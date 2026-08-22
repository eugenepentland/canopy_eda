//! First-order antipad synthesis for a single-ended controlled-impedance via.
//!
//! This is deliberately a small, auditable lumped-LC estimate rather than a
//! claim of 3D field-solver accuracy. It combines the empirical through-via
//! inductance and capacitance equations published in Intel AN 529:
//!
//!     L(nH) = 0.2 h_mm [1 + ln(4 h_mm / d_mm)]
//!     C(pF) = 0.0555 er h_mm Dpad_mm / (Danti_mm - Dpad_mm)
//!
//! with Z = sqrt(L/C), including the nH/pF unit factor. Solving for C and then
//! Danti gives a deterministic starting antipad from the actual via geometry
//! and board buildup. The result is floored at the ordinary copper-clearance
//! rule. Differential transitions are intentionally excluded by callers: a
//! coupled pair needs shared-antipad/return-via geometry and 3D EM analysis.

const std = @import("std");
const impedance = @import("impedance.zig");

const capacitance_factor_pf_per_mm: f64 = 0.0555;
const inductance_factor_nh_per_mm: f64 = 0.2;

/// The system impedance assumed for a `(max-freq …)` net whose class authored
/// no `(impedance OHMS)` target: 50 ohm, the near-universal single-ended RF
/// convention. Consumed by the plane-antipad path only — width synthesis and
/// the impedance report still require an authored target, so declaring a
/// frequency never silently resizes a trace.
pub const default_system_ohms: f64 = 50.0;

/// Synthesized circular antipad geometry and its lumped electrical estimate.
pub const Result = struct {
    estimated_ohms: f64,
    antipad_dia_mm: f64,
    length_mm: f64,
    er: f64,
    inductance_nh: f64,
    capacitance_pf: f64,
    clearance_limited: bool,
};

fn positive(v: f64) bool {
    return v > 0 and std.math.isFinite(v);
}

/// Finished through-via length represented by the stack. An authored finished
/// board thickness wins; otherwise sum the resolved foils and dielectric gaps.
fn boardThicknessMm(stack: impedance.Stack) ?f64 {
    if (stack.layers < 2) return null;
    if (positive(stack.board_mm)) return stack.board_mm;

    var total: f64 = 0;
    var layer: u8 = 1;
    while (layer <= stack.layers) : (layer += 1) total += stack.foilMm(layer);
    layer = 1;
    while (layer < stack.layers) : (layer += 1) total += stack.gapMm(layer);
    return if (positive(total)) total else null;
}

/// Thickness-weighted dielectric constant across the via barrel. Copper foil
/// is excluded from the weighting because it contributes no dielectric volume.
fn effectiveEr(stack: impedance.Stack) ?f64 {
    if (stack.layers < 2) return null;
    var thickness: f64 = 0;
    var weighted: f64 = 0;
    var layer: u8 = 1;
    while (layer < stack.layers) : (layer += 1) {
        const gap = stack.gapMm(layer);
        const er = stack.gapEr(layer);
        if (!positive(gap) or !positive(er)) return null;
        thickness += gap;
        weighted += gap * er;
    }
    if (!positive(thickness)) return null;
    const er = weighted / thickness;
    return if (positive(er)) er else null;
}

fn inductanceNh(length_mm: f64, drill_mm: f64) ?f64 {
    if (!positive(length_mm) or !positive(drill_mm)) return null;
    const arg = 4.0 * length_mm / drill_mm;
    if (!(arg > 1.0) or !std.math.isFinite(arg)) return null;
    const value = inductance_factor_nh_per_mm * length_mm * (1.0 + @log(arg));
    return if (positive(value)) value else null;
}

fn capacitancePf(length_mm: f64, er: f64, pad_dia_mm: f64, antipad_dia_mm: f64) ?f64 {
    if (!positive(length_mm)) return null;
    if (!positive(er)) return null;
    if (!positive(pad_dia_mm)) return null;
    const opening = antipad_dia_mm - pad_dia_mm;
    if (!positive(opening)) return null;
    const value = capacitance_factor_pf_per_mm * er * length_mm * pad_dia_mm / opening;
    return if (positive(value)) value else null;
}

fn estimatedOhms(inductance_nh: f64, capacitance_pf: f64) ?f64 {
    if (!positive(inductance_nh) or !positive(capacitance_pf)) return null;
    const value = @sqrt(1000.0 * inductance_nh / capacitance_pf);
    return if (positive(value)) value else null;
}

/// Solve a circular plane/pour antipad for a target single-ended impedance.
/// The returned diameter is never smaller than `pad + 2*min_clearance`.
pub fn solve(
    stack: impedance.Stack,
    target_ohms: f64,
    pad_dia_mm: f64,
    drill_mm: f64,
    min_clearance_mm: f64,
) ?Result {
    if (!positive(target_ohms)) return null;
    if (!positive(pad_dia_mm)) return null;
    if (!positive(drill_mm)) return null;
    if (min_clearance_mm < 0 or !std.math.isFinite(min_clearance_mm)) return null;
    const length = boardThicknessMm(stack) orelse return null;
    const er = effectiveEr(stack) orelse return null;
    const inductance = inductanceNh(length, drill_mm) orelse return null;
    const target_capacitance = 1000.0 * inductance / (target_ohms * target_ohms);
    if (!positive(target_capacitance)) return null;

    const raw_antipad = pad_dia_mm +
        capacitance_factor_pf_per_mm * er * length * pad_dia_mm / target_capacitance;
    const minimum_antipad = pad_dia_mm + 2.0 * min_clearance_mm;
    const clearance_limited = raw_antipad < minimum_antipad;
    const antipad = @max(raw_antipad, minimum_antipad);
    const capacitance = capacitancePf(length, er, pad_dia_mm, antipad) orelse return null;
    const estimated = estimatedOhms(inductance, capacitance) orelse return null;

    return .{
        .estimated_ohms = estimated,
        .antipad_dia_mm = antipad,
        .length_mm = length,
        .er = er,
        .inductance_nh = inductance,
        .capacitance_pf = capacitance,
        .clearance_limited = clearance_limited,
    };
}

const testing = std.testing;

// spec: placement/via-antipad - published via equations reproduce the Intel AN 529 example geometry
test "published via equations reproduce the Intel AN 529 example geometry" {
    const length = 1.5748; // 62 mil
    const pad = 0.4064; // 16 mil
    const drill = 0.1524; // 6 mil
    const antipad = 0.6096; // 24 mil
    const l = inductanceNh(length, drill).?;
    const c = capacitancePf(length, 4.3, pad, antipad).?;
    try testing.expectApproxEqAbs(@as(f64, 1.49), l, 0.02);
    try testing.expectApproxEqAbs(@as(f64, 0.75), c, 0.02);
    try testing.expectApproxEqAbs(@as(f64, 44.6), estimatedOhms(l, c).?, 0.5);
}

// spec: placement/via-antipad - Black Canyon through-via solves a 50 ohm antipad from its buildup
test "Black Canyon through-via solves a 50 ohm antipad from its buildup" {
    const dielectrics = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
        .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
    };
    const stack = impedance.Stack{ .layers = 4, .dielectrics = &dielectrics, .board_mm = 1.6 };
    const result = solve(stack, 50, 0.4, 0.2, 0.127).?;
    try testing.expectApproxEqAbs(@as(f64, 0.6735), result.antipad_dia_mm, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.1368), (result.antipad_dia_mm - 0.4) / 2.0, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 50), result.estimated_ohms, 1e-9);
    try testing.expect(!result.clearance_limited);
}

// spec: placement/via-antipad - ordinary copper clearance floors an electrically smaller antipad
test "ordinary copper clearance floors an electrically smaller antipad" {
    const stack = impedance.Stack{ .layers = 4, .board_mm = 1.6 };
    const result = solve(stack, 40, 0.4, 0.2, 0.2).?;
    try testing.expectApproxEqAbs(@as(f64, 0.8), result.antipad_dia_mm, 1e-12);
    try testing.expect(result.clearance_limited);
    try testing.expect(result.estimated_ohms > 40);
}
