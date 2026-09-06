//! `close_open_nets` CLI tool — finish the nets the autorouter gave up on.
//!
//! `route_pcb` re-runs the whole-board autorouter, which answers "route this
//! board from scratch"; on a nearly-finished board that is both destructive and
//! beside the point, and its own tally is not connectivity (it reports a
//! plane-carried net as done while the oracle finds 17 islands). This tool asks
//! the other question: the connectivity oracle says these same-net pads sit in
//! different copper islands — put down the metal that joins them and disturb
//! nothing else.
//!
//! The loop is: `fab_readiness.openNets` names every remaining island and the
//! pads on it → `router.closeGaps` routes one hop per island (a plane/pour
//! STITCH via for a plane-carried net, a maze BRIDGE otherwise, with a
//! rip-up-and-retry behind a sealed pad) → each hop is kept ONLY if the oracle
//! then reports fewer islands on that net AND the geometric DRC error count did
//! not rise above the RATCHETED ceiling (see `Work.error_ceiling`: the count on
//! the board as it stands, not the one it started with) — or, when the caller
//! has declared one, above an absolute BUDGET (see `Work.error_budget`). Hops
//! that don't earn their copper are rolled back, so the tool can never make the
//! board worse than the caller said it was willing to accept.
//!
//! The accept gate runs INSIDE the routing batch, through `router.GapJudge`, so
//! the copper each hop is routed against is the copper the pass actually kept —
//! a hop the gate rolls back must not go on blocking the hops behind it.
//!
//! Two deliberate choices in the accept gate, both learned the hard way:
//!   * the geometry gate counts ERROR-severity violations only, while a
//!     separate monotone differential-quality gate rejects a hop that adds
//!     `diff uncoupled` / `diff skew`; unrelated RF warnings remain advisory;
//!     and
//!   * it uses `drc.check` (geometry) rather than the pour-aware
//!     `checkFilteredZones`, so the `net open` marker is EXCLUDED by
//!     construction. `net open` IS the airwire being closed and it fluctuates
//!     while a multi-hop net is partly joined; counting it reverts perfectly
//!     clean copper. The full pour-aware DRC runs once at the end, for the
//!     report.

const std = @import("std");
const mcp_arg_names = @import("mcp_arg_names.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const gap_policy = @import("../placement/gap_policy.zig");
const route_policy = @import("../placement/route_policy.zig");
const pour = @import("../placement/pour.zig");
const fab_readiness = @import("../fab_readiness.zig");
const pad_shape = @import("../placement/pad_shape.zig");
const geometry = @import("../placement/geometry.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const module_policy = @import("../placement/module_policy.zig");
const vacate_policy = @import("../placement/vacate_policy.zig");
const nomination = @import("../placement/blocker_nomination.zig");
const via_merge = @import("../placement/via_merge.zig");
const route_plan = @import("route_plan.zig");
const env_mod = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const serve_root = @import("../serve.zig");
const log = @import("../infra/log.zig");
const clock = @import("../infra/clock.zig");
const net_names = @import("../net_name.zig");

const SavedTrack = pcb_layout_page.SavedTrack;
const SavedVia = pcb_layout_page.SavedVia;
const SavedRoutes = pcb_layout_page.SavedRoutes;
const SavedRfPath = @import("../layout_sidecar_types.zig").SavedRfPath;
const HandlerError = pcb_layout_page.HandlerError;

fn netNameAt(nets: []const export_kicad.FlatNet, raw: i32) []const u8 {
    if (raw < 0) return "";
    const i: usize = @intCast(raw);
    return if (i < nets.len) nets[i].name else "";
}

/// Passes over the open-net list. Round 0 stitches plane-carried nets and
/// bridges the rest; later rounds bridge everything still open, so a net whose
/// stitch found no site still gets a surface route attempt.
const default_rounds: usize = 4;
/// Ceiling on hops requested per round, so a pathological board can't turn one
/// call into an unbounded maze run.
const max_hops_per_round: usize = 400;
/// Cap on the reported per-hop failure list.
const max_reported_failures: usize = 24;
/// How deep a rip may cascade inside ONE hop's transaction. **Zero — the
/// cascade is built and correct, but off by default.**
///
/// A repair is itself a routing problem, and on a congested board the corridor
/// the victim needs can be held by a THIRD net; at depth zero that hop dies
/// `broke_victim` however wide the first rip goes. Letting the repair rip in
/// turn is what "rip up and REORDER" means once more than two nets contend for
/// one channel, and `repairNet` implements it — the whole cascade stays inside
/// the same all-or-nothing transaction (`Work.tryHop`), so a cascade that does
/// not pay for itself is rolled back byte for byte.
///
/// It is nonetheless disabled, because on the board it was written for it has
/// never once paid: measured on board-a at both pour priorities it closed
/// NOTHING that depth zero did not, while a cascading repair costs a maze sweep
/// plus two connectivity oracle passes per victim — together with the multi-net
/// rip rung (`router.rip_tiers`) it took the pass from 345 s to 530 s (+54 %).
/// Raise it to 1 to re-arm the cascade on a board with genuine multi-net
/// congestion, where the third net really is the thing in the way. It is also
/// the FLOOR the last-K rule lifts off (`repairRipDepthFor`): the measurement
/// above was taken with the whole residual open, which is the case the cascade
/// is worst at.
const max_repair_rip_depth: usize = 0;
/// How far up the router's rip ladder a rejected hop may escalate (see
/// `escalateRip`). **One rung short of the top — the multi-net rung is built
/// and correct, but off by default.**
///
/// `router.rip_tiers`'s top rung is the `union_only` breadth: skip the singles
/// and rip every net walling the corridor at once. It is the right answer for a
/// hop that three nets contend over, and `RipBreadth` implements it — but it is
/// also a whole extra maze sweep on every hop the singles already failed, and on
/// board-a it has never changed a verdict at either pour priority. Together
/// with the repair cascade (`max_repair_rip_depth`) it cost +54 % wall clock for
/// nothing. Set it back to `router.rip_tiers` to re-arm the rung; the singles-
/// then-union breadth on rungs 1–3 still tries the union, so this only drops the
/// *dedicated* multi-net pass. It is also the FLOOR the last-K rule lifts off
/// (`ripTierCapFor`) — "never changed a verdict" was measured on a board with
/// its whole residual still open.
const max_rip_tier: usize = router.rip_tiers - 1;
/// Is the last-K adaptation of the two constants above armed at all?
///
/// Both are off because they cost far more than they pay IN THE MIDDLE of a
/// board — and `gap_policy.LastK` is the observation that "in the middle" is the
/// only place that was ever measured. "This is congestion for a wider rip to
/// solve" and "the cascade never pays" are verdicts about a board with thirty
/// nets open; with three left, the wide rip IS the remaining move and there is
/// nothing cheaper to spend the time on instead. The policy already exists for
/// the router's own fine-window classifier, and its `LastKRungs.wide_rip` field
/// was written for exactly these two constants, so this is an adoption rather
/// than a new threshold: one rule, read in two ladders.
///
/// **It is nonetheless OFF, because it was measured and it does not pay.**
/// board-a's `close_open_nets` ladder from the from-zero `t3-seed` placement,
/// run to a fixed point on the same machine, ReleaseSafe, both arms in parallel
/// (2026-08-06):
///
///   * armed:    call 1 281.4 s → 85/91, call 2 175.6 s → 85/91, **457.0 s**
///   * disarmed: call 1 229.1 s → 85/91, call 2 181.2 s → 85/91, **410.4 s**
///
/// Same fixed point, the same SIX open nets in the same order (`GND`, `V_3V3A`,
/// `V_12V`, `V_3V3_LMX`, `adf4159/SPI_ADF_CSN_1V8`, `buck_6v/VIN_F`), the same
/// two calls, the same one DRC error — for +46.6 s (+11 %). The rungs were not
/// idle either: the widened cascade fired ten times over the run and closed
/// nothing that depth zero had not already closed. So the endgame reading is
/// right in principle and still wrong on this board, and the honest place for it
/// is here, wired and disarmed, exactly like the two constants above.
///
/// Flip to `true` to arm it on a board with genuine multi-net congestion in its
/// residual — that is the case the rungs were built for and the one board-a's
/// six remaining nets are not (they are a plane rail, three supply pours, and
/// two escapes with no free lane, none of which a wider rip can reach).
const adopt_last_k: bool = false;

/// The residual width and per-board spend cap the widened rungs arm under.
const last_k: gap_policy.LastK = .{};

/// May the NEXT hop take a widened rung? Both bounds have to hold: the residual
/// must be small enough for the endgame reading to apply (`rungs.wide_rip`,
/// which `gap_policy.lastKRungs` sets from the open count at the last round
/// boundary), and this call must not already have let `last_k.spenders` hops pay
/// for one. The cap is what stops a residual sitting JUST under the threshold
/// from turning twenty hops into twenty extra whole-board maze sweeps.
fn wideArmed(rungs: gap_policy.LastKRungs, spent: usize) bool {
    return rungs.wide_rip and spent < last_k.spenders;
}

/// How far up the rip ladder a hop may escalate, given `wideArmed`. The widened
/// answer is `router.rip_tiers` — the dedicated multi-net `union_only` pass that
/// `max_rip_tier` normally cuts off.
fn ripTierCapFor(armed: bool) usize {
    return if (armed) router.rip_tiers else max_rip_tier;
}

/// How deep a rip may cascade inside one hop's transaction, given `wideArmed`.
/// One is the whole widening: the repair may rip in turn ONCE, which is what
/// "rip up and reorder" means when a third net holds the corridor the victim
/// needs. Everything stays inside `tryHop`'s all-or-nothing transaction either
/// way, so a cascade that does not pay for itself is still rolled back whole.
fn repairRipDepthFor(armed: bool) usize {
    return if (armed) 1 else max_repair_rip_depth;
}

/// Most nets one hop's transaction will disturb. Every victim costs a repair
/// route plus two connectivity passes in the accept gate, so an unbounded
/// cascade turns one hop into a whole-board re-route. Reaching the cap stops
/// the cascade; the gate then judges what is on the board, and rejects it
/// unless every victim came out whole.
const max_transaction_victims: usize = 6;
/// How far from the straight line joining two of a still-open net's islands a
/// track counts as standing in that net's way (see `corridorBlockers`). Wide
/// enough to catch the copper actually lying across the channel plus its
/// clearance, narrow enough that a cross-board corridor does not nominate every
/// net on the board.
const vacate_corridor_mm: f64 = 2.0;
/// Most nets one seed's wholesale re-route strips and puts back. Every one of
/// them has to re-close inside the same transaction or the whole thing is
/// rolled back, so a wide subset is both slow and unlikely to survive.
const max_vacate_blockers: usize = 6;
/// Most seeds the wholesale phase works in one call.
const max_vacate_seeds: usize = 6;
/// Most copper islands a seed may still be in for the phase to take it on.
///
/// The phase is a targeted corridor vacate for a net that is nearly whole and
/// walled in — one or two hops away. A net in a dozen pieces is a different
/// problem (a plane net whose pads rejoin by stitching), its transaction has to
/// re-ask every one of those hops on a board it just emptied, and it can only
/// be kept if ALL of them land. On board-a that is `GND`: seventeen islands,
/// nine minutes of maze, and a rollback at the end of it.
const max_vacate_seed_islands: usize = 4;
/// Most island-joining corridors of one seed that nominate blockers. A net in
/// seventeen pieces has sixteen corridors and they are reported nearest-first;
/// the far ones add nets without adding information.
const max_vacate_corridors: usize = 8;
/// The finer rung of a wholesale transaction's grid ladder (see `vacateFor`).
/// Halving the divisor-2 gap pitch is what makes two minimum-width escapes
/// representable when they legally need 0.254 mm centre-to-centre and the
/// divisor-2 lattice's adjacent lane falls just short — the next lane out
/// doubles the spacing and misses the corridor. Measured on board-a's J1
/// fine-pitch row: the two contending escapes run 0.265 mm apart on the
/// reference board, which this raster can hold and the standard one provably
/// cannot.
const vacate_fine_divisor: f64 = 4;

/// Most still-open seeds one JOINT transaction re-closes together (see
/// `Work.jointPhase`). Three is the width at which the union of three corridors
/// still names a subset small enough to come back inside one all-or-nothing
/// gate; past it the transaction is a whole-board re-route with a rollback.
const max_joint_seeds: usize = 3;
/// Most nets one joint transaction displaces — the union across its seeds. Six
/// rather than the single-seed tier's three because the transaction is serving
/// several corridors, and one blocker apiece is the minimum that makes it a
/// joint transaction at all.
const max_joint_blockers: usize = 6;
/// Total tracks+vias one joint transaction may take off the board. The net cap
/// alone bounds the wrong thing (`vacate_policy.Limits`'s lesson); this is
/// 1.5x the single-seed budget, in step with the doubled net cap, so a joint
/// transaction is allowed to be bigger but not unboundedly so.
const max_joint_elements: usize = 96;
/// Most seed clusters one call forms. The attempt cap below is the real bound;
/// this stops a board with thirty open nets from spending the whole call
/// forming clusters that never get an attempt.
const max_joint_clusters: usize = 3;
/// Whole-pass cap on joint cluster re-route attempts (clusters × rungs ×
/// orders). THE hard bound on the joint tier's wall time, independent of how
/// the per-cluster caps happen to compose — the house rule after two unbudgeted
/// sweeps. Six is one cluster's full ladder (two rasters × three orders), so a
/// cluster that wins on its first rung leaves attempts for the next cluster and
/// one that never wins cannot starve the call.
const max_joint_attempts: usize = 6;

/// Rounds inside one wholesale transaction. Two, because `bridgesNow` splits a
/// plane-carried net's STITCH (round 0) from its BRIDGES (round 1) — a single
/// round can only ask for both at once, which spends a corridor the stitch did
/// not need. Nothing above two: a transaction that has not put its displaced
/// nets back in a stitch pass and a bridge pass is not going to.
const vacate_rounds: usize = 2;

/// The corridor-bounded fine rungs, coarsest first.
///
/// A board-wide divisor-8 raster was built, measured, and REMOVED: it ran over
/// 50 minutes on a two-net request without returning, because each rung costs
/// the square of the divisor over the whole placement. Bounded to one hop's
/// corridor the same rung is affordable, which matters because the residue it
/// targets is specifically a lattice problem — board-a's `SPI_SCK` has a legal
/// ~35 mm way round whose tightest points clear by 0.07-0.20 mm, and the
/// divisor-4 pitch (~0.11 mm) cannot put a centreline on them.
const fine_divisors = [_]f64{ vacate_fine_divisor, vacate_fine_divisor * 2 };

/// How far outside a hop's terminals its fine-rung corridor reaches (mm).
/// mirror-of: src/placement/fine_window.zig.window_margin_mm
/// The whole-board rescue's own apron: enough
/// for a route to step around the parts flanking its endpoints without opening
/// the search back up to the board.
const fine_corridor_margin_mm: f64 = 3.5;

/// Whole-board fine search is an endgame move, not another default retry. It
/// exists for long bridges whose legal route leaves the terminal rectangle
/// altogether (Board A's control bus runs around the top board edge), and is
/// bounded both by residual width and by per-call spend.
const global_detour_last_nets: usize = 6;
const global_detour_spenders: usize = 2;
const global_detour_min_span_mm: f64 = 4.0;
/// Let each final fine search drain four times as much of the already-allocated
/// raster. The width/spender gates above bound who can pay; ordinary gap passes
/// retain multiplier 1 byte-for-byte.
const fine_expansion_multiplier: usize = 4;
/// Candidate global corridors sit this far inside the placement/outline bounds,
/// with a small apron for the local raster around their three guided legs.
const boundary_detour_inset_mm: f64 = 1.0;
const boundary_detour_margin_mm: f64 = 1.5;
const boundary_escape_mm: f64 = 4.0;

const BoundaryDetour = struct {
    first: router.NetPt,
    second: router.NetPt,
    window: router.GapWindow,
};

const ArtifactPrune = struct { tracks: usize = 0, vias: usize = 0 };

/// "This track end sits on that via" tolerance for the same-net via fold (mm),
/// and the length below which a re-anchored segment has collapsed to nothing.
/// The router emits a track end and its via from one grid node, so this only
/// absorbs float drift.
const via_fold_snap_mm: f64 = 1e-6;

/// Progress to the server log. A finishing pass runs for minutes on a full
/// board; an agent watching only the JSON reply cannot tell slow from hung, and
/// cannot tell WHICH net is eating the time.
fn progress(comptime fmt: []const u8, args: anytype) void {
    log.progress("close_open_nets: " ++ fmt, args);
}

/// One search deadline shared by all rounds and their nested repair attempts.
/// Validation and persistence still finish after it so accepted copper is safe.
const SearchBudget = struct {
    stop: route_policy.Stop = .{},
    timed_out: bool = false,

    fn fromArgs(args_val: ?std.json.Value) ?SearchBudget {
        const args = args_val orelse return .{};
        if (args != .object or !args.object.contains("max_route_ms")) return .{};
        const ms = argUsize(args_val, "max_route_ms") orelse return null;
        if (ms > 3_600_000) return null;
        return .{ .stop = .{ .max_route_ms = ms } };
    }

    fn arm(self: *SearchBudget) void {
        if (self.stop.max_route_ms != 0 and self.stop.deadline_ns == 0)
            self.stop.deadline_ns = clock.nanoTimestamp() + @as(i128, self.stop.max_route_ms) * clock.ns_per_ms;
    }

    fn stopped(self: *SearchBudget) bool {
        if (self.stop.deadline_ns != 0 and clock.nanoTimestamp() >= self.stop.deadline_ns) self.timed_out = true;
        return self.timed_out;
    }

    fn restrict(self: *const SearchBudget, original: route_policy.Stop) route_policy.Stop {
        var out = original;
        const deadline = self.stop.deadline_ns;
        if (deadline != 0 and (out.deadline_ns == 0 or deadline < out.deadline_ns)) out.deadline_ns = deadline;
        return out;
    }
};

/// `close_open_nets` — route the copper that closes the board's remaining
/// airwires, verified hop by hop against the connectivity oracle.
pub fn mcpCloseOpenNets(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const started_ms = clock.milliTimestamp();
    const name = argStr(args_val, "name") orelse return fail(out, alloc, "missing required arg: name");
    const layout_arg = argStr(args_val, "layout");
    const rounds = roundCount(args_val) orelse
        return fail(out, alloc, "rounds must be a non-negative integer; zero skips ordinary rounds");
    const only = try argNames(alloc, args_val, "nets");
    const budget = SearchBudget.fromArgs(args_val) orelse
        return fail(out, alloc, "max_route_ms must be an integer from 1 to 3600000; omit it for no search deadline");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return failFmt(out, alloc, "could not resolve layout: {s}", .{@errorName(e)});
    const working = pcb_layout_page.mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return fail(out, alloc, "no saved layout to finish — save a layout first");
    const routes = working.routes orelse
        return fail(out, alloc, "the saved layout carries no copper — route or draw some first");

    var work = Work{
        .alloc = alloc,
        .budget = budget,
        .placement = solved.placement,
        .params = solved.placement.rules.design.routeParams(),
        .zones = solved.shown_zones.user,
        .router_zones = try zoneSources(alloc, solved.placement, solved.shown_zones.user),
        .rules = drc_rules.loadForValidation(alloc, project_dir, name) orelse
            return fail(out, alloc, "could not read the complete DRC policy; layout was not changed"),
        .tracks = try dupeList(SavedTrack, alloc, routes.tracks),
        .vias = try dupeList(SavedVia, alloc, routes.vias),
        .rf_paths = routes.rf_paths,
        .only = only,
        .error_budget = argUsize(args_val, "drc_error_budget"),
    };
    work.plan = try finishingPlan(alloc, solved.block, solved.placement, work.zones);
    work.base_drc = try work.errorViolations();
    work.error_ceiling = try work.geometryErrors();
    work.diff_ceiling = try work.diffWarnings();
    work.budget.arm();

    const original_bypasses = try work.missingBypasses();
    var tally = Tally{};
    if (argBool(args_val, "repair_bypasses") orelse true) tally.bypasses = try work.repairBypasses();
    for (0..rounds) |round| {
        if (work.budget.stopped()) break;
        const planned = try work.planRound(round);
        const gaps = planned.gaps;
        progress("round {d}: {d} hops planned", .{ round, gaps.len });
        if (gaps.len == 0) break;
        const open_before = planned.open.len;
        const kept = try work.runRound(gaps, planned.open);
        tally.tried += kept.tried;
        tally.kept += kept.hops;
        tally.ripped += kept.ripped;
        tally.no_path += kept.no_path;
        tally.rejected += kept.rejected;
        tally.pair_rejected += kept.pair_rejected;
        progress("round {d}: kept {d}, no_path {d}, rejected {d}, ripped {d}", .{ round, kept.hops, kept.no_path, kept.rejected, kept.ripped });
        if (memoStale(kept.ripped, open_before, try work.openNetCount())) {
            work.dead_ends.clearRetainingCapacity();
        }
        if (roundsExhausted(round, kept)) break;
    }
    // Nothing above can make an already-closed net take a different shape, and
    // that is what the last few nets need (see the `vacatePhase` header). The
    // joint tier follows it because it is the more expensive move and because
    // its clusters are formed from whatever the single-seed pass left open.
    if (!work.budget.stopped() and (argBool(args_val, "vacate") orelse true)) {
        tally.vacated = try work.vacatePhase();
        tally.joint = try work.jointPhase();
    }
    // Last, because every phase above can plant one: a via the finishing search
    // dropped a few hundred microns from a barrel this net already had.
    const before_cleanup_tracks = try alloc.dupe(SavedTrack, work.tracks.items);
    const before_cleanup_vias = try alloc.dupe(SavedVia, work.vias.items);
    const before_cleanup_bypasses = try work.missingBypasses();
    if (!work.budget.stopped()) tally.folded = try work.foldRedundantVias();
    const pruned = if (!work.budget.stopped()) try work.pruneArtifacts() else ArtifactPrune{};
    tally.artifact_tracks_pruned = pruned.tracks;
    tally.artifact_vias_pruned = pruned.vias;
    // Cosmetic cleanup cannot undo a surface bond that this call just earned.
    if (newBypassMissing(before_cleanup_bypasses, try work.missingBypasses())) {
        work.tracks = try dupeList(SavedTrack, alloc, before_cleanup_tracks);
        work.vias = try dupeList(SavedVia, alloc, before_cleanup_vias);
        work.dead = &.{};
        tally.folded = 0;
        tally.artifact_tracks_pruned = 0;
        tally.artifact_vias_pruned = 0;
    }

    const final = (try finalCheck(alloc, project_dir, name, &work)) orelse
        return fail(out, alloc, "final DRC validation was incomplete; layout was not changed");
    if (newBypassMissing(original_bypasses, try work.missingBypasses()))
        return fail(out, alloc, "finishing broke an authored bypass connection; layout was not changed");
    var entry = working;
    entry.routes = .{ .tracks = work.tracks.items, .vias = work.vias.items, .zones = routes.zones, .rf_paths = routes.rf_paths };
    try pcb_layout_page.mcpPersistWorking(alloc, project_dir, name, entry, false);
    return writeResult(out, .{
        .alloc = alloc,
        .design = name,
        .layout = entry.name,
        .work = &work,
        .final = final,
        .tally = tally,
        .wall_ms = @max(0, clock.milliTimestamp() - started_ms),
    });
}

/// Has the pass run out of ideas after finishing `round` with `kept`? A round
/// that kept nothing has not necessarily: round 0 plans only STITCHES for a
/// plane-carried net — its bridges start at round 1 — so stopping there never
/// tries a surface route for the very nets a plane stitch just failed on; and a
/// round that RIPPED copper cleared the dead-end memo, so the next round
/// genuinely re-asks hops this one refused. Stop only once a round that had
/// something new to try did nothing with it.
fn roundsExhausted(round: usize, kept: RoundResult) bool {
    return round > 0 and kept.hops == 0 and kept.ripped == 0;
}

/// May this round ask for an open net's maze BRIDGES, given how many STITCHES
/// the same round just planned for it?
///
/// The rule is "round 0 stitches a plane-carried net, later rounds bridge it":
/// a net whose pads are joined by a plane rejoins by dropping a via into that
/// plane, and asking for a surface trace between two QFN ground pads first
/// wastes the corridor a real bridge might need. The clause that matters is the
/// last one. When the stitch pass planned NOTHING for that net — every island
/// the oracle found is already joined to plane copper, so a via there could
/// only land in metal the island is part of, which is exactly the hop
/// `addStitches` refuses to plan — there is no round-0 hop for its bridges to
/// wait behind, and those bridges are the net's only move.
///
/// Withholding them anyway is what made a scoped call a no-op. `planRound`
/// returning nothing ends the pass (`gaps.len == 0` breaks the round loop), so
/// `nets:["GND"]` on a board whose `GND` islands are each already plane-joined
/// planned zero hops, tried nothing, and returned the board untouched — while
/// the SAME board's unscoped run kept planning for other nets, reached round 1,
/// and asked for those very bridges. The tool's own `exhausted` remedy tells an
/// agent to "narrow the job by routing this net alone", so the shape it
/// recommends was the one shape that could not work.
fn bridgesNow(round: usize, plane_carried: bool, stitches: usize) bool {
    return round > 0 or !plane_carried or stitches == 0;
}

/// Has the round just finished invalidated the dead-end memo (see `Work.note`)?
///
/// Two things change the answer a re-asked hop would get. A **rip** is the
/// obvious one: it is the only thing that takes copper off the board. The other
/// is a net **becoming whole**, because a rip may only take copper from a net
/// that is already in one piece (`Work.rippedAnOpenNet`) — so every net a round
/// finishes hands the hops behind it an aggressor they were not allowed to move
/// before. Without this, a long bridge refused in round 0 because its one
/// blocker was still half-routed is never asked again, even though the very next
/// round finishes that blocker.
fn memoStale(ripped: usize, open_before: usize, open_after: usize) bool {
    return ripped > 0 or open_after < open_before;
}

fn hasBypass(items: []const drc.Violation, target: drc.Violation) bool {
    for (items) |item| {
        if (item.who.part_a != target.who.part_a or item.who.part_b != target.who.part_b) continue;
        if (std.mem.eql(u8, item.who.pad_a, target.who.pad_a) and std.mem.eql(u8, item.who.pad_b, target.who.pad_b)) return true;
    }
    return false;
}

fn newBypassMissing(before: []const drc.Violation, after: []const drc.Violation) bool {
    for (after) |item| if (!hasBypass(before, item)) return true;
    return false;
}

/// What one call accomplished.
const Tally = struct {
    bypasses: usize = 0,
    tried: usize = 0,
    kept: usize = 0,
    ripped: usize = 0,
    no_path: usize = 0,
    rejected: usize = 0,
    /// Hops rolled back because they would add a differential-pair coupling or
    /// skew warning.  An airwire is safer than silently persisting two
    /// independently-routed clock legs.
    pair_rejected: usize = 0,
    /// Nets closed by the single-seed wholesale re-route (`Work.vacatePhase`).
    vacated: usize = 0,
    /// Nets closed by the multi-seed JOINT tier (`Work.jointPhase`). Counted
    /// apart from `vacated` because they are different moves: one seed's
    /// corridor cleared, versus several contending seeds' corridors cleared and
    /// re-closed together.
    joint: usize = 0,
    /// Redundant same-net vias folded onto the barrel already there
    /// (see `Work.foldRedundantVias`).
    folded: usize = 0,
    artifact_tracks_pruned: usize = 0,
    artifact_vias_pruned: usize = 0,
};

/// What became of one applied hop.
const Verdict = enum {
    kept,
    /// The maze/stitch found no legal copper at all.
    no_path,
    /// Copper landed but the net's islands did not merge — e.g. a pour via a
    /// higher-priority overlapping pour clips, so it credits nothing.
    no_merge,
    /// The rip this hop needed left the ripped net more broken than it found it.
    broke_victim,
    /// The copper added a geometry DRC error.
    drc,
    /// The copper made differential-pair coupling/skew quality worse.
    diff_pair,
    bypass,
};

/// The next thing worth TRYING for a hop that did not land, in the caller's own
/// vocabulary.
///
/// `stuck[]` grew ranked remedies because a bare failure tag ("order_congestion")
/// tells an agent nothing it can act on. The gap closer's failures are the ones
/// an agent acts on NOW — they carry exact coordinates and a live board — and
/// until now they carried only a verdict and a router reason. This closes that
/// gap: each pairing of (what the gate decided, what the maze ran into) maps to
/// the one move that addresses it.
///
/// `scoped` says the caller ALREADY restricted the pass with `nets`, and it
/// exists for one remedy: telling an agent to "narrow the job by routing this
/// net alone" is a loop when routing that net alone is the call it just made.
/// A remedy an agent cannot act on further is the same defect as no remedy —
/// so when the job is already as narrow as that advice can make it, the next
/// move has to be a different KIND of move, not the same call again.
fn remedyFor(verdict: Verdict, why: router.GapReason, scoped: bool) []const u8 {
    return switch (verdict) {
        .kept => "",
        .bypass => "the repair broke an authored capacitor-to-IC surface connection; preserve that exact bond",
        .no_merge => "the copper landed but joined nothing — check whether a higher-priority pour clips this net's zone here, or raise this net's (net-class … (priority …)) zone rank",
        .broke_victim => "the rip this hop needed broke its victim — route the victim net first, or free the corridor by hand with add_tracks",
        .drc => "the copper broke a clearance rule — see drc_new for the rule and shortfall; a narrower (net-class … (width …)) or a different corridor is what it wants",
        .diff_pair => "the hop would route one differential leg independently and worsen coupling/skew — route both pair members together with route_pcb, or free a shared corridor for the pair",
        .no_path => switch (why) {
            .policy => "the candidate exceeds the authored layer or new-via limits — inspect the route wave and find a path within its constraints",
            .sealed_from, .sealed_to => "a terminal pad has no exit — its neighbours seal it; move the blocking part, or hand-draw the escape via with add_tracks",
            .no_via_site => "no legal via site near the pad — clear the drills/copper crowding it, or place the via by hand with add_tracks",
            .exhausted => if (scoped)
                "the search ran out of budget rather than options, and the job is already scoped to this net — the autorouter has no narrower call left to make. Read describe_pcb_layout's open_nets[] for this net's pad coordinates and gaps[] (add ?pads=1 for the obstacle set) and lay the copper with add_tracks"
            else
                "the search ran out of budget rather than options — narrow the job by routing this net alone (nets: [\"…\"])",
            else => "no legal channel exists on the current board — free one by re-routing a blocker, or draw this net by hand with add_tracks",
        },
    };
}

/// Which part of the pass a hop was asked for. Both go through `Work.runRound`,
/// which is why their diagnoses used to arrive in the caller's `failed[]` as one
/// undifferentiated list.
const Phase = enum {
    /// The round loop: hops on the open nets the CALLER named, against the board
    /// as it stands. These are the diagnoses an agent acts on.
    round,
    /// The wholesale re-route (`Work.vacatePhase`): hops on the foreign nets a
    /// seed's transaction stripped off the board and has to put back. They name
    /// nets that are neither open nor in the caller's scope, they are measured
    /// against a board with whole nets deliberately missing, and when the
    /// transaction rolls back they describe copper that was restored
    /// byte-for-byte. Real, and worth keeping — but not an answer to "what is
    /// still wrong with my board".
    vacate,
};

/// Which rule the wholesale phase nominates a seed's blockers by (see
/// `Work.corridorBlockers`).
const Tier = enum {
    /// Nearest-first over the copper the phase considers safe to restructure —
    /// the original rule, unchanged.
    standard,
    /// Cheapest-to-restore first, over everything in the corridor, judged by
    /// `vacate_policy`. Reached only once `standard` has failed both rasters.
    cheap,
};

/// Where a joint transaction's still-open SEEDS sit in the cluster's routing
/// order (see `Work.jointVacate`). The blockers keep the pass's own
/// hardest-first order among themselves, so the only variable is when the seeds
/// get their turn — which is the whole question, because a maze is
/// first-claim-wins.
const JointOrder = enum {
    /// Every seed first: they claim the freed channel and the displaced copper
    /// must find its own way back. The single-seed tier's order, generalised —
    /// kept because it is the one most likely to close the seeds.
    seeds_first,
    /// One pool, ordered by the pass's own rule (plan wave, then hop span):
    /// what an ordinary round would have done had the corridor been empty.
    contended,
    /// Seeds last: the displaced copper re-lays first, jointly, and the seeds
    /// take what is left. The only order that can find a solution in which the
    /// blockers moved ASIDE rather than merely returning to where they were.
    seeds_last,
};

/// The orders a cluster is tried under, in try order.
const joint_orders = [_]JointOrder{ .seeds_first, .contended, .seeds_last };

/// The rasters a cluster is tried on, coarsest first — the same two rungs the
/// single-seed ladder walks, and for the same reason: a lattice that cannot
/// represent the lane and a corridor that is simply occupied are different
/// failures, and a walled-in cluster can be suffering both.
const joint_rasters = [_]f64{ router.gap_grid_divisor, vacate_fine_divisor };

/// One transaction's routing order as `Work.planFor` takes it: the net list, and
/// how many of its leading entries claim their corridors before the rest.
const Sequence = struct { nets: []const usize, lead: usize };

/// One read of the board a nomination pass works from (see `Work.boardView`):
/// the connectivity oracle's open-net report, and the live copper it describes.
const BoardView = struct {
    open: []const fab_readiness.OpenNet,
    routes: router.RouteResult,
};

/// A board a joint attempt can be put back to — copper AND the dead-end memo,
/// because a transaction clears the memo as its first act (see `Work.restore`).
const Snapshot = struct {
    tracks: std.ArrayList(SavedTrack),
    vias: std.ArrayList(SavedVia),
    dead_ends: std.ArrayList(HopKey),
    error_ceiling: usize,
    diff_ceiling: usize,
};

/// The joint tier's remaining allowance, threaded through the whole pass so the
/// caps compose into ONE bound on the tier rather than a per-cluster one that
/// multiplies by however many clusters a board happens to yield.
const JointBudget = struct {
    clusters_left: usize = max_joint_clusters,
    attempts_left: usize = max_joint_attempts,

    /// Claim one cluster slot, or report the pass is done forming clusters.
    fn takeCluster(self: *JointBudget) bool {
        if (self.clusters_left == 0 or self.attempts_left == 0) return false;
        self.clusters_left -= 1;
        return true;
    }

    /// Claim one cluster re-route attempt, or report the pass is out of them.
    fn takeAttempt(self: *JointBudget) bool {
        if (self.attempts_left == 0) return false;
        self.attempts_left -= 1;
        return true;
    }
};

/// Do two still-open seeds contend for the same copper?
///
/// Either their corridors are held by a net in common, or one of them is
/// standing in the other's corridor — which is contention in its purest form
/// and the case a shared-blocker test alone would miss. The answer is a bool
/// over set membership, so the map iteration inside is order-independent and
/// the clustering stays deterministic.
fn contended(ta: nomination.Table, tb: nomination.Table, a: usize, b: usize) bool {
    if (ta.has(b) or tb.has(a)) return true;
    var it = ta.near.keyIterator();
    while (it.next()) |k| {
        if (tb.has(k.*)) return true;
    }
    return false;
}

/// One net a cheap transaction stripped, and what became of it.
const VacatePick = struct {
    net: []const u8,
    kind: vacate_policy.Kind,
    /// Tracks + vias it had before the strip.
    before: usize,
    /// Tracks + vias it has after the transaction settled.
    after: usize = 0,
    /// Is the net in one piece again? A pour-carried rail can be whole with far
    /// less copper than it started with — that is precisely why it was cheap.
    whole: bool = false,
};

/// One net the cheap tier looked at in the corridor and declined.
const VacateRefusal = struct { net: []const u8, why: vacate_policy.Refusal };

/// One cheap transaction's decision trace: what it nominated, in what order,
/// what it refused and why, and whether the board it produced was kept.
///
/// Reported to the caller because a rolled-back transaction is otherwise
/// invisible — the pass says "still open" and nothing about the move it tried.
/// This is the agent-facing half of the tier: it names the copper the closer
/// was willing to move and the copper it would not touch, so the next decision
/// (hand-route with `add_tracks`, relax a class, move a part) is informed.
const VacateTrace = struct {
    seed: []const u8,
    picked: []VacatePick,
    refused: []const VacateRefusal,
    won: bool = false,
};

/// Net-index order over policy inputs, so the decision trace is stable.
fn factsByIndex(_: void, a: vacate_policy.NetFacts, b: vacate_policy.NetFacts) bool {
    return a.net_i < b.net_i;
}

/// One hop that did not land, as reported back to the caller.
const Failure = struct {
    net: []const u8,
    bridge: bool,
    x: f64,
    y: f64,
    verdict: Verdict,
    /// Which phase asked for this hop (see `Phase`) — the label that keeps a
    /// vacate transaction's internal churn out of the caller's answer.
    phase: Phase = .round,
    /// Set when the wholesale transaction that produced this diagnosis was
    /// rolled back, so the board it describes is not the board on disk.
    rolled_back: bool = false,
    /// The router's own diagnosis (sealed pad vs blocked channel vs no via
    /// site). `verdict` says the pass rejected the hop; this says what the maze
    /// actually ran into, which is what tells an agent whether to move a part or
    /// to free a channel.
    why: router.GapReason,
    /// When `verdict == .drc`: the violations this hop's copper INTRODUCED —
    /// rule, measured gap, and where. A bare "drc" tells an agent the gate
    /// refused the copper but not what to change; the rule and the shortfall
    /// are what turn the rejection into a constraint it can write.
    drc_new: []const drc.Violation = &.{},
};

/// Identity of one hop, so a round can tell it has already tried this exact
/// pad-to-pad request. Coordinates come straight from the oracle's pad table, so
/// the same hop replans to bit-identical values.
const HopKey = struct {
    net_i: usize,
    fx: f64,
    fy: f64,
    tx: f64,
    ty: f64,
    surface_only: bool = false,

    fn eql(self: HopKey, other: HopKey) bool {
        return self.net_i == other.net_i and self.fx == other.fx and self.fy == other.fy and
            self.tx == other.tx and self.ty == other.ty and self.surface_only == other.surface_only;
    }
};

/// The memo key of one gap request (a stitch has no far pad, so it keys on NaN-
/// free sentinels of its own start point).
fn hopKey(gap: router.Gap) HopKey {
    const to = gap.to orelse gap.from;
    return .{ .net_i = gap.net_i, .fx = gap.from.x, .fy = gap.from.y, .tx = to.x, .ty = to.y, .surface_only = gap.surface_only };
}

/// A round's outcome.
const RoundResult = struct {
    tried: usize = 0,
    hops: usize = 0,
    ripped: usize = 0,
    no_path: usize = 0,
    rejected: usize = 0,
    pair_rejected: usize = 0,
};

/// What a wider-rip retry settled on (see `Work.escalateRip`).
const Escalation = struct { verdict: Verdict, ripped: usize };

/// A saved arc expands into several physical tracks on restore. Rip indexes
/// address those chords; every chord must map back to its one saved owner.
fn savedTrackChordCount(alloc: std.mem.Allocator, track: SavedTrack) std.mem.Allocator.Error!usize {
    if (track.xm == null or track.ym == null) return 1;
    // Ask the persistence adapter itself so its tessellation and the owner
    // map cannot drift. Only the few true arcs need this temporary projection.
    const restored = pcb_layout_page.restoreRoutes(alloc, .{ .tracks = &.{track}, .vias = &.{} }, &.{}) orelse return error.OutOfMemory;
    return restored.tracks.len;
}

/// The board's copper as the router must see it, plus the way back. `closeGaps`
/// reports the tracks it ripped as indices into the array it was handed, and
/// that array is the LIVE board — already-ripped entries squeezed out — while
/// the caller's rip marks are kept against `Work.tracks`. Without `map` the two
/// index spaces silently disagree and a rip lands on the wrong segments.
const LiveCopper = struct {
    routes: router.RouteResult,
    /// `map[j]` is the `Work.tracks` index of live track `j`.
    map: []const usize,
};

/// One net waiting to be repaired inside a hop's transaction, and how many rips
/// deep the cascade already is when its turn comes (see `max_repair_rip_depth`).
const VictimTask = struct { net_i: usize, depth: usize };

const FinishingPlan = struct {
    rank: []const usize = &.{},
    net: []const route_policy.NetPolicy = &.{},
    reserved: []const route_policy.ReservedLane = &.{},
};

/// The mutable board a `close_open_nets` call is finishing, plus everything the
/// accept gate needs to judge a hop.
const Work = struct {
    surface_target: ?drc.Violation = null,
    alloc: std.mem.Allocator,
    budget: SearchBudget = .{},
    placement: optimizer.Placement,
    params: router.RouteParams,
    zones: []const pour.UserZone,
    router_zones: []const route_policy.ExistingZone,
    rules: drc_rules.Rules,
    tracks: std.ArrayList(SavedTrack),
    vias: std.ArrayList(SavedVia),
    /// Retained swept RF copper must participate in every connectivity/DRC gate.
    rf_paths: []const SavedRfPath = &.{},
    /// Net names in the design's `(pcb-plan (route (wave …)))` order — the
    /// author's declared routing priority, empty when there is no plan.
    ///
    /// The finishing pass used to ignore the plan entirely, so a constraint an
    /// author writes reached only half the pipeline: the whole-board router
    /// honours the waves, then this pass earns the last nets in span order,
    /// blind to the intent. On board-a that is 11 of 87 nets — most of the
    /// margin between a fresh route and the finished board — ordered against
    /// what the design says it wants.
    plan: FinishingPlan = .{},
    /// Error-severity violations present on the board as the gate last judged
    /// it, minus the ones already there when the pass opened — i.e. exactly
    /// what the rejected hop added. Set by `judge`, drained by `note`.
    last_drc: []const drc.Violation = &.{},
    /// The violations the board carried before this pass touched it, so
    /// `newViolations` can subtract a pre-existing finding from a hop's bill.
    base_drc: []const drc.Violation = &.{},
    /// Net names the caller restricted the pass to (empty = every open net).
    only: []const []const u8 = &.{},
    /// Which normally-refused rungs this call may arm, from the residual open
    /// count at the last round boundary (`refreshWhole`). All-false — a wide
    /// residual, or no copper yet — is the fixed-rung behaviour exactly.
    rungs: gap_policy.LastKRungs = .{},
    /// Open-net width at the current round boundary. Fine bridge rescue uses
    /// this to stay an endgame operation; ordinary mid-route failures keep the
    /// established cheap ladder.
    residual_open: usize = 0,
    /// Whole-board fine detours spent by this call. Corridor-local fine retries
    /// are cheap and do not consume it.
    global_detour_spent: usize = 0,
    /// How many hops this call has already let through the widened rip rung.
    /// Counted on ENTRY, not on success: the thing being bounded is the extra
    /// whole-board maze sweep, which a hop pays whether or not the rung lands.
    wide_spent: usize = 0,
    /// Ceiling on error-severity geometry violations, and the whole reason the
    /// pass cannot make a board worse. It is the count on the board as it
    /// stands, RATCHETED DOWN every time a hop lands with fewer — never the
    /// count the pass started with. Holding the *starting* count instead leaves
    /// the pass free to spend, hop by hop, every error the board happened to
    /// begin with: a board that opened with nine errors could drift back up to
    /// nine after copper elsewhere had cleaned it to six, and the call would
    /// still report "no rise" against its own stale baseline. Ratcheting makes
    /// the guarantee monotone — errors leave and never come back.
    error_ceiling: usize = 0,
    /// Monotone ceiling on differential coupling/skew warnings.  The whole
    /// router routes pairs together; the finishing pass works one gap at a
    /// time, so this ratchet is its pair-atomic safety net.
    diff_ceiling: usize = 0,
    /// The caller's ABSOLUTE ceiling on error-severity geometry violations, or
    /// null for "never rise" (`error_ceiling` alone).
    ///
    /// The ratchet answers "did this hop make the board worse", but that is not
    /// the question a board with a fab budget is asking. A designer who will
    /// ship at eight errors and sits at six has two errors of headroom, and
    /// refusing every hop that would spend one of them leaves airwires open for
    /// nothing. So the budget is a RELAXATION, never a tightening: a hop is
    /// judged against whichever of the two is higher, and it still has to make
    /// strict connectivity progress (`judge` checks the island drop first).
    /// Absent — the default — the gate is exactly the monotone one, so nothing
    /// about an existing call changes and the extra copper is opt-in per call.
    ///
    /// **On board-a it does not pay, and the numbers are worth keeping.** The
    /// hypothesis was that `GND`'s 1.4–2.0 mm island gaps each cost exactly one
    /// `track↔pad` error, so one error of headroom would close the net. Measured
    /// on the finished board (both pour priorities, geometry sitting at six
    /// errors): a budget of 7 keeps **zero** extra hops — the rejected bridges
    /// each cost more than one error, not one. A budget of 12 keeps two, for
    /// +2 `track↔pad` (one of them at gap −0.001 mm, i.e. copper touching a
    /// foreign pad) and +2 `hole↔hole` from the re-route its rip forced onto
    /// `REF_LMX_P` — and `GND` is still open afterwards. Handed to a whole pass
    /// rather than one net, a budget of 7 costs a net on both fixtures (86→85
    /// and 87→86) because the first hop to spend the headroom takes a corridor
    /// `V_12V` needed. Use it to buy a specific, inspected hop; do not leave it
    /// on for a general pass.
    error_budget: ?usize = null,
    /// A FLOOR under `errorCap` while a wholesale re-route is in flight (see
    /// `vacateFor`), or null outside one.
    ///
    /// The phase begins by taking whole nets OFF the board, which usually drops
    /// the geometry error count — and the ratchet would then hold the nets it
    /// stripped to the emptier board's count, refusing to let its own copper
    /// back on. The floor pins the ceiling at the pre-phase count for the
    /// duration, so the displaced copper may return exactly as clean as it was.
    /// It cannot be a way in for new errors: the phase's own accept gate rejects
    /// the whole transaction unless the final count is ≤ the pre-phase one.
    phase_floor: ?usize = null,
    failures: std.ArrayList(Failure) = .empty,
    /// Which phase `note` stamps onto the failures it records. `vacateAt` flips
    /// it around its own `runRound` exactly as it does `terminal_via` and
    /// `grid_divisor`, so a transaction's internal hops are labelled at source
    /// rather than guessed at from the net name afterwards.
    phase: Phase = .round,
    /// Hops already tried and failed since the last rip-up (see `note`).
    dead_ends: std.ArrayList(HopKey) = .empty,
    /// Round-scoped rip-up marks over the round's STARTING track array. Ripped
    /// copper is only flagged during a round, never spliced out, so the `ripped`
    /// indices `closeGaps` reported stay valid for every later hop; the round's
    /// end compacts the list.
    dead: []bool = &.{},
    /// Every net the hop in flight has ripped copper out of, mapped to the
    /// island count it had BEFORE that rip. The accept gate holds each of them
    /// to "no worse than you found it", so a cascade cannot pay for one net by
    /// quietly breaking a third.
    victims: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// The same victims in discovery order, each with its cascade depth — the
    /// repair worklist for the hop in flight.
    victim_queue: std.ArrayList(VictimTask) = .empty,
    /// Every track index the hop in flight has marked dead, across the whole
    /// cascade. A rollback has to un-mark all of them, not just the ones the
    /// first rip asked for.
    ripped_marks: std.ArrayList(usize) = .empty,
    /// Which nets were whole when the current round opened — the nets a rip is
    /// allowed to take copper from (see `rippedAnOpenNet`). Refreshed per round
    /// rather than per hop: the oracle pass that builds it costs about as much
    /// as one maze sweep, and a net that closes mid-round is picked up by the
    /// next round, whose dead-end memo `memoStale` has just cleared for exactly
    /// this reason.
    whole: []bool = &.{},
    /// Seeds the wholesale phase has already spent a transaction on, kept or
    /// rolled back — a rolled-back seed must not be re-tried, because nothing
    /// about the board changed and the transaction would run identically.
    vacate_tried: std.ArrayList(usize) = .empty,
    /// Every cheap-tier transaction's decision trace, in the order it ran (see
    /// `VacateTrace`).
    vacate_trace: std.ArrayList(VacateTrace) = .empty,
    /// The trace of the cheap transaction in flight, filled at nomination time
    /// and completed with each net's restore outcome once the gate has ruled
    /// (`closeTrace`). Null outside a cheap transaction.
    pending_trace: ?VacateTrace = null,
    /// Hops the wholesale phase asked for, across every transaction. `Tally.tried`
    /// counts the ROUND loop alone, so a call whose rounds planned nothing used to
    /// report `hops_tried: 0` after spending fourteen seconds routing twenty hops
    /// inside a vacate transaction — the tally said "did nothing" while `failed[]`
    /// filled with that phase's diagnoses. Reported separately rather than folded
    /// in, because a vacate hop is not a hop on the caller's own nets.
    vacate_hops: usize = 0,
    /// Whether the hops in flight may put their escape via on their own SMD
    /// terminal pad (see `router.TerminalVia`). Raised only for the duration of
    /// a wholesale transaction: it is what lets a stuck net off a fine-pitch
    /// connector row, and left on for the ordinary rounds it shifts which
    /// copper wins every contested channel and costs a net.
    terminal_via: router.TerminalVia = .banned,
    /// Divisor on the base grid pitch for the hops in flight (see
    /// `router.GapOptions.grid_divisor`). Raised only for the second, finer
    /// rung of a wholesale transaction (see `vacateFor`): the ordinary rounds
    /// stay on the standard gap raster, whose verdicts the whole pass's
    /// baselines were measured on.
    grid_divisor: f64 = router.gap_grid_divisor,

    /// The board's copper as the oracle and the DRC see it right now — ripped
    /// tracks excluded.
    fn copper(self: *Work) std.mem.Allocator.Error!router.RouteResult {
        return (try self.liveCopper()).routes;
    }

    /// The same live copper, plus the index map back into `tracks` a caller
    /// needs when the router hands it rips against this array (see `LiveCopper`).
    fn liveCopper(self: *Work) std.mem.Allocator.Error!LiveCopper {
        var live: std.ArrayList(SavedTrack) = .empty;
        var map: std.ArrayList(usize) = .empty;
        for (self.tracks.items, 0..) |t, i| {
            if (i < self.dead.len and self.dead[i]) continue;
            try live.append(self.alloc, t);
            const count = try savedTrackChordCount(self.alloc, t);
            try map.appendNTimes(self.alloc, i, count);
        }
        const routes = pcb_layout_page.restoreRoutes(self.alloc, .{
            .tracks = live.items,
            .vias = self.vias.items,
            .rf_paths = self.rf_paths,
        }, self.placement.nets) orelse return error.OutOfMemory;
        return .{ .routes = routes, .map = map.items };
    }

    /// Translate rips reported against a live-copper array into `tracks`
    /// indices, and make sure `dead` is long enough to carry the marks: copper
    /// this round has already laid is rippable too, and it sits past the length
    /// `beginRound` allocated.
    fn mapRipped(self: *Work, ripped: []const usize, map: []const usize) std.mem.Allocator.Error![]const usize {
        try self.growDead();
        var out: std.ArrayList(usize) = .empty;
        for (ripped) |i| {
            if (i < map.len and std.mem.indexOfScalar(usize, out.items, map[i]) == null) try out.append(self.alloc, map[i]);
        }
        return out.toOwnedSlice(self.alloc);
    }

    /// Extend the round's rip-mark array to cover every track now on the board.
    fn growDead(self: *Work) std.mem.Allocator.Error!void {
        if (self.dead.len >= self.tracks.items.len) return;
        const grown = try self.alloc.alloc(bool, self.tracks.items.len);
        @memset(grown, false);
        @memcpy(grown[0..self.dead.len], self.dead);
        self.dead = grown;
    }

    /// Open a round: freeze the current track array so rip-up indices are
    /// stable across the round's hops.
    fn beginRound(self: *Work, open: ?[]const fab_readiness.OpenNet) std.mem.Allocator.Error!void {
        self.dead = try self.alloc.alloc(bool, self.tracks.items.len);
        @memset(self.dead, false);
        if (open) |connectivity| try self.setWhole(connectivity) else try self.refreshWhole();
    }

    /// Recompute which nets are in one piece, so the rip filter can answer from
    /// a table instead of a per-call oracle pass.
    fn refreshWhole(self: *Work) std.mem.Allocator.Error!void {
        const r = try self.copper();
        const open = try fab_readiness.openNets(self.alloc, self.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = self.zones,
        });
        try self.setWhole(open);
    }

    /// Use only a snapshot taken before this round, with no intervening copper
    /// changes. Nested vacate rounds rebuild it after removing their victims.
    fn setWhole(self: *Work, open: []const fab_readiness.OpenNet) std.mem.Allocator.Error!void {
        self.whole = try self.alloc.alloc(bool, self.placement.nets.len);
        @memset(self.whole, true);
        for (open) |o| {
            if (netIndex(self.placement, o.net)) |i| self.whole[i] = false;
        }
        self.residual_open = open.len;
        // The residual is already counted here, so the last-K reading costs
        // nothing extra. Round boundary is the right cadence: the rungs should
        // widen as the board closes, and every phase (ordinary rounds, vacate,
        // joint) reaches its hops through `runRound` → `beginRound` → here.
        self.rungs = if (adopt_last_k) gap_policy.lastKRungs(open.len, last_k) else .{};
    }

    /// The rip filter this pass hands the router: a net still in pieces is the
    /// pass's own unfinished work and its copper is not up for grabs (see
    /// `rippedAnOpenNet` for why, and what it cost to learn).
    fn ripFilter(self: *Work) router.RipFilter {
        return .{ .ctx = self, .rippable = rippable };
    }

    fn rippable(ctx: ?*anyopaque, net: i32, routing: i32) bool {
        const self: *Work = @ptrCast(@alignCast(ctx orelse return true));
        if (net < 0) return false;
        const i: usize = @intCast(net);
        if (i >= self.whole.len or !self.whole[i]) return false;
        if (i < self.placement.nets.len) for (self.rf_paths) |path| {
            if (std.mem.eql(u8, path.net, self.placement.nets[i].name)) return false;
        };
        if (routing < 0) return true;
        // A net the design ranks BELOW the one now routing may lose its copper
        // to it. Without this, plan order means nothing once the board is full:
        // the pass can only take copper from nets nobody prioritised, so a
        // high-priority net arriving late finds its corridor held by a lower
        // one and has no way to claim it — measured on board-a, `SPI_SCK`
        // loses 40 overlaps to `SPI_MOSI` copper it outranks in the plan.
        // Declared intent REPLACES a heuristic here: the engine stops guessing
        // who should yield and reads the answer out of the design.
        // `>=`, not `>`: two nets the plan never mentions tie at the bottom and
        // must stay mutually rippable — that is the old behaviour and the
        // common case. What this adds is one prohibition: copper the design
        // ranked ABOVE the net now routing is off limits.
        return self.planRank(i) >= self.planRank(@intCast(routing));
    }

    /// Close a round: physically drop every ripped track.
    fn endRound(self: *Work) std.mem.Allocator.Error!void {
        var kept: std.ArrayList(SavedTrack) = .empty;
        for (self.tracks.items, 0..) |t, i| {
            if (i < self.dead.len and self.dead[i]) continue;
            try kept.append(self.alloc, t);
        }
        self.tracks = kept;
        self.dead = &.{};
    }

    /// Error-severity GEOMETRY violations (see the module header: `net open` is
    /// deliberately not in this list).
    fn geometryErrors(self: *Work) std.mem.Allocator.Error!usize {
        const r = try self.copper();
        const raw = try drc.check(self.alloc, self.placement, r, self.params.clearance);
        var n: usize = 0;
        for (try drc_rules.applyChecked(self.alloc, self.rules, raw)) |v| {
            if (v.severity == .err) n += 1;
        }
        return n;
    }

    fn diffWarnings(self: *Work) std.mem.Allocator.Error!usize {
        const r = try self.copper();
        const raw = try drc.check(self.alloc, self.placement, r, self.params.clearance);
        var n: usize = 0;
        for (try drc_rules.applyChecked(self.alloc, self.rules, raw)) |v| {
            if (v.kind == .diff_uncoupled or v.kind == .diff_skew) n += 1;
        }
        return n;
    }

    /// Every error-severity violation on the board right now.
    fn errorViolations(self: *Work) std.mem.Allocator.Error![]const drc.Violation {
        const r = try self.copper();
        const raw = try drc.check(self.alloc, self.placement, r, self.params.clearance);
        var out: std.ArrayList(drc.Violation) = .empty;
        for (try drc_rules.applyChecked(self.alloc, self.rules, raw)) |v| {
            if (v.severity == .err) try out.append(self.alloc, v);
        }
        return out.items;
    }

    /// The nets whose copper sits at a violation's coordinate — what the
    /// rejected hop actually collided WITH.
    ///
    /// `drc.Violation` carries geometry but no identity, so a report could say
    /// "track↔track, short by 0.23 mm" and leave an agent to reverse-engineer
    /// the other party from coordinates. Naming both nets is the difference
    /// between a measurement and an instruction: it says which net to route
    /// first, or which one to guide elsewhere.
    fn netsAt(self: *Work, x: f64, y: f64, kind: drc.Kind) std.mem.Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const reach = self.params.clearance + self.params.track_width;
        // Tracks carry no drill, so they are never a `hole↔hole` party either.
        if (kind != .hole_hole) {
            for (self.tracks.items) |t| {
                if (segPointDistance(t.x1, t.y1, t.x2, t.y2, x, y) > reach + t.w) continue;
                if (!containsName(out.items, t.net)) try out.append(self.alloc, t.net);
            }
        }
        // …but VIAS do, and for a hole↔hole they are the only real candidates.
        for (self.vias.items) |v| {
            if (std.math.hypot(v.x - x, v.y - y) > reach + v.d) continue;
            if (!containsName(out.items, v.net)) try out.append(self.alloc, v.net);
        }
        // …and the PADS, named as `NET@REF.PIN`. A `track↔pad` finding is the
        // common case and its other party is a pad, not copper — and the hop's
        // own track is rolled back before the report is written, so pads are
        // often the only identity left to give. `REF.PIN` is also what a
        // `(guides (escape-from REF PIN …))` constraint is written against.
        // A `hole↔hole` finding is two DRILLS: an SMD pad has none and cannot be
        // party to it. Naming one anyway is worse than naming nothing — it
        // reads as an identification and sends the reader after an innocent
        // pad. (It sent ME after one: `dsa/U16.17` is SMD, and a whole
        // diagnosis was built on it before this check existed.)
        const drills_only = kind == .hole_hole;
        for (self.placement.nets) |net| {
            for (net.pins) |pin| {
                const part = partWithRef(self.placement, pin.ref_des) orelse continue;
                const pad = padNumbered(part, pin.pin) orelse continue;
                if (drills_only and !pad.thru) continue;
                const sh = pad_shape.worldShape(self.alloc, part, pad) catch continue;
                const cx = (sh.x0 + sh.x1) / 2;
                const cy = (sh.y0 + sh.y1) / 2;
                const hw = (sh.x1 - sh.x0) / 2 + reach;
                const hh = (sh.y1 - sh.y0) / 2 + reach;
                if (@abs(x - cx) > hw or @abs(y - cy) > hh) continue;
                const label = std.fmt.allocPrint(self.alloc, "{s}@{s}.{s}", .{ net.name, pin.ref_des, pin.pin }) catch continue;
                if (!containsName(out.items, label)) try out.append(self.alloc, label);
            }
        }
        return out.items;
    }

    /// The violations NOT present when the pass opened — the bill for the hop
    /// currently being judged. Matched on rule + position so two findings of
    /// the same kind at different places stay distinct.
    fn newViolations(self: *Work) std.mem.Allocator.Error![]const drc.Violation {
        var out: std.ArrayList(drc.Violation) = .empty;
        for (try self.errorViolations()) |v| {
            var seen = false;
            for (self.base_drc) |b| {
                if (b.kind == v.kind and @abs(b.x - v.x) < 1e-6 and @abs(b.y - v.y) < 1e-6) seen = true;
            }
            if (!seen) try out.append(self.alloc, v);
        }
        return out.items;
    }

    /// How many nets the connectivity oracle still finds in pieces.
    fn openNetCount(self: *Work) std.mem.Allocator.Error!usize {
        const r = try self.copper();
        const open = try fab_readiness.openNets(self.alloc, self.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = self.zones,
        });
        return open.len;
    }

    /// How many copper islands `net_i`'s pads currently fall into.
    fn islands(self: *Work, net_i: usize) std.mem.Allocator.Error!usize {
        const r = try self.copper();
        const g = try fab_readiness.buildPhysicalNetGraph(self.alloc, self.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = self.zones,
        }, net_i);
        var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
        for (0..g.n_pads) |i| try seen.put(self.alloc, g.root(i), {});
        return seen.count();
    }

    fn missingBypasses(self: *Work) std.mem.Allocator.Error![]const drc.Violation {
        return drc.checkBypasses(self.alloc, self.placement, (try self.copper()).tracks);
    }

    /// Repair exact surface intent even when a remote plane already closes the net.
    fn repairBypasses(self: *Work) std.mem.Allocator.Error!usize {
        var kept: usize = 0;
        for (try self.missingBypasses()) |target| {
            if (self.budget.stopped()) break;
            const ni: usize = @intCast(target.who.net_a);
            if (!self.wanted(self.placement.nets[ni].name)) continue;
            if (!hasBypass(try self.missingBypasses(), target)) continue;
            const cap = self.placement.parts[@intCast(target.who.part_a)];
            const hub = self.placement.parts[@intCast(target.who.part_b)];
            if (cap.side != hub.side) continue;
            const a = padNumbered(cap, target.who.pad_a) orelse continue;
            const b = padNumbered(hub, target.who.pad_b) orelse continue;
            const ash = try pad_shape.worldShape(self.alloc, cap, a);
            const bsh = try pad_shape.worldShape(self.alloc, hub, b);
            const layer: u8 = if (cap.side == .top) 0 else 1;
            const gap = router.Gap{
                .net_i = ni,
                .from = .{ .x = (ash.x0 + ash.x1) / 2, .y = (ash.y0 + ash.y1) / 2, .layer = layer },
                .to = .{ .x = (bsh.x0 + bsh.x1) / 2, .y = (bsh.y0 + bsh.y1) / 2, .layer = layer },
            };
            self.surface_target = target;
            defer self.surface_target = null;
            const live = try self.liveCopper();
            const paths = try self.closeGaps(.{
                .tracks = live.routes.tracks,
                .vias = live.routes.vias,
                .zones = self.router_zones,
            }, &.{gap}, .{ .ripup = false });
            const path = paths[0] orelse continue;
            try self.refreshWhole();
            if (try self.tryHop(gap, path) == .kept) kept += 1;
        }
        return kept;
    }

    const RoundPlan = struct {
        gaps: []const router.Gap,
        // Full-board connectivity, including nets outside the caller's scope.
        // Shared by planning, the before-count and the initial rip filter.
        open: []const fab_readiness.OpenNet,
    };

    /// Build this round's hop requests and retain their connectivity snapshot.
    fn planRound(self: *Work, round: usize) std.mem.Allocator.Error!RoundPlan {
        const r = try self.copper();
        const open = try fab_readiness.openNets(self.alloc, self.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = self.zones,
        });
        var gaps: std.ArrayList(router.Gap) = .empty;
        var index = std.StringHashMapUnmanaged(usize).empty;
        for (self.placement.parts, 0..) |p, i| try index.put(self.alloc, p.ref_des, i);
        for (open) |o| {
            if (!self.wanted(o.net)) continue;
            try self.planNetHops(&gaps, &index, o, round);
            if (gaps.items.len >= max_hops_per_round) break;
        }
        std.mem.sort(router.Gap, gaps.items, self, hardestFirst);
        return .{ .gaps = gaps.items, .open = open };
    }

    /// A fixed via allowance may be smaller than the number of plane islands.
    /// Try joining those islands on their existing face before spending barrels.
    /// Later rounds retain ordinary stitching and multilayer bridge fallbacks.
    fn planNetHops(
        self: *Work,
        gaps: *std.ArrayList(router.Gap),
        index: *std.StringHashMapUnmanaged(usize),
        o: fab_readiness.OpenNet,
        round: usize,
    ) std.mem.Allocator.Error!void {
        const net_i = netIndex(self.placement, o.net) orelse return;
        const plane = self.planeCarried(o.net);
        const before = gaps.items.len;
        if (plane) try self.addStitches(gaps, index, o, net_i);
        const stitches = gaps.items.len - before;
        if (round == 0 and plane) {
            if (self.remainingViaLimit(net_i)) |limit| if (stitches > limit) {
                var joins: std.ArrayList(router.Gap) = .empty;
                for (o.gaps) |g| {
                    const from = padPoint(self.placement, index, g.from) orelse continue;
                    const to = padPoint(self.placement, index, g.to) orelse continue;
                    var gap = router.Gap{ .net_i = net_i, .from = from, .to = to, .surface_only = true };
                    if (from.layer != to.layer) {
                        gap = self.alternateBridge(index, o, g, net_i) orelse continue;
                        gap.surface_only = true;
                    }
                    if (!self.deadEnd(gap)) try joins.append(self.alloc, gap);
                }
                if (joins.items.len > 0) {
                    gaps.shrinkRetainingCapacity(before);
                    try gaps.appendSlice(self.alloc, joins.items);
                    return;
                }
            };
        }
        if (bridgesNow(round, plane, stitches)) try self.addBridges(gaps, index, o, net_i);
    }

    /// Order one round's hops hardest-first. Every hop in a round contends for
    /// the same corridors, and each one that lands takes its corridor out of
    /// circulation for the rest of the round — so the order is a scheduling
    /// decision, not a cosmetic one. Nearest-first (the oracle's own order) is
    /// exactly backwards under congestion: the 1 mm bridges, which fit almost
    /// anywhere, spend the channels that a 30 mm cross-board hop has only one
    /// of, and the long hop then reports `blocked` against copper that had a
    /// dozen other places to go.
    ///
    /// SPAN is the proxy for "how constrained": a longer hop crosses more of the
    /// board and so meets more of what is already on it. Plane STITCHES have no
    /// far terminal and sort last — a stitch is a via plus a stub beside its own
    /// pad, so it never consumes a corridor a bridge could have used.
    fn hardestFirst(ctx: *Work, a: router.Gap, b: router.Gap) bool {
        // Declared intent first: a net the author placed in an early wave claims
        // its corridor before an unplanned one, exactly as the whole-board pass
        // treats it. Span breaks ties — still the right rule among peers, since
        // a long hop has the fewest alternative corridors.
        const ra = ctx.planRank(a.net_i);
        const rb = ctx.planRank(b.net_i);
        if (ra != rb) return ra < rb;
        return hopSpan(a) > hopSpan(b);
    }

    /// Where a net sits in the plan's route order; unplanned nets sort last.
    fn planRank(self: *Work, net_i: usize) usize {
        if (net_i >= self.plan.rank.len) return std.math.maxInt(usize);
        return self.plan.rank[net_i];
    }

    /// A hop's straight-line span in mm; 0 for a plane stitch (no far terminal).
    fn hopSpan(gap: router.Gap) f64 {
        const to = gap.to orelse return 0;
        return std.math.hypot(to.x - gap.from.x, to.y - gap.from.y);
    }

    /// Is this net in the caller's `nets` restriction (empty = every net)?
    fn wanted(self: *Work, net_name: []const u8) bool {
        if (self.only.len == 0) return true;
        for (self.only) |n| {
            if (std.mem.eql(u8, n, net_name)) return true;
        }
        return false;
    }

    /// A net whose pads are joined by a plane or by one of its own retained
    /// pours rejoins by dropping a via into that copper, not by a surface trace
    /// to its twin (which between two QFN ground pads is usually impossible).
    fn planeCarried(self: *Work, net_name: []const u8) bool {
        if (fab_readiness.netHasPlane(self.placement, net_name)) return true;
        for (self.zones) |z| {
            if (std.mem.eql(u8, z.net, net_name)) return true;
        }
        return false;
    }

    /// One stitch request per copper island of an open net — the island's first
    /// stitchable pad is where the via goes. The island the plane/pour already
    /// carries gets NO stitch: its via would land in copper the island is
    /// already part of, so the hop can only come back `no_merge` — the wasted
    /// round and the misleading failure this used to report on every open
    /// pour-carried net. A pad the dead-end memo has ruled out does not seal
    /// its whole island either: the island's next pad is asked instead (an
    /// island's first pad can sit in foreign congestion no via site survives
    /// while a later pad has a legal barrel at its own centre — board-a's
    /// `V_3V3_LMX` {U17.37, C93.1}).
    fn addStitches(
        self: *Work,
        gaps: *std.ArrayList(router.Gap),
        index: *std.StringHashMapUnmanaged(usize),
        o: fab_readiness.OpenNet,
        net_i: usize,
    ) std.mem.Allocator.Error!void {
        var done: std.AutoHashMapUnmanaged(usize, void) = .empty;
        for (o.pads) |p| {
            if (p.island < o.plane_joined.len and o.plane_joined[p.island]) continue;
            if (done.contains(p.island)) continue;
            const pt = padPoint(self.placement, index, p) orelse continue;
            const gap = router.Gap{ .net_i = net_i, .from = pt };
            if (self.deadEnd(gap)) continue;
            try done.put(self.alloc, p.island, {});
            try gaps.append(self.alloc, gap);
        }
    }

    /// The oracle's nearest-first island-joining hops as maze bridges.
    fn addBridges(
        self: *Work,
        gaps: *std.ArrayList(router.Gap),
        index: *std.StringHashMapUnmanaged(usize),
        o: fab_readiness.OpenNet,
        net_i: usize,
    ) std.mem.Allocator.Error!void {
        for (o.gaps) |g| {
            const from = padPoint(self.placement, index, g.from) orelse continue;
            const to = padPoint(self.placement, index, g.to) orelse continue;
            const gap = router.Gap{ .net_i = net_i, .from = from, .to = to };
            const chosen = if (self.deadEnd(gap))
                self.alternateBridge(index, o, g, net_i) orelse continue
            else
                gap;
            try gaps.append(self.alloc, chosen);
        }
    }

    /// A failed pad pair does not make its two copper islands unreachable.
    /// In particular, nearest XY pads can be on opposite faces while another
    /// pad already on the start island offers a surface-only bridge (the DSA
    /// select connection on Barracuda). Try one nearest untried surface pair
    /// per round, retaining the same island join and the ordinary accept gate.
    fn alternateBridge(
        self: *Work,
        index: *std.StringHashMapUnmanaged(usize),
        open: fab_readiness.OpenNet,
        join: fab_readiness.OpenGap,
        net_i: usize,
    ) ?router.Gap {
        var best: ?router.Gap = null;
        var best_span = std.math.inf(f64);
        for (open.pads) |a| {
            if (a.island != join.from.island) continue;
            const from = padPoint(self.placement, index, a) orelse continue;
            for (open.pads) |b| {
                if (b.island != join.to.island) continue;
                const shares_face = a.side == b.side or a.thru or b.thru;
                if (!shares_face) continue;
                const to = padPoint(self.placement, index, b) orelse continue;
                const gap = router.Gap{ .net_i = net_i, .from = from, .to = to };
                const span = hopSpan(gap);
                if (span >= best_span or self.deadEnd(gap)) continue;
                best = gap;
                best_span = span;
            }
        }
        return best;
    }

    /// Remaining new-via allowance for each net, shared by every finishing
    /// rung. All retained vias spend the authored total, including earlier calls.
    fn remainingPolicies(self: *Work) std.mem.Allocator.Error![]const route_policy.NetPolicy {
        const policies = try self.alloc.dupe(route_policy.NetPolicy, self.plan.net);
        for (policies, 0..) |*policy, ni| policy.max_vias = self.remainingViaLimit(ni);
        return policies;
    }

    fn remainingViaLimit(self: *Work, net_i: usize) ?u16 {
        if (net_i >= self.plan.net.len) return null;
        const limit = self.plan.net[net_i].max_vias orelse return null;
        if (net_i >= self.placement.nets.len) return limit;
        var present: u16 = 0;
        for (self.vias.items) |via| if (std.mem.eql(u8, via.net, self.placement.nets[net_i].name)) {
            present +|= 1;
        };
        return limit -| present;
    }

    /// Every round, retry and collateral repair uses the same authored hard
    /// policy. Keep this at the gap-call seam so a new rung cannot omit it.
    fn closeGaps(
        self: *Work,
        board: router.GapBoard,
        gaps: []const router.Gap,
        opts: router.GapOptions,
    ) std.mem.Allocator.Error![]const ?router.GapPath {
        if (self.budget.stopped()) {
            const skipped = try self.alloc.alloc(?router.GapPath, gaps.len);
            @memset(skipped, null);
            return skipped;
        }
        var options = opts;
        options.raster.stop = self.budget.restrict(options.raster.stop);
        var policies = try self.remainingPolicies();
        if (self.surface_target) |target| {
            const surface = try self.alloc.alloc(route_policy.NetPolicy, self.placement.nets.len);
            for (surface, 0..) |*slot, i| slot.* = if (i < policies.len) policies[i] else .{};
            const ni: usize = @intCast(target.who.net_a);
            const layer: u8 = if (self.placement.parts[@intCast(target.who.part_a)].side == .top) 0 else 1;
            const mask = @as(u64, 1) << @intCast(layer);
            if (surface[ni].allowed_layers != 0 and surface[ni].allowed_layers & mask == 0) {
                const refused = try self.alloc.alloc(?router.GapPath, gaps.len);
                @memset(refused, null);
                return refused;
            }
            surface[ni].allowed_layers = mask;
            surface[ni].max_vias = 0;
            policies = surface;
            options.ripup = false;
        }
        options.constraints.net = policies;
        var view = board;
        view.reserved_lanes = self.plan.reserved;
        const result = try router.closeGaps(self.alloc, self.placement, self.params, view, gaps, options);
        _ = self.budget.stopped();
        return result;
    }

    /// Route one round's hops and keep the ones that earn their copper.
    fn runRound(self: *Work, gaps: []const router.Gap, open: ?[]const fab_readiness.OpenNet) std.mem.Allocator.Error!RoundResult {
        if (self.budget.stopped()) return .{};
        try self.beginRound(open);
        const live = try self.liveCopper();
        const base = live.routes;
        const reasons = try self.alloc.alloc(router.GapReason, gaps.len);
        @memset(reasons, .routed);
        // The accept gate runs INSIDE the batch (see `router.GapJudge`), so the
        // copper the rest of the round routes against is the copper this pass
        // actually keeps — a hop the gate rolls back must not go on blocking
        // the hops behind it.
        const verdicts = try self.alloc.alloc(?Verdict, gaps.len);
        @memset(verdicts, null);
        var watch = HopWatch{
            .work = self,
            .gaps = gaps,
            .map = live.map,
            .last_ms = clock.milliTimestamp(),
            .reasons = reasons,
            .verdicts = verdicts,
        };
        const paths = try self.closeGaps(.{
            .tracks = base.tracks,
            .vias = base.vias,
            .zones = self.router_zones,
        }, gaps, .{
            .sink = .{ .ctx = &watch, .emit = HopWatch.emit },
            .judge = .{ .ctx = &watch, .keep = HopWatch.keep },
            .rip_filter = self.ripFilter(),
            .constraints = .{ .terminal_via = self.terminal_via },
            .raster = .{ .divisor = self.grid_divisor },
        });
        var kept = RoundResult{ .tried = watch.tried };
        for (gaps, paths, reasons, verdicts) |gap, maybe, why, judged| {
            const path = maybe orelse {
                if (self.budget.stopped()) continue;
                const bridge_fine = endgameBridgeFine(self.residual_open, gap, why);
                const global_detour = globalDetourEligible(
                    self.residual_open,
                    self.global_detour_spent,
                    gap,
                    why,
                );
                if (gap.to == null or bridge_fine) {
                    if (global_detour) self.global_detour_spent += 1;
                    const rescued = try self.fineDirect(gap, global_detour);
                    if (rescued == .kept) {
                        kept.hops += 1;
                        continue;
                    }
                }
                if (self.budget.stopped()) continue;
                kept.no_path += 1;
                try self.note(gap, .no_path, why);
                continue;
            };
            var verdict = judged orelse .no_path;
            var ripped = path.ripped.len;
            if (verdict == .broke_victim and !self.budget.stopped()) {
                const wider = try self.escalateRip(gap);
                verdict = wider.verdict;
                ripped = wider.ripped;
            }
            if (verdict != .kept and !self.budget.stopped()) {
                // The last rung's verdict is the reported one even when it
                // fails: it is the attempt that had the most board to work
                // with, so its DRC is what a caller should aim `add_tracks` at.
                const global_detour = globalDetourForRejected(
                    self.residual_open,
                    self.global_detour_spent,
                    gap,
                );
                if (global_detour) self.global_detour_spent += 1;
                verdict = try self.fineDirect(gap, global_detour);
                ripped = 0;
            }
            if (verdict == .no_path and self.budget.stopped()) continue;
            if (verdict == .kept) {
                kept.hops += 1;
                kept.ripped += ripped;
            } else {
                kept.rejected += 1;
                if (verdict == .diff_pair) kept.pair_rejected += 1;
                try self.note(gap, verdict, why);
            }
        }
        try self.endRound();
        return kept;
    }

    /// A hop the gate rejected *only* because the copper it ripped could not be
    /// repaired is not a dead end — the rip was too SMALL. Re-ask for the same
    /// hop one rung further up the router's rip ladder (a higher rung clears the
    /// aggressor outright, which is what lets its repair take a genuinely
    /// different route) until the repair holds or the ladder runs out at
    /// `max_rip_tier`.
    ///
    /// The retry routes against the copper the board carries RIGHT NOW, not the
    /// array the round opened with. Routing it against the stale array was a
    /// quiet defect: every hop this round had already landed was invisible to
    /// the retry, so the maze happily drew through occupied channels and the
    /// gate threw the result out as a DRC rise — a rejection that says nothing
    /// about whether the wider rip was the right idea. `LiveCopper.map` is what
    /// makes the live array usable: the rips come back as indices into it and
    /// have to be translated before they can mark `tracks`.
    fn escalateRip(self: *Work, gap: router.Gap) std.mem.Allocator.Error!Escalation {
        var tier: usize = 1;
        var judged: []const usize = &.{};
        const top = ripTierCapFor(wideArmed(self.rungs, self.wide_spent));
        while (tier < top) : (tier += 1) {
            if (self.budget.stopped()) break;
            // Exactly one rung sits above the fixed cap, so this charges the
            // hop once for the sweep it is about to buy.
            if (tier >= max_rip_tier) self.wide_spent += 1;
            const live = try self.liveCopper();
            const paths = try self.closeGaps(.{
                .tracks = live.routes.tracks,
                .vias = live.routes.vias,
                .zones = self.router_zones,
            }, &.{gap}, .{
                .rip_from = tier,
                .rip_filter = self.ripFilter(),
                .constraints = .{ .terminal_via = self.terminal_via },
                .raster = .{ .divisor = self.grid_divisor },
            });
            const raw = paths[0] orelse continue;
            const path = router.GapPath{
                .tracks = raw.tracks,
                .vias = raw.vias,
                .ripped = try self.mapRipped(raw.ripped, live.map),
                .ripped_nets = raw.ripped_nets,
            };
            // The ladder saturates: once a victim has no further segments near
            // the terminals, every remaining rung clears the same tracks, so the
            // maze returns the same copper and the gate would re-derive the same
            // verdict — at the price of another whole-net repair and two oracle
            // passes, which is where a `broke_victim` hop spends most of its time.
            if (tier > 1 and std.mem.eql(usize, judged, path.ripped)) continue;
            judged = path.ripped;
            const verdict = try self.tryHop(gap, path);
            progress("  retry {s} at rip tier {d}: {s}", .{
                self.placement.nets[gap.net_i].name,
                tier,
                @tagName(verdict),
            });
            if (verdict != .broke_victim) return .{ .verdict = verdict, .ripped = path.ripped.len };
        }
        return .{ .verdict = .broke_victim, .ripped = 0 };
    }

    /// Last rung for a hop every rip tier refused: the same hop on the finer
    /// `vacate_fine_divisor` raster with **no rip at all**.
    ///
    /// A hop that keeps failing as `broke_victim` / `drc` is not asking for a
    /// bigger rip — it is asking for a route that does not need one, and the
    /// standard raster cannot see it. Measured on board-a's `SPI_SCK`: the
    /// divisor-2 lattice offers only a ~24 mm line that has to tear
    /// `adf4159/SPI_ADF_SDI_1V8` out and cannot put it back, while a legal
    /// ~35 mm way round exists and costs nothing to anyone. Rip is off on
    /// purpose — this rung's whole premise is that the shorter, destructive
    /// path was the wrong answer.
    fn fineDirect(self: *Work, gap: router.Gap, global_detour: bool) std.mem.Allocator.Error!Verdict {
        // Two rungs, both bounded to the hop's own corridor. The coarser one
        // first: it is cheaper and closes most lattice failures. A long,
        // exhausted endgame bridge then gets ONE board-wide divisor-4 search,
        // which can see a perimeter corridor outside this rectangle. Divisor 8
        // stays corridor-bounded: board-wide it is prohibitively large.
        for (fine_divisors, 0..) |divisor, i| {
            if (self.budget.stopped()) break;
            const verdict = try self.fineDirectAt(gap, divisor);
            if (verdict == .kept) return verdict;
            if (i == 0 and global_detour) {
                const boundary = try self.fineBoundaryAt(gap, divisor);
                if (boundary == .kept) return boundary;
                const global = try self.fineGlobalAt(gap, divisor);
                if (global == .kept) return global;
            }
            if (divisor == fine_divisors[fine_divisors.len - 1]) return verdict;
        }
        return .no_path;
    }

    /// One corridor-bounded re-ask of `gap` at `divisor`× the base pitch.
    fn fineDirectAt(self: *Work, gap: router.Gap, divisor: f64) std.mem.Allocator.Error!Verdict {
        if (self.budget.stopped()) return .no_path;
        const live = try self.liveCopper();
        const paths = try self.closeGaps(
            .{ .tracks = live.routes.tracks, .vias = live.routes.vias, .zones = self.router_zones },
            &.{gap},
            fineDirectOptions(gap, divisor),
        );
        const path = paths[0] orelse return .no_path;
        const verdict = try self.tryHop(gap, path);
        progress("  retry {s} in its corridor on the divisor-{d} grid, no rip: {s}", .{
            self.placement.nets[gap.net_i].name,
            divisor,
            @tagName(verdict),
        });
        return verdict;
    }

    /// One board-wide fine re-ask for a long endgame bridge. This is the global
    /// corridor rung: no rip, exact SMD terminal escapes enabled, and capped by
    /// `global_detour_spenders` before it reaches here.
    fn fineGlobalAt(self: *Work, gap: router.Gap, divisor: f64) std.mem.Allocator.Error!Verdict {
        if (self.budget.stopped()) return .no_path;
        const live = try self.liveCopper();
        const paths = try self.closeGaps(
            .{ .tracks = live.routes.tracks, .vias = live.routes.vias, .zones = self.router_zones },
            &.{gap},
            fineGlobalOptions(divisor),
        );
        const path = paths[0] orelse return .no_path;
        const verdict = try self.tryHop(gap, path);
        progress("  retry {s} globally on the divisor-{d} grid, no rip: {s}", .{
            self.placement.nets[gap.net_i].name,
            divisor,
            @tagName(verdict),
        });
        return verdict;
    }

    /// Guide an endgame bridge around each board edge in turn. Each trial
    /// is three ordinary gap legs (terminal → edge, along edge, edge → terminal)
    /// routed as one batch, then combined and judged as ONE transaction. The
    /// synthetic waypoints are topology hints, never persisted constraints or
    /// hard-coded board coordinates; the placement bounds generate them.
    fn fineBoundaryAt(self: *Work, gap: router.Gap, divisor: f64) std.mem.Allocator.Error!Verdict {
        const to = gap.to orelse return .no_path;
        const candidates = boundaryDetours(self.placement, gap);
        for (candidates, 0..) |candidate, edge| {
            if (self.budget.stopped()) break;
            const live = try self.liveCopper();
            const legs = [_]router.Gap{
                .{ .net_i = gap.net_i, .from = gap.from, .to = candidate.first, .surface_only = gap.surface_only },
                .{ .net_i = gap.net_i, .from = candidate.first, .to = candidate.second, .surface_only = gap.surface_only },
                .{ .net_i = gap.net_i, .from = candidate.second, .to = to, .surface_only = gap.surface_only },
            };
            const paths = try self.closeGaps(
                .{ .tracks = live.routes.tracks, .vias = live.routes.vias, .zones = self.router_zones },
                &legs,
                fineBoundaryOptions(candidate.window, divisor),
            );
            var tracks: std.ArrayList(router.Track) = .empty;
            var vias: std.ArrayList(router.Via) = .empty;
            var complete = true;
            for (paths) |maybe| {
                const path = maybe orelse {
                    complete = false;
                    break;
                };
                try tracks.appendSlice(self.alloc, path.tracks);
                try vias.appendSlice(self.alloc, path.vias);
            }
            if (!complete) continue;
            const verdict = try self.tryHop(gap, .{ .tracks = tracks.items, .vias = vias.items });
            progress("  retry {s} via boundary corridor {d} on divisor-{d}: {s}", .{
                self.placement.nets[gap.net_i].name,
                edge,
                divisor,
                @tagName(verdict),
            });
            if (verdict == .kept) return verdict;
        }
        return .no_path;
    }

    /// What the last rungs ask for, split out so it can be stated as a fact: a
    /// finer raster BOUNDED TO THE HOP'S CORRIDOR, an escape via allowed on an
    /// SMD terminal, and NO rip.
    fn fineDirectOptions(gap: router.Gap, divisor: f64) router.GapOptions {
        return .{
            .ripup = false,
            .constraints = .{ .terminal_via = .smd_ok },
            .raster = .{
                .divisor = divisor,
                .window = router.GapWindow.around(gap, fine_corridor_margin_mm),
                .expansion_multiplier = fine_expansion_multiplier,
            },
        };
    }

    fn fineGlobalOptions(divisor: f64) router.GapOptions {
        return .{
            .ripup = false,
            .constraints = .{ .terminal_via = .smd_ok },
            .raster = .{ .divisor = divisor, .expansion_multiplier = fine_expansion_multiplier },
        };
    }

    fn fineBoundaryOptions(window: router.GapWindow, divisor: f64) router.GapOptions {
        return .{
            .ripup = false,
            .constraints = .{ .terminal_via = .smd_ok },
            .raster = .{
                .divisor = divisor,
                .window = window,
                // Three guided legs have a much smaller frontier than the
                // unconstrained global retry; normal effort keeps the four
                // board-edge candidates bounded in wall time.
                .expansion_multiplier = 1,
            },
        };
    }

    /// Record why one hop did not land, so the caller sees WHICH net is stuck
    /// and on what — the whole point of a finishing tool is that the residue is
    /// diagnosable. Capped, newest dropped, so a huge board can't flood.
    ///
    /// The hop also joins the dead-end memo: a later round replans from the same
    /// oracle and would re-request the identical hop, and re-running a 35-second
    /// blocked search to reach the same answer is the single biggest waste in a
    /// multi-round pass. Only a rip-up shrinks the board, so `runRound`'s caller
    /// clears the memo exactly when a round ripped something.
    fn note(self: *Work, gap: router.Gap, verdict: Verdict, why: router.GapReason) std.mem.Allocator.Error!void {
        try self.dead_ends.append(self.alloc, hopKey(gap));
        if (self.failures.items.len >= max_reported_failures) return;
        try self.failures.append(self.alloc, .{
            .net = self.placement.nets[gap.net_i].name,
            .bridge = gap.to != null,
            .x = gap.from.x,
            .y = gap.from.y,
            .verdict = verdict,
            .phase = self.phase,
            .why = why,
            .drc_new = if (verdict == .drc) self.last_drc else &.{},
        });
    }

    /// Has this exact hop already been tried and failed since the last rip?
    fn deadEnd(self: *Work, gap: router.Gap) bool {
        const key = hopKey(gap);
        for (self.dead_ends.items) |k| {
            if (k.eql(key)) return true;
        }
        return false;
    }

    /// Apply one hop as a TRANSACTION and keep it only if it earns its copper:
    /// the hop's own net must lose an island, EVERY net the transaction ripped
    /// copper out of must end no worse than it started (their repairs run inside
    /// this same transaction, and a repair may rip in turn — see
    /// `max_repair_rip_depth`), and the geometric error count must not rise.
    /// Anything else rolls every byte back — the copper, the repairs, and every
    /// rip the cascade made.
    fn tryHop(self: *Work, gap: router.Gap, path: router.GapPath) std.mem.Allocator.Error!Verdict {
        try self.growDead();
        const before_islands = try self.islands(gap.net_i);
        const before_bypasses = try self.missingBypasses();
        const mark_tracks = self.tracks.items.len;
        const mark_vias = self.vias.items.len;
        self.victims.clearRetainingCapacity();
        self.victim_queue.clearRetainingCapacity();
        self.ripped_marks.clearRetainingCapacity();
        var kept = false;
        defer if (!kept) {
            self.tracks.shrinkRetainingCapacity(mark_tracks);
            self.vias.shrinkRetainingCapacity(mark_vias);
            for (self.ripped_marks.items) |i| {
                if (i < self.dead.len) self.dead[i] = false;
            }
        };
        try self.noteVictims(path.ripped_nets, path.ripped.len, 0);
        // Nothing has been applied yet, so an unrippable victim costs only the
        // island counts already taken.
        if (self.rippedAnOpenNet()) return .broke_victim;
        try self.applyHop(gap.net_i, path);
        // Added copper can split a retained pour without ripping one byte of
        // that net's routed copper. Treat every net that was whole at the round
        // boundary and is open now as a transaction victim, so the same repair
        // and rollback guarantees cover geometric pour clipping too.
        try self.noteCollateralVictims(gap.net_i, 0);
        try self.repairVictims();
        if (newBypassMissing(before_bypasses, try self.missingBypasses())) return .bypass;
        const verdict = try self.judge(gap.net_i, before_islands);
        kept = verdict == .kept;
        return verdict;
    }

    /// Remember every net a rip is about to take copper from, and how many rips
    /// deep the cascade is. MUST be called before the rip is applied: the island
    /// count recorded here is the "no worse than you found it" bar the accept
    /// gate holds each net to.
    fn noteVictims(self: *Work, nets: []const i32, ripped: usize, depth: usize) std.mem.Allocator.Error!void {
        if (ripped == 0) return;
        for (nets) |n| try self.noteVictim(n, depth);
    }

    /// Record one victim's pre-rip island count (see `noteVictims`).
    fn noteVictim(self: *Work, ripped_net: i32, depth: usize) std.mem.Allocator.Error!void {
        if (ripped_net < 0) return;
        const v: usize = @intCast(ripped_net);
        if (v >= self.placement.nets.len) return;
        const slot = try self.victims.getOrPut(self.alloc, v);
        if (slot.found_existing) return;
        slot.value_ptr.* = try self.islands(v);
        try self.victim_queue.append(self.alloc, .{ .net_i = v, .depth = depth });
    }

    /// Discover connectivity victims created by ADDING copper. A foreign track
    /// can cut a narrow retained pour into two islands even when the router
    /// ripped no track belonging to that net, so `path.ripped_nets` alone is not
    /// a complete victim ledger. `whole` is the pre-hop round snapshot: a net
    /// already open then is the caller's unfinished work, never collateral.
    fn noteCollateralVictims(self: *Work, routing_net: usize, depth: usize) std.mem.Allocator.Error!void {
        const r = try self.copper();
        const open = try fab_readiness.openNets(self.alloc, self.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = self.zones,
        });
        for (open) |o| {
            const net_i = netIndex(self.placement, o.net) orelse continue;
            if (net_i == routing_net or net_i >= self.whole.len or !self.whole[net_i]) continue;
            const slot = try self.victims.getOrPut(self.alloc, net_i);
            if (slot.found_existing) continue;
            slot.value_ptr.* = 1;
            try self.victim_queue.append(self.alloc, .{ .net_i = net_i, .depth = depth });
        }
    }

    /// Is any net this transaction wants to rip ALREADY OPEN?
    ///
    /// The accept gate's promise about a victim is "no worse than I found it",
    /// and on a whole net that reads as "still in one piece". On a net that is
    /// already in two pieces it reads as almost nothing: the rip may throw away
    /// a half-finished route, lay a completely different one somewhere else,
    /// and still come back at two islands — same count, different board. The
    /// pass then hands the corridor the victim was one hop from using to
    /// somebody else, and the victim never closes. (Measured: letting hops rip
    /// the still-open `SPI_MOSI` and `V_12V` cost board-a two closed nets,
    /// 85/90 → 83/90, with every per-net island count "not worse".)
    ///
    /// So a rip may only take copper from a net that is currently WHOLE. An
    /// open net's copper belongs to the pass's own unfinished work.
    fn rippedAnOpenNet(self: *Work) bool {
        var it = self.victims.valueIterator();
        while (it.next()) |before| {
            if (before.* != 1) return true;
        }
        return false;
    }

    /// Re-close every net this transaction has broken. The queue grows as
    /// repairs rip in turn, so this is a breadth-first cascade bounded by
    /// `max_transaction_victims`; hitting the bound leaves the tail unrepaired,
    /// and the accept gate then rejects the whole transaction.
    fn repairVictims(self: *Work) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < self.victim_queue.items.len and i < max_transaction_victims) : (i += 1) {
            if (self.budget.stopped()) break;
            const task = self.victim_queue.items[i];
            try self.repairNet(task.net_i, task.depth);
        }
    }

    /// The three ways an applied hop can fail to earn its copper, in the order
    /// worth reporting: it did not merge the net, it left a net whose copper it
    /// ripped worse off, or it added a geometry DRC error.
    fn judge(self: *Work, net_i: usize, before: usize) std.mem.Allocator.Error!Verdict {
        const after = try self.islands(net_i);
        if (self.surface_target) |target| {
            if (after > before or hasBypass(try self.missingBypasses(), target)) return .no_merge;
        } else if (after >= before) return .no_merge;
        // The cascade can nominate a victim of its own after `tryHop`'s early
        // check, so the rule is re-asserted here where every victim is known.
        if (self.rippedAnOpenNet()) return .broke_victim;
        var it = self.victims.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == net_i) continue;
            if ((try self.islands(e.key_ptr.*)) > e.value_ptr.*) return .broke_victim;
        }
        const errors = try self.geometryErrors();
        if (errors > self.errorCap()) {
            self.last_drc = try self.newViolations();
            return .drc;
        }
        const diff_warnings = try self.diffWarnings();
        if (diff_warnings > self.diff_ceiling) return .diff_pair;
        // This hop is being kept, so the board it leaves behind is the one the
        // next hop is measured against (see `error_ceiling`).
        self.error_ceiling = errors;
        self.diff_ceiling = diff_warnings;
        return .kept;
    }

    /// The most error-severity geometry violations a hop may leave behind: the
    /// ratcheted ceiling, or the caller's absolute budget where that is higher
    /// (see `error_budget` — the budget only ever relaxes the gate), or the
    /// wholesale phase's floor (see `phase_floor`).
    fn errorCap(self: *const Work) usize {
        const declared = @max(self.error_budget orelse 0, self.phase_floor orelse 0);
        return @max(self.error_ceiling, declared);
    }

    /// Re-close a net whose copper a hop just ripped, so "rip-up and reorder"
    /// means the blocked net routes FIRST and its aggressor routes around the
    /// result — not that the aggressor is left broken. Below
    /// `max_repair_rip_depth` the repair may rip in turn, and whatever it rips
    /// joins the same transaction's victim queue; at the depth bound it must
    /// find a path through standing copper or fail. Either way its copper lands
    /// in the transaction `tryHop` accepts or discards as a whole.
    fn repairNet(self: *Work, net_i: usize, depth: usize) std.mem.Allocator.Error!void {
        if (self.budget.stopped()) return;
        const gaps = try self.repairGaps(net_i);
        if (gaps.len == 0) return;
        const rip = depth < repairRipDepthFor(wideArmed(self.rungs, self.wide_spent));
        var watch = RepairWatch{ .net = self.placement.nets[net_i].name };
        const live = try self.liveCopper();
        const paths = try self.closeGaps(.{
            .tracks = live.routes.tracks,
            .vias = live.routes.vias,
            .zones = self.router_zones,
        }, gaps, .{
            .ripup = rip,
            .sink = .{ .ctx = &watch, .emit = RepairWatch.emit },
            .rip_filter = self.ripFilter(),
            .constraints = .{ .terminal_via = self.terminal_via },
            .raster = .{ .divisor = self.grid_divisor },
        });
        var landed: usize = 0;
        for (gaps, paths) |gap, maybe| {
            var chosen = maybe;
            if (chosen == null and !self.budget.stopped()) {
                // Collateral repairs get the same bounded local fine rung as a
                // top-level endgame hop. Board A's pour island is a 1.868 mm
                // lattice miss: standard repair exhausts, divisor 4 closes it
                // in its own corridor without rip or board-wide search.
                const fine_live = try self.liveCopper();
                const fine = try self.closeGaps(
                    .{ .tracks = fine_live.routes.tracks, .vias = fine_live.routes.vias, .zones = self.router_zones },
                    &.{gap},
                    fineDirectOptions(gap, vacate_fine_divisor),
                );
                chosen = fine[0];
                progress("    repair {s} retry in its corridor on divisor-{d}: {s}", .{
                    self.placement.nets[net_i].name,
                    vacate_fine_divisor,
                    if (chosen != null) "routed" else "no path",
                });
            }
            const p = chosen orelse continue;
            const ripped = try self.mapRipped(p.ripped, live.map);
            if (ripped.len > 0 and !rip) continue;
            try self.noteVictims(p.ripped_nets, ripped.len, depth + 1);
            try self.applyHop(net_i, .{
                .tracks = p.tracks,
                .vias = p.vias,
                .ripped = ripped,
                .ripped_nets = p.ripped_nets,
            });
            try self.noteCollateralVictims(net_i, depth + 1);
            landed += 1;
        }
        progress("  repair {s} (depth {d}): {d}/{d} hops re-routed", .{
            self.placement.nets[net_i].name,
            depth,
            landed,
            gaps.len,
        });
    }

    /// The hops that would re-close `net_i` on the board as it stands.
    fn repairGaps(self: *Work, net_i: usize) std.mem.Allocator.Error![]const router.Gap {
        const r = try self.copper();
        const open = try fab_readiness.openNets(self.alloc, self.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = self.zones,
        });
        var index = std.StringHashMapUnmanaged(usize).empty;
        for (self.placement.parts, 0..) |p, i| try index.put(self.alloc, p.ref_des, i);
        var gaps: std.ArrayList(router.Gap) = .empty;
        for (open) |o| {
            if (netIndex(self.placement, o.net) != net_i) continue;
            if (self.planeCarried(o.net)) try self.addStitches(&gaps, &index, o, net_i);
            try self.addBridges(&gaps, &index, o, net_i);
        }
        return gaps.items;
    }

    /// Append a hop's copper and mark the tracks it ripped, recording each mark
    /// so `tryHop` can undo the WHOLE cascade and not just its first rip.
    /// Reserve all storage before changing any copper or rip mark. Later
    /// validation failures are rolled back by the enclosing transaction.
    fn applyHop(self: *Work, net_i: usize, path: router.GapPath) std.mem.Allocator.Error!void {
        try self.ripped_marks.ensureUnusedCapacity(self.alloc, path.ripped.len);
        try self.tracks.ensureUnusedCapacity(self.alloc, path.tracks.len);
        try self.vias.ensureUnusedCapacity(self.alloc, path.vias.len);
        const net_name = self.placement.nets[net_i].name;
        for (path.ripped) |i| {
            if (i >= self.dead.len or self.dead[i]) continue;
            // Record BEFORE marking: a mark the ledger missed is a rip the
            // rollback would leave standing.
            self.ripped_marks.appendAssumeCapacity(i);
            self.dead[i] = true;
        }
        for (path.tracks) |t| self.tracks.appendAssumeCapacity(.{
            .x1 = t.x1,
            .y1 = t.y1,
            .x2 = t.x2,
            .y2 = t.y2,
            .l = t.layer,
            .w = t.width,
            .net = net_name,
            .source = pcb_layout_page.route_source_autorouter,
        });
        for (path.vias) |v| self.vias.appendAssumeCapacity(.{
            .x = v.x,
            .y = v.y,
            .d = v.dia,
            .drill = v.drill,
            .net = net_name,
            .source = pcb_layout_page.route_source_autorouter,
        });
    }

    // ── Wholesale re-route: vacate the corridor ─────────────────────────────
    //
    // Everything above bridges GAPS: it puts new metal between two islands and,
    // at most, rips the copper immediately sealing a pad's escape — then repairs
    // the victim, which re-routes it through essentially the same channel it
    // just left. That is why a handful of nets survive every round: they are not
    // losing a race against the pass's own copper (giving them first pick of the
    // board closes none of them), they are walled in by copper that was already
    // on the board when the pass started and that no local rip restructures.
    //
    // This phase is the missing move. For one still-open SEED it takes the seed
    // AND the whole nets whose copper crosses the corridor it needs completely
    // off the board, routes the seed FIRST across the vacated channel, then puts
    // the displaced nets back AROUND the result. That is "rip up and reorder" at
    // whole-net granularity, and it is the only thing here that can make an
    // already-closed net take a different shape.
    //
    // It is a strict all-or-nothing transaction per seed: the seed must close,
    // every displaced net must come back whole (a still-open net that was not
    // open before is an instant rollback — the phase can never trade one net for
    // another), and the geometry error count may not rise. Otherwise the board
    // is restored byte-for-byte. Guarded copper — planes, pours, ground,
    // `(max-freq …)` RF, diff-pair members — is never stripped.

    /// Every via as `via_merge` sees it: the spacing it owes another barrel of
    /// its own net, and whether its position is somebody else's statement.
    fn mergeSites(self: *Work) std.mem.Allocator.Error![]const via_merge.ViaPt {
        const design = self.placement.rules.design;
        const out = try self.alloc.alloc(via_merge.ViaPt, self.vias.items.len);
        for (self.vias.items, out) |v, *o| {
            const ni: i32 = if (netIndex(self.placement, v.net)) |i| @intCast(i) else -1;
            const clr = self.placement.rules.clearanceForNet(ni, self.params.clearance);
            o.* = .{
                .x = v.x,
                .y = v.y,
                .r = v.d / 2,
                .net = v.net,
                .rule = if (design.via_to_via > 0) design.via_to_via else clr,
                .pinned = v.f.len > 0 or v.g.len > 0,
            };
        }
        return out;
    }

    /// Re-anchor every track end sitting on `from` onto `to` (within the
    /// endpoint tolerance the router emits copper at), dropping whatever
    /// becomes degenerate. Returns how many ends moved.
    fn reanchor(self: *Work, from: SavedVia, to: SavedVia) usize {
        var moved: usize = 0;
        for (self.tracks.items) |*t| {
            if (!std.mem.eql(u8, t.net, from.net)) continue;
            if (std.math.hypot(t.x1 - from.x, t.y1 - from.y) <= via_fold_snap_mm) {
                t.x1 = to.x;
                t.y1 = to.y;
                moved += 1;
            }
            if (std.math.hypot(t.x2 - from.x, t.y2 - from.y) <= via_fold_snap_mm) {
                t.x2 = to.x;
                t.y2 = to.y;
                moved += 1;
            }
        }
        return moved;
    }

    /// The index of the via at `p` on `net`, or null once it has been folded
    /// away. Coordinates, not indices: a fold shrinks the list under us.
    fn viaAtPoint(self: *Work, p: via_merge.ViaPt) ?usize {
        for (self.vias.items, 0..) |v, i| {
            if (!std.mem.eql(u8, v.net, p.net)) continue;
            if (std.math.hypot(v.x - p.x, v.y - p.y) <= via_fold_snap_mm) return i;
        }
        return null;
    }

    /// Apply ONE fold as its own transaction: re-anchor the dropped barrel's
    /// track ends onto the survivor, delete it, and keep the result only if the
    /// board did not get worse. Returns false (board restored byte-for-byte)
    /// otherwise.
    ///
    /// Per fold, not per batch, because re-anchoring moves a track END by up to
    /// the spacing rule plus a via diameter — real geometry, which one board in
    /// some corner may not accept. Batching them would let a single refusal
    /// throw away every good fold beside it.
    fn applyOneFold(self: *Work, keep: via_merge.ViaPt, drop: via_merge.ViaPt) std.mem.Allocator.Error!bool {
        const ki = self.viaAtPoint(keep) orelse return false;
        const di = self.viaAtPoint(drop) orelse return false;
        if (ki == di) return false;
        const save_t = try dupeList(SavedTrack, self.alloc, self.tracks.items);
        const save_v = try dupeList(SavedVia, self.alloc, self.vias.items);
        const open_before = try self.openNetCount();
        const errs_before = try self.geometryErrors();

        _ = self.reanchor(self.vias.items[di], self.vias.items[ki]);
        _ = self.vias.orderedRemove(di);
        var kept_t: std.ArrayList(SavedTrack) = .empty;
        for (self.tracks.items) |t| {
            if (std.math.hypot(t.x2 - t.x1, t.y2 - t.y1) > via_fold_snap_mm) try kept_t.append(self.alloc, t);
        }
        self.tracks = kept_t;
        if ((try self.geometryErrors()) <= errs_before and (try self.openNetCount()) <= open_before) return true;
        self.tracks = save_t;
        self.vias = save_v;
        return false;
    }

    /// Fold every redundant same-net via onto the barrel already there, so the
    /// board carries one drill per layer change instead of two (see
    /// `placement/via_merge.zig`). Returns how many barrels went.
    fn foldRedundantVias(self: *Work) std.mem.Allocator.Error!usize {
        try self.endRound(); // measure and rewrite LIVE copper, never a ripped tail
        const folds = try via_merge.plan(self.alloc, try self.mergeSites());
        if (folds.len == 0) return 0;
        const sites = try self.mergeSites();
        var done: usize = 0;
        var refused: usize = 0;
        for (folds) |f| {
            if (self.budget.stopped()) break;
            if (try self.applyOneFold(sites[f.keep], sites[f.drop])) done += 1 else refused += 1;
        }
        progress("via fold: reused {d} same-net via(s), {d} refused", .{ done, refused });
        return done;
    }

    /// Run the shared post-route topology gate over the board the finisher is
    /// about to persist. Scoped calls may clean only the nets they were asked
    /// to change; unscoped calls clean every net. Via deletion is rechecked by
    /// the connectivity oracle inside the gate, so a barrel that is actually
    /// carrying a layer transition survives.
    fn pruneArtifacts(self: *Work) std.mem.Allocator.Error!ArtifactPrune {
        try self.endRound();
        const before = try self.copper();
        var selected: []bool = &.{};
        if (self.only.len > 0) {
            selected = try self.alloc.alloc(bool, self.placement.nets.len);
            @memset(selected, false);
            for (self.only) |name| {
                if (netIndex(self.placement, name)) |ni| selected[ni] = true;
            }
        }
        const cleaned = try route_plan.pruneTopologyArtifacts(self.alloc, self.placement, self.params, before, .{
            .existing_zones = self.router_zones,
            .selected_nets = selected,
        });
        const saved = try pcb_layout_page.mcpSavedRoutesFrom(
            self.alloc,
            cleaned,
            self.placement.nets,
            .{ .tracks = self.tracks.items, .vias = self.vias.items },
        );
        self.tracks = try dupeList(SavedTrack, self.alloc, saved.tracks);
        self.vias = try dupeList(SavedVia, self.alloc, saved.vias);
        const removed = ArtifactPrune{
            .tracks = before.tracks.len -| cleaned.tracks.len,
            .vias = before.vias.len -| cleaned.vias.len,
        };
        if (removed.tracks > 0 or removed.vias > 0) progress(
            "artifact cleanup: pruned {d} loose track(s), {d} redundant via(s)",
            .{ removed.tracks, removed.vias },
        );
        return removed;
    }

    /// Run the wholesale phase over the nets still open, seed by seed. Returns
    /// how many seeds it closed. A no-op (no strip, no route) on a board with
    /// nothing open, so a clean board leaves this function untouched.
    fn vacatePhase(self: *Work) std.mem.Allocator.Error!usize {
        var closed: usize = 0;
        var attempts: usize = 0;
        while (attempts < max_vacate_seeds) : (attempts += 1) {
            if (self.budget.stopped()) break;
            const seed = try self.nextVacateSeed() orelse break;
            try self.vacate_tried.append(self.alloc, seed);
            const name = self.placement.nets[seed].name;
            progress("vacate {s}: wholesale re-route", .{name});
            const won = try self.vacateFor(seed);
            progress("vacate {s}: {s}", .{ name, if (won) "closed" else "rolled back" });
            if (won) closed += 1;
        }
        return closed;
    }

    /// The next still-open net the phase has not tried yet, in the oracle's own
    /// order. Re-read after every transaction, because closing one seed changes
    /// which nets are open and which copper is whole enough to displace.
    fn nextVacateSeed(self: *Work) std.mem.Allocator.Error!?usize {
        for (try self.openNetNames()) |n| {
            if (!self.wanted(n)) continue;
            const net_i = netIndex(self.placement, n) orelse continue;
            if (containsIndex(self.vacate_tried.items, net_i)) continue;
            return net_i;
        }
        return null;
    }

    /// One seed's wholesale re-route: an all-or-nothing transaction at the
    /// standard gap grid (see the section header), then — when that changed
    /// nothing — one more on the finer `vacate_fine_divisor` raster, and
    /// finally the same two rungs again on the CHEAP-RESTORE tier. True when
    /// the board some rung left is kept.
    ///
    /// The cheap tier is last on purpose. It costs nothing on a board the rungs
    /// above already closed, and it is the only rung that will displace copper a
    /// pour carries (see `vacate_policy`) — the category the standard tier
    /// refuses outright, and the one a human operator reaches for first. It
    /// repeats the grid ladder because a lattice that cannot represent the lane
    /// and a corridor that is simply occupied are different failures, and a
    /// walled-in seed can be suffering both.
    fn vacateFor(self: *Work, seed: usize) std.mem.Allocator.Error!bool {
        if (try self.vacateAt(seed, router.gap_grid_divisor, .standard)) return true;
        if (self.budget.stopped()) return false;
        progress("vacate {s}: retrying on the divisor-{d} grid", .{
            self.placement.nets[seed].name,
            vacate_fine_divisor,
        });
        if (try self.vacateAt(seed, vacate_fine_divisor, .standard)) return true;
        if (self.budget.stopped()) return false;
        progress("vacate {s}: retrying with cheap-to-restore neighbours", .{
            self.placement.nets[seed].name,
        });
        if (try self.vacateAt(seed, router.gap_grid_divisor, .cheap)) return true;
        return self.vacateAt(seed, vacate_fine_divisor, .cheap);
    }

    /// One rung of `vacateFor`'s grid ladder, as an all-or-nothing transaction.
    ///
    /// The finer rung is also the one allowed to run BARE — no displaceable
    /// blockers at all, subset = the seed alone — because the failure it exists
    /// for is a lattice with no legal lane, not copper in the way: board-a's
    /// J1 escapes contend for a corridor that stays unroutable at divisor 2
    /// with every competing net stripped off the board. At the standard rung a
    /// blocker-less seed is still a bail-out: nothing about the board would
    /// differ from the rounds that already failed it.
    fn vacateAt(self: *Work, seed: usize, divisor: f64, tier: Tier) std.mem.Allocator.Error!bool {
        if (self.budget.stopped()) return false;
        // A bare run — no displaceable blockers, subset = the seed alone —
        // reproduces the rounds that already failed unless the raster changed,
        // and on the cheap tier it is never useful at all: the standard tier
        // has run both rasters bare by the time this one is reached.
        const bare_ok = divisor > router.gap_grid_divisor and tier == .standard;
        const before_open = try self.openNetNames();
        const before_errors = try self.geometryErrors();
        const before_diff = self.diff_ceiling;
        if (try self.seedIslands(seed) > max_vacate_seed_islands) return false;
        // `whole` is what tells a blocker apart from the pass's own unfinished
        // work, and the last round left it as it was when THAT round opened.
        try self.refreshWhole();
        const blockers = try self.corridorBlockers(seed, tier);
        if (blockers.len == 0 and !bare_ok) return false; // nothing to displace — no new move to make
        // The seed always heads the ROUTING order (it is the net the corridor is
        // being vacated for), but it only joins the STRIP set when its own
        // copper is ours to move: a plane- or pour-carried seed like `GND` keeps
        // every via it has and simply gets first pick of the freed channel.
        const subset = try self.vacateSubset(seed, blockers);
        const save_t = try dupeList(SavedTrack, self.alloc, self.tracks.items);
        const save_v = try dupeList(SavedVia, self.alloc, self.vias.items);
        try self.stripNets(if (self.movable(seed)) subset else subset[1..]);
        // Every hop the pass refused earlier was refused against copper that is
        // no longer there — or against a coarser raster — so the memo it built
        // is stale by construction.
        self.dead_ends.clearRetainingCapacity();
        self.phase_floor = before_errors;
        // The standard tier raises the escape posture because its seed is
        // physically sealed and needs a way off a fine-pitch row. The cheap
        // tier's seed is not: what closes it is the VACANCY, and its own
        // documented cost — "left on for the ordinary rounds it shifts which
        // copper wins every contested channel and costs a net" — falls on the
        // displaced nets it is trying to put back unchanged. So the restore runs
        // at the ordinary posture.
        self.terminal_via = if (tier == .cheap) .banned else .smd_ok;
        self.grid_divisor = divisor;
        // Everything from here to the restore is the transaction's own work, on
        // nets the caller never named and against a board with whole nets
        // deliberately missing. Label it at source so the caller's `failed[]`
        // stays the round loop's answer (see `Phase`).
        self.phase = .vacate;
        const marked = self.failures.items.len;
        // TWO rounds, because `bridgesNow` splits a plane-carried net's stitch
        // from its bridges across rounds: round 0 asks every displaced pour net
        // to rejoin through its own pour, and round 1 asks for a surface route
        // only from whatever that left open. One round could only ever have both
        // at once, which is the ordering mistake this phase used to make.
        for (0..vacate_rounds) |round| {
            if (self.budget.stopped()) break;
            const hops = try self.planFor(subset, 1, round);
            if (hops.len == 0) break;
            self.vacate_hops += (try self.runRound(hops, null)).tried;
        }
        self.phase = .round;
        self.grid_divisor = router.gap_grid_divisor;
        self.terminal_via = .banned;
        self.phase_floor = null;
        if (try self.vacateWon(before_open, before_errors)) {
            self.error_ceiling = try self.geometryErrors();
            self.diff_ceiling = try self.diffWarnings();
            try self.closeTrace(tier, true);
            return true;
        }
        try self.closeTrace(tier, false);
        self.tracks = save_t;
        self.vias = save_v;
        self.dead = &.{};
        self.error_ceiling = before_errors;
        self.diff_ceiling = before_diff;
        // The board this transaction diagnosed has just been restored
        // byte-for-byte, so its findings are history, not the state of the
        // board the caller is holding. Say so rather than dropping them: "the
        // seed's blockers could not all come back" is exactly why the seed is
        // still open.
        for (self.failures.items[marked..]) |*f| f.rolled_back = true;
        return false;
    }

    /// One transaction's ROUTING order: the seed, then the nets walling its
    /// corridors in. Putting the seed at the head is the whole point — it gets
    /// first pick of the channel its blockers just left. `vacateFor` decides
    /// separately whether the seed's own copper is stripped.
    fn vacateSubset(self: *Work, seed: usize, blockers: []const usize) std.mem.Allocator.Error![]const usize {
        var out: std.ArrayList(usize) = .empty;
        try out.append(self.alloc, seed);
        try out.appendSlice(self.alloc, blockers);
        return out.items;
    }

    // ── Joint transactions: vacate ONE corridor for SEVERAL seeds ───────────
    //
    // Everything above is single-seed. `vacatePhase` takes the open nets one at
    // a time and each transaction restores the other seeds' copper before the
    // next one runs — so N nets contending for ONE corridor cannot be solved by
    // ANY sequence of single-seed vacates. Whichever of them goes first takes
    // the channel, the rest are put back exactly where they were, and the next
    // transaction re-asks the identical question against the identical board.
    // That is the shape of board-a's residual: six SPI lines wanting one J1
    // escape corridor, and a sealed LDO pocket whose rails and `GND` island want
    // the same bottom-layer channel.
    //
    // A joint transaction is the missing move. It forms a CLUSTER of still-open
    // seeds that provably contend — their nomination tables share copper — takes
    // the UNION of what stands in all their ways off the board in one strip, and
    // re-closes the whole set together. Because a maze is first-claim-wins, WHO
    // goes first is then the entire question, so the cluster is re-routed under
    // several orders (`JointOrder`) and the best outcome wins. This is the axis
    // the in-route `joint_rescue.zig` tier already has and this one lacked; the
    // nomination both tiers ask is now literally the same code
    // (`blocker_nomination.zig`).
    //
    // The guarantees are the single-seed tier's, unchanged. All-or-nothing per
    // attempt: strictly fewer open nets, no net that was closed left open, no
    // rise in geometry errors — else the board is restored byte-for-byte,
    // dead-end memo included. Guarded copper (planes, pours as SEEDS, ground,
    // `(max-freq …)` RF, diff-pair members) is never stripped, because the same
    // `vacate_policy` judges the union. And every bound is a COUNT: seeds per
    // cluster, blockers per transaction, copper per transaction, clusters per
    // call, and one whole-pass attempt cap over all of it.
    //
    // MEASURED on board-a (2026-08-06, ReleaseSafe, from-zero `route_pcb` at
    // the starred poses — 80/91 — then `close_open_nets` to a fixed point, A/B
    // against main with this tier absent):
    //
    //   * fixed point 84/91 -> **85/91**, reached in TWO calls instead of three
    //     (total wall 677 s -> 435 s) at an unchanged DRC error count of 1.
    //   * the FIRST call alone goes 83/91 -> 85/91, on two clusters that both
    //     close: `SPI_SCK + GND + V_3V3A` over six blockers takes 8 open nets to
    //     7, then `V_12V + adf4159/SPI_ADF_CSN_1V8 + adf4159/SPI_ADF_SDI_1V8`
    //     over two takes 7 to 6. `SPI_SCK` is the net no sequence of single-seed
    //     transactions closes — the audit's six-SPI-in-one-J1-corridor case.
    //   * that call costs 1.27x the single-seed one (238 s vs 187 s); the whole
    //     LADDER is cheaper because it needs one call fewer.
    //   * the next call's cluster is refused on every order and both rasters —
    //     one attempt took 6 open nets to 8 and was rolled back on the spot,
    //     which is the gate working rather than the tier failing.
    //
    // The three orders did NOT discriminate on this board: every accepted
    // attempt landed on the same open count, so `seeds_first` won each tie and
    // the other two were paid for and discarded. They stay because the cost is
    // bounded and the axis is real — a maze is first-claim-wins, and the
    // in-route tier measures orders mattering there — but if a wall-time budget
    // ever has to give, this is the first thing to cut, and the numbers above
    // say what cutting it would cost.

    /// Run the joint tier over whatever the single-seed pass left open. Returns
    /// how many nets it closed. A no-op — no nomination, no strip, no route — on
    /// a board with fewer than two open nets, so a clean board and a
    /// single-residual board both leave this function untouched.
    fn jointPhase(self: *Work) std.mem.Allocator.Error!usize {
        var budget = JointBudget{};
        var closed: usize = 0;
        var spent: std.ArrayList(usize) = .empty;
        while (budget.takeCluster()) {
            if (self.budget.stopped()) break;
            const cluster = try self.nextJointCluster(spent.items) orelse break;
            try spent.appendSlice(self.alloc, cluster);
            const before = (try self.openNetNames()).len;
            if (!try self.jointVacate(cluster, &budget)) continue;
            closed += before - (try self.openNetNames()).len;
        }
        return closed;
    }

    /// The next cluster of still-open seeds that contend for the same copper, or
    /// null when no two of them do.
    ///
    /// Contention is measured, not guessed: each candidate seed's corridors are
    /// swept into its own nomination table, and two seeds are in one cluster when
    /// their tables share a net — or when one seed's own copper stands in the
    /// other's corridor, which is contention in its purest form. Seeds are taken
    /// in the oracle's order and the first group of two or more wins, so the
    /// clustering is deterministic; a seed already spent on a cluster is not
    /// offered again, because nothing about the board changed for it.
    fn nextJointCluster(
        self: *Work,
        spent: []const usize,
    ) std.mem.Allocator.Error!?[]const usize {
        // ONE board read for the whole scan. Both halves of it — rebuilding the
        // live copper and running the connectivity oracle — are full sweeps over
        // the board, and a cluster scan asks about every open net; taking them
        // per seed would pay for them a dozen times over to learn the same thing.
        const view = try self.boardView() orelse return null;
        var seeds: std.ArrayList(usize) = .empty;
        for (view.open) |o| {
            if (!self.wanted(o.net)) continue;
            const net_i = netIndex(self.placement, o.net) orelse continue;
            if (containsIndex(spent, net_i)) continue;
            // The same "nearly whole and walled in" bound the single-seed tier
            // uses: a net in a dozen pieces is a different problem, and its
            // transaction has to re-ask every one of those hops.
            if (o.islands > max_vacate_seed_islands) continue;
            try seeds.append(self.alloc, net_i);
        }
        if (seeds.items.len < 2) return null;
        const tables = try self.alloc.alloc(nomination.Table, seeds.items.len);
        for (seeds.items, tables) |s, *t| {
            t.* = .{};
            try self.nominate(t, s, view);
        }
        for (seeds.items, 0..) |a, i| {
            var group: std.ArrayList(usize) = .empty;
            try group.append(self.alloc, a);
            for (seeds.items[i + 1 ..], tables[i + 1 ..]) |b, tb| {
                if (group.items.len >= max_joint_seeds) break;
                if (!contended(tables[i], tb, a, b)) continue;
                try group.append(self.alloc, b);
            }
            if (group.items.len > 1) return group.items;
        }
        return null;
    }

    /// One cluster's whole transaction: nominate the union, strip it, re-close
    /// under each order at each raster, and keep the best strictly-better board.
    /// Every losing attempt — and a cluster that never wins at all — leaves the
    /// board it started from, copper for copper and memo for memo.
    fn jointVacate(
        self: *Work,
        seeds: []const usize,
        budget: *JointBudget,
    ) std.mem.Allocator.Error!bool {
        const before_open = try self.openNetNames();
        const before_errors = try self.geometryErrors();
        // `whole` is what tells a blocker apart from the pass's own unfinished
        // work, and the last transaction left it as it was when THAT one opened.
        try self.refreshWhole();
        const blockers = try self.jointBlockers(seeds);
        if (blockers.len == 0) return false;
        progress("joint {s}: {d} seed(s), {d} blocker(s)", .{
            try self.seedLabel(seeds),
            seeds.len,
            blockers.len,
        });
        const strip = try self.jointStripSet(seeds, blockers);
        const save = try self.snapshot();
        const marked = self.failures.items.len;
        var best: ?Snapshot = null;
        var best_open = before_open.len;
        for (joint_rasters) |divisor| {
            if (self.budget.stopped()) break;
            for (joint_orders) |o| {
                if (self.budget.stopped()) break;
                if (!budget.takeAttempt()) break;
                const seq = try self.jointSequence(o, seeds, blockers);
                try self.runJointTransaction(strip, seq, divisor, before_errors);
                const after = (try self.openNetNames()).len;
                const won = try self.vacateWon(before_open, before_errors);
                progress("  joint order {s} raster {d}: open {d} -> {d}, {s}", .{
                    @tagName(o), divisor, before_open.len, after, if (won) "kept" else "rolled back",
                });
                if (won and after < best_open) {
                    best_open = after;
                    best = try self.snapshot();
                }
                try self.restore(save);
            }
            // A rung that closed something is the answer; the finer raster costs
            // three more full transactions to maybe tie it.
            if (best != null) break;
        }
        if (best) |b| {
            try self.restore(b);
            self.error_ceiling = try self.geometryErrors();
            try self.closeTrace(.cheap, true);
            return true;
        }
        try self.closeTrace(.cheap, false);
        // Same rule as the single-seed rollback: the findings describe a board
        // that has just been restored byte-for-byte, so say so rather than drop
        // them — "the cluster's blockers could not all come back" is exactly why
        // these nets are still open.
        for (self.failures.items[marked..]) |*f| f.rolled_back = true;
        return false;
    }

    /// The union of what stands in the cluster's way, judged and capped as ONE
    /// transaction by `vacate_policy.selectMany` (see `cheapNets`). Always the
    /// cheap tier: the standard tier's nominations have already been tried,
    /// seed by seed and on both rasters, by the time a cluster forms — what a
    /// joint transaction adds is jointness and order, plus the one category the
    /// standard tier refuses outright, the copper a pour underwrites.
    fn jointBlockers(self: *Work, seeds: []const usize) std.mem.Allocator.Error![]const usize {
        const view = try self.boardView() orelse return &.{};
        var table = nomination.Table{};
        for (seeds) |s| try self.nominate(&table, s, view);
        return self.cheapNets(try table.ranked(self.alloc), seeds);
    }

    /// The copper a joint transaction takes off the board: every blocker, plus
    /// each seed whose OWN copper is ours to move. A plane- or pour-carried seed
    /// (`GND`) keeps every via it has and simply gets first pick of the freed
    /// channel — the single-seed rule (`vacateAt`), applied per member.
    fn jointStripSet(
        self: *Work,
        seeds: []const usize,
        blockers: []const usize,
    ) std.mem.Allocator.Error![]const usize {
        var out: std.ArrayList(usize) = .empty;
        for (seeds) |s| {
            if (self.movable(s)) try out.append(self.alloc, s);
        }
        try out.appendSlice(self.alloc, blockers);
        return out.items;
    }

    /// One order's routing sequence for a cluster (see `JointOrder`), as the
    /// `nets`/`lead` pair `planFor` takes.
    fn jointSequence(
        self: *Work,
        o: JointOrder,
        seeds: []const usize,
        blockers: []const usize,
    ) std.mem.Allocator.Error!Sequence {
        var out: std.ArrayList(usize) = .empty;
        if (o == .seeds_last) {
            try out.appendSlice(self.alloc, blockers);
            try out.appendSlice(self.alloc, seeds);
        } else {
            try out.appendSlice(self.alloc, seeds);
            try out.appendSlice(self.alloc, blockers);
        }
        return .{ .nets = out.items, .lead = switch (o) {
            .seeds_first => seeds.len,
            .contended => 0,
            .seeds_last => blockers.len,
        } };
    }

    /// One joint attempt: strip the subset, then re-close it in `seq`'s order
    /// over the phase's two rounds (stitches, then bridges). The caller owns the
    /// snapshot, the accept gate and the restore — this only lays copper.
    fn runJointTransaction(
        self: *Work,
        strip: []const usize,
        seq: Sequence,
        divisor: f64,
        floor: usize,
    ) std.mem.Allocator.Error!void {
        try self.stripNets(strip);
        // Every hop the pass refused earlier was refused against copper that is
        // no longer there — or against a coarser raster — so the memo it built
        // is stale by construction.
        self.dead_ends.clearRetainingCapacity();
        self.phase_floor = floor;
        self.grid_divisor = divisor;
        // Label the churn at source, so the caller's `failed[]` stays the round
        // loop's answer (see `Phase`).
        self.phase = .vacate;
        for (0..vacate_rounds) |round| {
            if (self.budget.stopped()) break;
            const hops = try self.planFor(seq.nets, seq.lead, round);
            if (hops.len == 0) break;
            self.vacate_hops += (try self.runRound(hops, null)).tried;
        }
        self.phase = .round;
        self.grid_divisor = router.gap_grid_divisor;
        self.phase_floor = null;
    }

    /// The board as a joint attempt must be able to put it back.
    fn snapshot(self: *Work) std.mem.Allocator.Error!Snapshot {
        return .{
            .tracks = try dupeList(SavedTrack, self.alloc, self.tracks.items),
            .vias = try dupeList(SavedVia, self.alloc, self.vias.items),
            .dead_ends = try dupeList(HopKey, self.alloc, self.dead_ends.items),
            .error_ceiling = self.error_ceiling,
            .diff_ceiling = self.diff_ceiling,
        };
    }

    /// Put `s` back, copper and memo alike.
    ///
    /// The MEMO is the half the single-seed tier never restored, and a
    /// multi-order tier cannot leave it out: a transaction clears the dead-end
    /// memo as its first act (the copper those hops were refused against is
    /// gone), so without this the second order would be asked on a different
    /// board than the first and the orders would not be comparable — nor the
    /// pass reproducible.
    fn restore(self: *Work, s: Snapshot) std.mem.Allocator.Error!void {
        self.tracks = try dupeList(SavedTrack, self.alloc, s.tracks.items);
        self.vias = try dupeList(SavedVia, self.alloc, s.vias.items);
        self.dead_ends = try dupeList(HopKey, self.alloc, s.dead_ends.items);
        self.dead = &.{};
        self.error_ceiling = s.error_ceiling;
        self.diff_ceiling = s.diff_ceiling;
    }

    /// Did the transaction earn the board it left behind? Three ways to fail,
    /// and the middle one is the important one: comparing open COUNTS alone lets
    /// a transaction close two nets while breaking one and read as progress, so
    /// the rule is on the SET — every net still open must have been open before.
    fn vacateWon(self: *Work, before: []const []const u8, before_errors: usize) std.mem.Allocator.Error!bool {
        const after = try self.openNetNames();
        if (after.len >= before.len) return false;
        for (after) |a| {
            if (!containsName(before, a)) return false;
        }
        return (try self.geometryErrors()) <= before_errors;
    }

    /// May the phase take `net_i`'s copper off the board and re-route it? Only
    /// plain signal / rail copper: a plane or pour net is reference copper the
    /// finishing pass must not restructure, and an RF `(max-freq …)` net or a
    /// diff-pair member carries geometry that was placed deliberately.
    fn movable(self: *Work, net_i: usize) bool {
        if (net_i >= self.placement.nets.len) return false;
        const name = self.placement.nets[net_i].name;
        if (self.planeCarried(name)) return false;
        if (optimizer.isGroundName(leafName(name))) return false;
        for (self.placement.diff_pairs) |p| {
            if (p.p == net_i or p.n == net_i) return false;
        }
        if (net_i >= self.placement.rules.net.len) return true;
        const r = self.placement.rules.net[net_i];
        return r.rf.max_freq_hz <= 0 and r.diff_gap < 0;
    }

    /// The nets whose copper crosses a corridor `seed` still has to reach
    /// through — the copper that is actually in the way.
    ///
    /// On the `.standard` tier a blocker must be MOVABLE (see `movable`) and
    /// currently WHOLE, and the nearest `max_vacate_blockers` win. On the
    /// `.cheap` tier the same corridor sweep collects every foreign net in the
    /// way and `vacate_policy` decides, ranking by how cheap each is to put
    /// back rather than by how close it lies — which is what lets a pour-carried
    /// rail in.
    fn corridorBlockers(self: *Work, seed: usize, tier: Tier) std.mem.Allocator.Error![]const usize {
        const view = try self.boardView() orelse return &.{};
        var table = nomination.Table{};
        try self.nominate(&table, seed, view);
        const ranked = try table.ranked(self.alloc);
        if (tier == .standard) return self.closestNets(ranked);
        const seeds = [_]usize{seed};
        return self.cheapNets(ranked, &seeds);
    }

    /// Raise `table` over every island-joining corridor `seed` still needs, by
    /// the ONE nomination both rip-and-re-route tiers ask
    /// (`blocker_nomination.sweepHops`).
    ///
    /// ADDITIVE, deliberately: called once it is a single seed's candidate set,
    /// called over several seeds it is the UNION a joint transaction vacates —
    /// same code, same ranking, no second path.
    ///
    /// The sweep is VIA-AWARE here and track-only in the in-route tier, and that
    /// asymmetry is the point of the shared seam rather than a hole in it. The
    /// in-route tier probes (`router.detectBlockers`), and a probe already
    /// reports every net whose via barrels sit on the victim's own path. This
    /// tier cannot probe at all — the router's `Ctx` is built and dropped inside
    /// each `router.closeGaps` call, so there is no live occupancy grid to walk
    /// after the route — and with a track-only sweep a channel sealed by a via
    /// field nominated NOBODY, which is the "via-blind" half of the audit's
    /// finding. Geometry is this tier's only sense; it now uses all of it.
    fn nominate(
        self: *Work,
        table: *nomination.Table,
        seed: usize,
        view: BoardView,
    ) std.mem.Allocator.Error!void {
        const name = self.placement.nets[seed].name;
        for (view.open) |o| {
            if (!std.mem.eql(u8, o.net, name)) continue;
            var hops: std.ArrayList(nomination.Hop) = .empty;
            for (o.gaps, 0..) |g, i| {
                if (i >= max_vacate_corridors) break;
                try hops.append(self.alloc, .{
                    .ax = g.from.x,
                    .ay = g.from.y,
                    .bx = g.to.x,
                    .by = g.to.y,
                });
            }
            try nomination.sweepHops(table, self.alloc, .{
                .net_i = seed,
                .hops = hops.items,
                .tracks = view.routes.tracks,
                .vias = view.routes.vias,
                .radius_mm = vacate_corridor_mm,
                .via_policy = .tracks_and_vias,
            });
        }
    }

    /// The `.cheap` tier's nomination: turn the ranked corridor sweep into
    /// `vacate_policy.NetFacts`, let the policy judge and rank them, and record
    /// the whole decision — picks and refusals both — for the caller's trace.
    ///
    /// `seeds` is a slice, not one index, because the SAME judgement serves a
    /// joint transaction: `vacate_policy.selectMany` refuses every member as
    /// `.seed` and measures the priority guard against the highest-ranked one.
    /// A cluster also gets the wider caps — it is one transaction serving
    /// several corridors, so bounding it like a single seed's would starve it.
    fn cheapNets(
        self: *Work,
        ranked: []const nomination.Candidate,
        seeds: []const usize,
    ) std.mem.Allocator.Error![]const usize {
        var facts: std.ArrayList(vacate_policy.NetFacts) = .empty;
        for (ranked) |c| try facts.append(self.alloc, self.netFacts(c.net_i, c.dist));
        // `ranked` is nearest-first; the policy's own ranking breaks every tie on
        // net index, but sorting the INPUT by index keeps the refusal list stable
        // too, and that list is reported.
        std.mem.sort(vacate_policy.NetFacts, facts.items, {}, factsByIndex);
        var keys: std.ArrayList(vacate_policy.Seed) = .empty;
        for (seeds) |s| try keys.append(self.alloc, .{ .net_i = s, .priority = self.netPriority(s) });
        const decision = try vacate_policy.selectMany(
            self.alloc,
            facts.items,
            keys.items,
            if (seeds.len > 1)
                .{ .max_nets = max_joint_blockers, .max_total_elements = max_joint_elements }
            else
                .{},
        );
        var out: std.ArrayList(usize) = .empty;
        var picks: std.ArrayList(VacatePick) = .empty;
        for (decision.picked) |p| {
            try out.append(self.alloc, p.net_i);
            try picks.append(self.alloc, .{
                .net = self.placement.nets[p.net_i].name,
                .kind = p.kind,
                .before = p.elements,
            });
        }
        var refused: std.ArrayList(VacateRefusal) = .empty;
        for (decision.refused) |x| {
            try refused.append(self.alloc, .{ .net = self.placement.nets[x.net_i].name, .why = x.why });
        }
        self.pending_trace = .{
            .seed = try self.seedLabel(seeds),
            .picked = picks.items,
            .refused = refused.items,
        };
        return out.items;
    }

    /// The transaction's seed as the caller's trace names it: one net's name, or
    /// a cluster's names joined with " + ". One string keeps the reported
    /// `vacated[].seed` field one string whether the transaction had one seed or
    /// three — an agent reading it learns the cluster without a schema change.
    fn seedLabel(self: *Work, seeds: []const usize) std.mem.Allocator.Error![]const u8 {
        if (seeds.len == 1) return self.placement.nets[seeds[0]].name;
        var out: std.ArrayList(u8) = .empty;
        for (seeds, 0..) |s, i| {
            if (i > 0) try out.appendSlice(self.alloc, " + ");
            try out.appendSlice(self.alloc, self.placement.nets[s].name);
        }
        return out.items;
    }

    /// One candidate net as the policy sees it (see `vacate_policy.NetFacts`).
    fn netFacts(self: *Work, net_i: usize, dist: f64) vacate_policy.NetFacts {
        const name = self.placement.nets[net_i].name;
        return .{
            .net_i = net_i,
            .protected = .{
                .ground = optimizer.isGroundName(leafName(name)),
                // This tier re-routes a displaced net with an ordinary maze
                // walk, so a declared pair is protected outright — the coupled
                // construction is not part of its restore.
                .diff_pair = if (self.inDiffPair(net_i)) .protected else .none,
                .rf = self.netRf(net_i),
                .fenced = self.fenced(name),
            },
            .pour_carried = self.planeCarried(name),
            .whole = net_i < self.whole.len and self.whole[net_i],
            .rank = .{ .priority = self.netPriority(net_i) },
            .elements = self.netElements(name),
            .dist = dist,
        };
    }

    /// Is `net_i` a resolved `(diff-pair …)` member?
    fn inDiffPair(self: *Work, net_i: usize) bool {
        for (self.placement.diff_pairs) |p| {
            if (p.p == net_i or p.n == net_i) return true;
        }
        return false;
    }

    /// Does `net_i`'s class declare `(max-freq …)`?
    fn netRf(self: *Work, net_i: usize) bool {
        if (net_i >= self.placement.rules.net.len) return false;
        return self.placement.rules.net[net_i].rf.max_freq_hz > 0;
    }

    /// `net_i`'s `(net-class … (priority …))`, 0 when unclassed.
    fn netPriority(self: *Work, net_i: usize) u32 {
        if (net_i >= self.placement.rules.net.len) return 0;
        return self.placement.rules.net[net_i].priority;
    }

    /// Is some via on the board an RF fence flanking `name`? A fence via's `net`
    /// is the ground it stitches; its `f` names the FENCED trace, which is the
    /// net that must not move out from under it.
    fn fenced(self: *Work, name: []const u8) bool {
        for (self.vias.items) |v| {
            if (v.f.len > 0 and std.mem.eql(u8, v.f, name)) return true;
        }
        return false;
    }

    /// How many tracks plus vias `name` currently has on the board — the
    /// policy's measure of how much copper a restore has to re-lay.
    fn netElements(self: *Work, name: []const u8) usize {
        var n: usize = 0;
        for (self.tracks.items) |t| {
            if (std.mem.eql(u8, t.net, name)) n += 1;
        }
        for (self.vias.items) |v| {
            if (std.mem.eql(u8, v.net, name)) n += 1;
        }
        return n;
    }

    /// Finish the pending decision trace once the transaction has a verdict,
    /// recording what actually became of every net it stripped. Nothing to do
    /// on the standard tier, which nominates through `closestNets`.
    fn closeTrace(self: *Work, tier: Tier, won: bool) std.mem.Allocator.Error!void {
        if (tier != .cheap) return;
        var t = self.pending_trace orelse return;
        self.pending_trace = null;
        t.won = won;
        for (t.picked) |*p| {
            p.after = self.netElements(p.net);
            p.whole = !containsName(try self.openNetNames(), p.net);
        }
        try self.vacate_trace.append(self.alloc, t);
    }

    /// The `.standard` tier's nomination: the `max_vacate_blockers` nets closest
    /// to a seed's corridors that this tier is allowed to restructure — the
    /// copper most plausibly sitting ON the channel, rather than merely beside
    /// it. `ranked` already breaks ties on net index, so the phase stays
    /// deterministic.
    ///
    /// The eligibility filter runs HERE rather than inside the sweep, so both
    /// tiers see the same board: the `.cheap` tier needs every foreign net in
    /// the corridor to reach `vacate_policy`, which has to SEE the copper it
    /// refuses in order to report it. Filtering after the ranking picks the same
    /// nets it always did — a refused candidate is skipped, never counted
    /// against the cap.
    fn closestNets(
        self: *Work,
        ranked: []const nomination.Candidate,
    ) std.mem.Allocator.Error![]const usize {
        var out: std.ArrayList(usize) = .empty;
        for (ranked) |c| {
            if (out.items.len >= max_vacate_blockers) break;
            if (!self.movable(c.net_i)) continue;
            if (c.net_i >= self.whole.len or !self.whole[c.net_i]) continue;
            try out.append(self.alloc, c.net_i);
        }
        return out.items;
    }

    /// Take every track and via belonging to `nets` off the board. The removal
    /// is physical (not a `dead` mark) because the round that follows re-plans
    /// against this copper and re-uses the mark array for its own rips.
    fn stripNets(self: *Work, nets: []const usize) std.mem.Allocator.Error!void {
        var keep_t: std.ArrayList(SavedTrack) = .empty;
        for (self.tracks.items) |t| {
            if (!self.inNetSet(nets, t.net)) try keep_t.append(self.alloc, t);
        }
        var keep_v: std.ArrayList(SavedVia) = .empty;
        for (self.vias.items) |v| {
            if (!self.inNetSet(nets, v.net)) try keep_v.append(self.alloc, v);
        }
        self.tracks = keep_t;
        self.vias = keep_v;
        self.dead = &.{};
    }

    /// Is the copper named `name` on one of the flattened-net indices `nets`?
    fn inNetSet(self: *Work, nets: []const usize, name: []const u8) bool {
        for (nets) |n| {
            if (n < self.placement.nets.len and std.mem.eql(u8, self.placement.nets[n].name, name)) return true;
        }
        return false;
    }

    /// Hop requests for `nets`, in TWO blocks: the first `lead` nets' hops, then
    /// everything else. Each block is sorted hardest-first among itself, so the
    /// member with only one way back is asked before a short hop that fits
    /// anywhere spends its corridor — but the lead block always claims its
    /// corridors before the tail block sees the board.
    ///
    /// `lead` is the ROUTING ORDER, and it is the whole lever a wholesale
    /// transaction has. A single-seed transaction passes 1: the seed gets first
    /// pick of the channel its blockers just left, which is the point of the
    /// phase. A joint transaction passes its cluster width to put every seed
    /// first, `0` to let the whole subset contend on the pass's own
    /// hardest-first rule, or the blocker count (with the seeds moved to the
    /// back of `nets`) to make the displaced copper re-lay FIRST and hand the
    /// seeds what is left — the only order that can find a solution in which the
    /// blockers moved ASIDE rather than merely returning.
    fn planFor(
        self: *Work,
        nets: []const usize,
        lead: usize,
        round: usize,
    ) std.mem.Allocator.Error![]const router.Gap {
        const open = try self.openList();
        var index = std.StringHashMapUnmanaged(usize).empty;
        for (self.placement.parts, 0..) |p, i| try index.put(self.alloc, p.ref_des, i);
        var gaps: std.ArrayList(router.Gap) = .empty;
        var lead_end: usize = 0;
        for (nets, 0..) |net_i, n| {
            for (open) |o| {
                if (netIndex(self.placement, o.net) != net_i) continue;
                try self.planNetHops(&gaps, &index, o, round);
            }
            if (n + 1 == lead) lead_end = gaps.items.len;
        }
        std.mem.sort(router.Gap, gaps.items[0..lead_end], self, hardestFirst);
        std.mem.sort(router.Gap, gaps.items[lead_end..], self, hardestFirst);
        return gaps.items;
    }

    /// How many copper islands the oracle still finds `seed` in.
    fn seedIslands(self: *Work, seed: usize) std.mem.Allocator.Error!usize {
        const name = self.placement.nets[seed].name;
        for (try self.openList()) |o| {
            if (std.mem.eql(u8, o.net, name)) return o.islands;
        }
        return 0;
    }

    /// The oracle's open-net report AND the live copper it was computed from,
    /// read together — the pair every nomination needs.
    ///
    /// Read ONCE per nomination pass, not once per seed. Both halves are full
    /// sweeps over the board (rebuilding the routed copper from the saved
    /// tracks, then running the connectivity oracle over it), and a cluster scan
    /// asks about every open net; taking them per seed would pay for them a
    /// dozen times to learn the same thing.
    fn boardView(self: *Work) std.mem.Allocator.Error!?BoardView {
        const r = try self.copper();
        return .{
            .open = try fab_readiness.openNets(self.alloc, self.placement, .{
                .tracks = r.tracks,
                .arcs = r.arcs,
                .rf_paths = r.rf_port_outcomes,
                .vias = r.vias,
                .zones = self.zones,
            }),
            .routes = r,
        };
    }

    /// The oracle's open-net report for the board as it stands.
    fn openList(self: *Work) std.mem.Allocator.Error![]const fab_readiness.OpenNet {
        const r = try self.copper();
        return fab_readiness.openNets(self.alloc, self.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = self.zones,
        });
    }

    /// Just the names from `openList` — the SET the phase's accept gate compares
    /// before and after, so it can never trade one open net for another.
    fn openNetNames(self: *Work) std.mem.Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.openList()) |o| try out.append(self.alloc, o.net);
        return out.items;
    }
};

/// Resolve order, layer/via policies and reservations together. A failed
/// allocation cannot silently turn authored hard constraints into defaults.
fn finishingPlan(
    alloc: std.mem.Allocator,
    block: *env_mod.DesignBlock,
    placement: optimizer.Placement,
    zones: []const pour.UserZone,
) std.mem.Allocator.Error!FinishingPlan {
    const ranks = try alloc.alloc(usize, placement.nets.len);
    @memset(ranks, std.math.maxInt(usize));
    var policy = try module_policy.analyze(alloc, placement);
    defer policy.deinit(alloc);
    const resolved = try plan_resolve.resolve(alloc, block.pcb_plan, .{
        .placement = placement,
        .net_class = policy.net_class,
        .part_role = policy.part_role,
        .modules = policy.modules,
        .sections = try plan_resolve.sectionMembers(alloc, block),
        .net_class_specs = block.net_classes,
        .zones = zones,
    });
    for (resolved.route, 0..) |wave, wi| {
        for (wave.members) |net_i| {
            if (net_i < ranks.len and ranks[net_i] == std.math.maxInt(usize)) ranks[net_i] = wi;
        }
    }
    return .{
        .rank = ranks,
        .net = if (block.pcb_plan != null) try plan_resolve.routePolicies(alloc, resolved, placement, true) else &.{},
        .reserved = resolved.escape_reserved,
    };
}

/// Net name after the last '/', so a sub-block's `pll/GND` reads as ground.
const leafName = net_names.leaf;

/// Is `name` in `names`?
/// Distance from (px,py) to the segment (x1,y1)-(x2,y2).
fn segPointDistance(x1: f64, y1: f64, x2: f64, y2: f64, px: f64, py: f64) f64 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 0) return std.math.hypot(px - x1, py - y1);
    const t = @max(0.0, @min(1.0, ((px - x1) * dx + (py - y1) * dy) / len2));
    return std.math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
}

/// The placed part with this ref-des, or null when the netlist names one the
/// placement does not carry.
fn partWithRef(placement: optimizer.Placement, ref: []const u8) ?optimizer.Part {
    for (placement.parts) |p| {
        if (std.mem.eql(u8, p.ref_des, ref)) return p;
    }
    return null;
}

/// One numbered pad of a part, or null when the pin does not resolve.
fn padNumbered(part: optimizer.Part, num: []const u8) ?geometry.Pad {
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, num)) return pad;
    }
    return null;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Is `i` in `items`?
fn containsIndex(items: []const usize, i: usize) bool {
    for (items) |x| {
        if (x == i) return true;
    }
    return false;
}

/// May a bridge that produced no path buy the corridor-local fine rungs? The
/// endpoint-exact rescue is cheap only once the residual is genuinely small;
/// both a drained and a capped search can be a raster/escape miss at that point.
fn endgameBridgeFine(open: usize, gap: router.Gap, why: router.GapReason) bool {
    if (gap.to == null or open == 0 or open > global_detour_last_nets) return false;
    return why == .blocked or why == .exhausted;
}

/// May that bridge additionally search the whole board at divisor 4? Only a
/// long, budget-exhausted bridge benefits: a short blocked hop wants the exact
/// terminal escape inside its local window, while a long exhausted hop may have
/// a legal perimeter path outside that window.
fn globalDetourEligible(open: usize, spent: usize, gap: router.Gap, why: router.GapReason) bool {
    if (!endgameBridgeFine(open, gap, why)) return false;
    if (why != .exhausted or spent >= global_detour_spenders) return false;
    return Work.hopSpan(gap) >= global_detour_min_span_mm;
}

/// A landed path whose transaction failed (most often `broke_victim`) may need
/// the same non-destructive global detour as an exhausted search. The router did
/// find copper, but only by taking a trunk it could not put back; generated
/// boundary corridors are specifically the alternative that leaves it alone.
fn globalDetourForRejected(open: usize, spent: usize, gap: router.Gap) bool {
    if (gap.to == null or open == 0 or open > global_detour_last_nets) return false;
    if (spent >= global_detour_spenders) return false;
    return Work.hopSpan(gap) >= global_detour_min_span_mm;
}

/// Four generated corridor candidates for one bridge, one along each board
/// edge. They are tried before the unconstrained global flood: a deterministic
/// three-leg route is both cheaper and the topology this rung exists to find.
fn boundaryDetours(placement: optimizer.Placement, gap: router.Gap) [4]BoundaryDetour {
    const to = gap.to orelse gap.from;
    const left = placement.minx + boundary_detour_inset_mm;
    const right = placement.maxx - boundary_detour_inset_mm;
    const top = placement.miny + boundary_detour_inset_mm;
    const bottom = placement.maxy - boundary_detour_inset_mm;
    const from_dx: f64 = if (gap.from.x >= to.x) boundary_escape_mm else -boundary_escape_mm;
    const from_dy: f64 = if (gap.from.y >= to.y) boundary_escape_mm else -boundary_escape_mm;
    const first_x = @max(left, @min(right, gap.from.x + from_dx));
    const second_x = @max(left, @min(right, to.x - from_dx));
    const first_y = @max(top, @min(bottom, gap.from.y + from_dy));
    const second_y = @max(top, @min(bottom, to.y - from_dy));
    const points = [4][2]router.NetPt{
        .{ .{ .x = first_x, .y = top, .layer = 0 }, .{ .x = second_x, .y = top, .layer = 0 } },
        .{ .{ .x = first_x, .y = bottom, .layer = 1 }, .{ .x = second_x, .y = bottom, .layer = 1 } },
        .{ .{ .x = left, .y = first_y, .layer = gap.from.layer }, .{ .x = left, .y = second_y, .layer = gap.from.layer } },
        .{ .{ .x = right, .y = first_y, .layer = gap.from.layer }, .{ .x = right, .y = second_y, .layer = gap.from.layer } },
    };
    var out: [4]BoundaryDetour = undefined;
    for (points, 0..) |pair, i| {
        out[i] = .{
            .first = pair[0],
            .second = pair[1],
            .window = .{
                .x0 = @min(@min(gap.from.x, to.x), @min(pair[0].x, pair[1].x)) - boundary_detour_margin_mm,
                .y0 = @min(@min(gap.from.y, to.y), @min(pair[0].y, pair[1].y)) - boundary_detour_margin_mm,
                .x1 = @max(@max(gap.from.x, to.x), @max(pair[0].x, pair[1].x)) + boundary_detour_margin_mm,
                .y1 = @max(@max(gap.from.y, to.y), @max(pair[0].y, pair[1].y)) + boundary_detour_margin_mm,
            },
        };
    }
    return out;
}

/// Bridges `router.GapSink` to the server log: one line per routed hop, naming
/// the net, the hop shape, and what it cost — the only view a caller has into a
/// pass that spends minutes inside a single `closeGaps` call.
const HopWatch = struct {
    work: *Work,
    tried: usize = 0,
    gaps: []const router.Gap,
    /// The batch's physical track indices can include many chords per saved
    /// arc. Keep its original owner map for every judge call in the batch.
    map: []const usize,
    /// Wall clock at the previous event — the router reports hop boundaries and
    /// leaves the timing to us, so consecutive reads give each hop's cost.
    last_ms: i64,
    /// Per-hop diagnosis, index-aligned with `gaps`, for the round loop to
    /// report once it knows whether the hop also survived the accept gate.
    reasons: []router.GapReason,
    /// Per-hop accept-gate verdict, index-aligned with `gaps`; null where the
    /// hop found no path and the gate was never asked.
    verdicts: []?Verdict,

    /// The accept gate, as the router's per-hop veto (see `router.GapJudge`).
    /// Running it here rather than after the batch is what keeps the board the
    /// later hops route against equal to the board this pass keeps.
    fn keep(ctx: ?*anyopaque, index: usize, path: router.GapPath) bool {
        const self: *HopWatch = @ptrCast(@alignCast(ctx orelse return true));
        if (index >= self.gaps.len) return true;
        // An allocation failure mid-judgement cannot be reported through a veto
        // that returns bool. Refusing the copper is the fail-safe answer: the
        // hop is rolled back and reported, never silently kept unjudged.
        var saved_path = path;
        saved_path.ripped = self.work.mapRipped(path.ripped, self.map) catch {
            self.verdicts[index] = .no_path;
            return false;
        };
        const verdict = self.work.tryHop(self.gaps[index], saved_path) catch Verdict.no_path;
        self.verdicts[index] = verdict;
        return verdict == .kept;
    }

    fn emit(ctx: ?*anyopaque, ev: router.GapEvent) void {
        const self: *HopWatch = @ptrCast(@alignCast(ctx orelse return));
        const now = clock.milliTimestamp();
        const took = now - self.last_ms;
        self.last_ms = now;
        if (ev.index >= self.gaps.len) return;
        self.tried += 1;
        self.reasons[ev.index] = ev.why;
        const gap = self.gaps[ev.index];
        progress("  {s} {s} ({d:.2},{d:.2}) {s} {d} ms{s}", .{
            self.work.placement.nets[gap.net_i].name,
            if (gap.to != null) "bridge" else "stitch",
            gap.from.x,
            gap.from.y,
            @tagName(ev.why),
            took,
            if (ev.ripped > 0) " (ripped)" else "",
        });
    }
};

/// Logs the router's diagnosis for each hop of a rip victim's repair. The
/// repair is where a rip-up-and-reorder transaction usually dies, and "0/1 hops
/// re-routed" alone does not say whether the victim's pad got SEALED by the
/// copper that just rescued the other net or whether the channel simply filled.
const RepairWatch = struct {
    net: []const u8,

    fn emit(ctx: ?*anyopaque, ev: router.GapEvent) void {
        const self: *RepairWatch = @ptrCast(@alignCast(ctx orelse return));
        progress("    repair hop {d} on {s}: {s}", .{ ev.index, self.net, @tagName(ev.why) });
    }
};

/// Copy a slice into a growable list.
fn dupeList(comptime T: type, alloc: std.mem.Allocator, items: []const T) std.mem.Allocator.Error!std.ArrayList(T) {
    var list: std.ArrayList(T) = .empty;
    try list.appendSlice(alloc, items);
    return list;
}

/// Map the shown user pours to router source copper, so a same-net pour is a
/// stitch target and a foreign one is measured for clearance.
fn zoneSources(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    zones: []const pour.UserZone,
) std.mem.Allocator.Error![]const route_policy.ExistingZone {
    var out: std.ArrayList(route_policy.ExistingZone) = .empty;
    for (zones) |z| {
        const ni = netIndex(placement, z.net) orelse continue;
        try out.append(alloc, .{
            .polygon = z.poly,
            .layer = z.layer,
            .net = @intCast(ni),
            .copper = true,
            .priority = z.priority,
        });
    }
    return out.items;
}

/// The flattened-net index of `name`, or null when unknown.
fn netIndex(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, i| {
        if (std.mem.eql(u8, net.name, name)) return i;
    }
    return null;
}

/// Lift an oracle pad into the router's terminal form: its world centre, the
/// signal layer its side puts it on, and the outward escape axis (part centre →
/// pad centre) the gateway fan prefers.
fn padPoint(
    placement: optimizer.Placement,
    index: *std.StringHashMapUnmanaged(usize),
    p: fab_readiness.OpenPad,
) ?router.NetPt {
    const pi = index.get(p.ref) orelse return null;
    const part = placement.parts[pi];
    const len = std.math.hypot(p.x - part.x, p.y - part.y);
    return .{
        .x = p.x,
        .y = p.y,
        .layer = if (p.side == .bottom) 1 else 0,
        .thru = p.thru,
        .ref_des = p.ref,
        .pin = p.pad,
        .out = if (len > 1e-9) .{ (p.x - part.x) / len, (p.y - part.y) / len } else .{ 0, 0 },
    };
}

/// Complete physical validation, prepared before writing the candidate.
const FinalCheck = struct {
    violations: []const drc.Violation,
    tally: fab_readiness.Tally,
};

fn finalCheck(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, work: *Work) std.mem.Allocator.Error!?FinalCheck {
    const r = try work.copper();
    const report = drc_rules.checkRelease(alloc, project_dir, name, .{
        .placement = work.placement,
        .routed = r,
        .clearance = work.params.clearance,
        .zones = work.zones,
    });
    if (!report.complete) return null;
    return .{
        .violations = report.effective,
        .tally = try fab_readiness.routableTally(alloc, work.placement, .{
            .tracks = r.tracks,
            .arcs = r.arcs,
            .rf_paths = r.rf_port_outcomes,
            .vias = r.vias,
            .zones = work.zones,
        }),
    };
}

/// Write the tool's result: what it laid down, plus the pour-aware DRC and the
/// connectivity tally of the board it just persisted.
const Outcome = struct {
    alloc: std.mem.Allocator,
    design: []const u8,
    layout: []const u8,
    work: *Work,
    final: FinalCheck,
    tally: Tally,
    wall_ms: i64,
};

/// Write the tool's result: what it laid down, plus the pour-aware DRC and the
/// connectivity tally of the board it just persisted.
fn writeResult(out: *std.ArrayList(u8), o: Outcome) HandlerError!bool {
    const alloc = o.alloc;
    const work = o.work;
    const violations = o.final.violations;
    // `drc.errorCount`, so `drc_errors` means the same fab-blocking geometry it
    // does in the `add_tracks` result and in the rollback gate this tool's own
    // hops are judged by. The open nets it drops are reported two fields along,
    // as `routed`/`total`/`open` — the very thing this tool exists to move.
    const errors = drc.errorCount(violations);
    var warnings: usize = 0;
    var diff_warnings: usize = 0;
    var artifact_warnings: usize = 0;
    for (violations) |v| {
        if (v.severity == .warn) warnings += 1;
        if (v.kind == .diff_uncoupled or v.kind == .diff_skew) diff_warnings += 1;
        if (v.kind == .single_layer_via or v.kind == .redundant_via or v.kind == .copper_stub or v.kind == .dangling_copper) artifact_warnings += 1;
    }
    const final = o.final.tally;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print("{{\"ok\":true,\"live_version\":{d},\"layout\":", .{serve_root.getLiveVersion(o.design)});
    try pcb_layout_page.writeJsonStr(w, o.layout);
    try w.print(",\"bypasses_repaired\":{d},\"bypasses_remaining\":{d}", .{
        o.tally.bypasses, drc.countKind(violations, .bypass_open),
    });
    try w.print(",\"search_timed_out\":{s}", .{if (work.budget.timed_out) "true" else "false"});
    try w.print(
        ",\"hops_tried\":{d},\"hops_kept\":{d},\"hops_no_path\":{d},\"hops_rejected\":{d}," ++
            "\"nets_vacated\":{d},\"nets_joint_vacated\":{d}," ++
            "\"vacate_hops_tried\":{d},\"vias_folded\":{d},\"pair_quality_rejected\":{d}," ++
            "\"artifact_tracks_pruned\":{d},\"artifact_vias_pruned\":{d}," ++
            "\"ripped_tracks\":{d},\"tracks\":{d},\"vias\":{d}," ++
            "\"drc\":{d},\"drc_errors\":{d},\"drc_warnings\":{d},\"diff_warnings\":{d},\"artifact_warnings\":{d}," ++
            "\"wall_ms\":{d},\"routed\":{d},\"total\":{d},\"open\":",
        .{
            o.tally.tried,
            o.tally.kept,
            o.tally.no_path,
            o.tally.rejected,
            o.tally.vacated,
            o.tally.joint,
            work.vacate_hops,
            o.tally.folded,
            o.tally.pair_rejected,
            o.tally.artifact_tracks_pruned,
            o.tally.artifact_vias_pruned,
            o.tally.ripped,
            work.tracks.items.len,
            work.vias.items.len,
            violations.len,
            errors,
            warnings,
            diff_warnings,
            artifact_warnings,
            o.wall_ms,
            final.routed,
            final.total,
        },
    );
    try writeStrArray(w, final.open);
    // TWO ledgers, because they answer different questions. `failed[]` is the
    // round loop's record — hops on the nets the caller named, against the board
    // that was just persisted — and it is what an agent reads to decide what to
    // do next. `vacate_failed[]` is the wholesale phase's internal churn on the
    // foreign nets its transactions displaced; those name nets that are neither
    // open nor in scope, and a rolled-back transaction's entries describe copper
    // that no longer exists. Merged into one array (as they were) an agent
    // cannot tell which it is holding, and `hops_tried: 0` beside two dozen
    // diagnoses reads as a ledger from somewhere else entirely.
    try w.writeAll(",\"failed\":");
    try writeFailures(w, work, .round, final.open);
    try w.writeAll(",\"vacate_failed\":");
    try writeFailures(w, work, .vacate, final.open);
    try writeVacateTrace(w, work);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Emit `,"vacated":[…]` — one entry per cheap-tier transaction, naming the
/// copper it moved and the copper it would not.
///
/// Omitted entirely when the tier never ran, so a board that closes without it
/// (or a board with nothing open at all) reports exactly what it always did.
///
/// This is the tier's agent-facing half. `nets_vacated` says how many seeds the
/// wholesale phase closed; it says nothing about WHICH neighbours were moved to
/// close them, and nothing at all when a transaction rolled back. An agent
/// holding a still-open net needs both: the picks tell it what the closer was
/// willing to disturb (and whether each came back whole), and the refusals tell
/// it which copper is off-limits and on what grounds — which is the difference
/// between "try a different call" and "this corridor needs a hand route".
fn writeVacateTrace(w: *std.Io.Writer, work: *Work) HandlerError!void {
    if (work.vacate_trace.items.len == 0) return;
    try w.writeAll(",\"vacated\":[");
    for (work.vacate_trace.items, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"seed\":");
        try pcb_layout_page.writeJsonStr(w, t.seed);
        try w.print(",\"kept\":{s},\"nets\":[", .{if (t.won) "true" else "false"});
        for (t.picked, 0..) |p, k| {
            if (k > 0) try w.writeAll(",");
            try w.writeAll("{\"net\":");
            try pcb_layout_page.writeJsonStr(w, p.net);
            try w.print(
                ",\"why\":\"{s}\",\"elements_before\":{d},\"elements_after\":{d},\"restored\":{s}}}",
                .{ @tagName(p.kind), p.before, p.after, if (p.whole) "true" else "false" },
            );
        }
        try w.writeAll("],\"refused\":[");
        for (t.refused, 0..) |x, k| {
            if (k > 0) try w.writeAll(",");
            try w.writeAll("{\"net\":");
            try pcb_layout_page.writeJsonStr(w, x.net);
            try w.print(",\"why\":\"{s}\"}}", .{@tagName(x.why)});
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

/// One phase's failure ledger as a JSON array (see `Phase`).
fn writeFailures(w: *std.Io.Writer, work: *Work, phase: Phase, open: []const []const u8) HandlerError!void {
    try w.writeAll("[");
    var n: usize = 0;
    for (work.failures.items) |f| {
        if (f.phase != phase) continue;
        if (phase == .round and !containsName(open, f.net)) continue;
        if (n > 0) try w.writeAll(",");
        n += 1;
        try w.writeAll("{\"net\":");
        try pcb_layout_page.writeJsonStr(w, f.net);
        try w.print(",\"kind\":\"{s}\",\"x\":{d},\"y\":{d},\"why\":\"{s}\",\"router\":\"{s}\"", .{
            if (f.bridge) "bridge" else "stitch",
            f.x,
            f.y,
            @tagName(f.verdict),
            @tagName(f.why),
        });
        // A rolled-back transaction's board was restored byte-for-byte, so this
        // diagnosis is about a board that was never persisted. Saying so is the
        // difference between "here is what is wrong with your copper" and "here
        // is what the phase tried and undid".
        if (f.rolled_back) try w.writeAll(",\"rolled_back\":true");
        // What to TRY next, in the caller's vocabulary — the half a bare
        // verdict never carried (see `remedyFor`).
        const remedy = remedyFor(f.verdict, f.why, work.only.len > 0);
        if (remedy.len > 0) {
            try w.writeAll(",\"remedy\":");
            try pcb_layout_page.writeJsonStr(w, remedy);
        }
        // The violations a DRC-rejected hop introduced: the rule it broke, by
        // how much, and where. Without these "why: drc" says only that the
        // gate refused the copper — with them an agent can see that (say) a
        // track↔pad shortfall of 0.03 mm wants a narrower class or a different
        // corridor, and write that constraint instead of guessing.
        if (f.drc_new.len > 0) {
            try w.writeAll(",\"drc_new\":[");
            for (f.drc_new, 0..) |v, k| {
                if (k > 0) try w.writeAll(",");
                try w.print(
                    "{{\"kind\":\"{s}\",\"x\":{d:.3},\"y\":{d:.3},\"gap\":{d:.4},\"clearance\":{d:.4},\"short_by\":{d:.4},\"nets\":",
                    .{ @tagName(v.kind), v.x, v.y, v.gap, v.clearance, v.clearance - v.gap },
                );
                try writeStrArray(w, work.netsAt(v.x, v.y, v.kind) catch &.{});
                try w.writeAll("}");
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

fn writeStrArray(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, s);
    }
    try w.writeAll("]");
}

fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

const argNames = mcp_arg_names.parse;

/// A boolean argument, or null when the caller did not supply one.
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

/// Zero starts directly at the wholesale phase. Malformed explicit values
/// must not silently buy four ordinary rounds before that phase can run.
fn roundCount(args_val: ?std.json.Value) ?usize {
    const args = args_val orelse return default_rounds;
    if (args != .object) return default_rounds;
    const value = args.object.get("rounds") orelse return default_rounds;
    if (value != .integer) return null;
    return std.math.cast(usize, value.integer);
}

fn fail(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) HandlerError!bool {
    try out.appendSlice(alloc, "{\"ok\":false,\"error\":");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try pcb_layout_page.writeJsonStr(&aw.writer, msg);
    try out.appendSlice(alloc, aw.written());
    try out.appendSlice(alloc, "}");
    return false;
}

fn failFmt(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) HandlerError!bool {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return fail(out, alloc, msg);
}

const testing = std.testing;

/// A two-pad board whose only copper is a stub that leaves the net open — the
/// smallest fixture a gap pass can be judged on.
fn gapFixture(parts: []optimizer.Part, nets: []const export_kicad.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
}

// spec: Web Server - Finishing validation propagates allocation failures instead of reporting clean geometry or completed connectivity
test "close_open_nets validation reports allocation failure" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    inline for (.{ Work.geometryErrors, Work.diffWarnings, Work.errorViolations, Work.openNetCount, Work.planRound }, 0..) |inspect, i| {
        var failing = testing.FailingAllocator.init(arena, .{ .fail_index = 0 });
        var work = Work{
            .alloc = failing.allocator(),
            .placement = gapFixture(&parts, &nets),
            .params = .{},
            .zones = &.{},
            .router_zones = &.{},
            .rules = .{},
            .tracks = .empty,
            .vias = .empty,
        };
        if (i == 4) {
            try testing.expectError(error.OutOfMemory, inspect(&work, 0));
        } else {
            try testing.expectError(error.OutOfMemory, inspect(&work));
        }
    }
}

// spec: Web Server - Finishing must retain every shown pour obstacle or report allocation failure before searching
test "close_open_nets cannot silently truncate pour obstacles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    const placement = gapFixture(&parts, &nets);
    const polygon = [_][2]f64{ .{ 1, 1 }, .{ 9, 1 }, .{ 9, 9 }, .{ 1, 9 } };
    const zones = [_]pour.UserZone{
        .{ .net = "SIG", .layer = 0, .poly = &polygon },
        .{ .net = "SIG", .layer = 1, .poly = &polygon },
    };
    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, zoneSources(failing.allocator(), placement, &zones));
    try testing.expectEqual(@as(usize, 2), (try zoneSources(alloc, placement, &zones)).len);
}

// spec: Web Server - Final finishing validation cannot return a complete candidate after a checker allocation failure
test "close_open_nets final validation refuses incomplete evidence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "src", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(project);
    for (0..4000) |fail_at| {
        var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();
        var failing = testing.FailingAllocator.init(arena, .{ .fail_index = fail_at });
        var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
        const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
        var work = Work{
            .alloc = failing.allocator(),
            .placement = gapFixture(&parts, &nets),
            .params = .{},
            .zones = &.{},
            .router_zones = &.{},
            .rules = .{},
            .tracks = .empty,
            .vias = .empty,
        };
        const result = finalCheck(work.alloc, project, "demo", &work);
        if (!failing.has_induced_failure) {
            try testing.expect((try result) != null);
            progress("final validation sweep checked {d} failure sites before complete evidence", .{fail_at});
            return;
        }
        const checked = result catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try testing.expect(checked == null);
    }
    return error.AllocationSweepDidNotFinish;
}

// spec: Web Server - Every failed allocation in a finishing hop leaves accepted tracks, vias and earlier rip marks intact
test "close_open_nets allocation failure rolls back the entire hop" {
    // Each run owns its scratch arena; fail after each allocation in turn until
    // the complete transaction succeeds, including the allocation sites after
    // its candidate copper and rip marks have already been applied.
    for (0..2000) |fail_at| {
        var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();
        var parts = [_]optimizer.Part{
            vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
            vacatePart("R3", 2, 8), vacatePart("R4", 8, 8),
        };
        const nets = [_]export_kicad.FlatNet{ vacateNet("SIG", "R1", "R2"), vacateNet("VICTIM", "R3", "R4") };
        var failing = testing.FailingAllocator.init(arena, .{ .fail_index = fail_at });
        var work = Work{
            .alloc = failing.allocator(),
            .placement = gapFixture(&parts, &nets),
            .params = .{},
            .zones = &.{},
            .router_zones = &.{},
            .rules = .{},
            .tracks = .empty,
            .vias = .empty,
        };
        const victim = SavedTrack{ .net = "VICTIM", .l = 0, .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .w = 0.127 };
        const original = [_]SavedTrack{ victim, victim, victim };
        try work.tracks.appendSlice(arena, &original);
        const retained_via = SavedVia{ .net = "VICTIM", .x = 5, .y = 8, .d = 0.6, .drill = 0.3 };
        try work.vias.append(arena, retained_via);
        var dead = [_]bool{ true, false, false };
        work.dead = &dead;
        var whole = [_]bool{ false, true };
        work.whole = &whole;
        const gap = router.Gap{ .net_i = 0, .from = .{ .x = 2, .y = 5, .layer = 0 }, .to = .{ .x = 8, .y = 5, .layer = 0 } };
        const path = router.GapPath{
            .tracks = &.{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .width = 0.127, .layer = 0, .net = 0 }},
            .vias = &.{.{ .x = 5, .y = 5, .dia = 0.6, .drill = 0.3, .net = 0 }},
            .ripped = &.{1},
            .ripped_nets = &.{1},
        };
        const outcome = work.tryHop(gap, path);
        if (!failing.has_induced_failure) {
            try testing.expectEqual(Verdict.kept, try outcome);
            try testing.expect(fail_at > 0);
            progress("allocation sweep checked {d} failure sites before a successful hop", .{fail_at});
            return;
        }
        try testing.expectError(error.OutOfMemory, outcome);
        try testing.expectEqual(original.len, work.tracks.items.len);
        for (original, work.tracks.items) |before, after| try testing.expect(std.meta.eql(before, after));
        try testing.expectEqual(@as(usize, 1), work.vias.items.len);
        try testing.expect(std.meta.eql(retained_via, work.vias.items[0]));
        try testing.expectEqualSlices(bool, &.{ true, false, false }, work.dead[0..3]);
    }
    return error.AllocationSweepDidNotFinish;
}

// spec: Web Server - An expired finishing search skips grid allocation and further retries while retaining already accepted copper
test "close_open_nets expired budget keeps accepted copper and skips search" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    var work = Work{
        .alloc = arena,
        .budget = .{ .stop = .{ .deadline_ns = 1 } },
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    const accepted = SavedTrack{ .net = "SIG", .l = 0, .x1 = 2, .y1 = 5, .x2 = 3, .y2 = 5, .w = 0.2 };
    try work.tracks.append(arena, accepted);
    const gap = router.Gap{ .net_i = 0, .from = .{ .x = 3, .y = 5, .layer = 0 }, .to = .{ .x = 8, .y = 5, .layer = 0 } };
    const paths = try work.closeGaps(.{}, &.{gap}, .{ .ripup = false });
    try testing.expect(paths[0] == null);
    try testing.expect(work.budget.timed_out);
    try testing.expectEqual(@as(usize, 0), (try work.runRound(&.{gap}, null)).hops);
    try testing.expectEqual(@as(usize, 0), try work.vacatePhase());
    try testing.expectEqual(@as(usize, 0), try work.jointPhase());
    try testing.expectEqual(@as(usize, 0), work.failures.items.len);
    try testing.expectEqual(@as(usize, 1), work.tracks.items.len);
    try testing.expect(std.meta.eql(accepted, work.tracks.items[0]));
    // A previous wholesale tier can exhaust the deadline. Later tiers must
    // not rebuild the board or allocate a rollback copy before checking it.
    var failing = testing.FailingAllocator.init(arena, .{ .fail_index = 0 });
    work.alloc = failing.allocator();
    try testing.expect(!try work.vacateAt(0, vacate_fine_divisor, .standard));
    try testing.expect(!failing.has_induced_failure);
}

// spec: Web Server - Finishing rejects invalid search budgets and never extends an already armed deadline
test "close_open_nets validates and arms its search budget once" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const invalid = [_][]const u8{
        "{\"name\":\"unused\",\"max_route_ms\":0}",
        "{\"name\":\"unused\",\"max_route_ms\":-1}",
        "{\"name\":\"unused\",\"max_route_ms\":3600001}",
        "{\"name\":\"unused\",\"max_route_ms\":\"1000\"}",
        "{\"name\":\"unused\",\"max_route_ms\":null}",
    };
    for (invalid) |text| {
        const args = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
        var out: std.ArrayList(u8) = .empty;
        try testing.expect(!try mcpCloseOpenNets(arena, "/unused", args.value, &out));
        try testing.expect(std.mem.indexOf(u8, out.items, "max_route_ms must be an integer") != null);
    }
    var unlimited = SearchBudget.fromArgs(null).?;
    unlimited.arm();
    try testing.expectEqual(@as(i128, 0), unlimited.stop.deadline_ns);
    try testing.expect(!unlimited.stopped());
    const args = try std.json.parseFromSlice(std.json.Value, arena, "{\"max_route_ms\":1000}", .{});
    var bounded = SearchBudget.fromArgs(args.value).?;
    const before = clock.nanoTimestamp();
    bounded.arm();
    const deadline = bounded.stop.deadline_ns;
    try testing.expect(deadline >= before + clock.ns_per_s);
    bounded.arm();
    try testing.expectEqual(deadline, bounded.stop.deadline_ns);
    try testing.expectEqual(deadline, bounded.restrict(.{}).deadline_ns);
    try testing.expectEqual(@as(i128, 1), bounded.restrict(.{ .deadline_ns = 1 }).deadline_ns);
}

// spec: Web Server - Finishing rejects malformed round counts before evaluating or changing a layout
test "close_open_nets rejects malformed round counts" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const invalid = [_][]const u8{
        "{\"name\":\"unused\",\"rounds\":-1}",
        "{\"name\":\"unused\",\"rounds\":\"4\"}",
        "{\"name\":\"unused\",\"rounds\":1.5}",
        "{\"name\":\"unused\",\"rounds\":null}",
        "{\"name\":\"unused\",\"rounds\":false}",
    };
    for (invalid) |source| {
        const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
        var out: std.ArrayList(u8) = .empty;
        try testing.expect(!try mcpCloseOpenNets(arena, "/unused", args, &out));
        try testing.expect(std.mem.indexOf(u8, out.items, "rounds must be a non-negative integer") != null);
    }
    try testing.expectEqual(@as(?usize, default_rounds), roundCount(null));
    const omitted = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    try testing.expectEqual(@as(?usize, default_rounds), roundCount(omitted));
}

// spec: Web Server - An expired finishing deadline still gates completed copper and rolls back a hop whose victim cannot be repaired
test "close_open_nets timeout keeps a complete hop and rolls back an unrepaired victim" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
        vacatePart("R3", 2, 8), vacatePart("R4", 8, 8),
    };
    const nets = [_]export_kicad.FlatNet{ vacateNet("SIG", "R1", "R2"), vacateNet("OTHER", "R3", "R4") };
    var work = Work{
        .alloc = arena,
        .budget = .{ .stop = .{ .deadline_ns = 1 } },
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    const signal = router.Gap{ .net_i = 0, .from = .{ .x = 2, .y = 5, .layer = 0 }, .to = .{ .x = 8, .y = 5, .layer = 0 } };
    const completed = router.GapPath{ .tracks = &.{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .width = 0.127, .layer = 0, .net = 0 }} };
    try testing.expectEqual(Verdict.kept, try work.tryHop(signal, completed));
    const kept = work.tracks.items[0];
    try work.refreshWhole();
    const other = router.Gap{ .net_i = 1, .from = .{ .x = 2, .y = 8, .layer = 0 }, .to = .{ .x = 8, .y = 8, .layer = 0 } };
    const ripping = router.GapPath{
        .tracks = &.{.{ .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .width = 0.127, .layer = 0, .net = 1 }},
        .ripped = &.{0},
        .ripped_nets = &.{0},
    };
    try testing.expectEqual(Verdict.broke_victim, try work.tryHop(other, ripping));
    try testing.expect(work.budget.timed_out);
    try testing.expectEqual(@as(usize, 1), work.tracks.items.len);
    try testing.expect(std.meta.eql(kept, work.tracks.items[0]));
    try testing.expectEqual(@as(usize, 1), try work.islands(0));
    try testing.expectEqual(@as(usize, 2), try work.islands(1));
}

// spec: Web Server - Finishing propagates the route plan's layer masks, reservations and remaining new-via allowance through every round and retry without resetting the allowance
test "close_open_nets gap policy shares its remaining via allowance across retries" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    parts[1].side = .bottom;
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    const old_via = SavedVia{ .x = 2, .y = 2, .d = 0.6, .drill = 0.3, .net = "SIG" };
    var block = env_mod.DesignBlock{
        .name = "finishing-policy",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .pcb_plan = .{ .route = &.{.{
            .name = "signal",
            .nets = &.{"SIG"},
            .allowed_layers = &.{ "F.Cu", "B.Cu" },
            .max_vias = 2,
        }} },
    };
    work.plan = try finishingPlan(arena, &block, work.placement, &.{});
    try work.vias.append(arena, old_via);
    const initial = try work.remainingPolicies();
    try testing.expectEqual(@as(?u16, 1), initial[0].max_vias);
    try testing.expectEqual(@as(u64, 3), initial[0].allowed_layers);
    try work.vias.append(arena, .{ .x = 8, .y = 2, .d = 0.6, .drill = 0.3, .net = "SIG" });
    try testing.expectEqual(@as(?u16, 0), (try work.remainingPolicies())[0].max_vias);
    // This is the seam all retry rungs use. A new cross-face bridge cannot
    // acquire another via just by starting a fresh closeGaps call.
    const paths = try work.closeGaps(.{}, &.{.{
        .net_i = 0,
        .from = .{ .x = 2, .y = 5, .layer = 0 },
        .to = .{ .x = 8, .y = 5, .layer = 1 },
    }}, .{ .ripup = false });
    try testing.expect(paths[0] == null);
    // Reopening the saved board in another invocation must not reset the cap.
    work.plan = try finishingPlan(arena, &block, work.placement, &.{});
    try testing.expectEqual(@as(?u16, 0), (try work.remainingPolicies())[0].max_vias);
    try work.vias.append(arena, .{ .x = 5, .y = 2, .d = 0.6, .drill = 0.3, .net = "SIG" });
    try testing.expectEqual(@as(?u16, 0), (try work.remainingPolicies())[0].max_vias);
    work.vias.shrinkRetainingCapacity(1);
    try testing.expectEqual(@as(?u16, 1), (try work.remainingPolicies())[0].max_vias);
}

// spec: Web Server - When the nearest island bridge has failed, close_open_nets can try an untried same-face pad pair on those same islands without repeating the failed hop
test "close_open_nets tries another same-face pair after a bridge failed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 2.5, 5), vacatePart("R3", 8, 5),
    };
    parts[0].side = .bottom;
    const nets = [_]export_kicad.FlatNet{.{
        .name = "SIG",
        .pins = &.{
            .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" }, .{ .ref_des = "R3", .pin = "1" },
        },
    }};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "R1", 0);
    try index.put(arena, "R2", 1);
    try index.put(arena, "R3", 2);
    // R1 and R3 are already connected. The nearest pair asks for an extra
    // layer change; after that fails, R3 can join R2 entirely on the top face.
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 2, .y = 5, .side = .bottom, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 2.5, .y = 5, .side = .top, .thru = false, .island = 1 },
        .{ .ref = "R3", .pad = "1", .x = 8, .y = 5, .side = .top, .thru = false, .island = 0 },
    };
    const nearest = [_]fab_readiness.OpenGap{.{ .from = pads[0], .to = pads[1], .mm = 0.5 }};
    const open = fab_readiness.OpenNet{ .net = "SIG", .islands = 2, .pads = &pads, .gaps = &nearest };
    var gaps: std.ArrayList(router.Gap) = .empty;
    try work.addBridges(&gaps, &index, open, 0);
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectEqualStrings("R1", gaps.items[0].from.ref_des);
    try work.note(gaps.items[0], .no_path, .sealed_from);
    gaps.clearRetainingCapacity();
    try work.addBridges(&gaps, &index, open, 0);
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectEqualStrings("R3", gaps.items[0].from.ref_des);
    try testing.expectEqualStrings("R2", gaps.items[0].to.?.ref_des);
    try testing.expectEqual(gaps.items[0].from.layer, gaps.items[0].to.?.layer);
    try work.note(gaps.items[0], .no_path, .blocked);
    gaps.clearRetainingCapacity();
    try work.addBridges(&gaps, &index, open, 0);
    try testing.expectEqual(@as(usize, 0), gaps.items.len);
}

// spec: Web Server - The close_open_nets widened-rung policy arms its two capped rungs only once the board's residual is down to the last few nets, and only for a bounded number of hops
test "the close_open_nets rip rungs widen only in the endgame, and only so often" {
    // A wide residual reads as a placement/escape problem, so both constants
    // stand exactly where they were before the rule existed.
    const wide = gap_policy.lastKRungs(last_k.nets + 1, last_k);
    try testing.expect(!wideArmed(wide, 0));
    try testing.expectEqual(max_rip_tier, ripTierCapFor(wideArmed(wide, 0)));
    try testing.expectEqual(max_repair_rip_depth, repairRipDepthFor(wideArmed(wide, 0)));

    // With the last few nets open, "leave it to a wider rip" has nothing left to
    // leave it to, so both rungs come on.
    const endgame = gap_policy.lastKRungs(1, last_k);
    try testing.expect(wideArmed(endgame, 0));
    try testing.expectEqual(router.rip_tiers, ripTierCapFor(wideArmed(endgame, 0)));
    try testing.expect(repairRipDepthFor(wideArmed(endgame, 0)) > max_repair_rip_depth);

    // …for at most `spenders` hops. The cost is per HOP (one extra whole-board
    // maze sweep each), so the width threshold alone would let a residual
    // sitting just under it spend twenty of them.
    try testing.expect(wideArmed(endgame, last_k.spenders - 1));
    try testing.expect(!wideArmed(endgame, last_k.spenders));
    try testing.expectEqual(max_rip_tier, ripTierCapFor(wideArmed(endgame, last_k.spenders)));
    try testing.expectEqual(max_repair_rip_depth, repairRipDepthFor(wideArmed(endgame, last_k.spenders)));

    // Shipped DISARMED (see `adopt_last_k` for the numbers): `refreshWhole` then
    // hands `Work` an all-false `LastKRungs` whatever the residual is, which can
    // never arm — so every real call runs the fixed rungs above.
    try testing.expect(!wideArmed(.{}, 0));
}

// spec: Web Server - A close_open_nets board with nothing open arms no widened rung
test "a closed board arms no widened rung" {
    // Zero open nets is not an endgame, it is a finished board: there is no hop
    // to spend the extra sweep on, and `gap_policy` says so at the source.
    try testing.expect(!wideArmed(gap_policy.lastKRungs(0, last_k), 0));
}

// spec: Web Server - The close_open_nets global fine detour is reserved for a bounded number of long exhausted bridges in the last few open nets
test "the close_open_nets global detour is long-hop endgame only" {
    const long = router.Gap{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = global_detour_min_span_mm + 1, .y = 0, .layer = 0 },
    };
    var short = long;
    short.to.?.x = global_detour_min_span_mm - 1;

    try testing.expect(globalDetourEligible(2, 0, long, .exhausted));
    try testing.expect(!globalDetourEligible(global_detour_last_nets + 1, 0, long, .exhausted));
    try testing.expect(!globalDetourEligible(2, global_detour_spenders, long, .exhausted));
    try testing.expect(!globalDetourEligible(2, 0, short, .exhausted));
    try testing.expect(!globalDetourEligible(2, 0, long, .blocked));
    try testing.expect(endgameBridgeFine(2, short, .blocked));
    try testing.expect(globalDetourForRejected(2, 0, long));
    try testing.expect(!globalDetourForRejected(2, 0, short));

    const opts = Work.fineGlobalOptions(vacate_fine_divisor);
    try testing.expect(!opts.ripup);
    try testing.expectEqual(router.TerminalVia.smd_ok, opts.constraints.terminal_via);
    try testing.expectEqual(@as(?router.GapWindow, null), opts.raster.window);
    try testing.expectEqual(fine_expansion_multiplier, opts.raster.expansion_multiplier);
}

// spec: Web Server - A final bridge gets deterministic board-edge corridor candidates derived from solved geometry
test "global detours are generated from board and terminal bounds" {
    var placement = std.mem.zeroes(optimizer.Placement);
    placement.minx = 10;
    placement.maxx = 30;
    placement.miny = 20;
    placement.maxy = 50;
    const gap = router.Gap{
        .net_i = 0,
        .from = .{ .x = 14, .y = 28, .layer = 1 },
        .to = .{ .x = 26, .y = 42, .layer = 0 },
    };
    const detours = boundaryDetours(placement, gap);
    try testing.expectApproxEqAbs(@as(f64, 21), detours[0].first.y, 1e-9);
    try testing.expectEqual(@as(u8, 0), detours[0].first.layer);
    try testing.expectApproxEqAbs(@as(f64, 49), detours[1].first.y, 1e-9);
    try testing.expectEqual(@as(u8, 1), detours[1].first.layer);
    try testing.expectApproxEqAbs(@as(f64, 11), detours[2].first.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 29), detours[3].first.x, 1e-9);
    try testing.expect(detours[0].window.y0 < detours[0].first.y);
}

// spec: Web Server - The close_open_nets tool keeps a hop only when the connectivity oracle reports fewer islands on that net
test "close_open_nets rolls back a hop that does not merge the net's islands" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{.{
        .name = "SIG",
        .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } },
    }};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // A stub that goes nowhere near R2: it cannot merge the two islands, so the
    // gate must reject it and restore the board byte-for-byte.
    const useless = router.GapPath{
        .tracks = &.{.{ .x1 = 2, .y1 = 5, .x2 = 2, .y2 = 4, .layer = 0, .width = 0.127, .net = 0 }},
    };
    try testing.expectEqual(Verdict.no_merge, try work.tryHop(.{ .net_i = 0, .from = .{ .x = 2, .y = 5, .layer = 0 } }, useless));
    try testing.expectEqual(@as(usize, 0), work.tracks.items.len);

    // The same gate KEEPS copper that actually bridges the two pads.
    const bridge = router.GapPath{
        .tracks = &.{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.127, .net = 0 }},
    };
    try testing.expectEqual(Verdict.kept, try work.tryHop(.{ .net_i = 0, .from = .{ .x = 2, .y = 5, .layer = 0 } }, bridge));
    try testing.expectEqual(@as(usize, 1), work.tracks.items.len);
}

// spec: Web Server - The close_open_nets accept gate includes proven bypass-family pads when measuring progress on a parent supply rail
test "close_open_nets accepts a feed joining a proven bypass branch to its parent rail" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 4, 5),
        vacatePart("C1", 6, 5), vacatePart("U1", 8, 5),
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("VDD", "R1", "R2"), vacateNet("VDD.U1.1", "C1", "U1"),
    };
    var placement = gapFixture(&parts, &nets);
    placement.loops = &.{.{
        .cap = 2,
        .hub = 3,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .cap_gnd = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_pwr = &.{},
        .hub_gnd = &.{},
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .pwr_net = 1,
        .explicit_pin = "1",
    }};
    var work = Work{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 5, .x2 = 4, .y2 = 5, .l = 0, .w = 0.127, .net = "VDD" });
    try work.tracks.append(arena, .{ .x1 = 6, .y1 = 5, .x2 = 8, .y2 = 5, .l = 0, .w = 0.127, .net = "VDD.U1.1" });
    // Both logical endpoint pairs are closed, but the bypass branch has no feed.
    try testing.expectEqual(@as(usize, 1), try work.openNetCount());
    try testing.expectEqual(@as(usize, 2), try work.islands(0));
    try testing.expectEqual(@as(usize, 1), try work.islands(1));
    const gap = router.Gap{ .net_i = 0, .from = .{ .x = 4, .y = 5, .layer = 0 }, .to = .{ .x = 6, .y = 5, .layer = 0 } };
    const bridge = router.GapPath{ .tracks = &.{.{ .x1 = 4, .y1 = 5, .x2 = 6, .y2 = 5, .layer = 0, .width = 0.127, .net = 0 }} };
    try testing.expectEqual(Verdict.kept, try work.tryHop(gap, bridge));
    try testing.expectEqual(@as(usize, 3), work.tracks.items.len);
    try testing.expectEqual(@as(usize, 0), try work.openNetCount());
    try testing.expectEqual(@as(usize, 1), try work.islands(0));
    try testing.expectEqual(@as(usize, 1), try work.islands(1));
}

// spec: Web Server - The close_open_nets accept gate counts geometry DRC errors and never the net-open airwire it is closing
test "close_open_nets gate ignores the net-open marker of the net it is closing" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 5, .y = 9, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 7, .y = 9, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "OTHER", .pins = &.{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // OTHER has two individually terminated pad-to-via islands. It therefore
    // has no loose trace error (the one-layer vias are warnings), but its pads
    // remain disconnected and the pour-aware net-open oracle reports it.
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = 9, .x2 = 5, .y2 = 8, .l = 0, .w = 0.127, .net = "OTHER" });
    try work.tracks.append(arena, .{ .x1 = 7, .y1 = 9, .x2 = 7, .y2 = 8, .l = 0, .w = 0.127, .net = "OTHER" });
    try work.vias.append(arena, .{ .x = 5, .y = 8, .d = 0.4, .drill = 0.2, .net = "OTHER" });
    try work.vias.append(arena, .{ .x = 7, .y = 8, .d = 0.4, .drill = 0.2, .net = "OTHER" });
    try testing.expectEqual(@as(usize, 0), try work.geometryErrors());

    const r = (try work.copper());
    const pour_aware = try @import("../placement/net_open.zig").check(arena, work.placement, .{ .tracks = r.tracks, .vias = r.vias }, null);
    try testing.expect(pour_aware.len > 0);
}

// spec: Web Server - A gap pass's rip filter is told which net is asking, so a caller can refuse copper the design ranks above it
test "close_open_nets refuses to rip copper the plan ranks above the routing net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    var whole = [_]bool{ true, true };
    work.whole = &whole;
    const ranks = [_]usize{ 0, 5 }; // net 0 outranks net 1
    work.plan.rank = &ranks;

    // The lower-ranked net may not take copper from the one above it…
    try testing.expect(!Work.rippable(&work, 0, 1));
    // …while the higher-ranked net may, and equal ranks stay mutually rippable
    // (the old behaviour, which is the common unplanned case).
    try testing.expect(Work.rippable(&work, 1, 0));
    try testing.expect(Work.rippable(&work, 1, 1));
}

// spec: Web Server - A violation's reported nets name only copper that could be party to that rule — a drill finding never blames a surface pad
test "close_open_nets blames only copper that can break the rule in question" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 4, .y1 = 5, .x2 = 6, .y2 = 5, .l = 0, .w = 0.127, .net = "SIG" });

    // A track↔track finding names the track…
    try testing.expect(containsName(try work.netsAt(5, 5, .track_track), "SIG"));
    // …but a hole↔hole one does not: a track carries no drill and cannot break
    // that rule. Naming it reads as an identification and sends the reader
    // after innocent copper — which is exactly how an SMD pad once anchored a
    // whole false diagnosis here.
    try testing.expect(!containsName(try work.netsAt(5, 5, .hole_hole), "SIG"));

    // A via DOES carry a drill, so it is named for a hole↔hole.
    try work.vias.append(arena, .{ .x = 5, .y = 5, .d = 0.4, .drill = 0.2, .net = "SIG" });
    try testing.expect(containsName(try work.netsAt(5, 5, .hole_hole), "SIG"));
}

// spec: Web Server - A DRC-rejected hop reports the violations it introduced, each with the rule, the shortfall, and the nets or pads it collided with
test "close_open_nets names the copper a DRC-rejected hop collided with" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
    };
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // A bare coordinate names nothing — the honest answer for empty board.
    try testing.expectEqual(@as(usize, 0), (try work.netsAt(5, 5, .track_track)).len);

    // With copper there, the report names the net, which is what turns
    // "rejected for DRC" into a constraint an author can act on.
    try work.tracks.append(arena, .{ .x1 = 4, .y1 = 5, .x2 = 6, .y2 = 5, .l = 0, .w = 0.127, .net = "SIG" });
    const named = try work.netsAt(5, 5, .track_track);
    try testing.expect(named.len >= 1);
    try testing.expect(containsName(named, "SIG"));

    // A pad in reach is named as NET@REF.PIN — the spelling a
    // (guides (escape-from REF PIN …)) constraint is written against.
    const at_pad = try work.netsAt(2, 5, .track_pad);
    try testing.expect(containsName(at_pad, "SIG@R1.1"));
}

// spec: Web Server - The close_open_nets finishing pass orders its hops by the design's routing-plan wave order before hop length
test "close_open_nets orders hops by plan wave, then by span among peers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        vacatePart("R1", 1, 1), vacatePart("R2", 9, 1),
        vacatePart("R3", 4, 5), vacatePart("R4", 5, 5),
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("LONG", "R1", "R2"), // 8 mm span — first under the old rule
        vacateNet("PLANNED", "R3", "R4"), // 1 mm span, but named by the plan
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    const long = router.Gap{ .net_i = 0, .from = .{ .x = 1, .y = 1, .layer = 0 }, .to = .{ .x = 9, .y = 1, .layer = 0 } };
    const short = router.Gap{ .net_i = 1, .from = .{ .x = 4, .y = 5, .layer = 0 }, .to = .{ .x = 5, .y = 5, .layer = 0 } };

    // No plan: the longest hop leads, because it has the fewest alternatives.
    var gaps = [_]router.Gap{ short, long };
    std.mem.sort(router.Gap, &gaps, &work, Work.hardestFirst);
    try testing.expectEqual(@as(usize, 0), gaps[0].net_i);

    // With PLANNED in wave 0 and LONG unplanned, declared intent wins — this is
    // the whole point: the author's order reaches the finishing pass too.
    const ranks = [_]usize{ std.math.maxInt(usize), 0 };
    work.plan.rank = &ranks;
    gaps = [_]router.Gap{ short, long };
    std.mem.sort(router.Gap, &gaps, &work, Work.hardestFirst);
    try testing.expectEqual(@as(usize, 1), gaps[0].net_i);
}

// spec: Web Server - The close_open_nets tool plans hops only for the open nets the caller named
test "close_open_nets plans hops only for the nets the caller named" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two independent two-pad nets, no copper at all: each is one island pair,
    // so an unrestricted plan is exactly one bridge per net.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 8, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 8, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "OTHER", .pins = &.{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try testing.expectEqual(@as(usize, 2), (try work.planRound(0)).gaps.len);

    const only = [_][]const u8{"OTHER"};
    work.only = &only;
    const restricted = (try work.planRound(0)).gaps;
    try testing.expectEqual(@as(usize, 1), restricted.len);
    try testing.expectEqualStrings("OTHER", work.placement.nets[restricted[0].net_i].name);
}

// spec: Web Server - A close_open_nets round routes its longest-span hops before its short ones so a cheap bridge cannot spend a long hop's only corridor
test "close_open_nets orders a round's hops longest-span first" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // SHORT is declared first, so the oracle's own nearest-first order would
    // emit its 1 mm bridge ahead of LONG's 16 mm one — the order that lets the
    // cheap hop take a corridor the long hop may be the only user of.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "S1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "S2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 3, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "L1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 9, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "L2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 18, .y = 9, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SHORT", .pins = &.{ .{ .ref_des = "S1", .pin = "1" }, .{ .ref_des = "S2", .pin = "1" } } },
        .{ .name = "LONG", .pins = &.{ .{ .ref_des = "L1", .pin = "1" }, .{ .ref_des = "L2", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    const planned = try work.planRound(0);
    const gaps = planned.gaps;
    try testing.expectEqual(@as(usize, 2), gaps.len);
    try testing.expectEqualStrings("LONG", work.placement.nets[gaps[0].net_i].name);
    try testing.expectEqualStrings("SHORT", work.placement.nets[gaps[1].net_i].name);
}

// spec: Web Server - A close_open_nets pass runs on past a round that kept nothing while a later round still has hops that one could not ask for
test "close_open_nets keeps going past a barren round that still unlocked new hops" {
    // Round 0 plans no bridge for a plane-carried net, so a barren round 0 is
    // never the end of the pass.
    try testing.expect(!roundsExhausted(0, .{ .hops = 0, .ripped = 0 }));
    // A later round that ripped copper cleared the dead-end memo, so the next
    // round re-asks hops this one refused.
    try testing.expect(!roundsExhausted(2, .{ .hops = 0, .ripped = 4 }));
    // Keeping copper is progress in its own right.
    try testing.expect(!roundsExhausted(2, .{ .hops = 3, .ripped = 0 }));
    // Nothing kept, nothing ripped, past round 0 — genuinely out of ideas.
    try testing.expect(roundsExhausted(1, .{ .hops = 0, .ripped = 0 }));
}

// spec: Web Server - A close_open_nets round that finished a net drops the dead-end memo, because a whole net is copper the hops behind it may now rip
test "close_open_nets drops its dead-end memo when a round finished a net" {
    // Nothing ripped, nothing finished: every refused hop would be refused for
    // the same reasons, so the memo stands and the pass keeps the time it saves.
    try testing.expect(!memoStale(0, 5, 5));
    // Copper came off the board — the classic reason a refused hop is worth
    // re-asking.
    try testing.expect(memoStale(3, 5, 5));
    // …and so is a net becoming whole, even with nothing ripped: it was
    // unrippable while it was open, and now it is an aggressor a stuck hop may
    // move.
    try testing.expect(memoStale(0, 5, 4));
    // A round that LOST a net (a rejected transaction's victim, say) has not
    // unlocked anything by that route.
    try testing.expect(!memoStale(0, 4, 5));
}

// spec: Web Server - The close_open_nets accept gate ratchets its DRC error ceiling down as the board cleans up, so errors it removes can never come back
test "close_open_nets ratchets its DRC error ceiling down as the board cleans up" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };

    // Stand in for a board that OPENED with five errors which copper laid
    // earlier in the pass has since cleared: the board is clean now, the
    // ceiling still remembers the dirty start.
    work.error_ceiling = 5;
    try testing.expectEqual(@as(usize, 0), try work.geometryErrors());

    // A hop that merges its net on this clean board is kept...
    try testing.expectEqual(Verdict.kept, try work.judge(0, 99));
    // ...and the clean board it leaves behind becomes the new ceiling, so the
    // five errors the pass started with are no longer its to spend.
    try testing.expectEqual(@as(usize, 0), work.error_ceiling);
}

// spec: Web Server - The close_open_nets accept gate spends a caller-declared DRC error budget on a hop that closes a net, and never spends one it was not given
test "close_open_nets gate spends a declared DRC error budget but not an undeclared one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // SIG's two pads sit either side of a foreign track parked 0.05 mm off the
    // straight line between them — far under the 0.127 mm rule. Any bridge that
    // closes SIG therefore costs exactly one clearance error, which is the trade
    // a budget exists to authorise (on board-a it is `GND`'s 1.4–2.0 mm island
    // gaps against a `track↔pad` rule).
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 2, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 2, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "OTHER", .pins = &.{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 3, .y1 = 5.05, .x2 = 7, .y2 = 5.05, .l = 0, .w = 0.05, .net = "OTHER" });
    // The foreign track is intentionally under the board's 0.1 mm minimum, so
    // it contributes one stable baseline error before the bridge is considered.
    work.error_ceiling = try work.geometryErrors();
    try testing.expectEqual(@as(usize, 1), work.error_ceiling);

    // The bridge closes SIG, and costs the one error.
    const mark = work.tracks.items.len;
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .l = 0, .w = 0.127, .net = "SIG" });
    try testing.expectEqual(@as(usize, 2), try work.geometryErrors());
    try testing.expectEqual(@as(usize, 1), try work.islands(0));

    // Undeclared budget: the gate refuses the copper even though the net closes,
    // and leaves the ceiling where it was.
    try testing.expectEqual(Verdict.drc, try work.judge(0, 2));
    try testing.expectEqual(@as(usize, 1), work.error_ceiling);

    // A budget the resulting board still exceeds is no licence either — the
    // budget is an absolute ceiling, not permission to rise by one.
    work.error_budget = 1;
    try testing.expectEqual(Verdict.drc, try work.judge(0, 2));

    // Declared and sufficient: the same hop is kept, and the board it leaves
    // behind becomes the ceiling the next hop is measured against.
    work.error_budget = 2;
    try testing.expectEqual(Verdict.kept, try work.judge(0, 2));
    try testing.expectEqual(@as(usize, 2), work.error_ceiling);

    // The budget buys copper, never a free pass: a hop that does NOT close its
    // net is still rejected on connectivity, budget or no budget.
    work.tracks.shrinkRetainingCapacity(mark);
    try testing.expectEqual(Verdict.no_merge, try work.judge(0, 2));
}

// spec: Web Server - The close_open_nets accept gate rejects an independently-finished differential leg when it would increase coupling or skew warnings
test "close_open_nets rejects a finished differential leg that would be uncoupled" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Wider than the 0.127 mm pair legs so both endpoints establish the full
    // transverse land contact the connectivity gate now requires.
    const pad = @import("../placement/geometry.zig").Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "P1", .kind = .passive, .hw = 0.2, .hh = 0.2, .fallback = false, .x = 0, .y = 0, .pads = &.{pad} },
        .{ .ref_des = "P2", .kind = .passive, .hw = 0.2, .hh = 0.2, .fallback = false, .x = 10, .y = 0, .pads = &.{pad} },
        .{ .ref_des = "N1", .kind = .passive, .hw = 0.2, .hh = 0.2, .fallback = false, .x = 0, .y = 0.327, .pads = &.{pad} },
        .{ .ref_des = "N2", .kind = .passive, .hw = 0.2, .hh = 0.2, .fallback = false, .x = 10, .y = 0.327, .pads = &.{pad} },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "CLK_P", .pins = &.{ .{ .ref_des = "P1", .pin = "1" }, .{ .ref_des = "P2", .pin = "1" } } },
        .{ .name = "CLK_N", .pins = &.{ .{ .ref_des = "N1", .pin = "1" }, .{ .ref_des = "N2", .pin = "1" } } },
    };
    var placement = gapFixture(&parts, &nets);
    placement.diff_pairs = &.{.{ .p = 0, .n = 1, .gap = 0.2 }};
    var work = Work{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // P is already whole. N closes electrically, but spends almost its whole
    // run 2 mm away rather than beside P.
    try work.tracks.append(arena, .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .l = 0, .w = 0.127, .net = "CLK_P" });
    work.diff_ceiling = try work.diffWarnings();
    try testing.expectEqual(@as(usize, 0), work.diff_ceiling);
    try work.tracks.append(arena, .{ .x1 = 0, .y1 = 0.327, .x2 = 0, .y2 = 2, .l = 0, .w = 0.127, .net = "CLK_N" });
    try work.tracks.append(arena, .{ .x1 = 0, .y1 = 2, .x2 = 10, .y2 = 2, .l = 0, .w = 0.127, .net = "CLK_N" });
    try work.tracks.append(arena, .{ .x1 = 10, .y1 = 2, .x2 = 10, .y2 = 0.327, .l = 0, .w = 0.127, .net = "CLK_N" });
    try testing.expect((try work.diffWarnings()) > 0);
    try testing.expectEqual(Verdict.diff_pair, try work.judge(1, 2));
}

/// Three two-pad nets on one board: the net a hop is closing, plus two nets a
/// rip cascade can take copper out of.
fn cascadeParts() [6]optimizer.Part {
    const pad = @import("../placement/geometry.zig").Pad{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 };
    return .{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{pad} },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{pad} },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 2, .pads = &.{pad} },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 2, .pads = &.{pad} },
        .{ .ref_des = "R5", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 8, .pads = &.{pad} },
        .{ .ref_des = "R6", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 8, .pads = &.{pad} },
    };
}

// spec: Web Server - The close_open_nets accept gate holds every net a hop's rip cascade touched to no worse than it found it, not only the first victim
test "close_open_nets gate rejects a cascade that broke its SECOND victim" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = cascadeParts();
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "VIC1", .pins = &.{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } } },
        .{ .name = "VIC2", .pins = &.{ .{ .ref_des = "R5", .pin = "1" }, .{ .ref_des = "R6", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // Both victims start whole — one track each joins their two pads.
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 2, .x2 = 8, .y2 = 2, .l = 0, .w = 0.127, .net = "VIC1" });
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .l = 0, .w = 0.127, .net = "VIC2" });
    try work.growDead();
    // A cascade: the hop rips VIC1, and VIC1's repair rips VIC2 in turn.
    try work.noteVictims(&.{1}, 1, 0);
    try work.noteVictims(&.{2}, 1, 1);
    try testing.expectEqual(@as(u32, 2), work.victims.count());

    // VIC1 comes out whole (its repair re-routed it); VIC2 is left in pieces.
    work.dead[1] = true;
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 2, .x2 = 8, .y2 = 2, .l = 0, .w = 0.127, .net = "VIC1" });
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .l = 0, .w = 0.127, .net = "SIG" });

    // The first victim alone looks fine; the gate must still refuse, because a
    // hop may not pay for one net by quietly splitting a second.
    try testing.expectEqual(@as(usize, 1), try work.islands(1));
    try testing.expectEqual(@as(usize, 2), try work.islands(2));
    try testing.expectEqual(Verdict.broke_victim, try work.judge(0, 2));

    // Put VIC2 back and the identical hop is kept — the SECOND victim's state
    // is the only thing that changed.
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .l = 0, .w = 0.127, .net = "VIC2" });
    try testing.expectEqual(Verdict.kept, try work.judge(0, 2));
}

// spec: Web Server - A close_open_nets transaction treats a previously whole pour net split by newly added copper as a repair victim even when no track was ripped
test "close_open_nets detects a pour clipped by added copper as collateral" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        vacatePart("S1", 5, 0), vacatePart("S2", 5, 10),
        vacatePart("P1", 2, 5), vacatePart("P2", 8, 5),
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SIG", "S1", "S2"),
        vacateNet("POUR", "P1", "P2"),
    };
    var placement = gapFixture(&parts, &nets);
    const planes = [_]optimizer.PlaneAt{.{ .index = 1, .net = "POUR" }};
    // The pour sits on the TOP face and the hop below has to CUT it: whether a
    // 0.127 mm track severs the pour or leaves a channel around its ends turns
    // on the keepout width, so this face is pinned to the 0.3 mm gap an inner
    // plane defaults to rather than taking the tighter outer default.
    placement.rules = .{
        .design = .{ .pour = .{ .clearance_outer = 0.3 } },
        .plane_nets = &.{"POUR"},
        .copper_layers = 2,
        .planes = .{ .declared = &planes },
    };
    var work = Work{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.refreshWhole();
    try testing.expect(!work.whole[0]);
    try testing.expect(work.whole[1]);

    try work.applyHop(0, .{ .tracks = &.{.{
        .x1 = 5,
        .y1 = 0,
        .x2 = 5,
        .y2 = 10,
        .layer = 0,
        .width = 0.127,
        .net = 0,
    }} });
    work.victims.clearRetainingCapacity();
    work.victim_queue.clearRetainingCapacity();
    try work.noteCollateralVictims(0, 0);
    try testing.expectEqual(@as(u32, 1), work.victims.count());
    try testing.expectEqual(@as(?usize, 1), work.victims.get(1));
    try testing.expectEqual(@as(usize, 1), work.victim_queue.items.len);
    try testing.expectEqual(@as(usize, 1), work.victim_queue.items[0].net_i);
}

// spec: Web Server - A close_open_nets hop may only rip copper from a net that is currently whole, never from one the pass has still to close
test "close_open_nets refuses to rip a net that is itself still open" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = cascadeParts();
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "VIC1", .pins = &.{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } } },
        .{ .name = "VIC2", .pins = &.{ .{ .ref_des = "R5", .pin = "1" }, .{ .ref_des = "R6", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // VIC1 is whole. VIC2 is a stub that stops short of R6 — still open, still
    // the pass's own work to finish.
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 2, .x2 = 8, .y2 = 2, .l = 0, .w = 0.127, .net = "VIC1" });
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 8, .x2 = 5, .y2 = 8, .l = 0, .w = 0.127, .net = "VIC2" });
    try work.growDead();

    // A hop that bridges SIG by taking VIC1's whole copper is judged on its
    // merits — the copper lands and VIC1's repair gets its chance.
    const rip_whole = router.GapPath{
        .tracks = &.{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.127, .net = 0 }},
        .ripped = &.{0},
        .ripped_nets = &.{1},
    };
    try testing.expect(try work.tryHop(.{ .net_i = 0, .from = .{ .x = 2, .y = 5, .layer = 0 } }, rip_whole) != .broke_victim);

    // The identical hop paid for out of the STILL-OPEN net is refused outright,
    // and refused before it touches the board: no copper, no rip mark.
    const rip_open = router.GapPath{
        .tracks = &.{.{ .x1 = 2, .y1 = 6, .x2 = 8, .y2 = 6, .layer = 0, .width = 0.127, .net = 0 }},
        .ripped = &.{1},
        .ripped_nets = &.{2},
    };
    const tracks_before = work.tracks.items.len;
    try testing.expectEqual(Verdict.broke_victim, try work.tryHop(.{ .net_i = 0, .from = .{ .x = 2, .y = 5, .layer = 0 } }, rip_open));
    try testing.expectEqual(tracks_before, work.tracks.items.len);
    try testing.expect(!work.dead[1]);
}

// spec: Web Server - The close_open_nets pass reads its board back as live copper with an index map, so a rip reported against it lands on the board's own tracks
// spec: Web Server - Finishing restores saved RF regions for every connectivity and DRC check, protects them from ordinary rip-up, and maps arc chords back to their single saved owner
test "close_open_nets maps a rip reported against live copper back onto its own tracks" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = cascadeParts();
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "VIC1", .pins = &.{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } } },
        .{ .name = "VIC2", .pins = &.{ .{ .ref_des = "R5", .pin = "1" }, .{ .ref_des = "R6", .pin = "1" } } },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 2, .x2 = 4, .y2 = 2, .l = 0, .w = 0.127, .net = "VIC1" });
    try work.tracks.append(arena, .{ .x1 = 4, .y1 = 2, .x2 = 6, .y2 = 2, .l = 0, .w = 0.127, .net = "VIC1" });
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .l = 0, .w = 0.127, .net = "VIC2" });
    try work.growDead();
    // Track 1 is already ripped, so the live array the router is handed is
    // SHORTER than the board's and its indices are shifted.
    work.dead[1] = true;

    const live = (try work.liveCopper());
    try testing.expectEqual(@as(usize, 2), live.routes.tracks.len);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, live.map);

    // The router says "I ripped live track 1" — that is board track 2, VIC2's.
    const mapped = try work.mapRipped(&.{1}, live.map);
    try testing.expectEqualSlices(usize, &.{2}, mapped);

    // Untranslated, the mark would have landed on track 1 — VIC1's, a net the
    // hop never touched.
    try testing.expectEqualStrings("VIC2", work.tracks.items[mapped[0]].net);

    // And the rip-mark array is grown to cover copper the round has since laid,
    // so a mark on a fresh track cannot fall off the end and survive rollback.
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .l = 0, .w = 0.127, .net = "SIG" });
    _ = try work.mapRipped(&.{}, live.map);
    try testing.expectEqual(work.tracks.items.len, work.dead.len);
    work.tracks.items[0].xm = 3;
    work.tracks.items[0].ym = 3;
    const curved = (try work.liveCopper());
    try testing.expect(curved.routes.tracks.len > 3);
    try testing.expectEqual(curved.routes.tracks.len, curved.map.len);
    const last_victim = curved.map.len - 2;
    try testing.expectEqual(@as(usize, 2), curved.map[last_victim]);
    const remapped = try work.mapRipped(&.{ 0, 1, last_victim }, curved.map);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, remapped);

    // The batch judge must perform the same translation, not just the retry
    // helpers above. Rip one redundant victim row after an arc while closing
    // SIG; the other copy keeps the victim connected throughout the gate.
    work.tracks.shrinkRetainingCapacity(3);
    try work.tracks.append(arena, work.tracks.items[2]);
    try work.beginRound(null);
    const batch_live = (try work.liveCopper());
    const victim_chord = std.mem.indexOfScalar(usize, batch_live.map, 2).?;
    const batch_gaps = [_]router.Gap{.{
        .net_i = 0,
        .from = .{ .x = 2, .y = 5, .layer = 0 },
        .to = .{ .x = 8, .y = 5, .layer = 0 },
    }};
    var reasons = [_]router.GapReason{.routed};
    var verdicts = [_]?Verdict{null};
    var watch = HopWatch{
        .work = &work,
        .gaps = &batch_gaps,
        .map = batch_live.map,
        .last_ms = 0,
        .reasons = &reasons,
        .verdicts = &verdicts,
    };
    try testing.expect(HopWatch.keep(&watch, 0, .{
        .tracks = &.{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.127, .net = 0 }},
        .ripped = &.{victim_chord},
        .ripped_nets = &.{2},
    }));
    try testing.expect(work.dead[2]);
    try testing.expect(!work.dead[0]);
    try testing.expect(!work.dead[3]);

    // RF regions can connect pads without an ordinary constant-width track.
    work.tracks.clearRetainingCapacity();
    work.dead = &.{};
    work.rf_paths = &.{.{ .net = "SIG", .layer = 0, .samples = &.{
        .{ .at = .{ 2, 5 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 }, .{ .at = .{ 8, 5 }, .s_mm = 6, .curvature = 0, .width_mm = 0.2 },
    } }};
    try work.refreshWhole();
    try testing.expect(work.whole[0]);
    try testing.expectEqual(@as(usize, 1), (try work.copper()).rf_port_outcomes.len);
    try testing.expect(!Work.rippable(&work, 0, 1));
}

// ── Wholesale re-route phase ────────────────────────────────────────────────

/// A one-pad passive at `(x, y)` — the building block of the phase fixtures.
fn vacatePart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.3,
        .hh = 0.3,
        .fallback = false,
        .x = x,
        .y = y,
        .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }},
    };
}

/// A two-pad net over the two named parts. The names are `comptime` so the pin
/// array is a static const — built from runtime slices it would be a pointer to
/// this function's own stack frame.
fn vacateNet(
    comptime name: []const u8,
    comptime a: []const u8,
    comptime b: []const u8,
) export_kicad.FlatNet {
    return .{ .name = name, .pins = &.{ .{ .ref_des = a, .pin = "1" }, .{ .ref_des = b, .pin = "1" } } };
}

// spec: Web Server - The close_open_nets wholesale re-route never takes plane, pour, ground, RF, or diff-pair copper off the board
test "close_open_nets wholesale phase refuses to move guarded copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
        vacatePart("R3", 2, 6), vacatePart("R4", 8, 6),
        vacatePart("R5", 2, 7), vacatePart("R6", 8, 7),
        vacatePart("R7", 2, 8), vacatePart("R8", 8, 8),
        vacatePart("R9", 2, 9), vacatePart("RA", 8, 9),
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SIG", "R1", "R2"),
        vacateNet("GND", "R3", "R4"),
        vacateNet("RF_OUT", "R5", "R6"),
        vacateNet("D_P", "R7", "R8"),
        vacateNet("VBUS", "R9", "RA"),
    };
    var placement = gapFixture(&parts, &nets);
    // Index-aligned with `nets`: only RF_OUT carries a `(max-freq …)` rule.
    placement.rules.net = &.{ .{}, .{}, .{ .rf = .{ .max_freq_hz = 12e9 } }, .{}, .{} };
    placement.diff_pairs = &.{.{ .p = 3, .n = 3, .gap = 0.2 }};
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const zones = [_]pour.UserZone{.{ .net = "VBUS", .layer = 0, .poly = &poly }};
    var work = Work{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .zones = &zones,
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try testing.expect(work.movable(0)); // plain signal copper — fair game
    try testing.expect(!work.movable(1)); // ground
    try testing.expect(!work.movable(2)); // RF (max-freq)
    try testing.expect(!work.movable(3)); // diff-pair member
    try testing.expect(!work.movable(4)); // carried by a retained pour
}

// spec: Web Server - The close_open_nets wholesale re-route displaces only the whole nets whose copper crosses a still-open net's island-joining corridor
test "close_open_nets wholesale phase nominates only the whole copper across the corridor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5), // SEED, open, corridor y = 5
        vacatePart("R3", 5, 3), vacatePart("R4", 5, 7), // CROSS, whole, cuts the corridor
        vacatePart("R5", 2, 1), vacatePart("R6", 8, 1), // FAR, whole, 4 mm away
        vacatePart("R7", 6, 3), vacatePart("R8", 6, 7), // HALF, in the corridor but OPEN
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SEED", "R1", "R2"),
        vacateNet("CROSS", "R3", "R4"),
        vacateNet("FAR", "R5", "R6"),
        vacateNet("HALF", "R7", "R8"),
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = 3, .x2 = 5, .y2 = 7, .l = 0, .w = 0.127, .net = "CROSS" });
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 1, .x2 = 8, .y2 = 1, .l = 0, .w = 0.127, .net = "FAR" });
    // HALF's copper sits 1 mm off the corridor, but it reaches only half way to
    // its far pad — the net is in pieces, so it is the pass's own unfinished
    // work and not up for displacement.
    try work.tracks.append(arena, .{ .x1 = 6, .y1 = 3, .x2 = 6, .y2 = 4, .l = 0, .w = 0.127, .net = "HALF" });
    try work.refreshWhole();

    const blockers = try work.corridorBlockers(0, .standard);
    try testing.expectEqualSlices(usize, &.{1}, blockers);
    // …and the subset routes the seed before the copper it displaced.
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, try work.vacateSubset(0, blockers));
}

// spec: Web Server - The close_open_nets wholesale re-route asks for the seed's own hops before the hops of the copper it displaced
test "close_open_nets wholesale phase plans the seed's hops before its blockers'" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
        vacatePart("R3", 2, 2), vacatePart("R4", 3, 2),
    };
    const nets = [_]export_kicad.FlatNet{ vacateNet("SEED", "R1", "R2"), vacateNet("BLK", "R3", "R4") };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // Both nets are open (no copper at all), so both have a hop to ask for. The
    // seed's 6 mm hop is asked FIRST even though it is not the order a whole
    // round would take — BLK's 1 mm hop would otherwise spend the corridor.
    const gaps = try work.planFor(&.{ 0, 1 }, 1, 0);
    try testing.expectEqual(@as(usize, 2), gaps.len);
    try testing.expectEqual(@as(usize, 0), gaps[0].net_i);
    try testing.expectEqual(@as(usize, 1), gaps[1].net_i);
}

// spec: Web Server - The close_open_nets result names the nets a cheap-restore transaction vacated, what became of each, and the corridor copper it refused
test "close_open_nets reports a cheap transaction's decision trace" {
    var work = Work{
        .alloc = testing.allocator,
        .placement = undefined,
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    defer work.vacate_trace.deinit(testing.allocator);
    var picked = [_]VacatePick{
        .{ .net = "V_6VA", .kind = .pour_carried, .before = 44, .after = 42, .whole = true },
    };
    try work.vacate_trace.append(testing.allocator, .{
        .seed = "GND",
        .picked = &picked,
        .refused = &.{.{ .net = "V_5VA", .why = .over_budget }},
        .won = true,
    });
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeVacateTrace(&aw.writer, &work);
    const out = aw.written();
    // The seed, the verdict, each vacated net's restore outcome, and the reason
    // the corridor's other copper was left alone.
    try testing.expect(std.mem.indexOf(u8, out, "\"seed\":\"GND\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kept\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"why\":\"pour_carried\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"elements_before\":44") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"elements_after\":42") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"restored\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"why\":\"over_budget\"") != null);

    // A pass that never ran the tier emits nothing at all, so an existing
    // caller's payload is unchanged.
    work.vacate_trace.clearRetainingCapacity();
    var quiet: std.Io.Writer.Allocating = .init(testing.allocator);
    defer quiet.deinit();
    try writeVacateTrace(&quiet.writer, &work);
    try testing.expectEqual(@as(usize, 0), quiet.written().len);
}

// spec: Web Server - The close_open_nets wholesale re-route restores a plane-carried net by stitching it into its own pour before it will ask for a surface bridge
test "close_open_nets wholesale phase stitches a poured net before bridging it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
        vacatePart("R3", 2, 2), vacatePart("R4", 6, 2),
    };
    const nets = [_]export_kicad.FlatNet{ vacateNet("SEED", "R1", "R2"), vacateNet("BLK", "R3", "R4") };
    // A pour over R3's pad only, so BLK is plane-carried yet still in two
    // islands — exactly the state a displaced rail is in mid-transaction.
    const zones = [_]pour.UserZone{.{
        .net = "BLK",
        .layer = 0,
        .poly = &.{ .{ 1, 1 }, .{ 3, 1 }, .{ 3, 3 }, .{ 1, 3 } },
    }};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &zones,
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // Round 0 asks BLK for a plane STITCH and no surface bridge: a poured net
    // rejoins through its own copper, and a bridge here would lay metal back
    // across the channel the transaction just cleared. Round 1 is where its
    // bridge becomes available, if the stitch did not do the job.
    try testing.expectEqual(@as(usize, 0), bridgeHops(try work.planFor(&.{ 0, 1 }, 1, 0), 1));
    try testing.expectEqual(@as(usize, 1), bridgeHops(try work.planFor(&.{ 0, 1 }, 1, 1), 1));
}

/// How many of `gaps` are BRIDGES (a hop with a far pad) on net `net_i` — a
/// stitch carries no `to`. Lives outside the test block so the scan is not a
/// branch inside the assertion.
fn bridgeHops(gaps: []const router.Gap, net_i: usize) usize {
    var n: usize = 0;
    for (gaps) |g| {
        if (g.net_i == net_i and g.to != null) n += 1;
    }
    return n;
}

// spec: Web Server - The close_open_nets wholesale re-route holds the DRC ceiling at the pre-phase count so the copper it stripped may go back on
test "close_open_nets wholesale phase floors the DRC ceiling at the pre-phase count" {
    var work = Work{
        .alloc = testing.allocator,
        .placement = undefined,
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // Stripping whole nets drops the error count, and the ratchet follows it
    // down; without the floor the displaced copper could never come back.
    work.error_ceiling = 2;
    try testing.expectEqual(@as(usize, 2), work.errorCap());
    work.phase_floor = 6;
    try testing.expectEqual(@as(usize, 6), work.errorCap());
    // The floor never lowers a ceiling that is already higher, and it is gone
    // the moment the phase ends.
    work.error_ceiling = 9;
    try testing.expectEqual(@as(usize, 9), work.errorCap());
    work.phase_floor = null;
    try testing.expectEqual(@as(usize, 9), work.errorCap());
}

// spec: Web Server - The close_open_nets wholesale re-route restores the board byte-for-byte unless the set of open nets strictly shrank
test "close_open_nets wholesale phase restores the board when the seed stays open" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A retained GND land and barrel completely seal R1 on every layer, so
    // SEED can never close however much movable copper is removed. BLK sits
    // 1 mm off SEED's corridor and is whole, so it IS nominated and stripped:
    // the transaction runs in full and must still leave no trace. A sealed
    // terminal proves impossibility immediately instead of making this rollback
    // test repeat the fine-grid rescue behavior covered by the off-lattice test.
    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5),
        vacatePart("R2", 8, 5),
        vacatePart("R3", 2, 4),
        vacatePart("R4", 4, 4),
        .{
            .ref_des = "G1",
            .kind = .hub,
            .hw = 0.75,
            .hh = 0.75,
            .fallback = false,
            .x = 2,
            .y = 5,
            .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 1.5, .h = 1.5, .thru = true }},
        },
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SEED", "R1", "R2"),
        vacateNet("BLK", "R3", "R4"),
        .{ .name = "GND", .pins = &.{.{ .ref_des = "G1", .pin = "1" }} },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 4, .x2 = 4, .y2 = 4, .l = 0, .w = 0.127, .net = "BLK" });
    try work.vias.append(arena, .{ .x = 2, .y = 5, .d = 0.8, .drill = 0.4, .net = "GND" });
    const before = try arena.dupe(SavedTrack, work.tracks.items);
    const before_vias = try arena.dupe(SavedVia, work.vias.items);

    // One real wholesale transaction is sufficient to prove the rollback.
    // Exercising all four production ladder rungs here only repeats that same
    // invariant on an intentionally impossible board and dominated suite time.
    try testing.expect(!try work.vacateAt(0, router.gap_grid_divisor, .standard));
    try expectCopperUnchanged(&work, before, before_vias);
}

// spec: Web Server - The close_open_nets wholesale re-route leaves a seed still in more islands than its transaction could close alone, and strips nothing for it
test "close_open_nets wholesale phase leaves a many-island seed alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // SEED has six pads and no copper of its own — six islands, one more than
    // the transaction could ever put back in one go. CROSS still cuts its
    // corridor, so without the island cap the phase WOULD strip and re-route.
    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
        vacatePart("R3", 5, 3), vacatePart("R4", 5, 7),
        vacatePart("R5", 3, 5), vacatePart("R6", 4, 5),
        vacatePart("R7", 6, 5), vacatePart("R8", 7, 5),
    };
    const seed_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R5", .pin = "1" }, .{ .ref_des = "R6", .pin = "1" },
        .{ .ref_des = "R7", .pin = "1" }, .{ .ref_des = "R8", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SEED", .pins = &seed_pins },
        vacateNet("CROSS", "R3", "R4"),
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = 3, .x2 = 5, .y2 = 7, .l = 0, .w = 0.127, .net = "CROSS" });
    const before = try arena.dupe(SavedTrack, work.tracks.items);

    try testing.expectEqual(@as(usize, 6), try work.seedIslands(0));
    try testing.expect(!try work.vacateFor(0));
    try testing.expectEqual(before.len, work.tracks.items.len);
    for (before, work.tracks.items) |a, b| try testing.expect(std.meta.eql(a, b));
}

// spec: Web Server - The close_open_nets wholesale re-route retries a failed seed once on a finer gap grid, even when nothing was displaceable at the base pitch
test "close_open_nets wholesale phase closes an off-lattice corridor on the fine-grid rung" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A GND wall down x = 5 on both layers, slotted from y = 4.7425 to
    // y = 5.3225. The slot centre (5.0325) is a divisor-4 lattice line only:
    // the divisor-2 lanes (pitch 0.127 from oy = -1) land at 4.969 and 5.096,
    // each 0.2265 mm from a wall tip where the exact clearance test demands
    // 0.254 mm, and every diagonal between them passes closer still. GND is
    // ground copper, so `movable` refuses it — the standard rung has nothing
    // to displace and bails, and only the bare fine-grid retry can put SEED's
    // bridge through the slot.
    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5),
        vacatePart("R2", 8, 5),
        vacatePart("G1", 5, 9),
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SEED", "R1", "R2"),
        .{ .name = "GND", .pins = &.{.{ .ref_des = "G1", .pin = "1" }} },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = -2, .x2 = 5, .y2 = 4.7425, .l = 0, .w = 0.127, .net = "GND" });
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = 5.3225, .x2 = 5, .y2 = 12, .l = 0, .w = 0.127, .net = "GND" });
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = -2, .x2 = 5, .y2 = 4.7425, .l = 1, .w = 0.127, .net = "GND" });
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = 5.3225, .x2 = 5, .y2 = 12, .l = 1, .w = 0.127, .net = "GND" });

    try testing.expect(!work.movable(1));
    try testing.expect(try work.vacateFor(0));
    // The seed closed, and it closed with NEW copper — the wall is untouched.
    try testing.expect(work.tracks.items.len > 4);
    try testing.expect(!containsName(try work.openNetNames(), "SEED"));
}

// ── Joint (multi-seed) transactions ─────────────────────────────────────────

/// Two still-open seeds running parallel 6 mm corridors at y = 5 and y = 8,
/// with three whole one-track blockers around them:
///
///   * `LINK`  — a vertical run crossing BOTH corridors, so the two seeds
///     provably contend for the same copper and cluster.
///   * `A_ONLY`/`B_ONLY` — 0.5 mm off one corridor and 2.5 mm off the other, so
///     each is nominated by exactly one seed and NEITHER single-seed
///     transaction can ever reach the pair.
///   * `SOLO` — a third open net four millimetres away with its own private
///     blocker, which must not be swept into the cluster.
fn jointFixture(arena: std.mem.Allocator) std.mem.Allocator.Error!Work {
    const parts = try arena.dupe(optimizer.Part, &[_]optimizer.Part{
        vacatePart("A1", 2, 5),   vacatePart("A2", 8, 5),
        vacatePart("B1", 2, 8),   vacatePart("B2", 8, 8),
        vacatePart("L1", 5, 4),   vacatePart("L2", 5, 9),
        vacatePart("P1", 4, 5.5), vacatePart("P2", 6, 5.5),
        vacatePart("Q1", 4, 7.5), vacatePart("Q2", 6, 7.5),
        vacatePart("S1", 2, 1),   vacatePart("S2", 8, 1),
        vacatePart("T1", 4, 1.5), vacatePart("T2", 6, 1.5),
    });
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SEED_A", "A1", "A2"),
        vacateNet("SEED_B", "B1", "B2"),
        vacateNet("LINK", "L1", "L2"),
        vacateNet("A_ONLY", "P1", "P2"),
        vacateNet("B_ONLY", "Q1", "Q2"),
        vacateNet("SOLO", "S1", "S2"),
        vacateNet("SOLO_BLK", "T1", "T2"),
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(parts, try arena.dupe(export_kicad.FlatNet, &nets)),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 5, .y1 = 4, .x2 = 5, .y2 = 9, .l = 0, .w = 0.127, .net = "LINK" });
    try work.tracks.append(arena, .{ .x1 = 4, .y1 = 5.5, .x2 = 6, .y2 = 5.5, .l = 0, .w = 0.127, .net = "A_ONLY" });
    try work.tracks.append(arena, .{ .x1 = 4, .y1 = 7.5, .x2 = 6, .y2 = 7.5, .l = 0, .w = 0.127, .net = "B_ONLY" });
    try work.tracks.append(arena, .{ .x1 = 4, .y1 = 1.5, .x2 = 6, .y2 = 1.5, .l = 0, .w = 0.127, .net = "SOLO_BLK" });
    try work.refreshWhole();
    return work;
}

// spec: Web Server - The close_open_nets joint tier clusters only the still-open nets that provably contend for the same copper
test "close_open_nets clusters the seeds whose corridors share copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var work = try jointFixture(arena);

    const cluster = (try work.nextJointCluster(&.{})).?;
    // SEED_A and SEED_B share LINK; SOLO's corridor is 4 mm away and shares
    // nothing, so it is left for its own transaction.
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, cluster);
    // …and once they are spent there is no second cluster to form: SOLO is one
    // net, and one net is not a joint transaction.
    try testing.expectEqual(@as(?[]const usize, null), try work.nextJointCluster(cluster));
}

// spec: Web Server - A close_open_nets joint transaction vacates the union of its seeds' corridors, which no sequence of single-seed transactions can reach
test "close_open_nets joint blockers are the union of the cluster's corridors" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var work = try jointFixture(arena);

    // Each seed alone sees the shared LINK plus its own private neighbour…
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, try work.corridorBlockers(0, .cheap));
    try testing.expectEqualSlices(usize, &.{ 2, 4 }, try work.corridorBlockers(1, .cheap));
    // …and the joint transaction takes all three off the board at once. That
    // union is the move: no ordering of single-seed transactions ever has
    // A_ONLY and B_ONLY out of the way together.
    const joint = try work.jointBlockers(&.{ 0, 1 });
    try testing.expectEqualSlices(usize, &.{ 2, 3, 4 }, joint);
    // The seeds' own copper joins the strip set only when it is ours to move —
    // here both are plain signal nets, so both do, ahead of the blockers.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, try work.jointStripSet(&.{ 0, 1 }, joint));
}

// spec: Web Server - A close_open_nets joint transaction is re-tried with its seeds first, contending, and last, because a maze is first-claim-wins
test "the three joint orders sequence the cluster three ways" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var work = try jointFixture(arena);
    const seeds = [_]usize{ 0, 1 };
    const blockers = [_]usize{ 2, 3 };

    const first = try work.jointSequence(.seeds_first, &seeds, &blockers);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, first.nets);
    try testing.expectEqual(@as(usize, 2), first.lead); // both seeds claim first
    const mid = try work.jointSequence(.contended, &seeds, &blockers);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, mid.nets);
    try testing.expectEqual(@as(usize, 0), mid.lead); // one pool, pass order
    const last = try work.jointSequence(.seeds_last, &seeds, &blockers);
    try testing.expectEqualSlices(usize, &.{ 2, 3, 0, 1 }, last.nets); // blockers re-lay first
    try testing.expectEqual(@as(usize, 2), last.lead);
}

// spec: Web Server - The close_open_nets joint tier closes a cluster of contending nets in one transaction and puts the copper it displaced back
test "close_open_nets closes a contending cluster jointly" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var work = try jointFixture(arena);

    try testing.expectEqual(@as(usize, 2), try work.jointPhase());
    const open = try work.openNetNames();
    try testing.expect(!containsName(open, "SEED_A"));
    try testing.expect(!containsName(open, "SEED_B"));
    // Every net the transaction displaced came back whole — that is the gate,
    // not a side effect of it.
    try testing.expect(!containsName(open, "LINK"));
    try testing.expect(!containsName(open, "A_ONLY"));
    try testing.expect(!containsName(open, "B_ONLY"));
    // …and the tier reports what it moved, under the cluster's own name.
    try testing.expectEqual(@as(usize, 1), work.vacate_trace.items.len);
    try testing.expectEqualStrings("SEED_A + SEED_B", work.vacate_trace.items[0].seed);
    try testing.expect(work.vacate_trace.items[0].won);
}

// spec: Web Server - The close_open_nets joint tier is deterministic: the same board yields the same cluster, the same transaction and the same copper
test "close_open_nets joint tier is deterministic across runs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var a = try jointFixture(arena);
    var b = try jointFixture(arena);

    try testing.expectEqual(try a.jointPhase(), try b.jointPhase());
    try testing.expectEqual(a.tracks.items.len, b.tracks.items.len);
    try testing.expectEqual(a.vias.items.len, b.vias.items.len);
    for (a.tracks.items, b.tracks.items) |x, y| try testing.expect(std.meta.eql(x, y));
}

// spec: Web Server - A refused close_open_nets joint transaction restores the board byte-for-byte, dead-end memo included
test "close_open_nets restores the board when a joint transaction is refused" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Retained GND lands and barrels completely seal A1 and B1 on every layer,
    // so neither seed can close in any ordering. LINK sits within two
    // millimetres of both corridors, so it IS nominated and stripped: the
    // transaction runs in full and must still leave no trace. Sealed terminals
    // make the refusal immediate instead of re-running the separately covered
    // fine-grid rescue against an intentionally impossible wall.
    var parts = [_]optimizer.Part{
        vacatePart("A1", 2, 5),   vacatePart("A2", 8, 5),
        vacatePart("B1", 2, 8),   vacatePart("B2", 8, 8),
        vacatePart("L1", 2, 6.2), vacatePart("L2", 4, 6.2),
        .{
            .ref_des = "G1",
            .kind = .hub,
            .hw = 0.75,
            .hh = 0.75,
            .fallback = false,
            .x = 2,
            .y = 5,
            .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 1.5, .h = 1.5, .thru = true }},
        },
        .{
            .ref_des = "G2",
            .kind = .hub,
            .hw = 0.75,
            .hh = 0.75,
            .fallback = false,
            .x = 2,
            .y = 8,
            .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 1.5, .h = 1.5, .thru = true }},
        },
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SEED_A", "A1", "A2"),
        vacateNet("SEED_B", "B1", "B2"),
        vacateNet("LINK", "L1", "L2"),
        .{ .name = "A/GND", .pins = &.{.{ .ref_des = "G1", .pin = "1" }} },
        .{ .name = "B/GND", .pins = &.{.{ .ref_des = "G2", .pin = "1" }} },
    };
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 6.2, .x2 = 4, .y2 = 6.2, .l = 0, .w = 0.127, .net = "LINK" });
    try work.vias.append(arena, .{ .x = 2, .y = 5, .d = 0.8, .drill = 0.4, .net = "A/GND" });
    try work.vias.append(arena, .{ .x = 2, .y = 8, .d = 0.8, .drill = 0.4, .net = "B/GND" });
    try work.dead_ends.append(arena, .{ .net_i = 9, .fx = 1, .fy = 2, .tx = 3, .ty = 4 });
    const before = try arena.dupe(SavedTrack, work.tracks.items);
    const before_vias = try arena.dupe(SavedVia, work.vias.items);
    const memo = try arena.dupe(HopKey, work.dead_ends.items);

    // One real joint attempt proves the transaction's rollback contract. The
    // order/raster loop and its six-attempt cap are covered independently;
    // repeating an impossible maze six times added no state invariant here.
    const seeds = [_]usize{ 0, 1 };
    var budget = JointBudget{ .attempts_left = 1 };
    try testing.expect(!try work.jointVacate(&seeds, &budget));
    try testing.expectEqual(@as(usize, 0), budget.attempts_left);
    // Copper AND memo: the memo the transaction cleared as its first act is
    // back, so the next caller is not made to re-ask every hop this pass has
    // already refused — and so the three orders were compared against ONE board.
    try expectBoardUnchanged(&work, before, before_vias, memo);
}

/// Assert a rolled-back transaction left the board exactly as it found it —
/// every track, and the dead-end memo it cleared on the way in.
fn expectBoardUnchanged(work: *Work, tracks: []const SavedTrack, vias: []const SavedVia, memo: []const HopKey) !void {
    try expectCopperUnchanged(work, tracks, vias);
    try testing.expectEqual(memo.len, work.dead_ends.items.len);
    for (memo, work.dead_ends.items) |x, y| try testing.expect(x.eql(y));
}

/// Assert both kinds of routed copper are byte-for-byte unchanged.
fn expectCopperUnchanged(work: *Work, tracks: []const SavedTrack, vias: []const SavedVia) !void {
    try testing.expectEqual(tracks.len, work.tracks.items.len);
    for (tracks, work.tracks.items) |x, y| try testing.expect(std.meta.eql(x, y));
    try testing.expectEqual(vias.len, work.vias.items.len);
    for (vias, work.vias.items) |x, y| try testing.expect(std.meta.eql(x, y));
}

// spec: Web Server - The close_open_nets joint tier's cluster and attempt caps bound the whole call, not each cluster separately
test "the joint budget bounds clusters and attempts together" {
    var b = JointBudget{ .clusters_left = 3, .attempts_left = 2 };
    try testing.expect(b.takeCluster());
    try testing.expect(b.takeAttempt());
    try testing.expect(b.takeAttempt());
    try testing.expect(!b.takeAttempt()); // whole-pass attempt cap reached
    try testing.expect(!b.takeCluster()); // …which also stops handing out clusters
    // Every rung × order of one cluster fits inside the pass cap exactly once.
    try testing.expectEqual(max_joint_attempts, joint_rasters.len * joint_orders.len);
}

// spec: Web Server - Both rip-and-re-route tiers nominate through one shared seam, so the post-route tier sees exactly what the in-route tier's corridor sweep sees
test "the vacate tier's nomination is the shared corridor sweep" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var work = try jointFixture(arena);

    // What the tier nominates for SEED_A…
    var mine = nomination.Table{};
    try work.nominate(&mine, 0, (try work.boardView()).?);
    const got = try mine.ranked(arena);
    // …against the shared sweep called exactly as `joint_rescue` calls it: the
    // same hop, the same live copper, the same radius. One implementation, so
    // the two tiers can differ in what they may RIP but never in what they SEE.
    var theirs = nomination.Table{};
    try nomination.sweepHops(&theirs, arena, .{
        .net_i = 0,
        .hops = &.{.{ .ax = 2, .ay = 5, .bx = 8, .by = 5 }},
        .tracks = ((try work.copper())).tracks,
        .radius_mm = vacate_corridor_mm,
    });
    const want = try theirs.ranked(arena);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| {
        try testing.expectEqual(x.net_i, y.net_i);
        try testing.expectApproxEqAbs(x.dist, y.dist, 1e-12);
    }
}

// spec: Web Server - A close_open_nets hop every rip tier refused is re-asked once on a finer raster with no rip at all, and that last rung's diagnosis is the reported one
test "the last rung asks for a finer raster and no rip at all" {
    const gap = router.Gap{
        .net_i = 0,
        .from = .{ .x = 10, .y = 10, .layer = 0 },
        .to = .{ .x = 14, .y = 12, .layer = 0 },
    };
    const opts = Work.fineDirectOptions(gap, vacate_fine_divisor);
    // A hop that keeps failing as broke_victim/drc is not asking for a BIGGER
    // rip — it is asking for a route that needs none, and the standard raster
    // cannot see it. Measured on board-a's SPI_SCK: the divisor-2 lattice
    // offers only a ~24 mm line that tears adf4159/SPI_ADF_SDI_1V8 out and
    // cannot put it back, while a legal way round exists that costs no one.
    try std.testing.expect(!opts.ripup);
    try std.testing.expect(opts.raster.divisor > router.gap_grid_divisor);
    // The escape via has to be allowed on the terminal itself, or a sealed
    // fine-pitch pad has no exit for the finer raster to find.
    try std.testing.expectEqual(router.TerminalVia.smd_ok, opts.constraints.terminal_via);
    // …and it is BOUNDED to the hop's own corridor, which is what makes the
    // finer rung affordable at all (a board-wide divisor-8 raster was measured
    // at over 50 minutes for two nets and removed).
    const w = opts.raster.window orelse return std.testing.expect(false);
    try std.testing.expectApproxEqAbs(@as(f64, 10 - fine_corridor_margin_mm), w.x0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 14 + fine_corridor_margin_mm), w.x1, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10 - fine_corridor_margin_mm), w.y0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12 + fine_corridor_margin_mm), w.y1, 1e-9);
}

// spec: Web Server - The close_open_nets result reports the round loop's failures apart from the wholesale phase's own, and marks the ones whose transaction was rolled back
// spec: Web Server - Finishing reports round failures only for nets still open in the final physical tally
test "close_open_nets splits its round failures from the wholesale phase's" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &.{.{ .ref_des = "U1", .pin = "1" }} }};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // What the board-a call produced: the caller asked about GND, the round
    // loop failed on GND, and a rolled-back vacate transaction failed on two
    // nets the caller never named and that are not even open.
    try work.failures.append(arena, .{
        .net = "GND",
        .bridge = true,
        .x = 1,
        .y = 2,
        .verdict = .no_path,
        .phase = .round,
        .why = .exhausted,
    });
    try work.failures.append(arena, .{
        .net = "SPI_SCK",
        .bridge = true,
        .x = 3,
        .y = 4,
        .verdict = .no_path,
        .phase = .vacate,
        .rolled_back = true,
        .why = .blocked,
    });
    try work.failures.append(arena, .{
        .net = "V_1V8A",
        .bridge = true,
        .x = 5,
        .y = 6,
        .verdict = .no_merge,
        .phase = .vacate,
        .rolled_back = true,
        .why = .routed,
    });

    var round_out: std.Io.Writer.Allocating = .init(arena);
    try writeFailures(&round_out.writer, &work, .round, &.{"GND"});
    const round_json = round_out.written();
    // `failed[]` is the caller's answer: only the hop asked on the net they
    // named. A foreign net leaking in here is what made an agent act on a
    // diagnosis about copper that is neither open nor in scope.
    try testing.expect(std.mem.indexOf(u8, round_json, "\"GND\"") != null);
    try testing.expect(std.mem.indexOf(u8, round_json, "SPI_SCK") == null);
    try testing.expect(std.mem.indexOf(u8, round_json, "V_1V8A") == null);
    // Nothing in the round ledger is rolled back — those hops ran against the
    // board that was persisted.
    try testing.expect(std.mem.indexOf(u8, round_json, "rolled_back") == null);

    var vac_out: std.Io.Writer.Allocating = .init(arena);
    try writeFailures(&vac_out.writer, &work, .vacate, &.{"GND"});
    const vac_json = vac_out.written();
    // The phase's own churn is KEPT, not dropped — "the seed's blockers could
    // not all come back" is why the seed is still open — but it is labelled,
    // and each entry says its board was restored byte-for-byte.
    try testing.expect(std.mem.indexOf(u8, vac_json, "SPI_SCK") != null);
    try testing.expect(std.mem.indexOf(u8, vac_json, "V_1V8A") != null);
    try testing.expect(std.mem.indexOf(u8, vac_json, "\"GND\"") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, vac_json, "\"rolled_back\":true"));
    // Both arrays are still well-formed JSON arrays of objects.
    try testing.expect(round_json[0] == '[' and round_json[round_json.len - 1] == ']');
    try testing.expect(vac_json[0] == '[' and vac_json[vac_json.len - 1] == ']');
    var resolved: std.Io.Writer.Allocating = .init(arena);
    try writeFailures(&resolved.writer, &work, .round, &.{});
    try testing.expectEqualStrings("[]", resolved.written());
}

// spec: Web Server - Every close_open_nets failure carries the next thing worth trying, not just the verdict that rejected it
test "each failure verdict maps to an actionable remedy" {
    // Every non-kept verdict must say something; `kept` is not a failure.
    try std.testing.expect(remedyFor(.no_merge, .routed, false).len > 0);
    try std.testing.expect(remedyFor(.broke_victim, .routed, false).len > 0);
    try std.testing.expect(remedyFor(.drc, .routed, false).len > 0);
    try std.testing.expectEqualStrings("", remedyFor(.kept, .routed, false));
    // A no_path remedy is specific to what the MAZE ran into: a sealed pad is a
    // placement problem, a drained budget is a scoping one, and they must not
    // read the same.
    const sealed = remedyFor(.no_path, .sealed_from, false);
    const budget = remedyFor(.no_path, .exhausted, false);
    try std.testing.expect(sealed.len > 0 and budget.len > 0);
    try std.testing.expect(!std.mem.eql(u8, sealed, budget));
}

// spec: Web Server - A close_open_nets remedy never tells an already-scoped caller to narrow the job further
test "the drained-budget remedy changes once the call is already scoped" {
    // Unscoped, "route this net alone" is the right next move and names the arg.
    const open = remedyFor(.no_path, .exhausted, false);
    try std.testing.expect(std.mem.indexOf(u8, open, "nets") != null);
    // Scoped, that same sentence is a loop — the caller just made that call. The
    // remedy must hand off to a different KIND of move instead.
    const scoped = remedyFor(.no_path, .exhausted, true);
    try std.testing.expect(scoped.len > 0);
    try std.testing.expect(!std.mem.eql(u8, open, scoped));
    try std.testing.expect(std.mem.indexOf(u8, scoped, "add_tracks") != null);
    // Only this pairing is scope-sensitive; the others read the same either way,
    // because moving a part or freeing a corridor is the move regardless.
    try std.testing.expectEqualStrings(
        remedyFor(.no_path, .sealed_from, false),
        remedyFor(.no_path, .sealed_from, true),
    );
    try std.testing.expectEqualStrings(
        remedyFor(.drc, .routed, false),
        remedyFor(.drc, .routed, true),
    );
}

// spec: Web Server - A refused close_open_nets hop escalates through corridor-bounded fine rasters, coarsest first
test "the fine rungs go coarsest-first and all stay inside the hop's corridor" {
    try std.testing.expect(fine_divisors.len >= 2);
    try std.testing.expect(fine_divisors[0] < fine_divisors[1]);
    try std.testing.expectEqual(vacate_fine_divisor, fine_divisors[0]);
    const stitch = router.Gap{ .net_i = 0, .from = .{ .x = 5, .y = 5, .layer = 0 } };
    // A stitch has no far terminal: its corridor is a square around its pad.
    const w = router.GapWindow.around(stitch, fine_corridor_margin_mm);
    try std.testing.expectApproxEqAbs(w.x1 - w.x0, w.y1 - w.y0, 1e-9);
}

// spec: Web Server - A close_open_nets stitch is never planned for the island its plane or pour already carries
test "close_open_nets plans no stitch for the pour-joined island" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{.{
        .name = "PWR",
        .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } },
    }};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "R1", 0);
    try index.put(arena, "R2", 1);
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 2, .y = 5, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 8, .y = 5, .side = .top, .thru = false, .island = 1 },
    };
    // Island 0 is already joined to the pour: only island 1 may stitch.
    const joined = [_]bool{ true, false };
    const o = fab_readiness.OpenNet{ .net = "PWR", .islands = 2, .pads = &pads, .gaps = &.{}, .plane_joined = &joined };
    var gaps: std.ArrayList(router.Gap) = .empty;
    try work.addStitches(&gaps, &index, o, 0);
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectApproxEqAbs(@as(f64, 8), gaps.items[0].from.x, 1e-9);
}

// spec: Web Server - A close_open_nets round bridges a plane-carried net straight away when that round could plan it no stitch at all, so a call scoped to such a net is never a no-op
test "close_open_nets bridges a plane net in round 0 when it can plan no stitch" {
    // The rule the round loop asks: may this net's BRIDGES be planned now?
    // A plain signal net is bridged in every round.
    try testing.expect(bridgesNow(0, false, 0));
    // A plane-carried net that DID get stitches waits for round 1 — the stitch
    // is the cheaper rejoin and must not have its corridor spent by a bridge.
    try testing.expect(!bridgesNow(0, true, 2));
    // …but one the stitch pass could plan nothing for has no round-0 hop to
    // wait behind, so its bridges are asked immediately rather than a round
    // later — the round would otherwise be empty and end the whole pass.
    try testing.expect(bridgesNow(0, true, 0));
    // Past round 0 every open net is bridged regardless.
    try testing.expect(bridgesNow(1, true, 2));

    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // board-a's `GND` in miniature: a plane-carried net in two islands, and
    // BOTH of them already touch plane copper — separate pieces of metal that
    // each reach a plane the other does not. `addStitches` refuses every one of
    // them (a via there could only land in copper its island is already part
    // of), so the stitch pass plans nothing and the bridge is the only move.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 8, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{.{
        .name = "GND",
        .pins = &.{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } },
    }};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "U1", 0);
    try index.put(arena, "C1", 1);
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "U1", .pad = "1", .x = 2, .y = 5, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "C1", .pad = "1", .x = 8, .y = 5, .side = .top, .thru = false, .island = 1 },
    };
    const joined = [_]bool{ true, true };
    const closing = [_]fab_readiness.OpenGap{.{ .from = pads[0], .to = pads[1], .mm = 6 }};
    const o = fab_readiness.OpenNet{
        .net = "GND",
        .islands = 2,
        .pads = &pads,
        .gaps = &closing,
        .plane_joined = &joined,
    };
    var gaps: std.ArrayList(router.Gap) = .empty;
    try work.addStitches(&gaps, &index, o, 0);
    try testing.expectEqual(@as(usize, 0), gaps.items.len);
    // So round 0 must ask for the bridge, and there is one to ask for. Before
    // this rule the round planned nothing, `planRound` returned empty, and the
    // pass broke out of its round loop having tried nothing at all.
    try testing.expect(bridgesNow(0, true, gaps.items.len));
    try work.addBridges(&gaps, &index, o, 0);
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expect(gaps.items[0].to != null);
}

// spec: Web Server - A close_open_nets stitch island whose first pad is memoised dead is retried from its next pad
test "close_open_nets falls back to an island's next pad past a dead end" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 2, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.3, .hh = 0.3, .fallback = false, .x = 3, .y = 5, .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }} },
    };
    const nets = [_]export_kicad.FlatNet{.{
        .name = "PWR",
        .pins = &.{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } },
    }};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "U1", 0);
    try index.put(arena, "C1", 1);
    // Both pads share one island; U1.1's stitch already failed and was memoised.
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "U1", .pad = "1", .x = 2, .y = 5, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "C1", .pad = "1", .x = 3, .y = 5, .side = .top, .thru = false, .island = 0 },
    };
    const joined = [_]bool{false};
    const o = fab_readiness.OpenNet{ .net = "PWR", .islands = 1, .pads = &pads, .gaps = &.{}, .plane_joined = &joined };
    const dead_pt = padPoint(work.placement, &index, pads[0]).?;
    try work.dead_ends.append(arena, hopKey(.{ .net_i = 0, .from = dead_pt }));
    var gaps: std.ArrayList(router.Gap) = .empty;
    try work.addStitches(&gaps, &index, o, 0);
    // The island is not sealed by its first pad's dead end: C1.1 is asked.
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectApproxEqAbs(@as(f64, 3), gaps.items[0].from.x, 1e-9);
}

// spec: Web Server - A no-path bridge takes the fine corridor rescue only in the last few open nets, while a stitch always remains eligible
test "no-path bridge fine rescue is endgame-only" {
    const stitch = router.Gap{ .net_i = 0, .from = .{ .x = 5, .y = 5, .layer = 0 } };
    try std.testing.expect(!endgameBridgeFine(1, stitch, .blocked));
    const bridge = router.Gap{
        .net_i = 0,
        .from = .{ .x = 5, .y = 5, .layer = 0 },
        .to = .{ .x = 9, .y = 5, .layer = 0 },
    };
    try std.testing.expect(endgameBridgeFine(1, bridge, .blocked));
    try std.testing.expect(!endgameBridgeFine(global_detour_last_nets + 1, bridge, .blocked));
}

// spec: Web Server - close_open_nets folds a redundant same-net via onto the barrel already there, and restores the board when the fold makes it worse
test "close_open_nets folds a redundant same-net via and leaves the rest alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("SIG", "R1", "R2")};
    var work = Work{
        .alloc = arena,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    // A run that changes layer at (5,5), where a SECOND barrel of the same net
    // was planted 0.402 mm along — the measured board-a shape. Every track end
    // on the duplicate must come back to the barrel that was there first.
    try work.vias.append(arena, .{ .x = 5, .y = 5, .d = 0.4, .drill = 0.2, .net = "SIG" });
    try work.vias.append(arena, .{ .x = 5.402, .y = 5, .d = 0.4, .drill = 0.2, .net = "SIG" });
    try work.tracks.append(arena, .{ .x1 = 2, .y1 = 5, .x2 = 5, .y2 = 5, .l = 0, .w = 0.127, .net = "SIG" });
    try work.tracks.append(arena, .{ .x1 = 5.402, .y1 = 5, .x2 = 8, .y2 = 5, .l = 1, .w = 0.127, .net = "SIG" });

    try testing.expectEqual(@as(usize, 1), try work.foldRedundantVias());
    try testing.expectEqual(@as(usize, 1), work.vias.items.len);
    try testing.expectApproxEqAbs(@as(f64, 5), work.vias.items[0].x, 1e-12);
    try testing.expectEqual(@as(usize, 2), work.tracks.items.len);
    try testing.expectApproxEqAbs(@as(f64, 5), work.tracks.items[1].x1, 1e-12);
    // Idempotent: the board it leaves has nothing left to fold.
    try testing.expectEqual(@as(usize, 0), try work.foldRedundantVias());
    // A fence via is somebody else's statement about pitch, so a duplicate
    // tagged with its fenced net is left exactly where it is.
    try work.vias.append(arena, .{ .x = 5.402, .y = 5, .d = 0.4, .drill = 0.2, .net = "SIG", .f = "RF1" });
    try testing.expectEqual(@as(usize, 0), try work.foldRedundantVias());
    try testing.expectEqual(@as(usize, 2), work.vias.items.len);
}

// spec: Web Server - Finishing repairs exact same-face bypass intent on an already-connected rail without adding vias or breaking other authored bonds
test "close_open_nets repairs a surface bypass despite a closed remote via path" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    var parts = [_]optimizer.Part{ vacatePart("C1", 2, 5), vacatePart("U1", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("VDD", "C1", "U1")};
    var placement = gapFixture(&parts, &nets);
    placement.loops = &.{.{
        .cap = 0,
        .hub = 1,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .cap_gnd = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_pwr = &.{},
        .hub_gnd = &.{},
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .pwr_net = 0,
        .explicit_pin = "1",
    }};
    var work = Work{
        .alloc = a,
        .placement = placement,
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    try work.tracks.append(a, .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .l = 1, .w = 0.127, .net = "VDD" });
    try work.vias.append(a, .{ .x = 2, .y = 5, .d = 0.4, .drill = 0.2, .net = "VDD" });
    try work.vias.append(a, .{ .x = 8, .y = 5, .d = 0.4, .drill = 0.2, .net = "VDD" });
    const missing = try work.missingBypasses();
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqual(@as(usize, 1), try work.islands(0));
    work.error_ceiling = try work.geometryErrors();
    const before_tracks = work.tracks.items.len;
    // The board forbids the cap's surface: the repair must not override it.
    work.plan.net = &.{.{ .allowed_layers = 2 }};
    try testing.expectEqual(@as(usize, 0), try work.repairBypasses());
    try testing.expectEqual(before_tracks, work.tracks.items.len);
    work.plan.net = &.{};
    try testing.expectEqual(@as(usize, 1), try work.repairBypasses());
    try testing.expectEqual(@as(usize, 0), (try work.missingBypasses()).len);
    try testing.expectEqual(@as(usize, 2), work.vias.items.len);
    try testing.expectEqual(@as(usize, 1), try work.islands(0));
    try testing.expect(newBypassMissing(&.{}, missing));
    try testing.expect(!newBypassMissing(missing, &.{}));
    // Moving to the other face is a placement problem, never a via workaround.
    parts[0].side = .bottom;
    parts[1].side = .top;
    try testing.expectEqual(@as(usize, 0), try work.repairBypasses());
    try testing.expectEqual(@as(usize, 1), (try work.missingBypasses()).len);
}

// spec: Web Server - A via-limited poured rail joins surface islands before spending an insufficient stitch allowance
test "close_open_nets joins power islands before spending scarce vias" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    var parts = [_]optimizer.Part{ vacatePart("R1", 2, 5), vacatePart("R2", 8, 5) };
    const nets = [_]export_kicad.FlatNet{vacateNet("PWR", "R1", "R2")};
    const zones = [_]pour.UserZone{.{
        .net = "PWR",
        .layer = 1,
        .poly = &.{ .{ 1, 1 }, .{ 9, 1 }, .{ 9, 9 }, .{ 1, 9 } },
    }};
    var work = Work{
        .alloc = a,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &zones,
        .router_zones = try zoneSources(a, gapFixture(&parts, &nets), &zones),
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
        .plan = .{ .net = &.{.{ .max_vias = 1 }} },
    };
    work.error_ceiling = try work.geometryErrors();
    work.plan.net = &.{.{ .max_vias = 2 }};
    const ample = (try work.planRound(0)).gaps;
    try testing.expectEqual(@as(usize, 2), ample.len);
    try testing.expect(ample[0].to == null);
    work.plan.net = &.{.{ .max_vias = 1 }};
    const planned = try work.planRound(0);
    const gaps = planned.gaps;
    try testing.expectEqual(@as(usize, 1), gaps.len);
    try testing.expect(gaps[0].to != null and gaps[0].surface_only);
    const kept = try work.runRound(gaps, planned.open);
    try testing.expectEqual(@as(usize, 1), kept.hops);
    try testing.expectEqual(@as(usize, 0), work.vias.items.len);
    try testing.expectEqual(@as(usize, 0), try work.openNetCount());
    try testing.expectEqual(@as(usize, 0), try work.geometryErrors());
}

// spec: Web Server - A refused surface-only join does not memoize failure of an ordinary multilayer bridge
test "close_open_nets surface refusal leaves ordinary fallback eligible" {
    var work = Work{
        .alloc = testing.allocator,
        .placement = undefined,
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
    };
    defer work.dead_ends.deinit(testing.allocator);
    const ordinary = router.Gap{ .net_i = 0, .from = .{ .x = 2, .y = 5, .layer = 0 }, .to = .{ .x = 8, .y = 5, .layer = 0 } };
    var surface = ordinary;
    surface.surface_only = true;
    try work.dead_ends.append(testing.allocator, hopKey(surface));
    try testing.expect(work.deadEnd(surface));
    try testing.expect(!work.deadEnd(ordinary));
}

// spec: Web Server - A finishing round shares one full-board connectivity snapshot across planning and rip protection, then refreshes after copper changes
test "close_open_nets round snapshot preserves scoped protection and refreshes after edits" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    var parts = [_]optimizer.Part{
        vacatePart("R1", 2, 5), vacatePart("R2", 8, 5),
        vacatePart("R3", 2, 9), vacatePart("R4", 8, 9),
    };
    const nets = [_]export_kicad.FlatNet{
        vacateNet("SIG", "R1", "R2"), vacateNet("OTHER", "R3", "R4"),
    };
    var work = Work{
        .alloc = a,
        .placement = gapFixture(&parts, &nets),
        .params = .{},
        .zones = &.{},
        .router_zones = &.{},
        .rules = .{},
        .tracks = .empty,
        .vias = .empty,
        .only = &.{"SIG"},
    };
    const before = try work.planRound(0);
    try testing.expectEqual(@as(usize, 1), before.gaps.len);
    try testing.expectEqual(@as(usize, 2), before.open.len);
    const kept = try work.runRound(before.gaps, before.open);
    try testing.expectEqual(@as(usize, 1), kept.hops);
    // An unselected open net is still protected by the full-board snapshot.
    try testing.expect(!work.whole[0] and !work.whole[1]);
    try testing.expectEqual(@as(usize, 0), try work.geometryErrors());
    const after = try work.planRound(1);
    try testing.expectEqual(@as(usize, 0), after.gaps.len);
    try testing.expectEqual(@as(usize, 1), after.open.len);
    try work.beginRound(after.open);
    try testing.expect(work.whole[0] and !work.whole[1]);
    // Vacate changes copper before starting its round, so it must derive a
    // fresh snapshot rather than reusing the prior whole-net designation.
    work.tracks.clearRetainingCapacity();
    work.vias.clearRetainingCapacity();
    try work.beginRound(null);
    try testing.expect(!work.whole[0] and !work.whole[1]);
    try testing.expectEqual(@as(usize, 2), work.residual_open);
}
