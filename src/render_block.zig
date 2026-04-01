const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const types = @import("render_block_types.zig");

const Allocator = std.mem.Allocator;

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

pub fn renderBlockDiagram(allocator: Allocator, design: *const DesignBlock) ![]const u8 {
    var blocks: std.ArrayListUnmanaged(Block) = .empty;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;

    // Sections with sub_sections become hub blocks (center column)
    // Sections without sub_sections become peripheral blocks
    var hub_idx: ?usize = null;

    for (design.sections) |sec| {
        if (sec.sub_sections.len > 0) {
            // Hub block — merges sub-sections as internal detail
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
            // Collect IO protocols from sibling sections
            var io_protocols: std.ArrayListUnmanaged([]const u8) = .empty;
            for (design.sections) |other| {
                if (other.sub_sections.len > 0) continue;
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
                .detail = if (hub_detail_buf.items.len > 0) (try allocator.dupe(u8, hub_detail_buf.items)) else (if (sec.description.len > 0) sec.description else ""),
                .category = .mcu,
                .ports = sec.ports,
                .col = 1,
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

        try blocks.append(allocator, .{
            .title = sec.name,
            .subtitle = key_comp,
            .detail = if (detail_buf.items.len > 0) (try allocator.dupe(u8, detail_buf.items)) else "",
            .category = cat,
            .ports = sec.ports,
            .col = switch (cat) {
                .power => 0,
                .clock => 0,
                .mcu => 1,
                .memory => 2,
                .peripheral => 2,
                .connector => 2,
            },
        });
    }

    // Build edges
    const center_idx = hub_idx orelse 0;
    for (blocks.items, 0..) |src, si| {
        for (src.ports) |sp| {
            if (sp.direction != .out) continue;
            if ((sp.signal_type == .power or sp.signal_type == .clock) and hub_idx != null) {
                if (!types.edgeExists(edges.items, si, center_idx, sp.name))
                    try edges.append(allocator, .{ .from = si, .to = center_idx, .label = sp.name, .signal_type = sp.signal_type, .voltage = sp.voltage });
                continue;
            }
            for (blocks.items, 0..) |dst, di| {
                if (si == di) continue;
                for (dst.ports) |dp| {
                    if (dp.direction == .out) continue;
                    if (std.mem.eql(u8, sp.name, dp.name) and !types.edgeExists(edges.items, si, di, sp.name))
                        try edges.append(allocator, .{ .from = si, .to = di, .label = sp.name, .signal_type = sp.signal_type, .voltage = sp.voltage });
                }
            }
        }
    }
    // Hub → peripheral signal edges (from hub's sub-section outputs)
    if (hub_idx) |hi| {
        for (blocks.items, 0..) |blk, bi| {
            if (bi == hi) continue;
            for (blk.ports) |p| {
                if (p.signal_type == .power) continue;
                if (p.direction == .in or p.direction == .io) {
                    for (design.sections) |sec| {
                        if (sec.sub_sections.len == 0) continue;
                        for (sec.sub_sections) |sub| {
                            for (sub.ports) |sp| {
                                if (sp.direction == .out and std.mem.eql(u8, sp.name, p.name) and !types.edgeExists(edges.items, hi, bi, p.name))
                                    try edges.append(allocator, .{ .from = hi, .to = bi, .label = p.name, .signal_type = sp.signal_type, .voltage = sp.voltage });
                            }
                        }
                        for (sec.ports) |sp| {
                            if (sp.direction == .out and std.mem.eql(u8, sp.name, p.name) and !types.edgeExists(edges.items, hi, bi, p.name))
                                try edges.append(allocator, .{ .from = hi, .to = bi, .label = p.name, .signal_type = sp.signal_type, .voltage = sp.voltage });
                        }
                    }
                }
            }
        }
        // IO protocol edges
        for (blocks.items, 0..) |blk, bi| {
            if (bi == hi) continue;
            for (blk.ports) |p| {
                if (p.direction == .io and p.protocol.len > 0 and
                    !types.edgeExists(edges.items, hi, bi, p.protocol) and
                    !types.edgeExists(edges.items, bi, hi, p.protocol))
                    try edges.append(allocator, .{ .from = hi, .to = bi, .label = p.protocol, .signal_type = p.signal_type, .voltage = null });
            }
        }
    }

    // Compute block sizes (non-MCU)
    for (blocks.items) |*blk| {
        if (blk.category == .mcu) continue;
        var n_lines: f64 = 1;
        if (blk.subtitle.len > 0) n_lines += 1;
        if (blk.detail.len > 0) n_lines += 1;
        blk.h = @max(block_min_h, n_lines * line_h + block_pad * 2);
    }

    // Layout columns 0 and 2 first to determine total height
    const n_cols: usize = 3;
    var col_lists: [3]std.ArrayListUnmanaged(usize) = .{ .empty, .empty, .empty };
    for (blocks.items, 0..) |blk, i| {
        try col_lists[@min(blk.col, n_cols - 1)].append(allocator, i);
    }

    // Compute side column heights
    var max_side_h: f64 = 0;
    for ([_]usize{ 0, 2 }) |c| {
        var h: f64 = 0;
        for (col_lists[c].items) |idx| {
            h += blocks.items[idx].h + grid_gap_y;
        }
        if (h > 0) h -= grid_gap_y;
        max_side_h = @max(max_side_h, h);
    }

    // MCU block spans full height
    const mcu_h = @max(max_side_h, 300.0);
    blocks.items[center_idx].h = mcu_h;
    blocks.items[center_idx].w = block_w * 1.0;

    // Position columns
    const col0_x = margin;
    const col1_x = margin + block_w + grid_gap_x;
    const col2_x = col1_x + blocks.items[center_idx].w + grid_gap_x;

    // Position MCU
    blocks.items[center_idx].x = col1_x;
    blocks.items[center_idx].y = top_margin;

    // Position side columns, vertically centered relative to MCU
    for ([_]usize{ 0, 2 }) |c| {
        var col_h: f64 = 0;
        for (col_lists[c].items) |idx| col_h += blocks.items[idx].h + grid_gap_y;
        if (col_h > 0) col_h -= grid_gap_y;

        const col_top = top_margin + (mcu_h - col_h) / 2.0;
        var cy = @max(top_margin, col_top);
        const cx: f64 = if (c == 0) col0_x else col2_x;
        for (col_lists[c].items) |idx| {
            blocks.items[idx].x = cx;
            blocks.items[idx].y = cy;
            cy += blocks.items[idx].h + grid_gap_y;
        }
    }

    // SVG dimensions
    var svg_w: f64 = 0;
    var svg_h: f64 = 0;
    for (blocks.items) |blk| {
        svg_w = @max(svg_w, blk.x + blk.w + margin);
        svg_h = @max(svg_h, blk.y + blk.h + margin);
    }

    // ── Render ────────────────────────────────────────────────────────
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {d:.0} {d:.0}">
        \\<defs>
        \\  <filter id="shadow" x="-4%" y="-4%" width="108%" height="108%">
        \\    <feDropShadow dx="0" dy="2" stdDeviation="3" flood-opacity="0.25"/>
        \\  </filter>
        \\</defs>
        \\<style>
        \\  text {{ font-family: -apple-system, 'Segoe UI', sans-serif; }}
        \\  .block {{ filter: url(#shadow); }}
        \\  .block:hover rect {{ stroke-width: 2.5; }}
        \\  .block-title {{ font-size: 14px; font-weight: 700; fill: #e6edf3; }}
        \\  .block-sub {{ font-size: 11px; fill: #c9d1d9; font-weight: 500; }}
        \\  .block-detail {{ font-size: 10px; fill: #8b949e; }}
        \\  .edge-label {{ font-size: 10px; fill: #c9d1d9; font-family: monospace; }}
        \\  .voltage {{ font-size: 9px; font-weight: 700; font-family: monospace; }}
        \\  .mcu-port {{ font-size: 10px; fill: #8b949e; font-family: monospace; }}
        \\</style>
        \\<rect width="{d:.0}" height="{d:.0}" fill="#0d1117"/>
        \\
    , .{ svg_w, svg_h, svg_w, svg_h });

    // ── Pre-compute edge Y offsets per peripheral block ──────────────
    var periph_edge_count = try allocator.alloc(usize, blocks.items.len);
    var periph_edge_idx = try allocator.alloc(usize, edges.items.len);
    @memset(periph_edge_count, 0);
    for (edges.items, 0..) |edge, ei| {
        const periph_idx = if (edge.from == center_idx) edge.to else edge.from;
        periph_edge_idx[ei] = periph_edge_count[periph_idx];
        periph_edge_count[periph_idx] += 1;
    }

    // ── Draw edges ────────────────────────────────────────────────────
    for (edges.items, 0..) |edge, ei| {
        const src = blocks.items[edge.from];
        const dst = blocks.items[edge.to];
        const color = types.signalColor(edge.signal_type);
        const sw: f64 = if (edge.signal_type == .power) 2.5 else 1.5;
        const mcu = blocks.items[center_idx];

        const is_from_mcu = (edge.from == center_idx);
        const periph_idx = if (is_from_mcu) edge.to else edge.from;
        const periph = blocks.items[periph_idx];

        // Distribute edges vertically across the peripheral block
        const n_edges = periph_edge_count[periph_idx];
        const edge_i = periph_edge_idx[ei];
        const edge_spacing: f64 = 14.0;
        const total_edge_span = @as(f64, @floatFromInt(n_edges - 1)) * edge_spacing;
        const periph_y = periph.y + periph.h / 2.0 - total_edge_span / 2.0 + @as(f64, @floatFromInt(edge_i)) * edge_spacing;

        // MCU attachment: match peripheral Y, clamped
        const mcu_y = std.math.clamp(periph_y, mcu.y + 20.0, mcu.y + mcu.h - 20.0);

        var x1: f64 = undefined;
        var y1: f64 = undefined;
        var x2: f64 = undefined;
        var y2: f64 = undefined;

        if (is_from_mcu) {
            x1 = mcu.x + mcu.w;
            y1 = mcu_y;
            x2 = periph.x;
            y2 = periph_y;
        } else if (periph.x + periph.w < mcu.x) {
            x1 = periph.x + periph.w;
            y1 = periph_y;
            x2 = mcu.x;
            y2 = mcu_y;
        } else {
            x1 = src.x + src.w;
            y1 = src.y + src.h / 2.0;
            x2 = dst.x;
            y2 = dst.y + dst.h / 2.0;
        }

        // Draw the connection line
        if (@abs(y1 - y2) < 1.0) {
            try w.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"{s}\" stroke-width=\"{d:.1}\" opacity=\"0.7\"/>\n", .{ x1, y1, x2, y2, color, sw });
        } else {
            const mid_x = (x1 + x2) / 2.0;
            try w.print("<polyline points=\"{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d:.1}\" opacity=\"0.7\"/>\n", .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2, color, sw });
        }

        // Arrowhead
        if (x2 > x1) {
            try w.print("<polygon points=\"{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}\" fill=\"{s}\" opacity=\"0.8\"/>\n", .{
                x2, y2, x2 - arrow_size, y2 - arrow_size / 2.0, x2 - arrow_size, y2 + arrow_size / 2.0, color,
            });
        } else {
            try w.print("<polygon points=\"{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}\" fill=\"{s}\" opacity=\"0.8\"/>\n", .{
                x2, y2, x2 + arrow_size, y2 - arrow_size / 2.0, x2 + arrow_size, y2 + arrow_size / 2.0, color,
            });
        }

        // Edge label
        const label_x = x1 + (x2 - x1) * 0.3;
        const label_y = y1 - 5.0;
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" class=\"edge-label\">{s}", .{ label_x, label_y, edge.label });
        if (edge.voltage) |v| {
            try w.print(" <tspan class=\"voltage\" fill=\"{s}\">{d:.1}V</tspan>", .{ color, v });
        }
        try w.writeAll("</text>\n");

        // Port label on MCU side
        const mcu_label_x = if (is_from_mcu) mcu.x + mcu.w - 8 else mcu.x + 8;
        const mcu_anchor: []const u8 = if (is_from_mcu) "end" else "start";
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"{s}\" class=\"mcu-port\">{s}</text>\n", .{ mcu_label_x, mcu_y + 4, mcu_anchor, edge.label });
    }

    // ── Draw blocks ───────────────────────────────────────────────────
    for (blocks.items) |blk| {
        const cat_color = types.categoryColor(blk.category);
        try w.print("<g class=\"block\" data-section=\"{s}\">\n", .{blk.title});

        // Background
        try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"8\" fill=\"#161b22\" stroke=\"#30363d\" stroke-width=\"1.5\"/>\n", .{ blk.x, blk.y, blk.w, blk.h });

        // Color accent bar
        if (blk.category == .mcu) {
            try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"4\" height=\"{d:.1}\" rx=\"2\" fill=\"{s}\"/>\n", .{ blk.x, blk.y + 8, blk.h - 16, cat_color });
            try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"4\" height=\"{d:.1}\" rx=\"2\" fill=\"{s}\"/>\n", .{ blk.x + blk.w - 4, blk.y + 8, blk.h - 16, cat_color });
        } else {
            try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"4\" height=\"{d:.1}\" rx=\"2\" fill=\"{s}\"/>\n", .{ blk.x, blk.y + 8, blk.h - 16, cat_color });
        }

        // Title + subtitle + detail
        const text_h: f64 = types.blk_text_height(blk);
        const text_top = blk.y + (blk.h - text_h) / 2.0;

        var ty = text_top + 14;
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" class=\"block-title\">{s}</text>\n", .{ blk.x + blk.w / 2.0, ty, blk.title });

        if (blk.subtitle.len > 0) {
            ty += line_h;
            try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" class=\"block-sub\">{s}</text>\n", .{ blk.x + blk.w / 2.0, ty, blk.subtitle });
        }
        if (blk.detail.len > 0) {
            ty += line_h - 2;
            const max_chars = @as(usize, @intFromFloat((blk.w - 24.0) / 6.0));
            const detail = if (blk.detail.len > max_chars and max_chars > 3)
                blk.detail[0 .. max_chars - 2]
            else
                blk.detail;
            const ellipsis: []const u8 = if (blk.detail.len > max_chars and max_chars > 3) ".." else "";
            try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" class=\"block-detail\">{s}{s}</text>\n", .{ blk.x + blk.w / 2.0, ty, detail, ellipsis });
        }

        try w.writeAll("</g>\n");
    }

    try w.writeAll("</svg>\n");
    return buf.toOwnedSlice(allocator);
}
