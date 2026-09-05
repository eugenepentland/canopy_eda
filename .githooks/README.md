# Git hooks and the production deploy

Everything in this directory is **tracked**, so a fresh clone gets the whole
setup. Point git at it and (optionally) turn on production deploys:

```sh
.githooks/install.sh            # hooks only — safe on any clone
.githooks/install.sh --deploy   # + prod auto-deploy + server/checkpoint units
.githooks/install.sh --check    # report what is/isn't installed
```

`install.sh` sets `core.hooksPath` to this directory, so `.git/hooks/` is no
longer where git looks for hooks.

## Worktree and production Zig caches

The `post-checkout` hook gives every newly-created worktree its own
`.zig-cache`. Zig's global cache remains shared, so downloaded dependencies and
immutable compiler artifacts are reused without mixing build-root manifests
from concurrent worktrees. The hook also migrates the exact shared-cache
symlink created by its previous implementation; custom cache links are left
alone.

After a feature is merged into `main`, `post-merge` clears the `.zig-cache` in
the worktree parked at the merged feature tip. It requires that worktree to be
clean, skips locked worktrees and custom cache symlinks, and leaves the source,
worktree registration, and branch intact. This uses merge rather than commit as
the completion boundary so WIP commits and pre-release fixes retain their warm
development cache. To preview or reclaim caches from older clean worktrees
whose commits are already in `main`, run:

```sh
.githooks/prune-worktree-caches.sh --all --dry-run
.githooks/prune-worktree-caches.sh --all
```

The script also runs `git worktree prune`, which removes stale administrative
records for directories that are already gone; it never deletes a live
worktree or branch. Retire those separately with `git worktree remove` once no
agent or shell still uses them.

The committed `post-merge` and `post-commit` bridge hooks forward to matching
machine-local hooks under `.git/hooks/`. Release preparation gives the parallel
test and production build separate local caches under
`.git/release-cache/tree-<treehash>-zig-<compiler-sha256>/{test,build}` — keyed
by both the **source tree and exact compiler binary**, never shared across
either boundary. A shared release cache sham-verified wrong-tree
binaries three times (last 2026-08-12): Zig's compilation manifests key on the
module-root path spellings, not the tree, and record `@import`/`@embedFile`
inputs by absolute path into the builder's worktree, so a different tree's run
re-validated the *old* worktree's files and re-emitted its binary in seconds.
The test cache is additionally wiped before each run and `prepare-release.sh`
refuses a test job whose log lacks the counting runner's
`guardian/test: N test(s) selected` line, so a cached run step can never pass
for a verification. Old tree caches beyond the newest three are pruned; the
immutable global Zig cache remains shared. `post-merge` records the queued HEAD in
`.git/deploy-on-merge.log` synchronously before the machine-local hook detaches
the build, so a missing dispatch is distinguishable from a slow build.

Do not clear a cache while its owning build is running. Any of these derived
caches can be removed when idle; Zig recreates it on the next build.

## Why deploy stays opt-in per machine

Merging into `main` deploys a verified candidate and restarts the
`netlisp.service` systemd unit.
That is right on the production box and wrong on a laptop clone, so the
machine-local launchers under `.git/hooks/` are the per-machine switch:

```
git merge on main
  -> .githooks/post-merge         tracked bridge (exports ZIG_LOCAL_CACHE_DIR)
    -> .git/hooks/post-merge      machine-local launcher — PRESENT ONLY IF YOU
                                  RAN install.sh --deploy. This file's existence
                                  IS the "this machine deploys" flag.
      -> .githooks/deploy-prod.sh tracked; all the real logic, run detached
```

`install.sh --uninstall-deploy` removes the launchers and stops deploying here;
the hooks and systemd unit are left alone.

## prepare-release.sh — overlap the expensive jobs

Run this from a clean, committed feature worktree before merging:

```sh
.githooks/prepare-release.sh
```

It generates and checks the committed templates, runs the whole-tree Guardian
gate once, then starts the self-hosted Debug unit suite and the repository's
sole netlisp self-hosted ReleaseSafe build together with separate local Zig caches.
It uses the one pinned compiler from `PATH` (`$ZIG` overrides it). That
compiler ships LLVM, but `build.zig` defaults `-Dllvm` off, so this artifact —
like every other optimized build here — is emitted by the self-hosted backend
in well under a minute. Only this executable is stripped. Both jobs must pass. Success atomically publishes an
exact-commit candidate under `.git/release-candidates/<commit>/`, including the
binary checksum, exact Zig version, compiler-binary SHA-256, runtime build ID,
artifact policy, timings, and full job logs. That compiler SHA-256 is a
fingerprint, not a second pin: tree adoption requires both the same source tree
and the same compiler binary, so two builds of the same Zig version cannot
reuse each other's artifacts. Every build uses the
repository's fixed `--seed=1`, keeping unchanged test runs cacheable on Zig
0.17. The script rejects any compiler whose `zig version` differs from
`.zigversion` (see `ZIG_TOOLCHAIN.md`). Failure publishes nothing and keeps the
failed logs under `.git/release-failures/`.

Each parallel job owns a separate process group. If the Debug suite fails,
`prepare-release` immediately terminates the complete ReleaseSafe group instead
of waiting for the build to finish an artifact that cannot be published. It
gives
the group two seconds to handle `TERM`, then enforces cancellation with `KILL`;
both job logs and the failed staging directory are retained as usual. Exercise
this path without compiling netlisp using `scripts/test_prepare_release_fail_fast.sh`.

A candidate also records the source **tree** it was verified for, and that key
is checked before any work starts: a commit whose tree already has a verified,
checksum-passing candidate republishes those artifacts under its own sha in
milliseconds instead of rebuilding. This is what makes a `--no-ff` merge of a
prepared, up-to-date branch deploy in seconds — the merge commit's tree is
byte-identical to the branch tip's. A tree that matches nothing falls through
to the full build above, which is the safety property.

The commit ID is deliberately not compiled into the executable. Deployment
validates the candidate's nine-character `build-id` and writes it atomically to
`.git/netlisp-deploy-id`, which the application reads when stamping an artifact.
Local Debug runs fall back to the checkout's git metadata. This keeps a docs- or
hook-only commit from invalidating the application cache.

The build jobs use `-Dtemplates-prepared=true` only after the script has run
`zig build --seed=1 templates` and proved that generation left the commit clean. This
avoids two parallel Zig processes writing the same generated source files.

## deploy-prod.sh — exact candidate, health check and rollback

Deployment validates the candidate's commit identity, runtime build ID,
compiler SHA-256, artifact policy, and executable SHA-256 before installing it
by rename. If a merge produced
a new commit with no candidate, the hook runs `prepare-release.sh` on main first. A **failed test, gate, build,
or candidate validation never restarts prod**, so the service keeps running its
previous binary.

After installing the verified candidate it restarts the unit and probes the live server
(`HEALTH_URLS`, default: `/.well-known/oauth-protected-resource` must return
200 and `/` must return 302, the ward login redirect) for up to
`HEALTH_TIMEOUT` seconds:

- **Healthy** → the binary is copied to `.git/deploy-lastgood-netlisp`, its ID
  to `.git/deploy-lastgood-id`, and the deployed commit to
  `.git/deploy-last-hash`. The same verified binary is also pre-warmed into
  `projects/designs/.netlisp-bin/netlisp` with the paired netlisp commit written to
  `projects/designs/.git/netlisp-deploy-id`, so the schematic-design-agent
  folder (whose tracked `netlisp` is a launcher, not a binary) stays
  self-contained and on the current build — best-effort, never able to fail the
  deploy.
- **Unhealthy** → the bad binary is kept at `.git/deploy-failed-netlisp` for
  triage, the last known-good binary and its paired runtime ID are restored,
  and the unit is restarted on it. `deploy-last-hash` is **not** written, so
  `wait-deploy.sh` correctly reports a rolled-back deploy as a failure (exit 1).

The rollback installs the old binary **by rename**, never `cp` over it: the
failed binary is still running at that point and writing to a running
executable fails with `ETXTBSY`.

Because state lives under `.git/` it is machine-local and never committed.

## Coalesced deploys — merge and it builds, no hold period

A merge into main queues through `.git/deploy-pending`
(`<head> <epoch> <window>`) at **window 0** and deploys **immediately**: the
arming run (already detached from the merge by the launcher) execs the worker
(`deploy-debounce.sh`) on the spot, so an idle box starts building at once —
and a merge landing while a deploy is already building queues on the deploy
lock and starts the moment the running one finishes. No timer tick, no settle
delay, no `Deploy: skip` hold.

**The `Deploy: skip` trailer is retired.** A merge that still carries it (out
of muscle memory) is logged with a note and deploys like any other — the
trailer never silently holds prod back again. If batching ever matters more
than immediacy, `DEPLOY_SETTLE_SECONDS>0` (in the merging shell) arms a
positive window instead, deployed by the timer once it has sat untouched that
long; everything below about positive windows exists for that knob and for
legacy markers.

**Every further merge rewrites the marker**, and the queue is what collapses
cost: N merges landing while one deploy builds cost at most ONE follow-up
deploy of the accumulated head, never N — the expensive parts being
`prepare-release.sh` (the machine-wide `/tmp/netlisp-gate.lock` for ~7 minutes,
which every other session queues behind) and the prod restart. The marker
records the head that armed it only for the log: the deploy always targets
whatever main's HEAD is when it runs, one build covering everything that
accumulated.

- **A merge landing while a deploy is BUILDING queues instantly.** Arming
  never waits on the deploy lock (`.git/deploy-on-merge.lock` — only real
  deploys serialize on it), so the merge returns at once; its worker then
  waits its turn on the lock and, on acquiring it, **re-checks** whether the
  head it wants is already live (the deploy that just finished may have
  carried it) and exits as a no-op instead of rebuilding. A finished deploy
  settles only markers **covered** by what it shipped (ancestry-checked —
  `settle_pending`), never one a newer merge armed; and the worker LOOPS
  after each successful deploy, so a due marker re-armed mid-build chains
  build-after-build with no gap.
- The worker runs the deploy with `DEPLOY_RUN_NOW=1`; without it the inner
  `deploy-prod.sh` would arm-and-exec its way back through the worker.
- The marker is disarmed **before** the deploy runs, so a deploy still going
  at the next timer tick cannot be started twice. The cost of that order is
  that a **failed** deploy is not retried automatically — deliberate, since a
  broken main would fail identically on every retry while holding the gate
  lock. The failed head is recorded in `.git/deploy-failed-head` (the
  **HELD** state; prod stays on the rolled-back binary): `install.sh --check`
  reports it loudly with the retry command, `deploy-debounce.sh --now` clears
  it (the explicit retry), and any later successful deploy ends the hold.
- **The timer is the backstop, not the path.** Window 0 needs no timer — the
  arming run is its own worker — but `netlisp-deploy-debounce.timer` (once a
  minute) picks a queued marker back up after a crash or reboot mid-build,
  and is the deployer for positive-window markers. Arming a POSITIVE window
  with no active timer would leave a marker nothing ever comes back for, so
  such a merge deploys immediately instead, with a WARN naming the fix
  (`install.sh --deploy` enables the timer). Set `DEPLOY_DEBOUNCE_TIMER=''`
  if you drive `deploy-debounce.sh` from something other than this unit — a
  cron entry, a test harness — to turn that check off.
- `wait-deploy.sh` waits through a queued deploy and its success test is
  **ancestry, not equality**: a merge landing after yours re-arms the marker
  and one deploy ships both, so your head going live *inside* a newer head is
  a success, not a timeout. It exits **2** only when a covering marker's
  window ends beyond the wait's own deadline — a knob/legacy hold, the
  exception now.
- `install.sh --check` reports the whole state machine: **QUEUED** (armed
  marker, its window and time left, and **the commits it would ship**),
  **RUNNING** (the deploy lock is held right now; a queued marker shows as
  queued *behind* it), and **HELD** (the failed-head hold). The commit list
  baseline is `.git/deploy-last-hash`, written only after a health check
  passes, so it is what prod is RUNNING versus what is armed — a rolled-back
  deploy correctly leaves its commits shown as still pending:

  ```
    • deploy QUEUED at 870236ab1 — due in 94s (window 120s)
        3 commit(s) waiting on top of live b3cabe1f6, newest first:
          870236ab  Merge: defer prod deploys by default
          dafa4af2  Merge: the client DRC reads the two design-rule keys it was dropping
          ce59fca4  Merge: route-session reads the lexical PCB blob, not window.PCB
  ```

  The walk is `--first-parent`, because main advances by `--no-ff` merges and
  one line per merge is the summary; it caps at ten with an "… and N more"
  tail. When the two commits are unrelated (a reset, a force-push, a rollback
  onto another line) it says the history diverged rather than printing a
  plausible-looking wrong set, and a marker naming a commit this checkout does
  not have is reported without aborting the rest of the report.
- `install.sh --uninstall-deploy` stops the timer and discards the marker and
  any failed-head hold along with the launchers.

A marker still pending (the knob, a legacy marker, or a queued mid-build
merge after a crash) deploys on demand with:

```sh
.githooks/deploy-debounce.sh --now
```

`scripts/test_deploy_debounce.sh` exercises all of this (immediate deploy,
the retired trailer's note, the settle knob's positive windows, instant
queue-behind-the-lock with the one-build coalesce proof, the mid-deploy
re-arm + worker loop, the failed-head hold and `--now` retry, corrupt/legacy/
future markers, dry run, `wait-deploy` ancestry, `--check` states) in a
throwaway repo with the build/restart tail stubbed. Run it after touching any
of the scripts.

## The systemd unit

`netlisp.service.in` is the tracked template; `install.sh --deploy` renders it
to `~/.config/systemd/user/netlisp.service` with `@TOP@`/`@PORT@` substituted.
The deploy script writes the exact runtime build ID beside its rollback state
under `.git/`; a legacy binary with no paired ID continues using its embedded
stamp during rollback.

It uses **`Restart=always`, not `on-failure`** — systemd counts termination by
`SIGTERM`/`SIGINT`/`SIGHUP`/`SIGPIPE` as a *clean* exit, so under `on-failure` a
`pkill netlisp` or `fuser -k 7050/tcp` (a common way to free the port for a
worktree server) left production dead and never restarted. `always` still
honours an explicit `systemctl --user stop`.

### Quiet-period design checkpoints

Production disables per-MCP git commits and enables
`netlisp-designs-checkpoint.timer`. The timer checks the live
`projects/designs` checkout once per minute. A batch is committed only after
its exact file-content fingerprint has remained unchanged for five minutes, so
browser, MCP, and direct filesystem edits share one backup path without
committing files mid-write. Checkpoints run only on that checkout's `main`
branch, skip ignored/history/backup artifacts and Git hooks, never push, and
commit only the dirty paths in the stable batch; unrelated staged paths remain
untouched.

Set `DESIGNS_CHECKPOINT_QUIET_SECONDS` when running `install.sh --deploy` to
change the default 300-second quiet period. Run a manual observation/checkpoint
cycle with:

```sh
scripts/checkpoint-designs.py --project-dir projects/designs --verbose
# Once the batch is observed, bypass the remaining wait if an immediate backup
# is wanted:
scripts/checkpoint-designs.py --project-dir projects/designs --force
```

## pre-commit

`pre-commit` is managed by `guardian-check`, not by `install.sh` — it runs the
fast 67-check gate on every commit. If it is missing, build `guardian-zig` and
let guardian reinstall it.
