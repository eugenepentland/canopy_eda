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
const ClassId = types.ClassId;
const Writer = std.Io.Writer;

/// Tab metadata for the combined **System** view — every block + every
/// inter-block connection at once, color-coded by signal class. It is not a
/// signal class itself, so it lives outside `Graph.classes`; it's prepended as
/// the first (default) tab.
pub const system_key: []const u8 = "system";
pub const system_label: []const u8 = "System";
pub const system_color: []const u8 = "#768390"; // neutral accent (shows all classes)

/// Tab metadata for the high-level **Function** view — the glanceable "what
/// does the system do" abstraction (a handful of verb-labeled functional
/// subsystems). When present it is the first, default-selected tab, above the
/// detailed System view. Rendered from a separately-built coarsened graph.
const function_key: []const u8 = "function";
const function_label: []const u8 = "Function";
const function_color: []const u8 = "#3fb950"; // green accent, distinct from the class colors

const layout_key: []const u8 = "layout";
const layout_label: []const u8 = "Layout";
const layout_color: []const u8 = "#d29922"; // amber accent — the author-placed free view

/// Render the whole tabbed diagram. The first tab is always the **System**
/// view — one block diagram showing every block and every inter-block
/// connection at once, color-coded by signal class — when the graph has
/// anything to draw; it is followed by one focused signal tab per non-reference
/// class that has edges, in registry order (built-ins first, then declared
/// classes). Emits nothing when the graph has neither a block nor a signal
/// edge. The radio→panel toggle and per-tab accent rules are emitted into a
/// scoped `<style>`, so a brand-new declared class needs no hand-written CSS.
pub fn renderTabs(allocator: Allocator, graph: *const Graph, w: *Writer) (Allocator.Error || Writer.Error)!void {
    return renderTabsWithFunction(allocator, graph, null, w);
}

/// As `renderTabs`, but with an optional pre-built coarsened **Function** graph
/// prepended as the first, default-selected tab. `func_graph` is the high-level
/// "what does it do" view (built by `diagram/function.zig`); pass null to show
/// just the System + per-class tabs (the plain `renderTabs` entry).
pub fn renderTabsWithFunction(allocator: Allocator, graph: *const Graph, func_graph: ?*const Graph, w: *Writer) (Allocator.Error || Writer.Error)!void {
    const has_function = func_graph != null;
    const has_system = layout.hasSystemView(graph);
    const has_layout = layout.hasFreeLayout(graph);
    var first_signal: ?ClassId = null;
    for (graph.classes, 0..) |_, i| {
        const id: ClassId = @intCast(i);
        if (graph.isView(id)) {
            first_signal = id;
            break;
        }
    }
    if (!has_function and !has_system and !has_layout) {
        if (first_signal == null) return;
    }

    try w.writeAll("<div class=\"dg-wrap\"><style>");
    // Per-view rules: the checked radio shows its panel and lights its tab.
    // Function and System are just keyed views with neutral accents.
    if (has_layout) try writeToggleRule(w, layout_key, layout_color);
    if (has_function) try writeToggleRule(w, function_key, function_color);
    if (has_system) try writeToggleRule(w, system_key, system_color);
    for (graph.classes, 0..) |c, i| {
        if (!graph.isView(@intCast(i))) continue;
        try writeToggleRule(w, c.key, c.color);
    }
    try w.writeAll("</style>");
    // Radios first so the `:checked ~` sibling selectors can reach the panels.
    // Default-selected tab: Layout if the author declared one (they're actively
    // placing blocks), else Function, else System, else the first signal view.
    if (has_layout) try w.print("<input type=\"radio\" name=\"dg-view\" id=\"dg-tab-{s}\" class=\"dg-radio\" checked>", .{layout_key});
    if (has_function) {
        const checked = if (!has_layout) " checked" else "";
        try w.print("<input type=\"radio\" name=\"dg-view\" id=\"dg-tab-{s}\" class=\"dg-radio\"{s}>", .{ function_key, checked });
    }
    if (has_system) {
        const checked = if (!has_layout and !has_function) " checked" else "";
        try w.print("<input type=\"radio\" name=\"dg-view\" id=\"dg-tab-{s}\" class=\"dg-radio\"{s}>", .{ system_key, checked });
    }
    // A signal view is the default only when no coarse view is present.
    const signal_default = !has_layout and !has_function and !has_system;
    for (graph.classes, 0..) |c, i| {
        const id: ClassId = @intCast(i);
        if (!graph.isView(id)) continue;
        const checked = if (signal_default and id == first_signal.?) " checked" else "";
        try w.print("<input type=\"radio\" name=\"dg-view\" id=\"dg-tab-{s}\" class=\"dg-radio\"{s}>", .{ c.key, checked });
    }
    try w.writeAll("<div class=\"dg-tabs\">");
    if (has_layout) try writeTabLabel(w, layout_key, layout_label);
    if (has_function) try writeTabLabel(w, function_key, function_label);
    if (has_system) try writeTabLabel(w, system_key, system_label);
    for (graph.classes, 0..) |c, i| {
        if (!graph.isView(@intCast(i))) continue;
        try writeTabLabel(w, c.key, c.label);
    }
    try w.writeAll("</div><div class=\"dg-panels\">");
    if (has_layout) try renderFreePanel(allocator, graph, w);
    if (func_graph) |fg| try renderCoarsePanel(allocator, fg, function_key, w);
    if (has_system) try renderCoarsePanel(allocator, graph, system_key, w);
    for (graph.classes, 0..) |_, i| {
        const id: ClassId = @intCast(i);
        if (!graph.isView(id)) continue;
        try renderView(allocator, graph, id, w);
    }
    try w.writeAll("</div></div>");
}

/// The clickable `<label>` that selects one keyed view's radio.
fn writeTabLabel(w: *Writer, key: []const u8, label: []const u8) Writer.Error!void {
    try w.print("<label for=\"dg-tab-{s}\" class=\"dg-tab dg-tab-{s}\">{s}</label>", .{ key, key, label });
}

/// The checked-radio → show-panel + light-tab CSS pair for one keyed view.
fn writeToggleRule(w: *Writer, key: []const u8, color: []const u8) Writer.Error!void {
    try w.print(
        "#dg-tab-{s}:checked~.dg-panels .dg-panel-{s}{{display:block;}}" ++
            "#dg-tab-{s}:checked~.dg-tabs .dg-tab-{s}{{color:#fff;background:{s};border-color:{s};}}",
        .{ key, key, key, key, color, color },
    );
}

/// A toggled `dg-panel` wrapping a stage-laid-out diagram for `graph` under the
/// given tab `key`. Both the detailed System view and the coarsened Function
/// view share this — they differ only in the graph fed in and the panel key.
fn renderCoarsePanel(allocator: Allocator, graph: *const Graph, key: []const u8, w: *Writer) (Allocator.Error || Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lay = (try layout.computeSystemLayout(arena, graph)) orelse return;
    try w.print("<div class=\"dg-panel dg-panel-{s}\">", .{key});
    try renderSystemBody(arena, w, graph, lay, false);
    try w.writeAll("</div>");
}

/// The **Layout** tab panel: the author-declared free-floating view. Built from
/// `computeFreeLayout` (relative `(place …)` directives → absolute box
/// positions) and drawn through the same body as the System view, so blocks and
/// class-colored edges look identical — only the placement differs.
fn renderFreePanel(allocator: Allocator, graph: *const Graph, w: *Writer) (Allocator.Error || Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lay = (try layout.computeFreeLayout(arena, graph)) orelse return;
    try w.print("<div class=\"dg-panel dg-panel-{s}\">", .{layout_key});
    try renderSystemBody(arena, w, graph, lay, true);
    try w.writeAll("</div>");
}

/// Render the combined System diagram as a standalone always-visible block (a
/// class legend + one inline SVG) — the static form the markdown/zip export
/// embeds. Returns false when there is nothing to draw.
pub fn renderSystemStandalone(allocator: Allocator, graph: *const Graph, w: *Writer) (Allocator.Error || Writer.Error)!bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lay = (try layout.computeSystemLayout(arena, graph)) orelse return false;
    try w.writeAll("<div class=\"dg-wrap\">");
    try renderSystemBody(arena, w, graph, lay, false);
    try w.writeAll("</div>");
    return true;
}

/// The class legend + one inline SVG, shared by the tab panel and the export's
/// standalone block.
fn renderSystemBody(arena: Allocator, w: *Writer, graph: *const Graph, lay: layout.Layout, rail_mode: bool) (Allocator.Error || Writer.Error)!void {
    try writeClassLegend(w, graph, lay);
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"dg-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ lay.width, lay.height },
    );
    try renderSystemView(arena, w, graph, lay, rail_mode);
    try w.writeAll("</svg>");
}

// System view: power wires are drawn thin + faint so the (usually sparser)
// signal flow reads clearly on top of the dense power-distribution fan.
const sys_power_width: f64 = 1.0;
const sys_power_opacity: f64 = 0.2;
const sys_arrow_sz: f64 = 13; // signal-edge arrowhead size (px)

/// Draw the combined view: every wire colored by *its* signal class (not a
/// single view accent), every block as a box, signal arrowheads showing flow
/// direction, then the signal-net labels last so they stay legible over
/// crossings. Block boxes carry their category color (what a block *is*); wires
/// carry their class color (what a connection *carries*). Power wires recede
/// (thin/faint, undirected, unlabeled) — the rail fan is the main clutter and
/// its voltages live in the focused Power tab.
fn renderSystemView(arena: Allocator, w: *Writer, graph: *const Graph, lay: layout.Layout, rail_mode: bool) (Allocator.Error || Writer.Error)!void {
    try writeStageBands(w, lay);
    try writeGroupBoxes(w, lay);
    // In rail mode (the Layout view) each power net gets its own color + label so
    // rails are traceable; otherwise power recedes as one faint anonymous color.
    const rails: ?[]const RailColor = if (rail_mode) try buildRailPalette(arena, graph) else null;
    for (lay.routes) |r| {
        if (r.class == types.CLASS_POWER) {
            if (rails) |p| {
                try writeRoutedEdge(w, r, railColor(p, r.label), sys_rail_width, sys_rail_opacity);
            } else {
                try writeRoutedEdge(w, r, classColor(graph, r.class), sys_power_width, sys_power_opacity);
            }
        } else {
            try writeRoutedEdge(w, r, classColor(graph, r.class), null, null);
        }
    }
    for (lay.nodes) |n| try writeNode(arena, w, graph.nodes[n.gid], n.x, n.y);
    // Arrowheads after the boxes so they sit on top of the block border and
    // read as "drives into this block". Signal edges only.
    for (lay.routes) |r| {
        if (r.class == types.CLASS_POWER) continue;
        try writeArrowhead(w, r, classColor(graph, r.class));
    }
    // Labels: signal edges always; power edges too in rail mode (so each rail is
    // named), each in its own color.
    var labeled: std.StringHashMapUnmanaged(void) = .empty;
    for (lay.routes) |r| {
        if (r.label.len == 0) continue;
        const is_power = r.class == types.CLASS_POWER;
        if (is_power and rails == null) continue;
        const color = if (is_power) railColor(rails.?, r.label) else classColor(graph, r.class);
        const key = try std.fmt.allocPrint(arena, "{d}|{s}", .{ r.from_gid, r.label });
        if ((try labeled.getOrPut(arena, key)).found_existing) continue;
        try writeEdgeLabel(arena, w, r, color);
    }
}

/// A filled triangle at the edge's destination end, pointing into the driven
/// block, so the System view shows signal-flow direction. The tip sits where
/// the wire meets the box; the base backs off toward the wire.
fn writeArrowhead(w: *Writer, r: layout.Route, color: []const u8) Writer.Error!void {
    const last = r.pts.len - 1;
    const tip = if (r.arrow_at_start) r.pts[0] else r.pts[last];
    // Angle off the *adjacent* waypoint (the last routed segment), not the far
    // endpoint, so the head aligns with how the wire actually arrives and sits
    // flush on the box edge — works for an arrival from any of the four sides.
    const nb = if (r.arrow_at_start) r.pts[1] else r.pts[last - 1];
    var dx = tip.x - nb.x;
    var dy = tip.y - nb.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    dx /= len;
    dy /= len;
    const bx = tip.x - dx * sys_arrow_sz; // base centre, backed off along the wire
    const by = tip.y - dy * sys_arrow_sz;
    const half = sys_arrow_sz * 0.55;
    // Base corners offset along the perpendicular (-dy, dx).
    try w.print(
        "<path d=\"M {d:.1} {d:.1} L {d:.1} {d:.1} L {d:.1} {d:.1} Z\" fill=\"{s}\"/>",
        .{ tip.x, tip.y, bx - dy * half, by + dx * half, bx + dy * half, by - dx * half, color },
    );
}

const band_inset: f64 = 14; // band tint extends this far past the node box
const band_tint: []const u8 = "#11161d"; // faint column wash behind a stage
const band_label_color = system_color; // muted neutral header text (same grey)
const band_label_y: f64 = 31; // header baseline within the reserved strip

/// Draw the System view's functional-region bands: a faint full-height wash
/// behind each stage column plus a centered header ("POWER IN", "CORE", …), so
/// the diagram reads as labeled architectural regions rather than a flat graph.
/// Drawn first (before edges/nodes) so it sits behind the content.
fn writeStageBands(w: *Writer, lay: layout.Layout) Writer.Error!void {
    for (lay.stage_labels, 0..) |label, r| {
        const col_x = layout.pad + @as(f64, @floatFromInt(r)) * (layout.node_w + layout.h_gap);
        try w.print(
            "<rect x=\"{d:.1}\" y=\"0\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"10\" fill=\"{s}\"/>",
            .{ col_x - band_inset, layout.node_w + band_inset * 2, lay.height, band_tint },
        );
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-band-label\" fill=\"{s}\" text-anchor=\"middle\">",
            .{ col_x + layout.node_w / 2, band_label_y, band_label_color },
        );
        for (label) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(std.ascii.toUpper(c)),
        };
        try w.writeAll("</text>");
    }
}

// Palette cycled across `(group …)` boxes so adjacent regions read as distinct.
const group_palette = [_][]const u8{
    "#58a6ff", // blue
    "#d29922", // amber
    "#3fb950", // green
    "#bc8cff", // purple
    "#39c5cf", // teal
    "#f0883e", // orange
};

/// Draw the free Layout view's `(group …)` regions: a faint tinted rounded box
/// behind the member blocks with the group label in its top-left, each in a
/// cycled palette color. Drawn before edges/nodes so it sits behind them.
fn writeGroupBoxes(w: *Writer, lay: layout.Layout) Writer.Error!void {
    for (lay.groups) |g| {
        const color = group_palette[g.color_idx % group_palette.len];
        try w.print(
            "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"12\" " ++
                "fill=\"{s}\" fill-opacity=\"0.05\" stroke=\"{s}\" stroke-opacity=\"0.55\" stroke-width=\"1.5\"/>",
            .{ g.x, g.y, g.w, g.h, color, color },
        );
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-group-label\" fill=\"{s}\">",
            .{ g.x + 14, g.y + 21, color },
        );
        for (g.label) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(c),
        };
        try w.writeAll("</text>");
    }
}

/// The accent color for a class id, guarding against an out-of-range id.
fn classColor(graph: *const Graph, id: ClassId) []const u8 {
    return if (id < graph.classes.len) graph.classes[id].color else volt_unspecified;
}

/// A legend mapping each present wire color to its signal-class label, in
/// registry order. Lets the reader decode the combined view's colors.
fn writeClassLegend(w: *Writer, graph: *const Graph, lay: layout.Layout) Writer.Error!void {
    var any = false;
    for (graph.classes, 0..) |c, i| {
        const cid: ClassId = @intCast(i);
        var present = false;
        for (lay.routes) |r| {
            if (r.class == cid) {
                present = true;
                break;
            }
        }
        if (!present) continue;
        if (!any) {
            try w.writeAll("<div class=\"dg-legend\">");
            any = true;
        }
        try w.print(
            "<span class=\"dg-leg\"><svg class=\"dg-sw\" viewBox=\"0 0 12 12\"><rect width=\"12\" height=\"12\" rx=\"2\" fill=\"{s}\"/></svg>{s}</span>",
            .{ c.color, c.label },
        );
    }
    if (any) try w.writeAll("</div>");
}

fn renderView(allocator: Allocator, graph: *const Graph, view: ClassId, w: *Writer) (Allocator.Error || Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lay = (try layout.computeLayout(arena, graph, view)) orelse return;

    // Power edges are colored per rail voltage (with a legend above the SVG);
    // every other view uses its single accent color.
    const palette: ?[]const VoltColor = if (view == types.CLASS_POWER) try buildVoltPalette(arena, graph) else null;

    try w.print("<div class=\"dg-panel dg-panel-{s}\">", .{graph.classes[view].key});
    if (palette) |p| try writeLegend(w, p, lay);
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"dg-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ lay.width, lay.height },
    );
    if (view == types.CLASS_POWER) {
        try renderPowerView(arena, w, graph, lay, palette);
    } else {
        // Z-ordered passes: edges first (node rects paint over their ends), then
        // nodes, then net-label pills last (opaque, so they stay legible where
        // edges cross). Both non-power views use the same smooth end-to-end
        // Bézier connector as the power tree — lane alignment keeps chains on one
        // row, so the curves run clean.
        for (lay.routes) |r| try writeCurveEdge(w, r, nonPowerEdgeColor(view, graph, r));
        for (lay.nodes) |n| try writeNode(arena, w, graph.nodes[n.gid], n.x, n.y);
        // One label per (source, rail). A rail fanning out to many consumers is a
        // single net, so its name is drawn once on the trunk, not once per branch.
        var labeled: std.StringHashMapUnmanaged(void) = .empty;
        for (lay.routes) |r| {
            const key = try std.fmt.allocPrint(arena, "{d}|{s}", .{ r.from_gid, r.label });
            if ((try labeled.getOrPut(arena, key)).found_existing) continue;
            try writeEdgeLabel(arena, w, r, nonPowerEdgeColor(view, graph, r));
        }
    }
    try w.writeAll("</svg></div>");
}

// ── nodes ──────────────────────────────────────────────────────────────

const pad_x: f64 = 11;
const label_char_w: f64 = 9.2;
const sub_char_w: f64 = 7.8;
const label_y_off: f64 = 24; // title baseline from node top
const sub_y_off: f64 = 45; // first subtitle line baseline from node top
const sub_line_h: f64 = 18; // subtitle line advance
const sub_lines: usize = 2; // subtitle wraps to at most this many lines
const min_label_chars: usize = 8;
const min_sub_chars: usize = 10;
const stack_offset: f64 = 7; // per-card offset for a multi-channel stacked block
const stack_back_opacity: f64 = 0.5; // dimmer stroke on the cards behind the front one
const stack_badge_gap: f64 = 5; // gap between the rearmost card top and the ×N badge
const rf_if_color: []const u8 = "#e3742f"; // RF edges returning to the connector (IF lines)
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
    // Board-edge endpoints (antennas / EMVS cells) get a dashed border.
    const rect_class = if (node.is_boundary) "dg-rect dg-boundary" else "dg-rect";
    // Multi-channel block: draw offset cards behind the main box (back-to-front)
    // so it reads as N stacked identical channels.
    if (node.stack > 1) {
        var k: usize = node.stack - 1;
        while (k >= 1) : (k -= 1) {
            const off = @as(f64, @floatFromInt(k)) * stack_offset;
            try w.print(
                "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.0}\" rx=\"6\" class=\"{s}\" stroke=\"{s}\" stroke-opacity=\"{d:.2}\"/>",
                .{ x + off, y - off, layout.node_w, layout.node_h, rect_class, color, stack_back_opacity },
            );
        }
        // "×N" channel-count badge above the top-right of the rearmost card, so
        // a stack reads as "this many identical channels" at a glance.
        const back_off = @as(f64, @floatFromInt(node.stack - 1)) * stack_offset;
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"end\" " ++
                "font-family=\"monospace\" font-weight=\"700\" font-size=\"17\" fill=\"{s}\">×{d}</text>",
            .{ x + layout.node_w + back_off, y - back_off - stack_badge_gap, color, node.stack },
        );
    }
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.0}\" rx=\"6\" class=\"{s}\" stroke=\"{s}\"/>",
        .{ x, y, layout.node_w, layout.node_h, rect_class, color },
    );
    const label_max: usize = @max(min_label_chars, @as(usize, @intFromFloat((layout.node_w - pad_x * 2) / label_char_w)));
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-label\">", .{ x + pad_x, y + label_y_off });
    try writeEscaped(w, try truncate(arena, node.label, label_max));
    try w.writeAll("</text>");
    const sub_max: usize = @max(min_sub_chars, @as(usize, @intFromFloat((layout.node_w - pad_x * 2) / sub_char_w)));
    const tx = x + pad_x;
    const ty = y + sub_y_off;
    if (node.caption.len > 0 or node.members.len > 0) {
        // A Function super-node. Its verb ("what it does") moves to a hover
        // tooltip; the box body shows the explicit caption (a concrete spec /
        // connector type) when declared, else its key member parts (RP2350, the
        // DUT connectors, …) so the high-level view still names real hardware.
        if (node.subtitle.len > 0) {
            try w.writeAll("<title>");
            try writeEscaped(w, node.subtitle);
            try w.writeAll("</title>");
        }
        const body = if (node.caption.len > 0) node.caption else try std.mem.join(arena, " · ", node.members);
        try writeSubLines(w, tx, ty, try wrapText(arena, body, sub_max, sub_lines));
    } else if (node.subtitle.len > 0) {
        try writeSubLines(w, tx, ty, try wrapText(arena, node.subtitle, sub_max, sub_lines));
    }
    try w.writeAll("</g>");
    if (has_link) try w.writeAll("</a>");
}

/// Emit each wrapped subtitle line as a `dg-sub` text row from `(x, y)` down.
fn writeSubLines(w: *Writer, x: f64, y: f64, lines: []const []const u8) (Allocator.Error || Writer.Error)!void {
    for (lines, 0..) |line, li| {
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-sub\">",
            .{ x, y + @as(f64, @floatFromInt(li)) * sub_line_h },
        );
        try writeEscaped(w, line);
        try w.writeAll("</text>");
    }
}

// ── edges ──────────────────────────────────────────────────────────────

/// A small filled terminal dot where an edge meets a block.
fn writeDot(w: *Writer, p: types.Pt, color: []const u8) Writer.Error!void {
    try w.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" fill=\"{s}\"/>", .{ p.x, p.y, edge_dot_r, color });
}

/// Edge stroke for the non-power views: an RF edge returning to the connector
/// (an IF line) gets a distinct warm tone; everything else uses the view accent.
fn nonPowerEdgeColor(view: ClassId, graph: *const Graph, r: layout.Route) []const u8 {
    if (view == types.CLASS_RF and graph.nodes[r.to_gid].category == .connector) return rf_if_color;
    return graph.classes[view].color;
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
    // A 2-point edge (the free Layout view's face-to-face stub): anchor the
    // label at the true midpoint so it sits in the open span between boxes,
    // not at an endpoint where it would land on the box border / its text.
    if (pts.len == 2) return .{ .x = (pts[0].x + pts[1].x) / 2, .y = (pts[0].y + pts[1].y) / 2 };
    return pts[pts.len / 2];
}

// ── power-view voltage coloring + legend ────────────────────────────────

/// A distinct rail voltage paired with the color used for its edges + legend.
// Layout-view power rails: each net drawn in its own color at this weight, so a
// rail is followable end-to-end while still reading lighter than the bold
// full-weight signal edges.
const sys_rail_width: f64 = 1.6;
const sys_rail_opacity: f64 = 0.7;

const RailColor = struct { name: []const u8, color: []const u8 };

/// Assign each distinct power-net name a palette color. Stub rails carry no
/// resolved voltage, so voltage-coloring can't tell them apart — coloring by
/// net name gives every rail its own traceable hue. Sorted for stable colors.
fn buildRailPalette(arena: Allocator, graph: *const Graph) Allocator.Error![]const RailColor {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER or e.label.len == 0) continue;
        var seen = false;
        for (names.items) |x| {
            if (std.mem.eql(u8, x, e.label)) {
                seen = true;
                break;
            }
        }
        if (!seen) try names.append(arena, e.label);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const out = try arena.alloc(RailColor, names.items.len);
    for (names.items, 0..) |nm, i| out[i] = .{ .name = nm, .color = volt_palette[i % volt_palette.len] };
    return out;
}

/// The assigned color for a power net, or grey if unknown.
fn railColor(palette: []const RailColor, name: []const u8) []const u8 {
    for (palette) |rc| if (std.mem.eql(u8, rc.name, name)) return rc.color;
    return volt_unspecified;
}

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
        if (e.class != types.CLASS_POWER) continue;
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
fn edgeColor(fallback: []const u8, palette: ?[]const VoltColor, voltage: ?f64) []const u8 {
    const p = palette orelse return fallback;
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
    try writeCurveEdgeStyled(w, r, color, null, null);
}

/// Like `writeCurveEdge`, but with an optional explicit stroke `width` and
/// `opacity` (null ⇒ inherit the `.dg-edge` CSS default). The System view uses
/// this to draw power wires thin and faint so the signal flow reads on top.
fn writeCurveEdgeStyled(w: *Writer, r: layout.Route, color: []const u8, width: ?f64, opacity: ?f64) Writer.Error!void {
    const a = r.pts[0];
    const b = r.pts[r.pts.len - 1];
    const ddx = b.x - a.x;
    const c1x = a.x + ddx * curve_swing;
    const c2x = b.x - ddx * curve_swing;
    try w.print(
        "<path d=\"M {d:.1} {d:.1} C {d:.1} {d:.1}, {d:.1} {d:.1}, {d:.1} {d:.1}\" class=\"dg-edge\" stroke=\"{s}\"",
        .{ a.x, a.y, c1x, a.y, c2x, b.y, b.x, b.y, color },
    );
    if (width) |sw| try w.print(" stroke-width=\"{d:.1}\"", .{sw});
    if (opacity) |op| try w.print(" stroke-opacity=\"{d:.2}\"", .{op});
    try w.writeAll("/>");
    if (opacity == null) {
        try writeDot(w, a, color);
        try writeDot(w, b, color);
    }
}

/// Draw an edge that *follows its routed waypoints* — the path the layout placed
/// to attach on the nearest box face and dodge box bodies — as one flowing
/// Bézier rather than a straight box-to-box curve. A 2-point hop falls back to
/// the plain curve; longer routes run straight from the source to the first
/// segment's midpoint, then a quadratic rounds every interior waypoint (midpoint
/// → waypoint control → next midpoint), then straight out to the sink. Because
/// the first and last segments are the perpendicular stubs off each box face,
/// the curve still meets each block square-on and the arrowhead lands flush.
/// Used by the stage-banded System and Function views.
fn writeRoutedEdge(w: *Writer, r: layout.Route, color: []const u8, width: ?f64, opacity: ?f64) Writer.Error!void {
    const pts = r.pts;
    if (pts.len <= 2) return writeCurveEdgeStyled(w, r, color, width, opacity);
    try w.print("<path d=\"M {d:.1} {d:.1}", .{ pts[0].x, pts[0].y });
    const m0 = midpoint(pts[0], pts[1]);
    try w.print(" L {d:.1} {d:.1}", .{ m0.x, m0.y });
    var i: usize = 1;
    while (i + 1 < pts.len) : (i += 1) {
        const m = midpoint(pts[i], pts[i + 1]);
        try w.print(" Q {d:.1} {d:.1}, {d:.1} {d:.1}", .{ pts[i].x, pts[i].y, m.x, m.y });
    }
    try w.print(" L {d:.1} {d:.1}\" class=\"dg-edge\" stroke=\"{s}\"", .{ pts[pts.len - 1].x, pts[pts.len - 1].y, color });
    if (width) |sw| try w.print(" stroke-width=\"{d:.1}\"", .{sw});
    if (opacity) |op| try w.print(" stroke-opacity=\"{d:.2}\"", .{op});
    try w.writeAll("/>");
    if (opacity == null) try writeDot(w, pts[0], color); // source dot; arrowhead marks the sink
}

fn midpoint(a: types.Pt, b: types.Pt) types.Pt {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

/// Draws the power supply tree: rail-colored wires first, then the source /
/// regulator cards and the per-rail load buckets on top.
fn renderPowerView(arena: Allocator, w: *Writer, graph: *const Graph, lay: layout.Layout, palette: ?[]const VoltColor) (Allocator.Error || Writer.Error)!void {
    const power_color = graph.classes[types.CLASS_POWER].color;
    for (lay.routes) |r| try writeCurveEdge(w, r, edgeColor(power_color, palette, r.voltage));
    for (lay.power_boxes) |b| {
        const bv: ?f64 = if (std.math.isNan(b.v)) null else b.v;
        const color = edgeColor(power_color, palette, bv);
        const node = graph.nodes[b.gid];
        const rail = outputRail(node, b.v);
        switch (b.kind) {
            // Source card: name the actual input rail (VBATT, VPWR_IN, …) rather
            // than assuming a battery — a USB-C/barrel board has no VBATT.
            .source => {
                const name = if (rail) |r| r.net else "IN";
                try writePowerCard(arena, w, node, b, color, try voltLine(arena, name, b.v));
            },
            // Regulator card: show a programmable rail's span ("1.8–3.3 V").
            .regulator => try writePowerCard(arena, w, node, b, color, try voltRangeLine(arena, "\u{2192}", rail, b.v)),
            .bucket => try writePowerBucket(arena, w, graph, b, color),
        }
    }
}

/// The producer's output rail at (≈) voltage `v` — its net name and optional
/// lower bound. Falls back to the first declared output.
/// Tolerance for matching a rail's stored voltage to a box voltage (both come
/// from the same source data, so an exact 10 mV window is plenty).
const volt_match_eps: f64 = 0.01;

fn outputRail(node: types.Node, v: f64) ?types.RailEnd {
    var first: ?types.RailEnd = null;
    for (node.outputs) |o| {
        if (first == null) first = o;
        if (o.voltage) |ov| {
            if (@abs(ov - v) < volt_match_eps) return o;
        }
    }
    return first;
}

fn voltLine(arena: Allocator, prefix: []const u8, v: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(v)) return "";
    return std.fmt.allocPrint(arena, "{s} {d:.2} V", .{ prefix, v });
}

/// Like `voltLine`, but renders a programmable rail (`rail.v_lo` set) as a span
/// "lo–v V"; otherwise a single figure.
fn voltRangeLine(arena: Allocator, prefix: []const u8, rail: ?types.RailEnd, v: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(v)) return "";
    if (rail) |r| {
        if (r.v_lo) |lo| return std.fmt.allocPrint(arena, "{s} {d:.1}\u{2013}{d:.1} V", .{ prefix, lo, v });
    }
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

/// Greedy word-wrap `s` into at most `max_lines` lines of ~`max` chars each, so
/// a block's description reads in full instead of truncating at the first line.
/// Words longer than `max` are hard-split; overflow past the last line is
/// ellipsised onto it. Returns the line slices (all borrowed from `s` except a
/// possibly-allocated ellipsised final line).
fn wrapText(arena: Allocator, s: []const u8, max: usize, max_lines: usize) Allocator.Error![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len and lines.items.len < max_lines) {
        while (i < s.len and s[i] == ' ') i += 1; // skip leading spaces
        if (i >= s.len) break;
        const last_line = lines.items.len + 1 == max_lines;
        // Extend the line word by word while it still fits.
        var end = i;
        var brk = i; // last word boundary that fit
        while (end < s.len) {
            var we = end;
            while (we < s.len and s[we] != ' ') we += 1; // word [end..we)
            if (we - i <= max or end == i) {
                brk = we;
                end = we;
                while (end < s.len and s[end] == ' ') end += 1;
                if (we - i > max) break; // a single oversize word — take it, then stop
            } else break;
        }
        if (last_line and brk < s.len) {
            // Tail won't fit — ellipsise whatever remains onto the final line.
            try lines.append(arena, try truncate(arena, std.mem.trimRight(u8, s[i..], " "), max));
            break;
        }
        // truncate() is a no-op for a normal line; it only bites a single word
        // longer than the box (which forms its own line).
        try lines.append(arena, try truncate(arena, std.mem.trimRight(u8, s[i..brk], " "), max));
        i = brk;
    }
    return lines.toOwnedSlice(arena);
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
    \\.dg-rect{fill:#0d1117;stroke-width:1.5;}
    \\.dg-boundary{stroke-dasharray:5 4;}
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
    \\.dg-group-label{font:700 15px "SF Mono","Fira Code",monospace;letter-spacing:0.04em;}
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
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_RF, .label = "CPOUT_1" }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "dg-tab-rf") != null);
    try testing.expect(std.mem.indexOf(u8, out, "dg-tab-power") == null);

    // A control-class edge (e.g. an I2C/SPI/GPIO net) gets its own Control tab.
    var cnodes = [_]types.Node{ mkNode("MCU"), mkNode("Sensor") };
    var cedges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "I2C_SDA" }};
    var cgraph = Graph{ .nodes = &cnodes, .edges = &cedges };
    var caw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer caw.deinit();
    try renderTabs(testing.allocator, &cgraph, &caw.writer);
    try testing.expect(std.mem.indexOf(u8, caw.written(), "dg-tab-control") != null);

    var empty = Graph{ .nodes = &nodes, .edges = &.{} };
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try renderTabs(testing.allocator, &empty, &aw2.writer);
    try testing.expectEqual(@as(usize, 0), aw2.written().len);
}

// spec: diagram/render - A designer-declared class renders its own view
test "renderTabs emits a tab for a designer-declared class" {
    // A brand-new declared class (not a built-in) renders its own tab — the
    // headline: representing a circuit the tool has never seen, no code change.
    const classes = types.builtin_classes ++ [_]types.ClassDef{
        .{ .key = "audio", .label = "Audio", .color = "#ff8800" },
    };
    const audio_id: types.ClassId = @intCast(classes.len - 1);
    var nodes = [_]types.Node{ mkNode("MIC"), mkNode("CODEC") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = audio_id, .label = "MIC_OUT" }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges, .classes = &classes };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "dg-tab-audio") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), ">Audio<") != null);
}

// spec: diagram/render - Draws all edge labels after all wires so net pills stay legible
test "renderTabs draws edge-label pills after every wire" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_RF, .label = "N1" },
        .{ .from = 0, .to = 2, .class = types.CLASS_RF, .label = "N2" },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    // Scope to the System panel — the wire-then-pill z-order is a per-panel
    // property, and the page now emits a System panel ahead of the RF one.
    const sys = out[std.mem.lastIndexOf(u8, out, "dg-panel-system").?..std.mem.lastIndexOf(u8, out, "dg-panel-rf").?];
    // The last wire polyline must precede the first label pill, so no wire is
    // ever painted over a net pill.
    const last_wire = std.mem.lastIndexOf(u8, sys, "class=\"dg-edge\"").?;
    const first_pill = std.mem.indexOf(u8, sys, "class=\"dg-pill\"").?;
    try testing.expect(last_wire < first_pill);
}

// spec: diagram/render - Draws each rail label once per source, not once per fanout branch
test "renderTabs draws one label for a net fanned to many consumers" {
    var nodes = [_]types.Node{ mkNode("HUB"), mkNode("A"), mkNode("B") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_RF, .label = "LO_OUT" },
        .{ .from = 0, .to = 2, .class = types.CLASS_RF, .label = "LO_OUT" },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    // Both edges are the same net from the same source ⇒ a single label pill
    // (checked within the System panel; the RF panel draws its own copy).
    const sys = out[std.mem.lastIndexOf(u8, out, "dg-panel-system").?..std.mem.lastIndexOf(u8, out, "dg-panel-rf").?];
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sys, "class=\"dg-pill\""));
}

// spec: diagram/render - Draws per-rail load buckets with rail-colored headings in the power view
test "renderTabs draws load buckets in the power view" {
    var nodes = [_]types.Node{ mkNode("REG"), mkNode("A") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "v", .voltage = 3.3 }};
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
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "V3P3", .voltage = 3.3 },
        .{ .from = 0, .to = 2, .class = types.CLASS_POWER, .label = "V1P8", .voltage = 1.8 },
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

// spec: diagram/render - Tints RF edges returning to the connector distinctly from the forward chain
test "renderTabs tints RF connector-return edges" {
    var j1 = mkNode("J1");
    j1.category = .connector;
    var nodes = [_]types.Node{ mkNode("MIX"), j1 };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_RF, .label = "ADF_CH1" }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    // The IF-return edge (to the connector) uses the warm IF tone, not magenta.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "stroke=\"#e3742f\"") != null);
}

// spec: diagram/render - Puts the combined System view first and selects it by default
test "renderTabs prepends a default-checked System tab" {
    var nodes = [_]types.Node{ mkNode("MCU"), mkNode("Sensor") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "I2C_SDA" }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    // System is present and is the default-checked radio…
    try testing.expect(std.mem.indexOf(u8, out, "id=\"dg-tab-system\" class=\"dg-radio\" checked") != null);
    // …the signal view is not also checked (single default)…
    try testing.expect(std.mem.indexOf(u8, out, "id=\"dg-tab-control\" class=\"dg-radio\" checked") == null);
    // …and the System tab label precedes the Control tab label.
    const sys_label = std.mem.indexOf(u8, out, ">System</label>").?;
    const ctrl_label = std.mem.indexOf(u8, out, ">Control</label>").?;
    try testing.expect(sys_label < ctrl_label);
}

// spec: diagram/render - System view draws every class's edges at once, colored by class, with a class legend
test "renderTabs System view combines all classes color-coded with a legend" {
    // A power net and a control net between the same two blocks: the System
    // view shows both, each wire in its own class color, plus a class legend.
    var nodes = [_]types.Node{ mkNode("REG"), mkNode("MCU"), mkNode("Sensor") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "V3P3", .voltage = 3.3 },
        .{ .from = 1, .to = 2, .class = types.CLASS_CONTROL, .label = "I2C" },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    // Scope to the System panel (first panel, before the Power panel).
    const sys = out[std.mem.lastIndexOf(u8, out, "dg-panel-system").?..std.mem.lastIndexOf(u8, out, "dg-panel-power").?];
    // Power wire painted red, control wire painted blue — the class colors.
    try testing.expect(std.mem.indexOf(u8, sys, "stroke=\"#da3633\"") != null);
    try testing.expect(std.mem.indexOf(u8, sys, "stroke=\"#388bfd\"") != null);
    // A class legend naming both signal types.
    try testing.expect(std.mem.indexOf(u8, sys, "dg-legend") != null);
    try testing.expect(std.mem.indexOf(u8, sys, "Power") != null);
    try testing.expect(std.mem.indexOf(u8, sys, "Control") != null);
}

// spec: diagram/render - System view labels functional bands so it reads as an architecture
test "renderTabs System view draws functional band headers" {
    // A power block, an MCU, and a sensor: the System view groups them into
    // labeled POWER / CORE / PERIPHERALS bands, drawn left→right.
    var nodes = [_]types.Node{
        .{ .label = "Buck", .subtitle = "", .category = .power, .slug = "", .inputs = &.{}, .outputs = &.{} },
        .{ .label = "MCU", .subtitle = "", .category = .mcu, .slug = "", .inputs = &.{}, .outputs = &.{} },
        .{ .label = "Sensor", .subtitle = "", .category = .sensor, .slug = "", .inputs = &.{}, .outputs = &.{} },
    };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "3V3", .voltage = 3.3 },
        .{ .from = 1, .to = 2, .class = types.CLASS_CONTROL, .label = "I2C" },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabs(testing.allocator, &graph, &aw.writer);
    const out = aw.written();
    const sys = out[std.mem.lastIndexOf(u8, out, "dg-panel-system").?..std.mem.lastIndexOf(u8, out, "dg-panel-power").?];
    try testing.expect(std.mem.indexOf(u8, sys, "dg-band-label") != null);
    try testing.expect(std.mem.indexOf(u8, sys, ">POWER<") != null);
    try testing.expect(std.mem.indexOf(u8, sys, ">CORE<") != null);
    try testing.expect(std.mem.indexOf(u8, sys, "PERIPHERALS &amp; I/O") != null);
}

// spec: diagram/render - Function view is the default first tab above the System view when one is supplied
test "renderTabsWithFunction prepends a default-checked Function tab" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "x" }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    // A minimal coarsened graph stands in for the Function view.
    var fnodes = [_]types.Node{ mkNode("Power"), mkNode("Controller") };
    var fedges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "" }};
    var fgraph = Graph{ .nodes = &fnodes, .edges = &fedges };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTabsWithFunction(testing.allocator, &graph, &fgraph, &aw.writer);
    const out = aw.written();
    // The Function radio is checked by default and the System radio (present)
    // is not — and the Function radio is emitted before the System one. Match
    // the radio `<input>`s specifically (the `class="dg-radio"` marker), not the
    // `#dg-tab-system` that also appears earlier in the <style> toggle rules.
    const fn_radio = std.mem.indexOf(u8, out, "id=\"dg-tab-function\" class=\"dg-radio\" checked").?;
    const sys_radio = std.mem.indexOf(u8, out, "id=\"dg-tab-system\" class=\"dg-radio\">").?;
    try testing.expect(fn_radio < sys_radio);
}

// spec: diagram/render - Wraps a block's description onto multiple lines instead of truncating at one
test "wrapText word-wraps to a line budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Fits on two lines, broken at a word boundary.
    const two = try wrapText(a, "alpha beta gamma delta", 12, 2);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("alpha beta", two[0]);
    try testing.expectEqualStrings("gamma delta", two[1]);
    // Overflow past the last allowed line is ellipsised, never dropped silently.
    const cut = try wrapText(a, "alpha beta gamma delta epsilon", 12, 2);
    try testing.expectEqual(@as(usize, 2), cut.len);
    try testing.expect(std.mem.endsWith(u8, cut[1], "\u{2026}"));
}
