#!/usr/bin/env bash
# Verify that Guardian still BLOCKS on a failing [[external]] gate.
#
# This tree declares 45 external gates — every browser-asset syntax check, the
# JS unit-test runners, the policy checkers. For an unknown length of time all
# of them were decorative: guardian-zig named a failing gate's findings in a
# shape its own baseline layer discarded, so a gate that exited nonzero printed
# "FAILED" and then passed (AUDIT-LEDGER.toml DRIFT-INFRA-004). Nothing here
# would have noticed, because a gate that never fires and a gate that cannot
# fire look identical from inside a green run.
#
# So this asserts the property directly, on a throwaway fixture: a project with
# one external that exits 1 must make guardian-check exit nonzero. It is a
# check on the TOOLCHAIN, not on this tree — the one thing the toolchain cannot
# check about itself from in here.
#
# Read-only with respect to this repository; the fixture lives under a temp dir
# and is removed on exit.
set -euo pipefail

GUARDIAN="${GUARDIAN:-guardian-check}"
if ! command -v "$GUARDIAN" >/dev/null 2>&1; then
  echo "external-gates-armed: '$GUARDIAN' not on PATH" >&2
  echo "  A missing checker must fail rather than skip: an unrun probe is how" >&2
  echo "  the gate it guards went unnoticed in the first place." >&2
  exit 1
fi

# This probe runs as a step of `zig build test`, and prepare-release runs that
# build FROM guardian — which sets GUARDIAN_SKIP_CHECKS so the wired gate
# no-ops inside its own child build. Inherited here it would silence the
# fixture runs below, and the probe would read a skipped guardian as a guardian
# that failed to block. The fixture is a throwaway project, not part of the
# parent gate, so the recursion guard does not apply to it.
unset GUARDIAN_SKIP_CHECKS GUARDIAN_MUTATION_RUN GUARDIAN_UPDATE_SNAPSHOT GUARDIAN_AGAINST

# Distinguishing "guardian was skipped" from "guardian did not block" is the
# whole point: a probe that reports the wrong one of those is worse than no
# probe, because it sends the reader after a bug that is not there.
assert_ran() {
  if printf '%s' "$1" | grep -q 'checks skipped'; then
    echo "external-gates-armed: guardian SKIPPED its checks, so this proved nothing" >&2
    echo "  $2" >&2
    echo "  guardian said:" >&2
    printf '%s' "$1" | sed 's/^/    /' >&2
    exit 1
  fi
}

# Never /tmp: it is a small per-user tmpfs here, and stale prefixes have filled
# it before and broken every tool on the machine.
fixture="$(mktemp -d "${TMPDIR:-$HOME/.cache/netlisp}/guardian-armed.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/src"

cat >"$fixture/src/main.zig" <<'ZIG'
const std = @import("std");
pub fn main() void {}
ZIG

# Baseline mode ON, matching this project's own configuration: the defect was
# invisible precisely because the baseline layer reconstructed "no findings"
# and reported a match.
write_config() {
  cat >"$fixture/guardian.toml" <<EOF
[baseline]
enabled = true

[[external]]
name = "armed-probe"
command = ["sh", "-c", "exit $1"]
inputs = ["src/*.zig"]
EOF
}

# 1. A PASSING gate records a clean baseline. Doing this first matters, and it
#    has to be `accept`, not an ordinary run: an ordinary run on a tree with no
#    baseline yet only REPORTS what it would record, and leaves the findings
#    grandfathered. Testing the failure against an absent baseline proves
#    nothing — measured, this probe's own first draft passed for that reason.
write_config 0
rm -rf "$fixture/.guardian"
accepted="$("$GUARDIAN" accept external-gates "$fixture" 2>&1)" || {
  echo "external-gates-armed: could not record a baseline for a PASSING gate" >&2
  printf '%s\n' "$accepted" | sed 's/^/    /' >&2
  exit 1
}
assert_ran "$accepted" "the baseline was never recorded, so step 2 would test against an absent one"

passing="$("$GUARDIAN" external-gates "$fixture" 2>&1)" || {
  echo "external-gates-armed: a PASSING external gate was reported as a failure" >&2
  printf '%s\n' "$passing" | sed 's/^/    /' >&2
  exit 1
}
assert_ran "$passing" "guardian ran nothing for the passing case"

# 2. The same gate now fails. This must block.
write_config 1
output="$("$GUARDIAN" external-gates "$fixture" 2>&1)" && status=0 || status=$?
assert_ran "$output" "guardian ran nothing for the failing case, so a green result means nothing"
if [ "$status" -eq 0 ]; then
  echo "external-gates-armed: A FAILING EXTERNAL GATE DID NOT BLOCK." >&2
  echo "  guardian-check exited 0 for a gate whose command exited 1, so every" >&2
  echo "  [[external]] in guardian.toml is currently decorative — including all" >&2
  echo "  the browser-asset syntax gates. This is DRIFT-INFRA-004 recurring." >&2
  echo "  guardian said:" >&2
  echo "$output" | sed 's/^/    /' >&2
  exit 1
fi

# 3. And it must NAME the gate, not just exit nonzero — an unattributable
#    failure cannot be acted on, and cannot be baselined or accepted either.
if ! printf '%s' "$output" | grep -q 'armed-probe'; then
  echo "external-gates-armed: the failure did not name the gate that failed" >&2
  echo "$output" | sed 's/^/    /' >&2
  exit 1
fi

echo "external-gates armed: a failing [[external]] blocks and names itself"
