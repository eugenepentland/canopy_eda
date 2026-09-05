# Build System

> Moved verbatim from CLAUDE.md (2026-08-19); linked from its Reference Docs section.

Dependencies: `httpz` (HTTP server), `guardian` (code-quality gate).

### Build modes and codegen backends

The repository has one bright-line policy: **every internal netlisp build is the
self-hosted Debug build**. That includes the application, focused/full tests,
dev servers, renderers/exporters, mutation runs, solver experiments, profiling,
and benchmarks. **Self-hosted ReleaseSafe is built only at the deployment boundary**
by `prepare-release.sh`, never as a parallel
developer workflow.

Match the Debug workflow to the question being answered:

| Purpose | Command | When to use it |
|---|---|---|
| Fast application feedback | `zig build --seed=1 -Doptimize=debug` | Schematics, rendering, UI, parsers and ordinary development. Plain `zig build` is equivalent apart from its randomized cache key. |
| Focused behavioral test | `zig build --seed=1 test -Dtest-filter='name'` | The normal inner loop. Tests default to Debug; confirm that the printed match count is nonzero. |
| Whole-suite type-check | `zig build test-compile` | After focused tests when a change could affect distant test call sites. Runs no tests. |
| Full suite | `zig build --seed=1 test` | Cross-cutting diagnosis or the final gate. The test binary defaults to Debug independently of `-Doptimize`. |
| Exact production candidate | `.githooks/prepare-release.sh` | Once, on the final clean commit after rebasing onto current `main`. Runs self-hosted Debug tests and the sole self-hosted ReleaseSafe application build concurrently. |

Do not construct a standalone ReleaseSafe application during development.
`prepare-release` owns that build and runs it once beside the Debug suite.
During normal iteration, use the Debug application, Debug dev server, filtered
or full Debug tests, native Debug render/export tools, and `test-compile`.

The repository exactly pins Zig `0.17.0-dev.1683+5ceec001b`; see
`ZIG_TOOLCHAIN.md`. Its normal Debug build selects Zig's self-hosted code
generator. The top-level build runner does **not** accept
compiler flags such as `-fno-llvm` or `-fllvm`; both of these are invalid:

```bash
zig build -Doptimize=debug -fno-llvm
zig build -Doptimize=debug -fllvm
```

Direct compiler invocations may spell the self-hosted Debug backend explicitly,
for example the slim optimizer benchmark:

```bash
zig build-exe src/bench_layout.zig -ODebug -fno-llvm \
  -femit-bin=/tmp/bench-layout-selfhost
```

Do not substitute `-fllvm`, `-OReleaseSafe`, `-Dtest-opt=safe`, or
`-Doptimize=safe` in an internal workflow. The deployment scripts own the
self-hosted ReleaseSafe application artifact.

Measured 2026-08-11 with clean caches and the same four-design, three-rep
optimizer workload (all pose checksums matched):

| Toolchain / mode | Self-hosted compile / run | LLVM compile / run |
|---|---:|---:|
| Zig 0.15.1 Debug | 4.91 s / 143.82 s | 14.73 s / 32.59 s |
| Zig 0.15.1 ReleaseSafe | 4.95 s / 141.39 s | 92.03 s / 6.67 s |
| Zig master Debug | 5.22 s / 46.88 s | 16.24 s / 42.94 s |
| Zig master ReleaseSafe | 4.98 s / 45.29 s | 89.77 s / 6.75 s |

The table is historical pre-port decision data, not current command guidance.
A same-source rerun on 2026-08-12 selected
the current snapshot: Debug took 43.53 s versus 134.47 s on 0.15.1 (**3.09x
faster**) and ReleaseSafe was effectively unchanged at 6.28 s versus 6.23 s;
all pose checksums matched. The application, Guardian, Ward, httpz, zt,
websocket, metrics, passcay, and zbor are now ported and pinned together.
Use self-hosted Debug for development and internal performance work. Production
performance is checked on the candidate that `prepare-release.sh` already
builds; do not create a second ReleaseSafe binary just to benchmark it. Before
the latency-sensitive PCB-editor measurement, release preparation waits for
three quiet CPU/run-queue samples. A timing-budget miss gets up to three
attempts, each after another quiet window; renderer, workload, and other
infrastructure failures still fail immediately. The thresholds and timeout can
be tuned with the `NETLISP_PERF_HOST_*` environment variables, and
`NETLISP_EDITOR_PERF_ATTEMPTS` controls the bounded attempt count.

The deployment ReleaseSafe executable alone is stripped. On the pinned Zig
snapshot, a controlled clean direct build dropped from **293.66 s / 4.24 GB
RSS / 61.1 MB** unstripped to **223.11 s / 2.26 GB RSS / 20.5 MB** stripped
(70.55 s, 24% wall reduction). ReleaseSafe bounds/overflow/cast checks are
unchanged; the tradeoff is that production crash addresses no longer carry the
full in-binary symbol table. The failed binary, candidate commit and runtime
build ID remain available for exact reproduction with a Debug build.

Commit identity is deployment metadata, not a Zig module option. The candidate
stores its exact nine-character `build-id`; deployment atomically writes
`.git/netlisp-deploy-id`, and rollback restores the ID paired with the
last-known-good executable. Local Debug runs resolve the checkout's git metadata
when they create a stamped artifact. This keeps docs- and hook-only commits out
of the application cache key; the measured unchanged compiler
graph returns in about **0.27 s** instead of recompiling for a new embedded hash.

### The bundled standard library

`stdlib/**/*.sexp` is compiled INTO every artifact. `stdlibEmbed` in
`build.zig` walks `stdlib/` at configure time, copies each file into a
generated module directory, and emits a `path → @embedFile(…)` table as the
`stdlib_embed` module; the exe, both test binaries, the layout bench and the
WASM DRC all import it, because all five can reach `src/stdlib.zig`. Adding a
`.sexp` under `stdlib/` therefore needs no registration — the glob picks it up,
and the copies are `LazyPath`s onto the real files, so editing one re-runs the
step. See [standard-library.md](standard-library.md).

### Guardian gate

Guardian runs its full **71-check suite on every `zig build` / `zig build
test`** — formatting, the spec workflow, structural / public-API / style /
error-handling / allocation checks, and git-aware process gates. It runs in
**baseline mode**: existing violations are frozen in `.guardian/`, so only NEW
regressions fail. There is no bypass — fix the code, never loosen the gate.

The gate binary is **not compiled by this build** in the normal case: guardian's
`addAllChecks` reuses the `zig-out/bin/guardian-check` a plain `zig build`
already left in the guardian checkout, guarded by a `guardian-selfcheck` step
that hashes guardian's own sources and **fails the build** when that binary
predates them (`prebuilt guardian-check is stale vs its source` → run `zig
build` in `~/ai/canopy/guardian-zig`). This is why a brand-new worktree's first
`zig build` here is ~15 s instead of paying a cold ReleaseSafe compile of an
unchanged tool. `GUARDIAN_PREBUILT=off` forces the from-source compile back on;
`zig build guardian-selfcheck` runs the guard alone.

- **Per-item ratchets.** Each shape check (file/function length, complexity,
  nesting, params, type fields, line length) records a per-item ceiling that
  can only *shrink*. Do not raise a cap in `guardian.toml` to pass — improve the
  code; the improvement auto-lowers that item's ceiling.
- **Spec workflow.** `SPEC.md` `- ` bullets map **1:1** to `// spec: Section -
  Behavior` tags on tests. `[baseline] deny_growth = ["spec", "completeness"]`
  is active: a new bullet must land with its tagged test in the *same* change,
  and neither spec nor scenario-category debt may grow. `zig build spec-init`
  regenerates a starter SPEC.md.

`guardian-check` is the deliberate exception to the netlisp-artifact policy: it is
an already-built gate tool that must run on every Debug build, not a netlisp
application/test/dev-server artifact. Keeping that checker ReleaseSafe avoids
roughly 40x gate execution overhead; it does not create or exercise a
ReleaseSafe netlisp build.

Commands (`guardian-check` is the guardian dep's binary at
`../guardian-zig/zig-out/bin/`, built by `zig build` there — that build now
defaults the installed binary to **ReleaseSafe**; keep it that way. A Debug
`guardian-check` runs the same 71-check gate in ~42 s instead of ~1.1 s, a
silent 40x tax on every commit. If `guardian-check commit` starts reporting a
gate of tens of seconds, rebuild the dep with a plain `zig build` there and
check the binary size: ReleaseSafe ≈ 10 MB, Debug ≈ 55 MB):

- `zig build` / `zig build test` — gated build/test (full suite).
- `zig build mutate` — fast mutation tier: mutates only lines changed vs HEAD;
  for PR scope, `GUARDIAN_AGAINST=origin/main zig build mutate`.
- `zig build test-compile` — compile every test, run none (10 s). The tier
  between a filtered run and the gate; see [Testing](#testing).
- `zig build test-fast` — focused fail-closed boundary smoke suite used before
  the full suite for every mutation survivor.
- `zig build mutate-full` — whole-tree mutation; ratchets the kill score in
  `.guardian/mutation.txt` (nightly tier — the score can only climb).
- `guardian-check debt .` — non-gating frozen-debt / ratchet / mutation report;
  supports `--json`, `--check`, and dry-run `--prune-stale` (`--yes` deletes).
- `guardian-check doctor .` — read-only metadata, integration, and cache audit.
- `guardian-check spec-sync .` — dry-run suggestions for missing SPEC bullets.
- `guardian-check commit --intent "msg" .` — opt-in exact-diff commit flow:
  runs the configured commit tier (currently the unfiltered full suite), then
  stages a safe path list and commits only on green. Do not invoke it directly
  before `prepare-release` unless two full-suite runs are intentional; for the
  normal one-gate release flow, run Guardian, stage reviewed paths explicitly,
  commit, then let `prepare-release` own the single full test/build gate.
- `guardian-check explain <check>` — why a check blocks, how to fix / exempt;
  run it when a check fires instead of guessing.
- Selective refresh: `GUARDIAN_UPDATE_SNAPSHOT=<check[,check]> zig build` accepts
  exactly the named snapshot(s) — never a bare `=1` casually (it ratifies every
  snapshot at once). Commit the resulting `.guardian/` change.

Every gated run appends one JSON record per violation to
`.guardian/cache/last-run.jsonl` (machine-readable, for editor tooling / fix
loops).

The language reference `docs/language-forms.md` is auto-generated by
`src/docgen.zig` from the same dispatch tables the implementation uses
(`eval/forms.zig` registries, `eval/fmt.zig` directives, `sexpr/tokenizer.zig`
SI-suffix tables, `render_block_types.zig` classifier keywords). Three
enforcement layers keep it from drifting: an undocumented form variant is a
**compile error** (`requireAllDocumented`), per-table sync tests prove each
table matches its dispatch, and `gen-language-docs --check` runs on every
`zig build` / `zig build test` and fails when the committed file is stale.
Regenerate with `zig build docs`.
