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
//!     below, dielectric on both sides (homogeneous medium).
//!
//! An inner layer with a plane on only one side, or any layer with no plane at
//! all, has no closed-form reference here and is refused rather than guessed.
//!
//! ## Formulas and citations
//!
//! **Microstrip** — Hammerstad's synthesis of Wheeler's analysis
//! (E. Hammerstad, "Equations for Microstrip Circuit Design", Proc. 5th
//! European Microwave Conf., 1975, pp. 268–272; reproduced in Hammerstad &
//! Jensen, "Accurate Models for Microstrip Computer-Aided Design", IEEE MTT-S
//! Digest, 1980, and in every standard text since). With u = W/h:
//!
//!     εeff = (εr+1)/2 + (εr−1)/2 · (1 + 12/u)^(−1/2)      [+ 0.04(1−u)² if u<1]
//!     Z₀   = (60/√εeff) · ln(8/u + u/4)                    for u ≤ 1
//!     Z₀   = 120π / (√εeff · (u + 1.393 + 0.667·ln(u + 1.444)))  for u ≥ 1
//!
//! Stated accuracy ~1 % over 0.05 ≤ u ≤ 20, 1 ≤ εr ≤ 128 — the domain this
//! module enforces.
//!
//! Finite strip thickness is handled by Hammerstad's thickness correction
//! (after Wheeler): the strip is widened to an equivalent zero-thickness strip
//!
//!     ΔW = (t/π)·(1 + ln(2h/t))     for W/h ≥ 1/(2π)
//!     ΔW = (t/π)·(1 + ln(4πW/t))    for W/h ≤ 1/(2π)
//!
//! and W_eff = W + ΔW is used in the equations above. t = 0 skips it.
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
//! This is the same quasi-static, no-soldermask model used by KiCad's grounded
//! coplanar calculator; frequency-dependent dispersion and loss are outside
//! this module's width/impedance contract.
//!
//! **Symmetric stripline** — the two published branches of Cohn's analysis
//! (S. B. Cohn, "Characteristic Impedance of the Shielded-Strip Transmission
//! Line", IRE Trans. MTT-2, 1954, pp. 52–57), as given in IPC-2141A §4.2.2 with
//! b the plane-to-plane separation. NARROW strip, W/(b−t) < 0.35:
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
const coupled_stripline = @import("impedance_coupled_stripline.zig");

/// Why an impedance could not be computed. Every one of these is a refusal to
/// extrapolate: the approximations above have published validity ranges and a
/// number produced outside them would be a fabrication, not an estimate.
pub const Error = error{
    /// Geometry outside the closed form's stated domain (u, W/(b−t), t/b, εr).
    OutOfDomain,
    /// No target Z₀ inside the domain reaches the requested value.
    Unreachable,
};

/// Free-space wave impedance as the microstrip equations are published:
/// Hammerstad writes the wide-strip case with 120π and the narrow-strip case
/// with 60 (= 120π/2π · π/…, i.e. the same constant), so both are used here
/// verbatim rather than substituting the measured 376.730313 Ω.
const eta0: f64 = 120.0 * std.math.pi;

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

/// Hammerstad's equivalent zero-thickness strip width for a strip of finite
/// thickness `t` at height `h`. Returns the width INCREMENT ΔW (mm).
fn thicknessWidening(w: f64, h: f64, t: f64) f64 {
    if (t <= 0) return 0;
    if (h <= 0) return 0;
    if (w <= 0) return 0;
    const inv_2pi = 1.0 / (2.0 * std.math.pi);
    const arg = if (w / h >= inv_2pi) 2.0 * h / t else 4.0 * std.math.pi * w / t;
    if (!(arg > 1.0)) return 0; // ln <= 0: the correction is meaningless here
    return (t / std.math.pi) * (1.0 + @log(arg));
}

/// Hammerstad's effective permittivity for a microstrip of ratio `u` = W/h.
fn effectiveEr(er: f64, u: f64) f64 {
    const a = (er + 1.0) / 2.0;
    const b = (er - 1.0) / 2.0;
    var f = 1.0 / @sqrt(1.0 + 12.0 / u);
    if (u < 1.0) f += 0.04 * (1.0 - u) * (1.0 - u);
    return a + b * f;
}

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
    if (!positive(w_mm)) return Error.OutOfDomain;
    if (!positive(h_mm)) return Error.OutOfDomain;
    if (t_mm < 0) return Error.OutOfDomain;
    if (!validEr(er)) return Error.OutOfDomain;
    const u = (w_mm + thicknessWidening(w_mm, h_mm, t_mm)) / h_mm;
    // Hammerstad's stated validity range for the pair of expressions below.
    if (u < 0.05) return Error.OutOfDomain;
    if (u > 20.0) return Error.OutOfDomain;
    const sq = @sqrt(effectiveEr(er, u));
    // Hammerstad's two expressions meet at u = 1 with a ~0.4 % step (70.82 vs
    // 71.09 Ω on 0.2104 mm FR-4) — within their own accuracy, but a step all
    // the same, and a step makes a band of target impedances unreachable by
    // the monotonic inverse solve below. Blend over 0.9 <= u <= 1.1; outside
    // that band each published branch is used verbatim.
    const narrow = (60.0 / sq) * @log(8.0 / u + u / 4.0);
    const wide = eta0 / (sq * (u + 1.393 + 0.667 * @log(u + 1.444)));
    if (u <= 0.9) return narrow;
    if (u >= 1.1) return wide;
    const lambda = (u - 0.9) / 0.2;
    return (1.0 - lambda) * narrow + lambda * wide;
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
        else blk: {
            const u = (w_mm + thicknessWidening(w_mm, m.h_mm, t_mm)) / m.h_mm;
            if (u < 0.05 or u > 20.0) return Error.OutOfDomain;
            break :blk effectiveEr(m.er, u);
        },
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

/// Differential impedance of a pair in this reference geometry. The current
/// closed form covers homogeneous edge-coupled stripline; an outer coupled
/// microstrip is refused rather than estimated with the wrong field model.
pub fn refDiffZ0(ref: Ref, w_mm: f64, t_mm: f64, pair_gap_mm: f64) Error!f64 {
    return switch (ref) {
        .microstrip => Error.OutOfDomain,
        .stripline => |s| coupled_stripline.z0(w_mm, s.h1_mm, s.h2_mm, t_mm, s.er, pair_gap_mm),
    };
}

/// Widest and narrowest trace worth bracketing for `ref`, in mm. Deliberately
/// generous at both ends — the domain checks inside `refZ0` do the real
/// rejecting; this only has to contain the solution.
fn widthBracket(ref: Ref) [2]f64 {
    const h = ref.heightMm();
    return .{ h * 0.02, h * 20.0 };
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
pub const Foil = struct { index: u8, thickness_mm: f64 };

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
test "symmetric stripline equals Cohn's closed form" {
    // W/(b−t) = 0.2/0.8 = 0.25, inside the narrow branch, so the model must
    // reproduce Cohn's published expression to the last bit.
    const w = 0.2;
    const h = 0.4;
    const t = 0.035;
    const er = 4.4;
    const got = try striplineZ0(w, h, h, t, er);
    const b = 2.0 * h + t;
    const want = (60.0 / @sqrt(er)) * @log(4.0 * b / (0.67 * std.math.pi * (0.8 * w + t)));
    try testing.expectApproxEqRel(want, got, 1e-12);
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
    // u = W/h far above Hammerstad's 20.
    try testing.expectError(Error.OutOfDomain, microstripZ0(50.0, 0.2, 0.035, 4.4));
    // u far below 0.05.
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
    // 5 Ω on a 1.6 mm FR-4 microstrip needs a strip far wider than u = 20.
    try testing.expectError(
        Error.Unreachable,
        refWidthForZ0(.{ .microstrip = .{ .h_mm = 1.6, .er = 4.4 } }, 5.0, 0.035),
    );
    // 300 Ω needs one far narrower than u = 0.05.
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
        @as(f64, 0.3666),
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

// spec: placement/impedance - coupled stripline analysis refuses outer microstrip instead of applying the inner-layer field model
test "differential impedance refuses an outer microstrip reference" {
    const ref: Ref = .{ .microstrip = .{ .h_mm = 0.2104, .er = 4.4 } };
    try testing.expectError(Error.OutOfDomain, refDiffZ0(ref, 0.16, 0.035, 0.1524));
}
