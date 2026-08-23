//! Whole-board routing-QUALITY ratchet, built from the real `bcuda-lt3045-ldo`
//! board rather than from a shape invented to suit one pass.
//!
//! The audit that produced the fixes ahead of this file measured itself
//! on one module: an LT3045 LDO, DFN-10 with an exposed pad, seven passives, a
//! four-layer stack with a ground plane and a VOUT plane, and two authored
//! `(decouples "IC" PIN)` bonds. That board is the one place every fix was
//! seen to interact — the bend price against the detour guard, the priced
//! gateway escapes against pad-escape reversal, the leg-scoped bypass freeze
//! against the finishing gloss — so it is the one place a regression in any of
//! them shows up as a WORSE BOARD rather than as a unit test that still passes.
//!
//! Unit tests cannot read `projects/`, so the placement is constructed here
//! from the module's measured geometry: U1's eleven lands at their real
//! millimetre offsets, each passive at its real pose, the real net list in the
//! real order, and the four decoupling loops the optimizer resolves (two exact
//! pin bonds, two rail-class reservoirs). The DESIGN-side profile is
//! deliberately NOT reproduced — no `(net-class … (width …))`, no authored
//! route wave — so what this measures is the ROUTER on that geometry and not a
//! design's ability to steer it. The synthetic board therefore lands close to
//! but not identical with the real one (14.14 mm / 22 vias / 12 bends /
//! 3 quality warns / score 983.99 here against 15.081 / 22 / 12 / 3 / 983.89
//! through `route_experiment`), which is the point: the fixture is a ratchet on
//! router quality, and every gate below is a bound with headroom, never a
//! transcript of today's numbers.

const std = @import("std");
const bypass_open = @import("bypass_open.zig");
const drc = @import("drc.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const manhattan_route = @import("manhattan_route.zig");
const optimizer = @import("optimizer.zig");
const pad_shape = @import("pad_shape.zig");
const plane_via = @import("plane_via.zig");
const route_score = @import("route_score.zig");
const router = @import("router.zig");

const testing = std.testing;

// ── The ratchet ─────────────────────────────────────────────────────────────
//
// Each bound is set from a MEASUREMENT of the audited board plus headroom, so
// a legitimate re-shuffle of the same quality passes and the defect class the
// bound names does not.

/// How far past its own terminal MST one net's routed copper may run.
///
/// The MST over a net's pad centres is the shortest copper that could join them
/// if obstacles and layers did not exist, which is the same yardstick
/// `detour_guard` already measures a connection against. One octilinear corner
/// costs at most √2 ≈ 1.414 of the straight line it replaces, so a route that
/// is merely CORNERED stays under 1.5; 1.6 leaves a little more for pad-escape
/// stubs and via approach legs. The defect this catches is the perimeter tour —
/// the audit's VIN leg ran 1.96× its span around a wall of plane barrels — and
/// the worst net here (VIN, 1.19×) sits a long way inside it.
const max_detour_ratio: f64 = 1.6;

/// Terminal span below which a net's detour ratio is not a meaningful reading:
/// a single-pin net has no span at all, and two lands this close share one
/// escape rather than a route. Every multi-terminal net on this board spans
/// more than a millimetre, so nothing real is excused by it.
const detour_min_span_mm: f64 = 0.5;

/// Direction changes allowed over the whole board (`route_score.bendCount`).
/// The maze draws 12 here and 12 on the real module; the audit-era router drew
/// 19+ on the same geometry. Sixteen is above any plausible re-shuffle of a
/// twelve-corner board and far below a staircase.
const max_bends: usize = 16;

/// Barrels allowed over the whole board. GND has nine lands and VOUT five, each
/// wanting one plane drop, plus the signal transitions — 22 today. Twenty-six
/// leaves four for a legitimately different topology while refusing the
/// double-stitched boards the via-in-pad and island passes used to leave.
const max_vias: usize = 26;

/// Self-inflicted DRC warnings allowed (`route_score.qualityWarnCount`:
/// `dangling_copper` + `land_transit`). Three here, three on the real module,
/// 24+ before the audit. Six holds the win with room for one extra land
/// transit on a re-shuffle.
const max_quality_warns: usize = 6;

/// Copper sections shorter than this are the router's micro-tail dead zone —
/// above `route_cleanup.dropDegenerateTracks`'s 1 µm floor and below the
/// chamfer floor — so a section in it is either deliberate pad-neck copper or
/// an artifact. See `looseMicroTails`.
const micro_tail_mm: f64 = 0.1;

// ── The board ───────────────────────────────────────────────────────────────

/// U1, an LT3045 in a DFN-10 with an exposed pad: two columns of 0.8 × 0.3 mm
/// lands on a 0.5 mm pitch, and the 1.75 × 2.48 mm paddle at the origin.
const dfn10_pads = [_]geometry.Pad{
    .{ .number = "1", .x = -1.5, .y = -1.0, .w = 0.8, .h = 0.3 },
    .{ .number = "2", .x = -1.5, .y = -0.5, .w = 0.8, .h = 0.3 },
    .{ .number = "3", .x = -1.5, .y = 0.0, .w = 0.8, .h = 0.3 },
    .{ .number = "4", .x = -1.5, .y = 0.5, .w = 0.8, .h = 0.3 },
    .{ .number = "5", .x = -1.5, .y = 1.0, .w = 0.8, .h = 0.3 },
    .{ .number = "6", .x = 1.5, .y = 1.0, .w = 0.8, .h = 0.3 },
    .{ .number = "7", .x = 1.5, .y = 0.5, .w = 0.8, .h = 0.3 },
    .{ .number = "8", .x = 1.5, .y = 0.0, .w = 0.8, .h = 0.3 },
    .{ .number = "9", .x = 1.5, .y = -0.5, .w = 0.8, .h = 0.3 },
    .{ .number = "10", .x = 1.5, .y = -1.0, .w = 0.8, .h = 0.3 },
    .{ .number = "11", .x = 0, .y = 0, .w = 1.75, .h = 2.48 },
};
/// A 0402 resistor's two lands.
const r0402_pads = [_]geometry.Pad{
    .{ .number = "1", .x = -0.51, .y = 0, .w = 0.54, .h = 0.64, .shape = "roundrect" },
    .{ .number = "2", .x = 0.51, .y = 0, .w = 0.54, .h = 0.64, .shape = "roundrect" },
};
/// A 0402 capacitor's two lands.
const c0402_pads = [_]geometry.Pad{
    .{ .number = "1", .x = -0.48, .y = 0, .w = 0.56, .h = 0.62, .shape = "roundrect" },
    .{ .number = "2", .x = 0.48, .y = 0, .w = 0.56, .h = 0.62, .shape = "roundrect" },
};
/// A 0603 capacitor's two lands.
const c0603_pads = [_]geometry.Pad{
    .{ .number = "1", .x = -0.78, .y = 0, .w = 0.90, .h = 0.95, .shape = "roundrect" },
    .{ .number = "2", .x = 0.78, .y = 0, .w = 0.90, .h = 0.95, .shape = "roundrect" },
};

/// The eight placed parts at the poses the module's saved layout holds:
/// R1 = R_SET, R2 = R_PG, C1 = C_SET, C2 = C_VIN, C3 = C_VIN_HF,
/// C4 = C_VOUT, C5 = C_BULK. Courtyards touch edge to edge exactly as they do
/// on the real board, so the router sees the same 8.2 × 5.1 mm of laminate.
const parts = [_]optimizer.Part{
    .{ .ref_des = "U1", .kind = .hub, .hw = 2.1, .hh = 1.4, .pads = &dfn10_pads, .fallback = false, .x = 0, .y = 0 },
    .{ .ref_des = "R1", .kind = .passive, .hw = 1.0, .hh = 0.5, .pads = &r0402_pads, .fallback = false, .x = 3.1, .y = 1.1 },
    .{ .ref_des = "R2", .kind = .passive, .hw = 1.0, .hh = 0.5, .pads = &r0402_pads, .fallback = false, .x = -2.6, .y = 1.3, .rot = 90 },
    .{ .ref_des = "C1", .kind = .passive, .hw = 1.0, .hh = 0.5, .pads = &c0402_pads, .fallback = false, .x = 3.1, .y = 0.1 },
    .{ .ref_des = "C2", .kind = .passive, .hw = 1.4, .hh = 0.7, .pads = &c0603_pads, .fallback = false, .x = -1.3, .y = -2.1 },
    .{ .ref_des = "C3", .kind = .passive, .hw = 1.0, .hh = 0.5, .pads = &c0402_pads, .fallback = false, .x = -3.1, .y = -0.9, .rot = 180 },
    .{ .ref_des = "C4", .kind = .passive, .hw = 1.4, .hh = 0.7, .pads = &c0603_pads, .fallback = false, .x = 1.5, .y = -2.1, .rot = 180 },
    .{ .ref_des = "C5", .kind = .passive, .hw = 1.0, .hh = 0.5, .pads = &c0402_pads, .fallback = false, .x = 3.1, .y = -0.9 },
};

const set_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "7" },
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "C1", .pin = "1" },
};
const pg_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "4" },
    .{ .ref_des = "R2", .pin = "1" },
};
const gnd_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "5" },
    .{ .ref_des = "U1", .pin = "8" },
    .{ .ref_des = "U1", .pin = "11" },
    .{ .ref_des = "R1", .pin = "2" },
    .{ .ref_des = "C1", .pin = "2" },
    .{ .ref_des = "C2", .pin = "2" },
    .{ .ref_des = "C3", .pin = "2" },
    .{ .ref_des = "C4", .pin = "2" },
    .{ .ref_des = "C5", .pin = "2" },
};
const vout_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "9" },
    .{ .ref_des = "U1", .pin = "10" },
    .{ .ref_des = "R2", .pin = "2" },
    .{ .ref_des = "C4", .pin = "1" },
    .{ .ref_des = "C5", .pin = "1" },
};
const vin_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "1" },
    .{ .ref_des = "U1", .pin = "2" },
    .{ .ref_des = "U1", .pin = "6" },
    .{ .ref_des = "C2", .pin = "1" },
    .{ .ref_des = "C3", .pin = "1" },
};
/// EN/UV leaves the module through a port and touches one pad, so it is a
/// terminal the board cannot route — the reason `total` is 5 and not 6.
const en_uv_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "3" }};

/// The flattened nets in the order the real design produces them; net order
/// decides routing order and several tie-breaks, so it is part of the fixture.
const nets = [_]flat_netlist.FlatNet{
    .{ .name = "SET", .pins = &set_pins },
    .{ .name = "PG", .pins = &pg_pins },
    .{ .name = "GND", .pins = &gnd_pins },
    .{ .name = "VOUT", .pins = &vout_pins },
    .{ .name = "VIN", .pins = &vin_pins },
    .{ .name = "EN_UV", .pins = &en_uv_pins },
};

/// Routable nets — every one but the port-only EN/UV.
const routable_nets: usize = 5;

const net_vout: i32 = 3;
const net_vin: i32 = 4;

const c0402_pwr = optimizer.PadRect{ .x = -0.48, .y = 0, .w = 0.56, .h = 0.62 };
const c0402_gnd = optimizer.PadRect{ .x = 0.48, .y = 0, .w = 0.56, .h = 0.62 };
const c0603_pwr = optimizer.PadRect{ .x = -0.78, .y = 0, .w = 0.90, .h = 0.95 };
const c0603_gnd = optimizer.PadRect{ .x = 0.78, .y = 0, .w = 0.90, .h = 0.95 };
const u1_pin1 = optimizer.PadRect{ .x = -1.5, .y = -1.0, .w = 0.8, .h = 0.3 };
const u1_pin2 = optimizer.PadRect{ .x = -1.5, .y = -0.5, .w = 0.8, .h = 0.3 };
const u1_pin5 = optimizer.PadRect{ .x = -1.5, .y = 1.0, .w = 0.8, .h = 0.3 };
const u1_pin6 = optimizer.PadRect{ .x = 1.5, .y = 1.0, .w = 0.8, .h = 0.3 };
const u1_pin8 = optimizer.PadRect{ .x = 1.5, .y = 0.0, .w = 0.8, .h = 0.3 };
const u1_pin9 = optimizer.PadRect{ .x = 1.5, .y = -0.5, .w = 0.8, .h = 0.3 };
const u1_pin10 = optimizer.PadRect{ .x = 1.5, .y = -1.0, .w = 0.8, .h = 0.3 };
const u1_pad11 = optimizer.PadRect{ .x = 0, .y = 0, .w = 1.75, .h = 2.48 };

const vin_hub_pads = [_]optimizer.PadRect{ u1_pin1, u1_pin2, u1_pin6 };
const vout_hub_pads = [_]optimizer.PadRect{ u1_pin9, u1_pin10 };
const gnd_hub_pads = [_]optimizer.PadRect{ u1_pin5, u1_pin8, u1_pad11 };

/// The four decoupling loops the optimizer resolves for this module: the two
/// authored exact-pin bonds (`C_VIN_HF` → pin 1, `C_VOUT` → pin 10) and the two
/// `(decouples rail)` reservoirs, whose `rail_optout` says the local leg is not
/// required of them.
const loops = [_]optimizer.Loop{
    .{
        .cap = 5,
        .hub = 0,
        .cap_pwr = c0402_pwr,
        .cap_gnd = c0402_gnd,
        .hub_pwr = &vin_hub_pads,
        .hub_pwr_pin = u1_pin1,
        .hub_gnd = &gnd_hub_pads,
        .hub_gnd_pin = u1_pad11,
        .pwr_net = net_vin,
        .explicit_pin = "1",
    },
    .{
        .cap = 6,
        .hub = 0,
        .cap_pwr = c0603_pwr,
        .cap_gnd = c0603_gnd,
        .hub_pwr = &vout_hub_pads,
        .hub_pwr_pin = u1_pin10,
        .hub_gnd = &gnd_hub_pads,
        .hub_gnd_pin = u1_pad11,
        .pwr_net = net_vout,
        .explicit_pin = "10",
    },
    .{
        .cap = 4,
        .hub = 0,
        .cap_pwr = c0603_pwr,
        .cap_gnd = c0603_gnd,
        .hub_pwr = &vin_hub_pads,
        .hub_pwr_pin = u1_pin1,
        .hub_gnd = &gnd_hub_pads,
        .hub_gnd_pin = u1_pad11,
        .pwr_net = net_vin,
        .rail_optout = true,
    },
    .{
        .cap = 7,
        .hub = 0,
        .cap_pwr = c0402_pwr,
        .cap_gnd = c0402_gnd,
        .hub_pwr = &vout_hub_pads,
        .hub_pwr_pin = u1_pin9,
        .hub_gnd = &gnd_hub_pads,
        .hub_gnd_pin = u1_pad11,
        .pwr_net = net_vout,
        .rail_optout = true,
    },
};

/// `(stackup 4 (plane 2 "GND") (plane 3 "VOUT"))` — the module pins both inner
/// planes so a netlist reorder cannot flip which rail owns one.
const declared_planes = [_]optimizer.PlaneAt{
    .{ .index = 2, .net = "GND" },
    .{ .index = 3, .net = "VOUT" },
};
const plane_names = [_][]const u8{ "GND", "VOUT" };

/// The fixture placement. Parts and loops are duplicated into `arena` because
/// `Placement` holds them mutably and the router may repose nothing but must
/// still be handed writable storage.
fn fixture(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    return .{
        .parts = try arena.dupe(optimizer.Part, &parts),
        .links = &.{},
        .loops = try arena.dupe(optimizer.Loop, &loops),
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -4.1,
        .miny = -2.8,
        .maxx = 4.1,
        .maxy = 2.3,
        .generated = true,
        .rules = .{
            .plane_nets = &plane_names,
            .copper_layers = 4,
            .planes = .{ .declared = &declared_planes },
        },
        .board_rect = .{ .minx = -4.1, .miny = -2.8, .w = 8.2, .h = 5.1 },
    };
}

/// One routed fixture: the placement it came from, the copper, and the board
/// rules the DRC has to be run under (the design authors none, so these are the
/// toolchain defaults — 0.127 mm track and clearance, a 0.4/0.2 mm via).
const Routed = struct {
    placement: optimizer.Placement,
    result: router.RouteResult,
    params: router.RouteParams,
};

/// Build and route the fixture through the ordinary whole-board entry.
fn route(arena: std.mem.Allocator) std.mem.Allocator.Error!Routed {
    const placement = try fixture(arena);
    const params = placement.rules.design.routeParams();
    return .{
        .placement = placement,
        .result = try router.routeWithOptions(arena, placement, params, .{}),
        .params = params,
    };
}

// ── Measurements ────────────────────────────────────────────────────────────

/// Total routed copper (mm) — the score's `trace_mm` term.
fn traceMm(tracks: []const router.Track) f64 {
    var mm: f64 = 0;
    for (tracks) |t| mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    return mm;
}

/// Routed copper (mm) on one flattened net index.
fn netCopperMm(tracks: []const router.Track, net: i32) f64 {
    var mm: f64 = 0;
    for (tracks) |t| {
        if (t.net != net) continue;
        mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return mm;
}

/// Ref-des → part index, the lookup `pad_exit.netPoints` resolves terminals
/// through.
fn partIndex(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(usize) {
    var idx: std.StringHashMapUnmanaged(usize) = .empty;
    for (placement.parts, 0..) |part, i| try idx.put(arena, part.ref_des, i);
    return idx;
}

/// Every net's terminal MST (mm), index-aligned with `placement.nets` — the
/// shortest copper that could join each net's pads with no obstacles and no
/// layers, measured through the router's own `manhattan_route.mstMm`.
fn netSpans(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
) std.mem.Allocator.Error![]f64 {
    var idx = try partIndex(arena, placement);
    const out = try arena.alloc(f64, placement.nets.len);
    for (placement.nets, 0..) |net, i| {
        out[i] = try manhattan_route.mstMm(arena, try router.netPoints(arena, placement, &idx, net));
    }
    return out;
}

/// The largest per-net detour ratio on the board — routed copper over the net's
/// own terminal span — over the nets whose span is large enough to read.
fn worstDetourRatio(tracks: []const router.Track, spans: []const f64) f64 {
    var worst: f64 = 0;
    for (spans, 0..) |span, i| {
        if (!(span > detour_min_span_mm)) continue;
        worst = @max(worst, netCopperMm(tracks, @intCast(i)) / span);
    }
    return worst;
}

/// Sum of every net's terminal span (mm) — the denominator the whole board's
/// copper budget is derived from.
fn totalSpanMm(spans: []const f64) f64 {
    var mm: f64 = 0;
    for (spans) |s| mm += s;
    return mm;
}

/// How many sections the closing gloss would still change if it ran again over
/// this finished board.
///
/// `route_cleanup.glossFinishedTracks` — reached through the router's own
/// public seam — is what removes duplicate sections, fuses collinear runs, and
/// drops sub-half-width tails, and the finish runs it after every copper
/// emitter. Running it once more over the returned board is therefore the exact
/// question "did the finish leave a duplicate or a micro-tail behind", asked
/// with the router's own predicate rather than a second one written here. Zero
/// means the board is the gloss's own fixed point.
fn glossRewrites(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    result: router.RouteResult,
) std.mem.Allocator.Error!usize {
    var tracks: std.ArrayList(router.Track) = .empty;
    var mutable: std.ArrayList(bool) = .empty;
    for (result.tracks) |t| {
        try tracks.append(arena, t);
        try mutable.append(arena, true);
    }
    try router.glossFinishedTracks(arena, placement, &tracks, &mutable, result.vias);
    if (tracks.items.len != result.tracks.len) {
        return @max(tracks.items.len, result.tracks.len) - @min(tracks.items.len, result.tracks.len);
    }
    var changed: usize = 0;
    for (tracks.items, result.tracks) |after, before| {
        if (!std.meta.eql(after, before)) changed += 1;
    }
    return changed;
}

/// Is `p` held by same-net copper other than section `self_i` — a land of its
/// own net, a same-net barrel, or a junction on another same-net run?
fn endHeld(
    obs: []const router.PadObs,
    tracks: []const router.Track,
    vias: []const router.Via,
    self_i: usize,
    t: router.Track,
    p: [2]f64,
) bool {
    if (plane_via.landAt(obs, p, t.net, t.layer) != null) return true;
    for (vias) |v| {
        if (v.net != t.net) continue;
        if (std.math.hypot(v.x - p[0], v.y - p[1]) <= v.dia / 2) return true;
    }
    for (tracks, 0..) |other, i| {
        if (i == self_i or other.net != t.net or other.layer != t.layer) continue;
        const near = pad_shape.closestOnSeg(other.x1, other.y1, other.x2, other.y2, p[0], p[1]);
        if (near.d <= route_score.bend_join_tol_mm) return true;
    }
    return false;
}

/// Sub-`micro_tail_mm` sections that are neither pad-neck/taper copper nor held
/// at BOTH ends.
///
/// A necked section is deliberate: `pad_neck` draws the narrow entry and its
/// taper in pieces this short, and its width is below the board track width by
/// construction. Everything else that short has to terminate on something —
/// a land, a barrel, or a junction with the run it belongs to — or it is the
/// dangling micron the finish is supposed to have removed.
fn looseMicroTails(
    arena: std.mem.Allocator,
    routed: Routed,
) std.mem.Allocator.Error!usize {
    const obs = try router.buildObstacles(arena, routed.placement.parts, routed.placement.nets);
    const tracks = routed.result.tracks;
    var loose: usize = 0;
    for (tracks, 0..) |t, i| {
        if (std.math.hypot(t.x2 - t.x1, t.y2 - t.y1) >= micro_tail_mm) continue;
        if (t.width < routed.params.track_width) continue;
        if (!endHeld(obs, tracks, routed.result.vias, i, t, .{ t.x1, t.y1 })) loose += 1;
        if (!endHeld(obs, tracks, routed.result.vias, i, t, .{ t.x2, t.y2 })) loose += 1;
    }
    return loose;
}

/// Barrels standing IN one of their own net's lands with the ring hanging off
/// it, split by whether the land could have held the ring anywhere.
///
/// `viaClearsPads` skips the routing net's own copper, so the one land a
/// via-in-pad stands on is exactly the copper no clearance rule inspects;
/// `plane_via.barrelFits` is the predicate that closed that hole and this is
/// the board-level reading of it, taken through the same `landAt` the router
/// resolves a site's land with.
const Overhangs = struct {
    /// Rings hanging off a land that COULD have contained them — the defect
    /// containment exists to refuse, and always zero.
    avoidable: usize = 0,
    /// Rings on a land whose bounding box is narrower than the barrel, so NO
    /// site on it could have contained one. This is the documented degradation
    /// (`placement/plane-via`), not a routing choice — but it is counted rather
    /// than ignored, because a pass that stopped containing barrels would put
    /// several more of them on this board's DFN lands.
    unfittable: usize = 0,
};

/// The two overhang populations over the finished board's barrels.
fn overhangingBarrels(
    arena: std.mem.Allocator,
    routed: Routed,
) std.mem.Allocator.Error!Overhangs {
    const obs = try router.buildObstacles(arena, routed.placement.parts, routed.placement.nets);
    var out = Overhangs{};
    for (routed.result.vias) |v| {
        for ([_]u8{ 0, 1 }) |layer| {
            const land = plane_via.landAt(obs, .{ v.x, v.y }, v.net, layer) orelse continue;
            if (plane_via.barrelFits(land, .{ v.x, v.y }, v.dia)) continue;
            if (@min(land.x1 - land.x0, land.y1 - land.y0) < v.dia) {
                out.unfittable += 1;
                continue;
            }
            out.avoidable += 1;
        }
    }
    return out;
}

/// Rings allowed on a land too small to hold one.
///
/// Exactly one exists here: the VIN escape's transition at U1 pin 6, whose
/// 0.8 × 0.30 mm DFN land is 0.10 mm short of a 0.4 mm ring in y, so no site on
/// it could contain the barrel — the same geometry `placement/plane-via`
/// records for U1's ground lands. Bounding it at one is what makes a
/// containment regression fail HERE: measured, a `barrelFits` that always says
/// yes puts the plane pass back on two more of those DFN lands.
const max_unfittable_barrels: usize = 1;

/// The v2 score inputs this board presents, measured exactly the way
/// `route_experiment` and the route-review replay measure them.
fn scoreInputs(
    arena: std.mem.Allocator,
    routed: Routed,
) std.mem.Allocator.Error!route_score.Inputs {
    const violations = try drc.check(arena, routed.placement, routed.result, routed.params.clearance);
    return .{
        .routed = routed.result.routed,
        .total = routed.result.total,
        .vias = routed.result.vias.len,
        .trace_mm = traceMm(routed.result.tracks),
        .drc_errors = drc.errorCount(violations),
        .bends = try route_score.bendCount(arena, routed.result.tracks),
        .quality_warns = route_score.qualityWarnCount(violations),
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

// spec: placement/ldo-route-quality - the LT3045 fixture routes every routable net with no fab-blocking DRC error, and both authored bypass bonds close over surface copper
// spec: placement/ldo-route-quality - no barrel on the LT3045 fixture hangs its ring off a land that could have contained it, and only the one DFN land too small for any ring carries one that does
test "the LT3045 fixture routes complete, fab-clean, and bonded" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = try route(arena);

    // EN/UV touches one pad and leaves through a port, so five nets are
    // routable and all five must route.
    try testing.expectEqual(routable_nets, routed.result.total);
    try testing.expectEqual(routable_nets, routed.result.routed);
    try testing.expectEqual(@as(usize, 0), routed.result.failed.len);

    const violations = try drc.check(arena, routed.placement, routed.result, routed.params.clearance);
    try testing.expectEqual(@as(usize, 0), drc.errorCount(violations));

    // The two `(decouples "IC" PIN)` bonds — C_VIN_HF → U1.1 and C_VOUT → U1.10
    // — are the loops whose local leg is REQUIRED, and `bypass_open` asks the
    // only question that settles it: continuous same-face copper from the cap's
    // rail land to that exact IC supply land, vias and pours excluded.
    const opens = try bypass_open.check(arena, routed.placement, routed.result.tracks);
    try testing.expectEqual(@as(usize, 0), opens.len);

    // Every barrel that stands in one of its own lands keeps its ring on that
    // land's copper, save the one land on this footprint that could not hold a
    // ring at any site.
    const overhangs = try overhangingBarrels(arena, routed);
    try testing.expectEqual(@as(usize, 0), overhangs.avoidable);
    try testing.expect(overhangs.unfittable <= max_unfittable_barrels);
}

// spec: placement/ldo-route-quality - no routed net on the LT3045 fixture runs past its own terminal span by more than the detour budget, and the board's corner count, via count, and self-inflicted warnings all stay inside their measured ceilings
test "the LT3045 fixture's copper stays short, straight, and cheap" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = try route(arena);
    const spans = try netSpans(arena, routed.placement);
    const inputs = try scoreInputs(arena, routed);

    // No net tours the board: the worst leg here is VIN at 1.19x its own span.
    try testing.expect(worstDetourRatio(routed.result.tracks, spans) <= max_detour_ratio);
    // …and the same budget over the whole board, which also covers copper on a
    // net too small for the per-net reading.
    try testing.expect(inputs.trace_mm <= max_detour_ratio * totalSpanMm(spans));

    try testing.expect(inputs.bends <= max_bends);
    try testing.expect(inputs.vias <= max_vias);
    try testing.expect(inputs.quality_warns <= max_quality_warns);
}

// spec: placement/ldo-route-quality - the LT3045 fixture's finished copper is the closing gloss's own fixed point, and every sub-0.1mm section is either pad-neck copper or held at both ends
test "the LT3045 fixture leaves no duplicate section and no dangling micro-tail" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = try route(arena);

    try testing.expectEqual(@as(usize, 0), try glossRewrites(arena, routed.placement, routed.result));
    try testing.expectEqual(@as(usize, 0), try looseMicroTails(arena, routed));
}

// spec: placement/ldo-route-quality - the LT3045 fixture's v2 route score clears the score of the worst board its own quality gates still admit
test "the LT3045 fixture's route score clears the floor its gates imply" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = try route(arena);
    const spans = try netSpans(arena, routed.placement);
    const inputs = try scoreInputs(arena, routed);

    // The floor is DERIVED, not quoted: it is `route_score.score` evaluated at
    // the limit of every gate this file asserts — all five nets routed, no DRC
    // error, `max_vias` barrels, `max_detour_ratio` times the board's total
    // terminal span in copper, `max_bends` corners, `max_quality_warns`
    // warnings. So it is the score of the worst board this fixture still
    // accepts (975.28 against today's 983.99), and it moves with the gates
    // rather than with the router.
    //
    // Being implied by the conjunction is exactly what makes it worth
    // asserting: it is a pin between the SCALAR the routing loop optimizes and
    // the geometry this file bounds. A future formula that grew a penalty term
    // none of these gates bounds would charge the real board for it and not the
    // floor, and this is where the two stop agreeing.
    const floor = route_score.score(.{
        .routed = routable_nets,
        .total = routable_nets,
        .vias = max_vias,
        .trace_mm = max_detour_ratio * totalSpanMm(spans),
        .drc_errors = 0,
        .bends = max_bends,
        .quality_warns = max_quality_warns,
    });
    try testing.expectEqual(@as(u32, 2), route_score.formula_version);
    try testing.expect(route_score.score(inputs) >= floor);
}

// spec: placement/ldo-route-quality - routing the LT3045 fixture twice yields byte-identical copper, so the audit's retries and guards stay deterministic
test "routing the LT3045 fixture twice is byte-identical" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The campaign added a detour retry, a via retry, an escalation tier and a
    // cancel tail. Every one of them is a second opinion taken mid-route, and a
    // second opinion that depended on allocation addresses or on iteration
    // order would show up here and nowhere else.
    const first = try route(arena);
    const second = try route(arena);
    try testing.expectEqual(first.result.routed, second.result.routed);
    try testing.expectEqual(first.result.total, second.result.total);
    try testing.expectEqualSlices(router.Track, first.result.tracks, second.result.tracks);
    try testing.expectEqualSlices(router.Via, first.result.vias, second.result.vias);
}
