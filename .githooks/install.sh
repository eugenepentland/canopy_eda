#!/usr/bin/env bash
# install.sh — make this checkout's git hooks and production deploy live on
# THIS machine. Everything it installs is derived from tracked files, so a
# fresh clone is one command away from a working setup:
#
#   .githooks/install.sh              # hooks only (safe everywhere)
#   .githooks/install.sh --deploy     # hooks + prod auto-deploy + systemd unit
#   .githooks/install.sh --check      # report what is/isn't installed, change nothing
#   .githooks/install.sh --uninstall-deploy   # stop auto-deploying on this machine
#
# WHY --deploy IS OPT-IN: merging into main triggers a rebuild + restart of the
# netlisp systemd service. That is correct on the production box and wrong on a
# laptop clone, so the machine-local launcher under .git/hooks/ is the per-machine
# switch. The tracked .githooks/post-merge bridge execs it only if it exists.
#
# Env: PORT (default 7050), NETLISP_SERVICE (default netlisp.service),
# DESIGNS_CHECKPOINT_SERVICE (default netlisp-designs-checkpoint.service),
# DESIGNS_CHECKPOINT_QUIET_SECONDS (default 300),
# DEPLOY_DEBOUNCE_SERVICE (default netlisp-deploy-debounce.service), and
# DEPLOY_DEBOUNCE_QUIET_SECONDS (default 900) — the worker's fallback window
# for a LEGACY two-field marker (pre-window format only; every merge deploys
# immediately now — the retired `Deploy: skip` trailer holds nothing back.
# DEPLOY_SETTLE_SECONDS>0 restores a settle delay; that knob is
# deploy-prod.sh's own, read in the shell that merges, not from the systemd
# unit's environment).
set -uo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$TOP/.githooks"
PORT="${PORT:-7050}"
SERVICE="${NETLISP_SERVICE:-netlisp.service}"
# The live production executable, and what the rendered unit's ExecStart names.
# Kept OUT of zig-out/ so a developer or agent `zig build` in this checkout
# cannot overwrite the deployed binary (see deploy-prod.sh's BIN comment).
PROD_BIN="$TOP/.deploy/bin/netlisp"
CHECKPOINT_SERVICE="${DESIGNS_CHECKPOINT_SERVICE:-netlisp-designs-checkpoint.service}"
CHECKPOINT_TIMER="${CHECKPOINT_SERVICE%.service}.timer"
CHECKPOINT_QUIET_SECONDS="${DESIGNS_CHECKPOINT_QUIET_SECONDS:-300}"
DEBOUNCE_SERVICE="${DEPLOY_DEBOUNCE_SERVICE:-netlisp-deploy-debounce.service}"
DEBOUNCE_TIMER="${DEBOUNCE_SERVICE%.service}.timer"
DEBOUNCE_QUIET_SECONDS="${DEPLOY_DEBOUNCE_QUIET_SECONDS:-900}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/$SERVICE"
CHECKPOINT_UNIT="$UNIT_DIR/$CHECKPOINT_SERVICE"
CHECKPOINT_TIMER_UNIT="$UNIT_DIR/$CHECKPOINT_TIMER"
DEBOUNCE_UNIT="$UNIT_DIR/$DEBOUNCE_SERVICE"
DEBOUNCE_TIMER_UNIT="$UNIT_DIR/$DEBOUNCE_TIMER"
MODE="install"

case "${1:-}" in
  --check)             MODE="check" ;;
  --deploy)            MODE="deploy" ;;
  --uninstall-deploy)  MODE="uninstall" ;;
  "")                  MODE="install" ;;
  *) echo "usage: $0 [--deploy|--check|--uninstall-deploy]" >&2; exit 2 ;;
esac

if [ ! -d "$TOP/.git" ]; then
  echo "install: refusing — $TOP is a linked worktree, not the main checkout." >&2
  echo "install: run this from the main clone; hooks are shared by all worktrees." >&2
  exit 1
fi

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m•\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

# What an armed marker would actually SHIP, listed under the countdown. A
# deferred deploy is the one state where main is deliberately ahead of prod, and
# a hash plus a number of seconds does not say what is being held back — which
# is the thing a human deciding whether to run `deploy-debounce.sh --now`
# actually needs.
#
# The baseline is `.git/deploy-last-hash`, which deploy-prod.sh writes ONLY
# after the health check passes, so it is what prod is RUNNING, not merely what
# was last attempted: a rolled-back deploy correctly leaves its commits listed
# as still pending.
#
# `--first-parent` because main advances by `--no-ff` merges — one line per
# merge is the summary being asked for, and the branch commits under each are
# noise in a status report. Direct commits to main have no second parent and
# show up regardless.
pending_commits() { # $1 = armed head hash
  local head="$1" live count
  if ! git -C "$TOP" cat-file -e "$head^{commit}" 2>/dev/null; then
    echo "      (cannot describe ${head:0:9} — no such commit in this checkout)"
    return
  fi
  live="$(cat "$TOP/.git/deploy-last-hash" 2>/dev/null || true)"
  if [ -z "$live" ] || ! git -C "$TOP" cat-file -e "$live^{commit}" 2>/dev/null; then
    echo "      (no successful deploy recorded yet — everything up to ${head:0:9} is pending)"
    return
  fi
  # A force-push, a reset or a rollback to an unrelated line can leave the live
  # commit off the armed head's history, and `live..head` would then quietly
  # report a plausible-looking but wrong set. Say so instead of guessing.
  if ! git -C "$TOP" merge-base --is-ancestor "$live" "$head" 2>/dev/null; then
    echo "      (live ${live:0:9} is not an ancestor of ${head:0:9} — diverged history, not listing)"
    return
  fi
  count="$(git -C "$TOP" rev-list --first-parent --count "$live..$head" 2>/dev/null || echo 0)"
  if [ "${count:-0}" -eq 0 ]; then
    echo "      (prod is already at ${head:0:9} — the marker will deploy nothing new)"
    return
  fi
  echo "      $count commit(s) waiting on top of live ${live:0:9}, newest first:"
  git -C "$TOP" log --first-parent --max-count=10 --format='        %h  %s' "$live..$head"
  [ "$count" -gt 10 ] && echo "        … and $((count - 10)) more"
  return 0
}

# The machine-local launchers the tracked bridges exec. Kept tiny on purpose:
# all real logic lives in the tracked deploy-prod.sh, so these never need
# updating; their presence/absence IS the per-machine deploy switch.
write_launcher() { # $1 = post-merge | post-commit
  local name="$1" path="$TOP/.git/hooks/$1"
  mkdir -p "$TOP/.git/hooks"
  {
    echo '#!/usr/bin/env bash'
    echo "# Machine-local deploy launcher, written by .githooks/install.sh --deploy."
    echo "# Presence of this file = 'this machine deploys prod on merges into main'."
    echo "# Delete it (or .githooks/install.sh --uninstall-deploy) to stop deploying."
    echo 'branch="$(git symbolic-ref --quiet --short HEAD || true)"'
    echo '[ "$branch" = "main" ] || exit 0'
    if [ "$name" = "post-commit" ]; then
      # Conflicted merges conclude via `git commit`, which fires post-commit and
      # never post-merge. Only act on an actual merge commit (>=2 parents);
      # deploy-prod.sh dedupes by HEAD hash so a clean merge still deploys once.
      echo 'parents="$(git rev-list --parents -n1 HEAD | wc -w)"'
      echo '[ "$parents" -ge 3 ] || exit 0'
    fi
    echo "TOP=\"\$(git rev-parse --path-format=absolute --git-common-dir)\"; TOP=\"\${TOP%/.git}\""
    echo 'echo "['"$name"'] main updated → deploy started in background (queues behind any running deploy)"'
    echo 'echo "             log: $TOP/.git/deploy-on-merge.log   state: .githooks/install.sh --check"'
    echo 'setsid "$TOP/.githooks/deploy-prod.sh" </dev/null >/dev/null 2>&1 &'
    echo 'exit 0'
  } >"$path"
  chmod +x "$path"
}

# Before this was tracked, deploy-prod.sh / wait-deploy.sh lived under
# .git/hooks/. Once the launcher points at the tracked copies those are dead
# weight that will silently drift from the real thing — say so rather than
# deleting someone's file.
legacy_warn() {
  local f found=0
  for f in deploy-prod.sh wait-deploy.sh; do
    [ -e "$TOP/.git/hooks/$f" ] && { warn "legacy .git/hooks/$f is superseded by .githooks/$f"; found=1; }
  done
  [ "$found" = 1 ] && echo "  (nothing runs them any more — delete them so they can't drift)"
  return 0
}

render_unit() {
  mkdir -p "$UNIT_DIR"
  sed -e "s|@TOP@|$TOP|g" -e "s|@PORT@|$PORT|g" "$HOOKS/netlisp.service.in" >"$UNIT.tmp" &&
    mv -f "$UNIT.tmp" "$UNIT" &&
    sed -e "s|@TOP@|$TOP|g" -e "s|@QUIET_SECONDS@|$CHECKPOINT_QUIET_SECONDS|g" \
      "$HOOKS/netlisp-designs-checkpoint.service.in" >"$CHECKPOINT_UNIT.tmp" &&
    mv -f "$CHECKPOINT_UNIT.tmp" "$CHECKPOINT_UNIT" &&
    cp "$HOOKS/netlisp-designs-checkpoint.timer.in" "$CHECKPOINT_TIMER_UNIT.tmp" &&
    mv -f "$CHECKPOINT_TIMER_UNIT.tmp" "$CHECKPOINT_TIMER_UNIT" &&
    sed -e "s|@TOP@|$TOP|g" -e "s|@DEBOUNCE_QUIET_SECONDS@|$DEBOUNCE_QUIET_SECONDS|g" \
      "$HOOKS/netlisp-deploy-debounce.service.in" >"$DEBOUNCE_UNIT.tmp" &&
    mv -f "$DEBOUNCE_UNIT.tmp" "$DEBOUNCE_UNIT" &&
    cp "$HOOKS/netlisp-deploy-debounce.timer.in" "$DEBOUNCE_TIMER_UNIT.tmp" &&
    mv -f "$DEBOUNCE_TIMER_UNIT.tmp" "$DEBOUNCE_TIMER_UNIT"
}

echo "netlisp hook install — repo: $TOP"

if [ "$MODE" = "check" ]; then
  [ "$(git -C "$TOP" config --get core.hooksPath)" = "$HOOKS" ] \
    && ok "core.hooksPath -> .githooks" || bad "core.hooksPath NOT set to $HOOKS"
  for h in pre-commit pre-push post-merge post-commit post-checkout; do
    [ -x "$HOOKS/$h" ] && ok "hook $h executable" || warn "hook $h missing/not executable"
  done
  [ -x "$TOP/.git/hooks/post-merge" ] \
    && ok "prod auto-deploy ENABLED (machine-local launcher present)" \
    || warn "prod auto-deploy disabled on this machine (run --deploy to enable)"
  if [ -f "$UNIT" ]; then
    ok "systemd unit installed: $UNIT"
    grep -q '^Restart=always' "$UNIT" && ok "Restart=always" || bad "Restart is NOT always — a SIGTERM kill will leave prod down"
    echo "  service: $(systemctl --user is-active "$SERVICE" 2>/dev/null; true)"
  else
    warn "systemd unit not installed ($UNIT)"
  fi
  if [ -f "$CHECKPOINT_UNIT" ] && [ -f "$CHECKPOINT_TIMER_UNIT" ]; then
    ok "design checkpoint units installed (quiet period ${CHECKPOINT_QUIET_SECONDS}s)"
    echo "  timer: $(systemctl --user is-active "$CHECKPOINT_TIMER" 2>/dev/null; true)"
  else
    warn "design checkpoint units not installed"
  fi
  if [ -f "$DEBOUNCE_UNIT" ] && [ -f "$DEBOUNCE_TIMER_UNIT" ]; then
    ok "deploy worker units installed (merges deploy at once; timer is the crash/reboot backstop)"
    echo "  timer: $(systemctl --user is-active "$DEBOUNCE_TIMER" 2>/dev/null; true)"
  else
    warn "deploy worker units not installed — a marker queued mid-build has no crash/reboot backstop"
  fi
  # The live deploy state machine: RUNNING (the deploy lock is held right now),
  # QUEUED/SETTLING (a marker is armed — main is ahead of prod on purpose, and
  # for how much longer), HELD (the last deploy failed after consuming its
  # marker; nothing retries automatically), or idle.
  deploy_running=no
  if [ -e "$TOP/.git/deploy-on-merge.lock" ] &&
    ! flock -n "$TOP/.git/deploy-on-merge.lock" true 2>/dev/null; then
    deploy_running=yes
    warn "a deploy is RUNNING right now (holding .git/deploy-on-merge.lock; tail .git/deploy-on-merge.log)"
  fi
  if [ -f "$TOP/.git/deploy-pending" ]; then
    read -r pend_hash pend_at pend_win _ <"$TOP/.git/deploy-pending" 2>/dev/null || true
    case "${pend_at:-}" in
      '' | *[!0-9]*) warn "deploy queued, but .git/deploy-pending is unreadable" ;;
      *)
        case "${pend_win:-}" in '' | *[!0-9]*) pend_win="$DEBOUNCE_QUIET_SECONDS" ;; esac
        due=$((pend_win - ($(date +%s) - pend_at)))
        if [ "$deploy_running" = yes ]; then
          warn "deploy QUEUED at ${pend_hash:0:9} behind the running deploy — due in ${due}s (window ${pend_win}s)"
        else
          warn "deploy QUEUED at ${pend_hash:0:9} — due in ${due}s (window ${pend_win}s)"
        fi
        pending_commits "${pend_hash:-}"
        ;;
    esac
  elif [ "$deploy_running" = no ]; then
    ok "no deploy queued or running"
  fi
  if [ -f "$TOP/.git/deploy-failed-head" ]; then
    failed_head="$(cat "$TOP/.git/deploy-failed-head" 2>/dev/null)"
    bad "last deploy FAILED at ${failed_head:0:9} and nothing retries it automatically (HELD)"
    echo "      fix the cause, then: .githooks/deploy-debounce.sh --now   (a new merge also retries)"
  fi
  [ -f "$TOP/.git/deploy-lastgood-netlisp" ] \
    && ok "rollback target present ($(du -h "$TOP/.git/deploy-lastgood-netlisp" | cut -f1))" \
    || warn "no rollback target yet (seeded on the next healthy deploy)"
  # What the unit will actually exec. A deploy installs a STRIPPED ReleaseSafe
  # artifact here; an unstripped file means something else wrote this path (the
  # failure mode that put a Debug netlisp into prod on 2026-08-19, back when
  # this path was $TOP/zig-out/bin/netlisp and a plain `zig build` overwrote it).
  if [ -x "$PROD_BIN" ]; then
    if file -b "$PROD_BIN" 2>/dev/null | grep -q "debug_info"; then
      bad "prod binary at $PROD_BIN is a DEBUG build — a deploy installs a stripped ReleaseSafe artifact"
      echo "      restore it: cp .git/deploy-lastgood-netlisp $PROD_BIN && systemctl --user restart $SERVICE"
    else
      ok "prod binary present and stripped ($(du -h "$PROD_BIN" | cut -f1))"
    fi
  else
    warn "no prod binary at $PROD_BIN yet (installed by the first healthy deploy)"
  fi
  legacy_warn
  exit 0
fi

if [ "$MODE" = "uninstall" ]; then
  rm -f "$TOP/.git/hooks/post-merge" "$TOP/.git/hooks/post-commit"
  ok "removed machine-local deploy launchers — merges no longer deploy here"
  # The debounce timer is the other half of the same switch: leaving it running
  # would deploy an already-armed marker from a machine that just opted out.
  systemctl --user disable --now "$DEBOUNCE_TIMER" >/dev/null 2>&1 \
    && ok "deploy debounce timer stopped and disabled" \
    || warn "deploy debounce timer was not running"
  [ -f "$TOP/.git/deploy-pending" ] && rm -f "$TOP/.git/deploy-pending" \
    && ok "discarded the pending deferred deploy"
  rm -f "$TOP/.git/deploy-failed-head"
  echo "  (git hooks, the unit files and the netlisp service are left alone)"
  exit 0
fi

# --- hooks (always) -------------------------------------------------------
git -C "$TOP" config core.hooksPath "$HOOKS" && ok "core.hooksPath -> $HOOKS"
chmod +x "$HOOKS"/*.sh "$HOOKS"/pre-commit "$HOOKS"/pre-push "$HOOKS"/post-* 2>/dev/null
ok "hooks made executable"

if [ ! -x "$HOOKS/pre-commit" ]; then
  warn "no pre-commit hook — guardian-check manages that one; build guardian-zig and let it install"
fi

if [ "$MODE" != "deploy" ]; then
  echo
  echo "Hooks installed. Prod auto-deploy was NOT enabled (it rebuilds and restarts"
  echo "the $SERVICE systemd unit on every merge into main). To enable it here:"
  echo "    .githooks/install.sh --deploy"
  exit 0
fi

# --- deploy (opt-in) ------------------------------------------------------
mkdir -p "$(dirname "$PROD_BIN")" && ok "prod binary directory ready ($(dirname "$PROD_BIN"))"
write_launcher post-merge
write_launcher post-commit
ok "machine-local deploy launchers written to .git/hooks/"

if render_unit; then
  ok "systemd units rendered: $UNIT + $CHECKPOINT_TIMER + $DEBOUNCE_TIMER (port $PORT)"
  if systemctl --user daemon-reload 2>/dev/null; then
    ok "systemctl --user daemon-reload"
    systemctl --user enable "$SERVICE" >/dev/null 2>&1 && ok "unit enabled at login"
    systemctl --user enable --now "$CHECKPOINT_TIMER" >/dev/null 2>&1 \
      && ok "design checkpoint timer enabled and started"
    systemctl --user enable --now "$DEBOUNCE_TIMER" >/dev/null 2>&1 \
      && ok "deploy debounce timer enabled and started (quiet period ${DEBOUNCE_QUIET_SECONDS}s)"
    echo "  service is currently: $(systemctl --user is-active "$SERVICE" 2>/dev/null; true)"
    echo "  start it with: systemctl --user start $SERVICE"
  else
    warn "daemon-reload failed (no user systemd here?) — unit written but not loaded"
  fi
else
  bad "could not render $UNIT from $HOOKS/netlisp.service.in"
fi

legacy_warn

echo
echo "Done. Verify with: .githooks/install.sh --check"
