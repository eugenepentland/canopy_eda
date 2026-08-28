# Debug placement hot-path optimization — 2026-08-12

This run targeted the Zig 0.15.1 self-hosted Debug build used for daily
development. On the representative four-design corpus, the final placement
medians are **2.32–2.94× faster** with byte-identical pose checksums and
unchanged objective/routed scores. The sum of the four medians fell from
14.082 s to 5.374 s (2.62×, or 61.8%).

## Method

- Host: Intel Core i5-10400, Linux 5.15.0-187, Zig 0.15.1.
- Baseline: netlisp commit `b7fa30120535b8483c767cb1e3d75c59481055e3`.
- Final: the commit containing this report.
- Input repo: `projects/designs` at
  `b2789cc5defb531175fa51da33819e9eb40e62f6`, with its pre-existing dirty
  `lib/footprints/sot95p280x145-5n.sexp` included in both runs (SHA-256
  `e9312fb5041e5572afa8eba25975207d92c336a34ed45065d5d04ccc1ba1ff26`).
- Native timing: `zig build bench-layout -Doptimize=Debug`, then CPU-pinned
  medians of seven in-process repetitions. The benchmark checksum covers every
  part's final pose, side, and lock bit.
- Profiling: Valgrind 3.18.1 Callgrind with cache and branch simulation, one
  `rf-switch-8way` repetition, compiled from the same source with
  `-ODebug -fno-llvm -mcpu=x86_64`. The generic CPU target was required because
  Valgrind 3.18 cannot decode one AVX round instruction in the native binary.

Hardware `perf` was attempted first. The installed kernel has no matching perf
package, and the compatible 5.15 perf binary is denied by the host's
`kernel.perf_event_paranoid=4`; passwordless elevation is unavailable. Callgrind
and Cachegrind therefore supplied deterministic instruction, branch, and cache
profiles. Its simulated milliseconds are useful only for before/after ratios;
the native table is the wall-clock result.

Reproduction commands (replace the Valgrind paths with the local installation):

```sh
zig build bench-layout -Doptimize=Debug
taskset -c 3 /usr/bin/time -v ./zig-out/bin/bench-layout \
  --project-dir /home/epentland/ai/canopy/eda/projects/designs --reps 7 \
  barracuda stm32n6 cyclops-analog rf-switch-8way

zig build-exe src/bench_layout.zig -ODebug -fno-llvm -mcpu=x86_64 \
  -femit-bin=/tmp/bench-layout-debug-generic
taskset -c 3 env VALGRIND_LIB=/path/to/valgrind/libexec/valgrind \
  valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes \
  --callgrind-out-file=/tmp/callgrind.out \
  /tmp/bench-layout-debug-generic \
  --project-dir /home/epentland/ai/canopy/eda/projects/designs --reps 1 \
  rf-switch-8way
```

## Native Debug results

| design | parts | baseline median | final median | speedup | reduction | pose checksum |
|---|---:|---:|---:|---:|---:|---|
| barracuda | 186 | 3618.633 ms | 1558.515 ms | 2.322× | 56.9% | `6c9f706253ee4256` |
| stm32n6 | 232 | 7071.340 ms | 2405.198 ms | 2.940× | 66.0% | `8cd81ca201c40f00` |
| cyclops-analog | 168 | 3123.349 ms | 1308.681 ms | 2.387× | 58.1% | `0d6f585638c66217` |
| rf-switch-8way | 30 | 269.141 ms | 101.273 ms | 2.658× | 62.4% | `763565c4842b8ca1` |
| **sum** | 616 | **14082.463 ms** | **5373.667 ms** | **2.621×** | **61.8%** | — |

The geometric-mean speedup is 2.565×. The complete seven-repetition benchmark
process, which also includes parsing, evaluation, routed scoring, and warnings,
fell from 197.93 s to 124.35 s wall (1.592×, 37.2%). Maximum RSS was effectively
flat: 255,948 KiB before and 255,916 KiB after.

All final scores matched the baseline: barracuda `3893.7119 / 4682.7025`,
stm32n6 `17766.4380 / 19208.7239`, cyclops-analog
`8748.5818 / 9777.7020`, and rf-switch-8way `726.0986 / 726.0986`
(`objective / routed`).

## Profiler results

The original profile was dominated by repeated rule and string work in the
sealed-pad scan, by-value copies of the large `Part` and `BoardRules` structs,
crossing-candidate topology reconstruction, and a 4,096-element legalization
scratch footprint used even for a 30-part module.

| simulated event (`rf-switch-8way`) | baseline | final | reduction |
|---|---:|---:|---:|
| instructions | 4,659,537,749 | 1,592,836,702 | 65.8% |
| data reads | 3,431,210,537 | 828,490,535 | 75.9% |
| data writes | 3,504,042,384 | 869,668,298 | 75.2% |
| L1 instruction misses | 10,633,795 | 3,534,756 | 66.8% |
| L1 data-read misses | 5,403,277 | 238,820 | 95.6% |
| L1 data-write misses | 5,875,476 | 1,082,063 | 81.6% |
| conditional branches | 3,260,195,596 | 736,366,921 | 77.4% |
| conditional mispredicts | 48,367,969 | 23,737,266 | 50.9% |
| Callgrind elapsed | 81.478 s | 20.218 s | 75.2% (4.03×) |

The fixed-capacity legalization function alone fell from 294.5M to 19.3M
instructions after specialization, and its scratch-related L1 read/write misses
fell from roughly 4.47M/4.64M to 0/302. After the changes, no single source
function exceeds 10% of instructions; square root is first at 9.86%, followed
by crossing evaluation at 6.41%.

## Changes and iteration notes

- Cache the resolved net-class clearance in each pad-table row and compare
  canonical net indexes directly. This trades one `f64` per pad for removal of
  repeated `BoardRules` walks and string equality checks in the
  `O(pads² × escape-directions)` lint scan.
- Pass large, read-only geometry records by pointer in hot paths instead of
  copying `Part`, `BoardRules`, and `PadInfo` values.
- Resolve immutable crossing topology and footprint-local pad coordinates once
  per polish pass; candidate swaps now update only world coordinates and the
  crossing calculation.
- Allocate relaxation/legalization scratch outside iteration loops and use a
  256-part specialization for the common case. The live scratch footprint drops
  from 192 KiB (`4096 × (KeepBox + ax + ay)`) to 12 KiB, fitting comfortably in
  the core's cache; boards above 256 parts retain the 4,096-part fallback.
- Move the reusable MST/crossing primitives into `airwire_geometry.zig`, keeping
  the optimizer below its file-size gate and giving those primitives focused
  tests.

One memory-layout experiment was deliberately rejected: copying each `Part`
into a compact position/extent-only `MotionBody` array before repulsion increased
the four-design benchmark process from 132.89 s to 144.66 s (8.9% slower), even
though the pose checksums remained identical. The extra gather/scatter traffic
cost more than the smaller pair-loop records saved. The committed approach
keeps the canonical part array and shrinks scratch storage instead.

Intermediate native medians showed where the wins arrived (the first row used
seven repetitions; exploratory rows used three):

| iteration | barracuda | stm32n6 | cyclops | rf-switch |
|---|---:|---:|---:|---:|
| baseline | 3618.633 | 7071.340 | 3123.349 | 269.141 |
| cached lint rules/index equality | 1838.423 | 2731.674 | 1433.087 | 205.248 |
| loop-external scratch | 1714.847 | 2702.536 | 1424.400 | 205.190 |
| pointer geometry | 1613.982 | 2554.683 | 1338.930 | 207.777 |
| cached crossing topology | 1629.447 | 2541.931 | 1331.312 | 102.066 |
| final bounded scratch (seven reps) | 1558.515 | 2405.198 | 1308.681 | 101.273 |

Times are milliseconds. Small reversals between adjacent exploratory rows are
normal run-to-run noise; a change was retained only when the profiler explained
its effect and the final seven-repetition corpus remained faster.
