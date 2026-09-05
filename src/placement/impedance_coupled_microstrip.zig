//! Kirschning-Jansen static edge-coupled microstrip analysis.
//!
//! `gap` is the edge-to-edge spacing. The returned differential impedance is
//! `2 * odd`, never twice the isolated-line impedance. The zero-thickness mode
//! equations are Qucs technical documentation eq. 11.89-11.129. Rolf Jansen's
//! mode-specific effective-width correction is applied when copper has finite
//! thickness, matching the equation lineage used by Qucs and KiCad.

const std = @import("std");
const microstrip = @import("impedance_microstrip.zig");

pub const Error = error{OutOfDomain};
const eta0: f64 = 120.0 * std.math.pi;

/// Even/odd modal values and their differential/common-mode combinations.
pub const Modes = struct {
    even_ohms: f64,
    odd_ohms: f64,
    differential_ohms: f64,
    common_ohms: f64,
    er_eff_even: f64,
    er_eff_odd: f64,
};

fn positive(value: f64) bool {
    return value > 0 and std.math.isFinite(value);
}

fn singleThicknessDeltaU(u: f64, thickness_over_h: f64) Error!f64 {
    if (thickness_over_h == 0) return 0;
    if (!positive(thickness_over_h)) return Error.OutOfDomain;
    const transition = 1.0 + @exp(-100.0 * (u - 1.0 / (2.0 * std.math.pi)));
    const log_arg = (2.0 + (4.0 * std.math.pi * u - 2.0) / transition) / thickness_over_h;
    if (!(log_arg > 0) or !std.math.isFinite(log_arg)) return Error.OutOfDomain;
    const result = 1.25 * thickness_over_h / std.math.pi * (1.0 + @log(log_arg));
    if (result < 0 or !std.math.isFinite(result)) return Error.OutOfDomain;
    return result;
}

fn correctedModeWidths(u: f64, g: f64, thickness_over_h: f64, er: f64) Error!struct { even: f64, odd: f64 } {
    if (thickness_over_h == 0) return .{ .even = u, .odd = u };
    const delta_u = try singleThicknessDeltaU(u, thickness_over_h);
    const delta_t = thickness_over_h / (g * er);
    if (!positive(delta_t)) return Error.OutOfDomain;
    const even_delta = delta_u * (1.0 - 0.5 * @exp(-0.69 * delta_u / delta_t));
    const odd_delta = even_delta + delta_t;
    const even = u + even_delta;
    const odd = u + odd_delta;
    if (!positive(even) or !positive(odd)) return Error.OutOfDomain;
    return .{ .even = even, .odd = odd };
}

fn thicknessFillingDelta(u: f64, thickness_over_h: f64) f64 {
    return 2.0 * @log(2.0) / std.math.pi * thickness_over_h / @sqrt(u);
}

fn evenEffectiveEr(u: f64, g: f64, thickness_over_h: f64, er: f64) Error!f64 {
    const v = u * (20.0 + g * g) / (10.0 + g * g) + g * @exp(-g);
    const v2 = v * v;
    const v3 = v2 * v;
    const v4 = v2 * v2;
    const a = 1.0 + @log((v4 + v2 / 2704.0) / (v4 + 0.432)) / 49.0 +
        @log(1.0 + v3 / 5929.741) / 18.7;
    const b = 0.564 * std.math.pow(f64, (er - 0.9) / (er + 3.0), 0.053);
    const fill = std.math.pow(f64, 1.0 + 10.0 / v, -a * b) -
        thicknessFillingDelta(u, thickness_over_h);
    const result = 0.5 * (er + 1.0) + 0.5 * (er - 1.0) * fill;
    if (!positive(result)) return Error.OutOfDomain;
    return result;
}

fn oddEffectiveEr(u: f64, g: f64, thickness_over_h: f64, er: f64, single_er_eff: f64) Error!f64 {
    const b_odd = 0.747 * er / (0.15 + er);
    const c_odd = b_odd - (b_odd - 0.207) * @exp(-0.414 * u);
    const d_odd = 0.593 + 0.694 * @exp(-0.562 * u);
    const fill = @exp(-c_odd * std.math.pow(f64, g, d_odd)) -
        thicknessFillingDelta(u, thickness_over_h);
    const a_odd = 0.7287 * (single_er_eff - 0.5 * (er + 1.0)) *
        (1.0 - @exp(-0.179 * u));
    const result = (0.5 * (er + 1.0) + a_odd - single_er_eff) * fill + single_er_eff;
    if (!positive(result)) return Error.OutOfDomain;
    return result;
}

/// Analyze a symmetric edge-coupled pair over one reference plane.
pub fn analyze(w: f64, h: f64, t: f64, er: f64, gap: f64) Error!Modes {
    if (!positive(w)) return Error.OutOfDomain;
    if (!positive(h)) return Error.OutOfDomain;
    if (!positive(gap)) return Error.OutOfDomain;
    if (t < 0 or !std.math.isFinite(t)) return Error.OutOfDomain;
    if (!std.math.isFinite(er)) return Error.OutOfDomain;
    if (er < 1.0 or er > 18.0) return Error.OutOfDomain;

    const u = w / h;
    const g = gap / h;
    const thickness_over_h = t / h;
    // Kirschning-Jansen's published static validity box.
    if (u < 0.1 or u > 10.0) return Error.OutOfDomain;
    if (g < 0.1 or g > 10.0) return Error.OutOfDomain;

    const widths = try correctedModeWidths(u, g, thickness_over_h, er);
    const single = microstrip.analyze(w, h, 0, er) catch return Error.OutOfDomain;
    const er_even = try evenEffectiveEr(widths.even, g, thickness_over_h, er);
    const er_odd = try oddEffectiveEr(widths.odd, g, thickness_over_h, er, single.er_eff);

    const q1 = 0.8695 * std.math.pow(f64, widths.even, 0.194);
    const q2 = 1.0 + 0.7519 * g + 0.189 * std.math.pow(f64, g, 2.31);
    const g10 = std.math.pow(f64, g, 10.0);
    const q3 = 0.1975 + std.math.pow(f64, 16.6 + std.math.pow(f64, 8.4 / g, 6.0), -0.387) +
        @log(g10 / (1.0 + std.math.pow(f64, g / 3.4, 10.0))) / 241.0;
    const exp_gap = @exp(-g);
    const q4 = 2.0 * q1 /
        (q2 * (exp_gap * std.math.pow(f64, widths.even, q3) +
            (2.0 - exp_gap) * std.math.pow(f64, widths.even, -q3)));

    const q5 = 1.794 + 1.14 * @log(1.0 + 0.638 /
        (g + 0.517 * std.math.pow(f64, g, 2.43)));
    const q6 = 0.2305 + @log(g10 / (1.0 + std.math.pow(f64, g / 5.8, 10.0))) / 281.3 +
        @log(1.0 + 0.598 * std.math.pow(f64, g, 1.154)) / 5.1;
    const q7 = (10.0 + 190.0 * g * g) / (1.0 + 82.3 * g * g * g);
    const q8 = @exp(-6.5 - 0.95 * @log(g) - std.math.pow(f64, g / 0.15, 5.0));
    const q9 = @log(q7) * (q8 + 1.0 / 16.5);
    const q10 = (q2 * q4 - q5 * @exp(@log(widths.odd) * q6 *
        std.math.pow(f64, widths.odd, -q9))) / q2;

    const even_denom = 1.0 - @sqrt(single.er_eff) * q4 * single.z0_ohms / eta0;
    const odd_denom = 1.0 - @sqrt(single.er_eff) * q10 * single.z0_ohms / eta0;
    if (!positive(even_denom) or !positive(odd_denom)) return Error.OutOfDomain;
    const even = single.z0_ohms * @sqrt(single.er_eff / er_even) / even_denom;
    const odd = single.z0_ohms * @sqrt(single.er_eff / er_odd) / odd_denom;
    if (!positive(even) or !positive(odd)) return Error.OutOfDomain;

    return .{
        .even_ohms = even,
        .odd_ohms = odd,
        .differential_ohms = 2.0 * odd,
        .common_ohms = even / 2.0,
        .er_eff_even = er_even,
        .er_eff_odd = er_odd,
    };
}

/// Differential impedance (`2 * Zodd`) of an edge-coupled microstrip pair.
pub fn z0(w: f64, h: f64, t: f64, er: f64, gap: f64) Error!f64 {
    return (try analyze(w, h, t, er, gap)).differential_ohms;
}

test "differential impedance is twice odd mode rather than twice isolated Z0" {
    const modes = try analyze(0.3, 0.2, 0.035, 4.4, 0.1);
    const isolated = try microstrip.analyze(0.3, 0.2, 0.035, 4.4);
    try std.testing.expectApproxEqAbs(2.0 * modes.odd_ohms, modes.differential_ohms, 1e-12);
    try std.testing.expect(modes.odd_ohms < isolated.z0_ohms);
    try std.testing.expect(modes.differential_ohms < 2.0 * isolated.z0_ohms);
    try std.testing.expect(modes.even_ohms > modes.odd_ohms);
}

test "coupling vanishes toward the loose end of the published gap range" {
    const modes = try analyze(0.3, 0.2, 0, 4.4, 2.0);
    const isolated = try microstrip.analyze(0.3, 0.2, 0, 4.4);
    try std.testing.expectApproxEqRel(isolated.z0_ohms, modes.odd_ohms, 0.01);
    try std.testing.expectApproxEqRel(isolated.z0_ohms, modes.even_ohms, 0.01);
}

test "published validity box is enforced" {
    try std.testing.expectError(Error.OutOfDomain, analyze(0.01, 0.2, 0, 4.4, 0.1));
    try std.testing.expectError(Error.OutOfDomain, analyze(0.3, 0.2, 0, 4.4, 0.01));
    try std.testing.expectError(Error.OutOfDomain, analyze(0.3, 0.2, 0, 20.0, 0.1));
}
