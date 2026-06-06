# WIP: usable switching-regulator placement

**Branch:** `claude/busy-golick-2706ec`
**Status:** the "Open problem" below is **SOLVED** — functional groups now cluster
and zone into a power-flow layout. Root cause: cohesion/zoning lived only in the
scalar `constraintCost` (used to *select* among arrangements), but the spring
relaxation that actually *sets positions* had no cohesion force — so it never
*proposed* a tight block for the selector to pick. Fix: gave cohesion and zoning
**relaxation forces** (the position-space twins of the scalar terms). `tps55289-channel`
went from isotropic scatter (caps on all four sides, inductor 10 mm off) to
input-caps-left / output-caps-right zoned clusters with loop ≤ baseline and the
board still routes. Builds green, `zig build test` exit 0, guardian clean.
Experimental, **NOT deployed** (prod :7050 still runs the old binary).

See "What changed (the fix)" and "How to drive it" below. Remaining polish
(crisp single-row banks, inductor docked exactly at the SW pads, the
default-vs-opt-in product decision) is in "Still open".

## Goal

Make the auto-placer produce **usable power-supply layouts**, not tight blobs.
Trigger: the user judged the tuned `tps55289-channel` layout (obj 256, from the
score-oracle search) "definitely not usable."

## Root-cause diagnosis (the important part)

The objective is **per-part**: each part minimises its own HPWL + its own
decoupling-loop-to-IC, plus a global compactness pull. For a switcher this is the
wrong objective and produces an isotropic blob. Concretely:

1. **Functional groups were never used in placement.** A design's
   `(group "Output Filter" (C_OUT_A …))` forms are `env.Group` (for the
   diagram/BOM) — **distinct** from the constraints-DSL `GroupConstraint`. The
   optimizer only read constraint groups, and `resolveConstraints` *early-returned*
   when no `(constraints)` block was present. So `tps55289-channel` (which has
   functional groups but no `(constraints)` block) placed with **zero** grouping.
   Evidence: the 4×22µF output caps scatter across ~9mm (opposite corners of the
   IC) in both the auto layout and the oracle search; they must be one tight block.
2. **No functional zoning / power flow.** Real layout = `VIN-caps │ IC │ L │
   VOUT-caps`. The objective has no notion of sides, so input/output caps interleave.
3. **No copper room.** Packs courtyards to touching → only 12/13 routable, no room
   for the GND pour, thermal-pad vias, or SW pour.
4. (Earlier) the **score-oracle search optimised the raw objective**, ignoring
   groups — so it tore groups apart too.

## The four changes requested (user picked all)

1. Group clustering + zoning  2. Copper/routing room  3. Switching-loop rules
4. Make the search honor constraints

## Prior-session foundation (the scalar machinery the fix builds on)

All in `src/placement/optimizer.zig` unless noted. These shipped before the fix
above; the fix adds the *forces* that make them actually move parts.

- **Feed functional groups into placement cohesion.** `resolveConstraints` no
  longer early-returns on `!c.present`; it also reads `block.groups` (`env.Group`)
  and adds each as a `GroupTerm` (via `resolveGroupMembers` + `makeGroupTerm`).
  `Lowered.active` gates the `constraintCost` hot-path fast-exit (group-less,
  constraint-less designs still fast-exit — and the forces stay inert).
- ~~Cohesion = bounding-box~~ → **superseded**: the cohesion objective is now
  per-member centroid distance (bbox only pushed the 4 extreme members; see fix #2).
- **Zoning scaffold.** `GroupTerm` carries `hub`/`dirx`/`diry`; `makeGroupTerm`
  picks the largest non-member hub and the rail direction (now ground-excluded,
  fix #4). `constraintCost` pulls the centroid to the hub's connecting side.
- **Copper room.** `Params.route_gap` (mm) + threadlocal `g_route_gap` added to
  every keepout box — leaves a gap beyond touching. (Still belongs in final
  legalization, not the search keepbox — see "Still open".)
- **Params knobs** (defaults): `group_w = 2.0`, `group_zone_w = 1.0`,
  `route_gap = 0`, `group_loop_relief = 0`. Query params wired through
  `parseTuning` + `PngRequest` + `renderDesignPng` (`src/serve/pcb_layout_page.zig`).

## Root cause (was "Open problem")

**Cohesion was wired but did not cluster** — and the reason was *not* membership
(verified correct: the 5 Output-Filter refs resolve to `C156…C160`, etc.) and not
the bbox form. It was that **cohesion only existed in the scalar objective.**
`constraintCost` is consumed by multi-start *selection* and rotation
coordinate-descent — it picks the best of the arrangements the relaxation
proposes. But the relaxation (`relax` → `accumulateLoops`/`accumulateCompaction`/
`accumulateRepulsion`) had **no cohesion force**, so it only ever proposed
loop-driven scatter: each output cap independently hugs the *nearest point on the
tall central VOUT pad* (pad 11, 3.4 mm tall), which sends caps to the pad's top
and bottom ends → the y±4 split. With no tight-block candidate ever generated,
the selector had nothing tight to pick. (Confirms doc hypothesis 2's mechanism,
but the lever was the missing *force*, not the objective form.)

## What changed (the fix)

All in `src/placement/optimizer.zig` unless noted.

1. **Cohesion as a relaxation force** — `accumulateGroupCohesion` pulls every
   `(group …)` member toward the group centroid (`g_group_force·(centroid−pos)`),
   added to `relax`'s force accumulation. This is the position-space twin of the
   scalar `group_w` term, so the relaxation now *creates* tight blocks. The
   group's **largest hub member is the anchor** (the IC stays put so the cluster
   gathers around it); a *secondary* hub (e.g. the power inductor in the switching
   cell) is **not** the anchor and **is** pulled in, so it docks beside the IC
   instead of floating off (`U14` was 10 mm away in every prior layout).
2. **Cohesion objective = per-member centroid distance** (was bbox). The bbox
   `(maxx−minx)+(maxy−miny)` only exerts force on the 4 extreme members; the
   interior caps felt nothing. `Σ hypot(member−centroid)` acts on all of them.
3. **Zoning as a relaxation force** — `g_zone_force` pulls each member toward its
   hub's *connecting side* (the point a fixed reach beyond the hub edge along the
   group's rail direction). Migrates the whole cluster to one side → VIN caps land
   left, VOUT caps right (a power-flow layout).
4. **Zoning direction now excludes ground** — `makeGroupTerm` sums only the
   group's **non-ground** hub pads when picking the side. Ground pads are
   scattered all around an IC (and a switcher's exposed pad is dead-centre), so
   folding them in averaged the side away — the input bank was zoning *right*
   (toward the IC's right-side GND pads) instead of *left* toward VIN. Fixes
   hypothesis 3. (Both the force and the scalar term read `g.dirx/diry`, so one
   fix covers both.)
5. **Bank-loop relief (opt-in, `group_loop_relief` 0–1)** — caps in a ≥2-member
   *same-rail* group form a *bank*; collectively they only need the cluster near
   the rail, not each cap on its own access point. `bankLoopScale` precomputes a
   per-loop multiplier `1−relief` for bank caps (position-invariant, computed once
   in `prepare`), applied to **both** the loop *force* (`g_loop_force_scale` in
   `accumulateLoops`) and the loop *objective* (`constraintCost`). **Default 0**
   (off): it trades reported loop for tighter banking and is the only knob that
   measurably regressed a non-bank design (see Regression).
6. **Plumbing** — `Params.group_loop_relief`; `?group_loop_relief=` wired through
   `parseTuning`, `PngRequest`/`pngFloatOpt`, and `renderDesignPng`; the layout
   JSON now emits per-part `"origin"` (the stable `origin_key`) so group membership
   is inspectable from outside. Unit tests: `bankLoopScale` and
   `accumulateGroupCohesion`.

### Result on `tps55289-channel` (`?regen=1`)

| config (group_w / zone / relief) | hpwl | loop nH | layout |
|---|---|---|---|
| baseline (0 / 0 / 0)             | 95.7 | 16.7 | scatter, all 4 sides, L1 10 mm off |
| **8 / 2.5 / 0** (forces, no relief) | 84.0 | **15.0** | input-left / output-right zoned clusters, routes |
| 8 / 2.5 / 0.6 (with relief)      | 79.4 | ~20 | tighter banks, slightly longer loops |

Loop at the recommended `8 / 2.5 / 0` is *better* than baseline while the board
is zoned and clustered. Routes with F.Cu/B.Cu + GND vias (a few signal rats
remain, as in baseline).

### Regression (reported objective, `off` = forces disabled)

- **No groups → no change:** `tpsm84338`, `lt3045` byte-identical (they declare no
  `(group …)`, so the forces are inert — the `Lowered.active` gate holds).
- **Mild default `gw2/gz1/relief0` is safe:** `bank-rail` loop +3 %, `adp7118-ldo`
  +7 %, `tps54540-buck` −11 % (better). All within noise.
- **Strong `gw6/gz2/relief0` is mixed:** buck −14 %, `pma3-14ln` hpwl −15 % (both
  better) but `bank-rail` loop **+44 %** — clustering pulls its per-pin decoupling
  caps off their pins. So a *strong* global default is not safe; see "Still open".
- **Relief is the risky knob:** `gw6/gz2/relief0.5` pushed `adp7118-ldo` loop +34 %.
  Kept default 0.

## How to drive it

```
# the recommended switcher tuning (zoned, clustered, loop ≤ baseline):
GET /api/pcb-layout/<name>?regen=1&group_w=8&group_zone_w=2.5&group_loop_relief=0
GET /api/pcb-png/<name>?regen=1&group_w=8&group_zone_w=2.5&dims=1      # see it
GET /api/pcb-png/<name>?regen=1&group_w=8&group_zone_w=2.5&route=1     # routed
```

`group_loop_relief` 0.3–0.6 tightens cap banks further at the cost of a longer
reported loop — use only when the bank dominates (e.g. a 4–5-cap output filter).

## Still open (product + polish)

- **Default-vs-opt-in product decision (needs the user).** The forces ship with
  the *mild* default (`group_w=2`, `group_zone_w=1`, `group_loop_relief=0`), which
  is safe but too weak to auto-fix a switcher — the win needs the strong knobs.
  Three ways to deliver the strong behaviour without the `gw6` global regression:
  (a) keep mild default + tune per-layout via the API and **save the result** (the
  saved-layout system persists it); (b) **bump the global default** and accept the
  `bank-rail`-type loop regressions; (c) **add a constraints-DSL hook**
  (`(constraints (group-cohesion 8) (group-zone 2.5) (bank-relief 0.4))`) so a
  power design opts in declaratively while the global default stays mild — the
  cleanest fit with the existing "make the search honor constraints" design, a bit
  more parser work.
- **Crisp single-row banks + inductor exactly at the SW pads.** The force model
  produces coherent *organic* clusters, not crisp rows, and the inductor docks
  *near* the cell rather than precisely straddling SW1/SW2. Getting textbook
  `VIN-caps │ IC │ L │ VOUT-caps` rows is the **zone-then-pack** reframe: decide
  each group's side first, then place each group as a *rigid sub-block* (a row/grid
  of its members) rather than relaxing members individually. Bigger change; the
  current forces are the incremental step before it.
- **`route_gap` during search still destabilising** (unchanged from before) — it
  belongs in final legalization, not the search keepbox.
- **`ad7380-4` regen errored** in the regression harness (HTTP error — likely a
  size/timeout or a design-specific issue); worth a look but unrelated to these
  changes.

## Useful commands / artifacts

- Test server (Debug): `./zig-out/bin/netlisp serve --project-dir
  /home/epentland/ai/canopy/eda/projects/designs --port 7066`
  (the worktree's own `projects/designs` is empty — point at the main checkout's).
- Diagnose: `GET /api/pcb-layout/tps55289-channel?regen=1&group_w=…&group_zone_w=…&route_gap=…`
  → JSON has per-part `blame` + `loops`; render PNG with `?blame=1&dims=1`.
- Score an arbitrary pose set: `POST /api/pcb-score/<design>`
  `{"parts":[{ref,x,y,rot}…]}` (now leak-free — req.arena).
- Topology: `projects/designs/lib/modules/tps55289-channel.sexp` (18 parts: U1 IC,
  L1 inductor, 2 boot, VCC, FSW, 3 input, 5 output, COMP R+C, 2 pull-ups; declares
  6 functional `(group)`s).
- U13 pad map: `lib/footprints/tps552892qwryqrq1.sexp` (power pads 7–11 central,
  tall, vertical).
- Baseline numbers: auto **obj 309**, 12/13 routable, 107.9mm trace, 34 vias,
  inductor 10.6mm from IC. Oracle-search best (pre-group-work, deemed unusable):
  256, inductor 5.3mm (≈touching for these big parts).

## Earlier shipped work on this branch (for context)

`80d8175` courtyards touch-on-grid (overlap default off) · `eb11be3` PNG
diagnostic overlays (blame/loops/dims/grid/compare) · `639c8c9` JSON findings
sidecar on `/api/pcb-layout` · `3cd3758` `/api/pcb-score` leak fix + saved layouts
render verbatim. Plus the constraints DSL (`502b0ef`) and group-cohesion v1
(`d098a60`, now superseded by the bbox rewrite here).
