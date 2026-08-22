//! Cohn/Wadell edge-coupled stripline analysis used by `impedance.zig`.
//! Pair spacing is the edge-to-edge gap and the result is `2 * Zodd`.

const std = @import("std");

const Error = error{OutOfDomain};
const eta0: f64 = 120.0 * std.math.pi;

fn positive(v: f64) bool {
    return v > 0 and std.math.isFinite(v);
}

fn stripNarrowZ0(w: f64, b: f64, t: f64, er: f64) Error!f64 {
    const denom = 0.67 * std.math.pi * (0.8 * w + t);
    if (!positive(denom)) return Error.OutOfDomain;
    const arg = 4.0 * b / denom;
    if (arg <= 1.0) return Error.OutOfDomain;
    return 60.0 / @sqrt(er) * @log(arg);
}

fn stripWideZ0(w: f64, b: f64, t: f64, er: f64) Error!f64 {
    const x = t / b;
    if (x >= 1.0) return Error.OutOfDomain;
    const k = 1.0 / (1.0 - x);
    const second = if (k > 1.0) (k - 1.0) * @log(k * k - 1.0) else 0.0;
    const cf = 2.0 / std.math.pi * (k * @log(k + 1.0) - second);
    const denom = w / b * k + cf;
    if (!positive(denom)) return Error.OutOfDomain;
    return 94.15 / @sqrt(er) / denom;
}

fn singleStripZ0(w: f64, b: f64, t: f64, er: f64) Error!f64 {
    if (!positive(b)) return Error.OutOfDomain;
    if (t / b >= 0.25) return Error.OutOfDomain;
    const ratio = w / (b - t);
    if (ratio > 10.0) return Error.OutOfDomain;
    if (ratio <= 0.30) return stripNarrowZ0(w, b, t, er);
    if (ratio >= 0.40) return stripWideZ0(w, b, t, er);
    const lambda = (ratio - 0.30) / 0.10;
    return (1.0 - lambda) * try stripNarrowZ0(w, b, t, er) +
        lambda * try stripWideZ0(w, b, t, er);
}

fn ellipticK(k: f64) Error!f64 {
    if (!(k > 0 and k < 1)) return Error.OutOfDomain;
    if (!std.math.isFinite(k)) return Error.OutOfDomain;
    var a: f64 = 1;
    var b = @sqrt(1.0 - k * k);
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const next_a = 0.5 * (a + b);
        const next_b = @sqrt(a * b);
        if (next_a == a and next_b == b) break;
        a = next_a;
        b = next_b;
    }
    if (!positive(a)) return Error.OutOfDomain;
    return std.math.pi / (2.0 * a);
}

const Modes = struct { even: f64, odd: f64 };

fn zeroThicknessModes(w: f64, gap: f64, b: f64, er: f64) Error!Modes {
    const xw = std.math.pi * w / (2.0 * b);
    const xwg = std.math.pi * (w + gap) / (2.0 * b);
    const k_even = std.math.tanh(xw) * std.math.tanh(xwg);
    const k_odd = std.math.tanh(xw) / std.math.tanh(xwg);
    if (!(k_even > 0 and k_even < 1)) return Error.OutOfDomain;
    if (!(k_odd > 0 and k_odd < 1)) return Error.OutOfDomain;
    const scale = eta0 / (4.0 * @sqrt(er));
    return .{
        .even = scale * try ellipticK(@sqrt(1.0 - k_even * k_even)) / try ellipticK(k_even),
        .odd = scale * try ellipticK(@sqrt(1.0 - k_odd * k_odd)) / try ellipticK(k_odd),
    };
}

fn centeredModes(w: f64, gap: f64, b: f64, t: f64, er: f64) Error!Modes {
    const zero = try zeroThicknessModes(w, gap, b, er);
    if (t == 0) return zero;
    if (!(t > 0 and t < b)) return Error.OutOfDomain;
    if (!positive(gap)) return Error.OutOfDomain;
    const z_single_t = try singleStripZ0(w, b, t, er);
    const x = std.math.pi * w / (2.0 * b);
    const z_single_0 = eta0 / (4.0 * @sqrt(er)) *
        try ellipticK(1.0 / std.math.cosh(x)) / try ellipticK(std.math.tanh(x));
    const inv = 1.0 / (1.0 - t / b);
    const fringe_t = er / std.math.pi *
        (2.0 * inv * @log(inv + 1.0) - (inv - 1.0) * @log(inv * inv - 1.0));
    const fringe_0 = er / std.math.pi * 2.0 * @log(2.0);
    if (!positive(fringe_t) or !positive(fringe_0)) return Error.OutOfDomain;
    const ratio = fringe_t / fringe_0;
    const even_denom = 1.0 / z_single_t - ratio * (1.0 / z_single_0 - 1.0 / zero.even);
    const odd_1_denom = 1.0 / z_single_t + ratio * (1.0 / zero.odd - 1.0 / z_single_0);
    const odd_2_denom = 1.0 / zero.odd + (1.0 / z_single_t - 1.0 / z_single_0) -
        2.0 / eta0 * (fringe_t - fringe_0) + 2.0 * t / (eta0 * gap);
    if (!positive(even_denom)) return Error.OutOfDomain;
    if (!positive(odd_1_denom)) return Error.OutOfDomain;
    if (!positive(odd_2_denom)) return Error.OutOfDomain;
    const odd = if (gap / t >= 5.0) 1.0 / odd_1_denom else 1.0 / odd_2_denom;
    return .{ .even = 1.0 / even_denom, .odd = odd };
}

fn corrected(z: f64, a: f64, b: f64, w: f64, t: f64, er: f64) Error!f64 {
    const correction = 0.26 * std.math.pi / 8.0 * @sqrt(er) * z *
        std.math.pow(f64, @abs(0.5 - a / b), 2.2) * std.math.pow(f64, (t + w) / b, 2.9);
    const result = z * (1.0 - correction);
    if (!positive(result)) return Error.OutOfDomain;
    return result;
}

/// Differential impedance of an edge-coupled stripline pair.
pub fn z0(w: f64, h1: f64, h2: f64, t: f64, er: f64, gap: f64) Error!f64 {
    if (!positive(w) or !positive(h1)) return Error.OutOfDomain;
    if (!positive(h2) or !positive(gap)) return Error.OutOfDomain;
    if (t < 0 or !std.math.isFinite(t)) return Error.OutOfDomain;
    if (!(er >= 1.0 and er <= 128.0)) return Error.OutOfDomain;
    const b = h1 + t + h2;
    const a = h1 + t / 2.0;
    if (!(a > t / 2.0 and a < b - t / 2.0)) return Error.OutOfDomain;
    if (@abs(a - b / 2.0) <= b * 1e-9) return 2.0 * (try centeredModes(w, gap, b, t, er)).odd;
    const near = try centeredModes(w, gap, 2.0 * a, t, er);
    const far = try centeredModes(w, gap, 2.0 * (b - a), t, er);
    const odd_image = 2.0 / (1.0 / near.odd + 1.0 / far.odd);
    return 2.0 * try corrected(odd_image, a, b, w, t, er);
}

test "barracuda L3 100 ohm pair is about 0.1617 mm at a 0.1524 mm gap" {
    const actual = try z0(0.1617, 0.4, 0.618, 0.0152, 4.55915, 0.1524);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), actual, 0.02);
}
