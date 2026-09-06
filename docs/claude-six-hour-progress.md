# Netlisp six-hour sprint progress

- Start UTC: **2026-09-06T05:27:55Z**
- Deadline UTC (fixed across resumes): **2026-09-06T11:27:55Z**
- Closeout begins UTC: **2026-09-06T10:42:55Z** (last 45 min)
- Starting main commit: `517cc58b`
- Execution worktree and branch: `.claude/worktrees/claude-sprint-0906` / `claude/sprint-0906`
- Allowance basis / starting use / latest observed use: **not measurable from
  inside this session.** No usage telemetry tool is exposed here (`/usage` is an
  interactive terminal command, not a tool call), so this sprint is run on the
  **time budget only**. The user's stated "~50% of allowance" is recorded but
  cannot be tracked or converted; context-window occupancy is deliberately NOT
  used as a proxy.
- Usage observable: **no**; measurement source: none available.

## Ownership check (done at start)

18 sibling worktrees exist. Most recent commits: `rough-intent` 05:21,
`power-voltage-budget` 04:44, `p3-perf-baseline` 03:31. Files they hold and this
sprint therefore avoids: `src/placement/*` (rough-intent, black-canyon-rf-straight,
internal-cutouts, pour-gap-everywhere, pad-size-aware-tapers),
`src/serve/pcb_layout_mcp.zig` + `src/serve/pcb_layout_page.zig` (net-rename-copper,
trace-selection-priority), `src/serve/mcp_tools.zig` (alloc-waivers),
`src/serve/assets/pcb_board.js` (three worktrees), `src/export_fab.zig`
(jlc-export-format), `src/export_gerber.zig` (internal-cutouts, pour-gap-everywhere).

That rules out A05/A06/A07/A12 and most of the B queue by file collision.
Selected lane: **CLI / inspection tooling / benchmark durability**, which no
sibling worktree touches.

| Item | State | Current evidence / commit | Next action |
| --- | --- | --- | --- |
| A01 | **merged-pending** (verified, committed) | `cac63843` — see "Completed changes" | integrate at closeout |
| A02 | selected | bulk net-envelope dump | implement |
| A03 | selected | bench-route per-board checkpoint | implement after A02 |
| A05 A06 A07 A12 | owned-elsewhere | files held by net-rename-copper / black-canyon-rf-straight / rough-intent | skip |
| B01 B02 B03 B06 | owned-elsewhere | `src/placement/*` held by 5 worktrees; heavy board runs also contend for the gate lock | skip |

## Completed changes

### A01 — `serve` command line decided before anything is opened (`cac63843`)

**Problem (reproduced on the base build, evidence below).** `netlisp serve --help`
started the server: it created `<project>/logs/interactions-2026-09-06.jsonl`,
bound the port and blocked until killed (`timeout` exit 124). `--port abc`,
`--port 99999` and a valueless `--port` all silently served on 7050. An unknown
flag (`--allow-remoote`) was ignored, so an operator who believed they had
disabled the auth gate had not.

**Behaviour now.** `src/serve_args.zig` is a pure `parse(argv, auth_dir_env)`
returning `.help` / `.invalid` / `.run`; `dispatchServe` opens a socket only for
`.run`. `--help`/`-h` print serve's own flag list and exit 0. Unknown flag,
missing value, non-numeric / out-of-range / zero port, and a stray positional
each name the offending token and exit 1.

**Evidence.**
- Repro + verification transcripts: this session, against a disposable project
  under the session scratchpad (`.../scratchpad/a01proj`, `.../scratchpad/a01check`).
- `--help` leaves the project directory byte-identical (no `logs/`); all five
  malformed forms exit 1 having written nothing.
- `--port 7188 --skip-warmup` still answers HTTP 200 on `/`.
- 8 unit tests: `zig build --seed=1 test -Dtest-filter='serve_args.test'` →
  `RESULT {"passed":44,"failed":0,"skipped":0}` (8 named + 36 unnamed bridges).
- Whole-tree Guardian gate at commit: 88 checks, **0 blocking**, 4 report-only.
- Registries updated: `src/test_root.zig`, `src/test_shards.zig`; `SPEC.md`
  gained a `## Serve CLI` section (8 bullets + completeness waivers);
  `.guardian/pub-api.txt` accepted (7 pure additions).

## Verification and measurements

Build/test commands used, all in this worktree with its own prefix
(`-p zig-out-sprint`) so no running server's binary is overwritten:

```
zig build --seed=1 -p zig-out-sprint
zig build --seed=1 test -Dtest-filter='serve_args.test'
```

## Gate/integration status

`claude/sprint-0906` is unmerged. `.githooks/prepare-release.sh` has not run yet;
it runs once at closeout, before any merge.

## Reproduced blockers and preserved experiments

- `-Dtest-filter` matches the **test name**, not the `// spec:` tag. Filtering on
  a spec-tag phrase selects 0 named tests and Guardian correctly fails the run
  ("NOTHING YOU ASKED FOR RAN"). Use the module prefix (`serve_args.test`).

## Next useful tasks

1. A02 — one bulk net-envelope inspection surface.
2. A03 — preserve `bench-route` progress when a later board fails.
3. C09 — advertised tool schemas vs actual dispatch (read-only audit).
