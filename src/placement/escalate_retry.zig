//! Post-rip-up retry of the router's BLOCKED residual — the rung the
//! escalation ladder never had.
//!
//! `router.escalateSearchLimited` retries exactly one failure class: a leg that
//! ran out of node expansions (`ctx.search_limited`). Its complement — a leg
//! whose frontier DRAINED, i.e. no path existed through the copper on the board
//! at the moment it searched — is never retried, at any budget, by any later
//! tier. That is the wrong half to freeze: a budget failure means "search
//! harder", and searching harder on an unchanged board rarely changes the
//! answer, whereas a *blocked* failure means "the board was in the way" — and
//! the very next phase, rip-up, exists to take copper off the board.
//!
//! So a net walled in at greedy time stays failed even after the rip that
//! opened its corridor, unless rip-up happened to nominate it as its own seed
//! and its blocker probe happened to find something rippable. On the boards
//! here it usually does not: `router.detectBlockers`'s soft probe treats a
//! foreign PAD as a hard wall, so a net boxed in by pads yields an empty
//! rippable set and `ripUpReroute` `continue`s past it without ever attempting
//! a plain re-route (`joint_rescue`'s header records the same measurement —
//! six of barracuda's seven residual nets probe empty). And after the ladder's
//! LAST rip-up round only the last-resort escalation runs, which skips this
//! class by construction.
//!
//! This tier closes that: after a rip-up round that actually changed the board,
//! re-attempt each still-failed, non-search-limited net once, plainly, under
//! the escalated per-leg budget. It is purely ADDITIVE — a failed net has no
//! copper on the board (`router.routeNet` rolls its own attempt back), nothing
//! else is ripped, and a net that still cannot route leaves the board exactly
//! as it found it. So unlike a rip transaction there is no accept gate to fail:
//! the routed count can only rise.
//!
//! ## Why it is cheap, and where the budget is anyway
//!
//! A drained flood is *self-limiting*: if the net is still walled in, the
//! search terminates when its priority queue empties, which on a boxed-in net
//! is fast. The expensive shape is a net whose reachable region is large but
//! finite, so the retry still carries the two bounds the house rule demands —
//! a per-leg expansion budget (`Policy.budget`) and a per-net lifetime attempt
//! cap (`Policy.per_net_attempts`) plus a per-pass net cap
//! (`Policy.max_nets`) — and its own `route_timing` phase so its wall cost is
//! a measured number rather than a claim.
//!
//! The board-change guard is the other half of the budget. `State` remembers a
//! `Fingerprint` of the board it last ran against; a pass whose board is
//! unchanged since then returns without touching a net, so re-running the tier
//! at every rung of the interleave costs nothing when the rip-up round it
//! follows accepted nothing.
//!
//! ## Measured, and therefore OFF by default
//!
//! `Policy.enabled` is **false**. A/B on the whole corpus (`bench-route`,
//! ReleaseSafe, 2026-08-06, against `05e365c`): the tier fires on exactly the
//! nets it was designed for — barracuda's `SPI_MOSI`, `SPI_ADF_CSN`, the three
//! `adf4159/*_1V8` lines, `V_12V`, `buck_6v/VIN_F`, plus black-canyon's and
//! straps' residuals, 50 re-attempts corpus-wide — and **routes none of them**.
//! Completion is unchanged on every board (geomean 0.054367 → 0.054367) while
//! wall time rises: stm32n6 +19.8 s (+6.2 %), straps +3.4 s (+11 %),
//! barracuda-base +3.6 s (+2.9 %), barracuda +1.0 s (+8 %), black-canyon
//! +1.1 s (+9 %), cyclops-xband-sip +1.3 s (+3 %).
//!
//! The trace says why, and it agrees with `joint_rescue`'s independent finding:
//! a residual net whose frontier drained on these boards drained for STRUCTURAL
//! reasons — pad geometry, escape assignment, lattice resolution — so the
//! copper a rip frees was never what walled it in. That is a fact about the
//! corpus, not about the mechanism, so the rung is kept whole (driver, budgets,
//! tests, its own timing phase) and switched off rather than deleted: a board
//! class whose residual really is congestion, or the escape-assignment work
//! that would change which nets survive to this point, flips one field.
//!
//! Deterministic by construction: candidates are visited in working-set slice
//! order, every bound is a count (never a deadline), and no RNG, clock, or
//! hash-map iteration reaches a decision.

const std = @import("std");
const router = @import("router.zig");
const log = @import("../infra/log.zig");

/// Flip to true to have every pass name the nets it re-attempted and their
/// verdicts on stderr. Off in normal builds — a board whose residual is
/// genuinely sealed has nothing to say, and one being tuned is being read
/// (the `joint_rescue.trace_on` convention).
const trace_on = false;

// ── Policy ──────────────────────────────────────────────────────────────────

/// The tier's bounds. Each one exists because an unbudgeted retry loop is the
/// failure mode this router has already paid for twice (`Ctx.window_probe_budget`).
pub const Policy = struct {
    /// Does the tier run at all? FALSE, on measurement: it re-attempted 50 nets
    /// across the corpus and routed none of them, for +6 % to +11 % wall on the
    /// boards with a residual (see the header). Kept as a field rather than a
    /// deletion so the rung is one edit away when the residual class changes.
    enabled: bool = false,
    /// Most blocked nets one pass retries. A board with dozens of blocked nets
    /// is not one a re-attempt closes; it is one whose placement or escape
    /// assignment is wrong.
    max_nets: usize = 8,
    /// How many times ONE net may be re-attempted across the whole run. The
    /// interleave runs this tier once per rip-up round, so without a lifetime
    /// cap a permanently-walled net would pay a full drained flood per round.
    per_net_attempts: usize = 2,
    /// Per-leg maze expansion budget the retry runs under — `router`'s
    /// escalated tier, because a net whose corridor just opened has to search
    /// the long way round that the greedy budget could not.
    budget: usize = 400_000,
};

/// A cheap stand-in for "is this the same board as last time": how much copper
/// is on it and how many nets are routed. Any accepted rip changes at least one
/// of the two (`router.ripScoreBetter` accepts only a strictly better routed
/// count, authored priority, or shorter copper — and copper length cannot move
/// without a track moving).
pub const Fingerprint = struct {
    /// Tracks plus vias currently on the board.
    elements: usize = 0,
    /// Nets in the working set currently routed.
    routed: usize = 0,

    /// Is this the same board `other` described?
    pub fn same(self: Fingerprint, other: Fingerprint) bool {
        return self.elements == other.elements and self.routed == other.routed;
    }
};

/// Everything the candidate test needs about one working-set slot, so the
/// decision stays pure and testable away from a live routing context.
pub const Facts = struct {
    /// The net is already routed.
    ok: bool = false,
    /// The engine will re-route it (false for an atomic pair leg / hard replay).
    reroutable: bool = true,
    /// The net is in `ctx.search_limited` — a BUDGET failure, which the
    /// escalation tier already owns.
    search_limited: bool = false,
    /// Re-attempts this net has already been given by this tier.
    tries: usize = 0,
    /// `Policy.per_net_attempts`.
    max_tries: usize = 0,
};

/// Is this slot the blocked residual this tier exists for?
///
/// The class is the exact complement of `escalateSearchLimited`'s: still
/// failed, the engine is willing to re-route it, and its failure was NOT a
/// budget failure — so the only thing that can have changed the answer is the
/// board, which the rip-up round preceding this pass just changed.
pub fn isCandidate(f: Facts) bool {
    if (f.ok or !f.reroutable) return false;
    if (f.search_limited) return false;
    return f.tries < f.max_tries;
}

// ── Driver ──────────────────────────────────────────────────────────────────

/// What one pass did, for the caller's trace and this module's own tests.
pub const Report = struct {
    /// The pass ran (the board had changed since its last one).
    ran: bool = false,
    /// Nets it re-attempted.
    attempts: usize = 0,
    /// Nets that ended the pass routed and were not routed before it.
    rescued: usize = 0,
};

/// The tier's state across the whole escalate↔rip-up interleave: the policy,
/// the per-slot attempt counters, and the board it last ran against.
pub const State = struct {
    policy: Policy = .{},
    /// Re-attempts spent per working-set slot (index-parallel to
    /// `router.EscalateRun.routable`). A flat array rather than a map so the
    /// tier holds no hash-map iteration at all.
    tries: []usize = &.{},
    /// The board the previous pass left behind, or null before the first pass.
    last: ?Fingerprint = null,

    /// Allocate the per-slot counters for a working set of `slots` nets.
    pub fn init(alloc: std.mem.Allocator, slots: usize, policy: Policy) std.mem.Allocator.Error!State {
        const tries = try alloc.alloc(usize, slots);
        @memset(tries, 0);
        return .{ .policy = policy, .tries = tries };
    }

    /// Claim one re-attempt for slot `i`, or report the net is out of them.
    pub fn takeAttempt(self: *State, i: usize) bool {
        if (i >= self.tries.len) return false;
        if (self.tries[i] >= self.policy.per_net_attempts) return false;
        self.tries[i] += 1;
        return true;
    }

    /// Has the board changed since the last pass? Records `now` either way, so
    /// a caller that runs the tier every round pays one comparison when the
    /// preceding rip-up round accepted nothing.
    pub fn boardChanged(self: *State, now: Fingerprint) bool {
        defer self.last = now;
        const prev = self.last orelse return true;
        return !prev.same(now);
    }
};

/// The board `esc` currently describes, as `Fingerprint` measures it.
pub fn fingerprint(esc: router.EscalateRun) Fingerprint {
    var routed: usize = 0;
    for (esc.routable) |rn| {
        if (rn.ok) routed += 1;
    }
    return .{ .elements = esc.tracks.items.len + esc.vias.items.len, .routed = routed };
}

/// Re-attempt the blocked residual once, plainly, under the escalated budget.
///
/// Returns without touching a net when the board is unchanged since this
/// state's last pass — which is what makes it safe to call after every rip-up
/// round rather than only after one that is known to have accepted.
pub fn run(esc: router.EscalateRun, st: *State) std.mem.Allocator.Error!Report {
    if (!st.policy.enabled) return .{};
    if (!st.boardChanged(fingerprint(esc))) return .{};
    if (router.routeCancelled(esc.ctx)) return .{};
    var rep = Report{ .ran = true };
    var taken: usize = 0;
    for (esc.routable, 0..) |*rn, i| {
        if (router.routeCancelled(esc.ctx)) break; // cooperative cancel
        if (taken >= st.policy.max_nets) break;
        if (!isCandidate(.{
            .ok = rn.ok,
            .reroutable = rn.reroutable,
            .search_limited = router.searchWasLimited(esc.ctx, rn.net_i),
            .tries = st.tries[i],
            .max_tries = st.policy.per_net_attempts,
        })) continue;
        if (!st.takeAttempt(i)) continue;
        taken += 1;
        rep.attempts += 1;
        esc.ctx.escalate_budget = st.policy.budget;
        try router.rerouteNet(esc.ctx, esc.placement, esc.idx_of, rn, esc.tracks, esc.vias);
        esc.ctx.escalate_budget = 0;
        if (rn.ok) {
            router.clearSearchLimit(esc.ctx, rn.net_i);
            rep.rescued += 1;
        }
        trace(esc, rn.net_i, rn.ok);
    }
    // The pass just changed the board it will be compared against next round.
    if (rep.rescued > 0) st.last = fingerprint(esc);
    return rep;
}

/// Name one re-attempt and its verdict on stderr (see `trace_on`).
fn trace(esc: router.EscalateRun, net_i: usize, ok: bool) void {
    if (!trace_on) return;
    log.progress("blocked-retry: {s} ok={}", .{ esc.placement.nets[net_i].name, ok });
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/escalate-retry - the blocked residual is a still-failed, re-routable net whose failure was not a search-budget failure
test "the blocked class is the complement of the search-limited one" {
    try testing.expect(isCandidate(.{ .max_tries = 1 }));
    // Already routed, or frozen by the engine, is never a candidate.
    try testing.expect(!isCandidate(.{ .ok = true, .max_tries = 1 }));
    try testing.expect(!isCandidate(.{ .reroutable = false, .max_tries = 1 }));
    // A budget failure belongs to the escalation tier, not this one.
    try testing.expect(!isCandidate(.{ .search_limited = true, .max_tries = 1 }));
}

// spec: placement/escalate-retry - a net's re-attempts are capped for the whole run, so a permanently walled net cannot be re-flooded every round
test "a net's lifetime re-attempt cap bounds the tier" {
    try testing.expect(!isCandidate(.{ .tries = 2, .max_tries = 2 }));
    try testing.expect(isCandidate(.{ .tries = 1, .max_tries = 2 }));

    var st = try State.init(testing.allocator, 2, .{ .per_net_attempts = 2 });
    defer testing.allocator.free(st.tries);
    try testing.expect(st.takeAttempt(0));
    try testing.expect(st.takeAttempt(0));
    try testing.expect(!st.takeAttempt(0));
    // The cap is per slot, not per pass.
    try testing.expect(st.takeAttempt(1));
    // An out-of-range slot is refused rather than trusted.
    try testing.expect(!st.takeAttempt(9));
}

// spec: placement/escalate-retry - the tier skips a pass whose board is unchanged since its previous one, so calling it after every rip-up round costs nothing when nothing was accepted
test "an unchanged board skips the pass" {
    var st = try State.init(testing.allocator, 1, .{});
    defer testing.allocator.free(st.tries);
    // First pass always runs: nothing has been compared yet.
    try testing.expect(st.boardChanged(.{ .elements = 10, .routed = 3 }));
    try testing.expect(!st.boardChanged(.{ .elements = 10, .routed = 3 }));
    // Copper moved without the count moving — still a changed board.
    try testing.expect(st.boardChanged(.{ .elements = 9, .routed = 3 }));
    // A rip that closed a net changes the routed half.
    try testing.expect(st.boardChanged(.{ .elements = 9, .routed = 4 }));
    try testing.expect(!st.boardChanged(.{ .elements = 9, .routed = 4 }));
}

// spec: placement/escalate-retry - a board fingerprint compares copper element count and routed count, so any accepted rip reads as a change
test "the fingerprint compares both copper and routed count" {
    const a = Fingerprint{ .elements = 5, .routed = 2 };
    try testing.expect(a.same(.{ .elements = 5, .routed = 2 }));
    try testing.expect(!a.same(.{ .elements = 6, .routed = 2 }));
    try testing.expect(!a.same(.{ .elements = 5, .routed = 3 }));
}

// spec: placement/escalate-retry - the tier is disabled by default, because on the measured corpus it re-attempts the blocked residual at real wall cost and routes none of it
test "the tier ships disabled" {
    try testing.expectEqual(false, (Policy{}).enabled);
    const st = try State.init(testing.allocator, 1, .{});
    defer testing.allocator.free(st.tries);
    try testing.expectEqual(false, st.policy.enabled);
    // The switch is a field, not a deletion: a caller that measures a residual
    // class this rung can close turns it on without touching the driver.
    try testing.expectEqual(true, (Policy{ .enabled = true }).enabled);
}
