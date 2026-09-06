#!/usr/bin/env bash
# Build netlisp and run the server-page plus real-browser interaction gates.
#
#   scripts/perf_gate.sh            # enforce against the committed baseline
#                                   # (non-zero exit on any regression)
#   scripts/perf_gate.sh --record   # re-record the baseline in place; review
#                                   # and commit the diff deliberately
#   scripts/perf_gate.sh --resolve-workload
#                                   # resolve + report which workload an
#                                   # enforce run would measure, and stop
#                                   # before building or timing anything
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
# THE WORKLOAD IS PINNED, NOT LIVE. The designs library is edited and
# auto-committed all day, so a baseline recorded this morning named a workload
# that no longer exists by lunchtime and every push was refused as "workload
# changed" (a gate that needs a quiet-host re-record after every board edit is
# a gate nobody runs). So `--record` also SAVES the snapshot it measured, as a
# tarball under a machine-local store, and an enforce run whose live workload
# has drifted measures the RECORDED one: restored from that store, or rebuilt
# from the recorded designs commit plus the current ignored bundles when their
# hashes still match it exactly. Only when neither is possible does the gate
# refuse, which is then a true "this machine cannot reproduce the recording"
# rather than "a board moved". docs/benchmarks/pcb-page/README.md § How the
# workload is pinned has the rules.
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
# NETLISP_BROWSER_PERF_BINARY,
# NETLISP_PERF_WORKLOAD_STORE (default ~/.cache/netlisp/perf-workload),
# NETLISP_PERF_WORKLOAD_KEEP (default 3 stored snapshots),
# NETLISP_PERF_SNAPSHOT_ROOT (default /tmp — where the disposable copy lives).
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
# Never /tmp for the store: that tmpfs carries a per-user quota here and stale
# prefixes have filled it before. The disposable snapshot still defaults there
# (it is deleted on exit); NETLISP_PERF_SNAPSHOT_ROOT moves it onto disk.
WORKLOAD_STORE="${NETLISP_PERF_WORKLOAD_STORE:-$HOME/.cache/netlisp/perf-workload}"
WORKLOAD_KEEP="${NETLISP_PERF_WORKLOAD_KEEP:-3}"
SNAPSHOT_ROOT="${NETLISP_PERF_SNAPSHOT_ROOT:-/tmp}"
PERF_PROJECT_SNAPSHOT=""
STAGED_WORKLOAD_TAR=""

cleanup_perf_snapshot() {
  # Only ever a directory this script minted: the name is the guard.
  case "$PERF_PROJECT_SNAPSHOT" in
    */netlisp-perf-designs.*) [ ! -d "$PERF_PROJECT_SNAPSHOT" ] || rm -rf -- "$PERF_PROJECT_SNAPSHOT" ;;
  esac
  # A recording's snapshot is tarred before it is measured and installed into
  # the store only once the recording is accepted; a refused run leaves nothing.
  [ -z "$STAGED_WORKLOAD_TAR" ] || rm -f -- "$STAGED_WORKLOAD_TAR"
}
trap cleanup_perf_snapshot EXIT

MODE=enforce
case "${1:-}" in
  --record) MODE=record ;;
  --resolve-workload) MODE=resolve ;;
  "") ;;
  *) echo "usage: scripts/perf_gate.sh [--record | --resolve-workload]" >&2; exit 2 ;;
esac

# Take the machine-wide gate lock, once. gate.sh sets NETLISP_GATE_HELD and execs,
# so the re-entered script falls through to the body as the lock holder.
# --resolve-workload queues too: it copies a couple of hundred megabytes of
# workload around, which is exactly the kind of disk traffic that skews a gated
# run in another session.
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

# ── The measured workload ────────────────────────────────────────────────────
# Measure the committed designs sources plus an identified copy of the local
# generated-layout/model workload, never the writable live library itself.
# Besides making baselines reproducible, this prevents an unrelated tracked
# edit or a browser-generated sprite from masking or inventing a regression.

# Assemble one disposable snapshot: the local ignored workload bundles, then
# the tracked sources of `$2` extracted over them.
assemble_workload_snapshot() {
  dest="$1"
  commit="$2"
  rm -rf -- "$dest"
  mkdir -p "$dest/lib/models"
  # The vendor models are ignored binary inputs. Reflink/copy only their
  # top-level files; generated .sprites starts empty and any benchmark write
  # stays inside the disposable snapshot.
  if [ -d "$source_project_dir/lib/models" ]; then
    find "$source_project_dir/lib/models" -maxdepth 1 -type f \
      -exec cp -a --reflink=auto -t "$dest/lib/models" -- {} +
  fi
  mkdir -p "$dest/lib/models/.sprites"
  # Layout sidecars are intentionally local editor state, but they define the
  # placed benchmark corpus. Copy them at their exact relative paths.
  (cd "$source_project_dir" && find src -type f \( -name '*.layouts.json' -o -name '*.autolayout.json' \) -print0 \
    | tar --null -T - -cf -) | tar -xf - -C "$dest"
  # BOM sidecars are ignored generated inputs too, and assembly rendering uses
  # their resolved MPN, DNP, and grouping data instead of its fallback rows.
  (cd "$source_project_dir" && find src -type f -name '*.bom' -print0 \
    | tar --null -T - -cf -) | tar -xf - -C "$dest"
  # Extract tracked sources last so a dirty tracked file can never override
  # the selected commit (including tracked model configuration/files).
  git -C "$source_project_dir" archive --format=tar "$commit" | tar -xf - -C "$dest"
}

# Hash an assembled snapshot into `<commit>:<models>:<layouts>:<boms>`. Called
# in a command substitution, so it reports through stdout only — the three
# bundle hashes are read back out of the fingerprint where they are printed.
workload_fingerprint() {
  dir="$1"
  commit="$2"
  models="$(cd "$dir/lib/models" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"
  layouts="$(cd "$dir" && find src -type f \( -name '*.layouts.json' -o -name '*.autolayout.json' \) -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"
  boms="$(cd "$dir" && find src -type f -name '*.bom' -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"
  printf '%s:%s:%s:%s' "$commit" "$models" "$layouts" "$boms"
}

# Store file names: a fingerprint is ~235 characters of hex and colons, so the
# stored snapshot is keyed by the short commit plus a digest of the whole
# fingerprint, with the full text beside it for whoever reads the directory.
workload_slug() {
  printf '%s-%s' "$(printf '%s' "${1%%:*}" | cut -c1-12)" "$(printf '%s' "$1" | sha256sum | cut -c1-16)"
}

# Keep the newest few snapshots; each is as large as the designs workload.
prune_workload_store() {
  [ -d "$WORKLOAD_STORE" ] || return 0
  ls -1t "$WORKLOAD_STORE"/*.tar 2>/dev/null | tail -n "+$((WORKLOAD_KEEP + 1))" | while read -r stale; do
    rm -f -- "$stale" "${stale%.tar}.fingerprint"
  done
}

# Install an already-staged tar (or tar the snapshot now) as the stored copy of
# the workload `$2`. Best effort: a store that cannot be written costs the next
# drifted run a reconstruction, never this run's verdict.
store_workload_snapshot() {
  dir="$1"
  fingerprint="$2"
  staged="${3:-}"
  slug="$(workload_slug "$fingerprint")"
  if ! mkdir -p "$WORKLOAD_STORE"; then
    echo "perf_gate: could not create the workload store $WORKLOAD_STORE — not saving this snapshot" >&2
    return 0
  fi
  if [ -z "$staged" ]; then
    staged="$WORKLOAD_STORE/.staging.$$.tar"
    if ! tar -cf "$staged" -C "$dir" .; then
      rm -f -- "$staged"
      echo "perf_gate: could not archive the measured workload — not saving this snapshot" >&2
      return 0
    fi
  fi
  mv -f -- "$staged" "$WORKLOAD_STORE/$slug.tar"
  printf '%s\n' "$fingerprint" >"$WORKLOAD_STORE/$slug.fingerprint"
  prune_workload_store
  echo "perf_gate: saved the measured workload snapshot as $WORKLOAD_STORE/$slug.tar"
}

# Restore the stored snapshot for `$1` into the disposable snapshot dir, and
# prove by re-hashing that it is what it claims to be.
restore_workload_snapshot() {
  fingerprint="$1"
  slug="$(workload_slug "$fingerprint")"
  stored="$WORKLOAD_STORE/$slug.tar"
  [ -f "$stored" ] || return 1
  rm -rf -- "$PERF_PROJECT_SNAPSHOT"
  mkdir -p "$PERF_PROJECT_SNAPSHOT"
  if ! tar -xf "$stored" -C "$PERF_PROJECT_SNAPSHOT"; then
    echo "perf_gate: stored workload snapshot $stored could not be extracted" >&2
    return 1
  fi
  restored="$(workload_fingerprint "$PERF_PROJECT_SNAPSHOT" "${fingerprint%%:*}")"
  if [ "$restored" != "$fingerprint" ]; then
    echo "perf_gate: stored workload snapshot $stored no longer hashes to its own name — ignoring it" >&2
    return 1
  fi
  return 0
}

# Rebuild the recorded workload from the designs repo: its recorded commit plus
# the bundles present now. Accepted only on an exact fingerprint match — a
# rebuild that is merely close is a different workload.
rebuild_workload_snapshot() {
  want_commit="$1"
  want_fingerprint="$2"
  if ! git -C "$source_project_dir" cat-file -e "$want_commit^{commit}" 2>/dev/null; then
    echo "perf_gate: designs commit ${want_commit:0:12} is not in $source_project_dir, so the recorded workload cannot be rebuilt here" >&2
    return 1
  fi
  assemble_workload_snapshot "$PERF_PROJECT_SNAPSHOT" "$want_commit"
  rebuilt="$(workload_fingerprint "$PERF_PROJECT_SNAPSHOT" "$want_commit")"
  if [ "$rebuilt" != "$want_fingerprint" ]; then
    echo "perf_gate: rebuilding designs ${want_commit:0:12} gives a different workload than the recording:" >&2
    echo "perf_gate:   recorded $want_fingerprint" >&2
    echo "perf_gate:   rebuilt  $rebuilt" >&2
    return 1
  fi
  return 0
}

measured_commit=""
measured_fingerprint=""
measured_source=""
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
  PERF_PROJECT_SNAPSHOT="$(mktemp -d "$SNAPSHOT_ROOT/netlisp-perf-designs.XXXXXX")"
  assemble_workload_snapshot "$PERF_PROJECT_SNAPSHOT" "$designs_commit"
  live_fingerprint="$(workload_fingerprint "$PERF_PROJECT_SNAPSHOT" "$designs_commit")"
  measured_commit="$designs_commit"
  measured_fingerprint="$live_fingerprint"
  measured_source="live designs HEAD"

  # On an enforce run, drift means the recording is the thing to measure — if
  # this machine can still produce it. Recording never substitutes: --record
  # measures, and defines, the live workload.
  if [ "$MODE" != record ]; then
    recorded_commit=""
    recorded_fingerprint=""
    while IFS= read -r line; do
      case "$line" in
        commit=*) recorded_commit="${line#commit=}" ;;
        fingerprint=*) recorded_fingerprint="${line#fingerprint=}" ;;
      esac
    done < <(node scripts/perf_gate_designs_identity.js recorded "$BASELINE" || true)
    if [ -n "$recorded_fingerprint" ] && [ "$recorded_fingerprint" != "$live_fingerprint" ]; then
      recorded_slug="$(workload_slug "$recorded_fingerprint")"
      if restore_workload_snapshot "$recorded_fingerprint"; then
        measured_commit="$recorded_commit"
        measured_fingerprint="$recorded_fingerprint"
        measured_source="restored workload snapshot $recorded_slug"
        echo "perf_gate: live designs drifted to ${designs_commit:0:12}; measuring the recorded workload snapshot $recorded_slug instead (from $WORKLOAD_STORE)"
      elif rebuild_workload_snapshot "$recorded_commit" "$recorded_fingerprint"; then
        measured_commit="$recorded_commit"
        measured_fingerprint="$recorded_fingerprint"
        measured_source="rebuilt workload snapshot $recorded_slug"
        echo "perf_gate: live designs drifted to ${designs_commit:0:12}; measuring the recorded workload snapshot $recorded_slug instead (rebuilt from designs ${recorded_commit:0:12} plus the current bundles)"
        store_workload_snapshot "$PERF_PROJECT_SNAPSHOT" "$recorded_fingerprint"
      else
        # Neither restorable nor rebuildable: put the live workload back, so
        # what the refusal below names is what is actually here, and let the
        # identity check say no in its own words.
        echo "perf_gate: no stored workload snapshot $recorded_slug under $WORKLOAD_STORE, and the recorded workload cannot be rebuilt from this designs checkout" >&2
        echo "perf_gate: the recording cannot be reproduced on this machine, so only a fresh recording can re-arm the gate" >&2
        assemble_workload_snapshot "$PERF_PROJECT_SNAPSHOT" "$designs_commit"
      fi
    fi
  fi

  # Hash what is actually on disk now and refuse to name it anything else: the
  # last hash taken above may have been a rejected candidate's, and every
  # downstream gate trusts this identity. This also re-verifies a restored or
  # rebuilt snapshot immediately before it is measured.
  assembled_fingerprint="$(workload_fingerprint "$PERF_PROJECT_SNAPSHOT" "$measured_commit")"
  if [ "$assembled_fingerprint" != "$measured_fingerprint" ]; then
    echo "perf_gate: the assembled snapshot hashes to $assembled_fingerprint, not the resolved workload $measured_fingerprint — refusing to measure an unidentified workload" >&2
    exit 1
  fi
  PROJECT_DIR="$PERF_PROJECT_SNAPSHOT"
  export NETLISP_PERF_DESIGNS_COMMIT="$measured_commit"
  export NETLISP_PERF_DESIGNS_FINGERPRINT="$measured_fingerprint"
  IFS=: read -r _ models_fingerprint layouts_fingerprint boms_fingerprint <<<"$measured_fingerprint"
  echo "perf_gate: measuring designs $measured_commit with model $models_fingerprint, layout $layouts_fingerprint, and BOM $boms_fingerprint bundles ($measured_source)"

  if [ "$MODE" = record ]; then
    # Tar the workload BEFORE it is measured: rendering an unblessed board
    # persists its solve back into the snapshot's sidecars, so the tree after a
    # measurement is no longer the tree that was measured. The archive is
    # installed into the store only if the recording is accepted. A store that
    # cannot be written costs the next drifted run a rebuild, never this
    # recording.
    STAGED_WORKLOAD_TAR="$WORKLOAD_STORE/.staging.$$.tar"
    if ! mkdir -p "$WORKLOAD_STORE" || ! tar -cf "$STAGED_WORKLOAD_TAR" -C "$PERF_PROJECT_SNAPSHOT" .; then
      echo "perf_gate: could not stage the measured workload under $WORKLOAD_STORE — recording it anyway, but a later drifted run will have to rebuild it" >&2
      rm -f -- "$STAGED_WORKLOAD_TAR"
      STAGED_WORKLOAD_TAR=""
    fi
  fi
fi

# Refuse to compare latencies across different workloads before spending
# minutes measuring them: a designs-repo move otherwise surfaces as a page
# "latency regression" (FEEDBACK.md 2026-08-29). A non-zero check aborts here
# via set -e with the script's own named reason. The check is told which
# workload was actually resolved above, so a restored or rebuilt snapshot is
# verified against the recording rather than assumed to match it. The browser
# runners enforce the same identity from their baselines' reference.designs.
if [ "$MODE" != record ]; then
  if [ -n "$measured_fingerprint" ]; then
    node scripts/perf_gate_designs_identity.js check "$BASELINE" \
      --measured "$measured_fingerprint" --measured-commit "$measured_commit" --measured-source "$measured_source"
  else
    node scripts/perf_gate_designs_identity.js check "$BASELINE"
  fi
  # The three browser baselines pin their own workload (reference.designs) and
  # refuse a mismatch too. They are recorded by the same --record run, so a
  # sibling naming a different workload means the last recording did not
  # complete — worth saying here rather than as a confusing runner failure
  # twenty minutes in.
  for sibling in "$BROWSER_BASELINE" "$EDITOR_BASELINE" "$UI_BASELINE"; do
    [ -f "$sibling" ] || continue
    sibling_fingerprint="$( { node scripts/perf_gate_designs_identity.js recorded "$sibling" || true; } | sed -n 's/^fingerprint=//p')"
    if [ -n "$sibling_fingerprint" ] && [ -n "$measured_fingerprint" ] && [ "$sibling_fingerprint" != "$measured_fingerprint" ]; then
      echo "perf_gate: WARNING $sibling was recorded against designs ${sibling_fingerprint:0:12}, not the ${measured_fingerprint:0:12} workload being measured — that gate will report drift until a --record run re-records all four baselines together" >&2
    fi
  done
fi

if [ "$MODE" = resolve ]; then
  echo "perf_gate: --resolve-workload only; nothing was built or timed"
  exit 0
fi

zig build --seed=1 -Doptimize=debug
# Page rendering and CAM generation are user-facing/benchmark work, so the
# browser half runs the pinned self-hosted ReleaseSafe artifact. A Debug server
# makes Barracuda's cold CAM payload take minutes and measures the wrong thing.
zig build --seed=1 -Doptimize=safe -p zig-out-browser-perf

if [ "$MODE" = record ]; then
  mkdir -p "$(dirname "$BASELINE")"
  zig-out/bin/netlisp bench-page --project-dir "$PROJECT_DIR" --reps "$REPS" --json >"$BASELINE.tmp"
  # bench-page watches /proc/loadavg around every board and labels the run's
  # JSON when the 1-minute load exceeded its contention model — a workload the
  # gate lock cannot serialize ran beside the measurement. A contended
  # recording is poison as a baseline, so it is refused here, not committed.
  if ! node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).load?.contended ? 3 : 0)' "$BASELINE.tmp"; then
    rm -f "$BASELINE.tmp"
    echo "perf_gate: REFUSED --record — bench-page measured beside another workload (its machine-load line names the excess); re-run when the machine is quiet" >&2
    exit 1
  fi
  # Carry the hand-set budgets forward and stamp the measured designs identity
  # (commit + model/layout/BOM bundle hashes) so the next enforce can tell
  # workload drift from regression.
  node scripts/perf_gate_designs_identity.js stamp "$BASELINE.tmp" "$BASELINE"
  mv -f "$BASELINE.tmp" "$BASELINE"
  echo "perf_gate: recorded $BASELINE — review the diff and commit it deliberately"
  # The baseline now names a workload; save that workload so a later enforce
  # run can measure it again after the live library has moved on.
  if [ -n "$STAGED_WORKLOAD_TAR" ]; then
    store_workload_snapshot "$PERF_PROJECT_SNAPSHOT" "$measured_fingerprint" "$STAGED_WORKLOAD_TAR"
    STAGED_WORKLOAD_TAR=""
  fi
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
