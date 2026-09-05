//! The PCB editor page's data blob: every JSON the browser's board renderer
//! reads, and nothing that decides what is in it.
//!
//! Split out of `pcb_layout_page.zig` — where the page HTML now lives in
//! `pcb_layout_chrome.zig`, this module owns the other half of the response:
//! `writePcbData` (the inline `PCB_DATA` blob a page carries), its `?derived=1`
//! continuation `writePcbDerivedData`, and the field writers under both —
//! parts and pads, tracks and vias, pours, fabrication layers, antipads, net
//! colours/clearances, loops, saved-layout rows and the placement score.
//!
//! Everything here takes a `std.Io.Writer` and already-solved inputs: a
//! `Placement`, an optional `RouteResult`, the resolved `ShownView`. It reads
//! no request and no sidecar; `pcb_layout_page.zig` resolves those and calls in.
//!
//! Two invariants the client depends on: every string goes out through
//! `writeJsonStr` (a `</script>` in a net name has broken this page before),
//! and copper carries the persistent `seg-`/`via-` IDs the editor round-trips.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const board_theme = @import("../board_theme.zig");
const layer_table_json = @import("layer_table_json.zig");
const env_mod = @import("../eval/env.zig");
const na = @import("../eval/net_analysis.zig");
const optimizer = @import("../placement/optimizer.zig");
const impedance = @import("../placement/impedance.zig");
const via_antipad = @import("../placement/via_antipad.zig");
const router = @import("../placement/router.zig");
const drc = @import("../placement/drc.zig");
const drc_json = @import("drc_json.zig");
const pour = @import("../placement/pour.zig");
const pour_json = @import("pour_json.zig");
const pcb_keepout_json = @import("pcb_keepout_json.zig");
const pcb_rules_json = @import("pcb_rules_json.zig");
const pcb_part_json = @import("pcb_part_json.zig");
const trace_em_json = @import("trace_em_json.zig");
const power_integrity_json = @import("../power_integrity_json.zig");
const shape_sketch_json = @import("shape_sketch_json.zig");
const stuck_json = @import("stuck_json.zig");
const route_result_stats = @import("route_result_stats.zig");
const export_kicad = @import("../export_kicad.zig");
const export_fab = @import("../export_fab.zig");
const fab_identity = @import("../fab_identity.zig");
const font5x7 = @import("../font5x7.zig");
const net_names = @import("../net_name.zig");
const numeric = @import("../numeric.zig");
const escape = @import("../escape.zig");
const build_id = @import("../build_id.zig");
const sidecar_json = @import("layout_sidecar_json.zig");
const sidecar_types = @import("../layout_sidecar_types.zig");
const saved_zone = @import("saved_zone.zig");
const copper_ids = @import("copper_ids.zig");
const page = @import("pcb_layout_page.zig");
const drc_rules = @import("drc_rules.zig");
const geometry = @import("../placement/geometry.zig");
const perimeter_fence = @import("../placement/perimeter_fence.zig");
const export_kicad_footprint = @import("../export_kicad_footprint.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const shape_sketch = @import("../shape_sketch.zig");
const export_gerber = @import("../export_gerber.zig");
const via_fence = @import("../placement/via_fence.zig");
const route_score = @import("../placement/route_score.zig");
const module_policy = @import("../placement/module_policy.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const pcb_layout_chrome = @import("pcb_layout_chrome.zig");

const HandlerError = page.HandlerError;
const ShownView = page.ShownView;
const LayoutSource = page.LayoutSource;
const SavedLayout = sidecar_types.SavedLayout;
const SavedTrack = sidecar_types.SavedTrack;
const SavedVia = sidecar_types.SavedVia;
const SavedZone = sidecar_types.SavedZone;
const SavedRoutes = sidecar_types.SavedRoutes;
const SavedFabricationLayer = sidecar_types.SavedFabricationLayer;
const SavedPartEdgeDimension = sidecar_types.SavedPartEdgeDimension;
const LayoutScore = sidecar_types.LayoutScore;
const writeJsonStr = sidecar_json.writeJsonStr;
const jsonNum = sidecar_json.jsonNum;
const writeEscaped = escape.writeXml;
const shortName = net_names.leaf;
const netKey = na.baseNetName;
const SavedOutline = sidecar_types.SavedOutline;
const userZonesFrom = saved_zone.userZones;
const routeArcOwnsTrack = @import("../saved_route_copper.zig").arcOwnsTrack;
const View = page.View;
const name_open = page.name_open;
const net_json_key = page.net_json_key;
const shownZones = page.shownZones;
const writeUrlEncoded = page.writeUrlEncoded;
const parts_open = page.parts_open;
const SavedHeatsink = sidecar_types.SavedHeatsink;
const zoneFillReqsFrom = saved_zone.fillRequests;
const rekeyRowsToPlacement = page.rekeyRowsToPlacement;
const writeSavedZonesJson = sidecar_json.writeSavedZonesJson;
const writeSavedRoutesJson = sidecar_json.writeSavedRoutesJson;
const view_margin_mm = render_pcb_png.view_margin_mm;
const origin_open = page.origin_open;
const outline_open = page.outline_open;
const SavedFan = sidecar_types.SavedFan;
const silkKeepoutsFrom = page.silkKeepoutsFrom;
const writeOptionalBoardTextJson = sidecar_json.writeOptionalBoardTextJson;
const writeSavedRfPathsJson = sidecar_json.writeSavedRfPathsJson;
const writeSavedOutlineJson = sidecar_json.writeSavedOutlineJson;
const fabrication_layers_open = page.fabrication_layers_open;
const worldPad = page.worldPad;
const writeFreshRfPathsJson = page.writeFreshRfPathsJson;
const writeSavedHeatsinkJson = sidecar_json.writeSavedHeatsinkJson;
const writeSavedFanJson = sidecar_json.writeSavedFanJson;
const writePartEdgeDimensionsJson = sidecar_json.writePartEdgeDimensionsJson;
const texts_open = page.texts_open;
const writeSavedTextsJson = sidecar_json.writeSavedTextsJson;
const writeOptionalSavedFanJson = page.writeOptionalSavedFanJson;

/// Shared JSON fragments for copper serialization — the sidecar, the page
/// blob, and the Stamp subroutes all write the identical track/via shape.
pub const track_json_fmt = "{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d},\"net\":";

/// One outline-polygon vertex as a JSON `[x,y]` pair (sidecar + page blob).
pub const pt_pair_fmt = "[{d},{d}]";

pub const via_json_fmt = "{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":";

pub const vias_arr_open = "],\"vias\":[";

const net_object_open = "{\"net\":";

pub const segment_id_prefix = "seg-";

pub const via_id_prefix = "via-";

pub const writeTrackSegmentId = sidecar_json.writeTrackSegmentId;

pub const writeViaId = sidecar_json.writeViaId;

/// Summary of a routed board for the JSON API (`?route=1`): total copper length,
/// track/via counts, DRC-violation count, net-completion counts, and the names
/// of the nets that failed — the machine-readable comparison key.
pub const RoutedMetrics = struct {
    trace_mm: f64,
    tracks: usize,
    vias: usize,
    drc: usize,
    /// Fab-blocking subset of `drc` — the routing-score term. Counted by
    /// `drc.errorCount`, so warnings AND `net_open` are excluded: completion is
    /// already reported as `routed`/`total`, and charging an open net through
    /// the score's DRC term too made one open net outweigh the completion the
    /// same net is measured by.
    drc_errors: usize = 0,
    routed: usize = 0,
    total: usize = 0,
    unrouted: []const []const u8 = &.{},
    /// Bounded rip-up rounds the router ran after its greedy pass (0 = none).
    ripup_rounds: usize = 0,
    /// Per-net routed copper: length (mm) + via count, longest first.
    per_net: []const router.NetRouted = &.{},
};

/// Emit `,"per_net":[{"net":NAME,"mm":M,"vias":V},…]` — the per-net routed
/// copper totals shared by the `?route=1` summary and `/api/pcb-describe`.
pub fn writePerNetJson(w: *std.Io.Writer, per_net: []const router.NetRouted) std.Io.Writer.Error!void {
    try w.writeAll(",\"per_net\":[");
    for (per_net, 0..) |pn, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(net_object_open);
        try writeJsonStr(w, pn.name);
        try w.print(",\"mm\":{d:.1},\"vias\":{d}}}", .{ pn.mm, pn.vias });
    }
    try w.writeAll("]");
}

/// Layout JSON + a `findings` sidecar: each part's normalized objective `blame`
/// (0–1, the render heatmap value) and a `loops` list (per decoupling loop:
/// cap, hub, inductance nH, and power-leg length mm) — the machine-readable twin
/// of the PNG diagnostic overlays, so an agent gets precise numbers, not pixels.
/// `blame` is index-aligned with `p.parts` (empty ⇒ all zero).
pub fn writePlacementJson(w: *std.Io.Writer, p: optimizer.Placement, params: optimizer.Params, name: []const u8, blame: []const f64, routed: ?RoutedMetrics) std.Io.Writer.Error!void {
    const b = p.breakdown;
    var bmax: f64 = 0;
    for (blame) |v| bmax = @max(bmax, v);
    try w.writeAll(name_open);
    try writeJsonStr(w, name);
    try w.print(",\"generated\":{s},", .{if (p.generated) "true" else "false"});
    try w.print("\"params\":{{\"loop_w\":{d},\"w_align\":{d},\"w_congest\":{d},\"cap_w_max\":{d},\"grid\":{s}}},", .{
        params.loop_w,                                   optimizer.effAlignW(params), params.w_congest, params.cap_w_max,
        if (params.grid_courtyards) "true" else "false",
    });
    try w.print("\"score\":{{\"hpwl_mm\":{d},\"loop_mm\":{d},\"loop_caps\":{d}}},", .{ p.score.hpwl_mm, p.score.loop_mm, p.score.loop_caps });
    try w.writeAll("\"breakdown\":");
    try writeBreakdownJson(w, b, params);
    try w.print(",\"bbox\":{{\"minx\":{d},\"miny\":{d},\"maxx\":{d},\"maxy\":{d}}},", .{ p.minx, p.miny, p.maxx, p.maxy });
    try w.writeAll(parts_open);
    for (p.parts, 0..) |pt, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try writeJsonStr(w, pt.ref_des);
        if (i < p.instances.len) {
            try w.writeAll(origin_open);
            try writeJsonStr(w, p.instances[i].origin_key);
        }
        const bl = if (i < blame.len and bmax > 0) blame[i] / bmax else 0;
        try w.print(",\"kind\":\"{s}\",\"x\":{d},\"y\":{d},\"rot\":{d},\"hw\":{d},\"hh\":{d},\"fallback\":{s},\"blame\":{d:.3}", .{
            if (pt.kind == .hub) "hub" else "passive",
            pt.x,
            pt.y,
            pt.rot,
            pt.hw,
            pt.hh,
            if (pt.fallback) "true" else "false",
            bl,
        });
        if (pt.ccx != 0 or pt.ccy != 0) try w.print(",\"ccx\":{d},\"ccy\":{d}", .{ pt.ccx, pt.ccy });
        try pcb_part_json.writePoseSideLocked(w, pt.side, pt.locked);
        try w.writeAll("}");
    }
    try w.writeAll("],\"loops\":[");
    for (p.loops, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        const cap = p.parts[L.cap];
        const hub = p.parts[L.hub];
        const cw = worldPad(cap, L.cap_pwr);
        const hp = worldPad(hub, L.hub_pwr_pin);
        const leg = std.math.hypot(cw[0] - hp[0], cw[1] - hp[1]);
        try w.writeAll("{\"cap\":");
        try writeJsonStr(w, cap.ref_des);
        try w.writeAll(",\"hub\":");
        try writeJsonStr(w, hub.ref_des);
        try w.print(",\"nh\":{d:.3},\"leg_mm\":{d:.3}", .{ optimizer.loopNh(p.parts, L), leg });
        if (L.explicit_pin.len > 0) {
            try w.writeAll(",\"ep\":");
            try writeJsonStr(w, L.explicit_pin);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
    if (routed) |r| {
        try w.print(
            ",\"routed\":{{\"trace_mm\":{d:.1},\"tracks\":{d},\"vias\":{d},\"drc\":{d},\"routed\":{d},\"total\":{d},\"unrouted\":[",
            .{ r.trace_mm, r.tracks, r.vias, r.drc, r.routed, r.total },
        );
        for (r.unrouted, 0..) |name_s, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonStr(w, name_s);
        }
        try w.writeAll("]");
        try w.print(",\"ripup_rounds\":{d}", .{r.ripup_rounds});
        // Deterministic accept/reject scalar (route_score.zig) from these same fields.
        try w.print(",\"score\":{d:.2},\"score_v\":{d}", .{
            route_score.score(.{
                .routed = r.routed,
                .total = r.total,
                .vias = r.vias,
                .trace_mm = r.trace_mm,
                .drc_errors = r.drc_errors,
            }),
            route_score.formula_version,
        });
        try writePerNetJson(w, r.per_net);
        try w.writeAll("}");
    }
    // Report any parts the solve left staged below the board (the `(board …)`
    // edge-dock / force path) and the ones autofill pulled back out. Read straight
    // from the optimizer's per-solve thread-local — set during the `solve` above.
    const pl = optimizer.placementDiag();
    if (pl.unplaced.len > 0 or pl.auto_filled.len > 0) {
        try w.writeAll(",\"placement\":{\"unplaced\":[");
        for (pl.unplaced, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonStr(w, ref);
        }
        try w.writeAll("],\"auto_filled\":[");
        for (pl.auto_filled, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonStr(w, ref);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("}");
}

/// Emit the objective `breakdown` as a JSON object: the raw terms, each term's
/// weighted contribution, and the summed `objective`. Shared by the GET export
/// and the POST score endpoint so both report the same shape.
pub fn writeBreakdownJson(w: *std.Io.Writer, b: optimizer.Breakdown, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.writeByte('{');
    try writeBreakdownFields(w, b, params);
    try w.writeByte('}');
}

/// The breakdown's fields with no enclosing braces, so the score endpoint can
/// splice an extra `"blame"` map into the same object for the live Heatmap.
pub fn writeBreakdownFields(w: *std.Io.Writer, b: optimizer.Breakdown, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.print("\"hpwl\":{d},\"loop_raw\":{d},\"loop_weighted\":{d},\"loop_nh\":{d},\"loop_nh_weighted\":{d},", .{
        b.hpwl, b.loop_raw, b.loop_weighted, b.loop_nh, b.loop_nh_weighted,
    });
    try w.print("\"alignment\":{d},\"footprint\":{d},\"congestion\":{d},", .{ b.alignment, b.footprint, b.congestion });
    try w.print("\"loop_term\":{d},\"alignment_term\":{d},\"congestion_term\":{d},\"objective\":{d}", .{
        params.loop_w * b.loop_nh_weighted, optimizer.effAlignW(params) * b.alignment, params.w_congest * b.congestion, b.objective,
    });
}

const LocalPt = struct { x: f64, y: f64 };

/// Page-mode flags for the embedded `PCB` object: `read_only` drives `PCB.ro`
/// (BOARD_JS skips all edit wiring when set); `embed` is any embedded chrome
/// (read-only preview *or* editable embed) — neither has the 3D toggle; the
/// assembly/debug embed can independently opt into model sprites. `sub` is the
/// `?sub=` slug a sub circuit's save/star POSTs append to target the per-sub
/// layout sidecar.
pub const PcbDataOpts = struct {
    read_only: bool,
    embed: bool,
    /// Resolve STEP metadata for an assembly/debug embed and let the browser
    /// progressively rasterize it; ordinary embeds deliberately leave it off.
    model_sprites: bool = false,
    /// Resolve STEP metadata for an embedded 3D scene without enabling the 2D
    /// model-sprite client. Used by Thermal's on-demand physical setup view.
    model_data: bool = false,
    /// Thermal's exclusive overlay needs board/part geometry, not editor-only
    /// layout history, stamping seeds, source metadata, or fabrication text.
    thermal_overlay: bool = false,
    /// Read-only assembly payload: keep cross-probe and board geometry, omit
    /// editor/analysis fields that have no UI on this surface.
    assembly_review: bool = false,
    /// The first editor response carries editable state only. Pours, DRC,
    /// fabrication identity, mask relief, and electrical analyses are fetched
    /// from the matching dependency-cached derived payload after first paint.
    analysis_deferred: bool = false,
    /// Emit `"ac": null` instead of the PDN impedance sweep, leaving it for the
    /// viewer's own `?pdn=1` fetch. Set on the after-paint payload only: every
    /// other surface either emits its analyses inline or emits none at all.
    pdn_deferred: bool = false,
    /// Emit ONLY that sweep — the `?pdn=1` answer itself.
    pdn_only: bool = false,
    /// Emit a cacheable API URL and fetch exact CAM after the semantic board's
    /// first frame instead of blocking HTML generation on Gerber read-back.
    cam_lazy: bool = false,
    sub: ?[]const u8,
    /// Prebuilt `buildSubSeedsJson` object (the blob writer has no block).
    subseeds_json: []const u8 = "{}",
    /// Which module snapshot each group's seeds came from (`buildSubSeedsJson`).
    subseedinfo_json: []const u8 = "{}",
    /// Sub-block name → module source, for palette name links (`buildSubModulesJson`).
    submodules_json: []const u8 = "{}",
    /// Ref → owning source metadata for surgical passive-footprint edits.
    part_edits_json: []const u8 = "{}",
    /// The blob's "board" rect came from a user-DRAWN layout outline (the ▭
    /// tool), so the viewer treats it as editable (PCB.outline).
    outline_drawn: bool = false,
    /// The render's shared board-edge margin field (see `pour.sharedEdgeField`),
    /// threaded into every pour writer here so the outline walk happens once
    /// for the whole render instead of once per writer. Null seeds per writer.
    base_edge: ?pour.EdgeField = null,
    /// Separate capability for board-sized analysis scratch; production uses
    /// the page allocator so releasing a fill really returns its pages.
    scratch_allocator: ?std.mem.Allocator = null,
    /// Exact shown outline; unlike board_poly, this retains nominal vertices
    /// and their editable fillet radii.
    saved_outline: ?SavedOutline = null,
    /// Native sketches for the shown backing overrides.
    saved_fabrication_layers: []const SavedFabricationLayer = &.{},
    /// Physical heatsink authored on the shown saved layout.
    saved_heatsink: ?SavedHeatsink = null,
    /// Axial fan authored on the shown saved layout.
    saved_fan: ?SavedFan = null,
    /// Footprint-origin dimensions driven from the shown outline sketch.
    saved_dimensions: []const SavedPartEdgeDimension = &.{},
    /// This page is a whole top-level DESIGN (not a module page, not a `?sub`
    /// scoped sub circuit) — the only scope the "Sync from KiCad" board import
    /// makes sense on, since it reads the design's own `.kicad_pcb`.
    top_design: bool = false,
    /// The named saved layout this page is showing (`?layout=` / `?refine=` /
    /// the ★ default), or null when the board came from the cache / a fresh
    /// solve / the grid. The viewer adopts it as the active edit target, so
    /// Update and autosave write back into the layout you opened rather than
    /// minting a new one — and the address bar keeps naming it.
    shown_layout: ?[]const u8 = null,
    /// Which rung of the precedence ladder the shown board came from — the same
    /// classification the scorebar's source chip prints, handed to the client so
    /// it can tell a PERSISTED layout from an unsaved solve. `cache`/`fresh` are
    /// the seed states a Rough/Regenerate run lands in, and the only ones that
    /// offer the "Route plan" action.
    src: LayoutSource = .fresh,
    /// SavedRoutes the shown copper was restored from (ShownView.saved) —
    /// lets writeRoutedArrays re-emit per-segment stamp group tags.
    saved_routes: ?SavedRoutes = null,
    /// Already-lowered user copper zones for request-independent physical
    /// review documents. Ordinary pages retain `saved_routes` as their source
    /// so editing metadata and raw authored boundaries remain available.
    user_zones: ?[]const pour.UserZone = null,
    /// Suppress authored board copper pours from the rendered board (a bare
    /// routing-feasibility view that shows no unrelated poured copper).
    omit_pours: bool = false,
    /// Per-group module copper for Stamp (`buildSubSeedsJson`): the ★ module
    /// snapshot's tracks/vias in module-local coordinates with net names
    /// mapped to this design's nets.
    subroutes_json: []const u8 = "{}",
    /// The design's resolved placement+routing plan (`buildPlanJson`): the
    /// authored `(pcb-plan …)` waves or the synthesized default, with each
    /// wave's member parts/nets spelled by name. Emitted as `PCB.plan` for the
    /// settings drawer's routing-plan section.
    plan_json: []const u8 = "{}",
    /// The shown layout's board-level silkscreen texts (ShownView.texts) —
    /// emitted as `PCB.texts` so the viewer draws + edits them.
    texts: []const font5x7.BoardText = &.{},
    /// The generated fabrication identity, kept separate from `PCB.texts`
    /// until the user adopts it for manual positioning.
    fab_text: ?font5x7.BoardText = null,
    /// The layout sidecar's optimistic-concurrency rev at page-render time
    /// (`readLayoutRev`). Emitted as `PCB.rev`; every Save/Update POST echoes
    /// it back so the server can 409 a stale write from a second window.
    rev: i64 = 0,
};

fn payloadUserZones(alloc: std.mem.Allocator, p: optimizer.Placement, opts: PcbDataOpts) []const pour.UserZone {
    return opts.user_zones orelse userZonesFrom(alloc, p.rules, shownZones(opts.saved_routes));
}

pub fn payloadLayouts(layouts: []const SavedLayout, lean_read_only: bool) []const SavedLayout {
    return if (lean_read_only) &.{} else layouts;
}

/// World position of the GND-plane via covering the pad centred at (`cx`,`cy`),
/// or that pad centre itself when no via is near (big board / no route). The
/// loop overlay drops its GND via here so the previewed via is the DRC-safe one
/// routing will use — never a second via beside it. A via belonging to this pad
/// sits within the fan-out radius; anything past `VIA_MATCH_MM` is a neighbour's.
const via_match_mm: f64 = 3.0;

/// Only run the pass-1 GND-via preview on boards small enough that the page
/// already pays for routed scoring (mirrors the optimizer's ROUTED_SCORE_MAX_PARTS);
/// bigger boards skip it and the overlay falls back to the pad centre.
const routed_via_preview_max_parts: usize = 48;

/// The DRC-safe GND-via nearest `(cx,cy)` within `VIA_MATCH_MM`, or null when the
/// router placed no via there. Null is meaningful: a fat EP/thermal GND pad often
/// can't take a fanned via at all, so the overlay must *not* invent one at the raw
/// pad centre (it would sit on a neighbouring pad — e.g. the FB tap abutting the
/// thermal pad — and never match what routing actually drops).
fn dropViaPos(vias: []const router.Via, cx: f64, cy: f64) ?LocalPt {
    var best_d2: f64 = via_match_mm * via_match_mm;
    var found: ?LocalPt = null;
    for (vias) |vi| {
        const d2 = (vi.x - cx) * (vi.x - cx) + (vi.y - cy) * (vi.y - cy);
        if (d2 <= best_d2) {
            best_d2 = d2;
            found = .{ .x = vi.x, .y = vi.y };
        }
    }
    return found;
}

/// Emit a via drop point as `{"x":…,"y":…}`, or `null` when none exists — the
/// overlay reads null as "draw the GND return path but no via dot here".
fn writeViaDropJson(w: *std.Io.Writer, p: ?LocalPt) std.Io.Writer.Error!void {
    if (p) |q| {
        try w.print("{{\"x\":{d},\"y\":{d}}}", .{ q.x, q.y });
    } else try w.writeAll("null");
}

/// Raw per-part objective blame (the same attribution the PNG heatmap uses), in
/// `alloc`; empty on alloc failure. The client normalizes for the colour ramp —
/// excluding the anchor IC — and refreshes it on drag via the score endpoint.
pub fn partBlameRaw(alloc: std.mem.Allocator, p: optimizer.Placement, params: optimizer.Params) []const f64 {
    const blame = alloc.alloc(f64, p.parts.len) catch return &.{};
    optimizer.perPartBlame(p, params, blame);
    return blame;
}

/// Emit `,"drc_kinds":[…],` — the per-kind DRC rules table (built-in default +
/// current override) the viewer's ⚙ Rules menu renders. Sits between the
/// blob's name and layouts fields, so it carries both surrounding commas.
fn writeDrcKindsField(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) HandlerError!void {
    try w.writeAll(",\"drc_kinds\":");
    try drc_rules.writeKindsJson(w, drc_rules.load(alloc, project_dir, name));
    // …and how the settings drawer sections them. Shipped from `drc_json`'s
    // one grouping table so the drawer cannot section a kind the enum no
    // longer has, nor miss one it has just gained.
    try w.writeAll(",\"drc_groups\":");
    try drc_json.writeDrawerGroupsJson(w);
    try w.writeAll(",");
}

fn buildPcbFabText(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: ?router.RouteResult,
    saved_routes: ?SavedRoutes,
    texts: []const font5x7.BoardText,
    base_edge: ?pour.EdgeField,
) HandlerError!?font5x7.BoardText {
    const saved_zones = shownZones(saved_routes);
    const copper = export_gerber.Copper{
        .tracks = if (routed) |r| r.tracks else &.{},
        .arcs = if (routed) |r| r.arcs else &.{},
        .rf_paths = if (routed) |r| r.rf_port_outcomes else &.{},
        .vias = if (routed) |r| r.vias else &.{},
        .zones = userZonesFrom(alloc, placement.rules, saved_zones),
        .silk_keepouts = silkKeepoutsFrom(alloc, saved_zones),
    };
    const mark = fab_identity.build(alloc, placement, copper, texts, export_fab.frameFor(placement), base_edge) catch |err| switch (err) {
        error.NoSilkscreenSpace, error.InvalidCopperRegion => return null,
        else => return err,
    };
    return mark.text;
}

// An invalid copper region must suppress only the optional fabrication mark:
// the derived response still needs to reach its already-computed pour-invalid
// DRC payload so the editor can explain why fabrication is blocked.
test "derived PCB data recovers from an invalid copper region" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const bow_tie = [_][2]f64{ .{ -1, -1 }, .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 } };
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 2, .h = 2, .shape = "custom", .poly = &bow_tie }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 2,
        .hh = 2,
        .pads = &pads,
        .fallback = false,
        .x = 10,
        .y = 5,
    }};
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
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
    };

    try std.testing.expect((try buildPcbFabText(alloc, placement, null, null, &.{}, null)) == null);
}

fn buildPayloadFabText(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: ?router.RouteResult,
    opts: PcbDataOpts,
) HandlerError!?font5x7.BoardText {
    if (opts.thermal_overlay or opts.assembly_review or opts.analysis_deferred) return null;
    return buildPcbFabText(alloc, placement, routed, opts.saved_routes, opts.texts, opts.base_edge);
}

fn writePayloadDrcMetadata(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    lean: bool,
) HandlerError!void {
    if (lean) return w.writeAll(",\"drc_kinds\":[],\"drc_groups\":[],");
    return writeDrcKindsField(w, alloc, project_dir, name);
}

fn payloadBlame(alloc: std.mem.Allocator, p: optimizer.Placement, params: optimizer.Params, lean: bool) []const f64 {
    return if (lean) &.{} else partBlameRaw(alloc, p, params);
}

fn writePayloadAnalysis(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    routed: ?router.RouteResult,
    opts: PcbDataOpts,
) std.Io.Writer.Error!void {
    if (opts.assembly_review or opts.analysis_deferred) {
        try w.writeAll(",\"antipads\":[],\"trace_em\":{\"analyses\":[]},\"power_integrity\":{\"nets\":[]}");
        return;
    }
    try writeAntipadsField(w, p, routed);
    try trace_em_json.write(w, alloc, p, routed);
    try power_integrity_json.write(
        w,
        .{ .output = alloc, .scratch = opts.scratch_allocator orelse alloc },
        payloadPowerInputs(alloc, p, routed, opts),
    );
}

pub fn writeCamFields(w: *std.Io.Writer, name: []const u8, opts: PcbDataOpts) std.Io.Writer.Error!void {
    try w.writeAll(",\"cam_url\":");
    if (!opts.cam_lazy) return w.writeAll("null,\"cam\":null");
    try w.writeAll("\"/api/pcb-cam/");
    try writeUrlEncoded(w, name);
    try w.writeAll("?cam=1");
    if (opts.shown_layout) |layout| {
        try w.writeAll("&layout=");
        try writeUrlEncoded(w, layout);
    }
    try w.writeAll("\",\"cam\":null");
}

/// The deferred half of an editable PCB page. This is intentionally a small
/// JSON object rather than a second HTML document: it contains only values
/// derived from the already-embedded placement and saved copper. The normal
/// page and this response share the dependency-aware PCB cache, so reloads
/// reuse both halves until the design or layout sidecar changes.
pub fn writePcbDerivedData(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement, rv: ShownView, opts: PcbDataOpts) HandlerError!void {
    const allocators: power_integrity_json.Allocators = .{ .output = alloc, .scratch = opts.scratch_allocator orelse alloc };
    // `?pdn=1` is this payload's own deferral: the PDN impedance sweep alone,
    // over the same solved state, because it is the most expensive analysis the
    // editor runs and the only reader is the track/via inspector.
    if (opts.pdn_only) return power_integrity_json.writeAcResponse(w, allocators, payloadPowerInputs(alloc, p, rv.routed, opts), opts.rev);
    const routed = rv.routed;
    const copper: pour.Copper = if (routed) |r| .{ .tracks = r.tracks, .arcs = r.arcs, .vias = r.vias, .rf_paths = r.rf_port_outcomes } else .{};
    const zones = userZonesFrom(alloc, p.rules, shownZones(opts.saved_routes));
    const fab_text = try buildPcbFabText(alloc, p, routed, opts.saved_routes, opts.texts, opts.base_edge);

    try w.print("{{\"rev\":{d},\"pours\":", .{opts.rev});
    try pour_json.writePours(w, alloc, p, copper, zones, opts.base_edge);
    try pour_json.writePlaneFillsField(w, alloc, p, copper, false, opts.base_edge);
    try w.writeAll(",\"zone_fills\":");
    try pour_json.writeZoneFills(w, alloc, p, copper, zoneFillReqsFrom(alloc, p.rules, shownZones(opts.saved_routes)), opts.base_edge);
    try w.writeAll(",\"drc\":[");
    for (rv.violations, 0..) |violation, i| {
        if (i > 0) try w.writeByte(',');
        try writeViolation(w, violation, .{ .nets = p.nets, .parts = p.parts });
    }
    try w.writeByte(']');
    if (rv.tally) |t| try w.print(",\"routed\":{d},\"total\":{d},\"unique_routed\":{d},\"unique_total\":{d}", .{
        t.routed, t.total, t.unique_routed, t.unique_total,
    });
    try pcb_rules_json.writeMaskRelief(w, alloc, p, routed);
    var full_opts = opts;
    full_opts.analysis_deferred = false;
    try writePayloadAnalysis(w, alloc, p, routed, full_opts);
    try w.writeAll(",\"fab_text\":");
    try writeOptionalBoardTextJson(w, fab_text);
    try w.writeByte('}');
}

/// The solved board both power screens read, assembled once.
fn payloadPowerInputs(alloc: std.mem.Allocator, p: optimizer.Placement, routed: ?router.RouteResult, opts: PcbDataOpts) power_integrity_json.Inputs {
    return .{
        .placement = p,
        .routed = routed,
        .zones = payloadUserZones(alloc, p, opts),
        .base_edge = opts.base_edge,
        .ac = if (opts.pdn_deferred) .deferred else .included,
    };
}

pub fn writePcbData(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    p: optimizer.Placement,
    params: optimizer.Params,
    v: View,
    name: []const u8,
    layouts: []const SavedLayout,
    routed: ?router.RouteResult,
    clearance: f64,
    violations: []const drc.Violation,
    opts: PcbDataOpts,
) HandlerError!void {
    // ref → part index, and "ref|pin" → collapsed net (for pad tags).
    var idx = std.StringHashMapUnmanaged(usize).empty;
    for (p.parts, 0..) |pt, i| try idx.put(alloc, pt.ref_des, i);
    var pin_net = std.StringHashMapUnmanaged([]const u8).empty;
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(alloc, key, netKey(net.name));
        }
    }

    const fab_text = try buildPayloadFabText(alloc, p, routed, opts);
    var blob_opts = opts;
    blob_opts.fab_text = fab_text;

    try w.writeAll("<script>const PCB=");
    const pour_copper: pour.Copper = if (routed) |r| .{ .tracks = r.tracks, .arcs = r.arcs, .vias = r.vias, .rf_paths = r.rf_port_outcomes } else .{};
    try writeBlobHead(w, alloc, v, clearance, p, pour_copper, blob_opts);
    // The build that RENDERED this page. Every client event posted to
    // `/api/client-log/:name` carries it back, so a tab held open across a
    // deploy files its events under the code that drew it rather than the code
    // that received them (`serve/request_log.zig`).
    try w.print("\"build_id\":\"{s}\",", .{build_id.current()});
    // Server-computed objective breakdown of the layout on screen — the baseline
    // the live score deltas against. Same shape the /api/pcb-score endpoint returns.
    try w.print("\"caps\":{d},\"auto\":", .{p.score.loop_caps});
    try writeBreakdownJson(w, p.breakdown, params);
    try w.writeAll(",\"name\":");
    try writeJsonStr(w, name);
    // Where this board came from (source-chip classification). The viewer offers
    // "Route plan" only on an unsaved solve — see PcbDataOpts.src.
    try w.writeAll(",\"src\":");
    try writeJsonStr(w, @tagName(opts.src));
    try writePayloadDrcMetadata(w, alloc, project_dir, name, opts.assembly_review);
    // Rows go out re-keyed onto the flatten this page shows, so a client Load
    // matches by exact ref — identity resolution stays server-side only.
    try writeLayoutsJson(w, rekeyRowsToPlacement(alloc, layouts, p), opts.shown_layout);

    // Raw per-part objective blame → the live "Heatmap" toggle tints each
    // courtyard by its share (client normalizes, excluding the anchor IC).
    const blame = payloadBlame(alloc, p, params, opts.assembly_review);

    // Parts.
    try w.writeAll(parts_open);
    for (p.parts, 0..) |_, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_part_json.writePartJson(w, alloc, p, i, if (i < blame.len) blame[i] else 0, pin_net);
    }
    try w.writeAll("],");

    // Airwires (each tagged with its collapsed net name for the Net-colours view).
    try pcb_layout_chrome.writeLinks(w, p.links, p.rules);

    // Per-net colour map the "Net colours" view paints pads + airwires from.
    try pcb_layout_chrome.writeNetColors(w, alloc, p);

    // Decoupling loops: cap + hub power/ground pads, the *pinned* hub pads (`pp`/
    // `gp`) the score uses, and DRC-safe via drop points (`cgv`/`gpv`) valid for
    // the emitted pose (BOARD_JS recomputes them on drag). `drop_vias` = the routed
    // vias when routed, else `route`'s pass-1 preview on small boards, else empty.
    const drop_vias: []const router.Via = if (routed) |r|
        r.vias
    else if (p.parts.len <= routed_via_preview_max_parts)
        (router.groundVias(alloc, p, .{}) catch &.{})
    else
        &.{};

    try w.writeAll(",\"loops\":[");
    for (p.loops, 0..) |lp, i| {
        if (i > 0) try w.writeAll(",");
        try writeLoopJson(w, p, lp, drop_vias);
    }
    try w.writeAll("],");

    // Signal nets (for the HPWL score) — same set the server scored.
    try w.writeAll("\"nets\":[");
    var first_net = true;
    for (p.nets) |net| {
        if (isGroundNet(net.name)) continue;
        if (!first_net) try w.writeAll(",");
        first_net = false;
        try w.writeAll("[");
        var first_pin = true;
        for (net.pins) |pin| {
            const i = idx.get(pin.ref_des) orelse continue;
            const loc = padLocalPage(p.parts[i], pin.pin);
            if (!first_pin) try w.writeAll(",");
            first_pin = false;
            try w.print("{{\"p\":{d},\"x\":{d},\"y\":{d}}}", .{ i, loc.x, loc.y });
        }
        try w.writeAll("]");
    }
    try w.writeAll("],");

    // Routed copper + DRC markers — emitted in the same shape the
    // /api/pcb-route endpoint returns so drawRoute/drawClr/drawDrc read either.
    try writeRoutedArrays(w, routed, violations, .{ .nets = p.nets, .parts = p.parts }, opts.saved_routes, p);

    // Solder-mask relief for the SHOWN copper — the assembly view draws these
    // served opening polygons and construction strokes verbatim (the same mask_relief.compute the
    // Gerber mask writer runs), so the browser can never drift from the fab.
    if (opts.analysis_deferred) {
        try w.writeAll(",\"mask_relief\":{\"openings\":[],\"strokes\":[],\"joints\":[]},\"mask_merges\":[]");
    } else {
        try pcb_rules_json.writeMaskRelief(w, alloc, p, routed);
    }

    // Solved controlled-impedance via antipads for the viewer's Antipads
    // overlay (see writeAntipadsField).
    // Antipad and click-to-inspect 2.5D analysis have no assembly UI.
    try writePayloadAnalysis(w, alloc, p, routed, opts);

    // Per-footprint STEP-model references (URL + KiCad offset/rotation) for the
    // 3D-view tab, thermal setup, or assembly's persistent sprite cache.
    // Ordinary embedded previews have none and skip filesystem model lookup.
    try w.writeAll(",\"models\":");
    const skip_models = opts.embed and !(opts.model_sprites or opts.model_data);
    if (skip_models) try w.writeAll("{}") else try writeModelsJson(w, alloc, project_dir, p.instances);
    try writeCamFields(w, name, opts);
    try w.writeAll("};</script>");
}

/// Emit `{ "<footprint>": {"o":[x,y,z],"r":[x,y,z]} }` for every distinct
/// footprint in the design that resolves to a STEP model — the KiCad offset/
/// rotation the 3D-view tab orients each part body with (it fetches the bytes
/// from `/api/model-file/<fp>`, keyed on the map entry). Footprints with no
/// model are omitted (the viewer shows their pads only).
pub fn writeModelsJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    instances: []const export_kicad.FlatInstance,
) HandlerError!void {
    const cfg = export_kicad.loadModelConfig(alloc, project_dir);
    var seen = std.StringHashMapUnmanaged(void).empty;
    try w.writeByte('{');
    var first = true;
    for (instances) |inst| {
        const fp = inst.footprint;
        if (fp.len == 0) continue;
        if (seen.contains(fp)) continue;
        try seen.put(alloc, fp, {});
        const tf = cfg.get(fp);
        // Resolve the STEP model the same way the KiCad export / footprint
        // viewer do: an explicit `model` override wins, else a filesystem
        // match. Skip footprints with no model — the 3D view shows pads only.
        const has_model = (if (tf) |t| t.model != null else false) or
            export_kicad_footprint.findModelFile(alloc, project_dir, fp, fp) != null;
        if (!has_model) continue;
        const off = if (tf) |t| t.offset else [3]f64{ 0, 0, 0 };
        const rot = if (tf) |t| t.rotation else [3]f64{ 0, 0, 0 };
        if (!first) try w.writeByte(',');
        first = false;
        try writeJsonStr(w, fp);
        try w.print(
            ":{{\"o\":[{d},{d},{d}],\"r\":[{d},{d},{d}]}}",
            .{ off[0], off[1], off[2], rot[0], rot[1], rot[2] },
        );
    }
    try w.writeByte('}');
}

fn writeFreshTracks(w: *std.Io.Writer, r: router.RouteResult, nets: []const export_kicad.FlatNet) std.Io.Writer.Error!void {
    var first = true;
    var ordinal: usize = 0;
    for (r.tracks) |track| {
        if (routeArcOwnsTrack(r.arcs, track)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const net = netNameOf(nets, track.net);
        try w.print(track_json_fmt, .{ track.x1, track.y1, track.x2, track.y2, track.layer, track.width });
        try writeJsonStr(w, net);
        try w.writeAll(",\"source\":\"autorouter\"");
        try writeTrackSegmentId(w, .{
            .x1 = track.x1,
            .y1 = track.y1,
            .x2 = track.x2,
            .y2 = track.y2,
            .l = track.layer,
            .w = track.width,
            .net = net,
        }, ordinal);
        try w.writeAll("}");
        ordinal += 1;
    }
    for (r.arcs) |arc| {
        if (!first) try w.writeAll(",");
        first = false;
        const net = netNameOf(nets, arc.net);
        try w.print(track_json_fmt, .{ arc.p1[0], arc.p1[1], arc.p2[0], arc.p2[1], arc.layer, arc.width });
        try writeJsonStr(w, net);
        try w.print(",\"xm\":{d},\"ym\":{d},\"source\":\"autorouter\"", .{ arc.pm[0], arc.pm[1] });
        try writeTrackSegmentId(w, .{
            .x1 = arc.p1[0],
            .y1 = arc.p1[1],
            .x2 = arc.p2[0],
            .y2 = arc.p2[1],
            .xm = arc.pm[0],
            .ym = arc.pm[1],
            .l = arc.layer,
            .w = arc.width,
            .net = net,
        }, ordinal);
        try w.writeAll("}");
        ordinal += 1;
    }
}

fn writeSavedTracks(w: *std.Io.Writer, tracks: []const SavedTrack) std.Io.Writer.Error!void {
    for (tracks, 0..) |track, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(track_json_fmt, .{ track.x1, track.y1, track.x2, track.y2, track.l, track.w });
        try writeJsonStr(w, track.net);
        if (track.xm) |xm| if (track.ym) |ym| try w.print(",\"xm\":{d},\"ym\":{d}", .{ xm, ym });
        if (track.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, track.g);
        }
        if (track.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, track.source);
        }
        try writeTrackSegmentId(w, track, i);
        try w.writeAll("}");
    }
}

/// Write one routed via's creator tag. Saved positional copper keeps its tag
/// (including an omitted legacy-unknown tag); a fresh or newly appended via is
/// autorouter output.
fn writeRoutedViaSource(w: *std.Io.Writer, saved: ?SavedRoutes, i: usize) std.Io.Writer.Error!void {
    if (saved) |routes| {
        if (i >= routes.vias.len) return w.writeAll(",\"source\":\"autorouter\"");
        if (routes.vias[i].source.len == 0) return;
        try w.writeAll(",\"source\":");
        return writeJsonStr(w, routes.vias[i].source);
    }
    return w.writeAll(",\"source\":\"autorouter\"");
}

/// Emit `"tracks":[…],"vias":[…],"zones":[…],"drc":[…]` (world mm;
/// track layer 0=top, 1=bottom). Saved KiCad zones are passed through as
/// `PCB.zones`; fresh route API responses carry an empty zones array.
pub fn writeRoutedArrays(
    w: *std.Io.Writer,
    routed: ?router.RouteResult,
    violations: []const drc.Violation,
    names: drc_json.Names,
    saved: ?SavedRoutes,
    placement: ?optimizer.Placement,
) std.Io.Writer.Error!void {
    const nets = names.nets;
    try w.writeAll("\"tracks\":[");
    const saved_tracks = if (saved) |sr| sr.tracks else &.{};
    if (saved_tracks.len > 0) {
        try writeSavedTracks(w, saved_tracks);
    } else if (routed) |r| try writeFreshTracks(w, r, nets);
    try w.writeAll(vias_arr_open);
    if (routed) |r| for (r.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(via_json_fmt, .{ vi.x, vi.y, vi.dia, vi.drill });
        try writeJsonStr(w, netNameOf(nets, vi.net));
        if (saved) |sr| if (i < sr.vias.len and sr.vias[i].g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, sr.vias[i].g);
        };
        // RF via-fence provenance, recovered positionally like `g` above, so the
        // viewer can draw and invalidate a fence via as one.
        var wrote_f = false;
        if (saved) |sr| if (i < sr.vias.len and sr.vias[i].f.len > 0) {
            try w.writeAll(",\"f\":");
            try writeJsonStr(w, sr.vias[i].f);
            wrote_f = true;
        };
        if (!wrote_f) if (placement) |p| if (perimeter_fence.isGenerated(p, vi)) {
            try w.writeAll(",\"f\":");
            try writeJsonStr(w, perimeter_fence.provenance);
        };
        try writeRoutedViaSource(w, saved, i);
        if (saved) |sr| {
            if (i < sr.vias.len) {
                try writeViaId(w, sr.vias[i], i);
            } else {
                try writeViaId(w, .{ .x = vi.x, .y = vi.y, .d = vi.dia, .drill = vi.drill, .net = netNameOf(nets, vi.net) }, i);
            }
        } else try writeViaId(w, .{ .x = vi.x, .y = vi.y, .d = vi.dia, .drill = vi.drill, .net = netNameOf(nets, vi.net) }, i);
        try w.writeAll("}");
    };
    try w.writeAll("],\"zones\":");
    if (saved) |sr| {
        try writeSavedZonesJson(w, sr.zones);
    } else {
        try w.writeAll("[]");
    }
    try w.writeAll(",\"rf_paths\":");
    if (saved) |sr| {
        try writeSavedRfPathsJson(w, sr.rf_paths);
    } else if (routed) |r| {
        try writeFreshRfPathsJson(w, r.rf_port_outcomes, nets);
    } else try w.writeAll("[]");
    try w.writeAll(",\"drc\":[");
    for (violations, 0..) |vio, i| {
        if (i > 0) try w.writeAll(",");
        try writeViolation(w, vio, names);
    }
    // Names of the nets the router could NOT fully connect — the actionable
    // half of the routed/total count (which connections are missing, not just
    // how many). Empty when everything routed or no route ran.
    try w.writeAll("],\"unrouted\":[");
    if (routed) |r| for (r.failed, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonStr(w, name);
    };
    try w.writeAll("]");
    // The router bailed without trying (board bigger than the per-layer grid
    // cap) — surfaced so the viewer can SAY so instead of showing an
    // inexplicably empty route.
    if (routed) |r| if (r.grid_overflow) try w.writeAll(",\"grid_overflow\":true");
}

// spec: Web Server - Inner-layer copper paints one colour across the PCB blob, the page legend and the PNG
test "inner-layer track colour agrees across blob, legend and PNG" {
    // Four copper layers with a plane on In1.Cu: routable signal layer 2 is
    // In2.Cu, the THIRD physical layer — the only shape where a signal-indexed
    // palette lookup and the physical-stack one disagree.
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const rules = optimizer.BoardRules{ .plane_nets = &.{"GND"}, .copper_layers = 4, .planes = .{ .declared = &planes } };
    // Blob and legend are written into one buffer so the "no signal-indexed
    // #C2C200 anywhere" assertion covers both. The placement is parts-free:
    // pcb_layout_chrome.writeLegend reads only the fallback tally and the rules. All three
    // surfaces now read the SAME `board_layers` row, so agreement is
    // structural — this test is what keeps any of them from drifting off it.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try layer_table_json.write(&aw.writer, rules);
    const legend_at = aw.written().len;
    try pcb_layout_chrome.writeLegend(&aw.writer, .{ .parts = &.{}, .links = &.{}, .loops = &.{}, .stubs = &.{}, .instances = &.{}, .nets = &.{}, .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 }, .minx = 0, .miny = 0, .maxx = 20, .maxy = 10, .generated = false, .rules = rules }, false);
    try std.testing.expect(std.mem.indexOf(u8, aw.written()[0..legend_at], "\"l\":2,\"name\":\"In2.Cu\",\"kind\":\"signal\",\"net\":null,\"c\":\"#C200C2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written()[legend_at..], "border-color:#C200C2\"></span> In2.Cu track") != null);
    // …and never the signal-indexed colour the legend used to print (the blob's
    // stack table does carry it — as In1.Cu's PLANE swatch, one layer up).
    try std.testing.expect(std.mem.indexOf(u8, aw.written()[legend_at..], "#C2C200") == null);
    const png = render_pcb_png.trackColor(rules, 2);
    try std.testing.expectEqualSlices(u8, "\xC2\x00\xC2", &[_]u8{ png.r, png.g, png.b });
}

/// The PCB blob's leading scalar/flag fields: projection, grid, board rect
/// (the placement's — carries a drawn outline when one was applied), the
/// read-only/sub flags, and the Stamp seed poses. Split from writePcbData
/// purely to keep both under the function-length cap.
pub fn writeBlobHead(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    v: View,
    clearance: f64,
    p: optimizer.Placement,
    copper: pour.Copper,
    opts: PcbDataOpts,
) HandlerError!void {
    try w.print("{{\"scale\":{d},\"minx\":{d},\"miny\":{d},", .{ v.scale, v.minx, v.miny });
    try w.print("\"margin\":{d},\"grid\":{d},\"w\":{d},\"h\":{d},\"part_edits\":{s},", .{ view_margin_mm, optimizer.grid_mm, v.width, v.height, opts.part_edits_json });
    try w.print("\"clr\":{d},\"cmargin\":{d},", .{ clearance, geometry.bbox_margin_mm });
    // Resolved board-level design-rule scalars for a byte-identical client DRC
    // (`clearance` is edgeClearance()'s fallback; copper_edge only when set —
    // the settings panel's design_rules block is the one listing every scalar).
    const dr = p.rules.design;
    // The pour_* scalars are emitted ONCE, with the pour_* group further down,
    // and are deliberately not repeated here: everything from this print to the
    // closing `}}` is a single JSON object, so a key written twice is last-wins
    // in every parser and the earlier write is dead bytes.
    try w.print(
        "\"rules\":{{\"min_drill\":{d},\"min_annular\":{d},\"hole_to_hole\":{d}," ++
            "\"mask_margin\":{d},\"mask_web\":{d},\"mask_relief_corner_radius\":{d},\"min_width\":{d},\"clearance\":{d},",
        .{
            dr.min_drill, dr.min_annular,               dr.hole_to_hole, dr.mask.margin,
            dr.mask.web,  dr.mask.relief_corner_radius, dr.min_width,    dr.clearance,
        },
    );
    if (dr.edge.copper > 0) try w.print("\"copper_edge\":{d},", .{dr.edge.copper});
    try w.print("\"component_edge\":{d},", .{dr.edge.component});
    // Same-net via spacing, emitted only when the design AUTHORED one: absent
    // means "the net's own clearance", which the client resolves for itself.
    if (dr.via_to_via > 0) try w.print("\"via_to_via\":{d},", .{dr.via_to_via});
    const perimeter_mask_width = p.rules.perimeter_fence.mask_width;
    try w.print(
        "\"pour_clearance\":{d},\"pour_clearance_outer\":{d},\"pour_min_width\":{d},\"pour_corner_radius\":{d},\"ground_via_max\":{d},\"track_width\":{d},\"via_dia\":{d}," ++
            "\"via_drill\":{d},\"via_plating\":{d},\"board_thickness\":{d},\"perimeter_mask_width\":{d},\"perimeter_mask_net\":",
        .{
            dr.pour_clearance,                                                                   dr.pour.clearance_outer, dr.pour.min_width, dr.pour.corner_radius, dr.pour.ground_via_max, dr.track_width, dr.via_dia, dr.via_drill, p.rules.physical.via_plating_mm,
            if (p.rules.physical.board_thickness > 0) p.rules.physical.board_thickness else 1.6, perimeter_mask_width,
        },
    );
    try writeJsonStr(w, p.rules.perimeter_fence.net);
    try w.writeAll("},");
    // Outline rectangle (world mm) — authored `(board …)` or a drawn outline;
    // a non-rectangular board also carries its exact `board_poly` (rect = bbox).
    if (p.board_rect) |br| {
        try w.print("\"board\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}},", .{ br.minx, br.miny, br.w, br.h });
    } else {
        try w.writeAll("\"board\":null,");
    }
    if (p.board_poly) |poly| {
        try w.writeAll("\"board_poly\":[");
        for (poly, 0..) |pp, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(pt_pair_fmt, .{ pp[0], pp[1] });
        }
        try w.writeAll("],");
    } else {
        try w.writeAll("\"board_poly\":null,");
    }
    try w.writeAll("\"board_arcs\":[");
    for (p.board_arcs, 0..) |arc, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"x1\":{d},\"y1\":{d},\"xm\":{d},\"ym\":{d},\"x2\":{d},\"y2\":{d}}}", .{
            arc.p1[0], arc.p1[1], arc.pm[0], arc.pm[1], arc.p2[0], arc.p2[1],
        });
    }
    try w.writeAll("],");
    try w.writeAll("\"outline\":");
    if (opts.saved_outline) |saved_outline| {
        try writeSavedOutlineJson(w, saved_outline);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte(',');
    try writeFabricationLayersField(w, p, opts.saved_fabrication_layers);
    try pcb_keepout_json.write(w, alloc, p);
    try w.writeAll("\"pours\":");
    if (opts.omit_pours) try w.writeAll("[]") else try pour_json.writePours(w, alloc, p, copper, payloadUserZones(alloc, p, opts), opts.base_edge);
    try pour_json.writePlaneFillsField(w, alloc, p, copper, opts.omit_pours, opts.base_edge);
    try w.writeByte(',');
    // Does this board declare any outer-face copper pour? Drives the toolbar's
    // ⟳ Pours button visibility client-side (hidden when no pour is declared).
    const pours_declared = p.rules.pourNetOnSide(.top) != null or p.rules.pourNetOnSide(.bottom) != null;
    try w.print("\"pours_declared\":{s},", .{if (pours_declared) "true" else "false"});
    try pcb_rules_json.writePlaneNets(w, p);
    try pcb_rules_json.writeGroundNames(w);
    // Does any net resolve to a fence target — a `(net-class … (fence …))` or a
    // `(max-freq …)` RF trace? Retained in the page model for clients that want
    // to describe the board's RF capabilities; it does not hide the Fence action.
    try w.print("\"fence_declared\":{s},", .{if (via_fence.anyFenceable(p)) "true" else "false"});
    // Every flattened net name (sorted, deduped) — the user-pour tool's net
    // picker offers exactly these, matching the names tracks/zones/zone_fills use.
    try w.writeAll("\"netnames\":");
    try pcb_layout_chrome.writeNetNames(w, alloc, p);
    // Carved fills for each filled, netted, non-keepout, valid outer-layer user
    // copper pour among the shown zones — same contour shape as `pours`; `zone`
    // indexes the emitted `PCB.zones` array. Computed against the shown copper,
    // so blob == refill == Gerber == PNG.
    try w.writeAll(",\"zone_fills\":");
    if (opts.omit_pours) {
        try w.writeAll("[]");
    } else {
        try pour_json.writeZoneFills(w, alloc, p, copper, zoneFillReqsFrom(alloc, p.rules, shownZones(opts.saved_routes)), opts.base_edge);
    }
    try w.writeByte(',');
    try layer_table_json.write(w, p.rules);
    try board_theme.writeBlobJson(w);
    // Read-only flag for the embedded preview — BOARD_JS skips all edit wiring.
    try w.print("\"ro\":{s},", .{if (opts.read_only) "true" else "false"});
    // `sub` slug for a `?sub=` scoped sub circuit — BOARD_JS appends it to the
    // save/star POSTs so they persist to the per-sub sidecar, not the parent's.
    if (opts.sub) |sq| {
        try w.writeAll("\"sub\":");
        try writeJsonStr(w, sq);
        try w.writeAll(",");
    } else {
        try w.writeAll("\"sub\":null,");
    }
    if (opts.outline_drawn) try w.writeAll("\"outline_drawn\":true,");
    if (opts.top_design) try w.writeAll("\"top_design\":true,");
    if (opts.shown_layout) |sl| {
        try w.writeAll("\"shown_layout\":");
        try writeJsonStr(w, sl);
        try w.writeAll(",");
    }
    try w.writeAll("\"heatsink\":");
    if (opts.saved_heatsink) |sink| try writeSavedHeatsinkJson(w, sink) else try w.writeAll("null");
    try w.writeAll(",\"fan\":");
    try writeOptionalSavedFanJson(w, opts.saved_fan);
    try w.writeAll(",\"dimensions\":");
    try writePartEdgeDimensionsJson(w, opts.saved_dimensions);
    try w.writeAll(",");
    // Optimistic-concurrency rev the page loaded — Save/Update echoes it to 409 a
    // stale write from another window.
    try w.print("\"rev\":{d},\"analysis_deferred\":{},", .{ opts.rev, opts.analysis_deferred });
    // Per-sub-block module-layout seed poses for the palette's Stamp button.
    try w.writeAll("\"subseeds\":");
    try w.writeAll(if (opts.subseeds_json.len > 0) opts.subseeds_json else "{}");
    try w.writeAll(",\"subseedinfo\":");
    try w.writeAll(if (opts.subseedinfo_json.len > 0) opts.subseedinfo_json else "{}");
    try w.writeAll(",\"submodules\":");
    try w.writeAll(if (opts.submodules_json.len > 0) opts.submodules_json else "{}");
    // Per-group module copper (net-mapped, module-local coords) for Stamp.
    try w.writeAll(",\"subroutes\":");
    try w.writeAll(if (opts.subroutes_json.len > 0) opts.subroutes_json else "{}");
    // Resolved placement+routing plan (authored or synthesized) — the drawer's
    // routing-plan section renders the effective execution order from this.
    try w.writeAll(",\"plan\":");
    try w.writeAll(if (opts.plan_json.len > 0) opts.plan_json else "null");
    try writeNetClrJson(w, p);
    try pcb_rules_json.writeNetClasses(w, p);
    try writeDiffPairsJson(w, p);
    try w.writeAll(",\"fab_text\":");
    try writeOptionalBoardTextJson(w, opts.fab_text);
    // Board-level silkscreen texts the shown layout carries (Text tool state).
    try w.writeAll(texts_open);
    try writeSavedTextsJson(w, opts.texts);
    try w.writeAll(",");
}

fn writePointArray(w: *std.Io.Writer, points: []const [2]f64) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (points, 0..) |point, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(pt_pair_fmt, .{ point[0], point[1] });
    }
    try w.writeAll("]");
}

/// Emit every backing with board regions already resolved to editable polygon
/// vertices. The browser therefore edits one uniform representation, while
/// source-level `region board` still follows later outline changes until the
/// user makes and saves an explicit override.
fn writeFabricationSketches(w: *std.Io.Writer, count: usize, layer_name: []const u8, saved_layers: []const SavedFabricationLayer) std.Io.Writer.Error!void {
    var found: ?[]const ?shape_sketch.Sketch = null;
    for (saved_layers) |saved| if (std.mem.eql(u8, saved.name, layer_name)) {
        found = saved.sketches;
        break;
    };
    const sketches = found orelse return;
    var any = false;
    for (sketches) |sketch| if (sketch != null) {
        any = true;
        break;
    };
    if (!any) return;
    try w.writeAll(",\"sketches\":[");
    for (0..count) |i| {
        if (i > 0) try w.writeByte(',');
        if (i < sketches.len and sketches[i] != null) try shape_sketch_json.write(w, sketches[i].?) else try w.writeAll("null");
    }
    try w.writeByte(']');
}

fn writeFabricationLayersField(w: *std.Io.Writer, p: optimizer.Placement, saved_layers: []const SavedFabricationLayer) std.Io.Writer.Error!void {
    try w.writeAll("\"fabrication_layers\":[");
    for (p.fabrication_layers, 0..) |layer, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, layer.name);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, layer.kind);
        try w.writeAll(",\"side\":");
        try writeJsonStr(w, @tagName(layer.side));
        try w.writeAll(",\"material\":");
        try writeJsonStr(w, layer.material);
        try w.print(",\"thickness\":{d},\"regions\":[", .{layer.thickness});
        for (layer.regions, 0..) |region, ri| {
            if (ri > 0) try w.writeAll(",");
            switch (region) {
                .polygon => |points| try writePointArray(w, points),
                .board => if (p.board_poly) |points|
                    try writePointArray(w, points)
                else {
                    const r = export_fab.outlineRect(p);
                    const points = [_][2]f64{
                        .{ r.minx, r.miny },
                        .{ r.minx + r.w, r.miny },
                        .{ r.minx + r.w, r.miny + r.h },
                        .{ r.minx, r.miny + r.h },
                    };
                    try writePointArray(w, &points);
                },
            }
        }
        try w.writeByte(']');
        try writeFabricationSketches(w, layer.regions.len, layer.name, saved_layers);
        try w.print(",\"exclude_footprints\":{s},\"all_sides\":{s},\"clearance\":{d}}}", .{
            if (layer.exclude_footprints.enabled) "true" else "false",
            if (layer.exclude_footprints.all_sides) "true" else "false",
            layer.exclude_footprints.clearance,
        });
    }
    try w.writeAll("],");
}

/// Emit `,"netclr":{…}` — per-net clearance overrides (collapsed net key → mm)
/// for the client DRC preview; positive overrides only, others fall back to `clr`.
fn writeNetClrJson(w: *std.Io.Writer, p: optimizer.Placement) std.Io.Writer.Error!void {
    try w.writeAll(",\"netclr\":{");
    var nc_first = true;
    for (p.nets, 0..) |net, i| {
        if (i >= p.rules.net.len) break;
        const c = p.rules.net[i].clearance;
        if (!(c > 0)) continue;
        if (!nc_first) try w.writeAll(",");
        nc_first = false;
        try writeJsonStr(w, netKey(net.name));
        try w.print(":{d}", .{c});
    }
    try w.writeAll("}");
}

/// Emit `,"diffpairs":[{"p":NAME,"n":NAME,"gap":MM}]` — the resolved
/// differential pairs (raw net names; `drc_marshal.js` dot-collapses them like
/// net-classes) so the client DRC/inspector can bind a copper net to its twin.
fn writeDiffPairsJson(w: *std.Io.Writer, p: optimizer.Placement) std.Io.Writer.Error!void {
    try w.writeAll(",\"diffpairs\":[");
    for (p.diff_pairs, 0..) |dp, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"p\":");
        try writeJsonStr(w, if (dp.p < p.nets.len) p.nets[dp.p].name else "");
        try w.writeAll(",\"n\":");
        try writeJsonStr(w, if (dp.n < p.nets.len) p.nets[dp.n].name else "");
        try w.print(",\"gap\":{d}}}", .{dp.gap});
    }
    try w.writeByte(']');
}

/// A routed feature's net NAME for the persistable route JSON ("" for −1).
pub fn netNameOf(nets: []const export_kicad.FlatNet, idx: i32) []const u8 {
    if (idx < 0 or idx >= nets.len) return "";
    return nets[@intCast(idx)].name;
}

/// Emit `,"antipads":[{"x","y","net","dia","anti","min","ohms","limited"},…]`
/// — one record per shown via on a single-ended controlled-impedance net whose
/// plane antipad the stackup solver could answer for. `anti` is the SOLVED
/// opening the plane fills and Gerbers actually carve (the identical
/// `via_antipad.solve` call `pour.viaPlaneClearance` makes), `min` the
/// ordinary-clearance ring it is floored at, and `ohms` the lumped estimate at
/// the emitted opening. On a thin buildup the two diameters differ by tens of
/// microns — sub-pixel at any board zoom — which is exactly why the viewer's
/// Antipads overlay prints the numbers instead of asking the eye to compare
/// rings. Empty when nothing qualifies (no CI vias, or no physical stackup).
pub fn writeAntipadsField(w: *std.Io.Writer, p: optimizer.Placement, routed: ?router.RouteResult) std.Io.Writer.Error!void {
    try w.writeAll(",\"antipads\":[");
    var first = true;
    const r = routed orelse return w.writeByte(']');
    for (r.vias) |via| {
        if (via.net < 0) continue;
        const ni: usize = @intCast(via.net);
        if (ni >= p.rules.net.len) continue;
        const imp = p.rules.net[ni].rf.impedance;
        if (!(imp.ohms > 0) or imp.diff_ohms > 0) continue;
        const minimum = p.rules.clearanceForNet(via.net, p.rules.design.clearance);
        const solved = via_antipad.solve(p.rules.physical.stack, imp.ohms, via.dia, via.drill, minimum) orelse continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"x\":{d},\"y\":{d},\"net\":", .{ via.x, via.y });
        try writeJsonStr(w, netNameOf(p.nets, via.net));
        try w.print(",\"dia\":{d},\"anti\":{d},\"min\":{d},\"ohms\":{d},\"limited\":{s}}}", .{
            via.dia,
            solved.antipad_dia_mm,
            via.dia + 2 * minimum,
            solved.estimated_ohms,
            if (solved.clearance_limited) "true" else "false",
        });
    }
    try w.writeByte(']');
}

/// Short label for a DRC violation kind (shown in the marker tooltip).
/// DRC violation JSON (incl. the short traceable id) lives in drc_json.zig —
/// one writer for every surface, so ids can never drift between endpoints.
pub const writeViolation = drc_json.writeViolation;

/// Emit `"layouts":[ … ],` — the saved-layout history for the client. Each
/// entry carries its name, kind, optional score, and `parts` as a ref → {x,y,
/// rot, origin?} map so a Load reads positions by the renumber-stable `origin`
/// (falling back to the ref key for legacy entries). Trailing comma included.
///
/// COPPER is emitted only for `shown` — the layout this page actually renders.
/// Every other row that has copper gets `"routes":null`, meaning "this exists,
/// but server-side": the client loads it by following the row's `?layout=`
/// permalink instead of restoring it in place. Embedding all of it inline made
/// the page grow with the number of routed candidates kept (a board with 18 of
/// them carried megabytes of tracks nobody had clicked), which is exactly the
/// shape a backfilled board has. A row with no copper at all still omits the
/// field, so a pose-only layout keeps loading in place with no round-trip.
pub fn writeLayoutsJson(w: *std.Io.Writer, layouts: []const SavedLayout, shown: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll("\"layouts\":[");
    for (layouts, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(name_open);
        try writeJsonStr(w, L.name);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, L.kind);
        // Capture time (unix s) — the viewer's unsaved-work check compares a
        // localStorage draft's timestamp against the newest saved layout's.
        try w.print(",\"ts\":{d}", .{L.ts});
        if (L.default) try w.writeAll(",\"default\":true");
        if (L.score) |s| {
            try w.print(",\"score\":{{\"hpwl\":{d},\"loop\":{d},\"caps\":{d},\"objective\":{d}}}", .{ s.hpwl, s.loop, s.caps, s.objective });
        } else try w.writeAll(",\"score\":null");
        if (L.routes) |sr| {
            try w.writeAll(",\"routes\":");
            const is_shown = shown != null and std.mem.eql(u8, shown.?, L.name);
            if (is_shown) try writeSavedRoutesJson(w, sr) else try w.writeAll("null");
        }
        if (L.outline) |o| {
            try w.writeAll(outline_open);
            try writeSavedOutlineJson(w, o);
        }
        if (L.fabrication_layers.len > 0) {
            try w.writeAll(fabrication_layers_open);
            try sidecar_json.writeSavedFabricationLayersJson(w, L.fabrication_layers);
        }
        if (L.heatsink) |sink| {
            try w.writeAll(",\"heatsink\":");
            try writeSavedHeatsinkJson(w, sink);
        }
        if (L.fan) |fan| {
            try w.writeAll(",\"fan\":");
            try writeSavedFanJson(w, fan);
        }
        if (L.texts.len > 0) {
            try w.writeAll(texts_open);
            try writeSavedTextsJson(w, L.texts);
        }
        if (L.dimensions.len > 0) {
            try w.writeAll(",\"dimensions\":");
            try writePartEdgeDimensionsJson(w, L.dimensions);
        }
        try w.writeAll(",\"parts\":{");
        for (L.parts, 0..) |pt, j| {
            if (j > 0) try w.writeAll(",");
            try writeJsonStr(w, pt.ref);
            try w.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pt.x, pt.y, pt.rot });
            try pcb_part_json.writePoseSideLocked(w, pt.side, pt.locked);
            if (pt.origin.len > 0) {
                try w.writeAll(origin_open);
                try writeJsonStr(w, pt.origin);
            }
            try w.writeAll("}");
        }
        try w.writeAll("}}");
    }
    try w.writeAll("],");
}

fn padLocalPage(part: optimizer.Part, pin: []const u8) LocalPt {
    for (part.pads) |pd| {
        if (std.mem.eql(u8, pd.number, pin)) return .{ .x = pd.x, .y = pd.y };
    }
    return .{ .x = 0, .y = 0 };
}

/// Emit one decoupling placement guide, including its net-colour lookup key.
pub fn writeLoopJson(
    w: *std.Io.Writer,
    p: optimizer.Placement,
    lp: optimizer.Loop,
    drop_vias: []const router.Via,
) std.Io.Writer.Error!void {
    try w.print("{{\"cap\":{d},\"hub\":{d},\"cp\":", .{ lp.cap, lp.hub });
    try pcb_part_json.writePadRect(w, lp.cap_pwr);
    try w.writeAll(",\"cg\":");
    try pcb_part_json.writePadRect(w, lp.cap_gnd);
    try w.writeAll(",\"pp\":");
    try pcb_part_json.writePadRect(w, lp.hub_pwr_pin);
    try w.writeAll(",\"gp\":");
    try pcb_part_json.writePadRect(w, lp.hub_gnd_pin);
    // `ep` = the hub pad the DESIGN declared (`(decouples "IC" PIN)` / a per-pin
    // shorthand), absent when the solver defaulted; the viewer dashes those.
    if (lp.explicit_pin.len > 0) {
        try w.writeAll(",\"ep\":");
        try writeJsonStr(w, lp.explicit_pin);
    }
    if (lp.pwr_net >= 0 and @as(usize, @intCast(lp.pwr_net)) < p.nets.len) {
        try w.writeAll(net_json_key);
        try writeJsonStr(w, netKey(p.nets[@intCast(lp.pwr_net)].name));
    }
    try w.writeAll(",\"hp\":");
    try pcb_part_json.writePadRectList(w, lp.hub_pwr);
    try w.writeAll(",\"hg\":");
    try pcb_part_json.writePadRectList(w, lp.hub_gnd);
    const cg_c = optimizer.worldPadCenter(&p.parts[lp.cap], lp.cap_gnd.x, lp.cap_gnd.y);
    const gp_c = optimizer.worldPadCenter(&p.parts[lp.hub], lp.hub_gnd_pin.x, lp.hub_gnd_pin.y);
    try w.writeAll(",\"cgv\":");
    try writeViaDropJson(w, dropViaPos(drop_vias, cg_c[0], cg_c[1]));
    try w.writeAll(",\"gpv\":");
    try writeViaDropJson(w, dropViaPos(drop_vias, gp_c[0], gp_c[1]));
    try w.writeAll("}");
}

pub fn kindStr(k: optimizer.RatKind) []const u8 {
    return switch (k) {
        .proximity => "proximity",
        .ground => "ground",
        .signal => "signal",
    };
}

/// Shares the token set `placement/optimizer.isGroundName` judges a board by,
/// so the page's HPWL net groups match the server-computed baseline exactly.
/// Exact-match only: this is a grouping key, not the plane predicate, so it
/// deliberately does not accept the numbered suffixes that predicate does.
fn isGroundNet(name: []const u8) bool {
    const s = shortName(name);
    for (na.ground_tokens) |g| {
        if (std.mem.eql(u8, s, g)) return true;
    }
    return false;
}

fn writeStringList(w: *std.Io.Writer, values: []const []const u8) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonStr(w, value);
    }
    try w.writeByte(']');
}

fn writePlanWaves(w: *std.Io.Writer, waves: []const env_mod.PlanWave) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (waves, 0..) |wave, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(name_open);
        try writeJsonStr(w, wave.name);
        try w.writeAll(",\"reason\":");
        if (wave.reason) |reason| try writeJsonStr(w, reason) else try w.writeAll("null");
        try w.writeAll(",\"refs\":");
        try writeStringList(w, wave.refs);
        try w.writeAll(",\"sections\":");
        try writeStringList(w, wave.sections);
        try w.writeAll(",\"sub_blocks\":");
        try writeStringList(w, wave.sub_blocks);
        try w.writeAll(",\"classes\":");
        try writeStringList(w, wave.classes);
        try w.writeAll(",\"net_classes\":");
        try writeStringList(w, wave.net_classes);
        try w.writeAll(",\"nets\":");
        try writeStringList(w, wave.nets);
        try w.writeAll(",\"preferred_layers\":");
        try writeStringList(w, wave.preferred_layers);
        try w.writeAll(",\"allowed_layers\":");
        try writeStringList(w, wave.allowed_layers);
        try w.writeAll(",\"waypoints\":");
        try writeWaypoints(w, wave.corridor.waypoints);
        try w.writeAll(",\"max_vias\":");
        if (wave.max_vias) |max_vias| try w.print("{d}", .{max_vias}) else try w.writeAll("null");
        try w.print(",\"seed_first\":{s},\"rest\":{s}}}", .{
            if (wave.corridor.seed_first) "true" else "false",
            if (wave.rest) "true" else "false",
        });
    }
    try w.writeByte(']');
}

/// Emit `[{"x":X,"y":Y,"layer":L}, …]` for a wave's routing waypoints — shared
/// by the authored-provenance and resolved-plan wave writers.
fn writeWaypoints(w: *std.Io.Writer, points: []const env_mod.PlanWaypoint) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (points, 0..) |point, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"x\":{d},\"y\":{d},\"layer\":", .{ point.x, point.y });
        try writeJsonStr(w, point.layer);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

pub fn writeAuthoredSettings(
    w: *std.Io.Writer,
    block: *const env_mod.DesignBlock,
    source_path: []const u8,
    sub: ?[]const u8,
) std.Io.Writer.Error!void {
    try w.writeAll(name_open);
    try writeJsonStr(w, block.name);
    try w.writeAll(",\"source\":{\"path\":");
    try writeJsonStr(w, source_path);
    try w.writeAll(",\"kicad_pcb\":");
    if (block.kicad_pcb_path) |path| try writeJsonStr(w, path) else try w.writeAll("null");
    try w.writeAll(",\"sub\":");
    if (sub) |slug| try writeJsonStr(w, slug) else try w.writeAll("null");
    try w.writeAll("},\"revision\":{\"authored\":");
    try w.writeAll(if (block.revision.present) "true" else "false");
    try w.writeAll(",\"id\":");
    try writeJsonStr(w, block.revision.id);
    try w.writeAll(",\"date\":");
    try writeJsonStr(w, block.revision.date);
    try w.writeAll("},\"stackup\":{\"authored\":");
    try w.writeAll(if (block.stackup.present) "true" else "false");
    try @import("../eval/stackup_presets.zig").writeCatalogJson(w, block.stackup);
    for (block.stackup.planes, 0..) |plane, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"index\":{d},\"net\":", .{plane.index});
        try writeJsonStr(w, plane.net);
        try w.writeByte('}');
    }
    try w.writeAll("],\"copper\":[");
    for (block.stackup.copper, 0..) |layer, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"index\":{d},\"thickness\":{d},\"material\":", .{ layer.index, layer.thickness });
        try writeJsonStr(w, layer.material);
        try w.writeByte('}');
    }
    try w.writeAll("],\"dielectrics\":[");
    for (block.stackup.dielectrics, 0..) |layer, i| {
        if (i > 0) try w.writeByte(',');
        // `er` is the RESOLVED permittivity — the authored `(er X)` or the
        // generic FR-4 default the impedance model would use — so the panel
        // shows the number a width would actually be solved against, and
        // `er_authored` says whether the design stated it.
        try w.print("{{\"after_layer\":{d},\"kind\":\"{s}\",\"thickness\":{d},\"er\":{d},\"er_authored\":{},\"material\":", .{
            layer.after_layer,
            @tagName(layer.kind),
            layer.thickness,
            if (layer.er > 0) layer.er else impedance.default_er,
            layer.er > 0,
        });
        try writeJsonStr(w, layer.material);
        try w.writeByte('}');
    }
    const rules = block.design_rules;
    try w.print("],\"construction_thickness\":{d},\"origin\":\"source\"}},\"design_rules\":{{\"authored\":", .{
        block.stackup.constructionThickness(),
    });
    try w.writeAll(if (rules.present) "true" else "false");
    try w.print(
        ",\"clearance\":{d},\"track_width\":{d},\"via_dia\":{d},\"via_drill\":{d},\"via_plating\":{d}," ++
            "\"min_drill\":{d},\"min_annular\":{d},\"hole_to_hole\":{d},\"via_to_via\":{d},\"copper_edge\":{d},\"component_edge\":{d}," ++
            "\"mask_margin\":{d},\"mask_web\":{d},\"mask_relief_corner_radius\":{d},\"min_width\":{d},\"pour_clearance\":{d},\"pour_min_width\":{d},\"pour_corner_radius\":{d},\"ground_via_max\":{d}}}",
        .{
            rules.clearance,      rules.track_width,    rules.via.dia,            rules.via.drill,                 rules.via.plating,
            rules.min_drill,      rules.min_annular,    rules.hole_to_hole,       rules.via_to_via,                rules.edge.copper,
            rules.edge.component, rules.mask.margin,    rules.mask.web,           rules.mask.relief_corner_radius, rules.min_width,
            rules.pour_clearance, rules.pour.min_width, rules.pour.corner_radius, rules.pour.ground_via_max,
        },
    );
    try w.writeAll(",\"net_classes\":[");
    for (block.net_classes, 0..) |class, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(name_open);
        try writeJsonStr(w, class.name);
        try w.print(
            ",\"width\":{d},\"power_branch_width\":{d},\"clearance\":{d},\"via_dia\":{d},\"via_drill\":{d}," ++
                "\"priority\":{d},\"diff_gap\":{d},\"max_freq_hz\":{d},\"impedance_ohms\":{d},\"ground_gap_mm\":{d},\"ground_gap_max_mm\":{d},\"nets\":",
            .{
                class.width,                          class.pad_neck.power_branch_width, class.clearance,      class.via_dia,           class.via_drill,
                class.priority,                       class.diff_gap,                    class.rf.max_freq_hz, class.rf.impedance.ohms, class.rf.impedance.ground_gap_mm,
                class.rf.impedance.ground_gap_max_mm,
            },
        );
        try writeStringList(w, class.nets);
        try w.writeByte('}');
    }
    try w.writeAll("],\"pcb_plan\":");
    if (block.pcb_plan) |plan| {
        try w.writeAll("{\"authored\":true,\"place\":");
        try writePlanWaves(w, plan.place);
        try w.writeAll(",\"route\":");
        try writePlanWaves(w, plan.route);
        try w.writeByte('}');
    } else try w.writeAll("{\"authored\":false,\"place\":[],\"route\":[]}");
    try w.writeByte('}');
}

/// Resolve the design's effective placement+routing plan — the authored
/// `(pcb-plan …)` waves or, when none is authored, the synthesized default —
/// against the solved `placement`, and render it as the blob's `plan` object
/// (`{synthesized, warnings, place, route}`). Members are spelled as names
/// (place → part ref-des, route → net name) so the drawer JS stays dumb.
fn writePlanJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    p: optimizer.Placement,
) HandlerError!void {
    var policy = try module_policy.analyze(alloc, p);
    defer policy.deinit(alloc);
    const resolved = try plan_resolve.resolve(alloc, block.pcb_plan, .{
        .placement = p,
        .net_class = policy.net_class,
        .part_role = policy.part_role,
        .modules = policy.modules,
        .sections = try plan_resolve.sectionMembers(alloc, block),
        .net_class_specs = block.net_classes,
    });
    try writeResolvedPlan(w, resolved, p);
}

/// Pre-render `writePlanJson` into a standalone string for `PcbDataOpts.plan_json`
/// (the blob writer has no block). Degrades to `"null"` so a plan-resolution
/// failure never fails the page — the drawer then falls back to authored
/// provenance alone.
pub fn buildPlanJson(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    p: optimizer.Placement,
) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    writePlanJson(&aw.writer, alloc, block, p) catch return "null";
    return aw.written();
}

/// Serialize a `ResolvedPlan`: the `synthesized` flag, the unresolved-selector
/// `warnings`, the placement waves (members as ref-des) and the routing waves
/// (members as net names, plus their layer/via/waypoint policy).
fn writeResolvedPlan(
    w: *std.Io.Writer,
    plan: plan_resolve.ResolvedPlan,
    p: optimizer.Placement,
) std.Io.Writer.Error!void {
    try w.print("{{\"synthesized\":{s},\"warnings\":", .{if (plan.synthesized) "true" else "false"});
    try writePlanWarnings(w, plan.warnings);
    try w.writeAll(",\"place\":[");
    for (plan.place, 0..) |wave, i| {
        if (i > 0) try w.writeByte(',');
        try writePlaceWaveJson(w, wave, p);
    }
    try w.writeAll("],\"route\":[");
    for (plan.route, 0..) |wave, i| {
        if (i > 0) try w.writeByte(',');
        try writeRouteWaveJson(w, wave, p);
    }
    try w.writeAll("]}");
}

/// Emit the plan's unresolved-selector warnings as `[{kind, message, wave, name}, …]`.
fn writePlanWarnings(w: *std.Io.Writer, warnings: []const plan_resolve.Warning) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (warnings, 0..) |warn, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":");
        try writeJsonStr(w, warn.kind);
        try w.writeAll(",\"message\":");
        try writeJsonStr(w, warn.message);
        try w.writeAll(",\"wave\":");
        try writeJsonStr(w, warn.wave);
        try w.writeAll(",\"name\":");
        try writeJsonStr(w, warn.name);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// Emit `"name":…,"reason":…,"rest":…` — the fields every resolved wave shares.
fn writeWaveCommon(w: *std.Io.Writer, wave: plan_resolve.ResolvedWave) std.Io.Writer.Error!void {
    try w.writeAll(name_open);
    try writeJsonStr(w, wave.name);
    try w.writeAll(",\"reason\":");
    if (wave.reason) |reason| try writeJsonStr(w, reason) else try w.writeAll("null");
    try w.print(",\"seed_first\":{s},\"rest\":{s}", .{
        if (wave.steering.seed_first) "true" else "false",
        if (wave.rest) "true" else "false",
    });
}

/// Emit a resolved wave's member NAMES: part ref-des when `route` is false,
/// net names when true (indices resolved against the solved placement).
fn writeWaveMembers(
    w: *std.Io.Writer,
    members: []const usize,
    p: optimizer.Placement,
    route: bool,
) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (members, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        const name = if (route)
            (if (m < p.nets.len) p.nets[m].name else "")
        else
            (if (m < p.parts.len) p.parts[m].ref_des else "");
        try writeJsonStr(w, name);
    }
    try w.writeByte(']');
}

/// One placement wave: the shared fields plus its member parts as ref-des.
fn writePlaceWaveJson(
    w: *std.Io.Writer,
    wave: plan_resolve.ResolvedWave,
    p: optimizer.Placement,
) std.Io.Writer.Error!void {
    try writeWaveCommon(w, wave);
    try w.writeAll(",\"members\":");
    try writeWaveMembers(w, wave.members, p, false);
    try w.writeByte('}');
}

/// One routing wave: the shared fields, its layer/via/waypoint policy, and its
/// member nets as names.
fn writeRouteWaveJson(
    w: *std.Io.Writer,
    wave: plan_resolve.ResolvedWave,
    p: optimizer.Placement,
) std.Io.Writer.Error!void {
    try writeWaveCommon(w, wave);
    try w.writeAll(",\"preferred_layers\":");
    try writeStringList(w, wave.layers.preferred);
    try w.writeAll(",\"allowed_layers\":");
    try writeStringList(w, wave.layers.allowed);
    try w.writeAll(",\"max_vias\":");
    if (wave.max_vias) |max_vias| try w.print("{d}", .{max_vias}) else try w.writeAll("null");
    try w.writeAll(",\"waypoints\":");
    try writeWaypoints(w, wave.waypoints);
    try w.writeAll(",\"members\":");
    try writeWaveMembers(w, wave.members, p, true);
    try w.writeByte('}');
}

// spec: Web Server - PCB design settings expose authored stackup, rules, net classes, and route plan provenance
test "authored PCB settings JSON includes the complete configuration" {
    const planes = [_]env_mod.StackupPlane{.{ .index = 2, .net = "GND" }};
    const copper = [_]env_mod.StackupCopper{
        .{ .index = 1, .thickness = 0.035 },
        .{ .index = 2, .thickness = 0.0152 },
    };
    const dielectrics = [_]env_mod.StackupDielectric{.{
        .after_layer = 1,
        .kind = .prepreg,
        .material = "7628*1",
        .thickness = 0.2104,
    }};
    const classes = [_]env_mod.NetClassSpec{.{
        .name = "rf",
        .width = 0.3124,
        .clearance = 0.127,
        .priority = 6,
        .rf = .{ .max_freq_hz = 12e9 },
        .nets = &.{"RF_OUT"},
    }};
    const route_waves = [_]env_mod.PlanWave{.{
        .name = "RF first",
        .net_classes = &.{"rf"},
        .allowed_layers = &.{"F.Cu"},
        .max_vias = 0,
        .reason = "Protect the launch",
    }};
    const block = env_mod.DesignBlock{
        .name = "Board A",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .kicad_pcb_path = "/boards/board-a.kicad_pcb",
        .stackup = .{
            .present = true,
            .layers = 4,
            .planes = &planes,
            .copper = &copper,
            .dielectrics = &dielectrics,
            .thickness = 1.6,
        },
        .design_rules = .{ .present = true, .clearance = 0.127, .min_drill = 0.2, .via_to_via = 0.23 },
        .net_classes = &classes,
        .pcb_plan = .{ .route = &route_waves },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeAuthoredSettings(&aw.writer, &block, "src/boards/board-a.sexp", null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 4), root.get("stackup").?.object.get("layers").?.integer);
    const stackup = root.get("stackup").?.object;
    const plane = stackup.get("planes").?.array.items[0].object;
    try std.testing.expectEqualStrings("GND", plane.get("net").?.string);
    try std.testing.expectEqual(@as(usize, 2), stackup.get("copper").?.array.items.len);
    const dielectric = stackup.get("dielectrics").?.array.items[0].object;
    try std.testing.expectEqualStrings("prepreg", dielectric.get("kind").?.string);
    try std.testing.expectEqualStrings("7628*1", dielectric.get("material").?.string);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.2606),
        stackup.get("construction_thickness").?.float,
        1e-9,
    );
    try std.testing.expectEqualStrings("rf", root.get("net_classes").?.array.items[0].object.get("name").?.string);
    const route = root.get("pcb_plan").?.object.get("route").?.array.items[0].object;
    try std.testing.expectEqualStrings(
        "F.Cu",
        route.get("allowed_layers").?.array.items[0].string,
    );
    try std.testing.expectEqualStrings("src/boards/board-a.sexp", root.get("source").?.object.get("path").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.23), root.get("design_rules").?.object.get("via_to_via").?.float, 1e-9);
}

/// A design block carrying only what plan resolution reads (its `pcb_plan`, with
/// empty section / net-class context); every other field stays empty.
fn planFixtureBlock(plan: ?env_mod.PcbPlanSpec) env_mod.DesignBlock {
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

// spec: Web Server - The PCB blob's plan lists the resolved placement and routing waves with member names and the synthesized flag
test "PCB blob plan lists resolved place and route waves by member name" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const alloc = arena_i.allocator();

    // A hub U1, a sub-block cap pwr/C1, and a connector J1; one RF net on U1.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "pwr/C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
    };
    const rf_pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{.{ .name = "RFOUT", .pins = &rf_pins }};
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
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };

    // Authored plan: a place wave claims U1; a rest route wave sweeps every net.
    const place_waves = [_]env_mod.PlanWave{.{ .name = "Core", .refs = &.{"U1"} }};
    const route_waves = [_]env_mod.PlanWave{.{ .name = "outer-only", .rest = true }};
    const authored = planFixtureBlock(.{ .place = &place_waves, .route = &route_waves });

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writePlanJson(&aw.writer, alloc, &authored, placement);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(!root.get("synthesized").?.bool);
    const place0 = root.get("place").?.array.items[0].object;
    try std.testing.expectEqualStrings("Core", place0.get("name").?.string);
    try std.testing.expectEqualStrings("U1", place0.get("members").?.array.items[0].string);
    const route0 = root.get("route").?.array.items[0].object;
    try std.testing.expectEqualStrings("RFOUT", route0.get("members").?.array.items[0].string);

    // A null plan synthesizes the default order, still spelling members by name.
    const synth = planFixtureBlock(null);
    var aw2: std.Io.Writer.Allocating = .init(alloc);
    try writePlanJson(&aw2.writer, alloc, &synth, placement);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw2.written(), .{});
    defer parsed2.deinit();
    const root2 = parsed2.value.object;
    try std.testing.expect(root2.get("synthesized").?.bool);
    const conn = root2.get("place").?.array.items[0].object;
    try std.testing.expectEqualStrings("Connectors & mechanical", conn.get("name").?.string);
    try std.testing.expectEqualStrings("J1", conn.get("members").?.array.items[0].string);
}

// spec: Web Server - The PCB blob emits each pad's rotation, roundrect ratio, oval slot, and through-hole flag
test "pad json carries rotation, roundrect ratio, oval slot, and thru; omits defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Pad A carries the rotation / roundrect ratio / oval-slot extras; pad B the
    // through-hole flag. Every field each pad leaves at its default is omitted,
    // so each key surfaces exactly once across the two pads.
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .slot_half = .{ 1, 0 }, .rot = 9, .overrides = .{ .rratio = 0.2 } },
        .{ .number = "2", .x = 0, .y = 0, .w = 0.4, .h = 0.4, .thru = true },
    };
    const pt = optimizer.Part{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false };
    const pin_net = std.StringHashMapUnmanaged([]const u8).empty;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try pcb_part_json.writePadsJson(&aw.writer, alloc, pt, pin_net);
    const s = aw.written();

    // Each DRC-input extra is present with its exact value.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"rot\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"rratio\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"slot_half\":[1,0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"thru\":true") != null);
    // Each appears exactly once — the pad leaving it at its default omits it.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "\"rot\":"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "\"rratio\":"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "\"slot_half\":"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "\"thru\":true"));
}

// spec: Web Server - The PCB blob carries the resolved board design-rule scalars for a byte-identical client DRC
test "board-rule json carries fab-floor scalars and the perimeter mask width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts = [_]optimizer.Part{};
    var placement = optimizer.Placement{
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
    const opts = PcbDataOpts{ .read_only = false, .embed = false, .sub = null };

    // Defaults: every scalar at its DesignRules default. The unset (0)
    // copper_edge is omitted from the legacy "rules" object; the settings
    // panel's "design_rules" block deliberately lists every scalar, so the
    // absence check is scoped to the legacy object only.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeBlobHead(&aw.writer, alloc, View.init(placement), 0.127, placement, .{}, opts);
    const d = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, d, "\"min_drill\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"min_annular\":0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"hole_to_hole\":0.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"mask_margin\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"mask_web\":0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"min_width\":0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"clearance\":0.127") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"component_edge\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"perimeter_mask_width\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"perimeter_mask_net\":\"GND\"") != null);
    const legacy_start = std.mem.indexOf(u8, d, "\"rules\":{").?;
    const legacy_end = std.mem.indexOfScalarPos(u8, d, legacy_start, '}').?;
    try std.testing.expect(std.mem.indexOf(u8, d[legacy_start..legacy_end], "copper_edge") == null);

    // A (design-rules (copper-edge …)) override is emitted verbatim.
    placement.rules.design.edge.copper = 0.3;
    placement.rules.design.edge.component = 1.25;
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    placement.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .mask_width = 0.7,
        .net = "CHASSIS",
        .keepout = .{
            .clearance = 0.3,
            .blocks = .{ .components = true, .tracks = true, .vias = true },
            .allow_nets = &.{"GND"},
        },
    };
    var aw2: std.Io.Writer.Allocating = .init(alloc);
    try writeBlobHead(&aw2.writer, alloc, View.init(placement), 0.127, placement, .{}, opts);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"copper_edge\":0.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"component_edge\":1.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"perimeter_mask_width\":0.7") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"perimeter_mask_net\":\"CHASSIS\"") != null);

    // Each pour scalar is written EXACTLY ONCE into the one `rules` object.
    // Both were emitted twice with the same value until 2026-08-14 — harmless
    // only by luck, since a JSON object is last-wins and a future edit to
    // either site would have silently lost to the other. Distinctive values so
    // the surviving key is proved to carry the resolved rule, not a default.
    placement.rules.design.pour.min_width = 0.35;
    placement.rules.design.pour.corner_radius = 0.45;
    var aw3: std.Io.Writer.Allocating = .init(alloc);
    try writeBlobHead(&aw3.writer, alloc, View.init(placement), 0.127, placement, .{}, opts);
    const d3 = aw3.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, d3, "\"pour_min_width\":"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, d3, "\"pour_corner_radius\":"));
    try std.testing.expect(std.mem.indexOf(u8, d3, "\"pour_min_width\":0.35") != null);
    try std.testing.expect(std.mem.indexOf(u8, d3, "\"pour_corner_radius\":0.45") != null);
}

// spec: Web Server - The viewer adopts the shown layout as its edit target and keeps the address bar on that layout's permalink
test "the viewer adopts the shown layout and keeps the url on its permalink" {
    // The blob names the layout the server rendered…
    const page_src = @embedFile("pcb_layout_blob.zig");
    try std.testing.expect(std.mem.indexOf(u8, page_src, "\\\"shown_layout\\\":") != null);

    const js = @embedFile("assets/pcb_board.js");
    // …the viewer adopts it as the edit target, so Update / autosave write back
    // into the layout you opened instead of demanding a new name…
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!RO&&PCB.shown_layout)setActiveLayout(PCB.shown_layout);") != null);
    // …and every Load / Save re-points the address bar at that layout's link,
    // dropping the solve flags that would outrank it on a reload.
    try std.testing.expect(std.mem.indexOf(u8, js, "function syncLayoutUrl(nm)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "u.searchParams.set(\"layout\",nm)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "assembly.href=target") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "SOLVE_QS.forEach") != null);
    // The single-layout special case is gone: Save always asks for a name.
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.single") == null);
}
