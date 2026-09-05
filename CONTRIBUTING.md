# Contributing to netlisp

Thanks for looking at netlisp. This file is the short version of how work gets
done here. It is worth reading once end to end, because this repository has two
habits that are unusual and that will otherwise fail your first build or your
first commit: **every build runs a code-quality gate**, and **nobody edits the
`main` checkout directly**.

netlisp is MIT licensed (see [LICENSE](LICENSE)). By contributing you agree
that your contribution is offered under the same license. There is no CLA.

- Code of conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Security reports: [SECURITY.md](SECURITY.md) — do **not** open a public issue
  for a vulnerability.

## 1. Prerequisites and your first build

Linux x86_64 is the platform the test suite runs on. macOS and aarch64 Linux
toolchains are mirrored but untested.

| Tool | Version |
| --- | --- |
| Zig | exactly the snapshot in [`.zigversion`](.zigversion) |
| Node.js | 20 or newer |
| Python | 3.11 or newer |
| git | any recent version |

The Zig pin is exact and `build.zig` refuses to configure on anything else,
including a *newer* master snapshot — Zig master has no stability guarantee and
this tree tracks a snapshot deliberately. Install the right one with:

```bash
scripts/install-zig.sh --link      # downloads, verifies the SHA-256, symlinks ~/.local/bin/zig
zig version                        # must print exactly the contents of .zigversion
```

Then:

```bash
zig build --seed=1                 # first build fetches and compiles the Guardian gate (~2 min)
zig build run -- serve --project-dir test/fixtures/stdlib-smoke
```

The first build is the only one that needs the network: it downloads the
Guardian dependency once, pinned by URL and hash in `build.zig.zon`. Later
builds are offline and take seconds. Full details:
[README.md](README.md) and [ZIG_TOOLCHAIN.md](ZIG_TOOLCHAIN.md).

## 2. Where you make changes: branch, and don't touch `main`

**Never edit files in the `main` checkout.** Create a branch in its own git
worktree and do everything there — code, tests, docs, `SPEC.md`, config,
generated files, Guardian metadata, and the commits:

```bash
git worktree add .claude/worktrees/my-change -b my-change main
cd .claude/worktrees/my-change
```

Why, honestly: this repository is worked on by several sessions at once
(including AI agent sessions), `main` is reserved for read-only inspection and
integration, and the maintainer's machine runs hooks that auto-commit and
auto-deploy from `main`. Loose uncommitted state on `main` has been swept into
an auto-commit and silently reverted another branch's work before. A worktree
per change makes that impossible.

If you are working in a fork and no automation is watching your `main`, a plain
feature branch is equivalent — the rule that matters is *branch, commit, and
keep the base checkout clean*. `.claude/worktrees/` is gitignored, so the
worktree itself never shows up in a diff. The full workflow, including how to
retire a merged worktree, is in [docs/worktrees.md](docs/worktrees.md).

## 3. The Guardian gate

[Guardian](https://github.com/eugenepentland/guardian-zig) is a code-quality
gate that runs its **full check suite on every `zig build` and every
`zig build test`**. There is no bypass flag, and the answer to a failing check
is to fix the code, never to loosen the rule.

It runs in **baseline mode**: every pre-existing violation is frozen in
`.guardian/baselines/<check>.txt`, so an untouched tree passes and only *new*
violations fail. When something fires, ask it why rather than guessing:

```bash
zig build guardian-explain -Dguardian-explain=<check>   # works in a fresh clone
guardian-check explain <check>                          # same thing, if the CLI is on your PATH
```

Every gated run also appends one JSON record per violation to
`.guardian/cache/last-run.jsonl`, which is the machine-readable version of the
same output.

### Accepting a snapshot

Some checks record a snapshot or a ratchet rather than a list of violations
(public API surface, per-item size ceilings, spec coverage, mutation score). If
a change legitimately moves one, accept **that one check by name** and commit
the resulting `.guardian/` diff with the change that caused it:

```bash
GUARDIAN_UPDATE_SNAPSHOT=<check> zig build     # or: zig build guardian-accept -Dguardian-checks=<check>
git add .guardian && git commit
```

Never run a bare `GUARDIAN_UPDATE_SNAPSHOT=1` — that ratifies every snapshot at
once and quietly launders unrelated drift into your commit. The `.guardian/`
files are sorted plain text so they diff cleanly in review; a reviewer will
read them.

Note that several checks are configured with `deny_growth` (see the header
comments in [`guardian.toml`](guardian.toml)) — for those, acceptance refuses
to record *more* debt at all. The ceiling can shrink; it cannot grow.

### The two files you must not grow

The `file-size` check counts *code* lines (non-blank, non-comment, outside
`test` blocks). It warns above 1,000 and **blocks above a hard cap of 10,000
that cannot be accepted** — no env var, no ceiling raise, no exemption. Two
files are close enough to that cap that they are effectively closed to growth:

| File | Code lines | |
| --- | ---: | --- |
| `src/serve/pcb_layout_page.zig` | ~9,600 | already prints a `NEAR HARD CAP` warning at 96% |
| `src/placement/router.zig` | ~8,500 | next in line |

Both are also frozen in `.guardian/baselines/file-size.txt` at a recorded
ceiling that can only shrink, so growth past *that* is a new violation long
before the hard cap — as this was written, each had only a few dozen lines of
headroom. And if a file does cross the hard cap it is *tripped* and stays
tripped: every later addition blocks, and the trip clears only once the file
falls to 8,000 lines.

So: **do not add lines to either file.** Put the code you are writing — and, if
you can, a cohesive neighbouring chunk that already exists — into a new module
under `src/serve/` or `src/placement/` and import it. Splitting along a real
seam is the outcome the check is asking for, and it lowers that file's ceiling
in the process. Do not raise a limit in `guardian.toml` to get past this.
`guardian-check size <file> .` reads a file's current count back without
running the gate.

## 4. Tests, `SPEC.md`, and the audit ledger

### The loop

```bash
zig build --seed=1 test -Dtest-filter='the behavior I am changing'   # fast, focused
zig build test-compile                                              # type-check every test, run none
zig build test-affected                                             # pick tests from your diff, then test-compile
zig build --seed=1 test                                             # the whole suite — before you open a PR
```

`zig build test-affected` is the default inner-loop check when the right test
names are not obvious: it reads your working-tree diff, follows `@import` and
`@embedFile` consumers, runs the tests it selected, and finishes with a
whole-suite `test-compile`. Run the unfiltered `zig build --seed=1 test` once
before opening a PR. A filtered run has two blind spots that have burned this
repo — tests it skipped were never type-checked, and a filter that matches
nothing used to exit 0 — so do not treat a green filtered run as a green suite.
Everything about filters, sharding and the mutation tiers is in
[docs/testing-guide.md](docs/testing-guide.md).

Pass `--seed=1` to any run whose result you want cached; without it Zig
randomizes the seed and an unchanged rerun recompiles.

### Adding a new module that has tests

The suite is **sharded**: `zig build test` compiles one test binary per shard
and each shard is a `--test-filter` list. Two consequences for a new file under
`src/`:

1. Add it to the exhaustive import bridge in `src/test_root.zig`. Zig only
   collects a file's tests when the file is analyzed, and a filtered shard
   would otherwise silently compile your tests into no binary at all.
2. Claim its tests in exactly one shard in `src/test_shards.zig` (usually one
   entry of the form `"my_module.test."`).

Both are enforced by tests in `src/test_root.zig`, so if you forget you get a
loud failure rather than a test that quietly never runs — which is exactly how
the first sharded build lost 49 tests with all eight shards reporting PASS.

### The `// spec:` tag contract

`SPEC.md` is a behavior list, and its `- ` bullets map **1:1** to
`// spec: Section - Behavior` comments on tests. Guardian gates the mapping and
refuses to let spec debt grow, which means:

- A new behavior needs a new `SPEC.md` bullet **and** its tagged test in the
  *same* change. Neither half lands alone.
- The tag text must match the bullet exactly, and the section must match the
  `##` heading the bullet lives under.

To add one, append a bullet under the right heading in `SPEC.md`:

```markdown
## sexpr/parser

- Parses a negative SI-scaled literal into a scaled float node
```

and tag the test that proves it:

```zig
// spec: sexpr/parser - Parses a negative SI-scaled literal into a scaled float node
test "parser scales a negative SI literal" {
    ...
}
```

`guardian-check spec-sync .` prints dry-run suggestions for bullets that are
missing.

### `AUDIT-LEDGER.toml`

[`AUDIT-LEDGER.toml`](AUDIT-LEDGER.toml) records past security and correctness
findings. Every entry marked `status = "fixed"` must name a regression test
that **still exists in the tree**, and `scripts/check_audit_ledger.py` fails the
build when one does not.

The practical consequence: **a test named in the ledger cannot be deleted or
renamed on its own.** It is the only thing proving a specific past bug stays
fixed — a `</script>` escaping bug in this tree was fixed once, lost its guard,
and came back through three sibling serializers. If you must rename such a
test, update its ledger entry in the same commit; if you think a test there is
genuinely obsolete, say so in the PR and let a maintainer decide.

## 5. Generated documentation

`docs/language-forms.md` is generated from the evaluator's own dispatch tables,
and `zig build` **fails when the committed copy is stale**. After any change to
the design language — a new special form, a new `fmt` directive, a new SI
suffix, a new classifier keyword — regenerate and commit it:

```bash
zig build docs
```

The hand-written language reference is [docs/sexpr-language.md](docs/sexpr-language.md);
`docs/language-forms.md` is the machine-checked companion, and the binary will
also print it with `netlisp reference [section]`. Start at
[docs/architecture.md](docs/architecture.md) for how the pipeline fits together
and [docs/webserver-api.md](docs/webserver-api.md) for HTTP routes and the
structured tool surface.

## 6. Git hooks

Install the hooks (and nothing else) on a fresh clone:

```bash
.githooks/install.sh            # hooks only — safe on any machine
.githooks/install.sh --check    # report what is and isn't installed, change nothing
```

That gives you a `pre-commit` hook which runs the same Guardian gate before a
commit is written. It needs a `guardian-check` binary and looks, in order, at
`$GUARDIAN_CHECK`, `./zig-out/bin/guardian-check`, and `guardian-check` on your
`PATH`; it refuses the commit if it finds none. A fresh clone has none of
those — `zig build` compiles the gate into Zig's cache rather than installing a
CLI — so if you do not have one, skip the hooks and rely on the build, which
runs the identical gate.

Do **not** run `.githooks/install.sh --deploy`. That arms an auto-deploy of a
production systemd service on every merge into `main`, and is correct on
exactly one machine.

## 7. Sending a pull request

- **One topic per PR, and keep it small.** A change that touches the evaluator,
  the renderer and the exporter is three PRs unless the coupling is the point.
- **Green before you open it.** `zig build --seed=1 test` must pass, and CI
  runs the same gate.
- **Say what changed in the design, and what a user sees.** The most useful PR
  description names the behavior that is different, not the files that moved:
  what a design evaluates to now, what the schematic or board looks like, what
  a CLI command prints, what an exported netlist contains. Include a before/after
  when the effect is visual.
- **Commit the generated and metadata files your change caused** — a
  `docs/language-forms.md` regeneration, a `.guardian/` acceptance, a `SPEC.md`
  bullet, an `AUDIT-LEDGER.toml` edit — in the same commit as the code.
- **Don't append to `FEEDBACK.md`.** It is the maintainer's repository log, not
  a changelog.
- Fill in [the PR template](.github/PULL_REQUEST_TEMPLATE.md); it is the
  checklist version of this section.

### What maintainers run and you do not

Some of the tooling in this repository is single-machine operator machinery.
You are not expected to run it, and a PR is never blocked on it:

- `.githooks/prepare-release.sh` — builds the exact deployable ReleaseSafe
  candidate.
- `.githooks/install.sh --deploy`, `deploy-prod.sh`, the systemd units — the
  merge-triggered production deploy.
- `scripts/perf_gate.sh` and the `netlisp bench-page` latency gate, plus the
  headless-Chromium performance runners. These compare against a baseline
  recorded on the maintainer's hardware; your numbers would not be comparable.

If you believe your change has a performance cost, say so in the PR and
describe the workload — the maintainer will measure it.

## 8. Filing a good bug

Use the [issue templates](.github/ISSUE_TEMPLATE). For anything where a design
evaluates, renders or exports *wrongly* — which is most netlisp bugs — the
report is only actionable with all four of:

1. **A minimal `.sexp`** that reproduces it. Cut it down: a bug that needs your
   whole board is a bug nobody can bisect. If it needs a library file, include
   that too.
2. **The exact command**, including `--project-dir` and any flags — for example
   `netlisp build --project-dir my-board my-board`.
3. **The complete output**, verbatim, not summarized. Error text, spans and
   line/column numbers are how the parser and evaluator report where they were.
4. **The version**: the output of `netlisp version` (it prints the build id —
   the netlisp commit, or the current checkout's `HEAD`), plus your OS and
   `zig version` if you built from source.

"It renders wrong" plus a screenshot is a start, but the `.sexp` is what makes
it reproducible.

## 9. Working with an agent

[`AGENTS.md`](AGENTS.md) and [`CLAUDE.md`](CLAUDE.md) are not documentation for
humans in the usual sense — they are the instruction files an AI coding agent
reads when it works in this repository, and much of netlisp was written that
way. You may find them the fastest description of the build modes, the gate,
and the reference docs; treat them as a map of the repository's conventions.

Two things follow from that:

- **The rules are the same for you.** The worktree rule, the Guardian gate, the
  spec tag contract and the audit ledger are enforced by the build, not by
  politeness, and they apply identically to a human contribution and an agent's.
- **You are accountable for what you submit.** Agent-assisted PRs are welcome —
  this is an agent-first tool — but review the diff yourself before opening it.
  Generated code that nobody has read is the thing the gate exists to catch, and
  a PR whose author cannot explain the change will be asked to.
