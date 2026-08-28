# KiCad-Reference Routing Port — Audit & Plan

**Goal.** Make the netlisp tool the system of record for full PCB routing, using the
routed KiCad board only as a *reference*: import the barracuda RF frontend's
exact placement, outline, and copper into the netlisp design, then progressively
erase traces and prove the native router — steered by constraints authored in
the DSL — can reproduce equivalent routing. The `.kicad_pcb` is never modified
by this workflow; it is scored against, not re-routed.

Audit date: 2026-07-17, branch `claude/pcb-routing-audit-dsl-ed0879` (HEAD
`b99a41f`).

---

## 1. What already exists (audit)

The last wave of commits (`1fdea39` → `c4c7436` → `bf12fb5` → `1b21616`) built
most of the *experiment* machinery — but all of it is anchored to the
`.kicad_pcb` file at runtime.

### 1.1 KiCad reference-routing stack (`src/kicad_pcb/`)

- **`snapshot.zig`** — full physical `.kicad_pcb` parser: footprint poses
  (`(at x y rot)`, CCW, side from `(layer "B.Cu")`, locked), pads incl.
  custom-pad polygons, `segment`/`arc`/`via`, zones (boundary polygon +
  keepout permissions only — **filled polygons are not read**), Edge.Cuts
  outline (`gr_line/arc/rect/poly`), stackup, legacy + modern net tables.
- **`net_aliases.zig`** — canonicalizes aliased net names before comparison.
- **`experiment.zig`** — `virtualErase` (in-memory removal of selected nets'
  segments/arcs/vias; zones/planes retained) and `scoreCandidate`
  (fixed-geometry drift + hard-rule violations + copper burden, lexicographic
  objective).
- **`router_adapter.zig`** — adapts the KiCad board into the native
  `optimizer.Placement` + `RouteParams`. Retained copper becomes
  `ExistingTrack/Via/Zone` obstacles; copper zones are deliberately
  non-blocking (KiCad repours); keepouts block; **arcs are lowered to two
  straight segments**.
- **`reference_guides.zig`** — recovers routing hints from reference copper at
  three fidelity levels: `vias` (soft via sites) → `corridor` (soft
  centerlines + preferred layers) → `path` (hard waypoint replay). Emits the
  same `route_policy.NetPolicy` the DSL lowers to — *this is the seam that
  makes "same thing via DSL constraints" possible*.
- **`route_command.zig`** — `netlisp route-kicad-reference <board>` CLI:
  load → canonicalize → virtual-erase selected nets → adapt → guides → route →
  DRC → score vs a like-for-like baseline → JSON (+ `--output-png` preview).
- **`route_score.zig`** — lexicographic candidate-vs-reference score:
  `missing·1e12 + new_err·1e9 + new_warn·1e6 + return_path·1e3 + vias·20 + mm`.
- **MCP tools** (`src/serve/mcp_import_tools.zig`): `inspect_kicad_layout`
  (counts, outline, per-layer copper, zones, `.kicad_pro` net classes,
  optional per-net metrics), `benchmark_kicad_routing` (virtual-erasure and
  candidate-score modes; does not route), `parse_kicad_netlist`.
- **`/route-review`** (`src/serve/route_review.zig` + `route_review.js`) —
  interactive timeline: upload a board, the server erases *all* copper,
  re-routes in memory with `router.routeWithTimeline`, and the browser plays
  back every net/plane/rip-up decision with full copper state per step.
  Upload-only; nothing persists. (Its unit test literally uses
  `Baraccuda_RF.kicad_pcb`.)

### 1.2 Native design-side machinery

- **DSL forms** (all merged, in `docs/language-forms.md`): `(stackup N (plane
  IDX "NET") (pour …))`, `(net-class "n" (width)(clearance)(via)(priority
  0-7)(diff-pair [GAP])(nets …))`, `(design-rules …)`, `(board (size …) …)`,
  and `(pcb-plan (route (wave "n" (classes|net-classes|nets …)
  (preferred-layers …)(allowed-layers …)(waypoints (at X Y "F.Cu")…)
  (max-vias N)(rest))))`. `plan_resolve.zig` lowers route waves to
  `NetPolicy` (wave priority, layer bitsets, must-visit waypoints, via
  budget) — identical type to what `reference_guides` produces.
- **Router** (`src/placement/router.zig`): A* grid maze (pitch =
  width+clearance), plane-via pass, priority-ordered signal pass, bounded
  rip-up, diff-pair corridors, return-path stitching, pad gateways, partial
  routing via `selected_nets` + existing-copper obstacles, timeline capture.
  Caps: 200k nodes/layer (`grid_overflow`), per-net expansion budgets
  (`search_limited`).
- **Persistence** (`src/serve/pcb_layout_page.zig`): `<design>.layouts.json`
  `SavedLayout{parts[{ref,x,y,rot,origin,side,locked}], routes{tracks[{x1,y1,
  x2,y2,l,w,net,g}], vias[{x,y,d,drill,net,g}]}, outline{x,y,w,h,pts?},
  texts}` — mm, y-down, layer index 0=F.Cu / 1=B.Cu / 2+=inner-signal, copper
  keyed by **net name**. MCP: `set_part_poses`, `set_board_outline`,
  `route_pcb` (per-net, holds other copper as obstacles), `clear_routes`,
  `save_pcb_layout`, `run_fab_readiness`.
- **Coordinate bridge** (`src/serve/sync.zig`): positions map 1:1 (mm,
  y-down, same origin); rotation/side convert via the unit-tested
  self-inverse `kicadRotToNetlisp(rot, back) = mod(360 − rot + (back?180:0),
  360)`; the sync placement guard rejects pose drift > 1e-4 mm / 1e-3°.

### 1.3 Barracuda RF frontend state

- Design `barracuda` ("Barracuda Signal Generator", the RF half) at
  `projects/designs/src/boards/barracuda/barracuda.sexp`; 35 top-level
  instances + 15 sub-blocks (VCO/mixer/DSA/LO/PLL chains + 6 power rails);
  `(hierarchical-ids)`; `(kicad-pcb
  "/mnt/nas/barracuda/Baraccuda_RF/Baraccuda_RF.kicad_pcb")` (double-c
  spelling is intentional).
- Reference board (NAS, mtime Jul 13): 4-layer 1.6 mm, ~169 footprints,
  **851 segments, 280 vias, 9 zones**, Edge.Cuts outline — fully hand-routed.
- netlisp sidecar `barracuda.layouts.json`: **one** manual starred layout,
  166 parts, placement-only — **no copper, no outline polygon**. The `.sexp`
  has **no `(stackup)`, `(net-class)`, or `(board)` forms** — all routing
  rules live only in the KiCad project today.
- The base board (`Baraccuda_Baseboard`) is currently **locked open in
  KiCad** — this workflow must not touch it (and doesn't need to).

---

## 2. Gap analysis

| # | Gap | Evidence |
|---|-----|----------|
| G1 | **No KiCad→netlisp layout import.** Nothing copies poses, outline, or copper into `.layouts.json`. `import-kicad` drops footprint x/y/side entirely; `snapshot.zig` reads everything but is consumed read-only. | `import_kicad.zig` never touches layout sidecars; no caller of `snapshot.parse` persists. |
| G2 | **Design has no routing-rule DSL.** No stackup/net-class/design-rules in `barracuda.sexp`, so design-native routing runs on defaults, not the KiCad project's rules (which `inspect_kicad_layout` can already read). | §1.3 |
| G3 | **Experiments only run against `.kicad_pcb`.** `virtualErase`, `reference_guides`, `route-kicad-reference`, and `/route-review` all take a board file/upload; none can use a design's stored reference layout. | `route_command.zig`, `route_review.zig` |
| G4 | **No reference→DSL distillation.** Guides are recovered from KiCad copper at runtime; there is no path that writes them down as authored `(pcb-plan (route …))` constraints. | `reference_guides.zig` |
| G5 | **Outline import missing.** Edge.Cuts *write* support is stranded on the unmerged `claude/edge-cuts-sync` branch; there is no Edge.Cuts → `SavedOutline` reader anywhere. | agent audit §3 |
| G6 | **Representation gaps**: native tracks are straight segments (KiCad arcs must tessellate); vias are through-only; zones/pours have no sidecar representation (planes only via `(stackup)`); no `(keepout)` authoring form; no length-matching beyond diff-pair skew warnings. | `router_adapter.zig:133`, `route_policy.zig` |

---

## 3. Plan

### Phase 0 — Ground truth & drift check (no code, ~half a day)

1. Copy `Baraccuda_RF.kicad_pcb` to a working location (never operate on the
   NAS file; the base board's lock is a reminder someone works in KiCad live).
2. `inspect_kicad_layout` (`include_nets`) on the copy: per-layer copper
   totals, **arc count**, **per-layer segment counts** (decides the stackup
   declaration — if inner layers carry tracks they cannot be declared planes),
   zone inventory (which of the 9 are full-layer pours vs islands vs
   keepouts), `.kicad_pro` net classes.
3. Netlist drift: the design renamed RF/IF/LO nets (`9da1a65`) — dry-run sync
   (`?dry_run=1`) + `parse_kicad_netlist` diff to build the net-rename map the
   importer must apply. Reconcile 166 netlisp parts vs ~169 board footprints
   (expect fiducials/logo-type KiCad-only items).
4. Baseline reference metrics: `route-kicad-reference` with no nets selected
   (baseline mode) for the reference DRC/return-path counts we'll score
   against.

### Phase 1 — Port the reference into the netlisp tool (the big one)

New command `netlisp import-kicad-layout <design> [--board <path>]` + MCP twin.
Reads the board via `snapshot.parse`; **writes only netlisp state** (the
KiCad file is opened read-only):

- **Poses**: match board footprints → design instances by `canopy_uuid`
  property first (the sync stamp — renumber-proof), then exact ref-des;
  convert with `kicadRotToNetlisp` + side from `(layer "B.Cu")`; positions
  copy 1:1 (same frame). Write into the design's single starred layout.
- **Outline**: Edge.Cuts items → ordered polygon (tessellate `gr_arc` at
  ~0.05 mm chord tolerance), validate with `outline.valid`, store as
  `SavedOutline` (bbox + pts).
- **Copper**: segments → `SavedTrack` 1:1; arcs → tessellated polylines
  (report count + max deviation); vias → `SavedVia` (flag any non-through);
  layer names → signal indices per the declared stackup. Net names go through
  the Phase-0 rename map + `net_aliases` canonicalization; unmatched
  nets/refs are **reported, never silently dropped**.
- **Zones**: not copied into the sidecar. Full-layer pours → generated
  `(stackup … (plane …)/(pour …))`; islands/keepouts listed in the report as
  known deltas. (Extending `SavedRoutes` with zone polygons is a deliberate
  non-goal for v1; revisit only if scoring shows it matters.)
- **DSL generation**: emit a ready-to-paste block — `(stackup 4 …)`,
  `(net-class …)` per `.kicad_pro` class (width/clearance/via/diff-pair),
  `(design-rules …)` from project minima — printed for review (author
  approves and pastes into `barracuda.sexp`), with a `--write` flag for later.

### Phase 2 — Fidelity gate ("identical" is proven, not assumed)

- **Poses**: file-based sync dry-run must report zero placement violations
  (existing guard, 1e-4 mm / 1e-3° epsilons) and an all-zero op summary
  (netlist-neutral).
- **Copper**: importer report asserts per-net length within tolerance
  (arc-tessellation delta only), exact via counts, per-layer totals matching
  `inspect_kicad_layout`.
- **DRC parity**: `drc.check` on the imported layout at the generated design
  rules ≈ the Phase-0 reference baseline (deltas explained or zero; expect
  vendor-land-pattern warnings à la the BK13H precedent).
- **Visual**: `/api/pcb-png/barracuda?route=1` side-by-side with the
  `route-kicad-reference` preview PNG.

### Phase 3 — Design-native progressive erasure experiments

Port the experiment loop's *data source* from `Snapshot` to `SavedRoutes`:

- Generalize `experiment.virtualErase` + `reference_guides.build` inputs to a
  neutral copper list (tracks/vias + net names) both a `Snapshot` and a
  `SavedLayout` can produce — mostly a thin adapter, since
  `SavedTrack/SavedVia` ≅ `ExistingTrack/ExistingVia` already.
- New `netlisp route-reference <design> --net … [--guide-mode
  vias|corridor|path|none]` + MCP twin `route_reference_experiment`:
  erase selected nets from the starred reference layout in memory, hold the
  rest as obstacles (`mcpExistingCopper` mechanism), build guides from the
  erased reference copper, route, DRC, `route_score` vs stored reference
  per-net metrics, emit JSON + PNG. **Request-local — never persists**; the
  starred reference layout is immutable during experiments. An explicit
  `route_pcb`/`save_pcb_layout` is the only way copper changes on disk.
- **Route-review design mode**: `GET /route-review?design=<name>` (or a
  design picker) that builds the same timeline JSON from the design's
  placement + reference experiment instead of an upload — the existing
  playback UI works unchanged.
- The ablation *ladder* itself stays agent-driven at first (loop over the MCP
  tool: 1 net → net family → module-policy class → whole board, at each guide
  fidelity); bake a batch runner into the server only if the loop proves
  routine.

### Phase 4 — Distill constraints into the DSL

- New `netlisp distill-route-plan <design>`: from the reference layout, per
  net emit compressed path vertices (`reference_guides` path-mode logic) as
  `(waypoints …)`, observed layer usage as `(preferred-layers/allowed-layers
  …)`, via count as `(max-vias N)`, and reference routing order (module-policy
  classes + RF chain) as ordered `(route (wave …))` waves. Output is a
  `(pcb-plan …)` block for review, authored into `barracuda.sexp`.
- **Acceptance ladder** (the point of the whole exercise): re-route erased
  nets using *only* DSL constraints (no copper-derived guides) and hit parity
  thresholds vs reference — start at: 0 missing nets, 0 new DRC errors,
  return-path warnings ≤ baseline, vias ≤ ref+10 %, length ≤ ref+15 %
  (tunable). Progression: waypoint-level DSL → layer+priority only →
  net-class only. Every rung that fails names a concrete router or DSL gap
  (candidates already visible: authored `(keepout …)`, curved-trace support,
  per-net width overrides).

### Phase 5 — Run it on barracuda

Execute the ladder end-to-end on the RF frontend, easy nets first: ground/
planes → DC rails → SPI/control → REF_LMX LVDS pair (diff-pair class) → IF
chain → LO chain → X-band RF chain last. Iterate the DSL (and router backlog)
until full-board routing from DSL constraints passes the Phase-4 gate and
`run_fab_readiness` is green. Deliverable: barracuda routes entirely inside
the netlisp tool; the KiCad file remains untouched reference ground truth.

---

## 4. Risks & open decisions

1. **Inner-layer tracks vs plane declaration** — if Phase 0 finds segments on
   In1/In2, those layers must be declared signal (plane-less stackup) or the
   copper has no home. Decide from data, not assumption.
2. **Arcs** — RF boards love curved traces. Tessellation changes geometry
   slightly (DRC/length deltas); the native router will never re-produce arcs,
   so scoring stays length/via/DRC-based, not geometry-match. Acceptable for
   the stated goal; note it in reports.
3. **Zone fidelity** — modeling the 9 zones as stackup planes/pours loses
   island shapes. Router already treats copper zones as non-blocking, so
   routing parity is unaffected; RF *electrical* fidelity of pours is out of
   scope for this workflow. Recommendation: accept for v1.
4. **Net-name drift** — the Jul-13 board predates/postdates recent net
   renames; the importer's rename map handles it, but if drift is large,
   consider a one-time KiCad re-sync *before* starting (user decision — it
   writes to the NAS board).
5. **Router capacity** — 37×30 mm at RF net-class pitches should fit the
   200k-node/layer cap, but Phase 3 must watch `grid_overflow` /
   `search_limited`; those are router work items, not workflow failures.
6. **Single-layout policy** — top-level designs keep exactly one starred
   layout; the imported reference *becomes* that layout (its placement half is
   already identical). Experiments never write; only explicit saves do.

## 5. Process notes

- All work under Guardian: each phase lands SPEC.md bullets + tagged tests +
  implementation in one `guardian-check commit` (new MCP tools also update
  `tools_list_result.json`; any new DSL form regenerates
  `docs/language-forms.md` via `zig build docs`).
- Related unmerged branch: `claude/edge-cuts-sync` (outline write-back +
  frame gates) — not required for import, but merge-worthy alongside Phase 1
  so outline flows both directions.
