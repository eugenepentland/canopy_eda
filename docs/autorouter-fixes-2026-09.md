# Autorouter audit fixes — 2026-09-05

The fixes improve routing safety and inspection correctness. They do not yet
increase fresh Barracuda completion: the controlled hierarchical benchmark
remains **120/130 with zero geometry DRC errors**, about 210 seconds. Standalone
`straps-synth-lmx2595` remains **26/27**, with `LMX_VBIASVCO2` open.

## Changes

- Cancelled `route_pcb` calls preserve the saved layout byte-for-byte. Top-level
  metrics describe retained copper; `candidate` describes the attempted result,
  and `applied`, `cancelled`, and `validation_complete` make the distinction
  explicit. Connectivity counters include physical arcs, RF paths and pours,
  including after a scoped merge or cancellation.
- `route_experiment` uses the commit path's local-to-global builder, waypoint
  seeding, shown pours and perimeter copper. Diagnostics are collected after
  routing and finishing, over the final candidate. Local-phase statistics are
  returned. Placement-repair trials also include pours in their DRC checks.
- A child with no authored PCB plan receives standalone defaults for its local
  pass, while the parent may narrow hard layer and via limits. It previously
  inherited global waypoints and wave order. A regression fixture demonstrates
  that an external board waypoint changes the local route before the fix but
  cannot change it afterward.
- Guides support explicit stable `scope/@origin` bindings. Bare ambiguous
  aliases warn instead of choosing the first matching part.
- `diagnose_net` inspects shown saved copper rather than rerouting. It returns
  the requested net's terminal islands, gap endpoints and relevant DRC witnesses
  without the whole-board diagnostic cap. Gap lines are not legal-route proofs.
- Rejected `add_tracks` requests report zero applied objects and retained-board
  metrics, with attempted metrics and DRC IDs/coordinates under `candidate`.
- Route-order search ranks geometry errors before connectivity, then geometry
  cost. The scalar score remains a display tradeoff and is documented as such.
  The invalid blocker-demotion `(nets ...) (rest)` remedy is replaced with an
  instruction to move the existing owning wave while preserving its policies.

## Measurements

Frozen baseline: tool source `d4447199`, design library base `45fa4603` plus the
same two pre-existing library edits captured in the audit snapshot. Both
executables use the pinned production-class self-hosted ReleaseSafe compiler.
Benchmarks omit saved whole-board traces/vias, retain shown pours, and permit
validated saved-module fallback. This is not a reference-free completion claim.
`bench-route` measures the hierarchical route before the commit/experiment
surfaces' perimeter addition; the before/after benchmark uses this same scope.

| Run | Barracuda | Geometry errors | Router time |
| --- | --- | --- | --- |
| Baseline | 120/130 | 0 | 209.99 s |
| Workflow fixes, original DSL | 120/130 | 0 | 209.52 s |
| Also fix default child policies, original DSL | 120/130 | 0 | 213.17 s |
| Final engine and conservative DSL cleanup | 120/130 | 0 | 210.59 s |

Rebinding all obsolete guide endpoints and activating the shadowed escape waves
produced 118/130. Correcting the SPI branch geometry and preserving the old loop
wave ownership also produced 118/130. These variants were rejected. The final
DSL cleanup instead removes unresolved guides, the invalid three-limb clock
tree, and the already-shadowed CPOUT/LF_OUT waves while preserving effective
ownership, layer restrictions, via limits and RF constraints. It removes the
12 stale-reference/branch-count warnings. Two existing reserved-layer warnings
remain for reference routing on In2.Cu; no ground copper was removed to silence
them.

The controlled before/after benchmark retains the same ten open nets: GND,
IF1_DSA, LOCK_DET, SPI_ADF_CSN, SPI_DSA_CSN, SPI_SCK, TXDATA_ADF, V_5VA,
adf4159/RSET_ADF and adf4159/SPI_ADF_CSN_1V8. Single-run timing differences here
are not evidence of a speedup.

The real one-second Barracuda timeout repro now reports `applied:false`,
`cancelled:true`, retained connectivity **130/130**, and candidate connectivity
**34/130**. The saved-layout SHA-256 is unchanged. The prior behavior replaced
that complete layout with the partial candidate and reported raw attempt
counts instead. `diagnose_net` on saved SPI_SCK takes 7.03 seconds in the measured
run and returns the saved 78.373 mm, five-via connection without routing.

The final `route_experiment` independently reports **120/130**, zero geometry
errors, `cancelled:false`, all ten open nets diagnosed, and the same open-net
set as the benchmark. Its local-phase report records 19 modules attempted,
18 local timeouts and 52 accepted seed nets. Local time allocation and the
remaining routing failures still need improvement.

## Verification and evidence

Focused regression runs cover cancellation, exact sidecar preservation, scoped
connectivity, manual-edit rejection, saved-copper inspection, stable guide
binding, default child policies, diagnostic/ordinary geometry parity, experiment
parsing and pours, remedy generation, and route-order ranking. The repository's
full release gate is required before integration.

The machine-readable comparison, binary hashes, input hashes, timeout response,
and all routing logs are in `/tmp/autorouter-fixes-20260905/comparison.json` and
its sibling files. Frozen original inputs are under
`/tmp/autorouter-completion-audit-20260905/project`; the accepted plan is under
`/tmp/autorouter-fixes-20260905/clean-plan-project`.

Candidate persistence/adoption by artifact ID, strict no-reference routing,
layer-isolated inspection images and critical-net acceptance profiles remain
separate work. These fixes do not establish fabrication readiness or a fully
autorouted Barracuda.
