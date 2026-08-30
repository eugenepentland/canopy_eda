"use strict";

// Every non-API GET route registered by src/serve.zig must be represented
// here. Runnable surfaces are exercised by run.js; redirects, raw responses,
// and the assembly page's deeper dedicated benchmark are explicit so a new UI
// route cannot silently land outside the browser performance gate.
const routes = {
  "/": { coverage: "surface", surface: "home" },
  "/schematics/:name": { coverage: "surface", surface: "schematic" },
  "/modules/:name": { coverage: "surface", surface: "module" },
  "/pcb-layout/:name": { coverage: "surfaces", surfaces: ["pcb_2d", "pcb_3d"] },
  "/assembly-debug/:name": {
    coverage: "delegated",
    runner: "scripts/pcb_browser_perf/run.js",
    scenarios: [
      "exact_cam_ready", "search", "type_filter", "show_dnp", "bom_select", "selection_clear",
      "panel_navigation", "cam_review", "cam_layer_visibility", "board_side", "rotate", "model_3d_navigation",
      "pan", "zoom",
    ],
  },
  "/thermal/:name": { coverage: "surface", surface: "thermal" },
  "/library": { coverage: "surface", surface: "library" },
  "/library/footprint/:name": { coverage: "surface", surface: "footprint_editor" },
  "/library/3d/:footprint": { coverage: "surface", surface: "model_alignment_3d" },
  "/route-review": { coverage: "surface", surface: "route_review" },
  "/pdf-view/:filename": { coverage: "surface", surface: "pdf_viewer" },
  "/datasheets/:filename": { coverage: "response", scenario: "datasheet_response" },
  "/modules": { coverage: "redirect", scenario: "modules_redirect" },
  "/pcb-route-lab/:name": { coverage: "redirect", scenario: "route_lab_redirect" },
  "/style.css": { coverage: "asset", reason: "shared stylesheet, not an interactive page" },
  "/static/:name": { coverage: "asset", reason: "static asset dispatcher, not an interactive page" },
  "/.well-known/oauth-protected-resource": { coverage: "metadata", reason: "OAuth discovery document, not an interactive page" },
  "/systems/:name": { coverage: "surface", surface: "system_review" },
  "/systems/:name/dossier": {
    coverage: "uncovered",
    reason: "The draft dossier is a script-free, server-composed document with no interactions to time: its whole cost is the system package composer's per-request analysis (every board's review snapshot and fabrication readiness), so measuring it here would time the composer through a browser rather than the UI, and doing so needs a release-ready system fixture this gate does not carry.",
  },
};

const surfaces = [
  {
    id: "home",
    label: "Designs home",
    path: "/",
    ready: "#home-grid",
    scenarios: [
      { id: "search", kind: "local" },
      { id: "filter", kind: "local" },
      { id: "new_design_dialog", kind: "local" },
      // Keep this last: home starts layout progress in the background, and a
      // fresh context must not abandon those CPU-heavy requests on teardown.
      { id: "progress_hydration", kind: "async", budgets: { p95_ms: 25000, max_ms: 25000 } },
    ],
  },
  {
    id: "schematic",
    label: "Board schematic",
    path: "/schematics/barracuda-base",
    ready: "#sch-search",
    scenarios: [
      { id: "search", kind: "local" },
      { id: "diagram_tab", kind: "local" },
      { id: "source_editor", kind: "async", budgets: { p95_ms: 300, max_ms: 500 } },
      { id: "erc", kind: "async", budgets: { p95_ms: 300, max_ms: 500 } },
      { id: "pan", kind: "frame", setup: ["diagram_tab"] },
      { id: "zoom", kind: "frame", setup: ["diagram_tab"] },
      { id: "view_switch", kind: "async", budgets: { p95_ms: 750, max_ms: 1000 } },
    ],
  },
  {
    id: "module",
    label: "Standalone module schematic",
    path: "/modules/lt3045",
    ready: "#sch-search",
    scenarios: [
      { id: "search", kind: "local" },
      { id: "detail_pick", kind: "local" },
      { id: "source_editor", kind: "async", budgets: { p95_ms: 300, max_ms: 500 } },
      { id: "erc_feedback", kind: "async", budgets: { p95_ms: 300, max_ms: 500 } },
    ],
  },
  {
    id: "pcb_2d",
    label: "PCB layout 2D",
    path: "/pcb-layout/barracuda-base?gpu=0",
    ready: ".pcb-scene",
    scenarios: [
      { id: "find", kind: "local" },
      { id: "side_panel", kind: "local" },
      { id: "appearance", kind: "local" },
      { id: "layout_load", kind: "async", budgets: { p95_ms: 2000, max_ms: 2500 } },
      {
        id: "layout_save",
        kind: "async",
        budgets: { p95_ms: 750, max_ms: 1000 },
        setup: ["layout_load"],
        privateMutations: ["POST /api/pcb-layouts/barracuda-base"],
        requiredPrivateMutations: ["POST /api/pcb-layouts/barracuda-base"],
      },
      { id: "drc_navigation", kind: "local", setup: ["side_panel"] },
      {
        id: "trace_route_cancel",
        kind: "local",
        budgets: { p95_ms: 250, max_ms: 400 },
        blockedMutations: ["POST /api/pcb-route-complete/"],
      },
      {
        id: "via_place_undo",
        kind: "local",
        blockedMutations: ["POST /api/pcb-score/", "POST /api/pcb-layouts/"],
      },
      { id: "pour_zone_cancel", kind: "local" },
      { id: "pour_refill", kind: "async", budgets: { p95_ms: 8000, max_ms: 10000 } },
      { id: "zoom_controls", kind: "local" },
      {
        id: "part_drag_undo",
        kind: "frame",
        blockedMutations: ["POST /api/pcb-score/", "POST /api/pcb-layouts/"],
        requiredBlockedMutations: ["POST /api/pcb-score/"],
      },
      { id: "pan", kind: "frame" },
      { id: "zoom", kind: "frame" },
    ],
  },
  {
    id: "pcb_3d",
    label: "PCB layout 3D",
    path: "/pcb-layout/barracuda-base?view=3d&gpu=0",
    ready: "#pcb-3d-canvas",
    scenarios: [
      { id: "streaming_orbit", kind: "frame", phase: "streaming" },
      { id: "streaming_zoom", kind: "frame", phase: "streaming" },
      { id: "preset", kind: "local" },
      { id: "visibility", kind: "local" },
      { id: "orbit", kind: "frame", budgets: { p95_ms: 55, max_ms: 75 } },
      { id: "zoom", kind: "frame" },
    ],
  },
  {
    id: "thermal",
    label: "Thermal review",
    path: "/thermal/barracuda-base",
    ready: "#tp-frame",
    scenarios: [
      { id: "scenario", kind: "async" },
      { id: "ambient", kind: "async" },
      { id: "face", kind: "local" },
      { id: "labels", kind: "local" },
      { id: "opacity", kind: "local" },
      { id: "pan", kind: "frame" },
      { id: "zoom", kind: "frame" },
    ],
  },
  {
    id: "system_review",
    label: "System review workspace",
    path: "/systems/barracuda",
    // The document workspace: boot() renders the document list and opens the
    // first active document. waitSurfaceReady() additionally requires the
    // loaded source, the rendered preview, and a settled readiness panel, so
    // nothing below is timed while boot() is still assigning page state.
    // Release readiness itself is out of scope and blocked by run.js — it
    // cannot succeed against the benchmark overlay at all; see AUDIT-LEDGER
    // DRIFT-SYSREV-001 for the measurement and what covering it would cost.
    ready: "#docs button.active",
    scenarios: [
      { id: "document_open", kind: "async", budgets: { p95_ms: 300, max_ms: 500 } },
      { id: "source_edit", kind: "local", setup: ["document_open"] },
      // Last: the largest authored document in the manifest. It replaces the
      // preview with ~58 KB of generated HTML and re-walks every [src]/[href]
      // for asset rewriting, and it leaves a read-only document selected.
      { id: "large_document", kind: "async", budgets: { p95_ms: 500, max_ms: 750 } },
    ],
  },
  {
    id: "library",
    label: "Parts library",
    path: "/library",
    ready: "#lib-grid",
    scenarios: [
      { id: "search", kind: "local" },
      { id: "pagination", kind: "local" },
      { id: "footprint_preview", kind: "async", budgets: { p95_ms: 300, max_ms: 500 } },
      { id: "courtyard_editor", kind: "local", setup: ["footprint_preview"] },
    ],
  },
  {
    id: "footprint_editor",
    label: "Footprint editor",
    path: "/library/footprint/qfn40p1000x1000x90-81n-d",
    ready: "#editor-svg [data-pad-key]",
    scenarios: [
      { id: "select_pad", kind: "local" },
      { id: "pad_drag_undo", kind: "frame" },
      { id: "inspector_edit_undo", kind: "local", setup: ["select_pad"] },
      { id: "duplicate_undo", kind: "local", setup: ["select_pad"] },
      { id: "add_undo", kind: "local" },
      { id: "grid_units", kind: "local" },
      { id: "pan", kind: "frame" },
      { id: "zoom", kind: "frame" },
    ],
  },
  {
    id: "model_alignment_3d",
    label: "Footprint 3D alignment",
    path: "/library/3d/mc3007",
    ready: "#view",
    scenarios: [
      { id: "preset", kind: "local" },
      { id: "rotation", kind: "local" },
      { id: "offset", kind: "local" },
      { id: "visibility", kind: "local" },
      { id: "seat_mode", kind: "local" },
      { id: "move_mode", kind: "local" },
      {
        id: "save",
        kind: "async",
        budgets: { p95_ms: 250, max_ms: 400 },
        setup: ["rotation"],
        privateMutations: ["POST /api/model-transform/mc3007"],
        requiredPrivateMutations: ["POST /api/model-transform/mc3007"],
      },
      { id: "reset", kind: "local", setup: ["rotation"] },
      { id: "orbit", kind: "frame" },
      { id: "zoom", kind: "frame" },
    ],
  },
  {
    id: "route_review",
    label: "Autoroute review",
    path: "/route-review",
    ready: "#rr-run",
    scenarios: [
      {
        id: "route",
        kind: "async",
        budgets: { p95_ms: 2000, max_ms: 2500 },
        workload: { parts: 20, nets: 8, zones: 2, min_decisions: 10, min_tracks: 16, min_vias: 2 },
      },
      { id: "timeline", kind: "local", setup: ["route"] },
      { id: "layers", kind: "local", setup: ["route"] },
      { id: "pan", kind: "frame", setup: ["route"] },
      { id: "zoom", kind: "frame", setup: ["route"] },
    ],
  },
  {
    id: "pdf_viewer",
    label: "PDF datasheet viewer",
    path: "/pdf-view/browser-perf.pdf?highlight=Netlisp",
    ready: "#viewer canvas",
    scenarios: [
      { id: "lazy_scroll", kind: "async", budgets: { p95_ms: 500, max_ms: 750 } },
      { id: "next_match", kind: "async", budgets: { p95_ms: 1000, max_ms: 1500 } },
    ],
  },
];

const responseScenarios = [
  { id: "datasheet_response", path: "/datasheets/browser-perf.pdf", expect: 200, contentType: "application/pdf" },
  { id: "modules_redirect", path: "/modules", expect: 302, location: "/" },
  { id: "route_lab_redirect", path: "/pcb-route-lab/barracuda-base", expect: 302, location: "/pcb-layout/barracuda-base" },
];

// The full-page PCB tool strip is a deliberately exact inventory: the
// manifest test extracts its source IDs, including the embedded pad-align
// button, and fails on additions or renames. Entries with a scenario are
// exercised through that exact control; authoring tools outside this gate's
// safe disposable interactions carry an explicit reviewable exclusion.
const pcbToolstripControls = {
  "tool-select": { scenario: "pour_zone_cancel" },
  "pcb-draw": { scenario: "trace_route_cancel" },
  "pcb-via": { scenario: "via_place_undo" },
  "pcb-outline": { excluded: "Multi-click board-outline authoring needs a dedicated disposable geometry fixture before it can be timed safely." },
  "pcb-outline-poly": { excluded: "Multi-click polygon-outline authoring needs a dedicated disposable geometry fixture before it can be timed safely." },
  "pcb-backing": { excluded: "Backing-region authoring needs a dedicated disposable geometry fixture and semantic shape oracle." },
  "pcb-heatsink": { excluded: "Heatsink authoring opens a multi-field editor and needs a dedicated thermal geometry fixture and oracle." },
  "pcb-outline-dxf": { excluded: "DXF import requires a user-selected file and belongs to the explicit import fixture rather than normal board gestures." },
  "pcb-pour-zone": { scenario: "pour_zone_cancel" },
  "pcb-text": { excluded: "Silkscreen text placement opens a prompt and needs a dedicated disposable text-edit fixture and oracle." },
  "pcb-move-btn": { excluded: "Numeric selection move requires a stable selected mixed-entity fixture; ordinary direct move is covered by part_drag_undo." },
  "pcb-ruler-btn": { excluded: "Driving-dimension creation mutates persisted board geometry and needs a dedicated dimension fixture and oracle." },
  "pcb-pad-align": { excluded: "Pad alignment needs two unambiguous fixture pads on independently movable components and a dedicated alignment oracle." },
  "z-in": { scenario: "zoom_controls" },
  "z-out": { scenario: "zoom_controls" },
  "z-fit": { scenario: "zoom_controls" },
};

// Ordinary primary controls outside the tool strip. Every listed ID must stay
// present in its owning source and mapped to a real PCB scenario.
const pcbPrimaryControls = {
  "pcb-find-input": { source: "src/serve/assets/pcb_find_header.html", scenarios: ["find"] },
  "pcb-lay-select": { source: "src/serve/pcb_layout_page.zig", scenarios: ["layout_load"] },
  "pcb-update": { source: "src/serve/pcb_layout_page.zig", scenarios: ["layout_save"] },
  "drc-prev": { source: "src/serve/assets/pcb_drc_pane.html", scenarios: ["drc_navigation"] },
  "drc-next": { source: "src/serve/assets/pcb_drc_pane.html", scenarios: ["drc_navigation"] },
  "pcb-pour": { source: "src/serve/pcb_layout_page.zig", scenarios: ["pour_refill"] },
  "pcb-undo": { source: "src/serve/pcb_layout_page.zig", scenarios: ["part_drag_undo", "via_place_undo"] },
};

module.exports = { routes, surfaces, responseScenarios, pcbToolstripControls, pcbPrimaryControls };
