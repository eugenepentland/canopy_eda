#!/usr/bin/env bash
# Behaviour test for the coalesced-deploy path: every merge queues through
# .git/deploy-pending at window 0 (.githooks/deploy-prod.sh arms and execs the
# worker in the same breath — no hold period; the `Deploy: skip` trailer is
# retired and only logs a note), and the worker (.githooks/deploy-debounce.sh)
# deploys the accumulated head, looping when a due marker re-armed mid-deploy
# and holding a failed head for --now / the next merge. Positive windows
# remain reachable via the DEPLOY_SETTLE_SECONDS knob and are exercised here
# through it.
#
# Runs entirely inside a throwaway git repo under $TMPDIR, against COPIES of the
# tracked scripts, with the expensive tail of deploy-prod.sh (candidate prepare,
# binary install, systemctl restart, health check) replaced by a stub. Nothing
# it does can reach the real repo, the real units, or production.
#
#   scripts/test_deploy_debounce.sh
#
# Not wired into `zig build test` — the suite is the Zig unit binary and these
# are shell/systemd seams. Run it by hand when touching any of the scripts.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../.githooks" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ck() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
    pass=$((pass + 1))
  else
    echo "  FAIL $1: want '$3', got '$2'"
    fail=$((fail + 1))
  fi
}

git init -q "$T/repo"
cd "$T/repo" || exit 1
git config user.email test@example.invalid
git config user.name test
mkdir -p .githooks
cp "$SRC/deploy-prod.sh" "$SRC/deploy-debounce.sh" .githooks/
chmod +x .githooks/*.sh
echo x >f
git add -A
git commit -qm root

# Replace everything from the rollback-target bootstrap onward. The dedup,
# arming, lock, post-lock recheck and failed-head-trap logic ABOVE that point —
# the whole subject of this test — runs verbatim from the tracked file. The
# stub mirrors the success tail's contract (record last-hash, settle only a
# covered marker, clear the failed-head hold), and two flag files inject the
# interesting mid-deploy events: .git/stub-rearm-once simulates an ordinary
# merge landing DURING the build (new commit + a window-0 marker, which the
# settle guard must keep and the worker loop must then deploy), and
# .git/stub-fail-once simulates a deploy that dies after consuming its marker
# (the REAL trap above the stub records the failed head).
if ! python3 - <<'PY'
import sys
p = ".githooks/deploy-prod.sh"
s = open(p).read()
marker = "# Bootstrap the rollback target"
if marker not in s:
    sys.exit("stub marker not found in deploy-prod.sh — update this test")
open(p, "w").write(s[:s.index(marker)] + '''echo "[$(ts)] STUB: would build+restart"
if [ -f .git/stub-rearm-once ]; then
  rm -f .git/stub-rearm-once
  git commit -q --allow-empty -m "landed mid-deploy"
  printf '%s %s %s\\n' "$(git rev-parse HEAD)" "$(date +%s)" 0 >"$PENDING"
fi
if [ -f .git/stub-fail-once ]; then
  rm -f .git/stub-fail-once
  echo "[$(ts)] STUB: simulated build/health failure"
  exit 1
fi
echo "$head_hash" >"$last_file"
settle_pending "$head_hash"
rm -f "$FAILED_HEAD"
echo "[$(ts)] deploy end"
exit 0
''')
PY
then
  echo "FATAL: could not stub deploy-prod.sh — refusing to run an unstubbed deploy" >&2
  exit 1
fi
grep -q 'STUB: would build+restart' .githooks/deploy-prod.sh || {
  echo "FATAL: stub did not take" >&2
  exit 1
}

LOG=.git/deploy-on-merge.log
SETTLE=120
QUIET=900
# No systemd timer exists for a throwaway repo, and deploy-prod.sh refuses to
# defer a POSITIVE window into a void (window 0 is its own worker and needs no
# timer). Empty = "something other than the unit runs the worker", which is
# exactly true here: this script runs it.
export DEPLOY_DEBOUNCE_TIMER=
export DEPLOY_DEBOUNCE_QUIET_SECONDS="$QUIET"
run_deploy() { .githooks/deploy-prod.sh >/dev/null 2>&1; }
run_deploy_settled() { DEPLOY_SETTLE_SECONDS="$SETTLE" .githooks/deploy-prod.sh >/dev/null 2>&1; }
run_debounce() { .githooks/deploy-debounce.sh >/dev/null 2>&1; }
deployed() { cat .git/deploy-last-hash 2>/dev/null; }
have_marker() { [ -e .git/deploy-pending ] && echo yes || echo no; }
armed_hash() { read -r h _ <.git/deploy-pending 2>/dev/null; echo "${h:-none}"; }
armed_at() { read -r _ a _ <.git/deploy-pending 2>/dev/null; echo "${a:-none}"; }
armed_window() { read -r _ _ w _ <.git/deploy-pending 2>/dev/null; echo "${w:-none}"; }
stub_runs() { grep -c 'STUB: would build+restart' "$LOG" 2>/dev/null || echo 0; }
backdate() { # $1 = hash, $2 = window (marker stamped past-due for that window)
  printf '%s %s %s\n' "$1" "$(($(date +%s) - $2 - 1))" "$2" >.git/deploy-pending
}

echo "== 1. an ordinary merge on an idle box deploys IMMEDIATELY =="
git commit -q --allow-empty -m "ordinary change"
run_deploy
ck "deployed at once" "$(deployed)" "$(git rev-parse HEAD)"
ck "nothing left armed" "$(have_marker)" "no"
ck "went through the worker" "$(grep -c 'window 0 — running the worker now' "$LOG")" "1"

echo "== 2. DEPLOY_SETTLE_SECONDS>0 restores a settle delay for ordinary merges =="
before="$(deployed)"
git commit -q --allow-empty -m "settled change"
run_deploy_settled
ck "prod not touched" "$(deployed)" "$before"
ck "armed at HEAD" "$(armed_hash)" "$(git rev-parse HEAD)"
ck "settle window recorded" "$(armed_window)" "$SETTLE"
run_debounce
ck "worker holds inside the window" "$(deployed)" "$before"
backdate "$(git rev-parse HEAD)" "$SETTLE"
run_debounce
ck "deploys once it elapses" "$(deployed)" "$(git rev-parse HEAD)"
ck "disarmed" "$(have_marker)" "no"

echo "== 3. the RETIRED 'Deploy: skip' trailer deploys immediately, with a note =="
git commit -q --allow-empty -m "cleanup

Deploy: skip"
run_deploy
ck "deployed at once despite the trailer" "$(deployed)" "$(git rev-parse HEAD)"
ck "nothing left armed" "$(have_marker)" "no"
ck "retirement noted in the log" "$(grep -c 'trailer is RETIRED' "$LOG")" "1"
git commit -q --allow-empty -m "mentions Deploy: skip inline in prose, not on its own line"
run_deploy
ck "prose mention deploys with no note" "$(grep -c 'trailer is RETIRED' "$LOG")" "1"

echo "== 4. an ordinary merge landing during a settle hold ships the whole batch NOW =="
git commit -q --allow-empty -m "held by the knob"
run_deploy_settled
ck "knob armed a hold" "$(have_marker)" "yes"
git commit -q --allow-empty -m "urgent follow-up"
run_deploy
ck "deployed immediately, batch included" "$(deployed)" "$(git rev-parse HEAD)"
ck "disarmed" "$(have_marker)" "no"

echo "== 5. a further settled merge RESETS the clock and re-targets the marker =="
git commit -q --allow-empty -m "held again"
run_deploy_settled
backdate "$(git rev-parse HEAD)" "$SETTLE" # would be due right now...
git commit -q --allow-empty -m "settled follow-up"
run_deploy_settled # ...but re-arming must undo that
ck "retargeted to the new HEAD" "$(armed_hash)" "$(git rev-parse HEAD)"
ck "window recorded" "$(armed_window)" "$SETTLE"
ck "clock restarted" "$([ $(($(date +%s) - $(armed_at))) -lt 10 ] && echo yes || echo no)" "yes"
before="$(deployed)"
run_debounce
ck "reset defeated the backdate" "$(deployed)" "$before"

echo "== 6. the worker deploys without re-arming, targeting main NOW =="
git commit -q --allow-empty -m "c2 landed after arming"
arms_before="$(grep -c 'armed the deploy debounce' "$LOG")"
backdate "$(armed_hash)" "$SETTLE" # marker still names the older commit
run_debounce
ck "deployed the newer HEAD" "$(deployed)" "$(git rev-parse HEAD)"
ck "logged the advance" "$(grep -c 'main advanced to' "$LOG")" "1"
ck "worker did not re-arm" "$(grep -c 'armed the deploy debounce' "$LOG")" "$arms_before"

echo "== 7. merges landing mid-build queue and chain the moment it finishes =="
exec 8>.git/deploy-on-merge.lock
flock 8 # simulate a deploy in flight
git commit -q --allow-empty -m "landed mid-build 1"
run_deploy &
d1=$!
sleep 1
git commit -q --allow-empty -m "landed mid-build 2"
run_deploy &
d2=$!
sleep 1
builds_before="$(stub_runs)"
ck "not deployed while the build runs" "$([ "$(deployed)" = "$(git rev-parse HEAD)" ] && echo deployed || echo queued)" "queued"
flock -u 8
exec 8>&-
wait "$d1" "$d2"
ck "deployed the moment the lock released" "$(deployed)" "$(git rev-parse HEAD)"
ck "TWO queued merges cost ONE build" "$(stub_runs)" "$((builds_before + 1))"
ck "nothing left armed" "$(have_marker)" "no"

echo "== 8. a window-0 marker re-armed MID-deploy survives the settle guard and chains =="
git commit -q --allow-empty -m "first of two"
: >.git/stub-rearm-once
run_deploy
ck "second (mid-deploy) head deployed in the same run" "$(deployed)" "$(git rev-parse HEAD)"
ck "loop announced itself" "$(grep -c 'window is already due' "$LOG")" "1"
ck "disarmed" "$(have_marker)" "no"

echo "== 9. a FAILED deploy holds: failed-head recorded, no auto-retry, --now retries =="
git commit -q --allow-empty -m "will fail"
: >.git/stub-fail-once
run_deploy
ck "deploy chain reported failure" "$?" "1"
ck "prod not advanced" "$([ "$(deployed)" = "$(git rev-parse HEAD)" ] && echo advanced || echo held)" "held"
ck "failed head recorded" "$(cat .git/deploy-failed-head 2>/dev/null)" "$(git rev-parse HEAD)"
ck "marker consumed (no retry loop)" "$(have_marker)" "no"
backdate "$(git rev-parse HEAD)" "$SETTLE"
.githooks/deploy-debounce.sh --now >/dev/null 2>&1
ck "--now retried and deployed" "$(deployed)" "$(git rev-parse HEAD)"
ck "hold cleared" "$([ -f .git/deploy-failed-head ] && echo held || echo clear)" "clear"

echo "== 10. with nothing queued the timer is a silent no-op =="
before_bytes="$(wc -c <"$LOG")"
run_debounce
ck "log untouched" "$(wc -c <"$LOG")" "$before_bytes"

echo "== 11. an unreadable marker is discarded, not obeyed forever =="
echo garbage >.git/deploy-pending
run_debounce
ck "discarded" "$(have_marker)" "no"

echo "== 12. a marker stamped in the future is due, not stuck =="
git commit -q --allow-empty -m "future"
printf '%s %s %s\n' "$(git rev-parse HEAD)" "$(($(date +%s) + 99999))" "$SETTLE" >.git/deploy-pending
run_debounce
ck "deployed anyway" "$(deployed)" "$(git rev-parse HEAD)"

echo "== 13. a legacy two-field marker falls back to the long window =="
git commit -q --allow-empty -m "legacy marker"
printf '%s %s\n' "$(git rev-parse HEAD)" "$(($(date +%s) - SETTLE - 1))" >.git/deploy-pending
run_debounce
ck "short elapse does not fire it" "$(have_marker)" "yes"
printf '%s %s\n' "$(git rev-parse HEAD)" "$(($(date +%s) - QUIET - 1))" >.git/deploy-pending
run_debounce
ck "long elapse does" "$(deployed)" "$(git rev-parse HEAD)"

echo "== 14. --now deploys the pending merge without waiting =="
git commit -q --allow-empty -m "impatient"
run_deploy_settled
ck "armed" "$(have_marker)" "yes"
.githooks/deploy-debounce.sh --now >/dev/null 2>&1
ck "deployed immediately" "$(deployed)" "$(git rev-parse HEAD)"
ck "disarmed" "$(have_marker)" "no"
.githooks/deploy-debounce.sh --now >/dev/null 2>&1
ck "--now with nothing pending is exit 0" "$?" "0"
.githooks/deploy-debounce.sh --bogus >/dev/null 2>&1
ck "unknown flag is a usage error" "$?" "2"

echo "== 15. DEPLOY_DRY_RUN writes nothing =="
git commit -q --allow-empty -m "dry"
DEPLOY_DRY_RUN=1 .githooks/deploy-prod.sh >/dev/null 2>&1
ck "no marker and no deploy from a dry-run merge" "$(have_marker)+$([ "$(deployed)" = "$(git rev-parse HEAD)" ] && echo deployed || echo held)" "no+held"
run_deploy_settled
backdate "$(git rev-parse HEAD)" "$SETTLE"
DEPLOY_DRY_RUN=1 .githooks/deploy-debounce.sh >/dev/null 2>&1
ck "dry-run worker leaves the marker armed" "$(have_marker)" "yes"
rm -f .git/deploy-pending

echo "== 16. window 0 needs no timer; a POSITIVE window with none deploys now =="
git commit -q --allow-empty -m "no timer installed"
# A unit name that certainly is not active. Window 0 is its own worker, so the
# ordinary merge deploys through the normal path with no warning...
DEPLOY_DEBOUNCE_TIMER=netlisp-deploy-debounce-nope.timer .githooks/deploy-prod.sh >/dev/null 2>&1
ck "ordinary merge deployed" "$(deployed)" "$(git rev-parse HEAD)"
ck "no stranding warning for it" "$(grep -c 'is not active' "$LOG")" "0"
# ...while arming a positive window (the settle knob) would strand the marker
# forever, so it deploys immediately with the warning instead.
git commit -q --allow-empty -m "no timer, settle knob"
DEPLOY_DEBOUNCE_TIMER=netlisp-deploy-debounce-nope.timer DEPLOY_SETTLE_SECONDS="$SETTLE" \
  .githooks/deploy-prod.sh >/dev/null 2>&1
ck "settled merge deployed instead of arming" "$(deployed)" "$(git rev-parse HEAD)"
ck "nothing armed" "$(have_marker)" "no"
ck "said why" "$(grep -c 'is not active' "$LOG")" "1"

echo "== 17. wait-deploy: due queues are waited out, long deferrals exit 2 =="
cp "$SRC/wait-deploy.sh" .githooks/ && chmod +x .githooks/wait-deploy.sh
git commit -q --allow-empty -m "waited on"
# A positive-window hold now only arises from the knob (or a legacy marker) —
# arm one well beyond the wait's deadline.
printf '%s %s %s\n' "$(git rev-parse HEAD)" "$(date +%s)" "$QUIET" >.git/deploy-pending
start=$SECONDS
.githooks/wait-deploy.sh 30 >/dev/null 2>&1
ck "long window beyond deadline = exit 2" "$?" "2"
ck "returned promptly" "$([ $((SECONDS - start)) -lt 15 ] && echo yes || echo no)" "yes"
# A marker due inside the deadline is the normal queue: no exit 2, keep
# polling (nothing deploys here, so it times out as a plain failure).
backdate "$(git rev-parse HEAD)" "$SETTLE"
.githooks/wait-deploy.sh 4 >/dev/null 2>&1
ck "due marker is polled, not refused" "$?" "1"
rm -f .git/deploy-pending
# Success is ancestry: a newer coalesced head that CONTAINS ours ships us.
old="$(git rev-parse HEAD)"
git commit -q --allow-empty -m "coalesced on top"
git rev-parse HEAD >.git/deploy-last-hash
WAIT_DEPLOY_EXPECT="$old" .githooks/wait-deploy.sh 10 >/dev/null 2>&1
ck "shipped inside a newer head = success" "$?" "0"
# A marker naming an OLDER head must not be mistaken for this head's deferral.
printf '%s %s %s\n' "0000000000000000000000000000000000000000" "$(date +%s)" "$QUIET" >.git/deploy-pending
git commit -q --allow-empty -m "not covered by that marker"
.githooks/wait-deploy.sh 4 >/dev/null 2>&1
ck "unrelated marker still times out" "$?" "1"
rm -f .git/deploy-pending

echo "== 18. the retirement note is case/space tolerant, like the trailer was =="
notes_before="$(grep -c 'trailer is RETIRED' "$LOG")"
git commit -q --allow-empty -m "case and spacing

deploy:   SKIP"
run_deploy
ck "odd-case trailer still deploys" "$(deployed)" "$(git rev-parse HEAD)"
ck "and still gets the note" "$(grep -c 'trailer is RETIRED' "$LOG")" "$((notes_before + 1))"

echo "== 19. --check reports QUEUED / RUNNING / HELD and lists what would ship =="
# install.sh --check is read-only and refuses LINKED worktrees; a throwaway
# `git init` repo is a main checkout, so it runs here. Its systemd probes read
# the real user units, which is harmless — only the state lines are asserted.
cp "$SRC/install.sh" .githooks/ && chmod +x .githooks/install.sh
checked() { .githooks/install.sh --check 2>&1; }
branch_now="$(git rev-parse --abbrev-ref HEAD)"
rm -f .git/deploy-pending .git/deploy-last-hash .git/deploy-failed-head
git commit -q --allow-empty -m "live one"
git rev-parse HEAD >.git/deploy-last-hash
git commit -q --allow-empty -m "pending alpha"
run_deploy_settled
git commit -q --allow-empty -m "pending beta"
run_deploy_settled
out="$(checked)"
ck "reports QUEUED with its window" "$(printf '%s\n' "$out" | grep -c "deploy QUEUED at .* (window ${SETTLE}s)")" "1"
ck "counts both waiting commits" "$(printf '%s\n' "$out" | grep -c '2 commit(s) waiting')" "1"
ck "names the newest subject" "$(printf '%s\n' "$out" | grep -c 'pending beta')" "1"
ck "names the older subject too" "$(printf '%s\n' "$out" | grep -c 'pending alpha')" "1"
ck "omits the already-live one" "$(printf '%s\n' "$out" | grep -c 'live one')" "0"

# A held deploy lock reads as RUNNING, and an armed marker queues behind it.
( exec 8>.git/deploy-on-merge.lock && flock 8 && sleep 3 ) &
locker=$!
sleep 1
out="$(checked)"
ck "reports RUNNING while the lock is held" "$(printf '%s\n' "$out" | grep -c 'RUNNING right now')" "1"
ck "marker shown queued behind it" "$(printf '%s\n' "$out" | grep -c 'behind the running deploy')" "1"
wait "$locker"

# A failed-head hold is a loud HELD line with the retry command.
echo "0123456789abcdef0123456789abcdef01234567" >.git/deploy-failed-head
out="$(checked)"
ck "reports the HELD failure" "$(printf '%s\n' "$out" | grep -c 'FAILED at 012345678')" "1"
ck "names the retry command" "$(printf '%s\n' "$out" | grep -c 'deploy-debounce.sh --now')" "1"
rm -f .git/deploy-failed-head

# The baseline is what prod is RUNNING, so a marker at the live commit ships nothing.
printf '%s %s %s\n' "$(git rev-parse HEAD)" "$(date +%s)" "$SETTLE" >.git/deploy-pending
git rev-parse HEAD >.git/deploy-last-hash
ck "marker at live commit says so" "$(checked | grep -c 'deploy nothing new')" "1"

# A live commit off the armed head's history must not yield a plausible-but-wrong list.
git checkout -q --orphan sidetrack
git commit -q --allow-empty -m "unrelated line"
git rev-parse HEAD >.git/deploy-last-hash
git checkout -q "$branch_now"
printf '%s %s %s\n' "$(git rev-parse HEAD)" "$(date +%s)" "$SETTLE" >.git/deploy-pending
ck "diverged history refuses to list" "$(checked | grep -c 'diverged history')" "1"

# Nothing ever deployed: there is no baseline to diff against, so say that.
rm -f .git/deploy-last-hash
ck "no recorded deploy is stated" "$(checked | grep -c 'no successful deploy recorded yet')" "1"

# A marker naming a commit this checkout lacks must report, not abort the run.
printf '%s %s %s\n' "0000000000000000000000000000000000000000" "$(date +%s)" "$SETTLE" >.git/deploy-pending
ck "unknown commit is not fatal" "$(checked | grep -c 'no such commit in this checkout')" "1"
rm -f .git/deploy-pending

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
