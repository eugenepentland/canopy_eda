#!/usr/bin/env bash
# Verify one exact commit, running its full tests and ReleaseSafe build in
# parallel, then publish the build as a hash-addressed deployment candidate.
set -uo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRED_ZIG="0.17.0-dev.1683+5ceec001b"
PRODUCTION_ZIG="/home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/zig"
REQUIRED_ZIG_SHA256="8f4af9650b5358abcdd8a283976d30b5dcdca2b400e44af25953b2e34101e7d4"
ARTIFACT_POLICY="release-safe-stripped-v1"
ZIG="${ZIG:-$PRODUCTION_ZIG}"
STRIP="${STRIP:-/usr/bin/strip}"
READELF="${READELF:-/usr/bin/readelf}"
ts() { date "+%Y-%m-%d %H:%M:%S"; }

# Start one verification job in its own process group. `setsid` is load-bearing:
# if the Debug suite fails, cancelling only this wrapper would orphan Zig/LLVM
# and leave the expensive production compile running in the background.
start_release_job() { # $1=status file, $2=log file, rest=command
  local status_file="$1" log_file="$2"
  shift 2
  setsid bash -c '
    status_file="$1"
    shift
    job_started="$(date +%s)"
    "$@"
    status=$?
    elapsed=$(( $(date +%s) - job_started ))
    printf "%s %s\n" "$status" "$elapsed" >"$status_file"
    exit "$status"
  ' release-job "$status_file" "$@" >"$log_file" 2>&1 &
  release_job_pid=$!
}

# Stop a whole release-job group, first allowing Zig to exit cleanly and then
# enforcing the cancellation if a child ignores TERM. The bounded wait keeps a
# failing test from turning into the same four-minute wait this path prevents.
cancel_release_job() { # $1=process-group leader
  local pid="$1" attempt=0
  kill -TERM -- "-$pid" 2>/dev/null || true
  while kill -0 -- "-$pid" 2>/dev/null && [ "$attempt" -lt 20 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 -- "-$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
}

valid_build_id() {
  local value="$1"
  [ "${#value}" -eq 9 ] || return 1
  case "$value" in *[!0-9a-f]*) return 1 ;; esac
}

if [ ! -x "$ZIG" ] || [ "$("$ZIG" version 2>/dev/null)" != "$REQUIRED_ZIG" ]; then
  echo "prepare-release: requires Zig $REQUIRED_ZIG; found '$("$ZIG" version 2>/dev/null || echo unavailable)' at $ZIG" >&2
  exit 1
fi
ZIG_SHA256="$(sha256sum "$ZIG" | awk '{print $1}')" || exit 1
if [ "$ZIG_SHA256" != "$REQUIRED_ZIG_SHA256" ]; then
  echo "prepare-release: compiler SHA-256 mismatch at $ZIG" >&2
  echo "  required: $REQUIRED_ZIG_SHA256" >&2
  echo "  found:    $ZIG_SHA256" >&2
  exit 1
fi
if ! command -v setsid >/dev/null 2>&1; then
  echo "prepare-release: requires setsid so a failed test can stop the complete ReleaseSafe process group" >&2
  exit 1
fi
if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
  echo "prepare-release: requires executable strip and readelf tools" >&2
  exit 1
fi

# Queue this whole preparation behind the machine-wide gate lock: two sessions
# preparing releases at once contend for disk and memory and roughly double
# each other's wall time (see scripts/gate.sh). Re-exec rather than wrap the
# body so the internal test/build concurrency below stays exactly as it is —
# that parallelism is deliberate (same commit, separate Zig caches) and only
# CROSS-session overlap is being removed. NETLISP_GATE_HELD is set by gate.sh once
# the lock is ours, so this cannot re-enter itself.
if [ "${NETLISP_GATE_SERIALIZE:-1}" != "0" ] && [ -z "${NETLISP_GATE_HELD:-}" ] && [ -x "$TOP/scripts/gate.sh" ]; then
  exec "$TOP/scripts/gate.sh" "$TOP/.githooks/prepare-release.sh" "$@"
fi

cd "$TOP" || { echo "prepare-release: cannot cd to $TOP" >&2; exit 1; }
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "prepare-release: $TOP is not a git worktree" >&2
  exit 1
}
HEAD_HASH="$(git rev-parse HEAD)" || exit 1
SHORT_HASH="${HEAD_HASH:0:9}"
HEAD_TREE="$(git rev-parse "HEAD^{tree}")" || exit 1
SHORT_TREE="$(printf '%.12s' "$HEAD_TREE")"
CANDIDATE_ROOT="$COMMON_DIR/release-candidates"
CANDIDATE="$CANDIDATE_ROOT/$HEAD_HASH"
FAILURE_ROOT="$COMMON_DIR/release-failures"
LOCK="$COMMON_DIR/release-prepare-$HEAD_HASH.lock"

candidate_valid() {
  [ -x "$CANDIDATE/install/bin/netlisp" ] || return 1
  [ -f "$CANDIDATE/commit" ] || return 1
  [ "$(cat "$CANDIDATE/commit")" = "$HEAD_HASH" ] || return 1
  [ -f "$CANDIDATE/tree" ] || return 1
  [ "$(cat "$CANDIDATE/tree")" = "$HEAD_TREE" ] || return 1
  [ -f "$CANDIDATE/verified" ] || return 1
  grep -qx 'pcb_editor_perf=passed' "$CANDIDATE/verified" || return 1
  grep -qx 'pcb_editor_invariants=passed' "$CANDIDATE/verified" || return 1
  [ -f "$CANDIDATE/zig-version" ] || return 1
  [ "$(cat "$CANDIDATE/zig-version")" = "$REQUIRED_ZIG" ] || return 1
  [ -f "$CANDIDATE/compiler-sha256" ] || return 1
  [ "$(cat "$CANDIDATE/compiler-sha256")" = "$ZIG_SHA256" ] || return 1
  [ -f "$CANDIDATE/build-id" ] || return 1
  [ "$(cat "$CANDIDATE/build-id")" = "$SHORT_HASH" ] || return 1
  [ -f "$CANDIDATE/artifact-policy" ] || return 1
  [ "$(cat "$CANDIDATE/artifact-policy")" = "$ARTIFACT_POLICY" ] || return 1
  [ -f "$CANDIDATE/netlisp.sha256" ] || return 1
  (cd "$CANDIDATE" && sha256sum --check --status netlisp.sha256)
}

# Is $1 a candidate that was VERIFIED for byte-identically this source tree?
# Every clause is load-bearing: an unverified or checksum-failing directory must
# never be adopted, and a tree mismatch must fall through to the full build.
candidate_tree_verified() {
  local dir="$1"
  [ -f "$dir/tree" ] || return 1
  [ "$(cat "$dir/tree")" = "$HEAD_TREE" ] || return 1
  [ -f "$dir/verified" ] || return 1
  grep -qx 'pcb_editor_perf=passed' "$dir/verified" || return 1
  grep -qx 'pcb_editor_invariants=passed' "$dir/verified" || return 1
  [ -f "$dir/zig-version" ] || return 1
  [ "$(cat "$dir/zig-version")" = "$REQUIRED_ZIG" ] || return 1
  [ -f "$dir/compiler-sha256" ] || return 1
  [ "$(cat "$dir/compiler-sha256")" = "$ZIG_SHA256" ] || return 1
  [ -f "$dir/build-id" ] || return 1
  valid_build_id "$(cat "$dir/build-id")" || return 1
  [ -f "$dir/artifact-policy" ] || return 1
  [ "$(cat "$dir/artifact-policy")" = "$ARTIFACT_POLICY" ] || return 1
  [ -x "$dir/install/bin/netlisp" ] || return 1
  [ -f "$dir/netlisp.sha256" ] || return 1
  (cd "$dir" && sha256sum --check --status netlisp.sha256)
}

# Checksum the staged binary and swap the staging directory into place. Shared
# by the full build and by adoption so both publish an identically-shaped
# candidate; the rename is atomic on this one filesystem.
publish_staging() {
  [ -x "$staging/install/bin/netlisp" ] || return 1
  [ -f "$staging/commit" ] || return 1
  [ "$(cat "$staging/commit")" = "$HEAD_HASH" ] || return 1
  [ -f "$staging/tree" ] || return 1
  [ "$(cat "$staging/tree")" = "$HEAD_TREE" ] || return 1
  [ -f "$staging/verified" ] || return 1
  grep -qx 'pcb_editor_perf=passed' "$staging/verified" || return 1
  grep -qx 'pcb_editor_invariants=passed' "$staging/verified" || return 1
  [ -f "$staging/compiler-sha256" ] || return 1
  [ "$(cat "$staging/compiler-sha256")" = "$ZIG_SHA256" ] || return 1
  [ -f "$staging/build-id" ] || return 1
  valid_build_id "$(cat "$staging/build-id")" || return 1
  [ -f "$staging/artifact-policy" ] || return 1
  [ "$(cat "$staging/artifact-policy")" = "$ARTIFACT_POLICY" ] || return 1
  (cd "$staging" && sha256sum install/bin/netlisp >netlisp.sha256) || return 1
  if [ -e "$CANDIDATE" ]; then
    mv "$CANDIDATE" "$CANDIDATE.invalid.$(date +%s).$$" || return 1
  fi
  mv "$staging" "$CANDIDATE" || return 1
  staging=""
}

# Republish an already-verified candidate under THIS commit.
adopt_candidate() {
  local src="$1" src_commit src_short
  src_commit="$(cat "$src/commit" 2>/dev/null || true)"
  [ -n "$src_commit" ] || src_commit="${src##*/}"
  src_short="$(printf '%.12s' "$src_commit")"

  staging="$(mktemp -d "$CANDIDATE_ROOT/.${HEAD_HASH}.XXXXXX")" || return 1
  # Only the immutable build output is shared — hardlinked when the filesystem
  # allows it, copied otherwise. Every metadata file below is written FRESH
  # rather than edited in place, so stamping this candidate's provenance can
  # never reach back through a link and rewrite the source candidate's own.
  cp -al "$src/install" "$staging/install" 2>/dev/null ||
    cp -a "$src/install" "$staging/install" || return 1
  printf '%s\n' "$HEAD_HASH" >"$staging/commit" || return 1
  printf '%s\n' "$HEAD_TREE" >"$staging/tree" || return 1
  printf '%s\n' "$REQUIRED_ZIG" >"$staging/zig-version" || return 1
  printf '%s\n' "$ZIG_SHA256" >"$staging/compiler-sha256" || return 1
  printf '%s\n' "$SHORT_HASH" >"$staging/build-id" || return 1
  printf '%s\n' "$ARTIFACT_POLICY" >"$staging/artifact-policy" || return 1
  {
    cat "$src/verified"
    printf 'adopted_from=%s\n' "$src_commit"
  } >"$staging/verified" || return 1
  {
    cat "$src/timing" 2>/dev/null || true
    printf 'adopted_from=%s\nadopted_at=%s\n' "$src_commit" "$(ts)"
  } >"$staging/timing" || return 1
  publish_staging || return 1

  echo "[$(ts)] prepare-release: adopted verified candidate for identical tree" \
    "$SHORT_TREE (built for $src_short)"
  echo "  $CANDIDATE/install/bin/netlisp"
}

dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
  echo "prepare-release: refusing dirty worktree; commit generated templates and source first:" >&2
  printf '%s\n' "$dirty" >&2
  exit 1
fi

mkdir -p "$CANDIDATE_ROOT" "$FAILURE_ROOT"
exec 8>"$LOCK"
flock 8

if candidate_valid; then
  echo "prepare-release: $SHORT_HASH already has a verified candidate"
  exit 0
fi

staging=""
cleanup() {
  if [ -n "${staging:-}" ] && [ -d "$staging" ]; then
    rm -rf -- "$staging"
  fi
}
trap cleanup EXIT

# --- tree-keyed reuse -------------------------------------------------------
# The production binary is a pure function of the source TREE (plus toolchain),
# and a --no-ff merge of an up-to-date branch has a tree byte-identical to the
# branch tip it merges — as does an amended commit. So before doing any work,
# look for a candidate already verified for THIS tree and republish its
# artifacts under this commit, turning a ~6-minute rebuild into a copy. Finding
# nothing simply falls through to the full build below, which is the safety
# property: reuse can only ever skip work that was already done for this exact
# source.
adopt_source=""
for dir in "$CANDIDATE_ROOT"/*; do
  [ -d "$dir" ] || continue
  [ "$dir" = "$CANDIDATE" ] && continue
  case "${dir##*/}" in *.invalid.*) continue ;; esac
  if candidate_tree_verified "$dir"; then
    adopt_source="$dir"
    break
  fi
done
if [ -n "$adopt_source" ]; then
  if adopt_candidate "$adopt_source"; then
    exit 0
  fi
  echo "prepare-release: adoption from $adopt_source failed; falling back to a full build" >&2
  cleanup
  staging=""
fi

staging="$(mktemp -d "$CANDIDATE_ROOT/.${HEAD_HASH}.XXXXXX")" || exit 1

# --- tree-keyed Zig caches ---------------------------------------------------
# One local cache PER SOURCE TREE, never shared across trees. The old shared
# release-cache/{test,build} sham-verified wrong-tree binaries three times
# (last 2026-08-12; the *.invalid-cache-audit-* siblings are the quarantined
# evidence): Zig's whole-compilation manifest is keyed by the option set plus
# the module-root path strings — five worktree-relative spellings, identical
# from every worktree — while every @import/@embedFile-DISCOVERED input (478 of
# 1181 entries on this binary) is recorded by ABSOLUTE path into the worktree
# that ran the build. A run for a DIFFERENT tree therefore finds the previous
# tree's manifest, re-validates those files against the ORIGINAL worktree —
# still on disk, still unchanged — never opens its own copies, and re-emits the
# previous tree's binary as a 0-second "verified" candidate. Keying the cache
# directory by tree hash makes every manifest inside certify this tree's
# content, so a hit can only ever reproduce a binary of this exact tree.
TREE_CACHE="$COMMON_DIR/release-cache/tree-$HEAD_TREE-zig-$ZIG_SHA256"
# The TEST cache is wiped besides: a warm run step would replay "success"
# without executing a single test (and without the counting-runner line the
# check after the jobs demands). Verification means the suite RUNS, every time.
rm -rf "$TREE_CACHE/test"
mkdir -p "$staging/install" "$TREE_CACHE/test" "$TREE_CACHE/build" || exit 1

# Bound the disk the per-tree caches take: keep the newest three, drop the
# rest. Touches only tree-* names — never the quarantined *.invalid-* audit
# dirs — and never this run's own; prepare-release runs serialize on the gate
# lock, so no other run's cache is live while this prunes.
ls -1dt "$COMMON_DIR"/release-cache/tree-* 2>/dev/null | tail -n +4 |
  while IFS= read -r stale_cache; do
    [ "$stale_cache" = "$TREE_CACHE" ] && continue
    rm -rf -- "$stale_cache"
  done

started="$(date +%s)"
echo "[$(ts)] prepare-release: $SHORT_HASH — generating templates once"
if ! "$ZIG" build --seed=1 templates; then
  echo "prepare-release: template generation failed" >&2
  exit 1
fi

dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
  echo "prepare-release: generated templates are stale; commit these updates before release:" >&2
  printf '%s\n' "$dirty" >&2
  exit 1
fi

echo "[$(ts)] prepare-release: running the whole-tree Guardian gate"
if ! "$ZIG" build --seed=1 -Dtemplates-prepared=true guardian -- all . --gate --full; then
  echo "prepare-release: Guardian gate failed" >&2
  exit 1
fi

echo "[$(ts)] prepare-release: starting full tests and ReleaseSafe build together"
jobs_started="$(date +%s)"
start_release_job "$staging/test.status" "$staging/test.log" \
  env GUARDIAN_SKIP_CHECKS=1 ZIG_LOCAL_CACHE_DIR="$TREE_CACHE/test" \
  "$ZIG" build --seed=1 -Dtemplates-prepared=true test
test_pid=$release_job_pid

start_release_job "$staging/build.status" "$staging/build.log" \
  env GUARDIAN_SKIP_CHECKS=1 ZIG_LOCAL_CACHE_DIR="$TREE_CACHE/build" \
  "$ZIG" build --seed=1 -Dtemplates-prepared=true -Doptimize=safe --prefix "$staging/install"
build_pid=$release_job_pid

wait "$test_pid"
test_status=$?
build_cancelled=0
if [ "$test_status" -ne 0 ] && kill -0 -- "-$build_pid" 2>/dev/null; then
  echo "[$(ts)] prepare-release: tests failed; stopping the concurrent ReleaseSafe build" >&2
  build_cancelled=1
  cancel_release_job "$build_pid"
fi
wait "$build_pid"
build_status=$?
jobs_elapsed=$(( $(date +%s) - jobs_started ))
if [ -f "$staging/test.status" ]; then
  read -r _ test_elapsed <"$staging/test.status"
else
  test_elapsed=$jobs_elapsed
fi
if [ -f "$staging/build.status" ]; then
  read -r _ build_elapsed <"$staging/build.status"
else
  build_elapsed=$jobs_elapsed
fi

if [ "$test_status" -ne 0 ] || [ "$build_status" -ne 0 ]; then
  echo "prepare-release: verification failed:" >&2
  if [ "$test_status" -ne 0 ]; then
    echo "  test ($test_status after ${test_elapsed}s)" >&2
    tail -n 80 "$staging/test.log" >&2
  fi
  if [ "$build_cancelled" -eq 1 ]; then
    echo "  build (cancelled after ${build_elapsed}s because tests failed)" >&2
  elif [ "$build_status" -ne 0 ]; then
    echo "  build ($build_status after ${build_elapsed}s)" >&2
    tail -n 80 "$staging/build.log" >&2
  fi
  failed="$FAILURE_ROOT/$HEAD_HASH-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$staging" "$failed"
  staging=""
  echo "prepare-release: full logs kept at $failed" >&2
  exit 1
fi

# The self-hosted backend does not currently honor Module.strip for this ELF,
# so enforce the artifact policy at the release boundary and verify it. This is
# deliberately after both jobs pass and before the checksum is recorded.
strip_failed=0
"$STRIP" --strip-all "$staging/install/bin/netlisp" || strip_failed=1
section_headers="$("$READELF" -S "$staging/install/bin/netlisp")" || strip_failed=1
if [ "$strip_failed" -ne 0 ] ||
  printf '%s\n' "$section_headers" | grep -qE '\.(debug_|symtab)'; then
  echo "prepare-release: failed to produce a stripped production executable" >&2
  failed="$FAILURE_ROOT/$HEAD_HASH-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$staging" "$failed"
  staging=""
  echo "prepare-release: full logs kept at $failed" >&2
  exit 1
fi

# The full test suite proves renderer semantics, but only a real browser can
# prove that Barracuda's current RF-heavy editor remains interactive. Run the
# deterministic DPR-2 Canvas + retained-WebGPU zoom gate against the exact
# stripped candidate before it becomes adoptable or deployable. Resolve the
# shared designs checkout from a feature worktree the same way perf_gate.sh
# does; a release host without the workload fails closed.
PERF_PROJECT_DIR="${NETLISP_PERF_PROJECT_DIR:-$TOP/projects/designs}"
if [ ! -d "$PERF_PROJECT_DIR/src" ]; then
  shared_checkout="${COMMON_DIR%/.git}"
  if [ -d "$shared_checkout/projects/designs/src" ]; then
    PERF_PROJECT_DIR="$shared_checkout/projects/designs"
  fi
fi
if [ ! -d "$PERF_PROJECT_DIR/src" ]; then
  echo "prepare-release: Barracuda performance workload not found at $PERF_PROJECT_DIR" >&2
  exit 1
fi
echo "[$(ts)] prepare-release: running deterministic Barracuda editor zoom gate"
editor_perf_started="$(date +%s)"
editor_perf_attempt=1
editor_perf_attempts="${NETLISP_EDITOR_PERF_ATTEMPTS:-3}"
case "$editor_perf_attempts" in
  ''|*[!0-9]*) echo "prepare-release: NETLISP_EDITOR_PERF_ATTEMPTS must be a positive integer" >&2; exit 1 ;;
esac
if [ "$editor_perf_attempts" -lt 1 ]; then
  echo "prepare-release: NETLISP_EDITOR_PERF_ATTEMPTS must be a positive integer" >&2
  exit 1
fi
editor_perf_passed=0
while [ "$editor_perf_attempt" -le "$editor_perf_attempts" ]; do
  if [ "${NETLISP_PERF_HOST_WAIT:-1}" != "0" ]; then
    echo "[$(ts)] prepare-release: waiting for a quiet host before editor perf attempt $editor_perf_attempt/$editor_perf_attempts"
    if ! node scripts/perf_host_idle.js --wait; then
      echo "prepare-release: no quiet host window became available for the editor performance gate" >&2
      break
    fi
  fi
  attempt_log="$staging/pcb-editor-perf.attempt-$editor_perf_attempt.log"
  if node scripts/pcb_editor_perf/run.js --project-dir "$PERF_PROJECT_DIR" \
    --binary "$staging/install/bin/netlisp" --reps "${NETLISP_EDITOR_PERF_REPS:-3}" \
    >"$attempt_log" 2>&1; then
    cp "$attempt_log" "$staging/pcb-editor-perf.log"
    editor_perf_passed=1
    break
  fi
  echo "prepare-release: Barracuda editor zoom attempt $editor_perf_attempt/$editor_perf_attempts failed:" >&2
  tail -n 120 "$attempt_log" >&2
  # Infrastructure or renderer-contract failures are deterministic and must
  # not be hidden by retries. Only a measured budget miss gets another quiet
  # host window, which is the failure class susceptible to machine contention.
  if ! grep -q 'PCB editor zoom regression:' "$attempt_log"; then
    break
  fi
  if [ "$editor_perf_attempt" -ge "$editor_perf_attempts" ]; then
    break
  fi
  editor_perf_attempt=$((editor_perf_attempt + 1))
  echo "[$(ts)] prepare-release: timing-only miss; retrying after host contention clears" >&2
done
if [ "$editor_perf_passed" -ne 1 ]; then
  echo "prepare-release: Barracuda editor zoom gate failed after $editor_perf_attempt attempt(s)" >&2
  failed="$FAILURE_ROOT/$HEAD_HASH-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$staging" "$failed"
  staging=""
  echo "prepare-release: full logs kept at $failed" >&2
  exit 1
fi
editor_perf_elapsed=$(( $(date +%s) - editor_perf_started ))

# The editor's six state-ownership invariants: a saved-layout row owning its
# copper, a queued autosave abandoning a changed target, undo dropping the
# copper selection, a rev-bumped analysis answer being re-aimed, a reattached
# route recording its undo step, and a 409 raising a visible conflict. Each one
# is a bug that shipped, and `pcb_board.js` has no other behavioural gate —
# `node --check` and static_assets' substring markers both pass a board that
# silently loses an edit. `--no-substitute` is required: the candidate EMBEDS
# its assets at build time, so the probe must exercise the binary's own copy
# rather than a working tree that may have moved on.
echo "[$(ts)] prepare-release: running PCB editor state-ownership invariants"
editor_inv_started="$(date +%s)"
if ! node scripts/pcb_editor_invariants/run.js \
  --binary "$staging/install/bin/netlisp" --no-substitute \
  >"$staging/pcb-editor-invariants.log" 2>&1; then
  echo "prepare-release: PCB editor invariant probe failed:" >&2
  tail -n 120 "$staging/pcb-editor-invariants.log" >&2
  failed="$FAILURE_ROOT/$HEAD_HASH-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$staging" "$failed"
  staging=""
  echo "prepare-release: full logs kept at $failed" >&2
  exit 1
fi
editor_inv_elapsed=$(( $(date +%s) - editor_inv_started ))

# Fail closed: a green test job must have EXECUTED the suite. Guardian's
# counting test runner prints this line before the first test; a log without
# it means the run step was replayed from a cache and nothing actually ran —
# the exact signature of the 2026-08-12 sham candidates.
if ! grep -qE 'guardian/test: [0-9]+ test\(s\) selected' "$staging/test.log"; then
  echo "prepare-release: test job exited 0 without executing the suite" >&2
  echo "  no 'guardian/test: N test(s) selected' line in test.log — a cached run step is not a verification" >&2
  failed="$FAILURE_ROOT/$HEAD_HASH-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$staging" "$failed"
  staging=""
  echo "prepare-release: full logs kept at $failed" >&2
  exit 1
fi

printf '%s\n' "$HEAD_HASH" >"$staging/commit"
# The tree this binary was built from — the key another commit adopts it by.
printf '%s\n' "$HEAD_TREE" >"$staging/tree"
printf '%s\n' "$REQUIRED_ZIG" >"$staging/zig-version"
printf '%s\n' "$ZIG_SHA256" >"$staging/compiler-sha256"
printf '%s\n' "$SHORT_HASH" >"$staging/build-id"
printf '%s\n' "$ARTIFACT_POLICY" >"$staging/artifact-policy"
printf 'guardian=passed\ntest=passed\nbuild=passed\npcb_editor_perf=passed\npcb_editor_invariants=passed\n' >"$staging/verified"
printf 'test_seconds=%s\nbuild_seconds=%s\npcb_editor_perf_seconds=%s\npcb_editor_invariants_seconds=%s\nwall_seconds=%s\n' \
  "$test_elapsed" "$build_elapsed" "$editor_perf_elapsed" "$editor_inv_elapsed" "$(( $(date +%s) - started ))" >"$staging/timing"

if ! publish_staging; then
  echo "prepare-release: could not publish the candidate for $SHORT_HASH" >&2
  exit 1
fi
echo "[$(ts)] prepare-release: candidate ready for $SHORT_HASH (tree $SHORT_TREE)"
echo "  tests: ${test_elapsed}s; build: ${build_elapsed}s; editor perf: ${editor_perf_elapsed}s; wall: $(( $(date +%s) - started ))s"
echo "  $CANDIDATE/install/bin/netlisp"
