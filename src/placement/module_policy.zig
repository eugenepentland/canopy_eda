//! Module-level layout-policy *detection* — Phase 0 of the module-placement
//! ruleset. Given a flattened, solved `Placement`, this reads the netlist
//! topology and leaf names and infers three things, changing no placement:
//!
//!   • a `NetClass` for every net — the routing-criticality taxonomy the
//!     ruleset orders by (ground / power / input-rail / switch-node / clock /
//!     rf / feedback / control / signal). The input-rail and switch-node
//!     distinctions mirror what the optimizer's hot-loop scoring already
//!     leans on (`isInputRailName`), lifted out so they can be reported.
//!   • a `PartRole` for every part — anchor IC, input / decoupling / bulk cap,
//!     feedback divider, RF matching element.
//!   • a `ModuleClass` per hub IC — buck / ldo / mcu / rf-amp / generic.
//!
//! This is deliberately separate from `diagram/classify.zig`: that module
//! colours *schematic* edges from section ports; this one works on the
//! *flattened* netlist (leaf names + which parts share a net) and adds the
//! layout-only switch-node / input-rail / feedback splits. The layout linter
//! (`layout_lint.zig`) keys its gates on the output here, and `pcb_describe`
//! surfaces it as facts so an agent can see how the board was read before
//! trusting the lint. Detection is best-effort and heuristic — the value is
//! observability; later phases let the design author override it.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const pin_roles = @import("pin_roles.zig");

const Allocator = std.mem.Allocator;
const Part = optimizer.Part;
const Placement = optimizer.Placement;

/// Routing-criticality class of a net, most-to-least sensitive. `input_rail`
/// and `switch_node` are the switching converter's high-dI/dt and high-dV/dt
/// aggressors; `feedback` is the high-impedance victim. Used by the linter and
/// (later) the router's net ordering.
pub const NetClass = enum {
    ground,
    power,
    input_rail,
    switch_node,
    clock,
    rf,
    feedback,
    analog,
    control,
    signal,
};

/// The kind of subsystem a hub IC anchors, inferred from the parts and rails
/// around it. Drives the per-module placement/order policy in later phases;
/// here it is reported as a fact. `generic` = couldn't tell.
pub const ModuleClass = enum { buck, ldo, mcu, rf_amp, analog_afe, generic };

/// A part's electrical role relative to its module. Only the roles we can infer
/// with reasonable confidence from the flattened netlist are modelled — the
/// honest set, not an aspirational one.
pub const PartRole = enum {
    anchor_ic,
    input_cap,
    decoupling_cap,
    bulk_cap,
    feedback_divider,
    matching_element,
    other,
};

/// One detected module: the hub part index, its class, and whether a power
/// inductor sits on one of its nets (the buck/boost tell).
pub const ModuleInfo = struct { hub: usize, class: ModuleClass, has_inductor: bool };

/// The full detection result. `net_class` is index-aligned with `Placement.nets`,
/// `part_role` with `Placement.parts`. Owns three heap slices — free with
/// `deinit`.
pub const ModulePolicy = struct {
    net_class: []NetClass,
    part_role: []PartRole,
    modules: []ModuleInfo,

    pub fn deinit(self: *ModulePolicy, alloc: Allocator) void {
        alloc.free(self.net_class);
        alloc.free(self.part_role);
        alloc.free(self.modules);
    }
};

/// A bulk cap is anything ≥ 4.7 µF — the rail-entry reservoir, not the
/// high-frequency bypass cap that hugs the pin.
const BULK_FARADS: f64 = 4.7e-6;

/// Analyse a solved placement. Allocates the three result slices on `alloc`
/// (caller frees via `ModulePolicy.deinit`); scratch maps are freed internally.
pub fn analyze(alloc: Allocator, p: Placement) Allocator.Error!ModulePolicy {
    const net_class = try alloc.alloc(NetClass, p.nets.len);
    errdefer alloc.free(net_class);
    const part_role = try alloc.alloc(PartRole, p.parts.len);
    errdefer alloc.free(part_role);

    var idx = std.StringHashMap(usize).init(alloc);
    defer idx.deinit();
    for (p.parts, 0..) |part, i| try idx.put(part.ref_des, i);

    classifyNets(p, &idx, net_class);

    // Per-part set of the net classes touching its pads — the basis for roles.
    const flags = try alloc.alloc(std.EnumSet(NetClass), p.parts.len);
    defer alloc.free(flags);
    for (flags) |*f| f.* = std.EnumSet(NetClass).initEmpty();
    for (p.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            if (idx.get(pin.ref_des)) |pi| flags[pi].insert(net_class[ni]);
        }
    }

    for (p.parts, 0..) |part, i| {
        part_role[i] = if (part.kind == .hub) .anchor_ic else roleOfPassive(part, flags[i]);
    }

    const modules = try detectModules(alloc, p, net_class);
    return .{ .net_class = net_class, .part_role = part_role, .modules = modules };
}

/// Only the criticality-bearing net classes are worth surfacing or pinning —
/// ground, power, control, and plain signal are the bulk of nets and add noise.
/// Shared by the describe facts and the `(module-policy …)` export.
pub fn isInterestingClass(c: NetClass) bool {
    return switch (c) {
        .input_rail, .switch_node, .clock, .rf, .feedback, .analog => true,
        .ground, .power, .control, .signal => false,
    };
}

/// Fill `out` with a `NetClass` per net: the leaf-name class, upgraded to
/// `switch_node` for an otherwise-plain net that bridges a hub and an inductor
/// (the SW/LX node, however it's named).
fn classifyNets(p: Placement, idx: *std.StringHashMap(usize), out: []NetClass) void {
    for (p.nets, 0..) |net, i| {
        var touch_hub = false;
        var touch_ind = false;
        for (net.pins) |pin| {
            const pi = idx.get(pin.ref_des) orelse continue;
            if (p.parts[pi].kind == .hub) touch_hub = true;
            if (isInductor(pin.ref_des)) touch_ind = true;
        }
        out[i] = classifyNetName(net.name);
        if ((out[i] == .signal or out[i] == .control) and touch_hub and touch_ind) out[i] = .switch_node;
    }
}

/// Classify a net by its leaf name alone (the structural switch-node upgrade
/// happens in `classifyNets`). Precedence runs most-specific first so a rail
/// that's both a power name and an input name (VBAT, V_12V) reads as input.
pub fn classifyNetName(name: []const u8) NetClass {
    const lf = leafName(name);
    if (pin_roles.isGroundFn(lf)) return .ground;
    if (isInputRail(lf)) return .input_rail;
    if (isSwitchNode(lf)) return .switch_node;
    if (isFeedback(lf)) return .feedback;
    if (isClock(lf)) return .clock;
    if (isRf(lf)) return .rf;
    if (isPowerRail(lf)) return .power;
    return .signal;
}

/// A passive's role from the net classes on its pads. Caps key on their most
/// critical rail; resistors/inductors on feedback/RF membership.
fn roleOfPassive(part: Part, fl: std.EnumSet(NetClass)) PartRole {
    const lf = leafName(part.ref_des);
    const pfx: u8 = if (lf.len > 0) std.ascii.toUpper(lf[0]) else 0;
    return switch (pfx) {
        'C' => capRole(part, fl),
        'R' => if (fl.contains(.feedback)) .feedback_divider else if (fl.contains(.rf)) .matching_element else .other,
        'L' => if (fl.contains(.rf)) .matching_element else .other,
        else => .other,
    };
}

fn capRole(part: Part, fl: std.EnumSet(NetClass)) PartRole {
    if (fl.contains(.input_rail)) return .input_cap;
    if (fl.contains(.rf)) return .matching_element;
    if (fl.contains(.feedback)) return .feedback_divider;
    if (fl.contains(.power)) {
        return if (capValueFarads(part.value) >= BULK_FARADS) .bulk_cap else .decoupling_cap;
    }
    return .other;
}

/// One `ModuleInfo` per hub. For each hub we collect the classes of the nets it
/// touches and whether a local inductor shares one, then classify.
fn detectModules(alloc: Allocator, p: Placement, net_class: []const NetClass) Allocator.Error![]ModuleInfo {
    var list: std.ArrayListUnmanaged(ModuleInfo) = .empty;
    errdefer list.deinit(alloc);
    for (p.parts, 0..) |part, hi| {
        if (part.kind != .hub) continue;
        var cl = std.EnumSet(NetClass).initEmpty();
        var has_ind = false;
        for (p.nets, 0..) |net, ni| {
            var hub_on = false;
            var ind_on = false;
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, part.ref_des)) hub_on = true;
                if (isInductor(pin.ref_des)) ind_on = true;
            }
            if (!hub_on) continue;
            cl.insert(net_class[ni]);
            if (ind_on) has_ind = true;
        }
        try list.append(alloc, .{ .hub = hi, .class = classifyModule(part, cl, has_ind), .has_inductor = has_ind });
    }
    return list.toOwnedSlice(alloc);
}

fn classifyModule(hub: Part, cl: std.EnumSet(NetClass), has_ind: bool) ModuleClass {
    const pads = hub.pads.len;
    if (has_ind and (cl.contains(.input_rail) or cl.contains(.switch_node))) return .buck;
    if (cl.contains(.rf)) return .rf_amp;
    if (pads >= 24 or (cl.contains(.clock) and pads >= 16)) return .mcu;
    if (cl.contains(.input_rail) and cl.contains(.power) and pads <= 16) return .ldo;
    return .generic;
}

// ── Name predicates ─────────────────────────────────────────────────────────
// Each takes a leaf name and normalizes the way it needs: `stripUpper` removes
// separators (VIN-style structural tokens, raw-voltage parsing); `upperKeep`
// preserves them (prefix tables like V_). Tuned for *layout* criticality, kept
// local rather than shared with diagram/classify.zig (different concern).

/// A switching converter's input rail: the high-dI/dt side whose loop dominates
/// EMI. Common input names plus any raw rail ≥ 7 V (a buck's input). Mirrors
/// the optimizer's `isInputRailName`.
fn isInputRail(lf: []const u8) bool {
    var buf: [48]u8 = undefined;
    const s = stripUpper(&buf, lf);
    if (anyPrefix(s, &.{ "VIN", "PVIN", "VBUS", "VBAT", "VSYS", "VDCIN", "HVIN" })) return true;
    var t = s;
    if (t.len > 0 and t[0] == 'V') t = t[1..];
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i == 0) return false;
    const volts = std.fmt.parseInt(u32, t[0..i], 10) catch return false;
    return volts >= 7;
}

/// The switching node (SW/LX/PHASE): `SW`/`LX` alone or with a digit index, or
/// the named variants. `SWCLK`/`SWDIO` are excluded — the remainder must be
/// empty or all digits.
fn isSwitchNode(lf: []const u8) bool {
    var buf: [48]u8 = undefined;
    const s = stripUpper(&buf, lf);
    if (anyEq(s, &.{ "PHASE", "VSW", "VLX", "VSWITCH" })) return true;
    for ([_][]const u8{ "SW", "LX" }) |stem| {
        if (!std.mem.startsWith(u8, s, stem)) continue;
        const rest = s[stem.len..];
        if (rest.len == 0) return true;
        if (allDigits(rest)) return true;
    }
    return false;
}

/// A feedback / compensation node (FB/VFB/COMP/ITH/FEEDBACK).
fn isFeedback(lf: []const u8) bool {
    var buf: [48]u8 = undefined;
    const s = stripUpper(&buf, lf);
    if (anyEq(s, &.{ "FB", "COMP", "ITH", "VFB" })) return true;
    if (std.mem.indexOf(u8, s, "FEEDBACK") != null) return true;
    if (std.mem.startsWith(u8, s, "VFB")) return true;
    if (std.mem.startsWith(u8, s, "FB") and allDigits(s[2..])) return true;
    return false;
}

fn isClock(lf: []const u8) bool {
    var buf: [48]u8 = undefined;
    const s = upperKeep(&buf, lf);
    if (anyPrefix(s, &.{ "REF_", "OSC" })) return true;
    if (anyContains(s, &.{ "XTAL", "TCXO", "MHZ", "_OSC", "XIN", "XOUT", "SWCLK" })) return true;
    if (anySuffix(s, &.{ "_CLK", "CLK" })) return true;
    return anyEq(s, &.{ "HSE", "LSE", "XIN", "XOUT" });
}

fn isRf(lf: []const u8) bool {
    var buf: [48]u8 = undefined;
    const s = upperKeep(&buf, lf);
    if (anyPrefix(s, &.{ "LO_", "RFIN", "RFOUT" })) return true;
    return anyContains(s, &.{ "RFIN", "RFOUT", "LNAOUT", "_LO_", "_RF", "EMVS", "VTUNE", "VARAC" });
}

fn isPowerRail(lf: []const u8) bool {
    var buf: [48]u8 = undefined;
    const s = upperKeep(&buf, lf);
    if (anyPrefix(s, &.{ "VDD", "VCC", "AVDD", "DVDD", "VREG", "VPOS", "VOUT", "VEXT", "VANA", "VREF", "VPP", "V_" })) return true;
    return s.len >= 2 and s[0] == 'V' and std.ascii.isDigit(s[1]);
}

// ── Small helpers ────────────────────────────────────────────────────────────

fn isInductor(ref: []const u8) bool {
    const s = leafName(ref);
    return s.len > 0 and (s[0] == 'L' or s[0] == 'l');
}

/// Last `parent/child` segment of a ref-des or net name.
fn leafName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// Parse a capacitance string ("100nF", "4.7uF") to farads; 0 if unrecognised.
fn capValueFarads(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
    if (i == 0) return 0;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return 0;
    if (i >= s.len) return 0;
    const mult: f64 = switch (s[i]) {
        'p', 'P' => 1e-12,
        'n', 'N' => 1e-9,
        'u', 'U' => 1e-6,
        'm' => 1e-3,
        else => return 0,
    };
    return num * mult;
}

/// Uppercase `s` into `buf`, dropping separators. Truncates past `buf`.
fn stripUpper(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| switch (c) {
        '_', '-', '/', '.', ' ', '#' => {},
        else => {
            if (n >= buf.len) break;
            buf[n] = std.ascii.toUpper(c);
            n += 1;
        },
    };
    return buf[0..n];
}

/// Uppercase `s` into `buf`, keeping separators. Truncates past `buf`.
fn upperKeep(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..n];
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn anyEq(s: []const u8, names: []const []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}
fn anyPrefix(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}
fn anySuffix(s: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |x| if (std.mem.endsWith(u8, s, x)) return true;
    return false;
}
fn anyContains(s: []const u8, subs: []const []const u8) bool {
    for (subs) |x| if (std.mem.indexOf(u8, s, x) != null) return true;
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const export_kicad = @import("../export_kicad.zig");
const geometry = @import("geometry.zig");

// spec: placement/module_policy - classifies ground, input-rail, switch-node and feedback nets by name
test "classifyNetName tags the criticality classes by leaf name" {
    try testing.expectEqual(NetClass.ground, classifyNetName("GND"));
    try testing.expectEqual(NetClass.ground, classifyNetName("pwr/AGND2"));
    try testing.expectEqual(NetClass.input_rail, classifyNetName("VIN"));
    try testing.expectEqual(NetClass.input_rail, classifyNetName("V_12V"));
    try testing.expectEqual(NetClass.input_rail, classifyNetName("VBATT"));
    try testing.expectEqual(NetClass.switch_node, classifyNetName("SW"));
    try testing.expectEqual(NetClass.switch_node, classifyNetName("buck/LX1"));
    try testing.expectEqual(NetClass.feedback, classifyNetName("FB"));
    try testing.expectEqual(NetClass.feedback, classifyNetName("VFB_3V3"));
    try testing.expectEqual(NetClass.clock, classifyNetName("SWCLK"));
    try testing.expectEqual(NetClass.rf, classifyNetName("LNAOUT"));
    try testing.expectEqual(NetClass.power, classifyNetName("V3P3"));
    try testing.expectEqual(NetClass.power, classifyNetName("VOUT"));
    // A 3V3 output rail is power, never an input — only ≥7V raw rails are inputs.
    try testing.expectEqual(NetClass.power, classifyNetName("V5P0"));
    // SWCLK/SWDIO must not be read as the switching node.
    try testing.expect(classifyNetName("SWDIO") != NetClass.switch_node);
}

// spec: placement/module_policy - infers a buck module from an inductor on the input rail and tags the input cap
test "analyze detects a buck module and its input cap" {
    const pad = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 };
    var hub_pads = [_]geometry.Pad{pad};
    var l_pads = [_]geometry.Pad{pad};
    var c_pads = [_]geometry.Pad{pad};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 1, .hh = 1, .pads = &l_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &c_pads, .fallback = false, .value = "10uF" },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &c_pads, .fallback = false, .value = "22uF" },
    };
    const vin = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const sw = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "L1", .pin = "1" } };
    const vout = [_]export_kicad.FlatPin{ .{ .ref_des = "L1", .pin = "2" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VIN", .pins = &vin },
        .{ .name = "SW", .pins = &sw },
        .{ .name = "VOUT", .pins = &vout },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    var policy = try analyze(testing.allocator, p);
    defer policy.deinit(testing.allocator);

    try testing.expectEqual(NetClass.input_rail, policy.net_class[0]);
    try testing.expectEqual(NetClass.switch_node, policy.net_class[1]);
    try testing.expectEqual(NetClass.power, policy.net_class[2]);
    try testing.expectEqual(PartRole.anchor_ic, policy.part_role[0]);
    try testing.expectEqual(PartRole.input_cap, policy.part_role[2]); // C1 on VIN
    try testing.expectEqual(PartRole.bulk_cap, policy.part_role[3]); // C2 on VOUT, 22uF ≥ 4.7uF
    try testing.expectEqual(@as(usize, 1), policy.modules.len);
    try testing.expectEqual(ModuleClass.buck, policy.modules[0].class);
    try testing.expect(policy.modules[0].has_inductor);
}
