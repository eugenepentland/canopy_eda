//! Exact primitive pieces for a sampled variable-width copper centreline.
//!
//! A saved RF path keeps a compact centreline plus a width at every sample.
//! Consumers that need the fabricated outline (pours and via-fence guides)
//! must sweep those widths, rather than treating the compact edit handle as a
//! constant-width capsule.  This leaf module deliberately imports neither the
//! router nor the pour engine, so both can consume the same geometry without
//! creating an import cycle.

const std = @import("std");
const Sample = @import("rf_path_solver.zig").Sample;

const eps: f64 = 1e-9;

/// One local filled polygon and the widest section it represents.
pub const Piece = struct {
    poly: []const [2]f64,
    /// Widest copper represented by this local piece.  A pour uses it only to
    /// resolve a width-dependent CPWG gap; the polygon remains the authority
    /// for the copper edge itself.
    width_mm: f64,
};

fn samePoint(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= 1e-7 and @abs(a[1] - b[1]) <= 1e-7;
}

fn onSegment(point: [2]f64, a: [2]f64, b: [2]f64) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len <= eps) return samePoint(point, a);
    const cross = @abs((point[0] - a[0]) * dy - (point[1] - a[1]) * dx) / len;
    const dot = (point[0] - a[0]) * dx + (point[1] - a[1]) * dy;
    return cross <= 1e-7 and dot >= -1e-7 and dot <= len * len + 1e-7;
}

/// Whether a persisted/editor track is wholly represented by `samples`.
/// Intermediate samples may lie on the same straight span, so one compact
/// handle can own several local swept pieces.
pub fn ownsTrack(samples: []const Sample, track: anytype) bool {
    const a = [2]f64{ track.x1, track.y1 };
    const b = [2]f64{ track.x2, track.y2 };
    return ownsSpan(samples, a, b) or ownsSpan(samples, b, a);
}

fn ownsSpan(samples: []const Sample, a: [2]f64, b: [2]f64) bool {
    for (samples, 0..) |start, i| {
        if (!samePoint(start.at, a)) continue;
        for (samples[i + 1 ..], i + 1..) |finish, j| {
            if (!samePoint(finish.at, b)) continue;
            for (samples[i + 1 .. j]) |middle| {
                if (!onSegment(middle.at, a, b)) break;
            } else return true;
        }
    }
    return false;
}

/// Collapse consecutive coincident samples, retaining the widest copper at
/// that coordinate.  This matches the normalization used by fabrication.
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

fn unit(v: [2]f64) [2]f64 {
    const len = std.math.hypot(v[0], v[1]);
    return if (len > eps) .{ v[0] / len, v[1] / len } else .{ 1, 0 };
}

fn segmentPiece(arena: std.mem.Allocator, a: Sample, b: Sample) std.mem.Allocator.Error!Piece {
    const direction = unit(.{ b.at[0] - a.at[0], b.at[1] - a.at[1] });
    const normal = [2]f64{ -direction[1], direction[0] };
    const ah = @max(a.width_mm, eps) / 2;
    const bh = @max(b.width_mm, eps) / 2;
    const poly = try arena.alloc([2]f64, 4);
    poly[0] = .{ a.at[0] + normal[0] * ah, a.at[1] + normal[1] * ah };
    poly[1] = .{ b.at[0] + normal[0] * bh, b.at[1] + normal[1] * bh };
    poly[2] = .{ b.at[0] - normal[0] * bh, b.at[1] - normal[1] * bh };
    poly[3] = .{ a.at[0] - normal[0] * ah, a.at[1] - normal[1] * ah };
    return .{ .poly = poly, .width_mm = @max(a.width_mm, b.width_mm) };
}

fn joinPiece(arena: std.mem.Allocator, samples: []const Sample, i: usize) std.mem.Allocator.Error!?Piece {
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
        for (ordered[0..count]) |point| if (samePoint(point, candidate)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        ordered[count] = candidate;
        count += 1;
    }
    if (count < 3) return null;
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
    return .{ .poly = try arena.dupe([2]f64, ordered[0..count]), .width_mm = samples[i].width_mm };
}

/// Exact union pieces for a sampled sweep: one trapezoid per sample span and
/// a convex join at each real turn.  Consumers union the pieces in their own
/// distance field, preserving a straight taper's sloped flanks exactly.
pub fn pieces(arena: std.mem.Allocator, samples: []const Sample) std.mem.Allocator.Error![]const Piece {
    const clean = try cleanSamples(arena, samples);
    if (clean.len < 2) return &.{};
    var out: std.ArrayList(Piece) = .empty;
    for (clean[1..], 1..) |sample, i| try out.append(arena, try segmentPiece(arena, clean[i - 1], sample));
    for (1..clean.len - 1) |i| if (try joinPiece(arena, clean, i)) |join| try out.append(arena, join);
    return out.toOwnedSlice(arena);
}

test "a straight taper lowers to its exact trapezoid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const samples = [_]Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 2 },
        .{ .at = .{ 4, 0 }, .s_mm = 4, .curvature = 0, .width_mm = 0.2 },
    };
    const got = try pieces(arena_state.allocator(), &samples);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualSlices([2]f64, &.{ .{ 0, 1 }, .{ 4, 0.1 }, .{ 4, -0.1 }, .{ 0, -1 } }, got[0].poly);
}
