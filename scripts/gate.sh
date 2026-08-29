#!/usr/bin/env bash
# Run one heavy build gate under a machine-wide exclusive lock.
#
# WHY: a speed audit (2026-08-10) measured concurrent agent sessions each
# running `zig build test` / the deployment-only ReleaseSafe build. The gate
# went from ~4.5 min
# solo to ~9.5 min with two or three sessions compiling at once, and the
# release ledger recorded the same test job at 527 s under contention vs 320 s
# alone. The deploy compile is one single-threaded LLVM module, so the loss is
# disk and memory contention rather than CPU sharing: queueing the gates is
# strictly faster in wall time than overlapping them, and it is far easier to
# read a serial log than three interleaved ones. This wrapper is that queue.
#
# Usage: scripts/gate.sh <command...>
#   NETLISP_GATE_LOCK=<path>    lock file            (default /tmp/netlisp-gate.lock)
#   NETLISP_GATE_WAIT=<seconds> how long to queue     (default 5400)
#   NETLISP_GATE_SERIALIZE=0    bypass the lock entirely (exec the command directly)
#
# Cheap work does not belong here — `zig build test -Dtest-filter=…` and
# `zig build test-compile` are seconds-to-10s jobs and should not wait behind
# somebody's 5-minute suite.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/gate.sh <command...>" >&2
  exit 2
fi

lock="${NETLISP_GATE_LOCK:-/tmp/netlisp-gate.lock}"
wait_secs="${NETLISP_GATE_WAIT:-5400}"

# Explicit opt-out, for a machine that is genuinely alone.
if [ "${NETLISP_GATE_SERIALIZE:-1}" = "0" ]; then
  exec "$@"
fi

# Recursion guard. flock(2) locks belong to the open file description, so a
# nested gate.sh (or a script that re-execs itself under the gate) would open a
# SECOND description of the same file and deadlock against its own parent for
# the whole timeout. Anything already inside this lock just runs.
if [ "${NETLISP_GATE_HELD:-}" = "$lock" ]; then
  exec "$@"
fi

exec 9>"$lock" || { echo "gate.sh: cannot open lock file $lock" >&2; exit 1; }

# Pids holding or awaiting the lock, left in $probed; both tools are
# best-effort. Waiters keep the file open on their own fd 9 while they queue,
# so the pids reported are the holder plus everyone queued ahead — the queue
# depth. `exec 9>&-` closes our inherited lock fd inside the probe subshell,
# so the probe does not report this process as a holder of the file it is
# asking about; our own pid still shows up through fd 9 and is dropped
# explicitly. The result travels by variable, not command substitution: a
# $(probe) subshell would itself hold fd 9 open and be counted as a phantom
# queue entry.
probe_lock_pids() {
  found="$(exec 9>&-; fuser "$lock" 2>/dev/null || true)"
  if [ -z "${found// /}" ]; then
    found="$(exec 9>&-; lsof -t -- "$lock" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  probed=""
  for pid in $found; do
    [ "$pid" = "$$" ] && continue
    # A queued waiter shows up as TWO pids on the fd: its gate.sh shell and
    # the flock(1) child doing the waiting. Count the shell, not the tool, so
    # depth means jobs ahead rather than open descriptors; a pid that exited
    # between the probes is dropped rather than listed nameless.
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    [ -z "$comm" ] && continue
    [ "$comm" = "flock" ] && continue
    probed="$probed $pid"
  done
}

# Try without waiting first, so a blocked entry reports what it is queued
# behind — and how deep the queue already is — instead of going silent for up
# to NETLISP_GATE_WAIT seconds.
if ! flock -n 9; then
  probe_lock_pids
  queued="$probed"
  depth=0
  for pid in $queued; do depth=$((depth + 1)); done
  {
    if [ "$depth" -gt 0 ]; then
      echo "gate.sh: blocked on $lock — queue depth $depth (holder + waiters ahead); waiting up to ${wait_secs}s"
      # shellcheck disable=SC2086
      ps -o pid=,etime=,args= -p $queued 2>/dev/null | sed 's/^/  /' || true
    else
      echo "gate.sh: blocked on $lock (holder not identifiable); waiting up to ${wait_secs}s"
    fi
  } >&2
  waited_from=$SECONDS
  if ! flock -w "$wait_secs" 9; then
    probe_lock_pids
    holders="$probed"
    {
      echo "gate.sh: timed out after ${wait_secs}s waiting for $lock"
      if [ -n "${holders// /}" ]; then
        echo "gate.sh: lock held by pid(s): $holders"
        # shellcheck disable=SC2086
        ps -o pid=,etime=,args= -p $holders 2>/dev/null | sed 's/^/  /' || true
      else
        echo "gate.sh: could not identify the holder (fuser/lsof found nothing)"
      fi
      echo "gate.sh: raise NETLISP_GATE_WAIT, or set NETLISP_GATE_SERIALIZE=0 to bypass the queue"
    } >&2
    exit 75 # EX_TEMPFAIL — distinct from the gated command's own failure codes
  fi
  echo "gate.sh: acquired $lock after $((SECONDS - waited_from))s in the queue" >&2
fi

# The lock lives on fd 9, which survives exec, so the gated command *becomes*
# the holder: no wrapper process lingers, and the kernel releases the lock when
# that process dies however it dies.
export NETLISP_GATE_HELD="$lock"
exec "$@"
