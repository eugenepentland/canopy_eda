//! Differential-pair post-route checks, factored out of `drc.zig` (at its
//! guardian file-size cap). Two WARNING-severity, non-blocking rules per
//! `(net-class … (diff-pair …))` pair carried on `Placement.diff_pairs`:
//!
//!   • `diff_uncoupled` — a stretch of the P net's copper with no N-net copper
//!     within the coupling window on the same layer (the pair split apart). The
//!     single worst spot is flagged.
//!   • `diff_skew` — the two legs' total routed length differs by more than the
//!     match tolerance (one leg meanders / detours). Flagged once per pair.
//!
//! Tolerances absorb grid quantization: the router's grid pitch is
//! `track_width + clearance`, so a coupled trace's centreline can sit up to a
//! pitch off the ideal `gap + track_width` spacing, and each 45° bend trades a
//! pitch of length between the legs. The windows below are sized from that
//! pitch so a cleanly-routed pair never trips, and only a real decouple/skew
//! does. Both checks require BOTH legs to carry copper — an unrouted leg is an
//! unrouted-net problem, not a coupling one — so a half-routed board is quiet.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const drc = @import("drc.zig");
const diff_pairs = @import("diff_pairs.zig");
const copper_length = @import("copper_length.zig");
const net_copper = @import("net_copper.zig");

/// Fallback trace width (mm) when a pair's P copper reports none — the router's
/// default track width, so the derived pitch matches an un-overridden net.
const default_width_mm: f64 = 0.127;

/// Append every diff-pair violation for `placement.diff_pairs` to `out`. A
/// no-op when the design declares no pairs, so the DRC output is byte-identical
/// for boards without differential pairs.
pub fn check(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    copper: Copper,
    clearance: f64,
) std.mem.Allocator.Error!void {
    const tracks = copper.tracks;
    for (placement.diff_pairs) |dp| {
        const pnet: i32 = @intCast(dp.p);
        const nnet: i32 = @intCast(dp.n);
        const len_p = try effectiveNetLength(arena, copper, pnet);
        const len_n = try effectiveNetLength(arena, copper, nnet);
        if (!(len_p > 0) or !(len_n > 0)) continue; // both legs must be routed
        const trace_w = firstWidth(tracks, pnet);
        const pitch = trace_w + clearance;

        // Skew: total routed length mismatch beyond the match window.
        const skew = @abs(len_p - len_n);
        const skew_tol = @max(4 * pitch, 1.0);
        if (skew > skew_tol) {
            const at = anySegMid(tracks, pnet);
            var v = finding(at[0], at[1], skew, skew_tol, .diff_skew);
            v.who = .{ .net_a = pnet, .net_b = nnet }; // the pair, so the report names both legs
            try out.append(arena, v);
        }

        // Coupling: the worst P-copper sample lacking N copper within the window.
        try appendUncoupled(arena, out, tracks, pnet, nnet, .{ .pitch = pitch, .couple = dp.gap + trace_w + pitch });
    }
}

/// The uncoupled scan's windows: the grid pitch (sets sample step + minimum run)
/// and `couple` (the centreline spacing a P sample must find N copper within).
const Win = struct { pitch: f64, couple: f64 };

/// A `Violation` at (x,y) with the given measured gap + rule, stamped with its
/// kind's CANONICAL built-in severity (`drc.defaultSeverity` — `.warn` for both
/// diff-pair kinds). Reading that one table instead of hardcoding `.warn` here
/// is what keeps the checker and the DRC-policy drawer's advertised default
/// from drifting apart, as they did when these two rules moved out of `drc.zig`
/// and the drawer's copy of the table stayed behind.
fn finding(x: f64, y: f64, gap: f64, clearance: f64, kind: drc.Kind) drc.Violation {
    return .{ .x = x, .y = y, .gap = gap, .clearance = clearance, .kind = kind, .severity = drc.defaultSeverity(kind) };
}

/// Flag the single worst uncoupled spot on the P net: the sample point on P's
/// copper whose nearest same-layer N copper is farthest away, when the run of
/// such samples is long enough to matter (a brief end-fanout gap is ignored).
fn appendUncoupled(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    tracks: []const router.Track,
    pnet: i32,
    nnet: i32,
    win: Win,
) std.mem.Allocator.Error!void {
    const couple = win.couple;
    const step = @max(win.pitch * 0.5, default_width_mm);
    const min_run = @max(2 * win.pitch, 1.0);
    var best_d: f64 = -1;
    var best_x: f64 = 0;
    var best_y: f64 = 0;
    for (tracks) |t| {
        if (t.net != pnet) continue;
        const seg_len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        const n_samp: usize = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(seg_len / step))));
        var run: f64 = 0; // contiguous uncoupled length on this leg
        var run_d: f64 = -1;
        var run_x: f64 = 0;
        var run_y: f64 = 0;
        var k: usize = 0;
        while (k <= n_samp) : (k += 1) {
            const f = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_samp));
            const px = t.x1 + f * (t.x2 - t.x1);
            const py = t.y1 + f * (t.y2 - t.y1);
            const d = nearestOnLayer(tracks, nnet, t.layer, px, py);
            if (d > couple) {
                run += step;
                if (d > run_d) {
                    run_d = d;
                    run_x = px;
                    run_y = py;
                }
            } else {
                if (run >= min_run and run_d > best_d) {
                    best_d = run_d;
                    best_x = run_x;
                    best_y = run_y;
                }
                run = 0;
                run_d = -1;
            }
        }
        if (run >= min_run and run_d > best_d) {
            best_d = run_d;
            best_x = run_x;
            best_y = run_y;
        }
    }
    if (best_d > 0) {
        var v = finding(best_x, best_y, best_d, couple, .diff_uncoupled);
        v.who = .{ .net_a = pnet, .net_b = nnet };
        try out.append(arena, v);
    }
}

/// The routed copper both rules read (`net_copper.Copper`, re-exported so a
/// caller of this rule need not know where the shape lives).
pub const Copper = net_copper.Copper;

/// A net's EFFECTIVE routed length (mm): the shortest path across its own merged
/// copper between its two most distant copper ends.
///
/// The summed length is what this used to read, and it over-reports whenever a
/// net overlaps itself — which same-net copper may legally do, so nothing else
/// objects. A pair whose leg retraces part of itself then measures as MATCHED
/// while the two electrical paths differ, i.e. the check reports the opposite of
/// the truth. Falls back to the sum when the copper does not connect its own
/// extremes (a half-routed or islanded net), where there is no path to measure
/// and the old number is at least a number.
///
/// Public because the skew NUMBER is needed outside the skew RULE. The rule
/// speaks only past `max(4·pitch, 1 mm)`, while a transaction that re-lays a
/// declared pair has to prove it came back no worse than the pair it replaced —
/// a standard the coupled constructor meets by an order of magnitude and a
/// two-independent-legs fallback misses while still tripping no finding. Both
/// read this one measure, so the gate and the DRC can never disagree about how
/// long a leg is.
pub fn effectiveNetLength(
    arena: std.mem.Allocator,
    copper: Copper,
    ni: i32,
) std.mem.Allocator.Error!f64 {
    const own = try net_copper.collect(arena, copper, ni);
    if (own.segs.len == 0) return 0;
    const ends = copper_length.farthestEnds(own.segs);
    const path = try copper_length.shortest(arena, own.segs, own.vias, ends[0], ends[1]);
    return path orelse netLength(copper.tracks, ni);
}

/// Total routed length (mm) of every track on net index `ni`.
fn netLength(tracks: []const router.Track, ni: i32) f64 {
    var sum: f64 = 0;
    for (tracks) |t| {
        if (t.net == ni) sum += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return sum;
}

/// The width of the first track on net `ni`, or the router default.
fn firstWidth(tracks: []const router.Track, ni: i32) f64 {
    for (tracks) |t| {
        if (t.net == ni and t.width > 0) return t.width;
    }
    return default_width_mm;
}

/// Midpoint of the first track on net `ni` (origin when the net has none — the
/// caller only reaches here after `netLength > 0`, so a segment always exists).
fn anySegMid(tracks: []const router.Track, ni: i32) [2]f64 {
    for (tracks) |t| {
        if (t.net == ni) return .{ (t.x1 + t.x2) / 2, (t.y1 + t.y2) / 2 };
    }
    return .{ 0, 0 };
}

/// Nearest distance (mm) from (px,py) to any track on net `ni` sharing `layer`;
/// ∞ when the net has no copper on that layer.
fn nearestOnLayer(tracks: []const router.Track, ni: i32, layer: u8, px: f64, py: f64) f64 {
    var lo: f64 = std.math.inf(f64);
    for (tracks) |t| {
        if (t.net != ni or t.layer != layer) continue;
        lo = @min(lo, pointSegDist(px, py, t.x1, t.y1, t.x2, t.y2));
    }
    return lo;
}

/// Distance (mm) from point (px,py) to the segment (ax,ay)-(bx,by).
fn pointSegDist(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 1e-12) return std.math.hypot(px - ax, py - ay);
    var t = ((px - ax) * dx + (py - ay) * dy) / len2;
    t = std.math.clamp(t, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a two-track diff-pair `Placement` + `RouteResult`: P runs straight
/// from (0,0) to (`len_p`,0); N runs from (0,`gap`) to (`nx2`,`ny2`). The pair
/// couples at `gap`. Returns the violations from a full `drc.check`.
fn diffCheck(arena: std.mem.Allocator, gap: f64, len_p: f64, nx2: f64, ny2: f64) ![]drc.Violation {
    const nets = [_]optimizer.FlatNet{ .{ .name = "D_P", .pins = &.{} }, .{ .name = "D_N", .pins = &.{} } };
    const pairs = [_]diff_pairs.DiffPair{.{ .p = 0, .n = 1, .gap = gap }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
        .diff_pairs = &pairs,
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = len_p, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0, .y1 = gap, .x2 = nx2, .y2 = ny2, .layer = 0, .width = 0.127, .net = 1 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };
    return drc.check(arena, placement, routed, 0.127);
}

fn hasKind(vs: []const drc.Violation, k: drc.Kind) bool {
    for (vs) |v| {
        if (v.kind == k) return true;
    }
    return false;
}

// spec: placement/drc - flags a differential pair whose legs are uncoupled and passes a tightly-coupled pair
test "diff-pair uncoupled fires on a split pair, silent on a hugging pair" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Tightly coupled: N parallel to P, 0.2 mm away over the whole 10 mm — no
    // uncoupled (nor skew) violation.
    const tight = try diffCheck(arena, 0.2, 10, 10, 0.2);
    try testing.expect(!hasKind(tight, .diff_uncoupled));

    // Split apart: N ends 8 mm away from P's far end, so most of P's copper has
    // no N copper within the coupling window — an uncoupled warning fires.
    const split = try diffCheck(arena, 0.2, 10, 10, 8);
    try testing.expect(hasKind(split, .diff_uncoupled));
    for (split) |v| {
        if (v.kind == .diff_uncoupled) try testing.expectEqual(drc.Severity.warn, v.severity);
    }
}

// spec: placement/drc - flags a differential pair whose leg lengths are skewed and passes a length-matched pair
test "diff-pair skew fires on mismatched leg lengths, silent when matched" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Matched: both legs ≈10 mm long (N at 0.2 mm offset) — no skew warning.
    const matched = try diffCheck(arena, 0.2, 10, 10, 0.2);
    try testing.expect(!hasKind(matched, .diff_skew));

    // Skewed: P is 4 mm, N runs to (4,6) ≈7.2 mm — a >3 mm length mismatch,
    // well past the ~1 mm tolerance, so a skew warning fires.
    const skewed = try diffCheck(arena, 0.2, 4, 4, 6);
    try testing.expect(hasKind(skewed, .diff_skew));
}
