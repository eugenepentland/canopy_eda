//! The maze search itself — Dijkstra/A* over the routing raster, and the pad
//! gateways that get a leg on and off that raster.
//!
//! `router.zig` decides WHICH connection to attempt and with what policy;
//! this file answers one attempt. It owns:
//!
//!   * `dijkstra` — one leg's bounded best-first search: seed the sources,
//!     expand under `relaxStep`'s cost model (vias, pours, preferred layers,
//!     diff-pair corridors, reference guides, RF shadow, congestion), and
//!     emit the winning path as real copper (`emitPath` / `emitSeg`).
//!   * the cost model's per-step pricing and the admissible A* heuristic,
//!     plus `expansionBudget` — how many node expansions one leg may buy.
//!   * `padGateways` / `gateStub` — the off-grid fan that lets a fine-pitch
//!     pad reach the lattice at all, priced by `GateAnchors` so the search
//!     pays for the escape stub it implies.
//!   * `trimBuriedStart`, `weldToNetCopper` and `OctiJoin` — the geometry
//!     that pulls a leg's ends out of foreign copper and welds them onto the
//!     net's own.
//!
//! Split out of `router.zig` verbatim (2026-09-05).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const octilinear = @import("octilinear.zig");
const manhattan_route = @import("manhattan_route.zig");
const net_topology = @import("net_topology.zig");
const maze_scratch = @import("maze_scratch.zig");
const congestion = @import("congestion.zig");
const pad_shape = @import("pad_shape.zig");
const pad_exit = @import("pad_exit.zig");
const plane_via = @import("plane_via.zig");
const lane_reserve = @import("lane_reserve.zig");
const rf_shadow = @import("rf_shadow.zig");
const route_grid = @import("route_grid.zig");
const route_timeline = @import("route_timeline.zig");
const route_result = @import("route_result.zig");
const router_support = @import("router_support.zig");
const via_rules = @import("router_via_rules.zig");
const router = @import("router.zig");
const pad_grid = @import("pad_grid.zig");
const router_ctx = @import("router_ctx.zig");

const RouteParams = router_support.RouteParams;
const PadObs = pad_grid.PadObs;
const Track = route_result.Track;
const Via = route_result.Via;

// The routing context and its board model (see `router_ctx.zig`).
const Ctx = router_ctx.Ctx;
const Grid = router_ctx.Grid;
const NetPt = router_ctx.NetPt;
const clearance_eps = router_ctx.clearance_eps;
const empty_cell = router_ctx.empty_cell;
const gate_rings = router_ctx.gate_rings;
const sqrt2 = router_ctx.sqrt2;
const allocLayerGrids = router_ctx.allocLayerGrids;
const blocked = router_ctx.blocked;
const copperHalo = router_ctx.copperHalo;
const foreignPadAt = router_ctx.foreignPadAt;
const layerInMask = router_ctx.layerInMask;
const moveClearsCopper = router_ctx.moveClearsCopper;
const segClearsPadsOnLayer = router_ctx.segClearsPadsOnLayer;
const segClearsTracks = router_ctx.segClearsTracks;
const segClearsVias = router_ctx.segClearsVias;
const stampCurrentRf = router_ctx.stampCurrentRf;
const stampCurrentRfVia = router_ctx.stampCurrentRfVia;
const stampKeepoutPadsForNet = router_ctx.stampKeepoutPadsForNet;
const stampStubOcc = router_ctx.stampStubOcc;
const stampTrackResv = router_ctx.stampTrackResv;
const stampViaOcc = router_ctx.stampViaOcc;
const trimStub = router_ctx.trimStub;
const viaAllowed = router_ctx.viaAllowed;
const viaCopperRule = router_ctx.viaCopperRule;

// The cost model's multipliers and the direct-synthesis geometry this search
// reuses, both still owned by `router.zig`.
const via_cost_mult = router.via_cost_mult;
const pour_cost_mult = router.pour_cost_mult;
const inner_cost_mult = router.inner_cost_mult;
const preferred_layer_cost_mult = router.preferred_layer_cost_mult;
const diff_corridor_mult = router.diff_corridor_mult;
const diff_via_on_ring_mult = router.diff_via_on_ring_mult;
const diff_via_off_ring_mult = router.diff_via_off_ring_mult;
const reference_corridor_mult = router.reference_corridor_mult;
const reference_via_mult = router.reference_via_mult;
const reference_off_via_mult = router.reference_off_via_mult;
const DirectPath = router.DirectPath;
const axisExitDogleg = router.axisExitDogleg;
const clearDoglegSegment = router.clearDoglegSegment;
const emitDogleg = router.emitDogleg;
const RipNet = router.RipNet;
const routeCancelled = router.routeCancelled;
const saveSnapshot = router.saveSnapshot;
const restoreSnapshot = router.restoreSnapshot;
const searchWasLimited = router.searchWasLimited;
const unguidedExpansionLimit = router.unguidedExpansionLimit;
const max_escalated_expansions = router.max_escalated_expansions;
const max_last_resort_expansions = router.max_last_resort_expansions;

/// Collect the off-grid gateway nodes of pad terminal `pt`: grid nodes within
/// `GATE_RINGS` of the pad centre that are themselves routable AND reachable
/// from the pad centre by ONE straight stub keeping true clearance from every
/// foreign pad, placed via, and routed track. Along a pad's own axis such a
/// stub always clears its row neighbours (the lateral gap is fixed by the pad
/// pitch), so a fine-pitch pin keeps an exit even when every nearby grid node
/// sits inside a neighbour's clearance. Keys are appended to `out` (deduped).
pub fn padGateways(ctx: *Ctx, tracks: []const Track, vias: []const Via, pt: NetPt, net: i32, out: *std.ArrayList(usize)) std.mem.Allocator.Error!void {
    if (ctx.timing) |t| t.begin(.gateways);
    defer if (ctx.timing) |t| t.end(.gateways);
    // Escape-constrained nets prefer gateways along the pad's outward axis —
    // the stub IS the start of the straight escape. If that filtered fan
    // yields nothing (a hemmed fine-pitch pad), fall back to the full fan:
    // routability wins and the bend smoother's reserve flags the residual.
    const escape = ctx.rf.escape_mm > 0 and (pt.out[0] != 0 or pt.out[1] != 0);
    const before = out.items.len;
    const scan = GateScan{ .ctx = ctx, .tracks = tracks, .vias = vias, .pt = pt, .net = net };
    try padGatewayFan(scan, out, escape);
    if (escape and out.items.len == before)
        try padGatewayFan(scan, out, false);
}

/// One pad terminal's gateway scan context (see `padGateways`).
const GateScan = struct {
    ctx: *Ctx,
    tracks: []const Track,
    vias: []const Via,
    pt: NetPt,
    net: i32,
};

fn padGatewayFan(
    scan: GateScan,
    out: *std.ArrayList(usize),
    escape_aligned_only: bool,
) std.mem.Allocator.Error!void {
    const ctx = scan.ctx;
    const grid = ctx.grid;
    const c = [2]f64{ scan.pt.x, scan.pt.y };
    const dir = plane_via.fanDir(ctx.obs, c, scan.net);
    var ring: usize = 1;
    while (ring <= ctx.gate_rings) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const ang = octilinear.compass45(std.math.atan2(dir[1], dir[0]), k);
            if (escape_aligned_only) {
                const along = @cos(ang) * scan.pt.out[0] + @sin(ang) * scan.pt.out[1];
                if (along < escape_align_min) continue;
            }
            const nd = grid.nearest(c[0] + rad * @cos(ang), c[1] + rad * @sin(ang));
            const n = grid.node(nd[0], nd[1]);
            const key = @as(usize, scan.pt.layer) * grid.nx * grid.ny + n;
            if (std.mem.indexOfScalar(usize, out.items, key) != null) continue;
            if (blocked(ctx, scan.pt.layer, n, scan.net)) continue;
            const s = [2]f64{ grid.worldX(nd[0]), grid.worldY(nd[1]) };
            const gateway_len = std.math.hypot(s[0] - c[0], s[1] - c[1]);
            const saved_width = router_support.usePadGateway(&ctx.params, gateway_len);
            const clears = segClearsPadsOnLayer(ctx, c, s, scan.net, null) and
                segClearsVias(ctx, scan.vias, c, s, scan.net) and
                segClearsTracks(ctx, scan.tracks, c, s, scan.net, scan.pt.layer);
            ctx.params.track_width = saved_width;
            if (!clears) continue;
            try out.append(ctx.arena, key);
        }
    }
}

/// Pull a leg's copper off a pad-buried start. `stampStubOcc`/`stampViaOcc` mark
/// this net's clearance HALO, not just its centreline, so Dijkstra can seed a leg
/// at a node a FOREIGN land swallows — and `emitSeg` then draws the run's first
/// segment out of that land (barracuda's `LMX_VTUNE` over `U17`'s ground pad, and
/// three rail stubs grazing their neighbours' ground pads).
///
/// Refusing the seed is the obvious fix and the wrong one: `tryMazeTerminalTree`
/// gives up on the WHOLE net when one leg cannot reach the net's copper, which
/// measured at nine lost nets and double the route time on barracuda. So keep the
/// route and shorten the copper — trim the source-end segment back to its first
/// clearing point (`trimStub` walked from the far end). The leg stays routed, the
/// illegal metal is gone, and the residue is a sub-millimetre gap the (probed)
/// weld closes when it can and `net_open` names when it cannot. Returns the leg's
/// new start, or the node's own point when it was legal to begin with.
pub fn trimBuriedStart(
    ctx: *Ctx,
    net: i32,
    key: usize,
    from: usize,
    tracks: *std.ArrayList(Track),
    vias: []const Via,
) [2]f64 {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const layer: u8 = @intCast(key / nodes);
    const n = key % nodes;
    const w = [2]f64{ grid.worldX(n % grid.nx), grid.worldY(n / grid.nx) };
    if (!foreignPadAt(ctx, layer, n, net)) return w;
    for (tracks.items[from..]) |*t| {
        if (t.net != net or t.layer != layer) continue;
        const at_head = @abs(t.x1 - w[0]) < clearance_eps and @abs(t.y1 - w[1]) < clearance_eps;
        const at_tail = @abs(t.x2 - w[0]) < clearance_eps and @abs(t.y2 - w[1]) < clearance_eps;
        if (!at_head and !at_tail) continue;
        const far = if (at_head) [2]f64{ t.x2, t.y2 } else [2]f64{ t.x1, t.y1 };
        // Nothing clears ⇒ `kept` lands on `far`, collapsing the segment to a
        // degenerate stub that `dropDegenerateTracks` sweeps up at the end.
        const kept = trimStub(ctx, vias, tracks.items, far, w, net, layer);
        if (at_head) {
            t.x1 = kept[0];
            t.y1 = kept[1];
        } else {
            t.x2 = kept[0];
            t.y2 = kept[1];
        }
        return kept;
    }
    return w;
}

/// Bridge a later maze leg's weld node to the net's EXISTING copper. A leg after
/// the first seeds Dijkstra from every `occ==net` node and welds at whichever it
/// reaches — but `stampStubOcc` / `stampViaOcc` mark `occ==net` out to the copper
/// CLEARANCE halo (`copperHalo`), not just the copper edge, so the weld node can
/// sit a fraction of a grid pitch OFF the real centreline. The leg's emitted path
/// starts exactly at that node, so without this the two legs' copper share no
/// metal — a fab-fatal open the router's grid model reads as connected (the
/// `net_open` DRC catches it downstream). Emit the short same-net segment from the
/// weld node to the nearest point on copper that existed BEFORE this leg
/// (`tracks[0..prior]`, same signal layer) so the centrelines physically meet. The
/// gap lies inside the net's own reserved halo, and the bridge is probed before
/// it is drawn, so it can add no foreign-clearance violation; it never changes
/// which path Dijkstra found (routed counts and every other DRC stay identical).
pub const Weld = struct {
    ctx: *Ctx,
    net: i32,
    /// Where the leg's copper actually starts (post-`trimBuriedStart`).
    at: [2]f64,
    layer: u8,
    /// Mark in `tracks` before this leg — everything below it is prior copper.
    prior: usize,
    tracks: *std.ArrayList(Track),
    vias: []const Via,
};

pub fn weldToNetCopper(weld: Weld) std.mem.Allocator.Error!void {
    const ctx = weld.ctx;
    const net = weld.net;
    const w = weld.at;
    const layer = weld.layer;
    const prior = weld.prior;
    const tracks = weld.tracks;
    const vias = weld.vias;
    var best: f64 = std.math.inf(f64);
    var bx: f64 = 0;
    var by: f64 = 0;
    for (tracks.items[0..prior]) |t| {
        if (t.net != net or t.layer != layer) continue;
        const c = pad_shape.closestOnSeg(t.x1, t.y1, t.x2, t.y2, w[0], w[1]);
        if (c.d < best) {
            best = c.d;
            bx = c.x;
            by = c.y;
        }
    }
    // Bridge only a genuine near-miss: the weld already sits ON same-layer
    // copper (centre within one track width ⇒ overlapping metal) needs nothing;
    // farther than the copper-clearance halo means the weld is via-connected to
    // another layer (a via stamps `occ==net` on every layer at its node) or is a
    // real gap the ratsnest owns — either way a long bridge would be wrong. Only
    // the (track_width, copperHalo] band is a stub-halo weld to close.
    // Deliberately NOT routed through the `OctiJoin` seam: this is the one join
    // that must not stamp an occupancy halo (stamping would let a later leg of
    // the same net weld to it in turn). It spans at most one copper halo, so the
    // residual off-axis copper is a few tenths of a millimetre.
    //
    // PROBED, though. The old "it lies inside our own reserved halo, so it adds
    // no foreign-clearance violation" reasoning only ever held for foreign
    // COPPER (which the halo did detour) — a foreign PAD is not stamped into
    // anything and can sit squarely across the bridge. Emitting a violating weld
    // trades a visible open for an invisible fab-blocking short, so the bridge
    // now has to clear like every other segment; when it can't, the leg simply
    // stays unwelded and `net_open` reports it.
    if (best > ctx.params.track_width and best <= copperHalo(ctx)) {
        const path = DirectPath{ .ctx = ctx, .net = net, .layer = layer, .tracks = tracks.items, .vias = vias };
        if (!clearDoglegSegment(path, w, .{ bx, by })) return;
        try tracks.append(ctx.arena, .{ .x1 = w[0], .y1 = w[1], .x2 = bx, .y2 = by, .layer = layer, .width = ctx.params.track_width, .net = net });
        stampCurrentRf(ctx, w, .{ bx, by }, net, layer);
    }
}

/// The seam every off-raster endpoint joins the board through: a pad centre or
/// a plane-via site, neither of which sits on the maze grid, so the naive
/// segment between them lands at whatever angle the offset happens to be. Each
/// is short, but there is roughly one per pad, and each seeds a chain that then
/// reads non-octilinear to every later pass. Supplies both the clearance probe
/// and the segment emitter for `octilinear.emitJoin`.
pub const OctiJoin = struct {
    ctx: *Ctx,
    net: i32,
    layer: u8,
    placed_vias: []const Via,
    tracks: *std.ArrayList(Track),

    /// DRC-grade clearance for one candidate leg, against foreign pads,
    /// placed vias, and foreign copper on this layer.
    pub fn clear(self: OctiJoin, a: [2]f64, b: [2]f64) bool {
        return segClearsPadsOnLayer(self.ctx, a, b, self.net, null) and
            segClearsVias(self.ctx, self.placed_vias, a, b, self.net) and
            segClearsTracks(self.ctx, self.tracks.items, a, b, self.net, self.layer);
    }

    /// Does the whole prefix `a`→`b` meet the *fabrication* rule — the exact
    /// track↔pad / track↔via / track↔track clearances the DRC re-checks, with
    /// the DRC's layer semantics (an SMD pad obstructs only its own side, a
    /// through pad every layer)? Deliberately NOT the same predicate as
    /// `clear`: that one is layer-blind, which is the right *chooser* (it keeps
    /// an elbow off the opposite face's lands too) but the wrong *gate* — a
    /// join refused on it alone would drop copper the board would happily fab.
    fn fabricable(self: OctiJoin, a: [2]f64, b: [2]f64) bool {
        return segClearsPadsOnLayer(self.ctx, a, b, self.net, self.layer) and
            segClearsVias(self.ctx, self.placed_vias, a, b, self.net) and
            segClearsTracks(self.ctx, self.tracks.items, a, b, self.net, self.layer);
    }

    /// The farthest point along `a`→`b` whose whole prefix is `fabricable`, or
    /// null when not even a sliver leaving `a` clears.
    ///
    /// Prefix clearance is monotone in the fraction kept (shortening a segment
    /// can only remove approaches), so a bisection is exact rather than a
    /// sampling approximation, and it costs `join_trim_probes` probes instead
    /// of one per grid step.
    fn trimmed(self: OctiJoin, a: [2]f64, b: [2]f64) ?[2]f64 {
        if (self.fabricable(a, b)) return b;
        const at = struct {
            fn point(p: [2]f64, q: [2]f64, t: f64) [2]f64 {
                return .{ p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1]) };
            }
        }.point;
        var lo: f64 = 0;
        var hi: f64 = 1;
        for (0..join_trim_probes) |_| {
            const mid = (lo + hi) / 2;
            if (self.fabricable(a, at(a, b, mid))) lo = mid else hi = mid;
        }
        const kept = at(a, b, lo);
        if (std.math.hypot(kept[0] - a[0], kept[1] - a[1]) < octilinear.min_heading_mm) return null;
        return kept;
    }

    /// Append one join segment and reserve its occupancy halo, so later nets
    /// detour copper the grid itself cannot see.
    ///
    /// TRIMMED to the fabricable prefix first. `emitJoin` has two paths that
    /// reach here with copper nothing ever probed — an already-octilinear pair
    /// (never a candidate, so `elbow` returns before probing it) and the
    /// direct-segment fallback taken when neither elbow clears — and this is
    /// the join every pad centre and plane-via site leaves the board through.
    /// On barracuda that drew `V_1V8A` out of `adf4159/C116.1` straight at the
    /// cap's own GND pad, 0.094 mm into a 0.127 mm rule. An elbow leg that
    /// `clear` already approved is untouched (that test is strictly stronger
    /// than this one), so only the unprobed paths change: they now stop at the
    /// violation instead of crossing it, and a pad whose centre cannot even
    /// start a legal stub emits nothing. An honestly open net is a better
    /// outcome than a fab-blocking short — the open is visible to `net_open`,
    /// the short is not.
    pub fn seg(self: OctiJoin, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
        const end = self.trimmed(a, b) orelse return;
        try self.tracks.append(self.ctx.arena, .{
            .x1 = a[0],
            .y1 = a[1],
            .x2 = end[0],
            .y2 = end[1],
            .layer = self.layer,
            .width = self.ctx.params.track_width,
            .net = self.net,
        });
        stampStubOcc(self.ctx, a, end, self.net, self.layer);
        stampCurrentRf(self.ctx, a, end, self.net, self.layer);
    }
};

/// Bisection steps `OctiJoin.trimmed` spends locating the fabricable prefix.
/// 24 halvings resolve a 5 mm join to under a nanometre — far below the
/// clearance epsilon, so the kept end is exact for every practical purpose.
const join_trim_probes: usize = 24;

/// Emit the stub joining pad terminal `pt`'s true centre to the entry node
/// `key` the maze actually used. The pad centre is off-raster by construction,
/// so it goes through the `OctiJoin` seam to keep its heading on the compass.
pub fn gateStub(
    ctx: *Ctx,
    net: i32,
    pt: NetPt,
    key: usize,
    placed_vias: []const Via,
    tracks: *std.ArrayList(Track),
) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const layer: u8 = @intCast(key / nodes);
    const n = key % nodes;
    const w = [2]f64{ grid.worldX(n % grid.nx), grid.worldY(n / grid.nx) };
    const path = DirectPath{ .ctx = ctx, .net = net, .layer = layer, .tracks = tracks.items, .vias = placed_vias };
    const join = OctiJoin{ .ctx = ctx, .net = net, .layer = layer, .placed_vias = placed_vias, .tracks = tracks };
    // The axis-only attempt joins its pads through the SAME seam, on an L rather
    // than the axis-then-45° elbow. A refusal is deliberately not fatal here: the
    // ordinary join still runs, and the off-axis copper it then draws is what
    // makes `manhattan_route` decline the whole route rather than ship a trace
    // that is not what it claims to be.
    if (ctx.manhattan.active and try manhattan_route.axisStub(join, .{ pt.x, pt.y }, w)) return;
    if (axisExitDogleg(path, pt, w)) |dogleg| {
        try emitDogleg(path, .{ pt.x, pt.y }, w, dogleg, tracks);
        return;
    }
    try octilinear.emitJoin(.{ pt.x, pt.y }, w, join);
}

/// Reset every grid node this net stamped back to EMPTY. Used to undo a failed
/// top-layer-only attempt before re-routing the net with vias allowed — since a
/// net only ever stamps its own index, clearing `occ == net` (and its diagonal
/// corner reservations) leaves every other net's copper untouched.
pub fn clearNetOcc(ctx: *Ctx, net: i32) void {
    for (ctx.occ, ctx.resv) |occ_l, resv_l| {
        for (occ_l, resv_l) |*o, *r| {
            if (o.* == net) o.* = empty_cell;
            if (r.* == net) r.* = empty_cell;
        }
    }
    // The net's keepout halo goes with its copper — a ripped-up RF trace must not
    // leave a phantom exclusion zone behind for every net routed after it — and
    // each halo node's GATE goes with the node, or a later stamp would inherit a
    // stale opening it never asked for.
    for (ctx.keep.layers, 0..) |keep_l, layer| {
        const gate_l: ?[]i32 = if (layer < ctx.keep.gate.len) ctx.keep.gate[layer] else null;
        for (keep_l, 0..) |*c, n| {
            if (c.* != net) continue;
            c.* = empty_cell;
            if (gate_l) |g| g[n] = empty_cell;
        }
    }
    // Component pads are permanent guarded copper, not routed copper. Restore
    // their exact halos after removing this net's track/via stamps.
    stampKeepoutPadsForNet(ctx, net);
    // `resv` reset 5/6, the same idea one line up: ripping a net's tracks must
    // not also hand its reserved corridor to whoever routes next.
    lane_reserve.stamp(ctx.reserved_lanes, ctx.resv, ctx.grid, net);
    ctx.shadow.clearNet(net);
}
/// The pad centres whose `padGateways` fan produced the keys one maze leg is
/// handed, so `dijkstra` can PRICE the escape stub each of those keys implies.
///
/// A gateway is not a free way into the grid: whichever one the path uses,
/// `gateStub` afterwards draws real copper from the pad's centre out to it. The
/// search used to see none of that — every gateway was a dist-0 source, and any
/// popped goal was accepted at whatever dist it carried and added nothing — so
/// the fan's outermost ring was the cheapest entry the maze could buy in EVERY
/// direction, including straight away from the target. Measured on
/// `bcuda-lt3045-ldo`: `C_VOUT` left its pad 0.51 mm (ring 2) on the heading
/// opposite its partner and then turned 45° back across itself, and that
/// wrong-way stub was permanent, because no later pass may LENGTHEN copper to
/// straighten what the search chose.
///
/// With an anchor the leg pays for what it draws: `hypot(pad, key)`, the
/// straight-line length of that stub. That is a LOWER bound on the copper
/// `gateStub` actually lays (an off-axis join mitres, an axis dogleg turns), so
/// charging it can only under-state the price — which is exactly what keeps it
/// safe against a search whose A* heuristic must stay admissible.
///
/// A null anchor prices nothing, so a caller whose keys are not a pad fan (zone
/// copper, a seeded via, a stitch's via sites) searches as it always did.
const GateAnchors = struct { source: ?NetPt = null, goal: ?NetPt = null };

/// One maze leg's two ends: the keys it may finish ON, the keys it may grow FROM
/// beyond the net's own copper, and the pad fans (if any) those key sets belong
/// to — the anchors that turn a key into a priced escape rather than a free one.
pub const MazeEnds = struct {
    goals: []const usize,
    sources: []const usize = &.{},
    anchors: GateAnchors = .{},
};

/// What entering or leaving the maze at grid key `k` costs when `anchor` names
/// the pad the key's fan surrounds — 0 for an unanchored key. See `GateAnchors`.
///
/// Through the SAME lens the leg's own steps are priced by: `scale` is the
/// lowest multiplier any of them can be discounted by (`routeHeuristic`), so a
/// stub is comparable with the lattice run it is competing against. Charging a
/// raw millimetre against steps a coupling corridor has halved would price the
/// escape out of every discount the leg exists to take — measured on the
/// diff-pair fixture, where the N net stopped detouring toward its P twin at all.
fn gateStubCost(grid: Grid, nodes: usize, anchor: ?NetPt, k: usize, scale: f64) f64 {
    const pt = anchor orelse return 0;
    const n = k % nodes;
    return std.math.hypot(grid.worldX(n % grid.nx) - pt.x, grid.worldY(n / grid.nx) - pt.y) * scale;
}

/// Where a successful maze leg entered and left the grid: `goal` is the goal
/// key it reached (plain access node or pad gateway), `source` the seeded key
/// the path grew from — the caller stubs the pad centres onto both. `start` is
/// where the leg's copper ACTUALLY begins: `source`'s own point normally, or
/// the trimmed point when that source sat inside a foreign land (see the
/// buried-source repair at the end of `dijkstra`). A caller that welds the leg
/// to the net's earlier copper must bridge from `start`, not from `source`.
pub const DijkstraHit = struct { goal: usize, source: usize, start: [2]f64 };

const RoutePq = maze_scratch.RoutePq;

const MazeSearch = struct {
    pq: *RoutePq,
    state: maze_scratch.State,
    heuristic: RouteHeuristic,
    /// Turn tie-break inputs, resolved once per search (`octilinear.turned`).
    lattice: octilinear.Lattice,
};

const RouteHeuristic = route_grid.Heuristic;

/// This leg's A* estimate. The scale is the LOWEST multiplier any step of the
/// leg can be discounted by — 0.1× inside a reference corridor, 0.5× inside a
/// pair corridor, 0.05× in both — which is what keeps the Euclidean estimate
/// admissible while it still points somewhere useful.
pub fn routeHeuristic(ctx: *Ctx, goals: []const usize, nodes: usize) RouteHeuristic {
    const reference_scale: f64 = if (ctx.reference_corridor != null) reference_corridor_mult else 1;
    const pair_scale: f64 = if (ctx.corridor != null) diff_corridor_mult else 1;
    return route_grid.heuristic(ctx.grid, goals, nodes, reference_scale * pair_scale);
}

pub fn recordSearchLimit(ctx: *Ctx, net: i32) std.mem.Allocator.Error!void {
    if (net < 0) return;
    const net_i: usize = @intCast(net);
    if (!searchWasLimited(ctx, net_i)) try ctx.search_limited.append(ctx.arena, net_i);
}

/// Drop `net_i` from the search-limited set — called when the escalation retry
/// finally routes a leg that the greedy pass had left budget-limited, so the
/// reported set names only nets that are *still* search-limited.
pub fn clearSearchLimit(ctx: *Ctx, net_i: usize) void {
    var i: usize = 0;
    while (i < ctx.search_limited.items.len) {
        if (ctx.search_limited.items[i] == net_i) _ = ctx.search_limited.swapRemove(i) else i += 1;
    }
}

/// Inputs that size one maze leg's node-expansion budget: the whole-board
/// `base` (`unguidedExpansionLimit`), whether the net carries a straight
/// pad-escape reserve, whether the post-greedy retry phase escalated this leg,
/// and whether a diff-pair coupling corridor confines it.
pub const BudgetInput = struct {
    base: usize,
    escape_active: bool,
    /// 0 = no escalation; otherwise the escalated per-leg expansion budget for
    /// this retry (the `max_escalated_expansions` or `max_last_resort_expansions`
    /// tier). A larger value widens both the plain and the corridor-capped search.
    escalate: usize,
    corridor: bool,
    /// This leg follows a soft reference guide (`setNetReferenceGuide`), which
    /// discounts on-guide steps to 0.1x — and therefore drops the A* heuristic
    /// to the same 0.1x to stay admissible (`routeHeuristic`). A near-Dijkstra
    /// search expands far more nodes for the same path, so a guided leg on the
    /// whole-board budget runs out of expansions on a path an unguided leg
    /// finds easily: the guide is meant to shape the route, not to make it fail.
    /// Measured on barracuda, where guiding a net set cost nets it had routed
    /// unguided. Guided legs therefore take the targeted floor, like escapes.
    guided: bool = false,
};

/// The bounded node-expansion budget for one maze leg. Escape-forced and
/// escalated legs search wider; a coupling corridor caps the search tightly (a
/// narrow band converges fast) unless escalation also widens that cap.
pub fn expansionBudget(in: BudgetInput) usize {
    const escape_limit = if (in.escape_active or in.guided)
        @max(in.base, route_grid.max_targeted_expansions)
    else
        in.base;
    const ordinary = if (in.escalate > 0)
        @max(escape_limit, in.escalate)
    else
        escape_limit;
    if (!in.corridor) return ordinary;
    const cap = if (in.escalate > 0) in.escalate else route_grid.max_pair_corridor_expansions;
    return @min(ordinary, cap);
}

/// Seed one maze leg's Dijkstra frontier: every node this net already owns, plus
/// the seed pad's gateway fan, each at what it costs to START there.
///
/// The `occ == net` scan is deliberately NOT filtered by `foreignPadAt`, though a
/// stamped node CAN be illegal copper (the halo reaches past the centreline).
/// Dropping those sources does remove the resulting violations, but measured on
/// barracuda it costs NINE connected nets and doubles the route time:
/// `tryMazeTerminalTree` fails the whole net when one leg cannot reach the net's
/// existing copper, and those failures cascade into rip-up escalation. Seeding
/// only the legal marks when any exist measured identical — the legs that die
/// need the buried cluster specifically, not just some legal source.
/// `trimBuriedStart` handles it at the other end instead: the leg routes, and its
/// copper is pulled back off the land it started in.
///
/// PRICES (see `GateAnchors`): a gateway costs the stub that reaches it, and so
/// does the seed pad's own ACCESS node — that node is a mark in `occ` like any
/// other, but `gateStub` still draws copper from the pad centre out to it, and
/// leaving the one reachable entry free would price the whole fan against a zero
/// that is not real. Every OTHER mark is copper that already exists and costs
/// nothing to stand on.
fn seedMazeSources(ctx: *Ctx, net: i32, ends: MazeEnds, search: MazeSearch) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const anchor = ends.anchors.source;
    const seed_key: ?usize = if (anchor) |pt| blk: {
        const nd = grid.nearest(pt.x, pt.y);
        break :blk @as(usize, pt.layer) * nodes + grid.node(nd[0], nd[1]);
    } else null;
    for (0..ctx.occ.len) |layer| {
        var cursor: usize = 0;
        while (std.mem.findScalarPos(i32, ctx.occ[layer], cursor, net)) |n| {
            const k = layer * nodes + n;
            var at = net_topology.sourceCost(ctx.join_lands, grid.worldX(n % grid.nx), grid.worldY(n / grid.nx));
            if (seed_key == k) at += gateStubCost(grid, nodes, anchor, k, search.heuristic.scale);
            try search.state.settle(k, at, -1);
            try search.pq.add(.{ .f = at + search.heuristic.estimate(grid, n), .d = at, .key = k });
            cursor = n + 1;
        }
    }
    for (ends.sources) |k| {
        const at = gateStubCost(grid, nodes, anchor, k, search.heuristic.scale);
        if (at < search.state.dist[k]) {
            try search.state.settle(k, at, -1);
            try search.pq.add(.{ .f = at + search.heuristic.estimate(grid, k % nodes), .d = at, .key = k });
        }
    }
}

/// Dijkstra from all of net's current copper (occ==net) plus `ends.sources`
/// (the seed pad's gateways) to the CHEAPEST key in `ends.goals` (full
/// layer*nodes+node keys). On success, stamps the path as the net's copper,
/// emits the tracks/vias, and reports which goal/source the path used.
///
/// "Cheapest" counts the escape stubs, not just the lattice path: with
/// `ends.anchors` naming the pad a fan belongs to, a source gateway is seeded at
/// the length of the stub `gateStub` will draw to reach it, and a goal is
/// accepted on `dist + its own stub` (`GateAnchors`). Without anchors every stub
/// is zero and the search is the pre-pricing one to the bit.
pub fn dijkstra(
    ctx: *Ctx,
    net: i32,
    ends: MazeEnds,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!?DijkstraHit {
    const goals = ends.goals;
    const anchors = ends.anchors;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    // Mark in `tracks` before this leg — the buried-source repair below only
    // ever rewrites copper this leg drew, and a welding caller bridges to what
    // sits below the mark.
    const prior = tracks.items.len;
    const n_layers = ctx.occ.len;
    const search_nodes = n_layers * nodes;
    const state = try ctx.search.begin(ctx.arena, search_nodes);
    const dist = state.dist;
    const prev = state.prev;
    // Goal keys span one narrow band of the key space (a terminal pad's access
    // nodes), so a range test rejects almost every pop before the membership
    // scan runs at all. Same predicate, same `found_key`; with no goals the
    // range is empty and the test is false, exactly as the scan was.
    //
    // `goal_stub_min` rides along: the cheapest stub in the whole goal fan, and
    // so the OPTIMALITY bound of the priced accept below.
    const heuristic = routeHeuristic(ctx, goals, nodes);
    var goal_lo: usize = std.math.maxInt(usize);
    var goal_hi: usize = 0;
    var goal_stub_min: f64 = std.math.inf(f64);
    for (goals) |goal| {
        goal_lo = @min(goal_lo, goal);
        goal_hi = @max(goal_hi, goal);
        goal_stub_min = @min(goal_stub_min, gateStubCost(grid, nodes, anchors.goal, goal, heuristic.scale));
    }
    if (ctx.route_queue == null) ctx.route_queue = RoutePq.init(ctx.arena, {});
    const pq = &ctx.route_queue.?;
    pq.clearRetainingCapacity();
    const search = MazeSearch{
        .pq = pq,
        .state = state,
        .heuristic = heuristic,
        .lattice = .{
            .nx = grid.nx,
            .nodes = nodes,
            .prev = prev,
            .enabled = ctx.corridor == null and ctx.reference_corridor == null,
        },
    };
    try seedMazeSources(ctx, net, ends, search);

    // An escape-forced net lost its direct-synthesis shortcut and pays soft
    // penalties around both terminals, so its search legitimately expands more
    // nodes: `expansionBudget` gives it the targeted budget. Escape nets are the
    // few RF nets of a board, so the extra allowance stays bounded. An escalated
    // retry searches wider still; a coupling corridor caps the search tightly.
    const expansion_limit = expansionBudget(.{
        .base = unguidedExpansionLimit(ctx.selected_nets),
        .escape_active = escapeActive(ctx),
        .escalate = ctx.escalate_budget,
        .corridor = ctx.corridor != null and ctx.reference_corridor == null,
        .guided = ctx.reference_corridor != null,
    });
    var expansions: usize = 0;
    // Whole-run counters: every leg's expansion count and the leg itself, so
    // `bench-route --breakdown` can divide greedy time by expansions to expose
    // the per-expansion cost. The `defer` reads the loop's final count.
    if (ctx.timing) |t| t.begin(.maze);
    if (ctx.timing) |t| t.maze_legs += 1;
    defer if (ctx.timing) |t| {
        t.end(.maze);
        t.maze_expansions += expansions;
    };
    var found_key: ?usize = null;
    // The best `dist + goal stub` accepted so far, and the OPTIMALITY invariant
    // that lets the leg stop: every goal still unpopped costs at least the heap
    // minimum `f` to reach — A* admissibility over a goal region where `h` is
    // zero, so a goal's own priority IS its cost paid — and at least
    // `goal_stub_min` to leave. Once `f + goal_stub_min` reaches `found_total`,
    // nothing left in the queue can beat it, and every goal that could TIE it
    // has already been popped. An unanchored leg prices every stub at zero, so
    // the test fires on the first goal popped: the pre-pricing search, exactly.
    var found_total: f64 = std.math.inf(f64);
    while (pq.removeOrNull()) |it| {
        if (it.d > dist[it.key]) continue;
        // A single maze leg may consume hundreds of thousands of expansions;
        // polling only between nets can overshoot an authored board deadline
        // by minutes. Match the direct-probe cadence without timing every node.
        if ((expansions & 1023) == 0 and routeCancelled(ctx)) return null;
        const layer = it.key / nodes;
        const n = it.key % nodes;
        if (it.key >= goal_lo and it.key <= goal_hi and
            std.mem.indexOfScalar(usize, goals, it.key) != null)
        {
            // A goal pops at its FINAL dist (a stale entry was skipped above), so
            // this is the one chance to price it. A STRICT improvement is required
            // to displace an equal earlier one, so the winner is a function of the
            // queue order alone — the same board still routes byte-identically.
            const total = it.d + gateStubCost(grid, nodes, anchors.goal, it.key, heuristic.scale);
            if (total < found_total) {
                found_total = total;
                found_key = it.key;
            }
        }
        if (found_key != null and it.f + goal_stub_min >= found_total) break;
        if (expansions >= expansion_limit) {
            // A budget that runs out AFTER a goal was accepted has not failed the
            // leg: `found_total` is already the best any remaining key could tie,
            // it is simply no longer proven optimal. Ship it rather than throwing
            // a routed leg away over the last few expansions.
            if (found_key != null) break;
            try recordSearchLimit(ctx, net);
            return null;
        }
        expansions += 1;
        const ix = n % grid.nx;
        const iy = n / grid.nx;
        // Same-layer 4-neighbours (orthogonal, cost g).
        const from = it.key;
        for ([4][2]i64{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d|
            try relaxStep(ctx, search, net, from, layer, neighbor(grid, ix, iy, d[0], d[1]), grid.g);
        // Same-layer diagonals (45° bends, cost g·√2). Guarded against
        // corner-cutting, and skipped outright while the RF axis-only attempt
        // owns the search — there is no 45° step for it to find.
        if (!ctx.manhattan.active) for ([4][2]i64{ .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } }) |d|
            try relaxDiag(ctx, search, net, from, layer, ix, iy, d[0], d[1]);
        // Via to every OTHER signal layer at the same (ix,iy) — vias are
        // through-only, so one drill reaches them all at the same cost. Only
        // where a via of the configured size keeps clearance from foreign
        // pads and copper, and only when this pass permits layer changes.
        // (On a 2-signal board this is exactly the old `1 - layer` step.)
        if (ctx.allow_vias and n_layers > 1 and viaAllowed(ctx, n, net, vias.items)) {
            // The lattice price for a layer change, under whatever ceiling the
            // caller set (`Ctx.via_cost_cap_mm`; null = the price to the bit).
            const lattice = grid.g * via_cost_mult;
            const via_step = if (ctx.via_cost_cap_mm) |cap| @min(lattice, cap) else lattice;
            for (0..n_layers) |to_layer| if (to_layer != layer)
                try relaxStep(ctx, search, net, from, to_layer, n, via_step);
        }
    }

    const goal = found_key orelse return null;
    const source = (try emitPath(ctx, prev, goal, net, tracks, vias)) orelse return null;
    // The SOURCE is the one node on the path the search never had to prove
    // legal. Every other node was relaxed into through `relaxStep`, which
    // refuses a `blocked` node — but a source is seeded at dist 0 from the
    // `occ == net` scan above, and `occ` carries this net's clearance HALO
    // (`stampStubOcc` / `stampViaOcc` / `stampDisc`), not just its centreline.
    // A halo node can therefore sit inside a FOREIGN pad's clearance, and
    // `emitPath` then draws the leg's last run ending exactly on it — copper
    // that fails the `track_pad` DRC by construction.
    //
    // Repairing it HERE, at the one seam every maze pass returns through, is
    // what makes the guarantee hold for all of them. The trim used to live at
    // the terminal tree's own call site, so every OTHER pass — the pour
    // terminal (`routeNetToZone`), the gap hops, the via-seeded retries — had
    // none. Measured on barracuda: two `V_5VA` legs out of `routeNetToZone`
    // ended on grid nodes inside a `hmc733` ground land and an `ldo_3v3a`
    // divider pad, and no later pass removed them.
    const start = trimBuriedStart(ctx, net, source, prior, tracks, vias.items);
    return .{ .goal = goal, .source = source, .start = start };
}

/// Resolve a 4-neighbour node index, or null at the grid edge.
pub fn neighbor(grid: Grid, ix: usize, iy: usize, dx: i64, dy: i64) ?usize {
    const x = @as(i64, @intCast(ix)) + dx;
    const y = @as(i64, @intCast(iy)) + dy;
    if (x < 0 or y < 0 or x >= grid.nx or y >= grid.ny) return null;
    return @as(usize, @intCast(y)) * grid.nx + @as(usize, @intCast(x));
}

pub const Pq = maze_scratch.Pq;

fn relaxStep(
    ctx: *Ctx,
    search: MazeSearch,
    net: i32,
    from_key: usize,
    to_layer: usize,
    to_node: ?usize,
    step: f64,
) std.mem.Allocator.Error!void {
    const tn = to_node orelse return;
    if (!layerInMask(ctx.allowed_layers, @intCast(to_layer))) return;
    if (blocked(ctx, to_layer, tn, net)) return;
    if (!moveClearsCopper(ctx, net, from_key, to_layer, tn)) return;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const to_key = to_layer * nodes + tn;
    const from_layer = from_key / nodes;
    if (ctx.pair_coupling_hard) {
        const corridor = ctx.corridor orelse return;
        const terminal = if (ctx.pair_terminal_mask) |mask| mask[to_key] else false;
        if (!corridor[to_key] and !terminal) return;
    }
    if (ctx.pair_vias_hard and from_layer != to_layer) {
        const mask = ctx.pair_via_mask orelse return;
        if (!mask[tn]) return;
    }
    // Stepping onto a poured outer layer costs extra (`POUR_COST_MULT`);
    // steps on an inner signal layer carry the mild `INNER_COST_MULT` bias
    // so equal-length paths stay on the outer faces.
    var eff = if (to_layer >= 2)
        step * inner_cost_mult
    else if (ctx.pour[to_layer])
        step * pour_cost_mult
    else
        step;
    if (!layerInMask(ctx.preferred_layers, @intCast(to_layer))) eff *= preferred_layer_cost_mult;
    if (ctx.reference_corridor) |guide| {
        if (guide[to_key]) eff *= reference_corridor_mult;
    }
    if (ctx.reference_guide_active and from_layer != to_layer) {
        const on_reference_via = if (ctx.reference_via_mask) |mask| mask[tn] else false;
        eff *= if (on_reference_via) reference_via_mult else reference_off_via_mult;
    }
    if (from_layer != to_layer) if (ctx.pair_via_mask) |mask| {
        eff *= if (mask[tn]) diff_via_on_ring_mult else diff_via_off_ring_mult;
    };
    if (ctx.rf.escape_mm > 0) eff *= escapePenalty(ctx, from_key, to_key);
    // RF crossing shadow: a step into a protected net's fence corridor is priced,
    // a via dropped in one priced harder. Soft, so a net that must cross still
    // crosses — it just buys the shortest (≈perpendicular) crossing it can, and
    // a run parallel to the trace costs a multiple of that. See `rf_shadow`.
    eff *= ctx.shadow.multiplier(to_layer, tn, net, from_layer != to_layer, ctx.keep.exempt);
    // A CORNER, added after every multiplier, because a corner is a property of
    // the turn and not of the layer or corridor it happens on
    // (`manhattan_route.turnCost`): `turn_cost_mult` (4 pitches) while the RF
    // axis-only attempt is buying straights outright, `bend_cost_mult` (0.15)
    // for every ordinary leg, and zero for a leg an explicit shape constraint
    // already pins — the diff-pair coupling and reference corridors, which
    // `search.lattice.enabled` marks and which therefore run on the cost model
    // that predates any turn price, to the bit.
    eff += ctx.manhattan.turnCost(ctx.grid.g, search.lattice, from_key, to_key);
    // Diff-pair coupling: discount a step landing in the N net's corridor so it
    // hugs its P twin. No corridor → mult 1.0 → the cost is byte-identical.
    const mult: f64 = if (ctx.corridor) |cor| (if (cor[to_key]) diff_corridor_mult else 1.0) else 1.0;
    // Congestion surcharge, and zero unless the negotiated-congestion sandbox is
    // armed: OUTSIDE the corridor multiplier, because a shared resource costs
    // what it costs whether or not the step also happens to hug a twin.
    const nd = search.state.dist[from_key] + eff * mult +
        congestion.price(ctx.congest, to_key, ctx.occ[to_layer][tn], net, ctx.grid.g);
    if (nd < search.state.dist[to_key]) {
        try search.state.settle(to_key, nd, @intCast(from_key));
        try search.pq.add(.{ .f = nd + search.heuristic.estimate(ctx.grid, tn), .d = nd, .key = to_key });
    }
}

/// Cost multiplier a step within the escape reserve pays: within `escape_mm`
/// of a terminal pad, steps misaligned with that pad's outward axis (and
/// early layer changes) are discouraged so the trace leaves the chip straight
/// before its first bend. Soft — a boxed-in pad can still pay it, and the
/// weight is kept moderate so goal regions don't become cost walls that
/// exhaust the search budget on dense boards.
const escape_pen_mult: f64 = 4.0;
/// Minimum |cos| between a step and the pad's outward axis to count as
/// escape-aligned. 0.85 admits only the straight-out compass direction on the
/// 45°-quantized maze (a 45° step scores ~0.71).
const escape_align_min: f64 = 0.85;

/// True when the current net carries a straight pad-escape reserve that can
/// actually bind: a positive escape distance and at least one terminal with a
/// real outward axis.
pub fn escapeActive(ctx: *const Ctx) bool {
    if (ctx.rf.escape_mm <= 0) return false;
    for (ctx.rf.escape_pts) |pt| if (pt.out[0] != 0 or pt.out[1] != 0) return true;
    return false;
}

/// The escape-reserve cost multiplier for the move `from_key` → `to_key` of
/// the current net (whose terminals are `ctx.rf.escape_pts`). 1.0 outside
/// every reserve; `escape_pen_mult` for a misaligned surface step or a layer
/// change inside one.
fn escapePenalty(ctx: *const Ctx, from_key: usize, to_key: usize) f64 {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const from_layer = from_key / nodes;
    const to_layer = to_key / nodes;
    const fn_node = from_key % nodes;
    const fx = grid.worldX(fn_node % grid.nx);
    const fy = grid.worldY(fn_node / grid.nx);
    for (ctx.rf.escape_pts) |pt| {
        if (pt.out[0] == 0 and pt.out[1] == 0) continue;
        if (std.math.hypot(fx - pt.x, fy - pt.y) >= ctx.rf.escape_mm) continue;
        if (from_layer != to_layer) {
            if (from_layer == pt.layer or to_layer == pt.layer) return escape_pen_mult;
            continue;
        }
        if (from_layer != pt.layer) continue;
        const tn = to_key % nodes;
        const dx = grid.worldX(tn % grid.nx) - fx;
        const dy = grid.worldY(tn / grid.nx) - fy;
        const len = std.math.hypot(dx, dy);
        if (len < 1e-9) continue;
        const along = @abs(dx * pt.out[0] + dy * pt.out[1]) / len;
        if (along < escape_align_min) return escape_pen_mult;
    }
    return 1.0;
}

/// Relax the diagonal neighbour (dx,dy) of (ix,iy) on `layer`. Refuses the move
/// if either orthogonal cell it squeezes past is blocked, so a 45° trace never
/// clips the corner of a pad it must clear (no corner-cutting).
fn relaxDiag(
    ctx: *Ctx,
    search: MazeSearch,
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
    try relaxStep(ctx, search, net, from_key, layer, neighbor(grid, ix, iy, dx, dy), grid.g * sqrt2);
}

/// Walk `prev` from the goal back to a source, stamp the path as net copper,
/// and emit merged track segments (per straight run) + vias (per layer change).
/// Returns the source key the path grew from (== `goal_key` for a 1-node path).
fn emitPath(
    ctx: *Ctx,
    prev: []i64,
    goal_key: usize,
    net: i32,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!?usize {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    var key: i64 = @intCast(goal_key);
    // Collect the path (goal → source).
    var path: std.ArrayList(usize) = .empty;
    while (key >= 0) : (key = prev[@intCast(key)]) {
        const k: usize = @intCast(key);
        try path.append(ctx.arena, k);
    }
    const ks = path.items;
    if (ks.len < 2) return goal_key;
    const via_path = .{
        .arena = ctx.arena,
        .grid = grid,
        .nodes = nodes,
        .rule = viaCopperRule(ctx),
        .net = net,
    };
    if (!try via_rules.pathClears(@TypeOf(via_path), via_path, ks, Via, vias.items)) return null;
    for (ks) |k| ctx.occ[k / nodes][k % nodes] = net;
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
            stampCurrentRfVia(ctx, vx, vy, net); // …and its RF halo + shadow, on every layer
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

fn emitSeg(ctx: *Ctx, tracks: *std.ArrayList(Track), a_key: usize, b_key: usize, net: i32) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    if (a_key == b_key) return;
    const layer: u8 = @intCast(a_key / nodes);
    const a = a_key % nodes;
    const b = b_key % nodes;
    const start = [2]f64{ grid.worldX(a % grid.nx), grid.worldY(a / grid.nx) };
    const end = [2]f64{ grid.worldX(b % grid.nx), grid.worldY(b / grid.nx) };
    try tracks.append(ctx.arena, .{
        .x1 = start[0],
        .y1 = start[1],
        .x2 = end[0],
        .y2 = end[1],
        .layer = layer,
        .width = ctx.params.track_width,
        .net = net,
    });
    stampTrackResv(ctx, start, end, net, layer);
    // A keepout net's copper carries its halo forward on THIS layer, so later
    // nets detour (or cross on another layer, which the rule allows by design) —
    // and its crossing shadow onto EVERY layer, so a crossing pays for running
    // alongside instead of straight across (`rf_shadow`).
    stampCurrentRf(ctx, start, end, net, layer);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");

// spec: placement/router - escapes a fine-pitch pad through an off-grid gateway stub when no grid lane clears
test "pad gateway neck admits a QFN launch that the nominal width blocks" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The target is centred between two 0.2 mm-wide foreign lands on 0.33 mm
    // pitch. Its 0.23 mm edge gap admits 0.1524 mm copper plus 0.127 mm
    // clearance, but is narrower than the 0.2532 mm nominal trace needs.
    const obs = [_]PadObs{
        .{ .x0 = -0.43, .y0 = -0.3, .x1 = -0.23, .y1 = 0.3, .net = 1 },
        .{ .x0 = 0.23, .y0 = -0.3, .x1 = 0.43, .y1 = 0.3, .net = 1 },
    };
    const grid = Grid{ .ox = -2, .oy = -2, .g = 0.254, .nx = 20, .ny = 20 };
    const nominal = RouteParams{ .track_width = 0.2532, .clearance = 0.127 };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &obs,
        .reach = nominal.track_width / 2 + nominal.clearance,
        .occ = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .resv = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .params = nominal,
        .base = nominal,
        .index_reach = nominal.track_width / 2 + nominal.clearance,
    };
    const terminal = NetPt{ .x = 0, .y = 0, .layer = 0, .out = .{ 0, 1 } };
    var gateways: std.ArrayList(usize) = .empty;
    try padGateways(&ctx, &.{}, &.{}, terminal, 0, &gateways);
    try testing.expectEqual(@as(usize, 0), gateways.items.len);

    ctx.params.pad_neck = .{ .width = 0.1524, .max_length = 0.75, .taper_length = 0.35 };
    try padGateways(&ctx, &.{}, &.{}, terminal, 0, &gateways);
    try testing.expect(gateways.items.len > 0);
    try testing.expectEqual(nominal.track_width, ctx.params.track_width);
    try testing.expectApproxEqAbs(@as(f64, 0.2028), router_support.padGatewayWidth(ctx.params, 0.925), 1e-9);
    try testing.expectEqual(nominal.track_width, router_support.padGatewayWidth(ctx.params, 1.2));
}

// spec: placement/router - a maze leg is charged for the escape stub each pad gateway implies, so it buys the entry that points where the route goes instead of the outermost free one
test "a priced gateway fan stops the maze buying a free wrong-way escape" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two off-grid pads 2.61 mm apart with one foreign land standing between
    // them, so the lattice run has to go round while a straight gateway stub
    // does not.
    //
    // Unpriced, this is the shape the fan cannot help drawing: BOTH ends may
    // enter the grid anywhere in their six-ring fan for nothing, so the search
    // minimises only the lattice run BETWEEN the two fans — and `gateStub` then
    // draws two long straight rays from the pad centres out to wherever that run
    // happened to start and end. Any meeting point off the line between the pads
    // makes those rays a V, and nothing in the cost told the search so. Priced,
    // the two rays ARE part of what is minimised.
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 14 };
    const obs = [_]PadObs{.{ .x0 = 1.5, .y0 = 0.6, .x1 = 2.1, .y1 = 1.4, .net = 1, .layer = 0 }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &obs,
        .reach = 0.1905,
        .occ = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .resv = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .params = .{},
        .base = .{},
        .index_reach = 0.1905,
    };
    const from = NetPt{ .x = 2.948, .y = 1.424, .layer = 0 };
    const to = NetPt{ .x = 0.538, .y = 0.418, .layer = 0 };
    var src_gates: std.ArrayList(usize) = .empty;
    var goals: std.ArrayList(usize) = .empty;
    const seed = grid.nearest(from.x, from.y);
    ctx.occ[0][grid.node(seed[0], seed[1])] = 0;
    try padGateways(&ctx, &.{}, &.{}, from, 0, &src_gates);
    const near = grid.nearest(to.x, to.y);
    try goals.append(arena, grid.node(near[0], near[1])); // layer 0 ⇒ key == node
    try padGateways(&ctx, &.{}, &.{}, to, 0, &goals);
    try testing.expect(src_gates.items.len > 8 and goals.items.len > 8);

    // Route the leg and hand back every millimetre of copper it lays: the maze
    // run plus the two escape stubs. Only `anchors` differs between the calls.
    const Leg = struct {
        fn copper(c: *Ctx, ends: MazeEnds, a: NetPt, b: NetPt) std.mem.Allocator.Error!f64 {
            clearNetOcc(c, 0);
            const nd = c.grid.nearest(a.x, a.y);
            c.occ[a.layer][c.grid.node(nd[0], nd[1])] = 0;
            var tracks: std.ArrayList(Track) = .empty;
            var vias: std.ArrayList(Via) = .empty;
            const hit = (try dijkstra(c, 0, ends, &tracks, &vias)) orelse return std.math.inf(f64);
            try gateStub(c, 0, a, hit.source, vias.items, &tracks);
            try gateStub(c, 0, b, hit.goal, vias.items, &tracks);
            return route_timeline.traceLen(tracks.items);
        }
    };
    const both = MazeEnds{ .goals = goals.items, .sources = src_gates.items };
    const free = try Leg.copper(&ctx, both, from, to);
    var priced = both;
    priced.anchors = .{ .source = from, .goal = to };
    const paid = try Leg.copper(&ctx, priced, from, to);

    // A whole fan radius is the scale of the thing being bought, so it is the
    // scale to judge the waste on: the free leg draws MORE than the straight
    // line between the pads plus one fan radius, and the priced leg draws less.
    const straight = std.math.hypot(to.x - from.x, to.y - from.y);
    const fan_reach = @as(f64, @floatFromInt(gate_rings)) * grid.g;
    try testing.expect(free > straight + fan_reach);
    try testing.expect(paid < straight + fan_reach);
    try testing.expect(paid < free - 4 * grid.g);
}

// spec: placement/router - a leg seeded on a pad-buried halo node has its copper trimmed back off the land instead of the net being failed
test "trimBuriedStart pulls a leg's first segment out of the foreign pad it started in" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    // A foreign (net 1) land swallowing node (2,2) and reaching a little to its
    // right — barracuda's `U17` ground pad beside the `LMX_VTUNE` escape. The
    // halo of net 0's own copper still marks (2,2) as net 0's, so Dijkstra may
    // seed there; the run it draws must not start inside the land.
    const pad = [_]PadObs{.{
        .x0 = grid.worldX(2) - 0.1,
        .y0 = grid.worldY(2) - 0.1,
        .x1 = grid.worldX(2) + 0.2,
        .y1 = grid.worldY(2) + 0.1,
        .net = 1,
        .layer = 0,
    }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &pad,
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
    };
    var tracks: std.ArrayList(Track) = .empty;
    const from = tracks.items.len;
    // The leg as `emitSeg` drew it: starting AT the buried node (2,2) and
    // running right, away from the pad.
    try tracks.append(arena, .{
        .x1 = grid.worldX(2),
        .y1 = grid.worldY(2),
        .x2 = grid.worldX(9),
        .y2 = grid.worldY(2),
        .layer = 0,
        .width = 0.2,
        .net = 0,
    });
    const start = trimBuriedStart(&ctx, 0, grid.node(2, 2), from, &tracks, &.{});

    // The run survives — one segment, same far end, same net — but its start has
    // moved clear of the land, and that is the point the caller welds from.
    try testing.expectEqual(@as(usize, 1), tracks.items.len);
    try testing.expectApproxEqAbs(grid.worldX(9), tracks.items[0].x2, 1e-9);
    try testing.expect(tracks.items[0].x1 > grid.worldX(2) + 0.1);
    try testing.expectApproxEqAbs(tracks.items[0].x1, start[0], 1e-9);
    try testing.expectApproxEqAbs(tracks.items[0].y1, start[1], 1e-9);

    // A leg whose start node is NOT pad-buried is returned untouched.
    var clean: std.ArrayList(Track) = .empty;
    try clean.append(arena, .{ .x1 = grid.worldX(9), .y1 = grid.worldY(9), .x2 = grid.worldX(12), .y2 = grid.worldY(9), .layer = 0, .width = 0.2, .net = 0 });
    const kept = trimBuriedStart(&ctx, 0, grid.node(9, 9), 0, &clean, &.{});
    try testing.expectApproxEqAbs(grid.worldX(9), kept[0], 1e-9);
    try testing.expectApproxEqAbs(grid.worldX(9), clean.items[0].x1, 1e-9);
}

// spec: placement/router - the pad-buried source trim happens at the shared search seam, so a pass that does no trimming of its own still emits pad-clearing copper
test "dijkstra pulls a leg off the foreign land its source was buried in" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    // A foreign (net 1) land swallowing node (2,2) but stopping short of (3,2),
    // so the maze can still step right out of it. This is the shape barracuda's
    // poured `V_5VA` hit: `routeNetToZone` seeds from the net's own `occ` marks,
    // `stampStubOcc` painted (2,2) net 0 as part of an earlier leg's clearance
    // HALO, and the pass does no trimming of its own.
    const pad = [_]PadObs{.{
        .x0 = grid.worldX(2) - 0.1,
        .y0 = grid.worldY(2) - 0.1,
        .x1 = 0.55,
        .y1 = grid.worldY(2) + 0.1,
        .net = 1,
        .layer = 0,
    }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &pad,
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
        .base = .{},
        .index_reach = 0.19,
    };
    // The buried node is the ONLY source, so the leg must grow out of it —
    // `relaxStep` would never have entered it (`blocked` is true there).
    try testing.expect(blocked(&ctx, 0, grid.node(2, 2), 0));
    ctx.occ[0][grid.node(2, 2)] = 0;

    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    const goals = [_]usize{grid.node(9, 2)}; // one layer ⇒ key == node index
    const hit = (try dijkstra(&ctx, 0, .{ .goals = &goals }, &tracks, &vias)) orelse
        return error.LegNotRouted;

    // The leg is routed, reaches its goal, and grew from the buried source…
    try testing.expect(tracks.items.len > 0);
    try testing.expectEqual(goals[0], hit.goal);
    try testing.expectEqual(grid.node(2, 2), hit.source);
    // …and every segment it drew clears the foreign land by the exact rule
    // `drc.checkTrackPad` applies (centreline distance − half width ≥ clearance).
    const shape = pad_shape.Shape{ .x0 = pad[0].x0, .y0 = pad[0].y0, .x1 = pad[0].x1, .y1 = pad[0].y1 };
    for (tracks.items) |t| {
        const d = pad_shape.segmentDist(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, 4.0);
        try testing.expect(d - t.width / 2 >= ctx.params.clearance - 1e-9);
    }
    // The reported start is where that copper now begins — off the land, and
    // the point a welding caller must bridge from.
    try testing.expect(hit.start[0] > grid.worldX(2) + 0.1);
}

// spec: placement/router - a later leg's weld to the net's occupancy halo is bridged to the real copper so the two legs share metal
test "weldToNetCopper bridges an off-centreline halo weld to the net's prior copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        // Explicit geometry so `copperHalo` is deterministic: its (0.2, ~0.48]
        // mm bridging band comfortably contains the one-grid-row (0.254 mm)
        // weld this test uses.
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
    };
    // Prior copper: one horizontal net-0 track on layer 0 (the earlier leg).
    const y0 = grid.worldY(2);
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = grid.worldX(2), .y1 = y0, .x2 = grid.worldX(6), .y2 = y0, .layer = 0, .width = 0.2, .net = 0 });
    const prior = tracks.items.len;

    // A later leg welds at node (4,3): one grid row (0.254 mm, inside the
    // (track_width, copperHalo] halo band) ABOVE the real centreline — the halo
    // weld a Dijkstra source leaves. It is bridged straight down to the closest
    // point on the prior track, so the centrelines now meet (no fab open).
    try weldToNetCopper(.{ .ctx = &ctx, .net = 0, .at = .{ grid.worldX(4), grid.worldY(3) }, .layer = 0, .prior = prior, .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(prior + 1, tracks.items.len);
    const b = tracks.items[prior];
    try testing.expectApproxEqAbs(grid.worldX(4), b.x1, 1e-9);
    try testing.expectApproxEqAbs(grid.worldY(3), b.y1, 1e-9);
    try testing.expectApproxEqAbs(grid.worldX(4), b.x2, 1e-9);
    try testing.expectApproxEqAbs(y0, b.y2, 1e-9);
    try testing.expectEqual(@as(i32, 0), b.net);

    // A weld already ON the prior copper adds no bridge.
    try weldToNetCopper(.{ .ctx = &ctx, .net = 0, .at = .{ grid.worldX(4), grid.worldY(2) }, .layer = 0, .prior = prior, .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(prior + 1, tracks.items.len);
}

// spec: placement/router - a halo weld whose bridge would cross foreign copper is refused instead of laid over it
test "weldToNetCopper refuses a bridge that crosses a foreign pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    // A foreign (net 1) pad sitting between the weld node (4,3) and the prior
    // copper at row 2 — barracuda's LDO ground paddle, which the unprobed
    // bridge used to be drawn straight across.
    const pad = [_]PadObs{.{
        .x0 = grid.worldX(4) - 0.2,
        .y0 = grid.worldY(2) + 0.05,
        .x1 = grid.worldX(4) + 0.2,
        .y1 = grid.worldY(3) - 0.05,
        .net = 1,
        .layer = 0,
    }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &pad,
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
    };
    const y0 = grid.worldY(2);
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = grid.worldX(2), .y1 = y0, .x2 = grid.worldX(6), .y2 = y0, .layer = 0, .width = 0.2, .net = 0 });
    const prior = tracks.items.len;

    // Same weld as the bridging test above, now with the pad in the way: no
    // copper is emitted, so the leg reads as the open it really is (the
    // `net_open` marker names it) instead of shorting to the pad.
    try weldToNetCopper(.{ .ctx = &ctx, .net = 0, .at = .{ grid.worldX(4), grid.worldY(3) }, .layer = 0, .prior = prior, .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(prior, tracks.items.len);
}

// spec: placement/router - a pad-centre join stops at the foreign-pad clearance instead of emitting the segment nothing probed
test "OctiJoin trims a join that aims at a two-pad passive's sibling pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // barracuda's `adf4159/C116` to scale: a 0402-class cap turned 90 degrees,
    // so its own pad (net 0) and its GND pad (net 1) sit 0.64 mm apart in y with
    // 0.230 mm half-heights. The maze's entry node for the V_1V8A pad lies
    // straight up the inter-pad lane, so the join is already octilinear — the
    // one shape `elbow` returns on without probing, which is exactly how the
    // unprobed segment used to be drawn 0.094 mm into a 0.127 mm rule.
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    const own = [2]f64{ 2.0, 2.0 };
    const sibling = [_]PadObs{.{ .x0 = 1.8, .y0 = 2.41, .x1 = 2.2, .y1 = 2.87, .net = 1, .layer = 0 }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &sibling,
        .reach = 0.2535,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.253, .clearance = 0.127, .via_dia = 0.4, .via_drill = 0.2 },
    };
    var tracks: std.ArrayList(Track) = .empty;
    const join = OctiJoin{ .ctx = &ctx, .net = 0, .layer = 0, .placed_vias = &.{}, .tracks = &tracks };

    // A track_width trace needs its half-width plus the rule clear of the
    // sibling's near edge, so the copper may reach y = 2.41 − 0.2535 and no
    // farther. The old emit ran the full 0.4 mm to the node at y = 2.4.
    try octilinear.emitJoin(own, .{ 2.0, 2.4 }, join);
    try testing.expectEqual(@as(usize, 1), tracks.items.len);
    const t = tracks.items[0];
    try testing.expectApproxEqAbs(own[0], t.x1, 1e-9);
    try testing.expectApproxEqAbs(own[1], t.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.1565), t.y2, 1e-6);
    // The emitted copper — not merely the requested span — passes the very
    // predicate the track-pad DRC re-runs on it.
    try testing.expect(segClearsPadsOnLayer(&ctx, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, 0, 0));

    // Away from the sibling the join is untouched: a legal span still emits end
    // to end, so trimming costs nothing where the copper was always fabricable.
    tracks.clearRetainingCapacity();
    try octilinear.emitJoin(own, .{ 2.0, 1.6 }, join);
    try testing.expectEqual(@as(usize, 1), tracks.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1.6), tracks.items[0].y2, 1e-9);

    // A pad centre that already crowds its neighbour has no legal stub at all,
    // so nothing is drawn — an open `net_open` names beats a silent short.
    const crowding = [_]PadObs{.{ .x0 = 1.8, .y0 = 2.1, .x1 = 2.2, .y1 = 2.5, .net = 1, .layer = 0 }};
    ctx.obs = &crowding;
    tracks.clearRetainingCapacity();
    try octilinear.emitJoin(own, .{ 2.0, 2.4 }, join);
    try testing.expectEqual(@as(usize, 0), tracks.items.len);
}

test "batch maze search is bounded and reuses its board-sized buffers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 200, .ny = 120 };
    const nodes = grid.nx * grid.ny;
    const selected = [_]bool{ true, true, true };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{},
        .selected_nets = &selected,
        .allow_vias = false,
    };
    const source = grid.node(10, 60);
    const goal = grid.node(190, 60);
    ctx.occ[0][source] = 0;
    for (0..grid.ny) |y| ctx.occ[0][grid.node(100, y)] = 1;

    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    try testing.expect(try dijkstra(&ctx, 0, .{ .goals = &.{goal} }, &tracks, &vias) == null);
    try testing.expectEqualSlices(usize, &.{0}, ctx.search_limited.items);
    const dist_ptr = ctx.search.dist.ptr;

    ctx.occ[0][grid.node(100, 60)] = empty_cell;
    try testing.expect(try dijkstra(&ctx, 0, .{ .goals = &.{goal} }, &tracks, &vias) != null);
    try testing.expect(dist_ptr == ctx.search.dist.ptr);
}

// spec: placement/router - a rolled-back attempt restores the search-limited marks its own probe added, leaving the set byte-identical
test "a rolled-back attempt leaves search_limited byte-identical" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var scratch_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_inst.deinit();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 200, .ny = 120 };
    const nodes = grid.nx * grid.ny;
    const selected = [_]bool{ true, true, true };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{},
        .selected_nets = &selected,
        .allow_vias = false,
    };
    // A mark an EARLIER phase left behind: the rollback must keep it.
    try ctx.search_limited.append(arena, 2);

    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    var routable = [_]RipNet{};
    const snap = try saveSnapshot(scratch_inst.allocator(), &ctx, &tracks, &vias, &routable);

    // The speculative attempt: a wall-blocked leg exhausts its budget on net 0
    // and marks it, as a `rerouteNet` inside a rip-up transaction would.
    const source = grid.node(10, 60);
    const goal = grid.node(190, 60);
    ctx.occ[0][source] = 0;
    for (0..grid.ny) |y| ctx.occ[0][grid.node(100, y)] = 1;
    try testing.expect(try dijkstra(&ctx, 0, .{ .goals = &.{goal} }, &tracks, &vias) == null);
    try testing.expectEqualSlices(usize, &.{ 2, 0 }, ctx.search_limited.items);

    // Rolling the attempt back unwinds its mark and only its mark.
    try restoreSnapshot(&ctx, &tracks, &vias, &routable, snap);
    try testing.expectEqualSlices(usize, &.{2}, ctx.search_limited.items);
}

test "A star heuristic stays admissible through combined corridor discounts" {
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 11, .ny = 1 };
    const corridor: [11]bool = @splat(false);
    var ctx = Ctx{
        .arena = testing.allocator,
        .grid = grid,
        .obs = &.{},
        .reach = 0,
        .occ = &.{},
        .resv = &.{},
        .params = .{},
        .reference_corridor = &corridor,
        .corridor = &corridor,
    };
    const heuristic = routeHeuristic(&ctx, &.{grid.node(10, 0)}, 11);
    try testing.expectApproxEqAbs(@as(f64, 0.05), heuristic.estimate(grid, 0), 1e-12);
}

// spec: placement/router - a leg following a soft reference guide searches on the targeted expansion budget, since its heuristic is discounted to stay admissible
test "expansionBudget gives a guided leg the targeted budget" {
    const base = route_grid.max_batch_expansions;
    // A guided leg pays a 0.1x heuristic (routeHeuristic) and so expands far
    // more nodes per unit of progress; it takes the targeted floor.
    try testing.expectEqual(route_grid.max_targeted_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = false,
        .guided = true,
    }));
    // Unguided is unchanged — the whole-board base, exactly as before.
    try testing.expectEqual(base, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = false,
        .guided = false,
    }));
}

// spec: placement/router - escalation widens the maze expansion budget only for a retried search-limited leg
test "expansionBudget escalates only for a retried search-limited leg" {
    const base = route_grid.max_batch_expansions;
    // Ordinary whole-board leg, no corridor: exactly the base budget.
    try testing.expectEqual(base, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = false,
    }));
    // An escape-forced leg widens to the targeted budget.
    try testing.expectEqual(route_grid.max_targeted_expansions, expansionBudget(.{
        .base = base,
        .escape_active = true,
        .escalate = 0,
        .corridor = false,
    }));
    // A coupling corridor caps the ordinary search tightly.
    try testing.expectEqual(route_grid.max_pair_corridor_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = true,
    }));
    // Escalation lifts the plain budget far above the whole-board base…
    try testing.expectEqual(max_escalated_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = max_escalated_expansions,
        .corridor = false,
    }));
    // …and lifts the corridor cap too, so an escalated pair retry is not stuck
    // at the tight 2 000-cell corridor budget.
    try testing.expectEqual(max_escalated_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = max_escalated_expansions,
        .corridor = true,
    }));
}

// spec: placement/router - a last-resort retry escalates a residual leg to a larger expansion budget than an ordinary escalation
test "the last-resort retry uses a larger expansion budget than an ordinary escalation" {
    try testing.expect(max_last_resort_expansions > max_escalated_expansions);
    // `expansionBudget` threads the caller's escalated budget verbatim, so the
    // last-resort tier searches strictly wider than an ordinary escalation — on
    // the plain AND the corridor-capped path.
    try testing.expectEqual(max_last_resort_expansions, expansionBudget(.{
        .base = route_grid.max_batch_expansions,
        .escape_active = false,
        .escalate = max_last_resort_expansions,
        .corridor = false,
    }));
    try testing.expectEqual(max_last_resort_expansions, expansionBudget(.{
        .base = route_grid.max_batch_expansions,
        .escape_active = false,
        .escalate = max_last_resort_expansions,
        .corridor = true,
    }));
}
