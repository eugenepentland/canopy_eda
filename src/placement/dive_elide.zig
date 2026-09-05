//! Needless-dive elision — deleting a routed net's layer DIVE when the surface
//! it dove under was open all along.
//!
//! The maze buys a layer change for a fixed multiple of grid steps, so where
//! the other face looks even slightly cheaper it dives, runs a millimetre, and
//! climbs back. `route_cleanup.dropRedundantViaPairs` (E10) already deletes the
//! pattern when the two via sites can be rejoined by a plain octilinear ELBOW —
//! two segments, one corner. That is the whole test, and it is why the dives
//! that matter survive it: the corridor a hand router would have used is a
//! narrow SLOT between two pads, and an elbow through the slot only exists if
//! the slot happens to lie on one of the two corners the elbow can take.
//!
//! Measured on board-a's `loop_amp/LF_OUT`: the dive passes under a SOIC-8's
//! right pad column, whose 1.27 mm row pitch leaves 0.62 mm of copper-free
//! slot between adjacent pads. At the net's 0.2532 mm width and 0.127 mm
//! clearance the trace needs 0.5072 mm of that, so the legal band for the
//! track's CENTERLINE is ~0.11 mm tall — and the whole-board routing lattice
//! (pitch = width + clearance = 0.3802 mm) has no row inside it. The maze
//! cannot represent the path, so it correctly picks the dive; the elbow cannot
//! bend to it either. What can is a THREE-segment path: a 45° leg off each via
//! site onto a corridor line, joined by an axis-parallel run along it — with
//! the corridor swept off-lattice until one clears.
//!
//! This module is that search plus the topology that makes it safe to apply.
//! It is deliberately self-contained over plain data (`Scan` takes track/via
//! slices, `channelPoints` / `candidateCoord` / `policyAdmits` are pure), so
//! the geometry is unit-testable without a routing context and the `@import`
//! graph stays acyclic — `route_cleanup` drives this, never the reverse.

const std = @import("std");
const router = @import("router.zig");
const via_hop_scan = @import("via_hop_scan.zig");
const net_rewrite_pass = @import("net_rewrite_pass.zig");

/// This pass's own name for the shared RF-discipline guard (see
/// `net_rewrite_pass.netIsRfDisciplined`): an RF net keeps its dives.
const netIsRfDisciplined = net_rewrite_pass.netIsRfDisciplined;
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

const Track = router.Track;
const Via = router.Via;
const Board = router.CleanupBoard;

/// "This track end sits on that via" tolerance — the scan's own, so the search
/// and the detector answer "same point" identically.
const snap_mm: f64 = via_hop_scan.snap_mm;
/// Do two points coincide within that tolerance? Also the scan's, for the same
/// reason.
const ptEq = via_hop_scan.ptEq;
/// Elisions attempted per net. Each success deletes two vias.
const max_dives_per_net: usize = 32;
/// Below this the two via sites coincide and there is nothing to redraw.
const min_span_mm: f64 = 1e-3;
/// Widest agreement (a cosine) between a replacement leg and the copper already
/// leaving that via before the leg counts as doubling back over it — cos 45°,
/// so a leg must turn at least one octilinear step away from the existing chain.
const back_cos_max: f64 = 0.7071;
/// How far either side of the dive's own midline the corridor sweep looks (mm).
/// The dive is a LOCAL detour by construction, so the corridor that replaces it
/// is local too; this also bounds the extra copper an elision may cost.
const channel_reach_mm: f64 = 1.5;
/// Corridor sweep step (mm) — a mil, an order finer than the whole-board
/// lattice, because the corridors worth finding are the ones the lattice cannot
/// express (the measured band above is ~0.11 mm tall).
const channel_step_mm: f64 = 0.0254;
/// Union-find touch slack for the "does anything else hang off this via" test,
/// kept in lock-step with `fab_readiness.touch_slack_mm` so this module's idea
/// of connected copper is the connectivity oracle's.
const touch_slack_mm: f64 = 0.02;
/// Net sentinel tagging copper for in-place removal.
const removed_net: i32 = std.math.minInt(i32);

/// Which way a corridor runs: `horizontal` = a constant-y line (swept in y),
/// `vertical` = a constant-x line (swept in x).
pub const Axis = enum { horizontal, vertical };

/// One dive found in a net's copper — `via_hop_scan.Hop`, the same shape the
/// elbow pass detects. Two pure transition vias joined by a single-layer run
/// whose far ends share one other layer, plus that run's length, which bounds
/// what a replacement corridor may cost.
const Dive = via_hop_scan.Hop;

/// Where a replacement must start and end, what it must not run back over, and
/// how much copper it is allowed to replace (see `Dive`).
pub const Span = struct {
    a: [2]f64,
    b: [2]f64,
    away: [2][2]f64,
    layer: u8,
    run_mm: f64,
};

/// A replacement path's two interior corners (`a` and `b` are the caller's).
/// Degenerate corners are legal and are dropped when the copper is emitted.
pub const Path = struct { p: [2]f64, q: [2]f64 };

// ── Pure geometry ────────────────────────────────────────────────────────────

/// The three-segment octilinear path from `a` to `b` that runs along the `axis`
/// line at `coord`: a 45° leg off each end onto that line, joined by a run
/// along it. Returns the two corner points.
///
/// Null when the ends share their along-axis coordinate (there is no run to
/// make) or when the two 45° legs would OVERSHOOT each other — the line is too
/// far off to reach and come back within the span, and the "path" would double
/// back on itself rather than thread anything.
pub fn channelPoints(a: [2]f64, b: [2]f64, axis: Axis, coord: f64) ?Path {
    const along: usize = if (axis == .horizontal) 0 else 1;
    const across: usize = 1 - along;
    const dir: f64 = if (b[along] > a[along]) 1 else if (b[along] < a[along]) -1 else return null;
    var p: [2]f64 = undefined;
    var q: [2]f64 = undefined;
    p[across] = coord;
    q[across] = coord;
    p[along] = a[along] + dir * @abs(coord - a[across]);
    q[along] = b[along] - dir * @abs(coord - b[across]);
    if (dir * (q[along] - p[along]) < -snap_mm) return null;
    return .{ .p = p, .q = q };
}

/// The `k`-th corridor coordinate to try for `axis`, or null once the sweep has
/// reached `channel_reach_mm`.
///
/// Order is deliberate and deterministic: the two ends' OWN across-axis
/// coordinates first (those two candidates reproduce exactly the pair of plain
/// octilinear elbows, so the cheapest answer is still tried first), then the
/// dive's own midline, then outward from it in `channel_step_mm` steps,
/// alternating sides. So the first corridor that clears is always the one that
/// deviates least from the copper being replaced.
pub fn candidateCoord(a: [2]f64, b: [2]f64, axis: Axis, k: usize) ?f64 {
    const across: usize = if (axis == .horizontal) 1 else 0;
    if (k == 0) return a[across];
    if (k == 1) return b[across];
    const mid = (a[across] + b[across]) / 2;
    if (k == 2) return mid;
    const j = k - 3;
    const step: f64 = @floatFromInt(j / 2 + 1);
    const off = step * channel_step_mm;
    if (off > channel_reach_mm) return null;
    return if (j % 2 == 0) mid + off else mid - off;
}

/// How many candidates one axis offers (both axes are swept per `k`, so the
/// two stay interleaved in deviation order).
fn candidateCount() usize {
    return 3 + 2 * numeric.toCount(@floor(channel_reach_mm / channel_step_mm));
}

/// The unit direction from `p` to `q`, or null when they coincide.
fn unitTo(p: [2]f64, q: [2]f64) ?[2]f64 {
    const len = std.math.hypot(q[0] - p[0], q[1] - p[1]);
    if (len <= snap_mm) return null;
    return .{ (q[0] - p[0]) / len, (q[1] - p[1]) / len };
}

/// Would a replacement leaving `from` toward `toward` head the SAME way as the
/// copper already leaving it (`away`)? Then the replacement runs back over that
/// chain instead of replacing the dive — a doubling-back spur no later pass can
/// simplify, so the dive is kept instead.
fn doublesBack(from: [2]f64, toward: [2]f64, away: [2]f64) bool {
    const u = unitTo(from, toward) orelse return false;
    const v = unitTo(from, away) orelse return false;
    return u[0] * v[0] + u[1] * v[1] > back_cos_max;
}

/// Total length of the three-segment path a→p→q→b.
fn pathLen(a: [2]f64, path: Path, b: [2]f64) f64 {
    return std.math.hypot(path.p[0] - a[0], path.p[1] - a[1]) +
        std.math.hypot(path.q[0] - path.p[0], path.q[1] - path.p[1]) +
        std.math.hypot(b[0] - path.q[0], b[1] - path.q[1]);
}

/// May a dive of a net with this route policy be elided onto `layer`?
///
/// A wave that lists BOTH outer faces (board-a's every wave does — "no routed
/// traces on either inner layer") is not asking for any particular dive; it is
/// excluding the planes. So an allowed/preferred mask admits the elision as
/// long as the surviving layer is in it — the result still obeys the mask. What
/// does forbid it is a policy that names GEOMETRY: waypoints (two consecutive
/// points at one coordinate on different layers ARE a requested via), reference
/// branches, and verbatim reference replay all mean the hop is authored.
pub fn policyAdmits(policy: route_policy.NetPolicy, layer: u8) bool {
    if (policy.waypoints.len > 0 or policy.branches.len > 0) return false;
    if (policy.replay_reference_copper) return false;
    // A PREFERENCE for the other face is the author asking for that dive: the
    // wave says "get this rail down onto B.Cu", and deleting the hop that takes
    // it there answers a different question than the one the design asked.
    if (policy.preferred_layers != 0 and !layerIn(policy.preferred_layers, layer)) return false;
    if (policy.allowed_layers == 0) return true;
    return layerIn(policy.allowed_layers, layer);
}

/// Is signal layer `layer` set in a route-policy layer bitset?
fn layerIn(mask: u64, layer: u8) bool {
    if (layer >= @bitSizeOf(u64)) return false;
    return (mask & (@as(u64, 1) << @intCast(layer))) != 0;
}

// ── Search ───────────────────────────────────────────────────────────────────

/// The corridor path replacing `span`, or null when no corridor within reach
/// clears. Every leg is probed with the router's own clearance oracle (so
/// same-net copper is free and every foreign feature, zone and the outline are
/// judged exactly as the DRC judges them), neither end may double back over the
/// copper already leaving it, and the whole path must not cost more than the
/// copper it removes plus the sweep's own reach.
pub fn channelPath(probe: router.TautProbe, span: Span) ?Path {
    const budget = span.run_mm + 2 * channel_reach_mm;
    const n = candidateCount();
    for (0..n) |k| {
        for ([_]Axis{ .horizontal, .vertical }) |axis| {
            const coord = candidateCoord(span.a, span.b, axis, k) orelse continue;
            const path = channelPoints(span.a, span.b, axis, coord) orelse continue;
            if (pathLen(span.a, path, span.b) > budget) continue;
            if (pathClears(probe, span, path)) return path;
        }
    }
    return null;
}

/// Do all three legs of `path` clear, without either end doubling back?
fn pathClears(probe: router.TautProbe, span: Span, path: Path) bool {
    const pts = [4][2]f64{ span.a, path.p, path.q, span.b };
    // The first/last NON-degenerate step away from each end is what may not
    // double back — a degenerate corner just is not a heading.
    const first = if (!ptEq(pts[0], pts[1])) pts[1] else if (!ptEq(pts[0], pts[2])) pts[2] else pts[3];
    const last = if (!ptEq(pts[3], pts[2])) pts[2] else if (!ptEq(pts[3], pts[1])) pts[1] else pts[0];
    if (doublesBack(span.a, first, span.away[0])) return false;
    if (doublesBack(span.b, last, span.away[1])) return false;
    for (0..3) |i| {
        if (ptEq(pts[i], pts[i + 1])) continue;
        if (!probe.clear(span.layer, pts[i], pts[i + 1])) return false;
    }
    return true;
}

// ── Board driver ─────────────────────────────────────────────────────────────

/// May this pass rewrite `net`'s copper? With no selection every net is fair
/// game (the whole-board route). In a SCOPED route an unselected net's copper
/// is the caller's retained board and must come back verbatim.
/// Was a feature joined to a via's LAND but left out of reach of the thinner
/// trace that replaces it?
///
/// The island model joins two features when their copper comes within
/// `touch_slack_mm`, so a via's 0.4 mm land reaches further than the ~0.25 mm
/// trace drawn through the same point. `d` is the distance from the via's
/// CENTRE to the other feature and `other_reach` that feature's own half-width
/// (0 for a pad, whose distance is already measured to its outline). Copper
/// inside the land but outside the trace's reach is exactly what a naive
/// deletion would strand — everything nearer stays joined to the replacement,
/// which is drawn through that same centre.
pub fn strandedAt(d: f64, other_reach: f64, via_r: f64, trace_w: f64) bool {
    return d <= via_r + touch_slack_mm + other_reach and
        d > trace_w / 2 + touch_slack_mm + other_reach;
}

/// Would deleting via `vi` strand copper of this net?
///
/// The walk already proves the run branches nowhere and both vias are pure
/// transitions, which settles every connection made by a shared ENDPOINT. This
/// settles the ones made by mere PROXIMITY, which the island model counts just
/// the same: a pad the via sat in, a neighbouring stub that clipped its land, a
/// second barrel overlapping it. Each is measured with `strandedAt`, so the
/// test asks the question that matters — "does this copper survive the swap" —
/// rather than the blunter "is anything near it", which refuses the net's OWN
/// outer chain (on board-a's `loop_amp/LF_OUT` the F.Cu leg's next segment
/// passes 0.171 mm from the via it terminates at, well inside the land and
/// well inside the replacement's reach too).
fn viaStrands(board: Board, net: i32, vi: usize, dive: Dive) bool {
    const v = board.vias.items[vi];
    const w = board.ctx.params.track_width;
    const r = v.dia / 2;
    for (board.ctx.obs) |o| {
        if (o.net != net) continue;
        const d = pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, v.x, v.y, std.math.inf(f64));
        if (strandedAt(d, 0, r, w)) return true;
    }
    for (board.vias.items, 0..) |u, ui| {
        if (ui == dive.v1 or ui == dive.v2 or u.net != net) continue;
        if (strandedAt(std.math.hypot(u.x - v.x, u.y - v.y), u.dia / 2, r, w)) return true;
    }
    for (board.tracks.items, 0..) |t, ti| {
        if (t.net != net) continue;
        if (ptEq(.{ t.x1, t.y1 }, .{ v.x, v.y }) or ptEq(.{ t.x2, t.y2 }, .{ v.x, v.y })) continue;
        for (dive.run) |ri| {
            if (ri == ti) break;
        } else if (strandedAt(pad_shape.segPointDist(t.x1, t.y1, t.x2, t.y2, v.x, v.y), t.width / 2, r, w)) return true;
    }
    return false;
}

/// May this via be deleted, given the replacement will be drawn on `outer`?
/// Not when it taps the net's OWN pour on any layer BUT `outer` — the island
/// model does not carry pours, so that connection is invisible here and
/// deleting the via would silently strand copper. A tap on `outer` itself is
/// safe: the replacement passes through exactly where the via was.
fn viaRemovable(board: Board, net: i32, vi: usize, dive: Dive) bool {
    const v = board.vias.items[vi];
    if (router.netPourCovers(board.ctx, net, v.x, v.y, dive.outer)) return false;
    return !viaStrands(board, net, vi, dive);
}

/// Drop every track of `net` from `list`, packing survivors down in place.
fn removeNetTracks(list: *std.ArrayList(Track), net: i32) void {
    var w: usize = 0;
    for (list.items) |item| {
        if (item.net != net) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

/// Drop every via of `net` from `list`, packing survivors down in place.
fn removeNetVias(list: *std.ArrayList(Via), net: i32) void {
    var w: usize = 0;
    for (list.items) |item| {
        if (item.net != net) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

/// Swap a dive's two vias and its detour run for the corridor path on `outer`.
fn apply(board: Board, net: i32, dive: Dive, a: [2]f64, path: Path, b: [2]f64) std.mem.Allocator.Error!void {
    for (dive.run) |ti| board.tracks.items[ti].net = removed_net;
    board.vias.items[dive.v1].net = removed_net;
    board.vias.items[dive.v2].net = removed_net;
    const w = board.ctx.params.track_width;
    const pts = [4][2]f64{ a, path.p, path.q, b };
    for (0..3) |i| {
        if (ptEq(pts[i], pts[i + 1])) continue;
        try board.tracks.append(board.ctx.arena, .{
            .x1 = pts[i][0],
            .y1 = pts[i][1],
            .x2 = pts[i + 1][0],
            .y2 = pts[i + 1][1],
            .layer = dive.outer,
            .width = w,
            .net = net,
        });
    }
    removeNetTracks(board.tracks, removed_net);
    removeNetVias(board.vias, removed_net);
    // Both packed survivors down, so every entry in the generation-stamped
    // copper index now names DIFFERENT copper (a survivor slid into a removed
    // one's slot: in range, wrong track — see `router.copperCompacted`). This
    // pass is a loop and `elideOne`'s `channelPath` probes read that index, so
    // the index is restamped from the new lists before the next dive is judged,
    // exactly as `route_cleanup.applyHop` does after the same pack-down.
    router.rebuildCopperIndex(board.ctx, board.tracks.items, board.vias.items);
}

/// Elide ONE dive of `net`, or report that none is left.
fn elideOne(board: Board, net: i32, policy: route_policy.NetPolicy) std.mem.Allocator.Error!bool {
    const ctx = board.ctx;
    const scan = via_hop_scan.Scan{ .arena = ctx.arena, .tracks = board.tracks.items, .vias = board.vias.items, .net = net };
    const probe = router.TautProbe{ .run = .{ .ctx = ctx, .net = net, .tracks = board.tracks, .vias = board.vias } };
    for (board.vias.items, 0..) |v, vi| {
        if (v.net != net) continue;
        const dive = (try scan.find(vi)) orelse continue;
        if (!policyAdmits(policy, dive.outer)) continue;
        if (!viaRemovable(board, net, dive.v1, dive) or !viaRemovable(board, net, dive.v2, dive)) continue;
        const far = board.vias.items[dive.v2];
        const a = [2]f64{ v.x, v.y };
        const b = [2]f64{ far.x, far.y };
        if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < min_span_mm) continue;
        const path = channelPath(probe, .{
            .a = a,
            .b = b,
            .away = dive.away,
            .layer = dive.outer,
            .run_mm = dive.run_mm,
        }) orelse continue;
        try apply(board, net, dive, a, path, b);
        return true;
    }
    return false;
}

/// The route policy declared for `net`, or the empty one for a net past the
/// table (an unauthored net constrains nothing).
fn netPolicy(board: Board, net: i32) route_policy.NetPolicy {
    const i: usize = @intCast(net);
    return if (i < board.ctx.net_policy.len) board.ctx.net_policy[i] else .{};
}

/// Elide one dive of `net` under its own route policy — the driver's per-net step.
fn elideOneNet(board: Board, net: i32) std.mem.Allocator.Error!bool {
    return elideOne(board, net, netPolicy(board, net));
}

/// Elide every needless dive the board still carries.
///
/// Runs after `route_cleanup.dropRedundantViaPairs`, so the dives an ordinary
/// elbow could take are already gone and what reaches here is exactly the
/// residue: dives whose replacement needs a corridor the elbow cannot bend to,
/// plus (on a board whose waves name their layers, which is every net on
/// board-a) the ones E10's coarser "layers are authored" guard skipped
/// wholesale — which is why this pass leaves `skip_layer_authored` off and
/// applies its own finer `policyAdmits` test per dive instead.
pub fn passBoard(board: Board) std.mem.Allocator.Error!void {
    const opts = net_rewrite_pass.Options{ .max_steps = max_dives_per_net, .skip_rf_disciplined = true };
    return net_rewrite_pass.run(board, opts, board, elideOneNet);
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

// spec: placement/router - a needless layer dive is replaced by a three-segment corridor path on the layer both its ends already use
test "channelPoints threads a corridor line the two-segment elbow cannot reach" {
    // board-a's loop_amp/LF_OUT, measured: the dive's two via sites and the
    // SOIC-8 pad-row slot midline the corridor has to run along.
    const a = [2]f64{ 136.367, 107.934 };
    const b = [2]f64{ 139.003, 108.373 };
    const slot_y: f64 = 108.565;
    const path = channelPoints(a, b, .horizontal, slot_y).?;
    // Both corners sit ON the corridor line, and the middle run spans the pad
    // column (x 137.124 … 138.652) from outside it on both sides.
    try testing.expectApproxEqAbs(slot_y, path.p[1], 1e-9);
    try testing.expectApproxEqAbs(slot_y, path.q[1], 1e-9);
    try testing.expect(path.p[0] < 137.124);
    try testing.expect(path.q[0] > 138.652);
    // Every leg is octilinear: the two 45° legs and the axis-parallel run.
    const octilinear = @import("octilinear.zig");
    try testing.expect(octilinear.isOctilinear(a, path.p));
    try testing.expect(octilinear.isOctilinear(path.p, path.q));
    try testing.expect(octilinear.isOctilinear(path.q, b));
    // The corridor at either end's own coordinate degenerates to the plain
    // two-segment elbow (one corner lands on the endpoint).
    const elbow = channelPoints(a, b, .horizontal, a[1]).?;
    try testing.expect(std.math.hypot(elbow.p[0] - a[0], elbow.p[1] - a[1]) <= snap_mm);
}

// spec: placement/router - a corridor whose legs would overshoot the dive's own span is refused rather than doubled back on
test "channelPoints refuses an unreachable corridor and a zero-length span" {
    const a = [2]f64{ 0, 0 };
    const b = [2]f64{ 2, 0 };
    // A corridor 3 mm off needs 3 mm of run on each 45° leg — 6 mm of span for
    // a 2 mm one, so the legs cross and there is no path.
    try testing.expect(channelPoints(a, b, .horizontal, 3.0) == null);
    // One exactly reachable (the legs meet at a point) is still a path.
    const tight = channelPoints(a, b, .horizontal, 1.0).?;
    try testing.expectApproxEqAbs(@as(f64, 1.0), tight.p[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), tight.q[0], 1e-9);
    // Two ends on one vertical line offer no horizontal run at all.
    try testing.expect(channelPoints(a, .{ 0, 2 }, .horizontal, 1.0) == null);
}

// spec: placement/router - the corridor sweep tries the plain elbows first and then deviates from the dive's own midline outward
test "candidateCoord orders the corridor sweep by deviation and stops at the reach" {
    const a = [2]f64{ 0, 10 };
    const b = [2]f64{ 5, 11 };
    try testing.expectEqual(@as(?f64, 10), candidateCoord(a, b, .horizontal, 0));
    try testing.expectEqual(@as(?f64, 11), candidateCoord(a, b, .horizontal, 1));
    try testing.expectApproxEqAbs(@as(f64, 10.5), candidateCoord(a, b, .horizontal, 2).?, 1e-12);
    // Then outward from the midline, alternating sides, one step at a time.
    try testing.expectApproxEqAbs(10.5 + channel_step_mm, candidateCoord(a, b, .horizontal, 3).?, 1e-12);
    try testing.expectApproxEqAbs(10.5 - channel_step_mm, candidateCoord(a, b, .horizontal, 4).?, 1e-12);
    try testing.expectApproxEqAbs(10.5 + 2 * channel_step_mm, candidateCoord(a, b, .horizontal, 5).?, 1e-12);
    // The vertical sweep reads the other coordinate.
    try testing.expectEqual(@as(?f64, 0), candidateCoord(a, b, .vertical, 0));
    // …and the sweep stops once it is `channel_reach_mm` off the midline.
    try testing.expect(candidateCoord(a, b, .horizontal, candidateCount()) == null);
    try testing.expect(candidateCoord(a, b, .horizontal, candidateCount() - 1) != null);
}

// spec: placement/router - a dive is elided only when nothing the removed via's land alone joined would be stranded by the thinner trace that replaces it
test "the strand test spares the net's own chain and still catches land-only copper" {
    const via_r: f64 = 0.2; // a 0.4 mm land
    const w: f64 = 0.2532; // board-a's analog trace
    // board-a's loop_amp/LF_OUT: the F.Cu leg's NEXT segment passes 0.171 mm
    // from the via its neighbour terminates at. Inside the land, and inside the
    // replacement's reach too — it survives the swap, so it is not a stranding.
    try testing.expect(!strandedAt(0.1711, w / 2, via_r, w));
    // Copper only the LAND reached: 0.34 mm out, past the trace's 0.1466 mm
    // reach plus its own half-width. Deleting the via would cut it loose.
    try testing.expect(strandedAt(0.34, w / 2, via_r, w));
    // Far copper was never joined through this via at all.
    try testing.expect(!strandedAt(1.0, w / 2, via_r, w));
    // A pad measures to its outline, so it brings no reach of its own: one
    // sitting in the land at 0.2 mm is stranded, one the via sat inside is not,
    // and one 0.3 mm out was never joined through this via to begin with.
    try testing.expect(strandedAt(0.2, 0, via_r, w));
    try testing.expect(!strandedAt(0.3, 0, via_r, w));
    try testing.expect(!strandedAt(0, 0, via_r, w));
}

// spec: placement/router - a net that declares RF bend discipline keeps its dives, because its corners are authored arcs
test "an RF-disciplined net is not offered to the dive elision" {
    var placement = std.mem.zeroes(optimizer.Placement);
    const rules = [_]optimizer.NetRule{
        .{ .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    placement.rules.net = &rules;
    try testing.expect(netIsRfDisciplined(placement, 0));
    try testing.expect(!netIsRfDisciplined(placement, 1));
    // A net past the rule table declares nothing, so it is fair game.
    try testing.expect(!netIsRfDisciplined(placement, 7));
}

// spec: placement/router - a dive is elided only when the net's route policy admits the surviving layer and asks for no geometry of its own
test "policyAdmits keeps an authored transition and allows a plain outer-face mask" {
    const outer_faces: u64 = 0b11; // "F.Cu and B.Cu" — board-a's every wave
    try testing.expect(policyAdmits(.{ .allowed_layers = outer_faces }, 0));
    try testing.expect(policyAdmits(.{ .allowed_layers = outer_faces }, 1));
    // A mask that excludes the surviving layer refuses it.
    try testing.expect(!policyAdmits(.{ .allowed_layers = 0b01 }, 1));
    // No mask at all is unrestricted.
    try testing.expect(policyAdmits(.{}, 1));
    // A PREFERENCE for the other face is a request for the dive, so the hop
    // that reaches it stays; a preference the surviving layer satisfies does not.
    try testing.expect(!policyAdmits(.{ .preferred_layers = 0b10 }, 0));
    try testing.expect(policyAdmits(.{ .preferred_layers = 0b10 }, 1));
    // A policy naming geometry means its hops on purpose.
    const wp = [_]route_policy.Waypoint{.{ .x = 0, .y = 0, .layer = 0 }};
    try testing.expect(!policyAdmits(.{ .allowed_layers = outer_faces, .waypoints = &wp }, 0));
    try testing.expect(!policyAdmits(.{ .replay_reference_copper = true }, 0));
}
