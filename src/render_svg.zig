const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;

const ctx_mod = @import("render_svg/context.zig");
pub const RenderCtx = ctx_mod.RenderCtx;
const hub = @import("render_svg/hub.zig");
const branch = @import("render_svg/branch.zig");
const draw = @import("render_svg/draw.zig");
const bom_table = @import("render_svg/bom_table.zig");
const top_margin = draw.top_margin;

const Allocator = std.mem.Allocator;

// Force-reference sub-modules for test coverage
comptime {
    _ = @import("render_svg/draw.zig");
    _ = @import("render_svg/context.zig");
    _ = @import("render_svg/hub.zig");
    _ = @import("render_svg/connection.zig");
    _ = @import("render_svg/branch.zig");
}

// ── Public entry point ────────────────────────────────────────────────

pub fn renderSchematic(allocator: Allocator, block: *const DesignBlock) ![]const u8 {
    var ctx = RenderCtx.init(allocator);

    // Flatten hierarchy
    try ctx.collectFlat(block, "");

    // Build section membership map (ref_des -> section index)
    var flat_sec_idx: usize = 0;
    for (block.sections) |sec| {
        for (sec.instances) |inst| {
            try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
        }
        flat_sec_idx += 1;
        for (sec.sub_sections) |sub| {
            for (sub.instances) |inst| {
                try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
            }
            flat_sec_idx += 1;
        }
    }

    // Build pin->net lookup
    try ctx.buildPinNetMap();

    // Classify hub vs spoke
    try ctx.classify();

    // Build adjacency from flat nets
    try ctx.buildAdjacency();

    // Synthesize spoke connections for passives on named nets
    try ctx.synthesizeSpokeConnections();

    // Build net index (net name -> list of pin refs)
    try ctx.buildNetIndex();

    // Build significant nets + port nets
    try ctx.buildSignificantNets(block);

    // Build canonical net for each hub pin
    try ctx.buildPinCanonicalNets();

    // Validate net consistency
    try ctx.validateNetConsistency();

    // Render
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    // Build grid cells from sections (auto grid layout).
    const GridCell = struct {
        hub_inst: ctx_mod.FlatInst,
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

    // Grid layout constants
    const cell_width: f64 = 850.0;
    const cell_gap_y: f64 = 30.0;
    const cell_gap_x: f64 = 40.0;
    const section_pad: f64 = 30.0;
    const title_font_size: f64 = 24.0;
    const desc_font_size: f64 = 15.0;
    const note_font_size: f64 = 11.0;
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

    // Pass 1: Measure cell heights
    var cell_heights = try allocator.alloc(f64, cells.items.len);
    defer allocator.free(cell_heights);

    for (cells.items, 0..) |cell, ci| {
        var measure_buf: std.ArrayListUnmanaged(u8) = .empty;
        const mw = measure_buf.writer(allocator);
        cell_heights[ci] = if (cell.part) |part|
            try hub.renderHubPart(&ctx, mw, cell.hub_inst, part, 0)
        else
            try hub.renderHub(&ctx, mw, cell.hub_inst, 0);
        measure_buf.deinit(allocator);
    }

    ctx.rendered_spokes.clearRetainingCapacity();

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

    // Pass 2: Render each section as a grid cell
    for (section_grid.items, 0..) |sg, si| {
        if (sg.cell_indices.items.len == 0) continue;
        const grid_row = si / n_cols;
        const grid_col = si % n_cols;
        const x_offset = @as(f64, @floatFromInt(grid_col)) * (cell_width + cell_gap_x);
        const cell_y = row_y_positions[grid_row];
        const section_h = row_heights[grid_row];
        const section_name = sg.name;
        const box_x = x_offset + 8.0;
        const box_w = cell_width - 16.0;
        const center_x = x_offset + cell_width / 2.0;
        const header_h = section_header_heights[si];

        try w.writeAll("<g class=\"section\" data-section=\"");
        try w.writeAll(section_name);
        try w.writeAll("\">\n");

        if (section_grid.items.len > 1 or sg.cell_indices.items.len > 0) {
            try w.print(
                \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" rx="8" fill="#0d1117" stroke="#21262d" stroke-width="1.5" pointer-events="none"/>
                \\
            , .{ box_x, cell_y, box_w, section_h });

            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="{d:.0}" font-weight="bold" fill="#8b949e" pointer-events="none">{s}</text>
                \\
            , .{ center_x, cell_y + title_font_size + 6.0, title_font_size, section_name });

            if (sg.description.len > 0) {
                try w.print(
                    \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="{d:.0}" fill="#6e7681" font-style="italic" pointer-events="none">{s}</text>
                    \\
                , .{ center_x, cell_y + title_font_size + 6.0 + desc_font_size + 6.0, desc_font_size, sg.description });
            }
        }

        try w.print("<g transform=\"translate({d:.0},0)\">\n", .{x_offset});
        var content_y = cell_y + header_h + section_pad;
        for (sg.cell_indices.items) |ci| {
            const cell = cells.items[ci];
            const h = if (cell.part) |part|
                try hub.renderHubPart(&ctx, w, cell.hub_inst, part, content_y)
            else
                try hub.renderHub(&ctx, w, cell.hub_inst, content_y);
            content_y += h + 40.0;
        }
        try w.writeAll("</g>\n");

        if (sg.notes.len > 0) {
            const notes_y = cell_y + section_h - section_footer_heights[si] + 8.0;
            try w.print(
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#21262d" stroke-width="1" pointer-events="none"/>
                \\
            , .{ box_x + 12.0, notes_y, box_x + box_w - 12.0, notes_y });
            var note_y = notes_y + note_line_height;
            for (sg.notes) |note_text| {
                try w.print(
                    \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#6e7681" font-style="italic" pointer-events="none">{s}</text>
                    \\
                , .{ box_x + 16.0, note_y, note_font_size, note_text });
                note_y += note_line_height;
            }
        }

        try w.writeAll("</g>\n");
    }

    // Port block
    if (block.ports.len > 0) {
        y += 20.0;
        const icon = branch.inferBlockIcon(&ctx, block);
        const port_h = try branch.renderPortBlock(&ctx, w, block.name, block.ports, y, icon);
        y += port_h + 40.0;
    }
    for (block.sub_blocks) |sb| {
        if (sb.block.ports.len > 0) {
            y += 10.0;
            const icon = branch.inferBlockIcon(&ctx, sb.block);
            const port_h = try branch.renderPortBlock(&ctx, w, sb.name, sb.block.ports, y, icon);
            y += port_h + 40.0;
        }
    }

    // Wrap in SVG
    const vb_w = @max(total_width, 850.0);
    const vb_h = @max(y + 40.0, 400.0);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const ow = out.writer(allocator);
    try ow.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {d:.0} {d:.0}">
        \\  <g class="hub-group" data-ref="{s}" transform="translate(0,0)">
        \\
    , .{ vb_w, vb_h, block.name });
    try ow.writeAll(buf.items);
    try ow.writeAll("</g>\n</svg>");
    return out.toOwnedSlice(allocator);
}

pub const renderBomTable = bom_table.renderBomTable;
pub const collectAllInstances = bom_table.collectAllInstances;
