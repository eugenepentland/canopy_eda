# A whole-board autorouter for netlisp

**Status:** proposal. Nothing here is built.
**Written:** 2026-07-26, from the measurements in the barracuda 87/90 effort.

> **Current execution policy:** implement and evaluate this proposal with the
> pinned self-hosted Debug build. Sections labelled ReleaseSafe preserve old
> observations only; do not reproduce them with a new internal ReleaseSafe
> build. Deployment is the sole ReleaseSafe boundary.

This document exists because the current router is a good *local* router and we
keep asking it to be a global one. Every attempt to close barracuda's last three
nets failed for the same structural reason, and that reason is worth writing
down properly before anyone spends another week on it.

The goal is not "route barracuda". It is to make the autorouter a capability we
trust on **every future board**, so the normal path to a fabbable PCB is
`route_pcb` plus a short hand-finish, not a multi-day agent session per board.

---

## 1. Where we actually are

`src/placement/router.zig` is a grid maze router with a good deal of real
engineering in it: per-net classes, exact-clearance move validation, pour-aware
connectivity, a rip-up ladder, a CDT rescue tier, and a finishing pass
(`close_open_nets`) that closes gaps a whole-board run left open.

On barracuda it reaches **87 of 90 routable nets** with 11 DRC findings (8
error-severity). That is a real result and it is *close*. But the last three
nets have resisted seven distinct mechanisms, and the failure is not a bug.

### What has been tried and disproved

Recording this is the single most valuable part of this document: each of these
cost hours, and every one of them is a plausible-sounding idea a future reader
will think of again.

| Hypothesis | Mechanism built | Measured outcome |
|---|---|---|
| Grid too coarse to see the channel | fine-grid rung (`GapOptions.grid_divisor`, divisor-4 retry) | **Merged.** Real fix — both stuck seeds now route. Board unchanged at 87. |
| Escape via banned at the pad | `TerminalVia.smd_ok` policy | **Merged.** Makes the escape reachable at all. |
| Hard nets starved by easy ones | route the 3 stuck nets first, on an empty board | **Disproved.** Closed **zero**. They fail with first pick of the board. |
| Ordering / congestion pricing | `negotiated-congestion` phase (PathFinder-style history costs) | **Disproved.** 83/90 — *worse* than doing nothing. |
| Gridless rescue for off-grid escapes | `cdt-router` (CDT + funnel) | **Disproved.** Engine correct; declines cleanly — the nets are not resolution-blocked. |
| Transaction discards good work | restore a displaced net's original copper | **No effect.** The old copper no longer fits. |
| Nets race for the escape corridor | simultaneous multi-net escape assignment | Lands DRC-clean. **Closes no net.** |
| Greedy site choice blocks a neighbour | joint constraint solve (backtracking over site combinations) | **Same 1-of-2 as greedy** ⇒ not a search problem. |
| Specific copper occupies the escape | targeted rip of the escape envelope | **Frees it — the net routes in 115 ms** — but the displaced net cannot re-close. |
| Neighbourhood is over-committed | global neighbourhood re-route (empty 8 nearby nets, re-solve together) | Escape assignment goes 1 → **4 nets**; `SPI_SCK` routes **all three hops**; still rolls back. |
| Escapes are taken back by later nets | **reserved escape lanes** — `router.EscapeLane` held in `ctx.resv`, re-stamped every hop | **No effect** — see the correction in §5. This was stage 1's core idea. |

### The finding that matters

The global re-route was run both ways, and that settles it:

| region policy | the stuck net | the displaced net |
|---|---|---|
| **strip** board-spanning nets | `SPI_SCK` routes all 3 hops | `SPI_MOSI` cannot re-close 20 mm outside the cleared region |
| **keep** board-spanning nets | `SPI_SCK` blocks | — |

**The space the last nets need is held by a net that spans the board.** Freeing
it obliges re-routing that net globally; sparing it means the stuck net cannot
route at all. No local transaction satisfies both directions — which is exactly
why seven local mechanisms produced seven identical results.

The reference 90/90 solution (a Python driver against our own MCP surface) did
not have a better algorithm. It re-solved **82 tracks across 6 nets at once**,
from a different starting arrangement. Its route does not transplant onto our
board: grafting it produces DRC 37/34 against three of our nets. It is a
*different global solution*, not a patch we failed to find.

---

## 2. What "whole-board" has to mean

The current architecture routes each net against the copper standing at that
moment, and repairs locally when that fails. A product router inverts this: it
treats the board as one optimisation over all nets, and expects to move copper
that is already placed.

Three properties the current design lacks:

1. **Ripping is normal, not exceptional.** Today a rip is a recovery step
   bounded by `ripup_max_nets` / `max_repair_rip_depth`, and a repair that fails
   discards the whole transaction. In a rip-up-and-reroute router, tearing out
   200 tracks and re-laying them is a *routine iteration*, not a failure path.
2. **Illegal intermediate states are allowed.** Our accept gate refuses any hop
   that raises the DRC count. That makes each step safe and the search myopic:
   the only way through many boards is a temporarily-overlapping arrangement
   that later iterations resolve. Negotiated congestion depends on this and our
   attempt did not permit it — which is a plausible reason it scored 83.
3. **Convergence is measured over the board, not the hop.** Success is "fewer
   unrouted nets and less overlap than the last iteration", evaluated globally,
   with the freedom to accept a worse single net for a better whole.

### The algorithm

PathFinder-style negotiated congestion, properly implemented:

```
route every net ignoring congestion (overlaps allowed)
repeat until no overlaps, or iteration budget spent:
    for each net, in a priority order:
        rip its current route
        re-route it on a cost surface where each cell costs
            base × (1 + present_penalty × current_occupancy)
                 × (1 + history_penalty accumulated over past iterations)
    raise present_penalty
    accumulate history on cells that stayed contested
```

The two penalties do different jobs. **Present** cost makes nets avoid each
other now; **history** cost remembers which regions were persistently fought
over and pushes nets away from them in *later* iterations — that is what lets
the router discover that a whole subsystem should route around a congested
corridor rather than through it. Our `negotiated-congestion` branch had the
shape but ran inside the existing DRC-gated transaction model, so it could never
pass through the illegal intermediate states the method needs.

### Escape/fanout as a first-class phase

The barracuda failure is specifically an **escape routing** problem: N signals
leaving one fine-pitch connector row where the inter-pad lane (0.280 mm) is
narrower than a track plus two clearances (0.381 mm), so the only exit is a via
at the pad. This is a well-studied sub-problem with its own literature, and it
must run **before** general routing, not as a rescue:

1. detect sealed rows (pitch vs `track + 2·clearance`) — already built in
   `src/placement/escape_group.zig` (that module is worth resurrecting: it
   detects, measures, and proves the seal correctly; it was only ever wired into
   a local phase, which is what made it useless)
2. assign every pad on the row a via site and an escape lane **together**,
   respecting planarity (escapes must fan out in pad order or they cross)
3. reserve those lanes so the general router cannot consume them
4. route the rest of the board around a solved fanout

Step 3 is the one we never had. Every mechanism this session assigned escapes
and then let the general router take the space back.

---

## 3. Why this is worth building

Not for barracuda. For the boards after it.

- Every board with a fine-pitch connector or BGA has this exact problem. It is
  not a barracuda quirk; barracuda just found it first.
- The current failure mode is expensive in the worst way: the router reports
  "87/90" and a human has to discover *which* three and *why*, then hand-route.
  A router that either finishes or explains its failure in board terms turns a
  multi-hour investigation into a decision.
- The measurement infrastructure now exists (connectivity oracle, DRC, fab
  gate, `describe_pcb_layout`), so a new engine can be evaluated honestly from
  day one instead of tuned against a single board.

---

## 4. How we will know it works — build this first

**The single biggest risk is tuning to barracuda.** Seven mechanisms this
session were evaluated on one board, and at least two (the DRC error budget, the
multi-net rip tier) looked reasonable and turned out to be net-negative *on the
same board they were designed against*. A one-board benchmark cannot detect
that.

Before any router work, build the harness:

- **Corpus.** Every design in `projects/designs/src/boards/` plus deliberately
  hard synthetic cases (a BGA fanout, a two-connector board, a dense mixed
  analog/digital board). Ten or more boards, not one.
- **Per-board record**, stored via the existing `[benchmark]` ledger so results
  are durable repo state rather than session notes: routed/total, DRC by
  severity, total trace length, via count, wall-clock.
- **The gate is the geomean across the corpus**, plus a hard rule that no board
  regresses by more than one net. This is what makes "is this change good?" a
  question with an answer.
- **Baseline the current engine on the whole corpus before writing a line of the
  new one.** We do not have this today, which is why "the router got better" has
  never been a checkable claim.

A change that improves barracuda and costs two nets elsewhere must be visibly
rejected by this harness. If the harness cannot express that, it is not finished.

---

## 5. Staging

Each stage is independently valuable and independently abandonable. Do not start
stage 3 before stage 0 is honest.

| Stage | Work | Done when |
|---|---|---|
| **0** | Benchmark harness + corpus + current-engine baseline in `[benchmark]` | One command prints a per-board table and a geomean; today's engine is recorded |
| **1** | Escape/fanout phase: detect sealed rows, assign vias + lanes jointly with planarity, **reserve the lanes** | Fanout survives a full route; barracuda's J1 row escapes without hand help |
| **2** | Negotiated-congestion core: overlap-permitting cost surface, present + history penalties, whole-board iteration | Converges to zero overlap on ≥8 corpus boards; beats baseline on geomean |
| **3** | Integration: replace the whole-board pass, keep `close_open_nets` as the finisher, keep the CDT tier as a rescue | Corpus geomean improves, no board regresses >1 net |
| **4** | Quality: length matching, layer-pair discipline, via minimisation, diff-pair coupling through the new core | Existing RF/diff-pair checks stay green across the corpus |

> **Correction (2026-07-26, same day).** An earlier draft claimed stages 0+1
> would likely have closed barracuda, reasoning that reserved lanes were the
> missing piece. **That was tested and is false.** `router.EscapeLane` was
> implemented — a corridor held in `ctx.resv`, re-stamped on every hop so it
> survives the per-hop board reset, generated for each escape the assignment
> places. Barracuda measured **87/90, hops kept 0**: unchanged. Reserving the
> lane does not help, because the escaped net's problem is not that its corridor
> gets taken — it is that the net it must reach lies beyond copper a whole-board
> solve has already committed. Stage 1 is still worth building (fanout is a real
> sub-problem every fine-pitch board hits), but **do not sell it as the cheap
> path to a stuck board.** Only stage 2 addresses the measured cause.

Stages 0 and 1 remain the right *starting* point — a harness you can trust and a
fanout phase are prerequisites for evaluating stage 2 at all — but do them for
those reasons, not expecting them to close boards on their own.

---

## 6. Cost, honestly

Stage 0: days. Stage 1: one to two weeks. Stage 2: the real project — a
correctly-implemented negotiated-congestion router with the convergence
behaviour above is weeks of work and is where the existing attempt already
failed once. Stages 3–4: comparable again.

This should be scoped as a deliberate product investment, not started from the
momentum of a stuck board. The alternative for any individual board remains
cheap and is not embarrassing: route what routes, then hand-finish the
remainder with `add_tracks` or the ✎ Draw tool.

And for barracuda specifically there is a better fix than any of this: **the J1
pin assignment puts six SPI signals on one 0.63 mm row.** Swapping two pins so
they do not all escape the same corridor is a schematic change that removes the
problem rather than solving it. A router that is smart enough to route a bad
fanout is worth having; a fanout that does not need one is worth more.

---

## 7. What actually closed barracuda — and what it says about §1–§6

**Correction (2026-07-26, later the same day). The J1 corridor was not the
wall.** That diagnosis came from an attribution bug (fixed in `c68c067`: a
`hole_hole` finding named an SMD pad that has no drill), and every conclusion
that rested on it — including the last paragraph of §6 — was wrong. Once the
reports named the right copper, the board went 88 → **90/90 in one afternoon**,
with **zero** new DRC findings: the list is identical, entry for entry, to the
88/90 board's.

The remaining two nets had nothing in common with "six SPI signals fight for one
corridor". They failed for the same small, local reason:

| net | orphan | why the router missed it |
|---|---|---|
| `GND` | one pad — `buck_6v/U22.3`, the buck's 1.32 × 1.72 mm thermal pad | it aimed at the pad **centre** (182.012, 92.913), which sits 0.063 mm from the `FB` pad and needs 0.327 — while a site 0.66 mm lower **inside the same pad** clears everything by 0.417 mm |
| `SPI_SCK` | one pad — `lmx2595/U17.16`, mid-row on a 0.5 mm-pitch QFN edge | 9 of the row's 10 pads had escaped; the lane between neighbours is 0.200 mm against the 0.404 mm a track needs, so the only exit is a via at the pad's free **tip**, again not its centre |

Both are one bug: **the escape via has a legal site inside the pad, but not at
the pad's anchor point, and the terminal-via search only ever tries the anchor.**
Every buck, LDO and QFN thermal pad on every future board has this geometry, so
this is worth more than anything in §5 — and it is days of work, not weeks.

Two further findings, both about *reports* rather than routing:

- **`add_tracks` rolled back every hand route's first step.** The gate counted
  `net_open` as a fab error, so an escape stub that leaves a sealed pad and
  lands on fresh copper — geometrically perfect, zero clearance findings — was
  undone because the net stayed open until the run finished. Hand routing was
  therefore impossible in practice while appearing to be supported. Fixed in
  `5eae965`: the gate counts geometry only, connectivity is already reported as
  `routed`/`total`/`open`.
- **The focus PNG draws a ratsnest airwire whether or not the net is routed.**
  A fully-routed `SPI_MOSI` renders the same yellow pad-to-pad line as an open
  `SPI_SCK`, so the picture cannot be used to tell routed from open. Trust
  `describe_pcb_layout`; the render should skip airwires for pad pairs copper
  already joins.

The 23 mm cross-board leg itself was closed by an **offline two-layer A\*** run
against the exact geometry `describe_pcb_layout` reports and submitted through
`add_tracks` — about 120 lines of throwaway Python, no engine change. Its
clearance model predicted the engine's DRC exactly on all three submissions.
That is the doctrine working as intended: **the engine reports precisely, and
the caller does the problem-solving.** It is also a measurement of how much
router is actually missing — an afternoon's script, not a negotiated-congestion
core, was the difference between 88 and 90.

**So the honest revision to §5's staging:** stage 2 is still the right answer
for boards that are genuinely congested, but barracuda was never evidence for
it. Do the terminal-via landing-point search first. It is cheap, it generalises,
and it is the fix the measurements actually point at.

---

## 8. The terminal-exit fixes, measured

§7 said the next thing to build was the terminal-via landing-point search. It
was built, and this is what it bought (barracuda, from the 88/90 board, engine
only — no hand copper):

| change | effect |
|---|---|
| **`pad_exit.interior`** — leave a terminal from the clearest point INSIDE its pad, not the pad's centre | `GND` closes on its own. 88 → **89/90**, DRC unchanged. The buck's thermal-pad stitch via now lands in the pad's free half instead of 0.063 mm from the `FB` pad. |
| **`pad_exit.boardHoles`** — count already-routed via drills, not only pad drills, in the gap pass's via-ban mask | Removed the `hole_hole` rejections that were killing `SPI_SCK`'s last rung: the maze was dropping barrels 0.2008 mm from existing vias against a 0.2 mm wall. |
| **`Work.fineDirect`** — re-ask a hop every rip tier refused once on the divisor-4 raster with **no rip**, and report that rung's diagnosis | Closes `SPI_SCK`'s hop inside a vacate transaction, and makes the reported failure the one with the most board to work with. |

### What still needs a hand and why

`SPI_SCK` does not close from the engine. Its failure is now precisely stated:
its legal way round is ~35 mm with tightest points clearing by 0.07–0.20 mm, and
**the divisor-4 lattice (~0.11 mm pitch) cannot put a centreline on them** — the
hop returns `no_path` from a board that demonstrably has a path.

A divisor-8 rung was built and **measured, then removed**: it ran for over 50
minutes on a two-net request without returning. Each rung costs 4x the nodes of
the one before, and a finishing pass that takes an hour is not a finishing pass.
Do not re-add it without a way to bound the search region first — the natural
one is to solve inside a corridor around the failed hop rather than the board.

The 35 mm route was produced instead by an **offline two-layer A\*** at 0.05 mm
against the geometry `describe_pcb_layout` reports, submitted through
`add_tracks`; the board finishes at **90/90 with zero new DRC** — its findings
list is identical, entry for entry, to the 88/90 board's. That script is ~120
lines and its clearance model predicted the engine's DRC exactly on every
submission, which is the useful measurement here: what the router is missing on
this board is *resolution inside a bounded region*, not a better algorithm.

### Historical measurement (barracuda, ReleaseSafe, fresh whole-board route)

Two independent runs, identical to the digit:

| | before | after |
|---|---:|---:|
| routed, connectivity oracle | **77/90** | **83/90** |
| routed, router's own claim | 85/90 | 85 (now reported as `router_claimed`) |
| DRC total / error-severity | 28 / 14 | **28 / 14** |
| tracks / vias | 624 / 92 | 683 / 131 |
| copper | 971.3 mm | 994.7 mm |
| wall clock | 108 s | **109 s** |

**Six nets for one second, at zero DRC cost.** `GND` picked up 37 stitching vias
and left the open list entirely; `buck_6v/FB`, `boost22/BOOST22_SW`, `CP_FILT`,
`V_22V`, `V_5VA` and `V_6VA` all closed. The seven still open are the five the
router itself reports failed — correctly deferred to the finishing pass — plus
`V_1V8A` and `V_12V`, which it claimed and the gate could not close. That pair
is exactly the `85 − 83` the new `router_claimed` field makes visible, so the
residual over-count is now a number on the board rather than a silent one.

### A verification trap worth recording

The first full-suite run after this wave reported a failure in
`serve.vfs.test.dirtyDesignsForPath resolves a nested src design to its
basename` — a test whose function is provably deterministic for its input, so it
could not produce the reported value. **Zig's parallel test runner had printed
one test's assertion failure under a different test's name.** The real failure
was a new test in this wave, whose fixture put one pad on two nets.

Two lessons, both cheap to apply next time:

- When a named test *cannot* produce the value reported, suspect the runner's
  attribution before the test.
- `-Dtest-filter` matches the FULL test name including the module path, so
  `-Dtest-filter=route-close` (hyphen) never matches `placement.route_close.*`
  (underscore). Several "green" filtered runs in this wave never executed the
  new tests at all. Filter on the module path spelling, and check the reported
  test COUNT against what you expect to run.

### What the corpus found on its first run

The harness earned its keep immediately, and not by scoring the router. Of seven
top-level boards, only **barracuda**, **straps** and **adf5901** route anything
at all; `barracuda-base`, `rf-switch-8way`, `labstation` and `straps-base` return
0 nets and 0 tracks in about a quarter-second each — they have **no saved
layout**, so `solveForRequest` falls back to a fresh solve or a plain grid whose
parts commonly overlap (labstation's fallback reports 997 DRC errors with no
copper at all). That is not a routing measurement, and it is not stable across
commits either.

Scored naively, those four boards pinned the corpus geomean at **0.0004**, which
would have hidden every real change the metric exists to expose. The harness now
marks a board whose placement did not come verbatim from a saved snapshot and
keeps it OUT of the score while still printing its row — so the number means
"how well does the router do on boards we have actually placed", and the table
still shows what is missing.

**Follow-up for the corpus itself, not the router:** those four designs need
blessed layouts before they can contribute. Until then the corpus is effectively
three boards, which is thinner than §4 asked for — worth remembering before
trusting a geomean delta as evidence.

### Re-measured after merging main (the numbers that matter)

Main moved while this wave was in flight, and two of its commits overlap it:
`11cc579` made `/api/pcb-describe` report the oracle tally (the same defect this
wave diagnosed, fixed on the reporting side only), and `ddb2ab5` cut the
`track↔pad` errors from 8 to 2 by probing every copper emit. The pre-merge
table above is therefore against a superseded base. Against **main `3c26ad5`**,
on the same starred layout:

| | main alone | main + this branch |
|---|---:|---:|
| routed (oracle) | 78/90 | **83/90** |
| `track↔pad` errors | 2 | **2** |
| `net open` errors | 59 | **15** |
| DRC total / error-severity | 76 / 61 | **32 / 17** |
| tracks / vias | 623 / 91 | 684 / 132 |
| wall clock | 104 s | 106 s |

**Five nets for two seconds, with geometry DRC held exactly.** The 44 fewer
`net open` markers are not a copper-quality change — they are the airwire
markers of the five nets that are no longer open. Read the two error kinds
separately: `track↔pad` measures the copper, `net open` counts which nets are
still unfinished, and only the first is a statement about routing quality.
