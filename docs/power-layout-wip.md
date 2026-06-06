# WIP: usable switching-regulator placement

**Branch:** `claude/busy-golick-2706ec`
**Status:** in progress — group-cohesion machinery built and wired, but **not yet
producing usable layouts**. The cohesion responds to its weight but does not
cluster functional groups (see "Open problem"). Safe to leave: builds green,
`zig build test` exit 0, guardian clean. Prod (:7050) and the dev server (:7065)
still run the **pre-group-changes** binary — these changes are experimental and
NOT deployed.

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

## What's implemented this session (committed)

All in `src/placement/optimizer.zig` unless noted:

- **Feed functional groups into placement cohesion.** `resolveConstraints` no
  longer early-returns on `!c.present`; it now also reads `block.groups`
  (`env.Group`) and adds each as a cohesion `GroupTerm` (via new
  `resolveGroupMembers` + `makeGroupTerm`). New `Lowered.active` flag gates the
  `constraintCost` hot-path fast-exit (so group-less, constraint-less designs
  still fast-exit).
- **Cohesion = bounding-box, not centroid.** `constraintCost` group term is now
  `group_w·(bbox_w + bbox_h)` over member centres (was `0.6·Σ|member−centroid|`,
  10× too weak and unable to co-locate).
- **Zoning.** `GroupTerm` gained `hub`/`dirx`/`diry`. `makeGroupTerm` picks the
  largest hub the group is NOT a member of, and computes the hub-local unit
  direction toward the hub pads the group's nets connect to. `constraintCost`
  pulls the cluster centroid to `hub.center + dir·(hub_extent_in_dir + ZONE_GAP_MM)`
  with weight `group_zone_w`.
- **Copper room.** `Params.route_gap` (mm) + threadlocal `g_route_gap` (set in
  `prepare`) added to every keepout box (`keepHw`/`keepHh`/`keepBoxOf`), so parts
  leave a gap beyond touching.
- **Params knobs** (defaults): `group_w = 2.0`, `group_zone_w = 1.0`,
  `route_gap = 0`. Query params `?group_w=`, `?group_zone_w=`, `?route_gap=` wired
  through `parseTuning` + `PngRequest` + `renderDesignPng` (`src/serve/pcb_layout_page.zig`).
- "Make search honor constraints" → use the **auto** placement (which honors
  `g_lowered` internally) rather than the external raw-objective Python search.

## Open problem (start here next session)

**Cohesion is wired but does not cluster.** Probe on `tps55289-channel` (output
0805 caps spread, `?regen=1`, zoning off):

| group_w | obj | output spread x×y (mm) |
|---|---|---|
| 0  | 309.0 | 3.0 × 8.2 |
| 8  | 312.2 | 2.4 × 9.6 |
| 30 | 364.4 | 2.2 × 10.2 |

So the term *takes effect* (obj rises, x tightens) but **y-spread grows and obj
worsens** — the opposite of clustering. `route_gap=0.4` also made it worse
(357.6). Hypotheses to investigate, roughly in order:

1. **Verify `block.groups` membership for the module.** Confirm the 5 Output-Filter
   refs actually resolve to the right part indices when `tps55289-channel` is
   rendered as a module (flattened refs are `C150…C161`). If membership is wrong,
   everything downstream is moot. (Add a temporary log in `makeGroupTerm`, or a
   unit test.)
2. **The loop term fights cohesion and wins.** Each output cap is pulled to the
   *same central VOUT pad* (`loop_w=6`). The TPS55289 power pads (VIN=7, SW1=8,
   PGND=9, SW2=10, VOUT=11) are tall vertical pads bunched in the IC **centre**
   (local x −1.08…+1.08, each 3.4mm tall reaching both edges). So "each cap at its
   VOUT pad" sends caps to different access points along a 3.4mm-tall pad → an
   irreducible vertical spread, and they end up top vs bottom (the y±4 split).
   bbox-cohesion on *centres* can't overcome a 6× loop pull. Options: (a) raise
   `group_w` only works if it doesn't blow up obj — it does; (b) **reduce the loop
   pull for grouped caps** (a group only needs ONE good connection to the rail, not
   each cap individually); (c) make cohesion **pairwise/adjacency** with a saturating
   form so it strongly wants members touching but doesn't distort globally.
3. **Zoning direction is wrong for central tall pads.** dir to VOUT pad ≈ (+1,0)
   → pulls the cluster *right* (over pins 14–17), but the caps should sit
   *above/below* the tall VOUT pad where it meets the IC edge. The pad-centre
   direction is the wrong signal; consider directing to the **nearest courtyard
   edge crossing** of the pad, or to the pad's far end (top/bottom), not its centre.
4. **route_gap during search is destabilising.** Adding the gap to the keepbox
   during relax/search spreads things and raises HPWL. It may belong only in the
   **final legalization** (leave room after placement is decided), not in the
   search objective. Reconsider where `g_route_gap` is applied.

Deeper reframe if the above don't pan out: the optimizer clusters around a hub by
construction (seedRing + relax + loop-to-centre). A switcher needs **zone-then-pack**:
decide each group's side/edge first (input W, output E, sensitive S, switching
cell tight at SW), then pack each group as a unit. That may be a placement-strategy
change, not just an objective term.

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
