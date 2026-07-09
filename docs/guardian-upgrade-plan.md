# Guardian upgrade plan — enabling the 2026-07-08 feature wave

**Audience:** anyone (human or agent) working in this repo.
**What happened:** guardian-zig implemented all ten additions from its
`AUDIT-2026-07-08.md` (an audit driven largely by *this repo's* usage evidence —
the 39%-of-commits `.guardian/` churn, the 10× file-size cap, the never-run
mutation tier). This document is the adoption plan: what arrives automatically,
what to enable, in what order, and what will fire the first time.

**Guardian version required:** the feature wave lives on guardian-zig branch
`claude/gifted-elion-87c139` (commits `9a36707..de25f21`). Our dependency is
`.path = "../guardian-zig"`, which tracks that checkout's **working tree** —
so step 0 is merging that branch to `main` in `../guardian-zig`. Until then,
nothing here is visible to our builds.

---

## Rollout status (2026-07-08) — all phases executed

| Phase | Landed as | Notes |
|---|---|---|
| 0 Migration | `c2c6068` | v2 ratchets live; mutate steps auto-wired; sinks on |
| 2 Spec debt | `68c29a1`, `ed5ed86` | debt 124→109; `deny_growth=["spec"]` proven to refuse growth; remaining 101 entries are tests-without-bullets (writing work) |
| 3 Caps | `2ac896a`…`1c27f4e` | all 7 overrides deleted; 479 offenders under personal only-shrinks ceilings; toml is defaults-only |
| 4 Workflow | `6ad050a`, `8b12c2d` | nightly units in `systemd/` (**not enabled** — run `systemctl --user enable --now netlisp-guardian-nightly.timer`); CLAUDE.md accurate |
| 5 Opt-ins | `2ec125d` | completeness live on `placement/drc` (8 honest waivers); 80-section exemption ledger is the TODO list |
| 1 Mutation | `5d0d1bd`, `5f79b91` | **first whole-tree score: 28%** (28/100 killed, 72 survivors); gate floored at the measured 28, ratchet in `.guardian/mutation.txt` |
| 1b Survivor campaign (07-09) | `5cfefa6`, `254b685`, `0d5b34e`, `ed39d46` | 50/72 survivors killed (splice-verified), 5 waived equivalent, 16 need harnesses (top: the auth email guard, `serve/auth.zig:1317`); 6 files' dead tests re-wired into the aggregator (+29 revived tests, suite now 897); re-measure on the shifted sample: **32%**, ratchet raised, gate floored at 32. Nightly timer installed + enabled. |

**The 28% is the headline.** 856 tests, and 72 of 100 sampled mutants survive —
concentrated in `placement/optimizer` (12/15), `router` (4/4), `drc` (2/2),
`pour`, `pad_shape`, `pin_roles`, and the render/diagram layer, i.e. exactly the
subsystems whose bugs shipped to users. Parser/writer/ERC/export mutants died —
those tests bite. Standing worklist, in value order:

1. **Kill survivors** (`.guardian/cache/last-mutate.jsonl` has file:line + the
   flipped operator + original line for each): add the assertion a mutant
   slipped past, re-run `zig build mutate-full`, watch the ratchet rise. Raise
   `min_score_pct` as it climbs; target 80.
2. **Enable the nightly timer** so the ratchet is enforced while you sleep.
3. **Author the ~101 missing SPEC bullets** for already-tested behaviors
   (spec baseline names them); `deny_growth` holds the line meanwhile.
4. **Un-exempt completeness sections** as their specs gain category coverage
   (router/optimizer next — their survivor density says boundary bullets are
   overdue).

---

## The short version

| Phase | Action | Effort | Payoff |
|---|---|---|---|
| 0 | Merge the guardian branch; build once; commit the `.guardian/` migration | 15 min | Everything below becomes available |
| 1 | Adopt mutation testing (`[mutation]` config + first ratchet) | ~1 hr | The only gate that measures whether our tests *bite* |
| 2 | Stop the spec-debt bleed (`deny_growth`, selective refresh, `debt`) | 30 min | Frozen spec debt (124 and climbing) stops growing silently |
| 3 | Restore default caps, one knob per PR (ratchets grandfather offenders) | 1 PR/knob | New code gets real limits again; 25 oversized files get personal ceilings |
| 4 | Workflow: `commit --intent`, PR mutate, nightly timer | ~1 hr | Gate timing holes closed; baseline churn becomes attributable |
| 5 | Opt-ins: completeness on router/DRC specs, fakes, waivers | as needed | Boundary-bug pressure where our real bugs live |

---

## Phase 0 — Upgrade and absorb the migration (one sitting)

1. In `../guardian-zig`: merge `claude/gifted-elion-87c139` into `main`.
2. Here: `zig build`. Expect a **one-time migration wave**, all green:
   - The threshold-check baselines (`function-length.txt`, `nesting-depth.txt`,
     `type-size.txt`, `line-length.txt`, …) self-migrate from v1 text to
     **v2 per-item ratchets** — `<value> <key>` lines, e.g.
     `339 src/serve/auth.zig|registerCompletePage`. Message:
     `migrated to per-item ratchet (N key(s))`.
   - Baselines with stale resolved entries **auto-prune** (this replaces the
     old "re-run with GUARDIAN_UPDATE_SNAPSHOT=1 to prune" dance).
   - `.guardian/cache/` gains machine-readable sinks (`last-run.jsonl`,
     `dora.jsonl`) — gitignored, digest-excluded, zero churn.
   - `zig build --help` now lists `mutate` and `mutate-full`: **auto-wired**
     by `addAllChecks`. Delete nothing; the wiring is idempotent.
3. `git add .guardian/ && git commit` the migration in one commit.
4. Optional but recommended while you're here: pin the guardian dep
   (`.url` + `.hash` once guardian tags a release) — our own AUDIT.md flags
   that a fresh clone can't build today.

### Behavior changes that can fire immediately (know before you build)

- **change-classification grew teeth** (this is deliberate — it existed to stop
  test-less fixes and we were routing around it without noticing):
  - Editing SPEC.md **prose** no longer waives the gate; only an added or
    modified `- ` behavior bullet does.
  - A **clean tree** no longer passes vacuously: the gate diffs `HEAD~1..HEAD`
    (skipping merge/root commits). A commit-then-build flow is now gated on
    the commit it just made. The next "quick serve/cache fix" with no test and
    no spec bullet **will go red** — that's the feature. Escape hatch if it
    misfires: `[change_classification] gate_last_commit = false` (don't,
    unless it's actually broken).
- **test-skip-ban** (new, default-on): a test whose body is empty or
  unconditionally `return error.SkipZigTest` fails. We're expected clean;
  if something fires, the test was fake — implement or delete it.
- **Ratchet semantics** replace text-diff for the ten shape checks: touching a
  grandfathered function no longer reds the build when its metric merely
  *changes* — it reds only when the metric **grows** past its recorded
  ceiling, and improvements auto-lower the ceiling. This kills the failure
  mode that drove ~39% of our commits to carry `.guardian/` noise.

---

## Phase 1 — Mutation testing (the point of the whole exercise)

Static checks prove tests exist; `mutate` proves they bite. Our bug history is
~80% behavioral, and most small fixes shipped test-less — this is the gate
aimed at exactly that.

Add to `guardian.toml`:

```toml
[mutation]
min_score_pct = 80   # fail below this kill rate (gated tiers only)
max_mutants   = 100  # deterministic sample cap for --full
timeout_secs  = 300  # per-phase child-build timeout (timeout counts as killed)
min_mutants   = 4    # below this many viable mutants: informational, not gated
```

Then:

1. **Fast tier, on a branch with real changes:** `zig build mutate` —
   mutates only lines changed vs `HEAD` (or `GUARDIAN_AGAINST=origin/main` for
   PR scope). Small diffs (< 4 viable mutants) report survivors without
   failing, so it's safe to run on every PR.
2. **Full tier, once, overnight:** `zig build mutate-full` — whole tree
   sampled to `max_mutants`, writes the kill-score ratchet to
   `.guardian/mutation.txt`. Commit it. From then on the score can never
   silently drop.
   - Expect the first run to take a while (sequential; each mutant is a
     build+test cycle). The **per-mutant result cache**
     (`.guardian/cache/mutants.jsonl`) makes re-runs at the same tree state
     near-instant and lets an interrupted run resume.
3. **Read the survivors.** Each one prints `file:line`, the operator flip, and
   the original source line — a survivor is a line where our suite doesn't
   constrain behavior. Survivors also land in
   `.guardian/cache/last-mutate.jsonl` for tooling.
4. **Equivalent mutants** (e.g. `>` vs `>=` in min/max-style geometry scans —
   we will hit these in DRC/router code): mark the line
   `// mutate-ok: boundary equivalence`. Waivers are counted and reported;
   don't blanket them.

---

## Phase 2 — Stop the spec-debt bleed

Our frozen spec debt grew 82 → 124 violations in the first week of July,
one global `GUARDIAN_UPDATE_SNAPSHOT=1` at a time. Three tools fix this:

1. **Growth denial.** In `guardian.toml`:

   ```toml
   [baseline]
   enabled = true          # (already set)
   deny_growth = ["spec"]  # a refresh may never grow the spec baseline
   ```

   From now on, accepting *any* intended change cannot silently ratify new
   unlinked bullets / untested behaviors — a refresh that would grow `spec`
   fails with `refusing to refresh spec: …`.
2. **Selective refresh.** Stop using `=1`. Accept exactly what you meant:

   ```bash
   GUARDIAN_UPDATE_SNAPSHOT=pub-api-surface zig build   # one check
   GUARDIAN_UPDATE_SNAPSHOT=spec,unsafe-ops-budget zig build  # a list
   ```

   Unknown names hard-fail, so typos can't refresh nothing.
3. **Visibility.** `guardian-check debt .` (or wire `zig build debt`) prints
   per-check frozen counts, ratchet key counts with worst offenders, snapshot
   totals, and the mutation score — with deltas vs the last committed state.
   Run it in weekly review; debt growth becomes a decision, not a side effect.

Also budget an hour to fix the **4 orphan `// spec:` tags** and start burning
the 101 unlinked bullets — `deny_growth` stops the bleeding but doesn't heal.

---

## Phase 3 — Restore the default caps (one knob per PR)

Every cap override in our `guardian.toml` exists because v1 baselines couldn't
hold shape checks (any metric change on a frozen offender went red). Per-item
ratchets fix that mechanism, so the overrides can come out — **new code gets
the strict default; each legacy offender keeps a personal, only-shrinks
ceiling.**

Per knob (one PR each, in roughly this order of value):

| Knob | Today | Restore to | Notes |
|---|---|---|---|
| `max_file_lines` | 10000 | 1000 | The 25 files over the default get ceilings; `placement/optimizer.zig` (~11k) ratchets at its current size and can only shrink |
| `[complexity] max_score` | 45 | 25 | Worst offender `analyze` (power_budget) ratchets at 42 |
| `[function_length] max_lines` | 200 | 120 | ~24 fns in the 150–200 band get ceilings |
| `[function_size] max_params` | 12 | 6 | The toml already says "DO NOT INCREASE — ratchet downward"; this does exactly that |
| `[type_size] max_fields` | 16 | 7 | `Instance` (now 25 fields — the comment's "16" is stale) gets a truthful ceiling |
| `[nesting_depth] max_depth` | 6 | 5 | Depth-6 spatial scans get ceilings |
| `[line_length] max_len` | 160 | 120 | Ratchet value is the count of over-limit lines per file |

Mechanics per PR: delete the override → `zig build` (the check fails listing
the newly-over-default items) → `GUARDIAN_UPDATE_SNAPSHOT=<check> zig build`
to record the ratchet → commit toml + `.guardian/`. Delete the stale
justification comment while you're there. Improvements after that auto-lower;
regressions on any grandfathered item go red naming the exact key.

---

## Phase 4 — Workflow integration

1. **Agent/dev commits:** prefer

   ```bash
   guardian-check commit --intent "fix: stale page cache on star change" .
   ```

   It runs the full gate on the exact working-tree diff, and only on green
   stages an explicit path list (never `git add .`; `.env*`/`*.pem`/key-ish
   paths excluded with a warning) and commits with the intent as the message.
   `.guardian/` and SPEC.md changes ride the same commit — baseline churn
   becomes attributable instead of smeared across 4-in-10 commits. This also
   structurally closes change-classification's diff-timing hole. (Build the
   binary once: `zig build` in `../guardian-zig`, or run it via our zig-out.)
2. **PRs / CI:** `GUARDIAN_AGAINST=origin/main zig build mutate` — mutation on
   exactly the PR's changed lines, small-diff floor keeps it non-flaky.
3. **Nightly:** we already run `systemd/netlisp.service`; add a timer that
   runs `guardian-check nightly .` (= full `all` suite + `mutate --full`
   ratchet) in the repo nightly. Sketch:

   ```ini
   # netlisp-guardian-nightly.timer → .service ExecStart:
   #   guardian-check nightly /path/to/eda
   OnCalendar=*-*-* 03:00
   ```

4. **Telemetry:** every executed `all`/`nightly` run appends to
   `.guardian/cache/dora.jsonl` (branch, commit, outcome, failed checks,
   duration). It's local-only; point `[dora] sink_path` somewhere else if we
   ever want it aggregated. `[dora] enabled = false` turns it off.

---

## Phase 5 — Opt-ins to grow into

1. **Completeness checklist** (our shipped bugs are geometry/boundary/numeric —
   exactly what this forces spec bullets, and therefore tests, for):

   ```toml
   [completeness]
   enabled = true
   exempt_sections = ["<non-feature sections>"]  # start broad, shrink over time
   ```

   Each SPEC.md `##` feature section must then address or explicitly waive 8
   categories (empty inputs, large inputs, unauthorized access, I/O failure,
   concurrent access, malformed encoding, integer overflow, panic-free) —
   waiver syntax: `- completeness-waiver: concurrent access (single-threaded eval)`.
   Recommended rollout: enable with everything exempted, then un-exempt the
   router/DRC/placement sections first.
2. **Deterministic fakes:** guardian now ships a `guardian-fakes` module
   (FakeClock, SeededRandom, FakeFs, FakeEnv) — the test doubles for the ports
   the ban-* checks force. Wire it when we next touch time/fs seams:

   ```zig
   const fakes_mod = guardian_dep.module("guardian-fakes");
   my_tests.root_module.addImport("guardian_fakes", fakes_mod);
   ```

3. **`explain`:** `guardian-check explain <check>` prints why a check blocks,
   how to fix, and how to exempt — point agents at it instead of letting them
   guess (or route around).
4. **Machine-readable runs:** `.guardian/cache/last-run.jsonl` has one record
   per violation (`check`, `file`, `line`, `message`, `fix_hint`,
   `ratchet_key`, `metric`) plus a run summary — useful for editor tooling and
   agent fix loops.

---

## Reference — new commands, flags, env vars

```bash
zig build mutate / mutate-full / debt      # auto-wired build steps
guardian-check nightly .                   # all + mutate --full (CI/cron tier)
guardian-check commit --intent "msg" .     # gate, then safety-railed commit
guardian-check debt .                      # frozen-debt report (non-gating)
guardian-check explain <check>             # rationale / fix / exemption recipe
guardian-check all . --only a,b            # run a subset (never writes green stamp)
guardian-check all . --skip a,b            # run all except (same rule)
guardian-check --version                   # attribute .guardian/ diffs to upgrades
GUARDIAN_UPDATE_SNAPSHOT=<name[,name]>     # selective refresh ("1" = everything)
GUARDIAN_AGAINST=<ref>                     # diff base for change-class + mutate
```

New `guardian.toml` sections we may set: `[mutation] min_mutants`,
`[baseline] deny_growth`, `[change_classification] gate_last_commit`,
`[completeness] enabled/exempt_sections`, `[dora] enabled/sink_path`.

## Gotchas / rollback

- **First test-less fix after upgrade will go red** (change-classification).
  Intended. Add the regression test or the spec bullet; don't reach for
  `gate_last_commit = false` unless the gate itself misbehaves.
- **`deny_growth` will block refreshes that used to "just work"** when new
  spec debt snuck in. Fix the debt; removing the check name from the list is
  the explicit opt-out.
- **Ratchet files change format** (v2 header). Merge conflicts in
  `.guardian/baselines/` resolve by re-running the check with
  `GUARDIAN_UPDATE_SNAPSHOT=<check>` — never by hand-editing values upward.
- **Mutation runs are sequential by design** (parallel sandboxes would break
  our relative `../guardian-zig` path dep). The changed-lines fast tier and
  the result cache are the mitigation; whole-tree runs belong in the nightly.
- Anything can still be turned off: top-level `disabled = ["check-name"]`
  (unknown names fail, so typos can't silently disable nothing).
