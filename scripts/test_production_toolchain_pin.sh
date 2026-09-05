#!/usr/bin/env bash
# Contract test for the production toolchain boundary.
#
# There is exactly ONE compiler in this project: the official pinned Zig master
# snapshot named by `.zigversion`, taken from PATH (or `$ZIG`). Release
# preparation and deployment must verify that version and refuse to run on any
# other, must not reintroduce a private compiler path or a compiler-binary SHA
# pin, and systemd must never bypass the verified-candidate pipeline by
# rebuilding during restart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARE="$ROOT/.githooks/prepare-release.sh"
DEPLOY="$ROOT/.githooks/deploy-prod.sh"
UNIT="$ROOT/systemd/netlisp.service"
PINNED="$(tr -d '[:space:]' <"$ROOT/.zigversion")"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -n "$PINNED" ] || fail '.zigversion is empty'

# build.zig carries the required version as a compile-time constant (it is
# compared against `builtin.zig_version_string` before anything else runs), so
# the two spellings of the pin must agree or a bump silently half-lands.
grep -Fq "pub const required_zig_version = \"$PINNED\";" "$ROOT/build.zig" ||
  fail "build.zig's required_zig_version does not match .zigversion ($PINNED)"

for script in "$PREPARE" "$DEPLOY"; do
  name="$(basename "$script")"
  # PATH is the default; $ZIG is the only override.
  grep -Fq 'ZIG="${ZIG:-zig}"' "$script" ||
    fail "$name does not default to the PATH compiler"
  # .zigversion is the single source of truth for the required version.
  grep -Fq 'REQUIRED_ZIG="$(tr -d '"'"'[:space:]'"'"' <"$TOP/.zigversion")"' "$script" ||
    fail "$name does not read the required version from .zigversion"
  grep -Fq 'if [ "$ZIG_VERSION" != "$REQUIRED_ZIG" ]; then' "$script" ||
    fail "$name does not reject a compiler whose version differs from the pin"
  # A duplicated version string drifts; a home-directory compiler path or a
  # binary-SHA pin is the private toolchain coming back.
  ! grep -Fq "$PINNED" "$script" ||
    fail "$name hardcodes the pinned version instead of reading .zigversion"
  ! grep -q 'zig-toolchains\|zig-prod\|PRODUCTION_ZIG\|REQUIRED_ZIG_SHA256' "$script" ||
    fail "$name references a private production compiler"
done

# The compiler binary SHA is still RECORDED (it keys the per-tree caches and the
# candidate's provenance), and deployment still rechecks what preparation wrote.
grep -Fq 'ZIG_SHA256="$(sha256sum "$ZIG" | awk '"'"'{print $1}'"'"')"' "$PREPARE" ||
  fail 'prepare-release.sh no longer fingerprints the compiler binary'
grep -Fq '[ "$(cat "$candidate/compiler-sha256")" = "$ZIG_SHA256" ] || return 1' "$DEPLOY" ||
  fail 'deploy-prod.sh no longer rechecks the candidate compiler fingerprint'
grep -Fq '"$STRIP" --strip-all "$staging/install/bin/netlisp"' "$PREPARE" ||
  fail 'prepare-release.sh no longer strips the production executable'

# The release artifact is emitted by the self-hosted backend; `-Dllvm` is an
# opt-in developer escape hatch and must default to off.
grep -Fq '.use_llvm = if (use_llvm) true else if (optimize == .debug) null else false,' "$ROOT/build.zig" ||
  fail 'build.zig no longer defaults optimized builds to the self-hosted backend'
! grep -q -- '-Dllvm' "$PREPARE" "$DEPLOY" ||
  fail 'the release path opts into the slow LLVM backend'

if grep -q '^ExecStartPre=' "$UNIT"; then
  fail 'systemd can rebuild outside the verified candidate pipeline'
fi
grep -q '^Restart=always$' "$UNIT" || fail 'the unit does not use Restart=always'
grep -q '^Environment=NETLISP_GIT_AUTOCOMMIT=0$' "$UNIT" ||
  fail 'the unit does not disable per-request git auto-commit'

# The unit must run the DEPLOYED artifact, never the dev build output. Checking
# only for ExecStartPre missed the 2026-08-19 incident, where this tracked unit
# pointed at zig-out/bin — the path any `zig build` overwrites — and prod served
# a Debug binary for five hours. The rendered template is the source of truth
# (.githooks/netlisp.service.in), so the two must name the same binary.
if ! grep -q '^ExecStart=.*/\.deploy/bin/netlisp ' "$UNIT"; then
  fail 'unit ExecStart does not run the deployed .deploy/bin/netlisp artifact'
fi
if grep -q '^ExecStart=.*/zig-out/' "$UNIT"; then
  fail 'unit ExecStart runs the overwritable zig-out build output'
fi
grep -Fq 'ExecStart=@TOP@/.deploy/bin/netlisp' "$ROOT/.githooks/netlisp.service.in" ||
  fail 'the deploy-hook unit template does not run the deployed artifact'

echo 'toolchain pin (.zigversion via PATH), candidate provenance, backend default, and service boundary OK'
