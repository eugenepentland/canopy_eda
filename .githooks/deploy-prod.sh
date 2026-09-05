#!/usr/bin/env bash
# Install an exact-commit verified ReleaseSafe candidate, restart the prod
# systemd service, health-check it, and roll back to the last known-good binary
# if the new one is unhealthy. Missing candidates are prepared on demand by
# running the full tests and build concurrently.
#
# TRACKED FILE — this is the source of truth for the production deploy. It is
# invoked through the hook chain:
#   git merge on main
#     -> .githooks/post-merge          (tracked bridge; exports ZIG_LOCAL_CACHE_DIR)
#       -> .git/hooks/post-merge       (machine-local opt-in launcher, written by
#                                       .githooks/install.sh; absent on a clone
#                                       that should not deploy)
#         -> .githooks/deploy-prod.sh  (this script, detached — ARMS the marker)
#           -> .githooks/deploy-debounce.sh  (timer-driven worker — re-invokes
#                                             this script to actually deploy)
# A bare hand run arms the short window like any merge; to deploy NOW by hand
# use .githooks/deploy-debounce.sh --now.
#
# Build mode: ReleaseSafe (switched from ReleaseSmall 2026-07-11, wave-3
# cast-safety audit) — keeps bounds/overflow/cast safety checks in the prod
# server, so corrupt or hostile input panics cleanly (systemd restarts in ~2s)
# instead of silently corrupting board data. The production executable is
# stripped to reduce compile/link wall and size without disabling those checks.
#
# - Real deploys are serialized with flock, one-at-a-time from the final source
#   (never mid-compile-with-changing-files); ARMING never waits on the lock, so
#   a merge landing mid-build queues instantly instead of blocking.
# - Only restarts prod after the exact commit passes BOTH the full suite and
#   ReleaseSafe build; a failed job leaves the running service untouched.
# - HEALTH CHECK + ROLLBACK (2026-07-25): after the restart the script probes
#   the live server. If it never comes up healthy within HEALTH_TIMEOUT, the
#   previous known-good binary is restored and prod is restarted on it — so a
#   bad merge degrades to "prod stays on the old build" instead of "prod is 502
#   until a human notices".
#     * .git/deploy-lastgood-netlisp — copy of the newest binary that PASSED a
#       health check. This is what a rollback restores.
#     * .git/deploy-lastgood-id      — runtime build ID paired with that binary.
#     * .git/deploy-failed-netlisp   — the binary that failed, kept for triage.
#   deploy-last-hash is written ONLY after the health check passes, so
#   wait-deploy.sh reports a rolled-back deploy as a failure (exit 1).
# - Appends a timestamped record to .git/deploy-on-merge.log.
# - DEPLOY_DRY_RUN=1 logs what it would do without building/restarting.
# - COALESCED DEPLOYS (2026-08-14): a merge never builds inline — it arms
#   .git/deploy-pending ("<head> <epoch> <window>") and the queue does the
#   rest, with NO hold period: the merge takes window 0 and this
#   (launcher-detached) run execs the worker (.githooks/deploy-debounce.sh)
#   on the spot, so an idle box builds immediately, and a merge landing while
#   a deploy is already building queues on the flock below and starts the
#   moment the running one finishes (the queued deploy re-checks after
#   acquiring the lock and no-ops if its head already shipped — so N merges
#   during one build cost at most ONE follow-up deploy). Each further merge
#   REWRITES the marker. What the queue collapses is prepare-release.sh — the
#   machine-wide /tmp/netlisp-gate.lock for ~7 min — plus the prod restart itself.
#   The `Deploy: skip` trailer is RETIRED: it is logged as a note and the
#   merge deploys like any other. DEPLOY_SETTLE_SECONDS>0 restores a settle
#   delay (timer-deployed) if batching ever matters more than immediacy again.
# - A deploy that FAILS (build, candidate, install, or health check) records
#   its head in .git/deploy-failed-head; the marker was already consumed, so
#   nothing retries automatically. install.sh --check reports the hold; a later
#   successful deploy (or deploy-debounce.sh --now, which clears it) ends it.
# - Env knobs: HEALTH_URLS (space-separated "url=expected_code" pairs),
#   HEALTH_TIMEOUT (secs, default 90), HEALTH_INTERVAL (secs, default 3),
#   NETLISP_SERVICE (unit name, default netlisp.service),
#   DEPLOY_SETTLE_SECONDS (optional settle window, default 0),
#   DEPLOY_RUN_NOW=1 (deploy NOW instead of arming — how the debounce
#   worker invokes this script; without it the arm-and-exec path would just
#   bounce back through the worker).
set -uo pipefail

# Repo root = one level up from .githooks/.
TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$TOP/.git/deploy-on-merge.log"
LOCK="$TOP/.git/deploy-on-merge.lock"
# The LIVE production executable, and the path the systemd unit's ExecStart
# names. Deliberately NOT $TOP/zig-out/bin/netlisp: that is where a plain
# `zig build` installs its Debug artifact, so any developer or agent build in
# this checkout silently overwrote the deployed ReleaseSafe binary and the next
# restart booted a 327 MB Debug netlisp. (That happened on 2026-08-19: a
# `zig build && zig build mutate-full` at 03:30 clobbered the 03:12 deploy, and
# the 04:49 restart ran Debug for five hours before anyone noticed.) Nothing but
# this script writes $BIN_DIR, so the two builds can no longer collide.
BIN_DIR="$TOP/.deploy/bin"
BIN="$BIN_DIR/netlisp"
mkdir -p "$BIN_DIR"
GOOD="$TOP/.git/deploy-lastgood-netlisp"
GOOD_ID="$TOP/.git/deploy-lastgood-id"
FAILED="$TOP/.git/deploy-failed-netlisp"
DEPLOY_ID="$TOP/.git/netlisp-deploy-id"
PENDING="$TOP/.git/deploy-pending"
FAILED_HEAD="$TOP/.git/deploy-failed-head"
# The window a merge arms the marker with: 0 — armed and deployed in the same
# breath (the arming run invokes the worker itself), with the marker still
# doing its job as the queue slot a mid-build merge coalesces through. The
# number is WRITTEN INTO the marker, so the worker honours whatever it reads.
# DEPLOY_SETTLE_SECONDS>0 restores a timer-deployed settle delay if batching
# ever matters more than immediacy again.
SETTLE_SECONDS="${DEPLOY_SETTLE_SECONDS:-0}"
# The unit that fires the debounce. Deferring is only safe if SOMETHING will
# come back for the marker, so an inactive timer makes ANY merge deploy
# immediately rather than vanish. Set DEPLOY_DEBOUNCE_TIMER='' when
# deploy-debounce.sh is driven by something other than this unit (a cron entry,
# a test harness) to turn that check off — `-` not `:-`, so empty is honoured.
DEBOUNCE_TIMER="${DEPLOY_DEBOUNCE_TIMER-netlisp-deploy-debounce.timer}"
CANDIDATE_ROOT="$TOP/.git/release-candidates"
SERVICE="${NETLISP_SERVICE:-netlisp.service}"
# The one toolchain: the official pinned Zig from PATH (or $ZIG). `.zigversion`
# is the single source of truth for which snapshot that is, so a pin bump can
# never leave the deploy path behind.
REQUIRED_ZIG="$(tr -d '[:space:]' <"$TOP/.zigversion")"
ARTIFACT_POLICY="release-safe-stripped-v1"
ZIG="${ZIG:-zig}"
ts() { date "+%Y-%m-%d %H:%M:%S"; }

valid_build_id() {
  local value="$1"
  [ "${#value}" -eq 9 ] || return 1
  case "$value" in *[!0-9a-f]*) return 1 ;; esac
}

# The `Deploy: skip` trailer is RETIRED (2026-08-14): no merge holds prod
# back any more — every merge deploys through the queue. A trailer someone
# still writes out of muscle memory is logged as a note and otherwise ignored,
# never silently honoured with a hold that no longer exists.
retired_trailer_present() {
  git log -1 --format=%B HEAD 2>/dev/null |
    grep -qiE '^[[:space:]]*Deploy:[[:space:]]*skip[[:space:]]*$'
}

# Is anything going to come back for a deferred deploy? An armed marker with no
# timer behind it is the worst outcome available here — prod silently never
# updates — so every merge checks this BEFORE deferring, not discovered later.
debounce_will_fire() {
  [ -z "$DEBOUNCE_TIMER" ] && return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user is-active --quiet "$DEBOUNCE_TIMER" 2>/dev/null
}

# Arm (or re-arm) the debounce: HEAD, the epoch second it was armed, and the
# window it should wait. A rewrite is what RESETS the clock (and adopts the new
# merge's window), so a run of merges collapses into one deploy. Written via a
# temp + rename so the timer can never read half a line.
arm_pending() { # $1 = head hash, $2 = window seconds
  local tmp="$PENDING.tmp.$$"
  printf '%s %s %s\n' "$1" "$(date +%s)" "$2" >"$tmp" && mv -f "$tmp" "$PENDING" && return 0
  rm -f "$tmp"
  return 1
}

write_build_id_file() {
  local value="$1" tmp="$DEPLOY_ID.tmp.$$"
  valid_build_id "$value" || return 1
  if printf '%s\n' "$value" >"$tmp" && mv -f "$tmp" "$DEPLOY_ID"; then return 0; fi
  rm -f "$tmp"
  return 1
}

restore_good_build_id() {
  local value
  if [ -f "$GOOD_ID" ]; then
    value="$(cat "$GOOD_ID")"
    if valid_build_id "$value"; then
      write_build_id_file "$value"
      return
    fi
  fi
  # A legacy rollback binary predates runtime IDs and uses its embedded stamp.
  rm -f "$DEPLOY_ID"
}

if [ -z "$REQUIRED_ZIG" ]; then
  echo "deploy-prod: .zigversion is empty or missing at $TOP/.zigversion" >&2
  exit 1
fi
# Resolve `zig` to an absolute path once, so the preparation this may trigger
# and the fingerprint below both name the exact binary that was validated.
#
# PATH is not enough on its own here: this script also runs from a systemd user
# timer, whose PATH is the manager's default and need not contain
# ~/.local/bin. So fall back to the two locations scripts/install-zig.sh
# writes before giving up — a deploy that cannot find the compiler is a silent
# prod freeze.
resolved="$(command -v "$ZIG" 2>/dev/null)" || resolved=""
if [ -z "$resolved" ]; then
  for candidate in \
    "$HOME/.local/bin/zig" \
    "${ZIG_INSTALL_DIR:-$HOME/.local/share/netlisp/zig}/$REQUIRED_ZIG/zig"; do
    if [ -x "$candidate" ]; then
      resolved="$candidate"
      break
    fi
  done
fi
ZIG="$resolved"
if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
  echo "deploy-prod: no usable Zig compiler on PATH (\$ZIG overrides it)" >&2
  echo "  install the pinned toolchain with scripts/install-zig.sh --link (see ZIG_TOOLCHAIN.md)" >&2
  exit 1
fi
ZIG_VERSION="$("$ZIG" version 2>/dev/null || echo unavailable)"
if [ "$ZIG_VERSION" != "$REQUIRED_ZIG" ]; then
  echo "deploy-prod: wrong Zig compiler at $ZIG" >&2
  echo "  required (.zigversion): $REQUIRED_ZIG" >&2
  echo "  found:                  $ZIG_VERSION" >&2
  echo "  install the pinned toolchain with scripts/install-zig.sh --link (see ZIG_TOOLCHAIN.md)" >&2
  exit 1
fi
# A fingerprint, not a pin: the candidate records which compiler binary emitted
# it, so an artifact from a different build of the same version is never
# adopted as this one's.
ZIG_SHA256="$(sha256sum "$ZIG" | awk '{print $1}')" || exit 1
# The preparation this may run below must use the very binary just validated,
# not re-resolve a possibly different one from its own environment.
export ZIG

# Prod is only ever built from the MAIN checkout (that is the tree the systemd
# unit's WorkingDirectory points at). In a linked worktree $TOP/.git is a FILE,
# not a directory — refuse, so a hand-run from a worktree can never deploy a
# feature branch to production.
if [ ! -d "$TOP/.git" ]; then
  echo "deploy-prod: refusing — $TOP is a linked worktree, not the main checkout" >&2
  exit 1
fi

# Production builds use a cache no worktree or interactive build touches. The
# tracked post-merge/post-commit bridges already export this; set it here too so
# a hand-run deploy uses the same cache as an automatic one.
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$TOP/.git/deploy-zig-cache}"

# Health probes: "URL=expected_http_code", space separated.
#   /healthz — served unauthenticated ahead of every handler, proves the process
#     is listening AND routing AND emitting a real response body (200). It reads
#     no design, sidecar or cache, so a cold process answers it as fast as a warm
#     one. Deliberately NOT `/`: that renders the design list, which on a cold
#     process is the slowest read on the server.
# A 502/000/500 means the binary is not serving traffic.
HEALTH_URLS="${HEALTH_URLS:-http://127.0.0.1:7050/healthz=200}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-3}"

# One full pass over the probes. Returns 0 only if the unit is active AND every
# probe returns its expected status code. Sets $last_health for logging.
health_ok() {
  systemctl --user is-active --quiet "$SERVICE" || { last_health="unit not active"; return 1; }
  local pair url want got
  for pair in $HEALTH_URLS; do
    url="${pair%=*}"; want="${pair##*=}"
    got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)"
    if [ "$got" != "$want" ]; then
      last_health="$url returned $got (want $want)"
      return 1
    fi
  done
  last_health="all probes OK"
  return 0
}

# Poll health until it passes or the timeout expires (the server needs a moment
# to bind the port and load the project on a cold start).
await_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  last_health="not probed"
  while (( SECONDS < deadline )); do
    if health_ok; then return 0; fi
    sleep "$HEALTH_INTERVAL"
  done
  health_ok && return 0
  return 1
}

candidate_valid() {
  local candidate="$1" expected="$2" expected_id="${2:0:9}"
  [ -x "$candidate/install/bin/netlisp" ] || return 1
  [ -f "$candidate/commit" ] || return 1
  [ "$(cat "$candidate/commit")" = "$expected" ] || return 1
  [ -f "$candidate/verified" ] || return 1
  grep -qx 'pcb_editor_perf=passed' "$candidate/verified" || return 1
  [ -f "$candidate/zig-version" ] || return 1
  [ "$(cat "$candidate/zig-version")" = "$REQUIRED_ZIG" ] || return 1
  [ -f "$candidate/compiler-sha256" ] || return 1
  [ "$(cat "$candidate/compiler-sha256")" = "$ZIG_SHA256" ] || return 1
  [ -f "$candidate/build-id" ] || return 1
  [ "$(cat "$candidate/build-id")" = "$expected_id" ] || return 1
  [ -f "$candidate/artifact-policy" ] || return 1
  [ "$(cat "$candidate/artifact-policy")" = "$ARTIFACT_POLICY" ] || return 1
  [ -f "$candidate/netlisp.sha256" ] || return 1
  (cd "$candidate" && sha256sum --check --status netlisp.sha256)
}

exec >>"$LOG" 2>&1
exec 9>"$LOCK"
cd "$TOP" || { echo "[$(ts)] ERROR: cannot cd $TOP"; exit 1; }
echo "============================================================"
echo "[$(ts)] deploy start @ $(git rev-parse --short HEAD 2>/dev/null) (zig=$ZIG)"

# Disarm the marker ONLY when the given head is covered by (an ancestor of, or
# equal to) the deployed head. An unconditional rm here can drop the marker a
# NEWER merge just armed — the deploy that finishes settles what it carried,
# never what arrived while it ran.
settle_pending() { # $1 = deployed head hash
  [ -f "$PENDING" ] || return 0
  local m_hash
  read -r m_hash _ <"$PENDING" 2>/dev/null || true
  if [ "${m_hash:-}" = "$1" ] ||
    git -C "$TOP" merge-base --is-ancestor "${m_hash:-x}" "$1" 2>/dev/null; then
    rm -f "$PENDING"
  fi
}

# Dedup: post-merge and post-commit can both fire for one clean merge; the
# second (and any repeat for an already-deployed HEAD) is a no-op.
last_file="$TOP/.git/deploy-last-hash"
head_hash="$(git rev-parse HEAD)"
if [ -f "$last_file" ] && [ "$(cat "$last_file")" = "$head_hash" ]; then
  echo "[$(ts)] skip: HEAD $head_hash already deployed"
  # Whatever the pending marker was holding is now on prod, so disarm it rather
  # than letting the timer wake up for a deploy with nothing left to do — but
  # never a marker armed by a NEWER merge than the one deployed.
  settle_pending "$head_hash"
  exit 0
fi

# Every merge queues through the marker and deploys NOW — the worker does the
# building. The merge takes window 0 (unless the DEPLOY_SETTLE_SECONDS knob
# raises it) and this same (already launcher-detached) run invokes the worker
# on the spot: idle box → the build starts immediately; a deploy already
# running → the worker's own deploy queues on the flock below and starts the
# moment the running one finishes. DEPLOY_RUN_NOW=1 (the worker, or a hand
# --now) skips arming and deploys HERE; and a POSITIVE window with no timer
# behind it would strand the change, so that combination deploys now instead
# (window 0 needs no timer — this run is its own worker).
window=""
if [ "${DEPLOY_RUN_NOW:-0}" != "1" ]; then
  window="$SETTLE_SECONDS"
  if retired_trailer_present; then
    echo "[$(ts)] note: the 'Deploy: skip' trailer is RETIRED — every merge deploys through the queue now"
  fi
fi
if [ -n "$window" ] && [ "$window" -gt 0 ] && ! debounce_will_fire; then
  echo "[$(ts)] WARN: $DEBOUNCE_TIMER is not active — nothing would ever deploy an armed"
  echo "[$(ts)] WARN: marker, so deploying NOW instead. Enable deferral with:"
  echo "[$(ts)] WARN:   .githooks/install.sh --deploy"
  window=""
fi
if [ -n "$window" ]; then
  if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
    echo "[$(ts)] DRY RUN: would arm the deploy debounce at $head_hash (window ${window}s)"
    echo "[$(ts)] deploy end (dry run, deferred)"
    exit 0
  fi
  if arm_pending "$head_hash" "$window"; then
    echo "[$(ts)] queued: armed the deploy debounce at $head_hash (window ${window}s)"
    if [ "$window" -eq 0 ]; then
      echo "[$(ts)] queued: window 0 — running the worker now"
      exec "$TOP/.githooks/deploy-debounce.sh"
    fi
    echo "[$(ts)] deploy end (deferred to deploy-debounce.sh)"
    exit 0
  fi
  # Falling through is the safe failure: a deploy nobody asked for costs build
  # time, whereas a dropped marker would leave prod behind with nothing tracking it.
  echo "[$(ts)] ERROR: could not write $PENDING — deploying now rather than losing the deferral"
fi

# Only REAL deploys serialize on the lock. Arming above deliberately does not
# wait for it — a merge landing while a deploy is building must queue (write
# the marker) instantly, not block behind minutes of compile. Overlapping real
# deploys (the worker, a --now) still run one-at-a-time from the final source.
flock 9

# The wait for the lock may have been minutes long. Re-resolve HEAD and re-run
# the dedup: a queued deploy whose head (or a newer one containing it) shipped
# while it waited must exit as a no-op, not rebuild and restart for nothing —
# this is what makes N deploys queued behind one build collapse into one.
head_hash="$(git rev-parse HEAD)"
if [ -f "$last_file" ] && [ "$(cat "$last_file")" = "$head_hash" ]; then
  echo "[$(ts)] skip: HEAD $head_hash was deployed while this run queued on the lock"
  settle_pending "$head_hash"
  exit 0
fi

if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
  echo "[$(ts)] DRY RUN: would reuse or prepare the verified candidate for $head_hash, restart $SERVICE,"
  echo "[$(ts)] DRY RUN: probe [$HEALTH_URLS] for ${HEALTH_TIMEOUT}s, and roll back to $GOOD on failure"
  echo "[$(ts)] deploy end (dry run)"
  exit 0
fi

# From here on a failure leaves prod on the previous binary with the marker
# already consumed — nothing retries automatically (a broken main would fail
# identically every minute while holding the gate lock). Record the head so
# install.sh --check can report the hold instead of the failure living only in
# this log; the success path below (and deploy-debounce.sh --now) clears it.
trap '[ "$?" -ne 0 ] && printf "%s\n" "$head_hash" >"$FAILED_HEAD" 2>/dev/null' EXIT

# Bootstrap the rollback target: if we have no known-good binary on file but the
# CURRENTLY RUNNING build is healthy, that build is by definition known-good.
# Must happen before the build, which overwrites $BIN in place.
if [ ! -f "$GOOD" ] && [ -x "$BIN" ]; then
  if health_ok; then
    cp -f "$BIN" "$GOOD.tmp" && mv -f "$GOOD.tmp" "$GOOD"
    previous_id=""
    if [ -f "$last_file" ]; then previous_id="$(printf '%.9s' "$(cat "$last_file")")"; fi
    if ! valid_build_id "$previous_id" && [ -f "$DEPLOY_ID" ]; then previous_id="$(cat "$DEPLOY_ID")"; fi
    if valid_build_id "$previous_id"; then
      printf '%s\n' "$previous_id" >"$GOOD_ID.tmp" && mv -f "$GOOD_ID.tmp" "$GOOD_ID"
    else
      rm -f "$GOOD_ID"
    fi
    echo "[$(ts)] seeded rollback target from the running (healthy) binary"
  else
    echo "[$(ts)] WARN: no rollback target and current prod is unhealthy ($last_health) — this deploy cannot roll back"
  fi
fi

candidate="$CANDIDATE_ROOT/$head_hash"
if ! candidate_valid "$candidate" "$head_hash"; then
  echo "[$(ts)] no verified candidate for $head_hash; preparing tests + build concurrently"
  if ! "$TOP/.githooks/prepare-release.sh"; then
    echo "[$(ts)] ERROR: release preparation failed — prod NOT restarted (still on previous binary)"
    echo "[$(ts)] deploy end"
    exit 1
  fi
fi

if ! candidate_valid "$candidate" "$head_hash"; then
  echo "[$(ts)] ERROR: candidate validation failed for $head_hash — prod NOT restarted"
  echo "[$(ts)] deploy end"
  exit 1
fi

candidate_build_id="$(cat "$candidate/build-id")"
if ! write_build_id_file "$candidate_build_id"; then
  echo "[$(ts)] ERROR: could not install candidate build identity — prod NOT restarted"
  echo "[$(ts)] deploy end"
  exit 1
fi

mkdir -p "$(dirname "$BIN")"
if ! { cp -f "$candidate/install/bin/netlisp" "$BIN.deploy.tmp" && chmod +x "$BIN.deploy.tmp" && mv -f "$BIN.deploy.tmp" "$BIN"; }; then
  rm -f "$BIN.deploy.tmp"
  restore_good_build_id || echo "[$(ts)] WARN: could not restore the previous runtime build ID"
  echo "[$(ts)] ERROR: could not install verified candidate — prod NOT restarted"
  echo "[$(ts)] deploy end"
  exit 1
fi

echo "[$(ts)] verified candidate installed; restarting $SERVICE"
if ! systemctl --user restart "$SERVICE"; then
  echo "[$(ts)] ERROR: restart failed"
fi

if await_health; then
  echo "[$(ts)] health OK ($last_health); service is $(systemctl --user is-active "$SERVICE")"
  if ! {
    cp -f "$BIN" "$GOOD.tmp" &&
      printf '%s\n' "$candidate_build_id" >"$GOOD_ID.tmp" &&
      mv -f "$GOOD.tmp" "$GOOD" &&
      mv -f "$GOOD_ID.tmp" "$GOOD_ID"
  }; then
    rm -f "$GOOD.tmp" "$GOOD_ID.tmp"
    echo "[$(ts)] ERROR: service is healthy but the rollback pair could not be recorded"
    echo "[$(ts)] deploy end"
    exit 1
  fi
  echo "$head_hash" >"$last_file"
  # Keep the schematic-design-agent folder's binary and runtime build id in
  # lockstep with prod. `projects/designs/netlisp` is now a TRACKED launcher
  # (not a binary) that materializes this same verified build into
  # `projects/designs/.netlisp-bin/` on first use; pre-warming it here — plus
  # writing the paired netlisp commit to the designs repo's git dir so
  # `netlisp version` and exported review metadata report the real build —
  # means the design folder is immediately self-contained and current after
  # any deploy. This is deliberately best-effort: a design agent that only
  # needs build/check/query works fine without it, and failures must never
  # fail the deploy.
  if [ -d "$TOP/projects/designs/.git" ]; then
    mkdir -p "$TOP/projects/designs/.netlisp-bin"
    if cp -f "$BIN" "$TOP/projects/designs/.netlisp-bin/netlisp.tmp" 2>/dev/null &&
      chmod +x "$TOP/projects/designs/.netlisp-bin/netlisp.tmp" &&
      mv -f "$TOP/projects/designs/.netlisp-bin/netlisp.tmp" "$TOP/projects/designs/.netlisp-bin/netlisp" &&
      printf '%s\n' "$candidate_build_id" >"$TOP/projects/designs/.git/netlisp-deploy-id" 2>/dev/null; then
      echo "[$(ts)] design-agent folder refreshed (binary $candidate_build_id)"
    else
      rm -f "$TOP/projects/designs/.netlisp-bin/netlisp.tmp"
      echo "[$(ts)] WARN: could not refresh projects/designs/.netlisp-bin/netlisp"
    fi
  fi
  # This deploy carries every merge that landed BEFORE it started, so that
  # deferral is settled — disarm before the timer fires for a stale one. A
  # marker armed by a merge that landed DURING the build is not ours to clear
  # (settle_pending's ancestry guard keeps it queued). A healthy deploy also
  # ends any failed-head hold: prod is current again.
  settle_pending "$head_hash"
  rm -f "$FAILED_HEAD"
  echo "[$(ts)] deploy end"
  exit 0
fi

# --- unhealthy: roll back -------------------------------------------------
echo "[$(ts)] ERROR: health check FAILED after ${HEALTH_TIMEOUT}s ($last_health)"
cp -f "$BIN" "$FAILED" 2>/dev/null && echo "[$(ts)] kept the failed binary at $FAILED for triage"

if [ ! -f "$GOOD" ]; then
  echo "[$(ts)] ERROR: no known-good binary to roll back to — prod is DOWN, fix by hand"
  echo "[$(ts)] deploy end (rollback impossible)"
  exit 1
fi

echo "[$(ts)] ROLLBACK: restoring last known-good binary and restarting"
# Install by rename, NOT `cp` over $BIN: the failed binary is still RUNNING at
# this point, and writing to a running executable fails with ETXTBSY (verified
# 2026-07-25). A rename swaps the directory entry; the live process keeps its
# own inode until the restart below picks up the new one.
if ! { cp -f "$GOOD" "$BIN.rollback.tmp" && chmod +x "$BIN.rollback.tmp" && mv -f "$BIN.rollback.tmp" "$BIN"; }; then
  rm -f "$BIN.rollback.tmp"
  echo "[$(ts)] ERROR: could not restore $GOOD -> $BIN — prod is DOWN, fix by hand"
  echo "[$(ts)] deploy end (rollback failed)"
  exit 1
fi
if ! restore_good_build_id; then
  echo "[$(ts)] ERROR: restored binary identity could not be installed — not restarting"
  echo "[$(ts)] deploy end (rollback failed)"
  exit 1
fi
# A binary that crash-loops can trip the unit's StartLimitBurst, which would
# make the rollback restart fail with "start request repeated too quickly".
systemctl --user reset-failed "$SERVICE" 2>/dev/null
systemctl --user restart "$SERVICE"

if await_health; then
  echo "[$(ts)] ROLLBACK OK: prod is healthy on the previous binary ($last_health)"
  echo "[$(ts)] NOTE: HEAD $head_hash is NOT deployed — the build starts but does not serve"
else
  echo "[$(ts)] ERROR: ROLLBACK FAILED — prod still unhealthy ($last_health), fix by hand"
fi
echo "[$(ts)] deploy end (rolled back)"
exit 1
