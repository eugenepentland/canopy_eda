const std = @import("std");
const env_mod = @import("eval/env.zig");

// ── Layout Constants ──────────────────────────────────────────────────
pub const block_w: f64 = 220.0;
pub const block_min_h: f64 = 60.0;
pub const line_h: f64 = 18.0;
pub const block_pad: f64 = 14.0;
pub const grid_gap_x: f64 = 140.0;
pub const grid_gap_y: f64 = 30.0;
pub const margin_val: f64 = 50.0;
pub const top_margin: f64 = 50.0;
pub const arrow_size: f64 = 7.0;

// ── Colors ────────────────────────────────────────────────────────────
pub fn signalColor(sig: env_mod.SignalType) []const u8 {
    return switch (sig) {
        .power => "#e06060",
        .clock => "#4a9",
        .data, .differential => "#4a9eff",
        .signal => "#8b949e",
    };
}

// ── High-level block ──────────────────────────────────────────────────
pub const Block = struct {
    title: []const u8,
    subtitle: []const u8,
    detail: []const u8,
    category: Category,
    ports: []const env_mod.SectionPort,
    protocols: []const []const u8 = &.{},
    status: env_mod.SectionStatus = .implemented,
    has_ic: bool = false,
    block_role: env_mod.BlockRole = .auto,
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = block_w,
    h: f64 = 0,
    col: usize = 0,
};

pub const Category = enum { mcu, power, memory, peripheral, connector, clock, comms, sensor, analog, protection };

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

pub fn categoryColumn(cat: Category) usize {
    return switch (cat) {
        .power, .clock, .protection => 0,
        .mcu => 1,
        .memory, .comms, .sensor, .connector, .peripheral, .analog => 2,
    };
}

/// Sort priority within a column (lower = higher in column).
pub fn categorySortOrder(cat: Category) usize {
    return switch (cat) {
        .mcu => 0,
        // Left column
        .power => 0,
        .protection => 1,
        .clock => 2,
        // Right column
        .memory => 0,
        .comms => 1,
        .sensor => 2,
        .analog => 3,
        .peripheral => 4,
        .connector => 5,
    };
}

pub const Edge = struct {
    from: usize,
    to: usize,
    label: []const u8,
    signal_type: env_mod.SignalType,
    voltage: ?f64,
};

pub fn blk_text_height(blk: Block) f64 {
    var h: f64 = line_h;
    if (blk.subtitle.len > 0) h += line_h;
    if (blk.detail.len > 0) h += line_h;
    return h;
}

pub fn edgeExists(items: []const Edge, from: usize, to: usize, label: []const u8) bool {
    for (items) |e| {
        if (e.from == from and e.to == to and std.mem.eql(u8, e.label, label)) return true;
    }
    return false;
}

const bidi_protocols = [_][]const u8{ "SPI", "I2C", "UART", "USB", "USB2.0-HS", "USB2.0-FS", "OctoSPI", "QuadSPI", "QSPI", "SWD", "JTAG", "SDIO", "SDMMC", "CAN" };

pub fn isBidirectional(label: []const u8) bool {
    for (&bidi_protocols) |proto| {
        if (std.mem.eql(u8, label, proto)) return true;
    }
    return false;
}

pub fn strInList(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

pub fn classifySection(sec: env_mod.Section) Category {
    return classifyByName(sec.name, sec.instances);
}

/// Returns true for sections that are support/infrastructure (LEDs, clocking, boot, mounting)
/// and should go in a separate Support section rather than Power/Signal flow.
pub fn isSupportSection(sec: env_mod.Section) bool {
    // LEDs, power indicators
    if (containsCI(sec.name, "LED")) return true;
    if (containsCI(sec.name, "Boot") or containsCI(sec.name, "Reset")) return true;
    const cat = classifySection(sec);
    return switch (cat) {
        .clock => true,
        .peripheral => sec.protocols.len == 0,
        .connector => {
            if (containsCI(sec.name, "Mounting") or containsCI(sec.name, "Test")) return true;
            return false;
        },
        else => false,
    };
}

pub fn classifyByName(name: []const u8, instances: []const env_mod.Instance) Category {
    // MCU — detect ahead of everything else so e.g. "STM32N657L0H3Q Core
    // System" doesn't fall through to the J/P connector heuristic below
    // just because it embeds a debug-header (J-prefix) instance.
    if (containsCI(name, "MCU") or containsCI(name, "SoC") or
        containsCI(name, "CPU") or containsCI(name, "Core System") or
        containsCI(name, "STM32") or containsCI(name, "ESP32") or
        containsCI(name, "nRF") or containsCI(name, "Microcontroller")) return .mcu;
    // Power
    if (containsCI(name, "Buck") or containsCI(name, "LDO") or containsCI(name, "Regulator") or
        containsCI(name, "Power") or containsCI(name, "Charger") or containsCI(name, "Converter") or
        containsCI(name, "PMIC")) return .power;
    // Memory
    if (containsCI(name, "Flash") or containsCI(name, "PSRAM") or containsCI(name, "RAM") or
        containsCI(name, "EEPROM") or containsCI(name, "SD Card")) return .memory;
    // Clocking
    if (containsCI(name, "Clock") or containsCI(name, "HSE") or containsCI(name, "LSE") or
        containsCI(name, "Oscillator") or containsCI(name, "PLL") or containsCI(name, "Crystal")) return .clock;
    // Comms
    if (containsCI(name, "USB") or containsCI(name, "Ethernet") or containsCI(name, "BLE") or
        containsCI(name, "WiFi") or containsCI(name, "CAN") or containsCI(name, "UART")) return .comms;
    // Sensor
    if (containsCI(name, "IMU") or containsCI(name, "ADC") or containsCI(name, "Sensor") or
        containsCI(name, "Temperature") or containsCI(name, "Accelerometer") or containsCI(name, "Gyro")) return .sensor;
    // Analog
    if (containsCI(name, "Analog") or containsCI(name, "DAC") or containsCI(name, "Op-Amp") or
        containsCI(name, "Reference") or containsCI(name, "Amplifier")) return .analog;
    // Protection
    if (containsCI(name, "ESD") or containsCI(name, "Protection") or containsCI(name, "Fuse") or
        containsCI(name, "TVS")) return .protection;
    // Connector
    if (containsCI(name, "Connector") or containsCI(name, "Expansion") or containsCI(name, "Header") or
        containsCI(name, "Mounting") or containsCI(name, "SWD") or containsCI(name, "Debug") or
        containsCI(name, "RJ45") or containsCI(name, "B2B")) return .connector;
    for (instances) |inst| {
        if (inst.ref_des.len > 0 and (inst.ref_des[0] == 'J' or inst.ref_des[0] == 'P')) return .connector;
    }
    return .peripheral;
}

pub fn findKeyComponent(sec: env_mod.Section) []const u8 {
    for (sec.instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        const prefix = inst.ref_des[0];
        if (prefix == 'R' or prefix == 'C' or prefix == 'L' or prefix == 'D' or prefix == 'F') continue;
        for (inst.properties) |prop| {
            if (std.mem.eql(u8, prop.key, "mpn") and prop.value.len > 0) return prop.value;
        }
        return inst.component;
    }
    return "";
}

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

pub fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
