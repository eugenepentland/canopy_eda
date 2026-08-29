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

## Profiling a hot path with no profiler

`perf_event_paranoid` is 4 on this machine and the agent account cannot lower
it, so `perf record` fails outright ("Failure to open any events"). Every
attribution in the incremental-DRC headroom work therefore had to come from
hand-placed timers, and the cost of that showed up twice.

First, it made the WRONG suspects expensive to rule out. The W3 report
attributed the residual scoped-reconcile time to `drc_pour`'s per-pass rebuild
(~300–400 ms) and to the Tarjan pass inside `copper_topology`. Both were wrong,
and each took a build-measure-rebuild cycle of its own to disprove: on an
identical repost `drc_pour` costs 44 ms of a 518 ms pass, and the two redundancy
analyses spend 0.2 ms in Tarjan and 40 ms each in the graph BUILD. The actual
hot spot was one predicate three call sites below any of that
(`copper_contact.directedTrackContact`, 56 ternary iterations = 224 segment
distances per same-net track pair, ~9 µs a call, several thousand calls a pass).
A five-minute sampling profile would have named it immediately.

Second, the scaffolding is not reusable. The timers went into `drc_scope.zig`,
`drc.zig`, `drc_pour.zig`, `drc_compose.zig` and `copper_topology.zig`, had to
be guarded for the freestanding `drc.wasm` build (no `std.time.nanoTimestamp`),
and were then stripped again — the same throwaway-patch cycle `drc-dump`'s own
header records for three previous DRC refactors.

Two things that would have paid for themselves:

1. A standing `NETLISP_PROFILE=1` stage-timer seam on the reporting DRC
   composition (`drc_compose`'s five stages plus `checkImpl`'s dozen), printed
   on exit. The stages are stable and already named in the code; the whole
   patch was about 60 lines and is worth keeping rather than re-deriving.
2. `netlisp drc-dump --bench <reps>` is now committed and is the cheap half of
   this: it primes a session and times the SCOPED seam alone over a drag, an
   identical repost and a via drag, with no cold full pass beside it. Reach for
   it before adding timers — an identical repost is the whole fixed cost of a
   reconcile, isolated, and it is one command.

Also worth knowing: this box runs several agents at once and wall times swing
2-3x between rounds. Any before/after claim needs alternating old/new runs and a
median of several, never one run of each.

## 2026-08-28 — the pour's cost was two quadratics, not the raster

Task: make a fill an edit changed cheap to UPDATE instead of re-pouring
(sub-window re-raster from the previous generation's margin field).

The premise held — the update works and is bit-identical — but the premise
about WHERE the time went did not, and finding that out cost most of the task.
A changed barracuda fill cost ~230 ms, and the obstacle walk the whole
sub-window design targets was 17 ms of it. Contour tracing was ~200 ms, in two
places that had nothing to do with the raster:

  * `collectBoundaryEdges` scanned the whole label grid once PER COMPONENT
    (O(components x cells));
  * `tracedComponentValid` compared every pair of a component's holes point by
    point with no bounding-box filter (O(holes^2 x points^2)) — 4.5 s of a 5 s
    pass on a pour with a few hundred via antipads.

Both are three-line fixes and both are pure speedups. The sub-window update is
worth ~27 ms of the remaining ~67 ms; the two quadratics were worth ~165 ms.

What would have saved the detour: **`netlisp drc-dump` reports per-seam wall
time but nothing below it.** Every phase number in this task came from hand-
patching `clock.nanoTimestamp()` counters into `pour.computeFill`, building,
reading, and stripping them again — four rebuild cycles, and the counters could
not live in `pour.zig` permanently because that file is compiled into the
wasm32 DRC engine, which has no clock (importing `infra/clock.zig` there fails
the build outright). A `--phases` flag on `drc-dump`, or a per-phase tally on
the `fill_cache` side of the seam where a clock is already available, would
have made "which part of a pour is expensive" a one-command question. This
change adds the coarse half of that (`# <board> build patched=N ms=… poured=N
ms=…`); the phase split inside a single build is still hand-instrumented.

Second, smaller: the machine ran at load average ~10 throughout (parallel
agents), and the same binary on the same board measured 3.3 s and 6.7 s for the
same phase within minutes. Any timing claim from a session like this needs
alternating medians against a baseline binary built from the same tree, not
absolute numbers — worth stating in the task brief rather than discovering.

## 2026-08-28 · claude · two open wasm/server DRC width divergences on power boards

Investigating whether the client wasm DRC pays the plane raster (it does not —
`wasm_drc.zig` marshals no rail current, so `needs_surfaces` is false there;
now pinned by a test) surfaced two pre-existing items worth recording. Neither
is fixed here.

1. `scripts/drc_wasm_parity.mjs` reports a phantom divergence on any board with
   a current-aware power net. It compares the wasm result against the server
   after applying only `PCB.drc_kinds` overrides (`applyOverrides`), but the
   viewer additionally filters the wasm list through
   `pcb_board.js drcGateDefersPowerWidth` before showing or gating anything.
   Run against `barracuda-base` the harness would flag ~103 findings of
   "drift" that no user ever sees: 99 `track width` on `V_3V3D` at its
   `power-branch-width`, 2 on `V_12V`, and 2 server-only `power width` warns.
   The script is wired into no gate today; it must learn that filter before it
   becomes one, or it will fail on its first real power board.

2. A rail with a declared current but NO `power-branch-width` produces
   transient false errors in the fast tier. On `barracuda-base`, `V_12V` (class
   `base-input-power`, width 0.400 mm) has two 0.127 mm segments. The server
   aggregates them into one advisory `power width` WARNING; the wasm, having no
   rail model, reports them as `track width` ERRORS against the 0.400 mm class
   width, and `drcGateDefersPowerWidth` does not suppress them because the
   class declares no branch floor to compare against. The user sees two errors
   for ~300 ms after every edit until the reconcile replaces them. Related:
   `applyWasmDrc` carries only `net open` rows across a wasm refresh, so every
   other server-only kind (`power width`, `reference_plane_gap`, `loop_area`,
   `bypass_open`) is torn down and recreated on each edit too.

Reproduction for both, no server needed: `netlisp drc-dump <board>` prints the
server's geometry seam; the wasm's answer is the same seam over a placement
with `rules.physical.rails` emptied.

## 2026-08-28 · claude · "the server takes ten seconds to come up" was never about the boot

A restart on this corpus looked like a nine-second outage, and there was
nothing in the process's own output to say whether the gap was in front of the
socket or behind it. It took an external probe (connect-poll separated from the
first HTTP request) to establish that `netlisp serve` accepts its first
connection **5 ms** after exec and that the whole nine seconds belonged to the
first `GET /api/designs`. Two things would have answered that in one command:

1. **A startup line with a number.** The banner said `Listening on
   http://localhost:PORT` with no elapsed time, so it was consistent with both
   stories. This branch adds `[I] startup: listening after N ms`, plus a
   `warmup: N design summary(s) ready in M ms` line for the one warm-up phase a
   request can actually be blocked on. Any future "the deploy is slow" question
   is now one `journalctl` grep.

2. **Beware `boot_to_ready_ms` from a polling harness.** The shared interaction
   benchmark polls `/api/designs` with a 3 s per-attempt abort, so its
   "boot to ready" was pinned at 9088 ms across every run — three aborted
   attempts plus change. That is a quantized artifact of the retry interval, not
   a measurement of anything: the true single-request cold cost was 8.3 s, and
   each aborted attempt left a *whole additional* corpus scan running server-side
   (nothing single-flighted them), so the harness was partly measuring its own
   retries. Measure a cold endpoint with one request and a generous timeout, and
   treat any figure that repeats to the millisecond across runs as suspect.

Also worth knowing for the next perf task here: with five agent sessions live,
`scripts/gate.sh` queued a timing run for ~50 minutes behind four other holders.
Batching every measurement that needs the lock into ONE script (parity check,
health probe, boot probes, and both benchmark reps) turned four queue waits into
one. `gate.sh` reporting the current queue depth when it blocks would make that
choice obvious instead of learned.

## 2026-08-29 · claude · fab-package fail-fast + a perf baseline that cannot be re-recorded

- **blocker:** `scripts/perf_gate.sh --record` cannot currently restore a
  passing gate, so the re-record it exists for is not a mechanical operation.
  `--record` deliberately carries the previous file's `budgets` object forward
  (`if (previous.budgets) recorded.budgets = previous.budgets`), and those
  hand-set absolute budgets — `page_ms` 1000, `assembly_page_ms` 150,
  `thermal_page_ms` 2250, `schematic_page_ms` 500 — are now blown 5-10x by the
  barracuda family: measured on a quiet machine, `barracuda` page 5.67 s /
  thermal 6.41 s and `barracuda-base` page 8.85 s / thermal 10.96 s. Recording
  medians cannot clear a budget violation, so the recorded baseline is followed
  immediately by `result: FAIL — page latency regression`. Someone has to
  decide whether the budget or the page is wrong; a re-recording agent cannot.
- **blocker:** the same re-record would silently absorb a corpus change, which
  is precisely what the DRC-count rule exists to stop. Against the committed
  baseline, `barracuda-base` moved `parts` 203 -> 231, `drc_total` 582 -> 727,
  `drc_errors` 33 -> 61; `barracuda` moved `drc_total` 441 -> 450, `net_open`
  11 -> 2 and its sidecar 650 KB -> 1.04 MB; and four boards in the baseline
  (`black-canyon`, `cyclops-interposer`, `rf-switch-eval`, `straps`) are no
  longer measured at all. Those come from `projects/designs` moving (the base
  IF-LNA work through d9484d1), not from any tool change. **The baseline file
  records no designs commit.** `perf_gate.sh` already computes
  `NETLISP_PERF_DESIGNS_FINGERPRINT` (designs commit + model/layout/BOM bundle
  hashes) and exports it — writing it INTO `baseline.json` and printing
  "recorded against designs X, comparing against designs Y" would turn a
  half-hour forensic diff into one line, and would let the gate say "the
  workload changed" instead of "latency regressed".
- **friction:** timing runs taken under `scripts/gate.sh` are still corrupted by
  sibling sessions that benchmark outside it. Three separate gate-locked
  measurements here overlapped a concurrent `scripts/pcb_editor_perf/hb_when.js`
  and a 100%-CPU test shard from other worktrees. Cost: one full
  `perf_gate.sh --record` (~20 min) aborted in `pcb_browser_perf` run 2/3 on a
  `page.waitForLoadState("networkidle")` 30 s timeout, leaving the pcb-browser /
  pcb-editor / ui-browser baselines unwritten; and one bench-page pass came out
  17-72% slower than its neighbours on the big boards (barracuda `solve_ms`
  4.72 s / 4.84 s / 8.10 s across three runs of one binary, while `labstation`
  held 86.0 / 85.4 / 87.1 ms). Two fixes worth having: put the browser runners
  behind the same lock the page half already takes (`hb_when.js` and
  `pcb_editor_perf/run.js` take none), and have `bench-page` refuse or flag a
  run whose 1-minute load average moved by more than a set fraction, so a
  contended measurement is labelled rather than recorded.
- **idea:** `serve/request_log.zig`'s `StageTimer` paid for itself immediately.
  The question "which second of this 15-second request is which" had no answer
  without it; three laps in `pcbGerbersApiHooked` located 4.5 s in
  `fab_identity.build` and 1.1 s in a lock the request had already disqualified
  itself from. Every handler that can exceed a second is worth one `defer
  emitStages` — it is ~8 lines and removes a build-instrument-rebuild cycle per
  investigation.

## 2026-08-29 · claude · designs identity stamped into the perf baselines

- **workaround:** implemented the entry above's idea. `scripts/perf_gate.sh
  --record` now stamps `NETLISP_PERF_DESIGNS_COMMIT`/`_FINGERPRINT` into
  `docs/benchmarks/pcb-page/baseline.json` (via
  `scripts/perf_gate_designs_identity.js`, contract-tested under Guardian),
  and enforce refuses a moved workload with "recorded against designs X,
  comparing against designs Y" BEFORE spending minutes measuring. The
  pcb-editor runner gained the `reference.designs` capture its two sibling
  runners already had; its enforcement is strict only under the perf_gate
  snapshot env and prints a label standalone, so `prepare-release` (which
  measures the live checkout) can never be blocked by designs
  work-in-progress. Until the next deliberate `--record`, the gate fails with
  the honest "no workload identity / workload changed" reason instead of fake
  latency regressions.
- **friction:** the four boards missing from the bench corpus (`black-canyon`,
  `cyclops-interposer`, `rf-switch-eval`, `straps`) never stopped evaluating —
  they were never tried. Their sources moved into `src/boards/<name>/` during
  the designs refactor while their gitignored `.layouts.json` sidecars stayed
  at the old flat `src/` paths, and `bench_page.corpus` (like the boot
  warm-up) only selects designs whose sidecar sits NEXT to the source file.
  Moving the orphaned sidecars — and deduplicating the `.bom` copies now
  present at three path depths (`src/`, `src/boards/`, `src/boards/<name>/`)
  — restores the corpus; no tool change is needed.
## 2026-08-29 — a memo that copies memory is invisible to every DRC metric we have

The per-fill patch base (H-B) deep-copies a margin field per fill when it
publishes one. On barracuda-base that is ~80 MB of allocation and memcpy in one
burst. Every number the DRC seam reports stayed green — findings identical on
twelve boards, scoped == full, sweep discrepancies zero, reconcile timings
better — because none of them measures *memory traffic on a background path*.
What caught it was `scripts/pcb_editor_perf/run.js`: the burst landed inside a
cold page load's derived warm, and the CPU-rendered zoom probes janked by
200-400 ms, reproducible to 0.6 ms.

Two things that would have caught it earlier, in order of cheapness:

1. **`drc-dump` already prints `retained=…+… bytes=…`, and nobody diffs it.**
   The regression is one number: 68.7 MB → 124.8 MB on the read-only path. It
   was in my own report as a fact about memory and never as a *comparison* —
   the corpus differential script compares findings and times, not the memo
   line. Adding the memo/bytes line to the same `diff -I '^#'` corpus loop
   (or a ceiling on it) makes "this change retains more" a gate rather than a
   footnote.

2. **A retention change wants the editor gate, not only the DRC gate.** The
   task brief for H-B named `drc-dump`, `scripts/perf_gate.sh` and the four
   primary-page latencies as the verification surface. None of them renders a
   frame. Anything that changes what a background pass *allocates* — not what
   it computes — should list `pcb_editor_perf/run.js` as a required probe,
   because the only place that cost is observable is a paint.

The fix itself is one line of policy: publishing a base is opt-in per
fill-build session, and only the editor's reconcile asks. The seam was already
exactly where the split needed to be (`boardFills` vs `boardFillsScoped` in
`drc_compose.zig`), so no plumbing was needed through `drc_reconcile.zig` at
all — worth remembering that the scoped/full fork lives in `drc_compose`, not
in the server.

## 2026-08-29 — the editor zoom gate measures a race, and a DRC speedup wins it

Follow-up to the entry above. A regression was attributed to H-B's patch-base
copy landing inside a cold page load's derived warm. It is not that, and the
three experiments that ruled it out are worth writing down because each looked
conclusive on its own:

1. RSS after a cold page load was within 2 MB of main's candidate, and
   `drc-dump` showed `bases=0` on every read-only seam. **But a `curl` of the
   page runs no JavaScript**, so it never issues the round-trips the real page
   makes. A memory probe that does not execute the page is not a probe of the
   page.
2. Excluding the priming reconcile too (so no base can be published during a
   page load at all) left the gate failing 3 of 3.
3. Stripping the candidate — main's is 61 MB stripped, a `zig-prod` build is
   143 MB with symbols — changed nothing. Worth knowing anyway: an A/B against
   a release candidate is not like-for-like until both are stripped.

The actual mechanism, found by logging request timing beside the frame data:
the editable page posts three server round-trips as it opens (the authoritative
DRC, the RF retrofit check, and `refillPours`), and each REPAINTS the board when
it answers. The gate starts measuring at `load`, without waiting. On main the
pour refill answers *after* the benchmark has finished, so its repaint is never
recorded. H-B makes that pour fast enough to answer *during* — and the repaint
lands in whichever zoom phase it falls in, as a single ~200 ms outlier with
every median unchanged. Blocking `/api/pcb-drc/**` in the harness makes the
numbers identical to main's, 4 runs of 4; allowing it reproduces the spike
exactly in the runs where the response beats `__fbench`.

So the gate is not measuring a rendering regression. It is measuring who won a
race, and **any** pour or DRC speedup flips it — this will happen again.

RESOLVED — the gate owner chose **measure the finished page**, and it landed:
`fbRunWhenReady` now waits for the page's deferred chain before the zoom program
runs, and `docs/benchmarks/pcb-editor/baseline.json` was re-recorded under those
semantics.

Two things the prototype got wrong, both worth knowing before touching this
again:

* The deferred work is a **chain**, not a set: `refillPours` hands off to the
  `?derived=1` payload, which schedules the RF retrofit check. Waiting for "one
  finished and none in flight" passes in the gaps BETWEEN links, and a run that
  starts in a gap still catches the next link's repaint — that is what left one
  196 ms `gpu.zoom_in` outlier after the first fix. The condition has to be a
  quiet INTERVAL (800 ms), which lets the next link start and take the flag back
  down.
* `?derived=1` is itself one of the repainting round-trips and is not a
  `/api/pcb-drc/` call, so a filter written around that path misses the largest
  one.

The re-recorded numbers went DOWN, not up, which was not the prediction: the old
baseline had been recorded against a lighter board (the live corpus has since
grown from 62 to 120 RF paths) and, from its GPU figures, a busier machine.
Canvas p50 23.0/23.1 -> 21.1/20.6, GPU p50 95.2/89.6 -> 63.4/55.0, and the p95s
collapse toward the medians (41.3 -> 29.9 on canvas zoom-out) because the
outlier the race produced is gone. The enforced budgets were left exactly as
they were, so the gate is no looser than before — which is the property that
matters when the person re-recording is the author of the change.

## 2026-08-29 · claude · benchmark runs can no longer dodge the gate silently

- **workaround:** implemented the "friction" fixes from the fail-fast entry
  above. All three tracked browser runners (`scripts/pcb_browser_perf/run.js`,
  `scripts/pcb_editor_perf/run.js`, `scripts/ui_browser_perf/run.js`) now
  re-exec themselves under `scripts/gate.sh` when invoked standalone
  (`scripts/perf_gate_lock.js`, tripwired by `manifest.test.js`); `--list`,
  `--help`, and argument errors stay lock-free, `NETLISP_GATE_SERIALIZE=0`
  still bypasses, and under `perf_gate.sh` the inherited `NETLISP_GATE_HELD`
  makes it a no-op. As the backstop for workloads that never take the lock at
  all, `netlisp bench-page` samples /proc/loadavg around every board and
  labels the run — and each board measured beside the excess — CONTENDED when
  a 1-minute sample exceeds `1 + (start − 1)·e^(−t/60)` (its own busy core
  plus the decay of the just-finished gated builds) by more than 2 runnable
  tasks; `perf_gate.sh --record` refuses to install a recording carrying the
  label, and an enforce run prints it beside a FAIL instead of flipping the
  verdict. `gate.sh` now reports the queue depth and the pids ahead (commands
  included) the moment it blocks, and how long it queued once it acquires.
- **note:** the tripwire deliberately tolerates ~2 runnable tasks of drift —
  one extra single-threaded process can still skew a big board without
  tripping it (stated in docs/benchmarks/pcb-page/README.md's validity
  rules). The `hb_when.js` named above was an untracked scratch script and is
  gone from every checkout; the durable protection is that the tracked
  runners queue and bench-page labels what queuing cannot prevent.
