# Netlisp Agent Feedback Log

This append-only log captures concrete blockers and development-process ideas
noticed by AI agents while working in this repository. Its purpose is to make
future tasks take fewer turns, tool calls, rebuilds, and retries.

This file is for the netlisp repository itself. Guardian-specific feedback belongs
in `../guardian-zig/FEEDBACK.md` under that repository's own rules.

## What to log

Add an entry when at least one of these is true:

- a blocker prevented completion or required user/external intervention;
- missing or misleading tooling, documentation, diagnostics, fixtures, or
  commands caused avoidable turns, tool calls, rebuilds, or investigation;
- a concrete improvement could remove repeated work from future tasks.

Do not add routine success notes, speculative wish lists, raw command output,
secrets, user data, or generic complaints. Finish the task when possible; this
log is not a substitute for reporting an active blocker to the user.

## How to add an entry

1. Append at the bottom of the Log section. Never edit, reorder, or delete an
   existing entry. If an old item is resolved, append a follow-up entry that
   names the resolving commit or issue.
2. Make the entry self-contained. A reader should understand the task, the
   failing seam or missing capability, what was tried, and the actual cost
   without access to the original agent conversation.
3. Quantify the cost when practical: extra turns, tool calls, full builds,
   retries, or minutes.
4. Make ideas actionable. Name the command, module, diagnostic, fixture, API,
   or documentation section to change and state what repeated work it would
   eliminate.
5. Use only the applicable bullets from the template. One concise entry per
   task is usually enough.

### Entry template

```markdown
## YYYY-MM-DD · <agent> · <task>
- **blocker:** <what prevented progress, evidence, attempts, and what is needed>
- **friction:** <avoidable repeated work and its measured cost>
- **idea:** <specific improvement and the turns/tool calls it should save>
- **workaround:** <best known procedure until the improvement lands>
- **status:** open | mitigated | resolved in <commit/issue>
```

---

## Log

## 2026-08-25 · codex · clickable DRC errors for blocked impedance tapers
- **blocker:** The filesystem was at 100%, and Git could not create the feature-branch ref lock. One old worktree's generated `.zig-cache` occupied 9.9 GB (another cache occupied 88 GB); clearing only the 9.9 GB generated cache restored worktree creation after three diagnostic/tool calls.
- **idea:** Add a documented cache-usage preflight or safe stale-worktree cache cleanup command to the worktree workflow so branch creation and release builds do not first fail on a full volume.
- **workaround:** Run `du -sh .claude/worktrees/*/.zig-cache | sort -hr`, identify an inactive worktree, and delete only files beneath that generated cache.
- **status:** mitigated

## 2026-08-25 · codex · Barracuda RF V2 DRC warning audit
- **friction:** `describe_pcb_layout` serializes the warning kind and named parties but omits topology's internal `track_a` and logical-owner identity. Distinguishing private RF tessellation probes from persisted cleanup candidates therefore required coordinate correlation, source inspection, repeated feature-binary DRC runs, and `clean_route_topology` dry runs; the missing identity also concealed an unsafe physical-index-to-saved-index handoff.
- **idea:** Add a read-only DRC audit/debug surface that reports stable logical copper owner, persisted track ID/index when applicable, implementation owner (RF path/arc), and whether the jointly safe cleanup plan selected the finding. That would make representation artifacts and mutation-index mismatches directly inspectable without exposing these fields in the normal UI payload.
- **status:** open

## 2026-08-26 · codex · manual-route DRC performance deployment
- **friction:** The post-merge hook logged merge `ef495ba` as queued while the previous `a07a7df` deployment was finishing, but the pending marker then disappeared and `.git/deploy-last-hash` remained on the older commit. Confirming the missed deployment and rerunning it required four extra diagnostic/tool calls.
- **idea:** Make the deploy lock holder atomically consume any pending hash after updating `deploy-last-hash`, or have the queuing process retry after lock release, so a merge queued during the final seconds of another deployment cannot be lost.
- **workaround:** Compare `git rev-parse main` with `.git/deploy-last-hash`; if the queue is empty but they differ, run `DEPLOY_RUN_NOW=1 .githooks/deploy-prod.sh` and verify the installed version and health check.
- **status:** open

## 2026-08-26 · codex · Barracuda net-open repair and location markers
- **friction:** `close_open_nets` scoped to seven power nets kept 12 safe `V_3V3D` stitches, then its default vacate phase expanded into repeated full-board Ethernet/USB reroutes and was killed with exit 137 before persisting. A bounded retry with `vacate:false` took about nine minutes but safely saved ten stitches. `netlisp check` also exited successfully while flooding the terminal with `SafeAllocator` leak diagnostics, obscuring its clean verdict.
- **idea:** Persist accepted additive hops before entering vacate, give targeted net diagnosis a strict geometry-only or wall-clock-bounded mode, and suppress allocator diagnostics after a successful CLI check unless explicitly requested.
- **workaround:** Run `close_open_nets` one subsystem at a time with `rounds:1` and `vacate:false`; inspect exact pad endpoints through `describe_pcb_layout`; then use `add_tracks`, whose DRC ratchet rolls back unsafe candidates.
- **status:** open

## 2026-08-26 · codex · primary page-load performance gates
- **friction:** The benchmark intentionally uses the live designs corpus, but that repository changed while the four-page baseline was being recorded. This invalidated comparisons and required repeated roughly 70-second recordings before a stable baseline could be committed.
- **idea:** Record and verify the designs-repository commit and cleanliness alongside the baseline, and fail the recorder early if either changes during a run.
- **workaround:** Confirm `projects/designs` is clean and its HEAD is unchanged immediately before and after recording, then run enforcement once against the resulting baseline.
- **status:** open

## 2026-08-26 · codex · Barracuda perimeter soldermask verification
- **friction:** A Debug `netlisp check --severity error barracuda-base` reached the clean `0 violation(s)` verdict, then continuously emitted more than 700 KB of `SafeAllocator` leak stacks and required an interrupt plus two polling calls to recover the terminal. This independently reproduces the allocator-diagnostic problem already noted by the Barracuda net-open task.
- **idea:** Keep the allocation report bounded or behind an explicit diagnostic flag so successful project checks terminate with their verdict visible.
- **status:** open

## 2026-08-27 · codex · all-pages headless performance gate
- **friction:** The previous browser gates read mutable live ignored layout/model state, while repeated fresh Home contexts abandoned CPU-heavy `/api/layout-progress/*` requests. That combination produced an incomplete workload and two false 15–20 second schematic-startup samples, costing multiple full recordings.
- **idea:** Snapshot and fingerprint committed sources plus ignored layout/model bundles, isolate generated sprites and browser writes, and keep Home progress hydration as an explicit final interaction so every repetition drains its background work.
- **status:** resolved in this change

## 2026-08-27 · codex · revision-locked fabrication release gate
- **friction:** Saved-layout parsing was intentionally best-effort: malformed records and allocation failures could become skipped tracks, zones, text, or fabrication layers without a parse status. Proving a release snapshot lossless therefore required a second raw-JSON validator, explicit raw-to-typed field/count/geometry parity, and separate fallible lowering evidence across several review cycles.
- **idea:** Add a strict `layout_sidecar_store` parse mode that returns the typed selected row and structured completeness errors from the same parse, while keeping the existing compatibility mode for normal viewing. The release gate could consume that one result and eliminate duplicate parsing, parity maintenance, and a substantial portion of `pcb_layout_page.zig`'s near-cap release plumbing.
- **status:** mitigated by `selectedLayoutParsedEvidence` and fail-closed lowering; strict single-pass parsing remains open

## 2026-08-27 · codex · fabrication release full-suite integration
- **friction:** Focused tests and `test-compile` passed, but the exact-candidate `prepare-release` run failed because newly extracted test-bearing modules were imported without being added to `test_shards.zig`; the manifest integrity test existed but only ran in the full suite. This consumed one full release attempt and a new candidate commit.
- **idea:** Make `test-compile` run the shard-manifest coverage and import-bridge checks, or add a cheap pre-release target that runs those two tests before the exact-candidate gate, so a missing shard claim is caught during iteration.
- **status:** mitigated by adding every new module to the shard manifest/import bridge; pipeline preflight remains open

## 2026-08-27 · codex · Assembly retained WebGPU CAM renderer
- **friction:** `scripts/pcb_gpu_check/run.js` has drifted from the shipped renderer: it still requires fence-specific ordering and polygon-pad GPU ownership that current source deliberately removed, producing more than 22,000 false failures when used to validate the new CAM pipelines. The Assembly browser benchmark also defaulted to a nested `projects/designs` path absent from feature worktrees, so a direct run reported a null workload fingerprint until given the shared checkout explicitly.
- **idea:** Replace the fake-GPU string harness with a focused WebGPU validation page that checks device errors and transparent Canvas fallback state, and make `pcb_browser_perf/run.js` resolve the shared designs checkout the same way `scripts/perf_gate.sh` does. This would avoid the stale failure flood and two diagnostic reruns on future renderer work.
- **status:** open

## 2026-08-27 · codex · HTTP(S) component datasheets
- **friction:** This independently repeated the missing-shard failure recorded under “fabrication release full-suite integration”: four focused URL-datasheet tests and `test-compile` were green, but the first 38-second exact-candidate run failed only because the new `serve/api.zig` and `serve/datasheet_ref.zig` tests lacked `test_root.zig` imports and `test_shards.zig` claims.
- **idea:** Make `test-compile` or the ordinary diff-scoped test gate run `test_root.test.shard manifest runs every named test exactly once` and `test_root.test.the shard import bridge lists every module whose tests run` whenever test-bearing Zig files change; two same-day release retries now show this is recurring rather than incidental.
- **status:** open

## 2026-08-27 · codex · zoom-exact Assembly CAM review
- **friction:** Tuning the CAM interaction renderer required four roughly 40-second `scripts/pcb_browser_perf/run.js` runs, and every useful render result still ended red on unrelated cold Gerber generation, 3D navigation, and a changed/dirty live-design baseline.
- **idea:** Add a focused `--only-render` or scenario filter that starts from a warm CAM payload and runs exact-quality, pan, zoom, side, rotate, and layer assertions without 3D navigation or aggregate baseline enforcement. This would preserve the full release gate while cutting iterative renderer measurements to the requested surface.
- **status:** open

## 2026-08-28 · codex · copper-pour fabrication audit
- **friction:** The first exact-candidate CAM-to-readiness audit exposed a pre-existing stale epoll event after a 3.07 MB response; unregistering only the handler-driven close path still missed curl's keepalive peer-close path and required a second real-server replay to locate the shared lifecycle boundary.
- **idea:** Keep socket read-unregistration centralized in `Conn.close` and retain the large-response, half-closed-client regression in the ordinary test suite so every HTTP close path shares the same lifetime rule.
- **status:** resolved in this change

## 2026-08-28 · codex · controlled-impedance Gerber gap audit
- **friction:** Measuring controlled gaps from the exact Gerber bytes of intentionally unready Barracuda layouts required a temporary `fab_preview` raw-byte tap, a temporary build step, one extra binary build, and roughly six patch/build/extract cleanup calls because `/api/pcb-gerbers` correctly refuses an incomplete release while `/api/pcb-cam` exposes only parsed operations.
- **idea:** Add a read-only local CLI that writes deterministic, unstamped Gerber layers for a named saved layout without bypassing or weakening the fabrication-release endpoint; this would make pre-release geometry audits reproducible without a diagnostic source patch.
- **workaround:** Temporarily expose `writeLayer` bytes through the generated-Gerber CAM path, verify native region integrity before encoding them, audit the decoded files, then remove the diagnostic patch before committing.
- **status:** open

## 2026-08-28 · codex · Barracuda editor zoom performance
- **friction:** The all-pages browser gate sent ordinary wheel events that Chromium coalesced before paint, ran the editor at DPR 1, and did not assert the selected renderer. It reported a misleading 16.8 ms frame while Barracuda's swept RF paths silently disabled WebGPU and deterministic DPR-2 paints took 23–42 ms; the pre-push-only gate also was not on the local post-merge deployment path.
- **idea:** Keep one-paint-per-camera-step editor benchmarks and exact-candidate performance certification as reusable release-gate primitives, so high-density fallback latency, renderer activation, workload size, and local deployment eligibility cannot drift apart again.
- **status:** resolved in this change

## 2026-08-28 · codex · dashed generated RF-fence vias
- **friction:** The standing `scripts/pcb_gpu_check/run.js` renderer harness aborted before reaching its WGSL or via-buffer assertions because its fake device has no `createSampler`, now required during renderer initialization. This cost one attempted run plus two diagnostic calls and left the focused static renderer contract as the available inner-loop coverage.
- **idea:** Keep the fake WebGPU surface API-complete for renderer initialization (starting with `createSampler`) or split shader/buffer checks from CAM resource setup, so a semantic-copper change can exercise its actual buffer and WGSL assertions without booting unrelated CAM machinery.
- **status:** open

## 2026-08-28 · codex · sub-circuit copper side flip
- **friction:** The exact-candidate `prepare-release.sh` run passed Guardian, all 1,247 tests, and the ReleaseSafe build, then rejected an editor-only change on one noisy Canvas zoom sample (33.6 ms median versus 30 ms). An immediate isolated rerun against the same stripped binary passed at 25 ms median and 34 ms worst, costing one failed release attempt and about three minutes.
- **idea:** Let the release script retry only the deterministic editor benchmark once against the preserved exact candidate before discarding it, while still requiring both the retry and the other release evidence to be green. This would absorb transient host contention without rerunning compilation and the full suite.
- **status:** open

## 2026-08-28 · claude · DRC hot-path speedups (W0)
- **friction:** Proving that a pure-speedup DRC change emits an identical violation multiset needed a temporary `drc-dump` subcommand plus two extra full binary builds: nothing shipped dumps the violation set. `netlisp check` is schematic ERC, `bench-page` reports only three aggregate DRC counts (total/errors/net_open), and `describe_pcb_layout` summarises rather than enumerating. Aggregate counts cannot distinguish "same number of findings" from "same findings".
- **idea:** Add a read-only `netlisp drc-dump [--project-dir <d>] <design>…` (or a `--dump-drc` flag on `bench-page`) that prints every violation's kind, coordinates, gap, clearance, severity, layer and parties, sorted deterministically. That single command turns any DRC refactor's correctness claim into one diff, and would have saved two builds and roughly six calls here.
- **workaround:** Added the subcommand as an uncommitted patch, built base and patched binaries with it, diffed the sorted dumps over eight corpus boards, then removed it before committing.
- **status:** open

## 2026-08-28 · claude · DRC de-quadratic (copper topology + net-open)
- **friction:** Proving "the emitted violation multiset is unchanged" over the board corpus needed a FULL violation dump, and no surface produces one: `describe_pcb_layout`'s `drc_list` omits `who.track_a` (which decides whether a `dangling_copper` finding is offered to automatic cleanup), and `bench-page` reports only counts. Attributing the cost also needed a phase profile, and `perf` is unusable on this machine (`perf_event_paranoid=4`), so a throwaway `drc-dump` command plus temporary `profNow/profMark` instrumentation in `drc.zig`/`drc_compose.zig` had to be written, built twice (Debug + ReleaseSafe), and stripped again — roughly eight extra build/patch cycles.
- **idea:** Add a small read-only `netlisp drc-dump <design>` that prints every field of every violation from both seams (`drc.check` and `drc_rules.checkFilteredZones`) in a deterministically sorted text form, plus each seam's wall time. It is the natural differential harness for any DRC refactor and would have removed every diagnostic patch here.
- **finding:** The audit premise that `copper_topology` dominates `drc.check` on barracuda-base is no longer true on `48c5573`: geometry DRC there is ~8.2 s ReleaseSafe of which `power_integrity.routedTrackRequiredWidths` (the un-prepared plane raster inside `checkImpl`) is ~7.5 s, while copper topology was ~310 ms. `drc.check` has no `prepared_power` seam, so every geometry-only caller — including the router's candidate loop and the client WASM twin — pays that raster.
- **status:** open

## 2026-08-28 · claude · per-fill copper memo + prepared power surfaces (W2)
- **friction:** The same missing tool was rebuilt for the third consecutive DRC change. Proving that a memo hands back a bit-identical fill needs the whole violation multiset from BOTH seams, plus a way to run one board through an edit twice (warm and cold) in separate processes; nothing shipped could do either, so a throwaway `drc-dump` had to be written, ported onto the base revision by hand, and built into two ReleaseSafe binaries before a single comparison could be made.
- **idea:** `netlisp drc-dump` is now committed, with `--mutate <k>` (a deterministic in-memory copper edit) and `--prime` (a discarded pass over the unmutated board). `drc-dump --mutate k --prime B` vs `drc-dump --mutate k B` in a fresh process is a one-line proof that a memo is sound, and `#`-prefixed timing/reuse lines mean `diff -I '^#'` compares only the findings. The next cache change should not need a patch at all.
- **finding:** Wall-clock on this machine is noisy enough to mislead: repeated identical barracuda reporting-DRC runs spanned 3.4–6.3 s (±30%). Every number in this change is a median of three alternating runs, and single-sample comparisons between two binaries were actively wrong twice before that discipline was adopted.
- **finding:** Two independent whole-board rasters of the SAME user-zone spec were being computed per reporting pass — `drc_compose.filledTopology`'s zone loop and `net_open.zoneFills` build identical `LayerSpec`s over identical copper. Content-keying the fill collapsed them, which is most of why COLD reporting DRC also got faster (barracuda 5951 ms → 3588 ms) rather than only the warm path.
- **status:** resolved in this change

## 2026-08-28 — the reconcile endpoint's cost was never where the DRC work was

Workstream W3 was briefed as "the editor's server reconcile runs a full DRC on
every POST /api/pcb-drc, ~300 ms after edit idle; get it well under 300 ms".
Measured on this tree before touching anything (ReleaseSafe, barracuda): the
endpoint took 7.0-11.4 s, of which 3.5 s was resolving the design and 4.3-5.3 s
was `placeFromPoses` — neither of them DRC at all. The DRC seam itself was
1.8-3.5 s. The 300 ms figure appears to have been carried forward from a
different measurement and set the whole plan's target an order of magnitude off.

Two things would have caught it in one command instead of an afternoon:

1. There is no way to time an ENDPOINT's stages. `bench-page` measures page
   renders; `drc-dump` measures the two DRC seams. Neither sees the handler, so
   "which part of this request is slow" needed a throwaway instrumentation
   patch, three rebuilds, and a scratch file to print into because
   `std.debug.print` from a serve thread does not reach the server log. A
   `netlisp bench-api <endpoint> <design> --body <file>` that posts a recorded
   body and prints per-stage wall time would be the drc-dump of the HTTP layer.

2. Nothing in the repo records what an endpoint currently costs, so a brief can
   quote a stale number and nobody notices. `scripts/perf_gate.sh` gates four
   PAGE latencies; the editor's reconcile — the request a user makes most — is
   not among them.

Also worth writing down, because it cost real time: `fill_cache`'s per-fill memo
hands back a BORROW, and a caller that retains the `pour.Fill` value across
requests keeps a pointer nothing is holding. The fix is to retain the memo KEY
and ask again (`pour.computeMemoKeyed`), which takes a proper reference or
misses and pours. The module header states the borrow rule for the whole-board
entry; it now also matters for anything that keeps a fill between passes, and
that is not obvious from the type — a `Fill` looks like a value.

## 2026-08-28 — no fixture exercised the deferred DRC kinds, and the forms that create one are top-level

W4 (the background full-board DRC sweep) exists mainly to refresh the three
kinds a scoped recheck defers — `reference_plane_gap`, `reference_transition`,
`loop_area` — so its first test had to be a board that actually emits one. No
committed fixture did. Every server-side reconcile fixture and every
`drc_return_path` test builds its placement in Zig, so the only worked examples
of the DSL that produces those findings are in `docs/language-forms.md`, in a
single table row several thousand characters long.

Two concrete costs, both avoidable:

1. `(stackup …)` and `(net-class …)` are TOP-LEVEL `design-block` forms, not
   `(design-rules …)` children. The existing reconcile fixture nested
   `(stackup 4) (plane 2 "GND")` inside `(design-rules …)`, where it is ignored
   — the board had no declared stackup at all, and `drc_return_path.check`
   returns immediately without one. The evaluator does warn, but the endpoint
   test harness discards evaluator warnings, so the fixture read as fine for as
   long as nothing depended on the stackup. A fixture that silently loses half
   its declarations is worse than one that fails.

2. Finding this took a placement dump printed from inside a test. There is no
   cheap way to ask "what did the evaluator actually make of this design's
   rules" — `netlisp check` is schematic ERC and `describe_pcb_layout`
   summarises geometry. A `netlisp describe-rules <design>` printing the
   resolved stackup, planes and per-net class rules would have answered it in
   one command.

Worth keeping in mind for the next task in this area: the reconcile fixture in
`src/drc_reconcile.zig` now declares a real 4-layer stackup and a
`(return-path (max-loop-area …))` net class, so it emits three
`reference_plane_gap` findings and one `loop_area`. It is the cheapest worked
example of those forms in the tree.
