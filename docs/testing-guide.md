# Testing

> Moved verbatim from CLAUDE.md (2026-08-19); linked from its Reference Docs section.

```bash
# Unit tests (Debug by default; also runs Guardian checks)
zig build --seed=1 test

# The unit-test binary compiles at -Dtest-opt (default debug), NOT -Doptimize.
# Keep it Debug: focused tests, test-fast/mutation smoke, and the complete suite
# all exercise the same self-hosted development mode. Do not pass
# -Dtest-opt=safe in the repository workflow.

# Run only the tests whose NAME contains a substring, instead of the whole
# suite — the fast loop while iterating on a handful of new tests. Repeatable
# (-Dtest-filter=a -Dtest-filter=b runs the union). Forwarded to the compiler's
# --test-filter, so non-matching tests are never even analyzed: it cuts the
# compile as well as the run. `test` step only — the Guardian gate and the
# mutation smoke tier keep their own fixed sets, so a filter can't narrow them.
zig build --seed=1 test -Dtest-filter=add_tracks

# Compile EVERY test and run none of them (-fno-emit-bin: analysis only, no
# codegen, no link). The tier between a filtered run and the gate.
zig build test-compile

# Automatically select tests affected by the working-tree diff (or, on a clean
# feature branch, by its changes since the merge-base with main), then run
# test-compile over the complete suite. This is the default development check
# when the right test names are not already obvious.
zig build test-affected

# Inspect the selected modules/tests without running them, or compare against
# an explicit revision. AFFECTED_BASE provides the same override for scripts.
zig build test-affected -Daffected-list=true
zig build test-affected -Daffected-base=origin/main

# Build all designs (current boards live under projects/designs/src/boards/)
for d in stm32n6 cyclops-analog barracuda labstation adf5901 rf-switch-8way; do
  zig build run -- build --project-dir projects/designs --push $d
done
```

### The daily loop (toolchain re-measured 2026-08-12)

Prototype on plain `zig build`; use `--seed=1` when cache repeatability matters.
On the final rebased migration tree, a fresh-cache Debug application build
takes about **10 s** after the one-time Zig build-runner/dependency bootstrap;
the application compiler itself takes **9–10 s**. Native PNG/SVG export remains
the fastest way to validate rendered output.

For placement/routing experiments, use pinned-master self-hosted Debug. The
same-source four-board benchmark executes in 43.53 s versus 134.47 s on Zig
0.15.1 (3.09x faster), while retaining the fast Debug compile. Profile and
benchmark this Debug artifact because it is the internal target. Production
timing belongs to the ReleaseSafe candidate already created by deployment;
never create a separate internal ReleaseSafe build. The old 0.15.1 walls in
the next table are retained only as historical context.

The final 2,538-test Debug suite executes in **65.44 s**, versus **154.54 s**
for the 2,527-test Zig 0.15.1 Debug suite immediately before this port (2.36x
faster despite eleven additional tests). From empty local and global caches,
the complete gated command takes **172.84 s** and peaks at **1,017,388 KiB**:
the test compiler is 10 s and the remaining cold overhead is primarily Zig's
one-time build-runner/std/dependency bootstrap plus the separately gated Debug
application. An identical unchanged-tree rerun is a **2.62 s cached no-op**.
These final measurements used `--seed=1` and no competing build under
`scripts/gate.sh`; see `docs/benchmarks/zig-toolchain-2026-08/`.

Never rerun an unchanged `zig build test` "to be sure" because the cache hit is
the proof. Finish every branch with
`.githooks/prepare-release.sh` in its worktree after rebasing onto current
`main`. It runs the approximately 421 s test job and 343 s production build
concurrently, so the final exact gate is about seven minutes rather than their
sum. Do not run either full job immediately beforehand. A matching prepared
tree then deploys in seconds via candidate adoption (see Worktrees).

### The three test tiers, and why a filtered run used to lie

Historical tier walls measured 2026-08-11 (Zig 0.15.1, `-Dtest-opt=ReleaseSafe`,
2485 tests), after a **one-file `src/` edit** — the only case that matters,
since a commit always has changes. Also recorded in the Guardian benchmark
ledger (`guardian-check bench list .`).

| Tier | Cost after an edit | Compiles | Runs |
|---|---|---|---|
| `zig build test -Dtest-opt=Debug -Dtest-filter=…` | **~23 s cold** for a representative renderer test | only matching tests | only matching tests |
| `zig build test-compile` | **10.4 s** (1.5 s no-op) | **everything** | nothing |
| `zig build test` (the gate) | **~382 s compile/setup + 40 s run** | everything | everything |

Pinned-master replacement measurements (2026-08-12, Debug, 2,538 tests): the
fresh-cache full command is **172.84 s** with **65.44 s** of test execution;
the unchanged rerun is **2.62 s** and does not execute the cached test step.
`test-compile` from empty caches is **101.63 s**, but its actual semantic test
compile is **4 s**; the rest is the same one-time toolchain/dependency bootstrap.

`--test-filter` is a **compiler** flag, so a filtered run has two blind spots,
both of which have burned this repo:

1. **A filter that matches nothing exits 0** — output-identical to a green
   suite. Fixed 2026-08-04: every test binary here (`test` *and* `test-fast`)
   is built with Guardian's counting test runner, which prints
   `guardian/test: N test(s) selected by filter: …` before the first test and
   **fails** a run whose filters named nothing. `GUARDIAN_TEST_ALLOW_EMPTY=1`
   opts out; nothing here should need it. The unfiltered suite prints
   `guardian/test: N test(s) selected` (2485 today), so the count is always
   visible.
2. **The tests it skipped were never type-checked** — two commits once landed
   green on a suite that would not compile. `zig build test-compile` is the
   cheap answer: whole test binary, `-fno-emit-bin`, nothing run. Verified
   2026-08-04 — a deliberate type error in `src/coverage.zig`'s test body left
   `zig build test-fast` green and exit 0, and `test-compile` reported it in
   10 s. It is deliberately **not** a dependency of `test` (that would re-analyze
   the whole suite on every filtered run and erase the reason to filter) and
   deliberately **not** in `[gate] test_command` (an unfiltered `zig build test`
   already analyzes every test — see the guardian.toml note).

`test-affected` automates the first two tiers without changing that boundary.
It reads tracked, staged, unstaged, and untracked paths from Git; follows Zig
`@import` and `@embedFile` consumers plus tests that quote an exact repository
path; and extracts the named tests from the changed modules and a bounded set
of their consumers. Direct consumers are always included. Additional reverse
layers are included only while the selection stays below 400 filters, avoiding
test-only import cycles that would quietly turn every edit into a full run.
Changes to the build graph/test root, low-level changes exceeding that cutoff,
or code with no discoverable named test fall back to the full suite. Every
filtered plan also includes the fixed boundary-smoke set and finishes with
`test-compile` over everything.

The selector is intentionally not used by `prepare-release.sh`: static imports
cannot model every behavioral influence, fixture, generated input, or external
process. The exact release candidate still executes every test from a clean
test cache. Run `python3 scripts/test_affected_test.py` for the selector's own
dependency, fallback, Git-diff, and command-order regressions.

The loop this buys:

```bash
zig build --seed=1 test -Dtest-filter='the thing I am changing'
zig build test-compile
zig build guardian -- all . --gate --full
git add path/to/changed-file
git commit -m "describe the change"
.githooks/prepare-release.sh
```

The first three commands are the fast iteration/type-check/Guardian tiers; only
`prepare-release` runs the unfiltered suite and independent ReleaseSafe
production build. It publishes an exact-commit candidate only when both pass,
so a fast-forward merge can deploy without paying for a second build. Use
`guardian-check commit` instead of the explicit stage/commit sequence only when
its additional commit-tier full suite is intentionally wanted.

### Serializing gates across sessions

This repo usually has several agent sessions live at once, and a full gate is
one long single-threaded LLVM compile per session: run two or three together
and they fight over disk and memory rather than sharing cores. Measured
2026-08-10, the gate goes from ~4.5 min alone to ~9.5 min with two or three
concurrent builds, and the release ledger shows the same test job at 527 s
against 320 s solo — so queueing is strictly faster than overlapping. When
another session may be building, put the expensive tier behind the wrapper:
`scripts/gate.sh zig build test` and `scripts/gate.sh guardian-check commit
--intent "..." .` take one machine-wide flock (`/tmp/netlisp-gate.lock`, override
with `NETLISP_GATE_LOCK`) and wait up to `NETLISP_GATE_WAIT` seconds (default 5400)
before failing with the holder's pid. `NETLISP_GATE_SERIALIZE=0` bypasses the lock
entirely for a machine you know is idle. When the lock is busy, gate.sh reports
the queue depth and the pids ahead (with their commands) before it starts
waiting, and prints how long it queued once it acquires — a blocked gate is
never silent about what it is behind. `.githooks/prepare-release.sh` takes
the same lock itself, so release preparations queue without being asked — its
*internal* test/build parallelism is deliberate and unaffected. The browser
benchmark runners (`scripts/pcb_browser_perf/run.js`,
`scripts/pcb_editor_perf/run.js`, `scripts/ui_browser_perf/run.js`) also
re-exec themselves under the lock when invoked standalone
(`scripts/perf_gate_lock.js`): a timing run outside the queue corrupts the
gated one it overlaps — one such overlap aborted a 20-minute `--record` and
skewed a bench-page pass 17-72% (FEEDBACK.md 2026-08-29). As the backstop for
workloads that never take the lock at all, `netlisp bench-page` watches
`/proc/loadavg` around every board and labels the run CONTENDED when the
1-minute load exceeds what the bench itself plus the decay of a just-finished
gated job explains; `scripts/perf_gate.sh --record` refuses to install a
recording carrying that label. Quick tiers do
**not** belong in the queue: use `zig build --seed=1 test` with a focused
`-Dtest-filter=…`, or use `zig build test-compile`; these short jobs
should never wait behind someone's full suite.

### The primary-page latency gate (pre-push on main)

Page-load and DRC latency regressed repeatedly because nothing measured them.
`netlisp bench-page` (src/bench_page.zig) times the production seams per board:
design eval, sidecar parse, placement restore, reporting DRC, geometry DRC, and
complete cold renders of the PCB, assembly, thermal, and schematic pages. The
assembly timing covers its parent page while the independently measured PCB
timing covers its board iframe. `--baseline` compares medians against the
committed recording in `docs/benchmarks/pcb-page/baseline.json`, failing on
per-board allowances, corpus-wide drift, hand-set absolute budgets, moved DRC
counts (unlike work), or lost PCB page-cache retention. Before comparing, the
gate checks the baseline's stamped designs identity (commit plus
model/layout/BOM bundle hashes) against the snapshot being measured and
refuses a moved workload by name — designs drift is never misreported as a
latency regression. The tracked
`.githooks/pre-push` hook runs it (via `scripts/perf_gate.sh`, behind the
machine gate lock) whenever main is pushed; feature-branch pushes are never
gated. Re-record deliberately with `scripts/perf_gate.sh --record` and commit
the diff. Full rules and workflow: `docs/benchmarks/pcb-page/README.md`.

The same pre-push command also runs three headless-Chromium gates. The assembly
runner measures exact-CAM readiness plus its strict pan/zoom program. The
all-pages runner covers every interactive route and its normal search,
control, editor, timeline, and camera gestures; its route manifest fails when
a newly registered page has no performance scenario. The focused PCB-editor
runner prevents wheel coalescing from hiding expensive Barracuda zoom paints,
gates the high-density Canvas fallback, and asserts that swept RF copper stays
on retained WebGPU. It also runs against the exact stripped release candidate,
so a local merge cannot deploy before this check merely because main has not
been pushed. Setup, focused commands, and safety rules live in
`docs/benchmarks/ui-browser/README.md` and
`docs/benchmarks/pcb-editor/README.md`.

### Validating without touching `zig-out`

**`zig build test` never writes `zig-out/`.** You can fire a test run — full or
filtered — while a long board measurement, a benchmark, or the local server is
executing `zig-out/bin/netlisp`; that file is byte-identical before and after.
Only `zig build` (the install step) refreshes it. No `-p <scratch-prefix>`
dance is needed for this case.

The reason is the shape of the step graph: the `test` step depends only on
compile / run / fmt steps. `docs_check_run` executes the `netlisp` binary
straight out of the build cache rather than the installed copy, and Guardian's
`addAllChecks` re-orders artifact installs only when it is wired onto the
install step itself (`maybeGateInstall` returns early otherwise). One stray
`test_step.dependOn(b.getInstallStep())` would undo all of that silently, so
`build.zig` asserts the property at configure time — `assertDoesNotInstall` on
both `test` and `test-fast` panics with a pointed message if either step's
dependency closure ever reaches an `install_artifact` / `install_file` /
`install_dir` step.

What a test run *does* rebuild is the `netlisp` executable itself, because the
`gen-language-docs --check` gate has to run a current binary. On an edited tree
that Debug relink is paid on top of the test-binary compile — but it lands in
`.zig-cache`, never in `zig-out`. (If you ever want a genuinely separate
install prefix, e.g. two concurrent builds of the same checkout, `zig build
-p <scratch-prefix>` still does that; it is just not the tool for "don't
disturb the running binary".)

### Fuzzing

The hand-rolled codecs that parse **untrusted** input (S-expressions via
MCP/HTTP/file import, DEFLATE, `.kicad_pcb`, the fab-package ZIP, PNG) carry
`std.testing.fuzz` harnesses. Their oracles are property-based: the sexpr
parser never crashes and its printed output re-parses to a fixed point; DEFLATE
is a true round-trip (`inflate(deflateRaw(x)) == x` via std's inflater); the
`.kicad_pcb` reader and ZIP/PNG encoders never crash and stay well-formed on
arbitrary bytes.

- **Smoke mode (default, every `zig build test`).** With the suite built
  normally, `std.testing.fuzz` just replays the harness's seed corpus plus the
  empty input once — a cheap regression check, run under `testing.allocator` so
  a leak on any path fails. This is what the gate relies on.
- **Deep mode (`zig build test --fuzz`) is broken on Zig 0.15.1.** The build
  system's fuzzer driver crashes inside `std/Build/Fuzz.zig` (a `pcs[]` indexing
  bug) before any harness runs, so coverage-guided fuzzing is unavailable on
  this toolchain. The harnesses are written to run either way; re-enable deep
  fuzzing once the toolchain is fixed.
- **Presence gate.** `guardian.toml [fuzz_presence] modules = [...]` lists the
  fuzzed files; Guardian fails the build if any listed module loses its
  `std.testing.fuzz` call, so the coverage can't silently lapse.
