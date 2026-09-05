//! The PCB editor page's chrome: every HTML fragment and CSS asset that frames
//! the board, and nothing that computes one.
//!
//! Split out of `pcb_layout_page.zig` because the page is two jobs wearing one
//! file. This half owns markup — the toolstrip, status bar, scorebar, side
//! tabs, sidebar panes, route/replay/stuck docks, the embed chrome, the modals
//! and the stylesheets — and its only inputs are a `std.Io.Writer` and already
//! solved data. It never reads a request, never touches the sidecar and never
//! decides what the board is; `pcb_layout_page.zig` resolves all of that and
//! calls in.
//!
//! The one rule that matters here: everything written into HTML goes through
//! `escape.writeXml` (aliased `writeEscaped`) or a JSON string writer. A
//! `</script>` in a net name has broken this page before.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const board_theme = @import("../board_theme.zig");
const optimizer = @import("../placement/optimizer.zig");
const escape = @import("../escape.zig");
const assets_css = @import("assets_css.zig");
const shape_sketch_json = @import("shape_sketch_json.zig");
const net_names = @import("../net_name.zig");
const na = @import("../eval/net_analysis.zig");
const sidecar_types = @import("../layout_sidecar_types.zig");
const page = @import("pcb_layout_page.zig");
const router = @import("../placement/router.zig");
const export_gerber = @import("../export_gerber.zig");
const export_kicad = @import("../export_kicad.zig");
const fab_readiness = @import("../fab_readiness.zig");
const module_policy = @import("../placement/module_policy.zig");
const numeric = @import("../numeric.zig");
const sidecar_store = @import("../layout_sidecar_store.zig");
const sidecar_json = @import("layout_sidecar_json.zig");

const SavedLayout = sidecar_types.SavedLayout;
const LayoutScore = sidecar_types.LayoutScore;
const HandlerError = page.HandlerError;
const LayoutSource = page.LayoutSource;
const View = page.View;
const writeEscaped = escape.writeXml;
const shortName = net_names.leaf;
const netKey = na.baseNetName;
const kind_manual = sidecar_store.kind_manual;
const writeJsonStr = sidecar_json.writeJsonStr;
const kindStr = page.kindStr;
const liveOfPlacement = page.liveOfPlacement;
const writePageScripts = page.writePageScripts;
const resolvePoseIdentity = @import("pose_identity.zig").resolve;
const net_json_key = page.net_json_key;
const Toggles = page.Toggles;
const writeUrlEncoded = page.writeUrlEncoded;
const PartPose = sidecar_types.PartPose;

/// The ` checked` HTML attribute fragment, emitted to pre-check a checkbox.
const checked_glyph = " checked";

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

/// The editable control stack shared by the full page and the editable embed
/// (`?embed=1&edit=1`): the action toolbar (Regenerate / Rough / Save as… /
/// Update / Undo / Redo / Reset / zoom), the collapsible route/stuck panels,
/// and the hidden legends (revealed by their chips). The full page prepends its
/// own header (title + Schematic⇄PCB nav); the editable embed skips that — its
/// parent schematic card carries the Schematic/PCB toggle instead.
pub fn writeEditControls(
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
    try writeEscaped(w, name);
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
    try writeEscaped(w, name);
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
    // RF finishing — rebuild and save the active layout's pad tapers before
    // POSTing /api/pcb-fence, so the regenerated fence follows that exact
    // variable-width copper, then fill the remaining board with the generated
    // ground-stitch lattice. Always visible: board-edge perimeter fencing is
    // unrelated and the endpoint explains boards with no fenceable classes.
    try w.writeAll("<button class=\"btn\" id=\"pcb-fence\" title=\"Refresh RF trace widths and ground gaps without moving their paths, " ++
        "rebuild and save their tapers, regenerate the RF ground via fence, then add a DRC-safe board-wide GND stitching grid\">\u{21bb} Tapers + fence</button>");
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
        try w.writeAll("<button class=\"btn\" id=\"pcb-via\" title=\"" ++ tip_via ++ "\">\u{2299} Via</button>");
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

const tip_via = "Place standalone vias (Shift+V): choose a net in the status bar, or click a pad / existing copper to pick its net, then click the board to place DRC-checked vias without drawing traces. Esc or right-click exits. Copper is saved with the layout (Save/Update).";

const tip_text = "Silkscreen text (T): click on the board to place a label " ++
    "(grid-snapped, on the active side). In Select or Text mode, click an existing label to edit it and drag it to " ++
    "move it, R rotates 90\u{b0}, Del or right-click deletes. Saved with the layout (Save/Update); emitted on the silk " ++
    "Gerber.";

const tip_backing = "Edit fabrication backing regions with the shared shape-sketch palette: lines/arcs, dimensions, constraints, fillet, chamfer, offset and mirror. " ++
    "The authored side, material, thickness, and automatic footprint cutouts remain unchanged. Saved with the layout and emitted in its named Gerber.";

const tip_heatsink = "Draw or edit a physical heatsink or two-block cold plate. Drag its PCB-contact body to move it, drag corner handles to resize it, or click it to edit its face, material, fin/second-block dimensions, and thermal pad. On a populated face it contacts covered package lids through declared theta-JC-top; on an unobstructed face its pad contacts the PCB. Saved with the layout; the thermal ladder and 3D view use it.";

const tip_fan = "Place or edit an axial fan. Drag its circular footprint to move it, drag corner handles to resize its outlet, or click it to edit the PCB face, outlet-to-target distance, and airflow specifications. The target is the heatsink outer face when a sink shares that face, otherwise the PCB. Saved with the layout and used by the fan thermal scenario.";

const tip_ruler = "Ruler / dimension (D): drag to measure, or select a footprint first and drag its origin to a straight board edge to create a driving dimension.";

const tip_move = "Move the selection by an X/Y distance (M): select footprints, tracks, vias, or outline-sketch geometry, then press M (or this button) and type how far to move it; one undo step.";

const pad_align_tool_html = @embedFile("assets/pcb_pad_align_tool.html");

const alignment_tools_html = @embedFile("assets/pcb_alignment_tools.html");

/// KiCad-style vertical drawing toolbar, docked on the canvas' left edge
/// (full page only). Every button keeps the id the board script already
/// wires: select is the new explicit "disarm all modes" tool; the rest are
/// the same tools that used to sit in the action bar.
pub const toolstrip_html =
    "<div class=\"pcb-toolstrip\" id=\"pcb-toolstrip\">" ++
    "<button class=\"ts-btn on\" id=\"tool-select\" title=\"Select / move (Esc) — drag parts or silkscreen text, marquee-select on empty board\">\u{2196}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-draw\" title=\"" ++ tip_draw ++ "\">\u{270E}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-via\" title=\"" ++ tip_via ++ "\">\u{2299}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-outline\" title=\"" ++ tip_outline ++ "\">\u{25AD}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-outline-poly\" title=\"" ++ tip_poly ++ "\">\u{2B21}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-backing\" title=\"" ++ tip_backing ++ "\">\u{25A7}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-heatsink\" title=\"" ++ tip_heatsink ++ "\">\u{2668}</button>" ++
    "<button class=\"ts-btn\" id=\"pcb-fan\" title=\"" ++ tip_fan ++ "\">\u{25C9}</button>" ++
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
    "title=\"Active renderer — WebGPU where available; Assembly requires WebGPU (?gpu=0 opts only the editor into 2D)\"></span>" ++
    "<span class=\"st-seg st-tool\" id=\"st-tool\"></span><label class=\"st-seg st-bend\" id=\"st-bend\" hidden title=\"Manual trace bend angle (E toggles while routing)\">bend <select id=\"pcb-bend-angle\" aria-label=\"Manual trace bend angle\"><option value=\"45\">45\u{b0}</option><option value=\"90\">90\u{b0}</option></select></label>" ++
    "<label class=\"st-seg st-via\" id=\"st-via\" hidden title=\"Electrical net assigned to newly placed vias\">via net <select id=\"pcb-via-net\" aria-label=\"Standalone via net\"></select></label>" ++
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

// spec: Web Server - The PCB editor places repeated standalone vias on a chosen net without creating trace segments, using grid/copper snapping, net-class geometry, the live DRC gate, and one undo step per via
test "PCB editor ships a standalone manual via tool" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, toolstrip_html, "id=\"pcb-via\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tip_via, "without drawing traces") != null);
    try std.testing.expect(std.mem.indexOf(u8, statusbar_html, "id=\"pcb-via-net\"") != null);
    for ([_][]const u8{
        "function viaModeSet(on)",
        "function viaSnap(m,net)",
        "function viaPlaceAt(m)",
        "var q=viaSnap(m,viaNet),vg=viaGeo(viaNet);",
        "if(viaViolation(q.x,q.y,viaNet,vg.dia,vg.drill))",
        "if(drcGateBlocks(null,[cand]))",
        "recordUndo();rfDropNet(viaNet);PCB.vias=PCB.vias||[];PCB.vias.push(cand);scheduleDrc();",
        "if(viaMode&&ev.button===0){viaPlaceAt(mm(ev));return;}",
        "Shift+V / ⊙ Via",
    }) |marker| try std.testing.expect(std.mem.indexOf(u8, js, marker) != null);
}

// spec: Web Server - M opens a move-by-distance dialog for mixed footprints/copper or selected outline geometry (X and/or Y in the current units, one undo step) and D arms the ruler/measure tool
test "M binds the move-by-distance dialog and D binds the ruler, and the toolstrip ships a Move button" {
    const js = @embedFile("assets/pcb_board.js");
    // M is the move command (a dialog), D is the measure tool — the ruler's
    // old M binding must be gone, and the move dialog must exist to be armed.
    try std.testing.expect(std.mem.indexOf(u8, js, "(ev.key===\"m\"||ev.key===\"M\")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();rulerArm(!rulerMode);return;}") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "(ev.key===\"d\"||ev.key===\"D\")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();rulerArm(!rulerMode);return;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "(ev.key===\"m\"||ev.key===\"M\")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();moveDialog();return;}") != null);
    // One shared delta moves explicit copper independently, including a
    // copper-only selection, without letting carried/private copper move twice.
    try std.testing.expect(std.mem.indexOf(u8, js, "function moveEntities(ents,deltas,banded)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "shiftCopper(band,deltas[0].dx,deltas[0].dy)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!deltas.length)deltas.push({dx:dx,dy:dy})") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "commitMove(moved,target.copper.t.length+target.copper.v.length)") != null);
    // Outline selection wins while its sketch editor is active and goes
    // through the constraint-aware batch mover and normal sketch undo seam.
    try std.testing.expect(std.mem.indexOf(u8, js, "function moveOutlineActive()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "cs.length===1?OS.moveCurve(sk,cs[0],dx,dy):OS.moveGeometry(sk,ps,cs,dx,dy)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "move blocked — the selected sketch geometry is fixed or fully constrained") != null);
    // The toolstrip ships the Move button the script wires by id.
    try std.testing.expect(std.mem.indexOf(u8, toolstrip_html, "id=\"pcb-move-btn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolstrip_html, "id=\"pcb-ruler-btn\"") != null);
    // Tooltips name the NEW keys so a user pressing M finds the move dialog.
    try std.testing.expect(std.mem.indexOf(u8, tip_ruler, "Ruler / dimension (D)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tip_move, "Move the selection by an X/Y distance (M)") != null);
}

// V opens the PCB View sidebar unless an active trace needs it to drop a via,
// while outline sketches retain their vertical constraint shortcut.
test "V opens the View sidebar outside an active trace or outline sketch" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "if(dtrace&&(ev.key==\"v\"||ev.key==\"V\")){ev.preventDefault();drawViaHere();if(dtrace)drawAutoSchedule(false,false);return;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(dtrace||viaMode||outlineMode||activeSketchIsArea())return;") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, js, "else{var snap=rulerCamSnap(m);rulerDraw.b=snap||m;rulerDraw.snap=!!snap;}rulerDrawNow(rulerDraw.a,rulerDraw.b,rulerDraw);") != null);
}

// spec: Web Server - With one footprint selected, D authors a persistent driving dimension from that footprint origin to a perpendicular straight outline edge
test "D drives a selected footprint origin from a stable outline edge" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "a=p?{x:p.x,y:p.y}:(snap||m)") != null);
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
    try writeEscaped(w, design);
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
pub const PanelData = struct {
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
    try writeEscaped(w, ctx.name);
    if (ctx.sub) |sub| {
        try w.writeAll("?sub=");
        try writeEscaped(w, sub);
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
        try writeEscaped(w, L.name);
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
        try writeEscaped(w, L.name);
        try w.writeAll("\" title=\"");
        try w.writeAll(if (L.default)
            "Default layout — the KiCad sync seeds new parts (placement + GND vias) from this. Click to clear."
        else
            "Make this the KiCad-sync default (seeds new parts' placement + GND vias)");
        try w.writeAll("\">");
        try w.writeAll(if (L.default) "★" else "☆");
        try w.writeAll("</button><button class=\"btn lay-go\" data-lay-load=\"");
        try writeEscaped(w, L.name);
        try w.writeAll("\">Load</button><button class=\"btn lay-rename\" title=\"Rename\" data-lay-rename=\"");
        try writeEscaped(w, L.name);
        try w.writeAll("\">Rename</button><button class=\"btn lay-del\" title=\"Delete\" data-lay-del=\"");
        try writeEscaped(w, L.name);
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
pub fn writeLinks(w: *std.Io.Writer, links: []const optimizer.Link, rules: optimizer.BoardRules) std.Io.Writer.Error!void {
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
pub fn writeNetColors(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) HandlerError!void {
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
pub fn writeNetNames(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) HandlerError!void {
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
pub fn writeDocHead(w: *std.Io.Writer, title: []const u8, embed: bool, edit_embed: bool) std.Io.Writer.Error!void {
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
        try writeEscaped(w, module_source);
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

pub const ReadOnlyEmbedChrome = struct {
    module_source: []const u8,
    params: router.RouteParams,
    routed: ?router.RouteResult,
    n_drc: usize,
    toggles: Toggles,
    physical_review: bool,
};

pub fn writeReadOnlyEmbedChrome(w: *std.Io.Writer, o: ReadOnlyEmbedChrome) std.Io.Writer.Error!void {
    if (!o.physical_review) try writeEmbedBar(w, o.module_source);
    try writeEmbedRoute(w, o.params, o.routed, o.n_drc, .{
        .toggles = o.toggles,
        .show_toggles = !o.physical_review,
        .show_drc_status = !o.physical_review,
        .show_route_status = !o.physical_review,
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
        show_route_status: bool = true,
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
    if (!display.show_route_status) return w.writeAll("</div>");
    if (routed) |r| {
        const cls = if (r.routed == r.total) "ok" else "warn";
        try w.print("<span class=\"route-stat {s}\" id=\"r-stat\">routed {d}/{d} nets · {d} vias", .{ cls, r.routed, r.total, r.vias.len });
        if (r.failed.len > 0) {
            try w.writeAll(" · missing: ");
            for (r.failed, 0..) |fname, i| {
                if (i > 0) try w.writeAll(", ");
                try writeEscaped(w, fname);
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

pub fn writeLegend(w: *std.Io.Writer, p: optimizer.Placement, hidden: bool) std.Io.Writer.Error!void {
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

/// Everything the docked left column needs beyond the placement itself.
pub const SidebarOpts = struct {
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
pub fn writeSidebar(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement, sch_base: []const u8, o: SidebarOpts) HandlerError!void {
    try w.writeAll("<aside class=\"pcb-side\" id=\"pcb-side\"><button class=\"dock-close\" type=\"button\" data-dock-close title=\"Close panel\" aria-label=\"Close panel\">×</button>");
    try writeSideTabs(w);
    try w.writeAll("<div class=\"side-pane\" id=\"side-props\" hidden>");
    try w.writeAll(alignment_tools_html);
    try w.writeAll("<div id=\"prop-body\" class=\"prop-body\" data-schbase=\"");
    try writeEscaped(w, sch_base);
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
        "<button class=\"btn\" id=\"pcb-fence\" title=\"Refresh RF trace widths and ground gaps without moving their paths, rebuild and save their tapers, regenerate the RF ground via fence, then add a DRC-safe board-wide GND stitching grid\">↻ Tapers + fence</button></div>");
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
pub fn writeActivityRail(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<nav class=\"pcb-activity\" aria-label=\"Editor panels\">" ++
        "<button type=\"button\" data-dock-pane=\"side-find\" title=\"Find parts, nets and DRC (Ctrl+F)\"><span aria-hidden=\"true\">⌕</span><small>Find</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-props\" title=\"Selection properties\"><span aria-hidden=\"true\">ⓘ</span><small>Inspect</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-route\" title=\"Placement, autorouter and saved layouts\"><span aria-hidden=\"true\">⚡</span><small>Route</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-drc\" title=\"Design-rule violations\"><span aria-hidden=\"true\">△</span><small>DRC</small></button>" ++
        "<button type=\"button\" data-dock-pane=\"side-subs\" title=\"Sub-circuit palette\"><span aria-hidden=\"true\">▦</span><small>Blocks</small></button>" ++
        "<span class=\"activity-spacer\"></span>" ++
        "<button type=\"button\" data-dock-appearance title=\"Layers and objects\"><span aria-hidden=\"true\">▤</span><small>View</small></button></nav>");
}

/// Full-page header row: title + the board-view switcher (PCB active).
/// Physical board designs also link to Assembly and the board Review page;
/// reusable modules retain the schematic/layout/3D/thermal surfaces only.
/// `name` resolves as a design under src/ first, else a reusable module — the
/// Schematic link points at the matching viewer.
pub fn writeHeadNav(
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
    if (!is_module) {
        try w.print("<a href=\"/review/{s}", .{name});
        if (layout) |selected| {
            try w.writeAll("?layout=");
            try writeUrlEncoded(w, selected);
        }
        try w.writeAll("\">Review</a>");
    }
    try w.writeAll("</nav>");
    try w.writeAll("</div>");
}

/// The board stage: a vertical tool strip (full page only) docked on the
/// canvas' left edge, the canvas host (SVG + scene canvas), and a KiCad
/// status bar underneath. Embeds keep the bare stage (no strip/status).
pub fn writeStage(w: *std.Io.Writer, view: View, embed: bool) std.Io.Writer.Error!void {
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
pub fn writeRightDock(
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

/// Two closing divs — shared by the stage, layouts-panel and sidebar writers.
const div2_end = "</div></div>";

/// Hidden-by-default overlay; populated + shown by BOARD_JS when a sidebar
/// footprint button is clicked. Edits the courtyard half-extents on the grid.
pub const courtyard_modal =
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

pub const cooling_modals = @embedFile("assets/pcb_cooling_modals.html");

/// Hidden-by-default overlay; BOARD_JS fills it from `/api/library-card/:name`
/// when the sidebar footprint button is clicked. Shows the SAME card as the
/// library page (component name, description, datasheet links, footprint
/// preview → Edit courtyard, 3D-model drag-in and alignment badge), so every
/// library action is reachable from the layout. Reuses the court-modal shell.
pub const fp_card_modal =
    \\<div id="fp-card-modal" class="court-modal" hidden><div class="court-dialog fp-card-dialog">
    \\<div class="court-h"><span id="fp-card-title">Library card</span><button id="fp-card-x" class="court-x" title="Close">×</button></div>
    \\<div id="fp-card-body" class="fp-card-body"></div>
    \\</div></div>
;

/// Hidden-by-default overlay populated by BOARD_JS when the ⤓ Gerbers button
/// receives the revision-locked release report. Every package requires an
/// explicit confirmation; remaining findings make that action a recorded
/// waiver. Reuses the court-modal styling.
pub const fab_modal =
    \\<div id="fab-modal" class="court-modal" hidden><div class="court-dialog fab-dialog">
    \\<div class="court-h"><span id="fab-title">Fab readiness</span><button id="fab-x" class="court-x" title="Close">×</button></div>
    \\<div id="fab-body" class="fab-body"></div>
    \\<div class="court-actions"><button id="fab-go" class="btn">Confirm release and export</button>
    \\<button id="fab-cancel" class="btn">Cancel</button></div>
    \\</div></div>
;

pub const pad_align_css = @embedFile("assets/pcb_pad_align.css");

pub const page_css = @embedFile("assets/pcb_layout.css");

pub const mobile_css = @embedFile("assets/pcb_mobile.css");

/// Extra rules layered on top of PAGE_CSS only when `?embed=1` — the body gets
/// the `embed` class. Strips outer padding, lets the board fill the frame
/// width, and drops the grab cursor (no dragging in the read-only preview).
pub const embed_css =
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
    \\body.embed.mode-3d .pcb-layout{height:100vh;min-height:0}
    \\body.embed.mode-3d .pcb-main{height:100%}
    \\body.embed.mode-3d .pcb-3d-stage{min-height:0}
;

/// The (hidden) WebGL stage for the 3D-view tab: a canvas, a status overlay,
/// and a floating toolbar (camera presets + layer toggles). CSS `.mode-3d`
/// reveals it and hides the 2D board; `pcb_3d_viewer.js` builds the scene.
pub const pcb_3d_stage_html =
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
    \\<button class="btn" id="pcb3d-export-step" title="Download the analytic green PCB solid with native rounded corners, mounting holes, exact component B-reps, and the heatsink when enabled">Export STEP</button>
    \\<span class="sep"></span>
    \\<label><input type="checkbox" id="pcb3d-t-models" checked>Models</label>
    \\<label><input type="checkbox" id="pcb3d-t-surface" checked>Surfaces</label>
    \\<label><input type="checkbox" id="pcb3d-t-board" checked>Board</label>
    \\<label title="Uncheck to hide and exclude the heatsink from STEP export"><input type="checkbox" id="pcb3d-t-heatsink" checked>Heatsink</label>
    \\<label><input type="checkbox" id="pcb3d-t-fan" checked>Fan</label>
    \\<label><input type="checkbox" id="pcb3d-t-axes" checked>Axes</label>
    \\</div></div>
;

/// Tab wiring for the Schematic ⇄ PCB Layout ⇄ 3D View switcher. Toggling to
/// 3D adds `.mode-3d` (CSS swaps in the stage), then lazily injects the WebGL
/// stack (Three.js + OrbitControls + occt-import-js) and our viewer before
/// calling `PCB3D.init()` — so the heavy assets load only when 3D is opened.
/// The PCB Layout tab flips back to 2D in place (no reload) when 3D is active.
pub const pcb_3d_toggle_js =
    \\<script>(function(){
    \\var tab3d=document.getElementById("pcb-tab-3d"),tab2d=document.getElementById("pcb-tab-2d");
    \\var loaded=false,loading=null;
    \\function loadScript(src){return new Promise(function(res,rej){
    \\ var s=document.createElement("script");s.src=src;s.onload=res;
    \\ s.onerror=function(){rej(new Error("load "+src));};document.head.appendChild(s);});}
    \\function ensure(){
    \\ if(loaded)return Promise.resolve();
    \\ if(loading)return loading;
    \\ var seq=Promise.resolve();
    \\ ["/static/three.min.js","/static/OrbitControls.js","/static/pcb_3d_surface.js","/static/pcb_step_export.js","/static/pcb_3d_viewer.js"]
    \\  .forEach(function(u){seq=seq.then(function(){return loadScript(u);});});
    \\ loading=seq.then(function(){loaded=true;});
    \\ return loading;}
    \\function setViewQuery(mode){try{var u=new URL(location.href);
    \\ if(document.body.classList.contains("embed"))return;
    \\ if(mode)u.searchParams.set("view",mode);else u.searchParams.delete("view");
    \\ history.replaceState(null,"",u.pathname+(u.searchParams.toString()?"?"+u.searchParams.toString():"")+u.hash);}catch(e){}}
    \\function show3d(){
    \\ document.body.classList.add("mode-3d");
    \\ if(tab3d)tab3d.classList.add("active");if(tab2d)tab2d.classList.remove("active");
    \\ setViewQuery("3d");
    \\ ensure().then(function(){
    \\  if(window.PCB3D){window.PCB3D.init();
    \\   requestAnimationFrame(function(){window.PCB3D.onShow();});}
    \\ }).catch(function(e){console.error(e);
    \\  var st=document.getElementById("pcb-3d-status");
    \\  if(st){st.textContent="3D assets failed to load";st.className="err";}});}
    \\function show2d(){
    \\ document.body.classList.remove("mode-3d");
    \\ if(tab2d)tab2d.classList.add("active");if(tab3d)tab3d.classList.remove("active");setViewQuery("");}
    \\window.PCB3DView={show3d:show3d,show2d:show2d};
    \\window.addEventListener("message",function(ev){var d=ev.data;
    \\ if(ev.origin!==window.location.origin||!d||d.type!=="netlisp-pcb-view")return;
    \\ if(d.view==="3d")show3d();else show2d();});
    \\if(tab3d)tab3d.addEventListener("click",function(e){e.preventDefault();show3d();});
    \\if(tab2d)tab2d.addEventListener("click",function(e){
    \\ if(document.body.classList.contains("mode-3d")){e.preventDefault();show2d();}});
    \\try{if(new URLSearchParams(location.search).get("view")==="3d")show3d();}catch(e){}
    \\})();</script>
;

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

// spec: Web Server - The Assembly physical-review embed omits optimizer, DRC, and route-status reporting while retaining the hidden route geometry inputs its read-only painter consumes
test "physical review embed omits optimizer scores and route reporting" {
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
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"r-stat\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"hidden\" id=\"r-cl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "nets routed") == null);
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
    const composed = "fp_card_modal ++ pcb_layout_chrome.fab_modal";
    const src = @embedFile("pcb_layout_page.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, composed) != null);
    // The board script's Edit-courtyard path still exists for the preview.
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function openCourt") != null);
}
