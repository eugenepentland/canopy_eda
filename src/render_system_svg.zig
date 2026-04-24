const std = @import("std");
const env_mod = @import("eval/env.zig");
const review = @import("review.zig");
const rb = @import("render_block_types.zig");

const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const SubBlock = env_mod.SubBlock;
const Allocator = std.mem.Allocator;

/// Macro column that a section chip sits in. Narrower than `rb.Category` so
/// the block-diagram silhouette reads at a glance: MCU/hub in the leftmost
/// column, anything power-ish next to it, peripherals in the middle, IO on
/// the right.
pub const Column = enum { hub, regulation, peripheral, io };

const Chip = struct {
    /// Section (or sub-block) display name.
    label: []const u8,
    /// One-line description (section `(description …)` or sub-block design name).
    subtitle: []const u8,
    /// Fine-grained 10-class category used for the chip's accent color and
    /// the small tag rendered on the top-right.
    category: rb.Category,
    /// Slug of the on-page section anchor (`#sec-<slug>`); empty when absent.
    slug: []const u8,
};

const col_count: usize = 4;
const col_w: f64 = 270;
const col_gap: f64 = 12;
const col_pad: f64 = 10;
const header_h: f64 = 30;
const chip_h: f64 = 50;
const chip_gap: f64 = 6;
const chip_pad_x: f64 = 10;
const svg_pad_y: f64 = 8;
const svg_w: f64 = col_count * col_w + (col_count - 1) * col_gap;

/// Render the system overview as an inline SVG. Each chip is one section
/// (or sub-block) from the design, placed into one of four columns by its
/// classified category. Clicking a chip jumps to that section's card below.
pub fn renderSystemOverviewSvg(
    allocator: Allocator,
    block: *const DesignBlock,
    w: anytype,
) !void {
    var cols: [4]std.ArrayListUnmanaged(Chip) = .{ .empty, .empty, .empty, .empty };
    defer for (&cols) |*c| c.deinit(allocator);

    try collectChips(allocator, block, &cols);

    var any = false;
    for (cols) |c| if (c.items.len > 0) {
        any = true;
        break;
    };
    if (!any) return;

    var max_chips: usize = 0;
    for (cols) |c| if (c.items.len > max_chips) {
        max_chips = c.items.len;
    };
    if (max_chips == 0) max_chips = 1;

    const body_h = header_h + @as(f64, @floatFromInt(max_chips)) * (chip_h + chip_gap) + col_pad;
    const svg_h = body_h + svg_pad_y * 2;

    try w.writeAll("<div class=\"sys-overview\">");
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"sys-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ svg_w, svg_h },
    );

    for (cols, 0..) |col, i| {
        const column: Column = @enumFromInt(i);
        const x = @as(f64, @floatFromInt(i)) * (col_w + col_gap);
        try writeColumn(allocator, w, column, col.items, x, svg_pad_y, body_h);
    }

    try w.writeAll("</svg></div>");
}

fn writeColumn(
    allocator: Allocator,
    w: anytype,
    column: Column,
    chips: []const Chip,
    x: f64,
    y: f64,
    h: f64,
) !void {
    const color = columnColor(column);
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.1}\" rx=\"8\" class=\"sys-col-bg\"/>",
        .{ x, y, col_w, h },
    );
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-col-title\" fill=\"{s}\">{s}</text>",
        .{ x + col_pad, y + 20, color, columnTitle(column) },
    );

    if (chips.len == 0) {
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-empty\">—</text>",
            .{ x + col_w / 2, y + header_h + 32 },
        );
        return;
    }

    var cy = y + header_h;
    for (chips) |chip| {
        try writeChip(allocator, w, chip, x + col_pad, cy, col_w - col_pad * 2);
        cy += chip_h + chip_gap;
    }
}

fn writeChip(
    allocator: Allocator,
    w: anytype,
    chip: Chip,
    x: f64,
    y: f64,
    width: f64,
) !void {
    const color = rb.categoryColor(chip.category);
    const has_link = chip.slug.len > 0;
    const cat_name = @tagName(chip.category);

    if (has_link) try w.print("<a href=\"#sec-{s}\" class=\"sys-chip-link\">", .{chip.slug});

    try w.writeAll("<g class=\"sys-chip\">");
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.0}\" rx=\"5\" class=\"sys-chip-rect\" stroke=\"{s}\"/>",
        .{ x, y, width, chip_h, color },
    );

    // Reserve room on the right for the category tag — ~6.2px per character
    // of 10px monospace plus a small gap.
    const cat_reserve: f64 = @as(f64, @floatFromInt(cat_name.len)) * 6.2 + 10.0;
    const label_max: usize = @max(6, @as(usize, @intFromFloat((width - chip_pad_x * 2 - cat_reserve) / 6.6)));
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-chip-label\">",
        .{ x + chip_pad_x, y + 18 },
    );
    try writeHtmlEscaped(w, try truncate(allocator, chip.label, label_max));
    try w.writeAll("</text>");

    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-chip-cat\" fill=\"{s}\">",
        .{ x + width - chip_pad_x, y + 18, color },
    );
    try writeHtmlEscaped(w, cat_name);
    try w.writeAll("</text>");

    if (chip.subtitle.len > 0) {
        const sub_max: usize = @max(8, @as(usize, @intFromFloat((width - chip_pad_x * 2) / 5.6)));
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-chip-sub\">",
            .{ x + chip_pad_x, y + 36 },
        );
        try writeHtmlEscaped(w, try truncate(allocator, chip.subtitle, sub_max));
        try w.writeAll("</text>");
    }
    try w.writeAll("</g>");

    if (has_link) try w.writeAll("</a>");
}

fn truncate(allocator: Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return s;
    if (max <= 1) return s[0..max];
    return try std.fmt.allocPrint(allocator, "{s}…", .{s[0 .. max - 1]});
}

fn columnTitle(column: Column) []const u8 {
    return switch (column) {
        .hub => "HUB",
        .regulation => "REGULATION",
        .peripheral => "PERIPHERALS",
        .io => "INPUT / OUTPUT",
    };
}

fn columnColor(column: Column) []const u8 {
    return switch (column) {
        .hub => "#1f6feb",
        .regulation => "#da3633",
        .peripheral => "#2ea043",
        .io => "#d29922",
    };
}

/// Maps the fine-grained 10-class section category to one of the four
/// macro columns in the diagram.
pub fn columnFor(cat: rb.Category) Column {
    return switch (cat) {
        .mcu => .hub,
        .power => .regulation,
        .connector => .io,
        .memory, .peripheral, .sensor, .analog, .comms, .clock, .protection => .peripheral,
    };
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

// ── Collection ────────────────────────────────────────────────────────

fn collectChips(
    allocator: Allocator,
    block: *const DesignBlock,
    cols: *[4]std.ArrayListUnmanaged(Chip),
) !void {
    for (block.sections) |sec| try addSection(allocator, sec, cols);
    for (block.sub_blocks) |sb| try addSubBlock(allocator, sb, cols);

    // Designs without any explicit `(section …)` still render one synthetic
    // card whose anchor is `#sec-design` (see render_html.writeFlatHubs). Emit
    // one matching chip so the overview isn't empty for those designs.
    if (block.sections.len == 0 and block.sub_blocks.len == 0) {
        var has_hub = false;
        for (block.instances) |inst| {
            if (inst.ref_des.len == 0) continue;
            switch (inst.ref_des[0]) {
                'R', 'C', 'L', 'D', 'F' => continue,
                else => {
                    has_hub = true;
                    break;
                },
            }
        }
        if (has_hub) {
            const cat = rb.classifyByName(block.name, block.instances);
            const col = columnFor(cat);
            try cols[@intFromEnum(col)].append(allocator, .{
                .label = block.name,
                .subtitle = "",
                .category = cat,
                .slug = "design",
            });
        }
    }
}

fn addSection(
    allocator: Allocator,
    sec: Section,
    cols: *[4]std.ArrayListUnmanaged(Chip),
) !void {
    const cat = rb.classifySection(sec);
    const col = columnFor(cat);
    const slug = try review.slugify(allocator, sec.name);
    try cols[@intFromEnum(col)].append(allocator, .{
        .label = sec.name,
        .subtitle = sec.description,
        .category = cat,
        .slug = slug,
    });
    // Sub-sections render as their own cards on the page, so each one also
    // gets its own chip — otherwise the overview would hide nested structure
    // that the user can still click to in the sidebar.
    for (sec.sub_sections) |sub| try addSection(allocator, sub, cols);
}

fn addSubBlock(
    allocator: Allocator,
    sb: SubBlock,
    cols: *[4]std.ArrayListUnmanaged(Chip),
) !void {
    const cat = rb.classifyByName(sb.name, sb.block.instances);
    const col = columnFor(cat);
    const slug = try review.slugify(allocator, sb.name);
    try cols[@intFromEnum(col)].append(allocator, .{
        .label = if (sb.name.len > 0) sb.name else sb.block.name,
        .subtitle = sb.block.name,
        .category = cat,
        .slug = slug,
    });
}

/// CSS fragment for the system overview. Embedded into the schematic page by
/// render_html.zig.
pub const SYSTEM_OVERVIEW_CSS =
    \\.sys-overview{margin:12px 0 4px;padding:10px;background:#0d1117;border:1px solid #21262d;border-radius:8px;overflow-x:auto;}
    \\.sys-svg{display:block;width:100%;max-width:1160px;height:auto;}
    \\.sys-col-bg{fill:#12161d;stroke:#21262d;stroke-width:1;}
    \\.sys-col-title{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:11px;font-weight:700;letter-spacing:0.08em;}
    \\.sys-empty{fill:#6e7681;font-size:14px;text-anchor:middle;font-family:-apple-system,BlinkMacSystemFont,sans-serif;}
    \\.sys-chip-rect{fill:#0d1117;stroke-width:1.5;}
    \\.sys-chip:hover .sys-chip-rect{fill:#161b22;}
    \\.sys-chip-label{fill:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:12px;font-weight:600;}
    \\.sys-chip-cat{font-family:"SF Mono","Fira Code",monospace;font-size:10px;text-anchor:end;text-transform:uppercase;letter-spacing:0.04em;font-weight:700;}
    \\.sys-chip-sub{fill:#8b949e;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:10px;}
    \\.sys-chip-link{cursor:pointer;}
;

// ── Tests ─────────────────────────────────────────────────────────────

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

// spec: render_system_svg - Maps section categories to macro columns
test "columnFor mapping" {
    try testing.expectEqual(Column.hub, columnFor(.mcu));
    try testing.expectEqual(Column.regulation, columnFor(.power));
    try testing.expectEqual(Column.io, columnFor(.connector));
    try testing.expectEqual(Column.peripheral, columnFor(.memory));
    try testing.expectEqual(Column.peripheral, columnFor(.comms));
    try testing.expectEqual(Column.peripheral, columnFor(.sensor));
    try testing.expectEqual(Column.peripheral, columnFor(.analog));
    try testing.expectEqual(Column.peripheral, columnFor(.clock));
    try testing.expectEqual(Column.peripheral, columnFor(.protection));
    try testing.expectEqual(Column.peripheral, columnFor(.peripheral));
}

// spec: render_system_svg - Builds one chip per section classified by name
test "sections become chips in their mapped column" {
    const sections = [_]Section{
        .{ .name = "MCU", .description = "main brain" },
        .{ .name = "Buck Power", .description = "3.3V rail" },
        .{ .name = "USB-C Connector", .description = "" },
        .{ .name = "QSPI Flash", .description = "" },
    };

    var block = emptyBlock("demo");
    block.sections = &sections;

    var cols: [4]std.ArrayListUnmanaged(Chip) = .{ .empty, .empty, .empty, .empty };
    defer for (&cols) |*c| c.deinit(testing.allocator);
    try collectChips(testing.allocator, &block, &cols);

    try testing.expectEqual(@as(usize, 1), cols[@intFromEnum(Column.hub)].items.len);
    try testing.expectEqual(@as(usize, 1), cols[@intFromEnum(Column.regulation)].items.len);
    // "USB-C Connector" contains "Connector", which classifyByName checks
    // *after* USB, but USB wins → comms → peripherals column. That means the
    // IO column stays empty for this input; assert the structure we actually
    // expect rather than a hoped-for mapping.
    try testing.expectEqual(@as(usize, 0), cols[@intFromEnum(Column.io)].items.len);
    try testing.expectEqual(@as(usize, 2), cols[@intFromEnum(Column.peripheral)].items.len);
}

// spec: render_system_svg - Recurses into sub-sections to expose each as its own chip
test "sub-sections produce their own chips" {
    const children = [_]Section{
        .{ .name = "Buck Power", .description = "" },
        .{ .name = "LDO", .description = "" },
    };
    const sections = [_]Section{.{
        .name = "Power Tree",
        .description = "",
        .sub_sections = &children,
    }};

    var block = emptyBlock("demo");
    block.sections = &sections;

    var cols: [4]std.ArrayListUnmanaged(Chip) = .{ .empty, .empty, .empty, .empty };
    defer for (&cols) |*c| c.deinit(testing.allocator);
    try collectChips(testing.allocator, &block, &cols);

    // Parent + two children, all classified as power → regulation column.
    try testing.expectEqual(@as(usize, 3), cols[@intFromEnum(Column.regulation)].items.len);
}

// spec: render_system_svg - Emits a chip per sub-block classified by its name
test "sub-blocks produce chips classified by name" {
    var buck_design = emptyBlock("tpsm84338");
    var rf_design = emptyBlock("rf-switch");

    const sub_blocks = [_]SubBlock{
        .{ .name = "buck", .block = &buck_design },
        .{ .name = "switch", .block = &rf_design },
    };
    var block = emptyBlock("demo");
    block.sub_blocks = &sub_blocks;

    var cols: [4]std.ArrayListUnmanaged(Chip) = .{ .empty, .empty, .empty, .empty };
    defer for (&cols) |*c| c.deinit(testing.allocator);
    try collectChips(testing.allocator, &block, &cols);

    try testing.expectEqual(@as(usize, 1), cols[@intFromEnum(Column.regulation)].items.len);
    try testing.expectEqual(@as(usize, 1), cols[@intFromEnum(Column.peripheral)].items.len);
}

// spec: render_system_svg - Falls back to one synthetic chip when a design has no sections
test "flat design with only top-level hubs produces a synthetic chip" {
    const instances = [_]env_mod.Instance{.{
        .ref_des = "U1",
        .component = "stm32n657l0h3q",
        .value = "",
        .footprint = "",
        .symbol = "",
    }};
    var block = emptyBlock("stm32-flat");
    block.instances = &instances;

    var cols: [4]std.ArrayListUnmanaged(Chip) = .{ .empty, .empty, .empty, .empty };
    defer for (&cols) |*c| c.deinit(testing.allocator);
    try collectChips(testing.allocator, &block, &cols);

    var total: usize = 0;
    for (cols) |c| total += c.items.len;
    try testing.expectEqual(@as(usize, 1), total);
}
