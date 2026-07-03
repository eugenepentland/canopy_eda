# Rough Placement Engine — Audit & Hybrid-Scoring Improvement Plan

*2026-07-03 · follows the rough-engine audit + 7 fixes merged in `7fd3b4c`*

---

## ✅ Implementation status (2026-07-03, subcircuits/modules only)

Scoped to **module-level layouts** (`lib/modules/`) per direction — full boards
(labstation, barracuda, cyclops/stm32n6) are out of scope for this pass. Built,
tested (`zig build test` green, guardian baselines refreshed), and validated on
the 24-module starred corpus via a ReleaseFast worktree server. **Not committed
to main / not deployed** — lives on branch `claude/awesome-kapitsa-78d8e6`.

**Shipped:**
- **Dense StyleMatch** (`src/serve/style_score.zig`, new): keeps the per-class
  per-edge COUNT discipline and adds `S_gap` (radial gap-band histogram overlap
  — tightness) + **D4 rotation symmetry** (best of 4 whole-module rotations, so a
  correct-but-rotated layout isn't a false zero). Emitted on `/api/layout-match`
  as `style_match_pct` + `style_terms{edge,gap,rot_k}`.
- **Hybrid score** (`hybridScore` in style_score.zig): `obj_rel · (1 + λ·(1 −
  style))`, physics objective read straight off each placement's `breakdown`. The
  reference scores exactly 1.0. `/api/layout-match` now returns `obj_rel`,
  `hybrid`, `rough_obj`, `star_obj`, `lambda`.
- **Starred-must-win calibration** (corpus sweep): λ pinned at **1.5** (plateau;
  hand layout beats its rough on **20/22** at λ=1.5). Surfaced two genuine
  **reward-misfits** — `adp7118-ldo` (rough physically better, obj_rel 0.56, but
  80% style → needs λ≈3.9) and `bcuda-vco-hmc733` (rough already reproduces the
  hand layout AND is tighter). These are objective/data findings, not λ bugs.
- **Best-of-family generation** (`src/serve/rough_best.zig`, new, additive
  endpoints `/api/rough-best/:name` + `/api/rough-best-png/:name`): restores the
  arbiter the audit found missing. Generates `{rough, force}` candidates, scores
  each with the hybrid, keeps the min, and **rigidly rotates the winner to the ★
  orientation**. Result on the hand corpus: **−9.5% mean hybrid, force wins 7/26
  (ina228 −40%, boost22 −35%, housekeeping −29%, neopixel −26%, lm74610 −24%),
  rotation re-aligns 6/26, zero regressions** (min over candidates). Visually
  confirmed the generated boards are clean and hand-like (ina228: 4 mm² vs the
  hand's 5 mm², correct edge grouping).

**Key correctness fix found during validation:** `solveForRequest(.{.rough=true})`
without `.regen` reads the stale auto-cache sidecar, so the "rough" being scored
was an old cached solve, not the engine's fresh output (inflated obj_rel wildly —
vco read 6.27 vs the true 0.75). Both the match and generation paths now pass
`.regen = true`. The corpus numbers above are post-fix.

**Not yet done (natural follow-ups):** `S_orient`/`S_adj` style terms (A1b);
`StylePrior` role-keyed model for ★-less modules (Phase C); UI wiring of a "Best
rough" button (needs prod-browser QA); persisting the winner as a named snapshot;
MCP twin of rough-best.

## ✅ Round 2 (same day): the pin-adjacent generator — near-hand generation

User direction: "most parts already say which IC pin they belong next to —
place them THERE, don't let the important ratlines cross, penalize crossings
(not GND / pull-up VDD legs) and overlaps." Implemented as a third candidate
(`pin`, commit `0fb2c69`), and it changed the game:

- **`solvePinAdjacent`** (optimizer.zig): anchor at origin; each part at its
  bound pad's along-coordinate on that pad's package edge — targets resolved
  from the decoupling loop's `hub_pwr_pin`, series-pair midpoints, else the
  fewest-hub-pads signal net. Per-edge **order = pad order** (important
  ratlines can't cross by construction); `pavPack` (pool-adjacent-violators)
  does a minimum-motion order-preserving 1-D relax where parts would collide,
  so uncrowded parts sit EXACTLY on their pads. Chains (RC loop filters,
  output matches) attach outward behind their partner; `orientPadsToIC` +
  `legalizeFinal` finish. **Escape-stub keepouts deliberately not applied** —
  they inflated the ring into a loose halo; dropping them took lmx2595 from
  obj_rel 1.46 → **1.008** (within 0.8 % of the freshly hand-cleaned ★).
- **Penalties**: `importantCrossings` (signal airwires + decoupling power
  legs; `.ground`/`.power`-class nets excluded via
  `module_policy.classifyNetName` — a pull-up's VDD leg rides the plane) and
  `overlapCount`. Candidate selection ranks on
  `hybrid × (1 + crossings/n) × (1 + overlaps)`.
- **Corpus (21 hand-starred modules)**: the generated winner's geomean
  obj_rel **1.41 → 0.972** — collectively *better than the hand layouts* on
  the physics objective — with mean style 54 → 71 %, important crossings
  11.8 → 3.6, zero overlaps. 13/21 beat-or-match hand (≤1.05); pin wins the
  arbiter 15/21 (rough 3, force 3). usb-hub-2514 (the old worst) 4.33 → 1.36
  with 57 → 3 crossings.
- Debug lens: `/api/rough-best-png/:name?variant=pin|rough|force`.

Remaining stragglers: neopixel (1.50 — hand is just tighter), tps631000
(1.30), lmk05318b (obj parity but style 31 % — its hand layout groups by
subsystem, not per-pin; the one module where the pin rule diverges from the
user's convention), ap33772 (18 residual crossings from its chain-dense PD
front end).

---

## The goal in one paragraph

The rough engine's job has always been "get components roughly where a human
would put them, then finish by hand." Today we have two disconnected ways of
judging a layout: the **physics objective** (wire + loop-inductance + tidiness
+ congestion, escalating to routed copper), which is style-blind, and the
**starred-layout match** (`/api/layout-match`), which captures hand-style but
only at side-of-IC granularity and only for designs that already have a ★.
This plan defines a **hybrid score** — a dense hand-likeness metric plus a
style *prior* learned from the approved ★ corpus, combined with the physics
objective and calibrated so that **every approved hand layout ranks first on
its own design** — and then uses that hybrid as the *selection* metric to
generate better rough layouts (best-of-family selection, prior-driven
seeding, and an interactive improve loop).

---

## Part 1 — Audit: where the engine stands today

### 1.1 Pipeline (verified at HEAD, post-`7fd3b4c`)

`Params.rough = true` is the **default** — the rough engine *is* the placer.
Dispatch in `runPlacement` (`src/placement/optimizer.zig:810`):

1. **Switcher boards** (`isSwitcherBoard`: anchor-hub inductor neighbor +
   input_rail/switch_node classes) → `packZoned` VIN│IC│L│VOUT flow rows.
2. **Hierarchical boards** (≥1 sub-block macro) → `runRough`: per-module
   nested solves **seeded from each module's own ★ layout**
   (`starredModulePoses`, optimizer.zig:2082, `remaining=true` so ★-covered
   parts pin and new parts place), loose parts partitioned into **glue rings**
   around their hubs, then `arrangeMacros` springs + `legalizeComposed`.
3. **Flat boards** → `packPadAnchored`: anchor = `pickAnchorHub` (net degree,
   area tie-break) → net-based side assignment (served-pad docking for bound
   caps) → `cohereGroups` (authored `(group …)` → one edge) →
   `dockSidesByTier` (tight 0.2 mm clear) → `refineSidesByPull` →
   `polishCrossings` → `orientPadsToIC`.
4. Degenerate fallback: declumped fast force relax.

Refinement after any fresh solve: `routedPolish` (≤16 parts, maze-routed tuck
per cap), `tightenPriorityLoops` (≤64 parts). `Part.locked` is honored by
every mover; `Params.remaining` ("Rough remaining") pins the ★-covered base
via `partialApplyLock` and places only the rest. Perf is a non-issue
(<0.2 s corpus-wide on ReleaseFast).

**Post-fix scorecard** (area_match vs ★): labstation 58→75, tps62933 60→70,
ap33772 31→46, adf4159 30→44, adp7118 50→67, dsa 75→100; the 100s/86/80 held.
Median across measurable designs sits around **70%** — decent sides, but a
third of the corpus still needs meaningful dragging.

### 1.2 The scoring surfaces that exist (physics side)

A three-rung fidelity ladder, all able to score **arbitrary poses verbatim**
(no re-solve):

| Rung | Function | What it measures | Cost |
|---|---|---|---|
| Surrogate | `scorePoses` → `Breakdown` | `hpwl + LOOP_W(12)·loop_nh_weighted + w_align(1.5)·tidiness + w_congest(2)·RUDY`; `INPUT_LOOP_BOOST=3×` on switcher input loops | ~ms, any size |
| Routed loops | `routedScorePoses` | same, loop term maze-routed | seconds, self-gates |
| Full route | `fullRoutedScorePoses` | `trace_mm + 2·vias + 25·DRC + 150·unrouted + loop + align` | slow, top-K arbiter only |

Plus `layout_lint` placement-quality gates (decap-far >6 mm,
hot-loop-not-tightest ×1.3, feedback-near-aggressor <2 mm, decouple-unbound)
surfaced in `pcb-describe.lint[]`.

**Key structural fact:** since rough became the default, there is **no
"pick the winner" comparison at the top level** — one deterministic rough
result is produced and polished. The old best-of-rough arbiter is gone. The
proven leverage point ("select on a better metric" — see Part 2) currently
has *nothing to select between*.

### 1.3 The imitation metric that exists (style side)

`src/serve/layout_match.zig` (322 lines): per **interchangeable class**
(`kind|value|footprint-0.1mm|sorted-netset`), per **anchor edge**
(left/right/top/bottom/center via shared `sideOf`), credit
`min(rough_count, starred_count)` per edge; `area_match_pct =
credited/total`. Coverage-aware (★-uncovered parts excluded from both
tallies, reported in `coverage.unmatched[]`). Surfaced as `/api/layout-match`,
MCP `compare_layout_to_starred`, and an async "★match N%" chip in the viewer.

What it deliberately does **not** measure — and these are exactly the axes a
hand-finisher still has to fix:

- **Distance/tightness** — a cap on the correct edge at 8 mm scores the same
  as at 0.4 mm (the TIGHT work was judged on `gapR→gapS` medians *outside*
  this metric for this reason).
- **Within-edge position/order** — bunched vs. smeared along an edge.
- **Orientation** — important-pad-inward or not.
- **Adjacency** — Cin next to the inductor vs. across the board.
- **Non-anchor structure** — side attribution is single-anchor; on labstation
  (347 parts) "left of the anchor" describes almost nothing.
- **Global rotation symmetry** — edges are board-global; a rough that lays
  out the identical topology rotated 90° from the ★ scores near zero.

It's a step function usable as a *report card*, too coarse to *rank
candidates* or to *drive search*.

### 1.4 The ★ corpus (data survey, 2026-07-03)

44 layout sidecars (6 boards under `src/boards/`, 38 modules in
`lib/modules/`), **29 starred**. Every starred pose is origin-keyed (the
migration completed), all top-side, none locked. Composition:

- ~11 power modules (bucks/boosts/LDOs/monitors: tpsm84338, tps62933,
  tps631000, mp8859, boost22, adp7118, lt3045, ldo3v3a, ina228, lm74610,
  ap33772), ~8 RF blocks (bcuda-*), 1 clock (lmk05318b), 2 MCU cores
  (rp2350b, w55rp20), 4 interface modules, 2 full boards (barracuda 166p,
  labstation 347p).
- **Provenance caveat: 5 of the 29 ★ carry `rough:true`** (bcuda-ldo1v8,
  bcuda-splitter, rp2350b-core, w55rp20, labstation) — the ★ was a machine
  output the user blessed, not a pure hand layout. Usable as "approved," but
  they must not dominate a *style-learning* corpus or the engine learns to
  imitate itself.
- Sidecars carry `ts` (save time) and per-layout `objective/hpwl/loop`
  scores, but there is **no design-version linkage** — staleness is only
  detectable by part-coverage counting (`layoutCoverage`).
- **No code aggregates across multiple ★ layouts.** Each ★ is only ever
  compared against its own design. The 29 approvals encode consistent,
  reusable preferences (tight decap gaps, flow rows on switchers, group
  cohesion, orientation conventions) that nothing currently learns from.

### 1.5 Gap summary (ranked by leverage)

1. **No candidate selection** — one rough result, no family, no arbiter, so
   metric improvements have nowhere to act (§1.2).
2. **Style metric too coarse to rank** — side-level counts only (§1.3).
3. **★ knowledge doesn't generalize** — a new design with no ★ gets zero
   benefit from 29 approved layouts; module ★-seeding (fix #3) transfers
   *poses* for the same module, never *style* across modules (§1.4).
4. **The two metrics are never combined** — objective and ★-match can
   disagree and nothing adjudicates; there is no calibration proving the
   objective agrees with the user's approvals (it demonstrably doesn't
   always: hand lmk = obj 877 vs auto 1657 in one direction; force solves
   that beat rough on objective while being worse to finish in the other).
5. Residual roughness: within-edge order still arbitrary, big-board macro
   arrangement (barucda block-side arbitrariness), multi-anchor attribution.

---

## Part 2 — Hard-won lessons that constrain the design

These are paid-for results from previous sessions; the plan treats them as
requirements, not suggestions.

1. **The leverage is WHICH metric you select on, not how hard you search.**
   The GA/ES experiment: a stronger optimizer pointed at the surrogate
   actively hurt (routed-worse basins); the standalone win was widening the
   routed-rerank *gate*. Corollary: build the hybrid as a **selection/rerank
   metric over a diverse candidate pool**, never as a stronger optimizer.
2. **Never proxy-guard individual seed passes.** Session-4 barycenter
   revert: a `crossings + loop-length` guard failed both ways (blocked a real
   win, missed a real regression). Score **whole candidates** with the real
   metric at the end; keep seed passes deterministic and unguarded.
3. **Interchangeability is real.** Bypass caps of the same class are
   fungible: match by **per-class per-edge counts**, never by name or greedy
   nearest-pairing (greedy gave 69% vs. the count method's 83% on identical
   data).
4. **To reproduce a specific hand layout, use its data (★ seed), not a
   structural heuristic.** The side-a-cap-by-its-pin heuristic regressed;
   capturing the hand layout as a seed/spec won. Heuristics generalize;
   data reproduces.
5. **The goal is hand-likeness / minimal finishing work, NOT score.** Stated
   explicitly by the user; `loop_nh`/objective alone are the wrong yardstick
   for the rough.
6. **A/B protocol matters**: ReleaseFast worktree binary on a spare port
   against the main checkout's designs dir; compare describe-vs-describe
   (never sidecar coords — `finalize()` recenters); `&regen=1` (cache
   contamination is real); always regression-guard the NORMAL path when the
   rough path shares code (the `cohere` flag exists for exactly this).
7. **Determinism is law** — guardian `ban-rng`; variation comes from
   enumerated variants or Wyhash, never `std.Random`; env gates only via
   `config.zig`; `optimizer.zig` is 9,099 lines — new machinery goes in
   **new files** (guardian file-size).

---

## Part 3 — The hybrid score

Three layers, each independently useful, composed at the top:

```
HybridScore(design, poses) =
    obj_rel(poses)                    # physics, normalized per design
  × (1 + λ · (1 − Style(poses)))     # style multiplier, Style ∈ [0,1]

Style(poses) = StyleMatch(poses, ★)         when the design has a usable ★
             = StylePrior(poses, model)     when it doesn't (or blended when ★ is stale/partial)
```

Multiplicative composition keeps it scale-free across designs (style acts as
a percentage penalty on physics), so one λ can be calibrated corpus-wide.
`obj_rel` = surrogate `Breakdown.objective` divided by the best-known
objective for that design (the ★'s own score when present, else best-of-pool)
— rung upgrades (routed/full-route) stay available for final arbitration
exactly as today.

### 3.1 StyleMatch v2 — make the ★ comparison dense enough to rank

Extend `layout_match`'s class machinery with graded terms. All terms stay
**per-interchangeable-class and count/distribution-based** (lesson 3), each
∈ [0,1], combined as a weighted mean with per-term breakdown in the JSON:

| Term | Weight (initial) | Definition |
|---|---|---|
| `S_edge` | 0.40 | existing per-class per-edge count credit (area_match) |
| `S_gap` | 0.25 | per class: compare anchor-gap distributions rough vs ★ — quantize `gap_mm` into bands (0–0.5, 0.5–1, 1–2, 2–4, 4–8, >8) and credit `min(count)` per band (a histogram-overlap; the count trick applied radially). Captures tightness — the `gapR→gapS` axis TIGHT was judged on. |
| `S_orient` | 0.15 | per class per edge: count of 2-pad passives with important-pad-inward, credit `min(rough, ★)` (reuses `importantPadLocal` logic) |
| `S_group` | 0.10 | per authored `(group …)`: fraction of members on the ★'s dominant edge for that group (cohesion agreement) |
| `S_adj` | 0.10 | class-adjacency: for each unordered class pair with courtyard gap < 1 mm in the ★, credit if the same pair is adjacent in the candidate (captures Cin-hugs-inductor, divider-pairs-together) |

Two structural fixes ride along:

- **D4 symmetry**: compute all tallies under the 4 global rotations (and
  optionally 2 reflections) of the candidate; `StyleMatch` = max. Kills the
  false-zero on rotated-but-identical arrangements. Cheap — tallies are O(n).
- **Multi-anchor attribution**: on boards where `pcb_describe` would attribute
  everything to one hub (labstation), attribute each part to its **nearest
  hub with a shared net** (the glue-ring partition already computes this
  ownership) and tally per-hub-edge. Falls back to single-anchor for flat
  modules — bit-identical there.

Where: extend `src/serve/layout_match.zig` (or split
`src/placement/style_score.zig` if it outgrows guardian caps); JSON gains
`style_match_pct` + `terms{}` alongside the existing `area_match_pct`
(kept for continuity).

### 3.2 StylePrior — learn the user's conventions from the ★ corpus

The generalization step: a design with **no ★** should still be scored
against "how Eugene lays boards out." Fit per-role statistics across the
approved corpus:

- **Keying — role-based, never netset-based.** `classKey`'s netset is right
  for same-design matching but cannot transfer across designs (net names
  differ). The prior keys on what already exists in
  `src/placement/module_policy.zig`: `(ModuleClass: buck/boost/ldo/mcu/
  rf_amp/generic) × (PartRole: input_cap/decoupling_cap/bulk_cap/
  feedback_divider/matching_element/…) × (NetClass where relevant)`.
- **Features per key** (robust stats: median + IQR, plain counting):
  - gap-to-served-pad (or to anchor) in mm
  - P(same edge as served pad) / P(same edge as the inductor) for input caps
  - P(important-pad-inward)
  - per-group spread (cohesion tightness)
  - for switcher classes: flow-row geometry stats (Cin→IC→L→Cout spacing) —
    these become `packZoned` seed parameters, not just scores
- **Fitting** = `netlisp fit-style --project-dir …`: walk every sidecar,
  take the ★ entry, **exclude `rough:true` ★s and keys with <3
  observations** (provenance + small-n guards), emit a versioned
  `lib/style-model.json` checked into the designs repo. Deterministic, no
  RNG, re-fit is explicit and diffable — when a new ★ is saved the model
  visibly changes in review.
- **Scoring** a candidate part: `f(x) = 1 / (1 + ((x − median)/max(IQR,ε))²)`
  per feature, averaged over parts with a matching key; parts with no key
  contribute nothing (score is coverage-weighted so unknown-role boards
  degrade to pure physics rather than noise).

Corpus honesty: ~24 hand-approved references is enough for medians/counts on
the common keys (decoupling caps: hundreds of observations; buck input caps:
~8–10) and nothing fancier. The math is deliberately at count-statistics
altitude — no ML runtime, no training pipeline, fits the guardian/Zig-only
constraint.

### 3.3 Calibration — "starred-must-win," the corpus as ground truth

The approved ★ layouts are the only ground truth for "what the user wants."
Use them to fit λ (and optionally the StyleMatch sub-weights):

1. For each starred design, produce candidates: the ★ poses themselves, a
   fresh rough (`?rough=1&regen=1`), a fresh force solve (`rough=0`), and
   the variant family from Part 4.
2. Score all with `HybridScore`. **Constraint: the ★ must rank #1** (within
   ε) on its own design.
3. Grid-search λ ∈ [0, 4]: report, per λ, the fraction of designs where ★
   wins. Pick the smallest λ in the plateau (physics keeps as much authority
   as the approvals allow). Leave-one-out for the prior half: fit the model
   on N−1 designs, verify the held-out ★ still wins — this is the test that
   the prior *generalizes* rather than memorizes.
4. **Every un-fixable violation is a reward-misfit finding** — a design
   where no λ makes the approved layout win means either the objective
   penalizes something the user wants (objective bug: file it) or the ★ is
   stale (data bug: coverage-gate it). This audit output is valuable on its
   own; it is the systematic version of the lmk 877-vs-1657 discovery.

Ship as `pub fn hybridScorePoses` (new `src/placement/hybrid_score.zig`,
composing `scorePoses` + the style layer), a `bench_layout` column
(`hybrid=`), and a calibration harness (extend `bench_layout --poses`, or a
script over `/api/layout-match` + `/api/pcb-describe` per the established
A/B recipe).

---

## Part 4 — Using the hybrid to GENERATE layouts

Where the score plugs into search — always as *selection over candidates*
(lesson 1), never as per-pass guards (lesson 2).

### Phase A — measure only (no behavior change)

- StyleMatch v2 terms + `style_match_pct` in `/api/layout-match` and the MCP
  tool; D4 symmetry; multi-anchor attribution.
- `hybridScorePoses` + bench columns; viewer score bar shows
  `obj · ★match · hybrid` (the async chip already exists — extend it).
- Run the calibration sweep; publish the λ curve and the misfit report.

*Acceptance: every starred design has a hybrid number; ★-must-win rate and
per-design violations documented; zero placement behavior change.*

### Phase B — best-of-family selection (the core win)

Reintroduce a top-level arbiter, now with the right metric and a **diverse
deterministic candidate family** instead of one result:

- Family (each is the existing engine with an enumerated knob, all
  deterministic): current rough · anchor rotated 90° · `cohereGroups`
  on/off · `ROUGH_PACK_LANES` 1 vs 2 · switcher `packZoned` vs ring (where
  `isSwitcherBoard`) · force solve (≤32 parts) · macro-arrangement
  tie-break variants for hierarchical boards (the barracuda block-side
  arbitrariness becomes *choice* instead of luck).
- Score all with `HybridScore` (surrogate rung); route-arbitrate the top 2–3
  exactly like today's `FULLROUTE_TOP` pattern; keep the winner.
- Cost: rough variants are <0.2 s each → a family of ~8 stays interactive.
- Regression guards: NORMAL-path (`?regen` objective) unchanged where
  shared code is gated; family selection behind the rough path only.

*Acceptance: corpus mean `style_match` and median `gapR` improve with no
routed-cost regression; the barracuda 72.7→47.9 block-side drop from the
audit is recovered (its cause is exactly what family selection fixes).*

### Phase C — prior-driven seeding

Feed the style model *forward* into construction (data-derived parameters
for existing mechanisms — not new heuristic passes):

- Per-role **target gaps** from the prior replace fixed dock constants where
  a key matches (`dockSidesByTier` pitch per class).
- `packZoned` row geometry seeded from the fitted switcher stats.
- Module ★-seeding already covers same-module reuse; the prior covers
  *"this is a buck I've never starred"*.

*Acceptance: A/B on ★-less designs (stm32n6, straps-base, adf5901…) judged
by StylePrior + lint counts + eyeball; starred corpus non-regression.*

### Phase D — close the loop with the user

- **Improve button** (`?improve=1`): bounded deterministic hill-climb on
  `HybridScore` over *unlocked* parts only — same-class swaps + small
  nudges, routed veto, exactly the `tightenPriorityLoops` machinery pointed
  at the hybrid. Complements "Rough remaining" (which places; this polishes).
- **Refit on approval**: when a ★ is saved, surface a "style model is N
  approvals behind — refit?" nudge (explicit, diffable; never silent).
- **Provenance tag**: saving a ★ over a `rough:true` layout the user barely
  edited keeps the tag; hand-drag beyond a threshold clears it — keeps the
  training corpus honest automatically.

---

## Part 5 — Risks & mitigations

| Risk | Mitigation |
|---|---|
| Small corpus overfit (29 ★, skewed to small power/RF modules) | count-statistics only; min-3 observations per key; leave-one-out gate; λ chosen at plateau minimum |
| Machine-blessed ★ pollute the style model (5 of 29) | `rough:true` excluded from fitting; provenance maintained at save time (Phase D) |
| Goodhart on the style metric | style is a *multiplier* on physics, never the sole score; routed/full-route rungs still arbitrate the top; lint gates unchanged |
| Netset class keys don't transfer across designs | prior keys on module_policy roles, never netsets (§3.2) |
| Stale ★ poisoning matches and refits | existing `layoutCoverage` gates both (already excluded from tallies; refit skips ★ with coverage < 90%) |
| Style prior fights physics on genuinely novel boards | coverage-weighted prior → unknown roles degrade to pure physics; λ bounded by calibration |
| Force-seed / NORMAL-path regressions from shared code | the established `cohere`-style gating + corpus `?regen=1` objective A/B on every change |
| guardian: file-size (optimizer.zig 9,099 ln), ban-rng, ban-env | new files (`style_score.zig`, `hybrid_score.zig`, `style_model.zig`); Wyhash only; config.zig for gates |

## Part 6 — Task breakdown

| # | Task | Where | Size |
|---|---|---|---|
| A1 | StyleMatch v2 terms (S_gap, S_orient, S_group, S_adj) + breakdown JSON | layout_match.zig / new style_score.zig | M |
| A2 | D4 symmetry + nearest-owning-hub attribution | style_score.zig, shared with pcb_describe | S–M |
| A3 | `hybridScorePoses` + bench `hybrid=` column + viewer chip | hybrid_score.zig, bench_layout.zig, pcb_layout_page.zig | S |
| A4 | Calibration harness + λ sweep + misfit report | bench extension or script (A/B recipe) | M |
| B1 | Deterministic candidate family (enumerate knobs behind rough path) | optimizer.zig dispatch (thin) + new file | M |
| B2 | Hybrid selection + top-K route arbitration + regression guards | same | M |
| C1 | `netlisp fit-style` + `lib/style-model.json` + prior scorer | style_model.zig, CLI wiring | M |
| C2 | Prior-driven dock gaps / packZoned geometry | optimizer.zig (gated) | M |
| D1 | `?improve=1` hybrid hill-climb (locked-aware) | reuse tighten machinery | M |
| D2 | Refit nudge + provenance-preserving save | pcb_layout_page.zig | S |

Order: **A (measure) → B (select) → C (generalize) → D (loop)**. A+B alone
deliver the user-visible win (better roughs on starred designs + honest
scoring); C extends it to new designs; D compounds the corpus over time.

## Open questions

1. Should the 5 `rough:true` ★s count as approvals for *calibration*
   (★-must-win) even though they're excluded from *fitting*? (Plan says yes —
   blessed is blessed — but labstation's ★ being a machine layout makes its
   "must-win" constraint weak.)
2. Is `center` a style the user ever intends, or always an artifact? (The
   prior currently treats it as a real edge.)
3. λ per design-kind (module vs. full board) or one global λ? Boards have
   much weaker ★ signal; plan starts global, revisits after the sweep.
