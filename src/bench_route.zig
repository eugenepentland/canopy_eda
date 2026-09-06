//! Whole-corpus routing benchmark — the harness that makes "the router got
//! better" a checkable claim.
//!
//! Every router change so far has been judged on one board, and at least two
//! changes that looked reasonable turned out to be net-negative *on the same
//! board they were designed against* (`docs/archive/autorouter-plan.md` §4). A
//! single-board measurement cannot detect that. This routes a whole corpus in
//! one command and prints a per-board table plus a geomean, so a change that
//! wins a net here and loses two there is visible immediately.
//!
//! Every number is the one a caller would actually see: the placement is the
//! design's starred layout (the blessed board), the route goes through
//! `route_plan` — the same seam and post-route oracle gate every surface
//! shares — and `routed`/`total` are therefore the connectivity oracle's
//! answer, never the router's own claim. DRC is the design's filtered rule set,
//! split by severity. `--json` additionally NAMES each board's still-open nets,
//! from that same oracle tally, so a two-net move is diffable net by net instead
//! of leaving a reader to guess which two it was.
//!
//! Read-only by default. `--save-candidate NAME` explicitly captures the
//! measured copper as a new, unstarred layout for inspection and finishing.
//! It refuses an existing name and never replaces the source layout.
//!
//! `--jsonl <path>` additionally appends each board's row the moment that board
//! finishes, so a corpus killed partway (exit 137 under memory pressure is the
//! recorded case) keeps every board it already measured — see
//! `bench_checkpoint.zig`. The aggregate `--json` document is unchanged.
//!
//! Usage:
//!   netlisp bench-route --project-dir <dir> [--route-space lattice|field]
//!       [--json] [--jsonl <path>] [<design> ...]
//!
//! With no design names it benchmarks every design in the project.

const std = @import("std");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const bench_args = @import("bench_args.zig");
const bench_checkpoint = @import("bench_checkpoint.zig");
const build_id = @import("build_id.zig");
const optimizer = @import("placement/optimizer.zig");
const drc = @import("placement/drc.zig");
const drc_rules = @import("serve/drc_rules.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const route_plan = @import("serve/route_plan.zig");
const route_copper_state = @import("route_copper_state.zig");
const saved_route_copper = @import("saved_route_copper.zig");
const sidecar_store = @import("layout_sidecar_store.zig");
const route_timing = @import("placement/route_timing.zig");
const route_policy = @import("placement/route_policy.zig");
const route_space_cache = @import("placement/route_space_cache.zig");
const json_writer = @import("json_writer.zig");
const route_score = @import("placement/route_score.zig");
const route_shape_score = @import("placement/route_shape_score.zig");
const router = @import("placement/router.zig");
const modules_mod = @import("serve/modules.zig");
const subcircuit_route = @import("serve/subcircuit_route.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Completion floor inside a geometric mean: a zero-completion board would
/// send a plain product to zero and `@log(0)` to -inf, so it is credited one
/// net's worth instead. Not a tolerance — a floor.
const min_scored_completion: f64 = 1e-6;

/// Largest design source this harness will read when scanning the corpus.
const max_design_bytes: usize = 4 * 1024 * 1024;
/// Marker that tells a design file apart from a library/module file.
const design_block_marker = "(design-block";
const ns_per_ms: f64 = 1_000_000.0;
const drc_kind_count = @typeInfo(drc.Kind).@"enum".field_names.len;

/// What this harness can fail with: allocation, stdout, and corpus directory
/// iteration. A design that fails to LOAD or ROUTE is not an error — it becomes
/// an `ok = false` row so one broken board cannot abort a corpus run.
pub const BenchError = std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    infra_fs.File.WriteError ||
    infra_fs.Iterator.Error ||
    bench_checkpoint.CheckpointError ||
    error{ BaselineRegression, CandidateSaveFailed, InvalidCandidateName, InvalidCheckpointPath }; // the --baseline gate failed

/// A board's connectivity, as the oracle counts it.
pub const Nets = struct {
    routed: usize = 0,
    total: usize = 0,
    /// The still-open nets by name, sorted. `routed`/`total` say a change moved
    /// the board by two nets; this says WHICH two, which is the difference
    /// between a comparable measurement and a number to squint at. Same source
    /// as the counts — `fab_readiness.routableTally` through the oracle gate —
    /// so a name here is exactly a net the counts did not credit.
    open: []const []const u8 = &.{},
};

/// A board's DRC findings — a change that buys a net by adding a fab-blocking
/// violation has not bought anything.
///
/// `total` is every finding the filtered check emitted, `net_open` included.
/// `errors` is `drc.errorCount`: error severity MINUS `net_open`, the same
/// fab-blocking-geometry count every other scoring surface reports, so this
/// column can be read beside `route_score`'s DRC term and against
/// `/api/pcb-describe`. Completion is already the `routed`/`total` columns
/// two over; counting an open net here as well charged it twice.
pub const Drc = struct {
    total: usize = 0,
    errors: usize = 0,
    wall_ns: u64 = 0,
    kinds: [drc_kind_count]usize = @splat(0),
    issues: [8]DrcIssue = @splat(.{}),
    issue_count: usize = 0,

    fn count(self: Drc, kind: drc.Kind) usize {
        return self.kinds[@backingInt(kind)];
    }
};

const DrcIssue = struct {
    kind: drc.Kind = .track_track,
    a: []const u8 = "?",
    b: []const u8 = "?",
    x: f64 = 0,
    y: f64 = 0,
    gap: f64 = 0,
    clearance: f64 = 0,
};

/// How much metal the route spent.
pub const Copper = struct {
    tracks: usize = 0,
    vias: usize = 0,
    mm: f64 = 0,
    connected_mm: f64 = 0,
    open_mm: f64 = 0,
    /// Per-net copper behind the aggregate totals. Keeping this in benchmark
    /// JSON makes unlike completion counts comparable on their common nets.
    per_net: []const router.NetRouted = &.{},
    seeds: pcb_layout_page.SubcircuitRouteSeedStats = .{},
};

/// Secondary route quality dimensions used by the path-director A/B.
const Quality = struct {
    candidate: struct { layout: ?[]const u8 = null, err: ?[]const u8 = null } = .{},
    shape: route_shape_score.Metrics = .{},
    score_v1: f64 = 0,
    copper_hash: u64 = 0,
    route_space: []const u8 = "lattice",
};

/// One board's measured routing outcome. Every field is a number a reviewer can
/// compare across commits; `ok = false` means the design failed to load or
/// route at all, which is itself a result worth printing rather than skipping.
pub const BoardResult = struct {
    name: []const u8,
    ok: bool = false,
    /// Did this board's placement come from a saved (blessed) layout? A design
    /// with no starred layout falls back to a fresh solve or a plain grid, whose
    /// parts commonly overlap — routing that is not a measurement of the router,
    /// and not comparable across commits either. Such a board is reported but
    /// kept OUT of the corpus score.
    placed: bool = false,
    nets: Nets = .{},
    drc: Drc = .{},
    copper: Copper = .{},
    quality: Quality = .{},
    wall_ms: f64 = 0,
    /// Per-phase wall-clock breakdown, populated only under `--breakdown`.
    breakdown: bool = false,
    timing: route_timing.PhaseTimer = .{},

    /// Does this row belong in the corpus score? Only a board that loaded AND
    /// routed at a blessed placement is comparable across commits.
    pub fn scorable(self: BoardResult) bool {
        return self.ok and self.placed;
    }

    /// Fraction of routable nets this board's copper actually connects. A board
    /// with nothing to route counts as complete (the `route_score` convention),
    /// so it neither flatters nor drags the corpus geomean.
    pub fn completion(self: BoardResult) f64 {
        if (self.nets.total == 0) return 1;
        return @as(f64, @floatFromInt(self.nets.routed)) / @as(f64, @floatFromInt(self.nets.total));
    }
};

/// Geometric mean of the corpus's completion fractions — the single number a
/// router change has to hold or improve. Geometric rather than arithmetic so
/// taking one board from 0.5 to 0.6 counts for more than taking another from
/// 0.98 to 0.99, and so a board driven to zero cannot be averaged away by
/// easy boards.
///
/// Only SCORABLE boards count: one that failed to load, and one with no saved
/// layout (whose fallback placement commonly overlaps parts and is not stable
/// across commits), are reported in the table but excluded here. Otherwise a
/// project holding a few un-placed designs pins the score near zero and hides
/// every real change. An empty corpus is 0.
pub fn geomeanCompletion(results: []const BoardResult) f64 {
    var sum: f64 = 0;
    var n: usize = 0;
    for (results) |r| {
        if (!r.scorable()) continue;
        // A zero-completion board would send a plain product to zero; the log
        // form needs the same guard, so floor it at one net's worth of credit.
        const c = @max(r.completion(), min_scored_completion);
        sum += @log(c);
        n += 1;
    }
    if (n == 0) return 0;
    return @exp(sum / @as(f64, @floatFromInt(n)));
}

/// Route one design at its blessed placement and measure the result.
pub fn benchOne(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) BoardResult {
    return benchOneBreakdown(alloc, project_dir, name, false);
}

/// `benchOne` with optional per-phase wall-time instrumentation. When
/// `breakdown` is true the result carries the phase timer and the DRC wall
/// time; the compact path (default) is byte-identical to `benchOne`.
pub fn benchOneBreakdown(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    breakdown: bool,
) BoardResult {
    return benchOneConfigured(alloc, project_dir, name, .{ .breakdown = breakdown });
}

const RunConfig = struct {
    breakdown: bool = false,
    route_space: route_policy.RouteSpace = .lattice,
    saved_module_routes: bool = true,
    save_candidate: ?[]const u8 = null,
};

fn benchOneConfigured(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    config: RunConfig,
) BoardResult {
    const breakdown = config.breakdown;
    const route_space = config.route_space;
    var out = BoardResult{ .name = name, .breakdown = breakdown, .quality = .{ .route_space = route_space.name() } };
    if (config.save_candidate) |target| {
        out.quality.candidate.layout = target;
        out.quality.candidate.err = "CandidateNotProduced";
        if (pcb_layout_page.mcpReadWorking(alloc, project_dir, name, target) != null) {
            out.quality.candidate.err = "CandidateNameExists";
            return out;
        }
    }
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const opts = pcb_layout_page.PngRequest{};
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res) catch return out;
    // `shownLayoutCopper` reports `from_saved` under exactly the condition
    // `solveForRequest` used to take a placement VERBATIM from a saved snapshot,
    // so it is the honest answer to "is this a blessed board".
    out.placed = pcb_layout_page.shownLayoutCopper(
        alloc,
        project_dir,
        name,
        opts,
        solved.placement,
    ).from_saved;
    const params = solved.placement.rules.design.routeParams();

    const t0 = clock.nanoTimestamp();
    var route_options = route_plan.lowerOrEmpty(alloc, solved.block, solved.placement);
    route_options.existing_zones = solved.shown_zones.sources;
    route_options.guides.saved_module_routes = config.saved_module_routes;
    // Always arm counters in the benchmark so route-space attempts are visible
    // in compact JSON too. Both A/B modes pay the same timing instrumentation.
    route_options.timing = &out.timing;
    var static_cache = route_space_cache.Cache.init(switch (route_space) {
        .lattice => alloc,
        .field => |field| field.scratch,
    });
    defer static_cache.deinit();
    route_options.guides.route_space = switch (route_space) {
        .lattice => .lattice,
        .field => |field| .{ .field = .{ .scratch = field.scratch, .cache = &static_cache } },
    };
    const seeded = pcb_layout_page.routeWithSubcircuitSeeds(
        alloc,
        project_dir,
        solved.block,
        solved.placement,
        params,
        route_options,
    ) catch return out;
    out.copper.seeds = seeded.seeds;
    // Match the copper that commit, experiment and inspection actually show.
    // The perimeter is generated output and belongs in the measured candidate.
    const routed = finishCandidate(alloc, solved.placement, seeded.result, solved.shown_zones.user) catch return out;
    out.wall_ms = @as(f64, @floatFromInt(clock.nanoTimestamp() - t0)) / ns_per_ms;
    if (out.breakdown) {
        // Resolve slow-net indexes to names while the placement is alive; the
        // name slices are duped into the outer arena in `benchAll`.
        for (&out.timing.slow_nets) |*s| {
            if (s.ns == 0) continue;
            if (s.net_i < solved.placement.nets.len) s.name = solved.placement.nets[s.net_i].name;
        }
    }

    const d0 = clock.nanoTimestamp();
    const v = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
        .placement = solved.placement,
        .routed = routed,
        .clearance = params.clearance,
        .zones = solved.shown_zones.user,
    });
    if (out.breakdown) out.drc.wall_ns = @intCast(clock.nanoTimestamp() - d0);
    for (routed.tracks) |t| out.copper.mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    out.drc.errors = drc.errorCount(v);
    for (v) |violation| {
        if (violation.severity != .err or violation.kind == .net_open) continue;
        out.drc.kinds[@backingInt(violation.kind)] += 1;
        if (out.drc.issue_count >= out.drc.issues.len) continue;
        const slot = &out.drc.issues[out.drc.issue_count];
        slot.* = .{
            .kind = violation.kind,
            .a = violationNetName(solved.placement, violation.who.net_a),
            .b = violationNetName(solved.placement, violation.who.net_b),
            .x = violation.x,
            .y = violation.y,
            .gap = violation.gap,
            .clearance = violation.clearance,
        };
        out.drc.issue_count += 1;
    }
    out.ok = true;
    out.nets = .{ .routed = routed.routed, .total = routed.total, .open = sortedOpen(alloc, routed.failed) };
    out.drc.total = v.len;
    out.copper.tracks = routed.tracks.len;
    out.copper.vias = routed.vias.len;
    const by_net = router.perNetRouted(alloc, solved.placement, routed) catch &.{};
    out.copper.per_net = by_net;
    out.copper.open_mm = openTraceMm(by_net, routed.failed);
    out.copper.connected_mm = @max(out.copper.mm - out.copper.open_mm, 0);
    out.quality.shape = route_shape_score.measure(alloc, solved.placement, routed, params.clearance) catch .{};
    out.quality.score_v1 = route_score.score(.{
        .routed = out.nets.routed,
        .total = out.nets.total,
        .vias = out.copper.vias,
        .trace_mm = out.copper.mm,
        .drc_errors = out.drc.errors,
        .bends = route_score.bendCount(alloc, routed.tracks) catch 0,
        .quality_warns = route_score.qualityWarnCount(v),
    });
    out.quality.copper_hash = copperHash(routed.tracks, routed.vias);
    if (config.save_candidate) |target| {
        out.quality.candidate.err = null;
        captureCandidate(alloc, project_dir, name, solved.placement, routed, target) catch |err| {
            out.quality.candidate.err = @errorName(err);
        };
    }
    return out;
}

fn finishCandidate(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const @import("placement/pour.zig").UserZone,
) std.mem.Allocator.Error!router.RouteResult {
    const fenced = (try route_copper_state.appendPerimeter(alloc, placement, routed)).?;
    return route_copper_state.reconcile(alloc, placement, fenced, zones);
}

const CaptureError = sidecar_store.StoreError || error{ CandidateNameExists, NoSavedPlacement };

fn captureCandidate(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    target: []const u8,
) CaptureError!void {
    if (pcb_layout_page.mcpReadWorking(alloc, project_dir, name, target) != null) return error.CandidateNameExists;
    var entry = pcb_layout_page.mcpReadWorking(alloc, project_dir, name, null) orelse return error.NoSavedPlacement;
    entry.name = target;
    entry.default = false;
    entry.parts = pcb_layout_page.posesFromPlacement(alloc, placement) orelse return error.OutOfMemory;
    var routes = try saved_route_copper.fromResult(alloc, routed, placement.nets, null);
    routes.zones = if (entry.routes) |prior| prior.zones else &.{};
    entry.routes = routes;
    try pcb_layout_page.mcpCreateWorking(alloc, project_dir, name, entry);
}

fn hashScalar(hash: *u64, value: anytype) void {
    const bytes = std.mem.asBytes(&value);
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= 1099511628211;
    }
}

/// Stable ordered-copper fingerprint used by the three-run determinism check.
fn copperHash(tracks: []const router.Track, vias: []const router.Via) u64 {
    var hash: u64 = 14695981039346656037;
    for (tracks) |track| {
        hashScalar(&hash, @as(u8, 0));
        hashScalar(&hash, track.x1);
        hashScalar(&hash, track.y1);
        hashScalar(&hash, track.x2);
        hashScalar(&hash, track.y2);
        hashScalar(&hash, track.layer);
        hashScalar(&hash, track.width);
        hashScalar(&hash, track.net);
    }
    for (vias) |via| {
        hashScalar(&hash, @as(u8, 1));
        hashScalar(&hash, via.x);
        hashScalar(&hash, via.y);
        hashScalar(&hash, via.dia);
        hashScalar(&hash, via.drill);
        hashScalar(&hash, via.net);
    }
    return hash;
}

/// The oracle's open-net names in name order. The oracle emits them in net-index
/// order, which is stable for one board but says nothing to a reader diffing two
/// runs; sorting makes the list comparable by eye. An allocation failure falls
/// back to the oracle's own order rather than costing the whole measurement.
fn sortedOpen(alloc: std.mem.Allocator, open: []const []const u8) []const []const u8 {
    const out = alloc.dupe([]const u8, open) catch return open;
    std.mem.sort([]const u8, out, {}, lessThanName);
    return out;
}

fn openTraceMm(per_net: []const router.NetRouted, open: []const []const u8) f64 {
    var mm: f64 = 0;
    for (per_net) |net| {
        for (open) |name| {
            if (!std.mem.eql(u8, net.name, name)) continue;
            mm += net.mm;
            break;
        }
    }
    return mm;
}

fn violationNetName(placement: optimizer.Placement, net: i32) []const u8 {
    if (net < 0) return "?";
    const ni: usize = @intCast(net);
    return if (ni < placement.nets.len) placement.nets[ni].name else "?";
}

/// Every design name in `project_dir`, sorted, as the default corpus.
pub fn corpus(arena: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const src_path = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch
        return names.toOwnedSlice(arena);
    defer dir.close();
    var walker = dir.walk(arena) catch return names.toOwnedSlice(arena);
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".sexp")) continue;
        const stem = entry.basename[0 .. entry.basename.len - ".sexp".len];
        // Not a net name: a FILE-name stem, dropping `foo.checks.sexp` sidecars.
        if (std.mem.indexOfScalar(u8, stem, '.') != null) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_path, entry.path });
        const src = infra_fs.cwd().readFileAlloc(arena, full, max_design_bytes) catch continue;
        if (std.mem.indexOf(u8, src, design_block_marker) == null) continue;
        try names.append(arena, try arena.dupe(u8, stem));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanName);
    return names.toOwnedSlice(arena);
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Render the corpus table a reviewer reads.
pub fn writeTable(w: *std.Io.Writer, results: []const BoardResult) std.Io.Writer.Error!void {
    try w.print("{s:<24} {s:>9} {s:>7} {s:>8} {s:>7} {s:>9} {s:>7} {s:>7} {s:>7} {s:>10}\n", .{
        "board", "routed", "err", "score", "vias", "mm", "bends", "rem", "micro", "wall_s",
    });
    for (results) |r| {
        if (!r.ok) {
            try w.print("{s:<24} {s:>9}\n", .{ r.name, "FAILED" });
            continue;
        }
        var buf: [32]u8 = undefined;
        const frac = std.fmt.bufPrint(&buf, "{d}/{d}", .{ r.nets.routed, r.nets.total }) catch "?";
        try w.print("{s:<24} {s:>9} {d:>7} {d:>8.1} {d:>7} {d:>9.1} {d:>7} {d:>7} {d:>7} {d:>10.2}{s}\n", .{
            r.name,                     frac,               r.drc.errors,                                              r.quality.score_v1,
            r.copper.vias,              r.copper.mm,        r.quality.shape.bends,                                     r.quality.shape.removable_bends,
            r.quality.shape.micro_jogs, r.wall_ms / 1000.0, if (r.placed) "" else "   (no saved layout - not scored)",
        });
        try w.print(
            "{s:<24} mode={s} tracks={d} drc={d} connected={d:.1}mm open={d:.1}mm removable_detour={d:.3}mm non_oct={d} shortest={d:.4}mm hash={d}\n",
            .{
                "",                                  r.quality.route_space, r.copper.tracks,                     r.drc.total,
                r.copper.connected_mm,               r.copper.open_mm,      r.quality.shape.removable_detour_mm, r.quality.shape.non_octilinear_segments,
                r.quality.shape.shortest_segment_mm, r.quality.copper_hash,
            },
        );
        const seeds = r.copper.seeds;
        if (seeds.copper.candidate_tracks > 0 or seeds.copper.candidate_vias > 0) try w.print(
            "{s:<24} {s}: {d} net(s), {d}/{d} tracks, {d}/{d} vias; {d} rejected net(s){s}\n",
            .{
                "",                         "subcircuit seeds",          seeds.copper.accepted_nets, seeds.copper.accepted_tracks,                                                                                                             seeds.copper.candidate_tracks,
                seeds.copper.accepted_vias, seeds.copper.candidate_vias, seeds.copper.rejected_nets, if (seeds.fallback) " (quality fallback)" else if (seeds.copper.accepted_tracks > 0 or seeds.copper.accepted_vias > 0) " (used)" else "",
            },
        );
        if (seeds.phase.attempted_subcircuits > 0) try w.print(
            "{s:<24} local phase: {d}/{d} completed, {d} timed out, {d} supply net(s) deferred, {d} carrier drop(s) accepted\n",
            .{
                "",
                seeds.phase.completed_subcircuits,
                seeds.phase.attempted_subcircuits,
                seeds.phase.timed_out_subcircuits,
                seeds.phase.deferred_supply_nets,
                seeds.phase.accepted_carrier_drops,
            },
        );
        if (r.drc.errors > 0) {
            try w.print("{s:<24} {s}:", .{ "", "DRC errors" });
            for (r.drc.kinds, 0..) |count, ki| {
                if (count > 0) try w.print(" {s}={d}", .{ @tagName(@as(drc.Kind, @fromBackingInt(@intCast(ki)))), count });
            }
            try w.writeByte('\n');
            for (r.drc.issues[0..r.drc.issue_count]) |issue| {
                try w.print("{s:<24}   {s}: {s} / {s} at ({d:.3}, {d:.3}), gap {d:.4}/{d:.4} mm\n", .{
                    "",      @tagName(issue.kind), issue.a,   issue.b,
                    issue.x, issue.y,              issue.gap, issue.clearance,
                });
            }
        }
    }
    var scorable: usize = 0;
    for (results) |r| {
        if (r.scorable()) scorable += 1;
    }
    try w.print("\ngeomean completion {d:.4} over {d} scored of {d} board(s)\n", .{
        geomeanCompletion(results),
        scorable,
        results.len,
    });
}

/// Render the same results as JSON, for a driver that records them in the
/// `[benchmark]` ledger rather than reading them.
///
// not the json-escaper-def idiom: this is the report emitter, not a string
/// escaper — every free string in it goes through `json_writer.writeString`.
pub fn writeJson(w: *std.Io.Writer, results: []const BoardResult) json_writer.WriteError!void {
    try w.print("{{\"geomean_completion\":{d:.6},\"boards\":[", .{geomeanCompletion(results)});
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try writeBoardJson(w, r);
    }
    try w.writeAll("]}\n");
}

/// One board's row, the ONE renderer both the aggregate `--json` document and
/// the `--jsonl` checkpoint stream use. A checkpoint row that drifted from the
/// aggregate row would make the two records incomparable, which is the whole
/// point of keeping a checkpoint.
pub fn writeBoardJson(w: *std.Io.Writer, r: BoardResult) json_writer.WriteError!void {
    {
        // The board name is a design filename, so it is escaped rather than
        // interpolated: a quote or backslash in one used to tear the record.
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, r.name);
        try w.print(
            ",\"ok\":{s},\"placed\":{s},\"routed\":{d},\"total\":{d},\"drc\":{d},\"drc_errors\":{d},",
            .{ if (r.ok) "true" else "false", if (r.placed) "true" else "false", r.nets.routed, r.nets.total, r.drc.total, r.drc.errors },
        );
        try w.print("\"{s}\":{d},\"{s}\":{d},\"{s}\":{d},", .{
            @tagName(drc.Kind.dangling_copper),   r.drc.count(.dangling_copper),
            @tagName(drc.Kind.implicit_junction), r.drc.count(.implicit_junction),
            @tagName(drc.Kind.hairline_gap),      r.drc.count(.hairline_gap),
        });
        try w.print(
            "\"route_space\":\"{s}\",\"score_v1\":{d:.3},\"tracks\":{d},\"vias\":{d},\"trace_mm\":{d:.2},\"wall_ms\":{d:.1}," ++
                "\"copper_hash\":{d},\"bends\":{d},\"removable_bends\":{d},\"removable_detour_mm\":{d:.4}," ++
                "\"micro_jogs\":{d},\"non_octilinear_segments\":{d},\"shortest_segment_mm\":{d:.4}," ++
                "\"seed_tracks\":{d},\"seed_vias\":{d},\"seed_nets\":{d},\"seed_rejected_nets\":{d}," ++
                "\"seed_used\":{s},\"seed_fallback\":{s},\"local_attempted\":{d},\"local_completed\":{d},\"local_timed_out\":{d}," ++
                "\"deferred_supply_nets\":{d},\"accepted_carrier_drops\":{d},\"field_attempts\":{d},\"field_terminal_pairs\":{d}," ++
                "\"field_successes\":{d},\"field_coarsened\":{d},\"field_expansions\":{d},\"field_static_cache_hits\":{d}",
            .{
                r.quality.route_space,
                r.quality.score_v1,
                r.copper.tracks,
                r.copper.vias,
                r.copper.mm,
                r.wall_ms,
                r.quality.copper_hash,
                r.quality.shape.bends,
                r.quality.shape.removable_bends,
                r.quality.shape.removable_detour_mm,
                r.quality.shape.micro_jogs,
                r.quality.shape.non_octilinear_segments,
                r.quality.shape.shortest_segment_mm,
                r.copper.seeds.copper.accepted_tracks,
                r.copper.seeds.copper.accepted_vias,
                r.copper.seeds.copper.accepted_nets,
                r.copper.seeds.copper.rejected_nets,
                if (!r.copper.seeds.fallback and (r.copper.seeds.copper.accepted_tracks > 0 or r.copper.seeds.copper.accepted_vias > 0)) "true" else "false",
                if (r.copper.seeds.fallback) "true" else "false",
                r.copper.seeds.phase.attempted_subcircuits,
                r.copper.seeds.phase.completed_subcircuits,
                r.copper.seeds.phase.timed_out_subcircuits,
                r.copper.seeds.phase.deferred_supply_nets,
                r.copper.seeds.phase.accepted_carrier_drops,
                r.timing.counters.field_attempts,
                r.timing.counters.field_terminal_pairs,
                r.timing.counters.field_successes,
                r.timing.counters.field_coarsened,
                r.timing.counters.field_expansions,
                r.timing.counters.field_static_cache_hits,
            },
        );
        if (r.quality.candidate.layout) |target| {
            try w.writeAll(",\"candidate_layout\":");
            try json_writer.writeString(w, target);
            if (r.quality.candidate.err) |err| {
                try w.writeAll(",\"candidate_error\":");
                try json_writer.writeString(w, err);
            }
        }
        try w.writeAll(",\"perimeter_included\":true");
        try pcb_layout_page.writeRouteSeedStats(w, r.copper.seeds);
        try w.print(",\"connected_trace_mm\":{d:.2},\"open_trace_mm\":{d:.2},\"field_query_cache_hits\":{d},\"field_live_cache_hits\":{d},\"open\":", .{
            r.copper.connected_mm,
            r.copper.open_mm,
            r.timing.counters.field_query_cache_hits,
            r.timing.counters.field_live_cache_hits,
        });
        try writeOpen(w, r.nets.open);
        try w.writeAll(",\"per_net\":");
        try writePerNet(w, r.copper.per_net, r.nets.open);
        try w.writeAll("}");
    }
}

fn writeOpen(w: *std.Io.Writer, open: []const []const u8) json_writer.WriteError!void {
    try w.writeAll("[");
    for (open, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        // A net name comes from design source, so it is escaped rather than
        // interpolated: a quote or control byte in one must not tear the row.
        try json_writer.writeString(w, name);
    }
    try w.writeAll("]");
}

fn writePerNet(
    w: *std.Io.Writer,
    per_net: []const router.NetRouted,
    open: []const []const u8,
) json_writer.WriteError!void {
    try w.writeAll("[");
    for (per_net, 0..) |net, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, net.name);
        try w.print(",\"trace_mm\":{d:.4},\"vias\":{d},\"open\":{s}}}", .{
            net.mm,
            net.vias,
            if (namedOpen(net.name, open)) "true" else "false",
        });
    }
    try w.writeAll("]");
}

fn namedOpen(name: []const u8, open: []const []const u8) bool {
    for (open) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// Per-phase wall-time breakdown for `--breakdown` runs: one row per board,
/// one column per pipeline phase (ms), plus the whole-route wall time, the
/// number of pipeline attempts (a fine-grid retry is a second attempt), and
/// the post-route DRC wall time. Phases nest (`finish_total` brackets every
/// finish phase), so the row sum can exceed the wall time.
pub fn writeBreakdown(w: *std.Io.Writer, results: []const BoardResult) std.Io.Writer.Error!void {
    try w.writeAll("\nper-phase wall time (ms)\n");
    try w.print("{s:<26}", .{"board"});
    for (std.enums.values(route_timing.Phase)) |p| try w.print(" {s:>9}", .{route_timing.PhaseTimer.label(p)});
    try w.print(
        " {s:>9} {s:>7} {s:>8} {s:>12} {s:>8} {s:>12} {s:>10} {s:>10} {s:>14} {s:>14}\n",
        .{ "wall_ms", "attempts", "drc_ms", "maze_expans", "maze_legs", "field_pairs", "field_ok", "field_exp", "via_checks", "dogleg_probes" },
    );
    for (results) |r| {
        if (!r.ok or !r.breakdown) continue;
        try w.print("{s:<26}", .{r.name});
        for (std.enums.values(route_timing.Phase)) |p| {
            try w.print(" {d:>9.1}", .{@as(f64, @floatFromInt(r.timing.elapsed(p))) / ns_per_ms});
        }
        try w.print(" {d:>9.1} {d:>7} {d:>8.1} {d:>12} {d:>8} {d:>12} {d:>10} {d:>10} {d:>14} {d:>14}\n", .{
            r.wall_ms,
            r.timing.counters.attempts,
            @as(f64, @floatFromInt(r.drc.wall_ns)) / ns_per_ms,
            r.timing.maze_expansions,
            r.timing.maze_legs,
            r.timing.counters.field_terminal_pairs,
            r.timing.counters.field_successes,
            r.timing.counters.field_expansions,
            r.timing.direct_via_checks,
            r.timing.dogleg_probes,
        });
        try w.print("{s:<26} {s:>9} {s:>9}\n", .{ "slowest nets", "net_i", "ms" });
        var printed: usize = 0;
        for (r.timing.slow_nets) |s| {
            if (s.ns == 0) continue;
            try w.print("{s:<26} {d:>9} {d:>9.1}  {s}\n", .{
                "", s.net_i, @as(f64, @floatFromInt(s.ns)) / ns_per_ms, s.name,
            });
            printed += 1;
            if (printed >= 5) break;
        }
    }
}

/// The harness's parsed command line: the flags every bench harness shares
/// (`--project-dir`, `--json`, `--baseline`, positional design names — see
/// `bench_args`), plus this one's own.
const Args = struct {
    cli: bench_args.Common = .{},
    route_space: []const u8 = "lattice",
    breakdown: bool = false,
    saved_module_routes: bool = true,
    save_candidate: ?[]const u8 = null,
    /// `--jsonl <path>`: append each board's row as it finishes, so an
    /// interrupted corpus keeps the boards it already measured.
    jsonl: ?[]const u8 = null,
};

/// Parse the shared bench flags plus the path-director A/B selector and the
/// per-phase breakdown switch.
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Args {
    var out = Args{};
    try out.cli.parse(arena, args, &out, takeExtra);
    return out;
}

/// bench-route's own flags. `--route-space` names the path director; only the
/// field space has to be selected, since lattice is the default.
fn takeExtra(out: *Args, args: []const []const u8, i: *usize) bool {
    if (std.mem.eql(u8, args[i.*], "--route-space")) {
        i.* += 1;
        if (i.* < args.len and (std.mem.eql(u8, args[i.*], "field") or std.mem.eql(u8, args[i.*], "margin"))) out.route_space = "field";
        return true;
    }
    if (std.mem.eql(u8, args[i.*], "--save-candidate")) {
        i.* += 1;
        out.save_candidate = if (i.* < args.len) args[i.*] else "";
        return true;
    }
    if (std.mem.eql(u8, args[i.*], "--no-saved-module-routes")) {
        out.saved_module_routes = false;
        return true;
    }
    if (std.mem.eql(u8, args[i.*], "--jsonl")) {
        i.* += 1;
        out.jsonl = if (i.* < args.len) args[i.*] else "";
        return true;
    }
    if (std.mem.eql(u8, args[i.*], "--breakdown")) {
        out.breakdown = true;
        return true;
    }
    return false;
}

/// Route every named board, each in its own arena so a corpus run holds one
/// board's routing state at a time instead of every board's at once.
fn benchAll(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    names: []const []const u8,
    config: Args,
    checkpoint: ?*bench_checkpoint.Checkpoint,
) BenchError![]const BoardResult {
    const project_dir = config.cli.project_dir;
    const breakdown = config.breakdown;
    const route_space = config.route_space;
    var results: std.ArrayList(BoardResult) = .empty;
    for (names) |n| {
        var board_arena = std.heap.ArenaAllocator.init(allocator);
        defer board_arena.deinit();
        const provider: route_policy.RouteSpace = if (std.mem.eql(u8, route_space, "field")) .{ .field = .{ .scratch = allocator } } else .lattice;
        var r = benchOneConfigured(board_arena.allocator(), project_dir, n, .{
            .breakdown = breakdown,
            .route_space = provider,
            .saved_module_routes = config.saved_module_routes,
            .save_candidate = config.save_candidate,
        });
        r.name = try arena.dupe(u8, n);
        // The open names point into the board arena this loop is about to free.
        const open = try arena.alloc([]const u8, r.nets.open.len);
        for (r.nets.open, open) |src, *dst| dst.* = try arena.dupe(u8, src);
        r.nets.open = open;
        const per_net = try arena.alloc(router.NetRouted, r.copper.per_net.len);
        for (r.copper.per_net, per_net) |src, *dst| {
            dst.* = src;
            dst.name = try arena.dupe(u8, src.name);
        }
        r.copper.per_net = per_net;
        const attempts = try arena.dupe(subcircuit_route.Attempt, r.copper.seeds.attempts);
        for (attempts) |*attempt| attempt.path = try arena.dupe(u8, attempt.path);
        r.copper.seeds.attempts = attempts;
        if (breakdown) {
            for (&r.timing.slow_nets) |*s| {
                if (s.ns > 0) s.name = try arena.dupe(u8, s.name);
            }
        }
        for (&r.drc.issues) |*issue| {
            issue.a = try arena.dupe(u8, issue.a);
            issue.b = try arena.dupe(u8, issue.b);
        }
        try results.append(arena, r);
        // On disk before the NEXT board starts: that is the whole point.
        if (checkpoint) |cp| try cp.writeBoard(r, writeBoardJson);
    }
    return results.toOwnedSlice(arena);
}

/// One board's expect row inside a committed baseline file. Only `ok`/`placed`/
/// `routed`/`total` drive the gate; the rest are recorded so a reviewer diffing
/// two baselines sees the same columns a run prints.
const BaselineBoard = struct {
    name: []const u8,
    ok: bool = false,
    placed: bool = false,
    routed: usize = 0,
    total: usize = 0,
    drc_errors: usize = 0,
    dangling_copper: usize = 0,
    implicit_junctions: usize = 0,
    hairline_gaps: usize = 0,
    tracks: usize = 0,
    vias: usize = 0,
    trace_mm: f64 = 0,
};

/// A committed `--json` output re-read. `boards` is the authoritative record;
/// the gate recomputes both sides from the board rows so a drifted board set
/// cannot smuggle a change in.
const Baseline = struct {
    boards: []const BaselineBoard = &.{},

    /// The routed count a scorable board of this name recorded in the baseline,
    /// or null if the name was not scorable there.
    fn scoredNetRouted(self: Baseline, name: []const u8) ?usize {
        for (self.boards) |b| {
            if (!b.ok or !b.placed) continue;
            if (std.mem.eql(u8, b.name, name)) return b.routed;
        }
        return null;
    }

    fn scoredBoard(self: Baseline, name: []const u8) ?BaselineBoard {
        for (self.boards) |board| {
            if (board.ok and board.placed and std.mem.eql(u8, board.name, name)) return board;
        }
        return null;
    }
};

fn jsonBool(v: std.json.Value) bool {
    return v == .bool and v.bool;
}

fn jsonUscalar(v: std.json.Value) usize {
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
}

fn jsonF64(v: std.json.Value) f64 {
    return if (v == .float) v.float else 0;
}

/// Parse a committed `--json` baseline back into rows. Unknown/malformed fields
/// degrade to defaults — a baseline that is not JSON just produces an empty
/// row set, which the gate treats as "nothing to compare" (fail-visible, since
/// a missing baseline is never a pass). Any read/parse failure surfaces as a
/// gate failure, not a silent pass.
fn loadBaseline(arena: std.mem.Allocator, path: []const u8) !Baseline {
    const data = infra_fs.cwd().readFileAlloc(arena, path, max_design_bytes) catch return error.BaselineUnreadable;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return error.BaselineInvalid;
    var out = Baseline{};
    if (root != .object) return out;
    const arr = root.object.get("boards") orelse return out;
    if (arr != .array) return out;
    var boards: std.ArrayList(BaselineBoard) = .empty;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const nm = (it.object.get("name") orelse continue);
        if (nm != .string) continue;
        try boards.append(arena, .{
            .name = nm.string,
            .ok = jsonBool(it.object.get("ok") orelse .{ .bool = false }),
            .placed = jsonBool(it.object.get("placed") orelse .{ .bool = false }),
            .routed = jsonUscalar(it.object.get("routed") orelse .{ .integer = 0 }),
            .total = jsonUscalar(it.object.get("total") orelse .{ .integer = 0 }),
            .drc_errors = jsonUscalar(it.object.get("drc_errors") orelse .{ .integer = 0 }),
            .dangling_copper = jsonUscalar(it.object.get(@tagName(drc.Kind.dangling_copper)) orelse .{ .integer = 0 }),
            .implicit_junctions = jsonUscalar(it.object.get(@tagName(drc.Kind.implicit_junction)) orelse .{ .integer = 0 }),
            .hairline_gaps = jsonUscalar(it.object.get(@tagName(drc.Kind.hairline_gap)) orelse .{ .integer = 0 }),
            .tracks = jsonUscalar(it.object.get("tracks") orelse .{ .integer = 0 }),
            .vias = jsonUscalar(it.object.get("vias") orelse .{ .integer = 0 }),
            .trace_mm = jsonF64(it.object.get("trace_mm") orelse .{ .float = 0 }),
        });
    }
    out.boards = try boards.toOwnedSlice(arena);
    return out;
}

/// The verdict of one baseline comparison.
const BaselineReport = struct {
    pass: bool,
    geomean_now: f64 = 0,
    geomean_ref: f64 = 0,
    /// Scored boards that lost more than one net vs. the baseline (the hard
    /// rule — the plan's "no board regresses by more than one net").
    regressed: []const []const u8 = &.{},
    /// Boards whose router-created connectivity-defect count rose. Unlike the
    /// completion allowance, this is a strict ratchet: no new dangles,
    /// implicit joins, or hairline gaps are accepted.
    defect_regressed: []const []const u8 = &.{},
    /// Scored now but absent from (or not scored in) the baseline — emitted as
    /// a note so a new board cannot silently enter the score.
    unlined: []const []const u8 = &.{},
};

/// Compare the run against a committed baseline.
///
/// The gate is the plan's two-sided rule: (1) hard — no scorable board falls
/// below `baseline_routed - 1` net; (2) soft — the geomean computed over the
/// board set BOTH runs scored does not drop. Geomean is recomputed from the
/// baseline's own board rows (using the current `total` as the denominator for
/// both, so a netlist edit can't paper over a routed drop) rather than trusting
/// the baseline's headline, so a drifted board set cannot smuggle a change in.
fn checkBaseline(
    arena: std.mem.Allocator,
    results: []const BoardResult,
    baseline: *const Baseline,
) std.mem.Allocator.Error!BaselineReport {
    var regressed: std.ArrayList([]const u8) = .empty;
    var defect_regressed: std.ArrayList([]const u8) = .empty;
    var unlined: std.ArrayList([]const u8) = .empty;
    var sum_now: f64 = 0;
    var n_now: usize = 0;
    var sum_ref: f64 = 0;
    var n_ref: usize = 0;
    for (results) |r| {
        if (!r.scorable()) continue;
        const base = baseline.scoredNetRouted(r.name);
        if (base == null) {
            try unlined.append(arena, r.name);
            continue;
        }
        const b = base.?;
        // Hard rule: a scorable board may lose at most one net.
        if (r.nets.routed + 1 < b) try regressed.append(arena, r.name);
        const base_board = baseline.scoredBoard(r.name).?;
        if (r.drc.count(.dangling_copper) > base_board.dangling_copper or
            r.drc.count(.implicit_junction) > base_board.implicit_junctions or
            r.drc.count(.hairline_gap) > base_board.hairline_gaps)
            try defect_regressed.append(arena, r.name);
        // Geomean over the boards both runs scored. Use the CURRENT total as the
        // shared denominator so a routed drop (or gain) is what moves the score.
        const comp_now = if (r.nets.total == 0) 1 else @as(f64, @floatFromInt(r.nets.routed)) / @as(f64, @floatFromInt(r.nets.total));
        const comp_ref = if (r.nets.total == 0) 1 else @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(r.nets.total));
        sum_now += @log(@max(comp_now, min_scored_completion));
        n_now += 1;
        sum_ref += @log(@max(comp_ref, min_scored_completion));
        n_ref += 1;
    }
    const geomean_now = if (n_now == 0) 0 else @exp(sum_now / @as(f64, @floatFromInt(n_now)));
    const geomean_ref = if (n_ref == 0) 0 else @exp(sum_ref / @as(f64, @floatFromInt(n_ref)));
    const pass = regressed.items.len == 0 and defect_regressed.items.len == 0 and
        (n_now == 0 or geomean_now >= geomean_ref - 1e-9);
    return .{
        .pass = pass,
        .geomean_now = geomean_now,
        .geomean_ref = geomean_ref,
        .regressed = try regressed.toOwnedSlice(arena),
        .defect_regressed = try defect_regressed.toOwnedSlice(arena),
        .unlined = try unlined.toOwnedSlice(arena),
    };
}

/// Write the human-readable baseline verdict.
fn writeBaselineReport(w: *std.Io.Writer, report: BaselineReport, baseline_path: []const u8) std.Io.Writer.Error!void {
    try w.print("\n— baseline gate vs {s} —\n", .{baseline_path});
    try w.print("  geomean completion: now {d:.4} vs baseline {d:.4} ({s})\n", .{
        report.geomean_now,
        report.geomean_ref,
        if (report.geomean_now >= report.geomean_ref - 1e-9) "OK" else "DROP",
    });
    if (report.regressed.len == 0) {
        try w.print("  scored-board routed: no board lost more than one net (OK)\n", .{});
    } else {
        try w.print("  REGRESSED (>1 net lost):", .{});
        for (report.regressed) |n| try w.print(" {s}", .{n});
        try w.print("\n", .{});
    }
    if (report.defect_regressed.len == 0) {
        try w.print("  connectivity defects: dangling/implicit/hairline counts did not rise (OK)\n", .{});
    } else {
        try w.print("  REGRESSED connectivity defects:", .{});
        for (report.defect_regressed) |n| try w.print(" {s}", .{n});
        try w.print("\n", .{});
    }
    if (report.unlined.len > 0) {
        try w.print("  note: scored now but not in baseline:", .{});
        for (report.unlined) |n| try w.print(" {s}", .{n});
        try w.print("\n", .{});
    }
    try w.print("  result: {s}\n", .{if (report.pass) "PASS" else "FAIL — baseline regression"});
}

/// CLI entry: `netlisp bench-route --project-dir <dir> [--route-space lattice|field] [--json] [--baseline <file>] [--breakdown] [<design> ...]`.
pub fn cmdBenchRoute(allocator: std.mem.Allocator, args: []const []const u8) BenchError!void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    return runBenchRoute(allocator, args, &fw.interface);
}

fn runBenchRoute(allocator: std.mem.Allocator, args: []const []const u8, writer: *std.Io.Writer) BenchError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseArgs(arena, args);
    if (parsed.save_candidate) |target| {
        if (target.len == 0 or std.mem.startsWith(u8, target, "--")) return error.InvalidCandidateName;
    }
    const names = if (parsed.cli.named.items.len > 0)
        parsed.cli.named.items
    else
        try corpus(arena, parsed.cli.project_dir);

    // Opened BEFORE the first board so an interrupted run still says what it
    // was measuring, and closed after `finish` so an interrupted run's file
    // simply has no completion record.
    var checkpoint: ?bench_checkpoint.Checkpoint = null;
    if (parsed.jsonl) |path| {
        if (path.len == 0 or std.mem.startsWith(u8, path, "--")) return error.InvalidCheckpointPath;
        checkpoint = try bench_checkpoint.Checkpoint.create(allocator, path, .{
            .tool = build_id.current(),
            .project_dir = parsed.cli.project_dir,
            .route_space = parsed.route_space,
            .saved_module_routes = parsed.saved_module_routes,
            .save_candidate = parsed.save_candidate,
            .boards = names,
        });
    }
    defer if (checkpoint) |*cp| cp.deinit();

    const results = try benchAll(allocator, arena, names, parsed, if (checkpoint) |*cp| cp else null);
    if (checkpoint) |*cp| try cp.finish(results.len, geomeanCompletion(results));

    if (parsed.cli.json) try writeJson(writer, results) else try writeTable(writer, results);
    if (parsed.breakdown) try writeBreakdown(writer, results);

    // The durable regression gate: compare scored boards to a committed
    // baseline and fail (non-zero exit) on any regression. Record a baseline
    // with `netlisp bench-route --project-dir … --json > baseline.json`.
    if (parsed.cli.baseline) |path| {
        // loadBaseline/checkBaseline carry their own read/parse/allocator errors;
        // any failure here is a gate failure, folded into BaselineRegression so
        // the command exits non-zero (a missing/corrupt baseline is never a pass).
        const baseline = loadBaseline(arena, path) catch return error.BaselineRegression;
        const report = checkBaseline(arena, results, &baseline) catch return error.BaselineRegression;
        try writeBaselineReport(writer, report, path);
        try writer.flush();
        if (!report.pass) return error.BaselineRegression;
    }
    try writer.flush();
    for (results) |result| if (result.quality.candidate.err != null) return error.CandidateSaveFailed;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: bench-route - --jsonl names a checkpoint path, and an empty or flag-shaped one fails the run rather than measuring without a record
test "the jsonl checkpoint path is parsed and a malformed one fails the run" {
    var parsed = try parseArgs(testing.allocator, &.{ "--jsonl", "/tmp/run.jsonl", "board-a" });
    defer parsed.cli.named.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/run.jsonl", parsed.jsonl.?);
    var missing = try parseArgs(testing.allocator, &.{"--jsonl"});
    defer missing.cli.named.deinit(testing.allocator);
    try testing.expectEqualStrings("", missing.jsonl.?);
    var none = try parseArgs(testing.allocator, &.{"board-a"});
    defer none.cli.named.deinit(testing.allocator);
    try testing.expect(none.jsonl == null);

    // A path that is empty, or that is the next flag because the value was
    // omitted, must not become a filename — the run fails instead.
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expectError(
        error.InvalidCheckpointPath,
        runBenchRoute(testing.allocator, &.{ "--jsonl", "--breakdown" }, &out.writer),
    );
    try testing.expectError(
        error.InvalidCheckpointPath,
        runBenchRoute(testing.allocator, &.{"--jsonl"}, &out.writer),
    );
}

// spec: bench-route - --route-space field selects the signed-margin path director while lattice remains the default
// spec: bench-route - --no-saved-module-routes measures generated routing without module snapshot tracks or vias; saved placement and shown pours remain inputs, and JSON reports the selected policy plus each local attempt
test "route-space CLI selects field and defaults to lattice" {
    var default_args = try parseArgs(testing.allocator, &.{});
    defer default_args.cli.named.deinit(testing.allocator);
    try testing.expectEqualStrings("lattice", default_args.route_space);
    var field_args = try parseArgs(testing.allocator, &.{ "--route-space", "field", "board-a" });
    defer field_args.cli.named.deinit(testing.allocator);
    try testing.expectEqualStrings("field", field_args.route_space);
    try testing.expectEqualStrings("board-a", field_args.cli.named.items[0]);
    var fresh_args = try parseArgs(testing.allocator, &.{ "--no-saved-module-routes", "board-a" });
    defer fresh_args.cli.named.deinit(testing.allocator);
    try testing.expect(default_args.saved_module_routes);
    try testing.expect(!fresh_args.saved_module_routes);
    try testing.expectEqualStrings("board-a", fresh_args.cli.named.items[0]);
}

// spec: bench-route - a board's completion fraction is its routed share of routable nets, and a board with nothing to route counts complete
test "completion fraction handles the empty board" {
    try testing.expectEqual(@as(f64, 1), (BoardResult{ .name = "x", .ok = true }).completion());
    const half = BoardResult{ .name = "y", .ok = true, .placed = true, .nets = .{ .routed = 45, .total = 90 } };
    try testing.expectEqual(@as(f64, 0.5), half.completion());
}

// spec: bench-route - the corpus score is the geometric mean of per-board completion, so one collapsed board cannot be averaged away by easy ones
test "geomean punishes a collapsed board more than an arithmetic mean would" {
    const mixed = [_]BoardResult{
        .{ .name = "a", .ok = true, .placed = true, .nets = .{ .routed = 100, .total = 100 } },
        .{ .name = "b", .ok = true, .placed = true, .nets = .{ .routed = 100, .total = 100 } },
        .{ .name = "c", .ok = true, .placed = true, .nets = .{ .routed = 10, .total = 100 } },
    };
    const g = geomeanCompletion(&mixed);
    const arithmetic = (1.0 + 1.0 + 0.1) / 3.0;
    try testing.expect(g < arithmetic);
    try testing.expect(g > 0.4 and g < 0.5); // cube root of 0.1
}

// spec: bench-route - a board that failed to load or route is reported, not silently dropped from the corpus score
test "a failed board is excluded from the geomean and printed as FAILED" {
    const with_failure = [_]BoardResult{
        .{ .name = "good", .ok = true, .placed = true, .nets = .{ .routed = 90, .total = 90 } },
        .{ .name = "broken", .ok = false },
    };
    try testing.expectEqual(@as(f64, 1), geomeanCompletion(&with_failure));

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, &with_failure);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "90/90") != null);
}

// spec: bench-route - a board with no saved layout is reported but kept out of the corpus score, since its fallback placement is neither blessed nor stable
test "an unplaced board is listed but not scored" {
    const mixed = [_]BoardResult{
        .{ .name = "blessed", .ok = true, .placed = true, .nets = .{ .routed = 90, .total = 90 } },
        // Routed nothing because it has no blessed placement — a grid fallback,
        // not a routing measurement. Scoring it would peg the corpus at ~0.
        .{ .name = "unplaced", .ok = true, .placed = false, .nets = .{ .routed = 0, .total = 137 } },
    };
    try testing.expect(!mixed[1].scorable());
    try testing.expectEqual(@as(f64, 1), geomeanCompletion(&mixed));

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, &mixed);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "unplaced") != null);
    try testing.expect(std.mem.indexOf(u8, s, "not scored") != null);
    try testing.expect(std.mem.indexOf(u8, s, "1 scored of 2") != null);
}

// spec: bench-route - the corpus results serialise to JSON so a driver can record them in the benchmark ledger
test "json output carries every board and the geomean" {
    const results = [_]BoardResult{
        .{
            .name = "board-a",
            .ok = true,
            .placed = true,
            .nets = .{ .routed = 86, .total = 90 },
            .drc = .{ .total = 10, .errors = 7 },
            .copper = .{
                .tracks = 1076,
                .vias = 166,
                .mm = 1150.5,
                .connected_mm = 1100.25,
                .open_mm = 50.25,
                .per_net = &.{.{ .name = "SIG", .mm = 12.5, .vias = 1 }},
            },
            .wall_ms = 107700,
        },
    };
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJson(&w, &results);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "\"name\":\"board-a\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"routed\":86") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"connected_trace_mm\":1100.25") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"open_trace_mm\":50.25") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"per_net\":[{\"name\":\"SIG\",\"trace_mm\":12.5000,\"vias\":1,\"open\":false}]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"geomean_completion\"") != null);
}

// spec: bench-route - the JSON board name is escaped like every other string in the row, so a design filename carrying a quote still yields a parseable ledger
test "json output escapes the board name" {
    // The board name is a design filename, and a filename may hold a quote or a
    // backslash. It used to be interpolated raw as `"name":"{s}"`, which tore
    // the record the `--baseline` gate re-reads.
    const results = [_]BoardResult{.{
        .name = "we\"ird\\board",
        .ok = true,
        .placed = true,
        .nets = .{ .routed = 1, .total = 1 },
    }};
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJson(&w, &results);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const board = parsed.value.object.get("boards").?.array.items[0].object;
    try testing.expectEqualStrings(results[0].name, board.get("name").?.string);
}

// spec: bench-route - trace totals separate completed-net copper from partial copper left by open nets, and JSON reports per-net trace/via totals so runs with unlike completion can be compared on common nets
test "open trace length is identified by the connectivity oracle's net names" {
    const per_net = [_]router.NetRouted{
        .{ .name = "DONE", .mm = 12.5, .vias = 0 },
        .{ .name = "OPEN_A", .mm = 3.25, .vias = 0 },
        .{ .name = "OPEN_B", .mm = 7.0, .vias = 1 },
    };
    const open = [_][]const u8{ "OPEN_B", "OPEN_A" };
    try testing.expectApproxEqAbs(@as(f64, 10.25), openTraceMm(&per_net, &open), 1e-9);
}

// spec: bench-route - the JSON per-board row names the oracle's still-open nets, sorted, so a completion change reads net by net
test "json output names the open nets in sorted order" {
    const open = [_][]const u8{ "SPI_SCK", "EN_BUCK6V", "V_3V3A" };
    const results = [_]BoardResult{.{
        .name = "board-a",
        .ok = true,
        .placed = true,
        .nets = .{ .routed = 88, .total = 91, .open = sortedOpen(testing.allocator, &open) },
    }};
    defer testing.allocator.free(results[0].nets.open);
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try writeJson(&w.writer, &results);
    const s = w.written();
    try testing.expect(std.mem.indexOf(u8, s, "\"open\":[\"EN_BUCK6V\",\"SPI_SCK\",\"V_3V3A\"]") != null);
    // A board with nothing open still carries the field, as an empty array.
    const clean = [_]BoardResult{.{ .name = "tiny", .ok = true, .placed = true, .nets = .{ .routed = 3, .total = 3 } }};
    var w2 = std.Io.Writer.Allocating.init(testing.allocator);
    defer w2.deinit();
    try writeJson(&w2.writer, &clean);
    try testing.expect(std.mem.indexOf(u8, w2.written(), "\"open\":[]") != null);
}

fn baselineSample() Baseline {
    return .{ .boards = &.{
        .{ .name = "a", .ok = true, .placed = true, .routed = 90, .total = 90, .drc_errors = 2, .tracks = 500, .vias = 60, .trace_mm = 800.0 },
        .{ .name = "b", .ok = true, .placed = true, .routed = 40, .total = 50, .drc_errors = 8, .tracks = 300, .vias = 40, .trace_mm = 600.0 },
        .{ .name = "unplaced", .ok = true, .placed = false, .routed = 0, .total = 137 },
    } };
}

// spec: bench-route - the --baseline gate passes a run identical to its committed baseline
test "baseline gate passes an unchanged run and is geomean-neutral" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const baseline = baselineSample();
    const results = [_]BoardResult{
        .{ .name = "a", .ok = true, .placed = true, .nets = .{ .routed = 90, .total = 90 }, .copper = .{ .tracks = 500, .vias = 60, .mm = 800.0 } },
        .{ .name = "b", .ok = true, .placed = true, .nets = .{ .routed = 40, .total = 50 }, .copper = .{ .tracks = 300, .vias = 40, .mm = 600.0 } },
    };
    const report = try checkBaseline(arena, &results, &baseline);
    try testing.expect(report.pass);
    try testing.expect(report.regressed.len == 0);
    try testing.expect(report.geomean_now > report.geomean_ref - 1e-9);
}

// spec: bench-route - the --baseline gate fails a scorable board that loses more than one net, even when every other number is healthy
test "baseline gate fails a board that loses more than one net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const baseline = baselineSample();
    // Board 'a' fell from 90 to 88 routable — a two-net regression (the rule is
    // "lose at most one"), so the gate must fail even though every other number
    // is healthy.
    const results = [_]BoardResult{
        .{ .name = "a", .ok = true, .placed = true, .nets = .{ .routed = 88, .total = 90 } },
        .{ .name = "b", .ok = true, .placed = true, .nets = .{ .routed = 40, .total = 50 } },
    };
    const report = try checkBaseline(arena, &results, &baseline);
    try testing.expect(!report.pass);
    try testing.expectEqual(@as(usize, 1), report.regressed.len);
    try testing.expect(std.mem.eql(u8, "a", report.regressed[0]));
}

// spec: bench-route - the --baseline gate tolerates a one-net loss but still fails a geomean drop over the shared board set
test "baseline gate tolerates a one-net loss but fails a geomean drop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const baseline = baselineSample();
    // Board 'b' lost one net (40→39, allowed) so the hard rule passes, but the
    // geomean over the shared board set drops — the soft rule catches it.
    const results = [_]BoardResult{
        .{ .name = "a", .ok = true, .placed = true, .nets = .{ .routed = 90, .total = 90 } },
        .{ .name = "b", .ok = true, .placed = true, .nets = .{ .routed = 39, .total = 50 } },
    };
    const report = try checkBaseline(arena, &results, &baseline);
    try testing.expect(!report.pass);
    try testing.expect(report.regressed.len == 0);
    try testing.expect(report.geomean_now < report.geomean_ref);
}

// spec: bench-route - the --baseline gate reports a newly-scored board as unlined rather than silently passing on it
test "baseline gate reports a newly-scored board as unlined, not a silent pass" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const baseline = baselineSample();
    const results = [_]BoardResult{
        .{ .name = "a", .ok = true, .placed = true, .nets = .{ .routed = 90, .total = 90 } },
        .{ .name = "brand-new", .ok = true, .placed = true, .nets = .{ .routed = 100, .total = 100 } },
    };
    const report = try checkBaseline(arena, &results, &baseline);
    try testing.expect(report.pass); // nothing regressed
    try testing.expectEqual(@as(usize, 1), report.unlined.len);
    try testing.expect(std.mem.eql(u8, "brand-new", report.unlined[0]));
}

// spec: bench-route - the --baseline gate ratchets dangling-copper, implicit-junction, and hairline-gap counts per board so none may rise
test "baseline gate rejects a new connectivity defect" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const baseline = baselineSample();
    var damaged = BoardResult{ .name = "a", .ok = true, .placed = true, .nets = .{ .routed = 90, .total = 90 } };
    damaged.drc.kinds[@backingInt(drc.Kind.hairline_gap)] = 1;
    const report = try checkBaseline(arena, &.{damaged}, &baseline);
    try testing.expect(!report.pass);
    try testing.expectEqual(@as(usize, 1), report.defect_regressed.len);
    try testing.expectEqualStrings("a", report.defect_regressed[0]);
}

// spec: bench-route - --save-candidate writes the measured copper and solved poses to a new layout, preserving the source layout and its star and refusing a name collision
// spec: bench-route - benchmark candidates include generated perimeter copper and use the physical connectivity oracle before measurement and capture
test "benchmark candidate capture preserves source and refuses collisions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/foo.layouts.json", .data = "{\"layouts\":[]}" });
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 10, .y = 5, .locked = true }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{.{ .name = "GND", .pins = &.{} }},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
        .rules = .{ .perimeter_fence = .{ .via_dia = 0.4, .via_drill = 0.2, .spacing = 1, .edge_offset = 0.5 } },
    };
    // Deliberately stale solver counts must not survive physical reconciliation.
    const raw = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 7, .total = 8, .failed = &.{"stale"} };
    const routed = try finishCandidate(alloc, placement, raw, &.{});
    try testing.expect(routed.vias.len > 0);
    try testing.expectEqual(@as(usize, 0), routed.total);
    try testing.expectEqual(@as(usize, 0), routed.failed.len);
    try testing.expectError(error.NoSavedPlacement, captureCandidate(alloc, project, "foo", placement, routed, "trial"));
    const source = pcb_layout_page.SavedLayout{
        .name = "source",
        .kind = "manual",
        .ts = 1,
        .score = null,
        .parts = &.{.{ .ref = "U1", .x = 42, .y = 7, .rot = 0 }},
        .default = true,
        .outline = .{ .x = 0, .y = 0, .w = 20, .h = 10 },
        .texts = &.{.{ .x = 2, .y = 2, .text = "KEEP" }},
    };
    try pcb_layout_page.mcpPersistWorking(alloc, project, "foo", source, true);
    try captureCandidate(alloc, project, "foo", placement, routed, "trial");
    const saved = pcb_layout_page.mcpReadWorking(alloc, project, "foo", "trial").?;
    try testing.expect(!saved.default);
    try testing.expectEqual(@as(f64, 10), saved.parts[0].x);
    try testing.expect(saved.parts[0].locked);
    try testing.expectEqual(routed.vias.len, saved.routes.?.vias.len);
    try testing.expectEqualStrings("KEEP", saved.texts[0].text);
    try testing.expectEqual(@as(f64, 20), saved.outline.?.w);
    const original = pcb_layout_page.mcpReadWorking(alloc, project, "foo", null).?;
    try testing.expectEqualStrings("source", original.name);
    try testing.expect(original.routes == null);
    // Exercise both the early check and the locked create-only persistence gate.
    try testing.expectError(error.CandidateNameExists, captureCandidate(alloc, project, "foo", placement, raw, "trial"));
    try testing.expectError(error.CandidateNameExists, pcb_layout_page.mcpCreateWorking(alloc, project, "foo", source));
    try testing.expectEqual(routed.vias.len, pcb_layout_page.mcpReadWorking(alloc, project, "foo", "trial").?.routes.?.vias.len);
    const refused = benchOneConfigured(alloc, project, "foo", .{ .save_candidate = "trial" });
    try testing.expectEqualStrings("CandidateNameExists", refused.quality.candidate.err.?);
    try testing.expect(!refused.ok);
    const missing = benchOneConfigured(alloc, project, "missing-design", .{ .save_candidate = "trial" });
    try testing.expect(!missing.ok);
    try testing.expectEqualStrings("CandidateNotProduced", missing.quality.candidate.err.?);
    var output: std.Io.Writer.Allocating = .init(alloc);
    try testing.expectError(error.CandidateSaveFailed, runBenchRoute(alloc, &.{ "--project-dir", project, "--save-candidate", "trial", "foo" }, &output.writer));
    try testing.expectError(error.InvalidCandidateName, runBenchRoute(alloc, &.{"--save-candidate"}, &output.writer));
    try testing.expectError(error.BaselineRegression, runBenchRoute(alloc, &.{ "--project-dir", project, "--baseline", "missing-baseline.json", "foo" }, &output.writer));
}
