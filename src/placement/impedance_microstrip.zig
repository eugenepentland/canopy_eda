//! Hammerstad-Jensen quasi-static microstrip analysis.
//!
//! This is the closed-form core shared by single and coupled microstrip. Width,
//! substrate height, and copper thickness use any one consistent length unit.
//! The finite-thickness calculation follows Hammerstad and Jensen's normalized
//! delta-width correction (Qucs technical documentation, eq. 11.22-11.25).

const std = @import("std");

pub const Error = error{OutOfDomain};

/// Free-space wave impedance in the form used by the published equations.
const eta0: f64 = 120.0 * std.math.pi;

/// Quasi-static single-line impedance and phase-velocity permittivity.
pub const Analysis = struct {
    z0_ohms: f64,
    er_eff: f64,
};

fn positive(value: f64) bool {
    return value > 0 and std.math.isFinite(value);
}

fn validEr(er: f64) bool {
    return er >= 1.0 and er <= 128.0 and std.math.isFinite(er);
}

/// Homogeneous (air) microstrip impedance for normalized width `u = W/h`.
fn airZ0(u: f64) Error!f64 {
    if (!positive(u)) return Error.OutOfDomain;
    const fu = 6.0 + (2.0 * std.math.pi - 6.0) *
        @exp(-std.math.pow(f64, 30.666 / u, 0.7528));
    const result = eta0 / (2.0 * std.math.pi) *
        @log(fu / u + @sqrt(1.0 + 4.0 / (u * u)));
    if (!positive(result)) return Error.OutOfDomain;
    return result;
}

/// Zero-thickness Hammerstad-Jensen effective relative permittivity.
fn effectiveEr(er: f64, u: f64) Error!f64 {
    if (!validEr(er) or !positive(u)) return Error.OutOfDomain;
    const u_squared = u * u;
    const u_fourth = u_squared * u_squared;
    const a = 1.0 + @log((u_fourth + u_squared / (52.0 * 52.0)) / (u_fourth + 0.432)) / 49.0 +
        @log(1.0 + u * u_squared / (18.1 * 18.1 * 18.1)) / 18.7;
    const b = 0.564 * std.math.pow(f64, (er - 0.9) / (er + 3.0), 0.053);
    const result = (er + 1.0) / 2.0 + (er - 1.0) / 2.0 *
        std.math.pow(f64, 1.0 + 10.0 / u, -a * b);
    if (!positive(result)) return Error.OutOfDomain;
    return result;
}

const CorrectedWidths = struct {
    /// Width corrected as though the surrounding medium were homogeneous.
    u_air: f64,
    /// Width corrected for the dielectric/air mixed medium.
    u_dielectric: f64,
};

fn correctedWidths(u: f64, thickness_over_h: f64, er: f64) Error!CorrectedWidths {
    if (thickness_over_h == 0) return .{ .u_air = u, .u_dielectric = u };
    if (!positive(thickness_over_h)) return Error.OutOfDomain;

    const root = @sqrt(6.517 * u);
    const tanh_root = std.math.tanh(root);
    if (!positive(tanh_root)) return Error.OutOfDomain;
    const coth_sq = 1.0 / (tanh_root * tanh_root);
    const delta_u_air = thickness_over_h / std.math.pi *
        @log(1.0 + 4.0 * std.math.e / (thickness_over_h * coth_sq));
    const delta_u_dielectric = 0.5 * delta_u_air *
        (1.0 + 1.0 / std.math.cosh(@sqrt(er - 1.0)));
    const u_air = u + delta_u_air;
    const u_dielectric = u + delta_u_dielectric;
    if (!positive(u_air) or !positive(u_dielectric)) return Error.OutOfDomain;
    return .{ .u_air = u_air, .u_dielectric = u_dielectric };
}

/// Quasi-static characteristic impedance and effective permittivity.
///
/// Published accuracy of the effective-permittivity fit is stated for
/// `0.01 <= W/h <= 100`; this routine refuses to extrapolate beyond that common
/// impedance/permittivity domain. `t` may be zero.
pub fn analyze(w: f64, h: f64, t: f64, er: f64) Error!Analysis {
    if (!positive(w) or !positive(h)) return Error.OutOfDomain;
    if (t < 0 or !std.math.isFinite(t)) return Error.OutOfDomain;
    if (!validEr(er)) return Error.OutOfDomain;

    const u = w / h;
    if (u < 0.01 or u > 100.0) return Error.OutOfDomain;
    const corrected = try correctedWidths(u, t / h, er);
    const z_air_dielectric = try airZ0(corrected.u_dielectric);
    const er_eff_zero = try effectiveEr(er, corrected.u_dielectric);
    const z0 = z_air_dielectric / @sqrt(er_eff_zero);

    // Eq. 11.25: phase velocity uses the homogeneous and mixed-media width
    // corrections together. Impedance itself uses eq. 11.24 above.
    const z_air = try airZ0(corrected.u_air);
    const er_eff = er_eff_zero * (z_air / z_air_dielectric) * (z_air / z_air_dielectric);
    if (!positive(z0) or !positive(er_eff)) return Error.OutOfDomain;
    return .{ .z0_ohms = z0, .er_eff = er_eff };
}

test "Hammerstad-Jensen is continuous through W over h equals one" {
    const below = try analyze(0.999999, 1.0, 0, 4.4);
    const above = try analyze(1.000001, 1.0, 0, 4.4);
    try std.testing.expectApproxEqAbs(below.z0_ohms, above.z0_ohms, 0.001);
    try std.testing.expectApproxEqAbs(below.er_eff, above.er_eff, 0.001);
}

test "finite copper changes both quasi-static line parameters" {
    const zero = try analyze(0.3, 0.2, 0, 4.4);
    const thick = try analyze(0.3, 0.2, 0.035, 4.4);
    try std.testing.expect(thick.z0_ohms < zero.z0_ohms);
    try std.testing.expect(@abs(thick.er_eff - zero.er_eff) > 1e-6);
    try std.testing.expect(thick.er_eff > 1.0 and thick.er_eff < 4.4);
}

test "air dielectric has unit effective permittivity" {
    const result = try analyze(0.3, 0.2, 0.035, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.er_eff, 1e-12);
}
