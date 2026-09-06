#!/usr/bin/env bash
# Behaviour test for the pcb-page gate's pinned workload: scripts/perf_gate.sh
# --record saves the exact snapshot it measured, and a later enforce run whose
# live designs library has drifted measures THAT recording — restored from the
# machine-local store, or rebuilt from the recorded designs commit when the
# ignored bundles still hash to the recorded values — instead of refusing every
# push made after a board edit. Only when neither is possible does it refuse,
# and it must then say so before building or timing anything.
#
# Runs entirely inside a throwaway pair of git repositories under $TMPDIR,
# against COPIES of the tracked scripts, with `zig` and `netlisp bench-page`
# and the three browser runners stubbed. Nothing it does can reach this
# repository, the real designs library, the real workload store, or the
# machine gate lock.
#
#   scripts/test_perf_gate_workload_store.sh
#
# Wired into `zig build test` beside the other maintainer shell seams.
set -uo pipefail
# Hermetic re-exec. The build's tree-policy step and the release hook both
# reach this script with a working environment attached — git's hook variables,
# the release script's exported ZIG and cache dir, and (fatally for this test)
# any NETLISP_PERF_* knob an operator exported in the invoking shell. Restart
# under a minimal environment so the fixture sees only what it sets up itself.
if [ -z "${NETLISP_HERMETIC_TEST:-}" ]; then
  # Fixtures go under the cache dir, never /tmp: that tmpfs carries a per-user
  # quota here, and a full one makes these tests fail in ways that look like
  # logic bugs.
  hermetic_tmp="${TMPDIR:-$HOME/.cache/netlisp/tmp}"
  mkdir -p "$hermetic_tmp"
  exec env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG=C.UTF-8 \
    TMPDIR="$hermetic_tmp" NETLISP_HERMETIC_TEST=1 bash "$0" "$@"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
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
ck_has() {
  case "$2" in
    *"$3"*) echo "  ok   $1"; pass=$((pass + 1)) ;;
    *) echo "  FAIL $1: output does not contain '$3'"; printf '%s\n' "$2" | sed 's/^/         /'; fail=$((fail + 1)) ;;
  esac
}
ck_lacks() {
  case "$2" in
    *"$3"*) echo "  FAIL $1: output unexpectedly contains '$3'"; fail=$((fail + 1)) ;;
    *) echo "  ok   $1"; pass=$((pass + 1)) ;;
  esac
}

REPO="$T/eda"           # a stand-in netlisp checkout: the scripts under test
DESIGNS="$T/designs"    # a stand-in designs library: the workload
STORE="$T/store"        # the machine-local workload store
SNAPS="$T/snapshots"    # where the disposable snapshot is assembled
BIN="$T/bin"            # stubbed zig
PAGE_BASELINE="$T/pcb-page.json"
BROWSER_BASELINE="$T/pcb-browser.json"
EDITOR_BASELINE="$T/pcb-editor.json"
UI_BASELINE="$T/ui-browser.json"
MEASURED_LOG="$T/measured.log"
mkdir -p "$REPO/scripts" "$REPO/node_modules/playwright" "$BIN" "$SNAPS"
cp "$HERE/perf_gate.sh" "$HERE/perf_gate_designs_identity.js" "$REPO/scripts/"
chmod +x "$REPO/scripts/perf_gate.sh"

# ── stubs ────────────────────────────────────────────────────────────────────
# `netlisp bench-page`. It reports which workload it was pointed at (the whole
# question this test asks), and MUTATES a layout sidecar the way a real render
# of an unblessed board does — which is why the recording's archive has to be
# taken before the measurement, not after.
cat >"$T/netlisp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir=""; json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-dir) dir="$2"; shift 2 ;;
    --json) json=1; shift ;;
    --baseline) shift 2 ;;
    --reps) shift 2 ;;
    *) shift ;;
  esac
done
marker="$(cat "$dir/src/marker.txt")"
printf 'measured marker=%s commit=%s\n' "$marker" "${NETLISP_PERF_DESIGNS_COMMIT:-none}" >>"$MEASURED_LOG"
echo "bench-page: measured workload marker $marker" >&2
printf 'persisted-solve\n' >>"$dir/src/board.layouts.json"   # a render writes back
contended=false
[ ! -f "$CONTENDED_FLAG" ] || contended=true
if [ "$json" = 1 ]; then
  printf '{"boards":[{"name":"board","ok":true,"page_ms":1.0}],"load":{"contended":%s}}\n' "$contended"
else
  echo "page gate PASS"
fi
STUB
chmod +x "$T/netlisp"

# `zig build […] [-p prefix]` — installs the stub binary where the gate expects it.
cat >"$BIN/zig" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
prefix="zig-out"
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = "-p" ] || continue
  prefix="${args[$((i + 1))]}"
done
mkdir -p "$prefix/bin"
cp "$NETLISP_STUB" "$prefix/bin/netlisp"
STUB
chmod +x "$BIN/zig"

# The three browser runners. Recording writes the workload identity they were
# recorded against, exactly as the real ones do (reference.designs); enforcing
# is a no-op here — their own gating is not what this test is about.
for runner in pcb_browser_perf pcb_editor_perf ui_browser_perf; do
  mkdir -p "$REPO/scripts/$runner"
  cat >"$REPO/scripts/$runner/run.js" <<'STUB'
const fs = require("fs");
const argv = process.argv.slice(2);
const baseline = argv[argv.indexOf("--baseline") + 1];
if (argv.includes("--record")) {
  fs.writeFileSync(baseline, `${JSON.stringify({ reference: { designs: {
    commit: process.env.NETLISP_PERF_DESIGNS_COMMIT,
    fingerprint: process.env.NETLISP_PERF_DESIGNS_FINGERPRINT,
  } } }, null, 2)}\n`);
}
STUB
done

# ── the workload ─────────────────────────────────────────────────────────────
mkdir -p "$DESIGNS/src" "$DESIGNS/lib/models"
git init -q -b main "$DESIGNS"
git -C "$DESIGNS" config user.email test@example.invalid
git -C "$DESIGNS" config user.name test
printf 'gen1\n' >"$DESIGNS/src/marker.txt"
printf '(design-block board)\n' >"$DESIGNS/src/board.sexp"
printf '*.layouts.json\n*.bom\nlib/models/\n' >"$DESIGNS/.gitignore"
git -C "$DESIGNS" add -A
git -C "$DESIGNS" commit -qm gen1
GEN1="$(git -C "$DESIGNS" rev-parse HEAD)"
# The ignored bundles: local editor/vendor state, not history.
printf '{"layout":1}\n' >"$DESIGNS/src/board.layouts.json"
printf 'ref,mpn\nR1,X\n' >"$DESIGNS/src/board.bom"
printf 'solid\n' >"$DESIGNS/lib/models/part.step"
LAYOUT_GEN1="$(cat "$DESIGNS/src/board.layouts.json")"

run_gate() {
  ( cd "$REPO" && env \
      PATH="$BIN:$PATH" HOME="$HOME" LANG=C.UTF-8 TMPDIR="$TMPDIR" \
      NETLISP_STUB="$T/netlisp" MEASURED_LOG="$MEASURED_LOG" CONTENDED_FLAG="$T/contended" \
      NETLISP_GATE_SERIALIZE=0 \
      NETLISP_PERF_PROJECT_DIR="$DESIGNS" \
      NETLISP_PERF_BASELINE="$PAGE_BASELINE" \
      NETLISP_BROWSER_PERF_BASELINE="$BROWSER_BASELINE" \
      NETLISP_EDITOR_PERF_BASELINE="$EDITOR_BASELINE" \
      NETLISP_UI_PERF_BASELINE="$UI_BASELINE" \
      NETLISP_PERF_WORKLOAD_STORE="$STORE" \
      NETLISP_PERF_SNAPSHOT_ROOT="$SNAPS" \
      ${WORKLOAD_KEEP:+NETLISP_PERF_WORKLOAD_KEEP="$WORKLOAD_KEEP"} \
      bash scripts/perf_gate.sh "$@" ) >"$T/out" 2>&1
  status=$?
  out="$(cat "$T/out")"
  return $status
}
store_tars() { ls -1 "$STORE"/*.tar 2>/dev/null | wc -l | tr -d ' '; }
store_state() { (cd "$STORE" 2>/dev/null && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) || true; }
measured_markers() { sed -n 's/^measured marker=\([^ ]*\) .*/\1/p' "$MEASURED_LOG" | tr '\n' ' '; }

echo "record stores the measured workload"
: >"$MEASURED_LOG"
run_gate --record; status=$?
ck "record succeeds" "$status" "0"
ck_has "record names the stored snapshot" "$out" "saved the measured workload snapshot"
ck "record measured the live workload" "$(measured_markers)" "gen1 "
ck "one snapshot in the store" "$(store_tars)" "1"
RECORDED_FP="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["designs"]["fingerprint"])' "$PAGE_BASELINE")"
STORED_TAR="$(ls -1 "$STORE"/*.tar)"
ck "the stored fingerprint sidecar names the recorded workload" \
  "$(cat "${STORED_TAR%.tar}.fingerprint")" "$RECORDED_FP"
ck "the baseline pins the recorded designs commit" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["designs"]["commit"])' "$PAGE_BASELINE")" "$GEN1"
# The archive is taken BEFORE the measurement: a render that persists a solve
# into the snapshot must not end up inside the workload the baseline names.
ck "the stored snapshot is the pre-measurement tree" \
  "$(tar -xOf "$STORED_TAR" ./src/board.layouts.json)" "$LAYOUT_GEN1"
ck "no staging archive is left behind" "$(ls -1 "$STORE"/.staging.* 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "enforce with the recorded workload still live"
before="$(store_state)"
: >"$MEASURED_LOG"
run_gate; status=$?
ck "enforce passes" "$status" "0"
ck_has "the identity check names the match" "$out" "baseline workload matches designs"
ck_has "it names the live source" "$out" "live designs HEAD"
ck_lacks "no drift is claimed" "$out" "drifted to"
ck "it measured the live workload" "$(measured_markers)" "gen1 "
ck "the store is untouched" "$(store_state)" "$before"

echo "enforce after the designs library moved on"
printf 'gen2\n' >"$DESIGNS/src/marker.txt"
git -C "$DESIGNS" commit -qam gen2
GEN2="$(git -C "$DESIGNS" rev-parse HEAD)"
printf '{"layout":2}\n' >"$DESIGNS/src/board.layouts.json"   # the bundles moved too
: >"$MEASURED_LOG"
run_gate; status=$?
ck "enforce still passes" "$status" "0"
ck_has "it names the drift and the snapshot it fell back to" "$out" \
  "live designs drifted to ${GEN2:0:12}; measuring the recorded workload snapshot"
ck_has "it names the store it restored from" "$out" "(from $STORE)"
ck_has "the identity check verifies the restored workload" "$out" "restored workload snapshot"
ck "it measured the RECORDED workload, not the live one" "$(measured_markers)" "gen1 "

echo "enforce after drift with no stored snapshot, but a rebuildable commit"
rm -f "$STORE"/*.tar "$STORE"/*.fingerprint
printf '%s\n' "$LAYOUT_GEN1" >"$DESIGNS/src/board.layouts.json"   # bundles back to the recorded ones
: >"$MEASURED_LOG"
run_gate; status=$?
ck "enforce passes on a rebuild" "$status" "0"
ck_has "it names the rebuild" "$out" "rebuilt from designs ${GEN1:0:12} plus the current bundles"
ck "it measured the recorded workload" "$(measured_markers)" "gen1 "
ck "the rebuild is saved for next time" "$(store_tars)" "1"
ck "the saved rebuild is the recorded workload" \
  "$(cat "$(ls -1 "$STORE"/*.tar | sed 's/\.tar$/.fingerprint/')")" "$RECORDED_FP"

echo "enforce after drift with neither a snapshot nor a rebuildable workload"
rm -f "$STORE"/*.tar "$STORE"/*.fingerprint
printf '{"layout":3}\n' >"$DESIGNS/src/board.layouts.json"
: >"$MEASURED_LOG"
run_gate; status=$?
# 3, not 1: the identity check's own exit code travels out through set -e, so a
# workload that cannot be reproduced stays distinguishable from a measured
# regression (1) for anything reading the gate's status.
ck "enforce refuses with the identity code" "$status" "3"
ck_has "it says the store has no such snapshot" "$out" "no stored workload snapshot"
ck_has "it shows the rebuild that did not match" "$out" "gives a different workload than the recording"
ck_has "it names the drift honestly" "$out" \
  "recorded against designs ${GEN1:0:12}, comparing against designs ${GEN2:0:12}"
ck_has "it gives the recipe" "$out" "re-record deliberately (scripts/perf_gate.sh --record)"
ck "it refused before measuring anything" "$(measured_markers)" ""
ck "nothing was written to the store" "$(store_tars)" "0"

echo "enforce when the recorded designs commit is gone"
python3 - "$PAGE_BASELINE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
gone = "0" * 40
doc["designs"] = {"commit": gone, "fingerprint": f"{gone}:m:l:b", "dirty": False,
                  "source": "git-archive+workload-bundles"}
open(sys.argv[1], "w").write(json.dumps(doc, indent=2) + "\n")
PY
run_gate; status=$?
ck "enforce refuses with the identity code" "$status" "3"
ck_has "it names the missing commit" "$out" "is not in $DESIGNS, so the recorded workload cannot be rebuilt here"
ck_has "it gives the recipe" "$out" "re-record deliberately"

echo "--resolve-workload reports without building or measuring"
: >"$MEASURED_LOG"
run_gate --resolve-workload; status=$?
ck "it exits with the resolution's verdict" "$status" "3"
ck_has "it says nothing was measured" "$out" "no stored workload snapshot"
ck "it measured nothing" "$(measured_markers)" ""

echo "a baseline pinning an implausible identity is not acted on"
python3 - "$PAGE_BASELINE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["designs"] = {"commit": "../../escape", "fingerprint": "../../escape:m:l:b", "dirty": False,
                  "source": "git-archive+workload-bundles"}
open(sys.argv[1], "w").write(json.dumps(doc, indent=2) + "\n")
PY
run_gate; status=$?
ck "enforce refuses with the identity code" "$status" "3"
ck_has "it names the implausible identity" "$out" "pins a designs identity with unexpected characters"
ck_lacks "it never went looking for a snapshot named after it" "$out" "no stored workload snapshot"
ck "nothing escaped the store directory" "$(ls -1 "$T"/*.tar 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "a contended recording is refused and saves no snapshot"
rm -rf "$STORE"
touch "$T/contended"
: >"$MEASURED_LOG"
run_gate --record; status=$?
ck "record refuses" "$status" "1"
ck_has "it names the contention" "$out" "REFUSED --record"
ck "no snapshot is stored for a refused recording" "$(store_tars)" "0"
ck "no staging archive is left behind" "$(ls -1 "$STORE"/.staging.* 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -f "$T/contended"

echo "a sibling baseline recorded against another workload is called out"
run_gate --record >/dev/null 2>&1
python3 - "$UI_BASELINE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["reference"]["designs"]["fingerprint"] = "f" * 40 + ":m:l:b"
open(sys.argv[1], "w").write(json.dumps(doc, indent=2) + "\n")
PY
run_gate; status=$?
ck "enforce still passes" "$status" "0"
ck_has "the mismatched sibling is named" "$out" "WARNING $UI_BASELINE was recorded against designs"
ck_has "it says what fixes it" "$out" "re-records all four baselines together"

echo "the store keeps only the newest snapshots"
WORKLOAD_KEEP=1
printf 'gen3\n' >"$DESIGNS/src/marker.txt"
git -C "$DESIGNS" commit -qam gen3
run_gate --record; status=$?
ck "record succeeds" "$status" "0"
ck "older snapshots are pruned" "$(store_tars)" "1"
ck "a pruned snapshot takes its fingerprint sidecar with it" \
  "$(ls -1 "$STORE"/*.fingerprint | wc -l | tr -d ' ')" "1"
unset WORKLOAD_KEEP

echo
if [ "$fail" -ne 0 ]; then
  echo "perf-gate workload store: $pass passed, $fail FAILED"
  exit 1
fi
echo "perf-gate workload store: $pass checks passed"
