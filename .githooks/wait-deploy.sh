#!/usr/bin/env bash
# wait-deploy.sh — TRACKED. Block until the coalesced deploy of HEAD has
# finished, then print the outcome and exit. Built for agent background-Bash
# use: it always terminates (success, failure, or timeout), so a completion
# notification reliably fires exactly once.
#
#   .githooks/wait-deploy.sh [timeout-secs]     # default 600
#
# Exit codes: 0 = HEAD is live (deployed itself, or shipped INSIDE a newer
# coalesced head — success is ancestry, not equality, because a merge landing
# after ours re-arms the marker and one deploy carries both); 1 = timed out /
# deploy failed; 2 = HEAD is deferred BEYOND this wait's deadline (its marker
# carries a positive window — the optional DEPLOY_SETTLE_SECONDS knob, or a
# legacy pre-window marker — ending after the timeout), so there is nothing
# here to wait for (log tail printed in every case). The normal window-0
# marker is due at once and is simply waited out. Merges deploy immediately
# now, so exit 2 is the exception, not the ordinary skip-merge answer it was.
#
# WHY THIS EXISTS (2026-07-23): an ad-hoc `until grep …; pgrep -f deploy-prod.sh`
# watcher hung forever because the pgrep PATTERN appeared in the watcher's own
# command line and matched itself. This script uses no process matching at all:
# deploy-prod.sh holds an flock on deploy-on-merge.lock for the whole deploy and
# writes the deployed HEAD to deploy-last-hash ONLY on build+restart success, so
# "lock free + HEAD reachable from the hash" is the complete, race-safe success
# signal (the reachability check also absorbs the detached-start race: if the
# deploy hasn't taken the lock yet, we just poll again until the deadline).
set -uo pipefail
TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$TOP/.git/deploy-on-merge.log"
LOCK="$TOP/.git/deploy-on-merge.lock"
LAST="$TOP/.git/deploy-last-hash"
PENDING="$TOP/.git/deploy-pending"
TIMEOUT="${1:-600}"
HEAD_HASH="${WAIT_DEPLOY_EXPECT:-$(git -C "$TOP" rev-parse HEAD)}"
DEFAULT_WINDOW="${DEPLOY_DEBOUNCE_QUIET_SECONDS:-900}"
END_EPOCH=$(($(date +%s) + TIMEOUT))

# Success = the live commit CONTAINS ours. Coalescing means a merge that lands
# after ours is deployed on our behalf: the marker re-arms at the newer head and
# one deploy ships both, so demanding hash equality would report our own
# successful deploy as a timeout.
deployed() {
  [ -f "$LAST" ] || return 1
  local live
  live="$(cat "$LAST")"
  [ "$live" = "$HEAD_HASH" ] && return 0
  git -C "$TOP" merge-base --is-ancestor "$HEAD_HASH" "$live" 2>/dev/null
}

finish() { # $1 = status word, $2 = exit code
  echo "wait-deploy: $1 (HEAD $HEAD_HASH, service $(systemctl --user is-active netlisp.service 2>/dev/null || echo unknown))"
  echo "--- last deploy log lines ---"
  tail -6 "$LOG" 2>/dev/null
  exit "$2"
}

exec 9>"$LOCK"
deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  deployed && finish "deploy SUCCEEDED" 0
  # If a deploy holds the lock, block until it releases (bounded by deadline).
  remaining=$((deadline - SECONDS)); (( remaining < 1 )) && remaining=1
  flock -w "$remaining" 9 && flock -u 9
  deployed && finish "deploy SUCCEEDED" 0
  # Lock free but HEAD not live: the deploy failed, is still settling, or hasn't
  # started yet (detached spawn race). A pending marker COVERING this head (it
  # names our commit, or a newer one containing it — that deploy ships us too)
  # settles the question of whether waiting can succeed: if the marker's window
  # ends beyond our deadline, no deploy is coming in time and burning the
  # timeout would report a failure that never happened. A marker due INSIDE the
  # deadline is the normal coalescing settle — keep polling through it. A
  # marker for an unrelated/older head says nothing about ours (a later merge
  # will re-arm it over ours), so keep polling on that too.
  if [ -f "$PENDING" ]; then
    read -r p_hash p_at p_win _ <"$PENDING" 2>/dev/null || true
    covers=no
    if [ "${p_hash:-}" = "$HEAD_HASH" ] ||
      git -C "$TOP" merge-base --is-ancestor "$HEAD_HASH" "${p_hash:-x}" 2>/dev/null; then
      covers=yes
    fi
    case "${p_at:-}" in
      '' | *[!0-9]*) : ;;
      *)
        case "${p_win:-}" in '' | *[!0-9]*) p_win="$DEFAULT_WINDOW" ;; esac
        if [ "$covers" = yes ] && [ $((p_at + p_win)) -ge "$END_EPOCH" ]; then
          echo "wait-deploy: DEFERRED beyond this wait — the marker's window ends after the ${TIMEOUT}s timeout."
          echo "             ship it now with: .githooks/deploy-debounce.sh --now"
          finish "deploy DEFERRED (not an error)" 2
        fi
        ;;
    esac
  fi
  sleep 2
done
finish "deploy NOT confirmed (timeout ${TIMEOUT}s — failed, skipped, or never started)" 1
