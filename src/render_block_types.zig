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

/// Pick the best-fitting `Category` for a section. Thin wrapper around
/// `classifyByName` that passes the section's name and instances so the
/// keyword + ref-des heuristics can both fire.
pub fn classifySection(sec: env_mod.Section) Category {
    return classifyByName(sec.name, sec.instances);
}

/// Classify a section/sub-block into a `Category` from a section name and
/// its instances. Order matters — the MCU keywords run first so a "STM32
/// Core System" section that happens to embed a debug header still lands
/// in the MCU category instead of the connector heuristic below.
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
