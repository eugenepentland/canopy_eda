# Repository Agent Instructions

## Mandatory worktree workflow

**Scope: changes to the netlisp tool itself.** This workflow governs edits to this
repo's source (the `netlisp` binary, schematic engine, renderers, server,
build scripts, and this documentation). Work on the design library under
`projects/designs/` is exempt: that folder is its own git repo and the live
library the server serves — edit and commit straight to its `main`, and never
run the build/test/release steps in this file for it (see
`projects/designs/AGENTS.md`).

Never modify the `main` checkout directly. Every project update must be made on
a feature branch in its own git worktree, including code, tests, design files,
documentation, specifications, Guardian metadata, generated files, and config.

Before any command that can write project files:

1. Run `git branch --show-current`, `git status --short`, and
   `git worktree list`.
2. If the current checkout is `main`, create a task worktree before editing:

   ```bash
   git worktree add .claude/worktrees/<short-task> -b codex/<short-task> main
   cd .claude/worktrees/<short-task>
   ```

   Use the branch prefix required by the active agent environment when it is
   not `codex/`.
3. Confirm the new worktree's branch and status, then perform all edits, code
   generation, builds, tests, Guardian acceptance, staging, and commits there.

The root `main` checkout is reserved for read-only inspection and controlled
integration/deployment operations. `main` should receive completed work through
a reviewed branch merge, never through direct file edits or a direct commit.

After a project update is implemented, verified, and committed, merge its
feature branch into `main` by default so the post-merge deployment hook can
restart the single-user server. Do not merge when there is a concrete concern
about regressions, incomplete verification, unresolved conflicts, dirty state,
or deployment safety; report that concern and leave the branch isolated instead.

For a completed commit, run `.githooks/prepare-release.sh` in its feature
worktree before merging. It runs the full test suite and ReleaseSafe build at
the same time, records an exact-commit candidate under the shared git directory,
and lets the post-merge deploy reuse that binary. If a merge creates a different
commit, the deploy hook safely performs the same preparation on `main`.

**This release gate applies only to changes to the netlisp tool itself** (the
`netlisp` binary, schematic engine, renderers, UI, parsers). Changes to the
design library under `projects/designs/` — schematics, modules, parts, and
their docs — never build or rebuild anything: the `netlisp` launcher resolves
the current verified build, so the whole workflow there is edit the `.sexp`,
then `netlisp build` + `netlisp check` (see `projects/designs/AGENTS.md`).
Skip every build/test/release step in this file for that folder's changes.

Treat commands that may rewrite files as write operations even when they sound
diagnostic. Examples include `zig build docs`, formatters without `--check`,
Guardian snapshot/baseline acceptance, import/export commands, and tests or
builds known to regenerate metadata.

If the `main` checkout is already dirty, do not stage, commit, move, overwrite,
or discard those changes. They may belong to another person or task. Create the
task worktree from the requested base, keep the new work isolated, and report
the pre-existing main-checkout state to the user.

Before handing work back, report the worktree path, feature branch, verification
performed, and whether the branch remains unmerged.

## Repository workflow feedback

After a netlisp-tool task, append a concise entry to `FEEDBACK.md` when you
encounter a genuine blocker or identify a concrete way to reduce future turns,
tool calls, rebuilds, or retries. Follow that file's append-only format and do
not add routine success notes. This repository log is separate from the
mandatory Guardian feedback log described by the global instructions.

## Build and test modes

**Scope: the netlisp tool source only.** These modes drive the toolchain build
(`zig build …`, `prepare-release.sh`). They exist because the tool itself is a
compiled Zig program. Design-library changes under `projects/designs/` never
touch it — `netlisp` is a launcher over the already verified binary, so design
work never builds, never runs `zig`, and never runs `prepare-release.sh`.
Continue to the modes only when you are modifying the netlisp tool; otherwise
work in `projects/designs/` per its own `AGENTS.md`.

There is exactly one compiler: the official Zig snapshot pinned in
`.zigversion`, taken from `PATH`. Install it with `scripts/install-zig.sh
--link`; `build.zig` and both release scripts refuse to run on any other
version. See `ZIG_TOOLCHAIN.md`.

- **Normal inner loop (schematics, renderers, UI, parsers, serializers):** use
  `zig build --seed=1 -Doptimize=debug` (plain `zig build` is equivalent apart
  from its randomized cache key) and focused tests such as
  `zig build --seed=1 test -Dtest-filter='the behavior being changed'`.
  The pinned Zig 0.17 Debug build uses the fast self-hosted backend and is the
  default for both the application and tests. Follow a focused run with
  `zig build test-compile` when a whole-suite type-check is useful.
- **Dev servers, feature review, solver runs, and benchmarks:** build
  ReleaseSafe with the same compiler:
  `zig build --seed=1 -Doptimize=safe -p <own-prefix>`.
  This is the same artifact class production deploys (about 1.5x faster than
  Debug on the four-board workload) and compiles in well under a minute,
  because `build.zig` emits it through Zig's self-hosted x86-64 backend. Do NOT
  add `-Dllvm`: it is an opt-in escape hatch that trades a multi-minute compile
  for a faster binary, and no gate, release, or deploy path uses it. Give the
  build its own `--prefix` so it cannot overwrite the `zig-out/bin/netlisp` a
  running server or measurement is executing.
  Performance-sensitive focused tests may use
  `zig build --seed=1 test -Dtest-opt=safe -Dtest-filter='...'`.
- **Full tests:** `zig build --seed=1 test` compiles the test binary in Debug.
  Reserve an unfiltered full suite for the final release gate or for diagnosing
  a genuinely cross-cutting failure; use filters and `test-compile` while
  iterating.
- **Final release:** rebase onto current `main`, commit the clean tree, and run
  `.githooks/prepare-release.sh` once. It already runs the unfiltered Debug
  test suite and the sole ReleaseSafe build concurrently; never duplicate the
  ReleaseSafe build during development. Only that production executable is
  stripped; every internal Debug artifact keeps symbols. Its exact commit ID
  comes from validated deployment metadata rather than a compiled option, so
  non-compiler changes can reuse the verified output.

Backend flags are compiler flags, not Zig build-runner flags:
`zig build ... -fno-llvm` and `zig build ... -fllvm` are invalid. They may be
used with direct commands such as `zig build-exe`; from `zig build`, the
backend is chosen with `-Dllvm`. See `ZIG_TOOLCHAIN.md` and
`docs/build-system.md` under "Build modes and codegen backends" for commands
and measurements. Zig 0.17
build options use lowercase enum values (`debug`, `safe`, `fast`, `small`);
direct compiler `-O` values retain the traditional spellings.
