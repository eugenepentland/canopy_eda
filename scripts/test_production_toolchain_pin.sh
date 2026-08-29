#!/usr/bin/env bash
# Contract test for the production compiler boundary. A same-version compiler
# must not prepare or deploy a candidate, and systemd must never bypass the
# verified candidate pipeline by rebuilding during restart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARE="$ROOT/.githooks/prepare-release.sh"
DEPLOY="$ROOT/.githooks/deploy-prod.sh"
UNIT="$ROOT/systemd/netlisp.service"
WANT_PATH='/home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/zig'
WANT_SHA='8f4af9650b5358abcdd8a283976d30b5dcdca2b400e44af25953b2e34101e7d4'

for script in "$PREPARE" "$DEPLOY"; do
  grep -Fq "PRODUCTION_ZIG=\"$WANT_PATH\"" "$script"
  grep -Fq "REQUIRED_ZIG_SHA256=\"$WANT_SHA\"" "$script"
  grep -Fq 'if [ "$ZIG_SHA256" != "$REQUIRED_ZIG_SHA256" ]; then' "$script"
done

# Deployment independently rechecks the provenance recorded by preparation.
grep -Fq '[ "$(cat "$candidate/compiler-sha256")" = "$ZIG_SHA256" ] || return 1' "$DEPLOY"
grep -Fq '"$STRIP" --strip-all "$staging/install/bin/netlisp"' "$PREPARE"
grep -Fq '.use_llvm = if (optimize == .safe) false else null,' "$ROOT/build.zig"

if grep -q '^ExecStartPre=' "$UNIT"; then
  echo 'FAIL: systemd can rebuild outside the verified candidate pipeline' >&2
  exit 1
fi
grep -q '^Restart=always$' "$UNIT"
grep -q '^Environment=NETLISP_GIT_AUTOCOMMIT=0$' "$UNIT"

# The unit must run the DEPLOYED artifact, never the dev build output. Checking
# only for ExecStartPre missed the 2026-08-19 incident, where this tracked unit
# pointed at zig-out/bin — the path any `zig build` overwrites — and prod served
# a Debug binary for five hours. The rendered template is the source of truth
# (.githooks/netlisp.service.in), so the two must name the same binary.
if ! grep -q '^ExecStart=.*/\.deploy/bin/netlisp ' "$UNIT"; then
  echo 'FAIL: unit ExecStart does not run the deployed .deploy/bin/netlisp artifact' >&2
  exit 1
fi
if grep -q '^ExecStart=.*/zig-out/' "$UNIT"; then
  echo 'FAIL: unit ExecStart runs the overwritable zig-out build output' >&2
  exit 1
fi
grep -Fq 'ExecStart=@TOP@/.deploy/bin/netlisp' "$ROOT/.githooks/netlisp.service.in"

echo 'production toolchain path, compiler SHA, candidate provenance, and service boundary OK'
