# Router benchmark ledger

The durable regression gate for the autorouter (`docs/autorouter-audit-round-two.md`
§3a). It makes "the router got better" a **checkable, non-regressing claim** —
a CI command that fails the build when a router change costs a net.

## How it works

`netlisp bench-route --baseline <file>` routes the corpus at every design's
blessed placement, compares each SCORABLE board against a committed
`--json` baseline, and **exits non-zero** on either:

1. **Hard rule** — any scorable board loses more than one net
   (`baseline_routed − current_routed > 1`), or
2. **Soft rule** — the geomean completion over the shared board set drops.

The gate recomputes *both* sides from the baseline's own board rows (using the
current `total` as the shared denominator), so a drifted board set or netlist
edit cannot smuggle a change in through a stale headline number.

## Recording a baseline

Baselines are machine/placement-specific routing counts, not portable numbers,
so they are recorded from a real run, not fabricated:

```sh
# Full corpus (slow — minutes on the scored boards). Point --project-dir at a
# checkout that has the designs (projects/designs is its own nested repo).
netlisp bench-route --project-dir projects/designs --json > bench/baseline.json
```

Then gate CI / the commit hook on:

```sh
netlisp bench-route --project-dir projects/designs --baseline bench/baseline.json
```

## Notes

- **Read-only.** `bench-route` never writes a layout sidecar, so it is safe to
  point at a served project dir.
- **Unscored boards** (no saved/blessed placement) are reported but kept out of
  the score — a fallback-placement route is not a routing measurement. Blessing
  more boards widens the scored sample (the largest lever on the corpus's power).
- **Timing is not part of the gate.** `wall_ms` varies by machine; the gate
  compares `routed`/`total`/geomean only.
- A **newly-scored board** absent from the baseline is reported as `unlined`
  (a note, not a failure) so it cannot silently enter the score.
- A missing/corrupt baseline is a **failure** (never a silent pass).

## Implementation

- `src/bench_route.zig` — `--baseline <file>` arg, `loadBaseline`,
  `checkBaseline`, `writeBaselineReport`; the gate failures return
  `error.BaselineRegression`.
- `src/placement/route_determinism.zig` — routing the same placement twice is
  byte-identical (determinism regression, §3f).
- Specs live under the `## bench-route` and `## placement/router` sections of
  `SPEC.md`.
