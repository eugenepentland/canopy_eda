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
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = block_w,
    h: f64 = 0,
    col: usize = 0,
};

pub const Category = enum { mcu, power, memory, peripheral, connector, clock };

pub fn categoryColor(cat: Category) []const u8 {
    return switch (cat) {
        .mcu => "#1f6feb",
        .power => "#da3633",
        .memory => "#8957e5",
        .peripheral => "#2ea043",
        .connector => "#d29922",
        .clock => "#4a9",
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

pub fn strInList(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

pub fn classifySection(sec: env_mod.Section) Category {
    const name = sec.name;
    if (containsCI(name, "Buck") or containsCI(name, "LDO") or containsCI(name, "Regulator") or containsCI(name, "Power")) return .power;
    if (containsCI(name, "Flash") or containsCI(name, "PSRAM") or containsCI(name, "RAM") or containsCI(name, "EEPROM")) return .memory;
    if (containsCI(name, "Clock") or containsCI(name, "HSE") or containsCI(name, "LSE") or containsCI(name, "Oscillator")) return .clock;
    if (containsCI(name, "Connector") or containsCI(name, "Expansion") or containsCI(name, "Header")) return .connector;
    for (sec.instances) |inst| {
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
