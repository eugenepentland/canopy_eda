//! Whose copper stands in a stuck net's way — the ONE nomination both
//! rip-and-re-route tiers ask.
//!
//! Two tiers take foreign copper off the board and re-route a cluster around the
//! hole: `joint_rescue.zig` inside the batch route, and `serve/mcp_close_gaps.zig`'s
//! vacate phase afterwards, over a saved layout. Both open with the same
//! question — *whose copper is in the way?* — and each grew its own answer, over
//! its own hash map, with its own (unspecified) iteration order and its own
//! sort. The 2026-08 router audit put it bluntly: three nomination
//! implementations exist and the tier facing the hardest problem uses the
//! weakest one.
//!
//! There are exactly two ways to answer, and they fail in OPPOSITE directions,
//! which is why neither is redundant:
//!
//!   * **The probe** — `router.detectBlockers`, a soft Dijkstra from pad to pad
//!     with foreign copper passable at a penalty — reports every net whose
//!     OCCUPANCY the stuck net's cheapest path crosses. It sees via barrels,
//!     45°-step reservations and stamped RF keepout halos, because all three
//!     live in the grid it walks. But `softEnter` treats a foreign PAD as a hard
//!     wall, and blockers are recorded only off a path that COMPLETED, so a net
//!     boxed in by pads yields nothing whatsoever. Measured on board-a: six of
//!     the seven nets reaching the in-route tier report an EMPTY probe.
//!   * **The corridor sweep** always answers, because it is pure geometry: every
//!     foreign net whose copper lies within a radius of one of the straight hops
//!     the net still has to make. But both copies of it only ever looked at
//!     TRACKS, so a via field parked across a channel was invisible — the
//!     "via-blind" half of the same audit finding, and the reason a sealed
//!     corridor could read as empty and nominate nobody.
//!
//! So this module is their union: one `Table`, one `nearer` rule (a net's
//! CLOSEST approach wins, and a net the probe walked THROUGH is recorded at
//! zero — nothing is more in the way than copper on your own cheapest path), and
//! one deterministic `ranked` order both callers had been re-deriving. The sweep
//! takes vias as well as tracks (`ViaPolicy`), which is what a tier with no live
//! router context to probe with needs: the post-route vacate tier's `Ctx` is
//! built and dropped inside each `router.closeGaps` call, so it cannot probe at
//! all, and geometry is its only sense.
//!
//! JUDGEMENT IS NOT HERE, deliberately. What may be ripped differs between the
//! tiers on real grounds — `vacate_policy.zig` will displace a poured rail
//! because the pour underwrites its restoration, and `joint_rescue.judge` will
//! not, because mid-route nothing underwrites anything. Nomination is the half
//! that was accidentally different; keeping the policies apart is the half that
//! is meant to be.

const std = @import("std");
const drc = @import("drc.zig");
const router = @import("router.zig");

/// One candidate net and how close its copper comes to the stuck net's
/// corridor, in millimetres. Zero means the soft probe walked THROUGH it.
pub const Candidate = struct { net_i: usize, dist: f64 };

/// One straight hop the stuck net still has to make — the line a sweep measures
/// against. Both tiers already own such a list: the in-route tier's is
/// `fine_window.mstLegs` over the net's pads, the post-route tier's is the
/// connectivity oracle's own island-joining gaps.
pub const Hop = struct { ax: f64, ay: f64, bx: f64, by: f64 };

/// Does a via field count as copper standing in the corridor?
pub const ViaPolicy = enum {
    /// Tracks alone — what both sweeps did before this module existed, and what
    /// the in-route tier keeps: its probe already reports every net whose via
    /// barrels sit on the path, so sweeping them again would only reshuffle two
    /// equally-in-the-way candidates and move a measured route.
    tracks_only,
    /// Tracks and via barrels. The answer for a tier that has no probe: a row of
    /// vias across a channel walls it exactly as a track does, and nominating
    /// nothing for it is how a sealed corridor reads as empty.
    tracks_and_vias,
};

/// One corridor sweep's inputs (see `sweepHops`). An options struct rather than
/// a parameter list because the two halves — what the net wants, what the board
/// holds — are read at different call sites.
pub const Sweep = struct {
    /// The stuck net. Its own copper is never its own blocker.
    net_i: usize,
    /// The hops whose corridors are swept.
    hops: []const Hop,
    /// The board's live tracks.
    tracks: []const router.Track,
    /// The board's live vias; consulted only under `.tracks_and_vias`.
    vias: []const router.Via = &.{},
    /// How far from a hop's straight line foreign copper still counts as being
    /// in the way. Wide enough to catch the copper actually lying across the
    /// channel plus its clearance, narrow enough that a cross-board corridor
    /// does not nominate every net on the board.
    radius_mm: f64,
    /// Whether via barrels are swept (see `ViaPolicy`).
    via_policy: ViaPolicy = .tracks_only,
};

/// The accumulating candidate set: flattened-net index → closest approach in mm.
///
/// Additive on purpose. One table raised over ONE seed's corridors is a
/// single-seed nomination; the same table raised over SEVERAL seeds' corridors
/// is the union a joint transaction vacates, with no second code path and no
/// second ranking.
pub const Table = struct {
    near: std.AutoHashMapUnmanaged(usize, f64) = .empty,

    /// Record `net_i` at `d` mm, keeping whichever approach is closer. Closest
    /// wins because a net that brushes one corridor at 1.9 mm and lies straight
    /// across another at 0 mm is, for the purpose of getting out of the way,
    /// the second one.
    pub fn nearer(
        self: *Table,
        alloc: std.mem.Allocator,
        net_i: usize,
        d: f64,
    ) std.mem.Allocator.Error!void {
        const slot = try self.near.getOrPut(alloc, net_i);
        if (!slot.found_existing or d < slot.value_ptr.*) slot.value_ptr.* = d;
    }

    /// How many distinct nets have been nominated so far.
    pub fn count(self: Table) usize {
        return self.near.count();
    }

    /// Has `net_i` been nominated? Two seeds whose tables share a net are
    /// contending for the same copper, which is the whole test a joint
    /// transaction forms its cluster on.
    pub fn has(self: Table, net_i: usize) bool {
        return self.near.contains(net_i);
    }

    /// Every candidate, NEAREST first, ties broken on net index.
    ///
    /// A hash map's iteration order is unspecified, and both callers were
    /// sorting their own copy of it for exactly that reason — one by distance,
    /// one by index, each having had to rediscover why. Ordering here means a
    /// board nominates the same subset in the same order on every run without a
    /// caller having to remember to ask.
    pub fn ranked(self: Table, alloc: std.mem.Allocator) std.mem.Allocator.Error![]const Candidate {
        var out: std.ArrayList(Candidate) = .empty;
        var it = self.near.iterator();
        while (it.next()) |e| try out.append(alloc, .{ .net_i = e.key_ptr.*, .dist = e.value_ptr.* });
        std.mem.sort(Candidate, out.items, {}, nearerFirst);
        return out.toOwnedSlice(alloc);
    }
};

/// Nearest-the-corridor first, net index as the deterministic tie-break.
pub fn nearerFirst(_: void, a: Candidate, b: Candidate) bool {
    if (a.dist != b.dist) return a.dist < b.dist;
    return a.net_i < b.net_i;
}

/// Nomination half one: fold `router.detectBlockers`'s yield into `t`.
///
/// Recorded at distance ZERO. The probe does not report a proximity — it
/// reports that the stuck net's own cheapest path runs through this copper,
/// which is as in-the-way as a net gets, and the ranking should say so.
/// Negative ids (the router's `empty_cell` and its keepout sentinels) are not
/// nets and are dropped.
pub fn foldProbe(
    t: *Table,
    alloc: std.mem.Allocator,
    crossed: []const i32,
) std.mem.Allocator.Error!void {
    for (crossed) |b| {
        if (b < 0) continue;
        try t.nearer(alloc, @intCast(b), 0);
    }
}

/// Nomination half two: every foreign net whose copper comes within
/// `s.radius_mm` of one of `s.hops`, each at its closest approach.
///
/// This is the half that always answers. It is what the post-route vacate tier
/// has always nominated from and what gave that tier its measured board-a
/// 85 → 91; the in-route tier added it after finding its probe empty on six of
/// seven residual nets.
pub fn sweepHops(t: *Table, alloc: std.mem.Allocator, s: Sweep) std.mem.Allocator.Error!void {
    const ni: i32 = @intCast(s.net_i);
    for (s.tracks) |c| {
        if (c.net < 0 or c.net == ni) continue;
        const d = trackGap(s.hops, c);
        if (d > s.radius_mm) continue;
        try t.nearer(alloc, @intCast(c.net), d);
    }
    if (s.via_policy != .tracks_and_vias) return;
    for (s.vias) |v| {
        if (v.net < 0 or v.net == ni) continue;
        const d = viaGap(s.hops, v);
        if (d > s.radius_mm) continue;
        try t.nearer(alloc, @intCast(v.net), d);
    }
}

/// Closest approach of one TRACK to any of `hops`, in mm. Infinite when there
/// are no hops, so a net with nothing left to close is in nobody's way.
///
/// Public because a nomination is not always the end of the story: a
/// transaction that lifts only the copper standing in the corridor — rather
/// than the whole net — has to answer the same question per ELEMENT that the
/// sweep answered per net, and answering it with a second distance rule is how
/// a net gets nominated for copper the rip then leaves behind.
pub fn trackGap(hops: []const Hop, c: router.Track) f64 {
    var lo = std.math.inf(f64);
    for (hops) |h| lo = @min(lo, drc.segSegDist(h.ax, h.ay, h.bx, h.by, c.x1, c.y1, c.x2, c.y2));
    return lo;
}

/// Closest approach of one VIA BARREL to any of `hops`, in mm.
///
/// A barrel is a disc, so the gap to the corridor is the distance to its centre
/// LESS its own radius: a 0.6 mm power via reaches 0.3 mm further into the
/// channel than its coordinate alone says, and on a fine-pitch escape row that
/// is the whole margin.
pub fn viaGap(hops: []const Hop, v: router.Via) f64 {
    var lo = std.math.inf(f64);
    for (hops) |h| lo = @min(lo, drc.segSegDist(h.ax, h.ay, h.bx, h.by, v.x, v.y, v.x, v.y));
    return @max(0, lo - v.dia / 2);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// One horizontal hop across the middle of a 10 mm board, the shape both tiers'
/// corridors take in their own fixtures.
const mid_hop = Hop{ .ax = 2, .ay = 5, .bx = 8, .by = 5 };

// spec: placement/blocker-nomination - the shared nomination records each candidate net's closest approach to any of the stuck net's corridors
test "a candidate keeps its closest approach across several hops" {
    var t = Table{};
    try t.nearer(testing.allocator, 4, 1.9);
    try t.nearer(testing.allocator, 4, 0.2);
    try t.nearer(testing.allocator, 4, 1.1);
    defer t.near.deinit(testing.allocator);
    const ranked = try t.ranked(testing.allocator);
    defer testing.allocator.free(ranked);
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectApproxEqAbs(@as(f64, 0.2), ranked[0].dist, 1e-12);
}

// spec: placement/blocker-nomination - a net the soft probe walked through is nominated at distance zero, ahead of every net merely near the corridor
test "the probe's yield outranks the sweep's" {
    var t = Table{};
    defer t.near.deinit(testing.allocator);
    const tracks = [_]router.Track{
        .{ .x1 = 5, .y1 = 3, .x2 = 5, .y2 = 4.5, .layer = 0, .width = 0.127, .net = 2 },
    };
    try sweepHops(&t, testing.allocator, .{
        .net_i = 0,
        .hops = &.{mid_hop},
        .tracks = &tracks,
        .radius_mm = 2.0,
    });
    // The probe reports net 3, which has no copper anywhere near the straight
    // line — it walls the net somewhere the corridor never looked.
    try foldProbe(&t, testing.allocator, &.{ 3, -1 });
    const ranked = try t.ranked(testing.allocator);
    defer testing.allocator.free(ranked);
    try testing.expectEqual(@as(usize, 2), ranked.len);
    try testing.expectEqual(@as(usize, 3), ranked[0].net_i); // probe first, at 0
    try testing.expectApproxEqAbs(@as(f64, 0), ranked[0].dist, 1e-12);
    try testing.expectEqual(@as(usize, 2), ranked[1].net_i);
    try testing.expectApproxEqAbs(@as(f64, 0.5), ranked[1].dist, 1e-12);
}

// spec: placement/blocker-nomination - a via field across a corridor is nominated under the via-aware policy and invisible without it, and a barrel is measured from its edge
test "a via field is nominated only under the via-aware policy" {
    const vias = [_]router.Via{.{ .x = 5, .y = 3.1, .dia = 0.6, .net = 7 }};
    var blind = Table{};
    defer blind.near.deinit(testing.allocator);
    try sweepHops(&blind, testing.allocator, .{
        .net_i = 0,
        .hops = &.{mid_hop},
        .tracks = &.{},
        .vias = &vias,
        .radius_mm = 2.0,
    });
    try testing.expectEqual(@as(usize, 0), blind.count());

    var seeing = Table{};
    defer seeing.near.deinit(testing.allocator);
    try sweepHops(&seeing, testing.allocator, .{
        .net_i = 0,
        .hops = &.{mid_hop},
        .tracks = &.{},
        .vias = &vias,
        .radius_mm = 2.0,
        .via_policy = .tracks_and_vias,
    });
    const ranked = try seeing.ranked(testing.allocator);
    defer testing.allocator.free(ranked);
    try testing.expectEqual(@as(usize, 1), ranked.len);
    try testing.expectEqual(@as(usize, 7), ranked[0].net_i);
    // 1.9 mm centre-to-line, less the 0.3 mm barrel radius: the disc reaches
    // into the channel, and measuring from the centre alone would say 1.9.
    try testing.expectApproxEqAbs(@as(f64, 1.6), ranked[0].dist, 1e-12);
}

// spec: placement/blocker-nomination - a nomination never nominates the stuck net's own copper, nor copper outside the corridor radius
test "the sweep skips the net's own copper and everything out of reach" {
    var t = Table{};
    defer t.near.deinit(testing.allocator);
    const tracks = [_]router.Track{
        .{ .x1 = 3, .y1 = 5, .x2 = 4, .y2 = 5, .layer = 0, .width = 0.127, .net = 0 }, // own
        .{ .x1 = 2, .y1 = 1, .x2 = 8, .y2 = 1, .layer = 0, .width = 0.127, .net = 5 }, // 4 mm off
        .{ .x1 = 5, .y1 = 4, .x2 = 5, .y2 = 6, .layer = 0, .width = 0.127, .net = 6 }, // across
    };
    const vias = [_]router.Via{
        .{ .x = 5, .y = 5, .dia = 0.4, .net = 0 }, // own barrel, on the line
    };
    try sweepHops(&t, testing.allocator, .{
        .net_i = 0,
        .hops = &.{mid_hop},
        .tracks = &tracks,
        .vias = &vias,
        .radius_mm = 2.0,
        .via_policy = .tracks_and_vias,
    });
    const ranked = try t.ranked(testing.allocator);
    defer testing.allocator.free(ranked);
    try testing.expectEqual(@as(usize, 1), ranked.len);
    try testing.expectEqual(@as(usize, 6), ranked[0].net_i);
}

// spec: placement/blocker-nomination - the per-element corridor gap the sweep nominates by is the same measure a caller reads to decide which of a net's own tracks and barrels lie in the way
test "the per-element corridor gap is the sweep's own measure" {
    const across = router.Track{ .x1 = 5, .y1 = 4, .x2 = 5, .y2 = 6, .layer = 0, .width = 0.127, .net = 6 };
    const away = router.Track{ .x1 = 2, .y1 = 1, .x2 = 8, .y2 = 1, .layer = 0, .width = 0.127, .net = 6 };
    const hops = [_]Hop{mid_hop};
    // The track lying across the hop is at zero; the one 4 mm off reads 4.
    try testing.expectApproxEqAbs(@as(f64, 0), trackGap(&hops, across), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), trackGap(&hops, away), 1e-12);
    // A barrel is measured from its EDGE, exactly as the sweep measures it.
    try testing.expectApproxEqAbs(
        @as(f64, 1.6),
        viaGap(&hops, .{ .x = 5, .y = 3.1, .dia = 0.6, .net = 7 }),
        1e-12,
    );
    // And what the sweep nominated is what these two report: the net's closest
    // element decides, so a lift that takes everything within the same radius
    // takes the copper the nomination was made for.
    var t = Table{};
    defer t.near.deinit(testing.allocator);
    try sweepHops(&t, testing.allocator, .{
        .net_i = 0,
        .hops = &hops,
        .tracks = &.{ across, away },
        .radius_mm = 2.0,
    });
    const ranked = try t.ranked(testing.allocator);
    defer testing.allocator.free(ranked);
    try testing.expectEqual(@as(usize, 1), ranked.len);
    try testing.expectApproxEqAbs(trackGap(&hops, across), ranked[0].dist, 1e-12);
    // No hops left to close: nothing is in the way, by either reading.
    try testing.expect(std.math.isInf(trackGap(&.{}, across)));
}

// spec: placement/blocker-nomination - the shared nomination's order is deterministic for a given board, nearest first and net index on a tie
test "the ranked order is deterministic" {
    var t = try tiedTable();
    defer t.near.deinit(testing.allocator);
    const a = try t.ranked(testing.allocator);
    defer testing.allocator.free(a);
    const b = try t.ranked(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 11), a[0].net_i); // nearest leads
    // Then index order on the equal ranks, identically on the second read.
    const want = [_]usize{ 11, 2, 4, 7, 9 };
    for (a, b, want) |x, y, w| {
        try testing.expectEqual(w, x.net_i);
        try testing.expectEqual(w, y.net_i);
    }
}

/// Four nets tied at one distance, inserted out of index order, plus a nearer
/// fifth — the shape that tells a stable ranking from a map's own iteration.
fn tiedTable() std.mem.Allocator.Error!Table {
    var t = Table{};
    for ([_]usize{ 9, 2, 7, 4 }) |n| try t.nearer(testing.allocator, n, 0.5);
    try t.nearer(testing.allocator, 11, 0.1);
    return t;
}

// spec: placement/blocker-nomination - one nomination table accumulates several seeds' corridors, so a joint transaction's candidate set is their union
test "a table raised over two seeds holds the union of their corridors" {
    var t = Table{};
    defer t.near.deinit(testing.allocator);
    const tracks = [_]router.Track{
        .{ .x1 = 5, .y1 = 4.6, .x2 = 5, .y2 = 5.4, .layer = 0, .width = 0.127, .net = 3 },
        .{ .x1 = 5, .y1 = 7.6, .x2 = 5, .y2 = 8.4, .layer = 0, .width = 0.127, .net = 4 },
    };
    // Seed 0 runs along y = 5, seed 1 along y = 8; net 3 walls the first, net 4
    // the second, and neither seed alone sees both.
    try sweepHops(&t, testing.allocator, .{
        .net_i = 0,
        .hops = &.{mid_hop},
        .tracks = &tracks,
        .radius_mm = 2.0,
    });
    try testing.expect(t.has(3) and !t.has(4));
    try sweepHops(&t, testing.allocator, .{
        .net_i = 1,
        .hops = &.{.{ .ax = 2, .ay = 8, .bx = 8, .by = 8 }},
        .tracks = &tracks,
        .radius_mm = 2.0,
    });
    try testing.expect(t.has(3) and t.has(4));
    try testing.expectEqual(@as(usize, 2), t.count());
}
