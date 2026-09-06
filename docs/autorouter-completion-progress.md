# Three-board autorouter completion work

The goal remains complete automatically generated routing for Barracuda Base,
Barracuda RF, and Black Canyon RF, with the DSL expressing the required routing
intent and the inspection/edit tools sufficient to verify and finish the boards.
Completion requires a saved generated candidate for each board, every routable
net connected, no geometry DRC errors, and the authored hard constraints intact.
It has not been achieved.

The best generated-copper candidates currently stand at:

| Board | Connected nets | Geometry errors | Remaining acceptance work |
| --- | --- | --- | --- |
| Black Canyon RF | 59/59 | 0 | No missing authored surface bonds after local capacitor moves and automatic repair; DRC warnings and release review |
| Barracuda RF | 130/130 | 0 | SPI_SCK reduced from 15 to 6 vias; three other via-cap violations and warning review remain; no missing authored bypass bonds |
| Barracuda Base | 99/183 | 1 | Open nets, 26 missing authored bypass bonds, and a hairline gap |

Allocation-safe finishing (`e5981dfe`) preserves Black Canyon's connected result
and prevents incomplete validation or failed allocations from accepting copper.
Explicit zero-round finishing (`fa04b8d8`) makes the wholesale phase directly
testable under a finite budget. These changes improve reliability and diagnosis;
the recent RF escape-order trials have not increased its best completion count.
Weighted-budget and revisable-guide experiments remain opt-in because their
measured completion is worse. The integration keeps equal budgets and fixed
signal seeds as defaults; release verification is recorded with the integration
commit.

For current experiments, saved placements, board outlines, and pours are inputs;
module snapshot tracks/vias and whole-board reference tracks/vias are excluded.
Whether placements and pours must also be regenerated from DSL is an outstanding
scope question. No result here proves that broader form of generation.

The physical-supply audit below corrects an earlier counting error: the prior
RF best is **128/130**, rather than 129/130, on unchanged copper. Its six supply
markers are actual unfed bypass branches. Historical RF and Base measurements
below were made before that checker fix unless explicitly identified as a
physical-supply recheck; their absolute completion counts need revalidation.
The subsequent matched repair closes all six feeds and restores an honestly
verified 129/130. Black Canyon's saved candidate has been rechecked and remains 59/59.

## Reproducible evidence

Frozen inputs (1,212 source/sidecar/BOM files) and SHA-256 manifest:
`/tmp/autorouter-completion-20260905/project` and `input-manifest.json`.
Tool baseline is `3b35239b`; library baseline is `23eabce`, including the two
pre-existing edits to sit5157 and rf-switch-eval. No live design was modified.
`comparison.json` records binary hashes and completed benchmark payloads.

| Measurement | Connected | Geometry errors | Router seconds |
| --- | --- | --- | --- |
| Black Canyon baseline, module snapshots permitted | 56/59 | 0 | 114.74 |
| RF, instrumented original algorithm, module snapshots excluded | 121/130 | 0 | 213.14 |
| RF, local bond bounds/cleanup/expired-work fixes, snapshots excluded | 120/130 | 0 | 219.00 |
| RF, also weighted local budgets and scoped residual guard | 118/130 | 0 | 231.92 |
| Black Canyon, same weighted variant, snapshots excluded | 56/59 | 0 | 157.04 |

These are single runs, not speedup claims. The algorithm variants regressed RF
completion and must remain isolated pending a better result. The first combined
three-board baseline process was killed (exit 137) under memory pressure before
its buffered JSON was emitted. Run heavy board measurements serially and save
one result file per board; do not reuse that incomplete baseline file.

## Confirmed causes and tooling

- Previously, LMX's local slice was about 3.35 seconds and supply-bond work took
  3.45 seconds. Its 19 selected signals entered routing only after that budget
  was spent, and none connected in the primary local pass.
- Every bypass bond allocated a whole-board fine search grid even though its
  local placement already retained all foreign component obstacles and the
  real outline. The new wide-board regression fails before changing the pair
  to use the local bounds and passes after; the full-board seed DRC still gates
  each result.
- Bond cleanup repeatedly refolded rails with no new copper. Expired slices
  also started signal/recovery work. Guarding both cut measured local-phase
  time from 85.81 to 71.29 seconds, but did not improve whole-board completion.
- Weighted budgets give the dense LMX about 9.51 seconds, enough to reach 15/19
  primary local signals. Whole-board completion nevertheless drops to 118/130.
  Better local completion alone is insufficient when the global pass freezes
  those local routes. Investigate global congestion and seed immutability;
  preserve child hard policies, authored bypass bonds, and caller-owned copper
  if experimenting with movable generated seeds.
- `saved_module_routes:false` is available on `route_experiment` and `route_pcb`;
  `bench-route --no-saved-module-routes` uses the same setting. This excludes
  saved module copper; incremental retained board copper and explicit reference
  layouts remain separate inputs and must be omitted for generation proofs.
- Every seed report includes per-module budget, wall time, supply-bond time,
  primary signal time/connectivity, recovery time and timeout state. Primary
  connectivity precedes recovery and board acceptance, so it is not a final
  board completion count. Null budget is untimed; zero is expired.

The Black Canyon image at `black-inspection.png` is a crop of the saved layout,
not a rendering of a benchmark candidate. It confirms the value of existing
net-focused crops but also exposes inspection gaps: layers overlap and labels
crowd dense components. Candidate capture/adoption plus layer-specific images
would let a failed trial be inspected without another expensive route.

## Verification and remaining work

Focused tests pass for local supply routing (including the failing-before /
passing-after bounds case), saved snapshot exclusion after timeout, per-module
reporting, scope-only recovery decisions, and weighted time allocation. The
96-test subcircuit filter passed before the weighted-budget addition; final
full release validation has not run, and the branch is not ready to merge.

The earlier serial job ended with SIGKILL during Base after 16m47s at
10.7 GiB peak RSS. Base produced no JSON and the queued weighted Base run
never started. A new isolated Base trial adds only `(max-route-seconds 283)`
to its route plan so the engine can return a candidate within a bounded search;
`netlisp build` and `netlisp check --severity error` pass (0 violations).
Its input is under `base-bounded-project`, separate from the frozen baseline.

## Candidate capture and automatic finishing

`bench-route --save-candidate NAME` saves generated copper plus actual solved
poses into a new unstarred layout and refuses name collisions. Unlike the
older rows above, these measurements include generated perimeter copper and
reconcile physical connectivity before measuring and saving. The original
starred layouts remain intact. `candidate-project` contains the first captures;
`finisher-project` holds the finishing trials. No live library layout changed.

| Stage | Connected | Geometry errors | Stage seconds |
| --- | --- | --- | --- |
| Black Canyon fresh capture, snapshots excluded | 56/59 | 0 | 129.30 |
| Black Canyon corrected automatic finishing, one round, vacate disabled | **59/59** | **0** | 34.25 |
| Barracuda RF fresh capture, snapshots excluded | 120/130 | 0 | 215.85 |
| RF automatic finishing of two ADF4159 internal nets | 122/130 | 0 | 31.67 |
| RF automatic finishing of remaining control signals | **125/130** | **0** | 107.41 |
| RF first power/ground stitch pass (7 island joins kept) | 125/130 | 0 | 96.54 |
| RF two-round supply stitch/bridge pass | **127/130** | **0** | 230.61 |
| RF same-face alternative bridge for SPI_DSA_CSN | **128/130** | **0** | 31.47 |
| RF separate automatic GND finishing | **129/130** | **0** | 130.37 |

These are successive automatic routing/finishing stages, not a controlled
before/after comparison of one routing algorithm. No manual tracks or vias
were added. Black Canyon's independent `describe_pcb_layout` check reports
59/59, all 134 DRC findings included, and no error-severity geometry findings.
Warnings and full electrical/RF acceptance remain separate from connectivity.
Saved placements, outlines and pours remain inputs; this is not proof of DSL-
generated placement or pours.

The exact Black candidate exposed two further finisher defects:

- Its internal copper omitted saved swept RF regions. The old finisher reported
  13 geometry errors while independent inspection reported zero. Restoring RF
  metadata through every live-copper projection removes those false errors and
  makes gate/cleanup/inspection agree. The fixed run restored the original
  generated candidate through `restore_layout_snapshot`, then again reached
  59/59 with zero errors. RF regions are protected from ordinary rip-up.
- Its live-to-saved rip-index map assumed one physical track per saved row.
  An arc expands into several chords, so a later rip could target the wrong
  saved track. The map now expands each arc's owner and deduplicates repeated
  rip targets; a fixture covers an arc before another net's trace.

Finishing also now preserves the complete saved layout metadata (heatsink,
fan, fabrication layers and dimensions), and its round-failure report excludes
nets the final physical oracle already considers closed. The latter was
reproduced when RF's successful SPI_SCK route still appeared in `failed[]`.
`vacate_failed[]` remains explicitly historical transaction diagnostics.

Focused verification: 67 finishing tests, the assembly-preservation regression,
and candidate capture/failed-capture/collision tests pass. Guardian has zero
blocking findings; only four intended public reporting/persistence additions
were accepted. The latest failure-ledger filter has its own focused check.
The feature branch is still isolated: local budget tuning previously regressed
RF's first pass, Base remains incomplete, and the complete
three-board generation/constraint acceptance goal remains unfinished.

RF's supply bridge pass finished: independent inspection confirmed 127/130,
all 400 DRC findings included, and zero geometry errors. A combined two-round
trial for GND, SPI_DSA_CSN and LOCK_DET was stopped after 14m06s with no JSON
result (exit 143; not an OOM kill). Its tentative copper was not adopted. Keep
finishing scopes small so a long control-net search cannot hold up saving
ground progress; LOCK_DET's remaining terminal span is almost 60 mm.

## Bypass search memory lifetime

The bounded Base benchmark completed at **99/183**, with **one geometry error**,
448.86 router seconds and 11,385,704 KiB peak RSS. Its declared 283-second
search deadline does not cap mandatory reconciliation and finishing: pruning
alone took 124.51 seconds. The MCU and reference-clock slices spent their entire
local allowance on supply bonds, so their primary signal passes never started.
The saved candidate is not a completed layout.

Each bypass attempt previously allocated its search grid and assembled-board
seed DRC world into the whole-board arena. A nested arena backed by that same
allocator would retain the pages just as long. The attempt now owns independently
reclaimable scratch pages and copies only accepted value-only track/via records
to the caller. The search inputs, policies and acceptance gate are unchanged.

The existing supply fixture now gives `attemptBond` only 4 KiB for retained
output. It failed with `OutOfMemory` in `allocLayerGrids` before the fix and
passes afterward, including the returned surface bond. All 48 tests selected
by `subcircuit_route` pass, and the ReleaseSafe measurement build passes Guardian
with zero blockers. A repeat of the same bounded Base input/deadline completed:

| Bounded Base run | Connected | Geometry errors | Router seconds | Peak RSS KiB |
| --- | --- | --- | --- | --- |
| Before independent bond scratch lifetime | 99/183 | 1 | 448.86 | 11,385,704 |
| After independent bond scratch lifetime | 99/183 | 1 | 413.61 | 10,493,960 |

Peak memory fell about 7.8% in these single timed runs; they are not repeated
performance estimates. Completion did not improve, and 10.01 GiB peak RSS is
still too high to consider Base's memory problem solved. Accepted local seed
nets increased from 11 to 13, but MCU/refclk signals remained starved by bonds.
Independent inspection of the original candidate locates its geometry error:
a 0.01257 mm hairline gap on `refclk/LMK_GPIO1_SCS`, between R95.1 and U28.24.

## Alternative island endpoints and batch rip mapping

The nearest pad pair is only one possible join between two copper islands.
On RF's SPI_DSA_CSN, the nearest pair is J1.12 on the bottom face and dsa/U9.16
on the top face, just 0.28 mm apart in XY. Once that pair fails, the finisher
now tries the nearest untried pair sharing a face on those same two islands.
It still adds at most one bridge per oracle join per round and uses the existing
connectivity, collateral-repair and DRC gates. In the actual RF trial, round 0
failed on J1.12; round 1 routed from dsa/R105.1 on the top face and closed the
net. Result: **128/130, zero geometry errors**, 31.47 seconds, no manual copper.

The earlier arc-map fix also needed to reach the main batch judge. That path
still passed physical chord indices directly to saved-track mutation, while
the retry paths translated them. The batch now retains its original live-to-
saved map and translates each rip before the transaction. A regression with
an arc before a redundant victim trace failed before this change: the judge
accepted the hop but never marked the intended saved victim row. It now passes.

The alternate-pad planner regression also failed before its implementation
and passes afterward. All 68 finishing tests pass; the ReleaseSafe build passes
Guardian after expressing face compatibility as a positive predicate.
Independent inspection confirms 128/130, all 400 findings included, and zero
geometry errors. The separate GND trial then kept 13 island joins, restored its
rip victims, and reached **129/130 with zero geometry errors** in 130.37 seconds
(10.67 GiB peak RSS). Independent inspection confirms 129/130, all 403 findings
included, and zero geometry errors. Only LOCK_DET remains open. No board routing
or inspection process from these trials is still live.

Next work is closing the final RF nets, inspecting Base's candidate, measuring
the memory fix, and integrating effective finishing with the main autorouter
while preserving all parent and child hard constraints.


## Hard policy during gap repair

Gap searches previously received the plan's ordering but omitted its net layer
masks and new-via limits. A regression with opposite-face terminals and
`max_vias = 0` produced a via before the fix. It now refuses the bridge. The
same acceptance check covers the maze, exact escapes, stitches and shape tier
before a candidate reaches the judge or the batch's live copper.

The finishing tool resolves plan order, net policy and escape reservations
together. Its fixed starting via counts distinguish retained copper from the
new vias this call may add; retries share the remaining allowance. Within a
batch, only accepted hops spend that allowance, and vetoed copper spends none.
Whole-route reconciliation and unblock searches also subtract already generated
vias from the enclosing route's allowance. Local two-terminal recovery now
carries merged parent/child policy and geometry instead of routing unrestricted;
carrier gap stitches receive the parent net policy.

This is layer/via enforcement for these paths, not a complete hard-constraint
proof of all earlier generated copper. The router's existing terminal-face
fanout allowance still applies. Ordered hard waypoint/topology acceptance,
interactive-session completion, and the complete generation pipeline still
need a separate end-to-end constraint audit.

Verification: the new policy filter passes 32 tests, the gap/reconciliation
filter passes 174, and the subcircuit filter passes 96 (counts include shared
unnamed test blocks; do not add them as distinct tests). ReleaseSafe builds
with zero blocking Guardian findings. The reviewed public additions are the
candidate policy predicate and remaining-policy adapter. The integer-budget
snapshot acknowledges bounded conversions: net indices use the router's i32
representation, and via spending is clamped to the u16 allowance before narrowing.

The original Black Canyon generated candidate was restored from snapshot
`2026-09-05T17-37-51` into a separate `hard-policy-project`. The corrected
finisher again reached **59/59 with zero geometry errors**, in 66.24 seconds.
Independent saved-layout inspection confirms 59/59, 148 findings included and
zero geometry errors. This run used 225 vias versus 218 in the earlier
finisher and took longer (earlier 34.25 seconds). It establishes constraint-aware
completion of the finishing step; it does not establish a performance or
routing-quality improvement. These remain single runs on a shared host.


RF's generated 127/130 snapshot (`2026-09-05T18-28-53`) was also restored into
`hard-policy-project`. The policy-aware DSA pass again reached 128/130 in 67.21
seconds, then GND reached **129/130 with zero geometry errors** in 251.93 seconds
(10.67 GiB peak RSS). Independent inspection confirms 129/130, all 403 findings
included and zero geometry errors; LOCK_DET is the sole remaining open. This
replays the last two finishing stages, retaining the earlier 127-net copper;
it is not a fresh board generation with the policy change. The best completion
counts remain unchanged. Detailed payloads and binary hashes are recorded in
`comparison.json` under `hard_policy_finishing`.


A subsequent control replay with the previous `bridge-fallback` binary on the
same original Black snapshot reached 59/59 in **38.66 seconds**, with 218 vias
and zero geometry errors. The new policy-aware run's 66.24 seconds and 225 vias
therefore have a real cost in this comparison; the change is a correctness fix,
not a demonstrated speed or completion improvement. RF's independent per-net
length/via statistics match the earlier 129/130 result exactly. No board process
from these trials remains active. The feature remains unmerged because of the
known first-pass weighted-budget regression and incomplete overall acceptance.

## Scoped repair corridors and physical-layer images

Commit `2b2c9067` fixes a selection guard that excluded every scoped route and
every board carrying retained tracks or vias from deferred corridor repair.
The repair mask now intersects the caller's scope; the fresh first-claim seed
still keeps its original restrictions. A regression reproduced the missing
mask before the fix. A routing fixture now closes the selected signal while
preserving the other net's tracks and via.

Repair policy also stays intact: the residual retry subtracts vias generated
earlier in the transaction, and both immediate and deferred repair keep the
hard allowed-layer mask. Direct waypoint/branch attempts reject guide points
outside that mask. A successful immediate repair now reaches the enclosing
via-budget check instead of returning ahead of it. The forbidden-layer fixture
previously connected on B.Cu despite a top-only policy and now refuses it.
These are layer/via checks for these paths; full ordered-waypoint preservation
through routing and cleanup remains unverified. The branch-construction test
checks the constructed tree before cleanup, whose topology preservation still
needs its own audit.

`get_pcb_layout_image` and the HTTP PNG endpoint now accept a physical copper
layer name, for example `"layer":"In2.Cu"`. Tracks, arcs, RF copper, fills,
surface pads, face labels and layer-specific DRC markers are filtered together;
through vias and drilled pads remain visible. Unknown layers are rejected, and
the cache separates layer requests. Omitting the selector preserves the overlay.
Physical plane layers are selectable too. HTTP/MCP byte parity and pixel checks
cover layer separation, planes, arcs, RF paths, bottom pads and through vias.

The matched LOCK_DET trial copied the same generated 129/130 candidate and kept
the existing 283-second plan budget, standard effort, one-net scope and disabled
saved-module fallback:

| Scoped route | Connected | Geometry errors | Seconds | Saved tracks/vias |
| --- | --- | --- | --- | --- |
| Previous hard-policy binary | 129/130 | 0 | 84.186 | 885 / 426 |
| Scoped-repair fix | 129/130 | 0 | 102.040 | 885 / 426 |

The corrected run actually enters guided repair: its shape probe reports no
channel, then its maze slice expires. It returns normally without cancellation.
**No additional net closes in this comparison.** Independent saved-layout
inspection reports 129/130, all 403 findings, zero geometry errors and per-net
length/via statistics identical to the starting candidate. LOCK_DET is still
open. Timing is from single runs on a shared host, not a speedup measurement.

Evidence is recorded under `scoped_guided_repair` in `comparison.json`, with
input/binary hashes, result/inspection payloads and image hashes. The three
reviewed images are `rf-layer-F.Cu.png`, `rf-layer-In2.Cu.png` and
`rf-layer-B.Cu.png` under `/tmp/autorouter-completion-20260905`. They separate
the congested bottom connector escapes from the inner-layer routing space;
they do not by themselves establish a clearance-safe route between the pads.

Verification: 56 PNG/scope checks and 138 guide/repair/unblock checks pass
(overlapping counts include shared unnamed test blocks), as do ReleaseSafe and
the 88-check commit gate. No trial process remains active. Live design layouts
are unchanged, and the feature remains isolated for the previously recorded
first-pass regression and incomplete overall acceptance.


## Bounded finishing and simpler LOCK_DET corridor

Commit `2e8d044b` adds an optional `max_route_ms` to `close_open_nets`
(1–3,600,000 ms). One deadline covers ordinary rounds, finer searches, rip
escalation, collateral repairs and wholesale retries. It starts after initial
layout evaluation and baseline DRC. On expiry, completed accepted hops remain;
an unfinished hop that breaks another net is rolled back. Final validation and
persistence still run, so this bounds search time rather than total request
duration. The result exposes `search_timed_out`. Omitting the budget preserves
the existing unlimited search behavior.

The gap batch also stops emitting events for requests skipped after cancellation.
The regression previously counted two attempts after the first hop cancelled
its batch; it now keeps that completed hop, leaves the next unsearched, and
reports one attempt. A separate pre-fix regression reproduced an expired
finisher starting another route. Tests also cover invalid budget rejection,
one-time deadline arming, earlier nested deadlines, retention of accepted
copper and rollback of an unrepaired victim. All 90 focused gap/finishing tests,
ReleaseSafe and the 88-check commit gate pass. Via-drill conversion moved beside
pad-drill conversion in `pad_exit` to keep the router under its frozen size
ceiling; the reviewed API snapshot adds only that typed helper.

A separate temporary DSL trial replaced LOCK_DET's long repair corridor with
five primary waypoints: escape into U13's central courtyard on F.Cu, change to
In2.Cu, cross toward J1, then return to B.Cu. Build and error-severity schematic
checks pass, but scoped routing still returns **129/130, zero geometry errors**,
in 57.783 seconds. It adds no tracks or vias. This trial used the preceding
`2b2c9067` binary, not the new finisher. Its source, input hashes and result are
under `rf-lock-center-via-*` in the artifact directory; it was not adopted.
U13 is the level shifter in the ADF4159 subcircuit, with LOCK_DET on pad 10.
The separate F.Cu U13 and B.Cu J1 endpoint crops help inspect those escapes,
but the failed trial does not prove a legal cross-board channel exists.


The new finisher then ran on a separate copy of the original 129/130 candidate,
with only LOCK_DET selected, two rounds requested, `vacate:false` and
`max_route_ms:120000`. Its ordinary hop exhausted after 47.40 seconds; the finer
retry used the remainder of the shared allowance. It returned normally with
`search_timed_out:true`, one hop tried, none kept and no false no-path failure
entry for the interrupted retry. Total command time was **135.81 seconds**,
including setup/final validation, with 1,309,036 KiB peak RSS. This demonstrates
a bounded returned result, not a faster completed search.

The result remains **129/130 with zero geometry errors**. Independent saved
layout inspection includes all 403 findings and confirms that per-net
length/via statistics are identical to the starting candidate. LOCK_DET remains
open; no new copper was accepted. `comparison.json` records the arguments,
source/binary/input hashes, result and inspection under `bounded_finishing`.
No process from these trials remains active. The branch remains unmerged for
the earlier first-pass regression and incomplete whole-board acceptance.

Further correctness review identified two allocation-error paths to fix before
acceptance: finishing's DRC helpers currently turn checker errors into empty
results, and `tryHop` does not roll back mutations if an allocation error escapes
after applying the candidate (the batch judge catches that error as a veto).
The timeout tests cover cooperative deadline expiry; they do not establish
rollback or validation safety under allocation failure.


## Allocation-safe finishing acceptance

Commit `e5981dfe` fixes the allocation-error paths identified above. Rebuilding
live copper, checking geometry/differential quality and counting copper islands
now propagate errors. The hop reserves storage before changing tracks, vias or
rip marks, and its rollback runs on every unaccepted exit, including errors
from collateral discovery, repairs or validation. Existing rip marks from
previous accepted work survive rollback. Pour-obstacle conversion also refuses
an incomplete result instead of searching against a truncated obstacle list.

The severity-policy path is checked too. A malformed/unreadable policy refuses
the finishing call before routing or persistence. Applying overrides cannot
silently lose a warning-to-error promotion when allocation fails; the shared
release report marks that failure incomplete. Full final validation and the
connectivity tally now finish before the layout write. An incomplete report
refuses persistence. Consequently the tool's `wall_ms` now includes final
validation; compare total command wall time with older trials when measuring
performance.

Two regressions failed against the previous implementation: an allocation
failure read as zero validation errors, and a hop returned `kept` despite an
injected failure. The corrected transaction passes a sweep of 591 allocation
failure points with its original tracks, vias and earlier rip marks intact.
Final validation passes a separate 129-point sweep, returning an error or
incomplete evidence at each failure. Additional cases cover severity promotion,
malformed-policy rejection with byte-identical saved layout, and pour-obstacle
allocation. All 81 focused finishing/policy/fabrication-gate tests, ReleaseSafe
and the 88-check commit gate pass. The reviewed API additions are `applyChecked`
and `loadForValidation` in `drc_rules`.

The first Black Canyon replay copied `candidate-project`, which had already
advanced to a connected candidate. That call attempted no hops and only pruned
one loose track, returning 59/59 with zero geometry errors in 8.86 seconds; it
is a cleanup check, not evidence of closing the original three opens. Its
initial input label was corrected in `black-checked-input.json`. The recorded
`2026-09-05T17-37-51` snapshot was then restored through the snapshot tool.
Independent inspection verifies the intended starting state: 56/59, zero
geometry errors, 376 physical tracks and 206 vias. The actual finishing replay
uses that state and has separate `black-checked-replay-*` artifacts.


The verified Black replay accepted all three planned repairs and returned
**59/59, zero geometry errors**, in 41.03 seconds total command time
(1,102,312 KiB peak RSS). It restored its collateral victims, retained five
reported rips and pruned seven loose tracks. Independent saved-layout inspection
confirms all 148 findings were included, zero geometry errors, 430 physical
tracks and 225 vias. Per-net length/via statistics match the earlier
policy-aware result exactly. This preserves the previous completion result;
single shared-host timings do not establish a speedup.

## RF terminal escape geometry probe

An isolated `add_tracks` trial used default class geometry to connect U13.10
at (135.95, 106.10) through (136.40, 106.10) to a via at (136.60, 105.90).
The edit was rejected and rolled back: two tracks and one via were proposed,
zero were added. Five geometry errors identify the actual local obstacles:
U13.12 (`adf4159/LS_OE`) on F.Cu, and boost22/R81.2 plus its GND trace on B.Cu.
The saved board remains 129/130 with zero geometry errors. The trial took
13.42 seconds and its `candidate.drc_list` includes exact rule/position/party
information in `rf-lock-escape-probe.json`. This was a manual geometry probe,
not automatically generated routing and not an adopted candidate.

The B.Cu crop `rf-lock-back-under-pll.png` shows copper beneath the apparent
space in the F.Cu courtyard. The image's large mirrored module silkscreen also
obscures part of the copper; a copper-only annotation toggle would improve such
close inspections. Exact DRC identities, rather than the image alone, establish
the collision. Saved-copper inspection also locates the SPI_ADF_CSN trace across
the outward F.Cu escape area, motivating a separate route-order experiment.

## RF escape-order trials

All trials below use `e5981dfe` and isolated project copies. Agent-directed
`clear_routes` operations change the routing order; every newly added track
and via comes from `close_open_nets`. They do not establish a fully automatic
generation pipeline. The original 129/130 candidate remains untouched.

| Intervention and automatic repair | Connected | Only open net | Geometry errors | Total seconds |
| --- | --- | --- | --- | --- |
| Remove CSN's 16 tracks and 3 vias, route LOCK_DET | 129/130 | SPI_ADF_CSN | 0 | 27.13 |
| Restore CSN around LOCK_DET | 129/130 | SPI_ADF_CSN | 0 | 133.44 |
| Remove one MOSI via, route CSN | 129/130 | SPI_MOSI | 0 | 46.88 |
| Restore MOSI around both new escapes | 129/130 | SPI_MOSI | 0 | 134.16 |

The first repair adds 17 LOCK_DET tracks and three vias; its first via takes
the freed CSN site at (143.280, 110.825). Thus the retained CSN corridor was
a real obstacle to LOCK_DET. CSN's restore attempt reaches its 120-second
search deadline and keeps no copper.

The next trial removes only the generated MOSI via at
(135.3864422822, 105.2833713512), retaining its tracks and shared trunk. CSN
then closes on the divisor-4 corridor grid, with a collateral GND repair also
restored. Its new local via is at (135.117, 104.0115). However, repairing MOSI
tries to rip CSN, cannot restore that victim and exhausts the search deadline.
The rejected transaction leaves the saved 912 tracks and 434 vias intact.

This provides a concrete reason to investigate terminal escape planning and
search-phase budgets. The ordinary gap rip-up removes tracks while retaining
vias. Wholesale repair can move both, but an ordinary round can consume the
whole deadline before wholesale or other search alternatives run. Clearing a
blocking object alone is insufficient evidence of improvement: the displaced
net must also be restored, and these trials have not increased RF completion.
Input manifests, exact arguments and result JSONs are under
`/tmp/autorouter-completion-20260905/rf-*-{input,finish,restore}*`.

Removing the nearby SCK via at (135.617, 104.395) before retrying MOSI did
not help: its first rip again displaced CSN, the collateral repair exhausted
the deadline, and the trial ended at 128/130 with MOSI and SCK open, zero
geometry errors, in 134.47 seconds. This candidate is not adopted.

A read-only comparison with the frozen `Barracuda V2` reference points to
coordinated local escapes as the next experiment. U13 and the bottom R81 have
the same poses, and the reference uses the same 0.4 mm / 0.2 mm signal vias.
Its nearby SCK, MOSI, CSN and LOCK vias lie at (135.1, 104.0), (135.0, 104.7),
(135.0, 105.3) and (134.9, 106.1), respectively. Its V_3V3A via instead lies
at (134.0, 106.92). The generated V_3V3A sites near (135.302, 106.294) and
(134.667, 106.294) occupy part of that reference escape area. This comparison
does not validate the reference layout or adopt its human-authored copper;
it suggests testing joint signal escapes and local supply-via placement,
with full obstacle and policy validation, instead of treating via diameter
as the missing capability.

## Direct wholesale finishing control

The initial attempt to isolate wholesale repair passed `rounds:0` to the old
handler. That was outside its declared schema (minimum 1), but the handler
silently substituted four rounds and started ordinary routing. The experiment
was stopped with SIGTERM, with no result or adopted copper; its input record
explicitly marks this setup error.

Commit `fa04b8d8` adds supported zero-round mode and rejects negative, fractional,
null, boolean and string counts before evaluating the layout. The omitted
default remains four. The schema and API documentation now state that
`rounds:0, vacate:true` starts at wholesale repair, whereas disabling vacate too
leaves only cleanup and final validation. A saved-layout regression previously
attempted three hops despite `rounds:0`; it now attempts none and retains the
original copper and connectivity. All 83 focused finishing/policy/fabrication
tests, ReleaseSafe and the 88-check commit gate pass. A separate immutable RF
input starts the actual wholesale-only measurement in `rf-wholesale-direct-*`.

That measurement attempts zero ordinary hops and one wholesale hop. It times
out at 129/130 with zero geometry errors, preserving every saved track, via,
zone and RF path exactly. It takes 165.55 seconds and peaks at 5,275,584 KiB.
The logs reveal more work after expiration: later wholesale tiers still rebuild
the board, nominate blockers, strip copper and construct rollback copies even
though their routing loops cannot start. Those tiers also emit rejected-trial
diagnostics despite performing no search.

Commit `4b22575a` checks the deadline before any new wholesale tier's setup and
stops its retry ladder before announcing a tier it cannot run. An allocation
failure injected into the next tier reproduced an attempted board rebuild
after expiration; the fixed test performs no allocation. All 83 focused tests,
ReleaseSafe and the 88-check commit gate pass. `rf-wholesale-deadline-*` uses
the exact same input manifest and arguments for the measured comparison.

The guarded replay returns **129/130, zero geometry errors**, with identical
saved tracks, vias, zones and RF paths. It attempts one wholesale hop, rolls it
back and skips the expired tiers entirely. Total command time falls from
**165.55 to 132.14 seconds**; peak RSS falls from **5,275,584 to 1,902,148 KiB**
(about 5.03 to 1.81 GiB). These are single matched trials, not a general speedup
estimate. The setup guard improves the cost of a failed attempt; it does not
close the remaining LOCK_DET net.

Independent saved-layout inspection (`rf-wholesale-deadline-describe.json`)
confirms 129/130, only LOCK_DET open, 918 physical tracks, 426 vias, and all
403 findings included with zero geometry errors. The finisher's own report
contains 399 findings; the independent full view retains the same 403-finding
count as the original baseline. No warning-count reduction is claimed.


## Reserved lanes through local routing and supply stitches

Commit `97236484` fixes three ways routing could ignore hard intent. Local
routing previously filtered foreign reservations out with the selected net
mask; standalone recovery also discarded those reservations and board zones,
and its no-child-policy fallback cleared the parent layer and via limits.
Local and recovery options now retain all parent and child hard reservations,
board pours/keepouts, and destination-board hard limits. Soft preferences may
still change during recovery.

The carrier-drop caller also omitted reservations from its gap board. Merely
forwarding them was insufficient: direct supply-via placement and its straight
stub used geometry checks that never consulted authored lanes. The shared
via-site and track-stub checks now reject foreign lanes, including the snapped
and in-pad ground-via candidates. This does not change lane widths or relax
physical clearance rules.

The regressions reproduce foreign-lane crossings in local routing/recovery,
a carrier via planted inside a reserved lane, and a stub crossing a lane to
reach an otherwise legal pour landing. Removing just the new segment check
makes the last case fail even with the via-site check retained. All **86 focused
subcircuit, gap, reservation and plane-stitch tests pass**, as does the
**88-check Guardian gate**, with no baseline acceptance. ReleaseSafe builds.
An unintended unfiltered `guardian-check commit` test invocation was stopped;
it is not a completed full-suite run. The subsequent ordinary commit used the
cached green code-quality gate. Full release validation remains outstanding.

A matched-input RF replay regenerates only LOCK_DET and V_3V3A, retaining all
other generated copper and all poses/pours, with saved module routes disabled.
Both the prior binary and this fix return **129/130, only LOCK_DET open, zero
geometry errors**, and **887 saved tracks / 425 vias**. Their entire decoded
saved routes objects are equal, including zones and RF paths. The source,
sidecar and BOM hashes match; the new input manifest merely omits history
files. This proves no completion gain for that replay. The frozen board has no
new reserved-escape DSL authored in this trial, so it does not exercise a newly
planned local fan.

The earlier two-net run took 141.56 seconds and consolidated the two nearby
V_3V3A drops into one at (135.236, 106.294). A following bounded LOCK-only
finisher took 131.84 seconds and closed nothing. The fixed replay took 155.69
seconds and peaked at 3,908,088 KiB, but overlapped the stopped unfiltered test
invocation; it is not usable as an uncontended performance comparison.
Artifacts: `rf-lock-v3a-reroute-*`, `rf-lock-v3a-finish-*`, and
`rf-reserved-stitches-*` under the experiment root.

## The escape preview still plans a destination corridor

The four-net `preview_escape_assignment` for adf4159/U13 reports an eastward
corridor at x=144.1 mm, while SCK, MOSI, CSN and LOCK pads are on U13's west
edge at x=135.95 mm. The destinations are east of the chip: the current
algorithm votes from source-to-destination vectors, so this is a global
corridor assignment rather than a plan for leaving those crowded pin lands.
No new local fan has been accepted from this preview.

The tool also lacks a layout selector and reads the default layout. For this
specific trial, all 225 reference and generated-candidate poses were compared
and match exactly, making the placement preview applicable. That extra
provenance check should be unnecessary: preview should accept a named layout
and report its revision. The next planning capability should separate the
initial package exit from the destination corridor and inspect retained copper
near the pins. Grouping these four nets into a single route wave must also
preserve their distinct layer/via policies; changing those limits is not an
acceptable way to manufacture a completion gain.


## Package pin exits and independent assignment peers

Commit `0d6bbda6` adds opt-in `(pin-side)` and `(with-nets ...)` to
`assign-escapes`. Pin-side mode uses the selected source pins' common package
edge, source ordering and a lane pitch large enough for the declared via
copper plus clearance. It takes the nearest cross-section that fits the group
within a 2 mm search beyond the courtyard, refusing mixed package edges.
The cut scan now also rejects cross-sections outside the board's extent on
the escape axis; previously only the transverse lane span was clipped.

Assignment peers are resolved separately from routing ownership. Adding
`(with-nets "SPI_SCK" "SPI_MOSI" "SPI_ADF_CSN")` to LOCK_DET's assignment
steers the group while each peer keeps its original wave priority, allowed
layers, via limit, ordinary waypoints and repair policy. Duplicate peer names
are deduplicated, and unknown peers produce a plan warning. This avoids merging
four different hard policies just to schedule one physical escape.

`preview_escape_assignment` now accepts a named `layout`, rejects a missing
named candidate, reports the selected layout and whether `pin_side` was used,
and explicitly reports `retained_copper_considered:false`. It still operates
on placement geometry, not a validated copper route. Its new `assignment_form`
can be inserted into an existing wave without replacing that wave's policies;
the older per-net waypoint `dsl` output remains available.

All **67 focused assignment, DSL and preview tests pass**, including opposite
facing destinations, rotated/mirrored packages, mixed-edge refusal, board-edge
exclusion, peer policy preservation and invalid tool requests. ReleaseSafe and
the **88-check Guardian gate pass** without baseline acceptance. These checks
do not replace the outstanding full release gate or prove board completion.

On the RF candidate, the new preview assigns all four U13 controls west at
x=135.1 mm, with 0.527 mm pitch. The selected lanes are:

| Net | Source pad y | Lane y |
| --- | --- | --- |
| SPI_SCK | 104.900 | 104.060 |
| SPI_MOSI | 105.300 | 104.587 |
| SPI_ADF_CSN | 105.700 | 105.114 |
| LOCK_DET | 106.100 | 105.641 |

The previous destination-based preview chose east, x=144.1 mm. The new result
is a local capacity plan; no via-site or retained-track clearance is implied
by this table.

A five-net control regenerates these four signals and V_3V3A together under
the existing DSL, retaining other generated copper. It returns **126/130**, all
four controls open, **zero geometry errors**, 849 saved tracks and 413 vias,
in 186.82 seconds with 4,833,288 KiB peak RSS. This is worse than the separately
retained 129/130 candidate and is not adopted.

A second frozen input changes only one source form: it adds the preview's
pin-side assignment plus `(reserve)` to the existing LOCK_DET wave. The same
five-net reroute returns **128/130**, with LOCK_DET and MOSI now connected and
SCK/CSN still open, **zero geometry errors**, 861 tracks and 410 vias, in 124.28
seconds with 3,842,540 KiB peak RSS. The nearby V_3V3A drops move west to
approximately (133.942, 106.809) and (134.093, 107.437); LOCK gets a via at
(134.644, 105.872). The design builds and reports zero error-severity schematic
violations. These are single scoped trials, and the reserved variant still
falls short of the original 129/130 best result.

A 120-second automatic finisher on SCK and CSN keeps one hop, joining part of
SCK's trunk, but ends at **128/130, zero geometry errors**, with both nets still
open. It preserves the authored reservations and hard policies. Saved copper
rises to 876 tracks and 411 vias; the command takes 131.01 seconds including final
validation. Artifacts are `rf-u13-five-net-*`, `rf-u13-pin-side-*`, and
`rf-u13-pin-side-finish-*` under the experiment root.

Independent inspection of the saved scoped candidate confirms 128/130, 909
physical tracks, 411 vias and zero geometry errors. Its 404 DRC findings include
nine error-severity net-open markers: three describe the SCK/CSN pad islands,
and six describe V_3V3_LMX copper disconnections also present in the original
129/130 candidate. The routing tally counts pad-bearing components; the net-open
check also considers orphan copper. These six markers remain acceptance work
and must not be hidden by the zero geometry-error count.

The full fresh trial, with reservations active before any generated track or
via, returns **118/130, zero geometry errors**. It takes 238.33 seconds including
capture, with 11,698,380 KiB peak RSS. LMX's primary local pass connects **19/19**
in 9.64 seconds (2.10 supply, 7.53 signals), before board acceptance; the final
board still has LMX_RFOUTAP open. Fifteen of nineteen local attempts time out;
ADF4159 spends its entire 9.94-second allowance on supply bonds and starts no
signals. The other final opens are GND, LOCK_DET, SPI_ADF_CSN, SPI_DSA_CSN,
SPI_SCK, V_1V8A, V_24V_CLEAN, V_3V75A, V_5VA, adf4159/RSET_ADF and
adf4159/SPI_ADF_CSN_1V8. This does not improve whole-board first-pass completion.

`rf-u13-pin-side-full-describe.json` independently confirms 118/130 and no
error-severity geometry findings on the captured layout, with 668 physical
tracks, 366 vias and 388 DRC findings. Forty-seven are error-severity net opens;
seventeen bypass-open warnings and other electrical/topology findings remain.
The best RF candidate stays at 129/130; none of these experiments replaces it.

## Local signal search memory lifetime

Commit `153a984f` releases each module's signal search, recovery candidates and
timeout validation world before advancing to the next module. Previously these
temporary allocations lived in the caller's whole-board arena, so the local
phase retained grids that could no longer contribute to routing. Accepted seed
tracks and vias are copied by value into the caller's storage. The final
two-terminal recovery helper now also appends with the output allocator rather
than its search allocator, keeping returned copper valid after scratch release.

A 32 KiB retained-output fixture fails before the fix while allocating a signal
grid, then succeeds with exactly the same seed copper after the fix. A separate
4 KiB output fixture exercises timeout validation and two-terminal recovery,
releases scratch and verifies the returned tracks still belong to that buffer.
All **50 focused subcircuit tests**, ReleaseSafe and the **88-check whole-tree
Guardian commit gate pass**; no snapshots were accepted. The finite deadline,
routing order, hard constraints and copper acceptance rules are unchanged.

`rf-local-signal-scratch-project` matches all 1,212 input hashes of the preceding
pin-side full RF run. Its matched benchmark measures memory and completion
separately from the still-unresolved supply-bond time allocation problem.

The completed run retains **118/130, zero geometry errors**, with the exact same
open-net set. Peak RSS falls from **11,698,380 to 7,108,864 KiB (39.23%)**;
elapsed time is 238.33 versus 232.49 seconds. This is one matched run and does
not establish a speedup. Both runs accept 65 seed nets, 237 seed tracks and two
seed vias; LMX reaches 19/19 primary signals and fifteen local attempts time out
in both. Final track counts are both 653, but the new result has one additional
via (367 versus 366), so the deadline-bounded whole-board copper is not identical.
The reduction in retained search memory is useful, but it does not improve the
completion count or resolve supply-bond starvation.

Independent saved-layout inspection confirms **118/130**, 668 physical tracks,
367 vias and zero error-severity geometry findings. It reports 385 DRC findings,
including 46 error-severity net opens. The extra via reduces island-level
findings without closing another whole net. Evidence is in
`rf-local-signal-scratch-describe.json`; the original best candidates are intact.

## Physical supply identity across checking, routing and acceptance

Three fixes address the same proven bypass-family relationship at different
boundaries. Explicit bypass-loop and pin evidence establishes that generated
nets such as `V_3V3_LMX.U10.7` share fabricated copper with `V_3V3_LMX`;
matching dotted names alone is insufficient.

- `cad0cfdf` makes board-level connectivity and net-open DRC include all proven
  branch pads in the parent rail's endpoint set. Previously, a closed parent
  pair and a closed capacitor-to-IC pair counted as connected even with no feed
  between them. Deliberately narrow local endpoint queries remain narrow.
- `d121a35e` gives each gap search a temporary physical-family view of pads,
  tracks, vias and pours. An aliased supply pad no longer blocks its own repair
  as foreign copper. Geometry, original rip indices, hard layer/via policy and
  reserved-lane ownership are preserved; subsequent hops recover their own
  logical identity and accepted copper remains owned by the requested net.
- `24020474` uses the same physical parent endpoints in the finisher's progress
  check. Without this third change, the router found all six feeds but the
  acceptance gate rejected them as `no_merge`, because it still measured only
  the already-connected original parent pads.

The checker regression fails before the first fix; 130 selected connectivity,
DRC and subcircuit tests pass afterward. Gap bridge/stitch fixtures cover parent,
child and subsequent parent queries, absence of alias proof, via/layer limits,
and foreign reservations; 130 selected tests pass. The transaction regression
separately fails with “expected 2, found 1” before the final fix, then passes
with 110 selected acceptance, rollback, physical-identity and gap tests. Each
implementation has a green ReleaseSafe build and 88-check whole-tree commit
gate. Named API acceptance added only `Identity.connectivityNet`, the extracted
`gap_state.State` factory, and `fab_readiness.buildPhysicalNetGraph`.

Independent reinspection of the original saved RF best confirms **128/130**,
918 physical tracks, 426 vias and zero geometry errors. `V_3V3_LMX` has seven
pad-bearing islands: the main feed and six disconnected capacitor/LMX pairs,
at U10 pins 7, 37, 21, 11, 26 and 15. `LOCK_DET` is the other open net.
Independent Black Canyon reinspection confirms **59/59**, 430 physical tracks,
225 vias and no error-severity DRC findings. Full authored-constraint review
remains outstanding.

The matched RF control and fixed candidates start from identical hashes for
all 1,140 inputs. The request names only `V_3V3_LMX`, uses one round,
`vacate:false` and `max_route_ms:120000`. With the corrected checker but old
gap search, all six attempts report `sealed_from`, no hops are kept and the
result stays 128/130 in 28.90 seconds with 1,257,008 KiB peak RSS. The router-only
fix finds six paths but the old progress check rejects them all; that run stays
128/130 in 75.43 router seconds with 8,286,396 KiB peak RSS. Both are useful
controls, not completion improvements. The complete fix keeps **all six hops**, closes `V_3V3_LMX` and reaches
**129/130**, with **zero geometry errors** and no ripped tracks. Six vias are
added (426 → 432); accepted cleanup leaves 885 saved tracks. The command takes
42.91 seconds including final validation and peaks at 4,019,900 KiB RSS.

Independent saved-layout inspection confirms **129/130**, 918 physical tracks,
432 vias and all 398 DRC findings included. Only one is error severity:
`LOCK_DET` remains in two pad-bearing islands. The six supply-open findings are
gone; warnings and full authored-constraint review remain separate acceptance
work. The new best RF candidate is `rf-physical-accept-project`, layout
`autorouter-generated-20260905`. Evidence is in `rf-physical-accept-close.json`,
`rf-physical-accept-describe.json` and their logs under the experiment root.
No manual copper, live-library edits or relaxed constraints were used.

This is a measured finishing improvement, not proof that the fresh hierarchical
first pass has recovered its earlier regression. The feature branch remains
unmerged, pending that regression and full release verification.

Base was also independently rechecked with the final physical-supply checker:
**99/183**, 1,016 physical tracks, 418 vias and 499 findings, including 173
error-severity net-open markers and the existing hairline-gap geometry error.
Its tally is unchanged. `base-physical-supply-describe.json` records this check;
no Base copper was modified in the supply-fix experiment.

## Reserve local time for signal joins

Commit `8d9f35f4` divides each timed module's existing allowance between supply
work and selected signal joins. The supply phase gets its remaining join-work
share; signals retain the original module deadline and may use supply time
left over. Untimed routing and modules with no selected signals keep their
previous deadline. Exact cap-to-pin surface routing, zero bypass vias, hard
policies and assembled-board acceptance remain intact. Expired bond attempts
also stop before retrying with earlier same-rail copper hidden.

The report now includes `supply_budget_ms` and counts selected signal nets even
when a module expires before routing them. The expired-module fixture failed
before this change (zero selected signals instead of one). All **51 focused
subcircuit tests**, ReleaseSafe and the **88-check whole-tree commit gate pass**,
without snapshot acceptance. The retained-output memory fixtures still pass.

A direct RF comparison uses the same 1,212 input hashes and the same physical
supply checker fixes on both sides. Both fresh runs exclude saved module routes
and capture new generated copper; the existing 129/130 finished candidate is
untouched.

| Fresh RF run | Connected | Geometry errors | Command seconds | Peak RSS KiB |
| --- | --- | --- | --- | --- |
| Previous scheduling, `24020474` | 118/130 | 0 | 229.69 | 6,964,928 |
| Signal share, `8d9f35f4` | 119/130 | 0 | 232.34 | 7,226,104 |

These are single runs and do not establish a speed improvement. ADF4159 changes
from 10.16 seconds of supply work and no signal routing to 7.01 seconds of
supply work followed by 3.54 seconds of signals. It reports 9/12 primary signals
connected; LMX reports 19/19 on both sides. Primary reports precede the final
oracle and board acceptance. The new final board closes `adf4159/RSET_ADF`,
`adf4159/SPI_ADF_CSN_1V8` and `lmx2595/LMX_RFOUTAP`, but loses `SPI_MOSI` and
`adf4159/LOCK_DET_1V8`, for a net gain of one. This still falls short of the
historical original first-pass count of 121 and is not a reason to merge yet.

Independent inspection of `rf-local-signal-share-project`, layout
`autorouter-local-signal-share-20260905`, confirms **119/130**, 692 physical
tracks, 372 vias and zero geometry errors. All 400 findings are included;
39 are error-severity net opens. Artifacts are `rf-local-signal-share-control*`
and `rf-local-signal-share*` under the experiment root.

## Black Canyon surface-intent audit

The saved 59/59 candidate still violates six explicit `(decouples IC PIN)`
relationships. `bypass_open` correctly ignores remote via/plane connectivity
when checking these surface paths. Missing connections are C47/C50 to U11.10
and C45/C46 to U11.1 in `ldo_5v`, plus C35 to U8.6 and C36 to U8.9 in `dsa`.
The latter two capacitors are locked on the bottom face while U8 is on top;
a same-face path is impossible without changing their placement. This is not
another global net-open problem, and the current finisher's requirement for
fewer whole-net islands cannot accept its repair on an already-connected rail.
An exact bypass-intent repair path and placement-aware diagnosis are required.

All 409 saved Black tracks are on outer copper (270 top, 139 bottom), so there
are no saved signal tracks on its declared internal ground planes. Its
remaining 148 warnings also include ground-via distance, dangling copper,
keepout and RF-bend findings. `black-bypass-intent-audit.json` records the six
missing bonds, faces and lock state. The best candidate has not been modified.


## September 6 finishing tools and review candidates

The live design library now contains a separate `autorouter-review-20260906`
layout for each board. All three flattened source netlists matched their live
counterparts before import. The importer preserved every previous saved row and
the starred layout. These are review candidates, not fabrication releases:

- `/pcb-layout/barracuda?layout=autorouter-review-20260906`: 129/130,
  no geometry errors; LOCK_DET remains open.
- `/pcb-layout/black-canyon?layout=autorouter-review-20260906`: 59/59,
  no geometry errors or missing authored bypass bonds. Independent description
  reports 446 physical tracks and 224 vias; 425 tracks are persisted (the rest
  are generated physical geometry). Warnings still require review.
- `/pcb-layout/barracuda-base?layout=autorouter-review-20260906`: preserved
  99/183 best candidate, with one hairline gap and many open nets.

`set_part_poses` now accepts `copper_scope: "local"`. The old and new component
extents, inflated for clearance, select nearby copper on moved nets. Distant
trunks and vias remain; intersecting arcs are discarded conservatively. Full-net
invalidation remains the default. The tool preserves complete saved assembly
metadata. On Black Canyon, moving dsa/C35 and dsa/C36 to the top face at
(89.6,70.5,0 degrees) and (92.0,70.5,180 degrees) dropped 13 copper objects,
versus 184 with full-net invalidation. Automatic finishing retained 59/59; the
full-net trial had regressed to 58/59 by breaking GND.

`close_open_nets` repairs exact same-face authored cap-to-hub bonds even when a
remote via path already closes their logical net. The repair obeys authored
layer restrictions and permits no new vias. Opposite-face bonds need a placement
change. Every accepted hop preserves previously completed bonds, and cleanup is
rolled back if it reopens a bond repaired during the call. Results include
`bypasses_repaired` and `bypasses_remaining`. Black Canyon's six original missing
bonds are now all closed. Evidence: `black-local-pose*.json`,
`black-local-bypass-final.json`, and `black-local-final-describe.json` under the
experiment root.

`save_pcb_layout` now accepts a named source `layout`, preserving all saved
metadata. An explicit `source_project_dir` and new `layout_name` copy an inspected
candidate into the live library through revision/history-guarded persistence.
Cross-project copying refuses an existing destination name and leaves it
unstarred. The caller must verify circuit identity before import. A regression
fixture checks the selected source, heatsink/copper preservation, collision
refusal, and the untouched destination star.

The opt-in `(pcb-plan (route (module-signals guided)))` hands ordinary generated
local signal copper to the global router as revisable guides. Default `fixed`
retains immutable seeds. Authored bypasses, supply seeds, module layer/via
restrictions, reserved lanes, caller copper, and saved fallback remain fixed.
The Base guided trial was only 4/183 and is not adopted. It exposed an existing
handoff bottleneck: a subsequent fixed trial spent 72.09 s locally, 199.48 s in
seed validation, and another 20.92 s in whole-board connectivity before global
routing. Every candidate had been repeating current solves for unrelated rails.
The new candidate-net DRC retains the complete board geometry and target rail
family, including ambiguous leaf-name demands, while omitting unrelated current
solves. The final carrier check also inspects only candidate-complete carriers.
A direct comparison fixture verifies identical target power/foreign-copper
findings against full DRC. Board measurements are recorded separately below.

The CLI editing implementation was first extracted to clear the page module's
latched size gate. During integration, upstream independently split those same
modules. The fixes now live in its `pcb_layout_mcp.zig`, `pcb_layout_seeds.zig`,
`router_gap_close.zig`, and `router_ctx.zig`; the duplicate editing module was
removed. Public page handler aliases preserve call sites. Focused editing, bypass, hierarchy, and policy tests passed (265 tests),
followed by 35 selected tests including the import and scoped DRC regressions.


The completed Base scoped-seed trial reports **79/183, zero geometry errors**,
959 tracks and 423 vias, with 361.04 seconds router wall time. It improves the
recent timeout-starved 30/183 and guided 4/183 runs, but does not exceed the saved
99/183 candidate (which has one geometry error). Its local pass took 76.81 seconds,
seed validation 26.57 seconds, and the carrier check no measurable additional
millisecond. The previous diagnostic used 72.09, 199.48, and 20.92 seconds
respectively. These are single timed trials, not deterministic speed guarantees.
The final global gate still overruns the 283-second search deadline; hard wall
bounds and higher completion remain unfinished. Evidence: `base-scoped-seeds.txt`
and `base-review-diagnostic.txt`, with accompanying logs.


The weighted RF scoped-seed run finished at **118/130**, zero geometry errors,
in 231.09 seconds (`rf-scoped-seeds.txt`). Weighted scheduling is therefore an
explicit experiment: `(module-budget weighted)` enables join-weighted local
slices and reserves a selected-signal share. The default `(module-budget equal)`
keeps the previous equal-share scheduler. `(module-signals guided)` is independently
opt-in. Neither experimental choice is enabled in the live board DSL or review
copies. Optimized seed validation, exact bypass repairs, local movement, and
candidate publishing are available regardless of those choices.


The final RF repair on the preserved 129/130 candidate repaired **11 distinct
bonds**, clearing all **12 bypass-open warnings**. It retained 129/130, zero
geometry errors, 908 saved tracks, and 432 vias, with zero missing authored
bypass bonds. The additive repair took 79.73 seconds, including validation.
The improved live layout is `autorouter-review-20260906-repaired`; the earlier
review copy remains available. Evidence: `rf-bypass-review.json` and its source
project, followed by a live independent description. The completed default
(equal-budget) fresh run was 117/130, zero geometry errors, in 218.42 seconds;
it does not replace the better finished review candidate.


## RF local fanout repair — 2026-09-06

The local-clear trial advances the preserved RF candidate from **129/130 to
130/130**, with **zero error-severity DRC findings and zero missing authored
bypass bonds**. This is a connected review candidate, not hard-constraint
acceptance: SPI_SCK has 15 total vias against the DSL's stated per-net cap of 10.
The starting layout already had 12. `close_open_nets` currently subtracts only
vias added during that invocation, so another invocation resets the allowance.
Its regression fixture explicitly enforces that narrower contract, while the
language reference calls `(max-vias N)` a hard per-net budget. Resolving this
mismatch and the remaining warnings is required before claiming completion.

The obstruction was retained copper in the west-side U13 fanout. Via-only
removal left attached stubs; whole-net removal discarded useful remote trunks.
`clear_routes` now supports `include_tracks:true` with a circular coordinate and
net/group scope. It removes whole intersecting track/arc records plus local via
centres, preserves other records and all layout metadata, and refuses partial
swept-RF clearing. Arc selection follows actual copper, not a chord or bounding
box. Existing via-only calls keep their semantics. Tests cover both arc directions,
foreign/distant copper, swept-RF refusal, invalid requests and metadata persistence.

Frozen evidence is `/tmp/autorouter-fanout-20260906`: `inputs.json` identifies
1,027 copied inputs, `project/` contains the board/library source, and the JSON
and log files record each native operation. Library `.sexp` and Barracuda source
inputs still matched the live library byte-for-byte when reviewed. The native
router executable is the verified ReleaseSafe candidate for tool commit
`517cc58b4afce0f7ff82fb2aa247b3d1f0053a3e`. Only the new clear operation needed
the feature executable; no hand-authored track was added.

The exact sequence on a native saved copy of
`autorouter-review-20260906-repaired`, named `fanout-window-1`, was:

1. Clear SPI_SCK, SPI_MOSI, SPI_ADF_CSN and V_3V3A in a 1.65 mm radius at
   (135.3, 105.35), with `include_tracks:true`: 13 tracks and four vias removed.
2. `close_open_nets` for LOCK_DET, rounds 1, 90,000 ms, no vacate or bypass
   repair: LOCK_DET closes; four deliberately displaced nets remain open.
3. Finish SPI_SCK, SPI_MOSI and SPI_ADF_CSN, rounds 2, 120,000 ms, no vacate
   or bypass repair: all three restored, only V_3V3A open.
4. Finish V_3V3A, rounds 2, 120,000 ms, no vacate, bypass repair enabled:
   130/130 and all authored bonds restored.
5. `clean_route_topology` scoped to those five nets, first dry-run then apply:
   eight tracks and one via removed, with all 130 connections preserved.

Independent `describe_pcb_layout` after cleanup reports **999 physical tracks,
966 saved tracks, 446 vias, 0 errors and 462 warnings**. The baseline has 941
physical tracks, 908 saved tracks, 432 vias and 410 warnings plus its open-net
error. Dangling-copper warnings increase from 140 to 185; the topology cleaner
conservatively excludes unsafe trace-removal candidates on SPI_SCK, V_3V3A and
SPI_ADF_CSN. This is a connectivity improvement, not a copper-quality pass.
All 225 component poses, outlines, texts, pours and saved RF paths are unchanged.
The repair is still an agent-selected local window and ordered native finishing
sequence; a single DSL-driven automatic replay remains unfinished. Barracuda Base
remains at 99/183 with one hairline gap and 26 missing bypass bonds.


## Total via-budget accounting — 2026-09-06

The connected RF candidate hid four violations of authored `(max-vias …)`
limits. Incremental finishing treated retained vias as free on each invocation;
whole-net retries and module handoff also disagreed about whether the policy
was a total or a remaining allowance. The current feature makes whole-net and
seed policies totals, and lowers gap-repair policies to the remaining allowance
once per transaction. Over-budget partial trees roll back. Plane, thermal,
escape, return-stitch, ground-pad and reference-replay passes check their total;
coupled differential legs check both members before either is committed.

`get_layout_progress` now reports `via-budget-exceeded` or
`via-budget-unverified` in the routing stage. Geometry DRC and connectivity
remain separate measurements. Standalone fence/stitch tools without a lowered
route plan still require this final saved-copper audit; these changes do not
prove every geometry-producing API enforces the plan before writing.

A native whole-net clear and automatic finish reduced RF `SPI_SCK` from 15 to
6 vias, keeping 130/130 connected and no missing bypass bonds. The published
candidate is `autorouter-review-20260906-via-budget`: 1017 physical tracks,
439 vias, zero geometry errors and 461 warnings. It has 988 persisted tracks;
the physical report includes derived copper. This experiment used verified
`b21f82ad`, starting SCK with zero vias, so its ten-new-via allowance was also
the total allowance. It is not a fresh full-board run of this feature engine.

The new progress audit reports 127/130 routing requirements satisfied:
`V_24V_CLEAN` has 4 vias against 2, `SPI_LMX_CSN` 5 against 3, and `V_1V8A`
8 against 4. A separate chip-select clear/finish trial kept zero of one hop
and reported a policy refusal; it remains an isolated 129/130 candidate.
No authored limits were relaxed. Frozen experiment files and reports are in
`/tmp/autorouter-via-budget-20260906`.

A guided-repair fixture also exposed a separate limitation: the ordinary
router can prune a retained isolated via, and the guided acceptance gate then
rejects the candidate because frozen copper changed. The budget changes do
not resolve that preservation/cleanup disagreement. Next work must improve
constrained RF repair and close Base's remaining 84 nets and geometry error,
then verify all three boards against the authored constraints and warnings.


### Via-budget release status

Feature commits `64aaf72a` and `cd5e0663` are isolated on
`codex/route-via-budget`. The full test suite and ReleaseSafe build passed at
`cd5e0663` (137 s and 136 s). Release preparation then failed all three Canvas
zoom timing attempts: zoom-in p95 was 57.2, 45.6 and 65.2 ms against 45 ms;
the first attempt also missed the zoom-out limit. Renderer assets and the
browser harness are unchanged by this feature, but deployment remains blocked
until the required gate passes. No merge or production restart was performed.
The isolated build and full logs remain in
`.git/release-failures/cd5e0663cbec8e43f654d4c2c8c084b965faffb1-20260906-073303-3685575`.
The saved RF candidate remains reviewable in the running server; its new
routing-progress check is available in the isolated feature build.


## Searching within a nonzero via allowance — 2026-09-06

A complete cheapest path could exceed a via limit even when a longer legal
path existed. Whole-net routing previously retried with no vias at all; gap
repair rejected the candidate. Both now try two bounded increases to the
layer-change cost before refusing the connection. Whole-net routing retains
its zero-via fallback. The added cost is outside corridor discounts and also
reaches the shape rescue. Every accepted path still passes its hard layer and
via policy; retries restore pricing and roll back rejected copper. These are
bounded searches, not an exhaustive proof that no feasible path exists.

The regression fixture forces three vias on the ordinary shortest path and
one on a longer valid detour. It failed before this change and passes for both
gap and whole-net routing afterward; the new copper also passes geometry DRC.
The focused via/policy suite and full-shard inventory passed 311 tests.

On frozen Barracuda RF copper, native automatic finishing now closes
`SPI_LMX_CSN` with three vias instead of five, meeting its authored limit.
The path grows from 43.4 to 44.7 mm. Independent inspection with the previously
verified ReleaseSafe executable reports 130/130 connected, 1015 physical tracks,
437 vias, zero geometry errors, 461 warnings and no missing bypass bonds.
The saved candidate has 982 persisted tracks; derived copper explains the
physical total. The feature progress check improves from 127/130 to 128/130:
`V_24V_CLEAN` remains at four vias against two and `V_1V8A` at eight against four.
An isolated clear/repair trial of the 24 V rail left it open and was not promoted.
No authored limit was relaxed.

Review candidate: `autorouter-review-20260906-via-search`. The named snapshot
was imported through the native save tool after all 1005 frozen library/board
source files matched the live project; the existing starred layout is retained.
Evidence, the working-source patch and Debug executable SHA-256 are in
`/tmp/autorouter-via-search-20260906`. This is an incremental repair experiment,
not a fresh full-board run. Release verification of the combined branch follows
this change; the earlier release failure above applies to its earlier commit.


## Sharing power vias through surface island joins — 2026-09-06

Finishing could exhaust a power rail's via allowance by independently stitching
each disconnected pad island before trying to join them on a surface. Its first
round now compares planned stitches against the remaining authored total. When
that allowance is insufficient, it first tries the oracle's island joins on a
shared pad face, without new vias or copper rip-up. Later rounds retain ordinary
stitching and multilayer bridges. Ordinary and wholesale finishing share the
planner. An unconstrained rail or one with enough allowance keeps the prior order.

The surface-only constraint follows fine and boundary retries, respects the raw
authored layer mask rather than borrowing terminal-escape exceptions, and resets
before a later ordinary hop. Its failed-hop memo entry is separate from the
ordinary bridge's entry. The regression that previously planned two stitches
with only one via available now joins the two pads without a via and verifies
connectivity and geometry. The 96 focused finishing/policy tests also cover
layer restrictions, state restoration and eligibility of later fallbacks.

On the frozen RF candidate, native clear/finish of `V_1V8A` now joins five pad
island pairs without vias, then completes two ordinary bridges. Independent
inspection with verified ReleaseSafe `2428ef3ad` confirms **130/130 connected,
987 physical tracks, 433 vias, zero geometry errors and 439 warnings**, with no
missing bypass bonds. `V_1V8A` falls from eight vias to its authored four and
increases from 41.8 to 43.1 mm. The candidate has 954 persisted tracks. Compared
with the preceding published candidate, dangling-copper warnings fall by 20 and
single-layer-via warnings by two. Feature routing progress reaches **129/130**;
`V_24V_CLEAN` is the remaining via violation (four against two).

The Debug finishing call reached its time limit after connecting all pads, so
optional cleanup was skipped. Its final saved-copper inspection, rather than
the timeout flag or intermediate mutation counts, establishes the result. The
same-budget previous ReleaseSafe finishing attempt remained 129/130 connected;
these mixed-build timings are not a performance comparison. No hand copper was
added and no authored limit changed. The 24 V surface joins remained blocked;
its separate trial is not the review candidate.

Frozen candidate: `power-islands-v1v8-1` in
`/tmp/autorouter-fanout-20260906/project`. Evidence, the exact working-source
patch and Debug executable hash are in `/tmp/autorouter-power-vias-20260906`.
Release verification and promotion follow the implementation; the broader goal
still includes Base's open nets, the RF 24 V constraint, power-model gaps and
warning review on all boards.
