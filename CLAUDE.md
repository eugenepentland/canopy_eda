# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A CLI-driven electronic design automation tool for schematic capture. All design files use S-expression syntax. A single Zig binary (`netlisp`) parses, evaluates, validates, renders, and serves designs.

## Build & Run

```bash
# Build
zig build

# Run tests (also runs the Guardian gate)
zig build test

# Regenerate the auto-generated language reference (docs/language-forms.md)
# from the evaluator's dispatch tables. `zig build` / `zig build test` FAIL
# when the committed file is stale, so run this after any DSL change.
zig build docs

# Start web server (default port 7050)
zig build run -- serve --project-dir projects/designs

# Build a design (stdout), --push sends to running server
zig build run -- build --project-dir projects/designs --push <design-name>

# Export KiCad netlist + footprints (handoff to KiCad's PCB editor)
zig build run -- export-kicad --project-dir projects/designs --output-dir <dir>

# Migrate an existing KiCad board INTO netlisp (reverse direction). Reads the
# .kicad_pcb alone — modern KiCad embeds the netlist (per-pad nets), pin names
# (pinfunction), footprint geometry, and BOM properties (Value/MPN/DNP) right
# in the board file, so no schematic wire-tracing is needed. Maps standard
# passives onto existing component families (cap-0402, res-0805, an FB ref on
# an L_0402 footprint → ferrite-0402), generates lib/components + lib/pinouts
# + lib/footprints for everything else (never overwrites existing library
# files), and writes src/<name>.sexp keeping KiCad's ref-des, with sanitized
# net names (unconnected-* pads dropped, DNP parts annotated). Imported
# designs are flat — section/sub-block structure is post-import curation.
#
# --fold-channels: for channelized boards (CH1_*/CH2_*/… net families) the
# importer detects the repeated per-channel circuit (seed by indexed net
# families, grow through private auto-nets, verify structural isomorphism)
# and emits ONE lib/modules/<design>-<prefix>.sexp defmodule + a (sub-block
# "chK" …) per channel with (net "CHK_X" "chK/X") stitching; channels that
# deviate structurally stay flat and are reported. Original ref-des survive
# as comments on each sub-block line. --fold-prefix CH overrides detection.
# Module port names are dot-free (+5.0V → port +5_0V) — dotted nets collide
# with the <rail>.<ic>.<pad> bypass-stub convention. The schematic page
# renders identical repeated sub-blocks once ("sub-block ×7").
zig build run -- import-kicad <board.kicad_pcb> --project-dir projects/designs --name <design> [--title <t>] [--dry-run] [--fold-channels] [--fold-prefix <P>]

# Convert KiCad files
zig build run -- convert-footprint <file.kicad_mod>
zig build run -- convert-symbol <file.kicad_sym> [--filter <name>]
zig build run -- convert-package <sym.kicad_sym> <fp.kicad_mod> [--name <name>]
zig build run -- convert-pinout <file.kicad_sym>
```

## Build System

Dependencies: `httpz` (HTTP server), `guardian` (code-quality gate).

### Guardian gate

Guardian runs its full **59-check suite on every `zig build` / `zig build
test`** — formatting, the spec workflow, structural / public-API / style /
error-handling / allocation checks, and git-aware process gates. It runs in
**baseline mode**: existing violations are frozen in `.guardian/`, so only NEW
regressions fail. There is no bypass — fix the code, never loosen the gate.

- **Per-item ratchets.** Each shape check (file/function length, complexity,
  nesting, params, type fields, line length) records a per-item ceiling that
  can only *shrink*. Do not raise a cap in `guardian.toml` to pass — improve the
  code; the improvement auto-lowers that item's ceiling.
- **Spec workflow.** `SPEC.md` `- ` bullets map **1:1** to `// spec: Section -
  Behavior` tags on tests. `[baseline] deny_growth = ["spec"]` is active: a new
  bullet must land with its tagged test in the *same* change, and no refresh may
  grow the spec baseline. `zig build spec-init` regenerates a starter SPEC.md.

Commands (`guardian-check` is the guardian dep's binary at
`../guardian-zig/zig-out/bin/`, built by `zig build` there):

- `zig build` / `zig build test` — gated build/test (full suite).
- `zig build mutate` — fast mutation tier: mutates only lines changed vs HEAD;
  for PR scope, `GUARDIAN_AGAINST=origin/main zig build mutate`.
- `zig build mutate-full` — whole-tree mutation; ratchets the kill score in
  `.guardian/mutation.txt` (nightly tier — the score can only climb).
- `guardian-check debt .` — non-gating frozen-debt / ratchet / mutation report.
- `guardian-check commit --intent "msg" .` — **preferred agent commit flow**:
  gates the exact working-tree diff, then stages a safe path list and commits
  only on green (never `git add .`; `.guardian/` + SPEC.md ride the same commit).
- `guardian-check explain <check>` — why a check blocks, how to fix / exempt;
  run it when a check fires instead of guessing.
- Selective refresh: `GUARDIAN_UPDATE_SNAPSHOT=<check[,check]> zig build` accepts
  exactly the named snapshot(s) — never a bare `=1` casually (it ratifies every
  snapshot at once). Commit the resulting `.guardian/` change.

Every gated run appends one JSON record per violation to
`.guardian/cache/last-run.jsonl` (machine-readable, for editor tooling / fix
loops).

The language reference `docs/language-forms.md` is auto-generated by
`src/docgen.zig` from the same dispatch tables the implementation uses
(`eval/forms.zig` registries, `eval/fmt.zig` directives, `sexpr/tokenizer.zig`
SI-suffix tables, `render_block_types.zig` classifier keywords). Three
enforcement layers keep it from drifting: an undocumented form variant is a
**compile error** (`requireAllDocumented`), per-table sync tests prove each
table matches its dispatch, and `gen-language-docs --check` runs on every
`zig build` / `zig build test` and fails when the committed file is stale.
Regenerate with `zig build docs`.

## Architecture

### Pipeline

```
Source (.sexp files)
    → Tokenizer → Parser → AST (nodes with source spans)
    → Evaluator (recursive eval with special forms, builtins, modules)
    → DesignBlock (instances, nets, ports, notes, sections, sub_blocks)
    → Post-build (ID insertion, BOM resolution, assertion checks)
    → Output:
        Schematic: render_html.zig → server-rendered HTML (hub-and-spoke SVG)
        Export: emit.zig (.sexp), export_kicad.zig (KiCad netlist + footprints + STEP models)
        Checks: erc.zig (electrical rules)
```

### Key Modules

**S-expression layer** (`src/sexpr/`): tokenizer → parser → AST. Printer is round-trip capable.

**Evaluator** (`src/eval/`): Split across multiple files:
- `evaluator.zig` — Main eval dispatcher
- `env.zig` — Core types: Value (union type), Env (lexical scope chain), DesignBlock, Instance, Net, Port
- `special_forms.zig` — `let`, `if`, `fmt`, `assert`, `assert-range`
- `modules.zig` — `import` (searches lib/components/ then lib/modules/), `defmodule` with closure capture
- `design_block.zig` — `design-block` evaluation
- `instance.zig` — Instance building + pin-net resolution
- `builders.zig` — Port, note, group, section builders
- `ids.zig` — 8-char hex ID generation, ref-des auto-assignment (prefix-based: C→C1, C2...)
- `builtins.zig` — Arithmetic, comparison, logic operators
- `fmt.zig` — String formatting (~V voltage, ~R resistance, ~C capacitance, ~A amperage, ~S string)

**Schematic rendering** (`src/render_html.zig` + `src/render_svg/`): Converts DesignBlock to an HTML page with inline SVG. Hub/spoke model: Hubs = ICs/connectors (U/J/P/X/Q prefix, rendered as boxes). Spokes = passives (R/C/L/F/D prefix, rendered inline on connections). Grid layout from sections. `src/render_json.zig` still emits a scene-graph JSON (`/api/scene-graph/:name`) used by the live-push pipeline. `src/render_system_svg.zig` + `src/render_block_types.zig` produce the system-overview SVG embedded in the page header (auto-categorised columns: mcu, power, memory, peripheral, connector, etc.).

**Checks**: `erc.zig` (duplicate ref-des, floating nets, unconnected pins, voltage mismatches, missing decoupling).

**Export**: `emit.zig` (flattened .sexp), `export_kicad.zig` + `export_kicad_netlist.zig` + `export_kicad_footprint.zig` + `export_kicad_model.zig` (KiCad netlist + footprints + STEP models — the bridge for handing schematic edits off to KiCad's PCB editor).

**Web server** (`src/serve.zig` + `src/serve/`): Serves the schematic viewer (with design-review panels embedded inline in the schematic page). Live update via version polling. JSON scene graph state protected by mutex.

**Docs generator** (`src/docgen.zig`): Renders `docs/language-forms.md` from the language's dispatch tables (forms registry, fmt directives, SI suffixes, classifier keywords). CLI: `netlisp gen-language-docs [--output <path>] [--check]`; build steps: `zig build docs` (regenerate), `--check` runs on every build/test.

### Component System

- **component-family**: Parameterized (e.g., `(cap "100nF" "np0")`) — `is_family: true`
- **component**: Fixed part (e.g., `(res-0402)`)
- Both cached in `component_cache: StringHashMap(ComponentData)`
- Import searches `lib/components/` then `lib/modules/` for `.sexp` files

## Conventions

- **Error handling**: `EvalError` enum propagated via `try`/`catch`. No panics. File load failures degrade gracefully.
- **Memory**: Uses `page_allocator` globally. File contents are never freed (AST slices reference source buffers).
- **Spans**: Every AST Node carries `span: Span` (line, col, byte offset) — used for ID insertion and error reporting.
- **Test tags**: Tests use `// spec: Section - Behavior` comments mapping to SPEC.md entries.
- **Strings**: All `[]const u8` slices into source or allocated buffers. Equality via `std.mem.eql(u8, ...)`.

## S-Expression Design Language

**Machine-checked reference: [docs/language-forms.md](docs/language-forms.md).**
Auto-generated from the evaluator's dispatch tables — every special form,
builtin operator, fmt directive, SI numeric suffix, design-scope form (with
arity + allowed scopes), and section-classifier keyword. It cannot drift
(see Build System above), so consult it for the grammar inventory; the
subsections below cover conventions and idiomatic usage only.

### Instance with inline pin-net connections

```scheme
(instance "C1" (cap-0402 "100nF")
  (pin 1 "VDD")
  (pin 2 "GND"))

;; Multi-pin shorthand for same net
(instance "U1" stm32n657l0h3q
  (pin 1 2 3 4 5 "VDD")
  (pin 27 28 29 30 31 "GND"))

;; (dnp) — first-class Do Not Populate. The footprint + pads stay in the
;; netlist / on the board (so a mod can stuff it), but it's marked DNP on the
;; BOM (badge + CSV column, kept off populated-qty merges), in the schematic,
;; and in the KiCad netlist export (dnp + exclude_from_bom properties). Use it
;; for option resistors / strap twins / spare-output footprints.
(instance "R_OPT" (res-0402 "0R") (pin 1 "A") (pin 2 "B") (dnp))
```

Test points (`(instance "TP_X" testpoint (pin 1 "NET"))`) are first-class
inside `(defmodule …)` sub-blocks: they take a renumber-safe `TP` ref-des and
are exempt from the `IC has no ground` ERC. A bare `(test-point "TP" "NET")`
stays a schematic-only marker (no exported pad).

### Multi-part symbols with grid layout

```scheme
(instance "U1" stm32n657l0h3q
  (part "VDD Power" (row 0) (col 0)
    (pin 1 2 3 4 5 "VDD")
    (pin 27 28 29 30 31 "GND"))
  (part "USB" (row 3) (col 1)
    (pin 52 "USB_DP")
    (pin 53 "USB_DM")))
```

### Named grid sections

```scheme
(section "USB" "USB 2.0 HS via USB-C — chip details sealed in usb-c-hs module"
  (row 3) (col 1)
  ...)
(section "3.3V Buck" "TPS62823 12V-to-3.3V, 2A"
  (row 0) (col 1)
  ...)
```

**When to create a section.** A design file reads as a wiring harness:
the main IC sits at the center, and each `(section …)` is one *functional
subsystem* hanging off it. `stm32n6.sexp` is the reference — work through
these four cases to decide whether something becomes a section:

1. **Peripheral with a distinct main-IC pin interface** (a bus, a clutch
   of GPIO control lines, dedicated clock pins). Make a section. Inside
   it, declare the main-IC-side mapping with `(pins "<ic>" (group "…")
   (pin …) …)`, plus `(role …)`, `(protocol …)`, and `(note …)` entries
   for firmware contracts and datasheet rationale. The peripheral's own
   pin-level implementation is sealed in a `(defmodule …)` under
   `lib/modules/` and brought in as a `(sub-block …)`. **Structural constraint:** `(sub-block …)`
   forms are *not* evaluated inside `(section …)`; place the sub-block at
   design-block top level immediately after its section (e.g. `(section
   "USB" …)` then `(sub-block "usb" (usb-c-hs))`).
2. **Self-contained hardware with no main-IC interface** — test points,
   mounting standoffs, fiducials. Make a section that directly
   `(instance …)`s the parts; there is no pin map and no sub-block.
3. **The main IC's own support infrastructure** — power rails, boot/reset,
   on-chip clocks, debug. This is *one* section ("… Core System"),
   subdivided with `(pins "<ic>" (group "VDD Power") …)`, `(group "Boot &
   Reset")`, `(group "SWD Debug")`, etc. Crystals and the debug header are
   simple enough to `(instance …)` directly inside this section alongside
   their `(decouple …)` / `(series …)` passives.
4. **Power-delivery blocks that only produce rails** — battery, charger,
   buck, LDO, voltage references. These get *no* section. Declare them as
   top-level `(sub-block …)`s and wire them with consolidated `(net …)`
   forms (one `(net …)` per rail so the validator doesn't flag a rail as
   split across sections). They surface in the system-overview diagram as
   their own synthetic chips.

One section per coherent subsystem — don't merge unrelated functions, and
don't split one subsystem (or one rail) across two sections. Section
bodies may also carry `(port …)` boundary declarations, `(calc …)` design
math, and `(bus …)` multi-bit shorthand; see `stm32n6.sexp` for each.

**Section-labeling conventions.** Every section has a *name* (short
functional role) and an optional *subtitle* (one-line technical summary).
Both feed the schematic header's system-overview SVG: the renderer in
`src/render_block_types.zig` `classifyByName` does case-insensitive keyword
matching on the **name** to pick the section's column + color, then prints
the **subtitle** as the chip caption.

- **Name** — 1–4 words, capitalized, functional role first. Pick at least
  one keyword the classifier recognizes so the chip lands in the right
  column instead of falling through to the generic peripheral bucket. The
  authoritative keyword→category table is auto-generated into
  [docs/language-forms.md § Section-name classifier keywords](docs/language-forms.md)
  from the same `name_rules` table `classifyByName` walks (don't copy it
  here — it would drift).
- **Subtitle** — one-line technical summary: part number, key spec
  (voltage / frequency / current), and any "chip details sealed in
  `<module>` module" pointer for sub-blocks. This is the caption that
  shows up under the chip in the overview, so prefer concrete numbers
  ("12V-to-3.3V, 2A") over generic phrases ("buck regulator").
- **Granularity** — one section per coherent functional block (a single
  rail, a peripheral, a debug interface). Don't merge unrelated functions
  into one section; don't split a single rail across two sections. For
  designs whose body is mostly `(sub-block …)` calls (e.g. power-6v.sexp,
  the small RF demos), a top-level `(section …)` per sub-block is
  optional — the system-overview SVG falls back to a synthetic per-design
  chip when none are declared.
- **Grid placement** — `(row N) (col N)` positions the section card in
  the schematic page. Convention used in `stm32n6.sexp` and
  `som-h563.sexp`: MCU/core in column 0, peripherals + buses in column 1,
  power rails stacked in column 0–1 at the top, connectors and
  bring-up/debug in the rightmost column.

### Hub grid positioning (non-part hubs)

```scheme
(instance "J2" amphenol-10164986
  (row 3) (col 1)
  (pin 1 12 13 24 "GND")
  (pin 4 9 16 21 "VBUS"))
```

### Parameterized modules

```scheme
(defmodule tpsm84338 (rfbt rfbb rled)
  (let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
  (assert-range vout 0.6 16.0 "VOUT")
  (design-block (fmt "~V Buck" vout)
    (instance "U1" tpsm84338rcjr
      (pin 4 vout-str)
      ...)))

;; Usage — positional, named, or mixed (positional may not follow named)
(sub-block "pwr" (tpsm84338 220k 47k 1k))
(sub-block "pwr" (tpsm84338 (rfbt 220k) (rfbb 47k) (rled 1k)))

;; A (param default) pair makes the argument optional — the default
;; evaluates at call time (later defaults may reference earlier params).
;; A fully-defaulted module renders standalone everywhere a design does.
(defmodule tpsm84338 ((rfbt 220k) (rfbb 47k) (rled 1k)) …)
```

**Modules are first-class on every read surface.** A `lib/modules/` name
works wherever a design name does: `GET /` lists modules with their
parameters and the designs using them, `/schematics/<m>` 302s to
`/modules/<m>`, and the MCP read tools (`get_schematic`,
`run_checks`, `list_instances`, `get_net`, `list_free_pins`)
resolve the module standalone via its parameter
defaults. The PCB tools also resolve a module name directly (real
instantiation first, else a zero-arg call), so `/pcb-layout/<m>` and the
`get_pcb_layout_image` / `describe_pcb_layout` MCP tools work on a bare
module.

### Numeric literals with SI suffixes

Bare numbers accept SI scale suffixes and an optional unit letter:
`220k` = 220000, `4.7k`, `1M`, `100n` = `100nF` = 1e-7, `10p`, `3.3V` = 3.3,
`0.5A`, `100mV` = 0.1 (milli only with a unit letter — `mm`/`mil` stay
dimension tokens). Unknown trailing text (`100kHz`) still parses as an atom.

### Decoupling shorthand

`(decouple "VDD" 1 per-pin auto)` expands to every pin already declared on the
net using the `(decouple-defaults (ic …))` ref (the `(pins …)` declarations
must appear first); a literal `REF PIN…` list spells the pins out instead. The
`(decouple-defaults … (bypass …))` component (not the ic) cascades into
sub-block modules that don't set their own.

### Per-pin decoupling binding: `(decouples "IC" PIN)`

A bypass cap declared as a plain `(instance …)` on a multi-pin rail (e.g. ten
`(instance "C_IOVDD_N" (cap-0402 "100nF") (pin 1 "VDD3V3") (pin 2 "GND"))`
caps, all on the same `VDD3V3` net that lands on a dozen IC pads) has no way to
say *which* pad it serves, so the placer pins every one of them to the same
(lowest-numbered) supply pad — their decoupling loops and the `/pcb-layout`
ratsnest all collapse onto one pin. Add `(decouples "IC" PIN)` to bind the
cap's power leg to a specific hub pad — it lives on the cap and also drives the
ERC/lint requirement below:

```scheme
(instance "C_IOVDD_3" (cap-0402 "100nF") (pin 1 "VDD3V3") (pin 2 "GND")
  (decouples "U1" 24))                 ;; this cap serves IOVDD_3 = pad 24
(instance "C_IOVDD_BULK" (cap-0402 "10uF") (pin 1 "VDD3V3") (pin 2 "GND")
  (decouples rail))                    ;; reservoir — serves the whole rail
```

`PIN` is resolved the same way `(pin …)` tokens are — a pad number or a
pinout function name. `(decouples rail)` is the explicit opt-out for a cap that
genuinely serves the whole rail (a reservoir / deliberately rail-level bypass).
The two `(decouple … per-pin …)` shorthands above already supply this binding
automatically (each generated cap carries its pad in its structural id); use
`(decouples …)` when you keep hand-named cap instances (and their stable ids).

Declaring which pin a decoupling cap serves is a **hard requirement**: an HF
decoupling cap on a rail that lands on ≥2 of a hub's **supply** pads (config
straps like EN/PG are excluded from that count by `pin_roles`, so a cap never
binds to the enable pin) **must** carry a binding.

- The **`decoupling_unbound` ERC check** (`src/erc.zig`, **error**) is the gate:
  it fails `netlisp check` (which exits non-zero on any error-severity
  violation), lights the home-page health chip red, and shows in the review doc
  + the `run_checks` MCP tool. (`netlisp build` / `--push` deliberately do *not*
  run ERC — the push path exists to view work-in-progress designs live; run
  `netlisp check` to gate.) It enforces the
  *requirement* — does the cap declare a pin at all? It runs **per block**
  (recursing sub-blocks), so a module's bypass cap is judged against *its own*
  IC's pad count, not an unrelated IC that merely shares a board rail once
  flattened. Reads `lib/pinouts` + `lib/components` for the strap classification
  (needs `--project-dir`).
- The **`decouple-unbound` layout lint** (`src/placement/layout_lint.zig`,
  **warning**) is the placement-time advisory, surfaced in `pcb-describe`'s
  `lint[]` on `/pcb-layout` and the `describe_pcb_layout` MCP tool. It is a
  *warning*, not an error, because it fires on `explicit_pin` resolution: a cap
  can declare a pin (so the ERC requirement is met) yet still land here when the
  solver pairs it to a different hub on a shared plane — a placement-quality
  smell, not a missing declaration. Use `(decouples rail)` for a cap that
  genuinely serves the whole plane.

Both share the exemptions: bulk reservoirs (≥4.7 µF, rail-level by nature),
single-supply-pad rails (a buck VIN/VOUT — the target is unambiguous), caps
already bound via `(decouples …)` / `decouple_pin` / a `(decouple … per-pin)`
shorthand pad, and `(decouples rail)` opt-outs. Value sets only placement
tightness, never *whether* a cap must declare its pin.

### Config-strap ties: `(strap-ok PIN "reason")`

A configuration / enable / reset strap (EN, CE, MODE, ILIM, SHDN, BOOT, ADDR,
an I²C `A0`/`A1`/`A2` address bit, OE, …) tied **directly** to a power or ground
rail is easy to wire backwards (`EN` high when it should be low) and impossible
to rework once fabbed. The idiomatic default is therefore a **pull-up/pull-down
resistor**: a strap pulled through a resistor lands on its own private net (e.g.
`EN_PU`), never on the rail, so it is silently fine — only a strap pad sitting on
the rail itself is flagged. A genuinely floating strap is still caught by the
floating-net check.

When the direct tie *is* correct (an I²C address bit, an LT3045 `ILIM`→GND
default current limit, a `MODE`→GND select, an always-on `~SHDN`→VDD), bless it
on the instance with a mandatory reason — the "I checked this, it's deliberate"
sign-off:

```scheme
(instance "U1" lt3045edd
  (pin 5 "GND")                                      ;; ILIM
  (strap-ok 5 "ILIM->GND selects the default (max) current limit per datasheet"))
;; PIN resolves like a (pin …) token — a number, a quoted/atom pad ("B1"),
;; or a function name that maps through the pinout to its physical pad.
```

`PIN` is resolved the same way `(pin …)` and `(decouples …)` tokens are. An empty
or missing reason does **not** suppress the error.

- The **`strap_tied_to_rail` ERC check** (`src/erc.zig`, **error**) is the gate:
  it fails `netlisp check` (non-zero exit on any error-severity violation),
  lights the home-page health chip red, and shows in the review doc + the
  `run_checks` MCP tool. (As with the other ERC checks, `netlisp build` does not
  run ERC — use `netlisp check` to gate.) It runs **per
  block** (recursing sub-blocks), so a module's strap is judged against the rail
  names in *its own* namespace (a module's `EN`→`VIN` tie is judged on `VIN`,
  not on whatever the parent wires `VIN` to). Strap-class pins are detected by
  pinout **function name** (`pin_roles.strapPads` / `isStrapFn`) **or** a library
  `(electrical "FN" (type input|output|io))` decl — the name heuristic matters
  because few parts carry electrical annotations. Connector / mechanical
  **positional** pins (a mezzanine pad named `A01`/`A01_A01`, or a `fn == pad`
  header pin) and two-digit `A`-bus / GPIO `P<x><n>` names are **not** straps, so
  the check stays low-noise on board-to-board connectors and MCUs. Needs
  `--project-dir` to read `lib/pinouts` + `lib/components`; the rail predicate is
  the supply/ground name heuristics (`isSupplyFn`/`isGroundFn`) plus this block's
  declared `(board …)`/derived rails and voltage-literal names (`3V3`, `+5V`).
- The strap-detection path is **ERC-only**: `pin_roles.classify` (the placer's
  loop-target path) is deliberately left on the electrical-type signal alone, so
  recognising more straps here never shifts a PCB layout.

### No-connect sign-off: `(nc-ok PIN "reason")`

A pad left unconnected (a "no-connect", NC) is often deliberate — an unused
GPIO, a datasheet "leave floating" pin, an internally-pulled enable — but it can
also be a forgotten wire on a pin that genuinely needs driving. Rather than
flagging *every* open pad (an MCU has dozens that are fine to float, which would
be pure noise), the `no_connect` ERC tiers each unconnected pinout pad **by
confidence** and only surfaces the ones worth a second look:

- **error** — the pad's library `(electrical "FN" (type input))` decl marks it a
  driven input, yet it's left floating. High-confidence "this must be wired".
- **warning** — the pad's pinout function *name* is a config/enable/reset strap
  (`EN`, `MODE`, `BOOT0`, `NRST`, `SHDN`, `CE`, `OE`, an I²C `A0`…`A9` address
  bit, …) left floating. A floating enable/address pin is suspicious, but such
  pins are commonly internally pulled, so it's a softer nudge than a declared
  input.
- **silent** — everything else: a real supply/ground pad (owned by the
  IC-power-presence check, never double-reported), an unused output, a GPIO/IO
  (`PA3`, `PD15`), a passive pin, a buffer/level-translator channel (an `A<n>`
  pad with a `B<n>` twin in the same pinout — a TXB0104/TXS0108/`245 channel,
  not a device-address strap), a datasheet no-connect/reserved name (`NC`,
  `N/C`, `DNC`, `NC3`, `RESERVED`, `RFU`), and any unrecognised name. This is
  what keeps the check quiet on a 100-pin MCU with unused peripherals.

When an unconnected pad *is* deliberate, sign it off on the instance with a
mandatory reason — the "I checked this, it's meant to float" acknowledgement,
mirroring `(strap-ok …)`:

```scheme
(instance "U1" w5500
  (pin 1 "VDD") …
  (nc-ok 37 "3V3_EN — 3V3 LDO always enabled internally, no external strap"))
;; PIN resolves like a (pin …) / (strap-ok …) token — a number, a quoted/atom
;; pad, or a function name that maps through the pinout to its physical pad.
;; An empty or missing reason does NOT suppress the finding.
```

- The **`no_connect` ERC check** (`src/erc.zig` `checkNoConnects`, error/warning
  by tier) runs **per block** (recursing sub-blocks), so a pad is judged in *its
  own* module namespace. It reads `lib/pinouts` + `lib/components` for the pad's
  function name and electrical type (needs `--project-dir`), and only inspects
  real IC instances (`U`-prefix, skipping test points, passives, and groundless
  parts — the same gating as the power-pin presence check). The tiering lives in
  `pin_roles.connectionRequirement` / `padRequirements` and, like the strap path,
  is **ERC-only** — the placer never consults it, so it can't shift a layout.
- **Sub-circuit ports** are the other half of the same idea, already built in:
  `checkUnconnectedPorts` makes a `(sub-block …)`'s **required** port an error if
  nothing connects to it, and the **`optional`** keyword on a `(port …)` is the
  "connection isn't required" flag — declare a module's spare GPIO/feature ports
  `(port "GPIO5" io optional)` and leaving them open is silently fine, the
  module-level twin of a per-pad `(nc-ok …)`.

### Schematic diagram layout: `(diagram-layout …)`

The free-floating block-diagram arrangement (the schematic page's Layout
tab) is authored with `(diagram-layout (anchor "x") (place "y"
(right-of "x")) …)`. **`diagram-layout` is the only spelling** — the old
`(layout …)` alias is retired (`ScopeForm.fromAtom("layout")` now returns
null; a test in `eval/forms.zig` asserts this), because the word "layout"
alone means PCB placement (the `/pcb-layout` force/rough solver).

The Layout tab is a **semantic-zoom ladder**: zoomed all the way out it
draws the **LOD0 "glance" layer** — one chip per `(group …)` region (or
ungrouped block), each chip the bounding box of its members — and zooming
in cross-fades to the detailed block diagram, then to the cloned real
schematic.

**Keeping the Layout diagram current — two halves, one automatic, one not:**

- *Render-time (automatic, every design).* A `(group …)` box is the bounding
  box of its members, so interleaved members produce huge overlapping (or
  engulfing) region boxes — at *every* zoom level, not just the glance
  chips. `computeFreeLayout` therefore runs a **group-aware separation**
  (`separateGroupClusters` in `src/diagram/layout.zig`): each `(group …)`
  and each ungrouped block is a rigid cluster occupying its members' integer
  cell box, and overlapping cell boxes push apart by whole cells along the
  smaller-overlap axis. Blocks stay on the `node_w+free_h_gap` ×
  `node_h+free_v_gap` lattice, intra-group relative placement is preserved,
  and disjoint cell boxes guarantee disjoint *drawn* boxes at LOD1/LOD2 —
  which in turn makes the LOD0 glance chips (built from those boxes) disjoint
  and grid-snapped for free (`separateEntities` in `src/diagram/lod.zig`
  remains as a cheap glance-layer safety net, now usually a no-op). The pass
  is a no-op for designs whose groups are already contiguous; only ones with
  interleaved groups get respread (and the page gets wider). There is no
  per-design tuning and nothing to regenerate. The author's job is upstream:
  keep each `(group …)` spatially coherent so the engine needn't respread it
  — co-locate a group's members in the `(place …)` directives.

- *Authoring (per design, manual).* Every design should carry a
  `(diagram-layout …)` and keep it in sync with the netlist. When you add,
  remove, or rename a `(sub-block …)` / `(section …)` / `(group …)`,
  refresh the matching `(anchor …)` / `(place …)` entries in the same edit:
  a `(place …)` naming a block that no longer exists is dropped silently,
  and a new block with no `(place …)` falls back to the engine's
  auto-placement and can land anywhere. After any structural edit, reload
  `/schematics/<name>`, eyeball the Layout tab at full zoom-out, and treat a
  stale or scattered diagram as part of the change still to finish.

### Lint warnings

Unknown sub-forms / enum words inside known forms (e.g. `(role inptu)`, a
section-only form at top level) no longer vanish silently — `netlisp build`
prints `file:line:col: warning: …` to stderr. Eval errors now name the form
with expected arity, suggest `(import …)` or nearest-name for unbound
components, and print the module call stack.

### Sub-block identity: legacy sidecar vs. hierarchical (opt-in)

Every part needs a stable `id` (→ `uuidFromId` → KiCad footprint) that survives
ref-des renumbering. For parts *inside* a `(sub-block …)` there are two schemes:

- **Legacy (default).** Each `(sub-block …)` carries an enumerated `(ids ("U1"
  …) ("C106" …) …)` sidecar — one frozen entry per child, keyed on the
  seed-time ref-des, written at the call site. Verbose (N×M entries for a module
  used N times with M parts) and the key drifts if a part renumbers because of
  an edit upstream of the sub-block. This is what `stm32n6.sexp` uses; it stays
  the default so already-adopted boards never churn.

- **Hierarchical (opt-in, "Option 4").** Add `(hierarchical-ids)` to the
  design-block body. Then each `(sub-block …)` gets **one** uuid (auto-minted
  into the design file on first build), and every child's id is
  `deriveChildId(subblock_uuid, child.origin_key)`, where `origin_key` is the
  child's stable *module-local* key (the source name for named instances, the
  `value@pin#index` / `value#index` structural key for `decouple`/`series`
  children). Both inputs are renumber-proof, so child ids survive sub-block
  renames *and* global renumbers. The module stays a clean, un-annotated
  template; storage scales as N+M (one uuid per call + the module written once).
  Mirrors KiCad's hierarchical-sheet path identity. See `src/adcarray/`.

```scheme
(design-block "ADC Array"
  (hierarchical-ids)                 ;; opt in — all sub-blocks below use it
  (sub-block "adc1" (ad7380-channel 1))   ;; (id …) auto-minted on first build
  (sub-block "adc2" (ad7380-channel 2))
  (sub-block "adc3" (ad7380-channel 3)))
```

The two schemes coexist per-design. Switching an existing design to
`(hierarchical-ids)` changes its child ids (different derivation), so it is a
one-time board re-stamp — adopt deliberately, not casually.

### Ports

```scheme
(port "VDD"  in  (rated 1.62 1.98))
(port "GND"  bidi)
;; Long form when net differs from name:
(port "VOUT" vout-str  out  (rated 0.6 16.0))
```

## Web Server

The production EDA server runs at **https://co-circuit.eugenepentland.dev** —
that's the canonical URL for the KiCad-sync agent and any remote MCP client.
Local dev still uses `http://localhost:7050`.

`netlisp serve` starts an HTTP server with the schematic viewer:

- **Design list**: `GET /` — links to all .sexp designs, with per-card health chips (ERC errors/warnings, failed assertions, open notes, green PASS)
- **Schematic viewer**: `GET /schematics/:name` — server-rendered HTML schematic with embedded SVG. The page also embeds the design-review panels inline (power-budget table, power-sequence, test-points, per-section coverage). There is no standalone review-report endpoint.
- **Scene graph**: `GET /api/scene-graph/:name` — JSON scene graph for schematic (used by the live-push pipeline)
- **PCB layout PNG**: `GET /api/pcb-png/:name` — server-rendered PNG of the force-directed PCB layout, so an AI agent (or any HTTP client) can *see* the board, not just parse the placement JSON. Mirrors the browser viewer's colours/projection (`src/render_pcb_png.zig` rasterizes onto `src/raster.zig`'s software canvas, encoded by `src/png.zig` — pure-Zig, no image dependency). Query: `?nets=A,B` / `?refs=U1,C3` enter *focus mode* (spotlight those nets/components in amber, dim the rest — `refs` match the bare leaf of a sub-block-prefixed ref); `?route=1` overlays routed copper + DRC markers; `?names=ref|origin|both` picks part labels (default: `origin`, the module-local sub-block-relative names, falling back to `ref` when no origin is known); `?pins=U13,C5` (or `pins=hubs`) labels those parts' pads with net names; `?crop=U1&r=6` zooms on one part (matched by ref, leaf, or origin name — combine with `?pins=`); `?sheet=1` returns a contact sheet (whole board + per-hub pin-labeled closeups); `?critique=1` draws a numbered worst-problems overlay (hottest loops by nH, longest airwire, staged parts, DRC count); `?width=`, `?layout=<saved>`, `?regen=1`, `?sub=<slug>`. When the design declares a `(board (size W H) …)` form, the physical outline rectangle + dimensions are drawn under the parts (green). Read-only; reuses the design's auto-layout cache.
- **Two-sided boards + standalone-PCB groundwork (2026-07-02)**: every pose
  (viewer, sidecars, sync) carries a board `side` (top/bottom) and `locked`
  flag — in the `/pcb-layout` viewer **F** flips the hovered part (bottom parts
  render blue + mirrored, matching worldPt's local-x mirror), **L** locks it
  (drag/rotate/flip refused). The router is layer-aware (bottom parts' pads
  block/connect on the bottom copper; through-hole pads on both; cross-side
  nets via by construction), and KiCad sync lands bottom parts on B.Cu with
  KiCad's stored back-side convention (+180° stored angle — netlisp mirrors
  local X, KiCad mirrors local Y). New top-level forms: `(stackup N (plane IDX
  "NET")…)` (no form = legacy implicit 4-layer with assumed planes;
  `(stackup 2)` = plane-less 2-layer, ground routes as real copper) and
  `(net-class "name" (width MM) (clearance MM) (via DIA DRILL) (nets …))`
  (per-net routing geometry; grid pitch sized to the widest class). DRC adds
  annular-ring (0.1 mm floor) + board-edge checks. **Routes persist**: saved
  layouts capture their routed copper (net-NAME keyed) in the sidecar;
  Load/page-open restores it and DRC re-checks it against current poses;
  moving a part invalidates only its own nets' copper. **Hand routing**: the
  ✎ Draw button (key **X**) draws tracks/vias onto the same model — click a
  pad to start (net/layer/width from pad + Route panel's track-width), click
  to fix 45°/grid-snapped corners (Shift = free angle), **V** drops a via +
  flips layer, finish on a same-net pad / double-click / Enter, Backspace
  steps back, right-click deletes copper under the cursor; Save/Update
  persists it like any routed copper (works on module pages → the module's
  `.layouts.json`). **Rigid sub-circuits**: parts sharing a sub-block prefix
  drag/rotate as one unit (G explodes/re-coheres; per-design localStorage),
  and the sidebar Sub-circuits palette **Stamp**s a whole module ★ layout
  onto the board via the same origin_key bridge KiCad sync seeds from
  (`PCB.subseeds`). **Stamped copper**: Stamp also carries the module ★
  snapshot's saved routes onto the board (`PCB.subroutes`, built server-side
  with module net names mapped to parent nets over the origin-key pin bridge;
  unbridged private nets get the `slug/NET` flatten spelling). Stamped copper
  is tagged with its group slug (`g` on tracks/vias, persisted through the
  sidecar), so rigid-group drags/rotates carry it along; it's dropped only
  when its group is broken apart (a member moved alone), and a re-Stamp
  replaces it. Nets touching a locked (not-moved) member are skipped.
- **Single-layout designs (2026-07-02)**: a top-level DESIGN keeps exactly one
  layout — no saved-layouts panel; the toolbar's "Save layout" overwrites the
  single auto-starred snapshot (KiCad sync + fab outputs read it). Modules and
  `?sub` sub circuits keep the multi-snapshot panel (variants per use case).
  After a live Regenerate/Rough run the page reloads with `?show=cache` so the
  fresh result is what you see (not the starred layout); Save commits it.
  Static assets serve with content-hash ETags + no-cache revalidation, so a
  deploy can never leave a browser running stale viewer JS.
- **Fab outputs (full package, Gerber included)**: `GET
  /api/pcb-gerbers/:name` — the complete manufacturing package as one ZIP
  (the `⤓ Gerbers` toolbar button on `/pcb-layout`): RS-274X/X2 Gerbers —
  outer copper (pads + the ★ layout's persisted routed tracks/vias), inner
  planes per the `(stackup …)` form (no form = the router's implicit 4-layer
  model, emitted as two inner ground planes with clearance antipads around
  foreign holes; a plane declared on an outer layer pours it with
  clear-polarity isolation), solder mask (0.05 mm expansion, vias tented),
  paste, silkscreen (footprint art + 5x7 ref-des strokes, mirrored on the
  bottom), and the board profile (the ★ layout's drawn outline > authored
  `(board …)` rect > parts-bbox fallback) — plus the Excellon PTH/NPTH
  drills and the centroid CSV. KiCad file naming + Protel extensions, so
  fab CAM auto-detects layers. Writer in `src/export_gerber.zig`, store-only
  ZIP in `src/zipfile.zig`. Individual pieces stay available: `GET
  /api/pcb-centroid/:name` — side-aware pick-and-place CSV at the blessed
  poses (★ default → newest manual → any → cache, the KiCad-sync
  preference); `GET /api/pcb-drill/:name[?npth=1]` — Excellon drill
  (plated: thru pads + the ★ layout's persisted routed vias; `?npth=1`:
  non-plated mounting holes). Formatters in `src/export_fab.zig`. **All fab
  outputs share one coordinate frame** (`export_fab.Frame`: y-UP, origin at
  the board outline's bottom-left, centroid rotation CCW-positive — the
  Gerber/KiCad-pos convention; the placement model itself stays y-down), so
  the package stacks exactly in CAM — never mix files from different
  requests/frames.
- **PCB layout facts**: `GET /api/pcb-describe/:name` — structured spatial facts about the solved placement (`src/serve/pcb_describe.zig`), the textual twin of the PNG: built from the identical placement-selection logic and accepting the same query parameters, so the facts always describe the board the image shows. Returns JSON with the axes convention (y grows down; "top" = −y), the anchor (largest hub IC), per-part `ref`/`origin`/side-of-anchor/`gap_mm`/nets/`unplaced`, per-decoupling-loop net + power-leg mm + nH + side, each hub's net→package-edge pad map, spec coverage (incl. `unresolved` spec names), per-part `want_side` (the part sits OPPOSITE the hub edge its net's pads are on), a `module_policy` block (Phase 0 of the module-placement ruleset — `src/placement/module_policy.zig`: the detected `ModuleClass` per hub IC (buck/ldo/mcu/rf_amp/generic, best-effort — integrated power modules with no discrete inductor read `generic`), the criticality `net_classes` (input_rail/switch_node/clock/rf/feedback/analog — the routing-order taxonomy), and the inferred passive `roles` (input_cap/decoupling_cap/bulk_cap/feedback_divider/matching_element)), a `lint` array (fell-back-to-auto / unresolved-name / unplaced errors; wrong-side / long-loop / outside-outline warns; plus the Phase-1 layout gates in `src/placement/layout_lint.zig` — `decap-far` (HF decap power-leg to its nearest supply pad >6 mm; bulk caps exempt), `hot-loop-not-tightest` (the switcher input loop is looser than a less-critical decoupling loop), `feedback-near-aggressor` (an FB/comp part within ~2 mm of a switch-node/clock/RF passive)), `board.outline` (the authored `(board (size W H) …)` rectangle when one exists), and (with `?route=1`) `routed:{trace_mm,tracks,vias,drc}`. The same facts flow through the MCP `describe_pcb_layout` tool. Agents should read measurements here and use the PNG for gestalt.
- **Rough-vs-starred match**: `GET /api/layout-match/:name` — score how hand-like the `?rough=1` seed is versus the design's *starred* layout (the saved layout flagged `"default"`/★ in `/pcb-layout`, the user's blessed hand-finished reference; `src/serve/layout_match.zig`). The metric is per interchangeable class (kind+value+footprint+net set), per IC edge, COUNT agreement — credit `min(rough, starred)` parts per edge — so swapping which fungible 100 nF cap sits on an edge isn't penalized and looseness is tolerated (only the wrong edge/proportion costs). Returns `{name, starred, n, area_match_pct, classes[]}` (each class's rough/starred per-edge tallies show which subsystem the rough scattered differently), else `{starred:null, message}` when nothing is starred yet. Measures placement hand-likeness / how little dragging remains to finish — NOT the electrical score. MCP twin: `compare_layout_to_starred`.
- **Layout state**: one sidecar per design — `<design>.layouts.json` `{default, cache, layouts[]}`. `layouts[]` = named snapshots (manual saves + auto-recorded optimizer runs), `default` = the starred (★) / KiCad-sync seed, `cache` = the single-slot optimizer cache (tuning params + poses, overwritten each solve). Precedence the `/pcb-layout` viewer shows as a scorebar chip: explicit `?refine=<snapshot>` > starred (★) default > cache > fresh solve > plain grid. (The old source-authored `(placement …)` spec once sat at the top of this chain; that DSL form is retired — layout is seeded from saved snapshots / the `?rough=1` seed now, not from a spec form in the `.sexp`.) Legacy standalone `<design>.autolayout.json` is still read as a fallback and deleted on the next solve; `.placement.json` migration was dropped (all designs migrated).
- **Live push**: `POST /api/push/:name` — rebuild and push update. On eval failure the JSON (and the schematic page, and the MCP `build` tool) carries a structured `diagnostic` `{file,line,col,message,source_line}` rendered compiler-style with a caret (`src/serve/diag_format.zig`).
- **Version history + diff**: `GET /api/history/:name` — stored snapshot ids (file copies under `<project>/history/<name>/<timestamp>/`, written before every mutation); `GET /api/diff/:name?from=<id>&to=<id|current>` — request-local netlist diff (instances added/removed, value/footprint changes, net membership changes; `src/serve/design_diff.zig`). Schematic header's History panel renders it. Caveat: snapshots capture the design file only, so an old revision re-evaluates against today's lib/ modules.
- **Datasheet attach**: `POST /api/attach-datasheet` `{component,file}` — splices the datasheet link into `lib/components/<name>.sexp` (idempotent, traversal-safe); library page has a per-card attach control. `GET /api/datasheets` lists candidates.
- **Cross-probing**: `/pcb-layout/:name?focus=REF` (or `#REF`) zooms/flashes a part (leaf-matching like `?refs=`); PCB sidebar rows link "Show in schematic →" (`#comp-REF` scroll+flash), schematic component detail links "Locate on PCB →". **Two-window live sync**: with any two of `/pcb-layout/<name>`, `/schematics/<name>`, and `/editor/<name>` open in separate tabs/windows of the same browser (the KiCad two-monitor workflow), clicking a part on one page highlights it on the others — a `BroadcastChannel("netlisp-xprobe")` bridge in `pcb_board.js`/`schematic_viewer.js`/`editor.js` (messages `{from: pcb|sch|ed, design, ref}`, receivers drop their own kind + other designs, refs resolved exact-then-leaf; no server round-trip). On the editor map an incoming ref frames the part's cell and selects it (`xpFocusRef`, falling back to `focusTarget` for canon/net names).
- **Version polling**: `GET /api/version/:name` — returns `{"version":N}`
- **Value editing**: `POST /api/edit-value/:name` — edit component value in .sexp file
- **ERC**: `GET /api/erc/:name` — electrical-rule violations
- **KiCad sync**: `POST /api/sync-kicad-pcb/:name` — file-based sync. Reads the `.kicad_pcb` declared by the design's `(kicad-pcb "<path>")` form, diffs it against the flattened netlist, and writes the updated board in place so footprint placements and routing are preserved. Driven by the schematic viewer's "Push to KiCad PCB" button, which dry-runs first and shows a categorized preview modal (board changes up top, metadata collapsed) before the real write, with a result toast. The heuristic relink (parent-path + value + net signature) is ON by default, so a refdes drift (e.g. FB→L) renames the placed part instead of staging a duplicate; a placement guard aborts the write with HTTP 409 if it would move, rotate, or side-flip any existing footprint; every write rolls a timestamped backup into a `backups/` subdirectory beside the board (`backups/<name>.bak-<stamp>`, newest 10 kept — the KiCad project dir stays free of `.bak-*` siblings). (`?dry_run=1` / `?prune=1` / `?no_migrate=1` / `?no_swap=1` modifiers — `no_swap` suppresses all `swap_footprint` geometry re-bakes so hand-tuned board lands survive; the withheld count is reported as `swaps_suppressed`.)
- **Library upload**: `GET /library`, `POST /api/upload-symbol`, `POST /api/upload-footprint`

### Live update workflow

```bash
# Terminal 1: start server (default port 7050)
netlisp serve --project-dir projects/designs

# Terminal 2: edit and push
vim projects/designs/src/stm32n6/stm32n6.sexp
netlisp build --project-dir projects/designs --push stm32n6
# Browser auto-updates within 500ms
```

### Verifying source changes don't move the board (dry-run sync)

After a refactor like the `(bus-net …)` / `(bus-port …)` rewrites, confirm
the change produces zero netlist-driven ops by hitting the file-based sync
in dry-run mode — no KiCad, Xvfb, or IPC agent needed. It reads the
`.kicad_pcb` at the design's `(kicad-pcb "<path>")` form, diffs against the
flattened netlist, and returns the op list without writing:

```bash
# Server running on :7050 with the design loaded
curl -s -X POST "http://localhost:7050/api/sync-kicad-pcb/<design>?dry_run=1" \
  | python3 -m json.tool
# "summary" all-zero (updated/added/removed/swapped) ⇒ the source change
# is netlist-neutral and won't move or re-stamp anything on the board.
```

The board file is on the NAS at
`/mnt/nas/Cyclops/Cyclops Digital/Cyclops Digital.kicad_pcb`. If the project
is open elsewhere, KiCad's lock file holds `{"hostname": …, "username": …}` —
concurrent saves corrupt the board, so only touch it when no other session
is live.

### MCP server (Claude Code integration)

`netlisp serve` exposes an MCP server so Claude Code can pull schematics, edit
the underlying `.sexp` files, and have the browser viewer update live. Two
transports:

- **`POST /mcp`** — streamable HTTP, the transport Claude Code's remote MCP
  connector uses. Auth is delegated to ward (see **Auth (ward)** below): Claude
  Code discovers the authorization server via RFC 9728/8414, registers
  dynamically (RFC 7591), and walks the user through ward's consent — nothing
  to configure client-side.
- **`GET /mcp`** — WebSocket upgrade, for local testing and any stdio bridge.

Tools exposed (defined in `src/serve/mcp_tools.zig`):

- **Project / introspection (read-only)**: `list_designs`, `list_library`,
  `list_history`, `list_instances`, `list_free_pins`, `get_net`,
  `describe_component`, `get_schematic`, `get_pcb_layout_image`, `get_version`,
  `run_checks`. `get_pcb_layout_image` returns the PCB layout
  as a PNG **image content block** (same renderer as `GET /api/pcb-png/:name`) so
  an agent can visually inspect placement; args: `name`, optional `nets`/`refs`
  (arrays or comma-strings) to spotlight a subsystem, `route`, `width`, `layout`,
  `sub`, `regen`, `names` (ref|origin|both part labels), `pins` (label pad net
  names on the given refs, or "hubs"). `describe_pcb_layout` is its textual
  twin — the `/api/pcb-describe` facts JSON built from the identical placement
  (args: `name`, optional `route`/`layout`/`sub`/`regen`). `compare_layout_to_starred`
  scores the `?rough=1` seed against the design's starred (default ★) layout —
  per-interchangeable-class, per-IC-edge area-match, the "is the rough in the
  right general area to finish by hand" check (args: `name`). The image tool
  also accepts `crop`/`r`/`sheet`/`critique` view modes.
- **Language / module authoring (read-only)**: `get_language_reference` —
  the auto-generated S-expression reference rendered live from the dispatch
  tables (same content as `docs/language-forms.md`; optional `section` arg
  returns one `## ` section). `preview_module` — evaluate a `lib/modules`
  defmodule standalone with caller-chosen args (request-local, nothing
  written): `view=summary` returns `{title,ports,instances,nets,sub_blocks,
  erc,assertions}`, `view=scene_graph` the full schematic JSON.
  For module-level *layout*, the PCB tools above accept a module name as
  `name` directly (resolved via a real instantiation in a design, else a
  zero-arg call).
- **VFS file ops**: `read_file`, `list_dir`, `glob` (read-only);
  `write_file`, `edit_file`, `delete_file`, `move_file` (mutation).
- **Build / state**: `build`, `regenerate_pinout`, `restore_version`.
- **Parts sourcing**: `search_components`, `resolve_mpn`, `check_stock`
  (read-only, DigiKey / Component Search Engine lookups); `download_footprint`,
  `download_datasheet` (mutation — import an ECAD model / datasheet into `lib/`);
  `read_datasheet` (read-only, extract text from an imported datasheet).
- **Per-design notes**: `list_design_notes` (read-only), `add_design_note`,
  `complete_design_note`, `reopen_design_note`, `remove_design_note`
  (mutation) — TODO sidecar (`<design>.notes.md`) for next-revision follow-ups.
- **Component requirements**: `list_component_requirements` (read-only),
  `add_component_requirement`, `remove_component_requirement` (mutation) —
  library `(requirement …)` rules that live on a part and are inherited by
  every design instantiating it (vs. `design_note`, which is per-design).

There is **no** granular `add_component` / `swap_component` / `edit_value` /
`rewire_pin` / `remove_component` tool — schematic edits go through
`read_file` → `edit_file` (or `write_file`) on the design's `.sexp` file,
then `build` to push the new version. Mutation tools
return the new `live_version`, so the browser picks up changes via its
existing 2 s poll of `/api/version/:name`.

```bash
# Connect from Claude Code — no --client-id/--client-secret: ward is the
# authorization server, discovered (RFC 9728/8414) and registered dynamically
# (RFC 7591) by Claude Code, which then walks you through ward's consent page.
claude mcp add --transport http netlisp https://co-circuit.eugenepentland.dev/mcp
```

## Auth (ward)

netlisp no longer runs its own auth — it is a **pure resource server**.
Authentication is delegated to **ward** (the `wardd` auth server, repo
`~/ai/ward`), which owns passkeys/WebAuthn, sessions, invites, roles, and is
the OAuth 2.1 authorization server. Public URL: **https://ward.eugenepentland.dev**
(local `http://127.0.0.1:9000`). The admin portal at
**https://ward.eugenepentland.dev/admin** manages users, sessions, invites,
OAuth clients, and grants; registration is invite-only through wardd. The
navbar Account link points at that admin portal.

- **Browser sessions.** A ward session cookie (domain `.eugenepentland.dev`) is
  verified against wardd `GET /verify`. No cookie → `302` to
  `https://ward.eugenepentland.dev/login?rd=<url>`; wardd unreachable → `503`
  (fail-closed, never fail-open).
- **MCP / API bearers.** Verified via wardd's LAN-only `POST /oauth/introspect`;
  the token scope must contain the service name (`eda`). On failure a `401`
  carries an RFC 9728 `WWW-Authenticate` pointing at
  `GET /.well-known/oauth-protected-resource` (the one well-known endpoint
  netlisp still serves), which names `ward.eugenepentland.dev` as the
  authorization server. Role mapping: ward **member → writer**, ward
  **admin → admin**, unknown → **reader** (write access gates the MCP mutation
  tools).
- **Plugin tokens (kept).** `eda_p_*` tokens — minted by the
  `mint-plugin-token` CLI, stored in `plugin_tokens.json` under the auth dir —
  still guard the KiCad plugin sync endpoint, checked **before** the ward
  bearer on `/api/sync-kicad-pcb/*`.
- **Dev bypass.** `NETLISP_DEV` grants a local admin identity to a loopback,
  unproxied request (env opt-in) — no wardd needed for local development.
- **Config (env / `.env`).** `WARD_VERIFY_URL`, `WARD_LOGIN_URL`,
  `WARD_INTROSPECT_URL`, `WARD_SERVICE_NAME` (default `eda`),
  `WARD_CACHE_TTL_SECS` (default `30`, the revocation-lag bound). Unset → fail
  closed (`503`) outside the dev bypass. Adapter: `src/serve/ward_auth.zig`
  (HTTP seam in `src/infra/net.zig`).

Everything netlisp used to host itself is **gone**: the `/account` page and
OAuth client minting (the `eda_c_*` / `eda_s_*` client-id/secret flow), all
`/auth/*` passkey/login/invite pages, all `/oauth/*` authorization-server
endpoints, `GET /.well-known/oauth-authorization-server`, the `mint-invite`
CLI, and the `users.json` / `sessions.json` / `credentials.json` /
`invites.json` / `oauth_clients.json` / `oauth_tokens.json` sidecars.

## Testing

```bash
# Unit tests (also runs Guardian checks)
zig build test

# Build all designs
for d in pma3-14ln stm32n6 adf5901 tpsm84338 lt3045 power-6v; do
  zig build run -- build --project-dir projects/designs --push $d
done
```

### Fuzzing

The hand-rolled codecs that parse **untrusted** input (S-expressions via
MCP/HTTP/file import, DEFLATE, `.kicad_pcb`, the fab-package ZIP, PNG) carry
`std.testing.fuzz` harnesses. Their oracles are property-based: the sexpr
parser never crashes and its printed output re-parses to a fixed point; DEFLATE
is a true round-trip (`inflate(deflateRaw(x)) == x` via std's inflater); the
`.kicad_pcb` reader and ZIP/PNG encoders never crash and stay well-formed on
arbitrary bytes.

- **Smoke mode (default, every `zig build test`).** With the suite built
  normally, `std.testing.fuzz` just replays the harness's seed corpus plus the
  empty input once — a cheap regression check, run under `testing.allocator` so
  a leak on any path fails. This is what the gate relies on.
- **Deep mode (`zig build test --fuzz`) is broken on Zig 0.15.1.** The build
  system's fuzzer driver crashes inside `std/Build/Fuzz.zig` (a `pcs[]` indexing
  bug) before any harness runs, so coverage-guided fuzzing is unavailable on
  this toolchain. The harnesses are written to run either way; re-enable deep
  fuzzing once the toolchain is fixed.
- **Presence gate.** `guardian.toml [fuzz_presence] modules = [...]` lists the
  fuzzed files; Guardian fails the build if any listed module loses its
  `std.testing.fuzz` call, so the coverage can't silently lapse.

## Worktrees

This repo routinely has several git worktrees in flight under `.claude/worktrees/` (one per feature branch). The directory is `.gitignore`d. A few rules keep them from colliding:

- **Never edit Zig code directly on `main` — always work in a worktree.** Any change to the compiler/server source (`src/**/*.zig`, `build.zig`, `build.zig.zon`) must be made on a feature branch in its own worktree under `.claude/worktrees/` (`git worktree add .claude/worktrees/<short-name> -b <branch>`) — do all edits, builds, and commits there. `main` is for merging finished code branches into and for rebuilding/deploying prod — never for in-progress code edits. Editing `main`'s checkout directly risks loose state being swept into auto-commits and silently reverting other branches (see the next rule). When a branch is ready, merge it into `main` (`--no-ff`, "Merge: …"); a local `post-merge` git hook then auto-rebuilds (ReleaseSmall — see the next bullet) and restarts prod for you, so you don't run the build/restart by hand.
- **Merging into `main` auto-deploys prod (2026-06-17).** A local git `post-merge` hook (`.git/hooks/post-merge` → detached `.git/hooks/deploy-prod.sh`; both untracked and machine-local, not version-controlled) runs `zig build -Doptimize=ReleaseSafe` in the main checkout and `systemctl --user restart netlisp.service` on every merge that lands on `main`. **Build mode is ReleaseSafe** (switched from ReleaseSmall 2026-07-11, wave-3 cast-safety audit): keeps bounds/overflow/cast safety checks in the prod server, so corrupt or hostile input panics cleanly (systemd restarts in ~2s) instead of silently corrupting board data. Compile time sits between ReleaseSmall (~60s) and ReleaseFast (~3m20s); flip the two `-Doptimize` lines in `deploy-prod.sh` to trade safety for speed/size if ever needed. Because the CLAUDE.md rule above mandates `--no-ff`, a merge commit always fires it; it's branch-guarded, so merges on feature branches in worktrees no-op. It runs **detached** (so `git merge` returns immediately instead of blocking ~1 min on the compile), serializes concurrent deploys with `flock`, and restarts **only on a successful build** — a failed build leaves prod on its previous working binary. So after merging a fix into main, **don't manually rebuild/restart** — just watch `.git/deploy-on-merge.log` (e.g. `tail -f`). Disable with `chmod -x .git/hooks/post-merge` (re-enable with `chmod +x`); `DEPLOY_DRY_RUN=1` makes the worker log-only. The manual deploy (`zig build -Doptimize=ReleaseSafe` in the main checkout + `systemctl --user restart netlisp.service`) is still the path for off-merge builds or when the hook is disabled.
- **Design files and docs may be edited directly on `main`.** Design sources (`.sexp` files under `projects/designs/`) and documentation (`.md` files — `CLAUDE.md`, `SPEC.md`, `*.notes.md`, etc.) don't rebuild the binary, so they can be changed, committed, and pushed straight from the `main` checkout without a worktree. Still keep the tree clean: commit such edits promptly rather than leaving them loose (see the next rule).
- **Keep the main worktree's tree clean.** If `git status` on main shows anything (uncommitted edits, staged deletions, untracked scratch files), deal with it *before* asking anything to merge branches — uncommitted state on main gets swept into auto-commits and can silently revert work from other branches. Lesson learned the hard way: a partial-revert sitting staged on main deleted the schematic sidebar when another branch was merged.
- **Commit WIP; don't leave it dangling.** Across-session work should land as a `WIP: ...` commit on the feature branch (fine to squash later), never as loose edits in a worktree. Stashes are invisible to automation and to a future you — prefer a commit.
- **Rebase worktree branches onto main weekly or before handoff.** Branches that drift more than a few commits behind main produce wide conflicts and, worse, context-line drift (e.g. a function call surviving a rebase after the function itself was deleted upstream). Small, frequent rebases keep the delta legible.
- **Before bulk-merging worktrees, inventory them.** Run `git status` in each worktree (a `git worktree list` + loop works well). Flag any uncommitted work and decide commit-vs-discard *per worktree* before anything touches main.
- **Retire merged worktrees.** `git worktree remove <path> && git branch -D <branch>` once a branch is in main. Fewer live worktrees = fewer places for drift to hide.
- **Audit `git stash list` periodically.** Stashes labelled against deleted branches are almost always forgotten work worth reviewing or dropping.
