# Full-PCB-Design Gap Audit

*What must be implemented/improved before someone can do a complete, real
PCB design in netlisp alone — no KiCad, no manual file surgery.*

*Audit date 2026-07-07, against main @ 78b0afa. Method: six parallel code
audits — interactive editor UX, router + copper model, DRC + fab gate, fab
outputs + interop, footprint/pad/library pipeline, board model + workflow.
Every claim was verified in current source with file:line evidence.
This supersedes `docs/pcb-editor-audit.md` (2026-07-06): all of its Tier-0
and Tier-1 items have shipped except the native footprint editor.*

---

## Verdict

**The happy path is real.** For a rectangular-or-polygonal, 2–4-layer,
all-round-hole, orthogonally-rotated board up to roughly 100 mm square, the
whole flow works in-tool today: capture → auto/rough place → hand-finish →
outline → auto/hand route (inner layers included) → live DRC → silkscreen
text → fab-readiness gate → Gerber/drill/centroid ZIP a board house will
accept. Nothing in that chain requires KiCad.

What separates "the happy path works" from "someone can do a full PCB
design" falls into three buckets:

1. **Silent fab-wrong outputs** — cases where the delivered files differ
   from what the screen shows, with no warning. These bite even the happy
   path (oval drills become round holes; the fab gate DRCs at the wrong
   clearance; pour connectivity is assumed, not verified).
2. **Capability walls** — board classes that simply cannot be finished:
   congested boards (no rip-up), boards over ~113 mm (grid cap), anything
   high-speed (no diff-pair routing / length matching / impedance), boards
   needing slots, cutouts, or keepouts.
3. **Work-loss and friction** — hours of hand placement/routing are the
   least-protected artifact in the system (last-write-wins saves, no
   layout history, no autosave), and a dozen missing editor conveniences
   push users back to `.sexp` source or KiCad.

A fourth, product-level gap: **layout is the one step an agent cannot
drive.** Every MCP layout tool is read-only; placement and routing are
mandatory human-in-the-browser steps. For a tool whose thesis is
agent-driven EDA, that is arguably the headline item.

---

## Where the pipeline stands

| Stage | Status | Gating gaps |
|---|---|---|
| Schematic capture (DSL, ERC, review, BOM) | **Strong** | pin-type conflict matrix; PDF/print schematic |
| Parts & library | **Good for simple SMD/THT** | oval drills, roundrect fidelity, no footprint editor, silk arcs/text dropped |
| Placement | **Strong** (rough engine, rigid groups, Stamp) | exact coordinate entry, copy/paste/array |
| Routing | **Good to module scale** | no rip-up, ~113 mm grid cap, no incremental route |
| High-speed | **Absent** | diff pairs, length match, impedance stackup |
| Copper features | **Basic** (whole-layer pours) | zones, thermal reliefs, island removal, keepouts, net ties |
| DRC | **Decent core, mis-wired rules** | design-rules clearance is a no-op; mask/silk/width checks missing |
| Fab outputs | **Complete core package** | slots, stackup doc, assembly outputs, DNP-clean centroid |
| Data safety | **Weak** | last-write-wins layout saves, no sidecar history |
| Agent/MCP | **Read-only for layout** | no place/route/save mutation tools |
| Docs | **Reference only** | no start-to-finish tutorial |

---

## P0 — silent fab-wrong: fix before the next fab run

These produce manufacturing files that differ from what the user sees,
without any warning. They affect even simple boards.

### 1. Oval drills / slots ship as round holes
`geometry.Pad.drill` stores only a scalar diameter
(`src/placement/geometry.zig:203-209`), and Excellon emits round tools only
(`src/export_fab.zig:90,115`) — no G85 slots. A `(drill oval 0.61 1.40)`
pad fabs as a **round 1.40 mm hole**. Real library parts hit today:
`usb4510-03-1-a-gct` (USB-C shield slots), GCT `conn-8p94…`, Amphenol
`10164986`. Connectors won't seat; shields break out. The KiCad-export path
preserves ovals (`src/export_kicad_footprint.zig:284-292`) — only the
native fab path is wrong.
**Fix:** add a drill minor-axis field to `Pad`, emit Excellon
G85 slots (and NPTH slots), teach DRC/raster the true hole shape.

### 2. The DRC the fab gate runs is not the DRC you configured
Three stacked rule-plumbing failures:
- `(design-rules (clearance …))` parses and stores
  (`src/eval/design_block.zig:1837` → `DesignRules.clearance`), but its
  **only consumer is the board-edge fallback** — the copper-copper DRC and
  the router never read it. Authors can set it and see zero effect.
- Per-net-class clearances reach only the **browser-side live preview**
  (`pcb_layout_page.zig:5443`, `pcb_board.js:1698`); the authoritative
  server DRC uses one scalar.
- The fab-readiness gate hardcodes the *default* clearance —
  `(router.RouteParams{}).clearance` = 0.127 mm at
  `src/fab_readiness.zig:157` — ignoring both the design rules and the
  Route-panel setting the user actually routed against.

Net effect: a board routed to a tighter (or class-specific) rule is gated
at 5 mil regardless. For mains/HV spacing this is a P0.
**Fix:** one rule-resolution path (`design-rules` → net-class override →
panel override) feeding router, server DRC, and gate identically.

### 3. Pour/plane connectivity is assumed, never verified
`fab_readiness.netComponents` short-circuits any plane/pour-carried net to
"one connected group" with **no geometric check**
(`src/fab_readiness.zig:353`). Consequences:
- A pad the pour actually isolates (antipad ring, plane split, trace
  slicing the pour) ships as a believed-connected airwire.
- There is **no island removal** — pours are outline-pullback minus
  antipads (`export_gerber.zig:466`), so orphan copper is emitted as-is.
- The router's failed-leg handling still marks the goal node as net-owned
  (`router.zig:1512`), so a later same-net leg can weld to a **stranded
  island** — the picture looks connected while electrically split.

**Fix:** compute the real pour fill once (flood from same-net seeds, clip
against foreign copper), share it between Gerber, viewer, DRC, and the
connectivity union-find; drop unseeded islands.

### 4. Fine-pitch assembly hazards nothing checks
- **No solder-mask sliver / min-web check** — mask is a blind
  `mask_margin` expansion (`export_gerber.zig:346`); nothing verifies a dam
  survives between QFN/0.4 mm-pitch pads → solder bridging at assembly.
- **Roundrect pads emit as sharp rectangles** in every copper/mask/paste
  layer (`export_gerber.zig:439-445` routes roundrect to the `R`
  aperture) while the library preview shows rounded corners. 147 real pads
  affected.
- **Custom polygon pads get mask == copper exactly** — `flashPad` returns
  before applying the mask expansion for poly pads
  (`export_gerber.zig:430-433`).
- **QFN/EP paste subdivision is dropped** at convert time; `writePaste`
  flashes one giant 1:1 aperture per pad (`export_gerber.zig:363-371`) →
  excess paste, float/tombstone on thermal pads.

### 5. DNP parts ship in the pick-and-place
All placed parts are emitted into the centroid; DNP is a **warning**, not
an exclusion (`src/fab_readiness.zig:205-212`). A CM running the file as-is
places parts you marked do-not-populate.
**Fix:** exclude by default (or a `DNP` column + query flag), and while in
there: the centroid rotation is KiCad's CCW convention
(`export_fab.zig:80-85`), not JLC's — offer a convention switch or a
per-package rotation table, and document it.

---

## P0 — work-loss: layout is the least-protected artifact

Hours of hand placement/routing are stored with weaker guarantees than any
`.sexp` edit:

- **Last-write-wins saves, no conflict guard.** The sidecar save replaces
  the file with no checksum (`pcb_layout_page.zig:2438`); two tabs clobber
  silently. Ironically the schematic editor already has the needed
  discipline — `edit.zig:220` uses a source-offset checksum.
- **No layout history.** `history.zig` snapshots `.sexp` sources only. A
  single-design Save overwrites the one auto-starred snapshot
  (`pcb_layout_page.zig:2173-2180`); a bad Save is unrecoverable in-tool
  (git on `projects/designs` is the only backstop — sidecars *are*
  tracked, but only if the user commits).
- **No autosave and no unsaved-changes guard.** No `beforeunload`; a
  refresh/crash loses all unsaved hand routing.
- **Board-outline edits sit outside undo.** `snapAll`/`restoreSnap` cover
  poses+copper+texts but never `PCB.outline`
  (`pcb_board.js:981,989,1465-1479`) — Ctrl+Z rewinds everything except a
  botched outline edit.
- **The `.sexp` is not a complete board description.** Outline, routes,
  texts, sides, locks live only in `*.layouts.json`. Any flow that
  reconstructs "from source" (fresh clone without sidecar, regenerate)
  loses the physical board.

**Fix (cheap, high value):** reuse the existing `history/` snapshot scheme
for `*.layouts.json` on every save; add the checksum guard from
`edit.zig`; add `beforeunload` + a periodic draft save; put outline edits
in the undo snapshot.

---

## P0 — capability walls (board classes that can't be finished)

### 6. Congested boards: no rip-up/reroute
Single greedy pass, first-routed-wins (`router.zig:13-15,248,646`). This is
why rp2350b-core sits at 13/14 with FLASH_D1 geometry-boxed. The plumbing
for a bounded rip-up exists (priority sort, `failed[]` list); negotiated
rip-up of the lowest-priority blocker is the single biggest routing-power
lever. Also missing: **incremental routing** — `route()` always re-routes
the whole board; you can't route one net or fill around locked copper
(`P1` friction that compounds the congestion problem).

### 7. Large boards: hard grid cap ≈ 113 mm square
`MAX_NODES = 200_000` per signal layer (`router.zig:88`) at the default
0.254 mm pitch → ~113 mm/side; a 160×100 Eurocard **routes nothing**
(surfaced as `grid_overflow`, but all-or-nothing). Behavior also silently
changes with part count (`TOP_FIRST_MAX_PARTS=32`, `STITCH_MAX_PARTS=48`,
`router.zig:97,101`). Every routed leg re-scans the full grid on every
layer to collect sources (`router.zig:1618-1626`) — a real scaling smell.
**Fix:** windowed/hierarchical grid or per-region routing; make the caps
rule-driven; profile the source-collection scan.

### 8. High-speed boards: the entire tier is absent
- No coupled **differential-pair routing** — `differential` on a port only
  mirrors *placement* (`optimizer.zig:4641-4755`); the router neither
  couples, gaps, nor phase-matches. stm32n6's USB-HS 90 Ω pairs cannot be
  routed to spec.
- No **length matching / meander tuning**; not even a **per-net routed
  length readout** (total `trace_mm` only, `pcb_layout_page.zig:1323`) —
  you can't hand-check skew.
- No **impedance model**: `StackupSpec` carries layer count + planes only
  (`env.zig:1098-1119`) — no thickness/Dk/copper-weight/target-Z0; the
  `.gbrjob` hardcodes `BoardThickness: 1.6` (`export_gerber.zig:160`).
  Controlled-impedance orders can't even be *documented*, let alone
  checked.

**Fix order:** per-net length readout (trivial, unblocks hand-matching) →
stackup physical fields + stackup doc in the fab ZIP → coupled pair
routing → meander tuning.

### 9. Mechanical walls: cutouts, slots, keepouts
- **No internal cutouts** — outline is one closed contour
  (`export_gerber.zig:403-420`); no multi-contour Edge.Cuts, no routed
  slots (ties into P0 #1).
- **No keepout model at all** — `KeepoutConstraint` survives in
  `env.zig:1364` but the parsing form was removed; nothing keeps copper,
  vias, or parts out of a region (antenna zones, connector shadows,
  HV creepage, mounting-hole annuli). P0 for RF/HV boards.
- **No arc outline segments** — polygon vertices only; `(corner-radius)`
  covers rounded rects, but true curved edges are unrepresentable
  (the Gerber writer is G01-only, `export_gerber.zig:225`).

### 10. Agent-driven layout: MCP is read-only
`get_pcb_layout_image` / `describe_pcb_layout` / `compare_layout_to_starred`
are the only layout tools (`mcp_tools.zig:94-96`). No MCP tool can move a
part, draw/clear copper, set the outline, or save a layout; no source form
can author poses. The "agent designs a board end-to-end" story stops at
the schematic. **Fix:** an MCP mutation set mirroring the viewer verbs
(place/rotate/flip/lock, route-net/clear-net, outline, save-layout,
run-fab-gate) — the endpoints already exist server-side; this is mostly
exposure + auth.

---

## P1 — major friction (forces `.sexp` surgery, KiCad, or manual file edits)

### Editor ergonomics
- **No interactive zone/pour tool** — pours exist only as authored
  `(stackup (pour …))` whole-layer fills, drawn as an unclipped translucent
  rect in the viewer (`pcb_board.js:423-441`); no polygon zones, no
  priority, no refill button, no live clipped preview.
- **No exact numeric position/rotation entry** — property panel X/Y/rot
  are read-only spans (`pcb_board.js:704-751`); precise connector
  placement means fighting the grid. Rotation is 90°-only
  (`pcb_board.js:821,951`).
- **No copy/paste/duplicate/array** — replicating a connector row is fully
  manual (Stamp covers saved *module* layouts only).
- **Editing existing copper = delete-and-redraw** — no drag-segment, no
  break/split, no change width/layer of laid track (`pcb_board.js:1848`).
- **No DRC results browser** — canvas markers + a count chip only
  (`pcb_board.js:1880-1897`); no list panel, no click-to-locate, no
  per-check severity/waivers, no report file. Fab modal lists errors only
  at export time.
- **Board text is silk-only, quarter-turn only** (`pcb_board.js:1505`,
  `font5x7.zig:138`) — no copper/fab-layer text, no arbitrary angle, no
  graphic primitives (line/rect/logo).
- Marquee selects by part-origin-in-box (`pcb_board.js:1492`), not
  window/crossing semantics — big parts get missed.

### Copper & routing
- **No thermal reliefs** — plane/pour connections are solid
  (`export_gerber.zig:317-340`); hand-soldering/rework of plane-tied pads
  is painful. Needs a spoke model + per-pad `zone_connect` override.
- **No user-drawn zones / split planes** — one net per face
  (`pcb_layout_page.zig:5383`); no way to do an analog/digital plane
  split.
- **No net-tie primitive** — the hand router actively blocks cross-net
  joins (`pcb_board.js:1817`); star-ground and shunt-sense topologies
  can't be expressed on copper (ERC-side net-ties exist; PCB-side don't).
- **No via-stitching tool/region** (auto return-path stitching exists,
  `RETURN_PATH_RADIUS_MM=2.0` hardcoded at `router.zig:1839`).
- **Stale copper after part moves** — untagged hand/auto copper stays put
  and dangles (only rigid-group copper translates); the fresh DRC pass is
  the only thing that notices.

### Rules & checks
- **Track-width-below-minimum never checked** for hand-drawn copper
  (`Track.width` unvalidated) — a thin power trace passes everything.
- **Thru-pad annular ring never DRC-checked** (vias only,
  `drc.zig:220-226`); KiCad export even invents `drill = min(sx,sy)` → a
  zero-ring pad with only a log line
  (`export_kicad_footprint.zig:327-336`).
- **No silk-over-pad / silk-over-mask check** (`export_gerber.zig:377`).
- **No current→trace-width sizing** — `power_budget.zig` knows rail
  currents but never sizes copper; no IPC-2221 ampacity check.
- **No voltage→clearance/creepage classes** — DRC clearance is purely
  geometric; HV boards can't be spacing-checked.
- **No drill-to-copper (barrel-to-foreign-trace) check**; hole-to-hole is
  net-agnostic but skips coincident holes (`drc.zig:242`).
- **Class-to-class clearance matrix** absent (single scalar + per-net
  override only).

### Library & footprints
- **No native footprint editor** — the only geometry mutation in-app is
  the courtyard rect (`pcb_layout_page.zig:2464`). Everything else means
  KiCad or hand-editing `lib/footprints/*.sexp`. A minimum editor needs
  pad create/move/resize/rotate + shape/drill/margins + silk/fab drawing —
  and first requires extending `geometry.Pad` (no `rot`, no per-pad
  mask/paste margins, no oval-drill minor axis today).
- **Footprint silk arcs and text never reach the fab silkscreen** — only
  lines+circles are parsed/emitted (`geometry.zig:141-148`,
  `export_gerber.zig:381-389`); `fp_arc`/`fp_text` are dropped at convert
  (pin-1 markers, polarity marks, curved connector outlines vanish);
  silk rects/polys render in preview but don't fab. Preview ≠ product.
- **Simple pads cannot represent rotation** — `parsePad` reads x,y only
  though its own doc comment advertises `[rot]` (`geometry.zig:177-196`);
  a 45° pad becomes axis-aligned. Currently masked by 90° part quantize;
  latent silent-wrong-geometry.
- **Re-import silently overwrites a footprint live boards use**
  (`upload.zig:487-513`) — no version/impact tracking; no library-wide QA
  (missing courtyard is silently synthesized as a fallback box,
  `geometry.zig:286-290`).
- **No castellated-edge model**; multi-footprint zips import only the
  first `.kicad_mod` (`upload.zig:130-136`).

### Fab & interop tail
- **No stackup documentation output** (blocked on stackup fields, P0 #8).
- **No IPC-D-356 netlist** for bare-board e-test.
- **No assembly drawings / fab drawing** (silk Gerber is the only refdes
  artifact); no drill map.
- **No board-level STEP/DXF export** for enclosure work (full-board 3D
  *view* exists, `pcb_3d_viewer.js`, but it renders a courtyard-slab
  substrate, not the real outline, and no copper/silk).
- **No from-scratch `.kicad_pcb` export** — `kicad_pcb/writer.zig` only
  patches existing boards; there is no clean hand-off of a netlisp-routed
  board to a KiCad-based CM. `import-kicad` conversely drops all
  tracks/zones/outline (schematic only) — no layout round-trip.
- **BOM lacks distributor part numbers** (MPN/Mfr only — no LCSC/DigiKey
  column despite the DigiKey integration); BOM isn't in the fab ZIP; no
  CLI path for the fab package (HTTP-only).
- **X2 object attributes absent** (`%TO.N/.C/.P`, `%TA.AperFunction`) —
  CAM can't extract nets/components from the Gerbers.
- **No PDF/printable schematic** — the review Markdown+SVG is the closest
  reviewer artifact; formal design review outside the tool has no
  paginated output.

### Workflow & docs
- **No start-to-finish tutorial.** Docs are grammar reference + build
  instructions; nothing walks a new user through
  capture→place→outline→route→gate→ZIP, and the crucial fact that *the
  physical board lives in the browser + sidecar, not the `.sexp`* is
  undocumented.
- **No fiducial form** (and centroid can't flag fiducials); **no
  first-class mounting-hole form** (NPTH footprint instances work as a
  convention); **no board datum/origin control** (fab frame is always
  outline bottom-left).
- **No assembly variants** beyond the single DNP boolean.

---

## P2 — parity & polish

Editor: align/distribute, zoom-to-selection, select-all, light theme,
window-vs-crossing marquee, arc tracks, teardrops, push-and-shove.
Rules: silk-to-silk, dangling-track/stub detection, zero-length segments,
same-net duplicate copper, DRC severity axis (today every finding —
including courtyard overlap — equally blocks export), runtime Gerber
read-back at export time (`gerber_verify.zig` runs only in tests, and
skips region contours). Fab: panelization (step-repeat, rails, mousebites),
ODB++/IPC-2581, testpoint report, stencil aperture tweaks (home-plate,
paste reduction), Excellon `METRIC,TZ`-vs-explicit-decimals nit, blind/
buried/microvias, per-net-class layer pinning. Model: multi-unit symbols
kept distinct, trapezoid/chamfered pads (silently → rect today,
`convert/footprint.zig:481`), custom pads keeping only the first
`gr_poly`, press-fit. Infra: router latency benchmark (bench_layout covers
placement only), big-board page-weight budget.

---

## Bug list — concrete, small, worth fixing now

| # | Bug | Where |
|---|---|---|
| 1 | `(design-rules (clearance))` parsed but never consumed by router/DRC | `optimizer.zig:5693`, `pcb_layout_page.zig:4046` |
| 2 | Fab gate DRCs at hardcoded default clearance, not the user's | `fab_readiness.zig:157` |
| 3 | Plane/pour nets assumed connected, no geometry check | `fab_readiness.zig:353` |
| 4 | Failed route leg still marks goal `occ=net` → welds to stranded islands | `router.zig:1512` |
| 5 | Oval drill → round hole of the larger axis | `geometry.zig:203`, `export_fab.zig:90` |
| 6 | Roundrect → sharp `R` aperture in all Gerber layers | `export_gerber.zig:439-445` |
| 7 | Oval pads draw as sharp rects in the server PNG (MCP image lies) | `render_pcb_png.zig:621-631` |
| 8 | Custom poly pads: mask opening == copper (margin skipped) | `export_gerber.zig:430-433` |
| 9 | Non-orthogonal pad rotation flashes axis-aligned apertures (latent) | `export_gerber.zig:435,540` |
| 10 | `.gbrjob` `BoardThickness` hardcoded 1.6 mm | `export_gerber.zig:160` |
| 11 | Outline edits excluded from undo snapshots | `pcb_board.js:981,989,1465` |
| 12 | Layout save has no conflict guard (checksum exists for source edits) | `pcb_layout_page.zig:2438` vs `edit.zig:220` |
| 13 | DNP parts emitted in centroid (warn only) | `fab_readiness.zig:205` |
| 14 | `multiple_drivers` ERC ViolationKind declared, never emitted | `erc.zig:43` |
| 15 | Courtyard DRC violations carry `clearance=0` → nonsense tooltip text | `drc.zig:333` |
| 16 | `board_poly` with <3 points silently falls back to bbox rect | `export_gerber.zig:405-414` |
| 17 | Missing footprint silently synthesized as a pin-count box | `geometry.zig:286-290` |
| 18 | Pad doc comment advertises `(pos X Y [rot])`; `rot` never parsed | `geometry.zig:177-196` |
| 19 | Dead constraint types (`Keepout`/`Proximity`/`NetLength`) mislead readers — holder is permanently empty | `env.zig:1285-1392` |

---

## Already ahead of KiCad — protect these

Force-directed auto-place with live scoring + the rough/hand-likeness
metric; module ★ layout **Stamp** (pre-routed sub-circuit reuse with
copper); the **fab-readiness gate** concept itself (KiCad has no export
blocker); *blocking* live DRC while hand routing (illegal segments refuse
to commit — stronger than KiCad's advisory highlight); automatic GND
return-path stitching; Gerber writer self-verification in the test suite;
3-surface cross-probe; the MCP read surface (image + facts twins); design
review/traceability/power-budget integration. None of the fixes above
should regress these.

---

## Cross-cutting insight: the authored board DSL has zero adoption

In `projects/designs/src`, **no real design authors** `(board (size …))`,
`(stackup …)`, `(net-class …)`, or `(design-rules …)` — outlines are drawn
interactively, every board runs the router's implicit legacy 4-layer
model, and rules ride the defaults. Two readings, both actionable:

1. The interactive path is the real product; invest there first (which is
   also where the data-safety gaps are).
2. The forms that exist are unused partly because they're not surfaced —
   there's no UI to create a net class or set design rules (`.sexp` only),
   and `(design-rules (clearance))` literally does nothing (Bug #1). Wire
   them up, surface them in the editor (a Rules panel writing back to
   source), and adoption follows.

---

## Suggested build order

**Wave 1 — protect the next fab run (small, days):**
fix Bugs #1–#3 + #5 + #6 + #13 (rule plumbing, slots, roundrect
apertures, DNP-clean centroid); add mask-sliver check; stackup thickness
fields + honest `.gbrjob`.

**Wave 2 — protect the work (small):**
layout sidecar history snapshots + save conflict guard + autosave/
`beforeunload` + outline-in-undo.

**Wave 3 — one real pour engine (medium):**
geometric pour fill computed once and shared by viewer/DRC/Gerber/
connectivity → island removal, real plane connectivity, thermal reliefs,
then user zone polygons + keepouts on the same machinery.

**Wave 4 — routing power (medium/large):**
bounded rip-up/reroute; incremental single-net routing; per-net length
readout; grid windowing past 113 mm; then diff-pair coupling + length
tuning on the stackup fields from Wave 1.

**Wave 5 — editor ergonomics (parallelizable):**
numeric position entry, copy/paste/array, drag/split existing copper, DRC
list panel with waivers, zone/keepout tools, Rules panel writing
`(design-rules)`/`(net-class)` back to source.

**Wave 6 — library depth (medium):**
extend `geometry.Pad` (rot, oval-drill minor axis, per-pad mask/paste
margins, paste subdivision), silk arcs/text through to fab, thru-pad
annular DRC, then the native footprint editor on the richer model;
footprint versioning + library QA page.

**Wave 7 — agent-driven layout (the differentiator):**
MCP mutation tools mirroring the viewer verbs (place/rotate/flip/lock,
route-net/clear-copper, outline, save-layout, fab-gate) so an agent can
take a design from schematic to gated Gerbers unattended.

**Wave 8 — fab/docs tail (as boards demand):**
IPC-D-356, assembly/fab drawings, board STEP/DXF, from-scratch
`.kicad_pcb` export, panelization, variants, PDF schematic; and the
start-to-finish tutorial (cheap, do anytime — biggest onboarding lever).
