#!/usr/bin/env bash
# Coalescing deploy worker for production merges.
#
# TRACKED FILE. EVERY merge into main queues its deploy through the marker:
#
#   git merge on main
#     -> .githooks/deploy-prod.sh  writes .git/deploy-pending
#        "<head> <epoch> <window>" — window 0 (armed and deployed in the same
#        breath: the arming run execs this worker directly; there is no hold
#        period). A later merge REWRITES the marker. The once-a-minute
#        netlisp-deploy-debounce.timer (installed by install.sh --deploy) is
#        the backstop that picks a queued marker back up after a crash or
#        reboot, and the deployer for a positive-window marker (the optional
#        DEPLOY_SETTLE_SECONDS knob, or a legacy two-field marker).
#   ...the marker is due (immediately at window 0)...
#     -> this script -> .githooks/deploy-prod.sh  (DEPLOY_RUN_NOW=1)
#
# A merge on an idle box therefore builds IMMEDIATELY; one landing while a
# deploy is running queues on deploy-prod.sh's flock and starts the moment
# the running deploy finishes; and N merges landing during one build still
# cost ONE follow-up deploy of the accumulated head, because each just
# rewrites the one marker. What that collapses is prepare-release.sh — the
# machine-wide /tmp/netlisp-gate.lock for ~7 minutes, which every other agent
# session on this box would spend queued behind — plus the prod restart.
#
# A merge landing while a deploy is RUNNING re-arms the marker; deploy-prod.sh's
# own flock serializes any overlap, and after each successful deploy this worker
# LOOPS: if the re-armed marker is already due (a merge that landed early in a
# long build), it deploys the accumulated head in the same run rather than
# waiting for the next timer tick. A marker still inside its window is left for
# the timer — the settle promise ("quiet for the whole window") holds uniformly.
#
# The marker records the head that armed it only for the log; the deploy always
# targets whatever main's HEAD is when the window expires, which is the point —
# one build covering everything that accumulated.
#
# Run by hand with --now to deploy a still-pending marker without waiting out
# whatever window it carries. --now also clears a failed-head hold
# (.git/deploy-failed-head — written by a deploy that failed after consuming
# its marker; nothing retries that automatically), making it the
# explicit-retry command too.
#
# Env: DEPLOY_DEBOUNCE_QUIET_SECONDS (default 900 — the fallback window for a
# legacy two-field marker), and everything deploy-prod.sh reads
# (DEPLOY_DRY_RUN=1 works here too).
set -uo pipefail

case "${1:-}" in
  --now) FORCE=1 ;;
  '') FORCE=0 ;;
  *)
    echo "usage: $0 [--now]   (--now: deploy the pending merge without waiting out its window; also clears a failed-head hold)" >&2
    exit 2
    ;;
esac

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$TOP/.git/deploy-on-merge.log"
PENDING="$TOP/.git/deploy-pending"
FAILED_HEAD="$TOP/.git/deploy-failed-head"
QUIET="${DEPLOY_DEBOUNCE_QUIET_SECONDS:-900}"
ts() { date "+%Y-%m-%d %H:%M:%S"; }

# The overwhelmingly common case is "nothing deferred" — leave the log alone so
# a minutely timer cannot bury the deploy history in no-ops.
if [ ! -f "$PENDING" ]; then
  [ "$FORCE" = 1 ] && echo "no deferred deploy pending — nothing to do" >&2
  exit 0
fi

# Read the marker into armed_hash/armed_at/armed_window. Returns 1 (after
# logging and discarding) on garbage; the window falls back to $QUIET for a
# legacy two-field marker.
read_marker() {
  armed_hash="" armed_at="" armed_window=""
  read -r armed_hash armed_at armed_window _rest <"$PENDING" 2>/dev/null || true
  case "${armed_at:-}" in
    '' | *[!0-9]*)
      echo "[$(ts)] debounce: $PENDING is unreadable ('${armed_hash:-}' '${armed_at:-}') — discarding it" >>"$LOG"
      rm -f "$PENDING"
      return 1
      ;;
  esac
  case "${armed_window:-}" in
    '' | *[!0-9]*) armed_window="$QUIET" ;;
  esac
  return 0
}

# Is the marker due? A marker stamped in the future (clock step, or a file
# copied between machines) would otherwise wait forever; treat it as due now.
marker_due() {
  local now elapsed
  now="$(date +%s)"
  elapsed=$((now - armed_at))
  [ "$elapsed" -ge "$armed_window" ] || [ "$elapsed" -lt 0 ]
}

# First look at the marker happens before the log redirect so the quiet
# "not due yet" path stays silent (read_marker logs its own discard directly).
read_marker || exit 0
if [ "$FORCE" != 1 ] && ! marker_due; then exit 0; fi

# Everything past here is written to the deploy log, which is where a timer-run
# deploy belongs — but a human who typed --now needs to be told that.
[ "$FORCE" = 1 ] && echo "deploying the pending merge; following output goes to $LOG" >&2
exec >>"$LOG" 2>&1

if [ "$FORCE" = 1 ] && [ -f "$FAILED_HEAD" ]; then
  echo "[$(ts)] debounce: --now clears the failed-head hold at $(cut -c1-9 "$FAILED_HEAD" 2>/dev/null) — explicit retry"
  rm -f "$FAILED_HEAD"
fi

passes=0
while :; do
  echo "============================================================"
  now="$(date +%s)"
  elapsed=$((now - armed_at))
  if [ "$FORCE" = 1 ]; then
    echo "[$(ts)] debounce: --now requested after ${elapsed}s of a ${armed_window}s window, armed at $armed_hash"
  else
    echo "[$(ts)] debounce: window elapsed (${elapsed}s >= ${armed_window}s) since $armed_hash"
  fi

  branch="$(git -C "$TOP" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ "$branch" != "main" ]; then
    echo "[$(ts)] debounce: the main checkout is on '${branch:-detached}', not main — leaving the marker armed"
    exit 0
  fi

  head_hash="$(git -C "$TOP" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$head_hash" ]; then
    echo "[$(ts)] debounce: cannot resolve HEAD — leaving the marker armed"
    exit 0
  fi
  if [ "$head_hash" != "$armed_hash" ]; then
    echo "[$(ts)] debounce: main advanced to $head_hash since arming — one deploy covers the batch"
  fi

  if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
    echo "[$(ts)] DRY RUN: would disarm $PENDING and deploy $head_hash"
    exit 0
  fi

  # Disarm BEFORE deploying, not after. The deploy runs for minutes and the
  # timer keeps ticking; a marker still on disk when the next tick lands would
  # queue a second identical deploy. The cost of this order is that a FAILED
  # deploy is not retried automatically — deliberate, since a failure here is a
  # broken main that would fail identically every minute while holding the gate
  # lock. deploy-prod.sh records the head in .git/deploy-failed-head (reported
  # by install.sh --check), and the next merge — or --now — retries.
  rm -f "$PENDING"

  echo "[$(ts)] debounce: deploying $head_hash"
  DEPLOY_RUN_NOW=1 "$TOP/.githooks/deploy-prod.sh"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "[$(ts)] debounce: deploy exited $status — prod is NOT on $head_hash (see the deploy record above)"
    exit "$status"
  fi

  # A merge that landed DURING the deploy re-armed the marker. An ordinary
  # merge (window 0) is due on the spot — deploy the accumulated head right
  # now, which is what makes back-to-back merges chain build-after-build with
  # no gap. A long-window marker still inside its window keeps its quiet-period
  # promise and is left for the timer.
  FORCE=0
  passes=$((passes + 1))
  if [ "$passes" -ge 5 ]; then
    echo "[$(ts)] debounce: 5 passes in one run — leaving anything further to the timer"
    exit 0
  fi
  [ -f "$PENDING" ] || exit 0
  read_marker || exit 0
  marker_due || exit 0
  echo "[$(ts)] debounce: a merge landed mid-deploy and its window is already due — continuing"
done
