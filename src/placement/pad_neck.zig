//! Pad-local width-transition shaping for generated copper.
//!
//! A net class may keep a wide nominal trunk while authorizing a short narrow
//! escape at SMD lands. A single-ended controlled-impedance class instead
//! transitions from every actual SMD launch span or through-via annulus,
//! whether wider or narrower, to its nominal line. Controlled-width signals
//! search with their nominal class geometry. Current-rated power nets instead
//! search a fabrication-legal centreline, then this pass grows them toward
//! their electrical target under exact clearance and adds pad/congestion
//! tapers. At the final output boundary the pass subdivides only width-changing
//! spans into fabrication-real constant-width slices.
//!
//! Constant-width slices are intentional. They are understood identically by
//! the route viewer, DRC, Gerber writer, KiCad writer, and saved-layout schema;
//! a 25 um slice pitch makes the union visually smooth without adding a second
//! copper primitive whose clearance and persistence could drift.

const std = @import("std");
const flat_netlist = @import("../flat_netlist.zig");
const pad_neck_profile = @import("../pad_neck_profile.zig");
const copper_support = @import("copper_support.zig");
const optimizer = @import("optimizer.zig");
const pose_math = @import("pose_math.zig");
const power_capacity = @import("power_capacity.zig");
const router = @import("router.zig");

const eps: f64 = 1e-9;
const taper_step_mm: f64 = 0.025;
const adaptive_step_mm: f64 = 0.05;
const adaptive_width_iterations: usize = 14;
/// A 45-degree copper flank changes full width by twice the axial distance.
const adaptive_width_per_length: f64 = 2;
const default_neck_length_mm: f64 = 0.75;
const default_taper_length_mm: f64 = 0.35;
const rf_taper_widths: f64 = 1.2;

const Pad = struct {
    at: [2]f64,
    layer: u8,
    half_w: f64,
    half_h: f64,
    axis_x: [2]f64,
};

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn samePoint(a: [2]f64, b: [2]f64) bool {
    return dist(a, b) <= router.clearance_eps;
}

fn profileWidth(distance: f64, neck: f64, nominal: f64, neck_len: f64, taper_len: f64) f64 {
    if (distance <= neck_len or taper_len <= eps) return neck;
    if (distance >= neck_len + taper_len) return nominal;
    const f = (distance - neck_len) / taper_len;
    return neck + (nominal - neck) * std.math.clamp(f, 0, 1);
}

fn unit(v: [2]f64) ?[2]f64 {
    const len = std.math.hypot(v[0], v[1]);
    if (len <= eps) return null;
    return .{ v[0] / len, v[1] / len };
}

fn localComponents(pad: Pad, direction: [2]f64) [2]f64 {
    const axis_y = [2]f64{ -pad.axis_x[1], pad.axis_x[0] };
    return .{
        direction[0] * pad.axis_x[0] + direction[1] * pad.axis_x[1],
        direction[0] * axis_y[0] + direction[1] * axis_y[1],
    };
}

fn boxRayHalfExtent(pad: Pad, direction: [2]f64) f64 {
    const local = localComponents(pad, direction);
    var extent = std.math.inf(f64);
    if (@abs(local[0]) > eps) extent = @min(extent, pad.half_w / @abs(local[0]));
    if (@abs(local[1]) > eps) extent = @min(extent, pad.half_h / @abs(local[1]));
    return if (std.math.isFinite(extent)) extent else 0;
}

/// Width of pad copper at the actual exit, perpendicular to this launch.
/// A centre cross-section is wrong for diagonal entries: on a square land it
/// grows by sqrt(2) at 45 degrees, then protrudes beyond the pad as a false
/// flare. The boundary chord shrinks naturally toward a corner while leaving
/// horizontal and vertical face entries unchanged.
fn launchSpan(pad: Pad, direction: [2]f64) f64 {
    const local = localComponents(pad, direction);
    const land = boxRayHalfExtent(pad, direction);
    const point = [2]f64{ local[0] * land, local[1] * land };
    const normal = [2]f64{ -local[1], local[0] };
    var lo = -std.math.inf(f64);
    var hi = std.math.inf(f64);
    for (point, normal, [2]f64{ pad.half_w, pad.half_h }) |p, n, half| {
        if (@abs(n) <= eps) {
            if (@abs(p) > half + eps) return 0;
            continue;
        }
        var a = (-half - p) / n;
        var b = (half - p) / n;
        if (a > b) std.mem.swap(f64, &a, &b);
        lo = @max(lo, a);
        hi = @min(hi, b);
        if (hi < lo - eps) return 0;
    }
    return @max(0, hi - lo);
}

fn needsNeck(profile: pad_neck_profile.Profile, nominal: f64, pad: Pad, direction: [2]f64) bool {
    return profile.width > 0 and
        profile.width < nominal - eps and
        launchSpan(pad, direction) < nominal - eps;
}

fn endpointNeedsNeck(
    pads: []const Pad,
    point: [2]f64,
    layer: u8,
    profile: pad_neck_profile.Profile,
    nominal: f64,
    direction: [2]f64,
) bool {
    var found = false;
    for (pads) |pad| {
        if (pad.layer != layer or !samePoint(pad.at, point)) continue;
        found = true;
        // Coincident same-net lands act as their copper union. If any one can
        // carry the trunk, narrowing the connection is unnecessary.
        if (!needsNeck(profile, nominal, pad, direction)) return false;
    }
    return found;
}

fn netPads(arena: std.mem.Allocator, placement: optimizer.Placement, net: i32) std.mem.Allocator.Error![]const Pad {
    var out: std.ArrayList(Pad) = .empty;
    for (placement.nets[@intCast(net)].pins) |pin| {
        for (placement.parts) |part| {
            if (!std.mem.eql(u8, part.ref_des, pin.ref_des)) continue;
            for (part.pads) |pad| {
                if (!std.mem.eql(u8, pad.number, pin.pin) or pad.thru) continue;
                try out.append(arena, .{
                    .at = optimizer.worldPadCenter(&part, pad.x, pad.y),
                    .layer = if (part.side == .bottom) 1 else 0,
                    .half_w = pad.w / 2,
                    .half_h = pad.h / 2,
                    .axis_x = blk: {
                        var local = pose_math.rotate(1, 0, pad.rot);
                        if (part.side == .bottom) local[0] = -local[0];
                        break :blk pose_math.rotate(local[0], local[1], part.rot);
                    },
                });
            }
        }
    }
    return out.items;
}

/// Whether an under-nominal segment is exactly inside this net class's pad
/// transition envelope: an authored pad neck when present, otherwise the
/// pad-size taper used by single-ended controlled-impedance routes.
/// DRC uses geometry instead of trusting provenance, so generated, restored,
/// and hand-routed copper all earn the exception by satisfying the same width
/// and pad-distance profile.
pub fn allowsTrack(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    track: router.Track,
    nominal: f64,
    fab_min_width: f64,
) std.mem.Allocator.Error!bool {
    if (track.net < 0) return false;
    const ni: usize = @intCast(track.net);
    if (ni >= placement.nets.len or ni >= placement.rules.net.len) return false;
    const rule = placement.rules.net[ni];
    const profile = rule.pad_neck;
    const neck = @max(profile.width, fab_min_width);
    const authored = profile.width > 0 and neck < nominal - eps and track.width >= neck - eps;
    const no_authored_neck = profile.width <= 0;
    const controlled_impedance = no_authored_neck and rule.rf.impedance.ohms > 0 and
        rule.rf.impedance.diff_ohms <= 0;
    if (!authored and !controlled_impedance) return false;
    const neck_len = if (profile.max_length > 0) profile.max_length else default_neck_length_mm;
    const taper_len = if (profile.taper_length > 0) profile.taper_length else default_taper_length_mm;
    const a = [2]f64{ track.x1, track.y1 };
    const b = [2]f64{ track.x2, track.y2 };
    const direction = unit(.{ b[0] - a[0], b[1] - a[1] }) orelse return false;
    for (try netPads(arena, placement, track.net)) |pad| {
        if (pad.layer != track.layer) continue;
        const da = dist(pad.at, a);
        const db = dist(pad.at, b);
        if (authored) {
            if (!needsNeck(profile, nominal, pad, direction)) continue;
            const total = neck_len + taper_len;
            if (da > total + taper_step_mm + eps or db > total + taper_step_mm + eps) continue;
            const required = profileWidth(@max(da, db), neck, nominal, neck_len, taper_len);
            if (track.width + eps >= required) return true;
        } else {
            const across = launchSpan(pad, direction);
            if (!(across > 0) or across >= nominal - eps) continue;
            const land = boxRayHalfExtent(pad, direction);
            const rf_taper = nominal * rf_taper_widths;
            if (@min(da, db) > land + rf_taper + eps) continue;
            const required = profileWidth(@max(da, db), across, nominal, land, rf_taper);
            if (track.width + eps >= required) return true;
        }
    }
    return false;
}

/// ---- Bounded pad-entry neck exemption for the adaptive power-width rule ----
///
/// A power track chain narrower than its solved IPC-2221 width is accepted
/// practice when the narrowing is FORCED by the land it terminates on (a QFN
/// pad cannot take copper wider than itself), the neck is no narrower than
/// that land demands, it is short, and its far end reaches copper that does
/// satisfy the solved width (or a same-net pour). A narrow run that merely
/// passes near a pad, pinches mid-run, or dangles keeps its finding.
///
/// The length bound is derived from the SAME empirical screen the rule
/// enforces (IPC-2221, `power_capacity.zig`), extended by the standard
/// one-dimensional fin argument for end conduction:
///
///   The screen says a trace of the solved width w_req carrying I sits at the
///   rise budget dT_b (10 C). Inverting I = k*dT^0.44*A^0.725 at the neck's
///   actual area gives the neck's standalone equilibrium rise
///       dT_inf = dT_b * (w_req/w)^(0.725/0.44).
///   Joule heating per length is q' = I^2*rho/A, so the loss conductance per
///   length the screen implicitly assigns this neck is g = q'/dT_inf. With
///   copper conduction k_cu along the neck, the excess temperature over its
///   ends obeys k_cu*A*x'' = g*x - (q' - g*dT_b): a fin clamped at the
///   compliant copper's own budget temperature, healing length 1/m with
///   m = sqrt(g/(k_cu*A)). Its midpoint excess is
///   (dT_inf - dT_b)*(1 - sech(m*L/2)), and the neck is exempt only while
///   that excess stays within the same dT_b budget the screen grants a
///   full-length run - AND while m*L/2 <= 1, because past one healing length
///   the ends no longer pin the middle and the fin argument itself (the only
///   reason to forgive the shortfall) has expired.
///
/// Material constants are chosen conservatively (short bound): foil
/// conductivity 355 W/(m*K), below bulk copper's 385-401, and resistivity
/// 2.0e-8 ohm*m, copper at ~75 C rather than the 1.72e-8 20 C value. Both
/// push m up and the allowance down. Everything else - foil thickness,
/// inner/outer coefficient, rise budget, solved width - comes from the model
/// itself.
const neck_copper_resistivity_ohm_m: f64 = 2.0e-8;
const neck_copper_conductivity_w_mk: f64 = 355.0;
/// A forcing pad's exit demands its own width from the neck. Assembly DFM
/// guidance puts pad-entry copper at up to - but deliberately not exactly -
/// the land width (a full-width entry promotes solder wicking off the land;
/// the ubiquitous fabricator rule of thumb is "trace entering an SMD pad at
/// no more than ~80% of the pad width"). Copper in that 80-100% band reads
/// as "the width the pad forces"; anything narrower is a routing choice, not
/// a pad constraint, and keeps its finding.
const neck_span_tolerance: f64 = 0.20;
/// A compliant neighbour must be real copper, not a zero-length crumb.
const neck_neighbor_min_len_mm: f64 = 1e-3;

/// The board slice `judgePowerNeck` walks. `required` is index-aligned with
/// `tracks`: the effective width requirement DRC computed for each track
/// (solved local IPC width, branch floor, or whole-rail envelope), 0 when the
/// track has none.
pub const PowerNeckBoard = struct {
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
    zones: []const copper_support.Zone = &.{},
    required: []const f64,
};

/// One `judgePowerNeck` answer: whether the walked chain is a bounded
/// pad-entry neck, plus the chain itself so a caller can cache the verdict
/// across every slice the walk already covered.
pub const PowerNeckVerdict = struct {
    exempt: bool,
    /// Every under-required track walked into the seed's chain (seed included).
    chain: []const usize,
};

fn neckUnderRequired(board: PowerNeckBoard, index: usize) bool {
    const track = board.tracks[index];
    const required = if (index < board.required.len) board.required[index] else 0;
    return required > 0 and track.width > eps and track.width < required - eps;
}

fn neckTrackLen(track: router.Track) f64 {
    return std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
}

/// Whether `point` lies on `track`'s centreline (interior included), within
/// the shared attach epsilon.
fn neckPointOnTrack(point: [2]f64, track: router.Track) bool {
    const dx = track.x2 - track.x1;
    const dy = track.y2 - track.y1;
    const len2 = dx * dx + dy * dy;
    if (len2 <= eps) return samePoint(.{ track.x1, track.y1 }, point);
    const f = std.math.clamp(((point[0] - track.x1) * dx + (point[1] - track.y1) * dy) / len2, 0, 1);
    const px = track.x1 + dx * f;
    const py = track.y1 + dy * f;
    return std.math.hypot(point[0] - px, point[1] - py) <= router.clearance_eps;
}

fn neckPointInPad(pad: Pad, point: [2]f64) bool {
    const dx = point[0] - pad.at[0];
    const dy = point[1] - pad.at[1];
    const axis_y = [2]f64{ -pad.axis_x[1], pad.axis_x[0] };
    const lx = dx * pad.axis_x[0] + dy * pad.axis_x[1];
    const ly = dx * axis_y[0] + dy * axis_y[1];
    return @abs(lx) <= pad.half_w + router.clearance_eps and @abs(ly) <= pad.half_h + router.clearance_eps;
}

/// Fin parameters of one under-required slice: its fin constant m and the
/// standalone excess rise its shortfall implies (see the module comment).
const NeckSliceThermal = struct { m_per_m: f64, excess_c: f64 };

fn neckSliceThermal(placement: optimizer.Placement, track: router.Track, required_mm: f64) ?NeckSliceThermal {
    const physical = placement.rules.signalStackIndex(track.layer);
    const foil_mm = placement.rules.physical.stack.foilMm(physical);
    if (!(foil_mm > 0)) return null;
    const outer = physical == 1 or physical == placement.rules.layerStack().stackCount();
    const amps = power_capacity.traceCapacityA(required_mm, foil_mm, outer);
    if (!(amps > 0)) return null;
    const rise_budget = power_capacity.temperature_rise_c;
    const rise_inf = rise_budget * std.math.pow(
        f64,
        required_mm / track.width,
        power_capacity.area_exponent / power_capacity.rise_exponent,
    );
    const area_m2 = (track.width / 1000.0) * (foil_mm / 1000.0);
    const joule_w_per_m = amps * amps * neck_copper_resistivity_ohm_m / area_m2;
    const loss_w_per_mk = joule_w_per_m / rise_inf;
    const m_per_m = @sqrt(loss_w_per_mk / (neck_copper_conductivity_w_mk * area_m2));
    if (!std.math.isFinite(m_per_m) or !(m_per_m > 0)) return null;
    return .{ .m_per_m = m_per_m, .excess_c = rise_inf - rise_budget };
}

/// The walk state behind `judgePowerNeck`: the growing chain of connected
/// under-required copper plus what its boundary has touched so far.
const NeckWalk = struct {
    board: PowerNeckBoard,
    net: i32,
    /// Indices of every same-net track with recorded width.
    net_tracks: []const usize,
    pads: []const Pad,
    chain: std.ArrayList(usize) = .empty,
    in_chain: std.AutoHashMapUnmanaged(usize, void) = .empty,
    forcing_span: f64 = 0,
    found_forcing_pad: bool = false,
    found_wide_end: bool = false,
    dangling: bool = false,

    /// Copper met at a joint: an under-required track joins the chain; a
    /// track already at its own requirement is the wide far end.
    fn absorbNeighbor(walk: *NeckWalk, arena: std.mem.Allocator, other_index: usize) std.mem.Allocator.Error!void {
        if (neckUnderRequired(walk.board, other_index)) {
            if (!walk.in_chain.contains(other_index)) {
                try walk.in_chain.put(arena, other_index, {});
                try walk.chain.append(arena, other_index);
            }
            return;
        }
        const other = walk.board.tracks[other_index];
        const required = if (other_index < walk.board.required.len) walk.board.required[other_index] else 0;
        if (other.width + eps >= required and neckTrackLen(other) > neck_neighbor_min_len_mm)
            walk.found_wide_end = true;
    }

    /// A same-net land under this endpoint: one at least as wide as the
    /// requirement is wide copper; a narrower one forces the neck.
    fn visitPads(walk: *NeckWalk, point: [2]f64, layer: u8, required: f64) bool {
        var touched = false;
        for (walk.pads) |pad| {
            if (pad.layer != layer or !neckPointInPad(pad, point)) continue;
            touched = true;
            // The power shaping pass necks to the land's smaller physical
            // dimension (`powerEndpointProfile`); judge by the same span.
            const span = 2 * @min(pad.half_w, pad.half_h);
            if (!(span > 0)) continue;
            if (span + eps >= required) {
                walk.found_wide_end = true;
            } else {
                walk.found_forcing_pad = true;
                walk.forcing_span = @max(walk.forcing_span, span);
            }
        }
        return touched;
    }

    /// Everything one chain-track endpoint reaches: joined tracks (endpoint
    /// or tee), barrels, lands, pours. An endpoint reaching nothing marks the
    /// chain dangling.
    fn visitEndpoint(walk: *NeckWalk, arena: std.mem.Allocator, index: usize, point: [2]f64) std.mem.Allocator.Error!void {
        const track = walk.board.tracks[index];
        var touched = false;
        // A same-net barrel joins every layer at this point.
        var through_via = false;
        for (walk.board.vias) |via| {
            if (via.net != walk.net or !samePoint(.{ via.x, via.y }, point)) continue;
            through_via = true;
            touched = true;
        }
        for (walk.net_tracks) |other_index| {
            if (other_index == index) continue;
            const other = walk.board.tracks[other_index];
            if (other.layer != track.layer and !through_via) continue;
            // Endpoint-to-endpoint, or this endpoint riding the other track's
            // interior - hand-drawn copper tees mid-segment.
            if (!neckPointOnTrack(point, other)) continue;
            touched = true;
            try walk.absorbNeighbor(arena, other_index);
        }
        // A same-net pour under this endpoint is wide copper by definition.
        const pour_mask = copper_support.pourLayers(walk.board.placement, walk.net, walk.board.zones, point[0], point[1]);
        if (pour_mask != 0) {
            const own_layer = track.layer < 64 and (pour_mask >> @intCast(track.layer)) & 1 == 1;
            if (own_layer or through_via) {
                touched = true;
                walk.found_wide_end = true;
            }
        }
        if (walk.visitPads(point, track.layer, walk.board.required[index])) touched = true;
        if (!touched) walk.dangling = true;
    }

    /// A neck chain earns judgement only when nothing dangles, a land forces
    /// the narrowing, and the far end reaches copper that satisfies its width.
    fn structurallySound(walk: *const NeckWalk) bool {
        if (walk.dangling) return false;
        return walk.found_forcing_pad and walk.found_wide_end;
    }

    /// The mirror tee: another track's ENDPOINT joined into this slice's
    /// interior. Same classification as an endpoint joint.
    fn visitTees(walk: *NeckWalk, arena: std.mem.Allocator, index: usize) std.mem.Allocator.Error!void {
        const track = walk.board.tracks[index];
        for (walk.net_tracks) |other_index| {
            if (other_index == index) continue;
            const other = walk.board.tracks[other_index];
            if (other.layer != track.layer) continue;
            const joins = neckPointOnTrack(.{ other.x1, other.y1 }, track) or
                neckPointOnTrack(.{ other.x2, other.y2 }, track);
            if (joins) try walk.absorbNeighbor(arena, other_index);
        }
    }
};

/// The clamped-fin length verdict over a walked chain: midpoint excess (worst
/// slice) within the rise budget, and never past the end-conduction regime
/// (m*L/2 <= 1). Branch lengths all count toward the one bound, which only
/// over-counts - a branch is extra copper, never extra allowance.
fn neckChainWithinBound(board: PowerNeckBoard, chain: []const usize) bool {
    var length_units: f64 = 0; // sum of m_j * L_j (dimensionless fin length)
    var worst_excess_c: f64 = 0;
    for (chain) |index| {
        const track = board.tracks[index];
        const thermal = neckSliceThermal(board.placement, track, board.required[index]) orelse return false;
        length_units += thermal.m_per_m * neckTrackLen(track) / 1000.0; // mm -> m
        worst_excess_c = @max(worst_excess_c, thermal.excess_c);
    }
    const rise_budget = power_capacity.temperature_rise_c;
    var half_units_max: f64 = 1.0;
    if (worst_excess_c > rise_budget) {
        const clamp = std.math.acosh(worst_excess_c / (worst_excess_c - rise_budget));
        half_units_max = @min(half_units_max, clamp);
    }
    return length_units <= 2 * half_units_max;
}

/// Whether the under-required track `seed` sits inside a bounded pad-entry
/// neck (see the module comment above for the physics). The verdict covers
/// the whole walked chain. Deliberately geometric like `allowsTrack`:
/// generated, restored and hand-drawn copper earn (or fail) the exemption by
/// the same profile, and an exempted neck is silent exactly the way the
/// own-land and port-frame-taper exemptions are.
pub fn judgePowerNeck(
    arena: std.mem.Allocator,
    board: PowerNeckBoard,
    seed: usize,
) std.mem.Allocator.Error!PowerNeckVerdict {
    var walk = NeckWalk{
        .board = board,
        .net = board.tracks[seed].net,
        .net_tracks = &.{},
        .pads = &.{},
    };
    try walk.chain.append(arena, seed);
    if (!neckUnderRequired(board, seed) or walk.net < 0)
        return .{ .exempt = false, .chain = walk.chain.items };

    // Same-net track universe once; the walk is quadratic only in its size.
    var net_tracks: std.ArrayList(usize) = .empty;
    for (board.tracks, 0..) |track, index| {
        if (track.net == walk.net and track.width > eps) try net_tracks.append(arena, index);
    }
    walk.net_tracks = net_tracks.items;
    walk.pads = try netPads(arena, board.placement, walk.net);

    try walk.in_chain.put(arena, seed, {});
    var cursor: usize = 0;
    while (cursor < walk.chain.items.len) : (cursor += 1) {
        const index = walk.chain.items[cursor];
        const track = board.tracks[index];
        try walk.visitEndpoint(arena, index, .{ track.x1, track.y1 });
        try walk.visitEndpoint(arena, index, .{ track.x2, track.y2 });
        try walk.visitTees(arena, index);
    }
    if (!walk.structurallySound()) return .{ .exempt = false, .chain = walk.chain.items };
    // The pad forces the neck, but not one narrower than the pad demands.
    for (walk.chain.items) |index| {
        if (board.tracks[index].width + eps < walk.forcing_span * (1 - neck_span_tolerance))
            return .{ .exempt = false, .chain = walk.chain.items };
    }
    return .{ .exempt = neckChainWithinBound(board, walk.chain.items), .chain = walk.chain.items };
}

const Profile = struct {
    width: f64,
    land: f64,
    taper: f64,
};

const Shape = struct {
    track: router.Track,
    nominal: f64,
    start: ?Profile = null,
    end: ?Profile = null,
};

fn localWidth(s: f64, len: f64, shape: Shape) f64 {
    const start_active = if (shape.start) |p| s < p.land + p.taper else false;
    const end_active = if (shape.end) |p| len - s < p.land + p.taper else false;
    const start_width = if (shape.start) |p| profileWidth(s, p.width, shape.nominal, p.land, p.taper) else shape.nominal;
    const end_width = if (shape.end) |p| profileWidth(len - s, p.width, shape.nominal, p.land, p.taper) else shape.nominal;
    if (start_active and end_active) {
        if (start_width <= shape.nominal and end_width <= shape.nominal) return @min(start_width, end_width);
        if (start_width >= shape.nominal and end_width >= shape.nominal) return @max(start_width, end_width);
        const f = if (len > eps) std.math.clamp(s / len, 0, 1) else 0;
        return start_width + (end_width - start_width) * f;
    }
    if (start_active) return start_width;
    if (end_active) return end_width;
    return shape.nominal;
}

fn routedNominal(placement: optimizer.Placement, ni: usize, track_width: f64) ?f64 {
    const rule = if (ni < placement.rules.net.len) placement.rules.net[ni] else optimizer.NetRule{};
    const authored = if (rule.width > 0) rule.width else placement.rules.design.track_width;
    if (@abs(track_width - authored) <= router.clearance_eps) return authored;
    const widened = @max(authored, placement.rules.powerWidthForNet(placement.nets[ni].name) orelse 0);
    return if (@abs(track_width - widened) <= router.clearance_eps) widened else null;
}

fn appendSlice(arena: std.mem.Allocator, out: *std.ArrayList(router.Track), shape: Shape, s0: f64, s1: f64, len: f64) std.mem.Allocator.Error!void {
    if (s1 - s0 <= eps) return;
    const t = shape.track;
    const ux = (t.x2 - t.x1) / len;
    const uy = (t.y2 - t.y1) / len;
    // The wider endpoint makes each capsule a conservative outer approximation
    // of the linear taper, still bounded by the nominal cleared envelope.
    const width = @max(localWidth(s0, len, shape), localWidth(s1, len, shape));
    try out.append(arena, .{
        .x1 = t.x1 + ux * s0,
        .y1 = t.y1 + uy * s0,
        .x2 = t.x1 + ux * s1,
        .y2 = t.y1 + uy * s1,
        .layer = t.layer,
        .width = width,
        .net = t.net,
    });
}

fn shapeTrack(arena: std.mem.Allocator, out: *std.ArrayList(router.Track), shape: Shape) std.mem.Allocator.Error!void {
    const t = shape.track;
    const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    if (len <= eps) return;
    var cuts: std.ArrayList(f64) = .empty;
    try cuts.append(arena, 0);
    try cuts.append(arena, len);
    for ([_]?Profile{ shape.start, shape.end }, 0..) |maybe_profile, end| {
        const profile = maybe_profile orelse continue;
        const shaped_span = profile.land + profile.taper;
        const origin: f64 = if (end == 0) 0 else len;
        const sign: f64 = if (end == 0) 1 else -1;
        const neck_cut = origin + sign * @min(profile.land, len);
        if (neck_cut > eps and neck_cut < len - eps) try cuts.append(arena, neck_cut);
        var d = profile.land + taper_step_mm;
        while (d < shaped_span - eps and d < len - eps) : (d += taper_step_mm) {
            const cut = origin + sign * d;
            if (cut > eps and cut < len - eps) try cuts.append(arena, cut);
        }
        const end_cut = origin + sign * @min(shaped_span, len);
        if (end_cut > eps and end_cut < len - eps) try cuts.append(arena, end_cut);
    }
    std.mem.sort(f64, cuts.items, {}, std.sort.asc(f64));
    var prior = cuts.items[0];
    for (cuts.items[1..]) |cut| {
        if (cut - prior <= eps) continue;
        try appendSlice(arena, out, shape, prior, cut, len);
        prior = cut;
    }
}

const EndpointCopper = struct {
    pads: []const Pad,
    vias: []const router.Via,
    net: i32,
};

fn rfEndpointProfile(
    copper: EndpointCopper,
    point: [2]f64,
    layer: u8,
    nominal: f64,
    direction: [2]f64,
) ?Profile {
    var found = false;
    var width: f64 = 0;
    var land: f64 = 0;
    for (copper.pads) |pad| {
        if (pad.layer != layer or !samePoint(pad.at, point)) continue;
        const span = launchSpan(pad, direction);
        if (!(span > 0)) continue;
        found = true;
        width = @max(width, span);
        land = @max(land, boxRayHalfExtent(pad, direction));
    }
    for (copper.vias) |via| {
        if (via.net != copper.net or !samePoint(.{ via.x, via.y }, point)) continue;
        if (!(via.dia > 0)) continue;
        found = true;
        width = @max(width, via.dia);
        land = @max(land, via.dia / 2);
    }
    if (!found or @abs(width - nominal) <= eps) return null;
    return .{ .width = width, .land = land, .taper = nominal * rf_taper_widths };
}

/// Pad-sized launch for an ordinary power route. Unlike the RF spelling, a
/// wider land does not flare above the electrical target: this pass grows a
/// narrow centreline toward that target, never beyond it. Power launches use
/// the pad's smaller physical dimension independent of route angle: that is
/// the narrowest copper the land can actually support. The transition then
/// takes only the distance needed for 45-degree flanks.
fn powerEndpointProfile(
    pads: []const Pad,
    point: [2]f64,
    layer: u8,
    nominal: f64,
    direction: [2]f64,
) ?Profile {
    var found = false;
    var width: f64 = 0;
    var land: f64 = 0;
    for (pads) |pad| {
        if (pad.layer != layer or !samePoint(pad.at, point)) continue;
        const span = 2 * @min(pad.half_w, pad.half_h);
        if (!(span > 0)) continue;
        found = true;
        width = @max(width, @min(span, nominal));
        land = @max(land, boxRayHalfExtent(pad, direction));
    }
    if (!found or width >= nominal - eps) return null;
    return .{
        .width = width,
        .land = land,
        .taper = (nominal - width) / adaptive_width_per_length,
    };
}

const AdaptiveCell = struct {
    s0: f64,
    s1: f64,
    width: f64,
};

/// One track this pass has smoothed but not yet emitted. The whole net is
/// shaped before any of it is written out, because a bend is only visible from
/// both of the tracks that form it.
const ShapedRun = struct {
    track: router.Track,
    len: f64,
    cells: []AdaptiveCell,
    /// An end cell was pulled down since this run last saw the flank passes.
    reflank: bool = false,
};

/// One end of one of this net's tracks, as a joint candidate. A shaped run can
/// still give width up; a track this pass left alone — already wider than the
/// routing floor, or degenerate — contributes its fixed width and nothing else.
const TrackEnd = struct {
    at: [2]f64,
    layer: u8,
    /// Index into the pass's shaped runs, or null for a fixed-width neighbour.
    run: ?usize,
    /// 0 selects the run's first cell, 1 its last.
    tail: u1,
    width: f64,
};

const AdaptiveShape = struct {
    probe: router.TautProbe,
    track: router.Track,
    floor: f64,
    target: f64,
    start: ?Profile,
    end: ?Profile,
};

fn pointOnTrack(track: router.Track, distance: f64, len: f64) [2]f64 {
    const f = if (len > eps) distance / len else 0;
    return .{
        track.x1 + (track.x2 - track.x1) * f,
        track.y1 + (track.y2 - track.y1) * f,
    };
}

/// Largest width whose full capsule clears this cell. The existing narrow
/// route is the proven floor; bisection approaches the target deterministically
/// without quantizing width to the routing lattice.
fn widestClear(
    shape: AdaptiveShape,
    s0: f64,
    s1: f64,
    len: f64,
) f64 {
    if (shape.target <= shape.floor + eps) return shape.floor;
    const a = pointOnTrack(shape.track, s0, len);
    const b = pointOnTrack(shape.track, s1, len);
    if (shape.probe.clearWidth(shape.track.layer, a, b, shape.target)) return shape.target;
    var low = shape.floor;
    var high = shape.target;
    for (0..adaptive_width_iterations) |_| {
        const mid = (low + high) / 2;
        if (shape.probe.clearWidth(shape.track.layer, a, b, mid))
            low = mid
        else
            high = mid;
    }
    return low;
}

/// Clearance may jump at an obstacle edge. Pull each side down to a
/// 45-degree-flank envelope so the emitted 50 um slices form a taper rather
/// than a width step. Two directional passes compute the greatest profile
/// beneath those local maxima. Re-running them after a joint has pulled an end
/// cell down walks that neck back into the run at the same flank.
fn flankCells(cells: []AdaptiveCell) void {
    for (cells[1..], 1..) |*cell, i| {
        const prior = cells[i - 1];
        const centre_gap = ((prior.s1 - prior.s0) + (cell.s1 - cell.s0)) / 2;
        cell.width = @min(cell.width, prior.width + adaptive_width_per_length * centre_gap);
    }
    var i = cells.len;
    while (i > 1) {
        i -= 1;
        const next = cells[i];
        const cell = &cells[i - 1];
        const centre_gap = ((next.s1 - next.s0) + (cell.s1 - cell.s0)) / 2;
        cell.width = @min(cell.width, next.width + adaptive_width_per_length * centre_gap);
    }
}

fn shapeRun(
    arena: std.mem.Allocator,
    adaptive: AdaptiveShape,
) std.mem.Allocator.Error!?ShapedRun {
    const track = adaptive.track;
    const floor = adaptive.floor;
    const target = adaptive.target;
    const len = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    if (len <= eps or target <= floor + eps) return null;
    const shape = Shape{ .track = track, .nominal = target, .start = adaptive.start, .end = adaptive.end };
    var cells: std.ArrayList(AdaptiveCell) = .empty;
    var s0: f64 = 0;
    while (s0 < len - eps) {
        const s1 = @min(len, s0 + adaptive_step_mm);
        // Keep the whole cell inside the pad-local taper envelope. Clearance
        // then imposes any tighter mid-route neck caused by foreign copper.
        var cap = @min(localWidth(s0, len, shape), localWidth(s1, len, shape));
        cap = @max(floor, @min(target, cap));
        try cells.append(arena, .{
            .s0 = s0,
            .s1 = s1,
            .width = widestClear(.{
                .probe = adaptive.probe,
                .track = track,
                .floor = floor,
                .target = cap,
                .start = null,
                .end = null,
            }, s0, s1, len),
        });
        s0 = s1;
    }
    flankCells(cells.items);
    return .{ .track = track, .len = len, .cells = cells.items };
}

fn emitShapedRun(
    arena: std.mem.Allocator,
    out: *std.ArrayList(router.Track),
    run: ShapedRun,
) std.mem.Allocator.Error!bool {
    const track = run.track;
    const len = run.len;
    const cells = run.cells;
    var changed = false;
    for (cells) |cell| changed = changed or cell.width > track.width + eps;
    if (!changed) {
        try out.append(arena, track);
        return false;
    }

    // Collapse the long uniform trunk back into one edit handle. Only the
    // taper and genuinely clearance-varying neck retain 50 um slices, so a
    // 100 mm rail does not become 2,000 persisted segments merely because it
    // had room to reach the same target everywhere.
    var run_s0 = cells[0].s0;
    var run_width = cells[0].width;
    for (cells[1..]) |cell| {
        if (@abs(cell.width - run_width) <= eps) continue;
        const a = pointOnTrack(track, run_s0, len);
        const b = pointOnTrack(track, cell.s0, len);
        try out.append(arena, .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1], .layer = track.layer, .width = run_width, .net = track.net });
        run_s0 = cell.s0;
        run_width = cell.width;
    }
    const a = pointOnTrack(track, run_s0, len);
    const b = pointOnTrack(track, len, len);
    try out.append(arena, .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1], .layer = track.layer, .width = run_width, .net = track.net });
    return true;
}

const JointPass = struct {
    runs: []ShapedRun,
    /// Same-net tracks this pass left alone. They cannot move, but a shaped run
    /// that ends on one still has to meet it.
    fixed: []const router.Track,
    vias: []const router.Via,
    pads: []const Pad,
    net: i32,
};

/// Sweeps of clamp-then-reflank. Clamping only ever lowers a width, so the
/// sweep is monotone and settles; the cap bounds a chain of sub-taper-length
/// segments, which would otherwise carry a neck one hop per sweep.
const joint_equalize_sweeps: usize = 3;

fn endCellIndex(run: ShapedRun, tail: u1) usize {
    return if (tail == 0) 0 else run.cells.len - 1;
}

fn endWidth(runs: []const ShapedRun, end: TrackEnd) f64 {
    const run = end.run orelse return end.width;
    return runs[run].cells[endCellIndex(runs[run], end.tail)].width;
}

fn clampEnd(runs: []ShapedRun, end: TrackEnd, width: f64) bool {
    const index = end.run orelse return false;
    const run = &runs[index];
    const cell = &run.cells[endCellIndex(run.*, end.tail)];
    if (cell.width <= width + eps) return false;
    cell.width = width;
    run.reflank = true;
    return true;
}

fn trackEnds(track: router.Track, run: ?usize) [2]TrackEnd {
    return .{
        .{ .at = .{ track.x1, track.y1 }, .layer = track.layer, .run = run, .tail = 0, .width = track.width },
        .{ .at = .{ track.x2, track.y2 }, .layer = track.layer, .run = run, .tail = 1, .width = track.width },
    };
}

/// Bring one joint's two ends to the narrower of their widths. True when that
/// moved copper, which is also what asks the run for another flank pass.
fn settleJoint(runs: []ShapedRun, ends: []const TrackEnd, joint: [2]usize) bool {
    const width = @min(endWidth(runs, ends[joint[0]]), endWidth(runs, ends[joint[1]]));
    const first = clampEnd(runs, ends[joint[0]], width);
    return clampEnd(runs, ends[joint[1]], width) or first;
}

fn endOrderLess(ends: []const TrackEnd, a: usize, b: usize) bool {
    if (ends[a].layer != ends[b].layer) return ends[a].layer < ends[b].layer;
    if (ends[a].at[0] != ends[b].at[0]) return ends[a].at[0] < ends[b].at[0];
    if (ends[a].at[1] != ends[b].at[1]) return ends[a].at[1] < ends[b].at[1];
    return a < b;
}

/// A same-net barrel or land at the meeting point already governs the corner:
/// the barrel covers the elbow, and the pad launch profiles own the land.
fn jointCovered(pass: JointPass, at: [2]f64, layer: u8) bool {
    for (pass.vias) |via| {
        if (via.net == pass.net and samePoint(.{ via.x, via.y }, at)) return true;
    }
    for (pass.pads) |pad| {
        if (pad.layer == layer and samePoint(pad.at, at)) return true;
    }
    return false;
}

/// Make connected copper meet at ONE width.
///
/// Each track is fitted against its own clearance, so two that meet at a bend
/// can arrive there at unrelated widths — a full-height ledge exactly on the
/// elbow, which is where a round capsule cap cannot hide it. Where exactly two
/// of this net's tracks meet on one layer, both ends take the narrower of the
/// two, and the wider side walks back up its own straight on the standard
/// 45-degree flank.
///
/// Only a bare two-track meeting is equalized. A T-junction is a real trunk to
/// branch step and ordinary fab practice, and a barrel or land at the point
/// already governs the geometry there.
fn equalizeJointWidths(arena: std.mem.Allocator, pass: JointPass) std.mem.Allocator.Error!void {
    var ends: std.ArrayList(TrackEnd) = .empty;
    for (pass.runs, 0..) |run, index| try ends.appendSlice(arena, &trackEnds(run.track, index));
    for (pass.fixed) |track| try ends.appendSlice(arena, &trackEnds(track, null));
    if (ends.items.len < 2) return;

    // Sorted by layer then x, so every end within joint tolerance of an anchor
    // sits in the short window that opens at it.
    const order = try arena.alloc(usize, ends.items.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, @as([]const TrackEnd, ends.items), endOrderLess);
    const claimed = try arena.alloc(bool, ends.items.len);
    @memset(claimed, false);
    var joints: std.ArrayList([2]usize) = .empty;
    for (order, 0..) |anchor, position| {
        if (claimed[anchor]) continue;
        claimed[anchor] = true;
        const at = ends.items[anchor].at;
        const layer = ends.items[anchor].layer;
        var partner = anchor;
        var degree: usize = 1;
        var scan = position + 1;
        while (scan < order.len) : (scan += 1) {
            const other = ends.items[order[scan]];
            if (other.layer != layer or other.at[0] - at[0] > router.clearance_eps) break;
            if (!samePoint(other.at, at)) continue;
            claimed[order[scan]] = true;
            partner = order[scan];
            degree += 1;
        }
        if (degree != 2 or jointCovered(pass, at, layer)) continue;
        try joints.append(arena, .{ anchor, partner });
    }
    if (joints.items.len == 0) return;

    for (0..joint_equalize_sweeps) |_| {
        var moved = false;
        for (joints.items) |joint| {
            if (settleJoint(pass.runs, ends.items, joint)) moved = true;
        }
        if (!moved) return;
        for (pass.runs) |*run| {
            if (!run.reflank) continue;
            run.reflank = false;
            flankCells(run.cells);
        }
    }
    // A re-flank can pull an end cell back below what its joint had agreed, and
    // a chain of very short segments can outlast the sweeps. Close on the
    // joints rather than on the flanks: any residue then lands mid-straight,
    // under a capsule cap, instead of on the elbow this pass exists to fix.
    for (joints.items) |joint| _ = settleJoint(pass.runs, ends.items, joint);
}

/// Route power nets at an ordinary legal centreline, then grow each segment
/// toward its electrical target under the router's exact width-aware clearance
/// oracle. Nets are committed one at a time so later rails see earlier widened
/// copper as a foreign obstacle rather than both claiming the same free space.
///
/// A net is shaped in full before any of it is emitted: width continuity across
/// a bend is a property of two tracks at once, and `equalizeJointWidths` needs
/// both sides in hand.
fn adaptPowerTracks(board: router.CleanupBoard) std.mem.Allocator.Error!bool {
    const arena = board.arena();
    var any_changed = false;
    for (board.placement.nets, 0..) |_, net_i| {
        if (!board.enabled(net_i)) continue;
        const target = board.adaptivePowerWidth(net_i) orelse continue;
        board.beginNet(net_i);
        const floor = board.trackWidth();
        if (target <= floor + eps) continue;
        const net: i32 = @intCast(net_i);
        const pads = try netPads(arena, board.placement, net);
        const probe = board.tautProbe(net);
        // Which shaped run each board track became, so emission keeps the
        // board's own track order.
        const plan = try arena.alloc(?usize, board.tracks.items.len);
        var runs: std.ArrayList(ShapedRun) = .empty;
        var fixed: std.ArrayList(router.Track) = .empty;
        for (board.tracks.items, 0..) |track, index| {
            plan[index] = null;
            if (track.net != net) continue;
            if (track.width > floor + router.clearance_eps) {
                try fixed.append(arena, track);
                continue;
            }
            const direction = unit(.{ track.x2 - track.x1, track.y2 - track.y1 }) orelse {
                try fixed.append(arena, track);
                continue;
            };
            const start = powerEndpointProfile(pads, .{ track.x1, track.y1 }, track.layer, target, direction);
            const end = powerEndpointProfile(pads, .{ track.x2, track.y2 }, track.layer, target, direction);
            const run = try shapeRun(arena, .{
                .probe = probe,
                .track = track,
                .floor = floor,
                .target = target,
                .start = start,
                .end = end,
            }) orelse {
                try fixed.append(arena, track);
                continue;
            };
            plan[index] = runs.items.len;
            try runs.append(arena, run);
        }
        try equalizeJointWidths(arena, .{
            .runs = runs.items,
            .fixed = fixed.items,
            .vias = board.vias.items,
            .pads = pads,
            .net = net,
        });
        var out: std.ArrayList(router.Track) = .empty;
        var changed = false;
        for (board.tracks.items, 0..) |track, index| {
            const run = plan[index] orelse {
                try out.append(arena, track);
                continue;
            };
            if (try emitShapedRun(arena, &out, runs.items[run])) changed = true;
        }
        if (!changed) continue;
        board.tracks.clearRetainingCapacity();
        try board.tracks.appendSlice(arena, out.items);
        router.copperCompacted(board.ctx);
        any_changed = true;
    }
    return any_changed;
}

/// Shape every selected generated net that declares a pad-local neck or a
/// single-ended controlled-impedance target. Controlled-impedance shaping is
/// local to each SMD or through-via endpoint, so branches elsewhere on the net
/// do not suppress an otherwise valid launch transition.
///
/// This is the copper-only seam used by scoped route replay before its output
/// is offered to the assembled-board gate. Normal complete-board routing uses
/// `passBoard` below, which also reports the compaction to the route context.
pub fn shapeGeneratedTracks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    selected_nets: []const bool,
    vias: []const router.Via,
    tracks: *std.ArrayList(router.Track),
) std.mem.Allocator.Error!bool {
    var out: std.ArrayList(router.Track) = .empty;
    const pads_by_net = try arena.alloc([]const Pad, placement.nets.len);
    const pads_known = try arena.alloc(bool, placement.nets.len);
    @memset(pads_known, false);
    var changed = false;
    for (tracks.items) |track| {
        if (track.net < 0 or @as(usize, @intCast(track.net)) >= placement.nets.len) {
            try out.append(arena, track);
            continue;
        }
        const ni: usize = @intCast(track.net);
        if (selected_nets.len > 0 and (ni >= selected_nets.len or !selected_nets[ni])) {
            try out.append(arena, track);
            continue;
        }
        const rule = if (ni < placement.rules.net.len) placement.rules.net[ni] else optimizer.NetRule{};
        const nominal = routedNominal(placement, ni, track.width) orelse {
            try out.append(arena, track);
            continue;
        };
        const neck = @max(rule.pad_neck.width, placement.rules.design.min_width);
        const authored = rule.pad_neck.width > 0 and neck < nominal - eps;
        const controlled_impedance = rule.rf.impedance.ohms > 0 and rule.rf.impedance.diff_ohms <= 0;
        if (!authored and !controlled_impedance) {
            try out.append(arena, track);
            continue;
        }
        if (!pads_known[ni]) {
            pads_by_net[ni] = try netPads(arena, placement, track.net);
            pads_known[ni] = true;
        }
        const pads = pads_by_net[ni];
        const direction = unit(.{ track.x2 - track.x1, track.y2 - track.y1 }) orelse {
            try out.append(arena, track);
            continue;
        };
        const neck_len = if (rule.pad_neck.max_length > 0) rule.pad_neck.max_length else default_neck_length_mm;
        const taper_len = if (rule.pad_neck.taper_length > 0) rule.pad_neck.taper_length else default_taper_length_mm;
        const start: ?Profile = if (authored and endpointNeedsNeck(
            pads,
            .{ track.x1, track.y1 },
            track.layer,
            rule.pad_neck,
            nominal,
            direction,
        ))
            .{ .width = neck, .land = neck_len, .taper = taper_len }
        else if (controlled_impedance)
            rfEndpointProfile(.{ .pads = pads, .vias = vias, .net = track.net }, .{ track.x1, track.y1 }, track.layer, nominal, direction)
        else
            null;
        const end: ?Profile = if (authored and endpointNeedsNeck(
            pads,
            .{ track.x2, track.y2 },
            track.layer,
            rule.pad_neck,
            nominal,
            direction,
        ))
            .{ .width = neck, .land = neck_len, .taper = taper_len }
        else if (controlled_impedance)
            rfEndpointProfile(.{ .pads = pads, .vias = vias, .net = track.net }, .{ track.x2, track.y2 }, track.layer, nominal, direction)
        else
            null;
        if (start == null and end == null) {
            try out.append(arena, track);
            continue;
        }
        try shapeTrack(arena, &out, .{
            .track = track,
            .nominal = nominal,
            .start = start,
            .end = end,
        });
        changed = true;
    }
    if (!changed) return false;
    tracks.clearRetainingCapacity();
    try tracks.appendSlice(arena, out.items);
    return true;
}

/// Shape a complete router board and notify its cleanup context when the track
/// list changes.
pub fn passBoard(board: router.CleanupBoard) std.mem.Allocator.Error!void {
    const adaptive = try adaptPowerTracks(board);
    const authored = try shapeGeneratedTracks(board.ctx.arena, board.placement, board.ctx.selected_nets, board.vias.items, board.tracks);
    if (adaptive or authored) router.copperCompacted(board.ctx);
}

const testing = std.testing;

test "pad neck slices form a monotonic taper without exceeding nominal width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(router.Track) = .empty;
    const track = router.Track{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2532, .net = 0 };
    try shapeTrack(arena, &out, .{
        .track = track,
        .nominal = 0.2532,
        .start = .{ .width = 0.1524, .land = 0.75, .taper = 0.35 },
    });
    try testing.expect(out.items.len > 10);
    try testing.expectEqual(@as(f64, 0.1524), out.items[0].width);
    var prior = out.items[0].width;
    for (out.items) |slice| {
        try testing.expect(slice.width + eps >= prior);
        try testing.expect(slice.width <= 0.2532 + eps);
        prior = slice.width;
    }
    try testing.expectApproxEqAbs(@as(f64, 0.2532), out.items[out.items.len - 1].width, eps);
}

// spec: placement/power-routing - an unpoured current-rated rail routes through a QFN-sized land at fabrication width, then grows to its electrical target with an automatic pad taper
test "adaptive power width routes a narrow QFN land then widens the open trunk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pad = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "J1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "J1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.035 },
    };
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 1.2,
        .any_max_load = true,
        .status = .no_source,
    }};
    const rules = [_]optimizer.NetRule{.{ .width = 0.8 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{
            .net = &rules,
            .plane_nets = &.{},
            .copper_layers = 2,
            .design = .{ .track_width = 0.127, .min_width = 0.127, .clearance = 0.127 },
            .physical = .{ .stack = .{ .layers = 2, .foils = &foils }, .rails = &rails },
        },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = true,
    };

    const routed = try router.route(arena, placement, .{ .track_width = 0.127, .clearance = 0.127 });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expectEqual(@as(usize, 0), routed.failed.len);
    var widest: f64 = 0;
    var launch_width: ?f64 = null;
    var distinct_widths: usize = 0;
    var prior: f64 = -1;
    for (routed.tracks) |track| {
        if (track.net != 0) continue;
        widest = @max(widest, track.width);
        if (samePoint(.{ track.x1, track.y1 }, .{ 0, 0 }) or samePoint(.{ track.x2, track.y2 }, .{ 0, 0 }))
            launch_width = if (launch_width) |width| @min(width, track.width) else track.width;
        if (@abs(track.width - prior) > eps) distinct_widths += 1;
        prior = track.width;
    }
    try testing.expect(widest >= 0.8 - 1e-4);
    try testing.expect(launch_width.? <= 0.2 + 1e-4);
    try testing.expect(distinct_widths > 4);
}

// spec: placement/power-routing - an adaptive power launch uses the pad's smaller physical dimension and the shortest 45-degree taper to nominal width
test "adaptive power launch uses minimum pad dimension and a compact taper" {
    const root = @sqrt(0.5);
    const pads = [_]Pad{.{
        .at = .{ 0, 0 },
        .layer = 0,
        .half_w = 1.2,
        .half_h = 0.15,
        .axis_x = .{ 1, 0 },
    }};
    const profile = powerEndpointProfile(&pads, .{ 0, 0 }, 0, 0.4, .{ root, root }).?;
    try testing.expectApproxEqAbs(@as(f64, 0.3), profile.width, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.05), profile.taper, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.15 * @sqrt(2.0)), profile.land, eps);
}

// spec: placement/power-routing - two adaptive power tracks that meet at a bend take the narrower of their two widths at that joint, including where one side is copper this pass left alone, and the wider side tapers back to its electrical target along its own straight
test "adaptive power widths meet at one width where two tracks bend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const G = @import("geometry.zig");
    const trunk_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8 }};
    const fine_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.4, .hh = 0.4, .pads = &trunk_pad, .fallback = false, .x = 5, .y = 2 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.1, .hh = 0.1, .pads = &fine_pad, .fallback = false, .x = 1.85, .y = 1.85 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.035 },
    };
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 0.2,
        .any_max_load = true,
        .status = .no_source,
    }};
    const rules = [_]optimizer.NetRule{.{ .width = 0.8 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{
            .net = &rules,
            .plane_nets = &.{},
            .copper_layers = 2,
            .design = .{ .track_width = 0.127, .min_width = 0.127, .clearance = 0.127 },
            .physical = .{ .stack = .{ .layers = 2, .foils = &foils }, .rails = &rails },
        },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 7,
        .maxy = 5,
        .generated = true,
    };
    // A long open trunk into a 45-degree elbow whose far end is a fine land:
    // the elbow cannot leave that land wide, and before this pass agreed the
    // corner the trunk arrived at full target beside it.
    const corner = [2]f64{ 2, 2 };
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, &.{
        .{ .x1 = 5, .y1 = 2, .x2 = corner[0], .y2 = corner[1], .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = corner[0], .y1 = corner[1], .x2 = 1.85, .y2 = 1.85, .layer = 0, .width = 0.127, .net = 0 },
    });
    var vias: std.ArrayList(router.Via) = .empty;
    const board = (try router.cleanupBoard(arena, placement, .{ .track_width = 0.127, .clearance = 0.127 }, .{}, .{
        .tracks = &tracks,
        .vias = &vias,
    })).?;
    try testing.expect(try adaptPowerTracks(board));

    var at_corner: ?f64 = null;
    var widest: f64 = 0;
    var trunk_widths: usize = 0;
    var prior: f64 = -1;
    for (tracks.items) |slice| {
        widest = @max(widest, slice.width);
        if (@abs(slice.y1 - 2) <= eps and @abs(slice.y2 - 2) <= eps and @abs(slice.width - prior) > eps) {
            trunk_widths += 1;
            prior = slice.width;
        }
        if (!samePoint(.{ slice.x1, slice.y1 }, corner) and !samePoint(.{ slice.x2, slice.y2 }, corner)) continue;
        if (at_corner) |width| try testing.expectEqual(width, slice.width) else at_corner = slice.width;
    }
    try testing.expectApproxEqAbs(@as(f64, 0.8), widest, 1e-4);
    // The corner carries what the elbow can carry there: above the routing
    // floor, below the trunk's target, and identical on both sides.
    try testing.expect(at_corner.? > 0.127 + eps);
    try testing.expect(at_corner.? < widest - eps);
    try testing.expect(trunk_widths > 4);
}

/// A shaped run whose clearance fit came out uniform: what this pass produces
/// for a leg held at one width along its whole length.
fn uniformRun(arena: std.mem.Allocator, track: router.Track, width: f64) std.mem.Allocator.Error!ShapedRun {
    const len = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    var cells: std.ArrayList(AdaptiveCell) = .empty;
    var s0: f64 = 0;
    while (s0 < len - eps) {
        const s1 = @min(len, s0 + adaptive_step_mm);
        try cells.append(arena, .{ .s0 = s0, .s1 = s1, .width = width });
        s0 = s1;
    }
    return .{ .track = track, .len = len, .cells = cells.items };
}

/// How a run reads walking from one end back into the track: the steepest width
/// step between neighbouring cells, the widest cell reached, and whether the
/// walk only ever widens. A legal flank keeps every step inside
/// `adaptive_width_per_length` times the cell pitch.
fn flankProfile(run: ShapedRun, tail: u1) struct { step: f64, widest: f64, monotonic: bool } {
    var prior = run.cells[endCellIndex(run, tail)].width;
    var step: f64 = 0;
    var widest = prior;
    var monotonic = true;
    for (1..run.cells.len) |offset| {
        const width = run.cells[if (tail == 0) offset else run.cells.len - 1 - offset].width;
        step = @max(step, @abs(width - prior));
        widest = @max(widest, width);
        monotonic = monotonic and width >= prior - eps;
        prior = width;
    }
    return .{ .step = step, .widest = widest, .monotonic = monotonic };
}

/// The V_5VA elbow this pass was reported on: a widened straight butt-joining a
/// leg a foreign obstacle held at the routing floor, meeting at 45 degrees.
const bend_corner = [2]f64{ 180.39, 91.99 };
const bend_trunk = router.Track{ .x1 = 181.39, .y1 = 91.99, .x2 = 180.39, .y2 = 91.99, .layer = 0, .width = 0.127, .net = 0 };
const bend_elbow = router.Track{ .x1 = 180.39, .y1 = 91.99, .x2 = 179.9, .y2 = 91.5, .layer = 0, .width = 0.127, .net = 0 };

test "a clearance-necked power leg pulls its bend partner down to a taper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runs = [_]ShapedRun{
        try uniformRun(arena, bend_trunk, 0.2532),
        try uniformRun(arena, bend_elbow, 0.127),
    };
    try equalizeJointWidths(arena, .{
        .runs = &runs,
        .fixed = &.{},
        .vias = &.{},
        .pads = &.{},
        .net = 0,
    });
    const taper = runs[0].cells;
    try testing.expectEqual(@as(f64, 0.127), taper[taper.len - 1].width);
    try testing.expectEqual(@as(f64, 0.127), runs[1].cells[0].width);

    // The wide side gives its width up on its own straight, at the 45-degree
    // flank and nowhere steeper, and still reaches target.
    const flank = flankProfile(runs[0], 1);
    try testing.expect(flank.monotonic);
    try testing.expect(flank.step <= adaptive_width_per_length * adaptive_step_mm + eps);
    try testing.expectApproxEqAbs(@as(f64, 0.2532), flank.widest, eps);

    // No emitted pair differs in width at the shared point.
    var out: std.ArrayList(router.Track) = .empty;
    _ = try emitShapedRun(arena, &out, runs[0]);
    _ = try emitShapedRun(arena, &out, runs[1]);
    var at_corner: ?f64 = null;
    for (out.items) |slice| {
        if (!samePoint(.{ slice.x1, slice.y1 }, bend_corner) and !samePoint(.{ slice.x2, slice.y2 }, bend_corner)) continue;
        if (at_corner) |width| try testing.expectEqual(width, slice.width) else at_corner = slice.width;
    }
    try testing.expectEqual(@as(f64, 0.127), at_corner.?);
}

// spec: placement/power-routing - a three-track junction, a same-net barrel, or a pad land at the meeting point leaves every leg its own width, so only a bare two-track joint is equalized
test "a branched, barrelled or landed power corner keeps each leg's own width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const branch = router.Track{ .x1 = 180.39, .y1 = 91.99, .x2 = 180.39, .y2 = 92.99, .layer = 0, .width = 0.127, .net = 0 };
    const barrels = [_]router.Via{.{ .x = bend_corner[0], .y = bend_corner[1], .dia = 0.6, .drill = 0.3, .net = 0 }};
    const lands = [_]Pad{.{ .at = bend_corner, .layer = 0, .half_w = 0.3, .half_h = 0.3, .axis_x = .{ 1, 0 } }};
    for (0..3) |scenario| {
        var runs = [_]ShapedRun{
            try uniformRun(arena, bend_trunk, 0.2532),
            try uniformRun(arena, bend_elbow, 0.127),
            try uniformRun(arena, branch, 0.2532),
        };
        const before = try arena.dupe(AdaptiveCell, runs[0].cells);
        try equalizeJointWidths(arena, .{
            .runs = runs[0..if (scenario == 0) 3 else 2],
            .fixed = &.{},
            .vias = if (scenario == 1) &barrels else &.{},
            .pads = if (scenario == 2) &lands else &.{},
            .net = 0,
        });
        for (runs[0].cells, before) |cell, unchanged| try testing.expectEqual(unchanged.width, cell.width);
        try testing.expectEqual(@as(f64, 0.2532), runs[0].cells[runs[0].cells.len - 1].width);
        try testing.expectEqual(@as(f64, 0.127), runs[1].cells[0].width);
    }
}

test "a shaped power leg meets copper this pass left alone at that copper's width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runs = [_]ShapedRun{try uniformRun(arena, bend_trunk, 0.2532)};
    // Already wider than the routing floor, so the shaping gates skipped it.
    var skipped = bend_elbow;
    skipped.width = 0.15;
    try equalizeJointWidths(arena, .{
        .runs = &runs,
        .fixed = &.{skipped},
        .vias = &.{},
        .pads = &.{},
        .net = 0,
    });
    const cells = runs[0].cells;
    try testing.expectEqual(@as(f64, 0.15), cells[cells.len - 1].width);
    try testing.expectApproxEqAbs(@as(f64, 0.25), cells[cells.len - 2].width, eps);
    try testing.expectEqual(@as(f64, 0.2532), cells[0].width);
}

test "overlapping endpoint profiles keep a short pad to pad hop narrow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(router.Track) = .empty;
    const track = router.Track{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2532, .net = 0 };
    try shapeTrack(arena, &out, .{
        .track = track,
        .nominal = 0.2532,
        .start = .{ .width = 0.1524, .land = 0.75, .taper = 0.35 },
        .end = .{ .width = 0.1524, .land = 0.75, .taper = 0.35 },
    });
    for (out.items) |slice| try testing.expectApproxEqAbs(@as(f64, 0.1524), slice.width, eps);
}

test "DRC allowance accepts only neck-profile copper beside its own undersized SMD pad" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.25 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &pads,
        .fallback = false,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.2532,
        .pad_neck = .{ .width = 0.1524, .max_length = 0.75, .taper_length = 0.35 },
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .design = .{ .track_width = 0.127, .min_width = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    const near = router.Track{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 0.1524, .net = 0 };
    const far = router.Track{ .x1 = 1.5, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.1524, .net = 0 };
    try testing.expect(try allowsTrack(arena, placement, near, 0.2532, 0.127));
    try testing.expect(!try allowsTrack(arena, placement, far, 0.2532, 0.127));
}

// spec: placement/rf-port-frame-routing - every single-ended controlled-impedance SMD launch tapers between the pad-boundary chord available at its actual path crossing and nominal width, including wider lands, bends inside the pad, full flat-face collars on rectangular and oval pads, and via-fed or branched nets, without diagonal centre-chord flares
test "pad launch span and edge distance follow a diagonal entry" {
    const root = @sqrt(0.5);
    const pad = Pad{
        .at = .{ 0, 0 },
        .layer = 0,
        .half_w = 0.4,
        .half_h = 0.1,
        .axis_x = .{ 1, 0 },
    };
    try testing.expectApproxEqAbs(@as(f64, 0.2 * @sqrt(2.0)), launchSpan(pad, .{ root, root }), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.1 * @sqrt(2.0)), boxRayHalfExtent(pad, .{ root, root }), 1e-12);

    const square = Pad{
        .at = .{ 0, 0 },
        .layer = 0,
        .half_w = 0.25,
        .half_h = 0.25,
        .axis_x = .{ 1, 0 },
    };
    try testing.expectApproxEqAbs(@as(f64, 0), launchSpan(square, .{ root, root }), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), launchSpan(square, .{ 1, 0 }), 1e-12);
}

test "generated controlled-impedance launch tapers both wider and narrower lands on a branched net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const G = @import("geometry.zig");
    const wide_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.6 }};
    const narrow_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.2 }};
    const branch_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &wide_pad, .fallback = false },
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &narrow_pad, .fallback = false, .x = 3 },
        .{ .ref_des = "TP1", .kind = .hub, .hw = 1, .hh = 1, .pads = &branch_pad, .fallback = false, .x = 8 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "TP1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.4,
        // No max-freq is required for the local impedance transition.
        .rf = .{ .impedance = .{ .ohms = 50 } },
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .design = .{ .track_width = 0.127, .min_width = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 9,
        .maxy = 1,
        .generated = true,
    };
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.append(arena, .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.4, .net = 0 });
    try testing.expect(try shapeGeneratedTracks(arena, placement, &.{true}, &.{}, &tracks));
    try testing.expectApproxEqAbs(@as(f64, 0.6), tracks.items[0].width, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.2), tracks.items[tracks.items.len - 1].width, eps);
    var saw_nominal = false;
    for (tracks.items) |track| saw_nominal = saw_nominal or @abs(track.width - 0.4) <= eps;
    try testing.expect(saw_nominal);
}

// spec: placement/rf-port-frame-routing - every single-ended controlled-impedance through-via launch tapers between the via's actual annulus diameter and nominal width independently on every connected signal layer
test "generated controlled-impedance trace tapers into both faces of a through-via" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.2,
        .rf = .{ .impedance = .{ .ohms = 50 } },
    }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .design = .{ .track_width = 0.127, .min_width = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -1,
        .maxx = 2,
        .maxy = 1,
        .generated = true,
    };
    const vias = [_]router.Via{.{ .x = 0, .y = 0, .dia = 0.6, .drill = 0.3, .net = 0 }};
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, &.{
        .{ .x1 = -2, .y1 = 0, .x2 = 0, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
    });

    try testing.expect(try shapeGeneratedTracks(arena, placement, &.{true}, &vias, &tracks));
    var top_via_width: ?f64 = null;
    var bottom_via_width: ?f64 = null;
    var saw_top_nominal = false;
    var saw_bottom_nominal = false;
    for (tracks.items) |track| {
        if (samePoint(.{ track.x2, track.y2 }, .{ 0, 0 }) and track.layer == 0) top_via_width = track.width;
        if (samePoint(.{ track.x1, track.y1 }, .{ 0, 0 }) and track.layer == 1) bottom_via_width = track.width;
        saw_top_nominal = saw_top_nominal or (track.layer == 0 and @abs(track.width - 0.2) <= eps);
        saw_bottom_nominal = saw_bottom_nominal or (track.layer == 1 and @abs(track.width - 0.2) <= eps);
    }
    try testing.expectApproxEqAbs(@as(f64, 0.6), top_via_width.?, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.6), bottom_via_width.?, eps);
    try testing.expect(saw_top_nominal and saw_bottom_nominal);
}

test "generated track keeps nominal width at a land that can carry its launch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const G = @import("geometry.zig");
    const fine_pads = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.80, .h = 0.20 }};
    const roomy_pads = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.54, .h = 0.64 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &fine_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &roomy_pads, .fallback = false, .x = 2 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.35,
        .pad_neck = .{ .width = 0.20, .max_length = 0.50, .taper_length = 0.25 },
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .design = .{ .track_width = 0.127, .min_width = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 3,
        .maxy = 1,
        .generated = true,
    };
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.append(arena, .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.35, .net = 0 });
    try testing.expect(try shapeGeneratedTracks(arena, placement, &.{true}, &.{}, &tracks));
    try testing.expectEqual(@as(f64, 0.20), tracks.items[0].width);
    try testing.expectEqual(@as(f64, 0.35), tracks.items[tracks.items.len - 1].width);
    try testing.expect(!try allowsTrack(arena, placement, .{
        .x1 = 1.7,
        .y1 = 0,
        .x2 = 2,
        .y2 = 0,
        .layer = 0,
        .width = 0.20,
        .net = 0,
    }, 0.35, 0.127));
}

test "DRC allowance recognizes the controlled-impedance land taper profile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.2 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &pads,
        .fallback = false,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .class = .{ .name = "rf" },
        .width = 0.4,
        .rf = .{ .max_freq_hz = 12e9, .impedance = .{ .ohms = 50 } },
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
    };
    const land = router.Track{ .x1 = 0, .y1 = 0, .x2 = 0.3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const taper = router.Track{ .x1 = 0.3, .y1 = 0, .x2 = 0.38, .y2 = 0, .layer = 0, .width = 0.234, .net = 0 };
    const too_thin = router.Track{ .x1 = 0.3, .y1 = 0, .x2 = 0.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const far = router.Track{ .x1 = 2, .y1 = 0, .x2 = 2.1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    try testing.expect(try allowsTrack(arena, placement, land, 0.4, 0.127));
    try testing.expect(try allowsTrack(arena, placement, taper, 0.4, 0.127));
    try testing.expect(!try allowsTrack(arena, placement, too_thin, 0.4, 0.127));
    try testing.expect(!try allowsTrack(arena, placement, far, 0.4, 0.127));
}

test "pad neck recognizes a power-capacity widened routed trunk" {
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 3, .thickness_mm = 0.0152 },
        .{ .index = 4, .thickness_mm = 0.035 },
    };
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 0.34,
        .any_max_load = true,
        .status = .no_source,
    }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.2532,
        .pad_neck = .{ .width = 0.1524, .max_length = 0.75, .taper_length = 0.35 },
    }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .physical = .{ .stack = .{ .layers = 4, .foils = &foils }, .rails = &rails } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const widened = placement.rules.powerWidthForNet("VDD").?;
    try testing.expect(widened > rules[0].width);
    try testing.expectApproxEqAbs(widened, routedNominal(placement, 0, widened).?, eps);
    try testing.expectApproxEqAbs(rules[0].width, routedNominal(placement, 0, rules[0].width).?, eps);
}

/// Shared fixture for the bounded pad-entry neck tests: a 0.3 x 0.8 mm SMD
/// land (span 0.3) on net 0 at the origin, uniform 35 um outer foil.
fn powerNeckPlacement(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet, rules: []const optimizer.NetRule) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .rules = .{
            .net = rules,
            .design = .{ .track_width = 0.127, .min_width = 0.127 },
            .physical = .{ .stack = .{ .layers = 2, .foils = &power_neck_test_foils } },
        },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -20,
        .miny = -20,
        .maxx = 20,
        .maxy = 20,
        .generated = true,
    };
}

const power_neck_test_foils = [_]@import("impedance.zig").Foil{
    .{ .index = 1, .thickness_mm = 0.035 },
    .{ .index = 2, .thickness_mm = 0.035 },
};
const power_neck_test_pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.8 }};
const power_neck_test_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
const power_neck_test_nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &power_neck_test_pins }};
const power_neck_test_rules = [_]optimizer.NetRule{.{}};

// spec: placement/drc - a short neck forced by a same-net land narrower than the solved power width is exempt when its far end reaches solved-width copper, while an overlong neck is not
test "bounded pad-entry power neck is exempt and an overlong one is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &power_neck_test_pads, .fallback = false }};
    const placement = powerNeckPlacement(&parts, &power_neck_test_nets, &power_neck_test_rules);
    const required = [_]f64{ 0.5, 0.5 };
    // Within the fin bound (thermal allowance here is ~9 mm; see the module
    // comment): a 1 mm neck at 0.25 into the 0.3 mm land, trunk at 0.55.
    const short = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.25, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.55, .net = 0 },
    };
    const short_verdict = try judgePowerNeck(arena, .{
        .placement = placement,
        .tracks = &short,
        .vias = &.{},
        .required = &required,
    }, 0);
    try testing.expect(short_verdict.exempt);
    try testing.expectEqual(@as(usize, 1), short_verdict.chain.len);
    // The same neck stretched to 12 mm exceeds the end-conduction bound.
    const long = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 12, .y2 = 0, .layer = 0, .width = 0.25, .net = 0 },
        .{ .x1 = 12, .y1 = 0, .x2 = 14, .y2 = 0, .layer = 0, .width = 0.55, .net = 0 },
    };
    const long_verdict = try judgePowerNeck(arena, .{
        .placement = placement,
        .tracks = &long,
        .vias = &.{},
        .required = &required,
    }, 0);
    try testing.expect(!long_verdict.exempt);
}

// spec: placement/drc - a mid-run pinch between two solved-width runs and a neck narrower than its forcing land both keep the power-width finding
test "mid-run pinch and narrower-than-the-pad copper stay findings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &power_neck_test_pads, .fallback = false }};
    const placement = powerNeckPlacement(&parts, &power_neck_test_nets, &power_neck_test_rules);
    // A pinch far from any land, wide copper on BOTH sides: not a pad neck.
    const pinch = [_]router.Track{
        .{ .x1 = 3, .y1 = 5, .x2 = 4, .y2 = 5, .layer = 0, .width = 0.55, .net = 0 },
        .{ .x1 = 4, .y1 = 5, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.25, .net = 0 },
        .{ .x1 = 5, .y1 = 5, .x2 = 7, .y2 = 5, .layer = 0, .width = 0.55, .net = 0 },
    };
    const pinch_required = [_]f64{ 0.5, 0.5, 0.5 };
    const pinch_verdict = try judgePowerNeck(arena, .{
        .placement = placement,
        .tracks = &pinch,
        .vias = &.{},
        .required = &pinch_required,
    }, 1);
    try testing.expect(!pinch_verdict.exempt);
    // Into the land, but far below the 0.3 mm the land itself supports: the
    // narrowing is a routing choice, not the pad's constraint.
    const skinny = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.55, .net = 0 },
    };
    const skinny_required = [_]f64{ 0.5, 0.5 };
    const skinny_verdict = try judgePowerNeck(arena, .{
        .placement = placement,
        .tracks = &skinny,
        .vias = &.{},
        .required = &skinny_required,
    }, 0);
    try testing.expect(!skinny_verdict.exempt);
    // A neck whose far end reaches nothing wide at all — a dangling stub —
    // keeps its finding even though it starts on the forcing land.
    const stub = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.25, .net = 0 },
    };
    const stub_required = [_]f64{0.5};
    const stub_verdict = try judgePowerNeck(arena, .{
        .placement = placement,
        .tracks = &stub,
        .vias = &.{},
        .required = &stub_required,
    }, 0);
    try testing.expect(!stub_verdict.exempt);
}

// spec: placement/drc - a bounded pad-entry neck may terminate in a same-net poured zone instead of solved-width track copper
test "pad-entry neck ending in a same-net zone is exempt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &power_neck_test_pads, .fallback = false }};
    const placement = powerNeckPlacement(&parts, &power_neck_test_nets, &power_neck_test_rules);
    const zone_poly = [_][2]f64{ .{ 1, -1 }, .{ 3, -1 }, .{ 3, 1 }, .{ 1, 1 } };
    const zones = [_]copper_support.Zone{.{ .net = "VDD", .layer = 0, .poly = &zone_poly }};
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 0, .layer = 0, .width = 0.25, .net = 0 },
    };
    const required = [_]f64{0.5};
    const verdict = try judgePowerNeck(arena, .{
        .placement = placement,
        .tracks = &tracks,
        .vias = &.{},
        .zones = &zones,
        .required = &required,
    }, 0);
    try testing.expect(verdict.exempt);
}
