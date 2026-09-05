#!/usr/bin/env bash
# Differential harness: run every deterministic dump surface over the board
# corpus with TWO already-built netlisp binaries and diff the results.
#
# The three dumps it drives — `drc-dump`, `gerber-dump`, `netlist-dump` — each
# print their per-run numbers on `#`-prefixed lines, so `diff -I '^#'` compares
# findings, artwork and connectivity while ignoring wall times. That is the
# whole point: the bugs this exists for changed EMITTED BYTES and no count
# anywhere (a Gerber arc re-derived from quantized endpoints and emitted as the
# complementary near-full turn; a pad number re-read by the SI tokenizer so `5V`
# became `5` and the pad silently left its net; a via dedup key missing the
# layer span so a blind and a through via in one hole collapsed into one). Unit
# tests and the DRC gate pass through all three.
#
#   scripts/corpus_diff.sh --base <binary> --candidate <binary> \
#                          [--project-dir <dir>] [--out <dir>] \
#                          [--surfaces drc,gerber,netlist] [--gerber-digest] \
#                          [<design>…]
#
# It BUILDS NOTHING. Building two binaries is minutes of work the caller
# schedules (and often already has done); a harness that rebuilt on every run
# would make the expensive half unskippable. Both binaries must already carry
# the three dump subcommands — the intended workflow is that this tier lands
# first, and every later change is diffed against a binary built from the commit
# before it.
#
# Building the two binaries (both in the SAME optimize mode — comparing a Debug
# dump against a ReleaseSafe one compares two compilers as well as two trees):
#
#   git worktree add ../netlisp-base <base-ref>
#   (cd ../netlisp-base && zig build --seed=1 -p ~/.cache/netlisp/corpus-diff/base)
#   zig build --seed=1 -p ~/.cache/netlisp/corpus-diff/cand
#   scripts/corpus_diff.sh \
#     --base      ~/.cache/netlisp/corpus-diff/base/bin/netlisp \
#     --candidate ~/.cache/netlisp/corpus-diff/cand/bin/netlisp
#
# Debug is the cheap build and is what the example uses. A poured barracuda-class
# gerber-dump is much faster from a ReleaseSafe build, which the pinned compiler
# emits through its self-hosted backend in seconds; build BOTH sides that way if
# you go there:
#
#   zig build --seed=1 -Doptimize=safe -p ~/.cache/netlisp/corpus-diff/base-safe
#
# Corpus selection: with no design names it reproduces `bench_page.corpus()` —
# every `<project-dir>/src/**/<stem>.sexp` whose basename carries no extra dot,
# whose text contains `(design-block`, and which has a `<stem>.layouts.json`
# sibling (the same saved-layout guard the boot warm-up applies), sorted by
# name. "Sibling" is `paths.designSiblingPath`'s meaning — the same directory as
# the source — so a board whose only sidecar sits elsewhere under src/ is NOT in
# the auto corpus. Naming designs on the command line overrides all of this and
# compares exactly what you named.
#
# Output lives under ~/.cache/netlisp/corpus-diff/, NOT /tmp: /tmp carries a
# per-user quota on this machine and accumulated throwaway trees filled it once
# (2026-08-26), which breaks every tool that needs tmpfile space. Nothing is
# cleaned up on exit — the dumps and diffs are the artifacts a human reads.
# Clean old runs with: rm -rf ~/.cache/netlisp/corpus-diff/run-*
#
# Exit status: 0 when every surface of every design matched, 1 on any
# difference OR any failed dump. A dump that fails compared nothing, so it can
# never read as agreement.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE_BIN=""
CAND_BIN=""
PROJECT_DIR="projects/designs"
OUT_DIR=""
SURFACES="drc,gerber,netlist"
GERBER_DIGEST=0
DESIGNS=()

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage; BASE_BIN="$2"; shift 2 ;;
    --candidate) [ $# -ge 2 ] || usage; CAND_BIN="$2"; shift 2 ;;
    --project-dir) [ $# -ge 2 ] || usage; PROJECT_DIR="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT_DIR="$2"; shift 2 ;;
    --surfaces) [ $# -ge 2 ] || usage; SURFACES="$2"; shift 2 ;;
    --gerber-digest) GERBER_DIGEST=1; shift ;;
    -h|--help) usage ;;
    --*) echo "corpus_diff: unknown flag $1" >&2; usage ;;
    *) DESIGNS+=("$1"); shift ;;
  esac
done

# ── The two binaries ──────────────────────────────────────────────────────
if [ -z "$BASE_BIN" ] || [ -z "$CAND_BIN" ]; then
  echo "corpus_diff: --base and --candidate are both required (this script builds nothing)" >&2
  usage
fi
for role in base candidate; do
  bin="$BASE_BIN"
  [ "$role" = base ] || bin="$CAND_BIN"
  if [ ! -x "$bin" ]; then
    echo "corpus_diff: $role binary is missing or not executable: $bin" >&2
    echo "  build it yourself, e.g. zig build --seed=1 -p ~/.cache/netlisp/corpus-diff/$role" >&2
    exit 2
  fi
done
BASE_BIN="$(cd "$(dirname "$BASE_BIN")" && pwd)/$(basename "$BASE_BIN")"
CAND_BIN="$(cd "$(dirname "$CAND_BIN")" && pwd)/$(basename "$CAND_BIN")"
if [ "$BASE_BIN" = "$CAND_BIN" ]; then
  echo "corpus_diff: --base and --candidate are the same binary ($BASE_BIN) — nothing to compare" >&2
  exit 2
fi

# ── The designs repo ──────────────────────────────────────────────────────
# A worktree has no projects/ of its own; the designs live in the shared
# checkout beside the common gitdir (the same fallback scripts/perf_gate.sh
# uses).
if [ ! -d "$PROJECT_DIR/src" ]; then
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  shared_checkout="${common_dir%/.git}"
  if [ -n "$common_dir" ] && [ -d "$shared_checkout/projects/designs/src" ]; then
    PROJECT_DIR="$shared_checkout/projects/designs"
  fi
fi
if [ ! -d "$PROJECT_DIR/src" ]; then
  echo "corpus_diff: no designs repo at $PROJECT_DIR — nothing to compare" >&2
  exit 2
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

# ── The corpus ────────────────────────────────────────────────────────────
# `bench_page.corpus()` in shell: a `(design-block` source under src/, no extra
# dot in its basename, carrying a saved-layout sidecar beside it.
if [ "${#DESIGNS[@]}" -eq 0 ]; then
  while IFS= read -r stem; do
    DESIGNS+=("$stem")
  done < <(
    find "$PROJECT_DIR/src" -type f -name '*.sexp' -print0 |
      while IFS= read -r -d '' sexp; do
        stem="$(basename "$sexp" .sexp)"
        case "$stem" in *.*) continue ;; esac
        # `paths.designSiblingPath` resolves a sidecar BESIDE the source, so a
        # design whose only `.layouts.json` sits elsewhere under src/ is not in
        # the auto corpus (name it on the command line to compare it anyway).
        [ -f "$(dirname "$sexp")/$stem.layouts.json" ] || continue
        grep -q -F '(design-block' "$sexp" || continue
        printf '%s\n' "$stem"
      done | LC_ALL=C sort
  )
fi
if [ "${#DESIGNS[@]}" -eq 0 ]; then
  echo "corpus_diff: no design in $PROJECT_DIR/src has a saved layout — refusing an empty comparison" >&2
  exit 2
fi

# ── The surfaces ──────────────────────────────────────────────────────────
WANT_DRC=0
WANT_GERBER=0
WANT_NETLIST=0
IFS=',' read -r -a requested <<<"$SURFACES"
for surface in "${requested[@]}"; do
  case "$surface" in
    drc) WANT_DRC=1 ;;
    gerber) WANT_GERBER=1 ;;
    netlist) WANT_NETLIST=1 ;;
    "") ;;
    *) echo "corpus_diff: unknown surface '$surface' (want drc, gerber or netlist)" >&2; exit 2 ;;
  esac
done
if [ "$WANT_DRC" -eq 0 ] && [ "$WANT_GERBER" -eq 0 ] && [ "$WANT_NETLIST" -eq 0 ]; then
  echo "corpus_diff: --surfaces selected nothing" >&2
  exit 2
fi

# ── Artifacts ─────────────────────────────────────────────────────────────
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$HOME/.cache/netlisp/corpus-diff/run-$(date +%Y%m%d-%H%M%S)-$$"
fi
mkdir -p "$OUT_DIR/base" "$OUT_DIR/candidate" "$OUT_DIR/diff"
SUMMARY="$OUT_DIR/summary.txt"
: >"$SUMMARY"

echo "corpus_diff: base      $BASE_BIN" >&2
echo "corpus_diff: candidate $CAND_BIN" >&2
echo "corpus_diff: designs   ${#DESIGNS[@]} from $PROJECT_DIR" >&2
echo "corpus_diff: artifacts $OUT_DIR" >&2

# Run one dump. Its stdout is the compared artifact and its stderr is kept
# beside it; the exit status is returned so a failed dump can never be read as
# agreement.
run_dump() {
  local bin="$1" surface="$2" design="$3" out="$4"
  local -a cmd
  case "$surface" in
    drc) cmd=("$bin" drc-dump --project-dir "$PROJECT_DIR" "$design") ;;
    netlist) cmd=("$bin" netlist-dump --project-dir "$PROJECT_DIR" "$design") ;;
    gerber)
      cmd=("$bin" gerber-dump --project-dir "$PROJECT_DIR")
      [ "$GERBER_DIGEST" -eq 0 ] || cmd+=(--digest)
      cmd+=("$design")
      ;;
  esac
  "${cmd[@]}" >"$out" 2>"$out.err"
}

# How many COMPARED lines a unified diff holds. Counted from the artifact
# rather than by diffing again, so a large board is not walked twice for a
# number. The pattern drops the `---`/`+++` file headers and the `#` lines
# `-I` ignored but that share a hunk with a real change — a dump line never
# begins with `+`, `-` or `#` (Gerber, Excellon and netlist lines all start
# with a coordinate, a command letter, a brace or a design name).
changed_lines() {
  grep -c -E '^[+-]([^#+-]|$)' "$1" || true
}

failures=0
diffs=0
compared=0

for design in "${DESIGNS[@]}"; do
  for surface in drc gerber netlist; do
    case "$surface" in
      drc) [ "$WANT_DRC" -eq 1 ] || continue ;;
      gerber) [ "$WANT_GERBER" -eq 1 ] || continue ;;
      netlist) [ "$WANT_NETLIST" -eq 1 ] || continue ;;
    esac

    base_out="$OUT_DIR/base/$design.$surface.txt"
    cand_out="$OUT_DIR/candidate/$design.$surface.txt"
    diff_out="$OUT_DIR/diff/$design.$surface.diff"

    echo "corpus_diff: $design $surface …" >&2
    base_status=0
    run_dump "$BASE_BIN" "$surface" "$design" "$base_out" || base_status=$?
    cand_status=0
    run_dump "$CAND_BIN" "$surface" "$design" "$cand_out" || cand_status=$?

    if [ "$base_status" -ne 0 ] || [ "$cand_status" -ne 0 ]; then
      # A dump that failed compared nothing, so it is a failure and never a
      # match. Both stderr logs are kept; name the side that actually broke.
      failed_log="$base_out.err"
      [ "$base_status" -ne 0 ] || failed_log="$cand_out.err"
      printf '%-28s %-8s FAILED   base=%d candidate=%d  (see %s)\n' \
        "$design" "$surface" "$base_status" "$cand_status" "$failed_log" >>"$SUMMARY"
      failures=$((failures + 1))
      continue
    fi

    compared=$((compared + 1))
    # ONE diff decides and produces the artifact. `diff -q` is deliberately not
    # used: brief mode is free to answer from a cheap whole-file comparison, and
    # an answer reached that way has not applied `-I` at all. Status 0 = same,
    # 1 = differing, anything else = diff itself failed.
    diff_status=0
    diff -u -I '^#' "$base_out" "$cand_out" >"$diff_out" || diff_status=$?
    case "$diff_status" in
      0)
        printf '%-28s %-8s same\n' "$design" "$surface" >>"$SUMMARY"
        rm -f "$diff_out"
        ;;
      1)
        printf '%-28s %-8s DIFF     %s changed lines  (%s)\n' \
          "$design" "$surface" "$(changed_lines "$diff_out")" "$diff_out" >>"$SUMMARY"
        diffs=$((diffs + 1))
        ;;
      *)
        printf '%-28s %-8s FAILED   diff exited %d  (%s)\n' \
          "$design" "$surface" "$diff_status" "$diff_out" >>"$SUMMARY"
        compared=$((compared - 1))
        failures=$((failures + 1))
        ;;
    esac
  done
done

echo >&2
cat "$SUMMARY"
echo
echo "corpus_diff: compared=$compared differing=$diffs failed=$failures"
echo "corpus_diff: artifacts kept in $OUT_DIR"

if [ "$diffs" -ne 0 ] || [ "$failures" -ne 0 ]; then
  exit 1
fi
exit 0
