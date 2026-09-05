//! Joint window re-route — the router's one MULTI-NET, MULTI-ORDER rescue tier.
//!
//! Every conflict the router resolves today is resolved ONE NET AT A TIME. The
//! greedy pass routes in priority order; escalation retries a single failed leg
//! under a bigger budget; rip-up rips a failed net's blockers and re-routes the
//! failed net first; the fine-window rescue re-mazes one residual net on a
//! finer lattice. Nowhere is a set of MUTUALLY conflicting nets re-routed
//! JOINTLY — the only lever on local contention is permuting the whole board's
//! wave order (`mcp_route_order`, an expensive outer loop capped at 6-net
//! clusters × 48 trials).
//!
//! The post-route gap closer's vacate tier (`serve/mcp_close_gaps.zig` +
//! `vacate_policy.zig`) proved the mechanism: take a small, CHEAP-TO-RESTORE
//! subset of the copper in the way off the board, re-route the cluster, and
//! keep the result only if the board strictly improved. It took board-a 85 →
//! 91 nets. But it runs only from CLI, on a saved layout, after the fact — a
//! from-zero `bench-route` never sees it. This module brings the same mechanism
//! INSIDE the route, generalized along the axis the vacate tier lacks: the
//! cluster is re-routed under SEVERAL orders and the best outcome wins.
//!
//! ## What is actually new versus rip-up
//!
//! `router.ripUpReroute` also rips blockers and re-routes. Three things differ,
//! and each is a measured lesson rather than a preference:
//!
//!   1. **The blockers are found GEOMETRICALLY, not only by probe.** Rip-up
//!      nominates from `detectBlockers` alone — the foreign nets a completed
//!      soft path walked through. A foreign PAD is a hard wall to that probe, so
//!      a net boxed in by pads yields NOTHING to rip: measured on board-a, six
//!      of the seven nets reaching this tier report an empty probe result, which
//!      is why rip-up is a no-op for them. `corridorCandidates` adds the
//!      straight-hop sweep the post-route vacate tier nominates from, and that
//!      is what lets this tier fire at all. Both halves now go through
//!      `blocker_nomination.zig`, the one seam the post-route tier also
//!      nominates through — the tiers differ in what they may RIP, never in what
//!      they can SEE.
//!   2. **The blocker set is SMALL and CHOSEN.** Rip-up rips *every* blocker it
//!      finds. The accept gate is strictly-better-or-revert, so every ripped net
//!      has to come back or the whole attempt is thrown away: a wide subset is
//!      both slow and unlikely to survive. This tier caps the subset
//!      (`Limits.max_blockers`, `Limits.max_total_elements`) and ranks it by
//!      proximity (see `cheaperFirst`).
//!   3. **The cluster is re-routed under SEVERAL orders** (see `Order`), not
//!      just victim-first. Which net claims a contended channel first is the
//!      whole question in a corridor several nets want, and a maze is
//!      first-claim-wins.
//!   4. **It runs AFTER the fine-window rescue**, on a board the earlier rip-up
//!      phase never saw (the rescue splices new copper in), so even the
//!      victim-first order is being asked about a different board.
//!
//! ## What it is measured to be worth
//!
//! From zero (`bench-route`, ReleaseSafe, whole corpus, A/B against the same
//! binary with `Limits.max_victims = 0`): **board-b-xband-sip 18 → 19**
//! (`RxADV_1V8`, victim-first, three displaced blockers all restored),
//! **straps 79 → 80** (`RF_AMP_OUT`, same shape), black-canyon closes one more
//! net by the router's own count at an unchanged oracle count, and no board
//! loses one. Wall cost 1.10x (board-a) to 1.27x (straps).
//!
//! **Board A is unchanged at 82/91, and the trace says why.** All seven of its
//! residual nets form clusters and every attempt is rolled back: the victim
//! fails to route with its three nearest corridor occupants entirely off the
//! board, in either order, at the escalated budget. Removing copper is simply
//! not the lever there — `SPI_SCK` is a lattice-resolution wall, `V_12V` /
//! `buck_6v/VIN_F` are geometrically sealed, and the `SPI_*` / `*_1V8` jam at
//! connector `J1` is an ESCAPE-ASSIGNMENT problem (which pad each net leaves
//! through), which no amount of vacating changes. A fine-grid window retry of
//! the victim inside the transaction was tried against exactly that hypothesis
//! and measured 13.2 s -> 22.0 s for zero closed nets; it is not here.
//!
//! ## Shape
//!
//! Policy — which blockers may be taken, in what rank, under what bounds, and
//! which orders a cluster is tried under — is PURE and lives here, over plain
//! data (`BlockerFacts`, `Victim`, `Limits`), the `vacate_policy.zig` /
//! `fine_window.zig` house style. The driver (`run`) also lives here and speaks
//! to the engine only through `router`'s public transaction primitives
//! (`saveSnapshot` / `ripNet` / `rerouteNet` / `ripScore` / `restoreSnapshot`),
//! so `router.zig` gains a single call site and no net code lines.
//!
//! Deterministic by construction: no RNG, no clock, no hash-map iteration order
//! reaches a decision (blocker facts are sorted by net index before they are
//! judged), and every bound is an expansion/attempt COUNT rather than a
//! deadline.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const log = @import("../infra/log.zig");
const fine_accept = @import("fine_accept.zig");
const fine_window = @import("fine_window.zig");
const nomination = @import("blocker_nomination.zig");
const route_timing = @import("route_timing.zig");
const rank_admit = @import("rank_admit.zig");

// ── Policy: which copper may this tier take, and in what order ───────────────

/// Why a net in the victim's way was NOT taken into the cluster. Reported as
/// much for the diagnosis as for the decision — "the tier looked at this copper
/// and declined it, for this reason" is the difference between a diagnosable
/// rollback and a silent one (`vacate_policy.Refusal`'s lesson).
pub const Refusal = enum {
    /// The victim itself — the net the cluster is being re-routed FOR.
    victim,
    /// Ground. The board's reference copper; `router.collectRippable` never
    /// rips it either.
    ground,
    /// A declared `(stackup … (plane …))` carries the net. Its connectivity is
    /// not this router's tracks to move.
    plane,
    /// A declared pour carries the net on an outer face; same reason.
    pour,
    /// A `(net-class … (diff-pair …))` member. Its geometry is a coupled pair
    /// placed deliberately; an independent re-route would not reproduce it.
    diff_pair,
    /// A `(net-class … (max-freq …))` RF net. Same reason, plus a bend/escape
    /// discipline this tier's plain re-route does not honour.
    rf_max_freq,
    /// The net is itself still unrouted, so it has no corridor to give — and
    /// displacing the pass's own unfinished work is the one move that measurably
    /// LOSES nets (the `rippedAnOpenNet` lesson `vacate_policy` records).
    not_routed,
    /// An atomic diff-pair leg or a hard reference replay: the engine froze it
    /// (`RipNet.reroutable == false`) and this tier honours that.
    frozen,
    /// A `(net-class … (priority …))` strictly above the victim's. Unlike the
    /// vacate tier there is no pour exemption here: nothing underwrites a
    /// restore inside the route, so authored order is absolute.
    outranks_victim,
    /// Eligible, but the per-cluster blocker cap was already full.
    capped,
    /// Eligible, but taking it would push the cluster past its copper budget
    /// (`Limits.max_total_elements`). Skipped rather than stopping the scan, so
    /// the smaller candidates ranked behind it still get in.
    over_budget,
};

/// A candidate's verdict: taken into the cluster, or refused with a reason.
pub const Verdict = union(enum) { accept: void, refuse: Refusal };

/// The reasons a net may never be taken, whatever its restore cost. One gate
/// ahead of every other question: this copper is either the board's reference,
/// carried by a plane the router does not lay, or a shape placed deliberately.
pub const Protected = struct {
    /// The net is ground by name.
    ground: bool = false,
    /// A declared `(plane …)` carries it.
    plane: bool = false,
    /// A declared pour carries it on an outer face.
    pour: bool = false,
    /// A resolved `(diff-pair …)` member.
    diff_pair: bool = false,
    /// The net's class declares `(max-freq …)`.
    rf: bool = false,

    /// The refusal these protections earn, or null when none apply. The order
    /// is the reporting order — the most specific reason a reader names first.
    pub fn refusal(self: Protected) ?Refusal {
        if (self.ground) return .ground;
        if (self.plane) return .plane;
        if (self.pour) return .pour;
        if (self.diff_pair) return .diff_pair;
        if (self.rf) return .rf_max_freq;
        return null;
    }
};

/// Everything `judge` needs about one net whose copper the victim's cheapest
/// soft path crossed. Assembled by the driver from the placement rules and the
/// live copper, so this half stays free of both.
pub const BlockerFacts = struct {
    /// Flattened-net index, and the deterministic tie-break for equal ranks.
    net_i: usize,
    /// The never-take reasons (see `Protected`).
    protected: Protected = .{},
    /// The net is routed right now, so it HAS a corridor to give.
    routed: bool = false,
    /// The engine will re-route it (false for an atomic pair leg / hard replay).
    reroutable: bool = true,
    /// The net class's `(priority …)`; 0 for an unclassed net.
    priority: u32 = 0,
    /// Tracks plus vias currently on the board for this net.
    elements: usize = 0,
    /// Closest approach of this net's copper to one of the victim's straight
    /// terminal hops, in mm. 0 for a net the soft probe walked THROUGH — that
    /// copper is on the victim's own cheapest path, which is as in-the-way as a
    /// net gets.
    dist: f64 = 0,
};

/// The still-failed net the cluster is being re-routed for.
pub const Victim = struct { net_i: usize, priority: u32 = 0 };

/// The tier's bounds. Every one exists to keep a cluster small enough that its
/// all-or-nothing accept gate can plausibly be met, and the whole pass short
/// enough to belong inside a route rather than beside it.
pub const Limits = struct {
    /// Most blockers one cluster takes. Each has to come back inside the SAME
    /// transaction or the attempt is discarded, so the odds fall off fast with
    /// width — and the wide subset is exactly what `ripUpReroute` already tries.
    max_blockers: usize = 3,
    /// Total tracks+vias one cluster may take off the board. The blocker cap
    /// alone bounds the wrong thing: two nets of two elements and two nets of
    /// fifty are not the same transaction (`vacate_policy.Limits`'s lesson).
    max_total_elements: usize = 64,
    /// Most still-failed nets one pass attempts. A board with thirty open nets
    /// is not one this tier can close; it is one whose placement is wrong.
    max_victims: usize = 8,
    /// Whole-pass cap on cluster re-route attempts (victims × orders). The hard
    /// bound on the tier's wall time, independent of how the per-victim caps
    /// happen to compose.
    max_attempts: usize = 24,
    /// Per-leg maze expansion budget every cluster member re-routes under —
    /// `router`'s escalated tier. A blocker gets it too, deliberately: the
    /// transaction only survives its strictly-better gate if the displaced net
    /// comes BACK, so the detour it has to find is exactly as long as the one
    /// the victim needs. (`ripUpReroute` gives its blockers the base budget,
    /// which is part of why its wide transactions so rarely survive.)
    cluster_budget: usize = 400_000,
    /// Expansion budget the blocker probe runs under (`router.detectBlockers`).
    /// A long congested net's probe has to reach across the board to see what
    /// walls it in, or the tier finds nothing to take.
    probe_budget: usize = 400_000,
    /// How close (mm) a foreign track must come to one of the victim's straight
    /// terminal hops to count as being in the way. The geometric half of the
    /// nomination — see `corridorCandidates` for why the soft probe alone is
    /// not enough. 2.0 mm is the radius the vacate tier measured on this board.
    corridor_mm: f64 = 2.0,
};

/// One blocker taken into the cluster.
pub const Nomination = struct { net_i: usize, priority: u32, elements: usize, dist: f64 = 0 };

/// One refused candidate and why, for the decision trace.
pub const Refused = struct { net_i: usize, why: Refusal };

/// What the tier decided about every net in the victim's way: the blockers to
/// rip (cheapest first) and every other candidate with its reason.
pub const Decision = rank_admit.Decision(Nomination, Refused);

/// May this net be taken into `victim`'s cluster, and if not, why not?
///
/// The order of the refusals is the order of the guarantees. Identity, then the
/// copper this router does not own (ground / plane / pour), then the shapes
/// placed deliberately (diff pair, RF) — no cheapness argument may override any
/// of them. Then `not_routed`, because displacing unfinished work is the one
/// move that measurably loses nets. Then authored priority. Everything left is
/// eligible and the ranking decides.
pub fn judge(f: BlockerFacts, victim: Victim) Verdict {
    if (f.net_i == victim.net_i) return .{ .refuse = .victim };
    if (f.protected.refusal()) |r| return .{ .refuse = r };
    if (!f.routed) return .{ .refuse = .not_routed };
    if (!f.reroutable) return .{ .refuse = .frozen };
    if (f.priority > victim.priority) return .{ .refuse = .outranks_victim };
    return .{ .accept = {} };
}

/// Rank order: NEAREST the victim's corridor first, then least authored
/// priority, then fewest elements, then net index.
///
/// Distance leads, and that is the one place this tier deliberately departs
/// from `vacate_policy.cheaperFirst` (which ranks restore cheapness first).
/// The two tiers are answering different questions. The vacate tier's seed is a
/// net already PARTLY on the board whose islands need joining, so any freed
/// channel helps and the only real risk is the restore. This tier's victim has
/// NO copper at all: the cluster is worth forming only if it contains the nets
/// actually standing where the victim must go. Measured on board-a's
/// `SPI_MOSI` under cheapness-first: the picks were two unrelated 12- and
/// 13-element nets and the four sibling SPI lines sharing its connector
/// corridor — the jam the board is actually stuck on — were all refused
/// `over_budget` behind them. Ranking by proximity puts the corridor's own
/// occupants in the cluster; priority and element count then break ties towards
/// the cheaper of two equally-in-the-way candidates, and the index is only
/// there to make the tier deterministic.
pub fn cheaperFirst(_: void, a: Nomination, b: Nomination) bool {
    if (a.dist != b.dist) return a.dist < b.dist;
    if (a.priority != b.priority) return a.priority < b.priority;
    if (a.elements != b.elements) return a.elements < b.elements;
    return a.net_i < b.net_i;
}

/// Sort candidate facts by net index — the driver's input arrives from a hash
/// set, and a stable input keeps the REFUSAL list (which is reported) stable
/// too, not just the picks the ranking would order anyway.
pub fn byIndex(_: void, a: BlockerFacts, b: BlockerFacts) bool {
    return a.net_i < b.net_i;
}

/// Judge every candidate, rank the eligible ones and keep the cheapest
/// `lim.max_blockers` that fit `lim.max_total_elements`. Everything else lands
/// in `refused`, so a caller can tell "the tier would not touch this" from "the
/// tier ran out of room".
pub fn select(
    alloc: std.mem.Allocator,
    facts: []const BlockerFacts,
    victim: Victim,
    lim: Limits,
) std.mem.Allocator.Error!Decision {
    return rank_admit.select(alloc, Nomination, Refused, BlockerFacts, Victim, nominate, cheaperFirst, facts, victim, .{
        .max_items = lim.max_blockers,
        .max_total_elements = lim.max_total_elements,
    });
}

/// `judge`'s verdict as a nomination: the ranking evidence this tier carries is
/// the candidate's authored priority, element count and corridor distance.
fn nominate(victim: Victim, f: BlockerFacts) rank_admit.Verdict(Nomination, Refusal) {
    return switch (judge(f, victim)) {
        .accept => .{ .accept = .{ .net_i = f.net_i, .priority = f.priority, .elements = f.elements, .dist = f.dist } },
        .refuse => |r| .{ .refuse = r },
    };
}

// ── Policy: the orders one cluster is re-routed under ────────────────────────

/// Where the victim sits in the cluster's routing order. Blockers always follow
/// the board's own wave order among themselves (descending authored priority),
/// so the only variable is when the victim gets its turn — which is the whole
/// question, because a maze is first-claim-wins.
pub const Order = enum {
    /// Victim first: it claims the freed channel and the blockers must find
    /// their own way back. The order `ripUpReroute` already uses, kept because
    /// it is the one most likely to route the victim.
    victim_first,
    /// Everyone in authored wave order, victim included — what the greedy pass
    /// would have done had the cluster been routed together from the start.
    wave,
    /// Victim last: the blockers re-lay first, jointly, and the victim takes
    /// what is left. The only order that can find a solution in which the
    /// blockers moved ASIDE rather than merely returning.
    victim_last,
};

/// One net in a cluster, as the order plan sees it.
pub const Member = struct { net_i: usize, priority: u32, is_victim: bool = false };

/// The orders a cluster is tried under, in try order.
pub const orders = [_]Order{ .victim_first, .wave, .victim_last };

/// Arrange `members` (victim first on entry, then the picked blockers in rank
/// order) into the sequence `o` routes them in. Sorts in place; stable, so two
/// members of equal priority keep the caller's rank order.
pub fn sequence(o: Order, members: []Member) void {
    switch (o) {
        .victim_first => std.mem.sort(Member, members, {}, victimLeads),
        .wave => std.mem.sort(Member, members, {}, waveOrder),
        .victim_last => std.mem.sort(Member, members, {}, victimTrails),
    }
}

/// `.victim_first`: the victim, then the blockers by descending priority.
fn victimLeads(_: void, a: Member, b: Member) bool {
    if (a.is_victim != b.is_victim) return a.is_victim;
    return a.priority > b.priority;
}

/// `.wave`: strictly descending authored priority, victim included.
fn waveOrder(_: void, a: Member, b: Member) bool {
    return a.priority > b.priority;
}

/// `.victim_last`: the blockers by descending priority, then the victim.
fn victimTrails(_: void, a: Member, b: Member) bool {
    if (a.is_victim != b.is_victim) return b.is_victim;
    return a.priority > b.priority;
}

/// Does `o` produce a different sequence than one already tried for this
/// cluster? A victim that outranks every blocker makes `.wave` identical to
/// `.victim_first`, and one that is outranked by all of them makes it identical
/// to `.victim_last`; re-routing the same sequence twice buys nothing and costs
/// a full cluster attempt.
///
/// Under the CURRENT refusal rule that means `.wave` never runs at all —
/// `judge` refuses any blocker of strictly higher authored priority, so no
/// cluster can hold one, and the authored order always collapses onto
/// victim-first. The rule is written on the general shape rather than that
/// special case deliberately: `router.ripUpReroute` already raises its rip
/// ceiling to `maxInt` for an eligible net, and the day this tier follows it
/// the middle order becomes real without another line changing.
pub fn orderIsNovel(o: Order, victim_pri: u32, blockers: []const Nomination) bool {
    if (o != .wave) return true;
    var any_above = false;
    var any_below_or_equal = false;
    for (blockers) |b| {
        if (b.priority > victim_pri) any_above = true else any_below_or_equal = true;
    }
    // Identical to victim_first when nothing outranks the victim, and to
    // victim_last when everything does.
    return any_above and any_below_or_equal;
}

/// The joint tier's own half of the accept gate: a cluster attempt is a
/// candidate only when it leaves the board with STRICTLY MORE nets routed.
///
/// The shared `router.ripScoreBetter` gate that rip-up uses also accepts an
/// equal-count board carrying shorter copper. For a rip-up round that is a real
/// improvement; for a RESCUE tier it is churn, and measured churn: on board-a
/// it kept a transaction that routed its victim and broke a displaced blocker —
/// the same routed count, a different open list, and a whole cluster of copper
/// redrawn for nothing. So this predicate gates ENTRY to the candidate set, and
/// `ripScoreBetter` then picks the best of the candidates, which is where its
/// priority and copper-length keys earn their place.
pub fn closesANet(now_routed: usize, before_routed: usize) bool {
    return now_routed > before_routed;
}

// ── Driver ──────────────────────────────────────────────────────────────────

/// Flip to true to have every victim name its blockers, its refusals, the
/// orders it tried and each one's verdict on stderr. Off in normal builds — a
/// board whose residual nets are geometrically sealed has nothing to say, and
/// one that is being actively tuned is being actively read.
const trace_on = false;

/// Run the joint tier over the residual failed nets of a finished batch route.
///
/// Called once, from `router.finishBatch`, after the fine-window rescue has had
/// its turn: everything here is a gamble paid for by a strictly-better gate, so
/// it belongs after every non-destructive tier and before the finish passes.
/// Rescued nets get their `ok` flag, their search-limit note cleared and a
/// timeline event, exactly as the fine rescue's do. The returned `Report` is
/// what the pass DID — the router ignores it, and a test reads it to tell "the
/// tier rolled every attempt back" from "the tier never attempted anything".
pub fn run(core: router.RouteCore) std.mem.Allocator.Error!Report {
    // `one_shot` skips this for the same reason it skips rip-up and the fine
    // rescue: a net the maze could not route is the agent's next DSL edit, not
    // the router's next gamble (`route_policy.Effort`).
    if (!core.ctx.effort.retries()) return .{};
    if (!anyFailed(core.result.routable)) return .{};
    if (core.ctx.timing) |t| t.begin(.joint_rescue);
    defer if (core.ctx.timing) |t| t.end(.joint_rescue);
    // Per-victim scratch: one cluster's snapshots at a time, reclaimed before
    // the next. allocator-ok: the injected route arena is monotonic.
    var scratch_inst = std.heap.ArenaAllocator.init(core.ctx.arena);
    defer scratch_inst.deinit();
    var accept_gate = try fine_accept.Gate.init(core.ctx.arena, core.placement, core.ctx.zones);
    defer accept_gate.deinit();
    var budget = Budget{ .lim = .{} };
    for (core.result.routable) |*rn| {
        if (router.routeCancelled(core.ctx)) break; // cooperative cancel
        if (rn.ok or !rn.reroutable) continue;
        if (!budget.takeVictim()) break;
        try rescueOne(core, rn, &budget, &accept_gate, scratch_inst.allocator());
        _ = scratch_inst.reset(.retain_capacity);
    }
    return budget.report;
}

/// What one pass did, for the caller's trace and this module's own tests.
pub const Report = struct {
    /// Still-failed nets the pass took as victims.
    victims: usize = 0,
    /// Cluster re-route attempts it ran (victims x novel orders).
    attempts: usize = 0,
    /// Nets that ended the pass routed and were not routed before it.
    rescued: usize = 0,
};

/// The pass's remaining allowance, threaded through the per-victim work so the
/// caps compose into ONE bound on the tier rather than a per-victim one that
/// multiplies by however many victims a board happens to have.
const Budget = struct {
    lim: Limits,
    victims_left: usize = 0,
    attempts_left: usize = 0,
    started: bool = false,
    report: Report = .{},

    /// Claim one victim slot, or report the pass is done with victims.
    fn takeVictim(self: *Budget) bool {
        if (!self.started) {
            self.started = true;
            self.victims_left = self.lim.max_victims;
            self.attempts_left = self.lim.max_attempts;
        }
        if (self.victims_left == 0 or self.attempts_left == 0) return false;
        self.victims_left -= 1;
        self.report.victims += 1;
        return true;
    }

    /// Claim one cluster re-route attempt, or report the pass is out of them.
    fn takeAttempt(self: *Budget) bool {
        if (self.attempts_left == 0) return false;
        self.attempts_left -= 1;
        self.report.attempts += 1;
        return true;
    }
};

/// True when some net in the working set is still unrouted — the cheap guard
/// that keeps the whole tier (and its snapshots) off a fully-routed board.
fn anyFailed(routable: []const router.RipNet) bool {
    for (routable) |rn| {
        if (!rn.ok and rn.reroutable) return true;
    }
    return false;
}

/// One victim's whole transaction: probe its blockers, choose a cluster, try it
/// under each novel order, and keep the best outcome only if the board strictly
/// improved. The board is byte-identical to its entry state on every other path.
fn rescueOne(
    core: router.RouteCore,
    rn: *router.RipNet,
    budget: *Budget,
    accept_gate: *fine_accept.Gate,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const victim = Victim{ .net_i = rn.net_i, .priority = classPriority(core.placement, rn.net_i) };
    var near = nomination.Table{};
    try probeCandidates(core, rn.net_i, budget.lim, &near, scratch);
    try corridorCandidates(core, rn.net_i, budget.lim, &near, scratch);
    var facts: std.ArrayList(BlockerFacts) = .empty;
    for (try near.ranked(scratch)) |c| try facts.append(scratch, netFacts(core, c.net_i, c.dist));
    // `ranked` is nearest-first; re-sorting by INDEX makes both the picks AND the
    // reported refusal list reproducible, not just the ranking.
    std.mem.sort(BlockerFacts, facts.items, {}, byIndex);
    const decision = try select(scratch, facts.items, victim, budget.lim);
    traceVictim(core, victim, decision);
    if (decision.picked.len == 0) return;
    try tryOrders(.{
        .core = core,
        .rn = rn,
        .victim = victim,
        .picked = decision.picked,
        .budget = budget,
        .accept_gate = accept_gate,
        .scratch = scratch,
    });
}

/// Nomination half one: the foreign nets the victim's cheapest SOFT path walks
/// through (`router.detectBlockers`), folded into the shared table at distance
/// 0 — nothing is more in the way than copper on your own cheapest path.
fn probeCandidates(
    core: router.RouteCore,
    net_i: usize,
    lim: Limits,
    near: *nomination.Table,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    core.ctx.escalate_budget = lim.probe_budget;
    const crossed = try router.detectBlockers(core.ctx, core.placement, core.idx_of, net_i, scratch);
    core.ctx.escalate_budget = 0;
    try nomination.foldProbe(near, scratch, crossed);
    traceProbe(core, net_i, crossed.len);
}

/// Nomination half two: every foreign net whose copper comes within
/// `lim.corridor_mm` of one of the victim's straight terminal hops, keeping each
/// net's closest approach (`blocker_nomination.sweepHops`).
///
/// This exists because the soft probe REPORTS NOTHING for a net whose corridor
/// is walled by pads rather than by copper — `softProbe` records blockers only
/// on a path it actually completed, and `softEnter` treats a foreign pad as a
/// hard wall (a pad can never be ripped). Measured on board-a's residual set:
/// six of the seven nets this tier sees produce an EMPTY probe result, so a
/// probe-only tier is starved of input and can never fire. The straight-line
/// sweep is what the post-route vacate tier nominates from, and it is the half
/// that gave that tier its measured 85 → 91.
///
/// TRACKS ONLY here, unlike the post-route tier: this one's probe already
/// reports every net whose via barrels sit on the victim's own path (they are
/// stamped into the same occupancy grid `softProbe` walks), so sweeping barrels
/// again would only reshuffle two equally-in-the-way candidates — and this tier
/// runs inside `bench-route`, where a reshuffle is a moved board.
fn corridorCandidates(
    core: router.RouteCore,
    net_i: usize,
    lim: Limits,
    near: *nomination.Table,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const pts = try router.netPoints(scratch, core.placement, core.idx_of, core.placement.nets[net_i]);
    if (pts.len < 2) return;
    // The same spanning-tree hops the fine rescue re-routes leg by leg, so the
    // corridor swept is the one the router itself would try to fill.
    var hops: std.ArrayList(nomination.Hop) = .empty;
    for (try fine_window.mstLegs(scratch, pts)) |leg| {
        const a = pts[leg[0]];
        const b = pts[leg[1]];
        try hops.append(scratch, .{ .ax = a.x, .ay = a.y, .bx = b.x, .by = b.y });
    }
    try nomination.sweepHops(near, scratch, .{
        .net_i = net_i,
        .hops = hops.items,
        .tracks = core.tracks.items,
        .radius_mm = lim.corridor_mm,
    });
}

/// Try the cluster under every novel order, keeping the best strictly-better
/// outcome. The pre-state snapshot is restored after every attempt, so the
/// board a losing attempt leaves behind is the board it started from, copper
/// for copper and occupancy cell for occupancy cell.
const OrderRun = struct {
    core: router.RouteCore,
    rn: *router.RipNet,
    victim: Victim,
    picked: []const Nomination,
    budget: *Budget,
    accept_gate: *fine_accept.Gate,
    scratch: std.mem.Allocator,
};

fn tryOrders(request: OrderRun) std.mem.Allocator.Error!void {
    const core = request.core;
    const rn = request.rn;
    const victim = request.victim;
    const picked = request.picked;
    const budget = request.budget;
    const accept_gate = request.accept_gate;
    const scratch = request.scratch;
    const ctx = core.ctx;
    const routable = core.result.routable;
    const snap = try router.saveSnapshot(scratch, ctx, core.tracks, core.vias, routable);
    // The `before` board's own native arcs. Live `net_smooth` describes the
    // board a cluster re-route just left, not this one, so weighing the
    // snapshot against it would carve the pre-state's pours with the curved
    // envelope of copper that is not on the pre-state at all.
    var snap_arcs: std.ArrayList(router.Arc) = .empty;
    for (snap.smooth) |entry| try snap_arcs.appendSlice(scratch, entry.v.arcs);
    var best_score = snap.score;
    var best: ?@TypeOf(snap) = null;
    const members = try scratch.alloc(Member, picked.len + 1);
    for (orders) |o| {
        if (!orderIsNovel(o, victim.priority, picked)) continue;
        if (!budget.takeAttempt()) break;
        members[0] = .{ .net_i = victim.net_i, .priority = victim.priority, .is_victim = true };
        for (picked, members[1..]) |p, *m| m.* = .{ .net_i = p.net_i, .priority = p.priority };
        sequence(o, members);
        try routeCluster(core, members, budget.lim);
        const now = router.ripScore(routable, core.tracks.items);
        var won_now = false;
        if (closesANet(now.routed, snap.score.routed)) {
            if (router.ripScoreBetter(now, best_score)) {
                if (!router.routeCancelled(ctx)) {
                    // Read after the re-route: this cluster's rip dropped some
                    // nets' arcs and its reroute minted others.
                    const curves = try router.liveCurves(scratch, ctx, core.placement.nets.len);
                    // RF paths are the same on both boards: a rip never drops a
                    // port outcome, and none exists this early anyway.
                    const was: fine_accept.Board = .{
                        .tracks = snap.tracks,
                        .vias = snap.vias,
                        .arcs = snap_arcs.items,
                        .rf_paths = curves.rf_paths,
                    };
                    won_now = try accept_gate.acceptsReplacement(was, .{
                        .tracks = core.tracks.items,
                        .vias = core.vias.items,
                        .arcs = curves.arcs,
                        .rf_paths = curves.rf_paths,
                    });
                    // An oracle pass can itself carry us across the absolute
                    // deadline. Never commit fresh speculative copper after
                    // that boundary; the snapshot below remains authoritative.
                    if (router.routeCancelled(ctx)) won_now = false;
                }
            }
        }
        if (won_now) {
            best_score = now;
            best = try router.saveSnapshot(scratch, ctx, core.tracks, core.vias, routable);
        }
        traceOrder(core, o, members, now.routed, snap.score.routed, won_now);
        try router.restoreSnapshot(ctx, core.tracks, core.vias, routable, snap);
    }
    const won = best orelse return;
    try router.restoreSnapshot(ctx, core.tracks, core.vias, routable, won);
    if (!rn.ok) return;
    budget.report.rescued += 1;
    router.clearSearchLimit(ctx, rn.net_i);
    try core.progress.timeline.capture(.{
        .kind = .net_routed,
        .net = rn.net_i,
        .routed = core.progress.plane_routed + best_score.routed,
    }, core.tracks.items, core.vias.items);
}

/// Rip every member of the cluster, then re-route them in `members` order —
/// each under the escalated budget, victim and displaced blocker alike (see
/// `Limits.cluster_budget`).
///
/// A fine-grid WINDOW retry of the victim inside the transaction was measured
/// here and removed: gated to the victim-first order it cost board-a 13.2 s →
/// 22.0 s (1.8x the ungated route) and closed nothing. The one transaction it
/// changed was a lateral swap — the victim routed and a displaced blocker did
/// not — which the accept gate above now refuses on its own.
fn routeCluster(core: router.RouteCore, members: []const Member, lim: Limits) std.mem.Allocator.Error!void {
    const ctx = core.ctx;
    for (members) |m| {
        const slot = slotOf(core.result.routable, m.net_i) orelse continue;
        router.ripNet(ctx, core.tracks, core.vias, m.net_i);
        slot.ok = false;
    }
    for (members) |m| {
        const slot = slotOf(core.result.routable, m.net_i) orelse continue;
        ctx.escalate_budget = lim.cluster_budget;
        try router.rerouteNet(ctx, core.placement, core.idx_of, slot, core.tracks, core.vias);
        ctx.escalate_budget = 0;
    }
}

/// The working-set slot for `net_i` (each net appears at most once), or null.
fn slotOf(routable: []router.RipNet, net_i: usize) ?*router.RipNet {
    for (routable) |*rn| {
        if (rn.net_i == net_i) return rn;
    }
    return null;
}

/// One candidate net as the policy sees it, read off the placement rules and
/// the live copper (see `BlockerFacts`).
fn netFacts(core: router.RouteCore, net_i: usize, dist: f64) BlockerFacts {
    const name = core.placement.nets[net_i].name;
    const pour = router.netPourLayers(core.placement, name);
    const slot = slotOf(core.result.routable, net_i);
    return .{
        .net_i = net_i,
        .protected = .{
            .ground = optimizer.isGroundName(router.shortName(name)),
            .plane = router.netHasPlane(core.placement, name),
            .pour = pour[0] or pour[1],
            .diff_pair = inDiffPair(core.placement, net_i),
            .rf = classRf(core.placement, net_i),
        },
        .routed = if (slot) |s| s.ok else false,
        .reroutable = if (slot) |s| s.reroutable else false,
        .priority = classPriority(core.placement, net_i),
        .elements = netElements(core, net_i),
        .dist = dist,
    };
}

/// Is `net_i` a resolved `(diff-pair …)` member?
fn inDiffPair(placement: optimizer.Placement, net_i: usize) bool {
    for (placement.diff_pairs) |p| {
        if (p.p == net_i or p.n == net_i) return true;
    }
    return false;
}

/// Does `net_i`'s class declare `(max-freq …)`?
fn classRf(placement: optimizer.Placement, net_i: usize) bool {
    if (net_i >= placement.rules.net.len) return false;
    return placement.rules.net[net_i].rf.max_freq_hz > 0;
}

/// `net_i`'s authored `(net-class … (priority …))`, 0 when unclassed. This is
/// the AUTHORED tier alone, not `router.netPriority`'s composite sort key: the
/// low bits of that key are an intrinsic heuristic rank, and "never rip a
/// higher-priority net" is a promise about what the author declared.
fn classPriority(placement: optimizer.Placement, net_i: usize) u32 {
    if (net_i >= placement.rules.net.len) return 0;
    return placement.rules.net[net_i].priority;
}

/// How many tracks plus vias `net_i` has on the board right now — the measure
/// of how much copper the cluster's restore has to re-lay.
fn netElements(core: router.RouteCore, net_i: usize) usize {
    const ni: i32 = @intCast(net_i);
    var n: usize = 0;
    for (core.tracks.items) |t| {
        if (t.net == ni) n += 1;
    }
    for (core.vias.items) |v| {
        if (v.net == ni) n += 1;
    }
    return n;
}

/// Name the soft probe's raw yield on stderr (see `trace_on`) — an EMPTY yield
/// is the diagnosis that motivated `corridorCandidates`.
fn traceProbe(core: router.RouteCore, net_i: usize, crossed: usize) void {
    if (!trace_on) return;
    log.progress("joint: probe {s} crossed={d}", .{ core.placement.nets[net_i].name, crossed });
}

/// Name one victim's whole nomination decision on stderr (see `trace_on`).
fn traceVictim(core: router.RouteCore, victim: Victim, d: Decision) void {
    if (!trace_on) return;
    log.progress("joint: victim {s} pri={d} picked={d} refused={d}", .{
        core.placement.nets[victim.net_i].name,
        victim.priority,
        d.picked.len,
        d.refused.len,
    });
    for (d.picked) |p| {
        log.progress("  pick   {s} pri={d} elems={d}", .{ core.placement.nets[p.net_i].name, p.priority, p.elements });
    }
    for (d.refused) |r| {
        log.progress("  refuse {s} {s}", .{ core.placement.nets[r.net_i].name, @tagName(r.why) });
    }
}

/// Name one cluster attempt's outcome on stderr (see `trace_on`): the sequence
/// it routed in, which members came back, and whether the board improved.
fn traceOrder(core: router.RouteCore, o: Order, members: []const Member, routed: usize, was: usize, kept: bool) void {
    if (!trace_on) return;
    log.progress("  order {s}: routed {d}->{d} kept={}", .{ @tagName(o), was, routed, kept });
    for (members) |m| {
        const slot = slotOf(core.result.routable, m.net_i);
        log.progress("    {s}{s} ok={}", .{
            if (m.is_victim) "*" else " ",
            core.placement.nets[m.net_i].name,
            if (slot) |s| s.ok else false,
        });
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    // The phase this tier reports under, pinned by NAME so `--breakdown` can
    // never lose its column to a rename in `route_timing`.
    try testing.expectEqualStrings("joint_rescue", route_timing.PhaseTimer.label(.joint_rescue));
}

// spec: placement/joint-rescue - a routed, re-routable, no-higher-priority blocker is taken into the victim's cluster
test "an ordinary routed blocker is accepted" {
    const v = judge(.{ .net_i = 3, .routed = true, .elements = 4 }, .{ .net_i = 1 });
    try testing.expectEqual(Verdict.accept, v);
}

// spec: placement/joint-rescue - ground, plane-carried, pour-carried, diff-pair and max-freq RF copper is never ripped by the joint tier
test "the guarded classes are refused whatever their cost" {
    const seed = Victim{ .net_i = 1 };
    const base = BlockerFacts{ .net_i = 2, .routed = true, .elements = 1 };
    var g = base;
    g.protected.ground = true;
    try testing.expectEqual(Refusal.ground, judge(g, seed).refuse);
    var p = base;
    p.protected.plane = true;
    try testing.expectEqual(Refusal.plane, judge(p, seed).refuse);
    var z = base;
    z.protected.pour = true;
    try testing.expectEqual(Refusal.pour, judge(z, seed).refuse);
    var d = base;
    d.protected.diff_pair = true;
    try testing.expectEqual(Refusal.diff_pair, judge(d, seed).refuse);
    var r = base;
    r.protected.rf = true;
    try testing.expectEqual(Refusal.rf_max_freq, judge(r, seed).refuse);
    try testing.expectEqual(Refusal.victim, judge(.{ .net_i = 1, .routed = true }, seed).refuse);
}

// spec: placement/joint-rescue - a still-open, frozen, or strictly-higher-priority net is refused rather than ripped
test "open, frozen and higher-priority candidates are refused" {
    const seed = Victim{ .net_i = 1, .priority = 1 };
    try testing.expectEqual(Refusal.not_routed, judge(.{ .net_i = 2, .routed = false }, seed).refuse);
    try testing.expectEqual(
        Refusal.frozen,
        judge(.{ .net_i = 2, .routed = true, .reroutable = false }, seed).refuse,
    );
    try testing.expectEqual(
        Refusal.outranks_victim,
        judge(.{ .net_i = 2, .routed = true, .priority = 2 }, seed).refuse,
    );
    // Equal authored priority is fine — the greedy pass routed them in one wave,
    // so one boxing the next in is exactly the trade this tier exists to make.
    try testing.expectEqual(Verdict.accept, judge(.{ .net_i = 2, .routed = true, .priority = 1 }, seed));
}

// spec: placement/joint-rescue - the joint tier ranks blockers nearest the victim's corridor first, then by least authored priority and fewest elements, and caps the cluster
test "select ranks by proximity then disturbance cost and caps the cluster" {
    const facts = [_]BlockerFacts{
        // Cheapest of all (priority 0, two elements) but four millimetres away.
        .{ .net_i = 2, .routed = true, .priority = 0, .elements = 2, .dist = 4.0 },
        // On the victim's own soft path, so `dist` 0 — nothing is more in the
        // way, and it leads despite being the longest candidate here.
        .{ .net_i = 3, .routed = true, .priority = 1, .elements = 9, .dist = 0 },
        // Same distance as net 2; the priority key then breaks the tie.
        .{ .net_i = 4, .routed = true, .priority = 0, .elements = 3, .dist = 0.5 },
        .{ .net_i = 5, .routed = false, .elements = 1, .dist = 0.1 },
    };
    const d = try select(testing.allocator, &facts, .{ .net_i = 1, .priority = 3 }, .{ .max_blockers = 2, .max_total_elements = 32 });
    defer testing.allocator.free(d.picked);
    defer testing.allocator.free(d.refused);
    try testing.expectEqual(@as(usize, 2), d.picked.len);
    try testing.expectEqual(@as(usize, 3), d.picked[0].net_i); // nearest wins
    try testing.expectEqual(@as(usize, 4), d.picked[1].net_i);
    try testing.expectEqual(@as(usize, 2), d.refused.len);
    try testing.expectEqual(Refusal.not_routed, d.refused[0].why); // net 5
    try testing.expectEqual(Refusal.capped, d.refused[1].why); // net 2, the far one
}

// spec: placement/joint-rescue - the joint tier accepts a cluster only when it leaves strictly more nets routed, never on an equal-count board with shorter copper
test "the accept gate demands a closed net, not shorter copper" {
    try testing.expect(closesANet(84, 83));
    try testing.expect(!closesANet(83, 83));
    try testing.expect(!closesANet(82, 83));
}

// spec: placement/joint-rescue - the joint tier's copper budget skips an oversized blocker without shutting out the short ones behind it
test "the cluster copper budget skips rather than stops" {
    const facts = [_]BlockerFacts{
        .{ .net_i = 2, .routed = true, .elements = 40 },
        .{ .net_i = 3, .routed = true, .elements = 41 },
        .{ .net_i = 4, .routed = true, .elements = 42 },
    };
    const d = try select(testing.allocator, &facts, .{ .net_i = 1 }, .{ .max_total_elements = 41 });
    defer testing.allocator.free(d.picked);
    defer testing.allocator.free(d.refused);
    try testing.expectEqual(@as(usize, 1), d.picked.len);
    try testing.expectEqual(@as(usize, 2), d.picked[0].net_i);
    try testing.expectEqual(@as(usize, 2), d.refused.len);
    try testing.expectEqual(Refusal.over_budget, d.refused[0].why);
    try testing.expectEqual(Refusal.over_budget, d.refused[1].why);
}

// spec: placement/joint-rescue - a cluster is re-routed victim-first, in authored wave order, and victim-last
test "the three orders place the victim first, in wave order and last" {
    const members = [_]Member{
        .{ .net_i = 1, .priority = 0, .is_victim = true },
        .{ .net_i = 2, .priority = 3 },
        .{ .net_i = 3, .priority = 1 },
    };
    var m = members;
    sequence(.victim_first, &m);
    try testing.expectEqual(@as(usize, 1), m[0].net_i);
    try testing.expectEqual(@as(usize, 2), m[1].net_i); // higher priority blocker first
    try testing.expectEqual(@as(usize, 3), m[2].net_i);
    m = members;
    sequence(.wave, &m);
    try testing.expectEqual(@as(usize, 2), m[0].net_i);
    try testing.expectEqual(@as(usize, 3), m[1].net_i);
    try testing.expectEqual(@as(usize, 1), m[2].net_i); // the unclassed victim last
    m = members;
    sequence(.victim_last, &m);
    try testing.expectEqual(@as(usize, 2), m[0].net_i);
    try testing.expectEqual(@as(usize, 3), m[1].net_i);
    try testing.expectEqual(@as(usize, 1), m[2].net_i);
}

// spec: placement/joint-rescue - the wave order is skipped when it would repeat the victim-first or victim-last sequence
test "a redundant wave order is skipped" {
    const above = [_]Nomination{.{ .net_i = 2, .priority = 3, .elements = 1 }};
    const below = [_]Nomination{.{ .net_i = 2, .priority = 0, .elements = 1 }};
    const mixed = [_]Nomination{
        .{ .net_i = 2, .priority = 3, .elements = 1 },
        .{ .net_i = 3, .priority = 0, .elements = 1 },
    };
    // Everything outranks the victim ⇒ wave == victim_last.
    try testing.expect(!orderIsNovel(.wave, 1, &above));
    // Nothing outranks it ⇒ wave == victim_first.
    try testing.expect(!orderIsNovel(.wave, 1, &below));
    // One of each ⇒ the victim sits in the middle, a sequence neither produces.
    try testing.expect(orderIsNovel(.wave, 1, &mixed));
    // The two endpoint orders are always run.
    try testing.expect(orderIsNovel(.victim_first, 1, &above));
    try testing.expect(orderIsNovel(.victim_last, 1, &below));
}

// spec: placement/joint-rescue - the joint tier's victim and attempt caps bound the whole pass, not each victim separately
test "the pass budget bounds victims and attempts together" {
    var b = Budget{ .lim = .{ .max_victims = 3, .max_attempts = 4 } };
    try testing.expect(b.takeVictim());
    try testing.expect(b.takeAttempt());
    try testing.expect(b.takeAttempt());
    try testing.expect(b.takeAttempt());
    try testing.expect(b.takeAttempt());
    try testing.expect(!b.takeAttempt()); // whole-pass attempt cap reached
    try testing.expect(!b.takeVictim()); // …which also stops handing out victims
    var v = Budget{ .lim = .{ .max_victims = 1, .max_attempts = 9 } };
    try testing.expect(v.takeVictim());
    try testing.expect(!v.takeVictim());
}

// spec: placement/joint-rescue - the joint tier's nomination order is deterministic for a given board
test "select is deterministic across runs" {
    const facts = [_]BlockerFacts{
        .{ .net_i = 9, .routed = true, .elements = 3 },
        .{ .net_i = 2, .routed = true, .elements = 3 },
        .{ .net_i = 7, .routed = true, .elements = 3 },
    };
    const a = try select(testing.allocator, &facts, .{ .net_i = 1 }, .{});
    defer testing.allocator.free(a.picked);
    defer testing.allocator.free(a.refused);
    const c = try select(testing.allocator, &facts, .{ .net_i = 1 }, .{});
    defer testing.allocator.free(c.picked);
    defer testing.allocator.free(c.refused);
    try testing.expectEqual(a.picked.len, c.picked.len);
    for (a.picked, c.picked) |x, y| try testing.expectEqual(x.net_i, y.net_i);
    try testing.expectEqual(@as(usize, 2), a.picked[0].net_i); // index tie-break
}

// ── Driver fixtures ─────────────────────────────────────────────────────────
//
// The tier is a TRANSACTION over a live routing context, so its guarantees —
// "never lowers the routed count", "a rejected cluster restores the board
// byte-identically", "a refused class is never even attempted" — are only real
// end to end. These fixtures build a small board, run the standard pipeline's
// automatic passes through `router.routeCoreStart`, and drive `run` directly on
// the live core, which is exactly what `router.finishBatch` does.

const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// A board with a net that CANNOT route, and copper beside it that can.
///
/// `W0…W18` are through-hole pads in an unbroken row: their copper exists on
/// every layer, so no maze path and no via crosses them, and they belong to no
/// net (a pure obstacle). `V1`/`V2` sit on opposite sides of that wall, so
/// `VICTIM` is unroutable however much copper is taken off the board — which is
/// the point: every cluster this tier forms for it MUST be rolled back, so the
/// fixture tests the rollback rather than the rescue. `A*`/`B*` route as short
/// hops that cross the victim's straight terminal line, so they are exactly the
/// corridor occupants `corridorCandidates` nominates.
fn walledPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const thru = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    const smd = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts: std.ArrayList(optimizer.Part) = .empty;
    try appendWall(arena, &parts, &thru);
    try appendPart(arena, &parts, "V1", 2.4, -3.0, &smd);
    try appendPart(arena, &parts, "V2", 2.4, 3.0, &smd);
    try appendPart(arena, &parts, "A1", 1.4, -2.4, &smd);
    try appendPart(arena, &parts, "A2", 3.4, -2.4, &smd);
    try appendPart(arena, &parts, "B1", 1.4, -1.2, &smd);
    try appendPart(arena, &parts, "B2", 3.4, -1.2, &smd);
    const nets = try arena.alloc(flat_netlist.FlatNet, 3);
    nets[0] = .{ .name = "VICTIM", .pins = try pinPair(arena, "V1", "V2") };
    nets[1] = .{ .name = "AAA", .pins = try pinPair(arena, "A1", "A2") };
    nets[2] = .{ .name = "BBB", .pins = try pinPair(arena, "B1", "B2") };
    return .{
        .parts = parts.items,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -3.5,
        .maxx = 5.3,
        .maxy = 3.5,
        .generated = true,
    };
}

/// The unbroken through-hole row, spanning wider than the routable extent so
/// nothing rounds the end of it.
fn appendWall(
    arena: std.mem.Allocator,
    parts: *std.ArrayList(optimizer.Part),
    pad: []const geometry.Pad,
) std.mem.Allocator.Error!void {
    for (0..19) |i| {
        const x = -3.0 + 0.6 * @as(f64, @floatFromInt(i));
        try appendPart(arena, parts, try std.fmt.allocPrint(arena, "W{d}", .{i}), x, 0, pad);
    }
}

fn appendPart(
    arena: std.mem.Allocator,
    parts: *std.ArrayList(optimizer.Part),
    ref: []const u8,
    x: f64,
    y: f64,
    pads: []const geometry.Pad,
) std.mem.Allocator.Error!void {
    try parts.append(arena, .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.35,
        .hh = 0.35,
        .pads = pads,
        .fallback = false,
        .x = x,
        .y = y,
    });
}

fn pinPair(arena: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error![]flat_netlist.FlatPin {
    const pins = try arena.alloc(flat_netlist.FlatPin, 2);
    pins[0] = .{ .ref_des = a, .pin = "1" };
    pins[1] = .{ .ref_des = b, .pin = "1" };
    return pins;
}

/// Declare every net but `VICTIM` an RF class, so the corridor holds nothing
/// this tier may take.
fn rfCorridorRules(arena: std.mem.Allocator, n: usize) std.mem.Allocator.Error![]optimizer.NetRule {
    const rules = try arena.alloc(optimizer.NetRule, n);
    for (rules, 0..) |*r, i| r.* = if (i == 0) .{} else .{ .rf = .{ .max_freq_hz = 12e9 } };
    return rules;
}

/// Start the standard pipeline and hand back the live core the tier drives.
fn liveCore(arena: std.mem.Allocator, placement: optimizer.Placement) !router.RouteCore {
    return switch (try router.routeCoreStart(arena, placement, .{}, .{}, .off)) {
        .core => |c| c,
        .done => error.EmptyGrid,
    };
}

/// How many of the working set's nets are routed right now.
fn countOk(routable: []const router.RipNet) usize {
    var n: usize = 0;
    for (routable) |rn| {
        if (rn.ok) n += 1;
    }
    return n;
}

/// Is `VICTIM` (net 0 of the fixture) still unrouted?
fn victimFailed(routable: []const router.RipNet) bool {
    for (routable) |rn| {
        if (rn.net_i == 0) return !rn.ok;
    }
    return true;
}

/// Compare two copper snapshots segment for segment and via for via. All loops
/// live here so a test body stays linear (Guardian's `test-no-conditional`).
fn expectCopperIdentical(at: []const router.Track, av: []const router.Via, bt: []const router.Track, bv: []const router.Via) !void {
    try testing.expectEqual(at.len, bt.len);
    try testing.expectEqual(av.len, bv.len);
    for (at, bt) |x, y| {
        try testing.expectApproxEqAbs(x.x1, y.x1, 1e-12);
        try testing.expectApproxEqAbs(x.y1, y.y1, 1e-12);
        try testing.expectApproxEqAbs(x.x2, y.x2, 1e-12);
        try testing.expectApproxEqAbs(x.y2, y.y2, 1e-12);
        try testing.expectEqual(x.layer, y.layer);
        try testing.expectEqual(x.net, y.net);
    }
    for (av, bv) |x, y| {
        try testing.expectApproxEqAbs(x.x, y.x, 1e-12);
        try testing.expectApproxEqAbs(x.y, y.y, 1e-12);
        try testing.expectEqual(x.net, y.net);
    }
}

// spec: placement/joint-rescue - the joint pass forms a cluster for a walled-in net and, when no order closes it, leaves the board byte-identical and the routed count unchanged
test "a rejected cluster restores the board byte-identically" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = try walledPlacement(arena);
    const core = try liveCore(arena, placement);
    try testing.expect(victimFailed(core.result.routable));
    const before_routed = countOk(core.result.routable);
    const before_t = try arena.dupe(router.Track, core.tracks.items);
    const before_v = try arena.dupe(router.Via, core.vias.items);

    const rep = try run(core);
    // The tier engaged: it took the walled net as a victim and formed a cluster
    // out of the corridor copper beside it, which it then re-routed.
    try testing.expect(rep.victims >= 1);
    try testing.expect(rep.attempts >= 1);
    // …and closed nothing, because the wall is pads. So every attempt was
    // rolled back, copper for copper.
    try testing.expectEqual(@as(usize, 0), rep.rescued);
    try testing.expectEqual(before_routed, countOk(core.result.routable));
    try expectCopperIdentical(before_t, before_v, core.tracks.items, core.vias.items);
}

// spec: placement/joint-rescue - a victim whose corridor holds only refused copper forms no cluster, so the tier never rips an RF class to reach it
test "a corridor of RF copper yields no cluster at all" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var placement = try walledPlacement(arena);
    placement.rules.net = try rfCorridorRules(arena, placement.nets.len);
    const core = try liveCore(arena, placement);
    const before_t = try arena.dupe(router.Track, core.tracks.items);
    const before_v = try arena.dupe(router.Via, core.vias.items);

    const rep = try run(core);
    try testing.expect(rep.victims >= 1); // the victim was still taken up…
    try testing.expectEqual(@as(usize, 0), rep.attempts); // …and nothing was tried
    try testing.expect(victimFailed(core.result.routable));
    try expectCopperIdentical(before_t, before_v, core.tracks.items, core.vias.items);
}

// spec: placement/joint-rescue - running the joint pass twice over the same board produces identical copper and an identical report
test "the joint pass is deterministic across runs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = try walledPlacement(arena);

    const first = try liveCore(arena, placement);
    const rep_a = try run(first);
    const a_t = try arena.dupe(router.Track, first.tracks.items);
    const a_v = try arena.dupe(router.Via, first.vias.items);

    const second = try liveCore(arena, placement);
    const rep_b = try run(second);
    try testing.expectEqual(rep_a.victims, rep_b.victims);
    try testing.expectEqual(rep_a.attempts, rep_b.attempts);
    try testing.expectEqual(rep_a.rescued, rep_b.rescued);
    try expectCopperIdentical(a_t, a_v, second.tracks.items, second.vias.items);
}
