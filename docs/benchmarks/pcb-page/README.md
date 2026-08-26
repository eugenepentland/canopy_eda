# PCB-page latency baseline — the pre-push gate for main

`baseline.json` here is the committed recording that `netlisp bench-page
--baseline` (and therefore the `pre-push` hook, via `scripts/perf_gate.sh`)
gates main against. The harness is `src/bench_page.zig` — its header documents
exactly what each phase times; this file documents the workflow and the rules.

## What is measured

Per board (every design with a `.layouts.json` sidecar — the boot warm-up's
own corpus rule), medians over 3 reps, in ms:

| phase | the production seam it times |
|---|---|
| `eval_ms` | design evaluation (`Evaluator.evalFile`) |
| `sidecar_ms` | `.layouts.json` read + JSON parse (7 MB on barracuda) |
| `solve_ms` | `solveForRequest` — eval + sidecar + ★ verbatim restore + copper restore |
| `drc_report_ms` | `drc_rules.checkFilteredZones` — the reporting DRC (geometry + pour topology + `net_open` + severity overrides) behind `/api/pcb-drc`, the page blob, describe, and the fab gate. **Reps are not independent**: the seam memoises a board's poured copper while the board is unchanged (`src/placement/fill_cache.zig`), so rep 1 pours it and the rest borrow it, and the median is the RECONCILE cost — what an editor DRC loop and every derived fetch pay over a board that has not moved. |
| `drc_geom_ms` | `drc.check` — geometry only, the native twin of the client's interactive WASM DRC |
| `page_ms` | `pcb_derived.warmPage(…, .page)` on a fresh cache — the complete cold `/pcb-layout/:name` render: eval, sidecar, placement, DRC, HTML, cache admission, gzip memo. The `.page` scope stops where the reader's first paint does; the analyses behind `?derived=1` are a separate response with its own cache entry and are not in this number. |

Phases nest (`eval ⊂ solve ⊂ page`); the DRC phases are timed standalone.
Alongside the timings each row records the DRC counts (errors / total /
net_open), whether the rendered page was **admitted to the page cache** (a
page too big or refused turns *every* reload cold — a regression no timing
column shows), and the rendered HTML size.

## The gate's rules

A gated run fails (non-zero exit, refusing the push) when any of:

1. **Per-board allowance** — a phase median exceeds
   `max(baseline × 1.30, baseline + 25 ms)`. The absolute floor keeps
   millisecond-scale boards from failing on jitter; the ratio catches real
   regressions on big ones.
2. **Corpus drift** — the geomean of per-board `now/baseline` ratios for any
   phase exceeds **1.10**: ten boards each 20 % slower is a regression the
   per-board rule alone would wave through.
3. **Hand-set budgets** — the optional top-level `"budgets"` object in
   `baseline.json` (e.g. `"budgets": {"page_ms": 1500, "drc_report_ms": 500}`)
   caps every board absolutely. The recorder never writes this object — only a
   human adds or changes a budget, so re-recording cannot silently raise one.
4. **Unlike work** — a board's DRC counts moved vs the baseline. Wall times
   over different work prove nothing; the fix is to re-record (below) if the
   *designs* changed, or to find what your *code* change did to DRC if they
   didn't.
5. **Retention lost** — a board whose page the baseline run cached is no
   longer admitted.

A board **without a blessed (starred/named-restorable) layout** is reported
but never gated: its cold render re-solves the placement — and the render
path persists that solve into the sidecar, exactly as the boot warm-up does —
so neither its wall times nor its DRC counts are stable across runs
(discovered the hard way: barracuda-base's counts moved between the first two
recordings). New boards are noted (`unlined`), never silently passed;
vanished boards are noted (`missing`), never failed — a designs-repo rename
is not a code regression. A missing or corrupt baseline **fails**: a gate that silently
stops gating is how the regressions this exists to stop got here.

## Workflow

```bash
# Enforce (what pre-push runs; non-zero exit on regression):
scripts/perf_gate.sh

# Re-record after an intentional change (a real speedup, a designs-repo
# update) — then review and COMMIT the diff deliberately; re-add any
# hand-set "budgets" object, which recording never writes:
scripts/perf_gate.sh --record

# One board, more reps, by hand:
zig-out/bin/netlisp bench-page --project-dir projects/designs --reps 5 barracuda

# Escapes (loud): skip one push
EDA_PERF_SKIP=1 git push
```

`perf_gate.sh` queues behind `scripts/gate.sh`'s machine-wide lock — a
concurrent `zig build test` roughly doubles wall times (measured, see
docs/testing-guide.md), which would fail honest commits.

## Validity rules for the numbers

- **Same machine, same build mode.** The baseline and the gated run must both
  be the pinned-toolchain **Debug** build (`zig build`) on the machine that
  recorded the baseline — the repo's standing rule that Debug is the internal
  measurement target (docs/benchmarks/zig-toolchain-2026-08/). A baseline from
  another machine or a ReleaseSafe binary compares nothing.
- **Idle machine or gated.** Never read numbers taken beside a compile.
- **Medians of ≥ 3.** One rep proves nothing; the harness defaults to 3.
- **`drc_report_ms` is a warm number** (see the table). A change that only
  makes the FIRST pour of a board cheaper will barely move it; a change that
  breaks the fill memo's key will move it several-fold and should be read as a
  regression in the memo, not in the pour.
- The client half of DRC latency (the browser's WASM worker) is the same
  `placement/drc.zig` compiled to wasm; `drc_geom_ms` is its native proxy.
  Browser-side costs (JS parse of the ~1 MB page, worker marshaling) are not
  measured here.
