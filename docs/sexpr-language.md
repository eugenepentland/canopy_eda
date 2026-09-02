# S-Expression Design Language

> Moved verbatim from CLAUDE.md (2026-08-19); linked from its Reference Docs section.

**Machine-checked reference: [docs/language-forms.md](docs/language-forms.md).**
Auto-generated from the evaluator's dispatch tables — every special form,
builtin operator, fmt directive, SI numeric suffix, design-scope form (with
arity + allowed scopes), and section-classifier keyword, plus the compound
forms whose bodies have a grammar of their own: `(instance …)` and
`(pins …)` sub-forms, `(sub-block …)` children (including `(bridge …)`),
`(port …)` options, the identity/layout markers, and the
`(component …)` library fields. Those tables are the same lists the
evaluator derives its accepted-children checks from, and a coverage test
walks `src/eval` for head atoms no registry names, so the reference cannot
drift. Consult it for the grammar inventory; the subsections below cover
conventions and idiomatic usage only.

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
   `lib/modules/` and brought in as a `(sub-block …)`. A `(sub-block …)`
   evaluates correctly *inside* a `(section …)` and inside a sub-section —
   its parts flatten into the netlist and its `(bridge …)` ties are applied
   exactly as at design-block top level, and the enclosing section
   additionally records it as a hosted block for the system-overview
   diagram. House style in `stm32n6.sexp` still puts the sub-block at top
   level immediately after its section (e.g. `(section "USB" …)` then
   `(sub-block "usb" (usb-c-hs))`) so the consolidated rail `(net …)` forms
   that wire it sit beside it; both placements are supported.
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
math, and multi-bit shorthand — `(bus-port …)` / `(bus-net …)` at section
scope, and `(bus …)` inside a `(pins …)` block or an `(instance …)` body;
see `stm32n6.sexp` for each.

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
  designs whose body is mostly `(sub-block …)` calls (rail-chain boards,
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

### Component datasheet link: `(datasheet "file.pdf")`

A library part declares the datasheets that document it with one `(datasheet
"…")` field per PDF, inside its `lib/components/<name>.sexp` definition:

```lisp
(component lm66100
  (footprint sc70-6)
  (datasheet "LM66100DCKR.pdf"))
```

The value is either a filename in `lib/datasheets/` or an absolute `http(s)`
URL, for a PDF that may not be redistributed. Repeat the field for a part
documented by several PDFs (a datasheet plus an errata or an app note).

**This field is the linkage, and nothing else is.** A PDF sitting in
`lib/datasheets/` that no component declares documents nothing: this form is
what fills each placed instance's `docs.datasheets`, what `describe_component`
reports under `datasheets`, what the `(datasheet-review …)` record below must
name, and what the datasheet coverage check requires of every active IC.

Three CLI tools cover the whole chain, so an agent never hand-edits the library
for this:

| Tool | Args | Does |
| --- | --- | --- |
| `fetch_datasheet` | `{url, name?, overwrite?}` | Download a PDF from an explicit manufacturer URL into `lib/datasheets/`. Content-sniffs `%PDF`, sanitizes the target name into that one directory, caps the transfer at 64 MiB / 90 s. Re-fetching identical bytes is a no-op (`status:"unchanged"`); a same-name fetch whose bytes DIFFER is refused unless `overwrite:true`, because a silent replacement would invalidate the `sha256` every review cites. Returns `{ok,name,sha256,bytes,status}`. |
| `attach_datasheet` | `{component, file}` | Splice `(datasheet "file")` into `lib/components/<component>.sexp`. Verifies a local name exists in `lib/datasheets/`; already-linked returns `status:"already_linked"` instead of duplicating. |
| `read_datasheet` | `{name, offset?, limit?}` | Extract a window of the PDF's text, and report the current `sha256` to record in the review. |

`download_datasheet {part_number}` remains the catalogue path (Component Search
Engine, then DigiKey); `fetch_datasheet` is the escape hatch for every part
those two do not carry.

### Datasheet review: `(datasheet-review …)`

A part's requirement review binds to an exact PDF, by digest:

```lisp
(component lm66100
  (datasheet "LM66100DCKR.pdf")
  (datasheet-review
    (datasheet "LM66100DCKR.pdf")
    (sha256 "<64 lowercase hex characters>")
    (status complete)
    (reviewed-by "agent-or-human")
    (date "YYYY-MM-DD")
    (category supply)
    (category-na sequencing "reason this topic is not applicable")))
```

The `(datasheet …)` inside the review must name a PDF the component itself
declares. `read_datasheet` and `fetch_datasheet` both return the current
`sha256`, so replacing the file automatically makes the review stale — which is
exactly why `fetch_datasheet` refuses a same-name/different-bytes overwrite by
default. `netlisp check --profile preflight` gates incomplete reviews; the full
category list is in `docs/language-forms.md` under **Datasheet review
preflight**.

### Component class: `(class <key>)`

A library component binds itself to a component-class review profile — the
obligations a part carries because of the kind of part it is:

```lisp
(component lt3045edd#pbf
  (class ldo)
  …)
```

Keys: `ldo`, `switching-regulator`, `protection`, `load-switch`, `mcu`,
`level-shifter`, `pll-loop`, `integrated-synthesizer`, `clock-jitter-cleaner`,
`crystal-oscillator`, `rf-amplifier`, `mixer`, `rf-attenuator-switch`,
`rf-passive`, `rf-detector`, `op-amp`, `sensor`, `connectors`,
`power-path-passives`. Without the field the class is inferred from the pin
function names (a `LO`/`RF`/`IF` trio is a mixer, `VCCA`+`VCCB` a level
shifter, `SW`+`FB` a switching regulator, …); `describe_component` reports
the authored key. The prose profiles — what a reviewer must still judge per
class — live beside the designs in `docs/review-profiles/`.

`netlisp check --profile release` (and `run_checks {profile:"release"}`)
reports each obligation the tool can see as a `profile_incomplete` finding —
informational while authoring, a warning in preflight, an error at release:
supply pins with no `(check (voltage-range …))` or decoupling check, no
`(i-typ …)`/`(i-max …)` on any supply pin of the instance, control pins
without `(electrical …)` thresholds, a complete review missing the class's
extra categories, a missing `(thermal …)` on a dissipating class, and a
`pll-loop`/`mixer` class whose design carries no `(pll-loop …)` /
`(frequency-plan …)` form in gate mode. The release profile also demands at
least one cited `(requirement …)` on every active part and surfaces the
evaluator's own warnings (an unknown sub-form is an error).

### Physical requirement checks: `cap-rating`, `max-distance`, `sequence`

Most of the library's `(requirement "…")` prose is reviewer-judged. Three
`(check …)` primitives make the three biggest prose clusters — capacitor
voltage rating, placement distance, and power sequencing — executable. Each
reads evidence the older primitives do not: the derived DC envelope of a net,
the saved layout's geometry, and the derived rail power-up order. The full
grammar table is generated into `docs/language-forms.md`; below is what each
one is for, with a real library requirement converted.

**`(cap-rating (pin "A") (pin "B") [(min-ratio X)] [(min-v V)])`** — every
capacitor bridging the nets on pins A and B must carry a voltage-rating
attribute at least `X` times the worst-case DC potential `eval/net_envelopes`
derives across those two nets, and at least `V` volts. Writing neither bound
applies **1.5x**, the conventional ceramic derating floor: an X5R/X7R part
sitting at its own marked rating has already lost most of its capacitance to DC
bias, so a bare 1.0x rule passes parts that do not work.

```lisp
;; BQ25185DLHR: "IN (pin 10) operates from 3.2 V to 5.5 V for charging;
;;  absolute maximum is -2 V to 18.5 V (VIN_OVP). The input cap must be
;;  rated for the worst-case IN voltage."
(requirement "The input cap must be rated for the worst-case IN voltage."
  (ref "BQ25185DLHR.pdf")
  (check (cap-rating (pin "IN") (pin "GND") (min-ratio 1.5))))
```

Three outcomes, and only one of them is green. A rated cap below the bound is
an **error**. A cap carrying no voltage attribute is **unproven** — never a
pass, because nothing was measured; author the rating
(`(cap-0402 "1uF" x7r "10%" "16V")`) and it decides. A net whose envelope the
tool cannot derive is **unproven** too, naming the net: give the rail a
`(port … (nominal …))` upstream, or state it outright with
`(net-envelope "VBUS" (rated 0 5.5) "USB VBUS")`.

**`(max-distance (pin "P") (kind C|R|L|any) (mm D) [(min-value X)] [(max-value Y)])`**
— the nearest matching passive on pin P's net must sit within D mm of that pad
**in the saved layout**. The value window is in the kind's natural unit (Ω / µH
/ µF), exactly like `series-element`.

```lisp
;; ADP7118: "Input decoupling: place a 1 uF ceramic capacitor from VIN to
;;  GND as close to the device as possible."
(requirement "Input decoupling: place a 1 uF ceramic capacitor from VIN to GND as close to the device as possible."
  (ref "adp7118.pdf" (page 14))
  (check (max-distance (pin "VIN") (kind C) (mm 3.0) (min-value 0.9))))
```

`netlisp check` has no geometry, so this rule is **layout-deferred** there: the
finding is informational and says which lint carries the verdict. The one thing
the netlist *can* settle it settles — a net with no qualifying passive at all
is an **error**, because no placement could ever satisfy the rule. The
measurement itself is the **`req-distance-far` layout lint** (a warning,
alongside `decap-far` and `bound-far`), which reports the nearest qualifying
passive, its gap and the budget, and appears in `/api/pcb-describe`'s `lint[]`
and in `describe_pcb_layout`. Pin, pad and candidate list are resolved once in
the evaluator (`req_physical_checks.resolveDistanceRules`) and shared, the same
contract `(near …)` uses, so the checker and the lint cannot disagree about
which pad or which parts a rule is about.

**`(sequence (pin "A") before (pin "B") [(margin-ms N)])`** — the supply rail on
pin A must come up before the rail on pin B, judged against the power-up order
`eval/power_sequencing` derives from the design's `(enable …)` declarations and
PG chains.

```lisp
;; BNO080/085: "VDD must reach its specified level before or at the same
;;  time as VDDIO during power-up; reverse sequencing is not permitted"
(requirement "VDD must reach its specified level before or at the same time as VDDIO during power-up; reverse sequencing is not permitted"
  (ref "BNO080_085_Datasheet-3196201.pdf" (page 45))
  (check (sequence (pin "VDD") before (pin "VDDIO"))))
```

A determined order that satisfies the rule passes; a determined order that
reverses it is an **error**. Everything else is **unproven**, naming both rails
and what would settle it — an `(enable "NET")` on the regulator's output port,
or a PG chain to the upstream rail. Two rails the enable graph leaves at the
same order count as undetermined, not as a pass: neither gates the other.
`margin-ms` is recorded and echoed in the verdict but **not enforced** — the
sequencing model derives a topological order, not ramp times, so there is
nothing in it a millisecond could be compared against.

Because none of the three can always reach a verdict, requirement results carry
two outcomes beyond pass/fail/pending: `unproven` (a **warning** in every
profile, including release — it is authoring work or an explicit
`(verifies …)` sign-off away from closing) and `layout_deferred`
(**informational**, since no schematic edit can clear it). Both show as their
own pill in the review UI and as their own status in `netlisp check`; run with
`--severity info` to see the deferred ones.

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

`PIN` is a pad id or a pinout **function name**, and a function name resolves
through the **target IC's** pinout — not the capacitor's, which has none. That
happens in a post-build pass (`builders.resolveDecoupleTargets`) once every
instance exists, so `(decouples "U1" VIN)` finds U1's VIN pad whether U1 is
declared above or below the cap. A pad id is checked first and passes through
untouched (so a connector pinout that names contact 4 "4" can't re-point a pad
binding), and a token that is neither stays as written for the
`decoupling_binding` ERC check to report rather than being silently rewritten.
A function name that a part repeats on several pads (a USB-C `VBUS`, a duplicated
MCU EXTI) resolves to the **lowest** pad id — deterministic, where the old
first-hash-match could bind a different pad after an unrelated edit — and warns
naming the duplicates so you can spell the pad you meant.

**Both halves of the binding are load-bearing.** The IC is carried through the
flatten alongside the pad (with the same `sub-block/` prefix the cap's ref-des
takes), because a pad number alone cannot say *which* part owns it: on a rail
shared by several ICs — or a rail that also lands on a test point — matching the
pad string alone binds to whichever endpoint the net happens to list first.
Measured 2026-08-12, that mis-bound 18 caps on barracuda (five LDO input caps
docked onto **test points**), 42 on cyclops-analog, 37 on labstation and 3 on
stm32n6. A binding naming an IC that is not on the cap's net now binds nothing
rather than guessing, and the cap reads as unbound to the `decouple-unbound`
lint. `(decouples rail)` is the explicit opt-out for a cap that
genuinely serves the whole rail (a reservoir / deliberately rail-level bypass).
The two `(decouple … per-pin …)` shorthands above already supply this binding
automatically — each generated cap records its host ref and resolved pad as real
`(decouples …)` fields, so a **function-name** pin list (`per-pin psram VDD_1
VDD_2`) binds exactly like a numeric one; its structural id is unchanged, so no
board re-stamps. Use `(decouples …)` when you keep hand-named cap instances
(and their stable ids).
The `/pcb-layout` viewer's default-on **Placement guides** layer draws these
exact-pin targets independently of the electrical ratsnest, so they remain
visible after copper connects the pads and when a declared plane carries the
rail. **Net colours** also colours the power leg of each guide by its rail. A
guide whose hub pad the design DECLARED is drawn solid and its tooltip names the
pad (`pin 24 (declared)`); one whose target the solver defaulted to the
lowest-numbered supply pad is dashed and reads `(defaulted)` — the same split
`/api/pcb-describe` reports per loop as `"authored"` (always) plus `"pin"` (only
when declared), and the board blob carries as `ep`.

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

### Physical adjacency: `(near "REF" PIN [(own PAD)])`

`(decouples …)` says "this bypass cap serves that supply pin", and carries a
ground return and a measured loop with it. Plenty of other passives are just as
layout-critical without being decoupling caps — a series termination that must
sit at its driver pin, a feedback resistor at the FB pad, an RF matching element
at the port it matches, a bulk cap at the rail's entry pin — and had no way to
say so. `(near …)` is that declaration, and nothing more than that: pure
adjacency.

```scheme
(instance "R_TAP_EN" (res-0402 "1k")
  (pin 1 "GPIO10") (pin 2 "TAP_GPIO10")
  (near "U3" 14))            ;; my leg on GPIO10 sits against U3 pad 14

(instance "C_IN_A" (cap-0805 "22uF")
  (pin 1 "VIN") (pin 2 "GND")
  (near "U1" 4))             ;; a bulk cap, exempt from (decouples) by the 4.7 µF rule

(instance "R_DIV" (res-0402 "10k")
  (pin 1 "VREF") (pin 2 "VREF_TAP")
  (near "U1" 7 (own 2)))     ;; both legs share the target net — say which one docks
```

- **`PIN` is a pad id or a pinout function name**, resolved through the **target's**
  pinout in the same post-build pass `(decouples …)` uses
  (`builders.resolveNearTargets`), so declaration order is irrelevant and a
  passive — which has no pinout of its own — can still name a function. Same
  rules throughout: a pad id is checked first and passes through untouched, a
  function repeated on several pads resolves to the lowest and warns, and a
  token that is neither stays as written for ERC to report.
- **The own leg is inferred**: whichever of the part's pads shares a net with the
  resolved target pin. `(own PAD)` spells it out, and is only needed when BOTH
  legs sit on that net.
- **`(near …)` is not decoupling.** It never produces a `Loop`, so it stays out of
  the inductance score and out of plane stitching, and it neither satisfies nor
  interacts with the `decoupling_unbound` requirement. A part carrying both forms
  is an ERC error — they are different intents, and the placer would otherwise
  have two authored targets with no rule for which wins.

What it changes in placement (`src/placement/near_bind.zig`, resolved once and
shared so the placer, the lint and the facts endpoint can never disagree):

- **Ownership.** A near-bound passive belongs to the part it names, ahead of the
  inferred decoupling-loop and series rungs. This is the case the form exists
  for: a 2-pad part whose legs land on **two different hubs** gets no series
  pairing at all (`pairSeriesLegs` requires one hub), so the net-locality scan
  was free to hand it to the hub the author did not mean.
- **Seed target.** Within that owner the part aims at the exact declared pad,
  above every rung derived from net shape.
- **Force.** One pad-to-pad hug spring at the same `k_prox` the inferred
  single-hub hug pulls with — and it **replaces** that hug rather than stacking
  with it, so the tuned force model gains no new magnitude.
- **Rotation is deliberately untouched.** A series pair decides its rotation from
  the axis between its two matched hub pads; a near binding names ONE pad, so
  there is no axis, and any rule aiming the bound leg at the target would depend
  on where the part ended up — exactly the position-dependent flip
  `seriesPairRot` is written to avoid. Adjacency without rotation is the feature.

Two gates, mirroring the decoupling pair:

- **`invalid_near_binding` ERC (error)** — per block, recursing sub-blocks, so a
  module's adjacency is judged in its own namespace. The named ref must be a
  local instance and must not itself be a passive, the named pin must carry a
  net, the declaring part must be on that net, `(own PAD)` must be on it too,
  only `R/C/L/F/D` parts may declare adjacency, and `(near …)` × `(decouples …)`
  is refused.
- **`bound-far` layout lint (warning)** — the bound leg ended up more than 5 mm
  from the pad it named, measured to the **declared** pad (not min-over-candidates
  the way `decap-far` measures a decoupling leg: a `(near …)` names one pad on
  purpose). Its twin `near-unresolved` reports a binding that resolved to nothing
  and names the cause, so a declaration that silently did nothing is never
  invisible. Both surface in `/api/pcb-describe`'s `lint[]`, alongside a
  `bindings[]` array of `{ref, own_pad, target_ref, target_pad, net, gap_mm,
  resolved}` — kept out of `loops[]` because a near binding has no ground return
  and nothing belonging in the nH column a reader scans loops for.

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

### Placement class pins: `(module-policy …)`

The placer, the routing order and the `layout_class_inferred` ERC info all
classify nets by name (`input_rail`, `switch_node`, `clock`, `rf`, `feedback`,
`analog`, `power`, `ground`, `control`, `signal`). When the guess is wrong, or
when you want the decision recorded so the info stops appearing, pin it:

```lisp
(module-policy
  (net-class "V_24V_CLEAN" power)      ;; a clean post-LDO rail, not an input rail
  (net-class "REF_ADF" clock)
  (net-class "BOOST25_SW" switch_node)) ;; a bare leaf reaches the module-local net
```

Design-block scope only. The net is the flattened name, or a bare leaf that
matches every module-local net of that name. A pinned class is final — the
hub-plus-inductor switch-node upgrade does not apply — and a pinned net is no
longer reported as inferred. Unknown class atoms are warned and dropped.

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

### Differential port pairs: `(diff-port …)`

A differential boundary signal is two ports that must stay identical apart
from one suffix. `(diff-port …)` writes the pair once — it expands to
`BASE_P` and `BASE_N`, replays every trailing modifier (direction, kind,
`optional`, `(rated …)`, `(side …)`, `(electrical …)`, a long-form net base)
onto both lanes, and defaults their kind to `differential`, so the result is
indistinguishable from the two hand-written lines it replaces.

```scheme
;; lib/modules/ad7380-channel.sexp declares its four analog inputs as eight
;; lines that differ only in one letter:
(port "AINA_EXT_P" in differential)
(port "AINA_EXT_N" in differential)
(port "AINB_EXT_P" in differential)
(port "AINB_EXT_N" in differential)
(port "AINC_EXT_P" in differential)
(port "AINC_EXT_N" in differential)
(port "AIND_EXT_P" in differential)
(port "AIND_EXT_N" in differential)

;; The same eight ports, as four paired declarations:
(diff-port "AINA_EXT" in)
(diff-port "AINB_EXT" in)
(diff-port "AINC_EXT" in)
(diff-port "AIND_EXT" in)
```

Unlike two hand-written ports, the expansion **records the pairing** on both
lanes. ERC reads it as a both-or-neither contract: wiring `AINA_EXT_P` and
leaving `AINA_EXT_N` open — inside the module, or from a parent that ties only
one lane of a sub-block — is reported as `diff_pair_half_connected`. A
hand-written `_P`/`_N` pair carries no pairing and is never second-guessed.

Two spellings beyond the default:

```scheme
;; Non-default lane suffixes (the corpus also uses "+"/"-" and bare P/N):
(diff-port "RFIN1" in rf (suffixes "+" "-"))     ;; → RFIN1+ / RFIN1-

;; Long form — the net base is suffixed per lane, like the name:
(diff-port "RFIN1" "LNA_IN" in)                  ;; RFIN1_P on net LNA_IN_P
```

An explicit signal-type word (`rf`, `clock`, …) wins over the `differential`
default; the pairing lives in its own field, not in that word.

### Iterating a list: `(for name (item…) body…)`

`(repeat name start end body…)` counts integers. `(for …)` walks a literal
list, so a loop variable can be a channel letter, a lane suffix, or any
expression — including `(let …)`-bound values. Each item is evaluated in the
enclosing scope, then bound in a fresh child scope for one pass over the body.
Both forms work in expression position and in a `(design-block …)` body.

```scheme
;; The anti-alias filter block of lib/modules/ad7380-channel.sexp — sixteen
;; hand-copied instance lines, four per channel — as one loop nest:
(for ch ("A" "B" "C" "D")
  (for leg ("P" "N")
    (instance (fmt "R_F~a~a" ch leg) (res-0201 "33R")
      (pin 1 (fmt "AIN~a_EXT_~a" ch leg)) (pin 2 (fmt "AIN~a_~a" ch leg)))
    (instance (fmt "C_F~a~a" ch leg) (cap-0201 "68pF")
      (pin 1 (fmt "AIN~a_~a" ch leg)) (pin 2 "GND"))))

;; A string item composes ref-des names through (fmt …) and drops straight
;; into a net name:
(for ch ("A" "B" "C" "D")
  (instance (fmt "R_SD~a" ch) (res-0201 "100R")
    (pin 1 (fmt "SDO~a_RAW" ch)) (pin 2 (fmt "SDO~a" ch))))
```

Identity works exactly as it does for `repeat`: the `(for …)` form owns one
source-resident `(id …)` anchor, and each generated child's id derives from
that anchor plus its `origin_key` and the item's **0-based ordinal**, so ids
are stable across rebuilds without minting an impossible `(id …)` per
iteration. A `(ids ("R_FAP@0" <hex8>) …)` sidecar on the loop form pins
migrated identities when a hand-unrolled block is folded into a `for`.

### Sub-block port wiring: `(bridge …)`

```scheme
;; Prefix idiom — one board net per port, sharing a peripheral prefix.
(sub-block "imu" (icm42688)
  (bridge "IMU_" SCK MOSI MISO (rename CS NCS)))
;;   →  (net "IMU_SCK"  "imu/SCK")
;;      (net "IMU_MOSI" "imu/MOSI")
;;      (net "IMU_MISO" "imu/MISO")
;;      (net "IMU_NCS"  "imu/CS")

;; Empty-prefix idiom — the form reads as a port → board-net map.
(sub-block "dsa" (bcuda-dsa-hmc1119)
  (bridge "" (rename LPF_RF IF1_LNA) (rename DSA_RF IF1_DSA)
             V_3V3A (rename SPI_DSA_SCK SPI_SCK) SPI_DSA_CSN GND)
  (id a625bd1e))
```

`(bridge "PREFIX" PORT… (rename PORT SUFFIX)…)` is how hierarchy is wired.
Each bridged port `P` emits **one net tie** between the board net
`PREFIX<suffix>` and the module net `<sub-block-name>/P`, where `<suffix>`
is `P` itself unless a `(rename P SUFFIX)` overrides it. It collapses the
per-port `(net "BOARD_NET" "sub/PORT")` lines a peripheral sub-block would
otherwise need at the design top level, and it is exactly equivalent to
writing them out — nothing else changes.

Two idioms are in use, both above:

- **Shared prefix** for a peripheral whose board nets are named after it.
  Bare port names pass through (`SCK` → `IMU_SCK`); a `(rename …)` covers
  the odd one out (`CS` → `IMU_NCS`).
- **Empty prefix + one `(rename PORT NET)` per port**, which reads as a
  port-to-net map and is the dominant style on `barracuda.sexp`. A bare
  port name there means "same name on both sides" (`GND`, `V_3V3A`).

Power and ground ports are usually left *off* the bridge list and wired
through the consolidated `(net …)` rail forms instead — one `(net …)` per
rail, so the validator does not see a rail split across sections. Bridge
them only when the module's rail name genuinely differs from the board's
(`(rename V_3V3 V_3V3_LMX)`).

A `(sub-block …)` accepts only `(bridge …)`, `(id …)`, `(ids …)` and
`(reflow)` as trailing children; anything else warns. See
[docs/language-forms.md § Sub-block sub-forms](language-forms.md).

### The four unrelated `(group …)` forms

`group` is overloaded across four grammars that share nothing but the word:

| Where | Shape | Meaning |
| --- | --- | --- |
| Design-block scope | `(group "name" ("R1" "R2" …))` | Bundle ref-des components for the schematic renderer's visual grouping pass. Members are a **list**. |
| `(diagram-layout …)` | `(group "Label" "a" "b" …)` | Labelled region over **variadic block keys** (section names / sub-block handles) on the block diagram. |
| `(pins "REF" …)` | `(group "label")` | Label every pin the block declares so the schematic draws them as one named group. |
| `(rough …)` | `(group "name" "REF"…)` | A PCB rough-placement cluster of ref-des strings. |

The generated reference lists each in its own table; when in doubt, check
the arity — a parenthesised member list means the design-scope form.
