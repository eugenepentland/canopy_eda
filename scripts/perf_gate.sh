#!/usr/bin/env bash
# Build netlisp and run the server-page and real-browser assembly benchmarks.
#
#   scripts/perf_gate.sh            # enforce against the committed baseline
#                                   # (non-zero exit on any regression)
#   scripts/perf_gate.sh --record   # re-record the baseline in place; review
#                                   # and commit the diff deliberately
#
# The first gate compares `netlisp bench-page` phase medians against
# docs/benchmarks/pcb-page/baseline.json. The second starts a private loopback
# server and drives the real Barracuda Base assembly iframe in headless Chromium
# against docs/benchmarks/pcb-browser/baseline.json.
#
# It runs under scripts/gate.sh's machine-wide lock: a concurrent `zig build
# test` roughly doubles wall times (docs/testing-guide.md), which would fail
# honest commits. Server-page timings are Debug and browser timings use the
# pinned ReleaseSafe build; both are same-machine numbers, so a baseline
# recorded elsewhere or in another build mode compares nothing.
#
# Env: EDA_PERF_BASELINE, EDA_BROWSER_PERF_BASELINE,
# EDA_PERF_PROJECT_DIR (default projects/designs), EDA_PERF_REPS (default 3),
# EDA_BROWSER_PERF_REPS (default 3), EDA_BROWSER_PERF_BINARY.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASELINE="${EDA_PERF_BASELINE:-docs/benchmarks/pcb-page/baseline.json}"
BROWSER_BASELINE="${EDA_BROWSER_PERF_BASELINE:-docs/benchmarks/pcb-browser/baseline.json}"
PROJECT_DIR="${EDA_PERF_PROJECT_DIR:-projects/designs}"
REPS="${EDA_PERF_REPS:-3}"
BROWSER_REPS="${EDA_BROWSER_PERF_REPS:-3}"
BROWSER_BINARY="${EDA_BROWSER_PERF_BINARY:-zig-out-browser-perf/bin/netlisp}"

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

zig build --seed=1 -Doptimize=debug
# Page rendering and CAM generation are user-facing/benchmark work, so the
# browser half runs the pinned self-hosted ReleaseSafe artifact. A Debug server
# makes Barracuda's cold CAM payload take minutes and measures the wrong thing.
scripts/zig-prod build --seed=1 -Doptimize=safe -p zig-out-browser-perf

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
  node scripts/pcb_browser_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$BROWSER_REPS" \
    --baseline "$BROWSER_BASELINE" --record
  exit 0
fi

page_status=0
browser_status=0
zig-out/bin/netlisp bench-page --project-dir "$PROJECT_DIR" --reps "$REPS" --baseline "$BASELINE" || page_status=$?
node scripts/pcb_browser_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$BROWSER_REPS" \
  --baseline "$BROWSER_BASELINE" || browser_status=$?
if [ "$page_status" -ne 0 ] || [ "$browser_status" -ne 0 ]; then
  echo "perf_gate: FAIL (page=$page_status browser=$browser_status)" >&2
  exit 1
fi
echo "perf_gate: PASS"
