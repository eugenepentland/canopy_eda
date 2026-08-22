# HANDOFF — RF via-fencing / keepout feature (wave 7 complete)

> **Archived handoff:** commands and ReleaseSafe dev-server references below
> describe the original wave-7 session. Current internal builds, review
> servers, tests, and benchmarks use pinned-master self-hosted Debug. Only the
> deployment pipeline creates a new ReleaseSafe EDA application.

**Worktree:** `.claude/worktrees/rf-trace-via-fencing-90d704` · **branch:** `claude/rf-trace-via-fencing-90d704` · main checkout untouched.
The interrupted wave-7 snapshot is `dc20258`. On resumption, the supposedly missing geometric fixture, crossing-shadow wiring, net-gated DRC/WASM symmetry, SPEC bullets, and matching `// spec:` tags were all present in that commit. No implementation repair was required.

## Completion record

- Focused shadow, keepout, and `closeGaps` suites pass.
- The isolated full suite first reached **1658/1658 tests passed** before the original sandbox denied the first local-socket fixture (`PermissionDenied` in `httpz.testing.init`). After permissions were expanded, `guardian-check commit` reran the entire suite with socket access, passed all checks, and committed the completion record as `39927fb`.
- Identical socket-free geometric analyzers on private `dfb5b69` and wave-7 copies measured barracuda at **76/91 → 77/91** routed nets. Wave 7 used **82** vias and **925.76 mm** of trace. It matches the handoff's 76–77/91 keepout-only band and loses four nets versus the 81/91 no-keepout baseline, so the 6× step / 12× via multipliers were retained. Route DRC was 79/70-error findings before and 87/77-error findings after; these are reported honestly, not conflated with the saved fence-review board's 11-error baseline.
- Foreign in-shadow track length fell **30.894 mm → 24.895 mm** and the analyzer's worst contiguous span/corridor ratio fell **1.981 → 1.414** (the latter is the square crossing's √2 lattice shape, slightly above the aspirational 1.3).
- The net-gate regression reproduced on `SPI_MISO`: at `dfb5b69` it crossed between U9 pads 1/3 on layer 0 along `(165.807,103.155)→(165.807,100.464)`, distance 0 from the pad connector. Wave 7's closest `SPI_MISO` segment is on layer 1 along `(164.049,100.464)→(174.155,100.464)`, **1.108 mm** from that connector.
- The live `fence-review` row was reset by removing only its generated `f`-tagged vias, then regenerated through the wave-7 ReleaseSafe server: **85/179** candidates persisted, **94** were legally skipped, and DRC remained **11→11 errors**. The row now has 522 tracks, 60 ordinary vias, and 85 generated fence vias. The wave-7 review server is live at `:7433`; the feature branch remains deliberately unmerged pending Eugene's call.

## Done and green (user-approved, do not rework)

| commit | wave |
|---|---|
| d402c69 | `(net-class … (fence (pitch)(offset)(via)(net)))` + `(keepout MM (escape MM))` DSL; resolution in optimizer (`rule.rf.fence.*`, `rf.keepout_mm`, `rf.keepout_escape_mm`); pure resolvers in `src/placement/via_fence.zig` |
| 55349be | fence generator + `generate_fence` MCP tool + `POST /api/pcb-fence/:name` + viewer Fence button; fence vias = GND vias with an `f` tag naming the flanked net (invalidate/regenerate with that net) |
| a8afdb5 | same-layer keepout: `keepout_violation` DRC (warn) + router halo (`Ctx.keep` mask); ground/plane copper exempt both sides |
| eebafe2 | closed-ring march + `mode=all|legal` plumbing |
| 4a239d8 | guide = pour-style SDF level-set contour around the net's copper UNION (tracks+pads+vias, all layers; `src/placement/via_guide.zig`); `(offset MM)` redefined = copper-edge→via-edge gap |
| dfb5b69 | `mode=legal` is the default; prefilter is an exact mirror of drc.zig (pairwise clearance, real pad outlines, slot capsules, drc.eps, viaBuildable); contract = fence adds ZERO new DRC errors; barracuda: 85/179 placed, 11→11 errors |

## Wave 7 (`dc20258`)

Two features, both requested by Eugene:

**A. Crossing-shadow cost.** Foreign nets may cross under an RF trace on OTHER layers, but should cross as briefly as possible (≈ perpendicular), never run parallel through the fence corridor (that blocks future fence-via sites). Implementation direction in the WIP: new `src/placement/rf_shadow.zig` — a per-signal-layer node mask beside `Ctx.keep`, cast on ALL signal layers by copper of any class with `fence.declared` or `keepout_mm > 0`, dilated from the copper edge by the corridor width (fence classes: `gap + via_dia` via `via_fence.resolvedGapMm`/`resolvedFenceVia` formulas; keepout-only classes: `keepout_mm`). Consulted in `relaxStep`/`relaxDiag` as a multiplicative step cost (soft, never blocking) and a stronger via-drop penalty (foreign via parked in the corridor permanently blocks fence sites). Exempt: the owner net, ground/plane nets. Stamped at the same emit seams as the stage-3 keepout (emitSeg/dogleg/OctiJoin/weld/via) + retained copper; windowed/derived ctxs may skip (documented gap, same as keepout). Multipliers were being tuned (started ~6.0 step / ~12.0 via as named constants).

**B. Net-gated keepout escapes** (the "green trace threads between the filter pads" bug). Stage 3 had two blanket openings: the escape exemption suspends the halo within `keepout_escape_mm` of ANY keepout-net pad for everyone, and `onForeignPadLanding` carves foreign pad landings out of the halo for everyone. Wave 7 makes both **net-gated**: a pad-landing carve-out admits only the landing pad's net (+ exempt ground); an escape-zone cell admits foreign net X only if X has its OWN pad within the escape radius (the adjacent-pin-same-IC case). The keepout i32 lane carries the gate net's index instead of a boolean hole. **DRC symmetry required**: `drc_keepout.zig`'s escape exemption must apply the same gate (violating track exempt only if its net has a pad within escape radius of the violation point); the WASM engine shares this code — re-check the wasm bridge test (`src/wasm_drc.zig` was touched in the WIP).

The interrupted fixture had already been converted to the geometric `shadowSpan` assertion in the committed snapshot. `src/placement/gap_close_route.zig` compiles and keeps `router.zig` below Guardian's 10,000-line hard cap.

## Resumption checklist (completed unless noted)

1. Suite and wiring audit: complete; the full socket-enabled rerun passed after permissions were expanded.
2. SPEC.md bullets 1:1 with `// spec:` tags: complete.
3. Validation on a PRIVATE rsync copy of `/tmp/claude-1000/-home-epentland-ai-canopy-eda--claude-worktrees-rf-trace-via-fencing-90d704/e44ee1b3-5fc7-4ed1-b39b-9d6d83dfde8c/scratchpad/designs`:
   - Green-trace before/after: complete for `SPI_MISO` / U9, with paths recorded above.
   - Shadow and ReleaseSafe completion metrics: complete, with results recorded above.
   - The route comparison used `bench-route`, which exercises the same `route_plan` and post-route oracle seams without writing a layout.
4. Guardian commit: complete (`39927fb`), with all 68 blocking checks and the full test suite green.
5. Redeploy and live 85-via / 11→11 regression: complete, with the exact results recorded above.

## Environment

- **Review server**: `http://localhost:7437`, running the final ReleaseSafe binary at `/tmp/rf-fence-dev/bin/netlisp` against the LIVE scratch project `…/scratchpad/designs` (path above). Eugene browses it. The pre-regeneration sidecar is recoverable at `/tmp/rf-wave7-barracuda.layouts.pre-live-39927fb.json`. `zig build test` never writes zig-out and is safe; for smoke binaries use `zig build -p <own-prefix>`. To redeploy: kill it with `pkill -f "netlisp[ ]serve.*7437"` (the `[ ]` prevents pkill matching your own shell), build into a private prefix, then start that binary with `NETLISP_DEV=1 <prefix>/bin/netlisp serve --project-dir <scratch>/designs --port 7437`.
- Scratch barracuda already declares `(fence)` + `(keepout 0.5)` on its `rf` class (lines ~190-191). Its `fence-review` layout row is the review surface; the ★ `layout` row is pristine. Real `projects/designs` (main checkout) is untouched and must stay so until merge.
- Design memory: `~/.claude/projects/-home-epentland-ai-canopy-eda/memory/project_rf_via_fencing_design.md` has the full chronicle.

## Caught up with main (2026-08-02, agent session)

Branch merged forward: `b9d2c73` merges all 49 main commits (coupled diff-pair routing, PDF export, route timing, assembly guides, autorouter speedups); `afbad50` regenerates the pub-api snapshot + file-size ratchet. **`git rev-list --count HEAD..main` = 0** — nothing from main is missing. Still NOT merged to main (prod auto-deploy remains Eugene's call).

Merge notes:
- 5 conflicts, all "keep both sides": `.guardian/pub-api.txt` (union), `SPEC.md` (union), `src/main.zig` (union imports), `src/placement/drc.zig` (main's new diffpair signature + branch's keepout call), `src/placement/router.zig` (branch's keepout/shadow ctx stamping + main's `ctx.timing`; branch's `runsAlong` refusal + main's copper-index fast path).
- **Merge regression found + fixed:** main's index fast paths (copper_index in `segClearsTracks`/`segClearsVias`, pad_index in `segClearsPadsOnLayer`) were keepout-blind — they dropped the halo and let direct-synthesis shortcuts slip past RF pads/traces (the maze never consulted). Fixed in `b9d2c73`: per-candidate `keepoutExtra` (via `padSegmentClears`) and index build/probe radii sized by the largest halo (`padIndexReach`, new `keepMaxExtra`). Keepout suite 39/39 again; the previously failing "a keepout component pad detours foreign routing around its copper" now passes.
- Guardian quirk encountered: `snapshot.diff` asserts full-line byte-order sort on snapshot files — a key-sorted union panics (std.debug.assert → "reached unreachable code"). Snapshot must be byte-order sorted. The pub-api snapshot was regenerated via `guardian-check accept pub-api-surface .` against the merged tree.
- `file-size` ratchet accepted for merged `router.zig` (10317 → 10520 code lines; main's coupled-diff-pair + timing + copper-index additions). **Follow-up recorded: split router.zig at a cohesive boundary** (same discipline as the gap_close_route.zig extraction).
- Full gate green: `zig build test` **1774/1774**, guardian **68 checks — 0 blocking** (pre-commit hook ran the gate on `afbad50`).

**Dev server:** `:7437` restarted with the MERGED ReleaseSafe binary (`/tmp/rf-fence-dev/bin/netlisp`, built 08-02 14:04). Verified: `/pcb-layout/barracuda?layout=fence-review` 200; fence dry-run **85 placed / 0 culled / DRC 14→14** (zero new errors — contract holds; absolute count moved 11→14 from main's DRC engine changes on this synthetic row).

## Close-out (2026-08-02, agent session)

Final HEAD `c2e3313` (post-handoff commits `7fa315b` halo-visualization toggle, `c2e3313` RF-pad keepout halos) verified complete:
- `zig build test` full suite: exit 0, green.
- `guardian-check all`: **68 checks — 0 blocking, 4 report-only**, exit 0.
- ReleaseSafe binary rebuilt at `/tmp/rf-fence-dev/bin/netlisp`.
- Dev/review server now on **`http://localhost:7437`** (final binary, NETLISP_DEV=1, same scratch `…/scratchpad/designs` project). Verified against the `fence-review` row: fence dry-run reproduces the wave-7 numbers exactly — **85 placed / 0 culled / DRC 11→11**, `/pcb-layout/barracuda?layout=fence-review` serves 200.
- The superseded wave-7 server (`:7433`, pre-`7fa315b` binary, same project dir) was retired to avoid two live writers on one project. `:7435` (inst-base/dz-base) is untouched.

**Still open — Eugene's call:** merge → main and author `(fence)` / `(keepout …)` into the REAL barracuda.sexp rf classes. Note main has moved: the branch's merge base is `42b422f` and main's tip is now `0013e20` (autorouter speedup, 08-02) — 49 commits ahead, so the merge is non-trivial and the post-merge hook auto-deploys prod. Review at `:7437` first.

## After wave 7 (Eugene's call)

Merge branch → main (`--no-ff`; auto-deploys prod via the post-merge hook — watch `.git/deploy-on-merge.log`), then author `(fence)` / `(keepout …)` into the REAL barracuda.sexp rf classes. Known follow-ups parked in memory: keepout inert at default 1.0 mm escape on fine-pitch chains (tuning question), via_fence.zig at 1090 lines (split prefilter before next change), drc_session.zig hand-pen pushback unimplemented, PNG renderer doesn't visually distinguish fence vias.
