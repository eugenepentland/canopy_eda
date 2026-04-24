const std = @import("std");
const env_mod = @import("eval/env.zig");
const review = @import("review.zig");
const rb = @import("render_block_types.zig");

const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const Instance = env_mod.Instance;
const SubBlock = env_mod.SubBlock;
const Allocator = std.mem.Allocator;

pub const Category = enum { hub, regulation, peripheral, io };

const Chip = struct {
    ref_des: []const u8,
    label: []const u8,
    subtitle: []const u8,
    slug: []const u8,
    category: Category,
};

const SectionRef = struct {
    name: []const u8,
    description: []const u8,
    slug: []const u8,
    /// 2 when the instance is declared directly inside this section via
    /// `(instance X …)`; 1 when the instance is only referenced via a
    /// `(pins X …)` group. Higher priority wins when both routes exist.
    priority: u8,
};

const col_count: usize = 4;
const col_w: f64 = 270;
const col_gap: f64 = 12;
const col_pad: f64 = 10;
const header_h: f64 = 30;
const chip_h: f64 = 46;
const chip_gap: f64 = 6;
const chip_pad_x: f64 = 10;
const svg_pad_y: f64 = 8;
const svg_w: f64 = col_count * col_w + (col_count - 1) * col_gap;

/// Render the system overview as an inline SVG with four category columns.
/// Each chip links to the schematic section card containing the instance.
pub fn renderSystemOverviewSvg(
    allocator: Allocator,
    block: *const DesignBlock,
    w: anytype,
) !void {
    var cols: [4]std.ArrayListUnmanaged(Chip) = .{ .empty, .empty, .empty, .empty };
    defer for (&cols) |*c| c.deinit(allocator);

    try collectChips(allocator, block, &cols);

    // Empty diagram → skip entirely so boards with zero top-level components
    // (rare but possible) don't render an empty card.
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
        const cat: Category = @enumFromInt(i);
        const x = @as(f64, @floatFromInt(i)) * (col_w + col_gap);
        try writeColumn(allocator, w, cat, col.items, x, svg_pad_y, body_h);
    }

    try w.writeAll("</svg></div>");
}

fn writeColumn(
    allocator: Allocator,
    w: anytype,
    cat: Category,
    chips: []const Chip,
    x: f64,
    y: f64,
    h: f64,
) !void {
    const color = categoryColor(cat);
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.1}\" rx=\"8\" class=\"sys-col-bg\"/>",
        .{ x, y, col_w, h },
    );
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-col-title\" fill=\"{s}\">{s}</text>",
        .{ x + col_pad, y + 20, color, categoryTitle(cat) },
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
    const color = categoryColor(chip.category);
    const has_link = chip.slug.len > 0;

    if (has_link) try w.print("<a href=\"#sec-{s}\" class=\"sys-chip-link\">", .{chip.slug});

    try w.print(
        "<g class=\"sys-chip\" data-ref=\"{s}\">",
        .{chip.ref_des},
    );
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.0}\" rx=\"5\" class=\"sys-chip-rect\" stroke=\"{s}\"/>",
        .{ x, y, width, chip_h, color },
    );

    // Ref-des reserves ~ref_chars*7px on the right for a monospace font.
    const ref_reserve: f64 = @as(f64, @floatFromInt(chip.ref_des.len)) * 7.0 + 6.0;
    // Row 1 leading label — budget 6.6px per char for the 11px sans font.
    const label_max: usize = @max(6, @as(usize, @intFromFloat((width - chip_pad_x * 2 - ref_reserve) / 6.6)));
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-chip-label\">",
        .{ x + chip_pad_x, y + 18 },
    );
    try writeHtmlEscaped(w, try truncate(allocator, chip.label, label_max));
    try w.writeAll("</text>");

    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-chip-ref\">",
        .{ x + width - chip_pad_x, y + 18 },
    );
    try writeHtmlEscaped(w, chip.ref_des);
    try w.writeAll("</text>");

    if (chip.subtitle.len > 0) {
        const sub_max: usize = @max(8, @as(usize, @intFromFloat((width - chip_pad_x * 2) / 6.0)));
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"sys-chip-sub\">",
            .{ x + chip_pad_x, y + 34 },
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

fn categoryTitle(cat: Category) []const u8 {
    return switch (cat) {
        .hub => "HUB",
        .regulation => "REGULATION",
        .peripheral => "PERIPHERALS",
        .io => "INPUT / OUTPUT",
    };
}

fn categoryColor(cat: Category) []const u8 {
    return switch (cat) {
        .hub => "#1f6feb",
        .regulation => "#da3633",
        .peripheral => "#2ea043",
        .io => "#d29922",
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
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    // Build ref_des → best-matching SectionRef. Direct `(instance X …)`
    // declarations beat `(pins X …)` references; for pin-group refs we
    // record the top-level ancestor section so pins inside sub-sections
    // surface the parent's broader title/description.
    var sec_map: std.StringHashMapUnmanaged(SectionRef) = .empty;
    defer sec_map.deinit(allocator);
    for (block.sections) |sec| try indexSection(allocator, sec, sec, &sec_map);

    // Top-level instances: stm32n6 declares its MCU and most peripherals at
    // block-scope, then references them inside sections via pin_groups.
    for (block.instances) |inst| {
        if (seen.contains(inst.ref_des)) continue;
        try seen.put(allocator, inst.ref_des, {});
        try addInstance(allocator, inst, sec_map.get(inst.ref_des), cols);
    }

    for (block.sections) |sec| try collectFromSection(allocator, sec, &seen, &sec_map, cols);

    for (block.sub_blocks) |sb| try addSubBlock(allocator, sb, cols);
}

fn indexSection(
    allocator: Allocator,
    sec: Section,
    top: Section,
    sec_map: *std.StringHashMapUnmanaged(SectionRef),
) !void {
    const slug = try review.slugify(allocator, sec.name);
    const top_slug = try review.slugify(allocator, top.name);

    // Recurse into sub-sections *first*: evaluator copies each direct
    // instance up into its parent section's `instances` list too (so the
    // review/BOM see a flat list), which would otherwise let the parent
    // win ties. Walking children first + first-writer-wins at same
    // priority keeps each ref_des pinned to its most-specific section.
    for (sec.sub_sections) |sub| try indexSection(allocator, sub, top, sec_map);

    for (sec.instances) |inst| {
        const ref: SectionRef = .{
            .name = sec.name,
            .description = sec.description,
            .slug = slug,
            .priority = 2,
        };
        try putSectionRef(allocator, sec_map, inst.ref_des, ref);
    }
    for (sec.pin_groups) |pg| {
        const ref: SectionRef = .{
            .name = top.name,
            .description = top.description,
            .slug = top_slug,
            .priority = 1,
        };
        try putSectionRef(allocator, sec_map, pg.ref_des, ref);
    }
}

fn putSectionRef(
    allocator: Allocator,
    map: *std.StringHashMapUnmanaged(SectionRef),
    ref_des: []const u8,
    ref: SectionRef,
) !void {
    if (map.get(ref_des)) |existing| {
        if (existing.priority >= ref.priority) return;
    }
    try map.put(allocator, ref_des, ref);
}

fn collectFromSection(
    allocator: Allocator,
    sec: Section,
    seen: *std.StringHashMapUnmanaged(void),
    sec_map: *std.StringHashMapUnmanaged(SectionRef),
    cols: *[4]std.ArrayListUnmanaged(Chip),
) !void {
    for (sec.instances) |inst| {
        if (seen.contains(inst.ref_des)) continue;
        try seen.put(allocator, inst.ref_des, {});
        try addInstance(allocator, inst, sec_map.get(inst.ref_des), cols);
    }
    for (sec.sub_sections) |sub| try collectFromSection(allocator, sub, seen, sec_map, cols);
}

fn addInstance(
    allocator: Allocator,
    inst: Instance,
    sec_ref: ?SectionRef,
    cols: *[4]std.ArrayListUnmanaged(Chip),
) !void {
    const cat = classifyInstance(inst.ref_des, inst.component, inst.label) orelse return;

    // Prefer the section's title+description (explains *what this is for*:
    // "Display — 0.96\" ST7735S TFT") over the library's component-level
    // description ("10 Position FFC, FPC Connector"). Fall back to the
    // instance label + library blurb when the instance has no section home.
    const instance_label = if (inst.label.len > 0 and !std.mem.eql(u8, inst.label, inst.ref_des))
        inst.label
    else
        inst.component;

    var label: []const u8 = instance_label;
    var subtitle: []const u8 = "";
    var slug: []const u8 = "";

    if (sec_ref) |ref| {
        slug = ref.slug;
        if (ref.name.len > 0) label = ref.name;
        if (ref.description.len > 0) {
            subtitle = ref.description;
        } else {
            subtitle = try buildSubtitle(allocator, inst, label);
        }
    } else {
        subtitle = try buildSubtitle(allocator, inst, instance_label);
    }

    try cols[@intFromEnum(cat)].append(allocator, .{
        .ref_des = inst.ref_des,
        .label = label,
        .subtitle = subtitle,
        .slug = slug,
        .category = cat,
    });
}

fn instProp(inst: Instance, key: []const u8) []const u8 {
    for (inst.properties) |p| {
        if (std.mem.eql(u8, p.key, key) and p.value.len > 0) return p.value;
    }
    return "";
}

/// Compose the chip's secondary line from the component library's
/// `(description …)` field plus the part number, skipping whichever is
/// missing. Falls back to the bare component family name if the library
/// entry has neither (e.g. ad-hoc components).
fn buildSubtitle(allocator: Allocator, inst: Instance, primary: []const u8) ![]const u8 {
    const desc = instProp(inst, "description");
    const mpn = instProp(inst, "mpn");
    return try joinDescMpn(allocator, desc, mpn, inst.component, primary);
}

fn joinDescMpn(
    allocator: Allocator,
    desc: []const u8,
    mpn: []const u8,
    component: []const u8,
    primary: []const u8,
) ![]const u8 {
    // Library descriptions frequently embed the part number already
    // (e.g. "STM32N657L0H3Q ARM Cortex-M55 MCU"). Skip appending MPN
    // when the description already contains it case-insensitively.
    if (desc.len > 0 and mpn.len > 0 and !rb.containsCI(desc, mpn)) {
        return try std.fmt.allocPrint(allocator, "{s} · {s}", .{ desc, mpn });
    }
    if (desc.len > 0) return desc;
    if (mpn.len > 0 and !std.mem.eql(u8, mpn, primary)) return mpn;
    if (!std.mem.eql(u8, component, primary)) return component;
    return "";
}

fn addSubBlock(
    allocator: Allocator,
    sb: SubBlock,
    cols: *[4]std.ArrayListUnmanaged(Chip),
) !void {
    const name = sb.block.name;
    const cat: Category = if (isRegulationComponent(name) or isRegulationComponent(sb.name))
        .regulation
    else
        .peripheral;
    const ref = if (sb.name.len > 0) sb.name else name;
    try cols[@intFromEnum(cat)].append(allocator, .{
        .ref_des = ref,
        .label = name,
        .subtitle = try subBlockSubtitle(allocator, sb),
        .slug = "",
        .category = cat,
    });
}

/// Dig into the nested design to find the key IC (first non-passive U/Q/Y
/// instance) and surface its library description + MPN on the chip's
/// second row — same treatment as a top-level instance.
fn subBlockSubtitle(allocator: Allocator, sb: SubBlock) ![]const u8 {
    for (sb.block.instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        const p = inst.ref_des[0];
        if (p == 'R' or p == 'C' or p == 'L' or p == 'D' or p == 'F') continue;
        if (isPassiveComponent(inst.component)) continue;
        return try joinDescMpn(
            allocator,
            instProp(inst, "description"),
            instProp(inst, "mpn"),
            inst.component,
            sb.block.name,
        );
    }
    return "";
}

// ── Classifier ────────────────────────────────────────────────────────

/// Classifies an instance by ref-des prefix and component/label patterns.
/// Returns null for things that should be omitted (passives, test points,
/// mounting hardware).
pub fn classifyInstance(ref_des: []const u8, component: []const u8, label: []const u8) ?Category {
    if (ref_des.len == 0) return null;
    const p = ref_des[0];

    switch (p) {
        'R', 'C', 'L', 'D', 'F' => return null,
        else => {},
    }

    // Some designs declare a "switch" (e.g. BOOT0 short, reset jumper) as a
    // 0-ohm resistor family — the ref-des is SW1 but the component is
    // res-0402. Treat anything whose component family name says passive as
    // a passive regardless of its ref-des.
    if (isPassiveComponent(component)) return null;

    if (std.mem.startsWith(u8, ref_des, "TP")) return null;
    if (std.mem.eql(u8, component, "testpoint")) return null;

    if (std.mem.startsWith(u8, ref_des, "MH")) return null;
    if (isMechanicalComponent(component)) return null;

    if (p == 'J' or p == 'P') return .io;

    if (isIoLabel(label) or isIoComponent(component)) return .io;

    if (isMcuComponent(component) or isMcuLabel(label)) return .hub;

    if (isRegulationComponent(component)) return .regulation;

    return .peripheral;
}

fn isPassiveComponent(component: []const u8) bool {
    const prefixes = [_][]const u8{ "res-", "cap-", "ind-", "ferrite-", "diode-" };
    return hasLowerPrefix(component, &prefixes);
}

fn isMechanicalComponent(component: []const u8) bool {
    return rb.containsCI(component, "spacer") or
        rb.containsCI(component, "smsi") or
        rb.containsCI(component, "mounting-hole") or
        rb.containsCI(component, "mount-hole") or
        rb.containsCI(component, "-screw");
}

fn isMcuComponent(component: []const u8) bool {
    const prefixes = [_][]const u8{
        "stm32",  "stm8",   "esp32", "esp8266", "nrf52", "nrf53", "nrf91",
        "rp2040", "rp2350", "samd",  "atmega",  "pic32", "pic16", "pic18",
        "imxrt",  "mimxrt", "am335", "k64",     "k66",
    };
    return hasLowerPrefix(component, &prefixes);
}

fn isMcuLabel(label: []const u8) bool {
    if (label.len == 0) return false;
    const exact = [_][]const u8{ "mcu", "soc", "cpu" };
    var buf: [32]u8 = undefined;
    const lower = lowerPrefix(&buf, label);
    for (exact) |e| if (std.mem.eql(u8, lower, e)) return true;
    return false;
}

fn isRegulationComponent(component: []const u8) bool {
    const patterns = [_][]const u8{
        "buck",    "boost", "ldo",  "regulator", "converter",
        "charger", "pmic",  "smps", "dcdc",
    };
    for (patterns) |pat| if (rb.containsCI(component, pat)) return true;
    const part_prefixes = [_][]const u8{
        "tps", "lt30", "lm317", "lm78", "lm105", "ld39",
        "mp2", "ncp",  "act8",  "lp87", "max17", "bq25",
        "mic", "tlv7", "rt",
    };
    return hasLowerPrefix(component, &part_prefixes);
}

fn isIoComponent(component: []const u8) bool {
    const patterns = [_][]const u8{
        "connector", "header",     "rj45",   "jtag", "b2b",
        "ffc",       "receptacle", "socket",
    };
    for (patterns) |pat| if (rb.containsCI(component, pat)) return true;
    const prefixes = [_][]const u8{ "usb", "amphenol", "molex-", "hrs-", "hirose" };
    return hasLowerPrefix(component, &prefixes);
}

fn isIoLabel(label: []const u8) bool {
    if (label.len == 0) return false;
    // Fallback for connectors whose component pattern doesn't match (bare
    // Molex / Hirose part numbers starting with digits). Do NOT include
    // interface keywords like "usb"/"swd" — those often live on ESD chips,
    // protection ICs, and transceivers *beside* the connector, not *at* it.
    const prefixes = [_][]const u8{
        "disp", "display", "expansion", "exp-", "hdr", "conn-", "socket", "io-",
    };
    return hasLowerPrefix(label, &prefixes);
}

fn hasLowerPrefix(s: []const u8, prefixes: []const []const u8) bool {
    var buf: [48]u8 = undefined;
    const lower = lowerPrefix(&buf, s);
    for (prefixes) |p| if (std.mem.startsWith(u8, lower, p)) return true;
    return false;
}

fn lowerPrefix(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (0..n) |i| buf[i] = std.ascii.toLower(s[i]);
    return buf[0..n];
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
    \\.sys-chip-ref{fill:#79c0ff;font-family:"SF Mono","Fira Code",monospace;font-size:11px;text-anchor:end;}
    \\.sys-chip-sub{fill:#8b949e;font-family:"SF Mono","Fira Code",monospace;font-size:10px;}
    \\.sys-chip-link{cursor:pointer;}
;

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: render_system_svg - Classifies MCU-family components as hub
test "classify MCU family as hub" {
    try testing.expectEqual(Category.hub, classifyInstance("U3", "stm32n657l0h3q", "stm32").?);
    try testing.expectEqual(Category.hub, classifyInstance("U1", "esp32-s3", "mcu").?);
    try testing.expectEqual(Category.hub, classifyInstance("U1", "nrf52840", "").?);
}

// spec: render_system_svg - Classifies regulator and converter components as regulation
test "classify regulators as regulation" {
    try testing.expectEqual(Category.regulation, classifyInstance("U4", "tps62840", "buck").?);
    try testing.expectEqual(Category.regulation, classifyInstance("U5", "lt3045-1", "ldo").?);
    try testing.expectEqual(Category.regulation, classifyInstance("U6", "bq25895", "charger").?);
    try testing.expectEqual(Category.regulation, classifyInstance("U7", "ld39020", "").?);
}

// spec: render_system_svg - Classifies J and P ref-des connectors as io
test "classify connectors as io" {
    try testing.expectEqual(Category.io, classifyInstance("J1", "connector-swd", "swd-hdr").?);
    try testing.expectEqual(Category.io, classifyInstance("J3", "usb4235-03-c", "usb-c").?);
    try testing.expectEqual(Category.io, classifyInstance("P1", "pin-header-2x5", "").?);
    // Connector auto-assigned U prefix should still land in IO via label hint.
    try testing.expectEqual(Category.io, classifyInstance("U9", "204928-0601", "expansion").?);
    try testing.expectEqual(Category.io, classifyInstance("U10", "fh12-10s-0-5sh-55-", "disp").?);
}

// spec: render_system_svg - Classifies remaining U-prefix components as peripheral
test "classify other U-prefix as peripheral" {
    try testing.expectEqual(Category.peripheral, classifyInstance("U5", "mx66uw1g45gxdi00", "flash").?);
    try testing.expectEqual(Category.peripheral, classifyInstance("U7", "icm-20948", "imu").?);
    try testing.expectEqual(Category.peripheral, classifyInstance("U8", "ltc6655bhms8-2-5#pbf", "vref").?);
    try testing.expectEqual(Category.peripheral, classifyInstance("Q1", "ao3400a", "q_bl").?);
    try testing.expectEqual(Category.peripheral, classifyInstance("Y1", "abm8", "hse").?);
}

// spec: render_system_svg - Omits passive R C L D F ref-des instances
test "omit passive ref-des" {
    try testing.expectEqual(@as(?Category, null), classifyInstance("R1", "res-0402", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("C42", "cap-0201", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("L1", "ind-2016", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("D1", "diode-0402", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("F1", "ferrite-0402", ""));
    // Ref-des starts with SW (a "switch" implemented as a 0-ohm resistor) —
    // the component family is still a passive, so skip.
    try testing.expectEqual(@as(?Category, null), classifyInstance("SW1", "res-0402", ""));
}

// spec: render_system_svg - Omits testpoint components and TP prefix ref-des
test "omit test points" {
    try testing.expectEqual(@as(?Category, null), classifyInstance("TP1", "testpoint", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("TP8", "testpoint", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("U99", "testpoint", ""));
}

// spec: render_system_svg - Omits mounting hole components and MH prefix ref-des
test "omit mounting hardware" {
    try testing.expectEqual(@as(?Category, null), classifyInstance("MH1", "some-mount", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("H1", "a-wurth-wa-smsi-9774020633r", ""));
    try testing.expectEqual(@as(?Category, null), classifyInstance("H2", "generic-spacer-m3", ""));
}

// spec: render_system_svg - Collapses sub-blocks into a single regulation chip
test "sub-block collapses to single chip" {
    var tpsm_design: DesignBlock = .{
        .name = "tpsm84338",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var ldo_design: DesignBlock = .{
        .name = "lt3045",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var peripheral_design: DesignBlock = .{
        .name = "rf-switch",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    const sub_blocks = [_]SubBlock{
        .{ .name = "buck", .block = &tpsm_design },
        .{ .name = "ldo", .block = &ldo_design },
        .{ .name = "switch", .block = &peripheral_design },
    };

    var cols: [4]std.ArrayListUnmanaged(Chip) = .{ .empty, .empty, .empty, .empty };
    defer for (&cols) |*c| c.deinit(testing.allocator);

    for (sub_blocks) |sb| try addSubBlock(testing.allocator, sb, &cols);

    try testing.expectEqual(@as(usize, 2), cols[@intFromEnum(Category.regulation)].items.len);
    try testing.expectEqual(@as(usize, 1), cols[@intFromEnum(Category.peripheral)].items.len);
}
