const std = @import("std");
const env_mod = @import("eval/env.zig");

// Section / sub-block category helpers. Originally shared between the
// (now-removed) Pixi.js block diagram and the system-overview SVG embedded
// in the schematic page; only the system SVG and `render_html.zig` still
// consume the classifier today.

/// Coarse classification of a block, used to pick its color and which
/// column it sits in. Inferred from the section name + instance ref-deses
/// by `classifyByName`.
pub const Category = enum { mcu, power, memory, peripheral, connector, clock, comms, sensor, analog, protection };

/// Hex color for a block of this category. Picked from the GitHub-style
/// dark-theme palette so the system overview looks consistent with the
/// schematic and review pages.
pub fn categoryColor(cat: Category) []const u8 {
    return switch (cat) {
        .mcu => "#1f6feb",
        .power => "#da3633",
        .memory => "#8957e5",
        .peripheral => "#2ea043",
        .connector => "#d29922",
        .clock => "#4a9",
        .comms => "#2196f3",
        .sensor => "#2ea043",
        .analog => "#e040fb",
        .protection => "#8b949e",
    };
}

/// Map an explicit `(category <key>)` declaration to a `Category`. Returns
/// null for an unrecognized key so the caller falls back to the name
/// heuristic (and, once the diagram engine is data-driven, an unknown key
/// can mint its own category).
fn categoryFromKey(key: []const u8) ?Category {
    return category_keys.get(key);
}

/// Valid `(category <key>)` keys. Pub so the generated language
/// reference can list them from the same map the classifier consults.
pub const category_keys = std.StaticStringMap(Category).initComptime(.{
    .{ "mcu", .mcu },
    .{ "power", .power },
    .{ "memory", .memory },
    .{ "peripheral", .peripheral },
    .{ "connector", .connector },
    .{ "clock", .clock },
    .{ "comms", .comms },
    .{ "sensor", .sensor },
    .{ "analog", .analog },
    .{ "protection", .protection },
});

/// Pick the best-fitting `Category` for a section. An explicit
/// `(category <key>)` declaration is authoritative; otherwise fall back to
/// the `classifyByName` keyword + ref-des heuristics.
pub fn classifySection(sec: env_mod.Section) Category {
    if (sec.category.len > 0) {
        if (categoryFromKey(sec.category)) |c| return c;
    }
    return classifyByName(sec.name, sec.instances);
}

/// Classify a placeholder `(stub …)` for its diagram column/colour. An explicit
/// `(category <key>)` is authoritative; otherwise fall back to the name
/// heuristic. Mirrors `classifySection` for parts that aren't sections.
pub fn classifyCategoryKey(category: []const u8, name: []const u8) Category {
    if (category.len > 0) {
        if (categoryFromKey(category)) |c| return c;
    }
    return classifyByName(name, &.{});
}

/// One keyword rule for `classifyByName`: a section whose name contains
/// any of `keywords` (case-insensitive) gets `category`.
pub const NameRule = struct {
    category: Category,
    keywords: []const []const u8,
};

/// Priority-ordered keyword rules — the single source of truth for both
/// `classifyByName` and the generated language reference (`src/docgen.zig`
/// renders this table into `docs/language-forms.md`). Order matters: the
/// MCU keywords run first so e.g. a "STM32N657 Core System" section that
/// happens to embed a debug-header (J-prefix) instance still lands in the
/// MCU category instead of the connector heuristic below.
pub const name_rules = [_]NameRule{
    .{ .category = .mcu, .keywords = &.{ "MCU", "SoC", "CPU", "Core System", "STM32", "ESP32", "nRF", "Microcontroller" } },
    .{ .category = .power, .keywords = &.{ "Buck", "LDO", "Regulator", "Power", "Charger", "Converter", "PMIC" } },
    .{ .category = .memory, .keywords = &.{ "Flash", "PSRAM", "RAM", "EEPROM", "SD Card" } },
    .{ .category = .clock, .keywords = &.{ "Clock", "HSE", "LSE", "Oscillator", "PLL", "Crystal" } },
    .{ .category = .comms, .keywords = &.{ "USB", "Ethernet", "BLE", "WiFi", "CAN", "UART" } },
    .{ .category = .sensor, .keywords = &.{ "IMU", "ADC", "Sensor", "Temperature", "Accelerometer", "Gyro" } },
    .{ .category = .analog, .keywords = &.{ "Analog", "DAC", "Op-Amp", "Reference", "Amplifier" } },
    .{ .category = .protection, .keywords = &.{ "ESD", "Protection", "Fuse", "TVS" } },
    .{ .category = .connector, .keywords = &.{ "Connector", "Expansion", "Header", "Mounting", "SWD", "Debug", "RJ45", "B2B" } },
};

/// Classify a section/sub-block into a `Category` from a section name and
/// its instances by walking `name_rules` in priority order, then falling
/// back to a J/P ref-des connector heuristic, then `.peripheral`.
pub fn classifyByName(name: []const u8, instances: []const env_mod.Instance) Category {
    for (name_rules) |rule| {
        for (rule.keywords) |kw| {
            if (containsCI(name, kw)) return rule.category;
        }
    }
    for (instances) |inst| {
        if (inst.ref_des.len > 0 and (inst.ref_des[0] == 'J' or inst.ref_des[0] == 'P')) return .connector;
    }
    return .peripheral;
}

/// Case-insensitive substring search — section names aren't normalized at
/// parse time, so the classifier needs to match "USB", "usb", and "Usb"
/// equally without allocating a lowercased copy.
pub fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (toLower(hc) != toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// ASCII-only `to_lower` — kept inline-able and panic-free so the hot
/// `containsCI` scan over section names doesn't pay an allocator round trip.
pub fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
