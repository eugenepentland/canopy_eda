# Autorouter audit, round two — what the router still needs, and where the leverage is

**Date:** 2026-08-04. **Scope:** the whole-board autorouter rooted at
`src/placement/router.zig` (+ its maze/A* core, rip-up ladder, direct-synthesis
probes, fine-rescue, diff-pair engine, and the `bench-route` harness).
**Method:** read of `router.zig`, `optimizer.zig`, `diff_route.zig`,
`route_session.zig`, `route_timeline.zig`, `route_policy.zig`, `guardian.toml`,
`bench_route.zig`, the placement test corpus, the serving seam
(`pcbRouteApi` / the live-route job), and the three prior router documents
(`docs/archive/autorouter-audit.md`, `docs/archive/autorouter-plan.md`,
`docs/archive/autorouter-wall-time.md`). This document is deliberately *fresh*: it does
not re-argue the closed questions; it names the gaps those audits left open and
adds new ones.

---

## 1. Health, in one paragraph

The router is a genuinely capable, actively-maintained grid maze router: exact
clearance, per-net classes, pour-aware connectivity, a bounded rip-up ladder, a
CDT rescue tier, coupled diff-pair routing with length/skew equalization,
RF keepout/fence lanes, an interactive session that presents stuck nets with
reasoned blockers, and a corpus benchmark. The wall-time audit's speed work
took whole-board routing on the scored boards from **1007 s → ~170 s (~6×)** at
flat or better completion, and closed-era boards hit **90/90 engine-routed**.
The codebase is disciplined: zero `TODO`/`FIXME` litter, no random seeds (the
router is deterministic given an input), and the tied-cost queue ordering by
bend count is a correctly-thought A* detail.

The persistent weaknesses are not in any one mechanic. They are (a) the
**search is single-net, first-routed-wins** — each net is locally minimized but
there is no whole-board refinement and no objective that rewards less copper or
fewer vias; (b) **failure is under-reported in the default path** — a batch run
returns a bare `routed/total`, and "which nets and why" requires the
interactive session or surgery; (c) **regression is under-enforced** — the
benchmark engine exists but its results are not durable repo state, and the
corpus is a handful of boards; and (d) the **two central files are monoliths**
(`router.zig` 13.6 kloc, `optimizer.zig` 12.1 kloc) whose passes are only
partially decomposed.

The rest of this document turns those four into prioritized, concrete work.

---

## 2. Already addressed — do not re-open these

So the round-two recommendations are not mistaken for proposals already closed:

- **DSL routing priority** — `(net-class … (priority …))` + inductor-aware
  `netClassRank`; the main pass now sorts by priority with authored priority
  dominant (`test "netPriority ranks the hot loop first …"`).
- **Overlap + 45° discipline for stubs** — escape/ground/pad stubs now check
  clearance, pad-gateway off-grid escapes exist, and DRC itself grew
  track↔track / track↔pad checks with per-emit probing.
- **Failed-net observability (partial)** — `router_claimed`, `StuckReport` with
  frontier + occupancy + ranked blockers in the interactive session, and
  `route_diagnose`.
- **Bounded rip-up / vacate tier** — `ripup_max_nets`/`ripup_max_tracks`, and
  the gap-closer now vacates the cheapest-to-restore copper.
- **Wall-time speedups** — copper spatial index, per-net direct-probe budget,
  and the 6 mm span gate on the direct synthesis (**Step 3 of the wall-time
  audit shipped**; Step 4, the retry-ladder budgets, was evaluated and
  **deferred**).
- **Diff-pair coupling** — coupled centreline routing, pad-sequence threading,
  skew/length equalization, twist absorption, hairpin cutting.
- **RF keepout/fence** — halos, crossing-gate by angle, via fences, escape
  zones; keepout now admits same-class copper.
- **Pad-exit interior landing points** — the fix that actually closed
  barracuda's thermal-pad and QFN edge cases.
- **Interactive whole-board session** with hints (waypoints, forced rip, layer
  override, reorder, abandon) and live progress/cancel/replay in the route dock.
- **Negotiated congestion: measured net-negative and dropped.** The committed
  position is to not re-approach global congestion via PathFinder-style
  negotiated routing.

---

## 3. Fresh findings, in priority order

### 3a. No durable benchmark ledger — "the router got better" is still not a checkable claim [HIGH]

The `bench-route` harness (Stage 0 of `autorouter-plan.md`) is built and
instrumented (`--breakdown`), and the wall-time doc prints credible tables. But
**the results are not committed repo state**: there is no `[benchmark]` ledger
and no checked-in baseline JSON. A change's effect lives in a chat transcript,
not in git. Two blockers make this concrete:

1. **The corpus is ~3–5 scored boards.** `autorouter-plan.md` says the corpus
   "is effectively three boards"; the wall-time doc's scored table lists ~5, and
   several designs (barracuda-base, straps-base, labstation, rf-switch-8way)
   are **excluded because they have no blessed placement** — they route nothing
   at a fallback pose. Every prior "X improved barracuda" lesson (two of which
   were net-negative *on the same board they were built for*) exists precisely
   because the sample was too thin.
2. Nothing fails the build when a board regresses a net.

**Recommended (cheap, highest leverage):**
- Commit a baseline: `netlisp bench-route --project-dir projects/designs
  --breakdown --json out/baseline.json` and treat it as durable repo state (the
  plan's `[benchmark]` ledger, or a committed JSON).
- Add a Guardian/CI tier that **fails if the geomean completion drops OR any
  scored board loses >1 net** versus the committed baseline (the plan's exact
  gate). This is what makes every future router edit an answerable question
  instead of a one-board bet.
- **Bless the four skipped boards** so the scored sample covers dense/mixed/dual
  boards, not just the RF-heavy ones. Blessing is a placement problem, not a
  routing problem — it is the single biggest multiplier on the corpus's power.

### 3b. The default batch path hides which nets failed and why [HIGH]

This is the recurring user pain and it is only half-fixed. The *interactive*
session produces a rich `StuckReport` (frontier snapshots, per-layer occupancy,
ranked blockers with rip cost), and `route_diagnose.zig` reasons about failure.
But the default `POST /api/pcb-route` response and `describe_pcb_layout` still
return a bare `routed/total` (+ `router_claimed`). An agent or a human facing
"87/90" must either open the interactive dock or re-run with diagnostics to
learn *which three and why*. Every investigation on a failing board starts with
re-deriving this by hand.

**Recommended:**
- Shape the batch result's `unrouted[]` to carry, per failed net, the
  `route_diagnose` reason and the top blockers from the same frontier census the
  session uses (reuse the machinery — do not write new routing code). Surface
  it in `describe_pcb_layout` as `routed.unrouted[]` so the MCP/agent surface
  and the viewer agree.
- This is the difference between "the router reports a failure" and "the router
  explains a failure in board terms" — the exact outcome `autorouter-plan.md`
  calls the product goal, for a fraction of the negotiated-congestion budget.

### 3c. Retry-ladder and fine-rescue budgets are still uncapped on failing boards [MEDIUM]

The wall-time audit's Step 4 was evaluated on **barracuda** (which routes well,
so the ladder was ~17 s) and deferred. But the ladder is the **dominant** cost on
the boards with many failed nets — the same audit measured stm32n6 ~448 s of
535 s, black-canyon ~146 s of 194 s, barracuda-base ~241 s of 344 s in the
ladder (escalate ↔ rip-up ↔ last-resort ↔ fine-rescue). `fineWindowRescue`
re-runs the direct primitives per residual failed net (black-canyon's
`fine_rescue` alone ≈ 87 s with ~97 M dogleg probes). After Steps 1–3 of the
speedup, each probe is cheap, but the *number of ladder rounds and the fine
rescue window* are still unbounded against a ceiling.

**Recommended:**
- Re-measure on the failing boards (stm32n6, black-canyon) now that the copper
  index exists, then add: (1) a per-board ladder **wall-time ceiling**, (2) a
  `fine_rescue` window/nodes budget scaled to the residual failed-net count
  (today `max_fine_grid_nodes`/`max_window_expansions` aren't tied to how many
  nets actually remain), and (3) a shared probe budget *across* the rescue, not
  just per net. `Effort.one_shot` already exists as the zero-ladder extreme; the
  goal is a knob between `standard` and `one_shot` that caps spend on the tail.

### 3d. No whole-board refinement, and length-matching is diff-pair-only [MEDIUM]

The architecture is single-net first-routed-wins; every net is locally
minimized by its A*/direct search, but nothing runs *afterwards* to shorten the
board: **no global trace-length reduction, no via-count minimization, no
copper-minimizing re-route of an obviously detoured net.** The straighten pass
polishes geometry (staircase/chamfer cleanup) but does not re-route for length.
And general trace-length matching exists **only for coupled diff pairs**
(`legSkew`/`equalize`); a matched-length **group** of independent nets (a data
bus, a clock + data) has no representation.

**Recommended:**
- Gate a **post-route refinement pass** behind the corpus: for each net whose
  current copper is measurably longer than its A* re-route (with DRC held flat),
  swap to the shorter path; prune redundant vias by re-running the maze with a
  higher via penalty and keeping the DRCC-clean shorter result. The risk
  (myopic gate-gated regression, the exact lesson of the negotiated-congestion
  attempt) is exactly what the Step 3a gate exists to catch — so land a it only
  when the corpus holds flat-or-better on geomean, DRC, *and* a new `trace_mm` /
  `via_count` column.
- Add length matching for independent nets via a DSL form (e.g.
  `(net-length-match "CDATA*" (tol 0.1))`) that equalizes the *set* with the
  existing raise/lengthen machinery, reusing `diff_route.equalize`'s approach
  rather than inventing a new one.

### 3e. The monoliths are the tax on all of the above [MEDIUM]

`router.zig` (13 666 lines) and `optimizer.zig` (12 091 lines) each exceed what
a single reviewer can hold in working memory, and the pattern is already proven:
the wall-time and keepout work repeatedly **extracted a pass into its own module**
(straighten moved out of router.zig; keepout, rf_shadow, via_guide, gap_policy
are separate). Guardian enforces per-file line-length and cast *ratchets*, but
not file/function size caps, so the two files pressure upward with no tripwire.
The maze/A* core, the rip-up ladder, the direct-synthesis probes, and the fine
rescue are each natural, budget-carrying modules (they already read as sections).

**Recommended:** continue the decomposition explicitly — maze core, rip-up
ladder, direct synthesis, fine rescue, route cost model — each with its own
header doc, constants, budget knobs, and test file. This is what makes 3c's
budget work and 3d's pass land safely: budgets and DRC-hold guarantees are
reviewable per module instead of inside a 13.6k-line file. Do not do this as a
big-bang move; do it pass-by-pass so `bench-route` holds at every commit.

### 3f. Determinism and parallelism are untested [MEDIUM]

The router uses no RNG and is deterministic today, and the vacate tier claims to
be "deterministic byte-identical." But a handful of `AutoHashMap` iterations
exist in routing paths (e.g. `crossed` net sets, `best` cost maps), and
`optimizer.zig` already uses thread-local mutable statics for background solves
— so the codebase is *adjacent* to nondeterminism and parallelism without any
guard.

**Recommended:**
- Add a **corpus determinism regression**: route each scored board twice from
  the same input and assert byte-identical `tracks`/`vias` (not just same
  counts). Cheap, and it converts "we believe it's deterministic" into a fact
  the CI enforces.
- Write down, in the router module doc, the current invariants that make
  parallel routing a hazard (per-net arena, global occupancy, first-routed-wins
  ordering) so a future parallelization is a deliberate design change with a
  measurably guarded rollout, not an accident.

### 3g. Thin tests in the highest-risk modules [MEDIUM]

Test count vs. complexity is very uneven. Diff-pair coupling — the most
complicated, most recently-written engine — has 19 tests across 2 974 lines;
the rip-up/vacate tier 7 tests across ~1 350 lines of `route_cleanup` +
`vacate_policy`; `keepout`/`via_guide` a handful each relative to the subtle RF
geometry they encode. The "one test per veil" discipline is strong for the maze
proper (76 in router.zig) but thins out exactly where regressions are most
expensive (RF, rip-up).

**Recommended:** target the rip-up/vacate tier and the keepout/fence halo (each
failed there has historically cost a board's last three nets) with combinatorial
tests — displacement succeeds/fails, cheapest-to-restore selection, halo
waiver between same-class members, escape-zone admission. The harness makes
these cheap to write as fixtures rather than whole-board runs.

### 3h. Guided-run A* heuristic is near-Dijkstra [LOW]

The A* heuristic is deliberately scaled by the minimum corridor discount
(down to 0.1× for a reference corridor) to stay admissible, which is correct but
**degenerates a guided leg toward Dijkstra** and burns its `expansionBudget` on
exactly the runs the guide is supposed to focus. The priority-queue comment in
`router.zig` shows the team already thinks hard about this (bend-count tie-break
is free and safe; pricing bends into cost was measured catastrophic). The open
lever is a **two-phase guide**: a cheap coarse search to settle the corridor
first, then a tight admissible heuristic *inside* it. Wire it behind the corpus;
if it doesn't hold completion flat, drop it — it is an optimization, not a
correctness claim.

### 3i. Thermal / current-aware width: implemented screening [DONE]

Power-load annotations now feed a shared IPC-2221 10 °C-rise model used by
both routing and post-route inspection. An unpoured rail reserves the
worst-layer full-current width; an explicit power plane or zone reserves that
width as its minimum neck while short component fanouts remain at their
authored geometry and are checked at solved local branch current. Power vias
route at the class/board via geometry and are judged after the fact: the
current solve divides a rail between parallel barrels, and the `via_current`
DRC rule reports each barrel that carries more than its plated area can take,
with the number of vias the transition needs. (Until 2026-09 the router instead
enlarged EVERY barrel on a rail to the single-barrel drill for the whole rail
current — wrong wherever barrels share, and a routing failure wherever the fat
barrel could not clear.) The resulting copper is still screened after routing
for local capacity and IR drop; this is conservative board-level screening
rather than a 3D thermal or IPC-2152 field solve.

---

## 4. Prioritized roadmap

| # | Work | Impact | Effort | Blocked by |
|---|---|---|---|---|
| 1 | **Durable benchmark ledger + corpus regression gate** (3a) | Makes every other improvement evaluable | Small | — |
| 2 | **Bless the skipped boards** → wider scored corpus (3a) | Multiplies the corpus's power | Medium (placement) | 1 |
| 3 | **Failure structure in the default batch path** (3b) | Closes the "which/why" gap; agent-actionable | Medium | reuse `route_diagnose` + session census |
| 4 | **Retry-ladder + fine-rescue ceilings on failing boards** (3c) | ~2–3× wall time on failing boards | Medium | 1 (measure) |
| 5 | **Pass decomposition** → maze/ripup/direct/fine modules (3e) | Makes 4 and 6 land safely | Medium, pass-by-pass | — |
| 6 | **Post-route refinement (length + via) + group length match** (3d) | Fewer mm, fewer vias, matched buses | Large | 1, 5 |
| 7 | **Corpus determinism regression** (3f) | Guards the "deterministic" claim | Small | 1 |
| 8 | **Test the rip-up/keepout thin spots** (3g) | Lower regression risk where it bites | Medium | — |
| 9 | **Two-phase guided A\*** (3h) | Faster guided legs | Medium | 1, 5 |
| 10 | **Current/thermal width** (3i) | Power-board correctness | Done | — |

**Sequence:** 1 → 2 → 3 → 7 are all small/medium and together convert the router
from "tuned by anecdote" to "measured by corpus, auditable in git, explainable
on failure." 4–6 follow the decomposition (5) so each is a reviewable,
bench-gated module. 9 remains optional; 10 is now implemented as conservative
screening.

## 5. Verification discipline (carried forward)

Every item above is gated by the same harness:
`netlisp bench-route --project-dir projects/designs --breakdown`. The gate is
**geomean completion flat-or-better and no scored board loses >1 net**, plus, for
quality items (3d, 3i), DRC error count and a `trace_mm`/`via_count` column held
or improved. Step 3a's ledger is what turns "hold" from a belief into a
failure. The prior audits' lesson is non-negotiable: *anything* tuned on one
board, even a board it was designed against, is untrusted until the corpus says
so.

---

## 6. Appendix — files that matter for the next edit

- Engine + maze/A* core, rip-up ladder, direct synthesis, fine rescue:
  `src/placement/router.zig`
- Placement/force-directed + optimizer progress:
  `src/placement/optimizer.zig`
- Coupled diff-pair engine + leg skew/equalize:
  `src/placement/diff_route.zig`, `diff_couple.zig`, `diff_pairs.zig`
- Failure diagnosis + interactive session (frontier/blockers/hints):
  `src/placement/route_diagnose.zig`, `route_session.zig`
- Timeline + progress sink: `src/placement/route_timeline.zig`,
  `progress.zig`; effort/knobs: `route_policy.zig`
- Serving seam (batch + live-route + cancel): `src/serve/pcb_layout_page.zig`
  (`pcbRouteApi`, `prepareRouteFromJson`, the live-route job)
- Benchmark harness: `src/bench_route.zig` (`--breakdown`, `--json`)
