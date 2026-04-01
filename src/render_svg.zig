const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;
const PinRef = env_mod.PinRef;
const Port = env_mod.Port;

// ── Layout Constants (matching Gleam) ──────────────────────────────────
const hub_width: f64 = 180.0;
const pin_stub: f64 = 40.0;
const spoke_len: f64 = 80.0;
const net_label_gap: f64 = 18.0;
const hub_x: f64 = 320.0;
const top_margin: f64 = 80.0;
const passive_bw: f64 = 40.0;
const passive_bh: f64 = 20.0;
const passive_hit_w: f64 = 52.0;
const passive_hit_h: f64 = 38.0;
const branch_spacing: f64 = 40.0;
const per_conn_spacing: f64 = 40.0;
const bus_gap: f64 = 15.0;

const Allocator = std.mem.Allocator;

// ── Flat types ─────────────────────────────────────────────────────────

const FlatInst = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    parts: []const env_mod.Part = &.{},
};

const FlatNet = struct {
    name: []const u8,
    pins: []const PinRef,
};

const Side = enum { left, right };

/// An endpoint in the adjacency list — either a named net or a pin on another component.
const Endpoint = union(enum) {
    net: []const u8,
    pin: struct { ref_des: []const u8, pin: []const u8 },
};

/// A connection entry: (pin_id, endpoint).
const AdjEntry = struct {
    pin: []const u8,
    endpoint: Endpoint,
};

/// Branch: chain of instances + terminal net name.
const Branch = struct {
    chain: []const FlatInst,
    terminal: []const u8,
};

const BranchBody = struct {
    end_x: f64,
    cy: f64,
    terminal: []const u8,
};

// ── Public entry point ─────────────────────────────────────────────────

pub fn renderSchematic(allocator: Allocator, block: *const DesignBlock) ![]const u8 {
    var ctx = RenderCtx.init(allocator);

    // Flatten hierarchy
    try ctx.collectFlat(block, "");

    // Build section membership map (ref_des → section index)
    // Flatten sub-sections: sub-section instances get the parent's index
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

    // Build pin→net lookup
    try ctx.buildPinNetMap();

    // Classify hub vs spoke
    try ctx.classify();

    // Build adjacency from flat nets
    try ctx.buildAdjacency();

    // Synthesize spoke connections for passives on named nets
    try ctx.synthesizeSpokeConnections();

    // Build net index (net name → list of pin refs)
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
    // Each section = one grid cell. Hubs not in any section go into an implicit cell.
    const GridCell = struct {
        hub: FlatInst,
        part: ?env_mod.Part,
        section_idx: usize, // index into section_grid
    };

    // Build section membership: ref_des → section index
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
        // Flatten sub-sections into the grid as their own cells
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
        const hub = ctx.inst_map.get(hub_ref) orelse continue;
        if (hub.parts.len > 0) {
            // Multi-part: each part goes to the section with matching name
            for (hub.parts) |part| {
                var sec_idx: usize = 0;
                for (section_grid.items, 0..) |sg, si| {
                    if (std.mem.eql(u8, sg.name, part.name)) {
                        sec_idx = si;
                        break;
                    }
                }
                const ci = cells.items.len;
                try cells.append(allocator, .{ .hub = hub, .part = part, .section_idx = sec_idx });
                try section_grid.items[sec_idx].cell_indices.append(allocator, ci);
            }
        } else {
            // Simple instance: find section by ref_des
            const sec_idx = ref_to_section.get(hub.ref_des) orelse blk: {
                // No section — create or reuse an implicit "Other" section
                for (section_grid.items, 0..) |sg, si| {
                    if (std.mem.eql(u8, sg.name, hub.component)) break :blk si;
                }
                const si = section_grid.items.len;
                try section_grid.append(allocator, .{ .name = hub.component, .description = "", .notes = &.{}, .cell_indices = .empty });
                break :blk si;
            };
            const ci = cells.items.len;
            try cells.append(allocator, .{ .hub = hub, .part = null, .section_idx = sec_idx });
            try section_grid.items[sec_idx].cell_indices.append(allocator, ci);
        }
    }

    // Auto grid dimensions: aim for roughly square
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

    // Compute per-section header height (title + optional description)
    var section_header_heights = try allocator.alloc(f64, section_grid.items.len);
    defer allocator.free(section_header_heights);
    for (section_grid.items, 0..) |sg, si| {
        var h: f64 = title_font_size + 12.0; // title + padding
        if (sg.description.len > 0) h += desc_font_size + 6.0;
        section_header_heights[si] = h;
    }

    // Compute per-section footer height (notes)
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
            try ctx.renderHubPart(mw, cell.hub, part, 0)
        else
            try ctx.renderHub(mw, cell.hub, 0);
        measure_buf.deinit(allocator);
    }

    ctx.rendered_spokes.clearRetainingCapacity();

    // Compute row heights from section grid positions
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

        // Section wrapper
        try w.writeAll("<g class=\"section\" data-section=\"");
        try w.writeAll(section_name);
        try w.writeAll("\">\n");

        // Draw section box
        if (section_grid.items.len > 1 or sg.cell_indices.items.len > 0) {
            try w.print(
                \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" rx="8" fill="#0d1117" stroke="#21262d" stroke-width="1.5" pointer-events="none"/>
                \\
            , .{ box_x, cell_y, box_w, section_h });

            // Centered title
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="{d:.0}" font-weight="bold" fill="#8b949e" pointer-events="none">{s}</text>
                \\
            , .{ center_x, cell_y + title_font_size + 6.0, title_font_size, section_name });

            // Optional description under title
            if (sg.description.len > 0) {
                try w.print(
                    \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="{d:.0}" fill="#6e7681" font-style="italic" pointer-events="none">{s}</text>
                    \\
                , .{ center_x, cell_y + title_font_size + 6.0 + desc_font_size + 6.0, desc_font_size, sg.description });
            }
        }

        // Render all hubs/parts in this section stacked vertically
        try w.print("<g transform=\"translate({d:.0},0)\">\n", .{x_offset});
        var content_y = cell_y + header_h + section_pad;
        for (sg.cell_indices.items) |ci| {
            const cell = cells.items[ci];
            const h = if (cell.part) |part|
                try ctx.renderHubPart(w, cell.hub, part, content_y)
            else
                try ctx.renderHub(w, cell.hub, content_y);
            content_y += h + 40.0;
        }
        try w.writeAll("</g>\n");

        // Notes at the bottom of the section
        if (sg.notes.len > 0) {
            const notes_y = cell_y + section_h - section_footer_heights[si] + 8.0;
            // Separator line
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

    // Port block — infer icon from first hub
    if (block.ports.len > 0) {
        y += 20.0;
        const icon = ctx.inferBlockIcon(block);
        const port_h = try ctx.renderPortBlock(w, block.name, block.ports, y, icon);
        y += port_h + 40.0;
    }
    // Sub-block ports
    for (block.sub_blocks) |sb| {
        if (sb.block.ports.len > 0) {
            y += 10.0;
            const icon = ctx.inferBlockIcon(sb.block);
            const port_h = try ctx.renderPortBlock(w, sb.name, sb.block.ports, y, icon);
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

// ── BOM Table ──────────────────────────────────────────────────────────

fn renderBomTable(allocator: Allocator, w: anytype, block: *const DesignBlock, y_start: f64, table_width: f64) !f64 {
    // Collect all instances (recursively through sub-blocks)
    var all_instances: std.ArrayListUnmanaged(env_mod.Instance) = .empty;
    defer all_instances.deinit(allocator);
    try collectAllInstances(allocator, block, &all_instances);

    if (all_instances.items.len == 0) return 0;

    // Group by (component, value, footprint, attrs_key)
    const BomKey = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        attrs_key: []const u8,
    };
    const BomEntry = struct {
        key: BomKey,
        count: u32,
        ref_des_list: std.ArrayListUnmanaged([]const u8),
        mpn: []const u8,
        manufacturer: []const u8,
    };

    var entries: std.ArrayListUnmanaged(BomEntry) = .empty;
    defer {
        for (entries.items) |*e| e.ref_des_list.deinit(allocator);
        entries.deinit(allocator);
    }

    for (all_instances.items) |inst| {
        // Build attrs key string
        const attrs_key = if (inst.attrs.len > 0) blk: {
            var ab: std.ArrayListUnmanaged(u8) = .empty;
            for (inst.attrs, 0..) |attr, ai| {
                if (ai > 0) ab.append(allocator, ' ') catch {};
                ab.appendSlice(allocator, attr) catch {};
            }
            break :blk ab.toOwnedSlice(allocator) catch "";
        } else "";

        // Find existing entry
        var found = false;
        for (entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key.component, inst.component) and
                std.mem.eql(u8, entry.key.value, inst.value) and
                std.mem.eql(u8, entry.key.footprint, inst.footprint) and
                std.mem.eql(u8, entry.key.attrs_key, attrs_key))
            {
                entry.count += 1;
                entry.ref_des_list.append(allocator, inst.ref_des) catch {};
                found = true;
                break;
            }
        }
        if (!found) {
            // Extract MPN and manufacturer from properties
            var mpn: []const u8 = "";
            var manufacturer: []const u8 = "";
            for (inst.properties) |prop| {
                if (std.mem.eql(u8, prop.key, "mpn")) mpn = prop.value;
                if (std.mem.eql(u8, prop.key, "manufacturer")) manufacturer = prop.value;
            }
            var ref_list: std.ArrayListUnmanaged([]const u8) = .empty;
            ref_list.append(allocator, inst.ref_des) catch {};
            entries.append(allocator, .{
                .key = .{
                    .component = inst.component,
                    .value = inst.value,
                    .footprint = inst.footprint,
                    .attrs_key = attrs_key,
                },
                .count = 1,
                .ref_des_list = ref_list,
                .mpn = mpn,
                .manufacturer = manufacturer,
            }) catch {};
        }
    }

    if (entries.items.len == 0) return 0;

    // Sort by component name, then value
    std.mem.sortUnstable(BomEntry, entries.items, {}, struct {
        fn lt(_: void, a: BomEntry, b: BomEntry) bool {
            const cmp = std.mem.order(u8, a.key.component, b.key.component);
            if (cmp == .lt) return true;
            if (cmp == .gt) return false;
            return std.mem.order(u8, a.key.value, b.key.value) == .lt;
        }
    }.lt);

    // Layout constants
    const row_height: f64 = 20.0;
    const header_height: f64 = 28.0;
    const title_height: f64 = 30.0;
    const pad_x: f64 = 12.0;
    const font_size: f64 = 11.0;
    const header_font: f64 = 11.0;
    const x = 8.0;
    const w_total = @min(table_width - 16.0, 1600.0);

    // Column widths (proportional)
    const col_qty: f64 = 40.0;
    const col_refs: f64 = 160.0;
    const col_value: f64 = 80.0;
    const col_footprint: f64 = 120.0;
    const col_attrs: f64 = 80.0;
    const col_mpn: f64 = 200.0;
    const col_mfr: f64 = 160.0;
    const col_desc: f64 = w_total - col_qty - col_refs - col_value - col_footprint - col_attrs - col_mpn - col_mfr;

    const cols = [_]struct { label: []const u8, width: f64 }{
        .{ .label = "Qty", .width = col_qty },
        .{ .label = "Ref Des", .width = col_refs },
        .{ .label = "Value", .width = col_value },
        .{ .label = "Package", .width = col_footprint },
        .{ .label = "Type", .width = col_attrs },
        .{ .label = "MPN", .width = col_mpn },
        .{ .label = "Manufacturer", .width = col_mfr },
        .{ .label = "Component", .width = col_desc },
    };

    const total_rows = entries.items.len;
    const table_h = title_height + header_height + @as(f64, @floatFromInt(total_rows)) * row_height + 8.0;

    // Background box
    try w.print(
        \\<g class="bom-table">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" rx="8" fill="#0d1117" stroke="#21262d" stroke-width="1.5" pointer-events="none"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="18" font-weight="bold" fill="#8b949e" pointer-events="none">Bill of Materials</text>
        \\
    , .{
        x,                 y_start,        w_total, table_h,
        x + w_total / 2.0, y_start + 22.0,
    });

    // Header row
    const header_y = y_start + title_height;
    try w.print(
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.0}" fill="#161b22" pointer-events="none"/>
        \\
    , .{ x, header_y, w_total, header_height });

    var cx: f64 = x;
    for (cols) |col| {
        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" font-weight="bold" fill="#8b949e" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, header_y + 18.0, header_font, col.label });
        cx += col.width;
    }

    // Header separator
    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#21262d" stroke-width="1" pointer-events="none"/>
        \\
    , .{ x, header_y + header_height, x + w_total, header_y + header_height });

    // Data rows
    var ry = header_y + header_height;
    for (entries.items, 0..) |entry, ri| {
        // Alternate row background
        if (ri % 2 == 1) {
            try w.print(
                \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.0}" fill="#0d1117" pointer-events="none"/>
                \\
            , .{ x, ry, w_total, row_height });
        }

        // Build ref-des string
        var ref_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer ref_buf.deinit(allocator);
        for (entry.ref_des_list.items, 0..) |rd, rdi| {
            if (rdi > 0) ref_buf.appendSlice(allocator, ", ") catch {};
            ref_buf.appendSlice(allocator, rd) catch {};
        }
        const refs_str = ref_buf.items;

        const text_y = ry + 14.0;
        cx = x;

        // Qty
        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#e0e0e0" pointer-events="none">{d}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.count });
        cx += col_qty;

        // Ref Des
        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#79c0ff" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, refs_str });
        cx += col_refs;

        // Value
        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#e0e0e0" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.key.value });
        cx += col_value;

        // Package
        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#8b949e" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.key.footprint });
        cx += col_footprint;

        // Type/attrs
        if (entry.key.attrs_key.len > 0) {
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#d2a8ff" pointer-events="none">{s}</text>
                \\
            , .{ cx + pad_x, text_y, font_size, entry.key.attrs_key });
        }
        cx += col_attrs;

        // MPN
        if (entry.mpn.len > 0) {
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#e0e0e0" pointer-events="none">{s}</text>
                \\
            , .{ cx + pad_x, text_y, font_size, entry.mpn });
        }
        cx += col_mpn;

        // Manufacturer
        if (entry.manufacturer.len > 0) {
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#8b949e" pointer-events="none">{s}</text>
                \\
            , .{ cx + pad_x, text_y, font_size, entry.manufacturer });
        }
        cx += col_mfr;

        // Component
        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#8b949e" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.key.component });

        ry += row_height;
    }

    // Total count
    var total_parts: u32 = 0;
    for (entries.items) |entry| total_parts += entry.count;
    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" font-size="11" fill="#6e7681" pointer-events="none">{d} unique lines, {d} total parts</text>
        \\
    , .{ x + pad_x, ry + 16.0, entries.items.len, total_parts });

    try w.writeAll("</g>\n");
    return table_h + 20.0;
}

fn collectAllInstances(allocator: Allocator, block: *const DesignBlock, out: *std.ArrayListUnmanaged(env_mod.Instance)) !void {
    for (block.instances) |inst| {
        try out.append(allocator, inst);
    }
    for (block.sub_blocks) |sb| {
        try collectAllInstances(allocator, sb.block, out);
    }
}

// ── Render Context ─────────────────────────────────────────────────────

const RenderCtx = struct {
    allocator: Allocator,
    instances: std.ArrayListUnmanaged(FlatInst),
    nets: std.ArrayListUnmanaged(FlatNet),
    hub_order: std.ArrayListUnmanaged([]const u8),
    inst_map: std.StringHashMapUnmanaged(FlatInst),
    spoke_set: std.StringHashMapUnmanaged(void),
    // pin "REF.PIN_NUM" → net name
    pin_net: std.StringHashMapUnmanaged([]const u8),
    // ref_des → list of AdjEntry
    adjacency: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(AdjEntry)),
    // net name → list of PinRef
    net_index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PinRef)),
    significant_nets: std.StringHashMapUnmanaged(void),
    port_nets: std.StringHashMapUnmanaged(void),
    pin_canonical_nets: std.StringHashMapUnmanaged([]const u8),
    rendered_spokes: std.StringHashMapUnmanaged(void),
    /// ref_des → section index (for section-aware spoke connections)
    section_map: std.StringHashMapUnmanaged(usize),

    fn init(allocator: Allocator) RenderCtx {
        return .{
            .allocator = allocator,
            .instances = .empty,
            .nets = .empty,
            .hub_order = .empty,
            .inst_map = .empty,
            .spoke_set = .empty,
            .pin_net = .empty,
            .adjacency = .empty,
            .net_index = .empty,
            .significant_nets = .empty,
            .port_nets = .empty,
            .pin_canonical_nets = .empty,
            .rendered_spokes = .empty,
            .section_map = .empty,
        };
    }

    // ── Data collection ────────────────────────────────────────────────

    fn collectFlat(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8) !void {
        for (block.instances) |inst| {
            const rd = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, inst.ref_des })
            else
                inst.ref_des;
            const flat = FlatInst{
                .ref_des = rd,
                .component = inst.component,
                .value = inst.value,
                .symbol = inst.symbol,
                .parts = inst.parts,
            };
            try self.instances.append(self.allocator, flat);
            try self.inst_map.put(self.allocator, rd, flat);
        }
        for (block.nets) |net| {
            var pins: std.ArrayListUnmanaged(PinRef) = .empty;
            for (net.pins) |pin| {
                const rd = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, pin.ref_des })
                else
                    pin.ref_des;
                try pins.append(self.allocator, .{ .ref_des = rd, .pin = pin.pin });
            }
            const net_name = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, net.name })
            else
                net.name;
            try self.nets.append(self.allocator, .{
                .name = net_name,
                .pins = try pins.toOwnedSlice(self.allocator),
            });
        }
        for (block.sub_blocks) |sb| {
            const np = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, sb.name })
            else
                sb.name;
            try self.collectFlat(sb.block, np);
        }
    }

    fn buildPinNetMap(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            for (net.pins) |pin| {
                const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin });
                try self.pin_net.put(self.allocator, key, net.name);
            }
        }
    }

    fn classify(self: *RenderCtx) !void {
        for (self.instances.items) |inst| {
            if (isHub(inst)) {
                try self.hub_order.append(self.allocator, inst.ref_des);
            } else {
                try self.spoke_set.put(self.allocator, inst.ref_des, {});
            }
        }
    }

    /// Build adjacency from flat Net data.
    /// For each net, create bidirectional adjacency:
    /// - Each hub pin gets NetEndpoint for the net name
    /// - Each hub pin pair on the same net gets PinEndpoint connections
    fn buildAdjacency(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            // For each pin on this net, add a net endpoint
            for (net.pins) |pin| {
                try self.adjAppend(pin.ref_des, .{
                    .pin = pin.pin,
                    .endpoint = .{ .net = bn },
                });
            }
        }
    }

    /// Synthesize spoke connections: for passives on named nets shared with hubs,
    /// create virtual pin-to-pin adjacency entries.
    /// Supports "REF.NET" dot notation: a spoke on net "U4.VDD" only connects to hub U4.
    fn synthesizeSpokeConnections(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;

            // Check if this net uses NET.REF.PIN dot notation for hub targeting
            // e.g. "VDD.U1.J14" → hub_target = "U1"
            const short = shortNetName(net.name);
            const hub_target: ?[]const u8 = blk: {
                const first_dot = std.mem.indexOfScalar(u8, short, '.') orelse break :blk null;
                const rest = short[first_dot + 1 ..];
                const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse break :blk null;
                break :blk rest[0..second_dot];
            };

            // Find hub pins and spoke pins on this net
            var hub_pins_buf: [64]PinRef = undefined;
            var hub_count: usize = 0;
            var spoke_pins_buf: [64]PinRef = undefined;
            var spoke_count: usize = 0;

            for (net.pins) |pin| {
                if (self.spoke_set.contains(pin.ref_des)) {
                    // Check if this spoke pin is on a ground net on its other pin
                    // (skip spoke ground pins — they shouldn't be synthesized)
                    const is_ground_pin = self.isSpokeGroundPin(pin.ref_des, pin.pin);
                    if (!is_ground_pin) {
                        if (spoke_count < spoke_pins_buf.len) {
                            spoke_pins_buf[spoke_count] = pin;
                            spoke_count += 1;
                        }
                    }
                } else {
                    if (hub_count < hub_pins_buf.len) {
                        hub_pins_buf[hub_count] = pin;
                        hub_count += 1;
                    }
                }
            }

            // If dot notation targets a hub but no hub pins are on this net,
            // find hub pins on the base net name from other nets
            if (hub_target != null and hub_count == 0) {
                for (self.nets.items) |other_net| {
                    if (std.mem.eql(u8, other_net.name, net.name)) continue;
                    if (!std.mem.eql(u8, baseNetName(other_net.name), bn)) continue;
                    for (other_net.pins) |pin| {
                        if (!self.spoke_set.contains(pin.ref_des) and
                            std.mem.eql(u8, pin.ref_des, hub_target.?))
                        {
                            if (hub_count < hub_pins_buf.len) {
                                hub_pins_buf[hub_count] = pin;
                                hub_count += 1;
                            }
                        }
                    }
                }
            }

            // For each spoke pin, connect it to matching hub pins
            for (spoke_pins_buf[0..spoke_count]) |sp| {
                // Section-aware filtering: if spoke belongs to a section,
                // only connect to hubs in the same section
                const spoke_section = self.section_map.get(sp.ref_des);

                for (hub_pins_buf[0..hub_count]) |hp| {
                    // If hub target specified (dot notation), only connect to that hub
                    if (hub_target) |target| {
                        if (!std.mem.eql(u8, hp.ref_des, target)) continue;
                    }
                    // If spoke has a section, only connect to hubs in the same section
                    if (spoke_section) |ss| {
                        const hub_section = self.section_map.get(hp.ref_des);
                        if (hub_section) |hs| {
                            if (ss != hs) continue;
                        }
                    }
                    try self.adjAppend(hp.ref_des, .{
                        .pin = hp.pin,
                        .endpoint = .{ .pin = .{ .ref_des = sp.ref_des, .pin = sp.pin } },
                    });
                    try self.adjAppend(sp.ref_des, .{
                        .pin = sp.pin,
                        .endpoint = .{ .pin = .{ .ref_des = hp.ref_des, .pin = hp.pin } },
                    });
                }
            }
        }
    }

    /// Check if a spoke has its other pin connected to a ground net.
    fn isSpokeGroundPin(self: *RenderCtx, ref_des: []const u8, pin_id: []const u8) bool {
        // Find all nets this ref_des is on
        for (self.nets.items) |net| {
            for (net.pins) |p| {
                if (std.mem.eql(u8, p.ref_des, ref_des) and !std.mem.eql(u8, p.pin, pin_id)) {
                    // Check if THAT net is ground
                    if (isGroundNet(baseNetName(net.name))) return false; // This pin is the signal pin
                }
            }
        }
        // If this pin's net is ground, then yes it's a ground pin
        for (self.nets.items) |net| {
            for (net.pins) |p| {
                if (std.mem.eql(u8, p.ref_des, ref_des) and std.mem.eql(u8, p.pin, pin_id)) {
                    if (isGroundNet(baseNetName(net.name))) return true;
                }
            }
        }
        return false;
    }

    fn buildNetIndex(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                var list = self.net_index.get(bn) orelse std.ArrayListUnmanaged(PinRef){};
                try list.append(self.allocator, pin);
                try self.net_index.put(self.allocator, bn, list);
            }
        }
    }

    fn buildSignificantNets(self: *RenderCtx, block: *const DesignBlock) !void {
        // Port nets
        for (block.ports) |port| {
            try self.port_nets.put(self.allocator, baseNetName(port.net), {});
            try self.significant_nets.put(self.allocator, baseNetName(port.net), {});
        }
        for (block.sub_blocks) |sb| {
            for (sb.block.ports) |port| {
                const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sb.name, baseNetName(port.net) });
                try self.port_nets.put(self.allocator, full, {});
                try self.significant_nets.put(self.allocator, full, {});
            }
        }
        // Nets connecting 2+ hubs, or any non-GND net with a hub pin
        // (these serve as terminals when spokes chain through them)
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;
            var has_hub = false;
            for (net.pins) |pin| {
                if (!self.spoke_set.contains(pin.ref_des)) {
                    has_hub = true;
                    break;
                }
            }
            if (has_hub) {
                try self.significant_nets.put(self.allocator, bn, {});
            }
        }
        // Ground nets always significant
        for ([_][]const u8{ "GND", "AGND", "DGND", "VSS" }) |g| {
            try self.significant_nets.put(self.allocator, g, {});
        }
    }

    /// Build canonical net name for each hub pin.
    fn buildPinCanonicalNets(self: *RenderCtx) !void {
        // Direct net connections
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                if (!self.spoke_set.contains(pin.ref_des)) {
                    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin });
                    try self.pin_canonical_nets.put(self.allocator, key, bn);
                }
            }
        }
    }

    fn validateNetConsistency(self: *RenderCtx) !void {
        // Check 1: Hub pin ↔ net endpoint consistency
        var adj_it = self.adjacency.iterator();
        while (adj_it.next()) |kv| {
            const ref_des = kv.key_ptr.*;
            if (self.spoke_set.contains(ref_des)) continue;
            for (kv.value_ptr.items) |entry| {
                switch (entry.endpoint) {
                    .net => |endpoint_net| {
                        if (isGroundNet(endpoint_net)) continue;
                        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ref_des, entry.pin });
                        const pin_net_name = self.pin_net.get(key) orelse continue;
                        const pin_bn = baseNetName(pin_net_name);
                        const ep_bn = baseNetName(endpoint_net);
                        if (!std.mem.eql(u8, pin_bn, ep_bn)) {
                            std.debug.print("NET VALIDATE: {s} pin {s}: pin_net=\"{s}\" but adjacency endpoint=\"{s}\"\n", .{ ref_des, entry.pin, pin_bn, ep_bn });
                        }
                    },
                    .pin => {},
                }
            }
        }

        // Check 2: Spoke synthesized connection consistency
        var adj_it2 = self.adjacency.iterator();
        while (adj_it2.next()) |kv| {
            const ref_des = kv.key_ptr.*;
            if (!self.spoke_set.contains(ref_des)) continue;
            for (kv.value_ptr.items) |entry| {
                switch (entry.endpoint) {
                    .pin => |p| {
                        // Only report once per pair (alphabetical order)
                        if (std.mem.order(u8, ref_des, p.ref_des) == .gt) continue;
                        const key_a = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ref_des, entry.pin });
                        const key_b = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ p.ref_des, p.pin });
                        const net_a = self.pin_net.get(key_a) orelse continue;
                        const net_b = self.pin_net.get(key_b) orelse continue;
                        const bn_a = baseNetName(net_a);
                        const bn_b = baseNetName(net_b);
                        if (isGroundNet(bn_a) or isGroundNet(bn_b)) continue;
                        if (!std.mem.eql(u8, bn_a, bn_b)) {
                            std.debug.print("NET VALIDATE: spoke {s} pin {s} (net=\"{s}\") <-> {s} pin {s} (net=\"{s}\") — mismatch\n", .{ ref_des, entry.pin, bn_a, p.ref_des, p.pin, bn_b });
                        }
                    },
                    .net => {},
                }
            }
        }

        // Check 3: pin_net vs pin_canonical_nets consistency
        var pcn_it = self.pin_canonical_nets.iterator();
        while (pcn_it.next()) |kv| {
            const key = kv.key_ptr.*;
            const canonical = kv.value_ptr.*;
            const raw = self.pin_net.get(key) orelse continue;
            const canon_bn = baseNetName(canonical);
            const raw_bn = baseNetName(raw);
            if (isGroundNet(canon_bn) or isGroundNet(raw_bn)) continue;
            if (!std.mem.eql(u8, canon_bn, raw_bn)) {
                std.debug.print("NET VALIDATE: {s}: pin_net=\"{s}\" but canonical=\"{s}\"\n", .{ key, raw_bn, canon_bn });
            }
        }
    }

    fn adjAppend(self: *RenderCtx, ref_des: []const u8, entry: AdjEntry) !void {
        var list = self.adjacency.get(ref_des) orelse std.ArrayListUnmanaged(AdjEntry){};
        try list.append(self.allocator, entry);
        try self.adjacency.put(self.allocator, ref_des, list);
    }

    // ── Hub rendering ──────────────────────────────────────────────────

    /// Render a single part of a multi-part instance as its own hub box.
    fn renderHubPart(self: *RenderCtx, w: anytype, hub: FlatInst, part: env_mod.Part, y_start: f64) !f64 {
        // Collect unique pin IDs from part, sorted
        var all_pins: std.ArrayListUnmanaged([]const u8) = .empty;
        defer all_pins.deinit(self.allocator);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);
        for (part.pins) |pp| {
            if (!seen.contains(pp.pin)) {
                try seen.put(self.allocator, pp.pin, {});
                try all_pins.append(self.allocator, pp.pin);
            }
        }
        std.mem.sortUnstable([]const u8, all_pins.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return pinOrder(a, b);
            }
        }.lt);

        // Get adjacency for this hub
        const adj_entries = if (self.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

        // Build pin name map from part pins
        var pn_map = self.buildPinNameMap(&[_]env_mod.Part{part});
        defer pn_map.deinit(self.allocator);

        // Group ALL pins by net first, then split groups left/right
        const all_groups = try self.groupHubPins(all_pins.items, adj_entries, &pn_map);

        // Distribute groups to left/right for visual balance
        var left_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
        var right_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
        var left_pin_count: usize = 0;
        var right_pin_count: usize = 0;

        for (all_groups) |group| {
            // Count pins in this group
            var n: usize = 0;
            var iter = std.mem.splitScalar(u8, group.pin_numbers, ',');
            while (iter.next()) |_| n += 1;

            if (left_pin_count <= right_pin_count) {
                try left_groups_list.append(self.allocator, group);
                left_pin_count += n;
            } else {
                try right_groups_list.append(self.allocator, group);
                right_pin_count += n;
            }
        }

        const left_groups = left_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};
        const right_groups = right_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};
        const left_heights = try self.groupHeights(left_groups, hub.ref_des);
        const right_heights = try self.groupHeights(right_groups, hub.ref_des);

        var left_total: f64 = 0;
        for (left_heights) |h| left_total += h;
        var right_total: f64 = 0;
        for (right_heights) |h| right_total += h;
        const hub_height = @max(left_total, right_total) + 40.0;
        const box_y = y_start;

        // Hub box with part label
        const label = try std.fmt.allocPrint(self.allocator, "{s} \xe2\x80\x94 {s}", .{ shortRef(hub.ref_des), part.name });
        try w.print(
            \\<g class="hub-group" data-ref="{s}" transform="translate(0,0)">
            \\<g data-ref="{s}" data-part="{s}" class="component" style="cursor:pointer"><rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="12" font-weight="bold" fill="#4a9eff">{s}</text></g>
            \\
        , .{
            hub.ref_des, hub.ref_des,             part.name,
            hub_x,       box_y,                   hub_width,
            hub_height,  hub_x + hub_width / 2.0, box_y + 18.0,
            label,
        });

        // Left pin groups
        var py_left = box_y + 40.0;
        for (left_groups, 0..) |group, gi| {
            const h = left_heights[gi];
            const cy = py_left + h / 2.0;
            try self.renderPinLeft(w, hub.ref_des, group, cy, h);
            py_left += h;
        }

        // Right pin groups
        var py_right = box_y + 40.0;
        for (right_groups, 0..) |group, gi| {
            const h = right_heights[gi];
            const cy = py_right + h / 2.0;
            try self.renderPinRight(w, hub.ref_des, group, cy, h);
            py_right += h;
        }

        try w.writeAll("</g>\n");
        return hub_height;
    }

    fn renderHub(self: *RenderCtx, w: anytype, hub: FlatInst, y_start: f64) !f64 {
        // Find all pins for this hub from nets
        var pin_nets_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer pin_nets_map.deinit(self.allocator);

        for (self.nets.items) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    try pin_nets_map.put(self.allocator, pin.pin, baseNetName(net.name));
                }
            }
        }

        // Sort pins
        var all_pins = try self.allocator.alloc([]const u8, pin_nets_map.count());
        defer self.allocator.free(all_pins);
        for (pin_nets_map.keys(), 0..) |k, i| all_pins[i] = k;
        std.mem.sortUnstable([]const u8, all_pins, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return pinOrder(a, b);
            }
        }.lt);

        // Get adjacency for this hub
        const adj_entries = if (self.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

        // Build pin name map from instance parts
        var pn_map = self.buildPinNameMap(hub.parts);
        defer pn_map.deinit(self.allocator);

        // Group ALL pins by net, then split groups left/right
        const all_groups = try self.groupHubPins(all_pins, adj_entries, &pn_map);
        var left_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
        var right_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
        var left_pc: usize = 0;
        var right_pc: usize = 0;
        for (all_groups) |group| {
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, group.pin_numbers, ',');
            while (it.next()) |_| n += 1;
            if (left_pc <= right_pc) {
                try left_groups_list.append(self.allocator, group);
                left_pc += n;
            } else {
                try right_groups_list.append(self.allocator, group);
                right_pc += n;
            }
        }
        const left_groups = left_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};
        const right_groups = right_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};

        const left_heights = try self.groupHeights(left_groups, hub.ref_des);
        const right_heights = try self.groupHeights(right_groups, hub.ref_des);

        var left_total: f64 = 0;
        for (left_heights) |h| left_total += h;
        var right_total: f64 = 0;
        for (right_heights) |h| right_total += h;

        const hub_height = @max(left_total, right_total) + 40.0;
        const box_y = y_start;

        // Hub box (clickable group)
        try w.print(
            \\<g data-ref="{s}" class="component" style="cursor:pointer"><rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="12" font-weight="bold" fill="#4a9eff">{s} {s}</text></g>
            \\
        , .{
            hub.ref_des,
            hub_x,
            box_y,
            hub_width,
            hub_height,
            hub_x + hub_width / 2.0,
            box_y + 18.0,
            shortRef(hub.ref_des),
            displayValue(hub),
        });

        // Hub icon
        try self.drawHubIcon(w, hub, box_y, hub_height);

        // Left pin groups
        var py_left = box_y + 40.0;
        for (left_groups, 0..) |group, gi| {
            const height = left_heights[gi];
            const pin_cy = py_left + height / 2.0;
            try self.renderPinLeft(w, hub.ref_des, group, pin_cy, height);
            py_left += height;
        }

        // Right pin groups
        var py_right = box_y + 40.0;
        for (right_groups, 0..) |group, gi| {
            const height = right_heights[gi];
            const pin_cy = py_right + height / 2.0;
            try self.renderPinRight(w, hub.ref_des, group, pin_cy, height);
            py_right += height;
        }

        return hub_height;
    }

    // ── Pin Group Types ────────────────────────────────────────────────

    const PinGroup = struct {
        display_name: []const u8,
        pin_numbers: []const u8,
        conns: []const AdjEntry,
    };

    /// Build a pin_id → pin_name map from PartPin data.
    fn buildPinNameMap(self: *RenderCtx, parts: []const env_mod.Part) std.StringHashMapUnmanaged([]const u8) {
        var map: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (parts) |part| {
            for (part.pins) |pp| {
                if (pp.pin_name.len > 0) {
                    map.put(self.allocator, pp.pin, pp.pin_name) catch {};
                }
            }
        }
        return map;
    }

    /// Group hub pins: consecutive pins sharing the same net get merged.
    fn groupHubPins(self: *RenderCtx, pins: []const []const u8, adj_entries: []const AdjEntry, pin_names: *const std.StringHashMapUnmanaged([]const u8)) ![]const PinGroup {
        if (pins.len == 0) return &[_]PinGroup{};

        // Build pin→net mapping
        const PinInfo = struct { pin: []const u8, net: []const u8 };
        var pin_infos: std.ArrayListUnmanaged(PinInfo) = .empty;
        for (pins) |pin_id| {
            var pin_net: []const u8 = "";
            for (adj_entries) |ae| {
                if (std.mem.eql(u8, ae.pin, pin_id)) {
                    switch (ae.endpoint) {
                        .net => |n| {
                            pin_net = n;
                            break;
                        },
                        .pin => {},
                    }
                }
            }
            try pin_infos.append(self.allocator, .{ .pin = pin_id, .net = pin_net });
        }

        // Sort by net name (so same-net pins are adjacent), then by pin id
        std.mem.sortUnstable(PinInfo, pin_infos.items, {}, struct {
            fn lt(_: void, a: PinInfo, b: PinInfo) bool {
                const cmp = std.mem.order(u8, a.net, b.net);
                if (cmp == .eq) return pinOrder(a.pin, b.pin);
                return cmp == .lt;
            }
        }.lt);

        // Group consecutive pins with same net
        var groups: std.ArrayListUnmanaged(PinGroup) = .empty;
        var current_pins: std.ArrayListUnmanaged([]const u8) = .empty;
        var current_net: ?[]const u8 = null;
        var current_conns: std.ArrayListUnmanaged(AdjEntry) = .empty;

        for (pin_infos.items) |pi| {
            const pin_id = pi.pin;

            // Get all connections for this pin
            var pin_conns: std.ArrayListUnmanaged(AdjEntry) = .empty;
            for (adj_entries) |ae| {
                if (std.mem.eql(u8, ae.pin, pin_id)) {
                    try pin_conns.append(self.allocator, ae);
                }
            }

            // Merge if same net as current group
            const should_merge = blk: {
                if (current_pins.items.len == 0) break :blk false;
                if (pi.net.len > 0) {
                    if (current_net) |cn| {
                        if (std.mem.eql(u8, pi.net, cn)) break :blk true;
                    }
                }
                break :blk false;
            };

            if (should_merge) {
                try current_pins.append(self.allocator, pin_id);
                for (pin_conns.items) |c| {
                    try current_conns.append(self.allocator, c);
                }
            } else {
                // Flush previous group
                if (current_pins.items.len > 0) {
                    try groups.append(self.allocator, try self.finishGroup(&current_pins, &current_conns, pin_names));
                }
                current_pins = .empty;
                current_conns = .empty;
                try current_pins.append(self.allocator, pin_id);
                current_net = if (pi.net.len > 0) pi.net else null;
                for (pin_conns.items) |c| {
                    try current_conns.append(self.allocator, c);
                }
            }
        }

        // Flush last group
        if (current_pins.items.len > 0) {
            try groups.append(self.allocator, try self.finishGroup(&current_pins, &current_conns, pin_names));
        }

        return groups.toOwnedSlice(self.allocator);
    }

    fn finishGroup(self: *RenderCtx, pins: *std.ArrayListUnmanaged([]const u8), conns: *std.ArrayListUnmanaged(AdjEntry), pin_names: *const std.StringHashMapUnmanaged([]const u8)) !PinGroup {
        // Build display name: prefer pin function name from pinout, fall back to net name
        var display_name: []const u8 = "~";

        // First try pin function name from pinout (use the first pin in the group)
        if (pins.items.len > 0) {
            if (pin_names.get(pins.items[0])) |func_name| {
                display_name = func_name;
            }
        }

        // Fall back to net name if no pinout name
        if (std.mem.eql(u8, display_name, "~")) {
            for (conns.items) |ae| {
                switch (ae.endpoint) {
                    .net => |n| {
                        if (!isGroundNet(n)) {
                            display_name = n;
                            break;
                        } else {
                            display_name = n;
                        }
                    },
                    .pin => {},
                }
            }
        }

        // If still nothing, use pin id
        if (std.mem.eql(u8, display_name, "~")) {
            if (pins.items.len == 1) {
                display_name = pins.items[0];
            }
        }

        // Build pin numbers string
        var num_buf: std.ArrayListUnmanaged(u8) = .empty;
        for (pins.items, 0..) |pn, i| {
            if (i > 0) try num_buf.append(self.allocator, ',');
            try num_buf.appendSlice(self.allocator, pn);
        }

        // Deduplicate connections
        const deduped = try self.dedupConns(conns.items);

        return PinGroup{
            .display_name = display_name,
            .pin_numbers = try num_buf.toOwnedSlice(self.allocator),
            .conns = deduped,
        };
    }

    /// Deduplicate connections: unique NetEndpoints by name, unique PinEndpoints by ref+pin.
    fn dedupConns(self: *RenderCtx, conns: []const AdjEntry) ![]const AdjEntry {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var result: std.ArrayListUnmanaged(AdjEntry) = .empty;
        for (conns) |ae| {
            const key = switch (ae.endpoint) {
                .net => |n| try std.fmt.allocPrint(self.allocator, "net:{s}", .{n}),
                .pin => |p| try std.fmt.allocPrint(self.allocator, "pin:{s}.{s}", .{ p.ref_des, p.pin }),
            };
            if (!seen.contains(key)) {
                try seen.put(self.allocator, key, {});
                try result.append(self.allocator, ae);
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// Calculate per-group heights based on connection count and branch estimates.
    fn groupHeights(self: *RenderCtx, groups: []const PinGroup, hub_ref: []const u8) ![]f64 {
        var heights = try self.allocator.alloc(f64, groups.len);
        for (groups, 0..) |group, i| {
            var total_slots: i32 = 0;
            for (group.conns) |conn| {
                switch (conn.endpoint) {
                    .pin => |p| {
                        if (self.spoke_set.contains(p.ref_des)) {
                            total_slots += @intCast(self.estimateBranchCount(p.ref_des, hub_ref));
                        } else {
                            total_slots += 1;
                        }
                    },
                    .net => {
                        // Net endpoints are just labels — only count if significant
                        // (they take a visual slot for the wire + label)
                        const bn = baseNetName(conn.endpoint.net);
                        if (self.significant_nets.contains(bn)) {
                            total_slots += 1;
                        }
                    },
                }
            }
            const base: f64 = 40.0;
            heights[i] = base + @as(f64, @floatFromInt(@max(total_slots, 1) - 1)) * per_conn_spacing;
        }
        return heights;
    }

    /// Estimate how many vertical slots a spoke connection needs.
    fn estimateBranchCount(self: *RenderCtx, spoke_rd: []const u8, hub_ref: []const u8) u32 {
        // Find which pin of the spoke connects to the hub
        const adj_list = self.adjacency.get(spoke_rd) orelse return 1;
        var hub_pin: ?[]const u8 = null;
        for (adj_list.items) |ae| {
            switch (ae.endpoint) {
                .pin => |p| {
                    if (std.mem.eql(u8, p.ref_des, hub_ref)) {
                        hub_pin = ae.pin;
                        break;
                    }
                },
                .net => {},
            }
        }

        // Find the OTHER pin's net (the one that doesn't connect back to hub)
        for (adj_list.items) |ae| {
            if (hub_pin != null and std.mem.eql(u8, ae.pin, hub_pin.?)) continue; // skip the hub-side pin
            switch (ae.endpoint) {
                .net => |net| {
                    if (isGroundNet(baseNetName(net))) return 1;
                    // Check if this net has a hub pin — if so, it's a terminal net,
                    // not a branch junction (the hub renders its own spokes)
                    const net_pins = self.net_index.get(baseNetName(net)) orelse continue;
                    var has_hub = false;
                    for (net_pins.items) |np| {
                        if (!self.spoke_set.contains(np.ref_des) and !std.mem.eql(u8, np.ref_des, spoke_rd)) {
                            has_hub = true;
                            break;
                        }
                    }
                    if (has_hub) return 1; // terminal net — no branches

                    // Count other spokes on this net (no hub present = junction)
                    var other_spokes: u32 = 0;
                    for (net_pins.items) |np| {
                        if (std.mem.eql(u8, np.ref_des, spoke_rd)) continue;
                        if (self.spoke_set.contains(np.ref_des)) {
                            other_spokes += 1;
                        }
                    }
                    if (other_spokes <= 1) return 1;
                    return other_spokes;
                },
                .pin => {},
            }
        }
        return 1;
    }

    // ── Pin rendering ──────────────────────────────────────────────────

    fn renderPinLeft(self: *RenderCtx, w: anytype, hub_ref: []const u8, group: PinGroup, py: f64, height: f64) !void {
        _ = height;
        const px = hub_x;
        const stub_x = px - pin_stub;

        // Pin stub line
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
            \\<text x="{d:.1}" y="{d:.1}" font-size="12" fill="#aaa">{s}</text>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="10" fill="#666">{s}</text>
            \\
        , .{
            stub_x,   py,                px,                 py,
            px + 8.0, py + 4.0,          group.display_name, stub_x + 38.0,
            py - 1.0, group.pin_numbers,
        });

        // Debug pin dot
        try writeDebugPin(w, stub_x, py);

        // Render connections
        try self.renderGroupedConnections(w, hub_ref, group, stub_x, py, .left);
    }

    fn renderPinRight(self: *RenderCtx, w: anytype, hub_ref: []const u8, group: PinGroup, py: f64, height: f64) !void {
        _ = height;
        const px = hub_x + hub_width;
        const stub_x = px + pin_stub;

        // Pin stub line
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="12" fill="#aaa">{s}</text>
            \\<text x="{d:.1}" y="{d:.1}" font-size="10" fill="#666">{s}</text>
            \\
        , .{
            px,       py,                stub_x,             py,
            px - 8.0, py + 4.0,          group.display_name, stub_x - 36.0,
            py - 1.0, group.pin_numbers,
        });

        // Debug pin dot
        try writeDebugPin(w, stub_x, py);

        // Render connections
        try self.renderGroupedConnections(w, hub_ref, group, stub_x, py, .right);
    }

    // ── Grouped connection rendering ───────────────────────────────────

    fn renderGroupedConnections(self: *RenderCtx, w: anytype, hub_ref: []const u8, group: PinGroup, stub_x: f64, py: f64, side: Side) !void {
        if (group.conns.len == 0) {
            // NC symbol
            const nc_x = switch (side) {
                .left => stub_x - 10.0,
                .right => stub_x + 10.0,
            };
            try drawNcSymbol(w, nc_x, py);
            return;
        }

        // Get the pin's canonical net name early (needed for filtering)
        var first_pin_id: []const u8 = "";
        for (group.conns) |c| {
            first_pin_id = c.pin;
            break;
        }
        const canon_key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ hub_ref, first_pin_id });
        const pin_net_name = self.pin_canonical_nets.get(canon_key) orelse "";

        // Classify each connection's terminal
        const Classified = struct { conn: AdjEntry, terminal: []const u8 };
        var classified: std.ArrayListUnmanaged(Classified) = .empty;

        for (group.conns) |conn| {
            switch (conn.endpoint) {
                .net => |net| {
                    const term = baseNetName(net);
                    if (!self.significant_nets.contains(term)) continue;
                    // Skip the pin's own net unless:
                    // 1. It's a port net (always show), OR
                    // 2. A spoke on this net was rendered on a different pin (bridge), OR
                    // 3. Another hub is on this net (hub-to-hub connection needs label)
                    if (std.mem.eql(u8, term, baseNetName(pin_net_name))) {
                        var should_show = false;
                        // Port nets always show
                        if (self.port_nets.contains(term)) should_show = true;
                        if (!should_show) {
                            if (self.net_index.get(term)) |nps| {
                                for (nps.items) |np| {
                                    if (self.rendered_spokes.contains(np.ref_des)) {
                                        should_show = true;
                                        break;
                                    }
                                    if (!self.spoke_set.contains(np.ref_des) and !std.mem.eql(u8, np.ref_des, hub_ref)) {
                                        should_show = true;
                                        break;
                                    }
                                }
                            }
                        }
                        if (!should_show) continue;
                    }
                    try classified.append(self.allocator, .{ .conn = conn, .terminal = term });
                },
                .pin => |p| {
                    // Skip already-rendered spokes entirely
                    if (self.rendered_spokes.contains(p.ref_des)) continue;
                    const term = try self.getConnTerminal(conn.endpoint, hub_ref, conn.pin);
                    try classified.append(self.allocator, .{ .conn = conn, .terminal = term });
                },
            }
        }

        if (classified.items.len == 0) return;

        // Sort by terminal
        std.mem.sortUnstable(Classified, classified.items, {}, struct {
            fn lt(_: void, a: Classified, b: Classified) bool {
                return std.mem.lessThan(u8, a.terminal, b.terminal);
            }
        }.lt);

        // Assign y-positions with slot counting
        var slot_counts = try self.allocator.alloc(u32, classified.items.len);
        var total_slots: u32 = 0;
        for (classified.items, 0..) |entry, i| {
            const slots: u32 = switch (entry.conn.endpoint) {
                .pin => |p| blk: {
                    if (self.spoke_set.contains(p.ref_des)) {
                        break :blk self.estimateBranchCount(p.ref_des, hub_ref);
                    }
                    break :blk 1;
                },
                .net => 1,
            };
            slot_counts[i] = slots;
            total_slots += slots;
        }
        const total_height = @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;

        // pin_net_name already computed above

        // Render each body and collect results
        var results: std.ArrayListUnmanaged(BranchBody) = .empty;

        // If multiple connections, draw a bus junction
        const multi = classified.items.len > 1;
        const bus_offset: f64 = 10.0;
        const bus_x: f64 = switch (side) {
            .left => stub_x - bus_offset,
            .right => stub_x + bus_offset,
        };

        var consumed_slots: u32 = 0;
        var min_cy: f64 = py;
        var max_cy: f64 = py;

        for (classified.items, 0..) |entry, i| {
            const slots = slot_counts[i];
            const slot_center = @as(f64, @floatFromInt(consumed_slots)) + @as(f64, @floatFromInt(slots -| 1)) / 2.0;
            const cy = py + slot_center * per_conn_spacing - total_height / 2.0;
            consumed_slots += slots;
            if (cy < min_cy) min_cy = cy;
            if (cy > max_cy) max_cy = cy;

            // Internal net: pin-to-pin uses canonical, direct net uses terminal
            const internal_net: []const u8 = switch (entry.conn.endpoint) {
                .net => entry.terminal,
                .pin => pin_net_name,
            };

            // For multi-connection pins, route from bus_x instead of stub_x
            const conn_stub_x = if (multi) bus_x else stub_x;
            const conn_stub_y = if (multi) cy else py;

            const end_x = try self.renderConnBody(w, entry.conn.endpoint, hub_ref, entry.conn.pin, conn_stub_x, conn_stub_y, cy, side, internal_net);

            try results.append(self.allocator, .{ .end_x = end_x, .cy = cy, .terminal = entry.terminal });
        }

        // Draw bus junction if multiple connections
        if (multi) {
            // Horizontal from pin stub to bus point
            try drawNetWire(w, stub_x, py, bus_x, py, pin_net_name);
            // Vertical bus line spanning all connections
            if (min_cy != max_cy) {
                try w.print(
                    \\<g class="net" data-net="{s}" style="cursor:pointer">
                    \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="transparent" stroke-width="12" class="hit-area"/>
                    \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
                    \\</g>
                    \\
                , .{ pin_net_name, bus_x, min_cy, bus_x, max_cy, bus_x, min_cy, bus_x, max_cy });
            }
        }

        // Group by terminal and render terminals
        // Compute aligned term_x
        var default_term_x: f64 = switch (side) {
            .left => stub_x - spoke_len - 20.0,
            .right => stub_x + spoke_len + 20.0,
        };
        for (results.items) |r| {
            switch (side) {
                .left => {
                    default_term_x = @min(default_term_x, r.end_x - 20.0);
                },
                .right => {
                    default_term_x = @max(default_term_x, r.end_x + 20.0);
                },
            }
        }
        const term_x = default_term_x;

        // Group consecutive results by terminal
        try self.renderTerminalGroups(w, results.items, term_x, side);
    }

    /// Render terminal labels/symbols, grouping by terminal name.
    fn renderTerminalGroups(self: *RenderCtx, w: anytype, results: []const BranchBody, term_x: f64, side: Side) !void {
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
            const group = results[i..j];

            if (!self.significant_nets.contains(term)) {
                i = j;
                continue;
            }

            if (group.len == 1) {
                // Single connection — extend wire to terminal
                const r = group[0];
                try drawNetWire(w, r.end_x, r.cy, term_x, r.cy, term);
                try self.drawTerminal(w, term_x, r.cy, term, anchor);
            } else {
                // Multiple connections sharing a terminal — bus bar
                const nearest_x = blk: {
                    var nx: f64 = switch (side) {
                        .left => 99999.0,
                        .right => -99999.0,
                    };
                    for (group) |r| {
                        switch (side) {
                            .left => {
                                nx = @min(nx, r.end_x);
                            },
                            .right => {
                                nx = @max(nx, r.end_x);
                            },
                        }
                    }
                    break :blk nx;
                };
                const bus_x = switch (side) {
                    .left => nearest_x - 20.0,
                    .right => nearest_x + 20.0,
                };

                const first_cy = group[0].cy;
                const last_cy = group[group.len - 1].cy;

                // Wire from each body end to bus
                for (group) |r| {
                    try drawNetWire(w, r.end_x, r.cy, bus_x, r.cy, term);
                }

                // Vertical bus
                try drawNetWire(w, bus_x, first_cy, bus_x, last_cy, term);

                // Extension wire to terminal
                try drawNetWire(w, bus_x, last_cy, term_x, last_cy, term);
                try self.drawTerminal(w, term_x, last_cy, term, anchor);
            }

            i = j;
        }
    }

    /// Get the terminal net name for a connection endpoint.
    fn getConnTerminal(self: *RenderCtx, endpoint: Endpoint, hub_ref: []const u8, from_pin: []const u8) ![]const u8 {
        switch (endpoint) {
            .net => |net| return net,
            .pin => |p| {
                if (self.spoke_set.contains(p.ref_des)) {
                    // Follow spoke chain to find terminal
                    var visited: std.StringHashMapUnmanaged(void) = .empty;
                    try visited.put(self.allocator, p.ref_des, {});
                    const result = try self.findSpokeChain(p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);
                    return result.terminal;
                } else {
                    // Hub pin — find its net name
                    if (self.adjacency.get(p.ref_des)) |adj_list| {
                        for (adj_list.items) |ae| {
                            if (std.mem.eql(u8, ae.pin, p.pin)) {
                                switch (ae.endpoint) {
                                    .net => |n| return n,
                                    .pin => {},
                                }
                            }
                        }
                    }
                    return try std.fmt.allocPrint(self.allocator, "{s}_pin{s}", .{ p.ref_des, p.pin });
                }
            },
        }
    }

    /// Find spoke chain result.
    const ChainResult = struct {
        chain: []const FlatInst,
        terminal: []const u8,
        branches: []const Branch,
    };

    /// Follow a chain of passives from a spoke, detecting branches at junctions.
    fn findSpokeChain(self: *RenderCtx, ref_des: []const u8, came_from: Endpoint, visited: *std.StringHashMapUnmanaged(void)) error{OutOfMemory}!ChainResult {
        const adj_list = self.adjacency.get(ref_des) orelse return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };

        // Find which pins came_from connects to
        var from_pins: std.ArrayListUnmanaged([]const u8) = .empty;
        for (adj_list.items) |ae| {
            if (endpointEql(ae.endpoint, came_from)) {
                try from_pins.append(self.allocator, ae.pin);
            }
        }

        // Get connections on the other side
        var other_conns: std.ArrayListUnmanaged(AdjEntry) = .empty;
        for (adj_list.items) |ae| {
            var is_from_pin = false;
            for (from_pins.items) |fp| {
                if (std.mem.eql(u8, ae.pin, fp)) {
                    is_from_pin = true;
                    break;
                }
            }
            if (!is_from_pin) {
                try other_conns.append(self.allocator, ae);
            }
        }

        return self.tryChainConns(other_conns.items, ref_des, visited);
    }

    fn tryChainConns(self: *RenderCtx, conns: []const AdjEntry, current_ref: []const u8, visited: *std.StringHashMapUnmanaged(void)) error{OutOfMemory}!ChainResult {
        if (conns.len == 0) return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };

        const ae = conns[0];
        switch (ae.endpoint) {
            .net => |net| {
                if (isGroundNet(net)) return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

                const net_pins = self.net_index.get(net) orelse return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

                // Check if any hub is on this net
                var has_hub = false;
                for (net_pins.items) |np| {
                    if (!std.mem.eql(u8, np.ref_des, current_ref) and !self.spoke_set.contains(np.ref_des)) {
                        has_hub = true;
                        break;
                    }
                }
                if (has_hub) return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

                // Find other spokes on this net
                var other_spokes: std.ArrayListUnmanaged(PinRef) = .empty;
                for (net_pins.items) |np| {
                    if (!std.mem.eql(u8, np.ref_des, current_ref) and
                        self.spoke_set.contains(np.ref_des) and
                        !visited.contains(np.ref_des))
                    {
                        try other_spokes.append(self.allocator, np);
                    }
                }

                if (other_spokes.items.len == 0) {
                    return .{ .chain = &.{}, .terminal = net, .branches = &.{} };
                } else if (other_spokes.items.len == 1) {
                    // Continue chain
                    const next_ref = other_spokes.items[0].ref_des;
                    const next_inst = self.inst_map.get(next_ref) orelse return .{ .chain = &.{}, .terminal = net, .branches = &.{} };
                    try visited.put(self.allocator, next_ref, {});
                    const rest = try self.findSpokeChain(next_ref, .{ .net = net }, visited);
                    var chain: std.ArrayListUnmanaged(FlatInst) = .empty;
                    try chain.append(self.allocator, next_inst);
                    for (rest.chain) |c| try chain.append(self.allocator, c);
                    return .{
                        .chain = try chain.toOwnedSlice(self.allocator),
                        .terminal = rest.terminal,
                        .branches = rest.branches,
                    };
                } else {
                    // Junction — all become branches
                    var branches: std.ArrayListUnmanaged(Branch) = .empty;
                    for (other_spokes.items) |sp| {
                        if (visited.contains(sp.ref_des)) continue;
                        const sib_inst = self.inst_map.get(sp.ref_des) orelse continue;
                        try visited.put(self.allocator, sp.ref_des, {});
                        const sub = try self.findSpokeChain(sp.ref_des, .{ .net = net }, visited);
                        var chain: std.ArrayListUnmanaged(FlatInst) = .empty;
                        try chain.append(self.allocator, sib_inst);
                        for (sub.chain) |c| try chain.append(self.allocator, c);
                        try branches.append(self.allocator, .{
                            .chain = try chain.toOwnedSlice(self.allocator),
                            .terminal = sub.terminal,
                        });
                    }
                    return .{
                        .chain = &.{},
                        .terminal = net,
                        .branches = try branches.toOwnedSlice(self.allocator),
                    };
                }
            },
            .pin => |p| {
                if (self.spoke_set.contains(p.ref_des)) {
                    if (visited.contains(p.ref_des)) {
                        // Already visited, try next conn
                        if (conns.len > 1) {
                            return self.tryChainConns(conns[1..], current_ref, visited);
                        }
                        return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };
                    }
                    const next_inst = self.inst_map.get(p.ref_des) orelse return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };
                    try visited.put(self.allocator, p.ref_des, {});
                    const rest = try self.findSpokeChain(p.ref_des, .{ .pin = .{ .ref_des = current_ref, .pin = ae.pin } }, visited);
                    var chain: std.ArrayListUnmanaged(FlatInst) = .empty;
                    try chain.append(self.allocator, next_inst);
                    for (rest.chain) |c| try chain.append(self.allocator, c);
                    return .{
                        .chain = try chain.toOwnedSlice(self.allocator),
                        .terminal = rest.terminal,
                        .branches = rest.branches,
                    };
                } else {
                    // Hub pin — find its net name
                    if (self.adjacency.get(p.ref_des)) |adj_list| {
                        for (adj_list.items) |adj_ae| {
                            if (std.mem.eql(u8, adj_ae.pin, p.pin)) {
                                switch (adj_ae.endpoint) {
                                    .net => |n| return .{ .chain = &.{}, .terminal = n, .branches = &.{} },
                                    .pin => {},
                                }
                            }
                        }
                    }
                    return .{ .chain = &.{}, .terminal = try std.fmt.allocPrint(self.allocator, "{s}_pin{s}", .{ p.ref_des, p.pin }), .branches = &.{} };
                }
            },
        }
    }

    /// Render the body of a connection (wire + passive chain or branch tree).
    /// Returns end_x position.
    fn renderConnBody(self: *RenderCtx, w: anytype, endpoint: Endpoint, hub_ref: []const u8, from_pin: []const u8, stub_x: f64, stub_y: f64, cy: f64, side: Side, net_name: []const u8) !f64 {
        switch (endpoint) {
            .net => {
                const end_x: f64 = switch (side) {
                    .left => stub_x - 20.0,
                    .right => stub_x + 20.0,
                };
                try drawNetWire(w, stub_x, stub_y, end_x, cy, net_name);
                return end_x;
            },
            .pin => |p| {
                if (self.spoke_set.contains(p.ref_des)) {
                    // Skip if already rendered on another pin — don't draw anything,
                    // the pin's own NetEndpoint connection handles the net label
                    if (self.rendered_spokes.contains(p.ref_des)) {
                        return stub_x;
                    }

                    const inst = self.inst_map.get(p.ref_des) orelse return stub_x;

                    // Mark this spoke (and chain members) as rendered
                    try self.rendered_spokes.put(self.allocator, p.ref_des, {});

                    var visited: std.StringHashMapUnmanaged(void) = .empty;
                    try visited.put(self.allocator, p.ref_des, {});
                    const chain_result = try self.findSpokeChain(p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);

                    // Mark all chain members as rendered too
                    for (chain_result.chain) |c| {
                        try self.rendered_spokes.put(self.allocator, c.ref_des, {});
                    }

                    // Build all_spokes = [inst] ++ chain
                    var all_spokes: std.ArrayListUnmanaged(FlatInst) = .empty;
                    try all_spokes.append(self.allocator, inst);
                    for (chain_result.chain) |c| try all_spokes.append(self.allocator, c);

                    switch (side) {
                        .left => {
                            try drawNetWire(w, stub_x, stub_y, stub_x - 20.0, cy, net_name);
                            const chain_end_x = try self.drawPassiveChainLeft(w, stub_x - 20.0, cy, all_spokes.items);
                            if (chain_result.branches.len > 0) {
                                try self.drawBranchTreeLeft(w, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                            }
                            return chain_end_x;
                        },
                        .right => {
                            try drawNetWire(w, stub_x, stub_y, stub_x + 20.0, cy, net_name);
                            const chain_end_x = try self.drawPassiveChainRight(w, stub_x + 20.0, cy, all_spokes.items);
                            if (chain_result.branches.len > 0) {
                                try self.drawBranchTreeRight(w, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                            }
                            return chain_end_x;
                        },
                    }
                } else {
                    // Hub-to-hub connection
                    const end_x: f64 = switch (side) {
                        .left => stub_x - spoke_len - 20.0,
                        .right => stub_x + spoke_len + 20.0,
                    };
                    try drawNetWire(w, stub_x, stub_y, end_x, cy, net_name);
                    return end_x;
                }
            },
        }
    }

    // ── Passive chain drawing ──────────────────────────────────────────

    fn drawPassiveChainLeft(self: *RenderCtx, w: anytype, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
        if (spokes.len == 0) return start_x;
        var x = start_x;
        for (spokes, 0..) |inst, i| {
            if (i > 0) {
                // Inter-passive wire
                try drawWire(w, x, cy, x - 20.0, cy);
                x -= 20.0;
            }
            try self.drawPassiveLeft(w, inst, x, cy);
            x -= passive_bw;
        }
        return x;
    }

    fn drawPassiveChainRight(self: *RenderCtx, w: anytype, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
        if (spokes.len == 0) return start_x;
        var x = start_x;
        for (spokes, 0..) |inst, i| {
            if (i > 0) {
                try drawWire(w, x, cy, x + 20.0, cy);
                x += 20.0;
            }
            try self.drawPassiveRight(w, inst, x, cy);
            x += passive_bw;
        }
        return x;
    }

    fn drawPassiveLeft(self: *RenderCtx, w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
        _ = self;
        const bx = x - passive_bw;
        const by = cy - passive_bh / 2.0;
        const cx = bx + passive_bw / 2.0;
        const pad: f64 = 6.0;

        // Clickable group
        try w.print(
            \\<g data-ref="{s}" class="component" style="cursor:pointer">
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
            \\
        , .{
            shortRef(inst.ref_des),
            bx - pad,
            by - 14.0,
            passive_bw + pad * 2.0,
            passive_bh + 18.0,
        });

        // Symbol shape
        try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

        // Label
        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">{s} {s}</text>
            \\</g>
            \\
        , .{ cx, by - 4.0, shortRef(inst.ref_des), formatShort(inst) });

        // Debug pin dots
        try writeDebugPin(w, bx, cy);
        try writeDebugPin(w, bx + passive_bw, cy);
    }

    fn drawPassiveRight(self: *RenderCtx, w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
        _ = self;
        const bx = x;
        const by = cy - passive_bh / 2.0;
        const cx = bx + passive_bw / 2.0;
        const pad: f64 = 6.0;

        try w.print(
            \\<g data-ref="{s}" class="component" style="cursor:pointer">
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
            \\
        , .{
            shortRef(inst.ref_des),
            bx - pad,
            by - 14.0,
            passive_bw + pad * 2.0,
            passive_bh + 18.0,
        });

        try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">{s} {s}</text>
            \\</g>
            \\
        , .{ cx, by - 4.0, shortRef(inst.ref_des), formatShort(inst) });

        try writeDebugPin(w, bx, cy);
        try writeDebugPin(w, bx + passive_bw, cy);
    }

    // ── Branch tree drawing ────────────────────────────────────────────

    fn drawBranchTreeLeft(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) !void {
        const n = branches.len;
        const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
        const start_y = center_y - total_height / 2.0;

        const bus_x = junction_x - bus_gap;
        try drawNetWire(w, junction_x, center_y, bus_x, center_y, junction_net);
        if (n > 1) {
            const end_y = start_y + total_height;
            try drawNetWire(w, bus_x, start_y, bus_x, end_y, junction_net);
        }

        // Render branch bodies and collect results
        var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

        for (branches, 0..) |branch, idx| {
            const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
            try drawNetWire(w, bus_x, by, bus_x - 10.0, by, junction_net);
            const chain_end_x = try self.drawPassiveChainLeft(w, bus_x - 10.0, by, branch.chain);
            try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
        }

        // Render terminals
        try self.renderBranchTerminalsLeft(w, bodies.items);
    }

    fn drawBranchTreeRight(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) !void {
        const n = branches.len;
        const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
        const start_y = center_y - total_height / 2.0;

        const bus_x = junction_x + bus_gap;
        try drawNetWire(w, junction_x, center_y, bus_x, center_y, junction_net);
        if (n > 1) {
            const end_y = start_y + total_height;
            try drawNetWire(w, bus_x, start_y, bus_x, end_y, junction_net);
        }

        var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

        for (branches, 0..) |branch, idx| {
            const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
            try drawNetWire(w, bus_x, by, bus_x + 10.0, by, junction_net);
            const chain_end_x = try self.drawPassiveChainRight(w, bus_x + 10.0, by, branch.chain);
            try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
        }

        try self.renderBranchTerminalsRight(w, bodies.items);
    }

    fn renderBranchTerminalsLeft(self: *RenderCtx, w: anytype, bodies: []const BranchBody) !void {
        if (bodies.len == 0) return;
        // Find furthest-left for alignment
        var term_x: f64 = 0;
        for (bodies) |b| {
            const tx = b.end_x - 20.0;
            if (term_x == 0 or tx < term_x) term_x = tx;
        }

        // Group by terminal
        var i: usize = 0;
        while (i < bodies.len) {
            const term = bodies[i].terminal;
            var j = i + 1;
            while (j < bodies.len) : (j += 1) {
                if (!std.mem.eql(u8, bodies[j].terminal, term)) break;
            }
            const group = bodies[i..j];

            if (group.len == 1) {
                try drawNetWire(w, group[0].end_x, group[0].cy, term_x, group[0].cy, term);
                try self.drawTerminal(w, term_x, group[0].cy, term, "end");
            } else {
                var bus_x: f64 = 99999.0;
                for (group) |b| bus_x = @min(bus_x, b.end_x - 15.0);
                for (group) |b| try drawNetWire(w, b.end_x, b.cy, bus_x, b.cy, term);
                try drawNetWire(w, bus_x, group[0].cy, bus_x, group[group.len - 1].cy, term);
                try drawNetWire(w, bus_x, group[group.len - 1].cy, term_x, group[group.len - 1].cy, term);
                try self.drawTerminal(w, term_x, group[group.len - 1].cy, term, "end");
            }

            i = j;
        }
    }

    fn renderBranchTerminalsRight(self: *RenderCtx, w: anytype, bodies: []const BranchBody) !void {
        if (bodies.len == 0) return;
        var term_x: f64 = 0;
        for (bodies) |b| {
            const tx = b.end_x + 20.0;
            if (term_x == 0 or tx > term_x) term_x = tx;
        }

        var i: usize = 0;
        while (i < bodies.len) {
            const term = bodies[i].terminal;
            var j = i + 1;
            while (j < bodies.len) : (j += 1) {
                if (!std.mem.eql(u8, bodies[j].terminal, term)) break;
            }
            const group = bodies[i..j];

            if (group.len == 1) {
                try drawNetWire(w, group[0].end_x, group[0].cy, term_x, group[0].cy, term);
                try self.drawTerminal(w, term_x, group[0].cy, term, "start");
            } else {
                var bus_x: f64 = -99999.0;
                for (group) |b| bus_x = @max(bus_x, b.end_x + 15.0);
                for (group) |b| try drawNetWire(w, b.end_x, b.cy, bus_x, b.cy, term);
                try drawNetWire(w, bus_x, group[0].cy, bus_x, group[group.len - 1].cy, term);
                try drawNetWire(w, bus_x, group[group.len - 1].cy, term_x, group[group.len - 1].cy, term);
                try self.drawTerminal(w, term_x, group[group.len - 1].cy, term, "start");
            }

            i = j;
        }
    }

    /// Draw a terminal label or symbol (GND/NC/net label).
    fn drawTerminal(self: *RenderCtx, w: anytype, end_x: f64, cy: f64, term: []const u8, anchor: []const u8) !void {
        if (isGroundNet(term)) {
            try w.print(
                \\<g class="net" data-net="{s}" style="cursor:pointer">
                \\
            , .{term});
            try drawGndSymbol(w, end_x, cy);
            try w.writeAll("</g>\n");
        } else {
            const color: []const u8 = if (self.port_nets.contains(term)) "#4a9eff" else "#e8c547";
            const label_x: f64 = if (std.mem.eql(u8, anchor, "end")) end_x - net_label_gap else end_x + net_label_gap;
            try w.print(
                \\<g class="net" data-net="{s}" style="cursor:pointer">
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="{s}" font-size="11" font-weight="bold" fill="{s}">{s}</text>
                \\</g>
                \\
            , .{ term, label_x, cy + 4.0, anchor, color, term });
        }
        try writeDebugPin(w, end_x, cy);
    }

    // ── Hub icon ───────────────────────────────────────────────────────

    fn drawHubIcon(self: *RenderCtx, w: anytype, hub: FlatInst, box_y: f64, hub_height: f64) !void {
        _ = self;
        const icon = classifyComponent(hub);
        if (icon) |icon_name| {
            const icon_cx = hub_x + hub_width / 2.0;
            const icon_cy = box_y + hub_height / 2.0 + 8.0;
            try drawBlockIcon(w, icon_name, icon_cx, icon_cy, "#4a9eff");
        }
    }

    /// Infer icon from a block's instances (find the first hub and classify it)
    fn inferBlockIcon(self: *RenderCtx, block: *const env_mod.DesignBlock) ?[]const u8 {
        // Check direct instances
        for (block.instances) |inst| {
            const fi = self.inst_map.get(inst.ref_des) orelse continue;
            if (classifyComponent(fi)) |icon| return icon;
        }
        // Check sub-block instances
        for (block.sub_blocks) |sb| {
            for (sb.block.instances) |inst| {
                const key = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sb.name, inst.ref_des }) catch continue;
                const fi = self.inst_map.get(key) orelse continue;
                if (classifyComponent(fi)) |icon| return icon;
            }
        }
        return null;
    }

    // ── Port block rendering ───────────────────────────────────────────

    fn renderPortBlock(self: *RenderCtx, w: anytype, name: []const u8, ports: []const Port, y_start: f64, icon: ?[]const u8) !f64 {
        _ = self;
        // Split ports: in/bidi left, out right
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
        const box_y = y_start;

        // Block box (dashed border)
        try w.print(
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" fill="#1a2e1a" stroke="#4a9" stroke-width="2" rx="6" stroke-dasharray="8,4"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="12" font-weight="bold" fill="#4a9">{s}</text>
            \\
        , .{
            hub_x,
            box_y,
            hub_width,
            block_height,
            hub_x + hub_width / 2.0,
            box_y + 18.0,
            name,
        });

        // Draw icon centered in block
        if (icon) |icon_name| {
            const icon_cx = hub_x + hub_width / 2.0;
            const icon_cy = box_y + block_height / 2.0 + 8.0;
            try drawBlockIcon(w, icon_name, icon_cx, icon_cy, "#4a9");
        }

        // Render ports
        var left_idx: usize = 0;
        var right_idx: usize = 0;
        for (ports) |port| {
            const is_output = std.mem.eql(u8, port.direction, "out");
            if (is_output) {
                const py = box_y + box_pad + @as(f64, @floatFromInt(right_idx)) * port_spacing;
                const edge_x = hub_x + hub_width;
                const stub_x = edge_x + pin_stub;

                // Wire from edge to stub
                try drawNetWire(w, edge_x, py, stub_x, py, port.net);

                // Port name inside box
                const dir_text: []const u8 = "\xe2\x86\x90 OUT";
                try w.print(
                    \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="12" fill="#4a9">{s} {s}</text>
                    \\
                , .{ edge_x - 8.0, py + 4.0, port.name, dir_text });

                // Net label
                try w.print(
                    \\<g class="net" data-net="{s}" style="cursor:pointer">
                    \\<text x="{d:.1}" y="{d:.1}" text-anchor="start" font-size="11" font-weight="bold" fill="#4a9eff">{s}</text>
                    \\</g>
                    \\
                , .{ port.net, stub_x + net_label_gap, py + 4.0, port.net });

                if (port.rated_min != null and port.rated_max != null) {
                    try w.print(
                        \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="9" fill="#888">{d:.1}V - {d:.1}V</text>
                        \\
                    , .{ edge_x - 8.0, py + 16.0, port.rated_min.?, port.rated_max.? });
                }

                right_idx += 1;
            } else {
                const py = box_y + box_pad + @as(f64, @floatFromInt(left_idx)) * port_spacing;
                const edge_x = hub_x;
                const stub_x = edge_x - pin_stub;

                try drawNetWire(w, stub_x, py, edge_x, py, port.net);

                const dir_text: []const u8 = if (std.mem.eql(u8, port.direction, "in"))
                    "\xe2\x86\x92 "
                else
                    "\xe2\x86\x94 ";

                try w.print(
                    \\<text x="{d:.1}" y="{d:.1}" font-size="12" fill="#4a9">{s}{s}</text>
                    \\
                , .{ edge_x + 8.0, py + 4.0, dir_text, port.name });

                // Net label
                if (isGroundNet(baseNetName(port.net))) {
                    try w.print(
                        \\<g class="net" data-net="{s}" style="cursor:pointer">
                        \\
                    , .{port.net});
                    try drawGndSymbol(w, stub_x, py);
                    try w.writeAll("</g>\n");
                } else {
                    try w.print(
                        \\<g class="net" data-net="{s}" style="cursor:pointer">
                        \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="11" font-weight="bold" fill="#4a9eff">{s}</text>
                        \\</g>
                        \\
                    , .{ port.net, stub_x - net_label_gap, py + 4.0, port.net });
                }

                if (port.rated_min != null and port.rated_max != null) {
                    try w.print(
                        \\<text x="{d:.1}" y="{d:.1}" font-size="9" fill="#888">{d:.1}V - {d:.1}V</text>
                        \\
                    , .{ edge_x + 8.0, py + 16.0, port.rated_min.?, port.rated_max.? });
                }

                left_idx += 1;
            }
        }

        return block_height;
    }
};

// ── Static drawing helpers ─────────────────────────────────────────────

/// Draw a wire (Manhattan routing: horizontal, or H-V-H polyline).
fn drawWire(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64) !void {
    if (y1 == y2) {
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
            \\
        , .{ x1, y1, x2, y2 });
    } else {
        const mid_x = (x1 + x2) / 2.0;
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="#4a9" stroke-width="1.5"/>
            \\
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
    }
}

/// Draw a net wire with hit area and data-net attribute.
fn drawNetWire(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64, net: []const u8) !void {
    try w.print(
        \\<g class="net" data-net="{s}" style="cursor:pointer">
    , .{net});

    if (y1 == y2) {
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="transparent" stroke-width="12" class="hit-area"/>
        , .{ x1, y1, x2, y2 });
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
        , .{ x1, y1, x2, y2 });
    } else {
        const mid_x = (x1 + x2) / 2.0;
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="transparent" stroke-width="12" stroke-linejoin="round" class="hit-area"/>
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="#4a9" stroke-width="1.5"/>
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
    }

    try w.writeAll("</g>\n");
}

/// Draw the symbol shape inside a passive component box.
fn drawSymbolShape(w: anytype, bx: f64, bw: f64, cx: f64, cy: f64, inst: FlatInst) !void {
    const ref = shortRef(inst.ref_des);
    const is_ferrite = ref.len >= 2 and ref[0] == 'F' and ref[1] == 'B';

    if (is_ferrite) {
        // Ferrite bead: filled rectangle body with wire stubs
        const body_w: f64 = 24.0;
        const body_h: f64 = 10.0;
        const body_x = cx - body_w / 2.0;
        const body_y = cy - body_h / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="#3a3a5a" stroke="#8888cc" stroke-width="1.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{
            bx,              cy,     body_x,  cy,
            body_x,          body_y, body_w,  body_h,
            body_x + body_w, cy,     bx + bw, cy,
        });
    } else if (std.mem.eql(u8, inst.symbol, "generic-res")) {
        // Resistor: open rectangle body with wire stubs
        const body_w: f64 = 24.0;
        const body_h: f64 = 10.0;
        const body_x = cx - body_w / 2.0;
        const body_y = cy - body_h / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="none" stroke="#8888cc" stroke-width="1.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{
            bx,              cy,     body_x,  cy,
            body_x,          body_y, body_w,  body_h,
            body_x + body_w, cy,     bx + bw, cy,
        });
    } else if (std.mem.eql(u8, inst.symbol, "generic-cap")) {
        // Capacitor: two vertical parallel plates with wire stubs
        const plate_h: f64 = 12.0;
        const gap: f64 = 6.0;
        const plate_l_x = cx - gap / 2.0;
        const plate_r_x = cx + gap / 2.0;
        const plate_top = cy - plate_h / 2.0;
        const plate_bot = cy + plate_h / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="2"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="2"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{
            bx,        cy,        plate_l_x, cy,
            plate_l_x, plate_top, plate_l_x, plate_bot,
            plate_r_x, plate_top, plate_r_x, plate_bot,
            plate_r_x, cy,        bx + bw,   cy,
        });
    } else if (std.mem.eql(u8, inst.symbol, "generic-ind")) {
        // Inductor: three arcs with wire stubs
        const arc_w: f64 = 6.0;
        const n_arcs: u32 = 3;
        const total_arc = arc_w * @as(f64, @floatFromInt(n_arcs));
        const start_x = cx - total_arc / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{ bx, cy, start_x, cy });
        var ai: u32 = 0;
        while (ai < n_arcs) : (ai += 1) {
            const ax = start_x + @as(f64, @floatFromInt(ai)) * arc_w;
            try w.print(
                \\<path d="M {d:.1} {d:.1} A {d:.1} {d:.1} 0 0 1 {d:.1} {d:.1}" fill="none" stroke="#8888cc" stroke-width="1.5"/>
                \\
            , .{ ax, cy, arc_w / 2.0, arc_w / 2.0, ax + arc_w, cy });
        }
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{ start_x + total_arc, cy, bx + bw, cy });
    } else {
        // Default: plain rectangle
        try w.print(
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="16" fill="#2a2a4a" stroke="#8888cc" stroke-width="1" rx="3"/>
            \\
        , .{ bx, cy - 8.0, bw });
    }
}

/// Draw the ground symbol: vertical stub + 3 decreasing horizontal lines.
fn drawGndSymbol(w: anytype, x: f64, y: f64) !void {
    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\
    , .{
        x,       y,        x,       y + 6.0,
        x - 7.0, y + 6.0,  x + 7.0, y + 6.0,
        x - 4.5, y + 9.0,  x + 4.5, y + 9.0,
        x - 2.0, y + 12.0, x + 2.0, y + 12.0,
    });
}

/// Draw the no-connect X symbol.
fn drawNcSymbol(w: anytype, x: f64, y: f64) !void {
    const size: f64 = 5.0;
    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#555" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#555" stroke-width="1.5"/>
        \\
    , .{
        x - size, y - size, x + size, y + size,
        x + size, y - size, x - size, y + size,
    });
}

/// Draw debug pin dot (hidden by default).
fn writeDebugPin(w: anytype, x: f64, y: f64) !void {
    try w.print(
        \\<circle class="debug-pin" cx="{d:.1}" cy="{d:.1}" r="3" fill="red" opacity="0.8" style="display:none"/>
        \\
    , .{ x, y });
}

/// Draw a block-level icon centered at (cx, cy) with given stroke color.
fn drawBlockIcon(w: anytype, icon_name: []const u8, cx: f64, cy: f64, color: []const u8) !void {
    if (std.mem.eql(u8, icon_name, "amplifier")) {
        const size: f64 = 28.0;
        const half_h = size * 0.6;
        const lx = cx - size / 2.0;
        const rx = cx + size / 2.0;
        const ty = cy - half_h;
        const by = cy + half_h;
        try w.print(
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Amplifier</text>
            \\
        , .{ lx, ty, lx, by, rx, cy, color, cx, by + 14.0, color });
    } else if (std.mem.eql(u8, icon_name, "ldo")) {
        const icon_w: f64 = 36.0;
        const icon_h: f64 = 24.0;
        const lx = cx - icon_w / 2.0;
        const ty = cy - icon_h / 2.0;
        const rx = lx + icon_w;
        // Split into multiple prints to stay under 32-arg limit
        try w.print(
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="none" stroke="{s}" stroke-width="1.5" opacity="0.5" rx="2"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="{s}" opacity="0.5"/>
            \\
        , .{
            lx,       ty,       icon_w, icon_h, color,
            lx - 8.0, cy,       lx,     cy,     color,
            lx - 4.0, cy - 3.0, lx,     cy,     lx - 4.0,
            cy + 3.0, color,
        });
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="{s}" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="{s}" opacity="0.5">LDO</text>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Linear Regulator</text>
            \\
        , .{
            rx,       cy,                 rx + 8.0, cy,       color,
            rx + 4.0, cy - 3.0,           rx + 8.0, cy,       rx + 4.0,
            cy + 3.0, color,              cx,       cy + 4.0, color,
            cx,       ty + icon_h + 14.0, color,
        });
    } else if (std.mem.eql(u8, icon_name, "transistor")) {
        const size: f64 = 24.0;
        const half = size / 2.0;
        const ch_x = cx + 4.0;
        const ch_top = cy - half;
        const ch_bot = cy + half;
        const gp_x = ch_x - 4.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="2" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Transistor</text>
            \\
        , .{
            ch_x,      ch_top,        ch_x,       ch_bot,       color,
            cx - half, cy,            gp_x,       cy,           color,
            gp_x,      ch_top + 3.0,  gp_x,       ch_bot - 3.0, color,
            ch_x,      ch_top,        ch_x + 8.0, ch_top,       color,
            ch_x,      ch_bot,        ch_x + 8.0, ch_bot,       color,
            cx,        ch_bot + 14.0, color,
        });
    }
}

// ── Classification helpers ─────────────────────────────────────────────

fn isHub(inst: FlatInst) bool {
    const rd = shortRef(inst.ref_des);
    if (rd.len == 0) return true;
    return switch (rd[0]) {
        'U', 'J', 'P', 'X', 'Q' => true,
        'R', 'C', 'L', 'F', 'D' => false,
        else => true,
    };
}

fn isGroundNet(name: []const u8) bool {
    return std.mem.eql(u8, name, "GND") or std.mem.eql(u8, name, "AGND") or
        std.mem.eql(u8, name, "DGND") or std.mem.startsWith(u8, name, "VSS");
}

fn shortRef(ref_des: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, ref_des, '/')) |idx| return ref_des[idx + 1 ..];
    return ref_des;
}

fn shortNetName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| return name[idx + 1 ..];
    return name;
}

fn baseNetName(name: []const u8) []const u8 {
    const short = shortNetName(name);
    if (std.mem.indexOfScalar(u8, short, '.')) |idx| return short[0..idx];
    return short;
}

fn displayValue(inst: FlatInst) []const u8 {
    if (inst.value.len > 0) return inst.value;
    return inst.component;
}

fn formatShort(inst: FlatInst) []const u8 {
    if (inst.value.len > 0) return inst.value;
    // Extract size from footprint-like component name
    return inst.component;
}

fn endpointEql(a: Endpoint, b: Endpoint) bool {
    switch (a) {
        .net => |an| {
            switch (b) {
                .net => |bn| return std.mem.eql(u8, an, bn),
                .pin => return false,
            }
        },
        .pin => |ap| {
            switch (b) {
                .pin => |bp| return std.mem.eql(u8, ap.ref_des, bp.ref_des) and std.mem.eql(u8, ap.pin, bp.pin),
                .net => return false,
            }
        },
    }
}

/// Classify a component into an icon category based on its symbol, component name, and ref_des.
fn classifyComponent(inst: FlatInst) ?[]const u8 {
    // Check component/symbol name against known patterns
    const name_lower = inst.component;

    // Amplifier keywords
    if (containsCI(name_lower, "pma") or containsCI(name_lower, "lna") or containsCI(name_lower, "mmic")) return "amplifier";
    // Buck converter
    if (containsCI(name_lower, "tpsm") or containsCI(name_lower, "tps5") or containsCI(name_lower, "lm267")) return "buck";
    // LDO
    if (containsCI(name_lower, "lt3045") or containsCI(name_lower, "lt3042") or containsCI(name_lower, "lp5907") or containsCI(name_lower, "ams1117")) return "ldo";
    // Transistor by ref_des
    const ref = shortRef(inst.ref_des);
    if (ref.len > 0 and ref[0] == 'Q') return "transistor";
    if (ref.len > 0 and ref[0] == 'D') return "led";

    return null;
}

/// Case-insensitive substring search.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const a = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            const b = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Compare pin IDs for sorting: try numeric, fall back to string.
fn pinOrder(a: []const u8, b: []const u8) bool {
    const a_num = std.fmt.parseInt(i64, a, 10) catch null;
    const b_num = std.fmt.parseInt(i64, b, 10) catch null;
    if (a_num != null and b_num != null) return a_num.? < b_num.?;
    if (a_num != null) return true; // numbers before alpha
    if (b_num != null) return false;
    return std.mem.order(u8, a, b) == .lt;
}

/// Escape HTML entities in text content.
fn escapeHtml(allocator: Allocator, s: []const u8) ![]const u8 {
    var needs_escape = false;
    for (s) |c| {
        if (c == '&' or c == '<' or c == '>' or c == '"') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return s;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}
