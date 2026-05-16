//! Block-diagram view of a design: nodes (hub MCU, peripherals, power
//! producers, IO connectors) connected by labeled buses (hub↔peripheral)
//! and power rails (producer→consumer). Replaces the column-of-chips
//! system-overview view that only showed *what* was in the design, never
//! how the pieces connect.
//!
//! Rendered inline as SVG at the top of the schematic page. Each node
//! links to its `#sec-<slug>` anchor so clicking still jumps to the
//! detailed card below.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const review = @import("review.zig");
const rb = @import("render_block_types.zig");

const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const SubBlock = env_mod.SubBlock;
const Allocator = std.mem.Allocator;

// ── Public types ──────────────────────────────────────────────────────

/// Layout column a node sits in. Power producers on the left, the hub in
/// the middle, peripherals + IO on the right.
pub const NodeKind = enum { hub, peripheral, power, io };

/// One end of a power rail: net name and (optional) voltage.
pub const RailEnd = struct {
    net: []const u8,
    voltage: ?f64 = null,
};

/// One block in the diagram. Carries enough information for the renderer
/// to draw a rectangle with a title, a category tag, and lists of
/// consumed/produced power rails on its boundary.
pub const Node = struct {
    label: []const u8,
    subtitle: []const u8,
    kind: NodeKind,
    category: rb.Category,
    /// On-page anchor slug — empty when the node has no card to link to.
    slug: []const u8,
    /// Power rails this node *consumes* (declared via `(port "X" in power V)`
    /// on the source section, or on an adopted sub-block). Voltages are
    /// post-normalised against the producer for the same net so e.g. a
    /// peripheral declaring `(rated 2.0 3.6)` shows the buck's actual
    /// 3.3 V output instead of its own absolute max.
    inputs: []RailEnd,
    /// Power rails this node *produces* (declared via `(port "X" out power V)`).
    outputs: []RailEnd,
};

/// A labeled signal bus between the hub and a peripheral node.
pub const BusEdge = struct {
    from: u32,
    to: u32,
    /// Human-readable label shown on the line (e.g. "IMU SPI5", "USB").
    label: []const u8,
    /// Optional protocol annotation shown as a small subtitle on the line
    /// (e.g. "SPI", "USB 2.0 HS"). Empty when the section doesn't declare one.
    protocol: []const u8,
};

/// A power-rail connection between a producer and a consumer node.
pub const RailEdge = struct {
    from: u32,
    to: u32,
    net: []const u8,
    voltage: ?f64 = null,
};

/// Owned result of `collectBlockDiagram`: the full set of nodes plus
/// every edge the renderer needs to draw. Caller must call `deinit` on
/// it once rendering is done.
pub const Diagram = struct {
    nodes: []Node,
    bus_edges: []BusEdge,
    rail_edges: []RailEdge,

    pub fn deinit(self: *Diagram, allocator: Allocator) void {
        for (self.nodes) |n| {
            allocator.free(n.inputs);
            allocator.free(n.outputs);
            // `label` and `subtitle` are unowned (slices into the source
            // DesignBlock), but `slug` is freshly allocated by
            // `review.slugify` in the collection pass.
            if (n.slug.len > 0) allocator.free(n.slug);
        }
        allocator.free(self.nodes);
        allocator.free(self.bus_edges);
        allocator.free(self.rail_edges);
    }
};

// ── Collection ────────────────────────────────────────────────────────

/// Build the diagram from a design. The caller owns the returned slices
/// and must call `Diagram.deinit` to free them.
pub fn collectBlockDiagram(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
) Allocator.Error!Diagram {
    // Build "<subblock>/<port>" → parent-net-name map. Sub-block ports
    // carry their module-local name ("VOUT" on a buck), but the parent
    // wires them to a design-level net via consolidated `(net "VDD"
    // "buck/VOUT" …)` forms — which the evaluator materialises as
    // `NetTie{ .a = "buck/VOUT", .b = "VDD" }` entries on `block.net_ties`.
    // Rail matching has to key on the parent net so consumer "VDD"
    // finds producer "VDD".
    var sub_port_to_net: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer sub_port_to_net.deinit(allocator);
    for (block.net_ties) |nt| {
        const a_slash = std.mem.indexOfScalar(u8, nt.a, '/');
        const b_slash = std.mem.indexOfScalar(u8, nt.b, '/');
        // Pick the side that's `<sub>/<port>` and the side that's a top-level net.
        const sub_side: []const u8 = if (a_slash != null and b_slash == null) nt.a else if (b_slash != null and a_slash == null) nt.b else continue;
        const top_side: []const u8 = if (a_slash != null and b_slash == null) nt.b else nt.a;
        try sub_port_to_net.put(allocator, sub_side, top_side);
    }

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    errdefer {
        for (nodes.items) |n| {
            allocator.free(n.inputs);
            allocator.free(n.outputs);
        }
        nodes.deinit(allocator);
    }

    // Section index → node index (so edge collection can map back).
    var sec_node = try allocator.alloc(?u32, block.sections.len);
    defer allocator.free(sec_node);
    for (sec_node) |*x| x.* = null;

    // Sub-block index → node index for unattached sub-blocks. Attached
    // sub-blocks fold into their section node; their entry stays null.
    var sub_node = try allocator.alloc(?u32, block.sub_blocks.len);
    defer allocator.free(sub_node);
    for (sub_node) |*x| x.* = null;

    // Pre-compute "which sub-block attaches to which section" reverse map.
    const sec_to_sub = try allocator.alloc(?usize, block.sections.len);
    defer allocator.free(sec_to_sub);
    for (sec_to_sub) |*x| x.* = null;
    for (sub_attachments, 0..) |maybe_sec, sb_idx| {
        if (maybe_sec) |sec_idx| sec_to_sub[sec_idx] = sb_idx;
    }

    // Pass 1: one node per section, merged with its adopted sub-block (if any).
    for (block.sections, 0..) |sec, sec_idx| {
        if (sec.diagram_hidden) continue;
        const cat = rb.classifySection(sec);
        const slug = try review.slugify(allocator, sec.name);
        var input_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        var output_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        errdefer input_buf.deinit(allocator);
        errdefer output_buf.deinit(allocator);

        try collectSectionRails(allocator, sec, &input_buf, &output_buf);
        if (sec_to_sub[sec_idx]) |sb_idx| {
            try collectSubBlockRails(allocator, block.sub_blocks[sb_idx], &sub_port_to_net, &input_buf, &output_buf);
        }
        const kind = pickKind(cat, output_buf.items.len > 0);

        try nodes.append(allocator, .{
            .label = sec.name,
            .subtitle = sec.description,
            .kind = kind,
            .category = cat,
            .slug = slug,
            .inputs = try input_buf.toOwnedSlice(allocator),
            .outputs = try output_buf.toOwnedSlice(allocator),
        });
        sec_node[sec_idx] = @intCast(nodes.items.len - 1);
    }

    // Pass 2: one node per unattached sub-block (typically power producers
    // like buck/ldo/charger). Attached sub-blocks fold into their section
    // node (handled above), so we skip them here.
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (sb_idx < sub_attachments.len and sub_attachments[sb_idx] != null) continue;
        const cat = rb.classifyByName(sb.name, sb.block.instances);
        const display_label = if (sb.name.len > 0) sb.name else sb.block.name;
        const slug = try review.slugify(allocator, display_label);
        var input_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        var output_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        errdefer input_buf.deinit(allocator);
        errdefer output_buf.deinit(allocator);

        try collectSubBlockRails(allocator, sb, &sub_port_to_net, &input_buf, &output_buf);
        const kind = pickKind(cat, output_buf.items.len > 0);

        try nodes.append(allocator, .{
            .label = display_label,
            .subtitle = sb.block.name,
            .kind = kind,
            .category = cat,
            .slug = slug,
            .inputs = try input_buf.toOwnedSlice(allocator),
            .outputs = try output_buf.toOwnedSlice(allocator),
        });
        sub_node[sb_idx] = @intCast(nodes.items.len - 1);
    }

    // Locate the hub: first node with kind=hub. If none, designs without
    // a dedicated MCU section just don't get bus edges drawn (the renderer
    // handles that gracefully).
    var hub_idx: ?u32 = null;
    var hub_ref_des: []const u8 = "";
    for (nodes.items, 0..) |n, i| {
        if (n.kind == .hub) {
            hub_idx = @intCast(i);
            break;
        }
    }
    if (hub_idx) |h| {
        // The hub's ref-des is the ref shared by every `(pins "<ref>" …)` in
        // the MCU section. Picks the first; in practice all `pins` in the
        // MCU section reference the same main IC.
        const hub_sec = findSectionForNode(block.sections, sec_node, h);
        if (hub_sec) |hs| {
            for (hs.pin_groups) |pg| {
                if (pg.ref_des.len > 0) {
                    hub_ref_des = pg.ref_des;
                    break;
                }
            }
        }
    }

    // Bus edges: hub ↔ peripheral. Inferred from non-hub sections whose
    // pin_groups reference the hub's ref-des. Label is the first word of
    // the section name (e.g. "XSPI2" from "XSPI2 NOR Flash") so the wire
    // gets a short, scannable tag instead of the verbose pin_group
    // description; the protocol annotation carries the rest.
    var buses: std.ArrayListUnmanaged(BusEdge) = .empty;
    errdefer buses.deinit(allocator);
    if (hub_idx) |h| {
        for (block.sections, 0..) |sec, sec_idx| {
            const nid = sec_node[sec_idx] orelse continue;
            if (nid == h) continue;
            if (hub_ref_des.len == 0) continue;
            var has_hub_pins = false;
            for (sec.pin_groups) |pg| {
                if (!std.mem.eql(u8, pg.ref_des, hub_ref_des)) continue;
                has_hub_pins = true;
                break;
            }
            if (!has_hub_pins) continue;
            const label = firstWord(sec.name);
            const protocol = if (sec.protocols.len > 0) sec.protocols[0] else "";
            try buses.append(allocator, .{
                .from = h,
                .to = nid,
                .label = label,
                .protocol = protocol,
            });
        }
    }

    const rails = try buildRailEdges(allocator, nodes.items);
    errdefer allocator.free(rails);

    return .{
        .nodes = try nodes.toOwnedSlice(allocator),
        .bus_edges = try buses.toOwnedSlice(allocator),
        .rail_edges = rails,
    };
}

/// Build the producer→consumer rail edges, and as a side-effect rewrite
/// every consumer's `inputs[*].voltage` to match the producer's actual
/// output voltage. Without that rewrite a peripheral declaring
/// `(rated 2.0 3.6)` shows "VDD 3.6V" inside its node — the part's
/// absolute max, not the rail's real value.
fn buildRailEdges(allocator: Allocator, nodes: []Node) Allocator.Error![]RailEdge {
    var producer_by_net: std.StringHashMapUnmanaged(u32) = .empty;
    defer producer_by_net.deinit(allocator);
    var producer_voltage: std.StringHashMapUnmanaged(f64) = .empty;
    defer producer_voltage.deinit(allocator);
    for (nodes, 0..) |n, i| {
        for (n.outputs) |out| {
            _ = try producer_by_net.put(allocator, out.net, @intCast(i));
            if (out.voltage) |v| try producer_voltage.put(allocator, out.net, v);
        }
    }
    for (nodes) |*n| {
        for (n.inputs) |*in| {
            if (producer_voltage.get(in.net)) |v| in.voltage = v;
        }
    }
    var rails: std.ArrayListUnmanaged(RailEdge) = .empty;
    errdefer rails.deinit(allocator);
    for (nodes, 0..) |n, consumer_i| {
        for (n.inputs) |in| {
            const prod = producer_by_net.get(in.net) orelse continue;
            if (prod == @as(u32, @intCast(consumer_i))) continue;
            try rails.append(allocator, .{
                .from = prod,
                .to = @intCast(consumer_i),
                .net = in.net,
                .voltage = in.voltage,
            });
        }
    }
    return rails.toOwnedSlice(allocator);
}

fn collectSectionRails(
    allocator: Allocator,
    sec: Section,
    inputs: *std.ArrayListUnmanaged(RailEnd),
    outputs: *std.ArrayListUnmanaged(RailEnd),
) Allocator.Error!void {
    for (sec.ports) |p| {
        if (p.signal_type != .power) continue;
        switch (p.direction) {
            .in => try inputs.append(allocator, .{ .net = p.name, .voltage = p.voltage }),
            .out => try outputs.append(allocator, .{ .net = p.name, .voltage = p.voltage }),
            .io => {},
        }
    }
}

fn collectSubBlockRails(
    allocator: Allocator,
    sb: SubBlock,
    sub_port_to_net: *const std.StringHashMapUnmanaged([]const u8),
    inputs: *std.ArrayListUnmanaged(RailEnd),
    outputs: *std.ArrayListUnmanaged(RailEnd),
) Allocator.Error!void {
    for (sb.block.ports) |p| {
        // Sub-block ports use string directions. Treat a port as a power
        // rail when it has either an explicit `(nominal V)` or a `(rated
        // min max)` clause — that's the signal we use to tell `VOUT`
        // from a logic-level `SCLK` (which carries neither). Bidi ports
        // (`GND`) are not rails.
        const v = p.nominal orelse p.rated_max orelse continue;
        // Resolve the port's *parent* net name. The buck regulator's
        // own port is named "VOUT", but the parent design's
        // `(net "VDD" "buck/VOUT" …)` rewires it to "VDD" — and "VDD"
        // is what every consumer section declares for its input port,
        // so producer/consumer matching has to key on the parent name.
        const lookup_key_buf = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, p.name });
        defer allocator.free(lookup_key_buf);
        const net = sub_port_to_net.get(lookup_key_buf) orelse
            (if (p.net.len > 0) p.net else p.name);
        if (std.mem.eql(u8, p.direction, "in")) {
            try inputs.append(allocator, .{ .net = net, .voltage = v });
        } else if (std.mem.eql(u8, p.direction, "out")) {
            try outputs.append(allocator, .{ .net = net, .voltage = v });
        }
    }
}

fn nodeKindFor(cat: rb.Category) NodeKind {
    return switch (cat) {
        .mcu => .hub,
        .power => .power,
        .connector => .io,
        else => .peripheral,
    };
}

/// Decide which column a node belongs in. Honours the keyword-derived
/// category by default, but two tweaks make the column placement
/// honest about what the block actually *does* in the circuit:
///
///   - A section/sub-block whose name carries a power keyword
///     ("Power Button Controller") but produces no voltage rail is
///     downgraded to .peripheral — it's a consumer, not a producer,
///     and putting it in the power column is misleading.
///   - A sub-block that *does* produce a voltage rail is promoted to
///     .power even if its keyword-class is something else
///     (a voltage reference like the LTC6655 reads as .peripheral
///     by name).
fn pickKind(cat: rb.Category, has_outputs: bool) NodeKind {
    const base = nodeKindFor(cat);
    if (base == .hub) return base;
    if (has_outputs) return .power;
    if (base == .power) return .peripheral;
    return base;
}

fn findSectionForNode(
    sections: []const Section,
    sec_node: []const ?u32,
    target: u32,
) ?Section {
    for (sections, 0..) |sec, i| {
        if (sec_node[i] == target) return sec;
    }
    return null;
}

/// Return the leading whitespace-delimited token of `s` (e.g. "XSPI2" from
/// "XSPI2 NOR Flash"). Used to derive a short bus-edge label from the
/// section name. Falls back to the full string when there is no space.
fn firstWord(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, ' ')) |sp| return s[0..sp];
    return s;
}

/// Which compass region does this node belong in? Power producers go
/// west (priority over the keyword category — "Power Button Controller"
/// is a peripheral consumer, not a producer, so its name keyword must
/// not pin it to the regulator column). Connectors and comms ride above
/// the hub; memory hangs below; sensors and everything else fan out east.
fn regionFor(n: Node) Region {
    if (n.kind == .power) return .west;
    return switch (n.category) {
        .connector, .comms => .north,
        .memory => .south,
        else => .east,
    };
}

const Region = enum { west, north, south, east };

/// Append `idx` to the matching cardinal column. Keeps the bucketing
/// loop in `renderDiagramSvg` linear and free of nested switches.
fn appendRegion(
    region: Region,
    allocator: Allocator,
    idx: u32,
    west: *std.ArrayListUnmanaged(u32),
    north: *std.ArrayListUnmanaged(u32),
    south: *std.ArrayListUnmanaged(u32),
    east: *std.ArrayListUnmanaged(u32),
) Allocator.Error!void {
    switch (region) {
        .west => try west.append(allocator, idx),
        .north => try north.append(allocator, idx),
        .south => try south.append(allocator, idx),
        .east => try east.append(allocator, idx),
    }
}

/// Total pixel height of a vertical stack of `count` standard nodes.
fn stackHeight(count: usize) f64 {
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(count)) * (node_h + node_v_gap) - node_v_gap;
}

/// Lay a vertical stack of `nodes` at column-x `x`, vertically centred
/// inside the canvas band of height `col_h` starting at `y0`.
fn placeStack(nodes: []const u32, x: f64, y0: f64, col_h: f64, total_h: f64, xs: []f64, ys: []f64) void {
    const start = y0 + (col_h - total_h) / center_div;
    for (nodes, 0..) |nid, ri| {
        xs[nid] = x;
        ys[nid] = start + @as(f64, @floatFromInt(ri)) * (node_h + node_v_gap);
    }
}

// ── Rendering ────────────────────────────────────────────────────────

const node_w: f64 = 220;
const node_h: f64 = 64;
const node_v_gap: f64 = 18;
const col_gap: f64 = 110;
const svg_pad_x: f64 = 16;
const svg_pad_y: f64 = 16;
const min_col_h: f64 = 80;
// Label sizing for clipping long strings before they overflow the rect.
const label_char_w: f64 = 6.6;
const sub_char_w: f64 = 5.6;
const node_pad_x: f64 = 10;
// Y-offsets inside a node rect for the title and subtitle baselines.
const node_label_y_off: f64 = 18;
const node_sub_y_off: f64 = 34;
const node_rail_y_off_from_bottom: f64 = 6;
// Approximate width of one rail-tag character at the 9px monospace size,
// used to advance the cursor between consecutive rail tags.
const rail_tag_char_w: f64 = 5.6;
const rail_tag_gap: f64 = 6;
// Approximate width of one bus/rail label character at the 10px size,
// used to size the background "pill" so it just contains the text.
const edge_label_char_w: f64 = 5.8;
const edge_label_pill_h: f64 = 14;
const edge_label_pill_pad_x: f64 = 10;
const rail_label_y_off: f64 = 14;
const center_div: f64 = 2.0;

/// Render `block` as an SVG block diagram. Convenience wrapper around
/// `collectBlockDiagram` + `renderDiagramSvg`.
pub fn renderBlockDiagramSvg(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
    w: anytype,
) (Allocator.Error || std.Io.Writer.Error)!void {
    var diagram = try collectBlockDiagram(allocator, block, sub_attachments);
    defer diagram.deinit(allocator);
    try renderDiagramSvg(allocator, diagram, w);
}

/// Pure renderer — takes a pre-built `Diagram` and writes its SVG. Split
/// out from `renderBlockDiagramSvg` so tests (and future callers that
/// want to post-process the diagram) can run the layout without going
/// through the collector. Uses an internal arena for the throwaway
/// label/rail text allocations so the caller's allocator doesn't have
/// to track them.
///
/// Layout is a compass around the MCU hub:
///   - West column: power producers (battery, charger, buck, ldo, vref)
///   - North of hub: connectors + comms (USB, expansion connector)
///   - Center: hub
///   - South of hub: memory (flash, PSRAM, SD card)
///   - East column: sensors, analog, and everything else peripheral
pub fn renderDiagramSvg(
    allocator: Allocator,
    diagram: Diagram,
    w: anytype,
) (Allocator.Error || std.Io.Writer.Error)!void {
    if (diagram.nodes.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Bucket nodes by the cardinal slot they belong in. The hub itself is
    // the only node in the centre middle row; everything else fans out.
    var west: std.ArrayListUnmanaged(u32) = .empty;
    var north: std.ArrayListUnmanaged(u32) = .empty;
    var south: std.ArrayListUnmanaged(u32) = .empty;
    var east: std.ArrayListUnmanaged(u32) = .empty;
    var hub_id: ?u32 = null;
    defer west.deinit(allocator);
    defer north.deinit(allocator);
    defer south.deinit(allocator);
    defer east.deinit(allocator);
    for (diagram.nodes, 0..) |n, i| {
        const idx: u32 = @intCast(i);
        if (n.kind == .hub and hub_id == null) {
            hub_id = idx;
            continue;
        }
        try appendRegion(regionFor(n), allocator, idx, &west, &north, &south, &east);
    }

    // Vertical heights of each conceptual column.
    const west_h = stackHeight(west.items.len);
    const east_h = stackHeight(east.items.len);
    const center_count: usize = north.items.len + (@as(usize, if (hub_id != null) 1 else 0)) + south.items.len;
    const center_h = stackHeight(center_count);
    const col_h = @max(min_col_h, @max(@max(west_h, east_h), center_h));

    const col_count: f64 = 3;
    const svg_w = svg_pad_x * 2 + node_w * col_count + col_gap * (col_count - 1);
    const svg_h = svg_pad_y * 2 + col_h;

    var xs = try allocator.alloc(f64, diagram.nodes.len);
    defer allocator.free(xs);
    var ys = try allocator.alloc(f64, diagram.nodes.len);
    defer allocator.free(ys);

    const x_west = svg_pad_x;
    const x_center = svg_pad_x + node_w + col_gap;
    const x_east = svg_pad_x + (node_w + col_gap) * 2;

    placeStack(west.items, x_west, svg_pad_y, col_h, west_h, xs, ys);
    placeStack(east.items, x_east, svg_pad_y, col_h, east_h, xs, ys);

    // Centre column: stack north → hub → south, vertically centred.
    const center_start = svg_pad_y + (col_h - center_h) / center_div;
    var cursor_y = center_start;
    for (north.items) |nid| {
        xs[nid] = x_center;
        ys[nid] = cursor_y;
        cursor_y += node_h + node_v_gap;
    }
    if (hub_id) |h| {
        xs[h] = x_center;
        ys[h] = cursor_y;
        cursor_y += node_h + node_v_gap;
    }
    for (south.items) |sid| {
        xs[sid] = x_center;
        ys[sid] = cursor_y;
        cursor_y += node_h + node_v_gap;
    }

    try w.writeAll("<div class=\"bd-wrap\">");
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"bd-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ svg_w, svg_h },
    );

    // Edges first so node rects paint on top. Only bus (data) edges are
    // drawn between blocks — voltage rails would clutter the diagram, so
    // they're surfaced as the red/green tags inside each node's box
    // instead.
    for (diagram.bus_edges) |e| try writeBusEdge(scratch, w, e, diagram.nodes, xs, ys);

    for (diagram.nodes, 0..) |n, i| {
        try writeNode(scratch, w, n, xs[i], ys[i]);
    }

    try w.writeAll("</svg></div>");
}

fn writeNode(allocator: Allocator, w: anytype, node: Node, x: f64, y: f64) !void {
    const color = rb.categoryColor(node.category);
    const has_link = node.slug.len > 0;
    if (has_link) try w.print("<a href=\"#sec-{s}\" class=\"bd-node-link\">", .{node.slug});
    try w.writeAll("<g class=\"bd-node\">");
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.0}\" rx=\"6\" class=\"bd-rect\" stroke=\"{s}\"/>",
        .{ x, y, node_w, node_h, color },
    );
    const label_max: usize = @max(8, @as(usize, @intFromFloat((node_w - node_pad_x * 2) / label_char_w)));
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"bd-label\">",
        .{ x + node_pad_x, y + node_label_y_off },
    );
    try writeHtmlEscaped(w, try truncate(allocator, node.label, label_max));
    try w.writeAll("</text>");
    if (node.subtitle.len > 0) {
        const sub_min_chars: usize = 10;
        const sub_max: usize = @max(sub_min_chars, @as(usize, @intFromFloat((node_w - node_pad_x * 2) / sub_char_w)));
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"bd-sub\">",
            .{ x + node_pad_x, y + node_sub_y_off },
        );
        try writeHtmlEscaped(w, try truncate(allocator, node.subtitle, sub_max));
        try w.writeAll("</text>");
    }
    // Power-rail tags along the bottom — inputs in red (consumed), outputs
    // in green (produced). Keeps the diagram's at-a-glance answer to "what
    // voltages does this block need/give?" without forcing the user to
    // open the section's review card.
    var tag_x = x + node_pad_x;
    for (node.inputs) |in| {
        const tag = try formatRail(allocator, in, true);
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"bd-rail-in\">",
            .{ tag_x, y + node_h - node_rail_y_off_from_bottom },
        );
        try writeHtmlEscaped(w, tag);
        try w.writeAll("</text>");
        tag_x += @as(f64, @floatFromInt(tag.len)) * rail_tag_char_w + rail_tag_gap;
    }
    for (node.outputs) |out| {
        const tag = try formatRail(allocator, out, false);
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"bd-rail-out\">",
            .{ tag_x, y + node_h - node_rail_y_off_from_bottom },
        );
        try writeHtmlEscaped(w, tag);
        try w.writeAll("</text>");
        tag_x += @as(f64, @floatFromInt(tag.len)) * rail_tag_char_w + rail_tag_gap;
    }
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"bd-kind\" fill=\"{s}\">",
        .{ x + node_w - node_pad_x, y + node_label_y_off, color },
    );
    try writeHtmlEscaped(w, @tagName(node.kind));
    try w.writeAll("</text>");
    try w.writeAll("</g>");
    if (has_link) try w.writeAll("</a>");
}

fn writeBusEdge(allocator: Allocator, w: anytype, e: BusEdge, nodes: []const Node, xs: []const f64, ys: []const f64) !void {
    const fx = xs[e.from];
    const fy = ys[e.from];
    const tx = xs[e.to];
    const ty = ys[e.to];
    // Anchor: from-right-edge -> to-left-edge, midpoint-y on each.
    const sx = if (fx < tx) fx + node_w else fx;
    const ex = if (tx > fx) tx else tx + node_w;
    const sy = fy + node_h / center_div;
    const ey = ty + node_h / center_div;
    const mx = (sx + ex) / center_div;

    try w.print(
        "<path d=\"M {d:.1} {d:.1} C {d:.1} {d:.1}, {d:.1} {d:.1}, {d:.1} {d:.1}\" class=\"bd-bus\"/>",
        .{ sx, sy, mx, sy, mx, ey, ex, ey },
    );
    // Label sits over a small pill at the midpoint so the line text
    // stays legible against the schematic backdrop.
    const label_text = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ e.label, if (e.protocol.len > 0) " · " else "", e.protocol },
    );
    const text_y = (sy + ey) / center_div;
    _ = nodes;
    const pill_w = @as(f64, @floatFromInt(label_text.len)) * edge_label_char_w + edge_label_pill_pad_x;
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.0}\" rx=\"7\" class=\"bd-bus-pill\"/>",
        .{ mx - pill_w / center_div, text_y - edge_label_pill_pad_x, pill_w, edge_label_pill_h },
    );
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"bd-bus-label\">",
        .{ mx, text_y },
    );
    try writeHtmlEscaped(w, label_text);
    try w.writeAll("</text>");
}

fn writeRailEdge(allocator: Allocator, w: anytype, e: RailEdge, nodes: []const Node, xs: []const f64, ys: []const f64) !void {
    const fx = xs[e.from];
    const fy = ys[e.from];
    const tx = xs[e.to];
    const ty = ys[e.to];
    // Producer-right → consumer-left when going across columns; same
    // anchor logic as bus edges but with a different stroke style.
    const sx = if (fx < tx) fx + node_w else fx;
    const ex = if (tx > fx) tx else tx + node_w;
    const sy = fy + node_h / center_div;
    const ey = ty + node_h / center_div;
    const mx = (sx + ex) / center_div;

    try w.print(
        "<path d=\"M {d:.1} {d:.1} C {d:.1} {d:.1}, {d:.1} {d:.1}, {d:.1} {d:.1}\" class=\"bd-rail\"/>",
        .{ sx, sy, mx, sy, mx, ey, ex, ey },
    );
    _ = nodes;
    const label_text = try formatRailEdgeLabel(allocator, e);
    const pill_w = @as(f64, @floatFromInt(label_text.len)) * edge_label_char_w + edge_label_pill_pad_x;
    const text_y = (sy + ey) / center_div + rail_label_y_off;
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.0}\" rx=\"7\" class=\"bd-rail-pill\"/>",
        .{ mx - pill_w / center_div, text_y - edge_label_pill_pad_x, pill_w, edge_label_pill_h },
    );
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"bd-rail-label\">",
        .{ mx, text_y },
    );
    try writeHtmlEscaped(w, label_text);
    try w.writeAll("</text>");
}

fn formatRail(allocator: Allocator, r: RailEnd, is_input: bool) ![]const u8 {
    const arrow: []const u8 = if (is_input) "→ " else "← ";
    if (r.voltage) |v| return std.fmt.allocPrint(allocator, "{s}{s} {d:.1}V", .{ arrow, r.net, v });
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ arrow, r.net });
}

fn formatRailEdgeLabel(allocator: Allocator, e: RailEdge) ![]const u8 {
    if (e.voltage) |v| return std.fmt.allocPrint(allocator, "{s} {d:.2}V", .{ e.net, v });
    return std.fmt.allocPrint(allocator, "{s}", .{e.net});
}

fn truncate(allocator: Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return s;
    if (max <= 1) return s[0..max];
    return std.fmt.allocPrint(allocator, "{s}…", .{s[0 .. max - 1]});
}

fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// CSS fragment for the block-diagram view. Embedded into the schematic
/// page by render_html.zig — mirrors the way SYSTEM_OVERVIEW_CSS was
/// composed.
pub const BLOCK_DIAGRAM_CSS =
    \\.bd-wrap{margin:12px 0 4px;padding:10px;background:#0d1117;border:1px solid #21262d;border-radius:8px;overflow-x:auto;}
    \\.bd-svg{display:block;width:100%;max-width:1160px;height:auto;}
    \\.bd-rect{fill:#0d1117;stroke-width:1.5;}
    \\.bd-node:hover .bd-rect{fill:#161b22;}
    \\.bd-node-link{cursor:pointer;}
    \\.bd-label{fill:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:12px;font-weight:600;}
    \\.bd-sub{fill:#8b949e;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:10px;}
    \\.bd-kind{font-family:"SF Mono","Fira Code",monospace;font-size:9px;text-anchor:end;text-transform:uppercase;letter-spacing:0.04em;font-weight:700;}
    \\.bd-rail-in{fill:#f85149;font-family:"SF Mono","Fira Code",monospace;font-size:9px;font-weight:600;}
    \\.bd-rail-out{fill:#3fb950;font-family:"SF Mono","Fira Code",monospace;font-size:9px;font-weight:600;}
    \\.bd-bus{fill:none;stroke:#2196f3;stroke-width:1.4;stroke-linecap:round;}
    \\.bd-rail{fill:none;stroke:#da3633;stroke-width:1.4;stroke-linecap:round;stroke-dasharray:4 3;}
    \\.bd-bus-pill{fill:#161b22;stroke:#2196f3;stroke-width:1;}
    \\.bd-rail-pill{fill:#161b22;stroke:#da3633;stroke-width:1;}
    \\.bd-bus-label{fill:#79c0ff;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:10px;font-weight:600;text-anchor:middle;}
    \\.bd-rail-label{fill:#ff7b72;font-family:"SF Mono","Fira Code",monospace;font-size:10px;font-weight:600;text-anchor:middle;}
;

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn emptyBlock(name: []const u8) DesignBlock {
    return .{
        .name = name,
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: render_block_diagram_svg - Builds one node per section and one per unattached sub-block
test "collectBlockDiagram produces nodes for sections and unattached sub-blocks" {
    const sections = [_]Section{
        .{ .name = "STM32 Core", .description = "MCU" },
        .{ .name = "IMU", .description = "BNO08x" },
    };
    var buck_design = emptyBlock("tpsm84338");
    var unused_design = emptyBlock("usb-c-hs");
    const sub_blocks = [_]SubBlock{
        .{ .name = "buck", .block = &buck_design },
        // attached to "IMU" — folds in, no extra node.
        .{ .name = "imu", .block = &unused_design },
    };
    var block = emptyBlock("demo");
    block.sections = &sections;
    block.sub_blocks = &sub_blocks;

    const attachments = [_]?usize{ null, 1 }; // buck unattached, "imu" → sec idx 1
    var diagram = try collectBlockDiagram(testing.allocator, &block, &attachments);
    defer diagram.deinit(testing.allocator);

    // 2 sections + 1 unattached sub-block = 3 nodes.
    try testing.expectEqual(@as(usize, 3), diagram.nodes.len);
}

// spec: render_block_diagram_svg - Infers a bus edge per non-hub section whose pin_groups reference the hub ref-des
test "bus edge inferred from pin_groups referencing the hub" {
    const imu_pins = [_]env_mod.PartPin{
        .{ .pin = "R1", .net = "IMU_SCK" },
        .{ .pin = "T1", .net = "IMU_MOSI" },
    };
    const imu_pin_groups = [_]env_mod.PinGroup{
        .{ .ref_des = "stm32", .pins = &imu_pins, .group = "IMU SPI5" },
    };
    const sections = [_]Section{
        .{
            .name = "STM32 Core System",
            .description = "MCU",
            // The hub section is identified by category, not by having
            // pin_groups itself. We do declare pin_groups on it though so
            // collectBlockDiagram can pick up "stm32" as the hub ref-des.
            .pin_groups = &.{.{ .ref_des = "stm32", .pins = &.{}, .group = "VDD Power" }},
        },
        .{
            .name = "IMU",
            .description = "BNO08x",
            .pin_groups = &imu_pin_groups,
            .protocols = &.{"SPI"},
        },
    };
    var block = emptyBlock("demo");
    block.sections = &sections;

    var diagram = try collectBlockDiagram(testing.allocator, &block, &.{});
    defer diagram.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), diagram.bus_edges.len);
    const e = diagram.bus_edges[0];
    // Label is the first word of the section name ("IMU"), not the
    // verbose pin_group name — keeps the wire tag scannable.
    try testing.expectEqualStrings("IMU", e.label);
    try testing.expectEqualStrings("SPI", e.protocol);
}

// spec: render_block_diagram_svg - Matches a section's `in power` port against a producer sub-block's `out power` to draw a rail edge
test "rail edge connects producer sub-block to consumer section by net name" {
    const consumer_ports = [_]env_mod.SectionPort{
        .{ .name = "VDD", .direction = .in, .signal_type = .power, .voltage = 3.3 },
    };
    const sections = [_]Section{
        .{ .name = "STM32 Core System", .description = "MCU" },
        .{ .name = "IMU", .description = "BNO08x", .ports = &consumer_ports },
    };
    const producer_ports = [_]env_mod.Port{
        .{ .name = "VDD", .net = "VDD", .direction = "out", .nominal = 3.3 },
    };
    var buck_design = emptyBlock("tpsm84338");
    buck_design.ports = &producer_ports;
    const sub_blocks = [_]SubBlock{
        .{ .name = "buck", .block = &buck_design },
    };
    var block = emptyBlock("demo");
    block.sections = &sections;
    block.sub_blocks = &sub_blocks;

    var diagram = try collectBlockDiagram(testing.allocator, &block, &.{null});
    defer diagram.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), diagram.rail_edges.len);
    const re = diagram.rail_edges[0];
    try testing.expectEqualStrings("VDD", re.net);
    try testing.expectEqual(@as(?f64, 3.3), re.voltage);
}

// spec: render_block_diagram_svg - Renders nothing when the design has no nodes
test "renderDiagramSvg writes nothing for an empty diagram" {
    const diagram = Diagram{ .nodes = &.{}, .bus_edges = &.{}, .rail_edges = &.{} };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderDiagramSvg(testing.allocator, diagram, buf.writer(testing.allocator));
    try testing.expectEqualStrings("", buf.items);
}

// spec: render_block_diagram_svg - Renders an SVG containing the node label and bus label for a hub→peripheral link
test "renderBlockDiagramSvg writes bus label and node label" {
    const imu_pin_groups = [_]env_mod.PinGroup{
        .{ .ref_des = "stm32", .pins = &.{}, .group = "IMU SPI5" },
    };
    const sections = [_]Section{
        .{
            .name = "STM32 Core System",
            .description = "MCU",
            .pin_groups = &.{.{ .ref_des = "stm32", .pins = &.{}, .group = "VDD Power" }},
        },
        .{
            .name = "IMU",
            .description = "BNO08x",
            .pin_groups = &imu_pin_groups,
            .protocols = &.{"SPI"},
        },
    };
    var block = emptyBlock("demo");
    block.sections = &sections;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderBlockDiagramSvg(testing.allocator, &block, &.{}, buf.writer(testing.allocator));
    // The bus tag is the first word of the section name; the rest of the
    // protocol description sits in the subtitle ("SPI") rather than the
    // wire label itself.
    try testing.expect(std.mem.indexOf(u8, buf.items, ">IMU ") != null or
        std.mem.indexOf(u8, buf.items, ">IMU·") != null or
        std.mem.indexOf(u8, buf.items, ">IMU<") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "BNO08x") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "bd-bus") != null);
}
