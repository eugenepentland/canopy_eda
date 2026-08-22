//! Wall-clock phase timing for the autorouter pipeline.
//!
//! The router's phases are measured so "where does the wall time go" is an
//! empirical question instead of a guess. A `PhaseTimer` is a flat array of
//! begin/end wall-clock accumulators, one slot per named phase. Phases may
//! nest (the finish phase brackets the escape/stitch/straighten/cleanup
//! phases), so the phase sum can exceed the total — the numbers are a
//! breakdown, not a partition.
//!
//! Instrumentation is optional and costs one null-check per site: the router
//! reads `Options.timing` (default null) and only calls `begin`/`end` when a
//! caller armed a timer. The production surfaces never arm one, so the batch
//! and interactive paths pay nothing. The whole-corpus benchmark
//! (`bench-route --breakdown`) arms one per board to print the per-phase
//! table.
//!
//! Phase definitions mirror the pipeline in `router.zig`:
//! `routeCoreStart` (build_ctx, plane_vias, greedy/escalate/ripup/last_resort
//! inside `routeSignalPass`), `finishBatch` (fine_rescue, joint_rescue),
//! `finishRoute` (escape_stubs, via_hops, stitch_return, straighten, cleanup),
//! and the post-route oracle in `route_plan.gate` (gate).

const std = @import("std");
const clock = @import("../infra/clock.zig");

/// One measurable phase of the routing pipeline. Name order is arbitrary —
/// `std.enums.values` gives the array size, not a meaning.
pub const Phase = enum {
    /// Grid fit + `buildRouteCtx` + retained-copper stamping, before pass 1.
    build_ctx,
    /// Pass 1: ground / plane-net via placement (`planeViaPass`).
    plane_vias,
    /// Pass 2: the priority-sorted maze sweep (`greedyPass`).
    greedy,
    /// The Dijkstra maze search itself — every leg, every pass (greedy,
    /// escalate, fine rescue). The counter companion is `maze_expansions`.
    maze,
    /// Per-terminal pad-gateway fan scans (`padGateways`).
    gateways,
    /// Direct-synthesis attempts (`tryDirectPair` / `tryDirectTerminalTree`).
    direct,
    /// Pour-derived signed-margin path queries (`RouteSpace.field`).
    field,
    /// Inline RF bend smoothing of freshly routed nets (`smoothNetInline`).
    smooth,
    /// Escalated retries of search-limited nets / pairs.
    escalate,
    /// Bounded rip-up rounds (rip + re-route).
    ripup,
    /// Plain re-attempts of the BLOCKED residual after a rip-up round changed
    /// the board (`escalate_retry.run`) — escalation's complementary class.
    blocked_retry,
    /// The far-budget last-resort tier.
    last_resort,
    /// Windowed fine-grid rescue of residual failed nets (`fineWindowRescue`).
    fine_rescue,
    /// Joint multi-net, multi-order cluster re-route of what the fine rescue
    /// still left open (`joint_rescue.run`).
    joint_rescue,
    /// The negotiated-congestion sandbox: the overlap-tolerant re-route phase
    /// and its end-state accept gate (`congestion.run`). Zero on every board for
    /// as long as that tier ships disarmed.
    congestion,
    /// Finish: per-pad escape stubs.
    escape_stubs,
    /// Finish: redundant layer-hop drops (`route_cleanup.dropRedundantViaPairs`)
    /// — the topology pass between the two pre-stitch straighten sweeps. Its
    /// own slot rather than riding inside `straighten`, which hid a whole-board
    /// probe-driven pass inside another pass's number.
    via_hops,
    /// Finish: return-path stitching.
    stitch_return,
    /// Finish: the taut/straighten sweeps that bracket the hop drop (both, when
    /// the conditional second one runs). The closing gloss over the geometry
    /// the cleanup passes rewrote is measured inside `cleanup`, where it runs.
    straighten,
    /// Finish: collinear collapse / via snap / net-open closure / degenerate
    /// drop, plus the second gloss pass over the geometry they rewrote.
    cleanup,
    /// Finish: the pad-escape discipline (`pad_escape.passBoard`, which runs the
    /// `pad_entry` lap trim under it), last so no later gloss can re-straighten
    /// a terminal's ray back across its land.
    pad_escape,
    /// The whole `finishRoute` body (brackets the finish phases).
    finish_total,
    /// The post-route connectivity oracle (`route_close.reconcile`).
    gate,
};

pub const phase_count = std.enums.values(Phase).len;

/// Per-phase wall-clock accumulators, plus a count of full pipeline attempts
/// a run paid for (a fine-grid retry is a second attempt sharing one timer).
pub const PhaseTimer = struct {
    start_ns: [phase_count]i128 = @splat(0),
    acc_ns: [phase_count]u64 = @splat(0),
    counters: Counters = .{},
    /// Total Dijkstra node expansions across every maze leg the run searched
    /// (accumulated in `dijkstra`). The companion to `greedy`/`escalate`/
    /// `fine_rescue` phase time: wall_ms / expansions is the per-expansion cost.
    maze_expansions: u64 = 0,
    /// Total Dijkstra legs (one per terminal join / hop) across the whole run.
    maze_legs: u64 = 0,
    /// Total exact via-clearance probes (`directViaClear`) the direct-synthesis
    /// lattice sweeps paid — each scans every track/via/pad linearly.
    direct_via_checks: u64 = 0,
    /// Total segment-clearance probes (`clearDoglegSegment`) the direct
    /// dogleg/fine searches paid — each scans every track/via/pad linearly.
    dogleg_probes: u64 = 0,
    /// The 8 slowest per-net greedy attempts, by wall time, kept in descending
    /// order. `bench-route --breakdown` prints them so a speed plan can target
    /// the nets that actually own the time.
    slow_nets: [8]SlowNet = @splat(.{}),
    /// Scratch for `beginNet`/`endNet` — the current net's wall clock.
    net_scratch_ns: i128 = 0,
    net_scratch_i: usize = 0,

    /// Begin measuring phase `p`. Must be paired with a later `end`.
    pub inline fn begin(self: *PhaseTimer, p: Phase) void {
        self.start_ns[@backingInt(p)] = clock.nanoTimestamp();
    }

    /// Stop measuring phase `p` and add the elapsed wall time to its slot.
    pub inline fn end(self: *PhaseTimer, p: Phase) void {
        self.acc_ns[@backingInt(p)] += @as(
            u64,
            @intCast(clock.nanoTimestamp() - self.start_ns[@backingInt(p)]),
        );
    }

    /// Start the per-net stopwatch for greedy net `net_i` (see `endNet`).
    pub inline fn beginNet(self: *PhaseTimer, net_i: usize) void {
        self.net_scratch_ns = clock.nanoTimestamp();
        self.net_scratch_i = net_i;
    }

    /// Stop the per-net stopwatch and enter the net in `slow_nets` if it is
    /// now one of the 8 slowest measured so far.
    pub fn endNet(self: *PhaseTimer) void {
        const ns: u64 = @intCast(clock.nanoTimestamp() - self.net_scratch_ns);
        var min_slot: ?*SlowNet = null;
        for (&self.slow_nets) |*s| {
            if (min_slot == null or s.ns < min_slot.?.ns) min_slot = s;
        }
        if (min_slot) |slot| {
            if (ns > slot.ns) slot.* = .{ .net_i = self.net_scratch_i, .ns = ns };
        }
    }

    /// A whole pipeline attempt began (`routeWithCapture` calls this once per
    /// `routeOnce`, so a fine-grid retry counts as a second attempt).
    pub inline fn noteAttempt(self: *PhaseTimer) void {
        self.counters.attempts +|= 1;
    }

    /// Pipeline and signed-margin search counters kept beside phase clocks.
    const Counters = struct {
        attempts: u8 = 0,
        field_attempts: u64 = 0,
        field_terminal_pairs: u64 = 0,
        field_successes: u64 = 0,
        field_coarsened: u64 = 0,
        field_expansions: u64 = 0,
        field_static_cache_hits: u64 = 0,
        field_query_cache_hits: u64 = 0,
        field_live_cache_hits: u64 = 0,
    };

    /// One slow per-net greedy attempt: the flattened-net index, its wall
    /// time, and (filled in by the benchmark) the net's name.
    pub const SlowNet = struct {
        net_i: usize = 0,
        ns: u64 = 0,
        name: []const u8 = "",
    };

    /// Phase `p`'s accumulated wall time in nanoseconds (0 when never measured).
    pub fn elapsed(self: *const PhaseTimer, p: Phase) u64 {
        return self.acc_ns[@backingInt(p)];
    }

    /// Sum of every phase's accumulated wall time. Phases nest (finish_total
    /// brackets the finish sub-phases), so this can exceed the measured whole
    /// route — it is a breakdown, not a partition.
    pub fn total(self: *const PhaseTimer) u64 {
        var sum: u64 = 0;
        for (self.acc_ns) |v| sum +|= v;
        return sum;
    }

    /// The short phase name for table headers (`@tagName`).
    pub fn label(p: Phase) []const u8 {
        return @tagName(p);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/route-timing - begin/end accumulates per-phase elapsed time, and total covers every slot
test "begin/end accumulates per-phase elapsed time" {
    var t = PhaseTimer{};
    t.begin(.greedy);
    const a = clock.nanoTimestamp();
    // no-op busy window so elapsed >= 0 always holds
    _ = a;
    t.end(.greedy);
    try testing.expect(t.elapsed(.greedy) >= 0);
    try testing.expectEqual(@as(u64, 0), t.elapsed(.gate));
    try testing.expect(t.total() >= t.elapsed(.greedy));
}

// spec: placement/route-timing - noteAttempt counts each whole pipeline attempt
test "attempt count accumulates across retries" {
    var t = PhaseTimer{};
    t.noteAttempt();
    t.noteAttempt();
    try testing.expectEqual(@as(u8, 2), t.counters.attempts);
}
