//! The DIRECT construction for a differential pair with no room to couple.
//!
//! `diff_couple.zig` routes a declared `(net-class … (diff-pair GAP))` pair as
//! ONE centreline and `diff_route.build` splits it into two exact
//! ±(width+gap)/2 offset legs, with a 45° taper at each end converging the legs
//! from their pads' own pitch to the class gap. That construction is right
//! whenever there is room for it. This module is what to do when there is not.
//!
//! **The measurement** (2026-08-11, `diff_couple`'s own rejection census turned
//! on, board-d-synth-lmx2595 at `?rough=1`): both declared pairs decline at every
//! launch option with `no envelope-wide corridor`, and fall back to routing the
//! two legs as independent nets. That fallback is what the board ships, and it
//! is what "the differential pair routing on the clock stuff does not look
//! good" is looking at:
//!
//! | pair | legs | corners | skew |
//! |---|---|---|---|
//! | `LMX_OSCIN_P/N` | 3 and 6 segments | 4×90°, 2×45° | 0.163 mm |
//! | `REF_P/REF_N`   | 3 and 6 segments | 3×90°, 2×45°, 2×135° | 0.888 mm |
//!
//! Two independent maze routes, each hooking around the other, entering their
//! pads on different headings at different lengths.
//!
//! **Why the coupled construction cannot help.** Its two tapers alone need more
//! escape run than the pair's ends leave between them. On the OSCIN pair the
//! AC-coupling caps sit 1.27 mm from the QFN's pins 8/9, while the caps' 1.1 mm
//! pad pitch wants 0.673 mm of taper and the pins' 0.5 mm pitch another
//! 0.373 mm — 1.046 mm of the 1.27 mm gone before any coupled run starts. Ask
//! for the taper anyway and the leg jogs out past the coupled run's start and
//! doubles back into its twin (a 0.2965 mm hairpin whose return leg sits
//! 0.2424 mm from the other leg against a 0.2540 mm floor — measured).
//!
//! **What a hand route draws instead** over a millimetre and a half keeps the
//! receiver launch straight at the receiver's pad pitch, then makes one 45°
//! fan at the wider passive pads. Carrying the pitch change over the whole run
//! as one diagonal makes neither section a controlled pair: the spacing changes
//! at every point. This module therefore emits one straight launch plus one fan
//! per leg, with the fan placed at the wider end.
//!
//! It is pair-SAFE by construction rather than by care: both legs are emitted
//! together from the same pad pairing, so they cannot be trimmed or reshaped
//! independently — the failure mode that keeps pairs excluded from the scalar
//! dress passes (`straighten`, `pad_entry`, `bend_smooth`).
//!
//! It is OFFERED, never imposed. `diff_couple` reaches here only after every
//! coupled option has declined, the shape is gated to the case it is honest
//! about, and the legs still face the same exact clearance probe as any other
//! construction — so this can only ever ADD a pair that routes cleanly.

const std = @import("std");
const diff_route = @import("diff_route.zig");

const Pt = diff_route.Pt;

const FanFrame = struct { along: Pt, normal: Pt, layer: u8 };

/// Coordinate tolerance (mm), mirroring `diff_route`'s own weld tolerance.
const eps: f64 = 1e-9;

/// A pitch change below this is a landing-placement tolerance, not a useful RF
/// fan (mm). Drawing two extra 45 degree corners to absorb 10 um per leg is
/// strictly worse than the almost-axial pad-to-pad traces. The 1.02 mm R2 pitch
/// and 1.00 mm C14/C15 pitch on board-d-synth-lmx2595 are the motivating case.
const direct_pitch_delta_mm: f64 = 0.05;

/// The shortest coupled run worth building, as a multiple of the leg offset.
///
/// `diff_route.build` only treats a centreline run as COUPLED when it is at
/// least two offsets long — a shorter one is demoted to a pad-escape fan. So a
/// pair with less than this left over after both tapers has no coupled run to
/// build, whatever the construction is asked for, and belongs here.
const min_coupled_offsets: f64 = 2;

/// Is this pair too tight to carry a coupled run at all?
///
/// True when the two ends' pad exits (`diff_route.padExitRun` — the straight
/// stub plus the 45° convergence to the class gap) plus the shortest worthwhile
/// coupled run do not fit in the gap between the ends. This is exactly the
/// condition under which the coupled construction has to hairpin, and it is
/// what gates `directLegs`, so a pair that CAN be coupled is never handed the
/// short fan construction instead.
fn tooTightToCouple(ends: diff_route.Ends, off: f64) bool {
    if (ends.seq[0].len == 0 or ends.seq[1].len == 0) return false;
    const a = ends.seq[0][ends.seq[0].len - 1];
    const b = ends.seq[1][ends.seq[1].len - 1];
    const sep = std.math.hypot(a.mid.x - b.mid.x, a.mid.y - b.mid.y);
    const need = diff_route.padExitRun(a, off) + diff_route.padExitRun(b, off);
    return need + min_coupled_offsets * off > sep;
}

/// The two short pad-to-pad legs of a pair too tight to carry a coupled run.
///
/// Null unless the shape is the simple one this is honest about: exactly one
/// pad pair at each end (a longer walk threads a pad field and needs the
/// sequence construction), the two legs not crossing (a TWISTED pair genuinely
/// needs the via machinery to swap sides), and both legs of non-zero length.
///
/// When the ends have different pitches, each leg holds the narrower pitch in
/// a straight launch and changes pitch in one 45° fan at the wider end. The
/// segments are `.chain`: they land on pads and thread the pad field, so
/// nothing downstream may reshape them.
pub fn directLegs(
    arena: std.mem.Allocator,
    ends: diff_route.Ends,
    off: f64,
    layer: u8,
) std.mem.Allocator.Error!?diff_route.Legs {
    if (ends.seq[0].len != 1 or ends.seq[1].len != 1) return null;
    if (!tooTightToCouple(ends, off)) return null;
    const a = ends.seq[0][0];
    const b = ends.seq[1][0];
    if (crosses(a.p, b.p, a.n, b.n)) return null;
    if (len(a.p, b.p) <= eps or len(a.n, b.n) <= eps) return null;
    const a_pitch = len(a.p, a.n);
    const b_pitch = len(b.p, b.n);
    if (@abs(a_pitch - b_pitch) <= direct_pitch_delta_mm) {
        const segs = try arena.alloc(diff_route.LegSeg, 2);
        segs[0] = .{ .a = a.p, .b = b.p, .layer = layer, .side = .p, .kind = .chain };
        segs[1] = .{ .a = a.n, .b = b.n, .layer = layer, .side = .n, .kind = .chain };
        return .{ .segs = segs, .vias = &.{} };
    }

    const wide = if (a_pitch > b_pitch) a else b;
    const narrow = if (a_pitch > b_pitch) b else a;
    const dx = narrow.mid.x - wide.mid.x;
    const dy = narrow.mid.y - wide.mid.y;
    const span = std.math.hypot(dx, dy);
    if (span <= eps) return null;
    const along = Pt{ .x = dx / span, .y = dy / span };
    const frame = FanFrame{ .along = along, .normal = .{ .x = -along.y, .y = along.x }, .layer = layer };
    var segs: std.ArrayList(diff_route.LegSeg) = .empty;
    if (!try appendFannedLeg(arena, &segs, wide.p, narrow.p, frame, .p)) return null;
    if (!try appendFannedLeg(arena, &segs, wide.n, narrow.n, frame, .n)) return null;
    return .{ .segs = try segs.toOwnedSlice(arena), .vias = &.{} };
}

/// Append one leg as a 45° fan out of the wide pad followed by a straight run
/// at the narrow pad's transverse coordinate. False means the fan would consume
/// the whole end-to-end span, so this short-pair construction is not honest.
fn appendFannedLeg(
    arena: std.mem.Allocator,
    out: *std.ArrayList(diff_route.LegSeg),
    wide: Pt,
    narrow: Pt,
    frame: FanFrame,
    side_name: diff_route.Side,
) std.mem.Allocator.Error!bool {
    const delta = Pt{ .x = narrow.x - wide.x, .y = narrow.y - wide.y };
    const run = delta.x * frame.along.x + delta.y * frame.along.y;
    const spread = delta.x * frame.normal.x + delta.y * frame.normal.y;
    const fan = @abs(spread);
    if (run <= fan + eps) return false;
    const bend = Pt{
        .x = wide.x + frame.along.x * fan + frame.normal.x * spread,
        .y = wide.y + frame.along.y * fan + frame.normal.y * spread,
    };
    if (fan > eps) try out.append(arena, .{ .a = wide, .b = bend, .layer = frame.layer, .side = side_name, .kind = .chain });
    try out.append(arena, .{ .a = bend, .b = narrow, .layer = frame.layer, .side = side_name, .kind = .chain });
    return true;
}

/// Do segments a0—a1 and b0—b1 properly intersect? The legs of a TWISTED pair
/// do, and joining those pads straight would cross the pair over itself.
fn crosses(a0: Pt, a1: Pt, b0: Pt, b1: Pt) bool {
    const d1 = side(b0, b1, a0);
    const d2 = side(b0, b1, a1);
    const d3 = side(a0, a1, b0);
    const d4 = side(a0, a1, b1);
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0));
}

fn side(a: Pt, b: Pt, p: Pt) f64 {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

fn len(a: Pt, b: Pt) f64 {
    return std.math.hypot(a.x - b.x, a.y - b.y);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// An `Ends` with one pad pair per end: each end's pads straddle `x` at
/// `pitch` apart, the two ends `sep` apart along x.
fn fixture(
    arena: std.mem.Allocator,
    pitch_a: f64,
    pitch_b: f64,
    sep: f64,
) !diff_route.Ends {
    const sa = try arena.alloc(diff_route.PadPair, 1);
    sa[0] = .{
        .p = .{ .x = 0, .y = -pitch_a / 2 },
        .n = .{ .x = 0, .y = pitch_a / 2 },
        .mid = .{ .x = 0, .y = 0, .layer = 0 },
    };
    const sb = try arena.alloc(diff_route.PadPair, 1);
    sb[0] = .{
        .p = .{ .x = sep, .y = -pitch_b / 2 },
        .n = .{ .x = sep, .y = pitch_b / 2 },
        .mid = .{ .x = sep, .y = 0, .layer = 0 },
    };
    return .{
        .mid = .{ .{ .x = -0.9, .y = 0, .layer = 0 }, .{ .x = sep + 0.9, .y = 0, .layer = 0 } },
        .far = .{ .{ .x = -1.5, .y = 0, .layer = 0 }, .{ .x = sep + 1.5, .y = 0, .layer = 0 } },
        .seq = .{ sa, sb },
    };
}

// spec: placement/router - a differential pair whose ends are too tight to carry a coupled run holds the narrow pad pitch in a straight launch and fans outward once at the wider pads
test "directLegs keeps the narrow launch straight and fans once at the wide pads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // board-d-synth-lmx2595's OSCIN pair: 1.1 mm cap pitch into a 0.5 mm QFN pin
    // pitch, 1.27 mm apart. The two tapers alone want 1.046 mm of the 1.27.
    const off = 0.254;
    const ends = try fixture(arena, 1.1, 0.5, 1.27);
    try testing.expect(tooTightToCouple(ends, off));

    const legs = (try directLegs(arena, ends, off, 0)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 4), legs.segs.len);
    try testing.expectEqual(@as(usize, 0), legs.vias.len);
    // The wide 0402 pitch changes on one 45 degree fan per leg.
    try testing.expectEqual(diff_route.Side.p, legs.segs[0].side);
    try testing.expectEqual(diff_route.Side.p, legs.segs[1].side);
    try testing.expectEqual(diff_route.Side.n, legs.segs[2].side);
    try testing.expectEqual(diff_route.Side.n, legs.segs[3].side);
    try testing.expectApproxEqAbs(@as(f64, -0.55), legs.segs[0].a.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.30), legs.segs[0].b.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.25), legs.segs[0].b.y, 1e-9);
    // From that bend to the QFN both legs are straight and remain at its
    // 0.5 mm pad pitch, instead of changing separation along the whole run.
    try testing.expectApproxEqAbs(@as(f64, -0.25), legs.segs[1].a.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.25), legs.segs[1].b.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), legs.segs[3].a.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), legs.segs[3].b.y, 1e-9);
    // Both legs are `.chain`: they land on pads, so nothing may reshape them.
    for (legs.segs) |s| try testing.expectEqual(diff_route.Kind.chain, s.kind);
    // And the pair's own self-check passes — the legs never fold together.
    try testing.expect(diff_route.minOppositeGap(legs) >= off);
}

// spec: placement/router - a too-short differential pair whose endpoint pitches differ only by placement tolerance takes one direct pad-to-pad segment per leg
test "directLegs sends the near-equal R2 and coupling-cap pitches straight pad to pad" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // board-d-synth-lmx2595 REF_P/N: vertical R2 pads are 1.02 mm apart and the
    // adjacent C14/C15 pads are 1.00 mm apart, with only 1.02 mm between pair
    // centres. A 10 um jog on each leg buys no controlled-impedance run; it
    // only adds two RF corners.
    const ends = try fixture(arena, 1.02, 1.00, 1.02);
    const legs = (try directLegs(arena, ends, 0.254, 0)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), legs.segs.len);
    try testing.expectEqual(@as(usize, 0), legs.vias.len);
    try testing.expectApproxEqAbs(@as(f64, 0), legs.segs[0].a.x, eps);
    try testing.expectApproxEqAbs(@as(f64, 1.02), legs.segs[0].b.x, eps);
    try testing.expectApproxEqAbs(@as(f64, -0.51), legs.segs[0].a.y, eps);
    try testing.expectApproxEqAbs(@as(f64, -0.50), legs.segs[0].b.y, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.51), legs.segs[1].a.y, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.50), legs.segs[1].b.y, eps);
    for (legs.segs) |s| try testing.expectEqual(diff_route.Kind.chain, s.kind);
}

// spec: placement/router - a differential pair with room for a coupled run is not given the short-pair fan construction
test "directLegs declines a pair that has room to couple properly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same pad pitches, but the ends are 10 mm apart: the tapers fit easily and
    // the coupled construction owns this pair.
    const ends = try fixture(arena, 1.1, 0.5, 10.0);
    try testing.expect(!tooTightToCouple(ends, 0.254));
    try testing.expect((try directLegs(arena, ends, 0.254, 0)) == null);
}

// spec: placement/router - a twisted differential pair is refused the short-pair fan construction rather than crossed over itself
test "directLegs refuses a twisted pair instead of shorting it across" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ends = try fixture(arena, 1.1, 0.5, 1.27);
    // Twist the far end: its P pad is now on the N side, so a straight p→p and
    // n→n would cross.
    const sb = try arena.alloc(diff_route.PadPair, 1);
    sb[0] = .{
        .p = .{ .x = 1.27, .y = 0.25 },
        .n = .{ .x = 1.27, .y = -0.25 },
        .mid = .{ .x = 1.27, .y = 0, .layer = 0 },
    };
    ends.seq[1] = sb;
    try testing.expect((try directLegs(arena, ends, 0.254, 0)) == null);
}
