# Power-rail reuse — stop duplicating regulator sub-circuits

> Design note / proposal. Captures *why* agents duplicate rail modules and the
> highest-leverage ways to make them reuse a parameterized one instead.

## Problem

Ask an AI agent (or a human in a hurry) for "a new 2.5 V rail" and it tends to
author a **brand-new `defmodule`** that duplicates the same regulator IC +
passives as an existing "generic" rail module — instead of instantiating the
existing parameterized module at the new voltage. The result is N near-identical
regulator modules that drift apart, bloat the library, and defeat the entire
point of parameterized `defmodule`s.

## Root causes — why reuse doesn't happen

1. **The interface is backwards.** Every rail module
   (`tps62933-rail`, `tps631000-rail`, `tpsm84338`, `lt3045`, `adp7118-ldo`, …)
   is parameterized by its **feedback-divider resistors** (`rfbt`/`rfbb`/`rset`)
   and *computes* `vout` from them:
   `vout = 0.8·(1 + rfbt/rfbb)`. But the request is always "give me 2.5 V", not
   "give me a 680k/320k divider". Hitting a target voltage means **inverting**
   that equation and snapping to E96 — enough friction that copy-paste-and-tweak
   feels easier than reuse.
2. **No discoverability.** Nothing tells an agent which library modules *provide
   a rail*, what voltage / current / topology each one covers, or how to
   instantiate one. So it never finds `tps62933-rail` and reinvents it.
3. **No guardrail.** Nothing flags "these two sub-blocks are the same circuit at
   different voltages."

## Proposed fixes (priority order)

### 1. Flip the interface: parameterize rails by target voltage `(vout X)` — HIGHEST LEVERAGE

Make rail modules take the **output voltage** and derive the divider internally.
Each module already has the `(let vout (* vref (+ 1 (/ rfbt rfbb))))` line — we
just invert it:

```scheme
(defmodule tps62933-rail ((vout 3.3) (rfbb 320k))
  "TPS62933 buck — give it a target voltage; it sizes the FB divider."
  (let rfbt (* rfbb (- (/ vout 0.8) 1.0)))   ; invert VOUT = 0.8·(1+rfbt/rfbb)
  (assert-range vout 0.8 17.0 "VOUT")
  (design-block (fmt "~V Buck (TPS62933)" vout)
    ...
    (instance "R_TOP" (res-0402 (fmt "~R" rfbt)) (pin 1 (fmt "~V" vout)) (pin 2 "FB"))
    (instance "R_BOT" (res-0402 (fmt "~R" rfbb)) (pin 1 "FB") (pin 2 "GND"))))
```

A new rail becomes **one line, no math, reusing the existing module**:

```scheme
(sub-block "rail_2v5" (tps62933-rail (vout 2.5))
  (bridge "" (rename VIN VSYS) (rename VOUT V_2V5) GND))
```

- Keep `rfbb` as a secondary knob (sets divider impedance / feedback current).
- Backward-compatible: keep the resistor params as an alternate path, or migrate
  the modules wholesale (the math is already there, just inverted).
- **Optional polish — honest BOM values:** add an `(e96 x)` / `(e24 x)` builtin
  that snaps the computed resistor to the nearest standard value, then recompute
  the *actual* `vout` from the snapped pair so the asserted voltage and the BOM
  match what gets built. (Needs `round`/`log10` builtins — a small addition to
  `src/eval/builtins.zig`.)

### 2. A rail catalog so agents find the module to reuse

- Add a `(provides-rail (vout-range 0.8 17.0) (current 3.0) (topology buck) (vin 3.8 30))`
  declaration to rail modules (or infer it from `assert-range` + metadata).
- Surface it where an agent looks: a "Power rails" section on the home page (or a
  `/rails` view), an MCP `list_rail_providers` tool, and a line in the
  auto-generated language reference — each entry showing the covered range and the
  one-line `(sub-block … (module (vout X)))` to paste.
- Ties into the existing power-budget table, which already reads sub-block rail
  ports with `(current …)`.

### 3. Guidance + a duplicate-circuit lint (cheap insurance)

- **CLAUDE.md / authoring rule:** "To add a power rail at a new voltage,
  instantiate an existing rail module with `(vout X)` — do **not** author a new
  regulator module. Pick by topology (LDO for low-noise / low-dropout, buck for
  efficiency), input voltage, and current. Author a new module only for a
  genuinely new regulator IC or topology."
- **`duplicate_regulator` lint (ERC):** flag ≥2 sub-blocks whose flattened
  component signature (component set + net topology, values ignored) is identical
  — "`rail_2v5` and `rail_3v3` are the same circuit; collapse into one
  `(vout …)`-parameterized module."

## Recommended first step

Implement #1 on the "generic" rail module as the worked pattern + add the
authoring rule, then roll the `(vout …)` interface across the other rail modules.
#2 (catalog) and #3 (lint) follow and reinforce it.
