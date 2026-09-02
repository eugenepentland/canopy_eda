//! Finding a needless LAYER HOP in one net's copper: two pure transition vias
//! joined by a single-layer run, whose outer ends both sit on one other layer.
//!
//! The maze buys a layer change for a fixed multiple of grid steps, so wherever
//! the far side looks even slightly cheaper it dives, runs a millimetre, and
//! climbs back. Two cleanup passes delete that pattern, differing only in what
//! they redraw it as: `route_cleanup.dropRedundantViaPairs` tries a plain
//! octilinear ELBOW, and `dive_elide` follows up with a swept three-segment
//! corridor for the dives an elbow cannot bend to.
//!
//! DETECTION is the same question for both, and it was written twice — the same
//! incident-leg scan, the same transition-via test, the same run walk, under two
//! names (`HopScan`/`Scan`, `findHop`/`findDive`) with the same three constants
//! spelled out in each file. The copies had already parted over one thing: the
//! corridor search needs the run's LENGTH (it may not spend more copper than it
//! removes) and the elbow search does not, so only one of the two walks
//! accumulated it. Nothing else about them differed, and nothing else should:
//! two passes disagreeing about what counts as a deletable hop would delete
//! different vias on the same board depending on which ran first.
//!
//! Pure reads over plain track/via slices — no routing context, so the geometry
//! is unit-testable on fixtures and the `@import` graph stays acyclic. The
//! caller applies whatever it decides.

const std = @import("std");
const router = @import("router.zig");

const Track = router.Track;
const Via = router.Via;

/// "This track end sits on that via" tolerance — the router emits both from the
/// same grid node, so this only absorbs float drift.
pub const snap_mm: f64 = 1e-6;

/// Most incident track ends recorded at a point; past this it is a junction and
/// no hop through it is considered.
const max_legs: usize = 3;

/// Longest run (in segments) the walk follows between two vias.
const max_run_segs: usize = 24;

/// Do two points coincide within the snap tolerance?
pub fn ptEq(a: [2]f64, b: [2]f64) bool {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]) <= snap_mm;
}

/// One track end seen from a point it touches, pointing away from it.
const Leg = struct { track: usize, layer: u8, far: [2]f64 };

/// The legs found at a point; `n` keeps counting past `max_legs` so a junction
/// is still recognised as one.
const Legs = struct {
    n: usize = 0,
    items: [max_legs]Leg = @splat(.{ .track = 0, .layer = 0, .far = .{ 0, 0 } }),
};

/// One hop found in a net's copper: two pure transition vias (`v1`, `v2`)
/// joined by a single-layer `run`, where the copper on the FAR side of both
/// vias sits on one other layer (`outer`) — so the run can be redrawn there and
/// both vias deleted. `away` is where each via's outer leg heads (the direction
/// a replacement must not run back over) and `run_mm` is how much copper the
/// run is, which a replacement search may hold itself to.
pub const Hop = struct {
    v1: usize,
    v2: usize,
    run: []const usize,
    outer: u8,
    away: [2][2]f64,
    run_mm: f64,
};

/// One net's copper, for the hop scan. Pure reads — the caller applies.
pub const Scan = struct {
    arena: std.mem.Allocator,
    tracks: []const Track,
    vias: []const Via,
    net: i32,

    /// Every track end of this net incident on `p`.
    fn legsAt(self: Scan, p: [2]f64) Legs {
        var out = Legs{};
        for (self.tracks, 0..) |t, i| {
            if (t.net != self.net) continue;
            const a = [2]f64{ t.x1, t.y1 };
            const b = [2]f64{ t.x2, t.y2 };
            const far: [2]f64 = if (ptEq(a, p)) b else if (ptEq(b, p)) a else continue;
            if (out.n < max_legs) out.items[out.n] = .{ .track = i, .layer = t.layer, .far = far };
            out.n += 1;
        }
        return out;
    }

    fn viaAt(self: Scan, p: [2]f64) ?usize {
        for (self.vias, 0..) |v, i| {
            if (v.net == self.net and ptEq(.{ v.x, v.y }, p)) return i;
        }
        return null;
    }

    /// The two legs of via `vi` when it is a pure TRANSITION via: exactly two
    /// track ends meet it, on two different layers, so it exists only to change
    /// layer. Null for a terminal via, a junction, or a stub.
    fn transition(self: Scan, vi: usize) ?[2]Leg {
        const v = self.vias[vi];
        const legs = self.legsAt(.{ v.x, v.y });
        if (legs.n != 2 or legs.items[0].layer == legs.items[1].layer) return null;
        return .{ legs.items[0], legs.items[1] };
    }

    /// Follow `start` away from a via along its own layer, collecting the run
    /// and its length, until another via of this net is reached. Null when the
    /// run branches, dead-ends, or would need a layer change to continue — that
    /// is what proves the copper about to be deleted serves nothing else.
    fn walk(self: Scan, start: Leg, run: *std.ArrayList(usize), mm: *f64) std.mem.Allocator.Error!?usize {
        var leg = start;
        var steps: usize = 0;
        while (steps < max_run_segs) : (steps += 1) {
            try run.append(self.arena, leg.track);
            const t = self.tracks[leg.track];
            mm.* += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
            if (self.viaAt(leg.far)) |vj| return vj;
            const legs = self.legsAt(leg.far);
            if (legs.n != 2) return null; // branch or dead end
            const cont = if (legs.items[0].track == leg.track) legs.items[1] else legs.items[0];
            if (cont.layer != leg.layer) return null; // no layer change without a via
            leg = cont;
        }
        return null;
    }

    /// The hop through via `vi`, if it is one. Both run directions are tried:
    /// either of the via's two layers may be the detour.
    pub fn find(self: Scan, vi: usize) std.mem.Allocator.Error!?Hop {
        const pair = self.transition(vi) orelse return null;
        for (0..2) |k| {
            const run_leg = pair[k];
            const outer = pair[1 - k].layer;
            var run: std.ArrayList(usize) = .empty;
            var mm: f64 = 0;
            const vj = (try self.walk(run_leg, &run, &mm)) orelse continue;
            if (vj == vi) continue;
            const far = self.transition(vj) orelse continue;
            const far_outer = if (far[0].layer == run_leg.layer) far[1] else far[0];
            if (far_outer.layer != outer) continue;
            return Hop{
                .v1 = vi,
                .v2 = vj,
                .run = run.items,
                .outer = outer,
                .away = .{ pair[1 - k].far, far_outer.far },
                .run_mm = mm,
            };
        }
        return null;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - a dive scan pairs two pure transition vias through a single-layer run and refuses a run that branches
test "the dive scan finds a two-via layer detour and rejects a branching run" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // F.Cu in → via → B.Cu across (two segments) → via → F.Cu out.
    const vias = [_]Via{
        .{ .x = 1, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 3, .y = 0, .dia = 0.4, .net = 0 },
    };
    var tracks = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
        .{ .x1 = 3, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const scan = Scan{ .arena = arena, .tracks = &tracks, .vias = &vias, .net = 0 };
    const dive = (try scan.find(0)).?;
    try testing.expectEqual(@as(usize, 1), dive.v2);
    try testing.expectEqual(@as(u8, 0), dive.outer); // both ends already use F.Cu
    try testing.expectEqual(@as(usize, 2), dive.run.len);
    // The run's LENGTH is the half only the corridor search needed, and the
    // reason the two hand-written copies of this scan had drifted apart.
    try testing.expectApproxEqAbs(@as(f64, 2), dive.run_mm, 1e-9);
    // Each end's outer leg heads AWAY from the detour, which a replacement may
    // not double back over.
    try testing.expectApproxEqAbs(@as(f64, 0), dive.away[0][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), dive.away[1][0], 1e-9);
    // A third leg hanging off the run's midpoint makes it a branch, not a dive.
    const branched = tracks ++ [_]Track{
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 1, .layer = 1, .width = 0.2, .net = 0 },
    };
    const scan2 = Scan{ .arena = arena, .tracks = &branched, .vias = &vias, .net = 0 };
    try testing.expect((try scan2.find(0)) == null);
}
