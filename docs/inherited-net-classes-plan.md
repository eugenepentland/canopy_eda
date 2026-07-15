# Inherited Net Classes for Reusable RF Subcircuits

*Implementation plan · 2026-07-15*

## Outcome

A reusable subcircuit can say “these nets belong to `rf-cpwg-50`” without
hard-coding final board geometry. When instantiated, class membership survives
hierarchy flattening and port bridging. The destination board supplies the
effective trace width, copper gap, via size, and routing priority.

The first trial should use the existing `pma3-lna` module inside
`cyclops-kband`: module-local `RFIN` and `LNAOUT` become the parent board's
`BEAM*_RFIN` and `BEAM*_LNAOUT` nets, while stamped copper adopts the parent
board's CPWG dimensions.

This is class inheritance, not an impedance calculator. The board still supplies
the width/gap values chosen for its stackup. A future impedance form could
calculate those values, but is not required here.

## Proposed authoring model

Keep the existing `(net-class ...)` form, but make its two responsibilities
independent:

1. `(nets ...)` assigns semantic class membership.
2. `(width ...)`, `(clearance ...)`, `(via ...)`, and `(priority ...)` define a
   class profile.

That lets a module assign nets while a destination board overrides the profile
without repeating module-local net names.

### Reusable RF amplifier

```lisp
(defmodule pma3-lna ()
  (design-block "PMA3-24323LN+ LNA"
    ;; instances, ports, and nets omitted

    ;; Safe standalone defaults plus semantic membership.
    (net-class "rf-cpwg-50"
      (width 0.20)
      (clearance 0.15)
      (nets "RFIN" "LNAOUT"))))
```

The numeric fields are optional. A library author can declare membership only:

```lisp
(net-class "rf-cpwg-50" (nets "RFIN" "LNAOUT"))
```

### Destination board

```lisp
(design-block "Cyclops K-band"
  (board-role board)
  (stackup 4 (plane 2 "GND") (plane 3 "V_RF_3P3"))

  ;; Profile-only: applies to inherited class members.
  (net-class "rf-cpwg-50"
    (width 0.38)
    (clearance 0.20)
    (via 0.60 0.30)
    (priority 7))

  (sub-block "lna1" (pma3-lna)
    (bridge "" (rename RFIN BEAM1_RFIN)
               (rename LNAOUT BEAM1_LNAOUT)))
  ...)
```

After flattening, `BEAM1_RFIN` and `BEAM1_LNAOUT` are members of
`rf-cpwg-50`. They route at 0.38 mm with a 0.20 mm gap even if the saved module
layout was created at 0.20/0.15 mm.

Board-local nets can still be assigned in the same declaration:

```lisp
(net-class "rf-cpwg-50"
  (width 0.38)
  (clearance 0.20)
  (nets "ANT1" "CAL_OUT"))
```

Do not automatically map `(port ... rf)` to a physical class. A functional RF
port does not imply one impedance or geometry; explicit membership keeps
`rf-cpwg-50`, `rf-cpwg-75`, and other transmission-line families distinct.

## Resolution rules

The behavior should be deterministic and backward-compatible:

1. Class names match case-insensitively; preserve the first spelling for UI.
2. Net names continue to match case-insensitively.
3. A class declaration may contain a profile, members, or both. Reject only a
   declaration containing neither.
4. Membership follows a net through hierarchy prefixes, bridge renames, and net
   ties to the final canonical flattened net.
5. The shallowest explicit membership wins. A board assignment overrides a
   module assignment. At equal depth, authored order preserves today's “first
   class wins” behavior.
6. If tied child nets bring different classes into one final net and no parent
   resolves the conflict, keep a deterministic winner and emit a diagnostic.
7. Profile values cascade field by field from module toward root. A non-zero
   destination value overrides the fallback; omitted destination fields retain
   the nearest inherited value.
8. Membership with no profile anywhere uses ordinary board defaults while
   retaining the class name for inspection.
9. Existing top-level forms containing geometry and `(nets ...)` behave exactly
   as they do now.

The resolved placement must retain the class name and effective numeric rule per
flattened net. Downstream code must not infer class identity from a final name.

## Current gaps

The tool already parses net classes and uses their geometry in routing and DRC.
The missing pieces are hierarchy and copper-transfer boundaries:

- `parseNetClass` requires `(nets ...)`, so a board cannot define a profile by
  name alone.
- `optimizer.netRulesOf` scans only root declarations against final net names;
  child membership is never collected.
- `applyNetTies` canonicalizes bridged nets but does not expose the alias map
  needed to carry metadata with them.
- module `SavedTrack.w` and `SavedVia.d/drill` values are copied verbatim by
  both PCB Stamp and KiCad sync.
- DRC honors per-net clearance, but pour generation and Gerber antipads use the
  board-wide `pour_clearance`, so the class cannot set a true CPWG pour gap.

## Implementation plan

### Phase 1 — Separate membership from profiles

- In `src/eval/env.zig`, retain `NetClassSpec` as authored syntax but allow an
  empty `nets` slice for profile-only declarations.
- In `src/eval/design_block.zig`, allow profile-only and membership-only forms;
  diagnose only an entirely empty class.
- Update `src/eval/forms.zig` help and regenerate `docs/language-forms.md`.
- Add a resolved representation containing class name, effective `NetRule`, and
  source depth. Carry it index-aligned with flattened nets in `BoardRules`.

### Phase 2 — Carry membership through flattening

- In `src/export_kicad_netlist.zig`, recursively collect member bindings with
  the same prefixes as `collectNets` and `collectNetTies`.
- Refactor `applyNetTies`, or add `flattenNetGraph`, to return the
  alias-to-canonical mapping it already computes internally.
- Map each prefixed member through that map and attach its class to the final
  `FlatNet` index.
- Resolve membership precedence by depth/order and diagnose cross-class ties.
- Resolve each selected class profile from its source block toward the root,
  overlaying non-zero fields.
- Replace `optimizer.netRulesOf`'s root-only string scan with this result.

Tests must cover renamed ports, private nets, nested modules, two module
instances, and a child-class conflict resolved by a parent assignment.

### Phase 3 — Apply destination geometry to stamped copper

Adapt copied copper at the destination boundary; never mutate the module layout:

- Add one shared helper that takes the mapped destination net and resolved rule.
  A non-zero class field replaces saved width/via geometry; zero keeps saved
  module geometry.
- In `src/serve/pcb_layout_page.zig`, pass parent rules to
  `writeSubRoutesJson` and emit destination track/via geometry.
- In `src/serve/sync.zig`, extend the local-to-parent bridge to carry both the
  KiCad display name and canonical parent name for rule lookup. Apply the same
  helper in `emitSeedCopper`.
- Preserve centerlines, layers, group tags, rigid transforms, mirror behavior,
  and F.Cu/B.Cu swapping. Only width/via geometry changes.
- Keep legacy sidecars readable. Source copper stays numeric and unchanged;
  destination projection is derived on Stamp/seed.

For the MVP, a changed parent profile requires re-Stamp/re-seed. A later
enhancement may mark inherited parent copper and re-resolve it live; arbitrary
hand-routed board copper must not be silently resized.

If a wider destination trace no longer fits the saved centerline, retain the
centerline and let DRC report the collision. Automatically rerouting it would
destroy the point of a hand-approved reusable RF layout.

### Phase 4 — Make clearance the CPWG pour gap

For CPWG represented as a signal trace beside a GND pour, class `clearance`
should be the edge-to-edge signal/pour gap:

- Add shared `BoardRules` helpers for effective per-net and pair clearance;
  reuse them in DRC, routing, pour generation, and Gerber output.
- In `src/placement/pour.zig`, grow each foreign feature by
  `max(board pour clearance, feature class clearance)` rather than one global
  value.
- In `src/export_gerber.zig`, use the same per-feature value for outer-pour
  clearing and plane antipads. Computed fill and clear flashes must agree.
- Test that a 0.38 mm trace with 0.20 mm class clearance creates a 0.78 mm
  corridor through a foreign GND pour.

This works when the CPWG reference is a pour. If a module saves explicit ground
guard tracks, changing clearance cannot move their centerlines; those must be
regenerated or represented as a pour boundary.

### Phase 5 — Surface the resolved result

- Include `{net, class, width, clearance, via_dia, via_drill, source}` in PCB
  page/describe data for classed nets.
- Show class and resolved geometry in selected track/net properties.
- Warn when an inherited class has no destination profile or conflicting child
  classes were resolved by precedence.
- Keep Route panel numbers as board defaults and label class values as per-net
  overrides.

### Phase 6 — Optional native KiCad project projection

Current `.kicad_pcb` sync writes explicit track/via dimensions, so seeded copper
can adopt width/via rules without changing KiCad settings. KiCad's interactive
router and zone refill read net classes from `.kicad_pro`, which this repository
does not edit today.

Treat native KiCad class sync as a separate opt-in phase: update only
Canopy-owned definitions/assignments, preserve unrelated rules, preview the
project-settings diff, and require explicit permission before writing the
project file. Core inheritance and Canopy Gerbers must not depend on this.

## Trial design

Use existing sources rather than a synthetic-only demo:

1. Add `rf-cpwg-50` membership for `RFIN` and `LNAOUT` in
   `projects/designs/lib/modules/pma3-lna.sexp`, with visibly different fallback
   values such as 0.20/0.15 mm.
2. Add a profile-only class to
   `projects/designs/src/boards/cyclops/cyclops-kband.sexp`, using trial values
   such as 0.38/0.20 mm.
3. Create or use the module's starred routed layout.
4. Open the parent PCB layout and Stamp `lna1` and `lna2`.
5. Confirm mapped `BEAM*` tracks retain paths but report 0.38 mm width and
   0.20 mm clearance.
6. Run route/DRC and inspect the clearance halo or GND pour opening.
7. Change only the parent profile to 0.45/0.25, re-Stamp, and confirm both
   instances adopt it without editing the module.
8. Dry-run KiCad sync and confirm `add_track`/`add_via` ops use destination
   geometry.

Then try the same pattern on `straps-amp-pma3`, classing the RF path on both
sides of its DC-block capacitors as separate named nets.

## Acceptance matrix

| Case | Expected result |
| --- | --- |
| Existing flat class | Behavior and numbers unchanged |
| Module standalone | Module fallback geometry used |
| Profile-only parent | Inherited members use parent geometry |
| Parent omits one field | Field falls back to module profile |
| Parent reclasses bridged net | Parent membership wins |
| Renamed module port | Class follows canonical parent net |
| Module-private net | Class follows `slug/NET` |
| Two module instances | Both inherit onto their mapped nets |
| Two child classes merge | Diagnostic plus deterministic precedence |
| Unclassed net | Defaults and saved copper unchanged |
| PCB Stamp | Width/via geometry destination-resolved |
| KiCad seed | Same geometry, including flip/layer transforms |
| GND outer pour | RF edge-to-pour gap equals class clearance |
| Wider copper collides | DRC reports it; path is not moved |
| Legacy `.layouts.json` | Loads without migration |

Add matching `SPEC.md` bullets and focused parser, flattener, optimizer,
router/DRC/pour/Gerber, Stamp, and sync tests. Finish with `zig build test` and
the full repository gate once unrelated working-tree edits are separated or
intentionally included.

## Recommended delivery slices

1. **Inheritance core:** Phases 1–2.
2. **Usable trial:** Phase 3 plus the `pma3-lna`/`cyclops-kband` example.
3. **True CPWG behavior:** Phase 4.
4. **Trust and polish:** Phase 5.
5. **KiCad-native editing parity:** optional Phase 6.

Slices 1–3 are required for the RF use case. Parser/router changes alone leave
stamped copper frozen; width adaptation without per-net pour clearance changes
the trace but not the CPWG gap.
