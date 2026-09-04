//! `placement_sensitivity` CLI tool — which parts are load-bearing?
//!
//! The board that motivated this: three sub-millimetre edits inside barracuda's
//! `lmx2595` group (R42 moved 0.2 mm in x, C91 de-rotated in place, C100 moved
//! 0.2 mm in y) cost the full-board route SEVEN nets, deterministically, and
//! tripled the DRC error count. Nothing in the toolchain called those three
//! parts fragile, because nothing ever ASKED — placement quality was only ever
//! measured on the board as it stands, never on the board one nudge away.
//!
//! This tool asks. For each probed part it perturbs the pose by ±`delta_mm` on
//! each axis (optionally ±90°) and, for each perturbation, re-routes ONLY the
//! affected scope — the nets that touch the part plus the nets whose copper runs
//! through the neighbourhood it sweeps — against the rest of the board's
//! existing copper, held as a hard obstacle. A whole-board route per
//! perturbation is ~150 s and so cannot be a probe; a scoped one is seconds.
//!
//! Two properties are deliberate:
//!
//!   * **It routes through `route_plan`**, like every other routing surface, so
//!     an authored `(pcb-plan (route …))` wave order and layer policy steer the
//!     probe exactly as they steer the commit. A probe routed under different
//!     rules than the board would answer about a different board.
//!   * **Flips are the connectivity oracle's verdict**, never the router's
//!     claim: each candidate's copper goes through `fab_readiness.netConnectivity`
//!     (the same tally `route_close.reconcile` reports), because the router
//!     over-claims — it counts a plane-carried net done while the oracle finds
//!     seventeen islands, and a sensitivity probe built on that would report
//!     stability that is not there.
//!
//! **The baseline is a scoped re-route at the ORIGINAL poses**, not the saved
//! copper. The scope's copper is thrown away and redrawn for every candidate
//! including the unperturbed one, so a net that the router simply draws
//! differently on a second look is not reported as a flip — only a net whose
//! verdict actually depends on the pose is.
//!
//! **The honest limit**: a scoped probe sees contention inside the scope. Damage
//! that flows through a net whose contenders are spread across the whole board
//! (a supply rail, a bus clock) is under-counted here, because the far half of
//! that contention is pinned by retained copper the probe is not allowed to
//! move. A `stable` verdict therefore means "stable against its neighbours",
//! not "safe to move" — the reported `scope` names exactly what was re-asked.

const std = @import("std");
const mcp_arg_names = @import("mcp_arg_names.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const route_policy = @import("../placement/route_policy.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const pour = @import("../placement/pour.zig");
const fab_readiness = @import("../fab_readiness.zig");
const env_mod = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const geometry = @import("../placement/geometry.zig");
const export_gerber = @import("../export_gerber.zig");
const log = @import("../infra/log.zig");
const clock = @import("../infra/clock.zig");
const net_name = @import("../net_name.zig");

const HandlerError = pcb_layout_page.HandlerError;

/// Default pose nudge (mm). 0.2 mm is the size of the edits that cost barracuda
/// seven nets — small enough that a designer would make it without a second
/// thought, which is exactly why it needs measuring.
const default_delta_mm: f64 = 0.2;

/// Ceiling on `delta_mm`. Past a couple of millimetres a "perturbation" is a
/// re-placement: the part lands on top of its neighbours and every net in the
/// scope fails for reasons that say nothing about sensitivity.
const max_delta_mm: f64 = 2.0;

/// How far outside a probed part's courtyard foreign copper still counts as its
/// immediate contender (mm). Wide enough to catch the tracks actually threading
/// past the part plus their clearance, narrow enough that a probe does not
/// nominate half the board and turn into the whole-board route it exists to
/// avoid.
const contender_margin_mm: f64 = 2.5;

/// Ceiling on parts probed in one call. Each part costs (perturbations + 1)
/// scoped routes, so an unbounded `refs` list is an unbounded run.
const max_probed_parts: usize = 24;

/// Progress to the server log — a multi-part probe runs for minutes and an
/// agent watching only the JSON reply cannot tell slow from hung.
fn progress(comptime fmt: []const u8, args: anytype) void {
    log.progress("placement_sensitivity: " ++ fmt, args);
}

// ── Perturbation set ────────────────────────────────────────────────────────

/// One candidate pose offset applied to the probed part. `label` is the
/// caller-facing name of the move ("+x", "-90deg"); the unperturbed baseline is
/// the all-zero value, which every part is measured against.
const Perturb = struct {
    label: []const u8,
    dx: f64 = 0,
    dy: f64 = 0,
    drot: f64 = 0,
};

/// The baseline "perturbation" — no move at all. Routed like any other
/// candidate so the comparison controls for the router's own run-to-run shape.
const baseline_perturb: Perturb = .{ .label = "baseline" };

/// The perturbation set for one part: ±`delta` on each axis, plus ±90° when the
/// caller asked for rotations. Translation first so a truncated read of the
/// results still covers the moves a hand-drag makes.
fn perturbationSet(
    alloc: std.mem.Allocator,
    delta: f64,
    rotations: bool,
) std.mem.Allocator.Error![]const Perturb {
    var out: std.ArrayList(Perturb) = .empty;
    try out.append(alloc, .{ .label = "+x", .dx = delta });
    try out.append(alloc, .{ .label = "-x", .dx = -delta });
    try out.append(alloc, .{ .label = "+y", .dy = delta });
    try out.append(alloc, .{ .label = "-y", .dy = -delta });
    if (rotations) {
        try out.append(alloc, .{ .label = "+90deg", .drot = 90 });
        try out.append(alloc, .{ .label = "-90deg", .drot = -90 });
    }
    return out.toOwnedSlice(alloc);
}

/// Clamp a caller's `delta_mm` into the range a perturbation is meaningful over
/// (see `max_delta_mm`); a non-positive request keeps the default.
fn clampDelta(want: f64) f64 {
    if (!(want > 0)) return default_delta_mm;
    return @min(want, max_delta_mm);
}

// ── Flip classification ─────────────────────────────────────────────────────

/// Which way a net's connectivity verdict moved between the baseline scoped
/// route and a perturbed one.
const FlipKind = enum {
    /// Connected at the baseline pose, open after the move — the finding this
    /// tool exists for.
    lost,
    /// Open at the baseline pose, connected after the move. Real information:
    /// it says the current pose is the one costing a net.
    gained,

    fn fromStr(self: FlipKind) []const u8 {
        return if (self == .lost) "routed" else "open";
    }

    fn toStr(self: FlipKind) []const u8 {
        return if (self == .lost) "open" else "routed";
    }
};

/// One net whose routed/open verdict changed under a perturbation.
const Flip = struct { net: []const u8, kind: FlipKind };

/// Classify the connectivity delta between two runs of the SAME netlist.
///
/// Compared per net by INDEX, because both sides are `netConnectivity` over
/// placements flattened from one block — same nets, same order. A length
/// mismatch means the two sides are not the same board and nothing may be
/// concluded, so it yields no flips rather than a misaligned diff.
///
/// Nets that need no copper (`routable == false` — a single-pad net, or one a
/// declared plane carries) are skipped on BOTH sides, matching exactly what
/// `routableTally` counts. Without that a plane net would flicker into the
/// report on every probe and bury the real findings.
fn classifyFlips(
    alloc: std.mem.Allocator,
    base: []const fab_readiness.NetStatus,
    pert: []const fab_readiness.NetStatus,
) std.mem.Allocator.Error![]const Flip {
    if (base.len != pert.len) return &.{};
    var out: std.ArrayList(Flip) = .empty;
    for (base, pert) |b, p| {
        if (!b.routable or !p.routable) continue;
        if (b.connected == p.connected) continue;
        try out.append(alloc, .{
            .net = p.name,
            .kind = if (b.connected) .lost else .gained,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// How many of `states` are routable and connected — the probe's own spelling of
/// `routableTally.routed`, over a list it already holds.
fn connectedCount(states: []const fab_readiness.NetStatus) usize {
    var n: usize = 0;
    for (states) |s| {
        if (s.routable and s.connected) n += 1;
    }
    return n;
}

/// How many of `states` need copper at all (`routableTally.total`).
fn routableCount(states: []const fab_readiness.NetStatus) usize {
    var n: usize = 0;
    for (states) |s| {
        if (s.routable) n += 1;
    }
    return n;
}

/// The one flip a part's verdict is written about: which move, which net, which
/// direction.
const Headline = struct { label: []const u8, net: []const u8, kind: FlipKind };

/// Fold one perturbation's flips into the running headline.
///
/// A net the move BREAKS outranks one it fixes, and once a broken net is held
/// nothing displaces it — that is the finding a reader has to see first. But a
/// GAINED flip still makes the part load-bearing, and deliberately so: a net
/// that routes only after a 0.2 mm nudge is a net that fails to route at the
/// pose on the board, which is the same knife edge read from the other side.
/// Treating a gain as "stable" would file the most actionable case there is —
/// "this part is in the wrong place right now" — under no finding at all.
fn pickHeadline(current: ?Headline, label: []const u8, flips: []const Flip) ?Headline {
    if (current) |c| {
        if (c.kind == .lost) return c;
    }
    for (flips) |f| {
        if (f.kind == .lost) return .{ .label = label, .net = f.net, .kind = .lost };
    }
    if (current != null) return current;
    if (flips.len == 0) return null;
    return .{ .label = label, .net = flips[0].net, .kind = flips[0].kind };
}

/// A part's verdict sentence. `stable` names the window it held over; a
/// load-bearing part names the headline net and the move that flips it, because
/// that pair is what a reader acts on.
fn verdictText(
    alloc: std.mem.Allocator,
    delta: f64,
    headline: ?Headline,
) std.mem.Allocator.Error![]const u8 {
    const h = headline orelse
        return std.fmt.allocPrint(alloc, "stable within ±{d:.2} mm", .{delta});
    return std.fmt.allocPrint(
        alloc,
        "load-bearing: {s} {s} on {s}",
        .{ h.net, if (h.kind == .lost) "opens" else "closes", h.label },
    );
}

// ── Scope selection ─────────────────────────────────────────────────────────

/// The nets one probe re-routes, and why each was included.
const Scope = struct {
    /// Per-net enable mask over `placement.nets`, handed to `ScopedRoute`.
    mask: []bool,
    /// Nets landing on the probed part — the ones the move relocates.
    own: usize = 0,
    /// Nets pulled in because their copper threads the part's neighbourhood.
    contenders: usize = 0,
};

/// Distance from point `(px,py)` to segment `(x1,y1)-(x2,y2)`.
fn segPointDistance(x1: f64, y1: f64, x2: f64, y2: f64, px: f64, py: f64) f64 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 0) return std.math.hypot(px - x1, py - y1);
    const t = @max(0.0, @min(1.0, ((px - x1) * dx + (py - y1) * dy) / len2));
    return std.math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
}

/// The neighbourhood radius (mm) a probe of `part` contends over: the
/// courtyard's own reach, plus the nudge it may take, plus the margin foreign
/// copper is still a contender within.
fn contendRadius(part: optimizer.Part, delta: f64) f64 {
    return std.math.hypot(part.hw, part.hh) + delta + contender_margin_mm;
}

/// Build the affected scope for `part_i`: every net with a pin on the part
/// (whose geometry the move changes outright), plus every net whose existing
/// copper passes within `contendRadius` of it (its immediate contenders — the
/// copper that has to move aside, or that will take the corridor this net
/// vacates). Everything else keeps its copper and is never re-asked.
fn scopeFor(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: router.RouteResult,
    part_i: usize,
    delta: f64,
) std.mem.Allocator.Error!Scope {
    const part = placement.parts[part_i];
    var s = Scope{ .mask = try alloc.alloc(bool, placement.nets.len) };
    @memset(s.mask, false);
    for (placement.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            if (!std.mem.eql(u8, pin.ref_des, part.ref_des)) continue;
            s.mask[ni] = true;
            s.own += 1;
            break;
        }
    }
    const r = contendRadius(part, delta);
    for (copper.tracks) |t| {
        const ni = netIndexOf(t.net, placement.nets.len) orelse continue;
        if (s.mask[ni]) continue;
        if (segPointDistance(t.x1, t.y1, t.x2, t.y2, part.x, part.y) > r) continue;
        s.mask[ni] = true;
        s.contenders += 1;
    }
    for (copper.vias) |v| {
        const ni = netIndexOf(v.net, placement.nets.len) orelse continue;
        if (s.mask[ni]) continue;
        if (std.math.hypot(v.x - part.x, v.y - part.y) > r) continue;
        s.mask[ni] = true;
        s.contenders += 1;
    }
    return s;
}

/// A copper object's net index when it names a real net of this board, else
/// null (unnetted copper is an obstacle, never a scope member).
fn netIndexOf(net: i32, n_nets: usize) ?usize {
    if (net < 0) return null;
    const ni: usize = @intCast(net);
    return if (ni < n_nets) ni else null;
}

/// The scope's net names, for the report — an agent reading a `stable` verdict
/// has to be able to see exactly what was re-asked before trusting it.
fn scopeNames(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    mask: []const bool,
) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (mask, 0..) |on, ni| {
        if (on) try out.append(alloc, placement.nets[ni].name);
    }
    return out.toOwnedSlice(alloc);
}

// ── One candidate route ─────────────────────────────────────────────────────

/// Everything a single candidate route needs that does not change between
/// candidates: the block, the board's saved copper and pours, the router
/// geometry, and the DRC rule set.
const Board = struct {
    block: *env_mod.DesignBlock,
    project_dir: []const u8,
    /// The shown layout's persisted copper, rebuilt against the current netlist.
    copper: router.RouteResult,
    /// The shown layout's user pours, as connecting copper for the oracle.
    zones: []const pour.UserZone,
    /// The same pours as router source copper.
    zone_sources: []const route_policy.ExistingZone,
    params: router.RouteParams,
    rules: drc_rules.Rules,
};

/// What one candidate pose produced.
const Candidate = struct {
    states: []const fab_readiness.NetStatus,
    drc_errors: usize,
    ms: u64,
};

/// The board's copper for every net OUTSIDE `selected`, as retained obstacles.
/// This is what makes the probe incremental: the scope is redrawn, everything
/// else is pinned exactly where the saved layout put it.
fn retainedCopper(
    alloc: std.mem.Allocator,
    copper: router.RouteResult,
    selected: []const bool,
) std.mem.Allocator.Error!route_plan.ScopedRoute {
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (copper.tracks) |t| {
        if (netIndexOf(t.net, selected.len)) |ni| {
            if (selected[ni]) continue;
        }
        try tracks.append(alloc, .{
            .x1 = t.x1,
            .y1 = t.y1,
            .x2 = t.x2,
            .y2 = t.y2,
            .layer = t.layer,
            .width = t.width,
            .net = t.net,
        });
    }
    for (copper.vias) |v| {
        if (netIndexOf(v.net, selected.len)) |ni| {
            if (selected[ni]) continue;
        }
        try vias.append(alloc, .{ .x = v.x, .y = v.y, .dia = v.dia, .drill = v.drill, .net = v.net });
    }
    return .{ .selected = selected, .existing_tracks = tracks.items, .existing_vias = vias.items };
}

/// The poses of `base` with `part_i` nudged by `p`.
fn posesWith(
    alloc: std.mem.Allocator,
    base: optimizer.Placement,
    part_i: usize,
    p: Perturb,
) std.mem.Allocator.Error![]const optimizer.RefPose {
    const out = try alloc.alloc(optimizer.RefPose, base.parts.len);
    for (base.parts, 0..) |part, i| {
        const hit = i == part_i;
        out[i] = .{
            .ref = part.ref_des,
            .x = part.x + (if (hit) p.dx else 0),
            .y = part.y + (if (hit) p.dy else 0),
            .rot = part.rot + (if (hit) p.drot else 0),
            .side = part.side,
            .locked = part.locked,
        };
    }
    return out;
}

/// Route one candidate pose and read its connectivity + geometry DRC.
///
/// Everything here is request-local and lives on the caller's (per-candidate)
/// arena: nothing is persisted, so a probe can never move the board it measures.
fn routeCandidate(
    arena: std.mem.Allocator,
    board: Board,
    base: optimizer.Placement,
    part_i: usize,
    scoped: struct { mask: []bool, perturb: Perturb },
) !Candidate {
    const started_ms = clock.milliTimestamp();
    const poses = try posesWith(arena, base, part_i, scoped.perturb);
    const placement = try optimizer.placeFromPoses(
        arena,
        board.block,
        board.project_dir,
        .{ .poses = poses, .outline = optimizer.outlineOf(&base) },
        optimizer.Params{},
    );
    var sr = try retainedCopper(arena, board.copper, scoped.mask);
    sr.existing_zones = board.zone_sources;
    var route_options = route_plan.lowerOrEmpty(arena, board.block, placement);
    route_options.selected_nets = sr.selected;
    route_options.existing_tracks = sr.existing_tracks;
    route_options.existing_vias = sr.existing_vias;
    route_options.existing_zones = sr.existing_zones;
    _ = try pcb_layout_page.addSubcircuitRouteSeeds(arena, board.project_dir, board.block, placement, board.params, &route_options);
    const routed = try route_plan.routeLowered(arena, placement, board.params, route_options);
    const gerber_copper = export_gerber.Copper{
        .tracks = routed.tracks,
        .arcs = routed.arcs,
        .rf_paths = routed.rf_port_outcomes,
        .vias = routed.vias,
        .zones = board.zones,
    };
    return .{
        .states = try fab_readiness.netConnectivity(arena, placement, gerber_copper),
        .drc_errors = errorCount(arena, board, placement, routed),
        .ms = elapsedMs(started_ms),
    };
}

/// Milliseconds since `started_ms`, floored at zero so a clock step backwards
/// cannot report a negative duration.
fn elapsedMs(started_ms: i64) u64 {
    const took = clock.milliTimestamp() - started_ms;
    return if (took > 0) @intCast(took) else 0;
}

/// Error-severity geometry violations on a candidate board, after the design's
/// own DRC policy has had its say. Geometry only — the `net open` airwire is the
/// thing the connectivity verdict already reports, and counting it twice would
/// make every flip look like two findings.
fn errorCount(
    arena: std.mem.Allocator,
    board: Board,
    placement: optimizer.Placement,
    routed: router.RouteResult,
) usize {
    const raw = drc.check(arena, placement, routed, board.params.clearance) catch return 0;
    var n: usize = 0;
    for (drc_rules.apply(arena, board.rules, raw)) |v| {
        if (v.severity == .err) n += 1;
    }
    return n;
}

/// Copy a candidate's connectivity verdicts onto `alloc`, so the baseline can
/// outlive the arena its route was built on. Net names are duplicated too — they
/// point into the per-candidate placement's flattened netlist.
fn dupeStates(
    alloc: std.mem.Allocator,
    states: []const fab_readiness.NetStatus,
) std.mem.Allocator.Error![]const fab_readiness.NetStatus {
    const out = try alloc.alloc(fab_readiness.NetStatus, states.len);
    for (states, 0..) |s, i| {
        out[i] = .{
            .name = try alloc.dupe(u8, s.name),
            .routable = s.routable,
            .connected = s.connected,
            .islands = s.islands,
        };
    }
    return out;
}

// ── Part resolution ─────────────────────────────────────────────────────────

/// Case-insensitive equality (ASCII), for a caller-typed part name.
fn eqNoCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Resolve a caller's part name the way `?refs=` and `?crop=` do: full ref-des,
/// sub-block leaf, or the stable module-local origin name — so `lmx2595/R42`,
/// `R42`, and the origin key all reach the same part.
fn findPart(placement: optimizer.Placement, want: []const u8) ?usize {
    for (placement.parts, 0..) |part, pi| {
        if (eqNoCase(part.ref_des, want)) return pi;
        if (eqNoCase(net_name.leaf(part.ref_des), want)) return pi;
        if (pi < placement.instances.len and eqNoCase(placement.instances[pi].origin_key, want)) return pi;
    }
    return null;
}

/// The part's stable module-local name, empty when it has none.
fn originOf(placement: optimizer.Placement, pi: usize) []const u8 {
    if (pi >= placement.instances.len) return "";
    return placement.instances[pi].origin_key;
}

// ── Tool entry ──────────────────────────────────────────────────────────────

/// One probed part's full result, ready to serialize.
const PartReport = struct {
    ref: []const u8,
    origin: []const u8,
    x: f64,
    y: f64,
    rot: f64,
    scope_nets: []const []const u8,
    own: usize,
    contenders: usize,
    base_routed: usize,
    base_total: usize,
    base_drc: usize,
    runs: []const RunReport,
    verdict: []const u8,
    load_bearing: bool,
    ms: u64,
};

/// One perturbation's result within a part's report.
const RunReport = struct {
    label: []const u8,
    dx: f64,
    dy: f64,
    drot: f64,
    routed: usize,
    drc_errors: usize,
    flips: []const Flip,
    ms: u64,
};

/// `placement_sensitivity` — probe which parts a sub-millimetre move breaks.
pub fn mcpPlacementSensitivity(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = argStr(args_val, "name") orelse return fail(out, alloc, "missing required arg: name");
    const refs = try argNames(alloc, args_val, "refs");
    if (refs.len == 0) return fail(out, alloc, "missing required arg: refs (the parts to probe)");
    const layout_arg = argStr(args_val, "layout");
    const delta = clampDelta(argFloat(args_val, "delta_mm") orelse default_delta_mm);
    const rotations = argBool(args_val, "rotations") orelse false;

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return failFmt(out, alloc, "could not resolve layout: {s}", .{@errorName(e)});
    const copper = solved.restored.routes orelse
        return fail(out, alloc, "the shown layout carries no copper — route or draw some first, then probe");

    const board = Board{
        .block = solved.block,
        .project_dir = project_dir,
        .copper = copper,
        .zones = solved.shown_zones.user,
        .zone_sources = solved.shown_zones.sources,
        .params = solved.placement.rules.design.routeParams(),
        .rules = drc_rules.load(alloc, project_dir, name),
    };
    const set = try perturbationSet(alloc, delta, rotations);

    var reports: std.ArrayList(PartReport) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    for (refs, 0..) |ref, i| {
        if (i >= max_probed_parts) break;
        const pi = findPart(solved.placement, ref) orelse {
            try unknown.append(alloc, ref);
            continue;
        };
        const rep = probePart(alloc, &arena_state, board, solved.placement, .{
            .part = pi,
            .delta = delta,
            .set = set,
        }) catch |e| return failFmt(out, alloc, "probe failed on {s}: {s}", .{ ref, @errorName(e) });
        try reports.append(alloc, rep);
    }
    return writeResult(out, .{
        .alloc = alloc,
        .design = name,
        .layout = pcb_layout_page.mcpWorkingName(alloc, project_dir, name, layout_arg),
        .delta = delta,
        .rotations = rotations,
        .parts = reports.items,
        .unknown = unknown.items,
    });
}

/// What `probePart` is asked to do — the part index, the window, and the
/// perturbation set (built once for the whole call).
const ProbeJob = struct { part: usize, delta: f64, set: []const Perturb };

/// Probe one part: scope it, route the unperturbed baseline, then route each
/// perturbation and diff its connectivity against that baseline.
///
/// Each candidate route is built on `arena`, which is RESET between candidates —
/// a full-board router grid per perturbation would otherwise accumulate into
/// gigabytes over a multi-part probe. Everything that outlives a candidate
/// (the baseline verdicts, the flips, the scope names) is copied onto `alloc`
/// before the reset.
fn probePart(
    alloc: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    board: Board,
    base: optimizer.Placement,
    job: ProbeJob,
) !PartReport {
    const started_ms = clock.milliTimestamp();
    const part = base.parts[job.part];
    const scope = try scopeFor(alloc, base, board.copper, job.part, job.delta);
    progress("{s}: scope {d} nets ({d} own, {d} contenders)", .{
        part.ref_des,
        scope.own + scope.contenders,
        scope.own,
        scope.contenders,
    });

    _ = arena_state.reset(.retain_capacity);
    const base_run = try routeCandidate(arena_state.allocator(), board, base, job.part, .{
        .mask = scope.mask,
        .perturb = baseline_perturb,
    });
    const base_states = try dupeStates(alloc, base_run.states);
    const base_drc = base_run.drc_errors;

    var runs: std.ArrayList(RunReport) = .empty;
    var headline: ?Headline = null;
    for (job.set) |p| {
        _ = arena_state.reset(.retain_capacity);
        const cand = try routeCandidate(arena_state.allocator(), board, base, job.part, .{
            .mask = scope.mask,
            .perturb = p,
        });
        const flips = try dupeFlips(alloc, try classifyFlips(arena_state.allocator(), base_states, cand.states));
        headline = pickHeadline(headline, p.label, flips);
        progress("{s}: {s} → routed {d} (base {d}), {d} flips", .{
            part.ref_des,
            p.label,
            connectedCount(cand.states),
            connectedCount(base_states),
            flips.len,
        });
        try runs.append(alloc, .{
            .label = p.label,
            .dx = p.dx,
            .dy = p.dy,
            .drot = p.drot,
            .routed = connectedCount(cand.states),
            .drc_errors = cand.drc_errors,
            .flips = flips,
            .ms = cand.ms,
        });
    }
    return .{
        .ref = part.ref_des,
        .origin = originOf(base, job.part),
        .x = part.x,
        .y = part.y,
        .rot = part.rot,
        .scope_nets = try scopeNames(alloc, base, scope.mask),
        .own = scope.own,
        .contenders = scope.contenders,
        .base_routed = connectedCount(base_states),
        .base_total = routableCount(base_states),
        .base_drc = base_drc,
        .runs = runs.items,
        .verdict = try verdictText(alloc, job.delta, headline),
        .load_bearing = headline != null,
        .ms = elapsedMs(started_ms),
    };
}

/// Copy a candidate's flips (net names included) onto the longer-lived
/// allocator before its arena is reset.
fn dupeFlips(alloc: std.mem.Allocator, flips: []const Flip) std.mem.Allocator.Error![]const Flip {
    const out = try alloc.alloc(Flip, flips.len);
    for (flips, 0..) |f, i| out[i] = .{ .net = try alloc.dupe(u8, f.net), .kind = f.kind };
    return out;
}

// ── Result serialization ────────────────────────────────────────────────────

/// The one field of the result an agent must go read before trusting a `stable`
/// verdict, spelled as it appears in the payload. Named here (and asserted by a
/// test against the serialized JSON) so a rename of the key cannot leave the
/// caller-facing note pointing at a field that no longer exists.
const scope_nets_path = "scope.nets";

/// The limit every reader of a `stable` verdict has to know about, stated in the
/// payload rather than only in the docs.
const limits_note =
    "Each perturbation re-routes only the part's own nets plus the nets whose copper " ++
    "runs through its neighbourhood; the rest of the board's copper is pinned. Damage " ++
    "that flows through a net contended across the whole board (a supply rail, a bus " ++
    "clock) is therefore under-counted — 'stable' means stable against the neighbours " ++
    "listed in " ++ scope_nets_path ++ ", not safe to move. Measured on barracuda's lmx2595 group: at " ++
    "the 0.2 mm default this flags 1 of 3 parts a full-board re-route was known to " ++
    "break; at 1.0 mm it flags all 3. Raise delta_mm when a probe comes back stable.";

const Outcome = struct {
    alloc: std.mem.Allocator,
    design: []const u8,
    layout: []const u8,
    delta: f64,
    rotations: bool,
    parts: []const PartReport,
    unknown: []const []const u8,
};

fn writeResult(out: *std.ArrayList(u8), o: Outcome) HandlerError!bool {
    var aw: std.Io.Writer.Allocating = .init(o.alloc);
    const w = &aw.writer;
    try w.print("{{\"ok\":true,\"design\":", .{});
    try pcb_layout_page.writeJsonStr(w, o.design);
    try w.writeAll(",\"layout\":");
    try pcb_layout_page.writeJsonStr(w, o.layout);
    try w.print(",\"delta_mm\":{d:.3},\"rotations\":{},\"parts\":[", .{ o.delta, o.rotations });
    for (o.parts, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try writePart(w, p);
    }
    try w.writeAll("],\"unknown_refs\":");
    try writeStrArray(w, o.unknown);
    try w.writeAll(",\"limits\":");
    try pcb_layout_page.writeJsonStr(w, limits_note);
    try w.writeAll("}");
    try out.appendSlice(o.alloc, aw.written());
    return true;
}

fn writePart(w: *std.Io.Writer, p: PartReport) std.Io.Writer.Error!void {
    try w.writeAll("{\"ref\":");
    try pcb_layout_page.writeJsonStr(w, p.ref);
    try w.writeAll(",\"origin\":");
    try pcb_layout_page.writeJsonStr(w, p.origin);
    try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"rot\":{d:.1}", .{ p.x, p.y, p.rot });
    try w.print(",\"load_bearing\":{},\"verdict\":", .{p.load_bearing});
    try pcb_layout_page.writeJsonStr(w, p.verdict);
    try w.print(",\"scope\":{{\"own\":{d},\"contenders\":{d},\"nets\":", .{ p.own, p.contenders });
    try writeStrArray(w, p.scope_nets);
    try w.print("}},\"baseline\":{{\"routed\":{d},\"total\":{d},\"drc_errors\":{d}}}", .{ p.base_routed, p.base_total, p.base_drc });
    try w.writeAll(",\"perturbations\":[");
    for (p.runs, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try writeRun(w, r);
    }
    try w.print("],\"ms\":{d}}}", .{p.ms});
}

fn writeRun(w: *std.Io.Writer, r: RunReport) std.Io.Writer.Error!void {
    try w.writeAll("{\"move\":");
    try pcb_layout_page.writeJsonStr(w, r.label);
    try w.print(",\"dx\":{d:.3},\"dy\":{d:.3},\"drot\":{d:.1}", .{ r.dx, r.dy, r.drot });
    try w.print(",\"routed\":{d},\"drc_errors\":{d},\"flips\":[", .{ r.routed, r.drc_errors });
    for (r.flips, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try pcb_layout_page.writeJsonStr(w, f.net);
        try w.print(",\"from\":\"{s}\",\"to\":\"{s}\"}}", .{ f.kind.fromStr(), f.kind.toStr() });
    }
    try w.print("],\"ms\":{d}}}", .{r.ms});
}

fn writeStrArray(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, s);
    }
    try w.writeAll("]");
}

// ── Argument helpers ────────────────────────────────────────────────────────

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

fn argFloat(args_val: ?std.json.Value, key: []const u8) ?f64 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    return switch (av.object.get(key) orelse return null) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

const argNames = mcp_arg_names.parse;

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

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A two-part fixture with one routable net between them, used for the scope
/// and part-resolution tests.
const probe_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn probeParts() [2]optimizer.Part {
    return .{
        .{ .ref_des = "lmx2595/R42", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &probe_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C91", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &probe_pad, .fallback = false, .x = 6, .y = 0 },
    };
}

fn probeFixture(parts: []optimizer.Part, nets: []const export_kicad.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 7,
        .maxy = 1,
        .generated = true,
    };
}

fn st(name: []const u8, routable: bool, connected: bool) fab_readiness.NetStatus {
    return .{ .name = name, .routable = routable, .connected = connected, .islands = if (connected) 1 else 2 };
}

// spec: Web Server - The placement_sensitivity probe set nudges a part both ways on each axis, and adds rotations only when asked
test "placement_sensitivity perturbation set covers both axes and opts into rotation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const flat = try perturbationSet(arena, 0.2, false);
    try testing.expectEqual(@as(usize, 4), flat.len);
    try testing.expectEqualStrings("+x", flat[0].label);
    try testing.expectEqual(@as(f64, 0.2), flat[0].dx);
    try testing.expectEqual(@as(f64, -0.2), flat[1].dx);
    try testing.expectEqual(@as(f64, 0.2), flat[2].dy);
    try testing.expectEqual(@as(f64, -0.2), flat[3].dy);
    for (flat) |p| try testing.expectEqual(@as(f64, 0), p.drot);

    const spun = try perturbationSet(arena, 0.2, true);
    try testing.expectEqual(@as(usize, 6), spun.len);
    try testing.expectEqual(@as(f64, 90), spun[4].drot);
    try testing.expectEqual(@as(f64, -90), spun[5].drot);
}

// spec: Web Server - The placement_sensitivity probe clamps its nudge to a window where a move is still a perturbation
test "placement_sensitivity clamps the requested delta" {
    try testing.expectEqual(default_delta_mm, clampDelta(0));
    try testing.expectEqual(default_delta_mm, clampDelta(-1));
    try testing.expectEqual(@as(f64, 0.05), clampDelta(0.05));
    try testing.expectEqual(max_delta_mm, clampDelta(50));
}

// spec: Web Server - The placement_sensitivity flip classifier reports a net that changed connectivity verdict and ignores nets needing no copper
test "placement_sensitivity flip classification names lost and gained nets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = [_]fab_readiness.NetStatus{
        st("SPI_SCK", true, true), // routed → open  (lost)
        st("V_3V3A", true, false), // open   → routed (gained)
        st("IF1_LPF", true, true), // unchanged
        st("GND", false, false), // plane-carried: never reported
    };
    const pert = [_]fab_readiness.NetStatus{
        st("SPI_SCK", true, false),
        st("V_3V3A", true, true),
        st("IF1_LPF", true, true),
        st("GND", false, true),
    };
    const flips = try classifyFlips(arena, &base, &pert);
    try testing.expectEqual(@as(usize, 2), flips.len);
    try testing.expectEqualStrings("SPI_SCK", flips[0].net);
    try testing.expectEqual(FlipKind.lost, flips[0].kind);
    try testing.expectEqualStrings("routed", flips[0].kind.fromStr());
    try testing.expectEqualStrings("open", flips[0].kind.toStr());
    try testing.expectEqualStrings("V_3V3A", flips[1].net);
    try testing.expectEqual(FlipKind.gained, flips[1].kind);
    try testing.expectEqual(@as(usize, 2), connectedCount(&pert));
    try testing.expectEqual(@as(usize, 3), routableCount(&pert));
}

// spec: Web Server - The placement_sensitivity flip classifier reports nothing when the two runs are not the same netlist
test "placement_sensitivity flip classification refuses a mismatched netlist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const base = [_]fab_readiness.NetStatus{ st("A", true, true), st("B", true, true) };
    const pert = [_]fab_readiness.NetStatus{st("A", true, false)};
    const flips = try classifyFlips(arena_state.allocator(), &base, &pert);
    try testing.expectEqual(@as(usize, 0), flips.len);
}

// spec: Web Server - A placement_sensitivity probe scopes a part to its own nets plus the foreign copper threading its neighbourhood
test "placement_sensitivity scope takes own nets and nearby foreign copper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = probeParts();
    const own_pins = [_]export_kicad.FlatPin{.{ .ref_des = "lmx2595/R42", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "IF1_LPF", .pins = &own_pins }, // lands on the probed part
        .{ .name = "SPI_SCK", .pins = &.{} }, // near copper ⇒ contender
        .{ .name = "V_12V", .pins = &.{} }, // far copper ⇒ untouched
    };
    const placement = probeFixture(&parts, &nets);
    const tracks = [_]router.Track{
        .{ .x1 = -1, .y1 = 2, .x2 = 1, .y2 = 2, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = -1, .y1 = 40, .x2 = 1, .y2 = 40, .layer = 0, .width = 0.2, .net = 2 },
    };
    const scope = try scopeFor(arena, placement, .{ .tracks = &tracks, .vias = &.{}, .routed = 0, .total = 0 }, 0, 0.2);
    try testing.expect(scope.mask[0] and scope.mask[1] and !scope.mask[2]);
    try testing.expectEqual(@as(usize, 1), scope.own);
    try testing.expectEqual(@as(usize, 1), scope.contenders);
    const names = try scopeNames(arena, placement, scope.mask);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("IF1_LPF", names[0]);
}

// spec: Web Server - A placement_sensitivity probe pins every net outside its scope to the copper the saved layout drew
test "placement_sensitivity retains out-of-scope copper as an obstacle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 1, .x2 = 1, .y2 = 1, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 0, .y1 = 2, .x2 = 1, .y2 = 2, .layer = 0, .width = 0.2, .net = -1 },
    };
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.6, .drill = 0.3, .net = 0 },
        .{ .x = 2, .y = 2, .dia = 0.6, .drill = 0.3, .net = 1 },
    };
    const selected = [_]bool{ true, false };
    const sr = try retainedCopper(arena, .{ .tracks = &tracks, .vias = &vias, .routed = 0, .total = 0 }, &selected);
    // Net 0 is in scope (redrawn); net 1 and the unnetted track are pinned.
    try testing.expectEqual(@as(usize, 2), sr.existing_tracks.len);
    try testing.expectEqual(@as(i32, 1), sr.existing_tracks[0].net);
    try testing.expectEqual(@as(i32, -1), sr.existing_tracks[1].net);
    try testing.expectEqual(@as(usize, 1), sr.existing_vias.len);
    try testing.expectEqual(@as(i32, 1), sr.existing_vias[0].net);
}

// spec: Web Server - A placement_sensitivity perturbation moves only the probed part and leaves every other pose alone
test "placement_sensitivity perturbation moves only the probed part" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parts = probeParts();
    const placement = probeFixture(&parts, &.{});
    const poses = try posesWith(arena_state.allocator(), placement, 0, .{ .label = "+x", .dx = 0.2, .drot = 90 });
    try testing.expectEqual(@as(usize, 2), poses.len);
    try testing.expectEqual(@as(f64, 0.2), poses[0].x);
    try testing.expectEqual(@as(f64, 90), poses[0].rot);
    try testing.expectEqual(@as(f64, 6), poses[1].x);
    try testing.expectEqual(@as(f64, 0), poses[1].rot);
}

// spec: Web Server - A placement_sensitivity part name resolves by full ref-des, sub-block leaf, or stable origin name
test "placement_sensitivity resolves a part by ref, leaf, or origin" {
    var parts = probeParts();
    const placement = probeFixture(&parts, &.{});
    try testing.expectEqual(@as(?usize, 0), findPart(placement, "lmx2595/R42"));
    try testing.expectEqual(@as(?usize, 0), findPart(placement, "r42"));
    try testing.expectEqual(@as(?usize, 1), findPart(placement, "C91"));
    try testing.expectEqual(@as(?usize, null), findPart(placement, "U99"));
}

// spec: Web Server - A placement_sensitivity verdict names the net and the move for a load-bearing part, and the window for a stable one
test "placement_sensitivity verdict names the flip that made a part load-bearing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "stable within ±0.20 mm",
        try verdictText(arena, 0.2, null),
    );
    try testing.expectEqualStrings(
        "load-bearing: SPI_SCK opens on +x",
        try verdictText(arena, 0.2, .{ .label = "+x", .net = "SPI_SCK", .kind = .lost }),
    );
    try testing.expectEqualStrings(
        "load-bearing: V_3V3A closes on -y",
        try verdictText(arena, 0.2, .{ .label = "-y", .net = "V_3V3A", .kind = .gained }),
    );
}

// spec: Web Server - The placement_sensitivity result states its scope limit and names a field the payload actually carries
test "placement_sensitivity result states its limit against a field it emits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flips = [_]Flip{.{ .net = "SPI_SCK", .kind = .lost }};
    const runs = [_]RunReport{.{
        .label = "+x",
        .dx = 0.2,
        .dy = 0,
        .drot = 0,
        .routed = 69,
        .drc_errors = 5,
        .flips = &flips,
        .ms = 1234,
    }};
    const nets = [_][]const u8{ "SPI_SCK", "V_3V3A" };
    const parts = [_]PartReport{.{
        .ref = "lmx2595/R42",
        .origin = "R_PU_CS",
        .x = 146.9,
        .y = 97.35,
        .rot = 0,
        .scope_nets = &nets,
        .own = 1,
        .contenders = 1,
        .base_routed = 70,
        .base_total = 90,
        .base_drc = 4,
        .runs = &runs,
        .verdict = "load-bearing: SPI_SCK opens on +x",
        .load_bearing = true,
        .ms = 5000,
    }};
    var out: std.ArrayList(u8) = .empty;
    try testing.expect(try writeResult(&out, .{
        .alloc = arena,
        .design = "barracuda",
        .layout = "layout",
        .delta = 0.2,
        .rotations = false,
        .parts = &parts,
        .unknown = &.{"NOSUCHPART"},
    }));
    defer out.deinit(arena);

    // Parses, and carries the caution the verdict has to be read against.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.items, .{});
    try testing.expect(root.object.get("ok").?.bool);
    const limits = root.object.get("limits").?.string;
    try testing.expect(std.mem.indexOf(u8, limits, scope_nets_path) != null);

    // …and the field it points at is really there, under exactly that path.
    const part = root.object.get("parts").?.array.items[0];
    const scope = part.object.get("scope").?;
    try testing.expectEqual(@as(usize, 2), scope.object.get("nets").?.array.items.len);
    try testing.expect(part.object.get("load_bearing").?.bool);
    const run = part.object.get("perturbations").?.array.items[0];
    try testing.expectEqualStrings("+x", run.object.get("move").?.string);
    const flip = run.object.get("flips").?.array.items[0];
    try testing.expectEqualStrings("SPI_SCK", flip.object.get("net").?.string);
    try testing.expectEqualStrings("routed", flip.object.get("from").?.string);
    try testing.expectEqualStrings("open", flip.object.get("to").?.string);
    try testing.expectEqualStrings("NOSUCHPART", root.object.get("unknown_refs").?.array.items[0].string);
}

// spec: Web Server - A placement_sensitivity headline prefers a net the move breaks over one it only fixes, and a fixed net still marks the part load-bearing
test "placement_sensitivity headline prefers a broken net over a fixed one" {
    const gained = [_]Flip{.{ .net = "V_3V3A", .kind = .gained }};
    const lost = [_]Flip{.{ .net = "SPI_SCK", .kind = .lost }};

    // No flips at all leaves the part with no headline (⇒ "stable").
    try testing.expect(pickHeadline(null, "+x", &.{}) == null);

    // A gained-only flip still counts: the net fails at the pose on the board.
    const first = pickHeadline(null, "+x", &gained).?;
    try testing.expectEqualStrings("V_3V3A", first.net);
    try testing.expectEqual(FlipKind.gained, first.kind);

    // A later BROKEN net displaces the held gain …
    const upgraded = pickHeadline(first, "-y", &lost).?;
    try testing.expectEqualStrings("SPI_SCK", upgraded.net);
    try testing.expectEqualStrings("-y", upgraded.label);
    try testing.expectEqual(FlipKind.lost, upgraded.kind);

    // … and nothing displaces a broken net once held.
    const held = pickHeadline(upgraded, "+y", &gained).?;
    try testing.expectEqualStrings("SPI_SCK", held.net);
    try testing.expectEqualStrings("-y", held.label);
}
