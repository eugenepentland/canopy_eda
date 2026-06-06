# LLM-Authored Constraints + Simulated Annealing for Module-Level PCB Placement

*A design / implementation brief.*

## What this is

This describes an architecture for module-level PCB component placement in which a large language model (Claude) acts as a **constraint author**, and a classical **simulated-annealing (SA) placer** does the geometry. The LLM never places parts and never tunes optimizer weights. It reads the netlist and part metadata, recognizes circuit topology and design intent, and emits a structured constraint set in a small Lisp-style DSL. Those constraints are validated against the real netlist, lowered into terms the existing scoring function already understands, and SA optimizes the result. Optionally, the LLM then looks at the rendered layout plus the numeric score breakdown and revises the constraint set.

The reason for this split is that it plays each tool to its strength and avoids the failure mode that sinks most "AI for placement" attempts. The genuinely hard, scarce ingredient in good PCB placement is not the optimizer — analytical and annealing-based placers are mature — it is *constraint generation*: knowing that "these eight parts are a buck converter, this is the input loop, this resistor pair is a feedback divider, keep it away from the inductor." That knowledge normally has to be hand-entered by an engineer or learned by a GNN from labeled data nobody has. An LLM can produce it directly from the netlist. So we let the LLM do the part it is uniquely good at (topology and intent), and leave the part it is worst at (precise, overlap-free geometry and physics) to code that already does it well.

This document assumes a placement engine already exists with a scoring function of the shape described in [The existing scoring engine](#the-existing-scoring-engine). The work being scoped is the **constraint layer** that sits in front of it.

---

## The core idea: three altitudes, only one of them is the LLM's job

It is tempting to imagine the LLM "looking at the board and twiddling the knobs." That is the wrong mental model and it produces a weak system. There are three distinct activities here, at three different altitudes, and conflating them is the main thing to avoid:

1. **Constraint authoring (the LLM's job, highest value).** Deciding *which constraints should exist at all* — what is a module, what is a critical loop, which net is high-impedance, what must keep away from what. The scoring function has a fixed functional form; it scores whatever poses it is handed against universal physics, but it has no representation of design intent until something adds it. That something is the LLM.

2. **Constraint revision (the LLM's job, secondary).** After a layout is produced, deciding whether a constraint is *missing or wrong* — "the RF section ended up next to the switch node, add a keep-out I forgot." This is structural feedback, not number-twiddling.

3. **Weight tuning (NOT the LLM's job).** Choosing how heavily to weight the loop-inductance term relative to wirelength, etc. This is an empirical sweep against real boards. The LLM should never be asked to do this per-iteration; doing so throws away its strength and leans on its weakness.

The reason the distinction matters is that these activities **fail differently**. A wrong weight costs you a slightly worse score, and you can sweep your way out of it. A wrong *constraint* — a hallucinated loop, a pin asserted on the wrong net — silently corrupts the objective, and SA will faithfully optimize the wrong board. That asymmetry drives the whole design, especially the validation step below.

---

## Architecture overview

The pipeline runs in two phases around the existing SA placer.

```
                          ┌─────────────────────────────────────────┐
                          │  netlist + component metadata + datasheets │
                          └──────────────────┬────────────────────────┘
                                             │
                  PHASE A                    ▼
            ┌────────────────────────────────────────────────┐
            │  Claude: constraint authoring                    │
            │  recognizes modules, loops, dividers, keep-outs  │
            │  emits constraint set in the DSL                 │
            └──────────────────┬─────────────────────────────-┘
                               │  DSL (with symbolic net/pin names)
                               ▼
            ┌────────────────────────────────────────────────┐
            │  VALIDATOR (deterministic, no LLM)                │
            │  resolve every net/pin against the real netlist  │
            │  reject anything that doesn't exist              │
            │  → lowered constraints (soft terms + move filters)│
            └──────────────────┬─────────────────────────────-┘
                               │
                               ▼
            ┌────────────────────────────────────────────────┐
            │  SA placer (existing engine)                     │
            │  objectiveCost += new soft terms                 │
            │  move generator respects hard filters            │
            │  minimize smooth surrogate, select on routed     │
            └──────────────────┬─────────────────────────────-┘
                               │  poses + Breakdown (score components)
                               ▼
                  PHASE B      ┌──────────────────────────────┐
            ┌──────────────────│  render layout to image       │
            │                  └──────────────────────────────┘
            ▼
   ┌────────────────────────────────────────────────┐
   │  Claude: constraint revision                     │
   │  given render + Breakdown numbers                │
   │  edits the constraint set INCREMENTALLY          │
   │  (add/relax a constraint — never regenerate)     │
   └──────────────────┬─────────────────────────────-┘
                      │  loop back to VALIDATOR until score converges / DRC clean
                      └────────────────────────────────────────────┘
```

**Phase A is a one-shot authoring pass that happens before any annealing.** It is where most of the value is. Most of "good module-level placement" is doing the intra-module placement correctly by construction and then letting the optimizer arrange the finished modules.

**Phase B is an optional structural-critique loop.** It is genuinely useful but secondary, and it has sharp failure modes (see [Failure modes](#failure-modes-and-mitigations)). Build Phase A first and get it solid before investing in Phase B.

---

## The existing scoring engine

The constraint layer plugs into a scoring function of this shape. Everything funnels through a single `objectiveCost` — a **cost**, lower is better — that is a weighted sum of four terms:

```
cost = HPWL
     + loop_w     · weightedLoop      (hot-loop inductance, value-weighted)
     + w_align    · compactnessTerm   (tidiness regularizer)
     + w_congest  · congestionPenalty (RUDY routability)
```

Default weights (all runtime-tunable): `loop_w = 6.0`, `w_align = 0.5`, `w_congest = 2.0`, and HPWL carries an implicit weight of `1.0`. The four terms:

**1. Wirelength (HPWL), weight 1.0.** For each non-ground net: nets of ≤3 pins use the bounding-box half-perimeter (which equals the optimal Steiner tree for ≤3 pins, so it is exact); larger nets use a rectilinear minimum spanning tree. Ground nets are skipped — they drop to the plane rather than routing point-to-point.

**2. Hot-loop inductance, weight 6.0 — the headline physics term.** For each decoupling cap (a passive with a power pad on a single-hub net *and* a ground pad), the engine builds a loop and scores its **connection inductance in nH**, not its length. The inductance model is a fixed floor for the two vias down to the plane plus a per-unit-length trace-over-plane term times the conductor length. The via floor is the dominant correction in the short regime — a pure length model wrongly drives inductance to zero as a cap touches the pin. There is deliberately **no lateral ground-return term**: on a solid ground plane the return images directly under the power trace, so loop area is set by the power-leg length, not by how far the cap's ground pad sits from the IC's ground pin. Caps are value-weighted: on a shared rail the smallest cap is pulled tightest, an explicit placement-order rank can tighten it further (only ever tighter, never looser), and on a switcher the input rail gets a ×2 boost because the input loop dominates radiated EMI. The whole thing uses a smooth straight-line surrogate (no obstacle detours) so the objective stays continuous in position.

**3. Compactness, weight 0.5.** A tidiness regularizer that snaps parts into shared rows and columns, which shortens routing on dense boards.

**4. Congestion, weight 2.0.** A RUDY (rectangular uniform wire density) penalty on an 8×8 grid that penalizes squared overflow above the two-signal-layer budget. It is near zero on sparse boards and only pushes parts apart out of genuine hotspots; it predicts routability, which wirelength alone does not.

**Surrogate vs. routed — important for where new terms go.** There are two versions of the objective. The smooth `objectiveCost` (straight-line loop surrogate) drives the relaxation, multi-start, and polish, and is also the on-screen score. A separate `routedObjectiveCost` (real maze-routed traces) is used only for finishing passes and benchmarking. The routed metric is never used as a per-pose signal because re-routing per pose makes the score jagged — a sub-millimeter nudge can flip a leg routable/unroutable. The optimizer therefore *minimizes the smooth surrogate*, then *selects* among fully-finished candidates on the real routed metric.

**New soft constraints from Phase A go into the smooth `objectiveCost`**, alongside the existing terms, exactly the way `compactnessTerm` already does. SA does not care what is in the scalar cost — you add a term, give it a weight, and it absorbs it. That property is the entire reason SA is the right solver for an LLM-authored objective: the set of objectives is open-ended, and SA accommodates an arbitrary scalar where an analytical placer would require every term to be differentiable and a MILP would require it to be linear.

**One existing piece is the seed of the DSL.** The value-weighting machinery already accepts a placement-order rank that can only tighten a cap's loop weight. That is, in effect, an already-shipping constraint primitive that the LLM can author. The constraint layer generalizes that idea from "rank a cap's priority" to the full set of grouping, proximity, keep-out, symmetry, orientation, and lock.

**A caveat carried over from the engine itself:** the loop weight, the input-loop boost, and the congestion weight are marked provisional in the code; they were hand-set to keep the inductance term near the magnitude of the older length-based term and need empirical re-tuning on real boards. This is exactly the weight-tuning activity that is *not* the LLM's job.

---

## The constraint DSL

A Phase-A authoring unit is a `module` form. The grammar (S-expression style, consistent with the engine's existing `requirement` and `critical-ic` forms; the `placement-order` form is reused verbatim because it already feeds the loop weighting):

```lisp
(module <name>
  (anchor      <ref> (role <role>) (integrated-inductor <bool>)?)
  (group       (<ref>+) (style cluster|row|column)?)
  (power-rail  <label> (role input|output|aux) (net <net>))
  (proximity   <ref> (to-pin <ref> <pin>) (max <n> mm) (priority low|med|high)?)
  (placement-order (<ref>+))                               ; existing — only tightens
  (feedback-divider (top <ref>) (bottom <ref>) (tap-net <net>) (sense-pin <ref> <pin>))
  (keep-out    (net <net>)|(part <ref>) (from <ref> (region <region>)?) (min <n> mm) (reason <str>)?)
  (net-length  (net <net>) (minimize | max <n> mm) (priority ...)?)
  (deprioritize (<ref>+) (reason <str>)?)
  (symmetry    (pair <ref> <ref>) (axis x|y) (about <ref>|net|point)?)
  (orient      <ref> (axis x|y) (to board-x|board-y|<deg>))
  (lock        <ref> (at <x> <y>) | (edge top|bottom|left|right))
  (side        <ref> top|bottom))
```

Each form is tagged **hard** or **soft**. Soft constraints become penalty terms in `objectiveCost`. Hard constraints become move filters or feasibility conditions in the search — they constrain which poses SA is allowed to consider, rather than adding to the cost. The mapping is given in full in [How constraints lower into the engine](#how-constraints-lower-into-the-engine).

---

## Worked example: a buck converter with an integrated inductor

The circuit: a buck regulator `U1` with an **integrated inductor**, a 1 µF and a 10 µF input cap on VIN, a 10 µF output cap, a two-resistor feedback divider, and three 0 Ω resistors on configuration pins.

### Why the integrated inductor changes the constraints

This is the kind of judgment that belongs in Phase A and that a fixed scoring function cannot make on its own. The reflexive constraint for any buck is "keep the switching loop tight." But with an integrated inductor, the high-dV/dt switch node lives **inside the package** — the radiating SW-node loop is internal, there is nothing external to tighten, and the SW net may not even be exposed. Blindly applying the tighten-the-switch-loop rule here would waste optimizer effort on a loop that does not exist externally. What is actually left critical on the board:

- **The input loop is now the dominant external EMI source:** Cin → VIN pin → (internal high-side switch) → GND pin → back to Cin. The smallest input cap wants to be as close to VIN/GND as physically possible. The scoring engine already handles this shape via the input-rail ×2 boost — *but only if it knows VIN is the input rail*. Declaring that is a Phase-A job.
- **The output is comparatively benign** — post-inductor and filtered, so the 10 µF output cap is an ordinary decap, not ultra-critical.
- **The feedback node is high-impedance and noise-sensitive** regardless of integration — and this is precisely what the engine is blind to. It has no idea the two resistors form a divider, that the FB tap is high-Z, or that it must stay clear of the inductor's magnetic field and the VIN copper.

So the honest division of labor for this circuit:

- **What the engine already does automatically:** the three caps. It detects them as decap loops, scores their connection inductance, and value-weights the 1 µF tighter than the 10 µF on the shared VIN rail. Phase A barely touches the caps — it mainly declares *which rail is the input* so the boost fires, and groups them.
- **What Phase A must add, because the engine cannot see it:** the feedback divider (proximity to FB, keep-out from the inductor, short tap net), the deprioritization of the three config straps so they do not steal space and optimizer effort from critical parts, and the module grouping.

### The constraint instance

```lisp
(module buck-3v3
  ;; --- anchor: the integrated-inductor flag suppresses the external SW-loop constraint ---
  (anchor U1 (role buck-converter) (integrated-inductor true))

  ;; --- one cluster ---
  (group (U1 C1 C2 C3 R1 R2 R3 R4 R5) (style cluster))

  ;; --- declare rails so the input-loop ×2 boost fires on the right one ---
  (power-rail VIN  (role input)  (net "VIN"))
  (power-rail VOUT (role output) (net "+3V3"))

  ;; --- input decoupling: 1uF is fast/small -> tightest; 10uF is bulk ---
  (proximity C1 (to-pin U1 VIN) (max 1.0 mm) (priority high))   ; 1uF
  (proximity C2 (to-pin U1 VIN) (max 2.5 mm))                   ; 10uF bulk
  (placement-order (C1 C2))                                     ; C1 ahead of C2 -> raises C1 loop weight

  ;; --- output cap: standard decap, post-inductor ---
  (proximity C3 (to-pin U1 VOUT) (max 2.5 mm))                  ; 10uF out

  ;; --- feedback divider: the part the engine is blind to ---
  (feedback-divider (top R1) (bottom R2) (tap-net "FB") (sense-pin U1 FB))
  (proximity R1 (to-pin U1 FB) (max 3.0 mm))
  (proximity R2 (to-pin U1 FB) (max 3.0 mm))
  (net-length (net "FB") (minimize) (priority high))            ; keep the high-Z tap short
  (keep-out (net "FB") (from U1 (region inductor)) (min 3.0 mm)
            (reason "high-Z FB node, magnetic coupling from integrated L"))

  ;; --- config straps: just need to connect; keep them out of the way ---
  (deprioritize (R3 R4 R5) (reason "0-ohm config straps, non-critical")))
```

The symbolic names — `VIN`, `FB`, `+3V3`, `U1.FB` — are placeholders the validator resolves against the actual netlist. They are not trusted until resolved.

---

## How constraints lower into the engine

There are two insertion points. Soft constraints become new terms in the smooth `objectiveCost`; hard constraints become move filters or frozen poses in the search. Nothing here requires changing the routed objective.

| DSL form | Hard / Soft | Where it lands |
|---|---|---|
| `anchor` (+ `integrated-inductor`) | metadata | feeds role / critical-IC detection; the flag *suppresses* any external SW-loop term |
| `group` | hard | move filter — a containment region the move generator keeps the cluster inside |
| `power-rail (role input)` | metadata | flips the input-loop ×2 boost branch for that rail |
| `proximity` | soft | new term shaped like the existing loop power-leg gap, or reinforces an auto-detected decap loop |
| `placement-order` | soft (weight) | **existing** — raises the cap's loop weight, only ever tightens |
| `feedback-divider` | metadata | declares the FB topology; the proximity / net-length / keep-out below are its teeth |
| `net-length (minimize)` | soft | partly already in HPWL; `priority high` raises that net's weight |
| `keep-out` | soft (→ hard) | new penalty on overlap of the net's routing region with the forbidden region |
| `deprioritize` | soft (weight) | scales down those parts' wirelength contribution so they don't compete for space |
| `symmetry` / `orient` | soft | new asymmetry / angular-deviation terms |
| `lock` / `side` | hard | move filter — pose or layer frozen |

### The feedback divider, walked through — a term that did not exist before

This is the clearest illustration of why the architecture is shaped this way, so it is worth tracing end to end.

*Before* Phase A, `R1` and `R2` are just two resistors on a couple of nets. The scoring function sees them only through HPWL, which would happily place them wherever shortens total wire — possibly running the FB tap directly under the package next to the switching copper. Nothing in the engine objects, because nothing in the engine knows FB is special.

*After* Phase A, three things attach to that node:

1. `proximity R1/R2 → U1.FB` pulls both resistors toward the FB pin. This is a new soft term, structurally identical to the existing decap power-leg gap, just anchored on a signal pin instead of a power pad.
2. `net-length (net "FB") (minimize) (priority high)` puts extra weight on shortening specifically the high-Z tap, above its default HPWL contribution.
3. `keep-out (net "FB") (from U1 inductor) (min 3.0 mm)` adds a penalty whenever the FB routing region encroaches on the inductor footprint region — the magnetic-coupling guard.

SA absorbs all three for free, because it does not care what is in the scalar cost. You add the terms, give them weights, and anneal. The engine went from blind to that node to actively protecting it, without any change to the optimizer itself — only to the cost it is handed.

---

## Validation and grounding (the guardrail that makes this safe)

**Every net and pin name the LLM emits is validated against the real netlist before it reaches SA.** This is not optional polish; it is the load-bearing safety property of the whole system, and it follows directly from the failure asymmetry described at the top: a wrong constraint corrupts the objective silently.

The validator is deterministic, runs with no LLM in the loop, and enforces at least:

- Every `net` referenced (`"VIN"`, `"FB"`, `"+3V3"`, …) resolves to a real net in the netlist.
- Every `(to-pin <ref> <pin>)` and `(sense-pin <ref> <pin>)` names a pin that actually exists on that part *and* is actually on the net the constraint implies.
- Every `<ref>` in a `group`, `proximity`, `deprioritize`, etc. is a real component.
- A `feedback-divider`'s top/bottom resistors and tap net are mutually consistent (the tap net actually connects them and reaches the named sense pin).

Anything that fails is **rejected** rather than silently lowered. A rejected constraint should be surfaced back to the LLM (in Phase B) as a correction signal, not dropped on the floor. To make validation tractable and to keep the LLM honest, **require the LLM to cite the net or pin each constraint refers to** — authoring against named, checkable entities rather than vibes.

If the engine exposes netlist-introspection primitives — something like a "get every pin on this net" and a "list the free/unassigned pins on this part" — those are exactly the grounding layer the validator should be built on. The same primitives are what let the LLM author correctly in the first place, by inspecting the netlist instead of guessing.

---

## Failure modes and mitigations

These are the things that will actually go wrong. Design against them from the start.

**Hallucinated constraints.** The LLM asserts a loop, divider, or pin that is electrically wrong. *Mitigation:* the validator above. This is why it is non-negotiable.

**Over-constraining into infeasibility.** The LLM piles on hard constraints that cannot be jointly satisfied, and SA fails — but SA fails *silently*, and you cannot tell whether the problem is genuinely infeasible or whether you just did not anneal long enough. *Mitigation:* prefer soft constraints, which absorb conflict gracefully. For dense sets of hard constraints — especially intra-module feasibility — consider a constraint-programming solver (e.g. OR-Tools CP-SAT) that can *prove* infeasibility and return a minimal conflicting subset (an unsatisfiable core). That conflict set is exactly the signal Phase B needs to relax the right constraint. A reasonable staging is: ship with SA alone, add CP-SAT for feasibility diagnosis the moment over-constraining starts biting (which, given that the LLM will over-constrain, will be soon).

**Thrashing across Phase-B iterations.** The LLM adds a keep-out, the layout shifts, and next iteration it removes the same keep-out. *Mitigation:* the constraint set is a **persistent, versioned artifact that the LLM edits incrementally**, never regenerates from scratch. Each Phase-B turn is a diff against the prior set, not a fresh authoring pass. If the engine has version-history primitives, use them as the backing store.

**Reading a render is lossy.** The LLM inferring loop inductance from a picture will always be worse than the engine computing it. *Mitigation:* feed Phase B the **`Breakdown` numbers alongside the image** — the render plus, e.g., "input loop 4.2 nH weighted ×2, congestion 0.3." The LLM then reasons about *structure* (what is near what, what is missing) while the engine supplies the *physics*. Never ask the LLM to eyeball what you can hand it as a number.

**Weight drift.** Phase B quietly turns into re-tuning `loop_w` every iteration. *Mitigation:* keep weight-tuning out of the loop entirely. It is a separate empirical sweep against real boards. Phase B edits *which constraints exist*, not how the existing physics terms are weighted.

---

## Suggested implementation path

A staging that de-risks the important parts first:

**Milestone 1 — DSL + validator + lowering, no LLM yet.** Define the DSL, write the deterministic validator against the netlist, and implement the lowering of each form into either a new `objectiveCost` soft term or a move filter. Hand-write the buck-converter constraint instance above and confirm SA produces a sane layout: input caps tight on VIN, FB divider near the FB pin and clear of the inductor region, config straps out of the way. This proves the constraint layer end to end without any LLM in the loop, and gives you a fixture to regression-test against.

**Milestone 2 — Phase A authoring.** Wire up the LLM to read the netlist + metadata and emit the DSL, feeding the validator. Compare LLM-authored constraints for the same buck against your hand-written fixture. Iterate on the authoring prompt until it reliably recognizes the module, the input rail, the divider, and the integrated-inductor subtlety.

**Milestone 3 — Phase B revision (optional).** Add the render + `Breakdown` feedback loop with the constraint set as a versioned artifact edited by diff. Add a stopping condition (score converged or DRC clean). Watch hard for thrashing and weight-drift.

**Milestone 4 — CP-SAT feasibility (as needed).** When over-constraining starts producing silent SA failures, add a CP-SAT feasibility check for intra-module hard constraints that returns conflict sets to Phase B.

The thing to protect throughout: the LLM authors and revises *constraints*; the engine owns *geometry and physics*; weights are an offline sweep. Keep those three altitudes separate and the system stays auditable, trainable-free, and free of reward-hacking. Collapse them into "LLM looks at a picture and twiddles knobs" and you have thrown away the one thing the LLM is uniquely good at.