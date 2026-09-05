//! RF bend discipline — post-route corner smoothing for `(max-freq …)` nets.
//!
//! An RF trace must not turn through sharp corners: the corner is an
//! impedance discontinuity (excess corner capacitance) and, at high
//! frequency, a radiator. The standard layout rule of thumb is a centerline
//! bend radius of at least 3x the trace width. A net opts in by belonging to
//! a `(net-class … (max-freq HZ))`; this pass then rebuilds the net's routed
//! polylines and replaces every corner it can with a tangent arc at that
//! radius. A RIGHT-ANGLE corner — the maze's staple and the harshest turn on
//! the trace — aims instead at the biggest arc its two legs can physically
//! host, which is free: a fillet only cuts inside its corner, so the copper
//! gets shorter, not longer. A corner too short for the symmetric fillet is
//! retried three ways before it is conceded: shrink the radius (and, if a
//! one-sided obstacle crowds the cut, below the floor to the largest clearing
//! chamfer); on a lopsided corner slide the arc unequally along the two legs
//! as a tangent biarc to route past that obstacle; and a starved same-sense
//! corner PAIR whose short shared leg (or escape-pinned outer legs) blocks
//! both bends is collapsed at the virtual apex so one bend opens against the
//! long outer legs. Corners that still miss the floor by more than 5% are
//! reported for the `sharp_bend` DRC check, with the marker placed ON the final
//! copper (an under-floor arc's midpoint / a biarc's join; the bare vertex only
//! when the corner stayed truly sharp). Preserved (stamped reference) copper is
//! never reshaped, and the straight pad-escape reserve is always honoured.
//!
//! The clearance probe also carries the board outline (when one is on the
//! placement), so an arc — or the outer-leg copper a corner-pair merge
//! extends toward its virtual apex — that would cross the board edge is
//! rejected just like one crowding foreign copper. The maze already routes
//! inside the edge; this keeps the post-route smoothing from bulging a curve
//! back out past it.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const pad_shape = @import("pad_shape.zig");
const outline = @import("outline.zig");
const numeric = @import("../numeric.zig");

/// Radius slack in board millimetres when a measured arc radius is compared
/// against a floor. Distinct from `eps` above, which is this module's
/// degenerate-length guard.
const radius_eps_mm: f64 = 1e-6;

/// The RF rule of thumb: DEFAULT minimum centerline bend radius = 3x trace
/// width. A `(net-class … (min-bend-radius N))` overrides this floor per net
/// (see `floorRatio`).
pub const radius_width_ratio: f64 = 3.0;
/// Radius the smoother AIMS for: the largest arc that fits the corner's legs
/// and clearance, capped at 5x the trace width. Beyond ~5W the return-loss
/// improvement is negligible while the corner cut keeps growing (hurting
/// length matching), so the cap keeps generous bends without noodling. A
/// `(min-bend-radius N)` above this cap lifts the aim to N (see `aimRatio`) —
/// otherwise the smoother could never reach the floor it must satisfy.
const max_radius_width_ratio: f64 = 5.0;

/// A RIGHT-ANGLE corner is the exception to that cap: a square turn is the
/// harshest discontinuity a routed RF trace carries, so it aims at the largest
/// arc its two legs can physically host (`legMaxClaim`) instead of a width
/// multiple. A fillet only ever cuts INSIDE its corner, so opening one up
/// SHORTENS the copper rather than lengthening it, and a cut that crowds
/// anything still walks back down the same ladder to the same floor.
///
/// This constant is how far (radians, ~3°) a corner may sit off a true quarter
/// turn and still count as one. The maze turns on a lattice, so the tolerance
/// only has to absorb the direction rounding of finite-precision endpoints; it
/// stays far clear of the neighbouring 45° and 135° lattice turns, which keep
/// the width-multiple aim exactly as before.
const right_angle_tol: f64 = 0.05;

const eps = 1e-9;
/// Endpoint-matching quantum (mm) when rebuilding polylines from segments.
const snap = 1e-4;
/// Corners flatter than this deflection (radians) are left alone — the kink
/// is invisible at copper scale and a tangent arc is numerically fragile.
const min_deflection = 0.03;
/// Corners tighter than this (near U-turn) are never smoothed — the tangent
/// length diverges; they are flagged sharp instead.
const max_deflection = 2.8;
/// Smallest tangent trim worth an arc; below this the corner stays sharp.
const min_tangent = 1e-3;
/// Deflection (radians, ~29 degrees) below which a corner too starved to
/// reach the floor radius is treated as a shallow kink (pad-entry stub
/// quantization, an escape-reserve pin) rather than a real sharp bend: it
/// gets no arc but no sharp_bend flag either.
const shallow_kink_max = 0.5;
/// The sagitta every copper EMITTER tessellates a smoothed arc at, and
/// therefore the only resolution an acceptance probe may judge one at.
///
/// A board carries chords, never arcs: `router.smoothNetInline`,
/// `straighten.rearcTautNet` and the viewer all draw `tessellate(arc, this)`.
/// A chord cuts across the CONCAVE side of its arc — toward whatever crowds the
/// corner — so copper drawn at this resolution sits up to one sagitta closer to
/// an obstacle than the ideal circle does. Probing the circle (or a FINER chord
/// walk) therefore measures metal that is never fabricated, and admits copper
/// the exact DRC then refuses by up to `emit_sagitta_mm`.
///
/// Measured on barracuda (2026-08-18): `adf4159/ADF_FB_RF_AC`'s smoothed corner
/// came out as R = 0.369 mm chords sweeping 22.3° apiece — a 7.0 µm sagitta —
/// and one of them passed 0.2175 mm from `adf4159/U19` pad 4, a gap of 0.1258
/// against the 0.127 rule. The circle through that chord's midpoint clears by
/// exactly the sagitta, which is why every probe said yes and the gate then
/// dropped the whole net as its DRC victim.
///
/// One constant, used by the emitters AND by both probes, is what keeps
/// "what was judged" and "what is drawn" the same polyline.
pub const emit_sagitta_mm: f64 = 0.01;

/// Minimum centerline bend radius (the compliance floor + sharp_bend flag
/// threshold) for one net: `floorRatio` × its effective trace width when its
/// winning class declares `(max-freq …)`, else 0 (unconstrained).
pub fn minBendRadius(rule: ?optimizer.NetRule, default_track_width: f64) f64 {
    const r = rule orelse return 0;
    if (r.rf.max_freq_hz <= 0) return 0;
    const width = if (r.width > 0) r.width else default_track_width;
    return floorRatio(r) * width;
}

/// The net's floor multiplier: its class's `(min-bend-radius N)` when declared
/// (>0), else the 3× rule-of-thumb default.
fn floorRatio(r: optimizer.NetRule) f64 {
    return if (r.rf.min_bend_ratio > 0) r.rf.min_bend_ratio else radius_width_ratio;
}

/// The width multiple the smoother AIMS for: the 5× cap, but never below the
/// net's floor — a `(min-bend-radius N)` above the cap raises the aim to N so
/// a compliant corner is reachable at all.
fn aimRatio(r: optimizer.NetRule) f64 {
    return @max(max_radius_width_ratio, floorRatio(r));
}

/// Does this corner turn a square corner — and so aim at the geometric maximum
/// its legs allow instead of `aimRatio` x width (see `right_angle_tol`)?
fn isRightAngle(defl: f64) bool {
    return @abs(defl - std.math.pi / 2.0) <= right_angle_tol;
}

/// The smoothing outcome: replacement copper plus the under-radius report.
pub const Result = struct {
    /// Full replacement track list (constrained nets trimmed to tangent
    /// points; everything else passed through verbatim).
    tracks: []const router.Track,
    arcs: []const router.Arc,
    sharp: []const router.SharpBend,
    /// False when no net is bend-constrained — callers keep their own list.
    changed: bool,
};

/// A router-side clearance oracle handed to the smoother, TYPE-ERASED so
/// `GeomProbe` stays a plain struct and this module keeps no dependency on the
/// router's `Ctx`. `handle` is the borrowed probe value's address (it must
/// outlive the smoothing call) and `clearFn` its straight-segment test —
/// `router.TautProbe.clear`, which judges pads, vias, tracks, keepout halos,
/// blocking zones, the RF crossing shadow AND the board outline.
///
/// It is a SUPPLEMENT to `GeomProbe`, never a replacement: the geometric probe
/// runs first (it is cheap and rejects most candidates), and only copper it
/// already likes is offered here. `net` is the net the oracle is aimed at —
/// same-net copper is free to it, so a group of any OTHER net must not be
/// judged through it and is silently exempt.
pub const ExtProbe = struct {
    /// Alignment the erased handle carries. Declared here — rather than
    /// recovered with an unchecked `@alignCast` on the way back out — so a
    /// probe type that could not satisfy it is a COMPILE error at its `bind`
    /// call instead of an assumption the cast makes at run time.
    const handle_align = @alignOf(*const anyopaque);

    handle: *align(handle_align) const anyopaque,
    net: i32,
    clearFn: *const fn (*align(handle_align) const anyopaque, u8, [2]f64, [2]f64) bool,

    /// Bind `probe` — a pointer to a `P` answering `clear(layer, a, b) bool` —
    /// as `net`'s oracle. The pointer is borrowed, so the value it names must
    /// outlive the smoothing call; every caller keeps it as a local in the same
    /// frame that calls `apply`.
    pub fn bind(comptime P: type, probe: *const P, net: i32) ExtProbe {
        const shim = struct {
            fn call(handle: *align(handle_align) const anyopaque, layer: u8, a: [2]f64, b: [2]f64) bool {
                const p: *const P = @ptrCast(handle);
                return p.clear(layer, a, b);
            }
        };
        return .{ .handle = probe, .net = net, .clearFn = shim.call };
    }

    fn clear(self: ExtProbe, layer: u8, a: [2]f64, b: [2]f64) bool {
        return self.clearFn(self.handle, layer, a, b);
    }
};

/// The smoothing input: the solved placement (net rules), the router's
/// default geometry, the routed copper, and the preserved prefix.
pub const Input = struct {
    placement: optimizer.Placement,
    params: router.RouteParams,
    tracks: []const router.Track,
    /// Routed vias — obstacles the clearance probe checks candidate arcs
    /// against (an arc's cut may not crowd a foreign via).
    vias: []const router.Via = &.{},
    /// `tracks[0..keep]` (preserved reference copper) pass through untouched.
    keep: usize = 0,
    /// The router's own clearance oracle, when the caller has one. Null (the
    /// standalone / unit-test path) leaves `GeomProbe` alone — it then sees
    /// tracks, vias, pads and the outline only, which is every obstacle a
    /// board built by hand from an `Input` carries anyway.
    ext: ?ExtProbe = null,
    /// Measure, never reshape: report the under-radius corners of the
    /// constrained copper and leave every track exactly where it is. The
    /// answer for copper some other stage owns the shape of — a coupled
    /// diff-pair leg, whose two halves may only move together.
    detect_only: bool = false,
};

/// Smooth the routed corners of every bend-constrained net. Each candidate
/// arc leaves the maze-verified path, so it is geometrically probed against
/// every foreign track, via, and pad with real clearances first — a corner
/// whose cut would crowd anything stays sharp and is flagged instead.
pub fn apply(arena: std.mem.Allocator, in: Input) std.mem.Allocator.Error!Result {
    const placement = in.placement;
    const tracks = in.tracks;
    const radii = try arena.alloc(f64, placement.nets.len);
    const escapes = try arena.alloc(f64, placement.nets.len);
    const aims = try arena.alloc(f64, placement.nets.len);
    var any = false;
    for (radii, escapes, aims, 0..) |*r, *esc, *aim, ni| {
        const rule: ?optimizer.NetRule =
            if (ni < placement.rules.net.len) placement.rules.net[ni] else null;
        r.* = minBendRadius(rule, in.params.track_width);
        esc.* = if (rule) |nr| nr.rf.escape_mm else 0;
        aim.* = if (rule) |nr| aimRatio(nr) else max_radius_width_ratio;
        any = any or r.* > 0;
    }
    const kept = @min(in.keep, tracks.len);
    if (!any or tracks.len == kept)
        return .{ .tracks = tracks, .arcs = &.{}, .sharp = &.{}, .changed = false };

    var out: std.ArrayList(router.Track) = .empty;
    var arcs: std.ArrayList(router.Arc) = .empty;
    var sharp: std.ArrayList(router.SharpBend) = .empty;
    try out.appendSlice(arena, tracks[0..kept]);
    var sink = Sink{ .arena = arena, .out = &out, .arcs = &arcs, .sharp = &sharp };

    // Group the freshly routed tracks of constrained nets by (net, layer);
    // everything else passes through.
    var groups = std.AutoHashMapUnmanaged([2]i32, std.ArrayList(router.Track)).empty;
    for (tracks[kept..]) |t| {
        const constrained = t.net >= 0 and t.net < radii.len and radii[@intCast(t.net)] > 0;
        if (!constrained or segLen(t) < eps) {
            try out.append(arena, t);
            continue;
        }
        const slot = try groups.getOrPut(arena, .{ t.net, t.layer });
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(arena, t);
    }
    const probe = try GeomProbe.build(arena, in);
    const worker = Smoother{ .sink = &sink, .probe = probe };
    var it = groups.iterator();
    while (it.next()) |entry| {
        const info = GroupInfo{
            .net = entry.key_ptr.*[0],
            .layer = @intCast(entry.key_ptr.*[1]),
            .radius = radii[@intCast(entry.key_ptr.*[0])],
            .escape = escapes[@intCast(entry.key_ptr.*[0])],
            .aim_ratio = aims[@intCast(entry.key_ptr.*[0])],
        };
        if (in.detect_only)
            try worker.auditGroup(entry.value_ptr.items, info)
        else
            try worker.smoothGroup(entry.value_ptr.items, info);
    }
    // Detect-only reshaped nothing, so the caller keeps the copper it handed
    // in (`changed = false`) and takes only the report.
    if (in.detect_only) return .{
        .tracks = tracks,
        .arcs = &.{},
        .sharp = try sharp.toOwnedSlice(arena),
        .changed = false,
    };
    return .{
        .tracks = try out.toOwnedSlice(arena),
        .arcs = try arcs.toOwnedSlice(arena),
        .sharp = try sharp.toOwnedSlice(arena),
        .changed = true,
    };
}

/// MEASURE the bend discipline of `in.tracks[in.keep..]` without touching a
/// single track: every corner of a bend-constrained net that turns sharper than
/// its floor radius comes back as a `SharpBend`, and no copper moves.
///
/// This is the answer for copper whose shape belongs to another stage — a
/// coupled diff-pair leg, which may only be reshaped in lock-step with its twin
/// or the pair's skew equalization is destroyed. Smoothing such a leg alone is
/// wrong; staying silent about its raw mitred corners is also wrong, because
/// `sharp_bend` DRC reports exactly what this pass records and nothing else. So
/// the corners are reported and the copper is left for the pair to own.
pub fn detect(arena: std.mem.Allocator, in: Input) std.mem.Allocator.Error![]const router.SharpBend {
    var measured = in;
    measured.detect_only = true;
    const res = try apply(arena, measured);
    return res.sharp;
}

/// Output collectors threaded through the smoothing helpers.
const Sink = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList(router.Track),
    arcs: *std.ArrayList(router.Arc),
    sharp: *std.ArrayList(router.SharpBend),
};

/// One (net, layer) group's identity plus its required bend radius (the floor),
/// the aim radius as a width multiple, and the straight pad-escape reserve (mm)
/// arcs must stay clear of.
const GroupInfo = struct {
    net: i32,
    layer: u8,
    radius: f64,
    escape: f64 = 0,
    aim_ratio: f64 = max_radius_width_ratio,
};

/// One polyline of a net on one layer: ordered vertices plus each leg's width.
/// Public because `extractChains` is the shared segment-soup → polyline
/// rebuilder: the RF bend smoother reads it to place arcs, and `via_fence`
/// reads it to march a stitching row along the same centreline.
pub const Chain = struct {
    pts: [][2]f64,
    widths: []f64,
};

/// A foreign pad as its world axis-aligned bounding box on one layer, from
/// `pad_shape.worldShape` — so the part pose AND the pad's own `(pos … ROT)`
/// rotation (plus custom-polygon outlines) shape the box, exactly like the
/// maze obstacles and DRC. Quarter turns stay exact; arbitrary angles and
/// polygons use the conservative world bbox.
const PadBox = struct { x0: f64, y0: f64, x1: f64, y1: f64, net: i32, layer: u8, thru: bool };

/// Geometric arc-acceptance probe: a candidate arc is accepted only when
/// every sampled point along it keeps clearance to all foreign tracks, vias,
/// and pads AND stays the copper-edge rule inside the board outline. Point
/// sampling is sagitta-safe — the required distance is inflated by half the
/// sample spacing so nothing threads between samples.
///
/// Tracks/vias/pads/outline are all it can see on its own, which is enough for
/// a board assembled from an `Input` but NOT for one the router is live on: a
/// blocking zone, a declared keepout halo and the RF crossing shadow are all
/// invisible here. So when the caller has the router's own oracle it hands one
/// over as `Input.ext` and every candidate must clear BOTH — otherwise an
/// accepted arc could cross a keepout every other probe in the system refuses.
const GeomProbe = struct {
    tracks: []const router.Track,
    vias: []const router.Via,
    pads: []const PadBox,
    clearance: []const f64,
    base_clearance: f64,
    /// Board outline from the placement — the arc must keep `edge_clearance`
    /// of copper-edge inset from it. Null (no authored/drawn outline) ⇒ no
    /// edge constraint, exactly like the board-edge DRC.
    board_rect: ?optimizer.BoardRect,
    board_poly: ?[]const [2]f64,
    edge_clearance: f64,
    /// The router's oracle for the net being smoothed, when the caller is the
    /// router. Consulted AFTER the geometry above clears.
    ext: ?ExtProbe = null,

    fn build(arena: std.mem.Allocator, in: Input) std.mem.Allocator.Error!GeomProbe {
        const placement = in.placement;
        // Pad net lookup: the same ref|pin bridge the render surfaces use.
        var pin_net = std.StringHashMapUnmanaged(i32).empty;
        for (placement.nets, 0..) |net, net_i| for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(arena, key, @intCast(net_i));
        };
        var pads: std.ArrayList(PadBox) = .empty;
        for (placement.parts) |part| {
            for (part.pads) |pad| {
                const sh = try pad_shape.worldShape(arena, part, pad);
                const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
                try pads.append(arena, .{
                    .x0 = sh.x0,
                    .y0 = sh.y0,
                    .x1 = sh.x1,
                    .y1 = sh.y1,
                    .net = pin_net.get(key) orelse -1,
                    .layer = if (part.side == .bottom) 1 else 0,
                    .thru = pad.thru,
                });
            }
        }
        const clearance = try arena.alloc(f64, placement.nets.len);
        for (clearance, 0..) |*c, ni| {
            const nr: ?optimizer.NetRule =
                if (ni < placement.rules.net.len) placement.rules.net[ni] else null;
            c.* = if (nr != null and nr.?.clearance > 0) nr.?.clearance else in.params.clearance;
        }
        return .{
            .tracks = in.tracks,
            .vias = in.vias,
            .pads = pads.items,
            .clearance = clearance,
            .base_clearance = in.params.clearance,
            .board_rect = placement.board_rect,
            .board_poly = placement.board_poly,
            .edge_clearance = placement.rules.design.edgeClearance(),
            .ext = in.ext,
        };
    }

    /// The router oracle's verdict on the straight run a→b drawn as `ref`'s
    /// copper. True (no objection) when the caller handed no oracle over, or
    /// when it is aimed at a different net than the copper being judged —
    /// same-net metal is free to it, so a foreign group would be judged wrong.
    fn extClear(self: GeomProbe, ref: CopperRef, a: [2]f64, b: [2]f64) bool {
        const e = self.ext orelse return true;
        if (e.net != ref.net) return true;
        return e.clear(ref.layer, a, b);
    }

    /// The router oracle's verdict on a whole arc, walked as EXACTLY the chords
    /// the emitters will draw it as (`emit_sagitta_mm`). Each chord is a real
    /// segment query, so this is not a sampling of the arc at all — it is the
    /// finished copper, asked about once per segment.
    fn extClearArc(self: GeomProbe, arc: router.Arc) bool {
        const e = self.ext orelse return true;
        if (e.net != arc.net) return true;
        const c = circleOf(arc) orelse return true;
        const count = chordCount(c, emit_sagitta_mm);
        var prev = chordVertex(c, arc, count, 0);
        for (1..count + 1) |k| {
            const pt = chordVertex(c, arc, count, k);
            if (!e.clear(arc.layer, prev, pt)) return false;
            prev = pt;
        }
        return true;
    }

    /// True when `pt` lies on (or within a hair of) a same-net pad reachable
    /// from the group's layer — the "this chain end is a pad exit" test the
    /// escape reserve keys on.
    fn onPad(self: GeomProbe, pt: [2]f64, info: GroupInfo) bool {
        for (self.pads) |pad| {
            if (pad.net != info.net) continue;
            if (!pad.thru and pad.layer != info.layer) continue;
            if (pt[0] >= pad.x0 - snap and pt[0] <= pad.x1 + snap and
                pt[1] >= pad.y0 - snap and pt[1] <= pad.y1 + snap) return true;
        }
        return false;
    }

    fn clearanceOf(self: GeomProbe, net: i32) f64 {
        if (net >= 0 and net < self.clearance.len) return self.clearance[@intCast(net)];
        return self.base_clearance;
    }

    /// True when the arc's swept copper keeps clearance to all foreign copper —
    /// the geometry this probe holds first, then the router's own oracle when
    /// the caller handed one over (`extClearArc`), so an arc admitted here is
    /// one every other clearance surface in the system would also admit.
    fn clear(self: GeomProbe, arc: router.Arc) bool {
        return self.geomClear(arc) and self.extClearArc(arc);
    }

    /// The geometric half of `clear`: foreign tracks, vias, pads, board edge.
    ///
    /// Sampled along the CHORD POLYLINE the emitters draw, not along the ideal
    /// circle. The two differ by up to `emit_sagitta_mm` on the concave side —
    /// the side an obstacle crowding the corner is on — and it is the chords
    /// that get fabricated (see `emit_sagitta_mm` for the barracuda case this
    /// cost). Sampling stays fine enough that the Lipschitz slack (half the
    /// inter-sample spacing) is near a hundredth of the clearance, so a legal
    /// bend is never vetoed by sampling coarseness.
    fn geomClear(self: GeomProbe, arc: router.Arc) bool {
        const c = circleOf(arc) orelse return true;
        const chords = chordCount(c, emit_sagitta_mm);
        const step: f64 = 0.03; // radians between samples
        const by_angle = @max(2.0, @ceil(@abs(c.sweep) / step));
        const count: usize = @intFromFloat(@min(@max(by_angle, @as(f64, @floatFromInt(chords))), 160));
        const halfstep = c.r * @abs(c.sweep) / @as(f64, @floatFromInt(count)) / 2.0;
        for (0..count + 1) |k| {
            const pt = polylinePoint(c, arc, chords, @as(f64, @floatFromInt(k)) /
                @as(f64, @floatFromInt(count)));
            if (!self.pointClear(pt[0], pt[1], arc, halfstep)) return false;
        }
        return true;
    }

    fn pointClear(self: GeomProbe, px: f64, py: f64, arc: router.Arc, slack: f64) bool {
        return self.pointClearRef(.{ px, py }, .{ .net = arc.net, .layer = arc.layer, .width = arc.width }, slack);
    }

    fn pointClearRef(self: GeomProbe, pt: [2]f64, ref: CopperRef, slack: f64) bool {
        const own_clr = self.clearanceOf(ref.net);
        for (self.tracks) |t| {
            if (t.net == ref.net or t.layer != ref.layer) continue;
            const need = ref.width / 2.0 + t.width / 2.0 +
                @max(own_clr, self.clearanceOf(t.net)) + slack;
            if (pointSegDist(pt[0], pt[1], t) < need) return false;
        }
        for (self.vias) |v| {
            if (v.net == ref.net) continue;
            const need = ref.width / 2.0 + v.dia / 2.0 +
                @max(own_clr, self.clearanceOf(v.net)) + slack;
            if (std.math.hypot(pt[0] - v.x, pt[1] - v.y) < need) return false;
        }
        for (self.pads) |pad| {
            if (pad.net == ref.net) continue;
            if (!pad.thru and pad.layer != ref.layer) continue;
            const need = ref.width / 2.0 +
                @max(own_clr, self.clearanceOf(pad.net)) + slack;
            const dx = @max(0, @max(pad.x0 - pt[0], pt[0] - pad.x1));
            const dy = @max(0, @max(pad.y0 - pt[1], pt[1] - pad.y1));
            if (std.math.hypot(dx, dy) < need) return false;
        }
        return self.edgeClear(pt, ref, slack);
    }

    /// Board edge: the point's copper edge (inset minus half-width) must stay
    /// `edge_clearance` inside the outline. Reducing the available inset by
    /// `slack` mirrors the foreign-copper conservatism (nothing threads between
    /// samples). No outline on the placement ⇒ no edge constraint.
    fn edgeClear(self: GeomProbe, pt: [2]f64, ref: CopperRef, slack: f64) bool {
        const inset = self.boardInset(pt[0], pt[1]) orelse return true;
        return inset - ref.width / 2.0 - slack >= self.edge_clearance;
    }

    /// Signed inset of (x,y) from the board outline (positive = inside), or
    /// null when the placement carries no outline. Exact polygon when a shape
    /// was authored/drawn, else the bounding rectangle — the same board-edge
    /// geometry `drc.checkBoardEdge` measures against.
    fn boardInset(self: GeomProbe, x: f64, y: f64) ?f64 {
        if (self.board_poly) |p| {
            if (p.len >= 3) return outline.signedInset(p, x, y);
        }
        const br = self.board_rect orelse return null;
        const dl = x - br.minx;
        const dr = br.minx + br.w - x;
        const dt = y - br.miny;
        const db = br.miny + br.h - y;
        return @min(@min(dl, dr), @min(dt, db));
    }

    /// True when the straight segment `a`→`b` (of the given copper `ref`) keeps
    /// clearance to all foreign copper. Used to vet the new outer-leg copper a
    /// corner-pair merge extends toward the virtual apex, and every collapse the
    /// chain simplifier proposes — copper the maze never verified, so it must be
    /// probed (here AND by the router's oracle) before it is accepted.
    fn segmentClear(self: GeomProbe, a: [2]f64, b: [2]f64, ref: CopperRef) bool {
        return self.geomSegmentClear(a, b, ref) and self.extClear(ref, a, b);
    }

    /// The geometric half of `segmentClear`: foreign tracks, vias, pads, edge.
    fn geomSegmentClear(self: GeomProbe, a: [2]f64, b: [2]f64, ref: CopperRef) bool {
        const len = dist(a, b);
        const count: usize = @intFromFloat(@min(@max(@ceil(len / 0.05), 2.0), 160));
        const half = len / @as(f64, @floatFromInt(count)) / 2.0;
        // Nothing foreign in reach ⇒ only the board edge can still veto, and
        // that walk costs no obstacle scan at all.
        const edge_only = self.farFromEverything(a, b, ref, half);
        for (0..count + 1) |k| {
            const f = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
            const pt = [2]f64{ a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f };
            const ok = if (edge_only) self.edgeClear(pt, ref, half) else self.pointClearRef(pt, ref, half);
            if (!ok) return false;
        }
        return true;
    }

    /// True when no foreign track, via or pad reaches the segment's bounding
    /// box — so no sample along it can be crowded by one, and the sampled walk
    /// only has to answer the board edge. Result-identical (a box that misses
    /// by `need` cannot hold a point closer than `need`), and it turns the probe
    /// from O(samples × obstacles) into O(obstacles) for copper in open space.
    /// That matters because the chain simplifier probes once per LEG, and an
    /// arc's chord tessellation makes those legs both numerous and sub-width —
    /// each was paying a board-wide scan per 0.05 mm sample.
    fn farFromEverything(self: GeomProbe, a: [2]f64, b: [2]f64, ref: CopperRef, slack: f64) bool {
        const seg = [4]f64{ @min(a[0], b[0]), @min(a[1], b[1]), @max(a[0], b[0]), @max(a[1], b[1]) };
        const own_clr = self.clearanceOf(ref.net);
        for (self.tracks) |t| {
            if (t.net == ref.net or t.layer != ref.layer) continue;
            const need = ref.width / 2.0 + t.width / 2.0 + @max(own_clr, self.clearanceOf(t.net)) + slack;
            const box = [4]f64{ @min(t.x1, t.x2), @min(t.y1, t.y2), @max(t.x1, t.x2), @max(t.y1, t.y2) };
            if (boxesReach(seg, box, need)) return false;
        }
        for (self.vias) |v| {
            if (v.net == ref.net) continue;
            const need = ref.width / 2.0 + v.dia / 2.0 + @max(own_clr, self.clearanceOf(v.net)) + slack;
            if (boxesReach(seg, .{ v.x, v.y, v.x, v.y }, need)) return false;
        }
        for (self.pads) |pad| {
            if (pad.net == ref.net) continue;
            if (!pad.thru and pad.layer != ref.layer) continue;
            const need = ref.width / 2.0 + @max(own_clr, self.clearanceOf(pad.net)) + slack;
            if (boxesReach(seg, .{ pad.x0, pad.y0, pad.x1, pad.y1 }, need)) return false;
        }
        return true;
    }
};

/// Do two axis-aligned boxes (each `{x0, y0, x1, y1}`) come within `gap`?
fn boxesReach(a: [4]f64, b: [4]f64, gap: f64) bool {
    const x_apart = a[0] - gap > b[2] or b[0] - gap > a[2];
    const y_apart = a[1] - gap > b[3] or b[1] - gap > a[3];
    return !x_apart and !y_apart;
}

/// Copper attributes (net, layer, width) a clearance query carries.
const CopperRef = struct { net: i32, layer: u8, width: f64 };

fn pointSegDist(px: f64, py: f64, t: router.Track) f64 {
    const dx = t.x2 - t.x1;
    const dy = t.y2 - t.y1;
    const len2 = dx * dx + dy * dy;
    if (len2 < eps) return std.math.hypot(px - t.x1, py - t.y1);
    const u = std.math.clamp(((px - t.x1) * dx + (py - t.y1) * dy) / len2, 0, 1);
    return std.math.hypot(px - (t.x1 + u * dx), py - (t.y1 + u * dy));
}

/// The corner-smoothing worker: geometry plus the clearance probe.
const Smoother = struct {
    const Self = @This();
    sink: *Sink,
    probe: GeomProbe,

    fn smoothGroup(self: Self, segs: []const router.Track, info: GroupInfo) std.mem.Allocator.Error!void {
        const chains = try extractChains(self.sink.arena, segs);
        for (chains) |chain| try self.smoothChain(chain, info);
    }

    /// `simplifyChain`'s clearance seam for this group: the group's own copper
    /// reference (widest leg, so the probe judges the whole chain at its
    /// thickest) bound to the smoother's board probe.
    const ChainProbe = struct {
        probe: GeomProbe,
        ref: CopperRef,

        /// True when the straight run a→b, drawn as this group's copper, keeps
        /// clearance from every foreign track, via, pad and the board edge.
        fn segClear(self: ChainProbe, a: [2]f64, b: [2]f64) bool {
            return self.probe.segmentClear(a, b, self.ref);
        }
    };

    /// This group's `simplifyChain` seam: the chain judged at its widest leg,
    /// so the probe answers for the thickest copper anywhere along it.
    fn chainProbe(self: Self, raw: Chain, info: GroupInfo) ChainProbe {
        var chain_w: f64 = 0;
        for (raw.widths) |w| chain_w = @max(chain_w, w);
        return .{
            .probe = self.probe,
            .ref = .{ .net = info.net, .layer = info.layer, .width = chain_w },
        };
    }

    /// Detect-only twin of `smoothGroup`: measure this group's corners, report
    /// the ones under the net's floor radius, and reshape nothing.
    fn auditGroup(self: Self, segs: []const router.Track, info: GroupInfo) std.mem.Allocator.Error!void {
        const chains = try extractChains(self.sink.arena, segs);
        for (chains) |chain| try self.auditChain(chain, info);
    }

    /// One chain's under-radius corners. Persisted arcs come back as tessellated
    /// track chords, so a same-sense run of turns is fitted to its circle and
    /// judged by that achieved radius. Everything else is raw copper: after
    /// `simplifyChain` folds away sub-width lattice jitter, a vertex turning
    /// less than `shallow_kink_max` is treated as vertex noise — exactly the
    /// exemption `smoothCorner` applies when it ends up placing no arc at all.
    fn auditChain(self: Self, raw: Chain, info: GroupInfo) std.mem.Allocator.Error!void {
        const arena = self.sink.arena;
        const chain = try simplifyChain(arena, raw, self.chainProbe(raw, info));
        const p = chain.pts;
        if (p.len < 3) return;
        const defl = try arena.alloc(f64, p.len);
        const turn = try arena.alloc(f64, p.len);
        @memset(defl, 0);
        @memset(turn, 0);
        for (1..p.len - 1) |i| {
            const u = unit(p[i - 1], p[i]) orelse continue;
            const v = unit(p[i], p[i + 1]) orelse continue;
            const dot = std.math.clamp(u[0] * v[0] + u[1] * v[1], -1.0, 1.0);
            defl[i] = std.math.acos(dot);
            turn[i] = u[0] * v[1] - u[1] * v[0];
        }
        const want = try arena.alloc(f64, p.len);
        @memset(want, 0);
        var i: usize = 1;
        while (i + 1 < p.len) {
            if (defl[i] < min_deflection) {
                i += 1;
                continue;
            }
            const sense: f64 = if (turn[i] >= 0) 1 else -1;
            var end = i;
            while (end + 2 < p.len and defl[end + 1] >= min_deflection and turn[end + 1] * sense > 0)
                end += 1;
            if (end >= i + 2) {
                if (circularRunRadius(chain, i, end)) |radius| {
                    if (radius + radius_eps_mm < 0.95 * info.radius)
                        try appendMeasuredSharp(self.sink, info, p[(i + end) / 2], radius);
                    i = end + 1;
                    continue;
                }
            }
            if (defl[i] < shallow_kink_max) {
                i += 1;
                continue;
            }
            const corner = Corner{ .chain = chain, .defl = defl, .want = want, .i = i, .info = info };
            try flagSharp(self.sink, corner, 0, null);
            i += 1;
        }
    }

    fn smoothChain(self: Self, raw: Chain, info: GroupInfo) std.mem.Allocator.Error!void {
        const sink = self.sink;
        const arena = sink.arena;
        const simplified = try simplifyChain(arena, raw, self.chainProbe(raw, info));
        // Collapse a starved same-sense corner PAIR (a Z-jog whose shared leg
        // is too short — or whose outer legs are escape-pinned — for either
        // bend to reach the floor) into a single corner at the virtual apex, so
        // the merged bend can open against the long outer legs instead.
        const chain = try self.mergeZigzags(simplified, info);
        const p = chain.pts;
        const n = p.len;
        if (n < 3) {
            try emitLegs(sink, chain, null, info);
            return;
        }
        // Pass 1: which interior vertices actually turn.
        const defl = try arena.alloc(f64, n);
        @memset(defl, 0);
        for (1..n - 1) |i| {
            const u = unit(p[i - 1], p[i]) orelse continue;
            const v = unit(p[i], p[i + 1]) orelse continue;
            const dot = std.math.clamp(u[0] * v[0] + u[1] * v[1], -1.0, 1.0);
            defl[i] = std.math.acos(dot);
        }
        // Pass 2: each corner's desired tangent trim — the LARGEST arc worth
        // having (capped at info.aim_ratio x width — normally the 5x cap, but
        // lifted to a `(min-bend-radius N)` floor above it; the minimum radius
        // is only the compliance floor). A leg shared by two corners is then
        // split in proportion to their wants, so consecutive bends (a Z-jog)
        // both smooth instead of the first starving the second.
        //
        // A square corner aims past its want at whatever its legs can host, but
        // this array stays its WEIGHT in that proportional split: a neighbour is
        // entitled to exactly the share it always had, and the square corner
        // takes only what the neighbour leaves (`smoothCorner`, `legMaxClaim`).
        const want = try arena.alloc(f64, n);
        @memset(want, 0);
        for (1..n - 1) |i| {
            if (defl[i] < min_deflection or defl[i] > max_deflection) continue;
            const width = @min(chain.widths[i - 1], chain.widths[i]);
            want[i] = info.aim_ratio * width * std.math.tan(defl[i] / 2.0);
        }
        // Pass 3: smooth each corner within its fair share of its legs.
        const nlegs = n - 1;
        const trim_s = try arena.alloc(f64, nlegs);
        const trim_e = try arena.alloc(f64, nlegs);
        @memset(trim_s, 0);
        @memset(trim_e, 0);
        const esc = try self.escapeOf(chain, info);
        for (1..n - 1) |i| {
            if (defl[i] < min_deflection) continue;
            const corner = Corner{ .chain = chain, .defl = defl, .want = want, .i = i, .info = info, .esc = esc };
            try self.smoothCorner(corner, .{ .s = trim_s, .e = trim_e });
        }
        try emitLegs(sink, chain, .{ .s = trim_s, .e = trim_e }, info);
    }

    /// Merge a starved same-sense adjacent corner PAIR into one corner at the
    /// virtual apex (the intersection of the two OUTER leg lines), skipping the
    /// short shared leg between them. A Z-jog whose shared leg is too short for
    /// two floor-radius fillets — or whose outer legs are escape-pinned so
    /// neither bend can round (the LO1_DRIVE mixer-drive case) — becomes a
    /// single bend that opens against the long outer legs and reaches the floor.
    /// The merge is accepted only when the resulting fillet reaches near the
    /// floor AND its arc plus the two extended outer legs (new copper the maze
    /// never verified) all clear the probe. Runs to a fixed point.
    fn mergeZigzags(self: Self, start: Chain, info: GroupInfo) std.mem.Allocator.Error!Chain {
        const arena = self.sink.arena;
        var chain = start;
        var pass: usize = 0;
        while (pass < 4) : (pass += 1) {
            const p = chain.pts;
            const n = p.len;
            if (n < 4) return chain; // need two interior corners (indices 1..n-2)
            var merged = false;
            var i: usize = 1;
            while (i + 2 < n) : (i += 1) {
                const v = self.tryMerge(chain, info, i) orelse continue;
                // Rebuild the chain with p[i], p[i+1] replaced by the apex `v`.
                // Legs kept: p[0]→…→p[i-1]→v (widths[0..i-1], the last being the
                // incoming outer leg) then v→p[i+2]→…→p[n-1] (widths[i+1..],
                // dropping widths[i], the collapsed shared leg).
                var pts: std.ArrayList([2]f64) = .empty;
                var ws: std.ArrayList(f64) = .empty;
                for (0..i) |j| {
                    try pts.append(arena, p[j]);
                    try ws.append(arena, chain.widths[j]);
                }
                try pts.append(arena, v); // the merged apex (no width — leg i-1 already counted)
                for (i + 2..n) |j| {
                    try pts.append(arena, p[j]);
                    try ws.append(arena, chain.widths[j - 1]);
                }
                chain = .{ .pts = try pts.toOwnedSlice(arena), .widths = try ws.toOwnedSlice(arena) };
                merged = true;
                break;
            }
            if (!merged) return chain;
        }
        return chain;
    }

    /// Decide whether the corner pair at interior vertices `i`,`i+1` should
    /// merge; returns the virtual apex when it should, else null.
    fn tryMerge(self: Self, chain: Chain, info: GroupInfo, i: usize) ?[2]f64 {
        const p = chain.pts;
        const n = p.len;
        const A0 = p[i - 1];
        const B = p[i];
        const C = p[i + 1];
        const D = p[i + 2];
        const d0 = unit(A0, B) orelse return null; // incoming outer dir
        const dm = unit(B, C) orelse return null; // shared middle dir
        const d1 = unit(C, D) orelse return null; // outgoing outer dir
        const defl0 = std.math.acos(std.math.clamp(d0[0] * dm[0] + d0[1] * dm[1], -1, 1));
        const defl1 = std.math.acos(std.math.clamp(dm[0] * d1[0] + dm[1] * d1[1], -1, 1));
        if (defl0 < min_deflection or defl1 < min_deflection) return null;
        // Same rotational sense (a monotone Z-jog, not an S).
        const s0 = d0[0] * dm[1] - d0[1] * dm[0];
        const s1 = dm[0] * d1[1] - dm[1] * d1[0];
        if (s0 * s1 <= 0) return null;
        // Merged deflection between the two OUTER legs.
        const md = std.math.acos(std.math.clamp(d0[0] * d1[0] + d0[1] * d1[1], -1, 1));
        if (md >= max_deflection or md < min_deflection) return null;
        // Merge when the pair is starved separately — either the shared leg is
        // too short for both fillets to fit (cramped: shorter than the sum of
        // their floor tangents) OR an outer leg is escape-pinned right at its
        // bend so that corner can never round without eating the reserve (the
        // mixer LO-drive case). The merged fillet's tangent points land past
        // the escape stub on BOTH ends, so the straight pad exits are kept — the
        // merge collapses only the interior Z, honouring the escape reserve.
        const width = @min(chain.widths[i - 1], chain.widths[i]);
        const floor_t = info.radius * std.math.tan(@min(defl0, defl1) / 2.0);
        const shared = dist(B, C);
        const escape = info.escape;
        const esc_in = if (i - 1 == 0 and escape > 0 and self.probe.onPad(A0, info)) escape else 0;
        const esc_out = if (i + 2 == n - 1 and escape > 0 and self.probe.onPad(D, info)) escape else 0;
        const pinned = (esc_in > 0 and dist(A0, B) <= escape + floor_t) or
            (esc_out > 0 and dist(C, D) <= escape + floor_t);
        const cramped = shared < floor_t;
        if (!pinned and !cramped) return null;
        // Virtual apex = intersection of the two outer leg lines.
        const v = lineIntersect(A0, d0, D, d1) orelse return null;
        // Tangent room on each outer leg, honouring the escape reserve.
        const avail_in = dist(A0, v) - esc_in;
        const avail_out = dist(v, D) - esc_out;
        if (avail_in < floor_t * 0.6 or avail_out < floor_t * 0.6) return null;
        // The largest fillet that fits both outer legs (and the 5x aim cap).
        const tan_h = std.math.tan(md / 2.0);
        const t_cap = info.aim_ratio * width * tan_h;
        const t = @min(@min(avail_in, avail_out), t_cap);
        const r_eff = t / tan_h;
        if (r_eff + radius_eps_mm < 0.95 * info.radius) return null; // merge must reach ~floor
        // Build the merged fillet and vet arc + the two extended outer legs.
        const g = BendGeom{
            .apex = v,
            .u = d0,
            .v = d1,
            .defl = md,
            .net = info.net,
            .layer = info.layer,
            .width = width,
        };
        const arc = filletArc(g, t) orelse return null;
        if (!self.probe.clear(arc)) return null;
        const p1 = [2]f64{ v[0] - d0[0] * t, v[1] - d0[1] * t };
        const p2 = [2]f64{ v[0] + d1[0] * t, v[1] + d1[1] * t };
        const ref = CopperRef{ .net = info.net, .layer = info.layer, .width = width };
        if (!self.probe.segmentClear(A0, p1, ref)) return null;
        if (!self.probe.segmentClear(p2, D, ref)) return null;
        return v;
    }

    /// The chain's escape reserves: when an end of the chain terminates on a
    /// same-net pad and the net declares a straight-escape distance, arcs may
    /// not cut into that first stretch of copper leaving the pad.
    fn escapeOf(self: Self, chain: Chain, info: GroupInfo) std.mem.Allocator.Error!Escape {
        const arena = self.sink.arena;
        const cum = try arena.alloc(f64, chain.pts.len);
        cum[0] = 0;
        for (1..chain.pts.len) |i| cum[i] = cum[i - 1] + dist(chain.pts[i - 1], chain.pts[i]);
        var esc = Escape{ .cum = cum, .total = cum[chain.pts.len - 1] };
        if (info.escape <= 0) return esc;
        if (self.probe.onPad(chain.pts[0], info)) esc.start = info.escape;
        if (self.probe.onPad(chain.pts[chain.pts.len - 1], info)) esc.end = info.escape;
        return esc;
    }

    fn smoothCorner(self: Self, c: Corner, trims: TrimsMut) std.mem.Allocator.Error!void {
        const sink = self.sink;
        const p = c.chain.pts;
        const i = c.i;
        const width = @min(c.chain.widths[i - 1], c.chain.widths[i]);
        const flag_all = c.defl[i] > max_deflection;
        const half = c.defl[i] / 2.0;
        const tan_half = std.math.tan(half);
        const len_prev = dist(p[i - 1], p[i]);
        const len_next = dist(p[i], p[i + 1]);
        var allow_prev = legShare(len_prev, c.want[i], c.want[i - 1]);
        var allow_next = legShare(len_next, c.want[i], c.want[i + 1]);
        // A square corner aims at the geometric maximum instead of the width
        // multiple, so it also claims the leg room its neighbour's want leaves
        // over (`legMaxClaim`). Zero on every other corner, which then keeps
        // exactly the width-multiple budget it has always had.
        const square = isRightAngle(c.defl[i]);
        const reserve = straightReserve(width);
        var most_prev = if (square)
            legMaxClaim(len_prev, c.want[i], c.want[i - 1], isRightAngle(c.defl[i - 1]), reserve)
        else
            0;
        var most_next = if (square)
            legMaxClaim(len_next, c.want[i], c.want[i + 1], isRightAngle(c.defl[i + 1]), reserve)
        else
            0;
        // The straight pad-escape reserve: an arc may not cut back into the
        // declared escape stretch of a pad the chain exits. A corner sitting
        // INSIDE the reserve (a rescued route that already bends early) is
        // not clamped — the reserve is already lost there, and a smoothed
        // early bend beats a hard one. It binds the maximal claim just as hard:
        // aiming bigger may never spend copper the escape reserved.
        if (c.esc.start > 0 and c.esc.cum[i] >= c.esc.start) {
            const room = c.esc.cum[i] - c.esc.start;
            allow_prev = @min(allow_prev, room);
            most_prev = @min(most_prev, room);
        }
        if (c.esc.end > 0 and c.esc.total - c.esc.cum[i] >= c.esc.end) {
            const room = c.esc.total - c.esc.cum[i] - c.esc.end;
            allow_next = @min(allow_next, room);
            most_next = @min(most_next, room);
        }
        // Whichever aim is more generous: a square corner never smooths tighter
        // than the width multiple alone would have reached, and the ladder below
        // descends from here to the same floor either way.
        const t_max = @max(
            @min(c.want[i], @min(allow_prev, allow_next)),
            @min(most_prev, most_next),
        );
        // The floor: never bother below a 1x-width radius (or a vanishing trim).
        const t_floor = @max(@max(min_tangent, width / 4.0), width * tan_half);
        // The compliance floor radius (3x width by default) and its 5% band:
        // an arc that reaches within 5% of the floor is not worth a finding.
        const floor_r = c.info.radius;
        const tol_r = 0.95 * floor_r;
        if (flag_all) {
            try flagSharp(sink, c, 0, null);
            return;
        }
        // A shallow kink too starved for even a 1x-width fillet is vertex noise
        // (a pad-stub grid quantization, an escape-reserve pin), not a real
        // sharp bend — leave it alone: no arc, no flag.
        if (c.defl[i] < shallow_kink_max and t_max < t_floor) return;
        // Pass A: the symmetric fillet, shrinking from the aim toward the floor
        // and — when even the floor cut is crowded — below it, taking the
        // largest DRC-clean radius. A sub-3W bend that fits still beats a hard
        // corner. `t_below` lets the ladder continue under `t_floor` down to a
        // small chamfer when the corner is fully probe-blocked at floor.
        const sym = self.bestSymmetric(c, width, t_max, t_floor);

        // Pass B: an asymmetric two-arc fit (a biarc) — its real value is
        // routing PAST a one-sided obstacle: the symmetric fillet's cut crowds
        // foreign copper on one flank and has to shrink, but a biarc slides its
        // bulk toward the free leg and clears at a much larger radius. (For a
        // clear corner the biarc only TIES the symmetric fillet, so it is used
        // only when it beats the symmetric result by a real margin.) Attempted
        // when the symmetric fillet fell short of the floor and the legs are
        // lopsided enough to give the slide somewhere to go.
        const asym_ratio = if (@min(allow_prev, allow_next) > eps)
            @max(allow_prev, allow_next) / @min(allow_prev, allow_next)
        else
            std.math.inf(f64);
        const sym_r = if (sym) |s| s.min_r else 0;
        const want_asym = sym_r + 1e-3 < floor_r and asym_ratio > 1.5;
        const bi = if (want_asym)
            self.bestBiarc(c, width, allow_prev, allow_next)
        else
            null;

        // Prefer the biarc only when it opens the bend by a meaningful margin
        // over the symmetric fillet (≈a tenth of a millimetre) — a marginal tie
        // keeps the single arc and its simpler copper.
        const use_bi = bi != null and bi.?.min_r > sym_r + 0.1;
        if (use_bi) {
            const b = bi.?;
            try sink.arcs.append(sink.arena, b.arc1);
            try sink.arcs.append(sink.arena, b.arc2);
            trims.e[i - 1] += b.tin;
            trims.s[i] += b.tout;
            if (b.min_r + radius_eps_mm < tol_r) try flagSharp(sink, c, b.min_r, b.join);
            return;
        }
        if (sym) |s| {
            try sink.arcs.append(sink.arena, s.arc);
            trims.e[i - 1] += s.t;
            trims.s[i] += s.t;
            if (s.min_r + radius_eps_mm < tol_r) try flagSharp(sink, c, s.min_r, s.mid);
            return;
        }
        // No arc placed at all: a shallow kink too starved for any arc is
        // vertex noise (a pad-stub grid quantization), not a sharp bend.
        if (c.defl[i] < shallow_kink_max) return;
        try flagSharp(sink, c, 0, null);
    }

    /// The best symmetric fillet that clears the probe: shrink from `t_max`
    /// toward `t_floor`, then continue below the floor to a small chamfer,
    /// taking the largest DRC-clean radius. Null when even the chamfer is
    /// crowded.
    fn bestSymmetric(self: Self, c: Corner, width: f64, t_max: f64, t_floor: f64) ?SymFit {
        if (t_max < min_tangent) return null;
        const tan_half = std.math.tan(c.defl[c.i] / 2.0);
        // A chamfer floor: allow the ladder to drop below the 1x-width floor
        // when the corner is otherwise blocked, but never below ~0.4x width.
        const t_min = @max(min_tangent, @min(t_floor, width * 0.4 * tan_half));
        var t = t_max; // start at the aim-limited maximum
        var blocked_above: ?f64 = null;
        // First descend on the coarse 0.7 ladder to the floor …
        while (t >= t_min - eps) : (t *= 0.7) {
            const use_t = @max(t, t_min);
            const arc = cornerArc(c, use_t, width) orelse return null;
            if (self.probe.clear(arc)) {
                const best = SymFit{ .arc = arc, .t = use_t, .min_r = use_t / tan_half, .mid = arc.pm };
                // The ladder finds a clearing bracket quickly, but returning
                // its first rung can throw away almost 30% of the available
                // radius. Refine between that clear candidate and the last
                // blocked one so an open elbow does not visually settle at the
                // compliance floor merely because the next 0.7 rung happened
                // to land there.
                const blocked = blocked_above orelse return best;
                return self.refineSymmetric(c, width, tan_half, best, blocked);
            }
            blocked_above = use_t;
            if (use_t <= t_min + eps) break;
        }
        return null;
    }

    fn refineSymmetric(
        self: Self,
        c: Corner,
        width: f64,
        tan_half: f64,
        initial: SymFit,
        blocked: f64,
    ) SymFit {
        var best = initial;
        var lo = initial.t;
        var hi = blocked;
        for (0..12) |_| {
            const mid = (lo + hi) / 2.0;
            const refined = cornerArc(c, mid, width) orelse break;
            if (self.probe.clear(refined)) {
                lo = mid;
                best = .{ .arc = refined, .t = mid, .min_r = mid / tan_half, .mid = refined.pm };
            } else {
                hi = mid;
            }
        }
        return best;
    }

    /// The best asymmetric biarc that clears the probe. Scans the turn split;
    /// for each split the two radii follow from a 2x2 linear solve. Returns the
    /// split maximising the smaller of the two radii (the binding one).
    fn bestBiarc(self: Self, c: Corner, width: f64, avail_in: f64, avail_out: f64) ?BiFit {
        if (avail_in < min_tangent or avail_out < min_tangent) return null;
        const p = c.chain.pts;
        const i = c.i;
        const u = unit(p[i - 1], p[i]) orelse return null; // travel dir into apex
        const v = unit(p[i], p[i + 1]) orelse return null; // travel dir out of apex
        const g = BendGeom{
            .apex = p[i],
            .u = u,
            .v = v,
            .defl = c.defl[i],
            .net = c.info.net,
            .layer = c.info.layer,
            .width = width,
        };
        // Cap the lever: beyond ~4x the floor radius extra tangent length only
        // pushes the join further out for no radius gain (and more copper to
        // clear). Scan a few tangent fractions on each leg AND the turn split,
        // keeping the split whose binding radius is largest and clears.
        const cap = 4.0 * @max(c.info.radius, width);
        const ti_max = @min(avail_in, cap);
        const to_max = @min(avail_out, cap);
        const fracs = [_]f64{ 1.0, 0.66, 0.4, 0.22 };
        const steps = 18;
        var best: ?BiFit = null;
        for (fracs) |tf| {
            const t_in = ti_max * tf;
            if (t_in < min_tangent) continue;
            for (fracs) |sf| {
                const t_out = to_max * sf;
                if (t_out < min_tangent) continue;
                var k: usize = 1;
                while (k < steps) : (k += 1) {
                    const a = g.defl * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
                    const cand = biarcFit(g, t_in, t_out, a) orelse continue;
                    if (!self.probe.clear(cand.arc1) or !self.probe.clear(cand.arc2)) continue;
                    if (best == null or cand.min_r > best.?.min_r) best = cand;
                }
            }
        }
        return best;
    }
};

/// A cleared symmetric-fillet candidate.
const SymFit = struct { arc: router.Arc, t: f64, min_r: f64, mid: [2]f64 };
/// A cleared biarc candidate: two tangent arcs meeting at `join`.
const BiFit = struct {
    arc1: router.Arc,
    arc2: router.Arc,
    tin: f64,
    tout: f64,
    min_r: f64,
    join: [2]f64,
};

/// One corner's geometry (apex + the two travel directions + deflection) plus
/// the copper attributes an arc there inherits — the shared input to the
/// fillet / biarc builders, bundled so those builders stay few-argument.
const BendGeom = struct {
    apex: [2]f64,
    u: [2]f64, // travel dir INTO the apex
    v: [2]f64, // travel dir OUT of the apex
    defl: f64,
    net: i32,
    layer: u8,
    width: f64,
    /// The turn sense: +1 left (CCW), −1 right (CW).
    fn sgn(g: BendGeom) f64 {
        return if (g.u[0] * g.v[1] - g.u[1] * g.v[0] >= 0) 1.0 else -1.0;
    }
};

/// The tangent arc cutting corner `c` with trim `t` on each leg, or null for
/// degenerate geometry (parallel legs).
fn cornerArc(c: Corner, t: f64, width: f64) ?router.Arc {
    const p = c.chain.pts;
    const i = c.i;
    const u = unit(p[i - 1], p[i]) orelse return null;
    const v = unit(p[i], p[i + 1]) orelse return null;
    const g = BendGeom{
        .apex = p[i],
        .u = u,
        .v = v,
        .defl = c.defl[i],
        .net = c.info.net,
        .layer = c.info.layer,
        .width = width,
    };
    return filletArc(g, t);
}

/// A symmetric tangent fillet at the apex: trimmed `t` back along the incoming
/// travel dir and `t` forward along the outgoing travel dir, bulging to the
/// interior of the bend. Null for parallel legs.
fn filletArc(g: BendGeom, t: f64) ?router.Arc {
    const half = g.defl / 2.0;
    const r_eff = t / std.math.tan(half);
    const bis = [2]f64{ g.v[0] - g.u[0], g.v[1] - g.u[1] };
    const bl = std.math.hypot(bis[0], bis[1]);
    if (bl < eps) return null;
    // Apex-to-center distance along the interior bisector: r/cos(defl/2).
    // (sin and cos coincide at a right angle — only non-90° bends expose
    // the difference, which is why this needs the 45° regression test.)
    const dist_c = r_eff / @cos(half);
    const center = [2]f64{ g.apex[0] + bis[0] / bl * dist_c, g.apex[1] + bis[1] / bl * dist_c };
    const to_apex = [2]f64{ g.apex[0] - center[0], g.apex[1] - center[1] };
    const tl = std.math.hypot(to_apex[0], to_apex[1]);
    return .{
        .p1 = .{ g.apex[0] - g.u[0] * t, g.apex[1] - g.u[1] * t },
        .pm = .{ center[0] + to_apex[0] / tl * r_eff, center[1] + to_apex[1] / tl * r_eff },
        .p2 = .{ g.apex[0] + g.v[0] * t, g.apex[1] + g.v[1] * t },
        .layer = g.layer,
        .width = g.width,
        .net = g.net,
    };
}

/// Intersection of the line through `p0` dir `d0` and the line through `p1`
/// dir `d1`, or null when (near-)parallel.
fn lineIntersect(p0: [2]f64, d0: [2]f64, p1: [2]f64, d1: [2]f64) ?[2]f64 {
    const den = d0[0] * d1[1] - d0[1] * d1[0];
    if (@abs(den) < eps) return null;
    const s = ((p1[0] - p0[0]) * d1[1] - (p1[1] - p0[1]) * d1[0]) / den;
    return .{ p0[0] + d0[0] * s, p0[1] + d0[1] * s };
}

fn perp(a: [2]f64) [2]f64 {
    return .{ -a[1], a[0] };
}
fn rotv(a: [2]f64, ang: f64) [2]f64 {
    const cs = @cos(ang);
    const sn = @sin(ang);
    return .{ a[0] * cs - a[1] * sn, a[0] * sn + a[1] * cs };
}

/// A tangent biarc cutting the corner `g`: two circular arcs, the first tangent
/// to the incoming leg `t_in` back from the apex, the second tangent to the
/// outgoing leg `t_out` past it, meeting at a join `J` with a shared tangent.
/// `a` is the turn the FIRST arc absorbs (the rest, `defl − a`, goes to the
/// second); with unequal `t_in`/`t_out` the arc next to the roomier leg swings
/// to a much larger radius than any symmetric fillet could reach. Null for a
/// split that yields a negative/degenerate radius (wrong sense or straightened).
fn biarcFit(g: BendGeom, t_in: f64, t_out: f64, a: f64) ?BiFit {
    const u = g.u;
    const v = g.v;
    const sgn = g.sgn();
    const b = g.defl - a;
    if (a < eps or b < eps) return null;
    const P1 = [2]f64{ g.apex[0] - u[0] * t_in, g.apex[1] - u[1] * t_in };
    const P2 = [2]f64{ g.apex[0] + v[0] * t_out, g.apex[1] + v[1] * t_out };
    const un = [2]f64{ sgn * perp(u)[0], sgn * perp(u)[1] }; // interior normal at P1
    const w = rotv(u, sgn * a); // tangent direction at the join
    const wn = [2]f64{ sgn * perp(w)[0], sgn * perp(w)[1] };
    // Arc-displacement basis vectors: J-P1 = r1*V1, P2-J = r2*V2.
    const V1 = [2]f64{ @sin(a) * u[0] + (1 - @cos(a)) * un[0], @sin(a) * u[1] + (1 - @cos(a)) * un[1] };
    const V2 = [2]f64{ @sin(b) * w[0] + (1 - @cos(b)) * wn[0], @sin(b) * w[1] + (1 - @cos(b)) * wn[1] };
    const dx = P2[0] - P1[0];
    const dy = P2[1] - P1[1];
    const det = V1[0] * V2[1] - V2[0] * V1[1];
    if (@abs(det) < eps) return null;
    const r1 = (dx * V2[1] - V2[0] * dy) / det;
    const r2 = (V1[0] * dy - dx * V1[1]) / det;
    if (r1 <= g.width * 0.3 or r2 <= g.width * 0.3) return null;
    const O1 = [2]f64{ P1[0] + r1 * un[0], P1[1] + r1 * un[1] };
    const J = [2]f64{ P1[0] + r1 * V1[0], P1[1] + r1 * V1[1] };
    const O2 = [2]f64{ P2[0] + r2 * (sgn * perp(v)[0]), P2[1] + r2 * (sgn * perp(v)[1]) };
    const pm1 = arcMid(O1, r1, P1, sgn * a);
    const pm2 = arcMid(O2, r2, J, sgn * b);
    return .{
        .arc1 = .{ .p1 = P1, .pm = pm1, .p2 = J, .layer = g.layer, .width = g.width, .net = g.net },
        .arc2 = .{ .p1 = J, .pm = pm2, .p2 = P2, .layer = g.layer, .width = g.width, .net = g.net },
        .tin = t_in,
        .tout = t_out,
        .min_r = @min(r1, r2),
        .join = J,
    };
}

/// Midpoint of a circular arc: `start` on the circle centred `O` radius `r`,
/// swept `sweep` radians (signed).
fn arcMid(O: [2]f64, r: f64, start: [2]f64, sweep: f64) [2]f64 {
    const a0 = std.math.atan2(start[1] - O[1], start[0] - O[0]);
    const am = a0 + sweep / 2.0;
    return .{ O[0] + r * @cos(am), O[1] + r * @sin(am) };
}

/// Collapse sub-half-width legs — the off-grid pad-entry jogs the maze
/// emits, vertex noise rather than real corners. Left alone, a 0.05 mm stub
/// beside a long run vetoes the run's bend (no leg allowance); collapsed,
/// the deviation is bounded by the jog length (inside the copper width) and
/// the clearance probe still vets the resulting arc. Chain endpoints (the
/// pad connections) never move. Runs to a fixed point (max 4 passes).
///
/// Each collapse is PROBED (`probe.segClear(a, b)`) before it is taken. "The
/// deviation is bounded by the copper width" is a bound on how far the copper
/// moves, not a promise that where it moves to is legal: swinging a 4 mm run's
/// far end by half a track width sweeps its whole middle sideways, and on a
/// dense board that middle lands on a foreign pad. Both surviving callers emit
/// this polyline as real copper — `straighten` directly, `smoothChain` as the
/// legs between its arcs — and each one's own probe never sees the change,
/// because both only probe the shortcuts and arcs THEY choose. That is how
/// barracuda's CP_FILT run ended up 0.09 mm inside the op-amp's ground pad on a
/// board every other stage had verified. A collapse the probe refuses simply
/// keeps its jog.
pub fn simplifyChain(arena: std.mem.Allocator, raw: Chain, probe: anytype) std.mem.Allocator.Error!Chain {
    var chain = raw;
    var pass: usize = 0;
    while (pass < 4) : (pass += 1) {
        if (chain.widths.len < 2) return chain;
        var pts: std.ArrayList([2]f64) = .empty;
        var ws: std.ArrayList(f64) = .empty;
        try pts.append(arena, chain.pts[0]);
        var dropped = false;
        var j: usize = 0;
        while (j < chain.widths.len) : (j += 1) {
            const tiny = dist(chain.pts[j], chain.pts[j + 1]) < chain.widths[j] / 2.0 and
                collapseClears(chain, pts.items, ws.items.len, j, probe);
            if (!tiny) {
                try pts.append(arena, chain.pts[j + 1]);
                try ws.append(arena, chain.widths[j]);
                continue;
            }
            dropped = true;
            if (j == chain.widths.len - 1) {
                // Tiny last leg: the previous leg absorbs it, ending exactly
                // at the chain's final point.
                if (ws.items.len > 0) {
                    pts.items[pts.items.len - 1] = chain.pts[j + 1];
                } else {
                    try pts.append(arena, chain.pts[j + 1]);
                    try ws.append(arena, chain.widths[j]);
                }
            } else if (pts.items.len == 1 and ws.items.len == 0) {
                // Tiny first leg: the next leg starts at the chain's origin.
            } else {
                // Interior jog: both joints collapse to the midpoint.
                pts.items[pts.items.len - 1] = .{
                    (chain.pts[j][0] + chain.pts[j + 1][0]) / 2.0,
                    (chain.pts[j][1] + chain.pts[j + 1][1]) / 2.0,
                };
            }
        }
        if (!dropped) return chain;
        chain = .{ .pts = try pts.toOwnedSlice(arena), .widths = try ws.toOwnedSlice(arena) };
    }
    return chain;
}

/// Would dropping leg `j` leave clear copper? `pts`/`ws_len` are the partially
/// rebuilt chain, so this mirrors exactly what `simplifyChain`'s three collapse
/// branches do to the geometry:
///   * tiny FIRST leg  — the next leg starts at the chain origin instead;
///   * tiny LAST leg   — the previous joint slides onto the chain's end pad
///                       (a no-op when this leg is the only one so far);
///   * interior jog    — both joints fuse at the jog's midpoint, reshaping the
///                       segment before it and the one after it.
/// Only the segments the collapse CREATES are probed; the untouched ones keep
/// whatever verdict they already earned.
fn collapseClears(chain: Chain, pts: []const [2]f64, ws_len: usize, j: usize, probe: anytype) bool {
    if (j == chain.widths.len - 1)
        return ws_len == 0 or probe.segClear(pts[pts.len - 2], chain.pts[j + 1]);
    if (pts.len == 1 and ws_len == 0) return probe.segClear(chain.pts[0], chain.pts[j + 2]);
    const mid = [2]f64{
        (chain.pts[j][0] + chain.pts[j + 1][0]) / 2.0,
        (chain.pts[j][1] + chain.pts[j + 1][1]) / 2.0,
    };
    return probe.segClear(pts[pts.len - 2], mid) and probe.segClear(mid, chain.pts[j + 2]);
}

/// A `simplifyChain` probe that takes every collapse — the chain-shape unit
/// tests, which hold no board to measure against.
const AllClearChainProbe = struct {
    fn segClear(_: AllClearChainProbe, _: [2]f64, _: [2]f64) bool {
        return true;
    }
};

/// One directed traversal option out of a chain node.
const Half = struct { seg: u32, to: u32 };

/// The endpoint graph a chain walk traverses.
const Graph = struct {
    segs: []const router.Track,
    adj: []const std.ArrayList(Half),
    node_pts: []const [2]f64,
    visited: []bool,
};

fn qpt(x: f64, y: f64) [2]i32 {
    return .{
        @intFromFloat(std.math.round(x / snap)),
        @intFromFloat(std.math.round(y / snap)),
    };
}

/// Rebuild ordered polylines from an unordered segment soup. Chains break at
/// junction vertices (degree != 2) so a T/Steiner point is never smoothed
/// through; collinear same-width runs merge into one leg.
pub fn extractChains(
    arena: std.mem.Allocator,
    segs: []const router.Track,
) std.mem.Allocator.Error![]Chain {
    var node_of = std.AutoHashMapUnmanaged([2]i32, u32).empty;
    var pts: std.ArrayList([2]f64) = .empty;
    var adj: std.ArrayList(std.ArrayList(Half)) = .empty;

    const ends = try arena.alloc([2]u32, segs.len);
    for (segs, 0..) |s, si| {
        const pab = [2][2]f64{ .{ s.x1, s.y1 }, .{ s.x2, s.y2 } };
        for (pab, 0..) |p, side| {
            const slot = try node_of.getOrPut(arena, qpt(p[0], p[1]));
            if (!slot.found_existing) {
                slot.value_ptr.* = @intCast(pts.items.len);
                try pts.append(arena, p);
                try adj.append(arena, .empty);
            }
            ends[si][side] = slot.value_ptr.*;
        }
        try adj.items[ends[si][0]].append(arena, .{ .seg = @intCast(si), .to = ends[si][1] });
        try adj.items[ends[si][1]].append(arena, .{ .seg = @intCast(si), .to = ends[si][0] });
    }

    var chains: std.ArrayList(Chain) = .empty;
    const visited = try arena.alloc(bool, segs.len);
    @memset(visited, false);
    const graph = Graph{
        .segs = segs,
        .adj = adj.items,
        .node_pts = pts.items,
        .visited = visited,
    };
    // Two sweeps: open chains from junction/terminal nodes first, then any
    // remaining pure loops.
    var sweep: usize = 0;
    while (sweep < 2) : (sweep += 1) {
        for (adj.items, 0..) |halves, start| {
            if (sweep == 0 and halves.items.len == 2) continue;
            for (halves.items) |h| {
                if (visited[h.seg]) continue;
                try chains.append(arena, try walkChain(arena, graph, @intCast(start), h));
            }
        }
    }
    return chains.toOwnedSlice(arena);
}

fn walkChain(
    arena: std.mem.Allocator,
    graph: Graph,
    start: u32,
    first: Half,
) std.mem.Allocator.Error!Chain {
    var cp: std.ArrayList([2]f64) = .empty;
    var cw: std.ArrayList(f64) = .empty;
    var node = start;
    var half = first;
    try cp.append(arena, graph.node_pts[node]);
    while (true) {
        graph.visited[half.seg] = true;
        try appendLeg(arena, &cp, &cw, graph.node_pts[half.to], graph.segs[half.seg].width);
        node = half.to;
        if (graph.adj[node].items.len != 2) break;
        var next: ?Half = null;
        for (graph.adj[node].items) |h| {
            if (!graph.visited[h.seg]) next = h;
        }
        half = next orelse break;
    }
    return .{ .pts = try cp.toOwnedSlice(arena), .widths = try cw.toOwnedSlice(arena) };
}

/// Append a vertex, merging into the previous leg when collinear (same
/// direction) and equal width — grid routes arrive as many unit steps.
fn appendLeg(
    arena: std.mem.Allocator,
    cp: *std.ArrayList([2]f64),
    cw: *std.ArrayList(f64),
    p: [2]f64,
    width: f64,
) std.mem.Allocator.Error!void {
    if (cp.items.len >= 2 and cw.items.len >= 1 and cw.items[cw.items.len - 1] == width) {
        const a = cp.items[cp.items.len - 2];
        const b = cp.items[cp.items.len - 1];
        const ab = [2]f64{ b[0] - a[0], b[1] - a[1] };
        const bp = [2]f64{ p[0] - b[0], p[1] - b[1] };
        const cross = ab[0] * bp[1] - ab[1] * bp[0];
        const dot = ab[0] * bp[0] + ab[1] * bp[1];
        if (@abs(cross) < snap and dot > 0) {
            cp.items[cp.items.len - 1] = p;
            return;
        }
    }
    try cp.append(arena, p);
    try cw.append(arena, width);
}

/// One turning vertex of a chain, with everything its arc needs.
const Corner = struct {
    chain: Chain,
    defl: []const f64,
    /// Desired tangent trim per vertex (0 = not a smoothable corner).
    want: []const f64,
    i: usize,
    info: GroupInfo,
    esc: Escape = .{},
};

/// A chain's cumulative vertex distances plus the straight escape reserve
/// (mm) at each end — nonzero only when that end terminates on a same-net pad
/// of an escape-declaring net.
const Escape = struct {
    cum: []const f64 = &.{},
    total: f64 = 0,
    start: f64 = 0,
    end: f64 = 0,
};

/// Fit the vertices of a contiguous same-sense turn run to one circle. A
/// smoothed arc persisted as straight chords has its tangent endpoints at
/// `start`/`end` and every vertex between them on the same circle. Raw doglegs
/// generally fail that radial-consistency test and remain zero-radius corners.
fn circularRunRadius(chain: Chain, start: usize, end: usize) ?f64 {
    if (end < start + 2 or end >= chain.pts.len) return null;
    const mid = (start + end) / 2;
    const fitted = circleOf(.{
        .p1 = chain.pts[start],
        .pm = chain.pts[mid],
        .p2 = chain.pts[end],
        .layer = 0,
        .width = 0,
        .net = 0,
    }) orelse return null;
    const radial_tol = @max(0.01, fitted.r * 0.02);
    for (chain.pts[start .. end + 1]) |pt| {
        const radius = std.math.hypot(pt[0] - fitted.cx, pt[1] - fitted.cy);
        if (@abs(radius - fitted.r) > radial_tol) return null;
    }
    return fitted.r;
}

fn appendMeasuredSharp(
    sink: *Sink,
    info: GroupInfo,
    pos: [2]f64,
    radius: f64,
) std.mem.Allocator.Error!void {
    try sink.sharp.append(sink.arena, .{
        .x = pos[0],
        .y = pos[1],
        .layer = info.layer,
        .net = info.net,
        .radius = radius,
        .required = info.radius,
    });
}

/// Record an under-radius corner for DRC. `pos` places the marker ON the final
/// copper — the arc midpoint / biarc join when an under-floor arc was actually
/// placed — so the `sharp_bend` marker never floats in empty space off a
/// resolved corner; a null `pos` falls back to the vertex (a corner that
/// stayed truly sharp, with no arc).
fn flagSharp(sink: *Sink, c: Corner, radius: f64, pos: ?[2]f64) std.mem.Allocator.Error!void {
    const at = pos orelse c.chain.pts[c.i];
    try sink.sharp.append(sink.arena, .{
        .x = at[0],
        .y = at[1],
        .layer = c.info.layer,
        .net = c.info.net,
        .radius = radius,
        .required = c.info.radius,
    });
}

/// How much of a leg one corner may consume. A leg wanted from both ends
/// splits in proportion to the two corners' desired trims (so a short shared
/// leg still gives BOTH bends their fair maximum); a leg wanted from one end
/// only is fully available.
fn legShare(len: f64, mine: f64, other: f64) f64 {
    const usable = @max(0, len - snap);
    if (other <= 0) return usable;
    if (mine + other <= usable) return mine;
    return usable * mine / (mine + other);
}

/// Straight copper (mm) a MAXIMAL fillet leaves at the far end of every leg it
/// eats into: one trace width. It keeps the tangent point off the leg's far
/// vertex (a pad or via entry) and off the neighbouring fillet's own tangent
/// point, so every leg still carries a real straight run for the emitter and
/// the tangency stays well conditioned.
fn straightReserve(width: f64) f64 {
    return @max(width, min_tangent);
}

/// How much of a leg a MAXIMAL (right-angle) corner may trim. On top of its
/// ordinary `legShare` it takes the room the corner at the leg's OTHER end does
/// not want — halved when that corner is maximal too, so the two claims still
/// sum to no more than the leg — and stops `reserve` short of the far end.
///
/// Claims from both ends therefore never exceed `len - snap`, exactly the
/// no-overlap invariant `legShare` alone gives the width-multiple aim.
fn legMaxClaim(len: f64, mine: f64, other: f64, other_max: bool, reserve: f64) f64 {
    const room = @max(0, len - snap - reserve);
    const share = legShare(len, mine, other);
    const spare = @max(0, room - share - legShare(len, other, mine));
    return @min(room, share + if (other_max) spare / 2.0 else spare);
}

const Trims = struct { s: []const f64, e: []const f64 };
const TrimsMut = struct { s: []f64, e: []f64 };

fn emitLegs(
    sink: *Sink,
    chain: Chain,
    trims: ?Trims,
    info: GroupInfo,
) std.mem.Allocator.Error!void {
    for (0..chain.pts.len - 1) |j| {
        const a = chain.pts[j];
        const b = chain.pts[j + 1];
        const u = unit(a, b) orelse continue;
        const ts = if (trims) |t| t.s[j] else 0;
        const te = if (trims) |t| t.e[j] else 0;
        const x1 = a[0] + u[0] * ts;
        const y1 = a[1] + u[1] * ts;
        const x2 = b[0] - u[0] * te;
        const y2 = b[1] - u[1] * te;
        if (std.math.hypot(x2 - x1, y2 - y1) < eps) continue;
        try sink.out.append(sink.arena, .{
            .x1 = x1,
            .y1 = y1,
            .x2 = x2,
            .y2 = y2,
            .layer = info.layer,
            .width = chain.widths[j],
            .net = info.net,
        });
    }
}

fn unit(a: [2]f64, b: [2]f64) ?[2]f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < eps) return null;
    return .{ dx / len, dy / len };
}

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn segLen(t: router.Track) f64 {
    return std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
}

/// Circle geometry recovered from an arc's three points, or null when the
/// points are (near-)collinear and the arc degenerates to its chord.
const Circle = struct { cx: f64, cy: f64, r: f64, a1: f64, sweep: f64 };

fn circleOf(arc: router.Arc) ?Circle {
    const x1 = arc.p1[0];
    const y1 = arc.p1[1];
    const xm = arc.pm[0];
    const ym = arc.pm[1];
    const x2 = arc.p2[0];
    const y2 = arc.p2[1];
    const d = 2.0 * (x1 * (ym - y2) + xm * (y2 - y1) + x2 * (y1 - ym));
    if (@abs(d) < 1e-9) return null;
    const s1 = x1 * x1 + y1 * y1;
    const sm = xm * xm + ym * ym;
    const s2 = x2 * x2 + y2 * y2;
    const cx = (s1 * (ym - y2) + sm * (y2 - y1) + s2 * (y1 - ym)) / d;
    const cy = (s1 * (x2 - xm) + sm * (x1 - x2) + s2 * (xm - x1)) / d;
    const r = std.math.hypot(x1 - cx, y1 - cy);
    const a1 = std.math.atan2(y1 - cy, x1 - cx);
    const am = std.math.atan2(ym - cy, xm - cx);
    const a2 = std.math.atan2(y2 - cy, x2 - cx);
    const tau = std.math.tau;
    const ccw_mid = @mod(am - a1, tau);
    const ccw_end = @mod(a2 - a1, tau);
    const sweep = if (ccw_mid <= ccw_end) ccw_end else ccw_end - tau;
    return .{ .cx = cx, .cy = cy, .r = r, .a1 = a1, .sweep = sweep };
}

/// Arc centerline length (chord length for a degenerate arc).
pub fn arcLength(arc: router.Arc) f64 {
    const c = circleOf(arc) orelse return dist(arc.p1, arc.p2);
    return c.r * @abs(c.sweep);
}

/// How many chords `tessellate` cuts this circle into at `max_sagitta`.
///
/// Factored out because the acceptance probes have to walk EXACTLY the chords
/// the emitters will draw (see `emit_sagitta_mm`); a probe deriving its own
/// count is a probe measuring copper that is never fabricated.
fn chordCount(c: Circle, max_sagitta: f64) usize {
    const s = @max(1e-4, max_sagitta);
    const step: f64 = if (c.r <= s)
        @abs(c.sweep)
    else
        2.0 * std.math.acos(std.math.clamp(1.0 - s / c.r, -1.0, 1.0));
    const raw = @ceil(@abs(c.sweep) / @max(step, 1e-3));
    return @max(1, @min(64, numeric.toCount(raw)));
}

/// The point a fraction `u` of the way along the `count`-chord polyline of `c`
/// — the copper itself, as opposed to the circle it approximates.
fn polylinePoint(c: Circle, arc: router.Arc, count: usize, u: f64) [2]f64 {
    const scaled = std.math.clamp(u, 0, 1) * @as(f64, @floatFromInt(count));
    const i: usize = @min(count -| 1, @as(usize, @intFromFloat(@floor(scaled))));
    const t = scaled - @as(f64, @floatFromInt(i));
    const a = chordVertex(c, arc, count, i);
    const b = chordVertex(c, arc, count, i + 1);
    return .{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
}

/// The `k`-th tessellation vertex of `c` cut into `count` chords. Vertex 0 is
/// `p1` and vertex `count` is `p2`, taken from the arc itself so the emitted
/// polyline starts and ends exactly on the copper it joins.
fn chordVertex(c: Circle, arc: router.Arc, count: usize, k: usize) [2]f64 {
    if (k == 0) return arc.p1;
    if (k >= count) return arc.p2;
    const frac = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
    const ang = c.a1 + c.sweep * frac;
    return .{ c.cx + c.r * @cos(ang), c.cy + c.r * @sin(ang) };
}

/// Chord-tessellate an arc for consumers without native arc support (DRC
/// geometry, Gerber, KiCad-sync fallback, WASM payloads). Chord count is
/// chosen so the sagitta never exceeds `max_sagitta` (clamped to 64 chords).
pub fn tessellate(
    arena: std.mem.Allocator,
    arc: router.Arc,
    max_sagitta: f64,
) std.mem.Allocator.Error![]const router.Track {
    const c = circleOf(arc) orelse {
        const one = try arena.alloc(router.Track, 1);
        one[0] = .{
            .x1 = arc.p1[0],
            .y1 = arc.p1[1],
            .x2 = arc.p2[0],
            .y2 = arc.p2[1],
            .layer = arc.layer,
            .width = arc.width,
            .net = arc.net,
        };
        return one;
    };
    const count = chordCount(c, max_sagitta);
    const tracks = try arena.alloc(router.Track, count);
    var prev = arc.p1;
    for (tracks, 1..) |*t, k| {
        const pt = chordVertex(c, arc, count, k);
        t.* = .{
            .x1 = prev[0],
            .y1 = prev[1],
            .x2 = pt[0],
            .y2 = pt[1],
            .layer = arc.layer,
            .width = arc.width,
            .net = arc.net,
        };
        prev = pt;
    }
    return tracks;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

fn fixturePlacement(
    nets: []const optimizer.FlatNet,
    rules: []const optimizer.NetRule,
) optimizer.Placement {
    var p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
    p.rules.net = rules;
    return p;
}

const rf_rule = optimizer.NetRule{
    .class = .{ .name = "rf" },
    .width = 0.3,
    .rf = .{ .max_freq_hz = 12e9 },
};
const fixture_nets = [_]optimizer.FlatNet{.{ .name = "RF1", .pins = &.{} }};

// spec: placement/bend-smooth - a net-class max-freq derives a 3x-width minimum bend radius
test "minBendRadius is 3x the effective trace width" {
    try testing.expectApproxEqAbs(0.9, minBendRadius(rf_rule, 0.127), 1e-12);
    const no_width = optimizer.NetRule{ .rf = .{ .max_freq_hz = 1e9 } };
    try testing.expectApproxEqAbs(3.0 * 0.127, minBendRadius(no_width, 0.127), 1e-12);
    try testing.expectEqual(@as(f64, 0), minBendRadius(optimizer.NetRule{ .width = 0.3 }, 0.127));
    try testing.expectEqual(@as(f64, 0), minBendRadius(null, 0.127));
}

// spec: placement/bend-smooth - a right-angle corner on a constrained net becomes a tangent arc at the target radius
test "right-angle corner opens to the largest arc its legs can host" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expect(res.changed);
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
    const arc = res.arcs[0];
    // Two free 5 mm legs, so the square corner aims at the GEOMETRIC maximum
    // rather than the 5W cap (r = 1.5): the whole leg bar one trace width of
    // straight run, r = 5 - 0.3 (- the endpoint-matching quantum). That is more
    // than 15x the trace width — an order above what the cap allowed.
    const r = 5.0 - 0.3 - snap;
    try testing.expect(r > 15.0 * 0.3);
    try testing.expectApproxEqAbs(5.0 - r, arc.p1[0], 1e-9);
    try testing.expectApproxEqAbs(0.0, arc.p1[1], 1e-9);
    try testing.expectApproxEqAbs(5.0, arc.p2[0], 1e-9);
    try testing.expectApproxEqAbs(r, arc.p2[1], 1e-9);
    // Mid point sits on the r circle centered at (5-r, r).
    const md = std.math.hypot(arc.pm[0] - (5.0 - r), arc.pm[1] - r);
    try testing.expectApproxEqAbs(r, md, 1e-9);
    // Legs are trimmed to the tangent points, and the reserved straight run at
    // each far end survives — the cut never swallows a leg whole.
    try testing.expectEqual(@as(usize, 2), res.tracks.len);
    try testing.expectApproxEqAbs(5.0 - r, res.tracks[0].x2, 1e-9);
    try testing.expectApproxEqAbs(r, res.tracks[1].y1, 1e-9);
    try testing.expect(res.tracks[0].x2 - res.tracks[0].x1 >= 0.3);
    try testing.expect(res.tracks[1].y2 - res.tracks[1].y1 >= 0.3);
}

// spec: placement/bend-smooth - a corner opens to the largest radius that fits its legs above the minimum
test "leg-limited corner lands between the 3W floor and the 5W cap unflagged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // 1.0 mm legs: the largest fitting radius is ~1.0 — above the 0.9 floor
    // (so no sharp_bend flag) but short of the 1.5 cap. Legs this short make
    // the square corner's maximal claim (a leg less its straight reserve,
    // 0.7 mm) the SMALLER of the two aims, so the corner keeps the leg-limited
    // width-multiple budget it always had: aiming bigger never smooths tighter.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = 1, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
    const r = arcLength(res.arcs[0]) / (std.math.pi / 2.0);
    try testing.expect(r > 0.9 and r < 1.5);
}

// spec: placement/bend-smooth - corners that cannot fit the radius smooth smaller and flag sharp_bend
test "short legs shrink the radius and flag the corner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.5, .y1 = 0, .x2 = 0.5, .y2 = 0.5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 1), res.sharp.len);
    try testing.expect(res.sharp[0].radius > 0);
    try testing.expect(res.sharp[0].radius < 0.9);
    try testing.expectApproxEqAbs(0.9, res.sharp[0].required, 1e-12);
}

// spec: placement/bend-smooth - a net-class min-bend-radius overrides the 3x floor for the aim and flag threshold
test "min-bend-radius raises the aim above the cap and lowers the flag threshold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // (a) A floor ABOVE the 5x aim cap (6x width): long legs let the corner
    // open all the way to the 6x radius (1.8 mm) — the aim rises to meet the
    // floor, so it is NOT flagged. Under the plain 5x cap the arc would stall
    // at 1.5 mm, short of the 1.8 mm floor, and flag.
    //
    // Measured on a 45-degree bend: a SQUARE corner ignores the width-multiple
    // aim entirely (it takes the whole leg), so the aim ratio is only
    // observable on the lattice's other turn.
    const gentle = optimizer.NetRule{ .width = 0.3, .rf = .{ .max_freq_hz = 12e9, .min_bend_ratio = 6 } };
    try testing.expectApproxEqAbs(1.8, minBendRadius(gentle, 0.127), 1e-12);
    const long = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 9, .y2 = 4, .layer = 0, .width = 0.3, .net = 0 },
    };
    const g = try apply(arena, .{ .placement = fixturePlacement(&fixture_nets, &.{gentle}), .params = .{}, .tracks = &long });
    try testing.expectEqual(@as(usize, 1), g.arcs.len);
    try testing.expectEqual(@as(usize, 0), g.sharp.len);
    // The arc reached the 6x floor (1.8 mm) — the aim lifted above the 5x cap.
    try testing.expectApproxEqAbs(1.8, arcLength(g.arcs[0]) / (std.math.pi / 4.0), 1e-6);

    // (b) A floor BELOW the default (2x width): a 0.7 mm-leg corner opens to
    // r ≈ 0.7 mm. Against the 2x floor (0.6 mm) that is compliant — arc, no
    // flag; the IDENTICAL corner on the default 3x class (0.9 mm floor) IS
    // flagged sharp.
    const short = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.7, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.7, .y1 = 0, .x2 = 0.7, .y2 = 0.7, .layer = 0, .width = 0.3, .net = 0 },
    };
    const tight = optimizer.NetRule{ .width = 0.3, .rf = .{ .max_freq_hz = 12e9, .min_bend_ratio = 2 } };
    const t = try apply(arena, .{ .placement = fixturePlacement(&fixture_nets, &.{tight}), .params = .{}, .tracks = &short });
    try testing.expectEqual(@as(usize, 1), t.arcs.len);
    try testing.expectEqual(@as(usize, 0), t.sharp.len);
    const d = try apply(arena, .{ .placement = fixturePlacement(&fixture_nets, &.{rf_rule}), .params = .{}, .tracks = &short });
    try testing.expectEqual(@as(usize, 1), d.sharp.len);
    try testing.expectApproxEqAbs(0.9, d.sharp[0].required, 1e-12);
}

// spec: placement/bend-smooth - a bend that would crowd foreign copper shrinks its radius until the cut clears
test "foreign copper in the elbow shrinks the bend radius" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF1", .pins = &.{} },
        .{ .name = "OTHER", .pins = &.{} },
    };
    const placement = fixturePlacement(&nets, &.{ rf_rule, .{} });
    // 1.8 mm legs: long enough for the full 5W cut, short enough that the
    // square corner's maximal claim (1.8 less its 0.3 straight reserve) lands
    // just under it — so this measures the ladder and its refinement, not the
    // aim. The wide-open version of the same corner is the descent test below.
    const tracks = [_]router.Track{
        .{ .x1 = 3.2, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 1.8, .layer = 0, .width = 0.3, .net = 0 },
    };
    // A small foreign via inside the corner elbow: legal against the original
    // legs (0.45 mm away, needs 0.383) but within reach of the full 3W cut.
    // The bend backs off to the LARGEST clearing radius instead of merely
    // accepting the first coarse 0.7-ladder rung. The geometric threshold is
    // about 0.588 mm; the old ladder stopped at 0.5145 mm.
    //
    // 0.588 rather than the 0.605 this measured while the probe walked the
    // ideal circle: the copper is the CHORDS, which cut to the concave side —
    // the side this via is on — so the clearing radius the emitted polyline
    // actually earns is a hair smaller (see `emit_sagitta_mm`).
    const vias = [_]router.Via{.{ .x = 4.55, .y = 0.45, .dia = 0.2, .net = 1 }};
    const res = try apply(arena, .{
        .placement = placement,
        .params = .{},
        .tracks = &tracks,
        .vias = &vias,
    });
    try testing.expect(res.changed);
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 1), res.sharp.len);
    try testing.expect(res.sharp[0].radius > 0.58);
    try testing.expect(res.sharp[0].radius < 0.60);
}

// spec: placement/bend-smooth - a maximal right-angle aim descends until the clearance oracle accepts the cut
test "copper in the cut walks the maximal right-angle aim back down" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF1", .pins = &.{} },
        .{ .name = "OTHER", .pins = &.{} },
    };
    const placement = fixturePlacement(&nets, &.{ rf_rule, .{} });
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    // Free, this corner takes the whole leg (r = 4.7). A foreign via parked on
    // that maximal arc's belly refuses it — the aim is only ever an aim, and
    // the same 0.7 ladder plus refinement walks it back to the largest radius
    // whose cut clears (~3.66 mm here), still far past the 1.5 mm width cap.
    const free = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    const free_r = arcLength(free.arcs[0]) / (std.math.pi / 2.0);
    try testing.expectApproxEqAbs(5.0 - 0.3 - snap, free_r, 1e-6);

    const vias = [_]router.Via{.{ .x = 3.6235, .y = 1.3765, .dia = 0.2, .net = 1 }};
    const res = try apply(arena, .{
        .placement = placement,
        .params = .{},
        .tracks = &tracks,
        .vias = &vias,
    });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
    const r = arcLength(res.arcs[0]) / (std.math.pi / 2.0);
    try testing.expect(r < free_r - 0.5);
    try testing.expect(r > 1.5);

    // And the descent stopped at a radius that genuinely CLEARS: every chord
    // the board will carry keeps the whole trace-to-via rule from it (half the
    // trace width + the via radius + the class clearance = 0.15 + 0.1 + 0.127),
    // so the bigger aim bought no clearance relief.
    for (try tessellate(arena, res.arcs[0], emit_sagitta_mm)) |chord| {
        try testing.expect(pointSegDist(vias[0].x, vias[0].y, chord) >= 0.377 - 1e-6);
    }
}

// spec: placement/bend-smooth - a 45-degree bend's arc stays inside its corner wedge
test "45-degree bend arc geometry is correct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 4, .y1 = 0, .x2 = 8, .y2 = 4, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
    const arc = res.arcs[0];
    // Every point of the arc stays within the tangent length of the apex —
    // with a wrong center distance the mid/samples wander far outside.
    const t = 1.5 * @tan(std.math.pi / 8.0);
    for (try tessellate(arena, arc, 0.005)) |ch| {
        try testing.expect(std.math.hypot(ch.x2 - 4.0, ch.y2 - 0.0) <= t + 1e-6);
    }
    // And the arc's own radius (from its three points) is the full 5W cap.
    try testing.expectApproxEqAbs(1.5 * std.math.pi / 4.0, arcLength(arc), 1e-6);
}

// spec: placement/bend-smooth - consecutive corners share a leg fairly and both smooth
test "a Z-jog smooths both corners" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // Two 45-degree corners sharing a 0.85 mm diagonal — the LO1_DRIVE shape.
    // Both wants fit the shared leg, so both bends reach the full 3W radius.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 4, .y1 = 0, .x2 = 4.6, .y2 = 0.6, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 4.6, .y1 = 0.6, .x2 = 4.6, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 2), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
}

/// The lowest and highest tangent points `arcs` leave on the vertical line
/// `x`, between `y0` and `y1` — the pair a shared-leg test must see ordered and
/// held apart. `{+inf, -inf}` when no arc touches that stretch of leg.
fn tangentSpanOnX(arcs: []const router.Arc, x: f64, y0: f64, y1: f64) [2]f64 {
    var span = [2]f64{ std.math.inf(f64), -std.math.inf(f64) };
    for (arcs) |a| for ([_][2]f64{ a.p1, a.p2 }) |pt| {
        if (@abs(pt[0] - x) > 1e-9 or pt[1] < y0 or pt[1] > y1) continue;
        span[0] = @min(span[0], pt[1]);
        span[1] = @max(span[1], pt[1]);
    };
    return span;
}

// spec: placement/bend-smooth - two right-angle corners split the leg between them instead of overlapping their cuts
test "two right-angle corners share one leg without overlapping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // A staircase: two OPPOSITE-sense square corners (so no zigzag merge) whose
    // 4 mm shared leg both want to eat whole. Each takes its 1.5 mm width-cap
    // share plus half of what is left over after the straight reserve, so both
    // open to r = 1.85 — past the cap, and 0.3 mm of straight copper survives
    // between the two tangent points instead of the cuts running through each
    // other. The 5 mm outer legs are free, so the shared leg is what binds.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 4, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 4, .x2 = 10, .y2 = 4, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 2), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
    const half_spare = (4.0 - snap - 0.3 - 2.0 * 1.5) / 2.0;
    const want_r = 1.5 + half_spare;
    for (res.arcs) |a| {
        const c = circleOf(a) orelse return error.ExpectedArc;
        try testing.expectApproxEqAbs(want_r, c.r, 1e-6);
        try testing.expect(c.r > 1.5); // past the 5W cap the aim used to stop at
    }
    // The two tangent points ON the shared leg: ordered, distinct, and a full
    // straight reserve apart — the trims split the leg, they do not overlap.
    const span = tangentSpanOnX(res.arcs, 5.0, snap, 4.0 - snap);
    try testing.expectApproxEqAbs(want_r, span[0], 1e-6);
    try testing.expectApproxEqAbs(4.0 - want_r, span[1], 1e-6);
    try testing.expectApproxEqAbs(0.3 + snap, span[1] - span[0], 1e-6);
}

// spec: placement/bend-smooth - pad keep-away measures the pad's true box, not a bounding disc
test "elongated foreign pad beyond clearance does not veto the bend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const other_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U9", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF1", .pins = &.{} },
        .{ .name = "OTHER", .pins = &other_pins },
    };
    // A wide, thin foreign pad above the corner: its true box clears the
    // near-cap cut, while its bounding disc (r ~1.2) would veto every retry.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 2.4, .h = 0.3 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U9",
        .kind = .passive,
        .hw = 1.2,
        .hh = 0.15,
        .pads = &pad,
        .fallback = false,
        .x = 4.7,
        .y = 1.6,
    }};
    var placement = fixturePlacement(&nets, &.{ rf_rule, .{} });
    placement.parts = &parts;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
}

// spec: placement/bend-smooth - a pad's own quarter rotation orients its keep-away box
test "pad-local rotation orients the probe box like the maze and DRC" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const other_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U9", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF1", .pins = &.{} },
        .{ .name = "OTHER", .pins = &other_pins },
    };
    // The same wide, thin world shape as the elongated-pad test, but spelled
    // as a TALL local pad turned flat by its own `(pos … 90)` rotation — the
    // mixer/U15 pattern. Ignoring pad.rot builds a phantom 0.3x2.4 tall box
    // that reaches down into the corner elbow and vetoes every arc retry.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 2.4, .rot = 90 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U9",
        .kind = .passive,
        .hw = 1.2,
        .hh = 0.15,
        .pads = &pad,
        .fallback = false,
        .x = 4.7,
        .y = 1.6,
    }};
    var placement = fixturePlacement(&nets, &.{ rf_rule, .{} });
    placement.parts = &parts;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
}

// spec: placement/bend-smooth - a sub-width pad-entry jog collapses instead of vetoing the adjacent bend
test "tiny jog beside a corner collapses and the bend still smooths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // A long run, a 0.058 mm off-grid jog (the maze's pad-entry artifact),
    // then a long run up: without simplification both corners at the jog
    // would flag radius 0; with it the jog collapses to one smoothable bend.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4.95, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 4.95, .y1 = 0, .x2 = 5, .y2 = 0.03, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0.03, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
}

// spec: placement/bend-smooth - arcs stay clear of the straight escape reserve at a pad exit
test "escape reserve holds the arc off the first millimetre out of a pad" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rf_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{.{ .name = "RF1", .pins = &rf_pins }};
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = 0,
        .y = 0,
    }};
    var escape_rule = rf_rule;
    escape_rule.rf.escape_mm = 1.0;
    var placement = fixturePlacement(&nets, &.{escape_rule});
    placement.parts = &parts;
    // The chain leaves the pad at (0,0) and turns at 2.0 mm. Unreserved, the
    // square corner would eat the leg down to 0.3 mm from the pad; the 1.0 mm
    // escape reserve holds its tangent point at exactly the reserve boundary —
    // the maximal aim is clamped by the reserve just as the width cap was.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expect(res.arcs[0].p1[0] >= 1.0 - 1e-9);

    // spec-companion: a shallow pad-entry stub kink INSIDE the reserve (the
    // maze's off-grid gateway quantization, ~6 degrees at 0.5 mm) is not a
    // bend — it gets neither an arc nor a sharp_bend flag.
    const kinked = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0.05, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.5, .y1 = 0.05, .x2 = 3, .y2 = 0.05, .layer = 0, .width = 0.3, .net = 0 },
    };
    const quiet = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &kinked });
    try testing.expectEqual(@as(usize, 0), quiet.arcs.len);
    try testing.expectEqual(@as(usize, 0), quiet.sharp.len);
}

// spec: placement/bend-smooth - unconstrained nets and preserved copper pass through untouched
test "unconstrained and preserved copper pass through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const plain = fixturePlacement(&fixture_nets, &.{.{ .width = 0.3 }});
    const untouched = try apply(arena, .{ .placement = plain, .params = .{}, .tracks = &tracks });
    try testing.expect(!untouched.changed);
    try testing.expectEqual(@as(usize, 2), untouched.tracks.len);

    const rf = fixturePlacement(&fixture_nets, &.{rf_rule});
    const preserved = try apply(arena, .{ .placement = rf, .params = .{}, .tracks = &tracks, .keep = tracks.len });
    try testing.expect(!preserved.changed);
}

// spec: placement/bend-smooth - tessellated arc chords stay on the true circle within the sagitta bound
test "tessellation follows the circle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Quarter circle r=0.9 centered (4.1, 0.9): from (4.1,0) via the point
    // nearest the corner apex to (5,0.9).
    const inv_sqrt2 = 1.0 / @sqrt(2.0);
    const arc = router.Arc{
        .p1 = .{ 4.1, 0 },
        .pm = .{ 4.1 + 0.9 * inv_sqrt2, 0.9 - 0.9 * inv_sqrt2 },
        .p2 = .{ 5.0, 0.9 },
        .layer = 0,
        .width = 0.3,
        .net = 0,
    };
    const chords = try tessellate(arena, arc, 0.02);
    try testing.expect(chords.len >= 3);
    try testing.expectApproxEqAbs(arc.p1[0], chords[0].x1, 1e-12);
    try testing.expectApproxEqAbs(arc.p2[1], chords[chords.len - 1].y2, 1e-12);
    for (chords) |ch| {
        const r = std.math.hypot(ch.x2 - 4.1, ch.y2 - 0.9);
        try testing.expectApproxEqAbs(0.9, r, 1e-6);
    }
    // Quarter circle of r=0.9 is ~1.4137 mm.
    try testing.expectApproxEqAbs(0.9 * std.math.pi / 2.0, arcLength(arc), 1e-6);
}

// spec: placement/bend-smooth - an asymmetric biarc retry is tangent to both legs and continuous at its join
test "an asymmetric biarc is tangent to both legs and joins continuously" {
    // The asymmetric retry (behaviour used when a one-sided obstacle crowds the
    // symmetric fillet): a 90-degree corner at (5,0), incoming from the west,
    // outgoing north, with UNEQUAL trims (1.2 mm back on the roomy incoming
    // leg, 0.4 mm on the tight outgoing one). The two arcs must (a) start/end
    // ON the legs at those trims, (b) meet at a shared join, and (c) leave/enter
    // tangent to the legs — the properties a valid biarc guarantees.
    const g = BendGeom{
        .apex = .{ 5, 0 },
        .u = .{ 1, 0 }, // travel INTO the apex (heading east)
        .v = .{ 0, 1 }, // travel OUT of the apex (heading north)
        .defl = std.math.pi / 2.0,
        .net = 0,
        .layer = 0,
        .width = 0.3,
    };
    // Give the FIRST arc a modest 15-degree share (the roomy incoming leg
    // hosts the gentle arc; the tight leg's arc turns the rest).
    const bi = biarcFit(g, 1.2, 0.4, std.math.pi / 12.0) orelse return error.ExpectedBiarc;
    // (a) tangent points sit at the requested trims on each leg.
    try testing.expectApproxEqAbs(5.0 - 1.2, bi.arc1.p1[0], 1e-9);
    try testing.expectApproxEqAbs(0.0, bi.arc1.p1[1], 1e-9);
    try testing.expectApproxEqAbs(5.0, bi.arc2.p2[0], 1e-9);
    try testing.expectApproxEqAbs(0.4, bi.arc2.p2[1], 1e-9);
    // (b) the two arcs meet exactly at the join.
    try testing.expectApproxEqAbs(bi.arc1.p2[0], bi.arc2.p1[0], 1e-9);
    try testing.expectApproxEqAbs(bi.arc1.p2[1], bi.arc2.p1[1], 1e-9);
    try testing.expectApproxEqAbs(bi.join[0], bi.arc1.p2[0], 1e-9);
    // (c) tangency: arc1's centre is perpendicular to the incoming dir at p1,
    // arc2's centre perpendicular to the outgoing dir at p2 (radius ⟂ tangent).
    const c1 = circleOf(bi.arc1) orelse return error.ExpectedArc;
    const c2 = circleOf(bi.arc2) orelse return error.ExpectedArc;
    // radius vector at p1 is (p1 - O1); its dot with u must be ~0 (⟂).
    try testing.expectApproxEqAbs(0.0, (bi.arc1.p1[0] - c1.cx) * g.u[0] + (bi.arc1.p1[1] - c1.cy) * g.u[1], 1e-6);
    try testing.expectApproxEqAbs(0.0, (bi.arc2.p2[0] - c2.cx) * g.v[0] + (bi.arc2.p2[1] - c2.cy) * g.v[1], 1e-6);
    // And unequal trims genuinely give unequal radii (a real biarc, not a fillet).
    try testing.expect(@abs(c1.r - c2.r) > 1e-3);
}

// spec: placement/bend-smooth - a starved same-sense corner pair merges at the virtual apex to reach the floor radius
test "a starved Z-jog merges into one floor-radius bend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // Two same-sense 45-degree corners joined by a 0.28 mm shared leg — too
    // short for either fillet to reach the floor (each would flag). The outer
    // legs are long, so merging the pair into one 90-degree bend at the virtual
    // apex (3.2, 0) opens to the full radius: ONE arc, no sharp_bend.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 3, .y1 = 0, .x2 = 3.2, .y2 = 0.2, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 3.2, .y1 = 0.2, .x2 = 3.2, .y2 = 3, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
    const c = circleOf(res.arcs[0]) orelse return error.ExpectedArc;
    try testing.expect(c.r >= 0.9);
}

// spec: placement/bend-smooth - a candidate arc that would bulge past the board outline is rejected, keeping smoothed copper inside the edge
test "an arc that would cross the board edge is rejected, flagging sharp" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A right-angle corner whose bottom leg runs along y = 0 — the board's
    // bottom edge. Unconstrained it opens to the full leg-length fillet, but
    // EVERY fillet radius has its tangent point on that y = 0 leg, so the arc
    // copper sits on/over the edge. With the outline present the smoother must
    // reject the fillet and flag the corner sharp rather than ship an arc that
    // bulges off the board (the exact failure the maze would never route but a
    // post-route smoothing pass could re-introduce).
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    var boarded = fixturePlacement(&fixture_nets, &.{rf_rule});
    boarded.board_rect = .{ .minx = -1, .miny = 0, .w = 12, .h = 11 };
    const res = try apply(arena, .{ .placement = boarded, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 0), res.arcs.len);
    try testing.expectEqual(@as(usize, 1), res.sharp.len);
    // The SAME corner with no outline opens to the full arc — proving the
    // rejection is the board-edge constraint, not the corner geometry.
    const free = try apply(arena, .{ .placement = fixturePlacement(&fixture_nets, &.{rf_rule}), .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), free.arcs.len);
    try testing.expectEqual(@as(usize, 0), free.sharp.len);

    // A polygon outline that pulls the bottom edge DOWN below the arc (a real
    // board that clears the corner) leaves the full fillet untouched — the
    // veto fires only when copper truly leaves the board.
    const clear_poly = [_][2]f64{ .{ -1, -1 }, .{ 11, -1 }, .{ 11, 11 }, .{ -1, 11 } };
    var polyed = fixturePlacement(&fixture_nets, &.{rf_rule});
    polyed.board_rect = .{ .minx = -1, .miny = -1, .w = 12, .h = 12 };
    polyed.board_poly = &clear_poly;
    const okp = try apply(arena, .{ .placement = polyed, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), okp.arcs.len);
    try testing.expectEqual(@as(usize, 0), okp.sharp.len);
}

// spec: placement/bend-smooth - an under-floor arc flags the sharp_bend marker on the arc, not at the bare vertex
test "an under-floor arc flags on the arc midpoint not the vertex" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // Equal 0.5 mm legs, 90-degree: the symmetric fillet lands at r = 0.5 mm,
    // under the 0.9 mm floor (and the biarc cannot help equal legs) — so it is
    // flagged, but the marker must sit on the placed arc's midpoint, not float
    // at the bare vertex (5, 0) the arc no longer passes through.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.5, .y1 = 0, .x2 = 0.5, .y2 = 0.5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 1), res.sharp.len);
    const m = res.sharp[0];
    // On the arc midpoint …
    try testing.expectApproxEqAbs(res.arcs[0].pm[0], m.x, 1e-9);
    try testing.expectApproxEqAbs(res.arcs[0].pm[1], m.y, 1e-9);
    // … and demonstrably NOT the vertex (0.5, 0).
    try testing.expect(std.math.hypot(m.x - 0.5, m.y - 0.0) > 0.1);
}

// spec: placement/bend-smooth - a corner arc within five percent of the floor radius is not flagged sharp_bend
test "an arc within 5 percent of the floor is not flagged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // Equal 0.87 mm legs, 90-degree: r = 0.87 mm — under the 0.9 mm floor but
    // within 5% of it (>= 0.855 mm), so it is a sub-percent shortfall, not a
    // finding: an arc is placed and NOT flagged.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.87, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.87, .y1 = 0, .x2 = 0.87, .y2 = 0.87, .layer = 0, .width = 0.3, .net = 0 },
    };
    const res = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);
    try testing.expectEqual(@as(usize, 0), res.sharp.len);
    // Genuinely under the 0.9 mm floor — it is the tolerance band, not a
    // compliant bend.
    const c = circleOf(res.arcs[0]) orelse return error.ExpectedArc;
    try testing.expect(c.r < 0.9 and c.r >= 0.855);
}

/// A stand-in for the router's clearance oracle: it refuses any segment that
/// enters an axis-aligned box. The box is a KEEPOUT — copper-free space that is
/// not copper, not a pad and not outside the outline, so `GeomProbe` cannot see
/// it at all and only an external probe can veto against it.
const KeepoutBoxProbe = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    fn clear(self: KeepoutBoxProbe, _: u8, a: [2]f64, b: [2]f64) bool {
        for (0..33) |k| {
            const f = @as(f64, @floatFromInt(k)) / 32.0;
            const x = a[0] + (b[0] - a[0]) * f;
            const y = a[1] + (b[1] - a[1]) * f;
            if (x >= self.x0 and x <= self.x1 and y >= self.y0 and y <= self.y1) return false;
        }
        return true;
    }
};

/// The first `sharp` finding on `net`, or null. A helper so a test can read one
/// leg's report without a second top-level loop in its body.
fn sharpOnNet(list: []const router.SharpBend, net: i32) ?router.SharpBend {
    for (list) |sb| if (sb.net == net) return sb;
    return null;
}

// spec: placement/bend-smooth - an arc the router's own clearance oracle refuses is rejected even when the geometric probe accepts it
test "an arc through a keepout the geometric probe cannot see is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    // The wide-open corner from the very first test: with tracks, vias, pads
    // and the outline the only obstacles it smooths to one clean maximal arc.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const bare = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), bare.arcs.len);
    try testing.expectEqual(@as(usize, 0), bare.sharp.len);

    // Now declare a keepout filling the corner's cut — every candidate arc's
    // belly lies inside the right triangle between the two legs, and the box
    // covers that triangle's interior while touching neither leg.
    const keep = KeepoutBoxProbe{ .x0 = 3.45, .y0 = 0.001, .x1 = 4.999, .y1 = 1.499 };
    const guarded = try apply(arena, .{
        .placement = placement,
        .params = .{},
        .tracks = &tracks,
        .ext = ExtProbe.bind(KeepoutBoxProbe, &keep, 0),
    });
    // No arc survives — not the 5W one, not the chamfer at the bottom of the
    // shrink ladder — and the corner is reported instead of quietly accepted.
    try testing.expectEqual(@as(usize, 0), guarded.arcs.len);
    try testing.expectEqual(@as(usize, 1), guarded.sharp.len);
    try testing.expectEqual(@as(f64, 0), guarded.sharp[0].radius);
    try testing.expectApproxEqAbs(5.0, guarded.sharp[0].x, 1e-9);
    try testing.expectApproxEqAbs(0.0, guarded.sharp[0].y, 1e-9);

    // The oracle is aimed at ONE net: same-net copper is free to it, so a group
    // of any other net must pass through untouched rather than be judged wrong.
    const foreign = try apply(arena, .{
        .placement = placement,
        .params = .{},
        .tracks = &tracks,
        .ext = ExtProbe.bind(KeepoutBoxProbe, &keep, 7),
    });
    try testing.expectEqual(@as(usize, 1), foreign.arcs.len);
}

/// An `ExtProbe` that admits everything and REMEMBERS every segment it was
/// asked about, so a test can compare the copper the oracle judged with the
/// copper the emitters will actually draw.
const RecordProbe = struct {
    arena: std.mem.Allocator,
    seen: *std.ArrayList([2][2]f64),

    fn clear(self: RecordProbe, _: u8, a: [2]f64, b: [2]f64) bool {
        self.seen.append(self.arena, .{ a, b }) catch return false;
        return true;
    }
};

/// Was `chord` one of the segments the oracle was asked about?
fn wasJudged(seen: []const [2][2]f64, chord: router.Track) bool {
    for (seen) |s| {
        if (@abs(s[0][0] - chord.x1) < 1e-12 and @abs(s[0][1] - chord.y1) < 1e-12 and
            @abs(s[1][0] - chord.x2) < 1e-12 and @abs(s[1][1] - chord.y2) < 1e-12) return true;
    }
    return false;
}

// spec: placement/bend-smooth - the clearance oracle judges an arc as exactly the chord polyline the emitters draw, so no chord is fabricated at a clearance no probe measured
test "an arc is judged on the chords it will be drawn as" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    var seen: std.ArrayList([2][2]f64) = .empty;
    const recorder = RecordProbe{ .arena = arena, .seen = &seen };
    const res = try apply(arena, .{
        .placement = placement,
        .params = .{},
        .tracks = &tracks,
        .ext = ExtProbe.bind(RecordProbe, &recorder, 0),
    });
    try testing.expectEqual(@as(usize, 1), res.arcs.len);

    // Every chord the board will carry was itself put to the oracle. Probing a
    // FINER walk (or the ideal circle) measures metal nobody fabricates: a
    // chord cuts to the concave side, i.e. toward whatever crowds the corner,
    // so the drawn copper would sit up to one sagitta nearer than what passed.
    const chords = try tessellate(arena, res.arcs[0], emit_sagitta_mm);
    try testing.expect(chords.len >= 2);
    for (chords) |chord| try testing.expect(wasJudged(seen.items, chord));

    // …and a chord really is not the circle: its midpoint lies strictly inside.
    const c = circleOf(res.arcs[0]).?;
    const mid = [2]f64{ (chords[0].x1 + chords[0].x2) / 2, (chords[0].y1 + chords[0].y2) / 2 };
    try testing.expect(std.math.hypot(mid[0] - c.cx, mid[1] - c.cy) < c.r - 1e-9);
}

// spec: placement/bend-smooth - detect reports a constrained net's under-radius corners without moving any copper
test "detect measures corners and leaves every track exactly where it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two legs of a pair, each with its own right-angle corner, both on an
    // RF-disciplined class — the `(diff-pair …) (max-freq …)` shape.
    const pair_nets = [_]optimizer.FlatNet{
        .{ .name = "D_P", .pins = &.{} },
        .{ .name = "D_N", .pins = &.{} },
    };
    const placement = fixturePlacement(&pair_nets, &.{ rf_rule, rf_rule });
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0, .y1 = 1, .x2 = 4, .y2 = 1, .layer = 0, .width = 0.3, .net = 1 },
        .{ .x1 = 4, .y1 = 1, .x2 = 4, .y2 = 5, .layer = 0, .width = 0.3, .net = 1 },
    };
    const sharp = try detect(arena, .{ .placement = placement, .params = .{}, .tracks = &tracks });
    // One corner per leg, each reported against its own net at a zero achieved
    // radius — the honest reading of copper nothing smoothed.
    try testing.expectEqual(@as(usize, 2), sharp.len);
    const on_p = sharpOnNet(sharp, 0) orelse return error.NoFindingOnP;
    const on_n = sharpOnNet(sharp, 1) orelse return error.NoFindingOnN;
    try testing.expectEqual(@as(f64, 0), on_p.radius);
    try testing.expectEqual(@as(f64, 0), on_n.radius);
    try testing.expectApproxEqAbs(0.9, on_p.required, 1e-12);
    try testing.expectApproxEqAbs(0.9, on_n.required, 1e-12);
    // And the copper is untouched: no arc, no trim, no re-emitted leg — which
    // is what keeps a coupled pair's skew equalization intact.
    const res = try apply(arena, .{
        .placement = placement,
        .params = .{},
        .tracks = &tracks,
        .detect_only = true,
    });
    try testing.expect(!res.changed);
    try testing.expectEqual(@as(usize, 0), res.arcs.len);
    try testing.expectEqual(tracks.len, res.tracks.len);
    for (tracks, res.tracks) |want, got| {
        try testing.expectEqual(want.x1, got.x1);
        try testing.expectEqual(want.y1, got.y1);
        try testing.expectEqual(want.x2, got.x2);
        try testing.expectEqual(want.y2, got.y2);
    }
}

fn persistedCopper(arena: std.mem.Allocator, smoothed: Result) std.mem.Allocator.Error![]const router.Track {
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, smoothed.tracks);
    for (smoothed.arcs) |arc| {
        const chords = try tessellate(arena, arc, 0.01);
        try tracks.appendSlice(arena, chords);
    }
    return tracks.toOwnedSlice(arena);
}

// spec: placement/bend-smooth - detect measures a persisted chord run as one circular bend instead of treating its tessellation vertices as hard corners
test "detect reconstructs the radius of persisted arc chords" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&fixture_nets, &.{rf_rule});

    const roomy = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const compliant = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &roomy });
    const compliant_chords = try persistedCopper(arena, compliant);
    const no_findings = try detect(arena, .{ .placement = placement, .params = .{}, .tracks = compliant_chords });
    try testing.expectEqual(@as(usize, 0), no_findings.len);

    const cramped = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.5, .y1 = 0, .x2 = 0.5, .y2 = 0.5, .layer = 0, .width = 0.3, .net = 0 },
    };
    const underfloor = try apply(arena, .{ .placement = placement, .params = .{}, .tracks = &cramped });
    const underfloor_chords = try persistedCopper(arena, underfloor);
    const one_finding = try detect(arena, .{ .placement = placement, .params = .{}, .tracks = underfloor_chords });
    try testing.expectEqual(@as(usize, 1), one_finding.len);
    try testing.expectApproxEqAbs(0.5, one_finding[0].radius, 0.02);
    try testing.expectApproxEqAbs(0.9, one_finding[0].required, 1e-12);
}

/// A `simplifyChain` probe that vetoes any segment passing within `r` of the
/// point `(ox, oy)` — a stand-in for the one foreign pad that matters in the
/// jog-collapse scenario below.
const PointVetoChainProbe = struct {
    ox: f64,
    oy: f64,
    r: f64,

    fn segClear(self: PointVetoChainProbe, a: [2]f64, b: [2]f64) bool {
        return pointSegDist(self.ox, self.oy, .{
            .x1 = a[0],
            .y1 = a[1],
            .x2 = b[0],
            .y2 = b[1],
            .layer = 0,
            .width = 0,
            .net = 0,
        }) >= self.r;
    }
};

// spec: placement/bend-smooth - a sub-width jog collapse that would sweep the adjacent run into foreign copper is refused
test "a jog collapse that drags a long run onto a foreign pad is refused" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // barracuda's CP_FILT in miniature: a 4 mm run into the op-amp, ending in a
    // 0.09 mm pad-entry jog — under half the 0.2 mm width, so the collapse rule
    // wants to slide the joint onto the chain's end point. Doing so tilts the
    // WHOLE 4 mm run, which is what swept it across the neighbouring ground pad.
    const raw = Chain{
        .pts = try arena.dupe([2]f64, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 0.09 } }),
        .widths = try arena.dupe(f64, &.{ 0.2, 0.2 }),
    };

    // With nothing in the way the jog collapses as before: two points, one run.
    const free = try simplifyChain(arena, raw, AllClearChainProbe{});
    try testing.expectEqual(@as(usize, 2), free.pts.len);
    try testing.expect(@abs(free.pts[1][1] - 0.09) < 1e-9);

    // Foreign copper 0.06 mm off the original run's midpoint clears it (0.06 >
    // 0.03) but not the tilted one (the tilt puts the midpoint 0.045 away, a
    // 0.015 mm gap) — so the jog stays and the run keeps its verified path.
    const blocked = try simplifyChain(arena, raw, PointVetoChainProbe{ .ox = 2, .oy = 0.06, .r = 0.03 });
    try testing.expectEqual(@as(usize, 3), blocked.pts.len);
    try testing.expect(@abs(blocked.pts[1][0] - 4) < 1e-9);
    try testing.expect(@abs(blocked.pts[1][1]) < 1e-9);
}
