//! End-to-end router regressions for the maze's SHAPE cost model: the corner
//! price that settles an equal-length octilinear tie toward the straight path,
//! and the detour guards that give a connection which routed far past its own
//! span one second opinion before its route is final.
//!
//! Separate from `router.zig` because these are whole-board measurements rather
//! than unit checks — each one routes a real placement and reads the finished
//! copper — and because the router file is already at its size ceiling.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const route_policy = @import("route_policy.zig");
const route_timeline = @import("route_timeline.zig");

const testing = std.testing;
const Part = optimizer.Part;
const FlatNet = flat_netlist.FlatNet;
const Track = router.Track;
const RouteParams = router.RouteParams;

/// Routed copper length (mm) on one signal layer.
fn trackLenOnLayer(tracks: []const Track, layer: u8) f64 {
    var len: f64 = 0;
    for (tracks) |t| {
        if (t.layer == layer) len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return len;
}

/// A two-pad board plus an optional wall of un-netted top-side blockers between
/// them: one net from `a` to `b` on an open rectangle. The shape most of the
/// shape/cost tests below need, so they can differ in the one thing each is
/// about.
///
/// The wall is PARTS rather than a keepout zone because a part's pad copper is
/// the obstacle every tier of the router agrees on — the maze, the direct
/// synthesis and the finishing passes alike — and it lives on the placed part's
/// own side, so a top-side wall leaves B.Cu open by construction.
const PairBoard = struct {
    parts: [2 + max_wall]Part,
    pads: [2 + max_wall]geometry.Pad,
    pins: [2]flat_netlist.FlatPin,
    nets: [1]FlatNet,
    box: [4]f64,
    used: usize,

    const max_wall = 8;

    /// Stack `count` blocker pads of side `pad` up the line x = `x`, starting at
    /// `y0` and stepping by `pitch` — a wall the top face has to go round.
    fn wall(self: *PairBoard, x: f64, y0: f64, pitch: f64, count: usize, pad: f64) void {
        for (0..count) |i| {
            const slot = self.used + i;
            self.pads[slot] = .{ .number = "1", .x = 0, .y = 0, .w = pad, .h = pad };
            self.parts[slot].ref_des = wall_names[i];
            self.parts[slot].hw = pad / 2;
            self.parts[slot].hh = pad / 2;
            self.parts[slot].x = x;
            self.parts[slot].y = y0 + @as(f64, @floatFromInt(i)) * pitch;
        }
        self.used += count;
    }

    fn placement(self: *PairBoard) optimizer.Placement {
        for (self.parts[0..self.used], 0..) |*part, i| part.pads = self.pads[i .. i + 1];
        self.nets[0].pins = &self.pins;
        return .{
            .parts = self.parts[0..self.used],
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &self.nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = self.box[0],
            .miny = self.box[1],
            .maxx = self.box[2],
            .maxy = self.box[3],
            .generated = true,
            .rules = .{ .copper_layers = 2 },
        };
    }
};

/// Distinct ref-des for each wall blocker; a duplicate would read as one part.
const wall_names = [PairBoard.max_wall][]const u8{ "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8" };

/// One `pad`-sided part at (x, y). Blockers start parked on the board's corner
/// and are moved into place by `PairBoard.wall`.
fn pairPart(ref: []const u8, x: f64, y: f64, pad: f64) Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = pad, .hh = pad, .pads = &.{}, .fallback = false, .x = x, .y = y };
}

/// The two-terminal board `a`→`b`, with `box` as its outline and `pad`-sided
/// terminal copper. Blockers start parked on the box's corner; `wall` moves the
/// ones a fixture asks for into place.
fn pairAt(a: [2]f64, b: [2]f64, pad: f64, box: [4]f64) PairBoard {
    var out = PairBoard{
        .parts = @splat(pairPart("B", box[0], box[1], pad / 2)),
        .pads = @splat(.{ .number = "1", .x = 0, .y = 0, .w = pad, .h = pad }),
        .pins = .{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } },
        .nets = .{.{ .name = "SIG", .pins = &.{} }},
        .box = box,
        .used = 2,
    };
    out.parts[0] = pairPart("R1", a[0], a[1], pad);
    out.parts[1] = pairPart("R2", b[0], b[1], pad);
    return out;
}

/// Straight runs in the copper the MAZE drew, read off the `net_routed`
/// timeline event — the board as it stood the moment the net closed, before the
/// finishing passes ran.
///
/// The finished board is the wrong place to ask this question: the straighteners
/// and the pad-escape pass pull a lattice staircase taut afterwards, so a
/// two-pad hop lands as the same handful of tracks whether the search found one
/// diagonal run or sixteen facets. What the corner price buys is the shape the
/// search HANDS those passes, and this is where that is visible.
fn mazeRuns(run: router.RouteRun) ?usize {
    for (run.timeline) |event| {
        if (event.kind == .net_routed) return event.state.tracks.len;
    }
    return null;
}

// spec: placement/router - an equal-length octilinear tie is settled toward the straight path rather than an arbitrary staircase of the same length
test "an equal-length octilinear tie comes out straight rather than as a staircase" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // (0,0) → (12,4) on an open board. Every interleaving of the diagonal steps
    // with the orthogonal ones has EXACTLY the same length, so length alone
    // cannot choose between one diagonal run plus one straight run and a
    // staircase of the same span — only a corner price can. The hop is past
    // `direct_span_mm`, so the maze decides it and not the direct synthesis.
    var b = pairAt(.{ 0, 0 }, .{ 12, 4 }, 0.4, .{ -1, -1, 13, 5 });
    const run = try router.routeWithTimeline(arena, b.placement(), .{}, .{});
    try testing.expectEqual(@as(usize, 1), run.routed.routed);
    try testing.expectEqual(@as(usize, 0), run.routed.vias.len);
    // Measured: the same board with the corner priced at zero hands the
    // finishing passes SIXTEEN runs, and with it eight. Twelve leaves headroom
    // for the pad-join stubs without letting a staircase back through.
    try testing.expect(mazeRuns(run).? <= 12);
    // …and the finished copper still spans the pads it joins, so the shape was
    // bought rather than truncated.
    try testing.expect(route_timeline.traceLen(run.routed.tracks) > 12.0);
}

/// A 0.45 mm power-class trace, so the lattice pitch is 0.9 mm and the search
/// prices one via at four of them (3.6 mm) — the regime the guard exists for,
/// where what a via costs the SEARCH and what one costs the BOARD disagree by a
/// factor of three.
const detour_params = RouteParams{ .track_width = 0.45, .clearance = 0.45 };

/// The guard's board: a 6.3 mm hop with a wall of top-side pads across it, open
/// from the board's north edge down well past the route line, so the only
/// surface path is a long way round the wall's south end while B.Cu stays clear.
fn detourBoard() PairBoard {
    var b = pairAt(.{ 0, 0 }, .{ 6, 2 }, 0.9, .{ -3, -4, 9, 14 });
    b.wall(3, -3.5, 1.2, 8, 0.8);
    return b;
}

// spec: placement/router - a connection that routes far past its own span is retried once on another face and keeps whichever route costs the board less
test "a long surface detour is retried and takes the two-via alternative" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var b = detourBoard();

    const guarded = try router.routeWithOptions(arena, b.placement(), detour_params, .{});
    try testing.expectEqual(@as(usize, 1), guarded.routed);
    // The guard took the retry: copper on the far face, a via at each end, and
    // less total copper than the surface tour it replaced.
    try testing.expect(guarded.vias.len >= 2);
    try testing.expect(trackLenOnLayer(guarded.tracks, 1) > 2.0);
    try testing.expect(route_timeline.traceLen(guarded.tracks) < 10.0);
}

// spec: placement/router - a net whose policy forbids vias keeps its detour rather than gaining one from the detour guard
test "a zero-via policy net never gains a via from the detour guard" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var b = detourBoard();

    // The same board the guard flips above, with the net's via budget pinned at
    // zero — a bypass bond, or any net whose return loop must not be cut by a
    // barrel. The long surface tour is then the only legal route, and the guard
    // must leave it alone rather than buy the shorter one with copper the
    // policy forbids it to spend.
    const no_vias = [_]route_policy.NetPolicy{.{ .max_vias = 0 }};
    const pinned = try router.routeWithOptions(arena, b.placement(), detour_params, .{ .net = &no_vias });
    try testing.expectEqual(@as(usize, 1), pinned.routed);
    try testing.expectEqual(@as(usize, 0), pinned.vias.len);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(pinned.tracks, 1));
}
