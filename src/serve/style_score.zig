//! Dense hand-likeness score for a **module** (subcircuit) layout vs its starred
//! reference — the graded upgrade to `layout_match`'s side-only `area_match`.
//!
//! `layout_match` credits per-interchangeable-class, per-IC-edge COUNT agreement
//! (right for fungible parts, order-independent), but it is a step function: a
//! cap on the correct edge at 8 mm scores identically to one at 0.4 mm, a module
//! laid out 90° rotated from the ★ scores near zero, and orientation is invisible
//! — exactly the axes a hand-finisher still has to fix. This module keeps the
//! per-class COUNT discipline (never per-part name pairing — that was measured to
//! be order-sensitive and worse) and adds:
//!
//!   * `S_edge`  — the existing per-class per-edge count credit (area_match).
//!   * `S_gap`   — per-class radial gap-band histogram overlap: tightness, the
//!                 `gapR→gapS` axis the whole tight-pack effort was judged on.
//!   * `S_rot`   — per-class quarter-turn histogram overlap: ORIENTATION, which
//!                 the first two terms cannot see at all. A 2-pad passive is
//!                 compared mod 180° (0° and 180° are the same footprint
//!                 orientation with its pads swapped), everything else mod 360°.
//!   * D4 symmetry — the candidate is scored under all four 90° rotations about
//!                 its anchor and the best is taken, so a correct-but-rotated
//!                 arrangement isn't a false zero (a module can be rotated whole).
//!                 The rotation term turns WITH the module, so it is measured
//!                 under the same winning `k` the edge term picks.
//!
//! Scope: modules are single-anchor flat blocks (`packPadAnchored`), so a single
//! anchor hub attributes every part — no multi-anchor bookkeeping needed here.
//! An adjacency term is a planned follow-up; the struct leaves room.

const std = @import("std");
const optimizer = @import("../placement/optimizer.zig");
const pcb_describe = @import("pcb_describe.zig");
const Side = pcb_describe.Side;

/// `Side` variant count (left, right, top, bottom, center).
pub const n_sides = @typeInfo(Side).@"enum".field_names.len;

/// Upper edges of the radial gap-to-anchor bands (mm); a part past the last edge
/// falls in the final "far" bucket. Chosen to separate the tightness regimes a
/// hand-finisher cares about: sub-mm hugging, close, mid, loose, far.
pub const gap_bands = [_]f64{ 0.5, 1.0, 2.0, 4.0, 8.0 };
pub const n_bands = gap_bands.len + 1;

/// Sub-term weights for the overall style score. Kept here (not scattered) so a
/// calibration sweep can retune them in one place, and summing to 1 so
/// `style_pct` stays a percentage. Orientation carries a deliberately modest
/// share: it is a real defect axis (a cap turned across its pad instead of into
/// it) but a smaller one than landing on the wrong edge entirely, and the
/// edge/gap split keeps the proportions the two-term score was calibrated on.
pub const w_edge: f64 = 0.5;
pub const w_gap: f64 = 0.35;
pub const w_rot: f64 = 0.15;

/// One analyzed part for the style metric: its anchor edge, its gap-band, and its
/// interchangeable-class key. Split out so the matcher is unit-testable on
/// hand-built infos without a whole `Placement`.
pub const SInfo = struct {
    side: Side,
    gap_band: usize,
    class: []const u8,
    /// Quarter-turns of the part's own rotation (0..3), before the D4 turn.
    rot_q: usize = 0,
    /// Compare this part's rotation mod 180° — true for a 2-pad passive, whose
    /// 0° and 180° poses are the same footprint with its pads swapped.
    half: bool = false,
};

/// Per-sub-term percentages (0–100) plus the weighted overall, and which of the
/// four D4 rotations of the candidate won (0 = as-placed).
pub const StyleResult = struct {
    n: usize,
    edge_pct: f64,
    gap_pct: f64,
    rot_pct: f64,
    style_pct: f64,
    rot_k: usize,
};

/// Build a part's interchangeable-class key: kind + value + footprint half-size
/// (0.1 mm buckets) + the sorted set of nets it touches. Two parts with the same
/// key serve the same role and are fungible when matching positions. (Canonical
/// home — `layout_match` imports this.)
pub fn classKey(alloc: std.mem.Allocator, p: optimizer.Placement, idx: usize) std.mem.Allocator.Error![]const u8 {
    const part = p.parts[idx];
    var nets: std.ArrayList([]const u8) = .empty;
    defer nets.deinit(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, part.ref_des)) {
                try nets.append(alloc, net.name);
                break;
            }
        }
    }
    std.mem.sort([]const u8, nets.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (nets.items) |n| {
        try joined.appendSlice(alloc, n);
        try joined.append(alloc, ',');
    }
    return std.fmt.allocPrint(alloc, "{s}|{s}|{d:.1}x{d:.1}|{s}", .{ @tagName(part.kind), part.value, part.hw, part.hh, joined.items });
}

/// Courtyard-AABB clearance between two parts in mm (0 = touching/overlapping).
/// Mirrors `pcb_describe.rectGap` (private there); rotation-aware via `aabbHalf`.
fn aabbGap(a: optimizer.Part, b: optimizer.Part) f64 {
    const ah = pcb_describe.aabbHalf(a);
    const bh = pcb_describe.aabbHalf(b);
    const gx = @max(0.0, @abs(b.x - a.x) - (ah[0] + bh[0]));
    const gy = @max(0.0, @abs(b.y - a.y) - (ah[1] + bh[1]));
    return std.math.hypot(gx, gy);
}

/// Bucket a gap (mm) into `0..N_BANDS-1` by `GAP_BANDS`.
pub fn gapBand(gap_mm: f64) usize {
    for (gap_bands, 0..) |edge, i| {
        if (gap_mm < edge) return i;
    }
    return n_bands - 1;
}

/// Quarter-turn index (0..3) of a rotation in degrees. A hand angle that is not
/// a multiple of 90° rounds to the nearest quarter — the placer only ever emits
/// quarters, and a stray 45° part is still better described by its nearest one
/// than dropped.
pub fn rotQuarter(deg: f64) usize {
    const t = @mod(deg, 360.0) / 90.0;
    if (t < 0.5 or t >= 3.5) return 0;
    if (t < 1.5) return 1;
    if (t < 2.5) return 2;
    return 3;
}

/// The rotation bucket a part falls in after the whole module turns `k`
/// quarter-turns: 0..3 normally, 0..1 for a part compared mod 180°.
pub fn rotBucket(info: SInfo, k: usize) usize {
    const q = (info.rot_q + k) % 4;
    return if (info.half) q % 2 else q;
}

/// Rotate a `Side` by `k` clockwise quarter-turns (top→right→bottom→left).
/// `center` is rotation-invariant. Trying `k = 0..3` covers all four whole-module
/// rotations, so chirality of a single quarter-turn is irrelevant.
pub fn rotSide(side: Side, k: usize) Side {
    const cycle = [_]Side{ .top, .right, .bottom, .left };
    const pos: ?usize = switch (side) {
        .top => 0,
        .right => 1,
        .bottom => 2,
        .left => 3,
        .center => null,
    };
    const p = pos orelse return .center;
    return cycle[(p + k) % 4];
}

/// Analyze every non-anchor part into an `SInfo` (edge + gap-band + class),
/// skipping refs in `excluded` (parts the starred reference doesn't cover — they
/// would charge the candidate for reference staleness). Empty when no anchor hub.
pub fn analyzeStyle(alloc: std.mem.Allocator, p: optimizer.Placement, excluded: ?*const std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error![]SInfo {
    const ai = pcb_describe.anchorIndex(p.parts, p.nets) orelse return &.{};
    const anchor = p.parts[ai];
    const a_half = pcb_describe.aabbHalf(anchor);
    var out: std.ArrayList(SInfo) = .empty;
    for (p.parts, 0..) |part, i| {
        if (i == ai) continue;
        if (excluded) |ex| {
            if (ex.contains(part.ref_des)) continue;
        }
        const side = pcb_describe.sideOf(part.x - anchor.x, part.y - anchor.y, a_half, pcb_describe.aabbHalf(part));
        try out.append(alloc, .{
            .side = side,
            .gap_band = gapBand(aabbGap(anchor, part)),
            .class = try classKey(alloc, p, i),
            .rot_q = rotQuarter(part.rot),
            .half = part.kind != .hub and part.pads.len == 2,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Per-class graded tallies. Both placements are the SAME design, so per class the
/// rough and starred totals are equal — we credit `min(count)` per edge and per
/// gap-band (order-independent histogram overlap).
const SClass = struct {
    edge_r: [n_sides]usize = @splat(0),
    edge_s: [n_sides]usize = @splat(0),
    gap_r: [n_bands]usize = @splat(0),
    gap_s: [n_bands]usize = @splat(0),
    rot_r: [4]usize = @splat(0),
    rot_s: [4]usize = @splat(0),
    n: usize = 0,
};

/// Score a candidate (`rough`) against a `starred` reference on the dense style
/// terms, taking the best of the four whole-module rotations. Both are analyzed
/// `SInfo` slices (from `analyzeStyle`). Gap-band overlap is rotation-invariant;
/// only the edge term varies with `k`, so the winning `k` is the one maximizing
/// the weighted total.
pub fn styleScore(alloc: std.mem.Allocator, rough: []const SInfo, starred: []const SInfo) std.mem.Allocator.Error!StyleResult {
    var map = std.StringHashMapUnmanaged(SClass).empty;
    defer map.deinit(alloc);
    for (starred) |s| {
        const gop = try map.getOrPut(alloc, s.class);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.edge_s[@backingInt(s.side)] += 1;
        gop.value_ptr.gap_s[s.gap_band] += 1;
        gop.value_ptr.rot_s[rotBucket(s, 0)] += 1;
        gop.value_ptr.n += 1;
    }

    // Gap term is rotation-invariant — tally once. Edge AND rotation both turn
    // with the module, so the winning `k` is the one maximizing their weighted
    // sum; k = 0 keeps a tie, so an unrotated match never reports a turn.
    var total: usize = 0;
    var gap_credit: usize = 0;
    var best_k: usize = 0;
    var best_edge: usize = 0;
    var best_rot: usize = 0;
    var best_score = -std.math.inf(f64);

    for (0..4) |k| {
        const t = try turnCredit(alloc, &map, rough, k);
        if (k == 0) total = t.total;
        const score = w_edge * @as(f64, @floatFromInt(t.edge)) + w_rot * @as(f64, @floatFromInt(t.rot));
        if (score > best_score) {
            best_score = score;
            best_edge = t.edge;
            best_rot = t.rot;
            best_k = k;
        }
    }

    // Gap credit (once): tally rough gap-bands then credit min per band per class.
    {
        var it = map.iterator();
        while (it.next()) |e| e.value_ptr.gap_r = @splat(0);
        for (rough) |r| {
            const gop = try map.getOrPut(alloc, r.class);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.gap_r[r.gap_band] += 1;
        }
        var it2 = map.iterator();
        while (it2.next()) |e| {
            const cd = e.value_ptr;
            for (0..n_bands) |j| gap_credit += @min(cd.gap_r[j], cd.gap_s[j]);
        }
    }

    const denom = if (total > 0) @as(f64, @floatFromInt(total)) else 1.0;
    const edge_pct = 100.0 * @as(f64, @floatFromInt(best_edge)) / denom;
    const gap_pct = 100.0 * @as(f64, @floatFromInt(gap_credit)) / denom;
    const rot_pct = 100.0 * @as(f64, @floatFromInt(best_rot)) / denom;
    return .{
        .n = total,
        .edge_pct = edge_pct,
        .gap_pct = gap_pct,
        .rot_pct = rot_pct,
        .style_pct = w_edge * edge_pct + w_gap * gap_pct + w_rot * rot_pct,
        .rot_k = best_k,
    };
}

/// Per-class edge + rotation credit for the candidate turned `k` quarter-turns,
/// plus the candidate's part total. Both tallies are rebuilt from scratch each
/// turn, so the caller can try all four without carrying state between them.
const TurnCredit = struct { edge: usize, rot: usize, total: usize };

fn turnCredit(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(SClass),
    rough: []const SInfo,
    k: usize,
) std.mem.Allocator.Error!TurnCredit {
    var it = map.iterator();
    while (it.next()) |e| {
        e.value_ptr.edge_r = @splat(0);
        e.value_ptr.rot_r = @splat(0);
    }
    for (rough) |r| {
        const gop = try map.getOrPut(alloc, r.class);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.edge_r[@backingInt(rotSide(r.side, k))] += 1;
        gop.value_ptr.rot_r[rotBucket(r, k)] += 1;
    }
    var out = TurnCredit{ .edge = 0, .rot = 0, .total = 0 };
    var it2 = map.iterator();
    while (it2.next()) |e| {
        const cd = e.value_ptr;
        for (0..n_sides) |j| out.edge += @min(cd.edge_r[j], cd.edge_s[j]);
        for (0..4) |j| out.rot += @min(cd.rot_r[j], cd.rot_s[j]);
        for (cd.edge_r) |c| out.total += c;
    }
    return out;
}

/// Style-penalty weight for the hybrid score. λ=0 ⇒ pure physics; larger ⇒ style
/// dominates. Pinned by the starred-must-win sweep over the 22 hand-approved
/// module layouts (2026-07-03): the hand layout beats its rough seed on 20/22 at
/// λ=0 (the hand layouts are usually physically better too, not just more
/// hand-like) and 21/22 from λ≈0.5 up. 1.5 sits in that plateau and gives the
/// style term real selection weight for generation. The lone holdout,
/// `adp7118-ldo` (rough obj_rel 0.56 but 80% style → needs λ≈3.9), is a
/// reward-misfit to investigate, not a reason to crank λ. See `hybridScore`.
pub const lambda_default: f64 = 1.5;

/// The hybrid verdict for one candidate: physics relative to the reference, the
/// dense style match, and their scale-free product. **Lower `hybrid` = better**,
/// and the reference layout scored against itself is exactly 1.0 (obj_rel=1,
/// style=100), so a candidate beats the hand layout only by being both physically
/// better AND stylistically indistinguishable — the property the calibration
/// leans on.
pub const HybridScore = struct {
    obj_rel: f64,
    style_pct: f64,
    hybrid: f64,
};

/// Compose the physics objective (lower = better) with the dense style match into
/// a single scale-free rank key: `obj_rel · (1 + λ·(1 − style))`. `cand_obj` and
/// `ref_obj` are surrogate objectives (`Breakdown.objective`); `ref_obj` is the
/// reference (★) layout's own objective, so `obj_rel` is unitless and comparable
/// across designs. Pure — no I/O — so it is trivially unit-testable and callable
/// from a bench sweep at any λ.
pub fn hybridScore(cand_obj: f64, ref_obj: f64, style_pct: f64, lambda: f64) HybridScore {
    const obj_rel = if (ref_obj > 0) cand_obj / ref_obj else 1.0;
    const penalty = 1.0 + lambda * (1.0 - style_pct / 100.0);
    return .{ .obj_rel = obj_rel, .style_pct = style_pct, .hybrid = obj_rel * penalty };
}

/// Convenience: analyze both placements then score. `rough` is the candidate,
/// `starred` the blessed reference; `excluded` names refs the reference doesn't
/// cover (dropped from BOTH so staleness isn't scored).
pub fn compareStyle(
    alloc: std.mem.Allocator,
    rough: optimizer.Placement,
    starred: optimizer.Placement,
    excluded: ?*const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!StyleResult {
    return styleScore(alloc, try analyzeStyle(alloc, rough, excluded), try analyzeStyle(alloc, starred, excluded));
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - style score credits interchangeable parts by per-edge count and rewards matching tightness
test "styleScore credits edge + gap overlap" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // Two class-C caps: starred one left(band0) one right(band1); rough same set
    // (fungible names). Edges + gap-bands agree exactly → 100% on both terms.
    const rough = [_]SInfo{ .{ .side = .right, .gap_band = 1, .class = "C" }, .{ .side = .left, .gap_band = 0, .class = "C" } };
    const starred = [_]SInfo{ .{ .side = .left, .gap_band = 0, .class = "C" }, .{ .side = .right, .gap_band = 1, .class = "C" } };
    const res = try styleScore(arena, &rough, &starred);
    try std.testing.expectEqual(@as(usize, 2), res.n);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.edge_pct, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.gap_pct, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.style_pct, 1e-9);
}

// spec: Web Server - style score gap term penalizes correct-edge but wrong-tightness placement
test "styleScore gap term sees tightness the edge term misses" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // Same edges (both left), but rough puts both caps in the FAR band while the
    // hand hugged them tight. Edge term = 100%, gap term = 0% → style < edge.
    const rough = [_]SInfo{ .{ .side = .left, .gap_band = 5, .class = "C" }, .{ .side = .left, .gap_band = 5, .class = "C" } };
    const starred = [_]SInfo{ .{ .side = .left, .gap_band = 0, .class = "C" }, .{ .side = .left, .gap_band = 0, .class = "C" } };
    const res = try styleScore(arena, &rough, &starred);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.edge_pct, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), res.gap_pct, 1e-9);
    try std.testing.expect(res.style_pct < res.edge_pct);
}

// spec: Web Server - style score is invariant to a whole-module 90-degree rotation
test "styleScore D4 rewards a rotated-but-identical arrangement" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // Starred: A on top, B on right. Rough: the same arrangement rotated 90° CW —
    // A on right, B on bottom. Naive edge match = 0; D4 max recovers 100%. To undo
    // a 90° CW rotation the candidate is turned 3 more CW quarter-turns → rot_k=3.
    const starred = [_]SInfo{ .{ .side = .top, .gap_band = 0, .class = "A" }, .{ .side = .right, .gap_band = 0, .class = "B" } };
    const rough = [_]SInfo{ .{ .side = .right, .gap_band = 0, .class = "A" }, .{ .side = .bottom, .gap_band = 0, .class = "B" } };
    const res = try styleScore(arena, &rough, &starred);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.edge_pct, 1e-9);
    try std.testing.expectEqual(@as(usize, 3), res.rot_k);
}

// spec: Web Server - style score credits matching part orientation, comparing a 2-pad passive mod 180 degrees
test "styleScore rotation term sees orientation the edge and gap terms miss" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // Same edge, same tightness for both parts: only the turn differs. The cap
    // is 180° off, which for a 2-pad passive is the SAME footprint orientation
    // with its pads swapped, so it still credits; the resistor is a real
    // quarter-turn out and does not.
    const starred = [_]SInfo{
        .{ .side = .left, .gap_band = 0, .class = "C", .rot_q = 0, .half = true },
        .{ .side = .left, .gap_band = 0, .class = "R", .rot_q = 0, .half = true },
    };
    const rough = [_]SInfo{
        .{ .side = .left, .gap_band = 0, .class = "C", .rot_q = 2, .half = true },
        .{ .side = .left, .gap_band = 0, .class = "R", .rot_q = 1, .half = true },
    };
    const res = try styleScore(arena, &rough, &starred);
    try std.testing.expectEqual(@as(usize, 0), res.rot_k);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.edge_pct, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.gap_pct, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), res.rot_pct, 1e-9);
    // The turn is the only thing costing anything, so style sits below both
    // terms that cannot see it.
    try std.testing.expectApproxEqAbs(w_edge * 100 + w_gap * 100 + w_rot * 50, res.style_pct, 1e-9);
    try std.testing.expect(res.style_pct < res.edge_pct);
}

// spec: Web Server - style score rounds a part rotation to its nearest quarter turn
test "rotQuarter buckets degrees, wrapping and rounding" {
    try std.testing.expectEqual(@as(usize, 0), rotQuarter(0));
    try std.testing.expectEqual(@as(usize, 1), rotQuarter(90));
    try std.testing.expectEqual(@as(usize, 3), rotQuarter(-90));
    try std.testing.expectEqual(@as(usize, 0), rotQuarter(360));
    try std.testing.expectEqual(@as(usize, 2), rotQuarter(175)); // nearest quarter
    // A 2-pad passive is compared mod 180: 0° and 180° share a bucket.
    const c = SInfo{ .side = .left, .gap_band = 0, .class = "C", .rot_q = 2, .half = true };
    try std.testing.expectEqual(rotBucket(.{ .side = .left, .gap_band = 0, .class = "C" }, 0), rotBucket(c, 0));
}

test "gapBand buckets by GAP_BANDS edges" {
    try std.testing.expectEqual(@as(usize, 0), gapBand(0.2));
    try std.testing.expectEqual(@as(usize, 1), gapBand(0.7));
    try std.testing.expectEqual(@as(usize, n_bands - 1), gapBand(20.0));
}

// spec: Web Server - hybrid score ranks the reference layout at exactly 1.0 and penalizes stylistic deviation
test "hybridScore: reference wins, style penalty raises off-style physics winners" {
    // The reference scored against itself: obj_rel=1, style=100 → hybrid=1.0.
    const ref = hybridScore(100, 100, 100, 1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), ref.hybrid, 1e-9);
    // A candidate 20% physically better (obj 80) but only 50% on style: at λ=1.5
    // the style penalty (1 + 1.5·0.5 = 1.75) outweighs the 0.8 physics edge →
    // hybrid 1.4 > 1.0, so the off-style winner loses to the hand layout.
    const off = hybridScore(80, 100, 50, 1.5);
    try std.testing.expect(off.hybrid > ref.hybrid);
    // λ=0 collapses to pure physics: the 20%-better candidate wins.
    const phys = hybridScore(80, 100, 50, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), phys.hybrid, 1e-9);
}
