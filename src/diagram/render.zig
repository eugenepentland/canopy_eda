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

    // Power edges are colored per rail voltage (with a legend above the SVG);
    // every other view uses its single accent color.
    const palette: ?[]const VoltColor = if (view == .power) try buildVoltPalette(arena, graph) else null;

    try w.print("<div class=\"dg-panel dg-panel-{s}\">", .{viewSlug(view)});
    if (palette) |p| try writeLegend(w, p, lay);
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"dg-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ lay.width, lay.height },
    );
    // Z-ordered passes: voltage bands behind everything, then wires (node rects
    // paint over their ends), then nodes, then net-label pills last (opaque, so
    // they stay legible where wires cross).
    for (lay.bands) |b| {
        const bv: ?f64 = if (std.math.isNan(b.v)) null else b.v;
        try writeBand(w, b, edgeColor(view, palette, bv));
    }
    for (lay.routes) |r| try writeEdgeWire(w, r, edgeColor(view, palette, r.voltage));
    for (lay.nodes) |n| try writeNode(arena, w, graph.nodes[n.gid], n.x, n.y);
    // One label per (source, rail). A rail fanning out to many consumers is a
    // single net, so its name is drawn once on the trunk, not once per branch —
    // this is what de-clutters the power tree (V_RF_3P3 ×6 → ×1).
    // Banded views (power) carry the rail name on the band heading, so they
    // skip the per-edge label pass.
    if (lay.bands.len == 0) {
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

const pad_x: f64 = 10;
const label_char_w: f64 = 6.6;
const sub_char_w: f64 = 5.6;
const label_y_off: f64 = 18; // title baseline from node top
const sub_y_off: f64 = 34; // subtitle baseline from node top
const min_label_chars: usize = 8;
const min_sub_chars: usize = 10;
const arrow_len: f64 = 7; // arrowhead length along the wire
const arrow_half: f64 = 4; // arrowhead half-height
const pill_char_w: f64 = 5.8; // edge-label width per character
const pill_pad_x: f64 = 10; // edge-label horizontal padding
const pill_h: f64 = 14; // edge-label pill height
const pill_half_h: f64 = 7; // half of pill_h, also the pill corner radius
const label_dy: f64 = 3; // edge-label text baseline nudge

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

const band_label_dx: f64 = 12; // heading inset from the band's left
const band_label_dy: f64 = 16; // heading baseline below the band's top

/// A voltage-band background: a tinted rounded rect in the rail color plus a
/// rail-colored "X.X V" heading (or "Other" for the unresolved band).
fn writeBand(w: *Writer, b: layout.Band, color: []const u8) Writer.Error!void {
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"8\"" ++
            " fill=\"{s}\" fill-opacity=\"0.07\" stroke=\"{s}\" stroke-opacity=\"0.55\" class=\"dg-band\"/>",
        .{ b.x, b.y, b.w, b.h, color, color },
    );
    const lx = if (b.label_x >= 0) b.label_x else b.x + band_label_dx;
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-band-label\" fill=\"{s}\">", .{ lx, b.y + band_label_dy, color });
    if (std.math.isNan(b.v)) {
        try w.writeAll("Other");
    } else {
        try w.print("{d:.1} V", .{b.v});
    }
    try w.writeAll("</text>");
}

/// True when voltage `v` is actually painted in this view — on a band or an
/// edge. Lets the legend list only voltages the reader can see, even though the
/// palette keeps a stable color per voltage across the whole design.
fn voltageRendered(v: f64, lay: layout.Layout) bool {
    for (lay.bands) |b| {
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
    \\.dg-edge{fill:none;stroke-width:1.5;stroke-linejoin:round;stroke-linecap:round;}
    \\.dg-pill{fill:#161b22;stroke-width:1;}
    \\.dg-edge-label{font:600 10px "SF Mono","Fira Code",monospace;text-anchor:middle;}
    \\.dg-legend{display:flex;gap:14px;flex-wrap:wrap;margin:0 0 9px 2px;
    \\font:600 11px "SF Mono","Fira Code",monospace;color:#8b949e;}
    \\.dg-leg{display:inline-flex;align-items:center;gap:5px;}
    \\.dg-sw{width:12px;height:12px;display:inline-block;}
    \\.dg-band-label{font:700 11px "SF Mono","Fira Code",monospace;}
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

// spec: diagram/render - Draws voltage-band backgrounds with rail-colored headings in the power view
test "renderTabs draws voltage bands in the power view" {
    var nodes = [_]types.Node{ mkNode("REG"), mkNode("A") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = .power, .label = "v", .voltage = 3.3 }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "class=\"dg-band\"") != null);
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
