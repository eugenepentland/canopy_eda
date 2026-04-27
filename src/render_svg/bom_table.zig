const std = @import("std");
const env_mod = @import("../eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const Allocator = std.mem.Allocator;
const draw = @import("draw.zig");
const RenderError = draw.RenderError;

/// Emit the BOM table at the bottom of the SVG schematic — one row per
/// distinct (component, value, footprint, attrs) tuple with its rolled-up
/// ref-des list and Qty. Returns the table's drawn height so the caller
/// can extend the SVG viewport accordingly.
pub fn renderBomTable(allocator: Allocator, w: anytype, block: *const DesignBlock, y_start: f64, table_width: f64) RenderError!f64 {
    var all_instances: std.ArrayListUnmanaged(env_mod.Instance) = .empty;
    defer all_instances.deinit(allocator);
    try collectAllInstances(allocator, block, &all_instances);

    if (all_instances.items.len == 0) return 0;

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
        const attrs_key = if (inst.attrs.len > 0) blk: {
            var ab: std.ArrayListUnmanaged(u8) = .empty;
            for (inst.attrs, 0..) |attr, ai| {
                if (ai > 0) try ab.append(allocator, ' ');
                try ab.appendSlice(allocator, attr);
            }
            break :blk ab.toOwnedSlice(allocator) catch "";
        } else "";

        var found = false;
        for (entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key.component, inst.component) and
                std.mem.eql(u8, entry.key.value, inst.value) and
                std.mem.eql(u8, entry.key.footprint, inst.footprint) and
                std.mem.eql(u8, entry.key.attrs_key, attrs_key))
            {
                entry.count += 1;
                try entry.ref_des_list.append(allocator, inst.ref_des);
                found = true;
                break;
            }
        }
        if (!found) {
            var mpn: []const u8 = "";
            var manufacturer: []const u8 = "";
            for (inst.properties) |prop| {
                if (std.mem.eql(u8, prop.key, "mpn")) mpn = prop.value;
                if (std.mem.eql(u8, prop.key, "manufacturer")) manufacturer = prop.value;
            }
            var ref_list: std.ArrayListUnmanaged([]const u8) = .empty;
            try ref_list.append(allocator, inst.ref_des);
            try entries.append(allocator, .{
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
            });
        }
    }

    if (entries.items.len == 0) return 0;

    std.mem.sortUnstable(BomEntry, entries.items, {}, struct {
        fn lt(_: void, a: BomEntry, b: BomEntry) bool {
            const cmp = std.mem.order(u8, a.key.component, b.key.component);
            if (cmp == .lt) return true;
            if (cmp == .gt) return false;
            return std.mem.order(u8, a.key.value, b.key.value) == .lt;
        }
    }.lt);

    const row_height: f64 = 20.0;
    const header_height: f64 = 28.0;
    const title_height: f64 = 30.0;
    const pad_x: f64 = 12.0;
    const font_size: f64 = 11.0;
    const header_font: f64 = 11.0;
    const x = 8.0;
    const w_total = @min(table_width - 16.0, 1600.0);

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

    try w.print(
        \\<g class="bom-table">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" rx="8" fill="#0d1117" stroke="#21262d" stroke-width="1.5" pointer-events="none"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="18" font-weight="bold" fill="#8b949e" pointer-events="none">Bill of Materials</text>
        \\
    , .{
        x,                 y_start,        w_total, table_h,
        x + w_total / 2.0, y_start + 22.0,
    });

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

    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#21262d" stroke-width="1" pointer-events="none"/>
        \\
    , .{ x, header_y + header_height, x + w_total, header_y + header_height });

    var ry = header_y + header_height;
    for (entries.items, 0..) |entry, ri| {
        if (ri % 2 == 1) {
            try w.print(
                \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.0}" fill="#0d1117" pointer-events="none"/>
                \\
            , .{ x, ry, w_total, row_height });
        }

        var ref_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer ref_buf.deinit(allocator);
        for (entry.ref_des_list.items, 0..) |rd, rdi| {
            if (rdi > 0) try ref_buf.appendSlice(allocator, ", ");
            try ref_buf.appendSlice(allocator, rd);
        }
        const refs_str = ref_buf.items;

        const text_y = ry + 14.0;
        cx = x;

        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#e0e0e0" pointer-events="none">{d}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.count });
        cx += col_qty;

        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#79c0ff" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, refs_str });
        cx += col_refs;

        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#e0e0e0" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.key.value });
        cx += col_value;

        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#8b949e" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.key.footprint });
        cx += col_footprint;

        if (entry.key.attrs_key.len > 0) {
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#d2a8ff" pointer-events="none">{s}</text>
                \\
            , .{ cx + pad_x, text_y, font_size, entry.key.attrs_key });
        }
        cx += col_attrs;

        if (entry.mpn.len > 0) {
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#e0e0e0" pointer-events="none">{s}</text>
                \\
            , .{ cx + pad_x, text_y, font_size, entry.mpn });
        }
        cx += col_mpn;

        if (entry.manufacturer.len > 0) {
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#8b949e" pointer-events="none">{s}</text>
                \\
            , .{ cx + pad_x, text_y, font_size, entry.manufacturer });
        }
        cx += col_mfr;

        try w.print(
            \\<text x="{d:.1}" y="{d:.1}" font-size="{d:.0}" fill="#8b949e" pointer-events="none">{s}</text>
            \\
        , .{ cx + pad_x, text_y, font_size, entry.key.component });

        ry += row_height;
    }

    var total_parts: u32 = 0;
    for (entries.items) |entry_item| total_parts += entry_item.count;
    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" font-size="11" fill="#6e7681" pointer-events="none">{d} unique lines, {d} total parts</text>
        \\
    , .{ x + pad_x, ry + 16.0, entries.items.len, total_parts });

    try w.writeAll("</g>\n");
    return table_h + 20.0;
}

/// Recursively flatten every `Instance` from a DesignBlock and all of its
/// sub-blocks into `out` so the BOM grouping pass sees each placed part
/// once. Sub-block instances keep their original ref-des — they were
/// already globalized by the evaluator's auto-assign pass.
pub fn collectAllInstances(allocator: Allocator, block: *const DesignBlock, out: *std.ArrayListUnmanaged(env_mod.Instance)) RenderError!void {
    for (block.instances) |inst| {
        try out.append(allocator, inst);
    }
    for (block.sub_blocks) |sb| {
        try collectAllInstances(allocator, sb.block, out);
    }
}
