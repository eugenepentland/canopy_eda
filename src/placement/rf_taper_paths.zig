//! Recover exact swept copper for straight RF tapers emitted by `pad_neck`.
//!
//! The router keeps ordinary tracks as edit handles. A width-changing launch
//! is therefore emitted as short, constant-width segments, but drawing those
//! segments as round-ended capsules makes their union bulge past the intended
//! taper. This final-output adapter records the endpoint widths that describe
//! the exact butt-ended sweep. On a two-pad RF chain it also carries a taper
//! through a bend when the straight pad-exit leg ends before the profile does,
//! matching the hand router's arclength-based taper. The same adapter is reused
//! after route-plan rescue, because that ladder can replace an already-finished
//! net after the router's ordinary output seam has run.

const std = @import("std");
const bend_smooth = @import("bend_smooth.zig");
const copper_contact = @import("copper_contact.zig");
const optimizer = @import("optimizer.zig");
const pad_shape = @import("pad_shape.zig");
const rf_path_solver = @import("rf_path_solver.zig");
const rf_port_report = @import("rf_port_report.zig");
const router = @import("router.zig");
const variable_width_copper = @import("variable_width_copper.zig");

const eps: f64 = 1e-7;
const taper_step_mm: f64 = 0.025;
const rf_taper_widths: f64 = 1.2;

fn eligible(rule: optimizer.NetRule) bool {
    return rule.rf.impedance.ohms > 0 and rule.rf.impedance.diff_ohms <= 0;
}

fn hasSuccessfulPath(
    outcomes: []const rf_port_report.Outcome,
    tracks: []const router.Track,
    net: i32,
) bool {
    for (outcomes) |outcome| {
        if (outcome.net != net or !outcome.success) continue;
        if (outcome.physical.gate_removed or outcome.physical.samples.len < 2) continue;
        for (tracks) |track| {
            if (track.net != net or track.layer != outcome.physical.layer) continue;
            if (variable_width_copper.ownsTrack(outcome.physical.samples, track)) return true;
        }
    }
    return false;
}

fn continuesStraight(points: []const [2]f64, vertex: usize) bool {
    const a = points[vertex - 1];
    const b = points[vertex];
    const c = points[vertex + 1];
    const ab = [2]f64{ b[0] - a[0], b[1] - a[1] };
    const bc = [2]f64{ c[0] - b[0], c[1] - b[1] };
    const ab_len = std.math.hypot(ab[0], ab[1]);
    const bc_len = std.math.hypot(bc[0], bc[1]);
    if (ab_len <= eps or bc_len <= eps) return false;
    const cross = @abs(ab[0] * bc[1] - ab[1] * bc[0]);
    const dot = ab[0] * bc[0] + ab[1] * bc[1];
    return cross <= eps * ab_len * bc_len and dot > 0;
}

fn varyingWidths(widths: []const f64) bool {
    if (widths.len < 2) return false;
    for (widths[1..]) |width| if (@abs(width - widths[0]) > eps) return true;
    return false;
}

const EndProfile = struct {
    width: f64,
    land: f64,
    taper: f64,
};

fn pointDistance(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn chainLength(chain: bend_smooth.Chain) f64 {
    var total: f64 = 0;
    for (chain.pts[1..], 1..) |point, i| total += pointDistance(chain.pts[i - 1], point);
    return total;
}

/// Recover the land plateau from conservative pad-neck slices. On a taper
/// from a wide land the first taper cell has the same (wider-end) width as the
/// plateau and `extractChains` merges them; subtract one known slicer step to
/// put the width station back at the real land boundary.
fn inferEndProfile(chain: bend_smooth.Chain, nominal: f64, reverse: bool) ?EndProfile {
    if (chain.widths.len < 2) return null;
    const endpoint_width = if (reverse) chain.widths[chain.widths.len - 1] else chain.widths[0];
    if (@abs(endpoint_width - nominal) <= eps) return null;
    var distance: f64 = 0;
    for (0..chain.widths.len) |walk_i| {
        const i = if (reverse) chain.widths.len - 1 - walk_i else walk_i;
        const leg = pointDistance(chain.pts[i], chain.pts[i + 1]);
        if (@abs(chain.widths[i] - endpoint_width) > eps) {
            const merged = if (endpoint_width > nominal + eps) @min(leg, taper_step_mm) else 0;
            return .{
                .width = endpoint_width,
                .land = @max(0, distance - merged),
                .taper = nominal * rf_taper_widths,
            };
        }
        distance += leg;
    }
    return null;
}

fn profileWidth(distance: f64, profile: EndProfile, nominal: f64) f64 {
    if (distance <= profile.land) return profile.width;
    if (distance >= profile.land + profile.taper or profile.taper <= eps) return nominal;
    const f = (distance - profile.land) / profile.taper;
    return profile.width + (nominal - profile.width) * std.math.clamp(f, 0, 1);
}

fn chainWidthAt(s: f64, total: f64, nominal: f64, start: ?EndProfile, end: ?EndProfile) f64 {
    const start_active = if (start) |profile| s < profile.land + profile.taper else false;
    const end_active = if (end) |profile| total - s < profile.land + profile.taper else false;
    const start_width = if (start) |profile| profileWidth(s, profile, nominal) else nominal;
    const end_width = if (end) |profile| profileWidth(total - s, profile, nominal) else nominal;
    if (start_active and end_active) {
        if (start_width <= nominal and end_width <= nominal) return @min(start_width, end_width);
        if (start_width >= nominal and end_width >= nominal) return @max(start_width, end_width);
        const f = if (total > eps) std.math.clamp(s / total, 0, 1) else 0;
        return start_width + (end_width - start_width) * f;
    }
    if (start_active) return start_width;
    if (end_active) return end_width;
    return nominal;
}

fn pointOnChain(chain: bend_smooth.Chain, target: f64) [2]f64 {
    var distance: f64 = 0;
    for (chain.pts[1..], 1..) |point, i| {
        const before = chain.pts[i - 1];
        const leg = pointDistance(before, point);
        if (target <= distance + leg + eps) {
            const f = if (leg > eps) std.math.clamp((target - distance) / leg, 0, 1) else 0;
            return .{ before[0] + (point[0] - before[0]) * f, before[1] + (point[1] - before[1]) * f };
        }
        distance += leg;
    }
    return chain.pts[chain.pts.len - 1];
}

fn appendStation(stations: *std.ArrayList(f64), arena: std.mem.Allocator, value: f64, total: f64) std.mem.Allocator.Error!void {
    if (value > eps and value < total - eps) try stations.append(arena, value);
}

/// Build one arclength-profiled path over the complete two-pad chain. The
/// input slices prove the endpoint widths and land lengths; the declared RF
/// taper length remains authoritative after the first straight leg ends.
fn profiledChainSamples(
    arena: std.mem.Allocator,
    chain: bend_smooth.Chain,
    nominal: f64,
) std.mem.Allocator.Error!?[]const rf_path_solver.Sample {
    const start = inferEndProfile(chain, nominal, false);
    const end = inferEndProfile(chain, nominal, true);
    if (start == null and end == null) return null;
    const total = chainLength(chain);
    if (total <= eps) return null;
    var stations: std.ArrayList(f64) = .empty;
    try stations.append(arena, 0);
    var distance: f64 = 0;
    for (chain.pts[1..], 1..) |point, i| {
        distance += pointDistance(chain.pts[i - 1], point);
        try stations.append(arena, distance);
    }
    if (start) |profile| {
        try appendStation(&stations, arena, profile.land, total);
        try appendStation(&stations, arena, profile.land + profile.taper, total);
    }
    if (end) |profile| {
        try appendStation(&stations, arena, total - profile.land, total);
        try appendStation(&stations, arena, total - profile.land - profile.taper, total);
    }
    std.mem.sort(f64, stations.items, {}, std.sort.asc(f64));
    var samples: std.ArrayList(rf_path_solver.Sample) = .empty;
    for (stations.items) |station| {
        if (samples.items.len > 0 and @abs(station - samples.items[samples.items.len - 1].s_mm) <= eps) continue;
        try samples.append(arena, .{
            .at = pointOnChain(chain, station),
            .s_mm = station,
            .curvature = 0,
            .width_mm = chainWidthAt(station, total, nominal, start, end),
        });
    }
    const owned: []const rf_path_solver.Sample = try samples.toOwnedSlice(arena);
    return owned;
}

/// The pad-neck slicer assigns each cell the wider of its two true endpoint
/// widths. At a shared boundary the narrower of the adjacent cell widths is
/// therefore the original linear profile value, for both rising and falling
/// tapers.
fn samplesForRun(
    arena: std.mem.Allocator,
    points: []const [2]f64,
    widths: []const f64,
) std.mem.Allocator.Error![]const rf_path_solver.Sample {
    var samples: std.ArrayList(rf_path_solver.Sample) = .empty;
    var distance: f64 = 0;
    try samples.append(arena, .{ .at = points[0], .s_mm = 0, .curvature = 0, .width_mm = widths[0] });
    for (1..points.len - 1) |i| {
        const point = points[i];
        const prior_point = points[i - 1];
        const leg = std.math.hypot(point[0] - prior_point[0], point[1] - prior_point[1]);
        const prior_width = widths[i - 1];
        const next_width = widths[i];

        // `extractChains` coalesces equal-width collinear slices. At the flat
        // end of a taper that folds the first conservative taper cell into the
        // plateau, moving the apparent width station one cell outward. Recover
        // the true station from the adjacent unmerged taper-cell length.
        if (prior_width > next_width + eps and i + 1 < widths.len and
            @abs(widths[i + 1] - next_width) > eps)
        {
            const after = points[i + 1];
            const step = std.math.hypot(after[0] - point[0], after[1] - point[1]);
            if (step > eps and leg > step + eps) {
                const f = (leg - step) / leg;
                const at = [2]f64{
                    prior_point[0] + (point[0] - prior_point[0]) * f,
                    prior_point[1] + (point[1] - prior_point[1]) * f,
                };
                try samples.append(arena, .{ .at = at, .s_mm = distance + leg - step, .curvature = 0, .width_mm = prior_width });
            }
        }
        distance += leg;
        try samples.append(arena, .{ .at = point, .s_mm = distance, .curvature = 0, .width_mm = @min(prior_width, next_width) });

        // The mirror case: the final conservative taper cell merged into the
        // following plateau. Its true wide station sits one preceding cell
        // length after this vertex.
        if (next_width > prior_width + eps and i >= 2 and
            @abs(widths[i - 2] - prior_width) > eps)
        {
            const before = points[i - 1];
            const step = std.math.hypot(point[0] - before[0], point[1] - before[1]);
            const after = points[i + 1];
            const next_leg = std.math.hypot(after[0] - point[0], after[1] - point[1]);
            if (step > eps and next_leg > step + eps) {
                const f = step / next_leg;
                const at = [2]f64{
                    point[0] + (after[0] - point[0]) * f,
                    point[1] + (after[1] - point[1]) * f,
                };
                try samples.append(arena, .{ .at = at, .s_mm = distance + step, .curvature = 0, .width_mm = next_width });
            }
        }
    }
    const last = points[points.len - 1];
    const prior = points[points.len - 2];
    distance += std.math.hypot(last[0] - prior[0], last[1] - prior[1]);
    try samples.append(arena, .{ .at = last, .s_mm = distance, .curvature = 0, .width_mm = widths[widths.len - 1] });
    return samples.toOwnedSlice(arena);
}

fn appendRun(
    arena: std.mem.Allocator,
    out: *std.ArrayList(rf_port_report.Outcome),
    net: i32,
    layer: u8,
    points: []const [2]f64,
    widths: []const f64,
) std.mem.Allocator.Error!void {
    if (!varyingWidths(widths)) return;
    const samples = try samplesForRun(arena, points, widths);
    try appendSamples(arena, out, net, layer, widths.len, samples);
}

fn appendSamples(
    arena: std.mem.Allocator,
    out: *std.ArrayList(rf_port_report.Outcome),
    net: i32,
    layer: u8,
    emitted_tracks: usize,
    samples: []const rf_path_solver.Sample,
) std.mem.Allocator.Error!void {
    try out.append(arena, .{
        .net = net,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{
            .sample_count = samples.len,
            .emitted_tracks = emitted_tracks,
            .samples = samples,
            .layer = layer,
        },
    });
}

const ChainContext = struct {
    net: i32,
    layer: u8,
    nominal: f64,
    two_pin: bool,
};

fn appendChainTapers(
    arena: std.mem.Allocator,
    out: *std.ArrayList(rf_port_report.Outcome),
    context: ChainContext,
    chain: bend_smooth.Chain,
) std.mem.Allocator.Error!void {
    if (chain.widths.len < 2 or chain.pts.len != chain.widths.len + 1) return;
    if (context.two_pin) {
        if (try profiledChainSamples(arena, chain, context.nominal)) |samples| {
            try appendSamples(arena, out, context.net, context.layer, chain.widths.len, samples);
            return;
        }
    }
    var first_leg: usize = 0;
    var vertex: usize = 1;
    while (vertex < chain.pts.len - 1) : (vertex += 1) {
        if (continuesStraight(chain.pts, vertex)) continue;
        try appendRun(arena, out, context.net, context.layer, chain.pts[first_leg .. vertex + 1], chain.widths[first_leg..vertex]);
        first_leg = vertex;
    }
    try appendRun(arena, out, context.net, context.layer, chain.pts[first_leg..], chain.widths[first_leg..]);
}

/// Capture one exact swept path for every straight autorouter taper that had
/// to fall back to pad-neck slices. This runs immediately after `pad_neck`,
/// before the final gloss is allowed to collapse those slices against their
/// pads. A successful G2 path already carries the authoritative full-net
/// width profile and wins.
pub fn exactFallbacks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: []const router.Track,
    outcomes: []const rf_port_report.Outcome,
) std.mem.Allocator.Error![]const rf_port_report.Outcome {
    var out: std.ArrayList(rf_port_report.Outcome) = .empty;
    for (0..placement.nets.len) |net_i| {
        if (net_i >= placement.rules.net.len or !eligible(placement.rules.net[net_i])) continue;
        const net: i32 = @intCast(net_i);
        if (hasSuccessfulPath(outcomes, tracks, net)) continue;
        var layers: [256]bool = @splat(false);
        for (tracks) |track| {
            if (track.net == net) layers[track.layer] = true;
        }
        for (layers, 0..) |present, layer_i| {
            if (!present) continue;
            var mine: std.ArrayList(router.Track) = .empty;
            for (tracks) |track| {
                if (track.net == net and track.layer == layer_i) try mine.append(arena, track);
            }
            const chains = try bend_smooth.extractChains(arena, mine.items);
            const rule = placement.rules.net[net_i];
            const nominal = if (rule.width > 0) rule.width else placement.rules.design.track_width;
            const context = ChainContext{
                .net = net,
                .layer = @intCast(layer_i),
                .nominal = nominal,
                .two_pin = placement.nets[net_i].pins.len == 2,
            };
            for (chains) |chain| try appendChainTapers(arena, &out, context, chain);
        }
    }
    return out.toOwnedSlice(arena);
}

fn straightRunOwnsTrack(samples: []const rf_path_solver.Sample, track: router.Track) bool {
    if (samples.len < 2) return false;
    const first = samples[0].at;
    const last = samples[samples.len - 1].at;
    const dx = last[0] - first[0];
    const dy = last[1] - first[1];
    const len_sq = dx * dx + dy * dy;
    if (len_sq <= eps * eps) return false;
    const len = @sqrt(len_sq);
    const cross_a = @abs((track.x1 - first[0]) * dy - (track.y1 - first[1]) * dx) / len;
    const cross_b = @abs((track.x2 - first[0]) * dy - (track.y2 - first[1]) * dx) / len;
    if (cross_a > 0.011 or cross_b > 0.011) return false;
    var ta = ((track.x1 - first[0]) * dx + (track.y1 - first[1]) * dy) / len_sq;
    var tb = ((track.x2 - first[0]) * dx + (track.y2 - first[1]) * dy) / len_sq;
    if (ta > tb) std.mem.swap(f64, &ta, &tb);
    if (ta < -eps or tb > 1 + eps) return false;

    var widest: f64 = 0;
    var conservative_step: f64 = 0;
    for (samples, 0..) |sample, i| {
        const t = ((sample.at[0] - first[0]) * dx + (sample.at[1] - first[1]) * dy) / len_sq;
        if (t >= ta - eps and t <= tb + eps) widest = @max(widest, sample.width_mm);
        if (i == 0) continue;
        const prior = samples[i - 1];
        const prior_t = ((prior.at[0] - first[0]) * dx + (prior.at[1] - first[1]) * dy) / len_sq;
        if (t <= prior_t + eps) continue;
        if (t >= ta - eps and prior_t <= tb + eps)
            conservative_step = @max(conservative_step, @abs(sample.width_mm - prior.width_mm));
        for ([_]f64{ ta, tb }) |edge| {
            if (edge < prior_t - eps or edge > t + eps) continue;
            const f = std.math.clamp((edge - prior_t) / (t - prior_t), 0, 1);
            widest = @max(widest, prior.width_mm + (sample.width_mm - prior.width_mm) * f);
        }
    }
    // Each pad-neck edit slice uses its wider endpoint. Final gloss may trim
    // that slice inward, leaving a short subspan whose exact local width is up
    // to one profile step narrower even though it is still the same generated
    // taper handle. Admit precisely that adjacent-step overshoot.
    return track.width <= widest + conservative_step + router.clearance_eps;
}

fn samplesContinueStraight(samples: []const rf_path_solver.Sample, vertex: usize) bool {
    const points = [3][2]f64{ samples[vertex - 1].at, samples[vertex].at, samples[vertex + 1].at };
    return continuesStraight(&points, 1);
}

fn fallbackOwnsTrack(path: rf_port_report.Outcome, track: router.Track) bool {
    if (!path.success or path.physical.gate_removed) return false;
    if (path.net != track.net or path.physical.layer != track.layer) return false;
    const samples = path.physical.samples;
    if (samples.len < 2) return false;
    var first: usize = 0;
    for (1..samples.len - 1) |vertex| {
        if (samplesContinueStraight(samples, vertex)) continue;
        if (straightRunOwnsTrack(samples[first .. vertex + 1], track)) return true;
        first = vertex;
    }
    return straightRunOwnsTrack(samples[first..], track);
}

fn pathDistance(path: rf_port_report.Outcome, other: router.Track) f64 {
    var best = std.math.inf(f64);
    const samples = path.physical.samples;
    for (samples[1..], 1..) |sample, i| {
        best = @min(best, pad_shape.segSegDist(
            samples[i - 1].at,
            sample.at,
            .{ other.x1, other.y1 },
            .{ other.x2, other.y2 },
        ));
    }
    return best;
}

fn compactCentrelineTouches(
    fallbacks: []const rf_port_report.Outcome,
    track: router.Track,
    other: router.Track,
) bool {
    for (fallbacks) |path| {
        if (!fallbackOwnsTrack(path, track)) continue;
        if (pathDistance(path, other) <= copper_contact.join_slack_mm) return true;
    }
    return false;
}

fn closestPathBridge(
    fallbacks: []const rf_port_report.Outcome,
    track: router.Track,
    other: router.Track,
) ?router.Track {
    for (fallbacks) |path| {
        if (!fallbackOwnsTrack(path, track)) continue;
        const samples = path.physical.samples;
        var best: ?router.Track = null;
        var best_len = std.math.inf(f64);
        for (samples[1..], 1..) |sample, i| {
            const a = samples[i - 1].at;
            const b = sample.at;
            const dx = b[0] - a[0];
            const dy = b[1] - a[1];
            const len_sq = dx * dx + dy * dy;
            if (len_sq <= eps * eps) continue;
            for ([_][2]f64{ .{ other.x1, other.y1 }, .{ other.x2, other.y2 } }) |point| {
                const t = std.math.clamp(((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / len_sq, 0, 1);
                const projected = [2]f64{ a[0] + dx * t, a[1] + dy * t };
                const distance = std.math.hypot(point[0] - projected[0], point[1] - projected[1]);
                if (distance >= best_len) continue;
                best_len = distance;
                best = .{
                    .x1 = point[0],
                    .y1 = point[1],
                    .x2 = projected[0],
                    .y2 = projected[1],
                    .layer = track.layer,
                    // The bridge is outside the land-axis taper exemption. Use
                    // the wider adjoining handle so it stays class-width legal.
                    .width = @max(track.width, other.width),
                    .net = track.net,
                };
            }
        }
        if (best_len > copper_contact.join_slack_mm) return best;
    }
    return null;
}

fn appendStraightHandle(
    arena: std.mem.Allocator,
    out: *std.ArrayList(router.Track),
    path: rf_port_report.Outcome,
    samples: []const rf_path_solver.Sample,
) std.mem.Allocator.Error!void {
    if (samples.len < 2) return;
    var width = samples[0].width_mm;
    for (samples[1..]) |sample| width = @min(width, sample.width_mm);
    const first = samples[0].at;
    const last = samples[samples.len - 1].at;
    if (pointDistance(first, last) <= eps) return;
    try out.append(arena, .{
        .x1 = first[0],
        .y1 = first[1],
        .x2 = last[0],
        .y2 = last[1],
        .layer = path.physical.layer,
        .width = width,
        .net = path.net,
    });
}

fn appendPathHandles(
    arena: std.mem.Allocator,
    out: *std.ArrayList(router.Track),
    path: rf_port_report.Outcome,
) std.mem.Allocator.Error!void {
    const samples = path.physical.samples;
    var first: usize = 0;
    for (1..samples.len - 1) |vertex| {
        if (samplesContinueStraight(samples, vertex)) continue;
        try appendStraightHandle(arena, out, path, samples[first .. vertex + 1]);
        first = vertex;
    }
    try appendStraightHandle(arena, out, path, samples[first..]);
}

/// Replace the conservative capsule slices owned by freshly captured fallback
/// paths with one narrow centreline handle per path. The handle keeps editor
/// connectivity and selection, while every physical consumer suppresses it in
/// favour of the exact swept path. This deliberately accepts sub-sample
/// endpoints: final gloss can snap a slice inside its own pad after capture.
pub fn compactFallbackHandles(
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(router.Track),
    fallbacks: []const rf_port_report.Outcome,
) std.mem.Allocator.Error!void {
    if (fallbacks.len == 0) return;
    const owned = try arena.alloc(bool, tracks.items.len);
    for (tracks.items, owned) |track, *slot| {
        slot.* = false;
        for (fallbacks) |path| {
            if (fallbackOwnsTrack(path, track)) {
                slot.* = true;
                break;
            }
        }
    }
    var out: std.ArrayList(router.Track) = .empty;
    var bridges: std.ArrayList(router.Track) = .empty;
    for (tracks.items, 0..) |track, i| {
        if (!owned[i]) {
            try out.append(arena, track);
            continue;
        }
        // Keep an owned slice when it is the actual copper bridge into a
        // branch whose centreline does not land exactly on the compact path.
        // Physical consumers still suppress this handle in favour of the exact
        // swept polygon; the topology oracle retains the overlap that made the
        // routed board connected before compaction.
        for (tracks.items, owned, 0..) |other, other_owned, j| {
            if (i == j or other_owned or other.net != track.net or other.layer != track.layer) continue;
            const contact = (track.width + other.width) / 2 + copper_contact.join_slack_mm;
            if (pad_shape.segSegDist(
                .{ track.x1, track.y1 },
                .{ track.x2, track.y2 },
                .{ other.x1, other.y1 },
                .{ other.x2, other.y2 },
            ) <= contact and !compactCentrelineTouches(fallbacks, track, other)) {
                try out.append(arena, track);
                if (closestPathBridge(fallbacks, track, other)) |bridge| try bridges.append(arena, bridge);
                break;
            }
        }
    }
    try out.appendSlice(arena, bridges.items);
    for (fallbacks) |path| {
        if (!path.success or path.physical.gate_removed or path.physical.samples.len < 2) continue;
        try appendPathHandles(arena, &out, path);
    }
    tracks.clearRetainingCapacity();
    try tracks.appendSlice(arena, out.items);
}

// spec: placement/rf-port-frame-routing - autorouter fallback tapers are captured before final copper cleanup, including two-sided pad-to-pad profiles, then exported as exact straight-sided swept copper with hidden connectivity handles instead of overlapping round-ended slices
test "autorouter fallback taper recovers exact endpoint widths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const points = [_][2]f64{ .{ 0, 0 }, .{ 0.25, 0 }, .{ 0.5, 0 }, .{ 0.75, 0 } };
    const widths = [_]f64{ 1.8, 1.2, 0.6 };
    var outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    try appendChainTapers(arena, &outcomes, .{ .net = 7, .layer = 0, .nominal = 0.6, .two_pin = false }, .{
        .pts = try arena.dupe([2]f64, &points),
        .widths = try arena.dupe(f64, &widths),
    });
    try std.testing.expectEqual(@as(usize, 1), outcomes.items.len);
    const samples = outcomes.items[0].physical.samples;
    try std.testing.expectEqual(@as(f64, 1.8), samples[0].width_mm);
    try std.testing.expectEqual(@as(f64, 1.2), samples[1].width_mm);
    try std.testing.expectEqual(@as(f64, 0.6), samples[2].width_mm);
    try std.testing.expectEqual(@as(f64, 0.6), samples[3].width_mm);
    try std.testing.expectEqual(@as(f64, 0.75), samples[3].s_mm);
    const pieces = try variable_width_copper.pieces(arena, samples);
    try std.testing.expectEqual(@as(usize, 3), pieces.len);
    try std.testing.expectEqual([2]f64{ 0, 0.9 }, pieces[0].poly[0]);
    try std.testing.expectEqual([2]f64{ 0.25, 0.6 }, pieces[0].poly[1]);
}

test "fallback detection retains two-sided tapers and splits bends" {
    try std.testing.expect(varyingWidths(&.{ 1.8, 1.2, 0.6 }));
    try std.testing.expect(varyingWidths(&.{ 0.2, 0.4, 0.6 }));
    try std.testing.expect(varyingWidths(&.{ 1.02, 0.3124, 1.02 }));
    try std.testing.expect(!varyingWidths(&.{ 0.3, 0.3, 0.3 }));
    try std.testing.expect(continuesStraight(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 } }, 1));
    try std.testing.expect(!continuesStraight(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } }, 1));
}

test "stale successful RF metadata does not suppress fallback regeneration" {
    const stale_samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 1.8 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.3124 },
    };
    const outcomes = [_]rf_port_report.Outcome{.{
        .net = 3,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .samples = &stale_samples, .sample_count = stale_samples.len, .layer = 0 },
    }};
    const moved = [_]router.Track{.{ .x1 = 0, .y1 = 0.1, .x2 = 1, .y2 = 0.1, .layer = 0, .width = 0.3124, .net = 3 }};
    const owned = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3124, .net = 3 }};
    try std.testing.expect(!hasSuccessfulPath(&outcomes, &moved, 3));
    try std.testing.expect(hasSuccessfulPath(&outcomes, &owned, 3));
}

// spec: placement/rf-port-frame-routing - an autorouter pad taper that outlives its straight escape leg continues linearly by arclength through the following bend instead of ending in a width step at the corner
test "two-pad fallback carries an unfinished taper through its bend" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const points = [_][2]f64{
        .{ 0, 0 },
        .{ 0.925, 0 },
        .{ 0.95, 0 },
        .{ 1.0, 0.05 },
        .{ 1.3, 0.35 },
    };
    const widths = [_]f64{ 1.02, 0.9728, 0.8312, 0.3124 };
    var outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    try appendChainTapers(arena, &outcomes, .{ .net = 4, .layer = 0, .nominal = 0.3124, .two_pin = true }, .{
        .pts = try arena.dupe([2]f64, &points),
        .widths = try arena.dupe(f64, &widths),
    });
    try std.testing.expectEqual(@as(usize, 1), outcomes.items.len);
    const samples = outcomes.items[0].physical.samples;
    var bend_width: ?f64 = null;
    for (samples) |sample| {
        if (pointDistance(sample.at, .{ 1.0, 0.05 }) <= eps) bend_width = sample.width_mm;
    }
    try std.testing.expect(bend_width != null);
    try std.testing.expect(bend_width.? > 0.7 and bend_width.? < 0.9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.02), samples[0].width_mm, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3124), samples[samples.len - 1].width_mm, 1e-12);

    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.925, .y2 = 0, .layer = 0, .width = 1.02, .net = 4 },
        .{ .x1 = 0.925, .y1 = 0, .x2 = 0.95, .y2 = 0, .layer = 0, .width = 0.9728, .net = 4 },
        .{ .x1 = 0.95, .y1 = 0, .x2 = 1.0, .y2 = 0.05, .layer = 0, .width = 0.8312, .net = 4 },
        .{ .x1 = 1.0, .y1 = 0.05, .x2 = 1.3, .y2 = 0.35, .layer = 0, .width = 0.3124, .net = 4 },
    });
    try compactFallbackHandles(arena, &tracks, outcomes.items);
    try std.testing.expectEqual(@as(usize, 2), tracks.items.len);
}

test "fallback compaction removes gloss-snapped capsules and keeps one handle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 1.02 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.3 },
        .{ .at = .{ 2, 0 }, .s_mm = 2, .curvature = 0, .width_mm = 1.02 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 4,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .samples = &samples, .sample_count = samples.len, .layer = 0 },
    }};
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 1.02, .net = 4 },
        // Final gloss snapped this endpoint between two captured samples.
        .{ .x1 = 1.9, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 1.02, .net = 4 },
        .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = 1, .layer = 0, .width = 0.3, .net = 4 },
    });
    try compactFallbackHandles(arena, &tracks, &paths);
    try std.testing.expectEqual(@as(usize, 2), tracks.items.len);
    try std.testing.expectEqual(@as(f64, 1), tracks.items[0].x2);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[1].x1);
    try std.testing.expectEqual(@as(f64, 2), tracks.items[1].x2);
    try std.testing.expectEqual(@as(f64, 0.3), tracks.items[1].width);
}

test "fallback compaction preserves a hidden slice that joins an offset branch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.6 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.3 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 2,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .samples = &samples, .sample_count = samples.len, .layer = 0 },
    }};
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3, .net = 2 },
        .{ .x1 = 0.8, .y1 = 0.12, .x2 = 0.8, .y2 = 1, .layer = 0, .width = 0.3, .net = 2 },
    });
    try compactFallbackHandles(arena, &tracks, &paths);
    try std.testing.expectEqual(@as(usize, 4), tracks.items.len);
}
