#!/usr/bin/env bash
# Prove every project under examples/ still works, end to end.
#
# The examples are the first thing a newcomer runs and the only tracked
# projects in this repository, so nothing here may rot silently. For each
# design this script:
#
#   1. builds it                     (evaluate → resolve → check → emit)
#   2. checks it                     (assertions, ERC, requirements)
#   3. exports a KiCad project       (netlist + schematic + footprints)
#   4. exports the review PDF
#   5. runs the layout DRC gate      (run_fab_readiness over the SAVED copper)
#
# and then asserts the tree is byte-identical to how it started. That last
# assertion is the point: `netlisp build` mints ids into the .sexp and writes
# a .bom sidecar, and both are committed, so a run that changes a byte means
# the committed state and the source disagree — a stale BOM, an unpinned id,
# or a tool whose output moved. It also catches the tool dropping runtime
# state (logs/, history/) somewhere that is not git-ignored.
#
# Exports go to a temp directory under ~/.cache/netlisp and are removed on
# exit. Never /tmp: it is a small per-user tmpfs on the machines this runs on,
# and stale prefixes have filled it before.
#
# Usage:
#   scripts/check_examples.sh [--netlisp <path>]
#
# `zig build test` runs it with the freshly compiled binary; a bare run uses
# zig-out/bin/netlisp.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

netlisp="zig-out/bin/netlisp"
while [ $# -gt 0 ]; do
  case "$1" in
    --netlisp) netlisp="$2"; shift 2 ;;
    *) echo "check_examples: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ ! -x "$netlisp" ]; then
  echo "check_examples: no netlisp binary at '$netlisp'" >&2
  echo "  build one with \`zig build\`, or pass --netlisp <path>." >&2
  exit 1
fi

if [ ! -d examples ]; then
  echo "check_examples: no examples/ directory" >&2
  exit 1
fi

out_root="${HOME}/.cache/netlisp"
mkdir -p "$out_root"
work="$(mktemp -d "${out_root}/check-examples.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Fingerprint every file in examples/ plus git's view of it. Runtime state the
# tool writes beside a project (logs/, history/) is git-ignored and excluded
# here by the same rule, so `git status` catching one of them is the signal.
fingerprint() {
  find examples -type f \
    -not -path 'examples/*/logs/*' \
    -not -path 'examples/*/history/*' \
    | LC_ALL=C sort | xargs md5sum
  git status --porcelain -- examples/
}

before="$(fingerprint)"

designs_checked=0
for project in examples/*/; do
  [ -d "${project}src" ] || continue
  for source in "${project}"src/*.sexp; do
    [ -f "$source" ] || continue
    design="$(basename "$source" .sexp)"
    echo "check_examples: ${project}${design}"

    "$netlisp" build --project-dir "$project" "$design" >"$work/build.log" 2>&1 || {
      echo "check_examples: build failed for $design" >&2
      sed 's/^/  /' "$work/build.log" >&2
      exit 1
    }

    "$netlisp" check --project-dir "$project" "$design" >"$work/check.log" 2>&1 || {
      echo "check_examples: check failed for $design" >&2
      sed 's/^/  /' "$work/check.log" >&2
      exit 1
    }

    "$netlisp" export-kicad --project-dir "$project" \
      --output-dir "$work/kicad-$design" --with-schematic "$design" \
      >"$work/kicad.log" 2>&1 || {
      echo "check_examples: KiCad export failed for $design" >&2
      sed 's/^/  /' "$work/kicad.log" >&2
      exit 1
    }
    for required in "$work/kicad-$design/$design.net" "$work/kicad-$design/$design.kicad_sch"; do
      [ -s "$required" ] || { echo "check_examples: $design export is missing $required" >&2; exit 1; }
    done

    "$netlisp" export-pdf --project-dir "$project" "$design" \
      --output "$work/$design.pdf" >"$work/pdf.log" 2>&1 || {
      echo "check_examples: PDF export failed for $design" >&2
      sed 's/^/  /' "$work/pdf.log" >&2
      exit 1
    }
    [ -s "$work/$design.pdf" ] || { echo "check_examples: $design produced an empty PDF" >&2; exit 1; }

    # The layout DRC gate, over the copper committed in <design>.layouts.json.
    # An example without a saved layout is skipped rather than failed: the
    # walkthrough's board has one, a future example need not.
    if [ -f "${project}src/$design.layouts.json" ]; then
      "$netlisp" tool run_fab_readiness --project-dir "$project" \
        --args "{\"name\":\"$design\"}" >"$work/drc.json" 2>"$work/drc.log" || {
        echo "check_examples: run_fab_readiness failed for $design" >&2
        sed 's/^/  /' "$work/drc.log" >&2
        exit 1
      }
      python3 - "$work/drc.json" "$design" <<'PY'
import json, sys

path, design = sys.argv[1], sys.argv[2]
with open(path) as handle:
    report = json.load(handle)

errors = [v for v in report.get("raw_drc", []) if v.get("severity") == "error"]
stats = report.get("stats", {})
routable = stats.get("routable_nets", 0)
connected = stats.get("connected_nets", 0)

problems = []
if errors:
    kinds = ", ".join(sorted({v.get("kind", "?") for v in errors}))
    problems.append(f"{len(errors)} DRC error(s) in the saved copper ({kinds})")
if connected != routable:
    problems.append(f"only {connected} of {routable} nets are connected on the saved layout")
if not stats.get("has_outline", False):
    problems.append("the saved layout has no board outline")

if problems:
    print(f"check_examples: {design} layout:", file=sys.stderr)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    for violation in errors[:10]:
        print(
            "  {kind} at ({x:.3f}, {y:.3f}) on {net}".format(
                kind=violation.get("kind", "?"),
                x=violation.get("x_mm", 0.0),
                y=violation.get("y_mm", 0.0),
                net=violation.get("net_a_name", "?"),
            ),
            file=sys.stderr,
        )
    sys.exit(1)

warnings = report.get("raw_drc_count", 0) - len(errors)
print(f"  layout: {connected}/{routable} nets connected, "
      f"{stats.get('tracks', 0)} tracks, {stats.get('vias', 0)} vias, "
      f"0 DRC errors, {warnings} warning(s)")
PY
    fi

    designs_checked=$((designs_checked + 1))
  done
done

if [ "$designs_checked" -eq 0 ]; then
  echo "check_examples: examples/ holds no designs — nothing was proven" >&2
  exit 1
fi

after="$(fingerprint)"
if [ "$before" != "$after" ]; then
  echo "check_examples: examples/ changed while being checked — not byte-idempotent." >&2
  echo "  A committed example must survive its own build unchanged: ids are pinned" >&2
  echo "  into the .sexp and the .bom sidecar is committed. Re-run the build, commit" >&2
  echo "  what it wrote, and make sure any new runtime directory is git-ignored." >&2
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/  /' >&2 || true
  exit 1
fi

echo "check_examples: $designs_checked design(s) built, checked, exported and DRC-clean"
