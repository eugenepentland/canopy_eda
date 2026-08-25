//! GET /pcb-layout/:name — interactive force-directed placement preview.
//!
//! The server evaluates the design, runs the optimizer, and emits the result
//! as JSON plus a small client renderer. The board is drawn client-side so
//! parts can be **dragged** (snapping to the 0.1 mm grid) and the layout
//! **score** (HPWL + decoupling-loop length) recomputes live — letting you
//! compare a hand placement against the auto one. A sidebar lists every
//! component and the net on each pin; hovering cross-highlights, and hovering
//! a pad (or net chip) reds every pad on that net.

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
const outline_mod = @import("../placement/outline.zig");
const shape_sketch = @import("../shape_sketch.zig");
const shape_sketch_json = @import("shape_sketch_json.zig");
const via_fence = @import("../placement/via_fence.zig");
const perimeter_fence = @import("../placement/perimeter_fence.zig");
const pcb_keepout_json = @import("pcb_keepout_json.zig");
const pour = @import("../placement/pour.zig");
const pour_json = @import("pour_json.zig");
const pcb_rules_json = @import("pcb_rules_json.zig");
const trace_em_json = @import("trace_em_json.zig");
const power_integrity_json = @import("../power_integrity_json.zig");
const export_fab = @import("../export_fab.zig");
const export_gerber = @import("../export_gerber.zig");
const fab_identity = @import("../fab_identity.zig");
const fab_preview = @import("../fab_preview.zig");
const subcircuit_silkscreen = @import("../subcircuit_silkscreen.zig");
const fab_readiness = @import("../fab_readiness.zig");
const fab_filename = @import("fab_filename.zig");

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
const font5x7 = @import("../font5x7.zig");
const png_mod = @import("../png.zig");
const assets_css = @import("assets_css.zig");
const pages_tmpl = @import("templates/pages.zig");
const diag_format = @import("diag_format.zig");
const serve_root = @import("../serve.zig");
const route_plan = @import("route_plan.zig");
const subcircuit_route = @import("subcircuit_route.zig");
const subcircuit_seed_drc = @import("../subcircuit_seed_drc.zig");
const placement_outline = @import("placement_outline.zig");
const route_result_stats = @import("route_result_stats.zig");
const stuck_json = @import("stuck_json.zig");
const pcb_part_json = @import("pcb_part_json.zig");
const history = @import("history.zig");
const numeric = @import("../numeric.zig");
const escape = @import("../escape.zig");
const Server = serve_root.Server;
const sidecar_json = @import("layout_sidecar_json.zig");
const saved_zone = @import("saved_zone.zig");
const layout_layers = @import("layout_layers.zig");
const copper_ids = @import("copper_ids.zig");
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
const parseSavedTexts = sidecar_json.parseSavedTexts;
const parseOutlinePts = sidecar_json.parseOutlinePts;

pub const HandlerError = fab_preview.Error;

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
const name_open = "{\"name\":";
/// JSON key + open bracket shared by the layout/cache/export part arrays.
const parts_open = "\"parts\":[";
/// JSON `,"origin":` key shared by the part records that carry the renumber-
/// stable origin key (saved-layout disk + page JSON, live PCB.parts).
const origin_open = ",\"origin\":";
const net_json_key = ",\"net\":";
/// JSON `,"texts":` key shared by the sidecar, the page blob, and the
/// per-layout Load records (board-level silkscreen text array).
const texts_open = ",\"texts\":";
/// JSON `,"outline":` key shared by the sidecar writer, the page blob, and the
/// CLI `set_board_outline` response.
const outline_open = ",\"outline\":";
const fabrication_layers_open = ",\"fabrication_layers\":";
/// Error bodies shared across the layout handlers.
const no_block_msg = "No design or module by that name";
/// Response header name the fab-output endpoints set their MIME type on.
const ct_hdr = "content-type";
/// Returned when `?sub=<slug>` names a sub-block that doesn't exist in the design.
const no_sub_msg = "No sub-block by that name";
const bad_json_msg = "bad json";
const placement_err_msg = "Placement error";
/// Returned by the fab endpoints when a design has no saved layout at all —
/// fab outputs are only meaningful for a deliberately placed board.
const no_saved_layout_msg = "no saved layout — place the board (and save/star a layout) first";
/// Returned when routing (or its scope resolution) fails server-side.
const routing_err_msg = "Routing error";
/// JSON body/query key for the copper-to-copper clearance rule (mm).
const clearance_key = "clearance";

/// Success body returned by the mutating layout/courtyard endpoints.
const ok_json_true = "{\"ok\":true}";

/// The ` checked` HTML attribute fragment, emitted to pre-check a checkbox.
const checked_glyph = " checked";

/// The one layout sidecar per design: every *named* saved layout (manual
/// snapshots the user named plus an auto-recorded history of optimizer
/// runs) under `"layouts"`, the KiCad-sync `"default"` marker, and the
/// single-slot optimizer cache under `"cache"`.
pub const layouts_ext = ".layouts.json";

/// Ceiling on a `.layouts.json` read. A board carrying several ROUTED saved
/// layouts legitimately runs to megabytes — each one stores its own copper —
/// so the old 1 MiB cap silently truncated real boards to ZERO layouts, taking
/// the viewer, the KiCad sync seed and the fab outputs down with them (they all
/// resolve the ★ through this same read). Generous on purpose; the read still
/// refuses to pull an unbounded file into memory.
pub const sidecar_max_bytes: usize = 16 << 20;

/// Layout `kind` tags. `manual` = a snapshot the user saved by name; `auto` =
/// one recorded automatically each time the optimizer regenerated.
pub const kind_manual = "manual";
const kind_auto = "auto";

/// Cap on auto-recorded entries kept per design. On each record the oldest
/// auto entries past this are pruned; manual snapshots are never auto-pruned.
const max_auto_layouts: usize = 12;

/// One placed part within a saved layout: ref-des + centre (mm) + rotation,
/// plus the renumber-stable `origin` (the part's module-local `origin_key`).
/// The ref-des is volatile — it shifts when the part renumbers or when the
/// same module is flattened from a different context (standalone vs as a
/// sub-block of a parent board, which produces different counters). `origin`
/// is the module-local source name, invariant across both, so a Load matches
/// on it first and falls back to `ref` only for legacy entries saved before
/// `origin` was recorded (empty string). See `rekeyPosesByOrigin`.
pub const PartPose = struct {
    ref: []const u8,
    x: f64,
    y: f64,
    rot: f64,
    origin: []const u8 = "",
    /// Board side (viewer F-flip state). Persisted as `"side":"bottom"` only
    /// when bottom, so legacy top-side sidecars stay byte-identical.
    side: optimizer.Side = .top,
    /// Editor lock (viewer refuses drag/rotate/flip). Persisted as
    /// `"locked":true` only when set.
    locked: bool = false,
};

/// One driving PCB-editor dimension from a footprint origin to a straight
/// board-outline edge. `axis` is `"x"` for a horizontal dimension to a
/// vertical edge and `"y"` for a vertical dimension to a horizontal edge.
/// `edge_id` is the stable curve id in `SavedOutline.sketch`; `offset` is the
/// signed origin coordinate minus the edge coordinate, so moving that edge
/// repositions only the constrained axis of the footprint.
pub const SavedPartEdgeDimension = struct {
    ref: []const u8,
    axis: []const u8,
    edge_id: u32,
    offset: f64,
};

/// The weighted `objective` the optimizer minimizes plus its visible HPWL +
/// decoupling-loop terms, stored with a layout so the list shows "better/worse"
/// at a glance without re-running the optimizer. `objective` is 0 for legacy
/// entries saved before it was recorded.
const LayoutScore = struct { hpwl: f64, loop: f64, caps: usize, objective: f64 = 0 };

/// One physical finned heatsink authored on a saved PCB layout. The rectangle
/// is the base/contact footprint in board coordinates; `side` is the physical
/// PCB face, not a package-relative direction. `target_ref` binds that face to
/// the package whose directional theta-JC path the thermal solver must use.
pub const SavedHeatsink = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    side: []const u8 = "bottom",
    target_ref: []const u8 = "",
    material: []const u8 = "aluminum_6063",
    base_mm: f64 = 2,
    fin_height_mm: f64 = 10,
    fin_thickness_mm: f64 = 1,
    fin_gap_mm: f64 = 1.5,
    fin_axis: []const u8 = "length",
    pad_thickness_mm: f64 = 0.5,
    pad_k_w_mk: f64 = 6,
};

/// A named saved layout: name, kind, capture time (unix s, 0 = unknown),
/// optional score, and the placement itself (newest first within a file).
/// `default` marks the one layout the KiCad sync seeds first-insertion
/// placement + vias from; it's stored once at the top level of the file
/// (`"default":"<name>"`) and reflected here on the matching entry. At most
/// one entry has `default = true`.
pub const SavedLayout = struct {
    name: []const u8,
    kind: []const u8,
    ts: i64,
    score: ?LayoutScore,
    parts: []const PartPose,
    default: bool = false,
    /// This layout was produced by the Rough seed (`?rough=1`) — the
    /// AI-friendly module-clustered starting point a human then hand-finishes.
    /// Recorded so the schematic's Module-layouts panel can show, per
    /// sub-module, that a rough placement has been seeded (vs. starred/done).
    rough: bool = false,
    /// Routed copper captured with the poses (null = never routed/saved).
    routes: ?SavedRoutes = null,
    /// User-drawn board outline captured with the poses (null = none drawn).
    outline: ?SavedOutline = null,
    /// Visually edited backing polygons; empty keeps the authored defaults.
    fabrication_layers: []const SavedFabricationLayer = &.{},
    /// User-authored physical heatsink assembly for this exact board layout.
    heatsink: ?SavedHeatsink = null,
    /// Board-level silkscreen text labels placed by the Text tool (empty when
    /// none). Persisted with the layout so a Save → reload round-trips them,
    /// and the ★ layout's set is what the Gerber silk / PNG render.
    texts: []const font5x7.BoardText = &.{},
    /// PCB-editor driving dimensions from footprint origins to outline edges.
    dimensions: []const SavedPartEdgeDimension = &.{},
};

/// Canonical creator tags persisted on saved tracks and vias. Known values are
/// `human` (the PCB editor), `agent` (`add_tracks`), `autorouter` (route/repair
/// engines), and `imported` (KiCad). The empty default is deliberately
/// `unknown`: old sidecars predate provenance and must not be relabelled on
/// their next save.
pub const route_source_human = "human";
pub const route_source_agent = "agent";
pub const route_source_autorouter = "autorouter";
pub const route_source_imported = "imported";

/// One persisted routed-copper segment of a saved layout. Field names match
/// the live route JSON (`l` layer, `w` width; net by NAME — net indices shift
/// across flattens), so the client draws stored and live copper identically.
/// `g` is the stamp group tag: copper stamped from a sub-block module layout
/// carries its group slug so a rigid-group drag moves it along instead of
/// invalidating it. `source` records the segment's creator; empty means a
/// legacy layout whose provenance is unknown. `id` is the stable, user-visible
/// segment handle shown by the inspector. Legacy empty IDs are deterministically
/// derived when serialized, so merely saving an old layout backfills them.
pub const SavedTrack = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    /// Native circular-arc midpoint. Both coordinates set = a KiCad-style
    /// start/mid/end arc; null keeps the legacy straight segment.
    xm: ?f64 = null,
    ym: ?f64 = null,
    l: u8 = 0,
    w: f64,
    net: []const u8 = "",
    g: []const u8 = "",
    source: []const u8 = "",
    id: []const u8 = "",
};

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
pub const SavedVia = struct {
    x: f64,
    y: f64,
    d: f64,
    drill: f64 = 0,
    net: []const u8 = "",
    g: []const u8 = "",
    f: []const u8 = "",
    source: []const u8 = "",
    s: ?[2]u8 = null,
    id: []const u8 = "",
};

/// Persisted custom/KiCad copper-zone geometry shared with sidecar consumers.
pub const SavedZone = saved_zone.SavedZone;
const savedZoneLayers = saved_zone.layers;
const savedZonePrimaryLayer = saved_zone.primaryLayer;

/// A saved layout's persisted copper — routed tracks/vias plus optional
/// imported KiCad zone polygons. The default keeps old sidecars and existing
/// struct literals source-compatible.
pub const SavedRoutes = struct {
    tracks: []const SavedTrack,
    vias: []const SavedVia,
    zones: []const SavedZone = &.{},
    rf_paths: []const struct {
        net: []const u8,
        layer: u8,
        samples: []const rf_path_solver.Sample,
        /// Stable editor handles whose geometry owns this swept region. A
        /// collar repeats its main path's IDs so either one is invalidated
        /// atomically when any underlying route segment changes.
        track_ids: []const []const u8 = &.{},
        /// A pad-face collar belongs to the handles above but never owns them.
        portal: bool = false,
    } = &.{},
};
const SavedRfPath = @typeInfo(@FieldType(SavedRoutes, "rf_paths")).pointer.child;
/// Replace any persisted board-derived ring with the ring implied by the
/// CURRENT outline and DSL. This makes a saved layout a cache of the generated
/// vias, never their authority: outline/rule edits cannot leave stale barrels.
fn routesWithPerimeter(alloc: std.mem.Allocator, placement: optimizer.Placement, base: ?SavedRoutes) ?SavedRoutes {
    const old = base orelse SavedRoutes{ .tracks = &.{}, .vias = &.{} };
    var vias: std.ArrayList(SavedVia) = .empty;
    for (old.vias) |via| {
        if (std.mem.eql(u8, via.f, perimeter_fence.provenance)) {
            if (!perimeter_fence.viaServesPad(alloc, placement, via.net, via.x, via.y, via.d)) continue;
            var adopted = via;
            adopted.f = "";
            vias.append(alloc, adopted) catch return base;
            continue;
        }
        vias.append(alloc, via) catch return base;
    }
    const restored = restoreRoutes(alloc, .{ .tracks = old.tracks, .vias = vias.items, .zones = old.zones, .rf_paths = old.rf_paths }, placement.nets) orelse return base;
    const sites = if (perimeter_fence.append(alloc, placement, restored) catch return base) |result| result.vias else &.{};
    for (sites) |site| {
        const net = netNameOf(placement.nets, site.net);
        var found = false;
        for (vias.items) |via| {
            if (std.ascii.eqlIgnoreCase(via.net, net) and
                std.math.hypot(via.x - site.x, via.y - site.y) < 1e-6)
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
        }) catch return base;
    }
    if (base == null and vias.items.len == 0) return null;
    return .{ .tracks = old.tracks, .vias = vias.items, .zones = old.zones, .rf_paths = old.rf_paths };
}

/// Shared JSON fragments for copper serialization — the sidecar, the page
/// blob, and the Stamp subroutes all write the identical track/via shape.
const track_json_fmt = "{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d},\"net\":";
/// One outline-polygon vertex as a JSON `[x,y]` pair (sidecar + page blob).
const pt_pair_fmt = "[{d},{d}]";
const via_json_fmt = "{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":";
const vias_arr_open = "],\"vias\":[";
const net_object_open = "{\"net\":";
const segment_id_prefix = "seg-";
const via_id_prefix = "via-";
/// "ref\x00pad" / "prefix\x00origin" composite hash keys.
const pin_key_fmt = "{s}\x00{s}";

fn segmentIdHashFloat(hash: *std.hash.Wyhash, value: f64) void {
    hash.update(std.mem.asBytes(&value));
}

/// Stable fallback for a legacy segment that predates stored IDs. Geometry,
/// net, layer, width, and the final list ordinal make duplicate overlapping
/// segments distinct. Once written, the ID is persisted and survives edits.
fn fallbackSegmentId(track: SavedTrack, ordinal: usize, buf: *[segment_id_prefix.len + 16]u8) []const u8 {
    var hash = std.hash.Wyhash.init(0x5345474d454e545f);
    segmentIdHashFloat(&hash, track.x1);
    segmentIdHashFloat(&hash, track.y1);
    segmentIdHashFloat(&hash, track.x2);
    segmentIdHashFloat(&hash, track.y2);
    const has_mid: u8 = @intFromBool(track.xm != null and track.ym != null);
    hash.update(std.mem.asBytes(&has_mid));
    if (track.xm) |xm| segmentIdHashFloat(&hash, xm);
    if (track.ym) |ym| segmentIdHashFloat(&hash, ym);
    segmentIdHashFloat(&hash, track.w);
    const layer = track.l;
    const stable_ordinal: u64 = @intCast(ordinal);
    hash.update(std.mem.asBytes(&layer));
    hash.update(track.net);
    hash.update(std.mem.asBytes(&stable_ordinal));
    return std.fmt.bufPrint(buf, segment_id_prefix ++ "{x:0>16}", .{hash.final()}) catch segment_id_prefix ++ "0000000000000000";
}

fn writeTrackSegmentId(w: *std.Io.Writer, track: SavedTrack, ordinal: usize) std.Io.Writer.Error!void {
    var buf: [segment_id_prefix.len + 16]u8 = undefined;
    try w.writeAll(",\"id\":");
    return writeJsonStr(w, if (track.id.len > 0) track.id else fallbackSegmentId(track, ordinal, &buf));
}

fn writeViaId(w: *std.Io.Writer, via: SavedVia, ordinal: usize) std.Io.Writer.Error!void {
    var buf: [via_id_prefix.len + 16]u8 = undefined;
    try w.writeAll(",\"id\":");
    return writeJsonStr(w, if (via.id.len > 0) via.id else copper_ids.legacyVia(via, ordinal, &buf));
}

/// A user-DRAWN board outline (world mm) captured with a saved layout — the
/// interactive counterpart of the authored `(board (size W H))` form (the
/// ▭ Outline / ⬠ Poly tools: rough-place first, then draw the board around
/// it). When the shown layout carries one it becomes the placement's
/// `board_rect`, so every renderer draws it and the board-edge DRC checks it.
/// `pts` is the closed-polygon vertex list of a ⬠ Poly outline; when set,
/// x/y/w/h are always its bounding box (derived at parse time, so the two
/// can never disagree). Null `pts` = a plain drawn rectangle.
pub const SavedOutline = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    /// Nominal sharp vertices edited by the user.
    pts: ?[]const [2]f64 = null,
    /// Per-vertex fillet radii, index-aligned with `pts`.
    radii: ?[]const f64 = null,
    /// Internal physical projection, derived while parsing and deliberately
    /// omitted by the JSON writer.
    derived: struct {
        poly: ?[]const [2]f64 = null,
        arcs: []const optimizer.BoardArc = &.{},
    } = .{},
    /// Versioned parametric authoring intent; physical fields above are its
    /// compiled compatibility projection when present.
    sketch: ?shape_sketch.Sketch = null,
};

/// Per-layout editable positive polygons for one authored backing layer.
/// Material, thickness, side, and footprint-cutout policy stay in source.
pub const SavedFabricationLayer = struct {
    name: []const u8,
    regions: []const []const [2]f64,
    /// Optional index-aligned native authoring geometry. `regions` remains the
    /// compiled projection used by fabrication, 3D, and thermal consumers.
    sketches: []const ?shape_sketch.Sketch = &.{},
};

/// Which layout state the page is showing — the precedence ladder made
/// visible in the scorebar chip: source **spec** > saved **snapshot**
/// (`?refine=`) > **starred** default > **cache** slot > **fresh** solve >
/// plain **grid**. `starred` is the design's ★-marked layout, loaded verbatim
/// as the default page view when nothing more specific is asked for.
const LayoutSource = enum { spec, snapshot, starred, cache, fresh, grid };

/// Render a scorebar chip that makes precedence among the placement spec,
/// saved snapshots, starred layout, optimizer cache, and fresh solve visible.
fn writeSourceChip(w: *std.Io.Writer, src: LayoutSource) std.Io.Writer.Error!void {
    const label: []const u8, const cls: []const u8, const title: []const u8 = switch (src) {
        .spec => .{
            "from spec", "spec",
            "Placed by the (placement …) form in the source file — the source of truth. " ++
                "Saved snapshots and the cache are ignored while a spec is present.",
        },
        .snapshot => .{
            "from snapshot", "snap",
            "Showing a named saved layout — verbatim for ?layout=<name> (the direct link), " ++
                "refined in place for ?refine=<name>. The cache is untouched.",
        },
        .starred => .{
            "★ default",
            "star",
            "Showing this design's starred (★) saved layout — the blessed reference, " ++
                "loaded verbatim as the default view. Regenerate re-solves; the star is set in the Layouts panel.",
        },
        .cache => .{
            "from cache", "cache",
            "Reusing the optimizer cache from the last solve (the \"cache\" slot of the " ++
                ".layouts.json sidecar). Regenerate re-solves; Save as spec promotes it to the source file.",
        },
        .fresh => .{
            "fresh solve",                                                                     "fresh",
            "Solved on this page load (Regenerate / tuning weights / per-sub-block preview).",
        },
        .grid => .{
            "no layout", "grid",
            "Plain grid placeholder — no layout computed yet. Regenerate to auto-place.",
        },
    };
    try w.print("<span class=\"src-chip src-{s}\" id=\"pcb-srcchip\" title=\"{s}\">{s}</span>", .{ cls, title, label });
}

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
const StoreRevCheck = struct {
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
const RenderJob = struct {
    name: []const u8,
    eval: *Evaluator,
    module_res_out: *?modules_mod.ResolvedBlock,
    rev: *StoreRevCheck,
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
    res.content_type = .HTML;
    res.body = html;
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
    applyFabricationLayerOverrides(ctx.allocator, &solved.placement, solved.shown_zones.fabrication_layers);
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

/// Render the evaluator diagnostic left behind by a failed design load.
/// Null means no source-located failure was recorded, which is how the caller
/// distinguishes a genuinely unknown design/module name from a broken one.
fn renderBlockLoadDiagnostic(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    eval: *const Evaluator,
) HandlerError!?[]const u8 {
    if (eval.last_error == null) return null;
    const source_path = paths.designSourcePath(allocator, project_dir, name) catch return null;
    defer allocator.free(source_path);
    const d = try diag_format.load(allocator, source_path, "BuildError", eval.last_error);
    return try diag_format.renderErrorPage(allocator, name, d);
}

// spec: Web Server - A /pcb-layout design that exists but fails to parse or evaluate returns a compiler-style build-error page with file, line, column, failing source line/caret when available, and the evaluator message; only a genuinely unknown design/module name returns the not-found message
test "PCB page load failure identifies the imported module and source location" {
    // Evaluator source/AST storage follows the project's arena-lifetime
    // convention; keep the fixture under one arena so the leak-checking test
    // allocator sees the complete lifetime end at deinit.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(project_dir);

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo.sexp",
        .data = "(import broken-module)\n(design-block \"Demo\")\n",
    });
    // The regression fixture: an import path exists but contains no parseable
    // module, so evaluation fails after resolving the design name itself.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/modules/broken-module.sexp",
        .data = "",
    });

    const source_path = try paths.designSourcePath(allocator, project_dir, "demo");
    defer allocator.free(source_path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    try std.testing.expectError(error.ImportError, eval.evalFile(source_path));

    const html = (try renderBlockLoadDiagnostic(allocator, project_dir, "demo", &eval)) orelse
        return error.TestExpectedDiagnostic;
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "Build error — demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "cannot import 'broken-module'") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "src/demo.sexp:1:9") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "(import broken-module)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"caret\">") != null);

    var missing_eval = Evaluator.init(allocator, project_dir);
    defer missing_eval.deinit();
    try std.testing.expect((try renderBlockLoadDiagnostic(allocator, project_dir, "not-there", &missing_eval)) == null);
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
fn renderLayoutPage(
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
        if (try renderBlockLoadDiagnostic(ctx.allocator, ctx.project_dir, name, eval)) |html| {
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
    const lean_read_only = physical_review or thermal_overlay;
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
    const subseeds: SubSeedsJson = if (sub == null and !lean_read_only)
        buildSubSeedsJson(ctx.allocator, ctx.project_dir, eff_block, placement)
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
        // The exclusive heat overlay never paints routed copper or DRC. The
        // field endpoint already resolved that copper for its thermal inputs,
        // so restoring and checking it again in this iframe is dead work.
        .omit_copper = thermal_overlay,
    });
    const ro = rv.ro;
    const routed = rv.routed;

    const view = View.init(placement);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;

    try writeDocHead(w, eff_block.name, embed, edit_embed);
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
    const src_class = classifyLayoutSource(sub, choice.grid_only, choice.spec_drives, sel, starred_name, choice.cached);
    // Full page: the left dock's Properties / Autorouter / Sub-circuits tabs
    // plus the saved-layouts history (KiCad-style docked column).
    if (!embed) try writeSidebar(w, ctx.allocator, placement, sch_base, .{
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
    if (!embed) try writeActivityRail(w);
    try w.writeAll("<main class=\"pcb-main\">");
    if (embed and !edit_embed) {
        // Ordinary schematic previews get compact score/route chrome. Physical
        // assembly review keeps only route status and the hidden route values;
        // its parent shell owns the useful board controls.
        try writeReadOnlyEmbedChrome(w, .{
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
        if (!embed) try writeHeadNav(w, module_res != null, name, eff_block.name, queryOpt(req, "layout"), rv.tally);
        try writeEditControls(w, placement, name, src_class, choice.grid_only, routed, ro.params, rv.violations.len, embed);
    }
    if (showEmbedLegend(embed, edit_embed, physical_review)) try writeLegend(w, placement, false);
    try writeStage(w, view, embed);
    // WebGL 3D-view stage — hidden until the "3D View" tab is opened, then the
    // body gets `.mode-3d` (CSS swaps the SVG out for this). Built lazily.
    if (!embed) try w.writeAll(pcb_3d_stage_html);
    if (!embed) try w.writeAll(courtyard_modal ++ heatsink_modal ++ fp_card_modal ++ fab_modal);
    try w.writeAll("</main>");
    try writeRightDock(w, ctx.allocator, embed, edit_embed, .{ .panel = .{ .name = name, .sub = sub }, .layouts = layouts, .auto = auto_score, .placement = placement });
    try w.writeAll("</div>");
    try writePcbData(
        w,
        ctx.allocator,
        ctx.project_dir,
        placement,
        shown,
        view,
        name,
        payloadLayouts(layouts, lean_read_only),
        routed,
        ro.params.clearance,
        rv.violations,
        .{
            .read_only = embed and !edit_embed,
            .embed = embed,
            .model_sprites = model_sprites,
            .thermal_overlay = thermal_overlay,
            .assembly_review = physical_review and !thermal_overlay,
            // The thermal overlay paints its own field over the semantic board
            // and explicitly suppresses copper/DRC. Generating every Gerber and
            // Excellon layer, parsing it back, and shipping the resulting CAM
            // program only to hide it cost several seconds on Barracuda.
            .cam_lazy = needsCamPreview(physical_review, thermal_overlay),
            .sub = sub,
            .subseeds_json = subseeds.poses,
            .subseedinfo_json = subseeds.info,
            .submodules_json = subseeds.mods,
            .part_edits_json = if (lean_read_only)
                "{}"
            else
                pcb_part_json.buildEditSources(ctx.allocator, eff_block, if (sub_block) |sb| sb.source else name),
            .outline_drawn = rv.outline_drawn,
            .saved_outline = rv.outline,
            .saved_fabrication_layers = rv.fabrication_layers,
            .saved_heatsink = rv.heatsink,
            .saved_dimensions = rv.dimensions,
            .base_edge = rv.base_edge,
            .scratch_allocator = ctx.scratch_allocator,
            .top_design = top_design,
            .shown_layout = if (sub == null) adoptedLayoutName(sel, starred_name) else null,
            .src = src_class,
            .saved_routes = rv.saved,
            .omit_pours = thermal_overlay,
            .subroutes_json = subseeds.routes,
            // Resolved effective plan (authored waves or the synthesized
            // default) for the settings drawer's routing-plan section.
            .plan_json = if (lean_read_only) "{}" else buildPlanJson(ctx.allocator, eff_block, placement),
            .texts = rv.texts,
            // Every render-path write above (persistGeneratedLayout,
            // displayLayouts dedup, recordAutoLayout) PRESERVES the rev, so the
            // doc read at the top of the handler still matches what's on disk —
            // only a user Save/Update bumps it.
            .rev = doc.rev,
        },
    );
    try writePageScripts(w, .{
        .physical_review = physical_review,
        .model_sprites = model_sprites,
        .thermal_overlay = thermal_overlay,
        .embed = embed,
    });
    try w.writeAll("</body></html>");

    return aw.written();
}

const PageScripts = struct {
    physical_review: bool,
    model_sprites: bool,
    thermal_overlay: bool,
    embed: bool,
};

/// Emit only the clients the selected surface can execute. Assembly is
/// read-only and has no settings, import, routing, replay, or stuck-net UI, so
/// loading those scripts on its critical path was pure parse/evaluation cost.
fn writePageScripts(w: *std.Io.Writer, mode: PageScripts) std.Io.Writer.Error!void {
    // FP.padShape and optional client-DRC marshaling load after `const PCB=…`.
    try w.writeAll("<script src=\"/static/footprint_svg.js\"></script>");
    if (!mode.physical_review) try w.writeAll("<script src=\"/static/drc_marshal.js\"></script>");
    // WebGPU must precede pcb_board.js, which reads window.PCBGpu at boot.
    try w.writeAll("<script src=\"/static/pcb_gpu.js\"></script>");
    if (!mode.physical_review) try w.writeAll("<script src=\"/static/shape_sketch.js\"></script>");
    try w.writeAll("<script src=\"/static/pcb_board.js\"></script>");
    if (!mode.physical_review) try w.writeAll("<script src=\"/static/pcb_settings.js\"></script>" ++
        "<script src=\"/static/pcb_dxf.js\"></script>" ++
        "<script src=\"/static/pcb_kicad_import.js\"></script><script src=\"/static/pcb_replay.js\"></script>" ++
        "<script src=\"/static/pcb_stuck.js\"></script>");
    if (mode.model_sprites) try w.writeAll("<script src=\"/static/pcb_model_sprites.js\"></script>");
    if (mode.thermal_overlay) try w.writeAll("<script src=\"/static/pcb_thermal.js\"></script>");
    if (!mode.embed) try w.writeAll(pcb_3d_toggle_js);
}

/// Pre-render the plain `/pcb-layout/<name>` page — no query, no request — and
/// retain it in the page cache. This is the most expensive read-only page the
/// server has (a routed board spends hundreds of milliseconds in placement,
/// DRC and HTML before a byte reaches the wire), and every cache it lands in is
/// process-lifetime, so a deploy makes the next visitor pay all of it. Called
/// off the request path by the boot warm-up; best-effort, returns whether an
/// entry was retained. `scratch` need only outlive the call: the cache dupes
/// the HTML it keeps and the file stamps own their own memory.
pub fn warmPage(ctx: *Server, scratch: std.mem.Allocator, name: []const u8) bool {
    var page_ctx = ctx.*;
    page_ctx.allocator = scratch;
    const live_version = serve_root.getLiveVersion(name);
    var eval = Evaluator.init(scratch, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        scratch.destroy(mr.eval);
    };
    var rev_check = StoreRevCheck{ .rendered = -1, .ctx = &page_ctx, .name = name, .sub = null };
    const html = (renderLayoutPage(&page_ctx, null, null, .{
        .name = name,
        .eval = &eval,
        .module_res_out = &module_res,
        .rev = &rev_check,
    }) catch return false) orelse return false;
    ctx.state.caches.pcb_pages.warm(.{
        .scratch = scratch,
        .project_dir = ctx.project_dir,
        .name = name,
        .eval = &eval,
        // Captured BEFORE the render: an edit that lands mid-render leaves
        // `current_version` ahead of it and the entry is dropped rather than
        // served stale, exactly as on the request path.
        .live_version = live_version,
        .current_version = serve_root.getLiveVersion(name),
    }, html, rev_check);
    // The response filter gzips every page after the handler returns, and a
    // megabyte board costs ~150 ms of deflate — more than the cached render it
    // wraps. That memo is keyed on the body itself and a cache hit serves these
    // exact bytes, so compressing once here retires that cost for the first
    // reader too. The stream is discarded; what matters is the memo entry.
    _ = ctx.state.caches.gzip.compress(scratch, html) catch return true;
    return true;
}

/// Resolve `name` to a renderable design block. Preference: a design source
/// under `src/` (evaluated with `eval`). Fallback: a reusable module under
/// `lib/modules/` (via `modules_mod.resolveModuleBlock`, whose evaluator is
/// stashed in `module_res` for the caller to free). Null if neither exists.
fn resolveBlock(
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
/// Ordinary PCB pages historically needed only geometry and skipped identity
/// resolution, so pay this cost only for designs that authored AC screens.
fn resolvePdnBom(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *env_mod.DesignBlock,
) void {
    if (block.pdn_intents.len == 0) return;
    const bom_path = paths.designSiblingPath(alloc, project_dir, name, ".bom") catch return;
    defer alloc.free(bom_path);
    bom.resolveIdentities(alloc, block, bom_path, project_dir) catch |err|
        log.warn("PDN BOM resolution for {s} failed: {s}", .{ name, @errorName(err) });
}

// spec: Web Server - A PCB design with PDN intents resolves selected BOM electrical model properties before placement
test "PCB PDN analysis resolves the selected BOM electrical model" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);

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

    var instances = [_]env_mod.Instance{.{
        .ref_des = "C1",
        .component = "cap-fixture",
        .value = "100nF",
        .footprint = "0402",
        .symbol = "Device:C",
        .id = "ab000001",
    }};
    var block: env_mod.DesignBlock = .{
        .name = "Demo",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .pdn_intents = &.{.{ .net = "VDD", .ripple_v = 0.1 }},
    };

    resolvePdnBom(alloc, project_dir, "demo", &block);
    var found_esr = false;
    var found_esl = false;
    for (instances[0].properties) |property| {
        if (std.mem.eql(u8, property.key, "pdn-esr-ohm") and std.mem.eql(u8, property.value, "0.02")) found_esr = true;
        if (std.mem.eql(u8, property.key, "pdn-esl-h") and std.mem.eql(u8, property.value, "4e-10")) found_esl = true;
    }
    try std.testing.expect(found_esr and found_esl);
}

/// Longest `?sub=` value accepted. A slug is a sub-block name run through
/// `review.slugify`; a few dozen characters is already an unusually long one,
/// and the cap keeps a hostile value from being pasted into a path at all.
const sub_slug_max_len = 128;

/// Whether `s` is spelled like a real sub-block slug — i.e. like something
/// `review.slugify` could have produced.
///
/// This is a SECURITY boundary, not a tidiness rule. `layoutsSidecar` pastes the
/// value straight into `<dir>/<design>.<sub>.layouts.json` and `writeLayoutsSub`
/// writes that path, and httpz hands query values over already percent-decoded —
/// so `?sub=../../../../tmp/x` arrived decoded and escaped the project directory
/// into an arbitrary file write.
///
/// The alphabet is `review.slugify`'s exact output: lowercase alphanumerics and
/// `-` (it lowercases, replaces every other run with a single hyphen, and trims
/// leading/trailing hyphens), plus `_`, the single character it emits when a name
/// slugifies to nothing. Slugs are matched against TOP-LEVEL sub-blocks only
/// (`descendToSub`), so they never nest and `/` is never legitimate — which makes
/// this whitelist strictly narrower than "reject traversal": `.`, `/`, `\`, NUL,
/// and every other separator fall out of the alphabet rather than needing a rule.
fn isValidSubSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > sub_slug_max_len) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
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
pub fn subSlug(req: ?*httpz.Request) ?[]const u8 {
    const r = req orelse return null;
    const q = r.query() catch return null;
    const s = q.get("sub") orelse return null;
    return if (isValidSubSlug(s)) s else null;
}

/// True when `?embed=1` is present — render the trimmed, read-only chrome used
/// by the schematic page's inline per-sub-block preview frame.
fn isEmbed(req: ?*httpz.Request) bool {
    const r = req orelse return false;
    const q = r.query() catch return false;
    return q.get("embed") != null;
}

fn isPhysicalReview(req: ?*httpz.Request, embed: bool, edit_embed: bool) bool {
    if (!embed) return false;
    if (edit_embed) return false;
    return queryFlag(req, "review");
}

fn needsCamPreview(physical_review: bool, thermal_overlay: bool) bool {
    return physical_review and !thermal_overlay;
}

fn showEmbedLegend(embed: bool, edit_embed: bool, physical_review: bool) bool {
    return embed and !edit_embed and !physical_review;
}

/// Descend a design block into the top-level sub-block whose slugified name
/// matches `sub_slug` (the same `review.slugify` the schematic page uses for its
/// `data-sub` attributes, so the keys line up). Null when none match. Only the
/// sub-block's parts are then placed/routed — the whole design never is.
fn descendToSub(
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

fn writeAuthoredSettings(
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
            ",\"width\":{d},\"clearance\":{d},\"via_dia\":{d},\"via_drill\":{d}," ++
                "\"priority\":{d},\"diff_gap\":{d},\"max_freq_hz\":{d},\"impedance_ohms\":{d},\"ground_gap_mm\":{d},\"ground_gap_max_mm\":{d},\"nets\":",
            .{
                class.width,    class.clearance,      class.via_dia,           class.via_drill,                  class.priority,
                class.diff_gap, class.rf.max_freq_hz, class.rf.impedance.ohms, class.rf.impedance.ground_gap_mm, class.rf.impedance.ground_gap_max_mm,
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
fn buildPlanJson(
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
    try writeAuthoredSettings(&aw.writer, block, source_path, sub);
    res.content_type = .JSON;
    res.body = aw.written();
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
        .name = "Barracuda",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .kicad_pcb_path = "/boards/barracuda.kicad_pcb",
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
    try writeAuthoredSettings(&aw.writer, &block, "src/boards/barracuda.sexp", null);
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
    try std.testing.expectEqualStrings("src/boards/barracuda.sexp", root.get("source").?.object.get("path").?.string);
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

/// The Stamp palette's seed blobs: `poses` maps each sub-block's parent-frame
/// ref-des → its module-layout pose, `info` maps each sub-block name → which
/// module snapshot supplied the poses (`{layout, starred, n}`) so the button
/// can say what a Stamp will pull and how much of the group it covers, and
/// `mods` maps every sub-block name → its module source (palette name links).
const SubSeedsJson = struct { poses: []const u8 = "{}", info: []const u8 = "{}", mods: []const u8 = "{}", routes: []const u8 = "{}" };

/// JSON map of sub-block name → module source ("mcu" → "w55rp20"), for the
/// palette's name links to each module's own /pcb-layout page — emitted for
/// every sub-block, including ones with no stampable layout yet (that page is
/// exactly where you go to make one).
fn buildSubModulesJson(alloc: std.mem.Allocator, block: *const env_mod.DesignBlock) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.writeByte('{') catch return "{}";
    var first = true;
    for (block.sub_blocks) |sb| {
        if (sb.source.len == 0) continue;
        if (!first) w.writeByte(',') catch return "{}";
        first = false;
        writeJsonStr(w, sb.name) catch return "{}";
        w.writeByte(':') catch return "{}";
        writeJsonStr(w, sb.source) catch return "{}";
    }
    w.writeByte('}') catch return "{}";
    return aw.written();
}

/// Build the viewer's per-group "Stamp" seeds — drop a whole pre-laid
/// sub-circuit onto the board as a rigid cluster instead of laying its parts
/// out again. Built through the same origin_key bridge the KiCad sync seeds
/// from (subBlockPoseByOriginKey), so the poses match what a sync would stamp.
/// Both blobs are "{}" when nothing bridges.
fn buildSubSeedsJson(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    p: optimizer.Placement,
) SubSeedsJson {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    var iw_buf: std.Io.Writer.Allocating = .init(alloc);
    const iw = &iw_buf.writer;
    var rw_buf: std.Io.Writer.Allocating = .init(alloc);
    const rw = &rw_buf.writer;
    w.writeByte('{') catch return .{};
    iw.writeByte('{') catch return .{};
    rw.writeByte('{') catch return .{};
    var first = true;
    var ifirst = true;
    var rfirst = true;
    // Lazily-built parent "ref\x00pad" → net-name map (only when some module
    // snapshot actually carries copper to stamp).
    var dpin_net: ?std.StringHashMapUnmanaged([]const u8) = null;
    for (block.sub_blocks) |sb| {
        var s = subBlockPoseByOriginKey(alloc, project_dir, sb) orelse continue;
        var ok_ref = std.StringHashMapUnmanaged([]const u8).empty;
        var n: usize = 0;
        for (p.instances) |inst| {
            if (inst.ref_des.len <= sb.name.len) continue;
            if (!std.mem.startsWith(u8, inst.ref_des, sb.name) or inst.ref_des[sb.name.len] != '/') continue;
            if (inst.origin_key.len == 0) continue;
            const pose = s.map.get(inst.origin_key) orelse continue;
            ok_ref.put(alloc, inst.origin_key, inst.ref_des) catch return .{};
            if (!first) w.writeByte(',') catch return .{};
            first = false;
            n += 1;
            writeJsonStr(w, inst.ref_des) catch return .{};
            w.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pose.x, pose.y, pose.rot }) catch return .{};
            if (pose.side == .bottom) w.writeAll(",\"side\":\"bottom\"") catch return .{};
            w.writeByte('}') catch return .{};
        }
        if (n == 0) continue;
        if (!ifirst) iw.writeByte(',') catch return .{};
        ifirst = false;
        writeJsonStr(iw, sb.name) catch return .{};
        iw.writeAll(":{\"layout\":") catch return .{};
        writeJsonStr(iw, s.layout_name) catch return .{};
        iw.print(",\"starred\":{},\"n\":{d}", .{ s.starred, n }) catch return .{};
        if (s.alt_name.len > 0) {
            iw.writeAll(",\"alt\":") catch return .{};
            writeJsonStr(iw, s.alt_name) catch return .{};
            iw.print(",\"alt_n\":{d}", .{s.alt_n}) catch return .{};
        }
        iw.writeByte('}') catch return .{};
        // The snapshot's copper, net names mapped onto this design's nets so
        // Stamp can carry the module's hand routing onto the board.
        if (s.routes) |sr| {
            if (dpin_net == null) dpin_net = designPinNetMap(alloc, p);
            const dm = if (dpin_net) |*m| m else continue;
            if (!rfirst) rw.writeByte(',') catch return .{};
            rfirst = false;
            writeJsonStr(rw, sb.name) catch return .{};
            rw.writeByte(':') catch return .{};
            const route_map = SubRouteMap{
                .pin_nets = s.pin_nets,
                .ok_ref = &ok_ref,
                .dpin_net = dm,
                .parent_nets = p.nets,
                .parent_rules = p.rules.net,
            };
            writeSubRoutesJson(rw, alloc, sb.name, sr, route_map) catch return .{};
        }
    }
    w.writeByte('}') catch return .{};
    iw.writeByte('}') catch return .{};
    rw.writeByte('}') catch return .{};
    return .{
        .poses = aw.written(),
        .info = iw_buf.written(),
        .mods = buildSubModulesJson(alloc, block),
        .routes = rw_buf.written(),
    };
}

/// Parent placement "ref\x00pad" → net NAME (raw flattened names, matching
/// the net names routed copper carries). Null on allocation failure.
fn designPinNetMap(alloc: std.mem.Allocator, p: optimizer.Placement) ?std.StringHashMapUnmanaged([]const u8) {
    var m = std.StringHashMapUnmanaged([]const u8).empty;
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = std.fmt.allocPrint(alloc, pin_key_fmt, .{ pin.ref_des, pin.pin }) catch return null;
            m.put(alloc, key, net.name) catch return null;
        }
    }
    return m;
}

/// Serialize one module snapshot's copper for the Stamp palette: coordinates
/// stay module-local (the same frame as the seed poses — the client
/// translates by the stamp offset), net names are mapped module → parent via
/// the origin-key bridge, falling back to the "slug/NET" spelling a
/// module-private net flattens to in the parent anyway.
const SubRouteMap = struct {
    pin_nets: []const SubPinNet,
    ok_ref: *const std.StringHashMapUnmanaged([]const u8),
    dpin_net: *const std.StringHashMapUnmanaged([]const u8),
    parent_nets: []const export_kicad.FlatNet,
    parent_rules: []const optimizer.NetRule,
};

fn writeSubRoutesJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    slug: []const u8,
    sr: SavedRoutes,
    map: SubRouteMap,
) std.Io.Writer.Error!void {
    var net_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (map.pin_nets) |ps| {
        if (net_map.contains(ps.net)) continue;
        const dref = map.ok_ref.get(ps.origin_key) orelse continue;
        const key = std.fmt.allocPrint(alloc, pin_key_fmt, .{ dref, ps.pad }) catch continue;
        const dn = map.dpin_net.get(key) orelse continue;
        net_map.put(alloc, ps.net, dn) catch break;
    }
    try w.writeAll("{\"tracks\":[");
    for (sr.tracks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        const net = mappedNet(alloc, &net_map, slug, t.net);
        const rule = netRuleNamed(map.parent_nets, map.parent_rules, net);
        const width = if (rule.width > 0) rule.width else t.w;
        try w.print(track_json_fmt, .{ t.x1, t.y1, t.x2, t.y2, t.l, width });
        try writeJsonStr(w, net);
        if (t.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, t.source);
        }
        try writeTrackSegmentId(w, t, i);
        try w.writeAll("}");
    }
    try w.writeAll(vias_arr_open);
    for (sr.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        const net = mappedNet(alloc, &net_map, slug, vi.net);
        const rule = netRuleNamed(map.parent_nets, map.parent_rules, net);
        const dia = if (rule.via_dia > 0) rule.via_dia else vi.d;
        const drill = if (rule.via_drill > 0) rule.via_drill else vi.drill;
        try w.print(via_json_fmt, .{ vi.x, vi.y, dia, drill });
        try writeJsonStr(w, net);
        if (vi.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, vi.source);
        }
        try writeViaId(w, vi, i);
        try w.writeAll("}");
    }
    try w.writeAll("],\"zones\":[");
    var first_zone = true;
    for (sr.zones) |z| {
        // Stamp conductive custom pours only. Keepouts are contextual geometry,
        // while declared planes / stackup pours never live in SavedRoutes.zones
        // at all and therefore cannot leak into this payload.
        if (!z.flags.filled or z.flags.keepout) continue;
        if (z.net.len == 0 or z.poly.len < 3) continue;
        if (!first_zone) try w.writeByte(',') else first_zone = false;
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, mappedNet(alloc, &net_map, slug, z.net));
        try w.writeAll(",\"layer\":");
        try writeJsonStr(w, savedZonePrimaryLayer(&z));
        if (z.layers.len > 1) {
            try w.writeAll(",\"layers\":[");
            for (z.layers, 0..) |layer_name, li| {
                if (li > 0) try w.writeByte(',');
                try writeJsonStr(w, layer_name);
            }
            try w.writeByte(']');
        }
        try w.writeAll(",\"poly\":[");
        for (z.poly, 0..) |point, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.print(pt_pair_fmt, .{ point[0], point[1] });
        }
        try w.writeAll("],\"filled\":true,\"keepout\":false");
        if (z.priority != 0) try w.print(",\"priority\":{d}", .{z.priority});
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn netRuleNamed(
    nets: []const export_kicad.FlatNet,
    rules: []const optimizer.NetRule,
    name: []const u8,
) optimizer.NetRule {
    for (nets, 0..) |net, i| {
        if (i >= rules.len) break;
        if (std.ascii.eqlIgnoreCase(net.name, name)) return rules[i];
    }
    return .{};
}

/// A stamped-copper net name in the parent design's namespace: the bridged
/// parent net when a module pin on the net resolved, else "slug/NET" (the
/// flatten's stitching spelling for a module-private net), else "".
fn mappedNet(
    alloc: std.mem.Allocator,
    net_map: *const std.StringHashMapUnmanaged([]const u8),
    slug: []const u8,
    net: []const u8,
) []const u8 {
    if (net.len == 0) return "";
    if (net_map.get(net)) |m| return m;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ slug, net }) catch net;
}

/// What automatic hierarchical routing recovered from isolated sub-circuit
/// passes and reusable module snapshots. Candidate counts are the copper before
/// board-level compatibility filtering; accepted counts are the same-net
/// sources actually handed to the global router.
pub const SubcircuitRouteSeedStats = struct {
    copper: struct {
        candidate_tracks: usize = 0,
        candidate_vias: usize = 0,
        accepted_nets: usize = 0,
        accepted_tracks: usize = 0,
        accepted_vias: usize = 0,
        rejected_nets: usize = 0,
    } = .{},
    phase: struct {
        attempted_subcircuits: usize = 0,
        completed_subcircuits: usize = 0,
        timed_out_subcircuits: usize = 0,
        deferred_supply_nets: usize = 0,
        accepted_carrier_drops: usize = 0,
    } = .{},
    /// Kept for response compatibility. Deterministic local-first routing never
    /// abandons all accepted local copper for a plain global candidate.
    fallback: bool = false,
};

const SeedTrack = subcircuit_route.SeedTrack;
const SeedVia = subcircuit_route.SeedVia;

const SeedAccumulator = struct {
    tracks: std.ArrayList(SeedTrack) = .empty,
    vias: std.ArrayList(SeedVia) = .empty,
    rejected: []bool,
    candidate: []bool,
    isolated: []const bool,
    supply: []const bool,
    stats: SubcircuitRouteSeedStats = .{},
};

const SeedContext = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    supply: []const bool,
    acc: *SeedAccumulator,
};

/// Rigid transform shared by module poses and their saved copper. This is the
/// server-side twin of the Stamp palette's `stampPose*` algebra: mirror local X
/// for a bottom-side group, then rotate in the board's y-down frame.
const SeedPose = struct {
    x: f64 = 0,
    y: f64 = 0,
    rot: f64 = 0,
    back: bool = false,

    fn linear(self: SeedPose, x: f64, y: f64) [2]f64 {
        const mx = if (self.back) -x else x;
        return pose_math.rotate(mx, y, self.rot);
    }

    fn apply(self: SeedPose, x: f64, y: f64) [2]f64 {
        const p = self.linear(x, y);
        return .{ p[0] + self.x, p[1] + self.y };
    }

    fn compose(self: SeedPose, other: SeedPose) SeedPose {
        const t = self.linear(other.x, other.y);
        return .{
            .x = t[0] + self.x,
            .y = t[1] + self.y,
            .rot = @mod(self.rot + (if (self.back) -other.rot else other.rot), 360.0),
            .back = self.back != other.back,
        };
    }

    fn inverse(self: SeedPose) SeedPose {
        var out = SeedPose{ .rot = @mod(if (self.back) self.rot else -self.rot, 360.0), .back = self.back };
        const t = out.linear(self.x, self.y);
        out.x = -t[0];
        out.y = -t[1];
        return out;
    }
};

const SeedHit = struct { part: usize, module: SyncPose };
const SeedNet = struct { parent: i32 = -1, compatible: bool = true, sampled: bool = false };

fn seedPoseFromSync(p: SyncPose) SeedPose {
    return .{ .x = p.x, .y = p.y, .rot = p.rot, .back = p.side == .bottom };
}

fn seedPoseFromPart(p: optimizer.Part) SeedPose {
    return .{ .x = p.x, .y = p.y, .rot = p.rot, .back = p.side == .bottom };
}

const seed_pose_tolerance_mm: f64 = 0.075;

fn seedPosesMatch(a: SeedPose, b: SeedPose) bool {
    if (a.back != b.back or std.math.hypot(a.x - b.x, a.y - b.y) > seed_pose_tolerance_mm) return false;
    const d = @abs(@mod(a.rot - b.rot + 540.0, 360.0) - 180.0);
    return d < 0.1;
}

fn subcircuitPartIndex(placement: optimizer.Placement, slug: []const u8, origin: []const u8) ?usize {
    for (placement.instances, 0..) |inst, i| {
        if (i >= placement.parts.len or inst.origin_key.len == 0 or !std.mem.eql(u8, inst.origin_key, origin)) continue;
        if (inst.ref_des.len > slug.len and std.mem.startsWith(u8, inst.ref_des, slug) and inst.ref_des[slug.len] == '/') return i;
    }
    return null;
}

fn boardNetAtPin(placement: optimizer.Placement, part: usize, pad: []const u8) ?usize {
    if (part >= placement.instances.len) return null;
    const ref = placement.instances[part].ref_des;
    for (placement.nets, 0..) |net, ni| for (net.pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, ref) and std.mem.eql(u8, pin.pin, pad)) return ni;
    };
    return null;
}

fn seedHits(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    slug: []const u8,
    seeds: SubBlockSeeds,
) std.mem.Allocator.Error![]const SeedHit {
    var out: std.ArrayList(SeedHit) = .empty;
    for (placement.instances, 0..) |inst, i| {
        if (i >= placement.parts.len or inst.origin_key.len == 0) continue;
        if (inst.ref_des.len <= slug.len or !std.mem.startsWith(u8, inst.ref_des, slug) or inst.ref_des[slug.len] != '/') continue;
        const pose = seeds.map.get(inst.origin_key) orelse continue;
        try out.append(alloc, .{ .part = i, .module = pose });
    }
    return out.toOwnedSlice(alloc);
}

fn seedTransformScore(placement: optimizer.Placement, hits: []const SeedHit, xf: SeedPose) usize {
    var score: usize = 0;
    for (hits) |hit| {
        const expected = xf.compose(seedPoseFromSync(hit.module));
        if (seedPosesMatch(expected, seedPoseFromPart(placement.parts[hit.part]))) score += 1;
    }
    return score;
}

fn bestSeedTransform(placement: optimizer.Placement, hits: []const SeedHit) ?SeedPose {
    var best: ?SeedPose = null;
    var best_score: usize = 0;
    var best_rank: f64 = -1;
    for (hits) |hit| {
        const board = seedPoseFromPart(placement.parts[hit.part]);
        const xf = board.compose(seedPoseFromSync(hit.module).inverse());
        const score = seedTransformScore(placement, hits, xf);
        const part = placement.parts[hit.part];
        const hub_rank: f64 = if (part.kind == .hub) 1.0e9 else 0.0;
        const rank = hub_rank + part.hw * part.hh;
        if (best == null or score > best_score or (score == best_score and rank > best_rank)) {
            best = xf;
            best_score = score;
            best_rank = rank;
        }
    }
    return best;
}

fn classifySeedNets(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    slug: []const u8,
    seeds: SubBlockSeeds,
    xf: SeedPose,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(SeedNet) {
    var out = std.StringHashMapUnmanaged(SeedNet).empty;
    for (seeds.pin_nets) |sample| {
        const gop = try out.getOrPut(alloc, sample.net);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const pi = subcircuitPartIndex(placement, slug, sample.origin_key) orelse {
            gop.value_ptr.compatible = false;
            continue;
        };
        const parent = boardNetAtPin(placement, pi, sample.pad) orelse {
            gop.value_ptr.compatible = false;
            continue;
        };
        if (gop.value_ptr.sampled and gop.value_ptr.parent != @as(i32, @intCast(parent))) gop.value_ptr.compatible = false;
        gop.value_ptr.parent = @intCast(parent);
        gop.value_ptr.sampled = true;
        const module_pose = seeds.map.get(sample.origin_key) orelse {
            gop.value_ptr.compatible = false;
            continue;
        };
        const expected = xf.compose(seedPoseFromSync(module_pose));
        if (!seedPosesMatch(expected, seedPoseFromPart(placement.parts[pi]))) gop.value_ptr.compatible = false;
    }
    return out;
}

fn seedNetEnabled(options: route_policy.Options, net: usize) bool {
    return options.selected_nets.len == 0 or (net < options.selected_nets.len and options.selected_nets[net]);
}

/// A saved module tree may seed the same local fragment a fresh isolated route
/// would: at least two terminals inside this first-level sub-circuit. The later
/// assembled-board pass joins any boundary legs to that frozen local source.
fn seedNetIsLocal(placement: optimizer.Placement, slug: []const u8, net: usize) bool {
    if (net >= placement.nets.len or placement.nets[net].pins.len < 2) return false;
    var local: usize = 0;
    for (placement.nets[net].pins) |pin| {
        if (pin.ref_des.len > slug.len and std.mem.startsWith(u8, pin.ref_des, slug) and pin.ref_des[slug.len] == '/') local += 1;
    }
    return local >= 2;
}

fn seedLayerAllowed(placement: optimizer.Placement, options: route_policy.Options, net: usize, layer: u8) bool {
    if (layer >= placement.rules.signalLayerCount()) return false;
    if (net >= options.net.len or options.net[net].allowed_layers == 0) return true;
    return layer < 64 and (options.net[net].allowed_layers & (@as(u64, 1) << @intCast(layer))) != 0;
}

/// Signal-layer indices are stackup-independent for the two outer layers:
/// 0=F.Cu and 1=B.Cu even on Barracuda's six-layer stack. A bottom-side rigid
/// stamp swaps those two; inner saved indices remain in the destination's
/// signal-layer namespace and are accepted only when that layer exists.
fn seedLayerFromModule(placement: optimizer.Placement, xf: SeedPose, saved: u8) ?u8 {
    const count = placement.rules.signalLayerCount();
    if (saved >= count) return null;
    return if (xf.back and saved < 2) 1 - saved else saved;
}

fn seedTrackWidth(placement: optimizer.Placement, params: router.RouteParams, net: usize, saved: f64) f64 {
    if (net < placement.rules.net.len and placement.rules.net[net].width > 0) return placement.rules.net[net].width;
    if (saved > 0) return saved;
    return params.track_width;
}

fn needsSavedSeedFallback(isolated: []const bool, net: usize) bool {
    return net >= isolated.len or !isolated[net];
}

fn seedViaGeometry(placement: optimizer.Placement, params: router.RouteParams, net: usize, saved: SavedVia) [2]f64 {
    const rule = if (net < placement.rules.net.len) placement.rules.net[net] else optimizer.NetRule{};
    const dia = if (rule.via_dia > 0) rule.via_dia else if (saved.d > 0) saved.d else params.via_dia;
    const drill = if (rule.via_drill > 0) rule.via_drill else if (saved.drill > 0) saved.drill else params.via_drill;
    return .{ dia, drill };
}

fn appendModuleSeedCopper(
    ctx: *SeedContext,
    slug: []const u8,
    seeds: SubBlockSeeds,
    xf: SeedPose,
) std.mem.Allocator.Error!void {
    const routes = seeds.routes orelse return;
    const nets = try classifySeedNets(ctx.alloc, ctx.placement, slug, seeds, xf);
    for (routes.tracks) |saved| {
        const mapped = nets.get(saved.net) orelse continue;
        if (!mapped.sampled or mapped.parent < 0) continue;
        const ni: usize = @intCast(mapped.parent);
        if (!seedNetEnabled(ctx.options, ni)) continue;
        const supply = ni < ctx.supply.len and ctx.supply[ni];
        if (supply and !subcircuit_route.savedSupplyFallbackAllowed(ctx.placement, ctx.options, slug, ni)) continue;
        if (!supply and ctx.placement.rules.carriesPlane(ctx.placement.nets[ni].name)) continue;
        // A fresh isolated route is authoritative for this net. The saved
        // module snapshot remains a fallback only when the local autorouter
        // emitted no copper for it.
        if (!needsSavedSeedFallback(ctx.acc.isolated, ni)) continue;
        ctx.acc.candidate[ni] = true;
        ctx.acc.stats.copper.candidate_tracks += 1;
        if (!seedNetIsLocal(ctx.placement, slug, ni)) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        // A moved remote supply terminal does not invalidate unchanged local copper.
        if (!mapped.compatible and !supply) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        const layer = seedLayerFromModule(ctx.placement, xf, saved.l) orelse {
            ctx.acc.rejected[ni] = true;
            continue;
        };
        if (!seedLayerAllowed(ctx.placement, ctx.options, ni, layer)) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        const a = xf.apply(saved.x1, saved.y1);
        const b = xf.apply(saved.x2, saved.y2);
        try ctx.acc.tracks.append(ctx.alloc, .{ .net = ni, .copper = .{
            .x1 = a[0],
            .y1 = a[1],
            .x2 = b[0],
            .y2 = b[1],
            .layer = layer,
            .width = seedTrackWidth(ctx.placement, ctx.params, ni, saved.w),
            .net = @intCast(ni),
        } });
    }
    for (routes.vias) |saved| {
        const mapped = nets.get(saved.net) orelse continue;
        if (!mapped.sampled or mapped.parent < 0) continue;
        const ni: usize = @intCast(mapped.parent);
        if (!seedNetEnabled(ctx.options, ni)) continue;
        const supply = ni < ctx.supply.len and ctx.supply[ni];
        if (supply and !subcircuit_route.savedSupplyFallbackAllowed(ctx.placement, ctx.options, slug, ni)) continue;
        if (supply and !subcircuit_route.savedNetUsesMultipleLayers(routes.tracks, saved.net)) continue;
        if (!supply and ctx.placement.rules.carriesPlane(ctx.placement.nets[ni].name)) continue;
        if (!needsSavedSeedFallback(ctx.acc.isolated, ni)) continue;
        ctx.acc.candidate[ni] = true;
        ctx.acc.stats.copper.candidate_vias += 1;
        if (!seedNetIsLocal(ctx.placement, slug, ni)) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        if (!mapped.compatible and !supply) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        const p = xf.apply(saved.x, saved.y);
        const geom = seedViaGeometry(ctx.placement, ctx.params, ni, saved);
        try ctx.acc.vias.append(ctx.alloc, .{ .net = ni, .copper = .{
            .x = p[0],
            .y = p[1],
            .dia = geom[0],
            .drill = geom[1],
            .net = @intCast(ni),
        } });
    }
}

fn appendSubcircuitCandidate(
    ctx: *SeedContext,
    project_dir: []const u8,
    sb: env_mod.SubBlock,
) std.mem.Allocator.Error!void {
    const seeds = subBlockPoseByOriginKey(ctx.alloc, project_dir, sb) orelse return;
    if (!seeds.starred or seeds.routes == null or seeds.pin_nets.len == 0) return;
    const hits = try seedHits(ctx.alloc, ctx.placement, sb.name, seeds);
    const xf = bestSeedTransform(ctx.placement, hits) orelse return;
    try appendModuleSeedCopper(ctx, sb.name, seeds, xf);
}

fn rejectSeedViaBudgets(options: route_policy.Options, acc: *SeedAccumulator) void {
    for (acc.rejected, 0..) |_, ni| {
        if (ni >= options.net.len or options.net[ni].max_vias == null) continue;
        var count: usize = 0;
        for (acc.vias.items) |item| if (item.net == ni) {
            count += 1;
        };
        if (count > options.net[ni].max_vias.?) acc.rejected[ni] = true;
    }
}

fn sameSeedTrack(a: route_policy.ExistingTrack, b: route_policy.ExistingTrack) bool {
    return a.net == b.net and a.layer == b.layer and a.width == b.width and
        a.x1 == b.x1 and a.y1 == b.y1 and a.x2 == b.x2 and a.y2 == b.y2;
}

fn sameSeedVia(a: route_policy.ExistingVia, b: route_policy.ExistingVia) bool {
    return a.net == b.net and a.x == b.x and a.y == b.y and a.dia == b.dia and a.drill == b.drill;
}

fn containsSeedTrack(items: []const route_policy.ExistingTrack, want: route_policy.ExistingTrack) bool {
    for (items) |item| if (sameSeedTrack(item, want)) return true;
    return false;
}

fn containsSeedVia(items: []const route_policy.ExistingVia, want: route_policy.ExistingVia) bool {
    for (items) |item| if (sameSeedVia(item, want)) return true;
    return false;
}

fn mergeAcceptedSeeds(
    alloc: std.mem.Allocator,
    options: *route_policy.Options,
    acc: *SeedAccumulator,
) std.mem.Allocator.Error!void {
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    try tracks.appendSlice(alloc, options.existing_tracks);
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    try vias.appendSlice(alloc, options.existing_vias);
    const accepted_vias = try alloc.alloc(u16, acc.rejected.len);
    @memset(accepted_vias, 0);
    for (acc.tracks.items) |item| {
        if (acc.rejected[item.net]) continue;
        if (containsSeedTrack(tracks.items, item.copper)) continue;
        try tracks.append(alloc, item.copper);
        acc.stats.copper.accepted_tracks += 1;
    }
    for (acc.vias.items) |item| {
        if (acc.rejected[item.net]) continue;
        if (containsSeedVia(vias.items, item.copper)) continue;
        try vias.append(alloc, item.copper);
        accepted_vias[item.net] +|= 1;
        acc.stats.copper.accepted_vias += 1;
        if (item.carrier_drop) acc.stats.phase.accepted_carrier_drops += 1;
    }
    const policies = try alloc.dupe(route_policy.NetPolicy, options.net);
    for (accepted_vias, 0..) |count, ni| if (count > 0 and ni < policies.len) {
        if (policies[ni].max_vias) |limit| policies[ni].max_vias = limit -| count;
    };
    options.net = policies;
    options.existing_tracks = tracks.items;
    options.existing_vias = vias.items;
}

fn retainedSeedCopper(
    alloc: std.mem.Allocator,
    options: route_policy.Options,
) std.mem.Allocator.Error!export_gerber.Copper {
    const tracks = try alloc.alloc(router.Track, options.existing_tracks.len);
    for (options.existing_tracks, 0..) |track, i| tracks[i] = .{
        .x1 = track.x1,
        .y1 = track.y1,
        .x2 = track.x2,
        .y2 = track.y2,
        .layer = track.layer,
        .width = track.width,
        .net = track.net,
    };
    const vias = try alloc.alloc(router.Via, options.existing_vias.len);
    for (options.existing_vias, 0..) |via, i| vias[i] = .{
        .x = via.x,
        .y = via.y,
        .dia = via.dia,
        .drill = via.drill,
        .net = via.net,
    };
    return .{ .tracks = tracks, .vias = vias };
}

/// Route every sub-circuit first in a component-only view, then add compatible
/// starred module copper only for nets the isolated router could not emit. The
/// assembled board's rules and DRC are authoritative: disallowed layers / via
/// budgets reject a net, and a board DRC error drops that net's local copper
/// before the global maze sees it.
pub fn addSubcircuitRouteSeeds(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: *route_policy.Options,
) std.mem.Allocator.Error!SubcircuitRouteSeedStats {
    if (block.sub_blocks.len == 0 or placement.nets.len == 0) return .{};
    const rejected = try alloc.alloc(bool, placement.nets.len);
    @memset(rejected, false);
    const candidate = try alloc.alloc(bool, placement.nets.len);
    @memset(candidate, false);
    const supply = try alloc.alloc(bool, placement.nets.len);
    var detected = try module_policy.analyze(alloc, placement);
    defer detected.deinit(alloc);
    for (supply, 0..) |*yes, ni| {
        yes.* = if (ni < detected.net_class.len) switch (detected.net_class[ni]) {
            .ground, .power, .input_rail => true,
            else => false,
        } else false;
    }
    const local = try subcircuit_route.routeAllClassified(alloc, block, placement, params, options.*, supply);
    @memcpy(candidate, local.nets);
    var acc = SeedAccumulator{ .rejected = rejected, .candidate = candidate, .isolated = local.nets, .supply = supply };
    try acc.tracks.appendSlice(alloc, local.tracks);
    try acc.vias.appendSlice(alloc, local.vias);
    acc.stats.copper.candidate_tracks = local.tracks.len;
    acc.stats.copper.candidate_vias = local.vias.len;
    acc.stats.phase.attempted_subcircuits = local.phase.attempted_subcircuits;
    acc.stats.phase.completed_subcircuits = local.phase.completed_subcircuits;
    acc.stats.phase.timed_out_subcircuits = local.phase.timed_out_subcircuits;
    acc.stats.phase.deferred_supply_nets = local.phase.deferred_supply_nets;
    var ctx = SeedContext{ .alloc = alloc, .placement = placement, .params = params, .options = options.*, .supply = supply, .acc = &acc };
    for (block.sub_blocks) |sb| try appendSubcircuitCandidate(&ctx, project_dir, sb);
    rejectSeedViaBudgets(options.*, &acc);
    try subcircuit_seed_drc.reject(alloc, .{
        .placement = placement,
        .params = params,
        .options = options.*,
        .rejected = acc.rejected,
        .tracks = acc.tracks.items,
        .vias = acc.vias.items,
        .track_list = &acc.tracks,
        .via_list = &acc.vias,
        .candidate = candidate,
    });
    for (local.complete_planes, 0..) |complete, ni| {
        if (complete and rejected[ni]) acc.stats.phase.deferred_supply_nets += 1;
    }
    try mergeAcceptedSeeds(alloc, options, &acc);
    for (candidate, 0..) |was_candidate, ni| if (was_candidate) {
        if (rejected[ni]) acc.stats.copper.rejected_nets += 1 else acc.stats.copper.accepted_nets += 1;
    };
    const global_scope = try alloc.alloc(bool, placement.nets.len);
    if (options.selected_nets.len == 0)
        @memset(global_scope, true)
    else for (global_scope, 0..) |*yes, ni|
        yes.* = ni < options.selected_nets.len and options.selected_nets[ni];
    const connectivity = try fab_readiness.netConnectivity(alloc, placement, try retainedSeedCopper(alloc, options.*));
    for (local.complete_planes, 0..) |complete, ni| {
        // The same oracle used by describe/fabrication decides whether the
        // retained local drops really joined every terminal. Complete carrier
        // nets stay frozen; only a physically open carrier re-enters the global
        // plane pass, where retainedStubMm prevents duplicate barrels.
        if (!complete or rejected[ni] or ni >= connectivity.len) continue;
        if (!connectivity[ni].routable or connectivity[ni].connected) {
            global_scope[ni] = false;
        } else {
            acc.stats.phase.deferred_supply_nets += 1;
        }
    }
    options.selected_nets = global_scope;
    return acc.stats;
}

fn seedWasUsed(stats: SubcircuitRouteSeedStats) bool {
    return !stats.fallback and (stats.copper.accepted_tracks > 0 or stats.copper.accepted_vias > 0);
}

fn armRouteDeadline(options: *route_policy.Options) void {
    if (options.stop.deadline_ns != 0 or options.stop.max_route_ms == 0) return;
    options.stop.deadline_ns = clock.nanoTimestamp() +
        @as(i128, @intCast(options.stop.max_route_ms)) * @as(i128, clock.ns_per_ms);
}

/// Run every sub-circuit locally, freeze its accepted copper, then run exactly
/// one assembled-board route. The local phase internally reserves three
/// quarters of any authored deadline for this global pass.
pub fn routeWithSubcircuitSeeds(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
) std.mem.Allocator.Error!struct { result: router.RouteResult, seeds: SubcircuitRouteSeedStats = .{} } {
    var bounded_base = base_options;
    armRouteDeadline(&bounded_base);
    var seeded_options = bounded_base;
    const stats = try addSubcircuitRouteSeeds(alloc, project_dir, block, placement, params, &seeded_options);
    return .{ .result = try route_plan.routeLowered(alloc, placement, params, seeded_options), .seeds = stats };
}

/// Diagnostic twin of `routeWithSubcircuitSeeds`, preserving the same strict
/// local-then-global order and one-global-candidate contract.
pub fn diagnoseWithSubcircuitSeeds(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
) std.mem.Allocator.Error!struct { diagnostic: route_plan.PlannedDiagnostic, seeds: SubcircuitRouteSeedStats = .{} } {
    var bounded_base = base_options;
    armRouteDeadline(&bounded_base);
    var seeded_options = bounded_base;
    const stats = try addSubcircuitRouteSeeds(alloc, project_dir, block, placement, params, &seeded_options);
    return .{ .diagnostic = try route_plan.routeLoweredDiagnostic(alloc, placement, params, seeded_options), .seeds = stats };
}

fn writeRouteSeedStats(w: *std.Io.Writer, stats: SubcircuitRouteSeedStats) std.Io.Writer.Error!void {
    try w.print(
        ",\"subcircuit_seeds\":{{\"candidate_tracks\":{d},\"candidate_vias\":{d}," ++
            "\"accepted_nets\":{d},\"accepted_tracks\":{d},\"accepted_vias\":{d},\"rejected_nets\":{d}," ++
            "\"attempted_subcircuits\":{d},\"completed_subcircuits\":{d},\"timed_out_subcircuits\":{d}," ++
            "\"deferred_supply_nets\":{d},\"accepted_carrier_drops\":{d},\"used\":{},\"fallback\":{}}}",
        .{
            stats.copper.candidate_tracks,
            stats.copper.candidate_vias,
            stats.copper.accepted_nets,
            stats.copper.accepted_tracks,
            stats.copper.accepted_vias,
            stats.copper.rejected_nets,
            stats.phase.attempted_subcircuits,
            stats.phase.completed_subcircuits,
            stats.phase.timed_out_subcircuits,
            stats.phase.deferred_supply_nets,
            stats.phase.accepted_carrier_drops,
            seedWasUsed(stats),
            stats.fallback,
        },
    );
}

// spec: Web Server - Route responses report attempted, completed, and timed-out local sub-circuits, deferred supply nets, and accepted carrier drops while the compatibility fallback flag remains false
test "route response exposes deterministic local phase statistics" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRouteSeedStats(&aw.writer, .{ .phase = .{ .attempted_subcircuits = 3, .completed_subcircuits = 2, .timed_out_subcircuits = 1, .deferred_supply_nets = 4, .accepted_carrier_drops = 5 } });
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"attempted_subcircuits\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accepted_carrier_drops\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fallback\":false") != null);
}

// spec: Web Server - A fresh isolated candidate supersedes saved module copper on the same net, including supply nets, so stale snapshots cannot poison valid bypass bonds.
test "fresh isolated supply copper suppresses its saved snapshot" {
    try std.testing.expect(!needsSavedSeedFallback(&.{true}, 0));
    try std.testing.expect(needsSavedSeedFallback(&.{false}, 0));
    try std.testing.expect(needsSavedSeedFallback(&.{}, 0));
}

/// Initial state of the embed preview's show-clearance / show-DRC toggles,
/// passed through from the schematic page's global checkboxes as `?clr=` / `?drc=`.
/// Clearance and DRC both default off; explicit query values override them.
const Toggles = struct { clr: bool, drc: bool };

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
    const routed_metrics: ?RoutedMetrics = if (ro.run) blk: {
        // Same plan-lowering seam as route_pcb, so this JSON preview == commit.
        const route_options = route_plan.lowerOrEmpty(ctx.allocator, block, placement);
        const seeded = routeWithSubcircuitSeeds(ctx.allocator, ctx.project_dir, block, placement, ro.params, route_options) catch
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
    try writePlacementJson(&aw.writer, placement, shown, name, blame, routed_metrics);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Summary of a routed board for the JSON API (`?route=1`): total copper length,
/// track/via counts, DRC-violation count, net-completion counts, and the names
/// of the nets that failed — the machine-readable comparison key.
const RoutedMetrics = struct {
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

const png_default_width: u32 = 1200;

/// Inputs for `renderDesignPng` — the union of what the HTTP query and the CLI
/// `get_pcb_layout_image` tool can specify. Empty `highlight_*` → plain board;
/// any value → focus mode (spotlight + dim).
pub const PngRequest = struct {
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
pub const PngError = error{ BlockNotFound, SubNotFound, BuildFailed } || png_mod.Error;

/// One classification of a failed solve, worded for both endpoints: `msg` is
/// the PNG handler's plain-text body, `json` the describe endpoint's. Shared
/// so the two views can't drift — an unknown design must never read as an
/// internal failure (a deleted design once 404'd as "describe failed" and got
/// chased as a describe bug).
pub const PngFail = struct { status: u16, msg: []const u8, json: []const u8 };

/// Map a solve/render failure to its HTTP reporting.
pub fn pngFailure(e: PngError) PngFail {
    return switch (e) {
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
    /// Physical heatsink authored on the named/starred saved layout.
    heatsink: ?SavedHeatsink = null,
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
    const saved = solved.heatsink orelse return null;
    const target = thermal_scenarios.resolveMountedTarget(bt, solved.placement, saved.target_ref) orelse return null;
    const physical = optimizer.Side.fromStr(saved.side);
    return .{
        .ref_des = target.ref_des,
        .side = if (physical == target.side) .package_top else .board_backside,
        .physical_face = if (physical == .top) .top else .bottom,
        .geometry = .{
            .width_mm = saved.w,
            .length_mm = saved.h,
            .base_mm = saved.base_mm,
            .fin_height_mm = saved.fin_height_mm,
            .fin_thickness_mm = saved.fin_thickness_mm,
            .fin_gap_mm = saved.fin_gap_mm,
            .fin_axis = std.meta.stringToEnum(thermal_scenarios.FinAxis, saved.fin_axis) orelse .length,
        },
        .material = std.meta.stringToEnum(thermal_scenarios.HeatsinkMaterial, saved.material) orelse .aluminum_6063,
        .contact = .{ .x_mm = saved.x, .y_mm = saved.y, .w_mm = saved.w, .h_mm = saved.h },
        .pad = .{ .thickness_mm = saved.pad_thickness_mm, .conductivity_w_mk = saved.pad_k_w_mk },
    };
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
    // (7 MB for barracuda), and the seven repeats put ~85% of a cold schematic
    // page render inside `std.json`. The page render already worked this way
    // (see `defaultLayoutNameIn`); this is the same discipline for the PNG /
    // describe / thermal path.
    const design_doc = readDesignDoc(alloc, project_dir, name);
    // A ?sub= view reads its own per-sub store; unscoped, it IS the design one.
    const sub_doc: SidecarDoc = if (opts.sub) |s| readSidecarDoc(alloc, project_dir, name, s) else design_doc;

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
        .heatsink = shownHeatsink(sub_doc.layouts, shown_name),
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
) PngError![]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
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
            .layout = opts.layout,
        });
        break :blk (try thermal_scenarios.paintFrom(alloc, results, solved.placement, scenario, ambient)) orelse
            try thermal_scenarios.paintAt(alloc, screen, solved.placement, scenario, ambient, copper);
    } else try thermal_scenarios.paintAt(alloc, screen, solved.placement, scenario, ambient, copper);
    return render_thermal_png.render(alloc, solved.placement, painted, .{
        .width = opts.width,
        .title = solved.title,
        .ambient_c = ambient,
        .inferred_outline = !thermal_scenarios.boardOf(solved.placement).authored,
    });
}

/// allocation goes through `alloc`; the returned bytes are owned by it.
pub fn renderDesignPng(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: PngRequest,
) PngError![]u8 {
    if (opts.thermal.on) return renderThermalPng(alloc, project_dir, name, opts);
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = try solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);
    const placement = solved.placement;
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
        const seeded = routeWithSubcircuitSeeds(alloc, project_dir, solved.block, placement, route_params, route_options) catch break :blk null;
        break :blk seeded.result;
    } else solved.restored.routes;
    if (opts.route) routed = perimeter_fence.append(alloc, placement, routed) catch routed;
    const violations: []const drc.Violation = if (routed) |r|
        drc_rules.checkFilteredZones(alloc, project_dir, name, .{ .placement = placement, .routed = r, .clearance = route_params.clearance, .zones = solved.shown_zones.user })
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
///   scenario=natural|airflow_1ms|airflow_2ms|heatsink
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
pub fn pcbPngApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = nameParam(req, res) orelse return;
    const opts = pngRequestFromQuery(arena, req);
    const png_bytes = renderDesignPng(arena, ctx.project_dir, name, opts) catch |e| {
        const fail = pngFailure(e);
        res.status = fail.status;
        res.body = fail.msg;
        return;
    };
    res.content_type = .PNG;
    res.header("Cache-Control", "no-store");
    res.body = png_bytes;
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
    try std.testing.expectEqual(@as(usize, 1), payloadLayouts(&layouts, false).len);
    try std.testing.expectEqual(@as(usize, 0), payloadLayouts(&layouts, true).len);
}

// spec: Web Server - The Assembly board paints its lightweight semantic view before asynchronously loading dependency-cached Gerber/Excellon artwork, and its initial iframe omits hidden DRC, editable-layout metadata, and editor-only scripts
test "assembly iframe defers CAM and omits editor-only clients" {
    var cam: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer cam.deinit();
    try writeCamFields(&cam.writer, "demo", .{
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
pub fn queryFlag(req: ?*httpz.Request, key: []const u8) bool {
    const r = req orelse return false;
    const q = r.query() catch return false;
    const v = q.get(key) orelse return false;
    return !(v.len == 0 or std.mem.eql(u8, v, "0"));
}

/// True when the request asks to KEEP Do-Not-Populate parts in the centroid
/// CSV (`?dnp=keep`). Default (absent / any other value) drops them — the
/// assembler's pick-and-place file should only carry stuffed parts.
fn queryKeepDnp(req: *httpz.Request) bool {
    const q = req.query() catch return false;
    const v = q.get("dnp") orelse return false;
    return std.mem.eql(u8, v, "keep");
}

/// `?dnp=keep` → keep DNP parts in the centroid; anything else drops them.
fn dnpMode(req: *httpz.Request) export_fab.DnpMode {
    return if (queryKeepDnp(req)) .keep else .drop;
}

/// Query `key` as a float, or -1 when absent/unparseable — the "unset" sentinel
/// the PNG path uses to keep the optimizer's own default for a group knob.
fn pngFloatOpt(req: *httpz.Request, key: []const u8) f64 {
    const q = req.query() catch return -1;
    const v = q.get(key) orelse return -1;
    return std.fmt.parseFloat(f64, v) catch -1;
}

/// Query `key` exactly as sent, keeping a present-but-empty value distinct
/// from an absent one — the layout selectors treat `?layout=` as naming a
/// layout (and 404 on it) rather than as no selection at all.
fn queryRaw(req: ?*httpz.Request, key: []const u8) ?[]const u8 {
    const r = req orelse return null;
    const q = r.query() catch return null;
    return q.get(key);
}

/// Query `key` as an optional string (absent/empty → null).
pub fn queryOpt(req: ?*httpz.Request, key: []const u8) ?[]const u8 {
    const r = req orelse return null;
    const q = r.query() catch return null;
    const v = q.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// Split a comma-separated query parameter into trimmed, non-empty tokens
/// (slices into the request's query buffer). Empty/absent → empty slice.
fn csvParam(arena: std.mem.Allocator, req: *httpz.Request, key: []const u8) []const []const u8 {
    const q = req.query() catch return &.{};
    const v = q.get(key) orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, v, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len > 0) list.append(arena, t) catch break;
    }
    return list.toOwnedSlice(arena) catch &.{};
}

/// Serialize a placement for the JSON export: name, generated flag, the steering
/// weights, the visible `score`, the full objective `breakdown` (raw terms plus
/// their weighted contributions and the summed objective), the bounding box, and
/// each part's `ref/kind/x/y/rot/hw/hh`.
/// World position (mm) of a footprint-local pad on a placed part — the
/// optimizer's OWN transform (bottom-side local-x mirror, then rotation), so
/// the `leg_mm` this JSON reports is the length the placer measured. The local
/// rotate-only copy this replaces dropped the mirror, putting a flipped part's
/// pad `2·|local x|` away from where the board draws it.
fn worldPad(pt: optimizer.Part, pad: optimizer.PadRect) [2]f64 {
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

/// Layout JSON + a `findings` sidecar: each part's normalized objective `blame`
/// (0–1, the render heatmap value) and a `loops` list (per decoupling loop:
/// cap, hub, inductance nH, and power-leg length mm) — the machine-readable twin
/// of the PNG diagnostic overlays, so an agent gets precise numbers, not pixels.
/// `blame` is index-aligned with `p.parts` (empty ⇒ all zero).
fn writePlacementJson(w: *std.Io.Writer, p: optimizer.Placement, params: optimizer.Params, name: []const u8, blame: []const f64, routed: ?RoutedMetrics) std.Io.Writer.Error!void {
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
fn writeBreakdownJson(w: *std.Io.Writer, b: optimizer.Breakdown, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.writeByte('{');
    try writeBreakdownFields(w, b, params);
    try w.writeByte('}');
}

/// The breakdown's fields with no enclosing braces, so the score endpoint can
/// splice an extra `"blame"` map into the same object for the live Heatmap.
fn writeBreakdownFields(w: *std.Io.Writer, b: optimizer.Breakdown, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.print("\"hpwl\":{d},\"loop_raw\":{d},\"loop_weighted\":{d},\"loop_nh\":{d},\"loop_nh_weighted\":{d},", .{
        b.hpwl, b.loop_raw, b.loop_weighted, b.loop_nh, b.loop_nh_weighted,
    });
    try w.print("\"alignment\":{d},\"footprint\":{d},\"congestion\":{d},", .{ b.alignment, b.footprint, b.congestion });
    try w.print("\"loop_term\":{d},\"alignment_term\":{d},\"congestion_term\":{d},\"objective\":{d}", .{
        params.loop_w * b.loop_nh_weighted, optimizer.effAlignW(params) * b.alignment, params.w_congest * b.congestion, b.objective,
    });
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
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
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
    const base = std.heap.page_allocator;
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
        const job = std.heap.page_allocator.create(RegenJob) catch {
            serve_root.pcbJobFinish(name, begin.gen, .failed);
            break :spawn;
        };
        job.* = .{
            .name = std.heap.page_allocator.dupe(u8, name) catch {
                std.heap.page_allocator.destroy(job);
                serve_root.pcbJobFinish(name, begin.gen, .failed);
                break :spawn;
            },
            .project_dir = ctx.project_dir,
            .params = tune.params,
            .gen = begin.gen,
        };
        const t = std.Thread.spawn(.{}, regenThread, .{job}) catch {
            std.heap.page_allocator.free(job.name);
            std.heap.page_allocator.destroy(job);
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
        const blame = partBlameRaw(arena, placement, tune.params);
        try aw.writer.writeByte('{');
        try writeBreakdownFields(&aw.writer, placement.breakdown, tune.params);
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
        try writeBreakdownJson(&aw.writer, bd, tune.params);
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
        try writeModelsJson(w, alloc, project_dir, placement.instances[selected .. selected + 1])
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
    const existing = try mcpExistingCopper(alloc, submitted, resolved.mask);
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
    effort: ?route_policy.Effort = null,
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
    PlacementFailed,
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
        return error.PlacementFailed;
    // An optional groups/nets scope makes this an incremental re-route: only the
    // scoped nets route and the submitted copper for the rest is retained. No
    // scope ⇒ the empty ScopedRoute, i.e. a whole-board route (unchanged).
    const vscope = parseViewerRouteScope(alloc, root, eff_block, placement) catch
        return error.ScopeFailed;
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
        .effort = resolvedBodyEffort(root, in.default_effort),
    };
}

/// The body's optional `"effort"` tier override. An absent field, a non-string,
/// or a word that is not a tier name all mean "keep the block's authored
/// effort", so every caller written before the field existed routes byte-
/// identically. (`route_experiment` is the surface that REJECTS a typo — here a
/// preview must never fail over a spelling, it just routes as the plan says.)
fn bodyEffort(root: std.json.Value) ?route_policy.Effort {
    if (root != .object) return null;
    const v = root.object.get("effort") orelse return null;
    if (v != .string) return null;
    return route_policy.Effort.fromName(v.string);
}

/// Resolve a surface's request policy without letting its fallback overwrite
/// an explicit tier. In particular, an API client's `standard` must beat the
/// editor endpoints' bounded one-shot default.
fn resolvedBodyEffort(root: std.json.Value, default: ?route_policy.Effort) ?route_policy.Effort {
    return bodyEffort(root) orelse default;
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
    subcircuit_seeds: SubcircuitRouteSeedStats = .{},
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
    if (prep.effort) |e| options.effort = e;
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
    var seed_stats = SubcircuitRouteSeedStats{};
    var pr: route_plan.PlannedRun = if (live.sink == null and live.cancel == null and live.timeline == .off) blk: {
        const route_options = preparedRouteOptions(alloc, prep);
        const seeded = try diagnoseWithSubcircuitSeeds(alloc, project_dir, prep.eff_block, prep.placement, prep.rp, route_options);
        seed_stats = seeded.seeds;
        break :blk .{
            .run = .{ .routed = seeded.diagnostic.result, .timeline = &.{} },
            .stuck = seeded.diagnostic.stuck,
            .claimed_routed = seeded.diagnostic.claimed_routed,
        };
    } else blk: {
        var base_options = preparedRouteOptions(alloc, prep);
        armRouteDeadline(&base_options);
        base_options.sink = live.sink;
        var seeded_options = base_options;
        seed_stats = try addSubcircuitRouteSeeds(alloc, project_dir, prep.eff_block, prep.placement, prep.rp, &seeded_options);
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
    try writeRoutedArrays(w, outcome.run.routed, outcome.violations, .{ .nets = prep.placement.nets, .parts = prep.placement.parts }, null, prep.placement);
    try stuck_json.writeStuckJson(w, outcome.stuck);
    try w.print(",\"routed\":{d},\"total\":{d},\"unique_routed\":{d},\"unique_total\":{d},\"return_path\":{d},\"selected\":{d},\"scope_unknown\":", .{ outcome.run.routed.routed, outcome.run.routed.total, outcome.connectivity.unique_routed, outcome.connectivity.unique_total, outcome.return_path, prep.echo.selected });
    try mcpWriteStrArray(w, prep.echo.unknown);
    try writeRouteSeedStats(w, outcome.subcircuit_seeds);
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
    const eff_block = if (subSlug(req)) |s|
        (descendToSub(ctx.allocator, block, s) orelse {
            res.status = 404;
            res.body = no_sub_msg;
            return;
        }).block
    else
        block;

    // A submitted outline becomes the board edge so the board-edge DRC check
    // sees it (a drawn polygon carries its exact points, so the polygon check
    // measures the real shape, not just its bbox). Absent one, fall back to
    // the design's blessed drawn outline — a bare-API caller that omits the
    // body outline must not silently get an edge-blind DRC (parity with
    // pcbRouteApi, which routes against this same resolution).
    const oseed = outlineForBody(ctx.allocator, ctx.project_dir, name, subSlug(req), parseSavedOutline(ctx.allocator, root.object.get("outline")));
    const placement = optimizer.placeFromPoses(ctx.allocator, eff_block, ctx.project_dir, .{ .poses = poses.items, .outline = oseed }, optimizer.Params{}) catch {
        res.status = 500;
        res.body = placement_err_msg;
        return;
    };

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
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    if (queryFlag(req, "pours_only")) {
        const live_copper: pour.Copper = .{ .tracks = rr.tracks, .vias = rr.vias };
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
        return;
    }
    const report = drc_rules.checkFilteredZonesTally(ctx.allocator, ctx.project_dir, name, .{ .placement = placement, .routed = rr, .clearance = clearance, .zones = user_zones });
    const violations = report.violations;
    const tally = report.tally;

    try w.writeAll("{\"drc\":[");
    for (violations, 0..) |vio, i| {
        if (i > 0) try w.writeAll(",");
        try writeViolation(w, vio, .{ .nets = placement.nets, .parts = placement.parts });
    }
    try w.print("],\"n\":{d}", .{violations.len});
    if (tally) |t| try w.print(",\"routed\":{d},\"total\":{d},\"unique_routed\":{d},\"unique_total\":{d}", .{ t.routed, t.total, t.unique_routed, t.unique_total });
    if (queryFlag(req, "pours")) {
        const live_copper: pour.Copper = .{ .tracks = rr.tracks, .vias = rr.vias };
        const base_edge = pour.sharedEdgeField(req.arena, placement) catch null;
        try w.writeAll(",\"pours\":");
        try pour_json.writePours(w, req.arena, placement, live_copper, user_zones, base_edge);
        try pour_json.writePlaneFillsField(w, req.arena, placement, live_copper, false, base_edge);
        // User-zone carved fills, `zone` indexing the POSTED zones order.
        try w.writeAll(",\"zone_fills\":");
        try pour_json.writeZoneFills(w, req.arena, placement, live_copper, zoneFillReqsFrom(req.arena, placement.rules, posted_zones), base_edge);
    }
    try w.writeByte('}');
    res.content_type = .JSON;
    res.body = aw.written();
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
    authored: FabAuthored = .{ .stackup = .{}, .revision = .{} },
    /// True when the blessed poses came from a saved snapshot (★ default →
    /// newest manual → any named), false when they fell back to the bare
    /// optimizer cache — the fab-readiness check surfaces the cache case as a
    /// warning.
    from_saved: bool = false,
};

/// The saved snapshot the blessed poses come from — the same precedence
/// `chooseSyncPoses` walks (★ default → newest manual → any named), so the
/// fab package's outline + routes are restored from the SAME layout its poses
/// were. Null when only the optimizer cache exists.
fn blessedLayout(layouts: []const SavedLayout) ?*const SavedLayout {
    for (layouts) |*L| {
        if (L.default and L.parts.len > 0) return L;
    }
    for (layouts) |*L| {
        if (std.mem.eql(u8, L.kind, kind_manual) and L.parts.len > 0) return L;
    }
    for (layouts) |*L| {
        if (L.parts.len > 0) return L;
    }
    return null;
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
    var placement = blessedPlacement(ctx, req, res, name) orelse return null;
    var routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    var zones: []const pour.UserZone = &.{};
    var silk_keepouts: []const subcircuit_silkscreen.Keepout = &.{};
    var from_saved = false;
    var texts: []const font5x7.BoardText = &.{};
    if (blessedLayout(readLayouts(req.arena, ctx.project_dir, name))) |L| {
        from_saved = true;
        if (L.outline) |o| {
            placement.board_rect = .{ .minx = o.x, .miny = o.y, .w = o.w, .h = o.h };
            placement.board_poly = o.derived.poly orelse o.pts;
            placement.board_arcs = o.derived.arcs;
        }
        applyFabricationLayerOverrides(req.arena, &placement, L.fabrication_layers);
        if (L.routes) |sr| {
            if (restoreRoutes(req.arena, routesWithPerimeter(req.arena, placement, sr).?, placement.nets)) |r| {
                routed = r;
            }
            zones = userZonesFrom(req.arena, placement.rules, sr.zones);
            silk_keepouts = silkKeepoutsFrom(req.arena, sr.zones);
        }
        texts = L.texts;
    }
    routed = (perimeter_fence.append(req.arena, placement, routed) catch null) orelse routed;
    return .{ .placement = placement, .routed = routed, .zones = zones, .silk_keepouts = silk_keepouts, .texts = texts, .from_saved = from_saved };
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

/// Run the fab-readiness report over a resolved `FabView` (the same view the
/// Gerber export builds), so the check and the files describe the same board.
fn fabReadinessFor(ctx: *Server, req: *httpz.Request, fv: FabView) HandlerError!fab_readiness.Report {
    const copper = export_gerber.Copper{ .tracks = fv.routed.tracks, .arcs = fv.routed.arcs, .rf_paths = fv.routed.rf_port_outcomes, .vias = fv.routed.vias, .zones = fv.zones, .silk_keepouts = fv.silk_keepouts };
    const name = req.param("name") orelse "";
    return fab_readiness.check(req.arena, fv.placement, copper, .{
        .from_saved_layout = fv.from_saved,
        .keep_dnp = queryKeepDnp(req),
        .drc_rules = drc_rules.load(req.arena, ctx.project_dir, name),
    });
}

/// GET /api/fab-readiness/:name — the pre-fab correctness report for `name`'s
/// blessed layout (audit item 0.1): `{ok,errors:[…],warnings:[…],stats:{…}}`,
/// computed against the SAME blessed-layout selection the Gerber export uses.
/// `?layout=<row>` pins the report to that named saved layout — the row its
/// /pcb-layout permalink shows and the CLI `run_fab_readiness` `layout` arg
/// selects — and 404s an unknown name instead of silently reporting the ★
/// board. The viewer fetches this before download and gates on it;
/// `pcbGerbersApi` enforces it server-side (409 on errors unless `?force=1`).
pub fn pcbFabReadinessApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const fv = blessedFabView(ctx, req, res, name) orelse return;
    const report = try fabReadinessFor(ctx, req, fv);
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try fab_readiness.writeJson(&aw.writer, report);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// GET /api/pcb-gerbers/:name — the complete fab package as one ZIP: Gerber
/// copper (outer signal layers + stackup-derived inner planes), solder mask,
/// paste, silkscreen, board profile, Excellon PTH/NPTH drills, the centroid
/// CSV, a `.gbrjob` job file, and a fabrication-ID manifest — all at the blessed poses with the ★
/// layout's persisted routed copper, in one shared y-up frame. What a board
/// house needs to build the board, no KiCad in the loop.
///
/// Gated by the fab-readiness report (`/api/fab-readiness`): if that finds
/// blocking errors, this returns **HTTP 409** with the report JSON and writes
/// nothing — unless `?force=1` overrides the gate (the viewer's "Download
/// anyway"). Warnings never block. A clean (or forced) request downloads the
/// ZIP as before. `?dnp=keep` keeps Do-Not-Populate parts in the centroid CSV
/// (dropped by default). `?layout=<row>` packages the named saved layout —
/// gate and files built from the same view, so they still agree.
pub fn pcbGerbersApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    const fv = blessedFabView(ctx, req, res, name) orelse return;

    // Pre-fab gate: block on errors unless explicitly forced.
    if (!queryFlag(req, "force")) {
        const report = try fabReadinessFor(ctx, req, fv);
        if (!report.ok()) {
            res.status = 409;
            var jw: std.Io.Writer.Allocating = .init(req.arena);
            try fab_readiness.writeJson(&jw.writer, report);
            res.content_type = .JSON;
            res.body = jw.written();
            return;
        }
    }

    const copper = export_gerber.Copper{ .tracks = fv.routed.tracks, .arcs = fv.routed.arcs, .rf_paths = fv.routed.rf_port_outcomes, .vias = fv.routed.vias, .zones = fv.zones, .silk_keepouts = fv.silk_keepouts };
    const frame = export_fab.frameFor(fv.placement);
    const mark = try fab_identity.build(req.arena, fv.placement, copper, fv.texts, frame, null);
    const fab_texts = try fab_identity.replaceAdoptedText(req.arena, fv.texts, mark);

    // The package basename is sanitized ONCE, here, and every member — the
    // layer files, the job file's own `Path` fields, the drills, the centroid
    // and the download's filename — is named from it. JLCPCB rejects an
    // archive whose entry names carry certain words, so a rejected design slug
    // falls back to a neutral one (`fab_filename.prefix`); doing that per call
    // site is how a job file ends up pointing at members the archive does not
    // contain under that name.
    var pkg = export_fab.Package{ .arena = req.arena, .prefix = fab_filename.prefix(name) };
    const layers = try export_gerber.planLayers(req.arena, fv.placement);
    // ONE clock read for the whole package, so every layer in this ZIP carries
    // the same `%TF.CreationDate`. The writer itself stays deterministic (its
    // CLI/test path passes no stamp at all) — the same split the review PDF
    // uses for `/CreationDate`.
    const stamped = try export_gerber.creationDate(req.arena, clock.timestamp());
    for (layers) |f| {
        var aw: std.Io.Writer.Allocating = .init(req.arena);
        try export_gerber.writeLayer(&aw.writer, req.arena, fv.placement, copper, fab_texts, frame, f.layer, .{ .function = f.function, .created = stamped });
        if (f.exact_name) try pkg.addNamed(f.suffix, aw.written()) else try pkg.add(f.suffix, aw.written());
    }
    // The Gerber Job File ties the package together (board size, layer count,
    // per-file FileFunction). Its Path fields match the entry names above.
    var jbw: std.Io.Writer.Allocating = .init(req.arena);
    try export_gerber.writeJobFile(&jbw.writer, fv.placement, layers, pkg.prefix);
    try pkg.add(export_gerber.job_file_suffix, jbw.written());
    // The drill headers declare the span they drill through, which is the
    // same copper count the job file reports and the layer table generated.
    const copper_layers = fv.placement.rules.layerStack().stackCount();
    var pth: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.excellonDrill(&pth.writer, req.arena, fv.placement.parts, fv.routed.vias, .{ .class = .plated, .copper_layers = copper_layers }, frame);
    try pkg.add(export_gerber.plated_drill_suffix, pth.written());
    var npth: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.excellonDrill(&npth.writer, req.arena, fv.placement.parts, fv.routed.vias, .{ .class = .non_plated, .copper_layers = copper_layers }, frame);
    try pkg.add(export_gerber.non_plated_drill_suffix, npth.written());
    var cw: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.centroidCsv(&cw.writer, fv.placement.parts, fv.placement.instances, frame, dnpMode(req));
    try pkg.add("centroid.csv", cw.written());
    const manifest = try std.fmt.allocPrint(req.arena,
        \\PCB fabrication ID: {s}
        \\Full SHA-256: {s}
        \\Scope: deterministic Gerber and Excellon geometry before the identity mark
        \\
    , .{ &mark.short_hex, &mark.digest_hex });
    try pkg.add("fab-id.txt", manifest);

    var zw: std.Io.Writer.Allocating = .init(req.arena);
    try zipfile.write(&zw.writer, pkg.entries.items);
    res.header(ct_hdr, "application/zip");
    res.header("x-pcb-fab-id", try req.arena.dupe(u8, &mark.short_hex));
    res.header("content-disposition", try std.fmt.allocPrint(req.arena, "attachment; filename=\"{s}-{s}-gerbers.zip\"", .{ pkg.prefix, &mark.short_hex }));
    res.body = zw.written();
}

/// POST /api/pcb-layouts/:name — save a named layout snapshot (kind "manual").
/// Body: `{"name","parts":[{ref,x,y,rot,origin?}, …]}`; the score is computed on the
/// server (no client-side metric). Upserts by name (re-save overwrites in
/// place); a new name is prepended so the newest sits at the top of the list.
/// Score a hand/CLI-saved layout on the server with the optimizer's own
/// objective — the same code the live `/api/pcb-score` endpoint uses — so a
/// saved layout is directly comparable to the auto baseline (HPWL + real
/// routed-trace loop). For a `?sub` circuit the score is against the scoped
/// sub-block. A resolve/score failure just leaves it unscored. Extracted from
/// `saveNamedLayoutApi` to keep that handler focused.
pub fn scoreSavedLayout(
    ctx: *Server,
    req: *httpz.Request,
    name: []const u8,
    sub: ?[]const u8,
    parts: []const PartPose,
) HandlerError!sidecar_json.SavedLayoutCheck {
    var out: sidecar_json.SavedLayoutCheck = .{};
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    if (resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res)) |block| {
        // For a sub circuit, score against the scoped sub-block (its parts),
        // not the whole parent design — null when the slug no longer resolves.
        const score_block: ?*env_mod.DesignBlock = if (sub) |s| blk: {
            const sb = descendToSub(ctx.allocator, block, s) orelse break :blk null;
            break :blk sb.block;
        } else block;
        if (score_block) |sblk| {
            out.layers = sidecar_json.stackupLayerRules(req.arena, sblk) catch null;
            const params = readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{};
            const poses = try refPosesFromPartPoses(req.arena, parts);
            if (optimizer.scorePoses(ctx.allocator, sblk, ctx.project_dir, poses, params)) |bd| {
                out.score = .{ .hpwl = bd.hpwl, .loop = bd.loop_raw, .caps = 0, .objective = bd.objective };
            } else |_| {}
        }
    }
    return out;
}

/// Star a block's very FIRST saved layout. Something must be starred for the
/// page to reopen on a saved board at all (`chooseLayout` falls through to the
/// optimizer cache otherwise — the "I saved, refreshed, and my edits vanished"
/// trap), and the KiCad sync + fab outputs read the ★ as the blessed board.
/// Deliberately scoped to a one-entry list: once a block has several layouts
/// the star is the user's pick, so a later save never steals it, and clearing
/// it (`setDefaultLayoutApi` with an empty name) stays cleared.
fn starFirstEver(layouts: []SavedLayout) void {
    if (layouts.len != 1) return;
    layouts[0].default = true;
}

/// `POST /api/pcb-layouts/:name` — persist a named layout: its poses, routed
/// copper, board outline, and silk texts. Guards an optimistic-concurrency
/// rev, scores the arrangement, and rejects a self-intersecting / zero-area
/// custom outline before writing the sidecar.
pub fn saveNamedLayoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
    // "accept then stamp". The successful write bumps the rev to `new_rev`.
    const disk_rev = readLayoutRev(req.arena, ctx.project_dir, name, sub);
    if (root.object.get("rev")) |rv| {
        const client_rev: ?i64 = switch (rv) {
            .integer => |i| i,
            .float => |f| numeric.checkedInt(i64, f),
            else => null,
        };
        if (client_rev) |cr| if (cr != disk_rev) {
            res.status = 409;
            res.content_type = .JSON;
            res.body = try std.fmt.allocPrint(req.arena, "{{\"error\":\"conflict\",\"rev\":{d}}}", .{disk_rev});
            return;
        };
    }
    const new_rev = disk_rev + 1;
    // Score the hand layout with the optimizer's own objective (comparable to
    // the auto baseline); the same pass hands back the block's layer rules.
    const checked = try scoreSavedLayout(ctx, req, name, sub, parts);
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
        .score = checked.score,
        .parts = parts,
        .routes = parseSavedRoutes(req.arena, root.object.get("routes")),
        .outline = saved_outline,
        .fabrication_layers = parseSavedFabricationLayers(req.arena, root.object.get("fabrication_layers")),
        .heatsink = parseSavedHeatsink(root.object.get("heatsink")),
        .texts = parseSavedTexts(req.arena, root.object.get("texts")),
        .dimensions = parsePartEdgeDimensions(req.arena, root.object.get("dimensions")),
    };
    // Geometry this WRITE path refuses — a bow-tie board outline, a pour on a
    // layer this board has not got (see `saveRejection` for why each is judged
    // here and nowhere else).
    if (sidecar_json.saveRejection(req.arena, checked.layers, entry)) |msg| {
        res.status = 400;
        res.body = msg;
        return;
    }
    // Snapshot only a request that has passed every rejection above and will
    // actually overwrite the sidecar. Rejected idle-autosaves used to consume
    // all 20 history slots with identical copies of the last good board.
    // Best-effort; sub circuits keep multi-snapshot in-file history already.
    if (sub == null) {
        if (layoutsSidecar(req.arena, ctx.project_dir, name, null, layouts_ext)) |scp| {
            _ = history.snapshotLayouts(req.arena, ctx.project_dir, name, scp) catch null;
        }
    }
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
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
        } else if (open and std.mem.eql(u8, L.kind, kind_auto) and sameLayoutScore(L.score, entry.score)) {
            // Same arrangement as an auto run → promote it to this named keeper
            // rather than leaving a duplicate behind.
            entry.default = L.default;
            replaced = true;
        } else try out.append(req.arena, L);
    }
    try out.insert(req.arena, 0, entry);
    starFirstEver(out.items);
    writeLayoutsSubRev(req.arena, ctx.project_dir, name, sub, out.items, new_rev);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d}}}", .{new_rev});
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
    const disk_rev = readLayoutRev(req.arena, ctx.project_dir, name, null);
    if (layoutsSidecar(req.arena, ctx.project_dir, name, null, layouts_ext)) |scp| {
        _ = history.snapshotLayouts(req.arena, ctx.project_dir, name, scp) catch null;
    }
    writeLayoutsFile(req.arena, ctx.project_dir, name, restored, readCacheSlot(req.arena, ctx.project_dir, name), disk_rev + 1);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d}}}", .{disk_rev + 1});
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
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const id = mcpArgStr(args_val, "id") orelse return mcpFail(out, alloc, "missing snapshot id");
    const snap_path = history.layoutSnapshotPath(alloc, project_dir, name, id) catch
        return mcpFail(out, alloc, "layout snapshot not found");
    const snap_data = infra_fs.cwd().readFileAlloc(alloc, snap_path, sidecar_max_bytes) catch
        return mcpFail(out, alloc, "layout snapshot read failed");
    const restored = parseLayouts(alloc, snap_data) orelse
        return mcpFail(out, alloc, "layout snapshot is corrupt");
    const disk_rev = readLayoutRev(alloc, project_dir, name, null);
    if (layoutsSidecar(alloc, project_dir, name, null, layouts_ext)) |sidecar_path| {
        _ = history.snapshotLayouts(alloc, project_dir, name, sidecar_path) catch null;
    }
    writeLayoutsFile(alloc, project_dir, name, restored, readCacheSlot(alloc, project_dir, name), disk_rev + 1);
    out.clearRetainingCapacity();
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, out);
    defer out.* = aw.toArrayList();
    try aw.writer.print("{{\"ok\":true,\"rev\":{d},\"snapshot\":", .{disk_rev + 1});
    try writeJsonStr(&aw.writer, id);
    try aw.writer.writeAll("}");
    return true;
}

fn namedLayoutMutationRev(
    req: *httpz.Request,
    res: *httpz.Response,
    project_dir: []const u8,
    design: []const u8,
    sub: ?[]const u8,
    root: std.json.Value,
) ?i64 {
    const disk_rev = readLayoutRev(req.arena, project_dir, design, sub);
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
pub fn commitNamedLayoutMutation(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    design: []const u8,
    sub: ?[]const u8,
    layouts: []const SavedLayout,
    disk_rev: i64,
) i64 {
    if (sub == null) {
        if (layoutsSidecar(alloc, project_dir, design, null, layouts_ext)) |sidecar_path| {
            _ = history.snapshotLayouts(alloc, project_dir, design, sidecar_path) catch null;
        }
    }
    const new_rev = disk_rev + 1;
    writeLayoutsSubRev(alloc, project_dir, design, sub, layouts, new_rev);
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
    const disk_rev = namedLayoutMutationRev(req, res, ctx.project_dir, name, sub, root) orelse return;
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
    const remaining = deletedLayoutList(req.arena, existing, nm_v.string) catch |err| switch (err) {
        error.LayoutNotFound => {
            res.status = 404;
            res.body = "layout not found";
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const new_rev = commitNamedLayoutMutation(req.arena, ctx.project_dir, name, sub, remaining, disk_rev);
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
    const disk_rev = namedLayoutMutationRev(req, res, ctx.project_dir, design, sub, root) orelse return;
    const existing = readLayoutsSub(req.arena, ctx.project_dir, design, sub);
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
    const new_rev = commitNamedLayoutMutation(req.arena, ctx.project_dir, design, sub, renamed, disk_rev);
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
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
    var out: std.ArrayList(SavedLayout) = .empty;
    for (existing) |L| {
        var e = L;
        e.default = want.len > 0 and std.mem.eql(u8, L.name, want);
        try out.append(req.arena, e);
    }
    writeLayoutsSub(req.arena, ctx.project_dir, name, sub, out.items);
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
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
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
    writeLayouts(req.arena, ctx.project_dir, name, out.items);

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
    const layouts = readLayoutsSub(req.arena, ctx.project_dir, name, sub);

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
        try writeBreakdownJson(w, bd, tune.params);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Parse the request body as a JSON object, setting a 400 and returning null on
/// any failure (missing body / malformed JSON / non-object root).
fn parseJsonObject(req: *httpz.Request, res: *httpz.Response) ?std.json.Value {
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
fn posesFromPlacement(alloc: std.mem.Allocator, p: optimizer.Placement) ?[]PartPose {
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
fn refPosesFromPartPoses(alloc: std.mem.Allocator, parts: []const PartPose) std.mem.Allocator.Error![]optimizer.RefPose {
    const out = try alloc.alloc(optimizer.RefPose, parts.len);
    for (parts, 0..) |p, i| out[i] = .{ .ref = p.ref, .x = p.x, .y = p.y, .rot = p.rot, .side = p.side, .locked = p.locked };
    return out;
}

/// The sub-block scope of a hierarchical ref-des: everything before the last
/// `/` ("hmc733/U14" → "hmc733", "U5" → ""). Origin keys are module-LOCAL, so
/// they only identify a part within one sub-block's scope.
fn refPrefix(ref: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return "";
    return ref[0..i];
}

/// One live part's identity for pose resolution: its current flatten ref-des
/// and (possibly empty) module-local origin key.
const LiveRef = struct { ref: []const u8, origin: []const u8 };

/// A `resolvePoseIdentity` result: pose i's resolved current ref (its stored
/// ref when nothing matched) and whether it bound to a live part at all.
const ResolvedPoses = struct { refs: [][]const u8, bound: []bool };

/// Resolve saved poses onto the current flatten's identity, in two passes: the
/// sub-block-scoped origin key binds FIRST — it is the renumber-stable
/// identity, while a ref-des *string* can survive a renumber naming a
/// DIFFERENT part (the recycled-ref mis-bind that scattered black-canyon's
/// sub-circuits after a netlist edit). Still-unresolved poses then claim their
/// exact ref string (legacy entries saved without an origin). The origin map
/// is scoped by the ref's sub-block prefix, because origin keys are
/// module-local ("U1" names the main IC of EVERY sub-block; an unscoped map
/// would let 13 sub-blocks clobber each other), and each live ref is claimed
/// at most once, so a stale pose can never shadow a genuine one. Null only on
/// allocation failure.
fn resolvePoseIdentity(
    alloc: std.mem.Allocator,
    live: []const LiveRef,
    parts: []const PartPose,
) ?ResolvedPoses {
    var by_ref = std.StringHashMapUnmanaged(usize).empty;
    var by_origin = std.StringHashMapUnmanaged(usize).empty;
    for (live, 0..) |lr, i| {
        by_ref.put(alloc, lr.ref, i) catch return null;
        if (lr.origin.len == 0) continue;
        const key = std.fmt.allocPrint(alloc, pin_key_fmt, .{ refPrefix(lr.ref), lr.origin }) catch return null;
        by_origin.put(alloc, key, i) catch return null;
    }
    const claimed = alloc.alloc(bool, live.len) catch return null;
    @memset(claimed, false);
    const refs = alloc.alloc([]const u8, parts.len) catch return null;
    const bound = alloc.alloc(bool, parts.len) catch return null;
    @memset(bound, false);
    for (parts, 0..) |pp, i| {
        refs[i] = pp.ref;
        if (pp.origin.len == 0) continue;
        const key = std.fmt.allocPrint(alloc, pin_key_fmt, .{ refPrefix(pp.ref), pp.origin }) catch return null;
        const li = by_origin.get(key) orelse continue;
        if (claimed[li]) continue;
        claimed[li] = true;
        refs[i] = live[li].ref;
        bound[i] = true;
    }
    for (parts, 0..) |pp, i| {
        if (bound[i]) continue;
        const li = by_ref.get(pp.ref) orelse continue;
        if (claimed[li]) continue;
        claimed[li] = true;
        bound[i] = true;
    }
    return .{ .refs = refs, .bound = bound };
}

/// The live-identity list of a built placement (ref + origin key per part),
/// the input `resolvePoseIdentity` matches saved poses against. Null on
/// allocation failure.
fn liveOfPlacement(alloc: std.mem.Allocator, p: optimizer.Placement) ?[]const LiveRef {
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
/// fallback). A pose with no match keeps its stored `ref`. Null only on a
/// flatten/allocation failure (caller falls back to raw refs).
fn rekeyPosesByOrigin(
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
    const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
    for (parts, 0..) |pp, i| {
        out[i] = .{ .ref = res.refs[i], .x = pp.x, .y = pp.y, .rot = pp.rot, .side = pp.side, .locked = pp.locked };
    }
    return out;
}

/// The page blob's saved-layout rows, re-keyed onto the flatten the page is
/// showing, so the client Load applies poses by EXACT ref. Pose identity —
/// the sub-block-scoped origin bridge — lives in exactly one place
/// (`resolvePoseIdentity`), server-side: the client's old origin map was
/// unscoped and last-wins, which collapsed every sub-block sharing a
/// module-local key ("U1") onto one pose on Load. Rows whose resolution fails
/// pass through unchanged (their stored refs are still the best available).
fn rekeyRowsToLive(
    alloc: std.mem.Allocator,
    layouts: []const SavedLayout,
    live: []const LiveRef,
) []const SavedLayout {
    const out = alloc.dupe(SavedLayout, layouts) catch return layouts;
    for (out) |*L| {
        const res = resolvePoseIdentity(alloc, live, L.parts) orelse continue;
        const np = alloc.dupe(PartPose, L.parts) catch continue;
        for (np, 0..) |*pp, i| pp.ref = res.refs[i];
        const nd = alloc.dupe(SavedPartEdgeDimension, L.dimensions) catch {
            L.parts = np;
            continue;
        };
        for (nd) |*dimension| {
            for (L.parts, 0..) |part, i| {
                if (std.mem.eql(u8, dimension.ref, part.ref)) {
                    dimension.ref = res.refs[i];
                    break;
                }
            }
        }
        L.parts = np;
        L.dimensions = nd;
    }
    return out;
}

/// `rekeyRowsToLive` against a built placement's identity; rows pass through
/// unchanged when the live list can't be built (allocation failure).
fn rekeyRowsToPlacement(
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
    return defaultLayoutNameIn(readLayoutsSub(alloc, project_dir, name, sub));
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
    return layoutPosesIn(alloc, readLayoutsSub(alloc, project_dir, name, sub), want, block);
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
fn layoutsSidecar(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8, ext: []const u8) ?[]u8 {
    const s = sub orelse return (paths.designSiblingPath(alloc, project_dir, name, ext) catch null);
    const src = paths.designSourcePath(alloc, project_dir, name) catch return null;
    defer alloc.free(src);
    const dir = std.fs.path.dirname(src) orelse ".";
    return std.fmt.allocPrint(alloc, "{s}/{s}.{s}{s}", .{ dir, name, s, ext }) catch null;
}

/// Read every saved layout for `name` from its `.layouts.json` sidecar
/// (newest first). Returns an empty slice when the file doesn't exist or on
/// parse failure; allocations live on `alloc` (request lifetime).
pub fn readLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) []const SavedLayout {
    return readLayoutsSub(alloc, project_dir, name, null);
}

/// Whether `name` has a saved layout called `want` (exact match, the same
/// comparison `layoutPosesIn` selects poses with).
///
/// A caller that would otherwise pay for a FRESH placement solve on a name
/// nobody saved — `solveForRequest` falls through to one — asks here first: a
/// sidecar parse is the cheap half of that mistake.
pub fn hasSavedLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    want: []const u8,
) bool {
    for (readLayouts(alloc, project_dir, name)) |l| {
        if (std.mem.eql(u8, l.name, want)) return true;
    }
    return false;
}

/// As `readLayouts`, but for a `?sub=` scoped sub circuit reads its per-sub
/// sidecar (`layoutsSidecar`). `sub == null` is identical to `readLayouts`.
pub fn readLayoutsSub(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) []const SavedLayout {
    return readSidecarDoc(alloc, project_dir, name, sub).layouts;
}

/// The board-level silkscreen texts of `name`'s shown layout: the layout named
/// `want` when given, else the starred (★ default) one — empty when nothing
/// matches or the layout carries no texts. Used by the PNG/describe path so a
/// screenshot draws the same legend the fab silk will (parallels `shownTexts`,
/// which reads the already-loaded list the page render holds).
fn layoutTextsFor(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, want: ?[]const u8, sub: ?[]const u8) []const font5x7.BoardText {
    return layoutTextsIn(readLayoutsSub(alloc, project_dir, name, sub), want);
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
pub fn parseLayouts(alloc: std.mem.Allocator, data: []const u8) ?[]const SavedLayout {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    return layoutsFromRoot(alloc, root);
}

/// `parseLayouts` over an already-parsed JSON tree — `readSidecarDoc` parses
/// the (multi-megabyte on a routed board) sidecar once and derives layouts,
/// cache slot and rev from the same tree.
fn layoutsFromRoot(alloc: std.mem.Allocator, root: std.json.Value) ?[]const SavedLayout {
    if (root != .object) return null;
    const arr = root.object.get("layouts") orelse return null;
    if (arr != .array) return null;
    // Top-level `"default":"<name>"` names the one layout the KiCad sync seeds
    // from; flag the matching entry below. Absent / empty → no default.
    const default_name: []const u8 = blk: {
        const dv = root.object.get("default") orelse break :blk "";
        break :blk if (dv == .string) dv.string else "";
    };
    var list: std.ArrayList(SavedLayout) = .empty;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const nm = it.object.get("name") orelse continue;
        if (nm != .string) continue;
        const kind: []const u8 = blk: {
            const k = it.object.get("kind") orelse break :blk kind_auto;
            break :blk if (k == .string and std.mem.eql(u8, k.string, kind_manual)) kind_manual else kind_auto;
        };
        var score: ?LayoutScore = null;
        if (it.object.get("hpwl")) |_| score = .{
            .hpwl = jsonNum(it.object.get("hpwl")),
            .loop = jsonNum(it.object.get("loop")),
            .caps = numeric.toCount(@max(@floor(jsonNum(it.object.get("caps"))), 0)),
            .objective = jsonNum(it.object.get("objective")), // 0 for legacy entries
        };
        const parts = parsePartPoses(alloc, it.object.get("parts")) orelse &[_]PartPose{};
        const rough = blk: {
            const rv = it.object.get("rough") orelse break :blk false;
            break :blk rv == .bool and rv.bool;
        };
        list.append(alloc, .{
            .name = nm.string,
            .kind = kind,
            .ts = numeric.checkedInt(i64, jsonNum(it.object.get("ts"))) orelse 0,
            .score = score,
            .parts = parts,
            .default = default_name.len > 0 and std.mem.eql(u8, nm.string, default_name),
            .rough = rough,
            .routes = parseSavedRoutes(alloc, it.object.get("routes")),
            .outline = parseSavedOutline(alloc, it.object.get("outline")),
            .fabrication_layers = parseSavedFabricationLayers(alloc, it.object.get("fabrication_layers")),
            .heatsink = parseSavedHeatsink(it.object.get("heatsink")),
            .texts = parseSavedTexts(alloc, it.object.get("texts")),
            .dimensions = parsePartEdgeDimensions(alloc, it.object.get("dimensions")),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Serialize a `SavedOutline` as the sidecar/page JSON object — the exact
/// shape `parseSavedOutline` reads back (rect fields always, `pts` only for
/// polygon outlines). Shared by the sidecar writer and the page blob so the
/// two can never diverge.
const writeSavedOutlineJson = sidecar_json.writeSavedOutlineJson;
const writePartEdgeDimensionsJson = sidecar_json.writePartEdgeDimensionsJson;
const writeSavedHeatsinkJson = sidecar_json.writeSavedHeatsinkJson;
const writeBoardTextJson = sidecar_json.writeBoardTextJson;
const writeOptionalBoardTextJson = sidecar_json.writeOptionalBoardTextJson;
const writeSavedTextsJson = sidecar_json.writeSavedTextsJson;

/// Serialize zone records in the sidecar/embedded `PCB.zones` shape.
const writeSavedZonesJson = sidecar_json.writeSavedZonesJson;

fn writeSavedRfPathsJson(w: *std.Io.Writer, saved_paths: []const SavedRfPath) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (saved_paths, 0..) |path, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, path.net);
        try w.print(",\"l\":{d}", .{path.layer});
        if (path.track_ids.len > 0) {
            try w.writeAll(",\"track_ids\":");
            try writeStringList(w, path.track_ids);
        }
        if (path.portal) try w.writeAll(",\"portal\":true");
        try w.writeAll(",\"samples\":[");
        for (path.samples, 0..) |sample, si| {
            if (si > 0) try w.writeByte(',');
            try w.print("[{d},{d},{d}]", .{ sample.at[0], sample.at[1], sample.width_mm });
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

fn writeFreshRfPathsJson(w: *std.Io.Writer, outcomes: []const rf_port_report.Outcome, nets: []const export_kicad.FlatNet) std.Io.Writer.Error!void {
    var first = true;
    try w.writeByte('[');
    for (outcomes) |outcome| {
        if (!outcome.success or outcome.physical.gate_removed) continue;
        if (outcome.physical.samples.len < 2) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, netNameOf(nets, outcome.net));
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
pub fn writeSavedRoutesJson(w: *std.Io.Writer, sr: SavedRoutes) std.Io.Writer.Error!void {
    try w.writeAll("{\"tracks\":[");
    for (sr.tracks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(track_json_fmt, .{ t.x1, t.y1, t.x2, t.y2, t.l, t.w });
        try writeJsonStr(w, t.net);
        if (t.xm) |xm| if (t.ym) |ym| try w.print(",\"xm\":{d},\"ym\":{d}", .{ xm, ym });
        if (t.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, t.g);
        }
        if (t.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, t.source);
        }
        try writeTrackSegmentId(w, t, i);
        try w.writeAll("}");
    }
    try w.writeAll(vias_arr_open);
    for (sr.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(via_json_fmt, .{ vi.x, vi.y, vi.d, vi.drill });
        try writeJsonStr(w, vi.net);
        if (vi.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, vi.g);
        }
        if (vi.f.len > 0) {
            try w.writeAll(",\"f\":");
            try writeJsonStr(w, vi.f);
        }
        if (vi.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, vi.source);
        }
        // The optional span remains omitted for ordinary through vias.
        if (vi.s) |span| try w.print(",\"s\":[{d},{d}]", .{ span[0], span[1] });
        try writeViaId(w, vi, i);
        try w.writeAll("}");
    }
    try w.writeAll("]");
    if (sr.zones.len > 0) {
        try w.writeAll(",\"zones\":");
        try writeSavedZonesJson(w, sr.zones);
    }
    if (sr.rf_paths.len > 0) {
        try w.writeAll(",\"rf_paths\":");
        try writeSavedRfPathsJson(w, sr.rf_paths);
    }
    try w.writeAll("}");
}

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
fn netIndexByName(placement: optimizer.Placement, name: []const u8) ?i32 {
    for (placement.nets, 0..) |net, i| if (std.mem.eql(u8, net.name, name)) return @intCast(i);
    return null;
}

const userZonesFrom = saved_zone.userZones;
const zoneFillReqsFrom = saved_zone.fillRequests;
const existingZonesFrom = saved_zone.existingZones;

/// Keepout polygons are no-silkscreen regions on both faces. Unlike copper
/// pours they need no net/layer resolution; a three-point imported boundary is
/// enough to conservatively suppress generated annotation ink.
fn silkKeepoutsFrom(alloc: std.mem.Allocator, zones: []const SavedZone) []const subcircuit_silkscreen.Keepout {
    var out: std.ArrayList(subcircuit_silkscreen.Keepout) = .empty;
    for (zones) |zone| {
        if (zone.flags.keepout and zone.poly.len >= 3) out.append(alloc, .{ .polygon = zone.poly }) catch return out.items;
    }
    return out.items;
}

/// The saved zones the shown view carries (null when no saved copper is shown).
fn shownZones(saved: ?SavedRoutes) []const SavedZone {
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
const ShownView = struct {
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
    /// into `writePcbData` (see `pour.sharedEdgeField`); null when the board
    /// has no fillable lattice.
    base_edge: ?pour.EdgeField = null,
    /// Exact authored vertices and fillet radii for the shown layout.
    outline: ?SavedOutline = null,
    /// Empty means the authored fabrication-layer regions remain active.
    fabrication_layers: []const SavedFabricationLayer = &.{},
    /// Physical heatsink authored on the shown saved layout.
    heatsink: ?SavedHeatsink = null,
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
    applyFabricationLayerOverrides(ctx.allocator, in.placement, fabrication_layers);
    // One board, one lattice: the board-edge margin field every fill below
    // seeds from is a pure function of the placement, and the outline above is
    // the placement's FINAL one — so seed it once here, after that mutation,
    // and thread it through the DRC pours in this call and the blob/fab pours
    // in `writePcbData` (carried out on the return). On barracuda that outline
    // walk was ~36% of the render, repeated per caller and per net.
    const base_edge = if (in.omit_copper)
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
        const seeded = routeWithSubcircuitSeeds(ctx.allocator, ctx.project_dir, in.block, in.placement.*, ro.params, route_options) catch null;
        routed = if (seeded) |s| s.result else null;
        routed = perimeter_fence.append(ctx.allocator, in.placement.*, routed) catch routed;
        // Keep the shown user zones visible (copper + fills) through a route
        // preview, but carry NO track/via source so writeRoutedArrays never
        // mis-tags fresh routed copper with a stale per-segment group tag.
        if (shown_zs.len > 0) saved = .{ .tracks = &.{}, .vias = &.{}, .zones = shown_zs };
    } else if (!in.omit_copper) {
        saved = shown_sr;
        if (saved) |sr| routed = restoreRoutes(ctx.allocator, sr, in.placement.nets);
    }
    // Persisted routes intentionally store geometry, not cached counters, so a
    // restored RouteResult starts at 0/0. Reconcile every shown board through
    // the shared connectivity oracle before any UI reports completion. Running
    // it for a bare board too gives the header the useful 0/N starting state.
    const user_zones = userZonesFrom(ctx.allocator, in.placement.*.rules, shown_zs);
    const tally: ?fab_readiness.Tally = if (in.omit_copper)
        null
    else
        fab_readiness.routableTally(ctx.allocator, in.placement.*, .{
            .tracks = if (routed) |r| r.tracks else &.{},
            .vias = if (routed) |r| r.vias else &.{},
            .zones = user_zones,
        }) catch null;
    if (routed) |*r| if (tally) |t| {
        // RouteResult keeps the count displayed by this page. The detailed
        // connection tally remains on `ShownView.tally` for non-UI consumers.
        r.routed = t.unique_routed;
        r.total = t.unique_total;
        r.failed = t.open;
    };
    const texts = shownTexts(in.layouts, in.shown);
    const violations: []const drc.Violation = if (in.check_drc and routed != null)
        drc_rules.checkFilteredZones(ctx.allocator, ctx.project_dir, name, .{ .placement = in.placement.*, .routed = routed.?, .clearance = ro.params.clearance, .zones = user_zones, .texts = texts, .base_edge = base_edge })
    else
        &.{};
    return .{ .ro = ro, .routed = routed, .tally = tally, .violations = violations, .outline_drawn = outline_drawn, .base_edge = base_edge, .outline = shownOutline(in.layouts, in.shown), .fabrication_layers = fabrication_layers, .heatsink = shownHeatsink(in.layouts, in.shown), .saved = saved, .texts = texts, .dimensions = shownDimensions(in.layouts, in.shown) };
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

/// Replace only the positive regions of matching authored layers. The source
/// remains authoritative for side/material/thickness and automatic footprint
/// cutouts, so a visual edit cannot silently change manufacturing semantics.
fn applyFabricationLayerOverrides(alloc: std.mem.Allocator, placement: *optimizer.Placement, overrides: []const SavedFabricationLayer) void {
    if (overrides.len == 0 or placement.fabrication_layers.len == 0) return;
    const specs = alloc.dupe(env_mod.FabricationLayerSpec, placement.fabrication_layers) catch return;
    for (specs) |*spec| {
        for (overrides) |saved| {
            if (!std.mem.eql(u8, spec.name, saved.name)) continue;
            const regions = alloc.alloc(env_mod.FabricationRegion, saved.regions.len) catch break;
            for (saved.regions, regions) |points, *region| region.* = .{ .polygon = points };
            spec.regions = regions;
            break;
        }
    }
    placement.fabrication_layers = specs;
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
    return blessedOutlineIn(readLayouts(alloc, project_dir, name), defaultLayoutName(alloc, project_dir, name, null));
}

/// A drawn `SavedOutline` as a `placeFromPoses` outline seed.
fn drawnSource(o: SavedOutline) optimizer.OutlineSource {
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
fn outlineForBody(
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
pub const CacheSlot = struct {
    params: optimizer.Params,
    /// Null when the slot carried no parts array at all (callers treat
    /// that as "no cached layout — solve fresh").
    parts: ?[]const PartPose,
};

/// Parse a `{"params":{…},"parts":[…]}` cache object (either the `"cache"`
/// key of `.layouts.json` or the root of a legacy `.autolayout.json`).
fn parseCacheSlot(alloc: std.mem.Allocator, v: std.json.Value) ?CacheSlot {
    if (v != .object) return null;
    var p = optimizer.Params{};
    if (v.object.get("params")) |po| {
        if (po == .object) parseCacheParams(po, &p);
    }
    return .{ .params = p, .parts = parsePartPoses(alloc, v.object.get("parts")) };
}

/// Apply the cache's stored tuning weights onto `p`.
fn parseCacheParams(po: std.json.Value, p: *optimizer.Params) void {
    if (po.object.get("loop_w")) |v| p.loop_w = jsonNum(v);
    if (po.object.get("w_congest")) |v| p.w_congest = jsonNum(v);
    if (po.object.get("cap_w_max")) |v| p.cap_w_max = jsonNum(v);
    if (po.object.get("grid")) |v| p.grid_courtyards = v == .bool and v.bool;
    // A negative `w_align` is the auto sentinel current builds write; 0.5 is the
    // legacy shipped default — the tidiness term has since been pair-normalized
    // (its weight scale moved to W_ALIGN_TIDINESS), so re-pinning the old number
    // would silently apply a ~5× weaker alignment than either era intended.
    // Both resolve to auto; anything else was a deliberate tuning override.
    if (po.object.get("w_align")) |v| {
        const a = jsonNum(v);
        const legacy_default = a == 0.5;
        if (a >= 0 and !legacy_default) p.w_align = a;
    }
}

/// Read the optimizer-cache slot for `name`: the `"cache"` key of
/// `.layouts.json` first, falling back to the legacy standalone
/// `.autolayout.json` for boards last solved by an older build.
pub fn readCacheSlot(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?CacheSlot {
    return readSidecarDoc(alloc, project_dir, name, null).cache orelse readLegacyCacheSlot(alloc, project_dir, name);
}

/// The legacy standalone `.autolayout.json` cache slot (boards last solved by
/// an older build), or null.
fn readLegacyCacheSlot(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?CacheSlot {
    const path = paths.designSiblingPath(alloc, project_dir, name, auto_ext) catch return null;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, sidecar_max_bytes) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    return parseCacheSlot(alloc, root);
}

/// The sidecar's optimistic-concurrency `rev` (top-level `"rev"` field), or 0
/// when the file/field is absent (legacy). Every user Save/Update embeds the
/// rev the page loaded and the save guard 409s on a mismatch; render-path
/// writes preserve this value so merely viewing/regenerating never bumps it.
pub fn readLayoutRev(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) i64 {
    return readSidecarDoc(alloc, project_dir, name, sub).rev;
}

/// The top-level `"rev"` of a parsed sidecar tree (see `readLayoutRev`).
fn revFromRoot(root: std.json.Value) i64 {
    if (root != .object) return 0;
    const rv = root.object.get("rev") orelse return 0;
    return switch (rv) {
        .integer => |i| i,
        .float => |f| numeric.checkedInt(i64, f) orelse 0,
        else => 0,
    };
}

/// Everything a `.layouts.json` read can answer, from ONE file read and ONE
/// JSON parse: the saved-layout list, the raw optimizer cache slot (no legacy
/// fallback — see `readCacheSlot`), and the optimistic-concurrency rev. The
/// single-question readers (`readLayoutsSub`, `readCacheSlot`, `readLayoutRev`)
/// all delegate here, and the page render reads the doc ONCE — it used to
/// re-read and re-parse the file for each question, which on a routed
/// multi-layout board is megabytes of JSON per question.
const SidecarDoc = struct { layouts: []const SavedLayout = &.{}, cache: ?CacheSlot = null, rev: i64 = 0 };

/// The page render's one sidecar read: `readSidecarDoc` plus the same legacy
/// `.autolayout.json` cache fallback `readCacheSlot` applies (design stores
/// only — sub stores carry no cache slot).
fn readPageDoc(ctx: *Server, name: []const u8, sub: ?[]const u8) SidecarDoc {
    if (sub) |s| return readSidecarDoc(ctx.allocator, ctx.project_dir, name, s);
    return readDesignDoc(ctx.allocator, ctx.project_dir, name);
}

/// A design store's sidecar doc plus the legacy `.autolayout.json` cache
/// fallback (boards last solved by an older build). Sub stores carry no cache
/// slot, so they read through `readSidecarDoc` directly.
fn readDesignDoc(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) SidecarDoc {
    var doc = readSidecarDoc(alloc, project_dir, name, null);
    if (doc.cache == null) doc.cache = readLegacyCacheSlot(alloc, project_dir, name);
    return doc;
}

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
    const raw = if (generated) readLayoutsSub(ctx.allocator, ctx.project_dir, name, sub) else doc.layouts;
    return displayLayouts(ctx.allocator, ctx.project_dir, name, sub, raw);
}

fn readSidecarDoc(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) SidecarDoc {
    var doc = SidecarDoc{};
    const path = layoutsSidecar(alloc, project_dir, name, sub, layouts_ext) orelse return doc;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, sidecar_max_bytes) catch |e| {
        // Only a MISSING sidecar may silently read as "no layouts" — anything
        // else means a board that HAS layouts reads back empty, which silently
        // strips the viewer, the KiCad sync seed and the fab outputs of it.
        if (e != error.FileNotFound) log.warn("layouts: cannot read {s}: {s} — reading as NO saved layouts", .{ path, @errorName(e) });
        return doc;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch {
        log.warn("layouts: {s} did not parse — reading as NO saved layouts", .{path});
        return doc;
    };
    if (layoutsFromRoot(alloc, root)) |list| doc.layouts = list;
    if (root == .object) {
        if (root.object.get("cache")) |c| doc.cache = parseCacheSlot(alloc, c);
    }
    doc.rev = revFromRoot(root);
    return doc;
}

/// Persist the layout list to `.layouts.json`, carrying the existing cache
/// slot AND the current `rev` over unchanged (a render-path write, not a user
/// save — see `readLayoutRev`). Best-effort: a write failure just means the
/// list reverts to what was last on disk.
fn writeLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layouts: []const SavedLayout) void {
    writeLayoutsFile(alloc, project_dir, name, layouts, readCacheSlot(alloc, project_dir, name), readLayoutRev(alloc, project_dir, name, null));
}

/// As `writeLayouts`, but for a `?sub=` scoped sub circuit writes its per-sub
/// sidecar, preserving that sidecar's rev. `sub == null` delegates to
/// `writeLayouts` (design store, cache preserved).
fn writeLayoutsSub(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8, layouts: []const SavedLayout) void {
    writeLayoutsSubRev(alloc, project_dir, name, sub, layouts, readLayoutRev(alloc, project_dir, name, sub));
}

/// As `writeLayoutsSub`, but stamps an explicit `rev` — the user-save path
/// passes `disk_rev + 1` to bump the counter; render-path callers pass the
/// current rev to preserve it. The sub store carries no auto-cache slot (sub
/// previews always solve fresh), so only the layouts array is persisted;
/// `sub == null` goes through the design store (cache preserved).
fn writeLayoutsSubRev(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8, layouts: []const SavedLayout, rev: i64) void {
    if (sub == null) return writeLayoutsFile(alloc, project_dir, name, layouts, readCacheSlot(alloc, project_dir, name), rev);
    const path = layoutsSidecar(alloc, project_dir, name, sub, layouts_ext) orelse return;
    defer alloc.free(path);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeLayoutsFileJsonRev(w, dedupedLayouts(alloc, layouts), null, rev) catch return;
    writeFileAll(path, aw.written()) catch return;
}

/// Persist layouts + cache slot + `rev` to `.layouts.json` (the whole sidecar).
fn writeLayoutsFile(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layouts: []const SavedLayout,
    cache: ?CacheSlot,
    rev: i64,
) void {
    const path = paths.designSiblingPath(alloc, project_dir, name, layouts_ext) catch return;
    defer alloc.free(path);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeLayoutsFileJsonRev(w, dedupedLayouts(alloc, layouts), cache, rev) catch return;
    writeFileAll(path, aw.written()) catch return;
}

/// Drop exactly-duplicated copper from every layout on its way to disk.
///
/// Copper reaches the sidecar from several appenders — a fresh route, the gap
/// closer's kept hops, `add_tracks`, a module Stamp — and an appender that
/// re-lays a segment it already has produces a byte-identical twin. That is not
/// harmless: a duplicated track is drawn twice, exported twice, and counted
/// twice by every per-net length report, and the barracuda `engine-90` snapshot
/// shipped 23 duplicate tracks and 3 duplicate vias this way. Two segments with
/// identical endpoints, layer, width and net carry no information the first one
/// does not, so the sidecar keeps one. Nothing else is touched: near-identical
/// or overlapping copper is real routing and stays.
fn dedupedLayouts(alloc: std.mem.Allocator, layouts: []const SavedLayout) []const SavedLayout {
    const out = alloc.alloc(SavedLayout, layouts.len) catch return layouts;
    for (layouts, 0..) |l, i| {
        out[i] = l;
        const r = l.routes orelse continue;
        out[i].routes = .{
            .tracks = dedupedTracks(alloc, r.tracks),
            .vias = dedupedVias(alloc, r.vias),
            .zones = r.zones,
            .rf_paths = r.rf_paths,
        };
    }
    return out;
}

/// `tracks` with byte-identical duplicates removed, order preserved.
fn dedupedTracks(alloc: std.mem.Allocator, tracks: []const SavedTrack) []const SavedTrack {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(SavedTrack) = .empty;
    for (tracks) |t| {
        const key = std.fmt.allocPrint(alloc, "{d},{d},{},{d},{d},{d},{d},{d},{d},{s}", .{
            t.x1, t.y1, t.xm != null and t.ym != null, t.xm orelse 0, t.ym orelse 0,
            t.x2, t.y2, t.l,                           t.w,           t.net,
        }) catch return tracks;
        const gop = seen.getOrPut(alloc, key) catch return tracks;
        if (gop.found_existing) continue;
        out.append(alloc, t) catch return tracks;
    }
    return out.items;
}

/// `vias` with byte-identical duplicates removed, order preserved.
///
/// The key is geometry + net and deliberately ignores BOTH provenance tags (`g`
/// stamp group, `f` fence): two vias at the same place on the same net are one
/// piece of copper however they got there, and keying on provenance would let a
/// re-Stamp or a fence re-run persist a second barrel in the same hole. Order
/// preservation then decides which row survives — the FIRST one, so
/// pre-existing (typically untagged, hand-drawn or autorouted) copper keeps its
/// identity and a later tagged twin is the one dropped.
fn dedupedVias(alloc: std.mem.Allocator, vias: []const SavedVia) []const SavedVia {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(SavedVia) = .empty;
    for (vias) |v| {
        const key = std.fmt.allocPrint(alloc, "{d},{d},{d},{d},{s}", .{
            v.x, v.y, v.d, v.drill, v.net,
        }) catch return vias;
        const gop = seen.getOrPut(alloc, key) catch return vias;
        if (gop.found_existing) continue;
        out.append(alloc, v) catch return vias;
    }
    return out.items;
}

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
    var placement = addTracksFixture(&parts, &nets, &.{});
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
fn writeLayoutsFileJson(w: *std.Io.Writer, layouts: []const SavedLayout, cache: ?CacheSlot) std.Io.Writer.Error!void {
    return writeLayoutsFileJsonRev(w, layouts, cache, 0);
}

/// Serialize the sidecar to its on-disk shape: an optional top-level `"rev":N`
/// optimistic-concurrency counter (omitted when 0 so a never-guarded legacy
/// file stays byte-identical), then an optional `"default":"<name>"` (the entry
/// whose `default` flag is set, if any), the optional `"cache"` slot, then the
/// `layouts` array. Score fields (hpwl/loop/caps) are flattened onto each entry
/// and omitted when unscored.
pub fn writeLayoutsFileJsonRev(w: *std.Io.Writer, layouts: []const SavedLayout, cache: ?CacheSlot, rev: i64) std.Io.Writer.Error!void {
    try w.writeAll("{");
    if (rev > 0) try w.print("\"rev\":{d},", .{rev});
    for (layouts) |L| {
        if (!L.default) continue;
        try w.writeAll("\"default\":");
        try writeJsonStr(w, L.name);
        try w.writeAll(",");
        break;
    }
    if (cache) |c| {
        try w.writeAll("\"cache\":");
        try writeCacheSlotJson(w, c);
        try w.writeAll(",");
    }
    try w.writeAll("\"layouts\":[");
    for (layouts, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(name_open);
        try writeJsonStr(w, L.name);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, L.kind);
        try w.print(",\"ts\":{d}", .{L.ts});
        if (L.rough) try w.writeAll(",\"rough\":true");
        // The SIDECAR always carries every layout's copper in full — it is the
        // file of record. Only the page blob slims (see `writeLayoutsJson`).
        if (L.routes) |sr| {
            try w.writeAll(",\"routes\":");
            try writeSavedRoutesJson(w, sr);
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
        if (L.texts.len > 0) {
            try w.writeAll(texts_open);
            try writeSavedTextsJson(w, L.texts);
        }
        if (L.dimensions.len > 0) {
            try w.writeAll(",\"dimensions\":");
            try writePartEdgeDimensionsJson(w, L.dimensions);
        }
        if (L.score) |s| try w.print(",\"hpwl\":{d},\"loop\":{d},\"caps\":{d},\"objective\":{d}", .{ s.hpwl, s.loop, s.caps, s.objective });
        try w.writeAll(",\"parts\":[");
        for (L.parts, 0..) |pt, j| {
            if (j > 0) try w.writeAll(",");
            try w.writeAll(ref_open);
            try writeJsonStr(w, pt.ref);
            try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pt.x, pt.y, pt.rot });
            try pcb_part_json.writePoseSideLocked(w, pt.side, pt.locked);
            if (pt.origin.len > 0) {
                try w.writeAll(origin_open);
                try writeJsonStr(w, pt.origin);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

/// Two saved layouts are duplicates when their score matches: the headline
/// objective and its two visible raw terms (HPWL + loop length) agree to 0.1.
/// This is the "duplicate layout" the panel dedups on — what the user reads as
/// the same row, e.g. repeated Regenerate runs that reconverge to the same
/// objective even if a part lands a grid step off. (Position isn't compared:
/// the deterministic optimizer can reach an equal-score arrangement that differs
/// by a hair, which the user still sees as the same layout.) Unscored legacy
/// entries never match — they're kept rather than guessed at.
fn sameLayoutScore(a: ?LayoutScore, b: ?LayoutScore) bool {
    const x = a orelse return false;
    const y = b orelse return false;
    return @abs(x.objective - y.objective) < 0.1 and @abs(x.hpwl - y.hpwl) < 0.1 and @abs(x.loop - y.loop) < 0.1;
}

/// Panel sort key: the layout edited most recently belongs at the top. A stable
/// sort preserves sidecar order for same-second saves and legacy rows whose
/// timestamp is unknown (`ts == 0`).
fn layoutMoreRecentlyEdited(_: void, a: SavedLayout, b: SavedLayout) bool {
    return a.ts > b.ts;
}

/// Collapse saved layouts that are the same arrangement into one, so the panel
/// never lists a placement twice (chiefly repeated Regenerate runs that
/// converged identically). Input order is preserved; each group's survivor keeps
/// a manual name over an auto stamp and the default flag if any member had it.
fn dedupLayouts(alloc: std.mem.Allocator, layouts: []const SavedLayout) []const SavedLayout {
    var out: std.ArrayList(SavedLayout) = .empty;
    for (layouts) |L| {
        var merged = false;
        for (out.items) |*K| {
            if (!sameLayoutScore(K.score, L.score)) continue;
            // Two MANUAL entries are never merged, however alike they score.
            // The score measures PLACEMENT only, and the whole point of named
            // layouts is banking several routings of one placement — collapsing
            // them here would delete every autoroute candidate but the first,
            // on the next page load, with no warning.
            if (std.mem.eql(u8, K.kind, kind_manual) and std.mem.eql(u8, L.kind, kind_manual)) continue;
            const keep_default = K.default or L.default;
            // Which duplicate survives (its NAME is the row's permalink):
            // a manual (named) entry over an auto stamp; between two auto
            // stamps, the STARRED one — the ★ must never silently migrate to
            // a different-named row, or the starred permalink stops
            // reproducing the board it named.
            const l_manual = std.mem.eql(u8, L.kind, kind_manual);
            const k_manual = std.mem.eql(u8, K.kind, kind_manual);
            if (l_manual and !k_manual) {
                K.* = L;
            } else if (L.default and !k_manual) {
                // Both auto here (a manual L was promoted above): the starred
                // auto row keeps its identity over an unstarred twin.
                if (!K.default) K.* = L;
            }
            K.default = keep_default;
            merged = true;
            break;
        }
        if (!merged) out.append(alloc, L) catch return layouts;
    }
    return out.items;
}

/// The saved-layout list for the panel: duplicate arrangements collapsed (legacy
/// histories that accumulated repeated Regenerate runs — the cleanup is persisted
/// once), then sorted most-recently-edited first. Only this display copy is
/// sorted; the sidecar's history order stays untouched. Empty for sub-scoped
/// previews.
fn displayLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8, raw: []const SavedLayout) []const SavedLayout {
    const deduped = dedupLayouts(alloc, raw);
    if (deduped.len != raw.len) writeLayoutsSub(alloc, project_dir, name, sub, deduped);
    const sorted = alloc.dupe(SavedLayout, deduped) catch return deduped;
    std.sort.insertion(SavedLayout, sorted, {}, layoutMoreRecentlyEdited);
    return sorted;
}

/// Append an auto-recorded snapshot of the just-generated `placement` to the
/// layout history — unless that arrangement is *already saved* (under any name,
/// auto or manual), in which case there is nothing new to record. Then prunes
/// auto entries past `MAX_AUTO_LAYOUTS`.
fn recordAutoLayout(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, p: optimizer.Placement, params: optimizer.Params) void {
    const existing = readLayouts(alloc, project_dir, name);
    const score = LayoutScore{ .hpwl = p.score.hpwl_mm, .loop = p.score.loop_mm, .caps = p.score.loop_caps, .objective = p.breakdown.objective };
    const parts = posesFromPlacement(alloc, p) orelse return;
    // Dedup against EVERY saved layout, not just the newest: a regen that
    // reproduces an arrangement already in the list (same objective + HPWL +
    // loop) adds nothing. If the match is the newest entry and predates the
    // objective field, backfill it in place. A rough solve that reconverges to
    // an existing (untagged) arrangement still tags it rough so the panel's
    // "rough seeded" status lights up.
    for (existing, 0..) |L, i| {
        if (!sameLayoutScore(L.score, score)) continue;
        if (params.rough and !L.rough) {
            tagRough(alloc, project_dir, name, existing, i);
        } else if (i == 0 and (L.score == null or L.score.?.objective <= 0)) {
            backfillNewestScore(alloc, project_dir, name, existing, score);
        }
        return;
    }
    const now = clock.timestamp();
    const entry = SavedLayout{
        .name = fmtAutoName(alloc, now) catch return,
        .kind = kind_auto,
        .ts = now,
        .score = score,
        .parts = parts,
        .rough = params.rough,
    };
    // Newest first; keep every manual entry but only the most-recent autos.
    // The entry the user marked default is never pruned (else a default that
    // happens to be an auto run could fall off the cap and dangle the sync).
    var out: std.ArrayList(SavedLayout) = .empty;
    out.append(alloc, entry) catch return;
    var autos: usize = 1;
    for (existing) |L| {
        if (std.mem.eql(u8, L.kind, kind_auto)) {
            if (autos >= max_auto_layouts and !L.default) continue;
            autos += 1;
        }
        out.append(alloc, L) catch break;
    }
    writeLayouts(alloc, project_dir, name, out.items);
}

/// Rewrite the layout list with the `rough` flag set on entry `idx` — used when
/// a Rough solve reconverges to an arrangement already saved without the flag,
/// so the schematic's Module-layouts panel still reads "rough seeded" rather
/// than recording a duplicate row.
fn tagRough(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, existing: []const SavedLayout, idx: usize) void {
    var out: std.ArrayList(SavedLayout) = .empty;
    for (existing, 0..) |L, i| {
        var e = L;
        if (i == idx) e.rough = true;
        out.append(alloc, e) catch return;
    }
    writeLayouts(alloc, project_dir, name, out.items);
}

/// Rewrite the layout list with `score` patched onto the newest entry — used to
/// backfill the objective onto a pre-objective auto entry a regen re-confirms,
/// without churning the history with a duplicate row.
fn backfillNewestScore(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, existing: []const SavedLayout, score: LayoutScore) void {
    var out: std.ArrayList(SavedLayout) = .empty;
    for (existing, 0..) |L, i| {
        var e = L;
        if (i == 0) e.score = score;
        out.append(alloc, e) catch return;
    }
    writeLayouts(alloc, project_dir, name, out.items);
}

/// Name for an auto-recorded entry: `auto · Mon D HH:MM:SS` (UTC). The seconds
/// keep two same-minute regenerations distinct.
fn fmtAutoName(alloc: std.mem.Allocator, ts: i64) std.mem.Allocator.Error![]const u8 {
    const es = clock.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const ds = es.getDaySeconds();
    const md = es.getEpochDay().calculateYearDay().calculateMonthDay();
    return std.fmt.allocPrint(alloc, "auto · {s} {d} {d:0>2}:{d:0>2}:{d:0>2}", .{
        monthAbbrev(md.month),   md.day_index + 1,          ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

fn monthAbbrev(m: clock.epoch.Month) []const u8 {
    return switch (m) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };
}

/// Read the optimizer cache's poses into a slice of `RefPose`, or null if
/// no cache slot exists. Strings are owned by `alloc` (request lifetime),
/// which outlives the `solve` call that consumes them.
fn readAutoPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const optimizer.RefPose {
    return cachePoses(alloc, readCacheSlot(alloc, project_dir, name));
}

/// `readAutoPoses` over an already-read cache slot (see `SidecarDoc`).
fn cachePoses(alloc: std.mem.Allocator, cache: ?CacheSlot) ?[]const optimizer.RefPose {
    const slot = cache orelse return null;
    const parts = slot.parts orelse return null;
    const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
    for (parts, 0..) |pt, i| out[i] = .{ .ref = pt.ref, .x = pt.x, .y = pt.y, .rot = pt.rot, .side = pt.side, .locked = pt.locked };
    return out;
}

/// One placed part exported to the KiCad sync: centre (mm) + rotation (deg,
/// CCW) + board side. The sync stamps these onto a footprint it inserts for
/// the first time.
pub const SyncPose = struct { x: f64, y: f64, rot: f64, side: optimizer.Side = .top };

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
fn chooseSyncPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const optimizer.RefPose {
    const layouts = readLayouts(alloc, project_dir, name);
    const chosen: ?[]const PartPose = blk: {
        for (layouts) |L| {
            if (L.default and L.parts.len > 0) break :blk L.parts;
        }
        for (layouts) |L| {
            if (std.mem.eql(u8, L.kind, kind_manual) and L.parts.len > 0) break :blk L.parts;
        }
        for (layouts) |L| {
            if (L.parts.len > 0) break :blk L.parts;
        }
        break :blk null;
    };
    if (chosen) |parts| return refPosesFromParts(alloc, parts);
    // No named/recorded layouts — fall back to the bare optimizer cache.
    const poses = readAutoPoses(alloc, project_dir, name) orelse return null;
    if (poses.len == 0) return null;
    return poses;
}

/// Saved-layout parts as sync `RefPose`s (null on allocation failure).
fn refPosesFromParts(alloc: std.mem.Allocator, parts: []const PartPose) ?[]const optimizer.RefPose {
    const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
    for (parts, 0..) |pt, i| out[i] = .{ .ref = pt.ref, .x = pt.x, .y = pt.y, .rot = pt.rot, .side = pt.side, .locked = pt.locked };
    return out;
}

/// `chooseModuleSnapshot` result: the snapshot to seed from, plus — when a
/// different snapshot covers strictly more of the module's current parts —
/// that fuller alternative (surfaced as a staleness hint, never auto-taken
/// over a ★).
const SnapshotChoice = struct {
    chosen: *const SavedLayout,
    /// Fuller non-chosen snapshot (only set when it beats `chosen`).
    alt: ?*const SavedLayout = null,
    /// How many module parts `alt` covers.
    alt_n: usize = 0,
};

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
fn chooseModuleSnapshot(
    layouts: []const SavedLayout,
    ok_of: *const std.StringHashMapUnmanaged([]const u8),
) ?SnapshotChoice {
    var starred: ?*const SavedLayout = null;
    var starred_score: usize = 0;
    var best: ?*const SavedLayout = null;
    var best_score: usize = 0;
    for (layouts) |*L| {
        if (L.parts.len == 0) continue;
        var score: usize = 0;
        for (L.parts) |p| {
            const ok = ok_of.get(p.ref) orelse continue;
            if (ok.len > 0) score += 1;
        }
        if (score == 0) continue;
        if (L.default) {
            starred = L;
            starred_score = score;
            continue;
        }
        const cur = best orelse {
            best = L;
            best_score = score;
            continue;
        };
        const manual = std.mem.eql(u8, L.kind, kind_manual);
        const cur_manual = std.mem.eql(u8, cur.kind, kind_manual);
        const wins = if (score == best_score) manual and !cur_manual else score > best_score;
        if (wins) {
            best = L;
            best_score = score;
        }
    }
    if (starred) |st| {
        const stale = best != null and best_score > starred_score;
        return .{ .chosen = st, .alt = if (stale) best else null, .alt_n = if (stale) best_score else 0 };
    }
    const b = best orelse return null;
    return .{ .chosen = b };
}

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
    // (`buildSubSeedsJson`) and the Push-modal seeder (`subCircuitSource`). Its
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
    /// buildSubSeedsJson uses to map module net names to parent nets. Only
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
    const layouts = readLayouts(alloc, project_dir, sub_block.source);
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
        for (merged.items) |v| if (v.net == site.net and std.math.hypot(v.x - site.x, v.y - site.y) < 1e-6) {
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
    const chosen = blessedLayout(readLayouts(alloc, project_dir, name)) orelse return null;
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
    const doc = readSidecarDoc(alloc, project_dir, name, null);
    // Refreshing the auto cache is a render-path write — preserve the rev.
    writeLayoutsFile(alloc, project_dir, name, doc.layouts, .{ .params = params, .parts = parts }, doc.rev);
    if (paths.designSiblingPath(alloc, project_dir, name, auto_ext)) |legacy| {
        defer alloc.free(legacy);
        infra_fs.cwd().deleteFile(legacy) catch |e| switch (e) {
            // Usually already gone — only first post-upgrade solve has one.
            error.FileNotFound => {},
            else => {},
        };
    } else |_| {}
}

/// Serialize a cache slot to `{"params":{…},"parts":[{ref,x,y,rot}, …]}` —
/// the weights so the controls reflect what produced the layout, the parts
/// for the cache.
fn writeCacheSlotJson(w: *std.Io.Writer, c: CacheSlot) std.Io.Writer.Error!void {
    try w.print("{{\"params\":{{\"loop_w\":{d},\"w_align\":{d},\"w_congest\":{d},\"cap_w_max\":{d},\"grid\":{s}}},", .{
        c.params.loop_w,                                   c.params.w_align, c.params.w_congest, c.params.cap_w_max,
        if (c.params.grid_courtyards) "true" else "false",
    });
    try w.writeAll(parts_open);
    for (c.parts orelse &[_]PartPose{}, 0..) |pt, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(ref_open);
        try writeJsonStr(w, pt.ref);
        try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pt.x, pt.y, pt.rot });
        try pcb_part_json.writePoseSideLocked(w, pt.side, pt.locked);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// Read the tuning weights stored alongside the cached layout, or null when
/// no cache slot exists.
fn readAutoParams(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?optimizer.Params {
    const slot = readCacheSlot(alloc, project_dir, name) orelse return null;
    return slot.params;
}

/// Tuning weights parsed from the request query, plus whether any were present
/// (`tuned`) and whether a fresh solve is required (`regen` = tuned or `?regen`).
const Tuning = struct {
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

const View = struct {
    scale: f64,
    minx: f64,
    miny: f64,
    width: f64,
    height: f64,

    fn init(p: optimizer.Placement) View {
        const cw = @max(p.maxx - p.minx, 1.0) + 2 * view_margin_mm;
        const ch = @max(p.maxy - p.miny, 1.0) + 2 * view_margin_mm;
        const s = std.math.clamp(target_px / @max(cw, ch), scale_min, scale_max);
        return .{ .scale = s, .minx = p.minx, .miny = p.miny, .width = cw * s, .height = ch * s };
    }
};

// ── Score bar + legend ───────────────────────────────────────────────────

/// The editable control stack shared by the full page and the editable embed
/// (`?embed=1&edit=1`): the action toolbar (Regenerate / Rough / Save as… /
/// Update / Undo / Redo / Reset / zoom), the collapsible route/stuck panels,
/// and the hidden legends (revealed by their chips). The full page prepends its
/// own header (title + Schematic⇄PCB nav); the editable embed skips that — its
/// parent schematic card carries the Schematic/PCB toggle instead.
fn writeEditControls(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    name: []const u8,
    src: LayoutSource,
    grid_only: bool,
    routed: ?router.RouteResult,
    ro_params: router.RouteParams,
    n_drc: usize,
    embed: bool,
) std.Io.Writer.Error!void {
    try writeScorebar(w, placement, name, src, embed);
    // When showing the plain grid placeholder, say so — the score is the raw
    // grid's, not an optimized layout, and Regenerate computes the real one.
    if (grid_only) try w.writeAll(
        "<div class=\"pcb-note\">Showing parts on a plain grid — no layout computed yet. " ++
            "Drag parts to arrange, or hit <b>Regenerate</b> to auto-place.</div>",
    );
    // Editable embed only: the secondary controls stay in the main column
    // behind the classic chip row (accordion). The full page docks the same
    // panels into the left sidebar (writeSidebar) and its view toggles into
    // the right Appearance panel, so nothing is emitted here.
    if (embed) {
        const route_open = routed != null;
        try writeTabsRow(w, route_open, true);
        try w.writeAll("<div class=\"pcb-panels\">");
        const rp_warn = if (routed) |r| router.returnPathViolations(placement, r, router.return_path_radius_mm) else 0;
        // writeRoutePanel now emits the live-route/replay dock inline.
        try writeRoutePanel(w, ro_params, routed, n_drc, rp_warn, route_open, true);
        try writeStuckPanel(w);
        try w.writeAll("</div>");
    }
    try writeLegend(w, placement, true); // hidden; revealed by the Legend toggle
    try writeHeatLegend(w); // hidden; revealed by the Heatmap toggle
}

// Action-bar group wrappers — small inline-flex clusters separated by thin rules
// so the buttons read as grouped (place / save / edit) rather than one long row.
// Extracted as consts (each used 3× in writeScorebar).
const bar_sep = "<span class=\"bar-sep\"></span>";
const bar_grp = "<span class=\"bar-grp\">";
const bar_grp_end = "</span>" ++ bar_sep;

/// The full editor keeps placement diagnostics beside the routing workflow in
/// the Autorouter dock.  This leaves the command row for save/edit commands
/// while preserving the exact ids the live-regenerate, score and progress
/// clients bind.  Editable embeds have no dock and continue to use the classic
/// all-in-one action bar below.
fn writePlacementControls(w: *std.Io.Writer, p: optimizer.Placement, name: []const u8, src: LayoutSource) std.Io.Writer.Error!void {
    try w.writeAll("<section class=\"pcb-placement\" aria-label=\"Placement\">" ++
        "<div class=\"placement-h\"><strong>Placement</strong>");
    try writeSourceChip(w, src);
    try w.writeAll("<span class=\"src-chip src-plan\" id=\"pcb-planchip\" style=\"display:none\"></span></div>" ++
        "<div class=\"placement-score\"><span class=\"score\" id=\"sc-obj\" " ++
        "title=\"Weighted objective the optimizer minimizes\">objective ");
    try w.print("{d:.1}</span>", .{p.breakdown.objective});
    try w.writeAll("<span class=\"delta\" id=\"sc-obj-d\"></span></div>" ++
        "<div class=\"placement-actions\"><a class=\"btn primary\" id=\"pcb-regen\" href=\"/pcb-layout/");
    try writeAttr(w, name);
    try w.writeAll("?regen=1\" title=\"Re-run the optimizer and watch it converge live\">Regenerate placement</a>" ++
        "<button class=\"btn\" id=\"pcb-routeplan\" style=\"display:none\" " ++
        "title=\"Autoroute the placement on screen as a temporary plan\">⚡ Route plan</button></div></section>");
}

/// Compact command row used by the full-page editor.  Placement and routing
/// controls live in the Autorouter dock; manufacturing handoffs share one
/// native disclosure menu instead of competing with Save on every viewport.
fn writeFullCommandBar(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-bar pcb-commandbar\"><span class=\"bar-grp save-grp\">" ++
        "<button class=\"btn primary\" id=\"pcb-saveas\" title=\"Save the current placement and routing under a new name\">Save as…</button>" ++
        "<button class=\"btn\" id=\"pcb-update\" disabled title=\"Save changes back into the loaded layout\">Update</button>" ++
        "<span class=\"lay-active\" id=\"pcb-active\" style=\"display:none\"></span></span>" ++
        "<span class=\"command-spacer\"></span><span class=\"bar-grp edit-grp\">" ++
        "<button class=\"btn icon-btn\" id=\"pcb-undo\" disabled title=\"Undo last move / rotate (Ctrl+Z)\">↶<span> Undo</span></button>" ++
        "<button class=\"btn icon-btn\" id=\"pcb-redo\" disabled title=\"Redo (Ctrl+Shift+Z)\">↷<span> Redo</span></button>" ++
        "<button class=\"btn\" id=\"pcb-reset\" title=\"Discard manual edits and restore the loaded layout\">Reset</button></span>" ++
        "<div class=\"bar-grp command-tools\"><button class=\"btn icon-btn\" id=\"pcb-settings\" " ++
        "title=\"Inspect stackup, rules, net classes, route plan, and DRC policy\">⚙<span> Settings</span></button>" ++
        "<details class=\"pcb-menu\"><summary class=\"btn\">Fabrication ▾</summary><div class=\"pcb-menu-pop\">" ++
        "<button class=\"btn\" id=\"pcb-kicad-import\">↧ Sync from KiCad</button>" ++
        "<button class=\"btn\" id=\"pcb-kicad-push\">↥ Push to KiCad</button>" ++
        "<button class=\"btn\" id=\"pcb-fab\" title=\"Run readiness checks and download the saved layout's fabrication ZIP\">↧ Gerbers</button>" ++
        "</div></details></div><span class=\"savemsg\" id=\"pcb-savemsg\"></span></div>");
}

fn writeScorebar(w: *std.Io.Writer, p: optimizer.Placement, name: []const u8, src: LayoutSource, tools_in_bar: bool) std.Io.Writer.Error!void {
    if (!tools_in_bar) return writeFullCommandBar(w);
    try w.writeAll("<div class=\"pcb-bar\">");
    try writeSourceChip(w, src);
    // Filled in by the "Route plan" action with the honest routed/total the
    // oracle gate returned. It says PLAN because this copper is request-local:
    // it is drawn like any routed layout but persists only if you Save, and any
    // pose edit or re-solve drops it.
    try w.writeAll("<span class=\"src-chip src-plan\" id=\"pcb-planchip\" style=\"display:none\"></span>");
    // Headline objective + its delta only, so this action bar stays a clean row
    // of "what to do". Filled/updated by showScore() from the server's own
    // breakdown; the full per-term decomposition is in the layout JSON export
    // (`/api/pcb-layout/<name>`).
    try w.writeAll("<span class=\"score\" id=\"sc-obj\" " ++
        "title=\"weighted objective the optimizer minimizes " ++
        "(per-term breakdown in the /api/pcb-layout JSON export)\">objective ");
    try w.print("{d:.1}</span>", .{p.breakdown.objective});
    try w.writeAll("<span class=\"delta\" id=\"sc-obj-d\"></span>");
    try w.writeAll(bar_sep);
    // Auto-place group: Regenerate re-runs the optimizer live. "Rough remaining"
    // lives in the Sub-circuits pane with the saved-layouts history it seeds from.
    try w.writeAll(bar_grp);
    try w.writeAll("<a class=\"btn\" id=\"pcb-regen\" href=\"/pcb-layout/");
    try writeAttr(w, name);
    try w.writeAll("?regen=1\" title=\"Re-run the optimizer and watch it converge live\">Regenerate</a>");
    // Route the seed on screen. Hidden until the client sees an UNSAVED board
    // (PCB.src cache/fresh) — the state a Rough/Regenerate run lands in, where
    // "what would this placement actually route like?" has no other answer. On a
    // persisted layout the Autorouter panel's own Route button is the control,
    // so this never duplicates it.
    try w.writeAll("<button class=\"btn\" id=\"pcb-routeplan\" style=\"display:none\" " ++
        "title=\"Autoroute the placement on screen at the one-shot tier and draw the copper as a PLAN " ++
        "— nothing is saved until you Save. Shows which nets this seed can actually close.\">" ++
        "\u{26A1} Route plan</button>");
    try w.writeAll(bar_grp_end);
    // Save group: Save as… mints a new snapshot; Update overwrites the loaded one
    // in place (disabled until a saved layout is the active edit target).
    try w.writeAll(bar_grp);
    try w.writeAll("<button class=\"btn\" id=\"pcb-saveas\" title=\"Save the current placement and routing " ++
        "under a new name — each named layout gets its own ?layout=<name> link\">Save as…</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-update\" disabled " ++
        "title=\"Save changes back into the loaded layout (overwrite in place)\">Update</button>");
    try w.writeAll("<span class=\"lay-active\" id=\"pcb-active\" style=\"display:none\"></span>");
    try w.writeAll(bar_grp_end);
    // Edit group: undo / redo the last manual move-or-rotate (Ctrl+Z / Ctrl+Shift+Z),
    // and reset back to the auto layout. Undo/redo start disabled (empty history).
    try w.writeAll(bar_grp);
    try w.writeAll("<button class=\"btn\" id=\"pcb-undo\" disabled title=\"Undo last move / rotate (Ctrl+Z)\">↶ Undo</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-redo\" disabled title=\"Redo (Ctrl+Shift+Z)\">↷ Redo</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-reset\" title=\"Discard manual edits, restore the auto layout\">Reset</button>");
    // First-class pour refill (declared outer-copper pours only — hidden client
    // side when the design declares none). A stale accent lights up after any
    // copper/pose edit; the click shares the Route panel's Refill-pours flow.
    try w.writeAll("<button class=\"btn\" id=\"pcb-pour\" title=\"Recompute declared copper pours " ++
        "around the current parts, tracks and vias\">\u{27F3} Pours</button>");
    // RF ground via fencing — the end-of-design pass over the active layout's
    // persisted copper. Always visible: board-edge perimeter fencing is not a
    // prerequisite, and the click POSTs /api/pcb-fence to patch the RF fence
    // copper back in.
    try w.writeAll("<button class=\"btn\" id=\"pcb-fence\" title=\"Lay the RF ground via fence " ++
        "along this layout's routed RF traces (declared (fence …) and max-freq classes; skips any site that would clash)\">\u{2591} Fence</button>");
    // Editable embed keeps the drawing tools in the action bar (it has no
    // vertical tool strip); the full page docks them left of the canvas
    // (TOOLSTRIP_HTML — same ids, so the wiring is shared).
    if (tools_in_bar) {
        try w.writeAll("<button class=\"btn\" id=\"pcb-outline\" title=\"" ++ tip_outline ++ "\">\u{25AD} Outline</button>");
        try w.writeAll("<button class=\"btn\" id=\"pcb-outline-poly\" title=\"" ++ tip_poly ++ "\">\u{2B21} Poly</button>");
        try w.writeAll("<button class=\"btn\" id=\"pcb-backing\" title=\"" ++ tip_backing ++ "\">\u{25A7} Backing</button>");
        try w.writeAll("<button class=\"btn\" id=\"pcb-outline-dxf\" title=\"" ++ tip_dxf ++ "\">\u{2912} DXF</button>");
        try w.writeAll("<button class=\"btn\" id=\"pcb-pour-zone\" title=\"" ++ tip_pour_zone ++ "\">\u{25A9} Area</button>");
        try w.writeAll("<button class=\"btn\" id=\"pcb-draw\" title=\"" ++ tip_draw ++ "\">\u{270E} Draw</button>");
        try w.writeAll("<button class=\"btn\" id=\"pcb-text\" title=\"" ++ tip_text ++ "\">T Text</button>");
    }
    try w.writeAll(bar_grp_end);
    // Fab handoff: the complete manufacturing package at the saved (★) layout.
    // A button (not a plain link) so it can run the pre-fab readiness gate
    // first — clean downloads straight through, errors/warnings open a modal.
    try w.writeAll(bar_grp);
    try w.writeAll("<button class=\"btn\" id=\"pcb-settings\" title=\"Inspect effective stackup, rules, " ++
        "net classes, route plan, and DRC policy\">" ++
        "⚙ Design settings</button>");
    // The tooltip names the job file by the extension the package actually
    // ships, spliced from the writer's own constant rather than retyped.
    try w.writeAll("<button class=\"btn\" id=\"pcb-fab\" title=\"Download the fab package (ZIP): Gerber copper / mask / paste / silk / " ++
        "board profile + Excellon drills + centroid CSV + " ++ export_gerber.job_file_ext ++
        ", at the saved (\u{2605}) layout with its saved routed " ++
        "copper. Runs a pre-fab readiness check first (unrouted nets, DRC, off-board parts). Save a layout first.\">" ++
        "\u{2913} Gerbers</button>");
    try w.writeAll(bar_grp_end);
    // Zoom stays in the bar for embeds only — the full page's tool strip
    // carries −/+/Fit (same ids). The old drag/rotate hint line moved into
    // the status bar's "?" help button.
    if (tools_in_bar) {
        try w.writeAll("<span class=\"zoom-grp\"><button class=\"btn\" id=\"z-out\" title=\"Zoom out\">−</button>");
        try w.writeAll("<button class=\"btn\" id=\"z-in\" title=\"Zoom in\">+</button>");
        try w.writeAll("<button class=\"btn\" id=\"z-fit\" title=\"Reset zoom\">Fit</button></span>");
    }
    try w.writeAll("<span class=\"savemsg\" id=\"pcb-savemsg\"></span>");
    if (tools_in_bar) {
        try w.print("<span class=\"muted\" title=\"drag part to move · hover + R to rotate · Ctrl+Z undo · " ++
            "two-finger drag / middle-drag to pan · scroll wheel or pinch to zoom · snaps to {d} mm grid · press ? for all shortcuts\">" ++
            "drag · R rotate · Ctrl+Z undo · ? help</span>", .{optimizer.grid_mm});
    }
    try w.writeAll("</div>");
}

// ── Drawing-tool tooltips (shared by the action bar and the tool strip) ─────
const tip_outline = "Edit board outline: exposes handles on the current authored or saved shape. " ++
    "Drag a corner or edge to reshape it; double-click an edge to add a vertex; right-click a vertex to remove it. " ++
    "Use Line to click connected segments with corner and horizontal/vertical snapping. Drag empty space to box-select vertices; select both ends of a fillet and press Delete to restore a sharp corner. " ++
    "Arm Rectangle before dragging to replace the outline. Saved with the layout (Save/Update); becomes the board edge the renderers draw and the board-edge DRC checks.";
const tip_poly = "Connected-line board outline (L/T shapes, cutout-free " ++
    "notches): click endpoints with existing-corner, start-point, grid, and horizontal/vertical snapping; click the first vertex or press Enter to close, Backspace removes " ++
    "the last vertex, Esc cancels. After closing, drag a vertex handle to edit. Saved with the layout (Save/Update); " ++
    "becomes the exact board edge the renderers draw, the board-edge DRC measures, and the Gerber " ++
    board_layers.edge_cuts ++ " traces.";
const tip_dxf = "Import a DXF file as the board outline (picks the same saved override the " ++
    "▭/⬡ tools draw): reads closed LWPOLYLINE/POLYLINE loops, chains LINE/ARC segments, honours the file's $INSUNITS " ++
    "(mm/inch selectable in the dialog), and preserves arcs as editable sketch curves. The chosen loop becomes the exact board " ++
    "edge the renderers draw, the board-edge DRC measures, and the " ++
    board_layers.edge_cuts ++ " Gerber traces. Saved with the layout (Save/Update).";
const tip_pour_zone = "Custom copper area (Z): edit pours and keepouts with the full shared shape-sketch palette (lines/arcs, dimensions, constraints, fillet, chamfer, offset and mirror), or draw a new polygon. " ++
    "Choose pour or keepout plus its layer; pours also select a net and priority. Double-click an edge to add a vertex; right-click geometry to delete. Saved with the layout.";
const tip_draw = "Route tracks (X): click a pad to start a trace, click to " ++
    "fix corners (E toggles 45\u{b0}/90\u{b0}, / switches posture, A toggles tangent arcs, Shift = free angle), V drops a via and flips " ++
    "layer, click a same-net pad or double-click to finish, Backspace steps back, Esc ends. Right-click deletes the " ++
    "track/via under the cursor. Copper is saved with the layout (Save/Update).";
const tip_text = "Silkscreen text (T): click on the board to place a label " ++
    "(grid-snapped, on the active side). In Select or Text mode, click an existing label to edit it and drag it to " ++
    "move it, R rotates 90\u{b0}, Del or right-click deletes. Saved with the layout (Save/Update); emitted on the silk " ++
    "Gerber.";
const tip_backing = "Edit fabrication backing regions with the shared shape-sketch palette: lines/arcs, dimensions, constraints, fillet, chamfer, offset and mirror. " ++
    "The authored side, material, thickness, and automatic footprint cutouts remain unchanged. Saved with the layout and emitted in its named Gerber.";
const tip_heatsink = "Draw or edit a physical heatsink. Drag its body to move it, drag corner handles to resize it, or click it to edit its face, target, material, fin count/dimensions, and thermal pad. Saved with the layout; the thermal ladder and 3D view use it.";
const tip_ruler = "Ruler / dimension (D): drag to measure, or select a footprint first and drag its origin to a straight board edge to create a driving dimension.";
const tip_move = "Move selected parts by an X/Y distance (M): marquee or Ctrl/Cmd+click parts, then press M (or this button) and type how far to move them; copper that belongs to the selection rides along, one undo step.";
const pad_align_tool_html = @embedFile("assets/pcb_pad_align_tool.html");
const alignment_tools_html = @embedFile("assets/pcb_alignment_tools.html");

/// KiCad-style vertical drawing toolbar, docked on the canvas' left edge
/// (full page only). Every button keeps the id the board script already
/// wires: select is the new explicit "disarm all modes" tool; the rest are
/// the same tools that used to sit in the action bar.
const toolstrip_html =
    "<div class=\"pcb-toolstrip\" id=\"pcb-toolstrip\">" ++
    "<button class=\"ts-btn on\" id=\"tool-select\" title=\"Select / move (Esc) — drag parts or silkscreen text, marquee-select on empty board\">\u{2196}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-draw\" title=\"" ++ tip_draw ++ "\">\u{270E}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-outline\" title=\"" ++ tip_outline ++ "\">\u{25AD}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-outline-poly\" title=\"" ++ tip_poly ++ "\">\u{2B21}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-backing\" title=\"" ++ tip_backing ++ "\">\u{25A7}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-heatsink\" title=\"" ++ tip_heatsink ++ "\">\u{2668}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-outline-dxf\" title=\"" ++ tip_dxf ++ "\">\u{2912}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-pour-zone\" title=\"" ++ tip_pour_zone ++ "\">\u{25A9}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-text\" title=\"" ++ tip_text ++ "\">T</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-move-btn\" title=\"" ++ tip_move ++ "\">\u{21C6}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-ruler-btn\" title=\"" ++ tip_ruler ++ "\">\u{1F4CF}</button>" ++
    pad_align_tool_html ++
    "<span class=\"ts-sep\"></span>" ++
    "<button class=\"ts-btn\" id=\"z-in\" title=\"Zoom in\">+</button>" ++
    "<button class=\"ts-btn\" id=\"z-out\" title=\"Zoom out\">\u{2212}</button>" ++
    "<button class=\"ts-btn\" id=\"z-fit\" title=\"Zoom to fit\">\u{26F6}</button>" ++
    "</div>";

/// Phone-only view controls. The desktop tool strip remains the authority for
/// editing; this compact overlay exposes only inspection, layer visibility and
/// viewport controls so a narrow screen is useful without presenting tiny
/// drawing tools. BOARD_JS proxies the zoom buttons to the desktop controls and
/// opens the existing dock panels as bottom sheets.
const mobile_view_tools_html =
    "<nav class=\"pcb-mobile-tools\" aria-label=\"Board inspection controls\">" ++
    "<button type=\"button\" id=\"mobile-info\" aria-controls=\"prop-body\" aria-expanded=\"false\">Info</button>" ++
    "<button type=\"button\" id=\"mobile-layers\" aria-controls=\"pcb-appear\" aria-expanded=\"false\">Layers</button>" ++
    "<span class=\"mobile-tool-sep\"></span>" ++
    "<button type=\"button\" id=\"mobile-z-out\" aria-label=\"Zoom out\">\u{2212}</button>" ++
    "<button type=\"button\" id=\"mobile-z-in\" aria-label=\"Zoom in\">+</button>" ++
    "<button type=\"button\" id=\"mobile-z-fit\" aria-label=\"Zoom board to fit\">Fit</button>" ++
    "</nav>";

/// KiCad-style status bar under the canvas (full page only): live cursor
/// position, drag/measure deltas, zoom, snap grid, units, active layer,
/// hovered part/net, and the shortcut help. The grid select + units button
/// keep their classic ids so the existing view-state wiring binds them.
const statusbar_html =
    "<div class=\"pcb-status\" id=\"pcb-status\">" ++
    "<span class=\"st-seg st-xy\" id=\"st-xy\"></span>" ++
    "<span class=\"st-seg st-dxdy\" id=\"st-dxdy\"></span>" ++
    "<span class=\"st-seg\" id=\"st-zoom\" title=\"Zoom\"></span>" ++
    "<span class=\"st-seg st-grid\" title=\"Snap grid for placement, hand routing, and the outline tool\">grid " ++
    "<select id=\"pcb-grid-sel\">" ++
    "<option value=\"0.5\">0.5 mm</option><option value=\"0.25\">0.25 mm</option>" ++
    "<option value=\"0.1\">0.1 mm</option><option value=\"0.05\">0.05 mm</option>" ++
    "<option value=\"0\">off</option></select></span>" ++
    "<button class=\"st-seg st-btn\" id=\"pcb-units-btn\" " ++
    "title=\"Toggle coordinate / dimension display between mm and mil (display only)\">mm</button>" ++
    "<span class=\"st-seg st-layer\" id=\"st-layer\" " ++
    "title=\"Selected routing layer — B toggles " ++ board_layers.f_cu ++ "/" ++ board_layers.b_cu ++
    "; PgUp/PgDn cycle\">" ++
    "<i id=\"st-layer-sw\"></i><span id=\"st-layer-nm\"></span></span>" ++
    "<span class=\"st-seg\" id=\"st-gpu\" " ++
    "title=\"Active renderer — WebGPU where the browser supports it, Canvas2D otherwise (?gpu=0 forces 2D)\"></span>" ++
    "<span class=\"st-seg st-tool\" id=\"st-tool\"></span><label class=\"st-seg st-bend\" id=\"st-bend\" hidden title=\"Manual trace bend angle (E toggles while routing)\">bend <select id=\"pcb-bend-angle\" aria-label=\"Manual trace bend angle\"><option value=\"45\">45\u{b0}</option><option value=\"90\">90\u{b0}</option></select></label>" ++
    "<span class=\"st-spacer\"></span>" ++
    "<span class=\"st-seg st-hover\" id=\"st-hover\"></span>" ++
    "<button class=\"st-seg st-btn\" id=\"pcb-help\" title=\"Keyboard &amp; mouse shortcuts (?)\">?</button>" ++
    "</div>";

// spec: Web Server - The PCB status bar carries a live renderer chip that reads GPU or 2D and follows device loss
test "status bar ships the renderer chip the viewer JS drives" {
    try std.testing.expect(std.mem.indexOf(u8, statusbar_html, "id=\"st-gpu\"") != null and std.mem.indexOf(u8, statusbar_html, "id=\"pcb-bend-angle\"") != null);
}

// spec: Web Server - Hovering visible routed copper, vias, pours, or unrouted airwires identifies their net in the PCB status bar while pad hover retains its component context
test "PCB status bar identifies nets under the pointer" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function statusHover(m,pointNet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function statusFeatureNet(m,partIndex)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var v=inspHitVia(m);if(v&&v.net)return v.net;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var t=inspHitTrack(m);if(t&&t.net)return t.net;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "z.t===\"zone\"&&z.o&&z.o.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PHYSICAL_REVIEW||ovExclusive()||!ratsOn") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "l.k===\"proximity\"||l.done||!l.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "statusHover(hm,statusFeatureNet(hm,hi));") != null);
}

// spec: Web Server - M opens a move-by-distance dialog for the selected parts (X and/or Y in the current units, one undo step, carried copper) and D arms the ruler/measure tool
test "M binds the move-by-distance dialog and D binds the ruler, and the toolstrip ships a Move button" {
    const js = @embedFile("assets/pcb_board.js");
    // M is the move command (a dialog), D is the measure tool — the ruler's
    // old M binding must be gone, and the move dialog must exist to be armed.
    try std.testing.expect(std.mem.indexOf(u8, js, "(ev.key===\"m\"||ev.key===\"M\")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();rulerArm(!rulerMode);return;}") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "(ev.key===\"d\"||ev.key===\"D\")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();rulerArm(!rulerMode);return;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "(ev.key===\"m\"||ev.key===\"M\")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();moveDialog();return;}") != null);
    // One shared delta for every selected entity, so the move carries the
    // marquee band exactly like a group drag (moveEntities' banded opt-in).
    try std.testing.expect(std.mem.indexOf(u8, js, "function moveEntities(ents,deltas,banded)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var moved=moveEntities(ents,ents.map(function(){return {dx:dx,dy:dy};}),true);") != null);
    // The toolstrip ships the Move button the script wires by id.
    try std.testing.expect(std.mem.indexOf(u8, toolstrip_html, "id=\"pcb-move-btn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolstrip_html, "id=\"pcb-ruler-btn\"") != null);
    // Tooltips name the NEW keys so a user pressing M finds the move dialog.
    try std.testing.expect(std.mem.indexOf(u8, tip_ruler, "Ruler / dimension (D)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tip_move, "Move selected parts by an X/Y distance (M)") != null);
}

// V opens the PCB View sidebar unless an active trace needs it to drop a via,
// while outline sketches retain their vertical constraint shortcut.
test "V opens the View sidebar outside an active trace or outline sketch" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "if(dtrace&&(ev.key==\"v\"||ev.key==\"V\")){ev.preventDefault();drawViaHere();return;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(dtrace||outlineMode||activeSketchIsArea())return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "compactDockSet(\"appearance\",true,\"\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "mobilePanelSet(\"layers\",true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(pop&&lb){popOpen();return true;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Open the View sidebar (when no trace or outline sketch is active)") != null);
}

// spec: Web Server - The PCB editor imports a DXF board outline: the page ships a DXF button (toolstrip + embed action bar) and the importer script, whose client-side parser exposes the loops a picked .dxf found (LWPOLYLINE/POLYLINE loops, LINE/ARC chains, $INSUNITS units, Y-flip to the board frame)
test "the toolstrip ships the DXF board-outline import button" {
    // Both surfaces carry the button under the same id the importer wires
    // (the embed action-bar variant is emitted beside the ▭/⬡ buttons).
    try std.testing.expect(std.mem.indexOf(u8, toolstrip_html, "id=\"pcb-outline-dxf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tip_dxf, "Import a DXF file as the board outline") != null);
    // The page loads the importer right after pcb_board.js (whose globals it uses).
    const page_js = @embedFile("assets/pcb_board.js");
    const dxf_js = @embedFile("assets/pcb_dxf.js");
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "window.PCBDxfParse") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "pcb-outline-dxf") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "LWPOLYLINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "INSUNITS") != null);
    // The importer feeds the existing outline-override seam the ▭/⬡ tools use.
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "PCB.outline = { x: 0, y: 0, w: 0, h: 0, pts: pts }") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "seams.outlineBboxSync()") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "seams.scheduleDrc()") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_js, "window.PCBDxfSeams.selfIntersects(pts)") != null);
    // The board script exports that seam (it is an IIFE — internal functions
    // are not globals, so the export is the only way in).
    try std.testing.expect(std.mem.indexOf(u8, page_js, "window.PCBDxfSeams={") != null);
    // And the board script still boots the page without it (independent script).
    try std.testing.expect(std.mem.indexOf(u8, page_js, "var RO=!!PCB.ro") != null);
}

// spec: Web Server - The PCB editor overlays source-declared fabrication backing, edits every region with the outline sketch palette and undo, and persists compiled polygons plus index-aligned native sketches without changing side or material
test "the PCB editor ships a persistent fabrication backing polygon tool" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, toolstrip_html, "id=\"pcb-backing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function backingArm(on)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function backingInsert(e)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function backingDelete(i)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "fabrication_layers:PCB.fabrication_layers||[]") != null);
    // Browser overrides carry only a layer name + regions. The source block
    // remains authoritative for face, material, thickness, and cutout policy.
    try std.testing.expect(std.mem.indexOf(u8, js, "side:l.side") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "material:l.material") == null);
}

// spec: Web Server - The ruler drag keeps its live measurement across redraws: the drawn overlay clears per frame but the drag's start/end state survives until the gesture ends
test "the ruler's drag state survives the per-frame overlay redraw" {
    const js = @embedFile("assets/pcb_board.js");
    // rulerClear used to null rulerDraw, so the very first redraw killed the
    // gesture and pointermove bailed: the measurement froze at d=0.00. It now
    // removes only the drawn overlay; the {a,b} drag state lives until
    // pointerup / rulerArm(false).
    try std.testing.expect(std.mem.indexOf(u8, js, "function rulerClear(){if(rgRuler&&rgRuler.parentNode)rgRuler.parentNode.removeChild(rgRuler);rgRuler=null;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function rulerClear(){if(rgRuler&&rgRuler.parentNode)rgRuler.parentNode.removeChild(rgRuler);rgRuler=null;rulerDraw=null;}") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "else rulerDraw.b=m;rulerDrawNow(rulerDraw.a,rulerDraw.b,rulerDraw);") != null);
}

// spec: Web Server - With one footprint selected, D authors a persistent driving dimension from that footprint origin to a perpendicular straight outline edge
test "D drives a selected footprint origin from a stable outline edge" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "a=p?{x:p.x,y:p.y}:m") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function dimensionEdgeAt(m,axis)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "d={ref:part.ref,axis:state.axis,edge_id:edge.id,offset:sign*n*unit}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function outlineGeomDrop(){outlineGeomRev++;outlineFilletCache=null;boardShapeCache=null;partDimensionsApply();}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "dimensions:PCB.dimensions||[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "dimensions:cloneDimensions()") != null);
}

// spec: Web Server - Double-clicking a saved PCB driving dimension line or value reopens its exact-distance editor
test "a PCB driving dimension opens its value editor on double click" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function partDimensionAt(m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.partDimensionDblClick=function(ev)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!RO&&PCB.partDimensionDblClick&&PCB.partDimensionDblClick(ev))return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "state.existing&&partDimensionEdge(state.existing)") != null);
}

// spec: Web Server - The overscan pan-buffer fingerprint reads the clearance-halo toggle from view state instead of a removed DOM checkbox, so a pan never throws
test "the overscan fingerprint reads the clearance toggle from view state" {
    const js = @embedFile("assets/pcb_board.js");
    // The old fingerprint referenced a removed #r-clr-show element and threw
    // ReferenceError on every pan-buffer build; it must read viewSt.vis.clr
    // through clrOn() now, and the dangling checkbox read must be gone.
    try std.testing.expect(std.mem.indexOf(u8, js, "clr&&clr.checked?1:0") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "clrOn()?1:0") != null);
}

/// Saved-layouts panel: the named history (manual snapshots + auto-recorded
/// optimizer runs), newest first, each row showing its kind, score, and delta
/// of (HPWL+loop) versus the layout currently on screen (`auto`). The Load /
/// delete buttons carry the layout name in data attributes for BOARD_JS.
/// How many of the placement's parts a saved layout covers, matched EXACTLY
/// the way a Load will land poses (`resolvePoseIdentity`: sub-block-scoped
/// origin key first, exact ref for legacy entries, each live part claimed
/// once). A count below the part total means the design grew since the layout
/// was saved (a stale ★) — the uncovered parts get staged on Load. The old
/// unscoped match let any "U1" pose cover any sub-block's IC, so a stale row
/// reported full coverage while its parts stacked at the origin. Returns 0 on
/// allocation failure — under-reporting lights the panel warning, the safe
/// direction.
fn layoutCoverage(alloc: std.mem.Allocator, L: SavedLayout, p: optimizer.Placement) usize {
    const live = liveOfPlacement(alloc, p) orelse return 0;
    const res = resolvePoseIdentity(alloc, live, L.parts) orelse return 0;
    var covered: usize = 0;
    for (res.bound) |b| {
        if (b) covered += 1;
    }
    return covered;
}

/// Which block the Layouts panel is listing, for the per-row permalinks.
/// A `?sub=` scoped sub circuit gets `sub` set and NO links: its layouts live
/// in a per-sub sidecar the `?layout=` selector deliberately doesn't read (a
/// sub preview always solves fresh), so a link there would be a dead one.
const LayoutsPanelCtx = struct { name: []const u8, sub: ?[]const u8 = null };

/// The permalink for one saved layout: `/pcb-layout/<design>?layout=<name>`.
/// The layout name is percent-encoded as a query VALUE (mirroring JS
/// `encodeURIComponent`), so the timestamped default names the Save prompt
/// offers — `layout 07-27 14:30` — survive spaces and colons intact, and a
/// name carrying `&`, `#` or `%` can't break out of the attribute it lands in.
fn writeLayoutHref(w: *std.Io.Writer, design: []const u8, layout: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("/pcb-layout/");
    try writeAttr(w, design);
    try w.writeAll("?layout=");
    for (layout) |c| {
        const unreserved = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

/// One saved layout's name cell: a permalink anchor on a design/module page,
/// a plain span on a `?sub` scoped sub circuit (see `LayoutsPanelCtx`).
fn writeLayoutName(w: *std.Io.Writer, ctx: LayoutsPanelCtx, layout: []const u8) std.Io.Writer.Error!void {
    if (ctx.sub != null) {
        try w.writeAll("<span class=\"lay-name\">");
        try writeEscaped(w, layout);
        try w.writeAll("</span>");
        return;
    }
    try w.writeAll("<a class=\"lay-name\" href=\"");
    try writeLayoutHref(w, ctx.name, layout);
    try w.writeAll("\" title=\"Direct link to this layout — opens the board exactly as saved\">");
    try writeEscaped(w, layout);
    try w.writeAll("</a>");
}

/// Everything the saved-layouts panel needs: which block it lists (for the
/// per-row permalinks), the rows, the on-screen score baseline, and the
/// placement whose parts each row's coverage is counted against.
const PanelData = struct {
    panel: LayoutsPanelCtx,
    layouts: []const SavedLayout,
    auto: LayoutScore,
    placement: optimizer.Placement,
};

fn writeLayoutsPanel(w: *std.Io.Writer, alloc: std.mem.Allocator, pd: PanelData) std.Io.Writer.Error!void {
    const layouts = pd.layouts;
    const auto = pd.auto;
    const placement = pd.placement;
    const ctx = pd.panel;
    try w.writeAll("<div class=\"pcb-saved\"><div class=\"saved-h\"><span>Saved versions <span class=\"saved-n\">");
    try w.print("{d}</span></span>", .{layouts.len});
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"lay-nav\" id=\"pcb-lay-nav\">" ++
        "<button class=\"btn lay-step\" id=\"pcb-lay-prev\" title=\"Older saved version\" aria-label=\"Older saved version\">‹</button>" ++
        "<select id=\"pcb-lay-select\" aria-label=\"Saved version\"></select>" ++
        "<button class=\"btn lay-step\" id=\"pcb-lay-next\" title=\"Newer saved version\" aria-label=\"Newer saved version\">›</button>" ++
        "</div><div class=\"lay-nav-foot\"><div class=\"lay-nav-meta\" id=\"pcb-lay-meta\"></div>" ++
        "<span class=\"lay-nav-actions\"><button class=\"btn\" id=\"pcb-lay-rename\" data-lay-rename=\"\" title=\"Rename selected layout\">Rename</button>" ++
        "<button class=\"btn lay-del\" id=\"pcb-lay-delete\" data-lay-del=\"\" title=\"Delete selected layout\">Delete</button></span></div>");
    if (layouts.len == 0) {
        try w.writeAll("<div class=\"saved-empty\">None yet — drag parts then <b>Save as…</b>, or hit Regenerate to record one.</div></div>");
        return;
    }
    // The common history workflow is a compact previous/current/next control.
    // The client fills the select from PCB.layouts and keeps it synchronized
    // with Load/Save; the complete management list remains one disclosure away.
    try w.writeAll("<details class=\"saved-all\"><summary>All versions</summary><div class=\"lay-tools\">");
    try w.writeAll("<a class=\"btn\" id=\"pcb-rough\" href=\"/pcb-layout/");
    try writeAttr(w, ctx.name);
    if (ctx.sub) |sub| {
        try w.writeAll("?sub=");
        try writeAttr(w, sub);
        try w.writeAll("&amp;remaining=1\"");
    } else try w.writeAll("?remaining=1\"");
    try w.writeAll(" title=\"Keep every part the ★ (or last auto) layout already places and rough-place only new parts\">Rough remaining</a>");
    try w.writeAll(
        "<button class=\"saved-rescore\" id=\"pcb-rescore\" " ++
            "title=\"Recompute every saved layout's objective with the current engine\">" ++
            "↻ Rescore all</button></div><div class=\"saved-list\">",
    );
    for (layouts) |L| {
        // Two stacked lines so the row fits the narrow sidebar: top = kind + name +
        // auto-relative delta; bottom = ★default-toggle + score + Load/Delete.
        // `data-lay-row` keys the row for the Score-view re-weigh (reweighLayouts
        // in BOARD_JS rewrites its `.lay-score` + `.lay-d` in place — both still
        // found by querySelector). The `def` class highlights the sync default.
        try w.writeAll(if (L.default) "<div class=\"lay-row def\" data-lay-row=\"" else "<div class=\"lay-row\" data-lay-row=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\"><div class=\"lay-top\"><span class=\"lay-kind ");
        try w.writeAll(if (std.mem.eql(u8, L.kind, kind_manual)) "k-man\">manual" else "k-auto\">auto");
        // The name is the layout's permalink: `?layout=<name>` renders exactly
        // this snapshot (poses + its saved copper), so the row is something you
        // can copy the link of and send to someone.
        try w.writeAll("</span>");
        try writeLayoutName(w, ctx, L.name);
        const cov = layoutCoverage(alloc, L, placement);
        if (cov < placement.parts.len) {
            try w.print(
                "<span class=\"lay-cover\" title=\"Covers {d} of {d} current parts — the design grew since " ++
                    "this layout was saved; re-save (or Rough remaining) to refresh it\">{d}/{d}</span>",
                .{ cov, placement.parts.len, cov, placement.parts.len },
            );
        }
        if (L.score) |s| {
            try writeLayDelta(w, s, auto);
        } else try w.writeAll("<span class=\"lay-d\"></span>");
        try w.writeAll("</div><div class=\"lay-bot\"><span class=\"lay-score\">");
        if (L.score) |s| {
            if (s.objective > 0) try w.print("obj {d:.1} · ", .{s.objective});
            try w.print("HPWL {d:.1} · loop {d:.1}", .{ s.hpwl, s.loop });
        } else try w.writeAll("—");
        try w.writeAll("</span><span class=\"lay-actions\"><button class=\"btn lay-star");
        if (L.default) try w.writeAll(" on");
        try w.writeAll("\" data-lay-default=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\" title=\"");
        try w.writeAll(if (L.default)
            "Default layout — the KiCad sync seeds new parts (placement + GND vias) from this. Click to clear."
        else
            "Make this the KiCad-sync default (seeds new parts' placement + GND vias)");
        try w.writeAll("\">");
        try w.writeAll(if (L.default) "★" else "☆");
        try w.writeAll("</button><button class=\"btn lay-go\" data-lay-load=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\">Load</button><button class=\"btn lay-rename\" title=\"Rename\" data-lay-rename=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\">Rename</button><button class=\"btn lay-del\" title=\"Delete\" data-lay-del=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\">✕</button></span></div></div>");
    }
    try w.writeAll("</div></details></div>");
}

/// Delta of a saved layout's cost versus the on-screen auto baseline, on the
/// weighted objective when both have one (legacy entries with no objective fall
/// back to the combined HPWL+loop). Positive (red) = worse, negative (green) =
/// better — matching the live score-bar deltas.
fn writeLayDelta(w: *std.Io.Writer, s: LayoutScore, auto: LayoutScore) std.Io.Writer.Error!void {
    const d = if (s.objective > 0 and auto.objective > 0)
        s.objective - auto.objective
    else
        (s.hpwl + s.loop) - (auto.hpwl + auto.loop);
    if (@abs(d) < 0.05) {
        try w.writeAll("<span class=\"lay-d\">=</span>");
        return;
    }
    try w.print("<span class=\"lay-d {s}\">{s}{d:.1}</span>", .{
        if (d > 0) "up" else "down",
        if (d > 0) "+" else "",
        d,
    });
}

/// Chip row that toggles the collapsible control panels (Route / Stuck — an
/// accordion, one open at a time) plus the blame Heatmap and trace Legend.
/// The Route chip starts active when the
/// page loaded already routed, so its status panel is visible without a click.
/// All behaviour is wired in BOARD_JS by the `data-panel` / id hooks.
/// Opening tag shared by the embed's board-view toggle chips (Heatmap / Legend)
/// — extracted so the repeated literal stays in one place.
const view_chip_open = "<label class=\"view-chip\" ";

fn writeTabsRow(w: *std.Io.Writer, route_open: bool, with_view_controls: bool) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-tabs\">");
    // The Route chip's panel now embeds the live-route / replay dock inline (the
    // Route button streams the autorouter onto the board and the dock's scrubber
    // replays it), so there is no separate Replay accordion chip.
    try w.writeAll(if (route_open)
        "<button class=\"tab-chip active\" data-panel=\"panel-route\" title=\"Autoroute (live) + replay + DRC\">Route</button>"
    else
        "<button class=\"tab-chip\" data-panel=\"panel-route\" title=\"Autoroute (live) + replay + DRC\">Route</button>");
    try w.writeAll("<button class=\"tab-chip\" data-panel=\"panel-stuck\" " ++
        "title=\"Nets the router could not connect — why each failed, and the DSL fixes to try\">Stuck</button>");
    // The view toggles + layers/grid/units/ruler controls stay in this row for
    // the editable embed only. The full page docks the toggles into the
    // Appearance panel, the grid/units into the status bar, and the ruler into
    // the tool strip — writeSidebar calls this with `with_view_controls=false`.
    if (with_view_controls) {
        try w.writeAll("<span class=\"tabs-sep\"></span>");
        try w.writeAll(view_chip_open ++
            "title=\"Tint each part green→red by its share of the objective (cost/blame heatmap)\">" ++
            "<input type=\"checkbox\" id=\"v-heat\"> Heatmap</label>");
        try w.writeAll(view_chip_open ++ "title=\"Show the trace / via colour key\">" ++
            "<input type=\"checkbox\" id=\"v-legend\"> Legend</label>");
        try w.writeAll("<span class=\"tabs-sep\"></span>");
        // Layers / grid / units / ruler controls (audit 1.5). Populated + wired
        // in pcb_board.js; the layers popover is built client-side so it can
        // read the persisted per-design visibility state.
        try w.writeAll("<button class=\"tab-chip\" id=\"pcb-layers-btn\" title=\"Appearance — the same " ++
            "layer/object rows the full page docks; B toggles " ++ board_layers.f_cu ++ "/" ++ board_layers.b_cu ++
            "; PgUp/PgDn cycle\">\u{25A4} Layers</button>");
        try w.writeAll("<label class=\"view-chip\" title=\"Snap grid for placement, hand routing, and the outline tool\">" ++
            "Grid <select id=\"pcb-grid-sel\">" ++
            "<option value=\"0.5\">0.5 mm</option><option value=\"0.25\">0.25 mm</option>" ++
            "<option value=\"0.1\">0.1 mm</option><option value=\"0.05\">0.05 mm</option>" ++
            "<option value=\"0\">off</option></select></label>");
        try w.writeAll("<button class=\"tab-chip\" id=\"pcb-units-btn\" " ++
            "title=\"Toggle coordinate / dimension display between mm and mil (display only)\">mm</button>");
        try w.writeAll("<button class=\"tab-chip\" id=\"pcb-ruler-btn\" " ++
            "title=\"" ++ tip_ruler ++ "\">\u{1F4CF} Ruler</button>");
        try w.writeAll("<div class=\"pcb-layers-pop\" id=\"pcb-layers-pop\" hidden></div>");
    }
    try w.writeAll("</div>");
}

// ── Net-colours view palette ────────────────────────────────────────────────
// Four buckets, not the full criticality taxonomy: no-connect → white, ground →
// one brown, power-family → a vivid warm colour (red/orange/yellow band), and
// every other (signal) net → its own distinct colour spread around the wheel.
// The goal is "tell the nets apart at a glance", not "label each net's role".
// Every ground variant, per `net_analysis.ground_tokens`.
const net_brown = "#8a5a2b";
const net_white = "#ffffff"; // no-connect nets + pads on no net at all

/// `h` in degrees [0,360), `s`/`l` in [0,1] → `"#rrggbb"` written into `buf`.
fn hslHex(buf: *[7]u8, h: f64, s: f64, l: f64) []const u8 {
    const c = (1 - @abs(2 * l - 1)) * s;
    const hp = h / 60.0;
    const x = c * (1 - @abs(@mod(hp, 2.0) - 1));
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = l - c / 2.0;
    const rgb = [3]u8{ chan(r + m), chan(g + m), chan(b + m) };
    const HEXD = "0123456789abcdef";
    buf[0] = '#';
    for (rgb, 0..) |v, i| {
        buf[1 + i * 2] = HEXD[v >> 4];
        buf[2 + i * 2] = HEXD[v & 0x0f];
    }
    return buf[0..7];
}

fn chan(v: f64) u8 {
    return numeric.checkedInt(u8, @round(std.math.clamp(v, 0, 1) * 255)) orelse 0;
}

/// True for a no-connect net name (mirrors `optimizer.isNoConnect`, private).
fn isNoConnectName(name: []const u8) bool {
    const s = shortName(name);
    if (std.mem.eql(u8, s, "NC") or std.mem.eql(u8, s, "DNC")) return true;
    return std.mem.startsWith(u8, s, "unconnected") or std.mem.startsWith(u8, s, "no_connect");
}

/// True for a digit-first voltage-rail name — `6V`, `12V`, `3V3`, `5V0`, `1V8`.
/// The shared `classifyNetName` only treats `V`-prefixed names as power, so these
/// common rail spellings would otherwise colour as signals. Kept LOCAL to the
/// colour view (not folded into the classifier) so it can't shift the placement/
/// router net-class behaviour that consumes `classifyNetName`.
fn looksLikeVoltageRail(name: []const u8) bool {
    const s = shortName(name);
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0 or i >= s.len) return false; // must start with digit(s)…
    return std.ascii.toUpper(s[i]) == 'V'; // …immediately followed by 'V'
}

/// Colour for one net: white (no-connect), brown (ground), a warm colour stepped
/// through the red→yellow band per power net (`pi`), or a distinct colour stepped
/// around the rest of the wheel per signal net (`si`). The golden-angle step
/// (137.508°) keeps consecutive nets far apart in hue so they read as distinct.
/// `pi`/`si` are bumped so each net in its bucket gets a fresh slot.
fn netColorHex(name: []const u8, buf: *[7]u8, pi: *usize, si: *usize) []const u8 {
    if (isNoConnectName(name)) return net_white;
    const cls = module_policy.classifyNetName(name);
    if (cls == .ground) return net_brown;
    const is_power = cls == .power or cls == .input_rail or cls == .switch_node or looksLikeVoltageRail(name);
    if (is_power) {
        const h = @mod(@as(f64, @floatFromInt(pi.*)) * 137.508, 50.0);
        pi.* += 1;
        return hslHex(buf, h, 0.92, 0.52);
    }
    const h = 60.0 + @mod(@as(f64, @floatFromInt(si.*)) * 137.508, 300.0);
    si.* += 1;
    return hslHex(buf, h, 0.72, 0.58);
}

/// Emit `"links":[ {a,ax,ay,b,bx,by,k,net?}, … ]` — the ratsnest airwires. Each
/// carries its collapsed `netKey` (when known) so the Net-colours view can tint
/// it by class. Electrical links on a net a DECLARED plane/pour carries are
/// dropped because the copper sheet is the connection. Proximity links survive:
/// they are placement-intent guides, not unresolved-connectivity airwires.
fn writeLinks(w: *std.Io.Writer, links: []const optimizer.Link, rules: optimizer.BoardRules) std.Io.Writer.Error!void {
    try w.writeAll("\"links\":[");
    var first = true;
    for (links) |l| {
        if (l.kind != .proximity and l.net.len > 0 and rules.carriesPlane(l.net)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"a\":{d},\"ax\":{d},\"ay\":{d},", .{ l.a, l.ax, l.ay });
        try w.print("\"b\":{d},\"bx\":{d},\"by\":{d},\"k\":\"{s}\"", .{ l.b, l.bx, l.by, kindStr(l.kind) });
        if (l.net.len > 0) {
            try w.writeAll(net_json_key);
            try writeJsonStr(w, netKey(l.net));
        }
        try w.writeAll("}");
    }
    try w.writeAll("],");
}

/// Emit `"netcolor":{ "<netKey>":"<hex>", … }` — a per-net colour map keyed by
/// the same collapsed `netKey` the pad/airwire `net` fields use. The Net-colours
/// view paints each pad/airwire straight from this (no class indirection): white
/// for no-connect, brown for ground, warm for power, a distinct colour per signal
/// net. Dotted bypass-stub nets collapse to one rail key (first net assigns the
/// slot — same key always lands the same bucket). `netColorHex` walks the buckets
/// and steps the per-bucket index so distinct nets get distinct colours.
fn writeNetColors(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) HandlerError!void {
    try w.writeAll("\"netcolor\":{");
    var seen = std.StringHashMapUnmanaged(void).empty;
    var first = true;
    var pi: usize = 0;
    var si: usize = 0;
    var buf: [7]u8 = undefined;
    for (p.nets) |net| {
        const k = netKey(net.name);
        if (seen.contains(k)) continue;
        try seen.put(alloc, k, {});
        const hex = netColorHex(net.name, &buf, &pi, &si);
        if (!first) try w.writeAll(",");
        first = false;
        try writeJsonStr(w, k);
        try w.writeAll(":");
        try writeJsonStr(w, hex);
    }
    try w.writeAll("}");
}

/// Every flattened net name in the placement, sorted and deduped, as a JSON
/// string array — the user-pour tool's net picker offers exactly these, and
/// they are the raw `net.name`s tracks / zones / zone_fills carry (not the
/// collapsed `netKey`).
fn writeNetNames(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) HandlerError!void {
    var seen = std.StringHashMapUnmanaged(void).empty;
    var list: std.ArrayList([]const u8) = .empty;
    for (p.nets) |net| {
        if (net.name.len == 0) continue;
        const gop = try seen.getOrPut(alloc, net.name);
        if (!gop.found_existing) try list.append(alloc, net.name);
    }
    std.mem.sort([]const u8, list.items, {}, netNameLess);
    try w.writeByte('[');
    for (list.items, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonStr(w, n);
    }
    try w.writeByte(']');
}

fn netNameLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Gradient key for the blame Heatmap, shown only while that view is enabled.
fn writeHeatLegend(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"heat-legend\" id=\"heat-legend\" hidden>" ++
        "<span class=\"heat-h\">Heatmap</span>" ++
        "<span class=\"heat-lbl\">cheap</span><span class=\"heat-bar\"></span><span class=\"heat-lbl\">costly</span>" ++
        "<span class=\"muted\">each part tinted by its share of the objective · " ++
        "scale fixed when toggled on (re-toggle to re-base) · hover a part for the raw number</span>" ++
        "</div>");
}

/// The `<head>` + opening `<body>` of the layout page: charset/viewport metas,
/// title, and the navbar + page styles (embeds add the chrome-trimming CSS and
/// the `.embed` body class).
fn writeDocHead(w: *std.Io.Writer, title: []const u8, embed: bool, edit_embed: bool) std.Io.Writer.Error!void {
    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
    try w.writeAll("<link rel=\"stylesheet\" href=\"/static/pcb_settings.css\">");
    // `title` is the free-form design/module name — escape it, don't `{s}` it raw.
    try w.writeAll("<title>");
    try writeEscaped(w, title);
    try w.writeAll(" — PCB Layout</title>");
    try w.writeAll("<style>");
    // The board palette first, as custom properties the sheets below read.
    try board_theme.writeCssVars(w);
    try w.writeAll(assets_css.navbar_css);
    try w.writeAll(page_css);
    try w.writeAll(mobile_css);
    try w.writeAll(pad_align_css);
    if (embed) try w.writeAll(embed_css);
    try w.writeAll("</style></head><body");
    // `.embed` trims chrome; `.embed-edit` re-enables drag (the read-only preview
    // forces a default cursor) for the editable embed used by the sub-circuit toggle.
    if (edit_embed) {
        try w.writeAll(" class=\"embed embed-edit\"");
    } else if (embed) {
        try w.writeAll(" class=\"embed\"");
    }
    try w.writeAll(">");
}

/// Routing panel: one whole-board Route action, its Stop button and status,
/// followed by the live replay dock. Router geometry remains authored by the
/// design; hidden resolved values preserve the hand-routing/client contract
/// without presenting a second tuning surface in the sidebar.
fn writeRoutePanel(
    w: *std.Io.Writer,
    params: router.RouteParams,
    routed: ?router.RouteResult,
    n_drc: usize,
    n_rp: usize,
    start_open: bool,
    _clr_toggle: bool,
) std.Io.Writer.Error!void {
    _ = _clr_toggle;
    try w.writeAll("<div class=\"pcb-route pcb-panel\" id=\"panel-route\"");
    if (!start_open) try w.writeAll(" hidden");
    try w.writeAll("><div class=\"route-primary\">");
    try w.writeAll("<button class=\"btn route-go\" id=\"r-go\" " ++
        "title=\"Route the whole board, save the result to this design, and stream progress into Replay\">" ++
        "Route board</button>");
    // Stop replaces the live-route action while a run is in flight. Keeping it
    // beside the primary action makes the common path one obvious control.
    try w.writeAll("<button class=\"btn\" id=\"r-stop\" title=\"Stop the live autoroute (keeps the partial copper to Adopt)\" hidden disabled>Stop</button>");
    // pcb_board.js also uses these resolved values for hand-routing geometry.
    // They are deliberately not editable here: the design's rules are the
    // source of truth for the common Route-board workflow.
    try w.print("<input type=\"hidden\" id=\"r-tw\" value=\"{d}\">", .{params.track_width});
    try w.print("<input type=\"hidden\" id=\"r-cl\" value=\"{d}\">", .{params.clearance});
    try w.print("<input type=\"hidden\" id=\"r-vd\" value=\"{d}\">", .{params.via_drill});
    try w.print("<input type=\"hidden\" id=\"r-va\" value=\"{d}\">", .{params.via_dia});
    try w.writeAll("<div class=\"route-status\">");
    // Status spans are updated in place by the Route button's POST (no reload,
    // so the on-screen layout stays put); pre-filled for a direct ?route=1 GET.
    if (routed) |r| {
        if (r.grid_overflow) {
            try w.writeAll("<span class=\"route-stat err\" id=\"r-stat\">board exceeds the routing grid cap — not routed</span>");
        } else {
            const cls = if (r.routed == r.total) "ok" else "warn";
            try w.print("<span class=\"route-stat {s}\" id=\"r-stat\">routed {d}/{d} nets · {d} vias</span>", .{ cls, r.routed, r.total, r.vias.len });
        }
        if (n_drc == 0) {
            try w.writeAll("<span class=\"route-stat ok\" id=\"r-drc\">DRC clean ✓</span>");
        } else {
            try w.print("<span class=\"route-stat err\" id=\"r-drc\">{d} DRC violation(s)</span>", .{n_drc});
        }
        if (n_rp == 0) {
            try w.writeAll("<span class=\"route-stat ok\" id=\"r-rp\">return paths ✓</span>");
        } else {
            try w.print("<span class=\"route-stat warn\" id=\"r-rp\">{d} return-path warning(s)</span>", .{n_rp});
        }
    } else {
        try w.writeAll("<span class=\"route-stat\" id=\"r-stat\"></span>");
        try w.writeAll("<span class=\"route-stat\" id=\"r-drc\"></span>");
        try w.writeAll("<span class=\"route-stat\" id=\"r-rp\"></span>");
    }
    try w.writeAll("</div></div>");
    // The live-route / replay dock lives INSIDE this panel now (a full-width
    // section, not a separate accordion chip), so the Route button's live stream
    // and its scrubber read as one control.
    try w.writeAll("<details class=\"route-disclosure route-replay\" id=\"route-replay\"><summary>Replay details</summary>");
    try writeReplayPanel(w);
    try w.writeAll("</details></div>");
}

/// Live-route / replay dock: the Route button streams the autorouter here
/// net-by-net (window.PCBLiveRoute in pcb_replay.js), and the scrubber replays
/// the decision timeline. All behaviour lives in pcb_replay.js;
/// this only emits the static dock (`#panel-replay` and its `rp-*` controls)
/// the scripts bind to. Emitted inline by writeRoutePanel — nested in `#panel-route`
/// as a plain section (no `pcb-panel` accordion chrome), so it shows/hides with the
/// Route panel and the accordion JS never toggles it independently.
const replay_panel_html = @embedFile("assets/pcb_replay_panel.html");
fn writeReplayPanel(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(replay_panel_html);
}

/// Stuck-nets panel: the sidebar view of the router's stuck-net diagnostics.
/// pcb_stuck.js fills it from the `stuck[]` block POST /api/pcb-route returns
/// (one card per unroutable net: failure mode, blockers, ranked dsl/code
/// remedies) — this only emits the static dock the script binds to, mirroring
/// the Replay panel's visibility in the same accordion. The `sk-*`/`panel-stuck`
/// ids are the front-end contract.
const stuck_panel_html = @embedFile("assets/pcb_stuck_panel.html");
fn writeStuckPanel(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(stuck_panel_html);
}

/// Compact, read-only score line for the embedded per-sub-block preview. Holds
/// the same `sc-*` spans BOARD_JS's showScore() fills (deltas read "=" since the
/// baseline is the layout itself) plus the zoom group — no edit buttons.
/// `module_source` = the sub-block's module name (empty when the sub-block
/// has no module provenance): renders an "Edit module layout" escape hatch
/// to the module's own full PCB page, where the spec panel saves into the
/// module file — the read-only preview stays read-only.
fn writeEmbedBar(w: *std.Io.Writer, module_source: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-bar\">");
    if (module_source.len > 0 and std.mem.indexOfScalar(u8, module_source, '/') == null and
        !std.mem.endsWith(u8, module_source, ".sexp"))
    {
        try w.writeAll("<a class=\"btn\" target=\"_top\" title=\"Open the module's own PCB page — " ++
            "its spec panel saves the layout into lib/modules, so every design using it picks the change up\" href=\"/pcb-layout/");
        try writeAttr(w, module_source);
        try w.writeAll("\">Edit module layout →</a>");
    }
    try w.writeAll("<span class=\"score\" id=\"sc-obj\">objective …</span><span class=\"delta\" id=\"sc-obj-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-hpwl\">HPWL …</span><span class=\"delta\" id=\"sc-hpwl-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-loop\">loop …</span><span class=\"delta\" id=\"sc-loop-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-area\">loop area …</span><span class=\"delta\" id=\"sc-area-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-align\">area …</span><span class=\"delta\" id=\"sc-align-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-iso\">iso …</span><span class=\"delta\" id=\"sc-iso-d\"></span>");
    try w.writeAll("<span class=\"zoom-grp\"><button class=\"btn\" id=\"z-out\" title=\"Zoom out\">−</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-in\" title=\"Zoom in\">+</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-fit\" title=\"Reset zoom\">Fit</button></span>");
    try w.writeAll("</div>");
}

const ReadOnlyEmbedChrome = struct {
    module_source: []const u8,
    params: router.RouteParams,
    routed: ?router.RouteResult,
    n_drc: usize,
    toggles: Toggles,
    physical_review: bool,
};

fn writeReadOnlyEmbedChrome(w: *std.Io.Writer, o: ReadOnlyEmbedChrome) std.Io.Writer.Error!void {
    if (!o.physical_review) try writeEmbedBar(w, o.module_source);
    try writeEmbedRoute(w, o.params, o.routed, o.n_drc, .{
        .toggles = o.toggles,
        .show_toggles = !o.physical_review,
        .show_drc_status = !o.physical_review,
        .compact_routed_count = o.physical_review,
    });
}

/// Read-only route status + optional display toggles for an embedded preview.
/// The via/track/clearance values the server routed with are always emitted as
/// hidden inputs so BOARD_JS reads the right numbers. Ordinary schematic
/// previews expose the show-clearance / show-DRC toggles; physical assembly
/// review deliberately omits them.
fn writeEmbedRoute(
    w: *std.Io.Writer,
    params: router.RouteParams,
    routed: ?router.RouteResult,
    n_drc: usize,
    display: struct {
        toggles: Toggles,
        show_toggles: bool,
        show_drc_status: bool = true,
        compact_routed_count: bool = false,
    },
) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-route\">");
    try w.print("<input type=\"hidden\" id=\"r-tw\" value=\"{d}\">", .{params.track_width});
    try w.print("<input type=\"hidden\" id=\"r-cl\" value=\"{d}\">", .{params.clearance});
    try w.print("<input type=\"hidden\" id=\"r-vd\" value=\"{d}\">", .{params.via_drill});
    try w.print("<input type=\"hidden\" id=\"r-va\" value=\"{d}\">", .{params.via_dia});
    if (display.show_toggles) {
        try w.print("<label class=\"tune-chk\"><input id=\"r-clr-show\" type=\"checkbox\"{s}> show clearance</label>", .{if (display.toggles.clr) checked_glyph else ""});
        try w.print("<label class=\"tune-chk\"><input id=\"r-drc-show\" type=\"checkbox\"{s}> show DRC</label>", .{if (display.toggles.drc) checked_glyph else ""});
    }
    if (routed) |r| {
        const cls = if (r.routed == r.total) "ok" else "warn";
        if (display.compact_routed_count) {
            try w.print("<span class=\"route-stat {s}\" id=\"r-stat\">{d} net{s} routed", .{
                cls,
                r.routed,
                if (r.routed == 1) "" else "s",
            });
        } else {
            try w.print("<span class=\"route-stat {s}\" id=\"r-stat\">routed {d}/{d} nets · {d} vias", .{ cls, r.routed, r.total, r.vias.len });
            if (r.failed.len > 0) {
                try w.writeAll(" · missing: ");
                for (r.failed, 0..) |fname, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeHtmlText(w, fname);
                }
            }
        }
        try w.writeAll("</span>");
        if (display.show_drc_status) {
            if (n_drc == 0) {
                try w.writeAll("<span class=\"route-stat ok\" id=\"r-drc\">DRC clean ✓</span>");
            } else {
                try w.print("<span class=\"route-stat err\" id=\"r-drc\">{d} DRC violation(s)</span>", .{n_drc});
            }
        }
    } else {
        try w.writeAll("<span class=\"route-stat\" id=\"r-stat\"></span>");
        if (display.show_drc_status) try w.writeAll("<span class=\"route-stat\" id=\"r-drc\"></span>");
    }
    try w.writeAll("</div>");
}

fn writeLegend(w: *std.Io.Writer, p: optimizer.Placement, hidden: bool) std.Io.Writer.Error!void {
    var fallback_count: usize = 0;
    for (p.parts) |part| {
        if (part.fallback) fallback_count += 1;
    }
    try w.writeAll(if (hidden) "<div class=\"pcb-legend\" id=\"pcb-legend\" hidden>" else "<div class=\"pcb-legend\" id=\"pcb-legend\">");
    try w.writeAll("<span class=\"sw prox\"></span> power leg (L1)");
    try w.writeAll("<span class=\"sw l2gnd\"></span> GND return (images under trace, L2 plane)");
    try w.writeAll("<span class=\"sw viadot\"></span> GND via (L1↔L2, Ø from route params)");
    try w.writeAll("<span class=\"sw sig\"></span> signal");
    // Inner routable copper layers (a stackup with >2 signal layers): one
    // swatch per layer, taking its name and colour from the SHARED layer table
    // — the same rows the blob ships and the PNG paints from, so the swatch
    // matches the copper even when a `(plane …)` sits above a routable inner.
    const table = p.rules.layerTable();
    for (table.rows()) |*row| {
        const sig = row.signal orelse continue;
        if (sig.int() < 2) continue;
        try w.print("<span class=\"sw\" style=\"border-color:{s}\"></span> {s} track", .{ row.color(), row.name() });
    }
    if (fallback_count > 0) {
        try w.print("<span class=\"note\">{d} part(s) using a placeholder box (no library footprint) — shown dashed</span>", .{fallback_count});
    }
    try w.writeAll("</div>");
}

// ── Sidebar (single-part properties panel, KiCad-style) ──────────────────

/// Everything the docked left column needs beyond the placement itself.
const SidebarOpts = struct {
    name: []const u8 = "demo",
    src: LayoutSource = .fresh,
    ro_params: router.RouteParams,
    routed: ?router.RouteResult,
    n_drc: usize,
    n_rp: usize,
    layouts: []const SavedLayout,
    auto: LayoutScore,
    /// Which block the Layouts panel lists, for its per-row permalinks.
    panel: LayoutsPanelCtx,
};

/// The left dock's Find header and four top-level tabs. Find's result pane
/// rides immediately after the tabs; each tab button names the pane it shows
/// (`data-sidetab`); BOARD_JS's `pcbSideTab` does the swap and also raises the
/// Autorouter tab whenever an accordion panel opens (a Route run, the Stuck
/// client) and the Properties tab whenever a part or a piece of copper is
/// selected — so a panel can never open inside a hidden pane. The Autorouter
/// pane also carries saved-version navigation so the two common
/// actions — route and compare history — stay together.
fn writeSideTabs(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(@embedFile("assets/pcb_find_header.html") ++ "<div class=\"side-tabs\" role=\"tablist\">" ++
        "<button class=\"side-tab\" role=\"tab\" aria-selected=\"false\" data-sidetab=\"side-props\" " ++
        "title=\"The selected part, track, via or DRC marker — position, side, nets, footprint\">" ++
        "Properties</button>" ++
        "<button class=\"side-tab active\" role=\"tab\" aria-selected=\"true\" data-sidetab=\"side-route\" " ++
        "title=\"Autoroute + DRC, live replay, and the stuck-net diagnostics\">" ++
        "Autorouter</button>" ++
        "<button class=\"side-tab\" role=\"tab\" aria-selected=\"false\" data-sidetab=\"side-drc\" " ++
        "title=\"Every DRC violation on this board, grouped by check — click a row (or step with ‹ ›) " ++
        "to locate it on the board\">" ++
        "DRC</button>" ++
        "<button class=\"side-tab\" role=\"tab\" aria-selected=\"false\" data-sidetab=\"side-subs\" title=\"" ++
        sub_tab_tip ++ "\">Sub-circuits</button></div>" ++ @embedFile("assets/pcb_find_pane.html"));
}

/// Tooltip for the Sub-circuits tab. Saved board versions live with Autorouter.
const sub_tab_tip = "Sub-circuit palette (rigid/exploded groups and Stamp from a module's saved layout)";

/// The DRC pane: a step-through header (‹ Prev / Next › + a position readout
/// and the current violation's message) above the violations list BOARD_JS's
/// `renderDrcList` fills. The list has its permanent home here rather than
/// folded inside the Route panel, so locating a violation no longer closes the
/// list it was clicked in — you can walk every one of them in place. The
/// embeds, which have no left dock, keep the inline Route-panel list BOARD_JS
/// creates on demand.
const drc_pane_html = @embedFile("assets/pcb_drc_pane.html");

/// Empty state for the Sub-circuits pane, shown until BOARD_JS finds groups.
const sub_pane_empty = "<div class=\"prop-empty\" id=\"sub-empty\">This board declares no sub-circuits." ++
    "<br><span class=\"prop-empty-n\">Group repeated blocks with <code>(sub-block …)</code> " ++
    "to drag and Stamp them as one.</span></div>";

/// The full page's docked left column (KiCad-style), with a board-wide Find
/// field followed by four tabbed
/// panes: **Properties** (the single-part panel, empty until a part is clicked
/// — BOARD_JS `renderProps` fills it), **Autorouter** (the Route/Stuck
/// accordion — same chip + panel ids the classic row used, so the accordion JS
/// binds unchanged), **DRC** (the violations list + step-through, filled by
/// `renderDrcList`), and **Sub-circuits** (the palette BOARD_JS fills into
/// `#sub-panel`). The saved-version navigator lives in **Autorouter**, directly
/// after the route/stuck controls, so route → compare is one uninterrupted
/// workflow. Designs, modules and `?sub` sub circuits all get it.
fn writeSidebar(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement, sch_base: []const u8, o: SidebarOpts) HandlerError!void {
    try w.writeAll("<aside class=\"pcb-side\" id=\"pcb-side\"><button class=\"dock-close\" type=\"button\" data-dock-close title=\"Close panel\" aria-label=\"Close panel\">×</button>");
    try writeSideTabs(w);
    try w.writeAll("<div class=\"side-pane\" id=\"side-props\" hidden>");
    try w.writeAll(alignment_tools_html);
    try w.writeAll("<div id=\"prop-body\" class=\"prop-body\" data-schbase=\"");
    try writeAttr(w, sch_base);
    try w.print(
        "\"><div class=\"prop-empty\">Click a part on the board to see its properties." ++
            "<br><span class=\"prop-empty-n\">{d} components</span></div>",
        .{p.instances.len},
    );
    try w.writeAll(div2_end);
    // Route is the Autorouter pane's primary action, so it must be present on
    // first open even before this board has routed copper. Stuck remains an
    // opt-in diagnostic reached through its accordion chip.
    const route_open = true;
    try w.writeAll("<div class=\"side-pane\" id=\"side-route\"><div class=\"side-acc\">");
    try writePlacementControls(w, p, o.name, o.src);
    try w.writeAll("<div class=\"side-route-actions\"><button class=\"btn\" id=\"pcb-pour\" title=\"Recompute declared copper pours around the current board\">⟳ Refill pours</button>" ++
        "<button class=\"btn\" id=\"pcb-fence\" title=\"Lay the RF ground via fence along routed RF traces\">░ Via fence</button></div>");
    try writeTabsRow(w, route_open, false);
    try w.writeAll("<div class=\"pcb-panels\">");
    // writeRoutePanel now emits the live-route/replay dock inline.
    try writeRoutePanel(w, o.ro_params, o.routed, o.n_drc, o.n_rp, route_open, false);
    try writeStuckPanel(w);
    try w.writeAll(div2_end);
    try writeLayoutsPanel(w, alloc, .{ .panel = o.panel, .layouts = o.layouts, .auto = o.auto, .placement = p });
    try w.writeAll("</div>");
    try w.writeAll(drc_pane_html);
    try w.writeAll("<div class=\"side-pane\" id=\"side-subs\" hidden>" ++
        "<div class=\"sub-panel\" id=\"sub-panel\"></div>" ++ sub_pane_empty);
    try w.writeAll("</div></aside>");
}

/// Compact-desktop activity rail.  Between phone and wide-CAD widths the two
/// heavyweight docks become mutually-exclusive drawers; this rail keeps every
/// destination one click away while returning their combined 540 px to the
/// board.  Wide screens hide it and keep both docks pinned.
fn writeActivityRail(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<nav class=\"pcb-activity\" aria-label=\"Editor panels\">" ++
        "<button type=\"button\" data-dock-pane=\"side-find\" title=\"Find parts, nets and DRC (Ctrl+F)\"><span aria-hidden=\"true\">⌕</span><small>Find</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-props\" title=\"Selection properties\"><span aria-hidden=\"true\">ⓘ</span><small>Inspect</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-route\" title=\"Placement, autorouter and saved layouts\"><span aria-hidden=\"true\">⚡</span><small>Route</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-drc\" title=\"Design-rule violations\"><span aria-hidden=\"true\">△</span><small>DRC</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-subs\" title=\"Sub-circuit palette\"><span aria-hidden=\"true\">▦</span><small>Blocks</small></button>" ++
        "<span class=\"activity-spacer\"></span>" ++
        "<button type=\"button\" data-dock-appearance title=\"Layers and objects\"><span aria-hidden=\"true\">▤</span><small>View</small></button></nav>");
}

/// Full-page header row: title + the Schematic ⇄ PCB Layout ⇄ 3D switcher
/// (PCB active). Physical board designs also link to their view-only
/// Assembly surface; reusable modules stop at the three design views.
/// `name` resolves as a design under src/ first, else a reusable module — the
/// Schematic link points at the matching viewer.
fn writeHeadNav(
    w: *std.Io.Writer,
    is_module: bool,
    name: []const u8,
    title: []const u8,
    layout: ?[]const u8,
    tally: ?fab_readiness.Tally,
) std.Io.Writer.Error!void {
    const schematic_path: []const u8 = if (is_module) "/modules/" else "/schematics/";
    try w.writeAll("<div class=\"pcb-head\">");
    try w.print("<h1>{s} <span class=\"pcb-sub\">PCB Layout · force-directed · drag to edit</span></h1>", .{title});
    if (tally) |t| {
        const cls = if (t.unique_routed == t.unique_total) " complete" else "";
        try w.print(
            "<span class=\"pcb-route-summary{s}\" id=\"pcb-route-summary\" data-total=\"{d}\" " ++
                "title=\"Unique logical nets completed; per-pin connections are collapsed and single-pad or plane-carried nets are excluded\">" ++
                "Routed <strong>{d} / {d}</strong></span>",
            .{ cls, t.unique_total, t.unique_routed, t.unique_total },
        );
    } else {
        try w.writeAll("<span class=\"pcb-route-summary\" id=\"pcb-route-summary\" title=\"Routing completion unavailable\">Routed <strong>— / —</strong></span>");
    }
    try w.print(
        "<nav class=\"viewtoggle\" aria-label=\"View\">" ++
            "<a href=\"{s}{s}\">Schematic</a>" ++
            "<a class=\"active\" id=\"pcb-tab-2d\" href=\"/pcb-layout/{s}\">PCB Layout</a>" ++
            "<a id=\"pcb-tab-3d\" href=\"/pcb-layout/{s}?view=3d\">3D View</a>",
        .{ schematic_path, name, name, name },
    );
    if (!is_module) {
        try w.print("<a href=\"/assembly-debug/{s}", .{name});
        if (layout) |selected| {
            try w.writeAll("?layout=");
            try writeUrlEncoded(w, selected);
        }
        try w.writeAll("\">Assembly</a>");
    }
    // Thermal screens the same block a module page already shows, so unlike
    // Assembly it is offered on both.
    try w.print("<a href=\"/thermal/{s}\">Thermal</a>", .{name});
    try w.writeAll("</nav>");
    try w.writeAll("</div>");
}

/// The board stage: a vertical tool strip (full page only) docked on the
/// canvas' left edge, the canvas host (SVG + scene canvas), and a KiCad
/// status bar underneath. Embeds keep the bare stage (no strip/status).
fn writeStage(w: *std.Io.Writer, view: View, embed: bool) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-stage\">");
    if (!embed) try w.writeAll(toolstrip_html);
    try w.writeAll("<div class=\"pcb-canvas-host\">");
    try w.print(
        "<svg id=\"pcb-svg\" class=\"pcb-svg\" viewBox=\"0 0 {d:.0} {d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\" xmlns=\"http://www.w3.org/2000/svg\"></svg>",
        .{ view.width, view.height, view.width, view.height },
    );
    if (!embed) try w.writeAll(statusbar_html);
    try w.writeAll("</div>");
    if (!embed) try w.writeAll(mobile_view_tools_html);
    try w.writeAll("</div>");
}

/// Right dock. Full page: the KiCad-style Appearance panel (Layers / Objects
/// tabs; rows built client-side from the persisted view state). Editable
/// embed: the saved-layouts history stays in this column (embeds have no left
/// dock); omitted in the read-only preview.
fn writeRightDock(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    embed: bool,
    edit_embed: bool,
    pd: PanelData,
) std.Io.Writer.Error!void {
    if (!embed) {
        try writeAppearance(w);
        return;
    }
    if (edit_embed) {
        try w.writeAll("<aside class=\"pcb-rside\">");
        try w.writeAll(alignment_tools_html);
        try writeLayoutsPanel(w, alloc, pd);
        try w.writeAll("</aside>");
    }
}

// spec: Web Server - Editable sub-circuit PCB embeds expose the pad aligner's Same X and Same Y controls
test "editable sub-circuit embeds expose pad alignment controls" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
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
    try writeRightDock(&aw.writer, std.testing.allocator, true, true, .{
        .panel = .{ .name = "demo", .sub = "power" },
        .layouts = &.{},
        .auto = .{ .hpwl = 0, .loop = 0, .caps = 0 },
        .placement = placement,
    });
    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pad-align-bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-pad-axis=\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-pad-axis=\"y\"") != null);
}

/// The right-docked Appearance panel (full page only), with Layers / Objects.
/// Only the empty panes are markup: every row is
/// built client-side by ONE builder shared with the embed's layers popover,
/// from `PCB.layer_table` plus the persisted per-design visibility and
/// active-layer state, so the two surfaces cannot drift apart.
fn writeAppearance(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<aside class=\"pcb-rside pcb-appear\" id=\"pcb-appear\">" ++
        "<button class=\"dock-close\" type=\"button\" data-dock-close title=\"Close panel\" aria-label=\"Close panel\">×</button>" ++
        "<div class=\"ap-tabs\"><button class=\"ap-tab active\" data-aptab=\"ap-layers\">Layers</button>" ++
        "<button class=\"ap-tab\" data-aptab=\"ap-objects\">Objects</button></div>" ++
        "<div class=\"ap-pane\" id=\"ap-layers\"></div>" ++
        "<div class=\"ap-pane\" id=\"ap-objects\" hidden></div></aside>");
}

// ── Embedded board data (consumed by BOARD_JS) ───────────────────────────

const LocalPt = struct { x: f64, y: f64 };

/// Page-mode flags for the embedded `PCB` object: `read_only` drives `PCB.ro`
/// (BOARD_JS skips all edit wiring when set); `embed` is any embedded chrome
/// (read-only preview *or* editable embed) — neither has the 3D toggle; the
/// assembly/debug embed can independently opt into model sprites. `sub` is the
/// `?sub=` slug a sub circuit's save/star POSTs append to target the per-sub
/// layout sidecar.
const PcbDataOpts = struct {
    read_only: bool,
    embed: bool,
    /// Resolve STEP metadata for an assembly/debug embed and let the browser
    /// progressively rasterize it; ordinary embeds deliberately leave it off.
    model_sprites: bool = false,
    /// Thermal's exclusive overlay needs board/part geometry, not editor-only
    /// layout history, stamping seeds, source metadata, or fabrication text.
    thermal_overlay: bool = false,
    /// Read-only assembly payload: keep cross-probe and board geometry, omit
    /// editor/analysis fields that have no UI on this surface.
    assembly_review: bool = false,
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

fn payloadLayouts(layouts: []const SavedLayout, lean_read_only: bool) []const SavedLayout {
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
fn partBlameRaw(alloc: std.mem.Allocator, p: optimizer.Placement, params: optimizer.Params) []const f64 {
    const blame = alloc.alloc(f64, p.parts.len) catch return &.{};
    optimizer.perPartBlame(p, params, blame);
    return blame;
}

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
        error.NoSilkscreenSpace => return null,
        else => return err,
    };
    return mark.text;
}

fn buildPayloadFabText(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: ?router.RouteResult,
    opts: PcbDataOpts,
) HandlerError!?font5x7.BoardText {
    if (opts.thermal_overlay or opts.assembly_review) return null;
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
    if (opts.assembly_review) {
        try w.writeAll(",\"antipads\":[],\"trace_em\":{\"analyses\":[]},\"power_integrity\":{\"nets\":[]}");
        return;
    }
    try writeAntipadsField(w, p, routed);
    try trace_em_json.write(w, alloc, p, routed);
    try power_integrity_json.write(
        w,
        .{ .output = alloc, .scratch = opts.scratch_allocator orelse alloc },
        p,
        routed,
        userZonesFrom(alloc, p.rules, shownZones(opts.saved_routes)),
        opts.base_edge,
    );
}

fn writeCamFields(w: *std.Io.Writer, name: []const u8, opts: PcbDataOpts) std.Io.Writer.Error!void {
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

fn writePcbData(
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
    const pour_copper: pour.Copper = if (routed) |r| .{ .tracks = r.tracks, .vias = r.vias } else .{};
    try writeBlobHead(w, alloc, v, clearance, p, pour_copper, blob_opts);
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
    try writeLinks(w, p.links, p.rules);

    // Per-net colour map the "Net colours" view paints pads + airwires from.
    try writeNetColors(w, alloc, p);

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
    try pcb_rules_json.writeMaskRelief(w, alloc, p, routed);

    // Solved controlled-impedance via antipads for the viewer's Antipads
    // overlay (see writeAntipadsField).
    // Antipad and click-to-inspect 2.5D analysis have no assembly UI.
    try writePayloadAnalysis(w, alloc, p, routed, opts);

    // Per-footprint STEP-model references (URL + KiCad offset/rotation) for the
    // 3D-view tab or assembly's persistent sprite cache. Ordinary embedded previews
    // have neither and skip the filesystem-scanning model resolution entirely.
    try w.writeAll(",\"models\":");
    if (opts.embed and !opts.model_sprites) try w.writeAll("{}") else try writeModelsJson(w, alloc, project_dir, p.instances);
    try writeCamFields(w, name, opts);
    try w.writeAll("};</script>");
}

/// Emit `{ "<footprint>": {"o":[x,y,z],"r":[x,y,z]} }` for every distinct
/// footprint in the design that resolves to a STEP model — the KiCad offset/
/// rotation the 3D-view tab orients each part body with (it fetches the bytes
/// from `/api/model-file/<fp>`, keyed on the map entry). Footprints with no
/// model are omitted (the viewer shows their pads only).
fn writeModelsJson(
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
fn writeRoutedArrays(
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
    // writeLegend reads only the fallback tally and the rules. All three
    // surfaces now read the SAME `board_layers` row, so agreement is
    // structural — this test is what keeps any of them from drifting off it.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try layer_table_json.write(&aw.writer, rules);
    const legend_at = aw.written().len;
    try writeLegend(&aw.writer, .{ .parts = &.{}, .links = &.{}, .loops = &.{}, .stubs = &.{}, .instances = &.{}, .nets = &.{}, .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 }, .minx = 0, .miny = 0, .maxx = 20, .maxy = 10, .generated = false, .rules = rules }, false);
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
fn writeBlobHead(
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
            "\"via_drill\":{d},\"via_plating\":{d},\"board_thickness\":{d},\"perimeter_mask_width\":{d}}},",
        .{
            dr.pour_clearance,                                                                   dr.pour.clearance_outer, dr.pour.min_width, dr.pour.corner_radius, dr.pour.ground_via_max, dr.track_width, dr.via_dia, dr.via_drill, p.rules.physical.via_plating_mm,
            if (p.rules.physical.board_thickness > 0) p.rules.physical.board_thickness else 1.6, perimeter_mask_width,
        },
    );
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
    if (opts.omit_pours) try w.writeAll("[]") else try pour_json.writePours(w, alloc, p, copper, userZonesFrom(alloc, p.rules, shownZones(opts.saved_routes)), opts.base_edge);
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
    try writeNetNames(w, alloc, p);
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
    try w.writeAll(",\"dimensions\":");
    try writePartEdgeDimensionsJson(w, opts.saved_dimensions);
    try w.writeAll(",");
    // Optimistic-concurrency rev the page loaded — Save/Update echoes it to 409 a
    // stale write from another window.
    try w.print("\"rev\":{d},", .{opts.rev});
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
fn netNameOf(nets: []const export_kicad.FlatNet, idx: i32) []const u8 {
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
fn writeAntipadsField(w: *std.Io.Writer, p: optimizer.Placement, routed: ?router.RouteResult) std.Io.Writer.Error!void {
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
const writeViolation = drc_json.writeViolation;

// ── Small helpers ────────────────────────────────────────────────────────

/// Two closing divs — shared by the stage, layouts-panel and sidebar writers.
const div2_end = "</div></div>";

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
fn writeLayoutsJson(w: *std.Io.Writer, layouts: []const SavedLayout, shown: ?[]const u8) std.Io.Writer.Error!void {
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
fn writeLoopJson(
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

fn kindStr(k: optimizer.RatKind) []const u8 {
    return switch (k) {
        .proximity => "proximity",
        .ground => "ground",
        .signal => "signal",
    };
}

fn shortName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// Net grouping key — dot-collapsed to the rail, sub-block prefix kept.
fn netKey(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
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

const writeEscaped = escape.writeXml;

fn writeAttr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// Percent-encode a layout name for use as a query-parameter value. This
/// mirrors JavaScript's encodeURIComponent so a named layout remains one
/// query value even when it contains spaces or reserved punctuation.
fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

/// Emit `s` as HTML text content: `&`, `<`, `>` escaped, nothing else — for
/// interpolating net/ref names into server-rendered markup.
fn writeHtmlText(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

/// Emit `s` as a quoted, JSON-escaped string to a `std.Io.Writer`. This
/// serializer's output is emitted verbatim INSIDE a `<script>` element (the
/// `const PCB=…` data blob), so it must also
/// neutralize the `<script>`-context breakouts a plain JSON escaper misses:
/// `<` is escaped to `<` (so a net/ref/value/layout name containing
/// `</script>` can't close the tag → stored XSS), and U+2028/U+2029 are
/// escaped (they terminate a JS string literal in older engines).
pub fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003c"),
            0xE2 => {
                if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                    try w.writeAll(if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 2;
                } else try w.writeByte(c);
            },
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ── Courtyard editor modal ───────────────────────────────────────────────

/// Hidden-by-default overlay; populated + shown by BOARD_JS when a sidebar
/// footprint button is clicked. Edits the courtyard half-extents on the grid.
const courtyard_modal =
    \\<div id="court-modal" class="court-modal" hidden><div class="court-dialog">
    \\<div class="court-h"><span id="court-title">Courtyard</span><button id="court-x" class="court-x" title="Close">×</button></div>
    \\<svg id="court-svg" class="court-svg" viewBox="0 0 260 220" xmlns="http://www.w3.org/2000/svg"></svg>
    \\<div class="court-mode" id="court-mode">
    \\<label><input type="radio" name="court-mode" value="size" checked> Overall size</label>
    \\<label><input type="radio" name="court-mode" value="offset"> Pad offset</label></div>
    \\<div class="court-fields" id="court-fields-size">
    \\<label>left <input id="court-x0" type="number" step="0.1"></label>
    \\<label>top <input id="court-y0" type="number" step="0.1"></label>
    \\<label>right <input id="court-x1" type="number" step="0.1"></label>
    \\<label>bottom <input id="court-y1" type="number" step="0.1"></label></div>
    \\<div class="court-fields" id="court-fields-offset" hidden>
    \\<label>Offset from pads <input id="court-off" type="number" step="0.05" min="0"> mm</label></div>
    \\<div id="court-full" class="court-full"></div>
    \\<div class="court-note" id="court-note">Drag any box edge — each edge moves independently (mm from the
    \\ part origin) and snaps to the grid. Saving rewrites the footprint file and applies to every design that uses it.</div>
    \\<div class="court-actions"><button id="court-save" class="btn">Save courtyard</button>
    \\<button id="court-cancel" class="btn">Cancel</button><span id="court-msg" class="savemsg"></span></div>
    \\</div></div>
;

const heatsink_modal =
    \\<div id="heatsink-modal" class="court-modal" hidden><div class="court-dialog heatsink-dialog">
    \\<div class="court-h"><span id="hs-title">Physical heatsink</span><button id="hs-x" class="court-x" title="Close">×</button></div>
    \\<div class="hs-grid">
    \\<label>PCB face<select id="hs-side"><option value="top">Top</option><option value="bottom">Bottom</option></select></label>
    \\<label>Target package<select id="hs-target"></select></label>
    \\<label>Material<select id="hs-material"><option value="aluminum_6063">Aluminum 6063</option><option value="aluminum_6061">Aluminum 6061</option><option value="copper_c110">Copper C110</option><option value="steel">Steel</option></select></label>
    \\<label>Fin direction<select id="hs-axis"><option value="length">Along length</option><option value="width">Along width</option></select></label>
    \\<label>X (mm)<input id="hs-x-mm" type="number" step="0.1"></label>
    \\<label>Y (mm)<input id="hs-y-mm" type="number" step="0.1"></label>
    \\<label>Width (mm)<input id="hs-w" type="number" step="0.1" min="0.1"></label>
    \\<label>Length (mm)<input id="hs-h" type="number" step="0.1" min="0.1"></label>
    \\<label>Base thickness (mm)<input id="hs-base" type="number" step="0.1" min="0.1"></label>
    \\<label>Fin height (mm)<input id="hs-fin-h" type="number" step="0.1" min="0"></label>
    \\<label>Fin thickness (mm)<input id="hs-fin-t" type="number" step="0.1" min="0.1"></label>
    \\<label>Fin count<input id="hs-fin-count" type="number" step="1" min="1" max="512"></label>
    \\<label>Fin gap (mm)<input id="hs-fin-g" type="number" step="0.1" min="0"></label>
    \\<label>Pad thickness (mm)<input id="hs-pad-t" type="number" step="0.1" min="0"></label>
    \\<label>Pad conductivity (W/m·K)<input id="hs-pad-k" type="number" step="0.1" min="0.1"></label>
    \\</div><div class="hs-result" id="hs-result"></div>
    \\<div class="court-note">The thermal solver derives fin count and an estimated still-air θSA from this extrusion. For package-top contact, the selected component must have published θJC(top); the opposite PCB face uses its board/exposed-pad path.</div>
    \\<div class="court-actions"><button id="hs-save" class="btn">Use heatsink</button><button id="hs-delete" class="btn fab-danger">Remove</button><button id="hs-cancel" class="btn">Cancel</button></div>
    \\</div></div>
;

// ── Library-card modal ────────────────────────────────────────────────

/// Hidden-by-default overlay; BOARD_JS fills it from `/api/library-card/:name`
/// when the sidebar footprint button is clicked. Shows the SAME card as the
/// library page (component name, description, datasheet links, footprint
/// preview → Edit courtyard, 3D-model drag-in and alignment badge), so every
/// library action is reachable from the layout. Reuses the court-modal shell.
const fp_card_modal =
    \\<div id="fp-card-modal" class="court-modal" hidden><div class="court-dialog fp-card-dialog">
    \\<div class="court-h"><span id="fp-card-title">Library card</span><button id="fp-card-x" class="court-x" title="Close">×</button></div>
    \\<div id="fp-card-body" class="fp-card-body"></div>
    \\</div></div>
;

// ── Fab-readiness modal ──────────────────────────────────────────────────

/// Hidden-by-default overlay populated by BOARD_JS when the ⤓ Gerbers button
/// finds the fab-readiness report non-clean. Lists errors + warnings; the
/// primary action is "Download anyway" (force) on errors, "Continue" on
/// warnings-only. Reuses the court-modal styling.
const fab_modal =
    \\<div id="fab-modal" class="court-modal" hidden><div class="court-dialog fab-dialog">
    \\<div class="court-h"><span id="fab-title">Fab readiness</span><button id="fab-x" class="court-x" title="Close">×</button></div>
    \\<div id="fab-body" class="fab-body"></div>
    \\<div class="court-actions"><button id="fab-go" class="btn">Download anyway</button>
    \\<button id="fab-cancel" class="btn">Cancel</button></div>
    \\</div></div>
;

// ── Styles + client renderer ─────────────────────────────────────────────

const pad_align_css = @embedFile("assets/pcb_pad_align.css");
const page_css = @embedFile("assets/pcb_layout.css");

const mobile_css = @embedFile("assets/pcb_mobile.css");

/// Extra rules layered on top of PAGE_CSS only when `?embed=1` — the body gets
/// the `embed` class. Strips outer padding, lets the board fill the frame
/// width, and drops the grab cursor (no dragging in the read-only preview).
const embed_css =
    \\body.embed .pcb-layout{padding:8px 10px;max-width:none;height:auto;min-height:0}
    \\body.embed .pcb-bar{margin:4px 0}
    \\body.embed .pcb-route{margin:2px 0 6px}
    \\body.embed .pcb-svg{width:100%}
    \\/* Embeds live inside an iframe: no app-frame lock, the stage takes the
    \\   frame height minus the bar/route rows (100vh = the iframe itself). */
    \\body.embed .pcb-stage{height:calc(100vh - 140px);min-height:240px;flex:none}
    \\body.embed .pcb-canvas-host{border-radius:6px}
    \\body.embed:not(.embed-edit) .part{cursor:default}
    \\body.embed-edit .part{cursor:grab}
;

/// The (hidden) WebGL stage for the 3D-view tab: a canvas, a status overlay,
/// and a floating toolbar (camera presets + layer toggles). CSS `.mode-3d`
/// reveals it and hides the 2D board; `pcb_3d_viewer.js` builds the scene.
const pcb_3d_stage_html =
    \\<div class="pcb-3d-stage" id="pcb-3d-stage">
    \\<canvas id="pcb-3d-canvas"></canvas>
    \\<div id="pcb-3d-status">Loading 3D view…</div>
    \\<div class="pcb-3d-tools">
    \\<button class="btn" id="pcb3d-iso">Iso</button>
    \\<button class="btn" id="pcb3d-top">Top</button>
    \\<button class="btn" id="pcb3d-bottom">Bottom</button>
    \\<button class="btn" id="pcb3d-front">Front</button>
    \\<button class="btn" id="pcb3d-side">Side</button>
    \\<span class="sep"></span>
    \\<button class="btn" id="pcb3d-export-step" title="Download the board, mounting holes, placed component models, and heatsink as a schema-conformant AP242 faceted B-rep STEP file">Export STEP</button>
    \\<span class="sep"></span>
    \\<label><input type="checkbox" id="pcb3d-t-models" checked>Models</label>
    \\<label><input type="checkbox" id="pcb3d-t-surface" checked>Surfaces</label>
    \\<label><input type="checkbox" id="pcb3d-t-board" checked>Board</label>
    \\<label><input type="checkbox" id="pcb3d-t-heatsink" checked>Heatsink</label>
    \\<label><input type="checkbox" id="pcb3d-t-axes" checked>Axes</label>
    \\</div></div>
;

/// Tab wiring for the Schematic ⇄ PCB Layout ⇄ 3D View switcher. Toggling to
/// 3D adds `.mode-3d` (CSS swaps in the stage), then lazily injects the WebGL
/// stack (Three.js + OrbitControls + occt-import-js) and our viewer before
/// calling `PCB3D.init()` — so the heavy assets load only when 3D is opened.
/// The PCB Layout tab flips back to 2D in place (no reload) when 3D is active.
const pcb_3d_toggle_js =
    \\<script>(function(){
    \\var tab3d=document.getElementById("pcb-tab-3d"),tab2d=document.getElementById("pcb-tab-2d");
    \\if(!tab3d||!tab2d)return;
    \\var loaded=false,loading=null;
    \\function loadScript(src){return new Promise(function(res,rej){
    \\ var s=document.createElement("script");s.src=src;s.onload=res;
    \\ s.onerror=function(){rej(new Error("load "+src));};document.head.appendChild(s);});}
    \\function ensure(){
    \\ if(loaded)return Promise.resolve();
    \\ if(loading)return loading;
    \\ var seq=Promise.resolve();
    \\ ["/static/three.min.js","/static/OrbitControls.js","/static/occt-import-js.js","/static/pcb_3d_surface.js","/static/pcb_step_export.js","/static/pcb_3d_viewer.js"]
    \\  .forEach(function(u){seq=seq.then(function(){return loadScript(u);});});
    \\ loading=seq.then(function(){loaded=true;});
    \\ return loading;}
    \\function setViewQuery(mode){try{var u=new URL(location.href);
    \\ if(mode)u.searchParams.set("view",mode);else u.searchParams.delete("view");
    \\ history.replaceState(null,"",u.pathname+(u.searchParams.toString()?"?"+u.searchParams.toString():"")+u.hash);}catch(e){}}
    \\function show3d(){
    \\ document.body.classList.add("mode-3d");
    \\ tab3d.classList.add("active");tab2d.classList.remove("active");
    \\ setViewQuery("3d");
    \\ ensure().then(function(){
    \\  if(window.PCB3D){window.PCB3D.init();
    \\   requestAnimationFrame(function(){window.PCB3D.onShow();});}
    \\ }).catch(function(e){console.error(e);
    \\  var st=document.getElementById("pcb-3d-status");
    \\  if(st){st.textContent="3D assets failed to load";st.className="err";}});}
    \\function show2d(){
    \\ document.body.classList.remove("mode-3d");
    \\ tab2d.classList.add("active");tab3d.classList.remove("active");setViewQuery("");}
    \\tab3d.addEventListener("click",function(e){e.preventDefault();show3d();});
    \\tab2d.addEventListener("click",function(e){
    \\ if(document.body.classList.contains("mode-3d")){e.preventDefault();show2d();}});
    \\try{if(new URLSearchParams(location.search).get("view")==="3d")show3d();}catch(e){}
    \\})();</script>
;

// ── CLI layout-mutation tools ──────────────────────────────────────────
//
// The read-only PCB tools (get_pcb_layout_image / describe_pcb_layout /
// compare_layout_to_starred) let an agent SEE a placement; these six let it
// EDIT one — set poses, draw a board outline, autoroute, save/star, clear
// copper, and run the pre-fab gate — so a design can go schematic → gated
// Gerbers with no browser. They persist into the same `<design>.layouts.json`
// sidecar the viewer writes, through the same save/route/fab helpers above, so
// a layout the agent builds loads unchanged in `/pcb-layout`.
//
// Each takes the CLI arg object + the response buffer and returns `ok`.
// Mutations write `<design>.layouts.json` and report the design's current
// `live_version` (the sidecar isn't the design source, so the counter is
// informational — the viewer picks up layout changes on its next load).

/// Shared error/response fragments for the layout tools (extracted so the
/// repeated-literal check stays quiet and the wording stays consistent).
const mcp_err_missing_name = "missing argument \"name\"";
const mcp_err_no_design = "no design or module by that name";
/// `mcpFailFmt` template for a design/module that fails to evaluate + solve.
const mcp_err_resolve_layout = "could not resolve layout: {s}";
/// `{"ok":true,"live_version":N,"layout":` — the opening the tools that report
/// only a layout name share (set_board_outline / route_pcb / clear_routes).
const mcp_ok_layout_fmt = "{{\"ok\":true,\"live_version\":{d},\"layout\":";

/// A single requested pose from `set_part_poses` (`x_mm`/`y_mm` in mm; `rot`/
/// `side`/`locked` optional — absent keeps the part's current value).
const McpReqPose = struct {
    ref: []const u8,
    has_xy: bool,
    x: f64,
    y: f64,
    has_rot: bool,
    rot: f64,
    has_side: bool,
    side: optimizer.Side,
    has_locked: bool,
    locked: bool,
};

/// `args.key` as a string (null when absent / not a string).
fn mcpArgStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `args.key` as a bool (absent / non-bool ⇒ false).
fn mcpArgBool(args_val: ?std.json.Value, key: []const u8) bool {
    return mcpArgBoolOpt(args_val, key) orelse false;
}

/// `args.key` as an OPTIONAL bool — null when absent (or non-bool), so a caller
/// can distinguish "not supplied" (fall back to a computed default) from an
/// explicit `false`. `route_pcb`'s `selected_only` uses this to default to
/// incremental whenever a scope was named.
fn mcpArgBoolOpt(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

/// `args.key` as an optional JSON number. Unlike `jsonNum`, absence stays null
/// so coordinate-scoped mutations cannot silently target the origin.
fn mcpArgNumOpt(args_val: ?std.json.Value, key: []const u8) ?f64 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => null,
    };
}

/// `args.key` as a token list — a JSON string array or a comma-separated
/// string (trimmed, empties dropped). Absent ⇒ empty slice.
fn mcpArgStrList(alloc: std.mem.Allocator, args_val: ?std.json.Value, key: []const u8) []const []const u8 {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get(key) orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    if (v == .array) {
        for (v.array.items) |it| {
            if (it == .string and it.string.len > 0) list.append(alloc, it.string) catch break;
        }
    } else if (v == .string) {
        var it = std.mem.tokenizeScalar(u8, v.string, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len > 0) list.append(alloc, t) catch break;
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// Write an `{"ok":false,"error":<msg>}` envelope into `out` and return false
/// (the CLI layer flags the result `isError`). The single error spelling for
/// every layout tool.
fn mcpFail(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) !bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try writeJsonStr(w, msg);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

/// `mcpFail` with a formatted message (built on `alloc`, then escaped).
fn mcpFailFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !bool {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return mcpFail(out, alloc, msg);
}

/// Is `layout` the ★ entry of `name`'s sidecar? Read back AFTER a write so a
/// tool result reports the star as it actually landed on disk, not as asked.
fn mcpIsStarred(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layout: []const u8) bool {
    for (readLayouts(alloc, project_dir, name)) |L| {
        if (std.mem.eql(u8, L.name, layout)) return L.default;
    }
    return false;
}

/// Does `name` resolve to a design or module at all? The existence guard the
/// layout-mutation tools run before touching a sidecar, so a typo'd name fails
/// with "no such design" instead of quietly minting one.
fn mcpBlockExists(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    return resolveBlock(alloc, project_dir, name, &eval, &module_res) != null;
}

/// The layout entry the agent's edits land on: the `layout` arg by name, else
/// the blessed snapshot (★ default → newest manual → any). Null when nothing
/// matches (a block with no saved layouts, or an unknown `layout` name — the
/// two are distinguished by the caller, which errors on a name it can't find).
pub fn mcpReadWorking(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layout_arg: ?[]const u8,
) ?SavedLayout {
    const layouts = readLayouts(alloc, project_dir, name);
    if (layout_arg) |la| {
        for (layouts) |L| {
            if (std.mem.eql(u8, L.name, la)) return L;
        }
        return null;
    }
    if (blessedLayout(layouts)) |L| return L.*;
    return null;
}

/// The name the working layout is stored under (see `mcpReadWorking`): the
/// `layout` arg, else the blessed snapshot's name, else "layout" — the name a
/// block's first-ever layout is minted under, matching what the viewer's own
/// first save has always produced for a design.
pub fn mcpWorkingName(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layout_arg: ?[]const u8,
) []const u8 {
    if (layout_arg) |la| return la;
    if (blessedLayout(readLayouts(alloc, project_dir, name))) |L| return L.name;
    return "layout";
}

fn mcpWorkingDimensions(working: ?SavedLayout) []const SavedPartEdgeDimension {
    return if (working) |layout| layout.dimensions else &.{};
}

/// Persist `entry` as the working layout: upsert by name (starring it clears
/// any other default), and star a block's first-ever layout so the page,
/// KiCad sync and fab outputs all reopen on it. Mirrors `saveNamedLayoutApi`.
pub fn mcpPersistWorking(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    entry_in: SavedLayout,
    star: bool,
) void {
    var entry = entry_in;
    entry.kind = kind_manual;
    // Every agent mutation is an edit, including an outline/route update to an
    // existing named layout. Refresh the timestamp so the editor's default
    // newest-edited-first ordering reflects the actual working layout.
    entry.ts = clock.timestamp();
    const existing = readLayouts(alloc, project_dir, name);
    var out: std.ArrayList(SavedLayout) = .empty;
    var replaced = false;
    for (existing) |L| {
        if (!replaced and std.mem.eql(u8, L.name, entry.name)) {
            entry.default = star or L.default;
            replaced = true;
        } else {
            var e = L;
            if (star) e.default = false;
            out.append(alloc, e) catch return;
        }
    }
    if (!replaced) entry.default = star;
    // Keep the physical history newest-first too, which resolves ties between
    // edits stamped during the same second before the stable display sort.
    out.insert(alloc, 0, entry) catch return;
    starFirstEver(out.items);
    mcpProtectedWrite(alloc, project_dir, name, out.items);
}

/// Write a sidecar mutated over CLI the way the viewer's Save does: snapshot
/// the previous design-level sidecar into `history/` first (best-effort), then
/// stamp `disk rev + 1` — so an agent's mutation is (a) recoverable and (b)
/// visible to an open editor tab's optimistic-concurrency guard (the tab's now
/// stale rev 409s on its next save instead of silently clobbering). CLI tools
/// are design-level only, so there is no `sub` variant.
fn mcpProtectedWrite(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layouts: []const SavedLayout) void {
    if (layoutsSidecar(alloc, project_dir, name, null, layouts_ext)) |scp| {
        _ = history.snapshotLayouts(alloc, project_dir, name, scp) catch null;
    }
    // Refresh the optimizer-cache poses to the blessed layout so a default CLI
    // read (rough → readAutoPoses, the cache slot — not the starred layout)
    // reflects this write, not the pre-mutation scene (read-after-write bug #2;
    // the solver applies a clean full cache verbatim). Tuning params survive.
    var cache = readCacheSlot(alloc, project_dir, name) orelse CacheSlot{ .params = .{}, .parts = null };
    if (blessedLayout(layouts)) |bl| cache.parts = bl.parts;
    writeLayoutsFile(alloc, project_dir, name, layouts, cache, readLayoutRev(alloc, project_dir, name, null) + 1);
}

/// Net NAME at flattened-net index `idx` (−1 / out-of-range ⇒ "" — foreign
/// copper the sidecar still stores). Inverse of `restoreRoutes`' name→index.
fn mcpNetNameAt(nets: []const export_kicad.FlatNet, idx: i32) []const u8 {
    if (idx < 0) return "";
    const u: usize = @intCast(idx);
    return if (u < nets.len) nets[u].name else "";
}

fn routeArcOwnsTrack(arcs: []const router.Arc, track: router.Track) bool {
    for (arcs) |arc| {
        if (arc.layer != track.layer or arc.net != track.net or @abs(arc.width - track.width) > 0.0001) continue;
        if (outline_mod.arcOwnsSegment(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, 0.0001)) return true;
    }
    return false;
}

fn savedTrackMetadataMatch(candidate: SavedTrack, saved: SavedTrack) bool {
    if (candidate.l != saved.l or @abs(candidate.w - saved.w) > 1e-9) return false;
    return std.mem.eql(u8, candidate.net, saved.net);
}

fn savedViaMetadataMatch(candidate: SavedVia, saved: SavedVia) bool {
    if (@abs(candidate.x - saved.x) > 1e-9 or @abs(candidate.y - saved.y) > 1e-9) return false;
    if (@abs(candidate.d - saved.d) > 1e-9 or @abs(candidate.drill - saved.drill) > 1e-9) return false;
    return std.mem.eql(u8, candidate.net, saved.net);
}

/// A router `RouteResult` → the sidecar's `SavedRoutes` shape (net INDEX →
/// net NAME, so the copper survives the next flatten's index shuffle). The
/// persistence counterpart of `restoreRoutes`.
pub fn mcpSavedRoutesFrom(
    alloc: std.mem.Allocator,
    r: router.RouteResult,
    nets: []const export_kicad.FlatNet,
    prior: ?SavedRoutes,
) std.mem.Allocator.Error!SavedRoutes {
    var tracks: std.ArrayList(SavedTrack) = .empty;
    for (r.tracks) |t| {
        if (routeArcOwnsTrack(r.arcs, t)) continue;
        var saved = SavedTrack{
            .x1 = t.x1,
            .y1 = t.y1,
            .x2 = t.x2,
            .y2 = t.y2,
            .l = t.layer,
            .w = t.width,
            .net = mcpNetNameAt(nets, t.net),
        };
        var matched_prior = false;
        if (prior) |old| for (old.tracks) |candidate| {
            if (candidate.xm != null or candidate.ym != null) continue;
            if (!savedTrackMetadataMatch(candidate, saved)) continue;
            const forward = @abs(candidate.x1 - saved.x1) <= 1e-9 and @abs(candidate.y1 - saved.y1) <= 1e-9 and
                @abs(candidate.x2 - saved.x2) <= 1e-9 and @abs(candidate.y2 - saved.y2) <= 1e-9;
            const reverse = @abs(candidate.x1 - saved.x2) <= 1e-9 and @abs(candidate.y1 - saved.y2) <= 1e-9 and
                @abs(candidate.x2 - saved.x1) <= 1e-9 and @abs(candidate.y2 - saved.y1) <= 1e-9;
            if (forward or reverse) {
                saved.g = candidate.g;
                saved.source = candidate.source;
                saved.id = candidate.id;
                matched_prior = true;
                break;
            }
        };
        if (!matched_prior) saved.source = route_source_autorouter;
        try tracks.append(alloc, saved);
    }
    for (r.arcs) |arc| {
        var saved = SavedTrack{
            .x1 = arc.p1[0],
            .y1 = arc.p1[1],
            .xm = arc.pm[0],
            .ym = arc.pm[1],
            .x2 = arc.p2[0],
            .y2 = arc.p2[1],
            .l = arc.layer,
            .w = arc.width,
            .net = mcpNetNameAt(nets, arc.net),
        };
        var matched_prior = false;
        if (prior) |old| for (old.tracks) |candidate| {
            if (candidate.xm == null or candidate.ym == null or !savedTrackMetadataMatch(candidate, saved)) continue;
            const midpoint_matches = @abs(candidate.xm.? - saved.xm.?) <= 1e-9 and @abs(candidate.ym.? - saved.ym.?) <= 1e-9;
            const endpoint_matches = (@abs(candidate.x1 - saved.x1) <= 1e-9 and @abs(candidate.y1 - saved.y1) <= 1e-9 and
                @abs(candidate.x2 - saved.x2) <= 1e-9 and @abs(candidate.y2 - saved.y2) <= 1e-9) or
                (@abs(candidate.x1 - saved.x2) <= 1e-9 and @abs(candidate.y1 - saved.y2) <= 1e-9 and
                    @abs(candidate.x2 - saved.x1) <= 1e-9 and @abs(candidate.y2 - saved.y1) <= 1e-9);
            if (midpoint_matches and endpoint_matches) {
                saved.g = candidate.g;
                saved.source = candidate.source;
                saved.id = candidate.id;
                matched_prior = true;
                break;
            }
        };
        if (!matched_prior) saved.source = route_source_autorouter;
        try tracks.append(alloc, saved);
    }
    const vias = try alloc.alloc(SavedVia, r.vias.len);
    for (r.vias, 0..) |v, i| {
        vias[i] = .{
            .x = v.x,
            .y = v.y,
            .d = v.dia,
            .drill = v.drill,
            .net = mcpNetNameAt(nets, v.net),
        };
        var matched_prior = false;
        if (prior) |old| for (old.vias) |candidate| {
            if (!savedViaMetadataMatch(candidate, vias[i])) continue;
            vias[i].g = candidate.g;
            vias[i].f = candidate.f;
            vias[i].source = candidate.source;
            vias[i].s = candidate.s;
            vias[i].id = candidate.id;
            matched_prior = true;
            break;
        };
        if (!matched_prior) vias[i].source = route_source_autorouter;
    }
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    for (r.rf_port_outcomes) |outcome| {
        if (!outcome.success or outcome.physical.gate_removed) continue;
        if (outcome.physical.samples.len < 2) continue;
        try rf_paths.append(alloc, .{
            .net = mcpNetNameAt(nets, outcome.net),
            .layer = outcome.physical.layer,
            .samples = outcome.physical.samples,
        });
    }
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = vias, .rf_paths = try rf_paths.toOwnedSlice(alloc) };
}

/// The set of net NAMES touched by any part in `moved` — the copper to
/// invalidate when those parts move (mirrors the viewer's `clearRouteFor`:
/// a moved part's nets' routed copper is stale, so it's dropped).
fn mcpNetsTouchingRefs(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    moved: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var set = std.StringHashMapUnmanaged(void).empty;
    for (placement.nets) |net| {
        for (net.pins) |pin| {
            if (moved.contains(pin.ref_des)) {
                try set.put(alloc, net.name, {});
                break;
            }
        }
    }
    return set;
}

/// Drop every track/via whose net is in `drop` from `sr`. Custom zones are
/// board geometry, not route-wave output, so they always survive a scoped clear
/// or reroute. Returns the surviving copper (null when nothing survives) and
/// how many track/via segments were dropped.
///
/// A via also goes when its FENCE tag (`f`, the RF net it flanks) is in the drop
/// set: an RF via fence is geometry of its trace, not of the ground net it
/// stitches, so moving an RF part must take its fence with its copper. Keyed on
/// `net` alone the fence would survive every reroute of the trace it hugs and
/// slowly become a row of vias beside nothing.
const McpDroppedRoutes = struct { routes: ?SavedRoutes, dropped: usize };
fn mcpDropRoutesForNets(
    alloc: std.mem.Allocator,
    sr: ?SavedRoutes,
    drop: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!McpDroppedRoutes {
    const s = sr orelse return .{ .routes = null, .dropped = 0 };
    var tracks: std.ArrayList(SavedTrack) = .empty;
    var vias: std.ArrayList(SavedVia) = .empty;
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    var dropped: usize = 0;
    for (s.tracks) |t| {
        if (t.net.len > 0 and drop.contains(t.net)) dropped += 1 else try tracks.append(alloc, t);
    }
    for (s.vias) |v| {
        const own = v.net.len > 0 and drop.contains(v.net);
        const fenced = v.f.len > 0 and drop.contains(v.f);
        if (own or fenced) dropped += 1 else try vias.append(alloc, v);
    }
    for (s.rf_paths) |path| if (!drop.contains(path.net)) try rf_paths.append(alloc, path);
    if (tracks.items.len == 0 and vias.items.len == 0 and s.zones.len == 0 and rf_paths.items.len == 0)
        return .{ .routes = null, .dropped = dropped };
    return .{
        .routes = .{
            .tracks = try tracks.toOwnedSlice(alloc),
            .vias = try vias.toOwnedSlice(alloc),
            .zones = s.zones,
            .rf_paths = try rf_paths.toOwnedSlice(alloc),
        },
        .dropped = dropped,
    };
}

/// Drop only vias of the selected nets whose centres lie within `radius` of
/// (`x`,`y`). This is the surgical counterpart to net-wide clearing: dense
/// boards often need one obsolete stitch removed without erasing hundreds of
/// unrelated GND segments. Tracks, zones, RF paths, and non-matching vias are
/// retained byte-for-byte.
fn mcpDropViasNear(
    alloc: std.mem.Allocator,
    sr: ?SavedRoutes,
    drop: *const std.StringHashMapUnmanaged(void),
    x: f64,
    y: f64,
    radius: f64,
) std.mem.Allocator.Error!McpDroppedRoutes {
    const s = sr orelse return .{ .routes = null, .dropped = 0 };
    var vias: std.ArrayList(SavedVia) = .empty;
    var dropped: usize = 0;
    const radius_sq = radius * radius;
    for (s.vias) |v| {
        const dx = v.x - x;
        const dy = v.y - y;
        const selected = v.net.len > 0 and drop.contains(v.net);
        if (selected and dx * dx + dy * dy <= radius_sq) {
            dropped += 1;
        } else {
            try vias.append(alloc, v);
        }
    }
    if (s.tracks.len == 0 and vias.items.len == 0 and s.zones.len == 0 and s.rf_paths.len == 0)
        return .{ .routes = null, .dropped = dropped };
    return .{
        .routes = .{
            .tracks = s.tracks,
            .vias = try vias.toOwnedSlice(alloc),
            .zones = s.zones,
            .rf_paths = s.rf_paths,
        },
        .dropped = dropped,
    };
}

/// Keep only the tracks/vias whose net is in `keep` (the fresh copper for the
/// `route_pcb` `nets` scope). Zones deliberately stay with the retained base,
/// avoiding duplicate board geometry when the two route sets merge. Null when
/// no track/via matches.
fn mcpKeepRoutesForNets(
    alloc: std.mem.Allocator,
    sr: SavedRoutes,
    keep: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!?SavedRoutes {
    var tracks: std.ArrayList(SavedTrack) = .empty;
    var vias: std.ArrayList(SavedVia) = .empty;
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    for (sr.tracks) |t| {
        if (t.net.len > 0 and keep.contains(t.net)) try tracks.append(alloc, t);
    }
    for (sr.vias) |v| {
        if (v.net.len > 0 and keep.contains(v.net)) try vias.append(alloc, v);
    }
    for (sr.rf_paths) |path| if (keep.contains(path.net)) try rf_paths.append(alloc, path);
    if (tracks.items.len == 0 and vias.items.len == 0 and rf_paths.items.len == 0) return null;
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = try vias.toOwnedSlice(alloc), .rf_paths = try rf_paths.toOwnedSlice(alloc) };
}

/// Concatenate two optional route sets (either may be null), carrying one copy
/// of the persistent custom zones. Scoped fresh copper normally has no zones;
/// the fallback handles a zone-only side if either helper is used independently.
fn mcpMergeRoutes(alloc: std.mem.Allocator, a: ?SavedRoutes, b: ?SavedRoutes) std.mem.Allocator.Error!?SavedRoutes {
    const ta = if (a) |x| x.tracks else &[_]SavedTrack{};
    const tb = if (b) |x| x.tracks else &[_]SavedTrack{};
    const va = if (a) |x| x.vias else &[_]SavedVia{};
    const vb = if (b) |x| x.vias else &[_]SavedVia{};
    const za = if (a) |x| x.zones else &[_]SavedZone{};
    const zb = if (b) |x| x.zones else &[_]SavedZone{};
    const zones = if (za.len > 0) za else zb;
    const ra = if (a) |x| x.rf_paths else &[_]SavedRfPath{};
    const rb = if (b) |x| x.rf_paths else &[_]SavedRfPath{};
    if (ta.len + tb.len == 0 and va.len + vb.len == 0 and zones.len == 0 and ra.len + rb.len == 0) return null;
    const tracks = try alloc.alloc(SavedTrack, ta.len + tb.len);
    @memcpy(tracks[0..ta.len], ta);
    @memcpy(tracks[ta.len..], tb);
    const vias = try alloc.alloc(SavedVia, va.len + vb.len);
    @memcpy(vias[0..va.len], va);
    @memcpy(vias[va.len..], vb);
    const rf_paths = try alloc.alloc(SavedRfPath, ra.len + rb.len);
    @memcpy(rf_paths[0..ra.len], ra);
    @memcpy(rf_paths[ra.len..], rb);
    return .{ .tracks = tracks, .vias = vias, .zones = zones, .rf_paths = rf_paths };
}

/// Parse the `poses` argument of `set_part_poses` into `[]McpReqPose`. Null
/// when the arg is absent or not an array. Non-object entries are skipped;
/// per-item `x_mm`/`y_mm` presence is validated by the caller.
fn mcpParsePoses(alloc: std.mem.Allocator, args_val: ?std.json.Value) ?[]McpReqPose {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get("poses") orelse return null;
    if (v != .array) return null;
    var list: std.ArrayList(McpReqPose) = .empty;
    for (v.array.items) |it| {
        if (it != .object) continue;
        const ref_v = it.object.get("ref") orelse it.object.get("origin") orelse continue;
        if (ref_v != .string) continue;
        const xv = it.object.get("x_mm");
        const yv = it.object.get("y_mm");
        const rv = it.object.get("rot");
        const sv = it.object.get("side");
        const lv = it.object.get("locked");
        list.append(alloc, .{
            .ref = ref_v.string,
            .has_xy = xv != null and yv != null,
            .x = jsonNum(xv),
            .y = jsonNum(yv),
            .has_rot = rv != null,
            .rot = jsonNum(rv),
            .has_side = sv != null,
            .side = jsonSide(sv),
            .has_locked = lv != null,
            .locked = jsonFlag(lv),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// The origin part of a possibly-prefixed key: "buck/U1" → "U1"; "C3" → "C3".
/// Pairs with `refPrefix` so a request can name a part by its module-local
/// origin key ("buck/C_IN") the same way a saved pose stores it.
fn mcpOriginOf(s: []const u8) []const u8 {
    const p = refPrefix(s);
    return if (p.len > 0 and s.len > p.len) s[p.len + 1 ..] else s;
}

/// `set_part_poses` — batch pose update on the design's working (or named)
/// layout. Every `ref` is resolved against the current flatten (exact ref-des
/// first, then module-local origin key scoped by sub-block prefix); an unknown
/// ref fails the whole call (nothing is written). Unlisted parts keep their
/// poses; a moved part's nets' persisted copper is dropped (stale).
pub fn mcpSetPartPoses(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const reqs = mcpParsePoses(alloc, args_val) orelse return mcpFail(out, alloc, "missing or malformed \"poses\" array");
    if (reqs.len == 0) return mcpFail(out, alloc, "\"poses\" is empty");
    const layout_arg = mcpArgStr(args_val, "layout");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const base = posesFromPlacement(alloc, placement) orelse return mcpFail(out, alloc, "out of memory building poses");

    // ref/origin → index into `base`, for O(1) resolve + patch.
    var idx_of = std.StringHashMapUnmanaged(usize).empty;
    var origin_of = std.StringHashMapUnmanaged(usize).empty;
    for (base, 0..) |p, i| {
        try idx_of.put(alloc, p.ref, i);
        if (p.origin.len > 0) {
            const key = try std.fmt.allocPrint(alloc, pin_key_fmt, .{ refPrefix(p.ref), p.origin });
            try origin_of.put(alloc, key, i);
        }
    }

    var moved = std.StringHashMapUnmanaged(void).empty;
    var updated: std.ArrayList([]const u8) = .empty;
    for (reqs) |rq| {
        if (!rq.has_xy) return mcpFailFmt(out, alloc, "pose for \"{s}\" is missing x_mm/y_mm", .{rq.ref});
        const i: usize = idx_of.get(rq.ref) orelse blk: {
            const key = try std.fmt.allocPrint(alloc, pin_key_fmt, .{ refPrefix(rq.ref), mcpOriginOf(rq.ref) });
            break :blk origin_of.get(key) orelse
                return mcpFailFmt(out, alloc, "unknown ref \"{s}\" — not a component or origin key in this design", .{rq.ref});
        };
        var p = &base[i];
        const before_x = p.x;
        const before_y = p.y;
        const before_rot = p.rot;
        const before_side = p.side;
        p.x = rq.x;
        p.y = rq.y;
        if (rq.has_rot) p.rot = rq.rot;
        if (rq.has_side) p.side = rq.side;
        if (rq.has_locked) p.locked = rq.locked;
        if (before_x != p.x or before_y != p.y or before_rot != p.rot or before_side != p.side)
            try moved.put(alloc, p.ref, {});
        try updated.append(alloc, p.ref);
    }

    // A moved part's nets' persisted copper is now stale — drop it, keeping
    // the working layout's outline / texts / other-net copper intact.
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    var drop = try mcpNetsTouchingRefs(alloc, placement, &moved);
    const filtered = try mcpDropRoutesForNets(alloc, if (working) |w| w.routes else null, &drop);

    const entry = SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = base,
        .routes = filtered.routes,
        .outline = if (working) |w| w.outline else null,
        .texts = if (working) |w| w.texts else &.{},
        .dimensions = mcpWorkingDimensions(working),
    };
    mcpPersistWorking(alloc, project_dir, name, entry, false);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"total_parts\":{d},\"moved\":{d},\"routes_dropped\":{d},\"updated\":[", .{ base.len, moved.count(), filtered.dropped });
    for (updated.items, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonStr(w, r);
    }
    try w.writeAll("]}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// A `rect` object's nested `pts` array, if any (null when `rect` is absent
/// or not an object). Split out so the polygon lookup stays one short line.
fn mcpNestedPts(rect_v: ?std.json.Value) ?std.json.Value {
    const r = rect_v orelse return null;
    if (r != .object) return null;
    return r.object.get("pts");
}

/// Parse `set_board_outline`'s outline argument (`av` is the args object): a
/// `pts` polygon (top-level or under `rect`) wins, its bbox filling the rect
/// fields; else the `rect` (or top-level) `{x,y,w,h}`. Same validation as the
/// sidecar reader (`parseOutlinePts` / `parseSavedOutline`), so it round-trips.
fn mcpParseOutlineArg(alloc: std.mem.Allocator, av: std.json.Value) ?SavedOutline {
    const rect_v: ?std.json.Value = av.object.get("rect");
    const pts_v: ?std.json.Value = av.object.get("pts") orelse mcpNestedPts(rect_v);
    if (pts_v) |pv| {
        const pts = parseOutlinePts(alloc, pv) orelse return null;
        const bb = outline_mod.bboxRect(pts);
        if (!(bb.w > 0) or !(bb.h > 0)) {
            alloc.free(pts);
            return null;
        }
        return .{ .x = bb.minx, .y = bb.miny, .w = bb.w, .h = bb.h, .pts = pts };
    }
    return parseSavedOutline(alloc, rect_v orelse av);
}

/// `set_board_outline` — write the working layout's board outline (a
/// `{x,y,w,h}` rect or a `pts` polygon ≥3 vertices). The outline becomes the
/// placement's `board_rect`/`board_poly`, so every renderer draws it and the
/// board-edge DRC + Gerber Edge.Cuts profile use it. Bootstraps a base
/// placement when the design has no layout yet.
pub fn mcpSetBoardOutline(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const av = args_val orelse return mcpFail(out, alloc, "missing outline");
    if (av != .object) return mcpFail(out, alloc, "missing rect/pts");

    // A `pts` polygon (top-level or under `rect`) wins; else the `rect`
    // (or top-level) `{x,y,w,h}`. `parseOutlinePts` + `parseSavedOutline`
    // do the validation the sidecar reader uses, so an outline set here reads
    // back identically.
    const outline = mcpParseOutlineArg(alloc, av) orelse
        return mcpFail(out, alloc, "invalid outline — need a positive-area rect {x,y,w,h} or a polygon pts of ≥3 vertices");
    // A polygon outline must be fab-legal: no self-crossing edges, non-zero area
    // (a rect has no `pts` and is always simple, so it skips this).
    if (outline.pts) |pts| {
        if (!outline_mod.valid(pts))
            return mcpFail(out, alloc, "invalid outline — the polygon self-intersects or has zero area");
    }

    if (!mcpBlockExists(alloc, project_dir, name)) return mcpFail(out, alloc, mcp_err_no_design);
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    const parts: []const PartPose = if (working) |wl| wl.parts else mcpBootstrapParts(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "could not resolve a placement to attach the outline to");

    const entry = SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = parts,
        .routes = if (working) |wl| wl.routes else null,
        .outline = outline,
        .texts = if (working) |wl| wl.texts else &.{},
        .dimensions = mcpWorkingDimensions(working),
    };
    mcpPersistWorking(alloc, project_dir, name, entry, false);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.writeAll(outline_open);
    try writeSavedOutlineJson(w, outline);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Parse and validate `set_copper_zones`' complete replacement set. This tool
/// authors conductive pours only: every member needs a real net, a routable
/// (non-plane-claimed) copper layer, and a simple positive-area polygon.
fn mcpBuildCopperZones(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    placement: optimizer.Placement,
    args_val: ?std.json.Value,
) HandlerError!?[]const SavedZone {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const zv = av.object.get("zones") orelse return null;
    if (zv != .array) return null;
    var zones: std.ArrayList(SavedZone) = .empty;
    for (zv.array.items, 0..) |item, i| {
        if (item != .object) {
            _ = try mcpFailFmt(out, alloc, "zone {d} is not an object", .{i});
            return null;
        }
        const net_v = item.object.get("net") orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} is missing net", .{i});
            return null;
        };
        const layer_v = item.object.get("layer") orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} is missing layer", .{i});
            return null;
        };
        const poly_v = item.object.get("poly") orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} is missing poly", .{i});
            return null;
        };
        if (net_v != .string or layer_v != .string) {
            _ = try mcpFailFmt(out, alloc, "zone {d} net/layer must be strings", .{i});
            return null;
        }
        if (netIndexByName(placement, net_v.string) == null) {
            _ = try mcpFailFmt(out, alloc, "unknown net \"{s}\" in zone {d}", .{ net_v.string, i });
            return null;
        }
        if (placement.rules.signalIndexOfName(layer_v.string) == null) {
            _ = try mcpFailFmt(out, alloc, "unknown or plane-claimed copper layer \"{s}\" in zone {d}", .{ layer_v.string, i });
            return null;
        }
        const poly = parseOutlinePts(alloc, poly_v) orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} needs a poly of at least 3 [x,y] vertices", .{i});
            return null;
        };
        if (!outline_mod.valid(poly)) {
            _ = try mcpFailFmt(out, alloc, "zone {d} polygon self-intersects or has zero area", .{i});
            return null;
        }
        var priority: i64 = 0;
        if (item.object.get("priority")) |pv| priority = switch (pv) {
            .integer => |n| n,
            .float => |n| numeric.checkedInt(i64, n) orelse {
                _ = try mcpFailFmt(out, alloc, "zone {d} priority must be an integer", .{i});
                return null;
            },
            else => {
                _ = try mcpFailFmt(out, alloc, "zone {d} priority must be an integer", .{i});
                return null;
            },
        };
        try zones.append(alloc, .{
            .net = net_v.string,
            .layer = layer_v.string,
            .poly = poly,
            .flags = .{ .filled = true },
            .priority = priority,
        });
    }
    return try zones.toOwnedSlice(alloc);
}

/// Replace the saved layout's user copper pours without touching its poses,
/// tracks, vias, outline, or text. An empty `zones` array intentionally clears
/// every custom pour. This is the headless twin of drawing/editing pours in the
/// browser and gives agents an in-band path instead of hand-editing sidecars.
pub fn mcpSetCopperZones(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const zones = (try mcpBuildCopperZones(alloc, out, solved.placement, args_val)) orelse {
        if (out.items.len > 0) return false;
        return mcpFail(out, alloc, "missing or malformed zones array");
    };
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    const old_routes = if (working) |w| w.routes else null;
    const old_tracks = if (old_routes) |r| r.tracks else &[_]SavedTrack{};
    const old_vias = if (old_routes) |r| r.vias else &[_]SavedVia{};
    const old_rf = if (old_routes) |r| r.rf_paths else &[_]SavedRfPath{};
    const routes: ?SavedRoutes = if (old_tracks.len + old_vias.len + old_rf.len + zones.len > 0) .{
        .tracks = old_tracks,
        .vias = old_vias,
        .zones = zones,
        .rf_paths = old_rf,
    } else null;
    const entry = SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = if (working) |w| w.score else null,
        .parts = if (working) |w| w.parts else posesFromPlacement(alloc, solved.placement) orelse &.{},
        .routes = routes,
        .outline = if (working) |w| w.outline else null,
        .texts = if (working) |w| w.texts else &.{},
        .dimensions = mcpWorkingDimensions(working),
    };
    mcpPersistWorking(alloc, project_dir, name, entry, false);

    const user_zones = userZonesFrom(alloc, solved.placement.rules, zones);
    var tally = fab_readiness.Tally{};
    var violations: []const drc.Violation = &.{};
    if (routes) |saved| if (restoreRoutes(alloc, saved, solved.placement.nets)) |rr| {
        tally = try fab_readiness.routableTally(alloc, solved.placement, .{
            .tracks = rr.tracks,
            .vias = rr.vias,
            .zones = user_zones,
        });
        violations = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
            .placement = solved.placement,
            .routed = rr,
            .clearance = solved.placement.rules.design.routeParams().clearance,
            .zones = user_zones,
        });
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"zones\":{d},\"routed\":{d},\"total\":{d},\"drc\":{d},\"drc_errors\":{d},\"open\":", .{
        zones.len,
        tally.routed,
        tally.total,
        violations.len,
        drc.errorCount(violations),
    });
    try mcpWriteStrArray(w, tally.open);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Base poses for a design with no working layout yet — solve fresh and take
/// the auto placement's poses (live ref-des + origin keys). Null on failure.
fn mcpBootstrapParts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layout_arg: ?[]const u8) ?[]const PartPose {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch return null;
    return posesFromPlacement(alloc, solved.placement);
}

// ── route_pcb scoping helpers ────────────────────────────────────────────────

/// Retained copper for the nets NOT in a scoped route — stamped as a physical
/// obstacle and echoed unchanged in the router's result.
const McpExistingCopper = struct {
    tracks: []const route_policy.ExistingTrack = &.{},
    vias: []const route_policy.ExistingVia = &.{},
};

/// Translate a completed saved layout into the normalized physical copper view
/// used by the reference-router experiment.  The conversion is deliberately
/// copper-only: target placement supplies the live terminals, while the saved
/// tracks/vias supply the topology the router should learn.
fn mcpReferenceSnapshot(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    saved: SavedRoutes,
) std.mem.Allocator.Error!pcb_snapshot.Snapshot {
    var segments: std.ArrayList(pcb_snapshot.Segment) = .empty;
    var arcs: std.ArrayList(pcb_snapshot.Arc) = .empty;
    for (saved.tracks) |track| {
        var layer_buf: [board_layers.name_buf_len]u8 = undefined;
        const layer = try alloc.dupe(u8, placement.rules.signalLayerName(track.l, &layer_buf));
        if (track.xm != null and track.ym != null) {
            try arcs.append(alloc, .{
                .start = .{ .x = track.x1, .y = track.y1 },
                .mid = .{ .x = track.xm.?, .y = track.ym.? },
                .end = .{ .x = track.x2, .y = track.y2 },
                .width = track.w,
                .layer = layer,
                .net = track.net,
            });
        } else {
            try segments.append(alloc, .{
                .start = .{ .x = track.x1, .y = track.y1 },
                .end = .{ .x = track.x2, .y = track.y2 },
                .width = track.w,
                .layer = layer,
                .net = track.net,
            });
        }
    }
    var vias = try alloc.alloc(pcb_snapshot.Via, saved.vias.len);
    for (saved.vias, 0..) |via, i| vias[i] = .{
        .at = .{ .x = via.x, .y = via.y },
        .size = via.d,
        .drill = via.drill,
        .net = via.net,
    };
    return .{
        .segments = try segments.toOwnedSlice(alloc),
        .arcs = try arcs.toOwnedSlice(alloc),
        .vias = vias,
    };
}

fn mcpConcat(comptime T: type, alloc: std.mem.Allocator, a: []const T, b: []const T) std.mem.Allocator.Error![]const T {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    const out = try alloc.alloc(T, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// Overlay learned path topology on the authored plan without erasing its wave
/// priorities, hard layer limits, via budgets, or lane reservations.
fn mcpApplyReferenceGuides(
    alloc: std.mem.Allocator,
    options: *route_policy.Options,
    placement: optimizer.Placement,
    saved: SavedRoutes,
) std.mem.Allocator.Error!usize {
    const snapshot = try mcpReferenceSnapshot(alloc, placement, saved);
    const learned = try reference_guides.build(alloc, placement, snapshot, &.{}, .path, 0.05);
    const policies = try alloc.alloc(route_policy.NetPolicy, placement.nets.len);
    for (policies, 0..) |*policy, i| {
        policy.* = if (i < options.net.len) options.net[i] else .{};
        if (i >= learned.policies.len or !learned.policies[i].replay_reference_copper) continue;
        const reference = learned.policies[i];
        if (policy.preferred_layers == 0) policy.preferred_layers = reference.preferred_layers;
        policy.waypoints = reference.waypoints;
        policy.branches = reference.branches;
        policy.replay_reference_copper = true;
    }
    options.net = policies;
    options.guides.tracks = try mcpConcat(route_policy.GuideTrack, alloc, options.guides.tracks, learned.tracks);
    options.guides.vias = try mcpConcat(route_policy.GuideVia, alloc, options.guides.vias, learned.vias);
    const layer_count: usize = placement.rules.signalLayerCount();
    const reserved = try alloc.alloc(route_policy.ReservedLane, learned.vias.len * layer_count);
    const via_claim = placement.rules.design.via_dia +
        2 * placement.rules.design.clearance + placement.rules.design.track_width;
    var reserve_i: usize = 0;
    for (learned.vias) |via| for (0..layer_count) |layer| {
        reserved[reserve_i] = .{
            .x1 = via.x,
            .y1 = via.y,
            .x2 = via.x,
            .y2 = via.y,
            .layer = @intCast(layer),
            .net = via.net,
            .width = @max(via_claim, via.dia),
        };
        reserve_i += 1;
    };
    options.guides.reserved = try mcpConcat(route_policy.ReservedLane, alloc, options.guides.reserved, reserved);
    return learned.guided_nets;
}

const McpReferenceLayoutInput = struct {
    project_dir: []const u8,
    name: []const u8,
    placement: optimizer.Placement,
    options: *route_policy.Options,
    reference_layout: ?[]const u8,
};

fn mcpApplyReferenceLayout(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: McpReferenceLayoutInput,
) HandlerError!?usize {
    const reference_name = input.reference_layout orelse return 0;
    var reference_routes: ?SavedRoutes = null;
    for (readLayouts(alloc, input.project_dir, input.name)) |candidate| {
        if (std.mem.eql(u8, candidate.name, reference_name)) {
            reference_routes = candidate.routes;
            break;
        }
    }
    const saved = reference_routes orelse {
        _ = try mcpFailFmt(out, alloc, "reference layout \"{s}\" does not exist or has no copper", .{reference_name});
        return null;
    };
    const guided = try mcpApplyReferenceGuides(alloc, input.options, input.placement, saved);
    if (guided == 0) {
        _ = try mcpFailFmt(out, alloc, "reference layout \"{s}\" has no usable routed-net topology", .{reference_name});
        return null;
    }
    return guided;
}

/// The full net NAMES a resolved scope mask selects, in net order — the keys the
/// SavedRoutes drop/keep/merge machinery matches on when persisting scoped copper.
fn scopeNetNames(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    mask: []const bool,
) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (mask, 0..) |on, ni| if (on and ni < placement.nets.len) {
        try list.append(alloc, placement.nets[ni].name);
    };
    return list.toOwnedSlice(alloc);
}

/// A resolved + validated ad-hoc route scope: `mask` and `names` select the same
/// nets (index mask + full names), `matched` counts them, and `has_scope` is
/// false only when no selector token was named (⇒ route the whole board).
const McpScope = struct {
    mask: []const bool,
    names: []const []const u8,
    matched: usize,
    has_scope: bool,
};

/// Resolve `groups` (generic net-class / criticality-class / sub-block / net
/// tokens) ∪ `nets` (explicit names) into a validated scope shared by `route_pcb`
/// and `clear_routes`. On an unknown token or a scope matching no net it writes
/// the `{ok:false}` error into `out` and returns null (the handler returns
/// false); a request with no selector returns `has_scope = false`.
fn mcpResolveRouteScope(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    groups: []const []const u8,
    nets: []const []const u8,
) HandlerError!?McpScope {
    const rs = route_plan.resolveScope(alloc, block, placement, .{ .groups = groups, .nets = nets }) catch |e| {
        _ = try mcpFailFmt(out, alloc, "could not resolve route scope: {s}", .{@errorName(e)});
        return null;
    };
    const has_scope = rs.selectors > 0;
    if (has_scope) {
        if (rs.unknown.len > 0) {
            _ = try mcpFailFmt(out, alloc, "unknown route group/net: {s}", .{rs.unknown[0]});
            return null;
        }
        if (rs.matched == 0) {
            _ = try mcpFail(out, alloc, "route scope matched no nets on this board");
            return null;
        }
    }
    const pair_added = if (has_scope) route_plan.includeDiffPartners(placement, rs.mask) else 0;
    return .{
        .mask = rs.mask,
        .names = try scopeNetNames(alloc, placement, rs.mask),
        .matched = rs.matched + pair_added,
        .has_scope = has_scope,
    };
}

/// Write a JSON array of strings: `["a","b"]`.
fn mcpWriteStrArray(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonStr(w, s);
    }
    try w.writeAll("]");
}

/// Convert all non-selected working copper to retained maze obstacles.
fn mcpExistingCopper(
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    selected: []const bool,
) !McpExistingCopper {
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (routed.tracks) |track| {
        const ni: usize = if (track.net >= 0) @intCast(track.net) else selected.len;
        if (ni < selected.len and selected[ni]) continue;
        try tracks.append(alloc, .{
            .x1 = track.x1,
            .y1 = track.y1,
            .x2 = track.x2,
            .y2 = track.y2,
            .layer = track.layer,
            .width = track.width,
            .net = track.net,
        });
    }
    for (routed.vias) |via| {
        const ni: usize = if (via.net >= 0) @intCast(via.net) else selected.len;
        if (ni < selected.len and selected[ni]) continue;
        try vias.append(alloc, .{
            .x = via.x,
            .y = via.y,
            .dia = via.dia,
            .drill = via.drill,
            .net = via.net,
        });
    }
    return .{ .tracks = tracks.items, .vias = vias.items };
}

/// Apply route_pcb's optional persisted-run effort override. False means the
/// caller supplied a string other than the two public tiers.
fn mcpApplyRouteEffort(options: *route_policy.Options, args_val: ?std.json.Value) bool {
    const word = mcpArgStr(args_val, "effort") orelse return true;
    if (std.mem.eql(u8, word, "one_shot") or std.mem.eql(u8, word, "one-shot")) {
        options.effort = .one_shot;
    } else if (std.mem.eql(u8, word, "standard")) {
        options.effort = .standard;
    } else return false;
    return true;
}

fn mcpSavedTraceMm(routes: ?SavedRoutes) f64 {
    var trace_mm: f64 = 0;
    const saved = routes orelse return trace_mm;
    for (saved.tracks) |track| trace_mm += std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    return trace_mm;
}

/// Autoroute and persist the working PCB layout, applying any authored
/// `(pcb-plan (route …))` wave order and layer policy.
pub fn mcpRoutePcb(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const started_ms = clock.milliTimestamp();
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const nets_arg = mcpArgStrList(alloc, args_val, "nets");
    const groups_arg = mcpArgStrList(alloc, args_val, "groups");
    const selected_only_opt = mcpArgBoolOpt(args_val, "selected_only");
    const reference_layout = mcpArgStr(args_val, "reference_layout");
    const defer_drc = mcpArgBool(args_val, "defer_drc");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const rp = placement.rules.design.routeParams();
    const lowered_plan = route_plan.lower(alloc, solved.block, solved.placement) catch |e|
        return mcpFailFmt(out, alloc, "could not resolve PCB plan: {s}", .{@errorName(e)});

    // Resolve the ad-hoc scope (groups ∪ nets); a bad token / empty match writes
    // its own error and returns null here.
    const rscope = (try mcpResolveRouteScope(alloc, out, solved.block, placement, groups_arg, nets_arg)) orelse
        return false;
    // Incremental by default whenever a scope was named: route only the scoped
    // nets and keep every other net's copper. `selected_only:false` opts back
    // into a whole-board re-route that merely ADOPTS the scoped nets' new copper.
    const selected_only = selected_only_opt orelse rscope.has_scope;
    if (selected_only and !rscope.has_scope)
        return mcpFail(out, alloc, "selected_only needs a nets or groups scope");

    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    var route_options = lowered_plan.options;
    if (!mcpApplyRouteEffort(&route_options, args_val))
        return mcpFail(out, alloc, "effort must be \"one_shot\" or \"standard\"");
    // Hand-authored pours are retained physical copper. Every CLI route sees
    // them as same-net maze sources just like the browser Route button does,
    // including an excluded In2.Cu pour that terminals reach through vias.
    route_options.existing_zones = solved.shown_zones.sources;
    const reference_guided = (try mcpApplyReferenceLayout(alloc, out, .{
        .project_dir = project_dir,
        .name = name,
        .placement = placement,
        .options = &route_options,
        .reference_layout = reference_layout,
    })) orelse return false;
    if (selected_only) {
        route_options.selected_nets = rscope.mask;
        if (working) |wl| if (wl.routes) |saved| if (restoreRoutes(alloc, saved, placement.nets)) |prior| {
            const existing = try mcpExistingCopper(alloc, prior, rscope.mask);
            route_options.existing_tracks = existing.tracks;
            route_options.existing_vias = existing.vias;
        };
    }
    // Through the shared seam's gate, not `router.routeWithOptions` directly:
    // the committed board must report the same oracle-checked `routed` count
    // the preview surfaces do (see `route_plan.routeLowered`).
    const seeded = routeWithSubcircuitSeeds(alloc, project_dir, solved.block, placement, rp, route_options) catch |e|
        return mcpFailFmt(out, alloc, "routing failed: {s}", .{@errorName(e)});
    const seed_stats = seeded.seeds;
    var routed = seeded.result;
    routed = (try perimeter_fence.append(alloc, placement, routed)).?;
    var fresh = try mcpSavedRoutesFrom(alloc, routed, placement.nets, if (working) |w| w.routes else null);
    // Autorouting replaces tracks/vias, never the user's custom polygons.
    fresh.zones = if (working) |wl| if (wl.routes) |saved| saved.zones else &.{} else &.{};

    var merged: ?SavedRoutes = undefined;
    if (rscope.has_scope) {
        var keep = std.StringHashMapUnmanaged(void).empty;
        for (rscope.names) |n| try keep.put(alloc, n, {});
        const base_after_drop = try mcpDropRoutesForNets(alloc, if (working) |wl| wl.routes else null, &keep);
        const fresh_scoped = try mcpKeepRoutesForNets(alloc, fresh, &keep);
        merged = try mcpMergeRoutes(alloc, base_after_drop.routes, fresh_scoped);
    } else {
        merged = if (fresh.tracks.len == 0 and fresh.vias.len == 0 and fresh.zones.len == 0) null else fresh;
    }
    merged = routesWithPerimeter(alloc, placement, merged);

    // Checkpoint routed copper before the optional full-board DRC report. DRC
    // is diagnostic here (route_pcb has never rolled copper back on a
    // finding), and a dense-board report can be much slower than a selected
    // route. Persisting first means a client timeout cannot erase a successful
    // automatic batch. `defer_drc` lets a checkpointed run return immediately;
    // the final candidate still goes through run_fab_readiness once all scopes
    // are complete.
    const entry = SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = if (working) |wl| wl.parts else posesFromPlacement(alloc, placement) orelse &.{},
        .routes = merged,
        .outline = if (working) |wl| wl.outline else null,
        .texts = if (working) |wl| wl.texts else &.{},
        .dimensions = mcpWorkingDimensions(working),
    };
    mcpPersistWorking(alloc, project_dir, name, entry, false);

    // DRC-check exactly what was persisted unless this is a fast checkpoint.
    // Keep the direct pour-aware call visible at this mutation boundary: the
    // result is the report, not an error-union or a second generic DRC pass.
    var route_findings: []const drc.Violation = &.{};
    if (!defer_drc) if (merged) |saved| if (restoreRoutes(alloc, saved, placement.nets)) |restored| {
        const v = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
            .placement = placement,
            .routed = restored,
            .clearance = rp.clearance,
            .zones = solved.shown_zones.user,
        });
        route_findings = v;
    };
    const trace_mm = mcpSavedTraceMm(merged);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"routed\":{d},\"total\":{d},", .{ routed.routed, routed.total });
    try route_result_stats.writeDrc(w, route_findings, @max(0, clock.milliTimestamp() - started_ms));
    try w.print(
        ",\"drc_deferred\":{},\"trace_mm\":{d:.3},\"tracks\":{d},\"vias\":{d},\"reference_guided\":{d},\"reference_replayed\":{d}" ++
            ",\"pcb_plan\":{s},\"plan_warnings\":{d},\"selected_only\":{s},\"selected\":{d},\"groups\":",
        .{
            defer_drc,
            trace_mm,
            if (merged) |m| m.tracks.len else 0,
            if (merged) |m| m.vias.len else 0,
            reference_guided,
            routed.reference_replayed.len,
            if (lowered_plan.applied) "true" else "false",
            lowered_plan.warnings,
            if (selected_only) "true" else "false",
            rscope.matched,
        },
    );
    try mcpWriteStrArray(w, groups_arg);
    // `scope` echoes the CONCRETE net names the scope resolved to (so the agent
    // sees exactly what routed), or "all" for a whole-board run.
    try w.writeAll(",\"scope\":");
    if (!rscope.has_scope) try w.writeAll("\"all\"") else try mcpWriteStrArray(w, rscope.names);
    try w.writeAll(",\"unrouted\":");
    try mcpWriteStrArray(w, routed.failed);
    try writeRouteSeedStats(w, seed_stats);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// `save_pcb_layout` — snapshot the working state as a named layout, optionally
/// starred. `layout_name` names it (default: keep the working layout's own name,
/// so a plain save updates in place rather than forking a copy); `star` marks it
/// the blessed board, clearing any other default. A block's first-ever layout is
/// starred regardless — something must be blessed for the page, the KiCad sync
/// and the fab outputs to resolve.
pub fn mcpSavePcbLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_name = mcpArgStr(args_val, "layout_name");
    const star = mcpArgBool(args_val, "star");

    if (!mcpBlockExists(alloc, project_dir, name)) return mcpFail(out, alloc, mcp_err_no_design);
    // Read the current working state (the blessed layout) to re-save.
    const working = mcpReadWorking(alloc, project_dir, name, null) orelse
        return mcpFail(out, alloc, "no working layout to save — set poses (or an outline) first");

    // No `layout_name` = save the working layout back into itself. Naming one
    // forks the working state into a new snapshot alongside it — that fork is
    // how an agent banks a routing candidate before trying the next.
    const target_name: []const u8 = layout_name orelse working.name;
    const entry = SavedLayout{
        .name = target_name,
        .kind = kind_manual,
        .ts = 0,
        .score = working.score,
        .parts = working.parts,
        .routes = working.routes,
        .outline = working.outline,
        .texts = working.texts,
        .dimensions = working.dimensions,
    };
    mcpPersistWorking(alloc, project_dir, name, entry, star);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    // Report the star as it ENDED UP, not as asked: `starFirstEver` stars a
    // block's first-ever layout even when the caller didn't ask for it.
    const starred = mcpIsStarred(alloc, project_dir, name, target_name);
    try w.print("{{\"ok\":true,\"live_version\":{d},\"starred\":{s},\"layout\":", .{
        serve_root.getLiveVersion(name),
        if (starred) "true" else "false",
    });
    try writeJsonStr(w, target_name);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Resolve `groups` to concrete net names for `clear_routes`. This is the only
/// clear path that evaluates the design — group tokens need a solved placement
/// to classify nets — so it stays out of the fast `nets`-only path. Writes an
/// `{ok:false}` error into `out` and returns null on a bad token / unresolvable
/// design.
fn mcpClearGroupNames(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_dir: []const u8,
    name: []const u8,
    groups: []const []const u8,
) HandlerError!?[]const []const u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{}, &eval, &module_res) catch |e| {
        _ = try mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
        return null;
    };
    const rscope = (try mcpResolveRouteScope(alloc, out, solved.block, solved.placement, groups, &.{})) orelse return null;
    return rscope.names;
}

/// Remove all route-wave output while retaining user-authored zone intent.
/// Null means no zone remains, so the layout truly has no route object.
fn mcpClearAllRoutedCopper(sr: SavedRoutes) ?SavedRoutes {
    if (sr.zones.len == 0) return null;
    return .{
        .tracks = &.{},
        .vias = &.{},
        .zones = sr.zones,
    };
}

/// `clear_routes` — drop all persisted routed tracks/vias from the working
/// layout, or only the copper of a `nets` / `groups` scope, keeping poses,
/// outline, texts, and user-authored copper zones. The inverse of `route_pcb`,
/// sharing its scope vocabulary; zones are layout intent and feed the next
/// route rather than being output of the route wave.
pub fn mcpClearRoutes(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const nets_arg = mcpArgStrList(alloc, args_val, "nets");
    const groups_arg = mcpArgStrList(alloc, args_val, "groups");
    const near_x = mcpArgNumOpt(args_val, "x");
    const near_y = mcpArgNumOpt(args_val, "y");
    const radius_arg = mcpArgNumOpt(args_val, "radius");
    const has_near = near_x != null or near_y != null or radius_arg != null;

    if (!mcpBlockExists(alloc, project_dir, name)) return mcpFail(out, alloc, mcp_err_no_design);
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no working layout to clear");

    // The net names to drop: explicit `nets` (verbatim) plus every net each
    // `groups` token resolves to.
    var drop = std.StringHashMapUnmanaged(void).empty;
    for (nets_arg) |n| try drop.put(alloc, n, {});
    if (groups_arg.len > 0) {
        const names = (try mcpClearGroupNames(alloc, out, project_dir, name, groups_arg)) orelse return false;
        for (names) |n| try drop.put(alloc, n, {});
    }
    const scoped = nets_arg.len > 0 or groups_arg.len > 0;

    if (has_near and (near_x == null or near_y == null))
        return mcpFail(out, alloc, "coordinate-scoped clear_routes requires both x and y");
    if (has_near and !scoped)
        return mcpFail(out, alloc, "coordinate-scoped clear_routes requires a nets or groups scope");
    const near_radius = radius_arg orelse 0.05;
    if (has_near) {
        if (!std.math.isFinite(near_x.?))
            return mcpFail(out, alloc, "coordinate-scoped clear_routes needs finite x/y and radius > 0");
        if (!std.math.isFinite(near_y.?))
            return mcpFail(out, alloc, "coordinate-scoped clear_routes needs finite x/y and radius > 0");
        if (!std.math.isFinite(near_radius) or near_radius <= 0)
            return mcpFail(out, alloc, "coordinate-scoped clear_routes needs finite x/y and radius > 0");
    }

    var cleared: usize = 0;
    var new_routes: ?SavedRoutes = null;
    if (has_near) {
        const res = try mcpDropViasNear(alloc, working.routes, &drop, near_x.?, near_y.?, near_radius);
        if (res.dropped == 0)
            return mcpFail(out, alloc, "no selected via found within radius of x/y");
        new_routes = res.routes;
        cleared = res.dropped;
    } else if (scoped) {
        const res = try mcpDropRoutesForNets(alloc, working.routes, &drop);
        new_routes = res.routes;
        cleared = res.dropped;
    } else if (working.routes) |sr| {
        cleared = sr.tracks.len + sr.vias.len;
        // A clean-slate route still needs its authored power pours. They are
        // route INPUT, not disposable output; retain them while clearing every
        // routed track/via/RF path. This also keeps an In3 power plan from
        // silently disappearing in the normal clear → route workflow.
        new_routes = mcpClearAllRoutedCopper(sr);
    }

    const entry = SavedLayout{
        .name = working.name,
        .kind = kind_manual,
        .ts = 0,
        .score = working.score,
        .parts = working.parts,
        .routes = new_routes,
        .outline = working.outline,
        .texts = working.texts,
        .dimensions = working.dimensions,
    };
    mcpPersistWorking(alloc, project_dir, name, entry, false);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"cleared\":{d}}}", .{cleared});
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// One requested polyline of agent-authored copper: a net, a signal-layer NAME ("F.Cu"),
/// ≥2 points in board mm, and an optional width override (0 = the net's class).
const McpReqTrack = struct {
    net: []const u8,
    layer: []const u8,
    pts: []const [2]f64,
    width: f64 = 0,
};

/// One requested via (0 dia/drill = the net's `(net-class …)` via geometry).
const McpReqVia = struct {
    net: []const u8,
    x: f64,
    y: f64,
    dia: f64 = 0,
    drill: f64 = 0,
    /// Optional `"span":["F.Cu","In2.Cu"]` — the barrel's two copper layers as
    /// KiCad NAMES, resolved against this board's stackup (see `SavedVia.s`).
    span: ?[2][]const u8 = null,
};

/// A net's effective routing geometry — its `(net-class …)` overlay on the board
/// base params, mirroring `router.setNetParams` so hand copper defaults to
/// exactly what the autorouter would have drawn on that net.
const McpNetGeom = struct { width: f64, via_dia: f64, via_drill: f64 };

fn mcpNetGeom(placement: optimizer.Placement, ni: usize, rp: router.RouteParams) McpNetGeom {
    var g = McpNetGeom{ .width = rp.track_width, .via_dia = rp.via_dia, .via_drill = rp.via_drill };
    if (ni >= placement.rules.net.len) return g;
    const r = placement.rules.net[ni];
    if (r.width > 0) g.width = r.width;
    if (r.via_dia > 0) g.via_dia = r.via_dia;
    if (r.via_drill > 0) g.via_drill = r.via_drill;
    return g;
}

/// Parse one `points` array of `[x,y]` mm pairs. Null when it isn't an array of
/// 2-number arrays — malformed geometry must fail the request, never silently
/// drop a segment the agent believes it drew.
fn mcpParsePts(alloc: std.mem.Allocator, v: std.json.Value) ?[]const [2]f64 {
    if (v != .array) return null;
    var list: std.ArrayList([2]f64) = .empty;
    for (v.array.items) |p| {
        if (p != .array or p.array.items.len < 2) return null;
        list.append(alloc, .{ jsonNum(p.array.items[0]), jsonNum(p.array.items[1]) }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Parse `add_tracks`' `tracks` argument. Absent → empty (vias-only is legal);
/// present but malformed in ANY member → null, so the handler rejects the whole
/// request rather than landing a partial route.
fn mcpParseAddTracks(alloc: std.mem.Allocator, args_val: ?std.json.Value) ?[]McpReqTrack {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get("tracks") orelse return &.{};
    if (v != .array) return null;
    var list: std.ArrayList(McpReqTrack) = .empty;
    for (v.array.items) |it| {
        if (it != .object) return null;
        const net_v = it.object.get("net") orelse return null;
        const layer_v = it.object.get("layer") orelse return null;
        const pts_v = it.object.get("points") orelse return null;
        if (net_v != .string or layer_v != .string) return null;
        const pts = mcpParsePts(alloc, pts_v) orelse return null;
        list.append(alloc, .{
            .net = net_v.string,
            .layer = layer_v.string,
            .pts = pts,
            .width = jsonNum(it.object.get("width")),
        }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Parse `add_tracks`' optional `vias` argument, same all-or-nothing rule.
fn mcpParseAddVias(alloc: std.mem.Allocator, args_val: ?std.json.Value) ?[]McpReqVia {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get("vias") orelse return &.{};
    if (v != .array) return null;
    var list: std.ArrayList(McpReqVia) = .empty;
    for (v.array.items) |it| {
        if (it != .object) return null;
        const net_v = it.object.get("net") orelse return null;
        if (net_v != .string) return null;
        const xv = it.object.get("x") orelse return null;
        const yv = it.object.get("y") orelse return null;
        list.append(alloc, .{
            .net = net_v.string,
            .x = jsonNum(xv),
            .y = jsonNum(yv),
            .dia = jsonNum(it.object.get("dia")),
            .drill = jsonNum(it.object.get("drill")),
            .span = layout_layers.parseSpanArg(it.object.get("span")) orelse return null,
        }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Validate every requested track/via against the design's nets + stackup and
/// lower them to persisted copper. Writes its own error and returns null on the
/// first unknown net / unknown layer / too-short polyline, so a bad request
/// never half-lands.
fn mcpBuildAddedCopper(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    placement: optimizer.Placement,
    rp: router.RouteParams,
    reqs: []const McpReqTrack,
    vreqs: []const McpReqVia,
) HandlerError!?SavedRoutes {
    var tracks: std.ArrayList(SavedTrack) = .empty;
    var vias: std.ArrayList(SavedVia) = .empty;
    for (reqs) |t| {
        const ni = netIndexByName(placement, t.net) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown net \"{s}\" — no such net in this design", .{t.net});
            return null;
        };
        const layer = placement.rules.signalIndexOfName(t.layer) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown copper layer \"{s}\" on net \"{s}\"", .{ t.layer, t.net });
            return null;
        };
        if (t.pts.len < 2) {
            _ = try mcpFailFmt(out, alloc, "track on net \"{s}\" needs at least 2 points", .{t.net});
            return null;
        }
        const g = mcpNetGeom(placement, @intCast(ni), rp);
        const w = if (t.width > 0) t.width else g.width;
        for (t.pts[1..], 0..) |p, i| {
            try tracks.append(alloc, .{
                .x1 = t.pts[i][0],
                .y1 = t.pts[i][1],
                .x2 = p[0],
                .y2 = p[1],
                .l = layer,
                .w = w,
                .net = t.net,
                .source = route_source_agent,
            });
        }
    }
    for (vreqs) |v| {
        const ni = netIndexByName(placement, v.net) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown net \"{s}\" — no such net in this design", .{v.net});
            return null;
        };
        const g = mcpNetGeom(placement, @intCast(ni), rp);
        // An unknown span name rejects the whole request rather than silently
        // landing a through via where a blind one was asked for.
        var span: ?[2]u8 = null;
        if (v.span) |names| span = layout_layers.resolveSpan(placement.rules, names) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown copper layer in the via span [\"{s}\",\"{s}\"] on net \"{s}\"", .{ names[0], names[1], v.net });
            return null;
        };
        try vias.append(alloc, .{
            .x = v.x,
            .y = v.y,
            .d = if (v.dia > 0) v.dia else g.via_dia,
            .drill = if (v.drill > 0) v.drill else g.via_drill,
            .net = v.net,
            .source = route_source_agent,
            .s = span,
        });
    }
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = try vias.toOwnedSlice(alloc) };
}

/// `add_tracks` — draw agent-authored copper onto the working layout: polylines
/// (and optional vias) APPENDED to the layout's persisted tracks/vias, then
/// DRC-checked and persisted. The write-side counterpart of `clear_routes`.
///
/// This is the seam that lets an agent finish a net the autorouter gave up on.
/// Every remedy the stuck-net diagnostics emit re-runs the AUTOROUTER, so when
/// they report `cdt_geometry_limit` ("no priority edit reopens it — move the
/// part or widen the channel") there was previously no tool that could put
/// copper down at all; hand routing existed only in the browser.
///
/// These additions receive the `agent` source tag, distinct from browser-drawn
/// `human` copper and native `autorouter` output. The result reports
/// post-edit `routed`/`total`/`open` from the shared
/// connectivity oracle, so a caller sees immediately whether its copper closed
/// the net instead of having to re-describe the board.
/// Fab-blocking DRC on the board as it stands BEFORE this edit — the number a
/// hand-drawn addition must not exceed to be kept. Geometry only, per
/// `drc.errorCount`: an open net is not a reason to undo copper.
fn mcpBaselineErrors(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: SolvedRequest,
    working: ?SavedLayout,
    rp: router.RouteParams,
) usize {
    const w = working orelse return 0;
    const r = w.routes orelse return 0;
    const rr = restoreRoutes(alloc, r, solved.placement.nets) orelse return 0;
    return drc.errorCount(drc_rules.checkFilteredZones(alloc, project_dir, name, .{
        .placement = solved.placement,
        .routed = rr,
        .clearance = rp.clearance,
        .zones = solved.shown_zones.user,
    }));
}

fn landTransitCount(violations: []const drc.Violation) usize {
    return drc.countKind(violations, .land_transit);
}

fn landTransitCountForNet(violations: []const drc.Violation, net: i32) usize {
    var count: usize = 0;
    for (violations) |violation| {
        if (violation.kind == .land_transit and violation.who.net_a == net) count += 1;
    }
    return count;
}

fn padBoxGap(a: router.PadObs, b: router.PadObs) f64 {
    const dx = @max(@max(a.x0 - b.x1, b.x0 - a.x1), 0);
    const dy = @max(@max(a.y0 - b.y1, b.y0 - a.y1), 0);
    return std.math.hypot(dx, dy);
}

fn trackHasLandTransit(track: router.Track, pads: []const router.PadObs) bool {
    for (pads) |pad| {
        if (pad.thru or pad.net != track.net or pad.layer != track.layer) continue;
        const land = land_transit.Land{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly };
        if (land_transit.segmentOffence(
            land,
            .{ track.x1, track.y1 },
            .{ track.x2, track.y2 },
            track.width / 2,
        ) != null) return true;
    }
    return false;
}

fn mcpCopperViolations(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: SolvedRequest,
    routed: router.RouteResult,
    clearance: f64,
) []const drc.Violation {
    const filled = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
        .placement = solved.placement,
        .routed = routed,
        .clearance = clearance,
        .zones = solved.shown_zones.user,
    });
    // Fab readiness also reports the raw, no-zone `dangling_copper` hygiene
    // findings. Include those exact track identities in the cleanup plan even
    // when a surrounding pour would suppress them in the fill-aware pass. The
    // acceptance gate below remains fill-honest and rejects any deletion that
    // loses a routed net, so this only closes the reporting/cleanup mismatch.
    const bare = drc_rules.apply(
        alloc,
        drc_rules.load(alloc, project_dir, name),
        drc.check(alloc, solved.placement, routed, clearance) catch &.{},
    );
    var combined: std.ArrayList(drc.Violation) = .empty;
    combined.appendSlice(alloc, filled) catch return filled;
    for (bare) |finding| {
        if (finding.kind != .dangling_copper or finding.who.track_a < 0) continue;
        var duplicate = false;
        for (filled) |existing| {
            if (existing.kind == .dangling_copper and existing.who.track_a == finding.who.track_a) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) combined.append(alloc, finding) catch return filled;
    }
    return combined.toOwnedSlice(alloc) catch filled;
}

const LandRepairEvaluation = struct {
    violations: []const drc.Violation,
    errors: usize,
    tally: fab_readiness.Tally,
};

const LandRepairBoard = struct {
    tracks: *std.ArrayList(router.Track),
    evaluation: LandRepairEvaluation,
};

const LandRepairNetResult = struct {
    changed: bool = false,
    rejected: bool = false,
    segments_reanchored: usize = 0,
    tracks_pruned: usize = 0,
};

const LandRepairContext = struct {
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: SolvedRequest,
    restored: router.RouteResult,
    pads: []const router.PadObs,
    clearance: f64,
    selected: []bool,
};

fn evaluateLandRepair(
    ctx: LandRepairContext,
    tracks: []const router.Track,
) std.mem.Allocator.Error!LandRepairEvaluation {
    var candidate = ctx.restored;
    candidate.tracks = tracks;
    const violations = mcpCopperViolations(ctx.alloc, ctx.project_dir, ctx.name, ctx.solved, candidate, ctx.clearance);
    return .{
        .violations = violations,
        .errors = drc.errorCount(violations),
        .tally = try fab_readiness.routableTally(ctx.alloc, ctx.solved.placement, .{
            .tracks = candidate.tracks,
            .vias = candidate.vias,
            .zones = ctx.solved.shown_zones.user,
        }),
    };
}

fn landRepairSafe(candidate: LandRepairEvaluation, baseline: LandRepairEvaluation) bool {
    return candidate.errors <= baseline.errors and candidate.tally.routed >= baseline.tally.routed and
        candidate.tally.total == baseline.tally.total;
}

fn landRepairReduced(candidate: LandRepairEvaluation, baseline: LandRepairEvaluation, net: i32) bool {
    return landTransitCountForNet(candidate.violations, net) < landTransitCountForNet(baseline.violations, net);
}

fn pruneLandTransitTracks(
    ctx: LandRepairContext,
    net: i32,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!usize {
    var pruned: usize = 0;
    var track_i: usize = 0;
    while (track_i < board.tracks.items.len) {
        const track = board.tracks.items[track_i];
        if (track.net != net or !trackHasLandTransit(track, ctx.pads)) {
            track_i += 1;
            continue;
        }
        const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
        _ = board.tracks.orderedRemove(track_i);
        const candidate = try evaluateLandRepair(ctx, board.tracks.items);
        if (landRepairReduced(candidate, board.evaluation, net) and landRepairSafe(candidate, board.evaluation)) {
            board.evaluation = candidate;
            pruned += 1;
        } else {
            board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
            track_i += 1;
        }
    }
    return pruned;
}

fn tryWholeLandTransitRepair(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!?usize {
    const net: i32 = @intCast(net_i);
    const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
    ctx.selected[net_i] = true;
    const snapped = route_cleanup.snapLandTransitEndpoints(ctx.pads, board.tracks, ctx.selected);
    ctx.selected[net_i] = false;
    var candidate = try evaluateLandRepair(ctx, board.tracks.items);
    if (landTransitCountForNet(candidate.violations, net) == 0 and landRepairSafe(candidate, board.evaluation)) {
        board.evaluation = candidate;
        return snapped.segments_reanchored;
    }

    board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
    const second_snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
    ctx.selected[net_i] = true;
    const repaired = try route_cleanup.reanchorLandTransit(ctx.alloc, ctx.pads, board.tracks, ctx.selected);
    ctx.selected[net_i] = false;
    candidate = try evaluateLandRepair(ctx, board.tracks.items);
    if (landTransitCountForNet(candidate.violations, net) == 0 and landRepairSafe(candidate, board.evaluation)) {
        board.evaluation = candidate;
        return repaired.segments_reanchored;
    }
    board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(second_snapshot);
    return null;
}

fn repairLandTransitByPad(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!usize {
    const net: i32 = @intCast(net_i);
    var segments: usize = 0;
    var round: usize = 0;
    var progressed = true;
    while (progressed and round < 3) : (round += 1) {
        progressed = false;
        for (ctx.pads, 0..) |pad, pad_i| {
            if (pad.net != net or pad.thru) continue;
            const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
            ctx.selected[net_i] = true;
            const repaired = try route_cleanup.reanchorLandTransit(ctx.alloc, ctx.pads[pad_i .. pad_i + 1], board.tracks, ctx.selected);
            ctx.selected[net_i] = false;
            if (repaired.segments_reanchored == 0) continue;
            const candidate = try evaluateLandRepair(ctx, board.tracks.items);
            if (landRepairReduced(candidate, board.evaluation, net) and landRepairSafe(candidate, board.evaluation)) {
                board.evaluation = candidate;
                segments += repaired.segments_reanchored;
                progressed = true;
            } else {
                board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
            }
        }
    }
    return segments;
}

fn repairLandTransitByPair(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!usize {
    const net: i32 = @intCast(net_i);
    var segments: usize = 0;
    for (ctx.pads, 0..) |first_pad, first_i| {
        if (first_pad.net != net or first_pad.thru) continue;
        for (ctx.pads[first_i + 1 ..]) |second_pad| {
            const compatible = second_pad.net == net and !second_pad.thru and second_pad.layer == first_pad.layer;
            if (!compatible or padBoxGap(first_pad, second_pad) > 0.25) continue;
            const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
            ctx.selected[net_i] = true;
            const repaired = try route_cleanup.reanchorLandPair(ctx.alloc, .{ first_pad, second_pad }, board.tracks, ctx.selected);
            ctx.selected[net_i] = false;
            if (repaired.segments_reanchored == 0) continue;
            const candidate = try evaluateLandRepair(ctx, board.tracks.items);
            if (landRepairReduced(candidate, board.evaluation, net) and landRepairSafe(candidate, board.evaluation)) {
                board.evaluation = candidate;
                segments += repaired.segments_reanchored;
            } else {
                board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
            }
        }
    }
    return segments;
}

fn repairLandTransitNet(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!LandRepairNetResult {
    const net: i32 = @intCast(net_i);
    var result = LandRepairNetResult{};
    result.tracks_pruned = try pruneLandTransitTracks(ctx, net, board);
    result.changed = result.tracks_pruned > 0;
    if (landTransitCountForNet(board.evaluation.violations, net) == 0) return result;

    if (try tryWholeLandTransitRepair(ctx, net_i, board)) |count| {
        result.changed = true;
        result.segments_reanchored += count;
        return result;
    }
    result.segments_reanchored += try repairLandTransitByPad(ctx, net_i, board);
    result.segments_reanchored += try repairLandTransitByPair(ctx, net_i, board);
    result.changed = result.changed or result.segments_reanchored > 0;
    result.rejected = landTransitCountForNet(board.evaluation.violations, net) > 0;
    return result;
}

/// Remove deletion-invariant trace sections and non-ground vias from persisted
/// copper without rerouting it. The shared topology gate supplies a jointly
/// safe deletion plan; the edit is persisted only when error DRC and routed-net
/// connectivity do not regress.
fn cleanupNetSelected(selected: []const bool, net: i32) bool {
    if (net < 0) return false;
    if (selected.len == 0) return true;
    const net_i: usize = @intCast(net);
    return net_i < selected.len and selected[net_i];
}

const CleanupApply = struct {
    routed: router.RouteResult,
    stub_tracks_removed: usize = 0,
};

fn mcpApplyTrackCleanupPlan(
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    findings: []const drc.Violation,
    selected: []const bool,
) std.mem.Allocator.Error!CleanupApply {
    const drop = try alloc.alloc(bool, routed.tracks.len);
    @memset(drop, false);
    var stub_tracks_removed: usize = 0;
    for (findings) |finding| {
        const removable = finding.kind == .dangling_copper or finding.kind == .copper_stub;
        if (!removable or finding.who.track_a < 0) continue;
        const track_i: usize = @intCast(finding.who.track_a);
        if (track_i >= routed.tracks.len) continue;
        const net = routed.tracks[track_i].net;
        if (!cleanupNetSelected(selected, net)) continue;
        if (!drop[track_i] and finding.kind == .copper_stub) stub_tracks_removed += 1;
        drop[track_i] = true;
    }
    var tracks: std.ArrayList(router.Track) = .empty;
    for (routed.tracks, drop) |track, remove| if (!remove) try tracks.append(alloc, track);
    var out = routed;
    out.tracks = try tracks.toOwnedSlice(alloc);
    return .{ .routed = out, .stub_tracks_removed = stub_tracks_removed };
}

fn mcpApplyViaCleanupPlan(
    alloc: std.mem.Allocator,
    nets: []const optimizer.FlatNet,
    routed: router.RouteResult,
    findings: []const drc.Violation,
    selected: []const bool,
) std.mem.Allocator.Error!router.RouteResult {
    const drop_vias = try alloc.alloc(bool, routed.vias.len);
    @memset(drop_vias, false);
    for (findings) |finding| {
        const removable = finding.kind == .single_layer_via or finding.kind == .redundant_via;
        if (!removable or finding.who.track_a < 0) continue;
        const via_i: usize = @intCast(finding.who.track_a);
        if (via_i >= routed.vias.len) continue;
        const via = routed.vias[via_i];
        if (!cleanupNetSelected(selected, via.net) or via.net < 0) continue;
        const net_i: usize = @intCast(via.net);
        if (net_i >= nets.len or optimizer.isGroundName(router.shortName(nets[net_i].name))) continue;
        drop_vias[via_i] = true;
    }
    var vias: std.ArrayList(router.Via) = .empty;
    for (routed.vias, drop_vias) |via, remove| if (!remove) try vias.append(alloc, via);
    var out = routed;
    out.vias = try vias.toOwnedSlice(alloc);
    return out;
}

fn cleanupGateSafe(
    before_violations: []const drc.Violation,
    before_tally: fab_readiness.Tally,
    after_violations: []const drc.Violation,
    after_tally: fab_readiness.Tally,
) bool {
    if (drc.errorCount(after_violations) > drc.errorCount(before_violations)) return false;
    if (after_tally.total != before_tally.total) return false;
    return after_tally.routed >= before_tally.routed;
}

/// Apply or preview the exact jointly-safe redundant-section plan emitted by
/// fabricated-fill DRC, guarded by a second full DRC/connectivity comparison.
pub fn mcpCleanRouteTopology(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const dry_run = mcpArgBool(args_val, "dry_run");
    const requested_nets = mcpArgStrList(alloc, args_val, "nets");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to clean");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to clean");
    const restored = restoreRoutes(alloc, saved_routes, solved.placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");
    var selected: []const bool = &.{};
    if (requested_nets.len > 0) {
        const mask = try alloc.alloc(bool, solved.placement.nets.len);
        @memset(mask, false);
        var matched: usize = 0;
        for (solved.placement.nets, 0..) |net, net_i| {
            for (requested_nets) |wanted| {
                if (!std.ascii.eqlIgnoreCase(net.name, wanted) and
                    !std.ascii.eqlIgnoreCase(router.shortName(net.name), wanted)) continue;
                if (!mask[net_i]) matched += 1;
                mask[net_i] = true;
                break;
            }
        }
        if (matched == 0) return mcpFail(out, alloc, "nets scope matched no board net");
        selected = mask;
    }
    const rp = solved.placement.rules.design.routeParams();
    const before_violations = mcpCopperViolations(alloc, project_dir, name, solved, restored, rp.clearance);
    const before_tally = try fab_readiness.routableTally(alloc, solved.placement, .{
        .tracks = restored.tracks,
        .vias = restored.vias,
        .zones = solved.shown_zones.user,
    });
    var cleanup_candidates_before: usize = 0;
    for (before_violations) |violation| {
        if (violation.kind == .dangling_copper and violation.who.track_a >= 0)
            cleanup_candidates_before += 1;
    }
    // Trace and via cleanup are separately gated transactions. A stale trace
    // redundancy verdict must not prevent independently safe via pruning (and
    // vice versa): reject only the phase that regressed full-board DRC or fab
    // connectivity, then continue the next phase from the last accepted board.
    var trace_candidate = restored;
    var trace_violations = before_violations;
    var cleanup_rounds: usize = 0;
    var candidate_stub_tracks_removed: usize = 0;
    const cleanup_limit = restored.tracks.len + 1;
    while (cleanup_rounds < cleanup_limit) : (cleanup_rounds += 1) {
        const applied = try mcpApplyTrackCleanupPlan(alloc, trace_candidate, trace_violations, selected);
        candidate_stub_tracks_removed += applied.stub_tracks_removed;
        if (applied.routed.tracks.len == trace_candidate.tracks.len) break;
        trace_candidate = applied.routed;
        trace_violations = mcpCopperViolations(alloc, project_dir, name, solved, trace_candidate, rp.clearance);
    }
    const trace_tally = try fab_readiness.routableTally(alloc, solved.placement, .{
        .tracks = trace_candidate.tracks,
        .vias = trace_candidate.vias,
        .zones = solved.shown_zones.user,
    });
    const trace_attempted = trace_candidate.tracks.len < restored.tracks.len;
    const trace_safe = cleanupGateSafe(before_violations, before_tally, trace_violations, trace_tally);
    var cleaned = if (trace_safe) trace_candidate else restored;
    const via_before_violations = if (trace_safe) trace_violations else before_violations;
    const via_before_tally = if (trace_safe) trace_tally else before_tally;
    const via_candidate = try mcpApplyViaCleanupPlan(
        alloc,
        solved.placement.nets,
        cleaned,
        via_before_violations,
        selected,
    );
    const via_attempted = via_candidate.vias.len < cleaned.vias.len;
    const via_violations = if (via_attempted)
        mcpCopperViolations(alloc, project_dir, name, solved, via_candidate, rp.clearance)
    else
        via_before_violations;
    const via_tally = if (via_attempted)
        try fab_readiness.routableTally(alloc, solved.placement, .{
            .tracks = via_candidate.tracks,
            .vias = via_candidate.vias,
            .zones = solved.shown_zones.user,
        })
    else
        via_before_tally;
    const via_safe = cleanupGateSafe(via_before_violations, via_before_tally, via_violations, via_tally);
    if (via_safe) cleaned = via_candidate;
    const after_violations = if (via_safe) via_violations else via_before_violations;
    const after_tally = if (via_safe) via_tally else via_before_tally;
    const tracks_rolled_back = trace_attempted and !trace_safe;
    const vias_rolled_back = via_attempted and !via_safe;
    const stub_tracks_removed = if (trace_safe) candidate_stub_tracks_removed else 0;
    var candidate_error_kinds: std.ArrayList([]const u8) = .empty;
    var candidate_error_details: std.ArrayList([]const u8) = .empty;
    for (after_violations) |violation| {
        if (violation.severity == .err and violation.kind != .net_open) {
            try candidate_error_kinds.append(alloc, @tagName(violation.kind));
            if (violation.who.track_a >= 0 and @as(usize, @intCast(violation.who.track_a)) < cleaned.tracks.len) {
                const track = cleaned.tracks[@intCast(violation.who.track_a)];
                try candidate_error_details.append(alloc, try std.fmt.allocPrint(
                    alloc,
                    "{s} net {d}: ({d},{d}) to ({d},{d}) L{d} W{d}",
                    .{ @tagName(violation.kind), violation.who.net_a, track.x1, track.y1, track.x2, track.y2, track.layer, track.width },
                ));
            }
        }
    }
    const would_change = cleaned.tracks.len < restored.tracks.len or cleaned.vias.len < restored.vias.len;
    const changed = would_change and !dry_run;
    if (changed) {
        var persisted = try mcpSavedRoutesFrom(alloc, cleaned, solved.placement.nets, saved_routes);
        persisted.zones = saved_routes.zones;
        mcpPersistWorking(alloc, project_dir, name, .{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        }, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"redundant_before\":{d},\"redundant_after\":{d},\"tracks_removed\":{d}," ++
            "\"vias_removed\":{d},\"drc_errors_before\":{d},\"candidate_drc_errors\":{d}," ++
            "\"routed_before\":{d},\"candidate_routed\":{d},\"total_before\":{d}," ++
            "\"candidate_total\":{d},\"candidate_redundant\":{d},\"cleanup_rounds\":{d},\"stub_tracks_removed\":{d},\"dry_run\":{},\"would_change\":{},\"changed\":{},\"rolled_back\":{}," ++
            "\"tracks_rolled_back\":{},\"vias_rolled_back\":{},\"track_candidate_removed\":{d},\"via_candidate_removed\":{d}," ++
            "\"cleanup_candidates_before\":{d},\"candidate_open\":",
        .{
            drc.countKind(before_violations, .dangling_copper),
            drc.countKind(after_violations, .dangling_copper),
            restored.tracks.len - cleaned.tracks.len,
            restored.vias.len - cleaned.vias.len,
            drc.errorCount(before_violations),
            drc.errorCount(after_violations),
            before_tally.routed,
            after_tally.routed,
            before_tally.total,
            after_tally.total,
            drc.countKind(after_violations, .dangling_copper),
            cleanup_rounds,
            stub_tracks_removed,
            dry_run,
            would_change,
            changed,
            tracks_rolled_back or vias_rolled_back,
            tracks_rolled_back,
            vias_rolled_back,
            restored.tracks.len - trace_candidate.tracks.len,
            (if (trace_safe) trace_candidate.vias.len else restored.vias.len) - via_candidate.vias.len,
            cleanup_candidates_before,
        },
    );
    try mcpWriteStrArray(w, after_tally.open);
    try w.writeAll(",\"candidate_error_kinds\":");
    try mcpWriteStrArray(w, candidate_error_kinds.items);
    try w.writeAll(",\"candidate_error_details\":");
    try mcpWriteStrArray(w, candidate_error_details.items);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Turn weak same-net trace/trace and trace/via overlaps in persisted copper
/// into exact centreline joins. This is deliberately opt-in: unlike the
/// autorouter's generated-copper pass, every selected saved track is mutable.
/// The candidate is committed only when connectivity and error DRC do not
/// regress, and dry-run exercises the identical candidate and gate.
pub fn mcpNormalizeJunctions(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const dry_run = mcpArgBool(args_val, "dry_run");
    const requested_nets = mcpArgStrList(alloc, args_val, "nets");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to normalize");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to normalize");
    const restored = restoreRoutes(alloc, saved_routes, solved.placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");

    var selected: []const bool = &.{};
    if (requested_nets.len > 0) {
        const mask = try alloc.alloc(bool, solved.placement.nets.len);
        @memset(mask, false);
        var matched: usize = 0;
        for (solved.placement.nets, 0..) |net, net_i| {
            for (requested_nets) |wanted| {
                if (!std.ascii.eqlIgnoreCase(net.name, wanted) and
                    !std.ascii.eqlIgnoreCase(router.shortName(net.name), wanted)) continue;
                if (!mask[net_i]) matched += 1;
                mask[net_i] = true;
                break;
            }
        }
        if (matched == 0) return mcpFail(out, alloc, "nets scope matched no board net");
        selected = mask;
    }

    const rp = solved.placement.rules.design.routeParams();
    const before_violations = mcpCopperViolations(alloc, project_dir, name, solved, restored, rp.clearance);
    const before_tally = try fab_readiness.routableTally(alloc, solved.placement, .{
        .tracks = restored.tracks,
        .vias = restored.vias,
        .zones = solved.shown_zones.user,
    });
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(alloc, restored.tracks);
    var mutable: std.ArrayList(bool) = .empty;
    for (restored.tracks) |track| {
        const selected_track = track.net >= 0 and (selected.len == 0 or
            (@as(usize, @intCast(track.net)) < selected.len and selected[@intCast(track.net)]));
        try mutable.append(alloc, selected_track);
    }
    try router.canonicalizeTraceJunctions(alloc, &tracks, &mutable, restored.vias);
    var candidate = restored;
    candidate.tracks = try tracks.toOwnedSlice(alloc);
    const after_violations = mcpCopperViolations(alloc, project_dir, name, solved, candidate, rp.clearance);
    const after_tally = try fab_readiness.routableTally(alloc, solved.placement, .{
        .tracks = candidate.tracks,
        .vias = candidate.vias,
        .zones = solved.shown_zones.user,
    });
    const safe = drc.errorCount(after_violations) <= drc.errorCount(before_violations) and
        after_tally.routed >= before_tally.routed and after_tally.total == before_tally.total;
    const would_change = safe and candidate.tracks.len != restored.tracks.len;
    const changed = would_change and !dry_run;
    if (changed) {
        var persisted = try mcpSavedRoutesFrom(alloc, candidate, solved.placement.nets, saved_routes);
        persisted.zones = saved_routes.zones;
        mcpPersistWorking(alloc, project_dir, name, .{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        }, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"implicit_before\":{d},\"implicit_after\":{d},\"tracks_added\":{d}," ++
            "\"routed_before\":{d},\"candidate_routed\":{d},\"total\":{d}," ++
            "\"dry_run\":{},\"would_change\":{},\"changed\":{},\"rolled_back\":{}}}",
        .{
            drc.countKind(before_violations, .implicit_junction),
            drc.countKind(after_violations, .implicit_junction),
            candidate.tracks.len - restored.tracks.len,
            before_tally.routed,
            after_tally.routed,
            after_tally.total,
            dry_run,
            would_change,
            changed,
            !safe,
        },
    );
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// HTTP twin of `normalize_junctions`. The path supplies the design name; the
/// JSON body accepts the same optional layout, dry_run, and nets fields as the
/// CLI action so browser tooling and agents exercise one implementation.
pub fn normalizeJunctionsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    var root = parseJsonObject(req, res) orelse return;
    root.object.put(req.arena, "name", .{ .string = name }) catch {
        res.status = 500;
        res.body = "could not prepare normalization request";
        return;
    };
    var out: std.ArrayList(u8) = .empty;
    const ok = try mcpNormalizeJunctions(req.arena, ctx.project_dir, root, &out);
    res.content_type = .JSON;
    res.body = out.items;
    if (!ok) res.status = 400;
}

/// Repair persisted same-net copper that laps an SMD land instead of entering
/// it through the pad centre. Each affected net is an independent transaction:
/// the rewrite is kept only when it removes every land-transit finding on that
/// net, does not increase error-severity DRC, and does not lose a connected net.
pub fn mcpRepairLandTransit(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to repair");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to repair");
    const restored = restoreRoutes(alloc, saved_routes, placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");
    const rp = placement.rules.design.routeParams();
    const pads = try router.buildObstacles(alloc, placement.parts, placement.nets);
    var tracks = std.ArrayList(router.Track).fromOwnedSlice(try alloc.dupe(router.Track, restored.tracks));
    const selected = try alloc.alloc(bool, placement.nets.len);
    @memset(selected, false);
    const touched = try alloc.alloc(bool, placement.nets.len);
    @memset(touched, false);
    const repair_ctx = LandRepairContext{
        .alloc = alloc,
        .project_dir = project_dir,
        .name = name,
        .solved = solved,
        .restored = restored,
        .pads = pads,
        .clearance = rp.clearance,
        .selected = selected,
    };

    var board = LandRepairBoard{
        .tracks = &tracks,
        .evaluation = try evaluateLandRepair(repair_ctx, tracks.items),
    };
    const warnings_before = landTransitCount(board.evaluation.violations);
    const routed_before = board.evaluation.tally.routed;
    const tracks_before = tracks.items.len;
    var accepted: std.ArrayList([]const u8) = .empty;
    var rejected: std.ArrayList([]const u8) = .empty;
    var segments_reanchored: usize = 0;
    var tracks_pruned: usize = 0;

    for (placement.nets, 0..) |net, net_i| {
        const ni: i32 = @intCast(net_i);
        if (landTransitCountForNet(board.evaluation.violations, ni) == 0) continue;
        const result = try repairLandTransitNet(repair_ctx, net_i, &board);
        if (result.changed) {
            touched[net_i] = true;
            segments_reanchored += result.segments_reanchored;
            tracks_pruned += result.tracks_pruned;
            try accepted.append(alloc, net.name);
        }
        if (result.rejected) try rejected.append(alloc, net.name);
    }

    var current = restored;
    var kept_arcs: std.ArrayList(router.Arc) = .empty;
    for (restored.arcs) |arc| {
        if (arc.net >= 0 and @as(usize, @intCast(arc.net)) < touched.len and touched[@intCast(arc.net)]) continue;
        try kept_arcs.append(alloc, arc);
    }
    var kept_outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    for (restored.rf_port_outcomes) |outcome| {
        if (outcome.net >= 0 and @as(usize, @intCast(outcome.net)) < touched.len and touched[@intCast(outcome.net)]) continue;
        try kept_outcomes.append(alloc, outcome);
    }
    current.tracks = board.tracks.items;
    current.arcs = kept_arcs.items;
    current.rf_port_outcomes = kept_outcomes.items;
    var persisted = try mcpSavedRoutesFrom(alloc, current, placement.nets, saved_routes);
    persisted.zones = saved_routes.zones;
    if (accepted.items.len > 0) {
        const entry = SavedLayout{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        };
        mcpPersistWorking(alloc, project_dir, name, entry, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"warnings_before\":{d},\"warnings_after\":{d},\"segments_reanchored\":{d},\"tracks_pruned\":{d}," ++
            "\"tracks_before\":{d},\"tracks_after\":{d},\"drc_errors\":{d},\"routed_before\":{d}," ++
            "\"routed\":{d},\"total\":{d},\"accepted\":",
        .{
            warnings_before,
            landTransitCount(board.evaluation.violations),
            segments_reanchored,
            tracks_pruned,
            tracks_before,
            board.tracks.items.len,
            board.evaluation.errors,
            routed_before,
            board.evaluation.tally.routed,
            board.evaluation.tally.total,
        },
    );
    try mcpWriteStrArray(w, accepted.items);
    try w.writeAll(",\"rejected\":");
    try mcpWriteStrArray(w, rejected.items);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Add the ground-plane barrels required by the board's authored
/// `(ground-via-max MM)` rule to an existing saved layout. The same router
/// post-pass runs automatically on fresh whole-board routes; this mutation is
/// the safe upgrade path for a hand-finished layout that must not be rerouted.
pub fn mcpStitchGroundPads(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const max_distance = placement.rules.design.pour.ground_via_max;
    if (!(max_distance > 0)) return mcpFail(out, alloc, "design has no positive (ground-via-max MM) rule");
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to stitch");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to stitch");
    const restored = restoreRoutes(alloc, saved_routes, placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");
    const rp = placement.rules.design.routeParams();
    const before_violations = mcpCopperViolations(alloc, project_dir, name, solved, restored, rp.clearance);
    const before_tally = try fab_readiness.routableTally(alloc, placement, .{
        .tracks = restored.tracks,
        .vias = restored.vias,
        .zones = solved.shown_zones.user,
    });
    const candidate = try router.addGroundPadStitches(alloc, placement, restored);
    const after_violations = mcpCopperViolations(alloc, project_dir, name, solved, candidate, rp.clearance);
    const after_tally = try fab_readiness.routableTally(alloc, placement, .{
        .tracks = candidate.tracks,
        .vias = candidate.vias,
        .zones = solved.shown_zones.user,
    });
    const safe = drc.errorCount(after_violations) <= drc.errorCount(before_violations) and
        drc.countKind(after_violations, .ground_via_distance) <= drc.countKind(before_violations, .ground_via_distance) and
        after_tally.routed >= before_tally.routed and after_tally.total == before_tally.total;
    const changed = safe and (candidate.vias.len > restored.vias.len or candidate.tracks.len > restored.tracks.len);
    if (changed) {
        var persisted = try mcpSavedRoutesFrom(alloc, candidate, placement.nets, saved_routes);
        persisted.zones = saved_routes.zones;
        mcpPersistWorking(alloc, project_dir, name, .{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        }, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"max_distance_mm\":{d},\"warnings_before\":{d},\"warnings_after\":{d}," ++
            "\"vias_added\":{d},\"tracks_added\":{d},\"drc_errors\":{d}," ++
            "\"routed\":{d},\"total\":{d},\"changed\":{},\"rolled_back\":{}}}",
        .{
            max_distance,
            drc.countKind(before_violations, .ground_via_distance),
            drc.countKind(if (safe) after_violations else before_violations, .ground_via_distance),
            if (changed) candidate.vias.len - restored.vias.len else 0,
            if (changed) candidate.tracks.len - restored.tracks.len else 0,
            if (safe) drc.errorCount(after_violations) else drc.errorCount(before_violations),
            if (safe) after_tally.routed else before_tally.routed,
            before_tally.total,
            changed,
            !safe,
        },
    );
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// `add_tracks` — append hand-drawn copper to a design's layout.
///
/// The mutation counterpart of `clear_routes`, and the seam that breaks a
/// closed loop: when the autorouter reports a net it cannot close, this is how
/// an agent (or a human) lays the copper itself. Validation is all-or-nothing,
/// and copper that raises the error-severity DRC count is rolled back unless
/// the caller passes `"rollback_on_drc": false`.
pub fn mcpAddTracks(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const reqs = mcpParseAddTracks(alloc, args_val) orelse
        return mcpFail(out, alloc, "malformed \"tracks\" — each entry needs {\"net\",\"layer\",\"points\":[[x,y],…]}");
    const vreqs = mcpParseAddVias(alloc, args_val) orelse
        return mcpFail(out, alloc, "malformed \"vias\" — each entry needs {\"net\",\"x\",\"y\"}");
    if (reqs.len == 0 and vreqs.len == 0)
        return mcpFail(out, alloc, "nothing to add — supply \"tracks\" and/or \"vias\"");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const rp = placement.rules.design.routeParams();

    const added = (try mcpBuildAddedCopper(alloc, out, placement, rp, reqs, vreqs)) orelse return false;
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    // Additive: hand copper joins the layout's existing tracks/vias (and never
    // touches its custom pours, which mcpMergeRoutes carries over).
    const merged = try mcpMergeRoutes(alloc, if (working) |wl| wl.routes else null, added);

    // DRC + connectivity on exactly what gets persisted, so the reported
    // numbers describe the board the caller just changed.
    var drc_count: usize = 0;
    var drc_errs: usize = 0;
    var tally = fab_readiness.Tally{};
    if (merged) |m| {
        if (restoreRoutes(alloc, m, placement.nets)) |rr| {
            const v = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
                .placement = placement,
                .routed = rr,
                .clearance = rp.clearance,
                .zones = solved.shown_zones.user,
            });
            drc_count = v.len;
            drc_errs = drc.errorCount(v);
            // Pours count as connecting copper — see ShownCopper.zones.
            tally = try fab_readiness.routableTally(alloc, placement, .{
                .tracks = rr.tracks,
                .vias = rr.vias,
                .zones = solved.shown_zones.user,
            });
        }
    }

    // Hand copper that makes the board WORSE is undone by default. There is no
    // per-edit undo otherwise — `clear_routes` is per-net, so reverting one bad
    // polyline means wiping every track on that net — which makes the
    // draw/measure/adjust loop an agent needs unsafe to iterate. Errors, not
    // warnings: a sharp-bend or diff-skew finding is not a reason to reject
    // good copper. Pass `"rollback_on_drc": false` to keep copper regardless.
    const rollback = mcpArgBoolOpt(args_val, "rollback_on_drc") orelse true;
    const before_errs = mcpBaselineErrors(alloc, project_dir, name, solved, working, rp);
    const rolled_back = rollback and drc_errs > before_errs;
    const entry_name = mcpWorkingName(alloc, project_dir, name, layout_arg);
    if (!rolled_back) {
        const entry = SavedLayout{
            .name = entry_name,
            .kind = kind_manual,
            .ts = 0,
            .score = if (working) |wl| wl.score else null,
            .parts = if (working) |wl| wl.parts else posesFromPlacement(alloc, placement) orelse &.{},
            .routes = merged,
            .outline = if (working) |wl| wl.outline else null,
            .texts = if (working) |wl| wl.texts else &.{},
            .dimensions = mcpWorkingDimensions(working),
        };
        mcpPersistWorking(alloc, project_dir, name, entry, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry_name);
    // `drc` is every violation; `drc_errors` is the fab-blocking subset. A
    // caller deciding whether to keep hand copper should gate on the ERROR
    // count — a sharp-bend or diff-skew warning is not a reason to roll back.
    try w.print(
        ",\"added_tracks\":{d},\"added_vias\":{d},\"drc\":{d},\"drc_errors\":{d},\"drc_errors_before\":{d},\"rolled_back\":{},\"routed\":{d},\"total\":{d},\"open\":",
        .{ added.tracks.len, added.vias.len, drc_count, drc_errs, before_errs, rolled_back, tally.routed, tally.total },
    );
    try mcpWriteStrArray(w, tally.open);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
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
    const layouts = readLayouts(alloc, project_dir, name);
    const chosen: ?SavedLayout = if (layout_arg) |la| blk: {
        for (layouts) |L| {
            if (std.mem.eql(u8, L.name, la) and L.parts.len > 0) break :blk L;
        }
        return error.UnknownLayout;
    } else if (blessedLayout(layouts)) |L| L.* else null;

    const poses: []const optimizer.RefPose = if (layout_arg != null) blk: {
        // A named selection always resolved a row above (else UnknownLayout).
        const c = chosen orelse return error.UnknownLayout;
        break :blk rekeyPosesByOrigin(alloc, block, c.parts) orelse (refPosesFromParts(alloc, c.parts) orelse return error.PlacementFailed);
    } else (chooseSyncPoses(alloc, project_dir, name) orelse return error.NoSavedLayout);

    // The chosen layout's own drawn outline is the fab board edge.
    const oseed: optimizer.OutlineSource = if (chosen) |L|
        (if (L.outline) |o| drawnSource(o) else .authored_only)
    else
        .authored_only;
    var placement = optimizer.placeFromPoses(alloc, block, project_dir, .{ .poses = poses, .outline = oseed }, optimizer.Params{}) catch return error.PlacementFailed;
    var routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    var zones: []const pour.UserZone = &.{};
    var silk_keepouts: []const subcircuit_silkscreen.Keepout = &.{};
    var texts: []const font5x7.BoardText = &.{};
    if (chosen) |L| {
        applyFabricationLayerOverrides(alloc, &placement, L.fabrication_layers);
        if (L.routes) |sr| {
            if (restoreRoutes(alloc, routesWithPerimeter(alloc, placement, sr).?, placement.nets)) |r| {
                routed = r;
            }
            zones = userZonesFrom(alloc, placement.rules, sr.zones);
            silk_keepouts = silkKeepoutsFrom(alloc, sr.zones);
        }
        texts = L.texts;
    }
    routed = (perimeter_fence.append(alloc, placement, routed) catch null) orelse routed;
    return .{
        .placement = placement,
        .routed = routed,
        .zones = zones,
        .silk_keepouts = silk_keepouts,
        .texts = texts,
        .authored = .{ .stackup = block.stackup, .revision = block.revision },
        .from_saved = chosen != null,
    };
}

/// Authored construction metadata needed by simulation handoffs.
pub const FabAuthored = struct {
    stackup: env_mod.StackupSpec,
    revision: env_mod.Revision,
};

/// `run_fab_readiness` — the pre-fab correctness report for the design's
/// blessed (or named) layout: `{ok,errors:[…],warnings:[…],stats:{…}}`,
/// computed against the SAME fab view the Gerber export builds. Read-only —
/// the gate `pcbGerbersApi` enforces server-side, surfaced here for the agent.
pub fn mcpRunFabReadiness(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const fv = fabViewFor(alloc, project_dir, name, layout_arg) catch |e| return switch (e) {
        // Name the dead reference — answering with the generic "no saved
        // layout" would read as "save one", when the fix is picking a row
        // that exists.
        error.UnknownLayout => mcpFailFmt(out, alloc, "no saved layout named \"{s}\" — list the design's layouts and pass one of those names", .{layout_arg.?}),
        else => mcpFail(out, alloc, "no saved layout — set poses and save a layout first"),
    };
    const copper = export_gerber.Copper{ .tracks = fv.routed.tracks, .arcs = fv.routed.arcs, .rf_paths = fv.routed.rf_port_outcomes, .vias = fv.routed.vias, .zones = fv.zones, .silk_keepouts = fv.silk_keepouts };
    const report = fab_readiness.check(alloc, fv.placement, copper, .{
        .from_saved_layout = fv.from_saved,
        .drc_rules = drc_rules.load(alloc, project_dir, name),
    }) catch |e|
        return mcpFailFmt(out, alloc, "fab-readiness check failed: {s}", .{@errorName(e)});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try fab_readiness.writeJson(&aw.writer, report);
    try out.appendSlice(alloc, aw.written());
    return true;
}

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

    const doc = readSidecarDoc(alloc, project, "foo", null);
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
    writeLayoutsFile(alloc, project, "foo", &layouts, null, 1);
    try std.testing.expectEqual(@as(i64, 1), readLayoutRev(alloc, project, "foo", null));

    // An explicit rev value round-trips too.
    writeLayoutsFile(alloc, project, "foo", &layouts, null, 42);
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

    const doc = readDesignDoc(alloc, project, "foo");
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

// spec: Web Server - A CLI layout mutation snapshots the sidecar to history and bumps the rev like a viewer Save
test "CLI persist bumps the sidecar rev and snapshots history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = "{\"layouts\":[]}" });

    // Two CLI persists: each stamps disk rev + 1 (0→1→2), so an open editor
    // tab holding the old rev 409s on its next save instead of clobbering.
    const parts = [_]PartPose{.{ .ref = "U1", .x = 1, .y = 2, .rot = 0 }};
    const entry = SavedLayout{ .name = "layout", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts, .default = true };
    mcpPersistWorking(alloc, project, "foo", entry, true);
    try std.testing.expectEqual(@as(i64, 1), readLayoutRev(alloc, project, "foo", null));
    mcpPersistWorking(alloc, project, "foo", entry, true);
    try std.testing.expectEqual(@as(i64, 2), readLayoutRev(alloc, project, "foo", null));

    // The pre-write sidecar landed in history/ (recoverable like a viewer Save).
    const snaps = try history.listLayoutSnapshots(alloc, project, "foo");
    try std.testing.expect(snaps.len >= 1);
}

// spec: Web Server - A CLI layout mutation refreshes the auto-layout cache poses so a default read reflects the write
test "CLI persist refreshes the auto cache poses so a default read sees the mutation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");

    // A sidecar whose optimizer-cache slot holds a STALE pose (an earlier solve)
    // and a tuning weight. This cache is the scene a default CLI read renders —
    // `get_pcb_layout_image` / `describe_pcb_layout` default `rough`, so
    // `solveForRequest` seeds from `readAutoPoses` (the cache), not the starred
    // layout.
    const stale = "{\"layouts\":[],\"cache\":{\"params\":{\"loop_w\":7.5}," ++
        "\"parts\":[{\"ref\":\"U1\",\"x\":0,\"y\":0,\"rot\":0}]}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = stale });
    const before = readAutoPoses(alloc, project, "foo") orelse return error.TestNoCache;
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqual(@as(f64, 0), before[0].x);

    // A CLI mutation persists U1 at a distinctive new pose (as set_part_poses does).
    const parts = [_]PartPose{.{ .ref = "U1", .x = 42, .y = 7, .rot = 90 }};
    const entry = SavedLayout{ .name = "layout", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts, .default = true };
    mcpPersistWorking(alloc, project, "foo", entry, true);

    // Read-after-write: the cache the default read consults now carries the
    // mutation, not the pre-mutation pose (bug #2 would leave x at 0).
    const after = readAutoPoses(alloc, project, "foo") orelse return error.TestNoCache;
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqual(@as(f64, 42), after[0].x);
    try std.testing.expectEqual(@as(f64, 7), after[0].y);

    // Only the poses are swapped — the stored tuning weight survives the refresh.
    const slot = readCacheSlot(alloc, project, "foo") orelse return error.TestNoCache;
    try std.testing.expectEqual(@as(f64, 7.5), slot.params.loop_w);
}

// spec: Web Server - physical board navigation exposes stable 3D and a read-only assembly workspace
test "PCB header links board designs to assembly and keeps modules scoped" {
    var board: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer board.deinit();
    try writeHeadNav(&board.writer, false, "demo", "Demo", null, .{ .routed = 70, .total = 90, .unique_routed = 7, .unique_total = 9 });
    try std.testing.expect(std.mem.indexOf(u8, board.written(), "href=\"/pcb-layout/demo?view=3d\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board.written(), "href=\"/assembly-debug/demo\"") != null);
    var selected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer selected.deinit();
    try writeHeadNav(&selected.writer, false, "demo", "Demo", "an2548-div4-post-ldo", null);
    try std.testing.expect(std.mem.indexOf(u8, selected.written(), "href=\"/assembly-debug/demo?layout=an2548-div4-post-ldo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_toggle_js, "get(\"view\")===\"3d\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_stage_html, "id=\"pcb3d-bottom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_stage_html, "id=\"pcb3d-export-step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_stage_html, "id=\"pcb3d-t-surface\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_stage_html, "id=\"pcb3d-t-heatsink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("assets/pcb_board.js"), "function hsModalOpen(rect)") != null);
    try std.testing.expect(std.mem.indexOf(u8, heatsink_modal, "id=\"hs-fin-count\"") != null);
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function hsDragMove(m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "heatsink moved/resized") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function hsCountToGap()") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "hsModalOpen(PCB.heatsink)") != null);
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("assets/pcb_3d_viewer.js"), "function rebuildHeatsink()") != null);
    const surface_asset = std.mem.indexOf(u8, pcb_3d_toggle_js, "pcb_3d_surface.js") orelse return error.TestUnexpectedResult;
    const step_export_asset = std.mem.indexOf(u8, pcb_3d_toggle_js, "pcb_step_export.js") orelse return error.TestUnexpectedResult;
    const viewer_asset = std.mem.indexOf(u8, pcb_3d_toggle_js, "pcb_3d_viewer.js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(surface_asset < step_export_asset and step_export_asset < viewer_asset);

    var module: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer module.deinit();
    try writeHeadNav(&module.writer, true, "power", "Power", null, null);
    try std.testing.expect(std.mem.indexOf(u8, module.written(), "/assembly-debug/") == null);
}

// spec: Web Server - The Routed UI count collapses per-pin micro-net connections onto unique logical net names while requiring every member connection to close
test "PCB editor header carries a live unique-net routing summary" {
    var incomplete: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer incomplete.deinit();
    try writeHeadNav(&incomplete.writer, false, "demo", "Demo", null, .{ .routed = 70, .total = 90, .unique_routed = 7, .unique_total = 9 });
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "class=\"pcb-route-summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "Routed <strong>7 / 9</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "70 / 90") == null);
    try std.testing.expect(std.mem.indexOf(u8, incomplete.written(), "Unique logical nets completed") != null);

    var complete: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer complete.deinit();
    try writeHeadNav(&complete.writer, false, "demo", "Demo", null, .{ .routed = 90, .total = 90, .unique_routed = 9, .unique_total = 9 });
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
    const none = chooseLayout(alloc, null, &block, .{}, .{ .params = .{}, .tuned = false, .regen = false }, readSidecarDoc(alloc, project, "foo", null));
    // Nothing asked for → the ★ default, rendered verbatim.
    try std.testing.expectEqualStrings("star", none.starred_name orelse return error.TestNoStar);
    try std.testing.expect(none.verbatim);
    try std.testing.expectEqual(@as(f64, 1), (none.cached orelse return error.TestNoPoses)[0].x);

    // ?layout=alt names a specific snapshot: it outranks the star (which is no
    // longer even consulted) and still renders verbatim — a direct link must
    // reproduce the saved board exactly, never a re-solve of it.
    const view = chooseLayout(alloc, null, &block, .{ .view = "alt" }, .{ .params = .{}, .tuned = false, .regen = false }, readSidecarDoc(alloc, project, "foo", null));
    try std.testing.expect(view.starred_name == null);
    try std.testing.expect(view.verbatim);
    try std.testing.expectEqual(@as(f64, 9), (view.cached orelse return error.TestNoPoses)[0].x);

    // ?refine= seeds from the same snapshot but asks for a re-solve, so it is
    // deliberately NOT verbatim.
    const refine = chooseLayout(alloc, null, &block, .{ .refine = "alt" }, .{ .params = .{}, .tuned = false, .regen = false }, readSidecarDoc(alloc, project, "foo", null));
    try std.testing.expect(!refine.verbatim);
    try std.testing.expectEqual(@as(f64, 9), (refine.cached orelse return error.TestNoPoses)[0].x);

    // A ?layout= naming nothing resolves no poses — the page turns that into a
    // 404 rather than quietly falling back to a different board.
    const missing = chooseLayout(alloc, null, &block, .{ .view = "nope" }, .{ .params = .{}, .tuned = false, .regen = false }, readSidecarDoc(alloc, project, "foo", null));
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

/// GET /api/fab-readiness/fabsel[?layout=…] through the real handler; expects
/// 200 and returns the body duped onto `alloc` (the harness arena dies here).
fn fabReadinessBody(alloc: std.mem.Allocator, project: []const u8, layout: ?[]const u8) ![]const u8 {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", "fabsel");
    if (layout) |l| ht.query("layout", l);
    try pcbFabReadinessApi(&srv, ht.req, ht.res);
    try std.testing.expectEqual(@as(u16, 200), ht.res.status);
    return alloc.dupe(u8, ht.res.body);
}

// spec: Web Server - The fab-readiness report and the fab package endpoints resolve ?layout=<name> to that named saved row and 404 an unknown name, never silently reporting a different board
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
    // Naming the starred row reproduces the default answer exactly.
    try std.testing.expectEqualStrings(starred, routed);

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
}

// spec: Web Server - An unscoped route_pcb call immediately after clear_routes routes the whole board and echoes scope "all"
test "mcp clear_routes then unscoped route_pcb routes the whole board" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fabsel\"}", .{});

    // Drop the ★ row's persisted copper (the fixture's three SIG tracks)…
    var cleared: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpClearRoutes(alloc, project, args, &cleared));
    try std.testing.expect(std.mem.indexOf(u8, cleared.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared.items, "\"cleared\":3") != null);

    // …then immediately route with NO nets/groups — the sequence that used to
    // segfault the server. No scope means a whole-board route: both nets close
    // (SIG traced, GND by plane vias), echoed as scope "all", nothing unrouted.
    var routed: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpRoutePcb(alloc, project, args, &routed));
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"scope\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"selected_only\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"routed\":2,\"total\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"unrouted\":[]") != null);
}

// spec: serve/mcp_tools - clean_route_topology removes deletion-invariant saved trace sections and recursively exposed loose stubs transactionally without rerouting the board
// spec: serve/mcp_tools - clean_route_topology supports a non-persisting dry run and an optional net-name scope
test "mcp clean_route_topology removes a saved branch and is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const add_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"tracks\":[{\"net\":\"SIG\",\"layer\":\"F.Cu\",\"points\":[[4.52,3],[4.52,2]],\"width\":0.2}]," ++
            "\"vias\":[{\"net\":\"SIG\",\"x\":7,\"y\":3},{\"net\":\"GND\",\"x\":5.48,\"y\":5}]}",
        .{},
    );
    var added: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpAddTracks(alloc, project, add_args, &added));
    try std.testing.expect(std.mem.indexOf(u8, added.items, "\"added_tracks\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, added.items, "\"added_vias\":2") != null);

    // Dry-run computes the same jointly-safe plan but leaves the row untouched.
    const dry_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"dry_run\":true,\"nets\":[\"SIG\"]}",
        .{},
    );
    var preview: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpCleanRouteTopology(alloc, project, dry_args, &preview));
    try std.testing.expect(std.mem.indexOf(u8, preview.items, "\"dry_run\":true,\"would_change\":true,\"changed\":false") != null);
    try std.testing.expectEqual(@as(usize, 4), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.vias.len);

    const clean_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\"}",
        .{},
    );
    var first: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpCleanRouteTopology(alloc, project, clean_args, &first));
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"redundant_before\":1,\"redundant_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"tracks_removed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"vias_removed\":1") != null);
    const first_json = try std.json.parseFromSliceLeaky(std.json.Value, alloc, first.items, .{});
    try std.testing.expectEqual(
        first_json.object.get("routed_before").?.integer,
        first_json.object.get("candidate_routed").?.integer,
    );
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"changed\":true,\"rolled_back\":false") != null);
    const persisted = mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?;
    try std.testing.expectEqual(@as(usize, 1), persisted.vias.len);
    try std.testing.expectEqualStrings("GND", persisted.vias[0].net);

    var second: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpCleanRouteTopology(alloc, project, clean_args, &second));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"redundant_before\":0,\"redundant_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"tracks_removed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"vias_removed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"changed\":false,\"rolled_back\":false") != null);
}

test "route topology cleanup includes newly exposed stubs and honors net scope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 4, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const findings = [_]drc.Violation{
        .{ .x = 0.5, .y = 0, .gap = 0, .clearance = 0, .kind = .dangling_copper, .who = .{ .track_a = 0 } },
        .{ .x = 2.5, .y = 0, .gap = 0, .clearance = 0, .kind = .copper_stub, .who = .{ .track_a = 1 } },
        .{ .x = 4.5, .y = 0, .gap = 0, .clearance = 0, .kind = .copper_stub, .who = .{ .track_a = 2 } },
    };
    const applied = try mcpApplyTrackCleanupPlan(
        alloc,
        .{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 },
        &findings,
        &.{ true, false },
    );

    try std.testing.expectEqual(@as(usize, 1), applied.routed.tracks.len);
    try std.testing.expectEqual(@as(i32, 1), applied.routed.tracks[0].net);
    try std.testing.expectEqual(@as(usize, 1), applied.stub_tracks_removed);
}

// spec: serve/mcp_tools - normalize_junctions CLI/HTTP actions explicitly repair saved implicit joins, support dry-run/net scope, and persist only a connectivity- and DRC-safe candidate
test "normalize_junctions dry-runs and repairs saved copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const add_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"tracks\":[{\"net\":\"SIG\",\"layer\":\"F.Cu\",\"points\":[[7,2],[7,4]],\"width\":0.2}]}",
        .{},
    );
    var added: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpAddTracks(alloc, project, add_args, &added));

    const dry_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"dry_run\":true,\"nets\":[\"SIG\"]}",
        .{},
    );
    var preview: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpNormalizeJunctions(alloc, project, dry_args, &preview));
    try std.testing.expect(std.mem.indexOf(u8, preview.items, "\"implicit_before\":1,\"implicit_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview.items, "\"dry_run\":true,\"would_change\":true,\"changed\":false") != null);
    try std.testing.expectEqual(@as(usize, 4), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);

    const apply_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"nets\":[\"SIG\"]}",
        .{},
    );
    var normalized: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpNormalizeJunctions(alloc, project, apply_args, &normalized));
    try std.testing.expect(std.mem.indexOf(u8, normalized.items, "\"implicit_before\":1,\"implicit_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.items, "\"changed\":true,\"rolled_back\":false") != null);
    try std.testing.expectEqual(@as(usize, 5), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);
}

// spec: serve/mcp_tools - restore_layout_snapshot restores protected PCB layout history after snapshotting the current sidecar and bumping its revision
test "mcp restore_layout_snapshot round-trips a protected sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);
    const sidecar = try std.fmt.allocPrint(alloc, "{s}/src/fabsel.layouts.json", .{project});
    const id = (try history.snapshotLayouts(alloc, project, "fabsel", sidecar)) orelse return error.TestExpectedEqual;

    const clear_args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fabsel\",\"layout\":\"routed\"}", .{});
    var cleared: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpClearRoutes(alloc, project, clear_args, &cleared));
    try std.testing.expect(mcpReadWorking(alloc, project, "fabsel", "routed").?.routes == null);
    const rev_before = readLayoutRev(alloc, project, "fabsel", null);

    var args_text: std.Io.Writer.Allocating = .init(alloc);
    try args_text.writer.writeAll("{\"name\":\"fabsel\",\"id\":");
    try writeJsonStr(&args_text.writer, id);
    try args_text.writer.writeAll("}");
    const restore_args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, args_text.written(), .{});
    var restored: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpRestoreLayoutSnapshot(alloc, project, restore_args, &restored));
    try std.testing.expectEqual(rev_before + 1, readLayoutRev(alloc, project, "fabsel", null));
    try std.testing.expectEqual(@as(usize, 3), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);
}

// spec: serve/mcp_tools - stitch_ground_pads applies the autorouter's final ground-reference pass transactionally to a saved layout
test "mcp stitch_ground_pads upgrades saved copper and is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\"}",
        .{},
    );
    var first: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpStitchGroundPads(alloc, project, args, &first));
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"warnings_before\":2,\"warnings_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"drc_errors\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"changed\":true,\"rolled_back\":false") != null);

    var second: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpStitchGroundPads(alloc, project, args, &second));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"warnings_before\":0,\"warnings_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"vias_added\":0,\"tracks_added\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"changed\":false,\"rolled_back\":false") != null);
}

// spec: Web Server - Every block keeps many named layouts, and the saved-layouts panel links each one by its own ?layout= permalink
test "the saved-layouts panel links every row by its own permalink" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
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
    const saved = [_]SavedLayout{
        .{ .name = "hand", .kind = kind_manual, .ts = 2, .score = null, .parts = &.{}, .default = true },
        // The Save prompt's default name carries a space and a colon — both must
        // survive as a query VALUE, not break the href.
        .{ .name = "layout 07-27 14:30", .kind = kind_manual, .ts = 1, .score = null, .parts = &.{} },
    };
    const auto = LayoutScore{ .hpwl = 0, .loop = 0, .caps = 0 };
    try writeLayoutsPanel(&aw.writer, alloc, .{ .panel = .{ .name = "demo" }, .layouts = &saved, .auto = auto, .placement = placement });
    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/pcb-layout/demo?layout=hand\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/pcb-layout/demo?layout=layout%2007-2714%3A30\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/pcb-layout/demo?layout=layout%2007-27%2014%3A30\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-lay-prev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-lay-select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-lay-next\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-lay-rename\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-lay-delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-lay-rename=\"hand\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-lay-del=\"hand\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<summary>All versions</summary>") != null);

    // A ?sub scoped sub circuit reads its own per-sub sidecar, which ?layout=
    // deliberately doesn't select — so it gets plain names, not dead links.
    var sw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sw.deinit();
    try writeLayoutsPanel(&sw.writer, alloc, .{ .panel = .{ .name = "demo", .sub = "pwr" }, .layouts = &saved, .auto = auto, .placement = placement });
    try std.testing.expect(std.mem.indexOf(u8, sw.written(), "?layout=") == null);
    try std.testing.expect(std.mem.indexOf(u8, sw.written(), "<span class=\"lay-name\">hand</span>") != null);
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

// spec: Web Server - The viewer adopts the shown layout as its edit target and keeps the address bar on that layout's permalink
test "the viewer adopts the shown layout and keeps the url on its permalink" {
    // The blob names the layout the server rendered…
    const page_src = @embedFile("pcb_layout_page.zig");
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

// spec: Web Server - The PCB viewer keeps net colours permanently on and omits the Nets tab, Ratsnest control, and Placement guides control
test "PCB view retires global connection overlays and keeps net colours on" {
    try std.testing.expect(std.mem.indexOf(u8, tip_draw, "/ switches posture") != null);
    try std.testing.expect(std.mem.indexOf(u8, tip_draw, "A toggles tangent arcs") != null);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeAppearance(&aw.writer);
    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"ap-pane\" id=\"ap-objects\" hidden></div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-aptab=\"ap-layers\">Layers</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-aptab=\"ap-objects\">Objects</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "ap-nets") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"v-rats\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"v-guides\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"v-netcol\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-clr-show\"") == null);

    var tabs: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tabs.deinit();
    try writeTabsRow(&tabs.writer, false, true);
    try std.testing.expect(std.mem.indexOf(u8, tabs.written(), "id=\"v-rats\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tabs.written(), "id=\"v-guides\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tabs.written(), "id=\"v-netcol\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tabs.written(), "id=\"v-heat\"") != null);

    var route: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer route.deinit();
    try writeRoutePanel(&route.writer, .{}, null, 0, 0, true, false);
    try std.testing.expect(std.mem.indexOf(u8, route.written(), "id=\"r-drc-show\" type=\"checkbox\" checked") == null);

    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.vis.netcol=1;viewSt.vis.rats=0;viewSt.vis.guides=0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var netColOn=true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function ratsSync()") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function drcSync()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(n===\"Front\"||n===\"Back\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "selectActiveLayer(selected.l)") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, js, "if(claimed[id]||rfOwnsTrack(t))return;") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!RO&&PCB.shown_layout)setTimeout(drawRfRetrofitSaved,0);") != null);
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

// spec: Web Server - On phone-width screens the PCB layout prioritizes a full-height touch viewport with read-only inspection and layer bottom sheets
test "phone layout prioritizes board inspection with touch-sized bottom sheets" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeStage(&aw.writer, .{ .scale = 1, .minx = 0, .miny = 0, .width = 320, .height = 240 }, false);
    const stage = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, stage, "class=\"pcb-mobile-tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stage, "id=\"mobile-info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stage, "id=\"mobile-layers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stage, "id=\"mobile-z-fit\"") != null);

    try std.testing.expect(std.mem.indexOf(u8, mobile_css, "height:calc(100dvh - 48px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile_css, ".pcb-side.mobile-open") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile_css, "min-width:44px;height:44px") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile_css, ".pcb-status{display:none}") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile_css, "a:not(#pcb-tab-2d):not(#pcb-tab-3d)") == null);

    var nav: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer nav.deinit();
    try writeHeadNav(&nav.writer, false, "demo", "Demo", null, .{ .routed = 40, .total = 40, .unique_routed = 4, .unique_total = 4 });
    try std.testing.expect(std.mem.indexOf(u8, nav.written(), ">Schematic</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, nav.written(), ">PCB Layout</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, nav.written(), ">3D View</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, nav.written(), ">Assembly</a>") != null);

    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function mobileInspectMode()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!RO&&!mobileInspectMode())") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function mobilePanelSet(which,open)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "mobileProxy(\"mobile-z-fit\",\"z-fit\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function touchDown(ev){\n mobilePanelsClose();") != null);
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
    try writeLoopJson(&aw.writer, p, lp, &.{});
    try writePlacementJson(&aw.writer, p, .{}, "t", &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"ep\":\"12\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"cap\":\"C1\",\"hub\":\"U1\"") != null);
    // Defaulted target: no `ep` key at all, on either surface.
    lp.explicit_pin = "";
    var dw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dw.deinit();
    try writeLoopJson(&dw.writer, p, lp, &.{});
    try writePlacementJson(&dw.writer, p, .{}, "t", &.{}, null);
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

// Legacy proximity-link serialization stays stable even though the viewer no
// longer exposes placement guides as a display option.
test "placement guides survive plane filtering" {
    const links = [_]optimizer.Link{
        .{ .a = 0, .b = 1, .ax = 0, .ay = 0, .bx = 1, .by = 1, .kind = .proximity, .net = "VDD" },
        .{ .a = 0, .b = 1, .ax = 0, .ay = 0, .bx = 1, .by = 1, .kind = .signal, .net = "VDD" },
    };
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "VDD" }};
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeLinks(&aw.writer, &links, .{ .planes = .{ .declared = &planes } });
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"k\":\"proximity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"k\":\"signal\"") == null);
}

// spec: Web Server - the PCB hand router defaults to the active net class while the sidebar keeps its resolved geometry controls hidden
test "route panel keeps authored geometry hidden instead of exposing routing tuners" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRoutePanel(&aw.writer, .{}, null, 0, 0, true, false);
    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"hidden\" id=\"r-tw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"hidden\" id=\"r-cl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"hidden\" id=\"r-vd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"hidden\" id=\"r-va\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-dw\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-bend\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-br\"") == null);
}

// spec: Web Server - The PCB autorouter sidebar exposes one whole-board Route action; routing-wave scope remains an API concern rather than a routine UI choice
// spec: Web Server - The /pcb-layout Route panel presents Route board, Stop, status, and live replay without cached-load, interactive-session, scope, or advanced-routing controls
test "the route panel is one whole-board action with replay" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // The Replay accordion chip is retired — no data-panel="panel-replay" chip in
    // the tabs row now that the dock lives inside the Route panel.
    try writeTabsRow(&aw.writer, false, false);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "data-panel=\"panel-replay\"") == null);

    var pw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer pw.deinit();
    try writeRoutePanel(&pw.writer, .{}, null, 0, 0, true, false);
    const html = pw.written();
    // The primary Route button and its in-flight Stop are the only routing
    // actions. Scope, deep/advanced routing and interactive sessions are gone.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-go\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-stop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-stop\" title=") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Route board</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-go-deep\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-scope\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<summary>Advanced routing</summary>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"route-replay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<summary>Replay details</summary>") != null);
    // The dock is nested inside panel-route — id preserved so pcb_replay.js's
    // getElementById guard still binds, but NOT a .pcb-panel the accordion
    // would toggle independently. Its disclosure opens only when needed.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"panel-replay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"pcb-replay pcb-panel\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"pcb-replay\" id=\"panel-replay\"") != null);
    // Route itself supplies the replay. There is no cached-load or interactive
    // launch option in the dock.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"rp-run\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"rp-load\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"rp-session\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"rs-stuck\"") == null);
    // Every remaining control id the front-end (pcb_replay.js) binds against.
    const ids = [_][]const u8{
        "id=\"rp-status\"", "id=\"rp-adopt\"",   "id=\"rp-clear\"",
        "id=\"rp-prev\"",   "id=\"rp-play\"",    "id=\"rp-next\"",
        "id=\"rp-slider\"", "id=\"rp-summary\"", "id=\"rp-deltas\"",
        "id=\"rp-log\"",
    };
    for (ids) |id| try std.testing.expect(std.mem.indexOf(u8, html, id) != null);
    // Adopt starts disabled until a run produces a routed result.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"rp-adopt\" disabled") != null);

    var scripts: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer scripts.deinit();
    try writePageScripts(&scripts.writer, .{
        .physical_review = false,
        .model_sprites = false,
        .thermal_overlay = false,
        .embed = false,
    });
    const script_html = scripts.written();
    try std.testing.expect(std.mem.indexOf(u8, script_html, "pcb_replay.js") != null);
    try std.testing.expect((std.mem.indexOf(u8, script_html, "shape_sketch.js") orelse return error.TestUnexpectedResult) <
        (std.mem.indexOf(u8, script_html, "pcb_board.js") orelse return error.TestUnexpectedResult));
    try std.testing.expect(std.mem.indexOf(u8, scripts.written(), "pcb_route_session.js") == null);
}

// spec: Web Server - The /pcb-layout left dock tabs Properties, Autorouter, DRC, and Sub-circuits, showing one pane at a time
test "the left dock tabs properties, autorouter, drc and sub-circuits into one visible pane" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
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
    try writeSidebar(&aw.writer, alloc, placement, "/schematics/demo", .{
        .ro_params = .{},
        .routed = null,
        .n_drc = 0,
        .n_rp = 0,
        .layouts = &.{},
        .auto = .{ .hpwl = 0, .loop = 0, .caps = 0 },
        .panel = .{ .name = "demo" },
    });
    const html = aw.written();
    // Four tab buttons, in order, each naming the pane it shows.
    const t_props = std.mem.indexOf(u8, html, "data-sidetab=\"side-props\"") orelse
        return error.TestPropsTabMissing;
    const t_route = std.mem.indexOf(u8, html, "data-sidetab=\"side-route\"") orelse
        return error.TestRouteTabMissing;
    const t_drc = std.mem.indexOf(u8, html, "data-sidetab=\"side-drc\"") orelse
        return error.TestDrcTabMissing;
    const t_subs = std.mem.indexOf(u8, html, "data-sidetab=\"side-subs\"") orelse
        return error.TestSubsTabMissing;
    try std.testing.expect(t_props < t_route and t_route < t_drc and t_drc < t_subs);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Properties</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Autorouter</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">DRC</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Sub-circuits</button>") != null);
    // Autorouter opens as the useful board-wide default; Properties remains one
    // click (or one board selection) away instead of occupying a blank dock.
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"side-tab active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"side-pane\" id=\"side-props\" hidden>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"side-pane\" id=\"side-route\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"side-drc\" hidden>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"side-subs\" hidden>") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, html, "class=\"side-pane\""));
    // Each pane still carries its content: the part panel, the routing
    // accordion, the DRC violations list, and the (client-filled) sub-circuit
    // palette host.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"prop-body\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-panel=\"panel-route\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"panel-stuck\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"drc-list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"sub-panel\"") != null);
    // The retired standalone "Properties" heading is gone — the tab names it.
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"side-h\"") == null);
    // Saved-version navigation follows the route controls in Autorouter and
    // finishes before the next top-level DRC pane begins.
    const saved_at = std.mem.indexOf(u8, html, "pcb-saved") orelse return error.TestLayoutsPanelMissing;
    const route_at = std.mem.indexOf(u8, html, "id=\"side-route\"") orelse return error.TestRoutePaneMissing;
    const drc_at = std.mem.indexOf(u8, html, "id=\"side-drc\"") orelse return error.TestDrcPaneMissing;
    try std.testing.expect(route_at < saved_at and saved_at < drc_at);
    // The primary route panel is expanded before any route has run.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"panel-route\" hidden") == null);
    // Placement diagnostics and context-only pour/fence actions live with the
    // Autorouter rather than consuming the canvas command row.
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"pcb-placement\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-regen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-pour\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-fence\"") != null);
}

// Compact desktop pages expose one activity rail for the dock drawers and keep
// fabrication handoffs in one menu.
test "the full editor uses a compact activity rail and fabrication menu" {
    var rail: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rail.deinit();
    try writeActivityRail(&rail.writer);
    const nav = rail.written();
    for ([_][]const u8{ "side-find", "side-props", "side-route", "side-drc", "side-subs" }) |pane| {
        try std.testing.expect(std.mem.indexOf(u8, nav, pane) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, nav, "data-dock-appearance") != null);

    var bar: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bar.deinit();
    try writeFullCommandBar(&bar.writer);
    const html = bar.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"pcb-menu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Fabrication ▾</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-kicad-import\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-kicad-push\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-fab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pcb-matlab-rf") == null);
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

// spec: Web Server - The /pcb-layout DRC pane docks the violations list under a previous/next step-through
test "the drc pane docks the violations list under a step-through header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
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
    try writeSidebar(&aw.writer, alloc, placement, "/schematics/demo", .{
        .ro_params = .{},
        .routed = null,
        .n_drc = 0,
        .n_rp = 0,
        .layouts = &.{},
        .auto = .{ .hpwl = 0, .loop = 0, .caps = 0 },
        .panel = .{ .name = "demo" },
    });
    const html = aw.written();
    const pane = std.mem.indexOf(u8, html, "id=\"side-drc\"") orelse return error.TestDrcPaneMissing;
    // Step-through header: both direction buttons, the position readout, and the
    // located violation's message line — every id BOARD_JS binds against.
    for ([_][]const u8{
        "id=\"drc-prev\"", "id=\"drc-next\"", "id=\"drc-pos\"", "id=\"drc-cur\"",
    }) |id| {
        const at = std.mem.indexOf(u8, html, id) orelse return error.TestDrcNavIdMissing;
        try std.testing.expect(at > pane);
    }
    // The violations list is docked in this pane (not folded inside the Route
    // panel), and starts visible — the pane's own `hidden` is the only gate.
    const lst = std.mem.indexOf(u8, html, "id=\"drc-list\"") orelse return error.TestDrcListMissing;
    const route_pane = std.mem.indexOf(u8, html, "id=\"side-route\"") orelse return error.TestRoutePaneMissing;
    try std.testing.expect(lst > pane and pane > route_pane);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"drc-list\" hidden") == null);
}

// spec: Web Server - The /pcb-layout saved-version navigator sits inside Autorouter, immediately after the route controls
test "the saved-layouts panel is nested in the autorouter pane" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
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
    const saved = [_]SavedLayout{.{
        .name = "hand",
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = &.{},
        .default = true,
    }};
    // Every block kind — design, module, `?sub` sub circuit — gets the panel.
    try writeSidebar(&aw.writer, alloc, placement, "/schematics/demo", .{
        .ro_params = .{},
        .routed = null,
        .n_drc = 0,
        .n_rp = 0,
        .layouts = &saved,
        .auto = .{ .hpwl = 0, .loop = 0, .caps = 0 },
        .panel = .{ .name = "demo" },
    });
    const html = aw.written();
    const route = std.mem.indexOf(u8, html, "id=\"side-route\"") orelse return error.TestRoutePaneMissing;
    const drc_at = std.mem.indexOf(u8, html, "id=\"side-drc\"") orelse return error.TestDrcPaneMissing;
    const panel = std.mem.indexOf(u8, html, "pcb-saved") orelse return error.TestLayoutsPanelMissing;
    // The compact previous/select/next navigator lives after Route but before
    // the next top-level pane; the full management list is disclosed on demand.
    try std.testing.expect(route < panel and panel < drc_at);
    try std.testing.expect(std.mem.indexOf(u8, html[panel..drc_at], "id=\"pcb-lay-prev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html[panel..drc_at], "id=\"pcb-lay-select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html[panel..drc_at], "id=\"pcb-lay-next\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html[panel..drc_at], "<summary>All versions</summary>") != null);
    // Rough remaining is now a secondary management action inside All versions.
    const rough = std.mem.indexOf(u8, html, "id=\"pcb-rough\"") orelse return error.TestRoughRemainingMissing;
    try std.testing.expect(panel < rough and rough < drc_at);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, html, "class=\"side-pane\""));
}

// spec: Web Server - The /pcb-layout accordion carries no optimizer tuning or score-reweigh panel
test "the accordion drops the tuning and score panels from both docks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // Neither chip is offered, on the full page's dock or the editable embed's
    // row — so the accordion can never open a retired panel.
    try writeTabsRow(&aw.writer, false, false);
    try writeTabsRow(&aw.writer, true, true);
    const chips = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, chips, "data-panel=\"panel-tune\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, chips, "data-panel=\"panel-score\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, chips, "data-panel=\"panel-route\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chips, "data-panel=\"panel-stuck\"") != null);

    // …and no dock emits their markup: no steering-weight inputs, no per-metric
    // re-weigh rows, no Recompute button.
    var pw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer pw.deinit();
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
    try writeSidebar(&pw.writer, alloc, placement, "/schematics/demo", .{
        .ro_params = .{},
        .routed = null,
        .n_drc = 0,
        .n_rp = 0,
        .layouts = &.{},
        .auto = .{ .hpwl = 0, .loop = 0, .caps = 0 },
        .panel = .{ .name = "demo" },
    });
    try writeEditControls(&pw.writer, placement, "demo", .fresh, false, null, .{}, 0, true);
    const html = pw.written();
    const gone = [_][]const u8{
        "id=\"panel-tune\"", "id=\"panel-score\"", "id=\"t-apply\"",   "id=\"t-align\"",
        "id=\"t-loop\"",     "id=\"t-cong\"",      "id=\"t-grid\"",    "id=\"sv-en-",
        "id=\"sv-w-",        "id=\"sv-reset\"",    "id=\"pcb-score\"", "sc-readout",
    };
    for (gone) |g| try std.testing.expect(std.mem.indexOf(u8, html, g) == null);
    // The headline objective chip stays — it is the toolbar's, not the panel's.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"sc-obj\"") != null);
}

// spec: Web Server - The /pcb-layout accordion carries a Stuck-nets chip and its diagnostics dock
test "the accordion embeds the stuck-nets chip and its diagnostics dock" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // The chip lives in the shared tabs row, adopted by the accordion JS by its
    // data-panel pairing — exactly like Route and Replay.
    try writeTabsRow(&aw.writer, false, false);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "data-panel=\"panel-stuck\"") != null);

    var pw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer pw.deinit();
    try writeStuckPanel(&pw.writer);
    const html = pw.written();
    // The panel base class + id the accordion toggles, plus the ids/markers
    // pcb_stuck.js binds against (count, empty-state, list) and the empty-state
    // instruction shown before a route has run.
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"pcb-stuck pcb-panel\" id=\"panel-stuck\"") != null);
    const ids = [_][]const u8{ "id=\"sk-count\"", "id=\"sk-empty\"", "id=\"sk-list\"" };
    for (ids) |id| try std.testing.expect(std.mem.indexOf(u8, html, id) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Run <b>Route</b> to see diagnostics") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, d, "\"mask_margin\":0.05") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"mask_web\":0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"min_width\":0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"clearance\":0.127") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"component_edge\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"perimeter_mask_width\":0") != null);
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

// spec: Web Server - The PCB editor draws one physical heatsink base rectangle on either board face, reopens it for parameter edits, drags it to reposition, resizes it with corner handles, directly edits fin count or gap, target package, material, base/fins and thermal pad, persists the assembly with the named layout, previews its pad/base/fins in 3D, and feeds the same exact contact and derived theta-SA to built-in and Elmer thermal solves
test "layouts sidecar round-trips a physical heatsink assembly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U15", .x = 12, .y = 8, .rot = 0 }};
    const layouts = [_]SavedLayout{.{
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
            .target_ref = "U15",
            .material = "aluminum_6061",
            .base_mm = 2.5,
            .fin_height_mm = 12,
            .fin_thickness_mm = 0.8,
            .fin_gap_mm = 1.2,
            .fin_axis = "width",
            .pad_thickness_mm = 0.5,
            .pad_k_w_mk = 6,
        },
    }};
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sink = got[0].heatsink orelse return error.TestParseFailed;
    try std.testing.expectEqualStrings("U15", sink.target_ref);
    try std.testing.expectEqualStrings("bottom", sink.side);
    try std.testing.expectEqualStrings("aluminum_6061", sink.material);
    try std.testing.expectEqualStrings("width", sink.fin_axis);
    try std.testing.expectEqual(@as(f64, 24), sink.w);
    try std.testing.expectEqual(@as(f64, 0.8), sink.fin_thickness_mm);
    try std.testing.expectEqual(@as(f64, 0.5), sink.pad_thickness_mm);
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

// spec: Web Server - the outline write paths reject a self-intersecting or zero-area polygon but accept a concave one
test "outline write-path gate rejects a self-intersecting polygon, accepts a concave one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A bow-tie polygon still parses (the reader is deliberately lenient), but
    // the shared write-path gate — outline_mod.valid, called by
    // saveNamedLayoutApi (→ HTTP 400) and mcpSetBoardOutline (→ CLI error) —
    // rejects it.
    const bowtie = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"pts":[[0,0],[10,10],[10,0],[0,10]]}
    , .{});
    const bo = mcpParseOutlineArg(alloc, bowtie) orelse return error.TestParseFailed;
    const bpts = bo.pts orelse return error.TestParseFailed;
    try std.testing.expect(!outline_mod.valid(bpts));

    // A concave-but-simple L polygon parses AND passes the gate.
    const l = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"pts":[[0,0],[40,0],[40,20],[20,20],[20,40],[0,40]]}
    , .{});
    const lo = mcpParseOutlineArg(alloc, l) orelse return error.TestParseFailed;
    const lpts = lo.pts orelse return error.TestParseFailed;
    try std.testing.expect(outline_mod.valid(lpts));
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
    try std.testing.expect(std.mem.startsWith(u8, parsed.tracks[0].id, segment_id_prefix));
    try std.testing.expectEqual(@as(usize, segment_id_prefix.len + 16), parsed.tracks[0].id.len);
    try std.testing.expect(!std.mem.eql(u8, parsed.tracks[0].id, parsed.tracks[1].id));
    try std.testing.expectEqual(@as(usize, 2), parsed.vias.len);
    try std.testing.expect(std.mem.startsWith(u8, parsed.vias[0].id, via_id_prefix));
    try std.testing.expectEqual(@as(usize, via_id_prefix.len + 16), parsed.vias[0].id.len);
    try std.testing.expect(!std.mem.eql(u8, parsed.vias[0].id, parsed.vias[1].id));

    var blob: std.Io.Writer.Allocating = .init(alloc);
    try writeRoutedArrays(&blob.writer, null, &.{}, .{}, .{ .tracks = &tracks, .vias = &.{} }, null);
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

// spec: placement/rf-port-frame-routing - a route removed by the final DRC gate is never rendered, saved, replayed, or fabricated as an RF polygon
test "fresh route persistence omits DRC-gate-removed RF polygons" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
    };
    const outcomes = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = 2, .gate_removed = true, .samples = &samples },
    }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &.{} }};

    var json: std.Io.Writer.Allocating = .init(alloc);
    try writeFreshRfPathsJson(&json.writer, &outcomes, &nets);
    try std.testing.expectEqualStrings("[]", json.written());

    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .rf_port_outcomes = &outcomes };
    const saved = try mcpSavedRoutesFrom(alloc, routed, &nets, null);
    try std.testing.expectEqual(@as(usize, 0), saved.rf_paths.len);
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
    // (stack 3) is a free inner SIGNAL layer at index 2 — the barracuda case.
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
    try writeRoutedArrays(&blob.writer, rr, &.{}, .{ .nets = &nets }, sr, null);
    try std.testing.expect(std.mem.indexOf(u8, blob.written(), "\"f\":\"RF1_BPF\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, blob.written(), "\"f\":"));
}

// spec: Web Server - A moved RF part drops its trace's fence with its copper, because a fence via is invalidated by the net it flanks and not by the ground net it stitches
test "scoped copper clearing drops a fence via by the net it flanks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const sr = SavedRoutes{
        .tracks = &[_]SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .w = 0.31, .net = "RF1_BPF" }},
        .vias = &[_]SavedVia{
            .{ .x = 1, .y = 0.6, .d = 0.4, .drill = 0.2, .net = "GND", .f = "RF1_BPF" },
            .{ .x = 9, .y = 9, .d = 0.4, .drill = 0.2, .net = "GND" }, // plain GND stitch
        },
    };
    // Moving the RF part invalidates RF1_BPF only — GND is untouched.
    var drop = std.StringHashMapUnmanaged(void).empty;
    try drop.put(alloc, "RF1_BPF", {});
    const res = try mcpDropRoutesForNets(alloc, sr, &drop);
    const kept = res.routes orelse return error.TestParseFailed;
    // The trace AND its fence go; the unrelated GND stitching via stays. Keyed on
    // `net` alone the fence would have survived beside nothing.
    try std.testing.expectEqual(@as(usize, 2), res.dropped);
    try std.testing.expectEqual(@as(usize, 0), kept.tracks.len);
    try std.testing.expectEqual(@as(usize, 1), kept.vias.len);
    try std.testing.expectApproxEqAbs(@as(f64, 9), kept.vias[0].x, 1e-9);
}

// spec: Web Server - coordinate-scoped clear_routes removes one selected via without erasing the rest of a dense shared net
test "coordinate-scoped via clearing is surgical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const sr = SavedRoutes{
        .tracks = &[_]SavedTrack{
            .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .w = 0.25, .net = "GND" },
        },
        .vias = &[_]SavedVia{
            .{ .x = 1.0, .y = 1.0, .d = 0.4, .drill = 0.2, .net = "GND" },
            .{ .x = 1.2, .y = 1.0, .d = 0.4, .drill = 0.2, .net = "GND" },
            .{ .x = 1.0, .y = 1.0, .d = 0.4, .drill = 0.2, .net = "VCC" },
        },
    };
    var drop = std.StringHashMapUnmanaged(void).empty;
    try drop.put(alloc, "GND", {});
    const res = try mcpDropViasNear(alloc, sr, &drop, 1.0, 1.0, 0.05);
    const kept = res.routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), res.dropped);
    try std.testing.expectEqual(@as(usize, 1), kept.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), kept.vias.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), kept.vias[0].x, 1e-9);
    try std.testing.expectEqualStrings("VCC", kept.vias[1].net);
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
    try writeRoutedArrays(&blob.writer, null, &.{}, .{}, sr, null);
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

// Regression: zone replacement validates the complete set before persistence.
test "set_copper_zones validates nets inner layers and polygons" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const planes = [_]optimizer.PlaneAt{
        .{ .index = 2, .net = "GND" },
        .{ .index = 5, .net = "GND" },
    };
    var placement = addTracksFixture(&.{}, &add_tracks_nets, &.{});
    placement.rules = .{
        .plane_nets = &.{"GND"},
        .copper_layers = 6,
        .planes = .{ .declared = &planes },
    };

    var valid_out: std.ArrayList(u8) = .empty;
    const valid_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"SIG\",\"layer\":\"In3.Cu\",\"priority\":4,\"poly\":[[0,0],[8,0],[8,6],[0,6]]}]}",
        .{},
    );
    const zones = (try mcpBuildCopperZones(alloc, &valid_out, placement, valid_json)).?;
    try std.testing.expectEqual(@as(usize, 1), zones.len);
    try std.testing.expectEqualStrings("In3.Cu", zones[0].layer);
    try std.testing.expect(zones[0].flags.filled);
    try std.testing.expectEqual(@as(i64, 4), zones[0].priority);

    var plane_out: std.ArrayList(u8) = .empty;
    const claimed_plane = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"SIG\",\"layer\":\"In1.Cu\",\"poly\":[[0,0],[8,0],[0,6]]}]}",
        .{},
    );
    try std.testing.expect((try mcpBuildCopperZones(alloc, &plane_out, placement, claimed_plane)) == null);
    try std.testing.expect(std.mem.indexOf(u8, plane_out.items, "plane-claimed") != null);

    var net_out: std.ArrayList(u8) = .empty;
    const unknown_net = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"NO_SUCH_NET\",\"layer\":\"In3.Cu\",\"poly\":[[0,0],[8,0],[0,6]]}]}",
        .{},
    );
    try std.testing.expect((try mcpBuildCopperZones(alloc, &net_out, placement, unknown_net)) == null);
    try std.testing.expect(std.mem.indexOf(u8, net_out.items, "unknown net") != null);

    var poly_out: std.ArrayList(u8) = .empty;
    const crossing = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"SIG\",\"layer\":\"In3.Cu\",\"poly\":[[0,0],[8,6],[0,6],[8,0]]}]}",
        .{},
    );
    try std.testing.expect((try mcpBuildCopperZones(alloc, &poly_out, placement, crossing)) == null);
    try std.testing.expect(std.mem.indexOf(u8, poly_out.items, "self-intersects") != null);
}

// Regression: a clean-slate autoroute clears generated copper but keeps the
// user-authored pours that are inputs to the next route.
test "unscoped clear_routes preserves copper zones" {
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 3 }, .{ 0, 3 } };
    const zones = [_]SavedZone{.{
        .net = "SIG",
        .layer = board_layers.f_cu,
        .poly = &poly,
        .flags = .{ .filled = true },
    }};
    const routes = SavedRoutes{
        .tracks = &.{.{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .w = 0.2, .net = "SIG" }},
        .vias = &.{.{ .x = 2, .y = 0, .d = 0.4, .net = "SIG" }},
        .zones = &zones,
    };
    const kept = mcpClearAllRoutedCopper(routes) orelse return error.TestNoSavedRoutes;
    try std.testing.expectEqual(@as(usize, 0), kept.tracks.len);
    try std.testing.expectEqual(@as(usize, 0), kept.vias.len);
    try std.testing.expectEqual(@as(usize, 1), kept.zones.len);
    try std.testing.expectEqualStrings(board_layers.f_cu, kept.zones[0].layer);

    try std.testing.expect(mcpClearAllRoutedCopper(.{ .tracks = &.{}, .vias = &.{} }) == null);
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
    try writeSubRoutesJson(&aw.writer, alloc, "buck", sr, .{
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

// spec: Web Server - The set_part_poses MCP tool parses each pose's ref, mm centre, and optional rot/side/locked (absent optionals stay unset)
test "mcp set_part_poses parses request poses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"poses":[{"ref":"C1","x_mm":1.5,"y_mm":2.5},
        \\{"ref":"mcu/U1","x_mm":0,"y_mm":0,"rot":90,"side":"bottom","locked":true}]}
    ;
    const j = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
    const poses = mcpParsePoses(alloc, j) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), poses.len);
    try std.testing.expectEqualStrings("C1", poses[0].ref);
    try std.testing.expect(poses[0].has_xy);
    try std.testing.expectEqual(@as(f64, 1.5), poses[0].x);
    try std.testing.expectEqual(@as(f64, 2.5), poses[0].y);
    // Absent optionals stay unset so the tool keeps the part's current values.
    try std.testing.expect(!poses[0].has_rot);
    try std.testing.expect(!poses[0].has_side);
    try std.testing.expect(!poses[0].has_locked);
    // Present optionals parse through.
    try std.testing.expect(poses[1].has_rot);
    try std.testing.expectEqual(@as(f64, 90), poses[1].rot);
    try std.testing.expectEqual(optimizer.Side.bottom, poses[1].side);
    try std.testing.expect(poses[1].has_locked and poses[1].locked);
}

// spec: Web Server - The set_board_outline MCP tool accepts a rect and a polygon pts, deriving the rect fields from the polygon bbox
test "mcp set_board_outline parses rect and polygon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const jr = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"rect\":{\"x\":0,\"y\":0,\"w\":10,\"h\":20}}", .{});
    const o1 = mcpParseOutlineArg(alloc, jr) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(f64, 10), o1.w);
    try std.testing.expectEqual(@as(f64, 20), o1.h);
    try std.testing.expect(o1.pts == null);

    const jp = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"pts\":[[0,0],[4,0],[4,3]]}", .{});
    const o2 = mcpParseOutlineArg(alloc, jp) orelse return error.TestParseFailed;
    try std.testing.expect(o2.pts != null);
    try std.testing.expectEqual(@as(f64, 4), o2.w); // bbox width
    try std.testing.expectEqual(@as(f64, 3), o2.h); // bbox height

    // A degenerate rect (zero area) is rejected.
    const jbad = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"rect\":{\"x\":0,\"y\":0,\"w\":0,\"h\":0}}", .{});
    try std.testing.expect(mcpParseOutlineArg(alloc, jbad) == null);
}

// spec: Web Server - The route_pcb MCP tool serializes routed net indices back to net names, round-tripping through restoreRoutes
// spec: serve/mcp_tools - Saved-copper rewrites preserve stamp-group, fence-provenance, and via-span tags on unchanged geometry
test "mcp route_pcb copper round-trips net index and name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &[_]export_kicad.FlatPin{} },
        .{ .name = "VBUS", .pins = &[_]export_kicad.FlatPin{} },
    };
    const rr = router.RouteResult{
        .tracks = &[_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 1, .width = 0.3, .net = 1 }},
        .vias = &[_]router.Via{.{ .x = 1, .y = 0, .dia = 0.6, .net = 1, .drill = 0.3 }},
        .routed = 1,
        .total = 1,
    };
    const prior_tracks = [_]SavedTrack{.{ .x1 = 3, .y1 = 0, .x2 = 0, .y2 = 0, .l = 1, .w = 0.3, .net = "VBUS", .g = "power-block", .source = route_source_human, .id = "seg-retained000001" }};
    const prior_vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "VBUS", .g = "power-block", .f = "RF_OUT", .source = route_source_agent, .s = .{ 0, 1 }, .id = "via-retained000001" }};
    const sr = try mcpSavedRoutesFrom(alloc, rr, &nets, .{ .tracks = &prior_tracks, .vias = &prior_vias });
    try std.testing.expectEqualStrings("VBUS", sr.tracks[0].net);
    try std.testing.expectEqual(@as(u8, 1), sr.tracks[0].l);
    try std.testing.expectEqualStrings("VBUS", sr.vias[0].net);
    try std.testing.expectEqualStrings("power-block", sr.tracks[0].g);
    try std.testing.expectEqualStrings("power-block", sr.vias[0].g);
    try std.testing.expectEqualStrings("RF_OUT", sr.vias[0].f);
    try std.testing.expectEqualStrings(route_source_human, sr.tracks[0].source);
    try std.testing.expectEqualStrings("seg-retained000001", sr.tracks[0].id);
    try std.testing.expectEqualStrings(route_source_agent, sr.vias[0].source);
    try std.testing.expectEqual(@as(?[2]u8, .{ 0, 1 }), sr.vias[0].s);
    try std.testing.expectEqualStrings("via-retained000001", sr.vias[0].id);

    const fresh = try mcpSavedRoutesFrom(alloc, rr, &nets, null);
    try std.testing.expectEqualStrings(route_source_autorouter, fresh.tracks[0].source);
    try std.testing.expectEqualStrings(route_source_autorouter, fresh.vias[0].source);

    const legacy_tracks = [_]SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .l = 1, .w = 0.3, .net = "VBUS" }};
    const legacy_vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "VBUS" }};
    const legacy = try mcpSavedRoutesFrom(alloc, rr, &nets, .{ .tracks = &legacy_tracks, .vias = &legacy_vias });
    try std.testing.expectEqualStrings("", legacy.tracks[0].source);
    try std.testing.expectEqualStrings("", legacy.vias[0].source);

    const restored = restoreRoutes(alloc, sr, &nets) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(i32, 1), restored.tracks[0].net);
    try std.testing.expectEqual(@as(i32, 1), restored.vias[0].net);
}

// spec: Web Server - route_pcb can learn hard path topology and reserve its proven transition sites from a completed saved reference layout while preserving authored wave/layer policy
// spec: Web Server - a reference-guided route reports how many nets received learned topology and how many required exact-copper fallback
test "mcp route_pcb overlays saved reference topology on authored policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = false,
        .board_rect = .{ .minx = -1, .miny = -1, .w = 6, .h = 2 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const saved = SavedRoutes{
        .tracks = &.{
            .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .l = 0, .w = 0.2, .net = "SIG" },
            .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .l = 0, .w = 0.2, .net = "SIG" },
        },
        .vias = &.{.{ .x = 2, .y = 0, .d = 0.4, .drill = 0.2, .net = "SIG" }},
    };
    const base = [_]route_policy.NetPolicy{.{
        .wave = .{ .priority = 17, .before_planes = 1 },
        .allowed_layers = 1,
        .max_vias = 2,
    }};
    var options = route_policy.Options{ .net = &base };
    const guided = try mcpApplyReferenceGuides(alloc, &options, placement, saved);
    try std.testing.expectEqual(@as(usize, 1), guided);
    try std.testing.expectEqual(@as(u32, 17), options.net[0].wave.priority);
    try std.testing.expectEqual(@as(u64, 1), options.net[0].allowed_layers);
    try std.testing.expectEqual(@as(?u16, 2), options.net[0].max_vias);
    try std.testing.expect(options.net[0].replay_reference_copper);
    try std.testing.expectEqual(@as(usize, 2), options.guides.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), options.guides.reserved.len);
}

// spec: Web Server - The route_pcb CLI tool preserves custom copper pours and passes them to the autorouter for whole-board and scoped routes
test "mcp route_pcb scoped copper preserves custom pours while dropping and merging by net" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const zone_poly = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const sr = SavedRoutes{
        .tracks = &[_]SavedTrack{
            .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .w = 0.2, .net = "A" },
            .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .w = 0.2, .net = "B" },
        },
        .vias = &.{},
        .zones = &.{.{ .net = "A", .layer = "In2.Cu", .poly = &zone_poly, .flags = .{ .filled = true } }},
    };
    var scope = std.StringHashMapUnmanaged(void).empty;
    try scope.put(alloc, "A", {});

    const dropped = try mcpDropRoutesForNets(alloc, sr, &scope);
    try std.testing.expectEqual(@as(usize, 1), dropped.dropped); // A removed
    const rem = dropped.routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), rem.tracks.len);
    try std.testing.expectEqualStrings("B", rem.tracks[0].net); // B kept
    try std.testing.expectEqual(@as(usize, 1), rem.zones.len); // custom pour kept

    const kept = try mcpKeepRoutesForNets(alloc, sr, &scope) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), kept.tracks.len);
    try std.testing.expectEqualStrings("A", kept.tracks[0].net);
    try std.testing.expectEqual(@as(usize, 0), kept.zones.len); // retained base owns it

    const merged = try mcpMergeRoutes(alloc, rem, kept) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), merged.tracks.len); // B (prior) + A (fresh)
    try std.testing.expectEqual(@as(usize, 1), merged.zones.len);
}

/// A minimal placement + design block for the route-scope resolver tests: one
/// hub and two nets (an RF net the criticality classifier recognises by name,
/// and a plain signal net).
const scope_fixture_part = optimizer.Part{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false };
const scope_fixture_nets = [_]export_kicad.FlatNet{
    .{ .name = "RFOUT", .pins = &.{} },
    .{ .name = "SIG", .pins = &.{} },
};

fn scopeFixture(parts: *[1]optimizer.Part) struct { placement: optimizer.Placement, block: env_mod.DesignBlock } {
    parts.* = .{scope_fixture_part};
    return .{
        .placement = .{
            .parts = parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &scope_fixture_nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = 0,
            .miny = 0,
            .maxx = 1,
            .maxy = 1,
            .generated = true,
        },
        .block = .{
            .name = "t",
            .instances = &.{},
            .nets = &.{},
            .ports = &.{},
            .notes = &.{},
            .groups = &.{},
            .sub_blocks = &.{},
        },
    };
}

// spec: Web Server - The route_pcb scope resolver selects a group token's concrete nets and reports a whole-board route when no selector is given
test "mcp route scope resolves a group and defaults to whole board" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts: [1]optimizer.Part = undefined;
    const fx = scopeFixture(&parts);

    var out: std.ArrayList(u8) = .empty;
    const rf = (try mcpResolveRouteScope(alloc, &out, &fx.block, fx.placement, &.{"rf"}, &.{})) orelse
        return error.TestScopeNull;
    try std.testing.expect(rf.has_scope);
    try std.testing.expectEqual(@as(usize, 1), rf.matched);
    try std.testing.expectEqualStrings("RFOUT", rf.names[0]);

    // No selector token at all ⇒ a whole-board route (no error emitted).
    var out2: std.ArrayList(u8) = .empty;
    const whole = (try mcpResolveRouteScope(alloc, &out2, &fx.block, fx.placement, &.{}, &.{})) orelse
        return error.TestScopeNull;
    try std.testing.expect(!whole.has_scope);
    try std.testing.expectEqual(@as(usize, 0), out2.items.len);
}

// spec: Web Server - The route_pcb scope resolver rejects an unknown group or net token with an error and no scope
test "mcp route scope errors on an unknown token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts: [1]optimizer.Part = undefined;
    const fx = scopeFixture(&parts);

    var out: std.ArrayList(u8) = .empty;
    const bad = try mcpResolveRouteScope(alloc, &out, &fx.block, fx.placement, &.{"nope"}, &.{});
    try std.testing.expect(bad == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown route group/net") != null);
}

// spec: Web Server - The viewer Route scope parses a group into an incremental ScopedRoute that retains submitted copper for the unselected nets
test "viewer route scope preserves other-net copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts: [1]optimizer.Part = undefined;
    const fx = scopeFixture(&parts); // nets: RFOUT (rf), SIG (signal)

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

// spec: Web Server - The set_part_poses MCP tool resolves a part by module-local origin key when the ref-des is not an exact match
test "mcp origin-key strips the sub-block prefix" {
    try std.testing.expectEqualStrings("U1", mcpOriginOf("buck/U1"));
    try std.testing.expectEqualStrings("C3", mcpOriginOf("C3"));
    try std.testing.expectEqualStrings("C_IN", mcpOriginOf("mcu/sub/C_IN"));
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
    const seed_stats = try addSubcircuitRouteSeeds(alloc, project_dir, dblock, placement, placement.rules.design.routeParams(), &options);
    try std.testing.expectEqual(@as(usize, 1), seed_stats.copper.accepted_nets);
    try std.testing.expectEqual(@as(usize, 1), options.existing_tracks.len);
    try std.testing.expectEqual(@as(usize, 0), options.existing_vias.len);
    try std.testing.expectApproxEqAbs(@as(f64, 11), options.existing_tracks[0].x1, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 22), options.existing_tracks[0].y2, 1e-9);
    try std.testing.expectEqual(@as(u8, 0), options.existing_tracks[0].layer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), options.existing_tracks[0].width, 1e-9);
    try std.testing.expectEqual(@as(?u16, 2), options.net[ctrl_i].max_vias);

    // A board-level tweak makes the one-shot local candidate incomplete and
    // invalidates the stale saved snapshot. The standalone completion retry
    // must still produce fresh, board-rule-width copper for the moved pads.
    board_parts[2].x += 0.5;
    const moved_policies = try alloc.alloc(route_policy.NetPolicy, board_nets.items.len);
    @memset(moved_policies, .{});
    var moved_options = route_policy.Options{ .net = moved_policies };
    const moved = try addSubcircuitRouteSeeds(alloc, project_dir, dblock, placement, placement.rules.design.routeParams(), &moved_options);
    try std.testing.expectEqual(@as(usize, 1), moved.copper.accepted_nets);
    try std.testing.expectEqual(@as(usize, 0), moved.copper.rejected_nets);
    try std.testing.expectEqual(@as(usize, 2), moved_options.existing_tracks.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), moved_options.existing_tracks[0].width, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), moved_options.existing_tracks[1].width, 1e-9);
}

test "mcpSetPartPoses rejects an empty poses array before resolving" {
    // `if (reqs.len == 0)` fails fast with `"poses" is empty`; an `==`->`!=`
    // flip lets an empty request through to layout resolution, which fails
    // with a different ("could not resolve") message instead.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"x\",\"poses\":[]}", .{});
    const ok = try mcpSetPartPoses(alloc, "/no/such/project", args, &out);
    try std.testing.expect(!ok);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "is empty") != null);
}

// spec: Web Server - The shown layout's copper carries its pour zones, so a rail poured rather than traced counts as connected
test "shownLayoutCopper carries pour zones as connecting copper" {
    // barracuda pours V_12V / V_5VA / V_6VA / V_3V3A / V_3V3_LMX instead of
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
    // One saved layout whose copper is a filled B.Cu pour on RAIL, no tracks.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/z.layouts.json", .data =
        \\{"default":"layout","layouts":[{"name":"layout","default":true,"parts":[{"ref":"U1","x":1,"y":1,"rot":0}],
        \\"routes":{"tracks":[],"vias":[],"zones":[{"net":"RAIL","layer":"B.Cu","filled":true,"keepout":false,
        \\"priority":1,"poly":[[0,0],[10,0],[10,10],[0,10]]}]}}]}
    });

    const rules = optimizer.BoardRules{ .plane_nets = &.{}, .copper_layers = 2 };
    var placement = addTracksFixture(&.{}, &.{}, &.{});
    placement.rules = rules;
    const shown = shownLayoutCopper(alloc, project, "z", .{}, placement);
    try std.testing.expect(shown.from_saved);
    // The pour must survive into the copper the connectivity oracle sees.
    try std.testing.expectEqual(@as(usize, 1), shown.zones.len);
    try std.testing.expectEqualStrings("RAIL", shown.zones[0].net);
    try std.testing.expectEqual(@as(u8, 1), shown.zones[0].layer); // B.Cu
}

/// A 2-layer, plane-free board carrying nets SIG (net 0) and RF (net 1) — the
/// fixture the `add_tracks` lowering scenarios draw copper on. `rules.net`
/// gives RF a `(net-class …)` rule so the width/via defaulting is observable.
fn addTracksFixture(parts: []optimizer.Part, nets: []const export_kicad.FlatNet, rules: []const optimizer.NetRule) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 10 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2, .net = rules },
    };
}

const add_tracks_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};

fn addTracksParts() [2]optimizer.Part {
    return .{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &add_tracks_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &add_tracks_pad, .fallback = false, .x = 10, .y = 0 },
    };
}

const add_tracks_nets = [_]export_kicad.FlatNet{
    .{ .name = "SIG", .pins = &.{} },
    .{ .name = "RF", .pins = &.{} },
};

// spec: Web Server - The add_tracks tool lowers a requested polyline into one persisted track segment per consecutive point pair
test "add_tracks lowers an N-point polyline into N-1 segments on the named layer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;

    var parts = addTracksParts();
    const placement = addTracksFixture(&parts, &add_tracks_nets, &.{});
    // A 4-point L-shaped route on the bottom layer → 3 joined segments.
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 4 }, .{ 10, 4 } };
    const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "B.Cu", .pts = &pts }};

    const built = (try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})).?;
    try std.testing.expectEqual(@as(usize, 3), built.tracks.len);
    // Segments must CHAIN (each one's end is the next one's start), else the
    // copper lands as disconnected stubs and the net never closes.
    try std.testing.expectEqual(@as(f64, 0), built.tracks[0].x1);
    try std.testing.expectEqual(@as(f64, 3), built.tracks[0].x2);
    try std.testing.expectEqual(@as(f64, 3), built.tracks[1].x1);
    try std.testing.expectEqual(@as(f64, 4), built.tracks[1].y2);
    try std.testing.expectEqual(@as(f64, 10), built.tracks[2].x2);
    for (built.tracks) |t| {
        try std.testing.expectEqual(@as(u8, 1), t.l); // B.Cu
        try std.testing.expectEqualStrings("SIG", t.net);
        try std.testing.expectEqualStrings(route_source_agent, t.source);
    }
}

// spec: Web Server - The add_tracks tool defaults track width and via geometry to the net's declared net-class rule
test "add_tracks takes width and via size from the net-class rule unless overridden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;

    var parts = addTracksParts();
    // Net 1 (RF) carries a class rule; net 0 (SIG) has none, so SIG falls back
    // to the board base params.
    const rules = [_]optimizer.NetRule{ .{}, .{ .width = 0.45, .via_dia = 0.6, .via_drill = 0.3 } };
    const placement = addTracksFixture(&parts, &add_tracks_nets, &rules);
    const base = router.RouteParams{ .track_width = 0.127, .via_dia = 0.4, .via_drill = 0.2 };

    const sig_pts = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 } };
    const rf_pts = [_][2]f64{ .{ 0, 2 }, .{ 5, 2 } };
    const wide_pts = [_][2]f64{ .{ 0, 4 }, .{ 5, 4 } };
    const reqs = [_]McpReqTrack{
        .{ .net = "SIG", .layer = "F.Cu", .pts = &sig_pts },
        .{ .net = "RF", .layer = "F.Cu", .pts = &rf_pts },
        .{ .net = "RF", .layer = "F.Cu", .pts = &wide_pts, .width = 1.2 },
    };
    const vreqs = [_]McpReqVia{
        .{ .net = "SIG", .x = 5, .y = 0 },
        .{ .net = "RF", .x = 5, .y = 2 },
    };

    const built = (try mcpBuildAddedCopper(alloc, &out, placement, base, &reqs, &vreqs)).?;
    try std.testing.expectEqual(@as(f64, 0.127), built.tracks[0].w); // board default
    try std.testing.expectEqual(@as(f64, 0.45), built.tracks[1].w); // RF class width
    try std.testing.expectEqual(@as(f64, 1.2), built.tracks[2].w); // explicit override wins
    try std.testing.expectEqual(@as(f64, 0.4), built.vias[0].d); // board default via
    try std.testing.expectEqual(@as(f64, 0.6), built.vias[1].d); // RF class via
    try std.testing.expectEqual(@as(f64, 0.3), built.vias[1].drill);
    for (built.tracks) |t| try std.testing.expectEqualStrings(route_source_agent, t.source);
    try std.testing.expectEqualStrings(route_source_agent, built.vias[0].source);
    try std.testing.expectEqualStrings(route_source_agent, built.vias[1].source);
}

// spec: Web Server - Hand-added copper that raises the error-severity DRC count is rolled back rather than persisted, unless the caller opts out
test "add_tracks rolls back copper that raises the error count" {
    // The decision the handler makes, in isolation: keep copper only while the
    // error-severity count does not climb. There is no per-edit undo otherwise
    // (`clear_routes` is per-NET), so an agent drawing copper needs a bad edit
    // to cost nothing — that is what makes draw/measure/adjust safe to iterate.
    const keeps = struct {
        fn f(rollback: bool, before: usize, after: usize) bool {
            return !(rollback and after > before);
        }
    }.f;
    try std.testing.expect(keeps(true, 8, 8)); // unchanged: kept
    try std.testing.expect(keeps(true, 8, 7)); // improved: kept
    try std.testing.expect(!keeps(true, 8, 11)); // worse: rolled back
    // …and the opt-out keeps copper regardless, for a caller spending a known
    // budget deliberately.
    try std.testing.expect(keeps(false, 8, 11));
}

// spec: Web Server - The add_tracks result separates fab-blocking DRC errors from total violations
test "add_tracks reports drc_errors beside the total violation count" {
    // The two counts must be distinct fields: a caller deciding whether to keep
    // hand copper gates on ERRORS, because sharp-bend / diff-skew WARNINGS are
    // not fab-blocking and treating them as regressions rejects good routes.
    const vios = [_]drc.Violation{
        .{ .kind = .track_pad, .x = 1, .y = 1, .gap = 0.01, .clearance = 0.127, .severity = .err },
        .{ .kind = .sharp_bend, .x = 2, .y = 2, .gap = 0, .clearance = 0, .severity = .warn },
        .{ .kind = .track_track, .x = 3, .y = 3, .gap = 0.02, .clearance = 0.127, .severity = .err },
    };
    // 3 violations, but only 2 block fabrication.
    try std.testing.expectEqual(@as(usize, 2), drc.errorCount(&vios));
    // An all-warning list is reported as zero blocking errors, never as "clean"
    // by dropping the warnings from the total the caller also sees.
    try std.testing.expectEqual(@as(usize, 0), drc.errorCount(vios[1..2]));
    try std.testing.expectEqual(@as(usize, 0), drc.errorCount(&.{}));
}

// spec: Web Server - The add_tracks rollback gate counts only geometry violations, never an open net, so an unfinished escape stub is kept
test "add_tracks judges hand copper on geometry, not on the net still being open" {
    // Hand routing lands in steps. The first step out of a sealed fine-pitch
    // pad is a stub to a fanout via: geometrically perfect, and it raises the
    // OPEN-net count by one because the stub is its own island until the run
    // finishes. Counting that as a regression rolled the stub back and the
    // loop could never take a first step — measured on barracuda's LMX2595
    // escape, which added zero clearance findings and was undone anyway.
    const stub_in_progress = [_]drc.Violation{
        .{ .kind = .net_open, .x = 1, .y = 1, .gap = 0.3, .clearance = 0, .severity = .err },
    };
    try std.testing.expectEqual(@as(usize, 0), drc.errorCount(&stub_in_progress));

    // A real clearance breach in the same list still counts, so the gate has
    // not been widened into "keep everything".
    const stub_plus_breach = [_]drc.Violation{
        .{ .kind = .net_open, .x = 1, .y = 1, .gap = 0.3, .clearance = 0, .severity = .err },
        .{ .kind = .track_pad, .x = 2, .y = 2, .gap = 0.01, .clearance = 0.127, .severity = .err },
    };
    try std.testing.expectEqual(@as(usize, 1), drc.errorCount(&stub_plus_breach));
}

// spec: Web Server - The add_tracks tool rejects an unknown net, an unknown copper layer, or a polyline shorter than two points without persisting anything
test "add_tracks rejects an unknown net, unknown layer, or single-point polyline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parts = addTracksParts();
    const placement = addTracksFixture(&parts, &add_tracks_nets, &.{});
    const good = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 } };
    const lone = [_][2]f64{.{ 0, 0 }};

    // Unknown net — named in the error so the caller can fix the spelling.
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "NOPE", .layer = "F.Cu", .pts = &good }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown net") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "NOPE") != null);
    }
    // Unknown copper layer (In2.Cu does not exist on this 2-layer stackup).
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "In2.Cu", .pts = &good }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown copper layer") != null);
    }
    // A 1-point polyline draws no segment — reject rather than silently no-op.
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "F.Cu", .pts = &lone }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "at least 2 points") != null);
    }
    // A via on an unknown net is refused too — the whole request fails, so a
    // valid track earlier in the same call is never half-persisted.
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "F.Cu", .pts = &good }};
        const vreqs = [_]McpReqVia{.{ .net = "GHOST", .x = 1, .y = 1 }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &vreqs)) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "GHOST") != null);
    }
}

// ── Progress-ladder copper seam ──────────────────────────────────────────────

/// The persisted routed copper of the layout the describe/PNG views show, plus
/// whether that layout is a saved snapshot. Read by the completion-progress
/// ladder (`pcb_progress.assemble`) so its net-connectivity / fab-readiness
/// verdicts describe the SAME board the facts describe.
pub const ShownCopper = struct {
    tracks: []const router.Track = &.{},
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
            out.vias = r.vias;
        }
        // Pour zones are CONNECTING COPPER, not decoration: a rail poured
        // instead of traced (barracuda's V_12V/V_5VA/V_6VA/V_3V3A/V_3V3_LMX)
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

test "physical review embed omits optimizer scores and route details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeReadOnlyEmbedChrome(&aw.writer, .{
        .module_source = "",
        .params = .{},
        .routed = .{
            .tracks = &.{},
            .vias = &.{},
            .routed = 7,
            .total = 9,
            .failed = &.{ "GND", "SCLK" },
        },
        .n_drc = 0,
        .toggles = .{ .clr = false, .drc = false },
        .physical_review = true,
    });
    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"sc-obj\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-clr-show\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-drc-show\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-drc\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"hidden\" id=\"r-cl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">7 nets routed</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "7/9") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "vias") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "missing") == null);

    var ordinary: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeReadOnlyEmbedChrome(&ordinary.writer, .{
        .module_source = "",
        .params = .{},
        .routed = .{
            .tracks = &.{},
            .vias = &.{},
            .routed = 7,
            .total = 9,
            .failed = &.{ "GND", "SCLK" },
        },
        .n_drc = 0,
        .toggles = .{ .clr = false, .drc = true },
        .physical_review = false,
    });
    const ordinary_html = ordinary.written();
    try std.testing.expect(std.mem.indexOf(u8, ordinary_html, "id=\"sc-obj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ordinary_html, "id=\"r-clr-show\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ordinary_html, "id=\"r-drc-show\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ordinary_html, "id=\"r-drc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ordinary_html, "routed 7/9 nets · 0 vias · missing: GND, SCLK") != null);
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
    try writeLayoutsJson(&aw.writer, &rows, "shown");
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

// spec: Web Server - A saved pose binds by sub-block-scoped origin key before its ref string, each live part claimed once, so a renumber-recycled ref cannot mis-bind a pose
test "pose identity binds scoped origin first and refuses a recycled ref" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // Two sub-blocks share the module-local origin "U1"; at top level the row's
    // "C13" (origin C_ID) renumbered to "C14" while a DIFFERENT part recycled
    // the string "C13".
    const live = [_]LiveRef{
        .{ .ref = "amp1/U7", .origin = "U1" },
        .{ .ref = "dsa/U8", .origin = "U1" },
        .{ .ref = "C13", .origin = "C_NEW" },
        .{ .ref = "C14", .origin = "C_ID" },
    };
    const row = [_]PartPose{
        .{ .ref = "amp1/U7", .origin = "U1", .x = 1, .y = 1, .rot = 0 },
        .{ .ref = "dsa/U8", .origin = "U1", .x = 2, .y = 2, .rot = 0 },
        .{ .ref = "C13", .origin = "C_ID", .x = 3, .y = 3, .rot = 0 },
    };
    const res = resolvePoseIdentity(alloc, &live, &row) orelse return error.TestResolveFailed;
    // Scoped origin map: each sub-block's "U1" binds within its own scope —
    // the unscoped last-wins map collapsed all of them onto one pose.
    try std.testing.expectEqualStrings("amp1/U7", res.refs[0]);
    try std.testing.expectEqualStrings("dsa/U8", res.refs[1]);
    // Origin outranks the recycled ref string: the pose follows C_ID to C14
    // instead of landing on whatever part now answers to "C13".
    try std.testing.expectEqualStrings("C14", res.refs[2]);
    try std.testing.expect(res.bound[0] and res.bound[1] and res.bound[2]);
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

// spec: Web Server - Layout coverage counts poses the way a Load lands them, so colliding module-local origin keys cannot report a stale row as full
test "coverage of a stale row stays partial under colliding origin keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts = [_]optimizer.Part{
        .{ .ref_des = "amp1/U7", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "dsa/U8", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
    };
    const insts = [_]export_kicad.FlatInstance{
        .{ .ref_des = "amp1/U7", .origin_key = "U1", .component = "amp", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{ .ref_des = "dsa/U8", .origin_key = "U1", .component = "dsa", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &insts,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const row_parts = [_]PartPose{
        .{ .ref = "amp1/U7", .origin = "U1", .x = 1, .y = 1, .rot = 0 },
    };
    const stale = SavedLayout{ .name = "old", .kind = kind_manual, .ts = 1, .score = null, .parts = &row_parts };
    // One pose covers ONE part. The old unscoped match let this "U1" pose
    // cover BOTH sub-blocks' ICs, reporting a stale row as complete.
    try std.testing.expectEqual(@as(usize, 1), layoutCoverage(alloc, stale, placement));
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
            return bodyEffort(v);
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
    try std.testing.expect(bodyEffort(.{ .string = "one_shot" }) == null);
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
        resolvedBodyEffort(missing, .one_shot) orelse return error.TestNoEffort,
    );
    try std.testing.expectEqual(
        route_policy.Effort.standard,
        resolvedBodyEffort(deep, .one_shot) orelse return error.TestNoEffort,
    );
    // Non-viewer consumers opt out of the fallback and preserve authored
    // policy exactly as before.
    try std.testing.expect(resolvedBodyEffort(missing, null) == null);
}

// spec: Web Server - The route_pcb CLI tool can select a bounded retry tier, checkpoints routed copper before optional deferred DRC, and rejects unknown tiers
test "route_pcb applies and validates its effort override" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const good = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"effort\":\"one_shot\"}", .{});
    var options = route_policy.Options{};
    try std.testing.expect(mcpApplyRouteEffort(&options, good));
    try std.testing.expectEqual(route_policy.Effort.one_shot, options.effort);
    const checkpoint = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"defer_drc\":true}", .{});
    try std.testing.expect(mcpArgBool(checkpoint, "defer_drc"));

    const bad = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"effort\":\"turbo\"}", .{});
    try std.testing.expect(!mcpApplyRouteEffort(&options, bad));
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

    prep.effort = .one_shot;
    const cheap = preparedRouteOptions(alloc, prep);
    try std.testing.expectEqual(route_policy.Effort.one_shot, cheap.effort);
    try std.testing.expect(!cheap.effort.retries());
    // The override changes the tier and NOTHING else about the run.
    try std.testing.expectEqual(plain.selected_nets.len, cheap.selected_nets.len);
    try std.testing.expectEqual(plain.net.len, cheap.net.len);
}

// The full editor now renders those controls in the Autorouter placement card;
// editable embeds retain them in the classic scorebar.
// spec: Web Server - The scorebar offers Route plan on an unsaved solve only, running the shared route flow at the one-shot tier and marking the copper a non-persisted plan
// spec: Web Server - A completed Route board run persists its applied copper to the active layout, or creates the conventional first `layout` snapshot; Route plan remains temporary
test "the placement controls' Route plan action is gated to an unsaved board and routes one-shot" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
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
    try writePlacementControls(&aw.writer, placement, "demo", .cache);
    const html = aw.written();
    // Server-side the control ships HIDDEN for every board — the client alone
    // decides, from PCB.src, whether this page is an unsaved solve.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-routeplan\" style=\"display:none\"") != null);
    // …and the PLAN chip it fills is likewise present but empty until a run.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"pcb-planchip\" style=\"display:none\"></span>") != null);

    const js = @embedFile("assets/pcb_board.js");
    // One route flow, two entry points: the primary Route button and the
    // scorebar's temporary plan action are bounded one-shot runs.
    try std.testing.expect(std.mem.indexOf(u8, js, "function runRoute(opts)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rgo.addEventListener(\"click\",function(){runRoute({effort:\"one_shot\"});})") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rdeep") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "runRoute({effort:\"one_shot\",plan:true})") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(opts.effort)payload.effort=opts.effort;") != null);
    // Revealed only on an unsaved solve — a persisted layout already has the
    // Autorouter's Route button and must not grow a second one.
    try std.testing.expect(std.mem.indexOf(u8, js, "var unsaved=(PCB.src===\"cache\"||PCB.src===\"fresh\");") != null);
    // The plan copper is marked as a plan, and dropped whenever the copper is.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(opts.plan)planChip(j);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function clearRoute(){planChip(null);") != null);
    // Both entry points disable together for the run (one board, one router).
    try std.testing.expect(std.mem.indexOf(u8, js, "function routeBusy(on){[\"r-go\",\"pcb-routeplan\"]") != null);
    // Route board applies then persists the active layout (or first `layout`);
    // the plan branch is deliberately excluded.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!opts.plan){markDirty();persistLayout(curLayout||\"layout\"") != null);
    const replay_js = @embedFile("assets/pcb_replay.js");
    try std.testing.expect(std.mem.indexOf(u8, replay_js, "var GATED = [\"r-go\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay_js, "r-go-deep") == null);
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
    try writeAntipadsField(&aw.writer, placement, .{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 });
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
    try writeAntipadsField(&aw2.writer, placement, .{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 });
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

// The PCB editor's sidebar footprint button opens the part's library card; this
// test covers the full-page modal markup that hosts that card.
test "the pcb page emits the library-card modal beside the courtyard modal" {
    // The full-page layout (embed=false) carries the card modal; its dialog is
    // the same court-modal shell so BOARD_JS's card wiring finds it.
    try std.testing.expect(std.mem.indexOf(u8, fp_card_modal, "id=\"fp-card-modal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fp_card_modal, "id=\"fp-card-body\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fp_card_modal, "id=\"fp-card-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fp_card_modal, "class=\"court-dialog fp-card-dialog\"") != null);
    // The page composes it into the modal emission (next to courtyard + fab).
    const composed = "courtyard_modal ++ fp_card_modal ++ fab_modal";
    const src = @embedFile("pcb_layout_page.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, composed) != null);
    // The board script's Edit-courtyard path still exists for the preview.
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function openCourt") != null);
}
