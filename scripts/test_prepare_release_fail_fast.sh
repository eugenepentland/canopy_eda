#!/usr/bin/env bash
# Integration regression for prepare-release's failed-test cancellation. A fake
# Zig makes the Debug suite fail after one second while the fake ReleaseSafe job
# would run for 30; the gate must terminate its whole process group promptly.
set -euo pipefail
# Hermetic re-exec. The build's tree-policy step and the release hook both
# reach this script with a working environment attached — git's hook
# variables (GIT_DIR …), the release script's exported ZIG and cache dir,
# deploy knobs, Guardian switches — and every one of them can redirect the
# throwaway repository and stubbed tools below at the real ones. Restart under
# a minimal environment so the fixture sees only what it sets up itself.
if [ -z "${NETLISP_HERMETIC_TEST:-}" ]; then
  # Fixtures go under the cache dir, never /tmp: that tmpfs carries a per-user
  # quota here, and a full one makes these tests fail in ways that look like
  # logic bugs (a git init that cannot write, a marker that never appears).
  hermetic_tmp="${TMPDIR:-$HOME/.cache/netlisp/tmp}"
  mkdir -p "$hermetic_tmp"
  exec env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG=C.UTF-8 \
    TMPDIR="$hermetic_tmp" ${XDG_RUNTIME_DIR:+XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"} \
    NETLISP_HERMETIC_TEST=1 bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/.githooks" "$REPO/bin" "$REPO/designs/src"
cp "$ROOT/.githooks/prepare-release.sh" "$REPO/.githooks/prepare-release.sh"
# prepare-release reads the required version from .zigversion, and so does the
# fake compiler below — one source of truth, so a pin bump needs no edit here.
cp "$ROOT/.zigversion" "$REPO/.zigversion"

cat >"$REPO/bin/zig" <<'ZIG'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = version ]; then
  tr -d '[:space:]' <"$(dirname "$0")/../.zigversion"
  printf '\n'
  exit 0
fi
case " $* " in
  *" templates "*|*" guardian "*) exit 0 ;;
  *" test "*)
    if [ "${FAKE_TEST_FAIL:-0}" = 1 ]; then sleep 1; exit 7; fi
    echo 'guardian/test: 1 test(s) selected'
    exit 0
    ;;
  *" -Doptimize=safe "*)
    if [ "${FAKE_TEST_FAIL:-0}" = 1 ]; then
      trap 'printf terminated >"$FAIL_FAST_MARKER"; exit 143' TERM
      printf started >"$FAIL_FAST_STARTED"
      (trap '' TERM; sleep 30) &
      stubborn_pid=$!
      printf '%s\n' "$stubborn_pid" >"$FAIL_FAST_CHILD_PID"
      wait "$stubborn_pid"
    fi
    prefix=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --prefix ]; then prefix="$2"; break; fi
      shift
    done
    mkdir -p "$prefix/bin"
    printf '#!/bin/sh\nexit 0\n' >"$prefix/bin/netlisp"
    chmod +x "$prefix/bin/netlisp"
    ;;
  *) exit 0 ;;
esac
ZIG
# The gate also runs three Node jobs against the candidate: the quiet-host
# probe, the Barracuda editor zoom budget and the editor-invariant probe. All
# three drive a real browser over the owner's design library, which no fixture
# can stand up — and none of them is what this test is about (the failed-test
# cancellation and the publish path are). Stub `node` the same way `zig` is
# stubbed, and hand the gate a designs directory shaped like the one it looks
# for, so the success half runs anywhere instead of only on the owner's box.
cat >"$REPO/bin/node" <<'NODE'
#!/usr/bin/env bash
# Fake node: every release-gate job succeeds, printing what it stood in for.
printf 'stub node: %s\n' "$*"
exit 0
NODE
chmod +x "$REPO/bin/zig" "$REPO/bin/node" "$REPO/.githooks/prepare-release.sh"

git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add .
git -C "$REPO" commit -qm fixture

started="$(date +%s)"
set +e
NETLISP_GATE_SERIALIZE=0 \
  ZIG="$REPO/bin/zig" \
  FAKE_TEST_FAIL=1 \
  FAIL_FAST_STARTED="$TMP/build-started" \
  FAIL_FAST_MARKER="$TMP/build-terminated" \
  FAIL_FAST_CHILD_PID="$TMP/build-child-pid" \
  "$REPO/.githooks/prepare-release.sh" >"$TMP/output" 2>&1
status=$?
set -e
elapsed=$(( $(date +%s) - started ))

if [ "$status" -eq 0 ]; then
  echo "FAIL: a failing Debug suite returned success" >&2
  exit 1
fi
if [ ! -f "$TMP/build-started" ] || [ ! -f "$TMP/build-terminated" ]; then
  echo "FAIL: the fake ReleaseSafe build was not started and terminated" >&2
  cat "$TMP/output" >&2
  exit 1
fi
child_pid="$(cat "$TMP/build-child-pid")"
if kill -0 "$child_pid" 2>/dev/null; then
  echo "FAIL: TERM-resistant ReleaseSafe descendant $child_pid survived cancellation" >&2
  exit 1
fi
if [ "$elapsed" -ge 8 ]; then
  echo "FAIL: cancellation took ${elapsed}s; the 30-second build was not stopped promptly" >&2
  cat "$TMP/output" >&2
  exit 1
fi
if ! grep -q 'tests failed; stopping the concurrent ReleaseSafe build' "$TMP/output"; then
  echo "FAIL: the gate did not report fail-fast cancellation" >&2
  cat "$TMP/output" >&2
  exit 1
fi
if ! grep -q 'build (cancelled after .* because tests failed)' "$TMP/output"; then
  echo "FAIL: intentional cancellation was reported as an ordinary build failure" >&2
  cat "$TMP/output" >&2
  exit 1
fi
candidate_root="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/release-candidates"
if [ -d "$candidate_root" ] && find "$candidate_root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | grep -q .; then
  echo "FAIL: a failed gate published a release candidate" >&2
  exit 1
fi

# The same grouped-job launcher must leave the green path unchanged: both jobs
# finish and the gate publishes the exact-commit executable.
set +e
PATH="$REPO/bin:$PATH" NETLISP_GATE_SERIALIZE=0 ZIG="$REPO/bin/zig" \
  NETLISP_PERF_PROJECT_DIR="$REPO/designs" NETLISP_PERF_HOST_WAIT=0 \
  STRIP=/bin/true READELF=/bin/true \
  "$REPO/.githooks/prepare-release.sh" >"$TMP/success-output" 2>&1
success_status=$?
set -e
head_hash="$(git -C "$REPO" rev-parse HEAD)"
if [ "$success_status" -ne 0 ] || [ ! -x "$candidate_root/$head_hash/install/bin/netlisp" ]; then
  echo "FAIL: the successful path did not publish an executable candidate (exit $success_status)" >&2
  cat "$TMP/success-output" >&2
  exit 1
fi
# A candidate is only adoptable if it records that every gate passed; publishing
# one whose `verified` file is missing a job is how a half-checked binary would
# reach prod.
for job in guardian test build pcb_editor_perf pcb_editor_invariants; do
  if ! grep -qx "$job=passed" "$candidate_root/$head_hash/verified"; then
    echo "FAIL: the published candidate does not record $job=passed" >&2
    cat "$candidate_root/$head_hash/verified" >&2
    exit 1
  fi
done

echo "prepare-release fail-fast cancellation and success path OK (${elapsed}s failure)"
