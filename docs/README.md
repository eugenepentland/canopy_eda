# netlisp documentation

Start at the [repository README](../README.md) for install and a five-minute
quick start, and at [`examples/README.md`](../examples/README.md) for a complete
board built from a clone to a KiCad project. This directory is the reference
set behind them.

## Reference

Read these when you are using netlisp.

| Document | What it is |
| --- | --- |
| [`architecture.md`](architecture.md) | What the tool can do and how the pieces fit together. Read it first if you are deciding whether netlisp covers your workflow. |
| [`sexp-language.md`](sexp-language.md) | The design language, form by form, with the reasoning behind each. The document you write designs from. |
| [`language-forms.md`](language-forms.md) | The generated grammar reference: every special form, operator, `fmt` directive, SI suffix and design-scope form with its arity and scopes. Produced from the evaluator's own dispatch tables and checked stale on every build, so it cannot drift. `netlisp reference [section]` prints it from the binary. |
| [`standard-library.md`](standard-library.md) | The component library compiled into the binary, and how a project's own `lib/` overrides it entry by entry. |
| [`agents.md`](agents.md) | Driving netlisp from an AI agent: the structured tool CLI, what a design repository looks like, and a `CLAUDE.md` you can drop into your own. |
| [`webserver-api.md`](webserver-api.md) | Every HTTP route `netlisp serve` answers, and the prose behind every structured tool. |
| [`auth.md`](auth.md) | The security model: loopback is admin, everything else is refused, and what changes when you put netlisp behind a proxy or Ward. |
| [`build-and-run.md`](build-and-run.md) | The full build, run and deploy reference — including the ID-persistence rules any surface that writes designs must follow. |
| [`rework-guides.md`](rework-guides.md) | Bench rework and deviation guides stored beside a design and shown on its assembly page. |

## Process

Read these when you are working *on* netlisp. [`CONTRIBUTING.md`](../CONTRIBUTING.md)
is the short version; these are the long ones.

| Document | What it is |
| --- | --- |
| [`worktrees.md`](worktrees.md) | The mandatory branch-in-a-worktree workflow, and (for the maintainer's machine) how a merge deploys. |
| [`testing-guide.md`](testing-guide.md) | Test filters, sharding, `test-compile`, `test-affected`, the mutation tiers and the browser performance gates. |
| [`build-system.md`](build-system.md) | Build graph internals: build modes, codegen backends, and which command answers which question. |
| [`../.githooks/README.md`](../.githooks/README.md) | Which files are single-machine operator machinery, and what `install.sh` does with and without `--deploy`. |
| [`../ZIG_TOOLCHAIN.md`](../ZIG_TOOLCHAIN.md) | The pinned compiler, its mirrors and checksums. |

Two root files are referenced constantly and are worth knowing about:
[`SPEC.md`](../SPEC.md) is the behaviour ledger the Guardian gate enforces
(every `- ` bullet has a test tagged with its exact text), and
[`FEEDBACK.md`](../FEEDBACK.md) is the maintainer's append-only repository log.
[`AUDIT-LEDGER.toml`](../AUDIT-LEDGER.toml) records past security and
correctness findings and gates each fixed one on a regression test that still
exists.

## Benchmarks

[`benchmarks/`](benchmarks) holds committed performance baselines — page load,
PCB editor, browser UI, toolchain — read by `scripts/perf_gate.sh` and the
pre-push hook. Each subdirectory has its own README describing the workload and
how to re-record it. These are recorded on the maintainer's hardware and are
not comparable to yours.

## Archive

[`archive/`](archive) holds historical audits, implementation plans, proposals
and research notes. None of it describes how netlisp behaves today; it is kept
for the reasoning behind subsystems that already shipped and the options that
were measured and rejected. [`archive/README.md`](archive/README.md) lists each
document with its date and status.
