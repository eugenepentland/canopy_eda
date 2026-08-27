//! Canonical electrical-contact policy shared by every copper connectivity
//! model. Fabricated copper conducts only when its geometry carries a complete
//! bottleneck cross-section within the 1 µm numeric tolerance. A larger
//! same-net gap up to 20 µm is deliberately *not* a join: it is the hairline
//! defect band reported by `net_open`.

const std = @import("std");
const numeric = @import("../numeric.zig");
const pad_shape = @import("pad_shape.zig");

pub const join_slack_mm: f64 = 1e-3;
pub const hairline_slack_mm: f64 = 0.02;

/// Electrical classification of the edge-to-edge gap between same-net copper.
pub const GapClass = enum { connected, hairline, open };

/// Classify a same-net edge gap without allowing the hairline band to conduct.
pub fn classifyGap(gap_mm: f64) GapClass {
    if (gap_mm <= join_slack_mm) return .connected;
    if (gap_mm <= hairline_slack_mm) return .hairline;
    return .open;
}

/// Through-hole copper reaches every routable layer. An SMD land reaches only
/// its authored outer face (top=0, bottom=1).
pub fn padOnLayer(thru: bool, pad_layer: u8, copper_layer: u8) bool {
    return thru or pad_layer == copper_layer;
}

const Interval = struct { lo: f64 = 0, hi: f64 = 1 };

fn clipAxis(interval: *Interval, start: f64, delta: f64, lo: f64, hi: f64) bool {
    if (lo > hi) return false;
    if (@abs(delta) <= 1e-12) return start >= lo and start <= hi;
    const a = (lo - start) / delta;
    const b = (hi - start) / delta;
    interval.lo = @max(interval.lo, @min(a, b));
    interval.hi = @min(interval.hi, @max(a, b));
    return interval.lo <= interval.hi;
}

fn cross(a: [2]f64, b: [2]f64) f64 {
    return a[0] * b[1] - a[1] * b[0];
}

fn clipLineAxis(lo: *f64, hi: *f64, start: f64, delta: f64, min: f64, max: f64) bool {
    if (@abs(delta) <= 1e-12) return start >= min and start <= max;
    const a = (min - start) / delta;
    const b = (max - start) / delta;
    lo.* = @max(lo.*, @min(a, b));
    hi.* = @min(hi.*, @max(a, b));
    return lo.* <= hi.*;
}

const ChordBounds = struct {
    lo: f64 = -std.math.inf(f64),
    hi: f64 = std.math.inf(f64),
    saw_lo: bool = false,
    saw_hi: bool = false,

    fn include(self: *ChordBounds, anchor: [2]f64, normal: [2]f64, before: [2]f64, point: [2]f64) void {
        const edge = [2]f64{ point[0] - before[0], point[1] - before[1] };
        const rel = [2]f64{ before[0] - anchor[0], before[1] - anchor[1] };
        const denominator = cross(normal, edge);
        if (@abs(denominator) <= 1e-12) return;
        const along_edge = cross(rel, normal) / denominator;
        if (along_edge < -1e-9 or along_edge > 1 + 1e-9) return;
        const t = cross(rel, edge) / denominator;
        if (t <= 1e-9 and (!self.saw_lo or t > self.lo)) {
            self.lo = t;
            self.saw_lo = true;
        }
        if (t >= -1e-9 and (!self.saw_hi or t < self.hi)) {
            self.hi = t;
            self.saw_hi = true;
        }
    }
};

/// The complete pad-copper chord through its deterministic copper anchor in
/// direction `normal`. For a concave custom land this selects the connected
/// interval containing the anchor, never a remote lobe across a relief notch.
fn padAnchorChord(shape: pad_shape.Shape, normal: [2]f64) ?[2][2]f64 {
    const anchor = pad_shape.copperAnchor(shape);
    var lo = -std.math.inf(f64);
    var hi = std.math.inf(f64);
    if (shape.poly.len < 3) {
        if (!clipLineAxis(&lo, &hi, anchor[0], normal[0], shape.x0, shape.x1) or
            !clipLineAxis(&lo, &hi, anchor[1], normal[1], shape.y0, shape.y1)) return null;
    } else {
        var bounds = ChordBounds{};
        var before = shape.poly[shape.poly.len - 1];
        for (shape.poly) |point| {
            bounds.include(anchor, normal, before, point);
            before = point;
        }
        if (!bounds.saw_lo or !bounds.saw_hi) return null;
        lo = bounds.lo;
        hi = bounds.hi;
    }
    if (!(hi > lo + 1e-12)) return null;
    return .{
        .{ anchor[0] + normal[0] * lo, anchor[1] + normal[1] * lo },
        .{ anchor[0] + normal[0] * hi, anchor[1] + normal[1] * hi },
    };
}

fn padBottleneckConnects(shape: pad_shape.Shape, a: [2]f64, b: [2]f64, normal: [2]f64, radius: f64) bool {
    const chord = padAnchorChord(shape, normal) orelse return false;
    for (chord) |point| {
        if (pad_shape.segPointDist(a[0], a[1], b[0], b[1], point[0], point[1]) >
            radius + join_slack_mm) return false;
    }
    return true;
}

/// Does the trace and land share a fabrication-robust neck? The narrower
/// feature is the bottleneck: either one complete transverse trace chord fits
/// on the land, or the land's complete anchor chord fits in the trace capsule.
/// Mere edge/corner overlap satisfies neither direction and stays open.
pub fn padTrackConnects(shape: pad_shape.Shape, a: [2]f64, b: [2]f64, width: f64) bool {
    if (!(width > 0)) return false;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const length = std.math.hypot(dx, dy);
    if (length <= 1e-12) return false;
    const nx = -dy / length;
    const ny = dx / length;
    const radius = width / 2;

    // A full transverse chord fits only where the centreline lies inside this
    // normal-dependent inset of the pad's bounding box. For ordinary
    // axis-aligned lands this slab intersection is the exact answer.
    const inset_x = @abs(nx) * radius;
    const inset_y = @abs(ny) * radius;
    var interval = Interval{};
    if (!clipAxis(&interval, a[0], dx, shape.x0 + inset_x - join_slack_mm, shape.x1 - inset_x + join_slack_mm) or
        !clipAxis(&interval, a[1], dy, shape.y0 + inset_y - join_slack_mm, shape.y1 - inset_y + join_slack_mm))
        return padBottleneckConnects(shape, a, b, .{ nx, ny }, radius);
    if (shape.poly.len < 3) return true;

    // Rotated, rounded, and custom lands carry exact outlines. Walk only the
    // already-clipped near-pad interval and require the entire transverse
    // chord (nine witnesses, including both edges) to sit on that outline.
    const clipped_length = length * (interval.hi - interval.lo);
    const steps = @max(@as(usize, 1), numeric.checkedInt(usize, @ceil(clipped_length / 0.025)) orelse 1);
    for (0..steps + 1) |step| {
        const t = interval.lo + (interval.hi - interval.lo) *
            @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
        const cx = a[0] + t * dx;
        const cy = a[1] + t * dy;
        var covered = true;
        for (0..9) |cross_step| {
            const offset = -radius + width * @as(f64, @floatFromInt(cross_step)) / 8;
            if (pad_shape.pointDist(
                shape.x0,
                shape.y0,
                shape.x1,
                shape.y1,
                shape.poly,
                cx + nx * offset,
                cy + ny * offset,
                join_slack_mm + 1e-9,
            ) > join_slack_mm + 1e-9) {
                covered = false;
                break;
            }
        }
        if (covered) return true;
    }
    return padBottleneckConnects(shape, a, b, .{ nx, ny }, radius);
}

/// Ordinary geometric overlap between two round-capped trace capsules. This
/// is useful to FIND a weak join that cleanup should bridge, but it is not
/// enough to prove electrical connectivity: two caps or parallel flanks can
/// share an arbitrarily thin sliver of copper.
pub const Trace = struct {
    a: [2]f64,
    b: [2]f64,
    width: f64,
};

/// A drilled barrel's outer copper diameter. Connectivity on either surface is
/// judged against this copper land; drill/annulus sufficiency is a separate
/// fabrication rule.
pub const Via = struct {
    at: [2]f64,
    dia: f64,
};

/// Whether the two round-capped trace shapes overlap at all, including a weak
/// contact that is insufficient for electrical connectivity.
pub fn trackTrackCapsulesOverlap(a: Trace, b: Trace) bool {
    if (!(a.width > 0 and b.width > 0)) return false;
    return pad_shape.segSegDist(a.a, a.b, b.a, b.b) <=
        a.width / 2 + b.width / 2 + join_slack_mm;
}

/// Whether a trace capsule and via land overlap at all, including a tangential
/// sliver that is too narrow to prove electrical connectivity.
pub fn trackViaCopperOverlaps(track: Trace, via: Via) bool {
    if (!(track.width > 0 and via.dia > 0)) return false;
    return pad_shape.segPointDist(
        track.a[0],
        track.a[1],
        track.b[0],
        track.b[1],
        via.at[0],
        via.at[1],
    ) <= track.width / 2 + via.dia / 2 + join_slack_mm;
}

/// Does a trace meet a via through a fabrication-robust neck? The narrower
/// feature sets the bottleneck:
///
/// * when the trace is narrower, one complete transverse trace-width chord
///   must fit inside the via land;
/// * when the via is narrower, one complete via-diameter chord through the
///   barrel centre must fit inside the trace capsule.
///
/// Both shapes are convex, so checking both endpoints proves the whole chord.
/// A trace/via edge graze therefore remains open while ordinary centred and
/// offset landings continue to conduct.
pub fn trackViaConnects(track: Trace, via: Via) bool {
    if (!trackViaCopperOverlaps(track, via)) return false;
    const dx = track.b[0] - track.a[0];
    const dy = track.b[1] - track.a[1];
    const length = std.math.hypot(dx, dy);
    if (length <= 1e-12) return false;
    const closest = pad_shape.closestOnSeg(
        track.a[0],
        track.a[1],
        track.b[0],
        track.b[1],
        via.at[0],
        via.at[1],
    );

    if (track.width <= via.dia) {
        const nx = -dy / length;
        const ny = dx / length;
        const radius = track.width / 2;
        return @max(
            std.math.hypot(closest.x - nx * radius - via.at[0], closest.y - ny * radius - via.at[1]),
            std.math.hypot(closest.x + nx * radius - via.at[0], closest.y + ny * radius - via.at[1]),
        ) <= via.dia / 2 + join_slack_mm;
    }

    // The via is the narrower feature. At an interior closest point the radial
    // vector is normal to the track, so its perpendicular is the track tangent.
    // At an end-cap it is the exact diameter orientation that minimizes the
    // farther endpoint's distance to that cap. When centres coincide, the
    // track tangent is an equivalent deterministic witness.
    const rx = via.at[0] - closest.x;
    const ry = via.at[1] - closest.y;
    const radial = std.math.hypot(rx, ry);
    const ux = if (radial > 1e-12) -ry / radial else dx / length;
    const uy = if (radial > 1e-12) rx / radial else dy / length;
    const radius = via.dia / 2;
    return @max(
        pad_shape.segPointDist(
            track.a[0],
            track.a[1],
            track.b[0],
            track.b[1],
            via.at[0] - ux * radius,
            via.at[1] - uy * radius,
        ),
        pad_shape.segPointDist(
            track.a[0],
            track.a[1],
            track.b[0],
            track.b[1],
            via.at[0] + ux * radius,
            via.at[1] + uy * radius,
        ),
    ) <= track.width / 2 + join_slack_mm;
}

const CrossSectionSearch = struct {
    narrow0: [2]f64,
    narrow_delta: [2]f64,
    normal: [2]f64,
    radius: f64,
    wide0: [2]f64,
    wide1: [2]f64,

    fn coverage(self: CrossSectionSearch, t: f64) f64 {
        const cx = self.narrow0[0] + t * self.narrow_delta[0];
        const cy = self.narrow0[1] + t * self.narrow_delta[1];
        return @max(
            pad_shape.segPointDist(
                self.wide0[0],
                self.wide0[1],
                self.wide1[0],
                self.wide1[1],
                cx - self.normal[0] * self.radius,
                cy - self.normal[1] * self.radius,
            ),
            pad_shape.segPointDist(
                self.wide0[0],
                self.wide0[1],
                self.wide1[0],
                self.wide1[1],
                cx + self.normal[0] * self.radius,
                cy + self.normal[1] * self.radius,
            ),
        );
    }
};

fn directedTrackContact(narrow: Trace, wide: Trace) bool {
    const delta = [2]f64{ narrow.b[0] - narrow.a[0], narrow.b[1] - narrow.a[1] };
    const length = std.math.hypot(delta[0], delta[1]);
    if (length <= 1e-12) return false;
    const normal = [2]f64{ -delta[1] / length, delta[0] / length };
    const radius = narrow.width / 2;
    const limit = wide.width / 2 + join_slack_mm;
    const search = CrossSectionSearch{
        .narrow0 = narrow.a,
        .narrow_delta = delta,
        .normal = normal,
        .radius = radius,
        .wide0 = wide.a,
        .wide1 = wide.b,
    };

    var lo: f64 = 0;
    var hi: f64 = 1;
    // 56 iterations resolve far below a nanometre even on metre-long board
    // coordinates; the electrical decision itself deliberately stops at 1 µm.
    for (0..56) |_| {
        const left = (2 * lo + hi) / 3;
        const right = (lo + 2 * hi) / 3;
        const left_need = search.coverage(left);
        const right_need = search.coverage(right);
        if (left_need <= right_need)
            hi = right
        else
            lo = left;
    }
    const middle = (lo + hi) / 2;
    const need = @min(
        @min(search.coverage(0), search.coverage(1)),
        search.coverage(middle),
    );
    return need <= limit;
}

/// Do two traces share a fabrication-robust neck? The narrower trace is the
/// connection's bottleneck, so at least one COMPLETE transverse cross-section
/// of that trace must fit inside the other trace's round-capped copper.
///
/// A trace capsule is convex. Therefore a transverse chord lies wholly inside
/// it exactly when both chord endpoints do. The maximum endpoint distance to
/// the wider centreline is a convex one-dimensional function along the narrow
/// centreline; ternary minimization finds its global minimum. The ordinary
/// capsule test first rejects the overwhelmingly common far pairs. Equal-width
/// traces test both directions so the result cannot depend on storage order.
pub fn trackTrackConnects(a: Trace, b: Trace) bool {
    if (!trackTrackCapsulesOverlap(a, b)) return false;
    if (a.width < b.width) return directedTrackContact(a, b);
    if (b.width < a.width) return directedTrackContact(b, a);
    return directedTrackContact(a, b) or directedTrackContact(b, a);
}

test "contact policy keeps a 5 um gap open and classifies it as hairline" {
    const testing = @import("std").testing;
    try testing.expectEqual(GapClass.connected, classifyGap(0.0005));
    try testing.expectEqual(GapClass.hairline, classifyGap(0.005));
    try testing.expectEqual(GapClass.open, classifyGap(0.021));
}

test "SMD copper joins only its own face while through copper spans layers" {
    const testing = @import("std").testing;
    try testing.expect(padOnLayer(false, 0, 0));
    try testing.expect(!padOnLayer(false, 0, 1));
    try testing.expect(padOnLayer(true, 0, 5));
}

test "pad contact requires one complete trace-width cross-section on the land" {
    const testing = @import("std").testing;
    const land = pad_shape.Shape{ .x0 = 0, .y0 = -0.5, .x1 = 1, .y1 = 0.5 };
    const width = 0.25;

    // The 0.125 mm round end-cap overlaps the land by 1 µm, but the trace
    // centreline never enters it, so the shared copper is narrower than the
    // trace and cannot prove connectivity.
    try testing.expect(!padTrackConnects(land, .{ 2, 0 }, .{ 1.124, 0 }, width));
    try testing.expect(padTrackConnects(land, .{ 2, 0 }, .{ 1, 0 }, width));

    // When the land is narrower, its complete anchor chord is the bottleneck
    // and a centred wide trace carries it. A flank graze still does not.
    const narrow = pad_shape.Shape{ .x0 = 0, .y0 = -0.1, .x1 = 1, .y1 = 0.1 };
    try testing.expect(padTrackConnects(narrow, .{ 2, 0 }, .{ 0.5, 0 }, width));
    try testing.expect(!padTrackConnects(narrow, .{ 2, 0.2 }, .{ 0.5, 0.2 }, width));

    // A concave custom pad does not inherit copper from its bounding-box
    // notch. Entering the real right-hand prong by one full width does join.
    const concave = [_][2]f64{
        .{ 0, -0.5 }, .{ 0.4, -0.5 }, .{ 0.4, -0.1 }, .{ 1, -0.1 },
        .{ 1, 0.5 },  .{ 0.4, 0.5 },  .{ 0.4, 0.1 },  .{ 0, 0.1 },
    };
    const custom = pad_shape.Shape{ .x0 = 0, .y0 = -0.5, .x1 = 1, .y1 = 0.5, .poly = &concave };
    try testing.expect(!padTrackConnects(custom, .{ -1, 0.3 }, .{ 0.2, 0.3 }, width));
    try testing.expect(padTrackConnects(custom, .{ -1, 0.3 }, .{ 0.8, 0.3 }, width));
}

// spec: fab_readiness - track-to-track connectivity requires a full cross-section of the narrower trace inside the other trace; a cap-only or parallel-flank graze stays open
test "track contact requires a complete bottleneck cross-section" {
    const testing = @import("std").testing;
    const width = 0.2532;

    // Barracuda boost22/U23: these parallel segments overlap by 8.06 µm at
    // their flanks, but nowhere carries the trace's 0.2532 mm cross-section.
    const old = [2][2]f64{
        .{ 169.0087087130193, 107.95538566406091 },
        .{ 170.17672304895842, 109.1234 },
    };
    const weld = [2][2]f64{
        .{ 170.32, 108.92 },
        .{ 170.88, 109.48 },
    };
    const old_trace = Trace{ .a = old[0], .b = old[1], .width = width };
    const weld_trace = Trace{ .a = weld[0], .b = weld[1], .width = width };
    try testing.expect(trackTrackCapsulesOverlap(old_trace, weld_trace));
    try testing.expect(!trackTrackConnects(old_trace, weld_trace));
    try testing.expectEqual(
        trackTrackConnects(old_trace, weld_trace),
        trackTrackConnects(weld_trace, old_trace),
    );

    // Explicit endpoint, T, and crossing junctions all carry a full chord.
    try testing.expect(trackTrackConnects(
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .width = width },
        .{ .a = .{ 1, 0 }, .b = .{ 2, 0 }, .width = width },
    ));
    try testing.expect(trackTrackConnects(
        .{ .a = .{ -1, 0 }, .b = .{ 1, 0 }, .width = width },
        .{ .a = .{ 0, 0 }, .b = .{ 0, 1 }, .width = width },
    ));
    try testing.expect(trackTrackConnects(
        .{ .a = .{ -1, -1 }, .b = .{ 1, 1 }, .width = width },
        .{ .a = .{ -1, 1 }, .b = .{ 1, -1 }, .width = width },
    ));

    // A narrow trace may join a wider trunk while offset, but only while its
    // whole narrower chord remains inside the trunk.
    const trunk = Trace{ .a = .{ -1, 0 }, .b = .{ 1, 0 }, .width = 0.4 };
    try testing.expect(trackTrackConnects(
        .{ .a = .{ -1, 0.09 }, .b = .{ 1, 0.09 }, .width = 0.2 },
        trunk,
    ));
    try testing.expect(!trackTrackConnects(
        .{ .a = .{ -1, 0.11 }, .b = .{ 1, 0.11 }, .width = 0.2 },
        trunk,
    ));
}

// spec: fab_readiness - track-to-via connectivity requires a full cross-section of the narrower copper feature; a tangential land graze stays open
test "via contact requires a complete bottleneck cross-section" {
    const testing = @import("std").testing;
    const trace = Trace{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .width = 0.25 };
    const centred = Via{ .at = .{ 1, 0 }, .dia = 0.4 };
    try testing.expect(trackViaConnects(trace, centred));

    // Barracuda V_24V_CLEAN track 104 only clips the edge of via 4. Their
    // copper overlaps geometrically, but no 0.2532 mm trace chord fits inside
    // the 0.4 mm via land.
    const weak_trace = Trace{
        .a = .{ 139.8234, 96.65 },
        .b = .{ 140.45, 97.4 },
        .width = 0.2532,
    };
    const weak_via = Via{ .at = .{ 140.41680036354114, 97.72507713281217 }, .dia = 0.4 };
    try testing.expect(trackViaCopperOverlaps(weak_trace, weak_via));
    try testing.expect(!trackViaConnects(weak_trace, weak_via));

    // A wider trace uses the via diameter as its bottleneck. A nearby end-cap
    // may carry that complete diameter even when the track centreline does not
    // pass through the via centre.
    try testing.expect(trackViaConnects(
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .width = 0.5 },
        .{ .at = .{ 1, 0.1 }, .dia = 0.4 },
    ));
}
