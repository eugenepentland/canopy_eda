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

if ! flock -w "$wait_secs" 9; then
  # Name the holder if the system can tell us; both tools are best-effort.
  # `exec 9>&-` closes our inherited lock fd inside the probe subshell, so the
  # probe does not report itself as a holder of the file it is asking about.
  found="$(exec 9>&-; fuser "$lock" 2>/dev/null || true)"
  if [ -z "${found// /}" ]; then
    found="$(exec 9>&-; lsof -t -- "$lock" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  # We hold the file open on fd 9 ourselves while waiting, so drop our own pid.
  holders=""
  for pid in $found; do
    [ "$pid" = "$$" ] || holders="$holders $pid"
  done
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

# The lock lives on fd 9, which survives exec, so the gated command *becomes*
# the holder: no wrapper process lingers, and the kernel releases the lock when
# that process dies however it dies.
export NETLISP_GATE_HELD="$lock"
exec "$@"
