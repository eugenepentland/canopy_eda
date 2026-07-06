# PCB Editor Audit — Path to Full KiCad Replacement

*Audit date: 2026-07-06. Four parallel code audits: viewer interactions
(`src/serve/assets/pcb_board.js`, `src/serve/pcb_layout_page.zig`), router +
DRC (`src/placement/router.zig`, `src/placement/drc.zig`), board data model
(`src/eval/`, `src/placement/geometry.zig`, `src/convert/footprint.zig`), fab
outputs + workflow (`src/export_gerber.zig`, `src/export_fab.zig`,
`src/serve/sync.zig`).*

## Verdict

The tool is already a **complete schematic-to-fab pipeline for simple,
rectangular, 2/4-layer boards**: capture → auto-place → hand-finish → route →
DRC → Gerber ZIP, with no KiCad in the loop. What separates it from "full
KiCad replacement" falls into three buckets:

1. **Blocking** — real boards can't be fabbed without them (non-rect
   outlines, copper pours, a pre-fab correctness gate).
2. **Editor parity** — work that today still requires dropping to `.sexp`
   source or to KiCad (silkscreen text, footprint authoring, inner-layer
   routing, DRC-aware hand routing).
3. **Polish/advanced** — features KiCad has that matter for specific board
   classes (diff pairs, length tuning, 3D, panelization).

Strengths already *ahead* of KiCad — keep these: force-directed auto-place
with live scoring/heatmap, module layout Stamp (pre-routed sub-circuit
reuse), instant browser-side score re-weighting, 3-surface cross-probe,
agent/MCP integration, rough-vs-starred hand-likeness metric.

---

## What exists today (baseline)

| Area | State |
|---|---|
| Placement editing | Drag/rotate/flip/lock, marquee, rigid groups, undo/redo (200-deep, placement only), Stamp, outline-rect draw, courtyard editor |
| Routing | Grid Dijkstra maze router (45°, via costing, net-class priority 0–7, pad gateways, plane vias, return-path stitching); hand routing (X/V keys, 45°/grid snap, right-click delete) |
| Layers | 2 routable signal layers (top/bottom) + declared solid inner planes via `(stackup …)`; through vias only |
| DRC | 8 checks: via↔pad/via/track, track↔track/pad, pad↔pad, annular ring (0.1 mm floor), board edge |
| Rules | `(net-class …)` width/clearance/via/priority per net; grid pitch from widest class |
| Fab outputs | RS-274X/X2 Gerbers (outer copper + routed tracks/vias, inner planes w/ antipads, mask, paste, silk + 5×7 ref-des, edge), Excellon PTH/NPTH, JLC-style centroid, one ZIP, shared y-up frame; unit-tested writers |
| BOM | CSV (Qty/Refs/Value/Footprint/MPN/Mfr/Datasheet/DNP), `.bom` sidecar |
| Import/interop | `import-kicad` (one-way, complete), KiCad sync (now optional), CSE `download_footprint` |
| Persistence | `.layouts.json` sidecar (poses, side, locked, routed copper net-keyed, outline); not git-tracked |

---

## Tier 0 — Blocking (can't fab most real boards)

### 0.1 Pre-fab correctness gate (highest urgency — a fab run is imminent)
The `⤓ Gerbers` button today exports whatever the ★ layout holds, with **no
connectivity check and no DRC gate**. Hand-drawn copper is never DRC-checked
until the user happens to click Route; there is no unrouted-net /
floating-copper / missing-outline check at export time.

**Build:** a fab-readiness report run at `/api/pcb-gerbers` time (and shown
as a modal before download): unrouted nets (airwires remaining), DRC
violations against current copper, parts off-board / in staging band,
outline present, vias with drill=0 (legacy synthetic — would emit bad
drills), unplaced parts. Block (or require an explicit override) on errors.
This is the single cheapest change with the highest protection value.

### 0.2 Gerber CAM self-verification
Writers are unit-tested but **never validated against real CAM**. Arcs are
24-gon polylines (acceptable but worth eyeballing), `.gbrjob` is absent (many
fabs' CAM uses it for stackup detection).

**Build:** (a) a Gerber read-back check — parse the emitted layers with a
minimal RS-274X reader and diff flashed pads/tracks against the placement
model (catches frame/polarity/aperture regressions forever); (b) emit
`.gbrjob`; (c) one-time manual validation of the next fab package in KiCad's
gerber viewer / gerbv before sending.

### 0.3 Non-rectangular board outlines + cutouts
`BoardSpec` is `w,h` only (`src/eval/env.zig:1066`); the viewer's Outline
tool draws only a rect; Edge.Cuts emits only a rect. No arcs, no rounded
corners, no L/T shapes, no internal cutouts/slots.

**Build:** outline as a closed polyline+arc path: (a) model — `SavedOutline`
becomes a segment list (line/arc), plus optional `(board (outline …))`
authored form; (b) viewer — extend the ▭ Outline tool to polygon drawing
(click vertices, arc mode, edit handles); (c) consumers — `board_edge` DRC
against the path (point-in-polygon + distance-to-path), Gerber Edge_Cuts
path emission (G02/G03 or fine polyline), NPTH slots later. Rounded-rect
corners alone would cover a large fraction of real boards — worth shipping
as the first increment.

### 0.4 Copper zones / pours on signal layers
No user zone model at all (`src/export_gerber.zig:40-46` — declared solid
planes only). Every real 2-layer board wants a GND pour on one/both outer
layers; `(stackup 2)` currently routes GND as discrete traces instead.

**Build:** minimum-viable zones: (a) model — `(zone "GND" (layer top)
(poly …))` or default "pour rest of layer with net X"; (b) fill algorithm —
clip zone polygon against foreign copper + clearance (the antipad carving in
`export_gerber.zig:169-200` is already 80% of this logic — generalize it
from plane layers to outer layers and feed the result to the viewer,
DRC, and Gerber); (c) thermal reliefs on pads connected to the pour, solid
for vias; (d) island removal (drop fill regions that touch no same-net pad);
(e) connectivity — a pour counts as connecting its net (affects unrouted-net
accounting in 0.1). Skip user-drawn polygon editing initially: "pour this
layer with GND except keepout rects" covers most boards.

---

## Tier 1 — Editor parity (stop dropping to source/KiCad)

### 1.1 DRC-aware hand routing + copper undo
Hand routing is pure client-side geometry — you can draw dead shorts and
save them; DRC runs only via the Route button; undo covers placement only.

**Build:** (a) live clearance check while drawing (client-side against
`PCB.tracks/vias/pads` — the shapes are already in the browser); illegal
segment turns red and won't commit; (b) snap targets: pad centers, track
ends, track midlines (KiCad-style magnetic snap); (c) extend
`undoStack` to cover copper edits (add/delete track/via, Stamp); (d) run
server DRC automatically after Save and on a debounce after copper edits,
not only on Route.

### 1.2 Inner-layer signal routing
Router is hard-coded to L1/L4 signal (`router.zig:3-10`); declared stackups
with >2 signal layers emit *blank* inner Gerbers. Any dense 4/6-layer
digital board needs signal inners.

**Build:** generalize `Track.layer` u8 beyond {0,1}: maze router expands the
layer dimension to all non-plane layers from `(stackup …)`; via model gains
span awareness (through-only is still fine); viewer needs a layer palette
(color per layer, visibility toggles, active-layer selector for drawing —
see 1.5). This is a router + UI change, not a data-model rewrite — the
sidecar already stores `l` per track.

### 1.3 Board-level silkscreen text + graphics
Only footprint art + auto ref-des in a fixed 5×7 uppercase font
(`src/font5x7.zig`). No version strings, no polarity marks, no logos, no
values on fab layer.

**Build:** (a) a `texts[]` array in the layout sidecar `{x,y,rot,side,layer,
size,text}` + a Text tool in the viewer; (b) scale the stroke font (it's
vector strokes already — size is a multiplier), add lowercase; (c) emit on
silk Gerbers; (d) later: line/rect/logo (bitmap→polygon) graphics, fab-layer
value labels, a title block.

### 1.4 Native footprint authoring/editing
Everything comes from `.kicad_mod` conversion or CSE download; no way to
create or fix a footprint in-tool (courtyard box excepted). The `.sexp`
footprint format is already human-writable — what's missing is an editor
and docs.

**Build:** a `/footprint-editor/:name` page reusing the courtyard modal's
renderer: pad table (number, shape, size, position, drill, type) + silk/fab
line drawing + courtyard. Even a form-based (non-graphical) pad editor
covers the common case of "datasheet gives me a land pattern table."
Document the footprint `.sexp` grammar in `docs/`.

### 1.5 Layer display + grid/units controls
No layer visibility toggles, no active-layer selector (draw layer is
inherited from the starting pad), grid hard-coded 0.1 mm, mm-only display,
no measurement tool.

**Build:** layers panel (visibility + dim-others + active layer);
grid selector (0.5/0.25/0.1/0.05 + off) feeding the existing snap
functions; mil/mm toggle (display only); a ruler tool (click-drag shows
dx/dy/euclidean + net-to-net clearance readout).

### 1.6 DRC completeness
Missing vs KiCad: courtyard-overlap (exists only as placement lint, not
DRC), silk-over-pad, hole-to-hole clearance, min-drill, copper-to-edge per
class, via-in-pad flag, unconnected-items (belongs in 0.1), starved
thermals (belongs with 0.4). Global board-level default rules don't exist —
only per-net-class; mask margin (0.05) and pour clearance (0.3) are
hard-coded constants in `export_gerber.zig:29,32`.

**Build:** `(design-rules (clearance …) (min-drill …) (mask-margin …)
(copper-edge …))` top-level form as global defaults net-classes override;
add the missing geometric checks to `drc.zig` (courtyard and hole-to-hole
are cheap — the shapes are all loaded).

---

## Tier 2 — Advanced / board-class-specific

Ordered by relevance to this project's actual designs (USB-HS diff pairs on
stm32n6, RF on cyclops-analog):

- **2.1 Differential pairs + length readout.** stm32n6 has USB HS (90 Ω
  pair). Minimum viable: `(net-class (diff-pair "USB_DP" "USB_DM")
  (gap MM))` — router routes the pair as one path with fixed gap; viewer
  shows per-net routed length so skew can be hand-checked. Full
  meander/length-tuning is a later step.
- **2.2 Impedance/stackup documentation.** Controlled-impedance orders need
  a stackup table (layer, material, thickness, target Z). Emit a
  `stackup.txt`/JSON into the fab ZIP from the `(stackup …)` form + new
  optional thickness fields.
- **2.3 Rip-up-and-reroute + grid cap.** One-shot greedy routing and
  `MAX_NODES = 200_000` cap the routable board size (~100×80 mm at coarse
  pitch; the router silently returns empty beyond it — at minimum surface
  that as a lint). Negotiated rip-up of the lowest-priority blocker would
  lift completion on dense boards (rp2350b currently 13/14).
- **2.4 Teardrops, arc tracks, net ties.** RF/flex niceties; arcs also
  unlock proper curved Edge.Cuts (0.3).
- **2.5 3D board view.** STEP-per-footprint + occt viewer already exist
  (`src/serve/library_3d.zig`); assembling board box + parts into one scene
  is mostly frontend work. High demo value, zero fab value.
- **2.6 Assembly/fab drawings + IPC-D-356 + ODB++/IPC-2581.** Only needed
  when a CM asks; generate the assembly drawing (fab-layer render + BOM
  table PDF/SVG) first — it's the one hobbyist+CM shops actually use.
- **2.7 Panelization.** Step-repeat + rails + fiducials + v-score/mousebites
  as a ZIP-time transform; don't model it in the design.
- **2.8 Layout history/versioning.** `.layouts.json` is gitignored and
  snapshots overwrite by name; consider the same `history/` snapshot scheme
  designs already get, so a bad Save is recoverable.

---

## Suggested sequence

Driven by "next board gets fabbed from this tool":

1. **0.1 fab gate + 0.2 Gerber read-back check** — protect the imminent fab
   run; small, self-contained.
2. **0.4 zones (pour-layer-with-GND)** — biggest electrical-realism gap;
   the antipad clipper is already written.
3. **0.3 polygon outlines** (rounded-rect first) — biggest mechanical gap.
4. **1.1 DRC-aware hand routing + copper undo** — makes the hand-finish
   loop trustworthy.
5. **1.3 silkscreen text** + **1.5 layers/grid/ruler** — daily-driver UX.
6. **1.2 inner-layer routing** — unlocks real 4/6-layer boards.
7. **1.4 footprint editor** — removes the last KiCad-format dependency
   (CSE covers most parts meanwhile).
8. Tier 2 as boards demand (diff pairs next, given USB HS).

## KiCad dependencies after Tier 0+1

With tiers 0–1 done, KiCad remains only as: (a) an optional footprint
*source* (alongside CSE), (b) the legacy sync path for boards that already
live in `.kicad_pcb`, (c) mechanical/3D export for MCAD. None are in the
schematic→fab critical path.
