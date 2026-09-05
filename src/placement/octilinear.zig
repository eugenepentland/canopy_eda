//! Octilinear (H/V/45) trace geometry — the router's angle discipline.
//!
//! Hand layout draws copper on eight headings: the two axes and the four
//! diagonals. The discipline is a convention, not physics — electrons do not
//! care — but it is what makes a board *reviewable*: a disciplined trace has a
//! few meaningful corners a human can grab, follow, and edit, while an
//! arbitrary-angle line threading a dozen obstacles has to be re-drawn from
//! scratch the moment anything near it moves. netlisp's boards are read by
//! humans in the viewer, hand-finished in KiCad, and edited by agents through
//! `add_tracks`, so followability is the scarce resource, not the few percent
//! of trace length the discipline costs.
//!
//! The maze search already moves on an 8-neighbour grid, so its raw path is
//! octilinear by construction. This module supplies the two pieces the rest of
//! the router needs to keep that property end-to-end:
//!
//!   * `isOctilinear` — judge a finished segment, for the gates that refuse a
//!     replacement which would break the discipline (`straighten`) and for the
//!     tests that assert it board-wide.
//!   * `elbows` — the two octilinear two-segment connections between any pair
//!     of points (axis-run-then-45°, and 45°-then-axis-run). Both have equal
//!     total length; a caller probes them for clearance and takes the first
//!     that fits. This is how an off-grid pad centre joins the on-grid maze
//!     without an arbitrary-angle stub, and how a straightener collapses a
//!     staircase without going taut.
//!
//! Deliberate exception: `bend_smooth` replaces the corners of `(max-freq …)`
//! nets with tangent arcs. That geometry is curved on purpose (a sharp corner
//! is an impedance discontinuity and a radiator at RF), so it is *signal*, not
//! noise — the whole value of a disciplined board is that the one curved trace
//! stands out as intentional.

const std = @import("std");

/// Heading tolerance for judging an existing segment octilinear: 1°. Emitted
/// copper is octilinear exactly (the constructions below are closed-form), so
/// this only absorbs float drift and the sub-micron jitter of coordinates that
/// have been through a world→grid→world round trip.
pub const tol_sin: f64 = 0.01745240643728351; // sin(1°)

/// Segments shorter than this (1 nm) carry no meaningful heading — a join
/// stub or a degenerate tessellation tail — so they are judged compliant
/// rather than being reported as arbitrary-angle copper.
pub const min_heading_mm: f64 = 1e-6;

/// Is the segment a→b drawn on one of the eight octilinear headings
/// (horizontal, vertical, or either 45° diagonal) within `tol_sin`?
///
/// The test is scale-free: `off` is the perpendicular-style residual to the
/// nearest of the three constraint families (|dy|=0, |dx|=0, |dx|=|dy|),
/// compared against the segment's own length, so a long trace is held to the
/// same *angular* standard as a short one.
pub fn isOctilinear(a: [2]f64, b: [2]f64) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < min_heading_mm) return true;
    const adx = @abs(dx);
    const ady = @abs(dy);
    const off = @min(@min(adx, ady), @abs(adx - ady));
    return off <= len * tol_sin;
}

/// Is a→b horizontal or vertical (rather than merely H/V/45)?
pub fn isAxisAligned(a: [2]f64, b: [2]f64) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < min_heading_mm) return true;
    return @min(@abs(dx), @abs(dy)) <= len * tol_sin;
}

/// The two octilinear two-segment connections from `a` to `b`, given as their
/// corner points: `[0]` runs along the dominant AXIS first and finishes on a
/// 45° diagonal, `[1]` takes the DIAGONAL first and finishes along the axis.
///
/// Both are exactly octilinear on both legs and have identical total length
/// (`max(|dx|,|dy|) + (√2−1)·min(|dx|,|dy|)`), so the choice between them is
/// purely about which one clears the obstacles in between — a caller probes
/// `a→mid` and `mid→b` for each and takes the first that fits.
///
/// When a→b is already octilinear the corner degenerates onto an endpoint
/// (a zero-length leg), so a caller that drops degenerate segments emits the
/// single straight run without needing to special-case it.
pub fn elbows(a: [2]f64, b: [2]f64) [2][2]f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const adx = @abs(dx);
    const ady = @abs(dy);
    const sx: f64 = if (dx < 0) -1 else 1;
    const sy: f64 = if (dy < 0) -1 else 1;
    if (adx >= ady) {
        return .{
            .{ a[0] + sx * (adx - ady), a[1] }, // axis run, then 45°
            .{ a[0] + sx * ady, a[1] + sy * ady }, // 45°, then axis run
        };
    }
    return .{
        .{ a[0], a[1] + sy * (ady - adx) },
        .{ a[0] + sx * adx, a[1] + sy * adx },
    };
}

/// The two AXIS-ONLY two-segment connections from `a` to `b`, as their corner
/// points: `[0]` runs along x first, `[1]` along y first. The Manhattan
/// counterpart of `elbows`, for the RF axis-only attempt (`manhattan_route`)
/// where no 45° leg may exist.
///
/// Both have the same total length (|dx| + |dy|), so the choice between them is
/// again purely which one clears; and as with `elbows`, an already-axis-aligned
/// pair degenerates its corner onto an endpoint, so a caller that drops
/// zero-length legs emits the single straight run without a special case.
pub fn axisElbows(a: [2]f64, b: [2]f64) [2][2]f64 {
    return .{ .{ b[0], a[1] }, .{ a[0], b[1] } };
}

// ── Compass headings ────────────────────────────────────────────────────────

/// The `k`-th heading of a search fan around `ang0`, quantized to the compass.
///
/// `ang0` is first SNAPPED to the nearest multiple of 45° measured from the +x
/// axis, so the fan is anchored to the board's axes no matter how arbitrary the
/// caller's preferred direction was — this is what keeps every escape fan, pad
/// gateway scan, and dogleg breakout octilinear even when it starts from a
/// "point away from the nearest obstacle" hint. `k` then swivels outward in
/// alternating directions (0 = straight on, 1/2 = ±45°, 3/4 = ±90°, …), so a
/// caller scanning k ascending tries the most aligned headings first.
pub fn compass45(ang0: f64, k: usize) f64 {
    const step = std.math.pi / 4.0;
    const base = @round(ang0 / step) * step;
    const mag: f64 = @floatFromInt((k + 1) / 2);
    const sign: f64 = if (k % 2 == 1) 1 else -1;
    return base + sign * mag * step;
}

/// Snap the heading of a→b to the nearest 45° multiple, keeping the length —
/// the fallback surface stub's octilinear discipline.
pub fn snap45(a: [2]f64, b: [2]f64) [2]f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < 1e-9) return b;
    const ang = compass45(std.math.atan2(dy, dx), 0);
    return .{ a[0] + len * @cos(ang), a[1] + len * @sin(ang) };
}

// ── Joining an off-raster point to the board ────────────────────────────────

/// The corner of a clearing octilinear connection from `a` to `b`, or null when
/// none is needed or none fits.
///
/// `seam` supplies `clear(a, b) bool` — the caller's DRC-grade segment test —
/// so this stays pure geometry while the obstacle model lives with the router.
/// Null means "emit the single segment a→b": either the pair is already
/// compliant (no corner needed), or neither elbow clears and the caller must
/// fall back. Degenerate legs are not probed, so an already-octilinear pair
/// costs no probe calls at all.
pub fn elbow(a: [2]f64, b: [2]f64, seam: anytype) ?[2]f64 {
    if (isOctilinear(a, b)) return null;
    // Try the candidate that bends LATER first — the one whose corner sits
    // farther from `a`. Callers pass the off-raster, congested end as `a` (a pad
    // centre, a plane-via site), so bending late means the copper leaves the pad
    // straight and turns out in open space, instead of elbowing across its
    // neighbours' escape lanes. Both candidates are the same total length, so
    // this costs nothing; it only decides which way the L is folded. It is the
    // same principle as the RF straight-escape reserve, applied to every pad.
    //
    // Measured on board-a: taking whichever cleared first cost one net
    // (`V_3V3_ID`, which failed to close) because early bends near fine-pitch
    // pads consume the lanes their neighbours must escape through.
    var cand = elbows(a, b);
    if (sqDist(a, cand[1]) > sqDist(a, cand[0])) cand = .{ cand[1], cand[0] };
    for (cand) |mid| {
        if (leg(a, mid) and !seam.clear(a, mid)) continue;
        if (leg(mid, b) and !seam.clear(mid, b)) continue;
        return mid;
    }
    return null;
}

fn sqDist(a: [2]f64, b: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return dx * dx + dy * dy;
}

/// Emit the copper joining `a` to `b` with octilinear discipline: the single
/// straight run when the pair is already compliant, else the first clearing
/// two-segment elbow, else — when neither fits — the direct segment.
///
/// That last fallback is deliberate: connectivity outranks cosmetics, and an
/// off-axis fraction-of-a-millimetre stub is a far better outcome than an open
/// net. `seam` also supplies `seg(a, b) !void`; degenerate legs are dropped, so
/// the compliant case emits exactly one segment.
pub fn emitJoin(a: [2]f64, b: [2]f64, seam: anytype) !void {
    if (!leg(a, b)) return;
    if (elbow(a, b, seam)) |mid| {
        if (leg(a, mid)) try seam.seg(a, mid);
        if (leg(mid, b)) try seam.seg(mid, b);
        return;
    }
    try seam.seg(a, b);
}

// ── Pad-axis terminal joins ────────────────────────────────────────────────

/// Axis-aligned copper bounds of one pad.
pub const PadBox = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// A pad centre, its component-outward direction, and its copper bounds.
pub const PadTerm = struct {
    at: [2]f64,
    out: [2]f64,
    box: PadBox,
};

/// Search pitch, trace radius, and bounded number of outward escape lengths.
pub const PadOptions = struct {
    step: f64,
    half_width: f64,
    rings: usize = 6,
};

/// Up to three bends joining one or two pads through axis-aligned exits.
pub const PadPath = struct {
    count: u2 = 0,
    bends: [3][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
};

const PadMiddle = struct {
    count: u1 = 0,
    bend: [2]f64 = .{ 0, 0 },
};

fn padAxis(term: PadTerm, toward: [2]f64) ?[2]f64 {
    var hint = term.out;
    if (std.math.hypot(hint[0], hint[1]) < min_heading_mm)
        hint = .{ toward[0] - term.at[0], toward[1] - term.at[1] };
    if (std.math.hypot(hint[0], hint[1]) < min_heading_mm) return null;
    if (@abs(hint[0]) >= @abs(hint[1])) return .{ if (hint[0] < 0) -1 else 1, 0 };
    return .{ 0, if (hint[1] < 0) -1 else 1 };
}

fn padEscape(term: PadTerm, axis: [2]f64, opt: PadOptions, ring: usize) [2]f64 {
    const edge = if (axis[0] > 0)
        term.box.x1 - term.at[0]
    else if (axis[0] < 0)
        term.at[0] - term.box.x0
    else if (axis[1] > 0)
        term.box.y1 - term.at[1]
    else
        term.at[1] - term.box.y0;
    const base = @max(opt.step, edge + opt.half_width);
    const distance = base + @as(f64, @floatFromInt(ring)) * opt.step;
    return .{ term.at[0] + axis[0] * distance, term.at[1] + axis[1] * distance };
}

fn padMiddle(
    comptime Context: type,
    a: [2]f64,
    b: [2]f64,
    context: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) ?PadMiddle {
    if (isOctilinear(a, b)) return if (clear(context, a, b)) .{} else null;
    var cand = elbows(a, b);
    if (sqDist(a, cand[1]) > sqDist(a, cand[0])) cand = .{ cand[1], cand[0] };
    for (cand) |mid| {
        if (leg(a, mid) and !clear(context, a, mid)) continue;
        if (leg(mid, b) and !clear(context, mid, b)) continue;
        return .{ .count = 1, .bend = mid };
    }
    return null;
}

/// Prefer a horizontal/vertical run from `term` before joining `target`.
pub fn padExit(
    comptime Context: type,
    term: PadTerm,
    target: [2]f64,
    opt: PadOptions,
    context: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) ?PadPath {
    const axis = padAxis(term, target) orelse return null;
    for (0..opt.rings) |ring| {
        const exit = padEscape(term, axis, opt, ring);
        if (!clear(context, term.at, exit)) continue;
        const middle = padMiddle(Context, exit, target, context, clear) orelse continue;
        var out = PadPath{ .count = 1, .bends = .{ exit, .{ 0, 0 }, .{ 0, 0 } } };
        if (middle.count > 0) {
            out.bends[1] = middle.bend;
            out.count = 2;
        }
        return out;
    }
    return null;
}

/// Prefer outward H/V runs at both pads, nearest escape lengths first.
pub fn padPair(
    comptime Context: type,
    a: PadTerm,
    b: PadTerm,
    opt: PadOptions,
    context: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) ?PadPath {
    if (opt.rings == 0) return null;
    const axis_a = padAxis(a, b.at) orelse return null;
    const axis_b = padAxis(b, a.at) orelse return null;
    const direct = [2]f64{ b.at[0] - a.at[0], b.at[1] - a.at[1] };
    if (isAxisAligned(a.at, b.at) and
        direct[0] * axis_a[0] + direct[1] * axis_a[1] > 0 and
        direct[0] * axis_b[0] + direct[1] * axis_b[1] < 0 and
        clear(context, a.at, b.at)) return .{};
    for (0..opt.rings * 2 - 1) |sum| {
        for (0..opt.rings) |ar| {
            if (ar > sum) continue;
            const br = sum - ar;
            if (br >= opt.rings) continue;
            const ae = padEscape(a, axis_a, opt, ar);
            const be = padEscape(b, axis_b, opt, br);
            if (!clear(context, a.at, ae) or !clear(context, b.at, be)) continue;
            const middle = padMiddle(Context, ae, be, context, clear) orelse continue;
            var out = PadPath{ .count = 2, .bends = .{ ae, be, .{ 0, 0 } } };
            if (middle.count > 0) {
                out.bends[1] = middle.bend;
                out.bends[2] = be;
                out.count = 3;
            }
            return out;
        }
    }
    return null;
}

/// Is a→b long enough to be worth emitting or probing (not a degenerate leg)?
fn leg(a: [2]f64, b: [2]f64) bool {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]) >= min_heading_mm;
}

// ── Turn cost for the maze search ───────────────────────────────────────────

/// The maze-search state a turn is judged against, resolved once per search
/// rather than per relaxation.
pub const Lattice = struct {
    /// Grid column count and total node count, for decoding a search key.
    nx: usize,
    nodes: usize,
    /// The search tree the incoming heading is read from.
    prev: []const i64,
    /// False for a leg whose shape is already pinned by an explicit constraint
    /// — a diff-pair coupling corridor, or a replayed reference path. Those are
    /// electrical/intent constraints; corner count is cosmetic and must not
    /// reorder them, so no turn is ever counted on such a leg.
    enabled: bool = true,
};

/// The heading of the same-layer move `from_key` → `to_key` as an integer cell
/// delta, or null when the move changes layer — a via has no heading, and the
/// step after one is free to leave in any direction. Keys are the router's
/// `layer * nodes + node` encoding; `nx` is the grid's column count.
pub fn heading(nx: usize, nodes: usize, from_key: usize, to_key: usize) ?[2]i64 {
    if (from_key / nodes != to_key / nodes) return null;
    const a = from_key % nodes;
    const b = to_key % nodes;
    const ax: i64 = @intCast(a % nx);
    const ay: i64 = @intCast(a / nx);
    const bx: i64 = @intCast(b % nx);
    const by: i64 = @intCast(b / nx);
    return .{ bx - ax, by - ay };
}

/// 1 when the move `from_key` → `to_key` changes heading, else 0 — the
/// tie-break increment the router accumulates per search state.
///
/// Zero at a search source (no incoming heading to turn from), across a via, on
/// the first step after one, when the heading is unchanged, and on any leg whose
/// `Lattice.enabled` is false. The incoming heading is read off the search tree
/// (`prev`), so a node is judged by the one path that settled it — exact enough
/// for ordering, and it costs no extra state.
pub fn turned(lat: Lattice, from_key: usize, to_key: usize) u32 {
    if (!lat.enabled) return 0;
    return turnedAlways(lat, from_key, to_key);
}

/// `turned` with the `Lattice.enabled` gate removed.
///
/// That gate exists because a TIE-BREAK on corner count must never reorder a leg
/// whose shape an explicit constraint already pins. A search that prices a
/// corner as real COST is making a different claim — the corner is the thing
/// being bought — so it reads the turn unconditionally; silencing it there would
/// not preserve a shape, it would produce a staircase.
pub fn turnedAlways(lat: Lattice, from_key: usize, to_key: usize) u32 {
    const out = heading(lat.nx, lat.nodes, from_key, to_key) orelse return 0;
    const pk = lat.prev[from_key];
    if (pk < 0) return 0;
    const in = heading(lat.nx, lat.nodes, @intCast(pk), from_key) orelse return 0;
    return if (in[0] == out[0] and in[1] == out[1]) 0 else 1;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/octilinear - judges the eight octilinear headings compliant and an off-axis heading not
test "isOctilinear accepts the eight headings and rejects an arbitrary slope" {
    const o = [2]f64{ 5, 5 };
    // The eight compass headings, each at a different length.
    try testing.expect(isOctilinear(o, .{ 9, 5 })); // E
    try testing.expect(isOctilinear(o, .{ 1, 5 })); // W
    try testing.expect(isOctilinear(o, .{ 5, 8 })); // S (y grows down)
    try testing.expect(isOctilinear(o, .{ 5, 2 })); // N
    try testing.expect(isOctilinear(o, .{ 8, 8 })); // SE
    try testing.expect(isOctilinear(o, .{ 2, 8 })); // SW
    try testing.expect(isOctilinear(o, .{ 8, 2 })); // NE
    try testing.expect(isOctilinear(o, .{ 2, 2 })); // NW
    // Arbitrary slopes between the headings are refused.
    try testing.expect(!isOctilinear(o, .{ 15, 8 })); // ~16.7°
    try testing.expect(!isOctilinear(o, .{ 8, 12 })); // ~66.8°
    try testing.expect(!isOctilinear(o, .{ 9, 9.5 })); // just off 45°
}

// spec: placement/octilinear - judges a degenerate segment compliant so a join stub is never reported as off-axis
test "isOctilinear treats a sub-nanometre segment as compliant" {
    const a = [2]f64{ 3, 4 };
    try testing.expect(isOctilinear(a, a));
    try testing.expect(isOctilinear(a, .{ 3 + 1e-9, 4 + 3e-10 }));
}

// spec: placement/octilinear - distinguishes horizontal and vertical runs from diagonal octilinear copper
test "isAxisAligned accepts only the two board axes" {
    const a = [2]f64{ 1, 2 };
    try testing.expect(isAxisAligned(a, .{ 5, 2 }));
    try testing.expect(isAxisAligned(a, .{ 1, -3 }));
    try testing.expect(!isAxisAligned(a, .{ 4, 5 }));
}

// spec: placement/octilinear - both elbow connections are octilinear on each leg and equal in total length
test "elbows produce two equal-length octilinear two-segment paths" {
    const cases = [_][2][2]f64{
        .{ .{ 0, 0 }, .{ 10, 3 } }, // x-dominant, both positive
        .{ .{ 0, 0 }, .{ 3, 10 } }, // y-dominant
        .{ .{ 7, 2 }, .{ 1, 9 } }, // mixed signs, y-dominant
        .{ .{ 7, 9 }, .{ 1, 2 } }, // both negative
        .{ .{ 2, 2 }, .{ 12, 4.5 } }, // non-integer
    };
    for (cases) |c| {
        const a = c[0];
        const b = c[1];
        const es = elbows(a, b);
        var prev_total: ?f64 = null;
        for (es) |mid| {
            try testing.expect(isOctilinear(a, mid));
            try testing.expect(isOctilinear(mid, b));
            const total = std.math.hypot(mid[0] - a[0], mid[1] - a[1]) +
                std.math.hypot(b[0] - mid[0], b[1] - mid[1]);
            if (prev_total) |p| try testing.expectApproxEqAbs(p, total, 1e-9);
            prev_total = total;
        }
        // …and the octilinear detour is never longer than the diagonal bound.
        const dx = @abs(b[0] - a[0]);
        const dy = @abs(b[1] - a[1]);
        const bound = @max(dx, dy) + (std.math.sqrt2 - 1.0) * @min(dx, dy);
        try testing.expectApproxEqAbs(bound, prev_total.?, 1e-9);
    }
}

// spec: placement/octilinear - an already-octilinear pair degenerates to a single run with a zero-length leg
test "elbows degenerate onto an endpoint when the pair is already octilinear" {
    const a = [2]f64{ 1, 1 };
    for ([_][2]f64{ .{ 6, 1 }, .{ 1, 6 }, .{ 5, 5 }, .{ -3, 5 } }) |b| {
        const es = elbows(a, b);
        for (es) |mid| {
            const at_a = std.math.hypot(mid[0] - a[0], mid[1] - a[1]) < 1e-12;
            const at_b = std.math.hypot(mid[0] - b[0], mid[1] - b[1]) < 1e-12;
            try testing.expect(at_a or at_b);
        }
    }
}

// spec: placement/octilinear - a compass fan quantizes an arbitrary preferred heading onto the axis-referenced 45 degree multiples
test "compass45 snaps an arbitrary base heading onto the axis-referenced compass" {
    // An arbitrary hint (23.7°) still yields headings that are exact multiples
    // of 45° from +x — this is what keeps every escape fan octilinear even
    // though its "point away from obstacles" hint is unconstrained.
    const hint: f64 = 0.4137;
    for (0..8) |k| {
        const ang = compass45(hint, k);
        const quarter = ang / (std.math.pi / 4.0);
        try testing.expectApproxEqAbs(@round(quarter), quarter, 1e-12);
    }
    // …and snap45 moves the endpoint onto such a heading while keeping length.
    const a = [2]f64{ 2, 3 };
    const b = [2]f64{ 7.3, 4.1 };
    const snapped = snap45(a, b);
    try testing.expect(isOctilinear(a, snapped));
    try testing.expectApproxEqAbs(
        std.math.hypot(b[0] - a[0], b[1] - a[1]),
        std.math.hypot(snapped[0] - a[0], snapped[1] - a[1]),
        1e-9,
    );
}

/// A seam that records emitted segments; `blocked` vetoes any leg passing
/// within `r` of it, standing in for foreign copper crowding the elbow.
const RecordSeam = struct {
    out: *std.ArrayList([2][2]f64),
    arena: std.mem.Allocator,
    blocked: ?[2]f64 = null,
    r: f64 = 0.25,

    fn clear(self: RecordSeam, a: [2]f64, b: [2]f64) bool {
        const p = self.blocked orelse return true;
        for (0..41) |k| {
            const t = @as(f64, @floatFromInt(k)) / 40.0;
            const x = a[0] + t * (b[0] - a[0]);
            const y = a[1] + t * (b[1] - a[1]);
            if (std.math.hypot(x - p[0], y - p[1]) < self.r) return false;
        }
        return true;
    }

    fn seg(self: RecordSeam, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
        try self.out.append(self.arena, .{ a, b });
    }
};

// spec: placement/octilinear - a pad pair leaves both centres along their outward horizontal or vertical axes before joining
test "padPair keeps both terminal legs axis-aligned and outward" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var unused: std.ArrayList([2][2]f64) = .empty;
    const seam = RecordSeam{ .out = &unused, .arena = arena };
    const a = PadTerm{ .at = .{ 0, 0 }, .out = .{ -1, 0 }, .box = .{ .x0 = -0.3, .y0 = -0.15, .x1 = 0.3, .y1 = 0.15 } };
    const b = PadTerm{ .at = .{ -3, 1 }, .out = .{ 1, 0 }, .box = .{ .x0 = -3.2, .y0 = 0.8, .x1 = -2.8, .y1 = 1.2 } };
    const path = padPair(RecordSeam, a, b, .{ .step = 0.254, .half_width = 0.0635 }, seam, RecordSeam.clear) orelse
        return testing.expect(false);
    try testing.expect(path.count >= 2);
    try testing.expect(isAxisAligned(a.at, path.bends[0]));
    try testing.expect(isAxisAligned(path.bends[path.count - 1], b.at));
    try testing.expect(path.bends[0][0] < a.at[0]);
    try testing.expect(path.bends[path.count - 1][0] > b.at[0]);
}

// spec: placement/octilinear - a single pad escape tries longer outward axis runs when its nearest join is blocked
test "padExit scans outward before giving up its axis" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var unused: std.ArrayList([2][2]f64) = .empty;
    const seam = RecordSeam{ .out = &unused, .arena = arena, .blocked = .{ -0.37, 0.3 }, .r = 0.12 };
    const term = PadTerm{ .at = .{ 0, 0 }, .out = .{ -1, 0 }, .box = .{ .x0 = -0.2, .y0 = -0.2, .x1 = 0.2, .y1 = 0.2 } };
    const path = padExit(RecordSeam, term, .{ -1.5, 0.6 }, .{ .step = 0.2, .half_width = 0.05 }, seam, RecordSeam.clear) orelse
        return testing.expect(false);
    try testing.expect(isAxisAligned(term.at, path.bends[0]));
    try testing.expect(path.bends[0][0] < term.at[0]);
}

// spec: placement/octilinear - the join seam emits one straight run for a compliant pair and a two-segment elbow otherwise
test "emitJoin emits one run when compliant and an elbow when not" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var straight: std.ArrayList([2][2]f64) = .empty;
    try emitJoin(.{ 0, 0 }, .{ 3, 3 }, RecordSeam{ .out = &straight, .arena = arena });
    try testing.expectEqual(@as(usize, 1), straight.items.len);

    var bent: std.ArrayList([2][2]f64) = .empty;
    try emitJoin(.{ 0, 0 }, .{ 4, 1 }, RecordSeam{ .out = &bent, .arena = arena });
    try testing.expectEqual(@as(usize, 2), bent.items.len);
    for (bent.items) |e| try testing.expect(isOctilinear(e[0], e[1]));
    // The legs chain, and the endpoints are exactly what was asked for.
    try testing.expectEqual(bent.items[0][1], bent.items[1][0]);
    try testing.expectEqual([2]f64{ 0, 0 }, bent.items[0][0]);
    try testing.expectEqual([2]f64{ 4, 1 }, bent.items[1][1]);
}

// spec: placement/octilinear - the join seam falls back to the direct segment when neither elbow clears so connectivity is never lost
test "emitJoin falls back to the direct segment when both elbows are blocked" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var out: std.ArrayList([2][2]f64) = .empty;
    // The elbow corners of (0,0)→(2,1) are (1,0) and (1,1); an obstacle midway
    // between them, with a reach that covers both, vetoes every candidate leg.
    // The direct segment runs straight through it — the fallback does not probe,
    // because an open net is a worse outcome than an off-axis stub.
    const seam = RecordSeam{ .out = &out, .arena = arena, .blocked = .{ 1.0, 0.5 }, .r = 0.6 };
    try emitJoin(.{ 0, 0 }, .{ 2, 1 }, seam);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual([2]f64{ 0, 0 }, out.items[0][0]);
    try testing.expectEqual([2]f64{ 2, 1 }, out.items[0][1]);
}

// spec: placement/octilinear - a heading change is counted as a turn while a straight continuation and a via are not
test "turned counts only a heading change" {
    // A 4-column grid, one layer of 12 nodes; keys are layer*nodes + node.
    const nx: usize = 4;
    const nodes: usize = 12;
    var prev: [24]i64 = @splat(-1);
    prev[5] = 4;
    const lat = Lattice{ .nx = nx, .nodes = nodes, .prev = &prev };
    // Path 4 → 5 → 6 runs straight east: leaving 5 eastward is no turn.
    try testing.expectEqual(@as(u32, 0), turned(lat, 5, 6));
    // Turning north-east at 5 is a turn…
    try testing.expectEqual(@as(u32, 1), turned(lat, 5, 2));
    // …unless the leg's shape is already pinned by a corridor.
    try testing.expectEqual(@as(u32, 0), turned(.{ .nx = nx, .nodes = nodes, .prev = &prev, .enabled = false }, 5, 2));
    // A source has no incoming heading, so it may leave in any direction free.
    try testing.expectEqual(@as(u32, 0), turned(lat, 4, 9));
    // Arriving by via resets the heading: the next step is free whichever way.
    prev[5] = 5 + @as(i64, nodes);
    try testing.expectEqual(@as(u32, 0), turned(lat, 5, 2));
    // …and the via move itself is never a turn.
    prev[5] = 4;
    try testing.expectEqual(@as(u32, 0), turned(lat, 5, 5 + nodes));
}

// spec: placement/octilinear - a corner priced as search cost is counted even on a leg whose corner tie-break is suppressed
test "turnedAlways counts a heading change a pinned lattice would hide" {
    const nx: usize = 4;
    const nodes: usize = 12;
    var prev: [24]i64 = @splat(-1);
    prev[5] = 4; // reached 5 heading east
    const pinned = Lattice{ .nx = nx, .nodes = nodes, .prev = &prev, .enabled = false };
    // The tie-break stays silent on a pinned leg…
    try testing.expectEqual(@as(u32, 0), turned(pinned, 5, 2));
    // …while the priced form still reads the corner it would be buying.
    try testing.expectEqual(@as(u32, 1), turnedAlways(pinned, 5, 2));
    // Every other exemption is shared: straight on, a source, and a via.
    try testing.expectEqual(@as(u32, 0), turnedAlways(pinned, 5, 6));
    try testing.expectEqual(@as(u32, 0), turnedAlways(pinned, 4, 9));
    try testing.expectEqual(@as(u32, 0), turnedAlways(pinned, 5, 5 + nodes));
}

// spec: placement/octilinear - the axis-only elbow pair offers both L corners and degenerates on an already-axis-aligned pair
test "axisElbows gives the two L corners and no diagonal leg" {
    const a = [2]f64{ 1, 2 };
    const b = [2]f64{ 5, 9 };
    const cand = axisElbows(a, b);
    try testing.expectEqual([2]f64{ 5, 2 }, cand[0]); // x first
    try testing.expectEqual([2]f64{ 1, 9 }, cand[1]); // y first
    // Every leg of both candidates is horizontal or vertical — no 45° anywhere,
    // which is the whole difference from `elbows`.
    for (cand) |mid| {
        try testing.expect(isAxisAligned(a, mid));
        try testing.expect(isAxisAligned(mid, b));
    }
    // Both L's are the same length, and it is the Manhattan distance.
    try testing.expectApproxEqAbs(@as(f64, 11), legLen(a, cand[0]) + legLen(cand[0], b), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 11), legLen(a, cand[1]) + legLen(cand[1], b), 1e-12);
    // An axis-aligned pair puts both corners on an endpoint, so the caller that
    // drops degenerate legs emits one straight run.
    const flat = axisElbows(.{ 1, 2 }, .{ 5, 2 });
    try testing.expectEqual([2]f64{ 5, 2 }, flat[0]);
    try testing.expectEqual([2]f64{ 1, 2 }, flat[1]);
}

fn legLen(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}
