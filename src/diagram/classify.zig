//! Net classification: decide whether a net carries power, a clock, a control
//! signal, or an RF/analog signal (or is ground). Drives which view each
//! inter-block edge appears in.
//!
//! Strategy (first match wins): an explicit `SectionPort.signal_type` of
//! `.power`/`.clock` is authoritative (those are unambiguous and rarely left
//! to default); everything else falls to name heuristics grounded in the real
//! Cyclops Analog and STM32N6 net-naming conventions. The default `.signal`
//! signal-type is deliberately *not* treated as authoritative — that would
//! shadow the RF name match for any port that simply didn't set a type.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const types = @import("types.zig");

const DesignBlock = env_mod.DesignBlock;
const ClassId = types.ClassId;
const ClassDef = types.ClassDef;
const Allocator = std.mem.Allocator;

pub const PortClassMap = std.StringHashMapUnmanaged(ClassId);

/// Build the per-design class registry: the built-in classes followed by any
/// novel `(class <key>)` declared on a section port. A declared key that isn't
/// a built-in gets a fresh id and a cycled accent color — that is how a
/// brand-new circuit gets its own view with no code change. Caller owns the
/// returned slice (freed by `Graph.deinit`).
pub fn buildRegistry(allocator: Allocator, block: *const DesignBlock) Allocator.Error![]ClassDef {
    var list: std.ArrayList(ClassDef) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &types.builtin_classes);
    var discovered: usize = 0;
    for (block.sections) |sec| {
        for (sec.ports) |p| {
            if (p.class.len == 0) continue;
            if (types.findClass(list.items, p.class) != null) continue;
            const color = types.discovered_palette[discovered % types.discovered_palette.len];
            discovered += 1;
            try list.append(allocator, .{ .key = p.class, .label = p.class, .color = color });
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Index the authoritative section ports by net name → `ClassId`. An explicit
/// `(class <key>)` wins (resolved against `classes`, built-in or declared);
/// otherwise a `.power`/`.clock` `signal_type` maps to its built-in class (the
/// other signal types stay heuristic — see the module note on `.signal`).
pub fn buildPortClassMap(allocator: Allocator, block: *const DesignBlock, classes: []const ClassDef) Allocator.Error!PortClassMap {
    var m: PortClassMap = .empty;
    errdefer m.deinit(allocator);
    for (block.sections) |sec| {
        for (sec.ports) |p| {
            const cls: ?ClassId = if (p.class.len > 0)
                types.findClass(classes, p.class)
            else switch (p.signal_type) {
                .power => types.class_power,
                .clock => types.class_clock,
                else => null,
            };
            if (cls) |c| {
                const gop = try m.getOrPut(allocator, p.name);
                if (!gop.found_existing) gop.value_ptr.* = c;
            }
        }
    }
    return m;
}

/// Classify a net by name, consulting the authoritative port map first. The
/// heuristics only ever yield built-in classes; a designer-declared class
/// reaches an edge solely through an explicit port `(class …)` in the map.
pub fn netClass(name: []const u8, port_map: *const PortClassMap) ClassId {
    if (port_map.get(name)) |c| return c;
    if (isGround(name)) return types.class_ground;
    if (isPowerRail(name)) return types.class_power;
    // An enable strobe is a control GPIO no matter which subsystem it gates,
    // so it must win over the clock substring match: TCXO_EN gates the TCXO
    // but is driven by the PCAL6534 expander, not a clock copy.
    if (isEnable(name)) return types.class_control;
    if (isClock(name)) return types.class_clock;
    if (isControl(name)) return types.class_control;
    if (isRf(name)) return types.class_rf;
    return types.class_control; // keep otherwise-unknown digital nets visible somewhere
}

// Pattern tables (case-sensitive — net names are uppercase by convention).
// Kept as data + small loops so each predicate stays a short boolean
// expression instead of a long `or` chain.

const ground_eq = [_][]const u8{ "GND", "AGND", "DGND", "PGND" };
const ground_suf = [_][]const u8{ "_GND", "GND" };
// Named/derived grounds keep their `GND` stem as a prefix: an isolated barrier
// ground (`GND_ISO`), a digital/analog split (`GND_A`). Treated as ground so it
// stays a shared reference rather than a spurious control edge. `VSS`/`VSSA` is
// the 0 V reference in CMOS naming (not a rail), so it belongs here — otherwise a
// VSS-named design gets a spurious dense power-edge fan the ground reference class
// exists to suppress.
const ground_pre = [_][]const u8{ "GND_", "AGND_", "DGND_", "PGND_", "VSS" };

const power_pre = [_][]const u8{ "VDD", "VCC", "AVDD", "DVDD", "VBAT", "VREG", "VPOS", "VBUS", "VLX", "V_" };

const clock_pre = [_][]const u8{ "REF_", "OSC" };
const clock_sub = [_][]const u8{ "_REF_", "REFIN", "RADAR_REF", "_OSC", "MHZ", "TCXO", "XTAL", "SWCLK" };
const clock_suf = [_][]const u8{ "_CLK", "CLK" };

const control_pre = [_][]const u8{ "I2C_", "CS_", "MRST", "MADV", "LD_", "BOOT", "NRST", "PSHOLD" };
const control_sub = [_][]const u8{ "_SPI_", "_EN_", "TXEN", "_FAULT", "MUXOUT", "SYNC" };
const control_suf = [_][]const u8{ "_EN", "ADV", "RST" };
const control_eq = [_][]const u8{ "CHIRP_START", "CNV_MASTER" };

// Enable strobes: a dedicated suffix table so enable-ness can outrank a clock
// substring match (TCXO_EN, PLL_EN, …) without reordering the whole control
// category. `_EN` also lives in control_suf for the post-clock control pass.
const enable_suf = [_][]const u8{"_EN"};

const rf_pre = [_][]const u8{ "LO_", "BEAM", "ADF_CH", "TX1_", "TX2_", "LF" };
const rf_sub = [_][]const u8{ "RFIN", "RFOUT", "LNAOUT", "_LO_", "LO_OUT", "CPOUT", "EMVS", "VTUNE", "VARAC", "_RF", "_LF" };

fn isGround(n: []const u8) bool {
    return anyEq(n, &ground_eq) or anySuffix(n, &ground_suf) or anyPrefix(n, &ground_pre);
}

/// A net is a supply rail when its name reads like one. Structural so it
/// catches V5P0 / V1P8_RF / V_RF_3P3 without swallowing analog control
/// voltages like VTUNE (which start with 'V' but aren't rails).
fn isPowerRail(n: []const u8) bool {
    return anyPrefix(n, &power_pre) or startsVDigit(n);
}

fn isClock(n: []const u8) bool {
    return anyPrefix(n, &clock_pre) or anyContains(n, &clock_sub) or
        anySuffix(n, &clock_suf) or anyEq(n, &[_][]const u8{ "HSE", "LSE" });
}

fn isControl(n: []const u8) bool {
    return anyPrefix(n, &control_pre) or anyContains(n, &control_sub) or
        anySuffix(n, &control_suf) or anyEq(n, &control_eq);
}

/// An enable strobe (`*_EN`). Checked ahead of the clock heuristic so a net
/// named for the clock it gates (TCXO_EN) classifies as control, not clock.
fn isEnable(n: []const u8) bool {
    return anySuffix(n, &enable_suf);
}

fn isRf(n: []const u8) bool {
    return anyPrefix(n, &rf_pre) or anyContains(n, &rf_sub);
}

// ── pattern-table matchers ──────────────────────────────────────────────

fn anyEq(n: []const u8, names: []const []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}
fn anyPrefix(n: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, n, p)) return true;
    return false;
}
fn anySuffix(n: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |s| if (std.mem.endsWith(u8, n, s)) return true;
    return false;
}
fn anyContains(n: []const u8, subs: []const []const u8) bool {
    for (subs) |s| if (std.mem.indexOf(u8, n, s) != null) return true;
    return false;
}
/// `V` followed by a digit — V5P0, V1P8_RF, V3P3.
fn startsVDigit(n: []const u8) bool {
    return n.len >= 2 and n[0] == 'V' and n[1] >= '0' and n[1] <= '9';
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn emptyBlock(name: []const u8) DesignBlock {
    return .{ .name = name, .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
}

// spec: diagram/classify - Classifies power, ground, clock, control, and RF nets by name
test "netClass classifies real Cyclops net names" {
    var pm: PortClassMap = .empty;
    defer pm.deinit(testing.allocator);
    try testing.expectEqual(types.class_power, netClass("V_RF_3P3", &pm));
    try testing.expectEqual(types.class_power, netClass("VBATT", &pm));
    try testing.expectEqual(types.class_ground, netClass("GND", &pm));
    try testing.expectEqual(types.class_clock, netClass("REF_4159_1_AC", &pm));
    try testing.expectEqual(types.class_control, netClass("CS_ADF4159_1", &pm));
    try testing.expectEqual(types.class_control, netClass("RF_SPI_SCK", &pm));
    // Enable strobes are expander GPIO (control), even when named for the
    // clock/PLL they gate — TCXO_EN must not land in the clocks view.
    try testing.expectEqual(types.class_control, netClass("TCXO_EN", &pm));
    try testing.expectEqual(types.class_control, netClass("PLL_EN", &pm));
    try testing.expectEqual(types.class_clock, netClass("RADAR_REF_TCXO", &pm));
    try testing.expectEqual(types.class_rf, netClass("CPOUT_1", &pm));
    try testing.expectEqual(types.class_rf, netClass("BEAM1_RFIN", &pm));
    try testing.expectEqual(types.class_rf, netClass("ADF_CH1P", &pm));
    // Named/isolated grounds are recognized so they stay a shared reference
    // instead of leaking into the control view as spurious edges.
    try testing.expectEqual(types.class_ground, netClass("GND_ISO", &pm));
    // VSS/VSSA is the CMOS 0 V reference (ground), not a power rail — else it
    // fans a spurious dense power edge the ground reference class exists to hide.
    try testing.expectEqual(types.class_ground, netClass("VSS", &pm));
    try testing.expectEqual(types.class_ground, netClass("VSSA", &pm));
    try testing.expectEqual(types.class_ground, netClass("VSS_1", &pm));
    // A real supply rail is still power.
    try testing.expectEqual(types.class_power, netClass("VDD", &pm));
}

// spec: diagram/classify - Honors an explicit section-port signal type over the name heuristic
test "buildPortClassMap overrides the name heuristic" {
    const ports = [_]env_mod.SectionPort{.{ .name = "VSPECIAL", .direction = .in, .signal_type = .power }};
    const secs = [_]env_mod.Section{.{ .name = "X", .ports = &ports }};
    var block = emptyBlock("d");
    block.sections = &secs;
    var pm = try buildPortClassMap(testing.allocator, &block, &types.builtin_classes);
    defer pm.deinit(testing.allocator);
    // With the authoritative port, VSPECIAL is power; without it the name
    // heuristic finds no rail pattern and falls back to control.
    try testing.expectEqual(types.class_power, netClass("VSPECIAL", &pm));
    var empty: PortClassMap = .empty;
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(types.class_control, netClass("VSPECIAL", &empty));
}

// spec: diagram/classify - An explicit port (class …) overrides signal-type and name heuristics
test "explicit port class wins over signal type and name" {
    // CLK_AUX reads like a clock by name, but the port declares (class control).
    const ports = [_]env_mod.SectionPort{.{
        .name = "CLK_AUX",
        .direction = .out,
        .signal_type = .clock,
        .class = "control",
    }};
    const secs = [_]env_mod.Section{.{ .name = "X", .ports = &ports }};
    var block = emptyBlock("d");
    block.sections = &secs;
    var pm = try buildPortClassMap(testing.allocator, &block, &types.builtin_classes);
    defer pm.deinit(testing.allocator);
    try testing.expectEqual(types.class_control, netClass("CLK_AUX", &pm));
    // An unrecognized class key isn't a built-in, so the name heuristic applies.
    try testing.expectEqual(@as(?types.ClassId, null), types.findClass(&types.builtin_classes, "audio"));
}

// spec: diagram/classify - A declared (class …) key extends the registry with a new class
test "buildRegistry appends a designer-declared class" {
    const ports = [_]env_mod.SectionPort{.{ .name = "MIC_OUT", .direction = .out, .class = "audio" }};
    const secs = [_]env_mod.Section{.{ .name = "Mic", .ports = &ports }};
    var block = emptyBlock("d");
    block.sections = &secs;
    const reg = try buildRegistry(testing.allocator, &block);
    defer testing.allocator.free(reg);
    // Built-ins are preserved and the novel "audio" key is appended with an id.
    try testing.expectEqual(types.builtin_classes.len + 1, reg.len);
    const aid = types.findClass(reg, "audio") orelse return error.TestUnexpectedResult;
    try testing.expect(aid >= types.builtin_classes.len);
    // And a port declaring it maps its net to that new class.
    var pm = try buildPortClassMap(testing.allocator, &block, reg);
    defer pm.deinit(testing.allocator);
    try testing.expectEqual(aid, netClass("MIC_OUT", &pm));
}
