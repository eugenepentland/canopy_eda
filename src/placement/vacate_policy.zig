//! Which foreign copper a walled-in net's transaction may VACATE, and in what
//! order — the nomination policy behind the gap closer's wholesale re-route.
//!
//! `mcp_close_gaps.zig`'s vacate phase already takes whole nets off the board,
//! routes a stuck seed across the freed channel, and puts the displaced nets
//! back inside one all-or-nothing transaction. What it could not do is pick the
//! right nets. Its own predicate (`Work.movable`) asks "is this copper safe to
//! restructure?" and answers no for anything a plane or a pour carries — so the
//! cheapest copper on the board to move is the one category it never nominates.
//!
//! That is backwards, and the board says so. A rail whose pads are joined by a
//! pour is joined by the pour whether or not a single track comes back: strip
//! its tracks and the net stays WHOLE, because `stripNets` only ever removes
//! tracks and vias — the zones ride through the transaction untouched. Measured
//! on barracuda's `auto-full-v2`: `GND` sits in two islands behind a 2.3 mm
//! bridge the maze cannot walk, the LDO pocket's bottom layer is held by 44
//! elements of `V_6VA` (poured on both `B.Cu` and `In2.Cu`), and the standard
//! tier nominates only the two short control stubs beside it — which is exactly
//! the move a human tries first, and exactly the move that does not work. Adding
//! the poured rail to the same transaction closes the board.
//!
//! So this module ranks candidates by RESTORE CHEAPNESS rather than by routing
//! priority:
//!
//!   1. `pour_carried` — a plane/pour holds the net's connectivity, so removing
//!      its tracks cannot open it and putting them back is optional.
//!   2. `short_stub` — few elements, so re-laying it is a short maze walk.
//!   3. `pair_recouple` — a declared `(diff-pair …)` whose caller will rip BOTH
//!      legs and re-lay them with the coupled constructor. Dearest of the
//!      three, and admitted only when the caller says so (`NetFacts.pair_recouple`):
//!      a pair is the copper that seals a corridor precisely because nothing
//!      else may move it, and "unrippable" is a policy answer rather than a
//!      physical one when the pair's contract is spacing and skew rather than
//!      an absolute position.
//!
//! and nothing else is nominated at all. The refusals are as much the point as
//! the picks: they are reported to the caller, so an agent reading a rolled-back
//! transaction can see which copper the tier declined to touch and why.

const std = @import("std");

/// Why a net is cheap to put back. Ordered by cheapness — `pour_carried` first,
/// because its restoration is underwritten by copper the transaction never
/// touches.
pub const Kind = enum {
    /// A plane or pour on some layer already joins this net's pads, so its
    /// tracks are a convenience rather than its connectivity.
    pour_carried,
    /// Few enough elements that re-laying the whole net is a short maze walk.
    short_stub,
    /// A declared `(diff-pair …)` member whose transaction will rip BOTH legs
    /// and re-lay them with the coupled constructor. Last, because it is the
    /// dearest restore this policy admits: two nets' copper, a construction
    /// that may decline outright, and a geometry contract the caller has to
    /// re-prove afterwards (see `NetFacts.pair_recouple`).
    pair_recouple,
    /// A net whose `(net-class … (priority …))` outranks the seed's, lifted
    /// CORRIDOR-ONLY by a caller that says it will do exactly that
    /// (`Rank.negotiable`). Dearest of all and therefore last: the
    /// other three are cheapness arguments about copper the policy was always
    /// willing to move, while this one negotiates a guard — so it is nominated
    /// only after every cheaper occupant of the corridor, and only by the tier
    /// that has already refused with them.
    rank_lifted,
};

/// Why a net near the corridor was NOT nominated. Reported verbatim to the
/// caller: "the tier looked at this copper and declined it, for this reason" is
/// the difference between a diagnosable rollback and a silent one.
pub const Refusal = enum {
    /// The seed itself — the net the corridor is being vacated FOR.
    seed,
    /// Ground. Never displaced: it is the board's reference copper and the one
    /// net whose islands the pass is usually trying to join.
    ground,
    /// A `(net-class … (diff-pair …))` member. Its geometry is a coupled pair
    /// placed deliberately; a re-route would not reproduce it.
    diff_pair,
    /// A `(net-class … (max-freq …))` RF net. Same reason, plus a bend/escape
    /// discipline the finishing maze does not honour.
    rf_max_freq,
    /// Some via on the board is an RF via fence flanking THIS net (an `f`-tagged
    /// via, see `pcb_layout_page.SavedVia`). Its fence was generated around the
    /// trace that is here now; moving the trace orphans the fence.
    fenced,
    /// The net is itself still open. Displacing the pass's own unfinished work
    /// hands its corridor away — the `rippedAnOpenNet` lesson, which cost
    /// measured nets when it was relaxed.
    not_whole,
    /// A `(net-class … (priority …))` strictly above the seed's, on copper no
    /// pour underwrites and no caller offered to lift corridor-only. See `judge`
    /// for why the pour case is exempt and `Rank.negotiable` for the
    /// one tier that negotiates the rest.
    outranks_seed,
    /// Movable and in the way, but neither poured nor short — restoring it is a
    /// full re-route, which is the cost this tier exists to avoid.
    not_cheap,
    /// Cheap and eligible, but the per-transaction net cap was already full.
    capped,
    /// Cheap and eligible, but taking it would push the transaction past its
    /// copper budget (see `Limits.max_total_elements`). Skipped rather than
    /// stopping the scan, so the small candidates behind it still get in.
    over_budget,
};

/// A candidate's verdict.
pub const Verdict = union(enum) {
    accept: Kind,
    refuse: Refusal,
};

/// How a net's `(diff-pair …)` membership bears on the transaction judging it.
///
/// The one protection that is CONDITIONAL, and the condition is a property of
/// the caller rather than of the board: a pair's contract is spacing and skew,
/// not an absolute position, so whether its copper may move depends entirely on
/// whether the transaction can re-lay it through the coupled construction that
/// reproduces that contract.
pub const PairGuard = enum {
    /// Not a declared pair member.
    none,
    /// A declared pair member this transaction has no way to re-lay coupled —
    /// it would rip one leg, maze it alone, and hand back two nearly-parallel
    /// traces where the class promised exact offsets, mitred bends, paired vias
    /// and matched fans. Refused, which is the default and the historical
    /// behaviour.
    protected,
    /// A declared pair member whose transaction will rip BOTH legs and re-lay
    /// them with the coupled constructor, re-proving the pair's own geometry
    /// before it commits. Only a caller that will actually do that work may say
    /// so (`target_unblock.pairFacts`); this policy takes it at its word and
    /// ranks the pair as the dearest restore it admits.
    recouplable,
};

/// The reasons a net may never be vacated, whatever its cheapness. Grouped
/// because `judge` treats them as ONE gate that runs ahead of every cheapness
/// question: this copper is either the board's reference or a shape placed
/// deliberately, and no argument about restore cost may override it.
pub const Protected = struct {
    /// The net is ground by name.
    ground: bool = false,
    /// A resolved `(diff-pair …)` member, and what this transaction may do
    /// about it (see `PairGuard`).
    diff_pair: PairGuard = .none,
    /// The net's class declares `(max-freq …)`.
    rf: bool = false,
    /// Some via on the board flanks this net as an RF fence.
    fenced: bool = false,

    /// The refusal this net's protections earn, or null when none apply. The
    /// order is the reporting order — the most specific reason a reader would
    /// name first.
    ///
    /// A `.recouplable` pair earns no refusal HERE and is accepted in `judge`
    /// below — but ground, `(max-freq …)` RF and a via fence still fire on it,
    /// because the coupled constructor re-proves spacing and skew and says
    /// nothing whatever about a reference plane, a bend discipline or a fence
    /// generated around the trace that is there now.
    pub fn refusal(self: Protected) ?Refusal {
        if (self.ground) return .ground;
        if (self.diff_pair == .protected) return .diff_pair;
        if (self.rf) return .rf_max_freq;
        if (self.fenced) return .fenced;
        return null;
    }
};

/// A net's authored routing rank as the priority guard reads it.
///
/// The number and the permission travel together because they are one question:
/// the guard fires on the number, and a caller that will re-lay the copper the
/// guard protects answers it here rather than anywhere else.
pub const Rank = struct {
    /// The net class's `(priority …)`; 0 for an unclassed net.
    priority: u32 = 0,
    /// The caller will lift this net CORRIDOR-ONLY and put it back inside the
    /// same all-or-nothing transaction, so the priority guard may be negotiated
    /// for it (see `judge`).
    ///
    /// Set by a driver that will actually do that work and has already measured
    /// what the lift takes (`target_unblock.rankFacts`); this policy takes it at
    /// its word, exactly as it does for `PairGuard.recouplable`. Default false,
    /// so every caller that does not say so keeps today's refusal.
    negotiable: bool = false,
};

/// Everything `judge` needs to know about one net near the seed's corridor.
/// Assembled by the caller from the placement rules, the live copper and the
/// connectivity oracle, so this module stays free of all three.
pub const NetFacts = struct {
    /// Flattened-net index, and the deterministic tie-break for equal ranks.
    net_i: usize,
    /// The never-vacate reasons (see `Protected`).
    protected: Protected = .{},
    /// A plane or a pour on some layer carries this net (see `Kind`).
    pour_carried: bool = false,
    /// The connectivity oracle finds this net in ONE piece right now.
    whole: bool = false,
    /// The net class's authored routing rank, and whether the caller offered to
    /// negotiate it (see `Rank`).
    rank: Rank = .{},
    /// Tracks plus vias currently on the board for this net.
    elements: usize = 0,
    /// Closest approach of this net's copper to one of the seed's island-joining
    /// corridors, in mm.
    dist: f64 = 0,
};

/// The net the corridor is being vacated for.
pub const Seed = struct {
    net_i: usize,
    priority: u32 = 0,
};

/// The tier's bounds. Every one of them exists to keep a transaction small
/// enough that its all-or-nothing gate can plausibly be met.
pub const Limits = struct {
    /// Most nets one cheap transaction vacates. Each has to come back whole in
    /// the same transaction, so a wide subset is both slow and unlikely to
    /// survive the gate. Three is the measured shape of the barracuda case: one
    /// poured rail plus the two control stubs beside it.
    max_nets: usize = 3,
    /// Most elements a net may carry and still count as a `short_stub`. Above
    /// this, re-laying it is a real routing problem rather than a stub walk.
    /// Poured nets are exempt from THIS cap — a pour makes a net's size
    /// irrelevant to whether it comes back whole — but not from the copper
    /// budget below, which is about work rather than risk.
    stub_max_elements: usize = 8,
    /// Total elements one transaction may take off the board.
    ///
    /// The net cap alone bounds the wrong thing. Every displaced net has to be
    /// put back inside a single all-or-nothing gate, so what governs the odds is
    /// how much copper the restore has to re-lay — three nets of two elements
    /// and three nets of fifty are not the same transaction. A pour discounts
    /// the RISK of moving a net (it stays whole with its tracks gone); it does
    /// not discount the WORK.
    ///
    /// Measured on barracuda: the pocket holds `V_6VA` (44 elements, poured) and
    /// `V_5VA` (53, poured) beside two 2-4 element control stubs. Ranked on
    /// cheapness alone the two rails fill a 3-net cap and squeeze the stubs out,
    /// and the transaction then has to re-lay ~100 elements — `V_5VA` came back
    /// at 80+, re-cutting the pour the seed needed. Under a copper budget the
    /// same corridor yields `V_6VA` + both stubs, which is the subset a human
    /// operator cleared by hand.
    max_total_elements: usize = 64,
};

/// One nominated net, with the cheapness evidence the ranking uses.
pub const Nomination = struct {
    net_i: usize,
    kind: Kind,
    elements: usize,
    dist: f64,
};

/// One refused net and why, for the caller's decision trace.
pub const Refused = struct {
    net_i: usize,
    why: Refusal,
};

/// What the tier decided about every net near the seed's corridors.
pub const Decision = struct {
    /// The nets to strip, cheapest first — the transaction's routing order after
    /// the seed itself.
    picked: []const Nomination,
    /// Every other net that was near enough to consider, with its reason.
    refused: []const Refused,
};

/// Is this net cheap enough to vacate for `seed`, and if not, why not?
///
/// The order of the refusals is the order of the guarantees. Identity and the
/// deliberate-geometry classes come first because no cheapness argument may
/// override them; `not_whole` next because displacing unfinished work is the
/// one move that measurably LOSES nets; then the priority rule; and only then
/// the cheapness question itself.
///
/// **The priority rule exempts poured copper, deliberately.** A high
/// `(priority …)` declares routing ORDER — "give this rail its channel first" —
/// not "these tracks are sacred"; the copper that genuinely may not be
/// restructured is named by `diff_pair`/`rf_max_freq`, which refuse
/// unconditionally above. And for a poured net the guard has nothing to protect
/// anyway: its connectivity does not depend on the tracks, so the transaction
/// cannot leave it worse off than a pour-fed rail already is. Applying the rule
/// to poured copper would refuse barracuda's `V_6VA` — class `power`,
/// `(priority 3)`, against an unclassed `GND` seed — which is the only net whose
/// removal closes that board.
///
/// **And it is NEGOTIABLE for a caller that will lift corridor-only.** The rule
/// is a heuristic about routing order, not a statement about the copper: the
/// classes that genuinely may not be restructured refuse above it,
/// unconditionally, and none of them moves here. What it protects against is a
/// low-ranked seed helping itself to a high-ranked net's channel and leaving it
/// worse off — and a caller setting `Rank.negotiable` has said it will take only
/// what crosses the corridor, re-lay it in the same transaction, and roll the
/// whole thing back unless every net it named comes back connected. That is a
/// stronger guarantee than the rank rule was ever making, so the rule yields to
/// it and to nothing else.
pub fn judge(f: NetFacts, seed: Seed, lim: Limits) Verdict {
    const one = [_]Seed{seed};
    return judgeAll(f, &one, lim);
}

/// The same judgement against a CLUSTER of seeds — a joint transaction vacates
/// one corridor for several still-open nets at once, and each rule above has
/// exactly one honest generalisation:
///
///   * `.seed` covers EVERY member. A transaction can no more displace one of
///     its own seeds than a single-seed transaction can displace its one seed —
///     that copper is the pass's own unfinished work by definition.
///   * the priority guard is measured against the cluster's HIGHEST authored
///     priority, because the promise it keeps is "never take copper from a net
///     that outranks the net you are taking it FOR", and the transaction is
///     being run for every member. Using the lowest instead would refuse copper
///     a high-priority seed is plainly entitled to merely because a lesser seed
///     rode along in the same cluster.
///
/// Everything else is untouched and shared, which is the point: a joint
/// transaction must never be able to rip copper a single-seed one would have
/// protected.
pub fn judgeAll(f: NetFacts, seeds: []const Seed, lim: Limits) Verdict {
    var top: u32 = 0;
    for (seeds) |s| {
        if (f.net_i == s.net_i) return .{ .refuse = .seed };
        top = @max(top, s.priority);
    }
    if (f.protected.refusal()) |r| return .{ .refuse = r };
    if (!f.whole) return .{ .refuse = .not_whole };
    if (f.pour_carried) return .{ .accept = .pour_carried };
    // The pair's priority exemption, for the same reason the poured one exists:
    // a high `(priority …)` declares routing ORDER, and this copper is not
    // being taken away — it is re-laid by the constructor its own class
    // declared, inside a transaction that rolls back whole unless the pair
    // comes back coupled. A declared pair almost always outranks the stuck
    // control net whose corridor it seals (barracuda: `lvds-ref` priority 5
    // over `control` priority 2), so applying the rule here would refuse every
    // pair negotiation on principle.
    if (f.protected.diff_pair == .recouplable) return .{ .accept = .pair_recouple };
    if (f.rank.priority > top) {
        if (f.rank.negotiable) return .{ .accept = .rank_lifted };
        return .{ .refuse = .outranks_seed };
    }
    if (f.elements > 0 and f.elements <= lim.stub_max_elements) return .{ .accept = .short_stub };
    return .{ .refuse = .not_cheap };
}

/// Restore-cheapness order: poured nets before stubs, then fewer elements,
/// then nearer the corridor, then net index. The last two keys exist only to
/// make the tier deterministic — the same board must nominate the same subset
/// in the same order on every run.
pub fn cheaperFirst(_: void, a: Nomination, b: Nomination) bool {
    if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
    if (a.elements != b.elements) return a.elements < b.elements;
    if (a.dist != b.dist) return a.dist < b.dist;
    return a.net_i < b.net_i;
}

/// Judge every net near the corridor, rank the accepted ones by restore
/// cheapness and keep the cheapest `lim.max_nets`. Everything else lands in
/// `refused` — the ones that lost on the cap carry `.capped`, so a caller can
/// tell "the tier would not touch this" from "the tier ran out of room".
pub fn select(
    alloc: std.mem.Allocator,
    facts: []const NetFacts,
    seed: Seed,
    lim: Limits,
) std.mem.Allocator.Error!Decision {
    const one = [_]Seed{seed};
    return selectMany(alloc, facts, &one, lim);
}

/// `select` for a CLUSTER of seeds (see `judgeAll`): the transaction vacates the
/// union of what stands in several still-open nets' way, ranked and capped by
/// exactly the same restore-cheapness rules. One ranking over the union rather
/// than a ranking per seed, because the bounds that matter — how many nets come
/// off the board, and how much copper has to be re-laid inside one
/// all-or-nothing gate — are properties of the TRANSACTION, not of a seed.
pub fn selectMany(
    alloc: std.mem.Allocator,
    facts: []const NetFacts,
    seeds: []const Seed,
    lim: Limits,
) std.mem.Allocator.Error!Decision {
    var ok: std.ArrayList(Nomination) = .empty;
    defer ok.deinit(alloc);
    var no: std.ArrayList(Refused) = .empty;
    errdefer no.deinit(alloc);
    for (facts) |f| {
        switch (judgeAll(f, seeds, lim)) {
            .accept => |k| try ok.append(alloc, .{
                .net_i = f.net_i,
                .kind = k,
                .elements = f.elements,
                .dist = f.dist,
            }),
            .refuse => |r| try no.append(alloc, .{ .net_i = f.net_i, .why = r }),
        }
    }
    std.mem.sort(Nomination, ok.items, {}, cheaperFirst);
    // Admit greedily under both bounds, SKIPPING an over-budget candidate rather
    // than stopping — a poured rail too big for the budget must not shut out the
    // two-element stubs ranked behind it, which are the rest of the corridor.
    var picked: std.ArrayList(Nomination) = .empty;
    errdefer picked.deinit(alloc);
    var spent: usize = 0;
    for (ok.items) |n| {
        if (picked.items.len >= lim.max_nets) {
            try no.append(alloc, .{ .net_i = n.net_i, .why = .capped });
        } else if (spent + n.elements > lim.max_total_elements) {
            try no.append(alloc, .{ .net_i = n.net_i, .why = .over_budget });
        } else {
            spent += n.elements;
            try picked.append(alloc, n);
        }
    }
    // Owned slices, so a caller on a real allocator can free exactly what it was
    // handed (an arena caller simply drops them).
    return .{
        .picked = try picked.toOwnedSlice(alloc),
        .refused = try no.toOwnedSlice(alloc),
    };
}

// spec: placement/vacate-policy - a pour-carried net is nominated as the cheapest copper to vacate
test "a poured net is accepted as pour_carried" {
    const v = judge(.{ .net_i = 4, .pour_carried = true, .whole = true, .elements = 44 }, .{ .net_i = 1 }, .{});
    try std.testing.expectEqual(Kind.pour_carried, v.accept);
}

// spec: placement/vacate-policy - a pour-carried net outranking the seed is still nominated because the pour underwrites its restoration
test "a poured net whose class outranks the seed is still accepted" {
    const facts = NetFacts{ .net_i = 4, .pour_carried = true, .whole = true, .rank = .{ .priority = 3 }, .elements = 44 };
    try std.testing.expectEqual(Kind.pour_carried, judge(facts, .{ .net_i = 1, .priority = 0 }, .{}).accept);
    // The same net WITHOUT the pour is refused on exactly that priority rule.
    var bare = facts;
    bare.pour_carried = false;
    try std.testing.expectEqual(Refusal.outranks_seed, judge(bare, .{ .net_i = 1, .priority = 0 }, .{}).refuse);
}

// spec: placement/vacate-policy - a net outranking the seed is nominated as rank_lifted when the caller says it will lift it corridor-only, ranks behind every cheaper class, and is refused as before without that claim
test "an outranking net is nominated only under the caller's corridor-lift claim" {
    const seed = Seed{ .net_i = 1, .priority = 0 };
    const rail = NetFacts{ .net_i = 4, .whole = true, .rank = .{ .priority = 4 }, .elements = 30 };
    // Without the claim it is the refusal it has always been.
    try std.testing.expectEqual(Refusal.outranks_seed, judge(rail, seed, .{}).refuse);
    var claimed = rail;
    claimed.rank.negotiable = true;
    try std.testing.expectEqual(Kind.rank_lifted, judge(claimed, seed, .{}).accept);
    // The claim stands down the RANK guard alone. Every protection still
    // refuses ahead of it, and an open net is still the pass's own work.
    for ([_]Protected{
        .{ .ground = true },
        .{ .diff_pair = .protected },
        .{ .rf = true },
        .{ .fenced = true },
    }, [_]Refusal{ .ground, .diff_pair, .rf_max_freq, .fenced }) |p, want| {
        var guarded = claimed;
        guarded.protected = p;
        try std.testing.expectEqual(want, judge(guarded, seed, .{}).refuse);
    }
    var open = claimed;
    open.whole = false;
    try std.testing.expectEqual(Refusal.not_whole, judge(open, seed, .{}).refuse);
    // And a net that does NOT outrank the seed is judged on cheapness exactly
    // as before — the claim never promotes ordinary copper past the stub cap.
    var equal = claimed;
    equal.rank.priority = 0;
    try std.testing.expectEqual(Refusal.not_cheap, judge(equal, seed, .{}).refuse);
    // Dearest class, so it sorts behind every cheaper nomination however much
    // copper that nomination carries and however far off the corridor it lies.
    const lifted = Nomination{ .net_i = 4, .kind = .rank_lifted, .elements = 1, .dist = 0 };
    const dear = Nomination{ .net_i = 9, .kind = .pair_recouple, .elements = 99, .dist = 9 };
    try std.testing.expect(cheaperFirst({}, dear, lifted));
    try std.testing.expect(cheaperFirst({}, .{ .net_i = 9, .kind = .pour_carried, .elements = 99, .dist = 9 }, lifted));
    try std.testing.expect(cheaperFirst({}, .{ .net_i = 9, .kind = .short_stub, .elements = 99, .dist = 9 }, lifted));
}

// spec: placement/vacate-policy - a short whole stub is nominated and a long unpoured net is refused as not cheap
test "stub length decides an unpoured candidate" {
    const seed = Seed{ .net_i = 1 };
    try std.testing.expectEqual(Kind.short_stub, judge(.{ .net_i = 2, .whole = true, .elements = 4 }, seed, .{}).accept);
    try std.testing.expectEqual(Refusal.not_cheap, judge(.{ .net_i = 2, .whole = true, .elements = 40 }, seed, .{}).refuse);
}

// spec: placement/vacate-policy - ground, diff-pair, max-freq RF, fenced and still-open nets are never vacated
test "the guarded classes are refused whatever their cheapness" {
    const seed = Seed{ .net_i = 1 };
    const base = NetFacts{ .net_i = 2, .pour_carried = true, .whole = true, .elements = 1 };
    var g = base;
    g.protected.ground = true;
    try std.testing.expectEqual(Refusal.ground, judge(g, seed, .{}).refuse);
    var d = base;
    d.protected.diff_pair = .protected;
    try std.testing.expectEqual(Refusal.diff_pair, judge(d, seed, .{}).refuse);
    var r = base;
    r.protected.rf = true;
    try std.testing.expectEqual(Refusal.rf_max_freq, judge(r, seed, .{}).refuse);
    var f = base;
    f.protected.fenced = true;
    try std.testing.expectEqual(Refusal.fenced, judge(f, seed, .{}).refuse);
    var o = base;
    o.whole = false;
    try std.testing.expectEqual(Refusal.not_whole, judge(o, seed, .{}).refuse);
    try std.testing.expectEqual(Refusal.seed, judge(.{ .net_i = 1, .whole = true }, seed, .{}).refuse);
}

// spec: placement/vacate-policy - a diff-pair member is nominated as pair_recouple only when the caller will re-lay the whole pair coupled, and the pair's other protections still refuse it
test "a recouplable pair is nominated and an unclaimed one stays refused" {
    const seed = Seed{ .net_i = 1, .priority = 2 };
    // barracuda's shape: `lvds-ref` priority 5 sealing a `control` priority 2
    // net's corridor, 18 elements across the leg — far past `stub_max_elements`.
    const leg = NetFacts{
        .net_i = 4,
        .protected = .{ .diff_pair = .protected },
        .whole = true,
        .rank = .{ .priority = 5 },
        .elements = 18,
    };
    // Without the caller's claim it is the blanket refusal it has always been.
    try std.testing.expectEqual(Refusal.diff_pair, judge(leg, seed, .{}).refuse);
    var claimed = leg;
    claimed.protected.diff_pair = .recouplable;
    try std.testing.expectEqual(Kind.pair_recouple, judge(claimed, seed, .{}).accept);
    // The claim stands down the pair protection ALONE. Ground, `(max-freq …)`
    // RF and a via fence are about copper the coupled constructor re-proves
    // nothing of, so each still refuses a pair that carries it.
    for ([_]Protected{
        .{ .diff_pair = .recouplable, .ground = true },
        .{ .diff_pair = .recouplable, .rf = true },
        .{ .diff_pair = .recouplable, .fenced = true },
    }, [_]Refusal{ .ground, .rf_max_freq, .fenced }) |p, want| {
        var guarded = claimed;
        guarded.protected = p;
        try std.testing.expectEqual(want, judge(guarded, seed, .{}).refuse);
    }
    // And a pair the oracle finds in pieces is still the pass's own unfinished
    // work, claim or no claim.
    var broken = claimed;
    broken.whole = false;
    try std.testing.expectEqual(Refusal.not_whole, judge(broken, seed, .{}).refuse);
}

// spec: placement/vacate-policy - a pair nomination ranks behind every poured net and short stub, so the dearest restore is tried last
test "a pair nomination is ranked last and capped like any other" {
    const facts = [_]NetFacts{
        .{ .net_i = 2, .protected = .{ .diff_pair = .recouplable }, .whole = true, .elements = 18 },
        .{ .net_i = 3, .pour_carried = true, .whole = true, .elements = 44 },
        .{ .net_i = 4, .whole = true, .elements = 2 },
    };
    const d = try select(std.testing.allocator, &facts, .{ .net_i = 1 }, .{});
    defer std.testing.allocator.free(d.picked);
    defer std.testing.allocator.free(d.refused);
    try std.testing.expectEqual(@as(usize, 3), d.picked.len);
    try std.testing.expectEqual(Kind.pour_carried, d.picked[0].kind);
    try std.testing.expectEqual(Kind.short_stub, d.picked[1].kind);
    try std.testing.expectEqual(Kind.pair_recouple, d.picked[2].kind); // dearest last
    // The copper budget governs it exactly as it governs a poured rail: a pair
    // whose two legs are too much metal to re-lay is skipped, not admitted.
    const tight = try select(std.testing.allocator, &facts, .{ .net_i = 1 }, .{ .max_total_elements = 50 });
    defer std.testing.allocator.free(tight.picked);
    defer std.testing.allocator.free(tight.refused);
    try std.testing.expectEqual(@as(usize, 2), tight.picked.len);
    try std.testing.expectEqual(@as(usize, 1), tight.refused.len);
    try std.testing.expectEqual(@as(usize, 2), tight.refused[0].net_i);
    try std.testing.expectEqual(Refusal.over_budget, tight.refused[0].why);
}

// spec: placement/vacate-policy - the cheap tier ranks poured nets ahead of stubs and caps the subset it strips
test "select ranks by cheapness and caps the subset" {
    const facts = [_]NetFacts{
        .{ .net_i = 2, .whole = true, .elements = 6, .dist = 0.1 },
        .{ .net_i = 3, .pour_carried = true, .whole = true, .elements = 44, .dist = 1.9 },
        .{ .net_i = 4, .whole = true, .elements = 2, .dist = 0.5 },
        .{ .net_i = 5, .whole = true, .elements = 3, .dist = 0.2 },
        .{ .net_i = 6, .whole = true, .elements = 99, .dist = 0.3 },
    };
    const d = try select(std.testing.allocator, &facts, .{ .net_i = 1 }, .{});
    defer std.testing.allocator.free(d.picked);
    defer std.testing.allocator.free(d.refused);
    try std.testing.expectEqual(@as(usize, 3), d.picked.len);
    try std.testing.expectEqual(@as(usize, 3), d.picked[0].net_i); // poured first
    try std.testing.expectEqual(@as(usize, 4), d.picked[1].net_i); // then fewest elements
    try std.testing.expectEqual(@as(usize, 5), d.picked[2].net_i);
    var capped: usize = 0;
    var not_cheap: usize = 0;
    for (d.refused) |r| {
        if (r.why == .capped) capped += 1;
        if (r.why == .not_cheap) not_cheap += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), capped); // net 2 lost on the cap
    try std.testing.expectEqual(@as(usize, 1), not_cheap); // net 6 is too long
}

// spec: placement/vacate-policy - a transaction's copper budget skips an oversized poured rail without shutting out the stubs behind it
test "the copper budget skips rather than stops" {
    // Two poured rails rank ahead of two stubs on cheapness; only the smaller
    // rail fits the budget, and the stubs behind it must still get in.
    const facts = [_]NetFacts{
        .{ .net_i = 2, .pour_carried = true, .whole = true, .elements = 44 },
        .{ .net_i = 3, .pour_carried = true, .whole = true, .elements = 53 },
        .{ .net_i = 4, .whole = true, .elements = 2 },
        .{ .net_i = 5, .whole = true, .elements = 4 },
    };
    const d = try select(std.testing.allocator, &facts, .{ .net_i = 1 }, .{});
    defer std.testing.allocator.free(d.picked);
    defer std.testing.allocator.free(d.refused);
    try std.testing.expectEqual(@as(usize, 3), d.picked.len);
    try std.testing.expectEqual(@as(usize, 2), d.picked[0].net_i); // the smaller rail
    try std.testing.expectEqual(@as(usize, 4), d.picked[1].net_i); // stubs still admitted
    try std.testing.expectEqual(@as(usize, 5), d.picked[2].net_i);
    try std.testing.expectEqual(@as(usize, 1), d.refused.len);
    try std.testing.expectEqual(@as(usize, 3), d.refused[0].net_i); // the 53-element rail
    try std.testing.expectEqual(Refusal.over_budget, d.refused[0].why);
}

// spec: placement/vacate-policy - the cheap tier's nomination order is deterministic for a given board
test "select is deterministic across runs" {
    const facts = [_]NetFacts{
        .{ .net_i = 9, .whole = true, .elements = 3, .dist = 0.4 },
        .{ .net_i = 2, .whole = true, .elements = 3, .dist = 0.4 },
        .{ .net_i = 7, .whole = true, .elements = 3, .dist = 0.4 },
    };
    const a = try select(std.testing.allocator, &facts, .{ .net_i = 1 }, .{});
    defer std.testing.allocator.free(a.picked);
    defer std.testing.allocator.free(a.refused);
    const b = try select(std.testing.allocator, &facts, .{ .net_i = 1 }, .{});
    defer std.testing.allocator.free(b.picked);
    defer std.testing.allocator.free(b.refused);
    try std.testing.expectEqual(a.picked.len, b.picked.len);
    for (a.picked, b.picked) |x, y| try std.testing.expectEqual(x.net_i, y.net_i);
    try std.testing.expectEqual(@as(usize, 2), a.picked[0].net_i); // index tie-break
}

// spec: placement/vacate-policy - a joint transaction refuses every one of its own seeds and judges authored priority against the highest-ranked one
test "the cluster judgement covers every seed and takes the top priority" {
    const seeds = [_]Seed{ .{ .net_i = 1, .priority = 0 }, .{ .net_i = 2, .priority = 3 } };
    const whole = NetFacts{ .net_i = 2, .whole = true, .elements = 2 };
    // Seed 2 is a seed even though seed 1 is the one that happens to be first.
    try std.testing.expectEqual(Refusal.seed, judgeAll(whole, &seeds, .{}).refuse);
    // Priority 3 copper is fair game for a cluster containing a priority-3 seed…
    const rail = NetFacts{ .net_i = 5, .whole = true, .rank = .{ .priority = 3 }, .elements = 2 };
    try std.testing.expectEqual(Kind.short_stub, judgeAll(rail, &seeds, .{}).accept);
    // …and refused for the low-priority seed on its own, exactly as before.
    try std.testing.expectEqual(Refusal.outranks_seed, judge(rail, seeds[0], .{}).refuse);
    // Priority 4 outranks the whole cluster and stays protected.
    var above = rail;
    above.rank.priority = 4;
    try std.testing.expectEqual(Refusal.outranks_seed, judgeAll(above, &seeds, .{}).refuse);
}

// spec: placement/vacate-policy - a joint transaction ranks and caps the union of its seeds' candidates as one transaction, not once per seed
test "the cluster selection caps the union as a single transaction" {
    const seeds = [_]Seed{ .{ .net_i = 1 }, .{ .net_i = 2 } };
    const facts = [_]NetFacts{
        .{ .net_i = 3, .whole = true, .elements = 2, .dist = 0.4 },
        .{ .net_i = 4, .whole = true, .elements = 3, .dist = 0.1 },
        .{ .net_i = 5, .whole = true, .elements = 4, .dist = 0.2 },
        .{ .net_i = 2, .whole = true, .elements = 1, .dist = 0.0 }, // a seed
    };
    const d = try selectMany(std.testing.allocator, &facts, &seeds, .{ .max_nets = 2 });
    defer std.testing.allocator.free(d.picked);
    defer std.testing.allocator.free(d.refused);
    // TWO picks for the pair, not two per seed — cheapest first across the union.
    try std.testing.expectEqual(@as(usize, 2), d.picked.len);
    try std.testing.expectEqual(@as(usize, 3), d.picked[0].net_i);
    try std.testing.expectEqual(@as(usize, 4), d.picked[1].net_i);
    try std.testing.expectEqual(@as(usize, 2), d.refused.len);
    try std.testing.expectEqual(Refusal.seed, d.refused[0].why);
    try std.testing.expectEqual(Refusal.capped, d.refused[1].why);
}
