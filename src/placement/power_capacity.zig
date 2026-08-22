//! Cycle-free continuous-current capacity relations shared by routing, poured
//! copper generation, DRC and the post-route power-integrity report.
//!
//! This is an IPC-2221 10 C-rise SCREEN. It deliberately has no route geometry
//! dependency: callers supply copper thickness / via plating and decide whether
//! a conservative whole-rail envelope or a solved local branch current applies.

const std = @import("std");
const power_budget = @import("../eval/power_budget.zig");
const net_names = @import("../net_name.zig");

pub const temperature_rise_c: f64 = 10.0;
const mm_per_mil: f64 = 0.0254;
const outer_k: f64 = 0.048;
const inner_k: f64 = 0.024;

fn positiveFinite(value: f64) bool {
    return value > 0 and std.math.isFinite(value);
}

/// Continuous-current capacity for a copper cross-section. `area_mm2` is the
/// section perpendicular to current flow, not board-plan copper area.
pub fn capacityForArea(area_mm2: f64, outer: bool, rise_c: f64) f64 {
    if (!positiveFinite(area_mm2) or !positiveFinite(rise_c)) return 0;
    const area_mil2 = area_mm2 / (mm_per_mil * mm_per_mil);
    const k = if (outer) outer_k else inner_k;
    return k * std.math.pow(f64, rise_c, 0.44) * std.math.pow(f64, area_mil2, 0.725);
}

/// Continuous-current capacity of a trace at the shared 10 C-rise target.
pub fn traceCapacityA(width_mm: f64, foil_mm: f64, outer: bool) f64 {
    return capacityForArea(width_mm * foil_mm, outer, temperature_rise_c);
}

/// Trace / plane-neck width needed to carry `amps` at the shared target.
pub fn requiredTraceWidthMm(amps: f64, foil_mm: f64, outer: bool) ?f64 {
    if (!positiveFinite(amps) or !positiveFinite(foil_mm)) return null;
    const k = if (outer) outer_k else inner_k;
    const area_mil2 = std.math.pow(f64, amps / (k * std.math.pow(f64, temperature_rise_c, 0.44)), 1.0 / 0.725);
    return area_mil2 * mm_per_mil * mm_per_mil / foil_mm;
}

/// Capacity of one finished plated through-hole barrel. IPC-2221's inner-
/// conductor coefficient is used because the barrel is embedded in the board.
pub fn viaCapacityA(drill_mm: f64, plating_mm: f64) f64 {
    return capacityForArea(std.math.pi * drill_mm * plating_mm, false, temperature_rise_c);
}

/// Drill diameter needed for one plated barrel to carry `amps`. The router
/// may elect to use several smaller barrels instead; this is the safe one-via
/// fallback used until a connected via-array placement succeeds.
pub fn requiredViaDrillMm(amps: f64, plating_mm: f64) ?f64 {
    if (!positiveFinite(amps) or !positiveFinite(plating_mm)) return null;
    const k = inner_k;
    const area_mil2 = std.math.pow(f64, amps / (k * std.math.pow(f64, temperature_rise_c, 0.44)), 1.0 / 0.725);
    const area_mm2 = area_mil2 * mm_per_mil * mm_per_mil;
    return area_mm2 / (std.math.pi * plating_mm);
}

fn sameRail(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b) or std.ascii.eqlIgnoreCase(net_names.leaf(a), net_names.leaf(b));
}

/// Conservative current envelope available before topology exists. Prefer an
/// authored maximum; when only typical current is known, at least route for it
/// rather than silently treating the rail as zero-current. Ambiguous leaf-name
/// matches return null.
pub fn routingCurrentA(rails: []const power_budget.Rail, net: []const u8) ?f64 {
    var found: ?power_budget.Rail = null;
    for (rails) |rail| {
        if (!sameRail(rail.net, net)) continue;
        if (found) |prior| {
            if (!std.ascii.eqlIgnoreCase(prior.net, rail.net)) return null;
        } else found = rail;
    }
    const rail = found orelse return null;
    const current = if (rail.any_max_load)
        rail.load_max_a
    else if (rail.any_typ_load)
        rail.load_typ_a
    else
        return null;
    return if (current > 0 and std.math.isFinite(current)) current else null;
}

test "capacity round trips trace width and plated-barrel drill" {
    const width = requiredTraceWidthMm(0.34, 0.035, false).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.34), traceCapacityA(width, 0.035, false), 1e-12);
    const drill = requiredViaDrillMm(0.34, 0.020).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.34), viaCapacityA(drill, 0.020), 1e-12);
    try std.testing.expectEqual(@as(f64, 0), capacityForArea(std.math.inf(f64), false, temperature_rise_c));
    try std.testing.expectEqual(@as(?f64, null), requiredTraceWidthMm(std.math.inf(f64), 0.035, false));
}

// spec: placement/power-routing - a maximum load is the pre-route envelope, with typical used only when no maximum was authored
test "routing current prefers maximum and refuses ambiguous leaf rails" {
    const rails = [_]power_budget.Rail{
        .{ .net = "radio/VDD", .load_typ_a = 0.2, .load_max_a = 0.34, .any_typ_load = true, .any_max_load = true, .status = .no_source },
    };
    try std.testing.expectEqual(@as(?f64, 0.34), routingCurrentA(&rails, "VDD"));
    const ambiguous = [_]power_budget.Rail{
        rails[0],
        .{ .net = "logic/VDD", .load_typ_a = 0.1, .any_typ_load = true, .status = .no_source },
    };
    try std.testing.expectEqual(@as(?f64, null), routingCurrentA(&ambiguous, "VDD"));
}
