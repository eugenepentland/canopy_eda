//! Manufacturing output for a saved PCB layout: the fab view, the readiness
//! gate, and the endpoints that hand a board to a fabricator.
//!
//! Split out of `pcb_layout_page.zig`. Everything here answers one question —
//! *is this exact saved board fit to build, and what are its files?* — and it
//! answers it in the y-up fab frame, not the editor's. `FabView` is that
//! frozen snapshot (a placement at one layout's poses, with that layout's
//! outline, copper, zones and keepouts lowered onto it); `fabViewFor` builds
//! it from a name and `fabViewForResolved` from an already-resolved block.
//! On top sit `/api/pcb-centroid`, `/api/pcb-drill`, `/api/fab-readiness` and
//! `/api/pcb-gerbers`, the release lock, and the ZIP the browser downloads.
//!
//! The contract is fail-closed: a layout whose saved evidence does not lower
//! completely is reported incomplete rather than certified, and a production
//! release without a passing gate needs an explicit acknowledged waiver.

const std = @import("std");
const httpz = @import("httpz");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const env_mod = @import("../eval/env.zig");
const optimizer = @import("../placement/optimizer.zig");
const perimeter_fence = @import("../placement/perimeter_fence.zig");
const pour = @import("../placement/pour.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const router = @import("../placement/router.zig");
const subcircuit_silkscreen = @import("../subcircuit_silkscreen.zig");
const export_fab = @import("../export_fab.zig");
const export_gerber = @import("../export_gerber.zig");
const export_kicad = @import("../export_kicad.zig");
const panelize = @import("../panelize.zig");
const panel_export = @import("panel_export.zig");
const fab_identity = @import("../fab_identity.zig");
const fab_preview = @import("../fab_preview.zig");
const fab_readiness = @import("../fab_readiness.zig");
const fab_gate = @import("../fab_gate.zig");
const fab_package = @import("../fab_package.zig");
const fab_release = @import("../fab_release.zig");
const fab_filename = @import("fab_filename.zig");
const standalone_assembly = @import("standalone_assembly.zig");
const zipfile = @import("../zipfile.zig");
const font5x7 = @import("../font5x7.zig");
const review = @import("../review.zig");
const modules_mod = @import("modules.zig");
const page_cache = @import("page_cache.zig");
const request_log = @import("request_log.zig");
const build_id = @import("../build_id.zig");
const paths = @import("../paths.zig");
const bom = @import("../bom.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const sidecar_json = @import("layout_sidecar_json.zig");
const sidecar_store = @import("../layout_sidecar_store.zig");
const sidecar_types = @import("../layout_sidecar_types.zig");
const saved_zone = @import("saved_zone.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const outline_mod = @import("../placement/outline.zig");
const board_layers = @import("../board_layers.zig");
const log = @import("../infra/log.zig");
const subprocess = @import("subprocess.zig");
const pcb_query = @import("pcb_query.zig");
const pcb_layout_mcp = @import("pcb_layout_mcp.zig");
const pcb_layout_chrome = @import("pcb_layout_chrome.zig");
const pcb_layout_blob = @import("pcb_layout_blob.zig");

const HandlerError = pcb_layout_page.HandlerError;
const SavedLayout = sidecar_types.SavedLayout;
const SavedRoutes = sidecar_types.SavedRoutes;
const SavedZone = sidecar_types.SavedZone;
const SavedOutline = sidecar_types.SavedOutline;
const SavedFabricationLayer = sidecar_types.SavedFabricationLayer;
const SidecarDoc = sidecar_store.SidecarDoc;
const no_block_msg = pcb_layout_page.no_block_msg;
const ct_hdr = pcb_layout_page.ct_hdr;
const View = pcb_layout_page.View;
const queryOpt = pcb_query.opt;
const queryFlag = pcb_query.flag;
const queryKeepDnp = pcb_layout_page.queryKeepDnp;
const nameParam = pcb_layout_page.nameParam;
const resolveBlock = pcb_layout_page.resolveBlock;
const userZonesFrom = saved_zone.userZones;
const silkKeepoutsFrom = pcb_layout_page.silkKeepoutsFrom;
const applyFabricationLayerOverrides = pcb_layout_page.applyFabricationLayerOverrides;
const readDesignDoc = sidecar_store.readDesignDoc;
const unknownLayoutMsg = pcb_layout_page.unknownLayoutMsg;
const no_saved_layout_msg = pcb_layout_page.no_saved_layout_msg;
const dnpMode = pcb_layout_page.dnpMode;
const subSlug = pcb_query.subSlug;
const routesWithPerimeterEvidence = pcb_layout_page.routesWithPerimeterEvidence;
const cachePoses = sidecar_store.cachePoses;
const kind_manual = sidecar_store.kind_manual;
const drawnSource = pcb_layout_page.drawnSource;
const placement_err_msg = pcb_layout_page.placement_err_msg;
const writePageScripts = pcb_layout_page.writePageScripts;
const restoreRoutes = pcb_layout_page.restoreRoutes;
const rekeyPosesByOrigin = pcb_layout_page.rekeyPosesByOrigin;
const refPosesFromParts = sidecar_store.refPosesFromParts;

/// Everything the fab writers need, resolved ONCE so every file of a package
/// agrees: the blessed placement with the ★ layout's drawn outline applied
/// (it's the board edge the gerbers profile), that layout's persisted routed
/// copper, and the authored metadata governing it. A drill file and a copper
/// file built from different FabViews would mis-stack in CAM — always build
/// one view per package.
pub const FabView = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 },
    /// Hand-drawn user copper pours restored from the blessed layout's zones —
    /// the Gerber emits them as real copper and the fab airwire gate credits
    /// them toward connectivity.
    zones: []const pour.UserZone = &.{},
    silk_keepouts: []const subcircuit_silkscreen.Keepout = &.{},
    texts: []const font5x7.BoardText = &.{},
    authored: FabAuthored = .{ .stackup = .{}, .revision = .{}, .board = .{} },
    /// True when the blessed poses came from a saved snapshot (★ default →
    /// newest manual → any named), false when they fell back to the bare
    /// optimizer cache — the fab-readiness check surfaces the cache case as a
    /// warning.
    selection: struct {
        from_saved: bool = false,
        /// Concrete saved row selected for this export, or `optimizer-cache`
        /// when no persisted snapshot supplied the placement.
        name: []const u8 = "optimizer-cache",
        /// True only when the exact parsed selected sidecar row contains no
        /// malformed/defaulted manufacturing records. Cache-only views are false.
        evidence_complete: bool = false,
    } = .{},
};

const blessedLayout = fab_package.blessedLayout;

fn exactPoseCoverage(poses: []const optimizer.RefPose, parts: []const optimizer.Part) bool {
    if (poses.len != parts.len) return false;
    for (poses, 0..) |pose, pose_index| {
        for (poses[0..pose_index]) |earlier| if (std.mem.eql(u8, earlier.ref, pose.ref)) return false;
        var matches: usize = 0;
        for (parts) |part| {
            if (std.mem.eql(u8, part.ref_des, pose.ref)) matches += 1;
        }
        if (matches != 1) return false;
    }
    return true;
}

fn savedNetExists(placement: optimizer.Placement, name: []const u8) bool {
    for (placement.nets) |net| if (std.mem.eql(u8, net.name, name)) return true;
    return false;
}

fn savedRoutesResolve(placement: optimizer.Placement, routes: SavedRoutes) bool {
    const layer_count = placement.rules.signalLayerCount();
    for (routes.tracks) |track| {
        if (!savedNetExists(placement, track.net) or track.l >= layer_count) return false;
    }
    for (routes.vias) |via| {
        if (!savedNetExists(placement, via.net)) return false;
        if (via.s) |span| {
            if (span[0] != 0 or span[1] + 1 != layer_count) return false;
        }
    }
    for (routes.rf_paths) |path| {
        if (!savedNetExists(placement, path.net) or path.layer >= layer_count) return false;
    }
    for (routes.zones) |zone| {
        if (!outline_mod.valid(zone.poly)) return false;
        if (!zone.flags.filled or zone.flags.keepout) continue;
        if (!savedNetExists(placement, zone.net)) return false;
        var legacy: [1][]const u8 = undefined;
        for (saved_zone.layers(&zone, &legacy)) |layer_name| {
            if (placement.rules.signalIndexOfName(layer_name) == null) return false;
        }
    }
    return true;
}

fn fabricationOverridesResolve(placement: optimizer.Placement, overrides: []const SavedFabricationLayer) bool {
    for (overrides, 0..) |saved, index| {
        for (overrides[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, saved.name)) return false;
        var matches: usize = 0;
        for (placement.fabrication_layers) |layer| {
            if (std.mem.eql(u8, layer.name, saved.name)) matches += 1;
        }
        if (matches != 1) return false;
    }
    return true;
}

fn savedLayoutSemanticsComplete(
    placement: optimizer.Placement,
    layout: SavedLayout,
    poses: []const optimizer.RefPose,
) bool {
    if (!exactPoseCoverage(poses, placement.parts)) return false;
    if (!fabricationOverridesResolve(placement, layout.fabrication_layers)) return false;
    if (layout.routes) |routes| return savedRoutesResolve(placement, routes);
    return true;
}

/// The `?layout=<row>` fab view: the named saved row, resolved through the
/// same `fabViewFor` selection the CLI tools' `layout` arg makes, so the
/// permalink, the report, and the package all describe that one board. A name
/// matching nothing 404s like /pcb-layout's direct link does — naming the
/// rows that DO exist — rather than silently answering about the ★ board.
fn namedFabView(ctx: *Server, req: *httpz.Request, res: *httpz.Response, name: []const u8, want: []const u8) ?FabView {
    return fabViewFor(req.arena, ctx.project_dir, name, want) catch |e| {
        res.status = if (e == error.PlacementFailed) 500 else 404;
        res.body = switch (e) {
            error.BlockNotFound => no_block_msg,
            error.UnknownLayout => unknownLayoutMsg(req.arena, ctx.project_dir, name, null, want),
            error.NoSavedLayout => no_saved_layout_msg,
            error.PlacementFailed => placement_err_msg,
        };
        return null;
    };
}

/// Resolve `name`'s fab view (see `FabView`); null (+ client error status)
/// when the design/module doesn't resolve or has no saved layout. An explicit
/// `?layout=<row>` pins the view to that named saved row instead of the
/// blessed ★ selection (see `namedFabView`), so every fab output can be asked
/// about a specific saved board.
fn blessedFabView(ctx: *Server, req: *httpz.Request, res: *httpz.Response, name: []const u8) ?FabView {
    if (queryOpt(req, "layout")) |want| return namedFabView(ctx, req, res, name, want);
    return fabViewFor(req.arena, ctx.project_dir, name, null) catch |e| {
        res.status = if (e == error.PlacementFailed) 500 else 404;
        res.body = switch (e) {
            error.BlockNotFound => no_block_msg,
            error.UnknownLayout => no_saved_layout_msg,
            error.NoSavedLayout => no_saved_layout_msg,
            error.PlacementFailed => placement_err_msg,
        };
        return null;
    };
}

/// GET /api/pcb-centroid/:name — the pick-and-place centroid CSV at the
/// design's blessed poses (see `blessedPlacement`), side-aware, in the
/// shared fab frame. The assembly half of the fab package; pairs with the
/// BOM CSV. Do-Not-Populate parts are dropped by default; `?dnp=keep` lists
/// them (a fully-populated variant). `?layout=<row>` builds against that
/// named saved layout (shared `blessedFabView` selection).
pub fn pcbCentroidApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const fv = blessedFabView(ctx, req, res, name) orelse return;
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.centroidCsv(&aw.writer, fv.placement.parts, fv.placement.instances, export_fab.frameFor(fv.placement), dnpMode(req));
    res.header(ct_hdr, "text/csv; charset=utf-8");
    res.body = aw.written();
}

/// GET /api/pcb-drill/:name[?npth=1] — the Excellon drill file at the design's
/// blessed poses: plated through-hole pads + the ★ layout's persisted routed
/// vias (PTH), or the non-plated mounting holes (`?npth=1`). `?layout=<row>`
/// drills the named saved layout instead (shared `blessedFabView` selection).
pub fn pcbDrillApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const fv = blessedFabView(ctx, req, res, name) orelse return;
    const class: export_fab.DrillClass = if (queryFlag(req, "npth")) .non_plated else .plated;
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.excellonDrill(&aw.writer, req.arena, fv.placement.parts, fv.routed.vias, .{ .class = class, .copper_layers = fv.placement.rules.layerStack().stackCount() }, export_fab.frameFor(fv.placement));
    res.header(ct_hdr, "text/plain; charset=utf-8");
    res.body = aw.written();
}

fn fabGateFor(
    ctx: *Server,
    req: *httpz.Request,
    fv: FabView,
    evaluator: *Evaluator,
    block: ?*const env_mod.DesignBlock,
    bom_evidence_complete: bool,
) HandlerError!fab_gate.Result {
    const copper = export_gerber.Copper{ .tracks = fv.routed.tracks, .arcs = fv.routed.arcs, .rf_paths = fv.routed.rf_port_outcomes, .vias = fv.routed.vias, .zones = fv.zones, .silk_keepouts = fv.silk_keepouts };
    const name = req.param("name") orelse "";
    return fab_gate.check(req.arena, .{
        .project_dir = ctx.project_dir,
        .name = name,
        .evaluator = evaluator,
        .block = block,
        .physical = .{ .placement = fv.placement, .routed = fv.routed, .zones = fv.zones, .texts = fv.texts, .copper = copper },
        .release = .{
            .from_saved = fv.selection.from_saved,
            .layout_evidence_complete = fv.selection.evidence_complete,
            .bom_evidence_complete = bom_evidence_complete,
            .keep_dnp = queryKeepDnp(req),
            .board = fv.authored.board,
        },
    });
}

fn resolvedReleaseView(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    name: []const u8,
    block: *env_mod.DesignBlock,
) ?FabView {
    // UNTESTED-ERROR: the arm only renders `fabViewForResolved`'s refusals as a
    // status and body; the refusals themselves are covered by the fabViewFor
    // test and end to end by the readiness/export HTTP tests.
    return fabViewForResolved(req.arena, ctx.project_dir, name, queryOpt(req, "layout"), block) catch |err| {
        res.status = if (err == error.PlacementFailed) 500 else 404;
        res.body = switch (err) {
            error.UnknownLayout => if (queryOpt(req, "layout")) |want| unknownLayoutMsg(req.arena, ctx.project_dir, name, null, want) else no_saved_layout_msg,
            error.NoSavedLayout => no_saved_layout_msg,
            error.PlacementFailed => placement_err_msg,
            error.BlockNotFound => no_block_msg,
        };
        return null;
    };
}

fn releaseIdentityMark(
    arena: std.mem.Allocator,
    fv: FabView,
    copper: export_gerber.Copper,
    gate: *fab_gate.Result,
) HandlerError!fab_identity.Mark {
    return fab_gate.identityMark(arena, .{
        .placement = fv.placement,
        .routed = fv.routed,
        .zones = fv.zones,
        .texts = fv.texts,
        .copper = copper,
    }, gate);
}

fn releaseLock(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    name: []const u8,
    evidence: fab_release.Evidence,
) HandlerError!?fab_release.Lock {
    // UNTESTED-ERROR: reachable only when release identity itself cannot be
    // computed (a git/hash failure under `fab_release.makeLock`); the arm exists
    // so that failure blocks the export loudly instead of certifying a board.
    return fab_release.makeLock(req.arena, ctx.project_dir, name, evidence) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log.warn("fabrication release identity failed for {s}: {s}", .{ name, @errorName(err) });
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"internal_checks_complete\":false,\"errors\":[{\"id\":\"release-identity-failed\",\"message\":\"release evidence could not be computed; export is blocked\"}]}";
        return null;
    };
}

fn releaseEvidenceBlocked(gate: fab_gate.Result, lock: fab_release.Lock) bool {
    return !gate.drc.complete or !gate.internal_complete or gate.evaluation.block == null or
        fab_release.projectStatusBlocksRelease(lock.project_status);
}

/// A prototype handoff is deliberately allowed to carry failed/incomplete
/// production evidence. It still needs a resolved board, an exact snapshot
/// token, and the explicit browser acknowledgment; actual composition errors
/// and a token that changes during generation remain hard failures.
fn prototypeExport(req: *httpz.Request) bool {
    return queryFlag(req, "prototype");
}

fn releaseNeedsWaiver(gate: fab_gate.Result, lock: fab_release.Lock) bool {
    return gate.report.errors.len > 0 or gate.report.warnings.len > 0 or gate.drc.raw.len > gate.drc.effective.len or
        fab_release.projectStatusNeedsWaiver(lock.project_status);
}

/// The Assembly page's physical board over one already-bound fabrication view.
/// Request-independent callers must never resolve the design a second time.
fn dossierReviewBoardPage(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8, fv: FabView) HandlerError![]const u8 {
    const view = View.init(fv.placement);
    const route_params = fv.placement.rules.design.routeParams();
    var page: std.Io.Writer.Allocating = .init(allocator);
    const w = &page.writer;
    try pcb_layout_chrome.writeDocHead(w, name, true, false);
    try w.writeAll("<div class=\"pcb-layout\"><main class=\"pcb-main\">");
    try pcb_layout_chrome.writeReadOnlyEmbedChrome(w, .{ .module_source = "", .params = route_params, .routed = fv.routed, .n_drc = 0, .toggles = .{ .clr = false, .drc = false }, .physical_review = true });
    try pcb_layout_chrome.writeStage(w, view, true);
    try w.writeAll("</main></div>");
    const opts: pcb_layout_blob.PcbDataOpts = .{ .read_only = true, .embed = true, .assembly_review = true, .sub = null, .shown_layout = fv.selection.name, .user_zones = fv.zones, .texts = fv.texts };
    try pcb_layout_blob.writePcbData(w, allocator, project_dir, fv.placement, .{}, view, name, &.{}, fv.routed, route_params.clearance, &.{}, opts);
    try writePageScripts(w, .{ .physical_review = true, .model_sprites = false, .thermal_overlay = false, .embed = true });
    try w.writeAll("</body></html>");
    return page.written();
}

/// Self-contained semantic Assembly board for an offline system dossier.
pub fn standaloneDossierReviewBoardHtml(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8, fv: FabView) HandlerError![]const u8 {
    return standalone_assembly.renderReviewBoardDocument(allocator, try dossierReviewBoardPage(allocator, project_dir, name, fv));
}

/// Render the offline Assembly member for callers that compose a release from
/// the same resolved `FabView` outside the per-board HTTP endpoint (notably a
/// multi-board system package).
pub fn standaloneReleaseAssemblyHtml(
    ctx: *Server,
    req: *httpz.Request,
    name: []const u8,
    block: *const env_mod.DesignBlock,
    fv: FabView,
    identity: standalone_assembly.ReleaseIdentity,
) HandlerError![]const u8 {
    return standalone_assembly.render(
        req.arena,
        ctx.project_dir,
        name,
        block,
        .{
            .board_page = try dossierReviewBoardPage(req.arena, ctx.project_dir, name, fv),
            .cam = .{
                .enabled = true,
                .placement = fv.placement,
                .routed = fv.routed,
                .zones = fv.zones,
                .silk_keepouts = fv.silk_keepouts,
                .texts = fv.texts,
                .package = .{
                    .frame = export_fab.frameFor(fv.placement),
                    .drill_suffixes = .{ export_gerber.plated_drill_suffix, export_gerber.non_plated_drill_suffix },
                },
            },
            .identity = identity,
        },
    );
}

/// GET /api/fab-readiness/:name — the pre-fab correctness report for `name`'s
/// blessed layout (audit item 0.1): `{ok,errors:[…],warnings:[…],stats:{…}}`,
/// computed against the SAME blessed-layout selection the Gerber export uses.
/// `?layout=<row>` pins the report to that named saved layout — the row its
/// /pcb-layout permalink shows and the CLI `run_fab_readiness` `layout` arg
/// selects — and 404s an unknown name instead of silently reporting the ★
/// board. The viewer fetches this before download and gates on it;
/// `pcbGerbersApi` enforces it server-side with a revision-locked confirmation
/// token; no package is emitted from an unconfirmed or stale report.
pub fn pcbFabReadinessApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    return pcbFabReadinessApiHooked(ctx, req, res, null);
}

const ReleaseSnapshotHook = struct {
    path: []const u8,
    during: []const u8,
    restored: []const u8,
    failed: bool = false,
};

fn writeReleaseSnapshot(hook: ?*ReleaseSnapshotHook, during: bool) void {
    const active = hook orelse return;
    infra_fs.cwd().writeFile(.{
        .sub_path = active.path,
        .data = if (during) active.during else active.restored,
    }) catch {
        active.failed = true;
    };
}

fn pcbFabReadinessApiHooked(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    snapshot_hook: ?*ReleaseSnapshotHook,
) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    if (subSlug(req) != null) {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"errors\":[{\"id\":\"scoped-release-unsupported\",\"message\":\"fabrication release is available only for a complete top-level board\"}]}";
        return;
    }
    const project_before = try fab_release.captureProjectState(req.arena, ctx.project_dir);
    defer req.arena.free(project_before.commit);
    const layout_before = try fab_release.savedLayoutDigest(req.arena, ctx.project_dir, name);
    const bom_before = try fab_release.savedBomDigest(req.arena, ctx.project_dir, name);
    var read_trace = infra_fs.ReadTrace.init(req.arena);
    defer read_trace.deinit();
    defer writeReleaseSnapshot(snapshot_hook, false);
    read_trace.begin();
    defer read_trace.end();
    writeReleaseSnapshot(snapshot_hook, true);
    var evaluator = Evaluator.init(req.arena, ctx.project_dir);
    defer evaluator.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |resolved| {
        resolved.eval.deinit();
        req.arena.destroy(resolved.eval);
    };
    const block = resolveBlock(req.arena, ctx.project_dir, name, &evaluator, &module_res) orelse {
        res.status = 404;
        res.body = no_block_msg;
        return;
    };
    const gate_evaluator = if (module_res) |resolved| resolved.eval else &evaluator;
    const bom_evidence_complete = try fab_gate.prepareBomEvidence(req.arena, ctx.project_dir, name, block);
    const fv = resolvedReleaseView(ctx, req, res, name, block) orelse return;
    var gate = try fabGateFor(ctx, req, fv, gate_evaluator, block, bom_evidence_complete);
    read_trace.end();
    writeReleaseSnapshot(snapshot_hook, false);
    const consumed_inputs_sha256 = read_trace.digest();
    const traced_inputs = try fab_release.tracedInputs(req.arena, &read_trace, ctx.project_dir, name);
    const copper = export_gerber.Copper{ .tracks = fv.routed.tracks, .arcs = fv.routed.arcs, .rf_paths = fv.routed.rf_port_outcomes, .vias = fv.routed.vias, .zones = fv.zones, .silk_keepouts = fv.silk_keepouts };
    const mark = try releaseIdentityMark(req.arena, fv, copper, &gate);
    const evidence = fab_release.Evidence{
        .report = gate.report,
        .design = .{
            .placement = fv.placement,
            .revision = fv.authored.revision,
            .stackup = fv.authored.stackup,
            .keep_dnp = queryKeepDnp(req),
            .block = gate.evaluation.block,
            .layout_name = fv.selection.name,
            .dependencies = gate.evaluation.dependencies,
        },
        .mark = mark,
        .drc = .{ .raw = gate.drc.raw, .effective = gate.drc.effective, .complete = gate.drc.complete, .internal_complete = gate.internal_complete, .policy = gate.policy },
        .inputs = .{
            .evaluation_sha256 = gate.evaluation.sha256,
            .reviewed_sha256 = gate.evaluation.reviewed_inputs_sha256,
            .consumed_sha256 = consumed_inputs_sha256,
            .source_sha256 = traced_inputs.source,
            .layout_sha256 = traced_inputs.layout,
            .bom_sha256 = traced_inputs.bom,
        },
    };
    var lock = (try releaseLock(ctx, req, res, name, evidence)) orelse return;
    fab_release.bindBaseline(&lock, project_before, layout_before, bom_before);
    fab_release.bindTracedInputs(&lock, traced_inputs, read_trace.verify());
    if (releaseEvidenceBlocked(gate, lock) and !prototypeExport(req)) {
        res.status = 500;
        var failed_json: std.Io.Writer.Allocating = .init(req.arena);
        try fab_release.writeReadinessJson(req.arena, &failed_json.writer, evidence, lock);
        res.content_type = .JSON;
        res.body = failed_json.written();
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try fab_release.writeReadinessJson(req.arena, &aw.writer, evidence, lock);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// GET /api/pcb-gerbers/:name — the complete fab package as one ZIP: Gerber
/// copper (outer signal layers + stackup-derived inner planes), solder mask,
/// paste, silkscreen, board profile, Excellon PTH/NPTH drills, the centroid
/// CSV, a `.gbrjob` job file, fabrication-ID manifest, and complete JSON +
/// Markdown DRC reports — all at the blessed poses with the ★ layout's
/// persisted routed copper, in one shared y-up frame. What a board house needs
/// to build and audit the board, no KiCad in the loop.
///
/// Gated by the fab-readiness report (`/api/fab-readiness`): every request must
/// echo that exact report's `?confirm=<release_token>`. Remaining findings also
/// require `?waive=1`. The browser's explicit test-board path sends
/// `?prototype=1`, echoes the separately labeled prototype snapshot token, and
/// may package incomplete production evidence; the ZIP records every finding.
/// `?dnp=keep` keeps Do-Not-Populate parts in the centroid CSV
/// (dropped by default). `?layout=<row>` packages the named saved layout —
/// gate and files built from the same view, so they still agree.
pub fn pcbGerbersApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    return pcbGerbersApiHooked(ctx, req, res, null);
}

fn pcbGerbersApiHooked(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    snapshot_hook: ?*ReleaseSnapshotHook,
) HandlerError!void {
    // Phase timings for the one handler whose cost is worth attributing in
    // production: the release gate is seconds of work, and which second is
    // which was previously only visible from a throwaway patch.
    var timer = request_log.StageTimer.start();
    const name = nameParam(req, res) orelse return;
    defer request_log.emitStages(&ctx.state.request_log, req.arena, req.url.path, name, &timer);
    if (subSlug(req) != null) {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"errors\":[{\"id\":\"scoped-release-unsupported\",\"message\":\"fabrication release is available only for a complete top-level board\"}]}";
        return;
    }
    const project_before = try fab_release.captureProjectState(req.arena, ctx.project_dir);
    defer req.arena.free(project_before.commit);
    const layout_before = try fab_release.savedLayoutDigest(req.arena, ctx.project_dir, name);
    const bom_before = try fab_release.savedBomDigest(req.arena, ctx.project_dir, name);
    timer.lap("project_state");
    var read_trace = infra_fs.ReadTrace.init(req.arena);
    defer read_trace.deinit();
    defer writeReleaseSnapshot(snapshot_hook, false);
    read_trace.begin();
    defer read_trace.end();
    writeReleaseSnapshot(snapshot_hook, true);
    var evaluator = Evaluator.init(req.arena, ctx.project_dir);
    defer evaluator.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |resolved| {
        resolved.eval.deinit();
        req.arena.destroy(resolved.eval);
    };
    const block = resolveBlock(req.arena, ctx.project_dir, name, &evaluator, &module_res) orelse {
        res.status = 404;
        res.body = no_block_msg;
        return;
    };
    timer.lap("resolve_block");
    // The whole gate below exists to decide whether this board may be
    // fabricated. When the project's own source revision has ALREADY decided
    // it cannot, deciding it again costs seconds and changes nothing: refuse
    // here, with the finding the full report would have carried, before the
    // board is restored, poured, checked and digested (`fab_package`).
    if (!prototypeExport(req)) {
        if (fab_package.refuseEarly(req.arena, ctx.project_dir, name, queryOpt(req, "layout"), project_before)) |refusal| {
            res.status = 500;
            var refused: std.Io.Writer.Allocating = .init(req.arena);
            try fab_package.writeRefusalJson(&refused.writer, name, refusal);
            res.content_type = .JSON;
            res.body = refused.written();
            timer.lap("refused");
            return;
        }
    }
    const gate_evaluator = if (module_res) |resolved| resolved.eval else &evaluator;
    const bom_evidence_complete = try fab_gate.prepareBomEvidence(req.arena, ctx.project_dir, name, block);
    const fv = resolvedReleaseView(ctx, req, res, name, block) orelse return;
    timer.lap("release_view");

    const copper = export_gerber.Copper{ .tracks = fv.routed.tracks, .arcs = fv.routed.arcs, .rf_paths = fv.routed.rf_port_outcomes, .vias = fv.routed.vias, .zones = fv.zones, .silk_keepouts = fv.silk_keepouts };
    const frame = export_fab.frameFor(fv.placement);
    var gate = try fabGateFor(ctx, req, fv, gate_evaluator, block, bom_evidence_complete);
    timer.lap("fab_gate");
    read_trace.end();
    writeReleaseSnapshot(snapshot_hook, false);
    const consumed_inputs_sha256 = read_trace.digest();
    const traced_inputs = try fab_release.tracedInputs(req.arena, &read_trace, ctx.project_dir, name);
    timer.lap("traced_inputs");
    const mark = try releaseIdentityMark(req.arena, fv, copper, &gate);
    timer.lap("identity_mark");
    const evidence = fab_release.Evidence{
        .report = gate.report,
        .design = .{
            .placement = fv.placement,
            .revision = fv.authored.revision,
            .stackup = fv.authored.stackup,
            .keep_dnp = queryKeepDnp(req),
            .block = gate.evaluation.block,
            .layout_name = fv.selection.name,
            .dependencies = gate.evaluation.dependencies,
        },
        .mark = mark,
        .drc = .{ .raw = gate.drc.raw, .effective = gate.drc.effective, .complete = gate.drc.complete, .internal_complete = gate.internal_complete, .policy = gate.policy },
        .inputs = .{
            .evaluation_sha256 = gate.evaluation.sha256,
            .reviewed_sha256 = gate.evaluation.reviewed_inputs_sha256,
            .consumed_sha256 = consumed_inputs_sha256,
            .source_sha256 = traced_inputs.source,
            .layout_sha256 = traced_inputs.layout,
            .bom_sha256 = traced_inputs.bom,
        },
    };
    var lock = (try releaseLock(ctx, req, res, name, evidence)) orelse return;
    fab_release.bindBaseline(&lock, project_before, layout_before, bom_before);
    fab_release.bindTracedInputs(&lock, traced_inputs, read_trace.verify());
    timer.lap("release_lock");
    const prototype = prototypeExport(req);
    if (releaseEvidenceBlocked(gate, lock) and !prototype) {
        res.status = 500;
        var failed_json: std.Io.Writer.Allocating = .init(req.arena);
        try fab_release.writeReadinessJson(req.arena, &failed_json.writer, evidence, lock);
        res.content_type = .JSON;
        res.body = failed_json.written();
        timer.lap("blocked_body");
        return;
    }
    const confirmed = if (queryOpt(req, "confirm")) |token| std.mem.eql(u8, token, &lock.token) else false;
    const needs_waiver = prototype or releaseNeedsWaiver(gate, lock);
    const waived = queryFlag(req, "waive");
    const waiver_missing = needs_waiver and !waived;
    if (!confirmed or waiver_missing) {
        res.status = 428;
        var jw: std.Io.Writer.Allocating = .init(req.arena);
        try fab_release.writeReadinessJson(req.arena, &jw.writer, evidence, lock);
        res.content_type = .JSON;
        res.body = jw.written();
        return;
    }
    var displayed_id = mark.short_hex;
    _ = std.ascii.upperString(&displayed_id, &mark.short_hex);
    // UNTESTED-ERROR: forwards `panel_export.requested`'s own rejections, which
    // that module's tests own; this arm adds no decision of its own.
    const panel = panel_export.requested(req.arena, req, panelize.sourceFor(fv.placement)) catch |err| {
        panel_export.writeError(res, err);
        return;
    };
    const pkg = try fab_package.compose(req.arena, name, .{
        .placement = fv.placement,
        .routed = fv.routed,
        .texts = fv.texts,
        .copper = copper,
        .frame = frame,
        .panel = panel,
    }, .{
        .mark = mark,
        .evidence = evidence,
        .lock = lock,
        .needs_waiver = needs_waiver,
        .dnp = dnpMode(req),
        .assembly_html = try standaloneReleaseAssemblyHtml(ctx, req, name, block, fv, .{
            .part_number = mark.part_number,
            .revision = fv.authored.revision.id,
            .fab_id = &displayed_id,
            .release_token = &lock.token,
        }),
    });
    timer.lap("compose");

    // Close the generation-time TOCTOU window: `makeLock` rereads every disk
    // input. If source/layout/library state moved after the reviewed lock was
    // computed while CAM files were being rendered, discard the package and
    // force the browser to review a fresh token instead of labeling stale CAM
    // with newer dependency hashes.
    var final_lock = (try releaseLock(ctx, req, res, name, evidence)) orelse return;
    fab_release.bindBaseline(&final_lock, project_before, layout_before, bom_before);
    fab_release.bindTracedInputs(&final_lock, traced_inputs, read_trace.verify());
    const production_status_blocked = !prototype and fab_release.projectStatusBlocksRelease(final_lock.project_status);
    if (production_status_blocked or !std.mem.eql(u8, &lock.token, &final_lock.token)) {
        res.status = 428;
        var changed: std.Io.Writer.Allocating = .init(req.arena);
        try fab_release.writeReadinessJson(req.arena, &changed.writer, evidence, final_lock);
        res.content_type = .JSON;
        res.body = changed.written();
        return;
    }

    var zw: std.Io.Writer.Allocating = .init(req.arena);
    try zipfile.write(&zw.writer, pkg.entries.items);
    res.header(ct_hdr, "application/zip");
    res.header("x-pcb-fab-id", try req.arena.dupe(u8, &mark.short_hex));
    const revision = try fab_release.safeRevision(req.arena, fv.authored.revision.id);
    const download_name = if (panel) |p|
        try std.fmt.allocPrint(req.arena, "attachment; filename=\"{s}-rev-{s}-{s}-panel-{d}x{d}-release.zip\"", .{ pkg.prefix, revision, &mark.short_hex, p.options.columns, p.options.rows })
    else
        try std.fmt.allocPrint(req.arena, "attachment; filename=\"{s}-rev-{s}-{s}-release.zip\"", .{ pkg.prefix, revision, &mark.short_hex });
    res.header("content-disposition", download_name);
    res.body = zw.written();
    timer.lap("zip");
}

/// Why `fabViewFor` produced no view — mapped to an HTTP status + body by
/// `namedFabView` and to a tool-failure message by `mcpRunFabReadiness`.
pub const FabViewError = error{
    /// The design/module name resolves to no block.
    BlockNotFound,
    /// A layout was asked for by name and no saved row answers to it.
    UnknownLayout,
    /// Nothing is saved (or cached) to build the view from.
    NoSavedLayout,
    /// The placement itself failed to build.
    // UNTESTED-ERROR: allocation-only. `refPosesFromParts` and
    // `optimizer.placeFromPoses` return no error but `Allocator.Error`, so this
    // member is unreachable in a test that is not itself an OOM harness.
    PlacementFailed,
};

/// Resolve a design's fab view without an HTTP request — the shared selection
/// behind `blessedFabView`'s `?layout=` path and the CLI tools' `layout` arg:
/// the placement at the chosen layout's poses (the named `layout_arg`, else
/// the blessed ★/newest/any snapshot) with that layout's outline + routes
/// applied, in the shared y-up fab frame.
pub fn fabViewFor(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layout_arg: ?[]const u8) FabViewError!FabView {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const block = resolveBlock(alloc, project_dir, name, &eval, &module_res) orelse return error.BlockNotFound;
    return fabViewForResolved(alloc, project_dir, name, layout_arg, block);
}

const UserZoneEvidence = struct {
    zones: []const pour.UserZone,
    complete: bool,
};

fn userZonesEvidence(alloc: std.mem.Allocator, rules: optimizer.BoardRules, saved: []const SavedZone) UserZoneEvidence {
    const zones = userZonesFrom(alloc, rules, saved);
    var expected: usize = 0;
    for (saved) |zone| {
        if (!zone.flags.filled or zone.flags.keepout) continue;
        var legacy: [1][]const u8 = undefined;
        expected += saved_zone.layers(&zone, &legacy).len;
    }
    return .{ .zones = zones, .complete = zones.len == expected };
}

const SilkKeepoutEvidence = struct {
    keepouts: []const subcircuit_silkscreen.Keepout,
    complete: bool,
};

fn silkKeepoutsEvidence(alloc: std.mem.Allocator, saved: []const SavedZone) SilkKeepoutEvidence {
    const keepouts = silkKeepoutsFrom(alloc, saved);
    var expected: usize = 0;
    for (saved) |zone| if (zone.flags.keepout and zone.poly.len >= 3) {
        expected += 1;
    };
    return .{ .keepouts = keepouts, .complete = keepouts.len == expected };
}

const LayoutLowering = struct {
    routed: router.RouteResult = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 },
    zones: []const pour.UserZone = &.{},
    silk_keepouts: []const subcircuit_silkscreen.Keepout = &.{},
    complete: bool = true,
};

fn lowerSavedManufacturing(
    alloc: std.mem.Allocator,
    placement: *optimizer.Placement,
    layout: SavedLayout,
) LayoutLowering {
    var result = LayoutLowering{};
    result.complete = applyFabricationLayerOverrides(alloc, placement, layout.fabrication_layers);

    if (layout.routes) |saved| {
        const perimeter = routesWithPerimeterEvidence(alloc, placement.*, saved);
        result.complete = result.complete and perimeter.complete;
        if (perimeter.routes) |routes| {
            if (restoreRoutes(alloc, routes, placement.nets)) |restored| {
                result.routed = restored;
            } else {
                result.complete = false;
            }
        } else {
            result.complete = false;
        }

        const zone_evidence = userZonesEvidence(alloc, placement.rules, saved.zones);
        result.zones = zone_evidence.zones;
        result.complete = result.complete and zone_evidence.complete;

        const silk_evidence = silkKeepoutsEvidence(alloc, saved.zones);
        result.silk_keepouts = silk_evidence.keepouts;
        result.complete = result.complete and silk_evidence.complete;
    }

    return result;
}

fn appendPerimeterEvidence(alloc: std.mem.Allocator, placement: optimizer.Placement, lowered: *LayoutLowering) void {
    const fenced = perimeter_fence.append(alloc, placement, lowered.routed) catch {
        lowered.complete = false;
        return;
    };
    if (fenced) |routed| {
        lowered.routed = routed;
    } else {
        lowered.complete = false;
    }
}

/// Build the physical fab snapshot from the already-resolved block used by the
/// strict schematic gate. Keeping both halves on this one evaluator snapshot
/// prevents CAM A from being paired with schematic/BOM evidence B.
pub fn fabViewForResolved(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layout_arg: ?[]const u8,
    block: *env_mod.DesignBlock,
) FabViewError!FabView {
    const sidecar = (readDesignDoc(alloc, project_dir, name) catch SidecarDoc{});
    // One selection predicate, shared with the fast refusal in `fab_package`:
    // a release that is going to be refused must be able to reach these same
    // two 404s without first paying for the placement below.
    const cache_poses = cachePoses(alloc, sidecar.cache);
    const chosen: ?SavedLayout = switch (fab_package.select(sidecar.layouts, cache_poses != null, layout_arg)) {
        .row => |L| L.*,
        .cache => null,
        .unknown_layout => return error.UnknownLayout,
        .none_saved => return error.NoSavedLayout,
    };

    const poses: []const optimizer.RefPose = if (chosen) |layout|
        // UNTESTED-ERROR: both re-keyers return null only on allocation failure.
        (rekeyPosesByOrigin(alloc, block, layout.parts) orelse (refPosesFromParts(alloc, layout.parts) orelse return error.PlacementFailed))
    else
        (cache_poses orelse return error.NoSavedLayout);

    // The chosen layout's own drawn outline is the fab board edge.
    const oseed: optimizer.OutlineSource = if (chosen) |L|
        (if (L.outline) |o| drawnSource(o) else .authored_only)
    else
        .authored_only;
    // UNTESTED-ERROR: `placeFromPoses` returns `Allocator.Error` and nothing else.
    var placement = optimizer.placeFromPoses(alloc, block, project_dir, .{ .poses = poses, .outline = oseed }, optimizer.Params{}) catch return error.PlacementFailed;
    var layout_evidence_complete = false;
    if (chosen) |layout| {
        const structure_complete = if (sidecar.root) |root|
            sidecar_json.selectedLayoutParsedEvidence(alloc, root, layout)
        else
            false;
        layout_evidence_complete = structure_complete and savedLayoutSemanticsComplete(placement, layout, poses);
    }
    var lowered = LayoutLowering{};
    var texts: []const font5x7.BoardText = &.{};
    if (chosen) |L| {
        lowered = lowerSavedManufacturing(alloc, &placement, L);
        texts = L.texts;
    }
    appendPerimeterEvidence(alloc, placement, &lowered);
    layout_evidence_complete = layout_evidence_complete and lowered.complete;
    return .{
        .placement = placement,
        .routed = lowered.routed,
        .zones = lowered.zones,
        .silk_keepouts = lowered.silk_keepouts,
        .texts = texts,
        .authored = .{ .stackup = block.stackup, .revision = block.revision, .board = block.board },
        .selection = .{
            .from_saved = chosen != null,
            .name = if (chosen) |layout| layout.name else "optimizer-cache",
            .evidence_complete = layout_evidence_complete,
        },
    };
}

/// Authored construction metadata needed by simulation handoffs.
pub const FabAuthored = struct {
    stackup: env_mod.StackupSpec,
    revision: env_mod.Revision,
    board: env_mod.BoardSpec,
};

/// Fixture for the fab `?layout=` selection test: a 2-cap board (nets SIG +
/// GND) on a real 2-pad footprint, with two saved rows over the same poses —
/// the ★ "routed" row carries copper closing SIG, the "open" row carries
/// none — so the two rows' fab-readiness genuinely differs.
fn writeFabSelectionFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/footprints");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/0402.sexp", .data =
        \\(footprint "0402"
        \\  (pad 1 smd roundrect (pos -0.48 0.00) (size 0.56 0.62))
        \\  (pad 2 smd roundrect (pos 0.48 0.00) (size 0.56 0.62))
        \\  (courtyard (rect -0.91 -0.46 0.91 0.46)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/fabsel.sexp", .data =
        \\(design-block "Fab Selection"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (design-rules (stackup 4) (plane 2 "GND") (pour top "GND") (ground-via-max 1.0))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/fabsel.layouts.json", .data =
        \\{"default":"routed","layouts":[
        \\ {"name":"routed","kind":"manual","ts":2,"default":true,"parts":[
        \\   {"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}],
        \\  "routes":{"tracks":[
        \\   {"x1":4.52,"y1":5,"x2":4.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\   {"x1":4.52,"y1":3,"x2":9.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\   {"x1":9.52,"y1":3,"x2":9.52,"y2":5,"l":0,"w":0.2,"net":"SIG"}],"vias":[]}},
        \\ {"name":"open","kind":"manual","ts":1,"parts":[
        \\   {"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}]}]}
    });
}

/// GET /api/fab-readiness/fabsel[?layout=…] through the real handler. This
/// deliberately minimal routing fixture has no release revision/BOM evidence,
/// so the strict endpoint must return 500 while still reporting the selected
/// row's physical findings for this selection regression.
fn fabReadinessBody(alloc: std.mem.Allocator, project: []const u8, layout: ?[]const u8) ![]const u8 {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", "fabsel");
    if (layout) |l| ht.query("layout", l);
    try pcbFabReadinessApi(&srv, ht.req, ht.res);
    try std.testing.expectEqual(@as(u16, 500), ht.res.status);
    try std.testing.expect(std.mem.indexOf(u8, ht.res.body, "\"internal_checks_complete\":false") != null);
    return alloc.dupe(u8, ht.res.body);
}

// spec: Web Server - The fab-readiness report and the fab package endpoints resolve ?layout=<name> to that named saved row and 404 an unknown name, never silently reporting a different board
test "fabViewFor refuses an unknown layout, an empty sidecar, and unplaceable poses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    // A ?layout= / `layout` arg naming no saved row never falls back to another
    // board — it refuses, and that refusal is what the HTTP 404 renders.
    try std.testing.expectError(error.UnknownLayout, fabViewFor(alloc, project, "fabsel", "nope"));

    // A design with no saved rows and no cache slot has nothing to build a fab
    // view from at all.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/fabsel.layouts.json", .data = "{\"layouts\":[]}" });
    try std.testing.expectError(error.NoSavedLayout, fabViewFor(alloc, project, "fabsel", null));
}

test "fab-readiness answers about the named saved row and 404s a dead layout link" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const starred = try fabReadinessBody(alloc, project, null);
    const routed = try fabReadinessBody(alloc, project, "routed");
    const open = try fabReadinessBody(alloc, project, "open");
    const sig_airwire = "net SIG is not fully connected";
    // ?layout=open reports THAT row's board — SIG is an airwire there…
    try std.testing.expect(std.mem.indexOf(u8, open, sig_airwire) != null);
    // …while the ★ row has SIG closed by its copper. Before the fix every
    // ?layout= value silently answered with this starred report.
    try std.testing.expect(std.mem.indexOf(u8, starred, sig_airwire) == null);
    // Naming the starred row reproduces the same physical verdict. Release
    // tokens may also bind request-local evidence ordering, so compare the
    // stable findings/stats rather than treating the token as presentation.
    try std.testing.expect(std.mem.indexOf(u8, routed, sig_airwire) == null);
    for ([_][]const u8{ "\"layout\":\"routed\"", "\"tracks\":3", "\"connected_nets\":1" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, starred, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, routed, needle) != null);
    }

    // A ?layout= naming nothing is a dead link: 404 listing the rows that DO
    // exist — never a 200 about a different board.
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", "fabsel");
    ht.query("layout", "nope");
    try pcbFabReadinessApi(&srv, ht.req, ht.res);
    try std.testing.expectEqual(@as(u16, 404), ht.res.status);
    try std.testing.expect(std.mem.indexOf(u8, ht.res.body, "\"nope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ht.res.body, "\"routed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ht.res.body, "\"open\"") != null);

    // That 404 is `namedFabView` refusing: asked directly it answers null and
    // writes the same status/body every fab endpoint then returns.
    var hn = httpz.testing.init(.{});
    defer hn.deinit();
    try std.testing.expect(namedFabView(&srv, hn.req, hn.res, "fabsel", "nope") == null);
    try std.testing.expectEqual(@as(u16, 404), hn.res.status);

    // And `blessedFabView` refuses a name that resolves to no block at all,
    // rather than falling through to some other board's ★ row.
    var hb = httpz.testing.init(.{});
    defer hb.deinit();
    try std.testing.expect(blessedFabView(&srv, hb.req, hb.res, "no-such-design") == null);
    try std.testing.expectEqual(@as(u16, 404), hb.res.status);
    try std.testing.expectEqualStrings(no_block_msg, hb.res.body);
}

fn writeFabReleaseLayout(dir: std.Io.Dir, timestamp: i64) !void {
    var bytes: [512]u8 = undefined;
    const data = try std.fmt.bufPrint(&bytes,
        \\{{"default":"release","layouts":[{{"name":"release","kind":"manual","ts":{d},"default":true,
        \\ "parts":[{{"ref":"U1","x":20,"y":10,"rot":0}}],
        \\ "routes":{{"tracks":[],"vias":[{{"x":20,"y":10,"d":0.2,"drill":0.05,"net":"GND"}}]}}}}]}}
    , .{timestamp});
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/fabok.layouts.json", .data = data });
}

fn writeFabReleaseFixture(allocator: std.mem.Allocator, dir: std.Io.Dir, project: []const u8) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/footprints");
    try dir.createDirPath(std.testing.io, "lib/modules");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/fixture-part.sexp", .data =
        \\(component fixture-part
        \\  (footprint "onepad")
        \\  (manufacturer "Fixture Devices")
        \\  (mpn "FIX-1")
        \\  (ignore-requirements)
        \\  (pins (1 "GND")))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/onepad.sexp", .data =
        \\(footprint "onepad"
        \\  (pad 1 smd roundrect (pos 0 0) (size 1 1))
        \\  (courtyard (rect -0.8 -0.8 0.8 0.8)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/fabok.sexp", .data =
        \\(import fixture-part)
        \\(design-block "Fabrication Release Fixture"
        \\  (revision "A" (date "2026-08-27"))
        \\  (board (part-number "FAB-1001") (size 40 20))
        \\  (design-rules (stackup 4) (plane 2 "GND") (pour top "GND"))
        \\  (assert (== 1 2) "intentional fixture waiver")
        \\  (instance "U1" fixture-part
        \\    (id fab00001)
        \\    (pin 1 "GND")))
    });
    try writeFabReleaseLayout(dir, 1);

    const source_path = try paths.designSourcePath(allocator, project, "fabok");
    defer allocator.free(source_path);
    const bom_path = try paths.designSiblingPath(allocator, project, "fabok", ".bom");
    defer allocator.free(bom_path);
    var evaluator = Evaluator.init(allocator, project);
    defer evaluator.deinit();
    const evaluated = try evaluator.evalFile(source_path);
    const block = switch (evaluated) {
        .design_block => |value| value,
        else => return error.TestExpectedDesignBlock,
    };
    try bom.resolveIdentities(allocator, block, bom_path, project);
}

fn runFabTestGit(allocator: std.mem.Allocator, project: []const u8, tail: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, project);
    try argv.appendSlice(allocator, tail);
    const result = try subprocess.runCaptured(allocator, argv.items, 64 * 1024, 5_000);
    defer result.deinit(allocator);
    try std.testing.expectEqual(subprocess.Outcome.ok, result.outcome);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
}

const FabEndpointResponse = struct {
    status: u16,
    body: []const u8,
    content_type: ?[]const u8,
};

const FabEndpointCall = struct {
    gerbers: bool,
    confirm: ?[]const u8,
    waive: bool,
    prototype: bool = false,
    snapshot_hook: ?*ReleaseSnapshotHook = null,
};

fn callFabEndpoint(
    allocator: std.mem.Allocator,
    project: []const u8,
    gerbers: bool,
    confirm: ?[]const u8,
    waive: bool,
) !FabEndpointResponse {
    return callFabEndpointHooked(allocator, project, .{ .gerbers = gerbers, .confirm = confirm, .waive = waive });
}

fn callPrototypeFabEndpoint(
    allocator: std.mem.Allocator,
    project: []const u8,
    gerbers: bool,
    confirm: ?[]const u8,
    waive: bool,
) !FabEndpointResponse {
    return callFabEndpointHooked(allocator, project, .{ .gerbers = gerbers, .confirm = confirm, .waive = waive, .prototype = true });
}

fn callFabEndpointHooked(
    allocator: std.mem.Allocator,
    project: []const u8,
    call: FabEndpointCall,
) !FabEndpointResponse {
    var state = serve_root.ServerState{};
    var server = Server{ .allocator = allocator, .project_dir = project, .auth_dir = project, .state = &state };
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "fabok");
    request.query("layout", "release");
    if (call.confirm) |token| request.query("confirm", token);
    if (call.waive) request.query("waive", "1");
    if (call.prototype) request.query("prototype", "1");
    paths.beginRequest();
    if (call.gerbers)
        try pcbGerbersApiHooked(&server, request.req, request.res, call.snapshot_hook)
    else
        try pcbFabReadinessApiHooked(&server, request.req, request.res, call.snapshot_hook);
    return .{
        .status = request.res.status,
        .body = try allocator.dupe(u8, request.res.body),
        .content_type = if (request.res.headers.get(ct_hdr)) |value| try allocator.dupe(u8, value) else null,
    };
}

fn setupFabReleaseTest(allocator: std.mem.Allocator, dir: std.Io.Dir, project: []const u8) !void {
    try writeFabReleaseFixture(allocator, dir, project);
}

fn gitFabReleaseTest(allocator: std.mem.Allocator, project: []const u8, tail: []const []const u8) !void {
    try runFabTestGit(allocator, project, tail);
}

fn readinessFabReleaseTest(allocator: std.mem.Allocator, project: []const u8) ![]const u8 {
    const response = try callFabEndpoint(allocator, project, false, null, false);
    // UNTESTED-ERROR: test-harness assertion, not a product error path — the
    // release tests fail on it directly rather than through a second test.
    if (response.status != 200) return error.TestExpectedReadyResponse;
    return response.body;
}

fn readinessResponseFabReleaseTest(allocator: std.mem.Allocator, project: []const u8) !FabEndpointResponse {
    return callFabEndpoint(allocator, project, false, null, false);
}

/// Cross-module support for the layout-tool tests: the saved-row selection
/// fixture (one design, a starred routed row and an unrouted one) that
/// `pcb_layout_mcp.zig`'s tool tests build their sidecars on.
pub const FabSelectionTestSupport = struct {
    pub const write = writeFabSelectionFixture;
};

/// Cross-module support for the HTTP/MCP manufacturing-gate parity test.
pub const FabReleaseTestSupport = struct {
    pub const setup = setupFabReleaseTest;
    pub const git = gitFabReleaseTest;
    pub const readiness = readinessFabReleaseTest;
    pub const readiness_response = readinessResponseFabReleaseTest;
};

const StoredZipEntry = struct { name: []const u8, data: []const u8 };

fn storedZipEntries(allocator: std.mem.Allocator, bytes: []const u8) ![]const StoredZipEntry {
    var result: std.ArrayList(StoredZipEntry) = .empty;
    var offset: usize = 0;
    while (offset + 30 <= bytes.len and std.mem.eql(u8, bytes[offset .. offset + 4], "PK\x03\x04")) {
        const method = std.mem.readInt(u16, bytes[offset + 8 ..][0..2], .little);
        // UNTESTED-ERROR: harness assertion — the release ZIP is stored, never
        // deflated, and this reader exists only to prove that.
        if (method != 0) return error.TestExpectedStoredZip;
        const size: usize = std.mem.readInt(u32, bytes[offset + 18 ..][0..4], .little);
        const name_len: usize = std.mem.readInt(u16, bytes[offset + 26 ..][0..2], .little);
        const extra_len: usize = std.mem.readInt(u16, bytes[offset + 28 ..][0..2], .little);
        const data_offset = offset + 30 + name_len + extra_len;
        const end = data_offset + size;
        // UNTESTED-ERROR: harness assertion over a ZIP this suite just produced.
        if (end > bytes.len) return error.TestTruncatedZip;
        try result.append(allocator, .{
            .name = bytes[offset + 30 ..][0..name_len],
            .data = bytes[data_offset..end],
        });
        offset = end;
    }
    // UNTESTED-ERROR: harness assertion over a ZIP this suite just produced.
    if (result.items.len == 0) return error.TestExpectedZip;
    return result.toOwnedSlice(allocator);
}

fn storedZipEntry(entries: []const StoredZipEntry, name: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.data;
    return null;
}

fn storedZipEntrySuffix(entries: []const StoredZipEntry, suffix: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.endsWith(u8, entry.name, suffix)) return entry.data;
    return null;
}

fn hasZipSuffix(entries: []const StoredZipEntry, suffix: []const u8) bool {
    for (entries) |entry| if (std.mem.endsWith(u8, entry.name, suffix)) return true;
    return false;
}

fn expectFabIdentityParity(relative: std.json.Value, absolute: std.json.Value) !void {
    for ([_][]const u8{
        "release_token",
        "evaluation_read_set_sha256",
        "consumed_inputs_sha256",
        "source_sha256",
        "layout_sha256",
        "bom_evidence_sha256",
        "reviewed_inputs_sha256",
    }) |key| try std.testing.expectEqualStrings(relative.object.get(key).?.string, absolute.object.get(key).?.string);
}

fn expectPrefixedFabMember(allocator: std.mem.Allocator, entries: []const StoredZipEntry, suffix: []const u8) !void {
    const name = try std.fmt.allocPrint(allocator, "fabok-{s}", .{suffix});
    defer allocator.free(name);
    try std.testing.expect(storedZipEntry(entries, name) != null);
}

fn expectFabZipMembers(allocator: std.mem.Allocator, entries: []const StoredZipEntry) !void {
    const layer_table = (board_layers.Stack{}).table();
    for (layer_table.rows()) |*row| try expectPrefixedFabMember(allocator, entries, row.gerberSuffix());
    try expectPrefixedFabMember(allocator, entries, export_gerber.job_file_suffix);
    try expectPrefixedFabMember(allocator, entries, export_gerber.plated_drill_suffix);
    try expectPrefixedFabMember(allocator, entries, export_gerber.non_plated_drill_suffix);
    for ([_][]const u8{
        "fabok-bom.csv",
        "fabok-centroid.csv",
        "fabok-assembly.html",
        "fabok-fab-id.txt",
        "fabok-release-report.json",
        "fabok-release-report.md",
        "fabok-drc-report.json",
        "fabok-drc-report.md",
        "fabok-design-rules.json",
        "fabok-checksums.sha256",
    }) |member| try std.testing.expect(storedZipEntry(entries, member) != null);
}

fn expectFabChecksums(allocator: std.mem.Allocator, entries: []const StoredZipEntry, checksums: []const u8) !void {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "fabok-checksums.sha256")) continue;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const line = try std.fmt.allocPrint(allocator, "{s}  {s}\n", .{ &hex, entry.name });
        try std.testing.expect(std.mem.indexOf(u8, checksums, line) != null);
    }
}

// spec: fabrication-release - every acknowledged fabrication ZIP includes dedicated JSON and Markdown reports containing every raw DRC error and warning
test "fab release requires confirmation and waiver then emits a checksummed revision lock" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const absolute_project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    try writeFabReleaseFixture(allocator, tmp.dir, absolute_project);
    try runFabTestGit(allocator, absolute_project, &.{ "init", "-q" });
    try runFabTestGit(allocator, absolute_project, &.{ "add", "." });
    try runFabTestGit(allocator, absolute_project, &.{ "-c", "user.name=Fab Test", "-c", "user.email=fab@test.invalid", "commit", "-q", "-m", "fixture" });

    const current = try infra_fs.canonicalPathAlloc(allocator, ".");
    const relative_project = try std.fs.path.relative(allocator, current, null, current, absolute_project);
    const readiness = try callFabEndpoint(allocator, relative_project, false, null, false);
    try std.testing.expectEqual(@as(u16, 200), readiness.status);
    const readiness_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, readiness.body, .{});
    try std.testing.expect(readiness_json.object.get("internal_checks_complete").?.bool);
    try std.testing.expect(readiness_json.object.get("needs_waiver").?.bool);
    try std.testing.expectEqualStrings("clean", readiness_json.object.get("project_status").?.string);
    try std.testing.expectEqualStrings("FAB-1001", readiness_json.object.get("part_number").?.string);
    const token = try allocator.dupe(u8, readiness_json.object.get("release_token").?.string);

    const absolute_readiness = try callFabEndpoint(allocator, absolute_project, false, null, false);
    try std.testing.expectEqual(@as(u16, 200), absolute_readiness.status);
    const absolute_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, absolute_readiness.body, .{});
    try expectFabIdentityParity(readiness_json, absolute_json);

    const unconfirmed = try callFabEndpoint(allocator, relative_project, true, null, false);
    try std.testing.expectEqual(@as(u16, 428), unconfirmed.status);
    const not_waived = try callFabEndpoint(allocator, relative_project, true, token, false);
    try std.testing.expectEqual(@as(u16, 428), not_waived.status);
    const wrong_token = try callFabEndpoint(allocator, relative_project, true, "wrong-token", true);
    try std.testing.expectEqual(@as(u16, 428), wrong_token.status);

    const package = try callFabEndpoint(allocator, relative_project, true, token, true);
    try std.testing.expectEqual(@as(u16, 200), package.status);
    try std.testing.expectEqualStrings("application/zip", package.content_type.?);
    try std.testing.expect(std.mem.startsWith(u8, package.body, "PK\x03\x04"));
    const entries = try storedZipEntries(allocator, package.body);
    try expectFabZipMembers(allocator, entries);
    try std.testing.expectEqual(@as(usize, 24), entries.len);
    try std.testing.expect(std.mem.indexOf(u8, storedZipEntry(entries, "fabok-bom.csv").?, "U1") != null);
    try std.testing.expect(std.mem.indexOf(u8, storedZipEntry(entries, "fabok-centroid.csv").?, "U1") != null);
    const assembly_html = storedZipEntry(entries, "fabok-assembly.html").?;
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "Released assembly") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "FAB-1001") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "id=\"assembly-search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "id=\"pcb-frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "PCB.standalone=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "PCB.cam=") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "src=\"/pcb-layout/") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_html, "src=\"/static/") == null);
    try std.testing.expect(std.mem.indexOf(u8, storedZipEntry(entries, "fabok-fab-id.txt").?, "Board part number: FAB-1001") != null);

    const release_report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, storedZipEntry(entries, "fabok-release-report.json").?, .{});
    try std.testing.expectEqualStrings("netlisp-fab-release-v1", release_report.object.get("schema").?.string);
    try std.testing.expect(release_report.object.get("confirmed").?.bool);
    try std.testing.expect(release_report.object.get("waiver").?.bool);
    try std.testing.expectEqualStrings("A", release_report.object.get("revision").?.string);
    try std.testing.expectEqualStrings("FAB-1001", release_report.object.get("part_number").?.string);
    const drc_report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, storedZipEntry(entries, "fabok-drc-report.json").?, .{});
    try std.testing.expectEqualStrings("netlisp-drc-report-v1", drc_report.object.get("schema").?.string);
    try std.testing.expect(drc_report.object.get("acknowledged").?.bool);
    try std.testing.expect(drc_report.object.get("error_count").?.integer > 0);
    try std.testing.expectEqual(readiness_json.object.get("raw_drc_count").?.integer, drc_report.object.get("raw_count").?.integer);
    try std.testing.expectEqual(drc_report.object.get("raw_count").?.integer, drc_report.object.get("error_count").?.integer + drc_report.object.get("warning_count").?.integer);
    try std.testing.expectEqual(@as(usize, @intCast(drc_report.object.get("raw_count").?.integer)), drc_report.object.get("findings").?.array.items.len);
    const drc_markdown = storedZipEntry(entries, "fabok-drc-report.md").?;
    try std.testing.expect(std.mem.indexOf(u8, drc_markdown, "Acknowledgment accepted: yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, drc_markdown, "**err ·") != null or std.mem.indexOf(u8, drc_markdown, "**warn ·") != null);
    const rules = try std.json.parseFromSliceLeaky(std.json.Value, allocator, storedZipEntry(entries, "fabok-design-rules.json").?, .{});
    try std.testing.expectEqualStrings("FAB-1001", rules.object.get("part_number").?.string);

    const checksums = storedZipEntry(entries, "fabok-checksums.sha256").?;
    try expectFabChecksums(allocator, entries, checksums);

    try writeFabReleaseLayout(tmp.dir, 2);
    try runFabTestGit(allocator, absolute_project, &.{ "add", "src/fabok.layouts.json" });
    try runFabTestGit(allocator, absolute_project, &.{ "-c", "user.name=Fab Test", "-c", "user.email=fab@test.invalid", "commit", "-q", "-m", "layout update" });
    const stale = try callFabEndpoint(allocator, relative_project, true, token, true);
    try std.testing.expectEqual(@as(u16, 428), stale.status);
    const stale_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, stale.body, .{});
    try std.testing.expect(!std.mem.eql(u8, token, stale_json.object.get("release_token").?.string));

    try writeFabReleaseLayout(tmp.dir, 3);
    const dirty = try callFabEndpoint(allocator, relative_project, false, null, false);
    try std.testing.expectEqual(@as(u16, 200), dirty.status);
    const dirty_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, dirty.body, .{});
    try std.testing.expectEqualStrings("dirty", dirty_json.object.get("project_status").?.string);
    try std.testing.expect(dirty_json.object.get("release_token").? == .string);
    try std.testing.expect(dirty_json.object.get("internal_checks_complete").?.bool);
    try std.testing.expect(dirty_json.object.get("needs_waiver").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, dirty.body, "source-worktree-dirty") != null);
    try std.testing.expect(std.mem.indexOf(u8, dirty.body, "intentional fixture waiver") != null);
    try std.testing.expect(dirty_json.object.get("raw_drc_count").?.integer > 0);
    const dirty_token = try allocator.dupe(u8, dirty_json.object.get("release_token").?.string);
    const dirty_not_waived = try callFabEndpoint(allocator, relative_project, true, dirty_token, false);
    try std.testing.expectEqual(@as(u16, 428), dirty_not_waived.status);
    const stale_clean_token = try callFabEndpoint(allocator, relative_project, true, token, true);
    try std.testing.expectEqual(@as(u16, 428), stale_clean_token.status);
    const dirty_export = try callFabEndpoint(allocator, relative_project, true, dirty_token, true);
    try std.testing.expectEqual(@as(u16, 200), dirty_export.status);
    try std.testing.expect(std.mem.startsWith(u8, dirty_export.body, "PK\x03\x04"));
    const dirty_entries = try storedZipEntries(allocator, dirty_export.body);
    const dirty_report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, storedZipEntry(dirty_entries, "fabok-release-report.json").?, .{});
    try std.testing.expectEqualStrings("dirty", dirty_report.object.get("project_status").?.string);
    try std.testing.expect(dirty_report.object.get("waiver").?.bool);
    const dirty_warnings = dirty_report.object.get("warnings").?.array.items;
    var found_dirty_warning = false;
    for (dirty_warnings) |warning| {
        if (std.mem.eql(u8, warning.object.get("id").?.string, "source-worktree-dirty")) found_dirty_warning = true;
    }
    try std.testing.expect(found_dirty_warning);
}

fn initializeFabReleaseGit(allocator: std.mem.Allocator, project: []const u8) !void {
    try runFabTestGit(allocator, project, &.{ "init", "-q" });
    try runFabTestGit(allocator, project, &.{ "add", "." });
    try runFabTestGit(allocator, project, &.{ "-c", "user.name=Fab Test", "-c", "user.email=fab@test.invalid", "commit", "-q", "-m", "fixture" });
}

// spec: fabrication-release - production releases treat a duplicate design basename as a non-waivable source-bundle ambiguity, while an explicitly acknowledged prototype can export the resolved test board with every finding attached
test "duplicate release source blocks production but permits acknowledged prototype" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    try writeFabReleaseFixture(allocator, tmp.dir, project);
    try tmp.dir.createDirPath(std.testing.io, "src/duplicate");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/duplicate/fabok.sexp",
        .data = "(design-block \"Ambiguous Duplicate\" (revision \"A\") (board (size 1 1)))",
    });
    try initializeFabReleaseGit(allocator, project);

    const readiness_response = try callFabEndpoint(allocator, project, false, null, false);
    try std.testing.expectEqual(@as(u16, 500), readiness_response.status);
    const readiness_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, readiness_response.body, .{});
    try std.testing.expect(readiness_json.object.get("release_token").? == .null);
    try std.testing.expect(readiness_json.object.get("prototype_token").? == .string);
    try std.testing.expectEqualStrings("ambiguous", readiness_json.object.get("project_status").?.string);
    try std.testing.expect(std.mem.indexOf(u8, readiness_response.body, "source-bundle-ambiguous") != null);
    try std.testing.expect(std.mem.indexOf(u8, readiness_response.body, "intentional fixture waiver") != null);

    const package_response = try callFabEndpoint(allocator, project, true, "not-an-authorization", true);
    try std.testing.expectEqual(@as(u16, 500), package_response.status);
    try std.testing.expect(!std.mem.startsWith(u8, package_response.body, "PK\x03\x04"));

    const prototype_ready = try callPrototypeFabEndpoint(allocator, project, false, null, false);
    try std.testing.expectEqual(@as(u16, 200), prototype_ready.status);
    const prototype_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, prototype_ready.body, .{});
    const prototype_token = prototype_json.object.get("prototype_token").?.string;
    try std.testing.expect(!prototype_json.object.get("internal_checks_complete").?.bool);
    const prototype_package = try callPrototypeFabEndpoint(allocator, project, true, prototype_token, true);
    try std.testing.expectEqual(@as(u16, 200), prototype_package.status);
    try std.testing.expect(std.mem.startsWith(u8, prototype_package.body, "PK\x03\x04"));
}

// spec: fabrication-release - an in-request A/B/A sidecar mutation invalidates production HTTP readiness and export without granting a production authorization token
test "in-request layout ABA invalidates HTTP readiness and export" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    try writeFabReleaseFixture(allocator, tmp.dir, project);
    try initializeFabReleaseGit(allocator, project);
    const layout_path = try std.fmt.allocPrint(allocator, "{s}/src/fabok.layouts.json", .{project});
    const original = try infra_fs.cwd().readFileAlloc(allocator, layout_path, 64 * 1024);
    const during = try std.fmt.allocPrint(allocator,
        \\{{"default":"release","layouts":[{{"name":"release","kind":"manual","ts":2,"default":true,
        \\ "parts":[{{"ref":"U1","x":21,"y":10,"rot":0}}]}}]}}
    , .{});
    var hook = ReleaseSnapshotHook{ .path = layout_path, .during = during, .restored = original };

    const readiness_response = try callFabEndpointHooked(allocator, project, .{ .gerbers = false, .confirm = null, .waive = false, .snapshot_hook = &hook });
    try std.testing.expect(!hook.failed);
    try std.testing.expectEqual(@as(u16, 500), readiness_response.status);
    const readiness_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, readiness_response.body, .{});
    try std.testing.expect(readiness_json.object.get("release_token").? == .null);
    try std.testing.expectEqualStrings("changed", readiness_json.object.get("project_status").?.string);
    try std.testing.expect(std.mem.indexOf(u8, readiness_response.body, "intentional fixture waiver") != null);
    try std.testing.expect(readiness_json.object.get("raw_drc_count").?.integer > 0);

    hook.failed = false;
    const package_response = try callFabEndpointHooked(allocator, project, .{ .gerbers = true, .confirm = "stale-token", .waive = true, .snapshot_hook = &hook });
    try std.testing.expect(!hook.failed);
    try std.testing.expectEqual(@as(u16, 500), package_response.status);
    try std.testing.expect(!std.mem.startsWith(u8, package_response.body, "PK\x03\x04"));
}

test "release layout semantics require exact poses and resolvable physical references" {
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
    }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "N", .pins = &.{} }};
    const placement = pcb_layout_mcp.addTracksFixture(&parts, &nets, &.{});
    const poses = [_]optimizer.RefPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const valid_routes = SavedRoutes{
        .tracks = &.{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .l = 0, .w = 0.2, .net = "N" }},
        .vias = &.{},
    };
    const valid = SavedLayout{ .name = "release", .kind = kind_manual, .ts = 1, .score = null, .parts = &.{}, .routes = valid_routes };
    try std.testing.expect(savedLayoutSemanticsComplete(placement, valid, &poses));
    try std.testing.expect(!savedLayoutSemanticsComplete(placement, valid, &.{}));
    try std.testing.expect(!savedLayoutSemanticsComplete(placement, valid, &.{.{ .ref = "UNKNOWN", .x = 0, .y = 0, .rot = 0 }}));
    try std.testing.expect(!savedLayoutSemanticsComplete(placement, valid, &.{
        .{ .ref = "U1", .x = 0, .y = 0, .rot = 0 },
        .{ .ref = "U1", .x = 1, .y = 0, .rot = 0 },
    }));

    const unknown_rf = SavedLayout{
        .name = "release",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &.{},
        .routes = .{ .tracks = &.{}, .vias = &.{}, .rf_paths = &.{.{
            .net = "UNKNOWN",
            .layer = 0,
            .samples = &.{
                .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
                .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
            },
        }} },
    };
    try std.testing.expect(!savedLayoutSemanticsComplete(placement, unknown_rf, &poses));
    const unknown_layer = SavedLayout{
        .name = "release",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &.{},
        .fabrication_layers = &.{.{ .name = "unknown.gbr", .regions = &.{} }},
    };
    try std.testing.expect(!savedLayoutSemanticsComplete(placement, unknown_layer, &poses));
}

// spec: fabrication-release - allocation failure while lowering saved fabrication layers, copper, zones, keepouts, or perimeter vias blocks release rather than certifying a partial board
test "release layout lowering fails closed across every manufacturing adapter" {
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &.{} }};
    var placement = pcb_layout_mcp.addTracksFixture(&.{}, &nets, &.{});
    placement.fabrication_layers = &.{.{
        .name = "backing.gbr",
        .side = .bottom,
        .material = "tape",
        .thickness = 0.1,
        .regions = &.{.board},
    }};
    placement.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .net = "GND",
    };
    const saved_zones = [_]SavedZone{
        .{ .net = "GND", .layer = "F.Cu", .poly = &poly, .flags = .{ .filled = true } },
        .{ .layer = "F.Cu", .poly = &poly, .flags = .{ .keepout = true } },
    };
    const saved = SavedRoutes{
        .tracks = &.{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .l = 0, .w = 0.2, .net = "GND" }},
        .vias = &.{},
        .zones = &saved_zones,
    };

    var fab_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!applyFabricationLayerOverrides(fab_alloc.allocator(), &placement, &.{.{ .name = "backing.gbr", .regions = &.{&poly} }}));

    var route_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!routesWithPerimeterEvidence(route_alloc.allocator(), placement, saved).complete);

    var zone_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!userZonesEvidence(zone_alloc.allocator(), placement.rules, saved_zones[0..1]).complete);

    var silk_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!silkKeepoutsEvidence(silk_alloc.allocator(), saved_zones[1..2]).complete);

    var fence_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var lowered = LayoutLowering{};
    appendPerimeterEvidence(fence_alloc.allocator(), placement, &lowered);
    try std.testing.expect(!lowered.complete);

    var aggregate_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const layout = SavedLayout{
        .name = "release",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &.{},
        .routes = saved,
        .fabrication_layers = &.{.{ .name = "backing.gbr", .regions = &.{&poly} }},
    };
    try std.testing.expect(!lowerSavedManufacturing(aggregate_alloc.allocator(), &placement, layout).complete);
}
