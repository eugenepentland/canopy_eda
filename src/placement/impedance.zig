//! Characteristic impedance (Z₀) of a PCB trace, from the board's `(stackup …)`
//! geometry. Pure math + a stack model: nothing here reads a design, allocates
//! for its own sake, or touches the router. It is what upgrades
//! `(net-class … (max-freq …))` from geometry *discipline* (bend radius, escape
//! length) to electrical *truth* — a width that actually hits 50 Ω on THIS
//! buildup rather than on a rule of thumb.
//!
//! Three transmission-line cases cover every layer of an ordinary stackup:
//!
//!   • **Microstrip** — an OUTER copper face (layer 1 or layer N) over the
//!     nearest reference plane, dielectric on one side and air on the other.
//!   • **Grounded coplanar waveguide** — the same outer-face trace with
//!     same-layer ground copper a declared edge-to-edge gap away on both sides.
//!   • **Stripline** — an INNER signal layer with a reference plane above AND
//!     below, including offset and mixed-dielectric constructions.
//!   • **Coupled pairs** — edge-coupled microstrip/stripline and numerical
//!     broadside even/odd modes.
//!
//! An inner layer with a plane on only one side, or any layer with no plane at
//! all, has no closed-form reference here and is refused rather than guessed.
//!
//! ## Formulas and citations
//!
//! **Microstrip** — the continuous Hammerstad-Jensen model (E. Hammerstad and
//! Ø. Jensen, "Accurate Models for Microstrip Computer-Aided Design", IEEE
//! MTT-S Digest, 1980). With u = W/h:
//!
//!     Zair = η₀/(2π) · ln(fu/u + √(1 + (2/u)²))
//!     fu   = 6 + (2π−6) · exp(−(30.666/u)^0.7528)
//!     εeff = (εr+1)/2 + (εr−1)/2 · (1 + 10/u)^(−a(u)b(εr))
//!     Z₀   = Zair / √εeff
//!
//! The published accuracy is better than 0.2% for effective permittivity and
//! 0.03% for impedance over the practical domain. Unlike the former two-branch
//! approximation, it has no discontinuity for the inverse solver to hide.
//!
//! Finite strip thickness uses Hammerstad-Jensen's distinct homogeneous and
//! mixed-media normalized delta-width corrections; their ratio also corrects
//! the phase-velocity effective permittivity.
//!
//! **Grounded coplanar waveguide** — the quasi-static conformal-mapping model
//! of Ghione & Naldi (Electronics Letters 19(18), 1983, eq. 8), with complete
//! elliptic integrals evaluated by the arithmetic-geometric mean. For centre
//! strip W, slot S and backing-plane height h:
//!
//!     k₁ = W/(W+2S),  q₁ = K(k₁)/K(sqrt(1-k₁²))
//!     k₃ = tanh(πW/4h)/tanh(π(W+2S)/4h),  q₃ = K(k₃)/K(sqrt(1-k₃²))
//!     qz = 1/(q₁+q₃),  εeff = 1 + q₃qz(εr−1)
//!     Z₀ = (η₀/2)qz/sqrt(εeff)
//!
//! Finite thickness follows Gupta et al., *Microstrip Lines and Slotlines*,
//! 2nd ed., eq. 7.98–7.100: d=(1.25t/π)(1+ln(4πW/t)), W becomes W+d and
//! S becomes S−d in the elliptic ratio. The zero-thickness filling factor is
//! then reduced a posteriori by
//!
//!     εeff,t = εeff − 0.7(εeff−1)(t/S) / (q₁ + 0.7t/S)
//!
//! This is the ideal bare-trace baseline. Declared soldermask, etched
//! trapezoids and mixed media are applied by the calibrated capacitance-matrix
//! fallback below; frequency-dependent dispersion and loss remain outside this
//! module's width/impedance contract.
//!
//! **Symmetric stripline** — Cohn's exact zero-thickness conformal map (S. B.
//! Cohn, "Characteristic Impedance of the Shielded-Strip Transmission Line",
//! IRE Trans. MTT-2, 1954, pp. 52–57), with complete elliptic integrals
//! evaluated by the arithmetic-geometric mean:
//!
//!     Z₀ = 30π/√εr · K(k′)/K(k)
//!     k = sech(πW/2b),  k′ = tanh(πW/2b)
//!
//! Finite copper uses the Cohn/Wadell fringing-capacitance approximation as
//! published in IPC-2141A §4.2.2, with b the plane-to-plane separation.
//! NARROW strip, W/(b−t) < 0.35:
//!
//!     Z₀ = (60/√εr) · ln( 4b / (0.67π · (0.8W + t)) )
//!
//! WIDE strip, W/(b−t) > 0.35, where the parallel-plate term dominates and a
//! fringing capacitance C_f is added:
//!
//!     Z₀ = (94.15/√εr) / ( (W/b)/(1 − t/b) + C_f )
//!     C_f = (2/π)·[ k·ln(k + 1) − (k − 1)·ln(k² − 1) ],   k = 1/(1 − t/b)
//!
//! Both branches are needed: 50 Ω in FR-4 lands at W/(b−t) ≈ 0.35–0.45, i.e.
//! astride the crossover, so a narrow-only model would refuse the single most
//! common controlled-impedance target. The branches disagree by ~3.5 % at the
//! crossover (within their own stated accuracy), so they are BLENDED linearly
//! over 0.30 ≤ W/(b−t) ≤ 0.40 rather than switched. That is not cosmetic: a
//! step discontinuity would break the monotonicity the inverse solve below
//! depends on. Outside that band each branch is used verbatim. The thin-foil
//! condition t/b < 0.25 is enforced for both.
//!
//! **Asymmetric (offset) stripline** — built by superposition from the
//! symmetric result rather than as a second, differently-calibrated fit. In a
//! HOMOGENEOUS dielectric the strip's capacitance to the two planes simply
//! adds (C = C₁ + C₂), and Z₀ = √εr/(c₀·C), so the two half-line impedances
//! combine in parallel:
//!
//!     1/Z₀ = 1/Z_half(h₁) + 1/Z_half(h₂),
//!     Z_half(h) = 2 · Z₀_symmetric(W, b = 2h + t, t, εr)
//!
//! Z_half is defined as twice the symmetric impedance of the stack that would
//! put a plane h away on BOTH sides, so h₁ = h₂ reproduces the symmetric result
//! EXACTLY. That calibration is what makes the construction defensible: it is
//! the classic formula everywhere it overlaps one, and the physically correct
//! interpolation between — and it inherits the narrow/wide blend for free.
//!
//! **Edge-coupled stripline** — Cohn's shielded coupled-strip conformal map
//! (IRE Trans. MTT-3, 1955), with his finite-thickness fringe-capacitance
//! correction. For an offset pair, Wadell's image construction combines two
//! virtual centred coupled striplines, one for each reference-plane spacing.
//! This is the same quasi-static analysis used by KiCad's coupled-stripline
//! calculator. The differential impedance is twice the odd-mode impedance:
//!
//!     Zdiff = 2 Zodd
//!
//! Pair spacing is the routed edge-to-edge gap from `(diff-pair GAP)`.
//!
//! **Edge-coupled microstrip** — Kirschning-Jansen's even/odd quasi-static
//! model (IEEE MTT-32(1), 1984), with Jansen's finite-thickness effective-width
//! correction. Its published range is 0.1 ≤ W/h ≤ 10, 0.1 ≤ S/h ≤ 10, and
//! 1 ≤ εr ≤ 18. It returns both modes and uses `Zdiff = 2 Zodd`; it never
//! doubles the isolated single-ended impedance.
//!
//! **Numerical fallback** — a finite-volume solution of
//! `div(epsilon grad(V)) = 0` integrates the Maxwell capacitance matrix. A
//! vacuum solve gives `L = mu0*epsilon0*C_air^-1`; direct odd/even excitations
//! give the modal impedances and `Zdiff = 2 Zodd`. For any geometry with a
//! matching closed form, the solver is used as an actual/ideal ratio on that
//! baseline, cancelling most finite-box and grid error. Broadside pairs, which
//! have no baseline in this module, use the matrix result directly.
//!
//! ## Inverse
//!
//! `refWidthForZ0` solves W from a target Z₀ by bisection. Z₀ is strictly
//! decreasing in W for both cases, so bisection is unconditionally convergent;
//! it is used in preference to a closed-form synthesis formula because it stays
//! exactly consistent with the analysis equations above (round-trip
//! W → Z₀ → W is a fixed point to the bracket tolerance) and is deterministic
//! to the last bit — no iteration count that depends on the input.

const std = @import("std");
const cpwg = @import("impedance_cpwg.zig");
const microstrip = @import("impedance_microstrip.zig");
const coupled_microstrip = @import("impedance_coupled_microstrip.zig");
const coupled_stripline = @import("impedance_coupled_stripline.zig");
const field = @import("impedance_field.zig");

/// Why an impedance could not be computed. Every one of these is a refusal to
/// extrapolate: the approximations above have published validity ranges and a
/// number produced outside them would be a fabrication, not an estimate.
pub const Error = error{
    /// Geometry outside the closed form's stated domain (u, W/(b−t), t/b, εr).
    OutOfDomain,
    /// No target Z₀ inside the domain reaches the requested value.
    Unreachable,
};

/// Typical FR-4 relative permittivity used when a `(dielectric …)` entry
/// declares no `(er …)`. Generic FR-4 laminate is quoted between 4.2 and 4.7
/// at 1 MHz–1 GHz depending on resin content and glass style (IPC-4101 sheet
/// 21/26 class laminates; e.g. Isola 370HR is 4.04–4.24 at 1 GHz, Panasonic
/// R-1755V ≈ 4.6 at 1 MHz). 4.4 is the long-standing textbook midpoint and is
/// what every hand calculation in this repo's board notes assumes.
pub const default_er: f64 = 4.4;

/// Nominal 1 oz copper foil thickness (mm) — the finished-foil figure a fab
/// quotes for 35 µm plating. Used when `(copper IDX (thickness MM))` is absent.
pub const default_foil_mm: f64 = 0.035;

/// Fab-standard finished board thickness (mm), used to synthesise a uniform
/// buildup when the stackup declares layer count but no dielectric intervals.
/// Same default the Gerber job file reports.
pub const default_board_mm: f64 = 1.6;

// ── Closed forms ─────────────────────────────────────────────────────────────

/// A finite, strictly positive length/impedance. Factored out so each domain
/// guard below stays a single readable comparison.
fn positive(v: f64) bool {
    return v > 0 and std.math.isFinite(v);
}

/// The permittivity range Hammerstad's and Cohn's fits are stated over.
fn validEr(er: f64) bool {
    return er >= 1.0 and er <= 128.0;
}

/// Microstrip characteristic impedance (Ω): trace of width `w_mm` and copper
/// thickness `t_mm` on an outer face, `h_mm` above its reference plane, over a
/// dielectric of relative permittivity `er`. See the module header for the
/// equations and their published domain.
pub fn microstripZ0(w_mm: f64, h_mm: f64, t_mm: f64, er: f64) Error!f64 {
    return (microstrip.analyze(w_mm, h_mm, t_mm, er) catch return Error.OutOfDomain).z0_ohms;
}

/// Ground-backed coplanar-waveguide characteristic impedance (Ω). `gap_mm`
/// is the same-layer edge-to-edge slot between the trace and ground pour; the
/// backing plane is `h_mm` below the outer copper. No soldermask is modelled.
pub fn groundedCoplanarZ0(w_mm: f64, h_mm: f64, t_mm: f64, er: f64, gap_mm: f64) Error!f64 {
    return cpwg.z0(w_mm, h_mm, t_mm, er, gap_mm);
}

/// Cohn's NARROW-strip branch, W/(b−t) < 0.35.
fn stripNarrowZ0(w_mm: f64, b_mm: f64, t_mm: f64, er: f64) Error!f64 {
    const denom = 0.67 * std.math.pi * (0.8 * w_mm + t_mm);
    if (!positive(denom)) return Error.OutOfDomain;
    const arg = 4.0 * b_mm / denom;
    if (arg <= 1.0) return Error.OutOfDomain; // ln <= 0 — well past the fit
    return (60.0 / @sqrt(er)) * @log(arg);
}

/// Cohn's WIDE-strip branch, W/(b−t) > 0.35: parallel-plate plus the fringing
/// capacitance term.
fn stripWideZ0(w_mm: f64, b_mm: f64, t_mm: f64, er: f64) Error!f64 {
    const x = t_mm / b_mm;
    if (x >= 1.0) return Error.OutOfDomain;
    const k = 1.0 / (1.0 - x);
    // C_f = (2/π)[ k·ln(k+1) − (k−1)·ln(k²−1) ]. At t = 0 (k = 1) the second
    // term is 0·ln(0), whose limit is 0 — taken explicitly rather than by
    // letting the floating-point evaluate ln(0).
    const second = if (k > 1.0) (k - 1.0) * @log(k * k - 1.0) else 0.0;
    const cf = (2.0 / std.math.pi) * (k * @log(k + 1.0) - second);
    const denom = (w_mm / b_mm) * k + cf;
    if (!positive(denom)) return Error.OutOfDomain;
    return (94.15 / @sqrt(er)) / denom;
}

/// Complete elliptic integral K(k), evaluated by the arithmetic-geometric
/// mean. The fixed cap is defensive; f64 converges in only a few iterations.
fn ellipticK(k: f64) Error!f64 {
    if (!std.math.isFinite(k)) return Error.OutOfDomain;
    if (k <= 0 or k >= 1) return Error.OutOfDomain;
    var a: f64 = 1.0;
    var b = @sqrt(1.0 - k * k);
    for (0..32) |_| {
        const next_a = 0.5 * (a + b);
        const next_b = @sqrt(a * b);
        if (next_a == a and next_b == b) break;
        a = next_a;
        b = next_b;
    }
    if (!positive(a)) return Error.OutOfDomain;
    return std.math.pi / (2.0 * a);
}

/// Cohn's exact zero-thickness conformal map for a centered stripline.
fn stripExactZ0(w_mm: f64, b_mm: f64, er: f64) Error!f64 {
    const x = std.math.pi * w_mm / (2.0 * b_mm);
    const k = 1.0 / std.math.cosh(x);
    const k_complement = std.math.tanh(x);
    const result = 30.0 * std.math.pi / @sqrt(er) *
        try ellipticK(k_complement) / try ellipticK(k);
    if (!positive(result)) return Error.OutOfDomain;
    return result;
}

/// Symmetric stripline: strip centred between planes `b_mm` apart. Blends the
/// two Cohn branches over 0.30 ≤ W/(b−t) ≤ 0.40 so the model is continuous and
/// monotonic in W — see the module header.
fn symmetricStriplineZ0(w_mm: f64, b_mm: f64, t_mm: f64, er: f64) Error!f64 {
    if (!positive(b_mm)) return Error.OutOfDomain;
    if (t_mm / b_mm >= 0.25) return Error.OutOfDomain; // Cohn's thin-foil limit
    const gap = b_mm - t_mm;
    if (!positive(gap)) return Error.OutOfDomain;
    const ratio = w_mm / gap;
    if (ratio > 10.0) return Error.OutOfDomain; // a strip this wide is a plane
    if (t_mm == 0) return stripExactZ0(w_mm, b_mm, er);
    if (ratio <= 0.30) return stripNarrowZ0(w_mm, b_mm, t_mm, er);
    if (ratio >= 0.40) return stripWideZ0(w_mm, b_mm, t_mm, er);
    const lambda = (ratio - 0.30) / 0.10;
    const narrow = try stripNarrowZ0(w_mm, b_mm, t_mm, er);
    const wide = try stripWideZ0(w_mm, b_mm, t_mm, er);
    return (1.0 - lambda) * narrow + lambda * wide;
}

/// Stripline characteristic impedance (Ω) for a strip between two reference
/// planes: `h1_mm` to the plane on one side, `h2_mm` to the other, copper
/// thickness `t_mm`, homogeneous dielectric `er`. `h1 == h2` is the symmetric
/// (Cohn / IPC-2141A) case; unequal spacings are the offset case built by the
/// parallel-capacitance superposition described in the module header.
pub fn striplineZ0(w_mm: f64, h1_mm: f64, h2_mm: f64, t_mm: f64, er: f64) Error!f64 {
    if (!positive(w_mm)) return Error.OutOfDomain;
    if (!positive(h1_mm)) return Error.OutOfDomain;
    if (!positive(h2_mm)) return Error.OutOfDomain;
    if (t_mm < 0) return Error.OutOfDomain;
    if (!validEr(er)) return Error.OutOfDomain;
    // Each half is the symmetric stack that would put a plane h away on both
    // sides; twice its impedance is that half's contribution, and the two add
    // in parallel (see the header). h1 == h2 collapses to the symmetric case.
    const za = 2.0 * try symmetricStriplineZ0(w_mm, 2.0 * h1_mm + t_mm, t_mm, er);
    const zb = 2.0 * try symmetricStriplineZ0(w_mm, 2.0 * h2_mm + t_mm, t_mm, er);
    if (!positive(za)) return Error.OutOfDomain;
    if (!positive(zb)) return Error.OutOfDomain;
    return 1.0 / (1.0 / za + 1.0 / zb);
}

// ── Reference geometry ───────────────────────────────────────────────────────

/// The transmission-line case a signal layer presents, with the reference
/// geometry already resolved out of the stackup. Width is NOT part of it —
/// that is the unknown being solved for (or checked).
pub const Ref = union(enum) {
    /// Outer face over the nearest plane.
    microstrip: struct { h_mm: f64, er: f64 },
    /// Inner layer between two planes.
    stripline: struct { h1_mm: f64, h2_mm: f64, er: f64 },

    /// The dielectric height to the nearer reference plane (mm) — the one
    /// number that most compactly describes either case.
    pub fn heightMm(self: Ref) f64 {
        return switch (self) {
            .microstrip => |m| m.h_mm,
            .stripline => |s| @min(s.h1_mm, s.h2_mm),
        };
    }

    /// Effective relative permittivity of the reference dielectric.
    pub fn er(self: Ref) f64 {
        return switch (self) {
            .microstrip => |m| m.er,
            .stripline => |s| s.er,
        };
    }

    /// Short word naming the case, for JSON/report surfaces.
    pub fn kindName(self: Ref) []const u8 {
        return switch (self) {
            .microstrip => "microstrip",
            .stripline => "stripline",
        };
    }

    /// Report the outer-face geometry as grounded coplanar when a positive
    /// same-layer ground gap is in force. Inner layers remain stripline: the
    /// DSL's pour gap has no meaning between their two reference planes.
    pub fn kindNameWithGroundGap(self: Ref, ground_gap_mm: f64) []const u8 {
        return switch (self) {
            .microstrip => if (ground_gap_mm > 0) "grounded-coplanar" else "microstrip",
            .stripline => "stripline",
        };
    }
};

/// Z₀ (Ω) of a `w_mm`-wide, `t_mm`-thick trace in this reference geometry.
pub fn refZ0(ref: Ref, w_mm: f64, t_mm: f64) Error!f64 {
    return switch (ref) {
        .microstrip => |m| microstripZ0(w_mm, m.h_mm, t_mm, m.er),
        .stripline => |s| striplineZ0(w_mm, s.h1_mm, s.h2_mm, t_mm, s.er),
    };
}

/// Z₀ with an optional outer-layer grounded-coplanar gap. A zero gap preserves
/// the original microstrip/stripline behavior exactly.
pub fn refZ0WithGroundGap(ref: Ref, w_mm: f64, t_mm: f64, ground_gap_mm: f64) Error!f64 {
    if (ground_gap_mm < 0 or !std.math.isFinite(ground_gap_mm)) return Error.OutOfDomain;
    return switch (ref) {
        .microstrip => |m| if (ground_gap_mm > 0)
            groundedCoplanarZ0(w_mm, m.h_mm, t_mm, m.er, ground_gap_mm)
        else
            microstripZ0(w_mm, m.h_mm, t_mm, m.er),
        .stripline => |s| striplineZ0(w_mm, s.h1_mm, s.h2_mm, t_mm, s.er),
    };
}

/// Effective relative permittivity paired with `refZ0WithGroundGap`.  This is
/// the phase-velocity quantity for a quasi-TEM line, not the laminate Dk: an
/// outer trace also stores energy in air, while stripline is fully embedded.
pub fn refEffectiveErWithGroundGap(ref: Ref, w_mm: f64, t_mm: f64, ground_gap_mm: f64) Error!f64 {
    if (!positive(w_mm)) return Error.OutOfDomain;
    if (t_mm < 0 or !std.math.isFinite(t_mm)) return Error.OutOfDomain;
    if (ground_gap_mm < 0 or !std.math.isFinite(ground_gap_mm)) return Error.OutOfDomain;
    return switch (ref) {
        .microstrip => |m| if (ground_gap_mm > 0)
            (try cpwg.analyze(w_mm, m.h_mm, t_mm, m.er, ground_gap_mm)).er_eff
        else
            (microstrip.analyze(w_mm, m.h_mm, t_mm, m.er) catch return Error.OutOfDomain).er_eff,
        .stripline => |s| s.er,
    };
}

/// A locally synthesized grounded-CPWG slot for one routed width. `capped`
/// means the requested impedance was still above `z0_ohms` at the caller's
/// maximum permissible pour setback; the returned geometry is nevertheless
/// the best reachable value without disturbing the backing plane.
pub const GroundGapSolution = struct {
    gap_mm: f64,
    z0_ohms: f64,
    capped: bool,
};

/// Solve the same-layer ground-pour gap that makes a fixed-width OUTER trace
/// reach `target_ohms`, bounded by the authored minimum and maximum setbacks.
/// The grounded-CPWG solution is monotonic in gap: moving side ground away
/// raises Z0 until the backing-plane microstrip limit is approached. When the
/// cap is reached first, return that honest best effort with `capped = true`.
/// Inner stripline has no same-layer slot and is refused rather than assigned a
/// geometrically meaningless value.
pub fn refGroundGapForZ0(
    ref: Ref,
    w_mm: f64,
    t_mm: f64,
    target_ohms: f64,
    minimum_gap_mm: f64,
    maximum_gap_mm: f64,
) Error!GroundGapSolution {
    if (!(target_ohms > 0) or !std.math.isFinite(target_ohms)) return Error.OutOfDomain;
    if (!(minimum_gap_mm > 0) or !std.math.isFinite(minimum_gap_mm)) return Error.OutOfDomain;
    if (maximum_gap_mm < minimum_gap_mm or !std.math.isFinite(maximum_gap_mm)) return Error.OutOfDomain;
    switch (ref) {
        .stripline => return Error.OutOfDomain,
        .microstrip => {},
    }

    const z_min = try refZ0WithGroundGap(ref, w_mm, t_mm, minimum_gap_mm);
    if (z_min >= target_ohms) return .{ .gap_mm = minimum_gap_mm, .z0_ohms = z_min, .capped = false };
    const z_max = try refZ0WithGroundGap(ref, w_mm, t_mm, maximum_gap_mm);
    if (z_max < target_ohms) return .{ .gap_mm = maximum_gap_mm, .z0_ohms = z_max, .capped = true };

    var lo = minimum_gap_mm;
    var hi = maximum_gap_mm;
    for (0..80) |_| {
        const mid = (lo + hi) / 2.0;
        const z = try refZ0WithGroundGap(ref, w_mm, t_mm, mid);
        if (z < target_ohms) lo = mid else hi = mid;
    }
    const gap = (lo + hi) / 2.0;
    return .{
        .gap_mm = gap,
        .z0_ohms = try refZ0WithGroundGap(ref, w_mm, t_mm, gap),
        .capped = false,
    };
}

/// Differential impedance of a pair in this reference geometry. Outer layers
/// use Kirschning-Jansen edge-coupled microstrip; inner layers use Cohn/Wadell
/// edge-coupled stripline. Both return `2 * Zodd`.
pub fn refDiffZ0(ref: Ref, w_mm: f64, t_mm: f64, pair_gap_mm: f64) Error!f64 {
    return switch (ref) {
        .microstrip => |m| coupled_microstrip.z0(w_mm, m.h_mm, t_mm, m.er, pair_gap_mm) catch return Error.OutOfDomain,
        .stripline => |s| coupled_stripline.z0(w_mm, s.h1_mm, s.h2_mm, t_mm, s.er, pair_gap_mm),
    };
}

fn refDiffEffectiveErOdd(ref: Ref, w_mm: f64, t_mm: f64, pair_gap_mm: f64) Error!f64 {
    return switch (ref) {
        .microstrip => |m| (coupled_microstrip.analyze(w_mm, m.h_mm, t_mm, m.er, pair_gap_mm) catch return Error.OutOfDomain).er_eff_odd,
        // A homogeneous stripline is pure TEM, so every mode sees the bulk Dk.
        .stripline => |s| s.er,
    };
}

/// Widest and narrowest trace worth bracketing for `ref`, in mm. Deliberately
/// generous at both ends — the domain checks inside `refZ0` do the real
/// rejecting; this only has to contain the solution.
fn widthBracket(ref: Ref) [2]f64 {
    const h = ref.heightMm();
    return .{ h * 0.01, h * 100.0 };
}

/// Solve the trace width (mm) that gives `target_ohms` in this reference
/// geometry, by bisection. Z₀ decreases monotonically with width, so the
/// bracket is [narrow → high Z₀, wide → low Z₀].
///
/// `Error.Unreachable` when no width inside the closed form's domain reaches
/// the target (e.g. 100 Ω single-ended on a 0.1 mm prepreg microstrip, which
/// would need a strip narrower than the fit covers).
pub fn refWidthForZ0(ref: Ref, target_ohms: f64, t_mm: f64) Error!f64 {
    return refWidthForZ0WithGroundGap(ref, target_ohms, t_mm, 0);
}

/// Inverse of `refZ0WithGroundGap`, preserving the same fixed-iteration
/// bisection contract as the original microstrip/stripline solve.
pub fn refWidthForZ0WithGroundGap(ref: Ref, target_ohms: f64, t_mm: f64, ground_gap_mm: f64) Error!f64 {
    if (!(target_ohms > 0)) return Error.OutOfDomain;
    if (ground_gap_mm < 0 or !std.math.isFinite(ground_gap_mm)) return Error.OutOfDomain;
    const bracket = widthBracket(ref);
    // Walk inward from each end until both ends are inside the domain AND
    // straddle the target. Deterministic: fixed step count, fixed ratios.
    var lo = bracket[0];
    var hi = bracket[1];
    // z_lo is the HIGH impedance end (narrow strip), z_hi the LOW (wide).
    const z_lo = findEdge(ref, &lo, hi, t_mm, ground_gap_mm, .up) orelse return Error.OutOfDomain;
    const z_hi = findEdge(ref, &hi, lo, t_mm, ground_gap_mm, .down) orelse return Error.OutOfDomain;
    if (lo >= hi) return Error.OutOfDomain;
    if (target_ohms > z_lo) return Error.Unreachable;
    if (target_ohms < z_hi) return Error.Unreachable;
    // 80 halvings takes any bracket below f64 resolution; the loop is fixed
    // count (not tolerance-terminated) so the answer never depends on timing
    // or on how wide the initial bracket happened to be.
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        const mid = 0.5 * (lo + hi);
        if (!(mid > lo) or !(mid < hi)) break; // bracket collapsed to an ulp
        const z = refZ0WithGroundGap(ref, mid, t_mm, ground_gap_mm) catch break;
        if (z > target_ohms) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

/// Solve one trace's width for a differential target at a fixed edge-to-edge
/// pair gap. Analysis and synthesis share the exact same closed form, so a
/// derived width round-trips to its target.
pub fn refWidthForDiffZ0(ref: Ref, target_ohms: f64, t_mm: f64, pair_gap_mm: f64) Error!f64 {
    if (!(target_ohms > 0) or !positive(pair_gap_mm)) return Error.OutOfDomain;
    const bracket = widthBracket(ref);
    var lo = bracket[0];
    var hi = bracket[1];
    const z_lo = findDiffEdge(ref, &lo, hi, t_mm, pair_gap_mm, .up) orelse return Error.OutOfDomain;
    const z_hi = findDiffEdge(ref, &hi, lo, t_mm, pair_gap_mm, .down) orelse return Error.OutOfDomain;
    if (lo >= hi) return Error.OutOfDomain;
    if (target_ohms > z_lo or target_ohms < z_hi) return Error.Unreachable;
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        const mid = 0.5 * (lo + hi);
        if (!(mid > lo) or !(mid < hi)) break;
        const z = refDiffZ0(ref, mid, t_mm, pair_gap_mm) catch break;
        if (z > target_ohms) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

fn findDiffEdge(
    ref: Ref,
    edge: *f64,
    toward: f64,
    t_mm: f64,
    pair_gap_mm: f64,
    dir: enum { up, down },
) ?f64 {
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        if (refDiffZ0(ref, edge.*, t_mm, pair_gap_mm)) |z| return z else |_| {}
        edge.* = switch (dir) {
            .up => edge.* * 1.12,
            .down => edge.* / 1.12,
        };
        switch (dir) {
            .up => if (edge.* >= toward) return null,
            .down => if (edge.* <= toward) return null,
        }
    }
    return null;
}

/// Nudge `edge` toward `toward` until `refZ0` accepts it, returning the
/// impedance there (null when the whole span is out of domain). 60 steps of a
/// fixed 12 % geometric walk — deterministic and independent of the caller.
fn findEdge(ref: Ref, edge: *f64, toward: f64, t_mm: f64, ground_gap_mm: f64, dir: enum { up, down }) ?f64 {
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        if (refZ0WithGroundGap(ref, edge.*, t_mm, ground_gap_mm)) |z| return z else |_| {}
        edge.* = switch (dir) {
            .up => edge.* * 1.12,
            .down => edge.* / 1.12,
        };
        switch (dir) {
            .up => if (edge.* >= toward) return null,
            .down => if (edge.* <= toward) return null,
        }
    }
    return null;
}

// ── Stack model ──────────────────────────────────────────────────────────────

/// The controlled-impedance outcome for a net, resolved from its class's
/// `(impedance OHMS)`. Both halves travel together because either alone is
/// ambiguous: a target with no note of how the width was chosen cannot tell a
/// checker whether to verify that width or to trust it.
pub const Rule = struct {
    /// Target single-ended Z₀ (Ω); 0 = the class declared none. Kept even when
    /// the width was authored — that is exactly the case the
    /// `impedance_mismatch` lint checks.
    ohms: f64 = 0,
    /// Target differential impedance (Ω); 0 = undeclared. Uses the class's
    /// `(diff-pair GAP)` edge spacing and coupled-stripline analysis.
    diff_ohms: f64 = 0,
    /// 1-based copper layer selected by `(impedance … (layer N))` or
    /// `(diff-impedance … (layer N))`; 0 keeps the ordinary first usable
    /// signal-layer default.
    layer: u8 = 0,
    /// Resolved same-layer edge-to-edge gap (mm) from the signal trace to its
    /// ground pour. Positive selects grounded-coplanar analysis on outer
    /// layers and overrides the ground pour's ordinary clearance for this net.
    ground_gap_mm: f64 = 0,
    /// Optional upper bound for locally widening `ground_gap_mm` as a routed
    /// trace tapers into a wider pad. 0 keeps the gap fixed; a positive value
    /// enables per-section 50-ohm synthesis up to this setback.
    ground_gap_max_mm: f64 = 0,
    /// True when the net's track width was SOLVED from `ohms` against the
    /// board's `(stackup …)` rather than authored. This is what separates
    /// "derive my width" from "check my width": an authored width always wins,
    /// and only an authored one can mismatch its target.
    width_derived: bool = false,
};

/// One dielectric interval of the buildup: the gap immediately below copper
/// layer `after_layer` (1-based), its thickness and its permittivity.
pub const Dielectric = struct { after_layer: u8, thickness_mm: f64, er: f64 };

/// One copper foil of the buildup.
pub const Foil = struct {
    index: u8,
    thickness_mm: f64,
    width_reduction_mm: f64 = 0,
    narrow_up: bool = true,
};

/// Stepped outer-face soldermask cross-section. `substrate_mm` is its height
/// above bare laminate/between traces; `copper_mm` is coating above the trace.
pub const Mask = struct {
    top: bool,
    er: f64,
    substrate_mm: f64,
    copper_mm: f64,
};

/// The board buildup as this module needs to see it — the placement-side
/// mirror of `(stackup …)`, carrying only what Z₀ depends on. `layers` = 0
/// means no stackup was declared, and every query returns null.
pub const Stack = struct {
    layers: u8 = 0,
    /// 1-based copper indices declared as reference planes. An outer index is
    /// a poured signal face: it can reference another layer while still
    /// carrying routed traces itself. Only inner plane indices are dedicated
    /// plane-only layers.
    planes: []const u8 = &.{},
    /// Authored dielectric intervals. May be empty — see `gapMm`.
    dielectrics: []const Dielectric = &.{},
    /// Authored copper foils. May be empty — `default_foil_mm` then applies.
    foils: []const Foil = &.{},
    /// Optional outer-face coating process profiles.
    masks: []const Mask = &.{},
    /// Finished board thickness (mm) from `(stackup … (thickness MM))`;
    /// 0 = unset, and `default_board_mm` applies to the uniform fallback.
    board_mm: f64 = 0,

    /// True when NO dielectric interval was authored, so every height below is
    /// synthesised by spreading the finished board thickness evenly over the
    /// gaps. Surfaces mark such a row "assumed" — the number is an ordinary
    /// fab default, not something the design stated.
    pub fn assumed(self: Stack) bool {
        return self.dielectrics.len == 0;
    }

    /// Copper foil thickness (mm) of layer `index`.
    pub fn foilMm(self: Stack, index: u8) f64 {
        for (self.foils) |f| if (f.index == index) return f.thickness_mm;
        return default_foil_mm;
    }

    /// Complete foil/process profile for `index`, with the standard fallback.
    pub fn foil(self: Stack, index: u8) Foil {
        for (self.foils) |f| if (f.index == index) return f;
        return .{ .index = index, .thickness_mm = default_foil_mm };
    }

    /// Soldermask profile on an outer layer, or null for an uncoated face.
    pub fn mask(self: Stack, layer: u8) ?Mask {
        if (layer != 1 and layer != self.layers) return null;
        const top = layer == 1;
        for (self.masks) |m| if (m.top == top) return m;
        return null;
    }

    /// True when copper layer `index` is a declared reference plane.
    pub fn isPlane(self: Stack, index: u8) bool {
        for (self.planes) |p| if (p == index) return true;
        return false;
    }

    /// Thickness (mm) of the dielectric gap below copper layer `after`.
    /// Falls back to a uniform buildup: the finished board thickness less every
    /// foil, spread evenly over the `layers − 1` gaps.
    pub fn gapMm(self: Stack, after: u8) f64 {
        for (self.dielectrics) |d| if (d.after_layer == after) return d.thickness_mm;
        if (self.layers < 2) return 0;
        const board = if (self.board_mm > 0) self.board_mm else default_board_mm;
        var copper: f64 = 0;
        var i: u8 = 1;
        while (i <= self.layers) : (i += 1) copper += self.foilMm(i);
        const dielectric = board - copper;
        if (!(dielectric > 0)) return 0;
        return dielectric / @as(f64, @floatFromInt(self.layers - 1));
    }

    /// Permittivity of the dielectric gap below copper layer `after`.
    pub fn gapEr(self: Stack, after: u8) f64 {
        for (self.dielectrics) |d| if (d.after_layer == after) return d.er;
        return default_er;
    }
};

/// Process-aware result used by synthesis, lint and routed-line analysis.
pub const ProcessResult = struct { z0_ohms: f64, er_eff: f64 };

/// Nominal coating state implied by the mask-artwork class policy. Positive or
/// default RF relief exposes copper; explicit zero and ordinary classes remain
/// coated. Geometry-local pad dams do not change the trunk calculation.
pub fn traceIsCoated(mask_relief_mm: f64, max_freq_hz: f64) bool {
    if (mask_relief_mm >= 0) return mask_relief_mm == 0;
    return max_freq_hz <= 0;
}

/// Even/odd result for a broadside-coupled pair on two copper layers.
pub const BroadsideResult = struct {
    odd_ohms: f64,
    even_ohms: f64,
    diff_ohms: f64,
    common_ohms: f64,
    odd_er_eff: f64,
    even_er_eff: f64,
};

/// Two-layer broadside pair geometry, including lateral registration offset.
pub const BroadsideGeometry = struct {
    upper_layer: u8,
    lower_layer: u8,
    upper_width_mm: f64,
    lower_width_mm: f64,
    offset_mm: f64 = 0,
};

const CrossSection = struct {
    bands: [64]field.Band = @splat(.{ .y_min = 0, .y_max = 0, .er = 1 }),
    band_count: usize = 0,
    regions: [8]field.Region = @splat(.{ .x_min = 0, .x_max = 0, .y_min = 0, .y_max = 0, .er = 1 }),
    region_count: usize = 0,
    conductors: [6]field.Conductor = @splat(.{
        .x_center = 0,
        .y_min = 0,
        .y_max = 0,
        .width_bottom = 0,
        .width_top = 0,
        .terminal = 0,
    }),
    conductor_count: usize = 0,
    x_half: f64 = 0,
    y_min: f64 = 0,
    y_max: f64 = 0,

    fn geometry(self: *const CrossSection) field.Geometry {
        return .{
            .x_half = self.x_half,
            .y_min = self.y_min,
            .y_max = self.y_max,
            .bands = self.bands[0..self.band_count],
            .regions = self.regions[0..self.region_count],
            .conductors = self.conductors[0..self.conductor_count],
        };
    }

    fn band(self: *CrossSection, y_min: f64, y_max: f64, er: f64) bool {
        if (self.band_count >= self.bands.len) return false;
        if (!(y_max > y_min) or !validEr(er)) return false;
        self.bands[self.band_count] = .{ .y_min = y_min, .y_max = y_max, .er = er };
        self.band_count += 1;
        return true;
    }

    fn conductor(self: *CrossSection, c: field.Conductor) bool {
        if (self.conductor_count >= self.conductors.len) return false;
        self.conductors[self.conductor_count] = c;
        self.conductor_count += 1;
        return true;
    }
};

fn trapezoid(foil: Foil, layer: u8, layers: u8, width: f64) ?struct { bottom: f64, top: f64 } {
    if (!positive(width) or foil.width_reduction_mm < 0) return null;
    if (foil.width_reduction_mm >= width) return null;
    const narrow_local_top = if (layer == 1)
        foil.narrow_up
    else if (layer == layers)
        !foil.narrow_up
    else
        foil.narrow_up;
    const narrow = width - foil.width_reduction_mm;
    return if (narrow_local_top)
        .{ .bottom = width, .top = narrow }
    else
        .{ .bottom = narrow, .top = width };
}

const SignalSpec = struct { x: f64, y: f64, width: f64, terminal: u8 };

fn addSignal(cs: *CrossSection, foil: Foil, layer: u8, layers: u8, signal: SignalSpec) bool {
    const widths = trapezoid(foil, layer, layers, signal.width) orelse return false;
    return cs.conductor(.{
        .x_center = signal.x,
        .y_min = signal.y,
        .y_max = signal.y + foil.thickness_mm,
        .width_bottom = widths.bottom,
        .width_top = widths.top,
        .terminal = signal.terminal,
    });
}

fn addCoplanarGround(cs: *CrossSection, width: f64, gap: f64, foil: Foil, layer: u8, layers: u8) bool {
    if (!(gap > 0)) return true;
    const edge = width / 2 + gap;
    if (!(cs.x_half > edge)) return false;
    const side_width = cs.x_half - edge;
    const widths = trapezoid(foil, layer, layers, side_width) orelse return false;
    return cs.conductor(.{
        .x_center = -(edge + side_width / 2),
        .y_min = 0,
        .y_max = foil.thickness_mm,
        .width_bottom = widths.bottom,
        .width_top = widths.top,
        .terminal = 0,
    }) and cs.conductor(.{
        .x_center = edge + side_width / 2,
        .y_min = 0,
        .y_max = foil.thickness_mm,
        .width_bottom = widths.bottom,
        .width_top = widths.top,
        .terminal = 0,
    });
}

fn addMask(cs: *CrossSection, mask: Mask, trace_centers: []const f64, width: f64, t: f64) bool {
    if (cs.region_count >= cs.regions.len or !validEr(mask.er)) return false;
    // The base coat spans the whole laminate/trace gap. Local over-trace
    // rectangles extend it to the separately published copper-coat height.
    if (!cs.band(0, mask.substrate_mm, mask.er)) return false;
    for (trace_centers) |center| {
        if (cs.region_count >= cs.regions.len) return false;
        cs.regions[cs.region_count] = .{
            .x_min = center - width / 2,
            .x_max = center + width / 2,
            .y_min = t,
            .y_max = t + mask.copper_mm,
            .er = mask.er,
        };
        cs.region_count += 1;
    }
    return true;
}

const SectionOptions = struct { pair_gap: ?f64, ground_gap: f64, coated: bool, ideal: bool };

fn makeOuterSection(stack: Stack, layer: u8, width: f64, options: SectionOptions) ?CrossSection {
    const ref = reference(stack, layer) orelse return null;
    const m = switch (ref) {
        .microstrip => |v| v,
        else => return null,
    };
    const foil = stack.foil(layer);
    const span_x = if (options.pair_gap) |g| 2 * width + g else width + 2 * options.ground_gap;
    var cs = CrossSection{};
    cs.x_half = @max(6 * m.h_mm, 4 * span_x);
    cs.y_min = -m.h_mm;
    cs.y_max = foil.thickness_mm + @max(4 * m.h_mm, 4 * (stack.mask(layer) orelse Mask{ .top = true, .er = 1, .substrate_mm = 0, .copper_mm = 0 }).copper_mm);
    if (!cs.band(-m.h_mm, 0, m.er)) return null;
    const use_foil = if (options.ideal) Foil{ .index = layer, .thickness_mm = foil.thickness_mm } else foil;
    if (options.pair_gap) |g| {
        const center = (width + g) / 2;
        if (!addSignal(&cs, use_foil, layer, stack.layers, .{ .x = -center, .y = 0, .width = width, .terminal = 1 })) return null;
        if (!addSignal(&cs, use_foil, layer, stack.layers, .{ .x = center, .y = 0, .width = width, .terminal = 2 })) return null;
        if (options.coated and !options.ideal) if (stack.mask(layer)) |mask| {
            if (!addMask(&cs, mask, &.{ -center, center }, width, foil.thickness_mm)) return null;
        };
    } else {
        if (!addSignal(&cs, use_foil, layer, stack.layers, .{ .x = 0, .y = 0, .width = width, .terminal = 1 })) return null;
        if (!addCoplanarGround(&cs, width, options.ground_gap, use_foil, layer, stack.layers)) return null;
        if (options.coated and !options.ideal) if (stack.mask(layer)) |mask| {
            if (!addMask(&cs, mask, &.{0}, width, foil.thickness_mm)) return null;
        };
    }
    return cs;
}

fn makeInnerSection(stack: Stack, layer: u8, width: f64, options: SectionOptions) ?CrossSection {
    const ref = reference(stack, layer) orelse return null;
    const s = switch (ref) {
        .stripline => |v| v,
        else => return null,
    };
    const pa = nearestPlane(stack, layer, true) orelse return null;
    const pb = nearestPlane(stack, layer, false) orelse return null;
    const foil = stack.foil(layer);
    const span_x = if (options.pair_gap) |g| 2 * width + g else width;
    var cs = CrossSection{};
    cs.x_half = @max(3 * @max(s.h1_mm, s.h2_mm), 4 * span_x);
    cs.y_min = -s.h2_mm;
    cs.y_max = foil.thickness_mm + s.h1_mm;
    if (options.ideal) {
        if (!cs.band(cs.y_min, 0, s.er)) return null;
        if (!cs.band(foil.thickness_mm, cs.y_max, s.er)) return null;
    } else {
        var y = foil.thickness_mm;
        var i = layer - 1;
        while (true) {
            const er = stack.gapEr(i);
            const gap = stack.gapMm(i);
            if (!cs.band(y, y + gap, er)) return null;
            y += gap;
            if (i == pa) break;
            const buried = stack.foilMm(i);
            if (!cs.band(y, y + buried, er)) return null;
            y += buried;
            i -= 1;
        }
        y = 0;
        i = layer;
        while (true) {
            const er = stack.gapEr(i);
            const gap = stack.gapMm(i);
            if (!cs.band(y - gap, y, er)) return null;
            y -= gap;
            if (i + 1 == pb) break;
            const buried = stack.foilMm(i + 1);
            if (!cs.band(y - buried, y, er)) return null;
            y -= buried;
            i += 1;
        }
    }
    const use_foil = if (options.ideal) Foil{ .index = layer, .thickness_mm = foil.thickness_mm } else foil;
    if (options.pair_gap) |g| {
        const center = (width + g) / 2;
        if (!addSignal(&cs, use_foil, layer, stack.layers, .{ .x = -center, .y = 0, .width = width, .terminal = 1 })) return null;
        if (!addSignal(&cs, use_foil, layer, stack.layers, .{ .x = center, .y = 0, .width = width, .terminal = 2 })) return null;
    } else if (!addSignal(&cs, use_foil, layer, stack.layers, .{ .x = 0, .y = 0, .width = width, .terminal = 1 })) return null;
    return cs;
}

fn layerY(stack: Stack, plane_above: u8, target: u8) ?f64 {
    if (target <= plane_above) return null;
    var y: f64 = 0;
    var i = plane_above;
    while (i < target) : (i += 1) {
        y += stack.gapMm(i);
        if (i + 1 == target) return y;
        y += stack.foilMm(i + 1);
    }
    return null;
}

/// Numerical broadside-coupled pair analysis. The two signal layers must share
/// one enclosing plane above and below with no intervening reference plane.
/// `offset_mm` is their lateral centreline registration error (zero = aligned).
pub fn broadsideDiffZ0(
    allocator: std.mem.Allocator,
    stack: Stack,
    geometry: BroadsideGeometry,
) ?BroadsideResult {
    const upper_layer = geometry.upper_layer;
    const lower_layer = geometry.lower_layer;
    const upper_width_mm = geometry.upper_width_mm;
    const lower_width_mm = geometry.lower_width_mm;
    const offset_mm = geometry.offset_mm;
    if (!(upper_layer < lower_layer) or !std.math.isFinite(offset_mm)) return null;
    if (stack.isPlane(upper_layer) or stack.isPlane(lower_layer)) return null;
    const pa = nearestPlane(stack, upper_layer, true) orelse return null;
    const pb = nearestPlane(stack, lower_layer, false) orelse return null;
    var p = pa + 1;
    while (p < pb) : (p += 1) if (stack.isPlane(p)) return null;
    const yu = layerY(stack, pa, upper_layer) orelse return null;
    const yl = layerY(stack, pa, lower_layer) orelse return null;
    const enclosure = layerY(stack, pa, pb) orelse return null;
    var cs = CrossSection{};
    const span_x = @max(upper_width_mm, lower_width_mm) + @abs(offset_mm);
    cs.x_half = @max(3 * enclosure, 5 * span_x);
    cs.y_min = 0;
    cs.y_max = enclosure;
    var y: f64 = 0;
    var i = pa;
    while (i < pb) : (i += 1) {
        const er = stack.gapEr(i);
        const gap = stack.gapMm(i);
        if (!cs.band(y, y + gap, er)) return null;
        y += gap;
        if (i + 1 < pb) {
            const buried = stack.foilMm(i + 1);
            if (!cs.band(y, y + buried, er)) return null;
            y += buried;
        }
    }
    const fu = stack.foil(upper_layer);
    const fl = stack.foil(lower_layer);
    const wu = trapezoid(fu, upper_layer, stack.layers, upper_width_mm) orelse return null;
    const wl = trapezoid(fl, lower_layer, stack.layers, lower_width_mm) orelse return null;
    if (!cs.conductor(.{
        .x_center = 0,
        .y_min = yu,
        .y_max = yu + fu.thickness_mm,
        .width_bottom = wu.bottom,
        .width_top = wu.top,
        .terminal = 1,
    })) return null;
    if (!cs.conductor(.{
        .x_center = offset_mm,
        .y_min = yl,
        .y_max = yl + fl.thickness_mm,
        .width_bottom = wl.bottom,
        .width_top = wl.top,
        .terminal = 2,
    })) return null;
    const result = field.analyze(allocator, cs.geometry()) catch return null;
    const pair = result.pair orelse return null;
    return .{
        .odd_ohms = pair.odd_ohms,
        .even_ohms = pair.even_ohms orelse return null,
        .diff_ohms = pair.diff_ohms,
        .common_ohms = pair.common_ohms orelse return null,
        .odd_er_eff = pair.odd_er_eff,
        .even_er_eff = pair.even_er_eff orelse return null,
    };
}

fn needsField(stack: Stack, layer: u8, coated: bool) bool {
    if (stack.foil(layer).width_reduction_mm > 0) return true;
    if (coated and stack.mask(layer) != null) return true;
    const ref = reference(stack, layer) orelse return false;
    if (ref == .microstrip) return false;
    const pa = nearestPlane(stack, layer, true) orelse return false;
    const pb = nearestPlane(stack, layer, false) orelse return false;
    const first = stack.gapEr(pa);
    var i = pa + 1;
    while (i < pb) : (i += 1) if (@abs(stack.gapEr(i) - first) > 1e-12) return true;
    return false;
}

fn fieldSection(stack: Stack, layer: u8, width: f64, options: SectionOptions) ?CrossSection {
    const ref = reference(stack, layer) orelse return null;
    return switch (ref) {
        .microstrip => makeOuterSection(stack, layer, width, options),
        .stripline => makeInnerSection(stack, layer, width, options),
    };
}

/// Process-aware single-ended analysis on one physical copper layer. Bare,
/// rectangular, homogeneous cases remain exactly on the published closed form;
/// only additional fabrication effects are obtained from the calibrated field
/// ratio. `coated` means the class's generated mask artwork covers the trace.
pub fn analyzeOnLayer(
    allocator: std.mem.Allocator,
    stack: Stack,
    layer: u8,
    width_mm: f64,
    ground_gap_mm: f64,
    coated: bool,
) ?ProcessResult {
    const ref = reference(stack, layer) orelse return null;
    const foil = stack.foil(layer);
    const base_z = refZ0WithGroundGap(ref, width_mm, foil.thickness_mm, ground_gap_mm) catch return null;
    const base_er = refEffectiveErWithGroundGap(ref, width_mm, foil.thickness_mm, ground_gap_mm) catch return null;
    if (!needsField(stack, layer, coated)) return .{ .z0_ohms = base_z, .er_eff = base_er };
    const actual_cs = fieldSection(stack, layer, width_mm, .{ .pair_gap = null, .ground_gap = ground_gap_mm, .coated = coated, .ideal = false }) orelse return null;
    const ideal_cs = fieldSection(stack, layer, width_mm, .{ .pair_gap = null, .ground_gap = ground_gap_mm, .coated = false, .ideal = true }) orelse return null;
    const actual = field.analyze(allocator, actual_cs.geometry()) catch return null;
    const ideal = field.analyze(allocator, ideal_cs.geometry()) catch return null;
    const actual_single = actual.single orelse return null;
    const ideal_single = ideal.single orelse return null;
    return .{
        .z0_ohms = base_z * actual_single.ohms / ideal_single.ohms,
        .er_eff = base_er * actual_single.er_eff / ideal_single.er_eff,
    };
}

/// Process-aware edge-coupled differential analysis (`Zdiff = 2*Zodd`).
pub fn analyzeDiffOnLayer(
    allocator: std.mem.Allocator,
    stack: Stack,
    layer: u8,
    width_mm: f64,
    pair_gap_mm: f64,
    coated: bool,
) ?ProcessResult {
    const ref = reference(stack, layer) orelse return null;
    const foil = stack.foil(layer);
    const base_z = refDiffZ0(ref, width_mm, foil.thickness_mm, pair_gap_mm) catch return null;
    const base_er = refDiffEffectiveErOdd(ref, width_mm, foil.thickness_mm, pair_gap_mm) catch return null;
    if (!needsField(stack, layer, coated)) return .{ .z0_ohms = base_z, .er_eff = base_er };
    const actual_cs = fieldSection(stack, layer, width_mm, .{ .pair_gap = pair_gap_mm, .ground_gap = 0, .coated = coated, .ideal = false }) orelse return null;
    const ideal_cs = fieldSection(stack, layer, width_mm, .{ .pair_gap = pair_gap_mm, .ground_gap = 0, .coated = false, .ideal = true }) orelse return null;
    const actual = field.analyzeOdd(allocator, actual_cs.geometry()) catch return null;
    const ideal = field.analyzeOdd(allocator, ideal_cs.geometry()) catch return null;
    const actual_pair = actual.pair orelse return null;
    const ideal_pair = ideal.pair orelse return null;
    return .{
        .z0_ohms = base_z * actual_pair.diff_ohms / ideal_pair.diff_ohms,
        .er_eff = base_er * actual_pair.odd_er_eff / ideal_pair.odd_er_eff,
    };
}

/// Thickness and thickness-weighted permittivity of the dielectric spanning
/// copper layers `a`..`b` (exclusive of both foils, inclusive of any copper
/// foil trapped between them — a plane two gaps away is genuinely that far).
fn span(stack: Stack, a: u8, b: u8) struct { h: f64, er: f64 } {
    const lo = @min(a, b);
    const hi = @max(a, b);
    var h: f64 = 0;
    var dielectric: f64 = 0;
    var weighted: f64 = 0;
    var i = lo;
    while (i < hi) : (i += 1) {
        const t = stack.gapMm(i);
        h += t;
        dielectric += t;
        weighted += t * stack.gapEr(i);
        if (i + 1 < hi) h += stack.foilMm(i + 1); // buried foil in the span
    }
    // `h` is the full physical separation (foils included — they really do push
    // the planes apart), but the permittivity average is weighted by DIELECTRIC
    // thickness only. Counting a copper foil as a zero-εr slab would drag the
    // mix down (barracuda's bottom face read 4.35 instead of its uniform 4.40).
    return .{ .h = h, .er = if (dielectric > 0) weighted / dielectric else default_er };
}

/// Nearest declared plane above (`.up` = toward layer 1) or below `layer`.
fn nearestPlane(stack: Stack, layer: u8, comptime up: bool) ?u8 {
    var i = layer;
    while (true) {
        if (up) {
            if (i <= 1) return null;
            i -= 1;
        } else {
            if (i >= stack.layers) return null;
            i += 1;
        }
        if (stack.isPlane(i)) return i;
    }
}

/// The reference geometry copper layer `layer` (1-based) presents, or null when
/// the layer is a dedicated inner plane, is outside the stack, or has no usable
/// reference (no plane at all; an inner layer with a plane on only one side).
/// A declared outer plane is a pour rather than a plane-only routing layer, so
/// it remains eligible for microstrip just like the router's outer faces.
pub fn reference(stack: Stack, layer: u8) ?Ref {
    if (stack.layers == 0 or layer == 0 or layer > stack.layers) return null;
    const outer = layer == 1 or layer == stack.layers;
    if (stack.isPlane(layer) and !outer) return null;
    const above = nearestPlane(stack, layer, true);
    const below = nearestPlane(stack, layer, false);
    if (outer) {
        // An outer face has air on one side: microstrip over whichever plane
        // exists on the copper side.
        const p = above orelse below orelse return null;
        const s = span(stack, layer, p);
        if (!(s.h > 0)) return null;
        return .{ .microstrip = .{ .h_mm = s.h, .er = s.er } };
    }
    const pa = above orelse return null;
    const pb = below orelse return null;
    const sa = span(stack, layer, pa);
    const sb = span(stack, layer, pb);
    if (!(sa.h > 0) or !(sb.h > 0)) return null;
    const h_total = sa.h + sb.h;
    const er_mix = (sa.h * sa.er + sb.h * sb.er) / h_total;
    return .{ .stripline = .{ .h1_mm = sa.h, .h2_mm = sb.h, .er = er_mix } };
}

/// Every signal layer of the stack that has a usable reference, lowest index
/// first. Writes into `out` (caller-sized, `stack.layers` is always enough) and
/// returns the filled prefix — no allocation, so any surface can call it.
pub fn signalLayers(stack: Stack, out: []u8) []const u8 {
    var n: usize = 0;
    var i: u8 = 1;
    while (i <= stack.layers and n < out.len) : (i += 1) {
        if (reference(stack, i) == null) continue;
        out[n] = i;
        n += 1;
    }
    return out[0..n];
}

/// The layer a class's derived width resolves against: the FIRST signal layer
/// with a usable reference (lowest copper index, so an ordinary board resolves
/// on the top face — where a controlled-impedance run is normally kept). Null
/// when the stack offers none.
pub fn preferredLayer(stack: Stack) ?u8 {
    var i: u8 = 1;
    while (i <= stack.layers) : (i += 1) {
        if (reference(stack, i) != null) return i;
    }
    return null;
}

/// Resolve an optional authored layer against this stack. An explicit layer
/// must itself be a signal layer with a usable reference; it never falls back
/// silently to some other geometry.
pub fn targetLayer(stack: Stack, authored: u8) ?u8 {
    if (authored == 0) return preferredLayer(stack);
    if (reference(stack, authored) == null) return null;
    return authored;
}

/// The width (mm) a class targeting `target_ohms` resolves to on this stack:
/// solved on `preferredLayer`. Null when the stack has no usable reference or
/// the target is unreachable there — the caller then keeps the authored /
/// default width and says so.
pub fn resolvedWidthMm(stack: Stack, target_ohms: f64) ?f64 {
    return resolvedWidthMmWithGroundGap(stack, target_ohms, 0);
}

/// `resolvedWidthMm` with a same-layer grounded-coplanar gap on outer faces.
pub fn resolvedWidthMmWithGroundGap(stack: Stack, target_ohms: f64, ground_gap_mm: f64) ?f64 {
    return resolvedWidthMmOnLayerWithGroundGap(stack, 0, target_ohms, ground_gap_mm);
}

/// Single-ended synthesis on an explicit layer (`layer = 0` keeps the
/// preferred-layer behavior used by the original DSL form).
pub fn resolvedWidthMmOnLayerWithGroundGap(
    stack: Stack,
    layer: u8,
    target_ohms: f64,
    ground_gap_mm: f64,
) ?f64 {
    const resolved_layer = targetLayer(stack, layer) orelse return null;
    const ref = reference(stack, resolved_layer) orelse return null;
    const w = refWidthForZ0WithGroundGap(ref, target_ohms, stack.foilMm(resolved_layer), ground_gap_mm) catch return null;
    return w;
}

/// Differential synthesis on an explicit inner signal layer.
pub fn resolvedDiffWidthMmOnLayer(
    stack: Stack,
    layer: u8,
    target_ohms: f64,
    pair_gap_mm: f64,
) ?f64 {
    const resolved_layer = targetLayer(stack, layer) orelse return null;
    const ref = reference(stack, resolved_layer) orelse return null;
    return refWidthForDiffZ0(ref, target_ohms, stack.foilMm(resolved_layer), pair_gap_mm) catch null;
}

/// Process-aware inverse for single-ended width synthesis. A safeguarded
/// secant correction converges the calibrated field/closed-form ratio while
/// retaining the best sub-percent result when the finite grid quantizes a
/// conductor edge. The final forward solve is the same one reports use.
pub fn resolvedWidthMmOnLayerWithProcess(
    allocator: std.mem.Allocator,
    stack: Stack,
    layer: u8,
    target_ohms: f64,
    ground_gap_mm: f64,
    coated: bool,
) ?f64 {
    const resolved_layer = targetLayer(stack, layer) orelse return null;
    const ref = reference(stack, resolved_layer) orelse return null;
    const t = stack.foilMm(resolved_layer);
    var width = refWidthForZ0WithGroundGap(ref, target_ohms, t, ground_gap_mm) catch return null;
    if (!needsField(stack, resolved_layer, coated)) return width;
    var previous_width: ?f64 = null;
    var previous_error: f64 = 0;
    var best_width = width;
    var best_error = std.math.inf(f64);
    for (0..5) |_| {
        const process = analyzeOnLayer(allocator, stack, resolved_layer, width, ground_gap_mm, coated) orelse return null;
        const err = process.z0_ohms - target_ohms;
        if (@abs(err) < best_error) {
            best_error = @abs(err);
            best_width = width;
        }
        if (@abs(err) <= 0.01) return width;
        const closed = refZ0WithGroundGap(ref, width, t, ground_gap_mm) catch return null;
        const ratio = process.z0_ohms / closed;
        if (!positive(ratio)) return null;
        const ratio_width = refWidthForZ0WithGroundGap(ref, target_ohms / ratio, t, ground_gap_mm) catch return null;
        var next = ratio_width;
        if (previous_width) |prev| {
            const denom = err - previous_error;
            if (@abs(denom) > 1e-9) {
                const secant = width - err * (width - prev) / denom;
                if (positive(secant)) next = secant;
            }
        }
        next = std.math.clamp(next, width * 0.5, width * 1.5);
        next = @max(next, stack.foil(resolved_layer).width_reduction_mm * 1.01);
        previous_width = width;
        previous_error = err;
        width = next;
    }
    return if (best_error <= target_ohms * 0.01) best_width else null;
}

/// Process-aware inverse for edge-coupled differential width synthesis.
pub fn resolvedDiffWidthMmOnLayerWithProcess(
    allocator: std.mem.Allocator,
    stack: Stack,
    layer: u8,
    target_ohms: f64,
    pair_gap_mm: f64,
    coated: bool,
) ?f64 {
    const resolved_layer = targetLayer(stack, layer) orelse return null;
    const ref = reference(stack, resolved_layer) orelse return null;
    const t = stack.foilMm(resolved_layer);
    var width = refWidthForDiffZ0(ref, target_ohms, t, pair_gap_mm) catch return null;
    if (!needsField(stack, resolved_layer, coated)) return width;
    var previous_width: ?f64 = null;
    var previous_error: f64 = 0;
    var best_width = width;
    var best_error = std.math.inf(f64);
    for (0..5) |_| {
        const process = analyzeDiffOnLayer(allocator, stack, resolved_layer, width, pair_gap_mm, coated) orelse return null;
        const err = process.z0_ohms - target_ohms;
        if (@abs(err) < best_error) {
            best_error = @abs(err);
            best_width = width;
        }
        if (@abs(err) <= 0.01) return width;
        const closed = refDiffZ0(ref, width, t, pair_gap_mm) catch return null;
        const ratio = process.z0_ohms / closed;
        if (!positive(ratio)) return null;
        const ratio_width = refWidthForDiffZ0(ref, target_ohms / ratio, t, pair_gap_mm) catch return null;
        var next = ratio_width;
        if (previous_width) |prev| {
            const denom = err - previous_error;
            if (@abs(denom) > 1e-9) {
                const secant = width - err * (width - prev) / denom;
                if (positive(secant)) next = secant;
            }
        }
        // Keep the next field solve inside the same local closed-form domain;
        // this also damps grid-scale discontinuities in very thin coatings.
        next = std.math.clamp(next, width * 0.5, width * 1.5);
        next = @max(next, stack.foil(resolved_layer).width_reduction_mm * 1.01);
        previous_width = width;
        previous_error = err;
        width = next;
    }
    return if (best_error <= target_ohms * 0.01) best_width else null;
}

/// How far (%) the impedance of a `w_mm` trace on `layer` sits from
/// `target_ohms`. Null when it cannot be computed there.
pub fn mismatchPct(stack: Stack, layer: u8, w_mm: f64, target_ohms: f64) ?f64 {
    return mismatchPctWithGroundGap(stack, layer, w_mm, target_ohms, 0);
}

/// `mismatchPct` with grounded-coplanar analysis on outer layers.
pub fn mismatchPctWithGroundGap(stack: Stack, layer: u8, w_mm: f64, target_ohms: f64, ground_gap_mm: f64) ?f64 {
    if (!(target_ohms > 0)) return null;
    const ref = reference(stack, layer) orelse return null;
    const z = refZ0WithGroundGap(ref, w_mm, stack.foilMm(layer), ground_gap_mm) catch return null;
    return @abs(z - target_ohms) / target_ohms * 100.0;
}

/// Differential mismatch at one authored width/gap on one layer.
pub fn diffMismatchPct(stack: Stack, layer: u8, w_mm: f64, pair_gap_mm: f64, target_ohms: f64) ?f64 {
    if (!(target_ohms > 0)) return null;
    const ref = reference(stack, layer) orelse return null;
    const z = refDiffZ0(ref, w_mm, stack.foilMm(layer), pair_gap_mm) catch return null;
    return @abs(z - target_ohms) / target_ohms * 100.0;
}

/// The tolerance band an authored `(width …)` may miss its class's
/// `(impedance …)` by before `impedance_mismatch` fires. 5 % is the loosest
/// band a fab will quote for controlled impedance (±10 % is the standard
/// offering, ±5 % the tightened one), so a width that misses by more than this
/// was not chosen for the target on this stackup.
pub const mismatch_tolerance_pct: f64 = 5.0;

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A plain 1.6 mm two-layer FR-4 board: signal on top, plane on the bottom.
fn twoLayerFr4() Stack {
    return .{
        .layers = 2,
        .planes = &.{2},
        .dielectrics = &.{.{ .after_layer = 1, .thickness_mm = 1.6, .er = 4.4 }},
        .foils = &.{ .{ .index = 1, .thickness_mm = 0.035 }, .{ .index = 2, .thickness_mm = 0.035 } },
    };
}

// spec: placement/impedance - microstrip Z0 matches the published 50 ohm width on 1.6 mm FR-4
test "50 ohm microstrip on 1.6 mm FR-4 er 4.4 is about 3.0 mm wide" {
    // Published reference point: a 50 Ω microstrip on 1.6 mm FR-4 (εr 4.4,
    // 1 oz copper) is ~3.0 mm wide — the figure the standard calculators and
    // Hammerstad's own worked example agree on. This model says 3.0215 mm,
    // i.e. 0.7 % from the nominal; hold it to ±5 % of 3.0 so a formula change
    // that drifted off the published answer would fail here.
    const w = try refWidthForZ0(.{ .microstrip = .{ .h_mm = 1.6, .er = 4.4 } }, 50.0, 0.035);
    try testing.expectApproxEqAbs(@as(f64, 3.0), w, 0.15);
    // Forward direction at the nominal 3.0 mm: 50.21 Ω.
    const z = try microstripZ0(3.0, 1.6, 0.035, 4.4);
    try testing.expectApproxEqAbs(@as(f64, 50.0), z, 1.0);
}

// spec: placement/impedance - microstrip Z0 matches the published 50 ohm width on thin prepreg
test "50 ohm microstrip on 0.2 mm prepreg er 4.4 is about 0.36 mm wide" {
    // The four-layer counterpart: a 50 Ω top-layer run over a 0.2 mm prepreg
    // to the plane below is ~0.36 mm wide (the standard 4-layer 1.6 mm FR-4
    // controlled-impedance figure fabs quote). This model says 0.3471 mm —
    // 3.6 % under the quoted nominal, the expected spread between thickness
    // corrections at t/h = 0.175. Hold it to ±10 % of 0.36.
    const w = try refWidthForZ0(.{ .microstrip = .{ .h_mm = 0.2, .er = 4.4 } }, 50.0, 0.035);
    try testing.expectApproxEqAbs(@as(f64, 0.36), w, 0.036);
}

// spec: placement/impedance - width solved from a target Z0 round-trips back to that Z0
test "width -> Z0 -> width is a fixed point" {
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.2104, .er = 4.4 } };
    for ([_]f64{ 40.0, 50.0, 60.0, 75.0 }) |target| {
        const w = try refWidthForZ0(ref, target, 0.035);
        const z = try refZ0(ref, w, 0.035);
        try testing.expectApproxEqAbs(target, z, 0.01);
        const again = try refWidthForZ0(ref, z, 0.035);
        try testing.expectApproxEqRel(w, again, 1e-6);
    }
}

// spec: placement/impedance - a stripline is narrower than a microstrip of the same impedance
test "stripline and microstrip diverge for the same target" {
    // Same dielectric height to the reference plane, same target: the stripline
    // is enclosed (no air return path, so a higher effective permittivity and a
    // lower impedance per unit width) and must come out NARROWER.
    const h = 0.2104;
    const ms: Ref = .{ .microstrip = .{ .h_mm = h, .er = 4.4 } };
    const sl: Ref = .{ .stripline = .{ .h1_mm = h, .h2_mm = h, .er = 4.4 } };
    const w_ms = try refWidthForZ0(ms, 50.0, 0.0152);
    const w_sl = try refWidthForZ0(sl, 50.0, 0.0152);
    try testing.expect(w_sl < w_ms);
    // And the impedances genuinely differ at one common width.
    const z_ms = try refZ0(ms, 0.2, 0.0152);
    const z_sl = try refZ0(sl, 0.2, 0.0152);
    try testing.expect(z_ms > z_sl);
}

// spec: placement/impedance - the symmetric stripline reduces to Cohn's published formula
test "zero-thickness symmetric stripline equals Cohn's exact elliptic result" {
    const w = 0.2;
    const h = 0.4;
    const er = 4.4;
    // Independent AGM evaluation of Cohn's K(k')/K(k) reference vector.
    try testing.expectApproxEqAbs(
        @as(f64, 30.244372037271955),
        try striplineZ0(w, h, h, 0, er),
        1e-12,
    );
}

test "finite-thickness narrow stripline uses the Cohn-Wadell reduction" {
    const w = 0.2;
    const h = 0.4;
    const t = 0.035;
    const er = 4.4;
    const b = 2.0 * h + t;
    const want = (60.0 / @sqrt(er)) * @log(4.0 * b / (0.67 * std.math.pi * (0.8 * w + t)));
    try testing.expectApproxEqRel(want, try striplineZ0(w, h, h, t, er), 1e-12);
}

// spec: placement/impedance - the narrow and wide stripline branches are blended into one continuous monotonic curve
test "the stripline branch blend is continuous and monotonic across the crossover" {
    // b chosen so the 0.30/0.40 blend band spans a convenient width range.
    const b = 1.0;
    const t = 0.035;
    const h = (b - t) / 2.0;
    const er = 4.4;
    // Sweep W through the whole band and out both sides: Z must fall at every
    // step (the property the inverse bisection relies on) with no jump at the
    // two branch seams.
    // Every step is inside both branches' domain, so nothing is skipped.
    var prev = try striplineZ0(0.05, h, h, t, er);
    for (1..201) |i| {
        const w = 0.05 + 0.005 * @as(f64, @floatFromInt(i)); // up to 1.05 mm
        const z = try striplineZ0(w, h, h, t, er);
        // Strictly decreasing, and never by more than 2 Ω per 0.005 mm — a
        // branch discontinuity at a seam would break one or the other.
        try testing.expect(z < prev);
        try testing.expect(prev - z < 2.0);
        prev = z;
    }
}

// spec: placement/impedance - an offset stripline sits between its two symmetric bounds
test "asymmetric stripline is bracketed by its symmetric endpoints" {
    const w = 0.15;
    const t = 0.0152;
    const er = 4.4;
    const near = try striplineZ0(w, 0.2, 0.2, t, er);
    const far = try striplineZ0(w, 0.6, 0.6, t, er);
    const off = try striplineZ0(w, 0.2, 0.6, t, er);
    try testing.expect(off > near and off < far);
}

// spec: placement/impedance - geometry outside a formula's published domain is refused, not extrapolated
test "out-of-domain geometry is refused" {
    // u = W/h far above Hammerstad-Jensen's common impedance/epsilon domain.
    try testing.expectError(Error.OutOfDomain, microstripZ0(50.0, 0.2, 0.035, 4.4));
    // u far below 0.01.
    try testing.expectError(Error.OutOfDomain, microstripZ0(0.001, 1.6, 0.0, 4.4));
    // er below 1 is not a dielectric.
    try testing.expectError(Error.OutOfDomain, microstripZ0(0.3, 0.2, 0.035, 0.5));
    // Stripline so wide it is a plane, not a trace (W/(b−t) > 10).
    try testing.expectError(Error.OutOfDomain, striplineZ0(10.0, 0.4, 0.4, 0.035, 4.4));
    // Stripline past the t/b < 0.25 thin-foil limit.
    try testing.expectError(Error.OutOfDomain, striplineZ0(0.02, 0.05, 0.05, 0.05, 4.4));
    // Non-positive width / height / target.
    try testing.expectError(Error.OutOfDomain, microstripZ0(0.0, 1.6, 0.035, 4.4));
    try testing.expectError(Error.OutOfDomain, refWidthForZ0(.{ .microstrip = .{ .h_mm = 1.6, .er = 4.4 } }, 0.0, 0.035));
}

// spec: placement/impedance - a target Z0 no width in the domain reaches is reported unreachable
test "an unreachable target Z0 is reported, not clamped" {
    // 1 Ω on a 1.6 mm FR-4 microstrip needs a strip wider than u = 100.
    try testing.expectError(
        Error.Unreachable,
        refWidthForZ0(.{ .microstrip = .{ .h_mm = 1.6, .er = 4.4 } }, 1.0, 0.035),
    );
    // 300 Ω needs one far narrower than u = 0.01.
    try testing.expectError(
        Error.Unreachable,
        refWidthForZ0(.{ .microstrip = .{ .h_mm = 1.6, .er = 4.4 } }, 300.0, 0.035),
    );
}

// spec: placement/impedance - impedance solving is deterministic across repeated calls
test "solving the same width twice gives bit-identical answers" {
    const ref: Ref = .{ .stripline = .{ .h1_mm = 0.2104, .h2_mm = 1.065, .er = 4.4 } };
    const a = try refWidthForZ0(ref, 50.0, 0.0152);
    for (0..8) |_| {
        try testing.expectEqual(a, try refWidthForZ0(ref, 50.0, 0.0152));
    }
}

// spec: placement/impedance - an outer layer references the nearest plane as microstrip and an inner layer between planes as stripline
test "reference geometry follows the stackup's planes" {
    const two = twoLayerFr4();
    const top = reference(two, 1).?;
    try testing.expectEqualStrings("microstrip", top.kindName());
    try testing.expectApproxEqAbs(@as(f64, 1.6), top.heightMm(), 1e-12);
    // Layer 2 IS the plane — it carries no signal.
    try testing.expect(reference(two, 2) == null);

    // A four-layer board with BOTH inner layers as planes: layer 2 and 3 are
    // planes, so the outer faces are microstrip and there is no inner signal.
    const four = Stack{
        .layers = 4,
        .planes = &.{ 2, 3 },
        .dielectrics = &.{
            .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
            .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
            .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
        },
    };
    try testing.expectEqualStrings("microstrip", reference(four, 1).?.kindName());
    try testing.expectEqualStrings("microstrip", reference(four, 4).?.kindName());
    try testing.expect(reference(four, 2) == null);

    // Move the planes outward (1 and 4): the two inner layers become stripline.
    const buried = Stack{
        .layers = 4,
        .planes = &.{ 1, 4 },
        .dielectrics = four.dielectrics,
    };
    const inner = reference(buried, 2).?;
    try testing.expectEqualStrings("stripline", inner.kindName());
    const s = inner.stripline;
    try testing.expectApproxEqAbs(@as(f64, 0.2104), s.h1_mm, 1e-12);
    // Down to layer 4: gap 2 + foil 3 + gap 3 — the buried foil really does
    // push the planes apart, so it counts toward the separation…
    try testing.expectApproxEqAbs(1.065 + default_foil_mm + 0.2104, s.h2_mm, 1e-12);
    // …but NOT toward the permittivity mix: a uniform 4.4 buildup must read
    // back as exactly 4.4, not diluted by the copper it spans.
    try testing.expectApproxEqAbs(@as(f64, 4.4), inner.er(), 1e-12);
}

// spec: placement/impedance - outer poured faces remain signal layers when resolving impedance references
test "outer pours remain impedance-capable signal faces" {
    // Barracuda-style six-layer stack: outer GND pours coexist with routed RF,
    // while layers 2 and 4 are dedicated GND planes. Treating every declared
    // pour as plane-only used to skip F.Cu and derive the RF class against the
    // first inner stripline instead.
    const poured = Stack{
        .layers = 6,
        .planes = &.{ 1, 2, 4, 6 },
        .dielectrics = &.{
            .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
            .{ .after_layer = 2, .thickness_mm = 0.4, .er = 4.4 },
            .{ .after_layer = 3, .thickness_mm = 0.2028, .er = 4.4 },
            .{ .after_layer = 4, .thickness_mm = 0.4, .er = 4.4 },
            .{ .after_layer = 5, .thickness_mm = 0.2104, .er = 4.4 },
        },
        .foils = &.{
            .{ .index = 1, .thickness_mm = 0.035 },
            .{ .index = 2, .thickness_mm = 0.0152 },
            .{ .index = 3, .thickness_mm = 0.0152 },
            .{ .index = 4, .thickness_mm = 0.0152 },
            .{ .index = 5, .thickness_mm = 0.0152 },
            .{ .index = 6, .thickness_mm = 0.035 },
        },
    };

    const top = reference(poured, 1).?;
    try testing.expectEqualStrings("microstrip", top.kindName());
    try testing.expectApproxEqAbs(@as(f64, 0.2104), top.heightMm(), 1e-12);
    try testing.expectEqual(@as(?u8, 1), preferredLayer(poured));
    try testing.expectApproxEqAbs(
        @as(f64, 0.3726),
        resolvedWidthMm(poured, 50).?,
        0.0001,
    );

    var layers: [6]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 1, 3, 5, 6 }, signalLayers(poured, &layers));
    try testing.expect(reference(poured, 2) == null);
    try testing.expect(reference(poured, 4) == null);
}

// spec: placement/impedance - a layer with no reference plane yields no impedance rather than a guess
test "a plane-less stack computes no impedance" {
    const flat = Stack{ .layers = 2, .planes = &.{} };
    try testing.expect(reference(flat, 1) == null);
    try testing.expect(preferredLayer(flat) == null);
    try testing.expect(resolvedWidthMm(flat, 50.0) == null);
    // An inner layer with a plane on ONE side only is refused too.
    const half = Stack{ .layers = 4, .planes = &.{1} };
    try testing.expect(reference(half, 2) == null);
    try testing.expect(reference(half, 3) == null);
}

// spec: placement/impedance - a stackup with no authored dielectric intervals falls back to a uniform buildup
test "an undeclared buildup spreads the board thickness evenly" {
    const s = Stack{ .layers = 4, .planes = &.{ 2, 3 }, .board_mm = 1.6 };
    try testing.expect(s.assumed());
    // 1.6 mm less four 0.035 mm foils, over three gaps.
    const want = (1.6 - 4.0 * default_foil_mm) / 3.0;
    try testing.expectApproxEqAbs(want, s.gapMm(1), 1e-12);
    try testing.expectApproxEqAbs(default_er, s.gapEr(1), 1e-12);
    // And a declared buildup is NOT assumed.
    try testing.expect(!twoLayerFr4().assumed());
}

// spec: placement/impedance - the resolved width comes from the first signal layer with a usable reference
test "resolvedWidthMm solves on the preferred layer" {
    const two = twoLayerFr4();
    try testing.expectEqual(@as(?u8, 1), preferredLayer(two));
    const w = resolvedWidthMm(two, 50.0).?;
    const direct = try refWidthForZ0(reference(two, 1).?, 50.0, 0.035);
    try testing.expectEqual(direct, w);
    var buf: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{1}, signalLayers(two, &buf));
}

// spec: placement/impedance - an empty or zero-length stackup (no layers declared) computes no impedance at all
test "a zero-layer stack answers nothing" {
    const nothing = Stack{};
    try testing.expectEqual(@as(u8, 0), nothing.layers);
    try testing.expect(reference(nothing, 0) == null);
    try testing.expect(reference(nothing, 1) == null);
    try testing.expect(preferredLayer(nothing) == null);
    try testing.expect(resolvedWidthMm(nothing, 50.0) == null);
    try testing.expect(mismatchPct(nothing, 1, 0.2, 50.0) == null);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), signalLayers(nothing, &buf).len);
    // A zero-length output buffer is honoured rather than overrun.
    var none: [0]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), signalLayers(twoLayerFr4(), &none).len);
}

// spec: placement/impedance - non-finite or non-positive geometry is rejected by the domain checks rather than overflowing
test "infinities and NaNs are refused rather than propagated" {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    try testing.expectError(Error.OutOfDomain, microstripZ0(inf, 1.6, 0.035, 4.4));
    try testing.expectError(Error.OutOfDomain, microstripZ0(0.3, inf, 0.035, 4.4));
    try testing.expectError(Error.OutOfDomain, microstripZ0(nan, 1.6, 0.035, 4.4));
    try testing.expectError(Error.OutOfDomain, microstripZ0(0.3, 1.6, 0.035, nan));
    try testing.expectError(Error.OutOfDomain, striplineZ0(nan, 0.4, 0.4, 0.035, 4.4));
    try testing.expectError(Error.OutOfDomain, striplineZ0(0.2, inf, 0.4, 0.035, 4.4));
    // Negative copper thickness is not a foil.
    try testing.expectError(Error.OutOfDomain, microstripZ0(0.3, 1.6, -0.035, 4.4));
    try testing.expectError(Error.OutOfDomain, striplineZ0(0.2, 0.4, 0.4, -0.035, 4.4));
}

// spec: placement/impedance - the solver never panics: it is a fixed-count bisection returning an error instead of diverging
test "the inverse solve terminates on every target across a wide sweep" {
    // 10 Ω to 300 Ω is the whole span (impedance OHMS) accepts; every one of
    // them either solves to a width that reproduces the target, or reports
    // Unreachable. Neither branch may hang or trap.
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.2104, .er = 4.4 } };
    for (10..301) |ohms| {
        const target: f64 = @floatFromInt(ohms);
        const w = refWidthForZ0(ref, target, 0.035) catch |e| {
            try testing.expectEqual(Error.Unreachable, e);
            continue;
        };
        try testing.expect(w > 0);
        try testing.expectApproxEqAbs(target, try refZ0(ref, w, 0.035), 0.01);
    }
}

// spec: placement/impedance - the mismatch percentage measures an authored width against its class target
test "mismatchPct measures an authored width against its target" {
    const two = twoLayerFr4();
    // The solved 50 Ω width mismatches by ~0.
    const w = resolvedWidthMm(two, 50.0).?;
    try testing.expect(mismatchPct(two, 1, w, 50.0).? < 0.01);
    // A 0.25 mm trace on 1.6 mm FR-4 is nowhere near 50 Ω.
    try testing.expect(mismatchPct(two, 1, 0.25, 50.0).? > mismatch_tolerance_pct);
    // A layer with no reference reports nothing rather than 0.
    try testing.expect(mismatchPct(two, 2, 0.3, 50.0) == null);
}

// spec: placement/impedance - grounded coplanar analysis uses the authored ground gap and round-trips its synthesized width
test "grounded coplanar impedance matches the barracuda stackup" {
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.2104, .er = 4.4 } };
    const z = try groundedCoplanarZ0(0.31, 0.2104, 0.035, 4.4, 0.127);
    try testing.expectApproxEqAbs(@as(f64, 48.76), z, 0.02);
    try testing.expectEqualStrings("grounded-coplanar", ref.kindNameWithGroundGap(0.127));

    const solved = try refWidthForZ0WithGroundGap(ref, 50, 0.035, 0.127);
    try testing.expectApproxEqAbs(@as(f64, 0.29483), solved, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 50), try refZ0WithGroundGap(ref, solved, 0.035, 0.127), 1e-9);
}

test "documented conductor-backed CPWG equations match reference vectors" {
    // Direct evaluations of the document's closed form. The finite-thickness
    // vector exercises both W/S adjustment and Gupta's a-posteriori effective-
    // permittivity reduction.
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.5, .er = 4.3 } };
    try testing.expectApproxEqAbs(
        @as(f64, 46.5653913947),
        try refZ0WithGroundGap(ref, 0.9, 0, 0.25),
        1e-9,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 2.9970777230),
        try refEffectiveErWithGroundGap(ref, 0.9, 0, 0.25),
        1e-9,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 45.1686206303),
        try refZ0WithGroundGap(ref, 0.9, 0.035, 0.25),
        1e-9,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 2.8054261564),
        try refEffectiveErWithGroundGap(ref, 0.9, 0.035, 0.25),
        1e-9,
    );
}

// spec: placement/impedance - propagation uses the same grounded coplanar effective permittivity as impedance synthesis
test "grounded coplanar exposes its matched effective permittivity" {
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.2104, .er = 4.4 } };
    const width = try refWidthForZ0WithGroundGap(ref, 50, 0.035, 0.127);
    const er_eff = try refEffectiveErWithGroundGap(ref, width, 0.035, 0.127);
    try testing.expect(er_eff > 1);
    try testing.expect(er_eff < 4.4);
    try testing.expectApproxEqAbs(@as(f64, 50), try refZ0WithGroundGap(ref, width, 0.035, 0.127), 1e-9);
}

// spec: placement/impedance - a widening CPWG trace grows its side-ground slot only until the declared cap
test "grounded coplanar gap synthesis reaches target or reports its cap" {
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.2104, .er = 4.4 } };
    const matched = try refGroundGapForZ0(ref, 0.4, 0.035, 50, 0.127, 1.75);
    try testing.expectApproxEqAbs(@as(f64, 0.36121), matched.gap_mm, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 50), matched.z0_ohms, 1e-9);
    try testing.expect(!matched.capped);

    const limited = try refGroundGapForZ0(ref, 0.5588, 0.035, 50, 0.127, 1.75);
    try testing.expectEqual(@as(f64, 1.75), limited.gap_mm);
    try testing.expectApproxEqAbs(@as(f64, 43.87), limited.z0_ohms, 0.02);
    try testing.expect(limited.capped);
    try testing.expectError(Error.OutOfDomain, refGroundGapForZ0(.{ .stripline = .{ .h1_mm = 0.2, .h2_mm = 0.2, .er = 4.4 } }, 0.4, 0.035, 50, 0.127, 1.75));
}

// spec: placement/impedance - grounded coplanar analysis refuses a non-positive or copper-closed slot
test "grounded coplanar domain rejects impossible slots" {
    try testing.expectError(Error.OutOfDomain, groundedCoplanarZ0(0.31, 0.2104, 0.035, 4.4, 0));
    try testing.expectError(Error.OutOfDomain, groundedCoplanarZ0(0.01, 0.2104, 0.2, 4.4, 0.01));
}

// spec: placement/impedance - an offset L3 coupled stripline solves the Barracuda 100 ohm LVDS geometry and round-trips
test "coupled stripline synthesis matches the barracuda L3 reference pair" {
    const ref: Ref = .{ .stripline = .{ .h1_mm = 0.4, .h2_mm = 0.618, .er = 4.55915 } };
    const gap = 0.1524;
    const width = try refWidthForDiffZ0(ref, 100, 0.0152, gap);
    try testing.expectApproxEqAbs(@as(f64, 0.1617), width, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 100), try refDiffZ0(ref, width, 0.0152, gap), 1e-9);
}

// spec: placement/impedance - an outer differential pair uses coupled microstrip odd mode and round-trips through synthesis
test "differential impedance supports an outer microstrip reference" {
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.2104, .er = 4.4 } };
    const gap = 0.1524;
    const width = try refWidthForDiffZ0(ref, 100, 0.035, gap);
    const diff = try refDiffZ0(ref, width, 0.035, gap);
    const isolated = try refZ0(ref, width, 0.035);
    try testing.expectApproxEqAbs(@as(f64, 100), diff, 1e-9);
    try testing.expect(diff < 2.0 * isolated);
    var stack = twoLayerFr4();
    stack.dielectrics = &.{.{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 }};
    const stack_width = resolvedDiffWidthMmOnLayer(stack, 1, 100, gap).?;
    try testing.expectApproxEqAbs(width, stack_width, 1e-12);
    try testing.expect(diffMismatchPct(stack, 1, stack_width, gap, 100).? < 0.01);
}

// spec: placement/impedance - declared soldermask and trapezoidal etch profile correct the closed-form microstrip through a calibrated field ratio
test "coated trapezoidal microstrip lowers impedance and round-trips synthesis" {
    const foils = [_]Foil{
        .{ .index = 1, .thickness_mm = 0.035, .width_reduction_mm = 0.01778, .narrow_up = true },
        .{ .index = 2, .thickness_mm = 0.035, .width_reduction_mm = 0.01778, .narrow_up = false },
    };
    const masks = [_]Mask{.{ .top = true, .er = 3.8, .substrate_mm = 0.03048, .copper_mm = 0.01524 }};
    const stack = Stack{
        .layers = 2,
        .planes = &.{2},
        .dielectrics = &.{.{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 }},
        .foils = &foils,
        .masks = &masks,
    };
    const bare = analyzeOnLayer(testing.allocator, stack, 1, 0.30, 0, false).?;
    const coated = analyzeOnLayer(testing.allocator, stack, 1, 0.30, 0, true).?;
    try testing.expect(coated.z0_ohms < bare.z0_ohms);
    try testing.expect(coated.er_eff > bare.er_eff);
    const width = resolvedWidthMmOnLayerWithProcess(testing.allocator, stack, 1, 50, 0, true).?;
    const roundtrip = analyzeOnLayer(testing.allocator, stack, 1, width, 0, true).?;
    try testing.expectApproxEqAbs(@as(f64, 50), roundtrip.z0_ohms, 0.5);

    const thin_cpwg = Stack{
        .layers = 2,
        .planes = &.{2},
        .dielectrics = &.{.{ .after_layer = 1, .thickness_mm = 0.0994, .er = 4.1 }},
        .foils = &foils,
    };
    const cpwg_width = resolvedWidthMmOnLayerWithProcess(testing.allocator, thin_cpwg, 1, 50, 0.1524, false).?;
    const cpwg_roundtrip = analyzeOnLayer(testing.allocator, thin_cpwg, 1, cpwg_width, 0.1524, false).?;
    try testing.expectApproxEqAbs(@as(f64, 50), cpwg_roundtrip.z0_ohms, 0.1);
}

// spec: placement/impedance - coated coupled microstrip synthesis remains self-consistent for both USB and Ethernet targets
test "coated differential microstrip round-trips barracuda base targets" {
    const stack = Stack{
        .layers = 4,
        .planes = &.{ 2, 3 },
        .dielectrics = &.{
            .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
            .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.6 },
            .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
        },
        .foils = &.{
            .{ .index = 1, .thickness_mm = 0.035, .width_reduction_mm = 0.01778, .narrow_up = true },
            .{ .index = 2, .thickness_mm = 0.0152, .width_reduction_mm = 0.01778, .narrow_up = true },
            .{ .index = 3, .thickness_mm = 0.0152, .width_reduction_mm = 0.01778, .narrow_up = false },
            .{ .index = 4, .thickness_mm = 0.035, .width_reduction_mm = 0.01778, .narrow_up = false },
        },
        .masks = &.{.{ .top = true, .er = 3.8, .substrate_mm = 0.03048, .copper_mm = 0.01524 }},
    };
    for ([_]f64{ 90, 100 }) |target| {
        const width = resolvedDiffWidthMmOnLayerWithProcess(testing.allocator, stack, 1, target, 0.1524, true).?;
        const result = analyzeDiffOnLayer(testing.allocator, stack, 1, width, 0.1524, true).?;
        try testing.expectApproxEqAbs(target, result.z0_ohms, 0.1);
        try testing.expect(result.er_eff > 1 and result.er_eff <= 4.4);
    }
}

// spec: placement/impedance - mixed-dielectric stripline uses each physical interval instead of collapsing the stack to one average Dk
test "mixed dielectric stripline is field corrected and synthesizes its target" {
    const stack = Stack{
        .layers = 5,
        .planes = &.{ 2, 5 },
        .dielectrics = &.{
            .{ .after_layer = 1, .thickness_mm = 0.1, .er = 4.1 },
            .{ .after_layer = 2, .thickness_mm = 0.55, .er = 4.6 },
            .{ .after_layer = 3, .thickness_mm = 0.1088, .er = 4.16 },
            .{ .after_layer = 4, .thickness_mm = 0.55, .er = 4.6 },
        },
        .foils = &.{
            .{ .index = 1, .thickness_mm = 0.035 },
            .{ .index = 2, .thickness_mm = 0.0152 },
            .{ .index = 3, .thickness_mm = 0.0152, .width_reduction_mm = 0.01778, .narrow_up = false },
            .{ .index = 4, .thickness_mm = 0.0152 },
            .{ .index = 5, .thickness_mm = 0.0152 },
        },
    };
    const width = resolvedWidthMmOnLayerWithProcess(testing.allocator, stack, 3, 50, 0, false).?;
    const result = analyzeOnLayer(testing.allocator, stack, 3, width, 0, false).?;
    try testing.expectApproxEqAbs(@as(f64, 50), result.z0_ohms, 0.3);
    try testing.expect(result.er_eff > 4.1 and result.er_eff < 4.7);
    const pair_width = resolvedDiffWidthMmOnLayerWithProcess(testing.allocator, stack, 3, 100, 0.1524, false).?;
    const pair = analyzeDiffOnLayer(testing.allocator, stack, 3, pair_width, 0.1524, false).?;
    try testing.expectApproxEqAbs(@as(f64, 100), pair.z0_ohms, 1.0);
}

// spec: placement/impedance - broadside coupled pairs expose even and odd modes from the capacitance matrix and define differential impedance as twice odd mode
test "broadside pair returns capacitance-matrix modes" {
    const stack = Stack{
        .layers = 4,
        .planes = &.{ 1, 4 },
        .dielectrics = &.{
            .{ .after_layer = 1, .thickness_mm = 0.2, .er = 4.2 },
            .{ .after_layer = 2, .thickness_mm = 0.15, .er = 4.5 },
            .{ .after_layer = 3, .thickness_mm = 0.2, .er = 4.2 },
        },
        .foils = &.{
            .{ .index = 1, .thickness_mm = 0.035 },
            .{ .index = 2, .thickness_mm = 0.018 },
            .{ .index = 3, .thickness_mm = 0.018 },
            .{ .index = 4, .thickness_mm = 0.035 },
        },
    };
    const modes = broadsideDiffZ0(testing.allocator, stack, .{
        .upper_layer = 2,
        .lower_layer = 3,
        .upper_width_mm = 0.25,
        .lower_width_mm = 0.25,
    }).?;
    try testing.expectApproxEqRel(2 * modes.odd_ohms, modes.diff_ohms, 1e-12);
    try testing.expectApproxEqRel(modes.even_ohms / 2, modes.common_ohms, 1e-12);
    try testing.expect(modes.odd_ohms < modes.even_ohms);
}
