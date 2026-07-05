# Autorouter audit — routing priority, overlaps, 45° discipline

*2026-07-05. Measured on `rp2350b-core` (starred layout) via `POST /api/pcb-route`
on a dev server (`NETLISP_DEV=1`, main-checkout binary + project dir).*

**Status: IMPLEMENTED same day** (branch `claude/practical-mestorf-9e51a0`), plus
one fix the audit missed — the fine-pitch **pad-gateway** (a 0.4 mm-pitch pad's
±0.11 mm escape lane vs. grid columns up to ±0.127 mm off-axis meant on-grid
escape was alignment luck; `routeNet` now enters/leaves pads through an off-grid
straight stub validated against pads/vias/tracks). Verified on the ★ layout:
31 crossings → **0**, DRC now sees track↔track, unrouted nets are named
everywhere, and with the `(net-class … (priority …))` tiers in the design,
routed goes 11/14 → **13/14** (crystal + full flash bus incl. CLK + SMPS all
connected; `FLASH_D1` remains geometry-boxed by the ground-via ring — the
`unrouted-net` lint reports it). Corpus spot-check (tpsm84338, lt3045,
adf5901): all fully routed, DRC 0, no regressions.

## Measured facts (rp2350b-core, ★ layout)

- **Routed 11/14 multi-pad nets.** The failures are exactly the user-visible ones:
  - `FLASH_CLK` — zero real copper; its only two segments are 0.13 mm pad-centre
    stubs. The U1→U2 maze leg never found a path.
  - `XTAL_IN` — partial; 1.63 mm of copper in 2 disconnected islands.
  - `DVDD` / `VDD3V3` — stranded legs. `VDD3V3` emitted 80 segments in ~18
    disconnected islands (some island counts are pad-copper artifacts, but the
    router itself counts the net failed). `DVDD` is the SMPS inductor's output
    net — `VREG_LX` routed but the DVDD side is split.
- **31 hard same-layer crossings between different nets** (actual shorts) plus
  10 sub-clearance pairs — *every one* involves an escape stub (GPIO0-47,
  SWDIO, USB breakouts) crossing routed copper (`VDD3V3`, `DVDD`, `FLASH_D1`,
  `FLASH_CS`, `RUN`) or another stub. The maze copper itself has zero
  crossings.
- **DRC reports 0 violations** on this same board.
- **141 of 270 track segments are off-45°** — all from the three stub families
  (escape stubs up to ~3 mm at arbitrary angles are the visible ones;
  sub-0.2 mm pad-access and ground-via stubs are the bulk of the count). The
  maze emits only orthogonal + 45° runs.

## Root cause 1 — routing order is effectively declaration order

`route()` pass 2 sorts nets by `netPriority` = `(part_priority << 3) | netClassRank(name)`
(`src/placement/router.zig:568`), no rip-up — first-routed wins forever.

- **`part_priority` is always 0.** It came from `(placement-order …)`, removed in
  the dead-form sweep; `prepare()` now allocates the array and memsets it to zero
  (`src/placement/optimizer.zig:6397`, comment says "unranked everywhere now").
  The high 29 bits of the sort key are dead. Doc comments in `router.zig`
  (pass-2 comment, `netPriority` doc, `NETCLASS_BITS` doc) still cite the removed
  form; the file header cites a `RouteResult.failed` field that doesn't exist.
- **`netClassRank` elevates only switch_node/input_rail, via `classifyNetName`
  on the name alone.** On this board *nothing* is elevated:
  - `VREG_LX` → `isPowerRail`'s `"VREG"` prefix wins → `.power` → rank 0. The
    inductor-aware upgrade (`module_policy.netClasses`: a signal/control net
    bridging a hub and an inductor ⇒ `switch_node`) is **not consulted** by
    `netClassRank`, so the RP2350's internal-SMPS hot loop gets no elevation.
  - `XTAL_IN`/`XTAL_OUT` → clock — deliberately baseline (Ph3 lesson).
  - `FLASH_*` → signal.
- So the sort is a no-op and nets route in flattened-netlist order = pin
  declaration order in the `.sexp`. The IOVDD block is declared first, so the
  **24-pad `VDD3V3` tree routes first**, claiming both signal layers around the
  QFN perimeter (power rails are maze copper — legacy stackup only planes
  ground). GND pass-1 via halos (stamped on *both* layers) further wall the QFN
  neighborhood before any signal routes. Flash (6 nets into a tight WSON
  corner), crystal, and the DVDD legs route near-last into a walled board.

## Root cause 2 — stubs bypass the grid (overlaps + non-45°)

Three copper families are emitted outside the maze — no occupancy, no 45°
discipline, incomplete clearance checks:

1. **Escape stubs** (single-pin breakouts; the GPIO ports): `escapeFan` checks
   the *via* against tracks (`viaClearsTracks`) and the stub against pads
   (tier 1 only) and vias (`segClearsVias`) — but **never the stub segment
   against routed tracks**. Tier 2 (`clear_stub=false`) skips even the pad
   check. Result: the 31 crossings above.
2. **Ground-via stubs** (pass 1): arbitrary angle, but stamped into `occ`, so
   the maze detours them — mostly safe, only a 45° cosmetic issue.
3. **Pad-access stubs** (`addStub`): pad centre → nearest grid node, ≤ ~0.18 mm,
   arbitrary angle. Harmless nubs, but the majority of the off-45 count.

**DRC cannot see any of this**: `drc.zig` v1 scope is via↔pad, via↔via,
via↔track, pad↔pad, annular, board-edge — track↔track/track↔pad are skipped on
the assumption "the router already enforces them through its grid", which the
stub paths (and hand-drawn/stamped copper) violate. Hence "routed 11/14 ·
DRC 0" on a board with 31 shorts.

Latent, not observed here: diagonal moves undermine the pitch guarantee in
theory — a later orthogonal run through a diagonal's untouched corner cell can
approach the diagonal centerline at ~0.71·g < g = width+clearance. The
corner-cut guard blocks the crossing case; the sub-clearance case is
geometrically possible and would only become visible once DRC checks
track↔track.

## Root cause 3 — failures are a bare count

- `RouteResult` = `{tracks, vias, routed, total}` — no failed-net list.
- Viewer shows `routed 11/14 nets`; `/api/pcb-describe` `routed:{trace_mm,
  tracks,vias,drc}` doesn't even include the count; `lint[]` has no unrouted
  entries; MCP `describe_pcb_layout` likewise. Nobody can see *which* nets
  failed without eyeballing the ratsnest.
- Sub-detail: a failed leg still marks its goal node `occ = net` "so later pads
  can target it" — later legs can weld to that stranded island and the copper
  looks locally connected while electrically split from the tree (counting
  stays correct; the drawing misleads).
- `planeViaPass` counts a ground net routed when ≥1 via drops; pads that found
  no DRC-safe via spot are silently skipped.

## Proposal A — DSL routing priority: extend `(net-class …)`

```scheme
(net-class "hot-loop"
  (priority 3)                       ;; NEW: route-order tier 0(default)…7, high first
  (nets "VREG_LX" "DVDD" "XTAL_IN" "XTAL_OUT"))

(net-class "flash"
  (priority 2)
  (width 0.09)                       ;; composes with existing geometry fields
  (nets "FLASH_CLK" "FLASH_CS" "FLASH_D0" "FLASH_D1" "FLASH_D2" "FLASH_D3"))
```

Why this form, not a new one:

- `(net-class …)` is already the per-net routing-rules form with end-to-end
  plumbing: `parseNetClass` → `NetClassSpec` → `netRulesOf` → `Placement.rules.net`
  → router `setNetParams`. One new field per hop.
- The router reserved headroom for exactly this: "Three bits leaves headroom
  for `(net-class …)` overrides (Phase 4)" (`router.zig:558`). This *is* Phase 4.
- Priority and geometry belong together — a hot loop typically wants width AND
  order.
- Suggested sort key now that `(placement-order …)` is dead:
  `(authored_priority << 3) | auto_netClassRank`, net index as stable tiebreak.
  Zero behavior change for designs without `(priority …)`.

Notes: `(nets …)` matches full or leaf name case-insensitively, exact only —
no globs. Worth adding `*` suffix matching (`"FLASH_*"`) while in there; the
match loop is one function (`netRulesOf`).

Bundle with:

1. **Make `netClassRank` inductor-aware** — consult the hub+inductor bridge
   upgrade (or call `module_policy.netClasses` instead of bare
   `classifyNetName`) so `VREG_LX`-style names get the hot-loop tier without
   authoring. Still gated to switch/input-rail, so the Ph3 "don't reorder
   clock/power globally" lesson stays respected.
2. **Failed-net observability** — add the failed net names to `RouteResult`
   (making the stale header doc true), surface as `routed.unrouted[]` in
   pcb-describe + a lint error per failed net + the viewer chip tooltip + MCP.
   Without this the priority knob can't be evaluated.
3. Optional next step if priority alone doesn't clear congested boards:
   **bounded rip-up** — after the sweep, for each failed net, rip the
   lowest-priority blocking net and retry once. That turns priority into "who
   survives congestion" without global reorder heuristics. (Full negotiated
   congestion routing is out of scope for the module-scale router.)

Rejected alternatives: overloading `(net-length … (priority …))` /
`(deprioritize …)` (placement-weight semantics, would conflate length
constraints with routing order); a new standalone `(route-order …)` form (a
second per-net list to keep in sync with net-class).

## Proposal B — overlap + 45° fixes (router, no DSL)

1. `escapeFan`: add a `segClearsTracks` check for the stub (same shape as
   `segClearsVias`); `trimStub` gets the same. Removes ~all 31 crossings.
2. Snap escape/ground stub headings to the 8 compass directions (the fans
   already snap to grid points; prefer 45°-multiple candidates). Makes the
   long visible stubs 45°-clean.
3. `addStub`: emit as an axis-aligned or 45° dogleg (or accept — sub-track-width
   nubs; cosmetic).
4. **DRC: add track↔track + track↔pad checks.** The v1 grid assumption is
   invalidated by stubs, hand-drawn copper, and stamped module copper. This
   makes overlaps visible regardless of router fixes, and covers the latent
   diagonal sub-clearance case.

## Suggested order

1. Failed-net reporting + DRC track↔track (make both problems *visible*).
2. Stub clearance + 45° snapping (removes the shorts and the visible angles).
3. `(net-class (priority …))` + inductor-aware `netClassRank` (completion for
   flash/crystal/SMPS on rp2350b-core).
4. Re-measure rp2350b-core; consider bounded rip-up only if still <14/14.
