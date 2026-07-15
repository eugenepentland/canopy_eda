# Shared Zig cache for worktrees

The `post-checkout` hook links a newly-created worktree's `.zig-cache` to the
main checkout's `.zig-cache`. This keeps all EDA worktrees on one local Zig
cache while leaving `zig-out` local to each checkout.

This checkout is configured with:

```sh
git config core.hooksPath /home/epentland/ai/canopy/eda/.githooks
```

The committed `post-merge` and `post-commit` bridge hooks forward to matching
machine-local hooks under `.git/hooks/`. This preserves EDA's local production
deployment hooks while `core.hooksPath` points here.

Do not delete the shared cache while Zig builds are running. It remains safe
to remove when no build is active; Zig will recreate it on the next build.
