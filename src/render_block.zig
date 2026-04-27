const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const types = @import("render_block_types.zig");

const Allocator = std.mem.Allocator;

/// Error set for block-diagram JSON emission — uses an
/// `ArrayListUnmanaged(u8)` writer; only `OutOfMemory` propagates.
pub const RenderError = std.mem.Allocator.Error;

const Block = types.Block;
const Edge = types.Edge;
const block_w = types.block_w;
const block_min_h = types.block_min_h;
const line_h = types.line_h;
const block_pad = types.block_pad;
const grid_gap_x = types.grid_gap_x;
const grid_gap_y = types.grid_gap_y;
const margin = types.margin_val;
const top_margin = types.top_margin;
const arrow_size = types.arrow_size;

// ── Layout constants ──────────────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const EDGE_SPACING_LIMIT: f64 = 20.0;
const SECTION_LABEL_OFFSET: f64 = 30.0;
const COLUMN_LABEL_OFFSET: f64 = 24.0;

// ── Repeated string literals ──────────────────────────────────────
const PIN_KEY_FMT: []const u8 = "{s}\x00{s}";

// ── Shared: build blocks from design sections ────────────────────────

const BuildResult = struct {
    blocks: std.ArrayListUnmanaged(Block),
    hub_idx: ?usize,
};

fn buildBlocksFromDesign(allocator: Allocator, design: *const DesignBlock) !BuildResult {
    var blocks: std.ArrayListUnmanaged(Block) = .empty;
    var hub_idx: ?usize = null;

    for (design.sections) |sec| {
        if (sec.sub_sections.len > 0) {
            var key_comp: []const u8 = sec.description;
            if (key_comp.len == 0) {
                for (design.instances) |inst| {
                    if (inst.ref_des.len > 0 and inst.ref_des[0] == 'U') {
                        key_comp = inst.component;
                        break;
                    }
                }
            }
            var hub_detail_buf: std.ArrayListUnmanaged(u8) = .empty;
            const hdw = hub_detail_buf.writer(allocator);
            var io_protocols: std.ArrayListUnmanaged([]const u8) = .empty;
            for (design.sections) |other| {
                if (other.sub_sections.len > 0) continue;
                for (other.protocols) |proto| {
                    if (!types.strInList(io_protocols.items, proto))
                        try io_protocols.append(allocator, proto);
                }
                for (other.ports) |p| {
                    if (p.protocol.len > 0 and !types.strInList(io_protocols.items, p.protocol))
                        try io_protocols.append(allocator, p.protocol);
                }
            }
            for (io_protocols.items, 0..) |proto, i| {
                if (i > 0) try hdw.writeAll(", ");
                try hdw.writeAll(proto);
            }

            hub_idx = blocks.items.len;
            try blocks.append(allocator, .{
                .title = sec.name,
                .subtitle = key_comp,
                .detail = if (hub_detail_buf.items.len > 0)
                    (try allocator.dupe(u8, hub_detail_buf.items))
                else
                    (if (sec.description.len > 0) sec.description else ""),
                .category = .mcu,
                .ports = sec.ports,
                .protocols = sec.protocols,
                .status = sec.status,
                .block_role = sec.block_role,
                .has_ic = true,
            });
            continue;
        }
        const cat = types.classifySection(sec);
        const key_comp = types.findKeyComponent(sec);

        var detail_buf: std.ArrayListUnmanaged(u8) = .empty;
        const dw = detail_buf.writer(allocator);
        if (sec.description.len > 0) {
            try dw.writeAll(sec.description);
        } else {
            for (sec.protocols) |proto| {
                if (detail_buf.items.len > 0) try dw.writeAll(", ");
                try dw.writeAll(proto);
            }
            for (sec.ports) |p| {
                if (p.protocol.len > 0) {
                    if (detail_buf.items.len > 0) try dw.writeAll(", ");
                    try dw.writeAll(p.protocol);
                }
            }
        }
        for (sec.calcs) |calc| {
            for (calc.results) |r| {
                if (detail_buf.items.len > 0) try dw.writeAll(" | ");
                try dw.print("{s}={d:.1}", .{ r.name, r.value });
            }
        }

        // Determine if section has a power-consuming IC or provides power to a sub-block.
        // 1. Section has a U-prefix IC AND declares power ports → power consumer
        // 2. Section has an instance on a sub-block power input net → power source
        var sec_has_ic = false;
        // Case 1: IC with power ports
        if (!sec_has_ic) {
            var has_power_port = false;
            for (sec.ports) |p| {
                if (p.signal_type == .power) {
                    has_power_port = true;
                    break;
                }
            }
            if (has_power_port) {
                for (sec.instances) |inst| {
                    if (inst.ref_des.len > 0 and inst.ref_des[0] == 'U') {
                        sec_has_ic = true;
                        break;
                    }
                }
            }
        }
        // Case 2: instance provides power to a sub-block input
        if (!sec_has_ic) {
            sb_check: for (design.sub_blocks) |sb| {
                for (sb.block.ports) |p| {
                    if (!std.mem.eql(u8, p.direction, "in")) continue;
                    const is_rated = p.rated_max != null or p.rated_min != null or p.nominal != null;
                    if (!is_rated) continue;
                    // Find the net for this sub-block port
                    for (design.nets) |net| {
                        if (!std.mem.eql(u8, net.name, p.net)) continue;
                        // Check if any section instance is on this net
                        for (net.pins) |pin_ref| {
                            for (sec.instances) |inst| {
                                if (std.mem.eql(u8, pin_ref.ref_des, inst.ref_des)) {
                                    sec_has_ic = true;
                                    break :sb_check;
                                }
                            }
                        }
                    }
                }
            }
        }
        try blocks.append(allocator, .{
            .title = sec.name,
            .subtitle = key_comp,
            .detail = if (detail_buf.items.len > 0) (try allocator.dupe(u8, detail_buf.items)) else "",
            .category = cat,
            .ports = sec.ports,
            .protocols = sec.protocols,
            .status = sec.status,
            .block_role = sec.block_role,
            .has_ic = sec_has_ic,
        });
    }
    return .{ .blocks = blocks, .hub_idx = hub_idx };
}

// ── Shared: build edges from topology ────────────────────────────────

fn buildEdgesFromTopology(
    allocator: Allocator,
    blocks: []const Block,
    _: *const DesignBlock,
    hub_idx: ?usize,
) !std.ArrayListUnmanaged(Edge) {
    var edges: std.ArrayListUnmanaged(Edge) = .empty;

    // 1. Power chain edges: connect output→input by port name.
    //    For power rails, only show chain links (blocks that transform rail)
    //    + the MCU if it explicitly has that input port.
    for (blocks, 0..) |src, si| {
        for (src.ports) |sp| {
            if (sp.direction != .out) continue;

            if (sp.signal_type == .power or sp.signal_type == .clock) {
                for (blocks, 0..) |dst, di| {
                    if (si == di) continue;
                    var consumes = false;
                    for (dst.ports) |dp| {
                        if (dp.direction != .out and std.mem.eql(u8, sp.name, dp.name)) {
                            consumes = true;
                            break;
                        }
                    }
                    if (!consumes) continue;
                    // Only connect to chain links (has different power output) or the MCU
                    var is_chain = false;
                    for (dst.ports) |dp| {
                        if (dp.direction == .out and (dp.signal_type == .power or dp.signal_type == .clock) and !std.mem.eql(u8, dp.name, sp.name)) {
                            is_chain = true;
                            break;
                        }
                    }
                    const is_mcu = if (hub_idx) |hi| di == hi else false;
                    if (is_chain or is_mcu) {
                        if (!types.edgeExists(edges.items, si, di, sp.name))
                            try edges.append(allocator, .{ .from = si, .to = di, .label = sp.name, .signal_type = sp.signal_type, .voltage = sp.voltage });
                    }
                }
            } else {
                // Non-power: connect to all matching consumers
                for (blocks, 0..) |dst, di| {
                    if (si == di) continue;
                    for (dst.ports) |dp| {
                        if (dp.direction == .out) continue;
                        if (std.mem.eql(u8, sp.name, dp.name) and !types.edgeExists(edges.items, si, di, sp.name))
                            try edges.append(allocator, .{ .from = si, .to = di, .label = sp.name, .signal_type = sp.signal_type, .voltage = sp.voltage });
                    }
                }
            }
        }
    }

    // 2. Protocol edges from MCU sub-sections to peripherals
    if (hub_idx) |hi| {
        for (blocks, 0..) |blk, bi| {
            if (bi == hi) continue;
            for (blk.protocols) |proto| {
                if (!types.edgeExists(edges.items, hi, bi, proto) and
                    !types.edgeExists(edges.items, bi, hi, proto))
                    try edges.append(allocator, .{ .from = hi, .to = bi, .label = proto, .signal_type = .data, .voltage = null });
            }
        }
        for (blocks, 0..) |blk, bi| {
            if (bi == hi) continue;
            for (blk.ports) |p| {
                if (p.direction == .io and p.protocol.len > 0 and
                    !types.edgeExists(edges.items, hi, bi, p.protocol) and
                    !types.edgeExists(edges.items, bi, hi, p.protocol))
                    try edges.append(allocator, .{ .from = hi, .to = bi, .label = p.protocol, .signal_type = p.signal_type, .voltage = null });
            }
        }
    }

    // 3. De-orphan: connect orphans to block with most shared non-power port names
    for (blocks, 0..) |blk, bi| {
        var has_edge = false;
        for (edges.items) |edge| {
            if (edge.from == bi or edge.to == bi) {
                has_edge = true;
                break;
            }
        }
        if (has_edge) continue;

        // Find block with most shared non-power port names (excluding GND)
        var best_match: ?usize = null;
        var best_count: usize = 0;
        for (blocks, 0..) |other, oi| {
            if (oi == bi) continue;
            var count: usize = 0;
            for (blk.ports) |p| {
                if (std.mem.eql(u8, p.name, "GND")) continue;
                if (p.signal_type == .power) continue;
                for (other.ports) |op| {
                    if (std.mem.eql(u8, p.name, op.name)) {
                        count += 1;
                        break;
                    }
                }
            }
            if (count > best_count) {
                best_count = count;
                best_match = oi;
            }
        }
        // Fall back to MCU hub if no shared ports found
        const target = best_match orelse (hub_idx orelse continue);
        var best_port: ?env_mod.SectionPort = null;
        for (blk.ports) |p| {
            if (std.mem.eql(u8, p.name, "GND")) continue;
            if (p.signal_type == .power) continue;
            if (best_port == null) best_port = p;
        }
        const label = if (best_port) |p| p.name else blk.title;
        const sig = if (best_port) |p| p.signal_type else env_mod.SignalType.signal;
        const volt = if (best_port) |p| p.voltage else null;
        try edges.append(allocator, .{ .from = target, .to = bi, .label = label, .signal_type = sig, .voltage = volt });
    }

    return edges;
}

// ── Shared: layered graph layout ─────────────────────────────────────

fn layoutBlockPositions(allocator: Allocator, blocks: []Block, edges: []const Edge) !void {
    const n = blocks.len;
    if (n == 0) return;

    // 1. Compute block heights based on title + ports
    const port_line_h: f64 = 18.0;
    for (blocks) |*blk| {
        var n_lines: f64 = 1;
        if (blk.subtitle.len > 0) n_lines += 1;
        if (blk.detail.len > 0) n_lines += 1;
        const title_h = n_lines * line_h;
        // Count visible ports (same filter as JSON serialization)
        var blk_has_power_out = false;
        var blk_has_non_power = blk.protocols.len > 0;
        for (blk.ports) |p| {
            if (std.mem.eql(u8, p.name, "GND")) continue;
            if (p.signal_type == .power and p.direction == .out) blk_has_power_out = true;
            if (p.signal_type != .power) blk_has_non_power = true;
        }
        const blk_hide_pwr_in = blk_has_non_power and !blk_has_power_out;
        var in_count: f64 = 0;
        var out_count: f64 = 0;
        for (blk.ports) |p| {
            if (std.mem.eql(u8, p.name, "GND")) continue;
            if (blk_hide_pwr_in and p.signal_type == .power and p.direction != .out) continue;
            if (p.direction == .out) out_count += 1 else in_count += 1;
        }
        // Add protocols to output side count
        out_count += @floatFromInt(blk.protocols.len);
        const port_h = @max(in_count, out_count) * port_line_h;
        const symbol_h: f64 = 20.0;
        blk.h = @max(block_min_h, symbol_h + title_h + port_h + block_pad * 2 + 8);
    }

    // 2. Assign layers via longest-path from sources
    var layers = try allocator.alloc(usize, n);
    @memset(layers, 0);
    var in_degree = try allocator.alloc(usize, n);
    @memset(in_degree, 0);
    for (edges) |e| {
        in_degree[e.to] += 1;
    }

    // BFS from sources in topological order
    var queue: std.ArrayListUnmanaged(usize) = .empty;
    for (0..n) |i| {
        if (in_degree[i] == 0) try queue.append(allocator, i);
    }
    var processed: usize = 0;
    while (processed < queue.items.len) {
        const cur = queue.items[processed];
        processed += 1;
        for (edges) |e| {
            if (e.from == cur) {
                layers[e.to] = @max(layers[e.to], layers[cur] + 1);
                // Decrement in-degree copy for BFS ordering
                var found = false;
                for (queue.items) |q| {
                    if (q == e.to) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    // Check if all predecessors processed
                    var all_pred = true;
                    for (edges) |e2| {
                        if (e2.to == e.to) {
                            var pred_done = false;
                            for (queue.items[0..processed]) |q| {
                                if (q == e2.from) {
                                    pred_done = true;
                                    break;
                                }
                            }
                            if (!pred_done) {
                                all_pred = false;
                                break;
                            }
                        }
                    }
                    if (all_pred) try queue.append(allocator, e.to);
                }
            }
        }
    }
    // Handle nodes not reached by BFS (cycles or disconnected)
    var max_layer: usize = 0;
    for (layers) |l| max_layer = @max(max_layer, l);
    for (0..n) |i| {
        var in_queue = false;
        for (queue.items) |q| {
            if (q == i) {
                in_queue = true;
                break;
            }
        }
        if (!in_queue) layers[i] = max_layer + 1;
    }
    // Recompute max_layer
    max_layer = 0;
    for (layers) |l| max_layer = @max(max_layer, l);

    // 3. Group blocks by layer
    const num_layers = max_layer + 1;
    var layer_lists = try allocator.alloc(std.ArrayListUnmanaged(usize), num_layers);
    for (layer_lists) |*ll| ll.* = .empty;
    for (0..n) |i| {
        try layer_lists[layers[i]].append(allocator, i);
    }

    // Initial ordering: by category sort order
    const CatSortCtx = struct {
        blocks: []const Block,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return types.categorySortOrder(ctx.blocks[a].category) < types.categorySortOrder(ctx.blocks[b].category);
        }
    };
    for (layer_lists) |*ll| {
        std.mem.sort(usize, ll.items, CatSortCtx{ .blocks = blocks }, CatSortCtx.lessThan);
    }

    // 4. Barycenter ordering (4 passes)
    const PosSortCtx = struct {
        pos: []const f64,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.pos[a] < ctx.pos[b];
        }
    };
    var positions = try allocator.alloc(f64, n);
    for (0..n) |i| positions[i] = 0;

    for (0..4) |pass| {
        if (pass % 2 == 0) {
            // Forward pass
            for (1..num_layers) |l| {
                for (layer_lists[l].items) |bi| {
                    var sum: f64 = 0;
                    var count: f64 = 0;
                    for (edges) |e| {
                        if (e.to == bi and layers[e.from] == l - 1) {
                            sum += positions[e.from];
                            count += 1;
                        }
                        if (e.from == bi and layers[e.to] == l - 1) {
                            sum += positions[e.to];
                            count += 1;
                        }
                    }
                    if (count > 0) positions[bi] = sum / count;
                }
                // Sort layer by barycenter position
                std.mem.sort(usize, layer_lists[l].items, PosSortCtx{ .pos = positions }, PosSortCtx.lessThan);
                // Update positions to reflect new order
                for (layer_lists[l].items, 0..) |bi, idx| {
                    positions[bi] = @floatFromInt(idx);
                }
            }
        } else {
            // Backward pass
            var l: usize = if (num_layers > 1) num_layers - 2 else 0;
            while (true) {
                for (layer_lists[l].items) |bi| {
                    var sum: f64 = 0;
                    var count: f64 = 0;
                    for (edges) |e| {
                        if (e.from == bi and layers[e.to] == l + 1) {
                            sum += positions[e.to];
                            count += 1;
                        }
                        if (e.to == bi and layers[e.from] == l + 1) {
                            sum += positions[e.from];
                            count += 1;
                        }
                    }
                    if (count > 0) positions[bi] = sum / count;
                }
                std.mem.sort(usize, layer_lists[l].items, PosSortCtx{ .pos = positions }, PosSortCtx.lessThan);
                for (layer_lists[l].items, 0..) |bi, idx| {
                    positions[bi] = @floatFromInt(idx);
                }
                if (l == 0) break;
                l -= 1;
            }
        }
    }

    // 5. Position blocks
    for (0..num_layers) |l| {
        const x = @as(f64, @floatFromInt(l)) * (block_w + grid_gap_x) + margin;
        var cy: f64 = top_margin;
        for (layer_lists[l].items) |bi| {
            blocks[bi].x = x;
            blocks[bi].y = cy;
            blocks[bi].col = l;
            cy += blocks[bi].h + grid_gap_y;
        }
    }
}

// ── Power section: column-based layout ───────────────────────────────
// Assigns blocks to columns by role:
//   0: input connectors (USB-C, battery)
//   1: power regulators (charger, buck, ldo) — ordered by chain
//   2: IC consumers (STM32, flash, etc.)
//   3: output connectors (SWD)

fn layoutPowerColumns(allocator: Allocator, blocks: []Block, edges: []const Edge) !void {
    const n = blocks.len;
    if (n == 0) return;

    // Compute block heights
    const port_line_h: f64 = 18.0;
    for (blocks) |*blk| {
        var n_lines: f64 = 1;
        if (blk.subtitle.len > 0) n_lines += 1;
        if (blk.detail.len > 0) n_lines += 1;
        const title_h = n_lines * line_h;
        var in_count: f64 = 0;
        var out_count: f64 = 0;
        for (blk.ports) |p| {
            if (std.mem.eql(u8, p.name, "GND")) continue;
            if (p.direction == .out) out_count += 1 else in_count += 1;
        }
        const port_h = @max(in_count, out_count) * port_line_h;
        const symbol_h: f64 = 20.0;
        blk.h = @max(block_min_h, symbol_h + title_h + port_h + block_pad * 2 + 8);
    }

    // Assign columns
    var cols = try allocator.alloc(usize, n);
    for (blocks, 0..) |blk, i| {
        // Explicit role overrides all categories
        if (blk.block_role == .input) {
            cols[i] = 0;
            continue;
        } else if (blk.block_role == .output) {
            cols[i] = 3;
            continue;
        }
        if (blk.category == .connector) {
            // Auto: connected to the first power block → input, otherwise output
            var is_input = false;
            for (edges) |e| {
                const other = if (e.from == i) e.to else if (e.to == i) e.from else continue;
                if (blocks[other].category != .power) continue;
                var has_pwr_predecessor = false;
                for (edges) |e2| {
                    if (e2.to == other and blocks[e2.from].category == .power) {
                        has_pwr_predecessor = true;
                        break;
                    }
                }
                if (!has_pwr_predecessor) {
                    is_input = true;
                    break;
                }
            }
            cols[i] = if (is_input) 0 else 3;
        } else if (blk.category == .power or blk.category == .protection) {
            cols[i] = 1;
        } else {
            cols[i] = 2;
        }
    }

    // Count max columns
    var max_col: usize = 0;
    for (cols) |c| max_col = @max(max_col, c);
    const num_cols = max_col + 1;

    // Group by column
    var col_lists = try allocator.alloc(std.ArrayListUnmanaged(usize), num_cols);
    for (col_lists) |*cl| cl.* = .empty;
    for (0..n) |i| {
        try col_lists[cols[i]].append(allocator, i);
    }

    // Sort within power column by topological chain order
    if (col_lists.len > 1 and col_lists[1].items.len > 1) {
        // BFS from nodes with no incoming edges within the column
        var sorted: std.ArrayListUnmanaged(usize) = .empty;
        var visited = try allocator.alloc(bool, n);
        @memset(visited, false);
        // Find power chain order via edges
        for (0..col_lists[1].items.len) |_| {
            for (col_lists[1].items) |bi| {
                if (visited[bi]) continue;
                var has_unvisited_pred = false;
                for (edges) |e| {
                    if (e.to == bi and cols[e.from] == 1 and !visited[e.from]) {
                        has_unvisited_pred = true;
                        break;
                    }
                }
                if (!has_unvisited_pred) {
                    try sorted.append(allocator, bi);
                    visited[bi] = true;
                    break;
                }
            }
        }
        // Add any remaining
        for (col_lists[1].items) |bi| {
            if (!visited[bi]) try sorted.append(allocator, bi);
        }
        col_lists[1] = sorted;
    }

    // Position blocks with wider column gaps for power section
    const pwr_gap_x: f64 = 200.0;
    for (0..num_cols) |c| {
        const x = @as(f64, @floatFromInt(c)) * (block_w + pwr_gap_x) + margin;
        var cy: f64 = top_margin;
        for (col_lists[c].items) |bi| {
            blocks[bi].x = x;
            blocks[bi].y = cy;
            blocks[bi].col = c;
            cy += blocks[bi].h + grid_gap_y;
        }
    }
}

// ── Signal section: column-based layout ──────────────────────────────
// Assigns blocks to columns by role:
//   0: input connectors (role=input)
//   1: hub (MCU) + clocks
//   2: peripherals, memory, sensors, comms, power sub-blocks
//   3: output connectors (role=output)

fn layoutSignalColumns(allocator: Allocator, blocks: []Block, edges: []const Edge, hub_idx: ?usize) !void {
    const n = blocks.len;
    if (n == 0) return;

    // Compute block heights
    const port_line_h: f64 = 18.0;
    for (blocks) |*blk| {
        var n_lines: f64 = 1;
        if (blk.subtitle.len > 0) n_lines += 1;
        if (blk.detail.len > 0) n_lines += 1;
        const title_h = n_lines * line_h;
        var blk_has_power_out = false;
        var blk_has_non_power = blk.protocols.len > 0;
        for (blk.ports) |p| {
            if (std.mem.eql(u8, p.name, "GND")) continue;
            if (p.signal_type == .power and p.direction == .out) blk_has_power_out = true;
            if (p.signal_type != .power) blk_has_non_power = true;
        }
        const blk_hide_pwr_in = blk_has_non_power and !blk_has_power_out;
        var in_count: f64 = 0;
        var out_count: f64 = 0;
        for (blk.ports) |p| {
            if (std.mem.eql(u8, p.name, "GND")) continue;
            if (blk_hide_pwr_in and p.signal_type == .power and p.direction != .out) continue;
            if (p.direction == .out) out_count += 1 else in_count += 1;
        }
        out_count += @floatFromInt(blk.protocols.len);
        const port_h = @max(in_count, out_count) * port_line_h;
        const symbol_h: f64 = 20.0;
        blk.h = @max(block_min_h, symbol_h + title_h + port_h + block_pad * 2 + 8);
    }

    // Assign columns
    var cols = try allocator.alloc(usize, n);
    for (blocks, 0..) |blk, i| {
        const is_hub = if (hub_idx) |hi| i == hi else false;
        if (blk.block_role == .input) {
            cols[i] = 0;
        } else if (blk.block_role == .output) {
            cols[i] = 3;
        } else if (is_hub) {
            cols[i] = 1;
        } else if (blk.category == .connector) {
            // Auto connector: check if it has edges to/from hub
            var connects_to_hub = false;
            for (edges) |e| {
                const other = if (e.from == i) e.to else if (e.to == i) e.from else continue;
                const other_is_hub = if (hub_idx) |hi| other == hi else false;
                if (other_is_hub) {
                    connects_to_hub = true;
                    break;
                }
            }
            cols[i] = if (connects_to_hub) 3 else 2;
        } else {
            cols[i] = 2;
        }
    }

    // Count max columns
    var max_col: usize = 0;
    for (cols) |c| max_col = @max(max_col, c);
    const num_cols = max_col + 1;

    // Group by column
    var col_lists = try allocator.alloc(std.ArrayListUnmanaged(usize), num_cols);
    for (col_lists) |*cl| cl.* = .empty;
    for (0..n) |i| {
        try col_lists[cols[i]].append(allocator, i);
    }

    // Position blocks
    const sig_gap_x: f64 = 200.0;
    for (0..num_cols) |c| {
        const x = @as(f64, @floatFromInt(c)) * (block_w + sig_gap_x) + margin;
        var cy: f64 = top_margin;
        for (col_lists[c].items) |bi| {
            blocks[bi].x = x;
            blocks[bi].y = cy;
            blocks[bi].col = c;
            cy += blocks[bi].h + grid_gap_y;
        }
    }
}

// ── Shared: edge drawing helpers ─────────────────────────────────────

const EdgeAttach = struct { x: f64, y: f64 };

fn computeEdgeAttachments(
    allocator: Allocator,
    blocks: []const Block,
    edges: []const Edge,
) !struct { src: []EdgeAttach, dst: []EdgeAttach } {
    const n = blocks.len;
    // Count left (incoming) and right (outgoing) edges per block
    var right_counts = try allocator.alloc(usize, n);
    var left_counts = try allocator.alloc(usize, n);
    @memset(right_counts, 0);
    @memset(left_counts, 0);

    for (edges) |e| {
        right_counts[e.from] += 1;
        left_counts[e.to] += 1;
    }

    // Assign edge positions
    var right_idx = try allocator.alloc(usize, n);
    var left_idx = try allocator.alloc(usize, n);
    @memset(right_idx, 0);
    @memset(left_idx, 0);

    var src_attach = try allocator.alloc(EdgeAttach, edges.len);
    var dst_attach = try allocator.alloc(EdgeAttach, edges.len);

    for (edges, 0..) |e, ei| {
        const src = blocks[e.from];
        const dst = blocks[e.to];
        const same_col = src.col == dst.col;

        if (same_col) {
            // Vertical: attach at bottom/top center
            if (src.y < dst.y) {
                src_attach[ei] = .{ .x = src.x + src.w / HALF_DIVISOR, .y = src.y + src.h };
                dst_attach[ei] = .{ .x = dst.x + dst.w / HALF_DIVISOR, .y = dst.y };
            } else {
                src_attach[ei] = .{ .x = src.x + src.w / HALF_DIVISOR, .y = src.y };
                dst_attach[ei] = .{ .x = dst.x + dst.w / HALF_DIVISOR, .y = dst.y + dst.h };
            }
        } else {
            // Horizontal: distribute along right edge of source, left edge of dest
            const r_count = right_counts[e.from];
            const r_i = right_idx[e.from];
            right_idx[e.from] += 1;
            const r_spacing: f64 = if (r_count > 1) @min(EDGE_SPACING_LIMIT, (src.h - EDGE_SPACING_LIMIT) / @as(f64, @floatFromInt(r_count - 1))) else 0;
            const r_total = @as(f64, @floatFromInt(r_count - 1)) * r_spacing;
            const r_y = src.y + src.h / HALF_DIVISOR - r_total / HALF_DIVISOR + @as(f64, @floatFromInt(r_i)) * r_spacing;

            const l_count = left_counts[e.to];
            const l_i = left_idx[e.to];
            left_idx[e.to] += 1;
            const l_spacing: f64 = if (l_count > 1) @min(EDGE_SPACING_LIMIT, (dst.h - EDGE_SPACING_LIMIT) / @as(f64, @floatFromInt(l_count - 1))) else 0;
            const l_total = @as(f64, @floatFromInt(l_count - 1)) * l_spacing;
            const l_y = dst.y + dst.h / HALF_DIVISOR - l_total / HALF_DIVISOR + @as(f64, @floatFromInt(l_i)) * l_spacing;

            if (src.x < dst.x) {
                src_attach[ei] = .{ .x = src.x + src.w, .y = r_y };
                dst_attach[ei] = .{ .x = dst.x, .y = l_y };
            } else {
                src_attach[ei] = .{ .x = src.x, .y = r_y };
                dst_attach[ei] = .{ .x = dst.x + dst.w, .y = l_y };
            }
        }
    }
    return .{ .src = src_attach, .dst = dst_attach };
}

// ── Sub-diagram filtering ───────────────────────────────────────────

const SubDiagram = struct {
    blocks: []Block,
    edges: []Edge,
    hub_idx: ?usize,
};

fn filterSubDiagram(
    allocator: Allocator,
    all_blocks: []const Block,
    sub_edges: []const Edge,
    hub_idx: ?usize,
) !SubDiagram {
    const n = all_blocks.len;

    // Collect participating block indices
    var participating = try allocator.alloc(bool, n);
    @memset(participating, false);
    if (hub_idx) |hi| participating[hi] = true;
    for (sub_edges) |e| {
        participating[e.from] = true;
        participating[e.to] = true;
    }

    // Build old→new index remap
    var old_to_new = try allocator.alloc(?usize, n);
    @memset(old_to_new, null);
    var new_count: usize = 0;
    for (0..n) |i| {
        if (participating[i]) {
            old_to_new[i] = new_count;
            new_count += 1;
        }
    }

    // Copy participating blocks
    var new_blocks = try allocator.alloc(Block, new_count);
    var idx: usize = 0;
    for (0..n) |i| {
        if (participating[i]) {
            new_blocks[idx] = all_blocks[i];
            idx += 1;
        }
    }

    // Remap edge indices
    var new_edges = try allocator.alloc(Edge, sub_edges.len);
    for (sub_edges, 0..) |e, ei| {
        new_edges[ei] = .{
            .from = old_to_new[e.from].?,
            .to = old_to_new[e.to].?,
            .label = e.label,
            .signal_type = e.signal_type,
            .voltage = e.voltage,
        };
    }

    const new_hub = if (hub_idx) |hi| old_to_new[hi] else null;
    return .{ .blocks = new_blocks, .edges = new_edges, .hub_idx = new_hub };
}

// ── JSON serialization ──────────────────────────────────────────────

const PortNetMap = std.StringHashMap([]const u8);

fn serializeBlock(w: anytype, blk: Block, section: []const u8, port_net_map: *const PortNetMap) !void {
    try w.print(
        "{{\"title\":\"{s}\",\"subtitle\":\"{s}\",\"detail\":\"{s}\"," ++
            "\"category\":\"{s}\",\"status\":\"{s}\",\"section\":\"{s}\"," ++
            "\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1},\"ports\":[",
        .{
            blk.title,              blk.subtitle,         blk.detail,
            @tagName(blk.category), @tagName(blk.status), section,
            blk.x,                  blk.y,                blk.w,
            blk.h,
        },
    );
    const is_power_section = std.mem.eql(u8, section, "power");
    var has_power_out = false;
    var has_non_power = blk.protocols.len > 0;
    for (blk.ports) |p| {
        if (std.mem.eql(u8, p.name, "GND")) continue;
        if (p.signal_type == .power and p.direction == .out) has_power_out = true;
        if (p.signal_type != .power) has_non_power = true;
    }
    // In power section, always show power ports
    const hide_power_in = if (is_power_section) false else (has_non_power and !has_power_out);
    var port_written = false;
    for (blk.ports) |p| {
        if (std.mem.eql(u8, p.name, "GND")) continue;
        if (hide_power_in and p.signal_type == .power and p.direction != .out) continue;
        if (port_written) try w.writeAll(",");
        // Look up net name: key is "block_title\x00port_name"
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, PIN_KEY_FMT, .{ blk.title, p.name }) catch p.name;
        const net_name = port_net_map.get(key) orelse p.name;
        try w.print("{{\"name\":\"{s}\",\"net\":\"{s}\",\"direction\":\"{s}\",\"signal\":\"{s}\"", .{
            p.name, net_name, @tagName(p.direction), @tagName(p.signal_type),
        });
        if (p.voltage) |v| {
            try w.print(",\"voltage\":{d:.1}", .{v});
        }
        try w.writeAll("}");
        port_written = true;
    }
    try w.writeAll("],\"protocols\":[");
    for (blk.protocols, 0..) |proto, pi| {
        if (pi > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{proto});
    }
    try w.writeAll("]}");
}

fn serializeEdge(w: anytype, edge: Edge, idx_offset: usize) !void {
    try w.print(
        "{{\"from\":{d},\"to\":{d},\"label\":\"{s}\",\"signal\":\"{s}\"",
        .{ edge.from + idx_offset, edge.to + idx_offset, edge.label, @tagName(edge.signal_type) },
    );
    if (edge.voltage) |v| {
        try w.print(",\"voltage\":{d:.1}", .{v});
    }
    try w.writeAll("}");
}

// ── JSON Renderer ────────────────────────────────────────────────────

/// Render the design's section topology as a JSON scene graph for the
/// Pixi.js block-diagram viewer. Builds one block per section (and one per
/// sub-block), categorizes them, column-packs the layout, then routes
/// power/signal/protocol edges between them.
pub fn renderBlockDiagramJson(allocator: Allocator, design: *const DesignBlock) RenderError![]const u8 {
    var result = try buildBlocksFromDesign(allocator, design);
    const section_count = result.blocks.items.len;

    // Add sub-blocks as additional blocks
    for (design.sub_blocks) |sb| {
        const cat = types.classifyByName(sb.block.name, sb.block.instances);
        var sb_detail: std.ArrayListUnmanaged(u8) = .empty;
        const sbw = sb_detail.writer(allocator);
        for (sb.block.ports) |p| {
            const v = p.nominal orelse p.rated_max orelse continue;
            if (sb_detail.items.len > 0) try sbw.writeAll(", ");
            try sbw.print("{s}={d:.1}V", .{ p.name, v });
        }
        var sb_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
        for (sb.block.ports) |p| {
            const dir: env_mod.PortDirection = if (std.mem.eql(u8, p.direction, "out")) .out else if (std.mem.eql(u8, p.direction, "in")) .in else .io;
            const has_rated = p.rated_max != null or p.rated_min != null or p.nominal != null;
            // For power-category sub-blocks, classify voltage-like ports as power
            const is_power_block = cat == .power;
            const is_control_port = std.mem.eql(u8, p.name, "EN") or std.mem.eql(u8, p.name, "PG") or
                std.mem.eql(u8, p.name, "PGOOD") or std.mem.eql(u8, p.name, "SS");
            const sig: env_mod.SignalType = if (has_rated or (is_power_block and !is_control_port)) .power else .signal;
            const voltage = p.nominal orelse p.rated_max;
            try sb_ports.append(allocator, .{ .name = p.name, .direction = dir, .signal_type = sig, .voltage = voltage });
        }
        try result.blocks.append(allocator, .{
            .title = sb.name,
            .subtitle = sb.block.name,
            .detail = if (sb_detail.items.len > 0) (try allocator.dupe(u8, sb_detail.items)) else "",
            .category = cat,
            .ports = sb_ports.items,
        });
    }

    // Build edges from topology (only for section-based blocks)
    var edges = try buildEdgesFromTopology(allocator, result.blocks.items[0..section_count], design, result.hub_idx);

    // Build edges from net_ties (connects sub-blocks)
    const NetEndpoint = struct { block_idx: usize, voltage: ?f64, sig: env_mod.SignalType, is_source: bool };
    var net_map = std.StringHashMap(std.ArrayListUnmanaged(NetEndpoint)).init(allocator);

    for (design.net_ties) |nt| {
        const sides = [_][]const u8{ nt.a, nt.b };
        for (sides) |side| {
            if (std.mem.indexOfScalar(u8, side, '/')) |slash| {
                const sb_name = side[0..slash];
                const port_name = side[slash + 1 ..];
                const plain_net = if (std.mem.indexOfScalar(u8, nt.a, '/') == null)
                    nt.a
                else if (std.mem.indexOfScalar(u8, nt.b, '/') == null)
                    nt.b
                else
                    continue;
                for (result.blocks.items, 0..) |blk, bi| {
                    if (!std.mem.eql(u8, blk.title, sb_name)) continue;
                    for (blk.ports) |p| {
                        if (!std.mem.eql(u8, p.name, port_name)) continue;
                        const gop = try net_map.getOrPut(plain_net);
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        try gop.value_ptr.append(allocator, .{
                            .block_idx = bi,
                            .voltage = p.voltage,
                            .sig = p.signal_type,
                            .is_source = p.direction == .out,
                        });
                        break;
                    }
                    break;
                }
            }
        }
    }
    if (result.hub_idx) |hi| {
        var net_iter = net_map.iterator();
        while (net_iter.next()) |entry| {
            const net_name = entry.key_ptr.*;
            for (result.blocks.items[hi].ports) |p| {
                if (!std.mem.eql(u8, p.name, net_name)) continue;
                try entry.value_ptr.append(allocator, .{
                    .block_idx = hi,
                    .voltage = p.voltage,
                    .sig = p.signal_type,
                    .is_source = p.direction == .out,
                });
                break;
            }
        }
    }
    var net_iter2 = net_map.iterator();
    while (net_iter2.next()) |entry| {
        const net_name = entry.key_ptr.*;
        const endpoints = entry.value_ptr.items;
        for (endpoints) |src| {
            if (!src.is_source) continue;
            for (endpoints) |dst| {
                if (dst.is_source) continue;
                if (src.block_idx == dst.block_idx) continue;
                if (!types.edgeExists(edges.items, src.block_idx, dst.block_idx, net_name))
                    try edges.append(allocator, .{
                        .from = src.block_idx,
                        .to = dst.block_idx,
                        .label = net_name,
                        .signal_type = src.sig,
                        .voltage = src.voltage,
                    });
            }
        }
    }

    // ── Build power section from individual components ─────────────────
    // Instead of sections, each IC/connector with power pins gets its own block.

    // Build port→net lookup from design.net_ties
    var pwr_port_net = std.StringHashMap([]const u8).init(allocator);
    var net_alias = std.StringHashMap([]const u8).init(allocator);
    for (design.net_ties) |nt| {
        const a_has_slash = std.mem.indexOfScalar(u8, nt.a, '/') != null;
        const b_has_slash = std.mem.indexOfScalar(u8, nt.b, '/') != null;
        if (a_has_slash or b_has_slash) {
            const sides = [_][]const u8{ nt.a, nt.b };
            for (sides) |side| {
                if (std.mem.indexOfScalar(u8, side, '/')) |slash| {
                    const sb_name = side[0..slash];
                    const port_name = side[slash + 1 ..];
                    const plain_net = if (!a_has_slash) nt.a else if (!b_has_slash) nt.b else continue;
                    const key = try std.fmt.allocPrint(allocator, PIN_KEY_FMT, .{ sb_name, port_name });
                    try pwr_port_net.put(key, plain_net);
                }
            }
        } else {
            try net_alias.put(nt.b, nt.a);
        }
    }

    // Collect power net names (from section ports and sub-block rated ports)
    var power_net_set = std.StringHashMap(?f64).init(allocator);
    for (design.sections) |s| {
        for (s.ports) |p| {
            if (p.signal_type == .power) try power_net_set.put(p.name, p.voltage);
        }
    }
    for (design.sub_blocks) |sb| {
        const sb_is_power = types.classifyByName(sb.block.name, sb.block.instances) == .power;
        for (sb.block.ports) |p| {
            const is_rated = p.rated_max != null or p.rated_min != null or p.nominal != null;
            // Include rated ports and all power sub-block output ports
            if (is_rated or (sb_is_power and std.mem.eql(u8, p.direction, "out")))
                try power_net_set.put(p.net, p.nominal orelse p.rated_max);
        }
    }

    // Build component-based power blocks: one block per instance that has pins on power nets
    var pwr_blocks: std.ArrayListUnmanaged(Block) = .empty;
    var pwr_edges: std.ArrayListUnmanaged(Edge) = .empty;

    // First: add sub-blocks (charger, buck, ldo) — same as before
    for (design.sub_blocks) |sb| {
        const cat = types.classifyByName(sb.block.name, sb.block.instances);
        var sb_detail: std.ArrayListUnmanaged(u8) = .empty;
        const sbw = sb_detail.writer(allocator);
        for (sb.block.ports) |p| {
            const v = p.nominal orelse p.rated_max orelse continue;
            if (sb_detail.items.len > 0) try sbw.writeAll(", ");
            try sbw.print("{s}={d:.1}V", .{ p.name, v });
        }
        var sb_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
        for (sb.block.ports) |p| {
            const dir: env_mod.PortDirection = if (std.mem.eql(u8, p.direction, "out")) .out else if (std.mem.eql(u8, p.direction, "in")) .in else .io;
            const has_rated = p.rated_max != null or p.rated_min != null or p.nominal != null;
            const is_power_block = cat == .power;
            const is_control_port = std.mem.eql(u8, p.name, "EN") or std.mem.eql(u8, p.name, "PG") or
                std.mem.eql(u8, p.name, "PGOOD") or std.mem.eql(u8, p.name, "SS");
            const sig: env_mod.SignalType = if (has_rated or (is_power_block and !is_control_port)) .power else .signal;
            const voltage = p.nominal orelse p.rated_max;
            try sb_ports.append(allocator, .{ .name = p.name, .direction = dir, .signal_type = sig, .voltage = voltage });
        }
        try pwr_blocks.append(allocator, .{
            .title = sb.name,
            .subtitle = sb.block.name,
            .detail = if (sb_detail.items.len > 0) (try allocator.dupe(u8, sb_detail.items)) else "",
            .category = cat,
            .ports = sb_ports.items,
        });
    }

    // Build edges between sub-blocks (from net_ties)
    {
        const SbNetEndpoint = struct { block_idx: usize, voltage: ?f64, sig: env_mod.SignalType, is_source: bool };
        var sb_net_map = std.StringHashMap(std.ArrayListUnmanaged(SbNetEndpoint)).init(allocator);
        for (design.net_ties) |nt| {
            const sides = [_][]const u8{ nt.a, nt.b };
            for (sides) |side| {
                if (std.mem.indexOfScalar(u8, side, '/')) |slash| {
                    const sb_name = side[0..slash];
                    const port_name = side[slash + 1 ..];
                    const plain_net = if (std.mem.indexOfScalar(u8, nt.a, '/') == null)
                        nt.a
                    else if (std.mem.indexOfScalar(u8, nt.b, '/') == null)
                        nt.b
                    else
                        continue;
                    for (pwr_blocks.items, 0..) |blk, bi| {
                        if (!std.mem.eql(u8, blk.title, sb_name)) continue;
                        for (blk.ports) |p| {
                            if (!std.mem.eql(u8, p.name, port_name)) continue;
                            const gop = try sb_net_map.getOrPut(plain_net);
                            if (!gop.found_existing) gop.value_ptr.* = .empty;
                            try gop.value_ptr.append(allocator, .{
                                .block_idx = bi,
                                .voltage = p.voltage,
                                .sig = p.signal_type,
                                .is_source = p.direction == .out,
                            });
                            break;
                        }
                        break;
                    }
                }
            }
        }
        var sb_iter = sb_net_map.iterator();
        while (sb_iter.next()) |entry| {
            const net_name = entry.key_ptr.*;
            const eps = entry.value_ptr.items;
            for (eps) |src| {
                if (!src.is_source) continue;
                for (eps) |dst| {
                    if (dst.is_source or src.block_idx == dst.block_idx) continue;
                    if (!types.edgeExists(pwr_edges.items, src.block_idx, dst.block_idx, net_name))
                        try pwr_edges.append(allocator, .{
                            .from = src.block_idx,
                            .to = dst.block_idx,
                            .label = net_name,
                            .signal_type = src.sig,
                            .voltage = src.voltage,
                        });
                }
            }
        }
    }

    // Now find individual component instances on power nets and create blocks + edges
    // Track which ref_des we've already added
    var added_refs = std.StringHashMap(usize).init(allocator); // ref_des → block index
    for (design.nets) |net| {
        // Is this a power net? Check by name, alias, per-pin prefix, or voltage match
        var net_voltage = power_net_set.get(net.name) orelse
            (if (net_alias.get(net.name)) |canonical| power_net_set.get(canonical) orelse null else null);
        var is_power = power_net_set.contains(net.name) or
            (if (net_alias.get(net.name)) |canonical| power_net_set.contains(canonical) else false);
        // Check per-pin qualified names like "V1P8.U6.E4" → base is "V1P8"
        var base_net: []const u8 = net.name;
        if (!is_power) {
            if (std.mem.indexOfScalar(u8, net.name, '.')) |dot| {
                const prefix = net.name[0..dot];
                if (power_net_set.get(prefix)) |v| {
                    is_power = true;
                    base_net = prefix;
                    if (net_voltage == null) net_voltage = v;
                } else if (net_alias.get(prefix)) |canonical| {
                    if (power_net_set.get(canonical)) |v| {
                        is_power = true;
                        base_net = canonical;
                        if (net_voltage == null) net_voltage = v;
                    }
                }
            }
        }
        // Also check if any section declares this net name as a power port
        if (!is_power) {
            for (design.sections) |s| {
                for (s.ports) |p| {
                    if (p.signal_type == .power and std.mem.eql(u8, p.name, net.name)) {
                        is_power = true;
                        if (net_voltage == null) net_voltage = p.voltage;
                        break;
                    }
                }
                if (is_power) break;
            }
        }
        if (!is_power) continue;
        const voltage = net_voltage;

        // Resolve to canonical rail: use base_net, alias, or match by voltage
        var canonical_rail = if (!std.mem.eql(u8, base_net, net.name)) base_net else (net_alias.get(net.name) orelse net.name);
        // If not already a sub-block output rail name, match by voltage
        var is_sb_output = false;
        for (design.sub_blocks) |sb| {
            for (sb.block.ports) |p| {
                if (std.mem.eql(u8, p.direction, "out")) {
                    const pk = std.fmt.allocPrint(allocator, PIN_KEY_FMT, .{ sb.name, p.name }) catch continue;
                    const resolved_name = pwr_port_net.get(pk) orelse p.net;
                    if (std.mem.eql(u8, resolved_name, canonical_rail)) is_sb_output = true;
                }
            }
        }
        if (!is_sb_output) {
            if (voltage) |v| {
                for (design.sub_blocks) |sb| {
                    for (sb.block.ports) |p| {
                        if (!std.mem.eql(u8, p.direction, "out")) continue;
                        const pv = p.nominal orelse continue;
                        if (pv == v) {
                            const port_key = std.fmt.allocPrint(allocator, PIN_KEY_FMT, .{ sb.name, p.name }) catch continue;
                            canonical_rail = pwr_port_net.get(port_key) orelse p.net;
                            break;
                        }
                    }
                }
            }
        }

        // Find which sub-block outputs this rail (for edge building)
        var source_sb_idx: ?usize = null;
        for (pwr_blocks.items, 0..) |blk, bi| {
            for (blk.ports) |p| {
                if (p.direction != .out or p.signal_type != .power) continue;
                var kb: [512]u8 = undefined;
                const k = std.fmt.bufPrint(&kb, PIN_KEY_FMT, .{ blk.title, p.name }) catch continue;
                const resolved = pwr_port_net.get(k) orelse p.name;
                if (std.mem.eql(u8, resolved, canonical_rail) or std.mem.eql(u8, resolved, net.name)) {
                    source_sb_idx = bi;
                    break;
                }
            }
            if (source_sb_idx != null) break;
        }

        for (net.pins) |pin_ref| {
            // Skip passives
            if (pin_ref.ref_des.len == 0) continue;
            const prefix = pin_ref.ref_des[0];
            if (prefix == 'R' or prefix == 'C' or prefix == 'L' or prefix == 'D' or prefix == 'F' or prefix == 'Y') continue;
            // Skip instances that belong to sub-blocks (already have their own blocks)
            var is_sb_inst = false;
            for (design.sub_blocks) |sb| {
                for (sb.block.instances) |inst| {
                    if (std.mem.eql(u8, inst.ref_des, pin_ref.ref_des)) {
                        is_sb_inst = true;
                        break;
                    }
                }
                if (is_sb_inst) break;
            }
            if (is_sb_inst) continue;

            // Find the instance details and its section's block_role
            var inst_component: []const u8 = "";
            var inst_label: []const u8 = "";
            var inst_role: env_mod.BlockRole = .auto;
            for (design.instances) |inst| {
                if (std.mem.eql(u8, inst.ref_des, pin_ref.ref_des)) {
                    inst_component = inst.component;
                    inst_label = if (inst.label.len > 0) inst.label else inst.ref_des;
                    break;
                }
            }
            // Find which section owns this instance (for block_role)
            for (design.sections) |s| {
                for (s.instances) |inst| {
                    if (std.mem.eql(u8, inst.ref_des, pin_ref.ref_des)) {
                        if (inst_component.len == 0) {
                            inst_component = inst.component;
                            inst_label = if (inst.label.len > 0) inst.label else inst.ref_des;
                        }
                        inst_role = s.block_role;
                        break;
                    }
                }
                if (inst_role != .auto) break;
            }
            if (inst_component.len == 0) continue;

            // Use the canonical rail name resolved at the net level
            const rail_name = canonical_rail;
            const rail_voltage = voltage;

            // Get or create block for this instance
            const gop = try added_refs.getOrPut(pin_ref.ref_des);
            if (!gop.found_existing) {
                gop.value_ptr.* = pwr_blocks.items.len;
                var comp_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
                try comp_ports.append(allocator, .{
                    .name = rail_name,
                    .direction = .in,
                    .signal_type = .power,
                    .voltage = rail_voltage,
                });
                // Use ref_des prefix for more accurate categorization
                const comp_cat = if (pin_ref.ref_des.len > 0 and (pin_ref.ref_des[0] == 'J' or pin_ref.ref_des[0] == 'P'))
                    types.Category.connector
                else
                    types.classifyByName(inst_component, &.{});
                try pwr_blocks.append(allocator, .{
                    .title = inst_label,
                    .subtitle = inst_component,
                    .detail = pin_ref.ref_des,
                    .category = comp_cat,
                    .ports = comp_ports.items,
                    .block_role = inst_role,
                });
            } else {
                // Add this power rail as another port on the existing block
                const bi = gop.value_ptr.*;
                var existing_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
                for (pwr_blocks.items[bi].ports) |p| try existing_ports.append(allocator, p);
                // Don't add duplicate rail
                var already_has = false;
                for (existing_ports.items) |p| {
                    if (std.mem.eql(u8, p.name, rail_name)) {
                        already_has = true;
                        break;
                    }
                }
                if (!already_has) {
                    try existing_ports.append(allocator, .{
                        .name = rail_name,
                        .direction = .in,
                        .signal_type = .power,
                        .voltage = rail_voltage,
                    });
                    pwr_blocks.items[bi].ports = existing_ports.items;
                }
            }
            // Create edge from source sub-block to this component
            if (source_sb_idx) |src_bi| {
                const dst_bi = added_refs.get(pin_ref.ref_des).?;
                if (!types.edgeExists(pwr_edges.items, src_bi, dst_bi, rail_name))
                    try pwr_edges.append(allocator, .{ .from = src_bi, .to = dst_bi, .label = rail_name, .signal_type = .power, .voltage = rail_voltage });
            }
        }
    }

    // Also check for power source components (e.g., USB connector providing VBUS)
    // Find nets that are sub-block power inputs but not sub-block outputs
    for (design.net_ties) |nt| {
        const a_slash = std.mem.indexOfScalar(u8, nt.a, '/');
        const b_slash = std.mem.indexOfScalar(u8, nt.b, '/');
        const sb_side = if (a_slash != null) nt.a else if (b_slash != null) nt.b else continue;
        const plain_net = if (a_slash == null) nt.a else if (b_slash == null) nt.b else continue;
        const nt_slash = std.mem.indexOfScalar(u8, sb_side, '/').?;
        const sb_name = sb_side[0..nt_slash];
        const sb_port = sb_side[nt_slash + 1 ..];
        var is_sb_power_in = false;
        var sb_outputs_this = false;
        for (design.sub_blocks) |sb| {
            if (!std.mem.eql(u8, sb.name, sb_name)) continue;
            for (sb.block.ports) |p| {
                if (std.mem.eql(u8, p.name, sb_port) and std.mem.eql(u8, p.direction, "in")) {
                    const is_rated = p.rated_max != null or p.rated_min != null or p.nominal != null;
                    if (is_rated) is_sb_power_in = true;
                }
            }
        }
        if (!is_sb_power_in) continue;
        // Check if any sub-block outputs this net
        for (design.net_ties) |nt2| {
            const nt2_a_slash = std.mem.indexOfScalar(u8, nt2.a, '/') != null;
            const nt2_b_slash = std.mem.indexOfScalar(u8, nt2.b, '/') != null;
            if (!nt2_a_slash and !nt2_b_slash) continue;
            const o_plain = if (!nt2_a_slash) nt2.a else if (!nt2_b_slash) nt2.b else continue;
            if (!std.mem.eql(u8, o_plain, plain_net)) continue;
            const o_sb = if (nt2_a_slash) nt2.a else nt2.b;
            const o_slash = std.mem.indexOfScalar(u8, o_sb, '/').?;
            const o_sb_name = o_sb[0..o_slash];
            const o_sb_port = o_sb[o_slash + 1 ..];
            for (design.sub_blocks) |sb| {
                if (!std.mem.eql(u8, sb.name, o_sb_name)) continue;
                for (sb.block.ports) |p| {
                    if (std.mem.eql(u8, p.name, o_sb_port) and std.mem.eql(u8, p.direction, "out"))
                        sb_outputs_this = true;
                }
            }
        }
        if (sb_outputs_this) continue;
        // Find component instances on this net and connect to sub-block
        var sb_bi: ?usize = null;
        for (pwr_blocks.items, 0..) |blk, bi| {
            if (std.mem.eql(u8, blk.title, sb_name)) {
                sb_bi = bi;
                break;
            }
        }
        const target_bi = sb_bi orelse continue;
        for (design.nets) |net| {
            if (!std.mem.eql(u8, net.name, plain_net)) continue;
            for (net.pins) |pin_ref| {
                if (added_refs.get(pin_ref.ref_des)) |src_bi| {
                    if (!types.edgeExists(pwr_edges.items, src_bi, target_bi, plain_net))
                        try pwr_edges.append(allocator, .{ .from = src_bi, .to = target_bi, .label = plain_net, .signal_type = .power, .voltage = null });
                }
            }
        }
    }

    // Fallback: if no component power blocks were found (concept design),
    // use section-based blocks for the power section
    if (pwr_blocks.items.len == 0) {
        // Build from sections that have power ports (skip support sections)
        for (design.sections) |sec| {
            if (sec.sub_sections.len > 0) continue; // skip hub
            if (types.isSupportSection(sec)) continue;
            var has_power_port = false;
            for (sec.ports) |p| {
                if (p.signal_type == .power) {
                    has_power_port = true;
                    break;
                }
            }
            if (!has_power_port) continue;
            const cat = types.classifySection(sec);
            var pwr_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
            for (sec.ports) |p| {
                if (p.signal_type == .power) try pwr_ports.append(allocator, p);
            }
            const bi = pwr_blocks.items.len;
            try pwr_blocks.append(allocator, .{
                .title = sec.name,
                .subtitle = types.findKeyComponent(sec),
                .detail = if (sec.description.len > 0) sec.description else "",
                .category = cat,
                .ports = pwr_ports.items,
                .status = sec.status,
                .block_role = sec.block_role,
            });
            // Connect power outputs to matching inputs
            for (pwr_blocks.items[0..bi], 0..) |src_blk, si| {
                for (src_blk.ports) |sp| {
                    if (sp.direction != .out or sp.signal_type != .power) continue;
                    for (pwr_ports.items) |dp| {
                        if (dp.direction == .out) continue;
                        if (std.mem.eql(u8, sp.name, dp.name) and !types.edgeExists(pwr_edges.items, si, bi, sp.name))
                            try pwr_edges.append(allocator, .{ .from = si, .to = bi, .label = sp.name, .signal_type = .power, .voltage = sp.voltage });
                    }
                }
            }
            // Also check this block's outputs against previous blocks' inputs
            for (pwr_ports.items) |sp| {
                if (sp.direction != .out or sp.signal_type != .power) continue;
                for (pwr_blocks.items[0..bi], 0..) |dst_blk, di| {
                    for (dst_blk.ports) |dp| {
                        if (dp.direction == .out) continue;
                        if (std.mem.eql(u8, sp.name, dp.name) and !types.edgeExists(pwr_edges.items, bi, di, sp.name))
                            try pwr_edges.append(allocator, .{ .from = bi, .to = di, .label = sp.name, .signal_type = .power, .voltage = sp.voltage });
                    }
                }
            }
        }
        // Add hub to power section if it has power ports
        if (result.hub_idx) |hi| {
            const hub_blk = result.blocks.items[hi];
            var hub_pwr_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
            for (hub_blk.ports) |p| {
                if (p.signal_type == .power) try hub_pwr_ports.append(allocator, p);
            }
            if (hub_pwr_ports.items.len > 0) {
                const hub_bi = pwr_blocks.items.len;
                try pwr_blocks.append(allocator, .{
                    .title = hub_blk.title,
                    .subtitle = hub_blk.subtitle,
                    .detail = "",
                    .category = .mcu,
                    .ports = hub_pwr_ports.items,
                    .block_role = hub_blk.block_role,
                });
                // Connect power sources to hub
                for (pwr_blocks.items[0..hub_bi], 0..) |src_blk, si| {
                    for (src_blk.ports) |sp| {
                        if (sp.direction != .out or sp.signal_type != .power) continue;
                        for (hub_pwr_ports.items) |dp| {
                            if (dp.direction == .out) continue;
                            if (std.mem.eql(u8, sp.name, dp.name) and !types.edgeExists(pwr_edges.items, si, hub_bi, sp.name))
                                try pwr_edges.append(allocator, .{ .from = si, .to = hub_bi, .label = sp.name, .signal_type = .power, .voltage = sp.voltage });
                        }
                    }
                }
            }
        }
    }

    // Layout power blocks using column-based layout
    try layoutPowerColumns(allocator, pwr_blocks.items, pwr_edges.items);

    // ── Build signal section from individual components ────────────────
    var sig_blocks: std.ArrayListUnmanaged(Block) = .empty;
    var sig_edges: std.ArrayListUnmanaged(Edge) = .empty;

    // MCU hub block: collect all protocols from all sections
    var mcu_protocols: std.ArrayListUnmanaged([]const u8) = .empty;
    var mcu_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
    var hub_section: ?env_mod.Section = null;
    for (design.sections) |sec| {
        if (sec.sub_sections.len > 0) {
            hub_section = sec;
            // Add hub's own non-power ports
            for (sec.ports) |p| {
                if (p.signal_type != .power) try mcu_ports.append(allocator, p);
            }
            continue;
        }
        for (sec.protocols) |proto| {
            if (!types.strInList(mcu_protocols.items, proto))
                try mcu_protocols.append(allocator, proto);
        }
        for (sec.ports) |p| {
            if (p.protocol.len > 0 and !types.strInList(mcu_protocols.items, p.protocol))
                try mcu_protocols.append(allocator, p.protocol);
        }
    }
    var hub_sig_idx: ?usize = null;
    if (hub_section) |hs| {
        var key_comp: []const u8 = hs.description;
        if (key_comp.len == 0) {
            for (design.instances) |inst| {
                if (inst.ref_des.len > 0 and inst.ref_des[0] == 'U') {
                    key_comp = inst.component;
                    break;
                }
            }
        }
        hub_sig_idx = sig_blocks.items.len;
        try sig_blocks.append(allocator, .{
            .title = hs.name,
            .subtitle = key_comp,
            .detail = "",
            .category = .mcu,
            .ports = mcu_ports.items,
            .protocols = mcu_protocols.items,
            .block_role = hs.block_role,
        });
    }

    // Peripheral blocks: one per section (skip support sections)
    for (design.sections) |sec| {
        if (sec.sub_sections.len > 0) continue; // skip hub
        if (types.isSupportSection(sec)) continue;
        const key_comp = types.findKeyComponent(sec);
        const cat = types.classifySection(sec);
        // Collect non-power ports
        var comp_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
        for (sec.ports) |p| {
            if (p.signal_type != .power) try comp_ports.append(allocator, p);
        }
        const bi = sig_blocks.items.len;
        try sig_blocks.append(allocator, .{
            .title = sec.name,
            .subtitle = key_comp,
            .detail = if (sec.description.len > 0) sec.description else "",
            .category = cat,
            .ports = comp_ports.items,
            .protocols = sec.protocols,
            .status = sec.status,
            .block_role = sec.block_role,
        });
        // Edge from MCU hub to this peripheral via protocol
        if (hub_sig_idx) |hi| {
            for (sec.protocols) |proto| {
                if (!types.edgeExists(sig_edges.items, hi, bi, proto))
                    try sig_edges.append(allocator, .{ .from = hi, .to = bi, .label = proto, .signal_type = .data, .voltage = null });
            }
            // Also connect via io ports with protocols
            for (sec.ports) |p| {
                if (p.direction == .io and p.protocol.len > 0 and
                    !types.edgeExists(sig_edges.items, hi, bi, p.protocol))
                    try sig_edges.append(allocator, .{ .from = hi, .to = bi, .label = p.protocol, .signal_type = p.signal_type, .voltage = null });
            }
            // Connect via clock outputs
            for (sec.ports) |p| {
                if (p.signal_type == .clock and p.direction == .out and
                    !types.edgeExists(sig_edges.items, hi, bi, p.name))
                    try sig_edges.append(allocator, .{ .from = hi, .to = bi, .label = p.name, .signal_type = .clock, .voltage = null });
            }
            // Connect via signal ports (reset, etc.)
            for (sec.ports) |p| {
                if (p.signal_type == .signal and p.role.len > 0 and
                    !types.edgeExists(sig_edges.items, hi, bi, p.name))
                    try sig_edges.append(allocator, .{ .from = hi, .to = bi, .label = p.name, .signal_type = .signal, .voltage = null });
            }
            // De-orphan: if no edge yet, connect with section name
            var has_edge = false;
            for (sig_edges.items) |e| {
                if ((e.from == hi and e.to == bi) or (e.from == bi and e.to == hi)) {
                    has_edge = true;
                    break;
                }
            }
            if (!has_edge) {
                try sig_edges.append(allocator, .{ .from = hi, .to = bi, .label = sec.name, .signal_type = .signal, .voltage = null });
            }
        }
    }

    // Layout signal blocks
    try layoutSignalColumns(allocator, sig_blocks.items, sig_edges.items, hub_sig_idx);

    // ── Build support section (LEDs, clocking, boot/reset, mounting) ────
    var sup_blocks: std.ArrayListUnmanaged(Block) = .empty;
    for (design.sections) |sec| {
        if (sec.sub_sections.len > 0) continue;
        if (!types.isSupportSection(sec)) continue;
        const cat = types.classifySection(sec);
        var sup_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
        for (sec.ports) |p| {
            if (p.signal_type != .power) try sup_ports.append(allocator, p);
        }
        try sup_blocks.append(allocator, .{
            .title = sec.name,
            .subtitle = types.findKeyComponent(sec),
            .detail = if (sec.description.len > 0) sec.description else "",
            .category = cat,
            .ports = sup_ports.items,
            .protocols = sec.protocols,
            .status = sec.status,
            .block_role = sec.block_role,
        });
    }
    // Simple horizontal layout for support blocks
    {
        const port_line_h2: f64 = 18.0;
        var sx: f64 = margin;
        for (sup_blocks.items) |*blk| {
            var n_lines: f64 = 1;
            if (blk.subtitle.len > 0) n_lines += 1;
            if (blk.detail.len > 0) n_lines += 1;
            const title_h = n_lines * line_h;
            var port_count: f64 = 0;
            for (blk.ports) |p| {
                if (!std.mem.eql(u8, p.name, "GND")) port_count += 1;
            }
            port_count += @floatFromInt(blk.protocols.len);
            const sym_h: f64 = 20.0;
            blk.h = @max(block_min_h, sym_h + title_h + port_count * port_line_h2 + block_pad * 2 + 8);
            blk.x = sx;
            blk.y = top_margin;
            sx += block_w + grid_gap_x;
        }
    }

    // Compute section Y offsets
    const section_gap: f64 = 80.0;
    var power_max_y: f64 = 0;
    for (pwr_blocks.items) |blk| {
        const bottom = blk.y + blk.h;
        if (bottom > power_max_y) power_max_y = bottom;
    }
    const signal_y_offset = power_max_y + section_gap;

    // Offset signal blocks below power section
    for (sig_blocks.items) |*blk| {
        blk.y += signal_y_offset;
    }

    var signal_max_y: f64 = 0;
    for (sig_blocks.items) |blk| {
        const bottom = blk.y + blk.h;
        if (bottom > signal_max_y) signal_max_y = bottom;
    }
    const support_y_offset = signal_max_y + section_gap;

    // Offset support blocks below signal section
    for (sup_blocks.items) |*blk| {
        blk.y += support_y_offset;
    }

    // Build port→net name mapping for serialization
    var port_net_map = PortNetMap.init(allocator);
    for (design.net_ties) |nt| {
        const a_slash = std.mem.indexOfScalar(u8, nt.a, '/') != null;
        const b_slash = std.mem.indexOfScalar(u8, nt.b, '/') != null;
        if (a_slash or b_slash) {
            const sides = [_][]const u8{ nt.a, nt.b };
            for (sides) |side| {
                if (std.mem.indexOfScalar(u8, side, '/')) |slash| {
                    const sb_name = side[0..slash];
                    const port_name = side[slash + 1 ..];
                    const plain_net = if (!a_slash) nt.a else if (!b_slash) nt.b else continue;
                    const key = try std.fmt.allocPrint(allocator, PIN_KEY_FMT, .{ sb_name, port_name });
                    try port_net_map.put(key, plain_net);
                }
            }
        } else {
            for (result.blocks.items) |blk| {
                for (blk.ports) |p| {
                    if (std.mem.eql(u8, p.name, nt.b)) {
                        const key = try std.fmt.allocPrint(allocator, PIN_KEY_FMT, .{ blk.title, nt.b });
                        try port_net_map.put(key, nt.a);
                    }
                }
            }
        }
    }

    // Combine into single response
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"blocks\":[");
    const power_count = pwr_blocks.items.len;
    // Power blocks (component-based)
    for (pwr_blocks.items, 0..) |blk, i| {
        if (i > 0) try w.writeAll(",");
        try serializeBlock(w, blk, "power", &port_net_map);
    }
    // Signal blocks
    for (sig_blocks.items, 0..) |blk, i| {
        if (i > 0 or power_count > 0) try w.writeAll(",");
        try serializeBlock(w, blk, "signal", &port_net_map);
    }
    // Support blocks
    const signal_count = sig_blocks.items.len;
    for (sup_blocks.items, 0..) |blk, i| {
        if (i > 0 or power_count > 0 or signal_count > 0) try w.writeAll(",");
        try serializeBlock(w, blk, "support", &port_net_map);
    }
    try w.writeAll("],\"edges\":[");
    // Power edges
    var edge_written = false;
    for (pwr_edges.items) |edge| {
        if (edge_written) try w.writeAll(",");
        try serializeEdge(w, edge, 0);
        edge_written = true;
    }
    // Signal edges (offset indices by power block count)
    for (sig_edges.items) |edge| {
        if (edge_written) try w.writeAll(",");
        try serializeEdge(w, edge, power_count);
        edge_written = true;
    }
    try w.writeAll("],\"sections\":[");
    try w.print("{{\"name\":\"Power Flow\",\"y\":{d:.1}}}", .{top_margin - SECTION_LABEL_OFFSET});
    try w.print(",{{\"name\":\"Signal Flow\",\"y\":{d:.1}}}", .{signal_y_offset - SECTION_LABEL_OFFSET});
    if (sup_blocks.items.len > 0)
        try w.print(",{{\"name\":\"Support\",\"y\":{d:.1}}}", .{support_y_offset - SECTION_LABEL_OFFSET});
    try w.writeAll("],\"columns\":[");
    // Power section column labels
    const pwr_col_names = [_][]const u8{ "Input", "Regulation", "Peripherals", "Output" };
    var col_written = false;
    for (0..4) |c| {
        var col_x: ?f64 = null;
        var col_min_y: f64 = 9999.0;
        for (pwr_blocks.items) |blk| {
            if (blk.col == c) {
                if (col_x == null) col_x = blk.x;
                if (blk.y < col_min_y) col_min_y = blk.y;
            }
        }
        if (col_x) |x| {
            if (col_written) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\",\"x\":{d:.1},\"y\":{d:.1}}}", .{ pwr_col_names[c], x, col_min_y - COLUMN_LABEL_OFFSET });
            col_written = true;
        }
    }
    // Signal section column labels
    const sig_col_names = [_][]const u8{ "Input", "Hub", "Peripherals", "Output" };
    for (0..4) |c| {
        var col_x: ?f64 = null;
        var col_min_y: f64 = 9999.0;
        for (sig_blocks.items) |blk| {
            if (blk.col == c) {
                if (col_x == null) col_x = blk.x;
                if (blk.y < col_min_y) col_min_y = blk.y;
            }
        }
        if (col_x) |x| {
            if (col_written) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\",\"x\":{d:.1},\"y\":{d:.1}}}", .{ sig_col_names[c], x, col_min_y - COLUMN_LABEL_OFFSET });
            col_written = true;
        }
    }
    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}
