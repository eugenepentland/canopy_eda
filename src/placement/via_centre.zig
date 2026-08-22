//! Via-in-pad discipline — where a barrel standing on a same-net land belongs,
//! and what copper it makes redundant.
//!
//! The rule, in the board owner's own words (2026-08-12):
//!
//! > "If there is a via in pad being made, can you make it so the via by
//! >  default is placed in the center of the pad if there are no other
//! >  obstructions preventing that?"
//!
//! and, on the same board's `LMX_VTUNE`:
//!
//! > "there is still a short stub being drawn on the top side and the bottom
//! >  side of the board … the via is directly in the pad and it goes to the
//! >  opposite side of the board so there is no reason to have the trace."
//!
//! Those are one rule seen from its two ends. A via in a land is the pad's
//! connection to the other side, so it belongs where the pad's connection
//! belongs — the centre — and once it is there the copper that used to reach it
//! from the centre has zero length and simply stops existing.
//!
//! ## Why a POST-PASS and not a rule inside each emitter
//!
//! A dozen places put a barrel down: the plane stitcher's `findGroundVia`
//! (grid-snapped pad anchor, then `plane_via.InPad`'s ring walk), the maze's
//! layer change (a grid NODE, so off-centre by construction — up to half a pitch,
//! ~0.22 mm on these boards), the direct-hop lattice, the escape-stub fan, the
//! zone via-in-pad drop, hand copper through `add_tracks`. Each has its own
//! reason for the coordinate it picks and none of them is wrong about it; what
//! they lack is the last word. Asking the question ONCE over the finished via
//! list is the only version of this rule that every emitter obeys — and it is
//! also the only version the client-side DRC, the Gerber/Excellon writers and
//! KiCad sync automatically agree with, because all of them read that same
//! finished list and none of them re-derives a via site.
//!
//! ## What it may never cost
//!
//! Connectivity, and clearance. So a move is refused unless
//!
//!   * the target sits on the pad's REAL copper (`pad_shape.pointDist == 0`, so
//!     a rounded land's box centre still has to be inside the outline);
//!   * the barrel clears every foreign pad, every other barrel, every foreign
//!     track and every drill at the target (`route_cleanup.viaSiteClears`, the
//!     same predicate the terminal-via snap is guarded by);
//!   * every leg that ENDED on the old barrel still probes clear once
//!     re-anchored on the new one;
//!   * and every same-net track that merely TOUCHED the old barrel still
//!     touches the new one, or touches the land itself — a barrel that walks out
//!     from under somebody's copper would open the net on the far layer.
//!
//! A refusal keeps the via exactly where it stood. Nothing here relaxes a rule:
//! a same-net barrel inside its own land has always been legal copper (the
//! clearance probes skip same-net pads by design), and this only decides WHERE
//! inside the land it stands.
//!
//! ## The copper the centring makes redundant
//!
//! `netWithoutRedundant` is the second half. A land is one solid conductor, so a
//! chain both of whose ends lie on ONE same-net land, and which everything else
//! touches only ON that land, joins nothing the land does not already join. It
//! is `pad_entry.whollyOnLand` asked topologically instead of vertex by vertex —
//! which is what it takes to see straps-synth-lmx2595's `LMX_VTUNE` hairpin on
//! R4, a 0.367 mm out-and-back that pokes 0.06 mm past the land edge (so no
//! vertex test catches it) and whose two ends are 0.011 mm apart on the land
//! (so no loose-end test catches it either — both ends terminate on the pad).
//!
//! That argument is true of far more copper than it is SAFE to remove, and the
//! difference cost a routed net before it was bounded. Four conditions narrow it
//! to the shape it exists for, and three of them were measured rather than
//! reasoned (barracuda, `bench-route`, 2026-08-12 — the unbounded rule took 32
//! chains and 29 mm off the board and opened `V_12V`, 79/92 → 78/92):
//!
//!   * the land must carry a same-net BARREL. That is the premise — this pad's
//!     net continues through a via standing on its own copper — and it is the
//!     one condition that made barracuda whole again (79/92 restored, and the
//!     rule still takes the hairpin). A land with no barrel has no such story.
//!   * the land may not be a thermal PADDLE (`land_transit.paddle_min_half_mm`):
//!     a paddle's two corners are millimetres apart and everything between them
//!     is somebody's leg.
//!   * the chain may be no longer than the land's own diagonal plus an escape
//!     zone at each end, and no VERTEX of it may leave the land by more than one
//!     escape zone. Together those say "this copper could not have gone
//!     anywhere", which a stub running out to a barrel OUTSIDE its land fails.
//!
//! Deliberately out of scope: THROUGH-HOLE pads (the barrel is the connection on
//! every layer already), declared differential pairs and `(max-freq …)`
//! escape-ruled nets (their geometry is authored or length-matched, and moving a
//! barrel under one would spend skew this pass has no way to give back), and any
//! net outside a scoped route's selection (that copper is the caller's).

const std = @import("std");
const bend_smooth = @import("bend_smooth.zig");
const diff_pairs = @import("diff_pairs.zig");
const land_transit = @import("land_transit.zig");
const optimizer = @import("optimizer.zig");
const pad_shape = @import("pad_shape.zig");
const route_cleanup = @import("route_cleanup.zig");
const router = @import("router.zig");

const Track = router.Track;
const Via = router.Via;
const PadObs = router.PadObs;
const Board = router.CleanupBoard;

/// How close a track endpoint must be to a barrel's centre to count as
/// TERMINATING on it (mm) — the same tolerance `pad_entry.via_snap` uses, and
/// for the same reason: only the drift of a coordinate that has been through a
/// world→grid→world round trip.
const via_snap_mm: f64 = 0.01;

/// Below this the barrel is already centred and the move is a no-op (mm). Well
/// under fab resolution, so it only skips float noise.
const centred_eps_mm: f64 = 1e-9;

/// Touch slack for "this copper reaches that land" (mm) — kept in step with
/// `route_cleanup`'s island model, so a chain this pass calls redundant is one
/// the connectivity oracle also reads as held by the land.
const touch_slack_mm: f64 = 0.02;

/// How far past a land copper may reach and still be its stub (mm) — the escape
/// discipline's own clearance, so "local" here means the same thing it does one
/// rung up the ladder.
const pad_escape_clear_mm: f64 = 0.15;

/// Centre every same-net in-pad barrel that can be centred, then drop the copper
/// that leaves behind. Runs at the end of the finish, before `pad_escape`, so
/// the escape rays are drawn against the barrels that ship.
///
/// One NET at a time, and each net is a transaction: its copper before and
/// after is run through the island model (`route_cleanup.countCopperIslands`,
/// the same union-find the `net_open` DRC and the connectivity oracle use) and
/// the whole net is rolled back if its pads came out in more pieces than they
/// went in. The per-object guards below are all sound arguments, but an
/// argument is not a proof and this rule may not cost connectivity — so the
/// board is asked rather than reasoned about. It is also what makes the pass
/// safe on shapes nobody has thought of yet: a pour it cannot see, a rescue
/// hop it does not model, a plane contact it does not know about.
pub fn passBoard(board: Board) std.mem.Allocator.Error!void {
    const ctx = board.ctx;
    // Every probe below runs against copper this pass is MOVING, so the spatial
    // index is invalidated once up front and left invalid: the probes fall back
    // to their linear scan over the live lists, which is the only view that
    // stays true while barrels walk (`pad_escape` rebuilds it per net after us).
    router.copperCompacted(ctx);
    for (0..board.placement.nets.len) |net_i| {
        if (!mayCentre(board.placement, ctx.selected_nets, @intCast(net_i))) continue;
        try passNet(board, @intCast(net_i));
    }
}

/// One net's transaction: centre its in-pad barrels, drop the copper its lands
/// already provide, and put every bit of it back if that left its pads in more
/// islands than before.
fn passNet(board: Board, ni: i32) std.mem.Allocator.Error!void {
    const arena = board.ctx.arena;
    const pads = try netPads(arena, board.ctx.obs, ni);
    if (pads.len == 0) return;
    const was_tracks = try netTracks(arena, board.tracks.items, ni);
    const was_vias = try netViaSites(arena, board.vias.items, ni);
    var changed = centreNetVias(board, ni);
    if (try dropNetRedundant(board, ni)) changed = true;
    if (!changed) return;
    const before = try padIslands(arena, pads, was_tracks, try restoredVias(arena, board.vias.items, was_vias));
    const after = try padIslands(arena, pads, try netTracks(arena, board.tracks.items, ni), try netVias(arena, board.vias.items, ni));
    if (after <= before) return;
    // Refused: the net keeps every barrel and every millimetre it had.
    for (was_vias) |site| {
        board.vias.items[site.index].x = site.at[0];
        board.vias.items[site.index].y = site.at[1];
    }
    route_cleanup.removeNetTracks(board.tracks, ni);
    try board.tracks.appendSlice(arena, was_tracks);
}

/// Move this net's barrels standing on one of its own SMD lands onto that
/// land's centre, where the guards allow it. Vias are walked in list order and
/// the first containing pad in obstacle order is the one chosen, so the result
/// is a function of the board alone.
fn centreNetVias(board: Board, ni: i32) bool {
    const ctx = board.ctx;
    var moved = false;
    for (board.vias.items, 0..) |via, vi| {
        if (via.net != ni) continue;
        const pad = landUnder(ctx.obs, via) orelse continue;
        const target = padCentre(pad);
        if (std.math.hypot(target[0] - via.x, target[1] - via.y) <= centred_eps_mm) continue;
        if (shapeOf(pad).pointDistTo(target) > 0) continue;
        router.setNetParams(ctx, board.placement, @intCast(ni)); // per-net clearance
        if (!route_cleanup.viaSiteClears(board, board.tracks.items, board.vias.items, vi, target[0], target[1])) continue;
        if (!legsSurvive(board, vi, pad, target)) continue;
        board.vias.items[vi].x = target[0];
        board.vias.items[vi].y = target[1];
        applyReanchor(board, via, target);
        moved = true;
    }
    return moved;
}

/// Where one via of the net stands, and which slot of the board's list it is —
/// everything a rollback needs, since this pass never adds or removes a barrel.
const ViaSite = struct { index: usize, at: [2]f64 };

fn netPads(arena: std.mem.Allocator, obs: []const PadObs, ni: i32) std.mem.Allocator.Error![]const PadObs {
    var out: std.ArrayList(PadObs) = .empty;
    for (obs) |o| {
        if (o.net == ni) try out.append(arena, o);
    }
    return out.toOwnedSlice(arena);
}

fn netTracks(arena: std.mem.Allocator, tracks: []const Track, ni: i32) std.mem.Allocator.Error![]const Track {
    var out: std.ArrayList(Track) = .empty;
    for (tracks) |t| {
        if (t.net == ni) try out.append(arena, t);
    }
    return out.toOwnedSlice(arena);
}

fn netVias(arena: std.mem.Allocator, vias: []const Via, ni: i32) std.mem.Allocator.Error![]const Via {
    var out: std.ArrayList(Via) = .empty;
    for (vias) |v| {
        if (v.net == ni) try out.append(arena, v);
    }
    return out.toOwnedSlice(arena);
}

fn netViaSites(arena: std.mem.Allocator, vias: []const Via, ni: i32) std.mem.Allocator.Error![]const ViaSite {
    var out: std.ArrayList(ViaSite) = .empty;
    for (vias, 0..) |v, i| {
        if (v.net == ni) try out.append(arena, .{ .index = i, .at = .{ v.x, v.y } });
    }
    return out.toOwnedSlice(arena);
}

/// This net's barrels as they stood BEFORE the pass — the live records with the
/// recorded coordinates put back, so the "before" island count is measured on
/// the same objects the "after" one is.
fn restoredVias(arena: std.mem.Allocator, vias: []const Via, sites: []const ViaSite) std.mem.Allocator.Error![]const Via {
    const out = try arena.alloc(Via, sites.len);
    for (sites, out) |site, *v| {
        v.* = vias[site.index];
        v.x = site.at[0];
        v.y = site.at[1];
    }
    return out;
}

/// How many pieces this net's PADS come in, over the island model
/// `route_cleanup.countCopperIslands` builds — the count the `net_open` rule
/// reads. Pads occupy the first `pads.len` union-find nodes.
fn padIslands(
    arena: std.mem.Allocator,
    pads: []const PadObs,
    tracks: []const Track,
    vias: []const Via,
) std.mem.Allocator.Error!usize {
    var parent: []usize = &.{};
    _ = try route_cleanup.countCopperIslands(arena, pads, tracks, vias, &parent);
    var roots: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (0..pads.len) |i| try roots.put(arena, findRoot(parent, i), {});
    return roots.count();
}

fn findRoot(parent: []const usize, start: usize) usize {
    var i = start;
    while (parent[i] != i) i = parent[i];
    return i;
}

/// May this net's barrels be re-sited at all? Retained (out-of-scope) copper,
/// differential-pair legs and `(max-freq …)` escape-ruled nets are left alone —
/// see the module header.
fn mayCentre(placement: optimizer.Placement, selected: []const bool, net: i32) bool {
    if (net < 0) return false;
    const ni: usize = @intCast(net);
    if (selected.len > 0 and (ni >= selected.len or !selected[ni])) return false;
    for (placement.diff_pairs) |dp| {
        if (dp.p == ni or dp.n == ni) return false;
    }
    if (ni < placement.rules.net.len and placement.rules.net[ni].rf.escape_mm > 0) return false;
    return true;
}

/// The same-net SMD land this barrel stands on, or null. Through-hole pads are
/// skipped: their own barrel is the connection, and a via inside one is a
/// drill-to-drill question, not a centring one.
fn landUnder(obs: []const PadObs, via: Via) ?PadObs {
    for (obs) |o| {
        if (o.net != via.net or o.thru) continue;
        if (shapeOf(o).pointDistTo(.{ via.x, via.y }) > 0) continue;
        return o;
    }
    return null;
}

fn padCentre(o: PadObs) [2]f64 {
    return .{ (o.x0 + o.x1) / 2, (o.y0 + o.y1) / 2 };
}

/// A pad's copper outline, with the two containment questions this pass asks.
const Land = struct {
    shape: pad_shape.Shape,

    /// Distance from `p` to the land's real copper — 0 when `p` is on it.
    fn pointDistTo(self: Land, p: [2]f64) f64 {
        return pad_shape.pointDist(self.shape.x0, self.shape.y0, self.shape.x1, self.shape.y1, self.shape.poly, p[0], p[1], std.math.inf(f64));
    }

    /// Does the segment `a`→`b` reach this land's copper within `slack`?
    fn reaches(self: Land, a: [2]f64, b: [2]f64, slack: f64) bool {
        return pad_shape.segmentDist(self.shape, a, b, slack) <= slack;
    }
};

fn shapeOf(o: PadObs) Land {
    return .{ .shape = .{ .x0 = o.x0, .y0 = o.y0, .x1 = o.x1, .y1 = o.y1, .poly = o.poly } };
}

/// Would every leg the old barrel carried still be carried by the new one?
///
/// A leg that ENDS on the barrel travels with it, so it is judged re-anchored —
/// and re-probed, because moving its end moves the whole segment. A leg that
/// merely crosses the barrel does not travel, so it must still touch the moved
/// barrel or touch the land the barrel now stands in the middle of; otherwise the
/// far layer's copper is left hanging on nothing and the net opens.
fn legsSurvive(board: Board, vi: usize, pad: PadObs, target: [2]f64) bool {
    const via = board.vias.items[vi];
    const land = shapeOf(pad);
    // A same-net barrel this one OVERLAPS is united with it by that overlap
    // alone — the island model unites two vias whose copper meets. Walking out
    // from under such a neighbour breaks that union unless the neighbour also
    // stands on this land, and it cannot be re-made: the clearance guard the
    // caller ran will not let the barrel land touching anything anyway.
    for (board.vias.items, 0..) |o, oi| {
        if (oi == vi or o.net != via.net) continue;
        const reach = (o.dia + via.dia) / 2;
        if (std.math.hypot(o.x - via.x, o.y - via.y) > reach) continue;
        if (std.math.hypot(o.x - target[0], o.y - target[1]) <= reach) continue;
        if (land.pointDistTo(.{ o.x, o.y }) > 0) return false;
    }
    const probe = router.TautProbe{ .run = .{
        .ctx = board.ctx,
        .net = via.net,
        .tracks = board.tracks,
        .vias = board.vias,
    } };
    for (board.tracks.items) |t| {
        if (t.net != via.net) continue;
        if (reanchored(t, via, target)) |cand| {
            if (!probe.clear(cand.layer, .{ cand.x1, cand.y1 }, .{ cand.x2, cand.y2 })) return false;
            continue;
        }
        const reach = via.dia / 2 + t.width / 2;
        const a = [2]f64{ t.x1, t.y1 };
        const b = [2]f64{ t.x2, t.y2 };
        if (pad_shape.segPointDist(a[0], a[1], b[0], b[1], via.x, via.y) > reach) continue;
        if (pad_shape.segPointDist(a[0], a[1], b[0], b[1], target[0], target[1]) <= reach) continue;
        // The land can only stand in for the barrel on the face it IS copper on.
        if (t.layer == pad.layer and land.reaches(a, b, touch_slack_mm)) continue;
        return false;
    }
    return true;
}

/// `t` with every endpoint standing on `via` moved onto `target`, or null when
/// the track does not terminate at that barrel.
fn reanchored(t: Track, via: Via, target: [2]f64) ?Track {
    var out = t;
    var hit = false;
    if (std.math.hypot(t.x1 - via.x, t.y1 - via.y) <= via_snap_mm) {
        out.x1 = target[0];
        out.y1 = target[1];
        hit = true;
    }
    if (std.math.hypot(t.x2 - via.x, t.y2 - via.y) <= via_snap_mm) {
        out.x2 = target[0];
        out.y2 = target[1];
        hit = true;
    }
    return if (hit) out else null;
}

fn applyReanchor(board: Board, via: Via, target: [2]f64) void {
    for (board.tracks.items) |*t| {
        if (t.net != via.net) continue;
        if (reanchored(t.*, via, target)) |cand| t.* = cand;
    }
}

// ── Redundant land copper ───────────────────────────────────────────────────

/// Drop this net's chains that one of its own lands already joins.
///
/// The land is one solid conductor, so a chain whose two ends both lie on it and
/// which every other object touches only ON it can be removed without changing
/// what is connected to what. That is the topological form of
/// `pad_entry.whollyOnLand`, and it sees a shape the vertex test cannot: copper
/// that leaves the land and comes back.
fn dropNetRedundant(board: Board, ni: i32) std.mem.Allocator.Error!bool {
    const rebuilt = (try netWithoutRedundant(board, ni)) orelse return false;
    route_cleanup.removeNetTracks(board.tracks, ni);
    try board.tracks.appendSlice(board.ctx.arena, rebuilt);
    return true;
}

/// One net's copper with its land-redundant chains removed, or null when it has
/// none.
fn netWithoutRedundant(board: Board, ni: i32) std.mem.Allocator.Error!?[]const Track {
    const arena = board.ctx.arena;
    var mine: std.ArrayList(Track) = .empty;
    for (board.tracks.items) |t| {
        if (t.net == ni and segLen(t) > 0) try mine.append(arena, t);
    }
    if (mine.items.len == 0) return null;
    var out: std.ArrayList(Track) = .empty;
    var dropped = false;
    var layer: u8 = 0;
    const top = maxLayer(mine.items);
    while (true) : (layer += 1) {
        var segs: std.ArrayList(Track) = .empty;
        for (mine.items) |t| {
            if (t.layer == layer) try segs.append(arena, t);
        }
        if (segs.items.len > 0) {
            const chains = try bend_smooth.extractChains(arena, segs.items);
            for (chains, 0..) |chain, ci| {
                if (redundantOnLand(board, ni, layer, chains, ci)) {
                    dropped = true;
                    continue;
                }
                const width = if (chain.widths.len > 0) chain.widths[0] else segs.items[0].width;
                try emitChain(arena, &out, chain.pts, layer, width, ni);
            }
        }
        if (layer >= top) break;
    }
    return if (dropped) try out.toOwnedSlice(arena) else null;
}

/// Is chain `ci` copper that its own land already provides?
///
/// The proof the answer rests on: after the chain is gone, every object it was
/// united with must still be united with the LAND, and the land is not going
/// anywhere. So each toucher is checked for its own hold on the land — a via
/// standing on it, another chain reaching it — and one that has none refuses the
/// drop. Another same-net pad this copper crosses refuses outright: this chain
/// may be all that holds it, and nothing here can tell.
fn redundantOnLand(
    board: Board,
    ni: i32,
    layer: u8,
    chains: []const bend_smooth.Chain,
    ci: usize,
) bool {
    const pts = chains[ci].pts;
    if (pts.len < 2) return false;
    const pad = landHoldingBothEnds(board.ctx.obs, ni, layer, pts) orelse return false;
    // Only LOCAL copper. A run whose two ends happen to share one land can still
    // be a real route the whole way across a board — a thermal paddle's two
    // corners are 3 mm apart and everything between them is somebody's leg — and
    // an argument that the land "already joins" it is worth nothing against a
    // net that opens three passes later. So the rule is confined to copper that
    // could not have gone anywhere: no paddle, and no longer than the land's own
    // diagonal plus the escape zone at each end.
    if (isPaddle(pad)) return false;
    if (polylineLength(pts) > localReach(pad)) return false;
    const land = shapeOf(pad);
    // The land must carry a same-net BARREL, because that is the premise the
    // whole rule rests on: this pad's net continues through a via standing on
    // its own copper, so the surface copper reaching that via is copper the
    // land already is. A land with no barrel on it has no such story, and its
    // copper is somebody's connection however local it looks.
    if (!barrelOnLand(board.vias.items, ni, land)) return false;
    // …and it may not LEAVE the land by more than the escape zone. That is what
    // separates the shape this exists for — an out-and-back that pokes 0.06 mm
    // past an 0402's edge — from a stub running out to a barrel that stands
    // OUTSIDE the land, which is a real connection and the land cannot replace
    // it. Measured 2026-08-12: without this bound the rule took 32 chains and
    // 29 mm off barracuda and opened `V_12V` (bench-route 79/92 -> 78/92).
    for (pts) |p| {
        if (land.pointDistTo(p) > pad_escape_clear_mm) return false;
    }
    const half = halfWidth(chains[ci]);
    for (board.ctx.obs) |o| {
        if (o.net != ni or o.thru or o.layer != layer) continue;
        if (o.x0 == pad.x0 and o.y0 == pad.y0 and o.x1 == pad.x1 and o.y1 == pad.y1) continue;
        if (reachesLand(shapeOf(o), pts, half + touch_slack_mm)) return false;
    }
    for (board.vias.items) |v| {
        if (v.net != ni) continue;
        if (!nearPolyline(pts, .{ v.x, v.y }, v.dia / 2 + half)) continue;
        if (land.pointDistTo(.{ v.x, v.y }) > 0) return false;
    }
    for (chains, 0..) |other, oi| {
        if (oi == ci) continue;
        if (!chainsTouch(pts, half, other)) continue;
        // The other chain survives; it only stays connected if IT reaches the
        // land too. A vertex test is not enough here — two chains can cross
        // without sharing one — so the whole polyline is measured.
        if (!reachesLand(land, other.pts, halfWidth(other) + touch_slack_mm)) return false;
    }
    return true;
}

/// Does one of this net's barrels stand on `land`?
fn barrelOnLand(vias: []const Via, ni: i32, land: Land) bool {
    for (vias) |v| {
        if (v.net != ni) continue;
        if (land.pointDistTo(.{ v.x, v.y }) == 0) return true;
    }
    return false;
}

/// Is this land a thermal paddle rather than a lead land? Same threshold
/// `land_transit` judges the same shape by — a paddle is not entered on a ray
/// and copper crossing it is not a stub.
fn isPaddle(o: PadObs) bool {
    return (o.x1 - o.x0) / 2 >= land_transit.paddle_min_half_mm and
        (o.y1 - o.y0) / 2 >= land_transit.paddle_min_half_mm;
}

/// How long a chain on this land may be and still be copper the land plainly
/// replaces: the land's diagonal (the furthest two points on it) plus one
/// escape zone at each end, which is as far as copper can reach past the land
/// and still be a stub rather than a route.
fn localReach(o: PadObs) f64 {
    return std.math.hypot(o.x1 - o.x0, o.y1 - o.y0) + 2 * pad_escape_clear_mm;
}

fn polylineLength(pts: []const [2]f64) f64 {
    var sum: f64 = 0;
    for (1..pts.len) |i| sum += std.math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
    return sum;
}

fn halfWidth(chain: bend_smooth.Chain) f64 {
    var w: f64 = 0;
    for (chain.widths) |x| w = @max(w, x);
    return w / 2;
}

/// Does any segment of `pts` reach `land`'s copper within `slack`?
fn reachesLand(land: Land, pts: []const [2]f64, slack: f64) bool {
    for (1..pts.len) |i| {
        if (land.reaches(pts[i - 1], pts[i], slack)) return true;
    }
    return false;
}

/// Do the two polylines' swept copper meet anywhere?
fn chainsTouch(pts: []const [2]f64, half: f64, other: bend_smooth.Chain) bool {
    const reach = half + halfWidth(other) + touch_slack_mm;
    for (1..pts.len) |i| {
        for (1..other.pts.len) |j| {
            if (pad_shape.segSegDist(pts[i - 1], pts[i], other.pts[j - 1], other.pts[j]) <= reach) return true;
        }
    }
    return false;
}

/// The one same-net land, copper on THIS layer, that holds both ends of the
/// chain — or null when the ends sit on different pads or on none.
fn landHoldingBothEnds(obs: []const PadObs, ni: i32, layer: u8, pts: []const [2]f64) ?PadObs {
    const head = pts[0];
    const tail = pts[pts.len - 1];
    for (obs) |o| {
        if (o.net != ni or o.thru or o.layer != layer) continue;
        const land = shapeOf(o);
        if (land.pointDistTo(head) > 0) continue;
        if (land.pointDistTo(tail) > 0) continue;
        return o;
    }
    return null;
}

fn nearPolyline(pts: []const [2]f64, p: [2]f64, reach: f64) bool {
    for (1..pts.len) |i| {
        if (pad_shape.segPointDist(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1], p[0], p[1]) <= reach) return true;
    }
    return false;
}

fn emitChain(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Track),
    pts: []const [2]f64,
    layer: u8,
    width: f64,
    net: i32,
) std.mem.Allocator.Error!void {
    for (1..pts.len) |i| {
        try out.append(arena, .{
            .x1 = pts[i - 1][0],
            .y1 = pts[i - 1][1],
            .x2 = pts[i][0],
            .y2 = pts[i][1],
            .layer = layer,
            .width = width,
            .net = net,
        });
    }
}

fn segLen(t: Track) f64 {
    return std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
}

fn maxLayer(tracks: []const Track) u8 {
    var m: u8 = 0;
    for (tracks) |t| {
        if (t.layer > m) m = t.layer;
    }
    return m;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A 0.54 × 0.64 mm 0402 land centred on the origin, on the top layer of net 1.
fn land0402(net: i32) PadObs {
    return .{ .x0 = -0.27, .y0 = -0.32, .x1 = 0.27, .y1 = 0.32, .poly = &.{}, .net = net, .layer = 0, .thru = false };
}

// spec: placement/via-centre - a barrel standing on a same-net land is sited on that land's centre
test "the land under a barrel is the land it is centred on" {
    const pad = land0402(1);
    const off = Via{ .x = 0.13, .y = -0.09, .dia = 0.4, .drill = 0.2, .net = 1 };
    const obs = [_]PadObs{pad};
    const found = landUnder(&obs, off) orelse return error.TestExpectedLand;
    try testing.expectEqual(@as(i32, 1), found.net);
    const c = padCentre(found);
    try testing.expectApproxEqAbs(@as(f64, 0), c[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), c[1], 1e-12);
    // …and the same barrel on a FOREIGN land is not this pass's business
    try testing.expect(landUnder(&[_]PadObs{land0402(2)}, off) == null);
}

// spec: placement/via-centre - a through-hole pad is never centred on, since its own barrel is already the connection
test "a through-hole pad holds no centring candidate" {
    var thru = land0402(1);
    thru.thru = true;
    const off = Via{ .x = 0.1, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 };
    try testing.expect(landUnder(&[_]PadObs{thru}, off) == null);
}

// spec: placement/via-centre - a leg terminating on a barrel travels with it, so centring re-anchors it rather than breaking it
test "a leg that ends on the barrel is re-anchored onto the new site" {
    const via = Via{ .x = 0.13, .y = -0.09, .dia = 0.4, .drill = 0.2, .net = 1 };
    const leg = Track{ .x1 = 2, .y1 = 2, .x2 = 0.13, .y2 = -0.09, .layer = 1, .width = 0.127, .net = 1 };
    const moved = reanchored(leg, via, .{ 0, 0 }) orelse return error.TestExpectedReanchor;
    try testing.expectApproxEqAbs(@as(f64, 0), moved.x2, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), moved.y2, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), moved.x1, 1e-12); // the far end is untouched
    // a leg nowhere near the barrel is not re-anchored at all
    const far = Track{ .x1 = 5, .y1 = 5, .x2 = 6, .y2 = 6, .layer = 1, .width = 0.127, .net = 1 };
    try testing.expect(reanchored(far, via, .{ 0, 0 }) == null);
}

// spec: placement/via-centre - a chain both of whose ends lie on one same-net land, touched by nothing off that land, is copper the land already provides
test "an out-and-back hairpin on one land is redundant" {
    const pad = land0402(1);
    const land = shapeOf(pad);
    // straps-synth-lmx2595's LMX_VTUNE hairpin on R4, translated to the origin:
    // out past the land's edge and back, both ends on the land.
    const hairpin = [_][2]f64{ .{ 0, 0.15 }, .{ 0, 0.3835 }, .{ 0.0107, 0.1502 } };
    try testing.expect(land.pointDistTo(hairpin[0]) == 0);
    try testing.expect(land.pointDistTo(hairpin[2]) == 0);
    try testing.expect(land.pointDistTo(hairpin[1]) > 0); // …and it DOES leave the land
    // a run that ends off the land is a real connection, not redundant copper
    const run = [_][2]f64{ .{ 0, 0 }, .{ 0, 2 } };
    try testing.expect(land.pointDistTo(run[1]) > 0);
}

// spec: placement/via-centre - redundant land copper is dropped only where a same-net barrel stands on that land, and only while the chain stays local to it
test "the drop is confined to local copper on a land that carries a barrel" {
    const pad = land0402(1);
    const land = shapeOf(pad);
    const on = [_]Via{.{ .x = 0.1, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 }};
    try testing.expect(barrelOnLand(&on, 1, land));
    // a barrel just outside the land is not the premise — its stub is a real leg
    const off = [_]Via{.{ .x = 0.6, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 }};
    try testing.expect(!barrelOnLand(&off, 1, land));
    try testing.expect(!barrelOnLand(&on, 2, land)); // …nor is a foreign net's
    // an 0402 land is a lead land; a 2 mm square is a thermal paddle
    try testing.expect(!isPaddle(pad));
    try testing.expect(isPaddle(.{ .x0 = -1, .y0 = -1, .x1 = 1, .y1 = 1, .net = 1 }));
    // the hairpin is inside the local reach; a run twice the land is not
    const hairpin = [_][2]f64{ .{ 0, 0.15 }, .{ 0, 0.3835 }, .{ 0.0107, 0.1502 } };
    try testing.expect(polylineLength(&hairpin) <= localReach(pad));
    const run = [_][2]f64{ .{ 0, 0 }, .{ 0, 2 } };
    try testing.expect(polylineLength(&run) > localReach(pad));
}

// spec: placement/via-centre - a differential pair leg is never re-sited, so a matched pair's skew survives the pass
test "diff-pair legs, escape-ruled and out-of-scope nets are left alone" {
    var pairs = [_]diff_pairs.DiffPair{.{ .p = 0, .n = 1, .gap = 0.2 }};
    var rules = [_]optimizer.NetRule{ .{}, .{}, .{ .rf = .{ .escape_mm = 1.0 } }, .{} };
    var placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .diff_pairs = &pairs,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    placement.rules.net = &rules;
    try testing.expect(!mayCentre(placement, &.{}, 0)); // P leg
    try testing.expect(!mayCentre(placement, &.{}, 1)); // N leg
    try testing.expect(!mayCentre(placement, &.{}, 2)); // (max-freq …) escape-ruled
    try testing.expect(!mayCentre(placement, &.{}, -1)); // foreign / retained copper
    try testing.expect(mayCentre(placement, &.{}, 3)); // an ordinary net IS this pass's business
    // …and in a SCOPED route only the selected nets are, since the rest is the
    // caller's retained copper echoed back unchanged.
    const scope = [_]bool{ false, false, false, false };
    try testing.expect(!mayCentre(placement, &scope, 3));
}
