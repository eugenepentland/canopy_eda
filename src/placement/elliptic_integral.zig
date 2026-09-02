//! The complete elliptic integral of the first kind, K(k) — one implementation
//! for every conformal-mapping impedance model in `src/placement/`.
//!
//! `impedance.zig` (stripline + grounded CPWG), `impedance_cpwg.zig` and
//! `impedance_coupled_stripline.zig` each carried their own byte-identical
//! copy. K(k) is a mathematical constant of its argument, not a per-model
//! approximation: three copies could only ever agree or be a bug, and a
//! divergence would show up as an impedance number that disagrees with itself
//! depending on which module answered.
//!
//! Evaluated as π / (2·AGM(1, k′)) with k′ = √(1−k²) — Gauss's
//! arithmetic-geometric mean, which converges quadratically, so f64 is exact
//! in a handful of iterations. The iteration cap is purely defensive.
//!
//! The domain is the OPEN interval 0 < k < 1. K(0) = π/2 and K(1) = ∞ are both
//! refused rather than returned: every caller here divides one K by another,
//! and the endpoints are exactly the degenerate geometries (zero-width strip,
//! zero gap) that must be reported as out of domain rather than propagated as
//! a finite-looking impedance.

const std = @import("std");

pub const Error = error{OutOfDomain};

/// Defensive only. The AGM doubles its correct digits per step, so f64
/// converges in ~5 iterations and the loop exits on the fixed point long
/// before this.
const max_iterations: usize = 32;

fn positive(v: f64) bool {
    return v > 0 and std.math.isFinite(v);
}

/// Complete elliptic integral K(k) for 0 < k < 1, by the arithmetic-geometric
/// mean. `k` is the modulus (not the parameter m = k²).
pub fn completeK(k: f64) Error!f64 {
    if (!std.math.isFinite(k)) return Error.OutOfDomain;
    if (!(k > 0 and k < 1)) return Error.OutOfDomain;
    var a: f64 = 1.0;
    var b = @sqrt(1.0 - k * k);
    for (0..max_iterations) |_| {
        const next_a = 0.5 * (a + b);
        const next_b = @sqrt(a * b);
        if (next_a == a and next_b == b) break;
        a = next_a;
        b = next_b;
    }
    if (!positive(a)) return Error.OutOfDomain;
    return std.math.pi / (2.0 * a);
}

/// K(k) / K(k′) — the conformal-mapping ratio every model above actually
/// wants, with the complementary modulus k′ = √(1−k²) derived here so a
/// caller cannot pair a modulus with the wrong complement.
pub fn completeRatio(k: f64) Error!f64 {
    return try completeK(k) / try completeK(@sqrt(1.0 - k * k));
}

// spec: placement/impedance - Complete elliptic integral K(k) matches published values and refuses its degenerate endpoints
test "completeK matches published values and refuses the endpoints" {
    const testing = std.testing;
    // K(1/2) = 1.6857503548125960429... (DLMF 19.2.8 / AMS-55 table 17.1).
    try testing.expectApproxEqRel(@as(f64, 1.6857503548125961), try completeK(0.5), 1e-12);
    // K(k) → π/2 as k → 0; the endpoint itself is out of domain.
    try testing.expectApproxEqRel(std.math.pi / 2.0, try completeK(1e-9), 1e-12);
    try testing.expectError(Error.OutOfDomain, completeK(0));
    try testing.expectError(Error.OutOfDomain, completeK(1));
    try testing.expectError(Error.OutOfDomain, completeK(-0.5));
    try testing.expectError(Error.OutOfDomain, completeK(std.math.nan(f64)));
    // The ratio is 1 at the self-complementary modulus k = 1/√2.
    try testing.expectApproxEqRel(@as(f64, 1.0), try completeRatio(@sqrt(0.5)), 1e-12);
}
