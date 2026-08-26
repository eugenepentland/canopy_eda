#!/usr/bin/env bash
# Build netlisp and run the primary-page latency benchmark — enforcing or recording.
#
#   scripts/perf_gate.sh            # enforce against the committed baseline
#                                   # (non-zero exit on any regression)
#   scripts/perf_gate.sh --record   # re-record the baseline in place; review
#                                   # and commit the diff deliberately
#
# The gate compares `netlisp bench-page` phase medians (PCB, assembly, thermal,
# and schematic cold renders plus DRC, solve, eval, and sidecar parse) against
# docs/benchmarks/pcb-page/baseline.json. See that directory's README for the
# rules and workflow, and src/bench_page.zig for the exact measured seams.
#
# It runs under scripts/gate.sh's machine-wide lock: a concurrent `zig build
# test` roughly doubles wall times (docs/testing-guide.md), which would fail
# honest commits. Timings are Debug-build, same-machine numbers — a baseline
# recorded elsewhere or in another build mode compares nothing.
#
# Env: EDA_PERF_BASELINE, EDA_PERF_PROJECT_DIR (default projects/designs),
# EDA_PERF_REPS (default 3).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASELINE="${EDA_PERF_BASELINE:-docs/benchmarks/pcb-page/baseline.json}"
PROJECT_DIR="${EDA_PERF_PROJECT_DIR:-projects/designs}"
REPS="${EDA_PERF_REPS:-3}"

# Take the machine-wide gate lock, once. gate.sh sets EDA_GATE_HELD and execs,
# so the re-entered script falls through to the body as the lock holder.
lock="${EDA_GATE_LOCK:-/tmp/eda-gate.lock}"
if [ "${EDA_GATE_HELD:-}" != "$lock" ] && [ "${EDA_GATE_SERIALIZE:-1}" != "0" ]; then
  exec scripts/gate.sh bash "$0" "$@"
fi

if [ ! -d "$PROJECT_DIR/src" ]; then
  echo "perf_gate: no designs repo at $PROJECT_DIR — nothing to measure" >&2
  exit 1
fi

zig build

if [ "${1:-}" = "--record" ]; then
  mkdir -p "$(dirname "$BASELINE")"
  had_budgets=0
  [ -f "$BASELINE" ] && grep -q '"budgets"' "$BASELINE" && had_budgets=1
  zig-out/bin/netlisp bench-page --project-dir "$PROJECT_DIR" --reps "$REPS" --json >"$BASELINE.tmp"
  mv -f "$BASELINE.tmp" "$BASELINE"
  echo "perf_gate: recorded $BASELINE — review the diff and commit it deliberately"
  if [ "$had_budgets" = 1 ]; then
    echo "perf_gate: NOTE — the previous baseline carried a hand-set \"budgets\" object;" >&2
    echo "perf_gate: the recorder never writes one, so re-add it before committing." >&2
  fi
  exit 0
fi

exec zig-out/bin/netlisp bench-page --project-dir "$PROJECT_DIR" --reps "$REPS" --baseline "$BASELINE"
