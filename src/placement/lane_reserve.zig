//! Authored lane reservations: copper corridors one net owns for a whole
//! routing run.
//!
//! `(assign-escapes …)` already gives a contended escape fan one lane per net,
//! but it hands the router SOFT guides (`route_policy.GuideTrack`): a cost bonus
//! biasing the maze toward the lane, which a later net is free to ignore and
//! route straight across. That is deliberate — a guide can never fail a net —
//! and it is also why an assignment does not survive contact with the nets that
//! route after it. `(assign-escapes … (reserve))` is the hard half: the same
//! lane geometry, stamped as a claim only its owner may cross.
//!
//! ## Why `router.Ctx.resv` is the mechanism
//!
//! `resv` already means exactly this and nothing else. `router.blocked` refuses
//! a `resv` cell to a net purely on net-id mismatch — no clearance arithmetic,
//! no halo semantics — and Dijkstra never SEEDS from one, so a reservation is a
//! wall to strangers without becoming phantom copper its owner can "connect" to.
//! (That last property is why the 45° corner reservations live there, and it is
//! what an authored lane needs too: reserving a corridor must not let the owner
//! finish a net by touching the reservation.)
//!
//! ## Contested cells go to NOBODY
//!
//! Two lanes of DIFFERENT nets can both cover a node — the assignment's lane
//! pitch may be finer than the routing raster, and then two lanes simply are the
//! same node. First-writer-wins would answer that by locking the second net out
//! of its own assigned lane, which is the one outcome a reservation must never
//! produce: it would make a wave member's own escape plan the thing blocking it.
//! So a node claimed by two different nets is left EMPTY — free to everyone,
//! exactly as it was before the form was authored. The reservation therefore
//! degrades to "no effect" under a raster too coarse to express it, never to a
//! wrong effect, and the result does not depend on lane order.
//!
//! ## What is never touched
//!
//! A cell already carrying something (copper's own reservation halo, a via's
//! clearance ring, a diagonal corner) is left alone. A reservation only ever
//! claims free space, so stamping one can never relax an existing exclusion.

const std = @import("std");
const route_policy = @import("route_policy.zig");
const router = @import("router.zig");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

const sqrt2: f64 = std.math.sqrt2;

/// Half-width (mm) a lane claims around its centreline.
///
/// Floored at the raster's half-diagonal so a lane thinner than the grid still
/// claims the nodes its centreline runs through instead of rounding away to
/// nothing: every point lies within `g·√2/2` of some node, so this floor claims
/// at least one node per sample and a zero-width lane is exactly "the raster
/// nodes under the centreline".
pub fn radiusOf(lane: route_policy.ReservedLane, grid: router.Grid) f64 {
    return @max(lane.width * 0.5, grid.g * (sqrt2 / 2));
}

/// Stamp `lanes` into the per-signal-layer reservation grids `resv`.
///
/// `only_net` restricts the pass to one owner — what `router.clearNetOcc` needs,
/// since wiping a net's copper also wipes the cells its authored lane held and
/// the claim has to be re-asserted (the same reason pad keepout halos are
/// restamped there). Null stamps every lane.
///
/// Idempotent: a cell this pass would write is one that is currently empty, and
/// re-running writes the same value. Deterministic and order-independent — see
/// the contested rule in the header.
pub fn stamp(
    lanes: []const route_policy.ReservedLane,
    resv: []const []i32,
    grid: router.Grid,
    only_net: ?i32,
) void {
    if (lanes.len == 0) return;
    for (lanes) |lane| {
        if (only_net) |n| if (lane.net != n) continue;
        if (lane.layer >= resv.len) continue;
        stampOne(lanes, lane, resv[lane.layer], grid);
    }
}

/// Claim one lane's free cells. Sampling at half-pitch makes an
/// arbitrary-angle centreline a continuous claim on the raster, the same rule
/// `router.stampExistingCopper` rasters a track by.
fn stampOne(
    all: []const route_policy.ReservedLane,
    lane: route_policy.ReservedLane,
    layer: []i32,
    grid: router.Grid,
) void {
    const dist = radiusOf(lane, grid);
    const len = std.math.hypot(lane.x2 - lane.x1, lane.y2 - lane.y1);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (grid.g * 0.5))));
    for (0..steps + 1) |s| {
        const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
        claimDisc(all, lane, layer, grid, .{
            lane.x1 + t * (lane.x2 - lane.x1),
            lane.y1 + t * (lane.y2 - lane.y1),
        }, dist);
    }
}

/// Claim every free node within `dist` of world point `at` for `lane.net`,
/// skipping any node a lane of a different net also covers.
fn claimDisc(
    all: []const route_policy.ReservedLane,
    lane: route_policy.ReservedLane,
    layer: []i32,
    grid: router.Grid,
    at: [2]f64,
    dist: f64,
) void {
    const radius: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse return;
    const center = grid.nearest(at[0], at[1]);
    var dy: i64 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i64 = -radius;
        while (dx <= radius) : (dx += 1) {
            const ix = @as(i64, @intCast(center[0])) + dx;
            const iy = @as(i64, @intCast(center[1])) + dy;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            if (std.math.hypot(wx - at[0], wy - at[1]) > dist) continue;
            const node = grid.node(@intCast(ix), @intCast(iy));
            if (layer[node] != router.empty_cell) continue;
            if (contested(all, lane, grid, .{ wx, wy })) continue;
            layer[node] = lane.net;
        }
    }
}

/// True when a lane of a DIFFERENT net on the same layer also covers world
/// point `at` — the node then belongs to nobody (see the header).
fn contested(
    all: []const route_policy.ReservedLane,
    lane: route_policy.ReservedLane,
    grid: router.Grid,
    at: [2]f64,
) bool {
    for (all) |other| {
        if (other.net == lane.net or other.layer != lane.layer) continue;
        if (segDist(other, at) <= radiusOf(other, grid)) return true;
    }
    return false;
}

// ── The direct-synthesis half ───────────────────────────────────────────────
//
// Stamping `resv` binds the MAZE, and the maze is not the only thing that draws
// copper. `router.tryDirectPair` and its relatives synthesize a straight/dogleg
// run between two terminals and check it against pads, tracks, vias, zones and
// the outline — never against `resv`, because until now `resv` only ever held
// cells the maze had already refused to route through. An authored lane is the
// first thing in there the maze did not put there itself, so without these two
// predicates the reservation is skipped outright for any net a direct run can
// serve — which is exactly the short axis-aligned net it matters most for.
// (Measured while building this: a two-net fixture whose excluded net is
// collinear with the reserved channel routed straight through it, 14 stamped
// cells and all.)
//
// The question is asked in WORLD space rather than by sampling `resv`, because
// a direct run is off-grid by construction. It is the SAME question the node
// test asks — is this track centreline inside a foreign lane — so the two agree
// by construction rather than by raster luck.

/// True when the centreline `a`→`b` on `layer` enters a lane reserved for a net
/// other than `net`.
pub fn segmentBlocked(
    lanes: []const route_policy.ReservedLane,
    grid: router.Grid,
    layer: u8,
    net: i32,
    a: [2]f64,
    b: [2]f64,
) bool {
    for (lanes) |lane| {
        if (lane.net == net or lane.layer != layer) continue;
        const to = [2]f64{ lane.x2, lane.y2 };
        if (pad_shape.segSegDist(a, b, .{ lane.x1, lane.y1 }, to) <= radiusOf(lane, grid)) return true;
    }
    return false;
}

/// True when a through via at `at` sits inside a lane reserved for another net
/// on ANY layer — a barrel crosses them all, so one foreign lane refuses it.
pub fn viaBlocked(
    lanes: []const route_policy.ReservedLane,
    grid: router.Grid,
    net: i32,
    at: [2]f64,
) bool {
    for (lanes) |lane| {
        if (lane.net == net) continue;
        if (segDist(lane, at) <= radiusOf(lane, grid)) return true;
    }
    return false;
}

/// Distance (mm) from `at` to a lane's centreline segment.
fn segDist(lane: route_policy.ReservedLane, at: [2]f64) f64 {
    const dx = lane.x2 - lane.x1;
    const dy = lane.y2 - lane.y1;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 0) return std.math.hypot(at[0] - lane.x1, at[1] - lane.y1);
    const raw = ((at[0] - lane.x1) * dx + (at[1] - lane.y1) * dy) / len2;
    const t = std.math.clamp(raw, 0, 1);
    return std.math.hypot(at[0] - (lane.x1 + t * dx), at[1] - (lane.y1 + t * dy));
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A 21x21 raster at 0.5 mm pitch with one signal layer, plus its grid.
const Fixture = struct {
    grid: router.Grid,
    resv: [][]i32,

    fn deinit(self: Fixture, alloc: std.mem.Allocator) void {
        for (self.resv) |l| alloc.free(l);
        alloc.free(self.resv);
    }
};

fn fixture(alloc: std.mem.Allocator) std.mem.Allocator.Error!Fixture {
    const grid = router.Grid{ .ox = 0, .oy = 0, .g = 0.5, .nx = 21, .ny = 21 };
    const layers = try alloc.alloc([]i32, 1);
    layers[0] = try alloc.alloc(i32, grid.nx * grid.ny);
    @memset(layers[0], router.empty_cell);
    return .{ .grid = grid, .resv = layers };
}

/// What `router.clearNetOcc` does to `resv` when a net is ripped: every cell it
/// owned goes back to empty, authored lane included.
fn clearNet(resv: []const []i32, net: i32) void {
    for (resv) |l| for (l) |*c| {
        if (c.* == net) c.* = router.empty_cell;
    };
}

fn claimedBy(resv: []const []i32, net: i32) usize {
    var n: usize = 0;
    for (resv) |l| for (l) |c| {
        if (c == net) n += 1;
    };
    return n;
}

// spec: placement/reserved-lanes - an authored reserved lane claims its own corridor cells for its owning net and leaves every other cell free
test "a reserved lane claims its corridor for its owner" {
    const alloc = testing.allocator;
    const f = try fixture(alloc);
    defer f.deinit(alloc);

    const lanes = [_]route_policy.ReservedLane{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .net = 7, .width = 0.6 },
    };
    stamp(&lanes, f.resv, f.grid, null);

    // The centreline row is the owner's.
    try testing.expectEqual(@as(i32, 7), f.resv[0][f.grid.node(8, 10)]);
    // A cell a whole millimetre off the lane is untouched.
    try testing.expectEqual(router.empty_cell, f.resv[0][f.grid.node(8, 14)]);
    try testing.expect(claimedBy(f.resv, 7) > 0);
}

// spec: placement/reserved-lanes - stamping reserved lanes never overwrites a cell that already carries a reservation
test "a reserved lane never overwrites an existing reservation" {
    const alloc = testing.allocator;
    const f = try fixture(alloc);
    defer f.deinit(alloc);

    const taken = f.grid.node(8, 10);
    f.resv[0][taken] = 3; // some other net's copper halo already holds it
    const lanes = [_]route_policy.ReservedLane{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .net = 7, .width = 0.6 },
    };
    stamp(&lanes, f.resv, f.grid, null);
    try testing.expectEqual(@as(i32, 3), f.resv[0][taken]);
}

// spec: placement/reserved-lanes - a cell two different nets' reserved lanes both cover is left free rather than locking one of them out of its own lane
test "a cell two lanes contend for is left free" {
    const alloc = testing.allocator;
    const f = try fixture(alloc);
    defer f.deinit(alloc);

    // Two lanes 0.1 mm apart on a 0.5 mm raster: the grid cannot tell them
    // apart, so neither may claim the shared nodes.
    const lanes = [_]route_policy.ReservedLane{
        .{ .x1 = 2, .y1 = 5.0, .x2 = 8, .y2 = 5.0, .layer = 0, .net = 7 },
        .{ .x1 = 2, .y1 = 5.1, .x2 = 8, .y2 = 5.1, .layer = 0, .net = 9 },
    };
    stamp(&lanes, f.resv, f.grid, null);
    try testing.expectEqual(@as(usize, 0), claimedBy(f.resv, 7));
    try testing.expectEqual(@as(usize, 0), claimedBy(f.resv, 9));

    // Order cannot change that: the reverse list stamps identically.
    const reversed = [_]route_policy.ReservedLane{ lanes[1], lanes[0] };
    stamp(&reversed, f.resv, f.grid, null);
    try testing.expectEqual(@as(usize, 0), claimedBy(f.resv, 7));
    try testing.expectEqual(@as(usize, 0), claimedBy(f.resv, 9));
}

// spec: placement/reserved-lanes - re-stamping the reserved lanes of one net restores exactly that net's claim, so a rip-up that clears its cells cannot drop the reservation
test "a per-net re-stamp restores only that net's lane" {
    const alloc = testing.allocator;
    const f = try fixture(alloc);
    defer f.deinit(alloc);

    const lanes = [_]route_policy.ReservedLane{
        .{ .x1 = 2, .y1 = 3, .x2 = 8, .y2 = 3, .layer = 0, .net = 7 },
        .{ .x1 = 2, .y1 = 7, .x2 = 8, .y2 = 7, .layer = 0, .net = 9 },
    };
    stamp(&lanes, f.resv, f.grid, null);
    const seven = claimedBy(f.resv, 7);
    const nine = claimedBy(f.resv, 9);
    try testing.expect(seven > 0 and nine > 0);

    // A rip-up of net 7 clears every cell it owned — including its lane.
    clearNet(f.resv, 7);
    try testing.expectEqual(@as(usize, 0), claimedBy(f.resv, 7));

    stamp(&lanes, f.resv, f.grid, 7);
    try testing.expectEqual(seven, claimedBy(f.resv, 7));
    try testing.expectEqual(nine, claimedBy(f.resv, 9));
}

// spec: placement/reserved-lanes - a run that authors no reserved lane stamps nothing at all
test "no authored lane stamps nothing" {
    const alloc = testing.allocator;
    const f = try fixture(alloc);
    defer f.deinit(alloc);

    stamp(&.{}, f.resv, f.grid, null);
    for (f.resv[0]) |c| try testing.expectEqual(router.empty_cell, c);
}

// ── Whole-route integration ─────────────────────────────────────────────────

const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// The gap in the wall, as a world box. Anything crossing x = 2 at y ≈ 0 has
/// copper here; anything going the long way round has none.
const gap_box = [4]f64{ 1.4, -0.5, 2.6, 0.5 };

/// A board with TWO channels through one wall, 6 mm apart. Through-hole wall
/// pads block both signal layers, so a net shut out of a slot has to go round
/// to the other one rather than simply diving under.
///
/// Net 0 (`A`) runs at y = 0, dead in line with the LOW slot — and it is the
/// first net the router offers the board, so it takes that slot every time.
/// Net 1 (`B`) runs at y = 2, where the wall is solid, so it needs a slot too
/// and gets whatever net 0 left.
fn channelBoard(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const tall = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 14.0, .thru = true }};
    const mid = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 5.0, .thru = true }};
    const parts = try arena.alloc(optimizer.Part, 7);
    parts[0] = .{ .ref_des = "A1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.5, .y = 0 };
    parts[1] = .{ .ref_des = "A2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 3.5, .y = 0 };
    parts[2] = .{ .ref_des = "B1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.5, .y = -2 };
    parts[3] = .{ .ref_des = "B2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 3.5, .y = -2 };
    // Wall segments: above the HIGH slot, between the two slots, below the LOW
    // slot. What is left open is y in (-0.5, 0.5) and y in (5.5, 6.5).
    parts[4] = .{ .ref_des = "WT", .kind = .passive, .hw = 0.3, .hh = 7, .pads = &tall, .fallback = false, .x = 2, .y = 13.5 };
    parts[5] = .{ .ref_des = "WM", .kind = .passive, .hw = 0.3, .hh = 2.5, .pads = &mid, .fallback = false, .x = 2, .y = 3 };
    parts[6] = .{ .ref_des = "WB", .kind = .passive, .hw = 0.3, .hh = 7, .pads = &tall, .fallback = false, .x = 2, .y = -7.5 };
    const pins_a = try arena.alloc(flat_netlist.FlatPin, 2);
    pins_a[0] = .{ .ref_des = "A1", .pin = "1" };
    pins_a[1] = .{ .ref_des = "A2", .pin = "1" };
    const pins_b = try arena.alloc(flat_netlist.FlatPin, 2);
    pins_b[0] = .{ .ref_des = "B1", .pin = "1" };
    pins_b[1] = .{ .ref_des = "B2", .pin = "1" };
    const nets = try arena.alloc(flat_netlist.FlatNet, 2);
    nets[0] = .{ .name = "A", .pins = pins_a };
    nets[1] = .{ .name = "B", .pins = pins_b };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = -7,
        .maxx = 4,
        .maxy = 7,
        .generated = true,
    };
}

/// Does `net` have routed copper inside `box`? Sampled along each segment, so a
/// single long track that merely passes through still counts.
fn copperIn(tracks: []const router.Track, net: i32, box: [4]f64) bool {
    for (tracks) |t| {
        if (t.net != net) continue;
        const steps: usize = 64;
        for (0..steps + 1) |s| {
            const f = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
            const x = t.x1 + f * (t.x2 - t.x1);
            const y = t.y1 + f * (t.y2 - t.y1);
            if (x >= box[0] and x <= box[2] and y >= box[1] and y <= box[3]) return true;
        }
    }
    return false;
}

/// The lane that holds the channel for one net: the slot itself, wide enough to
/// cover both of the rows the raster offers there.
fn channelLane(net: i32) [1]route_policy.ReservedLane {
    return .{.{ .x1 = 1.4, .y1 = 0, .x2 = 2.6, .y2 = 0, .layer = 0, .net = net, .width = 1.0 }};
}

// spec: placement/reserved-lanes - an authored reserved lane holds its corridor for its owner against a net that routes earlier, which a soft guide cannot do
test "a reserved lane holds the channel for a net that has not routed yet" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = try channelBoard(arena);

    // Control: nothing reserved, so the low slot goes to whoever asks first —
    // net 0, which is collinear with it and routes before net 1 even sees it.
    const open = try router.routeWithOptions(arena, placement, .{}, .{});
    try testing.expectEqual(@as(usize, 2), open.routed);
    try testing.expect(copperIn(open.tracks, 0, gap_box));
    try testing.expect(!copperIn(open.tracks, 1, gap_box));

    // Hold it for net 1. Net 0's pads sit ON the channel's axis and it is the
    // first net offered the board, so this is exactly the case a soft guide
    // cannot express: by the time net 1 routes, net 0 has already taken the
    // channel. With the reservation net 0 goes round the wall instead, and both
    // nets still route.
    const lanes = channelLane(1);
    const held = try router.routeWithOptions(arena, placement, .{}, .{ .guides = .{ .reserved = &lanes } });
    try testing.expectEqual(@as(usize, 2), held.routed);
    try testing.expect(copperIn(held.tracks, 1, gap_box));
    try testing.expect(!copperIn(held.tracks, 0, gap_box));
}

// spec: placement/reserved-lanes - a reserved lane naming a layer the router does not model is skipped rather than mis-stamped
test "a lane on an unmodelled layer is skipped" {
    const alloc = testing.allocator;
    const f = try fixture(alloc);
    defer f.deinit(alloc);

    const lanes = [_]route_policy.ReservedLane{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 3, .net = 7 },
    };
    stamp(&lanes, f.resv, f.grid, null);
    try testing.expectEqual(@as(usize, 0), claimedBy(f.resv, 7));
}
