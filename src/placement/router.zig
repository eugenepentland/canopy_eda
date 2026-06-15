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
//! no rip-up, so congested boards can leave nets unrouted (reported in
//! `RouteResult.failed`). It's aimed at module-scale boards. Coordinates are
//! millimetres, y-down (KiCad convention).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const module_policy = @import("module_policy.zig");
const pad_shape = @import("pad_shape.zig");
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
/// (`poly`; empty ⇒ the box is exact) and the net it belongs to. The maze pass
/// rasterises the box; the clearance checks measure against the outline.
pub const PadObs = struct { x0: f64, y0: f64, x1: f64, y1: f64, poly: []const [2]f64 = &.{}, net: i32 };

/// A routed copper segment. `layer` 0 = top, 1 = bottom signal. `net` is the
/// flattened-net index it carries (for the design-rule check).
pub const Track = struct { x1: f64, y1: f64, x2: f64, y2: f64, layer: u8, width: f64, net: i32 };

/// A via (drawn as the pad ring; spans the layers it connects). `net` is the
/// flattened-net index it belongs to (for the design-rule check).
pub const Via = struct { x: f64, y: f64, dia: f64, net: i32 };

/// Router output: the copper, plus how many nets routed of the total tried.
pub const RouteResult = struct {
    tracks: []const Track,
    vias: []const Via,
    routed: usize,
    total: usize,
};

/// Largest grid (nodes per layer) the router will attempt — keeps a huge board
/// from allocating an enormous grid; modules stay far under this.
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

/// Route `placement` under `params`. All output is allocated in `arena`.
pub fn route(arena: std.mem.Allocator, placement: optimizer.Placement, params: RouteParams) std.mem.Allocator.Error!RouteResult {
    var tracks: std.ArrayListUnmanaged(Track) = .empty;
    var vias: std.ArrayListUnmanaged(Via) = .empty;

    // ref-des → part index, for resolving each net pin to a pad.
    var idx_of = std.StringHashMap(usize).init(arena);
    for (placement.parts, 0..) |p, i| try idx_of.put(p.ref_des, i);

    const g = @max(params.track_width + params.clearance, 0.05);
    const margin = 1.0;
    const ox = placement.minx - margin;
    const oy = placement.miny - margin;
    const nx: usize = @intFromFloat(@ceil((placement.maxx - placement.minx + 2 * margin) / g) + 1);
    const ny: usize = @intFromFloat(@ceil((placement.maxy - placement.miny + 2 * margin) / g) + 1);
    if (nx * ny == 0 or nx * ny > MAX_NODES) {
        return .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    }
    const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

    // Routed-copper occupancy per signal layer (one net per grid line ⇒
    // adjacent lines are track+clearance apart, satisfying trace-to-trace DRC).
    const occ = [2][]i32{ try arena.alloc(i32, nx * ny), try arena.alloc(i32, nx * ny) };
    @memset(occ[0], EMPTY);
    @memset(occ[1], EMPTY);

    // Pad obstacles: *every* pad's rectangle + its net — including pads on no
    // net (net −1), so a via/trace keeps clearance from NC/mechanical pads too.
    // Mirrors `drc.zig`'s pad set exactly, so what the router avoids is exactly
    // what the DRC checks.
    const obs = try buildObstacles(arena, placement.parts, placement.nets);

    // Route each net. Ground → plane vias; others → maze on the signal layers.
    const reach = params.track_width / 2 + params.clearance;
    var ctx = Ctx{ .arena = arena, .grid = grid, .obs = obs, .reach = reach, .occ = occ, .params = params };
    var routed: usize = 0;
    var total: usize = 0;

    // Pass 1: ground/plane nets. Each ground pad drops a via to the GND plane.
    // The via is placed where it keeps full via-clearance from every *foreign*
    // pad (and any via already down) — preferring the pad centre, else fanning
    // outward into open copper and joining it with a short same-net stub, so the
    // via can't crowd a neighbouring pad (the classic DFN/QFN via-in-pad fail).
    // Each placed via's clearance halo is stamped into the routing grid on *both*
    // signal layers, so the maze pass routes foreign copper around it.
    for (placement.nets, 0..) |net, net_i| {
        const pts = try netPoints(arena, placement, &idx_of, net);
        if (pts.len < 2) continue;
        if (!isGroundName(shortName(net.name))) continue;
        total += 1;
        const ni: i32 = @intCast(net_i);
        for (pts) |c| {
            const pos = findGroundVia(&ctx, vias.items, c, ni) orelse continue;
            try vias.append(arena, .{ .x = pos[0], .y = pos[1], .dia = params.via_dia, .net = ni });
            if (@abs(pos[0] - c[0]) > 1e-6 or @abs(pos[1] - c[1]) > 1e-6) {
                try tracks.append(arena, .{ .x1 = c[0], .y1 = c[1], .x2 = pos[0], .y2 = pos[1], .layer = 0, .width = params.track_width, .net = ni });
                stampStubOcc(&ctx, c, pos, ni);
            }
            stampViaOcc(&ctx, pos[0], pos[1], ni);
        }
        routed += 1;
    }

    // Pass 2: every other multi-pad net, maze-routed on the two signal layers,
    // now detouring the ground vias stamped in pass 1. Nets are routed in
    // declared `(placement-order …)` priority (highest first) so a high-priority
    // rail claims the short path before a low-priority signal can block it — the
    // router has no rip-up, so first-routed wins. Within a priority tier the
    // switching hot loop (switch-node / input-rail nets) routes ahead of the
    // pack, so a discrete switcher's loop claims the tightest copper even when
    // the author declared no `(placement-order …)`. Remaining ties keep net order.
    const net_pri = try arena.alloc(u32, placement.nets.len);
    for (placement.nets, 0..) |net, i| net_pri[i] = netPriority(placement, &idx_of, net);
    var order: std.ArrayListUnmanaged(usize) = .empty;
    for (placement.nets, 0..) |net, net_i| {
        if (isGroundName(shortName(net.name))) continue;
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
    for (order.items) |net_i| {
        const pts = try netPoints(arena, placement, &idx_of, placement.nets[net_i]);
        if (pts.len < 2) continue;
        total += 1;
        const ni: i32 = @intCast(net_i);
        // …and only for *short* nets (a feedback tap, a strap — a handful of
        // pads), which almost always have a clear surface path. A short net with
        // no top path rolls back and re-routes with layer changes, same as before.
        if (top_first and pts.len <= TOP_FIRST_MAX_PADS) {
            const t_mark = tracks.items.len;
            const v_mark = vias.items.len;
            ctx.allow_vias = false;
            ctx.use_poly = true; // accurate outlines so an EP notch frees the escape
            const top_ok = try routeNet(&ctx, ni, pts, &tracks, &vias);
            ctx.allow_vias = true;
            ctx.use_poly = false;
            if (top_ok) {
                routed += 1;
                continue;
            }
            tracks.shrinkRetainingCapacity(t_mark);
            vias.shrinkRetainingCapacity(v_mark);
            clearNetOcc(&ctx, ni);
        }
        if (try routeNet(&ctx, ni, pts, &tracks, &vias)) routed += 1;
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
        const a = optimizer.worldPadCenter(part, st.ax, st.ay);
        const b = optimizer.worldPadCenter(part, st.bx, st.by);
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const dl = std.math.hypot(dx, dy);
        const dir: [2]f64 = if (dl > 1e-9) .{ dx / dl, dy / dl } else .{ 1, 0 };
        if (findEscapeVia(&ctx, vias.items, tracks.items, a, dir, st.net)) |vp| {
            try tracks.append(arena, .{ .x1 = a[0], .y1 = a[1], .x2 = vp[0], .y2 = vp[1], .layer = 0, .width = params.track_width, .net = st.net });
            try vias.append(arena, .{ .x = vp[0], .y = vp[1], .dia = params.via_dia, .net = st.net });
            continue;
        }
        // Too hemmed in for any DRC-safe via — fall back to the trimmed surface stub.
        const end = trimStub(&ctx, vias.items, a, b, st.net);
        if (@abs(end[0] - a[0]) < 1e-6 and @abs(end[1] - a[1]) < 1e-6) continue;
        try tracks.append(arena, .{ .x1 = a[0], .y1 = a[1], .x2 = end[0], .y2 = end[1], .layer = 0, .width = params.track_width, .net = st.net });
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
            const n_signal = vias.items.len;
            for (0..n_signal) |i| {
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
                try vias.append(arena, .{ .x = pos[0], .y = pos[1], .dia = params.via_dia, .net = gnet });
                stampViaOcc(&ctx, pos[0], pos[1], gnet);
            }
        }
    }

    return .{
        .tracks = try tracks.toOwnedSlice(arena),
        .vias = try vias.toOwnedSlice(arena),
        .routed = routed,
        .total = total,
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

    const g = @max(params.track_width + params.clearance, 0.05);
    const margin = 1.0;
    const ox = placement.minx - margin;
    const oy = placement.miny - margin;
    const nx: usize = @intFromFloat(@ceil((placement.maxx - placement.minx + 2 * margin) / g) + 1);
    const ny: usize = @intFromFloat(@ceil((placement.maxy - placement.miny + 2 * margin) / g) + 1);
    if (nx * ny == 0 or nx * ny > MAX_NODES) return &.{};
    const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

    const occ = [2][]i32{ try arena.alloc(i32, nx * ny), try arena.alloc(i32, nx * ny) };
    @memset(occ[0], EMPTY);
    @memset(occ[1], EMPTY);
    const obs = try buildObstacles(arena, placement.parts, placement.nets);
    const reach = params.track_width / 2 + params.clearance;
    var ctx = Ctx{ .arena = arena, .grid = grid, .obs = obs, .reach = reach, .occ = occ, .params = params };

    for (placement.nets, 0..) |net, net_i| {
        const pts = try netPoints(arena, placement, &idx_of, net);
        if (pts.len < 2) continue;
        if (!isGroundName(shortName(net.name))) continue;
        const ni: i32 = @intCast(net_i);
        for (pts) |c| {
            const pos = findGroundVia(&ctx, vias.items, c, ni) orelse continue;
            try vias.append(arena, .{ .x = pos[0], .y = pos[1], .dia = params.via_dia, .net = ni });
            // Stamp the same occupancy `route` would, so the *next* via avoids this
            // one identically (the via positions depend on placement order).
            if (@abs(pos[0] - c[0]) > 1e-6 or @abs(pos[1] - c[1]) > 1e-6) stampStubOcc(&ctx, c, pos, ni);
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

        const occ = [2][]i32{ try arena.alloc(i32, nx * ny), try arena.alloc(i32, nx * ny) };

        // Every pad is an obstacle tagged with its net — same indexing as `route`
        // (absolute position in `nets`), so a leg routed on net N treats N's pads
        // as passable (its own copper) and all others as obstacles to detour.
        const obs = try buildObstacles(arena, parts, nets);

        const reach = params.track_width / 2 + params.clearance;
        return .{
            .ctx = .{ .arena = arena, .grid = grid, .obs = obs, .reach = reach, .occ = occ, .params = params },
            .ready = true,
        };
    }

    /// Real routed copper length (mm) from world point `cap_c` to `hub_c` on net
    /// `net_id` (their shared rail), detouring foreign pads. Null when the maze
    /// can't connect them (boxed in) or the router isn't ready.
    pub fn legLen(self: *LoopRouter, cap_c: [2]f64, hub_c: [2]f64, net_id: i32) std.mem.Allocator.Error!?f64 {
        if (!self.ready or net_id < 0) return null;
        @memset(self.ctx.occ[0], EMPTY);
        @memset(self.ctx.occ[1], EMPTY);
        var tracks: std.ArrayListUnmanaged(Track) = .empty;
        var vias: std.ArrayListUnmanaged(Via) = .empty;
        var pts = [_][2]f64{ cap_c, hub_c };
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
            try obs.append(arena, .{ .x0 = sh.x0, .y0 = sh.y0, .x1 = sh.x1, .y1 = sh.y1, .poly = sh.poly, .net = net });
        }
    }
    return obs.toOwnedSlice(arena);
}

/// Bits reserved for the intrinsic net-class rank in a net's sort key. Explicit
/// `(placement-order …)` priority occupies the high bits and always dominates;
/// the net-class rank only orders nets the author left unranked and breaks ties
/// between equal-ranked ones. Three bits leaves headroom for `(net-class …)`
/// overrides (Phase 4); the auto rule below uses only ranks 0–1.
const NETCLASS_BITS = 3;

/// A net's routing priority. Primary key: the highest `(placement-order …)` rank
/// among the parts it touches (0 when none is ranked). Secondary key (the low
/// `NETCLASS_BITS` bits): the net's intrinsic routing criticality inferred from
/// its name (Phase 3 of the module-placement ruleset) — the switcher hot loop and
/// its input rail route ahead of the pack. Routing the hot loop first lets it
/// claim the tightest copper before a bulk net blocks it (the router has no
/// rip-up, so first-routed wins), even when the author declared no
/// `(placement-order …)`.
fn netPriority(placement: optimizer.Placement, idx_of: *std.StringHashMap(usize), net: FlatNet) u32 {
    var best: u32 = 0;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        if (pi < placement.priority.len and placement.priority[pi] > best) best = placement.priority[pi];
    }
    return (best << NETCLASS_BITS) | netClassRank(net.name);
}

/// Intrinsic routing-order rank for a net from its name-based `NetClass`
/// (0 = baseline, 1 = route first). Only the switching hot loop and its input
/// rail are elevated. Those net names exist solely on a switching power module,
/// so this is a no-op on signal/array boards — which is precisely why it never
/// regresses them — while on a discrete switcher it gives the hot loop the
/// tightest copper. Clock/RF/feedback/power are deliberately *not* elevated:
/// reordering them trades total routed length board-by-board (it helps a
/// clock-sparse board and hurts a clock-dense array), a tradeoff the scalar
/// routed metric can't adjudicate, so they stay at the baseline tier.
fn netClassRank(name: []const u8) u32 {
    return switch (module_policy.classifyNetName(name)) {
        .switch_node, .input_rail => 1,
        else => 0,
    };
}

/// Sort net indices by descending priority, with the net index itself as a
/// stable tiebreaker (so equal-priority nets keep their original order).
fn priorityDesc(pri: []const u32, a: usize, b: usize) bool {
    if (pri[a] != pri[b]) return pri[a] > pri[b];
    return a < b;
}

/// World centres (mm) of every resolvable pad on `net`.
fn netPoints(arena: std.mem.Allocator, placement: optimizer.Placement, idx_of: *std.StringHashMap(usize), net: FlatNet) std.mem.Allocator.Error![][2]f64 {
    var list: std.ArrayListUnmanaged([2]f64) = .empty;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        const c = padCenter(placement.parts[pi], pin.pin) orelse continue;
        try list.append(arena, c);
    }
    return list.toOwnedSlice(arena);
}

/// World centre of `pin` on `part`, or null if the pad isn't in the footprint.
fn padCenter(part: Part, pin: []const u8) ?[2]f64 {
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, pin)) return optimizer.worldPadCenter(part, pad.x, pad.y);
    }
    return null;
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

/// True if point `p` (a `track_width` trace's centreline) keeps clearance from
/// every foreign pad.
fn ptClearsPads(ctx: *Ctx, p: [2]f64, net: i32) bool {
    const need = ctx.params.track_width / 2 + ctx.params.clearance;
    for (ctx.obs) |o| {
        if (o.net == net) continue;
        if (pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, p[0], p[1], need) < need - 1e-9) return false;
    }
    return true;
}

/// True if the same-net stub segment a→b (a real `track_width` trace) keeps
/// clearance from every foreign pad along its length (sampled).
fn segClearsPads(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32) bool {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / (ctx.grid.g * 0.5)))));
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        if (!ptClearsPads(ctx, .{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) }, net)) return false;
    }
    return true;
}

/// Longest clear prefix of escape stub a→b on net `net`: the farthest point
/// from the pad `a` such that the whole sub-segment keeps clearance from every
/// foreign pad and via. Returns `a` itself when even the first step isn't clear
/// (the caller then drops the stub) — a single-pin breakout has nothing to
/// connect to, so trimming it never breaks a real connection.
fn trimStub(ctx: *Ctx, placed: []const Via, a: [2]f64, b: [2]f64, net: i32) [2]f64 {
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
/// from the pad to the via. Two tiers: first the nearest spot whose pad→via stub
/// also stays clear of foreign pads (a clean hand-route, the normal case); then,
/// if the pad is so hemmed in that *no* straight stub stays clear — the dense
/// power-module case that is exactly why you'd escape to an inner layer — the
/// nearest spot where at least the via itself is DRC-safe, accepting the short
/// stub crossing the relieved thermal/EP copper beside the pad. Null only when no
/// DRC-safe via spot exists in the search window at all (caller keeps the trimmed
/// surface stub).
fn findEscapeVia(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, dir: [2]f64, net: i32) ?[2]f64 {
    return escapeFan(ctx, placed, tracks, a, dir, net, true) orelse
        escapeFan(ctx, placed, tracks, a, dir, net, false);
}

/// One fan of the escape-via search (see `findEscapeVia`). Fans outward from the
/// pad `a` in growing grid rings, preferring the reserved corridor heading `dir`
/// then swivelling to either side, and returns the first grid spot where a via of
/// the configured size clears every foreign pad, via and routed track. When
/// `clear_stub` is set the straight pad→via stub must also clear every foreign
/// pad. Mirrors `findGroundVia`'s fan, but seeded along the escape heading and
/// additionally clearing routed tracks (it runs after the maze pass).
fn escapeFan(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, dir: [2]f64, net: i32, clear_stub: bool) ?[2]f64 {
    const grid = ctx.grid;
    const ang0 = std.math.atan2(dir[1], dir[0]);
    var ring: usize = 1;
    while (ring <= ESCAPE_VIA_RINGS) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 12) : (k += 1) {
            const ang = ang0 + swivel(k);
            const s = grid.snap(a[0] + rad * @cos(ang), a[1] + rad * @sin(ang));
            if (!viaClearsPads(ctx, s[0], s[1], net)) continue;
            if (!viaClearsVias(ctx, placed, s[0], s[1], net)) continue;
            if (!viaClearsTracks(ctx, tracks, s[0], s[1], net)) continue;
            // The stub itself must clear every already-placed via — those vias
            // are fixed and won't re-check this trace, so the pair would fail DRC.
            if (!segClearsVias(ctx, placed, a, s, net)) continue;
            if (clear_stub and !segClearsPads(ctx, a, s, net)) continue;
            return s;
        }
    }
    return null;
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

/// Index of the first ground net (by name), or null when the board has none —
/// then there's no plane to stitch to and the stitch pass is skipped.
fn firstGroundNet(placement: optimizer.Placement) ?i32 {
    for (placement.nets, 0..) |net, i| {
        if (isGroundName(shortName(net.name))) return @intCast(i);
    }
    return null;
}

/// Claim every empty grid node within `dist` (mm) of (x,y) for `net` — on the
/// top layer, and on both layers when `both`. Existing copper is never
/// overwritten. Used to reserve a via/stub's clearance halo so the maze pass
/// keeps foreign copper away from it.
fn stampDisc(ctx: *Ctx, x: f64, y: f64, net: i32, dist: f64, both: bool) void {
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
            if (ctx.occ[0][n] == EMPTY) ctx.occ[0][n] = net;
            if (both and ctx.occ[1][n] == EMPTY) ctx.occ[1][n] = net;
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

/// Reserve a placed via's clearance halo on both signal layers.
fn stampViaOcc(ctx: *Ctx, x: f64, y: f64, net: i32) void {
    stampDisc(ctx, x, y, net, copperHalo(ctx), true);
}

/// Reserve a top-layer ground-via stub's clearance halo along its length, so a
/// foreign via can't be dropped on top of the stub.
fn stampStubOcc(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32) void {
    const grid = ctx.grid;
    const d = copperHalo(ctx);
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / (grid.g * 0.5)))));
    var s: usize = 0;
    while (s <= steps) : (s += 1) {
        const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
        stampDisc(ctx, a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), net, d, false);
    }
}

/// May a layer-changing via be dropped at node `n` for net `net`? It must clear
/// foreign pads by the via clearance and have no foreign copper within its halo
/// on either layer — so a maze via can never crowd a pad or an already-routed
/// foreign track/via.
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
            if (ctx.occ[0][m] != EMPTY and ctx.occ[0][m] != net) return false;
            if (ctx.occ[1][m] != EMPTY and ctx.occ[1][m] != net) return false;
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
    occ: [2][]i32,
    params: RouteParams,
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
};

/// True if node (layer, n) can't carry net `net`: copper of another net is
/// there, or (on top) a foreign pad is within clearance. A node sitting on the
/// net's *own* pad is always allowed (that's where the trace must connect).
fn blocked(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    const o = ctx.occ[layer][n];
    if (o != EMPTY and o != net) return true;
    if (layer != 0) return false; // pads (and their clearance) live on top
    const px = ctx.grid.worldX(n % ctx.grid.nx);
    const py = ctx.grid.worldY(n / ctx.grid.nx);
    var on_own = false;
    var foreign = false;
    for (ctx.obs) |p| {
        // Measure clearance against the pad's real copper outline only when asked
        // (the top-first pass): a concave thermal/EP pad over-states copper in its
        // box, walling off a corridor a short net could escape through — which is
        // exactly what buries a feedback tap beside an EP and forces it inner. The
        // outline test is costly, so the bulk maze keeps the cheap box distance.
        const d = if (ctx.use_poly)
            pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, px, py, ctx.reach)
        else
            distPointRect(px, py, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1 });
        if (p.net == net) {
            if (d <= 1e-9) on_own = true;
        } else if (d < ctx.reach) {
            foreign = true;
        }
    }
    return foreign and !on_own;
}

const QItem = struct { d: f64, key: usize }; // key = layer*nodes + node
fn qLess(_: void, a: QItem, b: QItem) std.math.Order {
    return std.math.order(a.d, b.d);
}

/// Connect every pad of one net by repeatedly maze-routing the next pad to the
/// net's routed-so-far copper. Returns true if all pads were joined.
fn routeNet(ctx: *Ctx, net: i32, pts: [][2]f64, tracks: *std.ArrayListUnmanaged(Track), vias: *std.ArrayListUnmanaged(Via)) std.mem.Allocator.Error!bool {
    // Seed the net with its first pad's access node (top layer).
    const p0 = ctx.grid.nearest(pts[0][0], pts[0][1]);
    ctx.occ[0][ctx.grid.node(p0[0], p0[1])] = net;

    var all_ok = true;
    for (pts[1..]) |pt| {
        const goal = ctx.grid.nearest(pt[0], pt[1]);
        const goal_key = ctx.grid.node(goal[0], goal[1]); // top-layer key
        if (try dijkstra(ctx, net, goal_key, tracks, vias)) {
            // path already stamped + emitted by dijkstra
        } else {
            all_ok = false;
            // Still mark the goal pad as occupied so later pads can target it.
            ctx.occ[0][goal_key] = net;
        }
    }
    // The maze routes between pad *access nodes* (nearest grid node); add a
    // short stub from each pad's true centre to its access node so the copper
    // begins and ends in the centre of the pad, not a grid point beside it.
    for (pts) |pt| try addStub(ctx, net, pt, tracks);
    return all_ok;
}

/// Reset every grid node this net stamped back to EMPTY. Used to undo a failed
/// top-layer-only attempt before re-routing the net with vias allowed — since a
/// net only ever stamps its own index, clearing `occ == net` leaves every other
/// net's copper untouched.
fn clearNetOcc(ctx: *Ctx, net: i32) void {
    for (0..2) |layer| {
        for (ctx.occ[layer]) |*c| {
            if (c.* == net) c.* = EMPTY;
        }
    }
}

/// Append a top-layer stub from pad centre `pt` to its grid access node, if
/// they differ (the maze trace continues from that node).
fn addStub(ctx: *Ctx, net: i32, pt: [2]f64, tracks: *std.ArrayListUnmanaged(Track)) std.mem.Allocator.Error!void {
    const a = ctx.grid.nearest(pt[0], pt[1]);
    const ax = ctx.grid.worldX(a[0]);
    const ay = ctx.grid.worldY(a[1]);
    if (@abs(ax - pt[0]) < 1e-6 and @abs(ay - pt[1]) < 1e-6) return;
    try tracks.append(ctx.arena, .{ .x1 = pt[0], .y1 = pt[1], .x2 = ax, .y2 = ay, .layer = 0, .width = ctx.params.track_width, .net = net });
}

/// Dijkstra from all of net's current copper (occ==net) to `goal_key` (a top
/// node). On success, stamps the path as the net's copper and emits the
/// tracks/vias. Returns false if unreachable.
fn dijkstra(ctx: *Ctx, net: i32, goal_key: usize, tracks: *std.ArrayListUnmanaged(Track), vias: *std.ArrayListUnmanaged(Via)) std.mem.Allocator.Error!bool {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const dist = try ctx.arena.alloc(f64, 2 * nodes);
    const prev = try ctx.arena.alloc(i64, 2 * nodes);
    @memset(dist, std.math.inf(f64));
    @memset(prev, -1);

    var pq = std.PriorityQueue(QItem, void, qLess).init(ctx.arena, {});
    // Sources: every node already owned by this net, on either signal layer.
    for (0..2) |layer| {
        for (0..nodes) |n| {
            if (ctx.occ[layer][n] == net) {
                const k = layer * nodes + n;
                dist[k] = 0;
                try pq.add(.{ .d = 0, .key = k });
            }
        }
    }

    var found_key: ?usize = null;
    while (pq.removeOrNull()) |it| {
        if (it.d > dist[it.key]) continue;
        const layer = it.key / nodes;
        const n = it.key % nodes;
        if (layer == 0 and n == goal_key) {
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
        // Via to the other signal layer at the same (ix,iy) — only where a via
        // of the configured size keeps clearance from foreign pads and copper,
        // and only when this pass permits layer changes at all.
        if (ctx.allow_vias and viaAllowed(ctx, n, net))
            try relaxStep(ctx, &pq, dist, prev, net, it.key, 1 - layer, n, grid.g * VIA_COST_MULT);
    }

    const goal = found_key orelse return false;
    try emitPath(ctx, prev, goal, net, tracks, vias);
    return true;
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
    const nd = dist[from_key] + step;
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
fn emitPath(
    ctx: *Ctx,
    prev: []i64,
    goal_key: usize,
    net: i32,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
) std.mem.Allocator.Error!void {
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
    if (ks.len < 2) return;
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
            try vias.append(ctx.arena, .{ .x = vx, .y = vy, .dia = ctx.params.via_dia, .net = net });
            stampViaOcc(ctx, vx, vy, net); // reserve its halo for later nets
            run_start = i;
        } else if (i >= 2 and !sameDir(grid, nodes, ks[i - 2], ks[i - 1], ks[i])) {
            try emitSeg(ctx, tracks, ks[run_start], ks[i - 1], net);
            run_start = i - 1;
        }
    }
    try emitSeg(ctx, tracks, ks[run_start], ks[ks.len - 1], net);
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

// ── Small helpers (mirror optimizer.zig) ───────────────────────────────────

fn isGroundName(name: []const u8) bool {
    const grounds = [_][]const u8{ "GND", "GNDA", "AGND", "PGND", "DGND", "GNDD", "VSS", "VSSA" };
    for (grounds) |gg| {
        if (std.mem.eql(u8, name, gg)) return true;
    }
    return false;
}

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

// spec: placement/router - lets explicit (placement-order …) priority dominate the intrinsic net-class rank
test "netPriority ranks the hot loop first yet keeps placement-order dominant" {
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

    // With no `(placement-order …)`, the hot-loop net outranks the bulk signal.
    try testing.expect(netPriority(base, &idx, sw) > netPriority(base, &idx, sig));

    // Declare a high `(placement-order …)` rank on the signal's part: explicit
    // author intent now wins, even though the hot loop still carries its class bit.
    var pri = [_]u32{ 0, 5 }; // U1 (hot loop) unranked, C1 (signal) ranked 5
    var ranked = base;
    ranked.priority = &pri;
    try testing.expect(netPriority(ranked, &idx, sig) > netPriority(ranked, &idx, sw));
}
