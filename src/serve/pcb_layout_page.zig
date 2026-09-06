//! GET /pcb-layout/:name — interactive force-directed placement preview, and
//! the request-facing half of the PCB editor.
//!
//! The server evaluates the design, runs the optimizer, and emits the result
//! as JSON plus a small client renderer. The board is drawn client-side so
//! parts can be **dragged** (snapping to the 0.1 mm grid) and the layout
//! **score** (HPWL + decoupling-loop length) recomputes live — letting you
//! compare a hand placement against the auto one. A sidebar lists every
//! component and the net on each pin; hovering cross-highlights, and hovering
//! a pad (or net chip) reds every pad on that net.
//!
//! This module owns what a REQUEST decides: which board and which saved layout
//! the caller means (`chooseLayout` and the `LayoutSource` ladder), the page
//! and API route handlers, the sidecar reads and writes behind them, and the
//! shown-view resolution the rest of the split shares. What it hands off:
//!
//!   * `pcb_layout_chrome.zig` — the page's HTML and CSS
//!   * `pcb_layout_blob.zig`   — the JSON the board renderer reads
//!   * `pcb_layout_fab.zig`    — fab view, readiness gate, Gerbers, release
//!   * `pcb_layout_mcp.zig`    — the agent-facing layout-mutation tools
//!   * `pcb_layout_seeds.zig`  — sub-circuit routing seeds
//!
//! Those five take already-resolved inputs and never read a request; the
//! aliases below re-export the names their callers reach through this module,
//! so the split is invisible outside the six files.

const std = @import("std");
const httpz = @import("httpz");
const paths = @import("../paths.zig");
const bom = @import("../bom.zig");
const board_layers = @import("../board_layers.zig");
const board_theme = @import("../board_theme.zig");
const layer_table_json = @import("layer_table_json.zig");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const process_alloc = @import("../infra/process_alloc.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const na = @import("../eval/net_analysis.zig");
const optimizer = @import("../placement/optimizer.zig");
const pose_math = @import("../placement/pose_math.zig");
const impedance = @import("../placement/impedance.zig");
const via_antipad = @import("../placement/via_antipad.zig");
const geometry = @import("../placement/geometry.zig");
const lib_limits = @import("../lib_limits.zig");
const router = @import("../placement/router.zig");
const route_cleanup = @import("../placement/route_cleanup.zig");
const land_transit = @import("../placement/land_transit.zig");
const bend_smooth = @import("../placement/bend_smooth.zig");
const rf_port_report = @import("../placement/rf_port_report.zig");
const rf_path_solver = @import("../placement/rf_path_solver.zig");
const route_score = @import("../placement/route_score.zig");
const drc = @import("../placement/drc.zig");
const drc_json = @import("drc_json.zig");
const drc_rules = @import("drc_rules.zig");
const route_cleanup_gate = @import("../route_cleanup_gate.zig");
const outline_mod = @import("../placement/outline.zig");
const shape_sketch = @import("../shape_sketch.zig");
const shape_sketch_json = @import("shape_sketch_json.zig");
const via_fence = @import("../placement/via_fence.zig");
const perimeter_fence = @import("../placement/perimeter_fence.zig");
const pcb_keepout_json = @import("pcb_keepout_json.zig");
const pour = @import("../placement/pour.zig");
const pour_json = @import("pour_json.zig");
const drc_reconcile = @import("../drc_reconcile.zig");
const page_cache = @import("page_cache.zig");
const png_cache = @import("png_cache.zig");
const pcb_rules_json = @import("pcb_rules_json.zig");
const pcb_query = @import("pcb_query.zig");
const pcb_derived = @import("pcb_derived.zig");
const pcb_page_cache = @import("pcb_page_cache.zig");
const trace_em_json = @import("trace_em_json.zig");
const power_integrity_json = @import("../power_integrity_json.zig");
const export_fab = @import("../export_fab.zig");
const export_gerber = @import("../export_gerber.zig");
const panelize = @import("../panelize.zig");
const panel_export = @import("panel_export.zig");
const fab_identity = @import("../fab_identity.zig");
const fab_preview = @import("../fab_preview.zig");
const subcircuit_silkscreen = @import("../subcircuit_silkscreen.zig");
const fab_readiness = @import("../fab_readiness.zig");
const fab_gate = @import("../fab_gate.zig");
const fab_package = @import("../fab_package.zig");
const fab_release = @import("../fab_release.zig");
const fab_filename = @import("fab_filename.zig");
const standalone_assembly = @import("standalone_assembly.zig");
const subprocess = @import("subprocess.zig");

// One spelling feeds both the downloaded package and the parsed CAM preview.
const zipfile = @import("../zipfile.zig");
const module_policy = @import("../placement/module_policy.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const route_policy = @import("../placement/route_policy.zig");
const reference_guides = @import("../kicad_pcb/reference_guides.zig");
const pcb_snapshot = @import("../kicad_pcb/snapshot.zig");
const route_diagnose = @import("../placement/route_diagnose.zig");
const modules_mod = @import("modules.zig");
const netlist = @import("../export_kicad_netlist.zig");
const export_kicad = @import("../export_kicad.zig");
const export_kicad_footprint = @import("../export_kicad_footprint.zig");
const review = @import("../review.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const render_thermal_png = @import("../render_thermal_png.zig");
const thermal = @import("../eval/thermal.zig");
const thermal_scenarios = @import("../thermal_scenarios.zig");
const thermal_api = @import("thermal_api.zig");
const authored_heatsink = @import("../authored_heatsink.zig");
const font5x7 = @import("../font5x7.zig");
const png_mod = @import("../png.zig");
const assets_css = @import("assets_css.zig");
const pages_tmpl = @import("templates/pages.zig");
const diag_format = @import("diag_format.zig");
const serve_root = @import("../serve.zig");
const route_plan = @import("route_plan.zig");
const route_resume = @import("../route_resume.zig").ManualCompletion;
const subcircuit_route = @import("subcircuit_route.zig");
const subcircuit_seed_drc = @import("../subcircuit_seed_drc.zig");
const placement_outline = @import("placement_outline.zig");
const route_copper_state = @import("../route_copper_state.zig");
const route_result_stats = @import("route_result_stats.zig");
const stuck_json = @import("stuck_json.zig");
const pcb_part_json = @import("pcb_part_json.zig");
const history = @import("history.zig");
const request_log = @import("request_log.zig");
const layout_save_layers = @import("../layout_save_layers.zig");
const build_id = @import("../build_id.zig");
const numeric = @import("../numeric.zig");
const escape = @import("../escape.zig");
const Server = serve_root.Server;
const sidecar_json = @import("layout_sidecar_json.zig");
const sidecar_store = @import("../layout_sidecar_store.zig");
const sidecar_types = @import("../layout_sidecar_types.zig");
const saved_zone = @import("saved_zone.zig");
const layout_layers = @import("layout_layers.zig");
const copper_ids = @import("copper_ids.zig");
const net_names = @import("../net_name.zig");

// ── CLI layout-mutation tools ──────────────────────────────────────────
//
// The tools themselves live in `pcb_layout_mcp.zig`; they are re-exported here
// so `mcp_tools.zig` and the other agent surfaces keep reaching them through
// this module's name, exactly as they did when the bodies were in this file.
const pcb_layout_blob = @import("pcb_layout_blob.zig");
const pcb_layout_fab = @import("pcb_layout_fab.zig");
const pcb_layout_seeds = @import("pcb_layout_seeds.zig");
const blessedLayout = fab_package.blessedLayout;
const pcb_layout_chrome = @import("pcb_layout_chrome.zig");
const pcb_layout_mcp = @import("pcb_layout_mcp.zig");

const routeArcOwnsTrack = @import("../saved_route_copper.zig").arcOwnsTrack;

/// The board data blob and its JSON field writers live in
/// `pcb_layout_blob.zig`; `pcb_describe.zig` reads this one through this module.
/// Sub-circuit routing seeds live in `pcb_layout_seeds.zig`; the route
/// surfaces, the benchmarks and the describe/plan modules reach them here.
pub const SubcircuitRouteSeedStats = pcb_layout_seeds.SubcircuitRouteSeedStats;
pub const addSubcircuitRouteSeeds = pcb_layout_seeds.addSubcircuitRouteSeeds;
pub const routeWithSubcircuitSeeds = pcb_layout_seeds.routeWithSubcircuitSeeds;
pub const diagnoseWithSubcircuitSeeds = pcb_layout_seeds.diagnoseWithSubcircuitSeeds;
pub const writeRouteSeedStats = pcb_layout_seeds.writeRouteSeedStats;

/// The manufacturing surface — fab view, readiness gate, Gerber/centroid/drill
/// endpoints and the release lock — lives in `pcb_layout_fab.zig`; the CLI
/// dumps, the review snapshot and the release service reach it through here.
pub const FabView = pcb_layout_fab.FabView;
pub const FabViewError = pcb_layout_fab.FabViewError;
pub const FabAuthored = pcb_layout_fab.FabAuthored;
pub const FabReleaseTestSupport = pcb_layout_fab.FabReleaseTestSupport;
pub const fabViewFor = pcb_layout_fab.fabViewFor;
pub const fabViewForResolved = pcb_layout_fab.fabViewForResolved;
pub const pcbCentroidApi = pcb_layout_fab.pcbCentroidApi;
pub const pcbDrillApi = pcb_layout_fab.pcbDrillApi;
pub const pcbFabReadinessApi = pcb_layout_fab.pcbFabReadinessApi;
pub const pcbGerbersApi = pcb_layout_fab.pcbGerbersApi;
pub const standaloneDossierReviewBoardHtml = pcb_layout_fab.standaloneDossierReviewBoardHtml;
pub const standaloneReleaseAssemblyHtml = pcb_layout_fab.standaloneReleaseAssemblyHtml;

pub const writePerNetJson = pcb_layout_blob.writePerNetJson;
pub const writePcbDerivedData = pcb_layout_blob.writePcbDerivedData;

pub const mcpArgStrList = pcb_layout_mcp.mcpArgStrList;
pub const mcpReadWorking = pcb_layout_mcp.mcpReadWorking;
pub const mcpWorkingName = pcb_layout_mcp.mcpWorkingName;
pub const mcpPersistWorking = pcb_layout_mcp.mcpPersistWorking;
pub const mcpSavedRoutesFrom = pcb_layout_mcp.mcpSavedRoutesFrom;
pub const mcpSetPartPoses = pcb_layout_mcp.mcpSetPartPoses;
pub const mcpSetBoardOutline = pcb_layout_mcp.mcpSetBoardOutline;
pub const mcpSetCopperZones = pcb_layout_mcp.mcpSetCopperZones;
pub const mcpRoutePcb = pcb_layout_mcp.mcpRoutePcb;
pub const mcpSavePcbLayout = pcb_layout_mcp.mcpSavePcbLayout;
pub const mcpClearRoutes = pcb_layout_mcp.mcpClearRoutes;
pub const mcpCleanRouteTopology = pcb_layout_mcp.mcpCleanRouteTopology;
pub const mcpNormalizeJunctions = pcb_layout_mcp.mcpNormalizeJunctions;
pub const normalizeJunctionsApi = pcb_layout_mcp.normalizeJunctionsApi;
pub const mcpRepairLandTransit = pcb_layout_mcp.mcpRepairLandTransit;
pub const mcpStitchGroundPads = pcb_layout_mcp.mcpStitchGroundPads;
pub const mcpAddTracks = pcb_layout_mcp.mcpAddTracks;
// JSON leaf parsers split into layout_sidecar_json.zig; aliased so the many
// in-file callers (and the sidecar read/write paths) keep their spelling.
const jsonNum = sidecar_json.jsonNum;
const jsonOptNum = sidecar_json.jsonOptNum;
const jsonInt = sidecar_json.jsonInt;
const jsonSide = sidecar_json.jsonSide;
const jsonFlag = sidecar_json.jsonFlag;
const jsonStrField = sidecar_json.jsonStrField;
const parsePartPoses = sidecar_json.parsePartPoses;
const parsePartEdgeDimensions = sidecar_json.parsePartEdgeDimensions;
/// Re-exported for the KiCad sync (module-★ copper parsing).
pub const parseSavedRoutes = sidecar_json.parseSavedRoutes;
const parseSavedOutline = sidecar_json.parseSavedOutline;
const parseSavedFabricationLayers = sidecar_json.parseSavedFabricationLayers;
const parseSavedHeatsink = sidecar_json.parseSavedHeatsink;
const parseSavedFan = sidecar_json.parseSavedFan;
const parseSavedTexts = sidecar_json.parseSavedTexts;
const parseOutlinePts = sidecar_json.parseOutlinePts;
pub const writeJsonStr = sidecar_json.writeJsonStr;

pub const HandlerError = sidecar_store.StoreError || fab_preview.Error || error{
    InvalidReadinessJson,
    StandaloneAssemblyRenderFailed,
    AssetMissing,
};

// SVG framing.
const scale_min: f64 = 6.0; // px per mm
const scale_max: f64 = 48.0;
const target_px: f64 = 1000.0; // desired content width/height
/// The framing margin is the PNG renderer's, not a second opinion: the served
/// SVG and `/api/pcb-png` must frame one board identically or a cross-probe
/// lands on different pixels in the two surfaces.
const view_margin_mm = render_pcb_png.view_margin_mm;

/// Legacy standalone optimizer-cache sidecar. The cache now lives in the
/// `"cache"` key of `.layouts.json` (one sidecar per design); this file is
/// still read as a fallback for boards last solved by an older build, and
/// is deleted the next time the cache is written.
const auto_ext = ".autolayout.json";

/// JSON key prefix shared by every `{"ref": …}` record we emit.
const ref_open = "{\"ref\":";
/// JSON object opener shared by the placement-export / saved-layout records.
pub const name_open = "{\"name\":";
/// JSON key + open bracket shared by the layout/cache/export part arrays.
pub const parts_open = "\"parts\":[";
/// JSON `,"origin":` key shared by the part records that carry the renumber-
/// stable origin key (saved-layout disk + page JSON, live PCB.parts).
pub const origin_open = ",\"origin\":";
pub const net_json_key = ",\"net\":";
/// JSON `,"texts":` key shared by the sidecar, the page blob, and the
/// per-layout Load records (board-level silkscreen text array).
pub const texts_open = ",\"texts\":";
/// JSON `,"outline":` key shared by the sidecar writer, the page blob, and the
/// CLI `set_board_outline` response.
pub const outline_open = ",\"outline\":";
pub const fabrication_layers_open = ",\"fabrication_layers\":";
/// Error bodies shared across the layout handlers.
pub const no_block_msg = "No design or module by that name";
/// Response header name the fab-output endpoints set their MIME type on.
pub const ct_hdr = "content-type";
/// Returned when `?sub=<slug>` names a sub-block that doesn't exist in the design.
pub const no_sub_msg = "No sub-block by that name";
const bad_json_msg = "bad json";
pub const placement_err_msg = "Placement error";
/// Returned by the fab endpoints when a design has no saved layout at all —
/// fab outputs are only meaningful for a deliberately placed board.
pub const no_saved_layout_msg = "no saved layout — place the board (and save/star a layout) first";
/// Returned when routing (or its scope resolution) fails server-side.
const routing_err_msg = "Routing error";
/// JSON body/query key for the copper-to-copper clearance rule (mm).
const clearance_key = "clearance";

/// Success body returned by the mutating layout/courtyard endpoints.
const ok_json_true = "{\"ok\":true}";

/// The one layout sidecar per design: every *named* saved layout (manual
/// snapshots the user named plus an auto-recorded history of optimizer
/// runs) under `"layouts"`, the KiCad-sync `"default"` marker, and the
/// single-slot optimizer cache under `"cache"`.
pub const layouts_ext = sidecar_store.layouts_ext;

/// Ceiling on a `.layouts.json` read. A board carrying several ROUTED saved
/// layouts legitimately runs to megabytes — each one stores its own copper —
/// so the old 1 MiB cap silently truncated real boards to ZERO layouts, taking
/// the viewer, the KiCad sync seed and the fab outputs down with them (they all
/// resolve the ★ through this same read). Generous on purpose; the read still
/// refuses to pull an unbounded file into memory.
pub const sidecar_max_bytes = sidecar_store.sidecar_max_bytes;

/// Layout `kind` tags. `manual` = a snapshot the user saved by name; `auto` =
/// one recorded automatically each time the optimizer regenerated.
pub const kind_manual = sidecar_store.kind_manual;
const kind_auto = sidecar_store.kind_auto;

/// Cap on auto-recorded entries kept per design. On each record the oldest
/// auto entries past this are pruned; manual snapshots are never auto-pruned.
/// One placed part within a saved layout: ref-des + centre (mm) + rotation,
/// plus the renumber-stable `origin` (the part's module-local `origin_key`).
/// The ref-des is volatile — it shifts when the part renumbers or when the
/// same module is flattened from a different context (standalone vs as a
/// sub-block of a parent board, which produces different counters). `origin`
/// is the module-local source name, invariant across both, so a Load matches
/// on it first and falls back to `ref` only for legacy entries saved before
/// `origin` was recorded (empty string); a stale pose whose `ref` a live part
/// inherited through renumbering is dropped rather than applied. See
/// `rekeyPosesByOrigin`.
pub const PartPose = sidecar_types.PartPose;

/// One driving PCB-editor dimension from a footprint origin to a straight
/// board-outline edge. `axis` is `"x"` for a horizontal dimension to a
/// vertical edge and `"y"` for a vertical dimension to a horizontal edge.
/// `edge_id` is the stable curve id in `SavedOutline.sketch`; `offset` is the
/// signed origin coordinate minus the edge coordinate, so moving that edge
/// repositions only the constrained axis of the footprint.
pub const SavedPartEdgeDimension = sidecar_types.SavedPartEdgeDimension;

/// The weighted `objective` the optimizer minimizes plus its visible HPWL +
/// decoupling-loop terms, stored with a layout so the list shows "better/worse"
/// at a glance without re-running the optimizer. `objective` is 0 for legacy
/// entries saved before it was recorded.
const LayoutScore = sidecar_types.LayoutScore;

/// One physical heatsink authored on a saved PCB layout. The rectangle
/// is the base/contact footprint in board coordinates; `side` is the physical
/// PCB face, not a package-relative direction. Its thermal pad couples every
/// covered board cell to the passive sink; no component target is required.
pub const SavedHeatsink = sidecar_types.SavedHeatsink;
pub const SavedFan = sidecar_types.SavedFan;

/// A named saved layout: name, kind, capture time (unix s, 0 = unknown),
/// optional score, and the placement itself (newest first within a file).
/// `default` marks the one layout the KiCad sync seeds first-insertion
/// placement + vias from; it's stored once at the top level of the file
/// (`"default":"<name>"`) and reflected here on the matching entry. At most
/// one entry has `default = true`.
pub const SavedLayout = sidecar_types.SavedLayout;

/// Canonical creator tags persisted on saved tracks and vias. Known values are
/// `human` (the PCB editor), `agent` (`add_tracks`), `autorouter` (route/repair
/// engines), and `imported` (KiCad). The empty default is deliberately
/// `unknown`: old sidecars predate provenance and must not be relabelled on
/// their next save.
pub const route_source_human = sidecar_types.route_source_human;
pub const route_source_agent = sidecar_types.route_source_agent;
pub const route_source_autorouter = sidecar_types.route_source_autorouter;
pub const route_source_imported = sidecar_types.route_source_imported;

/// One persisted routed-copper segment of a saved layout. Field names match
/// the live route JSON (`l` layer, `w` width; net by NAME — net indices shift
/// across flattens), so the client draws stored and live copper identically.
/// `g` is the stamp group tag: copper stamped from a sub-block module layout
/// carries its group slug so a rigid-group drag moves it along instead of
/// invalidating it. `source` records the segment's creator; empty means a
/// legacy layout whose provenance is unknown. `id` is the stable, user-visible
/// segment handle shown by the inspector. Legacy empty IDs are deterministically
/// derived when serialized, so merely saving an old layout backfills them.
pub const SavedTrack = sidecar_types.SavedTrack;

/// One persisted via of a saved layout (same shape as the live route JSON).
/// `f` is fence provenance: an RF-fenced net name, or the reserved
/// `@perimeter` tag for a board-derived outline fence. It is deliberately NOT
/// `g` — a `g` tag means "stamped module copper", which is exempt from net-keyed
/// clearing and is parsed as a ref-des prefix. RF fences invalidate with the
/// trace they flank; perimeter sites are replaced from the board declaration.
///
/// `s` is the barrel's LAYER SPAN, `[from,to]` routable indices persisted as
/// `"s":[a,b]`; ABSENT (every board here today) is the full-stack through via
/// every consumer still assumes — schema groundwork, resolved by
/// `layout_layers`. `source` has the same creator-tag semantics as SavedTrack.
/// `id` is the stable, user-visible handle shown by the inspector, with legacy
/// empty IDs deterministically backfilled on serialization.
pub const SavedVia = sidecar_types.SavedVia;

/// Persisted custom/KiCad copper-zone geometry shared with sidecar consumers.
pub const SavedZone = sidecar_types.SavedZone;
const savedZoneLayers = saved_zone.layers;
const savedZonePrimaryLayer = saved_zone.primaryLayer;

/// A saved layout's persisted copper — routed tracks/vias plus optional
/// imported KiCad zone polygons. The default keeps old sidecars and existing
/// struct literals source-compatible.
pub const SavedRoutes = sidecar_types.SavedRoutes;
const SavedRfPath = sidecar_types.SavedRfPath;
/// Replace any persisted board-derived ring with the ring implied by the
/// CURRENT outline and DSL. This makes a saved layout a cache of the generated
/// vias, never their authority: outline/rule edits cannot leave stale barrels.
pub const SavedRoutesEvidence = struct {
    routes: ?SavedRoutes,
    complete: bool,
};

pub fn routesWithPerimeterEvidence(alloc: std.mem.Allocator, placement: optimizer.Placement, base: ?SavedRoutes) SavedRoutesEvidence {
    const old = base orelse SavedRoutes{ .tracks = &.{}, .vias = &.{} };
    var vias: std.ArrayList(SavedVia) = .empty;
    for (old.vias) |via| {
        if (std.mem.eql(u8, via.f, perimeter_fence.provenance)) {
            const serves_pad = perimeter_fence.viaServesPad(alloc, placement, via.net, via.x, via.y, via.d) catch
                return .{ .routes = base, .complete = false };
            if (!serves_pad) continue;
            var adopted = via;
            adopted.f = "";
            vias.append(alloc, adopted) catch return .{ .routes = base, .complete = false };
            continue;
        }
        vias.append(alloc, via) catch return .{ .routes = base, .complete = false };
    }
    const restored = restoreRoutes(alloc, .{ .tracks = old.tracks, .vias = vias.items, .zones = old.zones, .rf_paths = old.rf_paths }, placement.nets) orelse
        return .{ .routes = base, .complete = false };
    const sites = if (perimeter_fence.append(alloc, placement, restored) catch
        return .{ .routes = base, .complete = false }) |result| result.vias else &.{};
    for (sites) |site| {
        const net = pcb_layout_blob.netNameOf(placement.nets, site.net);
        var found = false;
        for (vias.items) |via| {
            if (std.ascii.eqlIgnoreCase(via.net, net) and
                std.math.hypot(via.x - site.x, via.y - site.y) < drc.eps)
            {
                found = true;
                break;
            }
        }
        if (!found) vias.append(alloc, .{
            .x = site.x,
            .y = site.y,
            .d = site.dia,
            .drill = site.drill,
            .net = net,
            .f = perimeter_fence.provenance,
            .source = route_source_autorouter,
        }) catch return .{ .routes = base, .complete = false };
    }
    if (base == null and vias.items.len == 0) return .{ .routes = null, .complete = true };
    return .{ .routes = .{ .tracks = old.tracks, .vias = vias.items, .zones = old.zones, .rf_paths = old.rf_paths }, .complete = true };
}

pub fn routesWithPerimeter(alloc: std.mem.Allocator, placement: optimizer.Placement, base: ?SavedRoutes) ?SavedRoutes {
    return routesWithPerimeterEvidence(alloc, placement, base).routes;
}

/// "ref\x00pad" / "prefix\x00origin" composite hash keys.
pub const pin_key_fmt = "{s}\x00{s}";

/// A user-DRAWN board outline (world mm) captured with a saved layout — the
/// interactive counterpart of the authored `(board (size W H))` form (the
/// ▭ Outline / ⬠ Poly tools: rough-place first, then draw the board around
/// it). When the shown layout carries one it becomes the placement's
/// `board_rect`, so every renderer draws it and the board-edge DRC checks it.
/// `pts` is the closed-polygon vertex list of a ⬠ Poly outline; when set,
/// x/y/w/h are always its bounding box (derived at parse time, so the two
/// can never disagree). Null `pts` = a plain drawn rectangle.
pub const SavedOutline = sidecar_types.SavedOutline;

/// Per-layout editable positive polygons for one authored backing layer.
/// Material, thickness, side, and footprint-cutout policy stay in source.
pub const SavedFabricationLayer = sidecar_types.SavedFabricationLayer;

/// Which layout state the page is showing — the precedence ladder made
/// visible in the scorebar chip: source **spec** > saved **snapshot**
/// (`?refine=`) > **starred** default > **cache** slot > **fresh** solve >
/// plain **grid**. `starred` is the design's ★-marked layout, loaded verbatim
/// as the default page view when nothing more specific is asked for.
pub const LayoutSource = enum { spec, snapshot, starred, cache, fresh, grid };

/// Which named saved layout the request asked for, if any — the two query
/// parameters that outrank the starred default. `view` (`?layout=<name>`) is
/// the **direct link**: show that snapshot verbatim, exactly as saved, so a
/// URL names one specific placement + routing. `refine` (`?refine=<name>`)
/// seeds the same snapshot into a routed-tuck re-solve instead. At most one is
/// meaningful; `view` wins when both are present.
const LayoutSelect = struct {
    view: ?[]const u8 = null,
    refine: ?[]const u8 = null,

    /// The named snapshot this request selects, whichever way it asked.
    fn named(self: LayoutSelect) ?[]const u8 {
        return self.view orelse self.refine;
    }
};

/// The layout name the page ADOPTS as its edit target — the row Update and the
/// idle autosave write into. Only a row rendered VERBATIM qualifies: the
/// explicit `?layout=` view, else the starred default. A `?refine=` re-solve
/// is never adopted — what renders is the SOLVER's output, and adopting the
/// seed row's name would let a single drag idle-autosave that output over the
/// hand-saved board.
fn adoptedLayoutName(sel: LayoutSelect, starred_name: ?[]const u8) ?[]const u8 {
    return sel.view orelse (if (sel.refine == null) starred_name else null);
}

/// Name the rung of the precedence ladder the shown placement came from,
/// mirroring the selection logic at the top of `pcbLayoutPage`.
fn classifyLayoutSource(
    sub: ?[]const u8,
    grid_only: bool,
    spec_drives: bool,
    sel: LayoutSelect,
    starred_name: ?[]const u8,
    cached: ?[]const optimizer.RefPose,
) LayoutSource {
    if (sub != null) return .fresh;
    if (grid_only) return .grid;
    if (spec_drives) return .spec;
    if (sel.named() != null and cached != null) return .snapshot;
    if (starred_name != null and cached != null) return .starred;
    if (cached != null) return .cache;
    return .fresh;
}

/// Body for the 404 a `?layout=<name>` direct link gets when no saved layout
/// answers to that name — a deleted or renamed snapshot, or a typo'd link. Names
/// the layouts that DO exist so the reader can pick the one they meant instead
/// of guessing. Falls back to the bare sentence if the listing can't be built.
pub fn unknownLayoutMsg(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    want: []const u8,
) []const u8 {
    const saved = readLayoutsSub(alloc, project_dir, name, sub);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.print("no saved layout named \"{s}\" on {s}", .{ want, name }) catch return no_layout_msg;
    if (saved.len == 0) {
        w.writeAll(" — this design has no saved layouts yet") catch return no_layout_msg;
    } else {
        w.writeAll(" — saved layouts are: ") catch return no_layout_msg;
        for (saved, 0..) |L, i| {
            w.print("{s}\"{s}\"", .{ if (i > 0) ", " else "", L.name }) catch return no_layout_msg;
        }
    }
    return aw.written();
}

/// Fallback body when `unknownLayoutMsg` cannot build its listing.
const no_layout_msg = "no saved layout by that name";

/// The page's resolved placement source: the spec/starred flags the scorebar
/// chip reads, plus the seed poses + grid fallback the solve uses. `verbatim`
/// means the poses are a user-saved layout and must render exactly as saved
/// (`placeFromPoses`), never through `solve`'s apply-or-re-solve ladder — a
/// hand layout with a courtyard overlap is still the user's layout, not a
/// stale cache to discard.
const LayoutChoice = struct {
    spec_drives: bool,
    starred_name: ?[]const u8,
    cached: ?[]const optimizer.RefPose,
    grid_only: bool,
    verbatim: bool,
};

/// Decide which placement `pcbLayoutPage` renders, walking the precedence ladder:
/// explicit `?layout=` / `?refine=` snapshot > `(placement …)` spec > the design's
/// starred (★) default saved layout > the auto cache > a plain grid. A `?refine=`
/// seed runs the routed-tuck refine; every other seed (`?layout=`, starred, cache)
/// renders verbatim via the `.place` mode. Sub-scoped previews never read a
/// sidecar — they solve fresh and cheap, so all four flags collapse to
/// "solve from scratch".
fn chooseLayout(
    alloc: std.mem.Allocator,
    sub: ?[]const u8,
    eff_block: *env_mod.DesignBlock,
    sel: LayoutSelect,
    tune: Tuning,
    doc: SidecarDoc,
) LayoutChoice {
    // No authored PCB-placement spec exists any more — the board always solves
    // via the force / starred-seed / cache ladder below.
    const spec_drives = false;
    // With no named layout asked for, no regen/tuning and no sub preview, default
    // the page to the design's starred (★) layout if it has one — the user's
    // blessed reference, shown verbatim as the seed below.
    const want_default = !(sel.named() != null or tune.regen or tune.tuned or tune.show_cache);
    // A sub circuit seeds from its own per-sub sidecar (`doc` is read from
    // the per-sub store), so a starred sub layout shows verbatim on reload just
    // like a design's. Sub circuits have no auto-cache slot, so when nothing is
    // starred they solve fresh (never the plain-grid placeholder).
    const starred_name: ?[]const u8 = if (want_default)
        defaultLayoutNameIn(doc.layouts)
    else
        null;
    var cached = if (sel.named()) |sn|
        layoutPosesIn(alloc, doc.layouts, sn, eff_block)
    else if (starred_name) |sn|
        layoutPosesIn(alloc, doc.layouts, sn, eff_block)
    else if (tune.regen) null else if (sub == null) cachePoses(alloc, doc.cache) else null;
    // "Rough remaining" is a regen, but one seeded with a base to pin: the ★
    // layout preferred, else the auto cache. The solve locks what the base
    // covers and places only the uncovered parts (`Params.remaining`); with
    // no base at all it degrades to a plain fresh rough.
    if (tune.params.remaining and sel.named() == null) {
        const star_base = if (defaultLayoutNameIn(doc.layouts)) |dn|
            layoutPosesIn(alloc, doc.layouts, dn, eff_block)
        else
            null;
        const fallback = cached orelse (if (sub == null) cachePoses(alloc, doc.cache) else null);
        cached = star_base orelse fallback;
    }
    // No layout to show and nothing asked for one: place the parts on a plain grid
    // instead of running the (potentially expensive) optimizer on page open.
    // (Sub circuits always solve fresh instead — there's no grid placeholder.)
    const grid_only = sub == null and sel.named() == null and !tune.regen and cached == null;
    // A starred saved layout — or one asked for by name via `?layout=` — is the
    // user's hand state: render it VERBATIM. Routing it through `solve` would let
    // `applyCached` reject it on any courtyard overlap (normal mid-floor-planning,
    // e.g. right after a Stamp) and silently re-solve — the "I saved, refreshed,
    // and my edits vanished" bug. `?refine=` is the one seed that asks to re-solve.
    const verbatim = (sel.view != null or starred_name != null) and cached != null;
    return .{ .spec_drives = spec_drives, .starred_name = starred_name, .cached = cached, .grid_only = grid_only, .verbatim = verbatim };
}

/// Run the placement a resolved `LayoutChoice` calls for: the plain grid
/// placeholder, the saved layout verbatim (`placeFromPoses` — never re-solved,
/// even with courtyard overlaps), or a (possibly seeded) solve / refine.
fn placeForChoice(
    alloc: std.mem.Allocator,
    eff_block: *env_mod.DesignBlock,
    project_dir: []const u8,
    choice: LayoutChoice,
    sel: LayoutSelect,
    params: optimizer.Params,
) std.mem.Allocator.Error!optimizer.Placement {
    if (choice.grid_only) return optimizer.gridPlace(alloc, eff_block, project_dir, params);
    // Outline: the page folds the shown/blessed drawn outline post-build in
    // resolveShownView (shared with the solve/grid branches, which have no
    // pose seed), so the seed itself stays authored-only here.
    if (choice.verbatim) return optimizer.placeFromPoses(alloc, eff_block, project_dir, .{ .poses = choice.cached.?, .outline = .authored_only }, params);
    return optimizer.solve(alloc, eff_block, project_dir, choice.cached, params, if (sel.refine != null) .refine else .place);
}

/// Resolve a page handler's optional `?sub=<slug>` scope: null when the
/// request isn't sub-scoped; writes the 404 and errors when the slug names no
/// sub-block of `block`.
fn pageSubBlock(
    ctx: *Server,
    req: ?*httpz.Request,
    res: ?*httpz.Response,
    block: *env_mod.DesignBlock,
) error{SubNotFound}!?env_mod.SubBlock {
    const s = subSlug(req) orelse return null;
    return descendToSub(ctx.allocator, block, s) orelse {
        if (res) |r| {
            r.status = 404;
            r.body = no_sub_msg;
        }
        return error.SubNotFound;
    };
}

/// The page cache's store-time question: has the layout sidecar's
/// optimistic-concurrency rev moved since this render read it? Render-path
/// writes (persistGeneratedLayout, displayLayouts dedup, recordAutoLayout)
/// PRESERVE the rev, so only a user Save/Update landing mid-render moves it —
/// and such a page must not be retained. Its dependency stamps are taken after
/// that save, so the entry would validate while serving HTML whose `PCB.rev` is
/// already one behind: every Save from it 409s "layout changed in another
/// window", and a refused save writes nothing, so the sidecar mtime never moves
/// and the entry never invalidates — reloading serves the same doomed page
/// forever. `rendered < 0` means this render never read a sidecar (an error
/// path bailed first), which nothing can have moved.
///
/// Adapted into the page cache's duck-typed `layout_rev` slot rather than read
/// there, so the cache keeps its one-way dependency on `page_cache` alone; the
/// probe runs AFTER stamping, which is what leaves no window (a save landing
/// later is a write the stamps predate, so it invalidates the entry the
/// ordinary way).
pub const StoreRevCheck = struct {
    rendered: i64,
    ctx: *Server,
    name: []const u8,
    sub: ?[]const u8,

    /// Whether the layout sidecar's rev has moved past the one this render read.
    pub fn moved(self: StoreRevCheck) bool {
        if (self.rendered < 0) return false;
        return readLayoutRev(self.ctx.allocator, self.ctx.project_dir, self.name, self.sub) != self.rendered;
    }
};

/// Everything a PCB page render needs beyond the server and the request —
/// bundled so the renderer stays under the function-size cap and the boot
/// warm-up can build one with no request at all. `rev` is the caller's
/// store-time freshness check: the render fills in the layout sidecar's rev
/// and `?sub=` scope it read, and the page cache asks `moved()` after
/// stamping (see `StoreRevCheck`).
pub const RenderJob = struct {
    name: []const u8,
    eval: *Evaluator,
    module_res_out: *?modules_mod.ResolvedBlock,
    rev: *StoreRevCheck,
    /// Set to take EVERY response one solve can answer — the page, the
    /// after-paint payload, the impedance sweep — publishing each through the
    /// sink as it lands. See `pcb_derived`. Only the deferrable editor page
    /// produces the extras; every other surface publishes just its page.
    both: ?pcb_derived.BothPayloads = null,
};

/// GET /pcb-layout/:name — evaluate the design, run the optimizer, and return
/// the interactive (drag + live-score) inline-SVG preview with a sidebar.
pub fn pcbLayoutPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    var cache_version: ?u32 = null;
    if (ctx.state.caches.pcb_pages.serve(.{ .scratch = ctx.allocator, .name = name, .live_version = serve_root.getLiveVersion(name) }, req, res, &cache_version)) return;

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    // The layout sidecar's rev as this render read it (see `doc` below), and the
    // `?sub=` scope it was read under. The page cache asks them at store time —
    // a Save that landed mid-render makes this HTML unfit to retain.
    var rev_check = StoreRevCheck{ .rendered = -1, .ctx = ctx, .name = name, .sub = null };
    defer ctx.state.caches.pcb_pages.store(.{ .scratch = ctx.allocator, .project_dir = ctx.project_dir, .name = name, .req = req, .eval = &eval, .res = res, .live_version = cache_version, .current_version = serve_root.getLiveVersion(name), .layout_rev = rev_check });
    const html = (try renderLayoutPage(ctx, req, res, .{
        .name = name,
        .eval = &eval,
        .module_res_out = &module_res,
        .rev = &rev_check,
    })) orelse return;
    res.content_type = if (queryFlag(req, "derived")) .JSON else .HTML;
    res.body = html;
    // This render was a cache MISS on the plain editor page, which means an
    // edit just invalidated BOTH halves — and the browser about to receive this
    // HTML will ask for the second one as soon as it has painted. Start that
    // render now instead of at the end of the download-parse-paint gap; the
    // cache's in-flight reservation makes the browser's fetch join it.
    if (cache_version != null and pcb_derived.warmsDeferred(req)) pcb_derived.spawn(ctx, name);
}

/// GET /api/pcb-cam/:name — exact Gerber/Excellon read-back for Assembly.
///
/// The physical-review iframe paints its semantic board immediately, then
/// requests this payload after the first animation frame. Keeping the nearly
/// megabyte CAM object out of the HTML removes both its generation and parse
/// cost from first paint; the shared dependency-aware PCB cache makes later
/// page loads a normal cache hit.
pub fn pcbCamJsonApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    var cache_version: ?u32 = null;
    if (ctx.state.caches.pcb_pages.serve(.{ .scratch = ctx.allocator, .name = name, .live_version = serve_root.getLiveVersion(name) }, req, res, &cache_version)) return;

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const rev_check = StoreRevCheck{
        .rendered = readLayoutRev(ctx.allocator, ctx.project_dir, name, null),
        .ctx = ctx,
        .name = name,
        .sub = null,
    };
    defer ctx.state.caches.pcb_pages.store(.{
        .scratch = ctx.allocator,
        .project_dir = ctx.project_dir,
        .name = name,
        .req = req,
        .eval = &eval,
        .res = res,
        .live_version = cache_version,
        .current_version = serve_root.getLiveVersion(name),
        .layout_rev = rev_check,
    });

    var solved = solveForRequest(ctx.allocator, ctx.project_dir, name, .{
        .layout = queryOpt(req, "layout"),
    }, &eval, &module_res) catch |err| {
        const refusal = pngFailure(err);
        res.status = refusal.status;
        res.content_type = .JSON;
        res.body = refusal.json;
        return;
    };
    _ = applyFabricationLayerOverrides(ctx.allocator, &solved.placement, solved.shown_zones.fabrication_layers);
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try fab_preview.writeJson(&aw.writer, ctx.allocator, .{
        .enabled = true,
        .placement = solved.placement,
        .routed = solved.restored.routes,
        .zones = solved.shown_zones.user,
        .silk_keepouts = solved.shown_zones.silk_keepouts,
        .texts = solved.texts,
        .package = .{
            .frame = export_fab.frameFor(solved.placement),
            .drill_suffixes = .{ export_gerber.plated_drill_suffix, export_gerber.non_plated_drill_suffix },
        },
    });
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Refuse the render with `status`, writing it onto the response when there is
/// one. A warm-up render has no response to refuse into and simply gets the
/// null; every caller reads that the same way, so the guards below stay one
/// statement each whether or not a request is behind them.
fn refuse(res: ?*httpz.Response, status: u16, body: []const u8) ?[]const u8 {
    if (res) |r| {
        r.status = status;
        r.body = body;
    }
    return null;
}

/// Render the page body, or null when a guard refused (the status is written
/// into `res` when there is one). Split out of the handler so the boot warm-up
/// can pre-render a page with no live request: a null `req` reads through every
/// query helper as "no query at all", which is exactly the plain
/// `/pcb-layout/<name>` URL a first visitor asks for, and a null `res` drops
/// the error-status writes a warm caller has nothing to do with. The evaluator
/// and module handle stay with the caller because the page cache stamps the
/// files the evaluator loaded, which it can only do while it is still alive.
/// `job.rev` receives the layout sidecar's rev and `?sub=` scope this render
/// read, which the handler's store-time freshness check asks about after the
/// page is stamped.
pub fn renderLayoutPage(
    ctx: *Server,
    req: ?*httpz.Request,
    res: ?*httpz.Response,
    job: RenderJob,
) HandlerError!?[]const u8 {
    const name = job.name;
    const eval = job.eval;
    const module_res_out = job.module_res_out;
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, eval, module_res_out) orelse {
        // A source file that exists but failed to parse/evaluate is not a
        // missing design. Preserve the evaluator's source-located diagnostic
        // so the PCB page identifies the failing form/import just like the
        // schematic page and CLI do. A genuinely unknown name has no
        // diagnostic and remains the terse not-found response.
        if (try diag_format.designLoadPage(ctx.allocator, ctx.project_dir, name, eval)) |html| {
            if (res) |r| {
                r.status = 500;
                r.content_type = .HTML;
                r.body = html;
            }
            return null;
        }
        return refuse(res, 404, no_block_msg);
    };
    const module_res = module_res_out.*;
    // A `?sub=<slug>` request scopes the layout to a single sub-block — the
    // schematic page's per-sub-block preview — so only that sub-block's parts
    // are placed, never the whole design. `?embed=1` trims the page chrome
    // (navbar/sidebar/edit controls) for inline display in that preview frame.
    const sub = subSlug(req);
    const sub_block: ?env_mod.SubBlock = pageSubBlock(ctx, req, res, block) catch return null;
    const eff_block: *env_mod.DesignBlock = if (sub_block) |sb| sb.block else block;
    // Designs, modules and `?sub` sub circuits all keep saved-layout snapshots.
    const top_design = module_res == null and sub == null;
    const embed = isEmbed(req);
    // `?embed=1&edit=1` is the editable embed: trimmed chrome (no navbar / left
    // properties sidebar / 3D), but the full action toolbar + saved-layouts panel
    // and drag-to-edit enabled — the schematic page's per-sub-circuit "PCB Layout"
    // toggle iframes this so a layout can be roughed / dragged / saved / starred in
    // place. It applies both to a module's own page (no `?sub`) and to a `?sub=`
    // scoped sub circuit; the latter persists its saved layouts to a per-sub
    // sidecar (`<design>.<sub>.layouts.json`) via the `sub`-aware save endpoints.
    const edit_embed = embed and queryFlag(req, "edit");
    // The assembly/debug iframe is a distinct read-only presentation, not a
    // compact PCB-layout preview. It keeps the routed board data but omits
    // placement scores, optimizer legends, and route-overlay controls.
    const physical_review = isPhysicalReview(req, embed, edit_embed);
    // Assembly/debug opts its read-only physical-board embed into persistent
    // model images. Keep ordinary schematic embeds cheap and keep editable
    // embeds free of raster bodies that could obscure placement work.
    const model_sprites = if (physical_review) queryFlag(req, "model_sprites") else false;
    // `?thermal=1` — the thermal page's board pane. Same read-only physical
    // board every other reviewer sees, plus one overlay script that paints the
    // solved heat field over it and hides the copper underneath. Only in the
    // read-only review embed: a heat field over an EDITABLE board would invite
    // dragging parts against numbers solved for where they used to be.
    const thermal_overlay = physical_review and queryFlag(req, "thermal");
    // The ordinary editor's expensive copper-derived fields arrive from a
    // second, dependency-cached response after first paint. `?derived=1` runs
    // the complete calculation but emits only those fields, not a second page.
    const derived_only = queryFlag(req, "derived");
    // `?pdn=1` is the third tier: the PDN impedance sweep alone, which the
    // viewer fetches for itself once the board's own diagnostics have landed.
    const pdn_only = queryFlag(req, "pdn");
    const lean_payload = derived_only or pdn_only;
    const lean_read_only = physical_review or thermal_overlay or lean_payload;
    const review_toggles = parseToggles(req);

    // Tuning weights come from the query (?w_align=… etc) — any present (or
    // ?regen=1) forces a fresh solve; otherwise the cached layout is reused.
    // ?refine=<layout> seeds the solve from a named saved layout and runs only the
    // routed tuck on it (improve a hand layout in place; the auto cache is left as-is).
    // Sub-scoped previews never touch the design's layout sidecars: they compute
    // fresh each time (the sub-block is small, so this is cheap) so a scoped run
    // can't clobber the whole-design auto cache or its saved-layout history.
    const tune = parseTuning(req);
    // `?layout=<name>` is the direct link to one saved layout: render that
    // snapshot verbatim (poses + its saved copper/outline/texts), outranking the
    // ★ default, so a URL names a specific placement AND routing. `?refine=`
    // seeds the same snapshot into a re-solve instead.
    const sel: LayoutSelect = if (sub != null) .{} else .{
        .view = queryRaw(req, "layout"),
        .refine = queryRaw(req, "refine"),
    };
    // Only stable, saved-state editor views split their payload. One-shot
    // solve/route/refine requests keep their result atomic, while embeds retain
    // their existing purpose-built lean paths.
    const defer_analysis = !lean_payload and !embed and sub == null and
        !tune.regen and sel.refine == null and !queryFlag(req, "route");
    // The layout sidecar of a routed board runs to megabytes — read + parse it
    // ONCE here and derive everything below (the choose ladder, the panel
    // list, the shown tuning params, the embedded save rev) from this doc
    // rather than re-reading the file per question.
    const doc = readPageDoc(ctx, name, sub);
    // What the page will embed as `PCB.rev`, handed to the page cache's
    // store-time freshness check (`StoreRevCheck`) via the job's `rev` slot.
    job.rev.rendered = doc.rev;
    job.rev.sub = sub;
    // Resolve which placement the page renders, per the precedence ladder (see
    // chooseLayout): explicit ?layout=/?refine= snapshot > (placement …) spec >
    // starred ★ default > auto cache > plain grid. ?refine= seeds a routed-tuck
    // refine; every other seed renders verbatim. Sub previews always solve fresh.
    const choice = chooseLayout(ctx.allocator, sub, eff_block, sel, tune, doc);
    // A direct link that names no existing layout is a dead link, not a request
    // to show something else — say so rather than silently rendering a different
    // board under the URL the user shared.
    if (sel.view) |vn| if (choice.cached == null)
        return refuse(res, 404, unknownLayoutMsg(ctx.allocator, ctx.project_dir, name, sub, vn));
    const starred_name = choice.starred_name;
    var placement = placeForChoice(ctx.allocator, eff_block, ctx.project_dir, choice, sel, tune.params) catch
        return refuse(res, 500, placement_err_msg);
    // Persist the layout + its weights whenever the optimizer ran (miss /
    // stale / regen / tune) — see persistGeneratedLayout.
    persistGeneratedLayout(ctx, name, placement, tune.params, sub, top_design);
    // Module-layout stamp poses for the Stamp palette — whole-design pages
    // only (a ?sub scoped page IS one sub-circuit already).
    const subseeds: pcb_layout_seeds.SubSeedsJson = if (sub == null and !lean_read_only)
        pcb_layout_seeds.buildSubSeedsJson(ctx.allocator, ctx.project_dir, eff_block, placement)
    else
        .{};
    const shown = shownParams(sub, tune, placement.generated, doc);

    // The named-layout history is a whole-design concept; scoped previews show none.
    // Deduplicated + best-score-first for the panel (see displayLayouts).
    const layouts = panelLayouts(ctx, name, sub, placement.generated, doc);

    // Fold the shown layout's persisted extras (drawn outline, saved copper)
    // into the placement and resolve routing/DRC — see resolveShownView.
    // `rv.base_edge` is the board-edge margin field seeded once, after the
    // shown outline was applied, and threaded into every pour below.
    const rv = resolveShownView(ctx, req, .{
        .name = name,
        .placement = &placement,
        .layouts = layouts,
        .shown = if (sub == null) (sel.named() orelse starred_name) else null,
        .block = eff_block,
        // Assembly explicitly opens with `drc=0`: its parent has no DRC
        // surface, and computing hundreds of hidden markers delayed the first
        // board paint. Editable/full pages still receive the complete check.
        .check_drc = !physical_review or review_toggles.drc,
        // `?pdn=1` reads copper and the shared edge field, never markers. Its
        // caller already has the DRC from the payload before it. Assembly has
        // no route/DRC reporting surface either; its exact CAM and compact
        // route geometry need no whole-board connectivity raster.
        .reporting = needsPageReporting(physical_review, pdn_only, review_toggles.drc),
        // The exclusive heat overlay never paints routed copper or DRC. The
        // field endpoint already resolved that copper for its thermal inputs,
        // so restoring and checking it again in this iframe is dead work.
        .omit_copper = thermal_overlay,
        .defer_derived = defer_analysis,
    });
    const ro = rv.ro;
    const routed = rv.routed;
    const src_class = classifyLayoutSource(sub, choice.grid_only, choice.spec_drives, sel, starred_name, choice.cached);

    const data_opts = pcb_layout_blob.PcbDataOpts{
        .read_only = embed and !edit_embed,
        .embed = embed,
        .model_sprites = model_sprites,
        .model_data = thermal_overlay,
        .thermal_overlay = thermal_overlay,
        .assembly_review = physical_review and !thermal_overlay,
        .analysis_deferred = defer_analysis,
        .pdn_deferred = derived_only,
        .pdn_only = pdn_only,
        // The thermal overlay paints its own field over the semantic board
        // and explicitly suppresses copper/DRC. Generating every Gerber and
        // Excellon layer, parsing it back, and shipping the resulting CAM
        // program only to hide it cost several seconds on Board A.
        .cam_lazy = needsCamPreview(physical_review, thermal_overlay),
        .sub = sub,
        .subseeds_json = subseeds.poses,
        .subseedinfo_json = subseeds.info,
        .submodules_json = subseeds.mods,
        .part_edits_json = if (lean_read_only)
            "{}"
        else
            pcb_part_json.buildEditSources(ctx.allocator, eff_block, .{ .name = if (sub_block) |sb| sb.source else name, .project_dir = ctx.project_dir }),
        .outline_drawn = rv.outline_drawn,
        .saved_outline = rv.outline,
        .saved_fabrication_layers = rv.fabrication_layers,
        .saved_heatsink = rv.heatsink,
        .saved_fan = rv.fan,
        .saved_dimensions = rv.dimensions,
        .base_edge = rv.base_edge,
        .scratch_allocator = ctx.scratch_allocator,
        .top_design = top_design,
        .shown_layout = if (sub == null) adoptedLayoutName(sel, starred_name) else null,
        .src = src_class,
        .saved_routes = rv.saved,
        .omit_pours = thermal_overlay or defer_analysis,
        .subroutes_json = subseeds.routes,
        // Resolved effective plan (authored waves or the synthesized default)
        // for the settings drawer's routing-plan section.
        .plan_json = if (lean_read_only) "{}" else pcb_layout_blob.buildPlanJson(ctx.allocator, eff_block, placement),
        .texts = rv.texts,
        // Every render-path write above (persistGeneratedLayout,
        // displayLayouts dedup, recordAutoLayout) PRESERVES the rev, so the
        // doc read at the top of the handler still matches what's on disk —
        // only a user Save/Update bumps it.
        .rev = doc.rev,
    };

    if (lean_payload) {
        var body: std.Io.Writer.Allocating = .init(ctx.allocator);
        try pcb_layout_blob.writePcbDerivedData(&body.writer, ctx.allocator, placement, rv, data_opts);
        return body.written();
    }

    const view = View.init(placement);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;

    try pcb_layout_chrome.writeDocHead(w, eff_block.name, embed, edit_embed);
    if (!embed) try pages_tmpl.Navbar.render(.{""}, w);

    try w.writeAll("<div class=\"pcb-layout\">");
    // Cross-probe target for the sidebar's "Show in schematic" links: modules
    // render under /modules/, designs under /schematics/.
    const sch_base: []const u8 = if (module_res != null) "/modules/" else "/schematics/";
    const auto_score = LayoutScore{
        .hpwl = placement.score.hpwl_mm,
        .loop = placement.score.loop_mm,
        .caps = placement.score.loop_caps,
        .objective = placement.breakdown.objective,
    };
    // Full page: the left dock's Properties / Autorouter / Sub-circuits tabs
    // plus the saved-layouts history (KiCad-style docked column).
    if (!embed) try pcb_layout_chrome.writeSidebar(w, ctx.allocator, placement, sch_base, .{
        .name = name,
        .src = src_class,
        .ro_params = ro.params,
        .routed = routed,
        .n_drc = rv.violations.len,
        .n_rp = if (routed) |r| router.returnPathViolations(placement, r, router.return_path_radius_mm) else 0,
        .layouts = layouts,
        .auto = auto_score,
        .panel = .{ .name = name, .sub = sub },
    });
    if (!embed) try pcb_layout_chrome.writeActivityRail(w);
    try w.writeAll("<main class=\"pcb-main\">");
    if (embed and !edit_embed) {
        // Ordinary schematic previews get compact score/route chrome. Physical
        // assembly review keeps only the hidden route values its painter reads;
        // its parent shell owns the useful board controls.
        try pcb_layout_chrome.writeReadOnlyEmbedChrome(w, .{
            .module_source = if (sub_block) |sb| sb.source else "",
            .params = ro.params,
            .routed = routed,
            .n_drc = rv.violations.len,
            .toggles = review_toggles,
            .physical_review = physical_review,
        });
    } else {
        // Header row: title + the Schematic ⇄ PCB Layout switcher (PCB active).
        // The editable embed skips this header (the parent card carries its own
        // Schematic/PCB toggle) but keeps the full editing toolbar that follows.
        if (!embed) try pcb_layout_chrome.writeHeadNav(w, module_res != null, name, eff_block.name, queryOpt(req, "layout"), rv.tally);
        try pcb_layout_chrome.writeEditControls(w, placement, name, src_class, choice.grid_only, routed, ro.params, rv.violations.len, embed);
    }
    if (showEmbedLegend(embed, edit_embed, physical_review)) try pcb_layout_chrome.writeLegend(w, placement, false);
    try pcb_layout_chrome.writeStage(w, view, embed);
    // WebGL 3D-view stage — hidden until the "3D View" tab (or the thermal
    // parent's "3D setup" button) opens it, then `.mode-3d` swaps out the SVG.
    // Ordinary embeds remain lean; the thermal embed alone exposes this stage.
    if (!embed or thermal_overlay) try w.writeAll(pcb_layout_chrome.pcb_3d_stage_html);
    if (!embed) try w.writeAll(pcb_layout_chrome.courtyard_modal ++ pcb_layout_chrome.cooling_modals ++ pcb_layout_chrome.fp_card_modal ++ pcb_layout_chrome.fab_modal);
    try w.writeAll("</main>");
    try pcb_layout_chrome.writeRightDock(w, ctx.allocator, embed, edit_embed, .{ .panel = .{ .name = name, .sub = sub }, .layouts = layouts, .auto = auto_score, .placement = placement });
    try w.writeAll("</div>");
    try pcb_layout_blob.writePcbData(
        w,
        ctx.allocator,
        ctx.project_dir,
        placement,
        shown,
        view,
        name,
        pcb_layout_blob.payloadLayouts(layouts, lean_read_only),
        routed,
        ro.params.clearance,
        rv.violations,
        data_opts,
    );
    try writePageScripts(w, .{
        .physical_review = physical_review,
        .model_sprites = model_sprites,
        .thermal_overlay = thermal_overlay,
        .embed = embed,
        .embedded_3d = thermal_overlay,
    });
    try w.writeAll("</body></html>");

    return try pcb_derived.bothPayloads(ctx, name, aw.written(), .{
        .both = job.both,
        .deferrable = defer_analysis,
        .placement = placement,
        .view = rv,
        .opts = data_opts,
    });
}

/// The solved state a multi-payload render carries past its finished page.
/// Declared here so its fields keep their own module's types private:
/// `pcb_derived` sequences the publishing without naming any of them.
pub const DeferredJob = struct {
    both: ?pcb_derived.BothPayloads,
    /// False on any surface that already emits its derived fields inline, and
    /// therefore has no second response to produce.
    deferrable: bool,
    placement: optimizer.Placement,
    view: ShownView,
    opts: pcb_layout_blob.PcbDataOpts,
};

pub const PageScripts = struct {
    physical_review: bool,
    model_sprites: bool,
    thermal_overlay: bool,
    embed: bool,
    embedded_3d: bool = false,
};

/// Emit only the clients the selected surface can execute. Assembly is
/// read-only and has no settings, import, routing, replay, or stuck-net UI, so
/// loading those scripts on its critical path was pure parse/evaluation cost.
pub fn writePageScripts(w: *std.Io.Writer, mode: PageScripts) std.Io.Writer.Error!void {
    // FP.padShape and optional client-DRC marshaling load after `const PCB=…`.
    try w.writeAll("<script src=\"/static/footprint_svg.js\"></script>");
    if (!mode.physical_review) try w.writeAll("<script src=\"/static/drc_marshal.js\"></script>");
    // Earcut and the non-zero Gerber-region adapter precede WebGPU's CAM bake;
    // all three precede pcb_board.js at boot.
    try w.writeAll("<script src=\"/static/pcb_earcut.js\"></script>");
    try w.writeAll("<script src=\"/static/pcb_region.js\"></script>");
    try w.writeAll("<script src=\"/static/pcb_gpu.js\"></script>");
    if (!mode.physical_review) try w.writeAll("<script src=\"/static/shape_sketch.js\"></script>");
    try w.writeAll("<script src=\"/static/pcb_board.js\"></script>");
    if (!mode.physical_review) try w.writeAll("<script src=\"/static/pcb_settings.js\"></script>" ++
        "<script src=\"/static/pcb_dxf.js\"></script>" ++
        "<script src=\"/static/pcb_kicad_import.js\"></script><script src=\"/static/pcb_replay.js\"></script>" ++
        "<script src=\"/static/pcb_stuck.js\"></script>");
    if (mode.model_sprites) try w.writeAll("<script src=\"/static/pcb_model_sprites.js\"></script>");
    if (mode.thermal_overlay) try w.writeAll("<script src=\"/static/pcb_thermal.js\"></script>");
    if (!mode.embed or mode.embedded_3d) try w.writeAll(pcb_layout_chrome.pcb_3d_toggle_js);
}

/// Resolve `name` to a renderable design block. Preference: a design source
/// under `src/` (evaluated with `eval`). Fallback: a reusable module under
/// `lib/modules/` (via `modules_mod.resolveModuleBlock`, whose evaluator is
/// stashed in `module_res` for the caller to free). Null if neither exists.
pub fn resolveBlock(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    eval: *Evaluator,
    module_res: *?modules_mod.ResolvedBlock,
) ?*env_mod.DesignBlock {
    if (paths.designSourcePath(alloc, project_dir, name)) |path| {
        defer alloc.free(path);
        if (eval.evalFile(path)) |result| {
            switch (result) {
                .design_block => |b| {
                    const bom_path = paths.designSiblingPath(alloc, project_dir, name, ".bom") catch return b;
                    defer alloc.free(bom_path);
                    bom.applyExisting(alloc, b, bom_path, project_dir) catch |err|
                        log.warn("read-only BOM load for {s} failed: {s}", .{ name, @errorName(err) });
                    resolvePdnBom(alloc, project_dir, name, b);
                    return b;
                },
                else => {},
            }
        } else |_| {}
    } else |_| {}
    module_res.* = modules_mod.resolveModuleBlock(alloc, project_dir, name);
    if (module_res.*) |mr| return mr.block;
    return null;
}

/// The PDN extractor consumes the selected BOM row's C/ESR/ESL properties.
/// Loading is deliberately read-only: opening a page or release report must
/// never refresh a stale BOM and thereby manufacture its own release evidence.
fn resolvePdnBom(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *env_mod.DesignBlock,
) void {
    if (block.pdn_intents.len == 0) return;
    const bom_path = paths.designSiblingPath(alloc, project_dir, name, ".bom") catch return;
    defer alloc.free(bom_path);
    bom.applyExisting(alloc, block, bom_path, project_dir) catch |err|
        log.warn("PDN BOM load for {s} failed: {s}", .{ name, @errorName(err) });
}

// spec: Web Server - A PCB design with PDN intents resolves selected BOM electrical model properties before placement
test "PCB PDN analysis resolves the selected BOM electrical model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.createDirPath(std.testing.io, "lib/parts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/parts/cap-fixture.sexp",
        .data =
        \\(parts "cap-fixture"
        \\  (part "100nF"
        \\    (manufacturer "Fixture")
        \\    (mpn "CAP-100N")
        \\    (pdn-esr-ohm "0.02")
        \\    (pdn-esl-h "4e-10")
        \\    (preferred)))
        ,
    });

    var built_instances = [_]env_mod.Instance{.{
        .ref_des = "C1",
        .component = "cap-fixture",
        .value = "100nF",
        .footprint = "0402",
        .symbol = "Device:C",
        .id = "ab000001",
    }};
    var built_block: env_mod.DesignBlock = .{
        .name = "Demo",
        .instances = &built_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .pdn_intents = &.{.{ .net = "VDD", .ripple_v = 0.1 }},
    };
    const bom_path = try paths.designSiblingPath(alloc, project_dir, "demo", ".bom");
    try bom.resolveIdentities(alloc, &built_block, bom_path, project_dir);

    var loaded_instances = [_]env_mod.Instance{built_instances[0]};
    loaded_instances[0].properties = &.{};
    var loaded_block = built_block;
    loaded_block.instances = &loaded_instances;
    resolvePdnBom(alloc, project_dir, "demo", &loaded_block);

    var found_esr = false;
    var found_esl = false;
    for (loaded_instances[0].properties) |property| {
        if (std.mem.eql(u8, property.key, "pdn-esr-ohm") and std.mem.eql(u8, property.value, "0.02")) found_esr = true;
        if (std.mem.eql(u8, property.key, "pdn-esl-h") and std.mem.eql(u8, property.value, "4e-10")) found_esl = true;
    }
    try std.testing.expect(found_esr and found_esl);
}

/// The `?sub=<slug>` query value (a slugified sub-block name), or null when the
/// request targets the whole design. Empty values count as absent, and so does
/// anything that is not spelled like a slug (`isValidSubSlug`) — every one of
/// this module's `?sub=`-aware handlers reads the scope through here, so the
/// single null is what keeps a hostile value out of the sidecar path builder.
/// Degrading to design scope (rather than erroring) is deliberate: the callers
/// are helpers deep in the render/save paths with no response to write, and a
/// design-scoped request is one the caller could have made by omitting `?sub=`
/// entirely, so nothing is reachable that was not already.
pub const subSlug = pcb_query.subSlug;
const isValidSubSlug = pcb_query.isValidSubSlug;
const sub_slug_max_len = pcb_query.sub_slug_max_len;

/// True when `?embed=1` is present — render the trimmed, read-only chrome used
/// by the schematic page's inline per-sub-block preview frame.
fn isEmbed(req: ?*httpz.Request) bool {
    return pcb_query.raw(req, "embed") != null;
}

fn isPhysicalReview(req: ?*httpz.Request, embed: bool, edit_embed: bool) bool {
    return embed and !edit_embed and queryFlag(req, "review");
}

fn needsCamPreview(physical_review: bool, thermal_overlay: bool) bool {
    return physical_review and !thermal_overlay;
}

fn needsPageReporting(physical_review: bool, pdn_only: bool, review_drc: bool) bool {
    return !pdn_only and (!physical_review or review_drc);
}

fn showEmbedLegend(embed: bool, edit_embed: bool, physical_review: bool) bool {
    return embed and !edit_embed and !physical_review;
}

/// Descend a design block into the top-level sub-block whose slugified name
/// matches `sub_slug` (the same `review.slugify` the schematic page uses for its
/// `data-sub` attributes, so the keys line up). Null when none match. Only the
/// sub-block's parts are then placed/routed — the whole design never is.
pub fn descendToSub(
    allocator: std.mem.Allocator,
    block: *env_mod.DesignBlock,
    sub_slug: []const u8,
) ?env_mod.SubBlock {
    for (block.sub_blocks) |sb| {
        const slug = review.slugify(allocator, sb.name) catch continue;
        if (std.mem.eql(u8, slug, sub_slug)) return sb;
    }
    return null;
}

/// GET /api/pcb-settings/:name — authored PCB configuration and provenance.
/// The live page already owns the resolved/effective placement values; this
/// deliberately avoids a second solve and lets the settings drawer merge the
/// source declarations with the exact values currently used by routing/DRC.
pub fn pcbSettingsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const root = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 404;
        res.body = no_block_msg;
        return;
    };
    const sub = subSlug(req);
    const block = if (sub) |slug| (descendToSub(ctx.allocator, root, slug) orelse {
        res.status = 404;
        res.body = no_sub_msg;
        return;
    }).block else root;
    var source_path: []const u8 = name;
    if (module_res == null) {
        if (paths.designSourcePath(req.arena, ctx.project_dir, name)) |absolute| {
            source_path = absolute;
            if (std.mem.startsWith(u8, absolute, ctx.project_dir)) {
                source_path = std.mem.trimStart(u8, absolute[ctx.project_dir.len..], "/");
            }
        } else |_| {}
    }
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try pcb_layout_blob.writeAuthoredSettings(&aw.writer, block, source_path, sub);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Persist a freshly generated layout + its weights (auto cache + the named
/// history), so later loads are instant and the controls show the weights
/// that actually produced the layout on screen. Scoped sub-block runs skip
/// this — there's no sidecar key for an individual sub-block yet. A `top_design`
/// page writes the cache slot only — never an "auto · …" history row alongside
/// it: a whole board re-solves on many page opens, and a dozen auto rows would
/// bury the hand-saved candidates the Layouts panel exists to compare. A module
/// page, whose solves are cheap and deliberate, keeps its auto history.
fn persistGeneratedLayout(ctx: *Server, name: []const u8, placement: optimizer.Placement, params: optimizer.Params, sub: ?[]const u8, top_design: bool) void {
    if (sub != null or !placement.generated) return;
    writeAutoCache(ctx.allocator, ctx.project_dir, name, placement, params);
    if (!top_design) recordAutoLayout(ctx.allocator, ctx.project_dir, name, placement, params);
}

/// Initial state of the embed preview's show-clearance / show-DRC toggles,
/// passed through from the schematic page's global checkboxes as `?clr=` / `?drc=`.
/// Clearance and DRC both default off; explicit query values override them.
pub const Toggles = struct { clr: bool, drc: bool };

fn parseToggles(req: ?*httpz.Request) Toggles {
    const r = req orelse return .{ .clr = false, .drc = false };
    const q = r.query() catch return .{ .clr = false, .drc = false };
    const clr_on = if (q.get("clr")) |v| std.mem.eql(u8, v, "1") else false;
    const drc_on = if (q.get("drc")) |v| std.mem.eql(u8, v, "1") else false;
    return .{ .clr = clr_on, .drc = drc_on };
}

/// GET /api/pcb-layout/:name — export the solved placement as JSON: per-part
/// positions plus the full objective breakdown. The on-screen score bar only
/// shows HPWL + *raw* loop length; this also surfaces the value-weighted loop
/// and alignment terms the optimizer actually minimises, so a layout that looks
/// worse on the visible metric but wins on the true objective can be told apart.
/// Honours the same ?regen / tuning query as the page.
pub fn pcbLayoutJsonApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = no_block_msg;
        return;
    };
    const sidecar = readPageDoc(ctx, name, null);

    const tune = parseTuning(req);
    const refine_name: ?[]const u8 = if (req.query()) |q| q.get("refine") else |_| null;
    // Match the page: with nothing more specific asked for, default to the design's
    // starred (★) saved layout if it has one, so this JSON twin describes the same
    // board the page shows.
    const want_default = !(refine_name != null or tune.regen or tune.tuned or tune.show_cache);
    const starred_name: ?[]const u8 = if (want_default) defaultLayoutNameIn(sidecar.layouts) else null;
    const cached = if (refine_name) |rn|
        layoutPosesIn(ctx.allocator, sidecar.layouts, rn, block)
    else if (starred_name) |sn|
        layoutPosesIn(ctx.allocator, sidecar.layouts, sn, block)
    else if (tune.regen) null else cachePoses(ctx.allocator, sidecar.cache);
    // Starred = the user's saved hand layout: verbatim, same as the page (see
    // chooseLayout — `solve` would re-solve it away on any courtyard overlap).
    var placement = (if (starred_name != null and cached != null)
        // Outline: folded post-build just below (shared with the solve branch).
        optimizer.placeFromPoses(ctx.allocator, block, ctx.project_dir, .{ .poses = cached.?, .outline = .authored_only }, tune.params)
    else
        optimizer.solve(ctx.allocator, block, ctx.project_dir, cached, tune.params, if (refine_name != null) .refine else .place)) catch {
        res.status = 500;
        res.body = placement_err_msg;
        return;
    };
    // Fold the board outline (starred/blessed) onto the placement so ?route=1's
    // DRC here checks the true board edge — the JSON twin must match the page +
    // commit (else a fresh/regen solve routes and DRCs with no edge; see
    // foldBlessedOutline).
    if (starred_name) |sn|
        _ = applyShownOutline(&placement, sidecar.layouts, sn)
    else if (blessedOutlineIn(sidecar.layouts, defaultLayoutNameIn(sidecar.layouts))) |o|
        applyOutline(&placement, o);
    if (placement.generated) writeAutoCache(ctx.allocator, ctx.project_dir, name, placement, tune.params);
    const shown = shownParams(null, tune, placement.generated, sidecar);

    // Per-part objective blame for the findings sidecar (index-aligned w/ parts).
    const blame = try req.arena.alloc(f64, placement.parts.len);
    optimizer.perPartBlame(placement, shown, blame);

    // Optional `?route=1`: route the board and summarise the real copper so layouts
    // are directly comparable (trace length, via count, DRC) without scraping HTML.
    const ro = parseRoute(req, placement.rules.design.routeParams());
    const routed_metrics: ?pcb_layout_blob.RoutedMetrics = if (ro.run) blk: {
        // Same plan-lowering seam as route_pcb, so this JSON preview == commit.
        const route_options = route_plan.lowerOrEmpty(ctx.allocator, block, placement);
        const seeded = pcb_layout_seeds.routeWithSubcircuitSeeds(ctx.allocator, ctx.project_dir, block, placement, ro.params, route_options) catch
            break :blk null;
        const r = seeded.result;
        const v = drc_rules.checkFiltered(ctx.allocator, ctx.project_dir, name, placement, r, ro.params.clearance);
        var trace: f64 = 0;
        for (r.tracks) |t| trace += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        break :blk .{
            .trace_mm = trace,
            .tracks = r.tracks.len,
            .vias = r.vias.len,
            .drc = v.len,
            .drc_errors = drc.errorCount(v),
            .routed = r.routed,
            .total = r.total,
            .unrouted = r.failed,
            .ripup_rounds = r.ripup_rounds,
            .per_net = router.perNetRouted(ctx.allocator, placement, r) catch &.{},
        };
    } else null;

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try pcb_layout_blob.writePlacementJson(&aw.writer, placement, shown, name, blame, routed_metrics);
    res.content_type = .JSON;
    res.body = aw.written();
}

const png_default_width: u32 = 1200;

/// Inputs for `renderDesignPng` — the union of what the HTTP query and the CLI
/// `get_pcb_layout_image` tool can specify. Empty `highlight_*` → plain board;
/// any value → focus mode (spotlight + dim).
pub const PngRequest = struct {
    /// One physical copper-layer name, including inner planes; null shows all.
    layer: ?[]const u8 = null,
    width: u32 = png_default_width,
    highlight_nets: []const []const u8 = &.{},
    highlight_refs: []const []const u8 = &.{},
    route: bool = false,
    layout: ?[]const u8 = null,
    regen: bool = false,
    sub: ?[]const u8 = null,
    /// Experimental courtyard-overlap allowance (mm); 0 = touch only (default).
    court_overlap: f64 = 0,
    /// Routing/copper room between courtyards (mm); 0 = touch (default).
    route_gap: f64 = 0,
    /// Functional-group cohesion / zoning / bank-loop-relief tuning knobs.
    group: GroupKnobs = .{},
    /// Constructive zone-then-pack floorplan (crisp VIN│IC│L│VOUT rows).
    zone_pack: bool = false,
    /// "Rough remaining": pin what the base layout (★ else auto cache) covers,
    /// rough-place only the uncovered parts (`Params.remaining`).
    remaining: bool = false,
    /// Rough hierarchical / pad-anchored seed (`?rough=1`): cluster each module
    /// into a rigid block, or — for a flat module — ring the anchor IC with each
    /// passive on the side of the pad it serves. A legible, module-intact start
    /// (the `Params.rough` path in the optimizer), deliberately not metric-optimal.
    rough: bool = false,
    /// Diagnostic overlays (see render_pcb_png.Options).
    blame: bool = false,
    loop_labels: bool = false,
    dims: bool = false,
    grid: bool = false,
    /// Saved-layout name to diff the current placement against.
    compare: ?[]const u8 = null,
    /// Part-name labelling (`?names=ref|origin|both`). Null = auto: origin
    /// names when a `(placement …)` spec drives the solve (so the image speaks
    /// the spec's vocabulary), ref-des otherwise.
    names: ?render_pcb_png.NameMode = null,
    /// Parts whose pads get net-name labels (`?pins=U13,C5`; "hubs" = all hubs).
    pins: []const []const u8 = &.{},
    /// Crop the viewport around this part (`?crop=U1`), radius `?r=<mm>`.
    crop: ?[]const u8 = null,
    crop_r: f64 = 6,
    /// `?cropnet=A,B` net-bbox zoom lens: crop the viewport to these nets' pads
    /// + copper (restored or fresh-routed) + a ~1.5 mm margin (matched like
    /// `highlight_nets`). When both `crop=` and `cropnet=` are given, `crop=`
    /// wins (a single-part window is the more specific request).
    crop_nets: []const []const u8 = &.{},
    /// Contact sheet (`?sheet=1`): whole board + per-hub pin-labeled closeups.
    sheet: bool = false,
    /// Callout overlay (`?critique=1`): numbered worst-problem markers + panel.
    critique: bool = false,
    /// `?pads=1` — add the full pad table to the describe facts. Off by default
    /// because it roughly doubles the payload on a dense board; on when a
    /// caller needs to place copper without colliding (the obstacle set).
    pads: bool = false,
    /// `?thermal=1` — paint the heat field instead of the copper board.
    thermal: ThermalPng = .{},
};

/// Functional-group cohesion / zoning / bank-loop-relief tuning knobs
/// (negative ⇒ "unset", keep the optimizer default). One experiment's dial set,
/// nested because they are only ever set and read together.
pub const GroupKnobs = struct {
    w: f64 = -1,
    zone_w: f64 = -1,
    loop_relief: f64 = -1,
};

/// The heat-zone view of a board (`?thermal=1`), which is a different picture
/// of the same placement rather than an overlay on the copper one.
pub const ThermalPng = struct {
    /// Render the heat field instead of the board's copper.
    on: bool = false,
    /// Which cooling scenario to solve and paint. Null ⇒ still air, the board
    /// as designed and the only one that needs no assumption about its housing.
    scenario: ?thermal_scenarios.Scenario = null,
    /// Ambient the absolute temperatures are printed at (°C). Null ⇒ bench
    /// ambient, matching `GET /api/thermal/:name`.
    ambient_c: ?f64 = null,
};

/// A `scenario=` / `"scenario"` spelling as a cooling scenario. Absent or
/// unrecognised ⇒ null, which the renderer reads as still air: a typo in one
/// optional word should not refuse the whole image, and still air is the
/// scenario that assumes nothing about the board's housing.
pub fn parseScenario(s: ?[]const u8) ?thermal_scenarios.Scenario {
    return std.meta.stringToEnum(thermal_scenarios.Scenario, s orelse return null);
}

/// Failures `renderDesignPng` surfaces; callers map these to an HTTP status or
/// CLI error message.
pub const PngError = error{ BlockNotFound, SubNotFound, BuildFailed, InvalidLayer } || png_mod.Error;

/// One classification of a failed solve, worded for both endpoints: `msg` is
/// the PNG handler's plain-text body, `json` the describe endpoint's. Shared
/// so the two views can't drift — an unknown design must never read as an
/// internal failure (a deleted design once 404'd as "describe failed" and got
/// chased as a describe bug).
pub const PngFail = struct { status: u16, msg: []const u8, json: []const u8 };

/// Map a solve/render failure to its HTTP reporting.
pub fn pngFailure(e: PngError) PngFail {
    return switch (e) {
        error.InvalidLayer => .{ .status = 400, .msg = "unknown copper layer", .json = "{\"error\":\"unknown copper layer\"}" },
        error.BlockNotFound => .{
            .status = 404,
            .msg = no_block_msg,
            .json = "{\"error\":\"no design or module by that name\"}",
        },
        error.SubNotFound => .{
            .status = 404,
            .msg = no_sub_msg,
            .json = "{\"error\":\"no sub-block by that name\"}",
        },
        else => .{
            .status = 500,
            .msg = placement_err_msg,
            .json = "{\"error\":\"describe failed\"}",
        },
    };
}

/// User-zone copper in both authoring and router-ready forms. Keeping the pair
/// nested prevents `SolvedRequest` from becoming a flat request god-object.
const ShownZones = struct {
    user: []const pour.UserZone = &.{},
    sources: []const route_policy.ExistingZone = &.{},
    silk_keepouts: []const subcircuit_silkscreen.Keepout = &.{},
    /// Per-layout positive fabrication regions selected with the placement.
    fabrication_layers: []const SavedFabricationLayer = &.{},
};

const SolvedCooling = struct {
    heatsink: ?SavedHeatsink = null,
    fan: ?SavedFan = null,
};

/// A solved placement plus the request context the PNG and describe endpoints
/// share — both views must show the *same* board. `placement` references block
/// memory owned by the caller's `eval`/`module_res`, so those must outlive it.
pub const SolvedRequest = struct {
    placement: optimizer.Placement,
    spec_status: ?render_pcb_png.SpecStatus,
    params: optimizer.Params,
    title: []const u8,
    /// The (possibly sub-scoped) design block the placement was solved from —
    /// callers needing a second solve (e.g. the compare overlay) reuse it.
    block: *env_mod.DesignBlock,
    /// Board-level silkscreen texts from the shown/starred layout (empty when
    /// none) — the PNG draws them so screenshots match the Gerber silk.
    texts: []const font5x7.BoardText = &.{},
    /// The shown layout's persisted routed copper + its layer audit (see
    /// `layout_layers.Restored`), rebuilt against the CURRENT netlist
    /// (`restoreRoutes`) — the same copper the /pcb-layout page draws
    /// when no fresh `?route=1` ran (see resolveShownView). Null when `?route=1`
    /// was requested (the caller routes fresh instead) or the shown layout has
    /// no saved routes. Page parity: the PNG/describe endpoints draw/report this
    /// so the route-once/inspect-many agent loop sees saved copper without a
    /// full-board re-route per request.
    restored: layout_layers.Restored = .{},
    /// The shown layout's hand-drawn user copper pours (filled netted outer
    /// zones) — the PNG draws them and the connectivity DRC credits them, so a
    /// screenshot / net-open report matches the interactive viewer. Shown
    /// regardless of `?route=1` (a user pour persists through a route preview).
    shown_zones: ShownZones = .{},
    /// Physical cooling assemblies resolved against this exact placement.
    cooling: SolvedCooling = .{},
};

/// The copper on a solved board, in the thermal projection's terms.
///
/// The thermal field reads the pours (an unpoured cell spreads through the
/// inner planes alone) and the vias (a stitched land transfers far better than
/// a bare one), so it has to see the SAME copper the view draws — which is what
/// this hands it. A board with no saved routes still carries its hand-drawn
/// zones, exactly as the PNG draws it.
pub fn thermalCopper(solved: SolvedRequest) thermal_scenarios.Copper {
    const routed = solved.restored.routes orelse return .{ .zones = solved.shown_zones.user };
    return .{ .tracks = routed.tracks, .vias = routed.vias, .zones = solved.shown_zones.user };
}

/// Convert a saved physical-face assembly into the package-relative form the
/// thermal kernel consumes. A sink on the component's own face is a package-
/// top path; the opposite physical PCB face is the board/exposed-pad path.
pub fn thermalHeatsink(solved: SolvedRequest, bt: thermal.BoardThermal) ?thermal_scenarios.Heatsink {
    const authored = solved.block.board.thermal.heatsink;
    var resolved = authored_heatsink.resolve(solved.placement, solved.cooling.heatsink, authored) orelse return null;
    // A layout-drawn assembly is bonded to its PCB footprint. Old sidecars
    // carried a nearest-part hint; clear it at this boundary so they migrate
    // without rewriting user data. Source-authored package sinks retain their
    // stable target and the directional theta-JC model.
    if (authored == null) resolved.target_ref = "";
    return authored_heatsink.thermalInput(solved.placement, bt, resolved);
}

/// Return the board-authored fan already lowered into this solved placement.
pub fn thermalFan(solved: SolvedRequest) ?thermal_scenarios.Fan {
    return authored_heatsink.fanThermalInput(solved.cooling.fan orelse return null);
}

/// Resolve `name` and apply the request's placement-selection rules: a named
/// `?layout=` renders verbatim, `?regen` forces a fresh solve, `?rough` re-seeds
/// the rough engine, otherwise the design's starred (★) saved layout is shown if
/// it has one (so the PNG / describe / CLI views match the /pcb-layout page),
/// else the auto cache — falling back to a plain grid when nothing is cached so
/// an agent's first call stays cheap. A fresh solve uses the rough engine (the
/// default top-level placer); the `?rough` flag is now redundant with that.
pub fn solveForRequest(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: PngRequest,
    eval: *Evaluator,
    module_res: *?modules_mod.ResolvedBlock,
) PngError!SolvedRequest {
    const block = resolveBlock(alloc, project_dir, name, eval, module_res) orelse return error.BlockNotFound;
    const eff_block: *env_mod.DesignBlock = if (opts.sub) |s|
        (descendToSub(alloc, block, s) orelse return error.SubNotFound).block
    else
        block;

    // One parse per sidecar for the whole solve. Every question below — the ★
    // default, its poses, the auto cache, the drawn outline, the silk texts,
    // the persisted copper, the user pours — used to re-read and re-parse the
    // same `.layouts.json` from scratch. On a routed board that file is large
    // (7 MB for board-a), and the seven repeats put ~85% of a cold schematic
    // page render inside `std.json`. The page render already worked this way
    // (see `defaultLayoutNameIn`); this is the same discipline for the PNG /
    // describe / thermal path.
    const design_doc = (readDesignDoc(alloc, project_dir, name) catch SidecarDoc{});
    // A ?sub= view reads its own per-sub store; unscoped, it IS the design one.
    const sub_doc: SidecarDoc = if (opts.sub) |s| (readSidecarDoc(alloc, project_dir, name, s) catch SidecarDoc{}) else design_doc;

    // With nothing more specific asked for (no ?layout=, no ?regen, no ?rough,
    // not sub-scoped), default to the design's starred (★) saved layout — the
    // same blessed board the /pcb-layout page and its JSON twin show — so the
    // PNG / describe / CLI views describe what the user sees, not a stale auto
    // cache. The layout_match rough/starred probes pass ?rough / ?layout and so
    // skip this, keeping their own seeds.
    const want_default = opts.sub == null and opts.layout == null and !opts.regen and !opts.rough and !opts.remaining;
    const starred_name: ?[]const u8 = if (want_default)
        defaultLayoutNameIn(design_doc.layouts)
    else
        null;
    var cached = if (opts.sub != null) null else if (opts.layout) |ln|
        layoutPosesIn(alloc, design_doc.layouts, ln, eff_block)
    else if (starred_name) |sn|
        layoutPosesIn(alloc, design_doc.layouts, sn, eff_block)
    else if (opts.regen) null else cachePoses(alloc, design_doc.cache);
    // "Rough remaining": a fresh solve seeded with the ★ (else the auto cache)
    // as its pinned base — the solve locks what it covers, places only the
    // rest. The ★ is preferred explicitly: without this, an existing auto
    // cache (some earlier rough) would win and get pinned instead.
    if (opts.remaining and opts.sub == null and opts.layout == null) {
        const star_base = if (defaultLayoutNameIn(design_doc.layouts)) |dn|
            layoutPosesIn(alloc, design_doc.layouts, dn, eff_block)
        else
            null;
        cached = star_base orelse (cached orelse cachePoses(alloc, design_doc.cache));
    }
    const grid_only = opts.sub == null and opts.layout == null and !opts.regen and cached == null;
    var params = optimizer.Params{ .courtyard_overlap = opts.court_overlap, .route_gap = opts.route_gap };
    if (opts.group.w >= 0) params.group_w = opts.group.w;
    if (opts.group.zone_w >= 0) params.group_zone_w = opts.group.zone_w;
    if (opts.group.loop_relief >= 0) params.group_loop_relief = opts.group.loop_relief;
    if (opts.zone_pack) params.zone_pack = true;
    if (opts.remaining) params.remaining = true;
    // Rough is the default top-level engine — a fresh solve always seeds rough.
    // (`?rough` is now redundant with this; left functional as a harmless alias.)
    params.rough = true;
    // A named saved layout OR the starred default renders VERBATIM
    // (placeFromPoses) — "show me this layout" must display exactly what was
    // saved, not a re-optimized version: refine can drift a hand-tuned layout
    // to a worse arrangement (e.g. a 70.8 hand layout relaxing back to 86
    // because it isn't a relax fixed-point), and `solve` discards any saved
    // layout with a courtyard overlap outright (applyCached's staleness test).
    var placement = (if ((opts.layout != null or starred_name != null) and cached != null)
        // Outline: folded post-build just below (shared with the solve/grid branches).
        optimizer.placeFromPoses(alloc, eff_block, project_dir, .{ .poses = cached.?, .outline = .authored_only }, params)
    else if (grid_only)
        optimizer.gridPlace(alloc, eff_block, project_dir, params)
    else
        optimizer.solve(alloc, eff_block, project_dir, cached, params, .place)) catch return error.BuildFailed;
    // Fold the user-drawn board outline (rectangle or polygon) onto the
    // placement so the PNG / describe / CLI / route views share the same board
    // edge the viewer and fab outputs use. The named ?layout= / starred view
    // takes its own outline; a FRESH regen/rough/route solve (no named or
    // starred layout) falls back to the design's blessed outline — otherwise it
    // would route and DRC with NO board edge (maze on the parts bbox,
    // bend-smoothing free to bulge arcs off the board, board-edge DRC silently
    // skipped on a null board_rect). The board edge is view-independent.
    if (opts.sub == null) {
        const applied = if (opts.layout orelse starred_name) |sn|
            applyShownOutline(&placement, design_doc.layouts, sn)
        else
            false;
        if (!applied) _ = foldBlessedOutlineIn(design_doc.layouts, &placement);
    }

    // Staging coverage from the solve just above (same thread): parts the
    // `(board …)` edge-dock / force path left in the band and the ones autofill
    // pulled back out. Reported so the image hatches staged parts in red.
    const diag = optimizer.placementDiag();
    const spec_status: ?render_pcb_png.SpecStatus = if (diag.unplaced.len > 0 or diag.auto_filled.len > 0)
        .{ .unplaced = diag.unplaced, .auto_filled = diag.auto_filled }
    else
        null;
    // Board-level silkscreen texts of the layout being shown (the named ?layout=,
    // else the starred default) — drawn on the PNG so screenshots match fab silk.
    const shown_name: ?[]const u8 = opts.layout orelse starred_name;
    const texts = layoutTextsIn(sub_doc.layouts, shown_name);
    // Page parity: unless a fresh route was asked for (?route=1), restore the
    // SHOWN layout's persisted copper (the same layout that supplied the poses
    // above), rebuilt against the current netlist. `route=1` keeps meaning "route
    // fresh" — the caller then routes instead of drawing this.
    // Persisted layer indices are judged against THIS board's stackup as they
    // load: out-of-range copper is kept and reported, never dropped.
    var restored = layout_layers.Restored{ .layer_audit = .{ .signals = placement.rules.signalLayerCount() } };
    if (!opts.route) {
        const raw: ?SavedRoutes = shownSavedRoutes(sub_doc.layouts, shown_name);
        if (raw) |sr| {
            restored.layer_audit = layout_layers.audit(sr, placement.rules);
            layout_layers.warn(restored.layer_audit, name, shown_name orelse "");
        }
        if (routesWithPerimeter(alloc, placement, raw)) |cur| restored.routes = restoreRoutes(alloc, cur, placement.nets);
    }
    // User copper pours ride along regardless of ?route=1 — a hand-drawn pour is
    // persistent copper, not something a route preview clears.
    const shown_routes: ?SavedRoutes = shownSavedRoutes(sub_doc.layouts, shown_name);
    const shown_zones: []const pour.UserZone = if (shown_routes) |sr|
        userZonesFrom(alloc, placement.rules, sr.zones)
    else
        &.{};
    const silk_keepouts: []const subcircuit_silkscreen.Keepout = if (shown_routes) |sr|
        silkKeepoutsFrom(alloc, sr.zones)
    else
        &.{};
    return .{
        .placement = placement,
        .spec_status = spec_status,
        .params = params,
        .title = eff_block.name,
        .block = eff_block,
        .texts = texts,
        .restored = restored,
        .shown_zones = .{
            .user = shown_zones,
            .sources = userZoneSources(alloc, placement, shown_zones),
            .silk_keepouts = silk_keepouts,
            .fabrication_layers = shownFabricationLayers(sub_doc.layouts, shown_name),
        },
        .cooling = .{
            .heatsink = authored_heatsink.resolve(placement, shownHeatsink(sub_doc.layouts, shown_name), eff_block.board.thermal.heatsink),
            .fan = authored_heatsink.resolveFan(placement, shownFan(sub_doc.layouts, shown_name), eff_block.board.thermal.fan),
        },
    };
}

/// The shown layout's hand-drawn user copper pours (filled netted outer zones),
/// scoped to the per-sub sidecar when `sub` is set — the PNG / describe twin of
/// `restoreShownRoutes` for zones.
fn shownUserZones(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, shown: []const u8, sub: ?[]const u8, rules: optimizer.BoardRules) []const pour.UserZone {
    const layouts = readLayoutsSub(alloc, project_dir, name, sub);
    const sr = shownSavedRoutes(layouts, shown) orelse return &.{};
    return userZonesFrom(alloc, rules, sr.zones);
}

fn shownSilkKeepouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, shown: []const u8, sub: ?[]const u8) []const subcircuit_silkscreen.Keepout {
    const layouts = readLayoutsSub(alloc, project_dir, name, sub);
    const sr = shownSavedRoutes(layouts, shown) orelse return &.{};
    return silkKeepoutsFrom(alloc, sr.zones);
}

/// Restore the shown layout's persisted routed copper against the CURRENT
/// netlist — the PNG/describe equivalent of the /pcb-layout page's
/// resolveShownView copper restore (`shownSavedRoutes` → `restoreRoutes`). Reads
/// the SAME layout that supplied the poses (`shown`), scoped to the per-sub
/// sidecar when `sub` is set. Null when that layout carries no saved routes.
fn restoreShownRoutes(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    shown: []const u8,
    sub: ?[]const u8,
    nets: []const export_kicad.FlatNet,
) ?router.RouteResult {
    const layouts = readLayoutsSub(alloc, project_dir, name, sub);
    const sr = shownSavedRoutes(layouts, shown) orelse return null;
    return restoreRoutes(alloc, sr, nets);
}

/// True when `opts` selects a board the server's thermal cache can NAME — the
/// design's default board (starred layout, else the auto cache, else a plain
/// grid), or one named `?layout=`. Those two are exactly what the cache key
/// distinguishes (project, design, layout, live version), so an image, a page
/// and a facts JSON asking for the same one share a solve.
///
/// Every other knob is excluded and solves its own field: a `?sub=` scope, a
/// regenerated or rough placement, a zone-packed or group-tweaked one all put
/// the parts somewhere the key cannot describe, and a field keyed as if they
/// had not would be another board's heat under this board's name.
///
/// Deliberately a whitelist of "no override": every knob that can move a part
/// moves the heat with it, so a new placement knob defaults to solving fresh
/// rather than silently reusing a field solved for different poses.
fn selectsCacheableBoard(opts: PngRequest) bool {
    return opts.sub == null and !opts.regen and
        !opts.rough and !opts.remaining and !opts.zone_pack and
        opts.court_overlap == 0 and opts.route_gap == 0 and
        std.meta.eql(opts.group, GroupKnobs{});
}

/// `?thermal=1` — the HEAT-ZONE image: the same placement the copper view would
/// show, painted with the temperature field one cooling scenario produces on it.
///
/// The copper view's own parameters are deliberately ignored here, and the
/// endpoint's doc comment says so: `nets`/`refs` focus, `route`, `crop` /
/// `cropnet`, `sheet`, `critique`, `compare`, `blame`, `loops`, `dims`, `grid`,
/// `pins` and `names` all describe copper this image does not draw — and a crop
/// would hide the very thing it exists to show, which is where on the WHOLE
/// board the heat is. `width`, `layout`, `regen`, `rough`, `remaining` and `sub`
/// still select and frame the board, because those choose WHICH board.
fn renderThermalPng(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: PngRequest,
    deps: ?*?page_cache.FileSet,
) PngError![]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    defer if (deps) |out| {
        out.* = png_cache.captureRenderDeps(alloc, &eval, module_res, project_dir, name);
    };
    const solved = try solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);

    const ambient = opts.thermal.ambient_c orelse thermal.default_ambient_c;
    const screen = try thermal.analyze(alloc, solved.block, ambient);
    const scenario = opts.thermal.scenario orelse .natural;
    // The server's cached ladder answers this image whenever the request shows
    // a board the cache can name — the design's default board, or one named
    // `?layout=`. That is the same board the thermal page and its facts JSON
    // report for the same URL, so the picture and the numbers are one solve. A
    // request that selects some other board (a sub-block, a rough or
    // regenerated placement) is not nameable, so it solves its own field rather
    // than borrowing an entry keyed on poses it does not have.
    const copper = thermalCopper(solved);
    const painted = if (selectsCacheableBoard(opts)) blk: {
        const results = try thermal_api.solveOver(alloc, &eval, project_dir, name, screen, .{
            .placement = solved.placement,
            .copper = copper,
            .heatsink = thermalHeatsink(solved, screen),
            .fan = thermalFan(solved),
            .layout = opts.layout,
        });
        break :blk (try thermal_scenarios.paintFrom(alloc, results, solved.placement, scenario, ambient)) orelse
            try thermal_scenarios.paintAtWithAssembly(alloc, screen, solved.placement, .{ .scenario = scenario, .ambient_c = ambient, .copper = copper, .heatsink = thermalHeatsink(solved, screen), .fan = thermalFan(solved) });
    } else try thermal_scenarios.paintAtWithAssembly(alloc, screen, solved.placement, .{ .scenario = scenario, .ambient_c = ambient, .copper = copper, .heatsink = thermalHeatsink(solved, screen), .fan = thermalFan(solved) });
    return render_thermal_png.render(alloc, solved.placement, painted, .{
        .width = opts.width,
        .title = solved.title,
        .ambient_c = ambient,
        .inferred_outline = !thermal_scenarios.boardOf(solved.placement).authored,
    });
}

/// allocation goes through `alloc`; the returned bytes are owned by it.
/// `deps`, when non-null, receives this render's read-set (see
/// `png_cache.captureRenderDeps`), captured while the evaluators are still
/// alive; the caller owns it and must `deinit` it.
pub fn renderDesignPng(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: PngRequest,
    deps: ?*?page_cache.FileSet,
) PngError![]u8 {
    if (opts.thermal.on) return renderThermalPng(alloc, project_dir, name, opts, deps);
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    defer if (deps) |out| {
        out.* = png_cache.captureRenderDeps(alloc, &eval, module_res, project_dir, name);
    };
    const solved = try solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);
    const placement = solved.placement;
    const layer = if (opts.layer) |name_| render_pcb_png.resolveLayer(placement.rules, name_) orelse return error.InvalidLayer else null;
    const spec_status = solved.spec_status;
    const png_params = solved.params;
    // Auto name mode: a spec-driven image speaks the spec's vocabulary.
    const name_mode = opts.names orelse
        (if (spec_status != null) render_pcb_png.NameMode.origin else render_pcb_png.NameMode.ref);

    // Seed the router/DRC from the design's resolved `(design-rules …)` so the
    // PNG mirrors the same rules the interactive viewer and fab gate use.
    // `?route=1` routes fresh (same plan-lowering seam as route_pcb, so the PNG
    // preview == commit); otherwise draw the shown layout's persisted copper
    // (page parity — see solveForRequest.restored). Either way the copper
    // is DRC-checked against the current poses, exactly like resolveShownView.
    const route_params = placement.rules.design.routeParams();
    var routed: ?router.RouteResult = if (opts.route) blk: {
        var route_options = route_plan.lowerOrEmpty(alloc, solved.block, placement);
        route_options.existing_zones = solved.shown_zones.sources;
        const seeded = pcb_layout_seeds.routeWithSubcircuitSeeds(alloc, project_dir, solved.block, placement, route_params, route_options) catch break :blk null;
        break :blk seeded.result;
    } else solved.restored.routes;
    if (opts.route) routed = perimeter_fence.append(alloc, placement, routed) catch routed;
    // One board, one lattice: every fill below — the reporting DRC's rasters
    // AND the renderer's paint of the same copper — seeds from this single
    // outline walk (what `resolveShownView` already does for the page). See
    // `render_pcb_png.PourInputs`; a null field is the historical behaviour.
    const base_edge = pour.sharedEdgeField(alloc, placement) catch null;
    const violations: []const drc.Violation = if (routed) |r|
        drc_rules.checkFilteredZones(alloc, project_dir, name, .{ .placement = placement, .routed = r, .clearance = route_params.clearance, .zones = solved.shown_zones.user, .base_edge = base_edge })
    else
        &.{};

    // `?cropnet=` zoom lens: viewport = the named nets' pads + copper (whatever
    // `routed` holds now — restored or fresh) + margin. `crop=` (a single part)
    // still wins in renderCanvas when both are set.
    const view_bbox: ?[4]f64 = if (opts.crop_nets.len > 0)
        (render_pcb_png.cropNetBbox(alloc, placement, routed, opts.crop_nets, render_pcb_png.cropnet_margin_mm) catch null)
    else
        null;

    // Optional compare layout for the diff overlay (ghost + movement arrows).
    var cmp_placement: ?optimizer.Placement = null;
    if (opts.compare) |cn| {
        if (readLayoutPosesFor(alloc, project_dir, name, cn, solved.block, opts.sub)) |cposes| {
            // Display-only ghost compare — the outline plays no part.
            cmp_placement = optimizer.placeFromPoses(alloc, solved.block, project_dir, .{ .poses = cposes, .outline = .authored_only }, png_params) catch null;
        }
    }

    const ropts = render_pcb_png.Options{
        .layer = layer,
        .width = opts.width,
        .highlight_nets = opts.highlight_nets,
        .highlight_refs = opts.highlight_refs,
        .routed = routed,
        .violations = violations,
        .title = solved.title,
        .params = png_params,
        .blame = opts.blame,
        .loop_labels = opts.loop_labels,
        .dims = opts.dims,
        .grid = opts.grid,
        .compare = cmp_placement,
        .names = name_mode,
        .pin_refs = opts.pins,
        .spec = spec_status,
        .crop = opts.crop,
        .crop_r = opts.crop_r,
        .view_bbox = view_bbox,
        .critique = opts.critique,
        .texts = solved.texts,
        .user_zones = solved.shown_zones.user,
        .silk_keepouts = solved.shown_zones.silk_keepouts,
        .pours = .{ .base_edge = base_edge },
    };
    if (opts.sheet) return render_pcb_png.renderSheet(alloc, placement, ropts);
    return render_pcb_png.render(alloc, placement, ropts);
}

/// Parse a `PngRequest` from an HTTP query string — shared by the PNG endpoint
/// and `/api/pcb-describe` so both accept the identical parameter set (and so
/// the facts always describe the placement the image shows).
pub fn pngRequestFromQuery(arena: std.mem.Allocator, req: *httpz.Request) PngRequest {
    const width: u32 = blk: {
        const q = req.query() catch break :blk png_default_width;
        const wv = q.get("width") orelse break :blk png_default_width;
        break :blk std.fmt.parseInt(u32, wv, 10) catch png_default_width;
    };
    return .{
        .layer = queryOpt(req, "layer"),
        .width = width,
        .highlight_nets = csvParam(arena, req, "nets"),
        .highlight_refs = csvParam(arena, req, "refs"),
        .route = queryFlag(req, "route"),
        .layout = queryOpt(req, "layout"),
        .regen = queryFlag(req, "regen"),
        .sub = subSlug(req),
        .court_overlap = blk: {
            const q = req.query() catch break :blk 0;
            const v = q.get("court_overlap") orelse break :blk 0;
            break :blk std.fmt.parseFloat(f64, v) catch 0;
        },
        .route_gap = blk: {
            const q = req.query() catch break :blk 0;
            const v = q.get("route_gap") orelse break :blk 0;
            break :blk std.fmt.parseFloat(f64, v) catch 0;
        },
        .group = .{
            .w = pngFloatOpt(req, "group_w"),
            .zone_w = pngFloatOpt(req, "group_zone_w"),
            .loop_relief = pngFloatOpt(req, "group_loop_relief"),
        },
        .zone_pack = queryFlag(req, "zone_pack"),
        .rough = queryFlag(req, "rough"),
        .remaining = queryFlag(req, "remaining"),
        .blame = queryFlag(req, "blame"),
        .loop_labels = queryFlag(req, "loops"),
        .dims = queryFlag(req, "dims"),
        .grid = queryFlag(req, "grid"),
        .compare = queryOpt(req, "compare"),
        .names = blk: {
            const v = queryOpt(req, "names") orelse break :blk null;
            break :blk std.meta.stringToEnum(render_pcb_png.NameMode, v);
        },
        .pins = csvParam(arena, req, "pins"),
        .crop = queryOpt(req, "crop"),
        .crop_r = blk: {
            const q = req.query() catch break :blk 6;
            const v = q.get("r") orelse break :blk 6;
            break :blk std.fmt.parseFloat(f64, v) catch 6;
        },
        .crop_nets = csvParam(arena, req, "cropnet"),
        .pads = queryFlag(req, "pads"),
        .sheet = queryFlag(req, "sheet"),
        .critique = queryFlag(req, "critique"),
        .thermal = .{
            .on = queryFlag(req, "thermal"),
            .scenario = parseScenario(queryOpt(req, "scenario")),
            .ambient_c = blk: {
                const q = req.query() catch break :blk null;
                const v = q.get("ambient") orelse break :blk null;
                break :blk std.fmt.parseFloat(f64, v) catch null;
            },
        },
    };
}

/// GET /api/pcb-png/:name — render the solved layout as a PNG so an AI agent (or
/// any HTTP client) can *see* it, not just parse the coordinate JSON.
///
/// Query parameters (all optional):
///   width=<px>            output width (clamped); height follows the board
///   nets=A,B  refs=U1,C3  focus mode — spotlight these nets/components, dim rest
///   route=1               route fresh and draw copper + DRC markers; WITHOUT
///                         it the shown layout's persisted copper is restored,
///                         DRC-checked, and drawn (page parity)
///   cropnet=A,B           zoom the viewport to these nets' pads + copper + a
///                         ~1.5 mm margin (when both crop= and cropnet= are
///                         given, crop= wins)
///   layout=<name>         render a specific saved layout (else the starred ★
///                         default if set, else the auto cache)
///   regen=1               force a fresh solve instead of the cache
///   sub=<slug>            scope to one sub-block (per-sub-block preview)
///   names=ref|origin|both part labels: ref-des, spec origin name, or REF=ORIGIN
///                         (default: origin when a (placement …) spec drives)
///   pins=U13,C5           label these parts' pads with net names ("hubs" = all)
///   thermal=1             paint the HEAT FIELD over this board instead of its
///                         copper — the picture twin of /api/thermal/:name
///   scenario=natural|fan|airflow_1ms|airflow_2ms|heatsink|fan_heatsink
///                         which cooling scenario the heat field is solved for
///                         (thermal=1 only; default natural)
///   ambient=NN            ambient °C the heat image's absolute temperatures
///                         are printed at (thermal=1 only; default 25)
///
/// `thermal=1` ignores the copper view's own parameters — nets/refs focus,
/// route, crop/cropnet, sheet, critique, compare, blame, loops, dims, grid,
/// pins and names — because they describe copper the heat image does not draw;
/// width/layout/regen/rough/remaining/sub still choose and frame the board.
///
/// Request-scoped allocation uses `req.arena` (freed after the response is sent;
/// `res.body` stays valid until then) — `ctx.allocator` is the global page
/// allocator, so a leaked image per call would never be reclaimed.
///
/// The body lives in `serve/png_cache.zig`, which answers the allow-listed
/// query modes from a dependency-validated retention and renders the rest here.
pub fn pcbPngApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    return png_cache.serveImage(ctx, req, res);
}

// spec: Web Server - The PCB layout page renders without a request, reading a missing request as the plain no-query page, so the startup warm-up can retain it under the same cache entry a bare URL looks up
test "no request reads as the plain no-query page" {
    try std.testing.expect(!isEmbed(null));
    try std.testing.expect(!queryFlag(null, "edit"));
    try std.testing.expect(!isPhysicalReview(null, true, false));
    try std.testing.expect(queryOpt(null, "layout") == null);
    try std.testing.expect(subSlug(null) == null);
    const tg = parseToggles(null);
    try std.testing.expect(!tg.clr and !tg.drc);
    const tn = parseTuning(null);
    try std.testing.expect(!tn.tuned and !tn.regen and !tn.show_cache);
    // Route params fall back to the caller's base, and nothing asks to route.
    const ro = parseRoute(null, .{ .track_width = 0.2 });
    try std.testing.expect(!ro.run);
    try std.testing.expectEqual(@as(f64, 0.2), ro.params.track_width);
}

// spec: serve/thermal-page - the thermal board frame omits generated CAM artwork, routed copper, DRC, pour geometry, and editor-only layout metadata because its exclusive heat overlay hides that data
test "the thermal board frame omits data hidden by its overlay" {
    try std.testing.expect(needsCamPreview(true, false));
    try std.testing.expect(!needsCamPreview(true, true));
    try std.testing.expect(!needsCamPreview(false, false));
    const layouts = [_]SavedLayout{.{ .name = "saved", .kind = kind_manual, .ts = 0, .score = null, .parts = &.{} }};
    try std.testing.expectEqual(@as(usize, 1), pcb_layout_blob.payloadLayouts(&layouts, false).len);
    try std.testing.expectEqual(@as(usize, 0), pcb_layout_blob.payloadLayouts(&layouts, true).len);
}

// spec: Web Server - The initial Assembly iframe omits hidden DRC, editable-layout metadata, editor-only scripts, and inline CAM while exposing the lazy generated-files URL
test "assembly iframe exposes lazy CAM and omits editor-only clients" {
    try std.testing.expect(!needsPageReporting(true, false, false));
    try std.testing.expect(needsPageReporting(true, false, true));
    try std.testing.expect(!needsPageReporting(false, true, true));
    try std.testing.expect(needsPageReporting(false, false, false));
    var cam: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer cam.deinit();
    try pcb_layout_blob.writeCamFields(&cam.writer, "demo", .{
        .read_only = true,
        .embed = true,
        .assembly_review = true,
        .cam_lazy = true,
        .sub = null,
        .shown_layout = "RF final",
    });
    try std.testing.expectEqualStrings(
        ",\"cam_url\":\"/api/pcb-cam/demo?cam=1&layout=RF%20final\",\"cam\":null",
        cam.written(),
    );

    var scripts: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer scripts.deinit();
    try writePageScripts(&scripts.writer, .{
        .physical_review = true,
        .model_sprites = false,
        .thermal_overlay = false,
        .embed = true,
    });
    const html = scripts.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "pcb_board.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "shape_sketch.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "drc_marshal.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pcb_settings.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pcb_replay.js") == null);
}

/// True when query `key` is present and not "0"/empty (a boolean toggle).
pub const queryFlag = pcb_query.flag;

/// True when the request asks to KEEP Do-Not-Populate parts in the centroid
/// CSV (`?dnp=keep`). Default (absent / any other value) drops them — the
/// assembler's pick-and-place file should only carry stuffed parts.
pub fn queryKeepDnp(req: *httpz.Request) bool {
    return if (pcb_query.raw(req, "dnp")) |value| std.mem.eql(u8, value, "keep") else false;
}

/// `?dnp=keep` → keep DNP parts in the centroid; anything else drops them.
pub fn dnpMode(req: *httpz.Request) export_fab.DnpMode {
    return if (queryKeepDnp(req)) .keep else .drop;
}

/// Query `key` as a float, or -1 when absent/unparseable — the "unset" sentinel
/// the PNG path uses to keep the optimizer's own default for a group knob.
const pngFloatOpt = pcb_query.floatOpt;

/// Query `key` exactly as sent, keeping a present-but-empty value distinct
/// from an absent one — the layout selectors treat `?layout=` as naming a
/// layout (and 404 on it) rather than as no selection at all.
const queryRaw = pcb_query.raw;

/// Query `key` as an optional string (absent/empty → null).
pub const queryOpt = pcb_query.opt;

/// Split a comma-separated query parameter into trimmed, non-empty tokens
/// (slices into the request's query buffer). Empty/absent → empty slice.
const csvParam = pcb_query.csv;

/// Serialize a placement for the JSON export: name, generated flag, the steering
/// weights, the visible `score`, the full objective `breakdown` (raw terms plus
/// their weighted contributions and the summed objective), the bounding box, and
/// each part's `ref/kind/x/y/rot/hw/hh`.
/// World position (mm) of a footprint-local pad on a placed part — the
/// optimizer's OWN transform (bottom-side local-x mirror, then rotation), so
/// the `leg_mm` this JSON reports is the length the placer measured. The local
/// rotate-only copy this replaces dropped the mirror, putting a flipped part's
/// pad `2·|local x|` away from where the board draws it.
pub fn worldPad(pt: optimizer.Part, pad: optimizer.PadRect) [2]f64 {
    return optimizer.worldPadCenter(&pt, pad.x, pad.y);
}

// spec: Web Server - The layout JSON measures a decoupling leg through the optimizer's own pad transform, so a bottom-side cap's leg_mm is the length the placer scored
test "the layout JSON's loop legs honour a bottom-side part's mirror" {
    const hub = optimizer.Part{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 0, .y = 0 };
    // Flipped, 4 mm right of the hub, power pad 3 mm out along local +x. Bottom
    // mirrors local x before rotating, so the pad is at 1 mm — the unmirrored
    // reading puts it at 7 mm, `2·|local x|` = 6 mm of pure error in the
    // `leg_mm` the viewer draws its loop against.
    const cap = optimizer.Part{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 4, .y = 0, .side = .bottom };
    const cap_pwr = optimizer.PadRect{ .x = 3, .y = 0, .w = 0.5, .h = 0.5 };
    const hub_pwr = optimizer.PadRect{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 };

    const cw = worldPad(cap, cap_pwr);
    try std.testing.expectEqual(optimizer.worldPadCenter(&cap, cap_pwr.x, cap_pwr.y), cw);
    const hp = worldPad(hub, hub_pwr);
    try std.testing.expectApproxEqAbs(@as(f64, 1), std.math.hypot(cw[0] - hp[0], cw[1] - hp[1]), 1e-12);

    // A rotated TOP-side part is unaffected: the mirror is the only thing that
    // was missing, and it must not start applying to parts that are not flipped.
    var turned = cap;
    turned.side = .top;
    turned.rot = 90;
    try std.testing.expectEqual(optimizer.worldPadCenter(&turned, cap_pwr.x, cap_pwr.y), worldPad(turned, cap_pwr));
}

// ── Live regen: background solve + best-so-far progress stream ──────────
//
// The "Regenerate" button no longer blocks the page on an 11–16 s solve.
// Instead it POSTs /api/pcb-regen-start, which spawns the optimizer on a
// background thread with a progress sink; the browser polls /api/pcb-progress
// and re-draws the board each time the optimizer finds a better arrangement, so
// you watch it converge instead of waiting on a spinner. When the run finishes
// the thread has written the auto-cache exactly as the synchronous path does,
// so the page just reloads to pick up the final (routable, history-recorded)
// layout.

/// Work item for a background live-regen solve. `name` is page_allocator-owned
/// (freed by the thread); `project_dir` is borrowed from the long-lived Server,
/// which outlives every request thread.
const RegenJob = struct {
    name: []const u8,
    project_dir: []const u8,
    params: optimizer.Params,
    gen: u32,
};

/// Context the optimizer's progress sink carries: which design + generation a
/// streamed frame belongs to. Lives on the solver thread's stack for the solve.
const RegenProgress = struct { name: []const u8, gen: u32 };

/// optimizer.ProgressSink callback: serialize the best-so-far poses to a compact
/// frame and publish it under the job's design + generation. Best-effort — a
/// formatting/alloc failure just drops this frame (the next improvement retries).
fn regenOnBest(ctx_ptr: *anyopaque, parts: []const optimizer.Part, score: f64, pass: optimizer.ProgressPass) void {
    const ctx: *RegenProgress = @ptrCast(@alignCast(ctx_ptr));
    var aw: std.Io.Writer.Allocating = .init(process_alloc.durable);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("{{\"pass\":\"{s}\",\"score\":{d:.2},\"parts\":[", .{ pass.label(), score }) catch return;
    for (parts, 0..) |p, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll(ref_open) catch return;
        writeJsonStr(w, p.ref_des) catch return;
        w.print(",\"x\":{d:.3},\"y\":{d:.3},\"rot\":{d:.0}}}", .{ p.x, p.y, p.rot }) catch return;
    }
    w.writeAll("]}") catch return;
    serve_root.pcbJobFrame(ctx.name, ctx.gen, aw.written());
}

/// Background thread: re-evaluate the design in its own arena, run the optimizer
/// with a progress sink streaming best-so-far frames, persist the result the same
/// way the synchronous page does, then mark the job done so the browser reloads.
fn regenThread(job: *RegenJob) void {
    const base = process_alloc.durable;
    defer {
        base.free(job.name);
        base.destroy(job);
    }
    var arena = std.heap.ArenaAllocator.init(base);
    defer arena.deinit();
    const a = arena.allocator();

    var had_err = true;
    run: {
        var eval = Evaluator.init(a, job.project_dir);
        defer eval.deinit();
        var module_res: ?modules_mod.ResolvedBlock = null;
        defer if (module_res) |mr| {
            mr.eval.deinit();
            a.destroy(mr.eval);
        };
        const block = resolveBlock(a, job.project_dir, job.name, &eval, &module_res) orelse break :run;

        var prog = RegenProgress{ .name = job.name, .gen = job.gen };
        optimizer.setProgressSink(.{ .ctx = &prog, .onBest = regenOnBest });
        defer optimizer.setProgressSink(null);

        // "Rough remaining": pin the base layout (★ else auto cache) and place
        // only the parts it doesn't cover.
        const cached: ?[]const optimizer.RefPose = if (job.params.remaining) blk: {
            if (defaultLayoutName(a, job.project_dir, job.name, null)) |dn| {
                if (readLayoutPosesFor(a, job.project_dir, job.name, dn, block, null)) |ps| break :blk ps;
            }
            break :blk readAutoPoses(a, job.project_dir, job.name);
        } else null;
        const placement = optimizer.solve(a, block, job.project_dir, cached, job.params, .place) catch break :run;
        if (placement.generated) {
            writeAutoCache(a, job.project_dir, job.name, placement, job.params);
            recordAutoLayout(a, job.project_dir, job.name, placement, job.params);
        }
        had_err = false;
    }
    serve_root.pcbJobFinish(job.name, job.gen, if (had_err) .failed else .ok);
}

/// POST /api/pcb-regen-start/:name — kick off a live (background) optimizer run
/// and return its generation id. The browser then polls /api/pcb-progress/:name
/// to animate the board converging and reloads when the run finishes. Honours the
/// same tuning query (?w_align / loop_w / w_congest / grid) as ?regen=1.
/// If a run for this design is already in flight, its generation is returned and
/// no second solver is spawned (one per design at a time).
pub fn pcbRegenStartApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const tune = parseTuning(req);
    const begin = serve_root.pcbJobBegin(name);
    if (begin.fresh) spawn: {
        const job = process_alloc.durable.create(RegenJob) catch {
            serve_root.pcbJobFinish(name, begin.gen, .failed);
            break :spawn;
        };
        job.* = .{
            .name = process_alloc.durable.dupe(u8, name) catch {
                process_alloc.durable.destroy(job);
                serve_root.pcbJobFinish(name, begin.gen, .failed);
                break :spawn;
            },
            .project_dir = ctx.project_dir,
            .params = tune.params,
            .gen = begin.gen,
        };
        const t = std.Thread.spawn(.{}, regenThread, .{job}) catch {
            process_alloc.durable.free(job.name);
            process_alloc.durable.destroy(job);
            serve_root.pcbJobFinish(name, begin.gen, .failed);
            break :spawn;
        };
        t.detach();
    }
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try aw.writer.print("{{\"gen\":{d}}}", .{begin.gen});
    res.content_type = .JSON;
    res.body = aw.written();
}

/// GET /api/pcb-progress/:name — current live-regen state for the page's poll
/// loop: the active generation, the frame sequence (so the client skips frames
/// it already drew), run/done/err flags, and the latest best-so-far `frame`
/// (`{pass,score,parts}`) or null. `{"gen":0,"none":true}` means no run has been
/// started for this design.
pub fn pcbProgressApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    res.content_type = .JSON;
    const snap = serve_root.pcbJobSnapshot(ctx.allocator, name) orelse {
        res.body = "{\"gen\":0,\"none\":true}";
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.print("{{\"gen\":{d},\"seq\":{d},\"running\":{s},\"done\":{s},\"err\":{s},\"frame\":", .{
        snap.gen,
        snap.seq,
        if (snap.running) "true" else "false",
        if (snap.done) "true" else "false",
        if (snap.err) "true" else "false",
    });
    if (snap.frame) |f| try w.writeAll(f) else try w.writeAll("null");
    try w.writeByte('}');
    res.body = aw.written();
}

/// POST /api/pcb-score/:name — score an arbitrary hand layout *on the server*,
/// reusing the optimizer's own objective code (no metric duplicated in JS). Body
/// is the same `{"parts":[{ref,x,y,rot}, …]}` the save endpoint takes; returns
/// the full breakdown for those exact positions. Honours the ?tuning query.
pub fn pcbScoreApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const body = bodyParam(req, res) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = bad_json_msg;
        return;
    };
    if (root != .object) {
        res.status = 400;
        return;
    }
    const parts_v = root.object.get("parts") orelse {
        res.status = 400;
        return;
    };
    if (parts_v != .array) {
        res.status = 400;
        return;
    }
    // Everything here is request-scoped; use req.arena (reclaimed after the
    // response is sent) — NOT ctx.allocator (the global page_allocator, never
    // freed: an agent hammering this endpoint for a layout search would OOM the
    // server, since each call allocates the parsed design + full scorePoses set).
    const arena = req.arena;
    var poses: std.ArrayList(optimizer.RefPose) = .empty;
    for (parts_v.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(arena, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
            .side = jsonSide(it.object.get("side")),
            .locked = jsonFlag(it.object.get("locked")),
        });
    }

    var eval = Evaluator.init(arena, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        arena.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(arena, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = no_block_msg;
        return;
    };
    const eff_block = if (subSlug(req)) |s|
        (descendToSub(arena, block, s) orelse {
            res.status = 404;
            res.body = no_sub_msg;
            return;
        }).block
    else
        block;

    const tune = parseTuning(req);
    // The live Heatmap asks for per-part blame (`"blame":true`, sent only while
    // the view is on) so a drag refreshes the tint. That needs a built Placement
    // (perPartBlame attributes over its parts/links/loops), so we take the
    // heavier placeFromPoses path — whose breakdown is the same scoreLayout +
    // surrogateLoops the light scorePoses returns, so the score bar never jumps.
    // Without the flag, stay on the cheap surrogate-only score (no Placement).
    const want_blame = blk: {
        const v = root.object.get("blame") orelse break :blk false;
        break :blk v == .bool and v.bool;
    };
    const refresh_ref: ?[]const u8 = blk: {
        const value = root.object.get("refresh") orelse break :blk null;
        break :blk if (value == .string and value.string.len > 0) value.string else null;
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    if (want_blame or refresh_ref != null) {
        // Scoring only — no score term reads the board outline.
        const placement = optimizer.placeFromPoses(arena, eff_block, ctx.project_dir, .{ .poses = poses.items, .outline = .authored_only }, tune.params) catch {
            res.status = 500;
            res.body = "score error";
            return;
        };
        const blame = pcb_layout_blob.partBlameRaw(arena, placement, tune.params);
        try aw.writer.writeByte('{');
        try pcb_layout_blob.writeBreakdownFields(&aw.writer, placement.breakdown, tune.params);
        try aw.writer.writeAll(",\"blame\":{");
        for (placement.parts, 0..) |pt, i| {
            if (i > 0) try aw.writer.writeByte(',');
            try writeJsonStr(&aw.writer, pt.ref_des);
            try aw.writer.print(":{d:.4}", .{if (i < blame.len) blame[i] else 0});
        }
        try aw.writer.writeAll("}");
        if (refresh_ref) |ref| {
            try aw.writer.writeAll(",");
            if (!try writePlacementRefresh(&aw.writer, arena, ctx.project_dir, placement, ref)) {
                res.status = 404;
                res.body = "part no longer exists after footprint update";
                return;
            }
        }
        try aw.writer.writeAll("}");
    } else {
        const bd = optimizer.scorePoses(arena, eff_block, ctx.project_dir, poses.items, tune.params) catch {
            res.status = 500;
            res.body = "score error";
            return;
        };
        try pcb_layout_blob.writeBreakdownJson(&aw.writer, bd, tune.params);
    }
    res.content_type = .JSON;
    res.body = aw.written();
}

/// The exact part geometry the PCB client must replace after a passive package
/// edit. Poses come from the request, so refreshing a package never moves any
/// part or disturbs the user's current viewport/editor state.
fn writePlacementRefresh(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    placement: optimizer.Placement,
    ref: []const u8,
) HandlerError!bool {
    var part_index: ?usize = null;
    for (placement.parts, 0..) |part, i| {
        if (std.mem.eql(u8, part.ref_des, ref)) part_index = i;
    }
    const selected = part_index orelse return false;

    var pin_net = std.StringHashMapUnmanaged([]const u8).empty;
    for (placement.nets) |net| for (net.pins) |pin| {
        const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
        try pin_net.put(alloc, key, netKey(net.name));
    };

    try w.writeAll("\"refresh\":{\"part\":");
    try pcb_part_json.writePartJson(w, alloc, placement, selected, 0, pin_net);
    try w.writeAll(",\"models\":");
    if (selected < placement.instances.len)
        try pcb_layout_blob.writeModelsJson(w, alloc, project_dir, placement.instances[selected .. selected + 1])
    else
        try w.writeAll("{}");
    try w.writeAll("}");
    return true;
}

/// A parsed viewer Route scope: the incremental `ScopedRoute` to route with
/// (empty ⇒ whole board), plus the resolved scope's `unknown` tokens and
/// `selected` net count for the response.
const ViewerScope = struct {
    scoped: route_plan.ScopedRoute = .{},
    unknown: []const []const u8 = &.{},
    selected: usize = 0,
};

/// Parse the viewer Route request's optional `groups`/`nets` scope (the same
/// generic tokens the `route_pcb` CLI tool accepts) plus the client's current
/// on-screen copper into an incremental `ScopedRoute`. With a scope named, only
/// the scoped nets route and every OTHER net's submitted copper is retained as
/// an obstacle (and echoed back), so the viewer's Route button becomes a true
/// incremental re-route. No scope named ⇒ a whole-board route (empty result).
fn parseViewerRouteScope(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!ViewerScope {
    const groups = mcpArgStrList(alloc, root, "groups");
    const nets = mcpArgStrList(alloc, root, "nets");
    const resolved = try route_plan.resolveScope(alloc, block, placement, .{ .groups = groups, .nets = nets });
    if (resolved.selectors == 0) return .{ .unknown = resolved.unknown };
    // Retain the client's copper for every net NOT in the scope (an empty scope
    // that matched nothing keeps ALL of it ⇒ a safe no-op that only reports the
    // unknown token).
    const empty_rr: router.RouteResult = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const submitted: router.RouteResult = if (parseSavedRoutes(alloc, root)) |sr|
        (restoreRoutes(alloc, routesWithPerimeter(alloc, placement, sr).?, placement.nets) orelse empty_rr)
    else
        empty_rr;
    const existing = try pcb_layout_mcp.mcpExistingCopper(alloc, submitted, resolved.mask);
    return .{
        .scoped = .{
            .selected = resolved.mask,
            .existing_tracks = existing.tracks,
            .existing_vias = existing.vias,
        },
        .unknown = resolved.unknown,
        .selected = resolved.matched,
    };
}

/// What one route's scope resolution reports back in the response, as opposed
/// to what it routes WITH (`RoutePrep.scoped`): how many nets the selectors
/// matched, and every selector token that matched nothing. Purely an echo, so a
/// caller cannot mistake it for something the router consulted. Deliberately
/// module-private: every construction site is in this file, and a caller that
/// merely reads `prep.echo.selected` needs no name for the type.
const ScopeEcho = struct {
    /// How many nets the scope selected (0 = whole board).
    selected: usize = 0,
    /// Scope tokens that matched nothing, echoed back to the caller.
    unknown: []const []const u8 = &.{},
};

/// Everything the shared route pipeline resolves at request time from a
/// `POST /api/pcb-route` body — the placement at the client's poses, the route
/// params, the incremental scope, and the posted user pours. Built once by
/// `prepareRouteFromJson` and consumed by BOTH the blocking handler and the
/// background live-route job, so the two can never parse or place differently.
pub const RoutePrep = struct {
    /// The (possibly sub-block-descended) block the placement was built from.
    eff_block: *const env_mod.DesignBlock,
    /// The placement at the submitted poses (never re-optimized).
    placement: optimizer.Placement,
    /// Router geometry from the body; absent fields keep the router default.
    rp: router.RouteParams,
    /// The incremental scope + retained copper/zones the route runs with.
    scoped: route_plan.ScopedRoute,
    /// Posted user pours credited toward the connectivity DRC.
    user_zones: []const pour.UserZone,
    /// What the scope resolution has to SAY back to the caller (`ScopeEcho`) —
    /// carried together because it is one answer, and because neither half
    /// steers the route: `scoped` already does that.
    echo: ScopeEcho = .{},
    /// The body's `"effort"` override for THIS run only, or null to keep the
    /// block's authored `(route (effort …))`. The viewer's "Route plan" action
    /// sends `one_shot` so a preview of a fresh seed answers in seconds instead
    /// of climbing the rescue ladder; nothing is persisted either way.
    steering: struct {
        effort: ?route_policy.Effort = null,
        resume_points: []const route_resume.Point = &.{},
    } = .{},
};

/// Why `prepareRouteFromJson` could not build a `RoutePrep` — each variant maps
/// onto the exact status/body the blocking handler answered before the
/// extraction (and onto the live start endpoint's JSON errors).
pub const RoutePrepError = error{
    /// The body carried no `parts` array (or a non-array one).
    MissingParts,
    /// No design or module by that name.
    BlockNotFound,
    /// The `?sub=` slug names no sub-block.
    SubNotFound,
    /// `placeFromPoses` failed on the submitted poses.
    PlacementFailed, // UNTESTED-ERROR: Existing fab selection failure, unchanged by the CLI module extraction. // UNTESTED-ERROR: Existing fab selection failure, unchanged by the CLI module extraction.
    /// The `groups`/`nets` scope could not be resolved.
    ScopeFailed,
    OutOfMemory,
};

/// Inputs `prepareRouteFromJson` reads besides the evaluator pair — bundled so
/// the pipeline entry stays one call for both the handler and the live job.
pub const RoutePrepInputs = struct {
    project_dir: []const u8,
    name: []const u8,
    /// The `?sub=<slug>` target, or null for the whole design.
    sub: ?[]const u8 = null,
    /// The parsed `POST /api/pcb-route` body object.
    root: std.json.Value,
    /// Tier to use when this surface's caller omitted `effort`. The editor's
    /// Route board endpoints set one-shot here, which also bounds an already-
    /// open pre-upgrade page whose script predates the explicit effort field.
    /// Non-editor consumers keep null and therefore retain authored policy.
    default_effort: ?route_policy.Effort = null,
};

/// The request-time half of the ONE route pipeline the blocking
/// `POST /api/pcb-route` handler and the background live-route job share:
/// parse the body's poses/params/scope/zones, resolve the block, and build the
/// placement at the submitted poses. Everything durable is allocated from
/// `alloc` (the live job passes its job arena so the result outlives the
/// request); `eval`/`module_res` are caller-owned so each caller controls
/// their lifetime.
pub fn prepareRouteFromJson(
    alloc: std.mem.Allocator,
    in: RoutePrepInputs,
    eval: *Evaluator,
    module_res: *?modules_mod.ResolvedBlock,
) RoutePrepError!RoutePrep {
    const root = in.root;
    if (root != .object) return error.MissingParts;
    const parts_v = root.object.get("parts") orelse return error.MissingParts;
    if (parts_v != .array) return error.MissingParts;
    var poses: std.ArrayList(optimizer.RefPose) = .empty;
    for (parts_v.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(alloc, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
            .side = jsonSide(it.object.get("side")),
            .locked = jsonFlag(it.object.get("locked")),
        });
    }

    // Route params from the body (mm); a missing or non-positive field keeps the
    // router default — the same fields the GET ?route=1 query carries.
    var rp = router.RouteParams{};
    const tw = jsonNum(root.object.get("track_width"));
    if (tw > 0) rp.track_width = tw;
    const cl = jsonNum(root.object.get(clearance_key));
    if (cl > 0) rp.clearance = cl;
    const vd = jsonNum(root.object.get("via_drill"));
    if (vd > 0) rp.via_drill = vd;
    const va = jsonNum(root.object.get("via_dia"));
    if (va > 0) rp.via_dia = va;

    const block: *env_mod.DesignBlock = resolveBlock(alloc, in.project_dir, in.name, eval, module_res) orelse
        return error.BlockNotFound;
    const eff_block = if (in.sub) |s|
        (descendToSub(alloc, block, s) orelse return error.SubNotFound).block
    else
        block;

    // Build the placement at the supplied poses (never re-optimized) — exactly
    // the GET ?route=1 pipeline, but on the client's layout instead of the
    // cached auto one. The outline seed (submitted body outline > blessed
    // drawn > authored) keeps the Route button's board edge in lockstep with
    // the DRC endpoint and the ?route=1 pipeline — a missing edge routes
    // copper off the board with no DRC error (the RF1_HPF bug).
    const oseed = outlineForBody(alloc, in.project_dir, in.name, in.sub, parseSavedOutline(alloc, root.object.get("outline")));
    const placement = optimizer.placeFromPoses(alloc, eff_block, in.project_dir, .{ .poses = poses.items, .outline = oseed }, optimizer.Params{}) catch
        return error.PlacementFailed; // UNTESTED-ERROR: Existing fab selection failure, unchanged by the CLI module extraction.
    // An optional groups/nets scope makes this an incremental re-route: only the
    // scoped nets route and the submitted copper for the rest is retained. No
    // scope ⇒ the empty ScopedRoute, i.e. a whole-board route (unchanged).
    const vscope = parseViewerRouteScope(alloc, root, eff_block, placement) catch
        return error.ScopeFailed;
    const resume_points = try route_resume.parse(alloc, root, placement);
    // Hand-drawn user copper pours the client posted: seed the maze with them as
    // same-net source copper (and credit them toward the connectivity DRC).
    const posted_zones = shownZones(parseSavedRoutes(alloc, root));
    var scoped = vscope.scoped;
    scoped.existing_zones = existingZonesFrom(alloc, placement, posted_zones);
    return .{
        .eff_block = eff_block,
        .placement = placement,
        .rp = rp,
        .scoped = scoped,
        .user_zones = userZonesFrom(alloc, placement.rules, posted_zones),
        .echo = .{ .selected = vscope.selected, .unknown = vscope.unknown },
        .steering = .{ .effort = route_resume.effort(root, in.default_effort), .resume_points = resume_points },
    };
}

/// The routed half of the shared pipeline's output: the router's run (timeline
/// captured only on the live path), the stuck-net diagnostics from the same
/// live grid, the rule-filtered DRC, and the return-path warning count —
/// everything `writeRoutePayload` serializes.
pub const RouteOutcome = struct {
    run: router.RouteRun,
    stuck: []const route_diagnose.Diagnosis,
    violations: []const drc.Violation,
    return_path: usize,
    subcircuit_seeds: pcb_layout_seeds.SubcircuitRouteSeedStats = .{},
    /// Connection-level plus logical-net connectivity for the returned copper.
    connectivity: fab_readiness.Tally = .{},
    /// What the ROUTER claimed before the shared oracle gate corrected
    /// `run.routed.routed` (see `route_plan.PlannedRun.claimed_routed`). Carried
    /// so the surfaces that persist this run — the cached design replay — can
    /// report the claim beside the honest count instead of inventing a zero.
    claimed_routed: usize = 0,
};

/// Lower the block's authored plan for a prepared request and overlay what THIS
/// request decided: its incremental scope, the copper/zones it retains, and the
/// optional `"effort"` tier override. One spelling, so the blocking and live
/// halves of `routePrepared` cannot come to route the same body differently.
fn preparedRouteOptions(alloc: std.mem.Allocator, prep: RoutePrep) route_policy.Options {
    var options = route_plan.lowerOrEmpty(alloc, prep.eff_block, prep.placement);
    options.selected_nets = prep.scoped.selected;
    options.existing_tracks = prep.scoped.existing_tracks;
    options.existing_vias = prep.scoped.existing_vias;
    options.existing_zones = prep.scoped.existing_zones;
    if (prep.steering.effort) |e| options.effort = e;
    options.net = route_resume.apply(alloc, prep.placement, options.net, prep.steering.resume_points);
    return options;
}

/// The route-time half of the ONE shared pipeline: run the planned scoped
/// route (with the caller's live streaming hooks — the blocking handler passes
/// `.{}`), then DRC + return-path check the SAME run. Diagnostic sibling of
/// routePlanned: it holds the live routing grid through finish so each failed
/// net can be explained without routing the board twice.
pub fn routePrepared(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    prep: RoutePrep,
    live: route_plan.LiveRoute,
) std.mem.Allocator.Error!RouteOutcome {
    var seed_stats = pcb_layout_seeds.SubcircuitRouteSeedStats{};
    var pr: route_plan.PlannedRun = if (live.sink == null and live.cancel == null and live.timeline == .off) blk: {
        const route_options = preparedRouteOptions(alloc, prep);
        const seeded = try pcb_layout_seeds.diagnoseWithSubcircuitSeeds(alloc, project_dir, prep.eff_block, prep.placement, prep.rp, route_options);
        seed_stats = seeded.seeds;
        break :blk .{
            .run = .{ .routed = seeded.diagnostic.result, .timeline = &.{} },
            .stuck = seeded.diagnostic.stuck,
            .claimed_routed = seeded.diagnostic.claimed_routed,
        };
    } else blk: {
        var base_options = preparedRouteOptions(alloc, prep);
        pcb_layout_seeds.armRouteDeadline(&base_options);
        base_options.sink = live.sink;
        var seeded_options = base_options;
        seed_stats = try pcb_layout_seeds.addSubcircuitRouteSeeds(alloc, project_dir, prep.eff_block, prep.placement, prep.rp, &seeded_options);
        break :blk try route_plan.routeLoweredLive(alloc, prep.placement, prep.rp, &seeded_options, live);
    };
    pr.run.routed = (try perimeter_fence.append(alloc, prep.placement, pr.run.routed)).?;
    const routed = pr.run.routed;
    const violations = drc_rules.checkFilteredZones(alloc, project_dir, name, .{ .placement = prep.placement, .routed = routed, .clearance = prep.rp.clearance, .zones = prep.user_zones });
    const connectivity = try fab_readiness.routableTally(alloc, prep.placement, .{ .tracks = routed.tracks, .arcs = routed.arcs, .rf_paths = routed.rf_port_outcomes, .vias = routed.vias, .zones = prep.user_zones });
    return .{ .run = pr.run, .stuck = pr.stuck, .violations = violations, .return_path = router.returnPathViolations(prep.placement, routed, router.return_path_radius_mm), .subcircuit_seeds = seed_stats, .connectivity = connectivity, .claimed_routed = pr.claimed_routed };
}

/// Serialize the shared pipeline's response fields (no surrounding braces) —
/// the exact `tracks/vias/zones/drc/unrouted/stuck/routed/total/return_path/
/// selected/scope_unknown` contract the blocking route endpoint answers. The
/// live job wraps the identical bytes as its `final` payload, so the two
/// surfaces carry one contract by construction.
pub fn writeRoutePayload(
    w: *std.Io.Writer,
    prep: RoutePrep,
    outcome: RouteOutcome,
) std.Io.Writer.Error!void {
    try pcb_layout_blob.writeRoutedArrays(w, outcome.run.routed, outcome.violations, .{ .nets = prep.placement.nets, .parts = prep.placement.parts }, null, prep.placement);
    try stuck_json.writeStuckJson(w, outcome.stuck);
    try w.print(",\"routed\":{d},\"total\":{d},\"unique_routed\":{d},\"unique_total\":{d},\"return_path\":{d},\"selected\":{d},\"scope_unknown\":", .{ outcome.run.routed.routed, outcome.run.routed.total, outcome.connectivity.unique_routed, outcome.connectivity.unique_total, outcome.return_path, prep.echo.selected });
    try pcb_layout_mcp.mcpWriteStrArray(w, prep.echo.unknown);
    try pcb_layout_seeds.writeRouteSeedStats(w, outcome.subcircuit_seeds);
}

/// Map a `RoutePrepError` onto the blocking handler's historic status + body
/// (a null body leaves the 400 empty, as the parts checks always answered).
pub fn routePrepFailure(e: RoutePrepError) struct { status: u16, msg: ?[]const u8 } {
    return switch (e) {
        error.MissingParts => .{ .status = 400, .msg = null },
        error.BlockNotFound => .{ .status = 500, .msg = no_block_msg },
        error.SubNotFound => .{ .status = 404, .msg = no_sub_msg },
        error.PlacementFailed => .{ .status = 500, .msg = placement_err_msg },
        error.ScopeFailed, error.OutOfMemory => .{ .status = 500, .msg = routing_err_msg },
    };
}

/// POST /api/pcb-route/:name — route the design at the *current on-screen* poses
/// (a loaded saved layout, or hand-dragged parts) rather than the auto-generated
/// placement, and return the copper as JSON. Body is the score endpoint's
/// `{"parts":[{ref,x,y,rot}, …]}` plus optional route params `track_width`,
/// `clearance`, `via_drill`, `via_dia` (mm; absent/0 → the router default). An
/// optional `groups`/`nets` scope (+ the current `tracks`/`vias`) makes it an
/// incremental re-route of just those nets, preserving the rest of the board.
/// Ordered `resume_points` additionally steer a selected net through the
/// manual route's fixed head and chosen destination-copper point; the client
/// extracts only the path between those hard points as its autocomplete.
/// The current `zones` array is always submitted, so whole-board and scoped
/// routes can use hand-drawn same-net pours as routing terminals.
/// An optional `"effort"` (`one_shot` / `one-shot` / `standard`) picks the retry
/// tier for THIS run only. `Route board` and `Route plan` are bounded one-shot
/// actions; the handler also defaults a missing or unrecognised field to that
/// tier so a board tab left open across a deploy cannot silently run the old
/// multi-minute policy. API clients may still explicitly send `standard` for
/// the full authored rescue behavior.
/// Response `{tracks, vias, drc, routed, total, selected, scope_unknown}` is the
/// routed-copper shape the page embeds, so the client redraws in place — no page
/// reload, which is what used to snap the layout back to auto. The body parse,
/// placement, route, and response serialization all ride the shared
/// prepare/route/write pipeline the background live-route job uses.
pub fn pcbRouteApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const body = bodyParam(req, res) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = bad_json_msg;
        return;
    };
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const prep = prepareRouteFromJson(ctx.allocator, .{
        .project_dir = ctx.project_dir,
        .name = name,
        .sub = subSlug(req),
        .root = root,
        // Route board is the bounded interactive action. New pages post this
        // explicitly; keeping the same default on the server also protects an
        // already-open page running the old client bundle. An explicit API
        // `standard` still wins over this fallback in prepareRouteFromJson.
        .default_effort = .one_shot,
    }, &eval, &module_res) catch |e| {
        const fail = routePrepFailure(e);
        res.status = fail.status;
        if (fail.msg) |m| res.body = m;
        return;
    };
    const outcome = routePrepared(ctx.allocator, ctx.project_dir, name, prep, .{}) catch {
        res.status = 500;
        res.body = routing_err_msg;
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.writeAll("{");
    try writeRoutePayload(w, prep, outcome);
    try w.writeAll("}");
    res.content_type = .JSON;
    res.body = aw.written();
}

/// POST /api/pcb-drc/:name — DRC-check the *submitted* copper (never route).
/// Body is the route endpoint's `{"parts":[{ref,x,y,rot,side}, …]}` plus the
/// on-screen copper `{"tracks":[…],"vias":[…]}` (the same SavedRoutes shape the
/// layout sidecar stores) and optional `clearance`/`outline`. It builds the
/// placement at those poses, restores the copper into the current netlist, runs
/// `drc.check` against it, and returns connection-level `routed`/`total` plus
/// UI-facing `unique_routed`/`unique_total`.
/// The completion pair comes from the shared connectivity oracle over the same
/// submitted copper, keeping the editor header current after manual edits.
/// This lets the viewer
/// verify hand-drawn copper continuously (debounced after any copper edit + on
/// Save) instead of only when the user clicks Route; `?pours=1` also recomputes live pours.
/// `?pours_only=1` returns fills before the editor's independent DRC refresh.
pub fn pcbDrcApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    // Six phases. FEEDBACK.md (2026-08-28) measured this endpoint at 7.0-11.4 s
    // on board-a, of which ~3.5 s was resolving the design and 4.3-5.3 s was
    // `placeFromPoses` — neither of them DRC. `resolve` is both of those (the
    // reconcile session's build), so a line where `resolve` is near zero is one
    // that answered from a retained placement.
    var timer = request_log.StageTimer.start();
    const name = nameParam(req, res) orelse return;
    const body = bodyParam(req, res) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = bad_json_msg;
        return;
    };
    if (root != .object) {
        res.status = 400;
        return;
    }
    const parts_v = root.object.get("parts") orelse {
        res.status = 400;
        return;
    };
    if (parts_v != .array) {
        res.status = 400;
        return;
    }
    var poses: std.ArrayList(optimizer.RefPose) = .empty;
    for (parts_v.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(ctx.allocator, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
            .side = jsonSide(it.object.get("side")),
            .locked = jsonFlag(it.object.get("locked")),
        });
    }

    // Copper-to-copper clearance rule the check measures against — the body's
    // `clearance` (mm) overrides; else the design's resolved `(design-rules …)`
    // base, applied after the placement is built below (matches ?route=1 and the
    // client's PCB.clr). Per-net `(net-class …)` overrides are applied inside
    // `drc.check` from `placement.rules.net`.
    const body_clearance = jsonNum(root.object.get(clearance_key));
    timer.lap("parse");

    // Lease this design's reconcile session and take its placement, or build one
    // into it. Evaluating and placing the design is seven to nine seconds of a
    // board-a-class request and depends on nothing the editor's copper edits
    // touch, so a session already holding one for these poses answers with it.
    var resolved = drc_reconcile.resolvePlacement(ctx, req, res, root, poses.items, name) orelse return;
    defer resolved.lease.release();
    const placement = resolved.placement;
    timer.lap("resolve");

    // Restore the client's copper into the current netlist (net NAME → index),
    // exactly as a saved layout's persisted copper is restored on page open.
    // `parseSavedRoutes` reads `tracks`/`vias` off the passed object, and the
    // client sends them at the request-body top level — so pass `root`.
    const empty_rr: router.RouteResult = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const parsed_sr = parseSavedRoutes(ctx.allocator, root);
    const rr: router.RouteResult = if (parsed_sr) |sr|
        (restoreRoutes(ctx.allocator, routesWithPerimeter(ctx.allocator, placement, sr).?, placement.nets) orelse empty_rr)
    else
        ((perimeter_fence.append(ctx.allocator, placement, empty_rr) catch null) orelse empty_rr);
    // Hand-drawn user copper pours the client posted (same `zones` array as the
    // sidecar) — credited toward connectivity and refilled below.
    const posted_zones = shownZones(parsed_sr);

    const clearance = if (body_clearance > 0) body_clearance else placement.rules.design.clearance;
    const user_zones = userZonesFrom(ctx.allocator, placement.rules, posted_zones);
    timer.lap("restore");
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    if (queryFlag(req, "pours_only")) {
        const live_copper: pour.Copper = .{ .tracks = rr.tracks, .arcs = rr.arcs, .vias = rr.vias, .rf_paths = rr.rf_port_outcomes };
        // Share one board-edge raster across every returned fill family.
        const base_edge = pour.sharedEdgeField(req.arena, placement) catch null;
        try w.writeAll("{\"pours\":");
        try pour_json.writePours(w, req.arena, placement, live_copper, user_zones, base_edge);
        try pour_json.writePlaneFillsField(w, req.arena, placement, live_copper, false, base_edge);
        try w.writeAll(",\"zone_fills\":");
        try pour_json.writeZoneFills(w, req.arena, placement, live_copper, zoneFillReqsFrom(req.arena, placement.rules, posted_zones), base_edge);
        try w.writeByte('}');
        res.content_type = .JSON;
        res.body = aw.written();
        timer.lap("pours");
        request_log.emitStages(&ctx.state.request_log, req.arena, req.url.path, name, &timer);
        return;
    }
    // Re-check what the edit can reach, against the board this session last
    // accepted. `?full=1` forces the whole-board path and re-primes — the escape
    // hatch a caller (or a test) uses to compare the two answers.
    const outcome = resolved.lease.reconcile(ctx.allocator, .{
        .project_dir = ctx.project_dir,
        .name = name,
        .board = .{
            .zones = drc_reconcile.zonesKey(user_zones),
            .aux = drc_reconcile.auxKey(rr),
            .clearance = clearance,
        },
        .copper = .{
            .placement = placement,
            .routed = rr,
            .clearance = clearance,
            .zones = user_zones,
            .base_edge = resolved.lease.edgeField(),
        },
        .full = queryFlag(req, "full"),
    });
    const violations = outcome.report.violations;
    const tally = outcome.report.tally;
    timer.lap("drc");

    try w.writeAll("{\"drc\":[");
    for (violations, 0..) |vio, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_blob.writeViolation(w, vio, .{ .nets = placement.nets, .parts = placement.parts });
    }
    try w.print("],\"n\":{d}", .{violations.len});
    if (tally) |t| try w.print(",\"routed\":{d},\"total\":{d},\"unique_routed\":{d},\"unique_total\":{d}", .{ t.routed, t.total, t.unique_routed, t.unique_total });
    // Additive only: how the answer was reached. No viewer reads these — they
    // exist so a test (and a human with curl) can tell a scoped recheck from a
    // full one without inferring it from a stopwatch.
    // …and, on the same terms, what the background full-board sweep has
    // established about this session (`drc_sweep.zig`): how many have landed,
    // which accepted generation the last one agreed about, how long ago, and
    // the disagreements it has found — a figure meant to stay 0.
    try w.print(",\"scoped\":{},\"fills\":{d},\"repoured\":{d},\"delta\":{d},\"sweep\":{{\"runs\":{d},\"rev\":{d},\"age_ms\":{d},\"discrepancies_total\":{d}}}", .{
        outcome.scoped, outcome.fills, outcome.fills_repoured, outcome.delta, outcome.sweep.runs, outcome.sweep.rev, outcome.sweep.age_ms, outcome.sweep.discrepancies_total,
    });
    if (queryFlag(req, "pours")) {
        const live_copper: pour.Copper = .{ .tracks = rr.tracks, .arcs = rr.arcs, .vias = rr.vias, .rf_paths = rr.rf_port_outcomes };
        const base_edge = pour.sharedEdgeField(req.arena, placement) catch null;
        try w.writeAll(",\"pours\":");
        try pour_json.writePours(w, req.arena, placement, live_copper, user_zones, base_edge);
        try pour_json.writePlaneFillsField(w, req.arena, placement, live_copper, false, base_edge);
        // User-zone carved fills, `zone` indexing the POSTED zones order.
        try w.writeAll(",\"zone_fills\":");
        try pour_json.writeZoneFills(w, req.arena, placement, live_copper, zoneFillReqsFrom(req.arena, placement.rules, posted_zones), base_edge);
        timer.lap("pours");
    }
    try w.writeByte('}');
    res.content_type = .JSON;
    res.body = aw.written();
    timer.lap("respond");
    request_log.emitStages(&ctx.state.request_log, req.arena, req.url.path, name, &timer);
}

/// Resolve `name`'s design block and build a placement at its blessed poses
/// (★ default → newest manual → any snapshot → optimizer cache — the same
/// preference the KiCad sync seeds from). Null (+ a client error status) when
/// the design/module doesn't resolve or has no saved layout at all — fab
/// outputs are only meaningful for a deliberately placed board.
fn blessedPlacement(ctx: *Server, req: *httpz.Request, res: *httpz.Response, name: []const u8) ?optimizer.Placement {
    var eval = Evaluator.init(req.arena, ctx.project_dir);
    var module_res: ?modules_mod.ResolvedBlock = null;
    const block: *env_mod.DesignBlock = resolveBlock(req.arena, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 404;
        res.body = no_block_msg;
        return null;
    };
    const poses = chooseSyncPoses(req.arena, ctx.project_dir, name) orelse {
        res.status = 404;
        res.body = no_saved_layout_msg;
        return null;
    };
    // Blessed drawn outline so the fab frame and any edge-aware consumer see
    // the true board edge (blessedFabView re-applies its chosen layout's own
    // outline on top, which stays authoritative for the fab package).
    return optimizer.placeFromPoses(req.arena, block, ctx.project_dir, .{
        .poses = poses,
        .outline = outlineForBody(req.arena, ctx.project_dir, name, null, null),
    }, optimizer.Params{}) catch {
        res.status = 500;
        res.body = placement_err_msg;
        return null;
    };
}

// POST /api/pcb-layouts/:name — save a named layout snapshot (kind "manual").
// Body: `{"name","parts":[{ref,x,y,rot,origin?}, …]}`. A save persists what it
// was given and scores nothing: it resolves the block only for the layer rules
// a submitted pour is checked against (`layout_save_layers`, which the
// sub-circuit capture shares), so entries land score-less. Upserts by name
// (re-save overwrites in place); a new name is prepended so the newest sits at
// the top of the list.

/// Star a block's very FIRST saved layout. Something must be starred for the
/// page to reopen on a saved board at all (`chooseLayout` falls through to the
/// optimizer cache otherwise — the "I saved, refreshed, and my edits vanished"
/// trap), and the KiCad sync + fab outputs read the ★ as the blessed board.
/// Deliberately scoped to a one-entry list: once a block has several layouts
/// the star is the user's pick, so a later save never steals it, and clearing
/// it (`setDefaultLayoutApi` with an empty name) stays cleared.
pub fn starFirstEver(layouts: []SavedLayout) void {
    if (layouts.len != 1) return;
    layouts[0].default = true;
}

/// `POST /api/pcb-layouts/:name` — persist a named layout: its poses, routed
/// copper, board outline, and silk texts. Guards an optimistic-concurrency
/// rev and rejects a self-intersecting / zero-area custom outline before
/// writing the sidecar. It does not score what it stores.
pub fn saveNamedLayoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    // Four phases, and the interesting one is `resolve` inside
    // `savedLayoutLayers`: an autosave that takes seconds is nearly all design
    // re-evaluation, which no whole-request timing could have shown (see
    // `serve/request_log.zig`).
    var timer = request_log.StageTimer.start();
    const name = nameParam(req, res) orelse return;
    const root = parseJsonObject(req, res) orelse return;
    const nm_v = root.object.get("name") orelse {
        res.status = 400;
        res.body = "no name";
        return;
    };
    if (nm_v != .string) {
        res.status = 400;
        return;
    }
    const nm = std.mem.trim(u8, nm_v.string, " \t\n\r");
    if (nm.len == 0 or nm.len > 80) {
        res.status = 400;
        res.body = "bad name";
        return;
    }
    const parts = parsePartPoses(req.arena, root.object.get("parts")) orelse {
        res.status = 400;
        res.body = "no parts";
        return;
    };
    // `?sub=` scopes the save to a sub circuit: score against that sub-block and
    // persist to its own `<design>.<sub>.layouts.json` sidecar (see writeLayoutsSub).
    const sub = subSlug(req);

    // ── Optimistic-concurrency guard ─────────────────────────────────
    // The page embedded the sidecar rev it loaded (PCB.rev); the save echoes it
    // back. If the on-disk rev moved since (a second window saved), refuse the
    // write with 409 + the current rev so the client can warn "reload to
    // continue" instead of silently clobbering the other window's edits. A body
    // with no `rev` (a legacy cached page) skips the check and just stamps —
    // "accept then stamp". The successful write bumps the rev to `disk_rev + 1`.
    //
    // The check and the write must happen under ONE hold of the sidecar lock or
    // this is a check-then-write race: two saves that both read `rev = 5` both
    // pass, both write `rev = 6`, and the first one's row is gone while both
    // clients are told `6`. So `client_rev` is only PARSED here; the authoritative
    // read-compare-write runs inside `lockSidecar` at the bottom of the handler,
    // after the expensive design resolve — which must stay outside the lock, or
    // every concurrent editor queues behind it.
    const client_rev = sidecar_store.clientRev(root.object.get("rev"));
    // Cheap pre-check on the same value, purely so an already-doomed save fails
    // fast instead of paying for a block resolve first. It decides nothing: the
    // hold below re-reads and re-compares before it writes.
    if (client_rev) |cr| {
        const seen_rev = (try readSidecarDoc(req.arena, ctx.project_dir, name, sub)).rev;
        if (cr != seen_rev) {
            res.status = 409;
            res.content_type = .JSON;
            res.body = try std.fmt.allocPrint(req.arena, "{{\"error\":\"conflict\",\"rev\":{d}}}", .{seen_rev});
            return;
        }
    }
    timer.lap("parse");
    // Resolve the block for its layer rules alone — a pour naming a layer this
    // board has not got is refused below. Nothing here judges the placement.
    const layers = layout_save_layers.savedLayoutLayers(ctx, req.arena, name, sub, &timer);
    const outline_value = root.object.get("outline");
    const saved_outline = parseSavedOutline(req.arena, outline_value);
    if (outline_value) |value| if (value == .object and value.object.get("sketch") != null and saved_outline == null) {
        res.status = 400;
        res.body = "invalid board outline sketch — repair its open, crossing, or malformed geometry";
        return;
    };
    var entry = SavedLayout{
        .name = nm,
        .kind = kind_manual,
        .ts = clock.timestamp(),
        // Saves are unscored — the objective belongs to the auto-placer, and
        // re-running it here was 98% of this handler's cost. The panel renders
        // "—" for the row until `/api/pcb-rescore` fills one in.
        .score = null,
        .parts = parts,
        .routes = parseSavedRoutes(req.arena, root.object.get("routes")),
        .outline = saved_outline,
        .fabrication_layers = parseSavedFabricationLayers(req.arena, root.object.get("fabrication_layers")),
        .heatsink = parseSavedHeatsink(root.object.get("heatsink")),
        .fan = parseSavedFan(root.object.get("fan")),
        .texts = parseSavedTexts(req.arena, root.object.get("texts")),
        .dimensions = parsePartEdgeDimensions(req.arena, root.object.get("dimensions")),
    };
    // Geometry this WRITE path refuses — a bow-tie board outline, a pour on a
    // layer this board has not got (see `saveRejection` for why each is judged
    // here and nowhere else).
    if (sidecar_json.saveRejection(req.arena, layers, entry)) |msg| {
        res.status = 400;
        res.body = msg;
        return;
    }
    // ── The guarded read-compare-write ───────────────────────────────
    // ONE hold of the sidecar lock now covers the entire span the rev guard was
    // always meant to protect: re-read the on-disk rev, re-compare it against
    // the client's, snapshot, read the current list, merge, write `rev + 1`.
    // Splitting the check from the write is what let two saves both observe
    // `rev = 5`, both pass, and both write `rev = 6` with the first one's row
    // dropped. Everything costly (the block resolve, every body parse, every
    // rejection) is already done above and stays OUTSIDE this hold, so it is
    // three file operations long and cannot serialize the editor.
    const guard = lockSidecar(name, sub);
    defer guard.unlock();

    const disk_rev = (try readSidecarDoc(req.arena, ctx.project_dir, name, sub)).rev;
    if (client_rev) |cr| if (cr != disk_rev) {
        res.status = 409;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(req.arena, "{{\"error\":\"conflict\",\"rev\":{d}}}", .{disk_rev});
        return;
    };
    const new_rev = disk_rev + 1;

    // Snapshot only a request that has passed every rejection above and will
    // actually overwrite the sidecar. Rejected idle-autosaves used to consume
    // all 20 history slots with identical copies of the last good board.
    // Best-effort; sub circuits keep multi-snapshot in-file history already.
    if (sub == null) {
        if (layoutsSidecar(req.arena, ctx.project_dir, name, null, layouts_ext)) |scp| {
            _ = history.snapshotLayouts(req.arena, ctx.project_dir, name, scp) catch null;
        }
    }
    timer.lap("snapshot");
    const existing = (try readSidecarDoc(req.arena, ctx.project_dir, name, sub)).layouts;
    var out: std.ArrayList(SavedLayout) = .empty;
    // `replaced` = found a matching row (same name, or an auto run of this
    // exact arrangement, promoted to the named keeper). The edited entry is
    // inserted at the front after the scan, keeping sidecar history newest-first
    // even when two edits share the same second-resolution timestamp.
    // An explicit NAME always lands: two named layouts may share a placement
    // (the same board routed two ways) and the score only measures placement,
    // so it can never be the reason to refuse a save the user asked for.
    var replaced = false;
    for (existing) |L| {
        const open = !replaced; // still searching for the row to update
        if (open and std.mem.eql(u8, L.name, nm)) {
            // Re-saving an existing name overwrites its poses/score and keeps
            // its default status — the user re-captured under the same name.
            entry.default = L.default;
            replaced = true;
        } else if (open and entry.score != null and std.mem.eql(u8, L.kind, kind_auto) and sameLayoutScore(L.score, entry.score)) {
            // Same arrangement as an auto run → promote it to this named keeper
            // rather than leaving a duplicate behind. Score is the only evidence
            // of sameness there is, and a save no longer computes one, so this
            // never fires today and a duplicate auto row simply stays. Guarded
            // explicitly rather than deleted: the check is exact when a score
            // does exist, and there is no pose-level substitute for it.
            entry.default = L.default;
            replaced = true;
        } else try out.append(req.arena, L);
    }
    try out.insert(req.arena, 0, entry);
    starFirstEver(out.items);
    try writeLayoutsSubRev(req.arena, ctx.project_dir, name, sub, out.items, new_rev);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d}}}", .{new_rev});
    timer.lap("write");
    request_log.emitStages(&ctx.state.request_log, req.arena, req.url.path, name, &timer);
}

/// GET /api/pcb-layout-history/:name — list the design's `.layouts.json`
/// snapshots (newest first) as `{"snapshots":[{"id":…}, …]}`. Each Save/Update
/// rolls the previous sidecar into history; this backs a restore picker.
pub fn pcbLayoutHistoryApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const snaps = history.listLayoutSnapshots(req.arena, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "history unavailable";
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    const w = &aw.writer;
    try w.writeAll("{\"snapshots\":[");
    for (snaps, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonStr(w, s.id);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = aw.written();
}

/// POST /api/pcb-layout-history/:name/restore — swap a `.layouts.json` snapshot
/// back into the live sidecar. Body `{"id":"<timestamp>"}`. Snapshots the
/// CURRENT sidecar first (the restore is itself undoable) and bumps the rev, so
/// any window still holding the pre-restore rev 409s on its next save instead
/// of clobbering the restored state. Design-level only (sub circuits keep
/// multi-snapshot in-file history). Returns `{"ok":true,"rev":N}`.
pub fn restoreLayoutHistoryApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const root = parseJsonObject(req, res) orelse return;
    const id_v = root.object.get("id") orelse {
        res.status = 400;
        res.body = "no id";
        return;
    };
    if (id_v != .string) {
        res.status = 400;
        return;
    }
    const snap_path = history.layoutSnapshotPath(req.arena, ctx.project_dir, name, id_v.string) catch {
        res.status = 404;
        res.body = "snapshot not found";
        return;
    };
    const snap_data = infra_fs.cwd().readFileAlloc(req.arena, snap_path, sidecar_max_bytes) catch {
        res.status = 500;
        res.body = "snapshot read failed";
        return;
    };
    const restored = parseLayouts(req.arena, snap_data) orelse {
        res.status = 500;
        res.body = "corrupt snapshot";
        return;
    };
    // Snapshot the current sidecar so the restore itself is undoable, then write
    // the restored layouts with a bumped rev, preserving the current cache slot.
    // Rev read → snapshot → cache read → write is one read-modify-write and is
    // held as one, so a concurrent save cannot land between the snapshot and
    // the overwrite (its row would be neither restored nor recoverable).
    const guard = lockSidecar(name, null);
    defer guard.unlock();
    const disk_rev = (try readSidecarDoc(req.arena, ctx.project_dir, name, null)).rev;
    if (layoutsSidecar(req.arena, ctx.project_dir, name, null, layouts_ext)) |scp| {
        _ = history.snapshotLayouts(req.arena, ctx.project_dir, name, scp) catch null;
    }
    try writeLayoutsFile(req.arena, ctx.project_dir, name, restored, (try readDesignDoc(req.arena, ctx.project_dir, name)).cache, disk_rev + 1);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d}}}", .{disk_rev + 1});
}

fn namedLayoutMutationRev(
    req: *httpz.Request,
    res: *httpz.Response,
    project_dir: []const u8,
    design: []const u8,
    sub: ?[]const u8,
    root: std.json.Value,
) ?i64 {
    const disk_rev = (readSidecarDoc(req.arena, project_dir, design, sub) catch {
        res.status = 500;
        res.body = "cannot read saved layouts";
        return null;
    }).rev;
    const rv = root.object.get("rev") orelse return disk_rev;
    const client_rev: ?i64 = switch (rv) {
        .integer => |i| i,
        .float => |f| numeric.checkedInt(i64, f),
        else => null,
    };
    if (client_rev == null) {
        res.status = 400;
        res.body = "bad rev";
        return null;
    }
    if (client_rev.? != disk_rev) {
        res.status = 409;
        res.content_type = .JSON;
        res.body = std.fmt.allocPrint(req.arena, "{{\"error\":\"conflict\",\"rev\":{d}}}", .{disk_rev}) catch return null;
        return null;
    }
    return disk_rev;
}

/// Persist a revised named-layout list, snapshotting top-level stores first,
/// and return the optimistic-concurrency revision written to the sidecar.
///
/// Takes no lock and is only half a critical section: `disk_rev` was read (and
/// usually compared, via `namedLayoutMutationRev`) by the caller. The CALLER
/// must hold `lockSidecar(design, sub)` across both halves — see
/// `deleteNamedLayoutApi` — or the rev guard degrades to a check-then-write and
/// two mutations that read the same rev both write `rev + 1`.
pub fn commitNamedLayoutMutation(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    design: []const u8,
    sub: ?[]const u8,
    layouts: []const SavedLayout,
    disk_rev: i64,
) sidecar_store.StoreError!i64 {
    if (sub == null) {
        if (layoutsSidecar(alloc, project_dir, design, null, layouts_ext)) |sidecar_path| {
            _ = history.snapshotLayouts(alloc, project_dir, design, sidecar_path) catch null;
        }
    }
    const new_rev = disk_rev + 1;
    try writeLayoutsSubRev(alloc, project_dir, design, sub, layouts, new_rev);
    return new_rev;
}

const RenameLayoutError = error{ LayoutNotFound, NameExists };

fn renamedLayoutList(
    alloc: std.mem.Allocator,
    layouts: []const SavedLayout,
    old_name: []const u8,
    new_name: []const u8,
) (std.mem.Allocator.Error || RenameLayoutError)![]SavedLayout {
    for (layouts) |layout| if (std.mem.eql(u8, layout.name, new_name)) return error.NameExists;
    var out: std.ArrayList(SavedLayout) = .empty;
    var found = false;
    for (layouts) |layout| {
        var entry = layout;
        if (std.mem.eql(u8, entry.name, old_name)) {
            entry.name = new_name;
            found = true;
        }
        try out.append(alloc, entry);
    }
    if (!found) return error.LayoutNotFound;
    return out.items;
}

fn deletedLayoutList(
    alloc: std.mem.Allocator,
    layouts: []const SavedLayout,
    name: []const u8,
) (std.mem.Allocator.Error || error{LayoutNotFound})![]SavedLayout {
    var out: std.ArrayList(SavedLayout) = .empty;
    var found = false;
    for (layouts) |layout| {
        if (std.mem.eql(u8, layout.name, name)) {
            found = true;
        } else try out.append(alloc, layout);
    }
    if (!found) return error.LayoutNotFound;
    return out.items;
}

/// POST /api/pcb-layouts/:name/delete — drop a named layout. Body: `{"name","rev"}`.
pub fn deleteNamedLayoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const root = parseJsonObject(req, res) orelse return;
    const nm_v = root.object.get("name") orelse {
        res.status = 400;
        return;
    };
    if (nm_v != .string) {
        res.status = 400;
        return;
    }
    const sub = subSlug(req);
    // `namedLayoutMutationRev` reads and compares the rev; `commitNamedLayoutMutation`
    // snapshots and writes `rev + 1`. That is a check-then-write and is held as one.
    const guard = lockSidecar(name, sub);
    defer guard.unlock();
    const disk_rev = namedLayoutMutationRev(req, res, ctx.project_dir, name, sub, root) orelse return;
    const existing = (try readSidecarDoc(req.arena, ctx.project_dir, name, sub)).layouts;
    const remaining = deletedLayoutList(req.arena, existing, nm_v.string) catch |err| switch (err) {
        error.LayoutNotFound => {
            res.status = 404;
            res.body = "layout not found";
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const new_rev = try commitNamedLayoutMutation(req.arena, ctx.project_dir, name, sub, remaining, disk_rev);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d}}}", .{new_rev});
}

/// POST /api/pcb-layouts/:name/rename — rename one saved layout without changing its board snapshot.
/// Body: `{"name":"old","new_name":"new","rev":N}`. The destination must not already exist.
pub fn renameNamedLayoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const design = nameParam(req, res) orelse return;
    const root = parseJsonObject(req, res) orelse return;
    const old_v = root.object.get("name") orelse {
        res.status = 400;
        res.body = "no name";
        return;
    };
    const new_v = root.object.get("new_name") orelse {
        res.status = 400;
        res.body = "no new name";
        return;
    };
    if (old_v != .string or new_v != .string) {
        res.status = 400;
        return;
    }
    const new_name = std.mem.trim(u8, new_v.string, " \t\n\r");
    if (new_name.len == 0 or new_name.len > 80) {
        res.status = 400;
        res.body = "bad name";
        return;
    }
    const sub = subSlug(req);
    // Rev check → name-collision scan → write is one read-modify-write: without
    // the hold, two renames to the same new name can both pass the collision
    // scan. See `deleteNamedLayoutApi`.
    const guard = lockSidecar(design, sub);
    defer guard.unlock();
    const disk_rev = namedLayoutMutationRev(req, res, ctx.project_dir, design, sub, root) orelse return;
    const existing = (try readSidecarDoc(req.arena, ctx.project_dir, design, sub)).layouts;
    if (std.mem.eql(u8, old_v.string, new_name)) {
        for (existing) |layout| if (std.mem.eql(u8, layout.name, new_name)) {
            res.content_type = .JSON;
            res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d}}}", .{disk_rev});
            return;
        };
        res.status = 404;
        res.body = "layout not found";
        return;
    }
    const renamed = renamedLayoutList(req.arena, existing, old_v.string, new_name) catch |err| switch (err) {
        error.NameExists => {
            res.status = 409;
            res.content_type = .JSON;
            res.body = "{\"error\":\"name_exists\"}";
            return;
        },
        error.LayoutNotFound => {
            res.status = 404;
            res.body = "layout not found";
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const new_rev = try commitNamedLayoutMutation(req.arena, ctx.project_dir, design, sub, renamed, disk_rev);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d}}}", .{new_rev});
}

/// POST /api/pcb-layouts/:name/default — mark which saved layout the KiCad sync
/// seeds first-insertion placement + vias from. Body `{"name":"<layout>"}` sets
/// that entry as the (single) default; an empty/blank name clears the default.
/// A name that matches no entry just clears it. Persists the top-level
/// `"default"` field to `.layouts.json`; returns `{"ok":true}`.
pub fn setDefaultLayoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const root = parseJsonObject(req, res) orelse return;
    const nm_v = root.object.get("name") orelse {
        res.status = 400;
        return;
    };
    if (nm_v != .string) {
        res.status = 400;
        return;
    }
    const want = std.mem.trim(u8, nm_v.string, " \t\n\r");
    const sub = subSlug(req);
    // Read the list, re-stamp one row's `default`, write the whole list back:
    // a read-modify-write that carries the current rev, so a save landing in the
    // middle would be written straight back out of existence. Nothing costly
    // happens between the read and the write, so the whole span is held.
    const guard = lockSidecar(name, sub);
    defer guard.unlock();
    const existing = (try readSidecarDoc(req.arena, ctx.project_dir, name, sub)).layouts;
    var out: std.ArrayList(SavedLayout) = .empty;
    for (existing) |L| {
        var e = L;
        e.default = want.len > 0 and std.mem.eql(u8, L.name, want);
        try out.append(req.arena, e);
    }
    try writeLayoutsSub(req.arena, ctx.project_dir, name, sub, out.items);
    res.content_type = .JSON;
    res.body = ok_json_true;
}

/// POST /api/pcb-rescore/:name — recompute every saved layout's objective with
/// the *current* engine and persist the refreshed scores to `.layouts.json`.
///
/// Each saved layout stores the score the engine produced when it was captured;
/// after the placement/scoring code changes those numbers go stale, so the
/// panel's "Δ vs auto" compares an old-engine saved score against a fresh-engine
/// auto baseline (the page-load `solve` always re-scores the auto layout). This
/// re-runs `scorePoses` on each layout's stored part positions so every entry is
/// measured by the live engine again, making the column comparable. Body is
/// ignored; returns `{"ok":true,"rescored":N}`. A layout with no stored parts,
/// or one whose scoring fails, keeps its previous score.
pub fn rescoreLayoutsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const sub = subSlug(req);
    const existing = (try readSidecarDoc(req.arena, ctx.project_dir, name, sub)).layouts;
    if (existing.len == 0) {
        res.content_type = .JSON;
        res.body = "{\"ok\":true,\"rescored\":0}";
        return;
    }
    // Sub circuits keep their save-time scores — the bulk rescore resolves the
    // whole parent design block, which doesn't match a sub-block's part set.
    if (sub != null) {
        res.content_type = .JSON;
        res.body = "{\"ok\":true,\"rescored\":0}";
        return;
    }

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = no_block_msg;
        return;
    };

    // Same weights the on-screen auto baseline uses, so the refreshed saved
    // scores are directly comparable to it (the panel's delta is auto-relative).
    const params = readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{};

    var out: std.ArrayList(SavedLayout) = .empty;
    var n: usize = 0;
    for (existing) |L| {
        var updated = L;
        if (L.parts.len > 0) {
            const poses = try refPosesFromPartPoses(req.arena, L.parts);
            if (optimizer.scorePoses(req.arena, block, ctx.project_dir, poses, params)) |bd| {
                updated.score = .{
                    .hpwl = bd.hpwl,
                    .loop = bd.loop_raw,
                    .caps = if (L.score) |s| s.caps else 0,
                    .objective = bd.objective,
                };
                n += 1;
            } else |_| {}
        }
        try out.append(req.arena, updated);
    }

    // Scoring resolved the design block and ran the objective once per saved
    // row — far too long to hold the sidecar lock across, and holding it there
    // would serialize every editor save behind a rescore. So only the
    // read-modify-write is held: re-read the list under the lock and copy each
    // freshly computed score onto the row that still carries the same NAME.
    // A layout saved, renamed or deleted while the scoring ran therefore
    // survives untouched, instead of being written back out of existence by
    // the stale list this handler started from. `sub` is null here (scoped
    // requests returned above), so this is the design-level sidecar.
    const guard = lockSidecar(name, null);
    defer guard.unlock();
    var merged: std.ArrayList(SavedLayout) = .empty;
    for ((try readSidecarDoc(req.arena, ctx.project_dir, name, null)).layouts) |L| {
        var row = L;
        for (out.items) |scored| {
            if (!std.mem.eql(u8, scored.name, L.name)) continue;
            row.score = scored.score;
            break;
        }
        try merged.append(req.arena, row);
    }
    try writeLayouts(req.arena, ctx.project_dir, name, merged.items);

    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rescored\":{d}}}", .{n});
}

/// POST /api/pcb-score-batch/:name — score every saved layout's stored poses on
/// the server (the design block is resolved once, then each pose-set scored), so
/// the page can re-weigh the whole saved-layout panel under the Score-view
/// weights from a single round-trip. Returns `{"results":[{"name",breakdown}, …]}`
/// with each layout's full raw breakdown; read-only (unlike `pcb-rescore`, it
/// persists nothing). The raw terms the client re-weighs are weight-independent,
/// so the result is stable regardless of `?tuning` (honoured only for parity).
pub fn pcbScoreBatchApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const sub = subSlug(req);
    const layouts = (try readSidecarDoc(req.arena, ctx.project_dir, name, sub)).layouts;

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block_root: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = no_block_msg;
        return;
    };
    // Score against the scoped sub-block when `?sub=` is present, so the panel
    // re-weigh matches the sub circuit's own parts.
    const block: *env_mod.DesignBlock = if (sub) |s| blk: {
        const sb = descendToSub(ctx.allocator, block_root, s) orelse {
            res.status = 404;
            res.body = no_sub_msg;
            return;
        };
        break :blk sb.block;
    } else block_root;
    const tune = parseTuning(req);

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    const w = &aw.writer;
    try w.writeAll("{\"results\":[");
    var first = true;
    for (layouts) |L| {
        if (L.parts.len == 0) continue;
        const poses = try refPosesFromPartPoses(req.arena, L.parts);
        const bd = optimizer.scorePoses(req.arena, block, ctx.project_dir, poses, tune.params) catch continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, L.name);
        try w.writeAll(",\"breakdown\":");
        try pcb_layout_blob.writeBreakdownJson(w, bd, tune.params);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Parse the request body as a JSON object, setting a 400 and returning null on
/// any failure (missing body / malformed JSON / non-object root).
pub fn parseJsonObject(req: *httpz.Request, res: *httpz.Response) ?std.json.Value {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return null;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = bad_json_msg;
        return null;
    };
    if (root != .object) {
        res.status = 400;
        return null;
    }
    return root;
}

fn writeFileAll(path: []const u8, data: []const u8) !void {
    // Atomic write (tmp → rename): the layout sidecar is rewritten on GET (the
    // dedup pass in `displayLayouts`) and on every solve, from multiple worker
    // threads with no lock. A truncate-then-write left a window where a
    // concurrent reader — or a crash — saw a half-written file, and
    // `parseLayouts` treats any parse failure as "no layouts", silently
    // discarding every saved/starred layout (and the KiCad-sync seed). The
    // rename is atomic, so a reader sees either the old or the new file whole;
    // concurrent writers degrade to last-writer-wins instead of corruption.
    var write_buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(data);
    try atomic.finish();
}

/// Round a courtyard half-extent up to the placement grid, the same rule the
/// optimizer draws with (`optimizer.ceilToGrid`) and the modal preview mirrors
/// (`gceil` in BOARD_JS). The `1e-9` slack stops a half-extent already on the
/// grid from being bumped a whole step by float error — which matters because
/// offset mode constructs a value designed to land exactly on a grid line.
fn courtCeilGrid(v: f64) f64 {
    const g = optimizer.grid_mm;
    return std.math.ceil(v / g - 1e-9) * g;
}

/// `courtCeilGrid`'s outward twin for a low edge (rounds down / away).
fn courtFloorGrid(v: f64) f64 {
    const g = optimizer.grid_mm;
    return std.math.floor(v / g + 1e-9) * g;
}

/// POST /api/courtyard/:name — rewrite a footprint's courtyard. Three modes:
///   `{"fp":"conn-x","mode":"rect","x0":-1.2,"y0":-0.8,"x1":2.4,"y1":0.8}` —
///     the four *effective* edges verbatim (the drag editor; the box needn't
///     be origin-centred); the loader's air-gap margin is inverted per side so
///     the written rect reloads to exactly those edges.
///   `{"fp":"c-0402","mode":"offset","offset":0.2}` — the offset is the literal
///     gap from the pad bounding box to the courtyard edge on every side,
///     grid-snapped outward per side (asymmetric pads stay hugged), then with
///     the loader's air-margin stripped back out.
///   `{"fp":"c-0402","mode":"size","hw":1.2,"hh":0.8}` — legacy symmetric
///     *effective* half-extents about the origin.
/// Mode defaults to "size" when absent. Then re-pack via `?regen=1`.
pub fn savePcbCourtyardApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = bodyParam(req, res) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = bad_json_msg;
        return;
    };
    if (root != .object) {
        res.status = 400;
        return;
    }
    const fp_v = root.object.get("fp") orelse {
        res.status = 400;
        return;
    };
    if (fp_v != .string or !safeFootprintName(fp_v.string)) {
        res.status = 400;
        res.body = "bad footprint name";
        return;
    }
    const path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, fp_v.string }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(ctx.allocator, path, lib_limits.max_footprint_bytes) catch {
        res.status = 404;
        res.body = "footprint not found";
        return;
    };

    // Three ways to size the rect (see the doc comment). All store an
    // *effective* box with the loader's air-gap margin stripped per side, so
    // geometry.load adds it back to exactly the intended courtyard.
    //   "rect"   — the four effective edges verbatim (the drag editor; the box
    //              needn't be origin-centred).
    //   "offset" — the pad bounding box + that gap on every side, grid-snapped
    //              outward (per side, so asymmetric pads stay hugged).
    //   "size"   — legacy symmetric half-extents.
    const mode: []const u8 = blk: {
        const mv = root.object.get("mode") orelse break :blk "size";
        break :blk if (mv == .string) mv.string else "size";
    };
    const margin = geometry.bbox_margin_mm;
    var rx0: f64 = undefined;
    var ry0: f64 = undefined;
    var rx1: f64 = undefined;
    var ry1: f64 = undefined;
    if (std.mem.eql(u8, mode, "rect")) {
        rx0 = jsonNum(root.object.get("x0")) + margin;
        ry0 = jsonNum(root.object.get("y0")) + margin;
        rx1 = jsonNum(root.object.get("x1")) - margin;
        ry1 = jsonNum(root.object.get("y1")) - margin;
    } else if (std.mem.eql(u8, mode, "offset")) {
        const off = @max(jsonNum(root.object.get("offset")), 0);
        const g = geometry.load(req.arena, ctx.project_dir, fp_v.string, 0, margin);
        var px0: f64 = std.math.inf(f64);
        var py0: f64 = std.math.inf(f64);
        var px1: f64 = -std.math.inf(f64);
        var py1: f64 = -std.math.inf(f64);
        for (g.pads) |p| {
            px0 = @min(px0, p.x - p.w / 2);
            px1 = @max(px1, p.x + p.w / 2);
            py0 = @min(py0, p.y - p.h / 2);
            py1 = @max(py1, p.y + p.h / 2);
        }
        if (g.pads.len == 0) {
            res.status = 400;
            res.body = "footprint has no pads to offset from";
            return;
        }
        // The offset is the literal gap from the pad bounding box to the
        // effective courtyard edge, snapped outward to the grid per side, then
        // deflated by the loader's air-margin (geometry.load adds it back).
        rx0 = courtFloorGrid(px0 - off) + margin;
        ry0 = courtFloorGrid(py0 - off) + margin;
        rx1 = courtCeilGrid(px1 + off) - margin;
        ry1 = courtCeilGrid(py1 + off) - margin;
    } else {
        const rw = @max(jsonNum(root.object.get("hw")) - margin, 0.05);
        const rh = @max(jsonNum(root.object.get("hh")) - margin, 0.05);
        rx0 = -rw;
        ry0 = -rh;
        rx1 = rw;
        ry1 = rh;
    }
    // Degenerate guard: a span the margin deflation collapsed keeps a sliver.
    if (rx1 - rx0 < 0.05) {
        const cx = (rx0 + rx1) / 2;
        rx0 = cx - 0.025;
        rx1 = cx + 0.025;
    }
    if (ry1 - ry0 < 0.05) {
        const cy = (ry0 + ry1) / 2;
        ry0 = cy - 0.025;
        ry1 = cy + 0.025;
    }

    const updated = rewriteCourtyard(ctx.allocator, src, rx0, ry0, rx1, ry1) catch {
        res.status = 500;
        res.body = "rewrite failed";
        return;
    };
    writeFileAll(path, updated) catch {
        res.status = 500;
        res.body = "write failed";
        return;
    };
    res.content_type = .JSON;
    res.body = ok_json_true;
}

/// A footprint name must be a bare file stem — no path separators or `..`, so a
/// request can't escape `lib/footprints/`.
fn safeFootprintName(fp: []const u8) bool {
    if (fp.len == 0 or fp.len > 128) return false;
    if (std.mem.indexOfScalar(u8, fp, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, fp, '\\') != null) return false;
    if (std.mem.indexOf(u8, fp, "..") != null) return false;
    return true;
}

/// Return `src` with its `(courtyard …)` form replaced by the given rect
/// (footprint-local corners — need not be origin-centred), inserting one
/// before the footprint's closing paren if none exists.
fn rewriteCourtyard(alloc: std.mem.Allocator, src: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) HandlerError![]u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    const w = &buf.writer;
    const form = try std.fmt.allocPrint(alloc, "(courtyard (rect {d:.3} {d:.3} {d:.3} {d:.3}))", .{ x0, y0, x1, y1 });
    if (std.mem.indexOf(u8, src, "(courtyard")) |start| {
        var depth: i32 = 0;
        var i: usize = start;
        var end: usize = src.len;
        while (i < src.len) : (i += 1) {
            if (src[i] == '(') depth += 1;
            if (src[i] == ')') {
                depth -= 1;
                if (depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        try w.writeAll(src[0..start]);
        try w.writeAll(form);
        try w.writeAll(src[end..]);
    } else {
        const last = std.mem.lastIndexOfScalar(u8, src, ')') orelse {
            try w.writeAll(src);
            return buf.written();
        };
        try w.writeAll(src[0..last]);
        try w.writeAll("  ");
        try w.writeAll(form);
        try w.writeAll("\n");
        try w.writeAll(src[last..]);
    }
    return buf.written();
}

/// A JSON integer field → i64 (absent/non-integer ⇒ 0). A float saturates into
/// range (NaN ⇒ 0). Used for a zone's `priority` (small non-negative rank; both
/// KiCad and the viewer emit it as an integer).
/// Saved-layout `PartPose`s from a solved placement, each stamped with its
/// renumber-stable `origin_key` (the placement's `instances` run index-aligned
/// with `parts`). Snapshots written through this can be re-loaded by origin
/// after the parts renumber. Null on allocation failure.
pub fn posesFromPlacement(alloc: std.mem.Allocator, p: optimizer.Placement) ?[]PartPose {
    const parts = alloc.alloc(PartPose, p.parts.len) catch return null;
    for (p.parts, 0..) |pt, i| parts[i] = .{
        .ref = pt.ref_des,
        .x = pt.x,
        .y = pt.y,
        .rot = pt.rot,
        .origin = if (i < p.instances.len) p.instances[i].origin_key else "",
        .side = pt.side,
        .locked = pt.locked,
    };
    return parts;
}

/// PartPose slice → RefPose slice, carrying side/locked — shared by the
/// scoring endpoints so a saved layout's board sides survive the conversion.
pub fn refPosesFromPartPoses(alloc: std.mem.Allocator, parts: []const PartPose) std.mem.Allocator.Error![]optimizer.RefPose {
    const out = try alloc.alloc(optimizer.RefPose, parts.len);
    for (parts, 0..) |p, i| out[i] = .{ .ref = p.ref, .x = p.x, .y = p.y, .rot = p.rot, .side = p.side, .locked = p.locked };
    return out;
}

/// Saved-pose identity (scoped-origin-first binding, one claim per live
/// part, stale-pose flagging) lives in `pose_identity.zig`; these names keep
/// the page's call sites and `saved_anchor_migration.bind` reading as before.
const pose_identity = @import("pose_identity.zig");
const refPrefix = pose_identity.refPrefix;
const LiveRef = pose_identity.LiveRef;
const ResolvedPoses = pose_identity.ResolvedPoses;
const resolvePoseIdentity = pose_identity.resolve;

/// The live-identity list of a built placement (ref + origin key per part),
/// the input `resolvePoseIdentity` matches saved poses against. Null on
/// allocation failure.
pub fn liveOfPlacement(alloc: std.mem.Allocator, p: optimizer.Placement) ?[]const LiveRef {
    const live = alloc.alloc(LiveRef, p.parts.len) catch return null;
    for (p.parts, 0..) |pt, i| {
        live[i] = .{
            .ref = pt.ref_des,
            .origin = if (i < p.instances.len) p.instances[i].origin_key else "",
        };
    }
    return live;
}

/// Re-key a saved layout's poses onto `block`'s *current* ref-des via
/// `resolvePoseIdentity` (origin key first, exact ref string as the legacy
/// fallback). A pose with no match keeps its stored `ref` — UNLESS that ref
/// now names a live part bound to some other pose, in which case the stale
/// pose is dropped (`ResolvedPoses.dropped`): after a netlist edit renumbers
/// parts, the parked pose of a deleted part must not shadow the genuine pose
/// of the part that inherited its ref. Null only on a flatten/allocation
/// failure (caller falls back to raw refs).
pub fn rekeyPosesByOrigin(
    alloc: std.mem.Allocator,
    block: *env_mod.DesignBlock,
    parts: []const PartPose,
) ?[]const optimizer.RefPose {
    var flat: std.ArrayList(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, block, "", &flat) catch return null;
    const live = alloc.alloc(LiveRef, flat.items.len) catch return null;
    for (flat.items, 0..) |fi, i| live[i] = .{ .ref = fi.ref_des, .origin = fi.origin_key };
    const res = resolvePoseIdentity(alloc, live, parts) orelse return null;
    @import("saved_anchor_migration.zig").bind(LiveRef, PartPose, ResolvedPoses, live, parts, block.rough, res);
    var out: std.ArrayList(optimizer.RefPose) = .empty;
    for (parts, 0..) |pp, i| {
        if (res.dropped(i)) continue;
        out.append(alloc, .{ .ref = res.refs[i], .x = pp.x, .y = pp.y, .rot = pp.rot, .side = pp.side, .locked = pp.locked }) catch return null;
    }
    return out.toOwnedSlice(alloc) catch null;
}

/// The page blob's saved-layout rows, re-keyed onto the flatten the page is
/// showing, so the client Load applies poses by EXACT ref. Pose identity —
/// the sub-block-scoped origin bridge — lives in exactly one place
/// (`resolvePoseIdentity`), server-side: the client's old origin map was
/// unscoped and last-wins, which collapsed every sub-block sharing a
/// module-local key ("U1") onto one pose on Load. A stale pose whose stored
/// ref a genuine pose now owns is dropped (`ResolvedPoses.dropped`) — the
/// client keys `parts` by ref, so a duplicate would silently win or lose by
/// emission order. Rows whose resolution fails pass through unchanged (their
/// stored refs are still the best available).
fn rekeyRowsToLive(
    alloc: std.mem.Allocator,
    layouts: []const SavedLayout,
    live: []const LiveRef,
) []const SavedLayout {
    const out = alloc.dupe(SavedLayout, layouts) catch return layouts;
    for (out) |*L| {
        const res = resolvePoseIdentity(alloc, live, L.parts) orelse continue;
        var np: std.ArrayList(PartPose) = .empty;
        for (L.parts, 0..) |pp, i| {
            if (res.dropped(i)) continue;
            var kept = pp;
            kept.ref = res.refs[i];
            np.append(alloc, kept) catch break;
        }
        if (np.items.len + res.droppedCount() != L.parts.len) continue;
        // A dimension follows the KEPT pose that carries its stored ref; one
        // anchored only on a dropped stale pose goes with it.
        var nd: std.ArrayList(SavedPartEdgeDimension) = .empty;
        for (L.dimensions) |dimension| {
            for (L.parts, 0..) |part, i| {
                if (res.dropped(i) or !std.mem.eql(u8, dimension.ref, part.ref)) continue;
                var moved = dimension;
                moved.ref = res.refs[i];
                nd.append(alloc, moved) catch break;
                break;
            }
        }
        L.parts = np.items;
        L.dimensions = nd.items;
    }
    return out;
}

/// `rekeyRowsToLive` against a built placement's identity; rows pass through
/// unchanged when the live list can't be built (allocation failure).
pub fn rekeyRowsToPlacement(
    alloc: std.mem.Allocator,
    layouts: []const SavedLayout,
    p: optimizer.Placement,
) []const SavedLayout {
    const live = liveOfPlacement(alloc, p) orelse return layouts;
    return rekeyRowsToLive(alloc, layouts, live);
}

/// Name of the design's starred (★ default) saved layout — the one the Layouts
/// panel marks with a filled star and the KiCad sync seeds first-insertion
/// placement from — or null when nothing is starred (or the starred entry has
/// no poses). Lets the `/pcb-layout` page default to that blessed layout on open.
fn defaultLayoutName(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) ?[]const u8 {
    return defaultLayoutNameIn((readSidecarDoc(alloc, project_dir, name, sub) catch return null).layouts);
}

/// `defaultLayoutName` over an already-parsed layout list — the page render
/// parses the (potentially multi-megabyte) sidecar ONCE and derives everything
/// from that list, instead of one full JSON parse per question.
fn defaultLayoutNameIn(layouts: []const SavedLayout) ?[]const u8 {
    for (layouts) |lay| {
        if (lay.default and lay.parts.len > 0) return lay.name;
    }
    return null;
}

/// The poses of a single named saved layout (`?refine=` / `?layout=`), as
/// `RefPose`s ready to seed `solve` / `placeFromPoses` — re-keyed onto `block`'s
/// current ref-des by `origin_key` (see `rekeyPosesByOrigin`) so a layout saved
/// against a different flattening of the same block still lands on the right
/// parts. Null when no layout by that name exists.
pub fn readLayoutPosesFor(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    want: []const u8,
    block: *env_mod.DesignBlock,
    sub: ?[]const u8,
) ?[]const optimizer.RefPose {
    return layoutPosesIn(alloc, (readSidecarDoc(alloc, project_dir, name, sub) catch return null).layouts, want, block);
}

/// `readLayoutPosesFor` over an already-parsed layout list (see
/// `defaultLayoutNameIn` for why the page render pre-parses once).
fn layoutPosesIn(
    alloc: std.mem.Allocator,
    layouts: []const SavedLayout,
    want: []const u8,
    block: *env_mod.DesignBlock,
) ?[]const optimizer.RefPose {
    for (layouts) |lay| {
        if (!std.mem.eql(u8, lay.name, want)) continue;
        if (rekeyPosesByOrigin(alloc, block, lay.parts)) |poses| return poses;
        // Re-key failed (flatten error) — fall back to the raw stored refs.
        var list: std.ArrayList(optimizer.RefPose) = .empty;
        for (lay.parts) |pp| {
            list.append(alloc, .{ .ref = pp.ref, .x = pp.x, .y = pp.y, .rot = pp.rot, .side = pp.side, .locked = pp.locked }) catch return null;
        }
        return list.toOwnedSlice(alloc) catch null;
    }
    return null;
}

/// Sidecar path for a design's (or sub circuit's) layout store. `sub == null` →
/// the design's own `<design>.layouts.json`, resolved next to the source via
/// `designSiblingPath`. `sub` set → the per-sub-circuit store
/// `<design>.<sub>.layouts.json` placed in the design's directory, so a
/// path-/inline-sourced sub circuit (no module page of its own) still gets
/// editable, persisted layouts — scoped to this design.
///
/// `sub` is pasted into the path unescaped, which is only safe because it is
/// spelled like `review.slugify` output. That is NOT free: the value reaches
/// here from the `?sub=` QUERY, already percent-decoded by httpz, so it is
/// caller-controlled. `subSlug`/`isValidSubSlug` is the gate that makes the
/// assumption true — every handler resolves its scope through it, and anything
/// outside the slug alphabet reads back as "no sub" and never arrives here.
const layoutsSidecar = sidecar_store.layoutsSidecar;

/// Read every saved layout for `name` from its `.layouts.json` sidecar
/// (newest first). Returns an empty slice when the file doesn't exist or on
/// parse failure; allocations live on `alloc` (request lifetime).
pub const readLayouts = sidecar_store.readLayouts;

/// Whether `name` has a saved layout called `want` (exact match, the same
/// comparison `layoutPosesIn` selects poses with).
///
/// A caller that would otherwise pay for a FRESH placement solve on a name
/// nobody saved — `solveForRequest` falls through to one — asks here first: a
/// sidecar parse is the cheap half of that mistake.
pub const hasSavedLayout = sidecar_store.hasSavedLayout;

/// As `readLayouts`, but for a `?sub=` scoped sub circuit reads its per-sub
/// sidecar (`layoutsSidecar`). `sub == null` is identical to `readLayouts`.
pub const readLayoutsSub = sidecar_store.readLayoutsSub;

/// The board-level silkscreen texts of `name`'s shown layout: the layout named
/// `want` when given, else the starred (★ default) one — empty when nothing
/// matches or the layout carries no texts. Used by the PNG/describe path so a
/// screenshot draws the same legend the fab silk will (parallels `shownTexts`,
/// which reads the already-loaded list the page render holds).
fn layoutTextsFor(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, want: ?[]const u8, sub: ?[]const u8) []const font5x7.BoardText {
    return layoutTextsIn((try readSidecarDoc(alloc, project_dir, name, sub)).layouts, want);
}

/// `layoutTextsFor` over an already-parsed layout list (see `defaultLayoutNameIn`
/// for why a render pre-parses the sidecar once).
fn layoutTextsIn(layouts: []const SavedLayout, want: ?[]const u8) []const font5x7.BoardText {
    for (layouts) |L| {
        if (want) |wn| {
            if (std.mem.eql(u8, L.name, wn)) return L.texts;
        } else if (L.default) return L.texts;
    }
    return &.{};
}

/// Parse a `.layouts.json` body (`{"layouts":[…]}`) into a slice of
/// `SavedLayout`. Each entry needs a `name`; `kind` defaults to auto, `score`
/// is present only when an `hpwl` field is. Null on malformed top-level JSON.
pub const parseLayouts = sidecar_store.parseLayouts;

/// `parseLayouts` over an already-parsed JSON tree — `readSidecarDoc` parses
/// the (multi-megabyte on a routed board) sidecar once and derives layouts,
/// cache slot and rev from the same tree.
/// Serialize a `SavedOutline` as the sidecar/page JSON object — the exact
/// shape `parseSavedOutline` reads back (rect fields always, `pts` only for
/// polygon outlines). Shared by the sidecar writer and the page blob so the
/// two can never diverge.
const writeSavedOutlineJson = sidecar_json.writeSavedOutlineJson;
const writePartEdgeDimensionsJson = sidecar_json.writePartEdgeDimensionsJson;
const writeSavedHeatsinkJson = sidecar_json.writeSavedHeatsinkJson;
const writeSavedFanJson = sidecar_json.writeSavedFanJson;
pub fn writeOptionalSavedFanJson(w: *std.Io.Writer, fan: ?SavedFan) std.Io.Writer.Error!void {
    if (fan) |value| return writeSavedFanJson(w, value);
    return w.writeAll("null");
}
const writeBoardTextJson = sidecar_json.writeBoardTextJson;
const writeOptionalBoardTextJson = sidecar_json.writeOptionalBoardTextJson;
const writeSavedTextsJson = sidecar_json.writeSavedTextsJson;

/// Serialize zone records in the sidecar/embedded `PCB.zones` shape.
const writeSavedZonesJson = sidecar_json.writeSavedZonesJson;

/// Serialize successful router RF path proofs in the live saved-route shape.
pub fn writeFreshRfPathsJson(w: *std.Io.Writer, outcomes: []const rf_port_report.Outcome, nets: []const export_kicad.FlatNet) std.Io.Writer.Error!void {
    var first = true;
    try w.writeByte('[');
    for (outcomes) |outcome| {
        if (!outcome.success or outcome.physical.gate_removed) continue;
        if (outcome.physical.samples.len < 2) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, pcb_layout_blob.netNameOf(nets, outcome.net));
        try w.print(",\"l\":{d},\"samples\":[", .{outcome.physical.layer});
        for (outcome.physical.samples, 0..) |sample, si| {
            if (si > 0) try w.writeByte(',');
            try w.print("[{d},{d},{d}]", .{ sample.at[0], sample.at[1], sample.width_mm });
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// Serialize saved routes in the shared live-JSON shape (see `SavedTrack`) —
/// the exact bytes `parseSavedRoutes` (already pub, beside it) reads back, so
/// the pair is testable as one round trip from outside this module.
pub const writeSavedRoutesJson = sidecar_json.writeSavedRoutesJson;
const writeSavedRfPathsJson = sidecar_json.writeSavedRfPathsJson;

/// Rebuild a `router.RouteResult` from a layout's persisted copper, resolving
/// each stored net NAME back to its index in the *current* flattened netlist
/// (unknown names → −1, still drawn + DRC-checked as foreign copper). Lets the
/// page draw saved routes on open and re-run DRC against the current poses.
pub fn restoreRoutes(alloc: std.mem.Allocator, sr: SavedRoutes, nets: []const export_kicad.FlatNet) ?router.RouteResult {
    var idx = std.StringHashMapUnmanaged(i32).empty;
    for (nets, 0..) |net, i| idx.put(alloc, net.name, @intCast(i)) catch return null;
    var tracks: std.ArrayList(router.Track) = .empty;
    var arcs: std.ArrayList(router.Arc) = .empty;
    for (sr.tracks) |t| {
        const net = if (t.net.len > 0) (idx.get(t.net) orelse -1) else -1;
        if (t.xm) |xm| if (t.ym) |ym| {
            const arc = router.Arc{
                .p1 = .{ t.x1, t.y1 },
                .pm = .{ xm, ym },
                .p2 = .{ t.x2, t.y2 },
                .layer = t.l,
                .width = t.w,
                .net = net,
            };
            arcs.append(alloc, arc) catch return null;
            const chords = bend_smooth.tessellate(alloc, arc, bend_smooth.emit_sagitta_mm) catch return null;
            tracks.appendSlice(alloc, chords) catch return null;
            continue;
        };
        tracks.append(alloc, .{
            .x1 = t.x1,
            .y1 = t.y1,
            .x2 = t.x2,
            .y2 = t.y2,
            .layer = t.l,
            .width = t.w,
            .net = net,
        }) catch return null;
    }
    const vias = alloc.alloc(router.Via, sr.vias.len) catch return null;
    for (sr.vias, 0..) |vi, i| vias[i] = .{
        .x = vi.x,
        .y = vi.y,
        .dia = vi.d,
        .drill = vi.drill,
        .net = if (vi.net.len > 0) (idx.get(vi.net) orelse -1) else -1,
    };
    var outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    for (sr.rf_paths) |path| {
        const net = idx.get(path.net) orelse continue;
        if (path.samples.len < 2) continue;
        outcomes.append(alloc, .{
            .net = net,
            .chosen = 0,
            .feasible = true,
            .success = true,
            .metrics = .{},
            .trials = &.{},
            .physical = .{ .sample_count = path.samples.len, .samples = path.samples, .layer = path.layer },
        }) catch return null;
    }
    return .{
        .tracks = tracks.toOwnedSlice(alloc) catch return null,
        .vias = vias,
        .arcs = arcs.toOwnedSlice(alloc) catch return null,
        .rf_port_outcomes = outcomes.toOwnedSlice(alloc) catch return null,
        .routed = 0,
        .total = 0,
    };
}

/// The net index of `name` in the flattened netlist, or null when unknown.
pub fn netIndexByName(placement: optimizer.Placement, name: []const u8) ?i32 {
    for (placement.nets, 0..) |net, i| if (std.mem.eql(u8, net.name, name)) return @intCast(i);
    return null;
}

const userZonesFrom = saved_zone.userZones;
const zoneFillReqsFrom = saved_zone.fillRequests;
const existingZonesFrom = saved_zone.existingZones;

/// Keepout polygons are no-silkscreen regions on both faces. Unlike copper
/// pours they need no net/layer resolution; a three-point imported boundary is
/// enough to conservatively suppress generated annotation ink.
pub fn silkKeepoutsFrom(alloc: std.mem.Allocator, zones: []const SavedZone) []const subcircuit_silkscreen.Keepout {
    var out: std.ArrayList(subcircuit_silkscreen.Keepout) = .empty;
    for (zones) |zone| {
        if (zone.flags.keepout and zone.poly.len >= 3) out.append(alloc, .{ .polygon = zone.poly }) catch return out.items;
    }
    return out.items;
}

/// The saved zones the shown view carries (null when no saved copper is shown).
pub fn shownZones(saved: ?SavedRoutes) []const SavedZone {
    return if (saved) |sr| sr.zones else &.{};
}

/// Map already-filtered user copper pours (`pour.UserZone`, keepout- and
/// invalid-free by construction) to router SOURCE-copper `ExistingZone`s, so a
/// fresh route grows same-net copper from them. Unknown-net zones are dropped.
/// The PNG/describe seeding path (its `SolvedRequest.shown_zones` is `UserZone`,
/// not raw `SavedZone`), the `existingZonesFrom` twin for the page/API paths.
fn userZoneSources(alloc: std.mem.Allocator, placement: optimizer.Placement, zones: []const pour.UserZone) []const route_policy.ExistingZone {
    var out: std.ArrayList(route_policy.ExistingZone) = .empty;
    for (zones) |z| {
        const ni = netIndexByName(placement, z.net) orelse continue;
        out.append(alloc, .{ .polygon = z.poly, .layer = z.layer, .net = ni, .copper = true, .priority = z.priority }) catch return out.items;
    }
    return out.items;
}

/// The page's resolved routing view: route params, the copper to draw (fresh
/// ?route=1 result, else the shown layout's persisted routes), its DRC
/// violations against the CURRENT poses, and whether a user-drawn outline was
/// applied onto the placement (see applyShownOutline).
pub const ShownView = struct {
    ro: RouteOpts,
    routed: ?router.RouteResult,
    /// Connectivity-oracle completion for the exact copper being shown. This
    /// exists even for a bare board (0/N), where `routed` remains null so the
    /// editor does not pretend an autoroute has run.
    tally: ?fab_readiness.Tally = null,
    violations: []const drc.Violation,
    outline_drawn: bool,
    /// The render's shared board-edge margin field, seeded AFTER the shown
    /// outline was applied — the one placement the DRC and the blob writer
    /// both pour. Carried out so `renderLayoutPage` threads the SAME field
    /// into `pcb_layout_blob.writePcbData` (see `pour.sharedEdgeField`); null when the board
    /// has no fillable lattice.
    base_edge: ?pour.EdgeField = null,
    /// Exact authored vertices and fillet radii for the shown layout.
    outline: ?SavedOutline = null,
    /// Empty means the authored fabrication-layer regions remain active.
    fabrication_layers: []const SavedFabricationLayer = &.{},
    /// Physical heatsink authored on the shown saved layout.
    heatsink: ?SavedHeatsink = null,
    fan: ?SavedFan = null,
    /// The SavedRoutes the shown copper was restored from (null when the
    /// copper is a fresh ?route=1 result) — index-aligned with `routed`, so
    /// the blob writer can re-emit per-segment stamp group tags (`g`).
    saved: ?SavedRoutes = null,
    /// The shown layout's board-level silkscreen texts (empty when none) —
    /// the blob emits them as `PCB.texts` so the viewer draws them on load.
    texts: []const font5x7.BoardText = &.{},
    /// Driving footprint-origin dimensions authored on the shown layout.
    dimensions: []const SavedPartEdgeDimension = &.{},
};

/// What `resolveShownView` reads: the placement being shown, the saved-layout
/// list, the shown layout's name, and the (sub-scoped) block whose authored
/// `(pcb-plan (route …))` steers any fresh ?route=1 run.
const ShownInputs = struct {
    /// The design being rendered. Passed in rather than read back off the
    /// route param, so a warm-up render (which has no request) resolves the
    /// same blessed outline a live request would.
    name: []const u8,
    placement: *optimizer.Placement,
    layouts: []const SavedLayout,
    shown: ?[]const u8,
    block: *env_mod.DesignBlock,
    /// Whether to compute server-side DRC for this render. Read-only physical
    /// review opens with markers disabled and has no control that consumes
    /// them, so its first paint deliberately skips the expensive check.
    check_drc: bool = true,
    /// Preserve the shown layout's placement/outline, but begin with no saved
    /// or freshly generated copper (a bare-board autorouter starting state).
    omit_copper: bool = false,
    /// Restore saved tracks/vias but postpone every field derived from them.
    /// The ordinary editor uses this for a fast first response; `?derived=1`
    /// computes and returns the postponed fields after the board has painted.
    defer_derived: bool = false,
    /// Whether to run the reporting half at all. False keeps the shared
    /// board-edge field — every pour still needs it — but skips the DRC and
    /// the connectivity tally, which `?pdn=1` has no reader for.
    reporting: bool = true,
};

/// Resolve everything the shown saved layout contributes to the page: apply
/// its drawn outline onto the placement (before DRC, so the board-edge check
/// sees it), run routing when ?route=1 asked for it (through the shared
/// plan-lowering seam, so the preview equals a route_pcb commit), else restore
/// the layout's persisted copper, and DRC whatever copper is shown. `shown` is
/// null for ?sub scoped pages (no whole-design layout applies).
fn resolveShownView(ctx: *Server, req: ?*httpz.Request, in: ShownInputs) ShownView {
    const name = in.name;
    // Drawn outline wins over the authored (board (size …)) rectangle — it's
    // the explicit per-layout edit. When the shown layout supplies no outline
    // (a regen renders a fresh solve with `shown` = null), fall back to the
    // design's blessed outline so ?route=1 still routes and DRCs against the
    // true board edge — else the maze uses the parts bbox, bend-smoothing bulges
    // arcs off the board, and the board-edge DRC silently skips (null board_rect).
    const outline_drawn = applyShownOutline(in.placement, in.layouts, in.shown) or
        foldBlessedOutline(ctx.allocator, ctx.project_dir, name, subSlug(req), in.placement);
    const fabrication_layers = shownFabricationLayers(in.layouts, in.shown);
    _ = applyFabricationLayerOverrides(ctx.allocator, in.placement, fabrication_layers);
    // One board, one lattice: the board-edge margin field every fill below
    // seeds from is a pure function of the placement, and the outline above is
    // the placement's FINAL one — so seed it once here, after that mutation,
    // and thread it through the DRC pours in this call and the blob/fab pours
    // in `pcb_layout_blob.writePcbData` (carried out on the return). On board-a that outline
    // walk was ~36% of the render, repeated per caller and per net.
    const base_edge = if (in.omit_copper or in.defer_derived)
        null
    else
        pour.sharedEdgeField(ctx.allocator, in.placement.*) catch null;
    // Routing runs only on demand (?route=1); otherwise the shown saved
    // layout's persisted copper is restored (see shownSavedRoutes).
    const ro = parseRoute(req, in.placement.rules.design.routeParams());
    const shown_sr_raw = if (in.omit_copper) null else shownSavedRoutes(in.layouts, in.shown);
    const shown_sr = if (in.omit_copper) null else routesWithPerimeter(ctx.allocator, in.placement.*, shown_sr_raw);
    const shown_zs = shownZones(shown_sr);
    var routed: ?router.RouteResult = null;
    var saved: ?SavedRoutes = null;
    if (ro.run and !in.omit_copper) {
        // ?route=1: route fresh, seeding the maze with the shown user copper
        // pours as same-net source copper (existingZonesFrom).
        const ez = existingZonesFrom(ctx.allocator, in.placement.*, shown_zs);
        var route_options = route_plan.lowerOrEmpty(ctx.allocator, in.block, in.placement.*);
        route_options.existing_zones = ez;
        const seeded = pcb_layout_seeds.routeWithSubcircuitSeeds(ctx.allocator, ctx.project_dir, in.block, in.placement.*, ro.params, route_options) catch null;
        routed = if (seeded) |s| s.result else null;
        routed = perimeter_fence.append(ctx.allocator, in.placement.*, routed) catch routed;
        // Keep the shown user zones visible (copper + fills) through a route
        // preview, but carry NO track/via source so pcb_layout_blob.writeRoutedArrays never
        // mis-tags fresh routed copper with a stale per-segment group tag.
        if (shown_zs.len > 0) saved = .{ .tracks = &.{}, .vias = &.{}, .zones = shown_zs };
    } else if (!in.omit_copper) {
        saved = shown_sr;
        if (saved) |sr| routed = restoreRoutes(ctx.allocator, sr, in.placement.nets);
    }
    const user_zones = userZonesFrom(ctx.allocator, in.placement.*.rules, shown_zs);
    const texts = shownTexts(in.layouts, in.shown);
    // The deferred half owns the connectivity oracle every completion count
    // reads (see `drc_rules.Deferred.reconcile`); running it for a bare board
    // too gives the header the useful 0/N starting state.
    const deferred: drc_rules.Deferred = if (in.omit_copper or in.defer_derived or !in.reporting)
        .{}
    else
        drc_rules.resolveDeferred(ctx.allocator, ctx.project_dir, name, .{
            .placement = in.placement.*,
            .routed = routed,
            .clearance = ro.params.clearance,
            .zones = user_zones,
            .texts = texts,
            .base_edge = base_edge,
            .check_drc = in.check_drc,
        });
    var view = ShownView{ .ro = ro, .routed = routed, .tally = deferred.tally, .violations = deferred.violations, .outline_drawn = outline_drawn, .base_edge = base_edge, .outline = shownOutline(in.layouts, in.shown), .fabrication_layers = fabrication_layers, .heatsink = authored_heatsink.resolve(in.placement.*, shownHeatsink(in.layouts, in.shown), in.block.board.thermal.heatsink), .fan = authored_heatsink.resolveFan(in.placement.*, shownFan(in.layouts, in.shown), in.block.board.thermal.fan), .saved = saved, .texts = texts, .dimensions = shownDimensions(in.layouts, in.shown) };
    deferred.reconcile(&view.routed);
    return view;
}

/// Complete a view resolved with `defer_derived`: the board-edge field every
/// pour of the deferred payload shares, then the reporting DRC over the copper
/// already restored into `view`. This is the ONLY work `?derived=1` does that
/// the page render ahead of it did not — which is what lets one warm-up solve
/// answer both (see `pcb_derived`).
pub fn applyDeferred(ctx: *Server, name: []const u8, placement: optimizer.Placement, view: *ShownView) void {
    view.base_edge = pour.sharedEdgeField(ctx.allocator, placement) catch null;
    const deferred = drc_rules.resolveDeferred(ctx.allocator, ctx.project_dir, name, .{
        .placement = placement,
        .routed = view.routed,
        .clearance = view.ro.params.clearance,
        .zones = userZonesFrom(ctx.allocator, placement.rules, shownZones(view.saved)),
        .texts = view.texts,
        .base_edge = view.base_edge,
    });
    view.tally = deferred.tally;
    view.violations = deferred.violations;
    deferred.reconcile(&view.routed);
}

fn shownOutline(layouts: []const SavedLayout, shown: ?[]const u8) ?SavedOutline {
    if (shown) |sn| {
        for (layouts) |layout| {
            if (std.mem.eql(u8, layout.name, sn)) return layout.outline;
        }
        return null;
    }
    const blessed = blessedLayout(layouts) orelse return null;
    return blessed.outline;
}

fn shownDimensions(layouts: []const SavedLayout, shown: ?[]const u8) []const SavedPartEdgeDimension {
    if (shown) |sn| for (layouts) |layout| {
        if (std.mem.eql(u8, layout.name, sn)) return layout.dimensions;
    };
    return if (blessedLayout(layouts)) |layout| layout.dimensions else &.{};
}

fn shownFabricationLayers(layouts: []const SavedLayout, shown: ?[]const u8) []const SavedFabricationLayer {
    if (shown) |sn| {
        for (layouts) |layout| if (std.mem.eql(u8, layout.name, sn)) return layout.fabrication_layers;
        return &.{};
    }
    const blessed = blessedLayout(layouts) orelse return &.{};
    return blessed.fabrication_layers;
}

fn shownHeatsink(layouts: []const SavedLayout, shown: ?[]const u8) ?SavedHeatsink {
    if (shown) |sn| {
        for (layouts) |layout| if (std.mem.eql(u8, layout.name, sn)) return layout.heatsink;
        return null;
    }
    const blessed = blessedLayout(layouts) orelse return null;
    return blessed.heatsink;
}

fn shownFan(layouts: []const SavedLayout, shown: ?[]const u8) ?SavedFan {
    if (shown) |sn| {
        for (layouts) |layout| if (std.mem.eql(u8, layout.name, sn)) return layout.fan;
        return null;
    }
    const blessed = blessedLayout(layouts) orelse return null;
    return blessed.fan;
}

/// Replace only the positive regions of matching authored layers. The source
/// remains authoritative for side/material/thickness and automatic footprint
/// cutouts, so a visual edit cannot silently change manufacturing semantics.
pub fn applyFabricationLayerOverrides(alloc: std.mem.Allocator, placement: *optimizer.Placement, overrides: []const SavedFabricationLayer) bool {
    if (overrides.len == 0 or placement.fabrication_layers.len == 0) return true;
    const specs = alloc.dupe(env_mod.FabricationLayerSpec, placement.fabrication_layers) catch return false;
    for (specs) |*spec| {
        for (overrides) |saved| {
            if (!std.mem.eql(u8, spec.name, saved.name)) continue;
            const regions = alloc.alloc(env_mod.FabricationRegion, saved.regions.len) catch return false;
            for (saved.regions, regions) |points, *region| region.* = .{ .polygon = points };
            spec.regions = regions;
            break;
        }
    }
    placement.fabrication_layers = specs;
    return true;
}

/// The shown saved layout's board-level silkscreen texts (empty when the
/// layout isn't found or carries none). Mirrors `shownSavedRoutes`.
fn shownTexts(layouts: []const SavedLayout, shown: ?[]const u8) []const font5x7.BoardText {
    const sn = shown orelse return &.{};
    for (layouts) |L| {
        if (std.mem.eql(u8, L.name, sn)) return L.texts;
    }
    return &.{};
}

/// Fold a drawn `SavedOutline` onto an already-built placement: sets
/// `board_rect`/`board_poly` and grows the framing bbox so the whole
/// rectangle is on screen. The post-build twin of seeding
/// `placeFromPoses` with `drawnSource(o)` — used on the `solve` paths,
/// which have no pose seed.
fn applyOutline(placement: *optimizer.Placement, o: SavedOutline) void {
    placement_outline.apply(placement, .{ .minx = o.x, .miny = o.y, .w = o.w, .h = o.h }, o.derived.poly orelse o.pts, o.derived.arcs);
    placement.minx = @min(placement.minx, o.x);
    placement.miny = @min(placement.miny, o.y);
    placement.maxx = @max(placement.maxx, o.x + o.w);
    placement.maxy = @max(placement.maxy, o.y + o.h);
}

/// Apply the shown saved layout's user-drawn outline (if any) onto the
/// placement (see `applyOutline`). Returns true when an outline was applied
/// (the blob then flags it editable — see PCB.outline in the viewer).
fn applyShownOutline(placement: *optimizer.Placement, layouts: []const SavedLayout, shown: ?[]const u8) bool {
    const sn = shown orelse return false;
    for (layouts) |L| {
        if (!std.mem.eql(u8, L.name, sn)) continue;
        const o = L.outline orelse return false;
        applyOutline(placement, o);
        return true;
    }
    return false;
}

/// The design's blessed drawn outline among its saved layouts: the default
/// (★) layout's, else the first layout that carries one. Pure lookup so it's
/// testable; `blessedOutline` wraps it with the sidecar reads.
fn blessedOutlineIn(layouts: []const SavedLayout, default_name: ?[]const u8) ?SavedOutline {
    if (default_name) |dn| {
        for (layouts) |L| {
            if (!std.mem.eql(u8, L.name, dn)) continue;
            if (L.outline) |o| return o;
            break;
        }
    }
    for (layouts) |L| {
        if (L.outline) |o| return o;
    }
    return null;
}

/// The design's blessed drawn outline (see `blessedOutlineIn`); null for a
/// ?sub scoped view (its own module frame) or when no saved layout carries
/// one. A drawn outline is a physical board property independent of which
/// placement variant is shown — without it a fresh solve routes and DRCs
/// with NO board edge (maze on the parts bbox, bend-smoothing free to bulge
/// arcs off the board, board-edge DRC silently skipped on a null
/// `board_rect`): copper off the board with no DRC error.
fn blessedOutline(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) ?SavedOutline {
    if (sub != null) return null;
    return blessedOutlineIn((readSidecarDoc(alloc, project_dir, name, null) catch return null).layouts, defaultLayoutName(alloc, project_dir, name, null));
}

/// A drawn `SavedOutline` as a `placeFromPoses` outline seed.
pub fn drawnSource(o: SavedOutline) optimizer.OutlineSource {
    return .{ .drawn = .{
        .rect = .{ .minx = o.x, .miny = o.y, .w = o.w, .h = o.h },
        .poly = o.derived.poly orelse o.pts,
        .arcs = o.derived.arcs,
    } };
}

/// The outline seed for an endpoint that rebuilds a placement from client
/// poses (pcbRouteApi, pcbDrcApi): a submitted body outline wins (the
/// on-screen edit, saved or not), else the design's blessed drawn outline,
/// else authored-only. The ONE resolution such endpoints share, so the Route
/// button, the debounced DRC, and the GET ?route=1 pipeline can never
/// disagree about the board edge again.
pub fn outlineForBody(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    submitted: ?SavedOutline,
) optimizer.OutlineSource {
    if (submitted) |o| return drawnSource(o);
    if (blessedOutline(alloc, project_dir, name, sub)) |o| return drawnSource(o);
    return .authored_only;
}

/// Fold the design's blessed board outline (see `blessedOutline`) onto an
/// already-built placement — the post-build fold for the `solve` paths.
/// Returns true when applied.
fn foldBlessedOutline(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    placement: *optimizer.Placement,
) bool {
    const o = blessedOutline(alloc, project_dir, name, sub) orelse return false;
    applyOutline(placement, o);
    return true;
}

/// `foldBlessedOutline` over an already-parsed layout list (see
/// `defaultLayoutNameIn`). Design-scoped only, matching `blessedOutline`'s rule
/// that a ?sub view has no board edge of its own.
fn foldBlessedOutlineIn(layouts: []const SavedLayout, placement: *optimizer.Placement) bool {
    const o = blessedOutlineIn(layouts, defaultLayoutNameIn(layouts)) orelse return false;
    applyOutline(placement, o);
    return true;
}

/// The shown saved layout's persisted copper — the page draws it when no
/// fresh ?route=1 ran (rebuilt against the current netlist by the caller via
/// `restoreRoutes`, which DRC re-checks it against the CURRENT poses so
/// copper gone stale after a part move shows violations). Null when nothing
/// is shown or the layout carries no routes.
fn shownSavedRoutes(layouts: []const SavedLayout, shown: ?[]const u8) ?SavedRoutes {
    const sn = shown orelse return null;
    for (layouts) |L| {
        if (!std.mem.eql(u8, L.name, sn)) continue;
        return L.routes;
    }
    return null;
}

/// The single-slot optimizer cache: the tuning weights that produced the
/// last solve plus its part poses. Lives in the `"cache"` key of
/// `.layouts.json`; never shown as a snapshot row.
pub const CacheSlot = sidecar_store.CacheSlot;
const parseCacheSlot = sidecar_store.parseCacheSlot;

/// Parse a `{"params":{…},"parts":[…]}` cache object (either the `"cache"`
/// key of `.layouts.json` or the root of a legacy `.autolayout.json`).
/// Read the optimizer-cache slot for `name`: the `"cache"` key of
/// `.layouts.json` first, falling back to the legacy standalone
/// `.autolayout.json` for boards last solved by an older build.
pub const readCacheSlot = sidecar_store.readCacheSlot;

/// The sidecar's optimistic-concurrency `rev` (top-level `"rev"` field), or 0
/// when the file/field is absent (legacy). Every user Save/Update embeds the
/// rev the page loaded and the save guard 409s on a mismatch; render-path
/// writes preserve this value so merely viewing/regenerating never bumps it.
pub const readLayoutRev = sidecar_store.readLayoutRev;

/// Everything a `.layouts.json` read can answer, from ONE file read and ONE
/// JSON parse: the saved-layout list, the raw optimizer cache slot (no legacy
/// fallback — see `readCacheSlot`), and the optimistic-concurrency rev. The
/// single-question readers (`readLayoutsSub`, `readCacheSlot`, `readLayoutRev`)
/// all delegate here, and the page render reads the doc ONCE — it used to
/// re-read and re-parse the file for each question, which on a routed
/// multi-layout board is megabytes of JSON per question.
const SidecarDoc = sidecar_store.SidecarDoc;

/// The page render's one sidecar read: `readSidecarDoc` plus the same legacy
/// `.autolayout.json` cache fallback `readCacheSlot` applies (design stores
/// only — sub stores carry no cache slot).
fn readPageDoc(ctx: *Server, name: []const u8, sub: ?[]const u8) SidecarDoc {
    if (sub) |s| return (readSidecarDoc(ctx.allocator, ctx.project_dir, name, s) catch SidecarDoc{});
    return (readDesignDoc(ctx.allocator, ctx.project_dir, name) catch SidecarDoc{});
}

/// A design store's sidecar doc plus the legacy `.autolayout.json` cache
/// fallback (boards last solved by an older build). Sub stores carry no cache
/// slot, so they read through `readSidecarDoc` directly.
const readDesignDoc = sidecar_store.readDesignDoc;

/// The tuning params the page displays: explicit tuning and a just-generated
/// solve show `tune.params` (persistGeneratedLayout just wrote exactly those
/// into the cache slot); a cached / starred render shows the doc's stored
/// cache weights — no second sidecar parse either way.
fn shownParams(sub: ?[]const u8, tune: Tuning, generated: bool, doc: SidecarDoc) optimizer.Params {
    if (sub != null or tune.tuned or generated) return tune.params;
    const cs = doc.cache orelse return .{};
    return cs.params;
}

/// The saved-layouts panel list. A generated placement may have just recorded
/// a fresh auto row (persistGeneratedLayout), so re-read; the common cached /
/// starred render reuses the doc's single parse.
fn panelLayouts(ctx: *Server, name: []const u8, sub: ?[]const u8, generated: bool, doc: SidecarDoc) []const SavedLayout {
    const raw = if (generated) (readSidecarDoc(ctx.allocator, ctx.project_dir, name, sub) catch return doc.layouts).layouts else doc.layouts;
    return displayLayouts(ctx.allocator, ctx.project_dir, name, sub, raw);
}

const readSidecarDoc = sidecar_store.readSidecarDoc;

/// Persist the layout list to `.layouts.json`, carrying the existing cache
/// slot AND the current `rev` over unchanged (a render-path write, not a user
/// save — see `readLayoutRev`). Best-effort: a write failure just means the
/// list reverts to what was last on disk.
const writeLayouts = sidecar_store.writeLayouts;

/// As `writeLayouts`, but for a `?sub=` scoped sub circuit writes its per-sub
/// sidecar, preserving that sidecar's rev. `sub == null` delegates to
/// `writeLayouts` (design store, cache preserved).
const writeLayoutsSub = sidecar_store.writeLayoutsSub;

/// As `writeLayoutsSub`, but stamps an explicit `rev` — the user-save path
/// passes `disk_rev + 1` to bump the counter; render-path callers pass the
/// current rev to preserve it. The sub store carries no auto-cache slot (sub
/// previews always solve fresh), so only the layouts array is persisted;
/// `sub == null` goes through the design store (cache preserved).
const writeLayoutsSubRev = sidecar_store.writeLayoutsSubRev;

/// Persist layouts + cache slot + `rev` to `.layouts.json` (the whole sidecar).
const writeLayoutsFile = sidecar_store.writeLayoutsFile;

/// Enter the read-compare-write critical section for one design's sidecar.
///
/// Every sidecar mutation on this page is a read-modify-write, and the `rev`
/// guard alone is a lockless check-then-write: two saves that both read `rev=5`
/// both passed it, both wrote `rev=6`, and the first one's row was gone. Take
/// this around the WHOLE span (rev read → conflict check → history snapshot →
/// list read → write) and `defer guard.unlock()`. Expensive work — resolving
/// the design, solving, scoring, pouring — is computed BEFORE the lock so the
/// editor is never serialized behind it. See `layout_sidecar_store.lockSidecar`.
const lockSidecar = sidecar_store.lockSidecar;

/// Drop exactly-duplicated copper from every layout on its way to disk.
///
/// Copper reaches the sidecar from several appenders — a fresh route, the gap
/// closer's kept hops, `add_tracks`, a module Stamp — and an appender that
/// re-lays a segment it already has produces a byte-identical twin. That is not
/// harmless: a duplicated track is drawn twice, exported twice, and counted
/// twice by every per-net length report, and the board-a `engine-90` snapshot
/// shipped 23 duplicate tracks and 3 duplicate vias this way. Two segments with
/// identical endpoints, layer, width and net carry no information the first one
/// does not, so the sidecar keeps one. Nothing else is touched: near-identical
/// or overlapping copper is real routing and stays.
const dedupedLayouts = sidecar_store.dedupedLayouts;

/// `tracks` with byte-identical duplicates removed, order preserved.
const dedupedTracks = sidecar_store.dedupedTracks;

/// `vias` with byte-identical duplicates removed, order preserved.
///
/// The key is geometry — hole position, diameter, drill AND the `s` layer
/// SPAN — plus the net, and it deliberately ignores BOTH provenance tags (`g`
/// stamp group, `f` fence): two vias at the same place on the same net are one
/// piece of copper however they got there, and keying on provenance would let a
/// re-Stamp or a fence re-run persist a second barrel in the same hole. Order
/// preservation then decides which row survives — the FIRST one, so
/// pre-existing (typically untagged, hand-drawn or autorouted) copper keeps its
/// identity and a later tagged twin is the one dropped.
///
/// The span is on the OTHER side of that line: a blind/buried `0..1` and a
/// through `0..N` in one hole are two different pieces of copper joining
/// different layers, so they are not twins and both persist.
const dedupedVias = sidecar_store.dedupedVias;

// spec: Web Server - Copper is de-duplicated on its way to the layout sidecar, so an appender that re-lays a segment cannot persist it twice
test "the sidecar drops byte-identical duplicate copper and keeps real copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dup = SavedTrack{ .x1 = 1, .y1 = 2, .x2 = 3, .y2 = 4, .l = 0, .w = 0.2, .net = "GND" };
    const tracks = [_]SavedTrack{
        dup,
        dup, // exact twin — carries nothing the first does not
        .{ .x1 = 1, .y1 = 2, .x2 = 3, .y2 = 4, .l = 1, .w = 0.2, .net = "GND" }, // other layer
        .{ .x1 = 1, .y1 = 2, .x2 = 3, .y2 = 4, .l = 0, .w = 0.2, .net = "VCC" }, // other net
    };
    const kept = dedupedTracks(arena, &tracks);
    try std.testing.expectEqual(@as(usize, 3), kept.len);

    const v = SavedVia{ .x = 5, .y = 6, .d = 0.4, .drill = 0.2, .net = "GND" };
    const vias = [_]SavedVia{ v, v, .{ .x = 5, .y = 6.5, .d = 0.4, .drill = 0.2, .net = "GND" } };
    try std.testing.expectEqual(@as(usize, 2), dedupedVias(arena, &vias).len);
}

// spec: Web Server - Two vias in the same hole on the same net are one via whatever their provenance tags say, and the first row is the one kept
test "the via dedupe key ignores provenance and keeps the untagged original" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same hole, same net, different provenance. Keying on `f`/`g` too would let
    // a fence re-run (or a re-Stamp) persist a second barrel in one drill.
    const vias = [_]SavedVia{
        .{ .x = 5, .y = 6, .d = 0.4, .drill = 0.2, .net = "GND" },
        .{ .x = 5, .y = 6, .d = 0.4, .drill = 0.2, .net = "GND", .f = "RF1_BPF" },
        .{ .x = 5, .y = 6, .d = 0.4, .drill = 0.2, .net = "GND", .g = "buck" },
    };
    const kept = dedupedVias(arena, &vias);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    // Order preservation decides the winner: the FIRST row survives, so
    // pre-existing hand/autorouted copper keeps its identity and the later
    // tagged twin is the one dropped.
    try std.testing.expectEqualStrings("", kept[0].f);
    try std.testing.expectEqualStrings("", kept[0].g);
}

test "perimeter restore replaces stale derived vias but adopts one serving exact custom-pad copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // L-shaped copper: the bounding-box centre and lower-left notch are empty,
    // while (5.6, 0.5) lies in the right-hand leg.
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ 0.2, 1 }, .{ 0.2, -0.2 }, .{ -1, -0.2 } };
    const pads = [_]geometry.Pad{.{ .number = "3", .x = 0, .y = 0, .w = 2, .h = 2, .shape = "custom", .poly = &poly }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &pads,
        .fallback = false,
        .x = 5,
        .y = 0,
    }};
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "3" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    var placement = pcb_layout_mcp.addTracksFixture(&parts, &nets, &.{});
    placement.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .mask_width = 0.7,
    };
    const old = SavedRoutes{
        .tracks = &.{},
        .vias = &.{
            .{ .x = 999, .y = 999, .d = 0.4, .drill = 0.2, .net = "GND", .f = perimeter_fence.provenance },
            .{ .x = 5.6, .y = 0.5, .d = 0.4, .drill = 0.2, .net = "GND", .f = perimeter_fence.provenance },
            .{ .x = 4.5, .y = 0.5, .d = 0.4, .drill = 0.2, .net = "GND", .f = perimeter_fence.provenance },
            .{ .x = 0, .y = 0, .d = 0.6, .drill = 0.3, .net = "GND" },
        },
    };
    const current = routesWithPerimeter(alloc, placement, old) orelse return error.TestExpectedRoutes;
    try std.testing.expectEqual(@as(usize, 50), current.vias.len); // 48-site ring + hand via + adopted via-in-pad
    try std.testing.expectApproxEqAbs(@as(f64, 5.6), current.vias[0].x, 1e-9);
    try std.testing.expectEqualStrings("", current.vias[0].f);
    try std.testing.expectApproxEqAbs(@as(f64, 0), current.vias[1].x, 1e-9);
    for (current.vias) |via| {
        try std.testing.expect(via.x != 999);
        try std.testing.expect(!(via.x == 4.5 and via.y == 0.5));
    }
    try std.testing.expectEqualStrings(perimeter_fence.provenance, current.vias[2].f);
}

/// Serialize the sidecar with no optimistic-concurrency rev (rev 0 → omitted).
/// The rev-free spelling used by the KiCad-sync/export round-trip tests and any
/// caller that doesn't participate in the save guard.
const writeLayoutsFileJson = sidecar_store.writeLayoutsFileJson;

/// Serialize the sidecar to its on-disk shape: an optional top-level `"rev":N`
/// optimistic-concurrency counter (omitted when 0 so a never-guarded legacy
/// file stays byte-identical), then an optional `"default":"<name>"` (the entry
/// whose `default` flag is set, if any), the optional `"cache"` slot, then the
/// `layouts` array. Score fields (hpwl/loop/caps) are flattened onto each entry
/// and omitted when unscored.
pub const writeLayoutsFileJsonRev = sidecar_store.writeLayoutsFileJsonRev;

/// Two saved layouts are duplicates when their score matches: the headline
/// objective and its two visible raw terms (HPWL + loop length) agree to 0.1.
/// This is the "duplicate layout" the panel dedups on — what the user reads as
/// the same row, e.g. repeated Regenerate runs that reconverge to the same
/// objective even if a part lands a grid step off. (Position isn't compared:
/// the deterministic optimizer can reach an equal-score arrangement that differs
/// by a hair, which the user still sees as the same layout.) Unscored legacy
/// entries never match — they're kept rather than guessed at.
const dedupLayouts = sidecar_store.dedupLayouts;
const sameLayoutScore = sidecar_store.sameLayoutScore;

/// The saved-layout list for the panel: duplicate arrangements collapsed (legacy
/// histories that accumulated repeated Regenerate runs — the cleanup is persisted
/// once), then sorted most-recently-edited first. Only this display copy is
/// sorted; the sidecar's history order stays untouched. Empty for sub-scoped
/// previews.
const displayLayouts = sidecar_store.displayLayouts;

/// Append an auto-recorded snapshot of the just-generated `placement` to the
/// layout history — unless that arrangement is *already saved* (under any name,
/// auto or manual), in which case there is nothing new to record. Then prunes
/// auto entries past `MAX_AUTO_LAYOUTS`.
const recordAutoLayout = sidecar_store.recordAutoLayout;

/// Read the optimizer cache's poses into a slice of `RefPose`, or null if
/// no cache slot exists. Strings are owned by `alloc` (request lifetime),
/// which outlives the `solve` call that consumes them.
const readAutoPoses = sidecar_store.readAutoPoses;

/// `readAutoPoses` over an already-read cache slot (see `SidecarDoc`).
const cachePoses = sidecar_store.cachePoses;

/// One placed part exported to the KiCad sync: centre (mm) + rotation (deg,
/// CCW) + board side. The sync stamps these onto a footprint it inserts for
/// the first time.
pub const SyncPose = sidecar_store.SyncPose;

/// Re-export so the KiCad sync can name a module's poses (`loadSubBlockPoses`)
/// without importing the placement layer directly.
pub const RefPose = optimizer.RefPose;

/// Choose the part poses the KiCad sync seeds first-insertion placement (and
/// GND vias) from, as `RefPose`s, or null when the design has no layout at all.
/// Preference: the user-marked **default** layout first, then the newest manual
/// snapshot, then the most recent recorded layout of any kind, then the raw
/// optimizer-cache slot. Both `loadSyncLayout` (placement) and
/// `loadSyncVias` (vias) go through this so the vias correspond to exactly the
/// poses the parts land at. Result lives on `alloc` (request lifetime).
const chooseSyncPoses = sidecar_store.chooseSyncPoses;

/// Saved-layout parts as sync `RefPose`s (null on allocation failure).
const refPosesFromParts = sidecar_store.refPosesFromParts;

/// `chooseModuleSnapshot` result: the snapshot to seed from, plus — when a
/// different snapshot covers strictly more of the module's current parts —
/// that fuller alternative (surfaced as a staleness hint, never auto-taken
/// over a ★).
const SnapshotChoice = sidecar_store.SnapshotChoice;

/// Pick which of a module's saved snapshots to seed a Stamp / sync from,
/// scoring each by how many of its refs still exist in the module's *current*
/// flatten (`ok_of`, ref-des → origin_key). A starred (★) snapshot that
/// bridges at all wins outright — the user's blessing (and what the KiCad sync
/// seeds from). With no ★, best coverage wins, manual beating auto on equal
/// coverage — replacing a blind "newest manual first": a module that grew
/// since an old hand save would stamp 42 of 59 parts from the stale snapshot
/// while a newer, fuller one sat unused. When the winner is a ★ that a
/// non-starred snapshot out-covers, that snapshot is reported as `alt` so the
/// UI can flag the stale star. Null when no snapshot bridges anything (caller
/// may fall back to the volatile cache slot).
const chooseModuleSnapshot = sidecar_store.chooseModuleSnapshot;

/// Load the design's premade placement-tool layout for the KiCad sync's
/// first-insertion path, as a ref-des → pose map (mm + degrees), or null when
/// the design has no saved layout at all. The layout is picked by
/// `chooseSyncPoses` (default → manual → any → optimizer cache). The returned
/// map and its keys live on `alloc` (request lifetime). Only positions are
/// exported here — the GND vias are computed separately by `loadSyncVias`.
pub fn loadSyncLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ?std.StringHashMapUnmanaged(SyncPose) {
    const poses = chooseSyncPoses(alloc, project_dir, name) orelse return null;
    var m = std.StringHashMapUnmanaged(SyncPose).empty;
    for (poses) |p| m.put(alloc, p.ref, .{ .x = p.x, .y = p.y, .rot = p.rot, .side = p.side }) catch return m;
    return m;
}

/// One GND-plane stitching via exported to the KiCad sync: centre (mm), pad +
/// hole diameter (mm), and the net name it stitches down to the plane. Saved
/// layouts store only positions, so the vias are *computed* at sync time.
pub const SyncVia = struct { x: f64, y: f64, dia: f64, drill: f64, net: []const u8 };

/// A sub-module's default layout re-keyed onto **`sub_block`'s own flattened
/// ref-des**, bridged by stable `origin_key`. A module's saved layout is keyed
/// by the ref-des of whatever design `/pcb-layout/<module>` rendered when it was
/// saved (e.g. the `tpsm84338` eval wraps the module in a `pwr` sub-block →
/// `pwr/U2`). The *same* part inside another board flattens differently
/// (`buck_3v3d/U11`) — different wrapper AND renumbering — so a prefix-strip
/// can't bridge them. This maps the starred module layout onto `origin_key` via
/// the shared `subBlockPoseByOriginKey` bridge, then re-keys the poses onto
/// `sub_block.block`'s flattened refs by matching `origin_key` (the module-local
/// identity, stable across both). Falls back to the raw layout (caller
/// prefix-strips) when the module can't be resolved or nothing bridges. Result
/// lives on `alloc` (request lifetime).
pub fn loadSubBlockPoses(alloc: std.mem.Allocator, project_dir: []const u8, sub_block: env_mod.SubBlock) ?[]const optimizer.RefPose {
    // The robust module→origin_key bridge, shared with the viewer Stamp
    // (`pcb_layout_seeds.buildSubSeedsJson`) and the Push-modal seeder (`subCircuitSource`). Its
    // predecessor here re-resolved the module SOURCE PATH (`sourceOriginKeys`),
    // which returned null for a module that exists only as a `lib/modules/`
    // defmodule — evaluating the defmodule file yields `.nil`, not a
    // design-block — so the origin_key re-key was skipped and the caller
    // prefix-stripped a module-standalone layout (`C1`…) against parent-renumbered
    // refs (`C88`…) that never match, silently dropping the module's starred
    // arrangement on a KiCad sync seed. `subBlockPoseByOriginKey` instead
    // re-flattens the module (`resolveModuleBlock`: real instantiation first,
    // else zero-arg), so a module-only defmodule bridges too.
    const seeds = subBlockPoseByOriginKey(alloc, project_dir, sub_block) orelse
        return chooseSyncPoses(alloc, project_dir, sub_block.source);

    // Re-key onto sub_block's own flattened refs by origin_key. This is a
    // module-scoped re-key (matched by origin_key), not the grouped root, so
    // keep the prefixed walk regardless of the design's grouped-refdes setting.
    var flat2: std.ArrayList(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, sub_block.block, "", &flat2) catch
        return chooseSyncPoses(alloc, project_dir, sub_block.source);
    var out: std.ArrayList(optimizer.RefPose) = .empty;
    for (flat2.items) |fi| {
        if (fi.origin_key.len == 0) continue;
        const pose = seeds.map.get(fi.origin_key) orelse continue;
        out.append(alloc, .{ .ref = fi.ref_des, .x = pose.x, .y = pose.y, .rot = pose.rot, .side = pose.side }) catch
            return chooseSyncPoses(alloc, project_dir, sub_block.source);
    }
    // Nothing bridged (e.g. the module changed since the layout) — let the
    // caller prefix-strip the raw layout as a legacy best effort.
    if (out.items.len == 0) return chooseSyncPoses(alloc, project_dir, sub_block.source);
    return out.toOwnedSlice(alloc) catch chooseSyncPoses(alloc, project_dir, sub_block.source);
}

/// A sub-block's module-layout seed: poses keyed by stable `origin_key`, plus
/// which module snapshot supplied them (shown in the Stamp palette so a user
/// can tell a ★-blessed pull from a best-coverage fallback). `alt_*` name a
/// fuller non-chosen snapshot when the chosen ★ has gone stale (module grew
/// since it was starred) — a hint to re-star, never taken automatically.
pub const SubBlockSeeds = struct {
    map: std.StringHashMapUnmanaged(SyncPose),
    layout_name: []const u8,
    starred: bool,
    alt_name: []const u8 = "",
    alt_n: usize = 0,
    /// The chosen snapshot's persisted copper (module-local coordinates and
    /// module-local net names) — Stamp carries it onto the parent board.
    routes: ?SavedRoutes = null,
    /// One entry per flattened module pin (net, origin_key, pad) — the bridge
    /// pcb_layout_seeds.buildSubSeedsJson uses to map module net names to parent nets. Only
    /// populated when the snapshot carries routes.
    pin_nets: []const SubPinNet = &.{},
};

/// A flattened module pin sample: which module-local net the pad at
/// (origin_key, pad) sits on. See `SubBlockSeeds.pin_nets`. Public so the KiCad
/// sync can bridge a seeded sub-circuit's module net names to parent nets.
pub const SubPinNet = struct { net: []const u8, origin_key: []const u8, pad: []const u8 };

/// The sub-block's saved module layout — the starred (★) snapshot when one
/// bridges, else best current-flatten coverage (`chooseModuleSnapshot`) — keyed
/// by stable `origin_key`, so a caller can match each flattened part by its
/// `FlatInstance.origin_key`, the module-local identity that survives the
/// parent design's `(hierarchical-ids)` renumbering.
///
/// The layout is keyed by the *module-standalone* ref-des (`U1`, `R1`, `C1`…,
/// as the `/pcb-layout/<module>` solve assigned them when the layout was saved),
/// which is NOT the parent-renumbered ref (`buck_3v3d/U11`, `mcu/C57`). The
/// missing link is `standalone-ref → origin_key`, and the ONLY way to reproduce
/// the exact standalone ref-des is to re-flatten the module the same way the
/// layout was made — `modules_mod.resolveModuleBlock` (real instantiation first,
/// else zero-arg) — NOT the parent's already-renumbered `sub_block.block`, and
/// NOT the module's *source path* (which evaluates a bare `lib/modules/`
/// defmodule to `.nil`, not a design-block, so no refs bridge). With that
/// bridge: layout ref `C1` → origin_key `100nF@3#0` → board part `mcu/C57`
/// (same origin_key). Null when the module has no saved layout or nothing
/// bridges. `loadSubBlockPoses` (the KiCad sync seed) delegates here so a
/// module-only defmodule bridges on the sync path too.
pub fn subBlockPoseByOriginKey(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    sub_block: env_mod.SubBlock,
) ?SubBlockSeeds {
    const resolved = modules_mod.resolveModuleBlock(alloc, project_dir, sub_block.source) orelse return null;
    // Standalone-flatten ref-des → origin_key (its refs key the saved layout).
    var flat: std.ArrayList(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, resolved.block, "", &flat) catch return null;
    var ok_of = std.StringHashMapUnmanaged([]const u8).empty;
    for (flat.items) |fi| ok_of.put(alloc, fi.ref_des, fi.origin_key) catch return null;
    const layouts = (readSidecarDoc(alloc, project_dir, sub_block.source, null) catch return null).layouts;
    const choice = chooseModuleSnapshot(layouts, &ok_of) orelse {
        // No snapshot bridges — last resort is the volatile optimizer cache.
        const poses = readAutoPoses(alloc, project_dir, sub_block.source) orelse return null;
        const m = seedMapFromPoses(alloc, &ok_of, poses) orelse return null;
        return .{ .map = m, .layout_name = "cache", .starred = false };
    };
    const layout = refPosesFromParts(alloc, choice.chosen.parts) orelse return null;
    const m = seedMapFromPoses(alloc, &ok_of, layout) orelse return null;
    return .{
        .map = m,
        .layout_name = choice.chosen.name,
        .starred = choice.chosen.default,
        .alt_name = if (choice.alt) |a| a.name else "",
        .alt_n = choice.alt_n,
        .routes = choice.chosen.routes,
        .pin_nets = if (choice.chosen.routes != null) modulePinNets(alloc, resolved.block, &ok_of) else &.{},
    };
}

/// Flatten the module's nets the same way its instances were flattened and
/// sample every pin as (net, origin_key, pad) — the module side of the
/// stamped-copper net-name bridge. Empty on any failure (copper then falls
/// back to slug-prefixed net names, which is what a module-private net
/// flattens to in the parent anyway).
fn modulePinNets(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    ok_of: *const std.StringHashMapUnmanaged([]const u8),
) []const SubPinNet {
    var fnets: std.ArrayList(export_kicad.FlatNet) = .empty;
    netlist.collectNets(alloc, block, "", &fnets) catch return &.{};
    var pn: std.ArrayList(SubPinNet) = .empty;
    for (fnets.items) |net| {
        for (net.pins) |pin| {
            const ok = ok_of.get(pin.ref_des) orelse continue;
            if (ok.len == 0) continue;
            pn.append(alloc, .{ .net = net.name, .origin_key = ok, .pad = pin.pin }) catch return &.{};
        }
    }
    return pn.toOwnedSlice(alloc) catch &.{};
}

/// Layout ref → origin_key → pose (null when nothing bridges).
fn seedMapFromPoses(
    alloc: std.mem.Allocator,
    ok_of: *const std.StringHashMapUnmanaged([]const u8),
    layout: []const optimizer.RefPose,
) ?std.StringHashMapUnmanaged(SyncPose) {
    var m = std.StringHashMapUnmanaged(SyncPose).empty;
    for (layout) |p| {
        const ok = ok_of.get(p.ref) orelse continue;
        if (ok.len == 0) continue;
        m.put(alloc, ok, .{ .x = p.x, .y = p.y, .rot = p.rot, .side = p.side }) catch return null;
    }
    if (m.count() == 0) return null;
    return m;
}

/// The generated vias for a placement at exactly `poses` (built from `block`):
/// the router's ground-via pass plus any board-declared perimeter fence —
/// in `block`'s local coordinate frame. Net names come from the placement's
/// flattened nets; via size/drill use the router's proto-fab defaults. Returns
/// null when the placement can't be built or the board is too large to grid (no
/// vias). Used both for a whole design (`loadSyncVias`) and a single sub-block
/// (the per-block seed offsets these by the block's staging origin).
pub fn viasForPoses(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    seed: optimizer.PoseSeed,
    params: optimizer.Params,
) ?[]const SyncVia {
    const placement = optimizer.placeFromPoses(alloc, block, project_dir, seed, params) catch return null;
    const rp = router.RouteParams{};
    const ground = router.groundVias(alloc, placement, rp) catch &.{};
    const fence = perimeter_fence.generate(alloc, placement) catch &.{};
    if (ground.len == 0 and fence.len == 0) return null;
    var merged: std.ArrayList(router.Via) = .empty;
    merged.appendSlice(alloc, ground) catch return null;
    for (fence) |site| {
        var found = false;
        for (merged.items) |v| if (v.net == site.net and std.math.hypot(v.x - site.x, v.y - site.y) < drc.eps) {
            found = true;
            break;
        };
        if (!found) merged.append(alloc, site) catch return null;
    }
    const out = alloc.alloc(SyncVia, merged.items.len) catch return null;
    for (merged.items, 0..) |v, i| {
        const net_name: []const u8 = if (v.net >= 0 and @as(usize, @intCast(v.net)) < placement.nets.len)
            placement.nets[@intCast(v.net)].name
        else
            "";
        out[i] = .{ .x = v.x, .y = v.y, .dia = v.dia, .drill = if (v.drill > 0) v.drill else rp.via_drill, .net = net_name };
    }
    return out;
}

/// The GND vias for the design's sync layout: pick the default-aware poses
/// (`chooseSyncPoses`) and route them (`viasForPoses`). Positions only, no
/// traces. Null when the design has no layout / the board is too large to grid.
pub fn loadSyncVias(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    name: []const u8,
) ?[]const SyncVia {
    const poses = chooseSyncPoses(alloc, project_dir, name) orelse return null;
    const params = readAutoParams(alloc, project_dir, name) orelse optimizer.Params{};
    // Blessed drawn outline so ground stitching vias stay inside the board
    // edge on designs whose outline is drawn (no authored (board …) form).
    return viasForPoses(alloc, block, project_dir, .{
        .poses = poses,
        .outline = outlineForBody(alloc, project_dir, name, null, null),
    }, params);
}

/// Exact outline + inward solder-mask opening width for KiCad's first-layout
/// seed. The sync layer emits this as closed F.Mask/B.Mask graphic strokes.
pub const SyncPerimeterMask = struct {
    outline: []const [2]f64,
    width: f64,
};

/// Resolve the current blessed outline and perimeter mask declaration into the
/// compact shape consumed by the KiCad sync writer.
pub fn loadSyncPerimeterMask(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    name: []const u8,
) ?SyncPerimeterMask {
    const poses = chooseSyncPoses(alloc, project_dir, name) orelse return null;
    const params = readAutoParams(alloc, project_dir, name) orelse optimizer.Params{};
    const placement = optimizer.placeFromPoses(alloc, block, project_dir, .{
        .poses = poses,
        .outline = outlineForBody(alloc, project_dir, name, null, null),
    }, params) catch return null;
    const fence = placement.rules.perimeter_fence;
    if (!(fence.mask_width > 0)) return null;
    const poly = perimeter_fence.outlinePoints(alloc, placement) catch return null;
    if (poly.len < 3) return null;
    return .{ .outline = poly, .width = fence.mask_width };
}

/// The routed copper SAVED with the design's sync layout — the tracks, vias and
/// zones as drawn, in whole-design board coordinates. Read by the KiCad sync so
/// a first-insertion seed carries the board's routing across, not just its
/// placement (`emitLayoutCopper`); `loadSyncVias` above is a different thing —
/// a freshly *computed* ground-stitch pass.
///
/// The snapshot is `blessedLayout`, which walks the same ★ default → newest
/// manual → any named precedence `chooseSyncPoses` takes poses from, so the
/// copper always belongs to the placement being seeded. Null when only the bare
/// optimizer cache exists (it stores poses, never copper) or the chosen snapshot
/// was never routed.
pub fn loadSyncRoutes(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?SavedRoutes {
    const chosen = blessedLayout((readSidecarDoc(alloc, project_dir, name, null) catch return null).layouts) orelse return null;
    const routes = chosen.routes orelse return null;
    var vias: std.ArrayList(SavedVia) = .empty;
    for (routes.vias) |via| {
        if (std.mem.eql(u8, via.f, perimeter_fence.provenance)) continue;
        vias.append(alloc, via) catch return routes;
    }
    return .{ .tracks = routes.tracks, .vias = vias.items, .zones = routes.zones, .rf_paths = routes.rf_paths };
}

/// Persist the generated layout (its tuning weights + ref/x/y/rot per part)
/// into the `"cache"` slot of `.layouts.json`, then drop the superseded
/// standalone `.autolayout.json` so each design carries one layout sidecar.
/// Best-effort: a write failure just means a regenerate.
fn writeAutoCache(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, p: optimizer.Placement, params: optimizer.Params) void {
    const parts = posesFromPlacement(alloc, p) orelse return;
    // Read the whole document, swap the cache slot, write it back. That is a
    // read-modify-write on the file saves also write, reached from the detached
    // regen thread as well as the render path, and it re-stamps the CURRENT rev
    // — so unheld it clobbers a concurrent save without ever tripping the rev
    // guard. Solving already finished in the caller; only the file work is
    // inside the hold. Released before the legacy-file cleanup below.
    {
        const guard = lockSidecar(name, null);
        defer guard.unlock();
        const doc = (readSidecarDoc(alloc, project_dir, name, null) catch return);
        // Refreshing the auto cache is a render-path write — preserve the rev.
        writeLayoutsFile(alloc, project_dir, name, doc.layouts, .{ .params = params, .parts = parts }, doc.rev) catch return;
    }
    if (paths.designSiblingPath(alloc, project_dir, name, auto_ext)) |legacy| {
        defer alloc.free(legacy);
        infra_fs.cwd().deleteFile(legacy) catch |e| switch (e) {
            // Usually already gone — only first post-upgrade solve has one.
            error.FileNotFound => {},
            else => {},
        };
    } else |_| {}
}

/// Read the tuning weights stored alongside the cached layout, or null when
/// no cache slot exists.
pub fn readAutoParams(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?optimizer.Params {
    const slot = readCacheSlot(alloc, project_dir, name) orelse return null;
    return slot.params;
}

/// Tuning weights parsed from the request query, plus whether any were present
/// (`tuned`) and whether a fresh solve is required (`regen` = tuned or `?regen`).
pub const Tuning = struct {
    params: optimizer.Params,
    tuned: bool,
    regen: bool,
    /// `?show=cache` — display the optimizer-cache layout even when a starred
    /// layout exists. The live-regen completion reload uses it so a fresh
    /// Regenerate/Rough result is what you SEE (instead of the page snapping
    /// back to the starred layout and the run looking like a no-op).
    show_cache: bool = false,
};

fn parseTuning(req: ?*httpz.Request) Tuning {
    var p = optimizer.Params{};
    var tuned = false;
    var regen = false;
    var show_cache = false;
    const r = req orelse return .{ .params = p, .tuned = false, .regen = false };
    const q = r.query() catch return .{ .params = p, .tuned = false, .regen = false };
    if (q.get("regen") != null) regen = true;
    if (q.get("show")) |v| show_cache = std.mem.eql(u8, v, "cache");
    if (q.get("loop_w")) |v| {
        p.loop_w = parseF(v, p.loop_w);
        tuned = true;
    }
    if (q.get("w_align")) |v| {
        p.w_align = parseF(v, p.w_align);
        tuned = true;
    }
    if (q.get("w_congest")) |v| {
        p.w_congest = parseF(v, p.w_congest);
        tuned = true;
    }
    if (q.get("cap_w_max")) |v| {
        p.cap_w_max = parseF(v, p.cap_w_max);
        tuned = true;
    }
    if (q.get("grid")) |v| {
        p.grid_courtyards = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        tuned = true;
    }
    // Experimental: allow drawn courtyards to overlap their clearance bands by N mm
    // (default 0 = touch only, no overlap). See Params.courtyard_overlap.
    if (q.get("court_overlap")) |v| {
        p.courtyard_overlap = parseF(v, p.courtyard_overlap);
        tuned = true;
    }
    // Routing/copper room between courtyards (mm); group cohesion + zoning weights.
    if (q.get("route_gap")) |v| {
        p.route_gap = parseF(v, p.route_gap);
        tuned = true;
    }
    if (q.get("group_w")) |v| {
        p.group_w = parseF(v, p.group_w);
        tuned = true;
    }
    if (q.get("group_zone_w")) |v| {
        p.group_zone_w = parseF(v, p.group_zone_w);
        tuned = true;
    }
    if (q.get("group_loop_relief")) |v| {
        p.group_loop_relief = parseF(v, p.group_loop_relief);
        tuned = true;
    }
    if (q.get("zone_pack")) |v| {
        p.zone_pack = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        tuned = true;
    }
    // `?rough=1` — the rough module-clustered / pad-anchored seed (the "Rough"
    // button); forces a fresh solve down the `Params.rough` path.
    if (q.get("rough")) |v| {
        p.rough = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        if (p.rough) tuned = true;
    }
    // `?remaining=1` — "Rough remaining": pin every part the base layout (the
    // ★, else the auto cache) covers and rough-place only the uncovered/new
    // parts around them. The incremental button for a hand-finished board.
    if (q.get("remaining")) |v| {
        p.remaining = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        if (p.remaining) tuned = true;
    }
    return .{ .params = p, .tuned = tuned, .regen = regen or tuned, .show_cache = show_cache };
}

fn parseF(s: []const u8, dflt: f64) f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch dflt;
}

/// Routing DRC parsed from the query, and whether routing was requested
/// (`?route=1`, set by the Route button).
const RouteOpts = struct { params: router.RouteParams, run: bool };

/// `base` is the router geometry seeded from the design's resolved
/// `(design-rules …)` (via `DesignRules.routeParams()`); an explicit query param
/// still overrides it, so interactive experimentation wins over the board
/// default. A design with no `(design-rules …)` seeds the built-in RouteParams
/// defaults, so the parsed result is unchanged for existing boards.
fn parseRoute(req: ?*httpz.Request, base: router.RouteParams) RouteOpts {
    var p = base;
    const r = req orelse return .{ .params = p, .run = false };
    const q = r.query() catch return .{ .params = p, .run = false };
    if (q.get("track_width")) |v| p.track_width = parseF(v, p.track_width);
    if (q.get(clearance_key)) |v| p.clearance = parseF(v, p.clearance);
    if (q.get("via_drill")) |v| p.via_drill = parseF(v, p.via_drill);
    if (q.get("via_dia")) |v| p.via_dia = parseF(v, p.via_dia);
    return .{ .params = p, .run = q.get("route") != null };
}

// ── View transform ───────────────────────────────────────────────────────

pub const View = struct {
    scale: f64,
    minx: f64,
    miny: f64,
    width: f64,
    height: f64,

    pub fn init(p: optimizer.Placement) View {
        const cw = @max(p.maxx - p.minx, 1.0) + 2 * view_margin_mm;
        const ch = @max(p.maxy - p.miny, 1.0) + 2 * view_margin_mm;
        const s = std.math.clamp(target_px / @max(cw, ch), scale_min, scale_max);
        return .{ .scale = s, .minx = p.minx, .miny = p.miny, .width = cw * s, .height = ch * s };
    }
};

// ── Score bar + legend ───────────────────────────────────────────────────

// ── Sidebar (single-part properties panel, KiCad-style) ──────────────────

// ── Embedded board data (consumed by BOARD_JS) ───────────────────────────

/// The request body, or null with a 400 already written — the guard every
/// JSON-POST handler opens with.
pub fn bodyParam(req: *httpz.Request, res: *httpz.Response) ?[]const u8 {
    return req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return null;
    };
}

/// The `:name` route param, or null with a 404 already written — the guard
/// every per-design handler opens with.
pub fn nameParam(req: *httpz.Request, res: *httpz.Response) ?[]const u8 {
    return req.param("name") orelse {
        res.status = 404;
        return null;
    };
}

// ── Small helpers ────────────────────────────────────────────────────────

const shortName = net_names.leaf;

/// Net grouping key — dot-collapsed to the rail, sub-block prefix kept.
const netKey = na.baseNetName;

const writeEscaped = escape.writeXml;

/// Percent-encode a layout name for use as a query-parameter value. This
/// mirrors JavaScript's encodeURIComponent so a named layout remains one
/// query value even when it contains spaces or reserved punctuation.
pub fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

// ── Courtyard editor modal ───────────────────────────────────────────────

// ── Library-card modal ────────────────────────────────────────────────

// ── Fab-readiness modal ──────────────────────────────────────────────────

// ── Styles + client renderer ─────────────────────────────────────────────

// The agent-facing layout-mutation tools that used to sit here now live in
// `pcb_layout_mcp.zig`; this module re-exports them beside its imports.

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - A ?sub= scope is accepted only when it is spelled like a sub-block slug, so it can never build a path outside the design directory
test "the sub-block slug gate accepts real slugs and refuses path characters" {
    // `ok` rows are everything `review.slugify` can emit — lowercase
    // alphanumerics, interior hyphens, and the lone `_` it falls back to for a
    // name that slugifies away. The rest are the traversal that made this a
    // gate, plus every separator / case / space that would let a value reach the
    // filesystem as something other than one name.
    const cases = [_]struct { s: []const u8, ok: bool }{
        .{ .s = "usb", .ok = true },
        .{ .s = "usb-c-hs", .ok = true },
        .{ .s = "adc1", .ok = true },
        .{ .s = "ch1", .ok = true },
        .{ .s = "_", .ok = true },
        .{ .s = "a", .ok = true },
        .{ .s = "3v3-buck", .ok = true },
        .{ .s = "../../../../tmp/x", .ok = false },
        .{ .s = "..", .ok = false },
        .{ .s = ".", .ok = false },
        .{ .s = "sub/../..", .ok = false },
        .{ .s = "a/b", .ok = false },
        .{ .s = "a\\b", .ok = false },
        .{ .s = "a.b", .ok = false },
        .{ .s = "/abs", .ok = false },
        // slugify lowercases, so an uppercase value is never its output.
        .{ .s = "USB", .ok = false },
        .{ .s = "a b", .ok = false },
        .{ .s = "a\x00b", .ok = false },
        .{ .s = "a:b", .ok = false },
        // empty means "no sub", never a sub named "".
        .{ .s = "", .ok = false },
    };
    for (cases) |c| try std.testing.expectEqual(c.ok, isValidSubSlug(c.s));

    // Bounded: a slug longer than the cap is refused whatever it spells, while
    // one exactly at the cap still passes.
    var long: [sub_slug_max_len + 1]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expect(!isValidSubSlug(&long));
    try std.testing.expect(isValidSubSlug(long[0..sub_slug_max_len]));
}

// spec: Web Server - A percent-encoded traversal in ?sub= resolves to no sub-block rather than a sub-block scope
test "a percent-encoded ?sub= traversal resolves to design scope" {
    // httpz decodes query values, so `%2e%2e%2f` reaches the handler as `../`.
    // `layoutsSidecar` pastes a sub slug straight into the sidecar path, so this
    // is the exact input that escaped the project directory.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/pcb-layout/x?sub=%2e%2e%2f%2e%2e%2f%2e%2e%2ftmp%2fpwn");
        try std.testing.expect(subSlug(ht.req) == null);
    }
    // A legitimate slug still scopes the request — the gate is a whitelist, not
    // a blanket refusal.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/pcb-layout/x?sub=usb-c-hs");
        try std.testing.expectEqualStrings("usb-c-hs", subSlug(ht.req).?);
    }
    // No `?sub=` at all is design scope, as before.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/pcb-layout/x");
        try std.testing.expect(subSlug(ht.req) == null);
    }
}

// spec: Web Server - The layouts sidecar round-trips snapshots and the optimizer cache slot through one file
test "layouts sidecar round-trips cache slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 1.5, .y = -2.0, .rot = 90 }};
    const dimensions = [_]SavedPartEdgeDimension{.{ .ref = "U1", .axis = "x", .edge_id = 17, .offset = 2 }};
    const layouts = [_]SavedLayout{.{
        .name = "best",
        .kind = kind_manual,
        .ts = 123,
        .score = .{ .hpwl = 10, .loop = 2, .caps = 1, .objective = 42 },
        .parts = &parts,
        .dimensions = &dimensions,
        .default = true,
    }};
    var params = optimizer.Params{};
    params.loop_w = 7;
    const cache = CacheSlot{ .params = params, .parts = &parts };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, cache);
    const text = aw.written();

    const got = parseLayouts(alloc, text) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("best", got[0].name);
    try std.testing.expect(got[0].default);
    try std.testing.expectEqual(@as(usize, 1), got[0].parts.len);
    try std.testing.expectEqual(@as(usize, 1), got[0].dimensions.len);
    try std.testing.expectEqualStrings("U1", got[0].dimensions[0].ref);
    try std.testing.expectEqualStrings("x", got[0].dimensions[0].axis);
    try std.testing.expectEqual(@as(u32, 17), got[0].dimensions[0].edge_id);
    try std.testing.expectEqual(@as(f64, 2), got[0].dimensions[0].offset);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
    const slot = parseCacheSlot(alloc, root.object.get("cache").?) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(f64, 7), slot.params.loop_w);
    try std.testing.expectEqual(@as(usize, 1), slot.parts.?.len);
    try std.testing.expectEqualStrings("U1", slot.parts.?[0].ref);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/foo.layouts.json",
        .data =
        \\{"rev":42,"default":"best","layouts":[{"name":"best","kind":"manual","ts":123,"parts":[{"ref":"U1","x":1,"y":2,"rot":90}]}],"cache":{"params":{"loop_w":1},"parts":[]}}
        ,
    });

    const placement = optimizer.Placement{
        .parts = &.{},
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
    var refreshed_params = optimizer.Params{};
    refreshed_params.loop_w = 9;
    writeAutoCache(alloc, project, "foo", placement, refreshed_params);

    const doc = (readSidecarDoc(alloc, project, "foo", null) catch SidecarDoc{});
    try std.testing.expectEqual(@as(i64, 42), doc.rev);
    try std.testing.expectEqual(@as(usize, 1), doc.layouts.len);
    try std.testing.expectEqualStrings("best", doc.layouts[0].name);
    try std.testing.expect(doc.layouts[0].default);
    try std.testing.expectEqual(@as(f64, 9), doc.cache.?.params.loop_w);
    try std.testing.expectEqual(@as(usize, 0), doc.cache.?.parts.?.len);
}

// spec: Web Server - A rough-seeded saved layout round-trips its rough flag through the sidecar
test "layouts sidecar round-trips rough flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{
        .{ .name = "rough seed", .kind = kind_auto, .ts = 1, .score = null, .parts = &parts, .rough = true },
        .{ .name = "hand", .kind = kind_manual, .ts = 2, .score = null, .parts = &parts },
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);

    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got[0].rough);
    try std.testing.expect(!got[1].rough);
}

// spec: Web Server - The layout sidecar carries an optimistic-concurrency rev, emitted only when non-zero
test "layouts sidecar emits rev only when non-zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{.{ .name = "layout", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts, .default = true }};

    // rev > 0 → serialized at the root.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJsonRev(&aw.writer, &layouts, null, 5);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"rev\":5") != null);
    // A legacy reader still parses the layout array unaffected.
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), got.len);

    // rev == 0 → omitted (a never-guarded legacy file stays byte-identical).
    var aw0: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJsonRev(&aw0.writer, &layouts, null, 0);
    try std.testing.expect(std.mem.indexOf(u8, aw0.written(), "\"rev\"") == null);
}

// spec: Web Server - readLayoutRev reads the sidecar rev (0 for a legacy file), and a save stamps disk_rev+1
test "layout sidecar rev reads back and a save stamps the next rev" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");

    // Legacy sidecar with no rev → 0 ("accept then stamp" starts here).
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = "{\"layouts\":[]}" });
    try std.testing.expectEqual(@as(i64, 0), readLayoutRev(alloc, project, "foo", null));

    // A save stamps disk_rev + 1 = 1; a follow-up read sees it.
    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{.{ .name = "layout", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts, .default = true }};
    try writeLayoutsFile(alloc, project, "foo", &layouts, null, 1);
    try std.testing.expectEqual(@as(i64, 1), readLayoutRev(alloc, project, "foo", null));

    // An explicit rev value round-trips too.
    try writeLayoutsFile(alloc, project, "foo", &layouts, null, 42);
    try std.testing.expectEqual(@as(i64, 42), readLayoutRev(alloc, project, "foo", null));
}

// spec: Web Server - The one-parse layout read still falls back to the legacy .autolayout.json cache when the sidecar carries no cache slot
test "readDesignDoc folds in the legacy auto cache like a re-reading readCacheSlot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");

    // A board last solved by an older build: the layouts sidecar carries no
    // "cache" key and the poses live only in the legacy file beside it. A
    // solve that reads the sidecar ONCE must still find them, or every such
    // board silently re-solves from scratch instead of loading its cache.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = "{\"layouts\":[]}" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/foo.autolayout.json",
        .data = "{\"parts\":[{\"ref\":\"U1\",\"x\":3,\"y\":4,\"rot\":90}]}",
    });

    const doc = (readDesignDoc(alloc, project, "foo") catch SidecarDoc{});
    const once = cachePoses(alloc, doc.cache) orelse return error.NoCachedPoses;
    const rereading = readAutoPoses(alloc, project, "foo") orelse return error.NoCachedPoses;
    try std.testing.expectEqual(rereading.len, once.len);
    try std.testing.expectEqualStrings("U1", once[0].ref);
    try std.testing.expectEqual(@as(f64, 3), once[0].x);
    try std.testing.expectEqual(@as(f64, 4), once[0].y);
    try std.testing.expectEqual(@as(f64, 90), once[0].rot);
}

// spec: Web Server - Silk texts resolve against an already-parsed layout list, naming the requested row or falling back to the starred default
test "layoutTextsIn picks the named row, else the starred default" {
    const shown = [_]font5x7.BoardText{.{ .x = 1, .y = 1, .text = "SHOWN" }};
    const starred = [_]font5x7.BoardText{.{ .x = 2, .y = 2, .text = "STARRED" }};
    const layouts = [_]SavedLayout{
        .{ .name = "shown", .kind = kind_manual, .ts = 1, .score = null, .parts = &.{}, .texts = &shown },
        .{ .name = "auto", .kind = kind_manual, .ts = 2, .score = null, .parts = &.{}, .default = true, .texts = &starred },
    };

    // A named row wins even when another row holds the star.
    try std.testing.expectEqualStrings("SHOWN", layoutTextsIn(&layouts, "shown")[0].text);
    // No name asked for → the ★ row's silk is what the Gerbers render.
    try std.testing.expectEqualStrings("STARRED", layoutTextsIn(&layouts, null)[0].text);
    // A row that is gone reads as no silk rather than borrowing another row's.
    try std.testing.expectEqual(@as(usize, 0), layoutTextsIn(&layouts, "deleted").len);
}

// spec: Web Server - The PCB editor draws a movable circular axial-fan target and outlet footprint, edits its PCB face and outlet-to-target distance with its catalog airflow/pressure and installed-flow assumption, explains that a same-face heatsink makes the target its fin tips, and persists the exact fan assembly with each saved layout for the thermal fan scenario
// spec: Web Server - physical board navigation exposes stable 3D and a read-only assembly workspace
// spec: serve/board-review - the PCB header exposes Review only for board designs and preserves a selected saved layout
test "PCB header links board designs to assembly and keeps modules scoped" {
    var board: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer board.deinit();
    try pcb_layout_chrome.writeHeadNav(&board.writer, false, "demo", "Demo", null, .{ .routed = 70, .total = 90, .unique_routed = 7, .unique_total = 9 });
    try std.testing.expect(std.mem.indexOf(u8, board.written(), "href=\"/pcb-layout/demo?view=3d\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board.written(), "href=\"/assembly-debug/demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board.written(), "href=\"/review/demo\"") != null);
    var selected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer selected.deinit();
    try pcb_layout_chrome.writeHeadNav(&selected.writer, false, "demo", "Demo", "an2548-div4-post-ldo", null);
    try std.testing.expect(std.mem.indexOf(u8, selected.written(), "href=\"/assembly-debug/demo?layout=an2548-div4-post-ldo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected.written(), "href=\"/review/demo?layout=an2548-div4-post-ldo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_toggle_js, "get(\"view\")===\"3d\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_stage_html, "id=\"pcb3d-bottom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_stage_html, "id=\"pcb3d-export-step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_stage_html, "id=\"pcb3d-export-artwork\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_stage_html, "id=\"pcb3d-t-surface\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_stage_html, "id=\"pcb3d-t-heatsink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_stage_html, "id=\"pcb3d-t-fan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("assets/pcb_board.js"), "function hsModalOpen(rect)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.cooling_modals, "id=\"hs-fin-count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.cooling_modals, "id=\"hs-shape\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.cooling_modals, "id=\"hs-lower-w\"") != null);
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function hsDragMove(m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "heatsink moved/resized") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function hsCountToGap()") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function hsProfileSync()") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "hsModalOpen(PCB.heatsink)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.toolstrip_html, "id=\"pcb-fan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.cooling_modals, "id=\"fan-distance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.cooling_modals, "id=\"fan-flow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function drawFan()") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function fanDragMove(m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "fanModalOpen(PCB.fan)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "fan:savedFan") != null);
    const viewer_js = @embedFile("assets/pcb_3d_viewer.js");
    try std.testing.expect(std.mem.indexOf(u8, viewer_js, "function rebuildHeatsink()") != null);
    try std.testing.expect(std.mem.indexOf(u8, viewer_js, "s.shape === \"stepped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, viewer_js, "function rebuildFan()") != null);
    try std.testing.expect(std.mem.indexOf(u8, viewer_js, "f.distance_mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_toggle_js, "netlisp-pcb-view") != null);
    const surface_asset = std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_toggle_js, "pcb_3d_surface.js") orelse return error.TestUnexpectedResult;
    const step_export_asset = std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_toggle_js, "pcb_step_export.js") orelse return error.TestUnexpectedResult;
    const viewer_asset = std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_toggle_js, "pcb_3d_viewer.js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(surface_asset < step_export_asset and step_export_asset < viewer_asset);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_toggle_js, "occt-import-js.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_chrome.pcb_3d_toggle_js, "pcb_fusion_bundle.js") == null);

    var module: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer module.deinit();
    try pcb_layout_chrome.writeHeadNav(&module.writer, true, "power", "Power", null, null);
    try std.testing.expect(std.mem.indexOf(u8, module.written(), "/assembly-debug/") == null);
    try std.testing.expect(std.mem.indexOf(u8, module.written(), "/review/") == null);
}

// spec: Web Server - The Routed UI count collapses per-pin micro-net connections onto unique logical net names while requiring every member connection to close
test "PCB editor header carries a live unique-net routing summary" {
    var incomplete: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer incomplete.deinit();
    try pcb_layout_chrome.writeHeadNav(&incomplete.writer, false, "demo", "Demo", null, .{ .routed = 70, .total = 90, .unique_routed = 7, .unique_total = 9 });
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "class=\"pcb-route-summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "Routed <strong>7 / 9</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "70 / 90") == null);
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "Unique logical nets completed") != null);

    var complete: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer complete.deinit();
    try pcb_layout_chrome.writeHeadNav(&complete.writer, false, "demo", "Demo", null, .{ .routed = 90, .total = 90, .unique_routed = 9, .unique_total = 9 });
    try std.testing.expect(std.mem.indexOf(u8, complete.written(), "class=\"pcb-route-summary complete\"") != null);

    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function routeSummary(routed,total)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function uniqueRouteCounts(j)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "typeof j.unique_routed===\"number\"") != null);
    const page_src = @embedFile("pcb_layout_page.zig");
    try std.testing.expect(std.mem.indexOf(u8, page_src, "\\\"unique_routed\\\":{d},\\\"unique_total\\\":{d}") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "drcChip(shown.length);routeSummaryFrom(j)") != null);
    const route_apply = std.mem.indexOf(u8, board_js, "else setStat(\"r-stat\",ok?") orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, board_js[route_apply..], "routeSummaryFrom(j);") != null);
}

// spec: Web Server - The PCB editor offers a persistent display-only heatsink visibility toggle in Appearance > Objects, without changing saved geometry or thermal simulations, and entering the heatsink edit tool reveals a hidden heatsink
test "PCB editor can hide its heatsink overlay without changing the authored assembly" {
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "clr:0,heatsink:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "{key:\"heatsink\",name:\"Heatsink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "if(!viewSt.vis.heatsink&&!heatsinkMode&&!heatsinkDraw)return") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "if(on&&!viewSt.vis.heatsink)") != null);
}

// spec: Web Server - The /pcb-layout page defaults to the design's starred (★) saved layout, below an explicit ?refine= snapshot and a (placement …) spec
test "scorebar source classifies the starred default layout" {
    const poses = [_]optimizer.RefPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const cached: ?[]const optimizer.RefPose = &poses;
    // Nothing more specific asked for + a starred layout loaded → starred default.
    try std.testing.expectEqual(LayoutSource.starred, classifyLayoutSource(null, false, false, .{}, "best", cached));
    // An explicit ?refine= snapshot still outranks the starred default.
    try std.testing.expectEqual(LayoutSource.snapshot, classifyLayoutSource(null, false, false, .{ .refine = "hand" }, "best", cached));
    // So does a ?layout= direct link.
    try std.testing.expectEqual(LayoutSource.snapshot, classifyLayoutSource(null, false, false, .{ .view = "hand" }, "best", cached));
    // A driving (placement …) spec outranks the starred default.
    try std.testing.expectEqual(LayoutSource.spec, classifyLayoutSource(null, false, true, .{}, "best", cached));
    // No starred layout, just the auto cache → cache.
    try std.testing.expectEqual(LayoutSource.cache, classifyLayoutSource(null, false, false, .{}, null, cached));
}

/// Two saved layouts for the selector tests: "star" is the ★ default (U1 at
/// 1,1), "alt" is an unstarred candidate (U1 at 9,9) — different poses so the
/// test can tell which one the ladder picked.
const sel_sidecar =
    \\{"default":"star","layouts":[
    \\ {"name":"star","kind":"manual","ts":2,"parts":[{"ref":"U1","x":1,"y":1,"rot":0}]},
    \\ {"name":"alt","kind":"manual","ts":1,"parts":[{"ref":"U1","x":9,"y":9,"rot":0}]}]}
;

/// A block with no instances — enough for `chooseLayout`, whose only use of it
/// is the origin-key re-key (which falls back to the stored refs).
const sel_block = env_mod.DesignBlock{
    .name = "foo",
    .instances = &.{},
    .nets = &.{},
    .ports = &.{},
    .notes = &.{},
    .groups = &.{},
    .sub_blocks = &.{},
};

// spec: Web Server - ?layout=<name> shows that saved layout verbatim, outranking the starred default, while ?refine= re-solves from it
test "the layout selector shows a named snapshot verbatim above the starred default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = sel_sidecar });

    var block = sel_block;
    const none = chooseLayout(alloc, null, &block, .{}, .{ .params = .{}, .tuned = false, .regen = false }, (readSidecarDoc(alloc, project, "foo", null) catch SidecarDoc{}));
    // Nothing asked for → the ★ default, rendered verbatim.
    try std.testing.expectEqualStrings("star", none.starred_name orelse return error.TestNoStar);
    try std.testing.expect(none.verbatim);
    try std.testing.expectEqual(@as(f64, 1), (none.cached orelse return error.TestNoPoses)[0].x);

    // ?layout=alt names a specific snapshot: it outranks the star (which is no
    // longer even consulted) and still renders verbatim — a direct link must
    // reproduce the saved board exactly, never a re-solve of it.
    const view = chooseLayout(alloc, null, &block, .{ .view = "alt" }, .{ .params = .{}, .tuned = false, .regen = false }, (readSidecarDoc(alloc, project, "foo", null) catch SidecarDoc{}));
    try std.testing.expect(view.starred_name == null);
    try std.testing.expect(view.verbatim);
    try std.testing.expectEqual(@as(f64, 9), (view.cached orelse return error.TestNoPoses)[0].x);

    // ?refine= seeds from the same snapshot but asks for a re-solve, so it is
    // deliberately NOT verbatim.
    const refine = chooseLayout(alloc, null, &block, .{ .refine = "alt" }, .{ .params = .{}, .tuned = false, .regen = false }, (readSidecarDoc(alloc, project, "foo", null) catch SidecarDoc{}));
    try std.testing.expect(!refine.verbatim);
    try std.testing.expectEqual(@as(f64, 9), (refine.cached orelse return error.TestNoPoses)[0].x);

    // A ?layout= naming nothing resolves no poses — the page turns that into a
    // 404 rather than quietly falling back to a different board.
    const missing = chooseLayout(alloc, null, &block, .{ .view = "nope" }, .{ .params = .{}, .tuned = false, .regen = false }, (readSidecarDoc(alloc, project, "foo", null) catch SidecarDoc{}));
    try std.testing.expect(missing.cached == null);
}

// spec: Web Server - A ?layout= name matching no saved layout is a 404 that lists the names that do exist
test "an unknown layout link names the layouts that do exist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = sel_sidecar });

    const msg = unknownLayoutMsg(alloc, project, "foo", null, "nope");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"nope\"") != null);
    // Both existing names are offered, so a stale link is one click from the
    // layout it meant.
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"star\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"alt\"") != null);

    // A design with nothing saved says that instead of listing an empty set.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/bare.layouts.json", .data = "{\"layouts\":[]}" });
    const bare = unknownLayoutMsg(alloc, project, "bare", null, "nope");
    try std.testing.expect(std.mem.indexOf(u8, bare, "no saved layouts yet") != null);
}

// spec: Web Server - The /pcb-layout saved-version sidebar renames and deletes any selected named layout, rejecting duplicate names and stale revisions
test "saved-layout sidebar manages selected layout names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const saved = [_]SavedLayout{
        .{ .name = "alpha", .kind = kind_manual, .ts = 2, .score = null, .parts = &.{}, .default = true },
        .{ .name = "beta", .kind = kind_manual, .ts = 1, .score = null, .parts = &.{} },
    };
    const renamed = try renamedLayoutList(alloc, &saved, "alpha", "release");
    try std.testing.expectEqualStrings("release", renamed[0].name);
    try std.testing.expect(renamed[0].default);
    try std.testing.expectEqualStrings("beta", renamed[1].name);
    try std.testing.expectError(error.NameExists, renamedLayoutList(alloc, &saved, "alpha", "beta"));
    try std.testing.expectError(error.LayoutNotFound, renamedLayoutList(alloc, &saved, "missing", "release"));
    const remaining = try deletedLayoutList(alloc, &saved, "alpha");
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("beta", remaining[0].name);
    try std.testing.expectError(error.LayoutNotFound, deletedLayoutList(alloc, &saved, "missing"));

    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function bindLayRename") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"/rename\"+subq()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rev:PCB.rev||0") != null);
}

// spec: Web Server - A block's first-ever saved layout is starred, and a later save never takes the star from the user's pick
test "the first saved layout is starred and later saves leave the star alone" {
    const row = SavedLayout{ .name = "a", .kind = kind_manual, .ts = 1, .score = null, .parts = &.{} };

    // First-ever save: nothing would be blessed otherwise, so the page would
    // reopen on the optimizer cache instead of the board you just saved.
    var one = [_]SavedLayout{row};
    starFirstEver(&one);
    try std.testing.expect(one[0].default);

    // A second layout arrives: the star stays on the user's pick, not the newest.
    var two = [_]SavedLayout{ .{ .name = "b", .kind = kind_manual, .ts = 2, .score = null, .parts = &.{} }, .{ .name = "a", .kind = kind_manual, .ts = 1, .score = null, .parts = &.{}, .default = true } };
    starFirstEver(&two);
    try std.testing.expect(!two[0].default);
    try std.testing.expect(two[1].default);

    // A deliberately cleared star on a multi-layout block stays cleared.
    var cleared = [_]SavedLayout{ .{ .name = "b", .kind = kind_manual, .ts = 2, .score = null, .parts = &.{} }, row };
    starFirstEver(&cleared);
    try std.testing.expect(!cleared[0].default);
    try std.testing.expect(!cleared[1].default);
}

// spec: Web Server - A named save always lands, and two named layouts sharing a placement are never merged, so routings of one board survive as separate candidates
test "two named layouts over one placement both survive the dedup" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Two autoroute candidates over the SAME placement: the score measures
    // placement only, so both carry an identical one. Plus the auto stamp that
    // recorded that placement, which is exactly what the dedup exists to fold.
    const score = LayoutScore{ .hpwl = 10, .loop = 2, .caps = 0, .objective = 12 };
    const rows = [_]SavedLayout{
        .{ .name = "route-a", .kind = kind_manual, .ts = 3, .score = score, .parts = &.{}, .default = true },
        .{ .name = "route-b", .kind = kind_manual, .ts = 2, .score = score, .parts = &.{} },
        .{ .name = "auto · Jul 27", .kind = kind_auto, .ts = 1, .score = score, .parts = &.{} },
    };
    const kept = dedupLayouts(alloc, &rows);
    // Both named candidates survive — collapsing them would silently delete
    // every routing of a board but the first, on the next page load.
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("route-a", kept[0].name);
    try std.testing.expectEqualStrings("route-b", kept[1].name);
    // The redundant auto stamp still folds into the named entry it duplicates,
    // and the ★ is carried, not dropped.
    try std.testing.expect(kept[0].default);
}

// spec: Web Server - Ordinary PCB-editor courtyard outlines use a 0.25-pixel stroke, standalone-part hover and selection outlines stay emphasized, and rigid sub-circuit hover highlights only the group bounding box
test "PCB courtyard highlights distinguish parts from sub-circuit bounds" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "return {c:TH.court,w:0.25};") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(selRef&&p.ref===selRef)return {c:\"#ffffff\",w:2.4};") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var groupHover=hoverGrpName&&grpOf(p.ref)===hoverGrpName;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(i===cur&&!RO&&!groupHover)return {c:\"#ffffff\",w:2};") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(hoverGrpName&&grpOf(p.ref)===hoverGrpName)return {c:\"#7ee787\",w:2};") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "ctx.strokeStyle=(picked||hov)?\"#7ee787\":\"rgba(126,231,135,0.4)\";") != null);
}

// spec: Web Server - Every saved trace segment and via has a stable inspector-visible ID that survives saves and retained-copper rewrites, with deterministic IDs backfilled for legacy copper
test "PCB viewer exposes provenance and persistent copper IDs" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "source:\"human\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "source:t.source") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "source:v.source") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "human:\"Human drawn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "agent:\"AI agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "autorouter:\"Autorouter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "imported:\"KiCad import\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "||\"Unknown (legacy)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "pRow(\"Source\",routeSourceLabel(o.source))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "pRow(\"Segment ID\",trackIdEnsure(o))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "pRow(\"Via ID\",viaIdEnsure(o))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "id:trackIdEnsure(t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "id:viaIdEnsure(v)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "copperIdsEnsureAll();var saveGeneration") != null);
}

// spec: placement/rf-port-frame-routing - a named saved layout made before automatic tapers reconciles only uncovered nominal-width launch runs, accepts no new routing-class DRC errors, persists the approved RF paths through ordinary autosave, and exposes each rejected taper as a clickable DRC error at the blocking clearance
test "saved controlled-impedance copper receives an idempotent DRC-gated taper retrofit" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function drawRfRetrofitPlan()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(t.source===\"autorouter\"||claimed[id]||rfOwnsTrack(t))return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "!(+c.impedance_ohms>0)||(+c.diff_impedance_ohms>0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drawViaAt(last.net,x,y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function drawRfRetrofitCheck(paths)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "payload.rf_paths=paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drawRfRetrofitCheck(original.concat(accepted,pending[i]))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Array.prototype.push.apply(accepted,pending[i]);acceptedBundles++") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function drawRfRetrofitNewBlocks(before,after)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "blocked.push(drawRfRetrofitNotice(pending[i],newBlocks,i))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "k:\"impedance taper blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "click the DRC errors to locate") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.drc=drawRfRetrofitDrcMerge(baseline)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var shown=drawRfRetrofitDrcMerge(srv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "list=drawRfRetrofitDrcMerge(list)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drawRfRetrofitDrcClear();") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.rf_paths=original.concat(accepted)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function drawRfRetrofitSchedule(){if(RO||FBENCH||!curLayout)return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!RO&&!FBENCH&&PCB.shown_layout)setTimeout(drawRfRetrofitSaved,0);") != null);
}

// spec: Web Server - visible board silkscreen text can be selected and grid-dragged directly in Select mode, with one undo step and refreshed DRC
test "Select mode directly drags visible board silkscreen text" {
    const js = @embedFile("assets/pcb_board.js");
    // The normal pointer path resolves visible text before underlying copper
    // or footprints, then shares the Text tool's one drag implementation.
    try std.testing.expect(std.mem.indexOf(u8, js, "function txDirectAt(m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var directText=ev.button===0?txDirectAt(m):-1,directSnap=null,directAdopt=false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(directSub){directSnap=snapAll();directText=subSilkAdopt(directSub);directAdopt=true;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "txDragStart(directText,m,ev,directSnap,directAdopt)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(txSel>=0)txSelect(-1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(ti>=0)txDragStart(ti,tm,ev);") != null);
    // The drop commits the captured pre-drag snapshot once and re-checks the
    // silkscreen/courtyard warning at the label's new position.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(moved||adopted){recordUndo(tsnap);txDirty();txPopReposition(ti);scheduleDrc();}") != null);
    // Generated names are promoted to tagged persisted board text only when
    // selected, so untouched labels remain automatically positioned while a
    // manually moved label suppresses exactly one generated fabrication copy.
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkAdopt(q)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "subcircuit:q.g") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "subcircuit:t.subcircuit||undefined") != null);
    // Generated test-point references use the same adoption path. The full
    // ref-des owns the persisted override even though its visible silk is the
    // leaf label, so equal TP names in different sub-circuits stay distinct.
    try std.testing.expect(std.mem.indexOf(u8, js, "function testPointSilkAt(wx,wy)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function testPointSilkAdopt(tp)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "testpoint:p.ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "testpoint:t.testpoint||undefined") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(directTp){directSnap=snapAll();directText=testPointSilkAdopt(directTp);directAdopt=true;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "testPointSilkRelease(P[di].ref)") != null);
    // Moving the sub-circuit itself releases the adopted name so automatic
    // placement takes over again, while dragging the label keeps it manual.
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkRelease(g)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!gdrag.moved){gdrag.moved=true;if(gdrag.g)subSilkRelease(gdrag.g)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function fabTextAdopt()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "fabTextAt(m.x,m.y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "fabrication_id:!!t.fabrication_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!fabTextOverridden()&&PCB.fab_text)") != null);
}

// spec: Web Server - a deferred PCB load retains an adopted fabrication-ID position and refreshes its derived text before Update persists it
test "deferred fabrication ID retains and refreshes its saved anchor" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "fabTextResolve(PCB.fab_text,!PCB.analysis_deferred)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "fabTextResolve(j.fab_text||null,true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "t.text=PCB.fab_text.text;t.fabrication_id=true") != null);
}

// spec: fabrication-release - the browser always offers an explicit prototype/test-board acknowledgment that can export with DRC or production-readiness findings while keeping the reports visible
test "fabrication export explicitly acknowledges prototype findings" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "id=\"fab-drc-ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Acknowledge and export test board") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "prototype_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "prototype=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drcAck&&!drcAck.checked") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drc-report.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "does not mark this board production-ready") != null);
}

// spec: Web Server - The deterministic PCB-editor benchmark never schedules a saved-layout migration or autosave while measuring read-only frame performance
test "PCB editor benchmark does not schedule saved layout migration" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function drawRfRetrofitSchedule(){if(RO||FBENCH||!curLayout)return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!RO&&!FBENCH&&PCB.shown_layout)setTimeout(drawRfRetrofitSaved,0)") != null);
}

test "PCB viewer replaces detected footprint pin-one circles with live collision-aware dots" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "var PIN_ONE_LIMIT=0.5,PIN_ONE_DIA=0.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function pinOneDirectional(p)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "p.kind===\"hub\"&&pads.length>1") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function pinOneHitsFootprintSilk(side,x,y,silk)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function pinOneSilkPlace(i,used,pads,keepouts,silk)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(pinOneAuthoredCircle(sc))return") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "paintPinOneSilk(ctx,mov,only,all.pin1)") != null);
}

// spec: Web Server - R and Shift-R rotate a held board-silkscreen label live and commit the whole drag as one undo step
test "R rotates board silkscreen text during its drag" {
    const js = @embedFile("assets/pcb_board.js");
    // This branch must precede kbTyping: pointer-down opens and focuses the
    // label editor, but R belongs to the active canvas gesture while held.
    const rotate = std.mem.indexOf(u8, js, "if(txDrag&&(ev.key==\"r\"||ev.key==\"R\"))") orelse return error.TestExpectedRotateBranch;
    const typing = std.mem.indexOf(u8, js, "var typing=kbTyping(ev.target);") orelse return error.TestExpectedTypingGuard;
    try std.testing.expect(rotate < typing);
    try std.testing.expect(std.mem.indexOf(u8, js, "txRotate(txDrag.i,ev.shiftKey?-90:90);txDrag.moved=true;paintSoon();return;") != null);
    // No nested recordUndo here: pointer-up owns the captured pre-drag state.
    try std.testing.expect(std.mem.indexOf(u8, js[rotate..typing], "recordUndo") == null);
}

// spec: Web Server - the /pcb-layout board blob carries a decoupling loop's declared hub pad and omits it when the solver defaulted
test "the board blob names an authored decoupling pad and omits it when defaulted" {
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &.{}, .fallback = false, .x = -4 },
    };
    const hp = [_]optimizer.PadRect{.{ .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 }};
    const hg = [_]optimizer.PadRect{.{ .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 }};
    var lp = optimizer.Loop{
        .cap = 1,
        .hub = 0,
        .cap_pwr = hp[0],
        .cap_gnd = hg[0],
        .hub_pwr = &hp,
        .hub_gnd = &hg,
        .hub_pwr_pin = hp[0],
        .hub_gnd_pin = hg[0],
        .explicit_pin = "12",
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = @as(*const [1]optimizer.Loop, &lp),
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 1 },
        .minx = -6,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // Both surfaces name the declared pad: the board blob the viewer reads
    // (PCB.loops) and the placement JSON `/pcb-layout?json=1` returns.
    try pcb_layout_blob.writeLoopJson(&aw.writer, p, lp, &.{});
    try pcb_layout_blob.writePlacementJson(&aw.writer, p, .{}, "t", &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"ep\":\"12\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"cap\":\"C1\",\"hub\":\"U1\"") != null);
    // Defaulted target: no `ep` key at all, on either surface.
    lp.explicit_pin = "";
    var dw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dw.deinit();
    try pcb_layout_blob.writeLoopJson(&dw.writer, p, lp, &.{});
    try pcb_layout_blob.writePlacementJson(&dw.writer, p, .{}, "t", &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, dw.written(), "\"ep\"") == null);
}

// spec: Web Server - the placement-guide power line is dashed for a defaulted decoupling target and solid for an authored one
test "the placement-guide power line dashes a defaulted decoupling target" {
    const js = @embedFile("assets/pcb_board.js");
    // Solid only when the design DECLARED the pad (`ep`); dashed otherwise.
    try std.testing.expect(std.mem.indexOf(u8, js, "d.power.setAttribute(\"stroke-dasharray\",L.ep?\"none\":\"3 2\");") != null);
    // …and the guide's own tooltip says which of the two it is.
    try std.testing.expect(std.mem.indexOf(u8, js, "\" pin \"+L.ep+\" (declared)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\" (defaulted)\"") != null);
}

test "net-class settings synchronize existing track and via geometry" {
    const board_js = @embedFile("assets/pcb_board.js");
    const settings_js = @embedFile("assets/pcb_settings.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function netClassGeometryPlan(tracks,vias)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "p.tracks.forEach(function(q){q.track.w=q.width;})") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "p.vias.forEach(function(q){q.via.d=q.dia;q.via.drill=q.drill;})") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "rfDropForTracks(changedTracks)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "if(poursDeclared())refillPours();") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "recordUndo(before)") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings_js, "id=\"ds-class-sync\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings_js, "Apply classes to routed copper") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings_js, "window.PCBApplyNetClassGeometry()") != null);
}

// Net colours are the permanent presentation and need neither a toggle nor a legend.
test "the pcb editor keeps net colours on without a control or legend" {
    const css = @embedFile("assets/pcb_layout.css");
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, css, ".net-legend") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "getElementById(\"net-legend\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "name:\"Net colours\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function apNetsHtml") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var netColOn=true;") != null);
}

// spec: Web Server - A saved layout round-trips each part's renumber-stable origin key through the sidecar
test "layouts sidecar round-trips part origin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // One part with an origin key, one legacy part without (empty origin).
    const parts = [_]PartPose{
        .{ .ref = "C1", .x = 1, .y = 2, .rot = 90, .origin = "C_VDDIN_BULK" },
        .{ .ref = "U1", .x = 0, .y = 0, .rot = 0 },
    };
    const layouts = [_]SavedLayout{.{ .name = "hand", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const text = aw.written();
    // The empty origin is omitted from the JSON; the populated one is present.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"origin\":\"C_VDDIN_BULK\"") != null);

    const got = parseLayouts(alloc, text) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), got[0].parts.len);
    try std.testing.expectEqualStrings("C_VDDIN_BULK", got[0].parts[0].origin);
    try std.testing.expectEqualStrings("", got[0].parts[1].origin);
}

// spec: Web Server - A saved layout round-trips its user-drawn board outline through the sidecar
test "layouts sidecar round-trips a drawn outline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const poly = [_][2]f64{ .{ -5, -2.5 }, .{ 45, -2.5 }, .{ 45, 37.5 }, .{ -5, 37.5 } };
    const radii = [_]f64{ 2, 2, 2, 2 };
    const layouts = [_]SavedLayout{.{
        .name = "outlined",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .outline = .{ .x = -5, .y = -2.5, .w = 50, .h = 40, .pts = &poly, .radii = &radii },
    }};
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const o = got[0].outline orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(f64, -5), o.x);
    try std.testing.expectEqual(@as(f64, 50), o.w);
    try std.testing.expectEqual(@as(f64, 40), o.h);
    try std.testing.expectEqual(@as(usize, 4), o.derived.arcs.len);
    try std.testing.expectEqual(@as(f64, 2), o.radii.?[0]);
    // A degenerate outline (zero size) never round-trips into existence.
    try std.testing.expect(parseSavedOutline(alloc, null) == null);
}

// spec: Web Server - The PCB editor draws one target-free physical heatsink rectangle on either PCB face, reopens it for parameter edits, drags it to reposition, resizes it with corner handles, directly edits fin count or gap, material, base/fins and thermal pad, persists the assembly with the named layout, previews its pad/base/fins in 3D, and resolves a populated face through covered packages' directional theta-JC-top into one shared plate while an unobstructed face couples the PCB through the pad
test "layouts sidecar round-trips a physical heatsink assembly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U15", .x = 12, .y = 8, .rot = 0 }};
    const layouts = [_]SavedLayout{
        .{
            .name = "bottom sink",
            .kind = kind_manual,
            .ts = 1,
            .score = null,
            .parts = &parts,
            .heatsink = .{
                .x = 4,
                .y = 5,
                .w = 24,
                .h = 18,
                .side = "bottom",
                .material = "aluminum_6061",
                .base_mm = 2.5,
                .profile = .{ .finned = .{ .height_mm = 12, .thickness_mm = 0.8, .gap_mm = 1.2, .axis = "width" } },
                .pad_thickness_mm = 0.5,
                .pad_k_w_mk = 6,
            },
            .fan = .{ .model = "Sanyo Denki 9A0812G4D011", .rect = .{ .x = 0.5, .y = -27.6, .w = 80, .h = 80 }, .side = "top", .distance_mm = 10, .curve = .{ .free_air_flow_m3_s = 0.025, .max_static_pressure_pa = 80.4 }, .operating_flow_fraction = 0.6 },
        },
        .{
            .name = "case cold plate",
            .kind = kind_manual,
            .ts = 2,
            .score = null,
            .parts = &parts,
            .heatsink = .{
                .x = 4,
                .y = 5,
                .w = 24,
                .h = 18,
                .side = "bottom",
                .base_mm = 3,
                .profile = .{ .stepped = .{ .width_mm = 40, .length_mm = 30, .height_mm = 8 } },
            },
        },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sink = got[0].heatsink orelse return error.TestParseFailed;
    try std.testing.expectEqualStrings("", sink.target_ref);
    try std.testing.expectEqualStrings("bottom", sink.side);
    try std.testing.expectEqualStrings("aluminum_6061", sink.material);
    const fins = sink.profile.finned;
    try std.testing.expectEqualStrings("width", fins.axis);
    try std.testing.expectEqual(@as(f64, 24), sink.w);
    try std.testing.expectEqual(@as(f64, 0.8), fins.thickness_mm);
    try std.testing.expectEqual(@as(f64, 0.5), sink.pad_thickness_mm);
    // Layouts saved before board contact became target-free carried a nearest-
    // package hint. They remain readable and no longer depend on that part
    // having a thermal-power row when lowered at the thermal boundary.
    const legacy = parseSavedHeatsink(try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"side\":\"bottom\",\"target_ref\":\"U99\"}", .{})) orelse return error.TestParseFailed;
    try std.testing.expectEqualStrings("U99", legacy.target_ref);
    const stepped = got[1].heatsink orelse return error.TestParseFailed;
    const lower = stepped.profile.stepped;
    try std.testing.expectEqual(@as(f64, 40), lower.width_mm);
    try std.testing.expectEqual(@as(f64, 30), lower.length_mm);
    try std.testing.expectEqual(@as(f64, 8), lower.height_mm);
    const fan = got[0].fan orelse return error.TestParseFailed;
    try std.testing.expectEqualStrings("Sanyo Denki 9A0812G4D011", fan.model);
    try std.testing.expectEqual(@as(f64, 0.5), fan.rect.x);
    try std.testing.expectEqual(@as(f64, 10), fan.distance_mm);
    try std.testing.expectEqual(@as(f64, 0.025), fan.curve.free_air_flow_m3_s);
    try std.testing.expectEqual(@as(f64, 0.6), fan.operating_flow_fraction);
}

// spec: Web Server - applyShownOutline folds a saved layout's drawn outline (rect or polygon) onto the placement, and is a no-op for a layout without one
test "applyShownOutline folds a drawn outline onto the placement" {
    const one = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 8 }, .{ 0, 8 } };
    const layouts = [_]SavedLayout{
        .{ .name = "rect", .kind = kind_manual, .ts = 0, .score = null, .parts = &one, .outline = .{ .x = 1, .y = 2, .w = 20, .h = 15 } },
        .{ .name = "poly", .kind = kind_manual, .ts = 0, .score = null, .parts = &one, .outline = .{ .x = 0, .y = 0, .w = 10, .h = 8, .pts = &poly } },
        .{ .name = "bare", .kind = kind_manual, .ts = 0, .score = null, .parts = &one },
    };
    const base = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
    };
    // A rect outline sets board_rect (its bbox); board_poly stays null.
    var p = base;
    try std.testing.expect(applyShownOutline(&p, &layouts, "rect"));
    try std.testing.expectEqual(@as(f64, 1), p.board_rect.?.minx);
    try std.testing.expectEqual(@as(f64, 20), p.board_rect.?.w);
    try std.testing.expect(p.board_poly == null);
    // A polygon outline also carries its exact points onto board_poly.
    var p2 = base;
    try std.testing.expect(applyShownOutline(&p2, &layouts, "poly"));
    try std.testing.expect(p2.board_poly != null);
    try std.testing.expectEqual(@as(usize, 4), p2.board_poly.?.len);
    // A layout with no outline — and an unknown name — is a no-op: board_rect stays null.
    var p3 = base;
    try std.testing.expect(!applyShownOutline(&p3, &layouts, "bare"));
    try std.testing.expect(p3.board_rect == null);
    try std.testing.expect(!applyShownOutline(&p3, &layouts, "nope"));
    try std.testing.expect(p3.board_rect == null);
}

// spec: Web Server - outlineForBody prefers a submitted outline, else the blessed drawn outline (the default layout's first, else the first layout carrying one), else authored-only
test "outlineForBody submitted > blessed > authored-only" {
    const one = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{
        .{ .name = "bare", .kind = kind_manual, .ts = 0, .score = null, .parts = &one },
        .{ .name = "first", .kind = kind_manual, .ts = 0, .score = null, .parts = &one, .outline = .{ .x = 3, .y = 3, .w = 30, .h = 20 } },
        .{ .name = "star", .kind = kind_manual, .ts = 0, .score = null, .parts = &one, .outline = .{ .x = 1, .y = 2, .w = 20, .h = 15 } },
    };
    // Blessed lookup: the default (★) layout's outline wins …
    try std.testing.expectEqual(@as(f64, 20), blessedOutlineIn(&layouts, "star").?.w);
    // … a default without one falls to the first layout carrying one …
    try std.testing.expectEqual(@as(f64, 30), blessedOutlineIn(&layouts, "bare").?.w);
    try std.testing.expectEqual(@as(f64, 30), blessedOutlineIn(&layouts, null).?.w);
    // … and no drawn outline anywhere yields null.
    const none = [_]SavedLayout{layouts[0]};
    try std.testing.expect(blessedOutlineIn(&none, null) == null);
    // A submitted outline short-circuits ahead of any sidecar read (the
    // project dir here doesn't even exist), carrying its exact polygon.
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 8 }, .{ 0, 8 } };
    const sub = SavedOutline{ .x = 0, .y = 0, .w = 10, .h = 8, .pts = &poly };
    const src = outlineForBody(std.testing.allocator, "/nonexistent-dir", "nope", null, sub);
    try std.testing.expectEqual(@as(f64, 10), src.drawn.rect.w);
    try std.testing.expectEqual(@as(usize, 4), src.drawn.poly.?.len);
    // No submitted outline + no sidecar ⇒ authored-only.
    try std.testing.expect(outlineForBody(std.testing.allocator, "/nonexistent-dir", "nope", null, null) == .authored_only);
}

// spec: Web Server - A saved layout round-trips a polygon board outline; the rect fields are re-derived as its bbox
test "layouts sidecar round-trips a polygon outline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // L-shaped outline; the stored rect fields deliberately LIE (0,0,1,1) —
    // the parser must re-derive them from the polygon bbox.
    const l_pts = [_][2]f64{ .{ -5, 0 }, .{ 45, 0 }, .{ 45, 20 }, .{ 20, 20 }, .{ 20, 40 }, .{ -5, 40 } };
    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{.{
        .name = "poly-outlined",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .outline = .{ .x = 0, .y = 0, .w = 1, .h = 1, .pts = &l_pts },
    }};
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const o = got[0].outline orelse return error.TestParseFailed;
    const pts = o.pts orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 6), pts.len);
    try std.testing.expectEqual(@as(f64, 20), pts[3][0]);
    try std.testing.expectEqual(@as(f64, 20), pts[3][1]);
    // Rect fields = polygon bbox, not the stored lie.
    try std.testing.expectEqual(@as(f64, -5), o.x);
    try std.testing.expectEqual(@as(f64, 0), o.y);
    try std.testing.expectEqual(@as(f64, 50), o.w);
    try std.testing.expectEqual(@as(f64, 40), o.h);
    // A malformed vertex list (pair with one number) rejects the polygon but
    // keeps the rect, so a corrupt sidecar can never reshape the board.
    const bad = parseLayouts(alloc,
        \\{"layouts":[{"name":"b","kind":"manual","ts":1,
        \\ "outline":{"x":1,"y":2,"w":30,"h":20,"pts":[[0],[1,1],[2,2]]},
        \\ "parts":[{"ref":"U1","x":0,"y":0,"rot":0}]}]}
    ) orelse return error.TestParseFailed;
    const bo = bad[0].outline orelse return error.TestParseFailed;
    try std.testing.expect(bo.pts == null);
    try std.testing.expectEqual(@as(f64, 30), bo.w);
}

// spec: Web Server - A saved layout round-trips its board-level silkscreen texts through the sidecar
test "layouts sidecar round-trips board texts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const texts = [_]font5x7.BoardText{
        .{ .x = 3.5, .y = 7.0, .rot = 90, .bottom = true, .size = 1.5, .text = "Rev C", .owner = .{ .subcircuit = "power" } },
        .{ .x = -2, .y = 0, .text = "v1" }, // top side, default size
        .{ .x = 6, .y = 4, .text = "ID OLD", .fabrication_id = true },
        .{ .x = 8, .y = 4, .text = "TP7", .owner = .{ .testpoint = "power/TP7" } },
    };
    const layouts = [_]SavedLayout{.{
        .name = "labelled",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .texts = &texts,
    }};
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 4), got[0].texts.len);
    const t0 = got[0].texts[0];
    try std.testing.expectEqualStrings("Rev C", t0.text);
    try std.testing.expectEqual(@as(f64, 3.5), t0.x);
    try std.testing.expectEqual(@as(f64, 90), t0.rot);
    try std.testing.expect(t0.bottom);
    try std.testing.expectEqual(@as(f64, 1.5), t0.size);
    try std.testing.expectEqualStrings("power", t0.owner.?.subcircuit);
    try std.testing.expect(got[0].texts[2].fabrication_id);
    try std.testing.expectEqualStrings("power/TP7", got[0].texts[3].owner.?.testpoint);
    // The second entry defaults: top side, 1 mm nominal size.
    try std.testing.expect(!got[0].texts[1].bottom);
    try std.testing.expectEqualStrings("v1", got[0].texts[1].text);
    // A blank-text entry is dropped, and a missing array parses as empty.
    try std.testing.expectEqual(@as(usize, 0), parseSavedTexts(alloc, null).len);
    const blank = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "[{\"x\":1,\"y\":2,\"text\":\"\"}]", .{});
    try std.testing.expectEqual(@as(usize, 0), parseSavedTexts(alloc, blank).len);
}

// spec: Web Server - A saved layout round-trips its routed copper (tracks + vias, net-name keyed) through the sidecar
test "layouts sidecar round-trips saved routes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const tracks = [_]SavedTrack{.{ .x1 = 0, .y1 = 0, .xm = 1.5, .ym = -1.5, .x2 = 3, .y2 = 0, .l = 1, .w = 0.3, .net = "VBUS", .source = route_source_human, .id = "seg-fixed00000001" }};
    const vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "VBUS", .source = route_source_agent, .id = "via-fixed00000001" }};
    const layouts = [_]SavedLayout{.{
        .name = "routed",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .routes = .{ .tracks = &tracks, .vias = &vias },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sr = got[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), sr.tracks.len);
    try std.testing.expectEqual(@as(u8, 1), sr.tracks[0].l);
    try std.testing.expectEqual(@as(f64, 0.3), sr.tracks[0].w);
    try std.testing.expectEqual(@as(f64, -1.5), sr.tracks[0].ym.?);
    try std.testing.expectEqualStrings("VBUS", sr.tracks[0].net);
    try std.testing.expectEqualStrings(route_source_human, sr.tracks[0].source);
    try std.testing.expectEqualStrings("seg-fixed00000001", sr.tracks[0].id);
    try std.testing.expectEqual(@as(usize, 1), sr.vias.len);
    try std.testing.expectEqual(@as(f64, 0.3), sr.vias[0].drill);
    try std.testing.expectEqualStrings(route_source_agent, sr.vias[0].source);
    try std.testing.expectEqualStrings("via-fixed00000001", sr.vias[0].id);

    // Restore against a netlist where VBUS is index 1 → indices re-resolve.
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{ .{ .name = "GND", .pins = &pins }, .{ .name = "VBUS", .pins = &pins } };
    const restored = restoreRoutes(alloc, sr, &nets) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(i32, 1), restored.tracks[0].net);
    try std.testing.expectEqual(@as(usize, 1), restored.arcs.len);
    try std.testing.expect(restored.tracks.len > 1);
    try std.testing.expectEqual(@as(i32, 1), restored.vias[0].net);
}

// Regression: legacy copper gains stable IDs and overlapping duplicates do
// not become ambiguous. The inspector/persistence contract is spec-linked by
// "PCB viewer exposes provenance and persistent copper IDs" above.
test "legacy copper IDs backfill deterministically and distinguish duplicates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const duplicate = SavedTrack{ .x1 = 1, .y1 = 2, .x2 = 3, .y2 = 4, .l = 1, .w = 0.25, .net = "SIG" };
    const tracks = [_]SavedTrack{ duplicate, duplicate };
    const duplicate_via = SavedVia{ .x = 2, .y = 3, .d = 0.5, .drill = 0.25, .net = "SIG" };
    const vias = [_]SavedVia{ duplicate_via, duplicate_via };

    var first: std.Io.Writer.Allocating = .init(alloc);
    try writeSavedRoutesJson(&first.writer, .{ .tracks = &tracks, .vias = &vias });
    const parsed_json = try std.json.parseFromSliceLeaky(std.json.Value, alloc, first.written(), .{});
    const parsed = parseSavedRoutes(alloc, parsed_json) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), parsed.tracks.len);
    try std.testing.expect(std.mem.startsWith(u8, parsed.tracks[0].id, pcb_layout_blob.segment_id_prefix));
    try std.testing.expectEqual(@as(usize, pcb_layout_blob.segment_id_prefix.len + 16), parsed.tracks[0].id.len);
    try std.testing.expect(!std.mem.eql(u8, parsed.tracks[0].id, parsed.tracks[1].id));
    try std.testing.expectEqual(@as(usize, 2), parsed.vias.len);
    try std.testing.expect(std.mem.startsWith(u8, parsed.vias[0].id, pcb_layout_blob.via_id_prefix));
    try std.testing.expectEqual(@as(usize, pcb_layout_blob.via_id_prefix.len + 16), parsed.vias[0].id.len);
    try std.testing.expect(!std.mem.eql(u8, parsed.vias[0].id, parsed.vias[1].id));

    var blob: std.Io.Writer.Allocating = .init(alloc);
    try pcb_layout_blob.writeRoutedArrays(&blob.writer, null, &.{}, .{}, .{ .tracks = &tracks, .vias = &.{} }, null);
    try std.testing.expect(std.mem.indexOf(u8, blob.written(), parsed.tracks[0].id) != null);
    try std.testing.expect(std.mem.indexOf(u8, blob.written(), parsed.tracks[1].id) != null);

    var second: std.Io.Writer.Allocating = .init(alloc);
    try writeSavedRoutesJson(&second.writer, parsed);
    try std.testing.expectEqualStrings(first.written(), second.written());
}

// spec: placement/rf-port-frame-routing - solver RF geometry and taper proof survive saved-layout round trips
test "saved layouts restore RF taper geometry and solver proof" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 1, 2 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 3, 2 }, .s_mm = 2, .curvature = 0, .width_mm = 0.3 },
    };
    const track_ids = [_][]const u8{ "seg-a", "seg-b" };
    const rf_paths = [_]SavedRfPath{.{ .net = "RF", .layer = 0, .samples = &samples, .track_ids = &track_ids, .portal = true }};
    const layouts = [_]SavedLayout{.{
        .name = "rf-routed",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &.{},
        .routes = .{ .tracks = &.{}, .vias = &.{}, .rf_paths = &rf_paths },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const parsed = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const saved = parsed[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), saved.rf_paths.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), saved.rf_paths[0].samples[0].width_mm, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), saved.rf_paths[0].samples[1].width_mm, 1e-12);
    try std.testing.expectEqual(@as(usize, track_ids.len), saved.rf_paths[0].track_ids.len);
    for (track_ids, saved.rf_paths[0].track_ids) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(saved.rf_paths[0].portal);

    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &.{} }};
    const restored = restoreRoutes(alloc, saved, &nets) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), restored.rf_port_outcomes.len);
    try std.testing.expect(restored.rf_port_outcomes[0].success);
    try std.testing.expectEqual(@as(i32, 0), restored.rf_port_outcomes[0].net);
    try std.testing.expectEqual(@as(usize, 2), restored.rf_port_outcomes[0].physical.samples.len);
}

// spec: Web Server - a saved layout round-trips its user-drawn copper-pour zones through the sidecar
test "layouts sidecar round-trips user copper-pour zones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 5 }, .{ 0, 5 } };
    const layers = [_][]const u8{ "F.Cu", "B.Cu" };
    const zones = [_]SavedZone{.{ .net = "GND", .layer = "F.Cu", .layers = &layers, .poly = &poly, .flags = .{ .filled = true } }};
    const layouts = [_]SavedLayout{.{
        .name = "poured",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .routes = .{ .tracks = &.{}, .vias = &.{}, .zones = &zones },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sr = got[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), sr.zones.len);
    try std.testing.expectEqualStrings("GND", sr.zones[0].net);
    try std.testing.expectEqualStrings("F.Cu", sr.zones[0].layer);
    try std.testing.expectEqual(@as(usize, 2), sr.zones[0].layers.len);
    try std.testing.expectEqualStrings("B.Cu", sr.zones[0].layers[1]);
    try std.testing.expect(sr.zones[0].flags.filled);
    try std.testing.expect(!sr.zones[0].flags.keepout);
    try std.testing.expectEqual(@as(usize, 4), sr.zones[0].poly.len);
}

// spec: Web Server - saved/imported keepout zones feed the generated-silkscreen exclusion geometry on both board faces
test "saved keepout zones become silkscreen exclusions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const poly = [_][2]f64{ .{ 1, 1 }, .{ 3, 1 }, .{ 2, 3 } };
    const zones = [_]SavedZone{
        .{ .poly = &poly },
        .{ .poly = &[_][2]f64{ .{ 0, 0 }, .{ 1, 1 } }, .flags = .{ .keepout = true } },
        .{ .poly = &poly, .flags = .{ .keepout = true } },
    };
    const got = silkKeepoutsFrom(arena_state.allocator(), &zones);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualSlices([2]f64, &poly, got[0].polygon);
}

// spec: Web Server - the PCB blob and pour-refill compute carved zone_fills for each filled netted outer-layer user zone
test "zone_fills emit a carved rectangle pour over a pad with its zone index and side" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A GND SMD pad on the top face inside a hand-drawn GND user pour rectangle.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 10, .y = 5, .side = .top },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    // Two zones: a valid filled GND F.Cu pour (blob index 0), then a keepout
    // (index 1, dropped from fills). Only the first yields a zone_fill, keyed on
    // its ORIGINAL index in the emitted zones array.
    const poly = [_][2]f64{ .{ 7, 2 }, .{ 13, 2 }, .{ 13, 8 }, .{ 7, 8 } };
    const zones = [_]SavedZone{
        .{ .net = "GND", .layer = "F.Cu", .poly = &poly, .flags = .{ .filled = true } },
        .{ .net = "GND", .layer = "F.Cu", .poly = &poly, .flags = .{ .filled = true, .keepout = true } },
    };
    const reqs = zoneFillReqsFrom(arena, placement.rules, &zones);
    try std.testing.expectEqual(@as(usize, 1), reqs.len);
    try std.testing.expectEqual(@as(usize, 0), reqs[0].index);
    try std.testing.expectEqual(@as(?optimizer.Side, .top), reqs[0].side);
    try std.testing.expectEqualStrings("F.Cu", reqs[0].layer_name);

    var aw2: std.Io.Writer.Allocating = .init(arena);
    try pour_json.writeZoneFills(&aw2.writer, arena, placement, .{}, reqs, null);
    const js = aw2.written();
    // One fill (≥1 contour) with the zone index, layer name, top side, and poly.
    try std.testing.expect(std.mem.indexOf(u8, js, "\"zone\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"layer\":\"F.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"side\":\"top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"poly\":[") != null);
}

// spec: Web Server - a filled inner-layer user zone emits a layer-tagged zone_fill with no side and preserves priority through both routing adapters
// spec: Web Server - one custom pour applied to multiple selected layers expands into an independent fill and routing source on every layer
test "multi-layer custom pour expands across outer and inner layers" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A 4-layer board whose In1 is the GND plane (stack index 2), so In2.Cu
    // (stack 3) is a free inner SIGNAL layer at index 2 — the board-a case.
    // A same-net V_3V3A through-hole pad seeds the inner pour.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.9, .thru = true, .drill = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 10, .y = 5, .side = .top },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "V_3V3A", .pins = &pins }};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
        .rules = .{ .plane_nets = &.{"GND"}, .copper_layers = 4, .planes = .{ .declared = &planes } },
    };

    const poly = [_][2]f64{ .{ 7, 2 }, .{ 13, 2 }, .{ 13, 8 }, .{ 7, 8 } };
    const layer_names = [_][]const u8{ "F.Cu", "In2.Cu" };
    const zones = [_]SavedZone{.{ .net = "V_3V3A", .layer = "F.Cu", .layers = &layer_names, .poly = &poly, .flags = .{ .filled = true }, .priority = 5 }};
    const reqs = zoneFillReqsFrom(arena, placement.rules, &zones);
    try std.testing.expectEqual(@as(usize, 2), reqs.len);
    try std.testing.expectEqual(@as(?optimizer.Side, .top), reqs[0].side);
    // The second application is an inner layer: no outer face, signal index 2.
    try std.testing.expectEqual(@as(?optimizer.Side, null), reqs[1].side);
    try std.testing.expectEqual(@as(u8, 2), reqs[1].track_layer);
    try std.testing.expectEqualStrings("In2.Cu", reqs[1].layer_name);

    const existing = existingZonesFrom(arena, placement, &zones);
    const users = userZonesFrom(arena, placement.rules, &zones);
    try std.testing.expectEqual(@as(usize, 2), existing.len);
    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expect(existing[1].layer == 2 and existing[1].priority == 5);
    try std.testing.expect(users[0].layer == 0 and users[1].layer == 2);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try pour_json.writeZoneFills(&aw.writer, arena, placement, .{}, reqs, null);
    const js = aw.written();
    // Both selected layer names are emitted; only the outer application has a
    // `side`, while the inner one is identified by its layer name.
    try std.testing.expect(std.mem.indexOf(u8, js, "\"layer\":\"F.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"layer\":\"In2.Cu\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, js, "\"side\":"));
    try std.testing.expect(std.mem.indexOf(u8, js, "\"poly\":[") != null);
}

// spec: Web Server - The PNG and describe endpoints restore the shown layout's persisted routed copper against the current netlist when no fresh route is requested
test "restoreShownRoutes rebuilds the shown layout's saved copper against the current netlist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");

    // A starred (default) layout carrying two VTUNE tracks + a via — the same
    // persisted copper the /pcb-layout page restores on open (resolveShownView).
    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const tracks = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .w = 0.15, .net = "VTUNE" },
        .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .w = 0.15, .net = "VTUNE" },
    };
    const vias = [_]SavedVia{.{ .x = 2, .y = 0, .d = 0.6, .drill = 0.3, .net = "VTUNE" }};
    const layouts = [_]SavedLayout{.{
        .name = "star",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .default = true,
        .routes = .{ .tracks = &tracks, .vias = &vias },
    }};
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = aw.written() });

    // Restore against the CURRENT netlist: VTUNE resolves to index 0 (the same
    // path solveForRequest → restored.routes takes for a no-route PNG/describe).
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "VTUNE", .pins = &pins }};
    const rr = restoreShownRoutes(alloc, project, "foo", "star", null, &nets) orelse return error.TestNoRoutes;
    try std.testing.expectEqual(@as(usize, 2), rr.tracks.len);
    try std.testing.expectEqual(@as(usize, 1), rr.vias.len);
    try std.testing.expectEqual(@as(i32, 0), rr.tracks[0].net); // VTUNE → net 0
    try std.testing.expectEqual(@as(i32, 0), rr.vias[0].net);
    // A layout name that doesn't exist (or carries no saved routes) restores
    // nothing, so a routeless PNG/describe falls back to drawing no copper.
    try std.testing.expect(restoreShownRoutes(alloc, project, "foo", "nope", null, &nets) == null);
}

// spec: Web Server - Inner-layer copper (l ≥ 2) round-trips the sidecar; legacy entries without an l stay top copper
test "layouts sidecar round-trips inner-layer copper and legacy layer defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const tracks = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .l = 3, .w = 0.3, .net = "SIG" }, // inner signal layer
        .{ .x1 = 3, .y1 = 0, .x2 = 5, .y2 = 0, .l = 0, .w = 0.3, .net = "SIG" }, // top
    };
    const layouts = [_]SavedLayout{.{
        .name = "routed",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .routes = .{ .tracks = &tracks, .vias = &.{} },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sr = got[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(u8, 3), sr.tracks[0].l);
    try std.testing.expectEqual(@as(u8, 0), sr.tracks[1].l);
    // …and the restored router copper carries the same layer indices.
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const restored = restoreRoutes(alloc, sr, &nets) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(u8, 3), restored.tracks[0].layer);

    // A LEGACY sidecar entry with no "l" at all parses as top copper (0) —
    // the meaning every existing sidecar was written with.
    const legacy_json =
        \\{"layouts":[{"name":"old","kind":"manual","ts":1,
        \\"routes":{"tracks":[{"x1":0,"y1":0,"x2":1,"y2":0,"w":0.2,"net":"SIG"},
        \\{"x1":1,"y1":0,"x2":2,"y2":0,"l":1,"w":0.2,"net":"SIG"}],"vias":[]},
        \\"parts":{"U1":{"x":0,"y":0,"rot":0}}}]}
    ;
    const old = parseLayouts(alloc, legacy_json) orelse return error.TestParseFailed;
    const osr = old[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(u8, 0), osr.tracks[0].l);
    try std.testing.expectEqual(@as(u8, 1), osr.tracks[1].l);
}

// spec: Web Server - Stamped module copper keeps its group tag through the sidecar so rigid-group moves carry it
test "layouts sidecar round-trips the copper stamp group tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "buck/U1", .x = 0, .y = 0, .rot = 0 }};
    const tracks = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .w = 0.3, .net = "VOUT", .g = "buck" },
        .{ .x1 = 3, .y1 = 0, .x2 = 5, .y2 = 0, .w = 0.3, .net = "VOUT" },
    };
    const vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "GND", .g = "buck" }};
    const zone_poly = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const zones = [_]SavedZone{.{ .net = "VOUT", .layer = board_layers.f_cu, .poly = &zone_poly, .flags = .{ .filled = true }, .g = "buck" }};
    const layouts = [_]SavedLayout{.{
        .name = "routed",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .routes = .{ .tracks = &tracks, .vias = &vias, .zones = &zones },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sr = got[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqualStrings("buck", sr.tracks[0].g);
    try std.testing.expectEqualStrings("", sr.tracks[1].g);
    try std.testing.expectEqualStrings("buck", sr.vias[0].g);
    try std.testing.expectEqualStrings("buck", sr.zones[0].g);
}

// spec: Web Server - An RF fence via keeps the name of the net it flanks through the sidecar and the page blob, stitching ground while belonging to that trace
test "layouts sidecar and page blob round-trip the RF via-fence provenance tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    // A fence via stitches GND but belongs to RF1_BPF; an ordinary GND stitching
    // via beside it carries no tag and must stay untagged.
    const vias = [_]SavedVia{
        .{ .x = 1, .y = 0.6, .d = 0.4, .drill = 0.2, .net = "GND", .f = "RF1_BPF" },
        .{ .x = 4, .y = 0, .d = 0.4, .drill = 0.2, .net = "GND" },
    };
    const layouts = [_]SavedLayout{.{
        .name = "routed",
        .kind = kind_manual,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .routes = .{ .tracks = &.{}, .vias = &vias },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    // The tag is omitted entirely for untagged copper, so untagged boards never churn.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, aw.written(), "\"f\":"));
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sr = got[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqualStrings("RF1_BPF", sr.vias[0].f);
    try std.testing.expectEqualStrings("GND", sr.vias[0].net);
    try std.testing.expectEqualStrings("", sr.vias[1].f);

    // …and it survives into the page/API blob the viewer reads, recovered
    // positionally from the source entry exactly as `g` is.
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &.{} }};
    const rr = restoreRoutes(alloc, sr, &nets) orelse return error.TestParseFailed;
    var blob: std.Io.Writer.Allocating = .init(alloc);
    try pcb_layout_blob.writeRoutedArrays(&blob.writer, rr, &.{}, .{ .nets = &nets }, sr, null);
    try std.testing.expect(std.mem.indexOf(u8, blob.written(), "\"f\":\"RF1_BPF\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, blob.written(), "\"f\":"));
}

// The page seam separately proves the imported-zone contract survives saved-route JSON and reaches the PCB blob.
test "saved routes preserve KiCad zones and legacy routes stay compatible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\{"tracks":[],"vias":[],"zones":[
        \\ {"net":"GND","layer":"In1.Cu","poly":[[0,0],[8,0],[8,6]],"filled":true,"keepout":false},
        \\ {"net":"","layer":"F.Cu","poly":[[1,1],[2,1],[2,2]],"filled":false,"keepout":true}]}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{});
    const sr = parseSavedRoutes(alloc, parsed) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), sr.zones.len);
    try std.testing.expectEqualStrings("GND", sr.zones[0].net);
    try std.testing.expectEqualStrings("In1.Cu", sr.zones[0].layer);
    try std.testing.expect(sr.zones[0].flags.filled);
    try std.testing.expect(sr.zones[1].flags.keepout);

    var sidecar: std.Io.Writer.Allocating = .init(alloc);
    try writeSavedRoutesJson(&sidecar.writer, sr);
    try std.testing.expect(std.mem.indexOf(u8, sidecar.written(), "\"zones\":[{\"net\":\"GND\"") != null);

    var blob: std.Io.Writer.Allocating = .init(alloc);
    try pcb_layout_blob.writeRoutedArrays(&blob.writer, null, &.{}, .{}, sr, null);
    try std.testing.expect(std.mem.indexOf(u8, blob.written(), "\"zones\":[{\"net\":\"GND\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob.written(), "\"keepout\":true") != null);

    const old_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"tracks\":[],\"vias\":[{\"x\":1,\"y\":2,\"d\":0.6,\"net\":\"SIG\"}]}",
        .{},
    );
    const old = parseSavedRoutes(alloc, old_json) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 0), old.zones.len);
    try std.testing.expectEqualStrings("", old.vias[0].source);
}

// spec: Web Server - Stamped module copper maps its net names onto the parent design via the origin-key bridge, slug-prefixing private nets
// spec: Web Server - Stamped copper adopts destination net-class geometry
test "stamped copper nets map to parent nets with slug fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Module side: pin (origin U1, pad 2) sits on module net "VOUT".
    const pin_nets = [_]SubPinNet{.{ .net = "VOUT", .origin_key = "U1", .pad = "2" }};
    // Bridge: module origin "U1" is design part "buck/U11".
    var ok_ref = std.StringHashMapUnmanaged([]const u8).empty;
    try ok_ref.put(alloc, "U1", "buck/U11");
    // Parent side: design pad buck/U11.2 is on parent net "5V0".
    var dpin = std.StringHashMapUnmanaged([]const u8).empty;
    try dpin.put(alloc, try std.fmt.allocPrint(alloc, pin_key_fmt, .{ "buck/U11", "2" }), "5V0");

    const tracks = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .w = 0.3, .net = "VOUT", .source = route_source_human },
        .{ .x1 = 0, .y1 = 1, .x2 = 3, .y2 = 1, .w = 0.2, .net = "FB" },
    };
    const vout_poly = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 3 }, .{ 0, 3 } };
    const private_poly = [_][2]f64{ .{ 5, 0 }, .{ 7, 0 }, .{ 7, 2 }, .{ 5, 2 } };
    const keepout_poly = [_][2]f64{ .{ 8, 0 }, .{ 9, 0 }, .{ 9, 1 }, .{ 8, 1 } };
    const zones = [_]SavedZone{
        .{ .net = "VOUT", .layer = board_layers.f_cu, .poly = &vout_poly, .flags = .{ .filled = true }, .priority = 3 },
        .{ .net = "FB", .layer = "In3.Cu", .poly = &private_poly, .flags = .{ .filled = true } },
        .{ .layer = board_layers.b_cu, .poly = &keepout_poly, .flags = .{ .keepout = true } },
    };
    const sr = SavedRoutes{ .tracks = &tracks, .vias = &.{}, .zones = &zones };
    const parent_nets = [_]export_kicad.FlatNet{
        .{ .name = "5V0", .pins = &.{} },
        .{ .name = "buck/FB", .pins = &.{} },
    };
    const parent_rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "power" }, .width = 0.55 },
        .{},
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try pcb_layout_seeds.writeSubRoutesJson(&aw.writer, alloc, "buck", sr, .{
        .pin_nets = &pin_nets,
        .ok_ref = &ok_ref,
        .dpin_net = &dpin,
        .parent_nets = &parent_nets,
        .parent_rules = &parent_rules,
    });
    const out = aw.written();
    // Bridged net → the parent's name; unbridged private net → slug-prefixed.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"5V0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"buck/FB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"VOUT\"") == null);
    // Conductive custom zones follow the identical parent-net bridge. A
    // keepout is not a pour and declared plane fills never enter SavedRoutes.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"zones\":[{\"net\":\"5V0\"") != null and std.mem.indexOf(u8, out, "\"net\":\"buck/FB\",\"layer\":\"In3.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"priority\":3") != null and std.mem.indexOf(u8, out, "\"keepout\":true") == null);
}

// spec: Web Server - A saved layout round-trips each part's board side and lock flag through the sidecar
test "layouts sidecar round-trips side and locked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // One bottom-side locked part; one default (top, unlocked) part.
    const parts = [_]PartPose{
        .{ .ref = "U1", .x = 1, .y = 2, .rot = 0, .side = .bottom, .locked = true },
        .{ .ref = "C1", .x = 3, .y = 4, .rot = 90 },
    };
    const layouts = [_]SavedLayout{.{ .name = "two-sided", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const text = aw.written();
    // Non-default fields are spelled out; the default part stays legacy-shaped.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"side\":\"bottom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"locked\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\"side\""));

    const got = parseLayouts(alloc, text) orelse return error.TestParseFailed;
    try std.testing.expectEqual(optimizer.Side.bottom, got[0].parts[0].side);
    try std.testing.expect(got[0].parts[0].locked);
    try std.testing.expectEqual(optimizer.Side.top, got[0].parts[1].side);
    try std.testing.expect(!got[0].parts[1].locked);
}

// spec: Web Server - The viewer Route scope parses a group into an incremental ScopedRoute that retains submitted copper for the unselected nets
test "viewer route scope preserves other-net copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts: [1]optimizer.Part = undefined;
    const fx = pcb_layout_mcp.scopeFixture(&parts); // nets: RFOUT (rf), SIG (signal)

    // Scope the route to the RF group; submit copper for SIG (out of scope) —
    // it must be retained as an obstacle, while RFOUT alone is selected.
    const body = "{\"groups\":\"rf\",\"tracks\":[{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":0,\"w\":0.2,\"net\":\"SIG\"}]}";
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
    const vs = try parseViewerRouteScope(alloc, root, &fx.block, fx.placement);
    try std.testing.expectEqual(@as(usize, 1), vs.selected); // RFOUT
    try std.testing.expect(vs.scoped.selected.len == 2 and vs.scoped.selected[0] and !vs.scoped.selected[1]);
    try std.testing.expectEqual(@as(usize, 1), vs.scoped.existing_tracks.len); // SIG's copper retained
    try std.testing.expectEqual(@as(usize, 0), vs.unknown.len);
}

test "safeFootprintName accepts a 128-char stem but rejects 129" {
    // `fp.len > 128` bounds the name; a `>`->`>=` flip rejects the exact
    // 128-char boundary a valid long footprint stem can hit.
    try std.testing.expect(safeFootprintName(&@as([128]u8, @splat('a'))));
    try std.testing.expect(!safeFootprintName(&@as([129]u8, @splat('a'))));
}

// A KiCad sync seeds a sub-block's missing parts from its module's starred
// layout by bridging module-local `origin_key` to the parent's renumbered
// refs. A module that exists ONLY as a `lib/modules/` defmodule (no same-named
// `src/` design) must still bridge: the earlier source-path resolver evaluated
// the defmodule file to `.nil`, dropped the whole origin_key re-key, and left
// the caller prefix-stripping a module-standalone layout (`C1`…) against the
// parent's renumbered refs (`C2`/`C3`…) that never match — so the sync scattered
// the module's passives instead of placing them at the ★ arrangement.
// spec: serve/subcircuit-route - callers can disable saved module routing; even a timed-out local search cannot copy saved module tracks or vias in that mode
test "loadSubBlockPoses re-keys a module-only defmodule layout onto parent refs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.createDirPath(std.testing.io, "src");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/0402.sexp", .data = "(component 0402 (footprint \"0402.kicad_mod\"))" });

    // Module: two NAMED caps (origin_key = source name). Flattened standalone
    // they renumber C_A→C1, C_B→C2 — the refs its saved layout is keyed by.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/synthx.sexp", .data =
        \\(defmodule synthx ()
        \\  (design-block "SynthX"
        \\    (import cap)
        \\    (instance "C_A" (cap "10nF") (pin 1 "CTRL") (pin 2 "GND"))
        \\    (instance "C_B" (cap "20nF") (pin 1 "CTRL") (pin 2 "GND"))))
    });
    // Starred layout keyed by the STANDALONE refs (C1/C2), origin recorded.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/synthx.layouts.json", .data =
        \\{"default":"hand","layouts":[{"name":"hand","parts":[
        \\ {"ref":"C1","x":1,"y":1,"rot":0,"origin":"C_A"},
        \\ {"ref":"C2","x":2,"y":2,"rot":0,"origin":"C_B"}],
        \\ "routes":{"tracks":[{"x1":1,"y1":1,"x2":2,"y2":2,"l":0,"w":0.2,"net":"CTRL"}],
        \\ "vias":[{"x":1.5,"y":1.5,"d":0.5,"drill":0.2,"net":"CTRL"}]}}]}
    });
    // Design: a top-level cap takes C1, so the sub-block's caps renumber to
    // C2/C3 — DIVERGING from the module-standalone C1/C2 the layout is keyed by,
    // which is exactly what a prefix-strip cannot bridge.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data =
        \\(design-block "Board"
        \\  (hierarchical-ids)
        \\  (import cap synthx)
        \\  (instance "C_PRE" (cap "1uF") (pin 1 "CTRL") (pin 2 "GND"))
        \\  (sub-block "sm" (synthx)))
    });

    const board_path = try std.fmt.allocPrint(alloc, "{s}/src/board.sexp", .{project_dir});
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    const result = try eval.evalFile(board_path);
    try std.testing.expect(result == .design_block);
    const dblock = result.design_block;
    try std.testing.expectEqual(@as(usize, 1), dblock.sub_blocks.len);
    const sm = dblock.sub_blocks[0];

    // The sub-block's own flattened refs (parent-renumbered) → origin_key. This
    // is the one top-level loop the test needs; the pose checks below index the
    // two-part result directly rather than looping again.
    var flat: std.ArrayList(export_kicad.FlatInstance) = .empty;
    try netlist.collectInstances(alloc, sm.block, "", &flat);
    var origin_of = std.StringHashMapUnmanaged([]const u8).empty;
    for (flat.items) |fi| try origin_of.put(alloc, fi.ref_des, fi.origin_key);

    const poses = loadSubBlockPoses(alloc, project_dir, sm) orelse return error.TestNoPoses;
    try std.testing.expectEqual(@as(usize, 2), poses.len);
    // Each returned pose is keyed by a REAL sub-block ref (via the flatten's
    // ref→origin table) — `origin_of.get` returning null would mean
    // loadSubBlockPoses leaked a module-standalone ref (C1/C2) the old
    // prefix-strip path produced. Re-key the two poses by their source-name
    // origin so the ★ x-coordinate can be checked order-independently.
    const o0 = origin_of.get(poses[0].ref) orelse return error.TestRefNotInSubBlock;
    const o1 = origin_of.get(poses[1].ref) orelse return error.TestRefNotInSubBlock;
    var x_of_origin = std.StringHashMapUnmanaged(f64).empty;
    try x_of_origin.put(alloc, o0, poses[0].x);
    try x_of_origin.put(alloc, o1, poses[1].x);
    // Both module caps bridged onto parent refs, each carrying its ★ pose:
    // C_A→x=1, C_B→x=2 (the layout's C1/C2 poses, matched by origin_key).
    try std.testing.expectEqual(@as(f64, 1), x_of_origin.get("C_A") orelse return error.TestMissingCA);
    try std.testing.expectEqual(@as(f64, 2), x_of_origin.get("C_B") orelse return error.TestMissingCB);
    // Divergence sanity: the parent DID renumber the sub-block off C1 (else the
    // bug would be masked by module-standalone refs happening to match). `.get`
    // resolving would prove a leaked standalone ref slipped through.
    try std.testing.expectEqual(@as(?[]const u8, null), origin_of.get("C1"));

    // The autorouter now routes this sub-circuit fresh in isolation. Its route
    // therefore supersedes the starred snapshot's unnecessary midpoint via,
    // while the destination's CTRL net-class geometry remains authoritative.
    var board_flat: std.ArrayList(export_kicad.FlatInstance) = .empty;
    try netlist.collectInstances(alloc, dblock, "", &board_flat);
    var board_nets: std.ArrayList(export_kicad.FlatNet) = .empty;
    try netlist.collectNets(alloc, dblock, "", &board_nets);
    try std.testing.expectEqual(@as(usize, 3), board_flat.items.len);
    try std.testing.expectEqualStrings("C_A", board_flat.items[1].origin_key);
    try std.testing.expectEqualStrings("C_B", board_flat.items[2].origin_key);
    const cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var board_parts = [_]optimizer.Part{
        .{ .ref_des = board_flat.items[0].ref_des, .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &cap_pads, .fallback = false },
        .{ .ref_des = board_flat.items[1].ref_des, .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &cap_pads, .fallback = false, .x = 11, .y = 21 },
        .{ .ref_des = board_flat.items[2].ref_des, .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &cap_pads, .fallback = false, .x = 12, .y = 22 },
    };
    const net_rules = try alloc.alloc(optimizer.NetRule, board_nets.items.len);
    @memset(net_rules, .{});
    const placement = optimizer.Placement{
        .parts = &board_parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = board_flat.items,
        .nets = board_nets.items,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 40,
        .maxy = 40,
        .generated = false,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 6, .net = net_rules },
    };
    const ctrl_i: usize = @intCast(netIndexByName(placement, "sm/CTRL") orelse return error.TestMissingCtrl);
    net_rules[ctrl_i] = .{ .width = 0.55, .via_dia = 0.7, .via_drill = 0.3 };
    const policies = try alloc.alloc(route_policy.NetPolicy, board_nets.items.len);
    @memset(policies, .{});
    policies[ctrl_i].max_vias = 2;
    var options = route_policy.Options{ .net = policies };
    const seed_stats = try pcb_layout_seeds.addSubcircuitRouteSeeds(alloc, project_dir, dblock, placement, placement.rules.design.routeParams(), &options);
    try std.testing.expectEqual(@as(usize, 1), seed_stats.copper.accepted_nets);
    try std.testing.expectEqual(@as(usize, 1), options.existing_tracks.len);
    try std.testing.expectEqual(@as(usize, 0), options.existing_vias.len);
    try std.testing.expectApproxEqAbs(@as(f64, 11), options.existing_tracks[0].x1, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 22), options.existing_tracks[0].y2, 1e-9);
    try std.testing.expectEqual(@as(u8, 0), options.existing_tracks[0].layer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), options.existing_tracks[0].width, 1e-9);
    try std.testing.expectEqual(@as(?u16, 2), options.net[ctrl_i].max_vias);

    // Expire the local phase before search. The default may recover from the
    // valid module snapshot; a synthesis-only run must leave it out entirely.
    var saved_options = route_policy.Options{ .stop = .{ .deadline_ns = 1 } };
    const saved_stats = try addSubcircuitRouteSeeds(alloc, project_dir, dblock, placement, placement.rules.design.routeParams(), &saved_options);
    try std.testing.expect(saved_stats.copper.accepted_tracks > 0);
    var fresh_options = route_policy.Options{ .stop = .{ .deadline_ns = 1 }, .guides = .{ .saved_module_routes = false } };
    const fresh_stats = try addSubcircuitRouteSeeds(alloc, project_dir, dblock, placement, placement.rules.design.routeParams(), &fresh_options);
    try std.testing.expect(!fresh_stats.saved_module_routes);
    try std.testing.expectEqual(@as(usize, 0), fresh_options.existing_tracks.len);
    try std.testing.expectEqual(@as(usize, 0), fresh_options.existing_vias.len);
    try std.testing.expectEqual(@as(usize, 1), fresh_stats.attempts.len);
    try std.testing.expect(fresh_stats.attempts[0].timed_out);
    try std.testing.expectEqual(@as(f64, 0), fresh_stats.attempts[0].timing.signal_ms);
    try std.testing.expectEqual(@as(usize, 1), fresh_stats.attempts[0].primary.total);

    // A board-level tweak makes the one-shot local candidate incomplete and
    // invalidates the stale saved snapshot. The standalone completion retry
    // must still produce fresh, board-rule-width copper for the moved pads.
    board_parts[2].x += 0.5;
    const moved_policies = try alloc.alloc(route_policy.NetPolicy, board_nets.items.len);
    @memset(moved_policies, .{});
    var moved_options = route_policy.Options{ .net = moved_policies };
    const moved = try pcb_layout_seeds.addSubcircuitRouteSeeds(alloc, project_dir, dblock, placement, placement.rules.design.routeParams(), &moved_options);
    try std.testing.expectEqual(@as(usize, 1), moved.copper.accepted_nets);
    try std.testing.expectEqual(@as(usize, 0), moved.copper.rejected_nets);
    try std.testing.expectEqual(@as(usize, 2), moved_options.existing_tracks.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), moved_options.existing_tracks[0].width, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), moved_options.existing_tracks[1].width, 1e-9);
}

// spec: Web Server - The shown layout's copper carries its pour zones, so a rail poured rather than traced counts as connected
test "shownLayoutCopper carries pour zones as connecting copper" {
    // board-a pours V_12V / V_5VA / V_6VA / V_3V3A / V_3V3_LMX instead of
    // tracing them. Dropping zones here (the old behaviour) made every pad on
    // such a rail read as its own island — 8-10 phantom "isolated islands" per
    // rail and five nets reported unrouted on a board where they are poured.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");
    // One saved layout with a filled B.Cu rail, a native arc, and exact RF
    // swept-path evidence — every physical form must reach readiness intact.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/z.layouts.json", .data =
        \\{"default":"layout","layouts":[{"name":"layout","default":true,"parts":[{"ref":"U1","x":1,"y":1,"rot":0}],
        \\"routes":{"tracks":[{"x1":1,"y1":1,"x2":5,"y2":1,"xm":3,"ym":3,"l":0,"w":0.2,"net":"RAIL"}],"vias":[],
        \\"rf_paths":[{"net":"RAIL","l":0,"samples":[[1,1,0.1],[5,1,0.3]]}],
        \\"zones":[{"net":"RAIL","layer":"B.Cu","filled":true,"keepout":false,"priority":1,"poly":[[0,0],[10,0],[10,10],[0,10]]}]}}]}
    });

    const rules = optimizer.BoardRules{ .plane_nets = &.{}, .copper_layers = 2 };
    const nets = [_]export_kicad.FlatNet{.{ .name = "RAIL", .pins = &.{} }};
    var placement = pcb_layout_mcp.addTracksFixture(&.{}, &nets, &.{});
    placement.rules = rules;
    const shown = shownLayoutCopper(alloc, project, "z", .{}, placement);
    try std.testing.expect(shown.from_saved);
    // The pour must survive into the copper the connectivity oracle sees.
    try std.testing.expectEqual(@as(usize, 1), shown.zones.len);
    try std.testing.expectEqualStrings("RAIL", shown.zones[0].net);
    try std.testing.expectEqual(@as(u8, 1), shown.zones[0].layer); // B.Cu
    try std.testing.expectEqual(@as(usize, 1), shown.arcs.len);
    try std.testing.expectEqual(@as(usize, 1), shown.rf_paths.len);
    try std.testing.expectEqual(@as(usize, 2), shown.rf_paths[0].physical.samples.len);
}

// ── Progress-ladder copper seam ──────────────────────────────────────────────

/// The persisted routed copper of the layout the describe/PNG views show, plus
/// whether that layout is a saved snapshot. Read by the completion-progress
/// ladder (`pcb_progress.assemble`) so its net-connectivity / fab-readiness
/// verdicts describe the SAME board the facts describe.
pub const ShownCopper = struct {
    tracks: []const router.Track = &.{},
    arcs: []const router.Arc = &.{},
    rf_paths: []const rf_port_report.Outcome = &.{},
    vias: []const router.Via = &.{},
    /// True when a saved snapshot supplied the shown placement (named ?layout=
    /// or the ★ default); false when it fell back to the auto cache / grid
    /// (which persist no copper) — surfaced as the fab gate's cache-layout
    /// warning and the fab-ready rung's "save the layout" nudge.
    from_saved: bool = false,
    /// The layout's user copper pours. Connecting copper for any rail that is
    /// poured rather than traced, so connectivity/fab-readiness must include
    /// them or every pad on such a rail reads as an isolated island.
    zones: []const pour.UserZone = &.{},
};

/// The copper + saved-ness of the layout `solveForRequest` would have shown for
/// `(name, opts)`: the named `?layout=`, else the ★ starred default; an auto
/// cache / grid / fresh-solve / sub-scoped view returns empty copper +
/// `from_saved=false` (matching `solveForRequest`'s own "placement came verbatim
/// from a saved snapshot" condition, so the copper always fits the shown poses).
pub fn shownLayoutCopper(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: PngRequest,
    placement: optimizer.Placement,
) ShownCopper {
    // Sub-scoped views always fresh-solve (`solveForRequest` forces cached=null
    // when opts.sub is set), so no saved copper fits them.
    if (opts.sub != null) return .{};
    const shown = shownSavedLayout(readLayouts(alloc, project_dir, name), opts) orelse return .{};
    var out = ShownCopper{ .from_saved = true };
    if (shown.routes) |sr| {
        const current = routesWithPerimeter(alloc, placement, sr) orelse sr;
        if (restoreRoutes(alloc, current, placement.nets)) |r| {
            out.tracks = r.tracks;
            out.arcs = r.arcs;
            out.vias = r.vias;
            out.rf_paths = r.rf_port_outcomes;
        }
        // Pour zones are CONNECTING COPPER, not decoration: a rail poured
        // instead of traced (board-a's V_12V/V_5VA/V_6VA/V_3V3A/V_3V3_LMX)
        // is joined by its zone and by nothing else. Omitting them here made
        // every pad on such a rail read as its own isolated island — the
        // connectivity pass must see the same copper the Gerber emits.
        out.zones = userZonesFrom(alloc, placement.rules, sr.zones);
    }
    return out;
}

/// The saved layout `solveForRequest` renders VERBATIM for `opts`: the named
/// `?layout=` (must carry parts), else — only on the plain default view (no
/// regen/rough/remaining) — the ★ default. Null when the placement is a fresh
/// solve / cache / grid, which have no matching persisted copper.
fn shownSavedLayout(layouts: []const SavedLayout, opts: PngRequest) ?*const SavedLayout {
    if (opts.layout) |want| {
        for (layouts) |*L| {
            if (std.mem.eql(u8, L.name, want) and L.parts.len > 0) return L;
        }
        return null;
    }
    if (opts.regen or opts.rough or opts.remaining) return null;
    for (layouts) |*L| {
        if (L.default and L.parts.len > 0) return L;
    }
    return null;
}

test "shownSavedLayout prefers the named layout, then the starred default" {
    const one = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{
        .{ .name = "best", .kind = kind_manual, .ts = 0, .score = null, .parts = &one, .default = true },
        .{ .name = "wip", .kind = kind_manual, .ts = 0, .score = null, .parts = &one, .default = false },
    };
    // Default view → the ★ default.
    try std.testing.expectEqualStrings("best", shownSavedLayout(&layouts, .{}).?.name);
    // Named → that layout, even if not starred.
    try std.testing.expectEqualStrings("wip", shownSavedLayout(&layouts, .{ .layout = "wip" }).?.name);
    // A fresh-solve view (regen) has no matching saved copper.
    try std.testing.expect(shownSavedLayout(&layouts, .{ .regen = true }) == null);
    // A missing named layout resolves to nothing (not a silent fallback to ★).
    try std.testing.expect(shownSavedLayout(&layouts, .{ .layout = "nope" }) == null);
}

/// Build a `.layouts.json` body carrying one layout with `n` tracks — enough
/// copper to push a realistic routed board past the old 1 MiB read cap. Kept
/// out of the test body so the test itself stays branch- and loop-free.
fn tBigSidecar(alloc: std.mem.Allocator, n: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"default\":\"big\",\"layouts\":[{\"name\":\"big\",\"kind\":\"manual\",\"ts\":1,\"routes\":{\"tracks\":[");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try w.writeAll(",");
        const f: f64 = @floatFromInt(i);
        try w.print(
            "{{\"x1\":{d},\"y1\":0.125,\"x2\":{d},\"y2\":0.375,\"l\":0,\"w\":0.2,\"net\":\"GND_LONG_NET_NAME\"}}",
            .{ f, f + 1 },
        );
    }
    try w.writeAll("],\"vias\":[],\"zones\":[]},\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":1,\"rot\":0}]}]}");
    return aw.written();
}

// spec: Web Server - A layout sidecar past a megabyte still reads back in full, and one that cannot be read or parsed is reported instead of passing as no layouts
test "an oversized layout sidecar still reads back and a corrupt one reads as none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");

    // A board with several routed candidates runs past a megabyte. The old cap
    // truncated exactly this to ZERO layouts — silently taking the viewer, the
    // KiCad sync seed and the fab outputs with it.
    const body = try tBigSidecar(alloc, 14000);
    try std.testing.expect(body.len > 1 << 20);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/big.layouts.json", .data = body });

    const got = readLayouts(alloc, project, "big");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("big", got[0].name);
    try std.testing.expect(got[0].default);
    try std.testing.expectEqual(@as(usize, 14000), got[0].routes.?.tracks.len);

    // A body that is not JSON still reads as no layouts (the caller cannot use
    // it), but takes the warned path rather than the silent one.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/bad.layouts.json", .data = "{ not json" });
    try std.testing.expectEqual(@as(usize, 0), readLayouts(alloc, project, "bad").len);
}

// spec: Web Server - The page blob inlines copper for the layout it shows and marks the other routed rows as server-side, so page weight does not grow with the candidates kept
test "the blob inlines copper only for the shown layout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 1, .y = 1, .rot = 0 }};
    const tracks = [_]SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .l = 0, .w = 0.25, .net = "GND" }};
    const routes = SavedRoutes{ .tracks = &tracks, .vias = &.{}, .zones = &.{} };
    const rows = [_]SavedLayout{
        .{ .name = "shown", .kind = kind_manual, .ts = 2, .score = null, .parts = &parts, .routes = routes, .default = true },
        .{ .name = "other", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts, .routes = routes },
        .{ .name = "poses-only", .kind = kind_manual, .ts = 0, .score = null, .parts = &parts },
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try pcb_layout_blob.writeLayoutsJson(&aw.writer, &rows, "shown");
    const js = aw.written();

    // The shown row carries its real copper …
    const at_shown = std.mem.indexOf(u8, js, "\"shown\"") orelse return error.TestShownMissing;
    const at_other = std.mem.indexOf(u8, js, "\"other\"") orelse return error.TestOtherMissing;
    try std.testing.expect(std.mem.indexOf(u8, js[at_shown..at_other], "\"tracks\":[{") != null);
    // The compact saved-version navigator can label the starred row without
    // parsing the server-rendered management list.
    try std.testing.expect(std.mem.indexOf(u8, js[at_shown..at_other], "\"default\":true") != null);
    // … while the second routed row is marked server-side, so the client knows
    // to follow its permalink instead of restoring copper it was never sent.
    try std.testing.expect(std.mem.indexOf(u8, js[at_other..], "\"routes\":null") != null);
    // Exactly one row's copper is inlined, however many routed rows exist.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, js, "\"tracks\":[{"));
    // A row with no copper at all still omits the field, so a pose-only layout
    // keeps loading in place with no round-trip.
    const at_poses = std.mem.indexOf(u8, js, "\"poses-only\"") orelse return error.TestPosesMissing;
    try std.testing.expect(std.mem.indexOf(u8, js[at_poses..], "\"routes\"") == null);
}

/// A bare flat block of caps for the re-key tests: `refs[i]` with origin
/// `origins[i]`, nothing else — enough for `collectInstances` to list them.
fn tCapBlock(alloc: std.mem.Allocator, refs: []const []const u8, origins: []const []const u8) !env_mod.DesignBlock {
    const insts = try alloc.alloc(env_mod.Instance, refs.len);
    for (insts, refs, origins) |*inst, ref, origin| inst.* = .{
        .ref_des = ref,
        .origin_key = origin,
        .id = "00000000",
        .component = "cap",
        .value = "100nF",
        .footprint = "0402",
        .symbol = "Device:C",
    };
    return .{ .name = "t", .instances = insts, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
}

// spec: Web Server - A saved pose whose part was deleted is dropped when a renumbered live part inherited its ref, so the genuine pose is not shadowed by a stale one
test "re-keying drops the stale pose of a deleted part whose ref a renumbered part inherited" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // board-e, 2026-09-02: the layout was saved with C16 = C_SNS12 parked
    // off-board and C20 = C_HPF1_IN placed on the board. Removing C_SNS12 (and
    // eleven others) renumbered C_HPF1_IN to C16.
    var block = try tCapBlock(alloc, &.{ "C16", "R7" }, &.{ "C_HPF1_IN", "R_KEPT" });
    const saved = [_]PartPose{
        .{ .ref = "C16", .origin = "C_SNS12", .x = 69.7, .y = 6.2, .rot = 0 },
        .{ .ref = "C20", .origin = "C_HPF1_IN", .x = 10, .y = 12, .rot = 90 },
        .{ .ref = "R7", .origin = "R_KEPT", .x = 3, .y = 4, .rot = 0 },
        // A deleted part whose ref nobody inherited is not a collision; it
        // passes through as before and the caller simply cannot place it.
        .{ .ref = "R99", .origin = "R_GONE", .x = 70, .y = 8, .rot = 0 },
    };
    const poses = rekeyPosesByOrigin(alloc, &block, &saved) orelse return error.TestRekeyFailed;
    try std.testing.expectEqual(@as(usize, 3), poses.len);
    // Exactly one pose answers to C16, and it is C_HPF1_IN's on-board one —
    // the parked C_SNS12 pose did not win by emission order.
    var c16: usize = 0;
    for (poses) |p| {
        if (!std.mem.eql(u8, p.ref, "C16")) continue;
        c16 += 1;
        try std.testing.expectEqual(@as(f64, 10), p.x);
        try std.testing.expectEqual(@as(f64, 12), p.y);
        try std.testing.expectEqual(@as(f64, 90), p.rot);
    }
    try std.testing.expectEqual(@as(usize, 1), c16);
    try std.testing.expectEqualStrings("R7", poses[1].ref);
    try std.testing.expectEqualStrings("R99", poses[2].ref);
}

// spec: Web Server - The page blob's re-keyed rows drop a stale shadowing pose and its dimension, so the client's ref-keyed Load cannot pick the wrong one
test "blob rows drop the stale shadowing pose and the dimension anchored on it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const live = [_]LiveRef{.{ .ref = "C16", .origin = "C_HPF1_IN" }};
    const row_parts = [_]PartPose{
        .{ .ref = "C16", .origin = "C_SNS12", .x = 69.7, .y = 6.2, .rot = 0 },
        .{ .ref = "C20", .origin = "C_HPF1_IN", .x = 10, .y = 12, .rot = 90 },
    };
    const dimensions = [_]SavedPartEdgeDimension{
        .{ .ref = "C16", .axis = "x", .edge_id = 7, .offset = 2 },
        .{ .ref = "C20", .axis = "y", .edge_id = 8, .offset = 3 },
    };
    const rows = [_]SavedLayout{
        .{ .name = "hand", .kind = kind_manual, .ts = 1, .score = null, .parts = &row_parts, .dimensions = &dimensions },
    };
    const out = rekeyRowsToLive(alloc, &rows, &live);
    // The client keys `parts` by ref: one C16, and it is the on-board pose.
    try std.testing.expectEqual(@as(usize, 1), out[0].parts.len);
    try std.testing.expectEqualStrings("C16", out[0].parts[0].ref);
    try std.testing.expectEqual(@as(f64, 10), out[0].parts[0].x);
    // The stale C16 dimension went with its pose; C20's followed it to C16.
    try std.testing.expectEqual(@as(usize, 1), out[0].dimensions.len);
    try std.testing.expectEqualStrings("C16", out[0].dimensions[0].ref);
    try std.testing.expectEqual(@as(u32, 8), @as(u32, @intCast(out[0].dimensions[0].edge_id)));
}

// spec: Web Server - The page blob's saved-layout rows are re-keyed onto the shown flatten, so a client Load applies poses by exact ref
test "blob rows re-key onto live refs and the client Load matches by exact ref" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const live = [_]LiveRef{
        .{ .ref = "amp1/U7", .origin = "U1" },
        .{ .ref = "amp2/U9", .origin = "U1" },
    };
    const row_parts = [_]PartPose{
        .{ .ref = "amp1/U5", .origin = "U1", .x = 1, .y = 2, .rot = 0 },
        .{ .ref = "amp2/U6", .origin = "U1", .x = 3, .y = 4, .rot = 0 },
    };
    const dimensions = [_]SavedPartEdgeDimension{
        .{ .ref = "amp1/U5", .axis = "x", .edge_id = 7, .offset = 2 },
        .{ .ref = "amp2/U6", .axis = "y", .edge_id = 8, .offset = 3 },
    };
    const rows = [_]SavedLayout{
        .{ .name = "hand", .kind = kind_manual, .ts = 1, .score = null, .parts = &row_parts, .dimensions = &dimensions },
    };
    const out = rekeyRowsToLive(alloc, &rows, &live);
    try std.testing.expectEqualStrings("amp1/U7", out[0].parts[0].ref);
    try std.testing.expectEqualStrings("amp2/U9", out[0].parts[1].ref);
    try std.testing.expectEqualStrings("amp1/U7", out[0].dimensions[0].ref);
    try std.testing.expectEqualStrings("amp2/U9", out[0].dimensions[1].ref);
    // …and the client builds NO origin map of its own any more: Load is an
    // exact-ref lookup over these server-rekeyed rows.
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "byOrigin") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var s=L.parts[p.ref]") != null);
}

// spec: Web Server - Merging duplicate layout rows keeps the starred row's name, so the ★ permalink still reproduces its board
test "dedup keeps the starred auto row's identity when merging equal scores" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const score = LayoutScore{ .hpwl = 10, .loop = 5, .caps = 2, .objective = 40 };
    const rows = [_]SavedLayout{
        .{ .name = "auto · Jul 29 08:00:00", .kind = kind_auto, .ts = 1, .score = score, .parts = &.{} },
        .{ .name = "auto · Jul 29 09:04:59", .kind = kind_auto, .ts = 2, .score = score, .parts = &.{}, .default = true },
    };
    const out = dedupLayouts(alloc, &rows);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    // The ★ row's NAME survives the merge — its permalink still answers.
    try std.testing.expectEqualStrings("auto · Jul 29 09:04:59", out[0].name);
    try std.testing.expect(out[0].default);
}

// spec: Web Server - A ?refine= re-solve is never adopted as the page's edit target, so the idle autosave cannot overwrite the named row with solver output
test "refine renders are not adopted as the autosave target" {
    try std.testing.expect(adoptedLayoutName(.{ .refine = "hand" }, null) == null);
    // Even with a starred default present: under ?refine= what renders is the
    // SOLVER's output, so nothing may be adopted for write-back.
    try std.testing.expect(adoptedLayoutName(.{ .refine = "hand" }, "star") == null);
    try std.testing.expectEqualStrings("hand", adoptedLayoutName(.{ .view = "hand" }, "star") orelse return error.TestNoAdopt);
    try std.testing.expectEqualStrings("star", adoptedLayoutName(.{}, "star") orelse return error.TestNoAdopt);
}

// spec: Web Server - The viewer's idle autosave pauses while unplaced parts remain, lifting when they are placed or explicitly saved
test "the idle autosave gates on unplaced parts" {
    const js = @embedFile("assets/pcb_board.js");
    // Both the scheduler and the fire path check the gate…
    try std.testing.expect(std.mem.indexOf(u8, js, "if(anyUnplaced()){var m=document.getElementById(\"pcb-savemsg\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!pcbDirty||autosaveQueued||anyUnplaced())return;") != null);
    // …the unload-flush skips rather than writes…
    try std.testing.expect(std.mem.indexOf(u8, js, "if(pcbDirty){if(anyUnplaced())return Promise.resolve(\"skipped\");") != null);
    // …and an explicit Save/Update accepts the staging and lifts the gate.
    try std.testing.expect(std.mem.indexOf(u8, js, "markUnplaced([]);") != null);
}

// spec: Web Server - The board PNG query turns ?thermal=1 into a heat-zone request carrying its scenario and ambient, and an unknown scenario word falls back to still air rather than refusing the image
test "the pcb PNG query parses the heat-zone request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Absent ⇒ the ordinary copper image, with nothing thermal decided for it.
    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    const copper = pngRequestFromQuery(arena, plain.req);
    try std.testing.expect(!copper.thermal.on);
    try std.testing.expect(copper.thermal.scenario == null);
    try std.testing.expect(copper.thermal.ambient_c == null);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.query("thermal", "1");
    ht.query("scenario", "airflow_2ms");
    ht.query("ambient", "70");
    ht.query("width", "800");
    const heat = pngRequestFromQuery(arena, ht.req);
    try std.testing.expect(heat.thermal.on);
    try std.testing.expectEqual(thermal_scenarios.Scenario.airflow_2ms, heat.thermal.scenario.?);
    try std.testing.expectEqual(@as(f64, 70), heat.thermal.ambient_c.?);
    // The framing parameters still apply — a heat image is the same board.
    try std.testing.expectEqual(@as(u32, 800), heat.width);

    // Every scenario word the renderer accepts round-trips through the one
    // parser both the query and the CLI tool use.
    inline for (@typeInfo(thermal_scenarios.Scenario).@"enum".field_names) |word| {
        try std.testing.expectEqual(@field(thermal_scenarios.Scenario, word), parseScenario(word).?);
    }
    // A typo is not a reason to refuse an image; it falls back to still air.
    try std.testing.expect(parseScenario("breeze") == null);
    try std.testing.expect(parseScenario(null) == null);
}

// spec: Web Server - The route-body effort parser accepts both one-shot spellings and standard, while leaving each API surface to choose its missing-field default
test "the route body's effort field overrides the tier for that run only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const parse = struct {
        fn go(a: std.mem.Allocator, body: []const u8) ?route_policy.Effort {
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return null;
            return route_resume.effort(v, null);
        }
    }.go;
    // Both spellings of the cheap tier — the viewer sends the enum's own, the
    // DSL-literate caller may send the hyphenated one.
    try std.testing.expectEqual(route_policy.Effort.one_shot, parse(alloc, "{\"effort\":\"one_shot\"}") orelse return error.TestNoEffort);
    try std.testing.expectEqual(route_policy.Effort.one_shot, parse(alloc, "{\"effort\":\"one-shot\"}") orelse return error.TestNoEffort);
    try std.testing.expectEqual(route_policy.Effort.standard, parse(alloc, "{\"effort\":\"standard\"}") orelse return error.TestNoEffort);
    // Absent, wrong type, or not a tier: null, i.e. keep the authored effort.
    // A preview must never FAIL over a spelling — it just routes as the plan
    // says, which is what every client written before the field does.
    try std.testing.expect(parse(alloc, "{\"parts\":[]}") == null);
    try std.testing.expect(parse(alloc, "{\"effort\":1}") == null);
    try std.testing.expect(parse(alloc, "{\"effort\":null}") == null);
    try std.testing.expect(parse(alloc, "{\"effort\":\"turbo\"}") == null);
    // A non-object body (the parts check rejects it upstream) is not a crash.
    try std.testing.expect(route_resume.effort(.{ .string = "one_shot" }, null) == null);
}

// spec: Web Server - Route board is bounded on the server even for an already-open legacy page that omits effort, while an explicit API standard tier wins over that default
test "the viewer route default is one-shot and explicit standard still wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"parts\":[]}", .{});
    const deep = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"parts\":[],\"effort\":\"standard\"}", .{});

    try std.testing.expectEqual(
        route_policy.Effort.one_shot,
        route_resume.effort(missing, .one_shot) orelse return error.TestNoEffort,
    );
    try std.testing.expectEqual(
        route_policy.Effort.standard,
        route_resume.effort(deep, .one_shot) orelse return error.TestNoEffort,
    );
    // Non-viewer consumers opt out of the fallback and preserve authored
    // policy exactly as before.
    try std.testing.expect(route_resume.effort(missing, null) == null);
}

// spec: Web Server - One lowering builds the route options for a prepared body, so the blocking and live halves route it at the same scope and effort
test "prepared route options carry the body's scope, copper and effort together" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts = [_]optimizer.Part{};
    const placement = optimizer.Placement{
        .parts = &parts,
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
    const mask = [_]bool{ true, false };
    var prep = RoutePrep{
        .eff_block = &sel_block,
        .placement = placement,
        .rp = .{},
        .scoped = .{ .selected = &mask },
        .user_zones = &.{},
        .echo = .{ .selected = 1 },
    };
    // No override: the authored tier stands. `sel_block` has no (pcb-plan …),
    // so that is the router's own default.
    const plain = preparedRouteOptions(alloc, prep);
    try std.testing.expectEqual(route_policy.Effort.standard, plain.effort);
    // The scope rides the same lowering, so the live and blocking halves cannot
    // route one body at different scopes.
    try std.testing.expectEqual(@as(usize, 2), plain.selected_nets.len);
    try std.testing.expect(plain.selected_nets[0] and !plain.selected_nets[1]);

    prep.steering.effort = .one_shot;
    const cheap = preparedRouteOptions(alloc, prep);
    try std.testing.expectEqual(route_policy.Effort.one_shot, cheap.effort);
    try std.testing.expect(!cheap.effort.retries());
    // The override changes the tier and NOTHING else about the run.
    try std.testing.expectEqual(plain.selected_nets.len, cheap.selected_nets.len);
    try std.testing.expectEqual(plain.net.len, cheap.net.len);
}

// spec: Web Server - The page blob names which rung of the layout ladder the shown board came from, so the viewer can tell a persisted layout from an unsaved solve
test "the page blob carries the shown board's layout source" {
    // Every rung the chip can print is a word the client can test, and the two
    // UNSAVED ones are exactly the states the Route plan action is offered in.
    try std.testing.expectEqualStrings("cache", @tagName(LayoutSource.cache));
    try std.testing.expectEqualStrings("fresh", @tagName(LayoutSource.fresh));
    try std.testing.expectEqualStrings("starred", @tagName(LayoutSource.starred));
    // A `?show=cache` page (a Rough/Regenerate landing) classifies as cache and
    // adopts NO layout, so the plan copper cannot be idle-autosaved anywhere.
    const cached = [_]optimizer.RefPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    try std.testing.expectEqual(LayoutSource.cache, classifyLayoutSource(null, false, false, .{}, null, &cached));
    try std.testing.expect(adoptedLayoutName(.{}, null) == null);
    // The blob writes the tag verbatim (the client compares against these words).
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll(",\"src\":");
    try writeJsonStr(&aw.writer, @tagName(LayoutSource.cache));
    try std.testing.expectEqualStrings(",\"src\":\"cache\"", aw.written());
}

// spec: Web Server - The page blob ships every single-ended controlled-impedance via's solved and minimum plane-antipad diameters, and the viewer's layer panels expose an Antipads overlay that draws both rings and prints the numbers
test "antipads field reports solved vs minimum openings and the viewer wires the overlay" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nets = [_]export_kicad.FlatNet{
        .{ .name = "RF1", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const net_rules = [_]optimizer.NetRule{
        .{ .rf = .{ .impedance = .{ .ohms = 50 } } },
        .{},
    };
    var placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
        .rules = .{ .net = &net_rules, .copper_layers = 4 },
    };
    placement.rules.physical.stack = .{ .layers = 4, .board_mm = 1.6 };
    // One controlled-impedance via and one plain GND via: only the RF via
    // qualifies, carrying a solved opening at or above the clearance floor.
    const vias = [_]router.Via{
        .{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 9, .y = 5, .dia = 0.4, .drill = 0.2, .net = 1 },
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try pcb_layout_blob.writeAntipadsField(&aw.writer, placement, .{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 });
    const js = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, js, "\"net\":\"RF1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"net\":\"GND\"") == null);
    const solved = via_antipad.solve(placement.rules.physical.stack, 50, 0.4, 0.2, placement.rules.clearanceForNet(0, placement.rules.design.clearance)).?;
    var buf: [64]u8 = undefined;
    const anti_frag = try std.fmt.bufPrint(&buf, "\"anti\":{d}", .{solved.antipad_dia_mm});
    try std.testing.expect(std.mem.indexOf(u8, js, anti_frag) != null);
    // No physical stackup → the solver has no answer and the overlay is empty.
    placement.rules.physical.stack = .{};
    var aw2: std.Io.Writer.Allocating = .init(arena);
    try pcb_layout_blob.writeAntipadsField(&aw2.writer, placement, .{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 });
    try std.testing.expectEqualStrings(",\"antipads\":[]", aw2.written());

    // The viewer wires the overlay as ONE Objects row (dock + embed popover
    // render the same builder's rows) and paints it.
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "{key:\"antipads\",name:\"Antipads\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function paintAntipads") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "antipads:0") != null);
}

// spec: Web Server - The Antipads overlay measures each via's achieved plane opening from the drawn fills and flags a starved reference plane in red with the excess printed
test "the antipads overlay flags a starved reference plane in red with its excess" {
    // Client-side geometry: the achieved opening is measured off the SAME fill
    // polygons the viewer draws (PCB.plane_fills / pours / zone_fills), so the
    // wiring is asserted on the asset the page ships.
    const board_js = @embedFile("assets/pcb_board.js");
    // The inner planes are the reference: a plane's own contour/hole geometry
    // answers "how far is the nearest copper", cached per source-array identity.
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function apDistToFill") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function apStarved") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "apNearest(PCB.plane_fills") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function apVerdicts") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "apCache.pf===PCB.plane_fills") != null);
    // The starve threshold: achieved gap over solved by more than half the
    // solved gap (50 µm floor), or a plane whose copper never reached the via.
    try std.testing.expect(std.mem.indexOf(u8, board_js, "tol=Math.max(0.05,0.5*solved)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "var AP_REACH=3.0;") != null);
    // A starved via's solved ring and label go red, and the label carries the
    // worst plane's name and excess in mm.
    try std.testing.expect(std.mem.indexOf(u8, board_js, "\"#ef4444\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function apExcessLabel") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "v.excess.toFixed(3)+\"mm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "if(v)lbl+=apExcessLabel(v);") != null);
}

// spec: serve/thermal - a heat-zone image of a named saved layout shares that layout's cached solve, and any other placement override solves its own field
test "only a nameable board may read the layout-keyed thermal cache" {
    const testing = std.testing;
    // The two boards the cache key can name: the design's default board, and a
    // named saved layout. Both may share a solve with the page and the facts
    // JSON that asked for the same one.
    try testing.expect(selectsCacheableBoard(.{}));
    try testing.expect(selectsCacheableBoard(.{ .layout = "RF-final" }));

    // Every knob that can move a part moves the heat with it, and none of these
    // is in the key, so each one alone must send the request off to solve its
    // own field. Reusing a named entry here would paint temperatures for poses
    // this board does not have — a picture that is wrong in exactly the way it
    // looks right.
    try testing.expect(!selectsCacheableBoard(.{ .sub = "amp1" }));
    try testing.expect(!selectsCacheableBoard(.{ .regen = true }));
    try testing.expect(!selectsCacheableBoard(.{ .rough = true }));
    try testing.expect(!selectsCacheableBoard(.{ .remaining = true }));
    try testing.expect(!selectsCacheableBoard(.{ .zone_pack = true }));
    try testing.expect(!selectsCacheableBoard(.{ .court_overlap = 0.2 }));
    try testing.expect(!selectsCacheableBoard(.{ .route_gap = 0.3 }));
    try testing.expect(!selectsCacheableBoard(.{ .group = .{ .w = 1.5 } }));
    try testing.expect(!selectsCacheableBoard(.{ .group = .{ .zone_w = 1.5 } }));
    try testing.expect(!selectsCacheableBoard(.{ .group = .{ .loop_relief = 1.5 } }));

    // Copper-view parameters do NOT choose a board — the heat-zone image
    // ignores them outright — so they must not push a plain request off the
    // cache and back into a multi-second solve.
    try testing.expect(selectsCacheableBoard(.{ .width = 2400, .pads = true, .sheet = true }));
    try testing.expect(selectsCacheableBoard(.{ .thermal = .{ .on = true, .scenario = .heatsink, .ambient_c = 70 } }));
}

/// Write a sidecar mutated over CLI the way the viewer's Save does: snapshot
/// the previous design-level sidecar into `history/` first (best-effort), then
/// stamp `disk rev + 1` — so an agent's mutation is (a) recoverable and (b)
/// visible to an open editor tab's optimistic-concurrency guard (the tab's now
/// stale rev 409s on its next save instead of silently clobbering). CLI tools
/// are design-level only, so there is no `sub` variant.
///
/// Takes no sidecar lock of its own: its only caller (`mcpPersistWorking`)
/// already holds one across the read this write is modifying, and
/// `infra_fs.Mutex` is not reentrant.
pub fn mcpProtectedWrite(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layouts: []const SavedLayout) sidecar_store.StoreError!void {
    if (layoutsSidecar(alloc, project_dir, name, null, layouts_ext)) |scp| {
        _ = history.snapshotLayouts(alloc, project_dir, name, scp) catch null;
    }
    // Refresh the optimizer-cache poses to the blessed layout so a default CLI
    // read (rough → readAutoPoses, the cache slot — not the starred layout)
    // reflects this write, not the pre-mutation scene (read-after-write bug #2;
    // the solver applies a clean full cache verbatim). Tuning params survive.
    var cache = (try readDesignDoc(alloc, project_dir, name)).cache orelse CacheSlot{ .params = .{}, .parts = null };
    if (blessedLayout(layouts)) |bl| cache.parts = bl.parts;
    try writeLayoutsFile(alloc, project_dir, name, layouts, cache, (try readSidecarDoc(alloc, project_dir, name, null)).rev + 1);
}

/// CLI twin of the HTTP layout-history restore. It snapshots the current
/// sidecar first and advances the optimistic-concurrency revision, so agent
/// recovery is undoable and cannot be silently overwritten by an older tab.
pub fn mcpRestoreLayoutSnapshot(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = pcb_layout_mcp.mcpArgStr(args_val, "name") orelse return pcb_layout_mcp.mcpFail(out, alloc, pcb_layout_mcp.mcp_err_missing_name);
    const id = pcb_layout_mcp.mcpArgStr(args_val, "id") orelse return pcb_layout_mcp.mcpFail(out, alloc, "missing snapshot id");
    const snap_path = history.layoutSnapshotPath(alloc, project_dir, name, id) catch
        return pcb_layout_mcp.mcpFail(out, alloc, "layout snapshot not found");
    const snap_data = infra_fs.cwd().readFileAlloc(alloc, snap_path, sidecar_max_bytes) catch
        return pcb_layout_mcp.mcpFail(out, alloc, "layout snapshot read failed");
    const restored = parseLayouts(alloc, snap_data) orelse
        return pcb_layout_mcp.mcpFail(out, alloc, "layout snapshot is corrupt");
    // Same read-modify-write as the HTTP twin, held the same way.
    const disk_rev = blk: {
        const guard = lockSidecar(name, null);
        defer guard.unlock();
        const rev = (try readSidecarDoc(alloc, project_dir, name, null)).rev;
        if (layoutsSidecar(alloc, project_dir, name, null, layouts_ext)) |sidecar_path| {
            _ = history.snapshotLayouts(alloc, project_dir, name, sidecar_path) catch null;
        }
        try writeLayoutsFile(alloc, project_dir, name, restored, (try readDesignDoc(alloc, project_dir, name)).cache, rev + 1);
        break :blk rev;
    };
    out.clearRetainingCapacity();
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, out);
    defer out.* = aw.toArrayList();
    try aw.writer.print("{{\"ok\":true,\"rev\":{d},\"snapshot\":", .{disk_rev + 1});
    try writeJsonStr(&aw.writer, id);
    try aw.writer.writeAll("}");
    return true;
}

pub const mcpCreateWorking = pcb_layout_mcp.mcpCreateWorking;
