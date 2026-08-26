#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRUNER="$ROOT/.githooks/prune-worktree-caches.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
printf 'base\n' >"$REPO/tracked"
git -C "$REPO" add tracked
git -C "$REPO" commit -qm base

FEATURE="$TMP/feature tree"
git -C "$REPO" worktree add -q -b feature "$FEATURE"
printf 'feature\n' >>"$FEATURE/tracked"
git -C "$FEATURE" commit -qam feature
mkdir -p "$FEATURE/.zig-cache"
printf 'cache\n' >"$FEATURE/.zig-cache/artifact"

git -C "$REPO" merge -q --no-ff --no-verify feature -m 'merge feature'
(cd "$REPO" && "$PRUNER" --post-merge) >"$TMP/post-merge-output"
test -d "$FEATURE/.zig-cache"
test ! -e "$FEATURE/.zig-cache/artifact"
grep -Fq "worktree-cache: cleared $FEATURE/.zig-cache" "$TMP/post-merge-output"

# Dirty work is never touched, even when the worktree is still at the exact
# merged feature tip.
printf 'cache again\n' >"$FEATURE/.zig-cache/artifact"
printf 'uncommitted\n' >>"$FEATURE/tracked"
(cd "$REPO" && "$PRUNER" --post-merge) >"$TMP/dirty-output"
test -e "$FEATURE/.zig-cache/artifact"
grep -Fq 'worktree-cache: kept dirty worktree cache' "$TMP/dirty-output"
git -C "$FEATURE" restore tracked

# --all catches old merged worktrees, while dry-run and unmerged worktrees are
# non-destructive.
UNMERGED="$TMP/unmerged"
git -C "$REPO" worktree add -q -b unmerged "$UNMERGED"
printf 'unmerged\n' >>"$UNMERGED/tracked"
git -C "$UNMERGED" commit -qam unmerged
mkdir -p "$UNMERGED/.zig-cache"
printf 'keep\n' >"$UNMERGED/.zig-cache/artifact"
printf 'cache again\n' >"$FEATURE/.zig-cache/artifact"
(cd "$REPO" && "$PRUNER" --all --dry-run) >"$TMP/dry-run-output"
test -e "$FEATURE/.zig-cache/artifact"
grep -Fq "worktree-cache: would clear $FEATURE/.zig-cache" "$TMP/dry-run-output"
(cd "$REPO" && "$PRUNER" --all) >"$TMP/all-output"
test ! -e "$FEATURE/.zig-cache/artifact"
test -e "$UNMERGED/.zig-cache/artifact"

# A custom cache symlink is configuration, not disposable derived data.
rmdir "$FEATURE/.zig-cache"
mkdir "$TMP/custom-cache"
printf 'custom\n' >"$TMP/custom-cache/artifact"
ln -s "$TMP/custom-cache" "$FEATURE/.zig-cache"
(cd "$REPO" && "$PRUNER" --all)
test -L "$FEATURE/.zig-cache"
test -e "$TMP/custom-cache/artifact"

echo 'worktree Zig cache pruning boundaries OK'
