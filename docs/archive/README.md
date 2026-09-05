# Archive

Historical working documents: audits, implementation plans, proposals and
research notes. **None of these is a reference for how netlisp behaves today.**
They are kept because they record *why* a subsystem is shaped the way it is,
what was measured at the time, and which options were rejected — context a
commit message cannot hold. The reference set lives one directory up and is
indexed by [`../README.md`](../README.md).

Read one of these only when you are changing the subsystem it discusses, and
check its claims against the current tree before acting on them. Nothing here
is maintained: file paths, function names, measurements, build commands and
policy notes are all as of the date in the row.

| Document | Date | What it was | Status |
| --- | --- | --- | --- |
| [`AUDIT.md`](AUDIT.md) | 2026-07-01 | Whole-codebase read-only security/correctness audit, ~148 findings across the parser, evaluator, renderers, exporters and server. | Closed. Every finding was remediated; the live subset is tracked in [`../../AUDIT-LEDGER.toml`](../../AUDIT-LEDGER.toml), which gates each `fixed` entry on a regression test that still exists. |
| [`autorouter-audit.md`](autorouter-audit.md) | 2026-07-05 | First router audit: routing priority, trace overlaps, 45° discipline, pad-gateway escapes. | Implemented the same day. |
| [`pcb-editor-audit.md`](pcb-editor-audit.md) | 2026-07-06 | Four-way audit of the PCB editor as a KiCad replacement (viewer interactions, router + DRC, board data model, fab outputs). | Superseded by `full-pcb-design-audit.md`. |
| [`full-pcb-design-audit.md`](full-pcb-design-audit.md) | 2026-07-07 | What had to exist before a complete board could be designed in netlisp alone. Six parallel code audits with file:line evidence. | Largely delivered; the fab/DRC/export stack it asked for now ships. |
| [`guardian-upgrade-plan.md`](guardian-upgrade-plan.md) | 2026-07-08 | Adoption plan for a ten-feature Guardian release (deny-growth ratchets, hard file-size cap, mutation tier). | All phases executed. See [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) for the gate as it works now. |
| [`layout-context-audit.md`](layout-context-audit.md) | 2026-07-03 | What context the auto-placer was throwing away that the design already carried. | Consumed by the rough-placement rounds below. |
| [`rough-hybrid-scoring-plan.md`](rough-hybrid-scoring-plan.md) | 2026-07-03 | Rough placement engine audit plus the hybrid-scoring rounds that followed it. | Rounds 1–4 implemented. |
| [`inherited-net-classes-plan.md`](inherited-net-classes-plan.md) | 2026-07-15 | Making a reusable RF subcircuit declare net-class membership that survives hierarchy flattening. | Implemented; `(net-class …)` inheritance is documented in the language reference. |
| [`routing-reference-port-plan.md`](routing-reference-port-plan.md) | 2026-07-17 | Scoring the native router against an already-routed KiCad board used as a read-only reference. | Delivered as `netlisp route-kicad-reference` / `inspect-kicad`. |
| [`interactive-routing-replay-proposal.md`](interactive-routing-replay-proposal.md) | 2026-07-19 | Proposed architecture for human-guided routing with a durable instruction replay log. | Proposal. Not adopted in this shape; the agent-driven `add_tracks` / `route_experiment` loop went the other way. |
| [`autorouter-plan.md`](autorouter-plan.md) | 2026-07-26 | Design for a whole-board (global) autorouter, written from the barracuda 87/90 measurements. | Proposal. Partly superseded by the shipped rip-up/rescue ladder; the global-planning half was measured and did not pay. |
| [`pdf-export-plan.md`](pdf-export-plan.md) | 2026-07-29 | Implementation plan for a self-contained schematic/review PDF with no browser. | Implemented as `netlisp export-pdf`. |
| [`autorouter-wall-time.md`](autorouter-wall-time.md) | 2026-08-02 | Where the router's seconds went, per phase, with the `bench-route --breakdown` instrumentation added alongside. | Historical measurement record. Numbers are ReleaseSafe and predate the current build policy. |
| [`autorouter-audit-round-two.md`](autorouter-audit-round-two.md) | 2026-08-04 | Second router audit: the gaps the first three documents left open, and where the leverage was. | Partly implemented; produced the `bench-route --baseline` regression gate. |
| [`autorouter-audit-2026-08.md`](autorouter-audit-2026-08.md) | 2026-08-04 | Five parallel audits over the routing subsystems (core engine, rescue ladders, DRC/oracle, agent loop, RF/diff-pair). | Historical. Its negotiated-congestion tier ships disarmed. |
| [`topology-planner-plan.md`](topology-planner-plan.md) | 2026-08-05 | A coarse-grid global topology planner (Physarum conductance + congestion pricing) to run before the detailed router. | Measured and not adopted — global steering did not pay on this corpus. |
| [`webgpu-renderer-plan.md`](webgpu-renderer-plan.md) | 2026-08 | Prototype plan for a GPU-native PCB renderer with cost constant in zoom. | Prototype landed behind a feature check; the Canvas2D path remains the default. |
| [`power-layout-wip.md`](power-layout-wip.md) | 2026-06-06 | Work-in-progress note on usable switching-regulator placement: group cohesion and zoning relaxation forces. | Shipped. Kept for the root-cause write-up. |
| [`power-rail-reuse.notes.md`](power-rail-reuse.notes.md) | 2026-06-23 | Design note on why agents duplicate regulator modules instead of reusing a parameterised one. | Implemented; the canonical-module check came out of it. |
| [`uuid-sync-research.md`](uuid-sync-research.md) | 2026-05 | How component identity worked end to end across `.sexp` ids, the `.bom` UUID and KiCad's `canopy_uuid`, and where it lost sync. | Research note. Describes the *old* three-identifier model. |
| [`uuid_research.md`](uuid_research.md) | 2026-05 | Survey of how other EDA tools solve identity drift, and the recommended path out of it. | Research note. Its recommendation (source-resident ids, sidecar stamping) is what shipped. |
| [`system_diagram_research.md`](system_diagram_research.md) | 2026-05 | Working brief for evolving the block-diagram generator from a fixed compass layout into a domain-aware pipeline. | Research note. Partly implemented. |
| [`maintainability-audit.md`](maintainability-audit.md) | 2026-06 | Survey of redundancies, duplicated helpers and lockstep-edit surfaces in `src/`. | Historical. Several items closed; file/line references are stale. |
| [`autorouter-fixes-2026-09.md`](autorouter-fixes-2026-09.md) | 2026-09-05 | The fixes that closed the round-two router audit, with the benchmark numbers they did and did not move. | Implemented. |
| [`guardian-contract-resolution-2026-09-05.md`](guardian-contract-resolution-2026-09-05.md) (+ [`.json`](guardian-contract-resolution-2026-09-05.json)) | 2026-09-05 | How 40 Guardian contract violations across 29 functions were resolved (durable writes, request decoding, source mutations, numeric conversions). | Closed. |
