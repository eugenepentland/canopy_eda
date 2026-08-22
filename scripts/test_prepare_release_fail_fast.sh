#!/usr/bin/env bash
# Integration regression for prepare-release's failed-test cancellation. A fake
# Zig makes the Debug suite fail after one second while the fake ReleaseSafe job
# would run for 30; the gate must terminate its whole process group promptly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/.githooks" "$REPO/bin"
cp "$ROOT/.githooks/prepare-release.sh" "$REPO/.githooks/prepare-release.sh"

cat >"$REPO/bin/zig" <<'ZIG'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = version ]; then
  printf '%s\n' '0.17.0-dev.1683+5ceec001b'
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
chmod +x "$REPO/bin/zig" "$REPO/.githooks/prepare-release.sh"
# The production script intentionally rejects same-version compiler binaries
# with different contents. Bind this isolated fixture to its fake compiler so
# the test reaches the grouped jobs instead of stopping at that security gate.
fake_zig_sha="$(sha256sum "$REPO/bin/zig" | awk '{print $1}')"
sed -i "s/^REQUIRED_ZIG_SHA256=.*/REQUIRED_ZIG_SHA256=\"$fake_zig_sha\"/" \
  "$REPO/.githooks/prepare-release.sh"

git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add .
git -C "$REPO" commit -qm fixture

started="$(date +%s)"
set +e
EDA_GATE_SERIALIZE=0 \
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
EDA_GATE_SERIALIZE=0 ZIG="$REPO/bin/zig" \
  STRIP=/bin/true READELF=/bin/true \
  "$REPO/.githooks/prepare-release.sh" >"$TMP/success-output" 2>&1
head_hash="$(git -C "$REPO" rev-parse HEAD)"
if [ ! -x "$candidate_root/$head_hash/install/bin/netlisp" ]; then
  echo "FAIL: the successful path did not publish an executable candidate" >&2
  cat "$TMP/success-output" >&2
  exit 1
fi

echo "prepare-release fail-fast cancellation and success path OK (${elapsed}s failure)"
