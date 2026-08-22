# Zig toolchain tradeoff measurements — 2026-08-10/11

> **Superseded 2026-08-12:** the project is now ported to and exactly pins
> `0.17.0-dev.1683+5ceec001b`. A same-source rerun before the port measured
> Debug execution at 43.53 s versus 134.47 s on 0.15.1 (**3.09x faster**),
> while ReleaseSafe remained effectively level at 6.28 s versus 6.23 s. The
> older “stay on 0.15.1” verdict below is retained as the decision history.
>
> The fully ported, rebased suite confirms the daily-loop gain: 2,538 Debug
> tests execute in 65.44 s, versus 154.54 s for the 2,527-test Debug suite on
> Zig 0.15.1 immediately before the port (**2.36x faster**). A completely
> empty-cache gated command takes 172.84 s at 1,017,388 KiB peak RSS; the
> identical unchanged rerun is a 2.62 s cached no-op. Raw summary fields are in
> `full-debug-suite-20260812.tsv`.
>
> **Current workflow:** use pinned-master self-hosted Debug for every internal
> application build, test, dev server, tool, solver run, and benchmark. The
> ReleaseSafe/LLVM rows below are retained only as toolchain decision evidence;
> deployment is the sole workflow that now builds a ReleaseSafe EDA artifact.
> That deployment executable is stripped: a 2026-08-12 clean A/B reduced the
> full application build from 293.66 s / 4.24 GB RSS / 61.1 MB to 223.11 s /
> 2.26 GB RSS / 20.5 MB without changing ReleaseSafe runtime checks. See
> `../release-build-2026-08/README.md` for the release-build analysis.

Decision data for "should eda upgrade past Zig 0.15.1, and can Debug builds
replace ReleaseSafe for prototyping?" Measured on the production server
(i5-10400, 12 threads, Linux). The raw `.tsv`/`.txt` files and the
`summarize*.py` scripts that regenerate every table live beside this file;
`*2`/no-suffix = the 2026-08-10 run (0.15.1 vs 0.16.0), `*3` = the 2026-08-11
run (all three toolchains, re-measured same-day after a designs-repo change
shifted barracuda's input).

## Method

Target: `src/bench_layout.zig` (placement optimizer + evaluator, no server
stack) compiled directly with `zig build-exe` (build.zig bypassed), source
ported per-toolchain on throwaway branches `zig016-experiment` /
`zig-master-experiment`. Every timed compile/run held the machine-wide gate
lock (`scripts/gate.sh`) so concurrent agent builds could not pollute walls;
medians of 3. Execution = `--reps 3 barracuda stm32n6 cyclops-analog
rf-switch-8way` from the main checkout root. **Pose checksums were
byte-identical across all toolchains × modes × runs**, so timings compare
identical work (barracuda's checksum differs between the two days because
designs commit `12272a1` changed its input — hence the same-day re-measure).

## Results (2026-08-11 run; toolchains: 0.15.1, 0.16.0, master = 0.17.0-dev.1662+cc6f42302)

Compile, elapsed seconds (median):

| mode | kind | 0.15.1 | 0.16.0 | master |
|---|---|---|---|---|
| Debug | cold | 1.96 | 1.92 | 1.63 |
| Debug | rebuild | 1.77 | 1.55 | 1.39 |
| ReleaseSafe | cold | 83.56 | 84.20 | 85.81 |
| ReleaseSafe | rebuild | 82.25 | 83.80 | 83.80 |
| ReleaseFast | cold (n=1) | 93.64 | 100.48 | 93.37 |

Execution, whole-workload wall (median):

| mode | 0.15.1 | 0.16.0 | master |
|---|---|---|---|
| Debug | 129.50 s | 41.06 s | 40.38 s |
| ReleaseSafe | 6.08 s | 10.11 s | 5.98 s |
| ReleaseFast | 5.15 s | 5.39 s | 5.38 s |

Per-design ReleaseSafe solve, median ms (ratio vs 0.15.1):

| design | 0.15.1 | 0.16.0 | master |
|---|---|---|---|
| barracuda | 103.09 | 749.73 (7.27×) | 104.20 (1.01×) |
| cyclops-analog | 79.94 | 231.18 (2.89×) | 85.49 (1.07×) |
| rf-switch-8way | 8.91 | 18.66 (2.09×) | 9.80 (1.10×) |
| stm32n6 | 129.01 | 286.29 (2.22×) | 182.91 (1.42×) |

## Verdicts

- **0.16.0: do not upgrade.** ReleaseSafe execution regressed 1.7–7.3× (prod
  ships ReleaseSafe), with no compile-time gain anywhere.
- **master: the ReleaseSafe regression is fixed** (3 of 4 designs at
  1.01–1.10×; stm32n6 keeps a real 1.42× residual), Debug execution is 3.2×
  faster than 0.15.1 — but master introduced its own ReleaseFast execution
  regression (1.2–1.46×) and compile times are unchanged in every toolchain.
- **Plan: stay on 0.15.1; port at the 0.17.0 release.** The payoff is the
  Debug daily loop (~1 s solves instead of ~3 s); the LLVM ReleaseSafe
  compile wall (~84 s for this slice, ~5 min for the full binary) is identical
  in all three toolchains and is not a reason to move.
- `-fincremental` does nothing outside `zig build --watch` (measured).

## Port-surface notes (what an 0.17 port must cover)

On top of the 0.16 std churn (std.fs→std.Io.Dir/File with io params,
`std.process.Init` main, ArrayList `.empty`, unmanaged PriorityQueue,
`@Vector` runtime indexing now comptime-only — mostly absorbed by the
`src/infra/{fs,clock,random,log}.zig` port modules), master additionally
removed the `**` array-repeat operator (64 sites → `@splat`; repeated strings
need explicit `[N]u8` consts), reworked `@typeInfo` enum reflection into
parallel `field_names`/`field_values` slices (9 files), and replaced
`EnumSet.initEmpty()` with the `.empty` decl (4 files). Still unported:
~270 `.writer(` sites, `std.json` (~475 hits), the HTTP layer, vendored
httpz/websocket/metrics (use the removed `@Type`), and guardian-zig itself
(its build helper must port before `zig build` even configures).
