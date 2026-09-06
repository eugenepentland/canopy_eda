//! Where copper should leave a pad.
//!
//! A pad's anchor is its centre, and on a pad larger than the copper leaving it
//! that is an arbitrary choice the geometry may not support. Two measured cases
//! on board-a, each of which cost the board a net:
//!
//!   * `buck_6v/U22.3`, a 1.32 x 1.72 mm GND thermal pad. Its centre sits
//!     0.063 mm from the neighbouring FB pad against a 0.127 mm clearance, so
//!     EVERY stub leaving it was a violation before it went anywhere — while a
//!     site 0.66 mm lower in the same pad clears by 0.417 mm.
//!   * `lmx2595/U17.16`, mid-row on a 0.5 mm-pitch QFN edge. Nine of the row's
//!     ten pads had escaped; the survivor's only exit is its free tip, because
//!     the inter-pad lane is 0.200 mm against the 0.404 mm a track needs.
//!
//! The sampling primitives take their obstacle slice as `anytype` so they stay
//! plain geometry — they need `.x0 .y0 .x1 .y1 .poly .net` and nothing else,
//! which keeps them out of an import cycle with the router that owns those
//! records. The terminal helpers the router hands its own `ctx.obs` to name
//! `pad_grid.PadObs` outright, since that leaf module is where the record
//! already lives.

const std = @import("std");
const pad_shape = @import("pad_shape.zig");
const optimizer = @import("optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const pad_grid = @import("pad_grid.zig");
const route_result = @import("route_result.zig");

/// One drill a new barrel owes a hole-to-hole wall: centre, bore radius, and
/// the world half-vector to an oval slot's arc centres (`{0,0}` for a round
/// bore). The slot vector is carried because `drc.holePairViolation` measures a
/// wall as the CAPSULE distance — a generator that measured a slot as a circle
/// would under-reach the checker on exactly the pads (mounting slots,
/// board-to-board shells) whose bore is longest.
pub const Hole = struct { x: f64, y: f64, r: f64, shx: f64 = 0, shy: f64 = 0 };

/// The parts' through-pad drills alone, in world coordinates.
///
/// Split out from `boardHoles` because the router needs the pad half on its own:
/// via drills are already measured against the LIVE via list every probe carries,
/// while pad drills are fixed for the whole run and can be indexed once.
pub fn padHoles(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const Hole {
    var out: std.ArrayList(Hole) = .empty;
    for (placement.parts) |part| {
        for (part.pads) |pad| {
            if (pad.drill <= 0) continue;
            const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
            var shx: f64 = 0;
            var shy: f64 = 0;
            if (pad.isSlot()) {
                const e1 = optimizer.worldPadCenter(&part, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
                shx = e1[0] - c[0];
                shy = e1[1] - c[1];
            }
            try out.append(arena, .{ .x = c[0], .y = c[1], .r = pad.drill / 2, .shx = shx, .shy = shy });
        }
    }
    return out.toOwnedSlice(arena);
}

/// The drills of already-routed vias, for `boardHoles`.
pub fn viaHoles(arena: std.mem.Allocator, vias: []const route_result.Via) std.mem.Allocator.Error![]const Hole {
    var out: std.ArrayList(Hole) = .empty;
    for (vias) |v| {
        if (v.drill > 0) try out.append(arena, .{ .x = v.x, .y = v.y, .r = v.drill / 2 });
    }
    return out.toOwnedSlice(arena);
}

/// Every drill on the board: the parts' through pads plus `via_holes`, the
/// drills of the vias already routed. The vias used to be left out, and the
/// via-ban mask is all the maze consults before dropping a barrel, so a hop
/// could land one fine-grid node from an existing via and come back rejected
/// by DRC — measured on board-a's `SPI_SCK` as two drills 0.2008 mm apart
/// against a 0.2 mm wall, which was the whole reason a clean route was lost.
pub fn boardHoles(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    via_holes: []const Hole,
) std.mem.Allocator.Error![]const Hole {
    var out: std.ArrayList(Hole) = .empty;
    try out.appendSlice(arena, try padHoles(arena, placement));
    try out.appendSlice(arena, via_holes);
    return out.toOwnedSlice(arena);
}

/// Separation below which two bores are the SAME hole rather than a wall.
/// mirror-of: src/placement/drc.zig.eps
const coincident_eps: f64 = 1e-6;

/// Wall gap between a new barrel of diameter `drill` centred at `(x, y)` and the
/// drilled hole `h`: the capsule-to-point distance less both bores.
///
/// THE one place the router prices a hole-to-hole wall, transcribed from
/// `drc.holePairViolation` so a generated barrel is measured exactly as the
/// checker will measure it. Null for a bore coincident with the candidate — a
/// via re-drilled on an existing barrel is the same hole, not a wall, which is
/// the identical exemption the checker's `< eps` guard makes.
pub fn wallGap(h: Hole, x: f64, y: f64, drill: f64) ?f64 {
    if (std.math.hypot(x - h.x, y - h.y) < coincident_eps) return null;
    const wall = pad_shape.segPointDist(h.x - h.shx, h.y - h.shy, h.x + h.shx, h.y + h.shy, x, y);
    return wall - h.r - drill / 2;
}

/// One terminal's exit question: the pad box to stay inside, the copper's
/// half-width, the sampling pitch, the anchor to beat, the net, and the
/// clearance the exit must reach.
pub const Exit = struct {
    box: [4]f64,
    half: f64,
    step: f64,
    at: [2]f64,
    net: i32,
    need: f64,
};

/// The clearest point inside `req.box` for copper on `req.net` to leave from,
/// or null to keep the caller's anchor.
///
/// Null covers every case where moving would be wrong or pointless: the anchor
/// already clears `req.need`, or the pad is too small to hold an alternative
/// once `req.half` is kept inside it. A board whose terminals were never the
/// problem therefore routes exactly as it did before. Clearance is what this
/// maximises — WHICH clear point it lands on is not part of the contract.
pub fn interior(obs: anytype, req: Exit) ?[2]f64 {
    const limit = req.need * span;
    var best_margin = margin(obs, req.at[0], req.at[1], req.net, limit);
    if (best_margin >= req.need) return null;
    const lo = [2]f64{ req.box[0] + req.half, req.box[1] + req.half };
    const hi = [2]f64{ req.box[2] - req.half, req.box[3] - req.half };
    if (hi[0] <= lo[0] or hi[1] <= lo[1]) return null;
    var best: ?[2]f64 = null;
    var y = lo[1];
    while (y <= hi[1] + eps) : (y += req.step) {
        var x = lo[0];
        while (x <= hi[0] + eps) : (x += req.step) {
            const m = margin(obs, x, y, req.net, limit);
            if (m > best_margin) {
                best_margin = m;
                best = .{ x, y };
                if (m >= limit) return best;
            }
        }
    }
    return best;
}

/// The land of the terminal's OWN pad — the first obstacle on `net` whose box
/// contains `at` (within `slack`), as `[x0, y0, x1, y1]` — or null when the
/// point sits on no pad of its own net.
pub fn ownBox(obs: []const pad_grid.PadObs, at: [2]f64, net: i32, slack: f64) ?[4]f64 {
    for (obs) |p| {
        if (p.net != net) continue;
        if (at[0] < p.x0 - slack or at[0] > p.x1 + slack) continue;
        if (at[1] < p.y0 - slack or at[1] > p.y1 + slack) continue;
        return .{ p.x0, p.y0, p.x1, p.y1 };
    }
    return null;
}

/// One terminal's move-to-clear-copper request: the trace half-width to keep
/// inside the pad, the sampling pitch, the clearance the exit must reach, and
/// the tolerance for deciding which pad the terminal is standing on.
pub const Interior = struct { half: f64, step: f64, need: f64, slack: f64 };

/// `pt` moved to the clearest point inside its own pad, or `pt` unchanged when
/// it stands on no pad of its net or the pad offers nothing better (see
/// `interior`, which owns that judgement).
pub fn movedToInterior(obs: []const pad_grid.PadObs, pt: NetPt, net: i32, req: Interior) NetPt {
    const b = ownBox(obs, .{ pt.x, pt.y }, net, req.slack) orelse return pt;
    const at = interior(obs, .{
        .box = b,
        .half = req.half,
        .step = req.step,
        .at = .{ pt.x, pt.y },
        .net = net,
        .need = req.need,
    }) orelse return pt;
    var out = pt;
    out.x = at[0];
    out.y = at[1];
    return out;
}

/// Distance from `(x, y)` to the nearest obstacle NOT on `net`, capped at
/// `limit`. The cap is what keeps this cheap enough to sample a lattice with.
fn margin(obs: anytype, x: f64, y: f64, net: i32, limit: f64) f64 {
    var best = limit;
    for (obs) |o| {
        if (o.net == net) continue;
        const d = pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, x, y, best);
        if (d < best) best = d;
    }
    return best;
}

/// How far, in units of the exit clearance, it is worth sliding inside a pad.
/// Two is enough to clear a neighbour on a 0.5 mm-pitch row and to reach the
/// free half of a thermal pad, and it bounds the sampling above.
/// One route terminal as the escape-pair rule below sees it: where the pad is,
/// which signal layer it presents on, and its outward escape axis. A plain
/// record rather than the router's own `NetPt`, so this module stays out of an
/// import cycle with the router (see the header).
pub const Term = struct { x: f64, y: f64, layer: u8, out: [2]f64 = .{ 0, 0 } };

/// One resolved router terminal: pad centre, signal layer, identity, and the
/// unit component-outward axis used by the pad-axis and RF escape planners.
pub const NetPt = struct {
    x: f64,
    y: f64,
    layer: u8,
    thru: bool = false,
    ref_des: []const u8 = "",
    pin: []const u8 = "",
    out: [2]f64 = .{ 0, 0 },
};

/// Project a resolved router terminal onto the straight-escape rule's record.
pub fn asTerm(p: NetPt) Term {
    return .{ .x = p.x, .y = p.y, .layer = p.layer, .out = p.out };
}

/// Resolve every pin on `net` to its physical pad centre and outward axis.
pub fn netPoints(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    net: flat_netlist.FlatNet,
) std.mem.Allocator.Error![]NetPt {
    var list: std.ArrayList(NetPt) = .empty;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        const part = placement.parts[pi];
        const pad = padOf(part, pin.pin) orelse continue;
        const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
        const olen = std.math.hypot(c[0] - part.x, c[1] - part.y);
        const out: [2]f64 = if (olen > 1e-9)
            .{ (c[0] - part.x) / olen, (c[1] - part.y) / olen }
        else
            .{ 0, 0 };
        try list.append(arena, .{
            .x = c[0],
            .y = c[1],
            .layer = if (part.side == .bottom) 1 else 0,
            .thru = pad.thru,
            .ref_des = pin.ref_des,
            .pin = pin.pin,
            .out = out,
        });
    }
    return list.toOwnedSlice(arena);
}

fn padOf(part: optimizer.Part, pin: []const u8) ?geometry.Pad {
    for (part.pads) |pad| if (std.mem.eql(u8, pad.number, pin)) return pad;
    return null;
}

/// Widest off-axis angle (expressed as a tangent) between two terminals still
/// treated as "nearly axis-aligned": ~11°, so the shorter of |dx|,|dy| must be
/// within a fifth of the longer. A single straight segment across such a pair
/// reads as horizontal or vertical.
const axis_align_ratio: f64 = 0.2;
/// cos of the widest angle (45°) the straight pad-to-pad line may deviate from
/// a pad's outward escape axis and still count as leaving that pad straight.
const escape_exit_min_dot: f64 = 0.70710678;

/// True when a straight segment leaving a pad along `(ux,uy)` stays inside that
/// pad's outward escape cone — or the pad declares no outward axis ({0,0}).
pub fn exitsAlong(out: [2]f64, ux: f64, uy: f64) bool {
    if (out[0] == 0 and out[1] == 0) return true;
    return ux * out[0] + uy * out[1] >= escape_exit_min_dot;
}

/// True when a single straight segment between the two same-layer terminals is
/// BOTH nearly axis-aligned (essentially horizontal or vertical) AND leaves
/// each pad along its outward escape axis (within 45°) — a facing, axis-aligned
/// pad pair for which the straight line IS each pad's ideal escape. This is the
/// one case an escape-shaped net may skip the maze for (see `routeNetAttempt`):
/// the straight RF hop beats the maze's grid-quantized dogleg, and the escape
/// reserve holds by construction. A pad at its part centre ({0,0} axis) imposes
/// no facing constraint; a diagonal, coincident, or cross-layer pair is refused.
pub fn straightEscapePair(a: Term, b: Term) bool {
    if (a.layer != b.layer) return false;
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const adx = @abs(dx);
    const ady = @abs(dy);
    const hi = @max(adx, ady);
    if (hi < 1e-9) return false; // coincident — no direction
    if (@min(adx, ady) > axis_align_ratio * hi) return false; // not near an axis
    const d = std.math.hypot(dx, dy);
    const ux = dx / d;
    const uy = dy / d;
    return exitsAlong(a.out, ux, uy) and exitsAlong(b.out, -ux, -uy);
}

const span: f64 = 2.0;
const eps: f64 = 1e-9;

const testing = std.testing;

const Obs = struct { x0: f64, y0: f64, x1: f64, y1: f64, net: i32, poly: []const [2]f64 = &.{} };

const big_pad = [4]f64{ -0.7, -0.9, 0.7, 0.9 };

// spec: placement/router - a gap hop leaves each terminal from the clearest point inside that pad, not from the pad centre
test "a crowded pad's exit moves onto clear copper, an uncrowded one stays put" {
    const need: f64 = 0.1905;
    // A 1.4 x 1.8 mm pad on net 0 with a foreign pad hugging the -y edge, its
    // bottom 0.06 mm above the big pad's centre: `buck_6v/U22.3` in miniature.
    const crowded = [_]Obs{
        .{ .x0 = -0.7, .y0 = -0.9, .x1 = 0.7, .y1 = 0.9, .net = 0 },
        .{ .x0 = -0.125, .y0 = -0.86, .x1 = 0.125, .y1 = -0.06, .net = 1 },
    };
    const at = interior(&crowded, .{
        .box = big_pad,
        .half = 0.0635,
        .step = 0.05,
        .at = .{ 0, 0 },
        .net = 0,
        .need = need,
    });
    try testing.expect(at != null);
    const p = at.?;
    // Still on the pad — copper leaving from off it connects nothing — and
    // genuinely clear, which the centre at 0.06 mm from the neighbour was not.
    try testing.expect(p[0] >= big_pad[0] and p[0] <= big_pad[2]);
    try testing.expect(p[1] >= big_pad[1] and p[1] <= big_pad[3]);
    try testing.expect(margin(&crowded, p[0], p[1], 0, need * 2) >= need);
    try testing.expect(margin(&crowded, 0, 0, 0, need * 2) < need);

    // Nothing foreign near: moving would churn a board whose terminals were
    // never the problem, so the anchor is kept.
    const roomy = [_]Obs{
        .{ .x0 = -0.7, .y0 = -0.9, .x1 = 0.7, .y1 = 0.9, .net = 0 },
        .{ .x0 = 5, .y0 = 5, .x1 = 5.5, .y1 = 5.5, .net = 1 },
    };
    try testing.expect(interior(&roomy, .{
        .box = big_pad,
        .half = 0.0635,
        .step = 0.05,
        .at = .{ 0, 0 },
        .net = 0,
        .need = need,
    }) == null);

    // A pad too small to hold an alternative also keeps its anchor, even when
    // the anchor is crowded — there is nowhere else on it to stand.
    const tight_box = [4]f64{ -0.05, -0.05, 0.05, 0.05 };
    const tight = [_]Obs{
        .{ .x0 = -0.05, .y0 = -0.05, .x1 = 0.05, .y1 = 0.05, .net = 0 },
        .{ .x0 = 0.06, .y0 = -0.05, .x1 = 0.3, .y1 = 0.05, .net = 1 },
    };
    try testing.expect(interior(&tight, .{
        .box = tight_box,
        .half = 0.0635,
        .step = 0.05,
        .at = .{ 0, 0 },
        .net = 0,
        .need = need,
    }) == null);
}

// spec: placement/router - a gap pass keeps a new barrel clear of every drill already on the board, the routed vias as well as the through pads
test "the board hole set carries routed via drills beside the pad drills" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const bare = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    try testing.expectEqual(@as(usize, 0), (try boardHoles(arena, bare, &.{})).len);
    const with_via = try boardHoles(arena, bare, &.{.{ .x = 3, .y = 1, .r = 0.125 }});
    try testing.expectEqual(@as(usize, 1), with_via.len);
    try testing.expectEqual(@as(f64, 3), with_via[0].x);
    try testing.expectEqual(@as(f64, 0.125), with_via[0].r);
}

// spec: placement/router - a barrel's wall to a bore is measured end-to-end along an oval slot, and a bore coincident with the barrel is the same hole rather than a wall
test "a barrel's wall to a bore reads the slot end-to-end and exempts a coincident hole" {
    // A round 0.2 mm bore at the origin, and a 0.3 mm barrel 0.4 mm away: the
    // wall is 0.4 − 0.1 − 0.15 = 0.15 mm, exactly what `drc.holePairViolation`
    // measures for the same pair.
    const round = Hole{ .x = 0, .y = 0, .r = 0.1 };
    try testing.expectApproxEqAbs(@as(f64, 0.15), wallGap(round, 0.4, 0, 0.3).?, 1e-9);

    // The same bore drawn as a slot running ±0.5 mm along x reaches the barrel:
    // the wall is measured from the nearer arc centre (0.4 − 0.5 is inside the
    // slot, so the capsule distance is 0), not from the slot's midpoint.
    const slot = Hole{ .x = 0, .y = 0, .r = 0.1, .shx = 0.5, .shy = 0 };
    try testing.expectApproxEqAbs(@as(f64, -0.25), wallGap(slot, 0.4, 0, 0.3).?, 1e-9);
    // Off the slot's axis it is the capsule distance, not the centre distance:
    // a barrel 0.4 mm ABOVE the slot's flank clears by 0.4 − 0.1 − 0.15.
    try testing.expectApproxEqAbs(@as(f64, 0.15), wallGap(slot, 0.3, 0.4, 0.3).?, 1e-9);

    // A barrel on the bore's own centre is that hole re-drilled, not a wall —
    // the exemption the checker makes with the identical epsilon.
    try testing.expect(wallGap(round, 0, 0, 0.3) == null);
    try testing.expect(wallGap(round, 5e-7, 0, 0.3) == null);
    try testing.expect(wallGap(round, 1e-3, 0, 0.3) != null);
}
