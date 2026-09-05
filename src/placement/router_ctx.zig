//! The autorouter's routing CONTEXT — the board model every search shares.
//!
//! `router.zig` owns the passes (greedy, rip-up, gap closing, the rescue
//! ladder); this file owns the state those passes route against, and the
//! primitive questions they ask of it:
//!
//!   * `Ctx` — the per-run context: the grid, the pad obstacle list, the
//!     per-signal-layer copper occupancy and diagonal reservations, the
//!     effective per-net geometry, and every mask or policy a pass arms on it.
//!   * the obstacle model — `buildObstacles`, `netPriority`, the board-outline
//!     mask, and `blocked` / `staticBlocked`: the question the maze asks once
//!     per node.
//!   * the copper model — stamping routed copper, RF halos and keepout discs
//!     into `occ` / `resv`, plus the lazily built spatial indexes
//!     (`pad_index`, `copper_index`) that keep the exact probes a superset
//!     prefilter rather than a different answer.
//!   * the exact clearance predicates — `viaClears*` / `segClears*` — which
//!     judge off-grid geometry the raster cannot represent.
//!   * the retained-pour queries (`netPourCovers`, `pourLiveNear`,
//!     `zoneBlocksPoint`).
//!
//! Nothing here decides WHERE copper goes: it only says what the board is and
//! whether a proposed piece of copper is legal. That is why it is a leaf —
//! it imports no other router module, so every pass module can import it.
//! Split out of `router.zig` verbatim (2026-09-05).

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const clock = @import("../infra/clock.zig");
const optimizer = @import("optimizer.zig");
const module_policy = @import("module_policy.zig");
const route_policy = @import("route_policy.zig");
const pair_pinch = @import("pair_pinch.zig");
const octilinear = @import("octilinear.zig");
const manhattan_route = @import("manhattan_route.zig");
const net_topology = @import("net_topology.zig");
const maze_scratch = @import("maze_scratch.zig");
const congestion = @import("congestion.zig");
const pad_shape = @import("pad_shape.zig");
const pad_grid = @import("pad_grid.zig");
const plane_stitch = @import("plane_stitch.zig");
const plane_via = @import("plane_via.zig");
const keepout = @import("keepout.zig");
const disc_stamp = @import("disc_stamp.zig");
const rf_shadow = @import("rf_shadow.zig");
const pad_exit = @import("pad_exit.zig");
const power_route_width = @import("power_route_width.zig");
const rf_port_report = @import("rf_port_report.zig");
const route_result = @import("route_result.zig");
const router_support = @import("router_support.zig");
const outline_mod = @import("outline.zig");
const route_timing = @import("route_timing.zig");
const route_grid = @import("route_grid.zig");
const via_rules = @import("router_via_rules.zig");
const flat_netlist = @import("../flat_netlist.zig");
const numeric = @import("../numeric.zig");
const net_name = @import("../net_name.zig");

const segPointDist = pad_shape.segPointDist;
const segSegDist = pad_shape.segSegDist;
const Part = optimizer.Part;
const FlatNet = flat_netlist.FlatNet;
const isGroundName = optimizer.isGroundName;
const shortName = net_name.leaf;
const RouteParams = router_support.RouteParams;
const PadObs = pad_grid.PadObs;
const Track = route_result.Track;
const Via = route_result.Via;
const Arc = route_result.Arc;
const SharpBend = route_result.SharpBend;
const RoutePq = maze_scratch.RoutePq;

/// Occupancy/reservation sentinel for a grid cell no net has claimed.
pub const empty_cell: i32 = -1;
pub const sqrt2: f64 = 1.4142135623730951; // diagonal step length vs. orthogonal
/// Geometry comparisons use the same one-nanometre tolerance as `drc.zig`,
/// so a route on an exact decimal clearance boundary is accepted consistently.
pub const clearance_eps: f64 = 1e-6;
pub fn perimeterAllowed(ctx: *const Ctx, net: i32) bool {
    if (net < 0) return false;
    const i: usize = @intCast(net);
    return i < ctx.perimeter_allowed.len and ctx.perimeter_allowed[i];
}
/// Exact via-to-outline test for both grid and off-grid synthesis. Mirrors the
/// DRC's staging exemption and measures the candidate's real copper radius;
/// nearest-node lookup is not safe for direct/escape candidates between nodes.
pub fn viaClearsOutline(ctx: *const Ctx, x: f64, y: f64, net: i32) bool {
    if (!via_rules.clearsOutline(
        ctx.board_rect,
        ctx.board_poly,
        ctx.params.via_dia,
        ctx.edge_clearance,
        x,
        y,
    )) return false;
    if (!(ctx.perimeter_via_clearance > 0) or perimeterAllowed(ctx, net)) return true;
    return via_rules.clearsOutline(
        ctx.board_rect,
        ctx.board_poly,
        ctx.params.via_dia,
        ctx.perimeter_via_clearance,
        x,
        y,
    );
}
// ── Grid + helpers ─────────────────────────────────────────────────────────

/// The routing raster, aliased so every maze call site still names it `Grid`.
pub const Grid = route_grid.Grid;

pub const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Allocate `n_layers` per-signal-layer node grids of `nodes` cells each,
/// all initialised EMPTY — the shape `Ctx.occ`/`Ctx.resv` carry.
pub fn allocLayerGrids(arena: std.mem.Allocator, n_layers: usize, nodes: usize) std.mem.Allocator.Error![][]i32 {
    const out = try arena.alloc([]i32, n_layers);
    for (out) |*l| {
        l.* = try arena.alloc(i32, nodes);
        @memset(l.*, empty_cell);
    }
    return out;
}

/// Distance from a point to an axis-aligned rect (0 if inside).
pub fn distPointRect(px: f64, py: f64, r: Rect) f64 {
    const dx = @max(@max(r.x0 - px, px - r.x1), 0);
    const dy = @max(@max(r.y0 - py, py - r.y1), 0);
    return @sqrt(dx * dx + dy * dy);
}

/// Build the pad-obstacle list: *every* pad of every part, as a world rect
/// tagged with its flattened-net index (−1 when the pad is on no net). This is
/// the exact pad set `drc.zig` checks against, so the router avoids precisely
/// what the DRC flags — connected pads *and* NC/mechanical pads alike.
pub fn buildObstacles(arena: std.mem.Allocator, parts: []const Part, nets: []const FlatNet) std.mem.Allocator.Error![]PadObs {
    var pin_net = std.StringHashMapUnmanaged(i32).empty;
    for (nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(arena, key, @intCast(ni));
        }
    }
    var obs: std.ArrayList(PadObs) = .empty;
    for (parts) |part| {
        for (part.pads) |pad| {
            const sh = try pad_shape.worldShape(arena, part, pad);
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
            const net = pin_net.get(key) orelse -1;
            try obs.append(arena, .{
                .x0 = sh.x0,
                .y0 = sh.y0,
                .x1 = sh.x1,
                .y1 = sh.y1,
                .poly = sh.poly,
                .net = net,
                .layer = router_support.sideLayer(part),
                .thru = pad.thru,
            });
        }
    }
    return obs.toOwnedSlice(arena);
}

/// Bits reserved for the intrinsic net-class rank in a net's sort key. The
/// authored `(net-class … (priority N))` tier occupies the high bits and always
/// dominates; the intrinsic rank only orders nets the author left unranked and
/// breaks ties between equal-ranked ones. Three bits leaves the auto rules room
/// to grow; today they use only ranks 0–1.
const netclass_bits = 3;

/// Highest authored `(net-class … (priority N))` tier a net can declare —
/// parse-time clamps to this, and `netPriority` clamps again defensively so a
/// corrupt rule can't shift garbage into the sort key's high bits.
const max_net_priority: u32 = 7;

/// A net's routing priority. Primary key (high bits): the authored
/// `(net-class … (priority N))` tier from the design source, 0 when the net is
/// in no class — explicit author intent always dominates. Secondary key (the
/// low `NETCLASS_BITS` bits): the net's intrinsic routing criticality — the
/// switcher hot loop and its input rail route ahead of the pack (Phase 3 of the
/// module-placement ruleset). Routing a critical net first lets it claim the
/// short path before a bulk rail blocks it (the router has no rip-up, so
/// first-routed wins).
pub fn netPriority(placement: optimizer.Placement, idx_of: *std.StringHashMapUnmanaged(usize), net: FlatNet, net_i: usize) u32 {
    const authored: u32 = if (net_i < placement.rules.net.len)
        @min(placement.rules.net[net_i].priority, max_net_priority)
    else
        0;
    var rank = netClassRank(net.name);
    if (rank == 0 and isInductorBridge(placement, idx_of, net)) rank = 1;
    return (authored << netclass_bits) | rank;
}

/// Intrinsic routing-order rank for a net from its name-based `NetClass`
/// (0 = baseline, 1 = route first). Only the switching hot loop and its input
/// rail are elevated. Those net names exist solely on a switching power module,
/// so this is a no-op on signal/array boards — which is precisely why it never
/// regresses them — while on a discrete switcher it gives the hot loop the
/// tightest copper. Clock/RF/feedback/power are deliberately *not* elevated:
/// reordering them trades total routed length board-by-board (it helps a
/// clock-sparse board and hurts a clock-dense array), a tradeoff the scalar
/// routed metric can't adjudicate, so they stay at the baseline tier. Authors
/// order those with `(net-class … (priority N))` instead.
pub fn netClassRank(name: []const u8) u32 {
    return switch (module_policy.classifyNetName(name)) {
        .switch_node, .input_rail => 1,
        else => 0,
    };
}

/// A bare hub→inductor bridge is a switch node even when its *name* reads as a
/// power rail — the RP2350's `VREG_LX` (hub pin 63 → the VREG inductor) hits
/// `classifyNetName`'s `VREG` power prefix before any switch-node stem. The
/// structural signature is unmistakable: at most a pin or two on a hub IC plus
/// the inductor, and nothing else (the post-inductor rail carries caps and many
/// pins, so it never matches). Mirrors the hub+inductor upgrade in
/// `module_policy.classifyNets`, which only rescues `.signal`/`.control` names
/// and so misses these.
fn isInductorBridge(placement: optimizer.Placement, idx_of: *std.StringHashMapUnmanaged(usize), net: FlatNet) bool {
    if (net.pins.len < 2 or net.pins.len > 3) return false;
    var hub = false;
    var ind = false;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        if (pi < placement.parts.len and placement.parts[pi].kind == .hub) hub = true;
        if (module_policy.isInductor(pin.ref_des)) ind = true;
    }
    return hub and ind;
}

pub const NetPt = pad_exit.NetPt;
pub const netPoints = pad_exit.netPoints;
/// Exact local capacitor-to-IC pad pairs from authored decoupling intent.
pub const localSupplyBonds = plane_stitch.surfaceBonds;
pub const escTerm = pad_exit.asTerm;

/// World centre of `pin` on `part`, or null if the pad isn't in the footprint.
// ── Via clearance (DRC-safe via placement) ──────────────────────────────────

/// Via copper radius (mm).
pub fn viaR(params: RouteParams) f64 {
    return params.via_dia / 2;
}

/// True if a via of the configured size centred at (x,y) on net `net` keeps the
/// copper clearance from every *foreign* pad (the via-in-pad crowding rule).
pub fn viaClearsPads(ctx: *Ctx, x: f64, y: f64, net: i32) bool {
    const need = viaR(ctx.params) + ctx.params.clearance;
    for (ctx.obs) |p| {
        if (p.net == net) continue;
        const lim = keepLimits(ctx, p.net, need);
        const distance = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, x, y, lim[1]);
        if (!keepout.approachClears(ctx.keep.zones, p.net, distance, .{ x, y }, lim)) return false;
    }
    return true;
}

pub fn viaPairCenterNeed(ctx: *const Ctx, a_dia: f64, b_dia: f64, same_net: bool) f64 {
    const rule = via_rules.CopperRule{ .via_to_via = ctx.via_to_via, .via_dia = a_dia, .ordinary = ctx.params.clearance };
    return via_rules.pairCenterNeed(rule, b_dia, if (same_net) .same_net else .all);
}

pub fn viaCopperRule(ctx: *const Ctx) via_rules.CopperRule {
    return .{ .via_to_via = ctx.via_to_via, .via_dia = ctx.params.via_dia, .ordinary = ctx.params.clearance };
}

/// True if a via at (x,y) keeps copper spacing from every already-placed via,
/// including vias on its own net.
pub fn viaClearsVias(ctx: *Ctx, placed: []const Via, x: f64, y: f64, net: i32) bool {
    if (copperIdx(ctx)) |idx| {
        for (idx.near(x, y)) |ci| {
            if (ci < ctx.copper_track_count) continue; // track box — not this probe's concern
            const vi = ci - ctx.copper_track_count;
            if (vi >= @min(ctx.copper_via_count, placed.len)) continue;
            const v = placed[vi];
            const need = viaPairCenterNeed(ctx, ctx.params.via_dia, v.dia, v.net == net);
            if (std.math.hypot(x - v.x, y - v.y) < need - clearance_eps) return false;
        }
        // The index is rebuilt at an attempt boundary. Copper appended by the
        // attempt is a soundness-critical tail, not a reason to discard the
        // otherwise-useful index.
        if (!via_rules.clears(Via, placed[@min(ctx.copper_via_count, placed.len)..], viaCopperRule(ctx), .{ x, y }, net, .all)) return false;
        return true;
    }
    return via_rules.clears(Via, placed, viaCopperRule(ctx), .{ x, y }, net, .all);
}

fn viaClearsSameNetVias(ctx: *const Ctx, placed: []const Via, x: f64, y: f64, net: i32) bool {
    if (ctx.exact) |ex| if (!via_rules.clears(Via, ex.vias, viaCopperRule(ctx), .{ x, y }, net, .same_net)) return false;
    return via_rules.clears(Via, placed, viaCopperRule(ctx), .{ x, y }, net, .same_net);
}

/// The board's fixed through-PAD drills plus the spatial index that answers
/// "which of them could a barrel at this point owe a wall to?".
///
/// Pad drills are the half of the `hole↔hole` rule the router had no probe for.
/// The copper tests cannot stand in for it: `viaClearsPads` skips the routing
/// net's OWN pads outright, so a barrel dropped beside a same-net through pad
/// passed every generator check while the DRC — which is net-blind about drills —
/// refused it. Measured on barracuda's `V_6VA`: a plane via 0.202 mm from
/// `buck_6v/U22` pad 5's 0.20 mm bore, a −0.048 mm wall against the design's
/// 0.200 mm rule, and the gate then dropped the whole net's generated copper
/// (3 islands → 16).
///
/// Built once per routing context (the pads never move mid-run) and queried
/// through the same `PadGrid` bucketing every other exact clearance probe uses,
/// because `directViaClear` alone runs its lattice hundreds of thousands of
/// times per net. `reach` is sized to the WIDEST via class on the board so the
/// index stays a superset for every net; the exact wall is still measured
/// per-candidate at the routing net's own drill.
pub const PadDrills = struct {
    holes: []const pad_exit.Hole = &.{},
    index: ?*const PadGrid = null,
    reach: f64 = 0,

    /// Index the board's pad drills for a barrel of at most `max_drill`.
    /// A null index (degenerate board / oversized cell grid) is not a failure:
    /// `clears` falls back to the full scan and returns the identical verdict.
    pub fn build(
        arena: std.mem.Allocator,
        placement: optimizer.Placement,
        grid: Grid,
        max_drill: f64,
    ) std.mem.Allocator.Error!PadDrills {
        const holes = try pad_exit.padHoles(arena, placement);
        if (holes.len == 0) return .{};
        const reach = max_drill / 2 + placement.rules.design.hole_to_hole;
        const boxes = try arena.alloc(PadObs, holes.len);
        for (holes, boxes) |h, *b| b.* = .{
            .x0 = h.x - @abs(h.shx) - h.r,
            .y0 = h.y - @abs(h.shy) - h.r,
            .x1 = h.x + @abs(h.shx) + h.r,
            .y1 = h.y + @abs(h.shy) + h.r,
            .net = -1,
        };
        return .{ .holes = holes, .index = PadGrid.build(arena, boxes, gridBounds(grid), reach), .reach = reach };
    }

    /// True when a barrel of diameter `drill` at `(x, y)` keeps `wall` from
    /// every pad bore. Net-blind, exactly as `drc.holePairViolation` is.
    ///
    /// A probe reaching FURTHER than the index was built for takes the full scan
    /// — an authored `(guides … )` via drill is set straight onto `ctx.params`
    /// and can exceed the widest net class, and an index queried past its reach
    /// is no longer a superset. Same verdict either way; only the cull is lost.
    fn clears(self: PadDrills, x: f64, y: f64, drill: f64, wall: f64) bool {
        if (self.index) |idx| {
            if (drill / 2 + wall <= self.reach + clearance_eps) {
                for (idx.near(x, y)) |hi| {
                    if (hi >= self.holes.len) continue; // defence in depth: a valid index only ever undershoots
                    const gap = pad_exit.wallGap(self.holes[hi], x, y, drill) orelse continue;
                    if (gap < wall - clearance_eps) return false;
                }
                return true;
            }
        }
        for (self.holes) |h| {
            const gap = pad_exit.wallGap(h, x, y, drill) orelse continue;
            if (gap < wall - clearance_eps) return false;
        }
        return true;
    }
};

/// True if a via drilled at (x,y) keeps the hole-to-hole WALL from every through
/// PAD drill on the board (`PadDrills`, which is where the measurement and the
/// reason for it live).
pub fn viaClearsPadDrills(ctx: *const Ctx, x: f64, y: f64) bool {
    const drill = ctx.params.via_drill;
    if (drill <= 0) return true;
    return ctx.pad_drills.clears(x, y, drill, ctx.hole_to_hole);
}

/// True if a via drilled at (x,y) keeps the hole-to-hole WALL from every drilled
/// hole — every placed via's drill AND every through PAD's bore — so the web is
/// manufacturable. Ignores net: two same-net GND vias still need a wall between
/// their drills (the `hole↔hole` DRC rule, which same-net copper clearance
/// doesn't enforce, and which is equally blind to whose pad a bore belongs to).
/// Centre distance ≥ the two drill radii + the rule (matching
/// `drc.checkDrillRules`); a coincident duplicate is skipped.
pub fn viaClearsHoles(ctx: *Ctx, placed: []const Via, x: f64, y: f64) bool {
    const vr = ctx.params.via_drill / 2;
    if (vr <= 0) return true;
    if (!viaClearsPadDrills(ctx, x, y)) return false;
    if (copperIdx(ctx)) |idx| {
        for (idx.near(x, y)) |ci| {
            if (ci < ctx.copper_track_count) continue; // track box — not this probe's concern
            const vi = ci - ctx.copper_track_count;
            if (vi >= placed.len) continue; // defence in depth: a valid index only ever undershoots
            const v = placed[vi];
            if (v.drill <= 0) continue;
            const d = std.math.hypot(x - v.x, y - v.y);
            if (d < 1e-6) continue; // coincident duplicate — no wall to lose
            if (d < vr + v.drill / 2 + ctx.hole_to_hole - clearance_eps) return false;
        }
        for (placed[@min(ctx.copper_via_count, placed.len)..]) |v| {
            if (v.drill <= 0) continue;
            const d = std.math.hypot(x - v.x, y - v.y);
            if (d < 1e-6) continue;
            if (d < vr + v.drill / 2 + ctx.hole_to_hole - clearance_eps) return false;
        }
        return true;
    }
    for (placed) |v| {
        if (v.drill <= 0) continue;
        const d = std.math.hypot(x - v.x, y - v.y);
        if (d < 1e-6) continue; // coincident duplicate — no wall to lose
        if (d < vr + v.drill / 2 + ctx.hole_to_hole - clearance_eps) return false;
    }
    return true;
}

/// True if a via of the configured size at (x,y) on net `net` keeps copper
/// clearance from every routed track on a *different* net — the via↔track rule
/// the DRC then re-checks (so an escape via can't be dropped on foreign copper).
pub fn viaClearsTracks(ctx: *Ctx, tracks: []const Track, x: f64, y: f64, net: i32) bool {
    const rr = viaR(ctx.params);
    if (copperIdx(ctx)) |idx| {
        for (idx.near(x, y)) |ci| {
            if (ci >= ctx.copper_track_count) continue; // via box — not this probe's concern
            if (ci >= tracks.len) continue; // defence in depth: a valid index only ever undershoots
            const t = tracks[ci];
            if (t.net == net) continue;
            const need = rr + t.width / 2 + ctx.params.clearance;
            if (segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) < need - clearance_eps) return false;
        }
        for (tracks[@min(ctx.copper_track_count, tracks.len)..]) |t| {
            if (t.net == net) continue;
            const need = rr + t.width / 2 + ctx.params.clearance;
            if (segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) < need - clearance_eps) return false;
        }
        return true;
    }
    for (tracks) |t| {
        if (t.net == net) continue;
        const need = rr + t.width / 2 + ctx.params.clearance;
        if (segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) < need - clearance_eps) return false;
    }
    return true;
}

/// True if the `track_width` stub a→b on net `net` keeps clearance from every
/// already-placed via on a *different* net (the via↔track rule, from the trace's
/// side). An escape stub is drawn after some vias are already down, and a via
/// fixed earlier won't re-check this later trace — so the trace must clear the
/// vias itself or the pair would fail DRC.
pub fn segClearsVias(ctx: *Ctx, placed: []const Via, a: [2]f64, b: [2]f64, net: i32) bool {
    if (copperIdx(ctx)) |idx| {
        var scratch: [near_scratch_len]u32 = undefined;
        if (nearSegment(idx, a, b, ctx.copper_reach, &scratch)) |cand| {
            for (cand) |ci| {
                if (ci < ctx.copper_track_count) continue; // track box — not this probe's concern
                const vi = ci - ctx.copper_track_count;
                if (vi >= placed.len) continue; // defence in depth: a valid index only ever undershoots
                const v = placed[vi];
                if (v.net == net) continue;
                if (!segClearsVia(ctx, v, a, b)) return false;
            }
            for (placed[@min(ctx.copper_via_count, placed.len)..]) |v| {
                if (v.net != net and !segClearsVia(ctx, v, a, b)) return false;
            }
            return true;
        }
    }
    for (placed) |v| if (v.net != net and !segClearsVia(ctx, v, a, b)) return false;
    return true;
}

/// One foreign via barrel's share of `segClearsVias`, so the index probe and the
/// fallback loop judge a band the same way: ordinary clearance always, plus the
/// via's declared keepout halo unless an escape zone waives that surplus
/// (`keepout.approachClears`).
fn segClearsVia(ctx: *const Ctx, v: Via, a: [2]f64, b: [2]f64) bool {
    const lim = keepLimits(ctx, v.net, v.dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance);
    if (segmentMissesBox(a, b, .{ v.x, v.y, v.x, v.y }, lim[1])) return true;
    const gap = segPointDist(a[0], a[1], b[0], b[1], v.x, v.y);
    if (gap >= lim[1]) return true; // clears the halo outright — no approach point needed
    return keepout.approachClears(ctx.keep.zones, v.net, gap, closestOnLine(a, b, v.x, v.y), lim);
}

/// Cheap conservative rejection before an exact segment/shape distance test.
/// `reach` expands the object's bounds by the required copper clearance.
fn segmentMissesBox(
    a: [2]f64,
    b: [2]f64,
    bounds: [4]f64,
    reach: f64,
) bool {
    return @max(a[0], b[0]) < @min(bounds[0], bounds[2]) - reach or
        @min(a[0], b[0]) > @max(bounds[0], bounds[2]) + reach or
        @max(a[1], b[1]) < @min(bounds[1], bounds[3]) - reach or
        @min(a[1], b[1]) > @max(bounds[1], bounds[3]) + reach;
}

pub fn pointMissesBox(point: [2]f64, x0: f64, y0: f64, x1: f64, y1: f64, reach: f64) bool {
    return point[0] < @min(x0, x1) - reach or point[0] > @max(x0, x1) + reach or
        point[1] < @min(y0, y1) - reach or point[1] > @max(y0, y1) + reach;
}

/// True if the `track_width` stub a→b on net `net` (drawn on signal layer
/// `layer`) keeps the copper clearance from every routed track of a *different*
/// net on that layer. The escape pass runs after the maze, and maze copper is
/// grid-guaranteed only against other maze copper — a stub drawn at an
/// arbitrary point must check the tracks itself or it can cross them outright
/// (the classic breakout-stub-through-a-rail short).
pub fn segClearsTracks(ctx: *Ctx, tracks: []const Track, a: [2]f64, b: [2]f64, net: i32, layer: u8) bool {
    // The RF crossing shadow rides here too. The direct / dogleg / octilinear
    // synthesis emits a segment whole or not at all and never sees the maze cost
    // model, so the only way to price a shortcut that RUNS ALONG a protected
    // corridor is to refuse it — the net then falls through to the maze, which
    // does read the cost and buys the short (≈perpendicular) crossing instead.
    if (!ctx.keep.exempt and ctx.shadow.runsAlong(tracks, .{ a, b }, ctx.params.track_width / 2, net)) return false;
    if (copperIdx(ctx)) |idx| {
        var scratch: [near_scratch_len]u32 = undefined;
        if (nearSegment(idx, a, b, ctx.copper_reach, &scratch)) |cand| {
            for (cand) |ci| {
                if (ci >= ctx.copper_track_count) continue; // via box — not this probe's concern
                if (ci >= tracks.len) continue; // defence in depth: a valid index only ever undershoots
                const t = tracks[ci];
                if (t.net == net or t.layer != layer) continue;
                if (!segClearsTrack(ctx, t, a, b)) return false;
            }
            for (tracks[@min(ctx.copper_track_count, tracks.len)..]) |t| {
                if (t.net == net or t.layer != layer) continue;
                if (!segClearsTrack(ctx, t, a, b)) return false;
            }
            return true;
        }
    }
    for (tracks) |t| if (t.net != net and t.layer == layer and !segClearsTrack(ctx, t, a, b)) return false;
    return true;
}

/// One foreign track's share of `segClearsTracks`, so the index probe and the
/// fallback loop judge a shortcut the same way: ordinary clearance always, plus
/// the track's declared keepout halo unless an escape zone waives that surplus
/// (`keepout.approachClears`).
fn segClearsTrack(ctx: *const Ctx, t: Track, a: [2]f64, b: [2]f64) bool {
    const lim = keepLimits(ctx, t.net, t.width / 2 + ctx.params.track_width / 2 + ctx.params.clearance);
    if (segmentMissesBox(a, b, .{ t.x1, t.y1, t.x2, t.y2 }, lim[1])) return true;
    const e = [2][2]f64{ .{ t.x1, t.y1 }, .{ t.x2, t.y2 } };
    const gap = segSegDist(a, b, e[0], e[1]);
    // Only the escape gate reads the approach POINT, and only for a gap inside the halo — computing the midpoint up front doubled the geometry `moveClearsCopper` pays per candidate per maze move.
    if (gap >= lim[1]) return true;
    return keepout.approachClears(ctx.keep.zones, t.net, gap, pad_shape.segSegMid(a, b, e[0], e[1]), lim);
}

/// True if the same-net stub segment a→b (a real `track_width` trace) keeps
/// clearance from every foreign pad along its length. Sampled at a tenth of
/// the grid pitch with the requirement inflated by half a sample step (the
/// Lipschitz bound: any point sits within step/2 of a sample), so a
/// between-sample dip can't slip a sub-clearance approach past the sampling —
/// the stub provably meets the DRC rule at a ~13 um routability cost.
/// An SMD pad only obstructs copper on its own signal layer; a through-hole pad
/// obstructs every layer. A null `layer` is the conservative form used where the
/// copper's layer is not yet fixed: every pad obstructs, whichever side it is on.
pub fn segClearsPadsOnLayer(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: ?u8) bool {
    const need = ctx.params.track_width / 2 + ctx.params.clearance;
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, gridBounds(ctx.grid), padIndexReach(ctx));
    if (ctx.pad_index) |idx| {
        var scratch: [near_scratch_len]u32 = undefined;
        if (nearSegment(idx, a, b, padIndexReach(ctx), &scratch)) |cand| {
            for (cand) |pi| {
                const o = ctx.obs[pi];
                if (o.net == net) continue;
                if (layer) |on| if (!o.thru and o.layer != on) continue;
                // `padSegmentClears` adds a keepout net's declared halo over the
                // ordinary clearance — exactly like the fallback loop, so the
                // index probe cannot let a direct shortcut slip past an RF pad.
                if (!padSegmentClears(ctx, o, a, b, need)) return false;
            }
            return true;
        }
    }
    for (ctx.obs) |o| {
        if (o.net == net) continue;
        if (layer) |on| if (!o.thru and o.layer != on) continue;
        if (!padSegmentClears(ctx, o, a, b, need)) return false;
    }
    return true;
}

/// Longest clear prefix of escape stub a→b on net `net`: the farthest point
/// from the pad `a` such that the whole sub-segment keeps clearance from every
/// foreign pad, via, and routed track on `layer`. Returns `a` itself when even
/// the first step isn't clear (the caller then drops the stub) — a single-pin
/// breakout has nothing to connect to, so trimming it never breaks a real
/// connection.
pub fn trimStub(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, b: [2]f64, net: i32, layer: u8) [2]f64 {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    if (len < 1e-9) return a;
    const step = ctx.grid.g * 0.2;
    const n: usize = @max(1, numeric.toCount(@ceil(len / step)));
    // Inflate the clearance by one sample step so a between-sample dip can't slip
    // a sub-clearance crossing past the sampling.
    const need = ctx.params.track_width / 2 + ctx.params.clearance + step;
    var last = a;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const p = [2]f64{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
        var ok = true;
        for (ctx.obs) |o| {
            if (o.net == net) continue;
            const lim = keepLimits(ctx, o.net, need);
            const distance = pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, p[0], p[1], lim[1]);
            if (!keepout.approachClears(ctx.keep.zones, o.net, distance, p, lim)) {
                ok = false;
                break;
            }
        }
        if (ok) for (placed) |v| {
            if (v.net == net) continue;
            if (std.math.hypot(p[0] - v.x, p[1] - v.y) - v.dia / 2 < need) {
                ok = false;
                break;
            }
        };
        if (ok) for (tracks) |tr| {
            if (tr.net == net or tr.layer != layer) continue;
            if (segPointDist(tr.x1, tr.y1, tr.x2, tr.y2, p[0], p[1]) - tr.width / 2 < need) {
                ok = false;
                break;
            }
        };
        if (!ok) break;
        last = p;
    }
    return last;
}

/// Rings (grid steps) the escape-via fan searches outward before giving up —
/// ~3 mm at the default pitch, enough to clear a dense module's pad field.
const escape_via_rings: usize = 12;

/// Find the *nearest* DRC-safe spot for a single-pin breakout's escape via — the
/// in-tool version of hand-routing a pin that has nothing to land on: drop a via
/// next to the pad and let the signal leave on an inner layer, with a short trace
/// from the pad to the via. Both the via AND the straight pad→via stub must be
/// fully DRC-safe: clear of foreign pads, placed vias, and routed tracks on the
/// stub's layer. There is deliberately NO relaxed tier that lets the stub cross
/// foreign copper — that used to draw breakout stubs straight across the
/// neighbouring pad of a fine-pitch QFN. A breakout carries no connection, so
/// when the pad is hemmed in the caller's trimmed surface stub (which stops at
/// clearance) is strictly better than pad-crossing copper. Null when no clean
/// spot exists in the search window.
pub fn findEscapeVia(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, dir: [2]f64, net: i32, layer: u8) ?[2]f64 {
    return escapeFan(ctx, placed, tracks, a, dir, net, layer);
}

/// One fan of the escape-via search (see `findEscapeVia`). Fans outward from the
/// pad `a` in growing rings along the eight 45° compass headings — nearest the
/// reserved corridor heading `dir` first, then swivelling to either side — and
/// returns the first spot where a via of the configured size clears every
/// foreign pad, via and routed track, and the straight pad→via stub clears
/// every foreign pad, via, and routed track on `layer`. Candidates sit exactly
/// on the 45° ray from the pad centre (NOT grid-snapped: the escape pass runs
/// after the maze, so nothing consults the occupancy grid afterwards, and the
/// unsnapped spot is what keeps the stub octilinear).
fn escapeFan(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, dir: [2]f64, net: i32, layer: u8) ?[2]f64 {
    const grid = ctx.grid;
    const ang0 = std.math.atan2(dir[1], dir[0]);
    var ring: usize = 1;
    while (ring <= escape_via_rings) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const ang = octilinear.compass45(ang0, k);
            const s = [2]f64{ a[0] + rad * @cos(ang), a[1] + rad * @sin(ang) };
            if (!viaClearsOutline(ctx, s[0], s[1], net)) continue;
            if (!viaClearsPads(ctx, s[0], s[1], net)) continue;
            if (!viaClearsVias(ctx, placed, s[0], s[1], net)) continue;
            if (!viaClearsHoles(ctx, placed, s[0], s[1])) continue;
            if (!viaClearsTracks(ctx, tracks, s[0], s[1], net)) continue;
            // The stub itself must clear every foreign pad, placed via, and
            // routed track — all are fixed and won't re-check this later
            // trace, so the pair would fail DRC (or short outright).
            if (!segClearsVias(ctx, placed, a, s, net)) continue;
            if (!segClearsTracks(ctx, tracks, a, s, net, layer)) continue;
            if (!segClearsPadsOnLayer(ctx, a, s, net, null)) continue;
            return s;
        }
    }
    return null;
}

/// The net's own pad copper under `c` on `layer` — the first same-net pad (in
/// obstacle-build order, so the answer is deterministic) whose shape contains
/// the point. Null when the anchor sits on no pad of its own net, which is when
/// there is no pad copper for a via to hide inside.
pub fn padCopperAt(ctx: *const Ctx, c: [2]f64, net: i32, layer: u8) ?pad_shape.Shape {
    return plane_via.landAt(ctx.obs, c, net, layer);
}

/// Find a DRC-safe spot for a ground via serving pad centre `c` on net `net`.
/// Prefers the pad centre (true via-in-pad — fine when the land can hold the
/// barrel and still clear its neighbours); if that crowds a foreign pad, via, or
/// retained track, or would leave the annular ring hanging off the land, searches
/// the rest of the pad's OWN copper (`plane_via.InPad`) before fanning outward
/// into open copper, returning that point (the caller joins it with a same-net
/// stub). Null when no clear spot is found in the search window — the pad is then
/// left without a via rather than emitting a guaranteed clearance violation.
pub fn findGroundVia(
    ctx: *Ctx,
    placed: []const Via,
    tracks: []const Track,
    c: [2]f64,
    net: i32,
    layer: u8,
) ?[2]f64 {
    const grid = ctx.grid;
    // Candidate 0: the pad centre, snapped to the grid (true via-in-pad when the
    // pad is large enough to clear its neighbours AND to hold the barrel).
    //
    // The snap is what makes containment a separate question from clearance
    // here: it moves the site up to half a grid pitch off the anchor, so a site
    // that sits ON the land can still hang its annular ring over the land's edge
    // — and no clearance probe can see that, because `viaClearsPads` skips the
    // routing net's own pads. Measured on `bcuda-lt3045-ldo`: U1's GND_1 land is
    // 0.80 x 0.30 mm, the snap put a 0.4 mm barrel at (1.578, 0.016) against a
    // land centred (1.500, 0.000), and the ring overhung the 0.30 mm dimension by
    // 0.034/0.066 mm. Refusing it costs one stub and buys a landed annulus.
    {
        const s = grid.snap(c[0], c[1]);
        if (plane_via.inLandBarrelFits(padCopperAt(ctx, s, net, layer), s, ctx.params.via_dia) and
            groundViaPointClear(ctx, placed, tracks, s, net) and segClearsPadsOnLayer(ctx, c, s, net, null))
            return s;
    }
    // A big pad (a thermal land) usually still has room a couple of tenths off
    // its anchor — a site the grid-stepped fan below strides straight over. This
    // is also where a snap refused for containment lands: the walk is centre-out
    // from the UNSNAPPED anchor and every site it yields contains the barrel, so
    // a land that can hold the via at all gets it at (or nearest to) its own
    // centre — strictly closer than the snap was, and with no stub at all.
    if (padCopperAt(ctx, c, net, layer)) |pad| {
        var scan = plane_via.InPad.init(pad, c, ctx.params.via_dia);
        while (scan.next()) |s| {
            if (groundViaPointClear(ctx, placed, tracks, s, net) and segClearsPadsOnLayer(ctx, c, s, net, null))
                return s;
        }
    }
    // Otherwise fan outward (away from foreign pads) in growing rings, snapping
    // each candidate to the grid, until one clears every foreign pad and via.
    // The containment gate rides along: ring 1 is only one grid pitch out, so a
    // snapped fan site routinely lands ON the anchor land's edge (or on a
    // neighbouring same-net land), and a barrel straddling an edge is the same
    // unlanded ring the pad-centre gate refuses. Ungated it would simply move
    // the defect one ring out.
    const dir = plane_via.fanDir(ctx.obs, c, net);
    const ang0 = std.math.atan2(dir[1], dir[0]);
    var ring: usize = 1;
    while (ring <= 16) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 12) : (k += 1) {
            const a = ang0 + plane_via.swivel(k);
            const s = grid.snap(c[0] + rad * @cos(a), c[1] + rad * @sin(a));
            if (!groundViaPointClear(ctx, placed, tracks, s, net)) continue;
            if (!plane_via.inLandBarrelFits(padCopperAt(ctx, s, net, layer), s, ctx.params.via_dia)) continue;
            if (!segClearsPadsOnLayer(ctx, c, s, net, null)) continue;
            if (!segClearsTracks(ctx, tracks, c, s, net, layer)) continue;
            return s;
        }
    }
    return null;
}

pub fn groundViaPointClear(
    ctx: *Ctx,
    placed: []const Via,
    tracks: []const Track,
    point: [2]f64,
    net: i32,
) bool {
    if (!viaClearsOutline(ctx, point[0], point[1], net)) return false;
    if (!viaClearsPads(ctx, point[0], point[1], net)) return false;
    if (!viaClearsVias(ctx, placed, point[0], point[1], net)) return false;
    if (!viaClearsHoles(ctx, placed, point[0], point[1])) return false;
    return viaClearsTracks(ctx, tracks, point[0], point[1], net);
}

/// The nearest DRC-safe spot for a standalone GND plane stitch via near `c` (a
/// signal via we're stitching the return path of): fan outward in growing rings
/// to the first grid point within `max_r` mm that clears every foreign pad, every
/// placed via, and every routed track (the stitch pass runs last, so all copper
/// is down). Null when nothing fits — the via stays unstitched rather than forcing
/// a DRC violation. Unlike `findGroundVia` there's no stub back to a pad (a plane
/// via needs none), so no segment-clearance constraint applies.
pub fn findStitchVia(ctx: *Ctx, placed: []const Via, tracks: []const Track, c: [2]f64, net: i32, max_r: f64) ?[2]f64 {
    const grid = ctx.grid;
    const max_ring: usize = @max(1, numeric.toCount(@floor(max_r / grid.g)));
    var ring: usize = 1;
    while (ring <= max_ring) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const a = (@as(f64, @floatFromInt(k)) / 16.0) * std.math.tau;
            const s = grid.snap(c[0] + rad * @cos(a), c[1] + rad * @sin(a));
            if (std.math.hypot(s[0] - c[0], s[1] - c[1]) > max_r) continue;
            if (!groundViaPointClear(ctx, placed, tracks, s, net)) continue;
            return s;
        }
    }
    return null;
}

/// Does `name` have a dedicated copper plane (see `plane_stitch.netHasPlane`)?
pub const netHasPlane = plane_stitch.netHasPlane;
/// Which outer signal layers pour `name` (see `plane_stitch.netPourLayers`)?
pub const netPourLayers = plane_stitch.netPourLayers;
pub const padInPour = plane_stitch.padInPour;

/// Overlay `net_i`'s `(net-class …)` rule onto the base route params — the
/// per-net effective geometry every subsequent clearance/width/via read uses.
/// Nets without a rule (or with zero fields) keep the base values.
/// Overlay `net_i`'s `(net-class …)` rule onto the base geometry, setting the
/// effective track width / clearance / via size / escape reserve + `reach` used
/// by every clearance read for the net currently routing (or being probed).
pub fn setNetParams(ctx: *Ctx, placement: optimizer.Placement, net_i: usize) void {
    var p = ctx.base;
    ctx.rf.escape_mm = 0;
    ctx.rf.escape_pts = &.{}; // repopulated by setNetRoutePolicy for maze nets
    ctx.keep.halo = 0;
    ctx.manhattan = manhattan_route.stateFor(placement, net_i); // clears `active` with it
    ctx.shadow.width = rf_shadow.widthAt(ctx.shadow.nets, @intCast(net_i));
    if (net_i < placement.rules.net.len) {
        const r = placement.rules.net[net_i];
        p.pad_neck = r.pad_neck;
        p.pad_neck.width = @max(p.pad_neck.width, placement.rules.design.min_width);
        if (r.width > 0) p.track_width = r.width;
        if (r.clearance > 0) p.clearance = r.clearance;
        if (r.via_dia > 0) p.via_dia = r.via_dia;
        if (r.via_drill > 0) p.via_drill = r.via_drill;
        ctx.rf.escape_mm = r.rf.escape_mm;
        ctx.keep.halo = r.rf.keepout_mm;
    }
    if (net_i < placement.nets.len) {
        // Current capacity is an electrical target, not a routing primitive.
        // Search an ordinary fabrication-legal centreline for an unpoured
        // rail, then let the final adaptive-width pass grow it as far as exact
        // clearance permits. This keeps a wide trunk routable through QFN
        // lands and other unavoidable necks without weakening copper DRC.
        // Plane/pour fanouts retain their authored branch geometry because
        // their local-current proof is tied to the carrying sheet.
        const authored_width = p.track_width;
        if (power_route_width.adaptiveTargetWidth(ctx.zones, placement, net_i, authored_width) != null)
            p.track_width = @max(placement.rules.design.min_width, @min(authored_width, ctx.base.track_width))
        else
            p.track_width = power_route_width.exactWidth(ctx.zones, placement, net_i, authored_width);
        // Barrels keep the class/board via geometry. Fattening every via on a
        // rail to the drill ONE barrel would need for the whole rail current
        // was both wrong (the solver divides current between parallel barrels)
        // and self-defeating (the enlarged barrel often could not clear its
        // neighbours). `drc_power_via.zig` now measures each barrel's solved
        // share after routing and says where another via is needed.
    }
    // Refresh the escape gate for the net about to route: which zones admit it
    // (it owns a pad inside them) is a per-net answer the maze then reads per node.
    keepout.admitCurrent(ctx.keep.zones, ctx.keep.pads, @intCast(net_i));
    // Ground/plane copper owes no foreign keepout: a stitching via or coplanar
    // pour beside an RF trace is the wanted fence. Clearance is untouched.
    ctx.keep.exempt = ctx.keep.nets.len > 0 and keepout.exempt(placement, net_i);
    ctx.keep.class.cur = @intCast(net_i); // whose class may pass its own halos
    ctx.params = p;
    ctx.reach = p.track_width / 2 + p.clearance;
    // The copper index's QUERY reach is a function of the routing net's own
    // geometry (`copperReach` reads `params` + `keep`), so it must move with
    // them: a reach left at a previous, NARROWER net's value lets this net's
    // `nearSegment` probes miss copper that really is inside its wider
    // clearance. Costs nothing when no index has been built yet.
    if (ctx.copper_index != null) ctx.copper_reach = copperReach(ctx);
    // Everything above is an input to a cached static-obstacle verdict, so the
    // memo belongs to ONE net's turn at the grid. Invalidating it here — the
    // single choke point every net change already goes through — is what makes
    // arming it on the primary route safe (`armStaticBlock`); the bump is O(1).
    ctx.static_block.reset();
}

/// True when `layer` belongs to `mask`; an empty mask means unrestricted.
/// The convention itself lives in `board_layers.LayerSet`, so route policy,
/// the DRC and the router can never read one mask differently.
pub fn layerInMask(mask: u64, layer: u8) bool {
    return board_layers.LayerSet.fromRaw(mask).contains(board_layers.SignalIndex.of(layer));
}

/// True when net `net_i`'s policy AUTHORS its layer choices — a preferred or
/// allowed layer mask, ordered waypoints, or reference branches. Such a net's
/// layer changes are the point of the route, not an accident of the search, so
/// a cleanup pass must not "simplify" them away (`dropRedundantViaPairs`).
pub fn netLayerAuthored(ctx: *const Ctx, net_i: usize) bool {
    if (net_i >= ctx.net_policy.len) return false;
    return route_policy.authorsLayers(ctx.net_policy[net_i]);
}

/// Load the current net's route-wave policy. Terminal pad layers are unioned
/// into a hard allowed-layer mask so a policy can say "route on In2.Cu" while
/// still letting a top-side SMD pad fan out far enough to reach that layer.
pub fn setNetRoutePolicy(ctx: *Ctx, net_i: usize, pts: []const NetPt) void {
    ctx.rf.escape_pts = pts;
    const policy = if (net_i < ctx.net_policy.len) ctx.net_policy[net_i] else route_policy.NetPolicy{};
    ctx.preferred_layers = policy.preferred_layers;
    ctx.allowed_layers = policy.allowed_layers;
    ctx.waypoints = policy.waypoints;
    ctx.guide_branches = policy.branches;
    ctx.max_vias = policy.max_vias;
    if (ctx.allowed_layers == 0) return;
    for (pts) |pt| {
        if (pt.layer < 64) ctx.allowed_layers |= @as(u64, 1) << @intCast(pt.layer);
    }
}

fn markGuideCell(mask: []bool, grid: Grid, layer: usize, nodes: usize, x: f64, y: f64) void {
    const center = grid.nearest(x, y);
    var dy: i64 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            const ix = @as(i64, @intCast(center[0])) + dx;
            const iy = @as(i64, @intCast(center[1])) + dy;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const node = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            mask[layer * nodes + node] = true;
        }
    }
}

pub fn setNetReferenceGuide(ctx: *Ctx, net_i: usize) std.mem.Allocator.Error!void {
    ctx.reference_corridor = null;
    ctx.reference_via_mask = null;
    ctx.reference_guide_active = false;
    const net: i32 = @intCast(net_i);
    var have_tracks = false;
    for (ctx.guide_tracks) |track| if (track.net == net and track.layer < ctx.occ.len) {
        have_tracks = true;
        break;
    };
    var have_vias = false;
    for (ctx.guide_vias) |via| if (via.net == net) {
        have_vias = true;
        break;
    };
    if (!have_tracks and !have_vias) return;
    ctx.reference_guide_active = true;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    if (have_tracks) {
        const corridor = try ctx.arena.alloc(bool, ctx.occ.len * nodes);
        @memset(corridor, false);
        for (ctx.guide_tracks) |track| {
            if (track.net != net or track.layer >= ctx.occ.len) continue;
            const len = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
            const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
            for (0..steps + 1) |step| {
                const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
                markGuideCell(
                    corridor,
                    ctx.grid,
                    track.layer,
                    nodes,
                    track.x1 + t * (track.x2 - track.x1),
                    track.y1 + t * (track.y2 - track.y1),
                );
            }
        }
        ctx.reference_corridor = corridor;
    }
    if (have_vias) {
        const via_mask = try ctx.arena.alloc(bool, nodes);
        @memset(via_mask, false);
        for (ctx.guide_vias) |via| {
            if (via.net != net) continue;
            markGuideCell(via_mask, ctx.grid, 0, nodes, via.x, via.y);
        }
        ctx.reference_via_mask = via_mask;
    }
}

/// Empty selection means the legacy full-board route; otherwise only true
/// net-index entries participate in plane, maze, and breakout passes.
pub fn netEnabled(ctx: *const Ctx, net_i: usize) bool {
    return ctx.selected_nets.len == 0 or
        (net_i < ctx.selected_nets.len and ctx.selected_nets[net_i]);
}

/// Stamp retained copper before routing a selected subset, and carry it into
/// the result unchanged. Sampling at half-grid pitch makes an arbitrary-angle
/// source segment a continuous obstacle on the maze raster.
pub fn stampExistingCopper(
    ctx: *Ctx,
    options: route_policy.Options,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!void {
    for (options.existing_tracks) |item| {
        // A track on a layer the maze does not model still ECHOES into the
        // result (the caller's copper is returned whole); only the obstacle
        // stamp is skipped, since there is no grid to stamp it on.
        if (item.layer < ctx.occ.len) {
            const net = if (item.net == empty_cell) -2 else item.net;
            const len = std.math.hypot(item.x2 - item.x1, item.y2 - item.y1);
            const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
            const halo = item.width / 2 + ctx.index_reach;
            for (0..steps + 1) |s| {
                const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
                const x = item.x1 + t * (item.x2 - item.x1);
                const y = item.y1 + t * (item.y2 - item.y1);
                stampDisc(ctx, x, y, net, halo, item.layer, false);
            }
        }
        try tracks.append(ctx.arena, .{
            .x1 = item.x1,
            .y1 = item.y1,
            .x2 = item.x2,
            .y2 = item.y2,
            .layer = item.layer,
            .width = item.width,
            .net = item.net,
        });
    }
    for (options.existing_vias) |item| {
        const net = if (item.net == empty_cell) -2 else item.net;
        const halo = item.dia / 2 + ctx.index_reach;
        stampDisc(ctx, item.x, item.y, net, halo, 0, true);
        try vias.append(ctx.arena, .{
            .x = item.x,
            .y = item.y,
            .dia = item.dia,
            .drill = item.drill,
            .net = item.net,
        });
    }
}

/// Stamp every routed `tracks`/`vias` of a net OTHER than `skip_net` into
/// `ctx`'s occupancy grids as a foreign obstacle `blocked` refuses. Seeds a
/// fresh windowed context (see `windowCtx`) with the current board so a local
/// retry keeps full DRC clearance from everything already placed; the routing
/// net itself is skipped so its own accumulating copper never blocks a later leg
/// (that copper is already threaded into the passed track/via lists, where the
/// direct-synthesis clearance checks — which skip same-net — see it).
///
/// The halo is the routing net's EXACT clearance (`ctx.reach`, set per-net
/// before the call) plus a half-diagonal grid step, not the board-wide
/// `index_reach`: a thin net threading a tight gap must not be walled out by the
/// widest class's margin, yet the diagonal-step term keeps a 45° maze segment
/// clear (its midpoint sits `g/√2` inside the node distances). Copper centred
/// outside the window still stamps its in-window halo (`stampDisc` clips to the
/// grid), so a foreign track skimming the window edge blocks correctly.
pub fn stampBoardCopper(ctx: *Ctx, tracks: []const Track, vias: []const Via, skip_net: i32) void {
    const slack = ctx.grid.g * (sqrt2 / 2);
    // The diagonal-step margin belongs to the RASTER, not to the physics. In
    // exact mode `moveClearsCopper` re-measures every move against the copper
    // itself, so the stamp drops the margin and blocks only what a track centre
    // may genuinely not occupy; the margin then survives as the `near` band that
    // decides which moves pay for that re-measurement.
    const margin = if (ctx.exact != null) 0 else slack;
    if (ctx.exact) |*ex| {
        @memset(ex.near, false);
        ex.tracks = tracks;
        ex.vias = vias;
    }
    for (tracks) |t| {
        if (t.layer >= ctx.occ.len or t.net == skip_net) continue;
        const net = if (t.net == empty_cell) -2 else t.net;
        const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
        // A track whose net declared a keepout is held off by the WIDER of its
        // clearance and its halo — how a windowed retry / gap hop respects an RF
        // keepout with no node mask of its own. Zero for an exempt routing net; BANDED, not flat (`KeepState.band`).
        const halo = t.width / 2 + ctx.reach + keepoutExtra(ctx, t.net);
        ctx.keep.band = .{ .net = t.net, .plain = t.width / 2 + ctx.reach + margin };
        for (0..steps + 1) |s| {
            const f = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
            const x = t.x1 + f * (t.x2 - t.x1);
            const y = t.y1 + f * (t.y2 - t.y1);
            stampDisc(ctx, x, y, net, halo + margin, t.layer, false);
            markNearCopper(ctx, x, y, halo + slack, t.layer, false);
        }
    }
    for (vias) |v| {
        if (v.net == skip_net) continue;
        const net = if (v.net == empty_cell) -2 else v.net;
        const halo = v.dia / 2 + ctx.reach + keepoutExtra(ctx, v.net);
        ctx.keep.band = .{ .net = v.net, .plain = v.dia / 2 + ctx.reach + margin };
        stampDisc(ctx, v.x, v.y, net, halo + margin, 0, true);
        markNearCopper(ctx, v.x, v.y, halo + slack, 0, true);
    }
    ctx.keep.band = .{}; // every OTHER stamper claims its whole disc outright
    if (ctx.exact != null) buildExactIndex(ctx, tracks, vias);
}

/// Flag every node within `dist` of `(x, y)` as sitting in some foreign
/// obstacle's re-measurement band (see `ExactClearance.near`). Mirrors
/// `stampDisc`'s raster exactly, so the band is the disc the raster-only model
/// would have blocked outright. No-op when exact mode is off.
fn markNearCopper(ctx: *Ctx, x: f64, y: f64, dist: f64, layer: u8, both: bool) void {
    const ex = ctx.exact orelse return;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const r_nodes: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse 0;
    const c = grid.nearest(x, y);
    const lo: usize = if (both) 0 else @min(@as(usize, layer), ctx.occ.len);
    const hi: usize = if (both) ctx.occ.len else @min(@as(usize, layer) + 1, ctx.occ.len);
    if (lo >= hi) return;
    var dj: i64 = -r_nodes;
    while (dj <= r_nodes) : (dj += 1) {
        var di: i64 = -r_nodes;
        while (di <= r_nodes) : (di += 1) {
            const ix = @as(i64, @intCast(c[0])) + di;
            const iy = @as(i64, @intCast(c[1])) + dj;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const ddx = grid.worldX(@intCast(ix)) - x;
            const ddy = grid.worldY(@intCast(iy)) - y;
            if (ddx * ddx + ddy * ddy > dist * dist) continue;
            const n = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            for (lo..hi) |l| ex.near[l * nodes + n] = true;
        }
    }
}

/// The spatial index itself, its obstacle box, and its point/segment queries
/// live in `pad_grid.zig` — the candidate-superset filter every exact clearance
/// probe here funnels through. Aliased so the probe sites read unchanged.
pub const PadGrid = pad_grid.PadGrid;
const nearSegment = pad_grid.nearSegment;
const near_scratch_len = pad_grid.near_scratch_len;

/// The world rectangle an index built for this route must cover: the routing
/// grid's own extent, so every on-board query lands in a real cell.
pub fn gridBounds(g: Grid) pad_grid.Bounds {
    return .{
        .minx = g.ox,
        .miny = g.oy,
        .maxx = g.ox + @as(f64, @floatFromInt(g.nx -| 1)) * g.g,
        .maxy = g.oy + @as(f64, @floatFromInt(g.ny -| 1)) * g.g,
    };
}

/// Build the copper spatial index over `tracks` + `vias` (box order: tracks
/// then vias). Insertion reach covers the largest clearance any direct probe
/// applies — a via-via pair is `via_dia/2 + via_dia/2`, a track is its own
/// half-width plus the routing net's half-width, holes add the drill wall —
/// so `near()` / `nearSegment()` are supersets for every probe. Null on a
/// degenerate board / oversized grid / alloc failure; callers fall back to
/// the full scan with identical verdicts.
fn buildCopperIndex(ctx: *Ctx, tracks: []const Track, vias: []const Via) ?*const PadGrid {
    if (tracks.len == 0 and vias.len == 0) return null;
    var widest: f64 = 0;
    for (tracks) |t| widest = @max(widest, t.width / 2);
    for (vias) |v| widest = @max(widest, v.dia / 2);
    const reach = widest + ctx.params.via_dia + ctx.params.track_width / 2 +
        ctx.params.clearance + ctx.hole_to_hole + keepMaxExtra(ctx);
    const boxes = ctx.arena.alloc(PadObs, tracks.len + vias.len) catch return null;
    for (tracks, 0..) |t, i| boxes[i] = .{
        .x0 = @min(t.x1, t.x2),
        .y0 = @min(t.y1, t.y2),
        .x1 = @max(t.x1, t.x2),
        .y1 = @max(t.y1, t.y2),
        .net = t.net,
    };
    for (vias, 0..) |v, i| boxes[tracks.len + i] = .{
        .x0 = v.x,
        .y0 = v.y,
        .x1 = v.x,
        .y1 = v.y,
        .net = v.net,
    };
    return PadGrid.build(ctx.arena, boxes, gridBounds(ctx.grid), reach);
}

/// The reach a copper-index query must expand by so its candidate set is a
/// superset of everything that could touch the probe: the widest copper in the
/// index plus the largest clearance the CURRENT net's geometry can demand.
/// Reads `ctx.params` + `ctx.keep`, so it is restated whenever those change.
pub fn copperReach(ctx: *const Ctx) f64 {
    return ctx.copper_widest + ctx.params.via_dia + ctx.params.track_width / 2 +
        ctx.params.clearance + ctx.hole_to_hole + keepMaxExtra(ctx);
}

/// Refresh `ctx.copper_index` from the current copper. O(tracks + vias) per
/// call — negligible against the millions of probes it accelerates. Restamps
/// the index with the current `copper_gen`, which is what makes it usable
/// again after a compaction (see `copperCompacted`).
pub inline fn rebuildCopperIndex(ctx: *Ctx, tracks: []const Track, vias: []const Via) void {
    ctx.copper_track_count = tracks.len;
    ctx.copper_via_count = vias.len;
    const built = buildCopperIndex(ctx, tracks, vias);
    ctx.copper_index = built;
    ctx.copper_index_gen = ctx.copper_gen;
    if (built == null) {
        ctx.copper_widest = 0;
        ctx.copper_reach = 0;
        return;
    }
    var widest: f64 = 0;
    for (tracks) |t| widest = @max(widest, t.width / 2);
    for (vias) |v| widest = @max(widest, v.dia / 2);
    ctx.copper_widest = widest;
    ctx.copper_reach = copperReach(ctx);
}

/// Announce that the copper lists were REORDERED or SHRUNK, so every index the
/// copper index holds now names different copper than it was built for.
///
/// `route_cleanup.removeNetTracks` / `removeNetVias` pack survivors down in
/// place, so a surviving track slides into a removed one's slot: the index's
/// candidate `ci` is still in range and points at the WRONG track — a bounds
/// guard cannot catch it, and the probe can return a false "clear" against
/// copper that is really in the way. Bumping the generation makes `copperIdx`
/// refuse the index (linear fallback, identical verdicts) until the next
/// `rebuildCopperIndex` restamps it, so a forgotten rebuild costs time and
/// never soundness.
pub inline fn copperCompacted(ctx: *Ctx) void {
    ctx.copper_gen +%= 1;
}

/// The copper index, or null when a compaction has invalidated it. Every probe
/// reads the index through here rather than touching `ctx.copper_index`.
pub inline fn copperIdx(ctx: *const Ctx) ?*const PadGrid {
    if (ctx.copper_gen != ctx.copper_index_gen) return null;
    return ctx.copper_index;
}

/// Account one exact-clearance probe against the per-net direct budget, if
/// armed. Returns true when the budget is exhausted — the caller must report
/// the probed item as BLOCKED so the direct attempt fails fast and the net
/// falls to the maze (bailing on "clear" would let unvalidated copper
/// through).
pub inline fn probeBudgetExhausted(ctx: *Ctx) bool {
    // Direct synthesis can spend millions of exact-clearance probes inside one
    // net, so net-boundary cancellation alone cannot enforce a board deadline.
    // One clock read per 1024 probes is negligible beside the geometry work and
    // bounds the overshoot without putting a syscall on every hot-path probe.
    if (ctx.deadline_expired) return true;
    if (ctx.deadline_ns != 0) {
        ctx.deadline_probe_count +%= 1;
        if ((ctx.deadline_probe_count & 1023) == 0 and clock.nanoTimestamp() >= ctx.deadline_ns) {
            ctx.deadline_expired = true;
            return true;
        }
    }
    if (ctx.direct_budget) |*b| {
        if (b.* == 0) return true;
        b.* -= 1;
    }
    return false;
}

/// Rebuild the spatial index `moveClearsCopper` prefilters through: one
/// bounding box per foreign track (first) then per foreign via, bucketed so the
/// bin holding a move's ORIGIN contains every obstacle that move could violate.
/// The registration reach is the widest obstacle's clearance plus one diagonal
/// step, which is the furthest a move's far end can reach past its origin.
fn buildExactIndex(ctx: *Ctx, tracks: []const Track, vias: []const Via) void {
    if (ctx.exact == null) return;
    ctx.exact.?.index = null;
    var widest: f64 = 0;
    for (tracks) |t| widest = @max(widest, t.width / 2);
    for (vias) |v| widest = @max(widest, v.dia / 2);
    const boxes = ctx.arena.alloc(PadObs, tracks.len + vias.len) catch return;
    for (tracks, 0..) |t, i| boxes[i] = .{
        .x0 = @min(t.x1, t.x2),
        .y0 = @min(t.y1, t.y2),
        .x1 = @max(t.x1, t.x2),
        .y1 = @max(t.y1, t.y2),
        .net = t.net,
    };
    for (vias, 0..) |v, i| boxes[tracks.len + i] = .{ .x0 = v.x, .y0 = v.y, .x1 = v.x, .y1 = v.y, .net = v.net };
    ctx.exact.?.index = PadGrid.build(ctx.arena, boxes, gridBounds(ctx.grid), widest + ctx.reach + ctx.grid.g * sqrt2);
}

/// The gap pass's exact-clearance model. The maze raster can only mark whole
/// cells, so the raster-only obstacle model inflates every obstacle by
/// `g·√2/2` — the furthest a diagonal move's midpoint strays from the nodes
/// actually tested. That margin is sized by the GRID PITCH, which is set by the
/// board's widest net class, so a 0.127 mm control net threading past 0.127 mm
/// copper is walled out of corridors it physically fits: 0.254 mm of real
/// centre-to-centre clearance is modelled as 0.409 mm. Exact mode stamps the
/// true clearance and re-measures each candidate move against the copper — the
/// error disappears instead of merely shrinking, and only moves touching the
/// thin `near` band pay for the measurement.
const ExactClearance = struct {
    /// Per-`layer*nodes + node`: this node lies inside some foreign obstacle's
    /// clearance INFLATED by one diagonal step. A move with both ends outside
    /// the band is provably clear (every point of it sits within `g·√2/2` of an
    /// end), so it needs no measurement.
    near: []bool = &.{},
    /// The board copper the current stamp was taken from — index order is
    /// tracks then vias, matching `index`.
    tracks: []const Track = &.{},
    vias: []const Via = &.{},
    /// Bounding-box bucket index over `tracks ++ vias`; null falls back to the
    /// full scan (same verdict, more work).
    index: ?*const PadGrid = null,
};

/// True when the maze move `from_key → (to_layer, to_node)` keeps the routing
/// net's real clearance from every foreign track and via. This is what lets the
/// stamp drop the raster's diagonal-step margin: the margin existed only
/// because nothing re-measured the move, and now something does.
///
/// A layer change is not a segment — it is a via drop, whose clearance
/// `viaAllowed` owns — so it passes through.
pub fn moveClearsCopper(ctx: *Ctx, net: i32, from_key: usize, to_layer: usize, to_node: usize) bool {
    const ex = ctx.exact orelse return true;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    if (from_key / nodes != to_layer) return true;
    const to_key = to_layer * nodes + to_node;
    if (from_key >= ex.near.len or to_key >= ex.near.len) return true;
    if (!ex.near[from_key] and !ex.near[to_key]) return true;
    const from_node = from_key % nodes;
    const a = [2]f64{ grid.worldX(from_node % grid.nx), grid.worldY(from_node / grid.nx) };
    const b = [2]f64{ grid.worldX(to_node % grid.nx), grid.worldY(to_node / grid.nx) };
    const move = MoveSeg{ .a = a, .b = b, .net = net, .layer = @intCast(to_layer) };
    if (ex.index) |idx| {
        for (idx.near(a[0], a[1])) |ci| if (!exactItemClears(ctx, ex, ci, move)) return false;
        return true;
    }
    for (0..ex.tracks.len + ex.vias.len) |ci| if (!exactItemClears(ctx, ex, ci, move)) return false;
    return true;
}

/// One candidate maze move, as the geometry the exact clearance test measures:
/// the segment between the two nodes, plus the routing net and the layer it
/// would be drawn on.
const MoveSeg = struct { a: [2]f64, b: [2]f64, net: i32, layer: u8 };

/// Does obstacle `ci` (a track while `ci` indexes `tracks`, else a via) leave
/// the routing net's clearance around the segment a→b on `layer`?
fn exactItemClears(ctx: *Ctx, ex: ExactClearance, ci: usize, move: MoveSeg) bool {
    // The very probes the direct/dogleg synthesis measures a shortcut by, so the
    // exact model widens for an obstacle's keepout — and waives that widening
    // inside an admitting escape zone — exactly where the raster stamp does.
    if (ci < ex.tracks.len) {
        const t = ex.tracks[ci];
        return t.net == move.net or t.layer != move.layer or segClearsTrack(ctx, t, move.a, move.b);
    }
    const v = ex.vias[ci - ex.tracks.len];
    return v.net == move.net or segClearsVia(ctx, v, move.a, move.b);
}

pub fn zoneBounds(poly: []const [2]f64) optimizer.BoardRect {
    return outline_mod.bboxRect(poly);
}

pub fn zoneArea(poly: []const [2]f64) f64 {
    if (poly.len < 3) return 0;
    var twice: f64 = 0;
    var previous = poly[poly.len - 1];
    for (poly) |point| {
        twice += previous[0] * point[1] - point[0] * previous[1];
        previous = point;
    }
    return @abs(twice) / 2;
}

/// True when `(x, y)` sits inside `zone`'s polygon but the copper is NOT there:
/// a strictly-higher-priority pour of a different net covers the same spot on
/// the same layer, so this pour's fill was knocked back (KiCad zone-priority
/// resolution, mirrored by `pour.clippedByHigher`). A plane stitch that lands
/// here drills into a clearance gap — the via is DRC-clean and joins nothing,
/// which is exactly the "copper landed, islands did not merge" outcome.
pub fn zoneClipped(ctx: *const Ctx, zone: route_policy.ExistingZone, x: f64, y: f64) bool {
    for (ctx.zones) |z| {
        if (!z.copper or z.layer != zone.layer or z.net == zone.net) continue;
        if (z.priority <= zone.priority) continue;
        if (outline_mod.contains(z.polygon, x, y)) return true;
    }
    return false;
}

/// True when `(x, y)` is a point where `zone`'s copper really is — inside the
/// polygon and not clipped away by a higher-priority overlap.
pub fn zonePoured(ctx: *const Ctx, zone: route_policy.ExistingZone, x: f64, y: f64) bool {
    return outline_mod.contains(zone.polygon, x, y) and !zoneClipped(ctx, zone, x, y);
}

/// True when `(x, y)` sits in copper poured for `net` ITSELF (not a foreign pour
/// the point merely lies over) on some layer other than `except_layer`.
///
/// A via there is a plane tap: copper hanging off it may reach the rest of the
/// net only through that pour, so a cleanup pass deleting vias must leave it
/// alone — the island model does not carry pours. `except_layer` is the layer a
/// caller is about to draw its replacement copper on: a tap there needs no via,
/// because the chain endpoint stays put inside the pour and keeps the
/// connection by plain copper overlap (a same-net zone merges with same-net
/// tracks rather than clearing around them).
pub fn netPourCovers(ctx: *const Ctx, net: i32, x: f64, y: f64, except_layer: ?u8) bool {
    for (ctx.zones) |z| {
        if (!z.copper or z.net != net) continue;
        if (except_layer) |skip| {
            if (z.layer == skip) continue;
        }
        if (zonePoured(ctx, z, x, y)) return true;
    }
    return false;
}

/// Does `net` own pour copper that SURVIVES priority clipping within `reach` of
/// `(x, y)` — real fabricated metal a stitch via could land in, rather than a
/// polygon a pour merely declares?
///
/// `largestNetZone(…) != null` answers the DECLARED question, and the two are
/// different answers on a board whose pours overlap. Barracuda's `V_6VA` In3
/// pour (priority 5) is overlapped almost end to end by `V_3V3_LMX`'s (priority
/// 6), so all but a ~1.2 mm band of its fill is knocked back; `V_3V3A`'s zone
/// stops at y = 105.75 while a third of its pads sit north of it. Both nets
/// therefore read as "poured" everywhere and every stitch site was measured
/// against copper that is not there — the pad ends up with no site at all
/// rather than with the ordinary trace its island actually needs.
///
/// Clipping is LOCAL, so this is asked local to the pad: the same net can be
/// genuinely poured under one pad and bare under another 20 mm away, and each
/// pad has to be judged where it stands. Sampling is on the router's own grid,
/// which is exactly the lattice every stitch site is snapped to, so a band no
/// grid node lands in is a band no via could have used anyway.
pub fn pourLiveNear(ctx: *const Ctx, net: i32, x: f64, y: f64, reach: f64) bool {
    // A pad standing in its own live copper is the common case and needs no scan.
    if (netPourCovers(ctx, net, x, y, null)) return true;
    const lo = ctx.grid.nearest(x - reach, y - reach);
    const hi = ctx.grid.nearest(x + reach, y + reach);
    var iy = lo[1];
    while (iy <= hi[1]) : (iy += 1) {
        var ix = lo[0];
        while (ix <= hi[0]) : (ix += 1) {
            const px = ctx.grid.worldX(ix);
            const py = ctx.grid.worldY(iy);
            if (std.math.hypot(px - x, py - y) > reach) continue;
            if (netPourCovers(ctx, net, px, py, null)) return true;
        }
    }
    return false;
}
pub fn zoneBlocksPoint(
    ctx: *const Ctx,
    layer: usize,
    point: [2]f64,
    net: i32,
    reach: f64,
    via: bool,
) bool {
    const x = point[0];
    const y = point[1];
    for (ctx.zones) |zone| {
        if (via) {
            if (!zone.vias_blocked) continue;
        } else {
            if (zone.layer != layer or !zone.tracks_blocked) continue;
        }
        if (zone.copper and zone.net == net) continue;
        // A lower-priority pour can geometrically cover this point yet have no
        // fabricated copper here because another pour clipped it away.  Such a
        // phantom region blocks neither a barrel nor a trace.
        if (zone.copper and zoneClipped(ctx, zone, x, y)) continue;
        if (outline_mod.contains(zone.polygon, x, y) or
            outline_mod.distToEdge(zone.polygon, x, y) < reach - clearance_eps) return true;
    }
    return false;
}

/// Index of the first ground net that HAS a plane (by name), or null when the
/// board has none — then there's no plane to stitch to and the return-path
/// stitch pass is skipped (on a plane-less 2-layer board ground is ordinary
/// routed copper, so "stitching" it makes no sense).
pub fn firstGroundNet(placement: optimizer.Placement) ?i32 {
    for (placement.nets, 0..) |net, i| {
        if (isGroundName(shortName(net.name)) and netHasPlane(placement, net.name)) return @intCast(i);
    }
    return null;
}

/// Claim every empty grid node within `dist` (mm) of (x,y) for `net` — on
/// signal layer `layer`, or on EVERY signal layer when `both` (a through
/// via's barrel reaches them all). Existing copper is never overwritten.
/// Used to reserve a via/stub's clearance halo so the maze pass keeps
/// foreign copper away from it.
pub fn stampDisc(ctx: *Ctx, x: f64, y: f64, net: i32, dist: f64, layer: u8, both: bool) void {
    const grid = ctx.grid;
    const r_nodes: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse 0;
    const c = grid.nearest(x, y);
    const ci: i64 = @intCast(c[0]);
    const cj: i64 = @intCast(c[1]);
    // Hoisted out of the per-cell loop: a single-layer stamp used to walk every
    // layer and `continue` past all but one, paying the whole board's layer
    // count for each of the millions of cells a board-wide re-stamp touches.
    const lanes: []const []i32 = if (both)
        ctx.occ
    else if (layer < ctx.occ.len)
        ctx.occ[layer .. layer + 1]
    else
        &.{};
    if (lanes.len == 0) return;
    var dj: i64 = -r_nodes;
    while (dj <= r_nodes) : (dj += 1) {
        var di: i64 = -r_nodes;
        while (di <= r_nodes) : (di += 1) {
            const ix = ci + di;
            const iy = cj + dj;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            // Squared compare: a board-wide re-stamp evaluates this for millions
            // of cells and `hypot` is the scaled, exactly-rounded routine.
            const ddx = wx - x;
            const ddy = wy - y;
            if (!keepout.bandClaims(ctx.keep.zones, ctx.keep.band, ddx * ddx + ddy * ddy, dist * dist, .{ wx, wy })) continue;
            const n = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            for (lanes) |occ_l| {
                if (occ_l[n] == empty_cell) occ_l[n] = net;
            }
        }
    }
}

/// Fine grids have sub-clearance neighbour spacing, so exact copper nodes need
/// a non-connective halo in `resv`. Normal-pitch grids already get this
/// guarantee from one-node spacing and retain their byte-identical raster.
pub fn stampTrackResv(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) void {
    const dist = ctx.params.track_width / 2 + ctx.index_reach - clearance_eps;
    if (layer >= ctx.resv.len or ctx.grid.g >= dist) return;
    const grid = ctx.grid;
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (grid.g * 0.5))));
    for (0..steps + 1) |step| {
        const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
        const x = a[0] + t * (b[0] - a[0]);
        const y = a[1] + t * (b[1] - a[1]);
        reserveDisc(ctx, x, y, net, dist, layer);
    }
}

/// Reserve every free `resv` node within `dist` of (x, y) on `layer` for `net`
/// — `disc_stamp`'s shared raster, first writer owning the node.
fn reserveDisc(ctx: *Ctx, x: f64, y: f64, net: i32, dist: f64, layer: u8) void {
    disc_stamp.claimFree(ctx.grid, ctx.resv[layer], .{ x, y }, dist, net);
}

// ── RF same-layer keepout (see `KeepState` and `placement/keepout.zig`) ──────

/// Extra edge-to-edge separation (mm) an obstacle on `obstacle_net` demands over
/// the routing net's ordinary clearance, because that net declared a keepout — so
/// `stampBoardCopper` and `exactItemClears` widen only the pairs the rule is about.
/// Zero between two members of ONE class: they are one signal family, held apart
/// by their shared clearance and not by each other's halo (`keepout.ClassGate`).
pub fn keepoutExtra(ctx: *const Ctx, obstacle_net: i32) f64 {
    if (ctx.keep.class.waives(obstacle_net)) return 0;
    return keepout.extraOver(ctx.keep.nets, obstacle_net, ctx.params.clearance, ctx.keep.exempt);
}

/// Conservative pad-index expansion: ordinary widest-class reach plus the
/// largest authored halo. Extra candidates are harmless; missing one is not.
pub fn padIndexReach(ctx: *const Ctx) f64 {
    return ctx.index_reach + keepout.maxHalo(ctx.keep.nets);
}

/// Largest keepout halo a foreign obstacle may demand over ordinary clearance.
/// The copper-index build and probe radii need it so a halo-only obstacle is
/// still found before the per-candidate test applies its own `keepoutExtra`.
fn keepMaxExtra(ctx: *const Ctx) f64 {
    if (ctx.keep.exempt) return 0;
    return @max(0, keepout.maxHalo(ctx.keep.nets) - ctx.params.clearance);
}

/// The `{ ordinary, ordinary + halo }` pair `keepout.approachClears` judges an
/// approach to `net`'s copper by, with this file's float epsilon folded in.
fn keepLimits(ctx: *const Ctx, net: i32, ordinary: f64) [2]f64 {
    const plain = ordinary - clearance_eps;
    return .{ plain, plain + keepoutExtra(ctx, net) };
}

/// Where segment a→b passes closest to (x, y) — the approach point every keepout
/// probe reports. `pad_shape` owns the projection; this is the array-shaped
/// wrapper the router's own call sites read best.
fn closestOnLine(a: [2]f64, b: [2]f64, x: f64, y: f64) [2]f64 {
    const c = pad_shape.closestOnSeg(a[0], a[1], b[0], b[1], x, y);
    return .{ c.x, c.y };
}

pub fn padSegmentClears(ctx: *const Ctx, p: PadObs, a: [2]f64, b: [2]f64, ordinary: f64) bool {
    const lim = keepLimits(ctx, p.net, ordinary);
    if (segmentMissesBox(a, b, .{ p.x0, p.y0, p.x1, p.y1 }, lim[1])) return true;
    const shape = pad_shape.Shape{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly };
    const distance = pad_shape.segmentDist(shape, a, b, lim[1]);
    const at = closestOnLine(a, b, (p.x0 + p.x1) / 2, (p.y0 + p.y1) / 2);
    return keepout.approachClears(ctx.keep.zones, p.net, distance, at, lim);
}

/// Is node `n` inside a FOREIGN net's stamped keepout halo — on `layer`, or (null
/// = a via, whose barrel occupies them all) on ANY layer? Mirrors `blocked`'s
/// `resv` test plus the two exemptions: ground owes no keepout, a halo's owner
/// routes through its own, and a GATED node admits the nets it was opened for.
pub fn keepoutBlocked(ctx: *const Ctx, layer: ?usize, n: usize, net: i32) bool {
    if (ctx.keep.exempt) return false;
    if (layer) |l| return l < ctx.keep.layers.len and keepoutBlockedOn(ctx, l, n, net);
    for (0..ctx.keep.layers.len) |l| if (keepoutBlockedOn(ctx, l, n, net)) return true;
    return false;
}

/// `keepoutBlocked` for one signal layer: claimed by a halo this net owes (a
/// fellow class member's is not one) AND not let through by that node's gate.
fn keepoutBlockedOn(ctx: *const Ctx, layer: usize, n: usize, net: i32) bool {
    if (!keepout.claimed(ctx.keep.layers[layer], ctx.keep.class.ids, n, net)) return false;
    return !keepoutGateAdmits(ctx, layer, n, net);
}

/// Does the gate on halo node `(layer, n)` admit `net`? See `KeepState.gate` for
/// the encoding. An ungated node admits nobody — the halo's whole point.
fn keepoutGateAdmits(ctx: *const Ctx, layer: usize, n: usize, net: i32) bool {
    if (layer >= ctx.keep.gate.len) return false;
    const g = ctx.keep.gate[layer][n];
    if (g == empty_cell) return false;
    if (g >= 0) return g == net; // a pad landing: only that pad's net
    return ctx.keep.zones.admits(@intCast(-g - 2)); // an escape zone: ask the gate
}

/// One keepout-halo stamping request: whose halo, which signal layer, how far it
/// reaches from the centreline, and the escape zones gating it open.
pub const KeepStamp = struct {
    net: i32,
    layer: u8,
    dist: f64,
    /// The owner's escape zones, and the index of the first of them in
    /// `KeepState.zones.all` so a covering zone can be encoded into `gate`.
    zones: []const keepout.Zone = &.{},
    zone_base: u32 = 0,
};

/// The stamp for a keepout net's copper of half-extent `half` (a track half-width
/// or a via radius): that copper, plus the halo, plus an allowance for the FOREIGN
/// centreline it holds off — the maze tests node centres and nothing else adds an
/// intruder's own half-width.
pub fn keepStamp(ctx: *const Ctx, net: i32, layer: u8, half: f64) KeepStamp {
    return .{
        .net = net,
        .layer = layer,
        .dist = half + keepout.haloAt(ctx.keep.nets, net) + ctx.max_half_width,
        .zones = ctx.keep.zones.of(net),
        .zone_base = ctx.keep.zones.base(net),
    };
}

/// Claim every free node within `st.dist` of (x,y) on `st.layer` for `st.net`'s
/// keepout halo, recording each node's gate (`KeepState.gate`) as it goes: the
/// escape zone or the foreign pad landing that opens it, and to whom. Claiming
/// rather than SKIPPING those nodes is the difference between an opening and a
/// hole — see `keepout.zig`'s module doc for the filter corridor an ungated one
/// left wide open.
fn keepDisc(ctx: *Ctx, x: f64, y: f64, st: KeepStamp) void {
    if (st.layer >= ctx.keep.layers.len) return;
    const Claim = struct {
        ctx: *Ctx,
        lane: []i32,
        st: KeepStamp,

        fn stamp(self: @This(), node: disc_stamp.Node) void {
            keepClaim(self.ctx, self.lane, node.at, node.x, node.y, self.st);
        }
    };
    const claim = Claim{ .ctx = ctx, .lane = ctx.keep.layers[st.layer], .st = st };
    disc_stamp.forEach(ctx.grid, .{ x, y }, st.dist, claim, Claim.stamp);
}

/// Claim one node for `st`, preserving first-stamp ownership and recording the
/// net-gated opening that covers it. Shared by disc and exact pad-shape stamps.
fn keepClaim(ctx: *Ctx, lane: []i32, node: usize, x: f64, y: f64, st: KeepStamp) void {
    if (lane[node] != empty_cell) return;
    lane[node] = st.net;
    if (keepGateAt(ctx, x, y, st)) |code| {
        if (st.layer < ctx.keep.gate.len) ctx.keep.gate[st.layer][node] = code;
    }
}

/// The gate code for a halo node at (x,y) under stamp `st`, or null when the halo
/// closes there for everyone. Escape zones are tested first: they are the
/// owner's own declaration, and a pad landing inside one would otherwise narrow
/// the opening to a single net.
fn keepGateAt(ctx: *Ctx, x: f64, y: f64, st: KeepStamp) ?i32 {
    for (st.zones, 0..) |z, i| {
        if (std.math.hypot(x - z.x, y - z.y) > z.r) continue;
        const index: i32 = @intCast(st.zone_base + i);
        return -index - 2;
    }
    return foreignPadNetAt(ctx, x, y, st.net);
}

/// The net of the first FOREIGN pad whose landing (its copper plus the clearance
/// ring only that net may occupy) covers (x,y), else null. Such a node is gated
/// to that net rather than closed, which keeps the rule from contradicting
/// itself: pads never offend, yet a pad whose landing the halo claimed would be
/// one its own net could not route out of.
///
/// The gate matters even though `foreignPadAt` already bars other nets from most
/// of these nodes: it is measured with `index_reach` (the widest class), while
/// pad blocking uses the ROUTING net's narrower `reach`, and it is layer-blind
/// while pad blocking is layer-aware. Both differences left the landing open to
/// every net; naming the net closes them.
fn foreignPadNetAt(ctx: *Ctx, x: f64, y: f64, keep_net: i32) ?i32 {
    if (ctx.obs.len == 0) return null;
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, gridBounds(ctx.grid), padIndexReach(ctx));
    const idx = ctx.pad_index orelse return null;
    const reach = ctx.index_reach;
    for (idx.near(x, y)) |pi| {
        const p = ctx.obs[pi];
        if (p.net == keep_net) continue;
        if (pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, x, y, reach) < reach) return p.net;
    }
    return null;
}

/// Stamp a keepout halo along the segment a→b, sampled at half-grid steps like
/// every other halo writer.
pub fn stampKeepoutSeg(ctx: *Ctx, a: [2]f64, b: [2]f64, st: KeepStamp) void {
    if (!(st.dist > 0) or st.layer >= ctx.keep.layers.len) return;
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
    for (0..steps + 1) |step| {
        const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
        keepDisc(ctx, a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), st);
    }
}

/// Stamp a keepout net's via halo on EVERY signal layer — its barrel is on all
/// of them, so foreign copper owes the halo wherever it runs.
fn stampKeepoutViaAll(ctx: *Ctx, x: f64, y: f64, st: KeepStamp) void {
    if (!(st.dist > 0)) return;
    for (0..ctx.keep.layers.len) |layer| {
        var one = st;
        one.layer = @intCast(layer);
        keepDisc(ctx, x, y, one);
    }
}

/// Stamp the exact copper outline of one keepout pad, dilated by its halo and
/// the widest foreign track half-width. SMD pads protect their face only;
/// through pads protect every signal layer just like vias.
pub fn stampKeepoutPad(ctx: *Ctx, p: PadObs) void {
    const halo = keepout.haloAt(ctx.keep.nets, p.net);
    if (!(halo > 0)) return;
    const first: usize = if (p.thru) 0 else p.layer;
    if (first >= ctx.keep.layers.len) return;
    const last: usize = if (p.thru) ctx.keep.layers.len else @min(first + 1, ctx.keep.layers.len);
    for (first..last) |layer| {
        stampKeepoutPadOn(ctx, p, keepStamp(ctx, p.net, @intCast(layer), 0));
    }
}

fn stampKeepoutPadOn(ctx: *Ctx, p: PadObs, st: KeepStamp) void {
    if (st.layer >= ctx.keep.layers.len) return;
    const grid = ctx.grid;
    const lane = ctx.keep.layers[st.layer];
    const cx = (p.x0 + p.x1) / 2;
    const cy = (p.y0 + p.y1) / 2;
    const corner = std.math.hypot(@abs(p.x1 - p.x0) / 2, @abs(p.y1 - p.y0) / 2);
    const radius: i64 = numeric.checkedInt(i64, @ceil((corner + st.dist) / grid.g)) orelse return;
    const center = grid.nearest(cx, cy);
    var dy: i64 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i64 = -radius;
        while (dx <= radius) : (dx += 1) {
            const ix = @as(i64, @intCast(center[0])) + dx;
            const iy = @as(i64, @intCast(center[1])) + dy;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            if (pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, wx, wy, st.dist) > st.dist) continue;
            const node = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            keepClaim(ctx, lane, node, wx, wy, st);
        }
    }
}

pub fn stampKeepoutPadsForNet(ctx: *Ctx, net: i32) void {
    for (ctx.obs) |p| {
        if (p.net == net) stampKeepoutPad(ctx, p);
    }
}

/// Stamp both RF bands of the copper the routing net is laying right now: its
/// same-layer keepout halo (`KeepState`) and its all-layer crossing shadow
/// (`rf_shadow`). Both read the current net's resolved widths, already loaded by
/// `setNetParams`, and both no-op for a net that declared neither.
pub fn stampCurrentRf(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) void {
    const half = ctx.params.track_width / 2;
    if (ctx.keep.halo > 0) stampKeepoutSeg(ctx, a, b, keepStamp(ctx, net, layer, half));
    ctx.shadow.stampSeg(ctx.grid, a, b, half, net);
}

/// Stamp the RF halo + shadow of a VIA the routing net is laying right now. The
/// barrel is on every signal layer, so both bands are too.
pub fn stampCurrentRfVia(ctx: *Ctx, x: f64, y: f64, net: i32) void {
    const r = viaR(ctx.params);
    if (ctx.keep.halo > 0) stampKeepoutViaAll(ctx, x, y, keepStamp(ctx, net, 0, r));
    ctx.shadow.stampVia(ctx.grid, x, y, r, net);
}

/// Stamp the RF halo + shadow of copper RETAINED from a previous run (a scoped
/// route, or a re-route seeded from a saved layout): the emitters only band
/// copper THIS run lays, so an RF trace that arrived as existing copper would
/// otherwise be unprotected while every net around it reroutes.
pub fn stampRetainedRf(
    ctx: *Ctx,
    placement: optimizer.Placement,
    copper: struct { tracks: []const Track, vias: []const Via },
) void {
    if (ctx.keep.layers.len == 0 and ctx.shadow.layers.len == 0) return;
    for (placement.nets, 0..) |_, ni| {
        const halo = keepout.haloOf(placement, ni);
        const shadow = rf_shadow.widthOf(placement, ni);
        if (!(halo > 0) and !(shadow > 0)) continue;
        const id: i32 = @intCast(ni);
        var one = ctx.shadow;
        one.width = shadow;
        for (copper.tracks) |t| {
            if (t.net != id) continue;
            if (halo > 0) stampKeepoutSeg(ctx, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, keepStamp(ctx, id, t.layer, t.width / 2));
            one.stampSeg(ctx.grid, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, t.width / 2, id);
        }
        for (copper.vias) |v| {
            if (v.net != id) continue;
            if (halo > 0) stampKeepoutViaAll(ctx, v.x, v.y, keepStamp(ctx, id, 0, v.dia / 2));
            one.stampVia(ctx.grid, v.x, v.y, v.dia / 2, id);
        }
    }
}

/// Minimal radius (mm) within which a foreign grid node must be excluded so no
/// foreign track/via comes closer than `D = viaR + track_half + clearance` to a
/// via centre. A foreign track between two nodes both at radius R dips to
/// `√(R²−g²/2)` at its closest, so `R = √(D² + g²/2)` is exactly enough — much
/// tighter than a flat per-node margin, which is what keeps tight parts routable.
pub fn copperHalo(ctx: *Ctx) f64 {
    const d = viaR(ctx.params) + ctx.params.track_width / 2 + ctx.params.clearance;
    return @sqrt(d * d + ctx.grid.g * ctx.grid.g * 0.5);
}

fn viaObstacleRadius(ctx: *Ctx) f64 {
    const via_via = ctx.params.via_dia + ctx.params.clearance;
    return @max(copperHalo(ctx), via_via);
}

/// How far `viaAllowed` must expand a foreign `occ` cell to bound the physical
/// via↔copper clearance. The answer depends on what `occ` actually HOLDS, which
/// differs between the two routing modes:
///
///   * whole-board route — `occ` is connective copper centreline/centre data,
///     so the expansion has to carry the entire physical term at once
///     (`viaObstacleRadius`), and a paired diff-pair portal drops the via↔via
///     half of it (`copperHalo`).
///   * gap pass (`ctx.exact` armed) — `stampGapBoard` wipes both grids and
///     `stampBoardCopper` refills `occ` with every foreign track ALREADY
///     inflated by `width/2 + reach` and every foreign via by `dia/2 + reach`.
///     The one term a via adds over a track centre is its own radius, so that
///     is all this may expand by; carrying the full physical clearance a second
///     time double-counts a track width plus a clearance and walls legal via
///     sites out of corridors they physically fit (the `no_via_site` verdict).
///
/// The gap-pass radius keeps the raster's half-diagonal, since `occ` samples the
/// inflated region at NODES and any point sits within `g·√2/2` of one. That
/// leaves the test conservative — it may still refuse a site by up to that
/// margin — never permissive, so relaxing it cannot introduce a clearance DRC.
fn viaOccReach(ctx: *Ctx, paired_portal: bool) f64 {
    if (ctx.exact == null) return if (paired_portal) copperHalo(ctx) else viaObstacleRadius(ctx);
    return viaR(ctx.params) + ctx.grid.g * (sqrt2 / 2);
}

/// Put a placed through-via's actual connective centre in `occ`, and its
/// non-connective track-clearance halo in `resv` on every signal layer. Keeping
/// those roles separate lets another legal via sit just outside via-to-via
/// clearance without the old double-halo rejection, while tracks still cannot
/// treat clearance cells as copper sources.
pub fn stampViaOcc(ctx: *Ctx, x: f64, y: f64, net: i32) void {
    const center = ctx.grid.nearest(x, y);
    const node = ctx.grid.node(center[0], center[1]);
    for (ctx.occ, 0..) |occ_l, layer| {
        if (occ_l[node] == empty_cell) occ_l[node] = net;
        reserveDisc(ctx, x, y, net, copperHalo(ctx), @intCast(layer));
    }
}

/// Reserve a ground-via stub's clearance halo along its length on the stub's
/// own signal layer, so a foreign via can't be dropped on top of the stub.
pub fn stampStubOcc(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) void {
    const grid = ctx.grid;
    const d = copperHalo(ctx);
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (grid.g * 0.5))));
    var s: usize = 0;
    while (s <= steps) : (s += 1) {
        const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
        stampDisc(ctx, a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), net, d, layer, false);
    }
}

/// May a layer-changing via be dropped at node `n` for net `net`? It must clear
/// foreign pads by the via clearance, keep the hole-to-hole wall from every pad
/// bore, and have no foreign copper within its halo on ANY signal layer (vias
/// are through-only, so the barrel meets them all) — so a maze via can never
/// crowd a pad or an already-routed foreign track/via.
///
/// The pad-bore wall is measured here rather than left to `via_ban`: that mask
/// is built only by the gap-closing pass, so the whole-board maze had no drill
/// test at all, and the mask is grid-quantized where `PadDrills` is exact.
pub fn viaAllowed(ctx: *Ctx, n: usize, net: i32, placed: []const Via) bool {
    const grid = ctx.grid;
    if (ctx.via_forbidden_net == net) if (ctx.via_forbidden_mask) |mask| {
        if (mask[n]) return false;
    };
    if (ctx.via_ban) |mask| {
        if (n < mask.len and mask[n]) return false;
    }
    if (outlineBlocked(ctx, n, net)) return false; // no vias off-board / in the edge inset
    const x = grid.worldX(n % grid.nx);
    const y = grid.worldY(n / grid.nx);
    if (!viaClearsOutline(ctx, x, y, net)) return false;
    if (!viaClearsSameNetVias(ctx, placed, x, y, net)) return false;
    if (!viaClearsPadDrills(ctx, x, y)) return false;
    const zone_reach = viaR(ctx.params) + ctx.params.clearance;
    if (zoneBlocksPoint(ctx, 0, .{ x, y }, net, zone_reach, true)) return false;
    if (!viaClearsPads(ctx, x, y, net)) return false;
    // Reservations already contain the full track/via-to-track exclusion at
    // their target nodes. Test them once instead of expanding a second halo
    // around an already-expanded reservation.
    for (ctx.resv) |resv_l| {
        if (resv_l[n] != empty_cell and resv_l[n] != net) return false;
    }
    // A through barrel is on every signal layer, so a same-layer keepout halo
    // stamped on ANY of them still refuses the site.
    if (keepoutBlocked(ctx, null, n, net)) return false;
    // Expand each foreign `occ` cell by exactly the term it is still missing —
    // which is not the same in both modes (see `viaOccReach`).
    const paired_portal = ctx.pair_vias_hard and
        (if (ctx.pair_via_mask) |mask| mask[n] else false);
    const dist = viaOccReach(ctx, paired_portal);
    const r_nodes: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse 0;
    const ci: i64 = @intCast(n % grid.nx);
    const cj: i64 = @intCast(n / grid.nx);
    var dj: i64 = -r_nodes;
    while (dj <= r_nodes) : (dj += 1) {
        var di: i64 = -r_nodes;
        while (di <= r_nodes) : (di += 1) {
            const ix = ci + di;
            const iy = cj + dj;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            if (std.math.hypot(wx - x, wy - y) > dist) continue;
            const m = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            for (ctx.occ) |occ_l| {
                if (occ_l[m] != empty_cell and occ_l[m] != net) return false;
            }
        }
    }
    return true;
}

// ── Maze routing ─────────────────────────────────────────────────────────

/// One net's inline bend-smoothing outcome — the true-arc metadata plus the
/// corners that missed the minimum radius. Slices are arena-owned.
pub const NetSmooth = struct { arcs: []const Arc, sharp: []const SharpBend };

/// RF bend-discipline routing state. `escape_mm`/`escape_pts` describe the
/// net currently being routed (a straight pad-escape reserve the maze cost
/// model enforces softly); `net_smooth` accumulates every net's inline
/// smoothing results, keyed by net index. Entries are dropped with the net's
/// copper on rip-up and snapshot/restored with the rest of the routing state.
const RfState = struct {
    escape_mm: f64 = 0,
    escape_pts: []const NetPt = &.{},
    net_smooth: std.AutoHashMapUnmanaged(i32, NetSmooth) = .empty,
    port_outcomes: std.AutoHashMapUnmanaged(i32, rf_port_report.Outcome) = .empty,
};

/// `(net-class … (keepout MM))` enforcement state — the maze's half of what
/// `drc_keepout.zig` checks afterwards. `keepout.zig`'s module doc carries the
/// semantics and why the halo gets its own node mask instead of more `resv`
/// stamps (in one line: only a separate lane can be waived for ground without
/// also waiving the ordinary clearance sharing that array).
pub const KeepState = struct {
    /// Per-net resolved halo (mm), net-indexed. Empty ⇒ no net on this board
    /// declares a keepout — the early-out every path checks first.
    nets: []const f64 = &.{},
    /// Per-signal-layer halo ownership: the net whose keepout claims this node,
    /// else `empty_cell`. Empty ⇒ nothing stamped. Owner ids (not a bitset), so
    /// a keepout net still routes through its own halo. Allocated ONLY on the
    /// whole-board route context; every derived context (windowed retry, gap
    /// pass, `visionMask`) instead gets the keepout term inside
    /// `stampBoardCopper`'s halo, so there is one allocation site and one place
    /// (`windowCtx`) that drops an inherited mask.
    layers: []const []i32 = &.{},
    /// Per-signal-layer GATE on a claimed halo node — the openings the halo has
    /// to carry, made net-specific so an opening admits only the nets it exists
    /// for. `empty_cell` = no gate (closed to everyone but the owner). Two kinds
    /// share the lane:
    ///   * `>= 0` — a foreign PAD LANDING (see `foreignPadNetAt`): only that
    ///     pad's own net may pass, because the opening exists so that pad can be
    ///     escaped from. First pad found owns the node.
    ///   * `<= -2` — an ESCAPE ZONE, index `-(v) - 2` into `zones.all`: a net
    ///     passes only when `zones.admits` says it owns a pad inside that zone
    ///     (see `keepout.Zones`). First zone found owns the node.
    /// Same shape, allocation site and lifetime as `layers`.
    gate: []const []i32 = &.{},
    /// The escape zones `gate`'s negative codes index, plus the per-net
    /// admission flags `setNetParams` refreshes. Empty ⇒ no keepout net declares
    /// an escape radius and no cell is ever escape-gated.
    zones: keepout.Zones = .{},
    /// Pad centres + nets the gate is answered from (`ctx.obs` projected once),
    /// so the router and `drc_keepout` gate on the same points. Empty when no
    /// keepout is declared.
    pads: []const keepout.PadPt = &.{},
    /// The obstacle `stampBoardCopper` is laying RIGHT NOW: `stampDisc` splits its
    /// halo surplus off the clearance under it and lets an admitting escape zone
    /// waive that surplus per node (`keepout.bandClaims`), which is how a derived
    /// context reproduces the openings `gate` carries. Inert for every other
    /// stamper, each of which claims its whole disc outright.
    band: keepout.Band = .{},
    /// The CURRENT net's own halo (mm, 0 = not a keepout net) — what `emitSeg`
    /// stamps as it lays copper.
    halo: f64 = 0,
    /// The current net is ground/plane copper, so no keepout halo applies to it
    /// (`keepout.exempt`). Ordinary clearance still does.
    exempt: bool = false,
    /// Net-class identity + the net now routing, so a halo is waived between one
    /// class's own members (`keepout.ClassGate`). Net-indexed, so it travels with
    /// `nets` onto every derived context.
    class: keepout.ClassGate = .{},
};

/// The maze router's whole per-run routing state: the grid, the pad obstacles,
/// the per-signal-layer occupancy/reservation grids, and the effective geometry
/// of the net currently routing. Held live (behind `RouteCore`) so an
/// interactive `route_session` can drive per-net retries / frontier probes.
pub const Ctx = struct {
    arena: std.mem.Allocator,
    field_space: ?struct { placement: optimizer.Placement, provider: route_policy.RouteSpace } = null,
    grid: Grid,
    obs: []const PadObs,
    reach: f64,
    /// Routed-copper occupancy, one node grid per SIGNAL layer (`occ.len` is
    /// the board's signal-layer count — 2 on legacy/2-layer boards, more when
    /// the stackup declares plane-free inner layers). Index 0 = top, 1 =
    /// bottom, 2.. = inner signal layers in stack order.
    occ: []const []i32,
    /// Diagonal corner reservations, per signal layer. When a path takes a 45°
    /// step, the two orthogonal cells it squeezes past sit only `g/√2` from the
    /// diagonal's centreline — closer than the `g = width + clearance` the grid
    /// pitch guarantees — so `emitPath` reserves them here. `blocked` refuses
    /// them to foreign nets exactly like copper, but they are NOT the owning
    /// net's copper: Dijkstra never seeds from them, so a later same-net leg
    /// can't "connect" to a cell that carries no track.
    resv: []const []i32,
    /// The *effective* geometry for the net currently being routed —
    /// `base` overlaid with that net's `(net-class …)` rule (see
    /// `setNetParams`). Every clearance/width/via read goes through this.
    params: RouteParams,
    /// The caller's defaults, kept pristine so each net's overlay starts
    /// from the same base.
    base: RouteParams = .{},
    /// Hole-to-hole wall (mm) via placement keeps from every placed via drill —
    /// `placement.rules.design.hole_to_hole` (see `viaClearsHoles`).
    hole_to_hole: f64 = 0.25,
    /// The board's fixed PAD drills, and the index that answers which of them a
    /// candidate barrel's wall could touch — see `PadDrills`.
    pad_drills: PadDrills = .{},
    /// Copper spacing between vias on the same net. Zero means use the current
    /// net's resolved ordinary clearance, matching `drc.viaSpacing`.
    via_to_via: f64 = 0,
    /// Exact outline geometry and copper-edge rule used by off-grid via
    /// synthesis. The node mask cannot safely judge a point between nodes.
    edge_clearance: f64 = 0,
    board_rect: ?optimizer.BoardRect = null,
    board_poly: ?[]const [2]f64 = null,
    /// Pad-index prefilter reach — the MAX reach any net class can need, so
    /// the lazily-built PadGrid stays a superset for every net (exact tests
    /// still use the per-net `reach`).
    index_reach: f64 = 0,
    /// When false the maze may not change layers — used for the top-layer-only
    /// first pass so a short signal net (e.g. a feedback tap) stays on the
    /// surface instead of diving to L2 the moment a via is marginally cheaper.
    allow_vias: bool = true,
    /// Ceiling (mm) on what one maze layer change may cost, or null for the
    /// lattice price alone.
    ///
    /// The ordinary price is `grid.g * via_cost_mult` — denominated in GRID
    /// PITCHES, which keeps the cost model scale-free but makes the same
    /// physical via cost four times more on a wide-track net's coarse lattice
    /// (measured: 1.91 mm at the LDO fixture's 0.477 mm pitch) than on a
    /// fine-pitch net's (0.51 mm at 0.127 mm). `detourGuard`'s retry caps it at
    /// a physical figure so a connection that already detoured is re-searched
    /// with vias priced by what they cost the BOARD. A `@min`, never a
    /// replacement: the retry can only ever be more via-friendly than the
    /// attempt it is second-guessing, never less.
    via_cost_cap_mm: ?f64 = null,
    /// Net-indexed policy for this run plus the effective masks of the current
    /// net. All-zero defaults preserve the legacy search cost and reachability.
    net_policy: []const route_policy.NetPolicy = &.{},
    selected_nets: []const bool = &.{},
    /// Cooperative cancel flag (`route_policy.Options.stop.cancel`), polled at each
    /// per-net loop boundary via `routeCancelled`. Null never cancels.
    cancel: ?*std.atomic.Value(bool) = null,
    /// Absolute whole-route deadline; zero keeps the historical clock-free
    /// behavior. Expensive probe/maze loops poll it cooperatively.
    deadline_ns: i128 = 0,
    deadline_probe_count: u32 = 0,
    deadline_expired: bool = false,
    /// How hard this run retries before reporting a net failed (see
    /// `route_policy.Effort`). `one_shot` skips the escalate / rip-up /
    /// fine-rescue machinery entirely.
    effort: route_policy.Effort = .standard,
    /// Which searches a declared pair's coupled construction may ask for its
    /// envelope-wide channel (see `route_policy.PairChannel`). The default is
    /// the maze alone, which is every board this router has ever routed.
    pair_channel: route_policy.PairChannel = .maze_only,
    /// Where a coupled pair records the wall its envelope search hit, when the
    /// caller armed one (see `pair_pinch`). Null on every run that does not ask.
    pinch_log: ?*pair_pinch.Log = null,
    /// Retained filled zones and keepouts imported from the physical board.
    /// Zone interiors seed their owner net; exact polygons provide foreign
    /// track/via clearance without turning the clearance halo into connectivity.
    zones: []const route_policy.ExistingZone = &.{},
    /// The current pour-backed net connected at least one terminal but not all.
    /// `routeNet` leaves those useful plane legs in place while still reporting
    /// the net failed; the connectivity gate remains the completion authority.
    zone_partial: bool = false,
    /// An ordinary multi-terminal tree joined at least two real pads before a
    /// later terminal proved unreachable.  Those joined pads are useful,
    /// electrically honest copper: retain the subtree so a later retry can grow
    /// from it instead of throwing away every successful leg.  Guided trees do
    /// not set this flag because their leading virtual waypoints are not pads.
    tree_partial: bool = false,
    guide_tracks: []const route_policy.GuideTrack = &.{},
    guide_vias: []const route_policy.GuideVia = &.{},
    /// Corridors an authored `(assign-escapes … (reserve))` claims for their
    /// owning nets — POLICY, not copper, so every site that reallocates or
    /// clears `resv` must re-stamp it (`lane_reserve`, which enumerates them).
    reserved_lanes: []const route_policy.ReservedLane = &.{},
    reference_corridor: ?[]const bool = null,
    reference_via_mask: ?[]const bool = null,
    pair_via_mask: ?[]const bool = null,
    pair_terminal_mask: ?[]const bool = null,
    /// Envelope-route exclusion mask (`layer*nodes + node`) for a COUPLED diff
    /// pair: foreign copper dilated by the extra half-width the pair envelope
    /// needs beyond one track, which the grid's one-lane-per-net clearance model
    /// cannot express on its own (`diff_pairs.buildBlock`). Null for every other
    /// route, so `blocked` stays byte-identical everywhere else.
    pair_block: ?[]const bool = null,
    pair_vias_hard: bool = false,
    pair_coupling_hard: bool = false,
    /// The pad lands of the net whose terminal tree is being grown, priced by
    /// `net_topology.sourceCost` when a maze leg picks where to join its own
    /// copper: a join on the net's own land is free, one mid-span on a trace
    /// pays `midspan_join_penalty_mm`. Empty (the default) for every other
    /// maze pass — the pour terminal, the gap hops, the via-seeded retries —
    /// which price every source at zero exactly as before.
    join_lands: []const net_topology.Land = &.{},
    /// Rings the pad-gateway fan scans outward (`padGateways`), in GRID steps.
    /// A pass that re-grids finer must scale this or its fan silently shrinks in
    /// millimetres and fine-pitch pads read as sealed. Default = `gate_rings`.
    gate_rings: usize = gate_rings,
    via_forbidden_mask: ?[]const bool = null,
    via_forbidden_net: i32 = empty_cell,
    /// Node-indexed sites where NO net may drop a maze via (see
    /// `buildViaBanMask`) — pad copper and through drills, including the
    /// routing net's OWN, which every other via test deliberately skips. Only
    /// the gap-closing pass sets it; null leaves via placement unchanged.
    via_ban: ?[]const bool = null,
    reference_guide_active: bool = false,
    /// Prefix of `vias` supplied as retained reference copper. Return-path
    /// stitching only considers newly routed vias after this prefix.
    preserved_vias: usize = 0,
    /// RF bend-discipline state: the current net's escape zones plus every
    /// net's inline-smoothing results (see `smoothNetInline`).
    rf: RfState = .{},
    /// Axis-only (Manhattan) discipline for the net now routing, and whether its
    /// attempt is the one currently searching (see `manhattan_route`). Inert by
    /// default, which is what keeps every non-RF route byte-identical.
    manhattan: manhattan_route.State = .{},
    /// RF same-layer keepout enforcement (see `KeepState`). Defaults inert, so
    /// every context that does not opt in routes exactly as before.
    keep: KeepState = .{},
    /// RF crossing-shadow cost: the all-layer fence-corridor band foreign copper
    /// pays to enter (see `rf_shadow`). Defaults inert — no lanes, every
    /// multiplier 1.0 — so a board declaring no fence/keepout costs exactly as
    /// before.
    shadow: rf_shadow.State = .{},
    /// Half the widest net class's track width (mm) — the allowance a keepout
    /// halo makes for the FOREIGN centreline it is holding off, since the maze
    /// tests node centres and nothing else adds a foreign track's own half-width.
    /// 0 (the default) makes a stamped halo edge-exact for a zero-width intruder,
    /// which only ever under-blocks; the real router sets it from
    /// `maxRouteParams`.
    max_half_width: f64 = 0,
    preferred_layers: u64 = 0,
    allowed_layers: u64 = 0,
    waypoints: []const route_policy.Waypoint = &.{},
    guide_branches: []const route_policy.GuideBranch = &.{},
    max_vias: ?u16 = null,
    /// When true `blocked` measures clearance against each pad's real copper
    /// outline (poly), not its bounding box — so a concave thermal/EP pad doesn't
    /// falsely wall off a corridor that a short net could escape through. The
    /// outline test is much costlier (point-in-polygon per node), so it's only
    /// switched on for the brief top-layer-first attempts; the bulk two-layer
    /// maze stays on the cheap, conservative bounding-box path.
    use_poly: bool = false,
    /// True when any obstacle pad lives on (or reaches, via through-hole) the
    /// bottom signal layer — false keeps `blocked`'s legacy all-top fast path.
    has_bottom_pads: bool = false,
    /// Which outer signal layers a declared pour covers (0 = top, 1 = bottom).
    /// Maze steps onto a poured layer cost `POUR_COST_MULT`× so signal copper
    /// prefers the un-poured face instead of slicing the pour. Both false when
    /// no pour is declared — the legacy cost model, unchanged.
    pour: [2]bool = .{ false, false },
    /// Diff-pair coupling corridor for the N net currently routing: a
    /// per-`layer*nodes + node` bitset of cells near its already-routed P twin
    /// (`diff_pairs.buildCorridor`). `relaxStep` discounts a step landing in a
    /// `true` cell so the pair hugs. Null for every other net → cost byte-identical.
    corridor: ?[]const bool = null,
    /// Lazily-built spatial index over `obs` (pads are static for a route) so
    /// `blocked` tests only pads near the node, not all of them. Null until
    /// first use, or when the board is degenerate / the grid would be oversized
    /// (blocked then falls back to the full scan). Result-identical: it only
    /// pre-filters candidates by position; the exact per-pad decision is kept.
    pad_index: ?*const PadGrid = null,
    /// Exact-clearance move validation (see `ExactClearance`). Null for every
    /// whole-board route, which keeps its raster-only obstacle model byte for
    /// byte; only the gap-closing pass arms it.
    exact: ?ExactClearance = null,
    /// Per-`layer*nodes + node` memo of `staticBlockedUncached` — the half of
    /// `blocked` that does NOT read the copper stamp, and so is pure for as long
    /// as the routing net is fixed. Unarmed (the default) every caller
    /// recomputes, which is what a differently-sized lattice must do.
    static_block: maze_scratch.Memo = .{},
    /// Per-node board-outline mask (grid-node indexed, `nx*ny` long): true where
    /// a track/via centred on that node would leave the board or sit inside the
    /// copper-edge inset. Null when the design declares NO board outline — then
    /// every outline check no-ops and routing is byte-identical to before. Built
    /// once in `buildRouteCtx` from `outline.signedInset` (exact polygon when the
    /// board is non-rectangular, else the bounding rectangle).
    outline_mask: ?[]const bool = null,
    /// A second outline mask for the fixed perimeter-fence exclusion. Unlike
    /// `outline_mask`, this one is governed by the keepout's typed track block
    /// and per-net admissions, and its inner edge begins beyond the generated
    /// fence barrel. Keeping the masks separate preserves ordinary edge rules
    /// for an explicitly admitted net.
    perimeter_track_mask: ?[]const bool = null,
    /// Copper-edge inset for exact (including off-grid) via candidates in the
    /// typed perimeter band. Zero when the keepout does not block vias.
    perimeter_via_clearance: f64 = 0,
    /// Flattened-net admission map for the typed perimeter keepout. Empty means
    /// no net is admitted; generated perimeter vias remain exempt in the DRC.
    perimeter_allowed: []const bool = &.{},
    /// Per-net (flattened-net index) flag: this net has a pad legitimately off
    /// the board — a staging part parked in the DRC's staging band. Such a net
    /// is exempt from the outline mask wholesale (else it could never reach its
    /// own off-board pad); the board-edge DRC already skips staged copper.
    net_offboard: []const bool = &.{},
    reference_replayed: std.ArrayList(usize) = .empty,
    search_limited: std.ArrayList(usize) = .empty,
    /// Nonzero only while a post-greedy retry phase re-attempts a still-failed
    /// search-limited leg: `dijkstra` / `softProbe` then size that one leg's
    /// budget to this many node expansions (the `max_escalated_expansions`
    /// tier, or `max_last_resort_expansions` for the final retry). 0 leaves
    /// every leg on its bounded whole-board budget, so escalation stays local.
    escalate_budget: usize = 0,
    /// Reused by every real maze leg and by the rip-up blocker probe. Keeping
    /// this in the route context makes memory proportional to board size
    /// instead of terminal-search count.
    search: maze_scratch.Search = .{},
    route_queue: ?RoutePq = null,
    /// Optional per-phase wall-clock instrumentation (`route_policy.Options.timing`
    /// copied through `routeCoreStart`). Null (default) leaves every phase site
    /// a no-op null check; only `bench-route --breakdown` arms it.
    timing: ?*route_timing.PhaseTimer = null,
    /// Lazily-built spatial index over the CURRENT routed copper (boxes in
    /// `tracks` then `vias` order) for the direct-synthesis exact-clearance
    /// probes (`viaClearsTracks` / `viaClearsVias` / `viaClearsHoles` /
    /// `segClearsTracks` / `segClearsVias` / `finePointClear`). A superset
    /// prefilter only — the exact per-item distance test is unchanged — so
    /// routing output is identical with or without it. Rebuilt at every
    /// per-net attempt boundary and at each finish pass's per-net boundary
    /// (copper grows as routing proceeds, and rip-up / cleanup compaction
    /// shifts list indexes); null before the first rebuild or on a degenerate
    /// board, in which case the probes fall back to the legacy full linear
    /// scan. NEVER read directly — go through `copperIdx`, which also refuses
    /// it when `copper_gen` says a compaction has invalidated it.
    copper_index: ?*const PadGrid = null,
    /// The query reach every `nearSegment` probe expands its segment box by —
    /// the largest clearance any direct probe applies under the CURRENT net's
    /// geometry, so the candidate set is a superset of the items that could
    /// touch it. Restated by `setNetParams` (a wider net's probes must widen
    /// with it) as well as by `rebuildCopperIndex`.
    copper_reach: f64 = 0,
    /// Widest copper half-extent (track half-width / via radius) in the lists
    /// `copper_index` was built from. Kept so `setNetParams` can restate
    /// `copper_reach` for the incoming net in O(1) instead of rescanning the
    /// copper.
    copper_widest: f64 = 0,
    /// Number of track boxes `copper_index` was built with — the split point
    /// between its track and via box ranges. The copper lists grow between
    /// rebuilds (a net appends its own copper mid-attempt), so probes must
    /// map an index to a track vs via using the BUILD-time boundary, not the
    /// current list length.
    copper_track_count: usize = 0,
    /// Number of via boxes in the index. Vias appended during a net attempt are
    /// not indexed, so exact probes scan this tail explicitly.
    copper_via_count: usize = 0,
    /// Bumped by `copperCompacted` whenever the copper lists are REORDERED or
    /// SHRUNK — a cleanup compaction (`route_cleanup.removeNetTracks` packs
    /// survivors down), a straighten rewrite, a rip-up rollback. Every index
    /// the copper index holds then names a *different* track or via than it
    /// was built for: in range, and wrong. `copperIdx` refuses the index until
    /// a rebuild restamps it, so the probes fall back to their linear scan
    /// (same verdict, slower) instead of returning a false "clear".
    /// Appends deliberately do NOT bump: they only leave the index a subset,
    /// which every probe already tolerates.
    copper_gen: u64 = 0,
    /// The `copper_gen` value `copper_index` was built at. A mismatch means a
    /// compaction happened since, and the index is unusable.
    copper_index_gen: u64 = 0,
    /// Per-net exact-clearance probe budget (`clearDoglegSegment` /
    /// `directViaClear`). When exhausted, probes report "blocked" so the
    /// direct attempt fails fast and the net falls to the maze (which has its
    /// own expansion budget). Null (default) leaves probes unbounded — the
    /// legacy behaviour. Armed per non-escape direct attempt in
    /// `routeNetAttempt`; the maze's own `padGateways` never pays it.
    direct_budget: ?usize = null,
    /// Probe ceiling `escapeDirectRescue` arms here; null (every whole-board
    /// route) keeps its unbounded sweep. Set only by `routeWindowNet`.
    window_probe_budget: ?usize = null,
    /// Overlap-tolerant congestion pricing, armed ONLY inside the negotiated-
    /// congestion sandbox (`congestion.zig`) — where foreign copper a re-routable
    /// net owns is passable at a price instead of walling the maze out. Null
    /// everywhere else, which is what keeps every other route byte-identical.
    congest: ?*const congestion.Pricing = null,
    /// Why the shape tier last declined a net — reported per net at info level,
    /// so a tier that ran and found nothing is never indistinguishable from one
    /// that never ran.
    shape_verdict: ShapeVerdict = .not_tried,
};

/// How far outside the outline a pad's centre must sit for its net to count as
/// an off-board staging net (mirrors `drc.staging_exempt_mm` so the router and
/// the board-edge DRC agree on what "staged" means).
pub const staging_offboard_mm: f64 = 10.0;

/// True when node `n` is masked off by the board outline for `net` — i.e. a
/// track/via centred there would leave the board (or the copper-edge inset).
/// A net that owns an off-board staging pad is exempt wholesale, and a node
/// sitting on any real pad is never masked (pads are the optimizer's concern
/// and the board-edge DRC never flags them, so an edge-hugging pad can still
/// seed and connect).
pub fn outlineBlocked(ctx: *Ctx, n: usize, net: i32) bool {
    var staged_offboard = false;
    if (net >= 0) {
        const net_index: usize = @intCast(net);
        if (net_index < ctx.net_offboard.len) staged_offboard = ctx.net_offboard[net_index];
    }
    if (ctx.outline_mask) |mask| {
        if (!staged_offboard and n < mask.len) {
            if (mask[n] and !nodeOnAnyPad(ctx, n)) return true;
        }
    }
    if (!perimeterAllowed(ctx, net)) {
        if (ctx.perimeter_track_mask) |mask| {
            // A fixed construction keepout has no pad-landing carve-out. A part in
            // this band is itself a hard DRC failure and must move; silently
            // threading its trace through the band would defeat that guarantee.
            if (n < mask.len and mask[n]) return true;
        }
    }
    return false;
}

/// True when grid node `n`'s world point lies on (inside) any obstacle pad's
/// copper. Used only for masked (near/off-edge) nodes, which are rare, so the
/// linear scan is cheap. Keeps `outlineBlocked` from walling off a pad that
/// legitimately hugs the board edge.
fn nodeOnAnyPad(ctx: *Ctx, n: usize) bool {
    const grid = ctx.grid;
    const px = grid.worldX(n % grid.nx);
    const py = grid.worldY(n / grid.nx);
    for (ctx.obs) |p| if (px >= p.x0 and px <= p.x1 and py >= p.y0 and py <= p.y1) return true;
    return false;
}

/// True if node (layer, n) can't carry net `net`: copper of another net is
/// there, or (on top) a foreign pad is within clearance. A node sitting on the
/// net's *own* pad is always allowed (that's where the trace must connect).
/// Fold one pad `p` into the `on_own`/`foreign` accumulators for a node at
/// `(px, py)` carrying `net`. Extracted so the indexed and full-scan candidate
/// paths in `blocked` share the exact same distance test.
inline fn accumPad(ctx: *const Ctx, p: PadObs, layer: usize, px: f64, py: f64, net: i32, use_poly: bool, on_own: *bool, foreign: *bool) void {
    // A pad only blocks (or connects on) the layer its copper lives on;
    // through-hole pads exist on every layer.
    if (!p.thru and p.layer != layer) return;
    // Measure clearance against the pad's real copper outline only when asked
    // (the top-first pass): a concave thermal/EP pad over-states copper in its
    // box, walling off a corridor a short net could escape through — which is
    // exactly what buries a feedback tap beside an EP and forces it inner. The
    // outline test is costly, so the bulk maze keeps the cheap box distance.
    const lim = keepLimits(ctx, p.net, ctx.reach);
    const d = if (use_poly)
        pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, px, py, lim[1])
    else
        distPointRect(px, py, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1 });
    if (p.net == net) {
        if (d <= 1e-9) on_own.* = true;
    } else if (!keepout.approachClears(ctx.keep.zones, p.net, d, .{ px, py }, lim)) {
        foreign.* = true;
    }
}

/// True when node `(layer, n)` is unavailable to `net` — foreign copper or
/// reservation, an off-board / edge-inset node, a blocking zone/keepout, or a
/// foreign pad within clearance. The interactive frontier flood uses it as the
/// hard cost model so the snapshot matches what a real retry would see.
///
/// Foreign COPPER is the one wall the negotiated-congestion sandbox may lower
/// (`congestion.walls`: hard for every ordinary route, passable-at-a-price for a
/// net that sandbox can itself put back). A foreign RESERVATION stays hard even
/// there — a reserved lane is policy, and re-routing its owner would not free it.
pub fn blocked(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    if (ctx.pair_block) |mask| {
        if (mask[layer * (ctx.grid.nx * ctx.grid.ny) + n]) return true;
    }
    const o = ctx.occ[layer][n];
    if (o != empty_cell and o != net and congestion.walls(ctx.congest, o)) return true;
    const rv = ctx.resv[layer][n];
    if (rv != empty_cell and rv != net) return true;
    return keepoutBlocked(ctx, layer, n, net) or staticBlocked(ctx, layer, n, net);
}

/// The half of `blocked` that reads no copper: the board-edge inset, the
/// blocking zones/keepouts, and the foreign pads. For a fixed routing net (so a
/// fixed `ctx.reach`) this is a pure function of `(layer, n)` — the pads, zones
/// and outline are all static for a route — so it is the same answer every time
/// a node is re-tested.
fn staticBlockedUncached(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    if (outlineBlocked(ctx, n, net)) return true; // node off-board / inside the copper-edge inset
    const at = [2]f64{ ctx.grid.worldX(n % ctx.grid.nx), ctx.grid.worldY(n / ctx.grid.nx) };
    if (zoneBlocksPoint(ctx, layer, at, net, ctx.reach, false)) return true;
    return foreignPadAt(ctx, layer, n, net);
}

/// `staticBlockedUncached`, memoized through `ctx.static_block` when a caller
/// has armed it (`armStaticBlock`; every net change invalidates it through
/// `setNetParams`).
///
/// One gap hop re-runs the maze up to a dozen times — the direct attempt, a
/// blocker probe, then a rip candidate per tier — and a greedy/escalate/rip-up
/// pass re-searches the same nodes leg after leg. Each of those sweeps
/// re-derives the identical verdict for the same nodes: a polygon containment
/// plus an edge-distance per zone, then a pad-index scan. That recomputation,
/// not the graph search, is what makes a failing hop cost tens of seconds. The
/// memo makes it at most one evaluation per (layer, node) per net; because the
/// underlying predicate is pure for a fixed net, the routed result is identical.
pub fn staticBlocked(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    const k = layer * (ctx.grid.nx * ctx.grid.ny) + n;
    if (ctx.static_block.get(k)) |cached| return cached;
    const hit = staticBlockedUncached(ctx, layer, n, net);
    ctx.static_block.put(k, hit);
    return hit;
}

/// Allocate + arm the `staticBlocked` memo over this context's lattice.
pub fn armStaticBlock(ctx: *Ctx, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
    try ctx.static_block.arm(arena, ctx.occ.len * ctx.grid.nx * ctx.grid.ny);
}

/// True when a FOREIGN pad's copper sits within clearance of node `(layer, n)`
/// and the node isn't on the net's *own* pad — the physical-pad half of
/// `blocked`, split out. The rip-up blocker probe reuses it so a probe can
/// treat foreign *copper* as passable-at-a-penalty (a rip could clear it) while
/// still refusing to tunnel through a pad (which can never be ripped).
pub fn foreignPadAt(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    // All-top boards keep the old fast path: nothing on the bottom layer to hit.
    if (layer != 0 and !ctx.has_bottom_pads) return false;
    const px = ctx.grid.worldX(n % ctx.grid.nx);
    const py = ctx.grid.worldY(n / ctx.grid.nx);
    // Lazily build the spatial index the first time we test a node; the pad
    // set is static for the route so one build serves all queries.
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, gridBounds(ctx.grid), padIndexReach(ctx));
    var on_own = false;
    var foreign = false;
    if (ctx.pad_index) |idx| {
        for (idx.near(px, py)) |pi| accumPad(
            ctx,
            ctx.obs[pi],
            layer,
            px,
            py,
            net,
            ctx.use_poly,
            &on_own,
            &foreign,
        );
    } else {
        for (ctx.obs) |p| accumPad(ctx, p, layer, px, py, net, ctx.use_poly, &on_own, &foreign);
    }
    return foreign and !on_own;
}

const QItem = maze_scratch.QItem;
/// Rings the pad-gateway search fans outward — ~1.5 mm at the default pitch,
/// enough to clear a QFN pad collar plus the ground-via ring beside it.
pub const gate_rings: usize = 6;
/// The named outcomes of one net's shape attempt.
pub const ShapeVerdict = enum {
    not_tried,
    /// More than two terminals — the sequential-leg tier owns those.
    multi_terminal,
    /// The net's policy leaves it no layer to lay copper on.
    no_layer,
    /// The layered channel graph found no corridor on any allowed layer,
    /// through any legal via site. A geometry answer.
    no_channel,
    /// A path existed but the board refused its copper — an RF halo, a reserved
    /// lane, a zone, or the outline, none of which the shape mesh models.
    copper_refused,
    /// The copper landed but failed the DRC gate, so it was rolled back.
    drc_refused,
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");

// spec: placement/router - elevates only the switching hot loop above the baseline routing tier
test "netClassRank elevates switch-node and input-rail nets but no other class" {
    // The switching loop routes first…
    try testing.expectEqual(@as(u32, 1), netClassRank("SW")); // switch node
    try testing.expectEqual(@as(u32, 1), netClassRank("VIN")); // input rail
    // …everything else stays at the baseline tier — clock/RF/power/signal are
    // deliberately NOT reordered (a tradeoff the scalar routed metric can't judge).
    try testing.expectEqual(@as(u32, 0), netClassRank("SCLK")); // clock
    try testing.expectEqual(@as(u32, 0), netClassRank("DATA0")); // bulk signal
    try testing.expectEqual(@as(u32, 0), netClassRank("GND")); // ground (pass-1 anyway)
}

// spec: placement/router - lets authored (net-class (priority …)) dominate the intrinsic net-class rank
test "netPriority ranks the hot loop first yet keeps authored class priority dominant" {
    var idx = std.StringHashMapUnmanaged(usize).empty;
    defer idx.deinit(testing.allocator);
    try idx.put(testing.allocator, "U1", 0);
    try idx.put(testing.allocator, "C1", 1);

    const sw_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const sig_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const sw = FlatNet{ .name = "SW", .pins = &sw_pins };
    const sig = FlatNet{ .name = "DATA", .pins = &sig_pins };

    const base = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
    };

    // With no `(net-class … (priority …))`, the hot-loop net (index 0) outranks
    // the bulk signal (index 1).
    try testing.expect(netPriority(base, &idx, sw, 0) > netPriority(base, &idx, sig, 1));

    // Give the signal's net an authored class priority: explicit author intent
    // now wins, even though the hot loop still carries its intrinsic class bit.
    const rules = [_]optimizer.NetRule{ .{}, .{ .priority = 5 } }; // SW unranked, DATA tier 5
    var ranked = base;
    ranked.rules = .{ .net = &rules };
    try testing.expect(netPriority(ranked, &idx, sig, 1) > netPriority(ranked, &idx, sw, 0));
}

// spec: placement/router - auto-elevates a bare hub-to-inductor bridge net to the hot-loop tier
test "netPriority elevates a power-named hub-inductor bridge (VREG_LX) over a rail" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "L_VREG", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    var idx = std.StringHashMapUnmanaged(usize).empty;
    try idx.put(arena, "U1", 0);
    try idx.put(arena, "L_VREG", 1);
    try idx.put(arena, "C1", 2);

    // VREG_LX: hub pin + inductor pin only — the RP2350-style switch node whose
    // NAME classifies as a power rail (VREG prefix). Must still outrank a
    // many-pin rail like DVDD (hub + inductor + cap = the smoothed output).
    const lx_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L_VREG", .pin = "1" } };
    const rail_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "L_VREG", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const lx = FlatNet{ .name = "VREG_LX", .pins = &lx_pins };
    const rail = FlatNet{ .name = "DVDD", .pins = &rail_pins };

    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 4,
        .maxy = 0,
        .generated = true,
    };
    try testing.expect(netPriority(placement, &idx, lx, 0) > netPriority(placement, &idx, rail, 1));
}

// spec: placement/router - an escape-constrained pad exits straight for the declared distance before its first bend
test "segSegDist returns zero for a proper crossing away from the origin" {
    // Two unit diagonals crossing at (1.5,1.5); the intersection parameter's
    // numerator must read b1−a1 (not b1+a1), or the crossing is missed and a
    // positive endpoint distance is returned instead of 0.
    try testing.expectEqual(@as(f64, 0), segSegDist(.{ 1, 1 }, .{ 2, 2 }, .{ 1, 2 }, .{ 2, 1 }));
}

test "copperHalo sums via radius, half track, and clearance under the sqrt" {
    var ctx = Ctx{
        .arena = testing.allocator,
        .grid = .{ .ox = 0, .oy = 0, .g = 1.0, .nx = 1, .ny = 1 },
        .obs = &.{},
        .reach = 0,
        .occ = &.{},
        .resv = &.{},
        .params = .{ .via_dia = 0.8, .track_width = 0.2, .clearance = 0.3 },
    };
    // d = viaR + track_width/2 + clearance = 0.4 + 0.1 + 0.3 = 0.8;
    // halo = √(d² + g²·0.5) = √(0.64 + 0.5) = √1.14. Any +→− flip changes d.
    try testing.expectApproxEqAbs(@as(f64, @sqrt(1.14)), copperHalo(&ctx), 1e-9);
}

test "via occupancy keeps legal neighboring via outside one physical halo" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 30, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2536,
        .occ = try allocLayerGrids(arena, 2, nodes),
        .resv = try allocLayerGrids(arena, 2, nodes),
        .params = .{ .via_dia = 0.4, .track_width = 0.2532, .clearance = 0.127 },
        .base = .{},
        .index_reach = 0.2536,
    };
    stampViaOcc(&ctx, 1.0, 1.0, 0);
    const halo_cell = grid.node(14, 10);
    try testing.expectEqual(empty_cell, ctx.occ[0][halo_cell]);
    try testing.expectEqual(@as(i32, 0), ctx.resv[0][halo_cell]);
    try testing.expect(!viaAllowed(&ctx, grid.node(15, 10), 1, &.{}));
    try testing.expect(viaAllowed(&ctx, grid.node(16, 10), 1, &.{}));
}

// spec: placement/router - a gap-pass via site counts its clearance from already-inflated foreign copper once, not twice
test "a gap-pass via site clears stamped foreign copper by the physical distance only" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 40, .ny = 40 };
    const nodes = grid.nx * grid.ny;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = try allocLayerGrids(arena, 2, nodes),
        .resv = try allocLayerGrids(arena, 2, nodes),
        .params = .{ .via_dia = 0.4, .track_width = 0.2, .clearance = 0.2 },
        .base = .{},
        .index_reach = 0.2,
    };
    // Arm the gap pass's exact mode, then stamp a foreign net-1 track along
    // y = 1.0. A net-0 via (radius 0.2) must keep viaR + width/2 + clearance
    // = 0.2 + 0.1 + 0.2 = 0.5 mm from that centreline — and no more.
    ctx.exact = .{ .near = try arena.alloc(bool, ctx.occ.len * nodes) };
    const foreign = [_]Track{
        .{ .x1 = 0.5, .y1 = 1.0, .x2 = 3.0, .y2 = 1.0, .layer = 0, .width = 0.2, .net = 1 },
    };
    stampBoardCopper(&ctx, &foreign, &.{}, 0);
    // 0.4 mm off the centreline is inside the physical clearance — still refused.
    try testing.expect(!viaAllowed(&ctx, grid.node(17, 14), 0, &.{}));
    // 0.7 mm off it clears by 0.2 mm. Re-expanding the stamp by a second full
    // via halo would refuse this site out past 0.9 mm.
    try testing.expect(viaAllowed(&ctx, grid.node(17, 17), 0, &.{}));
}

// spec: placement/router - a foreign net's pad landing carved out of a keepout halo is keyed to that pad's net, so no other net threads it
test "a keepout halo's pad-landing opening admits only that pad's net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Net 0 is the RF net (0.5 mm halo); net 1 owns a pad sitting inside that
    // halo, and net 2 is a passer-by with nothing there.
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 120, .ny = 120 };
    const pads = [_]PadObs{.{ .x0 = 5.9, .y0 = 5.2, .x1 = 6.1, .y1 = 5.4, .net = 1 }};
    const halos = [_]f64{ 0.5, 0, 0 };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .occ = &.{},
        .resv = &.{},
        .obs = &pads,
        .reach = 0.19,
        .params = .{},
        .base = .{},
    };
    ctx.index_reach = 0.19;
    ctx.keep.nets = &halos;
    ctx.keep.layers = try allocLayerGrids(arena, 1, grid.nx * grid.ny);
    ctx.keep.gate = try allocLayerGrids(arena, 1, grid.nx * grid.ny);
    ctx.keep.halo = 0.5;
    stampKeepoutSeg(&ctx, .{ 2, 5 }, .{ 10, 5 }, keepStamp(&ctx, 0, 0, 0.0635));

    // A node in the pad's clearance landing but off its copper: the opening is
    // there so net 1 can escape its own pad, and it admits nobody else.
    const landing = grid.node(60, 51);
    try testing.expect(!keepoutBlocked(&ctx, 0, landing, 1));
    try testing.expect(keepoutBlocked(&ctx, 0, landing, 2));
    // Plain halo well away from the pad is shut to both, and open to its owner.
    const plain = grid.node(40, 53);
    try testing.expect(keepoutBlocked(&ctx, 0, plain, 1));
    try testing.expect(keepoutBlocked(&ctx, 0, plain, 2));
    try testing.expect(!keepoutBlocked(&ctx, 0, plain, 0));
}
