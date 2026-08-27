//! Context-sensitive RF land adaptation.
//!
//! A footprint owns the assembly contract: an SMD pad may declare the smallest
//! copper land qualified for that package with `(rf-min-size W H)`. A design's
//! net classes own the electrical context. Once a footprint instance touches a
//! single-ended or differential controlled-impedance net, this pass clones that
//! instance's pads and reduces every eligible land to its declared RF minimum.
//! Reducing the whole annotated two-terminal footprint keeps solder lands
//! symmetric (and therefore avoids creating a tombstoning bias) even for a
//! shunt part whose second terminal is ground.
//!
//! No declaration means no change. Through-hole and custom polygon pads are
//! never resized, and an RF minimum can only shrink nominal copper, never grow
//! it. Pad centres, paste/mask behavior, shapes, and courtyards remain fixed.

const std = @import("std");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const net_rules = @import("net_rules.zig");

/// Apply declared RF minima to `parts`. `parts` is generic deliberately: the
/// production caller supplies `[]optimizer.Part` without making this focused
/// geometry pass import the optimizer back and form a cycle; tests use the
/// smaller `TestPart` below. Every element must expose `ref_des` and `pads`.
pub fn apply(
    arena: std.mem.Allocator,
    parts: anytype,
    nets: []const flat_netlist.FlatNet,
    rules: []const net_rules.NetRule,
) std.mem.Allocator.Error!void {
    if (parts.len == 0 or rules.len != nets.len) return;

    for (parts) |*part| {
        if (!touchesControlledImpedance(part.ref_des, nets, rules)) continue;

        var eligible = false;
        for (part.pads) |pad| {
            if (canAdapt(pad)) {
                eligible = true;
                break;
            }
        }
        if (!eligible) continue;

        const adapted = try arena.dupe(geometry.Pad, part.pads);
        var changed: usize = 0;
        for (adapted) |*pad| {
            if (!canAdapt(pad.*)) continue;
            const w = @min(pad.w, pad.overrides.rf_min_size[0]);
            const h = @min(pad.h, pad.overrides.rf_min_size[1]);
            if (w >= pad.w and h >= pad.h) continue;
            pad.w = w;
            pad.h = h;
            changed += 1;
        }
        if (changed == 0) continue;
        part.pads = adapted;
    }
}

fn canAdapt(pad: geometry.Pad) bool {
    return !pad.thru and !pad.npth and pad.poly.len == 0 and
        pad.overrides.rf_min_size[0] > 0 and pad.overrides.rf_min_size[1] > 0;
}

fn touchesControlledImpedance(
    ref_des: []const u8,
    nets: []const flat_netlist.FlatNet,
    rules: []const net_rules.NetRule,
) bool {
    for (nets, rules) |net, rule| {
        if (!(rule.rf.impedance.ohms > 0) and !(rule.rf.impedance.diff_ohms > 0)) continue;
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, ref_des)) return true;
        }
    }
    return false;
}

const TestPart = struct {
    ref_des: []const u8,
    pads: []const geometry.Pad,
};

fn testRule(ohms: f64, diff_ohms: f64) net_rules.NetRule {
    var rule: net_rules.NetRule = .{};
    rule.rf.impedance.ohms = ohms;
    rule.rf.impedance.diff_ohms = diff_ohms;
    return rule;
}

test "controlled impedance shrinks all qualified pads on the touched instance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.48, .y = 0, .w = 0.56, .h = 0.62, .overrides = .{ .rf_min_size = .{ 0.45, 0.50 } } },
        .{ .number = "2", .x = 0.48, .y = 0, .w = 0.56, .h = 0.62, .overrides = .{ .rf_min_size = .{ 0.45, 0.50 } } },
    };
    var parts = [_]TestPart{
        .{ .ref_des = "C_RF", .pads = &pads },
        .{ .ref_des = "C_DC", .pads = &pads },
    };
    const rf_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C_RF", .pin = "1" }};
    const dc_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C_DC", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &rf_pins },
        .{ .name = "DC", .pins = &dc_pins },
    };
    const rules = [_]net_rules.NetRule{ testRule(50, 0), .{} };

    try apply(arena, &parts, &nets, &rules);
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), parts[0].pads[0].w, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.50), parts[0].pads[0].h, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), parts[0].pads[1].w, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.56), parts[1].pads[0].w, 1e-9);
    // The shared library pad slice remains nominal; adaptation is per instance.
    try std.testing.expectApproxEqAbs(@as(f64, 0.56), pads[0].w, 1e-9);
}

test "adaptation honors eligibility and never grows copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const custom_poly = [_][2]f64{ .{ -0.2, -0.2 }, .{ 0.2, -0.2 }, .{ 0, 0.2 } };
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.40, .h = 0.45, .overrides = .{ .rf_min_size = .{ 0.45, 0.50 } } },
        .{ .number = "2", .x = 1, .y = 0, .w = 0.60, .h = 0.60 },
        .{ .number = "3", .x = 2, .y = 0, .w = 0.60, .h = 0.60, .thru = true, .overrides = .{ .rf_min_size = .{ 0.45, 0.50 } } },
        .{ .number = "4", .x = 3, .y = 0, .w = 0.60, .h = 0.60, .shape = "custom", .poly = &custom_poly, .overrides = .{ .rf_min_size = .{ 0.45, 0.50 } } },
    };
    var parts = [_]TestPart{.{ .ref_des = "U1", .pads = &pads }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "DP", .pins = &pins }};
    const rules = [_]net_rules.NetRule{testRule(0, 100)};

    try apply(arena, &parts, &nets, &rules);
    for (parts[0].pads, pads) |actual, nominal| {
        try std.testing.expectApproxEqAbs(nominal.w, actual.w, 1e-9);
        try std.testing.expectApproxEqAbs(nominal.h, actual.h, 1e-9);
    }
}
