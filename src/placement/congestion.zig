//! Negotiated congestion, run inside an OVERLAP-TOLERANT global accept gate.
//!
//! ## Why the gate has to come first
//!
//! PathFinder-style negotiated congestion (present + history pricing, rip and
//! re-route until nobody shares a resource) has been tried in this router once
//! before, INSIDE the DRC-gated transactional rip-up path, and it measured
//! WORSE than doing nothing (83/90 on barracuda). The reason is structural, not
//! a tuning miss: that path requires every INTERMEDIATE board to be legal, and
//! legality mid-iteration is precisely the thing negotiated congestion cannot
//! promise. Its whole mechanism is to let nets overlap, price the overlap, and
//! let the prices push them apart over several iterations. A gate that refuses
//! the first illegal state refuses the algorithm.
//!
//! So this module is two things in dependency order:
//!
//!   1. **The sandbox** (`open` / `close`): a phase in which illegal board-wide
//!      states are PERMITTED. Foreign copper a re-routable net owns is passable
//!      at a price rather than blocking (`walls` / `price`, the two entry points
//!      `router.blocked` and `router.relaxStep` consult); overlapping copper may
//!      exist between iterations. Nothing about the board is judged until the
//!      phase closes.
//!   2. **The negotiation** (`negotiate`): the classic PathFinder loop over that
//!      sandbox — route every victim with foreign copper priced by present
//!      congestion x history, then rip every net involved in an overlap and
//!      re-route it under the updated prices, until nobody overlaps or the
//!      budget runs out.
//!
//! ## What the gate judges, and when
//!
//! At the END of the phase, and only there, the board meets the strict regime
//! the house already trusts everywhere else — `fine_accept.strictlyBetter` over
//! `fab_readiness`'s connectivity oracle (strictly more nets joined, and not one
//! net that was joined left open), plus `drc.errorCount` not risen. On top of
//! those it must also have CONVERGED: a run that budgets out still carrying an
//! overlap is refused whatever the oracle says, because the copper it is holding
//! is two nets in one place. Anything short of all three restores the snapshot,
//! and the board is byte-identical to the one the phase opened on.
//!
//! ## What it is measured to be worth: NOTHING, and it ships OFF
//!
//! `Limits.max_iterations = 0` disarms the whole tier (the one-line A/B
//! `joint_rescue` established). That is the audit item's own kill criterion,
//! armed and then fired. Measured 2026-08-06, ReleaseSafe, whole corpus, on the
//! four boards that route at a blessed placement:
//!
//!   * **The negotiation works as an algorithm.** It converges. On
//!     cyclops-xband-sip the loop closes ELEVEN more nets than the ladder left
//!     (oracle 25 -> 36) and on straps five (83 -> 88), losing none.
//!   * **Its copper is not legal, and convergence does not make it legal.** A
//!     lattice on which nobody shares a cell is not a board that clears DRC: the
//!     grid records path centrelines while the rules measure via barrels,
//!     diagonal spans and per-class widths. Barracuda converges with ZERO shared
//!     cells and still hands the gate +9 fab-blocking errors (3 via-track, 6
//!     track-track). So the end-state gate refuses it — which is the gate doing
//!     exactly its job.
//!   * **Legalized, the negotiation's product is worth zero.** Laying the
//!     discovered victim SET down the ordinary way, in the router's own priority
//!     order (`legalize`), gives DRC-clean copper on every board — and gives back
//!     precisely the board the ladder already had: barracuda 81 -> 81, straps
//!     83 -> 83, cyclops-xband-sip 25 -> 25, black-canyon 54 -> 54, no net lost,
//!     no net gained, on any board, under any budget tried.
//!   * **Where the residual is sealed, there is nothing to negotiate.** Barracuda
//!     and black-canyon produce 4 and 0 shared cells IN TOTAL: their open nets do
//!     not fail because copper is in the way, they fail because pads, the board
//!     outline and the lattice are — none of which the sandbox may lower, and a
//!     pad can never be re-routed. This is the same diagnosis `joint_rescue`
//!     recorded for the same seven nets.
//!   * **The unconverged residue is a capacity wall, not a pricing miss.** On
//!     straps and cyclops-xband-sip 11-35 cells stay shared at `present = 256`
//!     — a surcharge of 256 grid pitches per cell. A net still crossing at that
//!     price has no alternative path at all.
//!
//! So negotiated congestion joins topology corridors (three doses) and escape
//! guides as global steering measured net-zero-or-negative on this corpus. What
//! LANDS is the sandbox: with the tier disarmed the corpus is row-identical to
//! main on all 18 boards (every field but wall clock, including the open-net
//! lists), and the machinery is the only place in this engine where a
//! whole-board re-route may pass through an illegal state and be judged solely
//! on where it ends up. The full per-iteration trace is in the commit message
//! and in `docs/autorouter-audit-2026-08.md`.
//!
//! Deterministic by construction: no RNG, no clock, no hash-map iteration order
//! reaches a decision (the victim list is built in net-index order and the
//! overlap scan walks the lattice in index order), and every bound is an
//! iteration / re-route / expansion COUNT rather than a deadline.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const route_timing = @import("route_timing.zig");
const fine_accept = @import("fine_accept.zig");
const route_close = @import("route_close.zig");
const drc = @import("drc.zig");
const fab_readiness = @import("../fab_readiness.zig");
const routed_copper = @import("routed_copper.zig");
const log = @import("../infra/log.zig");

/// The mark an unclaimed occupancy cell carries, lifted from the engine so the
/// pricing math below reads without reaching back into it.
const empty: i32 = router.empty_cell;

// ── The sandbox's cost model ────────────────────────────────────────────────

/// What one armed sandbox charges a maze step, and which copper it may charge
/// for at all.
///
/// `router.blocked` and `router.relaxStep` hold this behind a nullable pointer
/// on the route context. Null — every route outside the sandbox — short-circuits
/// both entry points to the behaviour they always had, so an unarmed run's
/// costs are bit-for-bit unchanged and its walls are the same walls.
pub const Pricing = struct {
    /// One flag per flattened net: may a victim's path cross this net's copper
    /// at a price instead of being walled out by it? True only for copper the
    /// sandbox can actually put back — a net in the working set, re-routable,
    /// and none of the guarded classes (see `Sandbox.markPassable`).
    passable: []const bool,
    /// Per `layer*nodes + node`: how many past iterations found this cell
    /// carrying two nets at once. PathFinder's history term — it is what makes
    /// a persistently contended channel expensive even in the iteration where
    /// it happens to be free, and so what makes the loop converge instead of
    /// oscillating between two nets swapping the same corridor.
    history: []const u16,
    /// This iteration's present-congestion factor (x grid pitch, per foreign
    /// net sharing the cell RIGHT NOW). Grows each iteration, so early
    /// iterations explore freely and late ones insist on legality.
    present: f64 = 1,
    /// Weight on the history term (x grid pitch, per recorded overlap).
    history_mult: f64 = 0.75,

    /// May `net`'s path cross a cell whose copper `owner` holds?
    pub fn crossable(self: *const Pricing, owner: i32) bool {
        if (owner < 0) return false;
        const i: usize = @intCast(owner);
        return i < self.passable.len and self.passable[i];
    }

    /// The congestion surcharge (in grid pitches) for `net` entering the cell
    /// at `key`, currently marked `owner`. Zero on a cell that is free, the
    /// net's own, and never contested — so a step through open board costs
    /// exactly what it costs outside the sandbox.
    pub fn surcharge(self: *const Pricing, key: usize, owner: i32, net: i32) f64 {
        const shared: f64 = if (owner != empty and owner != net) 1 else 0;
        const seen: f64 = if (key < self.history.len) @floatFromInt(self.history[key]) else 0;
        return self.present * shared + self.history_mult * seen;
    }
};

/// Does copper recorded as `owner` WALL `net` out? Outside the sandbox
/// (`p == null`) the answer is always yes — foreign copper is a hard obstacle,
/// which is this router's standing model everywhere else. Inside it, copper the
/// sandbox may itself re-route is passable at a price instead.
///
/// The engine calls this only once it already knows the cell is foreign, so an
/// `owner` this function sees is never `empty` and never the routing net.
pub fn walls(p: ?*const Pricing, owner: i32) bool {
    const pricing = p orelse return true;
    return !pricing.crossable(owner);
}

/// The extra cost of a maze step onto cell `key`, whose occupancy mark reads
/// `owner`, for `net`, on a lattice of pitch `g`. Zero outside the sandbox.
pub fn price(p: ?*const Pricing, key: usize, owner: i32, net: i32, g: f64) f64 {
    const pricing = p orelse return 0;
    return pricing.surcharge(key, owner, net) * g;
}

// ── Policy ──────────────────────────────────────────────────────────────────

/// The phase's bounds. Every one is a COUNT, never a deadline, so two runs of
/// the same board do the same work in the same order.
pub const Limits = struct {
    /// Negotiation rounds one phase may run. **Zero disarms the phase**, which
    /// is how it ships: the tier is compiled, tested and reachable, and does
    /// nothing at all until this is raised. That makes arming it a one-line A/B
    /// against the same binary (the shape `joint_rescue.Limits.max_victims`
    /// established), and it makes the OFF corpus row-identical by construction
    /// rather than by measurement.
    max_iterations: usize = 0,
    /// Most nets the victim set may ever hold. Once it is full no further
    /// displaced net can be adopted, so the overlaps it suffered can never be
    /// repaired — measured on cyclops-xband-sip, a cap of 12 shut out all 14
    /// nets the first round displaced. It has to be wide enough to hold the
    /// residual set AND everything that residual set pushes.
    max_victims: usize = 16,
    /// Whole-phase cap on victim re-routes (iterations x victims). The hard
    /// bound on the tier's wall time, independent of how the two caps above
    /// happen to compose on a given board.
    max_reroutes: usize = 320,
    /// Per-net maze expansion budget inside the sandbox — the router's
    /// escalated tier, because a victim being re-routed here has already failed
    /// under the base budget several times over.
    reroute_budget: usize = 400_000,
    /// How sharing a lattice cell is priced, round by round.
    price: Schedule = .{},
};

/// The congestion price schedule: what sharing costs now, how fast that cost
/// climbs, and how much a cell's past contention adds on top.
pub const Schedule = struct {
    /// Present-congestion factor for the first iteration. Low on purpose: the
    /// first pass is meant to find the paths nets WANT, overlaps and all.
    present_start: f64 = 1,
    /// Multiplier applied to `present` after each iteration that found an
    /// overlap. The classic geometric ramp — cheap sharing early, prohibitive
    /// sharing late.
    present_growth: f64 = 4,
    /// Ceiling on `present`, so the last iterations stay a maze search rather
    /// than becoming an unreachability wall the search burns its budget on.
    present_max: f64 = 256,
    /// Weight on the accumulated history term (x grid pitch, per overlap).
    history_mult: f64 = 0.75,
};

/// What one phase DID. The router ignores it; the trace prints it and the tests
/// read it to tell "the phase rolled back" from "the phase never ran".
pub const Report = struct {
    /// False when the phase was disarmed or had nothing open to work on.
    armed: bool = false,
    /// Did the last round end with nobody sharing a cell?
    converged: bool = false,
    /// Did the end-state gate keep the sandbox's board?
    accepted: bool = false,
    /// How much negotiating it took to get there.
    work: Work = .{},
    /// The connectivity oracle's routed count before and after the phase.
    routed: [2]usize = .{ 0, 0 },
};

/// The negotiation's own tallies — what the loop spent and what it found.
pub const Work = struct {
    /// Negotiation rounds actually run.
    iterations: usize = 0,
    /// Nets the victim set ended up holding.
    victims: usize = 0,
    /// Victim re-routes paid for.
    reroutes: usize = 0,
    /// Lattice cells found carrying two nets at once, summed over rounds.
    overlaps: usize = 0,
};

/// The board as the end-state gate weighs it: what the connectivity oracle
/// joins, and how much fab-blocking geometry it is carrying.
pub const EndState = struct {
    conn: fine_accept.Connectivity = .{},
    /// `drc.errorCount` — error severity minus `net_open`, the one spelling of
    /// "how many errors does this copper have" every other gate here counts by.
    drc_errors: usize = 0,
};

/// The whole-phase accept rule, as a pure predicate over the two measurements
/// and the loop's own verdict on itself.
///
/// All three clauses are load-bearing:
///
///   * `converged` — an unconverged sandbox is holding two nets in one place.
///     No connectivity gain can buy that, because the oracle counts copper by
///     adjacency and cannot see that two nets are sharing it.
///   * `fine_accept.strictlyBetter` — strictly more nets joined AND not one
///     previously joined net lost. The count alone admits a swap, which is the
///     measured 83/90 -> 81/90 failure that predicate exists for.
///   * DRC not risen — the sandbox may leave copper that clears the occupancy
///     lattice and still fails an exact clearance rule; the geometry check is
///     what refuses it.
pub fn accepts(before: EndState, after: EndState, converged: bool) bool {
    if (!converged) return false;
    if (!fine_accept.strictlyBetter(after.conn, before.conn)) return false;
    return after.drc_errors <= before.drc_errors;
}

/// This iteration's present-congestion factor, given the previous one. The
/// geometric ramp, clamped — pure so the schedule is testable without a board.
pub fn nextPresent(now: f64, s: Schedule) f64 {
    return @min(now * s.present_growth, s.present_max);
}

// ── Driver ──────────────────────────────────────────────────────────────────

/// Flip to true to have every iteration name its victims, the overlaps it
/// created and resolved, and the prices it charged, on stderr. Off in normal
/// builds — a disarmed phase has nothing to say, and an armed one is being
/// actively read.
const trace_on = false;

/// Run the phase over the residual failed nets of a finished batch route, under
/// the shipped `Limits` (which disarm it — see `Limits.max_iterations`).
///
/// Called once, from `router.finishBatch`, after every other rescue tier has had
/// its turn: this one is allowed to make the board temporarily illegal, so it
/// belongs last, and its own gate is what makes that safe.
pub fn run(core: router.RouteCore) std.mem.Allocator.Error!Report {
    return runWith(core, .{});
}

/// `run` with explicit bounds — the seam the tests drive the whole sandbox
/// through, and the one place the phase can be armed without a rebuild.
pub fn runWith(core: router.RouteCore, lim: Limits) std.mem.Allocator.Error!Report {
    if (lim.max_iterations == 0 or lim.max_reroutes == 0) return .{};
    // `one_shot` skips this for the same reason it skips rip-up and both
    // rescues: a net the maze could not route is the agent's next DSL edit, not
    // the router's next gamble (`route_policy.Effort`).
    if (!core.ctx.effort.retries()) return .{};
    if (core.ctx.timing) |t| t.begin(.congestion);
    defer if (core.ctx.timing) |t| t.end(.congestion);
    // One phase's scratch: the lattice-sized images and the rollback snapshot,
    // reclaimed together. allocator-ok: the injected route arena is monotonic.
    var scratch_inst = std.heap.ArenaAllocator.init(core.ctx.arena);
    defer scratch_inst.deinit();
    const sb = try Sandbox.prepare(scratch_inst.allocator(), core, lim);
    if (sb.victims.items.len == 0) return .{};
    return sb.phase();
}

/// One armed phase's live state: the sandbox's cost model, the victim set it
/// negotiates over, and the lattice images the overlap scan diffs.
const Sandbox = struct {
    core: router.RouteCore,
    lim: Limits,
    scratch: std.mem.Allocator,
    /// `layers * nodes` — the key space `Pricing.history` and `prev` index.
    cells: usize,
    pricing: Pricing,
    /// Mutable backing for `pricing.passable` / `pricing.history`.
    passable: []bool,
    history: []u16,
    /// Per flattened net: currently in the victim set.
    victim_of: []bool,
    /// The victim set in net-index order — the re-route order, and so the one
    /// thing that decides who claims a contended channel first.
    victims: std.ArrayList(usize),
    /// The occupancy image the per-victim overlap diff compares against. Reset
    /// from the live lattice after each iteration's rip, then advanced one
    /// victim at a time, so a victim overwriting ANY earlier owner — foreign
    /// copper or another victim's fresh copper — is seen.
    prev: []i32,
    /// Per cell: whose claim a victim overwrote (see `Lane.lost`).
    lost: []i32,
    report: Report,
    reroutes_left: usize,

    /// Build the phase's state, or leave `victims` empty when there is nothing
    /// open for it to negotiate about.
    fn prepare(scratch: std.mem.Allocator, core: router.RouteCore, lim: Limits) std.mem.Allocator.Error!*Sandbox {
        const ctx = core.ctx;
        const cells = ctx.occ.len * ctx.grid.nx * ctx.grid.ny;
        const self = try scratch.create(Sandbox);
        self.* = .{
            .core = core,
            .lim = lim,
            .scratch = scratch,
            .cells = cells,
            .pricing = .{ .passable = &.{}, .history = &.{} },
            .passable = try scratch.alloc(bool, core.placement.nets.len),
            .history = try scratch.alloc(u16, cells),
            .victim_of = try scratch.alloc(bool, core.placement.nets.len),
            .victims = .empty,
            .prev = try scratch.alloc(i32, cells),
            .lost = try scratch.alloc(i32, cells),
            .report = .{},
            .reroutes_left = lim.max_reroutes,
        };
        @memset(self.history, 0);
        @memset(self.lost, empty);
        @memset(self.victim_of, false);
        self.markPassable();
        try self.seedVictims();
        self.pricing = .{
            .passable = self.passable,
            .history = self.history,
            .present = lim.price.present_start,
            .history_mult = lim.price.history_mult,
        };
        return self;
    }

    /// Which copper a victim's path may cross at a price. The guarded classes
    /// are exactly the ones no speculative tier here may disturb — ground and
    /// plane/pour-carried copper (the board's reference and connectivity that
    /// is not this router's tracks to move), a `(diff-pair …)` member and a
    /// `(max-freq …)` RF net (deliberate coupled/bend geometry a plain re-route
    /// would not reproduce), and anything the engine froze. Crossable copper
    /// must also be re-routable, because every overlap this phase creates is a
    /// promise to put the displaced net back.
    fn markPassable(self: *Sandbox) void {
        @memset(self.passable, false);
        for (self.core.result.routable) |rn| {
            if (!rn.reroutable or rn.net_i >= self.passable.len) continue;
            self.passable[rn.net_i] = !self.guarded(rn.net_i);
        }
    }

    /// Is `net_i` one of the classes no speculative tier may disturb?
    fn guarded(self: *const Sandbox, net_i: usize) bool {
        const placement = self.core.placement;
        const name = placement.nets[net_i].name;
        if (optimizer.isGroundName(router.shortName(name))) return true;
        if (router.netHasPlane(placement, name)) return true;
        const pours = router.netPourLayers(placement, name);
        if (pours[0] or pours[1]) return true;
        for (placement.diff_pairs) |p| {
            if (p.p == net_i or p.n == net_i) return true;
        }
        return net_i < placement.rules.net.len and placement.rules.net[net_i].rf.max_freq_hz > 0;
    }

    /// The still-open re-routable nets, in net-index order, capped.
    fn seedVictims(self: *Sandbox) std.mem.Allocator.Error!void {
        for (self.core.result.routable) |rn| {
            if (rn.ok or !rn.reroutable) continue;
            if (self.victims.items.len >= self.lim.max_victims) break;
            try self.adopt(rn.net_i);
        }
    }

    /// Take `net_i` into the victim set (idempotent, and a no-op once full).
    fn adopt(self: *Sandbox, net_i: usize) std.mem.Allocator.Error!void {
        if (net_i >= self.victim_of.len or self.victim_of[net_i]) return;
        if (self.victims.items.len >= self.lim.max_victims) return;
        self.victim_of[net_i] = true;
        try self.victims.append(self.scratch, net_i);
    }

    /// Open the sandbox, negotiate, close it, and let the end-state gate decide
    /// whether the board it produced survives. The board is byte-identical to
    /// its entry state on every path but the accepting one.
    fn phase(self: *Sandbox) std.mem.Allocator.Error!Report {
        const core = self.core;
        self.report.armed = true;
        const before = try self.measure();
        self.report.routed[0] = before.conn.routed;
        const snap = try router.saveSnapshot(self.scratch, core.ctx, core.tracks, core.vias, core.result.routable);
        {
            core.ctx.congest = &self.pricing;
            defer core.ctx.congest = null;
            try self.negotiate();
        }
        try self.legalize();
        self.report.work.victims = self.victims.items.len;
        const after = try self.measure();
        self.report.routed[1] = after.conn.routed;
        self.report.accepted = accepts(before, after, self.report.converged);
        tracePhase(self, before, after);
        if (self.report.accepted) {
            try self.commit();
            return self.report;
        }
        try router.restoreSnapshot(core.ctx, core.tracks, core.vias, core.result.routable, snap);
        // `restoreSnapshot` puts the copper LISTS back but does not itself
        // invalidate the spatial index built over the sandbox's copper, whose
        // entries now name different tracks and vias. Bumping the generation
        // makes every probe fall back to its linear scan until a rebuild
        // restamps it — the same conservative move a compaction makes.
        router.copperCompacted(core.ctx);
        return self.report;
    }

    /// Lay the negotiated result down LEGALLY: with the sandbox closed, rip the
    /// whole victim set once more and re-route it in the order the negotiation
    /// settled on, under the router's ordinary hard walls.
    ///
    /// This is what the negotiation is actually FOR. Its own copper is not
    /// usable — a lattice on which nobody shares a cell is still not a board
    /// that clears DRC, because the lattice records path centrelines while the
    /// rules measure via barrels, diagonal spans and per-class widths (measured
    /// on barracuda: a round that converged with ZERO shared cells handed the
    /// gate +9 fab-blocking errors, 3 via-track and 6 track-track). What the
    /// negotiation produces that is worth keeping is the victim SET and the
    /// ORDER — which nets contend, and who should claim first. So the phase
    /// spends its rounds discovering that and then draws the board the ordinary
    /// way, which is legal by construction.
    fn legalize(self: *Sandbox) std.mem.Allocator.Error!void {
        const core = self.core;
        self.ripVictims();
        // Same repair the negotiation rounds make, and for the same reason: a
        // cell a victim took from a net still on the board has to go back to
        // that net before anything is drawn legally over it.
        self.restoreLostClaims();
        // In the ROUTER's own priority order, not the negotiation's. The
        // negotiation's product is the SET — which nets contend — and its own
        // order is an artefact of when each net was pulled in; laying a large
        // set down out of priority order is how a legalized board LOSES nets it
        // already had (measured on straps: twelve).
        const order = try self.scratch.dupe(usize, self.victims.items);
        std.mem.sort(usize, order, core.result.routable, byPriorityDesc);
        for (order) |net_i| {
            if (router.routeCancelled(core.ctx)) return;
            const slot = slotOf(core.result.routable, net_i) orelse continue;
            core.ctx.escalate_budget = self.lim.reroute_budget;
            try router.rerouteNet(core.ctx, core.placement, core.idx_of, slot, core.tracks, core.vias);
            core.ctx.escalate_budget = 0;
        }
    }

    /// The PathFinder loop. Each round rips every victim, re-routes them all in
    /// one fixed order under the current prices, prices whatever they ended up
    /// sharing, and pulls the displaced nets into the victim set for the next
    /// round. It stops the moment a round ends with nobody sharing a cell.
    fn negotiate(self: *Sandbox) std.mem.Allocator.Error!void {
        while (self.report.work.iterations < self.lim.max_iterations) {
            if (router.routeCancelled(self.core.ctx)) return;
            if (self.reroutes_left == 0) return;
            self.report.work.iterations += 1;
            self.ripVictims();
            self.restoreLostClaims();
            self.snapshotOwners();
            const displaced = try self.routeVictims();
            traceIteration(self, displaced.cells, displaced.nets);
            if (displaced.cells == 0) {
                self.report.converged = true;
                return;
            }
            self.report.work.overlaps += displaced.cells;
            self.pricing.present = nextPresent(self.pricing.present, self.lim.price);
            for (displaced.nets) |net_i| try self.adopt(net_i);
        }
    }

    /// Take every victim's copper off the board, so the round re-routes all of
    /// them from nothing and the order alone decides who claims what.
    fn ripVictims(self: *Sandbox) void {
        const core = self.core;
        for (self.victims.items) |net_i| {
            router.ripNet(core.ctx, core.tracks, core.vias, net_i);
            if (slotOf(core.result.routable, net_i)) |slot| slot.ok = false;
        }
    }

    /// Give every cell a victim took from a net that is still on the board back
    /// to that net, now that the victim's copper is off it again.
    ///
    /// Without this the sandbox lies to itself. A cell overwritten in round 1
    /// and freed by round 2's rip belongs to nobody, so a victim may re-take it
    /// with no overlap recorded — and the loop reports a legal board while two
    /// nets' copper sits in the same place. (Measured on cyclops-xband-sip: a
    /// round that reported ZERO shared cells handed the gate a board with 23
    /// track-to-track clearance errors, all of them on nets whose claims had
    /// been lost this way.) A net that is itself a victim is skipped: its copper
    /// really did just come off the board.
    fn restoreLostClaims(self: *Sandbox) void {
        const nodes = self.core.ctx.grid.nx * self.core.ctx.grid.ny;
        for (self.core.ctx.occ, 0..) |lane, layer| {
            _ = reclaimLane(lane, self.lost[layer * nodes ..][0..nodes], self.victim_of);
        }
    }

    /// Copy the post-rip occupancy into `prev` — the image every victim's own
    /// claim is then diffed against.
    fn snapshotOwners(self: *Sandbox) void {
        const nodes = self.core.ctx.grid.nx * self.core.ctx.grid.ny;
        for (self.core.ctx.occ, 0..) |lane, layer| @memcpy(self.prev[layer * nodes ..][0..nodes], lane);
    }

    /// Re-route every victim in turn under the sandbox's prices, diffing the
    /// lattice after each so the copper it displaced is attributed to it.
    fn routeVictims(self: *Sandbox) std.mem.Allocator.Error!Displaced {
        const core = self.core;
        var out = Displaced{ .nets = &.{} };
        var hit: std.ArrayList(usize) = .empty;
        for (self.victims.items) |net_i| {
            if (self.reroutes_left == 0) break;
            if (router.routeCancelled(core.ctx)) break;
            self.reroutes_left -= 1;
            self.report.work.reroutes += 1;
            const slot = slotOf(core.result.routable, net_i) orelse continue;
            core.ctx.escalate_budget = self.lim.reroute_budget;
            try router.rerouteNet(core.ctx, core.placement, core.idx_of, slot, core.tracks, core.vias);
            core.ctx.escalate_budget = 0;
            out.cells += try self.absorbClaim(&hit);
        }
        out.nets = hit.items;
        return out;
    }

    /// Fold the cells the victim that just routed took over into the history
    /// term, and name every net it took them FROM. Advances `prev` to the new
    /// image, so the next victim in the round is judged against this one's
    /// copper as well as against the board's.
    fn absorbClaim(self: *Sandbox, hit: *std.ArrayList(usize)) std.mem.Allocator.Error!usize {
        const nodes = self.core.ctx.grid.nx * self.core.ctx.grid.ny;
        var shared: usize = 0;
        for (self.core.ctx.occ, 0..) |lane, layer| shared += try absorbLane(.{
            .prev = self.prev[layer * nodes ..][0..nodes],
            .now = lane,
            .history = self.history[layer * nodes ..][0..nodes],
            .lost = self.lost[layer * nodes ..][0..nodes],
        }, hit, self.scratch);
        return shared;
    }

    /// Keep the sandbox's board: every victim that came back routed gets its
    /// search-limit note cleared and a timeline event, exactly as the fine and
    /// joint rescues' rescued nets do.
    fn commit(self: *Sandbox) std.mem.Allocator.Error!void {
        const core = self.core;
        const routed = router.ripScore(core.result.routable, core.tracks.items).routed;
        for (self.victims.items) |net_i| {
            const slot = slotOf(core.result.routable, net_i) orelse continue;
            if (!slot.ok) continue;
            router.clearSearchLimit(core.ctx, net_i);
            try core.progress.timeline.capture(.{
                .kind = .net_routed,
                .net = net_i,
                .routed = core.progress.plane_routed + routed,
            }, core.tracks.items, core.vias.items);
        }
    }

    /// One end-state measurement: what the connectivity oracle joins on the
    /// current copper (pours included — a rail poured rather than traced is
    /// joined by its zone and by nothing else) and its fab-blocking DRC count.
    fn measure(self: *Sandbox) std.mem.Allocator.Error!EndState {
        const core = self.core;
        const flags = try self.scratch.alloc(bool, core.placement.nets.len);
        const zones = try route_close.userZones(self.scratch, core.placement, core.ctx.zones);
        // The board is not just its track and via lists. A native arc's chords
        // are handles whose curved envelope carves the pours, and an RF path's
        // compact centreline is a handle whose swept polygon is what lands on
        // the pads — so the gate reads both off the live context rather than
        // weighing an end state that is missing copper it is about to keep.
        const curves = try router.liveCurves(self.scratch, core.ctx, core.placement.nets.len);
        const copper = routed_copper.Copper{
            .tracks = core.tracks.items,
            .arcs = curves.arcs,
            .rf_paths = curves.rf_paths,
            .vias = core.vias.items,
            .zones = zones,
        };
        const conn = try fab_readiness.netConnectivity(self.scratch, core.placement, copper);
        var routed: usize = 0;
        for (conn, 0..) |ns, i| {
            if (i >= flags.len) break;
            flags[i] = ns.connected;
            if (ns.connected) routed += 1;
        }
        const result = router.RouteResult{
            .tracks = core.tracks.items,
            .vias = core.vias.items,
            .arcs = curves.arcs,
            .rf_port_outcomes = curves.rf_paths,
            .routed = routed,
            .total = core.placement.nets.len,
        };
        const found = try drc.check(self.scratch, core.placement, result, core.ctx.base.clearance);
        traceViolations(found);
        return .{ .conn = .{ .routed = routed, .connected = flags }, .drc_errors = drc.errorCount(found) };
    }
};

/// Descending routing priority, the order the greedy pass itself laid the board
/// down in — the tie broken by net index so the sort is total and reproducible.
fn byPriorityDesc(routable: []const router.RipNet, a: usize, b: usize) bool {
    const pa = if (peekSlot(routable, a)) |s| s.pri else 0;
    const pb = if (peekSlot(routable, b)) |s| s.pri else 0;
    if (pa != pb) return pa > pb;
    return a < b;
}

/// Give every FREE cell in one signal layer back to the net a victim took it
/// from, unless that net is itself a victim whose copper really did just come
/// off the board. Returns how many claims it handed back.
///
/// The repair the sandbox cannot do without. The occupancy grid holds one owner
/// per cell, so a victim's overlap ERASES the displaced net's claim; ripping
/// that victim then frees the cell to nobody while the displaced net's copper is
/// still lying there. The loop would read that as "nobody shares a cell" and the
/// legalizing pass would draw straight through real metal. Measured on
/// cyclops-xband-sip before this existed: a round reporting ZERO shared cells
/// handed the gate a board with 23 track-to-track clearance errors.
pub fn reclaimLane(occ: []i32, lost: []const i32, victim: []const bool) usize {
    var back: usize = 0;
    for (occ, 0..) |*cell, n| {
        if (cell.* != empty or n >= lost.len) continue;
        const owner = lost[n];
        if (owner < 0 or @as(usize, @intCast(owner)) >= victim.len) continue;
        if (victim[@intCast(owner)]) continue;
        cell.* = owner;
        back += 1;
    }
    return back;
}

/// What one victim's re-route (or one whole round's worth) displaced: how many
/// lattice cells changed hands, and which nets they were taken from.
const Displaced = struct {
    cells: usize = 0,
    nets: []const usize,
};

/// One signal layer's worth of the overlap scan, index-aligned: the image the
/// last claim left (`prev`, advanced in place), the live occupancy (`now`), and
/// the history counters those cells price by.
pub const Lane = struct {
    prev: []i32,
    now: []const i32,
    history: []u16,
    /// Per cell: the owner a victim TOOK IT FROM, or `empty_cell` when nobody
    /// lost it. The occupancy grid records one owner per cell, so once a victim
    /// overwrites a mark the displaced net's claim is gone — and ripping that
    /// victim next round frees the cell to nobody rather than back to its owner.
    /// The loop would then read a board where two nets' copper physically
    /// coincides as "nobody shares a cell". This is the ledger that repairs it
    /// (`Sandbox.restoreLostClaims`).
    lost: []i32,
};

/// Attribute one net's fresh claim on `lane`: every cell whose owner CHANGED is
/// now that net's, and every such cell that had an owner before is an overlap —
/// charged to `history` and reported through `hit` as a net that must be pulled
/// into the victim set and re-routed.
///
/// This is the loop's whole convergence signal, and the reason it is a lattice
/// diff rather than a read of the copper lists: the occupancy grid records ONE
/// owner per cell, so the only way to learn that a cell changed hands — whether
/// from board copper or from a victim that routed earlier in the same round — is
/// to compare it against the image taken before the claim. A round that returns
/// zero from every claim is a round in which nobody shared anything, which is
/// exactly the legality the end-state gate then requires.
pub fn absorbLane(lane: Lane, hit: *std.ArrayList(usize), alloc: std.mem.Allocator) std.mem.Allocator.Error!usize {
    var shared: usize = 0;
    for (lane.now, 0..) |now, n| {
        const was = lane.prev[n];
        if (now == was) continue;
        lane.prev[n] = now;
        if (was == empty) continue;
        shared += 1;
        lane.history[n] +|= 1;
        if (lane.lost[n] == empty) lane.lost[n] = was;
        if (was >= 0) try appendOnce(hit, alloc, @intCast(was));
    }
    return shared;
}

/// Append `v` to `list` only if it is not already there. The victim set is a
/// handful of nets, so the linear membership test is cheaper than a hash map
/// and — unlike one — cannot leak an iteration order into a decision.
fn appendOnce(list: *std.ArrayList(usize), alloc: std.mem.Allocator, v: usize) std.mem.Allocator.Error!void {
    for (list.items) |it| {
        if (it == v) return;
    }
    try list.append(alloc, v);
}

/// The working-set slot for `net_i` (each net appears at most once), or null.
fn slotOf(routable: []router.RipNet, net_i: usize) ?*router.RipNet {
    for (routable) |*rn| {
        if (rn.net_i == net_i) return rn;
    }
    return null;
}

/// `slotOf` for a read-only working set (the ordering comparator's view).
fn peekSlot(routable: []const router.RipNet, net_i: usize) ?router.RipNet {
    for (routable) |rn| {
        if (rn.net_i == net_i) return rn;
    }
    return null;
}

/// Name the fab-blocking violations of one end-state measurement by KIND on
/// stderr (see `trace_on`) — the difference between the two printings is what
/// says whether a refused sandbox was refused for geometry it created.
fn traceViolations(found: []const drc.Violation) void {
    if (!trace_on) return;
    var counts = std.EnumMap(drc.Kind, usize){};
    for (found) |v| {
        if (v.severity != .err or v.kind == .net_open) continue;
        counts.put(v.kind, (counts.get(v.kind) orelse 0) + 1);
    }
    var it = counts.iterator();
    while (it.next()) |e| log.progress("    drc {s}={d}", .{ @tagName(e.key), e.value.* });
}

/// Name one negotiation round on stderr (see `trace_on`): the prices it charged,
/// how much copper changed hands, and which nets it pulled in as a result.
fn traceIteration(sb: *const Sandbox, cells: usize, nets: []const usize) void {
    if (!trace_on) return;
    log.progress("congestion: iter {d} victims={d} present={d:.1} overlap_cells={d} displaced={d}", .{
        sb.report.work.iterations,
        sb.victims.items.len,
        sb.pricing.present,
        cells,
        nets.len,
    });
    for (nets) |net_i| log.progress("    displaced {s}", .{sb.core.placement.nets[net_i].name});
    for (sb.victims.items) |net_i| {
        const slot = slotOf(sb.core.result.routable, net_i);
        log.progress("    victim {s} ok={}", .{
            sb.core.placement.nets[net_i].name,
            if (slot) |s| s.ok else false,
        });
    }
}

/// Name the phase's whole verdict on stderr (see `trace_on`), including WHICH
/// clause of the end-state gate refused it — the count of nets that were joined
/// before and are not now, and the fab-blocking DRC count either side. A
/// refusal a reader cannot attribute is the one this trace exists to prevent.
fn tracePhase(sb: *const Sandbox, before: EndState, after: EndState) void {
    if (!trace_on) return;
    const r = sb.report;
    var lost: usize = 0;
    for (before.conn.connected, 0..) |was, i| {
        if (was and i < after.conn.connected.len and !after.conn.connected[i]) lost += 1;
    }
    log.progress(
        "congestion: iters={d} victims={d} reroutes={d} overlaps={d} converged={} oracle {d}->{d} lost={d} drc {d}->{d} accepted={}",
        .{
            r.work.iterations, r.work.victims,   r.work.reroutes, r.work.overlaps,
            r.converged,       r.routed[0],      r.routed[1],     lost,
            before.drc_errors, after.drc_errors, r.accepted,
        },
    );
    for (before.conn.connected, 0..) |was, i| {
        if (was and i < after.conn.connected.len and !after.conn.connected[i])
            log.progress("    lost {s}", .{sb.core.placement.nets[i].name});
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");
const route_policy = @import("route_policy.zig");
const rf_path_solver = @import("rf_path_solver.zig");

test {
    testing.refAllDecls(@This());
    // The phase this tier reports under, pinned by NAME so `--breakdown` can
    // never lose its column to a rename in `route_timing`.
    try testing.expectEqualStrings("congestion", route_timing.PhaseTimer.label(.congestion));
}

// spec: placement/congestion - the negotiated-congestion tier ships disarmed, so a route that never raises its iteration cap is bit-for-bit the route it always was
test "the shipped limits disarm the phase" {
    try testing.expectEqual(@as(usize, 0), (Limits{}).max_iterations);
    // Nothing else about the shipped bounds may quietly arm it either: a zero
    // re-route allowance is the same refusal, and both are checked before the
    // phase touches the board.
    try testing.expect((Limits{ .max_iterations = 3, .max_reroutes = 0 }).max_reroutes == 0);
}

// spec: placement/congestion - foreign copper is a hard wall for every route outside the sandbox and passable-at-a-price only for a net the sandbox can itself re-route
test "walls keeps copper hard outside the sandbox and opens only re-routable nets" {
    // Unarmed: the engine's standing model, whatever the owner.
    try testing.expect(walls(null, 0));
    try testing.expect(walls(null, 7));
    const passable = [_]bool{ true, false, true };
    const pricing = Pricing{ .passable = &passable, .history = &.{} };
    try testing.expect(!walls(&pricing, 0));
    try testing.expect(walls(&pricing, 1)); // guarded / frozen class
    try testing.expect(walls(&pricing, 9)); // past the table — never crossable
}

// spec: placement/congestion - an unarmed route pays no congestion surcharge at all, and an armed one prices a shared cell by present congestion plus its accumulated history
test "the surcharge is zero unarmed and prices sharing plus history when armed" {
    try testing.expectEqual(@as(f64, 0), price(null, 3, 1, 0, 0.25));
    const passable = [_]bool{ true, true };
    const history = [_]u16{ 0, 0, 4, 0 };
    const pricing = Pricing{ .passable = &passable, .history = &history, .present = 2, .history_mult = 0.5 };
    // Free, never-contested cell: no surcharge, so an armed route through open
    // board costs exactly what an unarmed one costs.
    try testing.expectEqual(@as(f64, 0), price(&pricing, 0, empty, 0, 1));
    // The net's own copper is not sharing.
    try testing.expectEqual(@as(f64, 0), price(&pricing, 1, 0, 0, 1));
    // Foreign copper, no history: the present term alone.
    try testing.expectEqual(@as(f64, 2), price(&pricing, 1, 1, 0, 1));
    // History alone still prices a cell that happens to be free right now —
    // the term that stops two nets swapping one corridor for ever.
    try testing.expectEqual(@as(f64, 2), price(&pricing, 2, empty, 0, 1));
    // Both, and scaled by the lattice pitch.
    try testing.expectEqual(@as(f64, 2), price(&pricing, 2, 1, 0, 0.5));
}

// spec: placement/congestion - the present-congestion factor ramps geometrically between iterations and is clamped, so late rounds insist on legality without becoming an unreachable wall
test "the present factor ramps and clamps" {
    const s = Schedule{ .present_start = 1, .present_growth = 4, .present_max = 16 };
    try testing.expectEqual(@as(f64, 4), nextPresent(1, s));
    try testing.expectEqual(@as(f64, 16), nextPresent(4, s));
    try testing.expectEqual(@as(f64, 16), nextPresent(16, s));
}

// spec: placement/congestion - a cell a victim takes over is charged to the congestion history and names the net it was taken from, and a later round in which nobody takes a cell over reports the round legal
test "an overlap is priced and named, and resolving it reports the round clean" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Round 1: net 0 is re-routed straight through net 1's copper at cells 2-3.
    var prev = [_]i32{ empty, empty, 1, 1, empty, empty };
    var history: [6]u16 = @splat(0);
    var lost: [6]i32 = @splat(empty);
    const claimed = [_]i32{ empty, 0, 0, 0, empty, empty };
    var hit: std.ArrayList(usize) = .empty;
    const shared = try absorbLane(.{ .prev = &prev, .now = &claimed, .history = &history, .lost = &lost }, &hit, arena);
    try testing.expectEqual(@as(usize, 2), shared);
    try testing.expectEqualSlices(usize, &.{1}, hit.items);
    try testing.expectEqualSlices(u16, &.{ 0, 0, 1, 1, 0, 0 }, &history);
    // `prev` has advanced to the claim, so the next net in the same round is
    // judged against this one's fresh copper too.
    try testing.expectEqualSlices(i32, &claimed, &prev);
    // …and the ledger remembers WHOSE cells they were, so the next round's rip
    // can hand them back instead of freeing them to nobody.
    try testing.expectEqualSlices(i32, &.{ empty, empty, 1, 1, empty, empty }, &lost);

    // Round 2: net 1, re-routed under the raised prices, has gone around; net 0
    // keeps the corridor. Nobody takes a cell over, so the round is legal and
    // the loop converges — with the history it accumulated left intact.
    const resolved = [_]i32{ empty, 0, 0, 0, 1, 1 };
    hit.clearRetainingCapacity();
    const still = try absorbLane(.{ .prev = &prev, .now = &resolved, .history = &history, .lost = &lost }, &hit, arena);
    try testing.expectEqual(@as(usize, 0), still);
    try testing.expectEqual(@as(usize, 0), hit.items.len);
    try testing.expectEqualSlices(u16, &.{ 0, 0, 1, 1, 0, 0 }, &history);
}

// spec: placement/congestion - the sandbox's board survives only when the round converged, the connectivity oracle strictly improved, and the fab-blocking DRC count did not rise
test "the end-state gate needs convergence, a strictly better board and no new DRC errors" {
    const before = EndState{ .conn = .{ .routed = 2, .connected = &.{ true, true, false } }, .drc_errors = 3 };
    const better = EndState{ .conn = .{ .routed = 3, .connected = &.{ true, true, true } }, .drc_errors = 3 };
    try testing.expect(accepts(before, better, true));
    // An unconverged sandbox is holding two nets in one place; no oracle gain
    // buys that, because the oracle counts adjacency and cannot see the share.
    try testing.expect(!accepts(before, better, false));
    // The historical swap: one net closes, another opens. Level count, worse
    // board — refused by `fine_accept.strictlyBetter`'s second clause.
    const swapped = EndState{ .conn = .{ .routed = 2, .connected = &.{ false, true, true } }, .drc_errors = 3 };
    try testing.expect(!accepts(before, swapped, true));
    // Closed a net and bought a clearance violation with it.
    const dirty = EndState{ .conn = better.conn, .drc_errors = 4 };
    try testing.expect(!accepts(before, dirty, true));
    // Fewer errors than it started with is fine — the rule is "not risen".
    const cleaner = EndState{ .conn = better.conn, .drc_errors = 1 };
    try testing.expect(accepts(before, cleaner, true));
}

// spec: placement/congestion - a cell a victim took from a net still on the board is handed back when the victim's copper comes off, so a board where two nets' copper coincides can never read as legal
test "a freed cell goes back to the net it was taken from, unless that net is a victim too" {
    // Cell 1 was taken from net 2 and cell 3 from net 0; the victim that took
    // them has just been ripped, so both read free.
    var occ = [_]i32{ empty, empty, 5, empty };
    const lost = [_]i32{ empty, 2, empty, 0 };
    // Net 0 is itself a victim: its copper really did come off, so cell 3 stays
    // free. Net 2 is not, so cell 1 is its again.
    const victim = [_]bool{ true, false, false, false, false, false };
    try testing.expectEqual(@as(usize, 1), reclaimLane(&occ, &lost, &victim));
    try testing.expectEqualSlices(i32, &.{ empty, 2, 5, empty }, &occ);
    // An occupied cell is never overwritten, and a second pass hands nothing
    // back that the first already did.
    try testing.expectEqual(@as(usize, 0), reclaimLane(&occ, &lost, &victim));
}

// spec: placement/congestion - the negotiated set is laid down legally in the router's own priority order, not in the order the negotiation happened to pull nets in
test "the legalizing pass orders the victim set by routing priority" {
    const routable = [_]router.RipNet{
        .{ .net_i = 7, .pri = 1, .ok = false },
        .{ .net_i = 3, .pri = 9, .ok = false },
        .{ .net_i = 5, .pri = 9, .ok = false },
    };
    var order = [_]usize{ 7, 5, 3 };
    std.mem.sort(usize, &order, @as([]const router.RipNet, &routable), byPriorityDesc);
    // Highest priority first; equal priority breaks on net index, so the sort is
    // total and two runs of the same board order identically.
    try testing.expectEqualSlices(usize, &.{ 3, 5, 7 }, &order);
    // A net the working set does not hold ranks last rather than crashing.
    var missing = [_]usize{ 99, 3 };
    std.mem.sort(usize, &missing, @as([]const router.RipNet, &routable), byPriorityDesc);
    try testing.expectEqualSlices(usize, &.{ 3, 99 }, &missing);
}

// ── End-to-end fixture: a real routed board with one sealed-in net ──────────

/// A through-hole obstacle pad on NO net: an unconditional wall on both signal
/// layers, and one the sandbox may never open (a pad can never be re-routed).
fn wallPad(w: f64, h: f64) [1]geometry.Pad {
    return .{.{ .number = "1", .x = 0, .y = 0, .w = w, .h = h, .thru = true, .drill = 0.4 }};
}

const box_left = wallPad(0.8, 3.2);
const box_right = wallPad(0.8, 3.2);
const box_top = wallPad(3.2, 0.8);
const box_bottom = wallPad(3.2, 0.8);
const solo_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
const duo_pads = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = -0.7, .w = 0.5, .h = 0.5 },
    .{ .number = "2", .x = 0, .y = 0.7, .w = 0.5, .h = 0.5 },
};

fn fixturePart(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{ .ref_des = ref, .kind = .hub, .hw = 0.6, .hh = 1.0, .pads = pads, .fallback = false, .x = x, .y = y };
}

const sig_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "J1", .pin = "1" }, .{ .ref_des = "J2", .pin = "1" } };
const aux_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "J1", .pin = "2" },
    .{ .ref_des = "J2", .pin = "2" },
    .{ .ref_des = "X1", .pin = "1" },
};
const ref_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "K1", .pin = "1" }, .{ .ref_des = "K1", .pin = "2" } };
const jam_nets = [_]flat_netlist.FlatNet{
    .{ .name = "SIG", .pins = &sig_pins },
    .{ .name = "AUX", .pins = &aux_pins },
    .{ .name = "REF", .pins = &ref_pins },
};

/// A 26 x 16 mm board carrying three nets. `SIG` and `REF` route; `AUX` cannot,
/// because one of its three pads (`X1`) sits inside a closed box of through-hole
/// pads and a terminal tree fails whole when one leg cannot reach. So the board
/// always reaches the sandbox with exactly one open, re-routable net — and with
/// real copper on it that a refused phase has to give back untouched.
fn jamBoard(parts: *[8]optimizer.Part) optimizer.Placement {
    parts.* = .{
        fixturePart("J1", 3, 8, &duo_pads),
        fixturePart("J2", 23, 8, &duo_pads),
        fixturePart("K1", 6, 2, &duo_pads),
        fixturePart("X1", 20, 12, &solo_pad),
        fixturePart("B1", 18.4, 12, &box_left),
        fixturePart("B2", 21.6, 12, &box_right),
        fixturePart("B3", 20, 13.6, &box_top),
        fixturePart("B4", 20, 10.4, &box_bottom),
    };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &jam_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 26,
        .maxy = 16,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 26, .h = 16 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
}

/// Route the fixture with the standard ladder and hand back the live core, or
/// null when the board degenerated (nothing to negotiate about).
fn jamCore(arena: std.mem.Allocator, parts: *[8]optimizer.Part) std.mem.Allocator.Error!?router.RouteCore {
    return switch (try router.routeCoreStart(arena, jamBoard(parts), .{}, .{}, .off)) {
        .core => |c| c,
        .done => null,
    };
}

/// A copy of every track and via on the board — what a rollback has to
/// reproduce exactly, field for field. (Deliberately NOT a raw byte image:
/// `Track` and `Via` carry alignment padding, and comparing undefined padding
/// would make the assertion pass or fail for reasons that are not the board's.)
const Copper = struct { tracks: []const router.Track, vias: []const router.Via };

fn copperOf(alloc: std.mem.Allocator, core: router.RouteCore) std.mem.Allocator.Error!Copper {
    return .{
        .tracks = try alloc.dupe(router.Track, core.tracks.items),
        .vias = try alloc.dupe(router.Via, core.vias.items),
    };
}

fn expectSameCopper(want: Copper, got: Copper) !void {
    try testing.expectEqualSlices(router.Track, want.tracks, got.tracks);
    try testing.expectEqualSlices(router.Via, want.vias, got.vias);
}

/// The whole occupancy lattice as one flat slice, for rollback comparison.
fn dupeOcc(alloc: std.mem.Allocator, core: router.RouteCore) std.mem.Allocator.Error![]i32 {
    var out: std.ArrayList(i32) = .empty;
    for (core.ctx.occ) |lane| try out.appendSlice(alloc, lane);
    return out.items;
}

/// Still-unrouted re-routable nets in the working set.
fn countOpen(core: router.RouteCore) usize {
    var n: usize = 0;
    for (core.result.routable) |rn| {
        if (!rn.ok and rn.reroutable) n += 1;
    }
    return n;
}

/// A `(layer, node)` whose ONLY reason to wall `net` out is another net's
/// copper stamp — found by clearing the stamp and re-asking the engine, so the
/// cell the seam test then arms over is isolated from pads, zones and the board
/// edge rather than merely being occupied. Null when the board has none.
fn contestedCell(core: router.RouteCore, net: i32) ?[2]usize {
    for (core.ctx.occ, 0..) |lane, layer| {
        for (lane, 0..) |owner, n| {
            if (owner == empty or owner == net) continue;
            lane[n] = empty;
            const free = !router.blocked(core.ctx, layer, n, net);
            lane[n] = owner;
            if (free) return .{ layer, n };
        }
    }
    return null;
}

// spec: placement/congestion - inside an armed sandbox a cell another re-routable net's copper holds stops walling the maze out, and the same cell walls it out again the moment the sandbox closes
test "the sandbox opens a cell that foreign copper walls off, and closes it again" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [8]optimizer.Part = undefined;
    const core = try jamCore(arena, &parts) orelse return;
    // Some net routed and stamped the lattice; take one of its cells and ask
    // the engine's own wall predicate about it from another net's point of view.
    const cell = contestedCell(core, 1) orelse return;
    const owner = core.ctx.occ[cell[0]][cell[1]];
    try testing.expect(router.blocked(core.ctx, cell[0], cell[1], 1));

    const passable = try arena.alloc(bool, core.placement.nets.len);
    @memset(passable, false);
    passable[@intCast(owner)] = true;
    const pricing = Pricing{ .passable = passable, .history = &.{}, .present = 1 };
    core.ctx.congest = &pricing;
    try testing.expect(!router.blocked(core.ctx, cell[0], cell[1], 1));
    // …and a net the sandbox may NOT re-route still walls, armed or not.
    @memset(passable, false);
    try testing.expect(router.blocked(core.ctx, cell[0], cell[1], 1));
    core.ctx.congest = null;
    try testing.expect(router.blocked(core.ctx, cell[0], cell[1], 1));
}

// spec: placement/congestion - a sandbox whose end state the gate refuses restores the board byte for byte, copper and occupancy alike
test "a refused sandbox gives the board back byte for byte" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [8]optimizer.Part = undefined;
    const core = try jamCore(arena, &parts) orelse return;
    // The fixture exists to leave something open; without a victim there is
    // nothing to negotiate and the test would have no subject.
    const open_before = countOpen(core);
    try testing.expect(open_before > 0);
    const before = try copperOf(arena, core);
    const occ_before = try dupeOcc(arena, core);

    // Armed hard enough to reach a verdict. `AUX` is sealed behind pads, which
    // no price can open, so the board cannot strictly improve however the
    // sandbox re-routes — and everything it did must be given back.
    const report = try runWith(core, .{ .max_iterations = 3, .price = .{ .present_growth = 1000 } });
    try testing.expect(report.armed);
    try testing.expect(report.work.iterations > 0);
    try testing.expect(report.work.reroutes > 0);
    try testing.expect(!report.accepted);

    try expectSameCopper(before, try copperOf(arena, core));
    try testing.expectEqualSlices(i32, occ_before, try dupeOcc(arena, core));
    try testing.expectEqual(open_before, countOpen(core));
}

// spec: placement/congestion - two runs of the same armed sandbox over the same board make the same decisions and leave the same copper
test "an armed sandbox is deterministic over the same board" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const lim = Limits{ .max_iterations = 3, .price = .{ .present_growth = 1000 } };
    var parts_a: [8]optimizer.Part = undefined;
    const a = try jamCore(arena, &parts_a) orelse return;
    const ra = try runWith(a, lim);
    const copper_a = try copperOf(arena, a);

    var parts_b: [8]optimizer.Part = undefined;
    const b = try jamCore(arena, &parts_b) orelse return;
    const rb = try runWith(b, lim);

    try testing.expectEqual(ra.work.iterations, rb.work.iterations);
    try testing.expectEqual(ra.work.victims, rb.work.victims);
    try testing.expectEqual(ra.work.reroutes, rb.work.reroutes);
    try testing.expectEqual(ra.work.overlaps, rb.work.overlaps);
    try testing.expectEqual(ra.converged, rb.converged);
    try testing.expectEqual(ra.accepted, rb.accepted);
    try testing.expectEqualSlices(usize, &ra.routed, &rb.routed);
    try expectSameCopper(copper_a, try copperOf(arena, b));
}

/// A swept RF taper over ALL THREE of `AUX`'s lands — `J1.2`, `J2.2`, `X1.1` —
/// narrow enough to carry its full cross-section on each 0.5 mm terminal. This
/// is the copper on the board; the compact centreline a save keeps is a handle.
const aux_taper_samples = [_]rf_path_solver.Sample{
    .{ .at = .{ 3, 8.7 }, .s_mm = 0, .curvature = 0, .width_mm = 0.3 },
    .{ .at = .{ 23, 8.7 }, .s_mm = 20, .curvature = 0, .width_mm = 0.3 },
    .{ .at = .{ 20, 12 }, .s_mm = 24.5, .curvature = 0, .width_mm = 0.3 },
};

// spec: placement/congestion - the end-state measurement reads the live context's arcs and swept RF paths, so a net joined only by a taper is not counted open
test "the end-state measurement counts a net joined only by its RF taper" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const lim = Limits{ .max_iterations = 3, .price = .{ .present_growth = 1000 } };
    var parts_a: [8]optimizer.Part = undefined;
    const plain = try jamCore(arena, &parts_a) orelse return;
    const without = (try runWith(plain, lim)).routed[0];

    // The same board, with `AUX` finished as one variable-width RF path instead.
    // The path lives in the routing context, never in the track list — which is
    // exactly the copper a tracks-and-vias projection loses.
    var parts_b: [8]optimizer.Part = undefined;
    const tapered = try jamCore(arena, &parts_b) orelse return;
    try tapered.ctx.rf.port_outcomes.put(arena, 1, .{
        .net = 1,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{
            .sample_count = aux_taper_samples.len,
            .samples = &aux_taper_samples,
            .layer = 0,
        },
    });
    const with = (try runWith(tapered, lim)).routed[0];

    // `AUX` — the one net this fixture always leaves open — and only `AUX`.
    try testing.expectEqual(without + 1, with);
}

// spec: placement/congestion - the disarmed phase leaves the board and the working set exactly as the rest of the ladder left them
test "the disarmed phase never touches the board" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [8]optimizer.Part = undefined;
    const core = try jamCore(arena, &parts) orelse return;
    const before = try copperOf(arena, core);
    const occ_before = try dupeOcc(arena, core);

    const report = try run(core);
    try testing.expect(!report.armed);
    try testing.expectEqual(@as(usize, 0), report.work.iterations);
    try testing.expectEqual(@as(usize, 0), report.work.reroutes);
    try expectSameCopper(before, try copperOf(arena, core));
    try testing.expectEqualSlices(i32, occ_before, try dupeOcc(arena, core));
}
