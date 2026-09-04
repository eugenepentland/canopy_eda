//! GET /api/pcb-describe/:name — structured spatial facts about the solved
//! placement, the textual twin of `/api/pcb-png`. An agent reads relations
//! ("C_BOOT1 sits on U1's top edge, its power pad 1.46 mm from the BOOT1
//! pad") far more reliably than it estimates them from pixels, so the two
//! endpoints are meant to be consumed together: same placement-selection
//! logic (`solveForRequest`), same parameter set (`pngRequestFromQuery`) —
//! the facts always describe the board the image shows.
//!
//! Facts emitted: board bbox + axes convention, objective summary, anchor
//! (most-connected hub), per-part side-of-anchor / gap / nets / spec coverage,
//! per-decoupling-loop power-leg length + inductance + net, each hub's
//! net→package-edge pad map, and (with `?route=1`) the routed-copper summary.
//!
//! A `progress` block (the completion ladder — `pcb_progress.assemble` →
//! `placement/progress.zig`) rides along, and its stale-plan warnings mirror
//! into `lint[]`. Assembling it runs ERC + the fab-readiness gate per request
//! (acceptable — the load is dominated by the solve either way), but reuses the
//! one placement selection and the one `module_policy` analysis, and loads the
//! persisted copper exactly once.

const std = @import("std");
const httpz = @import("httpz");
const optimizer = @import("../placement/optimizer.zig");
const board_layers = @import("../board_layers.zig");
const env = @import("../eval/env.zig");
const router = @import("../placement/router.zig");
const rf_port_report = @import("../placement/rf_port_report.zig");
const rf_path_solver = @import("../placement/rf_path_solver.zig");
const perimeter_fence = @import("../placement/perimeter_fence.zig");
const drc = @import("../placement/drc.zig");
const drc_json = @import("drc_json.zig");
const drc_rules = @import("drc_rules.zig");
const drc_match = @import("../placement/drc_match.zig");
const match_group = @import("../placement/match_group.zig");
const outline_mod = @import("../placement/outline.zig");
const implicit_plane = @import("../placement/implicit_plane.zig");
const module_policy = @import("../placement/module_policy.zig");
const impedance = @import("../placement/impedance.zig");
const via_antipad = @import("../placement/via_antipad.zig");
const layout_lint = @import("../placement/layout_lint.zig");
const layout_layers = @import("layout_layers.zig");
const near_bind = @import("../placement/near_bind.zig");
const routability_lint = @import("../placement/routability_lint.zig");
const port_escape = @import("../placement/port_escape.zig");
const rough_routability = @import("../placement/rough_routability.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const route_score = @import("../placement/route_score.zig");
const progress = @import("../placement/progress.zig");
const pcb_progress = @import("pcb_progress.zig");
const page_cache_endpoint = @import("page_cache_endpoint.zig");
const page_cache = @import("page_cache.zig");
const pcb_keepout_json = @import("pcb_keepout_json.zig");
const progress_cache = @import("progress_cache.zig");
const fab_readiness = @import("../fab_readiness.zig");
const export_gerber = @import("../export_gerber.zig");
const pour = @import("../placement/pour.zig");
const pad_shape = @import("../placement/pad_shape.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const route_diagnose = @import("../placement/route_diagnose.zig");
const stuck_json = @import("stuck_json.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const serve_root = @import("../serve.zig");
const net_name = @import("../net_name.zig");
const Server = serve_root.Server;

/// Which side of the anchor (or of a loop's hub) something sits on, in board
/// coordinates: x grows right, y grows DOWN, so `top` means smaller y. The
/// same words the `(placement …)` spec uses.
pub const Side = enum { left, right, top, bottom, center };

/// The two cached facts endpoints below. They differ only in what they compute
/// — the full spatial-facts document, or the compact completion ladder — so the
/// hit / compute / frame / retain body they share lives once in
/// `page_cache_endpoint.Endpoint`, alongside the image endpoint's.
const facts_endpoint = page_cache_endpoint.Endpoint(.{
    .compute = describeDesign,
    .request_opts = pcb_layout_page.pngRequestFromQuery,
    .failure = pcb_layout_page.pngFailure,
    .version_of = serve_root.getLiveVersion,
    .content_type = httpz.ContentType.JSON,
    .error_body = page_cache_endpoint.ErrorBody.json,
    .no_store = false,
});

const ladder_endpoint = page_cache_endpoint.Endpoint(.{
    .compute = describeProgress,
    .request_opts = pcb_layout_page.pngRequestFromQuery,
    .failure = pcb_layout_page.pngFailure,
    .version_of = serve_root.getLiveVersion,
    .content_type = httpz.ContentType.JSON,
    .error_body = page_cache_endpoint.ErrorBody.json,
    .no_store = false,
});

/// GET /api/pcb-describe/:name — accepts the same query parameters as
/// /api/pcb-png (layout=, regen=, sub=, placement=off, route=1, tuning knobs)
/// so the facts match whichever board variant the caller is looking at.
pub fn pcbDescribeApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    facts_endpoint.answer(&ctx.state.caches.describe_json, ctx.project_dir, name, req, res);
}

/// GET /api/layout-progress/:name — the compact six-stage completion ladder
/// used by home-page design cards. This deliberately returns only the progress
/// report, not the much larger spatial-facts document from pcbDescribeApi.
pub fn layoutProgressApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    ladder_endpoint.answer(&ctx.state.caches.progress_json, ctx.project_dir, name, req, res);
}

/// Solve (or load) the placement exactly as the PNG endpoint would and return
/// the facts JSON. Bytes are owned by `alloc` (callers pass an arena).
/// `deps`, when non-null, receives the file dependency set of this computation
/// — the same one `describeProgress` captures, because these facts EMBED that
/// ladder and read no sidecar it doesn't — so the caller can cache the body
/// against it. The capture happens while the evaluators are still alive; the
/// caller owns the returned set and must `deinit` it.
pub fn describeDesign(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: pcb_layout_page.PngRequest,
    deps: ?*?page_cache.FileSet,
) pcb_layout_page.PngError![]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    // Captured before the deferred `deinit`s above run, and before any early
    // error return, so a caller's cache never keys on a half-built read-set.
    defer if (deps) |out| {
        out.* = if (module_res) |mr|
            progress_cache.captureDeps(alloc, &.{ &eval, mr.eval }, project_dir, name)
        else
            progress_cache.captureDeps(alloc, &.{&eval}, project_dir, name);
    };
    const solved = try pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);

    // Seed router/DRC from the design's resolved `(design-rules …)` so the facts
    // describe the same board the PNG shows and the fab gate checks. `?route=1`
    // routes fresh (plan-lowering seam + stuck-net diagnostics); otherwise the
    // shown layout's persisted copper is restored (page parity —
    // solveForRequest.restored) and DRC-checked the same way, so a
    // no-route describe reports the saved routing.
    const route_params = solved.placement.rules.design.routeParams();
    // One board, one pour. The reporting DRC below rasters every plane and
    // hand-drawn zone of this board; the connectivity tally and the open-net
    // report that follow ask the SAME questions of the SAME copper, and each
    // used to raster all of it privately — 55-60 s apiece on barracuda-base,
    // three times in one request. They now read what the DRC pass built
    // (`drc_rules.sharedFills`), and the board-edge margin field every one of
    // them starts from is seeded ONCE here instead of once per fill per net.
    const base_edge = drc_rules.sharedEdgeField(alloc, solved.placement) catch null;
    var stuck: []const route_diagnose.Diagnosis = &.{};
    var claimed: usize = 0;
    var raw_routed: ?router.RouteResult = if (opts.route) blk: {
        // Same plan-lowering seam as route_pcb, so these facts == commit. The
        // diagnostic sibling also floods the LIVE grid to explain each stuck net.
        var route_options = route_plan.lowerOrEmpty(alloc, solved.block, solved.placement);
        route_options.existing_zones = solved.shown_zones.sources;
        const seeded = pcb_layout_page.diagnoseWithSubcircuitSeeds(
            alloc,
            project_dir,
            solved.block,
            solved.placement,
            route_params,
            route_options,
        ) catch break :blk null;
        const diag = seeded.diagnostic;
        stuck = diag.stuck;
        claimed = diag.claimed_routed;
        break :blk diag.result;
    } else solved.restored.routes;
    if (opts.route) raw_routed = perimeter_fence.append(alloc, solved.placement, raw_routed) catch raw_routed;
    const routed: ?RoutedSummary = if (raw_routed) |r| blk: {
        const check: drc_rules.CopperCheck = .{
            .placement = solved.placement,
            .routed = r,
            .clearance = route_params.clearance,
            .zones = solved.shown_zones.user,
            .texts = solved.texts,
            .base_edge = base_edge,
        };
        const v = drc_rules.checkFilteredZones(alloc, project_dir, name, check);
        // The rasters that pass just poured, borrowed for the two sweeps below.
        // Nothing they produce points into a fill (`fill_cache`'s borrow rule),
        // so the borrow ends with this block.
        var board = drc_rules.sharedFills(alloc, check);
        defer board.release();
        const prep: fab_readiness.BoardPrep = .{
            .plane_fills = board.plane_fills,
            .zone_fills = if (board.failed) null else board.zone_fills,
            .base = base_edge,
        };
        var trace: f64 = 0;
        for (r.tracks) |t| trace += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        // Connectivity comes from the ORACLE, fresh route or restored copper
        // alike (see `netConnectivity`). The router's own counters answer a
        // different question — "did every leg's search succeed" — and on a
        // `?route=1` run they shipped in the SAME payload as `open_nets`, which
        // is the oracle: barracuda reported `routed:85, unrouted:[5 names]`
        // beside thirteen open nets. Two tallies in one object, and the
        // optimistic one is the one a reader sees first.
        const conn: fab_readiness.Tally = try connectivityTally(alloc, solved.placement, r, solved.shown_zones.user, prep);
        break :blk .{
            .trace_mm = trace,
            .tracks = r.tracks.len,
            .vias = r.vias.len,
            .drc = v.len,
            .drc_errors = drc.errorCount(v),
            .bends = route_score.bendCount(alloc, r.tracks) catch 0,
            .quality_warns = route_score.qualityWarnCount(v),
            .drc_list = v,
            .names = .{ .nets = solved.placement.nets, .parts = solved.placement.parts },
            .routed = conn.routed,
            .total = conn.total,
            .unrouted = conn.open,
            .router_claimed = claimed,
            .grid_overflow = r.grid_overflow,
            .ripup_rounds = r.ripup_rounds,
            .smoothed_arcs = r.arcs.len,
            .sharp_bends = r.sharp_bends.len,
            .rf_port_outcomes = r.rf_port_outcomes,
            .per_net = router.perNetRouted(alloc, solved.placement, r) catch &.{},
            .match_groups = drc_match.measure(alloc, solved.placement, .{ .tracks = r.tracks, .vias = r.vias }) catch &.{},
            .stuck = stuck,
            // Pours count as connecting copper either way — a fresh route and a
            // restored board both sit on the shown layout's zones.
            .open_nets = fab_readiness.openNetsPrepared(
                alloc,
                solved.placement,
                routeCopper(r, solved.shown_zones.user),
                prep,
            ) catch &.{},
        };
    } else null;

    // `?cropnet=` zoom lens: the world bbox of the named nets' pads + copper +
    // margin — the textual twin of the PNG viewport, so an agent gets the exact
    // lens window without recomputing it from pixels.
    const crop_bbox: ?[4]f64 = if (opts.crop_nets.len > 0)
        (render_pcb_png.cropNetBbox(alloc, solved.placement, raw_routed, opts.crop_nets, render_pcb_png.cropnet_margin_mm) catch null)
    else
        null;

    // The module-policy read feeds BOTH the facts' `module_policy` block and the
    // progress ladder's plan resolution — compute it once here and thread it in.
    var policy = module_policy.analyze(alloc, solved.placement) catch return error.BuildFailed;
    defer policy.deinit(alloc);
    const report = pcb_progress.assemble(alloc, project_dir, name, solved, opts, policy) catch
        return error.BuildFailed;

    // Escapes an authored `(assign-escapes …)` wave already owns — the mask the
    // static contention gate stays quiet on. Empty (and free) for every design
    // that authors no such wave.
    const assigned = plan_resolve.escapeAssignedFor(alloc, solved.block, solved.placement) catch &.{};

    // The block's own `(port …)` nets, which the placement itself cannot name.
    // Without this the port-escape gate is silent, so the facts would disagree
    // with the rough solve that just ran the same gate with the same mask.
    const ports = port_escape.portNets(alloc, solved.block, solved.placement.nets) catch &.{};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    writeDescribeJson(
        &aw.writer,
        alloc,
        solved.placement,
        solved.spec_status,
        routed,
        name,
        solved.title,
        .{
            .policy = policy,
            .progress = report,
            .crop_bbox = crop_bbox,
            .pads = opts.pads,
            .escapes_assigned = assigned,
            .port_nets = ports,
            .layer_audit = solved.restored.layer_audit,
        },
    ) catch return error.BuildFailed;
    return aw.written();
}

/// Solve `name` the way `describeDesign` does and return ONLY the completion
/// ladder JSON, prefixed with the design name:
/// `{"name":…,"current":…,"stages":[…]}` (+ `current_wave` / `warnings` when a
/// `(pcb-plan …)` splits the placement/routing rungs). Backs the read-only
/// `get_layout_progress` CLI tool. Bytes are owned by `alloc`.
/// `deps`, when non-null, receives the file dependency set of this computation
/// (both evaluators' read-sets plus the ladder's sidecars) so the caller can
/// cache the body against it. The capture happens while the evaluators are
/// still alive; the caller owns the returned set and must `deinit` it.
pub fn describeProgress(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: pcb_layout_page.PngRequest,
    deps: ?*?page_cache.FileSet,
) pcb_layout_page.PngError![]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    // Captured before the deferred `deinit`s above run, and before any early
    // error return, so a caller's cache never keys on a half-built read-set.
    defer if (deps) |out| {
        out.* = if (module_res) |mr|
            progress_cache.captureDeps(alloc, &.{ &eval, mr.eval }, project_dir, name)
        else
            progress_cache.captureDeps(alloc, &.{&eval}, project_dir, name);
    };
    const solved = try pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);
    var policy = module_policy.analyze(alloc, solved.placement) catch return error.BuildFailed;
    defer policy.deinit(alloc);
    const report = pcb_progress.assemble(alloc, project_dir, name, solved, opts, policy) catch
        return error.BuildFailed;

    // Splice `"name"` into the ladder object: emit `{"name":…,` then the ladder
    // JSON with its leading `{` dropped (`progress.writeJson` always opens with
    // `{"current":…`).
    var pw: std.Io.Writer.Allocating = .init(alloc);
    progress.writeJson(&pw.writer, report) catch return error.BuildFailed;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    writeNamedLadder(&aw.writer, name, pw.written()) catch return error.BuildFailed;
    return aw.written();
}

/// Emit `{"name":<name>,<ladder-without-its-leading-brace>}` — merges the design
/// name into the `progress.writeJson` object without re-serializing it.
fn writeNamedLadder(w: *std.Io.Writer, name: []const u8, ladder: []const u8) DescribeError!void {
    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, name);
    try w.writeByte(',');
    try w.writeAll(ladder[1..]);
}

const RoutedSummary = struct {
    trace_mm: f64,
    tracks: usize,
    vias: usize,
    drc: usize,
    /// Fab-blocking subset of `drc` — the term the routing score penalizes.
    /// Counted by `drc.errorCount`, so warnings AND `net_open` are excluded:
    /// this same object already reports connectivity as `routed`/`total`/
    /// `unrouted`, and charging an open net through the score's DRC term too
    /// made one open net outweigh the completion it is already measured by.
    drc_errors: usize = 0,
    /// The score's two v2 geometry terms, measured by the score module's own
    /// shared helpers over the same copper/findings this summary reports, so
    /// this writer's number matches `route_experiment`'s for the same board.
    bends: usize = 0,
    quality_warns: usize = 0,
    /// The violations behind the count, each carrying its short traceable id
    /// (pcb_layout_page.violationId) — same records the viewer shows.
    drc_list: []const drc.Violation = &.{},
    routed: usize = 0,
    total: usize = 0,
    unrouted: []const []const u8 = &.{},
    /// What the ROUTER claimed before the post-route oracle gate corrected it.
    /// `routed` above is the oracle's answer and the only one a reader should
    /// act on; this is the router's, kept as a DIAGNOSTIC and emitted only when
    /// it exceeds `routed`. That difference is the router counting a net
    /// complete whose pads its own copper never joined — a defect worth seeing
    /// once, rather than a second tally competing with the first.
    router_claimed: usize = 0,
    grid_overflow: bool = false,
    /// Bounded rip-up rounds the router ran after its greedy pass (0 = none).
    ripup_rounds: usize = 0,
    /// RF bend discipline: corners smoothed into arcs / corners that missed
    /// their 3x-width radius (the sharp_bend DRC warnings).
    smoothed_arcs: usize = 0,
    sharp_bends: usize = 0,
    /// Full deterministic port-frame candidate histories, including failed
    /// fits, so design iteration can act on geometry rather than a bend count.
    rf_port_outcomes: []const rf_port_report.Outcome = &.{},
    /// Per-net routed copper: length (mm) + via count, longest first.
    per_net: []const router.NetRouted = &.{},
    /// Stuck-net diagnostics: per failed net, its inferred failure mode, the
    /// copper blocking it, and ranked constraint-DSL / router-code remedies.
    stuck: []const route_diagnose.Diagnosis = &.{},
    /// Per open net: its pads (with coordinates + island), and the shortest
    /// pad-to-pad hops that would close it. The aiming data for `add_tracks`.
    open_nets: []const fab_readiness.OpenNet = &.{},
    /// Net / part tables so `drc_list` can name the parties of each violation
    /// (see `drc_json.Names`); empty in the hand-built unit fixtures.
    names: drc_json.Names = .{},
    /// Per `(net-class … (match-group …))` group: each member's effective routed
    /// length and the spread against the declared tolerance
    /// (`drc_match.measure`). Empty — and absent from the JSON — for every
    /// design that declares no group.
    match_groups: []const match_group.Report = &.{},
};

/// Net-completion counts for RESTORED copper, from the shared connectivity
/// oracle (`fab_readiness.routableTally`, fed the identical tracks+vias
/// `pcb_progress.assemble` passes), so this block, `get_layout_progress`, and
/// `run_fab_readiness` always agree.
///
/// Neither surface may use the ROUTER's counters. `restoreRoutes` leaves them at
/// ZERO, so a restored board with open nets once reported `"routed":0,"total":0`
/// with an empty `unrouted[]` — indistinguishable from "nothing left to route".
/// A fresh `?route=1` run has the opposite failure: the router counts a leg
/// whose search succeeded, so barracuda shipped `routed:85` next to thirteen
/// `open_nets` in one payload. The oracle answers both honestly.
fn connectivityTally(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    r: router.RouteResult,
    zones: []const pour.UserZone,
    prep: fab_readiness.BoardPrep,
) std.mem.Allocator.Error!fab_readiness.Tally {
    const conn = try fab_readiness.netConnectivityPrepared(alloc, placement, routeCopper(r, zones), prep);
    return fab_readiness.summarizeConnectivity(alloc, conn);
}

fn routeCopper(r: router.RouteResult, zones: []const pour.UserZone) export_gerber.Copper {
    return .{
        .tracks = r.tracks,
        .arcs = r.arcs,
        .rf_paths = r.rf_port_outcomes,
        .vias = r.vias,
        .zones = zones,
    };
}

/// Errors the facts writer can hit: allocation (scratch maps/lists) + writer.
pub const DescribeError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// The caller-computed analyses `writeDescribeJson` folds into the facts: the
/// shared `module_policy` read (drives the `module_policy` block, the layout
/// gates, and the progress plan) and the optional completion-ladder `progress`
/// report (emitted as the `progress` block; its warnings mirror into `lint`).
/// A null `progress` (the hand-built-placement unit tests) omits that block.
pub const Analyses = struct {
    policy: module_policy.ModulePolicy,
    progress: ?progress.Report = null,
    /// `?cropnet=` zoom-lens window (world mm; [minx,miny,maxx,maxy]): the named
    /// nets' pad + copper bbox + margin, the numeric twin of the PNG viewport.
    /// Null (the default) omits the `crop_bbox` block.
    crop_bbox: ?[4]f64 = null,
    /// `?pads=1` — emit the full pad obstacle table (see `writePadsJson`).
    pads: bool = false,
    /// Net-index mask of the nets an authored `(assign-escapes …)` route wave
    /// already schedules (`plan_resolve.escapeAssignedFor`). Suppresses the
    /// static escape-contention gate for a fan whose every net is covered.
    /// Empty (the default) masks nothing.
    escapes_assigned: []const bool = &.{},
    /// Net-index mask of the block's own `(port …)` nets
    /// (`port_escape.portNets`) — what turns the `port-blocked` gate on. Empty
    /// (the default) leaves it silent.
    port_nets: []const bool = &.{},
    /// What reading the shown layout's persisted track layers back against this
    /// board found (`pcb_layout_page.auditSavedLayers`). A non-clean audit
    /// becomes the `track-layer-out-of-range` lint entry; the default is clean,
    /// so a caller with no saved layout in hand reports nothing.
    layer_audit: board_layers.LayerAudit = .{},
};

/// The `(pcb-plan …)` facts `lint[]` reads, carried as one field so `writeLint`
/// stays at its parameter ceiling: the progress ladder's stale-name warnings,
/// the escape fans an authored assignment already owns, and the saved-layer
/// audit of the copper this view restored.
const PlanFacts = struct {
    warns: []const progress.Item = &.{},
    escapes_assigned: []const bool = &.{},
    port_nets: []const bool = &.{},
    layer_audit: board_layers.LayerAudit = .{},
};

/// `"origin"` JSON key — the stable module-local name, emitted beside every ref.
const origin_key_head = ",\"origin\":";
/// Opening of a `{"ref": …}` object — emitted for parts, hub-pad maps, and roles.
const ref_key = "{\"ref\":";
/// Opening of a `{"net": …}` object — emitted for loops, net-edge maps, and stuck nets.
const net_key = stuck_json.net_key;

/// Emit the full facts document. Split from `describeDesign` so tests can run
/// it on a hand-built `Placement` without a project on disk.
pub fn writeDescribeJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    spec: ?render_pcb_png.SpecStatus,
    routed: ?RoutedSummary,
    name: []const u8,
    title: []const u8,
    an: Analyses,
) DescribeError!void {
    // ref|pad → net name, the same resolution the PNG renderer uses.
    var pad_net = std.StringHashMapUnmanaged([]const u8).empty;
    defer pad_net.deinit(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pad_net.put(alloc, key, net.name);
        }
    }
    var unplaced = std.StringHashMapUnmanaged(void).empty;
    defer unplaced.deinit(alloc);
    var auto_filled = std.StringHashMapUnmanaged(void).empty;
    defer auto_filled.deinit(alloc);
    if (spec) |sp| {
        for (sp.unplaced) |ref| try unplaced.put(alloc, ref, {});
        for (sp.auto_filled) |ref| try auto_filled.put(alloc, ref, {});
    }
    // net → the single hub package edge its pads sit on (null = several edges,
    // i.e. no preference). Drives the per-part `want_side` regret signal.
    var net_edge = std.StringHashMapUnmanaged(?Side).empty;
    defer net_edge.deinit(alloc);
    try buildNetEdgeMap(alloc, p, &pad_net, &net_edge);
    var wrong_side: std.ArrayList([]const u8) = .empty;
    defer wrong_side.deinit(alloc);

    const anchor = anchorIndex(p.parts, p.nets);

    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, name);
    try w.writeAll(",\"title\":");
    try pcb_layout_page.writeJsonStr(w, title);
    // Spell the coordinate convention out so an agent never misreads "top".
    try w.writeAll(",\"axes\":\"x grows right, y grows down; side/edge words match the (placement ...) spec: top = toward -y\"");
    if (anchor) |ai| {
        try w.writeAll(",\"anchor\":{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, p.parts[ai].ref_des);
        try w.writeAll(origin_key_head);
        try pcb_layout_page.writeJsonStr(w, originOf(p, ai));
        try w.writeAll("}");
    }
    try w.print(",\"board\":{{\"w_mm\":{d:.2},\"h_mm\":{d:.2}", .{ p.maxx - p.minx, p.maxy - p.miny });
    // The authored `(board (size W H) …)` outline, when one drives the layout —
    // distinct from the bbox above (which includes the staging band/margins).
    if (p.board_rect) |br| {
        try w.print(",\"outline\":{{\"w_mm\":{d:.2},\"h_mm\":{d:.2}", .{ br.w, br.h });
        try w.print(",\"minx\":{d:.2},\"miny\":{d:.2}", .{ br.minx, br.miny });
        // Non-rectangular boards: w/h above are the polygon's BBOX; the
        // exact closed outline is spelled out so an agent can reason about
        // notches/cutaways, not just the envelope.
        if (p.board_poly) |poly| {
            try w.print(",\"points\":{d},\"poly\":[", .{poly.len});
            for (poly, 0..) |pp, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("[{d:.2},{d:.2}]", .{ pp[0], pp[1] });
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }
    // Declared outer-layer copper pours — the textual twin of the PNG's
    // translucent wash, so an agent reading the facts knows a face is a pour
    // (its net's same-face pads connect with no via and draw no airwire).
    var pour_open = false;
    for ([_]optimizer.Side{ .top, .bottom }) |side| {
        const pn = p.rules.pourNetOnSide(side) orelse continue;
        try w.writeAll(if (pour_open) "," else ",\"pours\":[");
        pour_open = true;
        try w.print("{{\"side\":\"{s}\",\"net\":", .{if (side == .top) "top" else "bottom"});
        try pcb_layout_page.writeJsonStr(w, pn);
        try w.writeAll("}");
    }
    if (pour_open) try w.writeAll("]");
    try writeKeepouts(w, alloc, p);
    try writeStackup(w, p);
    try w.writeAll("}");
    const b = p.breakdown;
    try w.print(",\"score\":{{\"objective\":{d:.1},\"hpwl\":{d:.1},\"loop_nh\":{d:.1}}}", .{ b.objective, b.hpwl, b.loop_nh });
    // `?cropnet=` zoom-lens window (world mm): the named nets' pad + copper bbox
    // + margin — the numeric twin of the PNG viewport (absent → whole board).
    if (an.crop_bbox) |cb| {
        try w.print(",\"crop_bbox\":{{\"minx\":{d:.2},\"miny\":{d:.2},\"maxx\":{d:.2},\"maxy\":{d:.2}}}", .{ cb[0], cb[1], cb[2], cb[3] });
    }
    if (spec) |sp| {
        // Parts the force/board solve left staged below the board, and the ones
        // `autofillUnlisted` pulled back out beside their pads.
        try w.writeAll(",\"placement\":{\"unplaced\":[");
        for (sp.unplaced, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try pcb_layout_page.writeJsonStr(w, ref);
        }
        try w.writeAll("],\"auto_filled\":[");
        for (sp.auto_filled, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try pcb_layout_page.writeJsonStr(w, ref);
        }
        try w.writeAll("]}");
    }

    try w.writeAll(",\"parts\":[");
    for (p.parts, 0..) |part, pi| {
        if (pi > 0) try w.writeAll(",");
        try w.writeAll(ref_key);
        try pcb_layout_page.writeJsonStr(w, part.ref_des);
        try w.writeAll(origin_key_head);
        try pcb_layout_page.writeJsonStr(w, originOf(p, pi));
        try w.print(",\"kind\":\"{s}\",\"x\":{d:.2},\"y\":{d:.2},\"rot\":{d:.0},\"w_mm\":{d:.2},\"h_mm\":{d:.2}", .{
            if (part.kind == .hub) "hub" else "passive",
            part.x,
            part.y,
            part.rot,
            part.hw * 2,
            part.hh * 2,
        });
        if (anchor) |ai| {
            if (pi == ai) {
                try w.writeAll(",\"side\":\"anchor\"");
            } else {
                const a = p.parts[ai];
                const cur = sideOf(part.x - a.x, part.y - a.y, aabbHalf(a), aabbHalf(part));
                try w.print(",\"side\":\"{s}\",\"gap_mm\":{d:.2}", .{ @tagName(cur), rectGap(a, part) });
                // Side regret: this part's hub pads all live on one package
                // edge, and the part sits on the OPPOSITE side of the anchor.
                // Adjacent sides (right vs bottom-edge pads) are corner cases
                // that are usually fine, so only the unambiguous mismatch
                // surfaces — every connection must cross the whole package.
                if (part.kind == .passive and !unplaced.contains(part.ref_des)) {
                    if (wantSideOf(&net_edge, &pad_net, part)) |want| {
                        if (oppositeSides(want, cur)) {
                            try w.print(",\"want_side\":\"{s}\"", .{@tagName(want)});
                            try wrong_side.append(alloc, part.ref_des);
                        }
                    }
                }
            }
        }
        // Board copper side ("layer", not "side" — that key is already the
        // side-of-anchor direction above). Emitted only for bottom parts.
        if (part.side == .bottom) try w.writeAll(",\"layer\":\"bottom\"");
        if (part.locked) try w.writeAll(",\"locked\":true");
        if (unplaced.contains(part.ref_des)) try w.writeAll(",\"unplaced\":true");
        if (auto_filled.contains(part.ref_des)) try w.writeAll(",\"auto_filled\":true");
        try writePartNets(w, alloc, &pad_net, part);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try w.writeAll(",\"loops\":[");
    for (p.loops, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        const cap = p.parts[L.cap];
        const hub = p.parts[L.hub];
        const cw = world(cap, L.cap_pwr.x, L.cap_pwr.y);
        const hw_ = world(hub, L.hub_pwr_pin.x, L.hub_pwr_pin.y);
        try w.writeAll("{\"cap\":");
        try pcb_layout_page.writeJsonStr(w, cap.ref_des);
        try w.writeAll(origin_key_head);
        try pcb_layout_page.writeJsonStr(w, originOf(p, L.cap));
        try w.writeAll(",\"hub\":");
        try pcb_layout_page.writeJsonStr(w, hub.ref_des);
        try writeLoopBinding(w, L);
        if (netAtLocal(&pad_net, cap, L.cap_pwr.x, L.cap_pwr.y)) |net| {
            try w.writeAll(",\"net\":");
            try pcb_layout_page.writeJsonStr(w, net);
        }
        try w.print(",\"leg_mm\":{d:.2},\"nh\":{d:.2},\"side\":\"{s}\"}}", .{
            std.math.hypot(cw[0] - hw_[0], cw[1] - hw_[1]),
            optimizer.loopNh(p.parts, L),
            @tagName(sideOf(cap.x - hub.x, cap.y - hub.y, aabbHalf(hub), aabbHalf(cap))),
        });
    }
    try w.writeAll("]");

    try writeNearBindings(w, alloc, p);
    try writeHubPads(w, alloc, p, &pad_net);
    try writePadsJson(w, alloc, p, an.pads);

    // Module-policy facts (Phase 0) + layout gates (Phase 1) over the solved
    // placement (`an.policy` computed once by the caller, shared with the
    // progress ladder's plan resolution), surfaced here to match the PNG.
    const findings = try layout_lint.lint(alloc, p, an.policy);
    defer layout_lint.freeFindings(alloc, findings);
    try writeModulePolicy(w, p, an.policy);
    try writeImpedance(w, alloc, p);
    const route_tally = try writeLint(w, alloc, p, spec, wrong_side.items, findings, routed, .{
        .warns = planWarns(an.progress),
        .escapes_assigned = an.escapes_assigned,
        .port_nets = an.port_nets,
        .layer_audit = an.layer_audit,
    });
    try writeRoutabilityBlock(w, route_tally, optimizer.placementDiag().routability);

    if (routed) |r| try writeRoutedJson(w, r);
    try writeProgressBlock(w, an.progress);
    try w.writeAll("}");
}

/// Emit `,"stackup":{…}` inside the `board` block — which copper layer pours
/// which net, so a reader never has to infer why a net draws no airwire. A
/// design with a `(stackup …)` form reports its own declared `(plane …)`
/// entries (`"declared":true`); a design with NO form reports the implicit
/// model's assumption (`implicit_plane`: an inner ground plane plus, when the
/// block has a dominant supply rail, an inner rail plane). Both are the exact
/// assignment the router stitches against and the Gerber pours — the whole
/// point of reporting it is that the assumption stops being silent.
/// The board's AUTHORED keepout regions, in world millimetres like `outline`.
/// The perimeter band is derived from geometry already in this document; these
/// rectangles are not derivable from anything else here, so an agent reading
/// the facts would otherwise have no way to know a piece of the board is
/// reserved. Absent entirely when the board declares none.
fn writeKeepouts(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) DescribeError!void {
    const regions = try optimizer.boardKeepoutRegions(alloc, p);
    if (regions.len == 0) return;
    try w.writeAll(",\"keepouts\":[");
    for (regions, 0..) |region, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try pcb_layout_page.writeJsonStr(w, region.spec.name);
        try w.print(",\"side\":\"{s}\",\"rect\":{{\"minx\":{d:.2},\"miny\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}}},\"blocks\":[", .{
            @tagName(region.spec.side),
            region.rect.minx,
            region.rect.miny,
            region.rect.w,
            region.rect.h,
        });
        try pcb_keepout_json.writeBlockFamilies(w, region.spec.blocks);
        try w.writeAll("],\"allow_nets\":[");
        for (region.spec.allow_nets, 0..) |net, ni| {
            if (ni > 0) try w.writeAll(",");
            try pcb_layout_page.writeJsonStr(w, net);
        }
        try w.writeAll("],\"reason\":");
        try pcb_layout_page.writeJsonStr(w, region.spec.reason);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

fn writeStackup(w: *std.Io.Writer, p: optimizer.Placement) DescribeError!void {
    const rules = p.rules;
    const stack = rules.layerStack();
    const implicit = !stack.declared;
    const layers: u8 = stack.stackCount();
    try w.print(",\"stackup\":{{\"copper_layers\":{d},\"declared\":{s},\"planes\":[", .{
        layers,
        if (implicit) "false" else "true",
    });
    if (implicit) {
        const inner = implicit_plane.innerPlanes(rules);
        const at = [_]u8{ implicit_plane.ground_index, implicit_plane.rail_index };
        for (inner, at, 0..) |plane, index, i| {
            if (i > 0) try w.writeAll(",");
            try writePlaneEntry(w, layers, index, switch (plane) {
                .ground => null,
                .rail => |net| net,
            });
        }
    } else {
        for (rules.planes.declared, 0..) |pl, i| {
            if (i > 0) try w.writeAll(",");
            try writePlaneEntry(w, layers, pl.index, pl.net);
        }
    }
    try w.writeAll("]}");
}

/// One plane row: its 1-based copper stack index, its KiCad layer name, and
/// what it carries. A null `net` is the implicit GROUND plane, which carries
/// every ground-named net rather than one named one — so it reports
/// `"carries":"ground"` instead of a net that would be a lie on a board with
/// GND, AGND and PGND.
fn writePlaneEntry(w: *std.Io.Writer, layers: u8, index: u8, net: ?[]const u8) DescribeError!void {
    var buf: [board_layers.name_buf_len]u8 = undefined;
    const name = board_layers.stackName(board_layers.StackIndex.of(index), layers, &buf);
    try w.print("{{\"index\":{d},\"layer\":\"{s}\",\"carries\":", .{ index, name });
    if (net) |n| {
        try w.writeAll("\"net\",\"net\":");
        try pcb_layout_page.writeJsonStr(w, n);
    } else {
        try w.writeAll("\"ground\"");
    }
    try w.writeAll("}");
}

/// The progress ladder's stale-plan warnings (empty when no report / no plan),
/// mirrored into `lint[]` so a `(pcb-plan …)` naming a vanished ref/net surfaces
/// where agents already read placement problems.
fn planWarns(report: ?progress.Report) []const progress.Item {
    return if (report) |r| r.warnings else &.{};
}

/// Append the `,"progress":{…}` completion-ladder block (omitted when the caller
/// supplied no report, e.g. the hand-built-placement unit tests).
fn writeProgressBlock(w: *std.Io.Writer, report: ?progress.Report) DescribeError!void {
    const r = report orelse return;
    try w.writeAll(",\"progress\":");
    try progress.writeJson(w, r);
}

/// Emit the `,"routed":{…}` facts block: copper totals, net-completion counts,
/// the unrouted-net names, rip-up rounds, and the per-net copper breakdown.
fn writeRoutedJson(w: *std.Io.Writer, r: RoutedSummary) std.Io.Writer.Error!void {
    try w.print(
        ",\"routed\":{{\"trace_mm\":{d:.1},\"tracks\":{d},\"vias\":{d},\"drc\":{d},\"routed\":{d},\"total\":{d},\"unrouted\":[",
        .{ r.trace_mm, r.tracks, r.vias, r.drc, r.routed, r.total },
    );
    for (r.unrouted, 0..) |name_s, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, name_s);
    }
    try w.writeAll("],\"drc_list\":[");
    for (r.drc_list, 0..) |vio, i| {
        if (i > 0) try w.writeAll(",");
        try drc_json.writeViolation(w, vio, r.names);
    }
    try w.writeAll("]");
    try w.print(",\"ripup_rounds\":{d}", .{r.ripup_rounds});
    // Emitted only when the router over-counted: `router_claimed` present at all
    // means its own tally disagreed with the connectivity oracle.
    if (r.router_claimed > r.routed) try w.print(",\"router_claimed\":{d}", .{r.router_claimed});
    // The deterministic accept/reject scalar (route_score.zig), computed from the
    // same routed/total/via/trace/error-DRC numbers this block already reports,
    // plus the two v2 geometry terms the summary's builder measured with the
    // score module's shared helpers — so this number matches what
    // `route_experiment` / the route-review replay report for the same board.
    try w.print(",\"score\":{d:.2},\"score_v\":{d}", .{
        route_score.score(.{
            .routed = r.routed,
            .total = r.total,
            .vias = r.vias,
            .trace_mm = r.trace_mm,
            .drc_errors = r.drc_errors,
            .bends = r.bends,
            .quality_warns = r.quality_warns,
        }),
        route_score.formula_version,
    });
    if (r.smoothed_arcs > 0 or r.sharp_bends > 0)
        try w.print(",\"smoothed_arcs\":{d},\"sharp_bends\":{d}", .{ r.smoothed_arcs, r.sharp_bends });
    try writeRfPortOutcomesJson(w, r);
    try pcb_layout_page.writePerNetJson(w, r.per_net);
    try writeMatchGroupsJson(w, r);
    try writeOpenNetsJson(w, r.open_nets);
    try stuck_json.writeStuckJson(w, r.stuck);
    if (r.grid_overflow) try w.writeAll(",\"grid_overflow\":true");
    try w.writeAll("}");
}

fn writeFinite(w: *std.Io.Writer, value: f64) !void {
    if (std.math.isFinite(value)) try w.print("{d:.6}", .{value}) else try w.writeAll("null");
}

fn writeRfGeometryMetrics(w: *std.Io.Writer, metrics: rf_path_solver.Metrics) !void {
    try w.writeAll(",\"entry\":{\"start_error_deg\":");
    try writeFinite(w, metrics.entry.start_error_deg);
    try w.writeAll(",\"end_error_deg\":");
    try writeFinite(w, metrics.entry.end_error_deg);
    try w.writeAll(",\"start_straight_mm\":");
    try writeFinite(w, metrics.entry.start_straight_mm);
    try w.writeAll(",\"end_straight_mm\":");
    try writeFinite(w, metrics.entry.end_straight_mm);
    try w.writeAll("},\"curvature\":{\"energy\":");
    try writeFinite(w, metrics.curve.energy);
    try w.writeAll(",\"rate_energy\":");
    try writeFinite(w, metrics.curve.rate_energy);
    try w.writeAll(",\"max_abs\":");
    try writeFinite(w, metrics.curve.max_abs);
    try w.writeByte('}');
}

fn writeRfPortOutcomesJson(w: *std.Io.Writer, r: RoutedSummary) !void {
    if (r.rf_port_outcomes.len == 0) return;
    try w.writeAll(",\"rf_port_routes\":[");
    for (r.rf_port_outcomes, 0..) |outcome, oi| {
        if (oi > 0) try w.writeByte(',');
        try w.writeAll("{\"net\":");
        const net_i: usize = if (outcome.net >= 0) @intCast(outcome.net) else r.names.nets.len;
        if (net_i < r.names.nets.len) {
            try pcb_layout_page.writeJsonStr(w, r.names.nets[net_i].name);
        } else {
            try w.print("\"#{d}\"", .{outcome.net});
        }
        try w.print(",\"chosen\":{d},\"feasible\":{},\"success\":{},\"sample_count\":{d},\"emitted_tracks\":{d},\"retained_tracks\":{d}", .{ outcome.chosen, outcome.feasible, outcome.success, outcome.physical.sample_count, outcome.physical.emitted_tracks, outcome.physical.retained_tracks });
        if (outcome.physical.gate_removed) {
            try w.writeAll(",\"gate_removed\":true,\"gate_first_error\":");
            try pcb_layout_page.writeJsonStr(w, outcome.physical.gate_first_error);
        }
        try w.writeAll(",\"length_mm\":");
        try writeFinite(w, outcome.metrics.length_mm);
        try w.writeAll(",\"worst_return_loss_db\":");
        try writeFinite(w, outcome.metrics.electrical.worst_return_loss_db);
        try w.writeAll(",\"objective\":");
        try writeFinite(w, outcome.metrics.objective);
        try w.print(",\"clearance\":{{\"ok\":{}", .{outcome.metrics.clearance.ok});
        if (outcome.metrics.clearance.blocked_at_mm) |blocked| try w.print(",\"blocked_at_mm\":{d:.6}", .{blocked});
        if (outcome.metrics.clearance.blocked_at) |at| try w.print(",\"blocked_at\":[{d:.6},{d:.6}]", .{ at[0], at[1] });
        try w.writeByte('}');
        try writeRfGeometryMetrics(w, outcome.metrics);
        try w.writeAll(",\"trials\":[");
        for (outcome.trials, 0..) |trial, ti| {
            if (ti > 0) try w.writeByte(',');
            try w.print("{{\"radius_ratio\":{d:.3},\"transition_fraction\":{d:.3},\"guide_variant\":{d},\"feasible\":{},\"success\":{},\"length_mm\":", .{ trial.radius_ratio, trial.transition_fraction, trial.guide_variant, trial.feasible, trial.success });
            try writeFinite(w, trial.metrics.length_mm);
            try w.writeAll(",\"worst_return_loss_db\":");
            try writeFinite(w, trial.metrics.electrical.worst_return_loss_db);
            try w.writeAll(",\"objective\":");
            try writeFinite(w, trial.metrics.objective);
            try w.print(",\"clearance_ok\":{}", .{trial.metrics.clearance.ok});
            if (trial.metrics.clearance.blocked_at_mm) |blocked| try w.print(",\"blocked_at_mm\":{d:.6}", .{blocked});
            try writeRfGeometryMetrics(w, trial.metrics);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// Emit `,"match_groups":[…]` — one object per declared `(net-class …
/// (match-group "NAME" (tolerance MM)))` group: its tolerance, the measured
/// max-min spread over the ROUTED members, whether that fits, and every
/// member's own effective routed length + via count.
///
/// This is the number the `length_mismatch` warning is computed from, not a
/// second opinion on it: both come from `drc_match.measure`. Absent entirely
/// when the design declares no group, so the facts of every board in the corpus
/// today are byte-identical.
fn writeMatchGroupsJson(w: *std.Io.Writer, r: RoutedSummary) std.Io.Writer.Error!void {
    if (r.match_groups.len == 0) return;
    try w.writeAll(",\"match_groups\":[");
    for (r.match_groups, 0..) |g, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try pcb_layout_page.writeJsonStr(w, g.group.name);
        try w.print(",\"tolerance_mm\":{d:.3},\"spread_mm\":{d:.3}", .{ g.group.tolerance_mm, g.span.spread_mm });
        try w.print(",\"min_mm\":{d:.3},\"max_mm\":{d:.3}", .{ g.span.min_mm, g.span.max_mm });
        try w.print(",\"members\":{d},\"routed_members\":{d}", .{ g.members.len, g.routed_members });
        try w.print(",\"comparable\":{s},\"within_tolerance\":{s}", .{
            if (g.comparable()) "true" else "false",
            if (g.withinTolerance()) "true" else "false",
        });
        try w.writeAll(",\"nets\":[");
        for (g.members, 0..) |m, j| {
            if (j > 0) try w.writeAll(",");
            try writeMatchMemberJson(w, m, r.names.nets);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

/// One `match_groups[].nets[]` entry: the net's name, its effective routed
/// length (via barrels included), how many barrels that was, and whether it is
/// routed at all.
fn writeMatchMemberJson(
    w: *std.Io.Writer,
    m: match_group.Member,
    nets: []const optimizer.FlatNet,
) std.Io.Writer.Error!void {
    try w.writeAll(net_key);
    try pcb_layout_page.writeJsonStr(w, if (m.net_i < nets.len) nets[m.net_i].name else "");
    try w.print(",\"length_mm\":{d:.3},\"vias\":{d},\"routed\":{s}}}", .{
        m.length_mm,
        m.vias,
        if (m.routed) "true" else "false",
    });
}

/// Emit `,"pads":[…]` — every placed pad's ref, pad name, net, world centre,
/// half-extents, side and thru flag (`?pads=1` / `pads:true`). This is the
/// OBSTACLE SET: without it a caller placing copper can avoid other tracks and
/// vias (both already in the facts) but not foreign PADS, and a bridge drawn
/// between two pads of an IC silently cuts through the pads in between. Off by
/// default — it roughly doubles the payload on a dense board.
fn writePadsJson(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement, want: bool) DescribeError!void {
    if (!want) return;
    // Same `ref|pad → net` resolution the rest of this file (and the PNG) uses.
    var pad_net = std.StringHashMapUnmanaged([]const u8).empty;
    defer pad_net.deinit(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pad_net.put(alloc, key, net.name);
        }
    }
    try w.writeAll(",\"pads\":[");
    var first = true;
    for (p.parts) |part| {
        for (part.pads) |pad| {
            const sh = try pad_shape.worldShape(alloc, part, pad);
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"ref\":");
            try pcb_layout_page.writeJsonStr(w, part.ref_des);
            try w.writeAll(",\"pad\":");
            try pcb_layout_page.writeJsonStr(w, pad.number);
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ part.ref_des, pad.number });
            try w.writeAll(",\"net\":");
            try pcb_layout_page.writeJsonStr(w, pad_net.get(key) orelse "");
            try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"hw\":{d:.3},\"hh\":{d:.3},\"side\":\"{s}\",\"thru\":{s}}}", .{
                (sh.x0 + sh.x1) / 2,
                (sh.y0 + sh.y1) / 2,
                (sh.x1 - sh.x0) / 2,
                (sh.y1 - sh.y0) / 2,
                if (part.side == .bottom) "bottom" else "top",
                if (pad.thru) "true" else "false",
            });
        }
    }
    try w.writeAll("]");
}

/// Emit `,"open_nets":[…]` — per still-open net, every pad with its board
/// coordinate and copper island, plus the shortest pad-to-pad hops that would
/// close it. Omitted entirely when nothing is open, so a finished board's facts
/// stay lean. This is what an agent aims `add_tracks` at.
fn writeOpenNetsJson(w: *std.Io.Writer, open_nets: []const fab_readiness.OpenNet) std.Io.Writer.Error!void {
    if (open_nets.len == 0) return;
    try w.writeAll(",\"open_nets\":[");
    for (open_nets, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try pcb_layout_page.writeJsonStr(w, n.net);
        try w.print(",\"islands\":{d},\"pads\":[", .{n.islands});
        for (n.pads, 0..) |p, pi| {
            if (pi > 0) try w.writeAll(",");
            try writeOpenPadJson(w, p, .with_island);
        }
        try w.writeAll("],\"gaps\":[");
        for (n.gaps, 0..) |gp, gi| {
            if (gi > 0) try w.writeAll(",");
            try w.print("{{\"mm\":{d:.3},\"from\":", .{gp.mm});
            try writeOpenPadJson(w, gp.from, .with_island);
            try w.writeAll(",\"to\":");
            try writeOpenPadJson(w, gp.to, .with_island);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

/// How much of an open-net endpoint a surface reports. Both forms name the same
/// pad in the same board frame `add_tracks` takes; the facts document adds the
/// two DIAGNOSTIC fields — whether the pad is through-hole, and which copper
/// island it currently sits in — that let a caller pick a layer and see which
/// islands a hop would join. `route_experiment`'s reply is deliberately the
/// compact form (documented in docs/webserver-api.md), so the difference is a
/// parameter rather than a second copy of the writer.
pub const OpenPadDetail = enum { compact, with_island };

/// One open-net endpoint: `{ref,pad,x,y,side}`, plus `thru`/`island` at
/// `.with_island`.
pub fn writeOpenPadJson(
    w: *std.Io.Writer,
    p: fab_readiness.OpenPad,
    detail: OpenPadDetail,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"ref\":");
    try pcb_layout_page.writeJsonStr(w, p.ref);
    try w.writeAll(",\"pad\":");
    try pcb_layout_page.writeJsonStr(w, p.pad);
    try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"side\":\"{s}\"", .{
        p.x,
        p.y,
        if (p.side == .bottom) "bottom" else "top",
    });
    if (detail == .with_island) {
        try w.print(",\"thru\":{s},\"island\":{d}", .{
            if (p.thru) "true" else "false",
            p.island,
        });
    }
    try w.writeByte('}');
}

/// Map each net to the single hub package edge its pads sit on; nets whose hub
/// pads straddle edges (or sit at the centre — an exposed pad) map to null.
fn buildNetEdgeMap(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    pad_net: *std.StringHashMapUnmanaged([]const u8),
    out: *std.StringHashMapUnmanaged(?Side),
) std.mem.Allocator.Error!void {
    for (p.parts) |part| {
        if (part.kind != .hub) continue;
        for (part.pads) |pad| {
            const net = netOf(pad_net, part.ref_des, pad.number) orelse continue;
            const e = padEdge(part, pad.x, pad.y);
            if (e == .center) continue;
            const gop = try out.getOrPut(alloc, net);
            if (!gop.found_existing) {
                gop.value_ptr.* = e;
                continue;
            }
            if (gop.value_ptr.*) |prev| {
                if (prev != e) gop.value_ptr.* = null;
            }
        }
    }
}

/// The side `part` "wants" to be on: the single hub edge of its first
/// non-ground net, when the hub pads agree on one. Null = no preference.
fn wantSideOf(
    net_edge: *std.StringHashMapUnmanaged(?Side),
    pad_net: *std.StringHashMapUnmanaged([]const u8),
    part: optimizer.Part,
) ?Side {
    for (part.pads) |pad| {
        const net = netOf(pad_net, part.ref_des, pad.number) orelse continue;
        if (groundish(net)) continue;
        const maybe = net_edge.get(net) orelse continue;
        if (maybe) |e| return e;
    }
    return null;
}

/// True for the two unambiguous mismatches: left↔right, top↔bottom.
fn oppositeSides(a: Side, b: Side) bool {
    return (a == .left and b == .right) or (a == .right and b == .left) or
        (a == .top and b == .bottom) or (a == .bottom and b == .top);
}

/// Ground-family net check (leaf name): GND/AGND/PGND/…/VSS — the return is a
/// plane, so ground pads never define a preferred side.
fn groundish(name: []const u8) bool {
    const leaf = net_name.leaf(name);
    var buf: [32]u8 = undefined;
    if (leaf.len > buf.len) return false;
    const up = std.ascii.upperString(&buf, leaf);
    return std.mem.indexOf(u8, up, "GND") != null or std.mem.eql(u8, up, "VSS");
}

/// Loops flagged "long": worse than twice the median inductance (and over an
/// absolute floor so tiny boards don't lint their best loop).
const long_loop_floor_nh: f64 = 3.0;

/// One lint entry: `{"rule","severity","refs":[…],"msg"}`.
fn lintItem(
    w: *std.Io.Writer,
    first: *bool,
    rule: []const u8,
    severity: []const u8,
    refs: []const []const u8,
    msg: []const u8,
) DescribeError!void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.writeAll("{\"rule\":");
    try pcb_layout_page.writeJsonStr(w, rule);
    try w.writeAll(",\"severity\":");
    try pcb_layout_page.writeJsonStr(w, severity);
    try w.writeAll(",\"refs\":[");
    for (refs, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, r);
    }
    try w.writeAll("],\"msg\":");
    try pcb_layout_page.writeJsonStr(w, msg);
    try w.writeAll("}");
}

/// The controlled-impedance block: for every net class that declared
/// `(impedance OHMS)`, the target, the width finally in force (and whether it
/// was DERIVED from the target or authored), and the per-signal-layer table —
/// on each layer the reference geometry read out of the `(stackup …)` plus
/// either the width that would hit the target there or, for an authored width,
/// what that width actually computes to.
///
/// Emitted only when at least one class declared a target: a board with none
/// (every board in the corpus today) gets no key at all, so the facts JSON is
/// byte-identical to what it was before this block existed.
fn writeImpedance(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) DescribeError!void {
    const stack = p.rules.physical.stack;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var first = true;
    for (p.rules.net) |r| {
        if ((r.rf.impedance.ohms <= 0 and r.rf.impedance.diff_ohms <= 0) or r.class.name.len == 0) continue;
        if ((try seen.getOrPut(alloc, r.class.name)).found_existing) continue;
        if (first) try w.writeAll(",\"impedance\":{\"classes\":[");
        if (!first) try w.writeAll(",");
        first = false;
        try writeImpedanceClass(w, alloc, stack, r, p.rules.design);
    }
    if (first) return;
    try w.print(
        "],\"stackup\":{{\"layers\":{d},\"assumed_buildup\":{}}}}}",
        .{ stack.layers, stack.assumed() },
    );
}

/// One class's row of the impedance table: its target, the width in force, and
/// the per-layer geometry/result table.
fn writeImpedanceClass(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    stack: impedance.Stack,
    r: optimizer.NetRule,
    design: optimizer.DesignRules,
) DescribeError!void {
    try w.writeAll("{\"class\":");
    try pcb_layout_page.writeJsonStr(w, r.class.name);
    const differential = r.rf.impedance.diff_ohms > 0;
    const target = if (differential) r.rf.impedance.diff_ohms else r.rf.impedance.ohms;
    const pair_gap = @max(
        if (r.diff_gap > 0) r.diff_gap else @max(r.clearance, design.clearance),
        @max(r.clearance, design.clearance),
    );
    const coated = impedance.traceIsCoated(r.rf.mask_relief_mm, r.rf.max_freq_hz);
    try w.print(
        ",\"target_ohms\":{d:.2},\"differential\":{},\"target_layer\":{d},\"width_mm\":{d:.4}," ++
            "\"width_derived\":{},\"ground_gap_mm\":{d:.4},\"ground_gap_max_mm\":{d:.4},\"pair_gap_mm\":{d:.4}",
        .{ target, differential, r.rf.impedance.layer, r.width, r.rf.impedance.width_derived, r.rf.impedance.ground_gap_mm, r.rf.impedance.ground_gap_max_mm, if (differential) pair_gap else 0 },
    );
    if (!differential) {
        const via_dia = if (r.via_dia > 0) r.via_dia else design.via_dia;
        const via_drill = if (r.via_drill > 0) r.via_drill else design.via_drill;
        const minimum = @max(r.clearance, design.clearance);
        if (via_antipad.solve(stack, target, via_dia, via_drill, minimum)) |result| {
            try w.print(
                ",\"via_transition\":{{\"model\":\"lumped-lc-estimate\",\"pad_dia_mm\":{d:.4}," ++
                    "\"drill_mm\":{d:.4},\"antipad_dia_mm\":{d:.4},\"clearance_mm\":{d:.4}," ++
                    "\"estimated_ohms\":{d:.2},\"length_mm\":{d:.4},\"er\":{d:.3}," ++
                    "\"inductance_nh\":{d:.4},\"capacitance_pf\":{d:.4},\"clearance_limited\":{}}}",
                .{
                    via_dia,
                    via_drill,
                    result.antipad_dia_mm,
                    (result.antipad_dia_mm - via_dia) / 2.0,
                    result.estimated_ohms,
                    result.length_mm,
                    result.er,
                    result.inductance_nh,
                    result.capacitance_pf,
                    result.clearance_limited,
                },
            );
        } else try w.writeAll(",\"via_transition\":null");
    } else try w.writeAll(",\"via_transition\":null");
    try w.writeAll(",\"layers\":[");
    var layer_buf: [32]u8 = undefined;
    const layers = impedance.signalLayers(stack, &layer_buf);
    for (layers, 0..) |layer, i| {
        const ref = impedance.reference(stack, layer) orelse continue;
        if (i > 0) try w.writeAll(",");
        const kind = if (differential) switch (ref) {
            .stripline => "coupled-stripline",
            .microstrip => "coupled-microstrip",
        } else ref.kindNameWithGroundGap(r.rf.impedance.ground_gap_mm);
        try w.print(
            "{{\"layer\":{d},\"kind\":\"{s}\",\"h_mm\":{d:.4},\"er\":{d:.2},\"foil_mm\":{d:.4}," ++
                "\"coated\":{},\"trapezoidal\":{}",
            .{ layer, kind, ref.heightMm(), ref.er(), stack.foilMm(layer), coated and stack.mask(layer) != null, stack.foil(layer).width_reduction_mm > 0 },
        );
        // The width that hits the target on THIS layer (they differ per layer —
        // that is the whole point of the table), and, when the author supplied
        // a width, what that width actually is on this layer.
        const solved_width: ?f64 = if (differential)
            impedance.resolvedDiffWidthMmOnLayerWithProcess(alloc, stack, layer, target, pair_gap, coated)
        else
            impedance.resolvedWidthMmOnLayerWithProcess(alloc, stack, layer, target, r.rf.impedance.ground_gap_mm, coated);
        if (solved_width) |solved| {
            try w.print(",\"width_for_target_mm\":{d:.4}", .{solved});
        } else try w.writeAll(",\"width_for_target_mm\":null");
        const computed = if (differential)
            impedance.analyzeDiffOnLayer(alloc, stack, layer, r.width, pair_gap, coated)
        else
            impedance.analyzeOnLayer(alloc, stack, layer, r.width, r.rf.impedance.ground_gap_mm, coated);
        if (computed) |result| {
            try w.print(",\"z0_at_width_ohms\":{d:.2},\"effective_er\":{d:.4}", .{ result.z0_ohms, result.er_eff });
        } else try w.writeAll(",\"z0_at_width_ohms\":null,\"effective_er\":null");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// The module-policy facts block (Phase 0): the detected module classes,
/// criticality net classes (only the routing-order-relevant ones, to stay
/// concise), and the inferred passive roles. Pure observation — it lets an
/// agent see how the board was read before trusting the lint below.
fn writeModulePolicy(
    w: *std.Io.Writer,
    p: optimizer.Placement,
    policy: module_policy.ModulePolicy,
) DescribeError!void {
    try w.writeAll(",\"module_policy\":{\"modules\":[");
    for (policy.modules, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"hub\":");
        try pcb_layout_page.writeJsonStr(w, p.parts[m.hub].ref_des);
        try w.writeAll(origin_key_head);
        try pcb_layout_page.writeJsonStr(w, originOf(p, m.hub));
        try w.print(",\"class\":\"{s}\",\"has_inductor\":{}}}", .{ @tagName(m.class), m.has_inductor });
    }
    try w.writeAll("],\"net_classes\":[");
    var first = true;
    for (p.nets, 0..) |net, i| {
        if (i >= policy.net_class.len or !module_policy.isInterestingClass(policy.net_class[i])) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll(net_key);
        try pcb_layout_page.writeJsonStr(w, net.name);
        try w.print(",\"class\":\"{s}\"}}", .{@tagName(policy.net_class[i])});
    }
    try w.writeAll("],\"roles\":[");
    first = true;
    for (p.parts, 0..) |part, i| {
        if (i >= policy.part_role.len) break;
        const r = policy.part_role[i];
        if (r == .other or r == .anchor_ic) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll(ref_key);
        try pcb_layout_page.writeJsonStr(w, part.ref_des);
        try w.writeAll(origin_key_head);
        try pcb_layout_page.writeJsonStr(w, originOf(p, i));
        try w.print(",\"role\":\"{s}\"}}", .{@tagName(r)});
    }
    try w.writeAll("]}");
}

/// Placement lint: machine-checkable rules an agent should fix before trusting
/// the layout. Spec coverage problems are errors; geometric smells are warns.
/// `findings` are the Phase-1 layout gates, appended after the built-in rules.
/// With `?route=1`, nets the router could not fully connect are errors too.
/// Returns the static-routability rollup of the entries it just wrote, so the
/// `routability` block counts exactly what `lint[]` reported.
fn writeLint(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    spec: ?render_pcb_png.SpecStatus,
    wrong_side: []const []const u8,
    findings: []const layout_lint.Finding,
    routed: ?RoutedSummary,
    plan: PlanFacts,
) DescribeError!rough_routability.Score {
    try w.writeAll(",\"lint\":[");
    var first = true;
    const sev_err = "error";
    const sev_warn = "warn";
    if (spec) |sp| {
        if (sp.unplaced.len > 0) {
            try lintItem(w, &first, "unplaced", sev_err, sp.unplaced, "parts still in the staging band below the board; free up room");
        }
    }
    if (routed) |r| {
        if (r.unrouted.len > 0) {
            const msg = "the autorouter could not fully connect these nets; free routing room " ++
                "near their pads or raise them with (net-class … (priority N))";
            try lintItem(w, &first, "unrouted-net", sev_err, r.unrouted, msg);
        }
        if (r.grid_overflow) {
            const msg = "the board exceeds the router's per-layer grid cap, so routing was " ++
                "skipped entirely (empty copper); shrink the board or widen the net-class geometry";
            try lintItem(w, &first, "router-grid-overflow", sev_err, &.{}, msg);
        }
    }
    if (wrong_side.len > 0) {
        try lintItem(w, &first, "wrong-side", sev_warn, wrong_side, "part sits on a different side of the anchor than the hub edge its net's pads are on; moving it shortens the connection");
    }
    // Parts poking past the authored `(board …)` outline. Staged (unplaced)
    // parts sit below the board by design and are already reported above.
    if (p.board_rect) |br| {
        var in_band = std.StringHashMapUnmanaged(void).empty;
        defer in_band.deinit(alloc);
        if (spec) |sp| for (sp.unplaced) |ref| try in_band.put(alloc, ref, {});
        var outside: std.ArrayList([]const u8) = .empty;
        defer outside.deinit(alloc);
        const tol = 0.05;
        for (p.parts) |part| {
            if (in_band.contains(part.ref_des)) continue;
            const half = aabbHalf(part);
            if (partCrossesOutline(br, p.board_poly, part.x, part.y, half, tol)) {
                try outside.append(alloc, part.ref_des);
            }
        }
        if (outside.items.len > 0) {
            const msg = "part courtyard crosses the (board …) outline; grow the board or move the part inside";
            try lintItem(w, &first, "outside-outline", sev_warn, outside.items, msg);
        }
    }
    // Long loops: collect inductances, compare to the median.
    if (p.loops.len >= 4) {
        const nhs = try alloc.alloc(f64, p.loops.len);
        defer alloc.free(nhs);
        for (p.loops, 0..) |L, i| nhs[i] = optimizer.loopNh(p.parts, L);
        const sorted = try alloc.dupe(f64, nhs);
        defer alloc.free(sorted);
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
        const median = sorted[sorted.len / 2];
        var refs: std.ArrayList([]const u8) = .empty;
        defer refs.deinit(alloc);
        for (p.loops, 0..) |L, i| {
            if (nhs[i] > 2 * median and nhs[i] > long_loop_floor_nh) {
                try refs.append(alloc, p.parts[L.cap].ref_des);
            }
        }
        if (refs.items.len > 0) {
            try lintItem(w, &first, "long-loop", sev_warn, refs.items, "decoupling loop inductance is more than twice the board median; tighten the cap to its supply pin");
        }
    }
    // Phase-1 layout gates (decap-far, hot-loop-not-tightest, feedback-near-aggressor).
    for (findings) |f| {
        const sev = switch (f.severity) {
            .err => sev_err,
            .warn => sev_warn,
            .info => "info",
        };
        try lintItem(w, &first, f.rule, sev, f.refs, f.msg);
    }
    // Static routability preflight (placement + rules only, no router): pads
    // that cannot be entered along their own axis, pads with no legal exit, and
    // hub escapes more nets leave through than the corridor there can seat.
    const route_tally = try writeRoutabilityLint(w, &first, alloc, p, plan);
    // Persisted copper naming a layer this board does not have. The copper is
    // KEPT as saved (a stackup edit must not delete a user's tracks), so this
    // is the only place the drift is visible short of the load-time stderr line.
    if (!plan.layer_audit.clean()) {
        const msg = try layout_layers.lintMessage(alloc, plan.layer_audit);
        defer alloc.free(msg);
        try lintItem(w, &first, layout_layers.lint_rule, sev_warn, &.{}, msg);
    }
    // Stale `(pcb-plan …)` names, mirrored from the progress ladder's warnings.
    for (plan.warns) |it| {
        try lintItem(w, &first, it.kind, sev_warn, &.{}, it.message);
    }
    try w.writeAll("]");
    return route_tally;
}

/// The `,"routability":{…}` block: per-gate counts of the static preflight over
/// the SHOWN board, plus what the rough seed's repair pass did when this request
/// solved one (`optimizer.placementDiag()`, the same per-solve threadlocal the
/// staging report reads). Counts, not verdicts — `deficit` is nets no corridor could seat,
/// `stacked` are courtyard pairs sitting on each other.
fn writeRoutabilityBlock(w: *std.Io.Writer, s: rough_routability.Score, r: rough_routability.Repair) DescribeError!void {
    try w.print(
        ",\"routability\":{{\"sealed\":{d},\"corridor_tight\":{d},\"contended\":{d}" ++
            ",\"deficit\":{d},\"port_blocked\":{d}",
        .{ s.sealed, s.corridor, s.contended, s.deficit, s.port_blocked },
    );
    if (r.ran) {
        try w.print(
            ",\"repair\":{{\"moved\":{d},\"sealed_before\":{d},\"deficit_before\":{d}" ++
                ",\"port_blocked_before\":{d},\"stacked_before\":{d},\"stacked_after\":{d}}}",
            .{ r.moved, r.before.sealed, r.before.deficit, r.before.port_blocked, r.stacked_before, r.stacked_after },
        );
    }
    try w.writeAll("}");
}

/// Append the static routability-preflight gates to the open `lint[]` array.
/// Computed here rather than threaded in as another `writeLint` parameter: the
/// pass needs nothing but the placement `writeLint` already holds plus the
/// authored-escape mask, and it runs in microseconds (no router, no raster).
/// See `placement/routability_lint.zig`.
fn writeRoutabilityLint(
    w: *std.Io.Writer,
    first: *bool,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    plan: PlanFacts,
) DescribeError!rough_routability.Score {
    const findings = try routability_lint.preflight(alloc, p, .{
        .escapes_assigned = plan.escapes_assigned,
        .port_nets = plan.port_nets,
    });
    defer routability_lint.freeFindings(alloc, findings);
    for (findings) |f| {
        const sev = if (f.severity == .warn) "warn" else "info";
        // `lint[]` carries only rule/severity/refs/msg, so a gate's paste-ready
        // DSL rides in the message — a suggestion nobody can read here is not a
        // suggestion. It stays a field of its own on `routability_preflight`.
        if (f.suggestion.len == 0) {
            try lintItem(w, first, f.rule, sev, f.refs, f.msg);
            continue;
        }
        const msg = try std.fmt.allocPrint(alloc, "{s} Paste: {s}", .{ f.msg, f.suggestion });
        defer alloc.free(msg);
        try lintItem(w, first, f.rule, sev, f.refs, msg);
    }
    return rough_routability.tally(findings);
}

/// The unique nets on `part`'s pads, in pad order — `"nets":["VIN","GND"]`.
fn writePartNets(w: *std.Io.Writer, alloc: std.mem.Allocator, pad_net: *std.StringHashMapUnmanaged([]const u8), part: optimizer.Part) !void {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);
    try w.writeAll(",\"nets\":[");
    for (part.pads) |pad| {
        const net = netOf(pad_net, part.ref_des, pad.number) orelse continue;
        var dup = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, net)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen.items.len > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, net);
        try seen.append(alloc, net);
    }
    try w.writeAll("]");
}

/// Each hub's net → package-edge map: which edge(s) of the IC a net's pads sit
/// on, and how many. This is what lets an agent reason "the VIN pads are on the
/// left edge, so the input bank belongs left" without reading the footprint.
fn writeHubPads(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement, pad_net: *std.StringHashMapUnmanaged([]const u8)) !void {
    try w.writeAll(",\"hub_pads\":[");
    var first_hub = true;
    for (p.parts, 0..) |part, pi| {
        if (part.kind != .hub) continue;
        if (!first_hub) try w.writeAll(",");
        first_hub = false;
        try w.writeAll(ref_key);
        try pcb_layout_page.writeJsonStr(w, part.ref_des);
        try w.writeAll(origin_key_head);
        try pcb_layout_page.writeJsonStr(w, originOf(p, pi));
        try w.writeAll(",\"nets\":[");

        // Aggregate per net (ordered by first appearance): edge set + pad count.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(alloc);
        var edges: std.ArrayList([5]bool) = .empty;
        defer edges.deinit(alloc);
        var counts: std.ArrayList(usize) = .empty;
        defer counts.deinit(alloc);
        for (part.pads) |pad| {
            const net = netOf(pad_net, part.ref_des, pad.number) orelse continue;
            var idx: ?usize = null;
            for (names.items, 0..) |s, i| {
                if (std.mem.eql(u8, s, net)) {
                    idx = i;
                    break;
                }
            }
            if (idx == null) {
                try names.append(alloc, net);
                try edges.append(alloc, .{ false, false, false, false, false });
                try counts.append(alloc, 0);
                idx = names.items.len - 1;
            }
            const e = padEdge(part, pad.x, pad.y);
            edges.items[idx.?][@backingInt(e)] = true;
            counts.items[idx.?] += 1;
        }
        for (names.items, 0..) |net, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll(net_key);
            try pcb_layout_page.writeJsonStr(w, net);
            try w.writeAll(",\"edges\":[");
            var first_edge = true;
            for (edges.items[i], 0..) |on, ei| {
                if (!on) continue;
                if (!first_edge) try w.writeAll(",");
                first_edge = false;
                try w.print("\"{s}\"", .{@tagName(@as(Side, @fromBackingInt(@intCast(ei))))});
            }
            try w.print("],\"pads\":{d}}}", .{counts.items[i]});
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

// ── Geometry helpers (pure; unit-tested below) ──────────────────────────────

/// World offset of a footprint-local point on `part` (rotation applied).
fn world(part: optimizer.Part, lx: f64, ly: f64) [2]f64 {
    const mlx = if (part.side == .bottom) -lx else lx;
    const a = part.rot * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    return .{ part.x + mlx * c - ly * s, part.y + mlx * s + ly * c };
}

/// World-axis-aligned half-extents of `part`'s rotated courtyard (AABB).
pub fn aabbHalf(part: optimizer.Part) [2]f64 {
    const a = part.rot * std.math.pi / 180.0;
    const c = @abs(@cos(a));
    const s = @abs(@sin(a));
    return .{ part.hw * c + part.hh * s, part.hw * s + part.hh * c };
}

/// Does a part's courtyard AABB (centre cx/cy, half-extents `half`) poke
/// past the board outline? Non-rectangular boards test the AABB's centre and
/// corners against the exact polygon (a corner hanging into a notch is
/// outside even though it's inside the bbox); plain boards keep the cheap
/// rectangle containment.
fn partCrossesOutline(br: optimizer.BoardRect, poly: ?[]const [2]f64, cx: f64, cy: f64, half: [2]f64, tol: f64) bool {
    if (poly) |pl| {
        if (pl.len >= 3) {
            const probes = [_][2]f64{
                .{ cx, cy },
                .{ cx - half[0], cy - half[1] },
                .{ cx + half[0], cy - half[1] },
                .{ cx + half[0], cy + half[1] },
                .{ cx - half[0], cy + half[1] },
            };
            for (probes) |pt| {
                if (outline_mod.signedInset(pl, pt[0], pt[1]) < -tol) return true;
            }
            return false;
        }
    }
    return cx - half[0] < br.minx - tol or cx + half[0] > br.minx + br.w + tol or
        cy - half[1] < br.miny - tol or cy + half[1] > br.miny + br.h + tol;
}

/// Which side of a reference box a point offset (dx,dy) falls on, normalized
/// by the combined half-extents so a wide flat board doesn't read everything
/// as left/right. `center` only when well inside the combined box.
pub fn sideOf(dx: f64, dy: f64, a_half: [2]f64, b_half: [2]f64) Side {
    const nx = dx / @max(a_half[0] + b_half[0], 0.001);
    const ny = dy / @max(a_half[1] + b_half[1], 0.001);
    if (@max(@abs(nx), @abs(ny)) < 0.45) return .center;
    if (@abs(nx) >= @abs(ny)) return if (nx < 0) .left else .right;
    return if (ny < 0) .top else .bottom;
}

/// Edge of `part`'s package a footprint-local pad sits on (world-rotated, so
/// the answer matches what the image shows).
fn padEdge(part: optimizer.Part, px: f64, py: f64) Side {
    const wp = world(part, px, py);
    const half = aabbHalf(part);
    return sideOf(wp[0] - part.x, wp[1] - part.y, .{ 0, 0 }, half);
}

/// Clearance between two parts' world AABBs in mm; 0 = touching/overlapping.
fn rectGap(a: optimizer.Part, b: optimizer.Part) f64 {
    const ah = aabbHalf(a);
    const bh = aabbHalf(b);
    const gx = @max(0.0, @abs(b.x - a.x) - (ah[0] + bh[0]));
    const gy = @max(0.0, @abs(b.y - a.y) - (ah[1] + bh[1]));
    return std.math.hypot(gx, gy);
}

/// Index of the anchor part facts are oriented around: the most-connected hub
/// (`optimizer.pickAnchorHub` — same pick the rough ring uses, so the facts'
/// side attribution matches the placement's own anchor), else null.
pub fn anchorIndex(parts: []const optimizer.Part, nets: []const optimizer.FlatNet) ?usize {
    return optimizer.pickAnchorHub(parts, nets);
}

/// The part's stable module-local origin name (what a `(placement …)` spec
/// calls it), falling back to the ref-des when none was recorded.
pub fn originOf(p: optimizer.Placement, pi: usize) []const u8 {
    if (pi < p.instances.len and p.instances[pi].origin_key.len > 0) return p.instances[pi].origin_key;
    return p.parts[pi].ref_des;
}

fn netOf(pad_net: *std.StringHashMapUnmanaged([]const u8), ref: []const u8, pad: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ ref, pad }) catch return null;
    return pad_net.get(key);
}

/// Net on the pad of `part` nearest the footprint-local point (lx,ly) — loops
/// carry pad rectangles, not pad numbers, so recover the net by proximity.
/// Emit one loop's authored-vs-defaulted binding marker. `explicit_pin` is the
/// hub pad a `(decouples "IC" PIN)` binding (or a `(decouple … per-pin …)`
/// shorthand) NAMED and that resolved to a real pad; "" means the solver
/// defaulted to the lowest-numbered supply pad. A reader has to be able to tell
/// a declared placement target from the solver's guess, so `"authored"` is
/// always emitted and `"pin"` only when there is a declared pad to name.
fn writeLoopBinding(w: *std.Io.Writer, lp: optimizer.Loop) std.Io.Writer.Error!void {
    if (lp.explicit_pin.len == 0) return w.writeAll(",\"authored\":false");
    try w.writeAll(",\"authored\":true,\"pin\":");
    try pcb_layout_page.writeJsonStr(w, lp.explicit_pin);
}

/// The `"bindings"` array: one record per authored `(near "REF" PIN)`, resolved
/// or not. Kept separate from `"loops"` rather than folded into it, because a
/// near binding is NOT a decoupling loop — it has no ground return, no leg
/// inductance, and nothing on it belongs in the nH column a reader scans loops
/// for. An unresolved binding is still reported (`"resolved":false` plus the
/// cause), since "the declaration did nothing" is exactly what a reader needs to
/// know and is invisible from the poses alone.
fn writeNearBindings(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const near = try near_bind.resolve(scratch.allocator(), p.instances, p.nets);

    try w.writeAll(",\"bindings\":[");
    var n: usize = 0;
    for (near.pairs) |np| {
        defer n += 1;
        if (n > 0) try w.writeAll(",");
        const own = optimizer.padLocal(&p.parts[np.part], np.own_pin);
        const tgt = optimizer.padLocal(&p.parts[np.target], np.target_pin);
        const a = world(p.parts[np.part], own.x, own.y);
        const b = world(p.parts[np.target], tgt.x, tgt.y);
        try w.writeAll("{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, p.parts[np.part].ref_des);
        try w.writeAll(",\"own_pad\":");
        try pcb_layout_page.writeJsonStr(w, np.own_pin);
        try w.writeAll(",\"target_ref\":");
        try pcb_layout_page.writeJsonStr(w, p.parts[np.target].ref_des);
        try w.writeAll(",\"target_pad\":");
        try pcb_layout_page.writeJsonStr(w, np.target_pin);
        try w.writeAll(",\"net\":");
        try pcb_layout_page.writeJsonStr(w, np.net);
        try w.print(",\"gap_mm\":{d:.2},\"resolved\":true}}", .{std.math.hypot(a[0] - b[0], a[1] - b[1])});
    }
    for (near.unresolved) |u| {
        defer n += 1;
        if (n > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, p.parts[u.part].ref_des);
        try w.writeAll(",\"target_ref\":");
        try pcb_layout_page.writeJsonStr(w, p.instances[u.part].bind.near.ref);
        try w.writeAll(",\"target_pad\":");
        try pcb_layout_page.writeJsonStr(w, p.instances[u.part].bind.near.pin);
        try w.writeAll(",\"resolved\":false,\"why\":");
        try pcb_layout_page.writeJsonStr(w, @tagName(u.why));
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// The net on `part` under the footprint-local offset (lx, ly) — the pad
/// nearest that point, resolved through the pad->net map. Shares the renderer's
/// nearest-pad search (`render_pcb_png.nearestPadNumber`); all that differs is
/// that a padless part has no net here rather than an empty pad number.
fn netAtLocal(pad_net: *std.StringHashMapUnmanaged([]const u8), part: optimizer.Part, lx: f64, ly: f64) ?[]const u8 {
    const number = render_pcb_png.nearestPadNumber(part.pads, lx, ly) orelse return null;
    return netOf(pad_net, part.ref_des, number);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "sideOf classifies quadrants with top = -y" {
    const half = [2]f64{ 1, 1 };
    try std.testing.expectEqual(Side.left, sideOf(-3, 0.2, half, half));
    try std.testing.expectEqual(Side.right, sideOf(3, -0.2, half, half));
    try std.testing.expectEqual(Side.top, sideOf(0.2, -3, half, half));
    try std.testing.expectEqual(Side.bottom, sideOf(-0.2, 3, half, half));
    try std.testing.expectEqual(Side.center, sideOf(0.1, 0.1, half, half));
}

test "aabbHalf swaps extents at quarter rotation and rectGap touches at zero" {
    const part = optimizer.Part{ .ref_des = "C1", .kind = .passive, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .rot = 90 };
    const half = aabbHalf(part);
    try std.testing.expectApproxEqAbs(@as(f64, 1), half[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), half[1], 1e-9);
    const a = optimizer.Part{ .ref_des = "A", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0 };
    const b = optimizer.Part{ .ref_des = "B", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2, .y = 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0), rectGap(a, b), 1e-9);
    const c = optimizer.Part{ .ref_des = "C", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2.5, .y = 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), rectGap(a, c), 1e-9);
}

test "writeDescribeJson emits parts with sides, nets and hub pad map" {
    const export_kicad = @import("../export_kicad.zig");
    const geometry = @import("../placement/geometry.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C9", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = false, .x = -4, .y = 0 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C9", .component = "cap", .value = "1uF", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_IN" },
    };
    const vin_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C9", .pin = "1" } };
    const gnd_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C9", .pin = "2" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VIN", .pins = &vin_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -6,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    var policy = try module_policy.analyze(alloc, p);
    defer policy.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeDescribeJson(&aw.writer, alloc, p, .{ .unplaced = &.{} }, null, "t", "Test", .{ .policy = policy });
    const out = aw.written();
    // The cap is left of the anchor IC, on VIN+GND, and the hub's VIN pad
    // resolves to the left package edge.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"C9\",\"origin\":\"C_IN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"side\":\"left\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"nets\":[\"VIN\",\"GND\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"VIN\",\"edges\":[\"left\"],\"pads\":1") != null);
    // Module-policy facts: VIN reads as an input rail and C9 as the input cap.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"module_policy\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"VIN\",\"class\":\"input_rail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"C9\",\"origin\":\"C_IN\",\"role\":\"input_cap\"") != null);
}

// spec: Web Server - the pcb-describe board facts list every authored keepout region in world millimetres with its side, blocked families, allowed nets and reason
test "pcb-describe names the board's authored keepout regions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const specs = [_]env.BoardKeepoutSpec{.{
        .name = "heatsink plate",
        .rect = .{ .x = 5, .y = 0, .w = 5, .h = 10 },
        .side = .bottom,
        .blocks = .{ .components = true, .tracks = true, .vias = true },
        .allow_nets = &.{"GND"},
        .reason = "bottom-side conduction plate",
    }};
    const p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        // Board origin at world (100, 200): the emitted rectangle must be the
        // WORLD one, not the board-local one the author wrote.
        .board_rect = .{ .minx = 100, .miny = 200, .w = 10, .h = 10 },
        .rules = .{ .board_keepouts = &specs },
    };
    var policy = try module_policy.analyze(alloc, p);
    defer policy.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeDescribeJson(&aw.writer, alloc, p, .{ .unplaced = &.{} }, null, "t", "Test", .{ .policy = policy });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"keepouts\":[{\"name\":\"heatsink plate\",\"side\":\"bottom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rect\":{\"minx\":105.00,\"miny\":200.00,\"w\":5.00,\"h\":10.00}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"blocks\":[\"components\",\"tracks\",\"vias\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"allow_nets\":[\"GND\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reason\":\"bottom-side conduction plate\"") != null);
}

// spec: Web Server - the pcb-describe loop facts mark each decoupling target authored or defaulted and name the declared hub pad
test "pcb-describe loop facts separate an authored decoupling target from a defaulted one" {
    const export_kicad = @import("../export_kicad.zig");
    const geometry = @import("../placement/geometry.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // U1 carries TWO supply pads on VDD (5, 6), so a cap's target pad is a real
    // choice: C1 declared `(decouples "U1" 5)` and C2 declared nothing.
    var hub_pads = [_]geometry.Pad{
        .{ .number = "5", .x = -1.8, .y = -0.6, .w = 0.6, .h = 0.6 },
        .{ .number = "6", .x = -1.8, .y = 0.6, .w = 0.6, .h = 0.6 },
        .{ .number = "9", .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = false, .x = -4, .y = -0.6 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = false, .x = -4, .y = 0.6 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_BOUND" },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_FREE" },
    };
    const vdd_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "5" }, .{ .ref_des = "U1", .pin = "6" },
        .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" },
    };
    const gnd_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "9" },
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const hub_pwr = [_]optimizer.PadRect{
        .{ .x = -1.8, .y = -0.6, .w = 0.6, .h = 0.6 },
        .{ .x = -1.8, .y = 0.6, .w = 0.6, .h = 0.6 },
    };
    const hub_gnd = [_]optimizer.PadRect{.{ .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 }};
    const cap_pwr = optimizer.PadRect{ .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 };
    const cap_gnd = optimizer.PadRect{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 };
    const loops = [_]optimizer.Loop{
        .{
            .cap = 1,
            .hub = 0,
            .cap_pwr = cap_pwr,
            .cap_gnd = cap_gnd,
            .hub_pwr = &hub_pwr,
            .hub_gnd = &hub_gnd,
            .hub_pwr_pin = hub_pwr[0],
            .hub_gnd_pin = hub_gnd[0],
            .explicit_pin = "5",
        },
        .{
            .cap = 2,
            .hub = 0,
            .cap_pwr = cap_pwr,
            .cap_gnd = cap_gnd,
            .hub_pwr = &hub_pwr,
            .hub_gnd = &hub_gnd,
            .hub_pwr_pin = hub_pwr[0],
            .hub_gnd_pin = hub_gnd[0],
        },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &loops,
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 2 },
        .minx = -6,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    var policy = try module_policy.analyze(alloc, p);
    defer policy.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeDescribeJson(&aw.writer, alloc, p, .{ .unplaced = &.{} }, null, "t", "Test", .{ .policy = policy });
    const out = aw.written();
    // The bound cap names the pad the design declared; the unbound one says the
    // target was defaulted and emits no `pin` at all (`net` follows directly).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cap\":\"C1\",\"origin\":\"C_BOUND\",\"hub\":\"U1\",\"authored\":true,\"pin\":\"5\",\"net\":\"VDD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cap\":\"C2\",\"origin\":\"C_FREE\",\"hub\":\"U1\",\"authored\":false,\"net\":\"VDD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cap\":\"C2\",\"origin\":\"C_FREE\",\"hub\":\"U1\",\"authored\":true") == null);
}

// spec: Web Server - the pcb-describe bindings array names each (near …) adjacency with its gap and reports an unresolved one with its cause
test "pcb-describe bindings report a resolved adjacency and an unresolved one" {
    const export_kicad = @import("../export_kicad.zig");
    const geometry = @import("../placement/geometry.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var hub_pads = [_]geometry.Pad{.{ .number = "14", .x = -1.5, .y = 0, .w = 0.6, .h = 0.6 }};
    var res_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
    };
    // R_OK's pad 1 sits at x = -4.5, the hub pad at x = -1.5: a 3.00 mm gap.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U3", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R_OK", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &res_pads, .fallback = false, .x = -4, .y = 0 },
        .{ .ref_des = "R_BAD", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &res_pads, .fallback = false, .x = -4, .y = 3 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U3", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U3" },
        .{
            .ref_des = "R_OK",
            .component = "res-0402",
            .value = "1k",
            .footprint = "",
            .properties = &.{},
            .uuid = "",
            .origin_key = "R_OK",
            .bind = .{ .near = .{ .ref = "U3", .pin = "14" } },
        },
        .{
            .ref_des = "R_BAD",
            .component = "res-0402",
            .value = "1k",
            .footprint = "",
            .properties = &.{},
            .uuid = "",
            .origin_key = "R_BAD",
            .bind = .{ .near = .{ .ref = "U9", .pin = "14" } },
        },
    };
    const sig = [_]export_kicad.FlatPin{
        .{ .ref_des = "U3", .pin = "14" },
        .{ .ref_des = "R_OK", .pin = "1" },
        .{ .ref_des = "R_BAD", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GPIO10", .pins = &sig }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -6,
        .miny = -2,
        .maxx = 2,
        .maxy = 4,
        .generated = true,
    };
    var policy = try module_policy.analyze(alloc, p);
    defer policy.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeDescribeJson(&aw.writer, alloc, p, .{ .unplaced = &.{} }, null, "t", "Test", .{ .policy = policy });
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"R_OK\",\"own_pad\":\"1\",\"target_ref\":\"U3\"," ++
        "\"target_pad\":\"14\",\"net\":\"GPIO10\",\"gap_mm\":3.00,\"resolved\":true") != null);
    // The unresolved one is still reported, and names WHY — the fix differs per
    // cause, and "the declaration did nothing" is invisible from the poses.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"R_BAD\",\"target_ref\":\"U9\"," ++
        "\"target_pad\":\"14\",\"resolved\":false,\"why\":\"no_such_ref\"") != null);
}

// spec: Web Server - the pcb-describe JSON carries a progress block and mirrors stale-plan warnings into lint
test "writeDescribeJson emits the progress block and mirrors plan warnings into lint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const warns = [_]plan_resolve.Warning{
        .{ .id = "abcd", .kind = "plan-unknown-name", .message = "unknown ref NOPE", .wave = "core", .name = "NOPE" },
    };
    // An ERC error keeps the ladder on the schematic rung; the plan carries a
    // stale-name warning that must surface in lint[].
    const report = try progress.compute(alloc, .{
        .erc_error_count = 1,
        .sub_circuits = &.{},
        .has_outline = true,
        .placement = p,
        .net_conn = &.{},
        .fab = null,
        .from_saved_layout = true,
        .plan = .{ .warnings = &warns },
    });
    var policy = try module_policy.analyze(alloc, p);
    defer policy.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeDescribeJson(&aw.writer, alloc, p, null, null, "t", "Test", .{ .policy = policy, .progress = report });
    const out = aw.written();
    // The six-rung ladder is present and sits on the schematic rung.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"progress\":{\"current\":\"schematic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"schematic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"fab_ready\"") != null);
    // The stale-plan warning is mirrored into lint[] as a warn-severity entry.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rule\":\"plan-unknown-name\",\"severity\":\"warn\"") != null);
}

test "buildNetEdgeMap maps a net to its non-centre hub pad edge" {
    // `if (e == .center) continue;` skips only centre (exposed-pad) pads; a
    // `==`->`!=` flip skips every EDGE pad instead, so the net→edge map comes
    // back empty and the VIN pad's left edge is lost.
    const geometry = @import("../placement/geometry.zig");
    const alloc = std.testing.allocator;
    var pads = [_]geometry.Pad{.{ .number = "1", .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
    };
    var pad_net = std.StringHashMapUnmanaged([]const u8).empty;
    defer pad_net.deinit(alloc);
    try pad_net.put(alloc, "U1|1", "VIN");
    var out = std.StringHashMapUnmanaged(?Side).empty;
    defer out.deinit(alloc);
    try buildNetEdgeMap(alloc, p, &pad_net, &out);
    const e = out.get("VIN") orelse return error.TestNetMissing;
    try std.testing.expectEqual(Side.left, e.?);
}

// spec: Web Server - the routed facts serialize a stuck block with per-net failure mode, blockers, and ranked DSL remedies
test "writeRoutedJson serializes the stuck-net diagnostics block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const blockers = [_]route_diagnose.Blocker{
        .{ .net = "V_6VA", .layer = "B.Cu", .x = 41.2, .y = 18.9, .share = 0.44, .rippable = true },
    };
    const remedies = [_]route_diagnose.Remedy{
        .{ .kind = "raise_priority", .dsl = "(net-class \"SPI-pri\" (priority 4) (nets \"SPI_SCK\"))", .rationale = "route first", .confidence = "high", .target = .dsl },
        .{ .kind = "router_fix", .dsl = "", .rationale = "sub-grid channel; CDT needed", .confidence = "high", .target = .code },
    };
    const stuck = [_]route_diagnose.Diagnosis{.{
        .net = "SPI_SCK",
        .failure_mode = "grid_quantization",
        .why = "open but narrow",
        .blockers = &blockers,
        .remedies = &remedies,
        .drc_related = &.{},
    }};
    const summary = RoutedSummary{ .trace_mm = 0, .tracks = 0, .vias = 0, .drc = 0, .stuck = &stuck };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeRoutedJson(&aw.writer, summary);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stuck\":[{\"net\":\"SPI_SCK\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"failure_mode\":\"grid_quantization\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"V_6VA\",\"layer\":\"B.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rippable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"target\":\"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"target\":\"dsl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(priority 4)") != null);
}

// spec: Web Server - the pcb-describe JSON carries a match_groups block with each member's routed length, and omits it when no group is declared
test "writeRoutedJson emits the match_groups block only for a design declaring one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "A0", .pins = &.{} },
        .{ .name = "A1", .pins = &.{} },
        .{ .name = "A2", .pins = &.{} },
    };
    const members = [_]match_group.Member{
        .{ .net_i = 0, .length_mm = 20.0, .vias = 0, .routed = true },
        .{ .net_i = 1, .length_mm = 22.5, .vias = 2, .routed = true },
        .{ .net_i = 2, .length_mm = 0, .vias = 0, .routed = false },
    };
    const reps = [_]match_group.Report{match_group.summarize(
        .{ .name = "ddr-addr", .tolerance_mm = 0.5, .members = &.{ 0, 1, 2 } },
        &members,
    )};
    const summary = RoutedSummary{
        .trace_mm = 0,
        .tracks = 0,
        .vias = 0,
        .drc = 0,
        .match_groups = &reps,
        .names = .{ .nets = &nets },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeRoutedJson(&aw.writer, summary);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"match_groups\":[{\"name\":\"ddr-addr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tolerance_mm\":0.500,\"spread_mm\":2.500") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"members\":3,\"routed_members\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"comparable\":true,\"within_tolerance\":false") != null);
    // Every member is listed by NAME with its own length — the number the
    // length_mismatch warning is computed from, not a second opinion on it.
    try std.testing.expect(std.mem.indexOf(u8, out, "{\"net\":\"A1\",\"length_mm\":22.500,\"vias\":2,\"routed\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "{\"net\":\"A2\",\"length_mm\":0.000,\"vias\":0,\"routed\":false}") != null);

    // A board declaring no group emits no block at all, so its facts are
    // byte-identical to what they were before length matching existed.
    var bare: std.Io.Writer.Allocating = .init(alloc);
    try writeRoutedJson(&bare.writer, .{ .trace_mm = 0, .tracks = 0, .vias = 0, .drc = 0 });
    try std.testing.expect(std.mem.indexOf(u8, bare.written(), "match_groups") == null);
}

// spec: Web Server - the routed facts block carries the deterministic routing score and its formula version
test "writeRoutedJson emits the routing score from its own routed fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // 3/4 routed, 2 vias, 20 mm copper, 1 error DRC. This summary leaves the
    // measured v2 geometry terms (`bends`, `quality_warns`) at their zero
    // defaults, so:
    //   1000·0.75 − 0.5·2 − 0.1·20 − 50·1 = 750 − 1 − 2 − 50 = 697.
    const summary = RoutedSummary{
        .trace_mm = 20,
        .tracks = 3,
        .vias = 2,
        .drc = 3,
        .drc_errors = 1,
        .routed = 3,
        .total = 4,
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeRoutedJson(&aw.writer, summary);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"score\":697.00,\"score_v\":2") != null);
}

// spec: placement/rf-port-frame-routing - every attempted RF net exposes its chosen trial, all trial scores, feasibility, entry error, curvature energy, and worst return loss in pcb-describe
test "writeRoutedJson exposes complete RF port-frame trial histories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const nets = [_]optimizer.FlatNet{.{ .name = "RF_OUT", .pins = &.{} }};
    const trials = [_]@import("../placement/rf_path_solver.zig").Trial{
        .{
            .radius_ratio = 3,
            .transition_fraction = 0.35,
            .feasible = false,
            .success = false,
            .metrics = .{ .length_mm = 7.5, .objective = 8.25 },
        },
        .{
            .radius_ratio = 5,
            .transition_fraction = 0.2,
            .feasible = true,
            .success = true,
            .metrics = .{
                .length_mm = 8.1,
                .curve = .{ .energy = 0.41, .rate_energy = 0.19, .max_abs = 0.9 },
                .entry = .{ .start_error_deg = 0.3, .end_error_deg = 0.4, .start_straight_mm = 0.2, .end_straight_mm = 0.2 },
                .electrical = .{ .worst_return_loss_db = 24.5 },
                .clearance = .{ .ok = true },
                .objective = 0.73,
            },
        },
    };
    const outcomes = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 1,
        .feasible = true,
        .success = true,
        .metrics = trials[1].metrics,
        .trials = &trials,
        .physical = .{ .sample_count = 20, .emitted_tracks = 19, .retained_tracks = 19 },
    }};
    const summary = RoutedSummary{
        .trace_mm = 8.1,
        .tracks = 1,
        .vias = 0,
        .drc = 0,
        .names = .{ .nets = &nets },
        .rf_port_outcomes = &outcomes,
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeRoutedJson(&aw.writer, summary);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rf_port_routes\":[{\"net\":\"RF_OUT\",\"chosen\":1,\"feasible\":true,\"success\":true,\"sample_count\":20,\"emitted_tracks\":19,\"retained_tracks\":19") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"worst_return_loss_db\":24.500000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"clearance\":{\"ok\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start_error_deg\":0.300000,\"end_error_deg\":0.400000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"curvature\":{\"energy\":0.410000,\"rate_energy\":0.190000") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\"radius_ratio\":"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"radius_ratio\":3.000,\"transition_fraction\":0.350,\"guide_variant\":0,\"feasible\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"radius_ratio\":5.000,\"transition_fraction\":0.200,\"guide_variant\":0,\"feasible\":true,\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"clearance_ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\"curvature\":{\"energy\":"));
}

// spec: Web Server - The describe facts emit the full pad obstacle table only when pads are requested
test "writePadsJson emits every pad with net and geometry, and nothing when unasked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const export_kicad = @import("../export_kicad.zig");
    const geometry = @import("../placement/geometry.zig");

    var u_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.6, .h = 0.4 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.4 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 5, .y = 5 },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "2" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "VIN", .pins = &pins }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
    };

    // Off by default: the block must not appear at all (it roughly doubles the
    // payload on a dense board).
    var off: std.Io.Writer.Allocating = .init(alloc);
    try writePadsJson(&off.writer, alloc, p, false);
    try std.testing.expectEqual(@as(usize, 0), off.written().len);

    var on: std.Io.Writer.Allocating = .init(alloc);
    try writePadsJson(&on.writer, alloc, p, true);
    const out = on.written();
    // Both pads present; the netted one carries its net, the unconnected one "".
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"U1\",\"pad\":\"2\",\"net\":\"VIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"U1\",\"pad\":\"1\",\"net\":\"\"") != null);
    // World centre = part origin + pad offset, with half-extents for clearance.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"x\":5.500,\"y\":5.000,\"hw\":0.300,\"hh\":0.200") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"side\":\"top\",\"thru\":false") != null);
}

// spec: Web Server - describe reports net-completion from the connectivity oracle, so neither a restored board's empty unrouted list nor a fresh route's optimistic count survives
test "the connectivity tally overrides both the zeroed restored counters and an optimistic fresh route" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const export_kicad = @import("../export_kicad.zig");
    const geometry = @import("../placement/geometry.zig");

    // Two 2-pad nets on a plane-free 2-layer board; only WIRED gets copper.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 5 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const wired_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const bare_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "WIRED", .pins = &wired_pins },
        .{ .name = "BARE", .pins = &bare_pins },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 7,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 11 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    // Exactly what `restoreRoutes` hands back for persisted copper: real
    // geometry, but routed/total counters left at ZERO. Reporting those raw is
    // what made a half-routed saved board read as "0/0, nothing unrouted".
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const restored = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 0, .total = 0 };
    try std.testing.expectEqual(@as(usize, 0), restored.routed);

    // No pour zones in this scenario — the two nets are joined by tracks alone.
    const conn = try connectivityTally(alloc, placement, restored, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 2), conn.total);
    try std.testing.expectEqual(@as(usize, 1), conn.routed);
    try std.testing.expectEqual(@as(usize, 1), conn.open.len);
    try std.testing.expectEqualStrings("BARE", conn.open[0]);

    // The same copper as a FRESH route, where the router claims it finished
    // both nets (its search for BARE succeeded; the copper never landed). The
    // oracle has to win, or the payload reports 2/2 beside an open BARE.
    const fresh = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };
    const fresh_conn = try connectivityTally(alloc, placement, fresh, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 1), fresh_conn.routed);
    try std.testing.expectEqualStrings("BARE", fresh_conn.open[0]);

    // A saved RF taper may persist only its sampled path proof. Describe must
    // feed that proof to the same oracle as DRC instead of falling back to an
    // empty compact-track list and contradicting the net-open marker.
    const RfOutcome = @typeInfo(@FieldType(router.RouteResult, "rf_port_outcomes")).pointer.child;
    const RfPhysical = @FieldType(RfOutcome, "physical");
    const RfSample = @typeInfo(@FieldType(RfPhysical, "samples")).pointer.child;
    const rf_samples = [_]RfSample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 10, 0 }, .s_mm = 10, .curvature = 0, .width_mm = 0.2 },
    };
    const rf_paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = rf_samples.len, .samples = &rf_samples },
    }};
    const sampled = router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .rf_port_outcomes = &rf_paths,
        .routed = 0,
        .total = 0,
    };
    const sampled_conn = try connectivityTally(alloc, placement, sampled, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 1), sampled_conn.routed);
    try std.testing.expectEqualStrings("BARE", sampled_conn.open[0]);
}

test "the facts' drc_errors term counts only fab-blocking geometry" {
    const vios = [_]drc.Violation{
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .pad_pad, .severity = .err },
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .courtyard, .severity = .warn },
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .via_pad, .severity = .err },
        // Connectivity, not geometry: the same payload reports it as
        // `routed`/`total`/`open_nets`, so counting it here charges it twice.
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .net_open, .severity = .err },
    };
    try std.testing.expectEqual(@as(usize, 2), drc.errorCount(&vios));
}

// spec-case: serve/route-plan - a diagnostic route preserves user copper zones as same-net source copper
test "pcb-describe fresh routing passes the shown user-zone sources into the diagnostic scope" {
    const source = @embedFile("pcb_describe.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "pcb_layout_page.diagnoseWithSubcircuitSeeds(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "route_options.existing_zones = solved.shown_zones.sources") != null);
}

// spec: Web Server - A fresh route's facts report the router's own pre-gate claim only when it exceeded what the connectivity oracle confirmed
test "router_claimed appears only when the router over-counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const honest = RoutedSummary{
        .trace_mm = 10,
        .tracks = 3,
        .vias = 1,
        .drc = 0,
        .routed = 12,
        .total = 12,
        .router_claimed = 12,
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeRoutedJson(&aw.writer, honest);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "router_claimed") == null);

    var over = honest;
    over.routed = 9;
    over.router_claimed = 12;
    var aw2: std.Io.Writer.Allocating = .init(arena);
    try writeRoutedJson(&aw2.writer, over);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"router_claimed\":12") != null);
}

// spec: Web Server - pcb-describe answers an unknown design or sub-block distinctly from an internal failure
test "describe error response separates unknown names from internal failures" {
    const nb = pcb_layout_page.pngFailure(error.BlockNotFound);
    try std.testing.expectEqual(@as(u16, 404), nb.status);
    try std.testing.expect(std.mem.indexOf(u8, nb.json, "no design or module") != null);
    const ns = pcb_layout_page.pngFailure(error.SubNotFound);
    try std.testing.expectEqual(@as(u16, 404), ns.status);
    try std.testing.expect(std.mem.indexOf(u8, ns.json, "no sub-block") != null);
    const ib = pcb_layout_page.pngFailure(error.BuildFailed);
    try std.testing.expectEqual(@as(u16, 500), ib.status);
    try std.testing.expect(std.mem.indexOf(u8, ib.json, "describe failed") != null);
    // The PNG endpoint's plain-text wording rides the same classification.
    try std.testing.expect(std.mem.indexOf(u8, nb.msg, "No design or module") != null);
}

// spec: Web Server - describeDesign reports facts for a design composed only of sub-blocks and rejects an unknown name
test "describeDesign solves a sub-block-only design and 404s an unknown name" {
    // The power-6v shape: a design whose body is nothing but (sub-block ...)
    // calls into a lib/modules defmodule — no top-level instances at all.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/mini-ic.sexp", .data =
        \\(component "mini-ic"
        \\  (description "minimal test regulator"))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/mini-cap.sexp", .data =
        \\(component-family "mini-cap"
        \\  (description "minimal test cap")
        \\  (parameter "value" capacitance))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/mini-rail.sexp", .data =
        \\(import mini-ic)
        \\(import mini-cap)
        \\
        \\(defmodule mini-rail ((val "1uF"))
        \\  (design-block "Mini Rail"
        \\    (instance "U1" mini-ic
        \\      (pin 1 "VIN")
        \\      (pin 2 "GND"))
        \\    (instance "C1" (mini-cap val)
        \\      (pin 1 "VIN")
        \\      (pin 2 "GND"))))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/power-mini.sexp", .data =
        \\(import mini-rail)
        \\
        \\(design-block "Mini Power"
        \\  (sub-block "a" (mini-rail))
        \\  (sub-block "b" (mini-rail "2uF")))
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const out = try describeDesign(alloc, project, "power-mini", .{}, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Mini Power\"") != null);
    // Both sub-blocks' parts made it into the facts, with prefixed refs.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"a/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"b/") != null);

    // A name that resolves to nothing surfaces BlockNotFound (the handler's
    // 404), not a generic failure.
    try std.testing.expectError(error.BlockNotFound, describeDesign(alloc, project, "no-such-design", .{}, null));
}
