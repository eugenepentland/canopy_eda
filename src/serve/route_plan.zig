//! The ONE `(pcb-plan (route …))` lowering seam every routing surface shares:
//! the `route_pcb` CLI commit path, `POST /api/pcb-route` (the viewer's Route
//! preview), the `/pcb-layout` page's `?route=1`, the PNG endpoint, and
//! `/api/pcb-describe`. Lowering in one place is what keeps preview == commit —
//! a wave's priority order and layer masks steer every fresh route identically,
//! never just the persisting one.
//!
//! It is also where every route's numbers are made HONEST. Each entry point
//! finishes through `gate` → `route_close.reconcile`, so `routed`/`total`/
//! `failed` are the connectivity oracle's answer rather than the router's own
//! attempt counters, and the short island-joining hops a batch route left open
//! are closed on the way out. One gate site is what stops two surfaces
//! reporting different completion for the same board.
//!
//! Deliberately NOT gated, because they do not report board state:
//!   * the route-review REPLAY (`route_review.zig`, `route_session_api.zig`) —
//!     it re-narrates what the ROUTER decided, so the router's own tally is the
//!     subject, not a defect; and
//!   * the placement optimizer's routed-rerank probe (`optimizer.zig`) — an
//!     inner-loop scoring heuristic that runs thousands of times, where a
//!     connectivity pass per candidate would be ruinous.

const std = @import("std");
const clock = @import("../infra/clock.zig");
// Residual-phase diagnostics (guided/joint/unblock accept-reject traces).
// Info level deliberately: these ~15 lines per timed route are the only
// visibility a ReleaseSafe binary has into the residual pipeline — debug
// level compiled them out exactly when the wide/pair tiers, which only fire
// at ReleaseSafe speed, needed diagnosing.
const routeLog = std.log.info;
const env_mod = @import("../eval/env.zig");
const optimizer = @import("../placement/optimizer.zig");
const module_policy = @import("../placement/module_policy.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const route_policy = @import("../placement/route_policy.zig");
const router = @import("../placement/router.zig");
const route_timing = @import("../placement/route_timing.zig");
const route_diagnose = @import("../placement/route_diagnose.zig");
const blocker_nomination = @import("../placement/blocker_nomination.zig");
const escape_assign = @import("../placement/escape_assign.zig");
const vacate_policy = @import("../placement/vacate_policy.zig");
const target_unblock = @import("../target_unblock.zig");
const rf_port_report = @import("../placement/rf_port_report.zig");
const route_close = @import("../placement/route_close.zig");
const pour = @import("../placement/pour.zig");
const export_gerber = @import("../export_gerber.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const fab_readiness = @import("../fab_readiness.zig");
const topo_lower = @import("../placement/topo_lower.zig");
const pad_neck_shape = @import("../pad_neck_shape.zig");
const route_copper_state = @import("../route_copper_state.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const net_name = @import("../net_name.zig");

/// Residual-cost tie tolerance: a candidate must beat the baseline by more
/// than this to count as better, so floating-point noise never flips a retry.
const cost_eps: f64 = 1e-6;

/// A lowered plan: the router options plus whether an authored plan applied
/// and how many selector warnings resolution produced (for result reporting).
pub const Lowered = struct {
    options: route_policy.Options = .{},
    applied: bool = false,
    warnings: usize = 0,
    /// What the global topology planner did, or null when no route wave carried
    /// `(topology)` and it never ran (see `topo_lower.merge`).
    topology: ?topo_lower.Stats = null,
};

/// The net-indexed router options from one plan resolution plus its
/// unresolved-selector warnings — the shared body of `lower` (which keeps only
/// the count) and `routeExperiment` (which echoes each warning to the caller).
const Resolved = struct {
    options: route_policy.Options,
    warnings: []const plan_resolve.Warning,
    topology: ?topo_lower.Stats = null,
};

/// One plan-lowering request: the spec to lower, the block it is judged
/// against, the placement it is resolved over, and whether the caller forces
/// global topology planning on every route wave for this run only
/// (`route_experiment`'s override — the authored `(topology)` needs no flag).
const Request = struct {
    spec: env_mod.PcbPlanSpec,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    force_topology: bool = false,
    zones: []const pour.UserZone = &.{},
};

/// Resolve `req.spec` against `req.placement` (module-policy read →
/// plan-resolve → routePolicies → topology merge) into net-indexed router
/// options plus the unresolved wave/class/net warnings. Pure and
/// request-local: reads nothing off disk, writes nothing.
fn resolveOptions(alloc: std.mem.Allocator, req: Request) std.mem.Allocator.Error!Resolved {
    var detected = try module_policy.analyze(alloc, req.placement);
    defer detected.deinit(alloc);
    const resolved = try plan_resolve.resolve(alloc, req.spec, .{
        .placement = req.placement,
        .net_class = detected.net_class,
        .part_role = detected.part_role,
        .modules = detected.modules,
        .net_class_specs = req.block.net_classes,
        .zones = req.zones,
    });
    var options = route_policy.Options{
        .net = try plan_resolve.routePolicies(alloc, resolved, req.placement, true),
        .effort = effortOf(req.spec.effort),
        .stop = .{ .max_route_ms = routeBudgetMs(req.spec.max_route_seconds) },
        // Soft lane guides from any `(assign-escapes …)` wave, plus the HARD
        // lanes from any wave that also authored `(reserve)` — one bundle, so
        // the two halves of one assignment cannot be handed over apart. Empty
        // for every plan without the form, so those designs route unchanged.
        .guides = .{ .tracks = resolved.escape_guides, .reserved = resolved.escape_reserved },
    };
    // Topology planning is part of routing, not untimed setup. Arm the one
    // board deadline before `topo_lower.merge`: the router receives the same
    // absolute timestamp afterwards and therefore spends only the remainder.
    // Without this seam a 30 s planner followed by a 270 s router made an
    // authored five-minute ceiling take more than five minutes in production.
    armDeadline(&options);
    // The ONE site the global topology planner is wired to. A no-op (and a null
    // result) unless a route wave carries `(topology)`, so a plan without the
    // form hands the router byte-identical options.
    const topology = try topo_lower.merge(alloc, .{
        .plan = resolved,
        .placement = req.placement,
        .force = req.force_topology,
    }, &options);
    return .{ .options = options, .warnings = resolved.warnings, .topology = topology };
}

/// Map the authored `(route (effort …))` onto the router's own enum. Absent
/// keeps the router's default, so a design that never mentions effort routes
/// exactly as it did before the form existed.
fn effortOf(authored: ?env_mod.PlanEffort) route_policy.Effort {
    return switch (authored orelse return .standard) {
        .one_shot => .one_shot,
        .standard => .standard,
    };
}

fn routeBudgetMs(seconds: ?u32) u64 {
    return @as(u64, seconds orelse return 0) * 1000;
}

fn armDeadline(options: *route_policy.Options) void {
    if (options.stop.deadline_ns != 0 or options.stop.max_route_ms == 0) return;
    options.stop.deadline_ns = clock.nanoTimestamp() +
        @as(i128, @intCast(options.stop.max_route_ms)) * @as(i128, clock.ns_per_ms);
}

fn routeStopped(options: route_policy.Options) bool {
    if (options.stop.cancel) |flag| if (flag.load(.monotonic)) return true;
    return options.stop.deadline_ns != 0 and clock.nanoTimestamp() >= options.stop.deadline_ns;
}

/// The lowered router options for a block's authored plan PLUS the resolved
/// route waves they came from — one resolution, so a caller that must BOTH
/// route with the plan and name the wave each net's priority came from
/// (`route_order_search`'s DSL suggestion) can never have the two disagree.
pub const LoweredWaves = struct {
    options: route_policy.Options = .{},
    waves: []const plan_resolve.ResolvedWave = &.{},
};

/// `lower`'s sibling that also returns the resolved wave list. A design with no
/// authored `(pcb-plan …)` gets the SYNTHESIZED default plan here (rather than
/// `lower`'s empty options), because a caller asking which wave a net sits in
/// needs the plan the router would actually use, not silence.
pub fn lowerWithWaves(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!LoweredWaves {
    var detected = try module_policy.analyze(alloc, placement);
    defer detected.deinit(alloc);
    const resolved = try plan_resolve.resolve(alloc, block.pcb_plan, .{
        .placement = placement,
        .net_class = detected.net_class,
        .part_role = detected.part_role,
        .modules = detected.modules,
        .net_class_specs = block.net_classes,
    });
    return .{
        .options = .{
            .net = try plan_resolve.routePolicies(alloc, resolved, placement, block.pcb_plan != null),
            .effort = effortOf(if (block.pcb_plan) |p| p.effort else null),
            .stop = .{ .max_route_ms = routeBudgetMs(if (block.pcb_plan) |p| p.max_route_seconds else null) },
        },
        .waves = resolved.route,
    };
}

/// Resolve and lower the block's authored PCB plan for `placement`. A design
/// with no `(pcb-plan …)` form returns empty options so legacy designs keep
/// their route order and layer costs exactly.
pub fn lower(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!Lowered {
    const spec = block.pcb_plan orelse return .{};
    const r = try resolveOptions(alloc, .{ .spec = spec, .block = block, .placement = placement });
    return .{
        .options = r.options,
        .applied = true,
        .warnings = r.warnings.len,
        .topology = r.topology,
    };
}

/// The read-only surfaces' spelling: an allocation failure during lowering
/// degrades to empty options rather than failing the preview/describe request.
pub fn lowerOrEmpty(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
) route_policy.Options {
    const lowered = lower(alloc, block, placement) catch return .{};
    return lowered.options;
}

/// Route `placement` fresh with the block's authored plan applied — the
/// one-call spelling for the read-only surfaces (page ?route=1, PNG,
/// describe, POST /api/pcb-route). Identical to `route_pcb`'s commit path
/// modulo scoped-net selection.
pub fn routePlanned(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
) std.mem.Allocator.Error!router.RouteResult {
    return routePlannedZones(alloc, block, placement, params, &.{});
}

/// `routePlanned` seeded with retained copper zones — hand-drawn user copper
/// pours (source copper the maze grows from) and keepouts. Empty `zones` is
/// byte-identical to `routePlanned`, so legacy designs route unchanged.
pub fn routePlannedZones(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    zones: []const route_policy.ExistingZone,
) std.mem.Allocator.Error!router.RouteResult {
    return routePlannedZonesTimed(alloc, block, placement, params, zones, null);
}

/// `routePlannedZones` with optional per-phase wall-clock instrumentation
/// (the whole-corpus benchmark arms one timer per board; every production
/// caller passes null and pays nothing).
pub fn routePlannedZonesTimed(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    zones: []const route_policy.ExistingZone,
    timing: ?*route_timing.PhaseTimer,
) std.mem.Allocator.Error!router.RouteResult {
    var options = lowerOrEmpty(alloc, block, placement);
    options.existing_zones = zones;
    options.timing = timing;
    return routeLowered(alloc, placement, params, options);
}

/// Route with options a caller already lowered, then gate the result. The
/// spelling for a surface that builds its own `route_policy.Options` (the
/// `route_pcb` CLI commit path scopes and seeds copper before routing) but must
/// still report the same `routed` count as every other surface.
pub fn routeLowered(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
) std.mem.Allocator.Error!router.RouteResult {
    var run_options = options;
    armDeadline(&run_options);
    const first = try routeLoweredCandidate(alloc, placement, params, run_options);
    return finishLoweredCandidate(alloc, placement, params, run_options, first);
}

/// Route and gate one candidate without the field's residual finishing pass.
/// Candidate competitions (the hierarchical-seed A/B) use this for each arm,
/// select one board, then call `finishLoweredCandidate` once on the winner.
pub fn routeLoweredCandidate(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
) std.mem.Allocator.Error!router.RouteResult {
    var run_options = options;
    armDeadline(&run_options);
    run_options = try withTimedWaypointSeeds(alloc, placement, params, run_options);
    const raw = try router.routeWithOptions(alloc, placement, params, try initialPassOptions(alloc, run_options));
    if (raw.cancelled) return route_copper_state.reconcile(alloc, placement, raw, try retainedZones(alloc, placement, run_options));
    return (try gate(alloc, placement, params, raw, run_options)).result;
}

const waypoint_seed_budget_ns: i128 = 45 * clock.ns_per_s;

fn broadWaypointSeedMask(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
) std.mem.Allocator.Error!?[]bool {
    if (options.stop.deadline_ns == 0 or options.selected_nets.len != 0 or
        options.existing_tracks.len != 0 or options.existing_vias.len != 0) return null;
    const selected = try alloc.alloc(bool, placement.nets.len);
    @memset(selected, false);
    var count: usize = 0;
    for (selected, 0..) |*yes, net_i| {
        if (net_i >= options.net.len or options.net[net_i].waypoints.len == 0) continue;
        yes.* = true;
        count += 1;
    }
    return if (count == 0) null else selected;
}

/// Preserve the proven bounded breadth strategy: ordinary authored waypoint
/// nets get one short first claim, and only their complete, DRC-safe copper is
/// frozen for the broad pass. Repair-only `(seed-first)` corridors are excluded
/// here and run after the connectivity oracle identifies the residual instead.
fn withTimedWaypointSeeds(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
) std.mem.Allocator.Error!route_policy.Options {
    const selected = try broadWaypointSeedMask(alloc, placement, options) orelse return options;
    var seed_options = options;
    seed_options.effort = .one_shot;
    seed_options.selected_nets = selected;
    seed_options.stop.max_route_ms = 0;
    seed_options.stop.deadline_ns = @min(
        options.stop.deadline_ns,
        clock.nanoTimestamp() + waypoint_seed_budget_ns,
    );
    const raw = try router.routeWithOptions(alloc, placement, params, seed_options);

    // The slice may expire with useful completed seeds already synthesized.
    // Gate them under the parent deadline, remove every still-open fragment,
    // and hand only the proven remainder to the broad route as retained copper.
    var gate_options = seed_options;
    gate_options.stop = options.stop;
    var seeded = (try gate(alloc, placement, params, raw, gate_options)).result;
    seeded = try stripGeneratedFailures(alloc, placement, gate_options, selected, seeded);

    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (seeded.tracks) |track| try tracks.append(alloc, trackAsExisting(track));
    for (seeded.vias) |via| try vias.append(alloc, viaAsExisting(via));
    var out = options;
    out.existing_tracks = try tracks.toOwnedSlice(alloc);
    out.existing_vias = try vias.toOwnedSlice(alloc);
    return out;
}

fn waypointSeedMask(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
) std.mem.Allocator.Error!?[]bool {
    if (options.selected_nets.len != 0 or options.existing_tracks.len != 0 or
        options.existing_vias.len != 0) return null;
    const selected = try alloc.alloc(bool, placement.nets.len);
    @memset(selected, false);
    var count: usize = 0;
    for (selected, 0..) |*yes, net_i| {
        if (net_i >= options.net.len or !options.net[net_i].wave.seed_first or
            options.net[net_i].wave.repair_waypoints.len == 0) continue;
        yes.* = true;
        count += 1;
    }
    return if (count == 0) null else selected;
}

fn initialPassOptions(
    _: std.mem.Allocator,
    options: route_policy.Options,
) std.mem.Allocator.Error!route_policy.Options {
    var initial = options;
    if (options.effort.retries() and
        (options.stop.max_route_ms != 0 or options.stop.deadline_ns != 0) and
        options.guides.route_space.fieldAllocator() == null)
    {
        initial.effort = .one_shot;
    }
    return initial;
}

/// Apply the route-space-specific finishing policy to a selected, already-gated
/// candidate. Lattice output and one-shot/cancelled runs remain byte-identical.
pub fn finishLoweredCandidate(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    first: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    if (first.cancelled) return first;
    if (routeStopped(options)) {
        var stopped = first;
        stopped.cancelled = true;
        return stopped;
    }
    const converged = if (!options.effort.retries() or first.failed.len == 0)
        first
    else
        try finishLoweredResidual(alloc, placement, params, options, first);
    // THE board's one topology prune, spent here and nowhere else: after the
    // residual ladder has stopped gaining. Cleanup is cosmetic, so it must not
    // run while the functional phases are still working — a prune inside a
    // ladder pass rewrites the copper the next pass plans against, and the DRC
    // ratchet sitting behind each gate turns any rule its removals trip into a
    // whole net dropped. It also buys back the per-pass whole-board scans.
    if (converged.cancelled or routeStopped(options)) return converged;
    const pruned = try pruneGateTopology(alloc, placement, params, converged, options);
    // A DRC gate can drop a normally finished net and let the residual ladder
    // reconnect it with a plain centreline. That late rescue happens after the
    // router's own pad-neck/output adapter, so make the final assembled board
    // pass the same seam once more. Caller-owned retained copper is immutable.
    const mutable = try alloc.alloc(bool, placement.nets.len);
    for (mutable, 0..) |*slot, net_i| {
        const in_scope = options.selected_nets.len == 0 or
            (net_i < options.selected_nets.len and options.selected_nets[net_i]);
        slot.* = in_scope and !retainedNetCopper(options, net_i);
    }
    const tapered = try pad_neck_shape.finishExactRfTapers(alloc, placement, mutable, pruned);

    // This seam is deliberately after the route gate, so it must uphold that
    // gate's contract itself. A pad flare that cannot clear a neighbouring
    // ground land falls back to the already-proven uniform route, exactly as
    // the hand router's taper fitter does; a geometry overlay must never turn
    // a green routed board red on persistence.
    const bad = try alloc.alloc(bool, placement.nets.len);
    @memset(bad, false);
    const findings = try ratchetFindings(alloc, placement, params, tapered, options);
    for (findings) |finding| {
        if (finding.severity != .err and finding.kind != .implicit_junction) continue;
        const candidates = candidateNets(placement, options, finding);
        for (candidates.items[0..candidates.len]) |net_i| {
            if (mutable[net_i]) bad[net_i] = true;
        }
    }
    const zones = try route_close.userZones(alloc, placement, options.existing_zones);
    const tally = try fab_readiness.routableTally(alloc, placement, .{
        .tracks = tapered.tracks,
        .arcs = tapered.arcs,
        .rf_paths = tapered.rf_port_outcomes,
        .vias = tapered.vias,
        .zones = zones,
    });
    for (tally.open) |name| {
        if (netIndexOf(placement, name)) |net_i| {
            if (mutable[net_i]) bad[net_i] = true;
        }
    }
    if (!anyTrue(bad)) return tapered;
    return rollbackTaperNets(alloc, bad, pruned, tapered);
}

fn rollbackTaperNets(
    alloc: std.mem.Allocator,
    bad: []const bool,
    baseline: router.RouteResult,
    candidate: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    var arcs: std.ArrayList(router.Arc) = .empty;
    var sharp: std.ArrayList(router.SharpBend) = .empty;
    var outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    for (candidate.tracks) |track| if (!selectedNet(bad, track.net)) try tracks.append(alloc, track);
    for (baseline.tracks) |track| if (selectedNet(bad, track.net)) try tracks.append(alloc, track);
    for (candidate.vias) |via| if (!selectedNet(bad, via.net)) try vias.append(alloc, via);
    for (baseline.vias) |via| if (selectedNet(bad, via.net)) try vias.append(alloc, via);
    for (candidate.arcs) |arc| if (!selectedNet(bad, arc.net)) try arcs.append(alloc, arc);
    for (baseline.arcs) |arc| if (selectedNet(bad, arc.net)) try arcs.append(alloc, arc);
    for (candidate.sharp_bends) |bend| if (!selectedNet(bad, bend.net)) try sharp.append(alloc, bend);
    for (baseline.sharp_bends) |bend| if (selectedNet(bad, bend.net)) try sharp.append(alloc, bend);
    for (candidate.rf_port_outcomes) |outcome| if (!selectedNet(bad, outcome.net)) try outcomes.append(alloc, outcome);
    // The baseline path is the geometry the route gate already proved. It may
    // also own a compact under-nominal edit handle; dropping that metadata
    // would expose the handle as fabricated copper and create a false width
    // error even though the rollback restored the original board.
    for (baseline.rf_port_outcomes) |outcome| if (selectedNet(bad, outcome.net)) try outcomes.append(alloc, outcome);
    var out = candidate;
    out.tracks = try tracks.toOwnedSlice(alloc);
    out.vias = try vias.toOwnedSlice(alloc);
    out.arcs = try arcs.toOwnedSlice(alloc);
    out.sharp_bends = try sharp.toOwnedSlice(alloc);
    out.rf_port_outcomes = try outcomes.toOwnedSlice(alloc);
    out.routed = baseline.routed;
    out.total = baseline.total;
    out.failed = baseline.failed;
    return out;
}

fn finishLoweredResidual(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    first: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    const t0 = clock.nanoTimestamp();
    return switch (options.guides.route_space) {
        .lattice => lattice: {
            // The aggregate field-cluster retry is deliberately absent here:
            // across every logged timed lattice run it reported "no strict
            // connectivity gain" while costing ~25 s the per-target unblock
            // transactions were starving for. The field route-space keeps it.
            routeLog("residual timeline: enter with {d} failed", .{first.failed.len});
            // The tail the LAST phase needs, taken off the two phases ahead of
            // it before either starts spending (see `unblockReserveNs`).
            const head_options = headOptions(options, unblockReserveNs(alloc, placement, options, first) catch 0);
            // Gates BEFORE the guided corridors. The ladder is the phase that
            // closes nets on a timed board — every logged barracuda run has it
            // gaining and the guided retries reporting "slice expired" for all
            // four targets — and running it second meant its last pass was the
            // one the reserve boundary cut off, mid-rail. Ordered this way the
            // ladder runs until it stops gaining, and the corridor retries take
            // what is left rather than the other way round.
            var best = first;
            // ONE memory for the whole residual, not just for the ladder. The
            // ladder fills it with this route's terminal geometry verdicts, and
            // the guided phase behind it reads them to skip the nets its slices
            // cannot help (`retryLatticeGuided`'s seal check) — so the two
            // phases share one record of what this board has already answered
            // rather than the second one re-discovering it a slice at a time.
            var memo = route_close.HopMemo.init(alloc);
            defer memo.deinit();
            const repeated = repeatLatticeGate(alloc, placement, params, head_options, first, &memo) catch first;
            routeLog("residual timeline: gates done +{d}ms, {d} failed", .{ phaseMs(t0), repeated.failed.len });
            best = keepBestBoard(best, repeated, "gate ladder");
            const guided = retryLatticeGuided(alloc, placement, params, head_options, best, &memo) catch best;
            routeLog("residual timeline: guided done +{d}ms, {d} failed", .{ phaseMs(t0), guided.failed.len });
            best = keepBestBoard(best, guided, "guided corridors");
            const finished = unblockPhase(alloc, placement, params, options, best) catch best;
            routeLog("residual timeline: unblock done +{d}ms, {d} failed", .{ phaseMs(t0), finished.failed.len });
            break :lattice keepBestBoard(best, finished, "target unblock");
        },
        .field => field: {
            var best = first;
            const residual = retryFieldResidual(alloc, placement, params, options, first) catch first;
            best = keepBestBoard(best, residual, "field residual");
            const clustered = retryFieldCluster(alloc, placement, params, options, best) catch best;
            best = keepBestBoard(best, clustered, "field cluster");
            const finished = unblockPhase(alloc, placement, params, options, best) catch best;
            break :field keepBestBoard(best, finished, "target unblock");
        },
    };
}

/// The residual's checkpoint: a phase may keep only a board at least as
/// connected as the best one this route has already held.
///
/// Every residual phase has its own commit rule and each is monotone on its own
/// terms, which is not the same as the ROUTE being monotone: a phase that
/// cancels mid-flight, one whose error path hands back a partly-finished board,
/// and a gate whose DRC ratchet drops a net a previous phase closed all return
/// a legal board that is simply worse than one the pipeline was holding an hour
/// of CPU ago. Measured on barracuda (ReleaseSafe, v93): a gate pass reported
/// `10 -> 5 failed` mid-run and the route shipped ten open nets.
///
/// So the pipeline carries its best board forward and hands the next phase THAT
/// board to improve, rather than whatever the last phase happened to return.
/// The successor's `cancelled` flag is always adopted — that is a fact about the
/// clock, not about the copper, and the caller reads it to know the run stopped
/// early.
fn keepBestBoard(
    best: router.RouteResult,
    next: router.RouteResult,
    phase: []const u8,
) router.RouteResult {
    if (!boardRegressed(best, next)) return next;
    routeLog("route checkpoint: {s} left {d} net(s) open, restoring the {d} the route already held", .{
        phase,
        next.failed.len,
        best.failed.len,
    });
    var kept = best;
    kept.cancelled = next.cancelled;
    return kept;
}

/// Did `next` come back LESS connected than `best`?
///
/// Read off the oracle's own tally, which every gated board carries: `routed`
/// out of the same `total`. A board measured against a different total is not
/// comparable (a scoped run counts a different denominator), so it is never
/// judged a regression — the checkpoint's job is to refuse a loss it can prove,
/// not to prefer one reading over another.
fn boardRegressed(best: router.RouteResult, next: router.RouteResult) bool {
    if (next.total != best.total) return false;
    return next.routed < best.routed;
}

fn phaseMs(t0: i128) i64 {
    return @intCast(@divTrunc(clock.nanoTimestamp() - t0, clock.ns_per_ms));
}

const lattice_gate_passes: usize = 8;
/// Widened from 15 s once the unblock phase existed (at 15 s the per-target
/// transactions each got a ~1 s slice and reported "no candidate"), then pulled
/// back from 45 s: across every logged barracuda run the unblock phase reported
/// "no candidate within its slice" for every target while the gate ladder — the
/// phase that was actually closing rails — was cut off mid-pass by this reserve.
const lattice_gate_tail_reserve_ns: i128 = 15 * clock.ns_per_s;
/// Halved from 7 s: five corridors at 7 s spent 36 s per board and closed
/// nothing across every logged run — the unblock transactions the freed time
/// funds retry the same authored corridors WITH rip-up authority.
const lattice_guided_slice_ns: i128 = 4 * clock.ns_per_s;

/// Re-plan additive joins after each accepted connectivity change. One oracle
/// pass can join only the gaps visible in its initial graph; joining two rail
/// islands often makes a different pad the nearest legal anchor for the next
/// leg. Every pass is a FULL gate — canonicalized, topology-pruned, DRC
/// victim-dropped — and retained only on strict pad-island gain. A lean
/// (reconcile-only) variant was tried and reverted: raw lean copper
/// accumulated junction forms the finishing full gate's DRC pass then blamed
/// on whole nets, so rails the passes had closed (V_3V3_LMX, V_5VA) came back
/// OPEN when their copper was victim-dropped at the end. The per-pass cost is
/// carried instead by the planner efficiencies (the shared refusal memo below,
/// cheapest-net-first ordering, and the reconcile slice).
fn repeatLatticeGate(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    first: router.RouteResult,
    memo: *route_close.HopMemo,
) std.mem.Allocator.Error!router.RouteResult {
    var baseline = first;
    var pass_options = options;
    if (pass_options.stop.deadline_ns > lattice_gate_tail_reserve_ns)
        pass_options.stop.deadline_ns -= lattice_gate_tail_reserve_ns;
    // The memory is the caller's (see `finishLoweredCandidate`), because every
    // pass re-plans from the oracle's island report — without it a net whose
    // hops all fail asks for exactly the same refused hops again in every later
    // pass — and because the phase BEHIND this one reads the same record.
    var pass: usize = 0;
    // The ladder's last pass, spent only once the ordinary ones have stopped
    // gaining: a long hop may search a corridor wide enough to detour, which is
    // copper no remaining plan can be blocked by (see `corridor_span_share`).
    var wide = false;
    while (pass < lattice_gate_passes and baseline.failed.len > 0) : (pass += 1) {
        if (routeStopped(pass_options)) return baseline;
        const candidate = (try gateConfigured(alloc, placement, params, baseline, pass_options, .{
            .memo = memo,
            .already_gated = true,
            .wide_corridors = wide,
        })).result;
        const expired = expiredPassCopper(candidate, userCancelled(options)) orelse return candidate;
        if (!try latticeResidualProgress(alloc, placement, pass_options, baseline, expired.result)) {
            if (wide) return baseline;
            wide = true;
            routeLog("gate ladder: converged, one last pass with detour corridors", .{});
            continue;
        }
        baseline = expired.result;
        // The reserve boundary arrived inside that pass. Its copper is kept —
        // that is the whole point of asking — but no further pass may start.
        if (expired.last) return baseline;
    }
    return baseline;
}

/// Is this guided target one this route's gate has already answered terminally?
///
/// Deadline-gated like every other timed-only behaviour in this pipeline: a
/// clock-free board (bench, corpus, every test route) skips nothing and retries
/// exactly the corridors it always did, byte for byte. The seal is only ever a
/// decision about how to SPEND a clock, so a route with no clock may not make
/// it.
fn guidedSealed(
    options: route_policy.Options,
    memo: *const route_close.HopMemo,
    net_i: usize,
) bool {
    if (options.stop.deadline_ns == 0) return false;
    return memo.sealed(net_i);
}

/// How many of this phase's still-open targets are sealed, reported on the
/// residual timeline as the tail it hands the phase behind it.
///
/// The guided retries are the residual's middle phase and the one measured to
/// close nothing: across four consecutive ReleaseSafe barracuda runs (v94-v97)
/// it gained ZERO nets while spending ~26-28 s, and its remaining targets were
/// all walls for the per-target unblock transactions behind it. That is not an
/// argument for deleting the phase — the corridor hints are load-bearing at the
/// FRONT of the pipeline, where the waves route through them, and a target this
/// route has not answered still deserves its slice here. It is an argument for
/// not re-asking a question this route already answered: a net the gate ladder
/// stopped planning, or one whose gridless mesh found no channel in the free
/// space, is not going to be closed by a 4 s corridor maze over strictly more
/// copper.
///
/// What the skip buys is measured in the phase BEHIND it. The unblock pass runs
/// against the board's own deadline, so every second this phase does not spend
/// is a second that pass still holds — and its per-target transactions are
/// priced in whole ladders (~60 s for a full narrow → wide → re-home → alternate
/// run), so one skipped 4 s maze slice is not noise there but a fraction of the
/// one more target the tail could not reach.
fn guidedSealCount(
    placement: optimizer.Placement,
    options: route_policy.Options,
    baseline: router.RouteResult,
    order: []const usize,
    memo: *const route_close.HopMemo,
) usize {
    var sealed: usize = 0;
    for (order) |net_i| {
        if (net_i >= placement.nets.len) continue;
        if (!namedFailed(placement.nets[net_i].name, baseline.failed)) continue;
        if (guidedSealed(options, memo, net_i)) sealed += 1;
    }
    return sealed;
}

/// The seconds the skipped targets hand the unblock phase — the maze slice each
/// would have been given, which is the one part of a guided retry whose cost is
/// a constant. The gate attempt an over-reach target also skips is unbounded and
/// is deliberately NOT counted, so this is a floor rather than a claim.
fn guidedSealYieldSecs(sealed: usize) i128 {
    return @divTrunc(@as(i128, @intCast(sealed)) * lattice_guided_slice_ns, clock.ns_per_s);
}

/// Retry authored `(seed-first)` corridors only after the broad route and its
/// first connectivity gate have identified the actual residual. Each candidate
/// gets a one-net scope against byte-frozen board copper. The candidate is kept
/// only when the oracle's old open set becomes a strict superset, so a hard
/// corridor can no longer displace a connection the broad route already earned.
///
/// A target this route's gate has ALREADY answered terminally is skipped
/// (`route_close.HopMemo.sealed`, and see `guidedSealCount` for why the phase's
/// dead time is worth more to the phase behind it than to this one).
fn retryLatticeGuided(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
    first: router.RouteResult,
    memo: *const route_close.HopMemo,
) std.mem.Allocator.Error!router.RouteResult {
    var baseline = first;
    const seed_mask = try waypointSeedMask(alloc, placement, base_options) orelse return baseline;
    var order: std.ArrayList(usize) = .empty;
    for (seed_mask, 0..) |seeded, net_i| if (seeded) try order.append(alloc, net_i);
    const priorities = try alloc.alloc(u64, placement.nets.len);
    for (priorities, 0..) |*priority, net_i| {
        const wave = if (net_i < base_options.net.len) base_options.net[net_i].wave.priority else 0;
        priority.* = (@as(u64, wave) << 32) | @as(u64, std.math.maxInt(u32) - @as(u32, @intCast(net_i)));
    }
    std.sort.pdq(usize, order.items, priorities, route_policy.priorityDesc);
    if (base_options.stop.deadline_ns != 0) {
        const sealed = guidedSealCount(placement, base_options, baseline, order.items, memo);
        routeLog("residual timeline: guided skipped {d} sealed net(s), yielding {d}s to unblock", .{
            sealed,
            guidedSealYieldSecs(sealed),
        });
    }
    for (order.items) |net_i| {
        if (routeStopped(base_options) or net_i >= placement.nets.len) return baseline;
        if (!namedFailed(placement.nets[net_i].name, baseline.failed)) continue;
        if (guidedSealed(base_options, memo, net_i)) {
            routeLog("guided residual {s}: sealed by this route's gate ({d} refusals, {d} with no channel) — skipped", .{
                placement.nets[net_i].name,
                memo.refusals(net_i),
                memo.shapeRefusals(net_i),
            });
            continue;
        }
        const selected = try alloc.alloc(bool, placement.nets.len);
        @memset(selected, false);
        selected[net_i] = true;

        var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
        var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
        for (baseline.tracks) |track| try tracks.append(alloc, trackAsExisting(track));
        for (baseline.vias) |via| try vias.append(alloc, viaAsExisting(via));

        var retry_options = base_options;
        retry_options.effort = .one_shot;
        retry_options.selected_nets = selected;
        retry_options.existing_tracks = tracks.items;
        retry_options.existing_vias = vias.items;
        // The broad wave can stay conservative (often outer faces only) while
        // its repair corridor explicitly names an inner-layer crossing. During
        // this selected retry the ordered waypoints, not the broad layer mask,
        // are the hard physical constraint.
        const retry_policies = try alloc.dupe(route_policy.NetPolicy, base_options.net);
        retry_policies[net_i].allowed_layers = 0;
        retry_policies[net_i].preferred_layers = 0;
        retry_policies[net_i].waypoints = retry_policies[net_i].wave.repair_waypoints;
        retry_options.net = retry_policies;
        retry_options.stop.max_route_ms = 0;
        // The retry's ROUTE runs on a per-net slice; its GATE must not. The
        // slice deadline is already in the past by the time the corridor route
        // returns, so a gate handed those stop conditions reports `cancelled`
        // for every candidate it is ever given — which is why this phase had
        // never once accepted a corridor on a timed board, however cleanly the
        // route itself finished. The gate is judged against the BOARD's clock.
        const weigh = GuidedWeigh{
            .alloc = alloc,
            .placement = placement,
            .params = params,
            .base_options = base_options,
            .gate_options = guidedGateOptions(retry_options, base_options),
            .selected = selected,
            .frozen_tracks = tracks.items,
            .frozen_vias = vias.items,
            .net_i = net_i,
            .target_hop_mm = try residualTargetHopMm(alloc, placement, base_options, baseline, net_i),
        };
        // Past the maze's practical reach, spend the slice's FIRST attempt on
        // the gate over the standing board: its shape tier answers the same
        // question in geometry and in a fraction of the time, and asking the
        // corridor maze first meant the slice expired before the gate was
        // reached at all. The maze still runs second on whatever is left, so no
        // answer the raster could have found is given up.
        if (weigh.target_hop_mm > guided_gate_first_hop_mm) {
            switch (try guidedWeigh(weigh, baseline, baseline)) {
                .gained => |board| {
                    baseline = board;
                    continue;
                },
                .abort => return baseline,
                .none => {},
            }
        }
        // One impossible corridor must not consume the whole residual tail.
        // Give every selected net a fresh bounded slice, still capped by the
        // board transaction's absolute deadline — and start it HERE, after any
        // gate-first attempt, so the maze's slice is the same length it has
        // always been rather than whatever the geometry answer left of it.
        const slice_deadline = clock.nanoTimestamp() + lattice_guided_slice_ns;
        retry_options.stop.deadline_ns = if (base_options.stop.deadline_ns != 0)
            @min(base_options.stop.deadline_ns, slice_deadline)
        else
            slice_deadline;
        const raw = try router.routeWithOptions(alloc, placement, params, retry_options);
        if (raw.cancelled) {
            routeLog("guided residual {s}: route slice expired", .{placement.nets[net_i].name});
            if (routeStopped(base_options)) return baseline;
            continue;
        }
        switch (try guidedWeigh(weigh, baseline, raw)) {
            .gained => |board| baseline = board,
            .abort => return baseline,
            .none => routeLog("guided residual {s}: no strict connectivity gain", .{placement.nets[net_i].name}),
        }
    }
    return baseline;
}

/// One guided candidate, gated and weighed against the board it would replace.
///
/// Extracted because the retry now makes TWO attempts at an over-reach target —
/// the gate on the standing board first, the corridor maze second — and a second
/// spelling of "gate it, merge it, prove the frozen copper did not move, keep it
/// only on a strict connectivity gain" is a second thing to keep in step.
const GuidedWeigh = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
    gate_options: route_policy.Options,
    selected: []const bool,
    frozen_tracks: []const route_policy.ExistingTrack,
    frozen_vias: []const route_policy.ExistingVia,
    net_i: usize,
    target_hop_mm: f64,
};

/// Kept, not kept, or the whole retry must hand the board back untouched.
const GuidedVerdict = union(enum) { gained: router.RouteResult, none, abort };

fn guidedWeigh(
    w: GuidedWeigh,
    baseline: router.RouteResult,
    raw: router.RouteResult,
) std.mem.Allocator.Error!GuidedVerdict {
    const name = w.placement.nets[w.net_i].name;
    var candidate = (try gateConfigured(w.alloc, w.placement, w.params, raw, w.gate_options, .{
        .scoped_target = true,
        .target_hop_mm = w.target_hop_mm,
    })).result;
    if (candidate.cancelled) {
        // Past the board deadline the gate's copper is still additive and fully
        // judged, so it is weighed rather than dropped; only a user cancel hands
        // the partial board back untouched.
        const expired = expiredPassCopper(candidate, userCancelled(w.base_options)) orelse {
            routeLog("guided residual {s}: cancelled", .{name});
            return .abort;
        };
        candidate = expired.result;
    }
    const replaced = try w.alloc.alloc(bool, w.placement.nets.len);
    @memset(replaced, false);
    candidate = try mergeResidualMetadata(w.alloc, replaced, w.selected, baseline, candidate);
    if (try retainsExistingCopper(w.alloc, candidate, w.frozen_tracks, w.frozen_vias, &.{}) != null) {
        routeLog("guided residual {s}: rejected because frozen copper changed", .{name});
        return .none;
    }
    if (!strictResidualGain(candidate, baseline)) return .none;
    routeLog("guided residual {s}: accepted ({d} -> {d} open nets)", .{
        name,
        baseline.failed.len,
        candidate.failed.len,
    });
    return .{ .gained = candidate };
}

/// One gate pass's copper as the ladder should treat it, or null when the USER
/// cancelled and the partial board must be handed back as-is.
///
/// A pass that runs into the ladder's reserve boundary comes back flagged
/// cancelled, and the ladder used to answer by returning the PREVIOUS board —
/// throwing away every hop the expired pass had already landed and judged
/// (barracuda lost two accepted `GND` island merges that way, in the one pass
/// that ever reached `GND`). The gate is additive and each hop is committed
/// only after the connectivity oracle and the geometry DRC weigh it, so an
/// expired pass's board is exactly as sound as a complete pass's — it is simply
/// the last one. The flag is a SLICE ending, not a board abort, so it is
/// cleared here for the same reason `route_close`'s pass slice never sets it.
fn expiredPassCopper(
    candidate: router.RouteResult,
    user_cancelled: bool,
) ?struct { result: router.RouteResult, last: bool } {
    if (!candidate.cancelled) return .{ .result = candidate, .last = false };
    if (user_cancelled) return null;
    var kept = candidate;
    kept.cancelled = false;
    return .{ .result = kept, .last = true };
}

fn userCancelled(options: route_policy.Options) bool {
    const flag = options.stop.cancel orelse return false;
    return flag.load(.monotonic);
}

/// The longest island-joining hop `net_i` still has to make on `board`, in mm —
/// the join a scoped transaction for it would be formed to close, and what its
/// gate's ceiling has to cover. Zero when the oracle finds the net whole.
fn residualTargetHopMm(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
    board: router.RouteResult,
    net_i: usize,
) std.mem.Allocator.Error!f64 {
    const zones = try route_close.userZones(alloc, placement, options.existing_zones);
    const wanted = [_][]const u8{placement.nets[net_i].name};
    const open = try fab_readiness.openNetsAmong(alloc, placement, .{
        .tracks = board.tracks,
        .vias = board.vias,
        .zones = zones,
    }, &wanted);
    var longest: f64 = 0;
    for (open) |detail| {
        for (detail.gaps) |gap| longest = @max(longest, gap.mm);
    }
    return longest;
}

/// Hop span (mm) past which a guided retry spends its slice's FIRST attempt on
/// the gate rather than on the corridor maze.
///
/// The same band `router.shape_first_hop_mm` separates, for the same measured
/// reason and one level up: a maze asked for a cross-board join spends the whole
/// 4 s slice and returns cancelled, and `retryLatticeGuided` reaches its gate —
/// where the gridless shape tier lives — only when the route DID finish. So on
/// barracuda `LOCK_DET` logged `route slice expired` on every pass and its gate
/// was never asked, in the one pass formed for nothing but that net.
const guided_gate_first_hop_mm: f64 = 40.0;

/// A guided retry's gate options: its own scope, the BOARD's clock.
fn guidedGateOptions(
    retry_options: route_policy.Options,
    base_options: route_policy.Options,
) route_policy.Options {
    var gate_options = retry_options;
    gate_options.stop = base_options.stop;
    return gate_options;
}

fn latticeResidualProgress(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
    baseline: router.RouteResult,
    candidate: router.RouteResult,
) std.mem.Allocator.Error!bool {
    for (candidate.failed) |name| if (!namedFailed(name, baseline.failed)) return false;
    if (candidate.failed.len < baseline.failed.len) return true;

    const zones = try route_close.userZones(alloc, placement, options.existing_zones);
    const before = try fab_readiness.openNetsAmong(alloc, placement, .{
        .tracks = baseline.tracks,
        .vias = baseline.vias,
        .zones = zones,
    }, baseline.failed);
    const after = try fab_readiness.openNetsAmong(alloc, placement, .{
        .tracks = candidate.tracks,
        .vias = candidate.vias,
        .zones = zones,
    }, candidate.failed);
    var before_islands: usize = 0;
    var after_islands: usize = 0;
    for (before) |detail| before_islands +|= detail.islands;
    for (after) |detail| after_islands +|= detail.islands;
    routeLog("residual progress: failed {d} -> {d}, islands {d} -> {d}, {s}", .{
        baseline.failed.len,
        candidate.failed.len,
        before_islands,
        after_islands,
        if (after_islands < before_islands) "kept" else "DISCARDED",
    });
    return after_islands < before_islands;
}

/// One non-destructive residual pass for the continuous route-space director.
/// Completed copper becomes immutable retained copper; only oracle-open nets are
/// selected. The retry therefore cannot trade away a connection already earned,
/// and a one-shot effort keeps this a bounded finishing pass rather than a second
/// full rescue ladder.
fn retryFieldResidual(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
    first: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    const selected = try alloc.alloc(bool, placement.nets.len);
    for (placement.nets, selected, 0..) |net, *retry, net_i| {
        retry.* = namedFailed(net.name, first.failed) and topologyMutable(base_options.selected_nets, @intCast(net_i));
    }
    if (!anyTrue(selected)) return first;

    const baseline = try stripGeneratedFailures(alloc, placement, base_options, selected, first);
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (baseline.tracks) |track| try tracks.append(alloc, trackAsExisting(track));
    for (baseline.vias) |via| try vias.append(alloc, viaAsExisting(via));

    var retry_options = base_options;
    retry_options.effort = .one_shot;
    retry_options.selected_nets = selected;
    retry_options.existing_tracks = tracks.items;
    retry_options.existing_vias = vias.items;
    const raw = router.routeWithOptions(alloc, placement, params, retry_options) catch return baseline;
    var candidate = (gate(alloc, placement, params, raw, retry_options) catch return baseline).result;
    candidate = try mergeResidualMetadata(alloc, selected, selected, baseline, candidate);
    candidate = try stripGeneratedFailures(alloc, placement, retry_options, selected, candidate);
    return if (residualBetter(candidate, baseline)) candidate else baseline;
}

// One deliberately small joint finishing transaction. The ordinary residual
// pass above freezes every completed net, which makes it safe but also makes a
// mutually-contended residual impossible to change: the channel an open seed
// needs may belong to a completed, cheap-to-restore net. This pass admits ONE
// measured cluster, removes only that cluster's generated copper, and asks the
// existing field/maze router to put it back in seed-first order. The oracle/DRC
// gate below remains the authority; a result which trades away any completed
// net is rejected byte-for-byte.
const field_cluster_max_open: usize = 12;
const field_cluster_max_seeds: usize = 3;
const field_cluster_max_blockers: usize = 6;
const field_cluster_max_elements: usize = 96;
const field_cluster_max_islands: usize = 4;
const field_cluster_max_corridors: usize = 8;
const field_cluster_corridor_mm: f64 = 2.0;
const field_cluster_limits: vacate_policy.Limits = .{
    .max_nets = field_cluster_max_blockers,
    .max_total_elements = field_cluster_max_elements,
};

const FieldClusterSeed = struct {
    net_i: usize,
    nominations: blocker_nomination.Table = .{},
};

const FieldClusterGroup = struct {
    nets: [field_cluster_max_seeds]usize = .{ 0, 0, 0 },
    len: usize = 0,

    fn append(self: *FieldClusterGroup, net_i: usize) void {
        if (self.len >= self.nets.len) return;
        self.nets[self.len] = net_i;
        self.len += 1;
    }

    fn items(self: *const FieldClusterGroup) []const usize {
        return self.nets[0..self.len];
    }
};

/// Try one multi-open cluster after the failed-only field residual pass. Every
/// bound is a count rather than a deadline, so the extra work is deterministic:
/// at most three seeds, six blockers, 96 displaced elements, one route call.
fn retryFieldCluster(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
    baseline: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    // ExistingVia deliberately carries physical copper only, not the saved
    // layout's `f` fence-provenance tag. With any caller-retained via present,
    // this layer cannot prove that a seemingly unrelated signal is not the
    // trace that via fences, so decline the optional displacement transaction.
    if (!fieldClusterAttemptEligible(baseline, base_options)) return baseline;

    const zones = try route_close.userZones(alloc, placement, base_options.existing_zones);
    const open = try fab_readiness.openNetsAmong(alloc, placement, .{
        .tracks = baseline.tracks,
        .vias = baseline.vias,
        .zones = zones,
    }, baseline.failed);
    var seeds: std.ArrayList(FieldClusterSeed) = .empty;
    for (open) |detail| {
        if (detail.islands > field_cluster_max_islands) continue;
        const net_i = placementNetIndex(placement, detail.net) orelse continue;
        // Seeds must be authoritative full-net reroutes. Plane/pour-carried,
        // protected, or caller-retained nets keep their deliberate topology;
        // selecting one while leaving some of its copper in place would make
        // the scoped route only a partial rewrite.
        if (!fieldClusterSeedEligible(placement, base_options, net_i)) continue;
        var seed = FieldClusterSeed{ .net_i = net_i };
        var hops: std.ArrayList(blocker_nomination.Hop) = .empty;
        for (detail.gaps, 0..) |gap, i| {
            if (i >= field_cluster_max_corridors) break;
            try hops.append(alloc, .{
                .ax = gap.from.x,
                .ay = gap.from.y,
                .bx = gap.to.x,
                .by = gap.to.y,
            });
        }
        try blocker_nomination.sweepHops(&seed.nominations, alloc, .{
            .net_i = net_i,
            .hops = hops.items,
            .tracks = baseline.tracks,
            .vias = baseline.vias,
            .radius_mm = field_cluster_corridor_mm,
            .via_policy = .tracks_and_vias,
        });
        try seeds.append(alloc, seed);
    }
    if (seeds.items.len < 2) return baseline;

    const group = firstNominatedFieldCluster(seeds.items) orelse escape: {
        // Static escape detection is a clustering hint only. Emitting its soft
        // guides would set `reference_corridor` and disable the exact field;
        // emitting reservations would make the field blind to a hard obstacle.
        const findings = try escape_assign.detect(alloc, placement, .{});
        break :escape firstEscapeFieldCluster(seeds.items, findings) orelse return baseline;
    };

    var union_table = blocker_nomination.Table{};
    for (group.items()) |net_i| {
        const seed = fieldClusterSeed(seeds.items, net_i) orelse continue;
        var it = seed.nominations.near.iterator();
        while (it.next()) |entry| try union_table.nearer(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }
    const ranked = try union_table.ranked(alloc);
    var facts: std.ArrayList(vacate_policy.NetFacts) = .empty;
    for (ranked) |candidate| {
        if (candidate.net_i >= placement.nets.len) continue;
        if (!topologyMutable(base_options.selected_nets, @intCast(candidate.net_i))) continue;
        const elements = generatedNetCopperCount(baseline, base_options, candidate.net_i);
        // Caller-authored/retained copper is immutable. A candidate with none
        // of the router's own copper to remove cannot free this transaction's
        // corridor and must not consume a blocker slot.
        if (elements == 0 or retainedNetCopper(base_options, candidate.net_i)) continue;
        try facts.append(alloc, fieldClusterNetFacts(placement, base_options, baseline, candidate, elements));
    }
    var policy_seeds: [field_cluster_max_seeds]vacate_policy.Seed = undefined;
    for (group.items(), 0..) |net_i, i| policy_seeds[i] = .{
        .net_i = net_i,
        .priority = fieldClusterPriority(placement, net_i),
    };
    const decision = try vacate_policy.selectMany(alloc, facts.items, policy_seeds[0..group.len], field_cluster_limits);
    if (decision.picked.len == 0) return baseline;
    routeLog("joint residual: {d} open seeds, {d} generated blockers", .{ group.len, decision.picked.len });

    const selected = try alloc.alloc(bool, placement.nets.len);
    const dropped = try alloc.alloc(bool, placement.nets.len);
    @memset(selected, false);
    @memset(dropped, false);
    for (group.items()) |net_i| {
        selected[net_i] = true;
        dropped[net_i] = fieldClusterSeedMovable(placement, base_options, net_i) and
            generatedNetCopperCount(baseline, base_options, net_i) > 0;
    }
    for (decision.picked) |pick| {
        selected[pick.net_i] = true;
        dropped[pick.net_i] = true;
    }

    const trial_base = try stripGeneratedMask(alloc, placement, base_options, dropped, baseline);
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (trial_base.tracks) |track| try tracks.append(alloc, trackAsExisting(track));
    for (trial_base.vias) |via| try vias.append(alloc, viaAsExisting(via));

    // Only priority is changed, and only for this scoped transaction. All
    // authored layer masks, waypoints, via caps and RF policy survive verbatim.
    const policies = try alloc.alloc(route_policy.NetPolicy, placement.nets.len);
    for (policies, 0..) |*policy, net_i| policy.* = if (net_i < base_options.net.len) base_options.net[net_i] else .{};
    var priority: u32 = std.math.maxInt(u32);
    for (group.items()) |net_i| {
        policies[net_i].wave.priority = priority;
        // A plane blocker is intentionally allowed by vacate_policy, but its
        // stitch pass runs before ordinary signals. Route the open seeds first
        // so the plane cannot immediately refill the corridor being opened.
        policies[net_i].wave.before_planes = 1;
        // A deferred repair corridor is inert in the broad pass. Once its
        // measured blockers have been admitted to this same transaction, make
        // that corridor the open seed's hard topology while the ordinary
        // policies continue to govern every displaced blocker.
        applyDeferredRepair(&policies[net_i]);
        priority -= 1;
    }
    for (decision.picked) |pick| {
        policies[pick.net_i].wave.priority = priority;
        priority -= 1;
    }

    var retry_options = base_options;
    retry_options.net = policies;
    retry_options.effort = .one_shot;
    retry_options.selected_nets = selected;
    retry_options.existing_tracks = tracks.items;
    retry_options.existing_vias = vias.items;
    const raw = router.routeWithOptions(alloc, placement, params, retry_options) catch return baseline;
    var candidate = (gate(alloc, placement, params, raw, retry_options) catch return baseline).result;
    candidate = try mergeResidualMetadata(alloc, dropped, selected, baseline, candidate);
    candidate = try stripGeneratedFailures(alloc, placement, retry_options, selected, candidate);
    if (try retainsExistingCopper(alloc, candidate, retry_options.existing_tracks, retry_options.existing_vias, &.{}) != null)
        return baseline;
    if (strictResidualGain(candidate, baseline)) {
        routeLog("joint residual: accepted ({d} -> {d} open nets)", .{ baseline.failed.len, candidate.failed.len });
        return candidate;
    }
    routeLog("joint residual: no strict connectivity gain", .{});
    return baseline;
}

fn applyDeferredRepair(policy: *route_policy.NetPolicy) void {
    if (policy.wave.repair_waypoints.len == 0) return;
    policy.allowed_layers = 0;
    policy.preferred_layers = 0;
    policy.waypoints = policy.wave.repair_waypoints;
}

fn placementNetIndex(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, net_i| if (std.mem.eql(u8, net.name, name)) return net_i;
    return null;
}

fn fieldClusterViaProvenanceSafe(options: route_policy.Options) bool {
    return options.existing_vias.len == 0;
}

fn fieldClusterAttemptEligible(baseline: router.RouteResult, options: route_policy.Options) bool {
    return !baseline.cancelled and baseline.failed.len >= 2 and
        baseline.failed.len <= field_cluster_max_open and fieldClusterViaProvenanceSafe(options);
}

fn fieldClusterSeed(seeds: []const FieldClusterSeed, net_i: usize) ?*const FieldClusterSeed {
    for (seeds) |*seed| if (seed.net_i == net_i) return seed;
    return null;
}

fn fieldNominationsContend(a: FieldClusterSeed, b: FieldClusterSeed) bool {
    if (a.nominations.has(b.net_i) or b.nominations.has(a.net_i)) return true;
    var it = a.nominations.near.keyIterator();
    while (it.next()) |net_i| if (b.nominations.has(net_i.*)) return true;
    return false;
}

fn firstNominatedFieldCluster(seeds: []const FieldClusterSeed) ?FieldClusterGroup {
    for (seeds, 0..) |anchor, i| {
        var group = FieldClusterGroup{};
        group.append(anchor.net_i);
        for (seeds[i + 1 ..]) |candidate| {
            if (group.len >= field_cluster_max_seeds) break;
            if (fieldNominationsContend(anchor, candidate)) group.append(candidate.net_i);
        }
        if (group.len > 1) return group;
    }
    return null;
}

fn fieldContentionHas(finding: escape_assign.Contention, net_i: usize) bool {
    for (finding.nets) |candidate| if (candidate == net_i) return true;
    return false;
}

fn firstEscapeFieldCluster(
    seeds: []const FieldClusterSeed,
    findings: []const escape_assign.Contention,
) ?FieldClusterGroup {
    for (findings) |finding| {
        var group = FieldClusterGroup{};
        for (seeds) |seed| {
            if (group.len >= field_cluster_max_seeds) break;
            if (fieldContentionHas(finding, seed.net_i)) group.append(seed.net_i);
        }
        if (group.len > 1) return group;
    }
    return null;
}

const fieldClusterLeafName = net_name.leaf;

fn fieldClusterInDiffPair(placement: optimizer.Placement, net_i: usize) bool {
    for (placement.diff_pairs) |pair| if (pair.p == net_i or pair.n == net_i) return true;
    return false;
}

fn fieldClusterRf(placement: optimizer.Placement, net_i: usize) bool {
    return net_i < placement.rules.net.len and placement.rules.net[net_i].rf.max_freq_hz > 0;
}

fn fieldClusterFenced(placement: optimizer.Placement, net_i: usize) bool {
    return net_i < placement.rules.net.len and placement.rules.net[net_i].rf.fence.declared;
}

fn fieldClusterPriority(placement: optimizer.Placement, net_i: usize) u32 {
    return if (net_i < placement.rules.net.len) placement.rules.net[net_i].priority else 0;
}

fn fieldClusterPourCarried(
    placement: optimizer.Placement,
    options: route_policy.Options,
    net_i: usize,
) bool {
    if (net_i >= placement.nets.len) return false;
    if (fab_readiness.netHasPlane(placement, placement.nets[net_i].name)) return true;
    for (options.existing_zones) |zone| {
        if (zone.copper and zone.net >= 0 and @as(usize, @intCast(zone.net)) == net_i) return true;
    }
    return false;
}

fn fieldClusterSeedMovable(
    placement: optimizer.Placement,
    options: route_policy.Options,
    net_i: usize,
) bool {
    if (net_i >= placement.nets.len or fieldClusterPourCarried(placement, options, net_i)) return false;
    const name = placement.nets[net_i].name;
    return !optimizer.isGroundName(fieldClusterLeafName(name)) and
        !fieldClusterInDiffPair(placement, net_i) and !fieldClusterRf(placement, net_i) and
        !fieldClusterFenced(placement, net_i);
}

/// May a PER-GAP transaction take this open net as its target?
///
/// The whole-net rule minus its POUR exclusion, and that one difference is the
/// point. A whole-net target is rewritten, which is meaningless for a rail
/// whose connectivity its zone underwrites and whose traces the transaction
/// would strip — so `fieldClusterSeedMovable` refuses it, and barracuda's
/// `V_3V3A` (eight islands over a retained In3 zone) is exactly that shape. A
/// per-gap transaction never touches the target's copper: it draws ONE
/// additive join in a channel it freed, and the verdict
/// (`Gate.acceptsIslandMerge`) measures the pours as the connecting copper they
/// are, so a join the fill already made is credited with nothing and refused.
///
/// GROUND is admitted here too, and only here, on the same terms and for the
/// same reason as the pour exclusion above: a plane or a pour underwrites its
/// connectivity, and a per-gap transaction never rewrites the target — it frees
/// one channel and draws one join, so the 246 pads it is not aiming at keep
/// their copper byte-for-byte. The old blanket refusal said such a net's islands
/// are closed by STITCHING instead, which is true right up to the island that
/// has no legal stitch site: barracuda's `J1` pad 40 is a 1.0 x 0.35 mm B.Cu
/// finger on a 0.4 mm via board, and once the drill-containment tier finally
/// produced sites for it (nine there, seven at `lmx2595/U17` pad 34) every one
/// was refused by a neighbour's escape track drawn 0.39 mm away. No stitch can
/// overrule that copper; MOVING it is exactly what this tier is for, and with
/// ground excluded there was no tier left to ask. Ground with no plane or pour
/// behind it stays refused — then its tracks ARE its connectivity, which is the
/// same line `target_unblock.blockerFacts` draws on the blocker side.
///
/// Everything else the whole-net rule asks still holds: in scope, no
/// caller-retained copper, and not a diff-pair leg, RF or fenced — the
/// coupled/shaped classes must not have copper drawn into them by a tier that
/// cannot see their geometry rules.
fn unblockGapEligible(
    placement: optimizer.Placement,
    options: route_policy.Options,
    net_i: usize,
) bool {
    if (net_i >= placement.nets.len) return false;
    if (!topologyMutable(options.selected_nets, @intCast(net_i))) return false;
    if (retainedNetCopper(options, net_i)) return false;
    const name = placement.nets[net_i].name;
    if (optimizer.isGroundName(fieldClusterLeafName(name)) and
        !fieldClusterPourCarried(placement, options, net_i)) return false;
    return !fieldClusterInDiffPair(placement, net_i) and !fieldClusterRf(placement, net_i) and
        !fieldClusterFenced(placement, net_i);
}

fn fieldClusterSeedEligible(
    placement: optimizer.Placement,
    options: route_policy.Options,
    net_i: usize,
) bool {
    return topologyMutable(options.selected_nets, @intCast(net_i)) and
        fieldClusterSeedMovable(placement, options, net_i) and
        !retainedNetCopper(options, net_i);
}

fn fieldClusterNetFacts(
    placement: optimizer.Placement,
    options: route_policy.Options,
    baseline: router.RouteResult,
    candidate: blocker_nomination.Candidate,
    elements: usize,
) vacate_policy.NetFacts {
    const name = placement.nets[candidate.net_i].name;
    return .{
        .net_i = candidate.net_i,
        .protected = .{
            .ground = optimizer.isGroundName(fieldClusterLeafName(name)),
            .diff_pair = if (fieldClusterInDiffPair(placement, candidate.net_i)) .protected else .none,
            .rf = fieldClusterRf(placement, candidate.net_i),
            .fenced = fieldClusterFenced(placement, candidate.net_i),
        },
        .pour_carried = fieldClusterPourCarried(placement, options, candidate.net_i),
        .whole = !namedFailed(name, baseline.failed),
        .rank = .{ .priority = fieldClusterPriority(placement, candidate.net_i) },
        .elements = elements,
        .dist = candidate.dist,
    };
}

// ── Per-target unblock ──────────────────────────────────────────────────────
//
// The cluster above forms ONE transaction out of several open seeds and the
// blockers they share. Measured on barracuda's 102/109 residual it was safe and
// bought nothing: those seeds' corridors are not one corridor — `LOCK_DET`
// crosses the board 55 mm while `EN_BUCK6V` needs 16 mm into a different pocket
// — so freeing their union frees nobody's, and the all-or-nothing gate then has
// six restores to prove instead of two. The tier below is the opposite shape and
// the one that was never tried: ONE open two-terminal net at a time, its own
// diagnosed blockers, its own bounded slice of what is left of the route budget,
// its own gate. Policy (which targets, in what order, how long each may take,
// what the transaction must prove) is `target_unblock.zig`; the copper is here,
// because ripping and re-routing is composed out of this seam's own strip,
// freeze, route, gate and merge helpers.

/// What one element of copper an unblock transaction has to put back is worth in
/// wall clock, for BOTH tiers below.
///
/// One rate, declared once, because both readings of it are the same claim. It is
/// the wide tier's own cap read back off itself — 45 s buys that tier's base
/// 128-element budget, which is 352 ms an element — and the narrow tier charges
/// the same rate for the copper it actually takes rather than inventing a second
/// price for the same work.
const unblock_ns_per_element: i128 = 350 * clock.ns_per_ms;

/// The pass's bounds. Named once so the tier's cost is readable in one place.
///
/// The flat 10 s cap is what a transaction gets for forming at all; the rate
/// above is what it earns for the restore it turns out to have to prove
/// (`target_unblock.restoreSlice`). Measured on barracuda (Debug, v91): `GND`'s
/// per-gap ladder rips 7, then 10, then 12 elements, and the flat cap cut the
/// third off at 8.6 s of a re-route that takes 13.0 s — reporting the CLOCK
/// where the board's real answer was that the freed corridor still carries no
/// hop. `slice.ceiling_ns` is unchanged and still the absolute stop, and
/// `sliceDeadline`'s equal share still bounds what is actually handed out.
const target_unblock_limits: target_unblock.Limits = .{
    .slice = .{ .ns_per_element = unblock_ns_per_element },
};

/// The bounds a SECOND, wider transaction runs under when the board still has
/// time for one. The ordinary limits are sized for the scraps this phase gets
/// on a slow build — three blockers, 48 elements, a 10 s slice — and on a fast
/// one they leave most of the route budget unspent while every target reports
/// "no candidate within its slice". A target that refused the narrow
/// transaction is asked once more with room to rip a real corridor.
const unblock_wide_limits: target_unblock.Limits = .{
    .blockers = .{
        .max_nets = 6,
        .stub_max_elements = target_unblock_limits.blockers.stub_max_elements,
        // The BASE budget, for a corridor of no length. `target_unblock.Corridor`
        // grows it with the corridor each transaction actually has to open, so
        // 128 is what an endpoint pocket gets here rather than what a 55 mm
        // cross-board join is held to.
        .max_total_elements = 128,
    },
    // The tier that negotiates, and the only one. `wideUnblockAffordable` has
    // already proved this board has measured spare wall time per remaining
    // target before a wide transaction is formed, and that is what each of the
    // two cost beyond an ordinary rip: a second coupled construction, and a
    // per-element corridor measurement. A run with no deadline never gets
    // here, so every bench and test route stays byte-identical.
    .negotiate = .{ .pairs = true, .plane_corridor = true },
    // 45 s: at 20 s the three cross-board control targets' wide re-routes -
    // each a 6-net scoped maze including corridor-lifted GND and pour rips -
    // all verdicted "ran out of its slice" at ReleaseSafe speed (v85) while
    // the phase left ~100 s of the board budget unspent. Debug never affords
    // this tier at all, so the raise is Debug-inert by construction.
    //
    // And 45 s is the cap for a corridor of NO LENGTH, because
    // `target_unblock.Corridor` then scales the rip: the same two targets came
    // back at v89 with two hundred elements of rip authority, the same flat
    // 45 s, and the same "ran out of its slice" verdict. 350 ms per extra
    // element is this cap's own implied rate read back off itself - 45 s buys
    // the base 128-element budget, which is 352 ms an element - so a
    // transaction ripping twice the copper gets about twice the clock and the
    // arithmetic is one number, not two. `Corridor.max_elements` (256) bounds
    // the growth at +128 elements = +44.8 s, so the cap tops out at 89.8 s just
    // inside the 90 s ceiling: today the ceiling is the stop if either corridor
    // constant is ever raised rather than a bound any corridor reaches. What
    // actually bounds a real slice is `sliceDeadline`'s equal share and
    // remainder, measured against what the board has left.
    .slice = .{
        .max_ns = 45 * clock.ns_per_s,
        .ns_per_element = unblock_ns_per_element,
        .ceiling_ns = 90 * clock.ns_per_s,
    },
};

/// Spare wall time PER REMAINING TARGET that makes the wide retry affordable.
/// Above this the phase is being handed a budget the narrow transaction cannot
/// use; below it, a second attempt would only take the tail the additive close
/// behind this phase needs.
const unblock_wide_gate_ns: i128 = 20 * clock.ns_per_s;

/// Can this board afford the wider second transaction for one more target?
///
/// A run with no deadline answers NO on purpose: bench and test routes are
/// deterministic clock-free boards, and "there is time left" is not a question
/// they can be asked — giving them a second, wider rip pass would change a
/// corpus result for a reason no author declared.
fn wideUnblockAffordable(now: i128, board_deadline: i128, targets_left: usize) bool {
    if (board_deadline == 0 or targets_left == 0) return false;
    const spare = board_deadline - unblock_wide_limits.slice.reserve_ns - now;
    if (spare <= 0) return false;
    return @divTrunc(spare, @as(i128, @intCast(targets_left))) >= unblock_wide_gate_ns;
}

/// Can this board afford ONE MORE NARROW transaction for this target — the
/// alternate nomination after a victim loss?
///
/// The alternate is not the wide tier: it rips the same classes under the same
/// `lim`, so `wideUnblockAffordable`'s 20 s-per-remaining-target gate priced it
/// at a tier it does not run. Measured on barracuda (ReleaseSafe, v93): the one
/// transaction that produced the victim-loss refusal this retry exists for
/// finished ~179 s into the phase, the spare-per-target test then answered NO,
/// and "retrying with <victim> held" was never printed on any logged run.
///
/// So it asks the narrow question instead — can `sliceDeadline` still cut a
/// slice for one of the targets left? — which is exactly the test
/// `unblockAttempt` opened the whole attempt with. A clock-free board still
/// answers NO on purpose, for the same reason the wide and shape tiers decline
/// one: "is there time left" is not a question a deterministic corpus route can
/// be asked.
fn alternateAffordable(
    now: i128,
    board_deadline: i128,
    targets_left: usize,
    lim: target_unblock.Limits,
) bool {
    if (board_deadline == 0 or targets_left == 0) return false;
    return target_unblock.sliceDeadline(now, board_deadline, targets_left, lim) != null;
}

/// The absolute ceiling on ONE target's corridor price inside the reserve.
/// Above this a single transaction stops being a tail and starts being the
/// route: the ladder is the phase measured to close rails, and no per-target
/// transaction is worth more than the corridor arithmetic's own biggest slice.
///
/// It bounds the FLOOR term alone (see `unblockReservePlan`), not the whole
/// reserve — a phase that owes six probes and two ladders owes that whether or
/// not its widest single corridor happens to price above a hundred seconds.
const unblock_reserve_max_ns: i128 = 100 * clock.ns_per_s;

/// Most of the residual's remaining wall clock the reserve may claim, as a
/// fraction. The two phases ahead of the tail are the ones every logged run has
/// closing nets, so a reserve that took the whole residual would be a
/// re-ordering of the phase budget in favour of its most speculative tier
/// rather than a tail — the head keeps a bit under half whatever the tail's own
/// demand comes to.
const unblock_reserve_share_num: i128 = 11;
const unblock_reserve_share_den: i128 = 20;

/// What ONE breadth probe costs the tail, for the phase-carving price.
///
/// A probe is not only its slice. `unblockBreadthLimits` clamps the scoped
/// re-route to `slice.max_ns` — a probe may be handed less when the round
/// divides what is left across its targets, never more — and then the
/// transaction's GATE reconciles BEHIND that slice, against a window of its own
/// (`unblockGateOptions`, bounded by `gate_window_ns`). That window exists
/// precisely because the slice is spent to the last nanosecond by construction,
/// so the gate's clock is additional wall by design. A probe's price is
/// therefore both terms, each read off the constant the round is itself bounded
/// by rather than off a stopwatch.
///
/// Pricing it at the slice alone priced half a probe. Measured on barracuda
/// (ReleaseSafe, v103/v104): probes ran 16-30 s against a 10 s price, so round 1
/// overran its priced share of the reserve and round 2 reported "funding 0 deep
/// ladders" run after run — the depth term was in the arithmetic and never in
/// the clock.
const unblock_breadth_probe_ns: i128 = target_unblock_limits.slice.max_ns + gate_window_ns;

/// How many deep ladders the tail is priced to FUND — the depth half of the
/// reserve's demand.
///
/// Two, because that is what round 2 has evidence for and no more. Its funding
/// arithmetic (`unblockFundedLadders`) already divides whatever the breadth round
/// leaves by `unblock_ladder_price_ns` and floors the answer at one, so the
/// question this constant answers is not "how many ladders may run" but "how many
/// is the head phase asked to leave room for". Measured on barracuda under the
/// 2026-08-18 layer contract (ReleaseSafe, v103 and v104): round 1 spent the
/// whole reserve and round 2 funded ZERO ladders on both runs, with `V_3V3A` and
/// `SPI_LMX_CSN` sitting on `deepenable` verdicts that only a ladder can escalate.
/// One would fund the best verdict alone; the sum of all of them (six here) would
/// price a tail no head phase could survive. Two funds the ranked pair, which is
/// the width `unblockFundedPlan` deals rungs round-robin across.
const unblock_reserve_ladders: usize = 2;

/// What the unblock phase would SPEND at the census the residual is entered with,
/// and the two counts that priced it.
const UnblockReserve = struct {
    /// Distinct open nets round 1 would probe — zero when there is no breadth
    /// round to run (`unblockRounds` leaves a single-target board alone).
    probes: usize,
    /// Deep ladders round 2 is asked to leave room for.
    ladders: usize,
    /// The single-target corridor price this reserve may not fall below: what
    /// the tail was before it was priced against a plan.
    floor_ns: i128,
    /// What the head phases must leave behind.
    reserve_ns: i128,

    fn breadthNs(self: UnblockReserve) i128 {
        return @as(i128, @intCast(self.probes)) * unblock_breadth_probe_ns;
    }

    fn depthNs(self: UnblockReserve) i128 {
        return @as(i128, @intCast(self.ladders)) * unblock_ladder_price_ns;
    }
};

/// Price the tail against the PLAN the phase would run, not against one number.
///
/// The reserve used to be one target's corridor price — the widest gap any
/// eligible target would ask for, through `target_unblock.phaseReserve`. That is
/// a guarantee about the biggest single transaction, and it was the right shape
/// while the phase WAS one transaction after another. It is not the shape of the
/// phase any more: `unblockRounds` runs a breadth probe per open NET and then
/// funds deep ladders out of what the probes leave, so the tail owes a bill with
/// two terms in it and the old number covered only part of the first.
///
/// Measured on barracuda under the 2026-08-18 layer contract (ReleaseSafe, v103
/// and v104): the flat 89 s reserve covered round 1's six probes and nothing
/// else, so round 2 reported "funding 0 deep ladders" on both runs while the head
/// phases spent every second of two successive budget raises (240 -> 270 -> 283)
/// without closing a net with them. The head phases spend to their deadline
/// whatever it is; what decides whether the productive edge of the phase runs at
/// all is where that deadline is put.
///
/// So the demand is `probes x unblock_breadth_probe_ns + ladders x
/// unblock_ladder_price_ns`, both priced off the constants the rounds are already
/// bounded by. Two bounds keep it a tail rather than a re-plan. It is FLOORED at
/// the old single-corridor price, so no board can reserve less than it does today
/// and a board whose widest corridor out-prices its plan keeps the corridor's
/// number. And it is CAPPED at `unblock_reserve_share_num`/`den` of what the
/// residual has left when it is measured, so the gate ladder — still the phase
/// closing three to six nets a run — keeps a share of every budget rather than
/// being priced out of a small one.
///
/// A board with no clock, no open nets or no targets prices NOTHING, which is
/// what keeps every bench, corpus and test route byte-identical.
fn unblockReservePlan(targets: usize, nets: usize, widest_mm: f64, remaining_ns: i128) UnblockReserve {
    const floor_ns = target_unblock.phaseReserve(unblock_wide_limits, widest_mm, unblock_reserve_max_ns);
    var plan = UnblockReserve{ .probes = 0, .ladders = 0, .floor_ns = floor_ns, .reserve_ns = 0 };
    if (targets == 0 or nets == 0 or remaining_ns <= 0) return plan;
    // Round 1 is DEADLINE-GATED on two or more targets and asks one question per
    // distinct net, so that count — and only on a board that reaches the round —
    // is what breadth costs.
    plan.probes = if (targets < 2) 0 else nets;
    plan.ladders = @min(unblock_reserve_ladders, nets);
    const want = @max(floor_ns, plan.breadthNs() + plan.depthNs());
    const share = @divTrunc(remaining_ns * unblock_reserve_share_num, unblock_reserve_share_den);
    plan.reserve_ns = @min(want, share);
    return plan;
}

/// The wall time the residual's HEAD phases must leave behind for the per-target
/// unblock pass — derived from that pass's OWN plan, not guessed.
///
/// The ladder already holds back a flat tail (`lattice_gate_tail_reserve_ns`),
/// and that tail bounds the LADDER alone: the guided corridor phase behind it
/// runs against the board's own deadline and is free to spend every second the
/// ladder saved. Measured on barracuda (Debug, v90): the ladder converged and
/// stopped on its own at +129 s, the guided phase then ran to +163 s — past the
/// board deadline — and the unblock phase was entered with 1.7 s, under its own
/// `slice.min_ns` floor, so `sliceDeadline` returned null and NOT ONE target was
/// ever attempted. The reserve existed and never reached the phase it was for.
///
/// The size is `unblockReservePlan`'s: the entry census this function measures —
/// how many targets, over how many distinct open nets, with what widest corridor
/// — priced through the constants the unblock rounds are themselves bounded by.
/// Everything about the phases is unchanged; only where the boundary between them
/// falls moves.
///
/// A clock-free board (bench, corpus, every test route) reserves NOTHING and is
/// byte-identical, exactly as the wide tier and the shape tier decline such a
/// board.
fn unblockReserveNs(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
    baseline: router.RouteResult,
) std.mem.Allocator.Error!i128 {
    if (options.stop.deadline_ns == 0 or baseline.failed.len == 0) return 0;
    const remaining = options.stop.deadline_ns - clock.nanoTimestamp();
    if (remaining <= 0) return 0;
    const targets = try unblockTargets(alloc, placement, options, baseline, target_unblock_limits);
    if (targets.len == 0) return 0;
    var widest: f64 = 0;
    for (targets) |t| widest = @max(widest, t.gap_mm);
    const nets = unblockDistinctNets(targets, placement.nets.len);
    const plan = unblockReservePlan(targets.len, nets, widest, remaining);
    // The arithmetic, not just its answer: a reserve that is the floor, one that
    // is the plan, and one the share cap cut are three different states of this
    // phase and a reader has to be able to tell them apart from the log alone.
    routeLog(
        "residual timeline: reserving {d}s for {d} unblock target(s) (breadth {d}x{d}s [slice {d}s + gate {d}s] + {d} ladder(s) {d}s, floor {d}s), widest corridor {d:.2}mm",
        .{
            @divTrunc(plan.reserve_ns, clock.ns_per_s),
            targets.len,
            plan.probes,
            @divTrunc(unblock_breadth_probe_ns, clock.ns_per_s),
            @divTrunc(target_unblock_limits.slice.max_ns, clock.ns_per_s),
            @divTrunc(gate_window_ns, clock.ns_per_s),
            plan.ladders,
            @divTrunc(plan.depthNs(), clock.ns_per_s),
            @divTrunc(plan.floor_ns, clock.ns_per_s),
            widest,
        },
    );
    return plan.reserve_ns;
}

/// The same options with the unblock pass's tail taken off the deadline. The
/// pass itself keeps the board's own deadline, which is what makes the tail its
/// window rather than a shorter route.
fn headOptions(options: route_policy.Options, reserve_ns: i128) route_policy.Options {
    if (options.stop.deadline_ns == 0 or reserve_ns <= 0) return options;
    var head = options;
    head.stop.deadline_ns -= reserve_ns;
    return head;
}

/// The residual tail: bounded per-target transactions, then one additive
/// connectivity close over whatever they freed.
///
/// The close is why `target_unblock.Limits.slice.reserve_ns` exists. Every earlier phase ends in
/// `gate`, whose reconciliation joins the short island-to-island hops a batch
/// route left open — cheap, non-ripping, strictly-gated work that a phase of
/// speculative rip-ups must not be able to starve. `repeatLatticeGate` cannot
/// serve here: it holds back its own 15 s tail, which is precisely the window
/// this phase runs in. So the close is one gate pass, kept on the same
/// island-or-net progress rule that loop accepts, and it runs only when a
/// transaction actually changed the board — on an unchanged board the previous
/// pass already proved another gate finds nothing.
fn unblockPhase(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    first: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    const unblocked = try retryTargetUnblock(alloc, placement, params, options, first);
    if (unblocked.failed.len == first.failed.len) return unblocked;
    return closeAfterUnblock(alloc, placement, params, options, unblocked);
}

/// One additive close inside the reserve, kept only on strict progress: the
/// oracle's open set may only shrink, by a net or by an island.
fn closeAfterUnblock(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    baseline: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    if (baseline.cancelled or baseline.failed.len == 0 or routeStopped(options)) return baseline;
    const candidate = (gate(alloc, placement, params, baseline, options) catch return baseline).result;
    if (candidate.cancelled) return baseline;
    if (!try latticeResidualProgress(alloc, placement, options, baseline, candidate)) return baseline;
    routeLog("target unblock: tail close ({d} -> {d} open nets)", .{ baseline.failed.len, candidate.failed.len });
    return candidate;
}

/// One per-target pass over an already-gated board.
fn retryTargetUnblock(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
    first: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    // `ExistingVia` carries physical copper only, never a saved layout's RF
    // fence provenance, so with caller-retained vias present this layer cannot
    // prove that a blocker is not the trace one of them fences — the field
    // cluster declines such a board for the same reason.
    if (first.cancelled or first.failed.len == 0 or !fieldClusterViaProvenanceSafe(base_options))
        return first;
    const lim = target_unblock_limits;
    const targets = try unblockTargets(alloc, placement, base_options, first, lim);
    if (targets.len == 0) return first;
    var accept = try target_unblock.Gate.init(alloc, placement, base_options.existing_zones);
    defer accept.deinit();
    // One evaluation per candidate this pass weighs, and a re-entering rail
    // spends one per island it merges — which is not the shape `fine_accept`'s
    // own default was sized for (see `Limits.max_evaluations`).
    accept.allowEvaluations(lim.max_evaluations);
    var run = UnblockRun{
        .alloc = alloc,
        .placement = placement,
        .params = params,
        .options = base_options,
        .lim = lim,
        .accept = &accept,
        .baseline = first,
        .measured = try unblockMeasure(alloc, placement, params, first),
    };
    // A net whose per-gap transaction was refused is not asked again this
    // phase: its remaining targets would nominate the same corridor's copper
    // against the same board, and one refusal is evidence enough (the gate
    // ladder's own per-net cutoff is the same lesson).
    const abandoned = try alloc.alloc(bool, placement.nets.len);
    @memset(abandoned, false);
    // ... unless the net has already EARNED an accept this phase (see below).
    const accepts = try alloc.alloc(usize, placement.nets.len);
    @memset(accepts, 0);
    // Which nets have had their first attempt, so a ladder can be told to stop
    // short of the ones that have not (see `unblockFirstTriesCovered`).
    const attempted = try alloc.alloc(bool, placement.nets.len);
    @memset(attempted, false);
    // BREADTH first, then depth in the order breadth earned (see `UnblockLadder`).
    const plan = try unblockRounds(&run, targets, lim);
    outer: for (plan, 0..) |target, done| {
        if (abandoned[target.net_i]) continue;
        var attempt = target;
        while (true) {
            attempted[attempt.net_i] = true;
            const live = unblockLiveTargets(plan, done, abandoned);
            const accepted = (try unblockAttempt(&run, attempt, live, lim)) orelse break :outer;
            if (!accepted) {
                // A net that has proved NOTHING is abandoned on its first
                // refusal, exactly as before.
                if (accepts[attempt.net_i] == 0 or attempt.kind != .one_gap) {
                    if (attempt.kind == .one_gap) abandoned[attempt.net_i] = true;
                    continue :outer;
                }
                // A net that has already earned an accept is a different case:
                // its ladder is known to close on this board, so one hop the
                // board will not take is evidence about THAT HOP, not about the
                // net. Measured on barracuda, `GND` earns two accepts and is
                // then abandoned on its 1.27 mm pocket — a hop whose honest
                // verdict (given 36 s instead of 8.6) is that the freed corridor
                // carries no legal path at all, while four 1.50 mm pockets and a
                // 2.06 mm one behind it were never asked.
                //
                // So the refusal retires the GAP and the ladder continues at the
                // next-smallest. Bounded twice over: a retired gap is never
                // offered again this phase, and every rung either retires a gap
                // or merges one, so the ladder is finite in the net's own gap
                // count either way.
                try unblockRetireGap(&run, attempt.net_i);
                if (!unblockFirstTriesCovered(&run, plan, done, attempted, abandoned, lim))
                    continue :outer;
                attempt = (try unblockNextGap(&run, attempt.net_i)) orelse continue :outer;
                continue;
            }
            accepts[attempt.net_i] += 1;
            // ACCEPTED, so this net has just proved a transaction of its own
            // closes on this board — take its NEXT gap at once, on the board
            // this one left, rather than handing the slice to a target that has
            // proved nothing. A rail arriving in eight islands is a LADDER of
            // seven merges, and one merge per visit through the planned list
            // is one merge per route: measured on barracuda, `GND` closed its
            // 1.00 mm pocket and then waited behind two cross-board targets
            // that spent the rest of the tail failing.
            //
            // Bounded by the board itself. The verdict that admitted this
            // transaction is a CREDITED island merge, so the net holds strictly
            // fewer islands than it did, and the re-entry ends when the oracle
            // reports no gap left. Its slice is one equal share of what is left,
            // and it yields outright once the remainder is down to the first
            // attempts still owed to the targets behind it.
            if (!unblockFirstTriesCovered(&run, plan, done, attempted, abandoned, lim))
                continue :outer;
            attempt = (try unblockNextGap(&run, attempt.net_i)) orelse continue :outer;
        }
    }
    return run.baseline;
}

/// The share of the phase tail the BREADTH round may spend, as a divisor.
///
/// HALF, and for the same reason the reserve one tier up keeps a share standing
/// for the phases behind it (`unblock_reserve_share_num`): a round that asks
/// every target one cheap question is only worth running
/// if the answers can then be ACTED on, and a breadth round that eats the whole
/// tail has replaced two finished targets with five diagnosed ones. Round 1 gets
/// half the remainder split across its targets; round 2 spends the rest on the
/// answers that earned it.
const unblock_breadth_share_div: i128 = 2;

/// Round 1 (breadth), then round 2's CONCENTRATED plan — or `targets` untouched
/// on a board that has no clock to split.
///
/// The two-round split is DEADLINE-GATED, so every bench, corpus and test route
/// runs the single pass it always has, target for target and transaction for
/// transaction. A board with one target is likewise left alone: breadth is a
/// scheduling answer to several targets sharing one tail, and with a single
/// target there is nothing to schedule and a bounded probe would only spend part
/// of its own ladder's budget.
fn unblockRounds(
    run: *UnblockRun,
    targets: []const target_unblock.Target,
    lim: target_unblock.Limits,
) std.mem.Allocator.Error![]const target_unblock.Target {
    if (run.options.stop.deadline_ns == 0 or targets.len < 2) return targets;
    const earned = try unblockBreadthRound(run, targets, lim);
    const ordered = try unblockByPromise(run.alloc, targets, earned);
    const funded = try unblockFundedPlan(run, ordered, lim);
    const ladders = unblockDistinctNets(funded, run.placement.nets.len);
    routeLog("unblock round 2: funding {d} deep ladders ({s})", .{
        ladders,
        try unblockPlanNetNames(run.alloc, run.placement, funded),
    });
    // A repeat rung is a SECOND ladder on a target the pass has already asked,
    // and `unblockFundedPlan` has just queued every one of them behind the
    // funded targets it has not. Say how many, so a reader can tell a run whose
    // depth went to distinct targets from one where a hydra took it all.
    if (funded.len > ladders) {
        routeLog("unblock round 2: {d} repeat rung(s) dealt behind every fresh ladder", .{funded.len - ladders});
    }
    return funded;
}

/// ONE narrow transaction per open NET, under a bounded slice, before any target
/// is given a ladder.
///
/// One per net rather than one per target, because that is the guarantee the
/// rest of the pass already counts in nets (`unblockFirstTriesOwed`): a rail
/// whose pockets fill several planned slots is one open net with one first
/// question, and giving each pocket its own breadth probe would rebuild the
/// monopoly `max_gap_transactions` exists to prevent.
///
/// An ACCEPT commits exactly as it does in the depth round — the board is the
/// board — but the net does not re-enter for its next gap here: re-entry is a
/// ladder, and this round's product is a verdict per target. The ladder runs in
/// round 2, over a list this round has ordered.
fn unblockBreadthRound(
    run: *UnblockRun,
    targets: []const target_unblock.Target,
    lim: target_unblock.Limits,
) std.mem.Allocator.Error!BreadthVerdicts {
    const promise = try run.alloc.alloc(UnblockPromise, run.placement.nets.len);
    @memset(promise, .unanswered);
    const rip = try run.alloc.alloc(usize, run.placement.nets.len);
    @memset(rip, 0);
    const probed = try run.alloc.alloc(bool, run.placement.nets.len);
    @memset(probed, false);
    var left = unblockDistinctNets(targets, promise.len);
    const planned = left;
    run.ladder = .breadth;
    defer {
        run.ladder = .depth;
        run.lim = lim;
    }
    var verdicts: usize = 0;
    var closed: usize = 0;
    for (targets) |target| {
        if (target.net_i >= probed.len or probed[target.net_i]) continue;
        const share = UnblockShare{ .board_deadline_ns = run.options.stop.deadline_ns, .targets_left = left };
        const now = clock.nanoTimestamp();
        const round_lim = unblockBreadthLimits(lim, now, share.board_deadline_ns, left);
        if (target_unblock.sliceDeadline(now, share.board_deadline_ns, left, round_lim) == null) break;
        probed[target.net_i] = true;
        left -|= 1;
        run.lim = round_lim;
        const outcome = try unblockOne(run, target, share, round_lim);
        promise[target.net_i] = unblockPromiseOf(outcome);
        rip[target.net_i] = outcome.picked.len;
        verdicts += 1;
        if (outcome.accepted) closed += 1;
        routeLog("unblock round 1 {s}: {s}", .{
            run.placement.nets[target.net_i].name,
            promise[target.net_i].label(),
        });
    }
    routeLog("unblock round 1: {d} targets, {d} verdicts, {d} closed", .{ planned, verdicts, closed });
    return .{ .promise = promise, .rip = rip };
}

/// What round 1 learned about each net, by flattened net index: the verdict, and
/// how much copper the transaction that earned it had to rip to get there.
///
/// The rip count is the "(N blockers)" the rollback line already prints — it is
/// `outcome.picked.len`, not a new measurement — and it is carried because it is
/// the one thing separating two otherwise identical `deepenable` verdicts (see
/// `promiseFirst`).
const BreadthVerdicts = struct {
    promise: []const UnblockPromise,
    rip: []const usize,
};

/// How many distinct NETS a planned target list covers.
fn unblockDistinctNets(targets: []const target_unblock.Target, nets: usize) usize {
    var count: usize = 0;
    for (targets, 0..) |t, i| {
        if (t.net_i >= nets) continue;
        if (!unblockNetSeen(targets[0..i], t.net_i)) count += 1;
    }
    return count;
}

/// Does an earlier stretch of the plan already name this net?
fn unblockNetSeen(earlier: []const target_unblock.Target, net_i: usize) bool {
    for (earlier) |before| if (before.net_i == net_i) return true;
    return false;
}

/// The narrow tier's own bounds with the SLICE CAP cut to a breadth probe's
/// share of the tail, and a POUR-CARRIED blocker lifted corridor-only.
///
/// The clock and that one nomination granularity, and nothing else: what a
/// breadth transaction may rip, which other classes it may negotiate and how its
/// candidate is judged are the narrow tier's, byte for byte. The cap is floored
/// at `slice.min_ns` (below that no transaction is worth starting at all) and
/// never raised above the narrow tier's own measured cap.
///
/// `ns_per_element` is zeroed so `restoreDeadline` cannot grow the cap back on
/// the strength of how much copper the rip turned out to take: that growth is
/// exactly the "one target claims the tail" behaviour this round defers to round
/// 2, where it is switched back on.
///
/// `plane_corridor` is on because this round is TIMED BY CONSTRUCTION and the
/// whole-net charge is what it cannot afford. A pour-carried rail lying across a
/// corridor is nominated at its whole copper — measured on barracuda,
/// `V_3V3_LMX` at 66 elements against ~8 of it in the corridor — so the probe's
/// restore, and the gate that has to prove it, are sized by copper the join
/// never needed moved: the `LOCK_DET` and `SPI_LMX_CSN` probes each spent 20-30 s
/// putting a whole pour back, and round 1 as a whole cost ~90 s of a tail round 2
/// then had to fund its ladders out of. The lift is the SAME mechanism the wide
/// tier and the deepening round already use (`target_unblock.liftFacts`), under
/// the same pad-by-pad connectivity gate, so a probe that closes under it is a
/// real close and commits exactly as it does today. It answers a slightly
/// SMALLER question — a corridor lift frees less copper than a whole rip — and
/// that is priced in where it lands: a probe refused on geometry keeps whatever
/// verdict `unblockPromiseOf` reads off it, and round 2's depth ladder keeps the
/// narrow tier's whole-rip authority untouched. `pairs` stays OFF: a coupled
/// re-construction is a second board a bounded probe has no budget for, and the
/// wide tier is still the only tier that recouples.
///
/// A clock-free board never reaches this round at all (`unblockRounds` returns
/// its targets untouched), so every bench, corpus and test route keeps the
/// whole-rip breadth it has always had, byte for byte.
fn unblockBreadthLimits(
    lim: target_unblock.Limits,
    now: i128,
    board_deadline: i128,
    targets: usize,
) target_unblock.Limits {
    var out = lim;
    out.slice.ns_per_element = 0;
    out.negotiate.plane_corridor = true;
    if (board_deadline == 0 or targets == 0) return out;
    const remaining = board_deadline - lim.slice.reserve_ns - now;
    if (remaining <= 0) return out;
    const cap = @divTrunc(remaining, @as(i128, @intCast(targets)) * unblock_breadth_share_div);
    out.slice.max_ns = @min(lim.slice.max_ns, @max(lim.slice.min_ns, cap));
    return out;
}

/// What one breadth transaction learned about its target, and the order round 2
/// funds ladders in.
///
/// Declared best-first, so the enum's own order IS the funding order and there
/// is no second table to keep in step with it.
const UnblockPromise = enum {
    /// The transaction was ACCEPTED. This net has proved a transaction of its
    /// own closes on this board, which is the strongest evidence the round can
    /// produce — its ladder is the one most likely to merge another island.
    closed,
    /// The candidate CLOSED the target and a net the rip took did not come back.
    /// An accept finishes it: the alternate nomination and the coupled re-home
    /// are the two depth tools written for exactly this verdict, and neither is
    /// affordable inside a breadth probe.
    victim_lost,
    /// Refused with a BOARD to show for it: the rip ran, every blocker came
    /// back, the target still cannot cross — and the sweep named copper a deeper
    /// tier may take. This is `unblockDeepen`'s own entry condition, read off
    /// the outcome, and it is the reason the rank exists: a deepening round
    /// diagnoses the candidate board its transaction produced, so a target that
    /// produced no board cannot enter one however reachable its refusals were.
    ///
    /// Measured on barracuda (Debug, v100): all five open nets earned the flat
    /// `depth_reachable` below, K=1 funded `SPI_DSA_CSN` on plan order alone,
    /// and its ladder had nothing to climb — the narrow transaction repeated its
    /// round-1 verdict ("no legal path across the freed corridor"), the wide
    /// tier is unaffordable at Debug by construction, and the two nets that HAD
    /// rolled back a re-routed board (`SPI_LMX_CSN`, `V_3V3A`) were released
    /// unasked.
    deepenable,
    /// Refused, and the sweep named copper only a WIDER or DEEPER tier may take
    /// (`unblockDepthReachable`) — a declared pair, an outranking net, or a
    /// candidate the narrow bounds capped out. The depth round has authority
    /// this probe did not, but no board of this target's own to spend it on:
    /// the escalation left is the wide tier's bigger corridor.
    depth_reachable,
    /// No board verdict at all: the slice, an error, or a hop that resolved to
    /// nothing. The round bought no evidence, so a full slice may still buy some.
    unanswered,
    /// Nothing rippable in its corridor under narrow bounds, and nothing the
    /// deeper tiers could reach either. A wider corridor band may still find
    /// copper, so it outranks a sealed verdict and nothing else.
    no_rip,
    /// The board answered on GEOMETRY — the corridor was freed, the blockers
    /// came back, the target still cannot cross — and the sweep named nothing a
    /// deeper tier may take. Last, deliberately: this is the one verdict that
    /// says more rip authority is not the lever, so its ladder is the one to
    /// starve when several targets are sharing one tail.
    sealed,

    /// One line of prose per verdict — what a reader needs in order to know
    /// which lever, if any, moves this target.
    fn label(self: UnblockPromise) []const u8 {
        return switch (self) {
            .closed => "closed — accepted in the breadth round",
            .victim_lost => "closed, but a ripped net did not come back — an accept finishes it",
            .deepenable => "rolled back a re-routed board a deepening round can diagnose",
            .depth_reachable => "refused, and a deeper tier can still reach copper it could not",
            .unanswered => "no board verdict — the probe bought no evidence",
            .no_rip => "no rippable copper in its corridor",
            .sealed => "geometry, and no class a deeper tier may negotiate",
        };
    }
};

/// Which verdict one breadth outcome earned.
///
/// Ordered as the questions are asked rather than as the enum is declared: an
/// accept beats everything, a lost victim is the refusal an accept is nearest
/// to, and the reachability of a deeper class is asked BEFORE the two "nothing
/// happened" readings, because a sweep that refused a declared pair reports no
/// picks at all and would otherwise read as an empty corridor.
///
/// The two reachable ranks are separated by ONE question — did the transaction
/// produce a board? — asked exactly as `unblockOne` asks it before entering a
/// deepening round: `geometry` is `unblockRolledBackOnGeometry`'s reading, and a
/// null `dead` is what says a candidate existed to read it off. So "which
/// verdict round 2 can escalate" has one definition rather than a second
/// spelling here.
fn unblockPromiseOf(outcome: UnblockOutcome) UnblockPromise {
    if (outcome.accepted) return .closed;
    if (outcome.lost_victim != null) return .victim_lost;
    if (unblockDepthReachable(outcome.refused)) {
        return if (outcome.geometry and outcome.dead == null) .deepenable else .depth_reachable;
    }
    if (outcome.picked.len == 0) return .no_rip;
    if (outcome.geometry) return .sealed;
    return .unanswered;
}

/// Did the sweep decline copper a WIDER or DEEPER tier is allowed to take?
fn unblockDepthReachable(refused: []const vacate_policy.Refused) bool {
    for (refused) |r| if (unblockDepthClass(r.why)) return true;
    return false;
}

/// Is this refusal one a depth tier answers?
///
/// Three of them are, and each names its tier: `diff_pair` is the wide tier's
/// `negotiate.pairs`, `outranks_seed` is the deepening round's
/// `negotiate.outranking`, and `capped` / `over_budget` are the wide tier's
/// bigger bounds. The rest are refusals no rip authority moves — the seed
/// itself, the board's reference copper, a `(max-freq …)` net, a via fence, a
/// net that is itself still open, and copper that is simply not cheap to put
/// back at any tier this phase has.
fn unblockDepthClass(why: vacate_policy.Refusal) bool {
    return switch (why) {
        .diff_pair, .outranks_seed, .capped, .over_budget => true,
        .seed, .ground, .rf_max_freq, .fenced, .not_whole, .not_cheap => false,
    };
}

/// What ONE funded deep ladder is budgeted at when round 2 decides how many of
/// them the remainder can run: the WIDE tier's own base slice cap.
///
/// A ladder is four tiers — the narrow retry, its alternate nomination, the wide
/// retry, and up to two deepening rounds — and none of the three ways of pricing
/// it is obvious, so the choice is made on what each one BUYS.
///
/// The SUM (10 + 10 + 45 + 2x30 = 125 s) prices a ladder nothing this phase can
/// afford: the tail is `unblock_reserve_max_ns` = 100 s at its absolute biggest,
/// so budgeting the sum funds ZERO ladders on every board the phase runs on and
/// round 2 stops existing. The NARROW tier alone (10 s) is what the previous
/// estimate quoted, and it is the degeneracy this constant replaces: measured on
/// barracuda (ReleaseSafe, v99), round 2 "funded 4 deep ladders" out of ten
/// admitted targets, priced every wide retry against ten remaining targets at
/// `unblock_wide_gate_ns` each, and so ran four narrow transactions with SMALLER
/// slices than round 1's — the same question, asked worse.
///
/// So the price is the biggest SINGLE slice a ladder can seat. Everything below
/// the wide tier is cheaper than it by construction, and everything above it
/// (both deepening windows) claims what is left over rather than a budget of its
/// own — `deepenDeadline` takes at most `deepen_window_ns` of the remainder and
/// leaves a floor standing for every funded ladder behind it. A board that
/// cannot seat one wide retry cannot escalate at all, and funding a second
/// ladder it cannot seat is exactly how the first one loses its own.
const unblock_ladder_price_ns: i128 = unblock_wide_limits.slice.max_ns;

/// How many full deep ladders the remainder GENUINELY funds — the number of
/// targets round 2 concentrates everything it has left on.
///
/// Bounded by the nets there are to fund, and floored at ONE while there is any
/// remainder at all: the tiers below `unblock_ladder_price_ns` are cheaper than
/// the price, a slice the board cannot seat is refused by `sliceDeadline` at the
/// door for free, and funding nobody throws away the whole reason the breadth
/// round ranked its verdicts. A clock-free board funds every net, which is the
/// single-round pass it has always run.
fn unblockFundedLadders(run: *UnblockRun, nets: usize, lim: target_unblock.Limits) usize {
    if (nets == 0) return 0;
    if (run.options.stop.deadline_ns == 0) return nets;
    const remaining = run.options.stop.deadline_ns - lim.slice.reserve_ns - clock.nanoTimestamp();
    if (remaining <= 0) return 0;
    const affordable: usize = @intCast(@divTrunc(remaining, unblock_ladder_price_ns));
    return @min(nets, @max(1, affordable));
}

/// Round 2's plan: the K nets the remainder can fund, in promise order, with
/// their rungs DEALT round-robin — every funded ladder's first rung before any
/// ladder's second — and nothing else.
///
/// RELEASING the rest is the point. Round 1 has already bought each of them a
/// board verdict, and that verdict is what they keep — but a target still in the
/// plan is a target every price in the pass divides by (`unblockLiveTargets` for
/// the slice, `unblockFirstTriesCovered` for the re-entry floor,
/// `wideUnblockAffordable` for the escalation gate, `deepenDeadline` for the
/// deepening window), so holding a floor for a target whose answer is already in
/// hand is how a "funded deep ladder" became a narrower repeat of round 1.
///
/// DEALING them is the other half, and it is what stops one target absorbing
/// every ladder the remainder funds. The ladder is the net and a net's per-gap
/// slots are that ladder's rungs — but `unblockByPromise` ranks NETS, so all of
/// one net's rungs share a rank and land adjacent, and a net with several of them
/// takes a full ladder per rung before the next funded net gets its first.
/// Measured on barracuda (ReleaseSafe, v100 and v101): `V_3V3A` absorbed the one
/// funded ladder of each run, its deepening freeing a blocker only to reveal
/// another (1 → 3 → 4), while `LOCK_DET` — whose deepening terminal
/// `V_24V_CLEAN` has been rank-negotiable since the round existed — has never had
/// a funded deepening round at all. So a rung is spent on a target the pass has
/// not asked yet before it is spent on a second round of one it has, and a
/// hydra's later rungs queue behind every fresh ladder rather than in front of
/// them.
///
/// It is an ORDER and not a cut: every funded net keeps every rung it had, and a
/// board funding one ladder deals that ladder's rungs in exactly the order it
/// always did. A clock-free board never reaches this function.
fn unblockFundedPlan(
    run: *UnblockRun,
    ordered: []const target_unblock.Target,
    lim: target_unblock.Limits,
) std.mem.Allocator.Error![]const target_unblock.Target {
    const ladders = unblockFundedLadders(run, unblockDistinctNets(ordered, run.placement.nets.len), lim);
    var funded: std.ArrayList(usize) = .empty;
    for (ordered, 0..) |target, i| {
        if (unblockNetSeen(ordered[0..i], target.net_i)) continue;
        if (funded.items.len == ladders) break;
        try funded.append(run.alloc, target.net_i);
    }
    var kept: std.ArrayList(target_unblock.Target) = .empty;
    var rung: usize = 0;
    while (kept.items.len < ordered.len) : (rung += 1) {
        const before = kept.items.len;
        for (funded.items) |net_i| {
            if (unblockNetRung(ordered, net_i, rung)) |target| try kept.append(run.alloc, target);
        }
        if (kept.items.len == before) break;
    }
    return kept.items;
}

/// The `rung`-th target this net holds in plan order, or null once its ladder
/// has no more.
fn unblockNetRung(
    ordered: []const target_unblock.Target,
    net_i: usize,
    rung: usize,
) ?target_unblock.Target {
    var seen: usize = 0;
    for (ordered) |target| {
        if (target.net_i != net_i) continue;
        if (seen == rung) return target;
        seen += 1;
    }
    return null;
}

/// The funded nets, named in plan order, for the timeline line — because "K deep
/// ladders" without WHICH ones cannot be checked against the round-1 verdicts
/// printed directly above it.
fn unblockPlanNetNames(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    plan: []const target_unblock.Target,
) std.mem.Allocator.Error![]const u8 {
    var names: std.ArrayList(u8) = .empty;
    for (plan, 0..) |target, i| {
        if (target.net_i >= placement.nets.len) continue;
        if (unblockNetSeen(plan[0..i], target.net_i)) continue;
        if (names.items.len != 0) try names.appendSlice(alloc, ", ");
        try names.appendSlice(alloc, placement.nets[target.net_i].name);
    }
    if (names.items.len == 0) return "none";
    return names.items;
}

/// One planned target with the round-1 verdict its NET earned, what that verdict
/// cost to reach, and where the plan originally put it — the three keys round 2
/// is ordered by.
const PromisedTarget = struct {
    target: target_unblock.Target,
    rank: usize,
    /// How much copper round 1 had to rip to earn the verdict — carried ONLY for
    /// a `deepenable` one and zero for every other rank, so the key is inert
    /// outside the bucket it was measured for (see `promiseFirst`).
    rip: usize,
    at: usize,
};

/// The rip count this target sorts by: round 1's, for a `deepenable` verdict,
/// and zero for every other rank.
///
/// Zero rather than "skip the key", because a rank whose every member scores
/// zero falls straight through to plan order — which is exactly the ordering
/// those ranks had before the key existed, with no second code path to keep in
/// step with it.
fn promisedRip(verdict: UnblockPromise, ripped: usize) usize {
    return if (verdict == .deepenable) ripped else 0;
}

/// Best promise first; within a `deepenable` promise the CHEAPEST rollback
/// first; within either, the plan's own order. Fully determined by that triple,
/// so the sort needs no stability guarantee of its own.
///
/// The middle key exists because the top bucket is otherwise flat and the pick
/// is what round 2 spends everything on. Both members of it have the same
/// evidence — a board, rolled back, still open — but not the same PRICE: a
/// deepening round re-sweeps, re-rips and re-routes everything the first
/// transaction took plus whatever it adds, so the transaction that reached its
/// verdict on less copper is the one the same remainder buys more rounds of.
/// Measured on barracuda (Debug, v101): `SPI_LMX_CSN` won the bucket on plan
/// order with a 71-element rip (a 66-element pour among them) and a 10.6 s gate
/// that overran its slice, leaving its deepening round nothing to run in, while
/// `V_3V3A` had rolled a board back on a single 4-element stub.
fn promiseFirst(_: void, a: PromisedTarget, b: PromisedTarget) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    if (a.rip != b.rip) return a.rip < b.rip;
    return a.at < b.at;
}

/// The same targets, re-ordered so round 2 spends what is left on the verdicts
/// that earned it. This step only RE-QUEUES — every planned target survives it,
/// so a board with the budget for every ladder still runs them all. Which of
/// them the budget actually reaches is `unblockFundedPlan`'s question, asked
/// against this order.
fn unblockByPromise(
    alloc: std.mem.Allocator,
    targets: []const target_unblock.Target,
    earned: BreadthVerdicts,
) std.mem.Allocator.Error![]const target_unblock.Target {
    const ranked = try alloc.alloc(PromisedTarget, targets.len);
    for (targets, ranked, 0..) |target, *slot, i| {
        const known = target.net_i < earned.promise.len;
        const verdict: UnblockPromise = if (known) earned.promise[target.net_i] else .unanswered;
        slot.* = .{
            .target = target,
            .rank = @backingInt(verdict),
            .rip = promisedRip(verdict, if (known) earned.rip[target.net_i] else 0),
            .at = i,
        };
    }
    std.mem.sort(PromisedTarget, ranked, {}, promiseFirst);
    const out = try alloc.alloc(target_unblock.Target, targets.len);
    for (ranked, out) |slot, *target| target.* = slot.target;
    return out;
}

/// How many LADDERS are still live at this point in the pass — the one being
/// attempted, plus every distinct net behind it that has not been abandoned.
///
/// This is the divisor the remaining budget is split by, and counting a turn the
/// pass will never take hands its share to nobody. The planned count
/// (`targets.len - done`) cannot see that: a rail whose per-gap targets fill
/// several slots keeps every one of them in the divisor after its first refusal
/// abandoned the net, so each target still standing is quoted a share of a
/// remainder that no longer has anyone to spend it.
///
/// It counts NETS for the same reason `unblockFirstTriesOwed` does, and the two
/// are now the same census at two scales. Round 2 funds LADDERS
/// (`unblockFundedPlan`), and a funded net's several planned slots are that one
/// ladder's rungs — so quoting each slot its own share divides a ladder's budget
/// by its own length. Measured on barracuda (Debug, v101): the funded ladder
/// reached its deepening round and found the window priced against slots it had
/// not spent. A net's own re-entries were never extra live targets either; this
/// only makes the planned slots agree with them.
fn unblockLiveTargets(
    targets: []const target_unblock.Target,
    done: usize,
    abandoned: []const bool,
) usize {
    if (done >= targets.len) return 1;
    const here = targets[done].net_i;
    const rest = targets[done + 1 ..];
    var live: usize = 1;
    for (rest, 0..) |ahead, i| {
        if (ahead.net_i == here or abandoned[ahead.net_i]) continue;
        var seen = false;
        for (rest[0..i]) |before| {
            if (before.net_i == ahead.net_i) seen = true;
        }
        if (!seen) live += 1;
    }
    return live;
}

/// Is there still enough of the budget left for every planned target behind this
/// one to get its FIRST attempt, after one more rung of the ladder in hand?
///
/// A ladder is re-entry, and re-entry is the one thing in this pass that can take
/// a turn nobody planned. Both re-entry paths are otherwise unbounded in the
/// tail: measured on barracuda, `GND` earns two accepts, then retires two refused
/// hops and takes two more rungs, and the two whole-net targets behind it — the
/// board's ONLY single-gap open nets, and so the only two a single accepted
/// transaction could close outright — got no attempt at all. That is the monopoly
/// `max_gap_transactions` exists to prevent, arriving through the door re-entry
/// opened.
///
/// So a rung is admitted only while the remainder still covers a floor slice for
/// itself AND one for each net still owed a first attempt. The floor rather than
/// a full share, because this is a guarantee that the turn HAPPENS, not a claim
/// about what it will achieve — `sliceDeadline` still sizes what each one gets.
/// A clock-free board answers yes and keeps today's ladder exactly.
fn unblockFirstTriesCovered(
    run: *UnblockRun,
    targets: []const target_unblock.Target,
    done: usize,
    attempted: []const bool,
    abandoned: []const bool,
    lim: target_unblock.Limits,
) bool {
    if (run.options.stop.deadline_ns == 0) return true;
    const left = run.options.stop.deadline_ns - clock.nanoTimestamp() - lim.slice.reserve_ns;
    return left >= @as(i128, @intCast(unblockFirstTriesOwed(targets, done, attempted, abandoned) + 1)) *
        lim.slice.min_ns;
}

/// How many NETS behind this target are still owed a first attempt — one per net,
/// however many slots the plan gave it, and none for a net already attempted or
/// already abandoned.
fn unblockFirstTriesOwed(
    targets: []const target_unblock.Target,
    done: usize,
    attempted: []const bool,
    abandoned: []const bool,
) usize {
    var owed: usize = 0;
    const rest = targets[@min(done + 1, targets.len)..];
    for (rest, 0..) |ahead, i| {
        if (abandoned[ahead.net_i] or attempted[ahead.net_i]) continue;
        var seen = false;
        for (rest[0..i]) |before| {
            if (before.net_i == ahead.net_i) seen = true;
        }
        if (!seen) owed += 1;
    }
    return owed;
}

/// One target's whole attempt: the narrow transaction, then the wide one when
/// the board can afford it AND the wide one would answer a different question.
/// True when either was ACCEPTED; null when there is no slice left to start one
/// in, which ends the pass.
fn unblockAttempt(
    run: *UnblockRun,
    target: target_unblock.Target,
    targets_left: usize,
    lim: target_unblock.Limits,
) std.mem.Allocator.Error!?bool {
    const share = UnblockShare{
        .board_deadline_ns = run.options.stop.deadline_ns,
        .targets_left = targets_left,
    };
    // The pass ENDS when the remainder can no longer start a transaction at all,
    // and that has to be answered before one is formed — nominating a corridor's
    // blockers is itself work, and a pass with no slice left must not pay for it.
    // The slice the transaction finally runs under is sized after nomination
    // (see `unblockOne`), never before.
    _ = target_unblock.sliceDeadline(clock.nanoTimestamp(), share.board_deadline_ns, targets_left, lim) orelse
        return null;
    run.lim = lim;
    const narrow = try unblockOne(run, target, share, lim);
    if (narrow.accepted) return true;
    // The narrow transaction refused BECAUSE OF ITS OWN RIP: one alternate
    // nomination without the net it could not put back, before any wider one.
    if (try unblockAlternate(run, target, share, lim, narrow, targets_left)) return true;
    // The narrow transaction refused. On a board with time to spare, ask
    // once more with a corridor's worth of rip authority.
    const now = clock.nanoTimestamp();
    // The slice follows the work it was sized to do: the same corridor
    // arithmetic that decides how much copper this transaction may rip
    // decides how long it gets to put that copper back.
    const wide_lim = target_unblock.corridorSlice(unblock_wide_limits, target.gap_mm);
    if (!wideUnblockAffordable(now, share.board_deadline_ns, targets_left)) return false;
    if (target_unblock.sliceDeadline(now, share.board_deadline_ns, targets_left, wide_lim) == null) return false;
    run.lim = wide_lim;
    if (narrow.geometry and !try unblockWideAddsAuthority(run, target, narrow.picked)) {
        run.lim = lim;
        return false;
    }
    routeLog("target unblock {s}: retrying wide ({d} blockers, {d} elements, {d}s cap, pairs negotiable)", .{
        run.placement.nets[target.net_i].name,
        wide_lim.blockers.max_nets,
        target_unblock.corridorLimits(wide_lim, target.gap_mm).max_total_elements,
        @divTrunc(wide_lim.slice.max_ns, clock.ns_per_s),
    });
    const wide = try unblockOne(run, target, share, wide_lim);
    if (wide.accepted) {
        run.lim = lim;
        return true;
    }
    // The WIDE transaction can lose a victim exactly as the narrow one can, and
    // it is the tier that reaches the expensive classes — a declared pair, a
    // corridor-lifted rail — so it is the tier whose rip is MOST likely to be
    // the reason a closed target is rolled back. Measured on barracuda
    // (ReleaseSafe, v95 and Debug): `SPI_DSA_CSN`'s narrow attempt refused on
    // geometry, the wide retry then closed the target and was rolled back
    // because `REF_LMX_N` did not come back — and the alternate nomination was
    // never asked, because this tail read `wide.accepted` and threw the rest of
    // the outcome away. One more narrow-priced nomination, under the tier that
    // formed the transaction, so the wide rip's own victim can be held out.
    const alt = try unblockAlternate(run, target, share, wide_lim, wide, targets_left);
    run.lim = lim;
    return alt;
}

/// ONE alternate nomination after a transaction the board refused only because a
/// net it RIPPED could not be put back.
///
/// That verdict says nothing against the corridor: it was freed, the target
/// crossed it, and the price turned out to be a victim the restore could not
/// re-home even with the shape channel behind it (`unblockRehome`). Measured on
/// barracuda (ReleaseSafe, v92), it is the board's nearest close — `GND` finished
/// as one 1.27 mm hop and was rolled back because `V_3V3_ID` did not come back —
/// and neither existing retry answers it: a wider rip takes MORE copper out,
/// including the copper that was already too dear to replace, and the ladder's
/// gap retirement moves to a different hop entirely.
///
/// So the same gap is asked once more with exactly that net held out of the
/// sweep. The nomination is ranked by restore cheapness already, so holding the
/// one pick that proved expensive is enough to reach a different corridor
/// occupant — and if the sweep has nobody else, the transaction simply does not
/// form and costs a nomination.
///
/// Bounded to ONE retry per attempt, spent only on the narrow refusal (never
/// behind the wide tier), and priced at THE TIER IT RUNS — one more narrow
/// transaction, so `alternateAffordable` asks whether a narrow slice can still
/// be cut, not whether the board could seat a wide one. A run with no deadline
/// still answers NO, so every bench and corpus route stays byte-identical.
fn unblockAlternate(
    run: *UnblockRun,
    target: target_unblock.Target,
    share: UnblockShare,
    lim: target_unblock.Limits,
    refused: UnblockOutcome,
    targets_left: usize,
) std.mem.Allocator.Error!bool {
    if (refused.accepted) return false;
    const victim = refused.lost_victim orelse return false;
    if (victim >= run.placement.nets.len or target.net_i >= run.placement.nets.len) return false;
    if (!alternateAffordable(clock.nanoTimestamp(), share.board_deadline_ns, targets_left, lim)) return false;
    run.alternates += 1;
    const name = run.placement.nets[target.net_i].name;
    const held = run.placement.nets[victim].name;
    routeLog("target unblock {s}: retrying with {s} held", .{ name, held });
    run.held = victim;
    defer run.held = null;
    const alt = try unblockOne(run, target, share, lim);
    if (alt.accepted) return true;
    routeLog("target unblock {s}: alternate nomination refused with {s} held", .{ name, held });
    return false;
}

/// Would the WIDE tier's nomination reach copper the narrow one could not?
///
/// Asked only after a GEOMETRY refusal, and that is the whole rule. The wide
/// tier's justification is bigger rip authority, which answers a budget, a
/// no-rippable or a blockers-did-not-restore refusal; it does not answer "the
/// corridor was freed and the target still cannot cross it". More elements of
/// the SAME classes rip more copper out of a channel whose geometry already
/// said no — unless the wider nomination reaches one of the two classes the
/// narrow tier may not touch at all (a declared pair it will re-lay coupled, a
/// plane- or pour-carried net it will lift corridor-only), which is a different
/// corridor rather than a bigger one.
///
/// Measured on barracuda (Debug, v91): `V_3V3A`'s per-gap narrow transaction
/// verdicted "rolled back — re-routed and still open (1 blockers)", and the wide
/// retry then ripped the same one blocker plus generic growth to 130 elements,
/// burned ~45 s of a 74 s phase tail, and returned the identical verdict — while
/// `GND`, one 1.27 mm accept from a closed net, was never attempted.
///
/// The nomination sweep runs a SECOND time here, and deliberately: it is the
/// cheap half of a transaction (~1.4 s against a 45 s wide slice on this board),
/// it has to be run under the wide bounds to answer the question at all, and it
/// is paid only on the path that was otherwise about to spend that whole slice.
fn unblockWideAddsAuthority(
    run: *UnblockRun,
    target: target_unblock.Target,
    narrow: []const vacate_policy.Nomination,
) std.mem.Allocator.Error!bool {
    const name = run.placement.nets[target.net_i].name;
    const picked = try unblockBlockers(run, target);
    if (unblockNewAuthority(picked, narrow, run.lim.negotiate)) |pick| {
        if (pick.net_i < run.placement.nets.len) {
            routeLog("target unblock {s}: wide adds {s} ({s}) the narrow rip could not reach", .{
                name,
                run.placement.nets[pick.net_i].name,
                @tagName(pick.kind),
            });
        }
        return true;
    }
    routeLog("target unblock {s}: wide skipped — no new authority ({d} wide picks, {d} narrow, geometry verdict)", .{
        name,
        picked.len,
        narrow.len,
    });
    return false;
}

/// The first wide nomination that is BOTH a negotiated class and a net the
/// narrow rip did not already hold, or null when the wider sweep is the same
/// authority spelled larger.
///
/// A net the narrow transaction already ripped is not new authority however the
/// wide tier classes it: the corridor lift is a SMALLER rip of copper that was
/// already removed whole (`unblockLifted`), so re-nominating it cannot free
/// anything the geometry verdict was not already measured against.
fn unblockNewAuthority(
    wide: []const vacate_policy.Nomination,
    narrow: []const vacate_policy.Nomination,
    negotiate: target_unblock.Negotiable,
) ?vacate_policy.Nomination {
    for (wide) |pick| {
        if (!unblockNegotiatedClass(pick.kind, negotiate)) continue;
        if (unblockAlreadyPicked(narrow, pick.net_i)) continue;
        return pick;
    }
    return null;
}

/// Is this nomination class one only a NEGOTIATING tier can reach?
///
/// Read off the same switches `target_unblock.pairFacts`, `liftFacts` and
/// `rankFacts` gate them on, so "what a negotiating tier can do that an ordinary
/// one cannot" has one definition rather than a second spelling here. A short
/// stub is none of them: it is ordinary rippable copper every tier reaches, and
/// only the element budget separates how much of it they take.
fn unblockNegotiatedClass(kind: vacate_policy.Kind, negotiate: target_unblock.Negotiable) bool {
    return switch (kind) {
        .pair_recouple => negotiate.pairs,
        .pour_carried => negotiate.plane_corridor,
        .rank_lifted => negotiate.outranking,
        .short_stub => false,
    };
}

/// Did this rip already hold authority over the net?
fn unblockAlreadyPicked(picked: []const vacate_policy.Nomination, net_i: usize) bool {
    for (picked) |pick| if (pick.net_i == net_i) return true;
    return false;
}

/// Is this net one the alternate nomination is holding out of the transaction it
/// is forming — the lost victim itself, or the TWIN it comes back coupled with?
///
/// The twin half is not a nicety. A pair is ripped, re-laid and judged as one
/// thing (`unblockPairsHeld`), so holding one leg out while the sweep nominates
/// the other re-forms the identical transaction under the other leg's name.
/// Measured on barracuda (Debug, this increment): the alternate held `REF_LMX_N`
/// and the very next sweep picked `REF_LMX_P` (pair_recouple, 38 elements, with
/// its twin) — the same 38 elements of the same pair, and the same refusal.
fn unblockHeldOut(run: *UnblockRun, net_i: usize) bool {
    const held = run.held orelse return false;
    if (net_i == held) return true;
    const held_pair = diffPairIndex(run.placement, held) orelse return false;
    const pair_i = diffPairIndex(run.placement, net_i) orelse return false;
    return pair_i == held_pair;
}

/// What one attempt may claim of the route budget: the board's own deadline and
/// how many targets are still sharing what is left of it.
///
/// Carried as the two INPUTS rather than as a computed deadline because the
/// deadline cannot be computed yet — its cap is sized by the restore the
/// transaction turns out to have to prove, which is not known until its blockers
/// are nominated.
const UnblockShare = struct {
    board_deadline_ns: i128,
    targets_left: usize,
};

/// This net's NEXT island-joining hop on the board its accepted transaction
/// just left, as a per-gap target, or null when it has none left to take.
///
/// The board is asked rather than the plan, for the same reason a transaction
/// looks its own gap up at execution time: the oracle renumbers a net's gaps the
/// moment any transaction lands, so the plan-time list is an ORDER and not an
/// inventory. Asking also supplies the bound — a net whose islands are all
/// joined has no next gap, and every accepted merge takes one off — and the hop
/// LENGTH, which is what sizes the corridor the wide tier would rip.
///
/// Eligibility is re-asked too, so a re-entry can never form a transaction the
/// planner would not have admitted in the first place.
fn unblockNextGap(
    run: *UnblockRun,
    net_i: usize,
) std.mem.Allocator.Error!?target_unblock.Target {
    if (net_i >= run.placement.nets.len) return null;
    if (!unblockGapEligible(run.placement, run.options, net_i)) return null;
    const open = try unblockOpenNet(run, net_i) orelse return null;
    const gap_i = unblockChosenGap(run.retired.items, net_i, open) orelse return null;
    return .{
        .net_i = net_i,
        .gap_mm = open.gaps[gap_i].mm,
        .kind = .one_gap,
        .gaps = open.gaps.len,
    };
}

/// The attempt list: every oracle-open net that is a two-terminal target this
/// layer may actually reroute, cheapest island gap first.
fn unblockTargets(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
    baseline: router.RouteResult,
    lim: target_unblock.Limits,
) std.mem.Allocator.Error![]const target_unblock.Target {
    const zones = try route_close.userZones(alloc, placement, options.existing_zones);
    const open = try fab_readiness.openNetsAmong(alloc, placement, .{
        .tracks = baseline.tracks,
        .vias = baseline.vias,
        .zones = zones,
    }, baseline.failed);
    var found: std.ArrayList(target_unblock.Target) = .empty;
    var per_gap_found: std.ArrayList(target_unblock.Target) = .empty;
    for (open) |detail| {
        const net_i = placementNetIndex(placement, detail.net) orelse continue;
        if (target_unblock.targetOf(net_i, openShape(detail))) |target| {
            // A whole-net target is rewritten wholesale, so the same
            // eligibility the cluster seeds demand applies: in scope, not
            // plane/pour-carried, not ground, diff-pair, RF or fenced, and
            // carrying no caller-retained copper.
            if (!fieldClusterSeedEligible(placement, options, net_i)) continue;
            try found.append(alloc, target);
            continue;
        }
        if (!unblockGapEligible(placement, options, net_i)) continue;
        var gap_mm: std.ArrayList(f64) = .empty;
        for (detail.gaps) |gap| try gap_mm.append(alloc, gap.mm);
        const per_gap = try target_unblock.gapTargets(alloc, net_i, openShape(detail), gap_mm.items, lim);
        for (per_gap) |target| try per_gap_found.append(alloc, target);
    }
    // A many-islanded net is attacked one gap at a time, and its transactions
    // are admitted only while the board can AFFORD them: they share the same
    // tail as the whole-net targets, and adding them to a board with seconds
    // left would only shrink everyone's slice (see `wideUnblockAffordable` for
    // the same rule and the same reason).
    //
    // The bound decides HOW MANY the tail can pay for; the ORDER decides WHICH.
    // Testing each candidate as the oracle happened to name it made admission a
    // function of arrival, which is how barracuda's cheapest target was lost:
    // with three whole-net targets found and 65 s of spare tail, `GND` — whose
    // shortest island gap is 1.00 mm, the most closable hop on the board — was
    // turned away at the door while 42-55 mm cross-board joins were kept, and
    // the closest-to-closed order this pass is built around never saw it.
    // Ordering the candidates first and taking the affordable prefix keeps the
    // count identical and spends it on the nets an accept would FINISH, which is
    // what the order is for; `target_unblock.order`'s round-robin still stops
    // one rail's pockets from filling the list.
    const ordered = try target_unblock.order(alloc, per_gap_found.items, lim);
    const admit = affordableGapCount(
        ordered.len,
        found.items.len,
        clock.nanoTimestamp(),
        options.stop.deadline_ns,
        lim,
    );
    for (ordered[0..admit]) |target| try found.append(alloc, target);
    return target_unblock.order(alloc, found.items, lim);
}

/// How many of the ordered per-gap candidates this board can pay for, on top of
/// the whole-net targets already found: the longest prefix whose per-target
/// share of the tail still buys that target its FIRST question.
///
/// A COUNT, deliberately, because a count is all affordability has to say.
/// WHICH candidates fill it is the order's business, and a clock-free board
/// admits none, exactly as it did when each candidate was tested where the
/// oracle happened to name it.
///
/// The price is `unblockAdmissible`'s and no longer `wideUnblockAffordable`'s.
/// Admission used to be quoted at the WIDE tier — 20 s of spare per remaining
/// target — because a target admitted to the old single-round pass took its
/// whole ladder in turn, so a board that could not seat everyone's ladder was
/// right to turn latecomers away at the door. The phase does not work that way
/// any more: every admitted target now gets one bounded breadth probe first
/// (`UnblockLadder`), and only the verdicts that earn it are funded a ladder.
/// Quoting the door at the wide tier's price under that schedule turns targets
/// away from the ROUND THEY COULD AFFORD. Measured on barracuda (Debug, this
/// increment): with 81 s reserved for six planned targets, three were admitted
/// and `SPI_SCK` and `V_3V3A` — the two the campaign has never had a
/// transaction verdict for — were refused entry, so the breadth round they
/// exist for could not reach them.
fn affordableGapCount(
    candidates: usize,
    already: usize,
    now: i128,
    deadline_ns: i128,
    lim: target_unblock.Limits,
) usize {
    var admitted: usize = 0;
    while (admitted < candidates) : (admitted += 1) {
        if (!unblockAdmissible(now, deadline_ns, already + admitted + 1, lim)) break;
    }
    return admitted;
}

/// Can the tail still buy one more TARGET its first question?
///
/// The floor slice, per target, exactly as `unblockFirstTriesCovered` prices a
/// first attempt one tier down — the two are the same guarantee at two scales
/// ("this target's turn HAPPENS"), and quoting them differently is what let the
/// door refuse targets the pass would then have had time for. What each turn
/// actually gets is still `sliceDeadline`'s, measured fresh when it starts.
///
/// A clock-free board admits none, which is what it did before and what keeps
/// every bench and corpus route byte-identical.
fn unblockAdmissible(now: i128, deadline_ns: i128, targets: usize, lim: target_unblock.Limits) bool {
    if (deadline_ns == 0 or targets == 0) return false;
    const spare = deadline_ns - lim.slice.reserve_ns - now;
    if (spare <= 0) return false;
    return @divTrunc(spare, @as(i128, @intCast(targets))) >= lim.slice.min_ns;
}

/// The oracle's open-net detail reduced to the shape the eligibility rule reads.
fn openShape(detail: fab_readiness.OpenNet) target_unblock.OpenShape {
    return .{
        .islands = detail.islands,
        .pads = detail.pads.len,
        .gaps = detail.gaps.len,
        .gap_mm = if (detail.gaps.len == 0) 0 else detail.gaps[0].mm,
    };
}

/// One pass's state: the board every transaction is judged against, the single
/// accept gate they share (its evaluation budget bounds the pass's oracle cost),
/// and the DRC error count no candidate may exceed.
const UnblockRun = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    lim: target_unblock.Limits,
    accept: *target_unblock.Gate,
    baseline: router.RouteResult,
    measured: UnblockMeasure,
    /// The hops this pass has already put a transaction behind and had refused.
    /// One list for the whole pass, read by every place that picks a net's gap,
    /// so a re-entry aiming at the next-smallest hop cannot be silently
    /// overridden by an internal that re-picks the smallest.
    retired: std.ArrayList(RetiredGap) = .empty,
    /// The net an ALTERNATE nomination is holding out of the transaction it is
    /// forming (see `unblockAlternate`), by flattened net index — and, when that
    /// net is a declared pair leg, its twin with it (`unblockHeldOut`). Null for
    /// every ordinary transaction, which is what keeps the nomination sweep the
    /// sweep it has always been.
    held: ?usize = null,
    /// How many alternate nominations this pass has actually SPENT.
    ///
    /// One per refused transaction that named a lost victim, from either tier —
    /// which is the whole bound on the retry, and the one thing that was silently
    /// wrong: the wide tier's tail read `accepted` off its outcome and dropped
    /// the rest, so a wide victim loss offered none and the counter read zero on
    /// exactly the boards the retry was written for.
    alternates: usize = 0,
    /// Which ROUND of the phase is running (see `UnblockLadder`). `.depth` by
    /// default, so every clock-free board — bench, corpus, every test route —
    /// runs exactly the single-round pass it always has.
    ladder: UnblockLadder = .depth,
    /// The nets a coupled re-home's envelope search named as the WALL it could
    /// not pass, by flattened net index (see `pair_pinch`). Filled by THIS
    /// transaction's own re-home and cleared when the next one starts, so a
    /// deepening round is only ever offered the wall its own pair hit.
    pinch: std.ArrayList(usize) = .empty,
    /// Whether the nomination sweep may offer them (see `UnblockPinch`).
    pinch_use: UnblockPinch = .ignore,
};

/// May a nomination sweep offer the copper a pair's envelope search named as its
/// wall?
///
/// `.ignore` everywhere but inside a deepening round, and that is the whole
/// rule. A pinch owner is copper the CORRIDOR SWEEP did not find — it walls the
/// pair's channel rather than the target's own hop — so offering it to an
/// ordinary transaction would widen every rip on the board on the strength of a
/// diagnosis about something else. Inside a deepening round the situation is the
/// one the fact was collected for: this transaction closed its target, lost the
/// pair, and the re-home has just reported which two bodies leave the pair no
/// room. Creating that channel is the move.
///
/// It adds NO authority. A pinch owner is judged by `vacate_policy` exactly as a
/// swept one is — ground, `(max-freq …)` RF and via-fenced copper are refused
/// unconditionally, a declared pair only under a tier that recouples, an
/// outranking net only under one that negotiates rank — and it competes for the
/// same capped nets and the same element budget.
const UnblockPinch = enum { ignore, nominate };

/// Which round of the unblock phase a transaction is running in.
///
/// The phase used to be ONE pass that gave each target its whole ladder in turn,
/// and on a timed board that is a queue, not a schedule: a full ladder costs
/// 45-60 s, the phase affords two, and the targets behind them are never asked
/// anything at all. Measured on barracuda (ReleaseSafe, v98): `SPI_DSA_CSN` and
/// `SPI_LMX_CSN` spent the whole 180 s tail between them and `LOCK_DET`,
/// `SPI_SCK` and `V_3V3A` produced no transaction verdict on any logged run —
/// the campaign had five open nets and facts about two of them.
///
/// So the phase asks every target ONE cheap question first and spends what is
/// left on the answers that earned it.
const UnblockLadder = enum {
    /// One narrow transaction per target under a bounded slice: no wide retry,
    /// no alternate nomination, no deepening round, and the coupled re-home
    /// priced as the ordinary hop it shares a window with. The product is a
    /// BOARD VERDICT per target (`UnblockPromise`), and any accept it earns
    /// commits exactly as it does in the depth round.
    breadth,
    /// The whole ladder, unchanged: the narrow transaction, its alternate
    /// nomination, the wide retry and up to two deepening rounds.
    depth,
};

/// One hop retired from a net's ladder: the pad PAIR it joins, which is the
/// oracle's own stable name for it.
///
/// Not the index (the oracle renumbers a net's gaps whenever anything lands) and
/// not the length (two pockets of a rail are commonly the same 1.50 mm).
const RetiredGap = struct {
    net_i: usize,
    from_ref: []const u8,
    from_pad: []const u8,
    to_ref: []const u8,
    to_pad: []const u8,

    fn names(gap: fab_readiness.OpenGap, net_i: usize) RetiredGap {
        return .{
            .net_i = net_i,
            .from_ref = gap.from.ref,
            .from_pad = gap.from.pad,
            .to_ref = gap.to.ref,
            .to_pad = gap.to.pad,
        };
    }

    /// Order-insensitive: which end of a hop the oracle names first is its
    /// business, and the hop is the same hop either way.
    fn same(a: RetiredGap, b: RetiredGap) bool {
        if (a.net_i != b.net_i) return false;
        return (padIs(a.from_ref, a.from_pad, b.from_ref, b.from_pad) and
            padIs(a.to_ref, a.to_pad, b.to_ref, b.to_pad)) or
            (padIs(a.from_ref, a.from_pad, b.to_ref, b.to_pad) and
                padIs(a.to_ref, a.to_pad, b.from_ref, b.from_pad));
    }

    fn padIs(ref_a: []const u8, pad_a: []const u8, ref_b: []const u8, pad_b: []const u8) bool {
        return std.mem.eql(u8, ref_a, ref_b) and std.mem.eql(u8, pad_a, pad_b);
    }
};

/// This net's cheapest hop that the pass has not already retired, or null when
/// every hop it has left has been tried.
///
/// THE one gap reader. `smallestGap` is the primitive underneath it, and the
/// difference is the whole of the accept-earned skip: a ladder that retires a
/// refused hop has to be able to reach the next one, and every place that
/// resolves a per-gap transaction's hop — the corridor sweep, the candidate
/// builder, the re-entry — has to agree about which hop that is.
fn unblockChosenGap(
    retired: []const RetiredGap,
    net_i: usize,
    detail: fab_readiness.OpenNet,
) ?usize {
    var best: ?usize = null;
    for (detail.gaps, 0..) |gap, i| {
        if (unblockGapRetired(retired, RetiredGap.names(gap, net_i))) continue;
        const incumbent = best orelse {
            best = i;
            continue;
        };
        if (gap.mm < detail.gaps[incumbent].mm) best = i;
    }
    return best;
}

fn unblockGapRetired(retired: []const RetiredGap, gap: RetiredGap) bool {
    for (retired) |seen| if (seen.same(gap)) return true;
    return false;
}

/// Retire the hop the attempt just failed on, so this net's ladder moves to its
/// next-smallest instead of re-forming the same transaction.
///
/// The board is re-read rather than remembered because a refused transaction
/// leaves it byte-for-byte as it arrived, so the hop this resolves is the one
/// the attempt actually ran against.
fn unblockRetireGap(run: *UnblockRun, net_i: usize) std.mem.Allocator.Error!void {
    const open = try unblockOpenNet(run, net_i) orelse return;
    const gap_i = unblockChosenGap(run.retired.items, net_i, open) orelse return;
    try run.retired.append(run.alloc, RetiredGap.names(open.gaps[gap_i], net_i));
    routeLog("target unblock {s}: retiring its {d:.2}mm hop, ladder continues", .{
        run.placement.nets[net_i].name,
        open.gaps[gap_i].mm,
    });
}

/// This net as the connectivity oracle sees the CURRENT board, or null when it
/// is not open on it any more.
fn unblockOpenNet(
    run: *UnblockRun,
    net_i: usize,
) std.mem.Allocator.Error!?fab_readiness.OpenNet {
    const zones = try route_close.userZones(run.alloc, run.placement, run.options.existing_zones);
    const wanted = [_][]const u8{run.placement.nets[net_i].name};
    const open = try fab_readiness.openNetsAmong(run.alloc, run.placement, .{
        .tracks = run.baseline.tracks,
        .vias = run.baseline.vias,
        .zones = zones,
    }, &wanted);
    return if (open.len == 0) null else open[0];
}

/// One whole-board geometry pass, read twice: the fabrication error count every
/// transaction ratchets against, and each declared pair's coupling and skew.
/// Both come off ONE `drc.check`, so a candidate is never weighed against two
/// different readings of itself.
const UnblockMeasure = struct {
    errors: usize = 0,
    pairs: []const target_unblock.PairHealth = &.{},
};

/// A candidate's verdict plus the measurement taken for it, so an accepted
/// board's ratchet is what was already computed rather than a second
/// whole-board check.
const UnblockVerdict = struct { kept: bool = false, measured: UnblockMeasure = .{} };

/// What one transaction did, and — when it refused — the two facts the tier
/// above needs in order to price a second, wider attempt.
const UnblockOutcome = struct {
    /// The candidate was committed to `run.baseline`.
    accepted: bool = false,
    /// The refusal was the BOARD's answer: the corridor was freed, the blockers
    /// were re-routed, and the target still could not cross it. A verdict about
    /// geometry, which is the one a bigger rip of the same classes cannot change
    /// (see `unblockWideAddsAuthority`).
    geometry: bool = false,
    /// The blockers this transaction held rip authority over, so a wider
    /// nomination can be asked whether it reaches copper this one did not.
    picked: []const vacate_policy.Nomination = &.{},
    /// The net this transaction RIPPED and could not put back, on a candidate
    /// whose target closed — the "closed, but <blocker> did not come back"
    /// verdict, named so an alternate nomination can hold exactly that net out
    /// of a second attempt (see `unblockAlternate`). Null for every other
    /// refusal.
    lost_victim: ?usize = null,
    /// Every net the nomination sweep looked at and DECLINED, with its reason —
    /// the half of `vacate_policy.Decision` this layer used to log and throw
    /// away. Kept because it is the one zero-cost signal saying whether a DEEPER
    /// tier still has copper to reach (`unblockDepthReachable`): the classes a
    /// narrow rip may not touch are named here by a sweep that has already run,
    /// so the breadth round can rank its targets without paying a second sweep
    /// per target to find out.
    refused: []const vacate_policy.Refused = &.{},
    /// Why the transaction produced no candidate board at all, or null when it
    /// produced one (accepted or rolled back). It separates "the clock stopped
    /// it" from "the board answered it", which is the difference between a
    /// target worth a longer slice and one worth none.
    dead: ?UnblockDead = null,
};

/// Why a transaction produced no candidate board at all.
///
/// One message — "no candidate within its slice" — used to stand for every one
/// of these, and it is wrong about most of them: measured at ReleaseSafe, the
/// transactions that reported it burned **1-3 s of a 20 s window**, so whatever
/// they hit, it was not the slice. Worse, the four causes want four different
/// fixes (more time, more rip authority, a different join, a bug), and a single
/// string cannot tell an operator which. Every early return in the two
/// candidate builders now names itself.
const UnblockDead = enum {
    /// The oracle reports no island-joining hop for this target any more — an
    /// earlier accepted transaction closed it, or moved its islands.
    no_gap,
    /// The gap has no routable request: its endpoints resolve to no pads this
    /// layer may join.
    no_request,
    /// The additive join found NO PATH across the freed corridor. The rip did
    /// what it was asked and the channel still carries no legal hop — a
    /// geometry answer, and the one a wider rip might change.
    join_no_path,
    /// A path existed but wanted to move copper nobody agreed to move. Refused:
    /// the whole point of the additive close is that the rip already named
    /// everything that may be displaced.
    join_would_rip,
    /// A path was found and it drew nothing.
    join_empty,
    /// The scoped RE-ROUTE hit the transaction's own wall clock and was
    /// abandoned mid-flight, so there is no board to judge. THIS is what the old
    /// message claimed of everything.
    ///
    /// Its twin — the gate overrunning the same clock AFTER the re-route
    /// finished — is deliberately not a cause here at all: that transaction has
    /// a board, and a board gets a verdict (see `unblockGateOverran`).
    route_expired,
    /// The scoped re-route or its gate returned an error.
    route_error,
    /// The scoped retry did not echo the frozen copper back exactly, so the
    /// candidate cannot be trusted to have left out-of-scope metal alone.
    copper_lost,

    /// Did the BOARD answer this, rather than the clock or the rip?
    ///
    /// Exactly one cause qualifies: the rip did what it was asked, the corridor
    /// was freed, and no legal path crosses it. Every other cause is about
    /// something a bigger transaction can change — time, authority, scope — and
    /// so is a reason to retry wider rather than a reason not to.
    fn onGeometry(self: UnblockDead) bool {
        return self == .join_no_path;
    }

    /// One line of prose per cause — what a reader needs in order to know which
    /// lever, if any, moves it.
    fn label(self: UnblockDead) []const u8 {
        return switch (self) {
            .no_gap => "the oracle reports no hop for it any more",
            .no_request => "its hop resolves to no joinable pads",
            .join_no_path => "no legal path across the freed corridor (geometry, not time)",
            .join_would_rip => "the only path wanted to move copper the rip did not name",
            .join_empty => "the join drew no copper",
            .route_expired => "the scoped re-route ran out of its slice before it drew a board",
            .route_error => "the scoped re-route or its gate failed",
            .copper_lost => "the scoped retry did not echo the frozen copper back",
        };
    }
};

/// A transaction's candidate board, or the precise reason there is none.
const UnblockCandidate = union(enum) {
    board: router.RouteResult,
    dead: UnblockDead,
};

/// One target's whole transaction: nominate its blockers, rip them with the
/// target's own fragments, route the target through what they vacate, reroute
/// them behind it, and commit only on a strict connectivity gain. The candidate
/// is built as a separate result over a copy of the board's copper, so a refusal
/// leaves `run.baseline` exactly as it arrived.
/// One transaction for one target: whether its candidate was ACCEPTED, and when
/// it was not, what kind of answer the refusal was and what copper it held.
fn unblockOne(
    run: *UnblockRun,
    target: target_unblock.Target,
    share: UnblockShare,
    lim: target_unblock.Limits,
) std.mem.Allocator.Error!UnblockOutcome {
    const name = run.placement.nets[target.net_i].name;
    // A pinch belongs to the transaction that found it: the pair whose re-home
    // reported it is THIS transaction's victim, and offering a previous target's
    // wall to this one would nominate copper nothing here is blocked by.
    run.pinch.clearRetainingCapacity();
    // The sweep's REFUSALS are kept alongside its picks, not logged and dropped:
    // they are what tells the breadth round whether a deeper tier still has
    // copper it could reach for this target (`unblockDepthReachable`).
    const decision = try unblockNominate(run, target, run.baseline);
    const picked = decision.picked;
    if (picked.len == 0) {
        routeLog("target unblock {s}: no rippable copper in its corridor", .{name});
        return .{ .refused = decision.refused };
    }
    unblockLogPicks(run, name, picked);
    // The transaction is FORMED, so its slice can finally be sized by the work
    // it turned out to take on: every element the rip removed has to come back
    // inside this one gate, and a restore twice the size is twice the re-route.
    // It is also sized from HERE, because nomination is not the re-route the
    // slice bounds — charging a corridor sweep to it spent 1.4 s of every 10 s
    // slice on this board. And it is CLAIMED rather than merely capped: a
    // 71-element restore priced at ~25 s that is handed a 14 s equal share
    // reports the clock where the board never got to answer.
    const deadline_ns = target_unblock.restoreDeadline(
        clock.nanoTimestamp(),
        share.board_deadline_ns,
        share.targets_left,
        lim,
        unblockRipElements(picked),
    ) orelse {
        routeLog("target unblock {s}: no slice left to route its restore in", .{name});
        return .{ .picked = picked, .refused = decision.refused };
    };
    // What the transaction was GRANTED and what it then SPENT, printed with
    // every refusal that produced no board. "Ran out of its slice" was the one
    // verdict an operator could not act on without these two numbers: a
    // transaction that spent 3 s of a 27 s slice and one that spent all 27 want
    // opposite fixes, and the message read identically for both.
    const started = clock.nanoTimestamp();
    const built = switch (target.kind) {
        .whole_net => try unblockCandidate(run, target, picked, deadline_ns),
        .one_gap => try unblockGapCandidate(run, target, picked, deadline_ns),
    };
    const candidate = switch (built) {
        .board => |board| board,
        .dead => |why| {
            routeLog("target unblock {s}: no candidate — {s} ({d}ms of a {d}ms slice, {d} elements ripped)", .{
                name,
                why.label(),
                @divTrunc(clock.nanoTimestamp() - started, clock.ns_per_ms),
                @divTrunc(deadline_ns - started, clock.ns_per_ms),
                unblockRipElements(picked),
            });
            return .{ .geometry = why.onGeometry(), .picked = picked, .refused = decision.refused, .dead = why };
        },
    };
    const verdict = switch (target.kind) {
        .whole_net => try unblockAccepted(run, target, picked, candidate),
        .one_gap => try unblockGapAccepted(run, target, picked, candidate),
    };
    if (!verdict.kept) {
        unblockLogRollback(run, name, target, picked, candidate);
        // The refusal the board answered on GEOMETRY has one thing the others do
        // not: a board on which the target's remaining blockers can be read
        // directly. Spend one bounded ladder on it before throwing it away —
        // in the DEPTH round only, because a deepening round is a whole scoped
        // re-route plus its gate and the breadth round's job is one verdict per
        // target, not one target's whole ladder (`UnblockLadder`).
        if (run.ladder == .depth and unblockRolledBackOnGeometry(name, candidate)) {
            if (try unblockDeepen(run, target, picked, candidate, share)) |deeper| return deeper;
        }
        return .{
            .geometry = unblockRolledBackOnGeometry(name, candidate),
            .picked = picked,
            .lost_victim = unblockLostVictim(run, name, picked, candidate),
            .refused = decision.refused,
        };
    }
    routeLog("target unblock {s}: accepted ({d} -> {d} open nets, {d} blockers rerouted)", .{
        name,
        run.baseline.failed.len,
        candidate.failed.len,
        picked.len,
    });
    run.baseline = candidate;
    run.measured = verdict.measured;
    return .{ .accepted = true, .picked = picked, .refused = decision.refused };
}

/// Was this ROLLED-BACK candidate's refusal the board's answer rather than the
/// transaction's? The target is still on the oracle's open list, so the corridor
/// was freed, the blockers came back, and the join still does not exist — the
/// same reading `unblockLogRollback` prints, kept in one place so the log and
/// the wide-retry decision can never disagree about what happened.
fn unblockRolledBackOnGeometry(name: []const u8, candidate: router.RouteResult) bool {
    return namedFailed(name, candidate.failed);
}

/// How many times one refused transaction may extend its own rip and ask again
/// on nothing but the standing bound — the count every round is free.
///
/// Two, because the ladder is a search and not a solver: each round pays a whole
/// scoped re-route plus its gate, and a target whose corridor is still sealed
/// after two independent diagnoses of two different boards is telling the reader
/// something about the placement rather than about the rip.
const unblock_max_deepen: usize = 2;

/// The hard stop on a TIMED depth ladder's deepening, whatever its budget says.
///
/// Past the standing two a round must price itself (`deepenAffordsRound`), and
/// that test is what actually bounds the ladder — this is the backstop that
/// keeps a mis-measured price, or a pocket that keeps peeling one blocker at a
/// time, from turning a search into a loop. Six because it is comfortably past
/// what any measured barracuda pocket has taken and still a number a reader can
/// hold: `V_3V3A`'s blocker set grew 1 → 3 across the two rounds it was allowed,
/// so its pocket is a handful of rounds deep, not dozens.
const unblock_max_deepen_funded: usize = 6;

/// The window ONE deepening round may re-route in.
///
/// Not the transaction's own slice: that slice was handed to the scoped
/// re-route, which spends it by construction, and the gate behind it commonly
/// overruns the same clock (`unblockGateOverran`) — so by the time there is a
/// board to diagnose, `now` is past it. So a round claims a window out of the
/// clock the PASS still holds, exactly as the victim re-home does
/// (`rehomeDeadline`), and never into the additive close's reserve. Sized like a
/// wide transaction's own re-route, because that is precisely what it is.
const deepen_window_ns: i128 = 30 * clock.ns_per_s;

/// What one deepening round may spend, and what it must leave behind.
const DeepenBudget = struct {
    board_deadline_ns: i128,
    reserve_ns: i128,
    /// Targets still live in the pass, this one included — the divisor the rest
    /// of the ladder prices itself by (`UnblockShare.targets_left`).
    targets_left: usize,
    floor_ns: i128,
};

/// When a deepening round may run until, or `now` when it may not run at all.
///
/// A round is a WHOLE scoped re-route plus its gate, which is the most expensive
/// thing this tier can do off-plan — so unlike the victim re-home it may not
/// simply claim the pass's remaining clock. It leaves a floor slice standing for
/// every target still behind it first (the same guarantee `unblockFirstTriesCovered`
/// makes for the ladder's re-entries: a rung may never spend a planned target's
/// only turn), takes at most `deepen_window_ns` of whatever is left, and answers
/// "not at all" the moment that remainder is under one floor slice. A clock-free
/// board answers `now` and never deepens.
fn deepenDeadline(now: i128, budget: DeepenBudget) i128 {
    if (budget.board_deadline_ns == 0) return now;
    const owed: i128 = @intCast(budget.targets_left -| 1);
    const spare = budget.board_deadline_ns - budget.reserve_ns - now - owed * budget.floor_ns;
    if (spare < budget.floor_ns) return now;
    return now + @min(deepen_window_ns, spare);
}

/// How many deepening rounds THIS ladder is allowed to attempt at all.
///
/// The standing two on a CLOCK-FREE board — bench, corpus, every test route —
/// which is what keeps their copper byte-identical. (`unblockDeepen` returns at
/// once on such a board, so this is the same answer twice; it is stated here so
/// the cap can be read without the caller.) The breadth round needs no case
/// either: `unblockOne` only offers a ladder in `.depth`, precisely so round 1
/// spends its share on one verdict per net rather than on one net's ladder.
///
/// A TIMED ladder gets the backstop instead, because for it the count was never
/// the real bound: measured on barracuda (ReleaseSafe, v100), the phase's one
/// funded ladder exhausted its two rounds at +187 s of a 240 s budget with its
/// blocker set still growing (1 → 3 across those two) and its funded plan empty
/// behind it, so the pass returned with **53 s of the board's own budget
/// unspent**. There was nothing left to hand that clock to. What decides a third
/// round is `deepenAffordsRound` — the ladder's own measured price against its
/// own share of the remainder — and this is only the ceiling that arithmetic
/// runs under.
fn unblockDeepenCap(run: *const UnblockRun) usize {
    if (run.options.stop.deadline_ns == 0) return unblock_max_deepen;
    return unblock_max_deepen_funded;
}

/// May this ladder afford ONE more deepening round beyond the standing two?
///
/// Priced at what its OWN rounds have cost — `priced` is the wall clock the
/// costliest round of this ladder actually took, sweep, scoped re-route and gate
/// together — rather than at `deepen_window_ns`, which is the window a round may
/// claim and not the bill it presents. The two differ by a lot: a round is
/// measured at 12-18 s against a 30 s window, so pricing the question at the
/// window would refuse a round the remainder comfortably covers.
///
/// What it must leave behind is a WHOLE funded ladder for every ladder still
/// behind this one (`unblock_ladder_price_ns`, the same constant round 2 funded
/// them by), not the floor slice `deepenDeadline` holds. The floor guarantees a
/// planned target's turn HAPPENS; that is the right guarantee for a rung, and
/// the wrong one here — an extended ladder that leaves the next funded ladder
/// three seconds has funded it on paper only, which is exactly the concentration
/// round 2 exists to prevent. Floored at the tier's own minimum slice, because a
/// ladder whose first rounds were free must still show it can seat a transaction.
///
/// A clock-free board answers NO and never reaches a third round, which is what
/// keeps every bench and corpus route byte-identical.
fn deepenAffordsRound(run: *const UnblockRun, share: UnblockShare, now: i128, priced: i128) bool {
    if (share.board_deadline_ns == 0) return false;
    const owed: i128 = @intCast(share.targets_left -| 1);
    const spare = share.board_deadline_ns - run.lim.slice.reserve_ns - now -
        owed * unblock_ladder_price_ns;
    return spare >= @max(priced, run.lim.slice.min_ns);
}

/// Extend a refused transaction's rip with the blockers its OWN candidate board
/// still shows in the way, and try again — for as many rounds as the ladder can
/// show it affords (`unblockDeepenCap`, `deepenAffordsRound`).
///
/// Reached only on "rolled back — re-routed and still open": the rip did what it
/// was asked, every blocker came back, and the target still cannot cross. That
/// verdict used to end the target's turn, which threw away the one thing the
/// transaction had just paid a whole slice to produce — a BOARD on which the
/// target's remaining blockers are directly diagnosable, by the same nomination
/// machinery that seeded the transaction in the first place. Measured on
/// barracuda (ReleaseSafe, v96), `SPI_LMX_CSN` and `LOCK_DET` both ended there,
/// each after ripping 60-80 elements and re-routing them, each reporting "3
/// blockers" it had already put back.
///
/// The deeper sweep is `unblockNominate` under the SAME `run.lim` with ONE
/// addition: `negotiate.outranking`. Every electrical-integrity refusal is
/// untouched — `vacate_policy` still refuses ground with nothing behind it,
/// `(max-freq …)` RF, via-fenced copper and a declared pair outside the wide
/// tier — and a declared pair is still reachable only from the wide tier. What a
/// round adds is which BOARD the corridor is swept against, so a net the first
/// sweep never saw can be named, and that a blocker held out on RANK alone can
/// now be lifted corridor-only (`target_unblock.rankFacts`).
///
/// The rank guard is the one refusal a deepening round is the right place to
/// negotiate. It is a heuristic about routing ORDER rather than about the
/// copper, and a round only reaches it after this target's rip has already
/// freed, re-routed and restored every negotiable occupant of its corridor and
/// the board has said the channel is still sealed — which is exactly the
/// evidence that the remaining occupant is the wall. Measured on barracuda
/// (ReleaseSafe, v97): `LOCK_DET` ended there with `V_24V_CLEAN` excluded as
/// `outranks_seed` and nothing else left to ask.
///
/// The switch is turned on HERE and off again on the way out, so it is scoped to
/// the round: the first transaction, its wide retry and its alternate nomination
/// all judge rank exactly as they always have.
///
/// Null means "deepening added nothing" and the caller keeps the refusal it
/// already had — including on a CLOCK-FREE board, which never enters at all, so
/// every bench and corpus route stays byte-identical.
///
/// It runs under whichever tier formed the transaction, the NARROW one included,
/// and that is deliberate: both measured cases on barracuda (`SPI_LMX_CSN`,
/// `LOCK_DET`) are narrow rollbacks whose wide retry that board never affords, so
/// a rule that waited for the wide tier would never reach either of them. The
/// cost is that a deepened narrow refusal delays that tier's own retry, which is
/// why a round leaves the floor standing, why the first two are the only free
/// ones, and why every round past them must price itself against a whole funded
/// ladder held for each ladder still waiting.
fn unblockDeepen(
    run: *UnblockRun,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
    produced: router.RouteResult,
    share: UnblockShare,
) std.mem.Allocator.Error!?UnblockOutcome {
    if (run.options.stop.deadline_ns == 0) return null;
    const name = run.placement.nets[target.net_i].name;
    // Scoped to the ladder below and restored on every exit from it, including
    // the error paths — the rank guard is negotiable in a deepening round and
    // nowhere else.
    const formed = run.lim.negotiate;
    run.lim.negotiate = deepenAuthority(formed);
    // The pair's own wall joins the sweep for exactly these rounds. Scoped like
    // the rank guard beside it, and for the same reason: the evidence that makes
    // it fair — this transaction has already freed, re-routed and restored every
    // negotiable occupant of the corridor, and the pair it lost reported which
    // two bodies leave it no room — exists nowhere but here.
    const use = run.pinch_use;
    run.pinch_use = .nominate;
    defer {
        run.lim.negotiate = formed;
        run.pinch_use = use;
    }
    var rip = picked;
    var board = produced;
    const cap = unblockDeepenCap(run);
    // What the costliest round of THIS ladder took, sweep and gate included — the
    // price the next one is quoted at. Zero until a round has been paid for, so
    // the standing two are never priced against a measurement that does not
    // exist yet.
    var priced: i128 = 0;
    var rounds: usize = 0;
    while (rounds < cap) : (rounds += 1) {
        const now = clock.nanoTimestamp();
        if (rounds >= unblock_max_deepen and !deepenAffordsRound(run, share, now, priced)) {
            routeLog("target unblock {s}: deepening stops after {d} rounds — its own {d}s round no longer fits the remainder ({d} ladder(s) behind it)", .{
                name,
                rounds,
                @divTrunc(priced, clock.ns_per_s),
                share.targets_left -| 1,
            });
            return .{ .geometry = true, .picked = rip };
        }
        const window = deepenDeadline(now, .{
            .board_deadline_ns = share.board_deadline_ns,
            .reserve_ns = run.lim.slice.reserve_ns,
            .targets_left = share.targets_left,
            .floor_ns = run.lim.slice.min_ns,
        });
        if (window <= now) {
            routeLog("target unblock {s}: deepening yields the remainder to the {d} target(s) behind it", .{
                name,
                share.targets_left -| 1,
            });
            return null;
        }
        const found = try unblockNominate(run, target, board);
        const wider = try unblockDeeperRip(run, rip, found.picked, name);
        if (wider.len == rip.len) {
            unblockLogDeepenStuck(run, name, found.refused, rip);
            return null;
        }
        const round = try unblockDeepenRound(run, target, wider, window);
        priced = @max(priced, clock.nanoTimestamp() - now);
        if (round.accepted or round.lost_victim != null) return round.outcome();
        rip = wider;
        board = round.board orelse return round.outcome();
    }
    routeLog("target unblock {s}: deepening exhausted after {d} rounds — target still open ({d} blockers ripped)", .{
        name,
        cap,
        rip.len,
    });
    return .{ .geometry = true, .picked = rip };
}

/// The authority ONE deepening round runs under: whatever tier formed the
/// transaction, plus the rank negotiation THIS tier opens nowhere else.
///
/// A named seam rather than a field poked in place, because "what a round may
/// do that its own tier may not" is the whole of this rule and it must be
/// readable — and provable — in one line. Everything the forming tier already
/// held passes through untouched: a narrow round negotiates rank and nothing
/// else, a wide one keeps its pairs and its plane lift as well.
fn deepenAuthority(formed: target_unblock.Negotiable) target_unblock.Negotiable {
    var open = formed;
    open.outranking = true;
    return open;
}

/// One deepening round's whole answer: the outcome to hand up, plus the board it
/// produced when that board is worth diagnosing again.
const UnblockDeepRound = struct {
    accepted: bool = false,
    geometry: bool = false,
    picked: []const vacate_policy.Nomination = &.{},
    lost_victim: ?usize = null,
    /// The candidate this round built, kept ONLY when it was refused because the
    /// target is still open — the one case the next round can learn from.
    board: ?router.RouteResult = null,

    fn outcome(self: UnblockDeepRound) UnblockOutcome {
        return .{ .accepted = self.accepted, .geometry = self.geometry, .picked = self.picked, .lost_victim = self.lost_victim };
    }
};

/// Build and judge ONE deepened transaction, exactly as `unblockOne` builds and
/// judges the first — same candidate builder, same gate, same commit.
fn unblockDeepenRound(
    run: *UnblockRun,
    target: target_unblock.Target,
    wider: []const vacate_policy.Nomination,
    window: i128,
) std.mem.Allocator.Error!UnblockDeepRound {
    const name = run.placement.nets[target.net_i].name;
    const built = switch (target.kind) {
        .whole_net => try unblockCandidate(run, target, wider, window),
        .one_gap => try unblockGapCandidate(run, target, wider, window),
    };
    const candidate = switch (built) {
        .board => |b| b,
        .dead => |why| {
            routeLog("target unblock {s}: deepening produced no candidate — {s}", .{ name, why.label() });
            return .{ .geometry = why.onGeometry(), .picked = wider };
        },
    };
    const verdict = switch (target.kind) {
        .whole_net => try unblockAccepted(run, target, wider, candidate),
        .one_gap => try unblockGapAccepted(run, target, wider, candidate),
    };
    if (verdict.kept) {
        routeLog("target unblock {s}: deepening accepted ({d} -> {d} open nets, {d} blockers rerouted)", .{
            name,
            run.baseline.failed.len,
            candidate.failed.len,
            wider.len,
        });
        run.baseline = candidate;
        run.measured = verdict.measured;
        return .{ .accepted = true, .picked = wider };
    }
    unblockLogRollback(run, name, target, wider, candidate);
    // A deepened rip loses a victim exactly as a first-round rip can, and the
    // answer to that is the alternate nomination the caller already owns — so
    // the loss is handed up named rather than deepened again.
    const still_open = unblockRolledBackOnGeometry(name, candidate);
    return .{
        .geometry = still_open,
        .picked = wider,
        .lost_victim = unblockLostVictim(run, name, wider, candidate),
        .board = if (still_open) candidate else null,
    };
}

/// The rip set extended with every deeper nomination it does not already hold,
/// naming each addition. Returns `rip` itself when the sweep found nothing new.
fn unblockDeeperRip(
    run: *UnblockRun,
    rip: []const vacate_policy.Nomination,
    found: []const vacate_policy.Nomination,
    target: []const u8,
) std.mem.Allocator.Error![]const vacate_policy.Nomination {
    var out: std.ArrayList(vacate_policy.Nomination) = .empty;
    try out.appendSlice(run.alloc, rip);
    for (found) |pick| {
        if (pick.net_i >= run.placement.nets.len) continue;
        if (unblockAlreadyPicked(out.items, pick.net_i)) continue;
        // A rank-negotiated pick is reported as the negotiation it is, not as
        // one more blocker: it is the only nomination here that overrides a
        // guard rather than paying a cheapness argument, so a reader auditing a
        // deepened transaction must be able to see it by name.
        if (pick.kind == .rank_lifted) {
            routeLog("target unblock {s}: deepening: negotiating outranking {s} ({s}, {d} elements, corridor only)", .{
                target,
                run.placement.nets[pick.net_i].name,
                @tagName(pick.kind),
                pick.elements,
            });
        } else {
            routeLog("target unblock {s}: deepening: freed corridor still blocked by {s} ({s}, {d} elements) — ripping it too", .{
                target,
                run.placement.nets[pick.net_i].name,
                @tagName(pick.kind),
                pick.elements,
            });
        }
        try out.append(run.alloc, pick);
    }
    if (out.items.len == rip.len) return rip;
    return out.toOwnedSlice(run.alloc);
}

/// Say WHY a deepening round found nothing to add: a blocker the policy will not
/// negotiate, or no copper in the corridor at all.
///
/// The two want opposite readings and "deepening stopped" said neither. A
/// non-negotiable remainder is a finding about the board — an RF fence, a
/// `(max-freq …)` net, ground with nothing behind it — and no rip authority this
/// tier can be given will move it. An empty corridor is the geometry answer:
/// the channel is clear and the join still does not exist.
///
/// The RANK refusal is the third reading and the refusal twin of the
/// negotiation `unblockDeeperRip` prints. Inside a deepening round the guard is
/// open, so `outranks_seed` can only come back for a net `rankFacts` declined —
/// which is the net having no copper in the corridor at all. That is not "the
/// policy would not touch it"; it is "there was nothing of it here to take", and
/// a reader chasing a sealed corridor must not be told the first when the board
/// said the second.
fn unblockLogDeepenStuck(
    run: *UnblockRun,
    target: []const u8,
    refused: []const vacate_policy.Refused,
    rip: []const vacate_policy.Nomination,
) void {
    for (refused) |r| {
        if (r.net_i >= run.placement.nets.len) continue;
        if (unblockAlreadyPicked(rip, r.net_i)) continue;
        if (r.why == .outranks_seed and run.lim.negotiate.outranking) {
            routeLog("target unblock {s}: deepening: cannot negotiate outranking {s} — no copper of it in the corridor to lift", .{
                target,
                run.placement.nets[r.net_i].name,
            });
            return;
        }
        routeLog("target unblock {s}: deepening exhausted — remaining blocker {s} is not negotiable ({s})", .{
            target,
            run.placement.nets[r.net_i].name,
            @tagName(r.why),
        });
        return;
    }
    routeLog("target unblock {s}: deepening found no new copper — geometry", .{target});
}

/// Total copper one transaction's picked blockers carry — what its all-or-nothing
/// restore has to re-lay, and so what its slice is priced against.
fn unblockRipElements(picked: []const vacate_policy.Nomination) usize {
    var total: usize = 0;
    for (picked) |pick| total += pick.elements;
    return total;
}

/// Whose copper stands in this target's island-joining hop, ranked by restore
/// cheapness and capped by `target_unblock.blockerLimits`.
///
/// Geometry alone nominates: the corridor sweep (tracks AND via barrels, because
/// a row of barrels walls a channel exactly as a track does) is the nomination
/// half that always answers, and this layer holds a finished result rather than
/// a live routing context to run the soft probe from. `vacate_policy.select`
/// then judges — ground, diff-pair, `(max-freq …)` RF and via-fenced copper is
/// never taken, nor is a net the oracle finds in pieces itself, nor one
/// outranking the target unless a pour underwrites its restore.
fn unblockBlockers(
    run: *UnblockRun,
    target: target_unblock.Target,
) std.mem.Allocator.Error![]const vacate_policy.Nomination {
    return (try unblockNominate(run, target, run.baseline)).picked;
}

/// The same sweep against ANY board, with the refusals kept.
///
/// The board is a parameter because a refused transaction has produced one, and
/// that board is where its target's REMAINING blockers are (`unblockDeepen`):
/// the copper the rip removed is back, possibly somewhere else, and whatever now
/// stands in the way is what the next rip has to name. Every existing caller
/// hands in `run.baseline` and is unchanged.
///
/// Only the hop geometry and the corridor sweep read that board. What a
/// nomination COSTS — its element count, its class, whether its net is whole —
/// stays measured on `run.baseline`, because that is the board a transaction
/// actually rips from, whichever board diagnosed it.
fn unblockNominate(
    run: *UnblockRun,
    target: target_unblock.Target,
    board: router.RouteResult,
) std.mem.Allocator.Error!vacate_policy.Decision {
    const alloc = run.alloc;
    const hops = try unblockHops(run, target, board);
    if (hops.len == 0) return .{ .picked = &.{}, .refused = &.{} };
    // Band AND budget are sized against the corridor this transaction actually
    // has to open, not against the endpoint pocket the flat bounds assumed.
    const corridor_mm = target_unblock.corridorLength(hops);
    var near = blocker_nomination.Table{};
    try blocker_nomination.sweepHops(&near, alloc, .{
        .net_i = target.net_i,
        .hops = hops,
        .tracks = board.tracks,
        .vias = board.vias,
        .radius_mm = target_unblock.corridorRadius(run.lim, corridor_mm),
        .via_policy = .tracks_and_vias,
    });
    const facts = try unblockBlockerFacts(run, target, try unblockPinchCandidates(run, try near.ranked(alloc)));
    const decision = try vacate_policy.select(alloc, facts, .{
        .net_i = target.net_i,
        .priority = fieldClusterPriority(run.placement, target.net_i),
    }, target_unblock.corridorLimits(run.lim, corridor_mm));
    unblockLogRefusals(run, decision.refused);
    return decision;
}

/// The island-joining hops this transaction is clearing a corridor for, read
/// against the CURRENT board — an accepted transaction ahead of this one may
/// have moved the copper the corridor is swept against, or closed this net
/// outright.
///
/// A whole-net target takes every hop it has to close; a per-gap transaction
/// takes ONE, because the copper standing in a different pocket of the same
/// rail is not in this join's way and ripping it would spend the budget on
/// someone else's problem.
///
/// One reader for the nomination AND for the corridor lift, so the copper a net
/// is nominated for and the copper a lift removes are measured against the same
/// lines. `board` is which board those lines are read off: `run.baseline` for
/// every ordinary caller, and the board a refused transaction PRODUCED when
/// `unblockDeepen` is asking what is still in the way.
fn unblockHops(
    run: *UnblockRun,
    target: target_unblock.Target,
    board: router.RouteResult,
) std.mem.Allocator.Error![]const blocker_nomination.Hop {
    const alloc = run.alloc;
    const zones = try route_close.userZones(alloc, run.placement, run.options.existing_zones);
    const wanted = [_][]const u8{run.placement.nets[target.net_i].name};
    const open = try fab_readiness.openNetsAmong(alloc, run.placement, .{
        .tracks = board.tracks,
        .vias = board.vias,
        .zones = zones,
    }, &wanted);
    if (open.len == 0) return &.{};
    var hops: std.ArrayList(blocker_nomination.Hop) = .empty;
    const chosen = if (target.kind == .one_gap) unblockChosenGap(run.retired.items, target.net_i, open[0]) else null;
    for (open[0].gaps, 0..) |gap, gap_i| {
        if (chosen) |only| if (gap_i != only) continue;
        try hops.append(alloc, .{ .ax = gap.from.x, .ay = gap.from.y, .bx = gap.to.x, .by = gap.to.y });
    }
    return hops.toOwnedSlice(alloc);
}

/// Name the copper this transaction is about to rip, at what granularity, and
/// what its restore is charged.
///
/// The refusal trace below says what the tier would not touch; without its twin
/// a formed-but-refused transaction says only "no candidate", which cannot
/// distinguish a corridor that was never freed from one that was freed and
/// still had no path.
fn unblockLogPicks(run: *UnblockRun, target: []const u8, picked: []const vacate_policy.Nomination) void {
    for (picked) |pick| {
        if (pick.net_i >= run.placement.nets.len) continue;
        routeLog("target unblock {s}: ripping {s} ({s}, {d} elements{s})", .{
            target,
            run.placement.nets[pick.net_i].name,
            @tagName(pick.kind),
            pick.elements,
            if (unblockLifted(run, pick))
                ", corridor only"
            else if (unblockPickTwin(run, pick) != null)
                ", with its twin"
            else
                "",
        });
    }
}

/// Say what a BUILT candidate failed on — the other half of the taxonomy.
///
/// A transaction that produced a board and was then refused is a different
/// animal from one that produced none (`UnblockDead`), and within it the two
/// interesting cases are opposites: the target is still open (the corridor was
/// freed and the re-route still could not cross it) or the target CLOSED and
/// something else the transaction named did not come back. The first is a
/// geometry problem, the second is a budget or ordering one, and "rolled back"
/// alone said neither.
fn unblockLogRollback(
    run: *UnblockRun,
    name: []const u8,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
    candidate: router.RouteResult,
) void {
    if (unblockRolledBackOnGeometry(name, candidate)) {
        routeLog("target unblock {s}: rolled back — re-routed and still open ({d} blockers)", .{
            name,
            picked.len,
        });
        return;
    }
    // The target closed. Name whichever ripped net did not, so the reader is
    // not left comparing two open-net lists by hand.
    if (unblockLostVictim(run, name, picked, candidate)) |victim| {
        routeLog("target unblock {s}: rolled back — closed, but {s} did not come back", .{
            name,
            run.placement.nets[victim].name,
        });
        return;
    }
    routeLog("target unblock {s}: rolled back — closed, but the board gate refused it ({d} blockers, kind {s})", .{
        name,
        picked.len,
        @tagName(target.kind),
    });
}

/// The first net this transaction RIPPED that did not come back, on a candidate
/// whose TARGET closed — or null when the target is what stayed open (a geometry
/// answer, about the corridor rather than about the price of freeing it) or when
/// every ripped net returned.
///
/// One reader for the verdict line and for the alternate-nomination decision, so
/// the log and the retry can never disagree about which net was lost.
fn unblockLostVictim(
    run: *UnblockRun,
    name: []const u8,
    picked: []const vacate_policy.Nomination,
    candidate: router.RouteResult,
) ?usize {
    if (unblockRolledBackOnGeometry(name, candidate)) return null;
    for (picked) |pick| {
        if (pick.net_i >= run.placement.nets.len) continue;
        if (namedFailed(run.placement.nets[pick.net_i].name, candidate.failed)) return pick.net_i;
    }
    return null;
}

/// Name the copper the tier looked at and declined, and why.
///
/// A rolled-back transaction is otherwise indistinguishable from one that never
/// formed, and the two want opposite fixes. `vacate_policy` computes these
/// reasons precisely so a caller can report them; this is the caller doing it.
fn unblockLogRefusals(run: *UnblockRun, refused: []const vacate_policy.Refused) void {
    for (refused) |r| {
        if (r.net_i >= run.placement.nets.len) continue;
        routeLog("target unblock: declined {s} ({s})", .{
            run.placement.nets[r.net_i].name,
            @tagName(r.why),
        });
    }
}

/// Each nominated net as `vacate_policy.judge` reads it — through
/// `fieldClusterNetFacts`, the cluster tier's own reader, so the two residual
/// tiers can never disagree about what one net is, and then through
/// `target_unblock.pairFacts`, which applies this tier's two departures from
/// that reading: plane- or pour-carried ground is displaceable inside a
/// transaction that re-measures ground before it commits, and a declared
/// differential pair is displaceable by a tier that will re-lay it coupled.
///
/// A candidate this layer cannot legally rewrite is not offered at all rather
/// than offered and refused, because `judge` has a fact for none of the three
/// reasons: out of the caller's scope, carrying caller-retained copper, or
/// holding no generated copper whose removal could free the corridor.
fn unblockBlockerFacts(
    run: *UnblockRun,
    target: target_unblock.Target,
    ranked: []const blocker_nomination.Candidate,
) std.mem.Allocator.Error![]const vacate_policy.NetFacts {
    var facts: std.ArrayList(vacate_policy.NetFacts) = .empty;
    // A pair lying across a corridor puts BOTH legs in the sweep's yield, and
    // each would nominate the same two nets and charge the same two legs'
    // copper twice. The nearer leg speaks for the pair (`ranked` is
    // nearest-first) and the other is dropped, so one pair is one nomination.
    var paired = std.AutoHashMapUnmanaged(usize, void).empty;
    // This target's corridor on the baseline board, read at most once (see the
    // measurement below). Null until some candidate is priced against it.
    var hops: ?[]const blocker_nomination.Hop = null;
    for (ranked) |candidate| {
        if (candidate.net_i >= run.placement.nets.len) continue;
        if (!topologyMutable(run.options.selected_nets, @intCast(candidate.net_i))) continue;
        // The net an alternate nomination is holding out of this transaction: it
        // was already proved unaffordable to put back on this board, so
        // re-offering it would re-form the transaction that failed.
        if (unblockHeldOut(run, candidate.net_i)) continue;
        const elements = generatedNetCopperCount(run.baseline, run.options, candidate.net_i);
        if (elements == 0 or retainedNetCopper(run.options, candidate.net_i)) continue;
        // Resolved only by a tier that may act on it, so the narrow
        // transaction's fact list is what it always was, net for net.
        const binding = if (run.lim.negotiate.pairs) unblockPairBinding(run, candidate.net_i) else null;
        if (binding != null) {
            const pair_i = diffPairIndex(run.placement, candidate.net_i) orelse continue;
            if ((try paired.getOrPut(run.alloc, pair_i)).found_existing) continue;
        }
        // ONE corridor measurement, shared by the two departures that are priced
        // against it — a poured net's lift and an outranking net's. Measured only
        // when some switch is on, so an ordinary narrow sweep does exactly the
        // work it always did.
        //
        // The CORRIDOR ITSELF is measured once per sweep rather than once per
        // candidate. It is a function of the target and the baseline board, both
        // of which are fixed for the whole of this call, but reading it costs an
        // oracle pass over the net (`unblockHops` → `openNetsAmong`) — so a sweep
        // that ranked a dozen candidates paid a dozen identical oracle passes for
        // one answer. Same corridor, same counts, once.
        const corridor: ?usize = if (run.lim.negotiate.plane_corridor or run.lim.negotiate.outranking) blk: {
            if (hops == null) hops = try unblockHops(run, target, run.baseline);
            break :blk try unblockCorridorElements(run, hops.?, candidate.net_i);
        } else null;
        try facts.append(run.alloc, target_unblock.rankFacts(target_unblock.liftFacts(
            target_unblock.pairFacts(
                fieldClusterNetFacts(run.placement, run.options, run.baseline, candidate, elements),
                run.lim,
                binding,
            ),
            run.lim,
            corridor,
        ), run.lim, corridor));
    }
    return facts.toOwnedSlice(run.alloc);
}

/// How much of `net_i`'s generated copper lies inside `hops`' corridor — what a
/// corridor lift would actually take off the board.
///
/// Counted through the RIP ITSELF — one `CopperRip` over a mask holding just
/// this net — so the copper the policy is charged for and the copper the strip
/// removes are decided by one predicate rather than by two that agree today.
///
/// The corridor is handed IN rather than read here, because it belongs to the
/// target and not to the candidate: every net in one sweep is measured against
/// the same lines, and reading them per candidate bought nothing but repeated
/// oracle passes.
fn unblockCorridorElements(
    run: *UnblockRun,
    hops: []const blocker_nomination.Hop,
    net_i: usize,
) std.mem.Allocator.Error!usize {
    if (hops.len == 0) return 0;
    const only = try run.alloc.alloc(bool, run.placement.nets.len);
    @memset(only, false);
    only[net_i] = true;
    const rip = CopperRip{
        .dropped = &.{},
        .lifted = only,
        .hops = hops,
        .radius_mm = target_unblock.corridorRadius(run.lim, target_unblock.corridorLength(hops)),
    };
    var count: usize = 0;
    for (run.baseline.tracks) |t| {
        if (rip.takesTrack(t) and !retainedTrack(t, run.options.existing_tracks)) count += 1;
    }
    for (run.baseline.vias) |v| {
        if (rip.takesVia(v) and !retainedVia(v, run.options.existing_vias)) count += 1;
    }
    return count;
}

/// The declared pair this nominated leg belongs to, when the transaction may
/// legally rip and re-lay BOTH of its legs — otherwise null, and the leg stays
/// the protected copper `vacate_policy` has always refused.
///
/// Every condition the twin has to meet is one the nominated leg already met
/// where `unblockBlockerFacts` reads it: in the caller's routing scope, no
/// caller-retained copper (this layer may not rewrite authored metal), and whole
/// on the incoming board — a pair with a leg the oracle already finds open is
/// the pass's own unfinished work, not a corridor to negotiate. The two legs'
/// copper is summed because the transaction's budget governs what its restore
/// must re-lay, and that is both legs.
///
/// Re-derived per call rather than carried on the nomination, so the twin a
/// candidate is BUILT with and the twin it is JUDGED with are the same lookup
/// against the same board.
fn unblockPairBinding(run: *UnblockRun, net_i: usize) ?target_unblock.PairBinding {
    const twin = diffPairTwin(run.placement, net_i) orelse return null;
    if (twin >= run.placement.nets.len) return null;
    if (!topologyMutable(run.options.selected_nets, @intCast(twin))) return null;
    if (retainedNetCopper(run.options, twin)) return null;
    if (namedFailed(run.placement.nets[twin].name, run.baseline.failed)) return null;
    const both = generatedNetCopperCount(run.baseline, run.options, net_i) +
        generatedNetCopperCount(run.baseline, run.options, twin);
    if (both == 0) return null;
    return .{ .twin = twin, .elements = both };
}

/// The other leg of `net_i`'s declared `(diff-pair …)`, or null.
fn diffPairTwin(placement: optimizer.Placement, net_i: usize) ?usize {
    for (placement.diff_pairs) |pair| {
        if (pair.p == net_i) return pair.n;
        if (pair.n == net_i) return pair.p;
    }
    return null;
}

/// The twin a pair nomination takes off the board with it, or null for every
/// other pick. A leg ripped ALONE cannot be re-laid coupled — the envelope
/// search reads the leg still on the board as foreign copper and walls its own
/// pair out — so this is not an optimisation but the thing that makes the
/// nomination honest.
fn unblockPickTwin(run: *UnblockRun, pick: vacate_policy.Nomination) ?usize {
    if (pick.kind != .pair_recouple) return null;
    const bind = unblockPairBinding(run, pick.net_i) orelse return null;
    return bind.twin;
}

/// The rip masks one transaction builds from its picks.
///
/// `selected` is the reroute scope — every net the scoped route may lay copper
/// for. `dropped` and `lifted` are the two rip granularities `CopperRip`
/// documents, and a net is in exactly one of them.
const UnblockMasks = struct { selected: []bool, dropped: []bool, lifted: []bool };

/// Three fresh masks over `placement.nets`, all clear.
fn unblockMasks(run: *UnblockRun) std.mem.Allocator.Error!UnblockMasks {
    const n = run.placement.nets.len;
    const masks = UnblockMasks{
        .selected = try run.alloc.alloc(bool, n),
        .dropped = try run.alloc.alloc(bool, n),
        .lifted = try run.alloc.alloc(bool, n),
    };
    @memset(masks.selected, false);
    @memset(masks.dropped, false);
    @memset(masks.lifted, false);
    return masks;
}

/// Mark one pick's nets as ripped and re-routed by this transaction: the pick
/// itself, plus the twin of a pair nomination — and at the granularity the
/// nomination was made at, so a plane-carried net that was CHARGED for its
/// corridor is RIPPED at its corridor too.
fn unblockMarkPick(
    run: *UnblockRun,
    pick: vacate_policy.Nomination,
    masks: UnblockMasks,
) void {
    const lift = unblockLifted(run, pick);
    masks.selected[pick.net_i] = true;
    if (lift) masks.lifted[pick.net_i] = true else masks.dropped[pick.net_i] = true;
    if (unblockPickTwin(run, pick)) |twin| {
        masks.selected[twin] = true;
        masks.dropped[twin] = true;
    }
}

/// This transaction's rip, at both granularities: the whole-net mask, the
/// corridor-lift mask, and the corridor those lifts are measured against.
fn unblockRip(
    run: *UnblockRun,
    target: target_unblock.Target,
    masks: UnblockMasks,
) std.mem.Allocator.Error!CopperRip {
    const hops = try unblockHops(run, target, run.baseline);
    return .{
        .dropped = masks.dropped,
        .lifted = masks.lifted,
        .hops = hops,
        .radius_mm = target_unblock.corridorRadius(run.lim, target_unblock.corridorLength(hops)),
    };
}

/// Is this pick lifted corridor-only rather than ripped whole?
///
/// Re-derived from the nomination's own kind, so the copper the policy charged
/// the transaction for and the copper the rip removes cannot diverge: only the
/// two nominations offered the corridor discount take it, and each only under
/// the switch that offered it.
fn unblockLifted(run: *UnblockRun, pick: vacate_policy.Nomination) bool {
    return switch (pick.kind) {
        .pour_carried => run.lim.negotiate.plane_corridor,
        .rank_lifted => run.lim.negotiate.outranking,
        .short_stub, .pair_recouple => false,
    };
}

/// The window ONE transaction's GATE may reconcile in, past the slice its own
/// scoped re-route has already spent.
///
/// Measured on barracuda (Debug, this increment): the wide `SPI_DSA_CSN`
/// transaction's gate reconciled for **14.8 s** and `SPI_LMX_CSN`'s for
/// **17.3 s**, both landing real island hops and both ending with the honest
/// verdict "a net this transaction named is still open". Twenty seconds covers
/// that worst case with a little headroom and stays under the reconcile's own
/// 30 s pass slice (`gate_reconcile_slice_ns`), which remains the bound on what
/// the gate actually spends. This only stops the gate being PRE-EXPIRED.
const gate_window_ns: i128 = 20 * clock.ns_per_s;

/// The same scoped options with the GATE's clock taken off the pass rather than
/// off the transaction slice the scoped re-route has already spent.
///
/// The slice is handed to `router.routeWithOptions`, which spends it to the last
/// nanosecond by construction, so the gate behind it starts with a stop that is
/// already past — and `route_close.reconcile` then cuts every hop maze to an
/// expired deadline (`slicedRasterStop`) and marks the board cancelled on the way
/// out. That is the same mistake `rehomeDeadline` was written for, one tier up,
/// so it is the same arithmetic: a small window out of the clock the PASS still
/// holds, never shorter than the deadline the transaction already had, and
/// nothing at all on a clock-free board.
fn unblockGateOptions(run: *UnblockRun, options: route_policy.Options) route_policy.Options {
    var out = options;
    out.stop.deadline_ns = windowDeadline(
        clock.nanoTimestamp(),
        run.options.stop.deadline_ns,
        run.lim.slice.reserve_ns,
        options.stop.deadline_ns,
        gate_window_ns,
    );
    return out;
}

/// A gate that overran the transaction's own clock still ANSWERED, so its board
/// is judged rather than thrown away.
///
/// `route_close.reconcile` sets `cancelled` whenever the stop it was handed has
/// elapsed by the time it returns — a statement about ONE transaction's slice,
/// not about the route. Reading it as "no candidate" cost this tier every
/// mechanism behind the verdict: measured on barracuda (Debug, this increment)
/// the wide `SPI_DSA_CSN` transaction reconciled for 14.8 s, reached the real
/// answer ("a net this transaction named is still open"), and was reported as
/// "the scoped re-route ran out of its slice" — so the rollback line, the lost
/// victim, the shape re-home and the alternate nomination were all skipped for a
/// transaction that had a board and a verdict.
///
/// Nothing about acceptance moves: the commit rule reads the oracle over the
/// board that exists, and `routeStopped(run.options)` — the BOARD's own deadline
/// and cancel flag — is still asked before and after the measurement. The flag
/// is cleared because a committed candidate becomes `run.baseline`, and a
/// baseline carrying one transaction's slice expiry as `cancelled` would abort
/// the phase and report the whole route cancelled.
fn unblockGateOverran(
    run: *UnblockRun,
    target: target_unblock.Target,
    candidate: router.RouteResult,
) router.RouteResult {
    if (!candidate.cancelled) return candidate;
    routeLog("target unblock {s}: gate overran the transaction's slice — judging the board it produced", .{
        run.placement.nets[target.net_i].name,
    });
    var out = candidate;
    out.cancelled = false;
    return out;
}

/// Build the transaction's candidate board: strip the target's own fragments and
/// every picked blocker's generated copper, freeze the rest byte-for-byte, and
/// re-route just that scope inside `deadline_ns`. Null whenever the slice
/// expired or the scoped route failed to echo the frozen copper exactly.
///
/// The candidate for a PER-GAP transaction: the blockers' copper stripped, ONE
/// island join drawn in the channel that frees, and the blockers re-routed
/// around it.
///
/// It differs from the whole-net candidate in the one way that matters: the
/// TARGET's own copper is never dropped. A rail in eight islands has copper
/// everywhere, most of it fine, and rewriting all of it to fix one 1 mm pocket
/// is both the expensive answer and the one `target_unblock.targetOf` refuses
/// to make a target of.
fn unblockGapCandidate(
    run: *UnblockRun,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
    deadline_ns: i128,
) std.mem.Allocator.Error!UnblockCandidate {
    const alloc = run.alloc;
    const placement = run.placement;
    const zones = try route_close.userZones(alloc, placement, run.options.existing_zones);
    const wanted = [_][]const u8{placement.nets[target.net_i].name};
    const open = try fab_readiness.openNetsAmong(alloc, placement, .{
        .tracks = run.baseline.tracks,
        .vias = run.baseline.vias,
        .zones = zones,
    }, &wanted);
    if (open.len == 0) return .{ .dead = .no_gap };
    const gap_i = unblockChosenGap(run.retired.items, target.net_i, open[0]) orelse return .{ .dead = .no_gap };
    const hop = open[0].gaps[gap_i];
    const request = (try route_close.hopRequest(alloc, placement, target.net_i, hop.from, hop.to)) orelse
        return .{ .dead = .no_request };

    const masks = try unblockMasks(run);
    const selected = masks.selected;
    const dropped = masks.dropped;
    for (picked) |pick| unblockMarkPick(run, pick, masks);
    const trial_base = try stripCopper(alloc, placement, run.options, try unblockRip(run, target, masks), run.baseline);

    // Draw the join in the channel the rip opened. Additive by construction:
    // whatever was nominated is already off the board, so a path that still has
    // to move copper is moving copper nobody agreed to move.
    const paths = try router.closeGaps(alloc, placement, run.params, .{
        .tracks = trial_base.tracks,
        .vias = trial_base.vias,
        .zones = run.options.existing_zones,
    }, &.{request}, .{
        .ripup = false,
        .judge = .{ .ctx = null, .keep = route_close.additiveOnly },
        .terminal_via = .banned,
        .raster = .{
            .window = route_close.hopWindow(request),
            .stop = .{ .deadline_ns = deadline_ns },
        },
    });
    if (paths.len == 0) return .{ .dead = .join_no_path };
    const join = paths[0] orelse return .{ .dead = .join_no_path };
    if (join.ripped.len > 0) return .{ .dead = .join_would_rip };
    if (join.tracks.len == 0 and join.vias.len == 0) return .{ .dead = .join_empty };

    var joined = trial_base;
    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    try tracks.appendSlice(alloc, trial_base.tracks);
    try tracks.appendSlice(alloc, join.tracks);
    try vias.appendSlice(alloc, trial_base.vias);
    try vias.appendSlice(alloc, join.vias);
    joined.tracks = tracks.items;
    joined.vias = vias.items;
    if (picked.len == 0) return .{ .board = joined };

    // Put the blockers back, around the copper that now occupies their channel.
    var existing_tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var existing_vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (joined.tracks) |track| try existing_tracks.append(alloc, trackAsExisting(track));
    for (joined.vias) |via| try existing_vias.append(alloc, viaAsExisting(via));
    var retry_options = run.options;
    retry_options.net = try unblockPolicies(run, target, picked);
    retry_options.effort = .one_shot;
    retry_options.selected_nets = selected;
    retry_options.existing_tracks = existing_tracks.items;
    retry_options.existing_vias = existing_vias.items;
    retry_options.stop.max_route_ms = 0;
    retry_options.stop.deadline_ns = deadline_ns;
    const raw = router.routeWithOptions(alloc, placement, run.params, retry_options) catch
        return .{ .dead = .route_error };
    if (raw.cancelled) return .{ .dead = .route_expired };
    var candidate = (gateConfigured(alloc, placement, run.params, raw, unblockGateOptions(run, retry_options), .{
        .scoped_target = true,
        // The TARGET is deliberately not named here: a per-gap transaction
        // closes one gap of several and leaves its net open on purpose, so its
        // commit rule asks the oracle for an island merge instead. What must
        // come back is every blocker the rip took.
        .must_close = try unblockNamed(run, null, picked),
    }) catch return .{ .dead = .route_error }).result;
    candidate = unblockGateOverran(run, target, candidate);
    candidate = try mergeResidualMetadata(alloc, dropped, selected, run.baseline, candidate);
    if (try retainsExistingCopper(alloc, candidate, existing_tracks.items, existing_vias.items, masks.lifted)) |lost| {
        unblockLogLost(run, placement.nets[target.net_i].name, lost);
        return .{ .dead = .copper_lost };
    }
    return .{ .board = try unblockRehome(run, target, picked, candidate, deadline_ns) };
}

fn unblockCandidate(
    run: *UnblockRun,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
    deadline_ns: i128,
) std.mem.Allocator.Error!UnblockCandidate {
    const alloc = run.alloc;
    const placement = run.placement;
    const masks = try unblockMasks(run);
    const selected = masks.selected;
    const dropped = masks.dropped;
    selected[target.net_i] = true;
    dropped[target.net_i] = generatedNetCopperCount(run.baseline, run.options, target.net_i) > 0;
    for (picked) |pick| unblockMarkPick(run, pick, masks);

    const trial_base = try stripCopper(alloc, placement, run.options, try unblockRip(run, target, masks), run.baseline);
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (trial_base.tracks) |track| try tracks.append(alloc, trackAsExisting(track));
    for (trial_base.vias) |via| try vias.append(alloc, viaAsExisting(via));

    var retry_options = run.options;
    retry_options.net = try unblockPolicies(run, target, picked);
    retry_options.effort = .one_shot;
    retry_options.selected_nets = selected;
    retry_options.existing_tracks = tracks.items;
    retry_options.existing_vias = vias.items;
    retry_options.stop.max_route_ms = 0;
    retry_options.stop.deadline_ns = deadline_ns;

    const raw = router.routeWithOptions(alloc, placement, run.params, retry_options) catch
        return .{ .dead = .route_error };
    if (raw.cancelled) return .{ .dead = .route_expired };
    var candidate = (gateConfigured(alloc, placement, run.params, raw, unblockGateOptions(run, retry_options), .{
        .scoped_target = true,
        // A whole-net transaction's success test IS its target closing, so the
        // target leads the list its blockers finish.
        .must_close = try unblockNamed(run, target, picked),
    }) catch return .{ .dead = .route_error }).result;
    candidate = unblockGateOverran(run, target, candidate);
    candidate = try mergeResidualMetadata(alloc, dropped, selected, run.baseline, candidate);
    candidate = try stripGeneratedFailures(alloc, placement, retry_options, selected, candidate);
    if (try retainsExistingCopper(alloc, candidate, tracks.items, vias.items, masks.lifted)) |lost| {
        unblockLogLost(run, placement.nets[target.net_i].name, lost);
        return .{ .dead = .copper_lost };
    }
    return .{ .board = try unblockRehome(run, target, picked, candidate, deadline_ns) };
}

/// Most island-joining hops the re-home draws for ONE lost victim.
///
/// A restore is a net the transaction is putting BACK, not a net it is
/// finishing: the scoped re-route already laid whatever its lattice could, and
/// what is left is the handful of joins that lattice cannot represent. Bounded
/// so a many-islanded rail cannot spend a whole transaction's slice on a net that
/// was never its target.
const unblock_rehome_max_hops: usize = 4;

/// Ask the gridless shape router to re-home the victims a scoped restore left
/// open, before the transaction is declared lost.
///
/// A ripped blocker's restore is an ordinary whole-board maze walk inside the
/// transaction's own scope — one tier, one lattice. The target's own join has had
/// the mesh behind it since the shape router landed (`router.closeGaps` runs the
/// maze and then the CDT channel), and the victim never did: measured on
/// barracuda (ReleaseSafe, v92), `GND` closed as one 1.27 mm hop and the whole
/// transaction was rolled back because `V_3V3_ID` — 12 elements of short stub —
/// could not be re-laid around the copper that had just taken its channel. So the
/// same fallback is wired here, asking the MESH ALONE
/// (`router.ShapeTier.only`): the maze has already answered for this exact
/// connection at whole-board scope, and a second lattice search would only re-ask
/// it.
///
/// Nothing about acceptance moves. The copper is additive by construction
/// (`ripup = false`, `route_close.additiveOnly`, and any path that ripped is
/// dropped), the oracle is re-read over the board that actually exists, and the
/// commit rule behind this still demands the island merge, no new DRC error and
/// every named net back — so a re-home that helps is committed and one that does
/// not leaves the transaction exactly as unacceptable as it already was.
fn unblockRehome(
    run: *UnblockRun,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
    candidate: router.RouteResult,
    deadline_ns: i128,
) std.mem.Allocator.Error!router.RouteResult {
    if (candidate.failed.len == 0 or picked.len == 0) return candidate;
    const name = run.placement.nets[target.net_i].name;
    // A WHOLE-NET transaction whose target is still open was refused on geometry.
    // Re-homing its victims cannot make that candidate acceptable, and this seam
    // must not turn the phase's cheapest verdict into its dearest. A per-gap
    // target is the other way round — its net stays open on purpose — so it is
    // judged by the island merge and never by this.
    if (target.kind == .whole_net and namedFailed(name, candidate.failed)) return candidate;
    var board = candidate;
    var landed: usize = 0;
    for (picked) |pick| {
        // Only a net the restore actually left OPEN is re-homed; everything else
        // came back and there is nothing to draw for it.
        const victim = unblockRehomable(run, pick, board) orelse continue;
        const window = unblockRehomeWindow(run, deadline_ns, pick.kind == .pair_recouple);
        // Every lost victim from here on gets a NAMED verdict. A silent skip is
        // what made this whole tier unfalsifiable: measured on barracuda
        // (ReleaseSafe, v95), `REF_LMX_N` was lost, the pair class was declined
        // one line before the first log statement, and the run printed neither
        // "re-homed" nor "found no channel" — indistinguishable from a tier that
        // was never reached at all.
        if (clock.nanoTimestamp() >= window) {
            routeLog("target unblock {s}: {s} left open, no window left to re-home it", .{ name, victim });
            break;
        }
        board = if (pick.kind == .pair_recouple)
            try unblockPairHome(run, name, pick, board, window, &landed)
        else
            try unblockShapeHome(run, name, pick.net_i, board, window, &landed);
    }
    if (landed == 0) return candidate;
    return unblockRetally(run, board);
}

/// The window ONE transaction's victim re-home may draw in.
///
/// Small on purpose: this is a handful of short additive hops for nets that were
/// already on the board, not a re-route, and it is spent inside a phase whose
/// own tail still owes an additive close.
const rehome_window_ns: i128 = 4 * clock.ns_per_s;

/// The window a COUPLED re-home may re-lay a lost pair in.
///
/// Larger than the shape channel's, because it is a different KIND of work: a
/// hop draws over a mesh that already exists, while `unblockPairHome` calls the
/// router, which builds this board's whole routing lattice before it lays the
/// first segment. Measured on barracuda (Debug, this increment): handed the
/// 4 s hop window, the `REF_LMX_P`/`REF_LMX_N` re-home verdicted "ran out of its
/// window" on every attempt — the mechanism engaged, was priced as a hop, and
/// could not finish.
///
/// Twenty seconds is the same claim the scoped gate's window makes
/// (`gate_window_ns`) and for the same reason: it is a stage BEHIND the
/// transaction's own re-route, bounded by what the pass still holds and never
/// into the additive close's reserve. It is spent only when a transaction
/// actually lost a declared pair, which is the rarest refusal this tier has.
const pair_rehome_window_ns: i128 = 20 * clock.ns_per_s;

/// When the re-home may run until.
///
/// NOT the transaction's own slice. That slice is handed to the scoped
/// re-route, which spends it to the last nanosecond by construction
/// (`stop.deadline_ns = deadline_ns`), and the gate behind it then reconciles
/// for tens of seconds MORE — so by the time a candidate exists, `now` is past
/// `deadline_ns` on every timed board and the re-home loop breaks before it asks
/// its first question. Measured on barracuda (ReleaseSafe, v92 and v93): two
/// transactions rolled back with "closed, but <victim> did not come back", the
/// exact refusal this tier was built for, and not one re-home verdict line was
/// ever printed. The mechanism was live in its unit tests and inert on the
/// board.
///
/// So the re-home claims a small window out of the clock the PASS still holds —
/// the board deadline, less the additive close's own reserve — and never less
/// than the transaction deadline it already had, so this can only ever grant
/// time. A clock-free board (bench, corpus, every test route) keeps exactly the
/// transaction deadline it had and stays byte-identical.
fn rehomeDeadline(now: i128, board_deadline: i128, reserve_ns: i128, deadline_ns: i128) i128 {
    return windowDeadline(now, board_deadline, reserve_ns, deadline_ns, rehome_window_ns);
}

fn pairRehomeDeadline(now: i128, board_deadline: i128, reserve_ns: i128, deadline_ns: i128) i128 {
    return windowDeadline(now, board_deadline, reserve_ns, deadline_ns, pair_rehome_window_ns);
}

/// The window THIS victim's re-home may draw in — measured fresh per pick,
/// because each one is spent before the next is priced, and sized for the work
/// its class actually is: a hop over the existing mesh, or a scoped coupled
/// route that builds the lattice first.
///
/// The coupled window is a DEPTH-round tool. It is twenty seconds, and a breadth
/// round whose whole point is one bounded verdict per target cannot hand a
/// single pick most of another target's turn — so in `.breadth` a pair re-home
/// is priced as the hop it shares this window with, and the "closed, but the
/// pair did not come back" verdict it produces is exactly what sorts that target
/// to the FRONT of the depth round, where the full window is affordable.
fn unblockRehomeWindow(run: *UnblockRun, deadline_ns: i128, coupled: bool) i128 {
    const now = clock.nanoTimestamp();
    const board_deadline = run.options.stop.deadline_ns;
    const reserve_ns = run.lim.slice.reserve_ns;
    return if (coupled and run.ladder == .depth)
        pairRehomeDeadline(now, board_deadline, reserve_ns, deadline_ns)
    else
        rehomeDeadline(now, board_deadline, reserve_ns, deadline_ns);
}

/// One small window out of the clock the PASS still holds, never shorter than
/// the deadline the caller already had.
///
/// Both places that need it — the victim re-home and the transaction's own gate
/// — are the same claim: a stage BEHIND the scoped re-route cannot run on the
/// slice that re-route has already spent, and neither may take the reserve the
/// additive close is owed. One arithmetic rather than two spellings, so the two
/// windows can only differ in the constant each declares.
fn windowDeadline(
    now: i128,
    board_deadline: i128,
    reserve_ns: i128,
    deadline_ns: i128,
    window_ns: i128,
) i128 {
    if (board_deadline == 0) return deadline_ns;
    const spare = board_deadline - reserve_ns - now;
    if (spare <= 0) return deadline_ns;
    return @max(deadline_ns, now + @min(window_ns, spare));
}

/// Is this ripped blocker one the re-home may be asked to put back — a net this
/// layer can name that the restore left open?
///
/// Its NAME when so, which is what every verdict line about it prints. The class
/// is deliberately not judged here: a declared pair is re-homed COUPLED
/// (`unblockPairHome`) rather than declined, and declining it before the first
/// log statement is what made this tier silent on the one board that reached it.
fn unblockRehomable(
    run: *UnblockRun,
    pick: vacate_policy.Nomination,
    board: router.RouteResult,
) ?[]const u8 {
    if (pick.net_i >= run.placement.nets.len) return null;
    const name = run.placement.nets[pick.net_i].name;
    return if (namedFailed(name, board.failed)) name else null;
}

/// Every island-joining hop one lost victim still needs, drawn by the mesh alone
/// over the candidate's own copper, up to `unblock_rehome_max_hops`.
fn unblockShapeHome(
    run: *UnblockRun,
    target: []const u8,
    net_i: usize,
    board: router.RouteResult,
    deadline_ns: i128,
    landed: *usize,
) std.mem.Allocator.Error!router.RouteResult {
    const victim = run.placement.nets[net_i].name;
    const zones = try route_close.userZones(run.alloc, run.placement, run.options.existing_zones);
    const wanted = [_][]const u8{victim};
    const open = try fab_readiness.openNetsAmong(run.alloc, run.placement, .{
        .tracks = board.tracks,
        .vias = board.vias,
        .zones = zones,
    }, &wanted);
    if (open.len == 0) return board;
    var out = board;
    var drawn: usize = 0;
    for (open[0].gaps) |gap| {
        if (drawn >= unblock_rehome_max_hops or clock.nanoTimestamp() >= deadline_ns) break;
        const path = (try unblockShapeHop(run, net_i, out, gap, deadline_ns)) orelse continue;
        out = try unblockAbsorb(run.alloc, out, path);
        drawn += 1;
        routeLog("target unblock {s}: {s} re-homed by shape channel ({d:.2}mm hop, {d} tracks, {d} vias)", .{
            target, victim, gap.mm, path.tracks.len, path.vias.len,
        });
    }
    if (drawn == 0) {
        routeLog("target unblock {s}: {s} found no shape channel ({d} hop(s) open)", .{
            target, victim, open[0].gaps.len,
        });
        return board;
    }
    landed.* += drawn;
    return out;
}

/// One hop for a lost victim, drawn by the gridless shape router alone, or null
/// when the mesh finds no channel — or finds one only by moving copper nobody
/// nominated, which is the one thing a restore may never do.
fn unblockShapeHop(
    run: *UnblockRun,
    net_i: usize,
    board: router.RouteResult,
    gap: fab_readiness.OpenGap,
    deadline_ns: i128,
) std.mem.Allocator.Error!?router.GapPath {
    const request = (try route_close.hopRequest(run.alloc, run.placement, net_i, gap.from, gap.to)) orelse
        return null;
    const paths = try router.closeGaps(run.alloc, run.placement, run.params, .{
        .tracks = board.tracks,
        .vias = board.vias,
        .zones = run.options.existing_zones,
    }, &.{request}, .{
        .ripup = false,
        .shape = .only,
        .judge = .{ .ctx = null, .keep = route_close.additiveOnly },
        .terminal_via = .banned,
        .raster = .{
            .window = route_close.hopWindow(request),
            .stop = .{ .deadline_ns = deadline_ns },
        },
    });
    if (paths.len == 0) return null;
    const path = paths[0] orelse return null;
    if (path.ripped.len > 0) return null;
    if (path.tracks.len == 0 and path.vias.len == 0) return null;
    return path;
}

/// Re-lay a lost DIFFERENTIAL PAIR victim with the router's own coupled
/// constructor, over the candidate board's copper.
///
/// A pair comes back COUPLED or not at all — that is the contract
/// `unblockPairsHeld` enforces and the whole reason the class is nominable — so
/// the lone shape channel every other victim gets is the wrong tool: one leg
/// drawn independently is copper the commit rule is certain to throw away. The
/// right tool is the one that ripped it, which is the router: a SCOPED route
/// over exactly the two legs, with every other net's copper frozen byte for
/// byte, runs `diff_pairs.corridorPlan` and the coupled constructor exactly as
/// the transaction's own restore did — but over the board as it now stands, with
/// the target's new copper in place, and with a window of its own rather than
/// the tail of a slice the restore has already spent.
///
/// Measured on barracuda (ReleaseSafe, v95): the wide `SPI_DSA_CSN` transaction
/// closed its target and was rolled back because `REF_LMX_N` — 38 elements of
/// declared pair — did not come back, and the re-home declined it silently one
/// line before its first log statement.
///
/// Nothing about acceptance moves. The copper is additive (every foreign item is
/// frozen and the echo is proved), the oracle is re-read over the board that now
/// exists, and the commit rule behind this still demands the island merge, no new
/// DRC error, every named net back AND `target_unblock.pairHeld` per pair — so a
/// coupled re-home that is worse than the pair it replaced is refused exactly as
/// it was before.
fn unblockPairHome(
    run: *UnblockRun,
    target: []const u8,
    pick: vacate_policy.Nomination,
    board: router.RouteResult,
    deadline_ns: i128,
    landed: *usize,
) std.mem.Allocator.Error!router.RouteResult {
    const victim = run.placement.nets[pick.net_i].name;
    const pair_i = diffPairIndex(run.placement, pick.net_i) orelse {
        routeLog("target unblock {s}: {s} is a pair leg with no declared pair to re-lay", .{ target, victim });
        return board;
    };
    const legs = unblockPairLegs(run, pair_i);
    // THE escalation for this tier's one remaining verdict, tried first.
    // Measured on barracuda (ReleaseSafe, v96): the wide `SPI_DSA_CSN`
    // transaction closed its target, was rolled back because `REF_LMX_N` did not
    // come back, and this re-home then answered "found no coupled channel" —
    // which is the maze's word for "not on the lattice", the exact refusal the
    // gridless mesh exists to re-ask. The pair asks it at ENVELOPE width, so a
    // channel it finds holds BOTH legs, and the legs are still built and
    // exact-probed by the constructor that would have built them off a maze
    // centreline (`route_policy.PairChannel`).
    for ([2]route_policy.PairChannel{ .mesh_behind_maze, .maze_only }) |channel| {
        if (clock.nanoTimestamp() >= deadline_ns) break;
        const out = (try unblockPairRoute(run, target, legs, board, deadline_ns, channel)) orelse continue;
        landed.* += 1;
        routeLog("target unblock {s}: {s}/{s} re-homed coupled via {s} ({d} -> {d} tracks, {d} -> {d} vias)", .{
            target,           legs.p,         legs.n,         @tagName(channel),
            board.tracks.len, out.tracks.len, board.vias.len, out.vias.len,
        });
        return out;
    }
    routeLog("target unblock {s}: {s}/{s} found no coupled channel (maze or mesh)", .{ target, legs.p, legs.n });
    return board;
}

/// ONE scoped coupled re-route of the pair over the candidate's frozen copper,
/// through the search space `channel` names — or null when it produced nothing
/// the ORACLE will accept.
///
/// The two spaces are tried in turn rather than only the wider one, because the
/// mesh tier stands IN FRONT of the pair's legacy leader/follower fallback: a
/// construction it commits is one that fallback never gets to make, and a
/// coupled pair that passes the exact clearance probe is not yet a coupled pair
/// the oracle joins. Measured on the walled-pair fixture, the mesh commits
/// exactly such a construction and the pair, which the lattice run re-homes,
/// stops being re-homed at all. So the lattice run is asked again behind it, and
/// whichever space the oracle accepts is the one that lands.
fn unblockPairRoute(
    run: *UnblockRun,
    target: []const u8,
    legs: UnblockPairLegs,
    board: router.RouteResult,
    deadline_ns: i128,
    channel: route_policy.PairChannel,
) std.mem.Allocator.Error!?router.RouteResult {
    const selected = try run.alloc.alloc(bool, run.placement.nets.len);
    @memset(selected, false);
    for (legs.nets) |net_i| selected[net_i] = true;

    // Freeze every other net's copper and take the pair's own fragments off, so
    // the constructor lays the pair whole rather than around the half-run the
    // scoped restore left behind.
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (board.tracks) |track| {
        if (selectedNet(selected, track.net)) continue;
        try tracks.append(run.alloc, trackAsExisting(track));
    }
    for (board.vias) |via| {
        if (selectedNet(selected, via.net)) continue;
        try vias.append(run.alloc, viaAsExisting(via));
    }

    var opts = run.options;
    opts.effort = .one_shot;
    opts.selected_nets = selected;
    opts.existing_tracks = tracks.items;
    opts.existing_vias = vias.items;
    opts.stop.max_route_ms = 0;
    opts.stop.deadline_ns = deadline_ns;
    opts.guides.pair_channel = channel;
    // Collect the wall, whichever way this attempt goes. A pinch is a fact about
    // the BOARD, not about the attempt: a re-home that lands still tells the
    // deepening round nothing it needs, and one that refuses has just named the
    // two bodies leaving the pair no room.
    var pinch = route_policy.PinchLog{};
    opts.guides.pinch = &pinch;
    defer unblockRecordPinch(run, &pinch);

    const raw = router.routeWithOptions(run.alloc, run.placement, run.params, opts) catch {
        routeLog("target unblock {s}: {s}/{s} coupled re-home failed ({s})", .{ target, legs.p, legs.n, @tagName(channel) });
        return null;
    };
    if (raw.cancelled) {
        routeLog("target unblock {s}: {s}/{s} coupled re-home ran out of its window ({s})", .{ target, legs.p, legs.n, @tagName(channel) });
        return null;
    }
    if (try retainsExistingCopper(run.alloc, raw, tracks.items, vias.items, &.{})) |lost| {
        unblockLogLost(run, target, lost);
        return null;
    }
    var out = board;
    out.tracks = raw.tracks;
    out.vias = raw.vias;
    if (!try unblockPairJoined(run, legs, out)) {
        routeLog("target unblock {s}: {s}/{s} laid no pair the oracle joins ({s})", .{ target, legs.p, legs.n, @tagName(channel) });
        return null;
    }
    return out;
}

/// Take the wall a coupled re-home's envelope search named into this
/// transaction's own record, and say so.
///
/// Only the NET owners are kept. A wall made of the board edge or an authored
/// keepout is a real diagnosis and an unusable nomination — there is no copper
/// to rip — so it is reported and dropped, which is the "if both pinch owners
/// are never-negotiable, the verdict itself is the finding" rule. Whether a net
/// owner may actually be moved is not decided here either: that is
/// `vacate_policy`'s, asked once, at the tier that would do the ripping.
fn unblockRecordPinch(run: *UnblockRun, log: *const route_policy.PinchLog) void {
    for (log.reports()) |report| {
        for ([2]route_policy.PinchSide{ .a, .b }) |side| {
            const net_i = report.owner(side) orelse continue;
            if (net_i >= run.placement.nets.len) continue;
            if (unblockPinchHeld(run, net_i)) continue;
            run.pinch.append(run.alloc, net_i) catch return;
            routeLog("target unblock: pair channel pinched by {s} — {d:.3}mm where the envelope needs {d:.3}mm", .{
                run.placement.nets[net_i].name,
                report.have_mm,
                report.need_mm,
            });
        }
    }
}

/// Is this net already in the transaction's pinch record?
fn unblockPinchHeld(run: *UnblockRun, net_i: usize) bool {
    for (run.pinch.items) |seen| if (seen == net_i) return true;
    return false;
}

/// The pinch owners a nomination sweep may offer, as ordinary corridor
/// candidates — or nothing at all outside a deepening round.
///
/// Distance ZERO, because that is what the mesh measured: this copper is not
/// merely near the corridor, it is the body the pair's envelope could not get
/// past. It is appended BEHIND the swept candidates so the nearer occupant of
/// the target's own hop still speaks first for a pair, exactly as before, and a
/// net the sweep already found is never offered twice.
fn unblockPinchCandidates(
    run: *UnblockRun,
    ranked: []const blocker_nomination.Candidate,
) std.mem.Allocator.Error![]const blocker_nomination.Candidate {
    if (run.pinch_use == .ignore or run.pinch.items.len == 0) return ranked;
    var out: std.ArrayList(blocker_nomination.Candidate) = .empty;
    try out.appendSlice(run.alloc, ranked);
    for (run.pinch.items) |net_i| {
        var seen = false;
        for (ranked) |candidate| {
            if (candidate.net_i == net_i) seen = true;
        }
        if (seen) continue;
        routeLog("target unblock: offering pinch owner {s} to the deepening sweep", .{
            run.placement.nets[net_i].name,
        });
        try out.append(run.alloc, .{ .net_i = net_i, .dist = 0 });
    }
    return out.toOwnedSlice(run.alloc);
}

/// One declared pair as this layer reads it: the two flattened net indices it
/// re-routes together, and their names for the verdict lines.
const UnblockPairLegs = struct { nets: [2]usize, p: []const u8, n: []const u8 };

fn unblockPairLegs(run: *UnblockRun, pair_i: usize) UnblockPairLegs {
    const pair = run.placement.diff_pairs[pair_i];
    return .{
        .nets = .{ pair.p, pair.n },
        .p = run.placement.nets[pair.p].name,
        .n = run.placement.nets[pair.n].name,
    };
}

/// Did the coupled re-home actually put BOTH legs back — the oracle's answer over
/// the board that now exists, not the scoped route's own claim about it.
fn unblockPairJoined(
    run: *UnblockRun,
    legs: UnblockPairLegs,
    board: router.RouteResult,
) std.mem.Allocator.Error!bool {
    const zones = try route_close.userZones(run.alloc, run.placement, run.options.existing_zones);
    const wanted = [_][]const u8{ legs.p, legs.n };
    const open = try fab_readiness.openNetsAmong(run.alloc, run.placement, .{
        .tracks = board.tracks,
        .vias = board.vias,
        .zones = zones,
    }, &wanted);
    return open.len == 0;
}

/// A hop's copper onto a candidate board.
fn unblockAbsorb(
    alloc: std.mem.Allocator,
    board: router.RouteResult,
    path: router.GapPath,
) std.mem.Allocator.Error!router.RouteResult {
    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    try tracks.appendSlice(alloc, board.tracks);
    try tracks.appendSlice(alloc, path.tracks);
    try vias.appendSlice(alloc, board.vias);
    try vias.appendSlice(alloc, path.vias);
    var out = board;
    out.tracks = tracks.items;
    out.vias = vias.items;
    return out;
}

/// Re-read the candidate's connectivity once the re-home has laid copper, so the
/// `routed`/`total`/`failed` the commit rule reads is the oracle's answer about
/// the board that now exists rather than the one the gate measured.
fn unblockRetally(
    run: *UnblockRun,
    board: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    const zones = try route_close.userZones(run.alloc, run.placement, run.options.existing_zones);
    const tally = try fab_readiness.routableTally(run.alloc, run.placement, .{
        .tracks = board.tracks,
        .arcs = board.arcs,
        .rf_paths = board.rf_port_outcomes,
        .vias = board.vias,
        .zones = zones,
    });
    var out = board;
    out.routed = tally.routed;
    out.total = tally.total;
    out.failed = tally.open;
    return out;
}

/// The scoped transaction's per-net policies. Only routing ORDER changes, and
/// only for this transaction: the target claims the vacated corridor first — and
/// ahead of plane stitching, which would otherwise refill it — then the blockers
/// in pick order. Every authored layer mask, waypoint, via cap and RF policy
/// survives verbatim, except that the target's own deferred repair corridor,
/// inert in the broad pass, becomes its hard topology now that the copper it was
/// authored around is off the board.
fn unblockPolicies(
    run: *UnblockRun,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
) std.mem.Allocator.Error![]const route_policy.NetPolicy {
    const policies = try run.alloc.alloc(route_policy.NetPolicy, run.placement.nets.len);
    for (policies, 0..) |*policy, net_i| policy.* = if (net_i < run.options.net.len)
        run.options.net[net_i]
    else
        .{};
    var priority: u32 = std.math.maxInt(u32);
    policies[target.net_i].wave.priority = priority;
    policies[target.net_i].wave.before_planes = 1;
    applyDeferredRepair(&policies[target.net_i]);
    for (picked) |pick| {
        priority -= 1;
        policies[pick.net_i].wave.priority = priority;
        // A pair's two legs share ONE routing slot: the coupled construction is
        // entered from whichever leg the greedy loop reaches first and lays
        // both, so splitting their order would only decide which leg leads.
        if (unblockPickTwin(run, pick)) |twin| policies[twin].wave.priority = priority;
    }
    return policies;
}

/// The commit rule — four questions in cost order, all of which must pass:
///
///   1. the oracle's open-net NAMES shrank and nothing new joined them;
///   2. every net the transaction named is off that open list — the target
///     closed AND every ripped blocker came back. Both of these read the open
///     set `gate` already computed, so they cost nothing and run first;
///   3. `target_unblock.Gate` — `fine_accept`'s own rule: strictly more nets
///     connected and not one connected net lost, measured over the WHOLE board,
///     the nets this transaction never named included, because a rerouted trace
///     can cut a pour and open a net nobody touched;
///   4. no new DRC error. `gate` already drops DRC-implicated mutable copper, so
///     a candidate arriving here is fab-legal; the counts are compared anyway
///     because this tier may only ever hand the board back at least as clean.
///   5. every declared pair the transaction re-laid came back to contract
///     (`unblockPairsHeld`). None of the four above can see this: two
///     independently mazed legs are connected, legal, and precisely what a
///     `(diff-pair …)` class forbids.
///
/// The deadline is re-read after the gate: an oracle pass can itself carry the
/// run past the board deadline, and speculative copper is never committed after
/// that boundary.
/// The verdict a PER-GAP transaction commits under.
///
/// Its target net is still OPEN afterwards — closing one gap of seven is the
/// whole point — so the whole-net rule ("strictly more nets connected") would
/// refuse every one of these on principle. What is asked instead is exactly
/// what the transaction was formed to do: the target holds one fewer copper
/// island, every blocker it ripped came back connected, no net the board
/// already joined was lost, and the geometry did not get worse. The first and
/// third of those are one question to the fabrication oracle
/// (`Gate.acceptsIslandMerge`), which is the same authority the whole-net
/// verdict and the post-route gate both ask.
fn unblockGapAccepted(
    run: *UnblockRun,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
    candidate: router.RouteResult,
) std.mem.Allocator.Error!UnblockVerdict {
    if (routeStopped(run.options)) return .{};
    const named = try unblockNamed(run, null, picked);
    if (!target_unblock.transactionClosed(candidate.failed, named)) return .{};
    if (!try run.accept.acceptsIslandMerge(
        target.net_i,
        unblockBoard(run.baseline),
        unblockBoard(candidate),
    )) return .{};
    if (routeStopped(run.options)) return .{};
    const measured = try unblockMeasure(run.alloc, run.placement, run.params, candidate);
    if (measured.errors > run.measured.errors) return .{};
    if (!unblockPairsHeld(run, picked, measured)) return .{};
    return .{ .kept = true, .measured = measured };
}

/// A finished route result as the connectivity gate weighs it. All four copper
/// kinds: a native arc's chords are handles whose curved envelope is what carves
/// a pour, and an RF path's compact centreline is a handle whose swept polygon
/// is what lands on the pads — so a projection that keeps only tracks and vias
/// hands the oracle a board on which a net joined by either reads OPEN.
fn unblockBoard(r: router.RouteResult) target_unblock.Board {
    return .{ .tracks = r.tracks, .vias = r.vias, .arcs = r.arcs, .rf_paths = r.rf_port_outcomes };
}

fn unblockAccepted(
    run: *UnblockRun,
    target: target_unblock.Target,
    picked: []const vacate_policy.Nomination,
    candidate: router.RouteResult,
) std.mem.Allocator.Error!UnblockVerdict {
    if (!strictResidualGain(candidate, run.baseline) or routeStopped(run.options)) return .{};
    const named = try unblockNamed(run, target, picked);
    if (!target_unblock.transactionClosed(candidate.failed, named)) return .{};
    if (!try run.accept.accepts(unblockBoard(run.baseline), unblockBoard(candidate))) return .{};
    if (routeStopped(run.options)) return .{};
    const measured = try unblockMeasure(run.alloc, run.placement, run.params, candidate);
    if (measured.errors > run.measured.errors) return .{};
    if (!unblockPairsHeld(run, picked, measured)) return .{};
    return .{ .kept = true, .measured = measured };
}

/// How many fabrication-blocking violations a board carries, by the same
/// canonical geometric check the route gate ratchets against.
fn drcErrorCount(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    result: router.RouteResult,
) std.mem.Allocator.Error!usize {
    return drc.errorCount(try drc.check(alloc, placement, result, params.clearance));
}

/// That same pass, kept whole: the error count AND every declared pair's
/// coupling and skew, so a transaction that re-laid a pair is judged on the
/// board it is ratcheting against rather than on a second reading of it.
fn unblockMeasure(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    result: router.RouteResult,
) std.mem.Allocator.Error!UnblockMeasure {
    const violations = try drc.check(alloc, placement, result, params.clearance);
    return .{
        .errors = drc.errorCount(violations),
        .pairs = try target_unblock.pairHealthAll(
            alloc,
            placement,
            .{ .tracks = result.tracks, .vias = result.vias },
            violations,
        ),
    };
}

/// Every net name this transaction NAMED — its target when the transaction
/// rewrites one, every picked blocker, and the twin leg a pair nomination takes
/// with it. `target_unblock.transactionClosed` reads it to insist that all of
/// them are off the oracle's open list on the candidate board: a pair whose
/// second leg did not come back is a broken pair, not a cheaper one.
fn unblockNamed(
    run: *UnblockRun,
    target: ?target_unblock.Target,
    picked: []const vacate_policy.Nomination,
) std.mem.Allocator.Error![]const []const u8 {
    var named: std.ArrayList([]const u8) = .empty;
    if (target) |t| try named.append(run.alloc, run.placement.nets[t.net_i].name);
    for (picked) |pick| {
        try named.append(run.alloc, run.placement.nets[pick.net_i].name);
        if (unblockPickTwin(run, pick)) |twin| try named.append(run.alloc, run.placement.nets[twin].name);
    }
    return named.toOwnedSlice(run.alloc);
}

/// Did every declared pair this transaction re-laid come back to contract?
///
/// The pair-specific half of the commit rule, and the reason a pair may be
/// nominated at all. The whole-board gate can only see connectivity and
/// fabrication legality — a pair re-routed as two independent legs is fully
/// connected and fully legal, and is exactly the outcome the class forbids. So
/// each ripped pair is re-measured against the pair it replaced
/// (`target_unblock.pairHeld`: both legs down, the coupling window no worse,
/// the skew inside the coupled constructor's own equalisation slack) and one
/// failure rolls the whole transaction back.
///
/// Only the pairs this transaction touched are judged. A pair it never named
/// is the whole-board gate's business, the same as every other net.
fn unblockPairsHeld(
    run: *UnblockRun,
    picked: []const vacate_policy.Nomination,
    candidate: UnblockMeasure,
) bool {
    for (picked) |pick| {
        if (pick.kind != .pair_recouple) continue;
        const pair_i = diffPairIndex(run.placement, pick.net_i) orelse return false;
        if (pair_i >= run.measured.pairs.len or pair_i >= candidate.pairs.len) return false;
        const before = run.measured.pairs[pair_i];
        const after = candidate.pairs[pair_i];
        if (!target_unblock.pairHeld(before, after)) {
            routeLog("target unblock: pair {s}/{s} refused (skew {d:.4} -> {d:.4} mm, uncoupled {d} -> {d}, legs {d})", .{
                run.placement.nets[run.placement.diff_pairs[pair_i].p].name,
                run.placement.nets[run.placement.diff_pairs[pair_i].n].name,
                before.skew_mm,
                after.skew_mm,
                before.uncoupled,
                after.uncoupled,
                after.legs_with_copper,
            });
            return false;
        }
        routeLog("target unblock: pair {s}/{s} re-laid coupled (skew {d:.4} -> {d:.4} mm, uncoupled {d} -> {d})", .{
            run.placement.nets[run.placement.diff_pairs[pair_i].p].name,
            run.placement.nets[run.placement.diff_pairs[pair_i].n].name,
            before.skew_mm,
            after.skew_mm,
            before.uncoupled,
            after.uncoupled,
        });
    }
    return true;
}

/// Which declared pair `net_i` belongs to, as an index into
/// `placement.diff_pairs`.
fn diffPairIndex(placement: optimizer.Placement, net_i: usize) ?usize {
    for (placement.diff_pairs, 0..) |pair, i| {
        if (pair.p == net_i or pair.n == net_i) return i;
    }
    return null;
}

/// A cluster must close at least one old airwire and may not introduce a new
/// one. Comparing only counts would accept a connection trade; this compares
/// the oracle's names as a set.
fn strictResidualGain(candidate: router.RouteResult, baseline: router.RouteResult) bool {
    if (candidate.failed.len >= baseline.failed.len) return false;
    for (candidate.failed) |name| if (!namedFailed(name, baseline.failed)) return false;
    return true;
}

fn namedFailed(name: []const u8, failed: []const []const u8) bool {
    for (failed) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn stillFailedDiagnoses(
    alloc: std.mem.Allocator,
    diagnoses: []const route_diagnose.Diagnosis,
    failed: []const []const u8,
) std.mem.Allocator.Error![]const route_diagnose.Diagnosis {
    var out: std.ArrayList(route_diagnose.Diagnosis) = .empty;
    for (diagnoses) |diagnosis| if (namedFailed(diagnosis.net, failed)) try out.append(alloc, diagnosis);
    return out.toOwnedSlice(alloc);
}

/// The routed→retained projection of one track: the router's own copper seen
/// as the obstacle a later pass must route around. The single spelling, so a
/// field added to `ExistingTrack` cannot be carried by one copy and dropped by
/// another.
pub fn trackAsExisting(track: router.Track) route_policy.ExistingTrack {
    return .{
        .x1 = track.x1,
        .y1 = track.y1,
        .x2 = track.x2,
        .y2 = track.y2,
        .layer = track.layer,
        .width = track.width,
        .net = track.net,
    };
}

/// `trackAsExisting` for a via barrel.
pub fn viaAsExisting(via: router.Via) route_policy.ExistingVia {
    return .{ .x = via.x, .y = via.y, .dia = via.dia, .drill = via.drill, .net = via.net };
}

/// The inverse of `trackAsExisting` — retained copper seen as router geometry.
fn existingAsTrack(track: route_policy.ExistingTrack) router.Track {
    return .{
        .x1 = track.x1,
        .y1 = track.y1,
        .x2 = track.x2,
        .y2 = track.y2,
        .layer = track.layer,
        .width = track.width,
        .net = track.net,
    };
}

/// `existingAsTrack` for a via barrel.
fn existingAsVia(via: route_policy.ExistingVia) router.Via {
    return .{ .x = via.x, .y = via.y, .dia = via.dia, .drill = via.drill, .net = via.net };
}

/// The routed-copper bundle the retained copper in `options` amounts to, as the
/// connectivity/DRC/Gerber consumers read it.
///
/// `zones` is a parameter and not an afterthought: the connectivity oracle joins
/// a net's pads THROUGH a copper pour, so a bundle built without the board's
/// user zones reports a plane-connected net as open. Every caller passes the
/// zones it holds; there is one projection so a caller cannot silently build
/// half a bundle. `arcs` and `rf_paths` have no retained counterpart in
/// `route_policy.Options` — retained copper is tracks, vias and pours — so they
/// stay at the bundle's empty defaults rather than being dropped per copy.
pub fn retainedCopper(
    alloc: std.mem.Allocator,
    options: route_policy.Options,
    zones: []const pour.UserZone,
) std.mem.Allocator.Error!export_gerber.Copper {
    const tracks = try alloc.alloc(router.Track, options.existing_tracks.len);
    for (options.existing_tracks, tracks) |track, *slot| slot.* = existingAsTrack(track);
    const vias = try alloc.alloc(router.Via, options.existing_vias.len);
    for (options.existing_vias, vias) |via, *slot| slot.* = existingAsVia(via);
    return .{ .tracks = tracks, .vias = vias, .zones = zones };
}

/// The pours in `options` as the bundle's `zones`, for a caller that reached
/// its retained copper through `route_policy.Options` alone (the seed builder)
/// rather than through a request's saved-zone list. Keepout zones are dropped —
/// `fab_readiness` documents that `copper.zones` carries poured copper only.
pub fn retainedZones(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
) std.mem.Allocator.Error![]const pour.UserZone {
    var out: std.ArrayList(pour.UserZone) = .empty;
    for (options.existing_zones) |zone| {
        if (!zone.copper or zone.net < 0) continue;
        const ni: usize = @intCast(zone.net);
        if (ni >= placement.nets.len) continue;
        try out.append(alloc, .{
            .net = placement.nets[ni].name,
            .layer = zone.layer,
            .poly = zone.polygon,
            .priority = zone.priority,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn sameTrack(track: router.Track, existing: route_policy.ExistingTrack) bool {
    return track.x1 == existing.x1 and track.y1 == existing.y1 and
        track.x2 == existing.x2 and track.y2 == existing.y2 and
        track.layer == existing.layer and track.width == existing.width and track.net == existing.net;
}

fn sameVia(via: router.Via, existing: route_policy.ExistingVia) bool {
    return via.x == existing.x and via.y == existing.y and via.dia == existing.dia and
        via.drill == existing.drill and via.net == existing.net;
}

fn retainedTrack(track: router.Track, existing: []const route_policy.ExistingTrack) bool {
    for (existing) |item| if (sameTrack(track, item)) return true;
    return false;
}

fn retainedVia(via: router.Via, existing: []const route_policy.ExistingVia) bool {
    for (existing) |item| if (sameVia(via, item)) return true;
    return false;
}

fn retainedNetCopper(options: route_policy.Options, net_i: usize) bool {
    const net: i32 = @intCast(net_i);
    for (options.existing_tracks) |track| if (track.net == net) return true;
    for (options.existing_vias) |via| if (via.net == net) return true;
    return false;
}

/// The frozen item a scoped retry failed to echo back, named for the trace.
const LostCopper = struct { net: i32, via: bool };

/// Prove that a scoped retry echoed every frozen item exactly, including
/// duplicate instances. Router finishers and the gate may rewrite a selected
/// net wholesale, so connectivity alone is not a sufficient preservation check
/// for caller-owned or OUT-OF-SCOPE copper. Null when everything was echoed.
///
/// `lifted` is the exception the corridor lift forced, and it is the scope word
/// in that sentence doing the work. A lifted net keeps the copper outside the
/// channel, so that copper is still in the frozen board handed to the router —
/// and the same call puts the net in `selected_nets`, because re-stitching what
/// the lift disturbed is the whole point. Demanding a byte-identical echo from
/// a net you just handed to the router is a contradiction, and it is one only a
/// LIFT can reach: a whole-net rip leaves nothing of its net behind to freeze.
///
/// Measured at ReleaseSafe (v87): once the slice was large enough for the wide
/// transactions to finish, three of five targets died exactly here — the scoped
/// re-route completed and then self-vetoed on the copper the transaction had
/// deliberately put in its own scope.
///
/// Nothing is given up by the exception. A lifted net is still held to the
/// oracle (`transactionClosed` requires it off the open list — a ground pad
/// whose only via was deleted reads as an island), still to the whole-board
/// accept gate, and still to the DRC ratchet.
fn retainsExistingCopper(
    alloc: std.mem.Allocator,
    candidate: router.RouteResult,
    existing_tracks: []const route_policy.ExistingTrack,
    existing_vias: []const route_policy.ExistingVia,
    lifted: []const bool,
) std.mem.Allocator.Error!?LostCopper {
    const used_tracks = try alloc.alloc(bool, candidate.tracks.len);
    const used_vias = try alloc.alloc(bool, candidate.vias.len);
    @memset(used_tracks, false);
    @memset(used_vias, false);

    for (existing_tracks) |existing| {
        if (netDropped(lifted, existing.net)) continue;
        var found = false;
        for (candidate.tracks, used_tracks) |track, *used| {
            if (used.* or !sameTrack(track, existing)) continue;
            used.* = true;
            found = true;
            break;
        }
        if (!found) return .{ .net = existing.net, .via = false };
    }
    for (existing_vias) |existing| {
        if (netDropped(lifted, existing.net)) continue;
        var found = false;
        for (candidate.vias, used_vias) |via, *used| {
            if (used.* or !sameVia(via, existing)) continue;
            used.* = true;
            found = true;
            break;
        }
        if (!found) return .{ .net = existing.net, .via = true };
    }
    return null;
}

/// Name the frozen copper a scoped retry failed to echo, so `copper_lost` says
/// WHOSE copper moved rather than only that some did.
fn unblockLogLost(run: *UnblockRun, target: []const u8, lost: LostCopper) void {
    const name = if (lost.net >= 0 and @as(usize, @intCast(lost.net)) < run.placement.nets.len)
        run.placement.nets[@intCast(lost.net)].name
    else
        "(unknown net)";
    routeLog("target unblock {s}: frozen {s} on {s} was not echoed back", .{
        target,
        if (lost.via) "via" else "track",
        name,
    });
}

fn selectedNet(selected: []const bool, net: i32) bool {
    if (net < 0) return false;
    const net_i: usize = @intCast(net);
    return net_i < selected.len and selected[net_i];
}

/// Remove only GENERATED copper on selected nets the oracle still calls open.
/// Caller-retained copper is preserved byte-for-byte even when it belongs to an
/// open net, so an incremental route never edits authored/out-of-scope metal.
fn stripGeneratedFailures(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
    selected: []const bool,
    in: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    const dropped = try alloc.alloc(bool, placement.nets.len);
    for (placement.nets, dropped, 0..) |net, *drop, net_i| {
        drop.* = net_i < selected.len and selected[net_i] and namedFailed(net.name, in.failed);
    }
    return stripGeneratedMask(alloc, placement, options, dropped, in);
}

/// Which copper a transaction takes off the board.
///
/// Two granularities, and the difference is an argument about connectivity
/// rather than about cost. A `dropped` net goes WHOLE, because for an ordinary
/// net its tracks ARE its connectivity and half a net is not a state anything
/// can reason about. A `lifted` net loses only what crosses the corridor: it is
/// plane- or pour-carried, so the copper that stays is joined by the fill
/// whether or not the lifted part ever comes back, which is the same argument
/// that let the policy nominate it at all. The rest of its copper is frozen
/// byte-for-byte like every other net's, and the transaction still proves the
/// board pad by pad before it commits — which is what catches a lift that took
/// a pad's only path to the plane.
const CopperRip = struct {
    /// Nets stripped whole.
    dropped: []const bool,
    /// Nets stripped only where they cross `hops`. Empty for every caller but
    /// the corridor-lifting unblock tier.
    lifted: []const bool = &.{},
    /// The corridor a lift is measured against, and how wide it is — the
    /// nomination's own hops and radius, so what was nominated is what is
    /// removed.
    hops: []const blocker_nomination.Hop = &.{},
    radius_mm: f64 = 0,

    /// Does this rip take `track` off the board?
    fn takesTrack(self: CopperRip, track: router.Track) bool {
        if (netDropped(self.dropped, track.net)) return true;
        return netDropped(self.lifted, track.net) and
            blocker_nomination.trackGap(self.hops, track) <= self.radius_mm;
    }

    /// Does this rip take `via` off the board?
    fn takesVia(self: CopperRip, via: router.Via) bool {
        if (netDropped(self.dropped, via.net)) return true;
        return netDropped(self.lifted, via.net) and
            blocker_nomination.viaGap(self.hops, via) <= self.radius_mm;
    }
};

/// Remove generated copper and shape metadata for an explicit net mask while
/// preserving caller-retained copper exactly. The failed-only residual and the
/// joint cluster share this physical operation; only how they choose the mask
/// differs.
fn stripGeneratedMask(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
    dropped: []const bool,
    in: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    return stripCopper(alloc, placement, options, .{ .dropped = dropped }, in);
}

/// The same operation at either granularity (see `CopperRip`). Shape metadata
/// follows the WHOLE-net mask only: a lifted net keeps its copper and therefore
/// keeps the arcs and bend findings that describe it.
fn stripCopper(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    options: route_policy.Options,
    rip: CopperRip,
    in: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    const dropped = rip.dropped;
    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    var arcs: std.ArrayList(router.Arc) = .empty;
    var sharp: std.ArrayList(router.SharpBend) = .empty;
    for (in.tracks) |track| {
        if (rip.takesTrack(track) and !retainedTrack(track, options.existing_tracks)) continue;
        try tracks.append(alloc, track);
    }
    for (in.vias) |via| {
        if (rip.takesVia(via) and !retainedVia(via, options.existing_vias)) continue;
        try vias.append(alloc, via);
    }
    for (in.arcs) |arc| if (!netDropped(dropped, arc.net)) try arcs.append(alloc, arc);
    for (in.sharp_bends) |bend| if (!netDropped(dropped, bend.net)) try sharp.append(alloc, bend);

    var out = in;
    out.tracks = try tracks.toOwnedSlice(alloc);
    out.vias = try vias.toOwnedSlice(alloc);
    out.arcs = try arcs.toOwnedSlice(alloc);
    out.sharp_bends = try sharp.toOwnedSlice(alloc);
    const zones = try route_close.userZones(alloc, placement, options.existing_zones);
    const tally = try fab_readiness.routableTally(alloc, placement, .{
        .tracks = out.tracks,
        .arcs = out.arcs,
        .rf_paths = out.rf_port_outcomes,
        .vias = out.vias,
        .zones = zones,
    });
    out.routed = tally.routed;
    out.total = tally.total;
    out.failed = tally.open;
    return out;
}

fn mergeResidualMetadata(
    alloc: std.mem.Allocator,
    replaced: []const bool,
    rerouted: []const bool,
    baseline: router.RouteResult,
    candidate: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    var arcs: std.ArrayList(router.Arc) = .empty;
    var sharp: std.ArrayList(router.SharpBend) = .empty;
    var outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    for (baseline.arcs) |arc| if (!selectedNet(replaced, arc.net)) try arcs.append(alloc, arc);
    try arcs.appendSlice(alloc, candidate.arcs);
    for (baseline.sharp_bends) |bend| if (!selectedNet(replaced, bend.net)) try sharp.append(alloc, bend);
    try sharp.appendSlice(alloc, candidate.sharp_bends);
    for (baseline.rf_port_outcomes) |outcome| if (!selectedNet(replaced, outcome.net)) try outcomes.append(alloc, outcome);
    try outcomes.appendSlice(alloc, candidate.rf_port_outcomes);

    var out = candidate;
    out.arcs = try arcs.toOwnedSlice(alloc);
    out.sharp_bends = try sharp.toOwnedSlice(alloc);
    out.rf_port_outcomes = try outcomes.toOwnedSlice(alloc);
    out.search_limited = try mergeNetIndexMetadata(alloc, rerouted, baseline.search_limited, candidate.search_limited);
    out.reference_replayed = try mergeNetIndexMetadata(alloc, rerouted, baseline.reference_replayed, candidate.reference_replayed);
    // The result is a composite whose frozen majority came from `baseline`.
    // Preserve that lattice provenance while carrying forward any overflow
    // observed by either run.
    out.grid_scale = baseline.grid_scale;
    out.grid_overflow = baseline.grid_overflow or candidate.grid_overflow;
    out.ripup_rounds +|= baseline.ripup_rounds;
    return out;
}

fn mergeNetIndexMetadata(
    alloc: std.mem.Allocator,
    rerouted: []const bool,
    baseline: []const usize,
    candidate: []const usize,
) std.mem.Allocator.Error![]const usize {
    var merged: std.ArrayList(usize) = .empty;
    for (baseline) |net_i| {
        if (net_i >= rerouted.len or !rerouted[net_i]) try merged.append(alloc, net_i);
    }
    try merged.appendSlice(alloc, candidate);
    std.mem.sort(usize, merged.items, {}, std.sort.asc(usize));
    if (merged.items.len == 0) return &.{};
    var write: usize = 1;
    for (merged.items[1..]) |net_i| {
        if (net_i == merged.items[write - 1]) continue;
        merged.items[write] = net_i;
        write += 1;
    }
    merged.items.len = write;
    return merged.toOwnedSlice(alloc);
}

fn residualBetter(candidate: router.RouteResult, baseline: router.RouteResult) bool {
    if (candidate.routed != baseline.routed) return candidate.routed > baseline.routed;
    return residualCost(candidate) < residualCost(baseline) - cost_eps;
}

/// One via costs the same as 20 mm of trace, which prevents a residual retry
/// from accepting an arbitrarily long detour merely because it saved one via.
///
/// This WAS route_score v1's balance once completion and DRC were tied. It no
/// longer is: v1 priced a via 20× above the maze's own layer-change cost, and
/// `route_score` v2 corrected that to 0.5 (5 mm of trace). The 20 here is now a
/// deliberately stricter local tie-break — this gate accepts a retry that
/// changes nothing but geometry, so it stays conservative about spending
/// copper. Retuning it is a routing-behaviour change and wants its own
/// measurement; it is not a v2 follow-through.
fn residualCost(result: router.RouteResult) f64 {
    return 20.0 * @as(f64, @floatFromInt(result.vias.len)) + traceLength(result.tracks);
}

fn traceLength(tracks: []const router.Track) f64 {
    var mm: f64 = 0;
    for (tracks) |track| mm += std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    return mm;
}

/// Standard effort is the unattended completion tier, so its additive gate
/// may spend a little more than the interactive one-shot ceiling before the
/// residual decision. These are still deterministic count/distance bounds;
/// every accepted hop remains non-ripping and DRC-ratcheted by `gate`.
/// The wide ceiling is deliberate: barracuda's V_1V8A closes ONLY through its
/// 37 mm whole-net gate join (capping this at 12 mm lost the net, v47), while
/// the treadmill of hopeless 40-50 mm mazes (SPI_SCK, TXDATA, SPI_LMX_CSN) is
/// bounded by the per-pass slice and sorted LAST by the millimetre-ordered hop
/// plan — the slice truncates the long shots, never the near-certain joins.
const standard_gate_max_hop_mm: f64 = 50.0;
const standard_gate_max_hops: usize = 64;

/// Put a fresh route through the post-route connectivity oracle before its
/// numbers leave this seam (`route_close.reconcile`). EVERY routing surface
/// lowers through here, so gating in one place is what makes `routed` mean the
/// same thing on the viewer, the PNG, `/api/pcb-describe`, and `route_pcb` —
/// and stops any of them reporting a net complete whose pads its own copper
/// never joined. Reconciliation is additive; after it, the DRC ratchet removes
/// generated copper from the smallest practical set of implicated mutable nets
/// rather than returning a fab-invalid route. A scoped run confines both halves
/// to its scope, so re-routing one group never changes another.
fn gate(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    raw: router.RouteResult,
    options: route_policy.Options,
) std.mem.Allocator.Error!route_close.Reconciled {
    return gateConfigured(alloc, placement, params, raw, options, .{});
}

/// What one gate call is allowed to do beyond the shared route options.
const GateConfig = struct {
    /// Whether this call's endgame may put an escape via inside an SMD land.
    terminal_via: router.TerminalVia = .banned,
    /// The refusals this route's earlier gate passes collected, when the
    /// caller runs the gate more than once against one evolving board.
    memo: ?*route_close.HopMemo = null,
    /// Let this pass's long hops search a corridor wide enough to detour.
    wide_corridors: bool = false,
    /// Is `raw` already a gate's own output? Then a pass that lands no hop
    /// hands back byte-identical copper, and canonicalization, the topology
    /// prune and the DRC ratchet would re-derive verdicts an earlier pass
    /// already reached — measured at 23 s of a 240 s barracuda route, on the
    /// pass that by definition changed nothing.
    already_gated: bool = false,
    /// Is this gate the tail of a SCOPED transaction — one net (plus the
    /// blockers a transaction ripped for it) over byte-frozen board copper?
    ///
    /// Then it earns the unattended hop ceiling even though the scoped route
    /// itself runs at `one_shot`. The short ceiling exists to stop a broad
    /// one-shot gate spending a corridor maze per net across the whole open
    /// set; a scoped pass has exactly one net to spend it on and a corridor
    /// that was freed for it. Measured on barracuda: the target's own join is
    /// 42-55 mm on every one of these transactions, so under the 4 mm default
    /// `route_close.planHops` dropped the target's whole net before a hop was
    /// ever planned — the scoped gate could not attempt the join the
    /// transaction was formed to make, by maze OR by the shape router behind
    /// it, while the broad gates attempted exactly that join all along.
    scoped_target: bool = false,
    /// The scoped target's OWN island-joining hop (mm), where the caller knows
    /// it. Zero — the default — leaves a scoped gate on exactly
    /// `standard_gate_max_hop_mm`, so every existing caller is unchanged.
    ///
    /// A scoped gate's ceiling has to cover the join its transaction was formed
    /// to make, and the unattended ceiling covers barracuda's 42.5 mm
    /// `SPI_LMX_CSN` and 49.6 mm `TXDATA_ADF` while stopping just short of its
    /// 55.3 mm `LOCK_DET` — whose hop `route_close.planHops` therefore dropped
    /// before the maze OR the shape tier was ever asked about it, in the one
    /// pass formed for nothing else. Bounded by `scoped_gate_max_hop_mm`.
    target_hop_mm: f64 = 0,
    /// The nets a SCOPED transaction NAMED — its target when it rewrites one,
    /// and every blocker it ripped to free that target's corridor.
    ///
    /// Naming them turns the gate's cost order around for a candidate that is
    /// about to be thrown away. The commit rule's first question is exactly
    /// `target_unblock.transactionClosed` over this list, and the reconcile
    /// pass has already answered it: everything after reconcile only ever
    /// REMOVES copper — the topology prune rejects any round that costs the
    /// board a net, the DRC ratchet drops implicated nets whole — so a name
    /// still on the open list here is still on it when the gate returns, and
    /// the transaction rolls back either way.
    ///
    /// The SEMANTICS are untouched: the same commit rule decides, reading the
    /// same oracle. What changes is that a refusal stops costing a whole-board
    /// topology scan. Measured on barracuda: the two cross-board targets spent
    /// 11.7 s apiece pruning a board they then discarded, which is also what
    /// carried their gate past its own slice and turned a real geometry verdict
    /// into "ran out of its slice".
    ///
    /// Empty — the default — keeps every broad caller on the full chain in the
    /// order it was tuned in, and an ACCEPTED candidate still pays it in full:
    /// the prune's copper and the ratchet's DRC reading are what the board
    /// keeps, so they are computed for exactly the boards that are kept.
    must_close: []const []const u8 = &.{},
};

/// Hard ceiling on what a scoped gate's own target may lift `max_hop_mm` to.
///
/// A hop longer than this is not a join, it is the board: barracuda's outline is
/// 62.7 x 26.8 mm, so its longest possible pad-to-pad line is about 68 mm and
/// this admits every real join on it while still refusing to hand the gate an
/// unbounded corridor maze on a board nobody has measured.
const scoped_gate_max_hop_mm: f64 = 64.0;

/// The longest island-joining hop one gate pass may attempt, for these options
/// and this gate configuration. A scoped pass reaches its own target's join; a
/// broad one keeps exactly the ceilings it was tuned on.
fn gateHopCeiling(options: route_policy.Options, cfg: GateConfig) f64 {
    if (!cfg.scoped_target) {
        return if (options.effort.retries()) standard_gate_max_hop_mm else route_close.default_max_hop_mm;
    }
    return @min(@max(standard_gate_max_hop_mm, cfg.target_hop_mm), scoped_gate_max_hop_mm);
}

/// Whether this route's topology prune has ever been ADOPTED. A rejected prune
/// returns the copper it was handed, so running it again over a board that
/// gained a couple of hops buys a whole-board topology scan (17.7 s of a timed
/// barracuda route, per pass) for a result already known to be discarded.
/// One reconcile pass's share of a timed board. The gate runs several times
/// per route (broad, per-retry, repeated tail passes), so a single call must
/// never own the board deadline: barracuda's broad gate once spent 108 s of a
/// 240 s budget closing islands and starved the deferred repairs, the repeat
/// gates, and the unblock phase behind it. The bound is a SLICE, not a
/// shortened board deadline — a first attempt at this shrank stop.deadline_ns
/// and reconcile's expiry then marked the whole board cancelled, aborting the
/// pipeline at 99 s with GND stitching unfinished. An untimed run (deadline 0)
/// stays unsliced — tests and bench routes keep their clock-free determinism.
const gate_reconcile_slice_ns: i128 = 30 * clock.ns_per_s;

fn gateSliceDeadline(stop: route_policy.Stop) i128 {
    if (stop.deadline_ns == 0) return 0;
    return clock.nanoTimestamp() + gate_reconcile_slice_ns;
}

fn gateReconcile(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    raw: router.RouteResult,
    options: route_policy.Options,
    cfg: GateConfig,
) std.mem.Allocator.Error!route_close.Reconciled {
    return route_close.reconcile(alloc, placement, params, raw, options.existing_zones, .{
        .only_nets = options.selected_nets,
        // Deterministic distance/count bounds make failed-net joins safe to
        // attempt before EITHER effort tier returns; standard gets the larger
        // unattended bounds declared above. Doing this before its residual
        // ladder matters: each recovered net shrinks the open set seen by the
        // bounded joint-cluster retry. The gate never rips foreign copper, so
        // a declined join is byte-neutral.
        .include_failed = true,
        .max_hop_mm = gateHopCeiling(options, cfg),
        .max_hops = if (options.effort.retries()) standard_gate_max_hops else route_close.default_max_hops,
        // Keep the broad first gate conservative. Via-in-SMD escape is useful
        // for a diagnosed terminal, but enabling it for every open island makes
        // the cheapest failed hop monopolize a board deadline before the quick
        // surface joins have been harvested. A finishing pass may opt a single
        // selected net into `.smd_ok` after this breadth-first gate.
        .terminal_via = cfg.terminal_via,
        .pass = .{
            .slice_deadline_ns = gateSliceDeadline(options.stop),
            .stop = options.stop,
            .memo = cfg.memo,
            .wide_corridors = cfg.wide_corridors,
        },
    });
}

fn gateConfigured(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    raw: router.RouteResult,
    options: route_policy.Options,
    cfg: GateConfig,
) std.mem.Allocator.Error!route_close.Reconciled {
    if (options.timing) |t| t.begin(.gate);
    const gate_t0 = clock.nanoTimestamp();
    var reconciled = try gateReconcile(alloc, placement, params, raw, options, cfg);
    const reconcile_ms = phaseMs(gate_t0);
    if (cfg.already_gated and reconciled.hops_kept == 0) {
        routeLog("gate: reconcile {d}ms, no hop landed on already-gated copper, {d} failed", .{
            reconcile_ms, reconciled.result.failed.len,
        });
        if (options.timing) |t| t.end(.gate);
        return reconciled;
    }
    if (cfg.must_close.len > 0 and !target_unblock.transactionClosed(reconciled.result.failed, cfg.must_close)) {
        routeLog("gate: reconcile {d}ms, a net this transaction named is still open — refused before the prune", .{
            reconcile_ms,
        });
        if (options.timing) |t| t.end(.gate);
        return reconciled;
    }
    reconciled.result = try canonicalizeGeneratedJunctions(alloc, placement, reconciled.result, options);
    const canon_ms = phaseMs(gate_t0);
    // NO topology prune here. It used to run in every gate pass, which put the
    // reconcile ladder to work on a board the prune had just rewritten — the
    // anchors and stubs a later pass's closer would have used were gone — and
    // put the DRC ratchet immediately behind it, so a removal that tripped any
    // error-severity rule cost that net ALL of its generated copper. Measured
    // on barracuda: the first gate went `17 -> 8 failed` with the prune
    // rejected and `17 -> 26 failed` with it active, and the board finished at
    // 583 tracks instead of 963. Cleanup is cosmetic and belongs after
    // functional convergence — see `finishLoweredCandidate`.
    const safe = try drcSafeResult(alloc, placement, params, reconciled, options);
    routeLog("gate: reconcile {d}ms, canon +{d}ms, drc +{d}ms, total {d}ms, {d} -> {d} failed", .{
        reconcile_ms,                canon_ms - reconcile_ms,
        phaseMs(gate_t0) - canon_ms, phaseMs(gate_t0),
        raw.failed.len,              safe.result.failed.len,
    });
    if (options.timing) |t| t.end(.gate);
    return safe;
}

/// Give every physical contact introduced by this route an explicit
/// endpoint-on-centreline representation before topology pruning judges it,
/// then gloss what that representation costs.
///
/// Canonicalization is the LAST thing on this board that emits copper, and it
/// emits the two shapes nothing downstream looks for: a split leaves two
/// perfectly collinear halves whose partner may since have gone away, and a weld
/// leaves a micron-scale off-axis tail. Both are invisible to the router's own
/// finish, which ran before this. `glossFinishedTracks` closes over the same
/// `mutable` mask, so caller-retained copper is as untouched by the gloss as it
/// is by the canonicalization: it may be bridged TO, never rewritten.
fn canonicalizeGeneratedJunctions(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    options: route_policy.Options,
) std.mem.Allocator.Error!router.RouteResult {
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(alloc, routed.tracks);
    var mutable: std.ArrayList(bool) = .empty;
    for (routed.tracks) |track| try mutable.append(alloc, topologyMutable(options.selected_nets, track.net) and
        !retainedTrack(track, options.existing_tracks));
    try router.canonicalizeTraceJunctions(alloc, &tracks, &mutable, routed.vias);
    try router.glossFinishedTracks(alloc, placement, &tracks, &mutable, routed.vias);
    var out = routed;
    out.tracks = try tracks.toOwnedSlice(alloc);
    return out;
}

fn topologyMutable(selected: []const bool, net: i32) bool {
    if (net < 0) return false;
    if (selected.len == 0) return true;
    const net_i: usize = @intCast(net);
    return net_i < selected.len and selected[net_i];
}

fn viaNamedByFinding(via: router.Via, via_i: usize, finding: drc.Violation) bool {
    const removable_kind = finding.kind == .single_layer_via or finding.kind == .redundant_via;
    return removable_kind and finding.who.net_a == via.net and
        finding.who.track_a == drc.partyIndex(via_i);
}

fn dropNamedTracksForNet(
    tracks: *std.ArrayList(router.Track),
    planned: []const router.Track,
    net: i32,
) bool {
    var track_write: usize = 0;
    var removed = false;
    for (tracks.items) |track| {
        var drop = false;
        if (track.net == net) for (planned) |candidate| {
            if (!std.meta.eql(track, candidate)) continue;
            drop = true;
            break;
        };
        if (drop) {
            removed = true;
        } else {
            tracks.items[track_write] = track;
            track_write += 1;
        }
    }
    tracks.shrinkRetainingCapacity(track_write);
    return removed;
}

const StubDrop = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: *std.ArrayList(router.Track),
    findings: []const drc.Violation,
    selected: []const bool,
    /// Nets this prune already damaged once and handed back (see
    /// `salvageOpenedNets`). Their copper is final for the rest of the prune.
    frozen: []const bool = &.{},
};

/// Has this net been handed back after a round opened it? Indexed like
/// `placement.nets`; an empty mask freezes nothing.
fn frozenNet(frozen: []const bool, net: i32) bool {
    if (net < 0) return false;
    const i: usize = @intCast(net);
    return i < frozen.len and frozen[i];
}

fn removableTrackFinding(finding: drc.Violation) bool {
    return finding.kind == .dangling_copper or finding.kind == .copper_stub;
}

fn dropStubFindings(ctx: StubDrop) std.mem.Allocator.Error!bool {
    var planned: std.ArrayList(router.Track) = .empty;
    for (ctx.findings) |finding| {
        if (!removableTrackFinding(finding)) continue;
        if (finding.who.track_a < 0) continue;
        if (frozenNet(ctx.frozen, finding.who.net_a)) continue;
        const track_i: usize = @intCast(finding.who.track_a);
        if (track_i >= ctx.tracks.items.len) continue;
        try planned.append(ctx.alloc, ctx.tracks.items[track_i]);
    }
    var removed = false;
    for (ctx.placement.nets, 0..) |_, net_i| {
        const net: i32 = @intCast(net_i);
        if (!topologyMutable(ctx.selected, net) or frozenNet(ctx.frozen, net)) continue;
        var named = false;
        for (ctx.findings) |finding| if (removableTrackFinding(finding) and
            finding.who.net_a == net and finding.who.track_a >= 0)
        {
            named = true;
            break;
        };
        if (!named) continue;

        removed = dropNamedTracksForNet(ctx.tracks, planned.items, net) or removed;
    }
    return removed;
}

const ViaDrop = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    vias: *std.ArrayList(router.Via),
    findings: []const drc.Violation,
    options: route_policy.Options,
    frozen: []const bool = &.{},
};

fn dropRedundantVias(ctx: ViaDrop) std.mem.Allocator.Error!bool {
    const drop = try ctx.alloc.alloc(bool, ctx.vias.items.len);
    @memset(drop, false);
    for (ctx.vias.items, 0..) |via, via_i| {
        if (!topologyMutable(ctx.options.selected_nets, via.net) or frozenNet(ctx.frozen, via.net)) continue;
        const net_i: usize = @intCast(via.net);
        if (net_i >= ctx.placement.nets.len or
            optimizer.isGroundName(router.shortName(ctx.placement.nets[net_i].name)))
            continue;
        for (ctx.findings) |finding| if (viaNamedByFinding(via, via_i, finding)) {
            drop[via_i] = true;
            break;
        };
    }
    var write: usize = 0;
    var removed = false;
    for (ctx.vias.items, drop) |via, remove| {
        if (remove) {
            removed = true;
            continue;
        }
        ctx.vias.items[write] = via;
        write += 1;
    }
    ctx.vias.shrinkRetainingCapacity(write);
    return removed;
}

/// Did this prune cost the board a connection? `total` moving is the same
/// answer: a net that stops being routable at all is not a tidier board.
fn connectivityLost(before: fab_readiness.Tally, after: fab_readiness.Tally) bool {
    return after.routed < before.routed or after.total != before.total;
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |old| if (std.mem.eql(u8, old, name)) return true;
    return false;
}

fn netIndexOf(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, net_i| if (std.mem.eql(u8, net.name, name)) return net_i;
    return null;
}

/// Put every frozen net's copper back exactly as the prune found it.
///
/// Sound because a prune only ever REMOVES, and every remover packs survivors
/// down in place: `list` is therefore a SUBSEQUENCE of `original`, in order.
/// Replaying `original` and re-admitting the frozen nets' items rebuilds the
/// board the prune started from — position for position — for those nets, and
/// leaves every other net exactly as this round left it.
fn restoreFrozenCopper(
    comptime T: type,
    alloc: std.mem.Allocator,
    original: []const T,
    list: *std.ArrayList(T),
    frozen: []const bool,
) std.mem.Allocator.Error!void {
    var out: std.ArrayList(T) = .empty;
    var kept: usize = 0;
    for (original) |item| {
        if (kept < list.items.len and std.meta.eql(list.items[kept], item)) {
            try out.append(alloc, item);
            kept += 1;
            continue;
        }
        if (frozenNet(frozen, item.net)) try out.append(alloc, item);
    }
    list.* = out;
}

const Salvage = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    tracks: *std.ArrayList(router.Track),
    vias: *std.ArrayList(router.Via),
    frozen: []bool,
    before: fab_readiness.Tally,
    running: fab_readiness.Tally,
};

/// Hand back exactly the nets this round damaged, and freeze them for the rest
/// of the prune. Returns false when the loss cannot be attributed net by net,
/// which is the caller's signal to fall back to rejecting the whole prune.
///
/// The attribution is free: `Tally.open` already names every routable net the
/// scan found disconnected, so the nets this round cost are the names in
/// `running.open` that `before.open` did not have. No per-net oracle is run —
/// one whole-board tally is seconds on a large board and the prune pays it per
/// round already.
fn salvageOpenedNets(s: Salvage) std.mem.Allocator.Error!?SalvageReport {
    // A net that stopped being ROUTABLE is not a connectivity loss this can
    // reason about net by net; hand the whole prune back instead.
    if (s.running.total != s.before.total) return null;
    var report = SalvageReport{};
    for (s.running.open) |name| {
        if (nameListed(s.before.open, name)) continue;
        const net_i = netIndexOf(s.placement, name) orelse return null;
        if (net_i >= s.frozen.len or s.frozen[net_i]) return null; // already given back and still open
        s.frozen[net_i] = true;
        if (report.opened == 0) report.first = name;
        report.opened += 1;
    }
    if (report.opened == 0) return null;
    try restoreFrozenCopper(router.Track, s.alloc, s.routed.tracks, s.tracks, s.frozen);
    try restoreFrozenCopper(router.Via, s.alloc, s.routed.vias, s.vias, s.frozen);
    for (s.frozen) |f| report.frozen += @intFromBool(f);
    return report;
}

/// What one salvage handed back: the first net this round opened (the log's
/// witness) plus how many nets are frozen once it is done.
const SalvageReport = struct { first: []const u8 = "?", opened: usize = 0, frozen: usize = 0 };

/// A finding family a REMOVAL can create, beyond the connectivity the tally
/// already guards. The tally answers "is this net still one piece"; these
/// answer "does the copper PATH a requirement measures still exist" — the
/// bypass leg from a cap's rail land to the IC land it decouples, a ground
/// pad's distance to its nearest return barrel, an endpoint left on nothing,
/// and the fabricated net-open reading that credits fill the topology scan
/// cannot see. Measured on barracuda, a prune judged on topology alone logged
/// `kept (topo 0->0)` every round while driving bypass_open 2 -> 30,
/// ground_via_distance 1 -> 21 and net_open 15 -> 126: every removal was
/// connectivity-safe and the board was still ruined.
fn removalDamageKind(k: drc.Kind) bool {
    return switch (k) {
        .net_open, .bypass_open, .ground_via_distance, .copper_stub => true,
        else => false,
    };
}

/// How many times the damage census may hand a net back before the prune
/// gives up and rejects the whole plan. Two is one more than any board has
/// needed: the first pass names the nets a removal hurt, the second confirms
/// the restoration fixed them.
const damage_salvage_rounds: usize = 2;

/// The finished board read through its fabricated fill — the same reading the
/// DRC ratchet takes, so the prune cannot approve copper the pass behind it is
/// about to blame a whole net for.
fn filledFindings(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    result: router.RouteResult,
    zones: []const pour.UserZone,
) []const drc.Violation {
    return drc_rules.checkFilled(alloc, .{
        .placement = placement,
        .routed = result,
        .clearance = params.clearance,
        .zones = zones,
    });
}

/// How many damage findings each net carries, indexed like `placement.nets`.
fn damageCensus(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    findings: []const drc.Violation,
) std.mem.Allocator.Error![]usize {
    const out = try alloc.alloc(usize, placement.nets.len);
    @memset(out, 0);
    for (findings) |finding| {
        if (!removalDamageKind(finding.kind) or finding.who.net_a < 0) continue;
        const net_i: usize = @intCast(finding.who.net_a);
        if (net_i < out.len) out[net_i] += 1;
    }
    return out;
}

/// The board position a damage salvage restores from and the working lists it
/// repairs in place.
const DamageSalvage = struct {
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    tracks: *std.ArrayList(router.Track),
    vias: *std.ArrayList(router.Via),
    frozen: []bool,
};

/// Freeze and hand back every net the removals left carrying MORE damage than
/// it arrived with. Returns how many nets were newly frozen; zero means the
/// board is clean by this reading and the prune stands.
fn salvageDamagedNets(s: DamageSalvage, before: []const usize, after: []const usize) std.mem.Allocator.Error!usize {
    var newly: usize = 0;
    for (before, after, 0..) |was, now, net_i| {
        if (now <= was or net_i >= s.frozen.len or s.frozen[net_i]) continue;
        s.frozen[net_i] = true;
        newly += 1;
    }
    if (newly == 0) return 0;
    try restoreFrozenCopper(router.Track, s.alloc, s.routed.tracks, s.tracks, s.frozen);
    try restoreFrozenCopper(router.Via, s.alloc, s.routed.vias, s.vias, s.frozen);
    return newly;
}

/// A prune's copper plus whether the verification ADOPTED it. A rejected prune
/// hands back the copper it started from, so a caller running the prune again
/// over near-identical copper is buying a whole-board topology scan for a
/// result it already knows will be discarded.
const Pruned = struct { result: router.RouteResult, kept: bool };

/// Reconciliation is additive and runs after the live router's own cleanup.
/// Prune whatever it introduced against the same topology oracle DRC reports.
fn pruneGateTopology(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    routed: router.RouteResult,
    options: route_policy.Options,
) std.mem.Allocator.Error!router.RouteResult {
    return (try pruneGateTopologyOutcome(alloc, placement, params, routed, options)).result;
}

fn pruneGateTopologyOutcome(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    routed: router.RouteResult,
    options: route_policy.Options,
) std.mem.Allocator.Error!Pruned {
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(alloc, routed.tracks);
    var vias: std.ArrayList(router.Via) = .empty;
    try vias.appendSlice(alloc, routed.vias);
    const user_zones = try route_close.userZones(alloc, placement, options.existing_zones);
    const prune_t0 = clock.nanoTimestamp();
    // Round zero's board IS the board this scan just judged, so the loop opens
    // with these findings rather than re-deriving them: one whole-board
    // topology scan on a routed barracuda is seconds of a timed route's budget,
    // and the gate pays this per pass.
    const topology_before = drc_rules.checkTopologyFilled(alloc, .{
        .placement = placement,
        .routed = routed,
        .clearance = 0,
        .zones = user_zones,
    });
    var findings = topology_before;
    const limit = tracks.items.len + vias.items.len + 1;
    var round: usize = 0;
    var pruned = false;
    var tally_before: ?fab_readiness.Tally = null;
    const frozen = try alloc.alloc(bool, placement.nets.len);
    @memset(frozen, false);
    while (round < limit) : (round += 1) {
        const tracks_removed = try dropStubFindings(.{
            .alloc = alloc,
            .placement = placement,
            .tracks = &tracks,
            .findings = findings,
            .selected = options.selected_nets,
            .frozen = frozen,
        });
        const vias_removed = try dropRedundantVias(.{
            .alloc = alloc,
            .placement = placement,
            .vias = &vias,
            .findings = findings,
            .options = options,
            .frozen = frozen,
        });
        if (!tracks_removed and !vias_removed) break;
        pruned = true;
        var current = routed;
        current.tracks = tracks.items;
        current.vias = vias.items;
        // Pruning only ever REMOVES copper, so connectivity is monotone across
        // the rounds and a net a round has cost cannot be redeemed by a later
        // one. Asking NOW is therefore the same verdict for a fraction of the
        // scans — barracuda's damage lands in the FIRST round's removals.
        //
        // The verdict is per NET, not per board. Redundancy proposes and the
        // fabrication oracle disposes, and they disagree about a handful of
        // nets on a large board: the support graph reaches a barrel only
        // through the copper that lands on it, so a run whose two halves are
        // joined by nothing but a via reads as two dead components, while the
        // fab graph joins them at the barrel and loses the net when they go.
        // Discarding the whole board's cleanup for that is a bad trade —
        // barracuda kept ~124 warnings to protect one net — so the damaged
        // nets get their copper back and are frozen for the remaining rounds,
        // and everything the oracle agreed about still comes off.
        if (tally_before == null) tally_before = try fab_readiness.routableTally(alloc, placement, .{
            .tracks = routed.tracks,
            .arcs = routed.arcs,
            .rf_paths = routed.rf_port_outcomes,
            .vias = routed.vias,
            .zones = user_zones,
        });
        const running = try fab_readiness.routableTally(alloc, placement, .{
            .tracks = current.tracks,
            .arcs = current.arcs,
            .rf_paths = current.rf_port_outcomes,
            .vias = current.vias,
            .zones = user_zones,
        });
        if (connectivityLost(tally_before.?, running)) {
            const salvaged = try salvageOpenedNets(.{
                .alloc = alloc,
                .placement = placement,
                .routed = routed,
                .tracks = &tracks,
                .vias = &vias,
                .frozen = frozen,
                .before = tally_before.?,
                .running = running,
            }) orelse {
                routeLog("prune: round {d} would open nets ({d} -> {d} routed), REJECTED, {d}ms", .{
                    round, tally_before.?.routed, running.routed, phaseMs(prune_t0),
                });
                return .{ .result = routed, .kept = false };
            };
            current.tracks = tracks.items;
            current.vias = vias.items;
            // The restoration should read exactly like the board the prune
            // started from for those nets, so this is a guard rather than a
            // decision: if the tally still shows a loss the attribution was
            // wrong somewhere, and the old whole-plan rejection is the answer.
            const recovered = try fab_readiness.routableTally(alloc, placement, .{
                .tracks = current.tracks,
                .arcs = current.arcs,
                .rf_paths = current.rf_port_outcomes,
                .vias = current.vias,
                .zones = user_zones,
            });
            if (connectivityLost(tally_before.?, recovered)) {
                routeLog("prune: round {d} restoration did not recover ({d} -> {d} routed), REJECTED, {d}ms", .{
                    round, tally_before.?.routed, recovered.routed, phaseMs(prune_t0),
                });
                return .{ .result = routed, .kept = false };
            }
            routeLog("prune: round {d} opened {s}, restored+frozen ({d} net(s), {d} frozen), continuing, {d}ms", .{
                round, salvaged.first, salvaged.opened, salvaged.frozen, phaseMs(prune_t0),
            });
        }
        findings = drc_rules.checkTopologyFilled(alloc, .{
            .placement = placement,
            .routed = current,
            .clearance = 0,
            .zones = user_zones,
        });
    }
    // Nothing came off, so the verification pair would re-measure the copper it
    // started from. A board the gate did not change is the common case on a
    // repeated gate ladder, and this is what keeps that pass cheap.
    if (!pruned) {
        routeLog("prune: {d} rounds, nothing removed, {d}ms", .{ round, phaseMs(prune_t0) });
        return .{ .result = routed, .kept = true };
    }
    var out = routed;
    out.tracks = tracks.items;
    out.vias = vias.items;
    // The rounds guarded CONNECTIVITY. That is not the whole of what a removal
    // can break: a section can go while leaving every net one piece and still
    // destroy the path a requirement check measures (see `removalDamageKind`).
    // The prune runs once per board now, so it can afford to read the finished
    // copper through the full filled check and hand back any net it made
    // worse. Bounded: each pass either freezes a net or stops.
    const damage_before = try damageCensus(alloc, placement, filledFindings(alloc, placement, params, routed, user_zones));
    var damage_rounds: usize = 0;
    while (damage_rounds < damage_salvage_rounds) : (damage_rounds += 1) {
        const after = try damageCensus(alloc, placement, filledFindings(alloc, placement, params, out, user_zones));
        const handed_back = try salvageDamagedNets(
            .{ .alloc = alloc, .routed = routed, .tracks = &tracks, .vias = &vias, .frozen = frozen },
            damage_before,
            after,
        );
        if (handed_back == 0) break;
        out.tracks = tracks.items;
        out.vias = vias.items;
        routeLog("prune: removals damaged {d} net(s) beyond connectivity, restored+frozen, re-judging", .{handed_back});
    } else {
        // Still worse after the salvage budget: the damage is not attributable
        // net by net, so the whole plan goes back exactly as it always did.
        routeLog("prune: damage outlived {d} salvage round(s), REJECTED, {d}ms", .{ damage_rounds, phaseMs(prune_t0) });
        return .{ .result = routed, .kept = false };
    }
    // Every round's removals were already weighed against the starting tally
    // and the damage census, and anything that failed either has been handed
    // back, so what is left to judge is the topology error count.
    const kept = drc.errorCount(findings) <= drc.errorCount(topology_before);
    var frozen_nets: usize = 0;
    for (frozen) |f| frozen_nets += @intFromBool(f);
    routeLog("prune: {d} rounds, {d}t {d}v removed, {d} net(s) frozen, {d}ms, {s} (topo {d}->{d})", .{
        round,
        routed.tracks.len - out.tracks.len,
        routed.vias.len - out.vias.len,
        frozen_nets,
        phaseMs(prune_t0),
        if (kept) "kept" else "REJECTED",
        drc.errorCount(topology_before),
        drc.errorCount(findings),
    });
    if (!kept) return .{ .result = routed, .kept = false };
    return .{ .result = out, .kept = true };
}

/// Remove route artifacts through the same connectivity-safe topology gate the
/// normal autorouter uses before persistence.  Finishing/editing tools call
/// this after their additive work so they cannot leave loose trace leaves or a
/// through-via that reaches only one copper layer behind.
pub fn pruneTopologyArtifacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    routed: router.RouteResult,
    options: route_policy.Options,
) std.mem.Allocator.Error!router.RouteResult {
    return pruneGateTopology(alloc, placement, params, routed, options);
}

/// A route must never improve its completion number by returning copper that
/// the canonical geometric DRC says cannot be fabricated. Choose a greedy
/// vertex cover over the violating MUTABLE nets (forced for one-sided rules
/// such as track↔pad), strip those nets, then ask the connectivity oracle for
/// the honest lower tally. Existing/out-of-scope copper is never a candidate.
///
/// This is intentionally a last-resort safety ratchet, not the router's normal
/// collision strategy: exact probes should prevent every finding upstream. If
/// a finishing pass or stale search index still creates one, however, an
/// airwire is safer and more truthful than illegal copper.
///
/// Its findings come from `ratchetFindings`, which reads the board through the
/// FABRICATED FILL exactly as the topology prune two lines above it does.
/// Judging it without the fill made one gate call contradict itself: the prune
/// credits a same-net pour and KEEPS a trace that ends on its rail's copper, and
/// the ratchet then called that same trace an unattached `copper_stub` — a
/// one-sided error, so a FORCED victim — and dropped every piece of that net's
/// generated copper. The board came back with the rail open, the next ladder
/// pass re-drew it, and the pass after that dropped it again. The disagreement
/// is also pour-extent sensitive, which is how a tighter default outer-pour gap
/// could turn a finished rail into a treadmill without a line of routing
/// changing.
/// Can crediting the fabricated fill CHANGE this finding? Only the
/// copper-topology family reads the fill (it is what tells a trace end, a via or
/// a fragment that same-net copper is there); every clearance, drill, width and
/// edge rule is fill-blind by construction.
fn fillSensitive(kind: drc.Kind) bool {
    return switch (kind) {
        .copper_stub,
        .implicit_junction,
        .hairline_gap,
        .dangling_copper,
        .single_layer_via,
        .redundant_via,
        .land_transit,
        .ground_via_distance,
        .bypass_open,
        => true,
        else => false,
    };
}

/// The findings the victim cover is choosing from — read through the fabricated
/// fill, but only when a fill could change the answer.
///
/// Crediting the fill costs a pour raster per net per carrying layer: measured
/// on barracuda (Debug), 3-11 s on top of a 2.5 s check, per gate pass, which
/// on a timed board is a whole ladder pass — and the ladder is the phase that
/// closes rails. So the zone-blind read comes first (it is the cheaper half of
/// the same rules), and the fill is bought only when that read produced a
/// fill-sensitive finding the cover would actually act on. Crediting copper can
/// only ever REMOVE a topology finding, so a board with none of them reads
/// identically either way, and this is an exact answer rather than a heuristic.
fn ratchetFindings(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    result: router.RouteResult,
    options: route_policy.Options,
) std.mem.Allocator.Error![]const drc.Violation {
    const blind = try drc.check(alloc, placement, result, params.clearance);
    var rejudge = false;
    for (blind) |v| {
        if ((v.severity != .err and v.kind != .implicit_junction) or v.kind == .net_open) continue;
        if (fillSensitive(v.kind)) rejudge = true;
    }
    if (!rejudge) return blind;
    routeLog("gate drc: a fill-sensitive finding — re-reading the board through its fabricated fill", .{});
    return drc_rules.checkFilled(alloc, .{
        .placement = placement,
        .routed = result,
        .clearance = params.clearance,
        .zones = try route_close.userZones(alloc, placement, options.existing_zones),
    });
}

fn drcSafeResult(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    reconciled: route_close.Reconciled,
    options: route_policy.Options,
) std.mem.Allocator.Error!route_close.Reconciled {
    const violations = try ratchetFindings(alloc, placement, params, reconciled.result, options);
    const dropped = try chooseDrcVictims(alloc, placement, reconciled.result, options, violations);
    if (!anyTrue(dropped)) return reconciled;
    for (dropped, 0..) |victim, net_i| {
        if (!victim or net_i >= placement.nets.len) continue;
        logDrcVictim(placement, options, violations, net_i);
    }

    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    var arcs: std.ArrayList(router.Arc) = .empty;
    var sharp: std.ArrayList(router.SharpBend) = .empty;
    for (reconciled.result.tracks) |t| if (!netDropped(dropped, t.net)) try tracks.append(alloc, t);
    for (reconciled.result.vias) |v| if (!netDropped(dropped, v.net)) try vias.append(alloc, v);
    for (reconciled.result.arcs) |a| if (!netDropped(dropped, a.net)) try arcs.append(alloc, a);
    for (reconciled.result.sharp_bends) |s| if (!netDropped(dropped, s.net)) try sharp.append(alloc, s);

    var result = reconciled.result;
    result.tracks = try tracks.toOwnedSlice(alloc);
    result.vias = try vias.toOwnedSlice(alloc);
    result.arcs = try arcs.toOwnedSlice(alloc);
    result.sharp_bends = try sharp.toOwnedSlice(alloc);
    const outcomes = try alloc.dupe(rf_port_report.Outcome, result.rf_port_outcomes);
    for (outcomes) |*outcome| {
        if (outcome.net < 0) continue;
        const net_i: usize = @intCast(outcome.net);
        if (net_i >= dropped.len or !dropped[net_i]) continue;
        outcome.physical.gate_removed = true;
        for (violations) |violation| {
            const candidates = candidateNets(placement, options, violation);
            for (candidates.items[0..candidates.len]) |candidate| {
                if (candidate != net_i) continue;
                outcome.physical.gate_first_error = @tagName(violation.kind);
                break;
            }
            if (outcome.physical.gate_first_error.len > 0) break;
        }
    }
    result.rf_port_outcomes = outcomes;

    const zones = try route_close.userZones(alloc, placement, options.existing_zones);
    const tally = try fab_readiness.routableTally(alloc, placement, .{
        .tracks = result.tracks,
        .arcs = result.arcs,
        .rf_paths = result.rf_port_outcomes,
        .vias = result.vias,
        .zones = zones,
    });
    result.routed = tally.routed;
    result.total = tally.total;
    result.failed = tally.open;

    return .{
        .result = result,
        .hops_tried = reconciled.hops_tried,
        .hops_kept = reconciled.hops_kept,
        .claimed_routed = reconciled.claimed_routed,
    };
}

fn anyTrue(items: []const bool) bool {
    for (items) |item| if (item) return true;
    return false;
}

fn netDropped(dropped: []const bool, net: i32) bool {
    if (net < 0) return false;
    const ni: usize = @intCast(net);
    return ni < dropped.len and dropped[ni];
}

/// Return the route-generated feature owners whose deletion can resolve `v`.
/// Pad/part-only findings deliberately have no candidate: deleting a same-net
/// track cannot repair a footprint's annular ring or pad-to-edge placement.
fn copperParties(v: drc.Violation) [2]i32 {
    return switch (v.kind) {
        .via_pad, .track_pad, .annular, .track_width, .copper_stub, .implicit_junction => .{ v.who.net_a, -1 },
        .min_drill, .board_edge => if (v.who.part_a < 0)
            .{ v.who.net_a, -1 }
        else
            .{ -1, -1 },
        .via_via, .via_spacing, .via_track, .track_track => .{ v.who.net_a, v.who.net_b },
        .hole_hole => .{
            if (v.who.part_a < 0) v.who.net_a else -1,
            if (v.who.part_b < 0) v.who.net_b else -1,
        },
        else => .{ -1, -1 },
    };
}

fn mutableNet(placement: optimizer.Placement, options: route_policy.Options, raw: i32) ?usize {
    if (raw < 0) return null;
    const ni: usize = @intCast(raw);
    if (ni >= placement.nets.len) return null;
    if (options.selected_nets.len == 0) return ni;
    if (ni >= options.selected_nets.len or !options.selected_nets[ni]) return null;
    return ni;
}

const CandidateNets = struct {
    items: [2]usize = .{ 0, 0 },
    len: usize = 0,
};

fn candidateNets(
    placement: optimizer.Placement,
    options: route_policy.Options,
    v: drc.Violation,
) CandidateNets {
    var out = CandidateNets{};
    for (copperParties(v)) |raw| {
        const ni = mutableNet(placement, options, raw) orelse continue;
        if (out.len > 0 and out.items[0] == ni) continue;
        out.items[out.len] = ni;
        out.len += 1;
    }
    return out;
}

fn netCopperCount(result: router.RouteResult, net: usize) usize {
    const ni: i32 = @intCast(net);
    var count: usize = 0;
    for (result.tracks) |t| {
        if (t.net == ni) count += 1;
    }
    for (result.vias) |v| {
        if (v.net == ni) count += 1;
    }
    return count;
}

/// How much of `net` this transaction may actually remove. Existing copper is
/// caller-owned even when it belongs to a selected net, so it counts neither
/// against the 96-element displacement budget nor as a useful blocker pick.
fn generatedNetCopperCount(
    result: router.RouteResult,
    options: route_policy.Options,
    net: usize,
) usize {
    const ni: i32 = @intCast(net);
    var count: usize = 0;
    for (result.tracks) |track| {
        if (track.net == ni and !retainedTrack(track, options.existing_tracks)) count += 1;
    }
    for (result.vias) |via| {
        if (via.net == ni and !retainedVia(via, options.existing_vias)) count += 1;
    }
    return count;
}

fn wavePriority(options: route_policy.Options, net: usize) u32 {
    return if (net < options.net.len) options.net[net].wave.priority else 0;
}

/// Tie-break a cover choice by preserving higher-priority and more substantial
/// routes. The final index tie-break makes the answer fully deterministic.
fn betterDrcVictim(
    result: router.RouteResult,
    options: route_policy.Options,
    degrees: []const usize,
    candidate: usize,
    incumbent: usize,
) bool {
    if (degrees[candidate] != degrees[incumbent]) return degrees[candidate] > degrees[incumbent];
    const cp = wavePriority(options, candidate);
    const ip = wavePriority(options, incumbent);
    if (cp != ip) return cp < ip;
    const cc = netCopperCount(result, candidate);
    const ic = netCopperCount(result, incumbent);
    if (cc != ic) return cc < ic;
    return candidate > incumbent;
}

/// Greedy vertex cover for route-caused DRC findings. One-sided violations are
/// forced; otherwise the net covering the most still-uncovered findings wins.
fn chooseDrcVictims(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    result: router.RouteResult,
    options: route_policy.Options,
    violations: []const drc.Violation,
) std.mem.Allocator.Error![]const bool {
    const dropped = try alloc.alloc(bool, placement.nets.len);
    @memset(dropped, false);
    const degree = try alloc.alloc(usize, placement.nets.len);

    while (true) {
        @memset(degree, 0);
        var forced: ?usize = null;
        for (violations) |v| {
            // An implicit junction is fabrication-safe (and therefore a DRC
            // warning on saved/imported copper), but generated routing is not
            // allowed to rely on one. Canonicalization above should remove it;
            // this route-only fatal gate is the last-resort invariant.
            if ((v.severity != .err and v.kind != .implicit_junction) or v.kind == .net_open) continue;
            const candidates = candidateNets(placement, options, v);
            var active: [2]usize = undefined;
            var active_len: usize = 0;
            var covered = false;
            for (candidates.items[0..candidates.len]) |ni| {
                if (dropped[ni]) {
                    covered = true;
                    break;
                }
                active[active_len] = ni;
                active_len += 1;
            }
            if (covered or active_len == 0) continue;
            if (active_len == 1) {
                forced = active[0];
                break;
            }
            for (active[0..active_len]) |ni| degree[ni] += 1;
        }
        if (forced) |ni| {
            dropped[ni] = true;
            continue;
        }

        var best: ?usize = null;
        for (degree, 0..) |n, ni| {
            if (n == 0 or dropped[ni]) continue;
            if (best == null or betterDrcVictim(result, options, degree, ni, best.?)) best = ni;
        }
        const victim = best orelse break;
        dropped[victim] = true;
    }
    return dropped;
}

/// The first finding that named `net_i` as a droppable party — the reason this
/// net's copper is about to be removed. Reads exactly the rows
/// `chooseDrcVictims` covers, so the log and the cover can never name different
/// findings. Reporting only.
fn victimCause(
    placement: optimizer.Placement,
    options: route_policy.Options,
    violations: []const drc.Violation,
    net_i: usize,
) ?drc.Violation {
    for (violations) |v| {
        if ((v.severity != .err and v.kind != .implicit_junction) or v.kind == .net_open) continue;
        const candidates = candidateNets(placement, options, v);
        for (candidates.items[0..candidates.len]) |ni| if (ni == net_i) return v;
    }
    return null;
}

/// The OTHER side of a victim's cause, as a name a reader can act on: the
/// foreign net, else the part, else `—` for a one-sided rule (a stub, a width,
/// an annular ring) whose second party does not exist.
fn victimOther(placement: optimizer.Placement, net_i: usize, v: drc.Violation) []const u8 {
    for ([_]i32{ v.who.net_a, v.who.net_b }) |raw| {
        if (raw < 0) continue;
        const ni: usize = @intCast(raw);
        if (ni == net_i or ni >= placement.nets.len) continue;
        return placement.nets[ni].name;
    }
    for ([_]i32{ v.who.part_a, v.who.part_b }) |raw| {
        if (raw < 0) continue;
        const pi: usize = @intCast(raw);
        if (pi < placement.parts.len) return placement.parts[pi].ref_des;
    }
    return "—";
}

/// Name the victim AND the finding that cost it its copper. A bare "its
/// generated copper is dropped" cannot distinguish a real clearance clash from
/// the gate disagreeing with its own acceptance probe, which is exactly the
/// distinction a treadmill (accept, drop, re-accept) turns on.
fn logDrcVictim(
    placement: optimizer.Placement,
    options: route_policy.Options,
    violations: []const drc.Violation,
    net_i: usize,
) void {
    const name = placement.nets[net_i].name;
    const cause = victimCause(placement, options, violations, net_i) orelse {
        routeLog("gate drc victim: {s} — its generated copper is dropped (no finding names it)", .{name});
        return;
    };
    routeLog("gate drc victim: {s} — its generated copper is dropped ({s} vs {s}, gap {d:.3}mm < {d:.3}mm at {d:.2},{d:.2})", .{
        name,
        @tagName(cause.kind),
        victimOther(placement, net_i, cause),
        cause.gap,
        cause.clearance,
        cause.x,
        cause.y,
    });
}

/// Resolve an ad-hoc incremental-routing scope (a set of group tokens and/or
/// explicit net names) against `block` + `placement`. Builds the same
/// `module_policy` + authored-net-class `Context` the plan resolver uses, so
/// "route the RF group" here selects the identical nets a
/// `(route (wave … (net-classes "RF")))` wave would. Shared by the `route_pcb`
/// CLI commit path and the viewer's Route button. Returns a whole-board sentinel
/// (`selectors == 0`) when the scope names nothing.
pub fn resolveScope(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    scope: plan_resolve.NetScope,
) std.mem.Allocator.Error!plan_resolve.ResolvedScope {
    var detected = try module_policy.analyze(alloc, placement);
    defer detected.deinit(alloc);
    return plan_resolve.resolveNetScope(alloc, scope, .{
        .placement = placement,
        .net_class = detected.net_class,
        .part_role = detected.part_role,
        .modules = detected.modules,
        .net_class_specs = block.net_classes,
    });
}

/// Expand an incremental routing mask so selecting either member of a
/// differential pair selects both. Returns the number of partner nets added.
pub fn includeDiffPartners(placement: optimizer.Placement, selected: []bool) usize {
    var added: usize = 0;
    for (placement.diff_pairs) |pair| {
        if (pair.p >= selected.len or pair.n >= selected.len) continue;
        if (!selected[pair.p] and !selected[pair.n]) continue;
        if (!selected[pair.p]) added += 1;
        if (!selected[pair.n]) added += 1;
        selected[pair.p] = true;
        selected[pair.n] = true;
    }
    return added;
}

/// A planned route plus the stuck-net diagnostics captured over its LIVE grid.
pub const PlannedDiagnostic = struct {
    result: router.RouteResult,
    stuck: []const route_diagnose.Diagnosis = &.{},
    /// How many nets the ROUTER claimed it routed, before the oracle gate
    /// corrected the count. Above `result.routed` it means the router counted a
    /// net complete whose pads its copper does not join — a router defect worth
    /// seeing rather than silently repairing.
    claimed_routed: usize = 0,
};

/// Inputs for an incremental *scoped* route: the `selected` enable mask (only
/// these nets route) plus the caller's retained copper for every OTHER net,
/// stamped as a hard obstacle and echoed into the result unchanged. All-empty
/// fields make this a whole-board route (every net routes, nothing retained).
pub const ScopedRoute = struct {
    selected: []const bool = &.{},
    existing_tracks: []const route_policy.ExistingTrack = &.{},
    existing_vias: []const route_policy.ExistingVia = &.{},
    /// Retained copper zones — hand-drawn user pours (source copper the maze
    /// grows a same-net route from) and keepouts (hard obstacles). Empty leaves
    /// routing unchanged.
    existing_zones: []const route_policy.ExistingZone = &.{},
};

/// Route `placement` fresh with the block's authored plan (like `routePlanned`),
/// but hold the live router state through the finish pass so the stuck-net
/// diagnostics can flood/classify the SAME grid the copper landed on —
/// `routePlanned` returns only the compact `RouteResult` and drops that state.
/// Callers with retained copper use `routePlannedScoped` and supply it through
/// `ScopedRoute`; this convenience spelling is the copper-free whole-board
/// case. Skips the fine-grid retry `routeWithOptions` layers on top; the
/// diagnostic needs one live core, and the retry only ever ADDS routed nets, so
/// the stuck set it would diagnose is a superset (never a mismatch) of the
/// committed one.
pub fn routePlannedDiagnostic(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
) std.mem.Allocator.Error!PlannedDiagnostic {
    return routePlannedScopedImpl(alloc, block, placement, params, .{});
}

/// `routePlannedDiagnostic`, scoped: only `scoped.selected` nets route, with
/// `scoped.existing_*` copper preserved as an obstacle and carried into the
/// result unchanged — a true incremental re-route of one net group. An all-empty
/// `scoped` is byte-identical to the whole-board `routePlannedDiagnostic`. The
/// viewer's Route button drives this when a scope is chosen; the authored
/// `(pcb-plan)` layer/priority policy still lowers underneath the scope.
pub fn routePlannedScoped(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    scoped: ScopedRoute,
) std.mem.Allocator.Error!PlannedDiagnostic {
    if (scoped.selected.len == 0 and
        scoped.existing_tracks.len == 0 and
        scoped.existing_vias.len == 0 and
        scoped.existing_zones.len == 0)
    {
        return routePlannedDiagnostic(alloc, block, placement, params);
    }
    return routePlannedScopedImpl(alloc, block, placement, params, scoped);
}

fn routePlannedScopedImpl(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    scoped: ScopedRoute,
) std.mem.Allocator.Error!PlannedDiagnostic {
    const pr = try routePlannedScopedLive(alloc, block, placement, params, scoped, .{});
    return .{ .result = pr.run.routed, .stuck = pr.stuck, .claimed_routed = pr.claimed_routed };
}

/// Streaming knobs for a live (background) route: the progress sink fired per
/// captured timeline event, the cooperative cancel flag, and whether the
/// timeline is captured at all. The all-default value is exactly the blocking
/// path — no timeline, no sink, never cancelled — which is what lets
/// `routePlannedScoped` delegate to the live variant without drifting.
pub const LiveRoute = struct {
    sink: ?route_policy.ProgressSink = null,
    cancel: ?*std.atomic.Value(bool) = null,
    timeline: router.TimelineCapture = .off,
};

/// A planned scoped route that keeps the router's full `RouteRun` (copper AND
/// captured timeline) alongside the stuck-net diagnostics from the same live
/// grid — what the background live-route job persists as the cached replay.
pub const PlannedRun = struct {
    run: router.RouteRun,
    stuck: []const route_diagnose.Diagnosis = &.{},
    /// The router's own pre-gate routed count (see `PlannedDiagnostic`).
    claimed_routed: usize = 0,
};

/// The scoped router options every planned scoped route uses: the block's
/// authored plan lowered first, then the caller's scope merged on top — one
/// merge site so the blocking and live paths cannot diverge.
fn scopedOptions(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    scoped: ScopedRoute,
) route_policy.Options {
    var options = lowerOrEmpty(alloc, block, placement);
    options.selected_nets = scoped.selected;
    options.existing_tracks = scoped.existing_tracks;
    options.existing_vias = scoped.existing_vias;
    options.existing_zones = scoped.existing_zones;
    return options;
}

/// `routePlannedScoped` with live-streaming hooks: `live.sink`/`live.cancel`
/// merge INTO the plan-lowered scoped options (never clobbering them), and
/// `live.timeline = .on` keeps the captured decision timeline in the returned
/// run. Like `routePlannedScoped` it routes through one live core (no
/// finer-grid retry) so the stuck diagnostics describe the SAME grid the
/// copper landed on; a `.{}` value is byte-identical to `routePlannedScoped`.
pub fn routePlannedScopedLive(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    scoped: ScopedRoute,
    live: LiveRoute,
) std.mem.Allocator.Error!PlannedRun {
    var options = scopedOptions(alloc, block, placement, scoped);
    return routeLoweredLive(alloc, placement, params, &options, live);
}

/// Live/diagnostic route with options the caller already lowered. Hierarchical
/// seed preparation uses this spelling because it adjusts both retained copper
/// and per-net via budgets before the background route starts.
pub fn routeLoweredLive(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: *route_policy.Options,
    live: LiveRoute,
) std.mem.Allocator.Error!PlannedRun {
    options.sink = live.sink;
    options.stop.cancel = live.cancel;
    armDeadline(options);
    const fin = try router.routeCoreFinishedRun(
        alloc,
        placement,
        params,
        try initialPassOptions(alloc, options.*),
        live.timeline,
    );
    // A cancelled run skips the stuck-net diagnosis entirely: remedy search
    // over dozens of unreached nets is minutes of work, and a user who pressed
    // Stop wants the partial result NOW — the unreached nets are simply
    // unrouted, not failures worth explaining. Gated on the result's cancelled
    // flag (not on live-vs-blocking), so any cancellable caller benefits.
    if (fin.run.routed.cancelled) {
        var run = fin.run;
        run.routed = try route_copper_state.reconcile(alloc, placement, run.routed, try retainedZones(alloc, placement, options.*));
        return .{ .run = run };
    }
    // Diagnose against the copper the router itself produced (the live grid the
    // core still holds describes THAT board), then report the gated counters —
    // so the stuck list explains the router's failures while `routed`/`failed`
    // stay the oracle's answer.
    const stuck: []const route_diagnose.Diagnosis = if (fin.core) |core|
        try route_diagnose.capture(&core, fin.run.routed, placement, alloc)
    else
        &.{};
    var run = fin.run;
    const gated = try gate(alloc, placement, params, fin.run.routed, options.*);
    run.routed = try finishLoweredCandidate(alloc, placement, params, options.*, gated.result);
    return .{
        .run = run,
        .stuck = try stillFailedDiagnoses(alloc, stuck, run.routed.failed),
        .claimed_routed = gated.claimed_routed,
    };
}

/// A request-local experiment route: the routed result plus its stuck-net
/// diagnostics (like `routePlannedDiagnostic`), the plan-resolution warnings,
/// and whether a plan applied — so `route_experiment` can echo the unresolved
/// wave/class/net names rather than only counting them.
pub const Experiment = struct {
    seeds: pcb_layout_page.SubcircuitRouteSeedStats = .{},
    result: router.RouteResult,
    stuck: []const route_diagnose.Diagnosis = &.{},
    warnings: []const plan_resolve.Warning = &.{},
    plan_applied: bool = false,
    /// The retry tier this run actually used — the caller's override when it
    /// supplied one, else the plan's authored `(effort …)`. Echoed so a recorded
    /// trial names the tier it was measured at.
    effort: route_policy.Effort = .standard,
    /// What the global topology planner did on this run, or null when it never
    /// ran (no `(topology)` authored and no `topology` override).
    topology: ?topo_lower.Stats = null,
};

/// Caller overrides for one `routeExperiment` run. All-default is exactly "route
/// the block's authored plan on bare copper", which is what the seam did before
/// the struct existed.
pub const ExperimentOpts = struct {
    /// Library root enables the same local module routing as the commit path.
    project_dir: ?[]const u8 = null,
    /// A complete `(pcb-plan …)` spec that REPLACES the block's authored plan
    /// for this run only. Null routes the authored plan.
    plan: ?env_mod.PcbPlanSpec = null,
    /// Retry-tier override. Null keeps the plan's authored `(effort …)`, so a
    /// caller that does not ask measures exactly what the design declares.
    effort: ?route_policy.Effort = null,
    /// The shown layout's hand-drawn pours as router source copper. A pour is
    /// CONNECTING copper (see `fab_readiness.netConnectivity`), so a run without
    /// them re-traces poured rails and its gate reports them open — which is a
    /// different board from the one `route_pcb` commits and `/api/pcb-describe`
    /// reports. Empty is the legacy bare-copper behaviour.
    zones: []const route_policy.ExistingZone = &.{},
    /// Force-topology flag: hand EVERY resolved route wave to the global
    /// topology planner. It flags whatever plan resolves for this run — the
    /// override when one is given, else the block's authored plan. With neither
    /// there are no resolved route waves to flag and it does nothing, which
    /// keeps the "no plan ⇒ empty options" guarantee below intact.
    topology: bool = false,
};

/// Route `placement` fresh through this ONE lowering seam, but lower
/// `opts.plan` (a caller-supplied `(pcb-plan …)` spec) INSTEAD of the block's
/// authored plan when it is non-null — the safe "try a DSL change" path for
/// `route_experiment`. With no override and no authored plan it routes with
/// empty options (no default synthesis), exactly as `routePlannedDiagnostic`
/// does, so the numbers match a plain `?route=1` describe. Purely request-local:
/// no persistence. With a library root it uses the commit path's hierarchical
/// builder, then inspects the final fenced copper after finishing all routing.
pub fn routeExperiment(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    opts: ExperimentOpts,
) std.mem.Allocator.Error!Experiment {
    const spec = opts.plan orelse block.pcb_plan;
    var options: route_policy.Options = .{};
    var warnings: []const plan_resolve.Warning = &.{};
    var topology: ?topo_lower.Stats = null;
    if (spec) |s| {
        const r = try resolveOptions(alloc, .{
            .spec = s,
            .block = block,
            .placement = placement,
            .force_topology = opts.topology,
            .zones = try retainedZones(alloc, placement, .{ .existing_zones = opts.zones }),
        });
        options = r.options;
        warnings = r.warnings;
        topology = r.topology;
    }
    if (opts.effort) |e| options.effort = e;
    options.existing_zones = opts.zones;
    var seeds: pcb_layout_page.SubcircuitRouteSeedStats = .{};
    const fresh = if (opts.project_dir) |project_dir| blk: {
        const seeded = try pcb_layout_page.routeWithSubcircuitSeeds(alloc, project_dir, block, placement, params, options);
        seeds = seeded.seeds;
        break :blk seeded.result;
    } else try routeLowered(alloc, placement, params, options);
    const fenced = (try route_copper_state.appendPerimeter(alloc, placement, fresh)).?;
    const measured = try route_copper_state.reconcile(alloc, placement, fenced, try retainedZones(alloc, placement, options));
    const pd = try diagnoseFinished(alloc, placement, params, options, measured);
    return .{
        .seeds = seeds,
        .result = pd.result,
        .stuck = pd.stuck,
        .warnings = warnings,
        .plan_applied = spec != null,
        .effort = options.effort,
        .topology = topology,
    };
}

/// Route through the ordinary candidate builder, then diagnose the final copper.
/// Diagnostic work cannot spend the routing deadline or change route geometry.
pub fn routeLoweredDiagnostic(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
) std.mem.Allocator.Error!PlannedDiagnostic {
    const result = try routeLowered(alloc, placement, params, options);
    return diagnoseFinished(alloc, placement, params, options, result);
}

/// Build a probe over the final copper only after all routing/finishing. This
/// work cannot consume the routing deadline or describe an earlier candidate.
fn diagnoseFinished(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    result: router.RouteResult,
) std.mem.Allocator.Error!PlannedDiagnostic {
    if (result.cancelled or result.failed.len == 0) return .{ .result = result };
    var probe = options;
    probe.stop = .{};
    probe.timing = null;
    probe.sink = null;
    const none = try alloc.alloc(bool, placement.nets.len);
    @memset(none, false);
    probe.selected_nets = none;
    const tracks = try alloc.alloc(route_policy.ExistingTrack, result.tracks.len);
    for (result.tracks, tracks) |t, *out| out.* = trackAsExisting(t);
    const vias = try alloc.alloc(route_policy.ExistingVia, result.vias.len);
    for (result.vias, vias) |v, *out| out.* = viaAsExisting(v);
    probe.existing_tracks = tracks;
    probe.existing_vias = vias;
    const outcome = try router.routeCoreStart(alloc, placement, params, probe, .off);
    const stuck = switch (outcome) {
        .core => |core| try route_diagnose.capture(&core, result, placement, alloc),
        .done => &.{},
    };
    return .{ .result = result, .stuck = stuck };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");

/// A minimal routable two-pad placement (mirrors the router's own fixture):
/// one net between two 0.4 mm pads 3 mm apart on the legacy 2-layer rules.
fn fixturePlacement(
    parts: []optimizer.Part,
    nets: []const optimizer.FlatNet,
) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
}

/// A design block carrying only what plan lowering reads (`pcb_plan` +
/// `net_classes`); everything else stays empty.
fn fixtureBlock(plan: ?env_mod.PcbPlanSpec) env_mod.DesignBlock {
    return .{
        .name = "fixture",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .pcb_plan = plan,
    };
}

const route_plan_fixture_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn twoPadParts() [2]optimizer.Part {
    return .{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 0 },
    };
}

const fixture_pins = [_]export_kicad.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
};

/// Total track length routed on signal layer `layer`.
fn trackMmOnLayer(tracks: []const router.Track, layer: u8) f64 {
    var mm: f64 = 0;
    for (tracks) |t| {
        if (t.layer == layer) mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return mm;
}

fn totalTrackMm(tracks: []const router.Track) f64 {
    var mm: f64 = 0;
    for (tracks) |t| mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    return mm;
}

// spec: serve/route-plan - a design with no authored plan lowers to empty options
test "no authored plan lowers to empty options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const block = fixtureBlock(null);
    const lowered = try lower(arena, &block, fixturePlacement(&parts, &nets));
    try testing.expect(!lowered.applied);
    try testing.expectEqual(@as(usize, 0), lowered.options.net.len);
    try testing.expectEqual(@as(usize, 0), lowered.warnings);
}

// spec: serve/route-plan - lowering turns authored route waves into per-net wave priority and layer masks
test "authored rest wave lowers to a per-net policy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const waves = [_]env_mod.PlanWave{.{
        .name = "outer-only",
        .rest = true,
        .allowed_layers = &.{ "F.Cu", "B.Cu" },
        .preferred_layers = &.{"F.Cu"},
    }};
    const block = fixtureBlock(.{ .route = &waves });
    const lowered = try lower(arena, &block, fixturePlacement(&parts, &nets));
    try testing.expect(lowered.applied);
    try testing.expectEqual(@as(usize, 1), lowered.options.net.len);
    try testing.expectEqual(@as(u32, 1), lowered.options.net[0].wave.priority);
    try testing.expectEqual(@as(u64, 0b11), lowered.options.net[0].allowed_layers);
    try testing.expectEqual(@as(u64, 0b01), lowered.options.net[0].preferred_layers);
}

// spec: serve/route-plan - a preview route through the shared seam honors the authored allowed-layers restriction
test "preview routing through the seam keeps copper off disallowed layers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // Prefer the bottom (which alone would drop vias and route B.Cu — see the
    // router's own fixture test) but forbid it: only F.Cu is allowed.
    const waves = [_]env_mod.PlanWave{.{
        .name = "outer-only",
        .rest = true,
        .allowed_layers = &.{"F.Cu"},
        .preferred_layers = &.{"B.Cu"},
    }};
    const block = fixtureBlock(.{ .route = &waves });
    const routed = try routePlanned(arena, &block, placement, .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expectEqual(@as(f64, 0), trackMmOnLayer(routed.tracks, 1));
    try testing.expectEqual(@as(usize, 0), routed.vias.len);
    try testing.expect(trackMmOnLayer(routed.tracks, 0) > 2.0);
}

// spec: serve/route-plan - the standard-effort gate attempts bounded additive joins on router-failed nets before deciding whether the residual rescue ladder is needed
test "standard gate closes a short router-failed join before residual rescue" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const failed = [_][]const u8{"SIG"};
    const raw = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 1,
        .failed = &failed,
    };

    const finished = (try gate(arena, placement, .{}, raw, .{ .effort = .standard })).result;
    try testing.expectEqual(@as(usize, 1), finished.routed);
    try testing.expectEqual(@as(usize, 0), finished.failed.len);
    try testing.expect(finished.tracks.len > 0);
}

// spec: serve/route-plan - standard effort gives its non-ripping connectivity gate a larger deterministic distance and hop budget than interactive one-shot routing
test "standard gate admits a bounded join beyond the one-shot ceiling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    parts[1].x = 6;
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    var placement = fixturePlacement(&parts, &nets);
    placement.maxx = 6.5;
    const failed = [_][]const u8{"SIG"};
    const raw = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 1,
        .failed = &failed,
    };

    const quick = (try gate(arena, placement, .{}, raw, .{ .effort = .one_shot })).result;
    try testing.expectEqual(@as(usize, 0), quick.routed);
    const unattended = (try gate(arena, placement, .{}, raw, .{ .effort = .standard })).result;
    try testing.expectEqual(@as(usize, 1), unattended.routed);
}

// spec: serve/route-plan - a scoped gate's hop ceiling reaches its own target's join and no further, while a broad gate of either effort keeps exactly the ceiling it was tuned on
test "a scoped gate's ceiling covers its target's join, bounded" {
    const one_shot = route_policy.Options{ .effort = .one_shot };
    const standard = route_policy.Options{ .effort = .standard };
    // A broad gate is untouched by the target field, at either effort.
    try testing.expectApproxEqAbs(route_close.default_max_hop_mm, gateHopCeiling(one_shot, .{}), 1e-12);
    try testing.expectApproxEqAbs(standard_gate_max_hop_mm, gateHopCeiling(standard, .{}), 1e-12);
    try testing.expectApproxEqAbs(
        route_close.default_max_hop_mm,
        gateHopCeiling(one_shot, .{ .target_hop_mm = 55.3 }),
        1e-12,
    );
    // A scoped gate that names no target keeps the unattended ceiling exactly,
    // so every caller predating the field is unchanged.
    const scoped = GateConfig{ .scoped_target = true };
    try testing.expectApproxEqAbs(standard_gate_max_hop_mm, gateHopCeiling(one_shot, scoped), 1e-12);
    // Barracuda's three cross-board control targets. The first two already fit
    // the unattended ceiling; LOCK_DET at 55.3 mm did not, so its hop was
    // dropped before the maze or the shape tier was ever asked about it.
    for ([_]f64{ 42.5, 49.6 }) |fits| {
        try testing.expectApproxEqAbs(
            standard_gate_max_hop_mm,
            gateHopCeiling(one_shot, .{ .scoped_target = true, .target_hop_mm = fits }),
            1e-12,
        );
    }
    try testing.expectApproxEqAbs(
        @as(f64, 55.3),
        gateHopCeiling(one_shot, .{ .scoped_target = true, .target_hop_mm = 55.3 }),
        1e-12,
    );
    // And it stops: a hop longer than the board is not a join to reach for.
    try testing.expectApproxEqAbs(
        scoped_gate_max_hop_mm,
        gateHopCeiling(one_shot, .{ .scoped_target = true, .target_hop_mm = 500 }),
        1e-12,
    );
}

// spec: serve/route-plan - a scoped transaction's gate plans its target's own long join at the unattended hop ceiling while a broad one-shot gate keeps the short one
test "a scoped transaction's gate reaches its target's long join" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    parts[1].x = 6; // one join, past the one-shot ceiling
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    var placement = fixturePlacement(&parts, &nets);
    placement.maxx = 6.5;
    const failed = [_][]const u8{"SIG"};
    const raw = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 1,
        .failed = &failed,
    };
    // A scoped transaction routes at `one_shot` by construction, and under the
    // broad ceiling that meant `route_close.planHops` dropped the target's net
    // before a hop was planned — so the join the transaction was formed to make
    // was never attempted, by the maze or by the shape router behind it.
    const broad = (try gate(arena, placement, .{}, raw, .{ .effort = .one_shot })).result;
    try testing.expectEqual(@as(usize, 0), broad.routed);
    const scoped = (try gateConfigured(arena, placement, .{}, raw, .{ .effort = .one_shot }, .{
        .scoped_target = true,
    })).result;
    try testing.expectEqual(@as(usize, 1), scoped.routed);
    try testing.expect(scoped.tracks.len > 0);
    // The ceiling is the only thing the flag moves: a standard-effort gate is
    // unchanged by it, so the broad passes keep the budget they were tuned on.
    const unscoped_std = (try gate(arena, placement, .{}, raw, .{ .effort = .standard })).result;
    const scoped_std = (try gateConfigured(arena, placement, .{}, raw, .{ .effort = .standard }, .{
        .scoped_target = true,
    })).result;
    try testing.expectEqual(unscoped_std.routed, scoped_std.routed);
    try testing.expectEqual(unscoped_std.tracks.len, scoped_std.tracks.len);
}

// spec: serve/route-plan - a scoped transaction's gate stops at reconciliation when a net the transaction named is still open, before the canonicalization and DRC ratchet its rolled-back candidate would never keep
test "a doomed scoped candidate is refused before the rest of the chain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `SIG` is closed by copper carrying a prunable stub; `FAR` is two pads
    // 12 mm apart with no copper at all, which is past the broad gate's own hop
    // ceiling — so reconciliation plans no join for it and it stays open.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 3 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 12, .y = 3 },
    };
    const far_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "R3", .pin = "1" },
        .{ .ref_des = "R4", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SIG", .pins = &fixture_pins },
        .{ .name = "FAR", .pins = &far_pins },
    };
    var placement = fixturePlacement(&parts, &nets);
    placement.maxx = 12.5;
    placement.maxy = 3.5;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = 0, .x2 = 1.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
    };
    const raw = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 2 };
    const selected = [_]bool{ true, true };
    const options = route_policy.Options{ .selected_nets = &selected, .effort = .one_shot };

    // Naming the still-open net stops the gate at reconciliation.
    const doomed = (try gateConfigured(arena, placement, .{}, raw, options, .{
        .must_close = &.{"FAR"},
    })).result;
    try testing.expectEqual(@as(usize, 2), doomed.tracks.len);
    // The verdict itself is unchanged — the caller's commit rule reads the same
    // open list and refuses this candidate either way.
    try testing.expect(!target_unblock.transactionClosed(doomed.failed, &.{"FAR"}));

    // A transaction whose names all came back pays the full chain. NO gate
    // prunes any more (see the placement test above), so what the full chain
    // costs this board is canonicalization and the DRC ratchet, and the stub
    // survives every one of them — it is the finish's single prune that takes
    // it off.
    const kept = (try gateConfigured(arena, placement, .{}, raw, options, .{
        .must_close = &.{"SIG"},
    })).result;
    try testing.expectEqual(@as(usize, 2), kept.tracks.len);
    // Naming nothing is the broad callers' configuration, and it is byte-for-byte
    // that same full chain.
    const broad = (try gateConfigured(arena, placement, .{}, raw, options, .{})).result;
    try testing.expectEqual(kept.tracks.len, broad.tracks.len);
    // The stub IS prunable — the prune just no longer lives in a gate pass.
    const pruned = try pruneGateTopology(arena, placement, .{}, raw, options);
    try testing.expectEqual(@as(usize, 1), pruned.tracks.len);
}

// spec: serve/route-plan - a timed standard lattice route starts with one whole-board one-shot pass and spends the shared remainder only on additive oracle-open-net retries
test "timed standard lattice routing starts with the one-shot pass" {
    const timed = try initialPassOptions(testing.allocator, .{
        .effort = .standard,
        .stop = .{ .max_route_ms = 270_000 },
    });
    try testing.expectEqual(route_policy.Effort.one_shot, timed.effort);

    const untimed = try initialPassOptions(testing.allocator, .{ .effort = .standard });
    try testing.expectEqual(route_policy.Effort.standard, untimed.effort);

    const field = try initialPassOptions(testing.allocator, .{
        .effort = .standard,
        .stop = .{ .max_route_ms = 270_000 },
        .guides = .{ .route_space = .{ .field = .{ .scratch = testing.allocator } } },
    });
    try testing.expectEqual(route_policy.Effort.standard, field.effort);
}

// spec: placement/route-deadline - topology planning consumes the same route deadline as detailed routing rather than starting an untimed pre-pass
test "topology planning and detailed routing share one armed deadline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const waves = [_]env_mod.PlanWave{.{
        .name = "planned",
        .rest = true,
        .corridor = .{ .topology = true },
    }};
    const block = fixtureBlock(.{ .route = &waves, .max_route_seconds = 1 });
    const lowered = try lower(arena, &block, fixturePlacement(&parts, &nets));
    try testing.expect(lowered.topology != null);
    try testing.expectEqual(@as(u64, 1000), lowered.options.stop.max_route_ms);
    try testing.expect(lowered.options.stop.deadline_ns != 0);
}

// spec: serve/route-plan - deferred repair selection uses only authored repair-waypoints, never ordinary waypoints, reference branches, or scoped/retained copper
test "deferred repair selection uses only fresh whole-board repair corridors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "WAYPOINT", .pins = &fixture_pins },
        .{ .name = "PLAIN", .pins = &.{} },
    };
    const placement = fixturePlacement(&parts, &nets);
    const points = [_]route_policy.Waypoint{.{ .x = 1, .y = 0, .layer = 0 }};
    const policies = [_]route_policy.NetPolicy{
        .{ .wave = .{ .seed_first = true, .repair_waypoints = &points } },
        .{ .branches = &.{.{ .waypoints = &points }} },
    };
    const selected = (try waypointSeedMask(arena, placement, .{
        .net = &policies,
    })).?;
    try testing.expectEqualSlices(bool, &.{ true, false }, selected);

    try testing.expect((try waypointSeedMask(arena, placement, .{
        .net = &policies,
        .selected_nets = &.{ true, false },
    })) == null);
}

// spec: serve/route-plan - every repeated tail gate pass is full-gated, so copper a pass closes is never victim-dropped wholesale at a phase boundary
test "repeated tail gates close an open net fully gated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const failed_names = [_][]const u8{"SIG"};
    const first = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 1,
        .failed = &failed_names,
    };
    var memo = route_close.HopMemo.init(arena);
    defer memo.deinit();
    const out = try repeatLatticeGate(arena, placement, .{}, .{}, first, &memo);
    try testing.expect(!out.cancelled);
    try testing.expectEqual(@as(usize, 1), out.routed);
    try testing.expectEqual(@as(usize, 0), out.failed.len);
    try testing.expect(out.tracks.len > 0);
}

// spec: serve/route-plan - a pour-carried net may be a per-gap unblock target though never a whole-net one, and a plane- or pour-carried ground net may be one too, while unbacked ground, diff-pair, RF and fenced nets are excluded from both
test "a poured rail is eligible for a per-gap transaction but not a whole-net one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "V_3V3A", .pins = &fixture_pins },
        .{ .name = "GND", .pins = &fixture_pins },
    };
    const placement = fixturePlacement(&parts, &nets);
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 5, -1 }, .{ 5, 1 }, .{ -1, 1 } };
    const zones = [_]route_policy.ExistingZone{
        .{ .polygon = &poly, .layer = 0, .net = 0, .copper = true },
        .{ .polygon = &poly, .layer = 1, .net = 1, .copper = true },
    };
    const options = route_policy.Options{ .existing_zones = &zones };
    _ = arena;

    // The rail's own zone carries it, so a wholesale rewrite is refused...
    try testing.expect(!fieldClusterSeedEligible(placement, options, 0));
    // ...while a per-gap join, which never touches its copper, is allowed.
    try testing.expect(unblockGapEligible(placement, options, 0));
    // GROUND a pour carries is a per-gap target on exactly those terms — the
    // transaction frees one channel and draws one join, and the pour still
    // underwrites every pad it is not aiming at. A wholesale rewrite of it stays
    // refused, as it is for any carried net.
    try testing.expect(unblockGapEligible(placement, options, 1));
    try testing.expect(!fieldClusterSeedEligible(placement, options, 1));
    // Ground with NO plane or pour behind it stays refused everywhere: then its
    // tracks are its connectivity, which is the line the blocker side draws too.
    // A DECLARED plane-less stackup is what that board looks like — under the
    // legacy implicit model every ground net is plane-carried by construction.
    var flat = fixturePlacement(&parts, &nets);
    flat.rules.plane_nets = &.{};
    const bare = route_policy.Options{};
    try testing.expect(!unblockGapEligible(flat, bare, 1));
    try testing.expect(!fieldClusterSeedEligible(flat, bare, 1));
    // ...and an ordinary signal net is unaffected by any of it.
    try testing.expect(unblockGapEligible(flat, bare, 0));
}

// spec: serve/route-plan - affordability decides only how many per-gap targets the tail can pay for, priced at the floor slice every admitted target is owed its first question in rather than at the wide retry it may never run, and the cheapest-first order decides which; a clock-free board admits none
test "the tail's affordability sets a count, not which targets fill it" {
    const now: i128 = 0;
    const lim = target_unblock_limits;
    // A clock-free board admits no per-gap target at all, which is what keeps
    // every bench and corpus route byte-identical.
    try testing.expectEqual(@as(usize, 0), affordableGapCount(5, 0, now, 0, lim));
    // 15 s of spendable tail past the reserve, priced at the floor slice every
    // admitted target is owed its first question in: five fit, a sixth does not.
    const tail = 15 * clock.ns_per_s + lim.slice.reserve_ns;
    try testing.expectEqual(@as(usize, 5), affordableGapCount(9, 0, now, tail, lim));
    // Whole-net targets already found are counted against the same tail: three
    // of them leave room for two more.
    try testing.expectEqual(@as(usize, 2), affordableGapCount(9, 3, now, tail, lim));
    try testing.expectEqual(@as(usize, 0), affordableGapCount(9, 5, now, tail, lim));
    // It never admits more than it was offered.
    try testing.expectEqual(@as(usize, 1), affordableGapCount(1, 0, now, tail, lim));
    try testing.expectEqual(@as(usize, 0), affordableGapCount(0, 0, now, tail, lim));
    // The door is priced at the BREADTH probe, not at the wide ladder: a tail
    // that could seat nobody's wide retry still buys every target the one
    // question the breadth round exists to ask it.
    try testing.expect(!wideUnblockAffordable(now, tail, 5));
    try testing.expect(unblockAdmissible(now, tail, 5, lim));
    // Inside the additive close's reserve nothing is admitted at all.
    try testing.expect(!unblockAdmissible(now, lim.slice.reserve_ns, 1, lim));

    // The ORDER decides which of them: barracuda's `GND` is named fifth by the
    // oracle and carries the board's cheapest hop, and testing candidates where
    // they arrive turned it away while 42-55 mm joins were kept.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const candidates = [_]target_unblock.Target{
        .{ .net_i = 8, .gap_mm = 6.42, .kind = .one_gap },
        .{ .net_i = 28, .gap_mm = 7.36, .kind = .one_gap },
        .{ .net_i = 18, .gap_mm = 1.00, .kind = .one_gap },
    };
    const ordered = try target_unblock.order(arena_state.allocator(), &candidates, .{});
    try testing.expectEqual(@as(usize, 18), ordered[0].net_i);
    try testing.expectApproxEqAbs(@as(f64, 1.00), ordered[0].gap_mm, 1e-12);
}

// spec: serve/route-plan - an unblock ladder takes another rung only while the remainder still covers a floor slice for every net behind it that has not yet had its first attempt, so re-entry can never spend a planned target's only turn
test "an unblock ladder yields once the targets behind it are owed their first try" {
    // barracuda's tail: the rail's per-gap target, then the two whole-net joins
    // that are the board's only single-gap open nets.
    const targets = [_]target_unblock.Target{
        .{ .net_i = 3, .gap_mm = 1.00, .kind = .one_gap },
        .{ .net_i = 9, .gap_mm = 42.54, .kind = .whole_net },
        .{ .net_i = 11, .gap_mm = 55.27, .kind = .whole_net },
    };
    var attempted = [_]bool{ false, false, false, false, false, false, false, false, false, false, false, false };
    var abandoned = attempted;
    attempted[3] = true;
    // Two nets behind the rail are still owed a turn.
    try testing.expectEqual(@as(usize, 2), unblockFirstTriesOwed(&targets, 0, &attempted, &abandoned));
    // A net already attempted is owed nothing more, and a net abandoned is owed
    // nothing at all.
    attempted[9] = true;
    try testing.expectEqual(@as(usize, 1), unblockFirstTriesOwed(&targets, 0, &attempted, &abandoned));
    abandoned[11] = true;
    try testing.expectEqual(@as(usize, 0), unblockFirstTriesOwed(&targets, 0, &attempted, &abandoned));
    // One net, one first attempt, however many slots the plan gave it.
    const rail = [_]target_unblock.Target{
        .{ .net_i = 3, .gap_mm = 1.00, .kind = .one_gap },
        .{ .net_i = 5, .gap_mm = 1.50, .kind = .one_gap },
        .{ .net_i = 5, .gap_mm = 2.06, .kind = .one_gap },
        .{ .net_i = 5, .gap_mm = 3.10, .kind = .one_gap },
    };
    var fresh = [_]bool{ false, false, false, false, false, false, false, false, false, false, false, false };
    try testing.expectEqual(@as(usize, 1), unblockFirstTriesOwed(&rail, 0, &fresh, &fresh));
    // Nothing is owed past the end of the plan.
    try testing.expectEqual(@as(usize, 0), unblockFirstTriesOwed(&rail, rail.len, &fresh, &fresh));
    fresh[5] = true;
    try testing.expectEqual(@as(usize, 0), unblockFirstTriesOwed(&rail, 0, &fresh, &fresh));
}

// spec: serve/route-plan - the remaining route budget is divided among the unblock LADDERS still live, so a planned target whose net an earlier refusal abandoned stops taking a share, and one net's several planned slots take a single share between them
test "an abandoned net's planned targets stop taking a share of the tail" {
    // A rail whose per-gap targets fill three of five slots, plus two two-terminal
    // nets behind them — barracuda's shape.
    const targets = [_]target_unblock.Target{
        .{ .net_i = 3, .gap_mm = 1.00, .kind = .one_gap },
        .{ .net_i = 7, .gap_mm = 6.42, .kind = .one_gap },
        .{ .net_i = 3, .gap_mm = 1.50, .kind = .one_gap },
        .{ .net_i = 3, .gap_mm = 2.06, .kind = .one_gap },
        .{ .net_i = 9, .gap_mm = 42.54, .kind = .whole_net },
    };
    var abandoned = [_]bool{ false, false, false, false, false, false, false, false, false, false };
    // Nothing abandoned: THREE ladders share the tail, not five slots. The rail's
    // other two pockets are the attempt-in-hand's own rungs, and a rung has never
    // taken a turn of its own.
    try testing.expectEqual(@as(usize, 3), unblockLiveTargets(&targets, 0, &abandoned));
    try testing.expectEqual(@as(usize, 1), unblockLiveTargets(&targets, targets.len - 1, &abandoned));
    // Counted from the rail's SECOND slot, the ladder in hand plus the one net
    // still behind it — its own third slot is a rung, and net 7 is already done.
    try testing.expectEqual(@as(usize, 2), unblockLiveTargets(&targets, 2, &abandoned));
    // Net 3 refused and was abandoned, so its two remaining slots are targets the
    // pass will skip — and a share quoted against them is a share handed to
    // nobody.
    abandoned[3] = true;
    try testing.expectEqual(@as(usize, 2), unblockLiveTargets(&targets, 1, &abandoned));
    // The target being attempted always counts itself, even when its own net has
    // just been abandoned by the refusal being handled.
    try testing.expectEqual(@as(usize, 3), unblockLiveTargets(&targets, 0, &abandoned));
    // Past the end there is only ever the attempt in hand.
    try testing.expectEqual(@as(usize, 1), unblockLiveTargets(&targets, targets.len, &abandoned));
}

// spec: serve/route-plan - a net that has earned an unblock accept this phase retires a refused hop and continues its ladder at the next-smallest, each hop offered at most once per phase, while a net that has proved nothing is still abandoned on its first refusal
test "a retired unblock hop is never offered to its net again" {
    // barracuda's `GND` after two accepts: a 1.27 mm pocket its transaction
    // cannot cross, and five wider pockets nobody had asked about.
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "U1", .pad = "9", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "C7", .pad = "2", .x = 1.27, .y = 0, .side = .top, .thru = false, .island = 1 },
        .{ .ref = "C8", .pad = "2", .x = 4, .y = 0, .side = .top, .thru = false, .island = 2 },
        .{ .ref = "C9", .pad = "2", .x = 8, .y = 0, .side = .top, .thru = false, .island = 3 },
    };
    const gaps = [_]fab_readiness.OpenGap{
        .{ .mm = 1.50, .from = pads[1], .to = pads[2] },
        .{ .mm = 1.27, .from = pads[0], .to = pads[1] },
        .{ .mm = 2.06, .from = pads[2], .to = pads[3] },
    };
    const joined = [_]bool{ false, false, false, false };
    const detail = fab_readiness.OpenNet{
        .net = "GND",
        .islands = 4,
        .pads = &pads,
        .gaps = &gaps,
        .plane_joined = &joined,
    };
    // Nothing retired: the cheapest hop, exactly as before.
    try testing.expectEqual(@as(usize, 1), unblockChosenGap(&.{}, 3, detail).?);
    // Retired, so the ladder moves to the next-smallest rather than re-forming
    // the same transaction against the same board.
    const retired = [_]RetiredGap{RetiredGap.names(gaps[1], 3)};
    try testing.expectEqual(@as(usize, 0), unblockChosenGap(&retired, 3, detail).?);
    // The hop is named by its PAD PAIR, so the oracle renumbering a net's gaps
    // cannot resurrect it, and which end the oracle names first is its business.
    const renumbered = [_]fab_readiness.OpenGap{
        .{ .mm = 1.27, .from = pads[1], .to = pads[0] },
        .{ .mm = 2.06, .from = pads[2], .to = pads[3] },
    };
    const after = fab_readiness.OpenNet{
        .net = "GND",
        .islands = 3,
        .pads = &pads,
        .gaps = &renumbered,
        .plane_joined = &joined,
    };
    try testing.expectEqual(@as(usize, 1), unblockChosenGap(&retired, 3, after).?);
    // A retirement belongs to ONE net: the same pads on another net's ladder are
    // another net's problem.
    try testing.expectEqual(@as(usize, 1), unblockChosenGap(&retired, 4, detail).?);
    // And a net whose every hop has been retired has no ladder left, which is
    // what ends it.
    const all = [_]RetiredGap{
        RetiredGap.names(gaps[0], 3),
        RetiredGap.names(gaps[1], 3),
        RetiredGap.names(gaps[2], 3),
    };
    try testing.expect(unblockChosenGap(&all, 3, detail) == null);
}

// spec: serve/route-plan - a per-gap unblock transaction keeps its target net's own copper, draws one island join in the channel its rip freed, and is accepted only on a credited island merge
test "a per-gap unblock transaction is judged on its island merge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The oracle renumbers a net's gaps whenever a transaction lands, so a
    // per-gap target names its hop by length and looks it up again here.
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 4, .y = 0, .side = .top, .thru = false, .island = 1 },
        .{ .ref = "R3", .pad = "1", .x = 9, .y = 0, .side = .top, .thru = false, .island = 2 },
    };
    const gaps = [_]fab_readiness.OpenGap{
        .{ .mm = 5.0, .from = pads[1], .to = pads[2] },
        .{ .mm = 1.4, .from = pads[0], .to = pads[1] },
    };
    const joined = [_]bool{ false, false, false };
    const detail = fab_readiness.OpenNet{
        .net = "PWR",
        .islands = 3,
        .pads = &pads,
        .gaps = &gaps,
        .plane_joined = &joined,
    };
    try testing.expectEqual(@as(usize, 1), unblockChosenGap(&.{}, 0, detail).?);
    // A net the oracle names no hop for has nothing for this tier to draw.
    const whole = fab_readiness.OpenNet{ .net = "PWR", .islands = 1, .pads = &pads, .gaps = &.{}, .plane_joined = &joined };
    try testing.expect(unblockChosenGap(&.{}, 0, whole) == null);

    // The hop is requested exactly as the post-route gate requests one, so the
    // two passes cannot aim at different geometry.
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "PWR", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const request = (try route_close.hopRequest(arena, placement, 0, pads[0], pads[1])).?;
    try testing.expectEqual(@as(usize, 0), request.net_i);
    try testing.expectApproxEqAbs(@as(f64, 0), request.from.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), request.to.?.x, 1e-9);
    // Its window is the gate's own corridor margin, not a wider one.
    const window = route_close.hopWindow(request);
    try testing.expect(window.x1 - window.x0 > 4);
    try testing.expect(window.x1 - window.x0 < 4 + 4 * 3.0);
}

// spec: serve/route-plan - a target whose narrow unblock transaction was refused is retried with wider rip authority when the board has spare wall time per remaining target, while a clock-free run keeps exactly one narrow attempt
test "the wide unblock retry is spent only on a board with time to spare" {
    const now: i128 = 0;
    const minute = 60 * clock.ns_per_s;
    // One target and a minute left: the wide transaction is affordable.
    try testing.expect(wideUnblockAffordable(now, minute, 1));
    // The same minute split five ways is not — a second, wider attempt each
    // would take the tail the additive close behind this phase needs.
    try testing.expect(!wideUnblockAffordable(now, minute, 5));
    // Nothing left on the clock, and nothing left to spend it on.
    try testing.expect(!wideUnblockAffordable(now, now + clock.ns_per_s, 1));
    try testing.expect(!wideUnblockAffordable(now, minute, 0));
    // A clock-free run answers no: bench and test boards are deterministic and
    // "is there time left" is not a question they can be asked.
    try testing.expect(!wideUnblockAffordable(now, 0, 1));
    // The wide tier really is wider than the ordinary one.
    try testing.expect(unblock_wide_limits.blockers.max_nets > target_unblock_limits.blockers.max_nets);
    try testing.expect(
        unblock_wide_limits.blockers.max_total_elements > target_unblock_limits.blockers.max_total_elements,
    );
    // And it is the ONLY tier that may negotiate a declared differential pair,
    // so the clock-free answer above is also what keeps a pair off every bench
    // and test board: the switch rides on a transaction this run never forms.
    try testing.expect(unblock_wide_limits.negotiate.pairs);
    try testing.expect(!target_unblock_limits.negotiate.pairs);
}

// spec: serve/route-plan - a narrow unblock refusal the board answered on geometry skips the wide retry unless the wider nomination reaches a negotiable-class blocker the narrow rip did not hold, while a refusal about time, authority or scope is retried wider as before
test "a geometry refusal is retried wider only for authority the narrow rip lacked" {
    // The two verdicts that are the BOARD's answer: no path across the freed
    // corridor, and a candidate that re-routed the corridor's occupants and left
    // the target open anyway.
    try testing.expect(UnblockDead.join_no_path.onGeometry());
    const still_open = [_][]const u8{ "V_3V3A", "SPI_SCK" };
    const target_open = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 2,
        .failed = &still_open,
    };
    try testing.expect(unblockRolledBackOnGeometry("V_3V3A", target_open));
    // Every other cause is about something a bigger transaction can change, so
    // it stays a reason to retry wider.
    try testing.expect(!UnblockDead.route_expired.onGeometry());
    try testing.expect(!UnblockDead.join_would_rip.onGeometry());
    try testing.expect(!UnblockDead.no_gap.onGeometry());
    try testing.expect(!UnblockDead.route_error.onGeometry());
    try testing.expect(!UnblockDead.copper_lost.onGeometry());
    // A target that CLOSED and was rolled back for something else is a budget or
    // ordering answer, not a geometry one.
    const blocker_open = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 1,
        .total = 2,
        .failed = &[_][]const u8{"SPI_SCK"},
    };
    try testing.expect(!unblockRolledBackOnGeometry("V_3V3A", blocker_open));

    // barracuda's v91 `V_3V3A`: the narrow transaction ripped one blocker, and
    // the wide nomination came back with that same net plus generic growth.
    // Nothing there is a class the narrow tier could not reach, so its 45 s
    // slice would re-ask a question the board has already answered.
    const narrow = [_]vacate_policy.Nomination{
        .{ .net_i = 4, .kind = .short_stub, .elements = 9, .dist = 0.4 },
    };
    const same_classes = [_]vacate_policy.Nomination{
        .{ .net_i = 4, .kind = .short_stub, .elements = 9, .dist = 0.4 },
        .{ .net_i = 7, .kind = .short_stub, .elements = 12, .dist = 0.9 },
    };
    const negotiate = unblock_wide_limits.negotiate;
    try testing.expect(unblockNewAuthority(&same_classes, &narrow, negotiate) == null);
    // A declared pair the narrow tier may not nominate at all IS new authority —
    // a different corridor rather than a bigger one.
    const with_pair = [_]vacate_policy.Nomination{
        .{ .net_i = 4, .kind = .short_stub, .elements = 9, .dist = 0.4 },
        .{ .net_i = 9, .kind = .pair_recouple, .elements = 30, .dist = 1.1 },
    };
    try testing.expectEqual(
        @as(usize, 9),
        unblockNewAuthority(&with_pair, &narrow, negotiate).?.net_i,
    );
    // So is a plane- or pour-carried net the lifting tier will open corridor-only.
    const with_lift = [_]vacate_policy.Nomination{
        .{ .net_i = 18, .kind = .pour_carried, .elements = 6, .dist = 0.3 },
    };
    try testing.expectEqual(
        @as(usize, 18),
        unblockNewAuthority(&with_lift, &narrow, negotiate).?.net_i,
    );
    // Both classes are new authority only while the tier actually holds the
    // switch, which is the same gate `pairFacts` and `liftFacts` read.
    try testing.expect(unblockNewAuthority(&with_pair, &narrow, .{}) == null);
    try testing.expect(unblockNewAuthority(&with_lift, &narrow, .{}) == null);
    // And a negotiable class on copper the narrow rip already held is not new
    // authority: a corridor lift removes LESS of a net that was ripped whole.
    const already = [_]vacate_policy.Nomination{
        .{ .net_i = 18, .kind = .pour_carried, .elements = 44, .dist = 0.3 },
    };
    try testing.expect(unblockNewAuthority(&with_lift, &already, negotiate) == null);
}

// spec: serve/route-plan - a ripped net a scoped restore left open is re-homed by the gridless shape channel alone before the transaction is declared lost, additively and re-tallied by the oracle, while a whole-net target that stayed open is never offered to it
test "a lost unblock victim is offered the shape channel before it is given up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two two-terminal nets 3 mm across, on their own pads: a transaction whose
    // TARGET closed and whose ripped VICTIM the restore left in two islands.
    var parts: std.ArrayList(optimizer.Part) = .empty;
    try appendUnblockPart(arena, &parts, "R1", .{ 0, 0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R2", .{ 3, 0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R3", .{ 0, 2 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R4", .{ 3, 2 }, &route_plan_fixture_pad);
    const nets = [_]optimizer.FlatNet{
        .{ .name = "TARGET", .pins = try unblockPins(arena, "R1", "R2") },
        .{ .name = "VICTIM", .pins = try unblockPins(arena, "R3", "R4") },
    };
    var placement = fixturePlacement(parts.items, &nets);
    placement.maxy = 2.5;

    // The tier this seam stands on. `.only` is the third state, not a degree of
    // effort: the maze alone, the maze with the mesh behind it, and the MESH
    // ALONE — which is the one a caller that has already mazed this connection
    // needs, and the one the re-home asks for.
    try testing.expect(!router.ShapeTier.off.meshes());
    try testing.expect(router.ShapeTier.fallback.meshes());
    try testing.expect(router.ShapeTier.only.meshes());
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 3, .y = 0, .side = .top, .thru = false, .island = 1 },
    };
    const request = (try route_close.hopRequest(arena, placement, 0, pads[0], pads[1])).?;
    const board = router.GapBoard{ .tracks = &.{}, .vias = &.{}, .zones = &.{} };
    const mesh_off = router.GapOptions{
        .ripup = false,
        .shape = .off,
        .judge = .{ .ctx = null, .keep = route_close.additiveOnly },
        .raster = .{ .window = route_close.hopWindow(request) },
    };
    const mazed = try router.closeGaps(arena, placement, .{}, board, &.{request}, mesh_off);
    try testing.expect(mazed.len == 1 and mazed[0] != null);
    // The same hop, with the lattice never consulted: the mesh answers on its own.
    var mesh_only = mesh_off;
    mesh_only.shape = .only;
    const meshed = try router.closeGaps(arena, placement, .{}, board, &.{request}, mesh_only);
    try testing.expect(meshed.len == 1 and meshed[0] != null);
    try testing.expectEqual(@as(usize, 0), meshed[0].?.ripped.len);

    // Which victims the re-home is willing to draw for. A ripped net the restore
    // left open is offered; one that came back is not.
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    const open = [_][]const u8{"VICTIM"};
    const candidate = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 1,
        .total = 2,
        .failed = &open,
    };
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = candidate,
        .measured = .{},
    };
    const victim = vacate_policy.Nomination{ .net_i = 1, .kind = .short_stub, .elements = 12, .dist = 0.4 };
    const returned = vacate_policy.Nomination{ .net_i = 0, .kind = .short_stub, .elements = 3, .dist = 0.2 };
    try testing.expectEqualStrings("VICTIM", unblockRehomable(&run, victim, candidate).?);
    try testing.expect(unblockRehomable(&run, returned, candidate) == null);
    // A declared pair is offered too, and NAMED — it comes back coupled
    // (`unblockPairHome`) rather than by a lone channel, and declining it before
    // the first log statement is what made this whole tier unfalsifiable.
    const leg = vacate_policy.Nomination{ .net_i = 1, .kind = .pair_recouple, .elements = 30, .dist = 0.4 };
    try testing.expectEqualStrings("VICTIM", unblockRehomable(&run, leg, candidate).?);
    // And a reporting path may never take a route down on a stale index.
    const stray = vacate_policy.Nomination{ .net_i = placement.nets.len, .kind = .short_stub, .elements = 1, .dist = 0 };
    try testing.expect(unblockRehomable(&run, stray, candidate) == null);

    // A WHOLE-NET target that is itself still open was refused on geometry: its
    // victims are not asked, and the candidate comes back untouched.
    const both_open = [_][]const u8{ "TARGET", "VICTIM" };
    var target_open = candidate;
    target_open.failed = &both_open;
    const deadline = clock.nanoTimestamp() + 5 * clock.ns_per_s;
    const skipped = try unblockRehome(&run, .{ .net_i = 0, .gap_mm = 3 }, &.{victim}, target_open, deadline);
    try expectUnblockCopperIdentical(target_open, skipped);
    // Nothing open, nothing ripped, and an expired slice are all no-ops too.
    const done = try unblockRehome(&run, .{ .net_i = 0, .gap_mm = 3 }, &.{victim}, .{
        .tracks = &.{},
        .vias = &.{},
        .routed = 2,
        .total = 2,
        .failed = &.{},
    }, deadline);
    try testing.expectEqual(@as(usize, 0), done.failed.len);
    try expectUnblockCopperIdentical(candidate, try unblockRehome(&run, .{ .net_i = 0, .gap_mm = 3 }, &.{}, candidate, deadline));
    try expectUnblockCopperIdentical(candidate, try unblockRehome(&run, .{ .net_i = 0, .gap_mm = 3 }, &.{victim}, candidate, 1));

    // The real thing: VICTIM's two pads are 3 mm apart on an empty board, so the
    // mesh finds the channel the scoped maze did not, and the oracle re-read over
    // the copper that now exists reports the net closed.
    const rehomed = try unblockRehome(&run, .{ .net_i = 0, .gap_mm = 3 }, &.{victim}, candidate, deadline);
    try testing.expect(rehomed.tracks.len > candidate.tracks.len);
    try testing.expect(!namedFailed("VICTIM", rehomed.failed));
}

// spec: serve/route-plan - a lost differential-pair victim is re-homed by a scoped coupled re-route of both its legs over the candidate's frozen copper, kept only when the oracle joins both, while a leg whose pair the board no longer declares is named and left alone
// spec: serve/route-plan - a lost differential-pair victim's coupled re-home asks the mesh-augmented search first and the lattice alone behind it, keeping whichever board the oracle joins both legs on, because a mesh construction stands in front of the pair's own legacy fallback
test "a lost pair victim is re-homed coupled rather than declined" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var placement = try pairWalledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    // The premise: the declared pair is down and whole on the board this
    // transaction started from.
    try testing.expect(!namedFailed("REF_P", baseline.failed));
    try testing.expect(!namedFailed("REF_N", baseline.failed));

    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = unblock_wide_limits,
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };

    // The candidate a restore that LOST the pair leaves behind: every other net's
    // copper exactly as it was, and both legs off the board.
    const lost = try unblockRetally(&run, try boardWithoutNets(arena, baseline, &.{ 1, 2 }));
    try testing.expect(namedFailed("REF_P", lost.failed));

    const pick = vacate_policy.Nomination{ .net_i = 1, .kind = .pair_recouple, .elements = 8, .dist = 0.4 };
    const legs = unblockPairLegs(&run, 0);
    // It is priced as the scoped ROUTE it is, not as the hop the shape channel
    // draws: measured on barracuda (Debug), the 4 s hop window was not enough to
    // build the board's lattice and the re-home verdicted "ran out of its
    // window" on every attempt.
    try testing.expect(pair_rehome_window_ns > rehome_window_ns);
    const clock_free = clock.nanoTimestamp();
    try testing.expectEqual(
        clock_free,
        pairRehomeDeadline(clock_free, 0, run.lim.slice.reserve_ns, clock_free),
    );
    try testing.expect(pairRehomeDeadline(
        clock_free,
        clock_free + 120 * clock.ns_per_s,
        run.lim.slice.reserve_ns,
        clock_free,
    ) > rehomeDeadline(
        clock_free,
        clock_free + 120 * clock.ns_per_s,
        run.lim.slice.reserve_ns,
        clock_free,
    ));
    try testing.expect(!try unblockPairJoined(&run, legs, lost));

    // The coupled constructor re-lays BOTH legs over the copper that now exists,
    // and the oracle — not the scoped route's own claim — says they came back.
    var landed: usize = 0;
    const window = clock.nanoTimestamp() + 30 * clock.ns_per_s;
    // Both search spaces are asked and the ORACLE picks between them. On this
    // fixture the mesh commits a coupled construction that passes the exact
    // clearance probe and that the oracle still finds open — and because a
    // committed coupled pair is one the pair's legacy leader/follower fallback
    // never gets to make, asking the wider space alone would stop re-homing this
    // pair at all.
    try testing.expect((try unblockPairRoute(&run, "TARGET", legs, lost, window, .mesh_behind_maze)) == null);
    try testing.expect((try unblockPairRoute(&run, "TARGET", legs, lost, window, .maze_only)) != null);
    const homed = try unblockPairHome(&run, "TARGET", pick, lost, window, &landed);
    try testing.expectEqual(@as(usize, 1), landed);
    try testing.expect(homed.tracks.len > lost.tracks.len);
    try testing.expect(try unblockPairJoined(&run, legs, homed));
    // Foreign copper is frozen, so every item the candidate held is echoed back.
    const frozen = try boardAsExisting(arena, lost);
    try testing.expect(
        (try retainsExistingCopper(arena, homed, frozen.tracks, frozen.vias, &.{})) == null,
    );

    // An expired window lands nothing and hands back the board it was given.
    var none: usize = 0;
    try expectUnblockCopperIdentical(lost, try unblockPairHome(&run, "TARGET", pick, lost, 1, &none));
    try testing.expectEqual(@as(usize, 0), none);

    // A leg whose pair the board no longer declares is named and left alone
    // rather than re-laid as a single net.
    placement.diff_pairs = &.{};
    run.placement = placement;
    try expectUnblockCopperIdentical(lost, try unblockPairHome(&run, "TARGET", pick, lost, window, &none));
    try testing.expectEqual(@as(usize, 0), none);
}

// spec: serve/route-plan - one refused transaction's own lost victim earns exactly one alternate nomination whichever tier formed it, holding that net and any declared twin out of the sweep, while an accepted or victimless outcome earns none
test "a lost victim earns one alternate nomination from either tier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };
    const targets = try unblockTargets(arena, placement, .{}, baseline, .{});
    try testing.expectEqual(@as(usize, 1), targets.len);
    const share = UnblockShare{
        .board_deadline_ns = clock.nanoTimestamp() + 120 * clock.ns_per_s,
        .targets_left = 1,
    };
    const picks = [_]vacate_policy.Nomination{
        .{ .net_i = 1, .kind = .short_stub, .elements = 12, .dist = 0.4 },
    };

    // An ACCEPTED transaction is owed nothing — there is no victim and no retry.
    try testing.expect(!try unblockAlternate(&run, targets[0], share, target_unblock_limits, .{
        .accepted = true,
        .lost_victim = 1,
        .picked = &picks,
    }, 1));
    // Nor is a refusal the board answered on geometry: no net was lost to hold.
    try testing.expect(!try unblockAlternate(&run, targets[0], share, target_unblock_limits, .{
        .geometry = true,
        .picked = &picks,
    }, 1));
    try testing.expectEqual(@as(usize, 0), run.alternates);

    // A victim loss earns exactly one — and it is priced and nominated under the
    // limits of the TIER THAT FORMED IT, which is the wide tier as readily as the
    // narrow one. Measured on barracuda (ReleaseSafe, v95): the wide transaction
    // lost `REF_LMX_N`, and the tail read `accepted` off its outcome and threw
    // the victim away, so this retry was never once offered on a real board.
    const wide_lim = target_unblock.corridorSlice(unblock_wide_limits, targets[0].gap_mm);
    run.lim = wide_lim;
    try testing.expect(!try unblockAlternate(&run, targets[0], share, wide_lim, .{
        .lost_victim = 1,
        .picked = &picks,
    }, 1));
    try testing.expectEqual(@as(usize, 1), run.alternates);
    try testing.expect(run.held == null);
    // The narrow tier's own loss earns its own, on the same one-per-refusal rule.
    run.lim = target_unblock_limits;
    try testing.expect(!try unblockAlternate(&run, targets[0], share, target_unblock_limits, .{
        .lost_victim = 1,
        .picked = &picks,
    }, 1));
    try testing.expectEqual(@as(usize, 2), run.alternates);

    // Holding one leg of a declared pair holds its TWIN with it. A pair is
    // ripped, re-laid and judged as one thing, so offering the other leg
    // re-forms the identical transaction under the other leg's name — measured
    // on barracuda (Debug, this increment): the alternate held `REF_LMX_N` and
    // the very next sweep picked `REF_LMX_P`, the same 38 elements of the same
    // pair, for the same refusal.
    run.placement = try pairWalledUnblockPlacement(arena);
    run.held = 1;
    try testing.expect(unblockHeldOut(&run, 1));
    try testing.expect(unblockHeldOut(&run, 2));
    try testing.expect(!unblockHeldOut(&run, 0));
    // An unpaired victim holds only itself, and no held net holds nothing.
    run.held = 0;
    try testing.expect(!unblockHeldOut(&run, 1));
    run.held = null;
    try testing.expect(!unblockHeldOut(&run, 1));
}

// spec: serve/route-plan - a scoped transaction's gate reconciles in a window out of the clock the pass still holds rather than the slice its own re-route has already spent, and a clock-free board keeps exactly the deadline it had
test "a scoped transaction's gate takes its window from the pass, not its spent slice" {
    const now: i128 = 1000 * clock.ns_per_s;
    const reserve = target_unblock_limits.slice.reserve_ns;
    const spent = now - clock.ns_per_s; // the re-route drank the whole slice
    // A clock-free board keeps exactly the deadline it had, so every bench and
    // corpus route gates byte-identically.
    try testing.expectEqual(spent, windowDeadline(now, 0, reserve, spent, gate_window_ns));
    // With the board's clock still running, the gate gets its own window.
    const board = now + 120 * clock.ns_per_s;
    try testing.expectEqual(now + gate_window_ns, windowDeadline(now, board, reserve, spent, gate_window_ns));
    // It can only ever GRANT time: a deadline already longer than the window wins.
    const generous = now + 5 * gate_window_ns;
    try testing.expectEqual(generous, windowDeadline(now, board, reserve, generous, gate_window_ns));
    // And it never eats the reserve the additive close behind the pass is owed.
    const nearly_done = now + reserve;
    try testing.expectEqual(spent, windowDeadline(now, nearly_done, reserve, spent, gate_window_ns));
    // One arithmetic, two windows: the re-home's is the same call, smaller.
    try testing.expect(rehome_window_ns < gate_window_ns);
    try testing.expectEqual(
        windowDeadline(now, board, reserve, spent, rehome_window_ns),
        rehomeDeadline(now, board, reserve, spent),
    );

    // The options the gate actually runs under carry that window and nothing else.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 0 },
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]optimizer.FlatNet{.{ .name = "N", .pins = try unblockPins(arena, "R1", "R2") }};
    const placement = fixturePlacement(&parts, &nets);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + 120 * clock.ns_per_s } },
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 },
        .measured = .{},
    };
    const retry = route_policy.Options{ .effort = .one_shot, .stop = .{ .deadline_ns = clock.nanoTimestamp() - 1 } };
    const gated = unblockGateOptions(&run, retry);
    try testing.expect(gated.stop.deadline_ns > retry.stop.deadline_ns);
    try testing.expectEqual(retry.effort, gated.effort);
    // A clock-free pass hands the gate exactly the deadline the transaction had.
    run.options.stop.deadline_ns = 0;
    try testing.expectEqual(retry.stop.deadline_ns, unblockGateOptions(&run, retry).stop.deadline_ns);
}

// spec: serve/route-plan - a scoped transaction whose gate overran that slice is judged on the board the gate produced instead of reported as no candidate, while the board's own deadline and cancel flag stay the authority and a re-route cut off before it drew a board is still a dead end
test "a gate that overran its slice hands back a board to judge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 0 },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "N", .pins = try unblockPins(arena, "R1", "R2") }};
    const placement = fixturePlacement(&parts, &nets);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 },
        .measured = .{},
    };
    const target = target_unblock.Target{ .net_i = 0, .gap_mm = 3 };
    // The gate ran, reconciled and answered; the flag says only that ONE
    // transaction's slice elapsed while it did. The board is judged, and the flag
    // is cleared so a committed candidate cannot report the whole route cancelled.
    const overran = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 2, .cancelled = true };
    const judged = unblockGateOverran(&run, target, overran);
    try testing.expect(!judged.cancelled);
    try expectUnblockCopperIdentical(overran, judged);
    try testing.expectEqual(overran.routed, judged.routed);
    // A gate that did not overrun is handed back untouched.
    var fine = overran;
    fine.cancelled = false;
    try testing.expect(!unblockGateOverran(&run, target, fine).cancelled);
    // The BOARD's own stop is still the authority the accept path asks.
    try testing.expect(routeStopped(.{ .stop = .{ .deadline_ns = clock.nanoTimestamp() - 1 } }));
    try testing.expect(!routeStopped(.{}));
    // And a re-route cut off BEFORE it drew a board is still a dead end, named
    // for the half of the transaction that actually ran out.
    try testing.expect(!UnblockDead.route_expired.onGeometry());
    try testing.expect(
        std.mem.indexOf(u8, UnblockDead.route_expired.label(), "before it drew a board") != null,
    );
}

// spec: serve/route-plan - an unblock transaction the board refused only because a net it ripped could not be put back is retried once with exactly that net held out of the nomination, on a board with measured spare wall time, while every other refusal and every clock-free run keeps today's single attempt
test "a transaction refused for a lost victim is retried once without it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };
    const picks = [_]vacate_policy.Nomination{
        .{ .net_i = 1, .kind = .short_stub, .elements = 12, .dist = 0.4 },
        .{ .net_i = 2, .kind = .short_stub, .elements = 3, .dist = 0.9 },
    };

    // The verdict this retry answers, and only it: the target CLOSED and a net
    // the rip took did not come back.
    const lost = [_][]const u8{"AAA"};
    const victim_open = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 2, .total = 3, .failed = &lost };
    try testing.expectEqual(@as(usize, 1), unblockLostVictim(&run, "TARGET", &picks, victim_open).?);
    // A target that stayed open is a geometry answer about the corridor, not a
    // price the rip could not pay — no alternate.
    const target_open = [_][]const u8{ "TARGET", "AAA" };
    try testing.expect(unblockLostVictim(&run, "TARGET", &picks, .{
        .tracks = &.{},
        .vias = &.{},
        .routed = 1,
        .total = 3,
        .failed = &target_open,
    }) == null);
    // Everything back and the whole-board gate still refusing is not one either.
    try testing.expect(unblockLostVictim(&run, "TARGET", &picks, .{
        .tracks = &.{},
        .vias = &.{},
        .routed = 3,
        .total = 3,
        .failed = &.{},
    }) == null);
    // A stale index names nothing rather than taking the pass down.
    const stray = [_]vacate_policy.Nomination{
        .{ .net_i = placement.nets.len, .kind = .short_stub, .elements = 1, .dist = 0 },
    };
    try testing.expect(unblockLostVictim(&run, "TARGET", &stray, victim_open) == null);

    // Held, that net is out of the sweep — and it is the ONLY thing that changes:
    // the rest of the corridor's occupants are nominated exactly as before.
    const targets = try unblockTargets(arena, placement, .{}, baseline, .{});
    try testing.expectEqual(@as(usize, 1), targets.len);
    const before = try unblockBlockers(&run, targets[0]);
    try testing.expect(unblockAlreadyPicked(before, 1));
    run.held = 1;
    const after = try unblockBlockers(&run, targets[0]);
    run.held = null;
    try testing.expect(!unblockAlreadyPicked(after, 1));
    try testing.expectEqual(before.len - 1, after.len);

    // The retry is gated on the same measured spare wall time the wide tier
    // stands on, so a clock-free board never forms it and every bench and corpus
    // route is byte-identical — and a refusal that named no victim never does.
    const timed = UnblockShare{ .board_deadline_ns = clock.nanoTimestamp() + 60 * clock.ns_per_s, .targets_left = 1 };
    try testing.expect(!try unblockAlternate(&run, targets[0], timed, target_unblock_limits, .{}, 1));
    const refused = UnblockOutcome{ .lost_victim = 1, .picked = &picks };
    try testing.expect(!try unblockAlternate(&run, targets[0], .{ .board_deadline_ns = 0, .targets_left = 1 }, target_unblock_limits, refused, 1));
    try testing.expect(run.held == null);
    // Its one attempt on a walled board closes nothing and leaves the baseline
    // exactly as it arrived — the alternate is a nomination, not a licence.
    try testing.expect(!try unblockAlternate(&run, targets[0], timed, target_unblock_limits, refused, 1));
    try testing.expect(run.held == null);
    try expectUnblockCopperIdentical(baseline, run.baseline);
}

// spec: serve/route-plan - an unblock transaction the board refused with its target still open extends its rip with the blockers the board it produced still shows in the way, for a bounded number of rounds, never past the additive close's reserve or a floor slice still owed to a target behind it, while a clock-free run keeps today's single attempt
test "a transaction still open after its own re-route deepens, and a clock-free one never does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };
    const picks = [_]vacate_policy.Nomination{
        .{ .net_i = 1, .kind = .short_stub, .elements = 12, .dist = 0.4 },
    };
    const still_open = [_][]const u8{"TARGET"};
    const produced = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 2, .failed = &still_open };
    // A clock-free run — every bench, every corpus route — never enters the
    // ladder at all, which is what keeps those boards byte-identical.
    const target = target_unblock.Target{ .net_i = 0, .gap_mm = 3 };
    const alone = UnblockShare{ .board_deadline_ns = 0, .targets_left = 1 };
    try testing.expect((try unblockDeepen(&run, target, &picks, produced, alone)) == null);
    try expectUnblockCopperIdentical(baseline, run.baseline);
    // The bound is declared rather than emergent: each round pays a whole scoped
    // re-route plus its gate.
    try testing.expectEqual(@as(usize, 2), unblock_max_deepen);
    // And a round claims its window out of the clock the PASS still holds, never
    // the transaction's own already-spent slice, never the additive close's
    // reserve, and never a floor slice owed to a target still behind it.
    const now = clock.nanoTimestamp();
    const floor = 4 * clock.ns_per_s;
    const budget = DeepenBudget{ .board_deadline_ns = 0, .reserve_ns = 0, .targets_left = 1, .floor_ns = floor };
    try testing.expectEqual(now, deepenDeadline(now, budget));
    var timed_budget = budget;
    timed_budget.board_deadline_ns = now + 10 * deepen_window_ns;
    try testing.expectEqual(now + deepen_window_ns, deepenDeadline(now, timed_budget));
    // The additive close's reserve is off limits …
    var reserved = timed_budget;
    reserved.reserve_ns = 10 * deepen_window_ns;
    try testing.expectEqual(now, deepenDeadline(now, reserved));
    // … and so is the floor every target behind this one is still owed: eight of
    // them claim more than the whole remainder, so there is no round at all.
    var crowded = budget;
    crowded.board_deadline_ns = now + deepen_window_ns;
    crowded.targets_left = 9;
    try testing.expectEqual(now, deepenDeadline(now, crowded));
    // Three behind is 12 s set aside and the round takes the 18 s left — the
    // remainder SHORTENS the window rather than refusing it.
    crowded.targets_left = 4;
    try testing.expectEqual(now + deepen_window_ns - 3 * floor, deepenDeadline(now, crowded));
    // Alone, it takes that whole remainder, up to its own cap.
    crowded.targets_left = 1;
    try testing.expectEqual(now + deepen_window_ns, deepenDeadline(now, crowded));
}

// spec: serve/route-plan - a timed ladder deepens past its two free rounds only while the remainder still covers its own measured round price after a whole funded ladder is held for every ladder behind it, stops at a hard round cap, and keeps the two-round bound exactly on a board with no clock
test "a ladder deepens past two rounds only while its own price fits the remainder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledUnblockPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 2 },
        .measured = .{},
    };
    const now = clock.nanoTimestamp();
    const second = clock.ns_per_s;

    // A CLOCK-FREE board keeps the standing two, so every bench and corpus route
    // is byte-identical; a timed one runs under the backstop instead, and the
    // backstop is genuinely higher than the count it replaces.
    try testing.expectEqual(unblock_max_deepen, unblockDeepenCap(&run));
    run.options = .{ .stop = .{ .deadline_ns = now + 200 * second } };
    try testing.expectEqual(unblock_max_deepen_funded, unblockDeepenCap(&run));
    try testing.expect(unblock_max_deepen_funded > unblock_max_deepen);

    // The price of one more round is the ladder's OWN measured one, not the
    // window it may claim: barracuda's rounds run 12-18 s against a 30 s window,
    // so a remainder that covers the measurement admits a round the window alone
    // would refuse.
    const measured = 15 * second;
    try testing.expect(measured < deepen_window_ns);
    const alone = UnblockShare{ .board_deadline_ns = now + 40 * second, .targets_left = 1 };
    try testing.expect(deepenAffordsRound(&run, alone, now, measured));
    // A round costlier than what is left is refused — this is the v100 tail the
    // rule exists for, spent only while it is genuinely affordable.
    try testing.expect(!deepenAffordsRound(&run, alone, now, 60 * second));

    // What it must leave standing is a WHOLE funded ladder for each ladder behind
    // it, not a floor slice: the same 40 s remainder that funds a lone ladder's
    // round funds none when a second funded ladder is still waiting.
    const behind = UnblockShare{ .board_deadline_ns = alone.board_deadline_ns, .targets_left = 2 };
    try testing.expect(!deepenAffordsRound(&run, behind, now, measured));
    // With a remainder that covers both, the round is admitted again.
    const roomy = UnblockShare{
        .board_deadline_ns = now + unblock_ladder_price_ns + 40 * second,
        .targets_left = 2,
    };
    try testing.expect(deepenAffordsRound(&run, roomy, now, measured));

    // A ladder whose first rounds cost nothing measurable is still held to the
    // tier's own minimum slice — it must show it can seat a transaction at all.
    const thin = UnblockShare{
        .board_deadline_ns = now + run.lim.slice.reserve_ns + run.lim.slice.min_ns - second,
        .targets_left = 1,
    };
    try testing.expect(!deepenAffordsRound(&run, thin, now, 0));
    const seats = UnblockShare{
        .board_deadline_ns = now + run.lim.slice.reserve_ns + run.lim.slice.min_ns,
        .targets_left = 1,
    };
    try testing.expect(deepenAffordsRound(&run, seats, now, 0));

    // And a clock-free board answers NO however cheap the round, so no corpus
    // route can reach a third one.
    try testing.expect(!deepenAffordsRound(&run, .{ .board_deadline_ns = 0, .targets_left = 1 }, now, 0));
}

// spec: serve/route-plan - a deepened unblock rip adds only the blockers it does not already hold, and a sweep that adds none ends the ladder rather than re-ripping the same copper
test "a deepened rip is the rip it had plus what it did not already hold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledUnblockPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 },
        .measured = .{},
    };
    const rip = [_]vacate_policy.Nomination{
        .{ .net_i = 1, .kind = .short_stub, .elements = 12, .dist = 0.4 },
    };
    // The deeper sweep re-names the net already ripped (it is back on the board
    // and back in the corridor) plus one the first sweep never reached. Only the
    // second is added, and the order the first rip was formed in is kept.
    const found = [_]vacate_policy.Nomination{
        .{ .net_i = 1, .kind = .short_stub, .elements = 12, .dist = 0.4 },
        .{ .net_i = 2, .kind = .short_stub, .elements = 3, .dist = 0.9 },
    };
    const wider = try unblockDeeperRip(&run, &rip, &found, "TARGET");
    try testing.expectEqual(@as(usize, 2), wider.len);
    try testing.expectEqual(@as(usize, 1), wider[0].net_i);
    try testing.expectEqual(@as(usize, 2), wider[1].net_i);
    // A sweep that names nothing new hands the rip straight back, which is the
    // equality the ladder ends on — never a copy that would re-rip the same
    // copper for another whole round.
    const again = try unblockDeeperRip(&run, wider, &rip, "TARGET");
    try testing.expectEqual(wider.len, again.len);
    // A stale index is skipped rather than taking the pass down with it.
    const stray = [_]vacate_policy.Nomination{
        .{ .net_i = placement.nets.len, .kind = .short_stub, .elements = 1, .dist = 0 },
    };
    try testing.expectEqual(rip.len, (try unblockDeeperRip(&run, &rip, &stray, "TARGET")).len);
}

// spec: serve/route-plan - a timed guided corridor retry skips the targets this route's gate has already sealed and reports what that yields the unblock tail, while a target the route has not answered keeps its slice and a clock-free run skips nothing
test "a timed guided retry skips only the targets this route already answered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SEALED", .pins = &fixture_pins },
        .{ .name = "ANSWERED_ONCE", .pins = &.{} },
        .{ .name = "UNPLANNED", .pins = &.{} },
    };
    const placement = fixturePlacement(&parts, &nets);
    var memo = route_close.HopMemo.init(arena);
    defer memo.deinit();
    // Net 0's hop was searched by the gridless tier and found to have no channel
    // in the free space — this route's terminal geometry answer for it.
    try memo.refuseShape(.{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 } });
    // Net 1 was refused ONE maze hop, which is a verdict about that hop and not
    // about the net. Net 2 the gate never planned at all.
    try memo.refuse(.{ .net_i = 1, .from = .{ .x = 1, .y = 0, .layer = 0 } }, false);

    var timed = route_policy.Options{};
    timed.stop.deadline_ns = clock.nanoTimestamp() + 60 * clock.ns_per_s;
    try testing.expect(guidedSealed(timed, &memo, 0));
    try testing.expect(!guidedSealed(timed, &memo, 1));
    try testing.expect(!guidedSealed(timed, &memo, 2));
    // A clock-free board — every bench and corpus route — seals nothing, so it
    // retries exactly the corridors it always did.
    try testing.expect(!guidedSealed(.{}, &memo, 0));

    const order = [_]usize{ 0, 1, 2 };
    const open = [_][]const u8{ "SEALED", "ANSWERED_ONCE", "UNPLANNED" };
    const board = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3, .failed = &open };
    try testing.expectEqual(@as(usize, 1), guidedSealCount(placement, timed, board, &order, &memo));
    try testing.expectEqual(@as(usize, 0), guidedSealCount(placement, .{}, board, &order, &memo));
    // A target the board already closed is not this phase's work at all, sealed
    // or not, so it is never counted as time reclaimed.
    const closed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 3, .total = 3 };
    try testing.expectEqual(@as(usize, 0), guidedSealCount(placement, timed, closed, &order, &memo));
    // What the skip hands the tail is the maze slice it did not spend — the one
    // part of a guided retry that costs a fixed amount.
    try testing.expectEqual(@as(i128, 0), guidedSealYieldSecs(0));
    try testing.expectEqual(
        @divTrunc(3 * lattice_guided_slice_ns, clock.ns_per_s),
        guidedSealYieldSecs(3),
    );
}

// spec: serve/route-plan - a deepening round negotiates a blocker its tier held out on authored rank alone, lifting it corridor-only under the same restore discipline, and the switch is off again for every transaction outside the round
test "a deepening round negotiates an outranking blocker, and only inside the round" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try rankWalledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    // The premise: the two foreign runs are down and whole, the target is not,
    // and both foreign nets outrank it on authored `(priority …)`.
    try testing.expect(namedFailed("TARGET", baseline.failed));
    try testing.expect(!namedFailed("AAA", baseline.failed));
    try testing.expect(!namedFailed("BBB", baseline.failed));
    try testing.expectEqual(@as(u32, 0), fieldClusterPriority(placement, 0));
    try testing.expectEqual(@as(u32, 4), fieldClusterPriority(placement, 1));

    const targets = try unblockTargets(arena, placement, .{}, baseline, .{});
    try testing.expectEqual(@as(usize, 1), targets.len);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var timed = route_policy.Options{};
    timed.stop.deadline_ns = clock.nanoTimestamp() + 10 * 60 * clock.ns_per_s;
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = timed,
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };
    // Every ordinary tier holds them out on rank alone — including the WIDE
    // one, which negotiates the other two classes. Read through the decision
    // rather than through the pick count, so the test proves WHY they are
    // absent rather than merely that they are.
    for ([_]target_unblock.Limits{ target_unblock_limits, unblock_wide_limits }) |lim| {
        run.lim = lim;
        const decision = try unblockNominate(&run, targets[0], baseline);
        try testing.expectEqual(@as(usize, 0), decision.picked.len);
        try testing.expect(decision.refused.len > 0);
        try testing.expectEqual(vacate_policy.Refusal.outranks_seed, decision.refused[0].why);
    }
    run.lim = target_unblock_limits;

    // The deepening round is the one place the guard yields, and the authority it
    // yields under is exactly the forming tier's plus this one switch.
    try testing.expect(!target_unblock_limits.negotiate.outranking);
    try testing.expect(!unblock_wide_limits.negotiate.outranking);
    try testing.expect(deepenAuthority(target_unblock_limits.negotiate).outranking);
    const wide_round = deepenAuthority(unblock_wide_limits.negotiate);
    try testing.expect(wide_round.outranking and wide_round.pairs and wide_round.plane_corridor);

    // Under that authority the round's own sweep names the outranking copper —
    // as `rank_lifted`, charged for the corridor it will lift and never for the
    // whole net.
    run.lim.negotiate = deepenAuthority(run.lim.negotiate);
    const found = try unblockNominate(&run, targets[0], baseline);
    try testing.expect(found.picked.len > 0);
    try testing.expectEqual(vacate_policy.Kind.rank_lifted, found.picked[0].kind);
    const lift = found.picked[0];
    try testing.expect(lift.elements > 0);
    try testing.expect(lift.elements <= generatedNetCopperCount(baseline, .{}, lift.net_i));
    // The rip granularity follows the nomination: corridor-lifted, not dropped.
    const masks = try unblockMasks(&run);
    unblockMarkPick(&run, lift, masks);
    try testing.expect(masks.lifted[lift.net_i] and masks.selected[lift.net_i]);
    try testing.expect(!masks.dropped[lift.net_i]);
    // A lifted net still has to come back CONNECTED, so it is named in the
    // transaction's own all-or-nothing test alongside the target.
    const named = try unblockNamed(&run, targets[0], found.picked);
    try testing.expect(named.len >= 2);

    // One whole round, built and judged exactly as the first transaction is: the
    // wall is pads, so no corridor this lift frees can close the target, and the
    // round rolls back with the board byte-for-byte where it was.
    const window = clock.nanoTimestamp() + deepen_window_ns;
    const round = try unblockDeepenRound(&run, targets[0], found.picked, window);
    try testing.expect(!round.accepted);
    try expectUnblockCopperIdentical(baseline, run.baseline);
    run.lim = target_unblock_limits;

    // And the ladder scopes that authority to ITSELF, on every way out. Entered
    // with the remainder already owed to the targets behind this one, it yields
    // without a round — and the switch is off again behind it, so every
    // transaction outside a round judges rank exactly as it did before.
    const still_open = [_][]const u8{"TARGET"};
    const produced = router.RouteResult{
        .tracks = baseline.tracks,
        .vias = baseline.vias,
        .routed = baseline.routed,
        .total = baseline.total,
        .failed = &still_open,
    };
    const crowded = UnblockShare{ .board_deadline_ns = timed.stop.deadline_ns, .targets_left = 1_000 };
    try testing.expect((try unblockDeepen(&run, targets[0], &.{}, produced, crowded)) == null);
    try testing.expect(!run.lim.negotiate.outranking);
    try expectUnblockCopperIdentical(baseline, run.baseline);
    try testing.expectEqual(@as(usize, 0), (try unblockBlockers(&run, targets[0])).len);
    // A clock-free run never enters the ladder at all, so no corpus board can
    // reach the negotiation.
    run.options = .{};
    try testing.expect((try unblockDeepen(&run, targets[0], &.{}, produced, .{
        .board_deadline_ns = 0,
        .targets_left = 1,
    })) == null);
}

// spec: serve/route-plan - a guided corridor retry's gate is judged against the board's clock, not the per-net route slice that has already expired
test "a guided retry gates on the board clock, not its own expired slice" {
    const far = clock.nanoTimestamp() + 60 * clock.ns_per_s;
    var base = route_policy.Options{};
    base.stop.deadline_ns = far;
    // What the corridor route runs under: a slice that is over by the time the
    // route returns. Gating with THESE stop conditions cancels every candidate.
    var retry = base;
    retry.stop.deadline_ns = 1;
    const gate_options = guidedGateOptions(retry, base);
    try testing.expectEqual(far, gate_options.stop.deadline_ns);
    // Everything else about the retry — its scope above all — is preserved.
    try testing.expectEqual(retry.effort, gate_options.effort);
}

// spec: serve/route-plan - the topology prune judges a round's damage as soon as it lands, since pruning only removes copper
test "a prune round's connectivity damage is judged as soon as it lands" {
    // Pruning only removes copper, so connectivity is monotone: a round's
    // damage is final and the early check sees it at full strength. What the
    // prune does about it is per net (see the salvage test below); the whole
    // plan is still rejected when the loss cannot be attributed.
    const before = fab_readiness.Tally{ .routed = 98, .total = 109, .open = &.{} };
    try testing.expect(connectivityLost(before, .{ .routed = 91, .total = 109, .open = &.{} }));
    try testing.expect(!connectivityLost(before, .{ .routed = 98, .total = 109, .open = &.{} }));
    // A net that stops being routable at all is not a tidier board either.
    try testing.expect(connectivityLost(before, .{ .routed = 98, .total = 108, .open = &.{} }));
}

/// Does the whole-board topology scan offer a removable track finding on
/// `net`? The salvage test asserts this as a precondition so its fixture
/// cannot pass vacuously on copper the prune never targeted.
fn topologyOffersTrackOn(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    net: i32,
) std.mem.Allocator.Error!bool {
    var offered = false;
    for (drc_rules.checkTopologyFilled(arena, .{
        .placement = placement,
        .routed = routed,
        .clearance = 0,
        .zones = try route_close.userZones(arena, placement, &.{}),
    })) |finding| {
        if (removableTrackFinding(finding) and finding.who.net_a == net and finding.who.track_a >= 0) offered = true;
    }
    return offered;
}

/// How many stored tracks does `net` still have?
fn trackCountOn(tracks: []const router.Track, net: i32) usize {
    var count: usize = 0;
    for (tracks) |t| count += @intFromBool(t.net == net);
    return count;
}

// spec: serve/route-plan - a prune round that opens a net hands that net's copper back untouched and freezes it for the remaining rounds, keeping every removal the fabrication oracle agreed with
test "a prune round that opens one net gives that net back and keeps the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 3 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 3 },
    };
    const safe_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const held_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SAFE", .pins = &safe_pins },
        .{ .name = "VIA_HELD", .pins = &held_pins },
    };
    var placement = fixturePlacement(&parts, &nets);
    placement.maxy = 3.5;
    // SAFE carries a trunk plus a two-section alternate path: genuinely
    // redundant, and the two oracles agree that one path may go.
    //
    // VIA_HELD is where they disagree. Its run stops short of R4's land and
    // reaches it only through a barrel dropped beside it. The fabrication
    // graph joins a pad to a via that lands on it, so the net is CONNECTED;
    // the support graph reaches a barrel only through the copper on it and
    // this one is not even live, so the run looks like copper joining a single
    // pad to nothing and every section of it reads as deletable.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = 1, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 3, .x2 = 2.7, .y2 = 3, .layer = 0, .width = 0.2, .net = 1 },
    };
    const vias = [_]router.Via{.{ .x = 2.7, .y = 3, .dia = 0.5, .drill = 0.2, .net = 1 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 2, .total = 2 };

    // Both nets start connected — the disagreement is only about what may go.
    const before = try fab_readiness.routableTally(arena, placement, .{ .tracks = &tracks, .vias = &vias });
    try testing.expectEqual(@as(usize, 2), before.routed);
    try testing.expectEqual(@as(usize, 2), before.total);
    // …and the fixture really does reproduce the disagreement rather than
    // passing vacuously: the topology scan names VIA_HELD's only run as safe
    // to delete, so a prune that took it at its word WOULD open the net.
    try testing.expect(try topologyOffersTrackOn(arena, placement, routed, 1));

    const outcome = try pruneGateTopologyOutcome(arena, placement, .{}, routed, .{});
    try testing.expect(outcome.kept);
    // VIA_HELD came back byte-identical, barrel and all…
    var held: usize = 0;
    for (outcome.result.tracks) |t| {
        if (t.net != 1) continue;
        try testing.expect(std.meta.eql(t, tracks[3]));
        held += 1;
    }
    try testing.expectEqual(@as(usize, 1), held);
    try testing.expectEqual(@as(usize, 1), outcome.result.vias.len);
    // …while SAFE still lost its alternate path. Whole-plan rejection would
    // have handed back all three of its sections to protect the other net.
    try testing.expectEqual(@as(usize, 1), trackCountOn(outcome.result.tracks, 0));
    // And the board the gate returns is no less connected than the one it got.
    const after = try fab_readiness.routableTally(arena, placement, .{
        .tracks = outcome.result.tracks,
        .vias = outcome.result.vias,
    });
    try testing.expect(!connectivityLost(before, after));
}

// spec: serve/route-plan - the board is topology-pruned exactly once, after the residual ladder has converged, so cleanup never rewrites the copper a functional pass is still planning against
test "the gate passes carry no topology prune and the finish spends exactly one" {
    // The prune used to run inside every gate pass. Two things then went
    // wrong on a large board: the reconcile ladder re-planned against copper
    // the prune had just rewritten, and `drcSafeResult` — which sits directly
    // behind the prune in a gate — turned any rule a removal tripped into the
    // whole net's copper being dropped. Measured on barracuda: `17 -> 8
    // failed` with the prune inert versus `17 -> 26 failed` with it live.
    const source = @embedFile("route_plan.zig");
    const gate_body_start = std.mem.indexOf(u8, source, "fn gateConfigured(").?;
    const gate_body_end = std.mem.indexOf(u8, source[gate_body_start..], "\n}\n").? + gate_body_start;
    try testing.expect(std.mem.indexOf(u8, source[gate_body_start..gate_body_end], "pruneGateTopology") == null);
    // …and the one remaining call is the finish's, after the ladder converged.
    const finish_start = std.mem.indexOf(u8, source, "pub fn finishLoweredCandidate(").?;
    const finish_end = std.mem.indexOf(u8, source[finish_start..], "\n}\n").? + finish_start;
    try testing.expect(std.mem.indexOf(u8, source[finish_start..finish_end], "pruneGateTopology") != null);
}

// spec: serve/route-plan - a prune that leaves a net carrying more requirement damage than it arrived with hands that net's copper back, and rejects the whole plan when the damage outlives the salvage budget
test "a prune is judged on requirement damage, not connectivity alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // The families a removal can break while every net stays one piece. The
    // topology scan reports none of them, which is why a prune judged on
    // `topo 0->0` drove barracuda's bypass_open 2 -> 30 and gvtf 1 -> 21.
    try testing.expect(removalDamageKind(.net_open));
    try testing.expect(removalDamageKind(.bypass_open));
    try testing.expect(removalDamageKind(.ground_via_distance));
    try testing.expect(removalDamageKind(.copper_stub));
    try testing.expect(!removalDamageKind(.dangling_copper));
    try testing.expect(!removalDamageKind(.single_layer_via));

    // A census counts them per net, and only a net that got WORSE is handed
    // back — one that arrived damaged keeps whatever cleanup it earned.
    const findings = [_]drc.Violation{
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .bypass_open, .who = .{ .net_a = 0 } },
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .dangling_copper, .who = .{ .net_a = 0 } },
    };
    const census = try damageCensus(arena, placement, &findings);
    try testing.expectEqual(@as(usize, 1), census[0]);

    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    var list: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    const frozen = try arena.alloc(bool, placement.nets.len);
    @memset(frozen, false);
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    // Removals emptied the net and its damage rose: the copper comes back.
    try testing.expectEqual(@as(usize, 1), try salvageDamagedNets(
        .{ .alloc = arena, .routed = routed, .tracks = &list, .vias = &vias, .frozen = frozen },
        &.{0},
        &.{1},
    ));
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expect(std.meta.eql(list.items[0], tracks[0]));
    try testing.expect(frozen[0]);
    // A second look at the same net hands nothing back — it is already frozen,
    // which is what bounds the salvage loop.
    try testing.expectEqual(@as(usize, 0), try salvageDamagedNets(
        .{ .alloc = arena, .routed = routed, .tracks = &list, .vias = &vias, .frozen = frozen },
        &.{0},
        &.{1},
    ));
}

// spec: serve/route-plan - a prune whose damage cannot be attributed net by net still rejects the whole plan, so the connectivity guarantee never weakens
test "an unattributable prune loss falls back to rejecting the whole plan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    var list: std.ArrayList(router.Track) = .empty;
    try list.appendSlice(arena, &tracks);
    var vias: std.ArrayList(router.Via) = .empty;
    const frozen = try arena.alloc(bool, placement.nets.len);
    @memset(frozen, false);
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    const base = Salvage{
        .alloc = arena,
        .placement = placement,
        .routed = routed,
        .tracks = &list,
        .vias = &vias,
        .frozen = frozen,
        .before = .{ .routed = 1, .total = 1 },
        .running = .{ .routed = 0, .total = 1 },
    };
    // A net that stopped being routable at all is not a per-net verdict.
    var shrunk = base;
    shrunk.running = .{ .routed = 0, .total = 0, .open = &.{"SIG"} };
    try testing.expect(try salvageOpenedNets(shrunk) == null);
    // Nor is a loss whose open name belongs to no net of this placement.
    var foreign = base;
    foreign.running = .{ .routed = 0, .total = 1, .open = &.{"NOT_A_NET"} };
    try testing.expect(try salvageOpenedNets(foreign) == null);
    // Nor a net already handed back once that is open again.
    frozen[0] = true;
    var repeat = base;
    repeat.running = .{ .routed = 0, .total = 1, .open = &.{"SIG"} };
    try testing.expect(try salvageOpenedNets(repeat) == null);
    frozen[0] = false;
    // A clean attribution restores the frozen net's copper in its original
    // position — the survivors are a subsequence, so replaying rebuilds order.
    var named = base;
    named.running = .{ .routed = 0, .total = 1, .open = &.{"SIG"} };
    list.clearRetainingCapacity();
    const report = (try salvageOpenedNets(named)).?;
    try testing.expectEqual(@as(usize, 1), report.opened);
    try testing.expectEqualStrings("SIG", report.first);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expect(std.meta.eql(list.items[0], tracks[0]));
}

// spec: serve/route-plan - a gate pass stopped by the ladder's reserve boundary keeps the hops it already landed and ends the ladder, rather than discarding the pass
test "a gate pass that ran into the reserve keeps its copper" {
    const track = [_]router.Track{.{ .net = 0, .layer = 0, .width = 0.2, .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0 }};
    const complete = router.RouteResult{ .tracks = &track, .vias = &.{}, .routed = 1, .total = 1 };
    // An ordinary pass is handed straight back and the ladder continues.
    const ordinary = expiredPassCopper(complete, false).?;
    try testing.expect(!ordinary.last);
    try testing.expectEqual(@as(usize, 1), ordinary.result.tracks.len);

    var expired = complete;
    expired.cancelled = true;
    const kept = expiredPassCopper(expired, false).?;
    // Its copper survives, the slice-level flag is cleared so the board is not
    // reported as an aborted route, and it is the ladder's last pass.
    try testing.expectEqual(@as(usize, 1), kept.result.tracks.len);
    try testing.expect(!kept.result.cancelled);
    try testing.expect(kept.last);

    // A user cancel is a different thing entirely: hand the partial board back.
    try testing.expect(expiredPassCopper(expired, true) == null);
}

// spec: serve/route-plan - the wide unblock slice affords a cross-board scoped re-route, so a time verdict means the maze was tried, not truncated
test "the wide unblock slice affords a cross-board re-route" {
    try testing.expect(unblock_wide_limits.slice.max_ns >= 45 * clock.ns_per_s);
}

// spec: serve/route-plan - both residual head phases run against a deadline pulled in by the tail the per-target unblock pass needs, sized from that pass's own entry census, bounded by a share of what the residual has left, and zero on a clock-free board
test "the residual head phases run under the unblock pass's reserve" {
    // A clock-free board reserves nothing and its options are handed back
    // unchanged, which is what keeps every bench and corpus route identical.
    const untimed = route_policy.Options{};
    try testing.expectEqual(@as(i128, 0), headOptions(untimed, 90 * clock.ns_per_s).stop.deadline_ns);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const open = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .failed = &.{"SIG"} };
    try testing.expectEqual(@as(i128, 0), try unblockReserveNs(arena_state.allocator(), placement, untimed, open));

    // A timed board hands its head phases a deadline pulled in by exactly the
    // reserve, while the pass itself keeps the board's own.
    const deadline = clock.nanoTimestamp() + 240 * clock.ns_per_s;
    const timed = route_policy.Options{ .stop = .{ .deadline_ns = deadline } };
    const head = headOptions(timed, 90 * clock.ns_per_s);
    try testing.expectEqual(deadline - 90 * clock.ns_per_s, head.stop.deadline_ns);
    try testing.expectEqual(deadline, timed.stop.deadline_ns);

    // A board with nothing open reserves nothing: the tail is for targets.
    const closed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(i128, 0), try unblockReserveNs(arena_state.allocator(), placement, timed, closed));

    // Both bounds are real: the floor's own ceiling, and the share of what is
    // left — which must leave the head phases a working share of any budget.
    try testing.expect(unblock_reserve_max_ns <= 100 * clock.ns_per_s);
    try testing.expect(unblock_reserve_share_num * 100 <= 55 * unblock_reserve_share_den);
    // The ceiling is above the widest slice the tier's own arithmetic can ask
    // for on this corpus, so it bounds a pathology rather than the normal case.
    try testing.expect(unblock_reserve_max_ns >=
        target_unblock.phaseReserve(unblock_wide_limits, 55.27, unblock_reserve_max_ns));
}

/// A residual long enough that the share cap is never the bound, so a pricing
/// assertion is about the PLAN rather than about the cap.
const uncapped_residual_ns: i128 = 10_000 * clock.ns_per_s;

// spec: serve/route-plan - the residual tail is priced from the census the phase is entered with, one breadth probe per distinct open net plus room for the deep ladders funded behind them, and a census with no target, no open net or no wall clock left prices no tail at all
test "the unblock reserve is priced from the census the phase is entered with" {
    // A probe is priced at BOTH of its clocks: the slice its scoped re-route is
    // clamped to, plus the window its gate may reconcile in behind that slice.
    // Pricing the slice alone bought half a probe, and round 1 then overran the
    // whole reserve — which is exactly the round-2 starvation this tail exists
    // to prevent.
    try testing.expectEqual(
        target_unblock_limits.slice.max_ns + gate_window_ns,
        unblock_breadth_probe_ns,
    );
    try testing.expect(unblock_breadth_probe_ns > target_unblock_limits.slice.max_ns);

    // barracuda's own entry census under the 2026-08-18 layer contract: eight
    // planned targets over six distinct open nets.
    const barracuda = unblockReservePlan(8, 6, 55.27, uncapped_residual_ns);
    try testing.expectEqual(@as(usize, 6), barracuda.probes);
    try testing.expectEqual(unblock_reserve_ladders, barracuda.ladders);
    try testing.expectEqual(6 * unblock_breadth_probe_ns, barracuda.breadthNs());
    // 6 x 30 s of breadth beside 2 x 45 s of depth: the reserve now holds a
    // WHOLE probe for each open net, so round 1 spending its share is no longer
    // the same event as round 2 losing its ladders.
    try testing.expectEqual(180 * clock.ns_per_s, barracuda.breadthNs());
    try testing.expectEqual(90 * clock.ns_per_s, barracuda.depthNs());
    try testing.expectEqual(2 * unblock_ladder_price_ns, barracuda.depthNs());
    try testing.expectEqual(barracuda.breadthNs() + barracuda.depthNs(), barracuda.reserve_ns);

    // Fewer open nets is a smaller bill, term by term — the price tracks the
    // census rather than being the same number on every board.
    const fewer = unblockReservePlan(3, 2, 55.27, uncapped_residual_ns);
    try testing.expectEqual(@as(usize, 2), fewer.probes);
    try testing.expect(fewer.breadthNs() < barracuda.breadthNs());
    try testing.expect(fewer.reserve_ns < barracuda.reserve_ns);

    // A single target never reaches the breadth round at all, so it is never
    // charged for one; it is still owed the ladder it will actually run.
    const lone = unblockReservePlan(1, 1, 55.27, uncapped_residual_ns);
    try testing.expectEqual(@as(usize, 0), lone.probes);
    try testing.expectEqual(@as(usize, 1), lone.ladders);

    // Nothing to fund, or nothing to fund it out of, prices nothing at all.
    try testing.expectEqual(@as(i128, 0), unblockReservePlan(0, 0, 55.27, uncapped_residual_ns).reserve_ns);
    try testing.expectEqual(@as(i128, 0), unblockReservePlan(8, 0, 55.27, uncapped_residual_ns).reserve_ns);
    try testing.expectEqual(@as(i128, 0), unblockReservePlan(8, 6, 55.27, 0).reserve_ns);
}

// spec: serve/route-plan - a demand-priced residual tail never falls below the single-corridor price it replaced, so no board reserves less of its residual than it did before the tail was priced against a plan
test "the unblock reserve never drops below the corridor price it replaced" {
    const corridor = target_unblock.phaseReserve(unblock_wide_limits, 55.27, unblock_reserve_max_ns);
    // One target over one net plans a single ladder and no breadth round, which
    // is worth less than that corridor — so the FLOOR is what carries the tail,
    // exactly as it did before the plan was priced.
    const lone = unblockReservePlan(1, 1, 55.27, uncapped_residual_ns);
    try testing.expectEqual(corridor, lone.floor_ns);
    try testing.expect(lone.depthNs() < corridor);
    try testing.expectEqual(corridor, lone.reserve_ns);

    // The floor never SHRINKS a bigger plan: a census owing six probes and two
    // ladders outprices even the widest single corridor.
    const many = unblockReservePlan(8, 6, 55.27, uncapped_residual_ns);
    try testing.expect(many.reserve_ns > many.floor_ns);

    // The guarantee itself, at three residual sizes: the priced tail is never
    // below the flat single-corridor tail (its own share of the residual, half)
    // that this seam replaced.
    try testing.expect(unblockReservePlan(8, 6, 55.27, 60 * clock.ns_per_s).reserve_ns >=
        @min(corridor, 30 * clock.ns_per_s));
    try testing.expect(unblockReservePlan(8, 6, 55.27, 200 * clock.ns_per_s).reserve_ns >=
        @min(corridor, 100 * clock.ns_per_s));
    try testing.expect(unblockReservePlan(8, 6, 55.27, 600 * clock.ns_per_s).reserve_ns >=
        @min(corridor, 300 * clock.ns_per_s));
}

// spec: serve/route-plan - a residual tail claims no more than its declared share of what the residual has left, so the gate ladder and the guided retries keep a working share of even a budget the tail's own demand outgrows
test "the unblock reserve leaves the head phases their share of the residual" {
    // The plan wants six probes and two ladders; a 200 s residual does not have
    // that to give, and the cap is what says so.
    const residual = 200 * clock.ns_per_s;
    const plan = unblockReservePlan(8, 6, 55.27, residual);
    try testing.expect(plan.breadthNs() + plan.depthNs() > plan.reserve_ns);
    try testing.expectEqual(
        @divTrunc(residual * unblock_reserve_share_num, unblock_reserve_share_den),
        plan.reserve_ns,
    );
    // What the head phases keep out of it, stated as the guarantee rather than
    // as the arithmetic: never less than 45% of the residual.
    try testing.expect((residual - plan.reserve_ns) * 100 >= 45 * residual);
}

// spec: serve/route-plan - residual-phase diagnostics print at info level, so a ReleaseSafe binary's wide and pair tiers stay observable
test "residual diagnostics are info level" {
    try testing.expect(routeLog == std.log.info);
}

// spec: serve/route-plan - a timed gate call bounds its reconcile with a pass slice that stops new hops without cancelling the board; an untimed run stays unsliced
test "a gate call's reconcile is sliced without cancelling the board" {
    try testing.expectEqual(@as(i128, 0), gateSliceDeadline(.{}));
    const far = clock.nanoTimestamp() + 300 * clock.ns_per_s;
    const sliced = gateSliceDeadline(.{ .deadline_ns = far });
    try testing.expect(sliced != 0 and sliced < far);

    // An already-expired slice stops hop work yet the result is NOT cancelled —
    // the first attempt shrank the board deadline instead, and reconcile's
    // expiry aborted the whole residual pipeline at 99 s on barracuda.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const out = try route_close.reconcile(arena, placement, .{}, claim, &.{}, .{
        .pass = .{ .slice_deadline_ns = 1 },
    });
    try testing.expect(!out.result.cancelled);
    try testing.expectEqual(@as(usize, 0), out.hops_kept);
}

// spec: serve/route-plan - the bounded broad seed phase excludes repair-only waypoint corridors
test "broad waypoint seeding excludes deferred repair corridors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "BROAD", .pins = &fixture_pins },
        .{ .name = "REPAIR", .pins = &.{} },
    };
    const placement = fixturePlacement(&parts, &nets);
    const points = [_]route_policy.Waypoint{.{ .x = 1, .y = 0, .layer = 0 }};
    const policies = [_]route_policy.NetPolicy{
        .{ .waypoints = &points },
        .{ .wave = .{ .seed_first = true, .repair_waypoints = &points } },
    };
    const selected = (try broadWaypointSeedMask(arena, placement, .{
        .net = &policies,
        .stop = .{ .deadline_ns = 2 },
    })).?;
    try testing.expectEqualSlices(bool, &.{ true, false }, selected);
}

// spec: serve/route-plan - repair-only waypoints do not replace ordinary broad-pass waypoints
test "the broad pass preserves ordinary waypoints beside a repair corridor" {
    const points = [_]route_policy.Waypoint{.{ .x = 1, .y = 2, .layer = 0 }};
    const policies = [_]route_policy.NetPolicy{
        .{ .wave = .{ .seed_first = true, .repair_waypoints = &points }, .waypoints = &points },
        .{ .waypoints = &points },
    };
    const broad = try initialPassOptions(testing.allocator, .{
        .net = &policies,
        .effort = .standard,
    });
    try testing.expectEqual(@as(usize, 1), broad.net[0].waypoints.len);
    try testing.expectEqual(@as(usize, 1), broad.net[1].waypoints.len);

    const interactive = try initialPassOptions(testing.allocator, .{
        .net = &policies,
        .effort = .one_shot,
    });
    try testing.expectEqual(@as(usize, 1), interactive.net[0].waypoints.len);
}

// spec: serve/route-plan - a lowering failure degrades a read-only surface to plan-less routing
test "allocation failure degrades to empty options" {
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const waves = [_]env_mod.PlanWave{.{ .name = "outer-only", .rest = true }};
    const block = fixtureBlock(.{ .route = &waves });
    const options = lowerOrEmpty(
        testing.failing_allocator,
        &block,
        fixturePlacement(&parts, &nets),
    );
    try testing.expectEqual(@as(usize, 0), options.net.len);
}

// spec: serve/route-plan - an override plan routes through the experiment seam and surfaces its unknown-target warnings
test "override plan routes through the experiment seam with warnings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // The block carries no authored plan; the override names a net that exists
    // nowhere — it must reach the seam, warn, and still route the real net.
    const block = fixtureBlock(null);
    const waves = [_]env_mod.PlanWave{.{ .name = "exp", .nets = &.{"NONEXISTENT"} }};
    const override: env_mod.PcbPlanSpec = .{ .route = &waves };
    const exp = try routeExperiment(arena, &block, placement, .{}, .{ .plan = override });
    try testing.expect(exp.plan_applied);
    try testing.expectEqual(@as(usize, 1), exp.warnings.len);
    try testing.expectEqualStrings("plan-unknown-name", exp.warnings[0].kind);
    try testing.expectEqual(@as(usize, 1), exp.result.routed);
}

// spec: serve/route-plan - an experiment run honors the caller's effort override and routes from the layout's retained pours
test "an experiment honors an effort override and grows from retained pours" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const block = fixtureBlock(null);

    // No override: the seam's historical bare-copper, authored-effort run.
    const plain = try routeExperiment(arena, &block, placement, .{}, .{});
    try testing.expectEqual(route_policy.Effort.standard, plain.effort);
    try testing.expect(totalTrackMm(plain.result.tracks) > 2.0);

    // The caller's effort reaches the router options, and a pour covering both
    // pads is retained as same-net source copper (so only the pad stubs are
    // drawn) — the same retention `routePlannedScoped` gives the describe path.
    const poly = [_][2]f64{
        .{ -0.3, -0.3 },
        .{ 3.3, -0.3 },
        .{ 3.3, 0.3 },
        .{ -0.3, 0.3 },
    };
    const zones = [_]route_policy.ExistingZone{.{ .polygon = &poly, .layer = 0, .net = 0 }};
    const poured = try routeExperiment(arena, &block, placement, .{}, .{
        .effort = .one_shot,
        .zones = &zones,
    });
    try testing.expectEqual(route_policy.Effort.one_shot, poured.effort);
    try testing.expectEqual(@as(usize, 1), poured.result.routed);
    try testing.expect(totalTrackMm(poured.result.tracks) < 0.5);
}

// spec: serve/route-plan - lowering with waves returns the resolved route waves beside the per-net options they produced
test "lowerWithWaves returns the waves the options came from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF", .pins = &fixture_pins },
        .{ .name = "SIG", .pins = &.{} },
    };
    const waves = [_]env_mod.PlanWave{
        .{ .name = "first", .nets = &.{"RF"} },
        .{ .name = "rest", .rest = true },
    };
    const block = fixtureBlock(.{ .route = &waves });
    const lw = try lowerWithWaves(arena, &block, fixturePlacement(&parts, &nets));
    try testing.expectEqual(@as(usize, 2), lw.waves.len);
    try testing.expectEqualStrings("first", lw.waves[0].name);
    try testing.expectEqualStrings("rest", lw.waves[1].name);
    // The wave a net's priority names is `waves.len - priority` — the identity a
    // caller rendering "reorder these wave forms" depends on.
    try testing.expectEqual(@as(u32, 2), lw.options.net[0].wave.priority);
    try testing.expectEqualStrings("first", lw.waves[lw.waves.len - lw.options.net[0].wave.priority].name);
}

// spec: serve/route-plan - a caller's own lowered options route through the diagnostic seam and come back gated by the connectivity oracle
test "routeLoweredDiagnostic gates a caller's own options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const policies = [_]route_policy.NetPolicy{.{ .wave = .{ .priority = 3 }, .allowed_layers = 0b01 }};
    const pd = try routeLoweredDiagnostic(arena, placement, .{}, .{ .net = &policies });
    // `routed`/`total` are the oracle's answer, not the router's attempt count.
    try testing.expectEqual(@as(usize, 1), pd.result.routed);
    try testing.expectEqual(@as(usize, 1), pd.result.total);
    try testing.expectEqual(@as(usize, 0), pd.stuck.len);
    // The caller's allowed-layer mask still applies — nothing on B.Cu.
    try testing.expectEqual(@as(f64, 0), trackMmOnLayer(pd.result.tracks, 1));
}

// spec: serve/route-plan - the field route retries oracle-open nets against frozen completed copper and removes generated fragments that remain open
test "field residual cleanup removes failed generated copper but preserves retained copper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "OPEN", .pins = &fixture_pins },
        .{ .name = "DONE", .pins = &.{} },
    };
    const placement = fixturePlacement(&parts, &nets);
    const kept = router.Track{ .x1 = 0, .y1 = 0, .x2 = 0.25, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const generated = router.Track{ .x1 = 0.25, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const done = router.Track{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 };
    const tracks = [_]router.Track{ kept, generated, done };
    const existing = [_]route_policy.ExistingTrack{trackAsExisting(kept)};
    try testing.expectEqual(@as(usize, 1), generatedNetCopperCount(.{
        .tracks = &tracks,
        .vias = &.{},
        .routed = 1,
        .total = 2,
    }, .{ .existing_tracks = &existing }, 0));
    const failed = [_][]const u8{"OPEN"};
    const selected = [_]bool{ true, false };
    const cleaned = try stripGeneratedFailures(arena, placement, .{ .existing_tracks = &existing }, &selected, .{
        .tracks = &tracks,
        .vias = &.{},
        .routed = 1,
        .total = 2,
        .failed = &failed,
    });
    try testing.expectEqual(@as(usize, 2), cleaned.tracks.len);
    try testing.expect(sameTrack(cleaned.tracks[0], existing[0]));
    try testing.expectEqual(@as(i32, 1), cleaned.tracks[1].net);

    // The cluster uses an explicit mask because its blocker was complete, not
    // listed in `failed`. It still removes only generated copper: the caller's
    // retained segment on that same net survives unchanged.
    const dropped = [_]bool{ true, false };
    const blocker_cleaned = try stripGeneratedMask(arena, placement, .{ .existing_tracks = &existing }, &dropped, .{
        .tracks = &tracks,
        .vias = &.{},
        .routed = 1,
        .total = 2,
    });
    try testing.expectEqual(@as(usize, 2), blocker_cleaned.tracks.len);
    try testing.expect(sameTrack(blocker_cleaned.tracks[0], existing[0]));
    try testing.expectEqual(@as(i32, 1), blocker_cleaned.tracks[1].net);

    const one_via = [_]router.Via{.{ .x = 0, .y = 0, .dia = 0.5, .drill = 0.25, .net = 0 }};
    const short = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const long = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 25, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(!residualBetter(
        .{ .tracks = &long, .vias = &.{}, .routed = 1, .total = 1 },
        .{ .tracks = &short, .vias = &one_via, .routed = 1, .total = 1 },
    ));
}

// spec: serve/route-plan - a field residual cluster is capped at three open seeds and formed deterministically from shared blocker nominations
test "field residual cluster groups shared nominations under the seed cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var seeds = [_]FieldClusterSeed{
        .{ .net_i = 0 },
        .{ .net_i = 1 },
        .{ .net_i = 2 },
        .{ .net_i = 3 },
    };
    for (&seeds) |*seed| try seed.nominations.nearer(arena, 9, 0.25);
    const group = firstNominatedFieldCluster(&seeds).?;
    try testing.expectEqual(field_cluster_max_seeds, group.len);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, group.items());
    try testing.expectEqual(@as(usize, 6), field_cluster_limits.max_nets);
    try testing.expectEqual(@as(usize, 96), field_cluster_limits.max_total_elements);
}

// spec: serve/route-plan - static escape contention can cluster open seeds without emitting guides or reservations
test "field residual cluster uses escape contention only as a fallback relation" {
    const seeds = [_]FieldClusterSeed{
        .{ .net_i = 0 },
        .{ .net_i = 1 },
        .{ .net_i = 2 },
        .{ .net_i = 3 },
    };
    const fan = [_]usize{ 3, 1, 2, 0 };
    const findings = [_]escape_assign.Contention{.{
        .hub = "J1",
        .nets = &fan,
        .seated = 1,
        .lanes = 1,
        .bands = 1,
        .corridor = .{},
    }};
    const group = firstEscapeFieldCluster(&seeds, &findings).?;
    try testing.expectEqual(field_cluster_max_seeds, group.len);
    // Seed/oracle order, not the fan's input order, is the deterministic tie.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, group.items());
}

// spec: serve/route-plan - a field residual cluster never trades a previously complete net for one of its old airwires
test "field residual cluster accepts only a strict subset of the old open set" {
    const before_open = [_][]const u8{ "A", "B", "C" };
    const fewer = [_][]const u8{ "B", "C" };
    const traded = [_][]const u8{ "B", "NEW" };
    const same = [_][]const u8{ "A", "B", "C" };
    const baseline = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3, .failed = &before_open };
    try testing.expect(strictResidualGain(
        .{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 3, .failed = &fewer },
        baseline,
    ));
    try testing.expect(!strictResidualGain(
        .{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 3, .failed = &traded },
        baseline,
    ));
    try testing.expect(!strictResidualGain(
        .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3, .failed = &same },
        baseline,
    ));
}

// spec: serve/route-plan - rerouting a residual net replaces its shape and search diagnostics while retaining untouched nets' metadata
test "field residual metadata replaces only rerouted cluster nets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old_arcs = [_]router.Arc{
        .{ .p1 = .{ 0, 0 }, .pm = .{ 0.5, 0.5 }, .p2 = .{ 1, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .p1 = .{ 2, 0 }, .pm = .{ 2.5, 0.5 }, .p2 = .{ 3, 0 }, .layer = 0, .width = 0.2, .net = 1 },
    };
    const new_arcs = [_]router.Arc{.{
        .p1 = .{ 0, 0 },
        .pm = .{ 0.5, -0.5 },
        .p2 = .{ 1, 0 },
        .layer = 0,
        .width = 0.2,
        .net = 0,
    }};
    const old_bends = [_]router.SharpBend{
        .{ .x = 0.5, .y = 0.5, .layer = 0, .net = 0, .radius = 0.1, .required = 0.2 },
        .{ .x = 2.5, .y = 0.5, .layer = 0, .net = 1, .radius = 0.1, .required = 0.2 },
    };
    const new_bends = [_]router.SharpBend{.{
        .x = 0.5,
        .y = -0.5,
        .layer = 0,
        .net = 0,
        .radius = 0.15,
        .required = 0.2,
    }};
    const replaced = [_]bool{ true, false, false };
    const rerouted = [_]bool{ true, false, true };
    const old_limited = [_]usize{ 0, 1, 2 };
    const new_limited = [_]usize{0};
    const old_replayed = [_]usize{ 1, 2 };
    const new_replayed = [_]usize{0};
    const merged = try mergeResidualMetadata(arena, &replaced, &rerouted, .{
        .tracks = &.{},
        .vias = &.{},
        .arcs = &old_arcs,
        .sharp_bends = &old_bends,
        .search_limited = &old_limited,
        .reference_replayed = &old_replayed,
        .grid_scale = 0.5,
        .grid_overflow = true,
        .routed = 2,
        .total = 2,
    }, .{
        .tracks = &.{},
        .vias = &.{},
        .arcs = &new_arcs,
        .sharp_bends = &new_bends,
        .search_limited = &new_limited,
        .reference_replayed = &new_replayed,
        .grid_scale = 1,
        .routed = 2,
        .total = 2,
    });
    try testing.expectEqual(@as(usize, 2), merged.arcs.len);
    try testing.expectEqual(@as(i32, 1), merged.arcs[0].net);
    try testing.expectEqual(@as(i32, 0), merged.arcs[1].net);
    try testing.expectEqual(@as(f64, -0.5), merged.arcs[1].pm[1]);
    try testing.expectEqual(@as(usize, 2), merged.sharp_bends.len);
    try testing.expectEqual(@as(i32, 1), merged.sharp_bends[0].net);
    try testing.expectEqual(@as(i32, 0), merged.sharp_bends[1].net);
    try testing.expectEqual(@as(f64, -0.5), merged.sharp_bends[1].y);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, merged.search_limited);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, merged.reference_replayed);
    try testing.expectEqual(@as(f64, 0.5), merged.grid_scale);
    try testing.expect(merged.grid_overflow);
}

// spec: serve/route-plan - a field residual cluster accepts only candidates which preserve every frozen track and via instance exactly
test "field residual cluster verifies frozen copper as a multiset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const track = router.Track{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const via = router.Via{ .x = 1, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 };
    const tracks = [_]router.Track{ track, track };
    const vias = [_]router.Via{via};
    const expected_tracks = [_]route_policy.ExistingTrack{ trackAsExisting(track), trackAsExisting(track) };
    const expected_vias = [_]route_policy.ExistingVia{viaAsExisting(via)};
    const candidate = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };
    try testing.expect(try retainsExistingCopper(arena, candidate, &expected_tracks, &expected_vias, &.{}) == null);

    const short = router.RouteResult{ .tracks = tracks[0..1], .vias = &vias, .routed = 1, .total = 1 };
    try testing.expect(try retainsExistingCopper(arena, short, &expected_tracks, &expected_vias, &.{}) != null);
}

// spec: serve/route-plan - a field residual cluster declines caller-retained vias because the router-neutral copper surface cannot carry saved RF-fence provenance
test "field residual cluster declines opaque retained-via provenance" {
    const existing = [_]route_policy.ExistingVia{.{ .x = 1, .y = 2, .dia = 0.4, .drill = 0.2, .net = 0 }};
    try testing.expect(fieldClusterViaProvenanceSafe(.{}));
    try testing.expect(!fieldClusterViaProvenanceSafe(.{ .existing_vias = &existing }));
}

// ── Per-target unblock fixtures ─────────────────────────────────────────────

const unblock_thru_pad = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 },
};

fn appendUnblockPart(
    arena: std.mem.Allocator,
    parts: *std.ArrayList(optimizer.Part),
    ref: []const u8,
    at: [2]f64,
    pads: []const geometry.Pad,
) std.mem.Allocator.Error!void {
    try parts.append(arena, .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.35,
        .hh = 0.35,
        .pads = pads,
        .fallback = false,
        .x = at[0],
        .y = at[1],
    });
}

fn unblockPins(
    arena: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
) std.mem.Allocator.Error![]export_kicad.FlatPin {
    const pins = try arena.alloc(export_kicad.FlatPin, 2);
    pins[0] = .{ .ref_des = a, .pin = "1" };
    pins[1] = .{ .ref_des = b, .pin = "1" };
    return pins;
}

/// Two open two-terminal nets 3 mm and 9 mm apart plus a three-pad net, all with
/// no copper at all — the shape the attempt list is built from.
fn openTargetPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    var parts: std.ArrayList(optimizer.Part) = .empty;
    try appendUnblockPart(arena, &parts, "R1", .{ 0, 0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R2", .{ 3, 0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R3", .{ 0, 2 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R4", .{ 9, 2 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R5", .{ 0, 4 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R6", .{ 2, 4 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R7", .{ 4, 4 }, &route_plan_fixture_pad);
    const wide = try arena.alloc(export_kicad.FlatPin, 3);
    wide[0] = .{ .ref_des = "R5", .pin = "1" };
    wide[1] = .{ .ref_des = "R6", .pin = "1" };
    wide[2] = .{ .ref_des = "R7", .pin = "1" };
    const nets = try arena.alloc(optimizer.FlatNet, 3);
    nets[0] = .{ .name = "FAR", .pins = try unblockPins(arena, "R3", "R4") };
    nets[1] = .{ .name = "NEAR", .pins = try unblockPins(arena, "R1", "R2") };
    nets[2] = .{ .name = "WIDE", .pins = wide };
    var placement = fixturePlacement(parts.items, nets);
    placement.maxx = 9.5;
    placement.maxy = 4.5;
    return placement;
}

/// A target whose two pads sit on opposite sides of an unbroken through-hole
/// wall — copper on every layer, belonging to no net, so neither a maze path nor
/// a via crosses it — with two short foreign hops lying across its straight
/// line. The corridor nominates those hops, the transaction rips them, and the
/// target still cannot route: every attempt must roll back.
fn walledUnblockPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    var parts: std.ArrayList(optimizer.Part) = .empty;
    for (0..19) |i| {
        const x = -3.0 + 0.6 * @as(f64, @floatFromInt(i));
        const ref = try std.fmt.allocPrint(arena, "W{d}", .{i});
        try appendUnblockPart(arena, &parts, ref, .{ x, 0 }, &unblock_thru_pad);
    }
    try appendUnblockPart(arena, &parts, "V1", .{ 2.4, -3.0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "V2", .{ 2.4, 3.0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "A1", .{ 1.4, -2.4 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "A2", .{ 3.4, -2.4 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "B1", .{ 1.4, -1.2 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "B2", .{ 3.4, -1.2 }, &route_plan_fixture_pad);
    const nets = try arena.alloc(optimizer.FlatNet, 3);
    nets[0] = .{ .name = "TARGET", .pins = try unblockPins(arena, "V1", "V2") };
    nets[1] = .{ .name = "AAA", .pins = try unblockPins(arena, "A1", "A2") };
    nets[2] = .{ .name = "BBB", .pins = try unblockPins(arena, "B1", "B2") };
    var placement = fixturePlacement(parts.items, nets);
    placement.miny = -3.5;
    placement.maxx = 5.3;
    placement.maxy = 3.5;
    return placement;
}

/// The walled fixture with its two foreign runs given an authored
/// `(net-class … (priority …))` strictly above the target's.
///
/// The one board on which `outranks_seed` is the ONLY thing standing between a
/// stuck target and the copper in its corridor: both foreign nets are whole,
/// unpoured, un-paired, carry no RF discipline and no fence, and are short
/// enough to be ordinary `short_stub` picks — so every refusal but the rank
/// guard is out of the picture, and what a tier nominates here is exactly what
/// it will and will not negotiate about rank. Barracuda's `LOCK_DET` /
/// `V_24V_CLEAN` in miniature.
fn rankWalledUnblockPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    var placement = try walledUnblockPlacement(arena);
    // Reached through the placement's own field type: the serve layer may not
    // compile against `placement/net_rules.zig` directly (guardian's
    // `serve-placement-internals` rule), and the fixture needs no more of it
    // than the rule struct the model already carries.
    const rules = try arena.alloc(std.meta.Child(@TypeOf(placement.rules.net)), placement.nets.len);
    for (rules) |*rule| rule.* = .{ .priority = 4 };
    rules[0].priority = 0;
    placement.rules.net = rules;
    return placement;
}

/// The walled fixture with its two foreign hops REPLACED by one declared
/// differential pair whose coupled run lies straight across the target's
/// corridor.
///
/// The target is walled by through-hole PADS, so it cannot route however much
/// copper is vacated for it — which is the point: what this board proves is
/// that a transaction may nominate and rip a pair and still leave the board
/// byte-for-byte when it fails, with no leg stranded and no half-laid pair.
fn pairWalledUnblockPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    var parts: std.ArrayList(optimizer.Part) = .empty;
    for (0..19) |i| {
        const x = -3.0 + 0.6 * @as(f64, @floatFromInt(i));
        const ref = try std.fmt.allocPrint(arena, "W{d}", .{i});
        try appendUnblockPart(arena, &parts, ref, .{ x, 0 }, &unblock_thru_pad);
    }
    try appendUnblockPart(arena, &parts, "V1", .{ 2.4, -3.0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "V2", .{ 2.4, 3.0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "P1", .{ 0.4, -2.4 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "P2", .{ 4.4, -2.4 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "N1", .{ 0.4, -1.8 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "N2", .{ 4.4, -1.8 }, &route_plan_fixture_pad);
    const nets = try arena.alloc(optimizer.FlatNet, 3);
    nets[0] = .{ .name = "TARGET", .pins = try unblockPins(arena, "V1", "V2") };
    nets[1] = .{ .name = "REF_P", .pins = try unblockPins(arena, "P1", "P2") };
    nets[2] = .{ .name = "REF_N", .pins = try unblockPins(arena, "N1", "N2") };
    var placement = fixturePlacement(parts.items, nets);
    const pairs = try arena.alloc(std.meta.Child(@TypeOf(placement.diff_pairs)), 1);
    pairs[0] = .{ .p = 1, .n = 2, .gap = 0.4 };
    placement.diff_pairs = pairs;
    placement.miny = -3.5;
    placement.maxx = 5.3;
    placement.maxy = 3.5;
    return placement;
}

// spec: serve/route-plan - an unblock transaction nominates a declared differential pair only under the wide tier, rips both of its legs together, and rolls the whole board back byte-for-byte when the target still will not close
test "a pair blocker is nominated only wide, ripped whole, and rolled back whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try pairWalledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    // The premise: the pair is down and whole, the target is not.
    try testing.expect(namedFailed("TARGET", baseline.failed));
    try testing.expect(!namedFailed("REF_P", baseline.failed));
    try testing.expect(!namedFailed("REF_N", baseline.failed));

    const targets = try unblockTargets(arena, placement, .{}, baseline, .{});
    try testing.expectEqual(@as(usize, 1), targets.len);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };
    // The narrow tier sees the pair lying across the corridor and refuses it:
    // its restore is an ordinary maze walk, which would hand back two
    // independently routed legs where a class promised a coupled run.
    try testing.expectEqual(@as(usize, 0), (try unblockBlockers(&run, targets[0])).len);

    // The wide tier nominates it — as the dearest restore it admits, charged
    // for BOTH legs' copper.
    run.lim = unblock_wide_limits;
    const picked = try unblockBlockers(&run, targets[0]);
    try testing.expectEqual(@as(usize, 1), picked.len);
    try testing.expectEqual(vacate_policy.Kind.pair_recouple, picked[0].kind);
    const legs = generatedNetCopperCount(baseline, .{}, 1) + generatedNetCopperCount(baseline, .{}, 2);
    try testing.expectEqual(legs, picked[0].elements);

    // One nomination, two nets off the board: a leg ripped alone could not be
    // re-laid coupled at all, so the twin rides with it in the rip mask and in
    // the names the transaction must reconnect.
    const masks = try unblockMasks(&run);
    unblockMarkPick(&run, picked[0], masks);
    try testing.expect(masks.dropped[1] and masks.dropped[2]);
    try testing.expect(masks.selected[1] and masks.selected[2]);
    // Ripped WHOLE, never corridor-lifted: a pair leg is not plane-carried, and
    // half a leg is not a pair.
    try testing.expect(!masks.lifted[1] and !masks.lifted[2]);
    const named = try unblockNamed(&run, targets[0], picked);
    try testing.expectEqual(@as(usize, 3), named.len);

    // And the whole thing rolls back: the wall is pads, so no corridor a pair
    // vacates can close the target — and the pair is exactly where it was.
    const after = try retryTargetUnblock(arena, placement, .{}, .{}, baseline);
    try testing.expect(namedFailed("TARGET", after.failed));
    try expectUnblockCopperIdentical(baseline, after);
}

// spec: serve/route-plan - a transaction that re-laid a declared pair is refused when the pair comes back with a leg missing, a wider coupling gap or more skew than the coupled constructor equalizes to
test "a pair negotiation is refused when the pair comes back degraded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try pairWalledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = unblock_wide_limits,
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };
    // The board's own pair, coupled by the greedy pass: both legs down and
    // inside the coupling window, which is what every candidate is held to.
    try testing.expectEqual(@as(usize, 1), run.measured.pairs.len);
    const before = run.measured.pairs[0];
    try testing.expectEqual(@as(usize, 2), before.legs_with_copper);
    try testing.expectEqual(@as(usize, 0), before.uncoupled);

    const pick = [_]vacate_policy.Nomination{
        .{ .net_i = 1, .kind = .pair_recouple, .elements = 6, .dist = 0 },
    };
    // Held: the same pair back where it was, and a pair moved but still coupled.
    try testing.expect(unblockPairsHeld(&run, &pick, run.measured));
    try testing.expect(unblockPairsHeld(&run, &pick, .{ .pairs = &.{.{
        .legs_with_copper = 2,
        .skew_mm = before.skew_mm + target_unblock.pair_skew_slack_mm,
    }} }));
    // Refused: a leg that never came back, a run that fell out of the coupling
    // window, and two legs mazed independently — connected and fab-legal, and
    // precisely what the class forbids.
    for ([_]target_unblock.PairHealth{
        .{ .legs_with_copper = 1, .skew_mm = before.skew_mm },
        .{ .legs_with_copper = 2, .uncoupled = 1, .skew_mm = before.skew_mm },
        .{ .legs_with_copper = 2, .skew_mm = before.skew_mm + 0.9 },
    }) |after| {
        try testing.expect(!unblockPairsHeld(&run, &pick, .{ .pairs = &.{after} }));
    }
    // A transaction that named no pair is not held to any of it.
    const plain = [_]vacate_policy.Nomination{
        .{ .net_i = 1, .kind = .short_stub, .elements = 2, .dist = 0 },
    };
    try testing.expect(unblockPairsHeld(&run, &plain, .{ .pairs = &.{.{ .legs_with_copper = 0 }} }));
}

// spec: serve/route-plan - a plane-carried unblock blocker is lifted only where it crosses the target's corridor, its copper elsewhere stays byte-for-byte, and only a tier that declares the lift lifts at all
test "a corridor lift takes the channel copper and leaves the stitch field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    // One vertical corridor, and a plane-carried net (index 1) with copper on
    // both sides of it: two hookups and two barrels, one of each in the
    // channel. This is barracuda's `GND` in miniature — hundreds of elements
    // board-wide, a handful of them actually in the way.
    const hops = [_]blocker_nomination.Hop{.{ .ax = 4, .ay = -2, .bx = 4, .by = 6 }};
    const board = router.RouteResult{
        .tracks = &.{
            .{ .x1 = 3.5, .y1 = 1, .x2 = 4.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 1 },
            .{ .x1 = 8.0, .y1 = 1, .x2 = 9.0, .y2 = 1, .layer = 0, .width = 0.2, .net = 1 },
        },
        .vias = &.{
            .{ .x = 4.4, .y = 3, .dia = 0.6, .drill = 0.3, .net = 1 },
            .{ .x = 8.0, .y = 3, .dia = 0.6, .drill = 0.3, .net = 1 },
        },
        .routed = 0,
        .total = 3,
        .failed = &.{},
    };
    const none = [_]bool{ false, false, false };
    const only_one = [_]bool{ false, true, false };

    // Lifted: the channel hookup and the channel barrel go, the far pair stays
    // exactly as it was.
    const lifted = try stripCopper(arena, placement, .{}, .{
        .dropped = &none,
        .lifted = &only_one,
        .hops = &hops,
        .radius_mm = 2.0,
    }, board);
    try testing.expectEqual(@as(usize, 1), lifted.tracks.len);
    try testing.expectEqual(@as(usize, 1), lifted.vias.len);
    try testing.expect(sameTrack(board.tracks[1], trackAsExisting(lifted.tracks[0])));
    try testing.expect(sameVia(board.vias[1], viaAsExisting(lifted.vias[0])));

    // The whole-net rip on the same net takes all four — the granularity really
    // is the difference, not the mask.
    const whole = try stripGeneratedMask(arena, placement, .{}, &only_one, board);
    try testing.expectEqual(@as(usize, 0), whole.tracks.len);
    try testing.expectEqual(@as(usize, 0), whole.vias.len);

    // A lift with no corridor to measure against removes nothing, so a target
    // the oracle reports no hop for cannot silently strip a plane.
    const no_hops = try stripCopper(arena, placement, .{}, .{
        .dropped = &none,
        .lifted = &only_one,
        .radius_mm = 2.0,
    }, board);
    try testing.expectEqual(board.tracks.len, no_hops.tracks.len);
    try testing.expectEqual(board.vias.len, no_hops.vias.len);
}

// spec: serve/route-plan - a corridor-lifted net's surviving copper is exempt from the frozen-copper echo, because the same transaction put that net in the router's scope; every other net's frozen copper must still come back byte-for-byte
test "the frozen-copper echo exempts exactly the nets the transaction lifted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A corridor lift leaves the rest of its net on the board, so that copper
    // is BOTH frozen into `existing_*` and in `selected_nets` — the router owns
    // it, and demanding a byte-identical echo from it is a contradiction. A
    // whole-net rip can never reach this: nothing of its net is left to freeze.
    const frozen_tracks = [_]route_policy.ExistingTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 }, // lifted net
        .{ .x1 = 5, .y1 = 0, .x2 = 6, .y2 = 0, .layer = 0, .width = 0.2, .net = 2 }, // bystander
    };
    const frozen_vias = [_]route_policy.ExistingVia{
        .{ .x = 0.5, .y = 2, .dia = 0.6, .drill = 0.3, .net = 1 }, // a stitch the lift disturbed
    };
    // What the scoped route hands back: the bystander untouched, and the lifted
    // net RE-STITCHED — its via re-sited and its hookup redrawn, which is the
    // work the lift asked the router to do.
    const candidate = router.RouteResult{
        .tracks = &.{
            .{ .x1 = 0, .y1 = 0.4, .x2 = 1, .y2 = 0.4, .layer = 0, .width = 0.2, .net = 1 },
            .{ .x1 = 5, .y1 = 0, .x2 = 6, .y2 = 0, .layer = 0, .width = 0.2, .net = 2 },
        },
        .vias = &.{.{ .x = 1.1, .y = 2, .dia = 0.6, .drill = 0.3, .net = 1 }},
        .routed = 0,
        .total = 2,
        .failed = &.{},
    };
    const lifted = [_]bool{ false, true, false };
    const none = [_]bool{ false, false, false };

    // Without the exemption the transaction self-vetoes on its own lift — the
    // v87 wall, where three of five targets died after a completed re-route.
    const strict = try retainsExistingCopper(arena, candidate, &frozen_tracks, &frozen_vias, &none);
    try testing.expect(strict != null);
    try testing.expectEqual(@as(i32, 1), strict.?.net);
    // With it, the lifted net's copper is the router's business and the
    // candidate stands.
    try testing.expect(try retainsExistingCopper(arena, candidate, &frozen_tracks, &frozen_vias, &lifted) == null);

    // The exemption is exactly that narrow: a BYSTANDER whose frozen copper
    // moved still fails the check, lift or no lift.
    const bystander_moved = router.RouteResult{
        .tracks = &.{.{ .x1 = 5, .y1 = 9, .x2 = 6, .y2 = 9, .layer = 0, .width = 0.2, .net = 2 }},
        .vias = &.{},
        .routed = 0,
        .total = 2,
        .failed = &.{},
    };
    const caught = try retainsExistingCopper(arena, bystander_moved, &frozen_tracks, &frozen_vias, &lifted);
    try testing.expect(caught != null);
    try testing.expectEqual(@as(i32, 2), caught.?.net);
    try testing.expect(!caught.?.via);
    // And a caller that lifted nothing keeps the invariant exactly as it was.
    try testing.expect(try retainsExistingCopper(arena, candidate, &frozen_tracks, &frozen_vias, &.{}) != null);
}

// spec: serve/route-plan - a transaction that produces no candidate board names which cause it hit, and never reports a corridor with no legal path as an expired slice
test "every dead end an unblock transaction can hit names itself distinctly" {
    // These want DIFFERENT fixes — more wall time, more rip authority, a
    // different join, a bug hunt — and one string for all of them told an
    // operator nothing. Measured at ReleaseSafe, the transactions reporting
    // "no candidate within its slice" had burned 1-3 s of a 20 s window, so the
    // one thing that message asserted was the one thing that was not true.
    const all = std.enums.values(UnblockDead);
    try testing.expect(all.len >= 8);
    for (all, 0..) |a, i| {
        try testing.expect(a.label().len > 0);
        for (all[0..i]) |b| try testing.expect(!std.mem.eql(u8, a.label(), b.label()));
    }
    // The two a reader must never see conflated: a slice that ran out, and a
    // corridor that was freed and still carried no legal path.
    try testing.expect(std.mem.indexOf(u8, UnblockDead.route_expired.label(), "slice") != null);
    try testing.expect(std.mem.indexOf(u8, UnblockDead.join_no_path.label(), "geometry") != null);
}

// spec: serve/route-plan - a formed unblock transaction traces the copper it rips and the granularity it rips at, why a built candidate was rolled back, and every candidate it declined and why, and no trace can be taken down by an out-of-range net index
test "an unblock transaction traces its picks and its refusals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = unblock_wide_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3, .failed = &.{} },
        .measured = .{},
    };
    // Every nomination kind, and one index past the end of the net table — the
    // trace is a reporting path and must never be able to take a route down,
    // which is exactly the guard a whole-board run would never exercise.
    var picks: [4]vacate_policy.Nomination = .{
        .{ .net_i = 0, .kind = .pour_carried, .elements = 44, .dist = 0 },
        .{ .net_i = 1, .kind = .short_stub, .elements = 2, .dist = 0.4 },
        .{ .net_i = 2, .kind = .pair_recouple, .elements = 20, .dist = 0 },
        .{ .net_i = placement.nets.len, .kind = .short_stub, .elements = 1, .dist = 0 },
    };
    unblockLogPicks(&run, "TARGET", &picks);
    var refused: [3]vacate_policy.Refused = .{
        .{ .net_i = 0, .why = .over_budget },
        .{ .net_i = 2, .why = .diff_pair },
        .{ .net_i = placement.nets.len + 7, .why = .capped },
    };
    unblockLogRefusals(&run, &refused);

    // The three shapes a BUILT-then-refused candidate takes, which "rolled
    // back" alone could not tell apart: the target re-routed and stayed open
    // (geometry), the target closed but a ripped blocker did not come back
    // (budget or ordering), and the target and every blocker closed while the
    // whole-board gate still said no.
    const target = target_unblock.Target{ .net_i = 0, .gap_mm = 3.0 };
    const still_open = [_][]const u8{placement.nets[0].name};
    const blocker_open = [_][]const u8{placement.nets[1].name};
    unblockLogRollback(&run, placement.nets[0].name, target, &picks, .{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 3,
        .failed = &still_open,
    });
    unblockLogRollback(&run, placement.nets[0].name, target, &picks, .{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 3,
        .failed = &blocker_open,
    });
    unblockLogRollback(&run, placement.nets[0].name, target, &picks, .{
        .tracks = &.{},
        .vias = &.{},
        .routed = 3,
        .total = 3,
        .failed = &.{},
    });

    // And what the trace says about granularity is what the rip does: the
    // poured pick is lifted, the stub is not, and the pair pick names a twin
    // only when one resolved (this fixture declares no pair, so none does).
    try testing.expect(unblockLifted(&run, picks[0]));
    try testing.expect(!unblockLifted(&run, picks[1]));
    try testing.expect(unblockPickTwin(&run, picks[2]) == null);
}

// spec: serve/route-plan - an unblock corridor charge is measured against the target's own corridor lines, so every candidate one sweep prices is measured against the same corridor and a target with no hop is charged nothing
test "one sweep prices every candidate against the same corridor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    // Two foreign nets either side of one vertical channel: net 1 with a hookup
    // and a barrel in it and a hookup well clear, net 2 with a barrel in it and
    // nothing else. The charge is per NET, the corridor is the target's.
    const board = router.RouteResult{
        .tracks = &.{
            .{ .x1 = 3.5, .y1 = 1, .x2 = 4.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 1 },
            .{ .x1 = 8.0, .y1 = 1, .x2 = 9.0, .y2 = 1, .layer = 0, .width = 0.2, .net = 1 },
        },
        .vias = &.{
            .{ .x = 4.1, .y = 3, .dia = 0.6, .drill = 0.3, .net = 1 },
            .{ .x = 4.2, .y = 5, .dia = 0.6, .drill = 0.3, .net = 2 },
            .{ .x = 8.0, .y = 3, .dia = 0.6, .drill = 0.3, .net = 2 },
        },
        .routed = 0,
        .total = 3,
        .failed = &.{},
    };
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = board,
        .measured = .{},
    };

    // ONE corridor, handed in — so the two candidates of this sweep are charged
    // against the same lines rather than each re-deriving them, and the count is
    // what the rip's own predicate takes and not a second reading of it.
    const hops = [_]blocker_nomination.Hop{.{ .ax = 4, .ay = -2, .bx = 4, .by = 6 }};
    try testing.expectEqual(@as(usize, 2), try unblockCorridorElements(&run, &hops, 1));
    try testing.expectEqual(@as(usize, 1), try unblockCorridorElements(&run, &hops, 2));

    // A target the oracle reports no hop for has no corridor, so nothing is in
    // the way and no net may be charged a discount off a channel that does not
    // exist.
    try testing.expectEqual(@as(usize, 0), try unblockCorridorElements(&run, &.{}, 1));

    // Copper the CALLER retained is nobody's to lift, so it is never counted
    // into a charge the transaction would then have to restore.
    run.options = .{ .existing_vias = &.{.{ .x = 4.1, .y = 3, .dia = 0.6, .drill = 0.3, .net = 1 }} };
    try testing.expectEqual(@as(usize, 1), try unblockCorridorElements(&run, &hops, 1));
}

// spec: serve/route-plan - only a pour-carried nomination under a lifting tier is ripped corridor-only; every other pick and every non-lifting tier is ripped whole
test "the corridor lift is confined to a pour-carried pick under a lifting tier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3, .failed = &.{} },
        .measured = .{},
    };
    const poured = vacate_policy.Nomination{ .net_i = 1, .kind = .pour_carried, .elements = 44, .dist = 0 };
    const stub = vacate_policy.Nomination{ .net_i = 1, .kind = .short_stub, .elements = 2, .dist = 0 };
    // The narrow tier rips everything whole, exactly as it always has.
    try testing.expect(!unblockLifted(&run, poured));
    try testing.expect(!unblockLifted(&run, stub));
    // The wide tier lifts the pour-carried pick and nothing else: a stub's
    // tracks ARE its connectivity, so half of one is not a state to leave.
    run.lim = unblock_wide_limits;
    try testing.expect(unblockLifted(&run, poured));
    try testing.expect(!unblockLifted(&run, stub));
    // The TIMED breadth probe is the second lifting tier, and it lifts the same
    // one class: it is the tier on the tightest clock, so a whole-net restore is
    // exactly what it cannot pay for.
    run.lim = unblockBreadthLimits(target_unblock_limits, 0, 0, 4);
    try testing.expect(unblockLifted(&run, poured));
    try testing.expect(!unblockLifted(&run, stub));
    run.lim = unblock_wide_limits;
    const masks = try unblockMasks(&run);
    unblockMarkPick(&run, poured, masks);
    try testing.expect(masks.lifted[1] and !masks.dropped[1] and masks.selected[1]);
    const whole_masks = try unblockMasks(&run);
    unblockMarkPick(&run, stub, whole_masks);
    try testing.expect(whole_masks.dropped[1] and !whole_masks.lifted[1]);
}

/// The same board with every listed net's copper taken off — the shape a scoped
/// restore that LOST those nets hands back. The loops live here so a test body
/// stays linear.
fn boardWithoutNets(
    arena: std.mem.Allocator,
    board: router.RouteResult,
    nets: []const i32,
) std.mem.Allocator.Error!router.RouteResult {
    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    for (board.tracks) |track| {
        if (std.mem.indexOfScalar(i32, nets, track.net) == null) try tracks.append(arena, track);
    }
    for (board.vias) |via| {
        if (std.mem.indexOfScalar(i32, nets, via.net) == null) try vias.append(arena, via);
    }
    var out = board;
    out.tracks = tracks.items;
    out.vias = vias.items;
    return out;
}

/// A board's copper as the frozen-existing lists a scoped route is handed.
const ExistingCopper = struct {
    tracks: []const route_policy.ExistingTrack,
    vias: []const route_policy.ExistingVia,
};

fn boardAsExisting(
    arena: std.mem.Allocator,
    board: router.RouteResult,
) std.mem.Allocator.Error!ExistingCopper {
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (board.tracks) |track| try tracks.append(arena, trackAsExisting(track));
    for (board.vias) |via| try vias.append(arena, viaAsExisting(via));
    return .{ .tracks = tracks.items, .vias = vias.items };
}

/// Compare two boards segment for segment and via for via. The loops live here
/// so a test body stays linear.
fn expectUnblockCopperIdentical(before: router.RouteResult, after: router.RouteResult) !void {
    try testing.expectEqual(before.tracks.len, after.tracks.len);
    try testing.expectEqual(before.vias.len, after.vias.len);
    try testing.expectEqual(before.failed.len, after.failed.len);
    try testing.expectEqual(before.routed, after.routed);
    for (before.tracks, after.tracks) |a, b| try testing.expect(sameTrack(a, trackAsExisting(b)));
    for (before.vias, after.vias) |a, b| try testing.expect(sameVia(a, viaAsExisting(b)));
}

// spec: serve/route-plan - a per-gap unblock transaction that was accepted re-enters at once for its net's next island gap, read off the board it just left, and the ladder ends when the oracle reports that net no gap at all
test "an accepted transaction takes its net's next gap at once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // One rail in three islands, its hops deliberately unequal: 1.5 mm between
    // the first pair and 4 mm to the third.
    var parts: std.ArrayList(optimizer.Part) = .empty;
    try appendUnblockPart(arena, &parts, "R1", .{ 0, 0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R2", .{ 1.5, 0 }, &route_plan_fixture_pad);
    try appendUnblockPart(arena, &parts, "R3", .{ 5.5, 0 }, &route_plan_fixture_pad);
    const rail = try arena.alloc(export_kicad.FlatPin, 3);
    rail[0] = .{ .ref_des = "R1", .pin = "1" };
    rail[1] = .{ .ref_des = "R2", .pin = "1" };
    rail[2] = .{ .ref_des = "R3", .pin = "1" };
    const nets = [_]optimizer.FlatNet{.{ .name = "RAIL", .pins = rail }};
    var placement = fixturePlacement(parts.items, &nets);
    placement.maxx = 6;
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = .{},
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 },
        .measured = .{},
    };

    // The first re-entry aims at the SHORTEST hop left, as the planner's own
    // order does, and it is a per-gap transaction like the one that earned it.
    const first = (try unblockNextGap(&run, 0)) orelse return error.NoNextGap;
    try testing.expectEqual(@as(usize, 0), first.net_i);
    try testing.expectEqual(target_unblock.Kind.one_gap, first.kind);
    try testing.expectApproxEqAbs(@as(f64, 1.5), first.gap_mm, 0.5);

    // Copper joining that pair is what an accepted merge leaves behind: the
    // next re-entry reads the BOARD, so it aims at what is actually left.
    const near = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    run.baseline.tracks = &near;
    const second = (try unblockNextGap(&run, 0)) orelse return error.NoNextGap;
    try testing.expectApproxEqAbs(@as(f64, 4.0), second.gap_mm, 0.5);

    // With every island joined the oracle names no hop, which is what ends the
    // ladder — the re-entry is bounded by the board, not by a counter.
    const whole = [_]router.Track{
        near[0],
        .{ .x1 = 1.5, .y1 = 0, .x2 = 5.5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    run.baseline.tracks = &whole;
    try testing.expect((try unblockNextGap(&run, 0)) == null);

    // Eligibility is re-asked, so a re-entry can never form a transaction the
    // planner would have refused, and an out-of-range net is never one.
    run.baseline.tracks = &.{};
    const out_of_scope = [_]bool{false};
    run.options = .{ .selected_nets = &out_of_scope };
    try testing.expect((try unblockNextGap(&run, 0)) == null);
    run.options = .{};
    try testing.expect((try unblockNextGap(&run, placement.nets.len)) == null);
}

// spec: serve/route-plan - the per-target unblock pass attempts only the oracle-open two-terminal nets its scope may reroute, cheapest island gap first
test "per-target unblock attempts open two-terminal nets cheapest gap first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    const failed = [_][]const u8{ "FAR", "NEAR", "WIDE" };
    const baseline = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3, .failed = &failed };

    const targets = try unblockTargets(arena, placement, .{}, baseline, .{});
    // WIDE arrives in three islands needing two hops, so it is no target at all;
    // the two-terminal pair is attempted shortest hop first, not net order.
    try testing.expectEqual(@as(usize, 2), targets.len);
    try testing.expectEqual(@as(usize, 1), targets[0].net_i); // NEAR, 3 mm
    try testing.expectEqual(@as(usize, 0), targets[1].net_i); // FAR, 9 mm
    try testing.expect(targets[0].gap_mm < targets[1].gap_mm);

    // A net whose copper this run may not rewrite is not attempted either.
    const scoped = [_]bool{ true, false, false };
    const in_scope = try unblockTargets(arena, placement, .{ .selected_nets = &scoped }, baseline, .{});
    try testing.expectEqual(@as(usize, 1), in_scope.len);
    try testing.expectEqual(@as(usize, 0), in_scope[0].net_i);
}

// spec: serve/route-plan - the per-target unblock phase ends with one additive connectivity close, kept only when the oracle's open set strictly shrinks
test "the unblock phase's tail close keeps only a strict connectivity gain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const failed = [_][]const u8{"SIG"};
    const open = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .failed = &failed };

    // A short hop the additive close can join: the reserve this phase leaves is
    // what buys it, and the gain is real, so it is kept.
    const closed = try closeAfterUnblock(arena, placement, .{}, .{ .effort = .standard }, open);
    try testing.expectEqual(@as(usize, 1), closed.routed);
    try testing.expectEqual(@as(usize, 0), closed.failed.len);
    try testing.expect(closed.tracks.len > 0);

    // Nothing left open: the close is not even attempted, so a finished board
    // pays nothing for the phase behind it.
    const done = try closeAfterUnblock(arena, placement, .{}, .{ .effort = .standard }, closed);
    try testing.expectEqual(closed.tracks.len, done.tracks.len);
    // Past the board deadline it declines rather than spending the reserve.
    const stopped = try closeAfterUnblock(arena, placement, .{}, .{
        .effort = .standard,
        .stop = .{ .deadline_ns = 1 },
    }, open);
    try testing.expectEqual(@as(usize, 0), stopped.tracks.len);
}

// spec: serve/route-plan - a per-target unblock transaction that cannot close its target leaves the baseline board byte-for-byte
test "a per-target unblock transaction rolls back when its target stays open" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try walledUnblockPlacement(arena);
    const baseline = try routeLoweredCandidate(arena, placement, .{}, .{});
    try testing.expect(namedFailed("TARGET", baseline.failed));

    // The tier engages: the walled target is a two-terminal candidate and the
    // short hops lying across its corridor are rippable copper.
    const targets = try unblockTargets(arena, placement, .{}, baseline, .{});
    try testing.expectEqual(@as(usize, 1), targets.len);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = .{},
        .accept = &accept,
        .baseline = baseline,
        .measured = try unblockMeasure(arena, placement, .{}, baseline),
    };
    try testing.expect((try unblockBlockers(&run, targets[0])).len > 0);

    // …and closes nothing, because the wall is pads. So the whole transaction is
    // rolled back and the board is the one the pass was handed.
    const after = try retryTargetUnblock(arena, placement, .{}, .{}, baseline);
    try testing.expect(namedFailed("TARGET", after.failed));
    try expectUnblockCopperIdentical(baseline, after);
}

// spec: serve/route-plan - a fresh route drops DRC-implicated mutable copper and reports the affected net open instead of returning a fab error
test "the shared route gate returns an airwire instead of illegal copper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 1.5, .y = -1 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 1.5, .y = 1 },
    };
    const a_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const b_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "R3", .pin = "1" },
        .{ .ref_des = "R4", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "A", .pins = &a_pins },
        .{ .name = "B", .pins = &b_pins },
    };
    var placement = fixturePlacement(&parts, &nets);
    placement.miny = -1.5;
    placement.maxy = 1.5;
    const crossing = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = -1, .x2 = 1.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 1 },
    };
    const raw = router.RouteResult{ .tracks = &crossing, .vias = &.{}, .routed = 2, .total = 2 };
    const before = try drc.check(arena, placement, raw, 0.127);
    try testing.expectEqual(@as(usize, 1), drc.errorCount(before));

    // B is retained caller copper. The gate may only sacrifice mutable A.
    const selected = [_]bool{ true, false };
    const safe = (try gate(arena, placement, .{}, raw, .{ .selected_nets = &selected })).result;
    try testing.expectEqual(@as(usize, 1), safe.tracks.len);
    try testing.expectEqual(@as(i32, 1), safe.tracks[0].net);
    try testing.expectEqual(@as(usize, 1), safe.routed);
    try testing.expectEqual(@as(usize, 2), safe.total);
    try testing.expectEqual(@as(usize, 1), safe.failed.len);
    try testing.expectEqualStrings("A", safe.failed[0]);
    try testing.expectEqual(@as(usize, 0), drc.errorCount(try drc.check(arena, placement, safe, 0.127)));
}

// spec: serve/route-plan - resolveScope selects a criticality class group over the analyzed context
test "resolveScope selects a criticality class group" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    // module_policy classifies "RFOUT" as the rf criticality class by name; the
    // scope's "rf" group token must then select it and not the plain signal net.
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RFOUT", .pins = &fixture_pins },
        .{ .name = "SIG", .pins = &.{} },
    };
    const block = fixtureBlock(null);
    const scope = try resolveScope(arena, &block, fixturePlacement(&parts, &nets), .{ .groups = &.{"rf"} });
    try testing.expect(scope.mask[0] and !scope.mask[1]);
    try testing.expectEqual(@as(usize, 1), scope.matched);
    try testing.expectEqual(@as(usize, 1), scope.selectors);
}

// spec: serve/route-plan - selecting either differential-pair member for an incremental route automatically includes its partner
test "incremental differential scope includes both pair members" {
    const nets = [_]optimizer.FlatNet{
        .{ .name = "CLK_P", .pins = &.{} },
        .{ .name = "CLK_N", .pins = &.{} },
        .{ .name = "OTHER", .pins = &.{} },
    };
    const pairs = [_]@import("../placement/diff_pairs.zig").DiffPair{.{ .p = 0, .n = 1, .gap = 0.2 }};
    var parts = [_]optimizer.Part{};
    var placement = fixturePlacement(&parts, &nets);
    placement.diff_pairs = &pairs;
    var selected = [_]bool{ true, false, false };
    try testing.expectEqual(@as(usize, 1), includeDiffPartners(placement, &selected));
    try testing.expect(selected[0] and selected[1] and !selected[2]);
    try testing.expectEqual(@as(usize, 0), includeDiffPartners(placement, &selected));
}

/// The shape that makes the gate's two halves disagree: a net whose trunk is
/// load-bearing copper (R1's land, through a via, to R2 on the other layer) and
/// whose surface run continues PAST that via and stops on its own rail's pour.
/// That overshoot is a finished run to anything that credits the fill and an
/// unattached stub to anything that does not.
fn pourEndedBoard(parts: []optimizer.Part) optimizer.Placement {
    var placement = fixturePlacement(parts, &pour_ended_nets);
    placement.minx = -2;
    placement.maxx = 5;
    placement.miny = -2;
    placement.maxy = 4;
    return placement;
}

const pour_ended_pins = [_]export_kicad.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
};
const pour_ended_nets = [_]optimizer.FlatNet{.{ .name = "A", .pins = &pour_ended_pins }};
const pour_ended_tracks = [_]router.Track{
    .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = 2, .layer = 1, .width = 0.2, .net = 0 },
};
const pour_ended_vias = [_]router.Via{.{ .x = 1, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 }};
const pour_ended_poly = [_][2]f64{ .{ 1.7, -0.5 }, .{ 2.6, -0.5 }, .{ 2.6, 0.5 }, .{ 1.7, 0.5 } };

// spec: serve/route-plan - the gate's DRC ratchet judges copper against the same fabricated fill its topology prune does, so a trace that ends on its own net's pour is never dropped as a stub
test "the route gate credits the pour the copper it keeps ends on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 1, .y = 2 },
    };
    const placement = pourEndedBoard(&parts);
    const raw = router.RouteResult{
        .tracks = &pour_ended_tracks,
        .vias = &pour_ended_vias,
        .routed = 1,
        .total = 1,
    };
    const zones = [_]route_policy.ExistingZone{.{ .polygon = &pour_ended_poly, .layer = 0, .net = 0 }};

    // The zone-BLIND reading is the one that was choosing victims: with no fill
    // to end on, the overshoot is an unattached stub, and a stub is an ERROR
    // whose only candidate is its own net — so the whole net's copper goes.
    const blind = try drc.check(arena, placement, raw, 0.127);
    try testing.expect(drc.errorCount(blind) > 0);
    const filled = drc_rules.checkFilled(arena, .{
        .placement = placement,
        .routed = raw,
        .clearance = 0.127,
        .zones = try route_close.userZones(arena, placement, &zones),
    });
    try testing.expectEqual(@as(usize, 0), drc.errorCount(filled));

    // …so the gate keeps the copper instead of dropping the whole net's.
    const safe = (try gate(arena, placement, .{}, raw, .{ .existing_zones = &zones })).result;
    var kept = false;
    for (safe.tracks) |t| {
        if (t.net == 0 and t.layer == 0 and t.x2 == 2) kept = true;
    }
    try testing.expect(kept);
}

// spec: serve/route-plan - a dropped gate victim names the rule that chose it and the other party to it, and says so plainly when no finding names it at all
test "a gate victim names the finding that cost it its copper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SIG", .pins = &fixture_pins },
        .{ .name = "OTHER", .pins = &.{} },
    };
    const placement = fixturePlacement(&parts, &nets);
    _ = arena;
    const clash = drc.Violation{
        .x = 1,
        .y = 2,
        .gap = -0.068,
        .clearance = 0.127,
        .kind = .via_track,
        .who = .{ .net_a = 0, .net_b = 1 },
    };
    const stub = drc.Violation{ .x = 3, .y = 4, .gap = 0, .clearance = 0, .kind = .copper_stub, .who = .{ .net_a = 0 } };
    const list = [_]drc.Violation{ clash, stub };

    // The cause is read off exactly the rows the victim cover walks, and the
    // other party is the net a reader has to go and look at.
    const cause = victimCause(placement, .{}, &list, 0) orelse return error.NoCause;
    try testing.expectEqual(drc.Kind.via_track, cause.kind);
    try testing.expectEqualStrings("OTHER", victimOther(placement, 0, cause));
    try testing.expectEqual(drc.Kind.via_track, (victimCause(placement, .{}, &list, 1) orelse return error.NoCause).kind);
    // A one-sided rule has no second party to name.
    try testing.expectEqualStrings("—", victimOther(placement, 0, stub));
    // And a net no finding names has no cause at all, rather than a wrong one.
    try testing.expect(victimCause(placement, .{}, &.{stub}, 1) == null);
}

// spec: serve/route-plan - the victim re-home runs in a window out of the clock the pass still holds rather than the transaction slice its own scoped re-route has already spent, and a clock-free board keeps exactly the deadline it had
test "a lost victim's re-home is given a window the pass can still pay" {
    const second = clock.ns_per_s;
    const now: i128 = 1_000 * second;
    const reserve: i128 = 6 * second;
    // The transaction's own slice: handed to the scoped re-route, which spent it
    // to the last nanosecond, and then the gate reconciled past it.
    const spent: i128 = now - 30 * second;

    // A clock-free board is answered with exactly the deadline it had.
    try testing.expectEqual(spent, rehomeDeadline(now, 0, reserve, spent));

    // A timed board with room hands over a bounded window measured from NOW,
    // not from the deadline its predecessor already burned.
    const board = now + 60 * second;
    const window = rehomeDeadline(now, board, reserve, spent);
    try testing.expect(window > now);
    try testing.expectEqual(now + rehome_window_ns, window);

    // The additive close's reserve is never eaten…
    const tight = now + reserve + second;
    try testing.expectEqual(now + second, rehomeDeadline(now, tight, reserve, spent));
    // …and a board already inside its reserve grants nothing at all.
    try testing.expectEqual(spent, rehomeDeadline(now, now + reserve, reserve, spent));
    // The window can only ever GROW a deadline, never shorten one.
    const generous = now + 5 * second;
    try testing.expectEqual(generous, rehomeDeadline(now, board, reserve, generous));
}

// spec: serve/route-plan - the alternate nomination after a lost victim is priced at the narrow tier it actually runs rather than at the wide tier's spare-time gate, while a clock-free run still declines it
test "an alternate nomination is affordable where a wide retry is not" {
    const second = clock.ns_per_s;
    const now: i128 = 1_000 * second;
    const lim = target_unblock_limits;

    // A clock-free board declines both, so every bench and corpus route keeps
    // exactly the one narrow attempt it was measured on.
    try testing.expect(!alternateAffordable(now, 0, 2, lim));
    try testing.expect(!wideUnblockAffordable(now, 0, 2));

    // Twelve seconds left over two targets cannot seat a wide transaction and
    // can seat a narrow one — which is the tier this retry runs at.
    const board = now + 12 * second;
    try testing.expect(!wideUnblockAffordable(now, board, 2));
    try testing.expect(alternateAffordable(now, board, 2, lim));

    // Inside the reserve nothing is affordable, and neither is a pass with no
    // targets left to spend on.
    try testing.expect(!alternateAffordable(now, now + lim.slice.reserve_ns, 2, lim));
    try testing.expect(!alternateAffordable(now, board, 0, lim));
}

// spec: serve/route-plan - a breadth probe's slice cap is the phase remainder split between its own targets and the depth round behind it, floored at the tier's own minimum and never raised above the narrow tier's measured cap
test "a breadth probe is capped at its share of half the phase tail" {
    const second = clock.ns_per_s;
    const now: i128 = 1_000 * second;
    const lim = target_unblock_limits;

    // A clock-free board keeps the tier's own cap, so every bench and corpus
    // route sees the bounds it was measured on. Only the per-element growth is
    // off, and a rateless read of it is what the narrow tier already had.
    const free = unblockBreadthLimits(lim, now, 0, 4);
    try testing.expectEqual(lim.slice.max_ns, free.slice.max_ns);
    try testing.expectEqual(@as(i128, 0), free.slice.ns_per_element);

    // 100 s left, reserve 6 s, five targets: half of 94 s split five ways is
    // 9.4 s, under the tier's own 10 s cap, so the share is what binds.
    const board = now + 100 * second;
    const shared = unblockBreadthLimits(lim, now, board, 5);
    try testing.expectEqual(@divTrunc(94 * second, 10), shared.slice.max_ns);
    try testing.expect(shared.slice.max_ns < lim.slice.max_ns);

    // A generous tail may not raise the cap ABOVE what the narrow tier was
    // measured with — breadth is a shorter question, never a longer one.
    const rich = unblockBreadthLimits(lim, now, now + 600 * second, 2);
    try testing.expectEqual(lim.slice.max_ns, rich.slice.max_ns);

    // And a tail already inside the reserve floors at the shortest slice worth
    // starting rather than handing out a nanosecond nothing can route in.
    const tight = unblockBreadthLimits(lim, now, now + lim.slice.reserve_ns + 1, 5);
    try testing.expectEqual(lim.slice.min_ns, tight.slice.max_ns);
    // A board already inside its reserve is left the tier's cap — `sliceDeadline`
    // is what refuses such a board a transaction, not a shrunken cap.
    const spent = unblockBreadthLimits(lim, now, now + lim.slice.reserve_ns, 5);
    try testing.expectEqual(lim.slice.max_ns, spent.slice.max_ns);
    // A round with no targets left divides by nobody and keeps the tier's cap.
    try testing.expectEqual(lim.slice.max_ns, unblockBreadthLimits(lim, now, board, 0).slice.max_ns);
}

// spec: serve/route-plan - a timed breadth probe negotiates a pour-carried blocker's corridor lift and nothing else, so its restore is sized by the copper in the corridor rather than by the whole net, while the depth ladder behind it keeps the whole-net rip
test "a breadth probe lifts a poured blocker's corridor instead of ripping the net" {
    const second = clock.ns_per_s;
    const now: i128 = 1_000 * second;
    const lim = target_unblock_limits;

    // ONE switch, on every shape of the round's own bounds. `pairs` stays off —
    // a coupled re-construction is a second board, which a probe bounded to a
    // share of half the tail has no budget for — and `outranking` stays the
    // deepening round's alone, because a breadth probe never deepens.
    for ([_]target_unblock.Limits{
        unblockBreadthLimits(lim, now, now + 100 * second, 5),
        unblockBreadthLimits(lim, now, 0, 4),
        unblockBreadthLimits(lim, now, now + lim.slice.reserve_ns, 5),
    }) |probe| {
        try testing.expect(probe.negotiate.plane_corridor);
        try testing.expect(!probe.negotiate.pairs);
        try testing.expect(!probe.negotiate.outranking);
    }

    // The DEPTH ladder behind it is the narrow tier untouched, so round 2 keeps
    // the whole-net rip it has always had. That is the whole containment: the
    // probe asks a slightly smaller question, and the tier that acts on the
    // answer asks the same one it always did.
    try testing.expect(!lim.negotiate.plane_corridor);
    try testing.expect(!lim.negotiate.pairs);

    // What the switch BUYS, on barracuda's own numbers: `V_3V3_LMX` crossing a
    // probe's corridor is 66 elements of pour and ~8 of them in the way. Whole,
    // it is refused for its size — and the probe pays a 20-30 s restore for the
    // 66 whenever the budget does admit it; lifted, it is the same pour-carried
    // nomination charged for the corridor.
    const probe = unblockBreadthLimits(lim, now, now + 100 * second, 5);
    const poured = vacate_policy.NetFacts{
        .net_i = 3,
        .pour_carried = true,
        .whole = true,
        .elements = 66,
    };
    try testing.expectEqual(@as(usize, 8), target_unblock.liftFacts(poured, probe, 8).elements);
    try testing.expectEqual(@as(usize, 66), target_unblock.liftFacts(poured, lim, 8).elements);
    // And nothing else moves: a net no pour carries keeps its whole charge under
    // the probe's bounds exactly as it does under the narrow tier's.
    var bare = poured;
    bare.pour_carried = false;
    try testing.expectEqual(@as(usize, 66), target_unblock.liftFacts(bare, probe, 8).elements);
}

// spec: serve/route-plan - the depth round funds its ladders in the order the breadth verdicts earned, and a target the board sealed on geometry with no class a deeper tier may negotiate sorts last
test "round 2 funds ladders in the order round 1's verdicts earned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An accept beats a lost victim beats a reachable class beats silence beats
    // an empty corridor beats a sealed one — the enum's own declaration order.
    try testing.expect(@backingInt(UnblockPromise.closed) < @backingInt(UnblockPromise.victim_lost));
    try testing.expect(@backingInt(UnblockPromise.victim_lost) < @backingInt(UnblockPromise.depth_reachable));
    try testing.expect(@backingInt(UnblockPromise.depth_reachable) < @backingInt(UnblockPromise.unanswered));
    try testing.expect(@backingInt(UnblockPromise.unanswered) < @backingInt(UnblockPromise.no_rip));
    try testing.expect(@backingInt(UnblockPromise.no_rip) < @backingInt(UnblockPromise.sealed));

    // Each outcome earns exactly one verdict, and the reachable class is read
    // ahead of "no picks" — a refused declared pair yields no picks at all.
    const pair_refusal = [_]vacate_policy.Refused{.{ .net_i = 7, .why = .diff_pair }};
    const dead_refusal = [_]vacate_policy.Refused{.{ .net_i = 7, .why = .ground }};
    const one_pick = [_]vacate_policy.Nomination{.{ .net_i = 3, .kind = .short_stub, .elements = 2, .dist = 0.4 }};
    try testing.expectEqual(UnblockPromise.closed, unblockPromiseOf(.{ .accepted = true }));
    try testing.expectEqual(UnblockPromise.victim_lost, unblockPromiseOf(.{ .lost_victim = 4, .picked = &one_pick }));
    try testing.expectEqual(UnblockPromise.depth_reachable, unblockPromiseOf(.{ .refused = &pair_refusal }));
    try testing.expectEqual(UnblockPromise.no_rip, unblockPromiseOf(.{ .refused = &dead_refusal }));
    try testing.expectEqual(UnblockPromise.sealed, unblockPromiseOf(.{ .geometry = true, .picked = &one_pick, .refused = &dead_refusal }));
    try testing.expectEqual(UnblockPromise.unanswered, unblockPromiseOf(.{ .picked = &one_pick, .dead = .route_expired }));

    // The plan is re-queued, never trimmed: three nets, worst promise first on
    // the way in, best promise first on the way out, and ties keep plan order.
    const promise = [_]UnblockPromise{ .sealed, .closed, .depth_reachable };
    const plan = [_]target_unblock.Target{
        .{ .net_i = 0, .gap_mm = 1.0, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 2, .gap_mm = 2.0 },
        .{ .net_i = 1, .gap_mm = 3.0 },
        .{ .net_i = 0, .gap_mm = 4.0, .kind = .one_gap, .gaps = 3 },
    };
    const rip = [_]usize{ 9, 1, 4 };
    const ordered = try unblockByPromise(arena, &plan, .{ .promise = &promise, .rip = &rip });
    try testing.expectEqual(plan.len, ordered.len);
    try testing.expectEqual(@as(usize, 1), ordered[0].net_i);
    try testing.expectEqual(@as(usize, 2), ordered[1].net_i);
    try testing.expectApproxEqAbs(@as(f64, 1.0), ordered[2].gap_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0), ordered[3].gap_mm, 1e-9);

    // Every refusal is classed once, and only the three a deeper tier owns are
    // reachable — the rest are refusals no rip authority moves.
    for (std.enums.values(vacate_policy.Refusal)) |why| {
        const reachable = switch (why) {
            .diff_pair, .outranks_seed, .capped, .over_budget => true,
            else => false,
        };
        try testing.expectEqual(reachable, unblockDepthClass(why));
    }
}

// spec: serve/route-plan - a breadth refusal that rolled back a re-routed board outranks one that produced no board at all, because a deepening round is the tier that can act on it
test "a breadth refusal with a board to diagnose outranks one without" {
    // A deepening round diagnoses THE BOARD its transaction produced, so the
    // rank that funds one has to be the rank that has a board.
    try testing.expect(@backingInt(UnblockPromise.victim_lost) < @backingInt(UnblockPromise.deepenable));
    try testing.expect(@backingInt(UnblockPromise.deepenable) < @backingInt(UnblockPromise.depth_reachable));

    // barracuda's five open nets (Debug, v100), all with an outranking net in
    // their sweep's refusals. Two rolled a re-routed board back — the verdict
    // `unblockDeepen` is entered on — and three produced no board at all.
    const reachable = [_]vacate_policy.Refused{.{ .net_i = 7, .why = .outranks_seed }};
    const one_pick = [_]vacate_policy.Nomination{.{ .net_i = 3, .kind = .short_stub, .elements = 2, .dist = 0.4 }};
    // `SPI_LMX_CSN` and `V_3V3A`: a board, rolled back, still open.
    const rolled_back = UnblockOutcome{ .geometry = true, .picked = &one_pick, .refused = &reachable };
    try testing.expectEqual(UnblockPromise.deepenable, unblockPromiseOf(rolled_back));

    // `SPI_DSA_CSN` and `SPI_SCK`: the same geometry READING, but with a cause
    // attached — `join_no_path` is a transaction that never drew a board, and no
    // deepening round can be entered on one. The null `dead` is what carries the
    // difference; the `geometry` flag alone cannot.
    var no_board = rolled_back;
    no_board.dead = .join_no_path;
    try testing.expectEqual(UnblockPromise.depth_reachable, unblockPromiseOf(no_board));
    // `LOCK_DET`: the clock stopped it before it drew anything, which is the
    // same "no board" reading arrived at by a different road.
    var expired = rolled_back;
    expired.geometry = false;
    expired.dead = .route_expired;
    try testing.expectEqual(UnblockPromise.depth_reachable, unblockPromiseOf(expired));

    // Neither rank is reachable without a refusal a deeper tier owns: a rollback
    // whose sweep named nothing negotiable is still the sealed verdict it was.
    const dead_refusal = [_]vacate_policy.Refused{.{ .net_i = 7, .why = .ground }};
    var sealed = rolled_back;
    sealed.refused = &dead_refusal;
    try testing.expectEqual(UnblockPromise.sealed, unblockPromiseOf(sealed));

    // And an accept still beats both, whatever board it left behind.
    var accepted = rolled_back;
    accepted.accepted = true;
    try testing.expectEqual(UnblockPromise.closed, unblockPromiseOf(accepted));

    // Every verdict keeps a line of prose of its own.
    for (std.enums.values(UnblockPromise)) |verdict| try testing.expect(verdict.label().len > 0);
}

// spec: serve/route-plan - two rolled-back refusals are funded cheapest-rip first, and the rip count never reorders any other verdict
test "the cheaper rollback is funded first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // barracuda's top bucket (Debug, v101): net 2 is `SPI_LMX_CSN`, first in plan
    // order with a 3-net rip; net 0 is `V_3V3A`, last, on a single stub. Both
    // rolled a board back, so plan order alone funded the expensive one.
    const promise = [_]UnblockPromise{ .deepenable, .sealed, .deepenable };
    const rip = [_]usize{ 1, 7, 3 };
    const plan = [_]target_unblock.Target{
        .{ .net_i = 2, .gap_mm = 2.0 },
        .{ .net_i = 1, .gap_mm = 3.0 },
        .{ .net_i = 0, .gap_mm = 1.0, .kind = .one_gap, .gaps = 2 },
        .{ .net_i = 0, .gap_mm = 4.0, .kind = .one_gap, .gaps = 2 },
    };
    const ordered = try unblockByPromise(arena, &plan, .{ .promise = &promise, .rip = &rip });
    try testing.expectEqual(plan.len, ordered.len);
    try testing.expectEqual(@as(usize, 0), ordered[0].net_i);
    try testing.expectEqual(@as(usize, 0), ordered[1].net_i);
    try testing.expectEqual(@as(usize, 2), ordered[2].net_i);
    try testing.expectEqual(@as(usize, 1), ordered[3].net_i);

    // A funded net still brings every rung it has, in plan order.
    try testing.expectApproxEqAbs(@as(f64, 1.0), ordered[0].gap_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0), ordered[1].gap_mm, 1e-9);

    // The key is inert outside the bucket it was measured for: only a
    // `deepenable` verdict carries a rip count into the sort at all.
    try testing.expectEqual(@as(usize, 3), promisedRip(.deepenable, 3));
    for (std.enums.values(UnblockPromise)) |verdict| {
        if (verdict == .deepenable) continue;
        try testing.expectEqual(@as(usize, 0), promisedRip(verdict, 7));
    }

    // So two same-rank verdicts that are NOT deepenable keep plan order however
    // differently their transactions ripped.
    const sealed_only = [_]UnblockPromise{ .sealed, .sealed, .sealed };
    const lopsided = try unblockByPromise(arena, &plan, .{ .promise = &sealed_only, .rip = &rip });
    try testing.expectEqual(plan[0].net_i, lopsided[0].net_i);
    try testing.expectEqual(plan[1].net_i, lopsided[1].net_i);
    try testing.expectEqual(plan[2].net_i, lopsided[2].net_i);
    try testing.expectEqual(plan[3].net_i, lopsided[3].net_i);
}

// spec: serve/route-plan - round 2 funds only the deep ladders the phase remainder can pay for at one wide retry apiece, floors that at a single ladder while any remainder is left, and funds every net on a board with no clock
test "round 2 funds the deep ladders its remainder can pay for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    const lim = target_unblock_limits;
    const second = clock.ns_per_s;
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = lim,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3 },
        .measured = .{},
    };

    // A ladder is priced at the WIDE tier's own base slice — the biggest single
    // transaction a ladder can seat — and never at the narrow slice the old
    // count-based estimate quoted, which is what let four "funded" ladders share
    // a remainder that could not seat one escalation between them.
    try testing.expectEqual(unblock_wide_limits.slice.max_ns, unblock_ladder_price_ns);
    try testing.expect(unblock_ladder_price_ns > lim.slice.max_ns);

    // A CLOCK-FREE board funds every net there is: it runs the single-round pass,
    // and there is no remainder to divide.
    try testing.expectEqual(@as(usize, 3), unblockFundedLadders(&run, 3, lim));
    try testing.expectEqual(@as(usize, 0), unblockFundedLadders(&run, 0, lim));

    // barracuda's v99 numbers: ~49 s of tail behind the breadth round funds ONE
    // ladder, not the four the count promised.
    const now = clock.nanoTimestamp();
    run.options = .{ .stop = .{ .deadline_ns = now + 49 * second + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 1), unblockFundedLadders(&run, 5, lim));

    // Two ladders' worth buys two; a tail longer than every ladder still funds
    // only the nets there are to fund.
    run.options = .{ .stop = .{ .deadline_ns = now + 2 * unblock_ladder_price_ns + second + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 2), unblockFundedLadders(&run, 5, lim));

    // The count TRACKS the remainder rather than a tier of its own, which is
    // what a raised board budget buys. barracuda's v100 tail measured 89 s at
    // this point and funded one ladder — one second short of two — while the
    // same phase behind a 270 s budget measures 119 s and funds the second, which
    // is `LOCK_DET`'s ladder and its rank negotiation.
    run.options = .{ .stop = .{ .deadline_ns = now + 89 * second + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 1), unblockFundedLadders(&run, 5, lim));
    run.options = .{ .stop = .{ .deadline_ns = now + 119 * second + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 2), unblockFundedLadders(&run, 5, lim));
    run.options = .{ .stop = .{ .deadline_ns = now + 40 * unblock_ladder_price_ns + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 3), unblockFundedLadders(&run, 3, lim));

    // Under one ladder's price the FLOOR still funds the best one: every tier
    // below the price is cheaper than it, and a slice the board cannot seat is
    // refused by `sliceDeadline` at the door for free.
    run.options = .{ .stop = .{ .deadline_ns = now + second + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 1), unblockFundedLadders(&run, 5, lim));

    // A tail already inside the additive close's reserve funds nothing at all —
    // that reserve is the one claim this phase may not spend.
    run.options = .{ .stop = .{ .deadline_ns = now + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 0), unblockFundedLadders(&run, 5, lim));
}

// spec: serve/route-plan - the funded round-2 plan carries every target of a funded net, releases the targets it cannot fund outright, and names the funded nets in its timeline line
test "the funded round-2 plan carries exactly the ladders it funds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    const lim = target_unblock_limits;
    const second = clock.ns_per_s;
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = lim,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3 },
        .measured = .{},
    };

    // Promise order on the way in: NEAR earned the best verdict, then WIDE, and
    // FAR's two per-gap rungs sit last and apart.
    const ordered = [_]target_unblock.Target{
        .{ .net_i = 1, .gap_mm = 3.0 },
        .{ .net_i = 2, .gap_mm = 2.0 },
        .{ .net_i = 0, .gap_mm = 1.0, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 0, .gap_mm = 4.0, .kind = .one_gap, .gaps = 3 },
    };

    // ONE ladder's remainder: the best promise is funded and the other two nets
    // are RELEASED — their breadth verdicts stand and no floor is held for them.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + unblock_ladder_price_ns + second + lim.slice.reserve_ns } };
    const one = try unblockFundedPlan(&run, &ordered, lim);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(usize, 1), one[0].net_i);
    try testing.expectEqualStrings("NEAR", try unblockPlanNetNames(arena, placement, one));

    // Two ladders' worth takes the next net in promise order, and stops there.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + 2 * unblock_ladder_price_ns + second + lim.slice.reserve_ns } };
    const two = try unblockFundedPlan(&run, &ordered, lim);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqual(@as(usize, 2), two[1].net_i);
    try testing.expectEqualStrings("NEAR, WIDE", try unblockPlanNetNames(arena, placement, two));

    // A funded net brings ALL its rungs, however far down the plan they sit —
    // the ladder is the net, and its per-gap slots are that ladder's rungs.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + 40 * unblock_ladder_price_ns + lim.slice.reserve_ns } };
    const all = try unblockFundedPlan(&run, &ordered, lim);
    try testing.expectEqual(ordered.len, all.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), all[2].gap_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0), all[3].gap_mm, 1e-9);
    try testing.expectEqualStrings("NEAR, WIDE, FAR", try unblockPlanNetNames(arena, placement, all));

    // A remainder already inside the reserve funds nothing, and an empty plan
    // names nobody rather than printing an empty parenthesis.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + lim.slice.reserve_ns } };
    try testing.expectEqual(@as(usize, 0), (try unblockFundedPlan(&run, &ordered, lim)).len);
    try testing.expectEqualStrings("none", try unblockPlanNetNames(arena, placement, &.{}));
}

/// Assert a dealt round-2 plan is exactly these nets, rung for rung, in order.
fn expectPlanNets(plan: []const target_unblock.Target, nets: []const usize) !void {
    try testing.expectEqual(nets.len, plan.len);
    for (plan, nets) |target, net_i| try testing.expectEqual(net_i, target.net_i);
}

/// Assert a dealt round-2 plan is exactly these hops, in order — which is what
/// says each net's own rungs kept their plan order through the deal.
fn expectPlanGaps(plan: []const target_unblock.Target, gaps_mm: []const f64) !void {
    try testing.expectEqual(gaps_mm.len, plan.len);
    for (plan, gaps_mm) |target, mm| try testing.expectApproxEqAbs(mm, target.gap_mm, 1e-9);
}

// spec: serve/route-plan - round 2 deals its funded ladders' rungs round-robin in promise order, so a target that has already spent a ladder this pass takes its next rung only behind every funded target that has spent none
test "a funded hydra's later rungs queue behind every fresh ladder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    const lim = target_unblock_limits;
    const second = clock.ns_per_s;
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = lim,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3 },
        .measured = .{},
    };

    // barracuda's shape: the best-promised net is a HYDRA with three planned
    // rungs, and two fresh targets sit behind it with one each. Grouped by net —
    // which is what the promise sort alone produces — FAR takes three whole
    // ladders before NEAR is asked anything.
    const ordered = [_]target_unblock.Target{
        .{ .net_i = 0, .gap_mm = 1.0, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 0, .gap_mm = 2.0, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 0, .gap_mm = 3.0, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 1, .gap_mm = 4.0 },
        .{ .net_i = 2, .gap_mm = 5.0 },
    };

    // TWO ladders' remainder: the funded nets are still the two best promises,
    // in promise order — but the hydra's second and third rungs now sit BEHIND
    // the fresh ladder, so the pass asks a target it has never asked before it
    // asks the same one again.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + 2 * unblock_ladder_price_ns + second + lim.slice.reserve_ns } };
    const two = try unblockFundedPlan(&run, &ordered, lim);
    try testing.expectEqualStrings("FAR, NEAR", try unblockPlanNetNames(arena, placement, two));
    try expectPlanNets(two, &.{ 0, 1, 0, 0 });
    // Every rung the funded nets held is still there — this is an ORDER and
    // never a cut — and the deal keeps each net's own rungs in plan order.
    try expectPlanGaps(two, &.{ 1.0, 4.0, 2.0, 3.0 });

    // ONE ladder's remainder has nobody fresh to defer to, so the hydra's rungs
    // deal in exactly the order they always did.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + unblock_ladder_price_ns + second + lim.slice.reserve_ns } };
    const one = try unblockFundedPlan(&run, &ordered, lim);
    try testing.expectEqualStrings("FAR", try unblockPlanNetNames(arena, placement, one));
    try expectPlanGaps(one, &.{ 1.0, 2.0, 3.0 });

    // Funding every net deals all three ladders' first rungs before the hydra's
    // second — the same rule, one tier out.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + 40 * unblock_ladder_price_ns + lim.slice.reserve_ns } };
    const all = try unblockFundedPlan(&run, &ordered, lim);
    try expectPlanNets(all, &.{ 0, 1, 2, 0, 0 });

    // The rung reader itself: plan order within one net, and null the moment
    // that net has no further rung to deal.
    try testing.expectApproxEqAbs(@as(f64, 2.0), unblockNetRung(&ordered, 0, 1).?.gap_mm, 1e-9);
    try testing.expect(unblockNetRung(&ordered, 0, 3) == null);
    try testing.expect(unblockNetRung(&ordered, 1, 1) == null);
    try testing.expect(unblockNetRung(&ordered, 9, 0) == null);
}

// spec: serve/route-plan - on a timed board with several unblock targets the phase gives every target one narrow slice-bounded transaction before any target is given a ladder, and a board with no deadline or a single target keeps the single-round pass exactly
test "the breadth round covers every open net once and yields on a board with nothing to schedule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3 },
        .measured = .{},
    };

    // A rail's pockets are one net's one first question, not three.
    const plan = [_]target_unblock.Target{
        .{ .net_i = 0, .gap_mm = 1.0, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 1, .gap_mm = 2.0 },
        .{ .net_i = 0, .gap_mm = 4.0, .kind = .one_gap, .gaps = 3 },
    };
    try testing.expectEqual(@as(usize, 2), unblockDistinctNets(&plan, placement.nets.len));
    try testing.expectEqual(@as(usize, 0), unblockDistinctNets(&.{}, placement.nets.len));

    // A CLOCK-FREE board is handed back its plan unchanged — the same slice, the
    // same order, the same transactions every corpus route has always run.
    const untimed = try unblockRounds(&run, &plan, target_unblock_limits);
    try testing.expectEqual(plan.len, untimed.len);
    try testing.expectEqual(plan[0].net_i, untimed[0].net_i);
    try testing.expectEqual(UnblockLadder.depth, run.ladder);

    // So is a timed board with ONE target: breadth answers a scheduling problem,
    // and a single target has nothing to schedule against.
    run.options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + 60 * clock.ns_per_s } };
    const single = try unblockRounds(&run, plan[1..2], target_unblock_limits);
    try testing.expectEqual(@as(usize, 1), single.len);
    try testing.expectEqual(UnblockLadder.depth, run.ladder);
}

// spec: serve/route-plan - a breadth transaction runs no deepening round and prices a coupled victim re-home as the ordinary hop it shares a window with, so one target cannot spend another's turn
test "a breadth transaction prices a coupled re-home as a hop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    const second = clock.ns_per_s;
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{ .stop = .{ .deadline_ns = clock.nanoTimestamp() + 300 * second } },
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3 },
        .measured = .{},
    };
    const spent = clock.nanoTimestamp() - 30 * second;

    // In the DEPTH round a lost pair gets the coupled window, which is what the
    // scoped coupled route measurably needs.
    run.ladder = .depth;
    const deep = unblockRehomeWindow(&run, spent, true);
    try testing.expect(deep - clock.nanoTimestamp() > rehome_window_ns);

    // In the BREADTH round it gets the hop window instead — the verdict it then
    // produces is what sorts the target to the front of round 2.
    run.ladder = .breadth;
    const shallow = unblockRehomeWindow(&run, spent, true);
    try testing.expect(shallow - clock.nanoTimestamp() <= rehome_window_ns);
    // An ordinary victim's window is the hop window in either round.
    try testing.expect(unblockRehomeWindow(&run, spent, false) - clock.nanoTimestamp() <= rehome_window_ns);
}

// spec: serve/route-plan - a timed route never returns a board less connected than one it already held, and a phase that comes back worse is checkpointed back to the best board while its cancellation is still reported
test "the residual checkpoint restores the best board a phase gave up" {
    const held = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 104, .total = 109, .failed = &.{ "a", "b" } };
    const worse = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 99, .total = 109, .failed = &.{"c"}, .cancelled = true };
    const better = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 106, .total = 109 };

    try testing.expect(boardRegressed(held, worse));
    try testing.expect(!boardRegressed(held, better));
    try testing.expect(!boardRegressed(held, held));

    // The copper comes back, and so does the successor's word about the clock.
    const kept = keepBestBoard(held, worse, "target unblock");
    try testing.expectEqual(@as(usize, 104), kept.routed);
    try testing.expectEqual(@as(usize, 2), kept.failed.len);
    try testing.expect(kept.cancelled);
    // A phase that improved the board is adopted whole.
    try testing.expectEqual(@as(usize, 106), keepBestBoard(held, better, "gate ladder").routed);

    // A board measured against a different denominator is not comparable, so it
    // is never called a regression.
    const scoped = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 3, .total = 4 };
    try testing.expect(!boardRegressed(held, scoped));
}

// spec: serve/route-plan - a scoped route preserves an unselected net's existing copper and reroutes only the selected net
test "scoped route preserves existing copper and reroutes the selected net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SIG", .pins = &fixture_pins }, // routable R1↔R2
        .{ .name = "OTHER", .pins = &.{} }, // its copper is supplied as retained
    };
    const placement = fixturePlacement(&parts, &nets);
    const block = fixtureBlock(null);
    const selected = [_]bool{ true, false }; // route only SIG
    // OTHER's copper sits clear of SIG's straight path (y=0) at y=-0.4.
    const existing = [_]route_policy.ExistingTrack{
        .{ .x1 = 0, .y1 = -0.4, .x2 = 3, .y2 = -0.4, .layer = 0, .width = 0.2, .net = 1 },
    };
    const diag = try routePlannedScoped(arena, &block, placement, .{}, .{
        .selected = &selected,
        .existing_tracks = &existing,
    });
    try testing.expect(diag.result.routed >= 1); // SIG routed
    var kept = false;
    for (diag.result.tracks) |t| {
        if (t.net == 1) kept = true;
    }
    try testing.expect(kept); // OTHER's retained copper carried through untouched
}

// spec: serve/route-plan - a diagnostic route preserves user copper zones as same-net source copper
test "diagnostic route grows from retained user-zone copper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const block = fixtureBlock(null);

    const plain = try routePlannedDiagnostic(arena, &block, placement, .{});
    try testing.expectEqual(@as(usize, 1), plain.result.routed);
    try testing.expect(totalTrackMm(plain.result.tracks) > 2.0);

    // Both pads sit in one same-net pour, so the diagnostic route should retain
    // only their tiny pad-centre access stubs instead of redrawing the trunk.
    const poly = [_][2]f64{
        .{ -0.3, -0.3 },
        .{ 3.3, -0.3 },
        .{ 3.3, 0.3 },
        .{ -0.3, 0.3 },
    };
    const zones = [_]route_policy.ExistingZone{.{
        .polygon = &poly,
        .layer = 0,
        .net = 0,
    }};
    const poured = try routePlannedScoped(arena, &block, placement, .{}, .{ .existing_zones = &zones });
    try testing.expectEqual(@as(usize, 1), poured.result.routed);
    try testing.expect(totalTrackMm(poured.result.tracks) < 0.5);
}

// spec: placement/router - the shared route gate applies a jointly safe deletion plan so alternate paths cannot be deleted together
// spec: serve/route-plan - the public topology cleanup seam removes deletion-invariant trace sections and connectivity-redundant non-ground vias with the same connectivity gate as a normal route
test "route gate prunes late stub and one-layer via findings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = 0, .x2 = 1.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = 2, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const selected = [_]bool{true};
    const cleaned = try pruneTopologyArtifacts(arena, placement, .{}, .{
        .tracks = &tracks,
        .vias = &vias,
        .routed = 1,
        .total = 1,
    }, .{ .selected_nets = &selected });
    try testing.expectEqual(@as(usize, 1), cleaned.tracks.len);
    try testing.expectEqual(@as(usize, 0), cleaned.vias.len);
}

// spec: serve/route-plan - the route gate's closing gloss fuses the collinear halves a junction split leaves behind while keeping the split that names a real junction
test "route gate keeps a T's split and fuses a split with nothing at its vertex" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // A true mid-span X: canonicalization gives the crossbar an endpoint at the
    // crossing, and the gloss must LEAVE it — the vertex is the junction.
    const crossed = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = -1, .x2 = 1.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
    };
    const tee = try canonicalizeGeneratedJunctions(arena, placement, .{
        .tracks = &crossed,
        .vias = &.{},
        .routed = 1,
        .total = 1,
    }, .{});
    try testing.expectEqual(@as(usize, 3), tee.tracks.len);
    try testing.expectEqual(@as(usize, 0), drc.countKind(
        try drc.checkTopology(arena, placement, tee, &.{}),
        .implicit_junction,
    ));

    // The same split with nothing left at its vertex — what a pruned partner
    // leaves — is one run again, so the board ships one section, not two.
    const halves = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const fused = try canonicalizeGeneratedJunctions(arena, placement, .{
        .tracks = &halves,
        .vias = &.{},
        .routed = 1,
        .total = 1,
    }, .{});
    try testing.expectEqual(@as(usize, 1), fused.tracks.len);
    try testing.expectEqual(@as(f64, 0), @min(fused.tracks[0].x1, fused.tracks[0].x2));
    try testing.expectEqual(@as(f64, 3), @max(fused.tracks[0].x1, fused.tracks[0].x2));
}

// spec: placement/router - a cancelled run still ships deduplicated, tail-free copper instead of raw maze output
test "a cancelled route glosses its partial board instead of shipping it raw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const run = router.Track{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const existing = [_]route_policy.ExistingTrack{
        trackAsExisting(run),
        trackAsExisting(run), // a second pass re-emitted the same section
        // …and a 0.05 mm tail its own copper already covers.
        trackAsExisting(.{ .x1 = 1.5, .y1 = 0, .x2 = 1.5, .y2 = 0.05, .layer = 0, .width = 0.2, .net = 0 }),
    };
    var cancelled: std.atomic.Value(bool) = .init(true);
    const result = try router.routeWithOptions(arena, placement, .{}, .{
        .existing_tracks = &existing,
        .stop = .{ .cancel = &cancelled },
    });
    try testing.expect(result.cancelled);
    // One section: the duplicate and the tail are both gone, and the run that
    // actually joins the two pads is untouched.
    try testing.expectEqual(@as(usize, 1), result.tracks.len);
    try testing.expectEqual(@as(f64, 0), result.tracks[0].x1);
    try testing.expectEqual(@as(f64, 3), result.tracks[0].x2);
}

// spec: placement/router - a net-scoped branch fold folds a caller's accumulated parallel legs and hands back unfoldable copper verbatim
test "the net-scoped bond fold folds a doubled leg and leaves an unfoldable group alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Barracuda's measured doubled-trunk shape, moved to the fixture origin: a
    // trunk from one land plus a second land's leg running beside it.
    const a = [2]f64{ 2.20000000000005, 2.12000000000002 };
    const b = [2]f64{ 3.9032613427087, 0.40840018177056 };
    const c = [2]f64{ 1.10000000000002, 2.69166152447922 };
    const d = [2]f64{ 2.77492286718785, 1.01673865729137 };
    const width = 0.2532;
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &route_plan_fixture_pad, .fallback = false, .x = 2.2, .y = 2.72 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &route_plan_fixture_pad, .fallback = false, .x = 1.1, .y = 3.3 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &route_plan_fixture_pad, .fallback = false, .x = b[0], .y = b[1] },
    };
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &pins }};
    var placement = fixturePlacement(&parts, &nets);
    placement.minx = 0.5;
    placement.miny = -0.2;
    placement.maxx = 4.5;
    placement.maxy = 3.9;
    // Where the branch meets the trunk: d's foot on a—b, precomputed so this
    // test needs no geometry helper from inside the placement layer.
    const foot = [2]f64{ 3.0376816771522757, 1.2782173736957065 };
    const legs = [_]router.Track{
        .{ .x1 = 2.2, .y1 = 2.72, .x2 = a[0], .y2 = a[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 1.1, .y1 = 3.3, .x2 = c[0], .y2 = c[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = c[0], .y1 = c[1], .x2 = d[0], .y2 = d[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = d[0], .y1 = d[1], .x2 = foot[0], .y2 = foot[1], .layer = 0, .width = width, .net = 0 },
    };
    const folded = try router.foldNetBranches(.{
        .arena = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .net = 0,
        .tracks = &legs,
        .vias = &.{},
    });
    try testing.expect(folded.changed);
    // A fold is only a fold when it SHORTENS the group, and it returns this
    // net's copper alone — never the board it was probed against.
    try testing.expect(trackMmOnLayer(folded.tracks, 0) + width < trackMmOnLayer(&legs, 0));
    for (folded.tracks) |t| try testing.expectEqual(@as(i32, 0), t.net);

    // The exactness the caller depends on: a group with nothing legally
    // foldable comes back as the caller's OWN slice, byte-identical, so a
    // no-op fold cannot perturb the copper it accumulated.
    const single = legs[0..2];
    const verbatim = try router.foldNetBranches(.{
        .arena = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .net = 0,
        .tracks = single,
        .vias = &.{},
    });
    try testing.expect(!verbatim.changed);
    try testing.expectEqual(single.ptr, verbatim.tracks.ptr);
    try testing.expectEqual(single.len, verbatim.tracks.len);
}

// spec: serve/route-plan - generated physical trace contacts are canonicalized before the route gate can count or persist them
test "route gate canonicalizes a width-overlap gap and preserves its retained side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.45, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const existing = [_]route_policy.ExistingTrack{trackAsExisting(tracks[0])};
    const canonical = try canonicalizeGeneratedJunctions(arena, placement, .{
        .tracks = &tracks,
        .vias = &.{},
        .routed = 1,
        .total = 1,
    }, .{ .existing_tracks = &existing });
    // Two, not the three the bridge leaves: the closing gloss fuses the weld
    // into the generated half it is collinear with (a degree-2 vertex holding
    // nothing), which is strictly better output for the same topology.
    try testing.expectEqual(@as(usize, 2), canonical.tracks.len);
    try testing.expect(sameTrack(canonical.tracks[0], existing[0]));
    try testing.expectEqual(@as(f64, 1.4), @min(canonical.tracks[1].x1, canonical.tracks[1].x2));
    try testing.expectEqual(@as(f64, 3), @max(canonical.tracks[1].x1, canonical.tracks[1].x2));
    const findings = try drc.checkTopology(arena, placement, canonical, &.{});
    try testing.expectEqual(@as(usize, 0), drc.countKind(findings, .implicit_junction));
}

test "route gate keeps one of two individually removable alternate paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = 1, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const cleaned = try pruneTopologyArtifacts(arena, placement, .{}, .{
        .tracks = &tracks,
        .vias = &.{},
        .routed = 1,
        .total = 1,
    }, .{});
    try testing.expectEqual(@as(usize, 1), cleaned.tracks.len);
    const findings = try drc.checkTopology(arena, placement, cleaned, &.{});
    try testing.expectEqual(@as(usize, 0), drc.countKind(findings, .dangling_copper));
}

// spec: placement/router - the shared route gate retains a single-layer via when removing its annulus would split the net
test "route gate keeps a connectivity-critical single-layer via" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // The via annulus is the only copper bridging these same-layer trace ends.
    // It remains suspicious DRC, but the automatic cleanup must not open SIG.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.8, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2.2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = 2, .y = 0, .dia = 0.5, .drill = 0.2, .net = 0 }};
    const cleaned = try pruneGateTopology(arena, placement, .{}, .{
        .tracks = &tracks,
        .vias = &vias,
        .routed = 1,
        .total = 1,
    }, .{});
    try testing.expectEqual(@as(usize, 2), cleaned.tracks.len);
    try testing.expectEqual(@as(usize, 1), cleaned.vias.len);
}

// spec: placement/router - the shared route gate consumes the jointly safe redundant non-ground via plan
test "route gate removes redundant multi-layer vias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const thru_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4, .thru = true }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &thru_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "J2", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &thru_pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "J2", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = fixturePlacement(&parts, &nets);
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{
        .{ .x = 0.5, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 2.5, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const cleaned = try pruneGateTopology(arena, placement, .{}, .{
        .tracks = &tracks,
        .vias = &vias,
        .routed = 1,
        .total = 1,
    }, .{});
    try testing.expect(cleaned.vias.len < vias.len);
}

// ── Topology-planner wiring ─────────────────────────────────────────────────

/// Lower `plan` over the one-net two-pad SIG fixture — the shared body of the
/// topology wiring tests, which differ only in the plan they hand the seam.
fn lowerTwoPad(arena: std.mem.Allocator, plan: env_mod.PcbPlanSpec) std.mem.Allocator.Error!Lowered {
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const block = fixtureBlock(plan);
    return lower(arena, &block, fixturePlacement(&parts, &nets));
}

// spec: serve/route-plan - a topology-flagged route wave lowers into planner corridor guides for its nets
test "a topology-flagged wave lowers into planner guides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const waves = [_]env_mod.PlanWave{.{ .name = "all", .rest = true }};
    const lowered = try lowerTwoPad(arena, .{ .route = &waves, .topology = true });
    try testing.expect(lowered.options.guides.tracks.len > 0);
    // The net may change layer, so the planner must never leave it tracks-only
    // (a tracks-only guide taxes every via on it board-wide — see topo_plan).
    try testing.expect(lowered.options.guides.vias.len > 0);
    const stats = lowered.topology orelse return error.PlannerDidNotRun;
    try testing.expectEqual(@as(usize, 1), stats.waves_planned);
    try testing.expectEqual(@as(usize, 1), stats.guides_emitted);
}

// spec: serve/route-plan - the same plan without the topology flag lowers to exactly the guides it had before
test "an unflagged plan lowers with no planner guides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const waves = [_]env_mod.PlanWave{.{ .name = "all", .rest = true }};
    const lowered = try lowerTwoPad(arena, .{ .route = &waves });
    try testing.expect(lowered.topology == null);
    try testing.expectEqual(@as(usize, 0), lowered.options.guides.tracks.len);
    try testing.expectEqual(@as(usize, 0), lowered.options.guides.vias.len);
}

// spec: serve/route-plan - a net whose wave authored waypoints keeps them and receives no planner guide
test "authored waypoints outrank a planner corridor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const points = [_]env_mod.PlanWaypoint{.{ .x = 1.5, .y = 0, .layer = "F.Cu" }};
    const waves = [_]env_mod.PlanWave{.{
        .name = "all",
        .rest = true,
        .corridor = .{ .waypoints = &points },
    }};
    const lowered = try lowerTwoPad(arena, .{ .route = &waves, .topology = true });
    try testing.expectEqual(@as(usize, 1), lowered.options.net[0].waypoints.len);
    try testing.expectEqual(@as(usize, 0), lowered.options.guides.tracks.len);
    const stats = lowered.topology orelse return error.PlannerDidNotRun;
    try testing.expectEqual(@as(usize, 0), stats.guides_emitted);
}

/// Two independent two-pad nets on separate rows, so a plan can flag the wave
/// claiming one and leave the wave claiming the other alone.
fn fourPadParts() [4]optimizer.Part {
    return .{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 0, .y = 3 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_plan_fixture_pad, .fallback = false, .x = 3, .y = 3 },
    };
}

const pins_b = [_]export_kicad.FlatPin{
    .{ .ref_des = "R3", .pin = "1" },
    .{ .ref_des = "R4", .pin = "1" },
};

/// Every net index the merged guide set names, tracks and vias together.
fn guidedNets(arena: std.mem.Allocator, guides: route_policy.Guides) std.mem.Allocator.Error![]const i32 {
    var out: std.ArrayList(i32) = .empty;
    for (guides.tracks) |t| try out.append(arena, t.net);
    for (guides.vias) |v| try out.append(arena, v.net);
    return out.toOwnedSlice(arena);
}

// spec: serve/route-plan - only a topology-flagged wave's nets receive planner guides when a plan mixes flagged and unflagged waves
test "only the flagged wave's nets receive planner guides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = fourPadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "A", .pins = &fixture_pins },
        .{ .name = "B", .pins = &pins_b },
    };
    var placement = fixturePlacement(&parts, &nets);
    placement.maxy = 3.5;
    const waves = [_]env_mod.PlanWave{
        .{ .name = "planned", .nets = &.{"A"}, .corridor = .{ .topology = true } },
        .{ .name = "rest", .rest = true },
    };
    const block = fixtureBlock(.{ .route = &waves });
    const lowered = try lower(arena, &block, placement);
    try testing.expect(lowered.options.guides.tracks.len > 0);
    // Every guide belongs to net 0 ("A"); the unflagged wave's "B" gets none.
    const guided = try guidedNets(arena, lowered.options.guides);
    for (guided) |net| try testing.expectEqual(@as(i32, 0), net);
    const stats = lowered.topology orelse return error.PlannerDidNotRun;
    // Only the first wave is relaxed: the unflagged one behind it emits nothing
    // and its capacity stamps have no later wave to read them.
    try testing.expectEqual(@as(usize, 1), stats.waves_planned);
    try testing.expectEqual(@as(usize, 1), stats.guides_emitted);
}

// spec: serve/route-plan - a route_experiment topology override plans a topology for every route wave of that run alone
test "the route_experiment topology override flags every route wave" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const block = fixtureBlock(null);
    // The override authors NO `(topology)`; only the request-local flag does.
    const waves = [_]env_mod.PlanWave{.{ .name = "exp", .rest = true }};
    const override: env_mod.PcbPlanSpec = .{ .route = &waves };
    const off = try routeExperiment(arena, &block, placement, .{}, .{ .plan = override });
    try testing.expect(off.topology == null);
    const on = try routeExperiment(arena, &block, placement, .{}, .{ .plan = override, .topology = true });
    const stats = on.topology orelse return error.PlannerDidNotRun;
    try testing.expectEqual(@as(usize, 1), stats.waves_planned);
    try testing.expectEqual(@as(usize, 1), stats.guides_emitted);
    try testing.expectEqual(@as(usize, 1), on.result.routed);
}

// spec: serve/route-plan - a pair channel's pinch owners join the deepening round's nomination sweep and nowhere else, are judged by the same vacate policy as swept copper, and a wall owned by a keepout or the board edge is reported and never nominated
test "a pair channel's pinch owners reach the deepening sweep and nowhere else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try openTargetPlacement(arena);
    var accept = try target_unblock.Gate.init(arena, placement, &.{});
    defer accept.deinit();
    var run = UnblockRun{
        .alloc = arena,
        .placement = placement,
        .params = .{},
        .options = .{},
        .lim = target_unblock_limits,
        .accept = &accept,
        .baseline = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 3 },
        .measured = .{},
    };

    // Three reports: one nameable owner beside a keepout side, the same owner
    // again, and an index no net answers to.
    var log = route_policy.PinchLog{};
    log.record(.{ .pair = .{ 0, 1 }, .nets = .{ 2, -1 }, .have_mm = 0.31, .need_mm = 0.52 });
    log.record(.{ .pair = .{ 0, 1 }, .nets = .{ 2, 2 }, .have_mm = 0.31, .need_mm = 0.52 });
    log.record(.{ .pair = .{ 0, 1 }, .nets = .{ 99, -1 } });
    unblockRecordPinch(&run, &log);
    // Only real, distinct nets are kept: the keepout side names nothing a rip
    // could move, and neither does an index off the end of the net list.
    try testing.expectEqual(@as(usize, 1), run.pinch.items.len);
    try testing.expectEqual(@as(usize, 2), run.pinch.items[0]);

    // Outside a deepening round the sweep is exactly the sweep it always was.
    const swept = [_]blocker_nomination.Candidate{.{ .net_i = 0, .dist = 1.0 }};
    try testing.expectEqual(swept.len, (try unblockPinchCandidates(&run, &swept)).len);

    // Inside one the wall joins it, at distance zero and behind the swept
    // candidates, so the nearer occupant of the target's own hop still leads.
    run.pinch_use = .nominate;
    const offered = try unblockPinchCandidates(&run, &swept);
    try testing.expectEqual(@as(usize, 2), offered.len);
    try testing.expectEqual(@as(usize, 0), offered[0].net_i);
    try testing.expectEqual(@as(usize, 2), offered[1].net_i);
    try testing.expectEqual(@as(f64, 0), offered[1].dist);

    // A net the sweep already found is never offered twice.
    const both = [_]blocker_nomination.Candidate{ .{ .net_i = 0, .dist = 1.0 }, .{ .net_i = 2, .dist = 3.0 } };
    try testing.expectEqual(both.len, (try unblockPinchCandidates(&run, &both)).len);
}

// spec: serve/route-plan - The retained-copper bundle handed to the connectivity oracle carries the board's poured zones, so a net joined only through a pour is not reported open
test "the retained-copper bundle carries the board's pours, not only its tracks and vias" {
    // Two hand-copies of this projection existed. The live-route one carried
    // `zones`; the sub-circuit seed one did not, so the seed pass asked the
    // SAME connectivity oracle a question with the board's copper pours
    // missing — a net joined only through a plane read as open there and as
    // connected in describe/fabrication. One projection, whole bundle.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    const zones = [_]route_policy.ExistingZone{
        .{ .polygon = &poly, .layer = 0, .net = 0, .copper = true, .priority = 2 },
        // A keepout is not poured copper; `fab_readiness` documents that the
        // serve layer filters it out before building `copper.zones`.
        .{ .polygon = &poly, .layer = 1, .net = -2, .copper = false },
    };
    const tracks = [_]route_policy.ExistingTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]route_policy.ExistingVia{
        .{ .x = 1, .y = 0, .dia = 0.6, .drill = 0.3, .net = 0 },
    };
    const options = route_policy.Options{
        .existing_tracks = &tracks,
        .existing_vias = &vias,
        .existing_zones = &zones,
    };

    const carried = try retainedZones(arena, placement, options);
    try testing.expectEqual(@as(usize, 1), carried.len);
    try testing.expectEqualStrings("GND", carried[0].net);
    try testing.expectEqual(@as(i64, 2), carried[0].priority);

    const bundle = try retainedCopper(arena, options, carried);
    try testing.expectEqual(@as(usize, 1), bundle.tracks.len);
    try testing.expectEqual(@as(usize, 1), bundle.vias.len);
    try testing.expectEqual(@as(usize, 1), bundle.zones.len);
    try testing.expectEqual(@as(f64, 0.2), bundle.tracks[0].width);
    try testing.expectEqual(@as(f64, 0.3), bundle.vias[0].drill);
}

// spec: serve/route-plan - cancelled candidates reconcile retained copper with the connectivity oracle without continuing search
// spec: serve/route-plan - diagnostic routing produces the ordinary route geometry before probing the final copper
test "routing audit cancellation oracle and diagnostic parity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const existing = [_]route_policy.ExistingTrack{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    var cancel: std.atomic.Value(bool) = .init(true);
    const cancelled = try routeLowered(arena, placement, .{}, .{ .existing_tracks = &existing, .stop = .{ .cancel = &cancel } });
    try testing.expect(cancelled.cancelled);
    try testing.expectEqual(@as(usize, 1), cancelled.routed);
    try testing.expectEqual(@as(usize, 1), cancelled.total);
    try testing.expectEqual(@as(usize, 0), cancelled.failed.len);
    const plain = try routeLowered(arena, placement, .{}, .{});
    const diagnostic = try routeLoweredDiagnostic(arena, placement, .{}, .{});
    try testing.expectEqualDeep(plain.tracks, diagnostic.result.tracks);
    try testing.expectEqualDeep(plain.vias, diagnostic.result.vias);
    try testing.expectEqual(plain.routed, diagnostic.result.routed);
}
