//! Small, fill-blind queries over authored bypass intent.
//!
//! These predicates deliberately depend only on the placement model and the
//! shared contact/pad geometry so late copper finishers can preserve exact
//! cap-to-pin requirements without pulling in the DRC or the router and
//! creating an import cycle. Copper arrives as the caller's OWN track type
//! (`build` is generic over it) and every query takes loose geometry, for the
//! same reason.
//!
//! ## What is protected, and why that is enough
//!
//! `bypass_open.check` is the rule this module exists to keep satisfied. For
//! each authored, non-reservoir `(decouples "IC" PIN)` bond it asks ONE
//! question: over same-net tracks on the two parts' shared outer face — vias
//! and pours deliberately excluded — is the cap's rail land united with the
//! exact IC supply land? Nothing else about the net matters to it.
//!
//! So the unit of protection is not the net. It is a WALK: one cap-land →
//! track → … → track → pin-land path through that very graph (`build` takes
//! the fewest-hops one, ties broken by track order, so the answer is a function
//! of the board alone). Everything else the net carries — a second
//! `(decouples rail)` reservoir's escape, a branch to a connector, the plane
//! drops — is ordinary copper the geometry passes may clean.
//!
//! ## Two ways to honour it, for two shapes of pass
//!
//! **Keep the walk (`trackFrozen`).** A pass that deletes or rewrites copper
//! object by object — a section-deletion oracle, a gloss over a per-track
//! mutability mask — refuses the objects the walk is made of.
//! `surfaceConnected` is a union-find over (cap land, pin land, same-net
//! same-layer tracks) whose unions come from `copper_contact` predicates
//! evaluated pairwise. The walk's own unions — cap↔t0, t0↔t1, …, tk↔pin — are
//! functions of the walk's tracks and the two LANDS alone, and lands are part
//! poses no finisher moves. Adding other tracks can only merge more; removing
//! them removes no union the walk induced. So `root(cap) == root(pin)` still
//! holds: a pass can no more orphan the bond than it can move the parts.
//!
//! **Or ask afterwards (`stillCloses`).** A pass that rebuilds a whole net at
//! once — straighten, the pad-escape rewrite, the pad-entry trim, the via-in-pad
//! sweep — has no cheap object-level story, and holding one chain rigid while
//! the copper around it moves is not conservative at all: it ships a board
//! neither the frozen nor the free version would have produced, and on
//! `board-a-lt3045-ldo` that shape cost VIN its whole route to a `track_width`
//! finding. Those passes rewrite freely and then re-run this walk over the
//! candidate copper — the very question `bypass_open.check` will ask the
//! finished board — putting the net back verbatim when a bond that was closed
//! has come open. That is the invariant asserted rather than argued, and it
//! leaves the pass free every time it does no harm.
//!
//! **When the walk does not exist**, the bond is protected by nothing, and that
//! is the whole of the rule rather than a hole in it. The invariant a cleanup
//! guard can hold is "no pass takes a bond from CLOSED to OPEN"; a bond with no
//! walk is one `bypass_open.check` reports open THIS INSTANT, and no pass can
//! push a boolean below its floor. The three ways a walk goes missing all say
//! the same thing: the surface leg was never drawn (open — `bypass_open` warns
//! now), the two parts straddle the board (open — `bypass_open` warns
//! unconditionally, no face exists to route on), or the loop's `PadRect` names
//! no footprint pad (`bypass_open` skips the bond entirely, so it states no
//! requirement at all). None of the three has copper whose loss would cost
//! anything. Freezing the net there buys no exactness and costs every pass its
//! gloss — measured on `board-a-lt3045-ldo`, where BOTH authored bonds are open
//! on the shipped board and the whole-net freeze bought two frozen rails for
//! nothing.
//!
//! Because every pass re-derives this from the copper in front of it, a bond is
//! protected from the FIRST pass at which it reads closed onward — including
//! one closed late, by the net-open bridger. Induction over the pass sequence
//! then gives the invariant outright: no bond that is closed when a pass begins
//! is open when it ends, so none can be closed at the start of the finish and
//! open at the end.
//!
//! What ambiguity remains still biases to protection: membership is sampled
//! with a tolerance that errs wide, a transaction that cannot prove the bond
//! survived puts the whole net back rather than part of it, and
//! `subcircuit_seed_drc`'s hierarchical-seed normalizer keeps the coarse
//! net-wide `exactNet` answer, because the per-net mask it feeds is shared with
//! the viewer's land-transit repair and has nowhere finer to say it.

const std = @import("std");
const copper_contact = @import("copper_contact.zig");
const geometry = @import("geometry.zig");
const optimizer = @import("optimizer.zig");
const pad_shape = @import("pad_shape.zig");

/// Two lands this close are already one node in `bypass_open`'s graph (its own
/// `touch_slack_mm`), so a bond between them needs no copper at all.
const touch_slack_mm: f64 = 0.02;

/// How far off a frozen leg segment copper may lie and still be read as part of
/// it (mm). It has to absorb `bend_smooth`'s chain rebuild — `qpt` quantizes
/// endpoints at 1e-4 mm and `appendLeg` fuses legs whose turn cross-product is
/// under 1e-4 mm² — and a junction canonicalization that split one leg in two.
/// 0.01 mm does that with room to spare while staying an order of magnitude
/// under the smallest clearance any net class allows, so no neighbouring trace
/// can be mistaken for leg copper.
const on_leg_tol_mm: f64 = 0.01;

/// Does `net_i` carry at least one authored, non-reservoir bypass leg whose
/// local surface path must terminate on an exact IC supply pad?
///
/// The COARSE question — true for the whole net, leg copper or not. Passes that
/// are net-granular by construction still ask it; anything that can name the
/// copper it is about should build `Legs` and ask that instead.
pub fn exactNet(placement: optimizer.Placement, net_i: usize) bool {
    for (placement.loops) |loop| {
        if (!authoredExact(loop)) continue;
        if (@as(usize, @intCast(loop.pwr_net)) == net_i) return true;
    }
    return false;
}

/// An authored per-pin bypass bond: a named target pin, not a rail reservoir,
/// on a resolved rail net. Optimizer-inferred proximity loops are not intent.
fn authoredExact(loop: optimizer.Loop) bool {
    return loop.explicit_pin.len > 0 and !loop.rail_optout and loop.pwr_net >= 0;
}

/// One track of an authored bond's surface walk, as plain geometry. The width
/// rides along because `copper_contact` reads a bottleneck cross-section, not a
/// centreline: a walk found at any other width would not be the walk
/// `bypass_open` sees.
pub const Seg = struct { a: [2]f64, b: [2]f64, layer: u8, width: f64, net: i32 };

/// The copper that realizes a board's authored exact bypass bonds — see the
/// module header for the membership definition and its exactness argument.
///
/// Built from the copper as it stands. Its holder either keeps the walk's own
/// tracks (`trackFrozen`), which leaves the answer true however much of the
/// rest of the rail goes, or rewrites freely and re-asks (`stillCloses`).
pub const Legs = struct {
    /// Every track on every resolved walk, in bond order. Empty means no walk
    /// carries a bond — either none is authored, or none of the authored ones
    /// is closed, or the closed ones are closed by abutting lands alone.
    segs: []const Seg = &.{},
    /// Index-aligned with `placement.loops`: was this bond CLOSED when the
    /// guard was built? The set a transactional caller must keep closed.
    closed: []const bool = &.{},

    /// Is any bond on this board closed, and so worth protecting? False lets a
    /// caller skip every question below.
    pub fn any(self: Legs) bool {
        for (self.closed) |c| {
            if (c) return true;
        }
        return false;
    }

    /// Would `tracks` still close every bond that was closed when this guard
    /// was built?
    ///
    /// The exactness invariant asked directly, for a pass that rewrites a whole
    /// net at once and cannot cheaply argue object by object: rewrite freely,
    /// then ask, and put the net back when the answer is no. It re-runs the
    /// same walk `build` ran, against the candidate copper — which is precisely
    /// what `bypass_open.check` will do to the finished board.
    pub fn stillCloses(
        self: Legs,
        arena: std.mem.Allocator,
        placement: optimizer.Placement,
        comptime Copper: type,
        tracks: []const Copper,
    ) std.mem.Allocator.Error!bool {
        if (!self.any()) return true;
        // Only the bonded RAILS' copper can answer this, so only that is
        // converted: on a board of thousands of sections the closed bonds sit
        // on one or two nets, and every pass asks this once per net it rewrites.
        var copper: std.ArrayList(Seg) = .empty;
        for (tracks) |t| {
            if (!self.onBondRail(placement, t.net)) continue;
            try copper.append(arena, segOf(t));
        }
        for (placement.loops, 0..) |loop, li| {
            if (li >= self.closed.len or !self.closed[li]) continue;
            var scratch: std.ArrayList(Seg) = .empty;
            if (!try walk(arena, placement, loop, copper.items, &scratch)) return false;
        }
        return true;
    }

    /// Does `net` carry one of the bonds this guard must keep closed?
    fn onBondRail(self: Legs, placement: optimizer.Placement, net: i32) bool {
        if (net < 0) return false;
        for (placement.loops, 0..) |loop, li| {
            if (li >= self.closed.len or !self.closed[li]) continue;
            if (loop.pwr_net == net) return true;
        }
        return false;
    }

    /// Must this track be kept? True for a walk track and for any track lying
    /// ON the walk's copper.
    ///
    /// The question is asked as "does this track lie on leg copper" rather than
    /// by record identity because the finish reshapes the track LIST around a
    /// leg it never reshapes: a junction canonicalization splits one leg segment
    /// in two, a chain rebuild fuses a collinear run into one. Both leave the
    /// same centreline, and sampling a track's two ends and its middle answers
    /// for either. A track that merely crosses the leg puts one sample on it,
    /// not three.
    ///
    /// Taken as loose geometry rather than a track record so every caller's own
    /// copper type fits without this module learning about the router.
    pub fn trackFrozen(self: Legs, net: i32, layer: u8, a: [2]f64, b: [2]f64) bool {
        if (net < 0 or self.segs.len == 0) return false;
        const mid = [2]f64{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 };
        return self.onLeg(net, layer, a) and self.onLeg(net, layer, b) and self.onLeg(net, layer, mid);
    }

    /// Does `p` sit on this net's leg copper on `layer`?
    fn onLeg(self: Legs, net: i32, layer: u8, p: [2]f64) bool {
        for (self.segs) |s| {
            if (s.net != net or s.layer != layer) continue;
            if (onSegment(s, p)) return true;
        }
        return false;
    }
};

/// Resolve every authored exact bond on `placement` against `tracks`.
///
/// `Copper` is the caller's own track record — anything carrying
/// `x1/y1/x2/y2/layer/width/net` — so this module needs no router import and no
/// caller needs a conversion.
///
/// Cheap on the overwhelming majority of boards: with no authored exact bond it
/// allocates nothing and every query answers false.
pub fn build(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    comptime Copper: type,
    tracks: []const Copper,
) std.mem.Allocator.Error!Legs {
    var authored = false;
    for (placement.loops) |loop| {
        if (authoredExact(loop)) authored = true;
    }
    if (!authored) return .{};

    const copper = try arena.alloc(Seg, tracks.len);
    for (tracks, copper) |t, *s| s.* = segOf(t);
    const closed = try arena.alloc(bool, placement.loops.len);
    @memset(closed, false);
    var segs: std.ArrayList(Seg) = .empty;
    for (placement.loops, 0..) |loop, li| {
        if (!authoredExact(loop)) continue;
        if (@as(usize, @intCast(loop.pwr_net)) >= placement.nets.len) continue;
        closed[li] = try walk(arena, placement, loop, copper, &segs);
    }
    return .{ .segs = try segs.toOwnedSlice(arena), .closed = closed };
}

/// One caller track as the plain segment the walk reads.
fn segOf(t: anytype) Seg {
    return .{
        .a = .{ t.x1, t.y1 },
        .b = .{ t.x2, t.y2 },
        .layer = t.layer,
        .width = t.width,
        .net = t.net,
    };
}

/// Append one bond's surface walk to `out`, or report that it has none.
///
/// The graph is `bypass_open.surfaceConnected`'s exactly: same-net tracks on
/// the two parts' shared outer face, united by `copper_contact`. The search is
/// a breadth-first sweep from the cap land, so the walk is the fewest-hops one
/// and ties fall to track order — a function of the board, not of the sweep.
fn walk(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    loop: optimizer.Loop,
    copper: []const Seg,
    out: *std.ArrayList(Seg),
) std.mem.Allocator.Error!bool {
    if (loop.cap >= placement.parts.len or loop.hub >= placement.parts.len) return false;
    const cap = placement.parts[loop.cap];
    const hub = placement.parts[loop.hub];
    // A direct outer-face leg cannot cross sides — `bypass_open` warns outright
    // there, and no cleanup can make or break a bond that has no face to run on.
    if (cap.side != hub.side) return false;
    const layer: u8 = if (cap.side == .top) 0 else 1;
    const cap_pad = padAt(cap, loop.cap_pwr) orelse return false;
    const hub_pad = padAt(hub, loop.hub_pwr_pin) orelse return false;
    const cap_shape = try pad_shape.worldShape(arena, cap, cap_pad);
    const hub_shape = try pad_shape.worldShape(arena, hub, hub_pad);
    // Abutting lands are one node before any copper is drawn.
    if (pad_shape.shapeGap(cap_shape, hub_shape, touch_slack_mm) <= touch_slack_mm) return true;

    var cand: std.ArrayList(Seg) = .empty;
    for (copper) |s| {
        if (s.net != loop.pwr_net or s.layer != layer) continue;
        try cand.append(arena, s);
    }
    const n = cand.items.len;
    if (n == 0) return false;
    const prev = try arena.alloc(usize, n);
    const seen = try arena.alloc(bool, n);
    @memset(seen, false);
    var queue: std.ArrayList(usize) = .empty;
    var hit: ?usize = null;
    for (cand.items, 0..) |s, i| {
        if (!touchesShape(s, cap_shape)) continue;
        seen[i] = true;
        prev[i] = i; // a seed is its own predecessor
        if (touchesShape(s, hub_shape)) {
            hit = i;
            break;
        }
        try queue.append(arena, i);
    }
    var head: usize = 0;
    while (hit == null and head < queue.items.len) : (head += 1) {
        const at = queue.items[head];
        for (cand.items, 0..) |s, i| {
            if (seen[i] or !segsTouch(cand.items[at], s)) continue;
            seen[i] = true;
            prev[i] = at;
            if (touchesShape(s, hub_shape)) {
                hit = i;
                break;
            }
            try queue.append(arena, i);
        }
    }
    const end = hit orelse return false;
    var at = end;
    while (true) {
        try out.append(arena, cand.items[at]);
        if (prev[at] == at) break;
        at = prev[at];
    }
    return true;
}

/// The footprint pad a loop's `PadRect` names, matched the way `bypass_open`
/// matches it so both rules speak about the same land.
fn padAt(part: optimizer.Part, rect: optimizer.PadRect) ?geometry.Pad {
    if (!(rect.w > 0 and rect.h > 0)) return null;
    for (part.pads) |pad| {
        if (@abs(pad.x - rect.x) <= 1e-7 and @abs(pad.y - rect.y) <= 1e-7) return pad;
    }
    return null;
}

fn trace(s: Seg) copper_contact.Trace {
    return .{ .a = s.a, .b = s.b, .width = s.width };
}

fn touchesShape(s: Seg, shape: pad_shape.Shape) bool {
    return copper_contact.padTrackConnects(shape, s.a, s.b, s.width);
}

fn segsTouch(a: Seg, b: Seg) bool {
    return copper_contact.trackTrackConnects(trace(a), trace(b));
}

/// Distance from `p` to the segment `a`→`b` (mm).
fn pointSegDist(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    if (len2 <= 0) return std.math.hypot(p[0] - a[0], p[1] - a[1]);
    const t = std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0, 1);
    return std.math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

fn onSegment(s: Seg, p: [2]f64) bool {
    return pointSegDist(s.a, s.b, p) <= on_leg_tol_mm;
}

const testing = std.testing;

/// A two-pad 0402 land pattern (pads at ±0.5 mm on x) — the shape both the cap
/// and the stand-in IC wear in these fixtures.
const two_pads = [_]geometry.Pad{
    .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
    .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
};

const Track = struct { x1: f64, y1: f64, x2: f64, y2: f64, layer: u8 = 0, width: f64 = 0.2, net: i32 = 0 };

/// `Legs.trackFrozen` asked about a whole fixture track.
fn frozen(legs: Legs, t: Track) bool {
    return legs.trackFrozen(t.net, t.layer, .{ t.x1, t.y1 }, .{ t.x2, t.y2 });
}

/// One rail net (`net 0`) with an IC at the origin and two caps on it: `C1`
/// carries an authored `(decouples "U1" 1)` bond to the IC's pad 1, `C2` is a
/// `(decouples rail)` reservoir with no exact target. Both sit to the right of
/// the IC; the exact leg runs U1 pad 1 → C1 pad 1, the reservoir's copper runs
/// off elsewhere entirely.
fn twoBondPlacement(parts: []optimizer.Part, loops: []optimizer.Loop, nets: []const optimizer.FlatNet) optimizer.Placement {
    parts[0] = .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &two_pads, .fallback = false, .x = 0, .y = 0 };
    parts[1] = .{ .ref_des = "C1", .kind = .passive, .hw = 0.6, .hh = 0.4, .pads = &two_pads, .fallback = false, .x = 4, .y = 0 };
    parts[2] = .{ .ref_des = "C2", .kind = .passive, .hw = 0.6, .hh = 0.4, .pads = &two_pads, .fallback = false, .x = 4, .y = 4 };
    loops[0] = .{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .cap_gnd = .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &.{},
        .pwr_net = 0,
        .explicit_pin = "1",
    };
    loops[1] = .{
        .cap = 2,
        .hub = 0,
        .cap_pwr = .{ .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .cap_gnd = .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &.{},
        .pwr_net = 0,
        .rail_optout = true,
    };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 8,
        .maxy = 8,
        .generated = true,
    };
}

// spec: placement/bypass-intent - the copper frozen for an authored exact bypass bond is the cap-land-to-pin-land surface walk, not the whole rail net
test "a two-bond rail freezes the exact leg and leaves the reservoir's copper cleanable" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [3]optimizer.Part = undefined;
    var loops: [2]optimizer.Loop = undefined;
    const nets = [_]optimizer.FlatNet{.{ .name = "VIN", .pins = &.{} }};
    const placement = twoBondPlacement(&parts, &loops, &nets);

    // The exact leg: U1 pad 1 (-0.5,0) out to C1 pad 1 (3.5,0), drawn as two
    // tracks meeting at (2,0). The reservoir's copper is a separate run to C2.
    const tracks = [_]Track{
        .{ .x1 = -0.5, .y1 = 0, .x2 = 2, .y2 = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3.5, .y2 = 0 },
        .{ .x1 = 3.5, .y1 = 4, .x2 = 2, .y2 = 4 },
        .{ .x1 = 2, .y1 = 4, .x2 = 2, .y2 = 0 },
    };
    const legs = try build(arena, placement, Track, &tracks);
    try testing.expect(legs.any());
    try testing.expectEqual(@as(usize, 2), legs.segs.len);
    try testing.expect(frozen(legs, tracks[0]));
    try testing.expect(frozen(legs, tracks[1]));
    // The reservoir's own copper is ordinary: cleanable like any other net.
    try testing.expect(!frozen(legs, tracks[2]));
    try testing.expect(!frozen(legs, tracks[3]));
    // The coarse question still says "exact" for the whole net — that is the
    // answer a net-granular pass keeps taking.
    try testing.expect(exactNet(placement, 0));
}

// spec: placement/bypass-intent - a rail whose only copper is its exact bypass leg is frozen entire, exactly as the whole-net freeze left it
test "a rail carrying only its exact leg freezes every track it has" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [3]optimizer.Part = undefined;
    var loops: [2]optimizer.Loop = undefined;
    const nets = [_]optimizer.FlatNet{.{ .name = "VIN", .pins = &.{} }};
    const placement = twoBondPlacement(&parts, &loops, &nets);

    const tracks = [_]Track{
        .{ .x1 = -0.5, .y1 = 0, .x2 = 2, .y2 = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3.5, .y2 = 0 },
    };
    const legs = try build(arena, placement, Track, &tracks);
    for (tracks) |t| try testing.expect(frozen(legs, t));
}

// spec: placement/bypass-intent - a whole-net rewrite is refused when it leaves an authored bypass bond that was closed no longer closing over routed copper
test "the transaction accepts a rewrite that keeps the pair closed and refuses one that does not" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [3]optimizer.Part = undefined;
    var loops: [2]optimizer.Loop = undefined;
    const nets = [_]optimizer.FlatNet{.{ .name = "VIN", .pins = &.{} }};
    const placement = twoBondPlacement(&parts, &loops, &nets);

    const before = [_]Track{
        .{ .x1 = -0.5, .y1 = 0, .x2 = 2, .y2 = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3.5, .y2 = 0 },
        .{ .x1 = 3.5, .y1 = 4, .x2 = 2, .y2 = 4 },
        .{ .x1 = 2, .y1 = 4, .x2 = 2, .y2 = 0 },
    };
    const legs = try build(arena, placement, Track, &before);
    try testing.expect(legs.any());

    // Rewrite A — the reservoir's run is deleted and the leg's two tracks are
    // fused into one. The pair still closes cap land to pin land, so a pass may
    // commit it: the guard is about the BOND, not about byte identity.
    const kept = [_]Track{.{ .x1 = -0.5, .y1 = 0, .x2 = 3.5, .y2 = 0 }};
    try testing.expect(try legs.stillCloses(arena, placement, Track, &kept));

    // Rewrite B — the same fusion, shortened so it no longer reaches the exact
    // IC land. Every pad is still on one connected piece of copper and an
    // ordinary net-open check is happy; the bond is not, so the pass must roll
    // this back.
    const shortened = [_]Track{.{ .x1 = 0.5, .y1 = 0, .x2 = 3.5, .y2 = 0 }};
    try testing.expect(!try legs.stillCloses(arena, placement, Track, &shortened));

    // Rewrite C — the leg deleted outright, which is the shape a fill-blind
    // section-deletion oracle proposes on a planed rail.
    const gone = [_]Track{
        .{ .x1 = 3.5, .y1 = 4, .x2 = 2, .y2 = 4 },
        .{ .x1 = 2, .y1 = 4, .x2 = 2, .y2 = 0 },
    };
    try testing.expect(!try legs.stillCloses(arena, placement, Track, &gone));

    // A guard holding no closed bond has nothing to refuse.
    const inert = Legs{};
    try testing.expect(try inert.stillCloses(arena, placement, Track, &gone));
}

// spec: placement/bypass-intent - an authored exact bypass bond that no surface walk closes protects no copper, because the bond is already open and cleanup cannot open it further
test "an unrealized or cross-side bond protects nothing" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [3]optimizer.Part = undefined;
    var loops: [2]optimizer.Loop = undefined;
    const nets = [_]optimizer.FlatNet{.{ .name = "VIN", .pins = &.{} }};
    const placement = twoBondPlacement(&parts, &loops, &nets);

    // Copper that stops at the WRONG supply pad: `bypass_open` warns about this
    // bond right now, and no geometry pass can push that verdict lower, so
    // there is nothing here worth freezing.
    const wrong = [_]Track{.{ .x1 = 0.5, .y1 = 0, .x2 = 3.5, .y2 = 0 }};
    const open = try build(arena, placement, Track, &wrong);
    try testing.expect(!open.any());
    try testing.expect(!frozen(open, wrong[0]));
    try testing.expectEqual(@as(usize, 0), open.segs.len);

    // Same copper, cap flipped to the far side: no shared face for a leg to run
    // on, so `bypass_open` warns unconditionally and again nothing is at stake.
    var flipped_parts = parts;
    flipped_parts[1].side = .bottom;
    var flipped = placement;
    flipped.parts = &flipped_parts;
    const closed = [_]Track{.{ .x1 = -0.5, .y1 = 0, .x2 = 3.5, .y2 = 0 }};
    const cross = try build(arena, flipped, Track, &closed);
    try testing.expect(!cross.any());

    // And with no authored exact bond at all the guard is inert.
    var rail_only = loops;
    rail_only[0].explicit_pin = "";
    var inferred = placement;
    inferred.loops = &rail_only;
    const none = try build(arena, inferred, Track, &closed);
    try testing.expect(!none.any());
    try testing.expect(!frozen(none, closed[0]));
}

// spec: placement/bypass-intent - leg membership survives the chain rebuild and junction splits that cleanup passes perform
test "a split or refused leg track is still recognised as leg copper" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [3]optimizer.Part = undefined;
    var loops: [2]optimizer.Loop = undefined;
    const nets = [_]optimizer.FlatNet{.{ .name = "VIN", .pins = &.{} }};
    const placement = twoBondPlacement(&parts, &loops, &nets);

    const tracks = [_]Track{.{ .x1 = -0.5, .y1 = 0, .x2 = 3.5, .y2 = 0 }};
    const legs = try build(arena, placement, Track, &tracks);
    try testing.expectEqual(@as(usize, 1), legs.segs.len);
    // A junction canonicalization splits the leg in two; both halves lie on it.
    try testing.expect(frozen(legs, Track{ .x1 = -0.5, .y1 = 0, .x2 = 1, .y2 = 0 }));
    try testing.expect(frozen(legs, Track{ .x1 = 1, .y1 = 0, .x2 = 3.5, .y2 = 0 }));
    // Copper on another layer, or a parallel run one clearance away, is not.
    try testing.expect(!frozen(legs, Track{ .x1 = -0.5, .y1 = 0, .x2 = 3.5, .y2 = 0, .layer = 1 }));
    try testing.expect(!frozen(legs, Track{ .x1 = -0.5, .y1 = 0.2, .x2 = 3.5, .y2 = 0.2 }));
}
