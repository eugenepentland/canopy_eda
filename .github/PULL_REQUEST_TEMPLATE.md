<!--
Thanks for contributing. CONTRIBUTING.md is the long version of this checklist;
this is the short one. Keep a PR to one topic — a change that touches the
evaluator, the renderer and an exporter is usually three PRs.
-->

## What changed

<!--
Describe the change in the design, not the files that moved. What behavior is
different now?
-->

## What a user sees

<!--
The user-facing effect: what a design evaluates to now, what the schematic or
board looks like, what a command prints, what an exported netlist or Gerber
contains. Include a before/after when the effect is visual.
-->

## How it was verified

<!-- Which tests, which designs, which commands. -->

## Checklist

- [ ] Work was done on a branch in its own worktree, not in the `main` checkout
- [ ] `zig build --seed=1 test` passes on the final tree
- [ ] Guardian is green — no check was loosened in `guardian.toml` to get past it
- [ ] `src/serve/pcb_layout_page.zig` and `src/placement/router.zig` did not grow
- [ ] Any `.guardian/` snapshot acceptance is a **named** check
      (`GUARDIAN_UPDATE_SNAPSHOT=<check>`), and the diff is committed here and
      explained below
- [ ] New behavior has a `SPEC.md` bullet **and** its `// spec:` tagged test in
      this same change
- [ ] No test named in `AUDIT-LEDGER.toml` was deleted or renamed (or the ledger
      entry was updated with it)
- [ ] A new module with tests is listed in `src/test_root.zig` and claimed by
      one shard in `src/test_shards.zig`
- [ ] `zig build docs` was run and `docs/language-forms.md` committed, if the
      design language changed
- [ ] Documentation updated if behavior, flags or output changed
- [ ] `FEEDBACK.md` was not touched

## Notes for the reviewer

<!--
Anything to explain: a Guardian acceptance, a performance cost you suspect, a
design decision with an alternative you rejected, a follow-up you deliberately
left out of scope.
-->
