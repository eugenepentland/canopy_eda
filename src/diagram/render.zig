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

const all_views = [_]View{ .power, .clocks, .rf };

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

    // Power edges are colored per rail voltage (with a legend above the SVG);
    // every other view uses its single accent color.
    const palette: ?[]const VoltColor = if (view == .power) try buildVoltPalette(arena, graph) else null;

    try w.print("<div class=\"dg-panel dg-panel-{s}\">", .{viewSlug(view)});
    if (palette) |p| try writeLegend(w, p, lay);
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"dg-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ lay.width, lay.height },
    );
    if (view == .power) {
        try renderPowerView(arena, w, graph, lay, palette);
    } else {
        // Z-ordered passes: wires first (node rects paint over their ends), then
        // nodes, then net-label pills last (opaque, so they stay legible where
        // wires cross). Clocks uses the curved connector style (its edges are all
        // adjacent-column hops); RF keeps the lane-routed orthogonal wires.
        const curved = view == .clocks;
        for (lay.routes) |r| {
            const color = edgeColor(view, palette, r.voltage);
            if (curved) try writeCurveEdge(w, r, color) else try writeEdgeWire(w, r, color);
        }
        for (lay.nodes) |n| try writeNode(arena, w, graph.nodes[n.gid], n.x, n.y);
        // One label per (source, rail). A rail fanning out to many consumers is a
        // single net, so its name is drawn once on the trunk, not once per branch.
        var labeled: std.StringHashMapUnmanaged(void) = .empty;
        for (lay.routes) |r| {
            const key = try std.fmt.allocPrint(arena, "{d}|{s}", .{ r.from_gid, r.label });
            if ((try labeled.getOrPut(arena, key)).found_existing) continue;
            try writeEdgeLabel(arena, w, r, edgeColor(view, palette, r.voltage));
        }
    }
    try w.writeAll("</svg></div>");
}

// ── nodes ──────────────────────────────────────────────────────────────

const pad_x: f64 = 11;
const label_char_w: f64 = 9.2;
const sub_char_w: f64 = 7.8;
const label_y_off: f64 = 24; // title baseline from node top
const sub_y_off: f64 = 46; // subtitle baseline from node top
const min_label_chars: usize = 8;
const min_sub_chars: usize = 10;
const arrow_len: f64 = 8; // arrowhead length along the wire
const arrow_half: f64 = 5; // arrowhead half-height
const pill_char_w: f64 = 8.4; // edge-label width per character
const pill_pad_x: f64 = 12; // edge-label horizontal padding
const pill_h: f64 = 20; // edge-label pill height
const pill_half_h: f64 = 10; // half of pill_h, also the pill corner radius
const label_dy: f64 = 4; // edge-label text baseline nudge

fn writeNode(arena: Allocator, w: *Writer, node: types.Node, x: f64, y: f64) (Allocator.Error || Writer.Error)!void {
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
    try w.writeAll("</g>");
    if (has_link) try w.writeAll("</a>");
}

// ── edges ──────────────────────────────────────────────────────────────

/// Wire + arrowhead only. The net-label pill is emitted in a separate later
/// pass (see `renderView`) so it always paints on top of every wire.
fn writeEdgeWire(w: *Writer, r: layout.Route, color: []const u8) Writer.Error!void {
    try w.print("<polyline points=\"", .{});
    for (r.pts, 0..) |p, i| {
        if (i > 0) try w.writeAll(" ");
        try w.print("{d:.1},{d:.1}", .{ p.x, p.y });
    }
    try w.print("\" class=\"dg-edge\" stroke=\"{s}\"/>", .{color});
    try writeArrow(w, r, color);
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

// ── power-view voltage coloring + legend ────────────────────────────────

/// A distinct rail voltage paired with the color used for its edges + legend.
const VoltColor = struct { v: f64, color: []const u8 };

const volt_eps: f64 = 0.05; // group voltages within 50 mV as one rail level
const volt_unspecified: []const u8 = "#8b949e"; // edge with no resolved voltage
// Cool→warm ramp, indexed by ascending voltage: low rails read cool, high warm.
const volt_palette = [_][]const u8{
    "#58a6ff", "#39c5cf", "#3fb950", "#d29922", "#e3742f", "#f85149", "#bc8cff", "#db61a2",
};

/// Distinct power-edge voltages (ascending) each assigned a palette color, so
/// the wires and the legend stay in lock-step.
fn buildVoltPalette(arena: Allocator, graph: *const Graph) Allocator.Error![]const VoltColor {
    var vs: std.ArrayListUnmanaged(f64) = .empty;
    for (graph.edges) |e| {
        if (e.class != .power) continue;
        const v = e.voltage orelse continue;
        var seen = false;
        for (vs.items) |x| {
            if (@abs(x - v) < volt_eps) {
                seen = true;
                break;
            }
        }
        if (!seen) try vs.append(arena, v);
    }
    std.mem.sort(f64, vs.items, {}, std.sort.asc(f64));
    const out = try arena.alloc(VoltColor, vs.items.len);
    for (vs.items, 0..) |v, i| out[i] = .{ .v = v, .color = volt_palette[i % volt_palette.len] };
    return out;
}

/// Stroke color for an edge: palette-by-voltage in the power view, the view's
/// accent color elsewhere. Power edges with no resolved voltage fall to grey.
fn edgeColor(view: View, palette: ?[]const VoltColor, voltage: ?f64) []const u8 {
    const p = palette orelse return viewColor(view);
    const v = voltage orelse return volt_unspecified;
    for (p) |pc| if (@abs(pc.v - v) < volt_eps) return pc.color;
    return volt_unspecified;
}

// ── power view: source → regulators → load buckets ──────────────────────

const pbox_pad: f64 = 15; // inner padding for source / regulator cards
const pbox_title_dy: f64 = 32; // card title baseline
const pbox_sub_dy: f64 = 56; // card subtitle baseline
const pbox_info_dy: f64 = 90; // card info-line baseline
const pbox_accent_w: f64 = 5; // left rail-color accent bar
const head_label_dx: f64 = 16; // bucket heading inset
const head_label_dy: f64 = 28; // bucket heading baseline
const pill_text_rise: f64 = 10; // pill text baseline above the pill bottom
const curve_swing: f64 = 0.5; // horizontal control-point fraction for edge curves
const edge_dot_r: f64 = 2.4; // terminal dot radius at each edge end

/// An edge as a smooth horizontal cubic Bézier between its end anchors, with a
/// small terminal dot at each end (no arrowhead) — the design's connector style,
/// used by the power supply tree and the clock fanout. Safe for adjacent-column
/// hops (the routed waypoints in between are ignored).
fn writeCurveEdge(w: *Writer, r: layout.Route, color: []const u8) Writer.Error!void {
    const a = r.pts[0];
    const b = r.pts[r.pts.len - 1];
    const ddx = b.x - a.x;
    const c1x = a.x + ddx * curve_swing;
    const c2x = b.x - ddx * curve_swing;
    try w.print(
        "<path d=\"M {d:.1} {d:.1} C {d:.1} {d:.1}, {d:.1} {d:.1}, {d:.1} {d:.1}\" class=\"dg-edge\" stroke=\"{s}\"/>",
        .{ a.x, a.y, c1x, a.y, c2x, b.y, b.x, b.y, color },
    );
    try w.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" fill=\"{s}\"/>", .{ a.x, a.y, edge_dot_r, color });
    try w.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" fill=\"{s}\"/>", .{ b.x, b.y, edge_dot_r, color });
}

/// Draws the power supply tree: rail-colored wires first, then the source /
/// regulator cards and the per-rail load buckets on top.
fn renderPowerView(arena: Allocator, w: *Writer, graph: *const Graph, lay: layout.Layout, palette: ?[]const VoltColor) (Allocator.Error || Writer.Error)!void {
    for (lay.routes) |r| try writeCurveEdge(w, r, edgeColor(.power, palette, r.voltage));
    for (lay.power_boxes) |b| {
        const bv: ?f64 = if (std.math.isNan(b.v)) null else b.v;
        const color = edgeColor(.power, palette, bv);
        switch (b.kind) {
            .source => try writePowerCard(arena, w, graph.nodes[b.gid], b, color, try voltLine(arena, "VBATT", b.v)),
            .regulator => try writePowerCard(arena, w, graph.nodes[b.gid], b, color, try voltLine(arena, "\u{2192}", b.v)),
            .bucket => try writePowerBucket(arena, w, graph, b, color),
        }
    }
}

fn voltLine(arena: Allocator, prefix: []const u8, v: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(v)) return "";
    return std.fmt.allocPrint(arena, "{s} {d:.2} V", .{ prefix, v });
}

/// A source or regulator card: dark rounded rect, left rail-color accent bar,
/// title (block label), subtitle (part / module), and an info line (rail V).
fn writePowerCard(
    arena: Allocator,
    w: *Writer,
    node: types.Node,
    b: layout.PowerBox,
    color: []const u8,
    info: []const u8,
) (Allocator.Error || Writer.Error)!void {
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"6\" class=\"dg-pcard\" stroke=\"{s}\"/>",
        .{ b.x, b.y, b.w, b.h, color },
    );
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"2\" fill=\"{s}\"/>",
        .{ b.x, b.y, pbox_accent_w, b.h, color },
    );
    const max_chars: usize = @max(min_label_chars, @as(usize, @intFromFloat((b.w - pbox_pad * 2) / label_char_w)));
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-label\">", .{ b.x + pbox_pad, b.y + pbox_title_dy });
    try writeEscaped(w, try truncate(arena, node.label, max_chars));
    try w.writeAll("</text>");
    if (node.subtitle.len > 0) {
        const sub_max: usize = @max(min_sub_chars, @as(usize, @intFromFloat((b.w - pbox_pad * 2) / sub_char_w)));
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-sub\">", .{ b.x + pbox_pad, b.y + pbox_sub_dy });
        try writeEscaped(w, try truncate(arena, node.subtitle, sub_max));
        try w.writeAll("</text>");
    }
    if (info.len > 0) {
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-pinfo\" fill=\"{s}\">", .{ b.x + pbox_pad, b.y + pbox_info_dy, color });
        try writeEscaped(w, info);
        try w.writeAll("</text>");
    }
}

/// A load bucket: rail-color outlined box, "X.X V · N loads" heading, then one
/// truncated pill per consuming block in a fixed two-column grid.
fn writePowerBucket(arena: Allocator, w: *Writer, graph: *const Graph, b: layout.PowerBox, color: []const u8) (Allocator.Error || Writer.Error)!void {
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"6\"" ++
            " fill=\"{s}\" fill-opacity=\"0.05\" stroke=\"{s}\" stroke-opacity=\"0.6\" class=\"dg-bucket\"/>",
        .{ b.x, b.y, b.w, b.h, color, color },
    );
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-band-label\" fill=\"{s}\">", .{ b.x + head_label_dx, b.y + head_label_dy, color });
    if (std.math.isNan(b.v)) {
        try w.print("Other \u{00b7} {d} loads", .{b.members.len});
    } else {
        try w.print("{d:.1} V \u{00b7} {d} loads", .{ b.v, b.members.len });
    }
    try w.writeAll("</text>");

    const cols = layout.pw_pill_cols;
    const fcols: f64 = @floatFromInt(cols);
    const pill_w = (b.w - 2 * layout.pw_bucket_pad - (fcols - 1) * layout.pw_pill_gap) / fcols;
    const pill_chars: usize = @max(min_sub_chars, @as(usize, @intFromFloat((pill_w - pbox_pad) / sub_char_w)));
    for (b.members, 0..) |gid, k| {
        const col: f64 = @floatFromInt(k % cols);
        const row: f64 = @floatFromInt(k / cols);
        const px = b.x + layout.pw_bucket_pad + col * (pill_w + layout.pw_pill_gap);
        const py = b.y + layout.pw_head_h + row * (layout.pw_pill_h + layout.pw_pill_gap);
        try w.print(
            "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"4\" class=\"dg-pill\" stroke=\"{s}\"/>",
            .{ px, py, pill_w, layout.pw_pill_h, color },
        );
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-pilltext\">", .{ px + pbox_pad / 2, py + layout.pw_pill_h - pill_text_rise });
        try writeEscaped(w, try truncate(arena, graph.nodes[gid].label, pill_chars));
        try w.writeAll("</text>");
    }
}

/// True when voltage `v` is actually painted in this view — on a bucket or an
/// edge. Lets the legend list only voltages the reader can see, even though the
/// palette keeps a stable color per voltage across the whole design.
fn voltageRendered(v: f64, lay: layout.Layout) bool {
    for (lay.power_boxes) |b| {
        if (!std.math.isNan(b.v) and @abs(b.v - v) < volt_eps) return true;
    }
    for (lay.routes) |r| {
        if (r.voltage) |rv| if (@abs(rv - v) < volt_eps) return true;
    }
    return false;
}

fn writeLegend(w: *Writer, palette: []const VoltColor, lay: layout.Layout) Writer.Error!void {
    if (palette.len == 0) return;
    try w.writeAll("<div class=\"dg-legend\">");
    for (palette) |pc| {
        if (!voltageRendered(pc.v, lay)) continue;
        // Swatch is a tiny inline SVG (fill attribute is CSP-safe, unlike style=).
        try w.print(
            "<span class=\"dg-leg\"><svg class=\"dg-sw\" viewBox=\"0 0 12 12\"><rect width=\"12\" height=\"12\" rx=\"2\" fill=\"{s}\"/></svg>{d:.1} V</span>",
            .{ pc.color, pc.v },
        );
    }
    try w.writeAll("</div>");
}

// ── text helpers ───────────────────────────────────────────────────────

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
    \\.dg-tab{cursor:pointer;color:#8b949e;padding:6px 14px;border:1px solid #30363d;border-radius:6px;user-select:none;
    \\font:600 17px -apple-system,BlinkMacSystemFont,sans-serif;}
    \\.dg-tab:hover{color:#c9d1d9;border-color:#484f58;}
    \\.dg-panel{display:none;overflow-x:auto;}
    \\.dg-svg{display:block;width:100%;max-width:1536px;height:auto;}
    \\#dg-tab-power:checked ~ .dg-panels .dg-panel-power,
    \\#dg-tab-clocks:checked ~ .dg-panels .dg-panel-clocks,
    \\#dg-tab-rf:checked ~ .dg-panels .dg-panel-rf{display:block;}
    \\#dg-tab-power:checked ~ .dg-tabs .dg-tab-power{color:#fff;background:#da3633;border-color:#da3633;}
    \\#dg-tab-clocks:checked ~ .dg-tabs .dg-tab-clocks{color:#fff;background:#4ab3a3;border-color:#4ab3a3;}
    \\#dg-tab-rf:checked ~ .dg-tabs .dg-tab-rf{color:#fff;background:#e040fb;border-color:#e040fb;}
    \\.dg-rect{fill:#0d1117;stroke-width:1.5;}
    \\.dg-node:hover .dg-rect{fill:#161b22;}
    \\.dg-node-link{cursor:pointer;}
    \\.dg-label{fill:#c9d1d9;font:600 18px -apple-system,BlinkMacSystemFont,sans-serif;}
    \\.dg-sub{fill:#8b949e;font:15px -apple-system,BlinkMacSystemFont,sans-serif;}
    \\.dg-edge{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round;}
    \\.dg-pill{fill:#161b22;stroke-width:1;}
    \\.dg-edge-label{font:600 15px "SF Mono","Fira Code",monospace;text-anchor:middle;}
    \\.dg-legend{display:flex;gap:16px;flex-wrap:wrap;margin:0 0 10px 2px;
    \\font:600 16px "SF Mono","Fira Code",monospace;color:#8b949e;}
    \\.dg-leg{display:inline-flex;align-items:center;gap:6px;}
    \\.dg-sw{width:16px;height:16px;display:inline-block;}
    \\.dg-band-label{font:700 17px "SF Mono","Fira Code",monospace;}
    \\.dg-pcard{fill:#0d1117;stroke-width:1.8;}
    \\.dg-pinfo{font:600 16px "SF Mono","Fira Code",monospace;}
    \\.dg-bucket{stroke-width:1.8;}
    \\.dg-pilltext{fill:#c9d1d9;font:500 15px "SF Mono","Fira Code",monospace;}
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

// spec: diagram/render - Draws all edge labels after all wires so net pills stay legible
test "renderTabs draws edge-label pills after every wire" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = .rf, .label = "N1" },
        .{ .from = 0, .to = 2, .class = .rf, .label = "N2" },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    // The last wire polyline must precede the first label pill, so no wire is
    // ever painted over a net pill.
    const last_wire = std.mem.lastIndexOf(u8, out, "class=\"dg-edge\"").?;
    const first_pill = std.mem.indexOf(u8, out, "class=\"dg-pill\"").?;
    try testing.expect(last_wire < first_pill);
}

// spec: diagram/render - Draws each rail label once per source, not once per fanout branch
test "renderTabs draws one label for a net fanned to many consumers" {
    var nodes = [_]types.Node{ mkNode("HUB"), mkNode("A"), mkNode("B") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = .rf, .label = "LO_OUT" },
        .{ .from = 0, .to = 2, .class = .rf, .label = "LO_OUT" },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    // Both edges are the same net from the same source ⇒ a single label pill.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, aw.written(), "class=\"dg-pill\""));
}

// spec: diagram/render - Draws per-rail load buckets with rail-colored headings in the power view
test "renderTabs draws load buckets in the power view" {
    var nodes = [_]types.Node{ mkNode("REG"), mkNode("A") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = .power, .label = "v", .voltage = 3.3 }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "class=\"dg-bucket\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "dg-band-label") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3.3 V") != null);
}

// spec: diagram/render - Colors power edges by voltage and renders a voltage legend
test "renderTabs colors power edges by voltage with a legend" {
    var nodes = [_]types.Node{ mkNode("REG"), mkNode("A"), mkNode("B") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = .power, .label = "V3P3", .voltage = 3.3 },
        .{ .from = 0, .to = 2, .class = .power, .label = "V1P8", .voltage = 1.8 },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "dg-legend") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.8 V") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3.3 V") != null);
    // Lowest voltage gets the first (cool) palette color on its wire stroke.
    try testing.expect(std.mem.indexOf(u8, out, "stroke=\"#58a6ff\"") != null);
}
