# Repository Agent Instructions

## Mandatory worktree workflow

Never modify the `main` checkout directly. Every project update must be made on
a feature branch in its own git worktree, including code, tests, design files,
documentation, specifications, Guardian metadata, generated files, and config.

Before any command that can write project files:

1. Run `git branch --show-current`, `git status --short`, and
   `git worktree list`.
2. If the current checkout is `main`, create a task worktree before editing:

   ```bash
   git worktree add .claude/worktrees/<short-task> -b codex/<short-task> main
   cd .claude/worktrees/<short-task>
   ```

   Use the branch prefix required by the active agent environment when it is
   not `codex/`.
3. Confirm the new worktree's branch and status, then perform all edits, code
   generation, builds, tests, Guardian acceptance, staging, and commits there.

The root `main` checkout is reserved for read-only inspection and explicitly
requested integration/deployment operations. `main` should receive completed
work through a reviewed branch merge, never through direct file edits or a
direct commit. Do not merge a worktree branch unless the user asks for it.

Treat commands that may rewrite files as write operations even when they sound
diagnostic. Examples include `zig build docs`, formatters without `--check`,
Guardian snapshot/baseline acceptance, import/export commands, and tests or
builds known to regenerate metadata.

If the `main` checkout is already dirty, do not stage, commit, move, overwrite,
or discard those changes. They may belong to another person or task. Create the
task worktree from the requested base, keep the new work isolated, and report
the pre-existing main-checkout state to the user.

Before handing work back, report the worktree path, feature branch, verification
performed, and whether the branch remains unmerged.

