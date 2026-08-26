#!/bin/sh

# Reclaim per-worktree Zig local caches without touching source or branches.
#
# The automatic post-merge mode considers only worktrees parked at a non-first
# parent of the merge that just landed on main. The explicit --all mode is the
# catch-up tool for old worktrees: it considers every linked worktree whose HEAD
# is already contained in main. Both modes require a clean worktree and preserve
# custom .zig-cache symlinks.
set -eu

usage() {
    echo "usage: $0 --post-merge | --all [--dry-run]" >&2
    exit 2
}

mode=""
dry_run=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --post-merge)
            [ -z "$mode" ] || usage
            mode=post-merge
            ;;
        --all)
            [ -z "$mode" ] || usage
            mode=all
            ;;
        --dry-run)
            dry_run=1
            ;;
        *) usage ;;
    esac
    shift
done
[ -n "$mode" ] || usage

common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
main_root=${common_dir%/.git}
main_ref=${WORKTREE_CACHE_MAIN_REF:-main}

if [ "$mode" = post-merge ]; then
    # Merges on feature branches do not retire those branches. Limit automatic
    # cleanup to the repository's completion boundary.
    current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ "$current_branch" = "$main_ref" ] || exit 0
    merge_line=$(git rev-list --parents -n1 HEAD 2>/dev/null || true)
    merge_commit=${merge_line%% *}
    merge_parents=${merge_line#* }
    [ "$merge_parents" != "$merge_commit" ] || exit 0
    first_parent=${merge_parents%% *}
    completed_parents=${merge_parents#* }
    # A one-parent commit has no completed side of a merge.
    [ "$completed_parents" != "$first_parent" ] || exit 0
fi

is_candidate() { # $1 = worktree HEAD
    candidate_head=$1
    if [ "$mode" = all ]; then
        git merge-base --is-ancestor "$candidate_head" "$main_ref" 2>/dev/null
        return
    fi

    for completed_head in $completed_parents; do
        [ "$candidate_head" = "$completed_head" ] && return 0
    done
    return 1
}

prune_cache() { # $1 = path, $2 = HEAD, $3 = locked (0/1)
    worktree_path=$1
    worktree_head=$2
    worktree_locked=$3

    [ -n "$worktree_path" ] || return 0
    [ "$worktree_path" != "$main_root" ] || return 0
    [ "$worktree_locked" -eq 0 ] || return 0
    is_candidate "$worktree_head" || return 0

    cache_path="$worktree_path/.zig-cache"
    # A symlink may be deliberate user configuration. Only the ordinary local
    # cache directory created by post-checkout is disposable here.
    [ -d "$cache_path" ] || return 0
    [ ! -L "$cache_path" ] || return 0
    # Exclude the cache path explicitly as well as relying on .gitignore, so
    # the safety check still works in stripped-down test repos and fresh clones.
    [ -z "$(git -C "$worktree_path" status --porcelain --untracked-files=normal -- \
        . ':(top,exclude).zig-cache' 2>/dev/null)" ] || {
        printf 'worktree-cache: kept dirty worktree cache %s\n' "$cache_path"
        return 0
    }

    cache_size=$(du -sh "$cache_path" 2>/dev/null | awk '{print $1}')
    if [ "$dry_run" -eq 1 ]; then
        printf 'worktree-cache: would clear %s (%s)\n' "$cache_path" "${cache_size:-unknown size}"
        return 0
    fi

    rm -rf -- "$cache_path"
    mkdir -p -- "$cache_path"
    printf 'worktree-cache: cleared %s (%s)\n' "$cache_path" "${cache_size:-unknown size}"
}

worktree_path=""
worktree_head=""
worktree_locked=0
git worktree list --porcelain | while IFS= read -r line; do
    case "$line" in
        "worktree "*) worktree_path=${line#worktree } ;;
        "HEAD "*) worktree_head=${line#HEAD } ;;
        locked*) worktree_locked=1 ;;
        "")
            prune_cache "$worktree_path" "$worktree_head" "$worktree_locked"
            worktree_path=""
            worktree_head=""
            worktree_locked=0
            ;;
    esac
done

# This only removes administrative records for worktree directories that are
# already gone; it never removes a live worktree or branch.
[ "$dry_run" -eq 1 ] || git worktree prune
