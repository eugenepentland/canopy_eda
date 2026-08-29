#!/usr/bin/env bash
# Build netlisp and run the server-page plus real-browser interaction gates.
#
#   scripts/perf_gate.sh            # enforce against the committed baseline
#                                   # (non-zero exit on any regression)
#   scripts/perf_gate.sh --record   # re-record the baseline in place; review
#                                   # and commit the diff deliberately
#
# The first gate verifies the baseline was recorded against the designs
# workload now measured (scripts/perf_gate_designs_identity.js — a moved
# workload is named as drift, never misreported as a latency regression), then
# compares `netlisp bench-page` phase medians against
# docs/benchmarks/pcb-page/baseline.json. The second starts a private loopback
# server and drives the real Barracuda Base assembly iframe in headless Chromium
# against docs/benchmarks/pcb-browser/baseline.json. The third gates the PCB
# editor's exact high-DPI zoom path; the fourth walks every interactive page
# surface against docs/benchmarks/ui-browser/baseline.json.
#
# It runs under scripts/gate.sh's machine-wide lock: a concurrent `zig build
# test` roughly doubles wall times (docs/testing-guide.md), which would fail
# honest commits. Server-page timings are Debug and browser timings use the
# pinned ReleaseSafe build; both are same-machine numbers, so a baseline
# recorded elsewhere or in another build mode compares nothing.
#
# Env: NETLISP_PERF_BASELINE, NETLISP_BROWSER_PERF_BASELINE,
# NETLISP_EDITOR_PERF_BASELINE, NETLISP_UI_PERF_BASELINE,
# NETLISP_PERF_PROJECT_DIR (default projects/designs), NETLISP_PERF_REPS (default 3),
# NETLISP_BROWSER_PERF_REPS (default 3), NETLISP_EDITOR_PERF_REPS (default 3),
# NETLISP_UI_PERF_REPS (default 3),
# NETLISP_BROWSER_PERF_BINARY.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASELINE="${NETLISP_PERF_BASELINE:-docs/benchmarks/pcb-page/baseline.json}"
BROWSER_BASELINE="${NETLISP_BROWSER_PERF_BASELINE:-docs/benchmarks/pcb-browser/baseline.json}"
EDITOR_BASELINE="${NETLISP_EDITOR_PERF_BASELINE:-docs/benchmarks/pcb-editor/baseline.json}"
UI_BASELINE="${NETLISP_UI_PERF_BASELINE:-docs/benchmarks/ui-browser/baseline.json}"
PROJECT_DIR="${NETLISP_PERF_PROJECT_DIR:-projects/designs}"
REPS="${NETLISP_PERF_REPS:-3}"
BROWSER_REPS="${NETLISP_BROWSER_PERF_REPS:-3}"
EDITOR_REPS="${NETLISP_EDITOR_PERF_REPS:-3}"
UI_REPS="${NETLISP_UI_PERF_REPS:-3}"
BROWSER_BINARY="${NETLISP_BROWSER_PERF_BINARY:-zig-out-browser-perf/bin/netlisp}"
PERF_PROJECT_SNAPSHOT=""

cleanup_perf_snapshot() {
  case "$PERF_PROJECT_SNAPSHOT" in
    /tmp/netlisp-perf-designs.*) [ ! -d "$PERF_PROJECT_SNAPSHOT" ] || rm -rf -- "$PERF_PROJECT_SNAPSHOT" ;;
  esac
}
trap cleanup_perf_snapshot EXIT

# Take the machine-wide gate lock, once. gate.sh sets NETLISP_GATE_HELD and execs,
# so the re-entered script falls through to the body as the lock holder.
lock="${NETLISP_GATE_LOCK:-/tmp/netlisp-gate.lock}"
if [ "${NETLISP_GATE_HELD:-}" != "$lock" ] && [ "${NETLISP_GATE_SERIALIZE:-1}" != "0" ]; then
  exec scripts/gate.sh bash "$0" "$@"
fi

if [ ! -d "$PROJECT_DIR/src" ]; then
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  shared_checkout="${common_dir%/.git}"
  if [ -n "$common_dir" ] && [ -d "$shared_checkout/projects/designs/src" ]; then
    PROJECT_DIR="$shared_checkout/projects/designs"
  fi
fi
if [ ! -d "$PROJECT_DIR/src" ]; then
  echo "perf_gate: no designs repo at $PROJECT_DIR — nothing to measure" >&2
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
if [ ! -d node_modules/playwright ]; then
  echo "perf_gate: Playwright is not installed — run npm ci first" >&2
  exit 1
fi

# Measure the committed designs sources plus an identified copy of the local
# generated-layout/model workload, never the writable live library itself.
# Besides making baselines reproducible, this prevents an unrelated tracked
# edit or a browser-generated sprite from masking or inventing a regression.
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  source_project_dir="$PROJECT_DIR"
  designs_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  layout_count="$(find "$source_project_dir/src" -type f \( -name '*.layouts.json' -o -name '*.autolayout.json' \) | wc -l)"
  bom_count="$(find "$source_project_dir/src" -type f -name '*.bom' | wc -l)"
  if [ "$layout_count" -eq 0 ]; then
    echo "perf_gate: no saved layout sidecars in $source_project_dir/src — refusing an empty page workload" >&2
    exit 1
  fi
  if [ "$bom_count" -eq 0 ]; then
    echo "perf_gate: no BOM sidecars in $source_project_dir/src — refusing an incomplete assembly workload" >&2
    exit 1
  fi
  PERF_PROJECT_SNAPSHOT="$(mktemp -d /tmp/netlisp-perf-designs.XXXXXX)"
  mkdir -p "$PERF_PROJECT_SNAPSHOT/lib/models"
  # The vendor models are ignored binary inputs. Reflink/copy only their
  # top-level files; generated .sprites starts empty and any benchmark write
  # stays inside the disposable snapshot.
  find "$source_project_dir/lib/models" -maxdepth 1 -type f \
    -exec cp -a --reflink=auto -t "$PERF_PROJECT_SNAPSHOT/lib/models" -- {} +
  mkdir -p "$PERF_PROJECT_SNAPSHOT/lib/models/.sprites"
  # Layout sidecars are intentionally local editor state, but they define the
  # placed benchmark corpus. Copy them at their exact relative paths.
  (cd "$source_project_dir" && find src -type f \( -name '*.layouts.json' -o -name '*.autolayout.json' \) -print0 \
    | tar --null -T - -cf -) | tar -xf - -C "$PERF_PROJECT_SNAPSHOT"
  # BOM sidecars are ignored generated inputs too, and assembly rendering uses
  # their resolved MPN, DNP, and grouping data instead of its fallback rows.
  (cd "$source_project_dir" && find src -type f -name '*.bom' -print0 \
    | tar --null -T - -cf -) | tar -xf - -C "$PERF_PROJECT_SNAPSHOT"
  # Extract tracked sources last so a dirty tracked file can never override
  # the selected commit (including tracked model configuration/files).
  git -C "$PROJECT_DIR" archive --format=tar "$designs_commit" | tar -xf - -C "$PERF_PROJECT_SNAPSHOT"
  models_fingerprint="$(cd "$PERF_PROJECT_SNAPSHOT/lib/models" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"
  layouts_fingerprint="$(cd "$PERF_PROJECT_SNAPSHOT" && find src -type f \( -name '*.layouts.json' -o -name '*.autolayout.json' \) -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"
  boms_fingerprint="$(cd "$PERF_PROJECT_SNAPSHOT" && find src -type f -name '*.bom' -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"
  PROJECT_DIR="$PERF_PROJECT_SNAPSHOT"
  export NETLISP_PERF_DESIGNS_COMMIT="$designs_commit"
  export NETLISP_PERF_DESIGNS_FINGERPRINT="$designs_commit:$models_fingerprint:$layouts_fingerprint:$boms_fingerprint"
  echo "perf_gate: measuring committed designs $designs_commit with model $models_fingerprint, layout $layouts_fingerprint, and BOM $boms_fingerprint bundles"
fi

# Refuse to compare latencies across different workloads before spending
# minutes measuring them: a designs-repo move otherwise surfaces as a page
# "latency regression" (FEEDBACK.md 2026-08-29). A non-zero check aborts here
# via set -e with the script's own named reason. The browser runners enforce
# the same identity from their baselines' reference.designs.
if [ "${1:-}" != "--record" ]; then
  node scripts/perf_gate_designs_identity.js check "$BASELINE"
fi

zig build --seed=1 -Doptimize=debug
# Page rendering and CAM generation are user-facing/benchmark work, so the
# browser half runs the pinned self-hosted ReleaseSafe artifact. A Debug server
# makes Barracuda's cold CAM payload take minutes and measures the wrong thing.
scripts/zig-prod build --seed=1 -Doptimize=safe -p zig-out-browser-perf

if [ "${1:-}" = "--record" ]; then
  mkdir -p "$(dirname "$BASELINE")"
  zig-out/bin/netlisp bench-page --project-dir "$PROJECT_DIR" --reps "$REPS" --json >"$BASELINE.tmp"
  # Carry the hand-set budgets forward and stamp the measured designs identity
  # (commit + model/layout/BOM bundle hashes) so the next enforce can tell
  # workload drift from regression.
  node scripts/perf_gate_designs_identity.js stamp "$BASELINE.tmp" "$BASELINE"
  mv -f "$BASELINE.tmp" "$BASELINE"
  echo "perf_gate: recorded $BASELINE — review the diff and commit it deliberately"
  node scripts/pcb_browser_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$BROWSER_REPS" \
    --baseline "$BROWSER_BASELINE" --record
  node scripts/pcb_editor_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$EDITOR_REPS" \
    --baseline "$EDITOR_BASELINE" --record
  node scripts/ui_browser_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$UI_REPS" \
    --baseline "$UI_BASELINE" --record
  exit 0
fi

page_status=0
browser_status=0
editor_status=0
ui_status=0
zig-out/bin/netlisp bench-page --project-dir "$PROJECT_DIR" --reps "$REPS" --baseline "$BASELINE" || page_status=$?
node scripts/pcb_browser_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$BROWSER_REPS" \
  --baseline "$BROWSER_BASELINE" || browser_status=$?
node scripts/pcb_editor_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$EDITOR_REPS" \
  --baseline "$EDITOR_BASELINE" || editor_status=$?
node scripts/ui_browser_perf/run.js --project-dir "$PROJECT_DIR" --binary "$BROWSER_BINARY" --reps "$UI_REPS" \
  --baseline "$UI_BASELINE" || ui_status=$?
if [ "$page_status" -ne 0 ] || [ "$browser_status" -ne 0 ] || [ "$editor_status" -ne 0 ] || [ "$ui_status" -ne 0 ]; then
  echo "perf_gate: FAIL (page=$page_status assembly_browser=$browser_status pcb_editor=$editor_status ui_browser=$ui_status)" >&2
  exit 1
fi
echo "perf_gate: PASS"
