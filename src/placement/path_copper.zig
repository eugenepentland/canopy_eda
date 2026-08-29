//! Physical track probes for swept variable-width copper paths.
//!
//! Saved layouts keep a compact constant-width centreline as the editor handle
//! for a taper. Rendering and fabrication use the path's swept polygon; rules
//! that operate on capsules receive a private chord lowering here so those
//! handles never become the physical-width authority.

const std = @import("std");
const polygon_outline = @import("outline.zig");
const router = @import("router.zig");
const rf_port_report = @import("rf_port_report.zig");
const variable_width_copper = @import("variable_width_copper.zig");
const Sample = @import("rf_path_solver.zig").Sample;

const eps: f64 = 1e-9;
const miter_limit: f64 = 2;

fn samePoint(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= 1e-7 and @abs(a[1] - b[1]) <= 1e-7;
}

fn unit(v: [2]f64) [2]f64 {
    const len = std.math.hypot(v[0], v[1]);
    return if (len > eps) .{ v[0] / len, v[1] / len } else .{ 1, 0 };
}

fn appendPoint(arena: std.mem.Allocator, points: *std.ArrayList([2]f64), point: [2]f64) std.mem.Allocator.Error!void {
    if (points.items.len > 0 and samePoint(points.items[points.items.len - 1], point)) return;
    try points.append(arena, point);
}

const OffsetInput = struct {
    point: [2]f64,
    before: [2]f64,
    after: [2]f64,
    half: f64,
    endpoint: bool,
};

fn appendOffset(arena: std.mem.Allocator, out: *std.ArrayList([2]f64), in: OffsetInput, side: f64) std.mem.Allocator.Error!void {
    const point = in.point;
    const before = in.before;
    const after = in.after;
    const half = in.half;
    const na = [2]f64{ -before[1] * side, before[0] * side };
    const nb = [2]f64{ -after[1] * side, after[0] * side };
    if (in.endpoint) return appendPoint(arena, out, .{ point[0] + nb[0] * half, point[1] + nb[1] * half });
    var mx = na[0] + nb[0];
    var my = na[1] + nb[1];
    const ml = std.math.hypot(mx, my);
    if (ml > eps) {
        mx /= ml;
        my /= ml;
        const denom = mx * nb[0] + my * nb[1];
        const offset = if (denom > eps) half / denom else std.math.inf(f64);
        if (offset <= half * miter_limit + eps)
            return appendPoint(arena, out, .{ point[0] + mx * offset, point[1] + my * offset });
    }
    try appendPoint(arena, out, .{ point[0] + na[0] * half, point[1] + na[1] * half });
    try appendPoint(arena, out, .{ point[0] + nb[0] * half, point[1] + nb[1] * half });
}

/// Collapse consecutive coincident centreline samples before any geometry is
/// derived. Keeping the widest sample in a run makes rendering, fabrication,
/// and conservative DRC lowering agree even on malformed legacy sidecars.
fn cleanSamples(arena: std.mem.Allocator, samples: []const Sample) std.mem.Allocator.Error![]const Sample {
    var out: std.ArrayList(Sample) = .empty;
    for (samples) |sample| {
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (std.math.hypot(sample.at[0] - last.at[0], sample.at[1] - last.at[1]) <= eps) {
                last.width_mm = @max(last.width_mm, sample.width_mm);
                continue;
            }
        }
        try out.append(arena, sample);
    }
    return out.toOwnedSlice(arena);
}

/// Exact filled outline of a sampled variable-width centreline. Ordinary
/// corners use a bounded miter. Reversals and over-limit miters use a bevel,
/// which keeps the polygon local and prevents the inward sliver produced by
/// clamping one synthetic miter point away from both true offset edges.
fn outlineClean(arena: std.mem.Allocator, samples: []const Sample) std.mem.Allocator.Error![]const [2]f64 {
    if (samples.len < 2) return &.{};
    var left: std.ArrayList([2]f64) = .empty;
    var right: std.ArrayList([2]f64) = .empty;
    for (samples, 0..) |sample, i| {
        const before = if (i == 0)
            unit(.{ samples[1].at[0] - sample.at[0], samples[1].at[1] - sample.at[1] })
        else
            unit(.{ sample.at[0] - samples[i - 1].at[0], sample.at[1] - samples[i - 1].at[1] });
        const after = if (i + 1 == samples.len)
            before
        else
            unit(.{ samples[i + 1].at[0] - sample.at[0], samples[i + 1].at[1] - sample.at[1] });
        const half = @max(sample.width_mm, eps) / 2;
        const in = OffsetInput{ .point = sample.at, .before = before, .after = after, .half = half, .endpoint = i == 0 or i + 1 == samples.len };
        try appendOffset(arena, &left, in, 1);
        try appendOffset(arena, &right, in, -1);
    }
    var polygon: std.ArrayList([2]f64) = .empty;
    try polygon.appendSlice(arena, left.items);
    var i = right.items.len;
    while (i > 0) {
        i -= 1;
        try appendPoint(arena, &polygon, right.items[i]);
    }
    return polygon.toOwnedSlice(arena);
}

/// Return the compact swept outline after normalizing consecutive duplicate
/// samples and preserving the widest width attached to each coordinate.
pub fn outline(arena: std.mem.Allocator, samples: []const Sample) std.mem.Allocator.Error![]const [2]f64 {
    return outlineClean(arena, try cleanSamples(arena, samples));
}

fn segmentRegion(arena: std.mem.Allocator, a: Sample, b: Sample) std.mem.Allocator.Error![]const [2]f64 {
    const direction = unit(.{ b.at[0] - a.at[0], b.at[1] - a.at[1] });
    const normal = [2]f64{ -direction[1], direction[0] };
    const ah = @max(a.width_mm, eps) / 2;
    const bh = @max(b.width_mm, eps) / 2;
    const region = try arena.alloc([2]f64, 4);
    region[0] = .{ a.at[0] + normal[0] * ah, a.at[1] + normal[1] * ah };
    region[1] = .{ b.at[0] + normal[0] * bh, b.at[1] + normal[1] * bh };
    region[2] = .{ b.at[0] - normal[0] * bh, b.at[1] - normal[1] * bh };
    region[3] = .{ a.at[0] - normal[0] * ah, a.at[1] - normal[1] * ah };
    return region;
}

/// A convex, clockwise join between the two butt-ended segment envelopes at
/// one centreline sample. The four candidates all lie on one circle, so an
/// angular sort is their convex hull after duplicate directions are removed.
fn joinRegion(arena: std.mem.Allocator, samples: []const Sample, i: usize) std.mem.Allocator.Error![]const [2]f64 {
    const at = samples[i].at;
    const before = unit(.{ at[0] - samples[i - 1].at[0], at[1] - samples[i - 1].at[1] });
    const after = unit(.{ samples[i + 1].at[0] - at[0], samples[i + 1].at[1] - at[1] });
    const half = @max(samples[i].width_mm, eps) / 2;
    const na = [2]f64{ -before[1] * half, before[0] * half };
    const nb = [2]f64{ -after[1] * half, after[0] * half };
    const candidates = [_][2]f64{
        .{ at[0] + na[0], at[1] + na[1] },
        .{ at[0] - na[0], at[1] - na[1] },
        .{ at[0] + nb[0], at[1] + nb[1] },
        .{ at[0] - nb[0], at[1] - nb[1] },
    };
    var ordered: [4][2]f64 = undefined;
    var count: usize = 0;
    for (candidates) |candidate| {
        var duplicate = false;
        for (ordered[0..count]) |point| {
            if (samePoint(point, candidate)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        ordered[count] = candidate;
        count += 1;
    }
    if (count < 3) return &.{};
    var j: usize = 1;
    while (j < count) : (j += 1) {
        var k = j;
        while (k > 0) {
            const before_angle = std.math.atan2(ordered[k - 1][1] - at[1], ordered[k - 1][0] - at[0]);
            const angle = std.math.atan2(ordered[k][1] - at[1], ordered[k][0] - at[0]);
            if (before_angle >= angle) break;
            std.mem.swap([2]f64, &ordered[k - 1], &ordered[k]);
            k -= 1;
        }
    }
    return arena.dupe([2]f64, ordered[0..count]);
}

fn orientCross(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn pointOnClosedSegment(point: [2]f64, a: [2]f64, b: [2]f64, tolerance: f64) bool {
    if (@abs(orientCross(a, b, point)) > tolerance) return false;
    const inside_x = point[0] >= @min(a[0], b[0]) - eps and point[0] <= @max(a[0], b[0]) + eps;
    const inside_y = point[1] >= @min(a[1], b[1]) - eps and point[1] <= @max(a[1], b[1]) + eps;
    return inside_x and inside_y;
}

fn oppositeSides(a: f64, b: f64, tolerance: f64) bool {
    return (a > tolerance and b < -tolerance) or (a < -tolerance and b > tolerance);
}

fn segmentsTouch(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) bool {
    const tolerance = eps * @max(1, @max(std.math.hypot(b[0] - a[0], b[1] - a[1]), std.math.hypot(d[0] - c[0], d[1] - c[1])));
    const abc = orientCross(a, b, c);
    const abd = orientCross(a, b, d);
    const cda = orientCross(c, d, a);
    const cdb = orientCross(c, d, b);
    if (oppositeSides(abc, abd, tolerance) and oppositeSides(cda, cdb, tolerance)) return true;
    if (@abs(abc) <= tolerance and pointOnClosedSegment(c, a, b, tolerance)) return true;
    if (@abs(abd) <= tolerance and pointOnClosedSegment(d, a, b, tolerance)) return true;
    if (@abs(cda) <= tolerance and pointOnClosedSegment(a, c, d, tolerance)) return true;
    return @abs(cdb) <= tolerance and pointOnClosedSegment(b, c, d, tolerance);
}

/// RF rings also treat a non-adjacent touch, a collinear overlap, or an
/// adjacent 180-degree retrace as a fold. The generic board-outline predicate
/// deliberately has different legacy semantics, so keep this stricter rule
/// local and mirrored by `rfRingFolded` in the browser.
fn ringFolded(poly: []const [2]f64) bool {
    if (poly.len < 3) return true;
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const ab = [2]f64{ b[0] - a[0], b[1] - a[1] };
        const ab_len = std.math.hypot(ab[0], ab[1]);
        if (ab_len <= eps) return true;
        for (i + 1..poly.len) |j| {
            const c = poly[j];
            const d = poly[(j + 1) % poly.len];
            const adjacent = (i + 1) % poly.len == j or (j + 1) % poly.len == i;
            if (adjacent) {
                const cd = [2]f64{ d[0] - c[0], d[1] - c[1] };
                const tolerance = eps * @max(1, @max(ab_len, std.math.hypot(cd[0], cd[1])));
                if (@abs(ab[0] * cd[1] - ab[1] * cd[0]) <= tolerance and ab[0] * cd[0] + ab[1] * cd[1] < -tolerance) return true;
                continue;
            }
            if (segmentsTouch(a, b, c, d)) return true;
        }
    }
    return false;
}

/// Fabrication-safe regions for a swept path. The compact mitered ring stays
/// the fast/common representation. If a near-end turn folds that ring across
/// itself, lower the same width profile to overlapping simple trapezoids and
/// convex joins. Region union preserves all legitimate copper; unlike a global
/// endpoint-plane clip it cannot cut an earlier segment that turns back across
/// the cap plane.
pub fn regions(arena: std.mem.Allocator, samples: []const Sample) std.mem.Allocator.Error![]const []const [2]f64 {
    const clean = try cleanSamples(arena, samples);
    if (clean.len < 2) return &.{};
    const ring = try outlineClean(arena, clean);
    if (!ringFolded(ring)) {
        const result = try arena.alloc([]const [2]f64, 1);
        result[0] = ring;
        return result;
    }
    var result: std.ArrayList([]const [2]f64) = .empty;
    for (clean[1..], 1..) |sample, i| {
        const before = clean[i - 1];
        if (std.math.hypot(sample.at[0] - before.at[0], sample.at[1] - before.at[1]) <= eps) continue;
        try result.append(arena, try segmentRegion(arena, before, sample));
    }
    for (1..clean.len - 1) |i| {
        const join = try joinRegion(arena, clean, i);
        if (join.len >= 3) try result.append(arena, join);
    }
    return result.toOwnedSlice(arena);
}

fn arcProgress(circle: polygon_outline.ArcCircle, point: [2]f64, reverse: bool) f64 {
    const angle = std.math.atan2(point[1] - circle.cy, point[0] - circle.cx);
    const start = if (reverse) circle.start_angle + circle.sweep else circle.start_angle;
    const ccw = if (reverse) circle.sweep < 0 else circle.sweep >= 0;
    return if (ccw)
        @mod(angle - start, std.math.tau)
    else
        @mod(start - angle, std.math.tau);
}

fn sampleSpanFollowsArc(samples: []const Sample, start: usize, finish: usize, circle: polygon_outline.ArcCircle, reverse: bool) bool {
    if (finish <= start + 1) return false;
    const distance_tolerance = 1e-4;
    const angle_tolerance = distance_tolerance / @max(circle.radius, distance_tolerance);
    const total = @abs(circle.sweep);
    var previous: f64 = 0;
    var saw_interior = false;
    for (samples[start .. finish + 1]) |sample| {
        const radius = std.math.hypot(sample.at[0] - circle.cx, sample.at[1] - circle.cy);
        if (@abs(radius - circle.radius) > distance_tolerance) return false;
        const progress = arcProgress(circle, sample.at, reverse);
        if (progress + angle_tolerance < previous or progress > total + angle_tolerance) return false;
        if (progress > angle_tolerance and progress + angle_tolerance < total) saw_interior = true;
        previous = progress;
    }
    return saw_interior and @abs(previous - total) <= angle_tolerance;
}

fn ownsArc(paths: []const rf_port_report.Outcome, arc: router.Arc) bool {
    const circle = polygon_outline.arcCircle(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }) orelse return false;
    for (paths) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        if (path.net != arc.net or path.physical.layer != arc.layer) continue;
        const samples = path.physical.samples;
        for (samples, 0..) |sample, i| {
            const reverse = if (samePoint(sample.at, arc.p1))
                false
            else if (samePoint(sample.at, arc.p2))
                true
            else
                continue;
            const finish_at = if (reverse) arc.p1 else arc.p2;
            for (samples[i + 1 ..], i + 1..) |candidate, j| {
                if (!samePoint(candidate.at, finish_at)) continue;
                if (sampleSpanFollowsArc(samples, i, j, circle, reverse)) return true;
            }
        }
    }
    return false;
}

/// Remove native arcs whose complete curved span is already represented by an
/// RF sampled path. A real on-circle interior sample is required, so a
/// two-point straight collar can never suppress an unrelated arc that merely
/// shares its endpoints.
pub fn filterArcs(arena: std.mem.Allocator, paths: []const rf_port_report.Outcome, source: []const router.Arc) std.mem.Allocator.Error![]const router.Arc {
    if (paths.len == 0 or source.len == 0) return source;
    var out: std.ArrayList(router.Arc) = .empty;
    for (source) |arc| if (!ownsArc(paths, arc)) try out.append(arena, arc);
    return out.toOwnedSlice(arena);
}

/// Whether `track` is an editor handle or implementation chord belonging to a
/// swept path, without hiding unrelated branches on the same net and layer.
///
/// Net, layer, and coordinates are necessary but not sufficient: a stale or
/// orphaned path still holds the coordinates of the run it used to describe, so
/// `variable_width_copper.ownsTrack` also requires the path's own copper over
/// the covered span to be at least as wide as the track. A wider rail lying
/// along a narrow probe path therefore survives at full width instead of being
/// deleted and re-emitted as that probe's chords.
///
/// The converse — a track NARROWER than the samples it lies on — is not
/// separable here: a compact constant-width handle under a taper has exactly
/// that shape, and only the stored `SavedRfPath.track_ids` could tell it from a
/// neighbour a drag moved onto the same coordinates. Those ids are dropped when
/// a saved layout is rebuilt into a `router.RouteResult`, which carries no
/// per-track identity at all.
pub fn ownsTrack(paths: []const rf_port_report.Outcome, track: anytype) bool {
    for (paths) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        if (path.net != track.net or path.physical.layer != track.layer) continue;
        const samples = path.physical.samples;
        if (samples.len < 2) continue;
        if (variable_width_copper.ownsTrack(samples, track)) return true;
    }
    return false;
}

/// Return capsule probes matching the swept path, without exposing them as
/// persisted or editor-visible trace objects. Ordinary persisted copper is
/// always the prefix and the private path probes follow it.
pub fn tracks(arena: std.mem.Allocator, routed: router.RouteResult) std.mem.Allocator.Error![]const router.Track {
    if (routed.rf_port_outcomes.len == 0) return routed.tracks;
    var out: std.ArrayList(router.Track) = .empty;
    for (routed.tracks) |track| {
        if (!ownsTrack(routed.rf_port_outcomes, track)) try out.append(arena, track);
    }
    for (routed.rf_port_outcomes) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        const samples = try cleanSamples(arena, path.physical.samples);
        if (samples.len < 2) continue;
        for (samples[1..], 1..) |sample, i| {
            const before = samples[i - 1];
            if (std.math.hypot(sample.at[0] - before.at[0], sample.at[1] - before.at[1]) <= 1e-9) continue;
            try out.append(arena, .{
                .x1 = before.at[0],
                .y1 = before.at[1],
                .x2 = sample.at[0],
                .y2 = sample.at[1],
                .layer = path.physical.layer,
                .width = @max(before.width_mm, sample.width_mm),
                .net = path.net,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

// spec: placement/rf-port-frame-routing - a trace taper remains one logical swept path with compact edit handles while DRC lowers conservative private width-profile chords and folded offset rings lower to overlapping simple fabrication regions
test "path copper replaces only its compact centreline handle with private profile chords" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.5, .y1 = 0, .x2 = 0.5, .y2 = 1, .layer = 0, .width = 0.3, .net = 0 },
    };
    const samples = [_]@import("rf_path_solver.zig").Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 0.5, 0 }, .s_mm = 0.5, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.3 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const got = try tracks(arena, .{ .tracks = &source, .vias = &.{}, .rf_port_outcomes = &paths, .routed = 1, .total = 1 });
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), got[1].width, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), got[2].width, 1e-12);
    try std.testing.expectEqual(@as(f64, 1), got[0].y2); // unrelated branch survives
}

// spec: placement/rf-port-frame-routing - an orphaned or stale swept path never narrows a wider stored trace that shares its coordinates, and still deduplicates the chords it does describe
test "a narrow orphaned path cannot swallow the wider rail lying along it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The two-sample debris an exact-gate width probe leaves behind on a power
    // net: real coordinates, but the probe's own narrow width.
    const samples = [_]Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1524 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.1524 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 3,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    // Same net, same layer, same endpoints — only the width says this rail is
    // not the probe's copper, and swallowing it would narrow it by 40%.
    const rail = router.Track{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2532, .net = 3 };
    try std.testing.expect(!ownsTrack(&paths, rail));
    const kept = try tracks(arena, .{ .tracks = &.{rail}, .vias = &.{}, .rf_port_outcomes = &paths, .routed = 1, .total = 1 });
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2532), kept[0].width, 1e-12); // the rail survives at full width
    try std.testing.expectApproxEqAbs(@as(f64, 0.1524), kept[1].width, 1e-12); // the path still lowers its own chord

    // A handle the path does cover is still deduped, so a live path never
    // doubles its own copper.
    const handle = router.Track{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.1524, .net = 3 };
    try std.testing.expect(ownsTrack(&paths, handle));
    const deduped = try tracks(arena, .{ .tracks = &.{handle}, .vias = &.{}, .rf_port_outcomes = &paths, .routed = 1, .total = 1 });
    try std.testing.expectEqual(@as(usize, 1), deduped.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1524), deduped[0].width, 1e-12);
}

test "variable width outline bevels a sharp angled taper without an inward gap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const samples = [_]Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 0.2, 0.1 }, .s_mm = 1.81, .curvature = 0, .width_mm = 0.3 },
    };
    const polygon = try outline(arena_state.allocator(), &samples);
    // A near reversal exceeds the 2x miter limit, so each side contributes
    // both true offset-edge points instead of one clamped, detached point.
    try std.testing.expectEqual(@as(usize, 8), polygon.len);
    for (polygon) |point| {
        try std.testing.expect(std.math.isFinite(point[0]));
        try std.testing.expect(std.math.isFinite(point[1]));
    }
}

test "wide taper that bends inside a pad lowers to simple overlapping regions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const samples = [_]Sample{
        .{ .at = .{ 149.70000000000002, 104.98 }, .s_mm = 0, .curvature = 0, .width_mm = 0.62 },
        .{ .at = .{ 149.70000000000002, 105 }, .s_mm = 0.02, .curvature = 0, .width_mm = 0.62 },
        .{ .at = .{ 149.66193976625587, 105.19134171618309 }, .s_mm = 0.215, .curvature = 0, .width_mm = 0.62 },
        .{ .at = .{ 149.63390958983942, 105.24844006892205 }, .s_mm = 0.279, .curvature = 0, .width_mm = 0.62 },
        .{ .at = .{ 149.6145384401762, 105.27956731142432 }, .s_mm = 0.316, .curvature = 0, .width_mm = 0.5472256867548122 },
        .{ .at = .{ 149.59293848866537, 105.30919143604933 }, .s_mm = 0.353, .curvature = 0, .width_mm = 0.4744513735096243 },
        .{ .at = .{ 149.56922586931807, 105.33715316612384 }, .s_mm = 0.389, .curvature = 0, .width_mm = 0.4016770602644365 },
        .{ .at = .{ 149.55355339059363, 105.3535533905945 }, .s_mm = 0.412, .curvature = 0, .width_mm = 0.3566548264334851 },
        .{ .at = .{ 149.5435280750872, 105.36330216298292 }, .s_mm = 0.426, .curvature = 0, .width_mm = 0.32890274701924865 },
        .{ .at = .{ 149.51598327239037, 105.38749783427886 }, .s_mm = 0.463, .curvature = 0, .width_mm = 0.25612843377406086 },
        .{ .at = .{ 149.48673955824634, 105.40961008988818 }, .s_mm = 0.499, .curvature = 0, .width_mm = 0.18335412052887323 },
        .{ .at = .{ 149.39134171618286, 105.4619397662577 }, .s_mm = 0.608, .curvature = 0, .width_mm = 0.18335412052887323 },
        .{ .at = .{ 149.20000000000002, 105.500000000003 }, .s_mm = 0.803, .curvature = 0, .width_mm = 0.18335412052887323 },
    };
    const lowered = try regions(arena_state.allocator(), &samples);
    for (lowered) |polygon| try std.testing.expect(!polygon_outline.selfIntersects(polygon));
}

test "short terminal pad jog keeps earlier copper while avoiding a folded region" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const samples = [_]Sample{
        .{ .at = .{ 143.96, 105.45 }, .s_mm = 0, .curvature = 0, .width_mm = 0.56 },
        .{ .at = .{ 144.22, 105.45 }, .s_mm = 0.26, .curvature = 0, .width_mm = 0.56 },
        .{ .at = .{ 144.22, 105.5 }, .s_mm = 0.31, .curvature = 0, .width_mm = 0.56 },
    };
    const folded = try outline(arena_state.allocator(), &samples);
    try std.testing.expect(polygon_outline.selfIntersects(folded));
    const lowered = try regions(arena_state.allocator(), &samples);
    try std.testing.expect(lowered.len > 1);
    var keeps_earlier_sweep = false;
    for (lowered) |polygon| {
        try std.testing.expect(!polygon_outline.selfIntersects(polygon));
        keeps_earlier_sweep = keeps_earlier_sweep or polygon_outline.contains(polygon, 144.0, 105.55);
    }
    try std.testing.expect(keeps_earlier_sweep);

    const retraced = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    try std.testing.expect(ringFolded(&retraced));
}

test "coincident RF samples normalize before regions and conservative track lowering" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const noisy = [_]Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.4 },
        .{ .at = .{ 0, 1 }, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 0, 1 }, .s_mm = 1, .curvature = 0, .width_mm = 0.3 },
    };
    const clean = [_]Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.4 },
        .{ .at = .{ 0, 1 }, .s_mm = 1, .curvature = 0, .width_mm = 0.3 },
    };
    const noisy_regions = try regions(arena, &noisy);
    const clean_regions = try regions(arena, &clean);
    try std.testing.expectEqual(@as(usize, 1), noisy_regions.len);
    try std.testing.expectEqualSlices([2]f64, clean_regions[0], noisy_regions[0]);

    const paths = [_]rf_port_report.Outcome{.{
        .net = 4,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = noisy.len, .samples = &noisy, .layer = 1 },
    }};
    const lowered = try tracks(arena, .{ .tracks = &.{}, .vias = &.{}, .rf_port_outcomes = &paths, .routed = 0, .total = 0 });
    try std.testing.expectEqual(@as(usize, 1), lowered.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), lowered[0].width, 1e-12);

    const coincident = [_]Sample{
        .{ .at = .{ 2, 2 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 2, 2 }, .s_mm = 0, .curvature = 0, .width_mm = 0.3 },
    };
    try std.testing.expectEqual(@as(usize, 0), (try regions(arena, &coincident)).len);
    var coincident_paths = paths;
    coincident_paths[0].physical.samples = &coincident;
    try std.testing.expectEqual(@as(usize, 0), (try tracks(arena, .{ .tracks = &.{}, .vias = &.{}, .rf_port_outcomes = &coincident_paths, .routed = 0, .total = 0 })).len);
}

test "sampled RF arcs replace only a complete matching native arc" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = std.math.sqrt(0.5);
    const arc = router.Arc{ .p1 = .{ 1, 0 }, .pm = .{ q, q }, .p2 = .{ 0, 1 }, .layer = 0, .width = 0.2, .net = 7 };
    const samples = [_]Sample{
        .{ .at = .{ 2, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = arc.p1, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
        .{ .at = arc.pm, .s_mm = 1.8, .curvature = 0, .width_mm = 0.2 },
        .{ .at = arc.p2, .s_mm = 2.6, .curvature = 0, .width_mm = 0.2 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 7,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    try std.testing.expectEqual(@as(usize, 0), (try filterArcs(arena, &paths, &.{arc})).len);

    const reverse_samples = [_]Sample{
        .{ .at = arc.p2, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = arc.pm, .s_mm = 0.8, .curvature = 0, .width_mm = 0.2 },
        .{ .at = arc.p1, .s_mm = 1.6, .curvature = 0, .width_mm = 0.2 },
    };
    var reverse_paths = paths;
    reverse_paths[0].physical.samples = &reverse_samples;
    try std.testing.expectEqual(@as(usize, 0), (try filterArcs(arena, &reverse_paths, &.{arc})).len);

    const two_point = [_]Sample{
        .{ .at = arc.p1, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = arc.p2, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
    };
    var collar_paths = paths;
    collar_paths[0].physical.samples = &two_point;
    try std.testing.expectEqual(@as(usize, 1), (try filterArcs(arena, &collar_paths, &.{arc})).len);

    var other_net = arc;
    other_net.net = 8;
    try std.testing.expectEqual(@as(usize, 1), (try filterArcs(arena, &paths, &.{other_net})).len);
}
