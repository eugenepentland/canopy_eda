const std = @import("std");
const env_mod = @import("eval/env.zig");
const json_writer = @import("json_writer.zig");
const DesignBlock = env_mod.DesignBlock;

const ctx_mod = @import("render_svg/context.zig");
pub const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const PinGroup = ctx_mod.PinGroup;
const Endpoint = ctx_mod.Endpoint;
const Side = ctx_mod.Side;

const hub_mod = @import("render_svg/hub.zig");
const connection = @import("render_svg/connection.zig");
const draw = @import("render_svg/draw.zig");
const branch_mod = @import("render_svg/branch.zig");

const hub_width = draw.hub_width;
const hub_x = draw.hub_x;
const pin_stub = draw.pin_stub;
const spoke_len = draw.spoke_len;
const passive_bw = draw.passive_bw;
const top_margin = draw.top_margin;
const per_conn_spacing = draw.per_conn_spacing;
const branch_spacing = draw.branch_spacing;
const bus_gap = draw.bus_gap;
const net_label_gap = draw.net_label_gap;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const shortRef = draw.shortRef;
const displayValue = draw.displayValue;
const formatShort = draw.formatShort;
const endpointEql = draw.endpointEql;

const Allocator = std.mem.Allocator;

// ── JSON Scene Graph Types ───────────────────────────────────────────

const JsonSection = struct {
    name: []const u8,
    description: []const u8,
    notes: []const []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

const JsonPin = struct {
    pin_numbers: []const u8,
    display_name: []const u8,
    y: f64,
    side: []const u8,
    /// Alternate functions available for this pin (empty for power/ground and multi-pin groups).
    alts: []const []const u8 = &.{},
    /// Asserted function if the user wrote `(pin X (as "FN") …)`, else empty.
    active_fn: []const u8 = "",
};

const JsonHub = struct {
    ref: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    part: ?[]const u8,
    label: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    icon: ?[]const u8,
    left_pins: std.ArrayListUnmanaged(JsonPin),
    right_pins: std.ArrayListUnmanaged(JsonPin),
};

/// Cached pinout data: symbol_name -> (pin_id -> []alt_names).
/// Populated lazily in renderSceneGraph; lives for the lifetime of a single render.
const PinoutAltMap = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const []const u8));

fn loadPinoutAlts(allocator: Allocator, map: *PinoutAltMap, project_dir: []const u8, symbol: []const u8) void {
    if (project_dir.len == 0 or symbol.len == 0) return;
    if (map.contains(symbol)) return;
    const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, symbol }) catch return;
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 256) catch return;
    const parser_m = @import("sexpr/parser.zig");
    const nodes = parser_m.parse(allocator, content) catch return;
    if (nodes.len == 0) return;
    const top = nodes[0].asList() orelse return;
    if (top.len < 2) return;
    const head = top[0].asAtom() orelse return;
    if (!std.mem.eql(u8, head, "pinout")) return;

    var by_pin: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 4) continue;
        const ch = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ch, "pin")) continue;
        const pin_id = cl[1].asAtom() orelse cl[1].asString() orelse continue;

        var alts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cl[3..]) |alt_node| {
            const al = alt_node.asList() orelse continue;
            if (al.len < 2) continue;
            const hd = al[0].asAtom() orelse continue;
            if (!std.mem.eql(u8, hd, "alt")) continue;
            const alt_name = al[1].asString() orelse (al[1].asAtom() orelse continue);
            alts.append(allocator, alt_name) catch continue;
        }
        if (alts.items.len > 0) {
            const owned = alts.toOwnedSlice(allocator) catch continue;
            by_pin.put(allocator, pin_id, owned) catch continue;
        }
    }
    map.put(allocator, symbol, by_pin) catch {};
}

/// Build a map of (ref_des|pin_id) -> asserted_fn from all nets. Keys are allocator-owned.
fn buildAssertedFnMap(allocator: Allocator, block: *const DesignBlock) std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    appendAssertedFromBlock(allocator, &map, block);
    return map;
}

fn appendAssertedFromBlock(allocator: Allocator, map: *std.StringHashMapUnmanaged([]const u8), block: *const DesignBlock) void {
    for (block.nets) |net| {
        for (net.pins) |p| {
            if (p.asserted_fns.len == 0) continue;
            const key = std.fmt.allocPrint(allocator, "{s}|{s}", .{ p.ref_des, p.pin }) catch continue;
            const joined = joinAssertedFns(allocator, p.asserted_fns) orelse continue;
            map.put(allocator, key, joined) catch {};
        }
    }
    for (block.sub_blocks) |sb| appendAssertedFromBlock(allocator, map, sb.block);
}

fn joinAssertedFns(allocator: Allocator, fns: []const []const u8) ?[]const u8 {
    if (fns.len == 0) return null;
    if (fns.len == 1) return fns[0];
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    for (fns, 0..) |f, i| {
        if (i > 0) w.writeAll(", ") catch return null;
        w.writeAll(f) catch return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

const JsonWire = struct {
    net: []const u8,
    points: std.ArrayListUnmanaged([2]f64),
    is_bus: bool,
};

const JsonPassive = struct {
    ref: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    count: u32 = 1,
};

const JsonLabel = struct {
    text: []const u8,
    x: f64,
    y: f64,
    anchor: []const u8,
    is_port: bool,
    is_ground: bool,
};

const JsonPort = struct {
    name: []const u8,
    net: []const u8,
    direction: []const u8,
    y: f64,
    rated_min: ?f64,
    rated_max: ?f64,
};

const JsonPortBlock = struct {
    name: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    icon: ?[]const u8,
    ports: std.ArrayListUnmanaged(JsonPort),
};

const SceneGraph = struct {
    allocator: Allocator,
    vb_w: f64 = 0,
    vb_h: f64 = 0,
    design_name: []const u8 = "",
    sections: std.ArrayListUnmanaged(JsonSection),
    hubs: std.ArrayListUnmanaged(JsonHub),
    wires: std.ArrayListUnmanaged(JsonWire),
    passives: std.ArrayListUnmanaged(JsonPassive),
    labels: std.ArrayListUnmanaged(JsonLabel),
    port_blocks: std.ArrayListUnmanaged(JsonPortBlock),

    fn init(allocator: Allocator) SceneGraph {
        return .{
            .allocator = allocator,
            .sections = .empty,
            .hubs = .empty,
            .wires = .empty,
            .passives = .empty,
            .labels = .empty,
            .port_blocks = .empty,
        };
    }

    fn addWire(self: *SceneGraph, net: []const u8, x1: f64, y1: f64, x2: f64, y2: f64, is_bus: bool) !void {
        var pts: std.ArrayListUnmanaged([2]f64) = .empty;
        if (y1 == y2) {
            try pts.append(self.allocator, .{ x1, y1 });
            try pts.append(self.allocator, .{ x2, y2 });
        } else {
            const mid_x = (x1 + x2) / 2.0;
            try pts.append(self.allocator, .{ x1, y1 });
            try pts.append(self.allocator, .{ mid_x, y1 });
            try pts.append(self.allocator, .{ mid_x, y2 });
            try pts.append(self.allocator, .{ x2, y2 });
        }
        try self.wires.append(self.allocator, .{
            .net = net,
            .points = pts,
            .is_bus = is_bus,
        });
    }

    fn addLabel(self: *SceneGraph, text: []const u8, x: f64, y: f64, anchor: []const u8, is_port: bool, is_ground: bool) !void {
        try self.labels.append(self.allocator, .{
            .text = text,
            .x = x,
            .y = y,
            .anchor = anchor,
            .is_port = is_port,
            .is_ground = is_ground,
        });
    }

    fn addPassive(self: *SceneGraph, inst: FlatInst, x: f64, y: f64) !void {
        try self.passives.append(self.allocator, .{
            .ref = shortRef(inst.ref_des),
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .x = x,
            .y = y,
            .w = passive_bw,
            .h = 20.0,
        });
    }

    fn addPassiveWithCount(self: *SceneGraph, inst: FlatInst, x: f64, y: f64, count: u32) !void {
        try self.passives.append(self.allocator, .{
            .ref = shortRef(inst.ref_des),
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .x = x,
            .y = y,
            .w = passive_bw,
            .h = 20.0,
            .count = count,
        });
    }
};

// ── Merge-aware height calculation ──────────────────────────────────

/// Compute group heights accounting for identical spoke merging.
/// Unlike hub_mod.groupHeights which counts every spoke individually,
/// this groups identical single-passive spokes and counts them as one slot.
fn mergeAwareGroupHeights(ctx: *RenderCtx, allocator: Allocator, groups: []const PinGroup, hub_ref: []const u8) ![]f64 {
    var heights = try allocator.alloc(f64, groups.len);
    for (groups, 0..) |group, i| {
        var total_slots: u32 = 0;

        // Classify connections for this group (same logic as collectGroupConnections)
        var classified: std.ArrayListUnmanaged(Classified) = .empty;
        for (group.conns) |conn| {
            switch (conn.endpoint) {
                .net => |net| {
                    const term = baseNetName(net);
                    if (!ctx.significant_nets.contains(term)) continue;
                    try classified.append(allocator, .{ .conn = conn, .terminal = term });
                },
                .pin => |p| {
                    if (ctx.spoke_set.contains(p.ref_des)) {
                        const term = try connection.getConnTerminal(ctx, conn.endpoint, hub_ref, conn.pin);
                        try classified.append(allocator, .{ .conn = conn, .terminal = term });
                    } else {
                        try classified.append(allocator, .{ .conn = conn, .terminal = "" });
                        total_slots += 1;
                        continue; // Non-spoke hub connections are always 1 slot, skip merge logic
                    }
                },
            }
        }

        // Now count slots with merge awareness for spoke/net connections
        if (classified.items.len > 0) {
            // Build merge keys for single-passive spokes
            const SpokeKey = struct { key: []const u8, is_mergeable: bool };
            var infos = try allocator.alloc(SpokeKey, classified.items.len);
            var consumed = try allocator.alloc(bool, classified.items.len);
            for (consumed) |*c| c.* = false;

            for (classified.items, 0..) |entry, j| {
                switch (entry.conn.endpoint) {
                    .pin => |p| {
                        if (ctx.spoke_set.contains(p.ref_des)) {
                            const inst = ctx.inst_map.get(p.ref_des) orelse {
                                infos[j] = .{ .key = "", .is_mergeable = false };
                                continue;
                            };
                            var visited: std.StringHashMapUnmanaged(void) = .empty;
                            try visited.put(allocator, p.ref_des, {});
                            const chain = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = entry.conn.pin } }, &visited);
                            if (chain.chain.len == 0 and chain.branches.len == 0) {
                                const val = if (inst.value.len > 0) inst.value else inst.component;
                                infos[j] = .{
                                    .key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ entry.terminal, val, inst.symbol }),
                                    .is_mergeable = true,
                                };
                            } else {
                                infos[j] = .{ .key = "", .is_mergeable = false };
                            }
                        } else {
                            infos[j] = .{ .key = "", .is_mergeable = false };
                        }
                    },
                    .net => {
                        infos[j] = .{ .key = "", .is_mergeable = false };
                    },
                }
            }

            // Count slots: merged groups count as 1 slot
            for (classified.items, 0..) |_, j| {
                if (consumed[j]) continue;
                consumed[j] = true;

                if (!infos[j].is_mergeable or infos[j].key.len == 0) {
                    // Non-mergeable: count normally
                    switch (classified.items[j].conn.endpoint) {
                        .pin => |p| {
                            if (ctx.spoke_set.contains(p.ref_des)) {
                                total_slots += hub_mod.estimateBranchCount(ctx, p.ref_des, hub_ref);
                            } else {
                                total_slots += 1;
                            }
                        },
                        .net => total_slots += 1,
                    }
                } else {
                    // Mergeable: consume all identical and count as 1 slot
                    for (j + 1..classified.items.len) |k| {
                        if (consumed[k]) continue;
                        if (infos[k].is_mergeable and std.mem.eql(u8, infos[k].key, infos[j].key)) {
                            consumed[k] = true;
                        }
                    }
                    total_slots += 1;
                }
            }
        }

        const base: f64 = 40.0;
        heights[i] = base + @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;
    }
    return heights;
}

/// Compute hub height using merge-aware group heights.
fn mergeAwareHubHeight(ctx: *RenderCtx, allocator: Allocator, hub: FlatInst, part: ?env_mod.Part) !f64 {
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

    var all_pins_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_pins_list.deinit(allocator);

    if (part) |p| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        for (p.pins) |pp| {
            if (!seen.contains(pp.pin)) {
                try seen.put(allocator, pp.pin, {});
                try all_pins_list.append(allocator, pp.pin);
            }
        }
    } else {
        for (ctx.nets.items) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    try all_pins_list.append(allocator, pin.pin);
                }
            }
        }
    }

    std.mem.sortUnstable([]const u8, all_pins_list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return draw.pinOrder(a, b);
        }
    }.lt);

    const parts_for_names: []const env_mod.Part = if (part) |p2| &[_]env_mod.Part{p2} else hub.parts;
    var pn_map = hub_mod.buildPinNameMap(ctx, parts_for_names);
    defer pn_map.deinit(allocator);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins_list.items, adj_entries, &pn_map);
    var left_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_pc: usize = 0;
    var right_pc: usize = 0;

    for (all_groups) |group| {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, group.pin_numbers, ',');
        while (it.next()) |_| n += 1;
        if (left_pc <= right_pc) {
            try left_groups_list.append(allocator, group);
            left_pc += n;
        } else {
            try right_groups_list.append(allocator, group);
            right_pc += n;
        }
    }

    const left_groups = left_groups_list.toOwnedSlice(allocator) catch &[_]PinGroup{};
    const right_groups = right_groups_list.toOwnedSlice(allocator) catch &[_]PinGroup{};
    const left_heights = try mergeAwareGroupHeights(ctx, allocator, left_groups, hub.ref_des);
    const right_heights = try mergeAwareGroupHeights(ctx, allocator, right_groups, hub.ref_des);

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;

    return @max(left_total, right_total) + 40.0;
}

// ── Public entry point ───────────────────────────────────────────────

pub fn renderSceneGraph(allocator: Allocator, block: *const DesignBlock, project_dir: []const u8) ![]const u8 {
    var ctx = RenderCtx.init(allocator);
    ctx.project_dir = project_dir;

    // Same pipeline as render_svg.zig
    try ctx.collectFlat(block, "");

    var flat_sec_idx: usize = 0;
    for (block.sections) |sec| {
        for (sec.instances) |inst| {
            try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
        }
        // Top-level instances whose pins are declared in this section via
        // `(pins ref ...)` should also count as "in" the section — this lets
        // the cross-section detection work for multipart hubs like U3 (the
        // STM32) whose body is top-level but whose pins live per-section.
        for (sec.pin_groups) |pg| {
            if (!ctx.section_map.contains(pg.ref_des)) {
                try ctx.section_map.put(allocator, pg.ref_des, flat_sec_idx);
            }
        }
        flat_sec_idx += 1;
        for (sec.sub_sections) |sub| {
            for (sub.instances) |inst| {
                try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
            }
            for (sub.pin_groups) |pg| {
                if (!ctx.section_map.contains(pg.ref_des)) {
                    try ctx.section_map.put(allocator, pg.ref_des, flat_sec_idx);
                }
            }
            flat_sec_idx += 1;
        }
    }
    // Include sub-block instances in section map (each sub-block becomes its own section)
    for (block.sub_blocks) |sb| {
        for (sb.block.instances) |inst| {
            try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
        }
        flat_sec_idx += 1;
    }

    try ctx.buildPinNetMap();
    try ctx.classify();
    try ctx.buildAdjacency();
    try ctx.synthesizeSpokeConnections();
    try ctx.buildNetIndex();
    try ctx.buildSignificantNets(block);
    try ctx.buildPinCanonicalNets();
    try ctx.validateNetConsistency();

    var scene = SceneGraph.init(allocator);
    scene.design_name = block.name;

    var alt_map: PinoutAltMap = .empty;
    var asserted_fns = buildAssertedFnMap(allocator, block);

    // Build grid cells from sections (same as render_svg.zig)
    const GridCell = struct {
        hub_inst: FlatInst,
        part: ?env_mod.Part,
        section_idx: usize,
    };

    const SectionInfo = struct {
        name: []const u8,
        description: []const u8,
        notes: []const []const u8,
        cell_indices: std.ArrayListUnmanaged(usize),
    };
    var section_grid: std.ArrayListUnmanaged(SectionInfo) = .empty;
    var ref_to_section = std.StringHashMap(usize).init(allocator);

    for (block.sections) |sec| {
        const sec_idx = section_grid.items.len;
        try section_grid.append(allocator, .{ .name = sec.name, .description = sec.description, .notes = sec.notes, .cell_indices = .empty });
        for (sec.instances) |inst| {
            try ref_to_section.put(inst.ref_des, sec_idx);
        }
        for (sec.sub_sections) |sub| {
            const sub_idx = section_grid.items.len;
            try section_grid.append(allocator, .{ .name = sub.name, .description = sub.description, .notes = sub.notes, .cell_indices = .empty });
            for (sub.instances) |inst| {
                try ref_to_section.put(inst.ref_des, sub_idx);
            }
        }
    }
    // Add sub-blocks as sections
    for (block.sub_blocks) |sb| {
        const sec_idx = section_grid.items.len;
        try section_grid.append(allocator, .{ .name = sb.block.name, .description = "", .notes = &.{}, .cell_indices = .empty });
        for (sb.block.instances) |inst| {
            try ref_to_section.put(inst.ref_des, sec_idx);
        }
    }

    var cells: std.ArrayListUnmanaged(GridCell) = .empty;

    for (ctx.hub_order.items) |hub_ref| {
        const hub_inst = ctx.inst_map.get(hub_ref) orelse continue;
        if (hub_inst.parts.len > 0) {
            for (hub_inst.parts) |part| {
                var sec_idx: usize = 0;
                for (section_grid.items, 0..) |sg, si| {
                    if (std.mem.eql(u8, sg.name, part.name)) {
                        sec_idx = si;
                        break;
                    }
                }
                const ci = cells.items.len;
                try cells.append(allocator, .{ .hub_inst = hub_inst, .part = part, .section_idx = sec_idx });
                try section_grid.items[sec_idx].cell_indices.append(allocator, ci);
            }
        } else {
            const sec_idx = ref_to_section.get(hub_inst.ref_des) orelse blk: {
                for (section_grid.items, 0..) |sg, si| {
                    if (std.mem.eql(u8, sg.name, hub_inst.component)) break :blk si;
                }
                const si = section_grid.items.len;
                try section_grid.append(allocator, .{ .name = hub_inst.component, .description = "", .notes = &.{}, .cell_indices = .empty });
                break :blk si;
            };
            const ci = cells.items.len;
            try cells.append(allocator, .{ .hub_inst = hub_inst, .part = null, .section_idx = sec_idx });
            try section_grid.items[sec_idx].cell_indices.append(allocator, ci);
        }
    }

    // Auto grid dimensions
    const n_sections = section_grid.items.len;
    const n_cols: usize = if (n_sections == 0) 1 else blk: {
        var c: usize = 1;
        while (c * c < n_sections) : (c += 1) {}
        break :blk c;
    };
    const n_rows: usize = if (n_sections == 0) 1 else (n_sections + n_cols - 1) / n_cols;

    // Grid layout constants (same as render_svg.zig)
    const cell_width: f64 = 850.0;
    const cell_gap_y: f64 = 30.0;
    const cell_gap_x: f64 = 40.0;
    const section_pad: f64 = 30.0;
    const title_font_size: f64 = 24.0;
    const desc_font_size: f64 = 15.0;
    const note_line_height: f64 = 15.0;

    // Compute per-section header height
    var section_header_heights = try allocator.alloc(f64, section_grid.items.len);
    defer allocator.free(section_header_heights);
    for (section_grid.items, 0..) |sg, si| {
        var h: f64 = title_font_size + 12.0;
        if (sg.description.len > 0) h += desc_font_size + 6.0;
        section_header_heights[si] = h;
    }

    // Compute per-section footer height
    var section_footer_heights = try allocator.alloc(f64, section_grid.items.len);
    defer allocator.free(section_footer_heights);
    for (section_grid.items, 0..) |sg, si| {
        if (sg.notes.len > 0) {
            section_footer_heights[si] = @as(f64, @floatFromInt(sg.notes.len)) * note_line_height + 16.0;
        } else {
            section_footer_heights[si] = 0;
        }
    }

    // Pass 1: Measure cell heights (merge-aware)
    var cell_heights = try allocator.alloc(f64, cells.items.len);
    defer allocator.free(cell_heights);

    for (cells.items, 0..) |cell, ci| {
        cell_heights[ci] = try mergeAwareHubHeight(&ctx, allocator, cell.hub_inst, cell.part);
    }

    // Compute row heights
    var row_heights = try allocator.alloc(f64, n_rows);
    defer allocator.free(row_heights);
    for (row_heights) |*rh| rh.* = 0;

    for (section_grid.items, 0..) |sg, si| {
        const grid_row = si / n_cols;
        var sec_height: f64 = 0;
        for (sg.cell_indices.items) |ci| {
            sec_height += cell_heights[ci] + 40.0;
        }
        const total = sec_height + section_pad * 2 + section_header_heights[si] + section_footer_heights[si];
        if (total > row_heights[grid_row]) row_heights[grid_row] = total;
    }

    // Compute row y-positions
    const row_y_positions = try allocator.alloc(f64, n_rows);
    defer allocator.free(row_y_positions);
    var y: f64 = top_margin;
    for (row_y_positions, 0..) |*ry, i| {
        ry.* = y;
        y += row_heights[i] + cell_gap_y;
    }

    var total_width: f64 = cell_width;
    if (n_cols > 1) {
        total_width = @as(f64, @floatFromInt(n_cols)) * cell_width + @as(f64, @floatFromInt(n_cols - 1)) * cell_gap_x;
    }

    // Pass 2: Collect scene graph data for each section
    for (section_grid.items, 0..) |sg, si| {
        if (sg.cell_indices.items.len == 0) continue;
        const grid_row = si / n_cols;
        const grid_col = si % n_cols;
        const x_offset = @as(f64, @floatFromInt(grid_col)) * (cell_width + cell_gap_x);
        const cell_y = row_y_positions[grid_row];
        const section_h = row_heights[grid_row];
        const header_h = section_header_heights[si];

        try scene.sections.append(allocator, .{
            .name = sg.name,
            .description = sg.description,
            .notes = sg.notes,
            .x = x_offset + 8.0,
            .y = cell_y,
            .w = cell_width - 16.0,
            .h = section_h,
        });

        var content_y = cell_y + header_h + section_pad;
        for (sg.cell_indices.items) |ci| {
            const cell = cells.items[ci];
            const h = cell_heights[ci];

            // Collect hub data
            var json_hub = try collectHubData(&ctx, allocator, cell.hub_inst, cell.part, x_offset, content_y, &alt_map, &asserted_fns);
            try scene.hubs.append(allocator, json_hub);

            // Collect connections for this hub
            try collectHubConnections(&ctx, &scene, allocator, cell.hub_inst, cell.part, x_offset, content_y, &json_hub);

            // Update the hub in the array with pin data
            scene.hubs.items[scene.hubs.items.len - 1] = json_hub;

            content_y += h + 40.0;
        }
    }

    // Port blocks (skipped — interface ports not shown in schematic)

    // Set viewBox
    scene.vb_w = @max(total_width, 850.0);
    scene.vb_h = @max(y + 40.0, 400.0);

    // Serialize to JSON
    return serializeScene(allocator, &scene);
}

fn countDir(ports: []const env_mod.Port, dir: []const u8) usize {
    var c: usize = 0;
    for (ports) |p| {
        if (std.mem.eql(u8, p.direction, dir)) c += 1;
    }
    return c;
}

fn countNonOut(ports: []const env_mod.Port) usize {
    var c: usize = 0;
    for (ports) |p| {
        if (!std.mem.eql(u8, p.direction, "out")) c += 1;
    }
    return c;
}

const BranchResult = struct { end_x: f64, cy: f64, terminal: []const u8 };
const Classified = struct { conn: AdjEntry, terminal: []const u8 };

// ── Hub data collection ──────────────────────────────────────────────

fn collectHubData(ctx: *RenderCtx, allocator: Allocator, hub: FlatInst, part: ?env_mod.Part, x_offset: f64, y_start: f64, alt_map: *PinoutAltMap, asserted_fns: *const std.StringHashMapUnmanaged([]const u8)) !JsonHub {
    loadPinoutAlts(allocator, alt_map, ctx.project_dir, hub.symbol);
    // Get pin groups (reuse hub.zig logic)
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

    var all_pins_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_pins_list.deinit(allocator);

    if (part) |p| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        for (p.pins) |pp| {
            if (!seen.contains(pp.pin)) {
                try seen.put(allocator, pp.pin, {});
                try all_pins_list.append(allocator, pp.pin);
            }
        }
    } else {
        for (ctx.nets.items) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    try all_pins_list.append(allocator, pin.pin);
                }
            }
        }
    }

    std.mem.sortUnstable([]const u8, all_pins_list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return draw.pinOrder(a, b);
        }
    }.lt);

    const parts_for_names: []const env_mod.Part = if (part) |p| &[_]env_mod.Part{p} else hub.parts;
    var pn_map = hub_mod.buildPinNameMap(ctx, parts_for_names);
    defer pn_map.deinit(allocator);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins_list.items, adj_entries, &pn_map);
    var left_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_pc: usize = 0;
    var right_pc: usize = 0;

    for (all_groups) |group| {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, group.pin_numbers, ',');
        while (it.next()) |_| n += 1;
        if (left_pc <= right_pc) {
            try left_groups_list.append(allocator, group);
            left_pc += n;
        } else {
            try right_groups_list.append(allocator, group);
            right_pc += n;
        }
    }

    const left_groups = left_groups_list.toOwnedSlice(allocator) catch &[_]PinGroup{};
    const right_groups = right_groups_list.toOwnedSlice(allocator) catch &[_]PinGroup{};
    const left_heights = try mergeAwareGroupHeights(ctx, allocator, left_groups, hub.ref_des);
    const right_heights = try mergeAwareGroupHeights(ctx, allocator, right_groups, hub.ref_des);

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;
    const hub_height = @max(left_total, right_total) + 40.0;

    const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ shortRef(hub.ref_des), displayValue(hub) });

    const icon = draw.classifyComponent(hub);

    var json_hub = JsonHub{
        .ref = hub.ref_des,
        .component = hub.component,
        .value = hub.value,
        .symbol = hub.symbol,
        .part = if (part) |p| p.name else null,
        .label = label,
        .x = x_offset + hub_x,
        .y = y_start,
        .w = hub_width,
        .h = hub_height,
        .icon = icon,
        .left_pins = .empty,
        .right_pins = .empty,
    };

    // Collect left pin positions
    var py_left = y_start + 40.0;
    for (left_groups, 0..) |group, gi| {
        const height = left_heights[gi];
        const pin_cy = py_left + height / 2.0;
        const enrich = pinEnrichment(allocator, group, hub.ref_des, hub.symbol, alt_map, asserted_fns);
        try json_hub.left_pins.append(allocator, .{
            .pin_numbers = group.pin_numbers,
            .display_name = group.display_name,
            .y = pin_cy,
            .side = "left",
            .alts = enrich.alts,
            .active_fn = enrich.active_fn,
        });
        py_left += height;
    }

    // Collect right pin positions
    var py_right = y_start + 40.0;
    for (right_groups, 0..) |group, gi| {
        const height = right_heights[gi];
        const pin_cy = py_right + height / 2.0;
        const enrich = pinEnrichment(allocator, group, hub.ref_des, hub.symbol, alt_map, asserted_fns);
        try json_hub.right_pins.append(allocator, .{
            .pin_numbers = group.pin_numbers,
            .display_name = group.display_name,
            .y = pin_cy,
            .side = "right",
            .alts = enrich.alts,
            .active_fn = enrich.active_fn,
        });
        py_right += height;
    }

    return json_hub;
}

const PinEnrichment = struct {
    alts: []const []const u8 = &.{},
    active_fn: []const u8 = "",
};

/// Return alt-function metadata for a single-pin group. Multi-pin groups get empty alts.
fn pinEnrichment(
    allocator: Allocator,
    group: PinGroup,
    ref_des: []const u8,
    symbol: []const u8,
    alt_map: *PinoutAltMap,
    asserted_fns: *const std.StringHashMapUnmanaged([]const u8),
) PinEnrichment {
    if (std.mem.indexOfScalar(u8, group.pin_numbers, ',')) |_| return .{};
    const pin_id = group.pin_numbers;

    var result = PinEnrichment{};
    if (alt_map.get(symbol)) |by_pin| {
        if (by_pin.get(pin_id)) |alts| result.alts = alts;
    }
    const key = std.fmt.allocPrint(allocator, "{s}|{s}", .{ ref_des, pin_id }) catch return result;
    if (asserted_fns.get(key)) |fn_name| result.active_fn = fn_name;
    return result;
}

// ── Connection collection ────────────────────────────────────────────

fn collectHubConnections(ctx: *RenderCtx, scene: *SceneGraph, allocator: Allocator, hub: FlatInst, part: ?env_mod.Part, x_offset: f64, y_start: f64, json_hub: *JsonHub) !void {
    _ = json_hub;
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

    var all_pins_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_pins_list.deinit(allocator);

    if (part) |p| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        for (p.pins) |pp| {
            if (!seen.contains(pp.pin)) {
                try seen.put(allocator, pp.pin, {});
                try all_pins_list.append(allocator, pp.pin);
            }
        }
    } else {
        for (ctx.nets.items) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    try all_pins_list.append(allocator, pin.pin);
                }
            }
        }
    }

    std.mem.sortUnstable([]const u8, all_pins_list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return draw.pinOrder(a, b);
        }
    }.lt);

    const parts_for_names: []const env_mod.Part = if (part) |p| &[_]env_mod.Part{p} else hub.parts;
    var pn_map = hub_mod.buildPinNameMap(ctx, parts_for_names);
    defer pn_map.deinit(allocator);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins_list.items, adj_entries, &pn_map);
    var left_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_pc: usize = 0;
    var right_pc: usize = 0;

    for (all_groups) |group| {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, group.pin_numbers, ',');
        while (it.next()) |_| n += 1;
        if (left_pc <= right_pc) {
            try left_groups_list.append(allocator, group);
            left_pc += n;
        } else {
            try right_groups_list.append(allocator, group);
            right_pc += n;
        }
    }

    const left_groups = left_groups_list.toOwnedSlice(allocator) catch &[_]PinGroup{};
    const right_groups = right_groups_list.toOwnedSlice(allocator) catch &[_]PinGroup{};
    const left_heights = try mergeAwareGroupHeights(ctx, allocator, left_groups, hub.ref_des);
    const right_heights = try mergeAwareGroupHeights(ctx, allocator, right_groups, hub.ref_des);

    // Collect left connections
    var py_left = y_start + 40.0;
    for (left_groups, 0..) |group, gi| {
        const height = left_heights[gi];
        const pin_cy = py_left + height / 2.0;
        const stub_x = x_offset + hub_x - pin_stub;
        try collectGroupConnections(ctx, scene, allocator, hub.ref_des, group, stub_x, pin_cy, .left);
        py_left += height;
    }

    // Collect right connections
    var py_right = y_start + 40.0;
    for (right_groups, 0..) |group, gi| {
        const height = right_heights[gi];
        const pin_cy = py_right + height / 2.0;
        const stub_x = x_offset + hub_x + hub_width + pin_stub;
        try collectGroupConnections(ctx, scene, allocator, hub.ref_des, group, stub_x, pin_cy, .right);
        py_right += height;
    }
}

fn collectGroupConnections(ctx: *RenderCtx, scene: *SceneGraph, allocator: Allocator, hub_ref: []const u8, group: PinGroup, stub_x: f64, py: f64, side: Side) !void {
    if (group.conns.len == 0) return;

    var first_pin_id: []const u8 = "";
    for (group.conns) |c| {
        first_pin_id = c.pin;
        break;
    }
    const canon_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ hub_ref, first_pin_id });
    const pin_net_name = ctx.pin_canonical_nets.get(canon_key) orelse "";

    var classified: std.ArrayListUnmanaged(Classified) = .empty;

    for (group.conns) |conn| {
        switch (conn.endpoint) {
            .net => |net| {
                const term = baseNetName(net);
                if (!ctx.significant_nets.contains(term)) continue;
                if (std.mem.eql(u8, term, baseNetName(pin_net_name))) {
                    var should_show = false;
                    if (ctx.port_nets.contains(term)) should_show = true;
                    if (!should_show) {
                        if (ctx.net_index.get(term)) |nps| {
                            const my_section = ctx.section_map.get(hub_ref);
                            for (nps.items) |np| {
                                if (ctx.rendered_spokes.contains(np.ref_des)) {
                                    should_show = true;
                                    break;
                                }
                                if (!ctx.spoke_set.contains(np.ref_des) and !std.mem.eql(u8, np.ref_des, hub_ref)) {
                                    should_show = true;
                                    break;
                                }
                                // Spoke in a different section: net crosses section boundaries,
                                // so the label belongs on this side of the crossing too.
                                if (ctx.spoke_set.contains(np.ref_des)) {
                                    const other_section = ctx.section_map.get(np.ref_des);
                                    if (my_section != null and other_section != null and my_section.? != other_section.?) {
                                        should_show = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if (!should_show) continue;
                }
                try classified.append(allocator, .{ .conn = conn, .terminal = term });
            },
            .pin => |p| {
                if (ctx.rendered_spokes.contains(p.ref_des)) continue;
                const term = try connection.getConnTerminal(ctx, conn.endpoint, hub_ref, conn.pin);
                try classified.append(allocator, .{ .conn = conn, .terminal = term });
            },
        }
    }

    if (classified.items.len == 0) return;

    std.mem.sortUnstable(Classified, classified.items, {}, struct {
        fn lt(_: void, a: Classified, b: Classified) bool {
            return std.mem.lessThan(u8, a.terminal, b.terminal);
        }
    }.lt);

    // Merge identical single-passive spokes to the same terminal (e.g. 5x 100nF decoupling caps to GND)
    const merged = try mergeIdenticalSpokes(ctx, allocator, classified.items, hub_ref);

    var slot_counts = try allocator.alloc(u32, merged.items.len);
    var total_slots: u32 = 0;
    for (merged.items, 0..) |entry, i| {
        const slots: u32 = if (entry.merge_count > 1) 1 else switch (entry.classified.conn.endpoint) {
            .pin => |p| blk: {
                if (ctx.spoke_set.contains(p.ref_des)) {
                    break :blk hub_mod.estimateBranchCount(ctx, p.ref_des, hub_ref);
                }
                break :blk 1;
            },
            .net => 1,
        };
        slot_counts[i] = slots;
        total_slots += slots;
    }

    const multi = merged.items.len > 1;
    const bus_offset: f64 = 10.0;
    const bus_x: f64 = switch (side) {
        .left => stub_x - bus_offset,
        .right => stub_x + bus_offset,
    };

    var consumed_slots: u32 = 0;
    var min_cy: f64 = py;
    var max_cy: f64 = py;
    const total_h2 = @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;

    var results: std.ArrayListUnmanaged(BranchResult) = .empty;

    for (merged.items, 0..) |entry, i| {
        const slots = slot_counts[i];
        const slot_center = @as(f64, @floatFromInt(consumed_slots)) + @as(f64, @floatFromInt(slots -| 1)) / 2.0;
        const cy = py + slot_center * per_conn_spacing - total_h2 / 2.0;
        consumed_slots += slots;
        if (cy < min_cy) min_cy = cy;
        if (cy > max_cy) max_cy = cy;

        const internal_net: []const u8 = switch (entry.classified.conn.endpoint) {
            .net => entry.classified.terminal,
            .pin => pin_net_name,
        };

        const conn_stub_x = if (multi) bus_x else stub_x;
        const conn_stub_y = if (multi) cy else py;

        if (entry.merge_count > 1) {
            const end_x = try collectMergedPassive(ctx, scene, allocator, entry.classified.conn.endpoint, hub_ref, entry.classified.conn.pin, conn_stub_x, conn_stub_y, cy, side, internal_net, entry.merge_count);
            try results.append(allocator, .{ .end_x = end_x, .cy = cy, .terminal = entry.classified.terminal });
        } else {
            const end_x = try collectConnBody(ctx, scene, allocator, entry.classified.conn.endpoint, hub_ref, entry.classified.conn.pin, conn_stub_x, conn_stub_y, cy, side, internal_net);
            try results.append(allocator, .{ .end_x = end_x, .cy = cy, .terminal = entry.classified.terminal });
        }
    }

    // Bus wires
    if (multi) {
        try scene.addWire(pin_net_name, stub_x, py, bus_x, py, false);
        if (min_cy != max_cy) {
            try scene.addWire(pin_net_name, bus_x, min_cy, bus_x, max_cy, true);
        }
    }

    // Terminal labels
    var default_term_x: f64 = switch (side) {
        .left => stub_x - spoke_len - 20.0,
        .right => stub_x + spoke_len + 20.0,
    };
    for (results.items) |r| {
        switch (side) {
            .left => default_term_x = @min(default_term_x, r.end_x - 20.0),
            .right => default_term_x = @max(default_term_x, r.end_x + 20.0),
        }
    }
    const term_x = default_term_x;

    try collectTerminals(ctx, scene, allocator, results.items, term_x, side);
}

const MergedEntry = struct {
    classified: Classified,
    merge_count: u32,
};

/// Find groups of identical single-passive spoke connections to the same terminal
/// and collapse them into one entry with a count (e.g. "5x 100nF" to GND).
fn mergeIdenticalSpokes(ctx: *RenderCtx, allocator: Allocator, classified: []const Classified, hub_ref: []const u8) !std.ArrayListUnmanaged(MergedEntry) {
    var result: std.ArrayListUnmanaged(MergedEntry) = .empty;

    // Build a key for each spoke connection: "terminal|value|symbol"
    // Non-spoke connections get unique keys so they never merge.
    const SpokeInfo = struct { key: []const u8, is_single_spoke: bool };
    var infos = try allocator.alloc(SpokeInfo, classified.len);
    var consumed = try allocator.alloc(bool, classified.len);
    for (consumed) |*c| c.* = false;

    for (classified, 0..) |entry, i| {
        switch (entry.conn.endpoint) {
            .pin => |p| {
                if (ctx.spoke_set.contains(p.ref_des)) {
                    const inst = ctx.inst_map.get(p.ref_des) orelse {
                        infos[i] = .{ .key = "", .is_single_spoke = false };
                        continue;
                    };
                    // Check it's a single passive (no chain)
                    var visited: std.StringHashMapUnmanaged(void) = .empty;
                    try visited.put(allocator, p.ref_des, {});
                    const chain = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = entry.conn.pin } }, &visited);
                    if (chain.chain.len == 0 and chain.branches.len == 0) {
                        // Single passive to terminal — mergeable
                        const val = if (inst.value.len > 0) inst.value else inst.component;
                        infos[i] = .{
                            .key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ entry.terminal, val, inst.symbol }),
                            .is_single_spoke = true,
                        };
                    } else {
                        infos[i] = .{ .key = "", .is_single_spoke = false };
                    }
                } else {
                    infos[i] = .{ .key = "", .is_single_spoke = false };
                }
            },
            .net => {
                infos[i] = .{ .key = "", .is_single_spoke = false };
            },
        }
    }

    // Group by key
    for (classified, 0..) |entry, i| {
        if (consumed[i]) continue;
        if (!infos[i].is_single_spoke or infos[i].key.len == 0) {
            try result.append(allocator, .{ .classified = entry, .merge_count = 1 });
            consumed[i] = true;
            continue;
        }
        // Count identical entries
        var count: u32 = 1;
        for (classified[i + 1 ..], i + 1..) |_, j| {
            if (consumed[j]) continue;
            if (infos[j].is_single_spoke and std.mem.eql(u8, infos[j].key, infos[i].key)) {
                count += 1;
                consumed[j] = true;
                // Mark the merged spoke as rendered so SVG renderer doesn't re-draw
                switch (classified[j].conn.endpoint) {
                    .pin => |p2| try ctx.rendered_spokes.put(allocator, p2.ref_des, {}),
                    .net => {},
                }
            }
        }
        try result.append(allocator, .{ .classified = entry, .merge_count = count });
        consumed[i] = true;
    }

    return result;
}

/// Render a merged passive: one symbol with "Nx value" label.
fn collectMergedPassive(ctx: *RenderCtx, scene: *SceneGraph, allocator: Allocator, endpoint: Endpoint, hub_ref: []const u8, from_pin: []const u8, stub_x: f64, stub_y: f64, cy: f64, side: Side, net_name: []const u8, count: u32) !f64 {
    switch (endpoint) {
        .net => {
            const end_x: f64 = switch (side) {
                .left => stub_x - 20.0,
                .right => stub_x + 20.0,
            };
            try scene.addWire(net_name, stub_x, stub_y, end_x, cy, false);
            return end_x;
        },
        .pin => |p| {
            const inst = ctx.inst_map.get(p.ref_des) orelse return stub_x;
            try ctx.rendered_spokes.put(allocator, p.ref_des, {});

            switch (side) {
                .left => {
                    try scene.addWire(net_name, stub_x, stub_y, stub_x - 20.0, cy, false);
                    try scene.addPassiveWithCount(inst, stub_x - 20.0 - passive_bw, cy, count);
                    const chain_end_x = stub_x - 20.0 - passive_bw;
                    // Find the terminal
                    var visited: std.StringHashMapUnmanaged(void) = .empty;
                    try visited.put(allocator, p.ref_des, {});
                    const chain = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);
                    _ = chain;
                    return chain_end_x;
                },
                .right => {
                    try scene.addWire(net_name, stub_x, stub_y, stub_x + 20.0, cy, false);
                    try scene.addPassiveWithCount(inst, stub_x + 20.0, cy, count);
                    const chain_end_x = stub_x + 20.0 + passive_bw;
                    var visited: std.StringHashMapUnmanaged(void) = .empty;
                    try visited.put(allocator, p.ref_des, {});
                    const chain = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);
                    _ = chain;
                    return chain_end_x;
                },
            }
        },
    }
}

fn collectConnBody(ctx: *RenderCtx, scene: *SceneGraph, allocator: Allocator, endpoint: Endpoint, hub_ref: []const u8, from_pin: []const u8, stub_x: f64, stub_y: f64, cy: f64, side: Side, net_name: []const u8) !f64 {
    switch (endpoint) {
        .net => {
            const end_x: f64 = switch (side) {
                .left => stub_x - 20.0,
                .right => stub_x + 20.0,
            };
            try scene.addWire(net_name, stub_x, stub_y, end_x, cy, false);
            return end_x;
        },
        .pin => |p| {
            if (ctx.spoke_set.contains(p.ref_des)) {
                if (ctx.rendered_spokes.contains(p.ref_des)) {
                    return stub_x;
                }

                const inst = ctx.inst_map.get(p.ref_des) orelse return stub_x;
                try ctx.rendered_spokes.put(allocator, p.ref_des, {});

                var visited: std.StringHashMapUnmanaged(void) = .empty;
                try visited.put(allocator, p.ref_des, {});
                const chain_result = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);

                for (chain_result.chain) |c| {
                    try ctx.rendered_spokes.put(allocator, c.ref_des, {});
                }

                var all_spokes: std.ArrayListUnmanaged(FlatInst) = .empty;
                try all_spokes.append(allocator, inst);
                for (chain_result.chain) |c| try all_spokes.append(allocator, c);

                switch (side) {
                    .left => {
                        try scene.addWire(net_name, stub_x, stub_y, stub_x - 20.0, cy, false);
                        const chain_end_x = try collectPassiveChainLeft(scene, allocator, stub_x - 20.0, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try collectBranchTreeLeft(ctx, scene, allocator, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                    .right => {
                        try scene.addWire(net_name, stub_x, stub_y, stub_x + 20.0, cy, false);
                        const chain_end_x = try collectPassiveChainRight(scene, allocator, stub_x + 20.0, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try collectBranchTreeRight(ctx, scene, allocator, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                }
            } else {
                const end_x: f64 = switch (side) {
                    .left => stub_x - spoke_len - 20.0,
                    .right => stub_x + spoke_len + 20.0,
                };
                try scene.addWire(net_name, stub_x, stub_y, end_x, cy, false);
                return end_x;
            }
        },
    }
}

fn collectPassiveChainLeft(scene: *SceneGraph, _: Allocator, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try scene.addWire("", x, cy, x - 20.0, cy, false);
            x -= 20.0;
        }
        try scene.addPassive(inst, x - passive_bw, cy);
        x -= passive_bw;
    }
    return x;
}

fn collectPassiveChainRight(scene: *SceneGraph, allocator: Allocator, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    _ = allocator;
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try scene.addWire("", x, cy, x + 20.0, cy, false);
            x += 20.0;
        }
        try scene.addPassive(inst, x, cy);
        x += passive_bw;
    }
    return x;
}

fn collectBranchTreeLeft(ctx: *RenderCtx, scene: *SceneGraph, allocator: Allocator, junction_x: f64, center_y: f64, branches: []const ctx_mod.Branch, junction_net: []const u8) !void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / 2.0;

    const bx = junction_x - bus_gap;
    try scene.addWire(junction_net, junction_x, center_y, bx, center_y, false);
    if (n > 1) {
        try scene.addWire(junction_net, bx, start_y, bx, start_y + total_height, true);
    }

    const BranchBody = struct { end_x: f64, cy: f64, terminal: []const u8 };
    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try scene.addWire(junction_net, bx, by, bx - 10.0, by, false);
        const chain_end_x = try collectPassiveChainLeft(scene, allocator, bx - 10.0, by, branch.chain);
        try bodies.append(allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    // Terminals
    var term_x: f64 = 0;
    for (bodies.items) |b| {
        const tx = b.end_x - 20.0;
        if (term_x == 0 or tx < term_x) term_x = tx;
    }
    for (bodies.items) |b| {
        try scene.addWire(b.terminal, b.end_x, b.cy, term_x, b.cy, false);
    }
    if (bodies.items.len > 0) {
        const last = bodies.items[bodies.items.len - 1];
        try collectTerminalLabel(ctx, scene, term_x, last.cy, last.terminal, "end");
    }
}

fn collectBranchTreeRight(ctx: *RenderCtx, scene: *SceneGraph, allocator: Allocator, junction_x: f64, center_y: f64, branches: []const ctx_mod.Branch, junction_net: []const u8) !void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / 2.0;

    const bx = junction_x + bus_gap;
    try scene.addWire(junction_net, junction_x, center_y, bx, center_y, false);
    if (n > 1) {
        try scene.addWire(junction_net, bx, start_y, bx, start_y + total_height, true);
    }

    const BranchBody = struct { end_x: f64, cy: f64, terminal: []const u8 };
    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try scene.addWire(junction_net, bx, by, bx + 10.0, by, false);
        const chain_end_x = try collectPassiveChainRight(scene, allocator, bx + 10.0, by, branch.chain);
        try bodies.append(allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    var term_x: f64 = 0;
    for (bodies.items) |b| {
        const tx = b.end_x + 20.0;
        if (term_x == 0 or tx > term_x) term_x = tx;
    }
    for (bodies.items) |b| {
        try scene.addWire(b.terminal, b.end_x, b.cy, term_x, b.cy, false);
    }
    if (bodies.items.len > 0) {
        const last = bodies.items[bodies.items.len - 1];
        try collectTerminalLabel(ctx, scene, term_x, last.cy, last.terminal, "start");
    }
}

fn collectTerminals(ctx: *RenderCtx, scene: *SceneGraph, _: Allocator, results: []const BranchResult, term_x: f64, side: Side) !void {
    if (results.len == 0) return;

    const anchor: []const u8 = switch (side) {
        .left => "end",
        .right => "start",
    };

    var i: usize = 0;
    while (i < results.len) {
        const term = results[i].terminal;
        var j = i + 1;
        while (j < results.len) : (j += 1) {
            if (!std.mem.eql(u8, results[j].terminal, term)) break;
        }
        const group_slice = results[i..j];

        if (!ctx.significant_nets.contains(term)) {
            i = j;
            continue;
        }

        if (group_slice.len == 1) {
            const r = group_slice[0];
            try scene.addWire(term, r.end_x, r.cy, term_x, r.cy, false);
            try collectTerminalLabel(ctx, scene, term_x, r.cy, term, anchor);
        } else {
            const nearest_x = blk: {
                var nx: f64 = switch (side) {
                    .left => 99999.0,
                    .right => -99999.0,
                };
                for (group_slice) |r| {
                    switch (side) {
                        .left => nx = @min(nx, r.end_x),
                        .right => nx = @max(nx, r.end_x),
                    }
                }
                break :blk nx;
            };
            const grp_bus_x = switch (side) {
                .left => nearest_x - 20.0,
                .right => nearest_x + 20.0,
            };

            const first_cy = group_slice[0].cy;
            const last_cy = group_slice[group_slice.len - 1].cy;

            for (group_slice) |r| {
                try scene.addWire(term, r.end_x, r.cy, grp_bus_x, r.cy, false);
            }
            try scene.addWire(term, grp_bus_x, first_cy, grp_bus_x, last_cy, true);
            try scene.addWire(term, grp_bus_x, last_cy, term_x, last_cy, false);
            try collectTerminalLabel(ctx, scene, term_x, last_cy, term, anchor);
        }

        i = j;
    }
}

fn collectTerminalLabel(ctx: *RenderCtx, scene: *SceneGraph, end_x: f64, cy: f64, term: []const u8, anchor: []const u8) !void {
    const display = baseNetName(term);
    if (isGroundNet(display)) {
        try scene.addLabel(display, end_x, cy, anchor, false, true);
    } else {
        const is_port = ctx.port_nets.contains(term) or ctx.port_nets.contains(display);
        const label_x: f64 = if (std.mem.eql(u8, anchor, "end")) end_x - net_label_gap else end_x + net_label_gap;
        try scene.addLabel(display, label_x, cy, anchor, is_port, false);
    }
}

// ── Port block collection ────────────────────────────────────────────

fn collectPortBlock(scene: *SceneGraph, allocator: Allocator, name: []const u8, ports: []const env_mod.Port, y_start: f64, icon: ?[]const u8) !void {
    var left_count: usize = 0;
    var right_count: usize = 0;
    for (ports) |port| {
        if (std.mem.eql(u8, port.direction, "out")) {
            right_count += 1;
        } else {
            left_count += 1;
        }
    }

    const port_spacing: f64 = 40.0;
    const box_pad: f64 = 40.0;
    const max_side = @max(@max(left_count, right_count), 1);
    const block_height = box_pad * 2.0 + @as(f64, @floatFromInt(max_side - 1)) * port_spacing;

    var port_block = JsonPortBlock{
        .name = name,
        .x = hub_x,
        .y = y_start,
        .w = hub_width,
        .h = block_height,
        .icon = icon,
        .ports = .empty,
    };

    var left_idx: usize = 0;
    var right_idx: usize = 0;
    for (ports) |port| {
        const is_output = std.mem.eql(u8, port.direction, "out");
        const idx = if (is_output) right_idx else left_idx;
        const py = y_start + box_pad + @as(f64, @floatFromInt(idx)) * port_spacing;

        try port_block.ports.append(allocator, .{
            .name = port.name,
            .net = port.net,
            .direction = port.direction,
            .y = py,
            .rated_min = port.rated_min,
            .rated_max = port.rated_max,
        });

        if (is_output) {
            right_idx += 1;
        } else {
            left_idx += 1;
        }
    }

    try scene.port_blocks.append(allocator, port_block);
}

// ── JSON Serialization ───────────────────────────────────────────────

fn serializeScene(allocator: Allocator, scene: *const SceneGraph) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeAll("{");

    // ViewBox
    try w.print("\"viewBox\":{{\"w\":{d:.0},\"h\":{d:.0}}}", .{ scene.vb_w, scene.vb_h });
    try w.print(",\"name\":\"{s}\"", .{scene.design_name});

    // Sections
    try w.writeAll(",\"sections\":[");
    for (scene.sections.items, 0..) |sec, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "name", sec.name);
        try w.writeAll(",");
        try writeJsonString(w, "description", sec.description);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1}", .{ sec.x, sec.y, sec.w, sec.h });
        try w.writeAll(",\"notes\":[");
        for (sec.notes, 0..) |note, ni| {
            if (ni > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeEscaped(w, note);
            try w.writeAll("\"");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Hubs
    try w.writeAll(",\"hubs\":[");
    for (scene.hubs.items, 0..) |h, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "ref", h.ref);
        try w.writeAll(",");
        try writeJsonString(w, "component", h.component);
        try w.writeAll(",");
        try writeJsonString(w, "value", h.value);
        try w.writeAll(",");
        try writeJsonString(w, "symbol", h.symbol);
        try w.writeAll(",");
        if (h.part) |p| {
            try writeJsonString(w, "part", p);
        } else {
            try w.writeAll("\"part\":null");
        }
        try w.writeAll(",");
        try writeJsonString(w, "label", h.label);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.0},\"h\":{d:.1}", .{ h.x, h.y, h.w, h.h });
        if (h.icon) |ic| {
            try w.writeAll(",");
            try writeJsonString(w, "icon", ic);
        } else {
            try w.writeAll(",\"icon\":null");
        }

        // Left pins
        try w.writeAll(",\"leftPins\":[");
        for (h.left_pins.items, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try writeJsonPin(w, pin);
        }
        try w.writeAll("]");

        // Right pins
        try w.writeAll(",\"rightPins\":[");
        for (h.right_pins.items, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try writeJsonPin(w, pin);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Wires
    try w.writeAll(",\"wires\":[");
    for (scene.wires.items, 0..) |wire, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "net", wire.net);
        try w.print(",\"bus\":{s}", .{if (wire.is_bus) "true" else "false"});
        try w.writeAll(",\"points\":[");
        for (wire.points.items, 0..) |pt, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.print("[{d:.1},{d:.1}]", .{ pt[0], pt[1] });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Passives
    try w.writeAll(",\"passives\":[");
    for (scene.passives.items, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "ref", p.ref);
        try w.writeAll(",");
        try writeJsonString(w, "component", p.component);
        try w.writeAll(",");
        try writeJsonString(w, "value", p.value);
        try w.writeAll(",");
        try writeJsonString(w, "symbol", p.symbol);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1},\"count\":{d}", .{ p.x, p.y, p.w, p.h, p.count });
        try w.writeAll("}");
    }
    try w.writeAll("]");

    // Labels
    try w.writeAll(",\"labels\":[");
    for (scene.labels.items, 0..) |l, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "text", l.text);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1}", .{ l.x, l.y });
        try w.writeAll(",");
        try writeJsonString(w, "anchor", l.anchor);
        try w.print(",\"port\":{s},\"ground\":{s}", .{
            if (l.is_port) "true" else "false",
            if (l.is_ground) "true" else "false",
        });
        try w.writeAll("}");
    }
    try w.writeAll("]");

    // Port blocks
    try w.writeAll(",\"portBlocks\":[");
    for (scene.port_blocks.items, 0..) |pb, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "name", pb.name);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.0},\"h\":{d:.1}", .{ pb.x, pb.y, pb.w, pb.h });
        if (pb.icon) |ic| {
            try w.writeAll(",");
            try writeJsonString(w, "icon", ic);
        } else {
            try w.writeAll(",\"icon\":null");
        }
        try w.writeAll(",\"ports\":[");
        for (pb.ports.items, 0..) |port, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("{");
            try writeJsonString(w, "name", port.name);
            try w.writeAll(",");
            try writeJsonString(w, "net", port.net);
            try w.writeAll(",");
            try writeJsonString(w, "direction", port.direction);
            try w.print(",\"y\":{d:.1}", .{port.y});
            if (port.rated_min) |rm| {
                try w.print(",\"ratedMin\":{d:.2}", .{rm});
            }
            if (port.rated_max) |rm| {
                try w.print(",\"ratedMax\":{d:.2}", .{rm});
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

const writeJsonString = json_writer.writeField;

fn writeJsonPin(w: anytype, pin: JsonPin) !void {
    try w.writeAll("{");
    try writeJsonString(w, "pins", pin.pin_numbers);
    try w.writeAll(",");
    try writeJsonString(w, "name", pin.display_name);
    try w.print(",\"y\":{d:.1}", .{pin.y});
    if (pin.active_fn.len > 0) {
        try w.writeAll(",");
        try writeJsonString(w, "activeFn", pin.active_fn);
    }
    if (pin.alts.len > 0) {
        try w.writeAll(",\"alts\":[");
        for (pin.alts, 0..) |alt, ai| {
            if (ai > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeEscaped(w, alt);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");
}

const writeEscaped = json_writer.writeEscaped;
