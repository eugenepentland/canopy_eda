//! Net-open connectivity DRC: copper belonging to ONE net that does not all
//! electrically connect. Unlike the pairwise clearance checks in `drc.zig`, an
//! open is INVISIBLE to clearance — two trace stubs that approach but never
//! meet pass every spacing rule yet fab as an open circuit — so it needs its
//! own pass. This is the DRC-marker twin of the fab gate's airwire error
//! (`fab_readiness`): both read the SAME `fab.buildNetGraph` connectivity, so
//! the viewer marker and the export blocker never disagree on what "connected"
//! means.
//!
//! It is deliberately NOT part of `drc.check`. The router evaluates thousands
//! of candidate routings through `drc.check`, and the client WASM DRC runs it
//! per edit, so the (per-plane-net) pour raster this needs must stay out of
//! both hot paths; the serve-layer `drc_rules.checkFiltered` is the single seam
//! that layers it on for the reporting surfaces (page blob, /api/pcb-drc,
//! /api/pcb-route, /api/pcb-describe, route review/session).
//!
//! Per net: build the net's connectivity graph, split it into connected
//! components (plane-fed islands fuse through the pour, so a real ground plane
//! is exempt), and if more than one survives, chain them by nearest approach —
//! one `net_open` error per (components − 1) edge, its marker sitting in the
//! closest gap with `gap` = that airgap in mm. A copper island touching NO pad
//! is orphan copper, flagged the same way (on a plane-carried net, orphan-only
//! islands are skipped — they are almost always pour-connected, which this pass
//! cannot cheaply prove, so flagging them would be noise).
//!
//! An island may be a BARE PAD — one the router never reached, so its only
//! copper is the pad itself. Those count exactly like a copper island: a pad
//! with nothing on it is the most literal open there is, and excusing it as
//! "unrouted, the ratsnest's job" is what let a board report a clean DRC while
//! the fab gate simultaneously refused it for the same net (barracuda's
//! `hmc451/C112` sat alone on `V_5VA` and no marker named it). The two now
//! agree by construction: `net_open` fires on exactly the nets
//! `fab_readiness.netConnectivity` calls unconnected.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const drc = @import("drc.zig");
const pad_shape = @import("pad_shape.zig");
const copper_contact = @import("copper_contact.zig");
const fab = @import("../fab_readiness.zig");
const routed_copper = @import("routed_copper.zig");
const flat_netlist = @import("../flat_netlist.zig");
const net_identity = @import("net_identity.zig");

const eps: f64 = 1e-9;

/// Run the net-open check over every net's drawn copper. Arena-owned output,
/// appended in `placement.nets` order (so ids stay stable across re-checks).
/// Takes `Copper` (not `RouteResult`) so it shares the fab gate's copper model
/// exactly, and the serve seam feeds it the same persisted/fresh tracks + vias.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: routed_copper.Copper,
    base: ?pour.EdgeField,
) std.mem.Allocator.Error![]drc.Violation {
    return (try checkWithConnectivity(arena, placement, copper, .{ .base = base })).violations;
}

/// Raster the board's user zones for connectivity — the whole-run fill
/// `checkWithConnectivity` builds when a caller does not hand one in.
///
/// Exposed so the reporting DRC seam can MEMOISE it beside the topology fill it
/// already retains: both are the same function of the board and its copper, and
/// this one is the other half of that seam's cost — 2.6 s of a barracuda-base
/// pass, for four zones. Feed the result back through `Prepared.zone_fills`.
pub fn zoneFills(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: routed_copper.Copper,
    base: ?pour.EdgeField,
) std.mem.Allocator.Error![]const pour.Fill {
    return zoneFillsMemo(arena, placement, copper, base, null);
}

/// `zoneFills` through a caller's per-fill memo. The reporting seam passes one,
/// so a zone whose own inputs did not change across an edit is borrowed rather
/// than re-rastered — and so that this raster and the topology pass's raster of
/// the SAME zone spec are computed once between them, not once each.
pub fn zoneFillsMemo(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: routed_copper.Copper,
    base: ?pour.EdgeField,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error![]const pour.Fill {
    return fab.userZoneFillsMemo(arena, placement, copper, base, memo);
}

/// Board-level fill state a caller may have already built for this exact board,
/// so one whole-board sweep is not repeated per pass. Every field defaults to
/// "not prepared", which reproduces the unshared behaviour exactly.
pub const Prepared = struct {
    /// The caller's shared board-edge margin field (`pour.sharedEdgeField`).
    base: ?pour.EdgeField = null,
    /// Carrying-layer fills retained by the topology pass.
    plane_fills: []const pour.NetFills = &.{},
    /// The user-zone rasters (`zoneFills`). Null — NOT an empty slice — means
    /// "not prepared": a board with no zones legitimately rasters to none, and
    /// the two must not be confused or a zoned board loses its pour credit.
    zone_fills: ?[]const pour.Fill = null,
};

/// Open-net findings plus the per-net connectivity statuses derived from the
/// exact same graphs. The authoritative DRC endpoint needs both; returning
/// them together avoids rastering every carried plane and rebuilding every
/// same-net union a second time solely for its routed/total summary.
pub const Report = struct {
    violations: []drc.Violation,
    connectivity: []const fab.NetStatus,
};

/// Run the open-net sweep and retain each graph's connectivity status so a
/// reporting caller can summarize it without a duplicate whole-board pass.
pub fn checkWithConnectivity(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: routed_copper.Copper,
    prepared: Prepared,
) std.mem.Allocator.Error!Report {
    var out: std.ArrayList(drc.Violation) = .empty;
    var connectivity: std.ArrayList(fab.NetStatus) = .empty;
    // Raster the user zones ONCE for the whole run — or not at all, when the
    // caller already holds this board's rasters (`Prepared.zone_fills`, which
    // the reporting DRC seam memoises). A zone's fill is a property of the
    // board and its copper, not of the net being inspected, so the per-net
    // graph builder gets the same slice every time — see
    // `fab.buildNetGraphPrepared`. Rebuilding it inside the loop made this pass
    // (which the PCB page runs on every render) cost ~86 s on barracuda.
    // `base` is the caller's shared edge-margin field; every fill below — the
    // zone rasters here and the per-net plane connect — reads it, so the
    // outline walk happens once for the whole render instead of once per
    // caller and once per net.
    const board: Board = .{
        .placement = placement,
        .copper = copper,
        .zone_fills = prepared.zone_fills orelse try zoneFills(arena, placement, copper, prepared.base),
        .base = prepared.base,
        .plane_fills = prepared.plane_fills,
        .identity = try net_identity.Identity.init(arena, placement),
    };
    for (placement.nets, 0..) |net, ni| {
        try connectivity.append(arena, try checkNet(arena, &out, board, net, @intCast(ni)));
    }
    return .{
        .violations = try out.toOwnedSlice(arena),
        .connectivity = try connectivity.toOwnedSlice(arena),
    };
}

/// One connected component of a net's copper: whether it holds a pad (so a
/// pad-less island is orphan copper), and the geometry that bounds it (for the
/// nearest-approach marker) — the pads' own copper as well as the tracks/vias,
/// because an island the router never reached is bounded by nothing else.
const Comp = struct {
    has_pad: bool = false,
    /// The first pad found on this island — what the violation names as the
    /// island's identity ("the copper at U17 pad 3"), left blank for orphan
    /// copper that touches no pad at all.
    pad: fab.PadId = .{},
    pads: std.ArrayList(pad_shape.Shape) = .empty,
    tracks: std.ArrayList(router.Track) = .empty,
    vias: std.ArrayList(router.Via) = .empty,
};

/// What every net's check reads and no net changes: the placement, its persisted
/// copper, the user-zone rasters computed once for the whole run, and the
/// shared edge-margin field every fill seeds from.
const Board = struct {
    placement: optimizer.Placement,
    copper: routed_copper.Copper,
    zone_fills: []const pour.Fill,
    base: ?pour.EdgeField,
    plane_fills: []const pour.NetFills,
    identity: net_identity.Identity,
};

fn checkNet(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    board: Board,
    net: flat_netlist.FlatNet,
    net_i: i32,
) std.mem.Allocator.Error!fab.NetStatus {
    const g = try fab.buildNetGraphPrepared(arena, board.placement, board.copper, net, net_i, .{
        .zone_fills = board.zone_fills,
        .base = board.base,
        .plane_fills = board.plane_fills,
        .identity = board.identity,
    });
    // The live DRC response only consumes routed/total from these retained
    // statuses. Its RF path lowering can contain thousands of private chords,
    // so do not run the separate quadratic hairline-gap audit here.
    const status = try fab.netStatusFromGraph(arena, net.name, g, false);
    // A net whose pads all sit at one board location needs no copper (a single
    // pad, or a net-tie's coincident pads) — the same gate `netComponents`
    // applies, so the marker and the fab gate agree on what "routable" means.
    if (g.locations < 2) return status;

    // Bucket every feature by its component root.
    var comps: std.AutoHashMapUnmanaged(usize, *Comp) = .empty;
    for (0..g.n_pads) |i| {
        const c = try compFor(arena, &comps, g.root(i));
        if (i < g.pads.len) {
            if (!c.has_pad) c.pad = g.pads[i];
            try c.pads.append(arena, g.pads[i].shape);
        }
        c.has_pad = true;
    }
    const tbase = g.n_pads;
    for (g.tracks, 0..) |t, ti| {
        try (try compFor(arena, &comps, g.root(tbase + ti))).tracks.append(arena, t);
    }
    const vbase = g.n_pads + g.tracks.len;
    for (g.vias, 0..) |v, vi| {
        try (try compFor(arena, &comps, g.root(vbase + vi))).vias.append(arena, v);
    }

    // The islands to reconcile. On a plane-carried net, orphan-only islands
    // (copper touching no pad) are dropped — they are almost always connected
    // through the pour, which this pass cannot cheaply confirm; a pad-bearing
    // island that misses the plane is still a real open and stays.
    const canonical_net = board.identity.canonical(net_i);
    const plane = router.netHasPlane(board.placement, board.identity.canonicalName(board.placement.nets, net_i));
    var islands: std.ArrayList(*Comp) = .empty;
    var it = comps.valueIterator();
    while (it.next()) |cp| {
        const c = cp.*;
        // An alias graph borrows the parent rail's copper solely to decide
        // whether THIS connection net's pads reach it. Parent/sibling copper
        // that reaches neither target pad is not an orphan of every bypass
        // stub; its canonical net owns that diagnostic once.
        if ((plane or canonical_net != net_i) and !c.has_pad) continue;
        try islands.append(arena, c);
    }
    if (islands.items.len < 2) return status; // everything is one piece of metal — fine.

    try emitOpens(arena, out, islands.items, net_i);
    return status;
}

/// The `*Comp` for a union-find root, minted on first sight (arena-owned).
fn compFor(
    arena: std.mem.Allocator,
    comps: *std.AutoHashMapUnmanaged(usize, *Comp),
    root: usize,
) std.mem.Allocator.Error!*Comp {
    const gop = try comps.getOrPut(arena, root);
    if (!gop.found_existing) {
        const c = try arena.create(Comp);
        c.* = .{};
        gop.value_ptr.* = c;
    }
    return gop.value_ptr.*;
}

/// Chain the copper islands into one tree by nearest approach (Prim's MST) and
/// emit a `net_open` error per tree edge — `islands − 1` violations, each marked
/// in the closest gap between the two islands it joins. Capping at the MST edges
/// (not every pair) keeps a many-island net from producing quadratic spam while
/// still surfacing every disconnected island once.
///
/// Prim runs off a per-island `best` frontier cache (one relaxation pass per
/// island joined) rather than re-scanning every (in-tree × out-of-tree) pair, so
/// it costs O(n²) `nearestApproach` calls, not O(n³). That matters now that a
/// bare pad is an island: an unrouted power rail on a big board is hundreds of
/// islands, where the cubic form would dominate the whole DRC pass.
fn emitOpens(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    islands: []const *Comp,
    net_i: i32,
) std.mem.Allocator.Error!void {
    const n = islands.len;
    const in_tree = try arena.alloc(bool, n);
    @memset(in_tree, false);
    // One box + largest radius per island, so a relaxation can prove a pair
    // cannot beat the frontier without walking its feature cross-product.
    const bounds = try arena.alloc(Bound, n);
    for (islands, bounds) |island, *bound| bound.* = boundOf(island);
    // `best[j]` = closest approach from the tree to island j; `link[j]` = the
    // in-tree island that attains it. Seeded from island 0, then relaxed against
    // each newly joined island.
    const best_to = try arena.alloc(Approach, n);
    const link = try arena.alloc(usize, n);
    in_tree[0] = true;
    for (0..n) |j| {
        best_to[j] = if (j == 0) approachInf() else nearestApproach(islands[0], islands[j]);
        link[j] = 0;
    }
    var joined: usize = 1;
    while (joined < n) : (joined += 1) {
        var chosen: ?usize = null;
        for (0..n) |j| {
            if (in_tree[j]) continue;
            if (chosen == null or best_to[j].dist < best_to[chosen.?].dist) chosen = j;
        }
        const pick = chosen orelse break;
        const best = best_to[pick];
        const from = link[pick];
        in_tree[pick] = true;
        for (0..n) |j| {
            if (in_tree[j]) continue;
            // Branch and bound. `boundGap` never exceeds the exact approach, and
            // the frontier only improves on a STRICT `<`, so a pair the bound
            // proves cannot beat `best_to[j]` would have been discarded by the
            // comparison below anyway: the frontier — and therefore the emitted
            // island pair, bridge, and gap — is unchanged.
            if (boundGap(bounds[pick], bounds[j]) >= best_to[j].dist) continue;
            const a = nearestApproach(islands[pick], islands[j]);
            if (a.dist < best_to[j].dist) {
                best_to[j] = a;
                link[j] = pick;
            }
        }
        const kind: drc.Kind = if (copper_contact.classifyGap(best.dist) == .hairline) .hairline_gap else .net_open;
        try out.append(arena, .{
            .x = best.x,
            .y = best.y,
            .gap = best.dist,
            .clearance = 0, // an open must close to 0 mm; no spacing rule applies
            .kind = kind,
            .severity = drc.defaultSeverity(kind),
            // ONE net (`net_b` unset), with the two islands it failed to join
            // named by a pad each — the endpoints copper still has to reach.
            .who = .{
                .net_a = net_i,
                .part_a = islands[from].pad.part,
                .pad_a = islands[from].pad.pad,
                .part_b = islands[pick].pad.part,
                .pad_b = islands[pick].pad.pad,
                .bridge = .{ best.a[0], best.a[1], best.b[0], best.b[1] },
            },
        });
    }
}

/// The nearest-approach point + edge-to-edge gap between two islands' copper.
const Approach = struct {
    dist: f64,
    x: f64,
    y: f64,
    /// The two feature probes that attained `dist`, one on each island.
    a: [2]f64,
    b: [2]f64,
};

const Closest = struct { dist: f64, x: f64, y: f64 };

/// One island's approach geometry in summary: the box containing every point
/// `nearestApproach` measures FROM (pad lands, track centrelines, via centres)
/// and the largest radius its kernels ever subtract from a raw distance.
const Bound = struct {
    minx: f64 = std.math.inf(f64),
    miny: f64 = std.math.inf(f64),
    maxx: f64 = -std.math.inf(f64),
    maxy: f64 = -std.math.inf(f64),
    radius: f64 = 0,
    empty: bool = true,
};

fn boundPoint(bound: *Bound, x: f64, y: f64) void {
    bound.minx = @min(bound.minx, x);
    bound.miny = @min(bound.miny, y);
    bound.maxx = @max(bound.maxx, x);
    bound.maxy = @max(bound.maxy, y);
    bound.empty = false;
}

fn boundOf(c: *const Comp) Bound {
    var bound = Bound{};
    for (c.pads.items) |p| {
        boundPoint(&bound, p.x0, p.y0);
        boundPoint(&bound, p.x1, p.y1);
    }
    for (c.tracks.items) |t| {
        boundPoint(&bound, t.x1, t.y1);
        boundPoint(&bound, t.x2, t.y2);
        bound.radius = @max(bound.radius, t.width / 2);
    }
    for (c.vias.items) |v| {
        boundPoint(&bound, v.x, v.y);
        bound.radius = @max(bound.radius, v.dia / 2);
    }
    return bound;
}

/// A lower bound on `nearestApproach(a, b).dist`. Every kernel measures between
/// a point/segment/land inside one island's box and one inside the other's, so
/// its raw distance is at least the boxes' gap; and every kernel subtracts at
/// most one radius per island, so the widest pair bounds the correction. An
/// island with no copper at all bounds to -inf, i.e. "measure it exactly".
fn boundGap(a: Bound, b: Bound) f64 {
    if (a.empty or b.empty) return -std.math.inf(f64);
    const gx = @max(@max(a.minx - b.maxx, b.minx - a.maxx), 0);
    const gy = @max(@max(a.miny - b.maxy, b.miny - a.maxy), 0);
    return std.math.hypot(gx, gy) - a.radius - b.radius;
}

fn approachInf() Approach {
    return .{ .dist = std.math.inf(f64), .x = 0, .y = 0, .a = .{ 0, 0 }, .b = .{ 0, 0 } };
}

/// Edge-to-edge nearest approach between two islands over their pad / track /
/// via copper. Two features of DISTINCT components never touch (a touch would
/// have united them), so the closest pair is always attained at a track
/// endpoint, a via centre, or a pad outline — the probes below are exact for
/// the open case.
fn nearestApproach(a: *const Comp, b: *const Comp) Approach {
    var best = approachInf();
    for (a.tracks.items) |ta| {
        for (b.tracks.items) |tb| trackTrack(&best, ta, tb);
        for (b.vias.items) |vb| trackVia(&best, ta, vb);
        for (b.pads.items) |pb| padTrack(&best, pb, ta);
    }
    for (a.vias.items) |va| {
        for (b.tracks.items) |tb| trackVia(&best, tb, va);
        for (b.vias.items) |vb| viaVia(&best, va, vb);
        for (b.pads.items) |pb| padVia(&best, pb, va);
    }
    for (a.pads.items) |pa| {
        for (b.tracks.items) |tb| padTrack(&best, pa, tb);
        for (b.vias.items) |vb| padVia(&best, pa, vb);
        for (b.pads.items) |pb| padPad(&best, pa, pb);
    }
    return best;
}

/// pad ↔ track: the pad's land against the track centreline, less the track's
/// half-width.
fn padTrack(best: *Approach, p: pad_shape.Shape, t: router.Track) void {
    const c = padCenter(p);
    fold(best, segRectDist(t, p) - t.width / 2, c, segClosestPoint(t, c));
}

/// pad ↔ via: the pad's land against the via centre, less the via radius.
fn padVia(best: *Approach, p: pad_shape.Shape, v: router.Via) void {
    fold(best, boxDist(p, v.x, v.y) - v.dia / 2, padCenter(p), .{ v.x, v.y });
}

/// pad ↔ pad: land-to-land gap between two bare pads.
fn padPad(best: *Approach, a: pad_shape.Shape, b: pad_shape.Shape) void {
    fold(best, pad_shape.shapeGap(a, b, 0), padCenter(a), padCenter(b));
}

/// Distance from `(px,py)` to a pad's land box. Measured on the bounding box
/// (`slack = 0` short-circuits the outline walk): a concave custom pad then
/// reads slightly WIDER than its copper, which can only shrink a reported
/// airgap — never hide one, since an island's existence is decided by the
/// union-find, not by this number.
fn boxDist(p: pad_shape.Shape, px: f64, py: f64) f64 {
    return pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, px, py, 0);
}

/// Exact segment↔box distance for two DISJOINT shapes: the closest pair of two
/// convex sets is attained at a vertex of one, so probing the box's four corners
/// against the segment plus the segment's two ends against the box covers every
/// case. Islands are disjoint by construction (an overlap would have united
/// them), so the disjoint assumption always holds here.
fn segRectDist(t: router.Track, p: pad_shape.Shape) f64 {
    var d = @min(boxDist(p, t.x1, t.y1), boxDist(p, t.x2, t.y2));
    const corners = [4][2]f64{ .{ p.x0, p.y0 }, .{ p.x1, p.y0 }, .{ p.x1, p.y1 }, .{ p.x0, p.y1 } };
    for (corners) |c| d = @min(d, segClosest(t.x1, t.y1, t.x2, t.y2, c[0], c[1]).dist);
    return d;
}

fn padCenter(p: pad_shape.Shape) [2]f64 {
    return .{ (p.x0 + p.x1) / 2, (p.y0 + p.y1) / 2 };
}

fn segClosestPoint(t: router.Track, p: [2]f64) [2]f64 {
    const c = segClosest(t.x1, t.y1, t.x2, t.y2, p[0], p[1]);
    return .{ c.x, c.y };
}

/// Keep `gap` (and a marker midway between the two probe points) when it beats
/// what `best` holds.
fn fold(best: *Approach, gap: f64, a: [2]f64, b: [2]f64) void {
    if (gap < best.dist) best.* = .{
        .dist = gap,
        .x = (a[0] + b[0]) / 2,
        .y = (a[1] + b[1]) / 2,
        .a = a,
        .b = b,
    };
}

/// track ↔ track: probe both endpoints of each track against the other track's
/// segment; the copper-edge gap subtracts both half-widths.
fn trackTrack(best: *Approach, ta: router.Track, tb: router.Track) void {
    const r = ta.width / 2 + tb.width / 2;
    consider(best, ta.x1, ta.y1, tb, r);
    consider(best, ta.x2, ta.y2, tb, r);
    considerRev(best, tb.x1, tb.y1, ta, r);
    considerRev(best, tb.x2, tb.y2, ta, r);
}

/// track ↔ via: the via centre against the track segment; gap subtracts the
/// track half-width and the via radius.
fn trackVia(best: *Approach, t: router.Track, v: router.Via) void {
    consider(best, v.x, v.y, t, t.width / 2 + v.dia / 2);
}

/// via ↔ via: centre distance minus both radii.
fn viaVia(best: *Approach, a: router.Via, b: router.Via) void {
    const d = std.math.hypot(a.x - b.x, a.y - b.y) - a.dia / 2 - b.dia / 2;
    if (d < best.dist) best.* = .{
        .dist = d,
        .x = (a.x + b.x) / 2,
        .y = (a.y + b.y) / 2,
        .a = .{ a.x, a.y },
        .b = .{ b.x, b.y },
    };
}

/// Fold point `(px,py)` against track `t`'s centreline into `best`: the gap is
/// the point-to-segment distance minus `r`, and the marker is the midpoint of
/// the point and its closest point on the segment.
fn consider(best: *Approach, px: f64, py: f64, t: router.Track, r: f64) void {
    const c = segClosest(t.x1, t.y1, t.x2, t.y2, px, py);
    const gap = c.dist - r;
    if (gap < best.dist) best.* = .{
        .dist = gap,
        .x = (px + c.x) / 2,
        .y = (py + c.y) / 2,
        .a = .{ px, py },
        .b = .{ c.x, c.y },
    };
}

/// `consider` with the same geometry — kept as a twin so `trackTrack` reads
/// symmetrically (the endpoint belongs to the OTHER track here).
fn considerRev(best: *Approach, px: f64, py: f64, t: router.Track, r: f64) void {
    consider(best, px, py, t, r);
}

/// Closest point on segment `(ax,ay)-(bx,by)` to point `(px,py)`, and its
/// distance.
fn segClosest(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) Closest {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 < eps) 0 else std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    const cx = ax + t * dx;
    const cy = ay + t * dy;
    return .{ .dist = std.math.hypot(px - cx, py - cy), .x = cx, .y = cy };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const pour = @import("pour.zig");

/// Two same-net single-pad parts 10 mm apart (`SIG`), on a 2-layer no-plane
/// board — the fixture the net-open scenarios build copper on.
fn twoPadPlacement(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
}

fn count(vs: []const drc.Violation) usize {
    var n: usize = 0;
    for (vs) |v| if (v.kind == .net_open) {
        n += 1;
    };
    return n;
}

// spec: placement/drc - the net-open island chain's bounding-box estimate never exceeds the exact nearest approach, so a skipped pair could not have beaten the frontier
test "the island bound never exceeds the exact nearest approach" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Islands of every shape the exact kernels handle: a bare pad, a wide
    // trace run, a barrel, and a mixed island — pairwise, in both orders.
    var bare = Comp{};
    try bare.pads.append(arena, .{ .x0 = -0.4, .y0 = -0.4, .x1 = 0.4, .y1 = 0.4 });
    var run = Comp{};
    try run.tracks.append(arena, .{ .x1 = 3, .y1 = 0, .x2 = 7, .y2 = 0, .layer = 0, .width = 0.8, .net = 0 });
    try run.tracks.append(arena, .{ .x1 = 7, .y1 = 0, .x2 = 7, .y2 = 4, .layer = 0, .width = 0.25, .net = 0 });
    var barrel = Comp{};
    try barrel.vias.append(arena, .{ .x = 1.5, .y = 5, .dia = 0.6, .drill = 0.3, .net = 0 });
    var mixed = Comp{};
    try mixed.pads.append(arena, .{ .x0 = 9.6, .y0 = 5.6, .x1 = 10.4, .y1 = 6.4 });
    try mixed.tracks.append(arena, .{ .x1 = 10, .y1 = 6, .x2 = 12, .y2 = 6, .layer = 0, .width = 0.5, .net = 0 });
    try mixed.vias.append(arena, .{ .x = 12, .y = 6, .dia = 0.4, .drill = 0.2, .net = 0 });

    const islands = [_]*Comp{ &bare, &run, &barrel, &mixed };
    for (islands) |a| {
        for (islands) |b| {
            if (a == b) continue;
            const exact = nearestApproach(a, b).dist;
            try testing.expect(boundGap(boundOf(a), boundOf(b)) <= exact);
        }
    }
    // An empty island has nothing to measure, so its bound must not prune it.
    var nothing = Comp{};
    try testing.expect(boundGap(boundOf(&nothing), boundOf(&run)) == -std.math.inf(f64));
}

// spec: placement/drc - flags a net whose drawn copper splits into disconnected islands at the nearest-approach gap
// spec: placement/drc - A net-open DRC violation carries the two nearest island probe coordinates used to report its missing join
test "two same-net track islands with a small gap flag one net_open at the gap" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // Two collinear 0.2 mm-wide stubs on net 0: one from U1 to x=4.7, the other
    // from C1 back to x=5.3 — a 0.6 mm centreline gap, i.e. a 0.4 mm COPPER-edge
    // gap once each round cap's half-width is taken off (the same capsule
    // convention drc.zig's track↔track uses). It is far too wide to bridge, so
    // the union-find leaves two islands; each carries a pad, so the open is
    // flagged once, marked in the middle of the gap with gap ≈ 0.4.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.3, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vs = try check(arena, placement, .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 1), count(vs));
    const v = vs[0];
    try testing.expectEqual(drc.Kind.net_open, v.kind);
    try testing.expectEqual(drc.Severity.err, v.severity);
    try testing.expect(@abs(v.gap - 0.4) < 0.05); // copper-edge gap ≈ 0.4 mm
    try testing.expect(@abs(v.x - 5.0) < 0.2); // marker in the gap midpoint
    try testing.expect(@abs(v.y - 0.0) < 0.2);
    const bridge = v.who.bridge orelse return error.TestExpectedEqual;
    try testing.expect(@abs(@min(bridge[0], bridge[2]) - 4.7) < 0.05);
    try testing.expect(@abs(@max(bridge[0], bridge[2]) - 5.3) < 0.05);
    try testing.expect(@abs(bridge[1]) < 0.05);
    try testing.expect(@abs(bridge[3]) < 0.05);
}

// spec: fab_readiness - Copper connectivity uses a 1 µm numeric contact tolerance; a same-net 1–20 µm gap stays electrically open and is an error-severity hairline_gap
test "a five micron same-net gap is a hairline error and not a connection" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.205, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const found = try check(arena, twoPadPlacement(&parts, &nets), .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(drc.Kind.hairline_gap, found[0].kind);
    try testing.expectEqual(drc.Severity.err, found[0].severity);
    try testing.expectApproxEqAbs(@as(f64, 0.005), found[0].gap, 1e-6);
}

// spec: placement/drc - A net-open DRC violation names its net and a pad from each copper island it failed to join
test "a net_open names its net and a pad on each side of the gap" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "2", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "2" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // The same split stubs as the flagging test above: U1's island stops short
    // of C1's, so the violation must name SIG plus one pad per island.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.3, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vs = try check(arena, placement, .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 1), count(vs));
    const who = vs[0].who;
    // ONE net (its own), so the second net slot stays empty.
    try testing.expectEqual(@as(i32, 0), who.net_a); // SIG
    try testing.expectEqual(@as(i32, -1), who.net_b);
    // A pad from each island — order follows the MST walk, so accept either.
    const pads_named = [_][]const u8{ who.pad_a, who.pad_b };
    const parts_named = [_]i32{ who.part_a, who.part_b };
    try testing.expect(std.mem.eql(u8, pads_named[0], "1") or std.mem.eql(u8, pads_named[1], "1"));
    try testing.expect(std.mem.eql(u8, pads_named[0], "2") or std.mem.eql(u8, pads_named[1], "2"));
    try testing.expect(parts_named[0] == 0 or parts_named[1] == 0); // U1
    try testing.expect(parts_named[0] == 1 or parts_named[1] == 1); // C1
}

// spec: placement/drc - a track bridging the two islands clears the net-open flag
test "a track joining the two islands produces no net_open" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // One continuous track spanning both pads: a single island, no open.
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const vs = try check(arena, placement, .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 0), count(vs));
}

// spec: placement/physical-net-identity - Alias connectivity does not duplicate parent-only orphan copper into every bypass-stub open-net report
test "a bypass alias borrows parent copper without duplicating parent orphan islands" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const hub_pads = [_]geometry.Pad{.{ .number = "5", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "core/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "core/C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &cap_pads, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "core/U1", .pin = "5" },
        .{ .ref_des = "core/C1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "core/VDD", .pins = &.{} },
        .{ .name = "core/VDD.U1.5", .pins = &pins },
    };
    const loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .cap_gnd = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_gnd = &.{},
        .pwr_net = 1,
        .explicit_pin = "5",
    }};
    var placement = twoPadPlacement(&parts, &nets);
    placement.loops = &loops;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 8, .y1 = 1, .x2 = 9, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
    };
    try testing.expectEqual(@as(usize, 0), count(try check(arena, placement, .{ .tracks = &tracks }, null)));
}

// spec: placement/drc - a via joining two same-net islands across layers clears the net-open flag
test "a via joining the islands across layers produces no net_open" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0, .side = .bottom },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // Top land/run to a via at x=5, then bottom run to the bottom land: the via
    // layer-jump joins the two same-net segments into one island, so no open.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
    };
    const via = [_]router.Via{.{ .x = 5, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const vs = try check(arena, placement, .{ .tracks = &tracks, .vias = &via }, null);
    try testing.expectEqual(@as(usize, 0), count(vs));
}

// spec: placement/drc - a plane-carried net's islands are exempt when each pad reaches the plane
test "a plane-declared net with two thru-pad islands is exempt from net_open" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two GND THROUGH-HOLE pads over the implicit inner ground plane, each with
    // a stub of copper (so the net has drawn copper) that does NOT reach the
    // other. The pads reach the plane through their barrels, so the pour fuses
    // the two islands → no open.
    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.4 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &pins }};
    // No (stackup …) form → implicit planes → GND is plane-carried.
    var placement = twoPadPlacement(&parts, &nets);
    placement.rules = .{};

    // Short stubs at each pad — two copper islands that the plane joins.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 10, .y1 = 0, .x2 = 9, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
    };
    const vs = try check(arena, placement, .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 0), count(vs));
}

// spec: placement/drc - orphan copper touching no pad is flagged as a net-open island
test "an orphan copper island touching no pad is flagged" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // A continuous track joins both pads (one pad-bearing island), plus a
    // floating stub at y=3 that touches NO pad — an orphan copper island.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 4, .y1 = 3, .x2 = 6, .y2 = 3, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vs = try check(arena, placement, .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 1), count(vs));
    try testing.expectEqual(drc.Kind.net_open, vs[0].kind);
}

// spec: placement/drc - two same-net tracks that cross mid-span with no shared endpoint are one island (no net-open)
test "two same-net tracks crossing mid-span are one island, not an open" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // Track A leaves U1 (0,0) heading to (10,10); track B leaves C1 (10,0)
    // heading to (0,10). The two cross mid-span at (5,5) but share NO endpoint
    // — every endpoint sits ~7 mm off the other segment, so the old
    // endpoint-only union left two pad-bearing islands and flagged a phantom
    // open. Capsule overlap (segSegDist = 0 at the crossing) fuses them into
    // one island, so a genuine electrically-connected mesh yields no net_open.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 10, .y1 = 0, .x2 = 0, .y2 = 10, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vs = try check(arena, placement, .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 0), count(vs));
}

// spec: placement/drc - a user copper pour unites its enclosed same-net copper islands so no net-open is flagged
test "a user copper pour joining two same-net islands produces no net_open" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // The same two disconnected pad-bearing stubs as the gap test (0.4 mm copper
    // gap → normally one net_open) …
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.3, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    try testing.expectEqual(@as(usize, 1), count(try check(arena, placement, .{ .tracks = &tracks }, null)));

    // … now a hand-drawn SIG copper pour on the top face encloses both pads,
    // so the two islands share one component through the pour: no open.
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 11, -1 }, .{ 11, 1 }, .{ -1, 1 } };
    const zones = [_]pour.UserZone{.{ .net = "SIG", .layer = 0, .poly = &poly }};
    const vs = try check(arena, placement, .{ .tracks = &tracks, .zones = &zones }, null);
    try testing.expectEqual(@as(usize, 0), count(vs));
}

// spec: placement/drc - a custom copper pour connects pads by real polygon overlap even when neither pad centre lies inside the pour
test "a user copper pour overlapping only the ends of two pads produces no net_open" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // Each 0.6 mm land reaches to x=±0.3 around its centre. The pour begins at
    // x=0.1 and ends at x=9.9: it overlaps 0.2 mm of each land but contains
    // neither centre. Centre-only membership reports a false open; polygon-to-
    // pad copper overlap correctly joins both terminals through the pour.
    const poly = [_][2]f64{ .{ 0.1, -0.4 }, .{ 9.9, -0.4 }, .{ 9.9, 0.4 }, .{ 0.1, 0.4 } };
    const zones = [_]pour.UserZone{.{ .net = "SIG", .layer = 0, .poly = &poly }};
    try testing.expectEqual(@as(usize, 0), count(try check(arena, placement, .{ .zones = &zones }, null)));
}

// spec: placement/drc - a custom copper pour connects a via by circular-land overlap even when the via centre lies outside the pour
test "a user copper pour overlapping pad and via edges joins islands across layers" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0, .side = .bottom },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);
    const tracks = [_]router.Track{.{ .x1 = 8, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]router.Via{.{ .x = 8, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 }};

    // B.Cu pour: 0.2 mm overlap with U1's bottom land at the left and 0.1 mm
    // overlap with the via's 0.2 mm-radius copper disc at the right. Both
    // centres remain outside, matching Barracuda U19's saved custom zones.
    const poly = [_][2]f64{ .{ 0.1, -0.4 }, .{ 7.9, -0.4 }, .{ 7.9, 0.4 }, .{ 0.1, 0.4 } };
    const zones = [_]pour.UserZone{.{ .net = "SIG", .layer = 1, .poly = &poly }};
    try testing.expectEqual(@as(usize, 0), count(try check(arena, placement, .{ .tracks = &tracks, .vias = &vias, .zones = &zones }, null)));
}

// spec: placement/drc - every net earns its own user pour's credit from the run's shared zone raster
test "a second net still earns its user pour's credit" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two independent nets, each a 0.4 mm-gapped stub pair under its own pour.
    // The zone rasters are computed ONCE for the whole run and handed to every
    // net, so a hoist that credited only the first net (or indexed the fills by
    // net order) would leave SIG_B's open standing.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 6 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 6 },
    };
    const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const pins_b = [_]flat_netlist.FlatPin{ .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SIG_A", .pins = &pins_a },
        .{ .name = "SIG_B", .pins = &pins_b },
    };
    const placement: optimizer.Placement = .{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 8,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 12 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.3, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 6, .x2 = 4.7, .y2 = 6, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 5.3, .y1 = 6, .x2 = 10, .y2 = 6, .layer = 0, .width = 0.2, .net = 1 },
    };
    // Bare copper: one open on each net.
    try testing.expectEqual(@as(usize, 2), count(try check(arena, placement, .{ .tracks = &tracks }, null)));

    const poly_a = [_][2]f64{ .{ -1, -1 }, .{ 11, -1 }, .{ 11, 1 }, .{ -1, 1 } };
    const poly_b = [_][2]f64{ .{ -1, 5 }, .{ 11, 5 }, .{ 11, 7 }, .{ -1, 7 } };
    const zones = [_]pour.UserZone{
        .{ .net = "SIG_A", .layer = 0, .poly = &poly_a },
        .{ .net = "SIG_B", .layer = 0, .poly = &poly_b },
    };
    try testing.expectEqual(@as(usize, 0), count(try check(arena, placement, .{ .tracks = &tracks, .zones = &zones }, null)));
}

// spec: placement/drc - an inner-layer user pour unites its enclosed same-net through-hole pads but not SMD pads
test "an inner-layer user pour joins same-net through-hole islands but ignores SMD pads" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The barracuda case: a rail pour on In2.Cu (signal index 2). Two SIG islands
    // (a 0.4 mm-gapped stub pair → normally one net_open) each anchored by a pad.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.3, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    // The inner pour encloses both pad centres.
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 11, -1 }, .{ 11, 1 }, .{ -1, 1 } };
    const zones = [_]pour.UserZone{.{ .net = "SIG", .layer = 2, .poly = &poly }};

    // THROUGH-HOLE pads reach the inner layer → the inner pour unites the two
    // islands: no net_open.
    const thru_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.9, .thru = true, .drill = 0.4 }};
    var thru_parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &thru_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &thru_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const thru_pl = twoPadPlacement(&thru_parts, &nets);
    try testing.expectEqual(@as(usize, 0), count(try check(arena, thru_pl, .{ .tracks = &tracks, .zones = &zones }, null)));

    // SMD pads live on the outer face and never touch the inner layer, so the
    // SAME inner pour does NOT unite them — the open stands.
    const smd_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var smd_parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &smd_pads, .fallback = false, .x = 0, .y = 0, .side = .top },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &smd_pads, .fallback = false, .x = 10, .y = 0, .side = .top },
    };
    const smd_pl = twoPadPlacement(&smd_parts, &nets);
    try testing.expectEqual(@as(usize, 1), count(try check(arena, smd_pl, .{ .tracks = &tracks, .zones = &zones }, null)));
}

// spec: placement/drc - the net-open sweep rasters the board's user pours once for all nets and each net still reads only its own pour
test "one shared zone raster serves every net without crossing pour ownership" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two independent nets, each split into the same 0.4 mm-gapped stub pair:
    // SIG along y = 0, GND along y = 6.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 6 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 6 },
    };
    const sig_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const gnd_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SIG", .pins = &sig_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    var placement = twoPadPlacement(&parts, &nets);
    placement.maxy = 8;
    placement.board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 12 };

    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.3, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 6, .x2 = 4.7, .y2 = 6, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 5.3, .y1 = 6, .x2 = 10, .y2 = 6, .layer = 0, .width = 0.2, .net = 1 },
    };
    // Both nets open with no pour at all: one violation each.
    try testing.expectEqual(@as(usize, 2), count(try check(arena, placement, .{ .tracks = &tracks }, null)));

    // ONE hand-drawn pour, owned by SIG, drawn wide enough to enclose BOTH
    // bands. The sweep rasters it once and hands the same fill to every net, so
    // this is where a hoist that lost net ownership would show: SIG must close,
    // and GND — whose islands sit under the very same copper — must stay open.
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 11, -1 }, .{ 11, 7 }, .{ -1, 7 } };
    const zones = [_]pour.UserZone{.{ .net = "SIG", .layer = 0, .poly = &poly }};
    const vs = try check(arena, placement, .{ .tracks = &tracks, .zones = &zones }, null);
    try testing.expectEqual(@as(usize, 1), count(vs));
    try testing.expectEqual(@as(i32, 1), vs[0].who.net_a); // GND, not SIG

    // Flip the pour's owner and the verdict flips with it — the shared raster
    // is identical, only the ownership test differs.
    const gnd_zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &poly }};
    const flipped = try check(arena, placement, .{ .tracks = &tracks, .zones = &gnd_zones }, null);
    try testing.expectEqual(@as(usize, 1), count(flipped));
    try testing.expectEqual(@as(i32, 0), flipped[0].who.net_a); // SIG
}

// spec: placement/drc - a pad no copper ever reached is a net-open island, not silently excused as unrouted
test "a pad the routed copper never reached is flagged as its own island" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // barracuda's hmc451/C112 in miniature: U1 and C1 are joined by real copper,
    // and a THIRD same-net pad (C2) sits 6 mm away with nothing on it. The old
    // pass dropped that island for holding no track/via ("unrouted, the
    // ratsnest's job") and reported a clean net, while the fab gate refused the
    // very same net as an airwire. It is one island of bare pad copper now.
    const one = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &one, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &one, .fallback = false, .x = 10, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 1, .pads = &one, .fallback = false, .x = 4, .y = 6 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const vs = try check(arena, placement, .{ .tracks = &tracks }, null);
    try testing.expectEqual(@as(usize, 1), count(vs));
    const v = vs[0];
    try testing.expectEqual(drc.Severity.err, v.severity);
    // The bare pad is named as one side of the open …
    try testing.expect(v.who.part_a == 2 or v.who.part_b == 2); // C2
    // … and the gap is measured to its pad copper (6 mm centre − 0.3 mm pad
    // half-height − 0.1 mm track half-width ≈ 5.6 mm), not left at infinity.
    try testing.expect(@abs(v.gap - 5.6) < 0.2);

    // Route to it and the flag clears — the island had no copper, nothing else.
    const joined = [_]router.Track{
        tracks[0],
        .{ .x1 = 4, .y1 = 0, .x2 = 4, .y2 = 6, .layer = 0, .width = 0.2, .net = 0 },
    };
    try testing.expectEqual(@as(usize, 0), count(try check(arena, placement, .{ .tracks = &joined }, null)));
}

// spec: placement/drc - a routable net with no drawn copper at all is flagged, matching the fab gate's airwire verdict
test "a net with two pads and no copper flags one net_open" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const one = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &one, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &one, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = twoPadPlacement(&parts, &nets);

    // No tracks, no vias: `fab_readiness.routableTally` calls SIG routable and
    // unconnected, so the marker has to agree instead of staying silent.
    const report = try checkWithConnectivity(arena, placement, .{}, .{});
    try testing.expectEqual(@as(usize, 1), count(report.violations));
    try testing.expectEqual(nets.len, report.connectivity.len);
    const tally = try fab.summarizeConnectivity(arena, report.connectivity);
    try testing.expectEqual(@as(usize, 1), tally.total);
    try testing.expectEqual(@as(usize, 0), tally.routed);

    // A single-pad net needs no copper — it must stay silent on both surfaces.
    const solo_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const solo = [_]flat_netlist.FlatNet{.{ .name = "NC1", .pins = &solo_pins }};
    const solo_pl = twoPadPlacement(&parts, &solo);
    try testing.expectEqual(@as(usize, 0), count(try check(arena, solo_pl, .{}, null)));
}
