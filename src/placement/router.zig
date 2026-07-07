//! In-tool grid maze (Dijkstra) autorouter — a first, deliberately simple cut.
//!
//! Stackup is 4-layer: top signal, GND plane, PWR plane, bottom signal. Ground
//! nets are connected to the GND plane with a via at each pad (no surface
//! trace). Every other multi-pad net is routed as real copper on the two
//! signal layers (top + bottom), switching layers through vias when a layer is
//! blocked. The board is rasterised to a grid whose pitch is `track_width +
//! clearance`, so two traces on adjacent grid lines satisfy the spacing rule;
//! pads of other nets (plus the board edge and already-routed copper) are
//! obstacles. Each net's pads are joined incrementally (route pad → the net's
//! routed-so-far set), i.e. a maze-routed tree.
//!
//! This is a maze router, not a commercial one: it routes nets in order with
//! no rip-up, so congested boards can leave nets unrouted (counted in
//! `RouteResult.routed`/`total`, named in `RouteResult.failed`). It's aimed at
//! module-scale boards. Coordinates are millimetres, y-down (KiCad convention).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const module_policy = @import("module_policy.zig");
const pad_shape = @import("pad_shape.zig");
const geometry = @import("geometry.zig");
const export_kicad = @import("../export_kicad.zig");

const Part = optimizer.Part;
const FlatNet = export_kicad.FlatNet;

/// Design-rule inputs for routing (millimetres). Defaults are conservative
/// proto-fab capabilities; the page lets the user override them.
pub const RouteParams = struct {
    track_width: f64 = 0.127, // 5 mil
    clearance: f64 = 0.127, // 5 mil
    via_drill: f64 = 0.2,
    via_dia: f64 = 0.4,
};

/// A pad as a routing obstacle: its world bounding box, its real copper outline
/// (`poly`; empty ⇒ the box is exact), the net it belongs to, and the signal
/// layer its copper lives on (`layer` 0 = top, 1 = bottom — the placed part's
/// side; `thru` pads exist on BOTH layers). The maze pass rasterises the box;
/// the clearance checks measure against the outline.
pub const PadObs = struct { x0: f64, y0: f64, x1: f64, y1: f64, poly: []const [2]f64 = &.{}, net: i32, layer: u8 = 0, thru: bool = false };

/// Signal-layer index a part's SMD pads live on (0 = top, 1 = bottom).
fn sideLayer(part: Part) u8 {
    return if (part.side == .bottom) 1 else 0;
}

/// True when any obstacle pad has copper on the bottom signal layer (a
/// bottom-side part, or a through-hole pad reaching every layer).
fn anyBottomPads(obs: []const PadObs) bool {
    for (obs) |p| {
        if (p.layer == 1 or p.thru) return true;
    }
    return false;
}

/// A routed copper segment. `layer` 0 = top, 1 = bottom signal. `net` is the
/// flattened-net index it carries (for the design-rule check).
pub const Track = struct { x1: f64, y1: f64, x2: f64, y2: f64, layer: u8, width: f64, net: i32 };

/// A via (drawn as the pad ring; spans the layers it connects). `net` is the
/// flattened-net index it belongs to (for the design-rule check); `drill` is
/// the hole diameter (0 on legacy/synthetic vias — the annular-ring DRC then
/// skips it).
pub const Via = struct { x: f64, y: f64, dia: f64, net: i32, drill: f64 = 0 };

/// Router output: the copper, how many nets routed of the total tried, and the
/// names of the nets that failed (`failed.len == total - routed`) — so callers
/// can say *which* connections are missing, not just how many.
pub const RouteResult = struct {
    tracks: []const Track,
    vias: []const Via,
    routed: usize,
    total: usize,
    failed: []const []const u8 = &.{},
    /// True when the board was too large to grid at all (`MAX_NODES`
    /// exceeded) and the router returned WITHOUT attempting any net — so
    /// callers can tell "nothing needed routing" apart from "the grid bailed"
    /// instead of silently showing an empty route.
    grid_overflow: bool = false,
    /// How many bounded rip-up-&-reroute rounds ran after the greedy pass
    /// (0 = none needed / the greedy pass already routed everything, or the
    /// grid overflowed). Surfaced in the route-summary JSON so a caller can see
    /// the router did more than one pass.
    ripup_rounds: usize = 0,
};

/// Largest grid (nodes per SIGNAL LAYER) the router will attempt — keeps a
/// huge board from allocating an enormous grid; modules stay far under this.
/// Total node count scales with the stackup's signal-layer count (the cap is
/// per layer), and a bail is reported via `RouteResult.grid_overflow`.
const MAX_NODES: usize = 200_000;
const EMPTY: i32 = -1;
const VIA_COST_MULT: f64 = 4.0; // a layer change costs ~4 grid steps
/// Nets with at most this many pads get the top-layer-first attempt (feedback
/// taps, straps, short two/three-pad signals). Fat nets skip it — see pass 2.
const TOP_FIRST_MAX_PADS: usize = 4;
/// Top-layer-first runs only on boards no larger than this. Bigger boards are
/// dense enough that forcing short nets onto the surface costs more (slow failed
/// searches) than it saves and disturbs the routing of other nets — see pass 2.
const TOP_FIRST_MAX_PARTS: usize = 32;
/// Return-path stitching runs only on boards no larger than this. The pass is
/// purely additive (it can't disturb existing routing), but it runs a via search
/// per unstitched signal via, so a huge board's already-long route is left alone.
const STITCH_MAX_PARTS: usize = 48;
const SQRT2: f64 = 1.4142135623730951; // diagonal step length vs. orthogonal
/// Step-cost multiplier for maze moves onto an outer layer a declared pour
/// covers: every signal trace there slices the pour into islands, so signals
/// prefer the un-poured face — but the layer stays usable when the other side
/// is walled off (the Gerber emission carves clearance around whatever lands
/// there, so the result is legal either way).
const POUR_COST_MULT: f64 = 1.5;
/// Step-cost multiplier for maze moves on an INNER signal layer (index ≥ 2,
/// from a `(stackup …)` with more than two plane-free copper layers). Kept
/// mild: an inner dive already pays two via costs, so this only breaks the
/// tie against equal-length inner paths — a trivially routable board keeps
/// all its copper on the outer faces (identical to the 2-layer result), while
/// a congested crossing still dives inner the moment the surface detour
/// exceeds ~25% of the path. No-op on ≤2-signal boards (no such layer exists).
const INNER_COST_MULT: f64 = 1.25;

/// Pass 1 of `route`: ground/plane nets. Each pad of a plane-carrying net
/// drops a via to its plane — except pads already sitting IN an outer-layer
/// pour of their own net (same-face SMD, or any through-hole barrel), which
/// the pour connects directly. The via is placed where it keeps full
/// via-clearance from every *foreign* pad (and any via already down) —
/// preferring the pad centre, else fanning outward into open copper and
/// joining it with a short same-net stub, so the via can't crowd a
/// neighbouring pad (the classic DFN/QFN via-in-pad fail). Each placed via's
/// clearance halo is stamped into the routing grid on *both* signal layers,
/// so the maze pass routes foreign copper around it. On a plane-less stackup
/// NOTHING gets via drops — every net (ground included) falls through to the
/// maze pass.
fn planeViaPass(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMap(usize),
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
    routed: *usize,
    total: *usize,
    failed: *std.ArrayListUnmanaged([]const u8),
) std.mem.Allocator.Error!void {
    const arena = ctx.arena;
    for (placement.nets, 0..) |net, net_i| {
        // Hoisted above netPoints so we don't allocate + look up pads for
        // every non-plane net just to skip it.
        if (!netHasPlane(placement, net.name)) continue;
        const pts = try netPoints(arena, placement, idx_of, net);
        if (pts.len < 2) continue;
        total.* += 1;
        const ni: i32 = @intCast(net_i);
        setNetParams(ctx, placement, net_i);
        const pour = netPourLayers(placement, net.name);
        var placed_any = false;
        var needed_any = false;
        for (pts) |c| {
            // A pad whose copper already reaches an outer-layer pour of its
            // own net sits IN the pour (same-face SMD pad, or a through-hole
            // barrel meeting the pour on either face) — a via stitches nothing.
            if (padInPour(pour, c)) continue;
            needed_any = true;
            const cc = [2]f64{ c.x, c.y };
            const pos = findGroundVia(ctx, vias.items, cc, ni) orelse continue;
            placed_any = true;
            try vias.append(arena, .{ .x = pos[0], .y = pos[1], .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = ni });
            if (@abs(pos[0] - c.x) > 1e-6 or @abs(pos[1] - c.y) > 1e-6) {
                try tracks.append(arena, .{ .x1 = c.x, .y1 = c.y, .x2 = pos[0], .y2 = pos[1], .layer = c.layer, .width = ctx.params.track_width, .net = ni });
                stampStubOcc(ctx, cc, pos, ni, c.layer);
            }
            stampViaOcc(ctx, pos[0], pos[1], ni);
        }
        // Only count the net routed if at least one plane via actually
        // dropped — a fully hemmed-in ground net must not inflate
        // routed/total and hide the hand-fix from fullRouteCost's unrouted
        // term. A net whose EVERY pad lands in an outer pour needs no via at
        // all: the pour itself is the connection, so it counts routed.
        if (placed_any or !needed_any) routed.* += 1 else try failed.append(arena, net.name);
    }
}

/// Pass 2's greedy first-routed-wins loop, factored out of `route`. Routes each
/// maze net in `order` (already priority-sorted): short single-layer nets get a
/// top-layer-first attempt (rolled back if it fails), then the plain via-allowed
/// maze route. Every net's outcome is appended to `routable` (the rip-up working
/// set) and `total` is bumped per attempted net. No `routed`/`failed` tally here
/// — that happens after rip-up so re-routed nets count correctly.
fn greedyPass(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMap(usize),
    order: []const usize,
    net_pri: []const u32,
    top_first: bool,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
    total: *usize,
    routable: *std.ArrayListUnmanaged(RipNet),
) std.mem.Allocator.Error!void {
    const arena = ctx.arena;
    for (order) |net_i| {
        const pts = try netPoints(arena, placement, idx_of, placement.nets[net_i]);
        if (pts.len < 2) continue;
        total.* += 1;
        const ni: i32 = @intCast(net_i);
        setNetParams(ctx, placement, net_i);
        // Top-layer-first only for *short* single-layer nets (a feedback tap, a
        // strap — a handful of pads), which almost always have a clear surface
        // path. A short net with no top path rolls back and re-routes with layer
        // changes. A net whose pads straddle both board sides needs a via by
        // definition, so it skips the no-via attempt outright.
        const one_layer = blk: {
            for (pts[1..]) |q| {
                if (q.layer != pts[0].layer) break :blk false;
            }
            break :blk true;
        };
        var ok = false;
        if (top_first and one_layer and pts.len <= TOP_FIRST_MAX_PADS) {
            const t_mark = tracks.items.len;
            const v_mark = vias.items.len;
            ctx.allow_vias = false;
            ctx.use_poly = true; // accurate outlines so an EP notch frees the escape
            const top_ok = try routeNet(ctx, ni, pts, tracks, vias);
            ctx.allow_vias = true;
            ctx.use_poly = false;
            if (top_ok) {
                ok = true;
            } else {
                tracks.shrinkRetainingCapacity(t_mark);
                vias.shrinkRetainingCapacity(v_mark);
                clearNetOcc(ctx, ni);
            }
        }
        if (!ok) ok = try routeNet(ctx, ni, pts, tracks, vias);
        try routable.append(arena, .{ .net_i = net_i, .pri = net_pri[net_i], .ok = ok });
    }
}

/// Route `placement` under `params`. All output is allocated in `arena`.
pub fn route(arena: std.mem.Allocator, placement: optimizer.Placement, params: RouteParams) std.mem.Allocator.Error!RouteResult {
    var tracks: std.ArrayListUnmanaged(Track) = .empty;
    var vias: std.ArrayListUnmanaged(Via) = .empty;
    var failed: std.ArrayListUnmanaged([]const u8) = .empty;

    // ref-des → part index, for resolving each net pin to a pad.
    var idx_of = std.StringHashMap(usize).init(arena);
    for (placement.parts, 0..) |p, i| try idx_of.put(p.ref_des, i);

    // Grid pitch sized to the WIDEST class on the board, so adjacent occupied
    // grid lines satisfy clearance even between the widest pair of nets.
    // No (net-class …) forms ⇒ maxp == params ⇒ the legacy grid, unchanged.
    const maxp = maxRouteParams(placement, params);
    const g = @max(maxp.track_width + maxp.clearance, 0.05);
    const margin = 1.0;
    const ox = placement.minx - margin;
    const oy = placement.miny - margin;
    const nx: usize = @intFromFloat(@ceil((placement.maxx - placement.minx + 2 * margin) / g) + 1);
    const ny: usize = @intFromFloat(@ceil((placement.maxy - placement.miny + 2 * margin) / g) + 1);
    if (nx * ny == 0 or nx * ny > MAX_NODES) {
        return .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0, .grid_overflow = nx * ny > MAX_NODES };
    }
    const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

    // Routed-copper occupancy per SIGNAL layer (one net per grid line ⇒
    // adjacent lines are track+clearance apart, satisfying trace-to-trace
    // DRC). The layer count comes from the stackup: the two outer faces plus
    // every plane-free inner copper layer (legacy no-form boards stay at 2).
    const n_signal: usize = placement.rules.signalLayerCount();
    const occ = try allocLayerGrids(arena, n_signal, nx * ny);
    // Diagonal corner reservations (see `emitPath`) — cells no foreign copper
    // may enter, but which are NOT the net's own copper (never Dijkstra sources).
    const resv = try allocLayerGrids(arena, n_signal, nx * ny);

    // Pad obstacles: *every* pad's rectangle + its net — including pads on no
    // net (net −1), so a via/trace keeps clearance from NC/mechanical pads too.
    // Mirrors `drc.zig`'s pad set exactly, so what the router avoids is exactly
    // what the DRC checks.
    const obs = try buildObstacles(arena, placement.parts, placement.nets);

    // Route each net. Ground → plane vias; others → maze on the signal layers.
    const reach = params.track_width / 2 + params.clearance;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = obs,
        .reach = reach,
        .occ = occ,
        .resv = resv,
        .params = params,
        .base = params,
        .index_reach = maxp.track_width / 2 + maxp.clearance,
        .has_bottom_pads = anyBottomPads(obs),
        .pour = .{
            placement.rules.pourNetOnSide(.top) != null,
            placement.rules.pourNetOnSide(.bottom) != null,
        },
    };
    var routed: usize = 0;
    var total: usize = 0;

    // Pass 1: ground/plane nets — see `planeViaPass`.
    try planeViaPass(&ctx, placement, &idx_of, &tracks, &vias, &routed, &total, &failed);

    // Pass 2: every other multi-pad net, maze-routed on the two signal layers,
    // now detouring the ground vias stamped in pass 1. Nets are routed in
    // authored `(net-class … (priority N))` order (highest first) so a critical
    // net claims the short path before a bulk rail can block it — the router
    // has no rip-up, so first-routed wins. Within a priority tier the switching
    // hot loop (switch-node / input-rail nets, plus a bare hub→inductor bridge)
    // routes ahead of the pack even when the author declared no class.
    // Remaining ties keep net order.
    const net_pri = try arena.alloc(u32, placement.nets.len);
    for (placement.nets, 0..) |net, i| net_pri[i] = netPriority(placement, &idx_of, net, i);
    var order: std.ArrayListUnmanaged(usize) = .empty;
    for (placement.nets, 0..) |net, net_i| {
        if (netHasPlane(placement, net.name)) continue;
        try order.append(arena, net_i);
    }
    std.sort.pdq(usize, order.items, net_pri, priorityDesc);
    // Top-layer-first only on small boards. There it keeps short signal nets on
    // the surface (no needless vias) with room to spare. On a big, congested
    // board it backfires: most top-only attempts fail after an exhaustive (and,
    // with the outline test, slow) surface search, and the few that succeed shift
    // the greedy first-come routing enough to strand other nets — so we skip it
    // and route exactly as before. Mirrors the routed-scoring part gate.
    const top_first = placement.parts.len <= TOP_FIRST_MAX_PARTS;
    // Greedy first-routed-wins pass. Every maze net's outcome lands in
    // `routable` (priority order) — the working set the bounded rip-up pass then
    // revisits. `routed`/`failed` are tallied from it *after* rip-up, so a net
    // re-routed by a rip counts correctly.
    var routable: std.ArrayListUnmanaged(RipNet) = .empty;
    try greedyPass(&ctx, placement, &idx_of, order.items, net_pri, top_first, &tracks, &vias, &total, &routable);

    // Bounded rip-up & reroute: give each still-failed net a chance to displace
    // no-higher-priority copper that boxes it in (see `ripUpReroute`). The
    // grid-overflow case already returned early above, so this only runs on a
    // real grid. Then tally `routed`/`failed` from the (possibly rip-updated)
    // working set — plane nets were already counted in pass 1.
    var ripup_rounds: usize = 0;
    if (anyFailed(routable.items))
        ripup_rounds = try ripUpReroute(&ctx, placement, &idx_of, routable.items, &tracks, &vias);
    for (routable.items) |rn| {
        if (rn.ok) routed += 1 else try failed.append(arena, placement.nets[rn.net_i].name);
    }

    // Escape breakouts: the optimizer reserved a corridor in front of every
    // single-pin signal pad. The pad has nothing to connect to on this board, so
    // rather than a long surface trace to nowhere the breakout escapes to an
    // inner layer the way you'd hand-route it — `findEscapeVia` fans outward
    // (preferring the reserved heading) to the nearest DRC-safe via spot, and we
    // route a short trace from the pad to that via. When the pad is too hemmed in
    // for any DRC-safe via, fall back to the trimmed surface stub so a blocked
    // breakout still has some copper leaving the part.
    for (placement.stubs) |st| {
        const part = placement.parts[st.part];
        if (st.net >= 0) setNetParams(&ctx, placement, @intCast(st.net));
        const lay = sideLayer(part);
        const a = optimizer.worldPadCenter(part, st.ax, st.ay);
        const b = optimizer.worldPadCenter(part, st.bx, st.by);
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const dl = std.math.hypot(dx, dy);
        const dir: [2]f64 = if (dl > 1e-9) .{ dx / dl, dy / dl } else .{ 1, 0 };
        if (findEscapeVia(&ctx, vias.items, tracks.items, a, dir, st.net, lay)) |vp| {
            try tracks.append(arena, .{ .x1 = a[0], .y1 = a[1], .x2 = vp[0], .y2 = vp[1], .layer = lay, .width = ctx.params.track_width, .net = st.net });
            try vias.append(arena, .{ .x = vp[0], .y = vp[1], .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = st.net });
            continue;
        }
        // Too hemmed in for any DRC-safe via — fall back to the trimmed surface
        // stub, snapped to the nearest 45° heading so even the fallback copper
        // keeps the octilinear discipline.
        const bs = snap45(a, b);
        const end = trimStub(&ctx, vias.items, tracks.items, a, bs, st.net, lay);
        if (@abs(end[0] - a[0]) < 1e-6 and @abs(end[1] - a[1]) < 1e-6) continue;
        try tracks.append(arena, .{ .x1 = a[0], .y1 = a[1], .x2 = end[0], .y2 = end[1], .layer = lay, .width = ctx.params.track_width, .net = st.net });
    }

    // Return-path stitching. A signal via that swaps reference planes needs a GND
    // via beside it so its return current can follow across the plane gap — without
    // one the return takes a long detour and the loop (and EMI) blows up; that's
    // the `returnPathViolations` warning. For every signal via with no ground via
    // within `RETURN_PATH_RADIUS_MM`, drop a GND plane stitch via at the nearest
    // DRC-safe spot inside that radius (no stub — a plane via needs none). Purely
    // additive: it only appends GND vias, so no existing copper moves. A via that
    // can't be stitched (no DRC-safe room) simply stays flagged. Gated to modest
    // boards so a big board's route doesn't grow a search per signal via.
    if (placement.parts.len <= STITCH_MAX_PARTS) {
        if (firstGroundNet(placement)) |gnet| {
            setNetParams(&ctx, placement, @intCast(gnet));
            const n_before = vias.items.len;
            for (0..n_before) |i| {
                const v = vias.items[i];
                if (isGndVia(placement, v.net)) continue; // already a ground/plane via
                var stitched = false;
                for (vias.items) |gv| {
                    if (!isGndVia(placement, gv.net)) continue;
                    if (std.math.hypot(v.x - gv.x, v.y - gv.y) <= RETURN_PATH_RADIUS_MM) {
                        stitched = true;
                        break;
                    }
                }
                if (stitched) continue;
                const pos = findStitchVia(&ctx, vias.items, tracks.items, .{ v.x, v.y }, gnet, RETURN_PATH_RADIUS_MM) orelse continue;
                try vias.append(arena, .{ .x = pos[0], .y = pos[1], .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = gnet });
                stampViaOcc(&ctx, pos[0], pos[1], gnet);
            }
        }
    }

    return .{
        .tracks = try tracks.toOwnedSlice(arena),
        .vias = try vias.toOwnedSlice(arena),
        .routed = routed,
        .total = total,
        .failed = try failed.toOwnedSlice(arena),
        .ripup_rounds = ripup_rounds,
    };
}

/// The DRC-safe GND-plane vias only — `route`'s pass 1 run in isolation. One via
/// per ground pad, placed (via `findGroundVia`) to clear every foreign pad and
/// any via already down, in the same net order and with the same grid as `route`,
/// so each via lands at *exactly* the spot `route` would drop it. The layout view
/// draws these as the pre-routing GND vias, so the via shown before routing is the
/// one routing will use — no "preview via at the pad centre + real DRC via beside
/// it" doubling, and the previewed via always meets clearance. Returns empty when
/// the grid is too large to build (callers fall back to the raw pad centre).
/// MUST stay in lockstep with `route`'s grid setup + pass-1 loop above.
pub fn groundVias(arena: std.mem.Allocator, placement: optimizer.Placement, params: RouteParams) std.mem.Allocator.Error![]Via {
    var vias: std.ArrayListUnmanaged(Via) = .empty;
    var idx_of = std.StringHashMap(usize).init(arena);
    for (placement.parts, 0..) |p, i| try idx_of.put(p.ref_des, i);

    // Same max-class pitch as `route` (MUST stay in lockstep — see doc above).
    const gmaxp = maxRouteParams(placement, params);
    const g = @max(gmaxp.track_width + gmaxp.clearance, 0.05);
    const margin = 1.0;
    const ox = placement.minx - margin;
    const oy = placement.miny - margin;
    const nx: usize = @intFromFloat(@ceil((placement.maxx - placement.minx + 2 * margin) / g) + 1);
    const ny: usize = @intFromFloat(@ceil((placement.maxy - placement.miny + 2 * margin) / g) + 1);
    if (nx * ny == 0 or nx * ny > MAX_NODES) return &.{};
    const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

    const n_signal: usize = placement.rules.signalLayerCount();
    const occ = try allocLayerGrids(arena, n_signal, nx * ny);
    const resv = try allocLayerGrids(arena, n_signal, nx * ny);
    const obs = try buildObstacles(arena, placement.parts, placement.nets);
    const reach = params.track_width / 2 + params.clearance;
    const maxp = maxRouteParams(placement, params);
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = obs,
        .reach = reach,
        .occ = occ,
        .resv = resv,
        .params = params,
        .base = params,
        .index_reach = maxp.track_width / 2 + maxp.clearance,
        .has_bottom_pads = anyBottomPads(obs),
    };

    for (placement.nets, 0..) |net, net_i| {
        // Plane filter hoisted above netPoints, in lockstep with `route`.
        if (!netHasPlane(placement, net.name)) continue;
        const pts = try netPoints(arena, placement, &idx_of, net);
        if (pts.len < 2) continue;
        const ni: i32 = @intCast(net_i);
        setNetParams(&ctx, placement, net_i);
        const pour = netPourLayers(placement, net.name);
        for (pts) |c| {
            // Same skip as `route`'s pass 1: a pad already sitting in an
            // outer-layer pour of its own net previews no via.
            if (padInPour(pour, c)) continue;
            const cc = [2]f64{ c.x, c.y };
            const pos = findGroundVia(&ctx, vias.items, cc, ni) orelse continue;
            try vias.append(arena, .{ .x = pos[0], .y = pos[1], .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = ni });
            // Stamp the same occupancy `route` would, so the *next* via avoids this
            // one identically (the via positions depend on placement order).
            if (@abs(pos[0] - c.x) > 1e-6 or @abs(pos[1] - c.y) > 1e-6) stampStubOcc(&ctx, cc, pos, ni, c.layer);
            stampViaOcc(&ctx, pos[0], pos[1], ni);
        }
    }
    return vias.toOwnedSlice(arena);
}

/// A reusable maze-router context over a *fixed* set of placed parts: the grid
/// and pad-obstacle list are built once, then individual two-pad legs are routed
/// against it. The placement optimizer's score path uses this to measure each
/// decoupling loop's *real* trace length (cap pad → its pinned hub pin), instead
/// of a straight-line ratline — a foreign pad in the way makes the trace (and so
/// the score) genuinely longer. Cheap enough for the score path (one build + a
/// Dijkstra per loop); never use it in the optimizer's inner loop.
pub const LoopRouter = struct {
    ctx: Ctx,
    /// False when the board couldn't be gridded (degenerate/oversize) — callers
    /// fall back to the analytic surrogate.
    ready: bool,

    pub fn init(
        arena: std.mem.Allocator,
        parts: []const Part,
        nets: []const FlatNet,
        idx_of: *std.StringHashMap(usize),
        params: RouteParams,
    ) std.mem.Allocator.Error!LoopRouter {
        _ = idx_of; // obstacles are built straight off `parts` now
        // Bounding box over part courtyards (pads live inside), rotation-aware,
        // then the same grid pitch + 1 mm margin `route` uses.
        var minx: f64 = std.math.inf(f64);
        var miny: f64 = std.math.inf(f64);
        var maxx: f64 = -std.math.inf(f64);
        var maxy: f64 = -std.math.inf(f64);
        for (parts) |p| {
            const q = @mod(@round(p.rot), 360);
            const quarter = (q == 90 or q == 270);
            const ehw = if (quarter) p.hh else p.hw;
            const ehh = if (quarter) p.hw else p.hh;
            minx = @min(minx, p.x - ehw);
            miny = @min(miny, p.y - ehh);
            maxx = @max(maxx, p.x + ehw);
            maxy = @max(maxy, p.y + ehh);
        }
        if (!std.math.isFinite(minx)) return .{ .ctx = undefined, .ready = false };

        const g = @max(params.track_width + params.clearance, 0.05);
        const margin = 1.0;
        const ox = minx - margin;
        const oy = miny - margin;
        const nx: usize = @intFromFloat(@ceil((maxx - minx + 2 * margin) / g) + 1);
        const ny: usize = @intFromFloat(@ceil((maxy - miny + 2 * margin) / g) + 1);
        if (nx * ny == 0 or nx * ny > MAX_NODES) return .{ .ctx = undefined, .ready = false };
        const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

        // The loop surrogate always measures on the two OUTER faces — it
        // scores a decoupling leg, not a full route, so inner layers would
        // only slow the placement loop without changing the ordering.
        const occ = try allocLayerGrids(arena, 2, nx * ny);
        const resv = try allocLayerGrids(arena, 2, nx * ny);

        // Every pad is an obstacle tagged with its net — same indexing as `route`
        // (absolute position in `nets`), so a leg routed on net N treats N's pads
        // as passable (its own copper) and all others as obstacles to detour.
        const obs = try buildObstacles(arena, parts, nets);

        const reach = params.track_width / 2 + params.clearance;
        return .{
            .ctx = .{
                .arena = arena,
                .grid = grid,
                .obs = obs,
                .reach = reach,
                .occ = occ,
                .resv = resv,
                .params = params,
                .base = params,
                .index_reach = reach,
                .has_bottom_pads = anyBottomPads(obs),
            },
            .ready = true,
        };
    }

    /// Real routed copper length (mm) from world point `cap_c` to `hub_c` on net
    /// `net_id` (their shared rail), detouring foreign pads. Null when the maze
    /// can't connect them (boxed in) or the router isn't ready.
    pub fn legLen(self: *LoopRouter, cap_c: [2]f64, hub_c: [2]f64, net_id: i32) std.mem.Allocator.Error!?f64 {
        if (!self.ready or net_id < 0) return null;
        for (self.ctx.occ) |l| @memset(l, EMPTY);
        for (self.ctx.resv) |l| @memset(l, EMPTY);
        var tracks: std.ArrayListUnmanaged(Track) = .empty;
        var vias: std.ArrayListUnmanaged(Via) = .empty;
        const pts = [_]NetPt{
            .{ .x = cap_c[0], .y = cap_c[1], .layer = 0 },
            .{ .x = hub_c[0], .y = hub_c[1], .layer = 0 },
        };
        if (!try routeNet(&self.ctx, net_id, &pts, &tracks, &vias)) return null;
        var len: f64 = 0;
        for (tracks.items) |t| len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        return len;
    }
};

// ── Grid + helpers ─────────────────────────────────────────────────────────

const Grid = struct {
    ox: f64,
    oy: f64,
    g: f64,
    nx: usize,
    ny: usize,

    fn node(self: Grid, ix: usize, iy: usize) usize {
        return iy * self.nx + ix;
    }
    fn worldX(self: Grid, ix: usize) f64 {
        return self.ox + @as(f64, @floatFromInt(ix)) * self.g;
    }
    fn worldY(self: Grid, iy: usize) f64 {
        return self.oy + @as(f64, @floatFromInt(iy)) * self.g;
    }
    /// Nearest grid node to a world point, clamped to the grid.
    fn nearest(self: Grid, x: f64, y: f64) [2]usize {
        const fx = std.math.clamp(@round((x - self.ox) / self.g), 0, @as(f64, @floatFromInt(self.nx - 1)));
        const fy = std.math.clamp(@round((y - self.oy) / self.g), 0, @as(f64, @floatFromInt(self.ny - 1)));
        return .{ @intFromFloat(fx), @intFromFloat(fy) };
    }
    /// World coords of the nearest grid node — snapping a via onto the grid so
    /// the `copperHalo` exclusion (exact only for on-grid centres) holds.
    fn snap(self: Grid, x: f64, y: f64) [2]f64 {
        const nd = self.nearest(x, y);
        return .{ self.worldX(nd[0]), self.worldY(nd[1]) };
    }
};

const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Allocate `n_layers` per-signal-layer node grids of `nodes` cells each,
/// all initialised EMPTY — the shape `Ctx.occ`/`Ctx.resv` carry.
fn allocLayerGrids(arena: std.mem.Allocator, n_layers: usize, nodes: usize) std.mem.Allocator.Error![][]i32 {
    const out = try arena.alloc([]i32, n_layers);
    for (out) |*l| {
        l.* = try arena.alloc(i32, nodes);
        @memset(l.*, EMPTY);
    }
    return out;
}

/// Distance from a point to an axis-aligned rect (0 if inside).
fn distPointRect(px: f64, py: f64, r: Rect) f64 {
    const dx = @max(@max(r.x0 - px, px - r.x1), 0);
    const dy = @max(@max(r.y0 - py, py - r.y1), 0);
    return @sqrt(dx * dx + dy * dy);
}

/// Build the pad-obstacle list: *every* pad of every part, as a world rect
/// tagged with its flattened-net index (−1 when the pad is on no net). This is
/// the exact pad set `drc.zig` checks against, so the router avoids precisely
/// what the DRC flags — connected pads *and* NC/mechanical pads alike.
fn buildObstacles(arena: std.mem.Allocator, parts: []const Part, nets: []const FlatNet) std.mem.Allocator.Error![]PadObs {
    var pin_net = std.StringHashMap(i32).init(arena);
    for (nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(key, @intCast(ni));
        }
    }
    var obs: std.ArrayListUnmanaged(PadObs) = .empty;
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
                .layer = sideLayer(part),
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
const NETCLASS_BITS = 3;

/// Highest authored `(net-class … (priority N))` tier a net can declare —
/// parse-time clamps to this, and `netPriority` clamps again defensively so a
/// corrupt rule can't shift garbage into the sort key's high bits.
const MAX_NET_PRIORITY: u32 = 7;

/// A net's routing priority. Primary key (high bits): the authored
/// `(net-class … (priority N))` tier from the design source, 0 when the net is
/// in no class — explicit author intent always dominates. Secondary key (the
/// low `NETCLASS_BITS` bits): the net's intrinsic routing criticality — the
/// switcher hot loop and its input rail route ahead of the pack (Phase 3 of the
/// module-placement ruleset). Routing a critical net first lets it claim the
/// short path before a bulk rail blocks it (the router has no rip-up, so
/// first-routed wins).
fn netPriority(placement: optimizer.Placement, idx_of: *std.StringHashMap(usize), net: FlatNet, net_i: usize) u32 {
    const authored: u32 = if (net_i < placement.rules.net.len)
        @min(placement.rules.net[net_i].priority, MAX_NET_PRIORITY)
    else
        0;
    var rank = netClassRank(net.name);
    if (rank == 0 and isInductorBridge(placement, idx_of, net)) rank = 1;
    return (authored << NETCLASS_BITS) | rank;
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
fn netClassRank(name: []const u8) u32 {
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
/// pins, so it never matches). Mirrors `module_policy.netClasses`' hub+inductor
/// upgrade, which only rescues `.signal`/`.control` names and so misses these.
fn isInductorBridge(placement: optimizer.Placement, idx_of: *std.StringHashMap(usize), net: FlatNet) bool {
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

/// Sort net indices by descending priority, with the net index itself as a
/// stable tiebreaker (so equal-priority nets keep their original order).
fn priorityDesc(pri: []const u32, a: usize, b: usize) bool {
    if (pri[a] != pri[b]) return pri[a] > pri[b];
    return a < b;
}

/// One route terminal: a pad's world centre (mm) + the signal layer it lives
/// on (its part's side; a through-hole pad connects on either layer, so its
/// part-side layer is simply where the maze starts) + whether its barrel
/// reaches both faces (the outer-pour skip in pass 1 needs it).
const NetPt = struct { x: f64, y: f64, layer: u8, thru: bool = false };

/// World centres (mm) of every resolvable pad on `net`, each tagged with the
/// signal layer its part sits on.
fn netPoints(arena: std.mem.Allocator, placement: optimizer.Placement, idx_of: *std.StringHashMap(usize), net: FlatNet) std.mem.Allocator.Error![]NetPt {
    var list: std.ArrayListUnmanaged(NetPt) = .empty;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        const part = placement.parts[pi];
        const pad = padOf(part, pin.pin) orelse continue;
        const c = optimizer.worldPadCenter(part, pad.x, pad.y);
        try list.append(arena, .{ .x = c[0], .y = c[1], .layer = sideLayer(part), .thru = pad.thru });
    }
    return list.toOwnedSlice(arena);
}

/// The footprint pad named `pin` on `part`, or null when absent.
fn padOf(part: Part, pin: []const u8) ?geometry.Pad {
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, pin)) return pad;
    }
    return null;
}

/// World centre of `pin` on `part`, or null if the pad isn't in the footprint.
fn padCenter(part: Part, pin: []const u8) ?[2]f64 {
    const pad = padOf(part, pin) orelse return null;
    return optimizer.worldPadCenter(part, pad.x, pad.y);
}

// ── Via clearance (DRC-safe via placement) ──────────────────────────────────

/// Via copper radius (mm).
fn viaR(params: RouteParams) f64 {
    return params.via_dia / 2;
}

/// Shortest distance from point (px,py) to segment (ax,ay)→(bx,by).
fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/// True if a via of the configured size centred at (x,y) on net `net` keeps the
/// copper clearance from every *foreign* pad (the via-in-pad crowding rule).
fn viaClearsPads(ctx: *Ctx, x: f64, y: f64, net: i32) bool {
    const need = viaR(ctx.params) + ctx.params.clearance;
    for (ctx.obs) |p| {
        if (p.net == net) continue;
        if (pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, x, y, need) < need - 1e-9) return false;
    }
    return true;
}

/// True if a via at (x,y) on net `net` keeps via-to-via clearance from every
/// already-placed via on a *different* net.
fn viaClearsVias(ctx: *Ctx, placed: []const Via, x: f64, y: f64, net: i32) bool {
    const rr = viaR(ctx.params);
    for (placed) |v| {
        if (v.net == net) continue;
        const need = rr + v.dia / 2 + ctx.params.clearance;
        if (std.math.hypot(x - v.x, y - v.y) < need - 1e-9) return false;
    }
    return true;
}

/// True if a via of the configured size at (x,y) on net `net` keeps copper
/// clearance from every routed track on a *different* net — the via↔track rule
/// the DRC then re-checks (so an escape via can't be dropped on foreign copper).
fn viaClearsTracks(ctx: *Ctx, tracks: []const Track, x: f64, y: f64, net: i32) bool {
    const rr = viaR(ctx.params);
    for (tracks) |t| {
        if (t.net == net) continue;
        const need = rr + t.width / 2 + ctx.params.clearance;
        if (segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) < need - 1e-9) return false;
    }
    return true;
}

/// True if the `track_width` stub a→b on net `net` keeps clearance from every
/// already-placed via on a *different* net (the via↔track rule, from the trace's
/// side). An escape stub is drawn after some vias are already down, and a via
/// fixed earlier won't re-check this later trace — so the trace must clear the
/// vias itself or the pair would fail DRC.
fn segClearsVias(ctx: *Ctx, placed: []const Via, a: [2]f64, b: [2]f64, net: i32) bool {
    for (placed) |v| {
        if (v.net == net) continue;
        const need = v.dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
        if (segPointDist(a[0], a[1], b[0], b[1], v.x, v.y) < need - 1e-9) return false;
    }
    return true;
}

/// Shortest distance between segments a1→a2 and b1→b2 (0 when they cross).
fn segSegDist(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) f64 {
    // Proper crossing ⇒ distance 0.
    const d1 = [2]f64{ a2[0] - a1[0], a2[1] - a1[1] };
    const d2 = [2]f64{ b2[0] - b1[0], b2[1] - b1[1] };
    const den = d1[0] * d2[1] - d1[1] * d2[0];
    if (@abs(den) > 1e-12) {
        const t = ((b1[0] - a1[0]) * d2[1] - (b1[1] - a1[1]) * d2[0]) / den;
        const u = ((b1[0] - a1[0]) * d1[1] - (b1[1] - a1[1]) * d1[0]) / den;
        if (t >= 0 and t <= 1 and u >= 0 and u <= 1) return 0;
    }
    // Otherwise the closest approach is at an endpoint of one of the two.
    var d = segPointDist(a1[0], a1[1], a2[0], a2[1], b1[0], b1[1]);
    d = @min(d, segPointDist(a1[0], a1[1], a2[0], a2[1], b2[0], b2[1]));
    d = @min(d, segPointDist(b1[0], b1[1], b2[0], b2[1], a1[0], a1[1]));
    d = @min(d, segPointDist(b1[0], b1[1], b2[0], b2[1], a2[0], a2[1]));
    return d;
}

/// True if the `track_width` stub a→b on net `net` (drawn on signal layer
/// `layer`) keeps the copper clearance from every routed track of a *different*
/// net on that layer. The escape pass runs after the maze, and maze copper is
/// grid-guaranteed only against other maze copper — a stub drawn at an
/// arbitrary point must check the tracks itself or it can cross them outright
/// (the classic breakout-stub-through-a-rail short).
fn segClearsTracks(ctx: *Ctx, tracks: []const Track, a: [2]f64, b: [2]f64, net: i32, layer: u8) bool {
    for (tracks) |t| {
        if (t.net == net or t.layer != layer) continue;
        const need = t.width / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
        if (segSegDist(a, b, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }) < need - 1e-9) return false;
    }
    return true;
}

/// True if the same-net stub segment a→b (a real `track_width` trace) keeps
/// clearance from every foreign pad along its length. Sampled at a tenth of
/// the grid pitch with the requirement inflated by half a sample step (the
/// Lipschitz bound: any point sits within step/2 of a sample), so a
/// between-sample dip can't slip a sub-clearance approach past the sampling —
/// the stub provably meets the DRC rule at a ~13 um routability cost.
fn segClearsPads(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32) bool {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const step = ctx.grid.g * 0.1;
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / step))));
    const need = ctx.params.track_width / 2 + ctx.params.clearance + step / 2;
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const p = [2]f64{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
        for (ctx.obs) |o| {
            if (o.net == net) continue;
            if (pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, p[0], p[1], need) < need - 1e-9) return false;
        }
    }
    return true;
}

/// Longest clear prefix of escape stub a→b on net `net`: the farthest point
/// from the pad `a` such that the whole sub-segment keeps clearance from every
/// foreign pad, via, and routed track on `layer`. Returns `a` itself when even
/// the first step isn't clear (the caller then drops the stub) — a single-pin
/// breakout has nothing to connect to, so trimming it never breaks a real
/// connection.
fn trimStub(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, b: [2]f64, net: i32, layer: u8) [2]f64 {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    if (len < 1e-9) return a;
    const step = ctx.grid.g * 0.2;
    const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / step))));
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
            if (pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, p[0], p[1], need) < need) {
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
const ESCAPE_VIA_RINGS: usize = 12;

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
fn findEscapeVia(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, dir: [2]f64, net: i32, layer: u8) ?[2]f64 {
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
    while (ring <= ESCAPE_VIA_RINGS) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const ang = compass45(ang0, k);
            const s = [2]f64{ a[0] + rad * @cos(ang), a[1] + rad * @sin(ang) };
            if (!viaClearsPads(ctx, s[0], s[1], net)) continue;
            if (!viaClearsVias(ctx, placed, s[0], s[1], net)) continue;
            if (!viaClearsTracks(ctx, tracks, s[0], s[1], net)) continue;
            // The stub itself must clear every foreign pad, placed via, and
            // routed track — all are fixed and won't re-check this later
            // trace, so the pair would fail DRC (or short outright).
            if (!segClearsVias(ctx, placed, a, s, net)) continue;
            if (!segClearsTracks(ctx, tracks, a, s, net, layer)) continue;
            if (!segClearsPads(ctx, a, s, net)) continue;
            return s;
        }
    }
    return null;
}

/// The `k`-th 45°-multiple heading nearest `ang0`: the snapped base compass
/// direction, then ±45°, ±90°, ±135°, +180° — so the fan tries the heading
/// closest to the reserved corridor first while every candidate stays a
/// 45°-multiple (the stub drawn along it is octilinear by construction).
fn compass45(ang0: f64, k: usize) f64 {
    const step = std.math.pi / 4.0;
    const base = @round(ang0 / step) * step;
    const mag: f64 = @floatFromInt((k + 1) / 2);
    const sign: f64 = if (k % 2 == 1) 1 else -1;
    return base + sign * mag * step;
}

/// Snap the heading of a→b to the nearest 45° multiple, keeping the length —
/// the fallback surface stub's octilinear discipline.
fn snap45(a: [2]f64, b: [2]f64) [2]f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < 1e-9) return b;
    const ang = compass45(std.math.atan2(dy, dx), 0);
    return .{ a[0] + len * @cos(ang), a[1] + len * @sin(ang) };
}

/// Outward fan direction for a ground via at pad centre `c`: a unit vector
/// pointing *away* from nearby foreign pads (so the via escapes into open
/// copper). Falls back to +y when nothing is close.
fn groundFanDir(ctx: *Ctx, c: [2]f64, net: i32) [2]f64 {
    var vx: f64 = 0;
    var vy: f64 = 0;
    for (ctx.obs) |p| {
        if (p.net == net) continue;
        const cx = (p.x0 + p.x1) / 2;
        const cy = (p.y0 + p.y1) / 2;
        const dx = c[0] - cx;
        const dy = c[1] - cy;
        const d2 = dx * dx + dy * dy;
        if (d2 < 1e-9 or d2 > 16.0) continue; // ignore pads > 4 mm away
        vx += dx / d2;
        vy += dy / d2;
    }
    const m = std.math.hypot(vx, vy);
    if (m < 1e-9) return .{ 0, 1 };
    return .{ vx / m, vy / m };
}

/// Angle offset sequence sweeping out from 0: 0, +30°, −30°, +60°, −60°, …
/// — so the fan search tries directions nearest the outward heading first.
fn swivel(k: usize) f64 {
    const step = std.math.pi / 6.0;
    const mag: f64 = @floatFromInt((k + 1) / 2);
    const sign: f64 = if (k % 2 == 1) 1 else -1;
    return sign * mag * step;
}

/// Find a DRC-safe spot for a ground via serving pad centre `c` on net `net`.
/// Prefers the pad centre (true via-in-pad — fine on a large exposed pad); if
/// that crowds a foreign pad/via, fans the via outward into open copper until it
/// clears, returning that point (the caller joins it with a same-net stub). Null
/// when no clear spot is found in the search window — the pad is then left
/// without a via rather than emitting a guaranteed clearance violation.
fn findGroundVia(ctx: *Ctx, placed: []const Via, c: [2]f64, net: i32) ?[2]f64 {
    const grid = ctx.grid;
    // Candidate 0: the pad centre, snapped to the grid (true via-in-pad when
    // the pad is large enough to clear its neighbours).
    {
        const s = grid.snap(c[0], c[1]);
        if (viaClearsPads(ctx, s[0], s[1], net) and viaClearsVias(ctx, placed, s[0], s[1], net) and segClearsPads(ctx, c, s, net))
            return s;
    }
    // Otherwise fan outward (away from foreign pads) in growing rings, snapping
    // each candidate to the grid, until one clears every foreign pad and via.
    const dir = groundFanDir(ctx, c, net);
    const ang0 = std.math.atan2(dir[1], dir[0]);
    var ring: usize = 1;
    while (ring <= 16) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 12) : (k += 1) {
            const a = ang0 + swivel(k);
            const s = grid.snap(c[0] + rad * @cos(a), c[1] + rad * @sin(a));
            if (!viaClearsPads(ctx, s[0], s[1], net)) continue;
            if (!viaClearsVias(ctx, placed, s[0], s[1], net)) continue;
            if (!segClearsPads(ctx, c, s, net)) continue;
            return s;
        }
    }
    return null;
}

/// The nearest DRC-safe spot for a standalone GND plane stitch via near `c` (a
/// signal via we're stitching the return path of): fan outward in growing rings
/// to the first grid point within `max_r` mm that clears every foreign pad, every
/// placed via, and every routed track (the stitch pass runs last, so all copper
/// is down). Null when nothing fits — the via stays unstitched rather than forcing
/// a DRC violation. Unlike `findGroundVia` there's no stub back to a pad (a plane
/// via needs none), so no segment-clearance constraint applies.
fn findStitchVia(ctx: *Ctx, placed: []const Via, tracks: []const Track, c: [2]f64, net: i32, max_r: f64) ?[2]f64 {
    const grid = ctx.grid;
    const max_ring: usize = @max(1, @as(usize, @intFromFloat(@floor(max_r / grid.g))));
    var ring: usize = 1;
    while (ring <= max_ring) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const a = (@as(f64, @floatFromInt(k)) / 16.0) * std.math.tau;
            const s = grid.snap(c[0] + rad * @cos(a), c[1] + rad * @sin(a));
            if (std.math.hypot(s[0] - c[0], s[1] - c[1]) > max_r) continue;
            if (!viaClearsPads(ctx, s[0], s[1], net)) continue;
            if (!viaClearsVias(ctx, placed, s[0], s[1], net)) continue;
            if (!viaClearsTracks(ctx, tracks, s[0], s[1], net)) continue;
            return s;
        }
    }
    return null;
}

/// Does `name` have a dedicated copper plane on this board? Legacy (no
/// `(stackup …)` form ⇒ `plane_nets == null`): ground nets are assumed to.
/// With a declared stackup: exactly the nets its `(plane …)` entries name
/// (matched case-insensitively, full or short name) — so `(stackup 2)`
/// declares none and ground routes as real copper.
fn netHasPlane(placement: optimizer.Placement, name: []const u8) bool {
    const planes = placement.rules.plane_nets orelse return isGroundName(shortName(name));
    for (planes) |pn| {
        if (std.ascii.eqlIgnoreCase(pn, name) or std.ascii.eqlIgnoreCase(pn, shortName(name))) return true;
    }
    return false;
}

/// Which outer signal layers (index 0 = top, 1 = bottom) carry `name` as a
/// declared pour — the faces where a same-net pad is already IN the copper.
/// Both false on the legacy implicit model (its planes are inner-only).
fn netPourLayers(placement: optimizer.Placement, name: []const u8) [2]bool {
    var out = [2]bool{ false, false };
    inline for ([_]optimizer.Side{ .top, .bottom }, 0..) |side, li| {
        if (placement.rules.pourNetOnSide(side)) |pn| {
            out[li] = std.ascii.eqlIgnoreCase(pn, name) or std.ascii.eqlIgnoreCase(pn, shortName(name));
        }
    }
    return out;
}

/// True when route terminal `c` already sits in one of its net's outer-layer
/// pours (`pour` from `netPourLayers`): an SMD pad on the poured face, or a
/// through-hole barrel, which meets a pour on either face.
fn padInPour(pour: [2]bool, c: NetPt) bool {
    if (c.thru) return pour[0] or pour[1];
    return pour[c.layer];
}

/// Overlay `net_i`'s `(net-class …)` rule onto the base route params — the
/// per-net effective geometry every subsequent clearance/width/via read uses.
/// Nets without a rule (or with zero fields) keep the base values.
fn setNetParams(ctx: *Ctx, placement: optimizer.Placement, net_i: usize) void {
    var p = ctx.base;
    if (net_i < placement.rules.net.len) {
        const r = placement.rules.net[net_i];
        if (r.width > 0) p.track_width = r.width;
        if (r.clearance > 0) p.clearance = r.clearance;
        if (r.via_dia > 0) p.via_dia = r.via_dia;
        if (r.via_drill > 0) p.via_drill = r.via_drill;
    }
    ctx.params = p;
    ctx.reach = p.track_width / 2 + p.clearance;
}

/// The widest geometry any net on this board can use — grid pitch and the
/// pad-index prefilter are sized to this so two adjacent occupied grid lines
/// satisfy clearance even between the widest pair of classes. Boards with no
/// `(net-class …)` forms return `base` unchanged (identical legacy grid).
fn maxRouteParams(placement: optimizer.Placement, base: RouteParams) RouteParams {
    var p = base;
    for (placement.rules.net) |r| {
        if (r.width > p.track_width) p.track_width = r.width;
        if (r.clearance > p.clearance) p.clearance = r.clearance;
        if (r.via_dia > p.via_dia) p.via_dia = r.via_dia;
    }
    return p;
}

/// Index of the first ground net that HAS a plane (by name), or null when the
/// board has none — then there's no plane to stitch to and the return-path
/// stitch pass is skipped (on a plane-less 2-layer board ground is ordinary
/// routed copper, so "stitching" it makes no sense).
fn firstGroundNet(placement: optimizer.Placement) ?i32 {
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
fn stampDisc(ctx: *Ctx, x: f64, y: f64, net: i32, dist: f64, layer: u8, both: bool) void {
    const grid = ctx.grid;
    const r_nodes: i64 = @intFromFloat(@ceil(dist / grid.g));
    const c = grid.nearest(x, y);
    const ci: i64 = @intCast(c[0]);
    const cj: i64 = @intCast(c[1]);
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
            const n = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            for (ctx.occ, 0..) |occ_l, li| {
                if (!both and li != layer) continue;
                if (occ_l[n] == EMPTY) occ_l[n] = net;
            }
        }
    }
}

/// Minimal radius (mm) within which a foreign grid node must be excluded so no
/// foreign track/via comes closer than `D = viaR + track_half + clearance` to a
/// via centre. A foreign track between two nodes both at radius R dips to
/// `√(R²−g²/2)` at its closest, so `R = √(D² + g²/2)` is exactly enough — much
/// tighter than a flat per-node margin, which is what keeps tight parts routable.
fn copperHalo(ctx: *Ctx) f64 {
    const d = viaR(ctx.params) + ctx.params.track_width / 2 + ctx.params.clearance;
    return @sqrt(d * d + ctx.grid.g * ctx.grid.g * 0.5);
}

/// Reserve a placed via's clearance halo on every signal layer (vias are
/// through-only — the barrel blocks them all).
fn stampViaOcc(ctx: *Ctx, x: f64, y: f64, net: i32) void {
    stampDisc(ctx, x, y, net, copperHalo(ctx), 0, true);
}

/// Reserve a ground-via stub's clearance halo along its length on the stub's
/// own signal layer, so a foreign via can't be dropped on top of the stub.
fn stampStubOcc(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) void {
    const grid = ctx.grid;
    const d = copperHalo(ctx);
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / (grid.g * 0.5)))));
    var s: usize = 0;
    while (s <= steps) : (s += 1) {
        const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
        stampDisc(ctx, a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), net, d, layer, false);
    }
}

/// May a layer-changing via be dropped at node `n` for net `net`? It must clear
/// foreign pads by the via clearance and have no foreign copper within its halo
/// on ANY signal layer (vias are through-only, so the barrel meets them all) —
/// so a maze via can never crowd a pad or an already-routed foreign track/via.
fn viaAllowed(ctx: *Ctx, n: usize, net: i32) bool {
    const grid = ctx.grid;
    const x = grid.worldX(n % grid.nx);
    const y = grid.worldY(n / grid.nx);
    if (!viaClearsPads(ctx, x, y, net)) return false;
    const dist = copperHalo(ctx);
    const r_nodes: i64 = @intFromFloat(@ceil(dist / grid.g));
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
            for (ctx.occ, ctx.resv) |occ_l, resv_l| {
                if (occ_l[m] != EMPTY and occ_l[m] != net) return false;
                if (resv_l[m] != EMPTY and resv_l[m] != net) return false;
            }
        }
    }
    return true;
}

// ── Maze routing ─────────────────────────────────────────────────────────

const Ctx = struct {
    arena: std.mem.Allocator,
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
    /// Pad-index prefilter reach — the MAX reach any net class can need, so
    /// the lazily-built PadGrid stays a superset for every net (exact tests
    /// still use the per-net `reach`).
    index_reach: f64 = 0,
    /// When false the maze may not change layers — used for the top-layer-only
    /// first pass so a short signal net (e.g. a feedback tap) stays on the
    /// surface instead of diving to L2 the moment a via is marginally cheaper.
    allow_vias: bool = true,
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
    /// Lazily-built spatial index over `obs` (pads are static for a route) so
    /// `blocked` tests only pads near the node, not all of them. Null until
    /// first use, or when the board is degenerate / the grid would be oversized
    /// (blocked then falls back to the full scan). Result-identical: it only
    /// pre-filters candidates by position; the exact per-pad decision is kept.
    pad_index: ?*const PadGrid = null,
};

/// Uniform spatial bucket grid over obstacle pads. Each pad is inserted into
/// every cell its `reach`-expanded bounding box overlaps, so a query for the
/// cell containing a node point returns every pad within `reach` of that node
/// (plus a few harmless extras the exact distance test rejects).
const PadGrid = struct {
    ox: f64,
    oy: f64,
    cell: f64,
    nx: usize,
    ny: usize,
    cells: []const []const u32,

    fn cellFor(w: f64, o: f64, cell: f64, n: usize) usize {
        const f = @floor((w - o) / cell);
        if (f < 0) return 0;
        const iu: usize = @intFromFloat(f);
        return @min(iu, n - 1);
    }

    /// Pads whose expanded box overlaps the cell containing `(px, py)`.
    fn near(self: *const PadGrid, px: f64, py: f64) []const u32 {
        const cx = cellFor(px, self.ox, self.cell, self.nx);
        const cy = cellFor(py, self.oy, self.cell, self.ny);
        return self.cells[cy * self.nx + cx];
    }

    /// Build the index, or return null (degenerate board / oversized grid) so
    /// the caller falls back to the exact full scan. Any allocation failure
    /// returns null rather than a partially-populated (wrong) index.
    fn build(arena: std.mem.Allocator, obs: []const PadObs, grid: Grid, reach: f64) ?*const PadGrid {
        if (obs.len == 0) return null;
        const cell = @max(reach * 4.0, 1.0);
        var minx = grid.ox;
        var miny = grid.oy;
        var maxx = grid.ox + @as(f64, @floatFromInt(grid.nx -| 1)) * grid.g;
        var maxy = grid.oy + @as(f64, @floatFromInt(grid.ny -| 1)) * grid.g;
        for (obs) |p| {
            minx = @min(minx, p.x0 - reach);
            miny = @min(miny, p.y0 - reach);
            maxx = @max(maxx, p.x1 + reach);
            maxy = @max(maxy, p.y1 + reach);
        }
        const gnx: usize = @as(usize, @intFromFloat(@floor((maxx - minx) / cell))) + 1;
        const gny: usize = @as(usize, @intFromFloat(@floor((maxy - miny) / cell))) + 1;
        const total = std.math.mul(usize, gnx, gny) catch return null;
        if (total > (1 << 22)) return null; // too big — full scan is cheaper
        const lists = arena.alloc(std.ArrayListUnmanaged(u32), total) catch return null;
        for (lists) |*l| l.* = .empty;
        for (obs, 0..) |p, i| {
            const cx0 = cellFor(p.x0 - reach, minx, cell, gnx);
            const cx1 = cellFor(p.x1 + reach, minx, cell, gnx);
            const cy0 = cellFor(p.y0 - reach, miny, cell, gny);
            const cy1 = cellFor(p.y1 + reach, miny, cell, gny);
            var cy = cy0;
            while (cy <= cy1) : (cy += 1) {
                var cx = cx0;
                while (cx <= cx1) : (cx += 1) {
                    lists[cy * gnx + cx].append(arena, @intCast(i)) catch return null;
                }
            }
        }
        const frozen = arena.alloc([]const u32, total) catch return null;
        for (lists, 0..) |l, i| frozen[i] = l.items;
        const self = arena.create(PadGrid) catch return null;
        self.* = .{ .ox = minx, .oy = miny, .cell = cell, .nx = gnx, .ny = gny, .cells = frozen };
        return self;
    }
};

/// True if node (layer, n) can't carry net `net`: copper of another net is
/// there, or (on top) a foreign pad is within clearance. A node sitting on the
/// net's *own* pad is always allowed (that's where the trace must connect).
/// Fold one pad `p` into the `on_own`/`foreign` accumulators for a node at
/// `(px, py)` carrying `net`. Extracted so the indexed and full-scan candidate
/// paths in `blocked` share the exact same distance test.
inline fn accumPad(p: PadObs, layer: usize, px: f64, py: f64, net: i32, use_poly: bool, reach: f64, on_own: *bool, foreign: *bool) void {
    // A pad only blocks (or connects on) the layer its copper lives on;
    // through-hole pads exist on every layer.
    if (!p.thru and p.layer != layer) return;
    // Measure clearance against the pad's real copper outline only when asked
    // (the top-first pass): a concave thermal/EP pad over-states copper in its
    // box, walling off a corridor a short net could escape through — which is
    // exactly what buries a feedback tap beside an EP and forces it inner. The
    // outline test is costly, so the bulk maze keeps the cheap box distance.
    const d = if (use_poly)
        pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, px, py, reach)
    else
        distPointRect(px, py, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1 });
    if (p.net == net) {
        if (d <= 1e-9) on_own.* = true;
    } else if (d < reach) {
        foreign.* = true;
    }
}

fn blocked(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    const o = ctx.occ[layer][n];
    if (o != EMPTY and o != net) return true;
    const rv = ctx.resv[layer][n];
    if (rv != EMPTY and rv != net) return true;
    return foreignPadAt(ctx, layer, n, net);
}

/// True when a FOREIGN pad's copper sits within clearance of node `(layer, n)`
/// and the node isn't on the net's *own* pad — the physical-pad half of
/// `blocked`, split out. The rip-up blocker probe reuses it so a probe can
/// treat foreign *copper* as passable-at-a-penalty (a rip could clear it) while
/// still refusing to tunnel through a pad (which can never be ripped).
fn foreignPadAt(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    // All-top boards keep the old fast path: nothing on the bottom layer to hit.
    if (layer != 0 and !ctx.has_bottom_pads) return false;
    const px = ctx.grid.worldX(n % ctx.grid.nx);
    const py = ctx.grid.worldY(n / ctx.grid.nx);
    // Lazily build the spatial index the first time we test a node; the pad
    // set is static for the route so one build serves all queries.
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, ctx.grid, ctx.index_reach);
    var on_own = false;
    var foreign = false;
    if (ctx.pad_index) |idx| {
        for (idx.near(px, py)) |pi| accumPad(ctx.obs[pi], layer, px, py, net, ctx.use_poly, ctx.reach, &on_own, &foreign);
    } else {
        for (ctx.obs) |p| accumPad(p, layer, px, py, net, ctx.use_poly, ctx.reach, &on_own, &foreign);
    }
    return foreign and !on_own;
}

/// True iff `idx.near(node)` includes every pad the full scan would consider
/// (any pad within `reach` of the node) across every grid node — the invariant
/// that makes the indexed `blocked` result-identical to the full scan (extra
/// candidates are fine; the exact distance test in `accumPad` rejects them).
/// Loops live here so the test body stays a single assertion.
fn padGridCoversFullScan(arena: std.mem.Allocator) bool {
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 64, .ny = 64 };
    const reach: f64 = 0.25;
    const pads = [_]PadObs{
        .{ .x0 = 1.0, .y0 = 1.0, .x1 = 1.5, .y1 = 1.3, .net = 1 },
        .{ .x0 = 1.45, .y0 = 1.2, .x1 = 1.9, .y1 = 1.5, .net = 3 }, // clearance-overlaps pad 0
        .{ .x0 = 3.0, .y0 = 2.0, .x1 = 3.4, .y1 = 2.4, .net = 2 },
        .{ .x0 = 5.2, .y0 = 5.2, .x1 = 5.4, .y1 = 5.4, .net = 1 },
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.15, .y1 = 6.3, .net = 4 }, // long edge pad
    };
    const idx = PadGrid.build(arena, &pads, grid, reach) orelse return true;
    var iy: usize = 0;
    while (iy < grid.ny) : (iy += 1) {
        var ix: usize = 0;
        while (ix < grid.nx) : (ix += 1) {
            const px = grid.worldX(ix);
            const py = grid.worldY(iy);
            const cand = idx.near(px, py);
            for (pads, 0..) |p, i| {
                const d = distPointRect(px, py, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1 });
                if (d >= reach) continue;
                var found = false;
                for (cand) |c| {
                    if (c == @as(u32, @intCast(i))) found = true;
                }
                if (!found) return false;
            }
        }
    }
    return true;
}

test "PadGrid index is result-identical to the full scan" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    try std.testing.expect(padGridCoversFullScan(arena_inst.allocator()));
}

const QItem = struct { d: f64, key: usize }; // key = layer*nodes + node
fn qLess(_: void, a: QItem, b: QItem) std.math.Order {
    return std.math.order(a.d, b.d);
}

/// Connect every pad of one net by repeatedly maze-routing the next pad to the
/// net's routed-so-far copper. Returns true if all pads were joined.
///
/// Each pad terminal is entered through its *access node* (nearest grid node)
/// OR one of its off-grid `padGateways` — the straight escape stub a hand
/// router draws when a fine-pitch pad's nearest grid lane happens to fall
/// inside a neighbouring pad's clearance (whether a 0.4 mm-pitch QFN pin can
/// escape on-grid is alignment luck; the gateway removes the lottery).
fn routeNet(ctx: *Ctx, net: i32, pts: []const NetPt, tracks: *std.ArrayListUnmanaged(Track), vias: *std.ArrayListUnmanaged(Via)) std.mem.Allocator.Error!bool {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    // Seed the net with its first pad's access node, on that pad's own layer,
    // plus that pad's gateways as extra Dijkstra sources until real copper
    // exists (a gateway only becomes copper when a path actually uses it —
    // stamping them all up-front would fake connectivity). A BLOCKED access
    // node (a fine-pitch pad whose nearest grid node fell inside a
    // neighbour's clearance — or onto the neighbour itself) is never seeded:
    // copper growing from it would sit on/inside the foreign pad. Such pads
    // enter the maze through their gateways only.
    const p0 = ctx.grid.nearest(pts[0].x, pts[0].y);
    const p0n = ctx.grid.node(p0[0], p0[1]);
    if (!blocked(ctx, pts[0].layer, p0n, net)) ctx.occ[pts[0].layer][p0n] = net;
    var seed_gates: std.ArrayListUnmanaged(usize) = .empty;
    try padGateways(ctx, tracks.items, vias.items, pts[0], net, &seed_gates);

    var have_copper = false; // true once some leg routed (seed stub emitted)
    var all_ok = true;
    for (pts[1..]) |pt| {
        const goal = ctx.grid.nearest(pt.x, pt.y);
        const goal_key = @as(usize, pt.layer) * nodes + ctx.grid.node(goal[0], goal[1]);
        var goals: std.ArrayListUnmanaged(usize) = .empty;
        try goals.append(ctx.arena, goal_key);
        try padGateways(ctx, tracks.items, vias.items, pt, net, &goals);
        const extra: []const usize = if (have_copper) &.{} else seed_gates.items;
        if (try dijkstra(ctx, net, goals.items, extra, tracks, vias)) |hit| {
            // Join the goal pad's centre to whichever entry node the path
            // actually reached (plain access node or gateway alike).
            try gateStub(ctx, net, pt, hit.goal, tracks);
            if (!have_copper) {
                try gateStub(ctx, net, pts[0], hit.source, tracks);
                have_copper = true;
            }
        } else {
            all_ok = false;
            // Do NOT stamp the failed goal as this net's copper. It was never
            // reached, so it carries no track — marking it `occ = net` would
            // make it a Dijkstra *source* for a later same-net leg (see the
            // source scan in `dijkstra`), letting that leg weld to a stranded
            // island: the drawing looks connected while the pad is electrically
            // split from the net's real copper. Leaving it EMPTY keeps the pad
            // honestly unrouted — a later leg connects to the real tree or fails.
        }
    }
    return all_ok;
}

/// Rings the pad-gateway search fans outward — ~1.5 mm at the default pitch,
/// enough to clear a QFN pad collar plus the ground-via ring beside it.
const GATE_RINGS: usize = 6;

/// Collect the off-grid gateway nodes of pad terminal `pt`: grid nodes within
/// `GATE_RINGS` of the pad centre that are themselves routable AND reachable
/// from the pad centre by ONE straight stub keeping true clearance from every
/// foreign pad, placed via, and routed track. Along a pad's own axis such a
/// stub always clears its row neighbours (the lateral gap is fixed by the pad
/// pitch), so a fine-pitch pin keeps an exit even when every nearby grid node
/// sits inside a neighbour's clearance. Keys are appended to `out` (deduped).
fn padGateways(ctx: *Ctx, tracks: []const Track, vias: []const Via, pt: NetPt, net: i32, out: *std.ArrayListUnmanaged(usize)) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const c = [2]f64{ pt.x, pt.y };
    const dir = groundFanDir(ctx, c, net);
    const ang0 = std.math.atan2(dir[1], dir[0]);
    var ring: usize = 1;
    while (ring <= GATE_RINGS) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const ang = compass45(ang0, k);
            const nd = grid.nearest(c[0] + rad * @cos(ang), c[1] + rad * @sin(ang));
            const n = grid.node(nd[0], nd[1]);
            const key = @as(usize, pt.layer) * nodes + n;
            if (containsKey(out.items, key)) continue;
            if (blocked(ctx, pt.layer, n, net)) continue;
            const s = [2]f64{ grid.worldX(nd[0]), grid.worldY(nd[1]) };
            if (!segClearsPads(ctx, c, s, net)) continue;
            if (!segClearsVias(ctx, vias, c, s, net)) continue;
            if (!segClearsTracks(ctx, tracks, c, s, net, pt.layer)) continue;
            try out.append(ctx.arena, key);
        }
    }
}

fn containsKey(keys: []const usize, key: usize) bool {
    for (keys) |k| {
        if (k == key) return true;
    }
    return false;
}

/// Emit the stub joining pad terminal `pt`'s true centre to the entry node
/// `key` the maze actually used, and reserve its clearance halo so later nets
/// detour it (the stub is off-grid copper the occupancy grid can't see).
fn gateStub(ctx: *Ctx, net: i32, pt: NetPt, key: usize, tracks: *std.ArrayListUnmanaged(Track)) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const layer: u8 = @intCast(key / nodes);
    const n = key % nodes;
    const w = [2]f64{ grid.worldX(n % grid.nx), grid.worldY(n / grid.nx) };
    if (@abs(w[0] - pt.x) < 1e-6 and @abs(w[1] - pt.y) < 1e-6) return;
    try tracks.append(ctx.arena, .{ .x1 = pt.x, .y1 = pt.y, .x2 = w[0], .y2 = w[1], .layer = layer, .width = ctx.params.track_width, .net = net });
    stampStubOcc(ctx, .{ pt.x, pt.y }, w, net, layer);
}

/// Reset every grid node this net stamped back to EMPTY. Used to undo a failed
/// top-layer-only attempt before re-routing the net with vias allowed — since a
/// net only ever stamps its own index, clearing `occ == net` (and its diagonal
/// corner reservations) leaves every other net's copper untouched.
fn clearNetOcc(ctx: *Ctx, net: i32) void {
    for (ctx.occ, ctx.resv) |occ_l, resv_l| {
        for (occ_l) |*c| {
            if (c.* == net) c.* = EMPTY;
        }
        for (resv_l) |*c| {
            if (c.* == net) c.* = EMPTY;
        }
    }
}

// ── Bounded rip-up & reroute ─────────────────────────────────────────────────
//
// The greedy pass is first-routed-wins, so a net can be boxed in by copper
// routed before it. After it, each still-failed net gets a bounded chance to
// displace copper of no-higher priority that stands in its way (see
// `collectRippable` for why equal-priority copper is rippable but strictly
// higher is protected): a soft "probe" search finds the min-cost path when
// foreign copper is passable-at-a-penalty (the crossed nets are the blockers),
// those blockers are ripped, the failed net is re-routed into the freed space,
// and the ripped nets are re-routed after it (they may find alternates). Every
// attempt is speculative — the whole routing state is snapshotted first and
// rolled back unless the attempt strictly improves the outcome (more nets
// routed, ties broken by shorter total copper), so rip-up can never regress a
// board. Capped at `RIPUP_MAX_ROUNDS` passes and stops early once a pass changes
// nothing. Skipped entirely on grid overflow
// (that path returns before the greedy pass ever runs).

/// A maze net's working record during rip-up: its net index, routing priority,
/// and whether it is currently routed. Built once from the greedy pass, then
/// mutated in place as nets are ripped and re-routed.
const RipNet = struct { net_i: usize, pri: u32, ok: bool };

/// Rip-up passes cap: at most this many full sweeps over the failed nets. Each
/// sweep is O(failed × (probe + rip + reroute)); 3 is plenty for module boards
/// and keeps the worst case a small multiple of the single greedy pass.
const RIPUP_MAX_ROUNDS: usize = 3;
/// Per-cell penalty (× grid pitch) the blocker probe charges for stepping onto
/// foreign copper. Large enough that the probe crosses copper only when there is
/// no pad-free detour — so the nets it reports are the ones actually walling the
/// failed net in, not incidental copper it could have gone around.
const RIPUP_CROSS_PEN: f64 = 200.0;

/// True when at least one net in the working set is still unrouted — the cheap
/// guard that keeps rip-up (and its scratch arena) off fully-routed boards.
fn anyFailed(routable: []const RipNet) bool {
    for (routable) |rn| {
        if (!rn.ok) return true;
    }
    return false;
}

/// Total length (mm) of every track segment — the tie-break metric rip-up uses
/// to prefer the shorter of two equally-routed outcomes.
fn traceLen(tracks: []const Track) f64 {
    var s: f64 = 0;
    for (tracks) |t| s += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    return s;
}

/// Count of currently-routed nets in the working set.
fn countRouted(routable: []const RipNet) usize {
    var c: usize = 0;
    for (routable) |rn| {
        if (rn.ok) c += 1;
    }
    return c;
}

/// Drop every track of `net` from `list`, packing the survivors down in place.
fn removeNetTracks(list: *std.ArrayListUnmanaged(Track), net: i32) void {
    var w: usize = 0;
    for (list.items) |item| {
        if (item.net != net) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

/// Drop every via of `net` from `list`, packing the survivors down in place.
fn removeNetVias(list: *std.ArrayListUnmanaged(Via), net: i32) void {
    var w: usize = 0;
    for (list.items) |item| {
        if (item.net != net) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

/// Remove all of `net_i`'s copper from the board: clear its occupancy/reservation
/// cells and delete its tracks + vias. Leaves every other net untouched (a net
/// only ever stamps its own index), so the freed cells are exactly this net's.
fn ripNet(ctx: *Ctx, tracks: *std.ArrayListUnmanaged(Track), vias: *std.ArrayListUnmanaged(Via), net_i: usize) void {
    const ni: i32 = @intCast(net_i);
    clearNetOcc(ctx, ni);
    removeNetTracks(tracks, ni);
    removeNetVias(vias, ni);
}

/// Cost of ENTERING node `(layer, n)` for `net` during a blocker probe: `null`
/// if a foreign pad hard-blocks it (a pad can never be ripped), else the soft
/// penalty — 0 for a free cell, `RIPUP_CROSS_PEN×g` per foreign-copper layer the
/// cell carries. This is what makes the probe pass *through* copper so the path
/// it finds reveals which nets a rip would have to clear.
fn softEnter(ctx: *Ctx, layer: usize, n: usize, net: i32) ?f64 {
    if (foreignPadAt(ctx, layer, n, net)) return null;
    var pen: f64 = 0;
    const o = ctx.occ[layer][n];
    if (o != EMPTY and o != net) pen += RIPUP_CROSS_PEN * ctx.grid.g;
    const rv = ctx.resv[layer][n];
    if (rv != EMPTY and rv != net) pen += RIPUP_CROSS_PEN * ctx.grid.g;
    return pen;
}

/// Relax one probe move onto `(to_layer, to_node)` at base step cost `base`,
/// adding the soft entry penalty. A hard-pad-blocked target is skipped.
fn softStep(ctx: *Ctx, pq: *PQ, dist: []f64, prev: []i64, net: i32, from_key: usize, to_layer: usize, to_node: ?usize, base: f64) std.mem.Allocator.Error!void {
    const tn = to_node orelse return;
    const enter = softEnter(ctx, to_layer, tn, net) orelse return;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const to_key = to_layer * nodes + tn;
    const nd = dist[from_key] + base + enter;
    if (nd < dist[to_key]) {
        dist[to_key] = nd;
        prev[to_key] = @intCast(from_key);
        try pq.add(.{ .d = nd, .key = to_key });
    }
}

/// Probe diagonal (dx,dy) of (ix,iy), refusing to clip a pad's corner (same
/// no-corner-cut guard as the real maze) — foreign copper on the flanks is fine,
/// only a hard-pad-blocked flank forbids the diagonal.
fn softDiag(
    ctx: *Ctx,
    pq: *PQ,
    dist: []f64,
    prev: []i64,
    net: i32,
    from_key: usize,
    layer: usize,
    ix: usize,
    iy: usize,
    dx: i64,
    dy: i64,
) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const c1 = neighbor(grid, ix, iy, dx, 0) orelse return;
    const c2 = neighbor(grid, ix, iy, 0, dy) orelse return;
    if (softEnter(ctx, layer, c1, net) == null or softEnter(ctx, layer, c2, net) == null) return;
    try softStep(ctx, pq, dist, prev, net, from_key, layer, neighbor(grid, ix, iy, dx, dy), grid.g * SQRT2);
}

/// Soft Dijkstra from `src`'s access node to `goal`'s, foreign copper passable
/// at a penalty (see `softEnter`). On reaching the goal it walks the path back
/// and records every foreign net whose copper it crossed into `crossed` — the
/// blocker set for this pad pair. Unreachable even softly (walled by pads) ⇒ no
/// blockers recorded. Uses `scratch` for its dist/prev/queue.
fn softProbe(ctx: *Ctx, net: i32, src: NetPt, goal: NetPt, crossed: *std.AutoHashMap(i32, void), scratch: std.mem.Allocator) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const n_layers = ctx.occ.len;
    const dist = try scratch.alloc(f64, n_layers * nodes);
    const prev = try scratch.alloc(i64, n_layers * nodes);
    @memset(dist, std.math.inf(f64));
    @memset(prev, -1);

    const s = grid.nearest(src.x, src.y);
    const src_key = @as(usize, src.layer) * nodes + grid.node(s[0], s[1]);
    const gd = grid.nearest(goal.x, goal.y);
    const goal_key = @as(usize, goal.layer) * nodes + grid.node(gd[0], gd[1]);

    var pq = std.PriorityQueue(QItem, void, qLess).init(scratch, {});
    dist[src_key] = 0;
    try pq.add(.{ .d = 0, .key = src_key });

    var found = false;
    while (pq.removeOrNull()) |it| {
        if (it.d > dist[it.key]) continue;
        if (it.key == goal_key) {
            found = true;
            break;
        }
        const layer = it.key / nodes;
        const n = it.key % nodes;
        const ix = n % grid.nx;
        const iy = n / grid.nx;
        try softStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 1, 0), grid.g);
        try softStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, -1, 0), grid.g);
        try softStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 0, 1), grid.g);
        try softStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 0, -1), grid.g);
        try softDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, 1, 1);
        try softDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, 1, -1);
        try softDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, -1, 1);
        try softDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, -1, -1);
        if (n_layers > 1) {
            for (0..n_layers) |to_layer| {
                if (to_layer == layer) continue;
                try softStep(ctx, &pq, dist, prev, net, it.key, to_layer, n, grid.g * VIA_COST_MULT);
            }
        }
    }
    if (!found) return;
    // Walk back from the goal, recording foreign copper crossed on the way.
    var k = goal_key;
    while (true) {
        const layer = k / nodes;
        const nn = k % nodes;
        const o = ctx.occ[layer][nn];
        if (o != EMPTY and o != net) try crossed.put(o, {});
        const rv = ctx.resv[layer][nn];
        if (rv != EMPTY and rv != net) try crossed.put(rv, {});
        const p = prev[k];
        if (p < 0) break;
        k = @intCast(p);
    }
}

/// The foreign nets whose copper boxes `net_i` in: probe `net_i`'s first pad to
/// each of its other pads with copper soft-passable and union the crossed nets.
/// Returns the blocker net indices (deduped). Allocated in `scratch`.
fn detectBlockers(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMap(usize),
    net_i: usize,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error![]i32 {
    const ni: i32 = @intCast(net_i);
    setNetParams(ctx, placement, net_i);
    const pts = try netPoints(scratch, placement, idx_of, placement.nets[net_i]);
    if (pts.len < 2) return &.{};
    var crossed = std.AutoHashMap(i32, void).init(scratch);
    for (pts[1..]) |pt| try softProbe(ctx, ni, pts[0], pt, &crossed, scratch);
    var out: std.ArrayListUnmanaged(i32) = .empty;
    var it = crossed.keyIterator();
    while (it.next()) |kp| try out.append(scratch, kp.*);
    return out.toOwnedSlice(scratch);
}

/// Indices (into `routable`) of the nets rip-up may remove for a net of priority
/// `fail_pri`: currently-routed blockers of priority ≤ `fail_pri` (never
/// STRICTLY HIGHER) that are not a plane, a pour, or ground (that copper is
/// never ripped).
///
/// Why lower-*or-equal*, not strictly-lower: the greedy pass routes strictly
/// higher-priority nets first, so a net that failed there was only ever boxed in
/// by copper of higher-OR-EQUAL priority. Forbidding equal-priority rips would
/// therefore make rip-up unable to rescue the common case — a net walled off by
/// an equal-tier neighbour (e.g. one flash-data line boxing the next) — leaving
/// it a no-op. Equal-tier nets carry no real importance difference (net index is
/// only a stable sort tiebreak), so ripping one to route another and letting it
/// find an alternate is exactly the intended trade. STRICTLY higher priority
/// (authored `(net-class (priority …))` tiers, the elevated switcher hot loop,
/// planes/pours/ground) stays protected; `saveSnapshot`/keep-best still make the
/// whole attempt a no-op unless it strictly improves the board.
fn collectRippable(
    scratch: std.mem.Allocator,
    placement: optimizer.Placement,
    routable: []const RipNet,
    blockers: []const i32,
    fail_pri: u32,
) std.mem.Allocator.Error![]usize {
    var out: std.ArrayListUnmanaged(usize) = .empty;
    for (routable, 0..) |rn, i| {
        if (!rn.ok) continue; // only routed copper can be ripped
        if (rn.pri > fail_pri) continue; // never rip STRICTLY higher priority
        const name = placement.nets[rn.net_i].name;
        if (netHasPlane(placement, name)) continue;
        if (isGroundName(shortName(name))) continue;
        const pour = netPourLayers(placement, name);
        if (pour[0] or pour[1]) continue;
        var is_blocker = false;
        for (blockers) |b| {
            if (b == @as(i32, @intCast(rn.net_i))) {
                is_blocker = true;
                break;
            }
        }
        if (is_blocker) try out.append(scratch, i);
    }
    return out.toOwnedSlice(scratch);
}

/// Re-route one net from scratch (its copper must already be ripped), updating
/// its `ok` flag. Mirrors the greedy pass's plain (via-allowed) attempt.
fn rerouteNet(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMap(usize),
    rn: *RipNet,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
) std.mem.Allocator.Error!void {
    setNetParams(ctx, placement, rn.net_i);
    const pts = try netPoints(ctx.arena, placement, idx_of, placement.nets[rn.net_i]);
    if (pts.len < 2) {
        rn.ok = true;
        return;
    }
    rn.ok = try routeNet(ctx, @intCast(rn.net_i), pts, tracks, vias);
}

/// A rollback point for one speculative rip-up attempt: the full routing state
/// (copper + occupancy grids + per-net status) plus its score, all duplicated
/// into the scratch arena so `restoreSnapshot` can put it back verbatim.
const RipSnapshot = struct {
    tracks: []Track,
    vias: []Via,
    occ: [][]i32,
    resv: [][]i32,
    routed: usize,
    trace: f64,
    ok: []bool,
};

/// Duplicate the current routing state into `scratch` for possible rollback.
fn saveSnapshot(
    scratch: std.mem.Allocator,
    ctx: *Ctx,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
    routable: []const RipNet,
) std.mem.Allocator.Error!RipSnapshot {
    const occ = try scratch.alloc([]i32, ctx.occ.len);
    for (ctx.occ, occ) |src, *dst| dst.* = try scratch.dupe(i32, src);
    const resv = try scratch.alloc([]i32, ctx.resv.len);
    for (ctx.resv, resv) |src, *dst| dst.* = try scratch.dupe(i32, src);
    const ok = try scratch.alloc(bool, routable.len);
    for (routable, ok) |rn, *o| o.* = rn.ok;
    return .{
        .tracks = try scratch.dupe(Track, tracks.items),
        .vias = try scratch.dupe(Via, vias.items),
        .occ = occ,
        .resv = resv,
        .routed = countRouted(routable),
        .trace = traceLen(tracks.items),
        .ok = ok,
    };
}

/// Restore the routing state captured by `saveSnapshot`, discarding the
/// speculative attempt's changes.
fn restoreSnapshot(
    ctx: *Ctx,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
    routable: []RipNet,
    snap: RipSnapshot,
) std.mem.Allocator.Error!void {
    tracks.clearRetainingCapacity();
    try tracks.appendSlice(ctx.arena, snap.tracks);
    vias.clearRetainingCapacity();
    try vias.appendSlice(ctx.arena, snap.vias);
    for (ctx.occ, snap.occ) |dst, src| @memcpy(dst, src);
    for (ctx.resv, snap.resv) |dst, src| @memcpy(dst, src);
    for (routable, snap.ok) |*rn, o| rn.ok = o;
}

/// Bounded rip-up & reroute over the greedy pass's working set. Returns the
/// number of rounds run (≥1 whenever called; caller only calls it when a net
/// failed). See the section header above for the algorithm.
fn ripUpReroute(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMap(usize),
    routable: []RipNet,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
) std.mem.Allocator.Error!usize {
    // Scratch arena for per-attempt snapshots + probe state, backed by the
    // caller's arena (not page_allocator) and reset between attempts so only one
    // snapshot's worth of memory is ever live.
    var scratch_inst = std.heap.ArenaAllocator.init(ctx.arena);
    defer scratch_inst.deinit();
    var rounds: usize = 0;
    while (rounds < RIPUP_MAX_ROUNDS) {
        rounds += 1;
        var progress = false;
        for (routable) |*rn| {
            if (rn.ok) continue; // only still-failed nets seek room
            const scratch = scratch_inst.allocator();
            const blockers = try detectBlockers(ctx, placement, idx_of, rn.net_i, scratch);
            const rippable = try collectRippable(scratch, placement, routable, blockers, rn.pri);
            if (rippable.len == 0) {
                _ = scratch_inst.reset(.retain_capacity);
                continue;
            }
            const snap = try saveSnapshot(scratch, ctx, tracks, vias, routable);
            // Rip the failed net + its lower-priority blockers…
            ripNet(ctx, tracks, vias, rn.net_i);
            rn.ok = false;
            for (rippable) |ri| {
                ripNet(ctx, tracks, vias, routable[ri].net_i);
                routable[ri].ok = false;
            }
            // …reroute the net we're rescuing first (so it claims the freed
            // space), then the ripped blockers in descending-priority order.
            try rerouteNet(ctx, placement, idx_of, rn, tracks, vias);
            for (rippable) |ri| try rerouteNet(ctx, placement, idx_of, &routable[ri], tracks, vias);
            const now_routed = countRouted(routable);
            const now_trace = traceLen(tracks.items);
            const better = now_routed > snap.routed or
                (now_routed == snap.routed and now_trace < snap.trace - 1e-6);
            if (better) {
                progress = true;
            } else {
                try restoreSnapshot(ctx, tracks, vias, routable, snap);
            }
            _ = scratch_inst.reset(.retain_capacity);
        }
        if (!progress) break;
    }
    return rounds;
}

/// Per-net routed-copper totals for the summary JSON: trace length (mm) summed
/// over the net's track segments, and its via count. Emitted by `perNetRouted`.
pub const NetRouted = struct { name: []const u8, mm: f64, vias: usize };

/// Aggregate a `RouteResult`'s copper by net — one `NetRouted` per net that
/// carries any track or via — so a caller can read where copper went per
/// connection (the route-summary JSON's `per_net`). Sorted by descending trace
/// length so the longest nets read first. `net`-index copper with no matching
/// `placement.nets` entry (there should be none) is skipped.
pub fn perNetRouted(arena: std.mem.Allocator, placement: optimizer.Placement, r: RouteResult) std.mem.Allocator.Error![]NetRouted {
    var by_idx = std.AutoHashMap(i32, NetRouted).init(arena);
    defer by_idx.deinit();
    for (r.tracks) |t| {
        if (t.net < 0) continue;
        const ui: usize = @intCast(t.net);
        if (ui >= placement.nets.len) continue;
        const gop = try by_idx.getOrPut(t.net);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = placement.nets[ui].name, .mm = 0, .vias = 0 };
        gop.value_ptr.mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    for (r.vias) |v| {
        if (v.net < 0) continue;
        const ui: usize = @intCast(v.net);
        if (ui >= placement.nets.len) continue;
        const gop = try by_idx.getOrPut(v.net);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = placement.nets[ui].name, .mm = 0, .vias = 0 };
        gop.value_ptr.vias += 1;
    }
    var out: std.ArrayListUnmanaged(NetRouted) = .empty;
    var it = by_idx.valueIterator();
    while (it.next()) |nr| try out.append(arena, nr.*);
    std.sort.pdq(NetRouted, out.items, {}, netRoutedLonger);
    return out.toOwnedSlice(arena);
}

fn netRoutedLonger(_: void, a: NetRouted, b: NetRouted) bool {
    if (a.mm != b.mm) return a.mm > b.mm;
    return std.mem.lessThan(u8, b.name, a.name); // stable, name-descending tiebreak
}

/// Where a successful maze leg entered and left the grid: `goal` is the goal
/// key it reached (plain access node or pad gateway), `source` the dist-0 key
/// the path grew from — the caller stubs the pad centres onto both.
const DijkstraHit = struct { goal: usize, source: usize };

/// Dijkstra from all of net's current copper (occ==net) plus `extra_sources`
/// (the seed pad's gateways) to the nearest key in `goals` (full
/// layer*nodes+node keys). On success, stamps the path as the net's copper,
/// emits the tracks/vias, and reports which goal/source the path used.
fn dijkstra(
    ctx: *Ctx,
    net: i32,
    goals: []const usize,
    extra_sources: []const usize,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
) std.mem.Allocator.Error!?DijkstraHit {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const n_layers = ctx.occ.len;
    const dist = try ctx.arena.alloc(f64, n_layers * nodes);
    const prev = try ctx.arena.alloc(i64, n_layers * nodes);
    @memset(dist, std.math.inf(f64));
    @memset(prev, -1);

    var pq = std.PriorityQueue(QItem, void, qLess).init(ctx.arena, {});
    // Sources: every node already owned by this net, on any signal layer…
    for (0..n_layers) |layer| {
        for (0..nodes) |n| {
            if (ctx.occ[layer][n] == net) {
                const k = layer * nodes + n;
                dist[k] = 0;
                try pq.add(.{ .d = 0, .key = k });
            }
        }
    }
    // …plus the seed pad's gateway nodes (validated by `padGateways`).
    for (extra_sources) |k| {
        if (dist[k] > 0) {
            dist[k] = 0;
            try pq.add(.{ .d = 0, .key = k });
        }
    }

    var found_key: ?usize = null;
    while (pq.removeOrNull()) |it| {
        if (it.d > dist[it.key]) continue;
        const layer = it.key / nodes;
        const n = it.key % nodes;
        if (containsKey(goals, it.key)) {
            found_key = it.key;
            break;
        }
        const ix = n % grid.nx;
        const iy = n / grid.nx;
        // Same-layer 4-neighbours (orthogonal, cost g).
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 1, 0), grid.g);
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, -1, 0), grid.g);
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 0, 1), grid.g);
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 0, -1), grid.g);
        // Same-layer diagonals (45° bends, cost g·√2). Guarded against corner-cutting.
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, 1, 1);
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, 1, -1);
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, -1, 1);
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, -1, -1);
        // Via to every OTHER signal layer at the same (ix,iy) — vias are
        // through-only, so one drill reaches them all at the same cost. Only
        // where a via of the configured size keeps clearance from foreign
        // pads and copper, and only when this pass permits layer changes.
        // (On a 2-signal board this is exactly the old `1 - layer` step.)
        if (ctx.allow_vias and n_layers > 1 and viaAllowed(ctx, n, net)) {
            for (0..n_layers) |to_layer| {
                if (to_layer == layer) continue;
                try relaxStep(ctx, &pq, dist, prev, net, it.key, to_layer, n, grid.g * VIA_COST_MULT);
            }
        }
    }

    const goal = found_key orelse return null;
    const source = try emitPath(ctx, prev, goal, net, tracks, vias);
    return .{ .goal = goal, .source = source };
}

/// Resolve a 4-neighbour node index, or null at the grid edge.
fn neighbor(grid: Grid, ix: usize, iy: usize, dx: i64, dy: i64) ?usize {
    const x = @as(i64, @intCast(ix)) + dx;
    const y = @as(i64, @intCast(iy)) + dy;
    if (x < 0 or y < 0 or x >= grid.nx or y >= grid.ny) return null;
    return @as(usize, @intCast(y)) * grid.nx + @as(usize, @intCast(x));
}

const PQ = std.PriorityQueue(QItem, void, qLess);

fn relaxStep(
    ctx: *Ctx,
    pq: *PQ,
    dist: []f64,
    prev: []i64,
    net: i32,
    from_key: usize,
    to_layer: usize,
    to_node: ?usize,
    step: f64,
) std.mem.Allocator.Error!void {
    const tn = to_node orelse return;
    if (blocked(ctx, to_layer, tn, net)) return;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const to_key = to_layer * nodes + tn;
    // Stepping onto a poured outer layer costs extra (`POUR_COST_MULT`);
    // steps on an inner signal layer carry the mild `INNER_COST_MULT` bias
    // so equal-length paths stay on the outer faces.
    const eff = if (to_layer >= 2)
        step * INNER_COST_MULT
    else if (ctx.pour[to_layer])
        step * POUR_COST_MULT
    else
        step;
    const nd = dist[from_key] + eff;
    if (nd < dist[to_key]) {
        dist[to_key] = nd;
        prev[to_key] = @intCast(from_key);
        try pq.add(.{ .d = nd, .key = to_key });
    }
}

/// Relax the diagonal neighbour (dx,dy) of (ix,iy) on `layer`. Refuses the move
/// if either orthogonal cell it squeezes past is blocked, so a 45° trace never
/// clips the corner of a pad it must clear (no corner-cutting).
fn relaxDiag(
    ctx: *Ctx,
    pq: *PQ,
    dist: []f64,
    prev: []i64,
    net: i32,
    from_key: usize,
    layer: usize,
    ix: usize,
    iy: usize,
    dx: i64,
    dy: i64,
) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const c1 = neighbor(grid, ix, iy, dx, 0) orelse return;
    const c2 = neighbor(grid, ix, iy, 0, dy) orelse return;
    if (blocked(ctx, layer, c1, net) or blocked(ctx, layer, c2, net)) return;
    try relaxStep(ctx, pq, dist, prev, net, from_key, layer, neighbor(grid, ix, iy, dx, dy), grid.g * SQRT2);
}

/// Walk `prev` from the goal back to a source, stamp the path as net copper,
/// and emit merged track segments (per straight run) + vias (per layer change).
/// Returns the source key the path grew from (== `goal_key` for a 1-node path).
fn emitPath(
    ctx: *Ctx,
    prev: []i64,
    goal_key: usize,
    net: i32,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
) std.mem.Allocator.Error!usize {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    var key: i64 = @intCast(goal_key);
    // Collect the path (goal → source).
    var path: std.ArrayListUnmanaged(usize) = .empty;
    while (key >= 0) : (key = prev[@intCast(key)]) {
        const k: usize = @intCast(key);
        ctx.occ[k / nodes][k % nodes] = net;
        try path.append(ctx.arena, k);
    }
    const ks = path.items;
    if (ks.len < 2) return goal_key;
    // Reserve the two corner cells of every diagonal step (see `Ctx.resv`):
    // they sit only g/√2 from the diagonal's centreline, so a later foreign
    // track through one would violate clearance without ever sharing a node.
    // `relaxDiag` already proved both corners clear of foreign copper *and*
    // foreign reservations, so stamping is always safe.
    for (ks[1..], 0..) |k, i| {
        const pk = ks[i];
        if (k / nodes != pk / nodes) continue; // layer change, not a step
        const layer = k / nodes;
        const ax = (pk % nodes) % grid.nx;
        const ay = (pk % nodes) / grid.nx;
        const bx = (k % nodes) % grid.nx;
        const by = (k % nodes) / grid.nx;
        if (ax == bx or ay == by) continue; // orthogonal step
        ctx.resv[layer][ay * grid.nx + bx] = net;
        ctx.resv[layer][by * grid.nx + ax] = net;
    }
    // Emit: merge straight same-layer runs into one track; via on layer change.
    // A run stays straight while consecutive grid steps share one direction —
    // which now includes the four diagonals, so 45° legs merge too.
    var run_start: usize = 0;
    var i: usize = 1;
    while (i < ks.len) : (i += 1) {
        const prev_layer = ks[i - 1] / nodes;
        const cur_layer = ks[i] / nodes;
        if (cur_layer != prev_layer) {
            try emitSeg(ctx, tracks, ks[run_start], ks[i - 1], net);
            const n = ks[i - 1] % nodes;
            const vx = grid.worldX(n % grid.nx);
            const vy = grid.worldY(n / grid.nx);
            try vias.append(ctx.arena, .{ .x = vx, .y = vy, .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = net });
            stampViaOcc(ctx, vx, vy, net); // reserve its halo for later nets
            run_start = i;
        } else if (i >= 2 and !sameDir(grid, nodes, ks[i - 2], ks[i - 1], ks[i])) {
            try emitSeg(ctx, tracks, ks[run_start], ks[i - 1], net);
            run_start = i - 1;
        }
    }
    try emitSeg(ctx, tracks, ks[run_start], ks[ks.len - 1], net);
    return ks[ks.len - 1];
}

/// Does the unit step a→b equal the unit step b→c? True ⇒ a, b, c lie on one
/// straight line (orthogonal *or* 45° diagonal), so the run can keep extending.
fn sameDir(grid: Grid, nodes: usize, a: usize, b: usize, c: usize) bool {
    const ax: i64 = @intCast((a % nodes) % grid.nx);
    const ay: i64 = @intCast((a % nodes) / grid.nx);
    const bx: i64 = @intCast((b % nodes) % grid.nx);
    const by: i64 = @intCast((b % nodes) / grid.nx);
    const cx: i64 = @intCast((c % nodes) % grid.nx);
    const cy: i64 = @intCast((c % nodes) / grid.nx);
    return (bx - ax) == (cx - bx) and (by - ay) == (cy - by);
}

fn emitSeg(ctx: *Ctx, tracks: *std.ArrayListUnmanaged(Track), a_key: usize, b_key: usize, net: i32) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    if (a_key == b_key) return;
    const layer: u8 = @intCast(a_key / nodes);
    const a = a_key % nodes;
    const b = b_key % nodes;
    try tracks.append(ctx.arena, .{
        .x1 = grid.worldX(a % grid.nx),
        .y1 = grid.worldY(a / grid.nx),
        .x2 = grid.worldX(b % grid.nx),
        .y2 = grid.worldY(b / grid.nx),
        .layer = layer,
        .width = ctx.params.track_width,
        .net = net,
    });
}

// ── Return-path continuity (a routed-result SI metric) ──────────────────────

/// A signal via needs a GND stitching via within this radius (mm) for its return
/// current to stay continuous across the layer change. ~2 mm is a common
/// stitching guideline for the low-MHz–GHz range these modules operate in.
pub const RETURN_PATH_RADIUS_MM: f64 = 2.0;

/// True when via net index `net` is a ground (plane-drop / stitching) via.
fn isGndVia(placement: optimizer.Placement, net: i32) bool {
    if (net < 0) return false;
    const ni: usize = @intCast(net);
    if (ni >= placement.nets.len) return false;
    return isGroundName(shortName(placement.nets[ni].name));
}

/// Count return-path discontinuities in a routed board: signal-net layer-change
/// vias that lack a GND stitching via within `radius` mm. On a 4-layer GND/PWR
/// stack a signal via swaps its reference plane (top references GND, bottom
/// references PWR), so its return current must hop planes — which needs a nearby
/// GND via to stay continuous. A broken/long return path dominates EMI far more
/// than trace length (TI SNVA638A), so this flags the discontinuity. Ground vias
/// are the stitching vias themselves and are never counted. O(vias²); routed
/// boards have only dozens of vias, and this runs only on an explicit route.
pub fn returnPathViolations(placement: optimizer.Placement, routed: RouteResult, radius: f64) usize {
    var count: usize = 0;
    for (routed.vias) |v| {
        if (isGndVia(placement, v.net)) continue; // a stitching via, not a signal hop
        var stitched = false;
        for (routed.vias) |g| {
            if (!isGndVia(placement, g.net)) continue;
            if (std.math.hypot(v.x - g.x, v.y - g.y) <= radius) {
                stitched = true;
                break;
            }
        }
        if (!stitched) count += 1;
    }
    return count;
}

// ── Small helpers ──────────────────────────────────────────────────────────

/// Ground-net predicate — the router shares the optimizer's exact one so a
/// split/numbered ground (GND1, AGND2, PGND_2) is treated as a plane here just
/// as it is in placement. A previous hand-copied exact-match list drifted and
/// routed those nets as signal copper.
const isGroundName = optimizer.isGroundName;

fn shortName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - maze-routes a two-pad net into connected track segments
test "route connects a simple two-pad net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 0 },
    };
    const pins_a = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins_a }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    try testing.expect(r.tracks.len >= 1);
}

// spec: placement/router - a net spanning the two board sides routes through a via, each leg on its part's layer
test "route vias between a top part and a bottom part" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 0, .side = .bottom },
    };
    const pins_a = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins_a }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    // Crossing sides needs at least one via, with copper on both layers.
    try testing.expect(r.vias.len >= 1);
    var top_len: f64 = 0;
    var bot_len: f64 = 0;
    for (r.tracks) |t| {
        const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        if (t.layer == 0) top_len += len else bot_len += len;
    }
    try testing.expect(top_len > 0);
    try testing.expect(bot_len > 0);
}

// spec: placement/router - a plane-less stackup routes ground as real copper instead of dropping plane vias
test "plane-less stackup maze-routes the ground net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 0 },
    };
    const pins_g = [_]export_kicad.FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins_g }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };

    // Legacy (no stackup): GND is a plane net — one via per pad, no trace run.
    const legacy = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), legacy.routed);
    try testing.expect(legacy.vias.len >= 2);

    // Declared plane-less stackup: GND maze-routes as surface copper.
    placement.rules.plane_nets = &.{};
    const flat = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), flat.routed);
    try testing.expectEqual(@as(usize, 0), flat.vias.len);
    var gnd_len: f64 = 0;
    for (flat.tracks) |t| gnd_len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    try testing.expect(gnd_len >= 2.5); // the ~3 mm pad-to-pad run exists as copper
}

// spec: placement/router - routes through a plane-free inner signal layer when both outer faces are blocked; a 2-signal stackup never emits inner copper
test "congested net dives to the inner signal layer on a 3-signal stackup" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // Net A joins two through-hole pads at x = ±3. Two SMD "wall" pads (on no
    // net) at x = 0 span the whole gridded height — one on the TOP face, one
    // on the BOTTOM face — so both outer signal layers are cut in half and no
    // 2-layer path exists. On a (stackup 4 (plane 2 "GND")) board the third
    // signal layer (index 2 = stack L3/In2.Cu) is plane-free and SMD walls
    // don't exist there, so the route must dive inner through vias.
    const thru_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.4 }};
    const wall_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 8.0 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &thru_pad, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &thru_pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "W1", .kind = .hub, .hw = 0.3, .hh = 4.0, .pads = &wall_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "W2", .kind = .hub, .hw = 0.3, .hh = 4.0, .pads = &wall_pad, .fallback = false, .x = 0, .y = 0, .side = .bottom },
    };
    const a_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "A", .pins = &a_pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -1,
        .maxx = 3.5,
        .maxy = 1,
        .generated = true,
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = &planes },
    };

    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    try testing.expectEqual(@as(usize, 0), r.failed.len);
    try testing.expect(!r.grid_overflow);
    // The crossing itself lives on the inner layer, reached through vias.
    try testing.expect(trackLenOnLayer(r.tracks, 2) > 1.0);
    try testing.expect(r.vias.len >= 2);
    // …and the inner-layer copper introduces no clearance violations.
    const viol = try @import("drc.zig").check(arena, placement, r, 0.127);
    try testing.expectEqual(@as(usize, 0), viol.len);

    // Regression: the same walls on a plane-less (stackup 2) have only the
    // two outer faces — the net cannot route, and NO inner copper appears.
    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    const flat = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 0), flat.routed);
    try testing.expectEqual(@as(usize, 1), flat.failed.len);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(flat.tracks, 2));

    // Legacy no-stackup boards keep the 2-signal model too (net A is not a
    // ground, so the implicit planes don't rescue it).
    placement.rules = .{};
    const legacy = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 0), legacy.routed);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(legacy.tracks, 2));
}

/// Total copper length (mm) the tracks put on signal layer `layer` — test
/// helper (hoisted so the inner-layer test keeps a single top-level loop).
fn trackLenOnLayer(tracks: []const Track, layer: u8) f64 {
    var len: f64 = 0;
    for (tracks) |t| {
        if (t.layer == layer) len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return len;
}

// spec: placement/router - reports a grid too large to route via RouteResult.grid_overflow instead of a silent empty result
test "route flags grid overflow on an oversized board" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 900, .y = 900 },
    };
    const pins_a = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins_a }};
    // ~900×900 mm at the default 0.254 mm pitch ≈ 12.6M nodes/layer — far past
    // MAX_NODES, so the router must bail AND say so.
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 900.5,
        .maxy = 900.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expect(r.grid_overflow);
    try testing.expectEqual(@as(usize, 0), r.tracks.len);
    try testing.expectEqual(@as(usize, 0), r.total);
}

// spec: placement/router - an outer-layer pour connects same-side pads directly; only opposite-face pads get a stitching via
test "outer pour skips vias for pads already in the pour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_smd = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_thru = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.4 }};
    var parts = [_]Part{
        // Top SMD pad: opposite the bottom pour — the one pad that needs a via.
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_smd, .fallback = false, .x = 0, .y = 0 },
        // Bottom SMD pad: sits in the pour.
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_smd, .fallback = false, .x = 3, .y = 0, .side = .bottom },
        // Through-hole pad: its barrel meets the pour from either side.
        .{ .ref_des = "J1", .kind = .passive, .hw = 0.6, .hh = 0.6, .pads = &pads_thru, .fallback = false, .x = 6, .y = 0 },
    };
    const pins_g = [_]export_kicad.FlatPin{
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
        .{ .ref_des = "J1", .pin = "1" },
    };
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins_g }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.6,
        .miny = -0.6,
        .maxx = 6.6,
        .maxy = 0.6,
        .generated = true,
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = &planes },
    };

    // (stackup 2 (pour bottom "GND")): only the top-face SMD pad vias down.
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    try testing.expectEqual(@as(usize, 0), r.failed.len);
    try testing.expectEqual(@as(usize, 1), r.vias.len);
    // The via serves C1 (near x=0), not the in-pour pads.
    try testing.expect(@abs(r.vias[0].x) < 1.5);

    // Every pad in the pour ⇒ zero vias, and the net still counts routed.
    parts[0].side = .bottom;
    const all_bot = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), all_bot.total);
    try testing.expectEqual(@as(usize, 1), all_bot.routed);
    try testing.expectEqual(@as(usize, 0), all_bot.failed.len);
    try testing.expectEqual(@as(usize, 0), all_bot.vias.len);
}

// spec: placement/router - a net-class rule sets its nets' trace width and via size; unruled nets keep defaults
test "net-class rules drive per-net track width" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_c = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_d = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 4, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_c, .fallback = false, .x = 0, .y = 3 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_d, .fallback = false, .x = 4, .y = 3 },
    };
    const pins_p = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_s = [_]export_kicad.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "VBUS", .pins = &pins_p }, .{ .name = "SIG", .pins = &pins_s } };
    const rules = [_]optimizer.NetRule{ .{ .width = 0.3, .via_dia = 0.6, .via_drill = 0.3 }, .{} };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 4.5,
        .maxy = 3.5,
        .generated = true,
        .rules = .{ .net = &rules },
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 2), r.routed);
    var saw_wide = false;
    var saw_default = false;
    for (r.tracks) |t| {
        if (t.net == 0) {
            try testing.expectEqual(@as(f64, 0.3), t.width);
            saw_wide = true;
        } else {
            try testing.expectEqual((RouteParams{}).track_width, t.width);
            saw_default = true;
        }
    }
    try testing.expect(saw_wide and saw_default);
}

// spec: placement/router - LoopRouter measures a real per-leg trace length that detours foreign pads
test "LoopRouter.legLen lengthens a leg that must route around an obstacle" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const sig = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };

    // Clear board: R1 → R2, 4 mm apart on net SIG (index 0). The real trace is
    // ~straight, so its length is close to the 4 mm separation.
    var clear_parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const clear_nets = [_]FlatNet{.{ .name = "SIG", .pins = &sig }};
    var clear_idx = std.StringHashMap(usize).init(arena);
    try clear_idx.put("R1", 0);
    try clear_idx.put("R2", 1);
    var lr_clear = try LoopRouter.init(arena, &clear_parts, &clear_nets, &clear_idx, .{});
    const len_clear = (try lr_clear.legLen(.{ 0, 0 }, .{ 4, 0 }, 0)).?;
    try testing.expect(len_clear >= 3.5 and len_clear < 6.0);

    // Same endpoints, but a foreign pad (net OTHER, index 1) straddles the direct
    // path — the trace must detour around it, so the measured length grows.
    const blk_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.2, .h = 1.2 }};
    var blk_parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
        .{ .ref_des = "U9", .kind = .hub, .hw = 0.8, .hh = 0.8, .pads = &blk_pad, .fallback = false, .x = 2, .y = 0 },
    };
    const other = [_]export_kicad.FlatPin{.{ .ref_des = "U9", .pin = "1" }};
    const blk_nets = [_]FlatNet{ .{ .name = "SIG", .pins = &sig }, .{ .name = "OTHER", .pins = &other } };
    var blk_idx = std.StringHashMap(usize).init(arena);
    try blk_idx.put("R1", 0);
    try blk_idx.put("R2", 1);
    try blk_idx.put("U9", 2);
    var lr_blk = try LoopRouter.init(arena, &blk_parts, &blk_nets, &blk_idx, .{});
    const len_blk = (try lr_blk.legLen(.{ 0, 0 }, .{ 4, 0 }, 0)).?;
    try testing.expect(len_blk > len_clear + 0.5);
}

// spec: placement/router - routes corners as 45° diagonals rather than 90° bends
test "route uses 45 degree diagonal segments" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two pads offset both in x and y on an open board: the shortest legal path
    // is a single 45° diagonal, so at least one emitted track must be diagonal.
    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 3 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 3.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.routed);
    var saw_diag = false;
    for (r.tracks) |t| {
        if (@abs(t.x2 - t.x1) > 1e-6 and @abs(t.y2 - t.y1) > 1e-6) saw_diag = true;
    }
    try testing.expect(saw_diag);
}

// spec: placement/router - counts signal vias lacking a nearby ground stitching via as return-path discontinuities
test "returnPathViolations flags unstitched signal vias" {
    const nets = [_]FlatNet{
        .{ .name = "SIG", .pins = &.{} }, // net 0 — a signal
        .{ .name = "GND", .pins = &.{} }, // net 1 — ground (stitching vias)
    };
    var parts = [_]Part{};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    // A signal via with its only GND via 5 mm away → unstitched (1 warning). The
    // GND via itself is never counted.
    const far = [_]Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 5, .y = 0, .dia = 0.4, .net = 1 },
    };
    const far_res = RouteResult{ .tracks = &.{}, .vias = &far, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 1), returnPathViolations(placement, far_res, RETURN_PATH_RADIUS_MM));

    // Move the GND via within the radius → the signal via is stitched (0 warnings).
    const near = [_]Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 1, .y = 0, .dia = 0.4, .net = 1 },
    };
    const near_res = RouteResult{ .tracks = &.{}, .vias = &near, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 0), returnPathViolations(placement, near_res, RETURN_PATH_RADIUS_MM));
}

// spec: placement/router - stitches each signal via's return path with a nearby GND plane via
test "route stitches a signal escape via with a ground via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // Same single-pin breakout as the escape test, but now the board has a GND
    // net (index 1). The escape drops one signal via; the return-path pass must
    // then add a GND plane via within RETURN_PATH_RADIUS_MM so nothing is left
    // unstitched. Open board, so a DRC-safe stitch spot always exists.
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]FlatNet{
        .{ .name = "EN", .pins = &pins }, // net 0 — the single-pin breakout
        .{ .name = "GND", .pins = &.{} }, // net 1 — the ground plane to stitch to
    };
    const stubs = [_]optimizer.Stub{.{ .part = 0, .ax = 0, .ay = 0, .bx = 2, .by = 0, .net = 0 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &stubs,
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 3,
        .maxy = 2,
        .generated = true,
    };

    const r = try route(arena, placement, .{});

    // The escape via (net 0) plus exactly one stitching GND via (net 1).
    try testing.expectEqual(@as(usize, 2), r.vias.len);
    var sig: ?Via = null;
    var gnd: ?Via = null;
    for (r.vias) |v| {
        if (v.net == 0) sig = v;
        if (v.net == 1) gnd = v;
    }
    try testing.expect(sig != null and gnd != null);
    // The stitch via sits within the return-path radius of the signal via…
    try testing.expect(std.math.hypot(gnd.?.x - sig.?.x, gnd.?.y - sig.?.y) <= RETURN_PATH_RADIUS_MM);
    // …so the routed board reports no return-path discontinuity.
    try testing.expectEqual(@as(usize, 0), returnPathViolations(placement, r, RETURN_PATH_RADIUS_MM));
}

// spec: placement/router - escapes a single-pin breakout to an inner layer with a short stub and a via
test "route escapes a single-pin breakout with a short stub and a via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // One part with a single pad on net EN (index 0) — a single-pin breakout
    // with nothing to connect to. The optimizer reserved a 2 mm corridor along
    // +x; the router should escape it to an inner layer with a short stub + via
    // rather than a full 2 mm surface trace.
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "EN", .pins = &pins }};
    const stubs = [_]optimizer.Stub{.{ .part = 0, .ax = 0, .ay = 0, .bx = 2, .by = 0, .net = 0 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &stubs,
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 3,
        .maxy = 1,
        .generated = true,
    };

    const r = try route(arena, placement, .{});

    // Exactly one via — the escape via — on the breakout's net, dropped close to
    // the pad (a *short* fanout, not the old full-length surface trace) and on the
    // +x escape side the corridor reserved.
    try testing.expectEqual(@as(usize, 1), r.vias.len);
    const v = r.vias[0];
    try testing.expectEqual(@as(i32, 0), v.net);
    try testing.expect(v.x > 0); // fanned out along the +x escape heading
    try testing.expect(std.math.hypot(v.x, v.y) < 1.0); // short hop off the pad

    // The escape track runs from the pad centre to the via and no further.
    var found_stub = false;
    for (r.tracks) |t| {
        if (t.net != 0) continue;
        try testing.expect(@abs(t.x1) < 1e-6 and @abs(t.y1) < 1e-6);
        try testing.expect(@abs(t.x2 - v.x) < 1e-6 and @abs(t.y2 - v.y) < 1e-6);
        found_stub = true;
    }
    try testing.expect(found_stub);

    // The breakout (short stub + via) introduces no clearance violations.
    const viol = try @import("drc.zig").check(arena, placement, r, 0.127);
    try testing.expectEqual(@as(usize, 0), viol.len);
}

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
    var idx = std.StringHashMap(usize).init(testing.allocator);
    defer idx.deinit();
    try idx.put("U1", 0);
    try idx.put("C1", 1);

    const sw_pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const sig_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
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
    var idx = std.StringHashMap(usize).init(arena);
    try idx.put("U1", 0);
    try idx.put("L_VREG", 1);
    try idx.put("C1", 2);

    // VREG_LX: hub pin + inductor pin only — the RP2350-style switch node whose
    // NAME classifies as a power rail (VREG prefix). Must still outrank a
    // many-pin rail like DVDD (hub + inductor + cap = the smoothed output).
    const lx_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L_VREG", .pin = "1" } };
    const rail_pins = [_]export_kicad.FlatPin{
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

// spec: placement/router - names the nets that failed to route in RouteResult.failed
test "route reports an unroutable net by name in failed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // A through-hole wall pad spanning the whole grid height splits the board on
    // BOTH signal layers, so net A (one pad each side) cannot route at all.
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 6.0, .thru = true }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 3.0, .pads = &wall, .fallback = false, .x = 0, .y = 0 },
    };
    const a_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const w_pins = [_]export_kicad.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "WALL", .pins = &w_pins } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 0), r.routed);
    try testing.expectEqual(@as(usize, 1), r.failed.len);
    try testing.expectEqualStrings("A", r.failed[0]);
}

// spec: placement/router - a failed leg's goal is never a same-net source, so a later leg cannot weld to a stranded pad
test "failed leg leaves no stranded island for a later leg to weld onto" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // Same full-height through-hole wall as the failed-net test, but net A now
    // has THREE pads: R1 alone on the left, R2 and R3 together on the right.
    // The seed is R1 (left). Its first leg R1→R2 must cross the wall and fails.
    // Before the fix that failed goal (R2's node) was stamped `occ = A`, so the
    // next leg R1→R3 grew a path R2-node → R3 and welded R3 onto the stranded
    // R2 island — a right-side {R2,R3} blob drawn as if wired to R1, electrically
    // split. With the fix R2's node stays EMPTY, R1→R3 also crosses the wall and
    // fails, and net A emits NO copper at all.
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 6.0, .thru = true }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 1.5 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 3.0, .pads = &wall, .fallback = false, .x = 0, .y = 0 },
    };
    const a_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" }, .{ .ref_des = "R3", .pin = "1" } };
    const w_pins = [_]export_kicad.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "WALL", .pins = &w_pins } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 2.0,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    // Net A cannot bridge the wall, so it is reported failed…
    try testing.expectEqual(@as(usize, 1), r.failed.len);
    try testing.expectEqualStrings("A", r.failed[0]);
    // …and — the invariant under test — emits ZERO copper: no track welds R3 to
    // the stranded R2 node (net A is flattened-index 0).
    var a_tracks: usize = 0;
    for (r.tracks) |t| {
        if (t.net == 0) a_tracks += 1;
    }
    try testing.expectEqual(@as(usize, 0), a_tracks);
}

// spec: placement/router - perNetRouted totals a net's routed copper length and via count
test "perNetRouted totals a net's routed copper length and via count" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    const per = try perNetRouted(arena, placement, r);
    try testing.expectEqual(@as(usize, 1), per.len);
    try testing.expectEqualStrings("SIG", per[0].name);
    try testing.expect(per[0].mm > 0);
    // The aggregate matches a direct sum over SIG's track segments; with only one
    // net on the board, every via is SIG's, so per-net via count == total vias.
    var sum: f64 = 0;
    for (r.tracks) |t| sum += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    try testing.expectApproxEqAbs(sum, per[0].mm, 1e-6);
    try testing.expectEqual(r.vias.len, per[0].vias);
}

// spec: placement/router - rip-up runs no rounds when the greedy pass already routed every net
test "rip-up runs no rounds when the greedy pass routes everything" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    // A cleanly routable board never triggers rip-up (the `anyFailed` guard).
    try testing.expectEqual(r.total, r.routed);
    try testing.expectEqual(@as(usize, 0), r.ripup_rounds);
}

// spec: placement/router - rip-up leaves a wall-blocked net failed without disturbing an already-routed net
test "rip-up leaves a wall-blocked net failed without disturbing a routed net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // A through-hole wall taller than the board+routing-margin grid splits it on
    // both layers with no over-the-top escape. GOOD's two pads sit together on the
    // left (trivially routable); BAD straddles the wall (unroutable). Rip-up runs
    // (BAD failed) but the wall is PADS, not copper, so BAD's blocker probe finds
    // nothing to rip — it must leave GOOD untouched and BAD honestly failed, never
    // welding BAD across the wall.
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 10.0, .thru = true }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -3, .y = -2 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -4, .y = -2 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -3, .y = 2 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = 3, .y = 2 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 3.2, .pads = &wall, .fallback = false, .x = 0, .y = 0 },
    };
    const good_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const bad_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const w_pins = [_]export_kicad.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{
        .{ .name = "GOOD", .pins = &good_pins },
        .{ .name = "BAD", .pins = &bad_pins },
        .{ .name = "WALL", .pins = &w_pins },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -3,
        .maxx = 5,
        .maxy = 3,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 2), r.total); // GOOD + BAD (WALL is single-pad)
    try testing.expectEqual(@as(usize, 1), r.routed); // GOOD routes, BAD can't
    try testing.expectEqual(@as(usize, 1), r.failed.len);
    try testing.expectEqualStrings("BAD", r.failed[0]);
    try testing.expect(r.ripup_rounds >= 1); // rip-up ran (a net failed)
    var good = false;
    var bad_tracks: usize = 0;
    for (r.tracks) |t| {
        if (t.net == 0) good = true; // GOOD copper survived rip-up
        if (t.net == 1) bad_tracks += 1; // BAD emitted no (false) copper
    }
    try testing.expect(good);
    try testing.expectEqual(@as(usize, 0), bad_tracks);
}

// spec: placement/router - escape stubs keep clearance from routed tracks and leave at 45-degree headings
test "escape stub avoids crossing a routed track and stays octilinear" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // U1's single-pin breakout reserves a +x corridor, but a routed SIG track
    // runs vertically right across it at x≈0.5. The stub must not cross SIG:
    // the fan either swivels to a clear 45° heading or stops short of the track.
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.5, .y = -3 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.5, .y = 3 },
    };
    const en_pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const sig_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "EN", .pins = &en_pins }, .{ .name = "SIG", .pins = &sig_pins } };
    const stubs = [_]optimizer.Stub{.{ .part = 0, .ax = 0, .ay = 0, .bx = 2, .by = 0, .net = 0 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &stubs,
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -3.5,
        .maxx = 3,
        .maxy = 3.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});

    var saw_en = false;
    for (r.tracks) |t| {
        if (t.net != 0) continue; // EN copper only
        saw_en = true;
        // Octilinear: the stub's heading is a 45° multiple.
        const ang = std.math.atan2(t.y2 - t.y1, t.x2 - t.x1);
        const rem = @abs(ang - @round(ang / (std.math.pi / 4.0)) * (std.math.pi / 4.0));
        try testing.expect(rem < 0.01);
        // And it never comes within clearance of the foreign SIG copper.
        for (r.tracks) |o| {
            if (o.net != 1 or o.layer != t.layer) continue;
            const d = segSegDist(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }, .{ o.x1, o.y1 }, .{ o.x2, o.y2 });
            try testing.expect(d >= t.width / 2 + o.width / 2 + 0.127 - 1e-9);
        }
    }
    try testing.expect(saw_en);
}

// spec: placement/router - escapes a fine-pitch pad through an off-grid gateway stub when no grid lane clears
test "pad gateway routes a pad whose flanking grid columns are inside neighbour clearance" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // A mini fine-pitch pad row (0.4 mm pitch, 0.2 mm pads): the target pad's
    // axis sits at x = −0.095, exactly BETWEEN two grid columns (−0.222 and
    // 0.032 for this bbox), and both columns are 0.173 mm from a neighbour
    // pad — inside the 0.1905 mm reach. Every node the maze could start from
    // is therefore blocked: without the off-grid gateway stub this net cannot
    // route at all; with it, the stub leaves the pad centre along its axis
    // (0.3 mm lateral to the neighbours, always clear) to the first free node.
    const pin_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.6 }};
    const tgt_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .passive, .hw = 0.15, .hh = 0.35, .pads = &pin_pad, .fallback = false, .x = -0.095, .y = 0 },
        .{ .ref_des = "W1", .kind = .passive, .hw = 0.15, .hh = 0.35, .pads = &pin_pad, .fallback = false, .x = -0.495, .y = 0 },
        .{ .ref_des = "W2", .kind = .passive, .hw = 0.15, .hh = 0.35, .pads = &pin_pad, .fallback = false, .x = 0.305, .y = 0 },
        .{ .ref_des = "R9", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &tgt_pad, .fallback = false, .x = -0.095, .y = 2.5 },
    };
    const a_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R9", .pin = "1" } };
    const b_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "W1", .pin = "1" }, .{ .ref_des = "W2", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "B", .pins = &b_pins } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1.5,
        .maxy = 3.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 2), r.total);
    try testing.expectEqual(@as(usize, 2), r.routed);
    try testing.expectEqual(@as(usize, 0), r.failed.len);
}

// spec: placement/router - a hemmed breakout keeps its stub clear of foreign pads instead of crossing them
test "escape stub falls back to a trimmed clear stub when every heading is pad-blocked" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // A breakout pad at the origin ringed by eight foreign pads, one on each
    // 45° compass heading at 0.7 mm — every escape ray passes through foreign
    // copper, so no DRC-safe stub+via exists. The old relaxed tier would have
    // dropped a via beyond the ring with the stub crossing a ring pad (the
    // QFN-neighbour overlap bug); now the breakout must keep a short trimmed
    // stub that stays fully clear, and the routed board must be DRC-clean.
    // Ring pads are 0.3 mm wide so adjacent ring pads keep pad↔pad clearance
    // between THEMSELVES — the only thing under test is the escape stub.
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const ring_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0.7, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0.495, .y = 0.495 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0, .y = 0.7 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = -0.495, .y = 0.495 },
        .{ .ref_des = "R5", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = -0.7, .y = 0 },
        .{ .ref_des = "R6", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = -0.495, .y = -0.495 },
        .{ .ref_des = "R7", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0, .y = -0.7 },
        .{ .ref_des = "R8", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0.495, .y = -0.495 },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "EN", .pins = &pins }};
    const stubs = [_]optimizer.Stub{.{ .part = 0, .ax = 0, .ay = 0, .bx = 2, .by = 0, .net = 0 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &stubs,
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    // No DRC-safe escape exists — no via may be dropped…
    try testing.expectEqual(@as(usize, 0), r.vias.len);
    // …and whatever trimmed stub remains keeps full clearance from every
    // foreign pad (this is the assertion the old pad-crossing tier failed).
    // This fixture packs the ring pads tighter than the solver ever would (to
    // starve every escape heading), so the diagonal courtyards intentionally
    // overlap — every violation here is a courtyard overlap, and the COPPER
    // clearance this test is about is clean (0 non-courtyard findings).
    const drc = @import("drc.zig");
    const viol = try drc.check(arena, placement, r, 0.127);
    try testing.expectEqual(viol.len, drc.countKind(viol, .courtyard));
}

// spec: placement/router - reserves diagonal corner cells so later nets keep trace-to-trace clearance
test "a routed diagonal reserves its corner cells against foreign nets only" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Bare 20×20 grid, no pads: route net 0 along a pure 45° diagonal, then
    // check the squeeze-past corner cells of every step are reserved — blocked
    // for a foreign net, open for the owner, and never Dijkstra sources (resv,
    // not occ).
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    const occ = try allocLayerGrids(arena, 2, nodes);
    const resv = try allocLayerGrids(arena, 2, nodes);
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.1905,
        .occ = occ,
        .resv = resv,
        .params = .{},
        .base = .{},
        .index_reach = 0.1905,
    };
    var tracks: std.ArrayListUnmanaged(Track) = .empty;
    var vias: std.ArrayListUnmanaged(Via) = .empty;
    // Drive the maze directly (no pad gateways): seed net 0 at (2,2), route to
    // (6,6) — the unique shortest path is the pure 45° diagonal.
    ctx.occ[0][grid.node(2, 2)] = 0;
    const goals = [_]usize{grid.node(6, 6)}; // layer 0 ⇒ key == node index
    const hit = try dijkstra(&ctx, 0, &goals, &.{}, &tracks, &vias);
    try testing.expect(hit != null);

    // Each diagonal step (i,i)→(i+1,i+1) squeezes past corners (i+1,i) and
    // (i,i+1) — all must now be reserved for net 0: blocked for a foreign net,
    // open for the owner, and never copper (occ stays EMPTY).
    try testing.expect(diagCornersReserved(&ctx, 2, 6, 0));
}

/// Loop body of the diagonal-reservation test, hoisted so the test itself
/// stays conditional-free: checks every corner cell of the (lo,lo)→(hi,hi)
/// diagonal is reserved for `net`, blocked to a foreign net, passable to the
/// owner, and not stamped as copper.
fn diagCornersReserved(ctx: *Ctx, lo: usize, hi: usize, net: i32) bool {
    const grid = ctx.grid;
    var i: usize = lo;
    while (i < hi) : (i += 1) {
        const c1 = grid.node(i + 1, i);
        const c2 = grid.node(i, i + 1);
        if (ctx.resv[0][c1] != net or ctx.resv[0][c2] != net) return false;
        if (!blocked(ctx, 0, c1, net + 1)) return false; // foreign net must be blocked
        if (blocked(ctx, 0, c1, net)) return false; // owner must stay passable
        if (ctx.occ[0][c1] != EMPTY) return false; // reserved ≠ copper
    }
    return true;
}
