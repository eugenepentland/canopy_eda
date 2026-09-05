//! `route_order_search` CLI tool — search the ROUTING ORDER of a contended net
//! cluster and report the best one it found, as a paste-ready DSL edit.
//!
//! The lever it turns is the one `(pcb-plan (route (wave …)))` already exposes:
//! earlier waves route first and claim the cleanest space, so which of two nets
//! contending for one corridor goes first can decide whether the other closes at
//! all. Moving board-a's `v3v3a-pour` wave above `control-clock-escape` — ONE
//! transposition — is worth two closed nets and halves the DRC error count,
//! because closing `V_3V3A` cascades into `GND`, `V_5VA`, `BOOST22_SW` and an
//! ADF chip-select. That was found by hand, one experiment at a time. This tool
//! runs the experiments: given the same three-wave cluster it measured six
//! orderings in 15 minutes and came back with a BETTER one — 81/90 at 20 DRC
//! errors against the authored plan's 77/90 at 51.
//!
//! Three things make it a search rather than a re-route:
//!
//!   * **The cluster comes from the diagnoses.** A baseline route's `stuck[]`
//!     already names, per failed net, the foreign copper that walled it in
//!     ("SPI_LMX_CSN was walled in by lower/equal-priority copper (chiefly
//!     SPI_SCK) that routed first"). Nets that name each other, plus the
//!     blockers they name, ARE the contended cluster — no guessing which knobs
//!     to turn. An explicit `nets` argument overrides the derivation.
//!
//!   * **An ordering is a PERMUTATION OF PRIORITY SLOTS, not a new plan.** The
//!     cluster's nets collectively hold a multiset of authored wave priorities;
//!     a candidate reassigns those same slots among those same nets. Every
//!     non-cluster net keeps its priority exactly, so a trial changes the
//!     cluster's internal order and NOTHING else — which is what makes the
//!     winning trial expressible as "reorder these wave forms, leave the rest".
//!     Layer masks, waypoints and via budgets stay with their own net.
//!
//!   * **Every trial is judged by the CONNECTIVITY ORACLE.** The router's own
//!     tally answers "did each leg's search succeed", which on this board reads
//!     81 while the oracle finds 76 — an ordering search steered by the
//!     optimistic number would chase phantoms. Routing goes through
//!     `route_plan`'s shared gate, so `routed`/`total` here are the same numbers
//!     `describe_pcb_layout` reports, with the ERROR-severity DRC count as
//!     tiebreak.
//!
//! It EDITS NO DESIGN FILE: the winning ordering comes back as printable DSL
//! guidance for a human or agent to apply. It does write ONE thing — every trial
//! it ran, appended to the design's trial-memory sidecar
//! (`<design>.trials.json`, the log `record_route_trial` writes and
//! `list_route_trials` reads) tagged `source:"order_search"`. Up to 48
//! whole-board routes per call used to leave no trace at all: the most expensive
//! search in the system was the only one whose results an agent had to
//! hand-transcribe, and a later call could not tell it had already measured an
//! ordering. `record:false` opts a throwaway probe out.

const std = @import("std");
const mcp_arg_names = @import("mcp_arg_names.zig");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const route_policy = @import("../placement/route_policy.zig");
const router = @import("../placement/router.zig");
const route_diagnose = @import("../placement/route_diagnose.zig");
const optimizer = @import("../placement/optimizer.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const pour = @import("../placement/pour.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const route_score = @import("../placement/route_score.zig");
const mcp_route_trials = @import("mcp_route_trials.zig");

const HandlerError = pcb_layout_page.HandlerError;

/// Most nets one auto-derived cluster may hold. Beyond this the candidate set
/// stops being a search and becomes a sampling of an enormous space, and each
/// extra net widens the scoped re-route it takes to judge one trial.
const max_cluster: usize = 6;
/// Cluster size at or below which every ordering is tried (`k!` ≤ 24).
const exhaustive_cluster: usize = 4;
/// Default ceiling on trials per call (the baseline is not counted).
const default_max_trials: usize = 12;
/// Hard ceiling, so a caller's `max_trials` cannot turn one call into an
/// unbounded run of whole-board routes.
const max_max_trials: usize = 48;
/// Blockers per stuck net that feed cluster derivation. The list is
/// share-ranked, so the tail is copper that barely touched the frontier.
const blockers_per_stuck: usize = 3;

fn progress(comptime fmt: []const u8, args: anytype) void {
    log.progress("route_order_search: " ++ fmt, args);
}

// ── Orderings ────────────────────────────────────────────────────────────────

/// One candidate ordering of the cluster: `order[i]` is the BASELINE POSITION
/// of the net that takes the i-th priority slot. `order` is always a
/// permutation of `0..k-1`; the identity is the baseline itself.
const Candidate = struct {
    label: []const u8,
    order: []const usize,
};

/// What the baseline route learned about the cluster, in cluster-position terms
/// — the seed for the heuristic candidates when the cluster is too big to
/// enumerate. Positions index the baseline ordering (slot 0 routes first).
const Evidence = struct {
    /// `.blocked` was walled in by `.blocker`, per the stuck diagnoses. Both
    /// are cluster positions; a diagnosis naming a non-cluster net is dropped.
    pairs: []const Pair = &.{},
    /// Position-aligned flag: is this cluster member a power rail / poured net?
    /// Drives the pours-before-signals and signals-before-pours candidates.
    power: []const bool = &.{},
};

/// One "this net was walled in by that one" edge from the diagnoses.
const Pair = struct { blocked: usize, blocker: usize };

/// Build the candidate orderings for a `k`-net cluster, baseline (identity)
/// first, deduplicated, capped at `max` (the baseline included in the count).
///
/// At `k ≤ exhaustive_cluster` the space is small enough to enumerate outright
/// — every ordering, in lexicographic order — so the search is a proof rather
/// than a sample. Above that it is seeded: the diagnoses' blocker/blocked
/// direction (both ways, because "route the blocker first so it stops being in
/// the way" and "route the victim first so it never has to fight" are both real
/// fixes and the board decides which), pours vs. signals, whole-cluster
/// reversal, single-net promotion/demotion (the shape of the board-a fix: one
/// wave lifted over its neighbours), then adjacent transpositions.
fn candidateOrderings(
    arena: std.mem.Allocator,
    k: usize,
    ev: Evidence,
    max: usize,
) std.mem.Allocator.Error![]const Candidate {
    var list: std.ArrayList(Candidate) = .empty;
    if (k == 0 or max == 0) return list.items;
    const base = try identity(arena, k);
    try push(arena, &list, max, "baseline", base);
    if (k <= exhaustive_cluster) {
        for (1..factorial(k)) |n| try push(arena, &list, max, "permutation", try nthPermutation(arena, k, n));
        return list.items;
    }
    try pushHeuristics(arena, &list, max, base, ev);
    return list.items;
}

/// The seeded candidates for a cluster too big to enumerate, pushed in the
/// order they deserve the trial budget.
fn pushHeuristics(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Candidate),
    max: usize,
    base: []const usize,
    ev: Evidence,
) std.mem.Allocator.Error!void {
    const k = base.len;
    try push(arena, list, max, "blocker-first", try byKey(arena, base, try blockerCounts(arena, k, ev.pairs), true));
    try push(arena, list, max, "blocked-first", try byKey(arena, base, try blockedCounts(arena, k, ev.pairs), true));
    try push(arena, list, max, "pours-first", try byFlag(arena, base, ev.power, true));
    try push(arena, list, max, "signals-first", try byFlag(arena, base, ev.power, false));
    try push(arena, list, max, "reverse", try reversed(arena, base));
    for (1..k) |i| try push(arena, list, max, "promote", try moved(arena, base, i, 0));
    for (0..k - 1) |i| try push(arena, list, max, "demote", try moved(arena, base, i, k - 1));
    for (0..k - 1) |i| try push(arena, list, max, "transpose", try swapped(arena, base, i, i + 1));
}

/// Append `order` under `label` unless the list is full or already holds an
/// identical ordering.
fn push(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Candidate),
    max: usize,
    label: []const u8,
    order: []const usize,
) std.mem.Allocator.Error!void {
    if (list.items.len >= max) return;
    for (list.items) |c| {
        if (std.mem.eql(usize, c.order, order)) return;
    }
    try list.append(arena, .{ .label = label, .order = order });
}

fn identity(arena: std.mem.Allocator, k: usize) std.mem.Allocator.Error![]usize {
    const out = try arena.alloc(usize, k);
    for (out, 0..) |*v, i| v.* = i;
    return out;
}

fn reversed(arena: std.mem.Allocator, base: []const usize) std.mem.Allocator.Error![]usize {
    const out = try arena.alloc(usize, base.len);
    for (base, 0..) |v, i| out[base.len - 1 - i] = v;
    return out;
}

fn swapped(arena: std.mem.Allocator, base: []const usize, a: usize, b: usize) std.mem.Allocator.Error![]usize {
    const out = try arena.dupe(usize, base);
    std.mem.swap(usize, &out[a], &out[b]);
    return out;
}

/// `base` with the element at `from` lifted out and re-inserted at `to`, every
/// other element keeping its relative order — the "move this wave above that
/// one" edit shape, as opposed to a swap (which also drags the target back).
fn moved(arena: std.mem.Allocator, base: []const usize, from: usize, to: usize) std.mem.Allocator.Error![]usize {
    const out = try arena.alloc(usize, base.len);
    const picked = base[from];
    var w: usize = 0;
    for (base, 0..) |v, i| {
        if (i == from) continue;
        if (w == to) w += 1;
        out[w] = v;
        w += 1;
    }
    out[to] = picked;
    return out;
}

/// `base` stably reordered so members whose `flag` equals `want` come first.
fn byFlag(
    arena: std.mem.Allocator,
    base: []const usize,
    flag: []const bool,
    want: bool,
) std.mem.Allocator.Error![]usize {
    const out = try arena.alloc(usize, base.len);
    var w: usize = 0;
    for (0..2) |pass| {
        const take = if (pass == 0) want else !want;
        for (base) |v| {
            if ((v < flag.len and flag[v]) == take) {
                out[w] = v;
                w += 1;
            }
        }
    }
    return out;
}

/// `base` stably reordered by descending (or ascending) `key`.
fn byKey(
    arena: std.mem.Allocator,
    base: []const usize,
    key: []const usize,
    descending: bool,
) std.mem.Allocator.Error![]usize {
    const out = try arena.dupe(usize, base);
    const Sorter = struct {
        key: []const usize,
        desc: bool,
        fn less(self: @This(), a: usize, b: usize) bool {
            const ka = if (a < self.key.len) self.key[a] else 0;
            const kb = if (b < self.key.len) self.key[b] else 0;
            return if (self.desc) ka > kb else ka < kb;
        }
    };
    std.sort.insertion(usize, out, Sorter{ .key = key, .desc = descending }, Sorter.less);
    return out;
}

/// How often each cluster position was named as somebody's blocker.
fn blockerCounts(arena: std.mem.Allocator, k: usize, pairs: []const Pair) std.mem.Allocator.Error![]usize {
    const out = try arena.alloc(usize, k);
    @memset(out, 0);
    for (pairs) |p| {
        if (p.blocker < k) out[p.blocker] += 1;
    }
    return out;
}

/// How often each cluster position was reported blocked by somebody.
fn blockedCounts(arena: std.mem.Allocator, k: usize, pairs: []const Pair) std.mem.Allocator.Error![]usize {
    const out = try arena.alloc(usize, k);
    @memset(out, 0);
    for (pairs) |p| {
        if (p.blocked < k) out[p.blocked] += 1;
    }
    return out;
}

/// `n!`, for the exhaustive-enumeration path only (`n ≤ exhaustive_cluster`).
/// The `n < 2` guard is load-bearing: `for (2..n + 1)` underflows its own length
/// computation at `n = 0`, and the last step of `nthPermutation` always asks for
/// `factorial(0)`.
fn factorial(n: usize) usize {
    if (n < 2) return 1;
    var f: usize = 1;
    for (2..n + 1) |i| f *= i;
    return f;
}

/// The `n`-th ordering of `0..k-1` in lexicographic order (factorial-number
/// decoding). `n = 0` is the identity, so candidate 0 is always the baseline.
fn nthPermutation(arena: std.mem.Allocator, k: usize, n: usize) std.mem.Allocator.Error![]usize {
    const pool = try identity(arena, k);
    const out = try arena.alloc(usize, k);
    var rem = n;
    var len = k;
    for (0..k) |i| {
        const f = factorial(len - 1);
        const pick = rem / f;
        rem %= f;
        out[i] = pool[pick];
        std.mem.copyForwards(usize, pool[pick .. len - 1], pool[pick + 1 .. len]);
        len -= 1;
    }
    return out;
}

// ── Judging ──────────────────────────────────────────────────────────────────

/// One trial's measured result. `routed`/`total` are the connectivity oracle's
/// (never the router's own claim); `drc_errors` counts ERROR-severity
/// violations only, so a sharp-bend or diff-skew warning never decides a race.
const Outcome = struct {
    routed: usize = 0,
    total: usize = 0,
    drc_errors: usize = 0,
    trace_mm: f64 = 0,
    vias: usize = 0,
    /// The score's two v2 geometry terms (route_score.Inputs), measured by the
    /// score module's shared helpers so a trial row's score matches what
    /// `route_experiment` reports for the same board.
    bends: usize = 0,
    quality_warns: usize = 0,
};

/// Is `a` a strictly better board than `b`? Fewer geometry errors first,
/// then greater connectivity, then total trace as a deterministic tiebreak (shorter copper
/// on an otherwise identical board is the better one, and it makes the ranking
/// total so two runs can never disagree).
fn betterOutcome(a: Outcome, b: Outcome) bool {
    if (a.drc_errors != b.drc_errors) return a.drc_errors < b.drc_errors;
    if (a.routed != b.routed) return a.routed > b.routed;
    return a.trace_mm < b.trace_mm;
}

/// One completed trial: the candidate that produced it and what it measured.
const Trial = struct {
    label: []const u8,
    /// Cluster positions in routing order (see `Candidate.order`).
    order: []const usize,
    out: Outcome,
    ms: i64,
    baseline: bool,
};

/// How many cluster members a candidate moves off their authored slot — the
/// SIZE OF THE EDIT the caller would have to make to the `(pcb-plan …)`.
fn editDistance(order: []const usize) usize {
    var n: usize = 0;
    for (order, 0..) |from, slot| {
        if (from != slot) n += 1;
    }
    return n;
}
/// Rank `trials` best-first. Ties on the measured board are broken by the SIZE
/// of the edit, then by trial index.
///
/// Both tiebreaks are about what gets recommended, not about the copper. The
/// edit-size one matters because different orderings routinely land the
/// identical board — on board-a's six-net cluster two candidates both hit
/// 81/90 at 20 DRC errors, one by moving five waves and one by lifting a single
/// pour above two signals — and the one-wave edit is the one a human should be
/// handed. The index one keeps the baseline (trial 0, edit distance 0) ahead of
/// anything that merely equals it, so the search recommends a CHANGE only when
/// the change earned something.
fn rankTrials(arena: std.mem.Allocator, trials: []const Trial) std.mem.Allocator.Error![]const usize {
    const idx = try identity(arena, trials.len);
    const Sorter = struct {
        trials: []const Trial,
        fn less(self: @This(), a: usize, b: usize) bool {
            if (betterOutcome(self.trials[a].out, self.trials[b].out)) return true;
            if (betterOutcome(self.trials[b].out, self.trials[a].out)) return false;
            const ea = editDistance(self.trials[a].order);
            const eb = editDistance(self.trials[b].order);
            if (ea != eb) return ea < eb;
            return a < b;
        }
    };
    std.sort.insertion(usize, idx, Sorter{ .trials = trials }, Sorter.less);
    return idx;
}

// ── Cluster derivation ───────────────────────────────────────────────────────

/// One net's claim on a place in the contended cluster.
const Claim = struct { net_i: usize, score: f64 };

/// Derive the contended cluster from a baseline route's stuck diagnoses: every
/// net that failed, plus the copper each one names as having walled it in.
///
/// The weights encode what the diagnoses mean. A failed net scores 1 — it is
/// the symptom. A named blocker scores its frontier `share` — how much of the
/// victim's ringed frontier that copper actually owned. A net that is BOTH
/// stuck and named as somebody's blocker scores an extra 1: those are the nets
/// standing in each other's way, which is precisely the set an order change can
/// resolve, and the reason `SPI_SCK` (blocker of six nets) and `V_3V3A` (stuck,
/// and blocked by copper that `SPI_SCK` also blocks) surface together on
/// board-a.
fn deriveCluster(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    stuck: []const route_diagnose.Diagnosis,
    limit: usize,
) std.mem.Allocator.Error![]const usize {
    const score = try arena.alloc(f64, placement.nets.len);
    @memset(score, 0);
    const is_stuck = try arena.alloc(bool, placement.nets.len);
    @memset(is_stuck, false);
    for (stuck) |d| {
        if (netIndex(placement, d.net)) |i| {
            score[i] += 1;
            is_stuck[i] = true;
        }
    }
    for (stuck) |d| {
        const n = @min(d.blockers.len, blockers_per_stuck);
        for (d.blockers[0..n]) |b| {
            const i = netIndex(placement, b.net) orelse continue;
            score[i] += b.share;
            if (is_stuck[i]) score[i] += 1;
        }
    }
    return topClaims(arena, score, limit);
}

/// The `limit` highest-scoring nets with a non-zero score, as net indices.
fn topClaims(arena: std.mem.Allocator, score: []const f64, limit: usize) std.mem.Allocator.Error![]const usize {
    var claims: std.ArrayList(Claim) = .empty;
    for (score, 0..) |s, i| {
        if (s > 0) try claims.append(arena, .{ .net_i = i, .score = s });
    }
    std.sort.insertion(Claim, claims.items, {}, claimBetter);
    var out: std.ArrayList(usize) = .empty;
    for (claims.items) |c| {
        if (out.items.len >= limit) break;
        try out.append(arena, c.net_i);
    }
    return out.items;
}

fn claimBetter(_: void, a: Claim, b: Claim) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.net_i < b.net_i;
}

fn netIndex(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, i| {
        if (std.mem.eql(u8, net.name, name)) return i;
    }
    return null;
}

// ── The search ───────────────────────────────────────────────────────────────

/// How a trial is routed: `cluster` re-routes only the cluster's nets on top of
/// the saved layout's copper for everything else (tens of seconds a trial);
/// `full` routes the whole board fresh (the mode the wave order was authored
/// for, and the only one whose numbers a `?route=1` describe reproduces).
const Scope = enum { cluster, full };

/// Everything a trial route needs that does not change between trials.
const Board = struct {
    placement: optimizer.Placement,
    params: router.RouteParams,
    /// Retained pour copper (the layout's hand-drawn zones), as router sources.
    zones: []const route_policy.ExistingZone = &.{},
    /// The same pours as connectivity/DRC input.
    user_zones: []const pour.UserZone = &.{},
};

/// The cluster-scope seed: which nets re-route and the copper kept for the rest.
const Seed = struct {
    selected: []const bool = &.{},
    tracks: []const route_policy.ExistingTrack = &.{},
    vias: []const route_policy.ExistingVia = &.{},
};

/// The whole search's shared state.
const Search = struct {
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    design: []const u8,
    block: ?*const env_mod.DesignBlock = null,
    board: Board,
    /// The authored plan's per-net policies — copied and re-slotted per trial.
    base_net: []const route_policy.NetPolicy,
    effort: route_policy.Effort,
    /// Net indices of the cluster, in baseline routing order (slot 0 first).
    cluster: []const usize,
    /// The priority slots the cluster holds, descending — index i is slot i.
    slots: []const u32,
    seed: Seed = .{},
    scope: Scope = .cluster,

    /// Router options for one candidate ordering: the authored policies with the
    /// cluster's own priority slots re-dealt, plus this scope's copper.
    fn optionsFor(self: Search, order: []const usize) std.mem.Allocator.Error!route_policy.Options {
        const nets = try self.alloc.dupe(route_policy.NetPolicy, self.base_net);
        for (order, 0..) |from, slot| {
            const net_i = self.cluster[from];
            if (net_i < nets.len) nets[net_i].wave.priority = self.slots[slot];
        }
        var options = route_policy.Options{
            .net = nets,
            .effort = self.effort,
            .selected_nets = self.seed.selected,
            .existing_tracks = self.seed.tracks,
            .existing_vias = self.seed.vias,
            .existing_zones = self.board.zones,
        };
        if (self.block) |block| _ = try pcb_layout_page.addSubcircuitRouteSeeds(
            self.alloc,
            self.project_dir,
            block,
            self.board.placement,
            self.board.params,
            &options,
        );
        return options;
    }

    /// Route one candidate and measure it. `diagnose` keeps the live router
    /// state so the baseline can hand its stuck list to cluster derivation;
    /// trials skip it, because a remedy search per trial is minutes of work the
    /// ranking never reads.
    fn run(self: Search, options: route_policy.Options, diagnose: bool) HandlerError!route_plan.PlannedDiagnostic {
        if (diagnose) return route_plan.routeLoweredDiagnostic(self.alloc, self.board.placement, self.board.params, options);
        const r = try route_plan.routeLowered(self.alloc, self.board.placement, self.board.params, options);
        return .{ .result = r };
    }

    /// The measured outcome of routed copper: the oracle's connectivity (already
    /// folded into `result` by the shared gate) plus fab-blocking DRC.
    ///
    /// `drc.errorCount` drops `net_open` as well as warnings, which matters here
    /// more than anywhere: this ranking already sorts on `routed`/`total` FIRST,
    /// so counting each open net's islands as DRC errors too let the tiebreak
    /// re-litigate — and outvote — the primary key it is supposed to break ties
    /// under.
    fn measure(self: Search, r: router.RouteResult) Outcome {
        const v = drc_rules.checkFilteredZones(self.alloc, self.project_dir, self.design, .{
            .placement = self.board.placement,
            .routed = r,
            .clearance = self.board.params.clearance,
            .zones = self.board.user_zones,
        });
        const errors = drc.errorCount(v);
        var trace: f64 = 0;
        for (r.tracks) |t| trace += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        return .{
            .routed = r.routed,
            .total = r.total,
            .drc_errors = errors,
            .trace_mm = trace,
            .vias = r.vias.len,
            .bends = route_score.bendCount(self.alloc, r.tracks) catch 0,
            .quality_warns = route_score.qualityWarnCount(v),
        };
    }
};

/// Build the cluster-scope seed: an enable mask holding only the cluster's nets,
/// and the saved layout's copper for every OTHER net kept as a hard obstacle.
/// The cluster's own saved copper is dropped — that is the copper being re-laid.
fn buildSeed(alloc: std.mem.Allocator, cluster: []const usize, nets: usize, saved: router.RouteResult) std.mem.Allocator.Error!Seed {
    const mask = try alloc.alloc(bool, nets);
    @memset(mask, false);
    for (cluster) |i| {
        if (i < mask.len) mask[i] = true;
    }
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    for (saved.tracks) |t| {
        if (t.net >= 0 and t.net < mask.len and mask[@intCast(t.net)]) continue;
        try tracks.append(alloc, .{ .x1 = t.x1, .y1 = t.y1, .x2 = t.x2, .y2 = t.y2, .layer = t.layer, .width = t.width, .net = t.net });
    }
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (saved.vias) |v| {
        if (v.net >= 0 and v.net < mask.len and mask[@intCast(v.net)]) continue;
        try vias.append(alloc, .{ .x = v.x, .y = v.y, .dia = v.dia, .drill = v.drill, .net = v.net });
    }
    return .{ .selected = mask, .tracks = tracks.items, .vias = vias.items };
}

/// The cluster's authored priorities, sorted descending — the slots a candidate
/// ordering re-deals. Sorting is what makes slot `i` mean "routes i-th among the
/// cluster" regardless of the order the cluster was derived in.
fn slotsOf(alloc: std.mem.Allocator, cluster: []const usize, policies: []const route_policy.NetPolicy) std.mem.Allocator.Error![]u32 {
    const out = try alloc.alloc(u32, cluster.len);
    for (cluster, 0..) |net_i, i| out[i] = if (net_i < policies.len) policies[net_i].wave.priority else 0;
    std.sort.insertion(u32, out, {}, descU32);
    return out;
}

fn descU32(_: void, a: u32, b: u32) bool {
    return a > b;
}

/// Order the derived cluster the way the baseline routes it: highest authored
/// priority first, ties by net index (the router's own deterministic fallback).
fn inRouteOrder(alloc: std.mem.Allocator, cluster: []const usize, policies: []const route_policy.NetPolicy) std.mem.Allocator.Error![]usize {
    const out = try alloc.dupe(usize, cluster);
    const Sorter = struct {
        policies: []const route_policy.NetPolicy,
        fn less(self: @This(), a: usize, b: usize) bool {
            const pa = if (a < self.policies.len) self.policies[a].wave.priority else 0;
            const pb = if (b < self.policies.len) self.policies[b].wave.priority else 0;
            if (pa != pb) return pa > pb;
            return a < b;
        }
    };
    std.sort.insertion(usize, out, Sorter{ .policies = policies }, Sorter.less);
    return out;
}

/// Cluster-position evidence for the heuristic candidates, projected from the
/// baseline's stuck diagnoses and the layout's pours.
fn evidenceFor(
    alloc: std.mem.Allocator,
    board: Board,
    cluster: []const usize,
    stuck: []const route_diagnose.Diagnosis,
) std.mem.Allocator.Error!Evidence {
    const power = try alloc.alloc(bool, cluster.len);
    for (cluster, 0..) |net_i, pos| power[pos] = isPoured(board, net_i);
    var pairs: std.ArrayList(Pair) = .empty;
    for (stuck) |d| {
        const blocked = clusterPos(board.placement, cluster, d.net) orelse continue;
        const n = @min(d.blockers.len, blockers_per_stuck);
        for (d.blockers[0..n]) |b| {
            const blocker = clusterPos(board.placement, cluster, b.net) orelse continue;
            if (blocker != blocked) try pairs.append(alloc, .{ .blocked = blocked, .blocker = blocker });
        }
    }
    return .{ .pairs = pairs.items, .power = power };
}

/// Does a hand-drawn pour carry this net? A poured rail is joined by its zone
/// rather than by traces, which is exactly why it can afford to route late —
/// and why "pours first" and "signals first" are both worth a trial.
fn isPoured(board: Board, net_i: usize) bool {
    if (net_i >= board.placement.nets.len) return false;
    const name = board.placement.nets[net_i].name;
    for (board.user_zones) |z| {
        if (std.mem.eql(u8, z.net, name)) return true;
    }
    return false;
}

/// The cluster position of a net named by a diagnosis, or null when that net is
/// not in the cluster.
fn clusterPos(placement: optimizer.Placement, cluster: []const usize, name: []const u8) ?usize {
    const net_i = netIndex(placement, name) orelse return null;
    for (cluster, 0..) |c, pos| {
        if (c == net_i) return pos;
    }
    return null;
}

// ── Handler ──────────────────────────────────────────────────────────────────

/// `route_order_search` — try orderings of a contended net cluster and report
/// the best one plus the DSL edit that expresses it. Persists nothing.
pub fn mcpRouteOrderSearch(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = argStr(args_val, "name") orelse return fail(out, alloc, "missing required arg: name");
    const layout_arg = argStr(args_val, "layout");
    const want_scope: Scope = if (argStr(args_val, "scope")) |s|
        (if (std.mem.eql(u8, s, "full")) .full else if (std.mem.eql(u8, s, "cluster")) .cluster else return fail(out, alloc, "scope must be \"cluster\" or \"full\""))
    else
        .cluster;
    const max_trials = @min(argUsize(args_val, "max_trials") orelse default_max_trials, max_max_trials);

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return failFmt(out, alloc, "could not resolve layout: {s}", .{@errorName(e)});

    const lowered = route_plan.lowerWithWaves(alloc, solved.block, solved.placement) catch |e|
        return failFmt(out, alloc, "could not lower the routing plan: {s}", .{@errorName(e)});
    var search = Search{
        .alloc = alloc,
        .project_dir = project_dir,
        .design = name,
        .block = solved.block,
        .board = .{
            .placement = solved.placement,
            .params = solved.placement.rules.design.routeParams(),
            .zones = solved.shown_zones.sources,
            .user_zones = solved.shown_zones.user,
        },
        .base_net = lowered.options.net,
        .effort = lowered.options.effort,
        .cluster = &.{},
        .slots = &.{},
    };
    // Cluster scope needs the saved board to stand on. Without persisted copper
    // there is nothing to hold the out-of-cluster nets still, so the run falls
    // back to whole-board routing and SAYS SO rather than silently measuring a
    // different question than the caller asked.
    var scope = want_scope;
    var scope_note: []const u8 = "";
    if (scope == .cluster and solved.restored.routes == null) {
        scope = .full;
        scope_note = "the layout carries no saved copper, so cluster scope had nothing to hold the other nets still — routed whole-board instead";
    }
    search.scope = scope;

    return runSearch(out, &search, .{
        .args = args_val,
        .saved = solved.restored.routes,
        .waves = lowered.waves,
        .max_trials = max_trials,
        .scope_note = scope_note,
        .requested_scope = want_scope,
        .record = argBool(args_val, "record") orelse true,
        .layout = layout_arg,
    });
}

/// The request context `runSearch` needs beyond the `Search` itself.
const Request = struct {
    args: ?std.json.Value,
    saved: ?router.RouteResult,
    waves: []const plan_resolve.ResolvedWave,
    max_trials: usize,
    scope_note: []const u8,
    requested_scope: Scope,
    /// Append every trial to the design's trial-memory sidecar (default on).
    record: bool = true,
    /// The `layout` the caller named, echoed into each recorded row so a reader
    /// knows which board a row measured. Null = the starred (★) snapshot.
    layout: ?[]const u8 = null,
};

/// Baseline → cluster → candidates → trials → ranked answer.
fn runSearch(out: *std.ArrayList(u8), search: *Search, req: Request) HandlerError!bool {
    const alloc = search.alloc;
    const started = clock.milliTimestamp();

    // Deriving the cluster costs one WHOLE-BOARD diagnostic route, because the
    // stuck diagnoses are what name the nets standing in each other's way. A
    // caller who already knows the cluster (`nets=[…]`) is spared it entirely —
    // on board-a that is 156 s of the call's wall clock not spent.
    const explicit = try argNames(alloc, req.args, "nets");
    var probe: ?route_plan.PlannedDiagnostic = null;
    var probe_ms: i64 = 0;
    if (explicit.len == 0) {
        progress("{s}: whole-board probe route for the cluster diagnoses", .{search.design});
        const t0 = clock.milliTimestamp();
        probe = search.run(.{
            .net = search.base_net,
            .effort = search.effort,
            .existing_zones = search.board.zones,
        }, true) catch |e| return failFmt(out, alloc, "baseline route failed: {s}", .{@errorName(e)});
        probe_ms = clock.milliTimestamp() - t0;
    }
    const stuck = if (probe) |p| p.stuck else &.{};

    const cluster = if (explicit.len > 0)
        (resolveNames(alloc, search.board.placement, explicit) catch |e| return failFmt(out, alloc, "cluster resolution failed: {s}", .{@errorName(e)})) orelse
            return failFmt(out, alloc, "unknown net in nets: none of {d} names matched a net on this board", .{explicit.len})
    else
        try deriveCluster(alloc, search.board.placement, stuck, max_cluster);
    if (cluster.len < 2) return fail(out, alloc, "no contended cluster to search — the baseline route named fewer than two nets standing in each other's way; pass nets=[…] to search an explicit cluster");

    search.cluster = try inRouteOrder(alloc, cluster, search.base_net);
    search.slots = try slotsOf(alloc, search.cluster, search.base_net);
    if (search.scope == .cluster) {
        search.seed = try buildSeed(alloc, search.cluster, search.board.placement.nets.len, req.saved.?);
    }

    // Trial 0 is the AUTHORED order routed the SAME WAY every other trial is, so
    // a delta measures the reorder and nothing else.
    //
    // The probe's result is deliberately NOT reused as that baseline, even under
    // full scope where it deals the identical priorities: the diagnostic path
    // routes ONE live core (it has to, to flood the grid the copper landed on)
    // while a trial routes through `routeLowered`, which layers the finer-grid
    // retry on top. Measured on board-a that retry is worth a net — the probe
    // reads 76/90 where a trial of the same ordering reads 77/90 — so reusing it
    // would have credited every candidate a phantom +1 over the authored plan.
    progress("{s}: baseline route ({s} scope)", .{ search.design, @tagName(search.scope) });
    const base_started = clock.milliTimestamp();
    const rerun = search.run(try search.optionsFor(try identity(alloc, search.cluster.len)), false) catch |e|
        return failFmt(out, alloc, "baseline route failed: {s}", .{@errorName(e)});
    const base_wall = clock.milliTimestamp() - base_started;
    const base_out = search.measure(rerun.result);

    const ev = try evidenceFor(alloc, search.board, search.cluster, stuck);
    const cands = try candidateOrderings(alloc, search.cluster.len, ev, req.max_trials);

    var trials: std.ArrayList(Trial) = .empty;
    try trials.append(alloc, .{ .label = "baseline", .order = cands[0].order, .out = base_out, .ms = base_wall, .baseline = true });
    for (cands[1..], 1..) |c, n| {
        if (try duplicateAssignment(alloc, search.*, trials.items, c.order)) continue;
        progress("{s}: trial {d}/{d} ({s})", .{ search.design, n, cands.len - 1, c.label });
        const options = try search.optionsFor(c.order);
        const t0 = clock.milliTimestamp();
        const r = search.run(options, false) catch |e|
            return failFmt(out, alloc, "trial route failed: {s}", .{@errorName(e)});
        try trials.append(alloc, .{ .label = c.label, .order = c.order, .out = search.measure(r.result), .ms = clock.milliTimestamp() - t0, .baseline = false });
    }

    const ranked = try rankTrials(alloc, trials.items);
    const answer = Answer{
        .search = search.*,
        .req = req,
        .trials = trials.items,
        .ranked = ranked,
        .baseline = base_out,
        .wall_ms = clock.milliTimestamp() - started,
        .probe_ms = probe_ms,
    };
    if (req.record) recordTrials(answer);
    return writeResult(out, answer);
}

/// Append every trial this run measured to the design's trial-memory sidecar, in
/// the order they ran, tagged `source:"order_search"`.
///
/// BEST-EFFORT by construction: a search that measured 48 boards must not lose
/// its answer because a sidecar write failed, so any error is logged and
/// swallowed and the result still goes back to the caller. Recorded through the
/// same `route_score` the `route_experiment` tool reports, so a row from either
/// tool is comparable in `list_route_trials` without re-deriving anything.
fn recordTrials(a: Answer) void {
    const alloc = a.search.alloc;
    var rows: std.ArrayList(mcp_route_trials.SearchTrial) = .empty;
    for (a.trials, 0..) |t, ti| {
        const row = trialRow(alloc, a, t, ti) catch |e| {
            log.warn("route_order_search: could not build trial row: {s}", .{@errorName(e)});
            return;
        };
        rows.append(alloc, row) catch |e| {
            log.warn("route_order_search: could not build trial row: {s}", .{@errorName(e)});
            return;
        };
    }
    _ = mcp_route_trials.recordSearchTrials(alloc, a.search.project_dir, a.search.design, rows.items) catch |e|
        log.warn("route_order_search: could not record {d} trial(s) for {s}: {s}", .{
            rows.items.len,
            a.search.design,
            @errorName(e),
        });
}

/// One trial as a sidecar row. `plan` is the ORDERING it tried, written in the
/// routing order the caller would have to author, because for this search the
/// ordering IS the plan edit under test; `note` carries the label, the scope it
/// was measured under, and the layout, so a later reader knows whether the row
/// is comparable to the board in front of them.
fn trialRow(
    alloc: std.mem.Allocator,
    a: Answer,
    t: Trial,
    index: usize,
) HandlerError!mcp_route_trials.SearchTrial {
    var pw: std.Io.Writer.Allocating = .init(alloc);
    try pw.writer.writeAll("route order: ");
    for (t.order, 0..) |from, i| {
        if (i > 0) try pw.writer.writeAll(" > ");
        try pw.writer.writeAll(a.search.board.placement.nets[a.search.cluster[from]].name);
    }
    const note = try std.fmt.allocPrint(alloc, "route_order_search trial {d} ({s}), scope={s}, layout={s}", .{
        index,
        t.label,
        @tagName(a.search.scope),
        if (a.req.layout) |ln| ln else "starred",
    });
    return .{
        .plan = pw.written(),
        .note = note,
        .outcome = .{
            .score = route_score.score(.{
                .routed = t.out.routed,
                .total = t.out.total,
                .vias = t.out.vias,
                .trace_mm = t.out.trace_mm,
                .drc_errors = t.out.drc_errors,
                .bends = t.out.bends,
                .quality_warns = t.out.quality_warns,
            }),
            .routed = t.out.routed,
            .total = t.out.total,
            .vias = t.out.vias,
            .trace_mm = t.out.trace_mm,
            .drc_errors = t.out.drc_errors,
        },
    };
}

/// Would this ordering deal the cluster exactly the priorities some earlier
/// trial already measured? Two orderings that differ only where the cluster's
/// authored priorities tie produce the identical router input, so routing the
/// second is a minute spent re-measuring the first.
fn duplicateAssignment(alloc: std.mem.Allocator, search: Search, done: []const Trial, order: []const usize) std.mem.Allocator.Error!bool {
    const key = try assignmentKey(alloc, search, order);
    for (done) |t| {
        if (std.mem.eql(u32, key, try assignmentKey(alloc, search, t.order))) return true;
    }
    return false;
}

/// The priority each cluster member ends up with under `order`, indexed by
/// cluster position — the ordering's identity as the ROUTER sees it.
fn assignmentKey(alloc: std.mem.Allocator, search: Search, order: []const usize) std.mem.Allocator.Error![]u32 {
    const key = try alloc.alloc(u32, search.cluster.len);
    for (order, 0..) |from, slot| key[from] = search.slots[slot];
    return key;
}

/// Resolve caller-named nets to indices, in the order given. Null when NOTHING
/// matched (a typo'd cluster is an error, not an empty search); names that miss
/// while others hit are dropped, so a stale name in a longer list still works.
fn resolveNames(alloc: std.mem.Allocator, placement: optimizer.Placement, names: []const []const u8) std.mem.Allocator.Error!?[]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (names) |n| {
        const i = plan_resolve.netIndexByName(placement, n) orelse continue;
        try out.append(alloc, i);
    }
    return if (out.items.len == 0) null else out.items;
}

// ── Reporting ────────────────────────────────────────────────────────────────

/// Everything the answer writer reports on.
const Answer = struct {
    search: Search,
    req: Request,
    trials: []const Trial,
    ranked: []const usize,
    baseline: Outcome,
    wall_ms: i64,
    /// Wall clock spent on the whole-board diagnostic probe that DERIVED the
    /// cluster (0 when the caller named the cluster and no probe was needed) —
    /// reported because it is pure overhead a second call with `nets=[…]` skips.
    probe_ms: i64 = 0,
};

fn writeResult(out: *std.ArrayList(u8), a: Answer) HandlerError!bool {
    const alloc = a.search.alloc;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, a.search.design);
    try w.writeAll(",\"scope\":");
    try pcb_layout_page.writeJsonStr(w, @tagName(a.search.scope));
    try w.writeAll(",\"scope_requested\":");
    try pcb_layout_page.writeJsonStr(w, @tagName(a.req.requested_scope));
    try w.writeAll(",\"scope_note\":");
    try pcb_layout_page.writeJsonStr(w, a.req.scope_note);
    try w.writeAll(",\"cluster\":");
    try writeNetNames(w, a.search, a.trials[0].order);
    try w.print(",\"trials_run\":{d},\"wall_ms\":{d},\"probe_ms\":{d},\"baseline\":", .{ a.trials.len, a.wall_ms, a.probe_ms });
    try writeOutcome(w, a.baseline);
    try w.writeAll(",\"trials\":[");
    for (a.ranked, 0..) |ti, rank| {
        if (rank > 0) try w.writeAll(",");
        try writeTrial(w, a, ti, rank + 1);
    }
    try w.writeAll("],\"suggestion\":");
    try pcb_layout_page.writeJsonStr(w, try suggestionText(alloc, a));
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

fn writeTrial(w: *std.Io.Writer, a: Answer, ti: usize, rank: usize) std.Io.Writer.Error!void {
    const t = a.trials[ti];
    try w.print("{{\"rank\":{d},\"trial\":{d},\"label\":", .{ rank, ti });
    try pcb_layout_page.writeJsonStr(w, t.label);
    try w.writeAll(",\"baseline\":");
    try w.writeAll(if (t.baseline) "true" else "false");
    try w.writeAll(",\"order\":");
    try writeNetNames(w, a.search, t.order);
    try w.writeAll(",");
    try writeOutcomeBody(w, t.out);
    try w.print(",\"delta_routed\":{d},\"delta_drc_errors\":{d},\"ms\":{d}}}", .{
        @as(i64, @intCast(t.out.routed)) - @as(i64, @intCast(a.baseline.routed)),
        @as(i64, @intCast(t.out.drc_errors)) - @as(i64, @intCast(a.baseline.drc_errors)),
        t.ms,
    });
}

fn writeOutcome(w: *std.Io.Writer, o: Outcome) std.Io.Writer.Error!void {
    try w.writeAll("{");
    try writeOutcomeBody(w, o);
    try w.writeAll("}");
}

fn writeOutcomeBody(w: *std.Io.Writer, o: Outcome) std.Io.Writer.Error!void {
    try w.print("\"routed\":{d},\"total\":{d},\"drc_errors\":{d},\"vias\":{d},\"trace_mm\":{d:.3}", .{
        o.routed,
        o.total,
        o.drc_errors,
        o.vias,
        o.trace_mm,
    });
}

/// The cluster's net names in the order `order` routes them.
fn writeNetNames(w: *std.Io.Writer, search: Search, order: []const usize) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (order, 0..) |from, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, search.board.placement.nets[search.cluster[from]].name);
    }
    try w.writeAll("]");
}

/// Did every trial land on exactly the same board? Under cluster scope that is
/// the signature of a question not asked rather than of an answer: with the rest
/// of the board frozen the cluster's nets can route past each other without
/// competing, so no permutation changes a single millimetre. Measured on
/// board-a's SPI_SCK / V_3V3_LMX / V_3V3A cluster, all six orderings came back
/// 72/90 with 87 DRC errors and the same copper to the micron — while the same
/// six under full scope spread from 77/90 (51 DRC errors) to 81/90 (20).
fn flatResult(trials: []const Trial) bool {
    if (trials.len < 2) return false;
    for (trials[1..]) |t| {
        if (t.out.routed != trials[0].out.routed) return false;
        if (t.out.drc_errors != trials[0].out.drc_errors) return false;
        if (t.out.trace_mm != trials[0].out.trace_mm) return false;
    }
    return true;
}

/// The paste-ready guidance: the winning order, the wave forms it corresponds
/// to, and — when a winning wave carries nets outside the cluster — the caveat
/// that moving the whole form moves them too (the trial moved only the cluster
/// net, so the two are not the same edit).
fn suggestionText(alloc: std.mem.Allocator, a: Answer) std.mem.Allocator.Error![]const u8 {
    const best = a.trials[a.ranked[0]];
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    if (best.baseline) {
        w.print("No ordering beat the authored plan ({d}/{d} routed, {d} DRC errors). Keep (pcb-plan (route …)) as it is.", .{
            a.baseline.routed,
            a.baseline.total,
            a.baseline.drc_errors,
        }) catch return aw.written();
        if (a.search.scope == .cluster and flatResult(a.trials))
            w.writeAll(
                "\nEvery ordering measured IDENTICALLY, which under cluster scope usually means the" ++
                    " question was not asked: with the rest of the board's copper held fixed these nets" ++
                    " never compete for the same space, and a reorder cannot cascade into the nets they" ++
                    " would have freed. Re-run with scope=\"full\" before concluding the order does not" ++
                    " matter.",
            ) catch return aw.written();
        return aw.written();
    }
    w.print("Best ordering: {d}/{d} routed (baseline {d}), {d} DRC errors (baseline {d}).\n", .{
        best.out.routed,
        best.out.total,
        a.baseline.routed,
        best.out.drc_errors,
        a.baseline.drc_errors,
    }) catch return aw.written();
    writeWaveEdit(w, a, best.order) catch return aw.written();
    return aw.written();
}

/// The "reorder these wave forms" instruction. The cluster's nets hold `k`
/// authored priority slots; the winning ordering re-deals exactly those slots,
/// so the edit is a permutation of the `k` wave forms that own them, with every
/// other wave left where it is.
fn writeWaveEdit(w: *std.Io.Writer, a: Answer, order: []const usize) std.Io.Writer.Error!void {
    const s = a.search;
    try w.writeAll("Edit (pcb-plan (route …)): reorder these wave forms and leave every other wave where it is.\n  before: ");
    for (0..order.len) |slot| {
        if (slot > 0) try w.writeAll(" -> ");
        try writeWaveRef(w, a, s.cluster[slot]);
    }
    try w.writeAll("\n  after:  ");
    for (order, 0..) |from, i| {
        if (i > 0) try w.writeAll(" -> ");
        try writeWaveRef(w, a, s.cluster[from]);
    }
    try w.writeAll("\nRouting order that produced this:");
    for (order, 0..) |from, slot| {
        try w.print("\n  {d}. {s}", .{ slot + 1, s.board.placement.nets[s.cluster[from]].name });
    }
    try writeShareCaveats(w, a, order);
}

/// `(wave "name")` for the wave whose slot this net holds, or a bare net name
/// when the design authored no wave covering it.
fn writeWaveRef(w: *std.Io.Writer, a: Answer, net_i: usize) std.Io.Writer.Error!void {
    if (waveOf(a, net_i)) |wi| {
        try w.print("(wave \"{s}\")", .{a.req.waves[wi].name});
    } else {
        try w.print("[{s}: no wave]", .{a.search.board.placement.nets[net_i].name});
    }
}

/// The resolved wave that gave `net_i` its priority. `routePolicies` deals
/// priority `waves.len - wi`, and a later wave overwrites an earlier one, so the
/// net's own priority names its wave exactly.
fn waveOf(a: Answer, net_i: usize) ?usize {
    if (net_i >= a.search.base_net.len) return null;
    const pri = a.search.base_net[net_i].wave.priority;
    if (pri == 0 or pri > a.req.waves.len) return null;
    return a.req.waves.len - pri;
}

/// Name the nets a winning wave carries besides the cluster member that earned
/// the move. Moving the form moves them too, which is NOT what the trial
/// measured — the caller has to decide whether to move the wave or split the
/// one net out of it.
fn writeShareCaveats(w: *std.Io.Writer, a: Answer, order: []const usize) std.Io.Writer.Error!void {
    var seen: [max_cluster]usize = undefined;
    var n_seen: usize = 0;
    for (order, 0..) |from, slot| {
        // Only a net that actually CHANGED slot implies an edit to its wave.
        if (from == slot) continue;
        const net_i = a.search.cluster[from];
        const wi = waveOf(a, net_i) orelse continue;
        // One caveat per wave: a control bus with three cluster members in it
        // would otherwise print the same warning three times.
        if (std.mem.indexOfScalar(usize, seen[0..n_seen], wi) != null) continue;
        if (n_seen < seen.len) {
            seen[n_seen] = wi;
            n_seen += 1;
        }
        const members = a.req.waves[wi].members;
        if (members.len <= 1) continue;
        try w.print("\n  caveat: (wave \"{s}\") also carries", .{a.req.waves[wi].name});
        var shown: usize = 0;
        for (members) |m| {
            if (m == net_i or m >= a.search.board.placement.nets.len) continue;
            if (shown > 0) try w.writeAll(",");
            try w.print(" {s}", .{a.search.board.placement.nets[m].name});
            shown += 1;
            if (shown >= 6) break;
        }
        try w.print(" — the trial moved only {s}, so split it into its own wave to reproduce this exactly.", .{a.search.board.placement.nets[net_i].name});
    }
}

// ── Argument + error helpers ─────────────────────────────────────────────────

fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn argBool(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn argUsize(args_val: ?std.json.Value, key: []const u8) ?usize {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    if (v != .integer or v.integer <= 0) return null;
    return @intCast(v.integer);
}

const argNames = mcp_arg_names.parse;

fn fail(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) HandlerError!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"error\":");
    try pcb_layout_page.writeJsonStr(w, msg);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

fn failFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) HandlerError!bool {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return fail(out, alloc, msg);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_tools = @import("mcp_tools.zig");
const export_kicad = @import("../export_kicad.zig");

// spec: Web Server - route_order_search is a registered mutation CLI tool because it records the trials it ran
test "route_order_search is registered as a mutation" {
    try testing.expect(mcp_tools.isKnownTool("route_order_search"));
    // It writes the trial-memory sidecar, so the write has to be role-gated and
    // git-autocommitted like every other CLI mutation — a read-only flag here
    // would let a reader-role client write a file and skip the commit seam.
    try testing.expect(mcp_tools.isMutationTool("route_order_search"));
}

// spec: Web Server - a recorded route_order_search trial names the ordering it tried, its score, and the scope it was measured under
test "a search trial records its ordering, score and scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SPI_SCK", .pins = &.{} },
        .{ .name = "V_3V3A", .pins = &.{} },
    };
    const search = Search{
        .alloc = arena,
        .project_dir = "",
        .design = "board-a",
        .board = .{ .placement = orderFixturePlacement(&nets), .params = .{} },
        .base_net = &.{},
        .effort = .standard,
        .cluster = &.{ 0, 1 },
        .slots = &.{},
        .scope = .full,
    };
    const order = [_]usize{ 1, 0 }; // the transposition
    const trial = Trial{
        .label = "transpose",
        .order = &order,
        .out = .{ .routed = 78, .total = 90, .drc_errors = 32, .trace_mm = 1234.5, .vias = 40 },
        .ms = 0,
        .baseline = false,
    };
    const answer = Answer{
        .search = search,
        .req = .{
            .args = null,
            .saved = null,
            .waves = &.{},
            .max_trials = 12,
            .scope_note = "",
            .requested_scope = .full,
        },
        .trials = &.{trial},
        .ranked = &.{0},
        .baseline = .{},
        .wall_ms = 0,
    };

    const row = try trialRow(arena, answer, trial, 3);
    // The ordering IS the plan edit under test, so it is what `plan` records.
    try testing.expectEqualStrings("route order: V_3V3A > SPI_SCK", row.plan);
    try testing.expectEqual(@as(u64, 78), row.outcome.routed);
    try testing.expectEqual(@as(u64, 90), row.outcome.total);
    try testing.expectEqual(@as(u64, 32), row.outcome.drc_errors);
    // The same deterministic score route_experiment reports, so rows from the
    // two tools are comparable in list_route_trials without re-deriving it.
    try testing.expectEqual(route_score.score(.{
        .routed = 78,
        .total = 90,
        .vias = 40,
        .trace_mm = 1234.5,
        .drc_errors = 32,
    }), row.outcome.score);
    try testing.expect(std.mem.indexOf(u8, row.note, "trial 3 (transpose)") != null);
    try testing.expect(std.mem.indexOf(u8, row.note, "scope=full") != null);
    // No `layout` was named, so the row says which board that means.
    try testing.expect(std.mem.indexOf(u8, row.note, "layout=starred") != null);
}

/// A placement carrying only the net names the trial-row writer reads.
fn orderFixturePlacement(nets: []const export_kicad.FlatNet) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
}

// spec: Web Server - a small route_order_search cluster is searched exhaustively, the authored order first
test "route_order_search enumerates every ordering of a small cluster" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cands = try candidateOrderings(arena, 3, .{}, 32);
    try testing.expectEqual(@as(usize, 6), cands.len);
    // Trial 0 is the authored order, so every delta is measured against it.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, cands[0].order);
    try testing.expectEqualStrings("baseline", cands[0].label);
    // Every ordering appears exactly once.
    for (cands, 0..) |a, i| {
        for (cands[i + 1 ..]) |b| try testing.expect(!std.mem.eql(usize, a.order, b.order));
    }
    // A four-net cluster is still exhaustive; a five-net one is not.
    try testing.expectEqual(@as(usize, 24), (try candidateOrderings(arena, 4, .{}, 64)).len);
    try testing.expect((try candidateOrderings(arena, 5, .{}, 200)).len < 120);
}

// spec: Web Server - a route_order_search cluster too big to enumerate is seeded from the blocker diagnoses and the pours
test "route_order_search seeds a big cluster from blockers and pours" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Position 4 walled in 0 and 1; positions 2 and 3 are poured rails.
    const pairs = [_]Pair{ .{ .blocked = 0, .blocker = 4 }, .{ .blocked = 1, .blocker = 4 } };
    const power = [_]bool{ false, false, true, true, false };
    const cands = try candidateOrderings(arena, 5, .{ .pairs = &pairs, .power = &power }, 32);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, cands[0].order);
    // The chief blocker is promoted to the front by the blocker-first seed…
    const blocker_first = findLabel(cands, "blocker-first").?;
    try testing.expectEqual(@as(usize, 4), blocker_first[0]);
    // …and the poured rails lead the pours-first seed, signals keeping their order.
    const pours_first = findLabel(cands, "pours-first").?;
    try testing.expectEqualSlices(usize, &.{ 2, 3, 0, 1, 4 }, pours_first);
    // Promotion is a MOVE, not a swap: everything else keeps its relative order.
    // This is the shape of the measured board-a fix (one wave lifted over two).
    try testing.expectEqualSlices(usize, &.{ 4, 0, 1, 2, 3 }, findOrderStartingWith(cands, &.{ 4, 0, 1 }).?);
}

fn findLabel(cands: []const Candidate, label: []const u8) ?[]const usize {
    for (cands) |c| {
        if (std.mem.eql(u8, c.label, label)) return c.order;
    }
    return null;
}

fn findOrderStartingWith(cands: []const Candidate, prefix: []const usize) ?[]const usize {
    for (cands) |c| {
        if (c.order.len >= prefix.len and std.mem.eql(usize, c.order[0..prefix.len], prefix)) return c.order;
    }
    return null;
}

// spec: Web Server - route_order_search ranks trials by geometry DRC errors first then oracle connectivity
test "route_order_search ranks by DRC errors then connectivity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const order = [_]usize{ 0, 1 };
    const trials = [_]Trial{
        // 0: the baseline.
        .{ .label = "baseline", .order = &order, .out = .{ .routed = 76, .total = 90, .drc_errors = 51, .trace_mm = 100 }, .ms = 0, .baseline = true },
        // 1: the winner has fewer geometry errors despite a net short.
        .{ .label = "a", .order = &order, .out = .{ .routed = 75, .total = 90, .drc_errors = 2, .trace_mm = 100 }, .ms = 0, .baseline = false },
        // 2: two more nets closed, but too many geometry errors.
        .{ .label = "b", .order = &order, .out = .{ .routed = 78, .total = 90, .drc_errors = 32, .trace_mm = 100 }, .ms = 0, .baseline = false },
        // 3: ties trial 2 on connectivity, loses on DRC.
        .{ .label = "c", .order = &order, .out = .{ .routed = 78, .total = 90, .drc_errors = 40, .trace_mm = 100 }, .ms = 0, .baseline = false },
        // 4: ties the baseline exactly — the baseline must keep its place, so a
        // search that found nothing recommends no edit.
        .{ .label = "d", .order = &order, .out = .{ .routed = 76, .total = 90, .drc_errors = 51, .trace_mm = 100 }, .ms = 0, .baseline = false },
    };
    const ranked = try rankTrials(arena, &trials);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 0, 4 }, ranked);
}

// spec: Web Server - route_order_search recommends the smallest plan edit among orderings that measured the same board
test "route_order_search prefers the smallest edit among tied orderings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const same = Outcome{ .routed = 81, .total = 90, .drc_errors = 20, .trace_mm = 923 };
    // Both land the identical board; the first shuffles five members, the second
    // lifts one net over two — the board-a case, where the second is the edit
    // a human should be handed.
    const big = [_]usize{ 0, 2, 3, 4, 5, 1 };
    const small = [_]usize{ 2, 0, 1, 3, 4, 5 };
    const base = [_]usize{ 0, 1, 2, 3, 4, 5 };
    try testing.expectEqual(@as(usize, 5), editDistance(&big));
    try testing.expectEqual(@as(usize, 3), editDistance(&small));
    try testing.expectEqual(@as(usize, 0), editDistance(&base));
    const trials = [_]Trial{
        .{ .label = "baseline", .order = &base, .out = .{ .routed = 77, .total = 90, .drc_errors = 51 }, .ms = 0, .baseline = true },
        .{ .label = "blocked-first", .order = &big, .out = same, .ms = 0, .baseline = false },
        .{ .label = "pours-first", .order = &small, .out = same, .ms = 0, .baseline = false },
    };
    const ranked = try rankTrials(arena, &trials);
    // The smaller edit is recommended even though the bigger one was tried first.
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, ranked);
}

// spec: Web Server - a route_order_search whose trials all measure identically under cluster scope says so rather than reporting no effect
test "route_order_search calls out a flat cluster-scope result" {
    const order = [_]usize{ 0, 1 };
    const same = Outcome{ .routed = 72, .total = 90, .drc_errors = 87, .trace_mm = 944.5 };
    const flat = [_]Trial{
        .{ .label = "baseline", .order = &order, .out = same, .ms = 0, .baseline = true },
        .{ .label = "permutation", .order = &order, .out = same, .ms = 0, .baseline = false },
    };
    try testing.expect(flatResult(&flat));
    // A single trial is not evidence of flatness — there is nothing to compare.
    try testing.expect(!flatResult(flat[0..1]));
    // Copper that merely ties on connectivity and DRC is NOT flat: a different
    // trace length means the orderings really did lay different boards.
    var moved_copper = flat;
    moved_copper[1].out.trace_mm = 944.6;
    try testing.expect(!flatResult(&moved_copper));
}

// spec: Web Server - a route_order_search ordering re-deals only the cluster's own authored priority slots
test "route_order_search re-deals only the cluster's own priority slots" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Five nets; the cluster is nets 0 and 3 (priorities 14 and 12). Net 2's
    // priority 13 sits between them and must not move.
    const policies = [_]route_policy.NetPolicy{
        .{ .wave = .{ .priority = 14 } },
        .{ .wave = .{ .priority = 20 } },
        .{ .wave = .{ .priority = 13 } },
        .{ .wave = .{ .priority = 12 } },
        .{ .wave = .{ .priority = 1 } },
    };
    const cluster = [_]usize{ 0, 3 };
    const slots = try slotsOf(arena, &cluster, &policies);
    try testing.expectEqualSlices(u32, &.{ 14, 12 }, slots);
    const search = Search{
        .alloc = arena,
        .project_dir = "",
        .design = "d",
        .board = .{ .placement = undefined, .params = .{} },
        .base_net = &policies,
        .effort = .standard,
        .cluster = &cluster,
        .slots = slots,
    };
    const swapped_opts = try search.optionsFor(&.{ 1, 0 });
    try testing.expectEqual(@as(u32, 12), swapped_opts.net[0].wave.priority);
    try testing.expectEqual(@as(u32, 14), swapped_opts.net[3].wave.priority);
    // Everything outside the cluster is untouched, including the priority the
    // swap stepped over.
    try testing.expectEqual(@as(u32, 20), swapped_opts.net[1].wave.priority);
    try testing.expectEqual(@as(u32, 13), swapped_opts.net[2].wave.priority);
    try testing.expectEqual(@as(u32, 1), swapped_opts.net[4].wave.priority);
    // The authored policies themselves are never mutated — every trial deals
    // from the same baseline.
    try testing.expectEqual(@as(u32, 14), policies[0].wave.priority);
}

// spec: Web Server - route_order_search derives its cluster from the nets the stuck diagnoses name as blocking each other
test "route_order_search derives a cluster from the stuck diagnoses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SPI_SCK", .pins = &.{} },
        .{ .name = "V_3V3A", .pins = &.{} },
        .{ .name = "SPI_LMX_CSN", .pins = &.{} },
        .{ .name = "UNRELATED", .pins = &.{} },
    };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const sck_block = [_]route_diagnose.Blocker{.{ .net = "SPI_SCK", .layer = "F.Cu", .x = 0, .y = 0, .share = 0.6, .rippable = true }};
    const stuck = [_]route_diagnose.Diagnosis{
        .{ .net = "V_3V3A", .failure_mode = "search_budget", .why = "", .blockers = &sck_block, .remedies = &.{}, .drc_related = &.{} },
        .{ .net = "SPI_LMX_CSN", .failure_mode = "order_congestion", .why = "", .blockers = &sck_block, .remedies = &.{}, .drc_related = &.{} },
    };
    const cluster = try deriveCluster(arena, placement, &stuck, max_cluster);
    // The blocker both victims name outranks either victim, and the net no
    // diagnosis mentioned is not in the cluster at all.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, cluster);
    try testing.expect(clusterPos(placement, cluster, "UNRELATED") == null);
    // A board whose baseline route stuck nothing has no cluster to search.
    try testing.expectEqual(@as(usize, 0), (try deriveCluster(arena, placement, &.{}, max_cluster)).len);
}

// spec: Web Server - route_order_search connectivity dominates any copper cost on equally legal boards
test "route_order_search connectivity dominates any copper cost on equally legal boards" {
    try testing.expect(betterOutcome(.{ .routed = 120, .total = 130, .vias = 10000, .trace_mm = 100000 }, .{ .routed = 119, .total = 130 }));
    try testing.expect(!betterOutcome(.{ .routed = 130, .total = 130, .drc_errors = 1 }, .{ .routed = 119, .total = 130 }));
}
