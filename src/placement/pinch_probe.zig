//! What walls a net — or a coupled pair's envelope — at THIS PLACEMENT, asked
//! standalone.
//!
//! The router already knows how to name a wall: `cdt_layers.routeDiagnosed`
//! triangulates the free space at the width a channel needs and, when no channel
//! exists, walks its own walls to the narrowest cut between the two terminals
//! and the copper that owns each side of it. `diff_couple` uses that to explain
//! a coupled pair's decline, and `route_plan`'s unblock phase turns the answer
//! into a rip nomination.
//!
//! Both of those are inside a ROUTE — a live `Ctx`, a live transaction, a live
//! rip authority — and that is the wrong shape for the question a placement
//! repair asks. "Which two bodies leave this net no room?" is a fact about where
//! the PARTS are, and it has to be answerable before any copper exists and
//! without permission to tear any up. So this module asks it over the placement
//! alone.
//!
//! Two properties make that honest rather than merely cheaper:
//!
//! * **The model is a SUBSET of the router's.** Pads always
//!   (`router.buildObstacles`), plus whatever copper the caller hands over, and
//!   nothing else — no halos, no keepouts, no via sites. Every richer model the
//!   router builds only ADDS obstacles, so a wall this probe finds is a wall in
//!   all of them: two bodies really are that far apart and the channel really
//!   does need more. The converse is not claimed and is not needed — a probe
//!   that finds a channel reports no pinch and the caller does nothing.
//! * **One layer, no dives.** A pad lives on one face, a pad-owned pinch is a
//!   fact about that face, and a placement move cannot conjure a layer change.
//!   The search is therefore run on the terminals' own signal layer with no via
//!   sites, which is a STRICTER search than the router's — so "pinched" here
//!   never means "the router has no route", only "this face has no channel".
//!   Whether widening it helps is settled by re-routing, never asserted here.
//!
//! Pure geometry over an arena: no clock, no RNG, no mutation of the placement
//! it is handed, and nothing here emits copper or moves a part.

const std = @import("std");
const cdt = @import("cdt_route.zig");
const cdt_layers = @import("cdt_layers.zig");
const fine_window = @import("fine_window.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const diff_pairs = @import("diff_pairs.zig");

/// How far outside the two terminals the search window reaches, so a channel
/// that bows around an obstacle is inside the window rather than cut off by it.
const probe_window_mm: f64 = 8.0;

/// One side of a wall: the copper class that owns it, its net, and — when it is
/// a PAD — the placed part that carries it.
///
/// The part index is the whole point of this module. `pair_pinch.Report` names
/// the two sides by NET, which is the handle a rip takes; a placement move needs
/// the handle a pose takes, and only a pad has one.
pub const Owner = struct {
    kind: cdt.OwnerKind,
    /// Flattened net index, or `-1` for a keepout / the board-edge band.
    net: i32 = -1,
    /// Index into `placement.parts` when `kind == .pad`; null otherwise.
    part: ?usize = null,
    /// The owning body's own centre (world mm) when this side is a PAD — the
    /// one point a widening axis can be measured from. A wall's crossing point
    /// sits BETWEEN the two bodies and is the same for both, so it cannot say
    /// which way either of them would have to go.
    center: [2]f64 = .{ 0, 0 },
};

/// The narrowest wall between a probe's two terminals: who is on each side, how
/// much room there actually is, and how much the channel needed.
///
/// `b` is null where a single body spans the wall alone — there is no gap
/// between two things to widen, which is a different (and unrepairable) finding
/// from "these two are too close".
pub const Pinch = struct {
    a: Owner,
    b: ?Owner = null,
    /// Where on the board the wall stands (world mm).
    at: [2]f64,
    layer: u8,
    have_mm: f64,
    need_mm: f64,

    /// The shortfall a move has to make up: how much wider this wall must get
    /// before the channel fits. Zero when the wall already has the room (which
    /// a pinch never does) so callers can add their own margin unconditionally.
    pub fn shortfallMm(self: Pinch) f64 {
        return @max(self.need_mm - self.have_mm, 0);
    }
};

/// `skip_net` for a probe with no routing net of its own: every pad is foreign.
///
/// Deliberately NOT `-1`. The router spells an UNNETTED pad `-1`, and the mesh
/// skips an obstacle whose net EQUALS `skip_net` — so `-1` would make every
/// mounting hole, fiducial and unconnected land transparent, which is the exact
/// opposite of "there is no net to skip". A value no pad can carry is the only
/// honest spelling.
pub const skip_nothing: i32 = -2;

/// A probe's two terminals and the face they sit on.
pub const Ends = struct { from: [2]f64, to: [2]f64, layer: u8 = 0 };

/// One question for the placement: which net's pads are transparent, which two
/// points the channel has to join, on which face, and how wide it has to be.
pub const Ask = struct {
    /// The net being routed — its own pads are not obstacles to itself. The
    /// default (`skip_nothing`) makes every pad foreign.
    skip_net: i32 = skip_nothing,
    ends: Ends,
    /// The copper profile the channel must hold: one track's width, or a
    /// coupled pair's whole envelope (`2·width + gap`).
    width: f64,
    clearance: f64,
    /// Copper already on the board, if the caller has any. Empty (the default)
    /// asks the pure PLACEMENT question — is there a channel through the pads
    /// alone. A caller that has just routed passes what it laid, and the answer
    /// narrows to "given how the board actually came out"; either way the
    /// routing net's own copper is transparent to itself through `skip_net`,
    /// and either way a wall that is found is a wall between two real bodies.
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
};

/// Ask the placement what walls this channel. Null when a channel exists at all
/// (nothing to repair) and null when the geometry could not name an owner —
/// a wall owned by the search window's own hull is a fact about the window, not
/// about the board.
pub fn probe(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    ask: Ask,
) std.mem.Allocator.Error!?Pinch {
    if (ask.width <= 0) return null;
    const pads = try router.buildObstacles(arena, placement.parts, placement.nets);
    const layers = try arena.alloc(cdt_layers.Layer, 1);
    layers[0] = .{ .index = ask.ends.layer, .cost = 1.0 };
    const found = try cdt_layers.routeDiagnosed(arena, .{
        .field = .{
            .rect = windowOf(ask.ends),
            .layer = ask.ends.layer,
            .obstacles = .{
                .pads = pads,
                .tracks = ask.tracks,
                .vias = ask.vias,
                .skip_net = ask.skip_net,
            },
            .track_width = ask.width,
            .clearance = ask.clearance,
        },
        .layers = layers,
        .start = .{ .at = ask.ends.from, .layer = ask.ends.layer },
        .goal = .{ .at = ask.ends.to, .layer = ask.ends.layer },
        .via_sites = &.{},
        .via_cost_mm = 0,
    });
    if (found.route != null) return null;
    const wall = found.pinch orelse return null;
    return .{
        .a = ownerOf(placement, pads, wall.a),
        .b = if (wall.b) |other| ownerOf(placement, pads, other) else null,
        .at = wall.at,
        .layer = wall.layer,
        .have_mm = wall.have_mm,
        .need_mm = wall.need_mm,
    };
}

/// The window one probe searches: the two terminals' bounding box, opened by a
/// fixed margin so a legal bow around an obstacle stays inside it.
fn windowOf(ends: Ends) fine_window.WindowRect {
    return .{
        .x0 = @min(ends.from[0], ends.to[0]) - probe_window_mm,
        .y0 = @min(ends.from[1], ends.to[1]) - probe_window_mm,
        .x1 = @max(ends.from[0], ends.to[0]) + probe_window_mm,
        .y1 = @max(ends.from[1], ends.to[1]) + probe_window_mm,
    };
}

/// Name one side of a wall, resolving a pad to the part that carries it and to
/// its own centre.
fn ownerOf(placement: optimizer.Placement, pads: []const router.PadObs, owner: cdt.Owner) Owner {
    if (owner.kind != .pad or owner.src >= pads.len) {
        return .{ .kind = owner.kind, .net = if (owner.kind == .keepout) -1 else owner.net };
    }
    const pad = pads[owner.src];
    return .{
        .kind = .pad,
        .net = owner.net,
        .part = padPart(placement, owner.src),
        .center = .{ (pad.x0 + pad.x1) / 2, (pad.y0 + pad.y1) / 2 },
    };
}

/// Which placed part carries obstacle `src`.
///
/// `router.buildObstacles` walks `placement.parts` in order and appends each
/// part's pads in order, so the obstacle index is a running pad count over the
/// same slice — deterministic, and derivable without the obstacle array carrying
/// a back-reference it has no other use for. Null when the index is past the
/// placement's own pads, which only a caller mixing two placements can produce.
pub fn padPart(placement: optimizer.Placement, src: u32) ?usize {
    var seen: u32 = 0;
    for (placement.parts, 0..) |part, i| {
        const n: u32 = @intCast(part.pads.len);
        if (src < seen + n) return i;
        seen += n;
    }
    return null;
}

/// The two ends a coupled pair's envelope has to join: the midpoints of the pad
/// pairs at its two EXTREMES, which is where the centreline the router
/// constructs from actually starts and stops.
///
/// A leg is rarely two bare pads. barracuda's `REF_LMX_P` is three — the
/// connector contact, a 100 Ω termination and an AC-coupling cap — and reading
/// "exactly two pads" as the precondition made the campaign's own keystone pair
/// vanish from the probe silently. What defines the envelope is the leg's SPAN,
/// so the two ends are its farthest-apart pads; the intermediate pads sit on the
/// run between them and are exactly the copper the envelope has to reach past.
///
/// Each end is then matched to the nearer pad of the twin, which is the pairing
/// the pad fan makes. A leg with fewer than two pads has no span at all and
/// comes back null rather than as a guess.
pub fn pairEnds(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    pair: diff_pairs.DiffPair,
) std.mem.Allocator.Error!?Ends {
    const pads = try router.buildObstacles(arena, placement.parts, placement.nets);
    const p_all = try padCenters(arena, pads, @intCast(pair.p));
    const n_all = try padCenters(arena, pads, @intCast(pair.n));
    if (p_all.len < 2 or n_all.len < 2) return null;
    const p = span(p_all);
    const n = span(n_all);
    // Match each P end to the N pad it shares an end with — the nearer of the
    // two, which is the same pairing the pad fan makes.
    const straight = dist(p[0], n[0]) + dist(p[1], n[1]);
    const crossed = dist(p[0], n[1]) + dist(p[1], n[0]);
    const mate: [2]usize = if (straight <= crossed) .{ 0, 1 } else .{ 1, 0 };
    return .{
        .from = mid(p[0], n[mate[0]]),
        .to = mid(p[1], n[mate[1]]),
        .layer = pads[0].layer,
    };
}

/// The two farthest-apart points of a leg — its span. Ties break on the earlier
/// index pair, so the answer is the same on every run.
fn span(pts: []const [2]f64) [2][2]f64 {
    var best: [2][2]f64 = .{ pts[0], pts[1] };
    var best_d = dist(pts[0], pts[1]);
    for (pts, 0..) |a, i| {
        for (pts[i + 1 ..]) |b| {
            const d = dist(a, b);
            if (d > best_d) {
                best_d = d;
                best = .{ a, b };
            }
        }
    }
    return best;
}

/// Every pad centre carrying `net`, in obstacle order.
fn padCenters(
    arena: std.mem.Allocator,
    pads: []const router.PadObs,
    net: i32,
) std.mem.Allocator.Error![][2]f64 {
    var out: std.ArrayList([2]f64) = .empty;
    for (pads) |pad| {
        if (pad.net != net) continue;
        try out.append(arena, .{ (pad.x0 + pad.x1) / 2, (pad.y0 + pad.y1) / 2 });
    }
    return out.toOwnedSlice(arena);
}

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn mid(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");

test {
    testing.refAllDecls(@This());
}

/// A placement of `parts` with the nets they carry, sized to their own extent.
fn fixture(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -20,
        .miny = -20,
        .maxx = 20,
        .maxy = 20,
        .generated = true,
    };
}

/// One square pad of `half` mm half-extent at the footprint origin.
fn onePadPart(ref: []const u8, x: f64, y: f64, half: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = half,
        .hh = half,
        .pads = pads,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

// spec: placement/pinch-probe - a pad obstacle index resolves to the placed part carrying it, by the running pad count `buildObstacles` itself walks
test "an obstacle index names the part whose pad it is" {
    const pads_a = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 1, .y = 0, .w = 0.5, .h = 0.5 },
    };
    const pads_b = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        onePadPart("R1", 0, 0, 1, &pads_a),
        onePadPart("R2", 5, 0, 1, &pads_b),
    };
    const p = fixture(&parts, &.{});
    try testing.expectEqual(@as(?usize, 0), padPart(p, 0));
    try testing.expectEqual(@as(?usize, 0), padPart(p, 1));
    try testing.expectEqual(@as(?usize, 1), padPart(p, 2));
    // Past the placement's own pads there is no part to name.
    try testing.expectEqual(@as(?usize, null), padPart(p, 3));
}

// spec: placement/pinch-probe - a channel with room reports no pinch at all, so a caller only ever acts on geometry that is genuinely short
test "an open channel is not a pinch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        onePadPart("R1", 0, -6, 1, &pads),
        onePadPart("R2", 0, 6, 1, &pads),
    };
    const p = fixture(&parts, &.{});
    const pinch = try probe(arena_state.allocator(), p, .{
        .ends = .{ .from = .{ -8, 0 }, .to = .{ 8, 0 } },
        .width = 0.15,
        .clearance = 0.15,
    });
    try testing.expect(pinch == null);
}

// spec: placement/pinch-probe - a channel walled by two pads names both parts, the room it has and the room it needs, and the shortfall between them
test "two pads too close to pass between name both parts and the shortfall" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Two 1 mm-wide pads leaving a 0.1 mm slot, walled top and bottom so the
    // only way across is between them.
    const wide = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 8.0 }};
    var parts = [_]optimizer.Part{
        onePadPart("R1", 0, -4.05, 4, &wide),
        onePadPart("R2", 0, 4.05, 4, &wide),
    };
    const p = fixture(&parts, &.{});
    const pinch = (try probe(arena_state.allocator(), p, .{
        .ends = .{ .from = .{ -6, 0 }, .to = .{ 6, 0 } },
        .width = 0.2,
        .clearance = 0.2,
    })) orelse return error.TestNoPinch;
    try testing.expectEqual(cdt.OwnerKind.pad, pinch.a.kind);
    const other = pinch.b orelse return error.TestOneSidedWall;
    try testing.expectEqual(cdt.OwnerKind.pad, other.kind);
    // Both sides are named as PARTS, which is the handle a move takes.
    const parts_named = [2]?usize{ pinch.a.part, other.part };
    try testing.expect(parts_named[0] != null and parts_named[1] != null);
    try testing.expect(parts_named[0].? != parts_named[1].?);
    // The channel needs a track plus a clearance either side, and has less.
    try testing.expectApproxEqAbs(@as(f64, 0.6), pinch.need_mm, 1e-9);
    try testing.expect(pinch.have_mm < pinch.need_mm);
    try testing.expect(pinch.shortfallMm() > 0);
}

// spec: placement/pinch-probe - a coupled pair's probe terminals are the midpoints of the pad pairs at its two extremes, so a leg carrying a termination or a coupling cap still has an envelope, and a leg with fewer than two pads has none
test "a pair's ends are the midpoints of its span's matched pad pairs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const one = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        onePadPart("U1", 0, 0, 1, &one), // P, left end
        onePadPart("U2", 10, 0, 1, &one), // P, right end
        onePadPart("U3", 0, 2, 1, &one), // N, left end
        onePadPart("U4", 10, 2, 1, &one), // N, right end
    };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "D_P", .pins = &.{
            .{ .ref_des = "U1", .pin = "1" },
            .{ .ref_des = "U2", .pin = "1" },
        } },
        .{ .name = "D_N", .pins = &.{
            .{ .ref_des = "U3", .pin = "1" },
            .{ .ref_des = "U4", .pin = "1" },
        } },
    };
    const p = fixture(&parts, &nets);
    const ends = (try pairEnds(arena, p, .{ .p = 0, .n = 1, .gap = 0.2 })) orelse
        return error.TestNoEnds;
    try testing.expectApproxEqAbs(@as(f64, 0), ends.from[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), ends.from[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), ends.to[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), ends.to[1], 1e-9);

    // A leg on one pad is not an envelope: there is no second end to aim at.
    const lopsided = [_]optimizer.FlatNet{
        nets[0],
        .{ .name = "D_N", .pins = &.{.{ .ref_des = "U3", .pin = "1" }} },
    };
    const q = fixture(&parts, &lopsided);
    try testing.expect((try pairEnds(arena, q, .{ .p = 0, .n = 1, .gap = 0.2 })) == null);

    // A THREE-pad leg — connector contact, termination, coupling cap, which is
    // what a real LVDS reference looks like — still has a span, and the ends are
    // its extremes rather than whichever two pads happened to be declared first.
    var wide_parts = [_]optimizer.Part{
        onePadPart("U1", 0, 0, 1, &one),
        onePadPart("R9", 5, 0, 1, &one), // a termination midway along P
        onePadPart("U2", 10, 0, 1, &one),
        onePadPart("U3", 0, 2, 1, &one),
        onePadPart("U4", 10, 2, 1, &one),
    };
    const three = [_]optimizer.FlatNet{
        .{ .name = "D_P", .pins = &.{
            .{ .ref_des = "U1", .pin = "1" },
            .{ .ref_des = "R9", .pin = "1" },
            .{ .ref_des = "U2", .pin = "1" },
        } },
        .{ .name = "D_N", .pins = &.{
            .{ .ref_des = "U3", .pin = "1" },
            .{ .ref_des = "U4", .pin = "1" },
        } },
    };
    const r = fixture(&wide_parts, &three);
    const wide_ends = (try pairEnds(arena, r, .{ .p = 0, .n = 1, .gap = 0.2 })) orelse
        return error.TestNoEnds;
    try testing.expectApproxEqAbs(@as(f64, 0), wide_ends.from[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), wide_ends.to[0], 1e-9);
}

// spec: placement/pinch-probe - a probe with no routing net of its own makes every pad foreign, including the unnetted lands the router itself spells -1
test "the no-net sentinel is not the router's own unnetted spelling" {
    // `cdt_route` skips an obstacle whose net EQUALS `skip_net`, and an unnetted
    // pad carries -1 — so a default of -1 would quietly delete every mounting
    // hole and fiducial from the model this probe claims is a subset of the
    // router's.
    try testing.expect(skip_nothing != -1);
    try testing.expectEqual(skip_nothing, (Ask{ .ends = .{ .from = .{ 0, 0 }, .to = .{ 1, 0 } }, .width = 0.1, .clearance = 0.1 }).skip_net);
}

// spec: placement/pinch-probe - a probe asked for no width at all answers nothing rather than triangulating a channel with no meaning
test "a zero-width probe is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parts = [_]optimizer.Part{};
    const p = fixture(&parts, &.{});
    try testing.expect((try probe(arena_state.allocator(), p, .{
        .ends = .{ .from = .{ 0, 0 }, .to = .{ 1, 0 } },
        .width = 0,
        .clearance = 0.15,
    })) == null);
}
