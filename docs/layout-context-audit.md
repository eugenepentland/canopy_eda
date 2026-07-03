# Layout-Context Audit — what the auto-placer knows vs. what your hands know

*2026-07-03 · follows the pin-adjacent engine (dc4af61) and multi-IC satellite
groups (f26e568). Question: what context — in the DSL or inferable by the
engine — would let the rough generator produce better layouts?*

The framing that makes this audit tractable: **every improvement so far came
from consuming context the design already carried, not from searching
harder.** `(decouples "IC" PIN)` → pin-adjacent placement; `Loop.hub` →
satellite groups. The corpus misfits that remain are, almost one-for-one,
places where context exists but is dropped, or where the knowledge lives only
in your head / the datasheet / a free-text note.

---

## 1. What the engine consumes today

| Context | Source | Consumed by |
|---|---|---|
| Cap→pad binding | `(decouples "IC" PIN)`, per-pin decouple keys | loops → pin seed's primary targets |
| Series elements | inferred (2-pad part, two legs to one hub) | series-pair midpoint targets, pinned rotation |
| Net criticality | net-NAME heuristics (`module_policy.classifyNetName`) | crossing penalty, router priority, hot-loop boost |
| Pin roles | pinout function names + library `(electrical …)` | supply/ground/strap classes (loop targets, ERC) |
| Module class | heuristic detection (buck/ldo/mcu/rf_amp) | packZoned dispatch, lint gates |
| Board outline / edge parts | `(board (size…) (left…)…)` — **designs only** | edge docking, corners, centering |
| Priority tiers | `(rough (anchor…) (group…))` | **legacy ring only** — pin seed ignores it |
| Subsystem grouping | `(group "name" …)` | **force-path cohesion only** — pin seed ignores it |
| Routing geometry | `(stackup)`, `(net-class width/clearance/via)` | router only — placement never reads widths |
| Electrical budget | port `(current typ max)`, `(efficiency)`, `(calc …)` | power-budget report only |
| Hand corpus | starred layouts | KiCad seeding, Stamp, layout-match scoring — **not a prior for unstarred modules** |

The striking column is the right one: at least five rows end in "…only" —
context that's already authored and parsed but never reaches the pin-adjacent
generator.

---

## 2. Context that already exists but the pin engine drops
*(no DSL changes; highest confidence, cheapest wins)*

### 2.1 Authored `(group …)` subsystems — the lmk05318b/ap33772 gap

`ap33772-sink` declares exactly the structure its hand layout uses:

```scheme
(group "AP33772S Core"  ("U1" "C_VCC" "C_V5V" "C_V18" "C_IFB"))
(group "Pass Switch"    ("Q1" "Q2" "R_GATE" "R_SENSE" "R_OUT" "C_VBUS" "C_VOUT"))
(group "Alert"          ("R_INT_T" "R_INT_B"))
```

The pin seed never looks. The "Pass Switch" group is the VBUS power path the
hand layout arranges as a flow row — instead its members are individually
pin-bound and chain-attached, which is where ap33772's 18 residual crossings
live. Same story on lmk05318b (style 31 %): its hand layout groups by
subsystem; the engine places per-pin.

**Proposal:** treat each authored group exactly like a Round-3 satellite
group — solve it as a cluster (members ringed/chained around the group's most
connected member), dock it rigidly at the anchor pads its nets tie to. The
machinery (`buildPinGroups`/`dockGroups`) now exists; this is "ownership can
also come from `(group …)` membership," a ~S–M change. Groups become the
author's one-line way to say *these parts are one thing*.

### 2.2 `(rough (anchor "REF"))` — the pin seed ignores the authored anchor

`packPadAnchored` honors it; `runPinAdjacent` calls `pickAnchorHub`
unconditionally. Trivial fix, removes a surprise ("I named the anchor and the
new engine ignored it"). The tier groups could likewise map to band order
(tier 0 flush, later tiers outward) — but with pad-binding doing the real
work, tiers matter less than they did; low priority beyond the anchor.

### 2.3 Section `(role input|output)` + port direction → world orientation

Every hand power-module layout obeys a flow convention: **VIN enters one
side, VOUT leaves the opposite, and the module reads left→right.** The engine
has no concept of "outside world," so it picks edges purely by pad geometry —
that is precisely the residual style gap on tps631000 (74 % style, 42.9 %
area), bcuda-boost22 (40 %), lm74610 (edges differ though objective improved).
The DSL *already* carries the signal: ports have directions (`in`/`out`),
power ports are marked `power`, sections carry `(role input|output)`.

**Proposal:** derive a preferred edge per port-connected net: `in power` →
one side, `out power` → opposite side, connectors/RF ports get their own
edges; bias `groupAnchorTarget`/ring targets a quarter-turn toward the
convention when the pad geometry is ambiguous. Where the anchor's own pinout
contradicts it (VIN pins physically on the right), pad truth wins — the bias
is a tiebreak, not a constraint.

### 2.4 Differential pairs from net names

`w55rp20`'s ethernet lanes (`ETH_TX_P/N`, `ETH_RX_P/N`, each with 3.3 R
series + 50 R termination + AC caps per leg) are placed as eight independent
passives. A hand layout places each P/N pair as mirrored twins, chains of
equal length. The `_P`/`_N` (and `DP`/`DM`) suffix convention is already
universal in the corpus.

**Proposal:** detect suffix-paired nets, tie each part on the P leg to its
twin on the N leg (same value + symmetric net position), and place twins as a
mirrored unit perpendicular to their shared edge. Also feeds the router
(length matching) later. Evidence says this is most of w55rp20's remaining
2.49× gap besides its oversized courtyard.

### 2.5 Current ratings and net-class widths as placement weights

`(current typ max)` on ports and `(net-class (width …))` say which copper is
heavy. The placer weights loops by cap value and `classifyNetName` only. A
3 A rail deserves a tighter, shorter run than a 10 mA one at equal net-name
class. **Proposal:** scale loop/spring weights by declared current (port) and
net-class width when present. Small, safe (weights, not structure).

### 2.6 The starred corpus as a prior (Phase C, already planned)

29 hand layouts are the richest context in the repo and today they only score
*their own* module. The planned StylePrior (role-keyed edge/gap statistics
over `module_policy` roles, fit offline, applied as dock-gap/edge biases)
generalizes them to unstarred modules. `import-kicad` boards could feed the
same fitting corpus. Unchanged from the plan doc; still the right Phase C.

---

## 3. Context that exists nowhere yet — DSL additions

### 3.1 Component-level layout rules in the library *(highest leverage)*

The knowledge behind a good layout is mostly **per-component datasheet
rules**: "CBOOT within 2 mm of BST," "FB node small and away from SW," "this
is a buck: VIN cap → IC → L → VOUT cap flow," "REFIN wants its divider at the
pin." Today the engine *guesses* these via `module_policy` heuristics
(integrated-module bucks read `generic`), and the guesses can't see part-
specific rules at all. The library is the natural home — one authoring, every
design inherits, exactly like the existing component `(requirement …)`
machinery.

```scheme
;; lib/components/tps62933.sexp
(layout
  (class buck)                    ;; authoritative, no heuristic guessing
  (near "BST" 2.0)                ;; anything bound to BST within 2.0 mm
  (quiet "FB")                    ;; FB parts get aggressor keep-outs
  (flow "VIN" "SW" "VOUT"))       ;; row order for the zone/flow layout

;; lib/components/w5500.sexp
(layout
  (pair "TXP" "TXN") (pair "RXP" "RXN"))  ;; explicit diff pairs by pin fn
```

Consumption is cheap because each rule lowers onto machinery that already
exists: `(near …)` → proximity terms, `(quiet …)` → the Phase-2b keep-out
synthesis, `(class …)` → `ModuleClass` override, `(flow …)` → packZoned rail
order, `(pair …)` → §2.4. The win is *authority*: datasheet truth instead of
name heuristics. Pairs naturally with a small agent workflow — `read_datasheet`
already extracts text, so drafting a component's `(layout …)` block from its
datasheet's layout-guidelines section is a one-prompt job you review.

### 3.2 Port sides — tell a module where the world is

Explicit version of §2.3 for when convention isn't enough:

```scheme
(port "VIN"  in power  (side left))
(port "VOUT" out power (side right))
(port "RF_OUT" out rf  (side top))
```

One token per port. Drives: which edge a port-net's parts prefer, where bulk
"rail entry" caps sit (today they dock at the rail-pad centroid; hands put
them where power *enters*), leftover-row side, and — when the module is
stamped into a parent — a sanity check against how the parent actually
orients it. Modules currently have *no* board-frame concept at all
(`(board …)` is design-only), so this is the smallest possible step toward
one, and it's optional per port.

### 3.3 Matching / symmetry intents — structured, not prose

The splitter module's note says it in English: *"Length-match the two outputs
±0.5 mm … place them symmetrically."* The engine can't read prose. RF modules
are where hand layouts are most deliberate and where the generator is
weakest-informed.

```scheme
(matched "PORT1" "PORT2" (tol-mm 0.5))   ;; length-match these nets
(symmetric "C_P" "C_N" (about "U1"))     ;; mirrored placement pair
```

Placer: mirrored/equal-radius placement. Router (later): length-match DRC.
Report: surfaces in the review doc like `(calc …)` does. Modest engine work
because symmetric placement is the diff-pair mechanism from §2.4 with an
explicit spelling.

### 3.4 Deliberately *not* proposed

- **No resurrection of the removed `(placement)`/`(floorplan)`/`(constraints)`
  DSL.** That family was removed for cause (218de48): position-dictation
  fights the solver, is unadjudicable by the metric, and duplicates what
  saved layouts already do better. Everything above declares *intent*
  (grouping, flow, pairing, world orientation), never coordinates.
- **No per-pass proxy guards / no new scoring knobs.** Whole-candidate
  selection stays the arbiter (ES/GA lesson: the leverage is what you select
  on, not how hard you search).
- **No thermal model yet.** Real, but no corpus evidence it's the binding
  constraint on any current module; revisit when a design shows it.

---

## 4. Engine-only refinements surfaced by this round's evidence

| Fix | Evidence | Size |
|---|---|---|
| Corner-pad edge classification: 4-pad crystals put one load cap top, one bottom; hands flank them on the signal-pad axis toward the MCU | rp2350b X1 | S |
| Second band depth per-slot, not per-edge max: groups dock beyond the *tallest* ring part on the whole edge even where the ring is empty | rp2350b X1 gap, w55 crystals | S |
| Group rotation cost includes group-to-group ties (today only anchor ties), so cascaded satellites (LDO→LDO) face each other | lm74610 chain | S |
| Ring base uses the courtyard box; oversized module courtyards push the cap band visibly off the body — consider pad-row-aware base | w55rp20 band | S–M |
| Single-part modules score 0 % style / area vacuously — exclude from corpus aggregates | bcuda-splitter-adp2 | S |

---

## 5. Recommended order

1. **§2.1 + §2.2 — honor authored `(group …)` and `(rough (anchor))` in the
   pin seed.** Zero new authoring, direct fixes for ap33772 + lmk05318b, and
   it makes `(group …)` *the* documented way to steer the generator.
2. **§2.3 — flow convention from port directions/section roles** (with §3.2
   `(side …)` as the explicit override). Attacks the residual style gap on
   every power module at once.
3. **§2.4 — differential-pair twins from net names** (+ `(pair …)` spelling
   in §3.1). w55rp20 and every future PHY/USB module.
4. **§3.1 — library `(layout …)` component rules.** The systemic one: moves
   layout knowledge to where datasheet knowledge lives, kills heuristic
   guessing, compounds forever. Bigger, so it goes after the quick wins.
5. **§2.6 — StylePrior fit over the ★ corpus** (planned Phase C) + §4 small
   fixes opportunistically.

Items 1–3 are all "consume what's already written" — consistent with how
every prior win here happened.
