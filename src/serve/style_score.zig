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
//!   * D4 symmetry — the candidate is scored under all four 90° rotations about
//!                 its anchor and the best is taken, so a correct-but-rotated
//!                 arrangement isn't a false zero (a module can be rotated whole).
//!
//! Scope: modules are single-anchor flat blocks (`packPadAnchored`), so a single
//! anchor hub attributes every part — no multi-anchor bookkeeping needed here.
//! Orientation/adjacency terms are a planned follow-up; the struct leaves room.

const std = @import("std");
const optimizer = @import("../placement/optimizer.zig");
const pcb_describe = @import("pcb_describe.zig");
const Side = pcb_describe.Side;

/// `Side` variant count (left, right, top, bottom, center).
pub const N_SIDES = @typeInfo(Side).@"enum".fields.len;

/// Upper edges of the radial gap-to-anchor bands (mm); a part past the last edge
/// falls in the final "far" bucket. Chosen to separate the tightness regimes a
/// hand-finisher cares about: sub-mm hugging, close, mid, loose, far.
pub const GAP_BANDS = [_]f64{ 0.5, 1.0, 2.0, 4.0, 8.0 };
pub const N_BANDS = GAP_BANDS.len + 1;

/// Sub-term weights for the overall style score. Kept here (not scattered) so a
/// calibration sweep can retune them in one place. Renormalized from the plan's
/// full-term weights to the two terms shipped in this increment.
pub const W_EDGE: f64 = 0.6;
pub const W_GAP: f64 = 0.4;

/// One analyzed part for the style metric: its anchor edge, its gap-band, and its
/// interchangeable-class key. Split out so the matcher is unit-testable on
/// hand-built infos without a whole `Placement`.
pub const SInfo = struct {
    side: Side,
    gap_band: usize,
    class: []const u8,
};

/// Per-sub-term percentages (0–100) plus the weighted overall, and which of the
/// four D4 rotations of the candidate won (0 = as-placed).
pub const StyleResult = struct {
    n: usize,
    edge_pct: f64,
    gap_pct: f64,
    style_pct: f64,
    rot_k: usize,
};

/// Build a part's interchangeable-class key: kind + value + footprint half-size
/// (0.1 mm buckets) + the sorted set of nets it touches. Two parts with the same
/// key serve the same role and are fungible when matching positions. (Canonical
/// home — `layout_match` imports this.)
pub fn classKey(alloc: std.mem.Allocator, p: optimizer.Placement, idx: usize) std.mem.Allocator.Error![]const u8 {
    const part = p.parts[idx];
    var nets: std.ArrayListUnmanaged([]const u8) = .empty;
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
    var joined: std.ArrayListUnmanaged(u8) = .empty;
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
    for (GAP_BANDS, 0..) |edge, i| {
        if (gap_mm < edge) return i;
    }
    return N_BANDS - 1;
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
pub fn analyzeStyle(alloc: std.mem.Allocator, p: optimizer.Placement, excluded: ?*const std.StringHashMap(void)) std.mem.Allocator.Error![]SInfo {
    const ai = pcb_describe.anchorIndex(p.parts, p.nets) orelse return &.{};
    const anchor = p.parts[ai];
    const a_half = pcb_describe.aabbHalf(anchor);
    var out: std.ArrayListUnmanaged(SInfo) = .empty;
    for (p.parts, 0..) |part, i| {
        if (i == ai) continue;
        if (excluded) |ex| {
            if (ex.contains(part.ref_des)) continue;
        }
        const side = pcb_describe.sideOf(part.x - anchor.x, part.y - anchor.y, a_half, pcb_describe.aabbHalf(part));
        try out.append(alloc, .{ .side = side, .gap_band = gapBand(aabbGap(anchor, part)), .class = try classKey(alloc, p, i) });
    }
    return out.toOwnedSlice(alloc);
}

/// Per-class graded tallies. Both placements are the SAME design, so per class the
/// rough and starred totals are equal — we credit `min(count)` per edge and per
/// gap-band (order-independent histogram overlap).
const SClass = struct {
    edge_r: [N_SIDES]usize = [_]usize{0} ** N_SIDES,
    edge_s: [N_SIDES]usize = [_]usize{0} ** N_SIDES,
    gap_r: [N_BANDS]usize = [_]usize{0} ** N_BANDS,
    gap_s: [N_BANDS]usize = [_]usize{0} ** N_BANDS,
    n: usize = 0,
};

/// Score a candidate (`rough`) against a `starred` reference on the dense style
/// terms, taking the best of the four whole-module rotations. Both are analyzed
/// `SInfo` slices (from `analyzeStyle`). Gap-band overlap is rotation-invariant;
/// only the edge term varies with `k`, so the winning `k` is the one maximizing
/// the weighted total.
pub fn styleScore(alloc: std.mem.Allocator, rough: []const SInfo, starred: []const SInfo) std.mem.Allocator.Error!StyleResult {
    var map = std.StringHashMap(SClass).init(alloc);
    defer map.deinit();
    for (starred) |s| {
        const gop = try map.getOrPut(s.class);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.edge_s[@intFromEnum(s.side)] += 1;
        gop.value_ptr.gap_s[s.gap_band] += 1;
        gop.value_ptr.n += 1;
    }

    // Gap term is rotation-invariant — tally once.
    var total: usize = 0;
    var gap_credit: usize = 0;
    var best_k: usize = 0;
    var best_edge: usize = 0;

    for (0..4) |k| {
        // Re-tally the rough edges under rotation k.
        var it = map.iterator();
        while (it.next()) |e| e.value_ptr.edge_r = [_]usize{0} ** N_SIDES;
        for (rough) |r| {
            const gop = try map.getOrPut(r.class);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.edge_r[@intFromEnum(rotSide(r.side, k))] += 1;
        }

        var edge_credit: usize = 0;
        var tot: usize = 0;
        var it2 = map.iterator();
        while (it2.next()) |e| {
            const cd = e.value_ptr;
            for (0..N_SIDES) |j| edge_credit += @min(cd.edge_r[j], cd.edge_s[j]);
            for (cd.edge_r) |c| tot += c;
        }
        if (k == 0) total = tot;
        if (edge_credit > best_edge) {
            best_edge = edge_credit;
            best_k = k;
        }
    }

    // Gap credit (once): tally rough gap-bands then credit min per band per class.
    {
        var it = map.iterator();
        while (it.next()) |e| e.value_ptr.gap_r = [_]usize{0} ** N_BANDS;
        for (rough) |r| {
            const gop = try map.getOrPut(r.class);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.gap_r[r.gap_band] += 1;
        }
        var it2 = map.iterator();
        while (it2.next()) |e| {
            const cd = e.value_ptr;
            for (0..N_BANDS) |j| gap_credit += @min(cd.gap_r[j], cd.gap_s[j]);
        }
    }

    const denom = if (total > 0) @as(f64, @floatFromInt(total)) else 1.0;
    const edge_pct = 100.0 * @as(f64, @floatFromInt(best_edge)) / denom;
    const gap_pct = 100.0 * @as(f64, @floatFromInt(gap_credit)) / denom;
    return .{
        .n = total,
        .edge_pct = edge_pct,
        .gap_pct = gap_pct,
        .style_pct = W_EDGE * edge_pct + W_GAP * gap_pct,
        .rot_k = best_k,
    };
}

/// Style-penalty weight for the hybrid score. λ=0 ⇒ pure physics; larger ⇒ style
/// dominates. Pinned by the starred-must-win sweep over the 22 hand-approved
/// module layouts (2026-07-03): the hand layout beats its rough seed on 20/22 at
/// λ=0 (the hand layouts are usually physically better too, not just more
/// hand-like) and 21/22 from λ≈0.5 up. 1.5 sits in that plateau and gives the
/// style term real selection weight for generation. The lone holdout,
/// `adp7118-ldo` (rough obj_rel 0.56 but 80% style → needs λ≈3.9), is a
/// reward-misfit to investigate, not a reason to crank λ. See `hybridScore`.
pub const LAMBDA_DEFAULT: f64 = 1.5;

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
    excluded: ?*const std.StringHashMap(void),
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

test "gapBand buckets by GAP_BANDS edges" {
    try std.testing.expectEqual(@as(usize, 0), gapBand(0.2));
    try std.testing.expectEqual(@as(usize, 1), gapBand(0.7));
    try std.testing.expectEqual(@as(usize, N_BANDS - 1), gapBand(20.0));
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
