# Autorouter audit — 2026-08-04

> **Current build policy (2026-08-12):** this audit's ReleaseSafe run is a
> historical input. Follow-up implementation, profiling, and benchmarks use
> pinned-master self-hosted Debug; only deployment builds ReleaseSafe.

*Method: five parallel code auditors over the routing subsystems (core engine,
rescue ladders, DRC/oracle, agent loop, RF/diff-pair), cross-checked against
`docs/autorouter-plan.md`, `docs/autorouter-audit.md` (2026-07-05) and
`docs/autorouter-wall-time.md` (2026-08-02), plus a fresh ReleaseSafe
`bench-route` run at today's HEAD. File:line references are from worktree
`claude/autorouter-audit-improvements-2112ee` (main + nothing).*

**TL;DR.** The wall-time problem is solved for boards that route (the 2026-08-02
speedup shipped: spatial index + probe budget + span gate, 17× on barracuda).
The frontier now is (a) a set of **correctness defects in the finishing/report
path** — one of which can silently ship a false-clear board — and (b)
**completion**: the engine alone still leaves 10–35 % of nets open on every
corpus board except barracuda, and the escalation ladder's hardest-net tiers are
structured so that the residual class that actually survives is exactly the
class they refuse to touch. The strategic options (negotiated congestion,
per-class lattice) are real but should not start before the Tier-0/1 items —
several of which invert the objective function the DSL loop is currently
optimizing against.

---

## 1. Where the engine stands (measured today)

`bench-route`, ReleaseSafe, blessed placements, 2026-08-04:

| board | routed | DRC err | tracks/vias | wall_s |
|---|---:|---:|---:|---:|
| barracuda | 82/91 | 70 | 599/85 | 29.9 |
| straps | 79/102 | 305 | 1069/433 | 26.0 |
| black-canyon | 45/66 | 258 | 341/102 | 40.8 |
| cyclops-xband-sip (unscored) | 18/49 | 90 | 348/177 | 39.7 |

Versus the 2026-08-02 post-speedup table: barracuda 83→82 and 7.8 s→29.9 s,
straps 82→79, black-canyon 41→45. The RF-shadow/keepout/gloss merges since then
moved boards in *both* directions — precisely the cross-board variance the
corpus harness exists to expose, and a reminder that the DRC "err" column is
dominated by `net_open` markers (see C2: several surfaces double-count them).

Shipped since the July plan and working: direct-probe spatial index +
probe budget + span gate (`docs/autorouter-wall-time.md` §7); `pad_exit`
interior landing + board-hole awareness; the vacate tier (91/91 on barracuda's
auto-full-v2 via `close_open_nets`); one connectivity oracle behind every
tally; gap-closer gloss; keepout escape zones reaching the direct probes;
coupled diff-pair construction.

---

## 2. Correctness findings — fix before any feature

**C1 — stale copper index inside `route_cleanup` passes (soundness).**
`segClearsTracks` resolves candidates through `ctx.copper_index` by **array
index**, guarded only by `ci >= tracks.len` (router.zig:3746-3757). Every
`route_cleanup` pass compacts the track list (`removeNetTracks`,
route_cleanup.zig:58) without rebuilding the index — `snapTerminalVias:185`,
`collapseCollinearNets:244`, `dropRedundantViaPairs:539`, `closeNetOpens:736` —
so surviving indexes alias *different tracks* (in range, wrong copper).
`straighten.passBoard` knows and rebuilds per net (straighten.zig:717-721);
cleanup does not. Failure direction is **false clear** — a cleanup decision
validated against the wrong track. Also: `setNetParams` doesn't refresh
`ctx.copper_reach` (router.zig:4424-4430 built it from a previous net's params).
Fix: rebuild after each compaction, or a generation counter with lazy rebuild
inside the query. *Small.*

**C2 — `net_open` double-charged in every ranking surface.**
`fabErrorCount` (pcb_layout_page.zig:9539) deliberately excludes `net_open`
(open nets are already the completion term). The three `drcErrorCount` copies
feeding `route_score` do **not**: pcb_describe.zig:553, route_review.zig:513,
mcp_route_order.zig:515-518. One open net on a 90-net board costs 11.1 via
completion and 50+ via the DRC term — inverting route_score.zig:27-29's stated
contract. **`route_order_search` and the DSL accept/reject loop are currently
ranking against a partly inverted objective.** *Small, unblocks everything
downstream.*

**C3 — two surfaces still bypass the oracle gate.** `route_review.replayDesign`
(route_review.zig:322) calls `router.routeWithTimeline` directly — its
routed/total are the router's claim, the exact defect fixed everywhere else.
`routeReviewApi` (route_review.zig:357) and kicad_pcb/route_command.zig:224
call bare `drc.check` (no net_open, no per-design rules). *Small.*

**C4 — coupled diff pairs skip the RF gloss, silently.** The coupled branch
`continue`s before `smoothNetInline` (router.zig:770-775 vs :843), `straighten`
skips pair legs (straighten.zig:174), and `sharp_bend` DRC only echoes what the
router recorded (drc.zig:222). So a `(diff-pair …) (max-freq …)` class — the
normal LVDS/USB3 declaration — keeps raw mitred lattice corners with **no arcs
and no warning**. Also: every rescue tier (`escalatePair` router.zig:8727,
`routeFollowerLeg` :8763, `rerouteNet`, `resetPairContext` :857) permanently
degrades a pair to independent nets — no re-coupling attempt, no skew
equalization — and when only the leader routed, both legs become rip-up fair
game. *Small (emit the sharp report + smooth symmetrically), medium (re-couple
in escalation).*

**C5 — `bend_smooth.GeomProbe` is blind to zones, keepouts, pours, RF shadow**
(bend_smooth.zig:214-267), yet runs *inline during routing* (`smoothNetInline`
router.zig:911) and from `straighten.rearcTautNet:842`. An accepted RF arc can
cross a keepout every other probe in the system would refuse. Fix: pass
`router.TautProbe` (bend_smooth already parameterises a probe for
`simplifyChain:965`). *Small–medium.*

**C6 — rescue contexts enforce a keepout the primary route waives.**
`windowCtx` clears `keep.layers`/`keep.gate` (router.zig:1494-1499); derived
contexts get their halo from `stampBoardCopper`+`keepoutExtra`
(router.zig:4276,4895), which honours the class waiver but **never
`keepout.Zones`** — so an escape admitted in the greedy pass is refused in
every windowed/gap rescue. Same class of bug as d9bbf4e, one layer down.
Inverse asymmetry for the RF shadow: windows drop the soft cost
(router.zig:1500) but keep the hard `runsAlong` refusal (router.zig:3745) —
the rescue's only surviving shadow rule is the strictest one, the shape that
cost 5 nets before 5b40b30. *Small.*

**C7 — connectivity-oracle holes (each one a false verdict class):*
- no **via↔via** union in `buildNetGraph` (fab_readiness.zig:795-829) while
  `route_cleanup.countCopperIslands` has one (route_cleanup.zig:630-634) —
  stacked/abutting same-net vias read as two islands → phantom `net_open`;
- **pad↔board-edge is unchecked** (`checkBoardEdge` drc.zig:488 iterates vias
  and tracks only) — the largest missing fab rule;
- **user pours credited by raw `outline.contains`** (fab_readiness.zig:719,726)
  while declared planes use the honest raster — a pour split by a foreign trace
  still reads connected (false CLEAN);
- **`keep_unseeded` ships floating copper unverified** (pour.zig:509-512), and
  pour copper is invisible to every DRC rule (`drc.check` takes RouteResult,
  no zones);
- **thermal reliefs exist only in the Gerber writer**
  (export_gerber.zig:446-473) — the oracle believes solid copper where the
  artwork ships four 0.3 mm spokes; inner-layer thru pads antipad on the
  **drill** only (pour.zig:822), ignoring the land.
*Small each; the thermal-relief move into `pour.zig` is medium.*

**C8 — drift, small but load-bearing:**
- finish ordering violates its own documented invariant: the comment at
  router.zig:2063-2083 promises topology-before-stitch/straighten; bb79c19
  moved `straighten.passBoard` above `dropRedundantViaPairs`, so stitch GND
  vias can guard signal vias E10 then deletes, and the conditional re-straighten
  at :2081 is a patch over the ordering rather than the ordering;
- a skipped gap hop reports the **previous** hop's `GapReason`
  (router.zig:2426 vs :2538);
- `drc_rules.defaultSeverity` (drc_rules.zig:43-55) claims diff_uncoupled /
  diff_skew are errors; they emit `.warn` (drc_diffpair.zig:71) — the mirror
  comment names files the sites moved out of; nothing enforces parity;
- `netPriority`'s doc still says "the router has no rip-up" (router.zig:3468);
  `cdt_route.zig:1-3` still claims to be the router's rescue tier (only
  route_diagnose.zig:373 calls it); `ripUpEligible` is a hardcoded
  `return true` with dead params (router.zig:8524-8528).

---

## 3. Performance findings

The direct-probe indexing shipped and holds (verified in-code: the clear
functions take the `ctx.copper_index` fast path). What remains, in ROI order:

**P1 — the per-leg O(layers×nodes) maze preamble.** Every leg pays two
`@memset`s over `dist`/`prev` (router.zig:9698-9699) plus a **full scan of
every node on every layer** for `occ == net` sources (router.zig:9729-9740) —
up to 3 sweeps of ~800 k entries before a search whose budget is 10 000
expansions. Duplicated at :7183 and :8250. Goal test is `indexOfScalar` per
pop (router.zig:9775). Fix: dirty-list reset + per-net occupancy index + goal
bitmask; byte-identical output. *Small, big on failing boards.*

**P2 — the static-obstacle memo is never armed for the primary route.**
`ctx.static_block` is allocated only inside `closeGaps` (router.zig:2402) and
explicitly disarmed in `windowCtx` (:1291); `buildRouteCtx` (:1133) never
allocates it, so greedy/escalate/rip-up recompute outline mask + zone polygon
containment + pad-grid exact tests on **every `blocked()` call** — the memo's
own docstring says that recomputation is what makes a failing hop cost tens of
seconds. *Small.*

**P3 — retry-ladder budgets (wall-time plan Step 4, still deferred).** The
ladder is the dominant cost on failing boards (stm32n6 448 s of 535 s;
black-canyon 146 s) and `max_batch_expansions = 10_000` is flat while the state
space scales with layers×nodes (router.zig:185-199) — deep stackups are
silently budget-starved relative to 2-layer boards. Cap ladder rounds
per board, scale per-leg budgets with lattice size. *Small–medium.*

**P4 — the oracle recomputes the world 4–6× per response.** `buildNetGraph`
runs for `netConnectivity`, `net_open.check`, twice inside `openNetDetail`
(fab_readiness.zig:534,540), plus two `routableTally` passes in
`route_close.reconcile` (:103,:122) — and for a plane net each run re-rasters
the board per layer (`pour.planeConnect:779`). No memoization exists. One
arena-scoped cache keyed (net, copper generation) + a fill cache for
planeConnect. *Medium.*

**P5 — remaining quadratics:** `hole↔hole` in drc.check is all-pairs
(drc.zig:465-482 — "holes are few" is false on a via-fenced RF board;
drc_session already builds a hole grid at drc_session.zig:529);
`net_open.emitOpens` is Prim O(islands²) with an unindexed O(features²)
`nearestApproach` (net_open.zig:153,219); `escape_assign.padCenter` rescans
all parts×pads per pin (escape_assign.zig:300).

**P6 — cheap structural wins:** rip-up snapshots copy five full lane groups
per candidate (router.zig:8462, ~16 MB per attempt at cap);
`fineWindowRescue` is embarrassingly parallel (independent `windowCtx` clones
+ per-net accept gate, router.zig:8836-8858) — collect in parallel, commit in
`routable` order.

---

## 4. Why boards stall — the completion architecture

**A. The ladder's hardest-net class has no tier.** `escalateSearchLimited`
only retries nets in `search_limited` — a net whose frontier *drained*
(`blocked`) at 10 k expansions is never retried at 400 k even after rip-up
opened its corridor (router.zig:8710). `fineWindowRescue`'s classifier
deliberately refuses any net whose flood was budget-capped or touches rippable
copper (router.zig:8892-8894). Net effect: "walled in by congestion" — the
dominant residual on a dense board — is excluded from tiers 2 *and* 5 by
design. The batch route's last tier is a no-op for its own hardest nets.

**B. Two rip-up engines, the stronger one unreachable from the primary route.**
Primary `ripUpReroute` rips whole nets under a keep-best gate that reverts any
rip not immediately improving the count (router.zig:8550,8162) — myopic by
exactly one net. The gap closer rips **track subsets** with a reach ladder and
now a vacate tier (router.zig:2831; gap_policy.zig:310; vacate_policy.zig).
Three separate blocker-nomination implementations exist
(router.zig:8583 / router.zig:2897 / mcp_close_gaps.zig:1812), and the vacate
tier uses the weakest (straight-line ±2 mm corridor; via-blind — a via field
across a channel is never nominated) for the hardest problem, when
`softProbe`-backed nomination is one export away. Two built rungs are switched
off in production (`max_repair_rip_depth = 0`, mcp_close_gaps.zig:90,104) with
no adaptive re-enable for the last few nets.

**C. Vacate is single-seed.** `vacatePhase` loops seeds serially
(mcp_close_gaps.zig:1466); each transaction restores the other seeds' copper
before the next runs, so N nets contending for one corridor cannot be solved by
any sequence of single-seed vacates. `vacate_policy.Limits` is never
caller-overridden (:1685), and the 3-net cheap cap vs 6-net standard cap are
inconsistent for one phase. A rolled-back vacate also permanently loses the
dead-end memo it cleared mid-transaction (:1555,:1595). Multi-seed joint
transactions + probe-based nomination are the shape that closes the
six-SPI-in-one-corridor case.

**D. `escape_assign` is finished and unwired.** The joint monotone-DP lane
assigner (escape_assign.zig:565 — constriction scan, planarity by
construction, minimum total detour) is reachable only from an authored
`(assign-escapes …)` (plan_resolve.zig:450) or the read-only preview tool.
Nothing *detects* contention ("J1: 6 nets, 3 lanes") and calls it; its
obstacle model is courtyards-only (`lanesAt:441` — fiction at rescue time when
the corridor is full of copper); it has one layer (`Plan.layer:110`) and no via
concept, while the sealed-row cases it exists for (J1) exit only by via.
`route_diagnose`'s `escape_blocked` remedies never mention it.

**E. One global lattice pitch, sized by the fattest class**
(`routeGridDims` router.zig:1033-1069). A 0.127 mm signal net rasters at a
0.5 mm power class's pitch; `max_nodes` overflow silently routes nothing
(:1851). The entire fine_window tier (+~660 lines of rescue in router.zig) is
compensation. Per-class-group rasters, or base the lattice on the *narrowest*
class and inflate wide nets' halos, is the structural fix. *Large, highest
structural payoff.*

> **MEASURED 2026-08-06 (Tier-4 item 2) — the payoff is a re-roll, not a gain.**
> The pitch policy is now `route_grid.zig` (extracted from router.zig, which
> drops 10333 -> 10227 code lines), carrying `Mode.narrowest`: raster the board
> at the finest pitch its own nets need instead of the coarsest, bounded by the
> node budget. This is the audit's own "narrowest class + inflated halos"
> option, and it is legitimate because the halos were *already* per-net —
> `setNetParams` gives every net its exact width/clearance for obstacle tests
> and `stampBoardCopper` haloes at that reach, so the lattice is purely a
> centreline quantization and a finer one is strictly more expressive.
>
> A uniform-finest lattice is therefore the CEILING on what any per-class
> scheme (grouped passes included) can buy in expressiveness. Measured over the
> whole corpus against b248148, that ceiling is:
>
> | board | routed | wall |
> |---|---|---|
> | straps | 83 -> **89** (+6) | 37.7 -> 88.7 s (2.35x) |
> | barracuda | 82 -> 81 (-1) | 12.6 -> 38.2 s (3.03x) |
> | black-canyon | 51 -> 49 (-2) | 13.3 -> 24.9 s (1.87x) |
> | cyclops-xband-sip | 19 -> 19 (0) | 42.8 -> 55.2 s (1.29x) |
> | the other 10 boards | unchanged | ~1.00x |
> | corpus | +3 nets, geomean 0.05458 -> 0.05477 | 658 -> 768 s (1.17x) |
>
> The per-net diff is what settles it: every moved board CLOSES and OPENS nets
> at once (straps closes 11 and opens 5; black-canyon closes 3 and opens 5;
> xband-sip closes 8 and opens 8 for a net zero). That is the signature of a
> different search, not a better one — the finer raster re-rolls which corridor
> each net claims first. DRC errors also move the wrong way where it wins
> (straps 159 -> 181, xband-sip 23 -> 58), so even straps' +6 is not free.
>
> Two structural facts explain it. The per-leg expansion budget is a COUNT, so
> a finer lattice sweeps a proportionally smaller PHYSICAL radius on the same
> budget — refining the pitch 1.73x quarters the reachable area, which is why
> boards lose nets they used to reach. And the corpus's headroom boards mostly
> have no class spread to exploit at all: **stm32n6 (91/238), barracuda-base
> (118/138) and straps-base (1/112) declare no `(net-class …)` geometry
> whatsoever**, so their one pitch is already their finest and the item cannot
> move them by construction (measured: byte-identical, 1.00x).
>
> Conclusion: the coarse lattice is NOT the binding constraint on this corpus —
> ordering and escape contention are. `Mode.narrowest` therefore ships OFF
> (`BoardRules.lattice`, default `.widest`), as a per-board opt-in with this
> measurement attached; straps is the one board whose numbers argue for turning
> it on, at 2.35x wall and +22 DRC errors. Class-GROUPED passes were NOT built:
> they are strictly bounded above by this ceiling for the fine nets, they would
> additionally freeze each earlier group's copper against later rip-up, and the
> ceiling does not pay for that complexity.
>
> What this retires from the fine_window tier: nothing yet, and the measurement
> says why. The rescue tiers stay load-bearing precisely because a board-wide
> fine raster is unaffordable in search budget while a BOUNDED window at the
> same pitch is not — `fine_window`'s windows buy the same resolution for the
> handful of nets that need it at a fraction of the cost. The one piece the
> mode does subsume in principle is the declared `(resolution MM)` path when a
> board opts in board-wide, and even there the `fine_accept` oracle gate is
> still required, since accepting board-scale fine copper is what that gate
> exists to police.

**F. Negotiated congestion — what round 2 would actually take.** The prior
attempt scored 83/90 vs 87 baseline, and both the plan doc and the code agree
why: `ripScoreBetter` (router.zig:8162) and `keepIfClean` (router.zig:9242)
forbid the temporarily-illegal intermediate states the method requires. **Do
not re-attempt PathFinder inside the current transaction model** — it will
reproduce 83/90. The prerequisite is an overlap-tolerant, globally-evaluated
accept gate (converge on "fewer opens + less overlap than last iteration"
across the board), which is a different accept architecture, not a cost tweak.
Also missing for any global method: no coarse-grid congestion estimation
phase, no bend pricing in the search (strict `<` at router.zig:9906 means an
equal-cost straighter path can never displace a staircase — tie-break only),
no Steiner topology (orderedNetPoints is greedy nearest-insertion,
router.zig:5974).

---

## 5. Specialty-discipline gaps

- **Diff-pair skew DRC floor is 1.0 mm** (`max(4·pitch, 1.0)`,
  drc_diffpair.zig:52) — a USB3 pair can be ~8× over spec and clean, while the
  coupled engine internally targets 0.05 mm. Derive tolerance from the class
  (`(diff-pair GAP (skew MM))` or frequency-aware default), report measured
  skew even in-tolerance. Odd-membered pair classes drop the leftover silently
  (diff_pairs.zig:117-128); naming only `_P/_N`+`DP/DM` (diff_pairs.zig:44-56).
- **No length matching anywhere** (no form, no NetRule field). The two hard
  halves already exist: `copper_length.shortest` (correct effective-length
  measurement) and `diff_route.bumpSeg` (working single-lobe detour with apex
  solving + self-simplicity checks). A `(match-group …)` form + an
  opportunistic multi-lobe serpentine pass modelled on `straighten.passBoard`,
  probe-gated by `TautProbe`, + a `length_mismatch` DRC kind. *Large but
  well-scaffolded.*
- **Return path is a report, not a cost — and the repair is off on real
  boards.** `stitchReturnPaths` is gated to ≤48 parts (router.zig:223,2215) so
  it never runs on any real board; nothing in `relaxStep` prices a
  plane-split crossing though `pour.zig` computes the geometry; `isGndVia` is
  name-only and plane-membership-blind (return_path.zig:26,41).
- **No impedance model at all.** The stackup form carries no εr/thickness
  (the only dielectric constant is `via_fence.assumed_er = 4.4`); `(width …)`
  is authored, never solved from a Z₀ target; changing stackup changes nothing
  in routing behaviour. Even `(max-freq)` alone casts **no** crossing shadow —
  the shadow requires `(fence)`/`(keepout)` too (rf_shadow.zig:345-350), which
  is not the intuitive reading of the form.
- **The router pays for a fence nobody builds**: shadow cost protects fence
  sites (rf_shadow.zig:61,66) but `via_fence.generate` only runs from the MCP
  tool; nothing verifies post-route that the protected corridor is buildable.

---

## 6. Agent-loop gaps (the DSL-loop vision, audited)

- **`route_experiment` is not self-sufficient**: no `unrouted[]`/`open_nets[]`
  (its `stuck[]` is router-derived, capped at 16, can be empty while
  routed<total), no `layout`/`sub`/`nets`/`effort` args — hard-coded full-board
  `.{.route=true}` (mcp_route_experiment.zig:62,100-114). Every trial forces a
  second full-board describe to *name* the failures. *Small, biggest
  loop-latency win.*
- **The per-net diagnosis endpoint exists and is HTTP-only**
  (route_analyze_api.zig:40). Exposing it as `diagnose_net` defeats the 16-net
  stuck cap and the "route the whole board to ask about one net" cost. Also:
  `pads` is read by the describe handler (mcp_read_opts.zig:40) but **absent
  from the tool's `additionalProperties:false` schema** — a remedy string
  explicitly tells the agent to pass it; a strict client refuses.
- **Diagnosis dead ends**: `unknown` → zero remedies (route_diagnose.zig:1011);
  past-16-net fallback → empty (route_analyze_api.zig:164); `drc_related`
  always empty (route_diagnose.zig:264); the CDT probe silently returns null
  for cross-layer/multi-leg nets — exactly the nets that fail — with no field
  saying why; `cdt_geometry_limit` (the highest-confidence verdict) carries no
  ref/direction/mm although `routability_lint` and `placement_sensitivity`
  already compute them. And there is **no corridor-group congestion
  diagnosis**: six contending nets get six contradictory per-net
  `raise_priority` remedies; the one diagnosis that would point at
  `preview_escape_assignment`, nothing emits.
- **Trial memory is a scoreboard, not a search index**: free-text plan, no
  layout/scope/score_v/open-net fingerprint, no canonical hash (so oscillation
  detection is eyeball-only), and `route_order_search` — up to 48 routes —
  records nothing (mcp_route_order.zig:40-42). Its winner is returned as prose
  the agent must hand-transcribe into the .sexp; no `apply`.
- **The richest steering surface is browser-only.** `RouteSession` (pausable
  runs, per-stuck frontier + ranked blockers with rip costs, 5-variant hints,
  `(pcb-plan)` distillation — route_session.zig:90-128,248) has zero MCP
  exposure; `route_live` is watch/cancel only. An agent's only lever is
  "rewrite the plan and re-route from scratch."
- **Describe-after-persist can't diagnose the persisted board**: without
  `route=1` there is no `stuck[]`; with it, the copper is thrown away and a
  *different* board is diagnosed (pcb_describe.zig:120-135).

---

## 7. Process / bench

- **The corpus gate is thinner than it looks**: adf5901 (4 layouts), stm32n6
  (7), straps-base (0) have **no ★ default**, so they route nothing at a
  fallback placement and stay unscored. Starring their best existing rows is
  free corpus width.
- Unmerged branches worth a decision: `claude/router-ctx-split` (8e3dd9b, the
  50-field Ctx decomposition — 173 commits behind, and windowCtx's
  copy-then-null-25-fields clone at router.zig:1476-1525 is the hazard it
  exists to fix); `codex/cdt-rescue-tier` (documented dormant — fine to keep
  parked). `codex/pcb-route-plan` (453 behind) and
  `claude/pcb-layout-route-save-6f9833` look superseded — candidates for
  deletion.
- The July memories claiming five router fixes were unmerged are stale — all
  five (7b7df27, d3d259b, 3aa76dd, b78f1a1, 9a6dfbb) are in main.

---

## 8. Ranked roadmap

**Tier 0 — correctness, days.** C1 stale copper index; C2 net_open
double-count (three copies) + severity-table parity test; C3 gate the two
bypassing surfaces; C4a emit sharp-bend on coupled pairs; C5 TautProbe into
bend_smooth; C6 zone-gate the rescue halo; C7 via↔via union + pad↔edge rule;
C8 finish-order + stale-GapReason one-liners. Every one is small, and C2/C3
must land before trusting any score-driven search again.

**Tier 1 — loop + bench honesty, days.** route_experiment self-sufficiency;
`diagnose_net` MCP wrapper + `pads` schema fix; star the three unstarred
corpus boards; make route_order_search record trials + add `apply`.

**Tier 2 — performance, ~a week.** P1 maze preamble (byte-identical);
P2 arm static_block for the primary route; P3 ladder budgets (Step 4);
P4 oracle memoization; P5 hole-grid + emitOpens index. Re-run
`bench-route --breakdown` as the gate for each.

**Tier 3 — completion mechanics, weeks.** Escape-contention auto-detection
feeding escape_assign (+ copper-aware lanes, via sites, per-layer plans) with
*reserved* lanes; unify blocker nomination on softProbe and give vacate
multi-seed joint transactions; let escalation retry `blocked` nets after
rip-up frees copper; re-couple diff pairs in escalation; adaptive re-enable of
the two powered-off rip rungs for the last K nets.

**Tier 4 — strategic bets, weeks each, in this order only.**
(1) Overlap-tolerant global accept gate, then a real negotiated-congestion
iteration on top — not before, or it re-scores 83/90. — **done 2026-08-06. The
gate lands; negotiated congestion is KILLED and ships disarmed. See the MEASURED
block below.** (2) Per-class lattice
pitch (retires most of fine_window) — **done 2026-08-06 and measured a re-roll,
not a gain; ships OFF as a per-board opt-in, retires nothing from fine_window.
See the MEASURED block in §4E.** (3) `(match-group)` length matching.
(4) Stackup εr/thickness + width-from-Z₀, which upgrades `(max-freq)` from
geometry discipline to electrical truth.

> **MEASURED 2026-08-06 (Tier-4 item 1) — the gate lands, the negotiation dies.**
> `src/placement/congestion.zig`. router.zig pays **net zero code lines** for it
> (+4 for the import, the `Ctx.congest` field and the `finishBatch` call, −4 by
> compaction; the file-size ratchet is unchanged at 10223).
>
> **Stage 1, the sandbox.** A phase in which illegal board-wide states are
> permitted and nothing is judged until it closes. `router.blocked` and
> `router.relaxStep` consult two entry points behind a nullable pointer
> (`congestion.walls` / `congestion.price`), so foreign copper a *re-routable,
> unguarded* net owns becomes passable at a price instead of walling the maze
> out; ground, plane- and pour-carried nets, diff-pair members, `(max-freq …)`
> nets, everything frozen, every PAD and every reserved lane stay hard. Overlaps
> are detected by diffing the occupancy lattice after each victim's claim — the
> grid holds one owner per cell, so a diff is the only way to see a share — and
> the displaced owner is remembered so ripping the victim hands the cell BACK
> rather than freeing it to nobody (without that ledger a round reporting zero
> shared cells handed the gate 23 track-track errors). The end-state accept is
> `fine_accept.strictlyBetter` over `fab_readiness`'s oracle plus
> `drc.errorCount` not risen plus convergence; anything else restores byte for
> byte. Disarmed, the corpus is **row-identical to main on all 18 boards** —
> every field but wall clock, open-net lists included (633.6 s vs 628.1 s).
>
> **Stage 2, the negotiation.** Classic PathFinder: route the victims with
> foreign copper priced by present congestion x history, rip everything involved
> in an overlap, re-route under raised prices, converge or budget out. Per-round
> trace, barracuda (7 residual nets):
>
> ```
> iter 1 victims=7  present=1.0  overlap_cells=3 displaced=2 (SPI_MISO, V_1V8A)
> iter 2 victims=9  present=4.0  overlap_cells=1 displaced=1 (LOCK_DET)
> iter 3 victims=10 present=16.0 overlap_cells=0 displaced=0  -> CONVERGED
> iters=3 reroutes=26 overlaps=4 oracle 81->81 lost=0 drc 2->11 accepted=false
> ```
>
> Four findings, in the order they kill the idea:
>
> 1. **The algorithm works.** It converges, and its copper closes nets: on
>    cyclops-xband-sip the loop closes ELEVEN more than the ladder left (oracle
>    25 → 36) and on straps five (83 → 88), losing none.
> 2. **Its copper is illegal, and convergence does not make it legal.** A lattice
>    on which nobody shares a cell is not a board that clears DRC — the grid
>    records path centrelines while the rules measure via barrels, diagonal spans
>    and per-class widths. Barracuda converges at ZERO shared cells and still
>    hands the gate **+9 fab-blocking errors** (3 via↔track, 6 track↔track);
>    xband-sip +8 (all track↔track). The gate refuses every one, which is the
>    gate doing its job.
> 3. **Legalized, the negotiation's product is worth exactly zero.** Laying the
>    discovered victim SET down the ordinary way, in the router's own priority
>    order, gives DRC-clean copper on every board — and gives back precisely the
>    board the ladder already had:
>
>    | board | oracle routed | DRC errors | verdict |
>    |---|---|---|---|
>    | barracuda | 81 → 81 | 2 → 2 | converged, no gain |
>    | cyclops-xband-sip | 25 → 25 | 11 → 11 | no gain, no loss |
>    | straps | 83 → 83 | 154 → 154 | no gain, no loss |
>    | black-canyon | 54 → 54 | 228 → 228 | 0 overlaps to negotiate |
>
> 4. **Where the residual is sealed there is nothing to negotiate.** Barracuda
>    and black-canyon produce **4 and 0 shared cells in total**: their open nets
>    do not fail because copper is in the way, they fail because pads, the
>    outline and the lattice are — none of which a sandbox may lower, and a pad
>    can never be re-routed. Same diagnosis `joint_rescue` recorded for the same
>    seven nets. And the residue that never clears elsewhere (11–35 cells on
>    straps / xband-sip) survives `present = 256` — a surcharge of 256 grid
>    pitches per cell — so it is a capacity wall, not a pricing miss.
>
> Conclusion: negotiated congestion joins topology corridors (three doses) and
> escape guides as global steering measured net-zero-or-negative on this corpus,
> and for the same underlying reason all three failed — **the binding constraint
> is pad geometry and escape assignment, not which corridor a net picks.** It
> ships OFF (`Limits.max_iterations = 0`, a one-line A/B). The SANDBOX ships ON
> and disarmed, because it is the only place in this engine where a whole-board
> re-route may pass through an illegal state and be judged solely on where it
> ends up — a reusable primitive, tested for byte-identical rollback and
> determinism, that any future global phase can borrow without re-deriving it.
> This closes Tier 4 item 1.
