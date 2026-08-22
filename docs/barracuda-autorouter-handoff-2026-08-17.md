# Barracuda autorouter handoff

Date: 2026-08-17 UTC

This is the handoff for the Barracuda copper-connectivity and reference-free
autorouting work. The current autorouter work is **not complete, committed,
merged, or deployed**. Earlier connectivity, rendering, provenance, plane, and
via-pruning work described below is already on `main`.

## Requested outcome

The remaining objective is a fresh, engine-generated route of Barracuda that:

- routes all 109 multi-pad nets without replaying saved/reference copper;
- reports zero fabrication/connectivity DRC errors;
- completes within five minutes end-to-end;
- may learn generic routing rules or use authored constraints derived from the
  completed layout, but must synthesize the copper itself;
- is rebased onto the latest `main`, passes the release gate, is committed in
  both repositories, merged, deployed, and verified in production.

That objective has not yet been achieved. The best fresh run is 102/109 with
zero DRC errors. The most recent experiment regressed to 98/109 and should not
be treated as the new baseline.

## Repository and worktree state

EDA repository:

- Worktree: `/home/epentland/ai/canopy/eda/.claude/worktrees/barracuda-reference-free-complete`
- Branch: `codex/barracuda-reference-free-complete`
- Base/current HEAD: `37ba1bf6` (`pcb: add persistent trace segment IDs`)
- Diff: 19 modified files, 1,738 insertions, 135 deletions
- No commit has been made on this feature branch.

Nested designs repository:

- Worktree: `/home/epentland/ai/canopy/eda/.claude/worktrees/barracuda-reference-free-complete/projects/designs`
- Branch: `codex/barracuda-reference-free-complete-designs`
- Base/current HEAD: `21f75ab` (`pcb: set Barracuda pour fabrication rules`)
- Modified file: `src/boards/barracuda/barracuda.sexp`
- Diff: 223 insertions, 63 deletions
- No commit has been made on this feature branch.

The root `main` checkout was deliberately left untouched. It has a pre-existing
unrelated modification:

```text
 M .guardian/mutation.txt
```

At the last local check, EDA `main` was also at `37ba1bf6` and designs `main`
was at `21f75ab`. A network fetch/pull and final rebase onto the remote latest
`main` have **not** been performed yet.

## Production-visible work already merged

These changes preceded the unfinished branch and are already in EDA `main`:

| Commit | Result |
| --- | --- |
| `e5a64250` | Made PCB connectivity copper-honest instead of accepting mere visual contact. |
| `d78ba490` | Purges exposed route stubs to a fixed point. |
| `3c036223` | Requires full trace-width contact at pads, addressing tangential/sliver pad overlap. |
| `55a36ccf` | Preserves stitching-via connectivity in KiCad-related geometry handling. |
| `4952962b` | Preserves concave/custom pad geometry in KiCad export instead of misparsing the footprint. |
| `d16e9c2d` | Requires full-width trace-to-trace junctions. |
| `7068254c` | Requires full-width trace/via junctions, addressing tiny via tangencies. |
| `7e2f2f1e` | Removes non-GND vias whose deletion does not change connectivity. |
| `c809fbc6` | Adds route provenance and authors inner-layer power pours. |
| `37ba1bf6` | Adds stable IDs to trace segments for reproducible review/fixes. |

Related designs history on `main` includes completed RF routing, feedback-edge
and perimeter fixes, nearby ground-via requirements, and Barracuda pour
fabrication rules (`397fbbb`, `72bc8d2`, `c32fa88`, and `21f75ab`).

The layout the user has been reviewing is named:

```text
barracuda-kicad-clean-v1
```

The local layout sidecar is
`projects/designs/src/barracuda.layouts.json`. The fresh-route experiment uses
that row for placement and pours but deliberately skips its saved tracks and
vias.

## Connectivity model now on main

The original bug was that copper could be called connected when two rendered
shapes only touched by a tiny amount. The merged model now requires a
manufacturable-width contact:

- A trace contacting a pad needs an overlap cross-section at least as wide as
  the connecting trace, rather than a point/tangent intersection.
- Trace-to-trace joins require a full-width junction rather than a sliver.
- Trace-to-via and via-related joins use the same robust-width principle.
- Pad and custom-pad geometry is preserved through KiCad export, including
  concave shapes that were previously flattened/misinterpreted.
- Stub cleanup repeats to a fixed point, so removing one invalid connection can
  expose and remove the next orphan.
- Redundant non-GND vias are tested by removal and kept deleted only when all
  connectivity remains unchanged. GND vias are exempt.

KiCad was used as an independent check. The two categories the user asked to
fix were disconnected nets and loose copper. The footprint mismatch was traced
to export/parsing of custom/concave pad geometry rather than a bad source
footprint; the export fix is the `4952962b` commit above.

## Uncommitted autorouter implementation

### Hard route deadline

- Added DSL form `(max-route-seconds N)` and carried it through parsing,
  validation, lowering, topology planning, routing, rescue passes, and the MCP
  experiment path.
- Barracuda currently specifies 240 router seconds, reserving roughly 60
  seconds for request setup, final connectivity/DRC, and response encoding.
- Long loops poll a shared absolute deadline and do not accept a partial
  mutation after the deadline.
- Timed standard routes use a one-shot initial pass. The previous standard
  retry ladder could consume the entire deadline before productive repair.

### Repair-only guidance

- Added `repair-waypoints` to the design DSL and route policy.
- Added `seed-first` wave behavior.
- Ordinary waypoint seeds do not consume repair-only points.
- A failed route can retry its authored repair corridor, and the post-route
  pass can retry open nets against frozen already-connected copper.
- A repair is accepted only on strict fabrication-connectivity improvement.

Parser/lowering storage is in:

- `src/eval/design_block.zig`
- `src/eval/env.zig`
- `src/placement/plan_resolve.zig`
- `src/placement/route_policy.zig`

Routing use is in:

- `src/placement/router.zig`
- `src/serve/route_plan.zig`

### Connectivity-preserving rescue acceptance

- Generalized `fine_accept.Gate.acceptsReplacement` to evaluate an arbitrary
  group of removed/replacement tracks and vias against full fabrication
  connectivity before and after.
- `joint_rescue` uses that gate and rejects a candidate unless it connects more
  nets without disconnecting any previously connected net.
- A candidate is not committed if its deadline expires during acceptance.
- The public API Guardian snapshot was updated for `acceptsReplacement`.

### Residual repair experiments

- Added a frozen-copper guided retry for open nets.
- Added a field-cluster attempt using up to three open seed nets plus up to six
  generated blockers (96 total elements), with strict connectivity retention.
- Added an immediate repair-corridor fallback after an ordinary net fails.
- The current source scales that immediate fallback to 8,192 probes per repair
  waypoint, capped at 65,536. This gave no routing gain and cost about six
  seconds. Revert the scaling or remove the immediate fallback unless a later
  experiment demonstrates a benefit.
- A bounded joint-rescue tier was removed from timed standard routing because
  it consumed most of the deadline without changing accepted copper. The safe
  acceptance machinery remains useful for untimed/explicit rescue work.

### Current debug residue

`src/serve/route_plan.zig` currently contains:

```zig
const routeLog = std.log.info;
```

and several diagnostic log calls. Remove or demote these before release.

`docs/language-forms.md` also needs regeneration/correction: its explanation of
repair semantics is stale and the generated form table does not yet clearly
list `repair-waypoints`.

## Current Barracuda design constraints

The uncommitted `barracuda.sexp` now includes:

- a 240-second internal route deadline;
- explicit layer/order guidance for reference, RF, loop-filter, SPI/control,
  enables, and power nets;
- `seed-first` plus repair corridors for `RF1_ADF_FB`, `SPI_LMX_CSN`,
  `TXDATA_ADF`, `LOCK_DET`, `EN_LDO5V`, and `EN_BUCK6V`;
- `V_3V3A` preference for `In3.Cu`, matching the retained In3 power zone;
- selected waypoint/guided local escapes derived from the completed board's
  topology, without asking the engine to replay copper.

Important: the file currently contains the rejected v37 RF experiment:

```lisp
(repair-waypoints
  (at 143.100 98.000 "B.Cu"))
```

That single sparse point regressed the route to 98/109. Before resuming from the
102/109 baseline, restore the previous four-point RF repair corridor:

```lisp
(repair-waypoints
  (at 142.880 96.400 "B.Cu")
  (at 143.613 97.133 "B.Cu")
  (at 143.613 98.648 "B.Cu")
  (at 143.940 99.258 "B.Cu"))
```

## Best known fresh route

The best reproducible result is v30/v31/v35/v36 quality:

- 102 of 109 nets connected
- 0 DRC errors
- best recent elapsed time: 244.72 seconds (v35)
- 171 vias
- 1,108.505 mm total trace length
- score 482.93

The seven remaining nets and strict pad-island gaps are:

| Net | Islands / pads | Minimum spanning gaps (mm) |
| --- | ---: | --- |
| `SPI_SCK` | 4 / 4 | 6.420, 43.538, 14.301 |
| `LOCK_DET` | 2 / 2 | 55.272 |
| `TXDATA_ADF` | 2 / 2 | 49.611 |
| `V_3V3A` | 8 / 27 | 7.359, 5.604, 10.193, 3.483, 2.017, 1.000, 3.584 |
| `EN_BUCK6V` | 2 / 2 | 16.503 |
| `SPI_LMX_CSN` | 2 / 2 | 42.541 |
| `RF1_ADF_FB` | 2 / 2 | 3.995 |

The current implementation therefore has a solid zero-DRC floor, but it is
seven nets short of completion.

## Experiment log

All of these are fresh routes; the saved reference tracks/vias are not loaded.
Times marked `—` were not retained in the condensed session notes.

| Version / artifact | Routed | DRC | Seconds | Conclusion |
| --- | ---: | ---: | ---: | --- |
| v22 `barracuda-conservative-v22.json` | 102/109 | 0 | 194.57 | Original strong baseline. |
| v23 `barracuda-deferred-guided-v23.json` | 98/109 | — | — | Deferred guidance regressed. |
| v24 `barracuda-guided-slices-v24.json` | 99/109 | — | — | Guided slices did not recover baseline. |
| v25 `barracuda-separated-guidance-v25.json` | 100/109 | — | — | Improvement, still below baseline. |
| v26 `barracuda-standard-guided-v26.json` | 98/109 | 2 | — | Regression plus DRC; rejected. |
| v27 `barracuda-old-engine-current-policy-v27.json` | 102/109 | 0 | — | Reached 102 with a different open-net set. |
| v28 `barracuda-broad-seed-residual-v28.json` | 94/109 | 1 | — | Broad repair seeding was harmful. |
| v29 `barracuda-baseline-plus-residual-v29.json` | 100/109 | 0 | — | Residual pass still below baseline. |
| v30 `barracuda-deferred-repair-v30.json` | 102/109 | 0 | 256.71 | Restored the seven-net baseline. |
| v31 `barracuda-joint-residual-v31.json` | 102/109 | 0 | 251.64 | Frozen guided and cluster repairs made no gain. |
| v32 `barracuda-plane-residual-v32.json` | 98/109 | 0 | 281.66 | Unsafe plane stitch regressed and nearly exhausted deadline; discarded. |
| v33 `barracuda-bounded-joint-v33.json` | 98/109 | 0 | 267.60 | Bounded joint rescue starved useful work. |
| v34 `barracuda-oracle-joint-v34.json` | 98/109 | 0 | 270.07 | Safe oracle kept no joint candidate; internal floor 92, final 98. |
| v35 `barracuda-immediate-repair-v35.json` | 102/109 | 0 | 244.72 | Immediate fixed-budget repair had no net gain. |
| v36 `barracuda-scaled-repair-v36.json` | 102/109 | 0 | 250.76 | 8,192 probes/point had no gain and was slower. |
| v37 `barracuda-sparse-rf-repair-v37.json` | 98/109 | 0 | 253.21 | One sparse RF choke point opened four extra nets; reject and roll back. |

v37's 11 open nets were:

```text
SPI_DSA_CSN
SPI_SCK
LOCK_DET
TXDATA_ADF
V_1V8A
V_3V3A
EN_BUCK6V
SPI_LMX_CSN
RF1_ADF_FB
adf4159/ADF_FB_RF_AC
adf4159/RFINB_ADF
```

## Reference-board evidence

The completed layout was inspected as a human/oracle reference only. Relevant
reference copper counts were:

| Net | Tracks | Vias |
| --- | ---: | ---: |
| `RF1_ADF_FB` | 13 | 0 |
| `SPI_LMX_CSN` | 11 | 3 |
| `SPI_SCK` | 35 | 10 |
| `TXDATA_ADF` | 19 | 5 |
| `LOCK_DET` | 35 | 12 |
| `EN_BUCK6V` | 21 | 7 |
| `V_3V3A` | 125 | 18 |

The reference dump is `/tmp/barracuda-reference-residual-copper.txt`.

An isolated KiCad reference test was especially useful:

```bash
./zig-out/bin/netlisp route-kicad-reference \
  /tmp/barracuda-six-layer-minimal.kicad_pcb \
  --net RF1_ADF_FB --reference-path
```

It erased the reference net's 10 segments / 4.534 mm and freshly synthesized a
connected six-track route in about 2.1 seconds, with four new segments,
4.833 mm, zero vias, and `reference_replayed: []`. This proves the RF route is
physically synthesizable against the completed surrounding arrangement without
copper replay. The failure is therefore route order/guide interaction in the
from-scratch board, not intrinsically impossible geometry.

`src/kicad_pcb/reference_guides.zig` can derive hard paths/branches. Do not use
the PCB UI/MCP reference-copper replay path for the final result; replay violates
the requested reference-free outcome.

An attempted export into `/tmp/barracuda-reference-route.aaWL1Q` wrote netlist
and footprint data but no PCB, and Debug SafeAllocator emitted very large leak
diagnostics. Treat that as a tooling issue, not a routing result.

## Approaches that should not be repeated unchanged

- **Broad repair seeds:** reduced completion as far as 94/109 and introduced a
  DRC error.
- **Timed standard retry ladder:** spent the route budget before the repairs
  most likely to help.
- **Bounded whole-field joint rescue inside the timed route:** did not mutate
  accepted copper and caused time starvation.
- **Unsafe in-place plane stitching:** regressed to 98/109 and risked buffer
  mutation. Any plane repair must be transactional and fabrication-gated.
- **One aggregate three-seed/six-blocker cluster:** safe but made no gain.
- **Increasing repair probe budget:** identical 102/109 copper with worse time.
- **One sparse RF waypoint:** v37 regression to 98/109.
- **Existing topology planner as the main route:**
  `/tmp/barracuda-topology-one-shot-mcp.json` reached only 91/109 (40 topology
  waves, 17 guides, 84 skipped) and was slower; it is not a drop-in solution.

## Verification already performed

Focused Debug tests passed:

```text
zig build --seed=1 test -Dtest-filter='bounded joint' -Doptimize=debug
zig build --seed=1 test -Dtest-filter='joint pass' -Doptimize=debug
zig build --seed=1 test -Dtest-filter='replacement gate' -Doptimize=debug
zig build --seed=1 test -Dtest-filter='deferred repair corridor immediately' -Doptimize=debug
```

Also passed during the work:

```text
zig build --seed=1 test-compile -Doptimize=debug
zig build --seed=1 -Doptimize=debug
```

The last build reported zero Guardian blockers and five report-only findings.
Guardian's public API snapshot was accepted for the new replacement gate. A
fresh `test-compile`, full release preparation, and final Guardian feedback log
are still required after the code is stabilized.

## How to reproduce a timed fresh route

From the feature worktree, build Debug and run the local server:

```bash
zig build --seed=1 -Doptimize=debug
NETLISP_DEV=1 ./zig-out/bin/netlisp serve \
  --project-dir /home/epentland/ai/canopy/eda/.claude/worktrees/barracuda-reference-free-complete/projects/designs \
  --port 7063
```

Then issue a fresh standard experiment:

```bash
/usr/bin/time -f %e -o /tmp/barracuda-next.time \
curl --max-time 330 -sS -o /tmp/barracuda-next.json \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":38,"method":"tools/call","params":{"name":"route_experiment","arguments":{"name":"barracuda","layout":"barracuda-kicad-clean-v1","effort":"standard"}}}' \
  http://127.0.0.1:7063/mcp
```

The previously launched server used port 7063 and the v36-era binary. Verify
or restart it before relying on it; a Codex terminal session ID is not a stable
handoff mechanism.

## Recommended next steps

1. Restore the four-point `RF1_ADF_FB` repair corridor so the working tree
   corresponds to the 102/109 baseline.
2. Revert the scaled immediate-repair budget to the smaller fixed budget, or
   remove that fallback if it remains demonstrably neutral.
3. Remove/demote `routeLog` diagnostics and make the docs match the final DSL.
4. Work one open-net class at a time with the fabrication gate:
   - `RF1_ADF_FB`: compare the successful isolated synthesis's local order with
     the from-scratch order; the geometry itself is feasible.
   - `SPI_SCK`: needs a true multi-branch tree (three root-to-terminal branches),
     not a single linear corridor.
   - `V_3V3A`: factor the transactional plane-stitch logic from
     `mcp_close_gaps` into `route_close`; connect one island at a time and keep
     only strict full-board connectivity gains.
   - long two-terminal control nets: release/reroute diagnosed blockers in a
     small explicit transaction per target rather than one aggregate cluster.
5. Keep every fresh run below five minutes and retain the last 102/109 zero-DRC
   result as a hard non-regression floor.
6. Once 109/109 and zero DRC are achieved, run focused tests, `test-compile`,
   rebase both branches onto current remote `main`, resolve any generated-doc or
   Guardian snapshots, and run `.githooks/prepare-release.sh` exactly once.
7. Commit the nested designs repository and EDA repository separately, merge
   both feature branches only when clean and verified, then confirm production
   shows the generated layout and its In3 power planes.

## Release checklist still outstanding

- [ ] 109/109 fresh autoroute
- [ ] zero fabrication/connectivity DRC errors
- [ ] end-to-end runtime under five minutes
- [ ] no reference copper replay
- [ ] remove debug logging and rejected experiment residue
- [ ] correct/generated DSL documentation
- [ ] focused tests and fresh `test-compile`
- [ ] fetch/rebase latest main in both repositories
- [ ] clean commits in designs and EDA
- [ ] `.githooks/prepare-release.sh`
- [ ] append and commit Guardian feedback in `guardian-zig`
- [ ] merge to main
- [ ] production deployment and visual/API verification

## Key temporary artifacts

These are local `/tmp` files and should be copied if the handoff moves to a
different machine:

```text
/tmp/barracuda-conservative-v22.json
/tmp/barracuda-deferred-repair-v30.json
/tmp/barracuda-joint-residual-v31.json
/tmp/barracuda-plane-residual-v32.json
/tmp/barracuda-bounded-joint-v33.json
/tmp/barracuda-oracle-joint-v34.json
/tmp/barracuda-immediate-repair-v35.json
/tmp/barracuda-scaled-repair-v36.json
/tmp/barracuda-sparse-rf-repair-v37.json
/tmp/barracuda-topology-one-shot-mcp.json
/tmp/barracuda-reference-residual-copper.txt
/tmp/barracuda-six-layer-minimal.kicad_pcb
/tmp/barracuda-six-layer-minimal.drc.json
```

Matching `.time` files exist for the main timed experiments.

---

# Campaign outcome addendum (2026-08-17, session 2)

The objective above was pursued to completion of every mechanical lever. Final
verified state, reproduced on both build modes:

- **Fresh reference-free route: 104/109 nets, 0 DRC errors** — Debug 237 s,
  ReleaseSafe candidate 59–95 s (candidate `89ba4bc17`, gate green 3×,
  full suite 2997+/green).
- Floor progression this session: 102 (handoff baseline restore) → 103
  (RF1_ADF_FB root-caused: a stale `vco-divider-raw` waypoint dragged DIV_RAW
  through the RF corridor; designs commit 109f041) → 104 (residual-budget
  reallocation + detour-corridor final pass; EN_BUCK6V closed).
- Landed machinery: transactional island-close ledger (`island_accept.zig`),
  per-target and per-gap rip-up transactions with a wide second tier
  (`target_unblock.zig`), authored branch-tree DSL (`(branches …)` +
  `guide_branch.zig`), gate slice/refusal-memo/prune-judging economics, the
  shared-trunk orientation fix, and the LiftedNet rescue fix (whole-net rescues
  no longer stack duplicate copper on retained subtrees).

## The remaining five, with measured causes

| Net | Shape | Why it stays open |
| --- | --- | --- |
| `LOCK_DET` | 55.3 mm | Corridor sealed by unrippable copper (GND stitch metal, REF pair); wide rip tier (6 nets/128 elements/20 s) refused at ReleaseSafe speed. |
| `TXDATA_ADF` | 49.6 mm | Same class. |
| `SPI_LMX_CSN` | 42.5 mm | Same class (order_congestion; rippable neighbours moved nothing). |
| `SPI_SCK` | 6.4/43.5/14.3 mm | Authored branch tree binds correctly but ALL limbs are geometrically blocked on the fresh board; per-limb maze fallbacks byte-identical. Reference closes it without In1, so feasibility is placement-order-bound, not layer-bound. |
| `V_3V3A` | 8 islands, 1.0–10.2 mm | Small-gap joins refused `no committable path` additively; per-gap rip transactions (smallest-first, island-merge gated) closed nothing at ReleaseSafe speed. |

Speed is NOT the constraint: at ReleaseSafe the whole pipeline converges by
~45 s and ~180 s of the 240 s budget goes unused. The completed reference board
routes all five through **In1.Cu**, which this design's `(stackup 6 …)`
declares a continuous GND plane — the fresh router honours the declared
stackup and therefore cannot use the one channel the hand-finish used.

## Paths to 109/109 (a decision, not a bug list)

1. **Protected-copper negotiation** — let a transaction reroute the REF_LMX
   diff pair as a coupled pair (its In2 stripline can shift vertically without
   breaking geometry) and shift GND stitch barrels. Real router engineering
   (days), RF review required.
2. **Targeted placement adjustment** — the five seal because escape lanes are
   claimed; small moves of 2–3 parts would open them, but the objective pinned
   the completed placement.
3. **Stackup contract change** — permit bounded In1 signal windows (what the
   hand-finish did). Electrically a design-owner decision (EMC/impedance
   discipline documented in barracuda.sexp says In1/In4 stay continuous).
4. **Author corridors from fresh-board occupancy imagery** — measured
   treadmill: 15+ authored-corridor attempts across sessions moved net count
   zero; not recommended without new information.

Wave-order and net-class priority levers are measured inert for these nets
(v72/v73 byte-identical; the `raise_priority` remedy was fixed to say so).
