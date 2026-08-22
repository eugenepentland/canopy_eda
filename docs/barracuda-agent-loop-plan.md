# Barracuda 90/90: a fast engine with an AI agent tweaking the DSL

*2026-07-27. Goal, stated by Eugene: complete the barracuda RF board with a
FAST autorouter and an AI agent in the loop that directs it through the DSL —
no rip-up/retry ladders grinding inside the engine. This document is the plan
to get there, with the measured history that justifies each step.*

> **Current execution policy (2026-08-12):** run the agent loop, dev server,
> router experiments, and benchmarks with pinned-master self-hosted Debug.
> ReleaseSafe timings in this plan are historical targets; deployment alone
> creates the current ReleaseSafe application.

---

## 1. The premise, checked against the record

The proposal is: strip the retry machinery out of the hot path; the router
becomes a fast, deterministic executor of what the DSL says; the agent iterates
by editing the DSL and, for the last mile, by issuing targeted writes.

The record supports this more strongly than intuition suggests:

- **Rip-up bought almost nothing here.** Universal rip-up eligibility: +0 nets.
  The multi-net rip tier and repair cascade were *net-negative* — disabling
  them closed `TXDATA_ADF`. Failed hops burn 2–60 s each proving the
  impossible against escalation budgets; `memoStale` re-asks were measured at
  20% of a whole finishing pass.
- **The DSL did the real lifting.** Waves, priorities, guides and net classes
  took the one-shot from 78 to 87. The ordering cluster (`SPI_MOSI`,
  `SPI_ADF_CSN`, `SPI_ADF_SDI_1V8`, `LOCK_DET`, `V_1V8A`) was closed by
  *authored order*, not by any rescue mechanism.
- **Directed writes finished it, twice.** Both 90/90 boards in designs-repo git
  (`hand-90` at `22e24f4`, `engine-90` at `17ca778`) got their last nets from
  an agent reading precise facts and placing precise copper — not from an
  engine mechanism.

So the steady state we should build for is: **fast route lands ~85+, the agent
closes the tail in a few directed moves, each loop iteration takes seconds.**

## 2. Why DSL iteration did NOT reach 90/90 before — the honest diagnosis

The board is hand-routable (Eugene routed it; `hand-90` and the KiCad reference
both close all 90 nets). So "the DSL can't get there" was never a statement
about the board or about the DSL in principle. It localizes to three specific
deficiencies, and they define the workstreams below:

1. **Lattice resolution (engine).** A hand places exact geometry; the maze
   places centerlines on a grid. `SPI_SCK`'s legal ~35 mm detour clears
   obstacles by 0.07–0.20 mm, and the router's ~0.11 mm divisor-4 pitch
   provably cannot put a centerline on it — an offline A* at 0.05 mm found the
   path immediately, and its clearance model predicted the engine's DRC exactly.
   **No DSL text can fix a path the raster cannot represent.** (The earlier
   "six SPI nets fight one J1 corridor" theory was retracted — it rested on a
   DRC attribution bug. The real residue was resolution plus terminal-exit
   bugs; fixing the terminal bugs alone closed `GND`.)
2. **Guides are soft (engine + DSL).** `(waypoints …)` and `(guides …)` are
   hints: when the guided copper fails validation the router silently falls
   back to a plain maze, and first-routed-wins lets earlier waves consume the
   channel an agent's program depended on. The DSL has no way to say "this
   channel belongs to this net — reserve it or tell me why you can't."
3. **The loop was un-iterable (ergonomics).** ~2 minutes per iteration, minutes
   more in rescue ladders, run-to-run variance (the same DSL produced 70/90 and
   77/90 on different runs), and — until the oracle gate merged — a `routed`
   count that overstated reality. An agent cannot converge on a noisy, slow,
   dishonest loop, and neither could a human.

Items already fixed (merged 2026-07-27): the oracle gate makes every surface
report real connectivity and closes phantom micro-gaps (+5 nets vs main alone,
geometry DRC held); corridor-bounded fine rasters exist in the gap pass
(`GapWindow`); `bench-route` gives a corpus scoreboard; `close_open_nets`
failures carry remedies.

## 3. Target architecture

```
        ┌──────────────────────────────────────────────────────┐
        │                  AGENT LOOP (seconds)                │
        │                                                      │
   .sexp DSL ──► route (one-shot, fail-fast, deterministic)    │
        ▲              │                                       │
        │              ▼                                       │
        │        describe: oracle routed/total, open_nets[],   │
        │        stuck[] with DSL remedies, per-wave timing    │
        │              │                                       │
        │        agent decides:                                │
        ├── edit DSL (waves/priorities/corridors/resolution)   │
        ├── targeted write (clear_routes + scoped route)       │
        └── last mile (add_tracks), verify with oracle, save   │
        └──────────────────────────────────────────────────────┘
```

- The engine does ONE pass, honestly, fast. Anything it cannot route fails in
  milliseconds with a precise reason, not after a minutes-long rescue ladder.
- `close_open_nets` stops being an automatic escalation ladder and becomes one
  of the agent's tools, invoked when the agent judges it useful.
- The DSL gains the vocabulary the agent actually needed and lacked: hard
  channel reservations and per-net resolution.

## 4. Workstreams

### W1 — `(effort …)`: retry becomes a DSL knob, fail-fast becomes the default

Add `(pcb-plan (route (effort one-shot|standard)))`:

- `one-shot`: no rip-up rounds, no escalated re-search of failed nets, no
  whole-board fine retry. A net that fails, fails immediately and lands in
  `stuck[]` with its diagnosis. This is the agent-loop default.
- `standard`: today's behaviour, kept as the escape hatch and for boards nobody
  is iterating on.

Where: `route_policy.Options` + the pass loop in `src/placement/router.zig`
(`ripup_rounds`, `escalateSearchLimited`, `fineWindowRescue` gating);
lowering in `src/serve/route_plan.zig`.

**Accept:** rebaseline and compare barracuda one-shot wall clock with the
self-hosted Debug build (`~60 s ReleaseSafe` from `106 s` is historical only);
`bench-route` corpus table for both efforts recorded in the ledger; no
board loses more than 1 net in `one-shot` vs `standard` without that trade
being written down in the ledger note.

### W2 — fine resolution where the DSL asks for it (the SPI_SCK fix)

The corridor-bounded fine raster exists (`GapWindow`, merged) but only the gap
closer uses it. Expose it to the main route, DSL-directed:

    (net-class "spi-tight" (width 0.127) (resolution 0.05) (nets "SPI_SCK" …))

A net whose class carries `(resolution …)` routes its legs inside a
corridor-bounded window at that pitch (reusing `windowCtx` — bounded region is
what makes 0.05 mm affordable; board-wide divisor-8 measured 50+ min and was
removed). The hand route is the feasibility oracle for acceptance — never
copied, only proving the corridor exists.

**Accept:** on a fresh board, `SPI_SCK` routes from DSL alone — the exact net
the offline A* had to close by hand. Wall-clock cost only on nets that declare
it.

### W3 — hard corridors: `(corridor …)`, and guides that refuse instead of fall back

Two halves:

1. **Reservation.** `(route (wave … (corridor "SPI_SCK" (via 187.3 109.3) …)))`
   (or the relative-guide spellings) reserves the named channel in `ctx.resv`
   *before any wave routes*, so an earlier wave cannot consume it. The
   `EscapeLane` re-stamping machinery from the escape-assignment work is the
   prior art for keeping a reservation alive.
2. **No silent fallback.** A guided net either follows its guide or FAILS with
   `guide_unroutable` naming the first blocked segment and the copper in the
   way. Falling back to a plain maze made agent waypoint programs
   non-deterministic in effect — the agent wrote a constraint and the router
   quietly ignored it. An error the agent can read beats a guess it can't see.

**Accept:** a wave with a corridor either produces copper inside the corridor
or a structured failure naming the blocker; a fixture proves an earlier wave
cannot take a reserved channel.

### W4 — determinism: same DSL, same board

The agent's edits only have stable meaning if the route is a pure function of
(.sexp, placement). Today two fresh routes of the same inputs differed by 7
nets (70 vs 77 oracle). Find and pin the variance source (iteration order over
hash maps is the usual suspect), then enforce it with a fixture: route
barracuda twice in-process, assert byte-identical copper.

**Accept:** the double-route fixture passes on the corpus; any deliberate
nondeterminism left is named in the doc.

### W5 — loop ergonomics: make an iteration cost seconds, not minutes

- Scoped re-route already exists (`route_pcb` with `nets`/`groups` +
  `selected_only`) and now goes through the oracle gate. Measure and record a
  target: re-routing a 6-net cluster in ≤10 s.
- Add per-wave timing + per-net wall time to the route result so the agent
  sees WHERE the time went and can spot a net that is about to become a
  problem before it fails.
- `stuck[]` remedies already speak DSL; extend them to name the new vocabulary
  (`resolution`, `corridor`, `effort`) so the loop closes: every failure names
  the DSL edit that addresses it.

**Accept:** an agent transcript closing a 3-net tail in under 2 minutes of
wall clock, all through MCP.

### W6 — prove it on barracuda, end to end

Run the loop on a sandbox copy until `(pcb-plan …)` + the checked-in net
classes yield **90/90 by the oracle, one-shot, reproducibly** (W4 makes
"reproducibly" meaningful). Expected shape of the final DSL program, from the
measured failure classes:

| nets | expected closing move |
|---|---|
| `V_6VA`, `V_12V`, `V_1V8A` (pour-fed rails) | stitch fixes already merged + wave order; else one `close_open_nets` invocation |
| `adf4159/REFIN_1V8`, `ADF_CE` | wave order (they close in some runs today — W4 pins which) |
| `TXDATA_ADF`, `SPI_LMX_CSN` | corridor reservations (W3) |
| `SPI_SCK` | `(resolution 0.05)` class (W2) |

If a net genuinely cannot close from DSL after W2+W3, the fallback is explicit
agent copper via `add_tracks` — recorded in the design as a known hand-finish,
not silently absorbed. Then: save as the starred layout, re-star, record the
final numbers in the ledger.

**Accept:** `barracuda.sexp` in designs-repo git routes 90/90 one-shot; the
starred layout is that route; `bench-route` shows it.

### W7 — every change gated by the corpus

`bench-route` + the `[benchmark]` ledger run before/after each workstream.
Standing caveat recorded on 2026-07-27: only 3 of 7 boards are scorable
(4 lack blessed layouts; `labstation` routes 0/189 at its saved placement with
997 DRC errors — almost certainly a placement bug worth its own look). Blessing
those layouts widens the corpus and is cheap; until then, treat geomean deltas
as three-board evidence.

## 5. What we deliberately stop doing

- **No more local rescue mechanisms in the engine.** Seven were built and
  measured (escape assignment, joint site solve, targeted envelope rip, global
  neighbourhood re-route, negotiated congestion, copper restore, vacate) — all
  terminated at the same count. That effort now goes into W2/W3 vocabulary.
- **No automatic rip-up in the agent-loop path.** Clearing copper is an agent
  decision (`clear_routes` + scoped route), visible and reversible, not an
  engine gamble.
- **No seeding from saved copper.** Unchanged standing decision (2026-07-24):
  the hand route is a feasibility oracle, never an input.

## 6. Sequencing and rough effort

| order | work | size | why this order |
|---|---|---|---|
| 1 | W1 effort knob + fail-fast | small (1 session) | everything else iterates on top of a fast loop |
| 2 | W4 determinism | small-medium | agent edits need stable meaning before tuning the DSL |
| 3 | W2 per-net resolution | medium | closes the one net no DSL text can reach today |
| 4 | W3 corridors + hard guides | medium | the last vocabulary gap; reuses reservation prior art |
| 5 | W5 ergonomics polish | small | mostly surfacing what exists |
| 6 | W6 barracuda end-to-end | 1 session | the actual goal |
| 7 | W7 corpus upkeep | ongoing | keeps 1–6 honest |

W1+W4 are worth doing immediately; W2 is the highest-value engine change; W6
is the finish line.

## 7. Definition of done

One command routes barracuda from source at the checked-in DSL:
**90/90 by the connectivity oracle, `track↔pad` errors ≤ the 2-error baseline,
one-shot, deterministic, in the ~60 s class** — and when a future edit breaks
a net, an agent (or Eugene) reads `stuck[]`, changes a line of DSL, and re-runs
in seconds. The 90/90 board is the starred layout, and `bench-route` proves
none of it cost the other boards anything.

---

## 8. W1 measured — the premise was wrong, and that changes the plan

`(effort one-shot|standard)` is implemented and shipped (`befb1ef`), defaulting
to `standard` so nothing regresses. Measured on barracuda at the starred layout:

| | routed | DRC total / err | wall |
|---|---:|---:|---:|
| `standard` | **83/90** | 32 / 17 | 105 s |
| `one-shot` | **76/90** | 45 / 27 | 92 s |

**One-shot costs 7 nets to save 13 seconds.** Two premises in §1 were wrong:

1. **Retry is not the wall-clock hog.** It is ~12% of the route. The historical
   "rip-up bought zero nets" evidence was about specific rescue TIERS (the
   multi-net rip, the repair cascade) and about `close_open_nets`'s ladder — not
   about the batch escalate/rip-up interleave, which is plainly earning 7 nets
   here. Generalising that evidence to the whole retry path was my error.
2. **Speed must come from the base pass, not from cutting retries.** Even
   one-shot is 92 s. If the target is a seconds-scale agent loop, the profile of
   the 92 s base route is the thing to attack — scoped re-routes (which already
   exist and are gated) are the realistic fast path for iteration, not a faster
   whole-board run.

Also measured, and useful: coupling the oracle gate to the effort
(`include_failed = !effort.retries()`, so the gate finishes what no rescue
ladder will) is correct and kept, but it did NOT recover one-shot's nets. The
reason is diagnostic: the still-open nets have sub-1.5 mm *airline* gaps
(`SPI_LMX_CSN` 1.22 mm, `adf4159/REFIN_1V8` 0.92 mm, `ADF_CE` 1.47 mm) whose
pads have **no legal escape** — a short airline is not a short route. They are
`escape_blocked`, which is W3's problem, not a retry-policy or gate problem.

### Revised sequencing

- **W1 — done, but `standard` stays the default.** The knob is there for boards
  where wall clock matters more than nets; barracuda is not one.
- **W2 (per-net resolution) is now the top priority**, unchanged in substance:
  `SPI_SCK` needs a raster it can be represented on, and no retry policy or DSL
  ordering reaches it.
- **W3 (hard corridors / escape reservation) is promoted**, because the
  measurement above shows the remaining tail is dominated by blocked escapes,
  not by ordering or by search budget.
- **W4 (determinism) is demoted** pending evidence: the "7-net variance" that
  motivated it compared two DIFFERENT SURFACES (viewer Route+Save vs
  `?route=1`, one of which ran the fine retry and one of which did not), which
  R5's seam unification has since removed. Probe determinism with two identical
  calls before building anything.

## 9. W2 measured — the primitive works, the policy does not pay (yet)

`(net-class "…" (resolution MM) …)` is implemented: parsed, resolved onto the
net's rules, honoured as the FIRST rescue-window tier ahead of the adaptive
half/quarter tiers, and honoured even under `(effort one-shot)` and without the
grid-quantization classifier having to agree — because a declaration is the
author's instruction, not a router guess. Landing it required grouping the RF
trio (`max-freq`/`escape`/`min-bend-radius`) into an `rf` sub-struct on both
`NetRule` and `NetClassSpec`, which the field-count gates demanded and which
reads better anyway.

Measured on barracuda with `(resolution 0.05)` on `SPI_SCK`, `SPI_LMX_CSN` and
`TXDATA_ADF`:

| | routed | claimed | DRC total / err | wall |
|---|---:|---:|---:|---:|
| baseline | 83/90 | 85 | 32 / 17 | 105 s |
| declared, default window budget | **83/90** | 86 | **31 / 16** | 132 s |
| declared, 400k-cell window budget | **81/90** | 87 | 34 / 19 | 139 s |

Two findings, both worth keeping:

1. **At the default budget the declaration is mostly VOID on long nets.** A
   35 mm span at 0.05 mm needs ~140k cells against a 60k cap, so the tier is
   dropped silently. The measurable effect is +27 s and one fewer DRC error —
   the machinery engages, but not where it was aimed.
2. **Raising the budget is NET-NEGATIVE, and instructively so.** At 400k cells
   `TXDATA_ADF` closed — a net that had resisted every previous mechanism — but
   `GND`, `loop_amp/LF_OUT` and `boost22/BOOST22_SW` broke, taking the board to
   81/90 while the ROUTER's own claim rose to 87. A wider window does not just
   find more paths; it finds paths that displace copper other nets were using,
   and the per-window clean-DRC gate cannot see that. This is the same shape as
   the historical "aggregate count climbs while individual nets regress" trap.

So the budget stays at the automatic cap, with the measurement recorded next to
the constant. **Raising it needs a connectivity-aware accept gate first** — the
window rescue must reject copper that opens another net, the way
`route_close`'s judge and `close_open_nets`'s oracle check already do. That is
the real next increment for W2, and it is a bounded piece of work: the oracle
(`fab_readiness.routableTally`) already exists and is already used for exactly
this decision elsewhere.

**Status:** the `(resolution …)` primitive ships (opt-in, conservative, never
harmful at its shipped setting). `SPI_SCK` remains open, for the reason §2
predicted — but the fix is now one gate away rather than a missing vocabulary.

### Where the wider-window regression actually comes from

Worth stating precisely, because it moves the fix to a different layer.

The fine-window rescue does not cut other nets' copper — it stamps every other
net as an obstacle (`stampBoardCopper(..., skip_net = ni)`) and its own copper
is DRC-validated before being kept. So the broken nets were not damaged by it
directly. What happened is downstream: the rescue runs at FINISH, and the
post-route oracle gate (`route_close`) runs after it. The extra fine copper
occupies exactly the free space the gate's micro-gap bridges and plane stitches
were using — `GND`'s stitch sites above all. The rescue wins its net; the gate
then loses three.

That is why the accept gate has to be **connectivity-aware at the board level,
not clean-DRC at the window level**. The window's own check cannot see the cost,
because the cost is not a violation — it is a stitch that no longer fits.

**The layering constraint this runs into.** `fab_readiness` imports
`placement/router.zig`, so the router cannot call `routableTally` from inside
its own rescue (the acyclic-import gate, and the same constraint that put
`route_close` in `placement/` rather than in the router). So the check belongs
where the oracle already lives — at the `route_plan` seam, which already owns
the gate and already computes the tally twice. The shape:

1. tally connectivity BEFORE the rescue phase,
2. run the rescue,
3. tally again; if any net that was connected is now open, roll the rescue's
   copper back — the same additive-only invariant `route_close`'s judge enforces
   for its own hops.

That makes the wider declared budget safe to enable, and it is the concrete
prerequisite for `SPI_SCK`. It is a bounded change against machinery that
already exists on both sides.
