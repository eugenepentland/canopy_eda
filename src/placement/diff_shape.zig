//! The GRIDLESS channel search for a coupled differential pair's envelope.
//!
//! `diff_couple` routes a declared pair as ONE centreline whose copper profile
//! is the whole pair envelope (`2·width + gap`), then splits that centreline
//! into two exact ±(width+gap)/2 offset legs. The centreline comes from the
//! raster maze, and when the maze finds nothing the pair falls back to two
//! independent leader/follower routes — the `no_corridor` decline.
//!
//! That verdict is the same one the single-net rescue tiers learned not to
//! trust: a channel narrower than the grid pitch, or one that only opens by
//! diving to another layer, is not a path a lattice can represent however much
//! budget it is handed. The answer there was `cdt_layers` — one navmesh per
//! allowed layer over the same window, joined at legal via sites — and this is
//! that same search asked for a pair, at the ENVELOPE width, so the corridor it
//! comes back with is one both legs fit in by construction.
//!
//! It is a CENTRELINE SOURCE and nothing more. What comes back is handed to the
//! caller's own `diff_route.build` / `equalize` / exact-probe chain unchanged,
//! so a mesh channel earns its copper on precisely the terms a maze channel
//! does: mitered through every bend, paired at every via, length-matched in the
//! pad fans, and refused outright when any constructed segment fails the honest
//! clearance probe. Nothing here emits copper and nothing here relaxes a rule.
//!
//! Reached only when the caller's tier turns it on
//! (`route_policy.PairChannel.mesh_behind_maze`), so every board that has ever
//! routed without it stays byte-identical.

const std = @import("std");
const router = @import("router.zig");
const cdt_layers = @import("cdt_layers.zig");
const diff_pairs = @import("diff_pairs.zig");
const diff_route = @import("diff_route.zig");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// The pair's two centreline terminals as the mesh wants them: the far escape
/// points `diff_route.Ends` already resolved, which are the exact two points the
/// maze's own envelope search launches from.
fn envelopeTerminals(ends: diff_route.Ends) [2]router.NetPt {
    return .{
        .{ .x = ends.far[0].x, .y = ends.far[0].y, .layer = ends.far[0].layer },
        .{ .x = ends.far[1].x, .y = ends.far[1].y, .layer = ends.far[1].layer },
    };
}

/// A multi-layer mesh route read as a centreline: one run per leg, one point per
/// via between them.
///
/// The two representations agree field for field — `cdt_layers.Leg` is a layer
/// plus a polyline and `diff_route.Run` is a layer plus a polyline — so this is a
/// transcription rather than a conversion. Null when the mesh handed back nothing
/// a leg construction can be built on.
///
/// The N-runs / N-1-vias SHAPE is checked rather than assumed, and that is not
/// defensiveness: `diff_route.chain` guarantees it for a maze centreline, and
/// `diff_route.build` and `shiftVia` both read `runs[i + 1]` for via `i` on the
/// strength of that guarantee. The mesh does not make it — `cdt_layers.extract`
/// appends a via unconditionally but drops a leg whose funnel yields no polyline,
/// so a route CAN come back with a trailing via and one run too few. Measured on
/// board-a: `REF_LMX_P`/`REF_LMX_N`'s re-home found exactly that channel (four
/// runs, four vias) and `shiftVia` indexed past its own last run. The router's own
/// emitter is happy with the looser shape, so the refusal belongs here, on the one
/// consumer whose contract is tighter.
fn centerlineOf(
    arena: std.mem.Allocator,
    found: cdt_layers.Route,
) std.mem.Allocator.Error!?diff_route.Centerline {
    if (found.legs.len == 0) return null;
    if (found.vias.len + 1 != found.legs.len) return null;
    const runs = try arena.alloc(diff_route.Run, found.legs.len);
    for (found.legs, runs) |leg, *run| {
        if (leg.path.len < 2) return null;
        const pts = try arena.alloc(diff_route.Pt, leg.path.len);
        for (leg.path, pts) |at, *pt| pt.* = .{ .x = at[0], .y = at[1] };
        run.* = .{ .layer = leg.layer, .pts = pts };
    }
    const vias = try arena.alloc(diff_route.Pt, found.vias.len);
    for (found.vias, vias) |site, *pt| pt.* = .{ .x = site.x, .y = site.y };
    return .{ .runs = runs, .vias = vias };
}

/// What the pair's envelope search FOUND: a centreline, or the wall that stopped
/// it (`cdt_layers.Pinch`).
///
/// A search that comes back empty is a fact about the board, and until now the
/// only fact it carried was its own emptiness — "no envelope channel in the mesh
/// either", which tells a reader that the geometry said no and nothing whatever
/// about what the geometry WAS. The mesh knows: it triangulates the pair's free
/// space at envelope width and can be walked through its own walls to find the
/// narrowest cut between the two terminals and the copper that owns each side of
/// it. That is a name a caller can act on — a rip may be able to CREATE the
/// channel a re-home needs — where an empty answer never was.
pub const Channel = struct {
    center: ?diff_route.Centerline = null,
    pinch: ?cdt_layers.Pinch = null,
};

/// Search the mesh for a channel wide enough for this pair's whole envelope and
/// return it as a centreline the caller can construct legs from — or, when no
/// such channel exists, the wall that closed it. That verdict is a statement
/// about the board's geometry, since the mesh has no lattice to be limited by.
///
/// The envelope width is the ONE substitution: obstacles are inflated by
/// `(2·width + gap)/2 + clearance`, so the free space the mesh triangulates is
/// exactly the set of places the pair's centreline may sit with both legs and
/// their outer clearance inside the board's copper rules. Everything else — the
/// window, the per-layer prices, the halos, the keepouts, the via sites — is
/// `router.shapeInput`'s, the same model every other mesh caller routes against.
///
/// The via sites are seeded at the single-track legality the router can answer
/// on its own; a pair needs room for a barrel PAIR, which only the construction
/// knows, so `diff_couple`'s via-float ladder walks each transition until the
/// exact probe passes. A site this seed offers that no pair fits simply loses
/// its candidate, exactly as a maze-chosen transition does.
///
/// The twin's copper is not hidden. In the caller's flow neither leg has copper
/// yet (the pair routes as one unit), and its PADS stay foreign obstacles for
/// the same reason `diff_couple.PairPads` documents: a centreline free to hug
/// its twin's landing pad builds a leg that grazes it and fails the honest probe.
///
/// A channel the mesh found but the leg construction cannot use comes back with
/// NEITHER half: the mesh answered, so there is no wall to name, and the caller
/// already has its own verdict for that case.
pub fn envelopeChannel(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
) std.mem.Allocator.Error!Channel {
    const ctx = run.ctx;
    const arena = ctx.arena;
    const pts = envelopeTerminals(ends);
    router.setNetRoutePolicy(ctx, pair.p, &pts);
    // The mesh attempt owns its own budget, exactly as every other `shapeInput`
    // caller does. Without this the via-site scan spends the probe allowance the
    // pair's own legacy fallback is still going to need — measured as a coupled
    // re-home that stopped landing at all on the walled-pair fixture, because the
    // route BEHIND the declined mesh attempt had nothing left to probe with.
    const saved_budget = ctx.direct_budget;
    ctx.direct_budget = null;
    defer ctx.direct_budget = saved_budget;
    const ask = (try router.shapeInput(run.direct(pair.p), .{
        .placement = run.placement,
        .tracks = run.tracks.items,
        .vias = run.vias.items,
        .from = pts[0],
        .to = pts[1],
        .width = 2 * ctx.params.track_width + pair.gap,
    })) orelse return .{};
    const found = try cdt_layers.routeDiagnosed(arena, ask);
    const route = found.route orelse return .{ .pinch = found.pinch };
    const center = (try centerlineOf(arena, route)) orelse return .{};
    return .{ .center = try diff_route.extendEnds(arena, center, ends.mid[0], ends.mid[1]) };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const route_policy = @import("route_policy.zig");

test {
    testing.refAllDecls(@This());
}

// spec: placement/diff-shape - the pair mesh tier is off unless a caller turns it on, so an ordinary run routes every declared pair on the lattice alone
test "the pair channel default is the maze alone" {
    const defaults = route_policy.Guides{};
    try testing.expectEqual(route_policy.PairChannel.maze_only, defaults.pair_channel);
    try testing.expect(!defaults.pair_channel.meshes());
    try testing.expect(route_policy.PairChannel.mesh_behind_maze.meshes());
}

/// A one-leg mesh answer over caller-owned storage, so the `Route` this hands
/// back outlives the call that built it.
fn meshRoute(
    arena: std.mem.Allocator,
    layer: u8,
    path: []const [2]f64,
) std.mem.Allocator.Error!cdt_layers.Route {
    const legs = try arena.alloc(cdt_layers.Leg, 1);
    legs[0] = .{ .layer = layer, .path = path };
    return .{ .legs = legs, .vias = &.{} };
}

// spec: placement/diff-shape - a mesh channel is transcribed into a pair centreline run for run, point for point, and via for via
test "a single-layer mesh route becomes a one-run centreline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = [_][2]f64{ .{ 1.0, 2.0 }, .{ 3.0, 2.0 }, .{ 3.0, 5.0 } };
    const center = (try centerlineOf(arena, try meshRoute(arena, 1, &path))) orelse
        return error.TestNoCenterline;
    try testing.expectEqual(@as(usize, 1), center.runs.len);
    try testing.expectEqual(@as(usize, 0), center.vias.len);
    try testing.expectEqual(@as(u8, 1), center.runs[0].layer);
    try testing.expectEqual(@as(usize, 3), center.runs[0].pts.len);
    try testing.expectEqual(@as(f64, 3.0), center.runs[0].pts[2].x);
    try testing.expectEqual(@as(f64, 5.0), center.runs[0].pts[2].y);
}

// spec: placement/diff-shape - a mesh channel that changes layers carries one centreline via per layer change, at the site the mesh dived through
test "a two-layer mesh route becomes two runs joined by its via" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top = [_][2]f64{ .{ 0.0, 0.0 }, .{ 4.0, 0.0 } };
    const bottom = [_][2]f64{ .{ 4.0, 0.0 }, .{ 8.0, 0.0 } };
    const legs = try arena.alloc(cdt_layers.Leg, 2);
    legs[0] = .{ .layer = 0, .path = &top };
    legs[1] = .{ .layer = 1, .path = &bottom };
    const sites = try arena.alloc(cdt_layers.ViaSite, 1);
    sites[0] = .{ .x = 4.0, .y = 0.0 };
    const center = (try centerlineOf(arena, .{ .legs = legs, .vias = sites })) orelse
        return error.TestNoCenterline;
    try testing.expectEqual(@as(usize, 2), center.runs.len);
    try testing.expectEqual(@as(usize, 1), center.vias.len);
    try testing.expectEqual(@as(u8, 1), center.runs[1].layer);
    try testing.expectEqual(@as(f64, 4.0), center.vias[0].x);
}

// spec: placement/diff-shape - a degenerate mesh answer yields no centreline at all rather than a run the leg construction cannot use
test "an empty or single-point mesh route yields no centreline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try centerlineOf(arena, .{ .legs = &.{}, .vias = &.{} })) == null);
    const stub = [_][2]f64{.{ 1.0, 1.0 }};
    try testing.expect((try centerlineOf(arena, try meshRoute(arena, 0, &stub))) == null);
}

// spec: placement/diff-shape - a mesh answer that is not N runs joined by N-1 vias is refused, because the leg construction reads the run past every via
test "a mesh route with a via and no run past it yields no centreline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `cdt_layers.extract` appends a via unconditionally and drops a leg whose
    // funnel yields no polyline, so this shape is reachable — and `shiftVia`
    // reads `runs[i + 1]` for via `i`, which would index past the end.
    const path = [_][2]f64{ .{ 0.0, 0.0 }, .{ 4.0, 0.0 } };
    var trailing = try meshRoute(arena, 0, &path);
    const sites = try arena.alloc(cdt_layers.ViaSite, 1);
    sites[0] = .{ .x = 4.0, .y = 0.0 };
    trailing.vias = sites;
    try testing.expect((try centerlineOf(arena, trailing)) == null);
    // The well-formed shape of the same length still transcribes.
    trailing.vias = &.{};
    try testing.expect((try centerlineOf(arena, trailing)) != null);
}

// spec: placement/diff-shape - the pair envelope search asks the mesh for a channel two widths and one intra-pair gap across, not for a single trace's
test "the envelope width is both legs plus the class gap" {
    // The one substitution `envelopeCenterline` makes on `router.shapeInput`'s
    // model, spelled the same way `diff_couple.routeEnvelope` spells it for the
    // maze — so the two searches can never ask for different corridors.
    const width: f64 = 0.15;
    const pair = diff_pairs.DiffPair{ .p = 0, .n = 1, .gap = 0.2 };
    try testing.expectEqual(@as(f64, 0.5), 2 * width + pair.gap);
}

/// A declared pair whose two ends face each other across a solid wall of foreign
/// pads: no channel at any width, on any layer, for either search.
fn walledPairFixture(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = try arena.alloc(optimizer.Part, 4);
    const at = [4][2]f64{ .{ 1, 2 }, .{ 9, 2 }, .{ 1, 2.6 }, .{ 9, 2.6 } };
    const refs = [4][]const u8{ "R1", "R2", "R3", "R4" };
    for (parts, refs, at) |*part, ref, xy| part.* = .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = xy[0],
        .y = xy[1],
    };
    const pins_p = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_n = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const nets = try arena.alloc(flat_netlist.FlatNet, 2);
    nets[0] = .{ .name = "D_P", .pins = &pins_p };
    nets[1] = .{ .name = "D_N", .pins = &pins_n };
    const pairs = try arena.alloc(diff_pairs.DiffPair, 1);
    pairs[0] = .{ .p = 0, .n = 1, .gap = 0.127 };
    // The wall: one THROUGH-HOLE pad per 0.5 mm of board height, each on its own
    // net, so no route of any width crosses the middle of the board — and none
    // dives under it either, which is what makes the mesh's answer a wall rather
    // than a channel on the far layer.
    const wall_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4, .thru = true, .drill = 0.2 }};
    const wall = try arena.alloc(optimizer.Part, 12);
    for (wall, 0..) |*part, i| part.* = .{
        .ref_des = "W",
        .kind = .passive,
        .hw = 0.25,
        .hh = 0.25,
        .pads = &wall_pad,
        .fallback = false,
        .x = 5,
        .y = @as(f64, @floatFromInt(i)) * 0.5,
    };
    const all = try arena.alloc(optimizer.Part, parts.len + wall.len);
    @memcpy(all[0..parts.len], parts);
    @memcpy(all[parts.len..], wall);
    return .{
        .parts = all,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = true,
        .diff_pairs = pairs,
    };
}

// spec: placement/diff-shape - a pair the mesh cannot channel either leaves the board exactly as the maze left it, so the tier can never buy copper by relaxing a rule
test "a walled pair refuses the mesh channel and lands the same copper either way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledPairFixture(arena);
    const maze = try router.routeWithOptions(arena, placement, .{}, .{});
    var meshed = route_policy.Options{};
    meshed.guides.pair_channel = .mesh_behind_maze;
    const both = try router.routeWithOptions(arena, placement, .{}, meshed);
    // The tier ran (its verdict line names the pair) and found nothing, so the
    // board is what the lattice alone produced — track for track, via for via.
    try testing.expectEqual(maze.tracks.len, both.tracks.len);
    try testing.expectEqual(maze.vias.len, both.vias.len);
    try testing.expectEqual(maze.routed, both.routed);
    try testing.expectEqual(maze.total, both.total);
    for (maze.tracks, both.tracks) |a, b| {
        try testing.expectEqual(a.x1, b.x1);
        try testing.expectEqual(a.y1, b.y1);
        try testing.expectEqual(a.x2, b.x2);
        try testing.expectEqual(a.y2, b.y2);
        try testing.expectEqual(a.layer, b.layer);
        try testing.expectEqual(a.net, b.net);
    }
}

// spec: placement/diff-shape - the pair envelope search launches from the same two far escape points the coupled maze search does
test "the mesh terminals are the pair's own far escape points" {
    const ends = diff_route.Ends{
        .far = .{ .{ .x = 1.5, .y = 2.5, .layer = 0 }, .{ .x = 9.5, .y = 2.5, .layer = 1 } },
        .mid = .{ .{ .x = 1.0, .y = 2.5, .layer = 0 }, .{ .x = 10.0, .y = 2.5, .layer = 1 } },
        .seq = .{ &.{}, &.{} },
    };
    const pts = envelopeTerminals(ends);
    try testing.expectEqual(@as(f64, 1.5), pts[0].x);
    try testing.expectEqual(@as(u8, 0), pts[0].layer);
    try testing.expectEqual(@as(f64, 9.5), pts[1].x);
    try testing.expectEqual(@as(u8, 1), pts[1].layer);
}

// spec: placement/diff-shape - the pair envelope search reports the wall that stopped it and records it for a caller holding rip authority, instead of only reporting that it found nothing
test "a walled pair records the wall its envelope could not pass" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledPairFixture(arena);
    var log = route_policy.PinchLog{};
    var meshed = route_policy.Options{};
    meshed.guides.pair_channel = .mesh_behind_maze;
    meshed.guides.pinch = &log;
    _ = try router.routeWithOptions(arena, placement, .{}, meshed);

    // The tier ran, found no channel, and said WHY: a wall with a measurement
    // against it, rather than the bare "no envelope channel in the mesh either".
    try testing.expect(log.reports().len > 0);
    const report = log.reports()[0];
    try testing.expect(report.need_mm > 0);
    try testing.expect(report.have_mm < report.need_mm);
    // It names the pair it was searching for, both legs.
    try testing.expect(report.pair[0] >= 0 and report.pair[1] >= 0);
    try testing.expect(report.pair[0] != report.pair[1]);
}
