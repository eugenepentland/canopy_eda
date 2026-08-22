//! Two-port RF route synthesis and fast electrical scoring.
//!
//! The ordinary maze router owns topology and obstacle avoidance. This leaf
//! module owns the continuous geometry of one ordered two-terminal run: fixed
//! pad centres and propagation tangents, straight pad entries, and G2 Euler
//! bends (clothoid ramp -> circular arc -> clothoid ramp). It deliberately
//! imports neither `router.zig` nor `optimizer.zig`; the router hands it a guide
//! polyline and a type-erased clearance probe, then may emit the winning
//! samples as ordinary track chords.

const std = @import("std");
const numeric = @import("../numeric.zig");

const eps: f64 = 1e-9;
const c_mm_s: f64 = 299_792_458_000.0;

/// A route terminal in board coordinates. `tangent` points in the direction
/// of propagation (out of the source pad, into the destination pad).
pub const PortFrame = struct {
    at: [2]f64,
    tangent: [2]f64,
};

/// A local transmission-line section used by the fast mismatch model. The
/// nominal routed trace fills the remaining path length between these end
/// sections. Callers normally model the launch/pad and any width taper here.
pub const EndSection = struct {
    length_mm: f64 = 0,
    z_ohm: f64 = 0,
};

/// Objective weights from the design policy. Geometry remains lexicographically
/// subordinate to feasibility regardless of these values.
pub const Weights = struct {
    return_loss: f64 = 1,
    curvature: f64 = 1,
    curvature_rate: f64 = 1,
    excess_length: f64 = 1,
};

/// One sampled point on the winning analytic chain. `curvature` is signed
/// inverse millimetres and is continuous at every primitive seam.
pub const Sample = struct {
    at: [2]f64,
    s_mm: f64,
    curvature: f64,
    /// Local copper width. The solver keeps nominal width through the body and
    /// linearly tapers only within the declared straight pad transitions.
    width_mm: f64 = 0,
};

/// Measured route and electrical quality for one trial.
pub const Metrics = struct {
    length_mm: f64 = 0,
    manhattan_mm: f64 = 0,
    curve: struct {
        energy: f64 = 0,
        rate_energy: f64 = 0,
        max_abs: f64 = 0,
    } = .{},
    entry: struct {
        start_error_deg: f64 = 180,
        end_error_deg: f64 = 180,
        start_straight_mm: f64 = 0,
        end_straight_mm: f64 = 0,
    } = .{},
    electrical: struct {
        worst_return_loss_db: f64 = 0,
    } = .{},
    clearance: struct {
        ok: bool = false,
        /// Arc length of the first rejected chord, or null when none failed.
        blocked_at_mm: ?f64 = null,
        blocked_at: ?[2]f64 = null,
    } = .{},
    objective: f64 = std.math.inf(f64),
};

/// A recorded candidate in the deterministic improvement loop.
pub const Trial = struct {
    radius_ratio: f64,
    transition_fraction: f64,
    /// 0 = tangent intersection, 1 = dogleg, 2/3 = mirrored detours.
    guide_variant: u8 = 0,
    feasible: bool,
    success: bool,
    metrics: Metrics,
};

/// The selected chain and the complete trial history.
pub const Result = struct {
    samples: []const Sample,
    trials: []const Trial,
    chosen: usize,
    feasible: bool,
    success: bool,
    metrics: Metrics,
};

/// Solver input. `guide` is the router's ordered polyline from source to
/// destination; its endpoints may repeat the port centres. The solver replaces
/// the first/last headings with the port tangents and rounds every remaining
/// corner with a curvature-continuous Euler bend.
pub const Input = struct {
    start: PortFrame,
    end: PortFrame,
    guide: []const [2]f64,
    geometry: struct {
        width_mm: f64,
        min_radius_ratio: f64 = 3,
        min_entry_mm: f64 = 0,
        start_entry_mm: f64 = 0,
        end_entry_mm: f64 = 0,
        chord_mm: f64 = 0.025,
        start_width_mm: f64 = 0,
        end_width_mm: f64 = 0,
        taper_mm: f64 = 0,
    },
    electrical: struct {
        target_z_ohm: f64 = 50,
        effective_er: f64 = 3.6,
        band_start_hz: f64,
        band_end_hz: f64,
        return_loss_target_db: f64 = 20,
        start_section: EndSection = .{},
        end_section: EndSection = .{},
    },
    policy: struct {
        weights: Weights = .{},
        stall_limit: usize = 6,
    } = .{},
};

/// Allocation-free lower bound used by placement before the obstacle router
/// exists. It accepts a straight connection or one forward tangent
/// intersection, and applies the same entry and minimum-radius Euler trim used
/// by the full solver. A false result is conservative: a wider S-bend or maze
/// guide may still work after the parts move farther apart.
pub const FrameFit = struct {
    feasible: bool,
    straight: bool,
    length_mm: f64,
    start_straight_mm: f64,
    end_straight_mm: f64,
};

const Fit = struct {
    trim_in: f64 = 0,
    trim_out: f64 = 0,
    radius: f64 = 0,
    transition_len: f64 = 0,
    arc_len: f64 = 0,
    signed_turn: f64 = 0,
    curve_len: f64 = 0,
};

const Candidate = struct {
    samples: []const Sample,
    metrics: Metrics,
    feasible: bool,
    success: bool,
};

const GuideProfile = struct { start_entry: f64, end_entry: f64, radius: f64, transition_fraction: f64, variant: u8 };

/// Search progressively flatter G2 profiles until the requested return loss
/// is met and no lower objective appears for `stall_limit` further mutations.
pub fn solve(arena: std.mem.Allocator, in: Input, probe: anytype) std.mem.Allocator.Error!Result {
    var trials: std.ArrayList(Trial) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;
    const ratios = [_]f64{ 3, 3.5, 4, 5, 6, 8, 10, 12 };
    const transitions = [_]f64{ 0.35, 0.2, 0.5 };
    var chosen: usize = 0;
    var have = false;
    const stall_limit = @max(in.policy.stall_limit, 1);

    for ([_]u8{ 0, 1, 2, 3 }) |variant| {
        var stalls: usize = 0;
        variant_search: for (ratios) |base_ratio| {
            const ratio = @max(base_ratio, in.geometry.min_radius_ratio);
            for (transitions) |transition| {
                const candidate = try buildCandidate(arena, in, ratio, transition, variant, probe);
                const trial_i = trials.items.len;
                try candidates.append(arena, candidate);
                try trials.append(arena, .{
                    .radius_ratio = ratio,
                    .transition_fraction = transition,
                    .guide_variant = variant,
                    .feasible = candidate.feasible,
                    .success = candidate.success,
                    .metrics = candidate.metrics,
                });
                if (!have or better(candidate, candidates.items[chosen])) {
                    chosen = trial_i;
                    have = true;
                    stalls = 0;
                } else {
                    stalls += 1;
                }
                if (have and candidates.items[chosen].success and stalls >= stall_limit) break :variant_search;
            }
        }
    }
    const best = candidates.items[chosen];
    return .{
        .samples = best.samples,
        .trials = try trials.toOwnedSlice(arena),
        .chosen = chosen,
        .feasible = best.feasible,
        .success = best.success,
        .metrics = best.metrics,
    };
}

fn better(a: Candidate, b: Candidate) bool {
    if (a.success != b.success) return a.success;
    if (a.feasible != b.feasible) return a.feasible;
    if (a.metrics.objective != b.metrics.objective) return a.metrics.objective < b.metrics.objective;
    if (a.metrics.electrical.worst_return_loss_db != b.metrics.electrical.worst_return_loss_db)
        return a.metrics.electrical.worst_return_loss_db > b.metrics.electrical.worst_return_loss_db;
    return a.metrics.length_mm < b.metrics.length_mm;
}

fn buildCandidate(arena: std.mem.Allocator, in: Input, ratio: f64, transition_fraction: f64, guide_variant: u8, probe: anytype) !Candidate {
    var metrics = Metrics{};
    if (!(in.geometry.width_mm > 0) or !(in.electrical.target_z_ohm > 0))
        return .{ .samples = &.{}, .metrics = metrics, .feasible = false, .success = false };
    const t0 = unit(in.start.tangent) orelse
        return .{ .samples = &.{}, .metrics = metrics, .feasible = false, .success = false };
    const t1 = unit(in.end.tangent) orelse
        return .{ .samples = &.{}, .metrics = metrics, .feasible = false, .success = false };
    const common_entry = @max(in.geometry.width_mm, in.geometry.min_entry_mm);
    const start_entry = @max(common_entry, in.geometry.start_entry_mm);
    const end_entry = @max(common_entry, in.geometry.end_entry_mm);
    const radius = ratio * in.geometry.width_mm;
    const pts = try portGuide(arena, in, t0, t1, .{
        .start_entry = start_entry,
        .end_entry = end_entry,
        .radius = radius,
        .transition_fraction = transition_fraction,
        .variant = guide_variant,
    });
    if (pts.len < 2)
        return .{ .samples = &.{}, .metrics = metrics, .feasible = false, .success = false };

    const fits = try arena.alloc(Fit, pts.len);
    @memset(fits, .{});
    for (1..pts.len - 1) |i| {
        const u = unit(sub(pts[i], pts[i - 1])) orelse continue;
        const v = unit(sub(pts[i + 1], pts[i])) orelse continue;
        const turn = std.math.atan2(cross(u, v), dot(u, v));
        if (@abs(turn) < 1e-7) continue;
        fits[i] = eulerFit(radius, turn, transition_fraction, @max(in.geometry.chord_mm, 0.002));
    }
    if (!fitsClear(pts, fits, start_entry, end_entry))
        return .{ .samples = &.{}, .metrics = metrics, .feasible = false, .success = false };

    var samples: std.ArrayList(Sample) = .empty;
    try samples.append(arena, .{ .at = pts[0], .s_mm = 0, .curvature = 0 });
    var cursor = pts[0];
    for (1..pts.len - 1) |i| {
        const u = unit(sub(pts[i], pts[i - 1])) orelse continue;
        const v = unit(sub(pts[i + 1], pts[i])) orelse continue;
        const fit = fits[i];
        const curve_start = add(pts[i], scale(u, -fit.trim_in));
        try appendLine(arena, &samples, &cursor, curve_start);
        if (fit.curve_len > 0) {
            const curve_end = add(pts[i], scale(v, fit.trim_out));
            try appendEuler(arena, &samples, .{ .start = curve_start, .finish = curve_end, .incoming = u, .fit = fit, .step = @max(in.geometry.chord_mm, 0.002) });
            cursor = curve_end;
            metrics.curve.energy += curvatureEnergy(fit);
            metrics.curve.rate_energy += curvatureRateEnergy(fit);
            metrics.curve.max_abs = @max(metrics.curve.max_abs, 1.0 / fit.radius);
        }
    }
    try appendLine(arena, &samples, &cursor, pts[pts.len - 1]);
    metrics.length_mm = if (samples.items.len == 0) 0 else samples.items[samples.items.len - 1].s_mm;
    const profile = WidthProfile{
        .nominal = in.geometry.width_mm,
        .start = if (in.geometry.start_width_mm > 0) in.geometry.start_width_mm else in.geometry.width_mm,
        .end = if (in.geometry.end_width_mm > 0) in.geometry.end_width_mm else in.geometry.width_mm,
        .taper = if (in.geometry.taper_mm > 0) in.geometry.taper_mm else in.geometry.width_mm,
        .start_land = @max(0, in.electrical.start_section.length_mm),
        .end_land = @max(0, in.electrical.end_section.length_mm),
    };
    const shaped = try taperSamples(arena, samples.items, profile);
    for (shaped) |*sample| sample.width_mm = localWidth(sample.s_mm, metrics.length_mm, profile);
    metrics.manhattan_mm = @abs(in.end.at[0] - in.start.at[0]) + @abs(in.end.at[1] - in.start.at[1]);
    metrics.entry.start_error_deg = tangentError(shaped, t0, false);
    metrics.entry.end_error_deg = tangentError(shaped, t1, true);
    metrics.entry.start_straight_mm = straightRun(shaped, false);
    metrics.entry.end_straight_mm = straightRun(shaped, true);
    metrics.electrical.worst_return_loss_db = worstReturnLoss(in, shaped);
    const target_rl = if (in.electrical.return_loss_target_db > 0) in.electrical.return_loss_target_db else 20;
    const mismatch = @max(0, target_rl - metrics.electrical.worst_return_loss_db);
    const excess = if (metrics.manhattan_mm > eps) @max(0, metrics.length_mm / metrics.manhattan_mm - 1) else 0;
    metrics.objective = in.policy.weights.return_loss * mismatch +
        in.policy.weights.curvature * metrics.curve.energy +
        in.policy.weights.curvature_rate * metrics.curve.rate_energy +
        in.policy.weights.excess_length * excess;

    const tangents_ok = metrics.entry.start_error_deg <= 2 and metrics.entry.end_error_deg <= 2;
    const entries_ok = metrics.entry.start_straight_mm + 1e-6 >= start_entry and
        metrics.entry.end_straight_mm + 1e-6 >= end_entry;
    var feasible = tangents_ok and entries_ok and
        metrics.curve.max_abs <= 1.0 / (in.geometry.min_radius_ratio * in.geometry.width_mm) + 1e-8;
    metrics.clearance.ok = feasible;
    if (feasible) if (@TypeOf(probe) != @TypeOf(null)) {
        for (shaped[1..], 1..) |sample, i| {
            const chord_width = @max(shaped[i - 1].width_mm, sample.width_mm);
            if (!probe.clear(shaped[i - 1].at, sample.at, chord_width)) {
                feasible = false;
                metrics.clearance.ok = false;
                metrics.clearance.blocked_at_mm = sample.s_mm;
                metrics.clearance.blocked_at = sample.at;
                break;
            }
        }
    };
    return .{
        .samples = shaped,
        .metrics = metrics,
        .feasible = feasible,
        .success = feasible and metrics.electrical.worst_return_loss_db + 1e-9 >= target_rl,
    };
}

const WidthProfile = struct {
    nominal: f64,
    start: f64,
    end: f64,
    taper: f64,
    /// Centre-to-near-edge distance of each land. Copper stays at land width
    /// through this overlap, then reaches nominal width outside the pad.
    start_land: f64,
    end_land: f64,
};

fn taperSamples(arena: std.mem.Allocator, source: []const Sample, profile: WidthProfile) ![]Sample {
    if (source.len < 2 or profile.taper <= eps) return arena.dupe(Sample, source);
    const total = source[source.len - 1].s_mm;
    var targets: std.ArrayList(f64) = .empty;
    for (0..7) |i| {
        const fraction = @as(f64, @floatFromInt(i)) / 6;
        const from_start = profile.start_land + profile.taper * fraction;
        const from_end = total - profile.end_land - profile.taper * fraction;
        if (from_start > eps and from_start < total - eps) try targets.append(arena, from_start);
        if (from_end > eps and from_end < total - eps) try targets.append(arena, from_end);
    }
    for (source) |sample| try targets.append(arena, sample.s_mm);
    std.mem.sort(f64, targets.items, {}, std.sort.asc(f64));
    var out: std.ArrayList(Sample) = .empty;
    for (targets.items) |s| {
        if (out.items.len > 0 and @abs(s - out.items[out.items.len - 1].s_mm) <= 1e-8) continue;
        try out.append(arena, sampleAt(source, s));
    }
    return out.toOwnedSlice(arena);
}

fn sampleAt(source: []const Sample, s: f64) Sample {
    if (s <= source[0].s_mm) return source[0];
    for (source[1..], 1..) |b, i| {
        const a = source[i - 1];
        if (s > b.s_mm + 1e-9) continue;
        const f = if (b.s_mm > a.s_mm) (s - a.s_mm) / (b.s_mm - a.s_mm) else 0;
        return .{
            .at = .{ a.at[0] + f * (b.at[0] - a.at[0]), a.at[1] + f * (b.at[1] - a.at[1]) },
            .s_mm = s,
            .curvature = a.curvature + f * (b.curvature - a.curvature),
        };
    }
    return source[source.len - 1];
}

fn localWidth(s: f64, total: f64, profile: WidthProfile) f64 {
    if (profile.taper <= eps) return profile.nominal;
    if (s <= profile.start_land) return @max(eps, profile.start);
    const start_taper = s - profile.start_land;
    if (start_taper < profile.taper)
        return @max(eps, profile.start + (profile.nominal - profile.start) * std.math.clamp(start_taper / profile.taper, 0, 1));
    const remaining = total - s;
    if (remaining <= profile.end_land) return @max(eps, profile.end);
    const end_taper = remaining - profile.end_land;
    if (end_taper < profile.taper)
        return @max(eps, profile.end + (profile.nominal - profile.end) * std.math.clamp(end_taper / profile.taper, 0, 1));
    return profile.nominal;
}

/// Test the shortest zero- or one-bend connection between two port frames.
/// This is intentionally the same geometry as one full-solver mutation at the
/// hard minimum radius, but without allocation, clearance probing, or the RF
/// model, making it cheap enough for connector-angle enumeration in placement.
pub fn frameFit(start: PortFrame, end: PortFrame, width_mm: f64, min_radius_ratio: f64, min_entry_mm: f64) FrameFit {
    var result = FrameFit{ .feasible = false, .straight = false, .length_mm = dist(start.at, end.at), .start_straight_mm = 0, .end_straight_mm = 0 };
    if (!(width_mm > 0)) return result;
    const t0 = unit(start.tangent) orelse return result;
    const t1 = unit(end.tangent) orelse return result;
    const delta = sub(end.at, start.at);
    const travel = unit(delta) orelse return result;
    const entry = @max(width_mm, min_entry_mm);
    const straight_error = @max(angleError(t0, travel), angleError(t1, travel));
    if (straight_error <= 2) {
        result.straight = true;
        result.start_straight_mm = result.length_mm;
        result.end_straight_mm = result.length_mm;
        result.feasible = result.length_mm + 1e-6 >= entry;
        return result;
    }
    const apex = portIntersection(start.at, t0, end.at, t1) orelse return result;
    const first = dist(start.at, apex);
    const last = dist(apex, end.at);
    const turn = std.math.atan2(cross(t0, t1), dot(t0, t1));
    if (@abs(turn) < 1e-7) return result;
    const fit = eulerFit(@max(min_radius_ratio, 3) * width_mm, turn, 0.35, 0.01);
    if (!(fit.curve_len > 0)) return result;
    result.start_straight_mm = first - fit.trim_in;
    result.end_straight_mm = last - fit.trim_out;
    result.length_mm = result.start_straight_mm + fit.curve_len + result.end_straight_mm;
    result.feasible = result.start_straight_mm + 1e-6 >= entry and result.end_straight_mm + 1e-6 >= entry;
    return result;
}

fn angleError(a: [2]f64, b: [2]f64) f64 {
    return std.math.acos(std.math.clamp(dot(a, b), -1, 1)) * 180 / std.math.pi;
}

fn portGuide(arena: std.mem.Allocator, in: Input, t0: [2]f64, t1: [2]f64, profile: GuideProfile) ![]const [2]f64 {
    const direct_heading = unit(sub(in.end.at, in.start.at));
    if (direct_heading) |heading| {
        if (angleError(t0, heading) <= 2 and angleError(t1, heading) <= 2) {
            return arena.dupe([2]f64, &.{ in.start.at, in.end.at });
        }
    }
    if (profile.variant == 0) if (portIntersection(in.start.at, t0, in.end.at, t1)) |apex| {
        const direct = [_][2]f64{ in.start.at, apex, in.end.at };
        return simplify(arena, &direct);
    };
    const span = dist(in.start.at, in.end.at);
    const detour_start = profile.variant >= 2 and profile.start_entry <= profile.end_entry;
    const detour_end = profile.variant >= 2 and profile.end_entry < profile.start_entry;
    const detour_fit = eulerFit(profile.radius, std.math.pi / 2.0, profile.transition_fraction, @max(in.geometry.chord_mm, 0.002));
    const sample_guard = @max(in.geometry.chord_mm, 0.002);
    const start_reserve = if (detour_start) detour_fit.trim_in + sample_guard else profile.radius;
    const end_reserve = if (detour_end) detour_fit.trim_in + sample_guard else profile.radius;
    const start_ray = @min(profile.start_entry + start_reserve, span * 0.45);
    const end_ray = @min(profile.end_entry + end_reserve, span * 0.45);
    var raw: std.ArrayList([2]f64) = .empty;
    try raw.append(arena, in.start.at);
    try raw.append(arena, add(in.start.at, scale(t0, start_ray)));
    const before_end = add(in.end.at, scale(t1, -end_ray));
    if (profile.variant >= 2) {
        // Leave the short land, then move laterally before crossing the body
        // of a neighbouring launch.  A midpoint bulge turns too late for the
        // common switch-fan case: the first bend is already inside the next
        // SMPM ground land.  Mirrored variants cover both sides and retain a
        // long final segment to recover the destination port tangent.
        const sign: f64 = if (profile.variant == 2) 1 else -1;
        const detour = @min(profile.start_entry, profile.end_entry) + 3 * profile.radius;
        if (profile.start_entry <= profile.end_entry) {
            const first = raw.items[raw.items.len - 1];
            try raw.append(arena, .{
                first[0] - t0[1] * detour * sign,
                first[1] + t0[0] * detour * sign,
            });
        } else {
            // Same construction seen from the destination end.  Reversing a
            // path negates its propagation tangent, so the lateral normal is
            // (t1.y,-t1.x); append it before `before_end` in forward order.
            try raw.append(arena, .{
                before_end[0] + t1[1] * detour * sign,
                before_end[1] - t1[0] * detour * sign,
            });
        }
    }
    if (dist(before_end, raw.items[raw.items.len - 1]) > 1e-6) try raw.append(arena, before_end);
    if (dist(in.end.at, raw.items[raw.items.len - 1]) > 1e-6) try raw.append(arena, in.end.at);
    return simplify(arena, raw.items);
}

fn portIntersection(start: [2]f64, t0: [2]f64, end: [2]f64, t1: [2]f64) ?[2]f64 {
    const den = cross(t0, t1);
    if (@abs(den) <= 1e-8) return null;
    const delta = sub(end, start);
    const along_start = cross(delta, t1) / den;
    const apex = add(start, scale(t0, along_start));
    const before_end = dot(sub(end, apex), t1);
    if (along_start <= 0 or before_end <= 0) return null;
    return apex;
}

fn simplify(arena: std.mem.Allocator, pts: []const [2]f64) ![]const [2]f64 {
    var out: std.ArrayList([2]f64) = .empty;
    for (pts) |p| {
        if (out.items.len > 0 and dist(p, out.items[out.items.len - 1]) <= 1e-7) continue;
        while (out.items.len >= 2) {
            const a = out.items[out.items.len - 2];
            const b = out.items[out.items.len - 1];
            const u = unit(sub(b, a)) orelse break;
            const v = unit(sub(p, b)) orelse break;
            if (@abs(cross(u, v)) > 1e-7 or dot(u, v) < 0) break;
            _ = out.pop();
        }
        try out.append(arena, p);
    }
    return out.toOwnedSlice(arena);
}

fn eulerFit(radius: f64, signed_turn: f64, fraction: f64, step: f64) Fit {
    const turn = @abs(signed_turn);
    const frac = std.math.clamp(fraction, 0.05, 0.9);
    const transition_len = radius * turn * frac;
    const arc_len = radius * turn * (1 - frac);
    const canonical = integrateEuler(.{ .radius = radius, .transition_len = transition_len, .arc_len = arc_len, .max_step = step }, null, .{ 0, 0 }, 0);
    const sin_turn = @sin(turn);
    if (@abs(sin_turn) < eps) return .{};
    const trim_out = canonical.at[1] / sin_turn;
    const trim_in = canonical.at[0] - trim_out * @cos(turn);
    if (trim_in <= 0 or trim_out <= 0) return .{};
    return .{
        .trim_in = trim_in,
        .trim_out = trim_out,
        .radius = radius,
        .transition_len = transition_len,
        .arc_len = arc_len,
        .signed_turn = signed_turn,
        .curve_len = 2 * transition_len + arc_len,
    };
}

const Integrated = struct { at: [2]f64, heading: f64, s: f64 };
const EulerParams = struct { radius: f64, transition_len: f64, arc_len: f64, max_step: f64 };

fn integrateEuler(
    p: EulerParams,
    samples: ?*std.ArrayList(Sample),
    origin: [2]f64,
    heading0: f64,
) Integrated {
    var state = Integrated{ .at = origin, .heading = heading0, .s = 0 };
    integrateRegion(&state, samples, p.transition_len, p.max_step, 0, 1.0 / p.radius);
    integrateRegion(&state, samples, p.arc_len, p.max_step, 1.0 / p.radius, 1.0 / p.radius);
    integrateRegion(&state, samples, p.transition_len, p.max_step, 1.0 / p.radius, 0);
    return state;
}

fn integrateRegion(state: *Integrated, samples: ?*std.ArrayList(Sample), len: f64, max_step: f64, k0: f64, k1: f64) void {
    if (len <= eps) return;
    const n = ceilCount(len, max_step);
    const ds = len / @as(f64, @floatFromInt(n));
    for (0..n) |i| {
        const f0 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const f1 = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(n));
        const ka = k0 + (k1 - k0) * f0;
        const kb = k0 + (k1 - k0) * f1;
        const dtheta = (ka + kb) * 0.5 * ds;
        const hm = state.heading + dtheta * 0.5;
        state.at = .{ state.at[0] + @cos(hm) * ds, state.at[1] + @sin(hm) * ds };
        state.heading += dtheta;
        state.s += ds;
        if (samples) |list| list.appendAssumeCapacity(.{ .at = state.at, .s_mm = state.s, .curvature = kb });
    }
}

const EulerAppend = struct { start: [2]f64, finish: [2]f64, incoming: [2]f64, fit: Fit, step: f64 };

fn appendEuler(arena: std.mem.Allocator, out: *std.ArrayList(Sample), job: EulerAppend) !void {
    const n_est = @max(3, ceilCount(job.fit.curve_len, job.step) + 3);
    try out.ensureUnusedCapacity(arena, n_est);
    var local: std.ArrayList(Sample) = .empty;
    try local.ensureTotalCapacity(arena, n_est);
    const sign: f64 = if (job.fit.signed_turn >= 0) 1 else -1;
    const heading = std.math.atan2(job.incoming[1], job.incoming[0]);
    _ = integrateEuler(.{
        .radius = job.fit.radius,
        .transition_len = job.fit.transition_len,
        .arc_len = job.fit.arc_len,
        .max_step = job.step,
    }, &local, .{ 0, 0 }, 0);
    const base_s = out.items[out.items.len - 1].s_mm;
    for (local.items, 0..) |sample, i| {
        const lx = sample.at[0];
        const ly = sample.at[1] * sign;
        const p = [2]f64{
            job.start[0] + lx * @cos(heading) - ly * @sin(heading),
            job.start[1] + lx * @sin(heading) + ly * @cos(heading),
        };
        var at = p;
        if (i + 1 == local.items.len) at = job.finish;
        try out.append(arena, .{ .at = at, .s_mm = base_s + sample.s_mm, .curvature = sample.curvature * sign });
    }
}

fn ceilCount(len: f64, step: f64) usize {
    if (!std.math.isFinite(len) or !std.math.isFinite(step)) return 1;
    if (len <= 0 or step <= 0) return 1;
    const raw = @ceil(len / step);
    return @max(1, numeric.toCount(raw));
}

fn appendLine(arena: std.mem.Allocator, out: *std.ArrayList(Sample), cursor: *[2]f64, finish: [2]f64) !void {
    const len = dist(cursor.*, finish);
    if (len <= eps) return;
    const s = out.items[out.items.len - 1].s_mm + len;
    try out.append(arena, .{ .at = finish, .s_mm = s, .curvature = 0 });
    cursor.* = finish;
}

fn fitsClear(pts: []const [2]f64, fits: []const Fit, start_entry: f64, end_entry: f64) bool {
    for (0..pts.len - 1) |i| {
        const used = fits[i].trim_out + fits[i + 1].trim_in;
        if (used > dist(pts[i], pts[i + 1]) - 1e-6) return false;
    }
    if (pts.len >= 2 and dist(pts[0], pts[1]) - fits[1].trim_in < start_entry - 1e-6) return false;
    if (pts.len >= 2 and dist(pts[pts.len - 2], pts[pts.len - 1]) - fits[pts.len - 2].trim_out < end_entry - 1e-6) return false;
    return true;
}

fn curvatureEnergy(f: Fit) f64 {
    return (2 * f.transition_len / 3 + f.arc_len) / (f.radius * f.radius);
}

fn curvatureRateEnergy(f: Fit) f64 {
    if (f.transition_len <= eps) return std.math.inf(f64);
    return 2 / (f.radius * f.radius * f.transition_len);
}

fn straightRun(samples: []const Sample, reverse: bool) f64 {
    if (samples.len < 2) return 0;
    var total: f64 = 0;
    for (0..samples.len - 1) |raw| {
        const i = if (reverse) samples.len - 1 - raw else raw;
        const a = if (reverse) samples[i] else samples[i];
        const b = if (reverse) samples[i - 1] else samples[i + 1];
        if (@abs(a.curvature) > 1e-8 or @abs(b.curvature) > 1e-8) break;
        total += dist(a.at, b.at);
    }
    return total;
}

fn tangentError(samples: []const Sample, want: [2]f64, reverse: bool) f64 {
    if (samples.len < 2) return 180;
    const a = if (reverse) samples[samples.len - 2].at else samples[0].at;
    const b = if (reverse) samples[samples.len - 1].at else samples[1].at;
    const got = unit(sub(b, a)) orelse return 180;
    return std.math.acos(std.math.clamp(dot(got, want), -1, 1)) * 180 / std.math.pi;
}

const Complex = struct {
    re: f64,
    im: f64,
    fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    fn subc(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }
    fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    fn scaleBy(a: Complex, x: f64) Complex {
        return .{ .re = a.re * x, .im = a.im * x };
    }
    fn div(a: Complex, b: Complex) Complex {
        const d = b.re * b.re + b.im * b.im;
        return .{ .re = (a.re * b.re + a.im * b.im) / d, .im = (a.im * b.re - a.re * b.im) / d };
    }
    fn mag(a: Complex) f64 {
        return std.math.hypot(a.re, a.im);
    }
};

const Matrix = struct { a: Complex, b: Complex, c: Complex, d: Complex };

fn identity() Matrix {
    return .{ .a = .{ .re = 1, .im = 0 }, .b = .{ .re = 0, .im = 0 }, .c = .{ .re = 0, .im = 0 }, .d = .{ .re = 1, .im = 0 } };
}

fn cascade(x: Matrix, y: Matrix) Matrix {
    return .{
        .a = Complex.add(Complex.mul(x.a, y.a), Complex.mul(x.b, y.c)),
        .b = Complex.add(Complex.mul(x.a, y.b), Complex.mul(x.b, y.d)),
        .c = Complex.add(Complex.mul(x.c, y.a), Complex.mul(x.d, y.c)),
        .d = Complex.add(Complex.mul(x.c, y.b), Complex.mul(x.d, y.d)),
    };
}

fn lineMatrix(z: f64, beta: f64, len: f64) Matrix {
    const co = @cos(beta * len);
    const si = @sin(beta * len);
    return .{
        .a = .{ .re = co, .im = 0 },
        .b = .{ .re = 0, .im = z * si },
        .c = .{ .re = 0, .im = si / z },
        .d = .{ .re = co, .im = 0 },
    };
}

fn worstReturnLoss(in: Input, samples: []const Sample) f64 {
    if (!(in.electrical.band_end_hz > 0) or !(in.electrical.effective_er > 0)) return 0;
    const lo = if (in.electrical.band_start_hz > 0) @min(in.electrical.band_start_hz, in.electrical.band_end_hz) else in.electrical.band_end_hz / 100;
    const hi = @max(lo, in.electrical.band_end_hz);
    var worst: f64 = 300;
    for (0..21) |i| {
        const f = lo + (hi - lo) * @as(f64, @floatFromInt(i)) / 20;
        const beta = 2 * std.math.pi * f * @sqrt(in.electrical.effective_er) / c_mm_s;
        var m = identity();
        const zs = if (in.electrical.start_section.z_ohm > 0) in.electrical.start_section.z_ohm else in.electrical.target_z_ohm;
        const ze = if (in.electrical.end_section.z_ohm > 0) in.electrical.end_section.z_ohm else in.electrical.target_z_ohm;
        if (in.electrical.start_section.length_mm > 0) m = cascade(m, lineMatrix(zs, beta, in.electrical.start_section.length_mm));
        const total = samples[samples.len - 1].s_mm;
        const route_start = std.math.clamp(in.electrical.start_section.length_mm, 0, total);
        const route_end = @max(route_start, total - std.math.clamp(in.electrical.end_section.length_mm, 0, total));
        for (samples[1..], 1..) |sample, si| {
            const before = samples[si - 1];
            const chord_len = sample.s_mm - before.s_mm;
            if (chord_len <= eps) continue;
            const from = @max(before.s_mm, route_start);
            const to = @min(sample.s_mm, route_end);
            const len = to - from;
            if (len <= eps) continue;
            const from_f = std.math.clamp((from - before.s_mm) / chord_len, 0, 1);
            const to_f = std.math.clamp((to - before.s_mm) / chord_len, 0, 1);
            const from_width = before.width_mm + (sample.width_mm - before.width_mm) * from_f;
            const to_width = before.width_mm + (sample.width_mm - before.width_mm) * to_f;
            const width = @max(eps, (from_width + to_width) / 2);
            const z = in.electrical.target_z_ohm * @sqrt(in.geometry.width_mm / width);
            m = cascade(m, lineMatrix(z, beta, len));
        }
        if (in.electrical.end_section.length_mm > 0) m = cascade(m, lineMatrix(ze, beta, in.electrical.end_section.length_mm));
        const z0 = in.electrical.target_z_ohm;
        const num = Complex.subc(Complex.add(m.a, Complex.scaleBy(m.b, 1 / z0)), Complex.add(Complex.scaleBy(m.c, z0), m.d));
        const den = Complex.add(Complex.add(m.a, Complex.scaleBy(m.b, 1 / z0)), Complex.add(Complex.scaleBy(m.c, z0), m.d));
        const gamma = Complex.div(num, den).mag();
        const rl = if (gamma <= 1e-15) 300 else -20 * std.math.log10(gamma);
        worst = @min(worst, rl);
    }
    return worst;
}

fn add(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ a[0] + b[0], a[1] + b[1] };
}
fn sub(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ a[0] - b[0], a[1] - b[1] };
}
fn scale(a: [2]f64, s: f64) [2]f64 {
    return .{ a[0] * s, a[1] * s };
}
fn dot(a: [2]f64, b: [2]f64) f64 {
    return a[0] * b[0] + a[1] * b[1];
}
fn cross(a: [2]f64, b: [2]f64) f64 {
    return a[0] * b[1] - a[1] * b[0];
}
fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}
fn unit(a: [2]f64) ?[2]f64 {
    const d = std.math.hypot(a[0], a[1]);
    if (d <= eps) return null;
    return .{ a[0] / d, a[1] / d };
}

const ClearAll = struct {
    fn clear(_: ClearAll, _: [2]f64, _: [2]f64, _: f64) bool {
        return true;
    }
};

// spec: placement/rf-port-frame-routing - G2 route matches both port frames and keeps one-width straight entries
test "G2 route matches both port frames and keeps one-width straight entries" {
    const testing = std.testing;
    var owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer owner.deinit();
    const arena = owner.allocator();
    const guide = [_][2]f64{ .{ 0, 0 }, .{ 8, 0 }, .{ 8, 6 } };
    const clear = ClearAll{};
    const result = try solve(arena, .{
        .start = .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .end = .{ .at = .{ 8, 6 }, .tangent = .{ 0, 1 } },
        .guide = &guide,
        .geometry = .{ .width_mm = 0.2, .min_entry_mm = 0.2 },
        .electrical = .{ .band_start_hz = 1e9, .band_end_hz = 6e9 },
    }, &clear);
    try testing.expect(result.success);
    try testing.expect(result.samples.len > 5);
    try testing.expectEqual([2]f64{ 0, 0 }, result.samples[0].at);
    try testing.expectEqual([2]f64{ 8, 6 }, result.samples[result.samples.len - 1].at);
    try testing.expect(result.metrics.entry.start_error_deg <= 2);
    try testing.expect(result.metrics.entry.end_error_deg <= 2);
    try testing.expect(result.metrics.entry.start_straight_mm >= 0.2);
    try testing.expect(result.metrics.entry.end_straight_mm >= 0.2);
    try testing.expect(result.metrics.curve.max_abs <= 1.0 / 0.6 + 1e-8);
}

// spec: placement/rf-port-frame-routing - Euler bend has zero-curvature seams and finite curvature-rate energy
test "Euler bend has zero-curvature seams and finite curvature-rate energy" {
    const testing = std.testing;
    var owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer owner.deinit();
    const arena = owner.allocator();
    const guide = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } };
    const result = try solve(arena, .{
        .start = .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .end = .{ .at = .{ 10, 10 }, .tangent = .{ 0, 1 } },
        .guide = &guide,
        .geometry = .{ .width_mm = 0.25 },
        .electrical = .{ .band_start_hz = 100e6, .band_end_hz = 10e9 },
    }, null);
    try testing.expect(std.math.isFinite(result.metrics.curve.rate_energy));
    try testing.expect(result.metrics.curve.rate_energy > 0);
    try testing.expectApproxEqAbs(@as(f64, 0), result.samples[0].curvature, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), result.samples[result.samples.len - 1].curvature, 1e-12);
    const chosen = result.trials[result.chosen];
    const radius = chosen.radius_ratio * 0.25;
    const transition_len = radius * (std.math.pi / @as(f64, 2)) * chosen.transition_fraction;
    const max_rate = 1 / (radius * transition_len);
    var saw_curve = false;
    for (result.samples[1..], 1..) |sample, i| {
        const before = result.samples[i - 1];
        saw_curve = saw_curve or @abs(before.curvature) > 1e-8 or @abs(sample.curvature) > 1e-8;
        const ds = sample.s_mm - before.s_mm;
        if (ds <= 1e-10) continue;
        try testing.expect(@abs(sample.curvature - before.curvature) / ds <= max_rate + 1e-6);
    }
    try testing.expect(saw_curve);
}

// spec: placement/rf-port-frame-routing - pad tapers hold full land width through the pad edge before narrowing or widening to the controlled-impedance body
test "pad tapers hold land width through the edge before reaching nominal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try solve(arena_state.allocator(), .{
        .start = .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .end = .{ .at = .{ 10, 0 }, .tangent = .{ 1, 0 } },
        .guide = &.{ .{ 0, 0 }, .{ 10, 0 } },
        .geometry = .{ .width_mm = 0.2, .start_width_mm = 0.1, .end_width_mm = 0.4, .taper_mm = 0.6 },
        .electrical = .{
            .band_start_hz = 1e9,
            .band_end_hz = 6e9,
            .start_section = .{ .length_mm = 0.5 },
            .end_section = .{ .length_mm = 0.4 },
        },
    }, null);
    try std.testing.expect(result.success);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.samples[0].width_mm, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), result.samples[result.samples.len - 1].width_mm, 1e-12);
    var saw_start_edge = false;
    var saw_start_taper_end = false;
    var saw_end_taper_start = false;
    var saw_end_edge = false;
    for (result.samples) |sample| {
        try std.testing.expect(sample.width_mm > 0);
        if (@abs(sample.s_mm - 0.5) <= 1e-9) {
            saw_start_edge = true;
            try std.testing.expectApproxEqAbs(@as(f64, 0.1), sample.width_mm, 1e-12);
        }
        if (@abs(sample.s_mm - 1.1) <= 1e-9) {
            saw_start_taper_end = true;
            try std.testing.expectApproxEqAbs(@as(f64, 0.2), sample.width_mm, 1e-12);
        }
        if (@abs(sample.s_mm - 9.0) <= 1e-9) {
            saw_end_taper_start = true;
            try std.testing.expectApproxEqAbs(@as(f64, 0.2), sample.width_mm, 1e-12);
        }
        if (@abs(sample.s_mm - 9.6) <= 1e-9) {
            saw_end_edge = true;
            try std.testing.expectApproxEqAbs(@as(f64, 0.4), sample.width_mm, 1e-12);
        }
    }
    try std.testing.expect(saw_start_edge and saw_start_taper_end and saw_end_taper_start and saw_end_edge);
}

// spec: placement/rf-port-frame-routing - feasibility and return-loss success precede the weighted geometry objective
test "success and feasibility precede weighted objective" {
    const poor_success = Candidate{ .samples = &.{}, .metrics = .{ .objective = 100 }, .feasible = true, .success = true };
    const cheap_failure = Candidate{ .samples = &.{}, .metrics = .{ .objective = 0 }, .feasible = true, .success = false };
    const infeasible = Candidate{ .samples = &.{}, .metrics = .{ .objective = -1 }, .feasible = false, .success = false };
    try std.testing.expect(better(poor_success, cheap_failure));
    try std.testing.expect(better(cheap_failure, infeasible));
}

// spec: placement/rf-port-frame-routing - identical inputs produce identical trial histories and winners
test "identical inputs produce identical trial histories and winners" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const input = Input{
        .start = .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .end = .{ .at = .{ 8, 6 }, .tangent = .{ 0, 1 } },
        .guide = &.{ .{ 0, 0 }, .{ 8, 0 }, .{ 8, 6 } },
        .geometry = .{ .width_mm = 0.2 },
        .electrical = .{ .band_start_hz = 100e6, .band_end_hz = 6e9 },
    };
    const first = try solve(arena_state.allocator(), input, null);
    const second = try solve(arena_state.allocator(), input, null);
    try std.testing.expectEqual(first.chosen, second.chosen);
    try std.testing.expectEqual(first.trials.len, second.trials.len);
    for (first.trials, second.trials) |a, b| {
        try std.testing.expectEqual(a.radius_ratio, b.radius_ratio);
        try std.testing.expectEqual(a.transition_fraction, b.transition_fraction);
        try std.testing.expectEqual(a.guide_variant, b.guide_variant);
        try std.testing.expectEqual(a.feasible, b.feasible);
        try std.testing.expectEqual(a.success, b.success);
        try std.testing.expectEqual(a.metrics.objective, b.metrics.objective);
    }
}

// spec: placement/rf-port-frame-routing - ABCD mismatch model rejects a badly mismatched launch across the band
test "ABCD mismatch model rejects a badly mismatched launch across the band" {
    const testing = std.testing;
    var owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer owner.deinit();
    const arena = owner.allocator();
    const guide = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 } };
    const result = try solve(arena, .{
        .start = .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .end = .{ .at = .{ 20, 0 }, .tangent = .{ 1, 0 } },
        .guide = &guide,
        .geometry = .{ .width_mm = 0.2 },
        .electrical = .{
            .band_start_hz = 1e9,
            .band_end_hz = 12e9,
            .return_loss_target_db = 20,
            .start_section = .{ .length_mm = 2, .z_ohm = 20 },
        },
    }, null);
    try testing.expect(result.feasible);
    try testing.expect(!result.success);
    try testing.expect(result.metrics.electrical.worst_return_loss_db < 20);
    try testing.expect(result.metrics.objective > 0);
}

// spec: placement/rf-port-frame-routing - clearance probe makes an otherwise smooth candidate infeasible
test "clearance probe makes an otherwise smooth candidate infeasible" {
    const Block = struct {
        fn clear(_: @This(), a: [2]f64, b: [2]f64, _: f64) bool {
            return @max(a[0], b[0]) < 4 or @min(a[0], b[0]) > 5;
        }
    };
    const testing = std.testing;
    var owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer owner.deinit();
    const arena = owner.allocator();
    const guide = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 } };
    const block = Block{};
    const result = try solve(arena, .{
        .start = .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .end = .{ .at = .{ 10, 0 }, .tangent = .{ 1, 0 } },
        .guide = &guide,
        .geometry = .{ .width_mm = 0.2 },
        .electrical = .{ .band_start_hz = 1e9, .band_end_hz = 6e9 },
    }, &block);
    try testing.expect(!result.feasible);
    try testing.expect(!result.metrics.clearance.ok);
    try testing.expect(result.metrics.clearance.blocked_at_mm != null);
}

// spec: placement/rf-port-frame-routing - frame fit rejects cramped tangent intersection and accepts a straight spoke
test "frame fit rejects cramped tangent intersection and accepts a straight spoke" {
    const testing = std.testing;
    const straight = frameFit(
        .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .{ .at = .{ 2, 0 }, .tangent = .{ 1, 0 } },
        0.25,
        3,
        0.25,
    );
    try testing.expect(straight.feasible);
    try testing.expect(straight.straight);

    const cramped = frameFit(
        .{ .at = .{ 0, 0 }, .tangent = .{ 1, 0 } },
        .{ .at = .{ 0.4, 0.4 }, .tangent = .{ 0, 1 } },
        0.25,
        3,
        0.25,
    );
    try testing.expect(!cramped.feasible);
}

test "early lateral profile is constructible from the shorter capacitor end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const input = Input{
        .start = .{ .at = .{ 14.607, 12.029 }, .tangent = .{ 0, -1 } },
        .end = .{ .at = .{ 8.178, 5.6 }, .tangent = .{ -1, 0 } },
        .guide = &.{},
        .geometry = .{
            .width_mm = 0.2,
            .min_radius_ratio = 3,
            .min_entry_mm = 0.2,
            .start_entry_mm = 0.52,
            .end_entry_mm = 1.7,
        },
        .electrical = .{ .band_start_hz = 60e6, .band_end_hz = 6e9 },
    };
    const candidate = try buildCandidate(arena_state.allocator(), input, 3, 0.35, 3, null);
    try std.testing.expect(candidate.samples.len > 2);
    try std.testing.expect(candidate.metrics.entry.start_straight_mm >= 0.52);
    try std.testing.expect(candidate.metrics.entry.end_straight_mm >= 1.7);
}
