#!/usr/bin/env bash
# Host prerequisites for `zig build` / `zig build test`.
#
# The build graph and Guardian's external gates shell out to `node` (the
# browser-asset syntax gates and the JS unit-test runners) and to `python3`
# with `tomllib` (the audit-ledger and JS-asset-gate checkers). When either is
# missing, those gates fail with a bare spawn error that says nothing about
# what to install. This runs first and says it in one line instead.
set -uo pipefail

fail() {
  echo "netlisp: missing build prerequisite — $1" >&2
  exit 1
}

command -v node >/dev/null 2>&1 ||
  fail "Node.js 20+ not found on PATH (the build runs node asset gates and JS unit tests). Install Node 20 or newer, e.g. https://nodejs.org/"

node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
case "$node_major" in
  '' | *[!0-9]*)
    fail "could not read a version from \`node\` on PATH. Install Node.js 20 or newer, e.g. https://nodejs.org/"
    ;;
esac
if [ "$node_major" -lt 20 ]; then
  fail "Node.js $(node --version) is too old; the build requires Node 20 or newer, e.g. https://nodejs.org/"
fi

command -v python3 >/dev/null 2>&1 ||
  fail "python3 3.11+ not found on PATH (the build runs the audit-ledger and JS-asset-gate checkers). Install Python 3.11 or newer."

python3 -c 'import tomllib' >/dev/null 2>&1 ||
  fail "this python3 ($(python3 -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || echo unknown)) has no \`tomllib\`; the build requires Python 3.11 or newer."

exit 0
