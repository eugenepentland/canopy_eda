//! SVG emission for the category-split block diagram: a tab strip (Power /
//! Clocks / Control / RF) over one inline SVG per non-empty view. Tabs toggle
//! with a pure-CSS radio+label pattern (no JS) — safe because exactly one
//! diagram exists per schematic page, so the input ids can be static.

const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");
const rb = @import("../render_block_types.zig");

const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const View = types.View;
const Writer = std.Io.Writer;

const all_views = [_]View{ .power, .clocks, .control, .rf };

const viewId = types.viewId;
const viewSlug = types.viewSlug;
const viewColor = types.viewColor;

/// Render the whole tabbed diagram. Emits nothing when no view has edges.
pub fn renderTabs(allocator: Allocator, graph: *const Graph, w: *Writer) (Allocator.Error || Writer.Error)!void {
    var first_view: ?View = null;
    for (all_views) |v| {
        if (graph.hasView(v)) {
            first_view = v;
            break;
        }
    }
    if (first_view == null) return;

    try w.writeAll("<div class=\"dg-wrap\">");
    // Radios first so the `:checked ~` sibling selectors can reach the panels.
    for (all_views) |v| {
        if (!graph.hasView(v)) continue;
        const checked = if (v == first_view.?) " checked" else "";
        try w.print("<input type=\"radio\" name=\"dg-view\" id=\"{s}\" class=\"dg-radio\"{s}>", .{ viewId(v), checked });
    }
    try w.writeAll("<div class=\"dg-tabs\">");
    for (all_views) |v| {
        if (!graph.hasView(v)) continue;
        try w.print("<label for=\"{s}\" class=\"dg-tab dg-tab-{s}\">{s}</label>", .{ viewId(v), viewSlug(v), types.viewLabel(v) });
    }
    try w.writeAll("</div><div class=\"dg-panels\">");
    for (all_views) |v| {
        if (!graph.hasView(v)) continue;
        try renderView(allocator, graph, v, w);
    }
    try w.writeAll("</div></div>");
}

fn renderView(allocator: Allocator, graph: *const Graph, view: View, w: *Writer) (Allocator.Error || Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lay = (try layout.computeLayout(arena, graph, view)) orelse return;

    try w.print("<div class=\"dg-panel dg-panel-{s}\">", .{viewSlug(view)});
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"dg-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ lay.width, lay.height },
    );
    // Edges first so node rects paint on top of the wires.
    for (lay.routes) |r| try writeEdge(arena, w, r, view);
    for (lay.nodes) |n| try writeNode(arena, w, graph.nodes[n.gid], n.x, n.y, view);
    try w.writeAll("</svg></div>");
}

// ── nodes ──────────────────────────────────────────────────────────────

const pad_x: f64 = 10;
const label_char_w: f64 = 6.6;
const sub_char_w: f64 = 5.6;
const rail_char_w: f64 = 5.6;
const label_y_off: f64 = 18; // title baseline from node top
const sub_y_off: f64 = 34; // subtitle baseline from node top
const rail_y_off: f64 = 7; // rail-tag baseline up from node bottom
const rail_gap: f64 = 6; // gap between consecutive rail tags
const min_label_chars: usize = 8;
const min_sub_chars: usize = 10;
const arrow_len: f64 = 7; // arrowhead length along the wire
const arrow_half: f64 = 4; // arrowhead half-height
const pill_char_w: f64 = 5.8; // edge-label width per character
const pill_pad_x: f64 = 10; // edge-label horizontal padding
const pill_h: f64 = 14; // edge-label pill height
const pill_half_h: f64 = 7; // half of pill_h, also the pill corner radius
const label_dy: f64 = 3; // edge-label text baseline nudge

fn writeNode(arena: Allocator, w: *Writer, node: types.Node, x: f64, y: f64, view: View) (Allocator.Error || Writer.Error)!void {
    const color = rb.categoryColor(node.category);
    const has_link = node.slug.len > 0;
    if (has_link) try w.print("<a href=\"#sec-{s}\" class=\"dg-node-link\">", .{node.slug});
    try w.writeAll("<g class=\"dg-node\">");
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.0}\" rx=\"6\" class=\"dg-rect\" stroke=\"{s}\"/>",
        .{ x, y, layout.node_w, layout.node_h, color },
    );
    const label_max: usize = @max(min_label_chars, @as(usize, @intFromFloat((layout.node_w - pad_x * 2) / label_char_w)));
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-label\">", .{ x + pad_x, y + label_y_off });
    try writeEscaped(w, try truncate(arena, node.label, label_max));
    try w.writeAll("</text>");
    if (node.subtitle.len > 0) {
        const sub_max: usize = @max(min_sub_chars, @as(usize, @intFromFloat((layout.node_w - pad_x * 2) / sub_char_w)));
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-sub\">", .{ x + pad_x, y + sub_y_off });
        try writeEscaped(w, try truncate(arena, node.subtitle, sub_max));
        try w.writeAll("</text>");
    }
    if (view == .power) try writeRailTags(arena, w, node, x, y);
    try w.writeAll("</g>");
    if (has_link) try w.writeAll("</a>");
}

fn writeRailTags(arena: Allocator, w: *Writer, node: types.Node, x: f64, y: f64) (Allocator.Error || Writer.Error)!void {
    var tag_x = x + pad_x;
    const ty = y + layout.node_h - rail_y_off;
    for (node.inputs) |in| {
        const tag = try formatRail(arena, in.net, in.voltage, true);
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-rail-in\">", .{ tag_x, ty });
        try writeEscaped(w, tag);
        try w.writeAll("</text>");
        tag_x += @as(f64, @floatFromInt(tag.len)) * rail_char_w + rail_gap;
    }
    for (node.outputs) |out| {
        const tag = try formatRail(arena, out.net, out.voltage, false);
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-rail-out\">", .{ tag_x, ty });
        try writeEscaped(w, tag);
        try w.writeAll("</text>");
        tag_x += @as(f64, @floatFromInt(tag.len)) * rail_char_w + rail_gap;
    }
}

// ── edges ──────────────────────────────────────────────────────────────

fn writeEdge(arena: Allocator, w: *Writer, r: layout.Route, view: View) (Allocator.Error || Writer.Error)!void {
    const color = viewColor(view);
    try w.print("<polyline points=\"", .{});
    for (r.pts, 0..) |p, i| {
        if (i > 0) try w.writeAll(" ");
        try w.print("{d:.1},{d:.1}", .{ p.x, p.y });
    }
    try w.print("\" class=\"dg-edge\" stroke=\"{s}\"/>", .{color});
    try writeArrow(w, r, color);
    try writeEdgeLabel(arena, w, r, color);
}

fn writeArrow(w: *Writer, r: layout.Route, color: []const u8) Writer.Error!void {
    const n = r.pts.len;
    if (n < 2) return;
    // Arrow tip is the connection point at the logical `to` end. Approach
    // segments are horizontal, so the triangle points left or right.
    const tip = if (r.arrow_at_start) r.pts[0] else r.pts[n - 1];
    const prev = if (r.arrow_at_start) r.pts[1] else r.pts[n - 2];
    const points_left = tip.x < prev.x;
    const dx: f64 = if (points_left) arrow_len else -arrow_len;
    try w.print(
        "<polygon points=\"{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}\" fill=\"{s}\" class=\"dg-arrow\"/>",
        .{ tip.x, tip.y, tip.x + dx, tip.y - arrow_half, tip.x + dx, tip.y + arrow_half, color },
    );
}

fn writeEdgeLabel(arena: Allocator, w: *Writer, r: layout.Route, color: []const u8) (Allocator.Error || Writer.Error)!void {
    const mid = edgeLabelAnchor(r.pts);
    const text = try edgeLabelText(arena, r);
    if (text.len == 0) return;
    const pill_w = @as(f64, @floatFromInt(text.len)) * pill_char_w + pill_pad_x;
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.0}\" rx=\"{d:.0}\" class=\"dg-pill\" stroke=\"{s}\"/>",
        .{ mid.x - pill_w / 2, mid.y - pill_half_h, pill_w, pill_h, pill_half_h, color },
    );
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-edge-label\" fill=\"{s}\">", .{ mid.x, mid.y + label_dy, color });
    try writeEscaped(w, text);
    try w.writeAll("</text>");
}

fn edgeLabelText(arena: Allocator, r: layout.Route) Allocator.Error![]const u8 {
    if (r.voltage) |v| {
        return std.fmt.allocPrint(arena, "{s} {d:.2}V", .{ r.label, v });
    }
    if (r.fanout > 1) {
        return std.fmt.allocPrint(arena, "{s} \u{00d7}{d}", .{ r.label, r.fanout });
    }
    return r.label;
}

/// Anchor the label on the first vertical channel segment (pts[1]→pts[2]),
/// which always sits in the gap between columns — clear of node boxes. Falls
/// back to the geometric middle for degenerate polylines.
fn edgeLabelAnchor(pts: []const types.Pt) types.Pt {
    if (pts.len >= 3) return .{ .x = pts[1].x, .y = (pts[1].y + pts[2].y) / 2 };
    return pts[pts.len / 2];
}

// ── text helpers ───────────────────────────────────────────────────────

fn formatRail(arena: Allocator, net: []const u8, voltage: ?f64, is_input: bool) Allocator.Error![]const u8 {
    const arrow: []const u8 = if (is_input) "\u{2192} " else "\u{2190} ";
    if (voltage) |v| return std.fmt.allocPrint(arena, "{s}{s} {d:.1}V", .{ arrow, net, v });
    return std.fmt.allocPrint(arena, "{s}{s}", .{ arrow, net });
}

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

// ── CSS ────────────────────────────────────────────────────────────────

pub const CSS =
    \\.dg-wrap{margin:12px 0 4px;padding:10px;background:#0d1117;border:1px solid #21262d;border-radius:8px;}
    \\.dg-radio{position:absolute;width:0;height:0;opacity:0;pointer-events:none;}
    \\.dg-tabs{display:flex;gap:6px;margin-bottom:10px;flex-wrap:wrap;}
    \\.dg-tab{cursor:pointer;color:#8b949e;padding:5px 12px;border:1px solid #30363d;border-radius:6px;user-select:none;
    \\font:600 12px -apple-system,BlinkMacSystemFont,sans-serif;}
    \\.dg-tab:hover{color:#c9d1d9;border-color:#484f58;}
    \\.dg-panel{display:none;overflow-x:auto;}
    \\.dg-svg{display:block;width:100%;max-width:1280px;height:auto;}
    \\#dg-tab-power:checked ~ .dg-panels .dg-panel-power,
    \\#dg-tab-clocks:checked ~ .dg-panels .dg-panel-clocks,
    \\#dg-tab-control:checked ~ .dg-panels .dg-panel-control,
    \\#dg-tab-rf:checked ~ .dg-panels .dg-panel-rf{display:block;}
    \\#dg-tab-power:checked ~ .dg-tabs .dg-tab-power{color:#fff;background:#da3633;border-color:#da3633;}
    \\#dg-tab-clocks:checked ~ .dg-tabs .dg-tab-clocks{color:#fff;background:#4ab3a3;border-color:#4ab3a3;}
    \\#dg-tab-control:checked ~ .dg-tabs .dg-tab-control{color:#fff;background:#2196f3;border-color:#2196f3;}
    \\#dg-tab-rf:checked ~ .dg-tabs .dg-tab-rf{color:#fff;background:#e040fb;border-color:#e040fb;}
    \\.dg-rect{fill:#0d1117;stroke-width:1.5;}
    \\.dg-node:hover .dg-rect{fill:#161b22;}
    \\.dg-node-link{cursor:pointer;}
    \\.dg-label{fill:#c9d1d9;font:600 12px -apple-system,BlinkMacSystemFont,sans-serif;}
    \\.dg-sub{fill:#8b949e;font:10px -apple-system,BlinkMacSystemFont,sans-serif;}
    \\.dg-rail-in{fill:#f85149;font:600 9px "SF Mono","Fira Code",monospace;}
    \\.dg-rail-out{fill:#3fb950;font:600 9px "SF Mono","Fira Code",monospace;}
    \\.dg-edge{fill:none;stroke-width:1.5;stroke-linejoin:round;stroke-linecap:round;}
    \\.dg-pill{fill:#161b22;stroke-width:1;}
    \\.dg-edge-label{font:600 10px "SF Mono","Fira Code",monospace;text-anchor:middle;}
;

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkNode(label: []const u8) types.Node {
    return .{ .label = label, .subtitle = "", .category = .peripheral, .slug = "", .inputs = &.{}, .outputs = &.{} };
}

// spec: diagram/render - Renders a tab per non-empty view and nothing when no view has edges
test "renderTabs emits only tabs for views that have edges" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = .rf, .label = "CPOUT_1" }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "dg-tab-rf") != null);
    try testing.expect(std.mem.indexOf(u8, out, "dg-tab-power") == null);

    var empty = Graph{ .nodes = &nodes, .edges = &.{} };
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try renderTabs(testing.allocator, &empty, &aw2.writer);
    try testing.expectEqual(@as(usize, 0), aw2.written().len);
}
