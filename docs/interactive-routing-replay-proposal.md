# Interactive Routing With Durable Replay

**A proposed architecture for human-guided PCB routing, replacing the current
pausable-session prototype without abandoning interactive routing.**

Status: proposal for review · 2026-07-19

---

## 1. Decision summary

Keep **interactive routing as the product direction**, but do not keep the
current pausable, server-resident route session as the product architecture.

The durable model should be:

1. Route the board as far as the automatic engine can.
2. Return a worklist describing every unresolved net.
3. Record each human decision as a typed, persistent routing instruction.
4. Re-run the router from the board plus all instructions recorded so far.
5. Repeat until the board is complete or explicitly left incomplete.

The instruction list is the source of truth. An in-memory incremental router
may accelerate the loop, but it is only a cache: losing it must not lose the
session, its decisions, or the ability to reproduce the result.

This preserves the strongest idea in the existing prototype—the router asking
for targeted human judgment—while removing its most fragile constraint: a live,
mutable routing process that must survive between interactions.

## 2. What the prototype established

The current prototype was useful. It established that the existing router can
expose and consume the right basic ingredients:

- A failed net can carry a search-frontier image and ranked blocking copper.
- A person can draw a corridor on the real board.
- Existing router machinery can retry a net, rip blocking nets, reorder work,
  and change layer policy.
- The route timeline and board painter can show the result in the existing PCB
  viewer.
- Some accepted hints can be lowered into `(pcb-plan ...)` routing intent.

Those pieces should be reused.

The prototype also exposed architectural problems that should not become
product constraints:

- A route session owns mutable router state across HTTP requests.
- Failed nets are presented one at a time rather than as a triage worklist.
- Sessions are capped, idle-evicted, and serialized behind shared server state.
- A server restart or eviction loses the live session.
- Accepted hints are distilled after the fact rather than being durable before
  they take effect.
- Not every interactive action has an executable replay form. In the current
  implementation, for example, rip and abandon hints distill only as comments.
- Human corridor clicks are recorded as layerless coordinates and later default
  to `F.Cu`, which is not an exact replay contract.

These are reasonable shortcuts for a prototype. They are the wrong foundation
for durable human work, regression tests, speculative alternatives, or a future
AI client.

## 3. Architectural principle

The canonical relationship is:

```text
board source + physical layout + router version + instruction list
                              │
                              ▼
                         route executor
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
          routed-board result       unresolved worklist
                 │                         │
                 │                         ▼
                 │                  human decision
                 │                         │
                 └──────────────┬──────────┘
                                ▼
                  append durable instruction
                                │
                                └──────► replay
```

A paused `RouteCore`, a prefix checkpoint, or cached speculative result may sit
inside the route executor. None of those objects is authoritative. The system
must always be able to discard them and reconstruct the same run from durable
inputs.

This gives the system two useful contracts:

**Reproducibility within a router build.** The same board revision, layout,
rules, router build, and ordered instructions produce the same output.

**Regression across router builds.** A completed recorded case must remain
complete and rule-clean after a router change unless the change intentionally
invalidates or migrates its instruction vocabulary. Exact copper geometry need
not remain byte-identical across different router versions.

## 4. Durable session model

Each routing session is attached to an immutable input revision. Its identity
must include hashes or equivalent stable identifiers for:

- Design source
- Physical-layout sidecar
- Relevant saved or locked copper
- Resolved design rules and net classes
- Router build and protocol version

The durable session contains:

- The input revision identifiers
- An ordered list of active routing instructions
- An append-only decision and outcome log
- The most recent run summary and report identifiers
- Actor, timestamp, and human-readable reason for every decision

The exact file split is an implementation choice. One reasonable starting point
is a current-state `<design>.route-session.json` plus an append-only
`<design>.route-log.jsonl`. The important requirement is semantic, not the
filename: accepted decisions must be durable before a route run depends on
them.

If the design source, part placement, outline, rules, or locked copper changes,
the current report becomes stale. A decision against that report must be
rejected rather than silently applied to a different board. The old log remains
available as history, and the user can explicitly start or migrate a session
for the new revision.

## 5. Protocol

The human viewer and any future agent should use the same versioned protocol.
The browser must not contain hidden routing semantics that are absent from the
wire format.

An abbreviated run report might look like:

```json
{
  "schema_version": 1,
  "report_id": "route-report:…",
  "input": {
    "design_revision": "sha256:…",
    "layout_revision": "sha256:…",
    "rules_revision": "sha256:…",
    "router_build": "git:…"
  },
  "summary": {
    "routed": 79,
    "total": 90,
    "drc_violations": 0,
    "trace_mm": 184.2,
    "vias": 31
  },
  "worklist": [
    {
      "stuck_id": "stuck:IF2_LO:…",
      "net": "IF2_LO",
      "reason": "search_exhausted",
      "frontier_contact": [
        {"net": "GND", "share": 0.63, "rip_cost_mm": 7.4}
      ],
      "evidence": {
        "frontier": "…",
        "occupancy_by_layer": ["…"],
        "focused_image": "…"
      }
    }
  ]
}
```

`frontier_contact` is deliberately not called `blame`. Contact share describes
what the failed search encountered; it does not prove that removing the named
copper will produce a successful route. A retry or evaluated future supplies
that counterfactual evidence.

A decision should identify both the report it answers and the complete action
to apply:

```json
{
  "schema_version": 1,
  "report_id": "route-report:…",
  "stuck_id": "stuck:IF2_LO:…",
  "idempotency_key": "decision:…",
  "action": {
    "kind": "route_through",
    "net": "IF2_LO",
    "waypoints": [
      {"x_mm": 18.4, "y_mm": 11.2, "layer": "F.Cu"},
      {"x_mm": 23.8, "y_mm": 14.0, "layer": "F.Cu"}
    ]
  },
  "actor": {"kind": "human", "id": "…"},
  "reason": "Keep the RF net via-free"
}
```

The decision records the typed action, not an option letter such as `B`.
Display labels may change; durable semantics may not.

After applying it, the log links the decision to the resulting report and
whole-board outcome. This distinguishes what a candidate predicted from what
the accepted instruction actually did.

## 6. First instruction vocabulary

The first version should be deliberately small and limited to operations the
router substantially supports already.

| Instruction | Meaning |
|---|---|
| `route_before` | Route the named net before specified competing nets or before the ordinary queue. |
| `rip_up_retry_after` | Remove explicitly scoped blocking copper, route the stuck net, then retry what was removed. |
| `route_policy` | Set preferred/allowed layers and the maximum permitted vias for a named net. |
| `route_through` | Route through exact, layer-qualified waypoints selected in the viewer. |
| `defer` | Move a net later in the routing order. |

Rip scope needs care. `rip_up_retry_after GND` must not casually mean “remove
every ground branch on the board.” The action should eventually identify a
routed branch, copper-object set, or bounded region near the failure. Whole-net
rip may be offered only when its scope and measured cost are clear.

Human corridor gestures should retain their exact coordinates and layers for
replay. A later AI client should normally choose an already generated corridor
or a symbolic named gate rather than inventing coordinates from an image. The
protocol can support both without weakening the human replay contract.

`skip` or `abandon` is a worklist operation, not successful completion. A run
with an abandoned net must end as explicitly incomplete with the remaining
airwire visible.

The following actions should not be part of the first implementation:

- Moving a component
- Narrowing a trace below its authored rule
- Waiving clearance or other fabrication rules
- Preserving newly hand-routed copper inside the replay loop

They affect placement, fabrication, or electrical intent beyond an ordinary
routing hint. They can be added later with full-board validation and explicit
human sign-off. A future waiver must be spatially bound to particular geometry
and a board revision; a broad exception for an entire net is unsafe.

## 7. User experience

The router completes all automatic passes before asking for help. It then shows
one worklist containing every unresolved net, ranked by an explainable heuristic
such as congestion, criticality, or the number of other failures sharing its
blocking region.

For each item, the viewer shows:

- The unresolved net and its relevant pads
- A focused search-frontier or occupancy view
- The strongest frontier contacts and the cost of ripping them
- Whole-board context
- The available typed instructions

The user may address any worklist item rather than being forced through a
sequence of popups. After a decision, the instruction is persisted and the
router replays. The refreshed worklist may shrink by more than one item because
changing one contested corridor can unblock other nets.

Undo removes or disables an instruction and replays. Restarting the server or
closing the browser does not change the session. Sharing the session means
sharing its durable input identifiers and instruction log, not transferring a
live server object.

## 8. Completion and route-quality contract

“All nets routed” is necessary but not sufficient. A complete result means:

- Every required electrical connection is physically connected.
- No net is skipped or abandoned.
- The exact geometric DRC has no unwaived violations.
- Authored width, clearance, via, layer, escape, bend, and other implemented
  net constraints are satisfied.
- Locked or manually preserved copper is unchanged.
- Placement, keepout, outline, and fabrication constraints have not regressed.

Every run report should also expose quality and stability metrics:

- Total and per-net trace length
- Via count and per-net via count
- DRC and constraint results
- Routed, unresolved, and abandoned nets
- Nets whose copper changed from the previous accepted run
- Copper added, removed, or moved

An instruction that solves one net while stranding two others is not a
successful outcome. Later evaluated futures must be judged on their resulting
whole board, not only the selected net.

## 9. Performance model

The replay architecture depends on acceptable feedback latency. That is an
assumption to measure, not assert.

Before replacing the prototype, benchmark at least:

- A cold full route of the target 90-net RF board
- A full replay after each supported instruction kind
- The existing incremental retry for the same cases
- A representative corpus of small and module-scale boards
- Peak memory and server contention

If full replay is already interactive, use it directly. If it is too slow,
preserve the same durable contract and add acceleration underneath it:

- Cache solved inputs by their full revision key.
- Cache prefixes of an instruction list.
- Resume a compatible in-memory `RouteCore` when available.
- Route work in cancellable background jobs.
- Serialize mutations per design, not all route work globally.

A cache hit and a cold replay must produce equivalent results. Cache loss must
change latency only.

Evaluated futures should not begin until one accepted decision can be replayed
within an agreed interactive budget on the target board. Speculating three
whole-board futures multiplies whatever cost remains.

## 10. What to reuse and what to retire

| Prototype component | Recommendation |
|---|---|
| Frontier extraction and occupancy snapshots | Keep; produce them for every post-route failure. |
| Blocker ranking and rip cost | Keep; rename the percentage to frontier contact share. |
| Route retry, rip-up, ordering, layer, via, and waypoint machinery | Keep behind typed durable instructions. |
| Board overlay, timeline, and corridor gesture UI | Keep and adapt to a worklist. |
| `(pcb-plan ...)` lowering | Keep; use it as part of instruction execution rather than optional post-session distillation. |
| Server-held `RouteSession` as canonical state | Retire. |
| One-failure-at-a-time state machine | Retire from the user workflow. |
| Idle eviction and capped live sessions | Retire as correctness-visible behavior. |
| Layerless corridor persistence | Replace with exact layer-qualified waypoints. |
| Rip/abandon comments in distilled output | Replace with executable semantics or explicit non-completion state. |

Do not delete the prototype immediately. First extract its reusable evidence,
router primitives, fixtures, and UI seams. Keep it behind a development flag
until the replay path has behavioral parity on representative cases, then
remove the server-resident session machinery.

## 11. Delivery plan

### Milestone 0 — measure and decide

- Run the current prototype on the target RF board.
- Record cold-route and per-hint latency.
- Classify the unresolved nets and which existing hints actually help.
- Decide the interactive latency budget.
- Freeze new product features in the pausable-session prototype.

Deliverable: benchmark report plus an accepted architectural decision that
durable instructions are canonical and in-memory state is optional.

### Milestone 1 — durable replay

- Define versioned report, decision, instruction, and outcome schemas.
- Hash the complete routing input and reject stale decisions.
- Persist instructions before applying them.
- Lower the first instruction vocabulary into existing route policy.
- Re-run deterministically and support undo by replay.
- Prove restart recovery.

Deliverable: a non-graphical protocol test that can complete and replay a
guided routing session without retaining a live `RouteSession`.

### Milestone 2 — worklist UI

- Produce stuck evidence for every failure after the automatic passes.
- Replace sequential stuck cards with one triage worklist.
- Reuse the existing frontier, occupancy, copper-preview, and corridor UI.
- Show route-quality and copper-churn deltas after each decision.

Deliverable: the target board can be guided from the existing PCB viewer, and
the session survives browser and server restarts.

### Milestone 3 — evaluated futures

- Generate a bounded set of safe candidate instructions.
- Run each candidate in isolation against the same immutable report input.
- Show complete-board outcomes, route diffs, and measured costs.
- Add caching, cancellation, and compute budgets.

Start with ordering, scoped rip, layer/via policy, and corridor alternatives.
Do not speculate component moves or rule waivers.

### Milestone 4 — richer judgment

Only after the logs show a real need:

- Add named gates and corridor vocabulary.
- Add locked hand-routing as replay input.
- Add spatially scoped, human-signed geometry exceptions.
- Consider component nudging with placement and fabrication validation.
- Add an AI client in shadow mode using the same protocol.

The decision log is initially a regression suite and evidence base. It should
not be described as automatically becoming training-quality data.

## 12. Acceptance criteria

The replacement is ready to supersede the prototype when all of these hold:

1. The same input revision and instruction list reproduces the same result
   within one router build.
2. A server restart during or between decisions loses no accepted instruction.
3. A stale report cannot mutate a changed board.
4. Undo is implemented by changing the instruction list and replaying.
5. Every accepted action has durable executable semantics.
6. A skipped or abandoned net is never reported as complete.
7. The ordinary non-interactive router remains behaviorally unchanged when no
   instructions are supplied.
8. The target board meets the agreed decision-to-result latency, directly or
   through a disposable cache.
9. The viewer reports whole-board DRC, completion, quality, and copper-churn
   outcomes after every decision.
10. At least one real stuck case on the target board is resolved through each
    retained v1 action that claims to solve such a case.

Product success should additionally measure human time saved, decisions per
completed board, candidate acceptance rate, and final route quality relative to
the current manual workflow.

## 13. Risks

**Full replay may be too slow.** Measure first; preserve incremental state only
as a cache keyed by durable inputs.

**Instructions can interact unexpectedly.** Keep them ordered, show whole-board
deltas, and make every instruction individually disableable.

**A new instruction can churn unrelated copper.** Track changed nets and copper
deltas. Add route-stability costs or explicit locks only when measurements show
they are needed.

**Coordinate hints can become stale after placement changes.** Bind them to the
layout revision and reject or migrate them explicitly.

**A coarse rip action can destroy valuable routing.** Scope it to known copper
and always report the removal cost and affected nets.

**Protocol evolution can invalidate sessions.** Version every format and write
explicit migrations; never reinterpret an old action silently.

**The cache can accidentally become authoritative again.** Require cold-replay
tests for completed sessions and treat cache eviction as a routine test case.

## 14. Non-goals for the replacement MVP

- An AI routing agent
- A triangle-mesh or topological conversation layer
- Automatic component movement
- Automatic rule waivers
- A custom machine-learning model
- A general-purpose job scheduler
- A new standalone PCB application
- Preserving a half-routed in-memory process as the only recoverable state

## 15. Decision requested from reviewers

Approve or reject the following direction:

1. Interactive routing remains the product goal.
2. Durable, typed routing instructions become the canonical session state.
3. Full deterministic replay defines correctness; incremental routing is an
   optional acceleration layer.
4. The current prototype is mined for frontier diagnostics, routing primitives,
   tests, and UI, then its server-resident session state is retired.
5. The first product milestone is a restart-safe worklist supporting only
   ordering, scoped rip, layer/via policy, and exact corridor hints.
6. Evaluated futures, named topology, geometry exceptions, and AI are deferred
   until the basic human loop succeeds on the real target board and meets an
   explicit latency budget.

This decision keeps the valuable interaction model while giving it a durable,
testable foundation suitable for real design work and later automation.
