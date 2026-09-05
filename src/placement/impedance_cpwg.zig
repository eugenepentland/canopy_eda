//! Ground-backed coplanar-waveguide closed form used by `impedance.zig`.
//! Kept separate because the conformal-mapping implementation is independent
//! of the stack/reference model and deserves its own compact domain boundary.

const std = @import("std");
const elliptic = @import("elliptic_integral.zig");

pub const Error = error{OutOfDomain};
const eta0: f64 = 120.0 * std.math.pi;

/// Quasi-static grounded-CPWG result.  The effective permittivity is exposed
/// alongside Z0 so propagation delay and dielectric loss can use the exact
/// same conformal-mapping solution as width synthesis.
pub const Result = struct {
    z0_ohms: f64,
    er_eff: f64,
};

fn positive(v: f64) bool {
    return v > 0 and std.math.isFinite(v);
}

const ellipticRatio = elliptic.completeRatio;

/// Ghione-Naldi ground-backed CPW with Gupta's finite-thickness correction.
/// `gap_mm` is the edge-to-edge centre-strip/ground slot; no mask is modelled.
pub fn analyze(w_mm: f64, h_mm: f64, t_mm: f64, er: f64, gap_mm: f64) Error!Result {
    if (!positive(w_mm)) return Error.OutOfDomain;
    if (!positive(h_mm)) return Error.OutOfDomain;
    if (!positive(gap_mm)) return Error.OutOfDomain;
    if (t_mm < 0) return Error.OutOfDomain;
    if (!std.math.isFinite(t_mm)) return Error.OutOfDomain;
    if (!(er >= 1 and er <= 128)) return Error.OutOfDomain;

    const k1 = w_mm / (w_mm + 2.0 * gap_mm);
    const q1 = try ellipticRatio(k1);
    const k3 = std.math.tanh(std.math.pi * w_mm / (4.0 * h_mm)) /
        std.math.tanh(std.math.pi * (w_mm + 2.0 * gap_mm) / (4.0 * h_mm));
    const q3 = try ellipticRatio(k3);

    var qz = 1.0 / (q1 + q3);
    // Gupta's finite-thickness correction below is a posteriori: its
    // permittivity term starts from this zero-thickness filling factor while
    // only the impedance factor replaces q1 with the thickness-adjusted qe.
    // Recomputing this filling factor with qe double-counts part of the copper
    // thickness effect and raises Z0 by several ohms on ordinary 1 oz CPWG.
    var er_eff = 1.0 + q3 * qz * (er - 1.0);
    var z_factor = eta0 / 2.0 * qz;

    if (t_mm > 0) {
        const log_arg = 4.0 * std.math.pi * w_mm / t_mm;
        if (!(log_arg > 0)) return Error.OutOfDomain;
        if (!std.math.isFinite(log_arg)) return Error.OutOfDomain;
        const d = (t_mm * 1.25 / std.math.pi) * (1.0 + @log(log_arg));
        const effective_gap = gap_mm - d;
        const effective_width = w_mm + d;
        if (!positive(d)) return Error.OutOfDomain;
        if (!positive(effective_gap)) return Error.OutOfDomain;
        if (!positive(effective_width)) return Error.OutOfDomain;
        const ke = effective_width / (effective_width + 2.0 * effective_gap);
        const qe = try ellipticRatio(ke);
        qz = 1.0 / (qe + q3);
        z_factor = eta0 / 2.0 * qz;
        er_eff -= (0.7 * (er_eff - 1.0) * t_mm / gap_mm) /
            (q1 + 0.7 * t_mm / gap_mm);
    }
    if (!positive(er_eff)) return Error.OutOfDomain;
    if (!positive(z_factor)) return Error.OutOfDomain;
    return .{ .z0_ohms = z_factor / @sqrt(er_eff), .er_eff = er_eff };
}

/// Characteristic impedance convenience wrapper for width synthesis callers.
pub fn z0(w_mm: f64, h_mm: f64, t_mm: f64, er: f64, gap_mm: f64) Error!f64 {
    return (try analyze(w_mm, h_mm, t_mm, er, gap_mm)).z0_ohms;
}
