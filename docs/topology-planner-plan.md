# Global Topology Planner (v1) — implementation plan

2026-08-05. Watershed "Layer 1" adapted to netlisp's router: a coarse-grid,
per-wave, all-nets-of-the-wave-simultaneous flow relaxation (Physarum
conductance adaptation + congestion pricing with a PathFinder-style history
term) that decides each net's global topology — which corridor/gap it threads,
which layer it prefers — BEFORE the sequential detailed router runs. The
detailed router stays what it is; the planner is a smarter producer of inputs
the router already honours.

> **Current execution policy (2026-08-12):** use pinned-master self-hosted
> Debug for the planner harness, corpus benchmarks, tests, and review server.
> Any ReleaseSafe baseline text below is historical; deployment is the only
> workflow that builds a new ReleaseSafe EDA application.

## Scope decisions (locked with Eugene)

- **Wave order stays authored law.** The `(pcb-plan (route …))` wave list keeps
  deciding WHAT routes WHEN (RF first, then control, then power). The planner
  owns only the spatial assignment *within* each wave. No arm of the
  experiment lets the planner reorder waves.
- **Per-wave incremental planning**, not one global relaxation:
  wave k's nets are planned simultaneously against each other, with waves
  1..k−1's extracted backbones stamped as consumed capacity and waves k+1..'s
  demands present at a light background weight (~0.2×) so ties in wave k break
  in favour of leaving room behind.
- **Out of scope for v1**: GPU/SIMD (planner grid is ~12k nodes — CPU is
  cheap), any new cost channel in `relaxStep` (Option C), Physarum
  multi-commodity Steiner reformulation, elastic-band refinement, planner-led
  wave reordering, incremental (partial-board) planning — v1 plans from-zero
  whole-board runs only.

## Why this is not the disproved negotiated-congestion branch

The PathFinder-style phase was tried and disproved (83/90, worse than doing
nothing — docs/autorouter-plan.md:41) because it ran *inside* the DRC-gated
transactional router and could not pass through illegal intermediate states.
The planner holds its overlapping/fractional state in its own continuous model
where overlap is legal by construction, and hands the router only soft costs.
Related in-tree evidence for "don't touch the detailed cost model": pricing
bends regressed barracuda 81→61 nets (note at router.zig ~9530).

## Algorithm (v1 spec)

**Grid.** Own coarse lattice, one per *signal* layer (2 on barracuda — In1 is
the GND plane, In2 pours; the router models signal layers only), plus vertical
via edges between layers. Pitch `p = max(2·g_route, 0.5 mm)` where `g_route`
is the router's own pitch formula (widest class track + max(clearance,
diff-gap)); barracuda ⇒ p ≈ 0.88 mm, ~69×28×2 cells. Rasterize pads (same
obstacle data model as `buildObstacles`), board-outline inset, keepout halos
(blocked for non-member classes, admitted for members — mirroring
`keepoutBlocked` semantics). Per-cell capacity = free cross-section ÷ demand
width crossing it.

**Demands.** One commodity per routable net in the wave (plane-carried nets
skipped — the oracle excludes them anyway). Multi-pin: inject +1 at pad 0,
extract 1/(n−1) at each other pad (star flow; steady loads condense to trees).
Per-net demand width = width + clearance from `placement.rules.net[i]` — the
same data `setNetParams` (router.zig:4075) reads. Diff-pair members are
demand-only: they consume capacity so others avoid their corridor, but the
planner emits NO guides for them (`diff_pairs.corridorPlan` owns pair
geometry). Nets with authored `(waypoints …)`/`(guides …)` likewise:
demand-only, authored guidance wins.

**Iteration (per frame, per wave):**
1. Per net: 4–6 Gauss–Seidel sweeps on `∇·(De∇p) = −b`,
   `De = D / (1 + κ·(cong + β·hist))`.
2. Flux `Q = De·∇p`; conductance update `D += rate·(|Q| − D)` (the proven
   Tero update; Hill sharpening is a later opt-in overlay, kept out of v1).
3. Congestion `cong[cell] = Σ_nets w_net·|Q_net| / capacity[cell]`;
   history `hist[cell] += max(0, cong − 1)` — the PathFinder anti-oscillation
   ingredient.
4. Vertical (via) edges carry lower base conductance (~0.25×) so layer
   changes are priced (flow analogue of `via_cost_mult = 4`).

**Determinism is a hard requirement.** No RNG, no clock reads (Guardian bans
them). Fixed frame budget (≤200/wave) with early-out when the extracted
topology is stable for 3 consecutive checks. Symmetry breaking via
deterministic per-net epsilon biases, never noise. Plan-twice must be
byte-identical (test mirrors `route_determinism.zig`).

**Extraction.** Per net: Dijkstra over edge weight `p/(|Q|+ε)` (highest-flux
corridor), simplify polyline, emit a `GuideTrack` with corridor half-width
≈ 1.25×p (must span ≥ a couple of router cells so the discounted region is
reachable), plus a `GuideVia` at every backbone layer change. **Confidence
gate:** emit a guide only when the net's flux actually concentrated (≥ ~60% of
the net's |Q| mass within corridor radius of the backbone); a diffuse net gets
no guide and routes exactly as today. Bad corridors are worse than no
corridors — soft 0.1× still steers hard.

**Intra-wave ordering (optional arm).** Contention-first rank within the wave
only; the inter-wave `wave_priority` band is untouched, and `netPriority`
(router.zig:3470) is never touched — authored `(net-class (priority N))`
deliberately dominates.

## Integration (Option A — zero router changes)

Everything the planner emits is an existing, honoured router input:

- `route_policy.GuideTrack` (route_policy.zig:67) → `setNetReferenceGuide`
  (router.zig:4155) → `ctx.reference_corridor`, 0.1× discount in `relaxStep`
  (router.zig:~9887). `expansionBudget` already bumps guided legs to the
  targeted floor (router.zig:~9648) — a documented prior lesson we inherit.
- `route_policy.GuideVia` (route_policy.zig:78) → `reference_via_mask`.
- `NetPolicy.wave_priority` (route_policy.zig:25) for the intra-wave arm.

Wire-in point: `route_plan.resolveOptions` (src/serve/route_plan.zig:54),
where `escape_guides` already merges into `options.guides.tracks` — one edit
reaches every surface (route_pcb, route_experiment, bench-route,
/api/pcb-describe, PNG) and preserves preview==commit.

Opt-in DSL: plan-level `(pcb-plan (topology))` = all waves; per-wave
`(wave "name" … (topology))` = just that wave. Plus a request-local
`topology` flag on `route_experiment` so A/B needs no design edit.

Precedence rules: authored waypoints/guides win per net;
`(assign-escapes …)` waves win for their nets (dormant on the corpus today —
zero uses — so no real conflict).

**Verify during implementation** (unresolved by the code survey):
(a) whether `reference_off_via_mult = 8.0` punishes vias on a net that has
guide *tracks* but zero guide *vias* — if so, always emit vias or suppress the
mask for planner guides; (b) `GuideTrack`'s exact field semantics.

### API sketch (M1 owns the final shape)

```zig
// src/placement/topo_plan.zig — pure module, escape_assign.zig-shaped:
// plain data in, deterministic slices out, no Ctx dependency.
pub const Params = struct {
    pitch_mm: ?f64 = null,          // default: max(2*g_route, 0.5)
    frames: u32 = 200,
    gs_sweeps: u32 = 6,
    kappa: f64 = 1.0,
    rate: f64 = 0.15,
    history_weight: f64 = 0.5,
    background_demand: f64 = 0.2,
    via_conductance: f64 = 0.25,
    corridor_halfwidth_scale: f64 = 1.25,
    confidence_min: f64 = 0.6,
    stability_checks: u32 = 3,
};
pub const NetInput = struct { net: usize, width: f64, clearance: f64,
    allowed_layers: u64, has_authored_guide: bool, is_diff_pair: bool };
pub const Wave = struct { nets: []const NetInput, topology: bool };
pub const Plan = struct { tracks: []route_policy.GuideTrack,
    vias: []route_policy.GuideVia, diags: []NetDiag };
pub fn plan(arena, placement, waves, params) !Plan
```

## Milestones

- **M0 — harness prep.** Commit this doc + the first `bench/baseline.json`
  (none committed yet): self-hosted Debug binary, whole corpus,
  `netlisp bench-route --project-dir <designs> --json > bench/baseline.json`.
  (Trial memory `barracuda.trials.json` starts at M3 — recording goes through
  the MCP tool, which needs an authorized session.)
- **M1 — planner core, pure.** `src/placement/topo_plan.zig`: raster +
  capacity, per-wave solver loop with prior-wave stamping + background
  demand, extraction + confidence gate, guide emission. Synthetic fixtures
  (route_determinism.zig style — worktree `projects/designs` is empty, no
  design files in tests): 2 nets / 2 gaps separate under contention; single
  net takes shortest gap; sealed net emits no guide (confidence gate);
  allowed-layer mask honoured; plan-twice byte-identical. SPEC bullets +
  tagged tests land together; register the file in `src/main.zig`'s test
  aggregator block.
- **M2 — wiring + eyes.** (a) DSL flag + lowering: parse in
  `design_block.zig`, types in `env.zig` (`PcbPlanSpec`/`PlanWave`), lower
  into `ResolvedPlan`/`ResolvedWave`, grammar string in `forms.zig`,
  `zig build docs` regen. (b) Integration: `resolveOptions` merge gated on
  the flag + `route_experiment` request-local flag. (c) Debug dump of
  per-net flux/corridors (route-vision overlay is the precedent) so the
  topology can be eyeballed before it is trusted.
- **M3 — barracuda A/B** (protocol below), then the corpus `--baseline` gate.
- **M4 — stretch.** Intra-wave ordering arm, H-signature stability gate
  (winding invariant around component clusters) replacing the cell-support
  stability check, history-term tuning.

## Evaluation protocol (barracuda)

Instruments: `netlisp bench-route --project-dir <designs> barracuda
--breakdown` (from-zero at starred poses, oracle-scored, read-only) for the
raw number; the canonical `auto-zero` recipe (route → `close_open_nets` to
fixed point → fence → post-fence close; designs-repo commit f719a13) for the
closed number; `record_route_trial` for the log; `bench-route --baseline
bench/baseline.json` as the corpus regression gate (hard rule: no scored
board loses >1 net; soft rule: geomean holds).

| Arm | What runs | Question |
|---|---|---|
| 0 | authored 16-wave plan as-is | baseline: 82/91 raw, 85/91 closed |
| 1 | authored plan + planner on **control-escape wave only** | the surgical test — does joint spatial assignment close SPI_MOSI / TXDATA_ADF / SPI_LMX_CSN? |
| 2 | authored plan + planner on all waves (+ intra-wave ordering) | the dial turned up |

Arm 1 first: it isolates the highest-confidence win and cannot disturb the RF
waves.

**Expectations, calibrated.** Planner-addressable residuals are the
order/contention class: `SPI_MOSI`, `adf4159/SPI_ADF_SDI_1V8`,
`buck_6v/VIN_F`, `TXDATA_ADF`, `SPI_LMX_CSN` (the agent-loop plan's own
expected fix for the latter two was "corridor reservation" — exactly what
planner corridors are), plus the pour-fed rails from-zero must route as
copper. **Not addressable:** `SPI_SCK` (lattice-resolution wall — legal
detour clears obstacles by 0.07–0.20 mm, needs the 0.05 mm window path) and
the `GND` buck-thermal-pad via-anchor case. The "six SPI nets in one J1
corridor" story was retracted (docs/autorouter-plan.md:235) — don't judge the
planner on it.

**Success:** arm 1 or 2 ≥ 85/91 raw (vs 82) with no corpus regression and no
DRC-error growth. **Kill / descope to diagnostics-only:** corridors cost nets
on barracuda after one tuning round — the M2 debug overlay shows why. Even in
the kill case the converged congestion field survives as a pre-route
oversubscription diagnostic (placement-side value).

## M3 outcome (2026-08-05) — measured verdict: guides do not help barracuda v1

Arms run via `bench-route` on scratch copies of the designs tree, same
ReleaseSafe binary (branch commits 0871c8e..3bbe5da):

| arm | routed | drc_err | trace_mm | wall |
|---|---|---|---|---|
| 0 pristine | **82/91** | 70 | 942 | 29.4 s |
| 1 `(topology)` on control-escape | 80/91 | 68 | 851 | 153.6 s |
| 2 plan-level `(topology)` | 80/91 | 68 | 848 | 164.4 s |

Both arms produce the identical open set. Per-net flip diagnosis (arm0 vs
arm1/2): 4 regressions, of which only ONE (`SPI_LMX_CSN`) is a net the planner
guided; `adf4159/ADF_CE`, `LOCK_DET_1V8`, `REFIN_1V8` are displacement (unguided
nets losing space to the guided corridors), and `SPI_MOSI` +
`adf4159/SPI_ADF_CSN_1V8` IMPROVED by the same displacement. Net −2. The
tuning round stopped here per the kill criterion.

Two structural findings, each the real story:

1. **The coarse lattice cannot plan connector escapes.** At 0.93 mm pitch the
   whole-cross-section cell rule seals the fine-pitch J1/QFN escape geometry:
   16 of 93 nets get `no_path`, including 3 of the 8 control-escape targets
   (`SPI_MISO`, `SPI_MOSI`, `SPI_ADF_CSN`). The planner is silent exactly
   where this board is hardest — the arm-1 thesis fails at the lattice, not in
   the physics. A v2 would need escape-region pitch refinement (the planner
   analogue of `fine_window`) before the corridors can even describe the
   contested region.
2. **Reference guides inflate the router's own search ~5.6×.** With only 5
   guided nets / 83 guide tracks, `direct` went 22.3 s → 124.1 s and
   `dogleg_probes` 4.9 M → 27.6 M (fine_rescue similarly). The planner itself
   is 8–15 s after the M3a restructure (549 s → 14.5 s, 37×). Suspected
   mechanism: folding the 0.1× corridor discount into the A* heuristic (the
   admissibility rule) makes the heuristic ~10× weaker board-wide for guided
   nets, degrading A* toward Dijkstra. Router-side; pre-existing for any
   GuideTrack producer (`assign-escapes` would pay it too); worth its own
   investigation independent of the planner.

What survives regardless of the verdict: the planner core + wiring (opt-in,
byte-identical when off, whole-suite green), `bench-route` per-board `open[]`
(per-net A/B diffing the harness lacked), the confidence gate measuring real
commitment (the unloaded-net 1.000 bug is fixed), and the congestion field as
a pre-route oversubscription diagnostic — the descoped role the kill criterion
names.

## v2 planner side (2026-08-05) — the lattice can plan connector escapes now

M3's first structural finding ("the coarse lattice cannot plan connector
escapes") was the whole verdict, and it is fixed. Three changes, all inside
`topo_plan.zig`:

1. **Pitch is resolution, the reference channel is capacity.** v1's cell offered
   `pitch × (open area fraction)`, so a finer pitch made every cell carry less
   and would have sealed the board rather than resolving it. A cell now offers
   the local APERTURE at its centre — the narrower of the open runs through it
   along x and y, sampled over a window one reference channel wide — capped at
   that channel. Geometry, not sampling.
2. **A stuck wave is replanned finer.** Nets the reference lattice cannot join
   are retried at `max(min_pin_pitch/2, 0.35 mm)`, with ONLY those nets as
   commodities and the first pass's frozen background field inherited rather
   than warmed up again. A wave whose nets all found corridors costs exactly
   what it did before. Consumed capacity is kept as world geometry and replayed
   onto whichever lattice the next pass uses.
3. **Two capacity corrections the finer lattice exposed.** A stamp consumes its
   own cross-section (`demand/2`, floored at half a cell), not the guide
   corridor's much wider *hint* radius — charging 1.16 mm of channel for a
   0.38 mm trace closed the J1 escape region after one net crossed it. And it
   consumes only the layers its backbone runs on; v1 took the capacity under a
   backbone on every layer.

Measured on barracuda at the starred poses (planner only — no routing):

| | arm 0 (v1) | v2 |
|---|---|---|
| `no_path` | 16 / 93 | **2 / 93** |
| control-escape wave | 3 of 8 `no_path` | **0 of 8**, all emitted |
| guides emitted | 12 | 22 |
| `SPI_LMX_CSN` backbone | 102 cells / 14 vias | 64 cells / **2 vias** |
| planner wall (arm 2, all 16 waves) | 20.5 s | 27.1 s |
| planner wall (arm 1, waves 0–4) | ~10.3 s | 11.0 s |

The two residual `no_path` are `V_12V` (a 0.507 mm-cross-section rail, refined
to 0.35 mm and still not joinable) and `buck_6v/VIN_F`. `GND` no longer lands on
`no_path` by accident: a plane-carried net is now excluded explicitly
(`Reason.plane_carried`) and never relaxed at all.

Per-wave planner cost, arm 2 (ms): 4588 / 1163 / 609 / 709 / **3280** / 719 /
689 / 397 / 1440 / 1163 / 369 / 314 / 510 / 516 / 1538 / 9040. Three waves
refined (0 → 0.35, 14 → 0.35, 15 → 0.4625); every other wave stayed on the
0.9296 mm reference channel. Plan-twice is byte-identical on the real board.

Still open on the planner side: 62 of 93 nets are `low_confidence`, so the gate,
not the lattice, is now what decides how many guides reach the router. The M3
router-side finding (reference guides inflate the maze's own search ~5.6×) is
untouched here.

## Risks

- Bad corridors steer hard even at soft 0.1× → confidence gate (above).
- Coarse-pitch lies (corridor legal at 0.88 mm, sealed at router pitch) →
  acceptable: guides are soft, escalation ladder still runs, confidence gate
  and capacity margins keep it rare.
- `escape_assign` overlap → precedence rule; dormant today.
- Wave-order forfeit: a world where routing one control net before an RF net
  is globally better is out of reach — chosen deliberately; RF-first is
  domain law on this board.

## v2 outcome (2026-08-05) — final verdict: corridors hurt, dose-dependently; the router fix is the prize

Definitive arms on the committed v2 tree (7f8b6b8 + 9db5128, whole suite green,
same binary):

| arm | routed | drc_err | trace_mm | wall | open-set delta vs arm 0 |
|---|---|---|---|---|---|
| 0 pristine | **82/91** | 70 | 942 | **12.1 s** | — |
| 1 control-escape `(topology)` | 78/91 | 65 | 817 | 36.6 s | +SPI_ADF_CSN +SPI_LMX_CSN +TXDATA_ADF +ADF_CE +LOCK_DET_1V8 −SPI_MOSI |
| 2 plan-level `(topology)` | 78/91 | 68 | 797 | 53.5 s | ditto +REFIN_1V8 −SPI_ADF_CSN_1V8 |

v2 achieved its planner-side goals — control-escape 3×no_path → 0, all 8
guided, via-thrash fixed, aperture capacity honest — and the OUTCOME GOT WORSE:
three of the newly-guided control nets (SPI_ADF_CSN, SPI_LMX_CSN, TXDATA_ADF)
now FAIL under their own corridors, displacing two more. The dose-response is
monotonic and now spans three points: 0 guides → 82, 12 guides (v1) → 80,
22 guides (v2) → 78. With the router's rescue tiers un-hobbled (the v2-A fix),
the sequential maze simply finds better escape topology than the flow
relaxation's corridors, and the soft 0.1×/8× corridor pricing steers hard
enough to break nets that routed fine unguided. Kill criterion fired twice;
the corridor-emission path is CLOSED for this board — do not re-tune knobs.

What the experiment paid for regardless:

- **Router probe-sweep fix (7f8b6b8): the standalone prize.** barracuda
  29.5 → 12.1 s, black-canyon 40.1 → 9.9 s, corpus baseline byte-identical
  except wall. Worth merging on its own merits.
- `bench-route` per-board `open[]` + the committed `bench/baseline.json` —
  per-net A/B diffing the harness never had.
- The planner + DSL + wiring: opt-in, byte-identical when off, whole-suite
  green — safe to carry on a branch or merge dormant. Its no_path census and
  congestion field remain a pre-route diagnostic (V_12V / buck_6v/VIN_F are
  unroutable at every planner resolution — matching their
  close-open-nets-only reality).
- Watershed post-mortem for the research doc: on a board with a mature
  hand-authored wave plan and a rescue-laddered detailed router, jointly
  planned soft corridors were strictly harmful at every dose tried. The
  untested remainder of the Watershed thesis is corridor-FREE delivery
  (ordering-only, or capacity-honest planning feeding placement decisions),
  not stronger corridors.
