//! `(net-class … (match-group "NAME" [(tolerance MM)]))` length matching: which
//! nets must come out the same routed length, how long each one actually is, and
//! how much slack the shortest member still has.
//!
//! A bus is length-matched when the flight time of every member agrees closely
//! enough that one clock edge samples them all. That is a length constraint
//! ACROSS nets, and nothing else in the router expresses one: `(diff-pair …)`
//! matches exactly two legs and couples their geometry as it goes, while a
//! twelve-bit address bus needs no coupling at all — only agreement on total
//! length. So the group is named, not derived: `NAME` is the join key rather
//! than the class, and two classes carrying different trace geometry may name
//! the same group (a bus split across a wide stretch and a narrow one is one
//! constraint, not two).
//!
//! Everything about a group lives here — the profile merge that resolves the
//! declaration, the grouping, the length measure, and the routing-order tweak —
//! so the router, `drc_match.zig` (the post-route warning) and the facts
//! endpoint all read the SAME resolution and the same number. It deliberately
//! knows nothing about `router`'s or `drc`'s types: copper arrives as plain
//! geometry, which is what lets the router import this without a cycle.
//!
//! What it does NOT do is lengthen anything. Measuring is the whole contract; a
//! pass that inserts serpentine copper to close a spread would sit on top of
//! these numbers and needs a legality probe this codebase does not yet expose
//! outside `router.zig`.
//!
//! **The measure.** A member's length is its EFFECTIVE copper length
//! (`copper_length` — shortest path over the merged copper, so a retrace or a
//! spur is not counted as spent budget), with every via barrel charged
//! `viaLengthMm`. Unlike a differential pair, whose two legs hop layers together
//! so the barrels cancel out of the skew, one group member may cross layers
//! twice and another not at all — so the z-travel is real, uncancelled
//! difference between them and has to be in the number.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const copper_length = @import("copper_length.zig");
const geometry = @import("geometry.zig");
const env = @import("../eval/env.zig");

const FlatNet = optimizer.FlatNet;
const NetRule = optimizer.NetRule;

/// Allowed max−min routed-length spread (mm) for a group whose declaration
/// carries no `(tolerance MM)`. Half a millimetre is roughly 3.4 ps of flight
/// time in FR-4 stripline (~6.7 ps/mm) — tight enough to catch a leg that took
/// a visibly different route, loose enough that grid quantization and a bend or
/// two never trip it. An author with a real timing budget declares theirs.
pub const default_tolerance_mm: f64 = 0.5;

/// Fab-standard finished board thickness (mm), used as the via z-travel when the
/// design declares no `(stackup … (thickness MM))`. The same fallback the Gerber
/// job file already applies, so one board reports one thickness everywhere.
pub const default_board_thickness_mm: f64 = 1.6;

/// The path length (mm) one via barrel traversal adds to a net.
///
/// A through via's signal does not teleport between faces: it travels the
/// barrel, and the standard length-matching practice in every PCB tool that
/// does this (Altium's 3D/`Z`-axis length, Allegro's z-axis delay, the DDR
/// routing guidelines that popularized it) is to add that physical z-length to
/// the 2D trace length. netlisp's router emits only THROUGH vias — `router.Via`
/// carries no layer span, so every barrel spans the whole stack — which makes
/// the travel exactly the board thickness, with no partial-barrel case to
/// distinguish. `board_thickness_mm` is `BoardRules.board_thickness` (0 when the
/// design declares no stackup, which falls back to the fab standard).
pub fn viaLengthMm(board_thickness_mm: f64) f64 {
    return if (board_thickness_mm > 0) board_thickness_mm else default_board_thickness_mm;
}

/// One resolved length-matching group: the authored name, the spread its members
/// must stay inside, and their net indices (into the design's flattened `nets`,
/// ascending). Only groups with at least two members are produced — one net
/// agrees with itself trivially.
pub const Group = struct {
    name: []const u8,
    tolerance_mm: f64,
    members: []const usize,
};

/// One member's measured routed length.
pub const Member = struct {
    /// Index into the design's flattened `nets`.
    net_i: usize,
    /// Effective routed length (mm), via barrels included. 0 when `!routed`.
    length_mm: f64,
    /// Via barrels on this net's copper — reported because they are the part of
    /// the length a reader cannot see in the 2D picture.
    vias: usize,
    /// False when the net carries no copper at all. An unrouted member is not a
    /// mismatch, it is unfinished work, so it is excluded from the comparison
    /// rather than counted as length zero.
    routed: bool,
};

/// The min / max / spread (mm) of a group's ROUTED member lengths. All zero
/// while fewer than two members carry copper.
pub const Span = struct {
    min_mm: f64 = 0,
    max_mm: f64 = 0,
    /// `max_mm − min_mm` — the number the tolerance is judged against.
    spread_mm: f64 = 0,
};

/// The two nets bracketing a group's span. Both or neither: they are set
/// together the moment a second member carries copper, so a caller that has one
/// always has the other.
pub const Extremes = struct { longest: usize, shortest: usize };

/// One group's measurement: the declaration it measures, every member's length,
/// and the span across the ROUTED ones. `span` is all zero and `extremes` null
/// below two routed members (`comparable` is then false and there is nothing to
/// judge yet).
pub const Report = struct {
    /// The declaration being measured — its name, tolerance and member indices.
    group: Group,
    /// Each member's measured length, in `group.members` order.
    members: []const Member,
    /// How many members carry copper.
    routed_members: usize = 0,
    span: Span = .{},
    /// The nets whose lengths bracket the span, so a report can name who to
    /// shorten and who to lengthen instead of quoting a bare number.
    extremes: ?Extremes = null,

    /// Whether at least two members carry copper, i.e. whether there is a spread
    /// to compare against the tolerance at all.
    pub fn comparable(self: Report) bool {
        return self.routed_members >= 2;
    }

    /// Whether the measured spread fits the group's budget. Vacuously true for
    /// a group that is not yet `comparable` — a half-routed board must not be
    /// reported as mismatched.
    pub fn withinTolerance(self: Report) bool {
        return !self.comparable() or self.span.spread_mm <= self.group.tolerance_mm;
    }
};

/// Where one candidate class declaration sits in the hierarchy: nesting `depth`
/// (0 = the board root) and authored `order` within that level. Lower is better,
/// so a board's own declaration outranks a module's fallback.
pub const Rank = struct { depth: u16, order: u32 };

/// Best-declaration bookkeeping across a `mergeProfile` walk. The group name and
/// the tolerance rank INDEPENDENTLY, which is the whole point: a module names
/// the group its bus belongs to, while the destination board — which alone knows
/// the stackup and the timing budget — supplies the spread it will accept, and
/// an all-or-nothing merge would have to drop one of them.
pub const Merge = struct {
    group: Rank = worst_rank,
    tolerance: Rank = worst_rank,
};

/// The rank every field starts at: worse than any real declaration.
const worst_rank: Rank = .{ .depth = std.math.maxInt(u16), .order = std.math.maxInt(u32) };

/// Merge one candidate class profile's `(match-group …)` into `out`, keeping the
/// best-ranked declaration of each field seen so far. Lives here rather than in
/// `optimizer.profileRule` so the resolution and the consumption of a group sit
/// in one file.
pub fn mergeProfile(out: *env.ClassMatch, cand: env.ClassMatch, at: Rank, st: *Merge) void {
    if (cand.group.len > 0 and better(at, st.group)) {
        out.group = cand.group;
        st.group = at;
    }
    if (cand.tolerance_mm > 0 and better(at, st.tolerance)) {
        out.tolerance_mm = cand.tolerance_mm;
        st.tolerance = at;
    }
}

/// Whether `cand` outranks `best`: shallower wins, then earlier in authored
/// order — the same precedence every other net-class profile field uses.
fn better(cand: Rank, best: Rank) bool {
    return cand.depth < best.depth or (cand.depth == best.depth and cand.order < best.order);
}

/// Resolve every `(match-group …)` declaration into `Group` records, in
/// first-appearance order by net index (so the report order is stable against
/// anything but a netlist edit). Groups are joined case-insensitively on the
/// authored NAME across classes.
///
/// A group's tolerance is the TIGHTEST any member declares. Two classes naming
/// one group with different budgets describe one physical constraint stated
/// twice, and the tighter statement is the requirement; taking the minimum also
/// makes the answer independent of which member the walk reaches first. A group
/// nobody gave a tolerance takes `default_tolerance_mm`.
///
/// Empty when no class declares a group, which is what makes every consumer a
/// no-op on the boards that declare none.
pub fn resolve(
    arena: std.mem.Allocator,
    nets: []const FlatNet,
    rules: []const NetRule,
) std.mem.Allocator.Error![]const Group {
    var out: std.ArrayList(Group) = .empty;
    var members: std.ArrayList(std.ArrayList(usize)) = .empty;
    const n = @min(nets.len, rules.len);
    for (0..n) |net_i| {
        const name = rules[net_i].match.group;
        if (name.len == 0) continue;
        const gi = indexOfGroup(out.items, name) orelse blk: {
            try out.append(arena, .{ .name = name, .tolerance_mm = 0, .members = &.{} });
            try members.append(arena, .empty);
            break :blk out.items.len - 1;
        };
        try members.items[gi].append(arena, net_i);
        out.items[gi].tolerance_mm = tighter(out.items[gi].tolerance_mm, rules[net_i].match.tolerance_mm);
    }
    return finishGroups(arena, out.items, members.items);
}

/// Attach each group's member list, apply the default tolerance, and drop the
/// single-member groups (a lone net has nothing to match against).
fn finishGroups(
    arena: std.mem.Allocator,
    groups: []Group,
    members: []std.ArrayList(usize),
) std.mem.Allocator.Error![]const Group {
    var out: std.ArrayList(Group) = .empty;
    for (groups, members) |g, m| {
        if (m.items.len < 2) continue;
        try out.append(arena, .{
            .name = g.name,
            .tolerance_mm = if (g.tolerance_mm > 0) g.tolerance_mm else default_tolerance_mm,
            .members = m.items,
        });
    }
    return out.toOwnedSlice(arena);
}

/// The tighter of two candidate tolerances, treating 0 as "not declared".
fn tighter(have: f64, cand: f64) f64 {
    if (!(cand > 0)) return have;
    if (!(have > 0)) return cand;
    return @min(have, cand);
}

/// Index of the group named `name` (case-insensitively), or null.
fn indexOfGroup(groups: []const Group, name: []const u8) ?usize {
    for (groups, 0..) |g, i| {
        if (std.ascii.eqlIgnoreCase(g.name, name)) return i;
    }
    return null;
}

/// Effective routed length (mm) of one net's copper, via barrels charged
/// `via_len_mm`, measured between the copper's two most distant ends. Null when
/// the net has no copper, or when its copper does not connect its own extremes
/// (a half-routed or islanded net has no single length to report, and inventing
/// one from the segment sum would over-report every island).
pub fn netLengthMm(
    arena: std.mem.Allocator,
    segs: []const copper_length.Seg,
    vias: []const copper_length.Via,
    via_len_mm: f64,
) std.mem.Allocator.Error!?f64 {
    if (segs.len == 0) return null;
    const ends = copper_length.farthestEnds(segs);
    return copper_length.shortestVia(arena, segs, vias, ends[0], ends[1], via_len_mm);
}

/// Summarize one group's measured members into a `Report`: the span over the
/// routed ones and which nets those extremes belong to.
pub fn summarize(group: Group, members: []const Member) Report {
    var out = Report{ .group = group, .members = members };
    var lo: ?Member = null;
    var hi: ?Member = null;
    for (members) |m| {
        if (!m.routed) continue;
        if (hi == null or m.length_mm > hi.?.length_mm) hi = m;
        if (lo == null or m.length_mm < lo.?.length_mm) lo = m;
        out.routed_members += 1;
    }
    if (out.routed_members < 2) return out;
    const long = hi.?;
    const short = lo.?;
    out.span = .{ .min_mm = short.length_mm, .max_mm = long.length_mm, .spread_mm = long.length_mm - short.length_mm };
    out.extremes = .{ .longest = long.net_i, .shortest = short.net_i };
    return out;
}

/// Re-deal each group's members across the slots they ALREADY occupy in the
/// router's priority order, longest expected route first.
///
/// A maze router with no rip-up gives the first net through a channel the short
/// path and leaves the later ones to detour. Inside a length-matched group that
/// ordering is exactly backwards: the member that will end up longest sets the
/// target every other member has to reach, so it should claim its path while the
/// board is still open, and the short members — the ones with slack to spend —
/// should be the ones that detour. `est` is the per-net expected length (the
/// caller's HPWL estimate); ties keep their original slot, so the result is a
/// deterministic function of the order that came in.
///
/// Only the group's own slots are touched: every other net keeps its exact
/// position, and the returned slice is `order` itself when no group is declared,
/// which is what makes the whole pass byte-identical on a board without one.
pub fn reorder(
    arena: std.mem.Allocator,
    order: []const usize,
    groups: []const Group,
    est: []const f64,
) std.mem.Allocator.Error![]const usize {
    if (groups.len == 0) return order;
    const out = try arena.dupe(usize, order);
    var slots: std.ArrayList(usize) = .empty;
    const seats = try arena.alloc(Seat, order.len);
    for (groups) |g| {
        slots.clearRetainingCapacity();
        try collectSlots(arena, &slots, order, g);
        if (slots.items.len < 2) continue;
        dealLongestFirst(out, slots.items, order, est, seats);
    }
    return out;
}

/// `reorder` against a live placement: builds each grouped net's expected-length
/// estimate from the poses, then re-deals the groups' slots. Returns `order`
/// itself the moment no group is declared, which is the whole board corpus today
/// and is what makes the router's routed result byte-identical there.
///
/// The estimate is the half-perimeter of the net's pad bounding box (HPWL) — the
/// placement objective's own wirelength surrogate. It is deliberately a cheap
/// PRE-route number: the ordering has to be decided before any copper exists, so
/// there is nothing better to ask, and being wrong only costs the group the
/// benefit of the ordering, never its correctness.
pub fn orderFor(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    order: []const usize,
) std.mem.Allocator.Error![]const usize {
    if (placement.match_groups.len == 0) return order;
    const est = try arena.alloc(f64, placement.nets.len);
    @memset(est, 0);
    for (placement.match_groups) |g| {
        for (g.members) |net_i| {
            if (net_i < placement.nets.len) est[net_i] = hpwlMm(placement, idx_of, placement.nets[net_i]);
        }
    }
    return reorder(arena, order, placement.match_groups, est);
}

/// Half-perimeter (mm) of one net's pad bounding box at the current poses — 0
/// for a net whose pads cannot be located, which simply leaves it at the back of
/// its group's ordering.
fn hpwlMm(
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    n: FlatNet,
) f64 {
    var box: ?[4]f64 = null;
    for (n.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        if (pi >= placement.parts.len) continue;
        const part = placement.parts[pi];
        const pad = padNamed(part, pin.pin) orelse continue;
        const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
        box = if (box) |b|
            .{ @min(b[0], c[0]), @min(b[1], c[1]), @max(b[2], c[0]), @max(b[3], c[1]) }
        else
            .{ c[0], c[1], c[0], c[1] };
    }
    const b = box orelse return 0;
    return (b[2] - b[0]) + (b[3] - b[1]);
}

/// The footprint pad named `pin` on `part`, or null when absent.
fn padNamed(part: optimizer.Part, pin: []const u8) ?geometry.Pad {
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, pin)) return pad;
    }
    return null;
}

/// Positions in `order` held by members of `g`, ascending.
fn collectSlots(
    arena: std.mem.Allocator,
    slots: *std.ArrayList(usize),
    order: []const usize,
    g: Group,
) std.mem.Allocator.Error!void {
    for (order, 0..) |net_i, slot| {
        for (g.members) |m| {
            if (m != net_i) continue;
            try slots.append(arena, slot);
            break;
        }
    }
}

/// Sorting key for one group slot: the net that sits there and its estimate.
const Seat = struct { slot: usize, net_i: usize, est: f64 };

/// Write the group's nets back into `slots` (which are already ascending) with
/// the largest estimate first, ties keeping their incoming slot order. `scratch`
/// is caller-owned sort space at least `slots.len` long.
fn dealLongestFirst(
    out: []usize,
    slots: []const usize,
    order: []const usize,
    est: []const f64,
    scratch: []Seat,
) void {
    const seats = scratch[0..slots.len];
    for (slots, seats) |slot, *seat| {
        const net_i = order[slot];
        seat.* = .{ .slot = slot, .net_i = net_i, .est = if (net_i < est.len) est[net_i] else 0 };
    }
    std.mem.sort(Seat, seats, {}, longerFirst);
    for (slots, seats) |slot, seat| out[slot] = seat.net_i;
}

/// Larger estimate first; equal estimates keep their incoming slot order, so the
/// sort is a deterministic function of the order that came in.
fn longerFirst(_: void, a: Seat, b: Seat) bool {
    if (a.est != b.est) return a.est > b.est;
    return a.slot < b.slot;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn net(name: []const u8) FlatNet {
    return .{ .name = name, .pins = &.{} };
}

// spec: placement/router - a (match-group …) joins nets across classes on the authored name and takes the tightest declared tolerance
test "resolve joins one group across two classes and drops a lone member" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // "addr" is declared by TWO classes with different trace geometry and two
    // different tolerances; "solo" has one member; SPARE declares nothing.
    const nets = [_]FlatNet{ net("A0"), net("A1"), net("A2"), net("LONE"), net("SPARE") };
    const rules = [_]NetRule{
        .{ .class = .{ .name = "addr-wide" }, .match = .{ .group = "addr", .tolerance_mm = 0.8 } },
        .{ .class = .{ .name = "addr-narrow" }, .match = .{ .group = "ADDR", .tolerance_mm = 0.3 } },
        .{ .class = .{ .name = "addr-narrow" }, .match = .{ .group = "addr" } },
        .{ .class = .{ .name = "misc" }, .match = .{ .group = "solo", .tolerance_mm = 1.0 } },
        .{},
    };
    const groups = try resolve(arena, &nets, &rules);
    try testing.expectEqual(@as(usize, 1), groups.len); // "solo" dropped: one member
    try testing.expectEqualStrings("addr", groups[0].name);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, groups[0].members);
    try testing.expectEqual(@as(f64, 0.3), groups[0].tolerance_mm); // the TIGHTER budget wins

    // No declaration anywhere → no groups, so every consumer stays on its
    // legacy path.
    const bare = [_]NetRule{ .{}, .{}, .{}, .{}, .{} };
    try testing.expectEqual(@as(usize, 0), (try resolve(arena, &nets, &bare)).len);
}

// spec: placement/router - a match-group name and its tolerance resolve independently through the class hierarchy
test "mergeProfile takes the group from one level of the hierarchy and the tolerance from another" {
    // The MODULE (depth 1) names the group its bus belongs to; the destination
    // BOARD (depth 0), which alone knows the stackup and the timing budget,
    // supplies the spread. Neither declaration is complete on its own, so an
    // all-or-nothing merge would have to throw one of them away.
    var out = env.ClassMatch{};
    var st = Merge{};
    mergeProfile(&out, .{ .group = "ddr-addr" }, .{ .depth = 1, .order = 1 }, &st);
    mergeProfile(&out, .{ .tolerance_mm = 0.15 }, .{ .depth = 0, .order = 0 }, &st);
    try testing.expectEqualStrings("ddr-addr", out.group);
    try testing.expectEqual(@as(f64, 0.15), out.tolerance_mm);

    // A deeper (worse-ranked) declaration never overwrites a shallower one, and
    // an empty candidate never clears what is already there.
    mergeProfile(&out, .{ .group = "other", .tolerance_mm = 9 }, .{ .depth = 5, .order = 0 }, &st);
    mergeProfile(&out, .{}, .{ .depth = 0, .order = 0 }, &st);
    try testing.expectEqualStrings("ddr-addr", out.group);
    try testing.expectEqual(@as(f64, 0.15), out.tolerance_mm);
}

// spec: placement/router - an undeclared (match-group) tolerance falls back to the module default
test "resolve applies the default tolerance when no member declares one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]FlatNet{ net("D0"), net("D1") };
    const rules = [_]NetRule{
        .{ .class = .{ .name = "data" }, .match = .{ .group = "data" } },
        .{ .class = .{ .name = "data" }, .match = .{ .group = "data" } },
    };
    const groups = try resolve(arena, &nets, &rules);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(default_tolerance_mm, groups[0].tolerance_mm);
}

// spec: placement/router - a match-group length charges each via barrel the board thickness, defaulting to the fab standard when no stackup declares one
test "netLengthMm charges the via barrel and viaLengthMm falls back to the fab standard" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 5 mm on layer 0, a barrel, 5 mm on layer 1: 10 mm of trace plus one hop.
    const segs = [_]copper_length.Seg{
        .{ .a = .{ 0, 0 }, .b = .{ 5, 0 }, .layer = 0 },
        .{ .a = .{ 5, 0 }, .b = .{ 10, 0 }, .layer = 1 },
    };
    const vias = [_]copper_length.Via{.{ .at = .{ 5, 0 } }};
    const with_barrel = (try netLengthMm(arena, &segs, &vias, viaLengthMm(0))).?;
    try testing.expectApproxEqAbs(10 + default_board_thickness_mm, with_barrel, 1e-9);
    // A declared stackup thickness is used verbatim…
    try testing.expectApproxEqAbs(@as(f64, 0.8), viaLengthMm(0.8), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10.8), (try netLengthMm(arena, &segs, &vias, viaLengthMm(0.8))).?, 1e-9);
    // …and copper with no path between its own extremes reports no length at all.
    try testing.expect((try netLengthMm(arena, &segs, &.{}, viaLengthMm(0))) == null);
    try testing.expect((try netLengthMm(arena, &.{}, &.{}, viaLengthMm(0))) == null);
}

// spec: placement/router - a match group's spread is measured over its routed members only, and an unroutable member never reads as a mismatch
test "summarize brackets the spread by net and stays quiet below two routed members" {
    const group = Group{ .name = "addr", .tolerance_mm = 0.5, .members = &.{ 3, 4, 5 } };
    const measured = [_]Member{
        .{ .net_i = 3, .length_mm = 20.0, .vias = 0, .routed = true },
        .{ .net_i = 4, .length_mm = 22.5, .vias = 2, .routed = true },
        .{ .net_i = 5, .length_mm = 0, .vias = 0, .routed = false },
    };
    const rep = summarize(group, &measured);
    try testing.expectEqual(@as(usize, 2), rep.routed_members);
    try testing.expectApproxEqAbs(@as(f64, 2.5), rep.span.spread_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20.0), rep.span.min_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 22.5), rep.span.max_mm, 1e-9);
    try testing.expectEqual(@as(usize, 4), rep.extremes.?.longest);
    try testing.expectEqual(@as(usize, 3), rep.extremes.?.shortest);
    try testing.expect(rep.comparable());
    try testing.expect(!rep.withinTolerance());

    // One routed member: nothing to compare, so no spread and no mismatch.
    const half = [_]Member{
        .{ .net_i = 3, .length_mm = 20.0, .vias = 0, .routed = true },
        .{ .net_i = 4, .length_mm = 0, .vias = 0, .routed = false },
    };
    const quiet = summarize(group, &half);
    try testing.expect(!quiet.comparable());
    try testing.expectEqual(@as(f64, 0), quiet.span.spread_mm);
    try testing.expectEqual(@as(?Extremes, null), quiet.extremes);
    try testing.expect(quiet.withinTolerance());
}

// spec: placement/router - within a match group the router routes the longest-expected member first, leaving every other net's slot untouched
test "reorder deals a group's own slots longest-first and returns the input when no group exists" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Nets 1, 3, 4 form a group and sit at slots 1, 3, 4. Their estimates say
    // net 4 is longest and net 3 shortest, so the group's slots must read
    // 4, 1, 3 while slots 0, 2, 5 keep nets 0, 2, 5 exactly.
    const order = [_]usize{ 0, 1, 2, 3, 4, 5 };
    const est = [_]f64{ 99, 20, 99, 10, 30, 99 };
    const groups = [_]Group{.{ .name = "addr", .tolerance_mm = 0.5, .members = &.{ 1, 3, 4 } }};
    const out = try reorder(arena, &order, &groups, &est);
    try testing.expectEqualSlices(usize, &.{ 0, 4, 2, 1, 3, 5 }, out);

    // Equal estimates keep their incoming slot order (determinism), and no
    // group at all returns the caller's own slice — byte-identical routing.
    const flat = [_]f64{ 1, 1, 1, 1, 1, 1 };
    try testing.expectEqualSlices(usize, &order, try reorder(arena, &order, &groups, &flat));
    try testing.expectEqual(order[0..].ptr, (try reorder(arena, &order, &.{}, &est)).ptr);
}

// spec: placement/router - a match group whose members are absent from the routing order is left alone
test "reorder skips a group with fewer than two nets in the order" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Net 7 is plane-carried / disabled, so only net 2 of the group is in the
    // order — there is no pair of slots to swap and the order must survive.
    const order = [_]usize{ 0, 2, 5 };
    const est = [_]f64{ 0, 0, 1, 0, 0, 9, 0, 50 };
    const groups = [_]Group{.{ .name = "clk", .tolerance_mm = 0.2, .members = &.{ 2, 7 } }};
    try testing.expectEqualSlices(usize, &order, try reorder(arena, &order, &groups, &est));
}
