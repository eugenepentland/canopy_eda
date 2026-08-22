//! Single-point pad entry — how much copper a route leaves lying ON the pad it
//! terminates at.
//!
//! Every route terminal is anchored at its pad's centre (or at the clearest
//! interior site `pad_exit.interior` found there), and the escape leaves along
//! the pad's outward axis. On a pad that is longer than it is wide — a 0.5 mm
//! pitch QFN land, a 0402's rectangle — that draws copper down the pad's whole
//! half-length before it reaches open board. Electrically it is nothing: a
//! track anywhere on the land is the same node. Visually it is a LAP JOINT —
//! the trace reads as running *alongside* the pad rather than into it, and it
//! says nothing about which point of the pad the route actually serves, which
//! is the one thing a reader wants from a terminal. Measured on
//! straps-synth-lmx2595's rough route (2026-08-10): 98 of 127 pad entries
//! carried more than 0.12 mm of copper inside their own pad, the median 0.25 mm
//! and the worst 0.49 mm — the full half-length of a QFN land.
//!
//! This pass trims each entry back to ONE crossing of the pad outline plus
//! `stub_mm` of copper inside it. It only ever REMOVES copper, and only from
//! the pad end of a chain, which is what makes it safe to run at the very end
//! of the finish:
//!
//!   * it cannot create a clearance violation — shortening a segment can only
//!     remove approaches, so every surviving millimetre was already probed;
//!   * it cannot open a net — the surviving end still lands inside the pad's
//!     real copper (checked against the pad's outline, not just its box), which
//!     is exactly what the connectivity oracle's pad↔track union and KiCad's
//!     own connectivity read as "this track is on that pad";
//!   * it cannot strand a via — a chain END is a terminal by construction, and
//!     a via OFF the land inside the span a trim would remove refuses that end
//!     outright (one standing ON the land keeps its join through the land, which
//!     is what lets a plane-via terminal be trimmed like any other).
//!
//! One shape it removes outright rather than trims: a chain every vertex of
//! which lies on ONE pad's land. That copper joins nothing the solid land does
//! not already join — both ends, and anything touching it, are on the same pad
//! — so it is a failed escape attempt drawn along the pad, which is the very
//! picture the trim exists to stop.
//!
//! Deliberately out of scope: THROUGH-HOLE pads (the barrel is the connection
//! and the annulus is not a lap), `(max-freq …)` escape-ruled nets (their
//! straight reserve is measured from the pad anchor, and shortening it is the
//! smoother's business, not this pass's), and diff-pair legs (trimming one leg
//! alone would decouple the pair).

const std = @import("std");
const bypass_intent = @import("bypass_intent.zig");
const router = @import("router.zig");
const bend_smooth = @import("bend_smooth.zig");
const optimizer = @import("optimizer.zig");
const pad_grid = @import("pad_grid.zig");
const pad_shape = @import("pad_shape.zig");
const route_cleanup = @import("route_cleanup.zig");

/// Copper (mm) a route may keep inside the pad it terminates on.
///
/// It has to be long enough that the join is unambiguous to everything
/// downstream — the connectivity oracle unites a pad with a track whose copper
/// reaches its land, KiCad wants the track END on the pad, and a fab's
/// photoplotter needs a real overlap, not a tangency — and short enough that
/// the entry reads as one point rather than a run. 0.12 mm is a hair under the
/// 0.127 mm default track width: the copper inside the pad is then shorter than
/// it is wide, which is the geometric definition of "a stub, not a run", while
/// still overlapping the land by a full trace width's worth of area.
pub const stub_mm: f64 = 0.12;

/// Float slack for "is this point on the polyline / inside the box" tests. Well
/// below fab resolution, so it only absorbs the drift of coordinates that have
/// been through a world→grid→world round trip.
const eps: f64 = 1e-9;

/// Tolerance for the surviving end being inside the pad's REAL copper. A pad's
/// outline test returns 0 inside, so anything above float noise means the
/// candidate landed in a rounded pad's box corner, outside the land — the trim
/// is refused there rather than left to hope.
const inside_tol_mm: f64 = 1e-6;

/// One pad a route may terminate on, as this pass needs it: the land's
/// axis-aligned bounds plus the outline that decides what is really copper.
const Pad = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64 = &.{},
};

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

/// Is `p` inside the pad's bounding box?
fn inBox(pad: Pad, p: [2]f64) bool {
    return p[0] >= pad.x0 - eps and p[0] <= pad.x1 + eps and
        p[1] >= pad.y0 - eps and p[1] <= pad.y1 + eps;
}

/// Is `p` on the pad's real copper (0 distance to its outline)?
fn onLand(pad: Pad, p: [2]f64) bool {
    return pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, p[0], p[1], 1) <= inside_tol_mm;
}

/// The fraction of `a`→`b` at which the segment leaves the pad's box, given `a`
/// inside and `b` outside. The box is convex, so the crossing is unique and the
/// nearest exiting half-plane fixes it exactly.
fn exitFraction(pad: Pad, a: [2]f64, b: [2]f64) f64 {
    var t: f64 = 1;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    if (dx > eps) t = @min(t, (pad.x1 - a[0]) / dx);
    if (dx < -eps) t = @min(t, (pad.x0 - a[0]) / dx);
    if (dy > eps) t = @min(t, (pad.y1 - a[1]) / dy);
    if (dy < -eps) t = @min(t, (pad.y0 - a[1]) / dy);
    return std.math.clamp(t, 0, 1);
}

/// Where the head of a polyline leaves its pad: the index of the segment that
/// crosses out, and the arclength from `pts[0]` to that crossing.
const Exit = struct { seg: usize, run: f64 };

fn headExit(pts: []const [2]f64, pad: Pad) ?Exit {
    var run: f64 = 0;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const a = pts[i];
        const b = pts[i + 1];
        if (inBox(pad, b)) {
            run += dist(a, b);
            continue;
        }
        return .{ .seg = i, .run = run + dist(a, b) * exitFraction(pad, a, b) };
    }
    return null; // the whole chain stays on the pad — nothing to trim into
}

/// Trim the HEAD of `pts` so at most `stub` mm of it lies inside `pad`, or null
/// when it already does (or when the trim would leave the copper off the land).
///
/// `pts[0]` must sit inside the pad. The result keeps every vertex from the
/// first one outside the trimmed prefix onward, with a new first point placed
/// `stub` back along the polyline from where it crosses the pad outline — so
/// the entry is one crossing plus one stub, on the heading the route already
/// arrived at.
fn trimHead(
    arena: std.mem.Allocator,
    pts: []const [2]f64,
    pad: Pad,
    stub: f64,
    vias: []const [2]f64,
) std.mem.Allocator.Error!?[][2]f64 {
    if (pts.len < 2 or !inBox(pad, pts[0])) return null;
    const exit = headExit(pts, pad) orelse return null;
    if (exit.run <= stub + eps) return null;
    const target = exit.run - stub;
    // Locate the segment holding the new terminal, measuring from `pts[0]`.
    var acc: f64 = 0;
    var k: usize = 0;
    while (k < exit.seg) : (k += 1) {
        const d = dist(pts[k], pts[k + 1]);
        if (acc + d >= target - eps) break;
        acc += d;
    }
    const a = pts[k];
    const b = pts[k + 1];
    const d = dist(a, b);
    const f = if (d <= eps) 0 else std.math.clamp((target - acc) / d, 0, 1);
    const at = [2]f64{ a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]) };
    if (!onLand(pad, at)) return null;
    if (pinnedByVia(vias, pts[0 .. k + 1], pad)) return null;
    // The tail is whatever the trim did not touch. A terminal that landed on
    // its own next vertex leaves that vertex to be the end instead.
    const tail = pts[k + 1 ..];
    if (dist(at, tail[0]) <= eps) {
        if (tail.len < 2) return null;
        return try arena.dupe([2]f64, tail);
    }
    const out = try arena.alloc([2]f64, tail.len + 1);
    out[0] = at;
    @memcpy(out[1..], tail);
    return out;
}

/// Trim BOTH ends of one chain against the pads its terminals sit on. Returns
/// the rewritten polyline (EMPTY when the whole chain is dead copper lying on
/// one land), or null when neither end had a lap to trim.
fn trimChain(
    arena: std.mem.Allocator,
    pts: []const [2]f64,
    pads: []const Pad,
    stub: f64,
    vias: []const [2]f64,
) std.mem.Allocator.Error!?[]const [2]f64 {
    if (padAt(pads, pts[0])) |pad| {
        if (whollyOnLand(pts, pad)) return &.{}; // dead copper drawn along the land
    }
    var work = pts;
    var changed = false;
    for (0..2) |end| {
        if (end == 1) work = try reversed(arena, work);
        if (padAt(pads, work[0])) |pad| {
            if (try trimHead(arena, work, pad, stub, vias)) |cut| {
                work = cut;
                changed = true;
            }
        }
        if (end == 1) work = try reversed(arena, work);
    }
    return if (changed) try arena.dupe([2]f64, work) else null;
}

fn reversed(arena: std.mem.Allocator, pts: []const [2]f64) std.mem.Allocator.Error![][2]f64 {
    const out = try arena.alloc([2]f64, pts.len);
    for (pts, 0..) |p, i| out[pts.len - 1 - i] = p;
    return out;
}

/// The pad `p` sits on, or null when the point is not on one of them.
fn padAt(pads: []const Pad, p: [2]f64) ?Pad {
    for (pads) |pad| {
        if (inBox(pad, p) and onLand(pad, p)) return pad;
    }
    return null;
}

// ── Board seam ─────────────────────────────────────────────────────────────

/// Trim every ordinary net's pad entries on a finished board.
///
/// Runs at the very end of the finish, after the last straighten pass, so the
/// copper it trims is the copper that ships: an earlier seam would just have
/// its work rewritten by the collinear collapse or the closing gloss. Nets not
/// in the route's scope are left byte-identical (a scoped route echoes the
/// caller's retained copper), as are escape-ruled and diff-pair nets.
pub fn passBoard(board: router.CleanupBoard) std.mem.Allocator.Error!void {
    const ctx = board.ctx;
    const placement = board.placement;
    const tracks = board.tracks;
    const vias = board.vias;
    var touched = false;
    for (0..placement.nets.len) |net_i| {
        if (!netSelected(ctx.selected_nets, net_i)) continue;
        if (skipNet(placement, net_i)) continue;
        const ni: i32 = @intCast(net_i);
        var mine: std.ArrayList(router.Track) = .empty;
        for (tracks.items) |t| if (t.net == ni) try mine.append(ctx.arena, t);
        if (mine.items.len == 0) continue;
        const pads = try netPads(ctx.arena, ctx.obs, ni);
        if (pads.len == 0) continue;
        var pins: std.ArrayList([2]f64) = .empty;
        for (vias.items) |v| if (v.net == ni) try pins.append(ctx.arena, .{ v.x, v.y });
        const trimmed = (try trimNet(ctx.arena, .{
            .net = ni,
            .tracks = mine.items,
            .pads = pads,
            .vias = pins.items,
        })) orelse continue;
        route_cleanup.removeNetTracks(tracks, ni);
        try tracks.appendSlice(ctx.arena, trimmed);
        touched = true;
    }
    // The removals packed survivors down, so every copper-index slot aliases.
    if (touched) router.copperCompacted(ctx);
}

/// One net's trim job: which net, its copper, the SMD lands it may terminate
/// on, and its via centres (copper may never be trimmed off one).
const NetTrim = struct {
    net: i32,
    tracks: []const router.Track,
    pads: []const Pad,
    vias: []const [2]f64,
};

/// One net's copper with its pad entries trimmed, or null when nothing moved.
fn trimNet(arena: std.mem.Allocator, job: NetTrim) std.mem.Allocator.Error!?[]const router.Track {
    var out: std.ArrayList(router.Track) = .empty;
    var changed = false;
    var layer: u8 = 0;
    const top = maxLayer(job.tracks, job.net);
    while (true) : (layer += 1) {
        var segs: std.ArrayList(router.Track) = .empty;
        for (job.tracks) |t| {
            if (t.net != job.net or t.layer != layer) continue;
            if (segLen(t) < eps) continue;
            try segs.append(arena, t);
        }
        if (segs.items.len > 0) {
            const chains = try bend_smooth.extractChains(arena, segs.items);
            for (chains) |chain| {
                const width = if (chain.widths.len > 0) chain.widths[0] else segs.items[0].width;
                const pts = try trimChain(arena, chain.pts, job.pads, stub_mm, job.vias);
                if (pts != null) changed = true;
                try emitPolyline(arena, &out, pts orelse chain.pts, layer, width, job.net);
            }
        }
        if (layer >= top) break;
    }
    return if (changed) try out.toOwnedSlice(arena) else null;
}

/// Would the trim strand a via? Consulted over the prefix it is about to
/// REMOVE: dropping copper off a via leaves everything on that via's other
/// layer hanging, while a via at the chain's FAR end is no reason to leave this
/// end's lap in place.
///
/// A via standing on the pad's own land is exempt. The pad is solid copper
/// there, and every graph that decides connectivity unites a pad with a via
/// touching it, so the barrel keeps its join to the net through the land itself
/// once the track is shortened — which is what lets a plane-via terminal (the
/// most numerous kind on a ground net) be trimmed like any other.
fn pinnedByVia(vias: []const [2]f64, pts: []const [2]f64, pad: Pad) bool {
    for (vias) |v| {
        if (onLand(pad, v)) continue;
        for (pts) |p| {
            if (dist(v, p) <= via_snap) return true;
        }
    }
    return false;
}

/// Is every vertex of this chain on one pad's own land? Such copper joins
/// nothing the land does not already join — both of its ends, and anything
/// touching it, sit on the same solid pad — so it is a failed escape stub
/// drawn along the pad rather than a route, and it is dropped outright.
fn whollyOnLand(pts: []const [2]f64, pad: Pad) bool {
    for (pts) |p| {
        if (!onLand(pad, p)) return false;
    }
    return true;
}

/// Via-matching tolerance (mm) — as with `eps`, only float drift on a
/// coordinate that has been through a world→grid→world round trip.
const via_snap: f64 = 0.01;

/// This net's SMD lands, as the trim needs them. Through-hole pads are left
/// out: the barrel is the connection, so copper across the annulus is not a
/// lap joint and trimming it would only shorten a legitimate join.
fn netPads(
    arena: std.mem.Allocator,
    obs: []const pad_grid.PadObs,
    net: i32,
) std.mem.Allocator.Error![]const Pad {
    var out: std.ArrayList(Pad) = .empty;
    for (obs) |o| {
        if (o.net != net or o.thru) continue;
        try out.append(arena, .{ .x0 = o.x0, .y0 = o.y0, .x1 = o.x1, .y1 = o.y1, .poly = o.poly });
    }
    return out.toOwnedSlice(arena);
}

/// Nets this pass never touches: an escape-ruled `(max-freq …)` net (its
/// straight reserve is measured from the pad anchor), an exact-target bypass
/// rail (its surface topology is an authored requirement), and either leg of
/// a diff pair (trimming one leg alone would decouple the pair).
fn skipNet(placement: optimizer.Placement, net_i: usize) bool {
    if (net_i < placement.rules.net.len and placement.rules.net[net_i].rf.escape_mm > 0) return true;
    if (bypass_intent.exactNet(placement, net_i)) return true;
    for (placement.diff_pairs) |dp| {
        if (dp.p == net_i or dp.n == net_i) return true;
    }
    return false;
}

/// Is this net in the route's scope? An empty selection means "every net".
fn netSelected(selected: []const bool, net_i: usize) bool {
    return selected.len == 0 or (net_i < selected.len and selected[net_i]);
}

fn maxLayer(net_tracks: []const router.Track, ni: i32) u8 {
    var m: u8 = 0;
    for (net_tracks) |t| {
        if (t.net == ni and t.layer > m) m = t.layer;
    }
    return m;
}

fn segLen(t: router.Track) f64 {
    return std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
}

fn emitPolyline(
    arena: std.mem.Allocator,
    out: *std.ArrayList(router.Track),
    pts: []const [2]f64,
    layer: u8,
    width: f64,
    net: i32,
) std.mem.Allocator.Error!void {
    if (pts.len < 2) return; // a dropped chain emits nothing
    for (1..pts.len) |k| {
        if (dist(pts[k - 1], pts[k]) < eps) continue;
        try out.append(arena, .{
            .x1 = pts[k - 1][0],
            .y1 = pts[k - 1][1],
            .x2 = pts[k][0],
            .y2 = pts[k][1],
            .layer = layer,
            .width = width,
            .net = net,
        });
    }
}

const testing = std.testing;

/// A 0.3 x 0.9 mm land — a 0.5 mm-pitch QFN pad, long axis vertical — centred
/// at the origin, which is where the router anchors a terminal on it.
const qfn_pad = Pad{ .x0 = -0.15, .y0 = -0.45, .x1 = 0.15, .y1 = 0.45 };

/// A polyline's total length. Lives out here so the test bodies asserting on it
/// stay loop-free (Guardian's `test-no-conditional` rule).
fn polyLen(pts: []const [2]f64) f64 {
    var out: f64 = 0;
    for (1..pts.len) |i| out += dist(pts[i - 1], pts[i]);
    return out;
}

// spec: placement/pad-entry - a route that runs the length of its pad is trimmed to one outline crossing plus a short stub
test "a lap-joint entry down a pad's long axis becomes a single-point entry" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // The shape every escape leaves: the pad centre, straight out along the
    // pad's long axis past its edge, then away. 0.45 mm of the run lies ON the
    // pad — half the land's length.
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.51 }, .{ 1.5, -0.51 } };
    const cut = (try trimHead(arena, &pts, qfn_pad, stub_mm, &.{})) orelse
        return testing.expect(false);
    // One crossing, one stub: the surviving copper inside the pad is `stub_mm`.
    try testing.expectApproxEqAbs(-0.45 + stub_mm, cut[0][1], 1e-9);
    try testing.expectApproxEqAbs(0.0, cut[0][0], 1e-9);
    try testing.expect(onLand(qfn_pad, cut[0]));
    // Everything outside the pad is untouched — the trim only removes copper
    // from the terminal, it never re-routes.
    try testing.expectEqual(@as(usize, 3), cut.len);
    try testing.expectApproxEqAbs(-0.51, cut[1][1], 1e-9);
    try testing.expectApproxEqAbs(1.5, cut[2][0], 1e-9);
}

// spec: placement/pad-entry - an entry already shorter than the stub keeps its copper byte-identical
test "a short entry is left alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // A terminal anchored near the pad's edge already crosses out within the
    // stub, so there is no lap to remove and the pass must not churn it.
    const pts = [_][2]f64{ .{ 0, -0.4 }, .{ 0, -1.0 } };
    try testing.expect((try trimHead(arena, &pts, qfn_pad, stub_mm, &.{})) == null);
    // Nor is a chain that never leaves the pad at all trimmed — there is no
    // crossing to measure a stub back from.
    const inside_only = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.2 } };
    try testing.expect((try trimHead(arena, &inside_only, qfn_pad, stub_mm, &.{})) == null);
}

// spec: placement/pad-entry - a trimmed entry keeps its end on the pad's real copper, refusing the trim when a rounded land would not hold it
test "a trim that would leave the land is refused" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // A diamond land inside the same box: the box crossing on the diagonal is
    // well outside the copper, so a stub measured back from it would end in
    // air. The pass refuses rather than trusting the bounding box.
    const diamond = Pad{
        .x0 = -0.45,
        .y0 = -0.45,
        .x1 = 0.45,
        .y1 = 0.45,
        .poly = &.{ .{ 0, -0.45 }, .{ 0.45, 0 }, .{ 0, 0.45 }, .{ -0.45, 0 } },
    };
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 0.6, -0.6 } };
    try testing.expect((try trimHead(arena, &pts, diamond, stub_mm, &.{})) == null);
    // The same land trimmed along an axis, where the crossing IS on copper,
    // still trims.
    const axis = [_][2]f64{ .{ 0, 0 }, .{ 1.2, 0 } };
    const cut = (try trimHead(arena, &axis, diamond, stub_mm, &.{})) orelse
        return testing.expect(false);
    try testing.expect(onLand(diamond, cut[0]));
}

// spec: placement/pad-entry - both ends of a pad-to-pad hop are trimmed, and a via off the land inside the span a trim would remove pins that end while one on the land does not
test "a pad-to-pad chain trims at both ends and only an off-land via pins a head" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const far = Pad{ .x0 = 1.85, .y0 = -0.45, .x1 = 2.15, .y1 = 0.45 };
    const pads = [_]Pad{ qfn_pad, far };
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.9 }, .{ 2, -0.9 }, .{ 2, 0 } };
    const cut = (try trimChain(arena, &pts, &pads, stub_mm, &.{})) orelse
        return testing.expect(false);
    try testing.expectApproxEqAbs(-0.45 + stub_mm, cut[0][1], 1e-9);
    try testing.expectApproxEqAbs(-0.45 + stub_mm, cut[cut.len - 1][1], 1e-9);
    try testing.expectApproxEqAbs(0.0, cut[0][0], 1e-9);
    try testing.expectApproxEqAbs(2.0, cut[cut.len - 1][0], 1e-9);
    // A via standing on the pad's own LAND does not block the trim — the land
    // is solid copper and every graph that decides connectivity unites a pad
    // with a via touching it, so the barrel keeps its join once the track is
    // shortened. That is what lets a plane-via terminal be trimmed at all.
    const on_land = (try trimChain(arena, &pts, &pads, stub_mm, &.{.{ 0, 0 }})) orelse
        return testing.expect(false);
    try testing.expectApproxEqAbs(-0.45 + stub_mm, on_land[0][1], 1e-9);
    // A via OFF the land in the span a trim would remove pins that end: nothing
    // would carry the copper hanging off its other layer.
    try testing.expect(pinnedByVia(&.{.{ 0, 5 }}, &.{.{ 0, 5 }}, qfn_pad));
    try testing.expect(!pinnedByVia(&.{.{ 0, 0 }}, &.{.{ 0, 0 }}, qfn_pad));
}

// spec: placement/pad-entry - copper lying wholly on one pad's land is dropped rather than trimmed, since the land already joins whatever it touches
test "a chain that never leaves its own land is dropped" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Pad{qfn_pad};
    // A failed escape: 0.8 mm of copper drawn down the land's long axis that
    // never reaches open board. It reads exactly like the lap this pass exists
    // to remove, and it connects nothing the pad does not already connect.
    const stranded = [_][2]f64{ .{ 0, -0.4 }, .{ 0, 0.4 } };
    const cut = (try trimChain(arena, &stranded, &pads, stub_mm, &.{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 0), cut.len);
    // Copper that does reach open board is trimmed, never dropped.
    const escaping = [_][2]f64{ .{ 0, 0 }, .{ 0, -1.2 } };
    const kept = (try trimChain(arena, &escaping, &pads, stub_mm, &.{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 2), kept.len);
}

// spec: placement/pad-entry - the trim never lengthens a route and never moves copper that is already outside the pad
test "a trim only removes copper from the pad end" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.6 }, .{ 0.8, -1.4 }, .{ 2.0, -1.4 } };
    const cut = (try trimHead(arena, &pts, qfn_pad, stub_mm, &.{})) orelse
        return testing.expect(false);
    try testing.expect(polyLen(cut) < polyLen(&pts));
    // Every vertex outside the pad survives at exactly its routed position.
    try testing.expectEqualSlices([2]f64, pts[1..], cut[1..]);
}
