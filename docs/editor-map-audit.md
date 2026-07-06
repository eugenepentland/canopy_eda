# Editor map readability audit — why the auto-schematic is hard to navigate

Date: 2026-07-05. Scope: `/editor/:name` canvas (the map view in
`src/serve/assets/editor.js` + the scene from `src/render_json.zig`).
The `/schematics/` page is out of scope (being phased out).
Constraint: everything stays **fully automatic** — no new authoring
directives, no placement DSL.

Evidence design: stm32n6 (Cyclops Digital) on prod; code refs are
editor.js line numbers at HEAD.

## What the map does today (recap)

`buildGlobalMap` (editor.js ~1306) gives every real hub IC a dashed
**cell** containing: the anchor IC (pins split left/right by height
balancing), point-to-point partners as ghost hubs + inline passive
chains, and an **extras band** of spokes for power/ground/multi-drop
pins. A link between two ICs is drawn once, in the lower-degree end's
cell; the other end shows only a ghost. Cells are grouped into
**bands** (Power first, then authored sections with ≥2 cells), and
bands shelf-pack left-to-right, wrapping at `MAXW = 2600`, stacking
downward. Far zoom (`s < 0.30`) swaps to glance chips.

## Findings

### F1 — Sub-block cells don't file under their authored section (findability bug)

A cell's band comes from `secNameOf` — geometric containment in the
*base-layout* section boxes. Parts inside a `(sub-block …)` sit in the
module's derived card, so the flash IC lands in a band named
"MX66UW Flash" (the module title) while the authored section
"Boot NOR Flash (XSPIM_P2 / Port N)" pages **empty (0 cells)** in the
sheet sidebar. stm32n6's sidebar today: ~10 authored sections at 0
cells, plus a second set of module-named pages (USB-C 2.0 HS, MX66UW
Flash, APS256 PSRAM…) where the content actually lives. Two competing
taxonomies of the same design; the one the author wrote is the empty
one. The design source already pairs `(section "USB" …)` with
`(sub-block "usb" …)` — the pairing just isn't used here.

### F2 — The main-IC cell is a wall of pins

U9 (STM32N657, ~260 pads) renders as one tall cell with ~100 pin rows
split left/right purely by height balance. No functional grouping —
the authored `(pins "U9" (group "VDD Power") …)` / `(part …)`
declarations exist in the DSL and partially in the scene, but the map
neither orders nor labels pin runs by them. Meanwhile every peripheral
cell already re-draws the relevant U9 pins as a ghost — so the mega-
cell largely duplicates information that is better presented
elsewhere, at enormous height cost (it single-handedly forces the
glance layer into a 1–2 cell-wide ribbon, F5).

### F3 — Rail/decoupling stacks repeat in every consumer cell

The V1P8 bypass stack (3× 100nF, 2× 10uF, ferrite stubs VDDA18ADC/AON/
PLL/CSI/USB…) is drawn in **both** the U14 flash cell and the U15
PSRAM cell (and again in the core cell). The extras pass pulls a
rail's inline passives into every cell whose anchor touches the rail.
Readers can't tell where the caps "really" live, and cells bloat.

### F4 — No bus collapsing

FLASH_IO0..7 + CLK + DQS = 10 parallel wires with 10 labels;
PSRAM_IO0..15 ≈ 19; GPIO fans similar. Indexed net families are the
single biggest consumer of cell height after F2/F3, and a human would
draw one bus slash. The scene already flags `wire.bus` and net names
are `PREFIX<d>` — nothing consumes it.

### F5 — Whole-board arrangement is a wrapped strip, not a 2D sheet

Shelf-packing at `MAXW=2600` with the giant U9 cell means most rows
hold 1–2 cells: the whole board becomes a narrow vertical ribbon
(screenshot: everything in one column on the right half of the
viewport, left half empty). Band order after Power is scene order.
There is no notion of "MCU in the middle, memory beside it, connectors
at the edge" — the info to do it (per-band inter-connect counts, J/P
refs, rail topology) is all in the scene.

### F6 — Net labels are dead ends

A stub labeled `V1P8` or `NRST` gives no hint where the other end is
and isn't a jump target. `focusTarget`/`hotNet` exist (find box, click
highlight) but the labels themselves — the thing your eye is on when
you wonder "where does this go?" — carry no destination and no click
affordance. This is the digital equivalent of a hand schematic's
off-sheet reference ("NRST → 3B"), and it's missing.

### F7 — Glance layer carries no semantics

Far zoom shows uniform grey chips + band titles. No category color
(the server's `classifyByName` taxonomy that colors the block diagram
isn't in the scene), no band numbering, no minimap. Orientation at
far zoom is purely by reading tiny titles.

## Proposal — three tiers, all automatic

### P0 · Findability (small, do first)

1. **Fold sub-block bands into their authored sections.** Emit the
   section↔sub-block pairing in the scene (evaluator already knows
   which section precedes/owns each sub-block; worst case match the
   existing name-pairing rule). Cells from `flash/…` file under
   "Boot NOR Flash"; the module-title bands disappear; every sidebar
   page has its content. Fixes F1.
2. **Off-sheet references on net labels.** Every net stub label gains
   a muted suffix chip naming the owner cell of that net's link
   (`NRST · U11 ▸`); click = `focusTarget` jump, hover = highlight all
   occurrences (hotNet). For rails, the chip names the producer
   (`V1P8 · U19 ▸`) from `rails[]`. Fixes F6 — this alone converts
   "scroll and hunt" into "click through".
3. **Canonical band order + numbering.** Order bands power → core →
   memory → comms/peripherals → UI → connectors → bring-up (server
   emits each section's `classifyByName` category in the scene);
   sidebar order = canvas order; band titles get "3 ·" prefixes.
   Fixes half of F5 at trivial cost.

### P1 · In-cell readability (medium)

4. **Bus collapse.** Group a cell's parallel point-to-point wires by
   net family (`PREFIX<d>`, ≥4 members, same owner/partner pair) into
   one thick bus wire with a slash count and range label
   (`FLASH_IO[0:7]`); expand to individual wires when zoomed past a
   threshold (the LOD machinery exists) or when the bus is clicked.
   Fixes F4; shrinks memory cells ~3×.
5. **Rail stacks live once.** Draw a rail's bypass/ferrite stack only
   in its producer's cell (or the Power band card); consumer cells
   show a compact rail chip (`V1P8 ▸`, click-jump per P0.2).
   Fixes F3.
6. **Functionally grouped anchor pins.** Emit pinout `(group …)` /
   `(part …)` membership + pin roles (supply/ground/strap/io — the
   pin_roles classifier exists server-side) per pin in the scene.
   Order: supplies top, grounds bottom, groups contiguous in pad
   order with a small run label; side assignment prefers the side of
   the partner that consumes the group (ghost left ⇒ pins left) and
   falls back to height balance. Fixes the *order* half of F2.
7. **Deflate the main-IC cell.** Pin runs whose links are owned by
   another cell collapse to one partner chip row
   (`XSPIM_P2 → U14 ×11 ▸`); the anchor cell keeps in full only what
   it owns (power, crystal, boot straps, debug). With 4–6 also fixes
   the *size* half of F2 and unblocks F5.

### P2 · Spatial arrangement (larger)

8. **Connectivity-driven 2D packing.** Replace shelf-pack with coarse
   grid placement: highest-degree cell (the MCU) center, bands scored
   by shared-net count placed adjacent, connector-anchored bands
   (J/P/X refs) pushed to the outer edge, Power top-left. Same
   anchor+satellite idea as the PCB rough engine, at band
   granularity — deterministic, no solver needed.
9. **Semantic glance layer.** Category colors on glance chips (same
   palette as the block diagram), band numbers, optional minimap
   inset. With 8, far zoom reads like a floorplan.

## Implementation status (2026-07-05)

P0 and P1 are implemented (this branch):

- Scene (`render_json.zig`): hubs carry `sec` (authored sheet, sub-block-aware
  via `membership.computeSubBlockAttachments`); `sheet_meta` lists every
  authored sheet with its `classifySection` category; pins carry `role`
  (pwr/gnd) and `grp` (feature-group label); attached sub-blocks no longer
  page a duplicate module-title sheet. `isPowerName` (editor.js) now
  recognises `V1P8`-style rails — the root cause of the duplicated cap banks.
- Editor (`editor.js`): cells band by `hub.sec` (every authored section bands,
  even 1-cell); bands sort power → mcu → memory → clock → comms → sensor →
  analog → peripheral → protection → connector, numbered on canvas + sidebar;
  net rows carry partner/producer chips (click = reveal wire, dblclick = jump
  via focusTarget); ≥4-member indexed families collapse to thick bus rows
  (`FLASH_IO[0:7] ▸`, click label to expand/collapse — `expandedBuses`);
  passives + pulls draw once board-wide (`passClaimed` global; consumers show
  a producer chip instead); extras order supplies-top/grounds-bottom with
  authored groups contiguous + dim run headings.
- Measured (Node harness, real scenes): stm32n6 map 12002 → 10410 world-units
  tall with 13 authored bands (was 8 mixed-name bands), wires 448 → 350,
  labels 333 → 275; V1P8 stack no longer drawn in 5 cells; MCU cell deflated
  to 839×912. labstation: 21 authored bands; barracuda: 0 duplicate passives.

P2 shipped as well (2026-07-06): bands place into category-family **columns**
(power | mcu/clock | memory/comms | sensors/analog/peripherals |
connectors/bring-up) with a height budget + spill, so the map lands near a
landscape aspect instead of a ribbon (stm32n6 2508×10410 → 8985×2264;
labstation 15726 → 3586 tall). Mostly-empty columns accept the next family so
small designs don't smear. The glance layer is a real block diagram now:
category-colored band containers (washed fill + colored numbered titles),
cell chips with the component name nearly as large as the ref, and
**band-to-band edges** aggregated from the signal links (weight ∝ link
count — Core↔PSRAM 20, Core↔Expansion 18 on stm32n6), drawn under the boxes.

## Notes

- Perf: stm32n6 already freezes tab renderers; every collapse above
  (buses, rail dedup, partner-chip rows) also cuts drawn primitives,
  so P1 is a perf fix too.
- Scene additions needed (render_json.zig): section↔sub-block
  pairing, section category, per-pin group/role, rail producer is
  already there. All read-only, no DSL change, no design-file edits.
- Everything degrades gracefully on designs with no pinout files /
  no sections (rp2350b-core: buses + off-sheet refs still apply).

---

# Glance → system block diagram audit (2026-07-06)

Goal (user): from a bird's-eye view, *understand what the system does*,
then zoom in for the parts. The P2 glance is a good **floorplan** — colored,
named, packed — but a floorplan answers "where is everything", not "what is
this machine". This audit lists what separates the two, and ideas.

## What the glance draws today

At `s < GLANCE_S (0.30)` — a hard cutover, no intermediate level — the map
draws: the band boxes (the literal detail-layout rectangles, washed +
numbered colored titles), one chip per cell (ref + part name), and
`bandLinks` edges: **undirected, unlabeled** grey lines, straight
center-to-center, width ∝ raw count of point-to-point signal links; power
is excluded entirely (editor.js ~2159-2173, draw ~395-425).

## Findings

### G1 — Geometry is inherited from the edit layout, not designed

Glance boxes are the detail rectangles, so box **area ∝ editing detail**
(pin rows, extras stacks), not system importance. The MCU band is huge
because it has many pins; a 3-part RF front-end is a sliver. Bands are
column-width and tall; block diagrams use squarish normalized blocks.
Zoomed out, visual weight is essentially noise.

### G2 — Edges say "talks to", never *what* or *which way*

No arrowheads (who drives whom), no labels (which interface — "XSPI",
"USB HS", "SWD"), no class distinction (power / clock / control / RF).
And power edges don't exist at all — the single most useful
system-understanding relation ("what powers what, at which voltage") is
invisible, even though `rails[]` in the scene already carries
producer hub + nominal voltage + aliases. Straight center-to-center lines
also cross through unrelated boxes (no routing).

### G3 — No purpose captions

A band shows only the section *name*. The authored **subtitle** — the
one-line spec the author already writes (`"TPS62823 12V-to-3.3V, 2A"`,
`"USB 2.0 HS via USB-C"`) — is not in the editor scene (`sheet_meta` is
`{name, cat}` only; `Section.description` + explicit `Section.category`
override exist server-side and go unused here). Chips show part numbers;
part numbers tell an expert what a block is, but *function* is the
subtitle's job.

### G4 — No system boundary / external world

A block diagram shows what crosses the board edge: connectors as
outward-facing stubs ("USB-C ▸ host", "SWD ▸ debugger"), antennas,
off-board loads. Here connector bands are ordinary boxes in the last
column, and the boundary endpoints the diagram engine synthesizes
(antennas / EMVS cells, `Node.is_boundary`) don't exist in the editor
scene at all.

### G5 — The server already computes the real block diagram; the client re-derives a worse one

`src/diagram/collect.zig` builds a directed `Graph` from the flattened
netlist for the /schematics Layout tab (page being **phased out**):
nodes carry label, **subtitle**, category, headline `parts`, rails,
`maturity`, `is_boundary`; edges carry **driver direction**, **class**
(power/clock/control/RF + designer-declared), a **derived bus label**,
voltage, and fanout (diff pairs + parallel nets collapsed). GND dropped,
net-ties merged, section↔sub-block attachment applied. The editor glance
uses none of it — it recounts raw links client-side. Migrating this graph
into the editor scene is also how the Layout tab's capability survives
the /schematics phase-out.

### G6 — Zoom is a cliff, not a ladder

One threshold flips full detail ↔ glance. No intermediate "subsystem"
level (band-internal mini-diagram), no cross-fade, no minimap for
orientation while zoomed in. The schematic Layout tab's LOD ladder
(glance → blocks → detail) is the working precedent.

### G7 — Column packing is categorical, not connective

Category-family columns give left→right reading order, but nothing inside
or between columns responds to actual connectivity: a sensor that talks
only to the MCU can land far from it; two unrelated peripheral bands sit
adjacent. (This is the un-shipped half of old item 8 — connectivity-scored
placement; column packing was the shipped simplification.)

## Ideas

### B0 · Client-only quick wins (scene already has the data)

1. **Power-flow edges from `rails[]`.** Producer band → consumer bands in
   the rail color, labeled with the voltage ("3V3", "1V8"), arrowhead at
   the consumer. Distinct style from signal edges (signal grey, power
   gold). Instantly answers "what powers what".
2. **Label signal edges by dominant net family / pin group.** The
   bus-collapse family logic (`famOf`) and per-pin `grp` names already
   identify interfaces; when one family dominates a band pair, label the
   edge ("FLASH_IO[0:7]", "XSPIM_P2"), else "×N".
3. **Direction heuristics + arrowheads.** Rail producer→consumer; band of
   category mcu = master toward peripherals; connector bands point
   outward. (Superseded by B1.6's real directions when that lands.)
4. **Orthogonal edge routing in the column gutters.** COL_GAP already
   reserves 150 wu between columns; route edges as 3-segment Manhattan
   paths through the gutters instead of center-to-center diagonals
   crossing boxes. Power enters a block's top edge, signals its sides.

### B1 · Small scene additions (render_json.zig)

5. **`sheet_meta` += subtitle + explicit category.** Emit
   `Section.description` and the `(category …)` override; glance bands
   render the subtitle as a caption line under the title — the author's
   own one-line spec becomes the block caption (same as the /schematics
   overview chips).
6. **Emit the diagram `Graph` as `block_graph`.** Compact nodes
   (sec-name-keyed so the client joins them to bands) + edges
   `{a,b,dir,class,label,voltage,fanout}`. Subsumes ideas 1–3 with
   authored truth (port classes, protocols, net-tie merges, diff-pair
   collapse) and brings `is_boundary` endpoints (antennas) in.
7. **Maturity dots on glance bands.** `Node.maturity` (amber concept /
   blue schematic / green done) already exists — one colored dot per band
   title makes the glance double as a project-status board.

### B2 · Dedicated glance geometry (bigger)

8. **Decouple glance geometry from edit geometry.** At far zoom draw
   *normalized* blocks — grid-snapped, near-square, sized by importance
   tier (MCU large, subsystems medium, single-part utilities small) — at
   positions derived from (but not equal to) the detail layout, each
   block's center kept inside its band's detail rect so zooming in lands
   where expected. Cross-fade between the two representations instead of
   the hard swap.
9. **Connectivity-driven glance placement.** MCU center, power column
   feeding from the left as a rail bus, connectors pinned to the outer
   edge as boundary stubs, peripherals clustered by their bus. Band
   granularity, deterministic — the PCB rough engine's anchor+satellite
   idea, one level up.
10. **Interface pills on block borders.** Small labeled tabs where edges
    attach ("USB", "SWD", "I²C") from pin `grp` names — reads like ports
    on a hand-drawn block diagram; click = jump to those pins.
11. **Legend + title block + minimap.** Category color legend, design
    title with the rail list (name + voltage), and a minimap inset while
    zoomed in (G6's orientation gap).

## Recommendation

Highest understanding-per-effort: **B0.1 + B0.2 + B1.5** (power arrows
with voltages, labeled bus edges, authored captions) — the glance then
states what feeds what, what talks over what, and what each block is for.
Then **B1.6** as the structural fix: one source of truth for the block
diagram, and the migration path for phasing out /schematics. **B2.8** is
the visual-quality leap that makes it look hand-drawn rather than packed.

## Shipped (2026-07-06)

**B0.1 + B0.2 + B1.5** landed as "editor glance block diagram": gold
power-flow arrows with voltage entry-tags from `rails[]`, signal edges
captioned by dominant net family / single net / count (pill-backed
labels), authored section subtitles as band captions (`sheet_meta.sub`),
edges clipped to box borders.

**The function tier** landed on top (hand-authored LOD0): a new
`(function "name" "caption" [(stack N)] (hosts "Section" …))` design-scope
form (`FunctionSpec` in env.zig, `buildFunction` in builders.zig, scene
`functions[]`). In the editor, member bands pack as one rigid mega-unit
(vertical stack under a `FN_HEAD` header) so the function box is exactly
the bbox of its bands at every zoom; the tier activates via
`fnTierActive()` — whole-board camera view (cam covers >77% of the map,
viewport-independent, so "Fit" shows the story) or below `FN_S = 0.18`.
It draws super-block cards (name + verb caption + ×N offset-card stack),
member bands wash-only, standalone bands titled, and **rolled-up edges**
(power tags unioned, signals summed with the dominant bus label kept;
intra-function edges drop out — the XSPI buses vanish inside "Compute
Core", which is the point). Click/dblclick a card frames it → band tier.
Authored on stm32n6 (5 functions) and labstation (7, PSU `(stack 2)`);
designs with no `(function …)` forms are pixel-identical to before.
