//! Build the diagram graph from a design: one node per visible section + one
//! per unattached sub-block, then inter-block edges derived from the *unified*
//! netlist (flattened across sub-blocks and merged on net-ties via the same
//! machinery the KiCad export uses). Each net is classified into a `NetClass`
//! and routed to the matching view; GND is dropped; differential pairs and
//! parallel nets between the same two blocks collapse into one edge.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const rb = @import("../render_block_types.zig");
const review = @import("../review.zig");
const netlist = @import("../export_kicad_netlist.zig");
const export_kicad = @import("../export_kicad.zig");
const types = @import("types.zig");
const classify = @import("classify.zig");
const membership = @import("membership.zig");

const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const SubBlock = env_mod.SubBlock;
const Allocator = std.mem.Allocator;
const Node = types.Node;
const Edge = types.Edge;
const RailEnd = types.RailEnd;
const NetClass = types.NetClass;
const Graph = types.Graph;

/// Build the full graph. Caller owns the result and must call `Graph.deinit`.
pub fn collectGraph(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
) Allocator.Error!Graph {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    const sub_port_to_net = try buildSubPortToNet(scratch, block);

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    errdefer {
        for (nodes.items) |n| freeNode(allocator, n);
        nodes.deinit(allocator);
    }

    const sec_node = try allocator.alloc(?u32, block.sections.len);
    defer allocator.free(sec_node);
    @memset(sec_node, null);
    const sub_node = try allocator.alloc(?u32, block.sub_blocks.len);
    defer allocator.free(sub_node);
    @memset(sub_node, null);

    // Reverse of sub_attachments: section index → adopted sub-block index.
    const sec_to_sub = try allocator.alloc(?usize, block.sections.len);
    defer allocator.free(sec_to_sub);
    @memset(sec_to_sub, null);
    for (sub_attachments, 0..) |maybe_sec, sb_idx| {
        if (maybe_sec) |sec_idx| if (sec_idx < sec_to_sub.len) {
            sec_to_sub[sec_idx] = sb_idx;
        };
    }

    try buildSectionNodes(allocator, scratch, block, &sub_port_to_net, sec_to_sub, &nodes, sec_node);
    try buildSubBlockNodes(allocator, scratch, block, &sub_port_to_net, sub_attachments, &nodes, sub_node);

    var mem = try membership.build(allocator, block, sec_node, sub_node, sub_attachments);
    defer mem.deinit(allocator);
    var port_map = try classify.buildPortClassMap(allocator, block);
    defer port_map.deinit(allocator);

    var producer_by_net: std.StringHashMapUnmanaged(u32) = .empty;
    for (nodes.items, 0..) |n, i| {
        for (n.outputs) |out| try producer_by_net.put(scratch, out.net, @intCast(i));
    }

    const flat = try buildFlatNets(scratch, block);
    const edges = try deriveEdges(allocator, scratch, flat, &mem, &port_map, &producer_by_net, nodes.items);

    return .{ .nodes = try nodes.toOwnedSlice(allocator), .edges = edges };
}

// ── node construction ──────────────────────────────────────────────────

fn buildSectionNodes(
    allocator: Allocator,
    scratch: Allocator,
    block: *const DesignBlock,
    sub_port_to_net: *const SubPortMap,
    sec_to_sub: []const ?usize,
    nodes: *std.ArrayListUnmanaged(Node),
    sec_node: []?u32,
) Allocator.Error!void {
    for (block.sections, 0..) |sec, sec_idx| {
        if (sec.diagram_hidden) continue;
        var input_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        var output_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        try collectSectionRails(scratch, sec, &input_buf, &output_buf);
        if (sec_to_sub[sec_idx]) |sb_idx| {
            try collectSubBlockRails(scratch, block.sub_blocks[sb_idx], sub_port_to_net, &input_buf, &output_buf);
        }
        try nodes.append(allocator, .{
            .label = sec.name,
            .subtitle = sec.description,
            .category = rb.classifySection(sec),
            .slug = try review.slugify(allocator, sec.name),
            .inputs = try dupeRails(allocator, input_buf.items),
            .outputs = try dupeRails(allocator, output_buf.items),
        });
        sec_node[sec_idx] = @intCast(nodes.items.len - 1);
    }
}

fn buildSubBlockNodes(
    allocator: Allocator,
    scratch: Allocator,
    block: *const DesignBlock,
    sub_port_to_net: *const SubPortMap,
    sub_attachments: []const ?usize,
    nodes: *std.ArrayListUnmanaged(Node),
    sub_node: []?u32,
) Allocator.Error!void {
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (sb_idx < sub_attachments.len and sub_attachments[sb_idx] != null) continue;
        var input_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        var output_buf: std.ArrayListUnmanaged(RailEnd) = .empty;
        try collectSubBlockRails(scratch, sb, sub_port_to_net, &input_buf, &output_buf);
        const label = if (sb.name.len > 0) sb.name else sb.block.name;
        try nodes.append(allocator, .{
            .label = label,
            .subtitle = sb.block.name,
            .category = rb.classifyByName(sb.name, sb.block.instances),
            .slug = try review.slugify(allocator, label),
            .inputs = try dupeRails(allocator, input_buf.items),
            .outputs = try dupeRails(allocator, output_buf.items),
        });
        sub_node[sb_idx] = @intCast(nodes.items.len - 1);
    }
}

fn dupeRails(allocator: Allocator, items: []const RailEnd) Allocator.Error![]RailEnd {
    const out = try allocator.alloc(RailEnd, items.len);
    @memcpy(out, items);
    return out;
}

fn freeNode(allocator: Allocator, n: Node) void {
    allocator.free(n.inputs);
    allocator.free(n.outputs);
    if (n.slug.len > 0) allocator.free(n.slug);
}

// ── rail collection (ported from the old hub diagram) ──────────────────

const SubPortMap = std.StringHashMapUnmanaged([]const u8);

/// `"<sub>/<port>"` → parent net name, from the design's net-ties — lets a
/// sub-block's module-local `VOUT` resolve to the design rail it feeds.
fn buildSubPortToNet(scratch: Allocator, block: *const DesignBlock) Allocator.Error!SubPortMap {
    var m: SubPortMap = .empty;
    for (block.net_ties) |nt| {
        const a_slash = std.mem.indexOfScalar(u8, nt.a, '/');
        const b_slash = std.mem.indexOfScalar(u8, nt.b, '/');
        const sub_side: []const u8 = if (a_slash != null and b_slash == null) nt.a else if (b_slash != null and a_slash == null) nt.b else continue;
        const top_side: []const u8 = if (a_slash != null and b_slash == null) nt.b else nt.a;
        try m.put(scratch, sub_side, top_side);
    }
    return m;
}

fn collectSectionRails(
    scratch: Allocator,
    sec: Section,
    inputs: *std.ArrayListUnmanaged(RailEnd),
    outputs: *std.ArrayListUnmanaged(RailEnd),
) Allocator.Error!void {
    for (sec.ports) |p| {
        if (p.signal_type != .power) continue;
        switch (p.direction) {
            .in => try inputs.append(scratch, .{ .net = p.name, .voltage = p.voltage }),
            .out => try outputs.append(scratch, .{ .net = p.name, .voltage = p.voltage }),
            .io => {},
        }
    }
}

fn collectSubBlockRails(
    scratch: Allocator,
    sb: SubBlock,
    sub_port_to_net: *const SubPortMap,
    inputs: *std.ArrayListUnmanaged(RailEnd),
    outputs: *std.ArrayListUnmanaged(RailEnd),
) Allocator.Error!void {
    for (sb.block.ports) |p| {
        const v = p.nominal orelse p.rated_max orelse continue;
        const key = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ sb.name, p.name });
        const net = sub_port_to_net.get(key) orelse (if (p.net.len > 0) p.net else p.name);
        if (std.mem.eql(u8, p.direction, "in")) {
            try inputs.append(scratch, .{ .net = net, .voltage = v });
        } else if (std.mem.eql(u8, p.direction, "out")) {
            try outputs.append(scratch, .{ .net = net, .voltage = v });
        }
    }
}

// ── netlist flatten + edge derivation ──────────────────────────────────

/// Flatten the design tree and merge net-ties into one canonical net list
/// (arena-owned). Reuses the KiCad-export netlist machinery so the diagram
/// sees exactly the same connectivity the board does.
fn buildFlatNets(scratch: Allocator, block: *const DesignBlock) Allocator.Error![]export_kicad.FlatNet {
    var nets: std.ArrayListUnmanaged(export_kicad.FlatNet) = .empty;
    try netlist.collectNets(scratch, block, "", &nets);
    var ties: std.ArrayListUnmanaged(netlist.FlatTie) = .empty;
    try netlist.collectNetTies(scratch, block, "", &ties);
    try netlist.applyNetTies(scratch, &nets, ties.items);
    return nets.items;
}

/// Accumulator while collapsing parallel/diff nets between the same node pair.
const AccEdge = struct {
    from: u32,
    to: u32,
    class: NetClass,
    label: []const u8, // arena slice; shrinks to the common prefix on collapse
    voltage: ?f64,
    fanout: u16,
};

fn deriveEdges(
    allocator: Allocator,
    scratch: Allocator,
    flat: []const export_kicad.FlatNet,
    mem: *const membership.Membership,
    port_map: *const classify.PortClassMap,
    producer_by_net: *const std.StringHashMapUnmanaged(u32),
    nodes: []const Node,
) Allocator.Error![]Edge {
    var acc: std.ArrayListUnmanaged(AccEdge) = .empty;
    var key_to_idx: std.StringHashMapUnmanaged(usize) = .empty;
    var touched_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var touched: std.ArrayListUnmanaged(u32) = .empty;

    for (flat) |net| {
        const clean = cleanNetName(net.name);
        const cls = classify.netClass(clean, port_map);
        if (cls == .ground) continue;

        touched_set.clearRetainingCapacity();
        touched.clearRetainingCapacity();
        for (net.pins) |p| {
            const nid = mem.resolve(p.ref_des) orelse continue;
            const gop = try touched_set.getOrPut(scratch, nid);
            if (!gop.found_existing) try touched.append(scratch, nid);
        }
        if (touched.items.len < 2) continue;

        const driver = pickDriver(cls, clean, touched.items, nodes, producer_by_net);
        const voltage: ?f64 = if (cls == .power) producerVoltage(nodes, driver, clean) else null;
        for (touched.items) |other| {
            if (other == driver) continue;
            try accumulate(scratch, &acc, &key_to_idx, driver, other, cls, clean, voltage);
        }
    }

    const edges = try allocator.alloc(Edge, acc.items.len);
    errdefer allocator.free(edges);
    for (acc.items, 0..) |a, i| {
        edges[i] = .{
            .from = a.from,
            .to = a.to,
            .class = a.class,
            .label = try allocator.dupe(u8, a.label),
            .voltage = a.voltage,
            .fanout = a.fanout,
        };
    }
    return edges;
}

fn accumulate(
    scratch: Allocator,
    acc: *std.ArrayListUnmanaged(AccEdge),
    key_to_idx: *std.StringHashMapUnmanaged(usize),
    from: u32,
    to: u32,
    cls: NetClass,
    label: []const u8,
    voltage: ?f64,
) Allocator.Error!void {
    if (from == to) return;
    const key = try std.fmt.allocPrint(scratch, "{d}|{d}|{d}", .{ from, to, @intFromEnum(cls) });
    const gop = try key_to_idx.getOrPut(scratch, key);
    if (gop.found_existing) {
        var e = &acc.items[gop.value_ptr.*];
        e.fanout +|= 1;
        // Adopt the shared prefix only when it stays meaningful (≥3 chars); a
        // mixed bus (SPI + I2C + GPIO) trims to a stub like "M", so keep the
        // first net name as a representative instead of an unhelpful "M ×16".
        const merged = commonPrefixTrim(e.label, label);
        if (merged.len >= 3) e.label = merged;
        if (e.voltage == null) e.voltage = voltage;
    } else {
        gop.value_ptr.* = acc.items.len;
        try acc.append(scratch, .{ .from = from, .to = to, .class = cls, .label = label, .voltage = voltage, .fanout = 1 });
    }
}

/// Choose the driver (edge `from`) for a net. Power nets use the rail
/// producer; everything else uses a category-based driver priority, breaking
/// ties toward the lowest node id for stability.
fn pickDriver(
    cls: NetClass,
    clean: []const u8,
    touched: []const u32,
    nodes: []const Node,
    producer_by_net: *const std.StringHashMapUnmanaged(u32),
) u32 {
    if (cls == .power) {
        if (producer_by_net.get(clean)) |p| {
            for (touched) |t| if (t == p) return p;
        }
    }
    var best = touched[0];
    var best_pri = driverPriority(nodes[best].category, cls);
    for (touched[1..]) |t| {
        const pri = driverPriority(nodes[t].category, cls);
        if (pri > best_pri or (pri == best_pri and t < best)) {
            best = t;
            best_pri = pri;
        }
    }
    return best;
}

/// Category-based driver priority for a net class — used to orient an edge
/// (the highest-priority touched node becomes `from`). Written as if-chains
/// rather than nested switches to keep the enum's switch surface in one file.
fn driverPriority(cat: rb.Category, cls: NetClass) u8 {
    if (cls == .power) return if (cat == .power) 3 else 1;
    if (cls == .control) {
        if (cat == .mcu) return 4;
        if (cat == .connector) return 3;
        return 1;
    }
    if (cls == .clock) {
        if (cat == .clock) return 3;
        if (cat == .connector or cat == .mcu) return 2;
        return 1;
    }
    return 1; // rf, ground
}

fn producerVoltage(nodes: []const Node, driver: u32, net: []const u8) ?f64 {
    for (nodes[driver].outputs) |out| {
        if (std.mem.eql(u8, out.net, net)) return out.voltage;
    }
    return null;
}

// ── label helpers ──────────────────────────────────────────────────────

/// Strip a per-pin micro-net suffix (`<base>.<ref>.<pin>` → `<base>`).
fn cleanNetName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

/// Common prefix of two labels, trimmed of trailing separators — collapses
/// `RF_SPI_SCK` + `RF_SPI_MOSI` → `RF_SPI`, `ADF_CH1P` + `ADF_CH2N` → `ADF_CH`.
fn commonPrefixTrim(a: []const u8, b: []const u8) []const u8 {
    var k: usize = 0;
    const n = @min(a.len, b.len);
    while (k < n and a[k] == b[k]) : (k += 1) {}
    while (k > 1 and (a[k - 1] == '_' or a[k - 1] == '-' or a[k - 1] == '.')) : (k -= 1) {}
    return a[0..k];
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn emptyBlock(name: []const u8) DesignBlock {
    return .{ .name = name, .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
}

// spec: diagram/collect - Derives inter-block edges from the flattened netlist rather than an MCU hub
test "collectGraph connects two non-MCU sections via a shared net" {
    const pg0 = [_]env_mod.PinGroup{.{ .ref_des = "U7", .pins = &.{} }};
    const pg1 = [_]env_mod.PinGroup{.{ .ref_des = "U11", .pins = &.{} }};
    const secs = [_]Section{
        .{ .name = "ADF4159 Synth", .pin_groups = &pg0 },
        .{ .name = "ADF5901 VCO", .pin_groups = &pg1 },
    };
    const pins = [_]env_mod.PinRef{ .{ .ref_des = "U7", .pin = "1" }, .{ .ref_des = "U11", .pin = "2" } };
    const nets = [_]env_mod.Net{.{ .name = "CPOUT_1", .pins = &pins }};
    var block = emptyBlock("rf");
    block.sections = &secs;
    block.nets = &nets;
    var g = try collectGraph(testing.allocator, &block, &.{});
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.nodes.len);
    try testing.expect(g.edges.len >= 1);
    try testing.expectEqual(NetClass.rf, g.edges[0].class);
}

// spec: diagram/collect - Excludes ground nets and collapses parallel or differential nets into one edge
test "collectGraph drops ground and merges a differential pair" {
    const pg0 = [_]env_mod.PinGroup{.{ .ref_des = "U8", .pins = &.{} }};
    const pg1 = [_]env_mod.PinGroup{.{ .ref_des = "J1", .pins = &.{} }};
    const secs = [_]Section{
        .{ .name = "ADAR2004 Mixer", .pin_groups = &pg0 },
        .{ .name = "Mezzanine Connector", .pin_groups = &pg1 },
    };
    const gnd = [_]env_mod.PinRef{ .{ .ref_des = "U8", .pin = "10" }, .{ .ref_des = "J1", .pin = "20" } };
    const chp = [_]env_mod.PinRef{ .{ .ref_des = "U8", .pin = "1" }, .{ .ref_des = "J1", .pin = "3" } };
    const chn = [_]env_mod.PinRef{ .{ .ref_des = "U8", .pin = "2" }, .{ .ref_des = "J1", .pin = "4" } };
    const nets = [_]env_mod.Net{
        .{ .name = "GND", .pins = &gnd },
        .{ .name = "ADF_CH1P", .pins = &chp },
        .{ .name = "ADF_CH1N", .pins = &chn },
    };
    var block = emptyBlock("rf");
    block.sections = &secs;
    block.nets = &nets;
    var g = try collectGraph(testing.allocator, &block, &.{});
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.edges.len);
    try testing.expectEqual(@as(u16, 2), g.edges[0].fanout);
    try testing.expectEqualStrings("ADF_CH1", g.edges[0].label);
}
