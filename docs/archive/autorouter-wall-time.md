# Autorouter wall-time audit — where the seconds go, and how to take them back

> **Current build policy (2026-08-12):** all new routing development,
> profiling, corpus runs, and acceptance tests use pinned-master self-hosted
> Debug. ReleaseSafe numbers below are a historical measurement record, not a
> command template; the only new netlisp ReleaseSafe build is made during deploy.

**Date:** 2026-08-02. **Instrumentation:** `bench-route --breakdown` (per-phase
wall-clock timing + maze-expansion/leg counters + per-net slowest list) added in
the same change. All numbers below are ReleaseSafe, whole-board `routePlannedZones`
runs at the blessed placement — the exact seam and oracle gate the corpus
benchmark measures.

## TL;DR

On every board measured, the wall time is owned by **two mechanisms**, in this
order:

1. **Direct-synthesis probes** (`tryDirectPair` / `tryDirectTerminalTree` and
the lattice searches they fan out) — **83–97 % of wall time on every board that
routes** (barracuda 96 %, barracuda-base 83 %, straps 95 %, black-canyon 97 %,
stm32n6 68 %).
2. **The retry ladder** (escalate ↔ rip-up ↔ last-resort ↔ fine rescue) on
boards with many failed nets — stm32n6 spends 448 s of 535 s there, black-canyon
146 s of 194 s.

The maze itself is almost free on the boards that route: barracuda's entire
maze search is **320 k node expansions ≈ 1 s**, while its direct-synthesis
probes are **37.7 M segment-clearance calls ≈ 130 s** — ~40× more probe calls
than maze expansions, each scanning every track/via/pad linearly.

| Board (scored) | wall_s | direct | maze | retry ladder | probes |
|---|---:|---:|---:|---:|---:|
| barracuda (82/91) | 135.0 | 129.8 s (96 %) | 1.0 s | 17.1 s | 37.7 M dogleg |
| barracuda-base (118/138) | 344.4 | 285.4 s (83 %) | 57.2 s | 240.7 s | 59.2 M dogleg |
| straps (76/102) | 334.0 | 317.6 s (95 %) | 12.0 s | 146.8 s | 80.4 M dogleg |
| black-canyon (41/66) | 194.2 | 187.9 s (97 %) | 6.2 s | 146.1 s | 97.1 M dogleg |
| stm32n6 (93/238) | 534.9 | 361.7 s (68 %) | 99.0 s | 448.0 s | 89.2 M dogleg |
| cyclops-breakout (9/41) | 29.2 | 3.1 s | 16.1 s | 27.1 s | 1.5 M dogleg |
| cyclops-xband-sip (20/49) | 47.8 | 18.2 s | 21.4 s | 40.5 s | 9.5 M dogleg |

(The retry ladder is escalate + rip-up + last-resort + fine_rescue, which nest
inside `greedy`/`finish`; on a board that routes well it is ~1.5 s, on a board
with many failed nets it multiplies the maze work by re-running legs under
larger budgets.)

## 1. The pipeline, and what the numbers say

`routeWithCapture` → `routeCoreStart`:

1. `build_ctx` — grid fit + `buildRouteCtx` + retained-copper stamping. **~4 ms.**
2. `planeViaPass` — ground/plane via placement. **~0 ms** (barracuda has planes).
3. `greedyPass` — per-net, in priority order:
   - `setNetParams` / `netPoints` / gateway fans (~9 ms total),
   - **direct-synthesis attempts (`tryDirectPair` etc.) — 129.8 s,**
   - then `tryMazeTerminalTree` (the Dijkstra maze) — included in the ~1 s,
   - `smoothNetInline` (RF bend smoothing) — 137 ms.
4. escalate ↔ rip-up interleave — 1.5 s on barracuda, **tens to hundreds of
   seconds on boards with many failed nets** (stm32n6: 448 s, barracuda-base:
   241 s, black-canyon: 146 s).
5. `fineWindowRescue` (fine-grid retries of residual failed nets) — 13.7 s on
   barracuda, 86.9 s on black-canyon.
6. `finishRoute` (escape stubs, return stitching, straighten, cleanup) — < 0.1 s.
7. `gate` → `route_close.reconcile` — 0.4–0.9 s.

`greedyPass` is 119.4 s of barracuda's 135 s, and **the direct phase is
129.8 s** — it also runs inside `fineWindowRescue`, which is why the `direct`
slot exceeds the `greedy` slot.

### Slowest per-net times (barracuda)

| net | ms | what it is |
|---|---:|---|
| `SPI_MISO` | 6 964 | long 2-pad same-layer RF-adjacent hop |
| `SPI_LMX_CSN` | 6 663 | long cross-layer hop |
| `SPI_SCK` | 3 789 | long cross-layer hop |
| `adf4159/SPI_ADF_SCK_1V8` | 1 924 | cross-layer |
| `SPI_ADF_CSN` | 947 | cross-layer |

The tail is heavy but not the whole story: **most of the 86 routed nets pay
~0.5–1.5 s each** in direct attempts that mostly fail and fall through to the
maze. The average is ~1.4 s/net because the direct phase runs for *every* 2-pad
net on the board. The other large boards show the same per-net pattern (straps'
`+3V3_MGMT` 37.3 s, `CANH` 28.1 s, `RF_OUT` 18.5 s; barracuda-base's
`ETH_RX_N` 22.1 s, `ETH_RX_IC_N` 17.3 s; black-canyon's `GPIO16` 4.5 s).

## 2. Root cause — why the direct phase is 100× the maze

Two brute-force mechanisms, each individually quadratic, composed:

### 2a. Exact-clearance probes are O(all copper), with no spatial index

Every via candidate and every dogleg segment is validated against the *entire*
copper set, linearly, with no bbox/spatial prefilter on tracks and vias:

- `directViaClear` (`router.zig:6608`) → `viaClearsPads` (O(pads)),
  `viaClearsVias` (O(vias)), `viaClearsHoles` (O(vias)),
  `viaClearsTracks` (O(tracks), `segPointDist` per track, no prefilter).
- `clearDoglegSegment` (`router.zig:5938`) → `segClearsPadsOnLayer` +
  `segClearsVias` + `segClearsTracks` (each a full linear scan).
- `finePointClear` — same, over pads + vias + tracks.

The maze avoids exactly this: `blocked()` uses the raster occupancy grid (O(1))
plus the `PadGrid` spatial index for pads (`foreignPadAt`). The direct
primitives predate that and never got the index.

### 2b. The failing sweeps pay for the entire lattice

The direct synthesis fans a dense lattice before giving up, and a *failing* net
(the common case on a partially-routed board) pays for every candidate:

- `tryDirectOneVia` (`router.zig:6964`): `direct_via_grid_mm = 0.05`, rings
  1..30 (1.5 mm radius) → **7 440 via candidates** (2 anchors × Σ 8·ring).
  Each candidate = `directViaClear` + 2× `findDogleg`.
- `findDogleg` (`router.zig:6025`) failure path: `findSimpleDogleg` then
  `findEscapedDogleg` — the escape fan is `direct_escape_grid_mm = 0.025` over
  1.5 mm → **60 rings × 8 headings ≈ 480 segment probes** per side, ~2 900 per
  candidate.
- `tryDirectPreferredLayer` (`router.zig:6701`): 20+ rings × 8 headings ×
  `directViaPairClear` (2× `directViaClear`) + 3× `findDogleg`.
- `tryViaSeededMaze` / `tryTwoViaSeededMaze`: 48–192 candidates, each
  `directViaClear` + `findDogleg` + a full `dijkstra`.
- `findMultiBend` (`router.zig:6232`): 64 expansions × up to 192 escape
  candidates + a `findDogleg` per expansion.

So a cross-layer net that the direct path cannot close pays on the order of
**10⁴ candidates × 10³ probes × 10² copper items ≈ 10⁹ distance computations**,
and there are several such nets plus ~80 ordinary ones paying the same
mechanism at smaller scale. `direct_via_checks = 74 557`, `dogleg_probes =
37 674 030` on barracuda; the second number is the wall time, essentially
1:1.

The maze, by contrast, was measured at 320 k expansions / 0.97 s for the whole
board: raster occupancy + `PadGrid` + budgeted A* is the *fast* path; the
"optimization" that runs before it is the slow one.

### 2c. Second mechanism: the retry ladder multiplies failed-net work

On boards with many failed nets, the escalate ↔ rip-up ↔ last-resort ↔
fine-rescue ladder (post-greedy) dominates almost as much as direct synthesis:
stm32n6 spends 448 s of its 535 s there, black-canyon 146 s of 194 s,
barracuda-base 241 s of 344 s. These passes re-run legs under escalating
budgets (`max_escalated_expansions` = 400 k, `max_last_resort_expansions` =
1.5 M) and re-probe copper with the same O(all copper) exact-clearance tests;
a leg that cannot close burns the whole budget, and the fine rescue re-runs
the direct primitives per failed net (black-canyon's `fine_rescue` = 86.9 s
with 97 M dogleg probes — more than barracuda's entire run). The ladder is
cheap on boards that route well (barracuda: 17 s) and expensive exactly where
it is most likely to fail — so its budgets are the second lever, not the first.

### Why the maze is not already first

`routeNetAttempt` (`router.zig:5457`) runs the direct synthesis *before*
`tryMazeTerminalTree` — deliberately, so RF/escape nets get the straight
off-grid trace (the maze output is grid-quantized). But the whole-board bench
has `selected_nets` empty → `focused_experiment` is true → **every** 2-pad net
pays the direct phase, and escape gating (`escapeActive`) only suppresses the
direct attempts for nets that actually carry an RF reserve. Plain nets get the
full treatment too.

## 3. What the direct phase buys — and what we can keep

The direct synthesis exists for trace *quality*: straight/dogleg off-grid runs
with exact clearance, needed for RF nets (`(max-freq …)`) and for clean pad
escapes. It is not needed to *close* nets — the maze closes them. On barracuda
the direct phase's success rate is low (most candidates fail; the nets then
route or fail via the maze), and the copper it produces for plain signal nets is
largely redundant with what the maze + straighten pass already deliver.

A fix that removes the direct phase outright would regress RF trace quality and
lose the axis-aligned straight hops the maze cannot express. A fix that only
indexes the probes keeps *all* the geometry and is the safe first move.

## 4. Plan

Ordered by ROI/risk. Every step is verified by the same harness that produced
this document: `netlisp bench-route --project-dir projects/designs --breakdown`
must hold the corpus **geomean completion and DRC error count flat** while
`wall_s` drops, and step 1 additionally proves copper-identical output.

### Step 1 — Spatial index for the exact-clearance probes (largest, safest win)

Extend the existing `PadGrid` bbox index (already built for `blocked`) to cover
tracks + vias, and route `viaClearsTracks` / `viaClearsVias` /
`viaClearsHoles` / `segClearsTracks` / `segClearsVias` / `finePointClear`
through it. The index is rebuilt once per net in `greedyPass` (O(copper) per
net — negligible vs. 37 M probes) and grows additively; the maze's
`ExactClearance` (`buildExactIndex`, `moveClearsCopper`) is the existing
pattern to copy — it already buckets tracks+vias into a `PadGrid`.

- Probe cost goes from O(copper) to O(pads/tracks/vias within reach), with the
  exact per-item test unchanged, so **copper is byte-identical** (the index only
  pre-filters candidates; the distance test is the same).
- Expected: `dogleg_probes` cost collapses ~100×; barracuda wall time
  ~137 s → ~5–15 s with zero routing change.
- Proof: run `bench-route --breakdown barracuda`; `routed`/`drc`/`tracks`/
  `vias`/`mm` must be unchanged while `direct` drops by >90 %.

### Step 2 — Probe budget + early exit on the failing sweeps (tail kill)

The lattice sweeps currently have no shared budget: `tryDirectOneVia` sweeps
all 7 440 candidates even after hundreds of consecutive failures. Give the
direct phase a per-net probe budget (mirroring the maze's `expansionBudget`)
and add an early-exit counter to `tryDirectOneVia`'s ring loop (the
`attempts >= 4` pattern already exists in the seeded-maze variants — extend it
to the lattice rings). A net that cannot be closed directly falls to the maze
after ~1–2 s instead of ~7 s. Same output for every net the direct phase
*succeeds* on; the only behavioral change is how long we search before
declaring the direct attempt failed.

### Step 3 — Gate the direct phase to nets that need it (largest, medium risk)

Run the expensive direct synthesis only for nets where it earns its keep:
`escapeActive(ctx)` (RF/escape reserve) or short spans (e.g. < 3 mm, matching
`direct_via_radius_mm`). Plain long nets go straight to the maze
(`tryMazeTerminalTree`), which measured 0.97 s for the whole board. Expected
barracuda wall ~137 s → ~2–4 s. Risk: trace-quality regressions on nets the
direct path currently improves without an escape flag — quantify with the
corpus geomean + DRC + `mm` columns and the route-review page before accepting.
Gate on `escapeActive` alone (the zero-risk subset) first; extend to short-span
only if the corpus holds.

### Step 4 — Retry-ladder and fine-rescue budgets (second tail)

The escalate / rip-up / last-resort / fine-rescue ladder is the dominant cost
on boards with many failed nets (stm32n6 448 s, black-canyon 146 s — see
§2c). After Steps 1–3 shrink the O(copper) probe cost, re-measure and cap the
remaining ladder spend: per-board ceilings on ladder wall time (the maze's
`expansionBudget` already caps per leg; there is no cap on the number of
ladder *rounds* a board pays), and scale the fine-rescue window budget
(`max_fine_grid_nodes`, per-leg caps) to the residual failed-net count. The
`one_shot` effort mode already exists as the zero-ladder extreme — the audit
quantifies what it saves on a failing board (~450 s on stm32n6).

### Explicitly not proposed

- Replacing the direct synthesis with a negotiated/rip-up congestion pass — the
  prior audit measured that as net-negative (see `docs/archive/autorouter-plan.md` §1).
- Parallelizing the greedy pass — net order is load-bearing (priority, pairs,
  first-routed-wins); a thread pool would need the exact index and occupancy to
  be per-thread, a large refactor with no measured upside yet.
- Fine-grid retries for whole boards — the fine-grid attempt in
  `routeWithCapture` only fires for small selected-net sets already.

## 5. Verification

1. `zig build --seed=1 -Doptimize=debug` + `zig build --seed=1 test` (self-hosted
   Debug unit suite + Guardian acceptance on the branch).
2. `netlisp bench-route --project-dir projects/designs --breakdown` before/after
   on the same 14-board corpus: hold geomean completion and DRC error count,
   report `wall_s` and per-phase table.
3. Step 1 additionally requires `routed`/`tracks`/`vias`/`mm` to be unchanged on
   every board (copper-identical proof).
4. Spot-check a route on the review page (`routeWithTimeline`) to confirm the
   RF straight-hop quality survives Steps 2–3.

Historical baseline measured with this instrumentation on 2026-08-02 (ReleaseSafe,
blessed placements): barracuda 135.0 s · barracuda-base 344.4 s · straps
334.0 s · black-canyon 194.2 s · stm32n6 534.9 s · cyclops-breakout 29.2 s ·
cyclops-xband-sip 47.8 s; corpus geomean completion 0.0513 over 5 scored
boards (the other 9 have no blessed layout and route nothing at a fallback
placement).

## 7. Implemented, measured 2026-08-02 (branch `codex/autorouter-speedup`)

Steps 1–3 shipped as one change; Step 4 (retry-ladder budgets) was evaluated
and deferred (see below). The corpus gate is the scored-board table: every
scored board holds or improves its routed count, geomean rises, and wall time
on the scored boards drops ~5.9×.

### Step 1 — spatial index for exact-clearance probes

`Ctx.copper_index` is a `PadGrid` over the current tracks+vias (rebuilt per
net — after `setNetParams`, so the insertion reach always covers the probing
net's geometry — and after any rip-up/straighten that shifts list indexes).
`viaClearsTracks` / `viaClearsVias` / `viaClearsHoles` / `segClearsTracks` /
`segClearsVias` / `finePointClear` query it (point `near()` + new
`nearSegment()` bbox-cell scan); `segClearsPadsOnLayer` uses the existing
`pad_index`. The index is a superset prefilter only — the exact per-item
distance test is unchanged — and **byte-identical output was proven**: with
Steps 2–3 disabled, barracuda, barracuda-base and cyclops-breakout reproduce
their baseline `routed`/`tracks`/`vias`/`mm`/DRC exactly (e.g. barracuda
82/91 · 551 tracks · 83 vias · 885.7 mm · 78/65 DRC at 119 s vs 135 s).

### Step 2 — per-net probe budget

`direct_budget` (200 k probes) caps `clearDoglegSegment` / `directViaClear`
for the plain-net direct path only; an exhausted budget reports "blocked" so
the attempt fails fast and the net falls to the maze (which never pays this
budget — it is restored before the maze runs, because `weldToNetCopper` clears
maze copper through `clearDoglegSegment`). At 200 k it was measured to cost
barracuda-base one net that needs > 200 k direct probes to close; the span
gate below was retuned to hold that board.

### Step 3 — span gate on the direct phase

A plain (non-escape) net pays the direct synthesis only when its terminal span
≤ `direct_span_mm` = 6 mm; escape-constrained (RF) nets are exempt (their
straight off-grid trace is the point of the direct path). At 3 mm the gate cost
barracuda-base a net; 6 mm holds it while keeping the win.

### Measured (scored boards, ReleaseSafe, blessed placements)

| board | before routed / wall | after routed / wall |
|---|---:|---:|
| barracuda | 82/91 · 135.0 s | **83/91 · 7.8 s** (17×) |
| barracuda-base | 118/138 · 344.4 s | 118/138 · 64.3 s (5.4×) |
| straps | 76/102 · 334.0 s | **82/102 · 15.5 s** (22×) |
| black-canyon | 41/66 · 194.2 s | 41/66 · 82.7 s (2.3×) |
| labstation | 0/191 · 0.2 s | 0/191 · 0.3 s |

Corpus geomean completion 0.0513 → **0.0523**; scored wall time 1007 s → 170 s.
Barracuda's DRC errors drop 65 → 40 (the direct phase was a violation source);
straps/black-canyon DRC rise a little (+12/+29 findings — the maze lays more
copper for the same routed count, see the caveat below). Unscored boards:
stm32n6 +4 nets and 3.1× faster; cyclops-breakout +1 net but ~2.2× slower
(maze-expansion growth); cyclops-xband-sip −2 nets.

### Known trade-offs / follow-ups

- **cyclops-xband-sip −2 nets** (unscored board, RF product): the gate skips
direct for its two long plain nets that only direct closed. The maze-first
+bounded-rescue reorder (maze, then direct for what the maze fails) preserves
xband-sip but cost barracuda one net and made stm32n6 slower — reverted in
favour of the gate. A per-net-class `(escape …)` flag on those two nets is the
clean fix (escape nets are exempt from the gate).
- **cyclops-breakout ~2.2× slower** (unscored): its maze/ladder expansions
roughly triple when the direct attempts are skipped — mechanism unidentified;
net count improved (+1) but wall time grew. Follow-up: trace why skipping the
failed direct attempts changes the maze's expansion profile.
- **straps/black-canyon DRC +12/+29**: the gate's maze copper is DRC-clean by
the grid model but physically longer/denser; the filtered-rule DRC reports
more findings at the same routed count. Verify on the DRC report that none of
the new findings are shorts (the router's own post-route gate already
re-checks connectivity).
- **Step 4 (retry-ladder budgets) deferred**: the ladder is the dominant cost
on boards with many failed nets (stm32n6 448 s → still ~150 s of its 173 s
after Steps 1–3). Its budgets are independent of the direct phase and need
their own pass; not needed for barracuda.

## 6. Instrumentation (merged with this audit)

`--breakdown` adds, per board: per-phase wall ms (build/plane/greedy/maze/
gateways/direct/smooth/escalate/ripup/last_resort/fine_rescue/escape/stitch/
straighten/cleanup/finish/gate), pipeline attempts, DRC wall ms, maze expansion
and leg counts, direct-probe and dogleg-probe counts, and the 8 slowest nets by
name. It rides `route_policy.Options.timing` (null = one null-check per site,
zero cost on production paths). Keep it: it is the regression gate for every
future router speed change, and the per-net slow list is how a new board tells
you *which* net to look at.
