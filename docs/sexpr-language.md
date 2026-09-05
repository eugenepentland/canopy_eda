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
inside `(block …)` sub-blocks: they take a renumber-safe `TP` ref-des and
are exempt from the `IC has no ground` ERC. That instance spelling is the
recommended one. A bare `(test-point "TP" "NET")` places **the same physical
pad** — it is a second spelling for the same part, plus its `(purpose …)` /
`(required-for …)` metadata, and it carries a `deprecated_form` info saying
so. Only `(test-point "TP" "NET" (virtual))` is the schematic-only marker with
no exported pad, and that form has no alias and is not deprecated.

### Pin function names, and `rewrite-pins-by-name`

Every `PIN` token — in `(pin …)`, `(strap-ok …)`, `(nc-ok …)`, `(near …)` and
`(decouples …)` — is either a physical pad id **or** a pinout **function
name**, and the evaluator resolves the name through the part's
`lib/pinouts/<name>.sexp`. The name is the better spelling: it says what the
pin *is*, it makes a strap or no-connect sign-off read as its own reason, and
a pinout regeneration that renumbers pads carries it along.

```scheme
(instance "U1" lt3045edd#pbf
  (pin 5 "GND")                                ;; ILIM   ← the comment IS the pinout
  (strap-ok 5 "ILIM->GND selects the default current limit"))

(instance "U1" lt3045edd#pbf
  (pin ILIM "GND")                             ;; …so write it instead
  (strap-ok ILIM "ILIM->GND selects the default current limit"))
```

The **`rewrite-pins-by-name` CLI tool** performs that conversion on a whole
module or board, in place:

```bash
netlisp tool rewrite-pins-by-name --project-dir projects/designs \
  --args '{"file": "lib/modules/bcuda-lt3045-ldo.sexp"}'          # diff only
netlisp tool rewrite-pins-by-name --project-dir projects/designs \
  --args '{"file": "src/boards/barracuda/barracuda.sexp", "write": true}'
```

- Text is spliced at the parser's **byte spans**, so every comment, blank line
  and column of alignment outside the replaced token survives byte for byte.
  (The now-redundant trailing `;; ILIM` comments are left for you to delete.)
- A pad is rewritten **only** when the evaluator's own resolver, re-run on the
  proposed spelling, returns the very pad the original bound to. That is why
  `(near "REF" PAD)` and `(decouples "REF" PAD)` — which resolve through the
  **target's** pinout, pad id first — are rewritten under their own rule, and
  why a name the tokenizer would re-read as something else (`5V` as an SI
  value) is quoted or skipped.
- Skipped, with the reason reported: a function name **repeated on several
  pads** (it cannot say which one it means), a pad the pinout does not carry,
  a part with **no pinout file**, and a **positional** part whose pinout names
  every pad after its own number — a connector's `(pin 09 "09")`, or the
  generic two-terminal `cap`/`res`/`ind` pinouts.
- The default is `write:false`: it returns the unified diff and the skip list
  without touching the file. Either way the ORIGINAL and REWRITTEN sources are
  both evaluated and flattened, and the write is **refused** unless their
  netlists and their resolved `(decouples …)`/`(near …)`/`(strap-ok …)`/
  `(nc-ok …)` bindings match exactly. A file that does not parse or does not
  evaluate is refused outright.
- `refs: ["U1"]` narrows the run to named instances.

Prove a run independently the same way the differential tier does:
`netlisp netlist-dump <name>` before and after, compared with `diff -I '^#'`.

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

- **Name** — 1–4 words, capitalized, functional role first. Name it for the
  reader, not for the classifier: **pin the column with `(category <key>)`**
  in the section body and the name is free to say whatever is clearest.
  `(category …)` is the source of truth — `classifySection` consults it
  first, and only a section without one falls back to case-insensitive
  keyword matching on the name. That fallback is a guess, so it announces
  itself: a section categorised by a name keyword gets a
  `section_category_inferred` **info** from `netlisp check` naming the
  category it landed in and the `(category …)` line that would pin it. The
  valid keys and the fallback keyword→category table are both auto-generated
  into [docs/language-forms.md § Section-name classifier keywords](docs/language-forms.md)
  from the same tables the classifier walks (don't copy them here — they
  would drift).
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

### `(block …)`: one word for a design and for a module

`(block …)` is the primary spelling for both halves of the definition
vocabulary, and which half it is comes from the name:

```scheme
;; A quoted name is an eager design root — a whole board or a whole file.
(block "Barracuda Signal Generator"
  (instance "U1" …)
  …)

;; A bare atom plus a parameter list is a parameterized, embeddable
;; definition, instantiated with (sub-block "pwr" (tpsm84338 …)).
(block tpsm84338 (rfbt rfbb rled)
  …)
```

`(design-block "name" …)` and `(defmodule name (params…) …)` are **permanent
aliases**, routed to the same two handlers. They are not deprecated, they emit
no info, and the corpus is full of them — a design written either way is
identical in every output. Prefer `(block …)` in new work because the two
things really are one thing (a module with no parameters and a design differ
only in whether anything instantiates them), and keep the older spelling where
a file already uses it consistently.

### Parameterized modules

```scheme
(block tpsm84338 (rfbt rfbb rled)          ;; ≡ (defmodule tpsm84338 …)
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
(block tpsm84338 ((rfbt 220k) (rfbb 47k) (rled 1k)) …)
```

**A parameter may be a component, not just a number.** Module arguments are
ordinary values, and a component family call like `(cap-0402 "100nF")` is one
of them — so a module can take *the part itself* as a parameter and place it
with `(instance "C1" bypass …)`. That is how one filter module serves a board
that wants an 0402 100 nF bypass and another that wants an 0603 1 µF:

```scheme
(block filt ((bypass (cap-0402 "100nF")))     ;; default part, overridable
  (design-block "Filter"
    (instance "C1" bypass (pin 1 "OUT") (pin 2 "GND"))
    (instance "R1" (res-0402 "10k") (pin 1 "IN") (pin 2 "OUT"))
    (port "IN" in) (port "OUT" out) (port "GND" bidi)))

(sub-block "a" (filt))                        ;; a/C… is cap-0402 100nF
(sub-block "b" (filt (bypass (cap-0603 "1uF")))) ;; b/C… is cap-0603 1uF
```

Both the footprint and the value follow the argument — the emitted design
carries `"cap-0402" "100nF"` for the first and `"cap-0603" "1uF"` for the
second — so this is a real part substitution, not a value override. The
default in the parameter list evaluates at call time like any other, so the
module still renders standalone with no arguments.

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

A trailing `%` closes a literal the same way a unit letter does: `10%`, `0.1%`.
Like `V` and `F`, the sign carries **no scale** — `10%` is the number `10` that
remembers it was written as a percentage, not `0.1`. Tolerances are authored,
compared and printed in percent everywhere in this language (`(expect 2.105
5%)`, `(tolerance "10%")`, the parts-table `(tolerance …)` column), so the
magnitude you wrote is the magnitude every consumer reads. The sign is only a
literal when it ENDS the token, which leaves `(% a b)` untouched.

**A suffixed literal keeps its spelling.** The number is still a plain `f64` in
arithmetic — `(let x 100nF)` then `(* x 2)` is 2e-7 as before — but the source
text travels with it, so anywhere a number is written back out as a *part
value* it renders by its unit rather than by its magnitude:

```lisp
(pullup "SDA" 4.7k "V_3V3")      ; the resistor's value is 4.7k, not 4700
(pullup "SDA" 100nF "V_3V3")     ; rejected: 100nF is not a resistance value
(cap-0402 100nF)                 ; same as (cap-0402 "100nF")
```

Before this, `100nF` reached the BOM as the number `1e-7` rendered `0.0000001`
— a value no parts row matches and that the declared-kind check could not tell
from a resistance. Every shorthand that takes a value (`pullup`, `pulldown`,
`divider`, `led`'s `(r …)`) and every component-family call reads the spelling.

### Typed attributes on a family instantiation

A component-family call takes a value and then any number of attributes. They
may be written bare or keyed, and the two mean exactly the same thing:

```lisp
(cap-0402 "1uF" x7r "10%" "25V")
(cap-0402 "1uF" (dielectric x7r) (tolerance 10%) (rating 25V))
(res-0402-0p1 rset-str (tolerance 0.1%) (power 0.063W) (rating 50V) (tempco 25ppm/C))
(cap-0402 "100nF" (esr 10mR) (esl 0.4nH))
```

Each attribute that can be *placed* lands on the instance as a property, and
that property is the one source every consumer reads — the BOM, `lib/parts/`
row selection, the capacitor-rating check, the PDN impedance screen, and the
KiCad export. Consumers keep their old attribute-text scan only as a fallback
for attributes nothing can place.

| Key | Property | Example | Also selects a `lib/parts/` row |
| --- | --- | --- | --- |
| `rating`, `voltage` | `voltage` | `(rating 25V)` | yes |
| `dielectric` | `dielectric` | `(dielectric x7r)` | yes |
| `tolerance` | `tolerance` | `(tolerance 10%)` | yes |
| `power` | `power` | `(power 0.063W)` | yes |
| `current` | `current` | `(current 1A)` | yes |
| `tempco`, `tcr` | `tempco` | `(tempco 25ppm/C)` | yes |
| `esr` | `esr` (+ `pdn-esr-ohm`) | `(esr 10mR)` | no |
| `esl` | `esl` (+ `pdn-esl-h`) | `(esl 0.4nH)` | no |

`esr` and `esl` are analysis overrides, not selection columns: no parts row is
keyed by them, so adding them to the row-matching attribute list would make the
release-gate lookup reject every row. They additionally decode into the
`pdn-esr-ohm` / `pdn-esl-h` numbers the PDN screen already reads.

**A keyed attribute is checked.** An unknown key is an error with a
did-you-mean, and setting the same key twice is an error. That strictness is
safe because keyed attributes are new syntax with no existing spellings to
protect.

**A bare attribute is classified, never rejected.** `"25V"` → `voltage`,
`"10%"`/`"0.1%"`/`"±15%"` → `tolerance`, `x5r`/`x7r`/`np0`/`c0g`/`x6s`/`y5v` →
`dielectric`, `"0.063W"` → `power`, `"1A"` → `current`, `"25ppm/C"` → `tempco`.
Anything else — `DNP`, `green`, `jumper`, `tantalum`, a bead's `600R@100MHz` —
stays a raw attribute and reaches the schematic and the parts table exactly as
it did before. When two bare attributes claim one slot the first wins, silently,
because a design that evaluated yesterday must evaluate today.

**When the selected part does not meet the request.** The parts lookup is
deliberately lenient: if no row carries the requested rating it falls back to a
value-only match, and the row's own `(voltage …)` then overrides the authored
one (the row is the physical part). `netlisp check` reports that substitution
as an `attribute_row_mismatch` warning naming both values.

A row is allowed to be **better** than what was asked, and those are silent: a
50 V part where 25 V was asked, a 1% resistor where 5% was asked, a 0.1 W part
where 0.063 W was asked. Headroom ratings (`voltage`, `power`, `current`) must
be at least the authored one; deviation budgets (`tolerance`, `tempco`) must be
no wider. `dielectric` is categorical — an x5r is not a worse x7r, it is a
different part with a different capacitance-versus-bias curve — so any
difference is reported.

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

### Design-owned rules

Everything above is a rule a **component library** hands the design: the
datasheet says the part needs it, so every board placing the part inherits it.
The rules a board's own author writes down had nowhere to live — they ended up
as `(note …)` prose nothing checks, or as a `(requirement …)` bolted onto a
library file that other designs then inherited by accident.

Two forms fix that, accepted at **design-block, section, sub-section and module
scope** (a `(defmodule …)` body is a block, so a module can carry rules about
itself and every instantiation is judged separately):

```lisp
(requirement "text" (on "REF") (check …) [(ref "file.pdf" (page N))] [(id "…")])
(net-rule    "text" (nets GLOB…) predicate… [(id "…")])
```

They are **gated exactly like library requirements** — same `Status` set, same
`requirementSeverity` mapping, same `netlisp check` findings, same review
table, same `run_checks` output — and carry `source: design` so a reviewer can
tell "you used the part wrong" from "you broke your own contract". The release
profile's demand for at least one cited requirement on every active part is
satisfied by an `(on "REF")` rule naming that part, and the `.checks.sexp`
sign-off mechanism reaches them through a `design-rule` target:

```lisp
(verifies (req design-rule "deadbeef") "5 V comes in from the bench supply")
```

**Ids.** An explicit `(id "…")` wins; otherwise the id is the CRC32 of the
rule's own text, the identical derivation `Requirement.id` uses for library
rules. Editing anything except that sentence — retargeting the rule, adding a
predicate, moving it into a section — leaves the id, and therefore every
sign-off, attached.

#### `(requirement … (on "REF") (check …))`

`(on "REF")` names an instance of the **containing block**, and the check is
evaluated against that block — the same contract a library requirement on the
same part gets, so `(pin "VIN")` resolves through that instance's pinout and
against that block's nets. `"sub/REF"` reaches a part inside a sub-block and is
judged **in the sub-block's block**, not the parent's. Every `(check …)`
primitive works unchanged:

```lisp
;; Barracuda: the LO synthesizer's charge-pump rail is the board's own rule,
;; not the LMX2820's — the datasheet allows 3.3 V, the board committed to a
;; quiet 3.3 V LDO and the rest of the loop analysis assumes it.
(requirement "VCC_CP runs from the quiet LDO, never the switcher"
  (on "U_LO")
  (check (tied-to-net (pin "VCC_CP") (net "V_3V3_ANA"))))

;; Reuse a library primitive on a part whose library file carries no rule:
(requirement "U1 keeps a local 1 uF bypass at VIN"
  (ref "bench-notes.pdf" (page 2) (quote "1 uF at every LDO input"))
  (on "U1")
  (check (decoupling (pin "VIN") (pin "GND") (min-uf 0.9))))
```

A target naming no instance **fails** naming itself — a renamed part must not
quietly retire the rule about it. Because a sub-block's parts are renumbered
into the board's global ref-des space, `"sub/REF"` also matches the part's
authored source name, so a module's author can write the `U9` they see in
their own file.

#### `(net-rule … (nets GLOB…) predicate…)`

A rule about **nets** rather than parts: no pinout, no `(on …)`, nothing to
place. Globs match flattened net names — `V_*`, `*_RF`, `sub/*`, or an exact
name — case-insensitively, where `*` matches any run of characters. A glob is
matched against the net's name as the rule's own block sees it **and** against
its full flattened name, so a module author writes `(nets "VOUT")` and the
board that instantiates it writes `(nets "buck/*")` for the same copper.
Per-pin bypass stubs (`VDD.U1.5`) are excluded, so `V_*` does not report one
result per decoupling capacitor.

The predicates are generated into the **"Net-rule predicates"** table of
`docs/language-forms.md`: `(min-bulk-uf F)`, `(declared-envelope)`,
`(in-net-class)` and `(max-fanout N)`. A rule may carry several; the net must
satisfy every one.

```lisp
;; Barracuda-style rail rule: every board rail carries a reservoir, has a
;; provable DC envelope for the release rating checks, and is claimed by a
;; net class so the router does not fall back to the board default width.
(net-rule "Every board rail is reservoired, bounded and classed"
  (nets "V_*")
  (min-bulk-uf 4.7)
  (declared-envelope)
  (in-net-class))
```

**Results.** A net rule produces **one result per matched net**, plus the
rule's rolled-up verdict (the worst of them). Both halves are load-bearing:
the per-net results are what `netlisp check` emits as findings, because a
failure has to name the net; the rollup is the rule's single identity, which is
what a `(verifies …)` addresses and what the review document shows one row
for. A glob matching **zero** nets is a **failed** result naming the glob —
never a silent pass, because the overwhelmingly likely cause is a net that was
renamed or never existed, which is exactly what the rule was written to catch.
`(declared-envelope)` on a net with no derivable envelope is **unproven**
rather than failed, matching how the library rating checks treat the same
missing evidence.

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
`(net-envelope "VBUS" (rated 0 5.5) "USB VBUS")`. Before reaching for that,
check what the library already says: a `(feedback-divider … (reference-v V))`
requirement bounds its FB pin at the reference, a `(set-resistor-output …)` one
bounds its SET pin at I_SET x R_SET, a divider tap between two bounded nets is
solved by the leg ratio, and an `(electrical "PIN" … (max-voltage V))`
declaration bounds the bypassed bias node behind that pin. `netlisp net
<design> <net>` shows which rule answered, under `envelope.origin`.

### Module-owned envelopes

Most nets need no `(net-envelope …)` at all: a rail's envelope follows its own
declaration and carries across ferrite beads and series resistors onto the
nodes beyond them. The nets that *do* need one are usually a module's own
internals — a regulator's SET or FB node, a bias pin behind its bypass cap —
and those are a function of the module's parameters, not of the board. Writing
them at board level means restating the same datasheet arithmetic once per
instantiation, in the board file, about parts the board cannot see.

So `(net-envelope …)` is a module form too. Inside a `(defmodule …)` /
`(block …)` body the net name is **module-local**, and `LO`/`HI` are
**evaluated expressions** of the module's own parameters:

```lisp
(defmodule bcuda-lt3045-ldo ((vout 3.3))
  (design-block (fmt "~V LDO (LT3045)" vout)
    (instance "U1" lt3045edd#pbf (pin 7 "SET") …)
    (instance "R_SET" (res-0402-0p1 rset-str "0.1%") (pin 1 "SET") (pin 2 "GND"))

    ;; Stated ONCE here, not once per board that instantiates this module.
    (net-envelope "SET" (rated (* vout 0.97) (* vout 1.03))
      "LT3045 SET sources 98/100/102 uA into R_SET = vout x 10k, so the node
       sits within 3 % of the programmed output")))
```

On flatten the declaration lands on `sub-block/NET` at each instantiation's own
numbers — `(sub-block "ldo_5v" (bcuda-lt3045-ldo (vout 5.0)) …)` gives
`ldo_5v/SET` 4.85–5.15 V, and `(vout 3.3)` gives `ldo_3v3a/SET` 3.201–3.399 V —
and it is reported as `declared in module ldo_5v`, so a reviewer can see which
body made the claim.

**Precedence.** A module-scope declaration is checked against what the parent's
own topology derives; the board's own declarations are then checked against
*that* result. So a board may restate or **widen** what a module claims about
the module's insides, and a board declaration that **narrows** it is the same
failed assertion an under-covering declaration always was — the module owns the
node it owns, and two statements about one net cannot disagree. `netlisp net
<design> <net>` reports the winning envelope, its `source`
(`authored`/`derived`), the rule that established it and the ferrite-class root
it was resolved on.

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

`(decouple "NET" …)` has two grammars on one head. The **sub-form** one is the
documented spelling:

```scheme
(decouple "VDD3V3"
  (per-pin (cap-0402 "100nF") VDD_1 VDD_2 VDD_3)   ;; one bypass per named pin function
  (bulk (cap-0805 "10uF") 2))                      ;; shared rail reservoir
```

The **positional** one — `(decouple "VDD" (comp "val") COUNT per-pin REF
PIN…)` — is the older shape and still works everywhere; it records a
`deprecated_form` info naming the sub-form spelling. Both emit the same parts
with the same structural ids, so rewriting one does not re-stamp a board.

`(decouple "VDD" 1 per-pin auto)` expands to every pin already declared on the
net using the `(decouple-defaults (ic …))` ref (the `(pins …)` declarations
must appear first); a literal `REF PIN…` list spells the pins out instead. The
`(decouple-defaults … (bypass …))` component (not the ic) cascades into
sub-block modules that don't set their own.

`(decouple-defaults …)` itself is deprecated (info, still working). The
defaults it supplies are exactly what makes a `(decouple …)` line unreadable
on its own — you cannot tell from `(decouple "VDD" 1 per-pin J14 K14)` which
part is placed or which IC hosts it without scrolling back to the defaults
form, and with a default IC set, a leading `REF` token is silently reinterpreted
as a *pin*. Spell the host and the part at each site instead.

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

### Placement class pins: `(module-policy (placement-class …))`

The placer, the routing order and the `layout_class_inferred` ERC info all
classify nets by name (`input_rail`, `switch_node`, `clock`, `rf`, `feedback`,
`analog`, `power`, `ground`, `control`, `signal`). When the guess is wrong, or
when you want the decision recorded so the info stops appearing, pin it:

```lisp
(module-policy
  (placement-class "V_24V_CLEAN" power)      ;; a clean post-LDO rail, not an input rail
  (placement-class "REF_ADF" clock)
  (placement-class "BOOST25_SW" switch_node)) ;; a bare leaf reaches the module-local net
```

**`placement-class`, not `net-class`.** The two words meant different things:
this one is *placement criticality* — how tightly the placer packs a net's
loop and how early the router claims its path — while the **top-level**
`(net-class …)` form is *routing geometry*: trace width, clearance, via size,
impedance. They never interacted, and sharing the word made every reading of
either one a guess. `(module-policy (net-class …))` is a permanent alias that
still works; it reports a `deprecated_form` info naming this spelling, and
nothing about the design changes when you leave it alone.

Design-block scope only. The net is the flattened name, or a bare leaf that
matches every module-local net of that name. A pinned class is final — the
hub-plus-inductor switch-node upgrade does not apply — and a pinned net is no
longer reported as inferred. Unknown class atoms are warned and dropped.

### Assembly variants: `(variant …)`, `(only-in …)`, `(dnp-in …)`, `(value-in …)`

One PCB, one netlist, one set of footprints — several build configurations
differing only in **which parts are populated** and **what value a populated
part carries**. Declare the variant space at design-block scope:

```lisp
(design-block "Sensor Node"
  (variant "Lite" "no radio, cost-reduced")
  (variant "Pro"  "full feature set" (default))
  …)
```

`(variant …)` is repeatable, at most one may carry `(default)`, and the name is
a literal quoted string (like `(revision "A")` — it is the identity the CLI, the
URL and the BOM spell out, so it is read straight off the source). A design with
no declaration has exactly one implicit **base** variant.

Each instance opts in with one or more clauses in its body:

```lisp
(instance "U7" (sx1262)                 (only-in "Pro"))      ;; Pro only; DNP elsewhere
(instance "R14" (res-0402 "0R")         (dnp-in "Lite"))      ;; populated everywhere but Lite
(instance "R9" (res-0402 "10k")
  (value-in "Pro" "4.7k"))                                    ;; different value in Pro
```

* `(only-in "V"…)` — populated **only** in the listed variants; every other
  variant, the base included, leaves it Do Not Populate.
* `(dnp-in "V"…)` — Do Not Populate in the listed variants, populated in the rest.
* `(value-in "V" "VALUE")` — value override in that variant; repeat the form
  once per variant. The family's declared value-kind applies to the override
  exactly as it applies to the authored value, so `(value-in "Pro" "4.7k")` on a
  `cap-0402` is still rejected.

Unlike the declaration, these arguments are evaluated, so a `let`-bound name or
an `(fmt …)` works.

**Only assembly differences are expressible.** The footprint and its pads stay
on the board in every variant — `(only-in …)` stops the pick-and-place, not the
copper. A difference that changes the netlist or the footprints is a different
board, not a variant.

**Variants are design-level.** A module is a circuit, not an assembly: the same
regulator module is embedded in boards whose variant names have nothing in
common. So a `(variant …)` inside a module body is an error, while an instance
inside a `(sub-block …)` names the **root design's** variants directly:

```lisp
(defmodule radio-front-end ()
  (design-block "Radio Front End"
    (instance "U1" (sx1262) (only-in "Pro"))))   ;; "Pro" is the ROOT design's variant
```

A variant name the root design never declared is a build error naming the
module's own file and line, with a did-you-mean.

**Errors.** `(dnp)` is unconditional, so combining it with `(only-in …)` or
`(dnp-in …)` is an error; so is naming one variant in both `(only-in …)` and
`(dnp-in …)` on the same part; so is a second `(default)`, a duplicate variant
name, and a duplicate `(value-in …)` for one variant. The shorthand-generated
parts (`decouple` / `series` / `pullup` / `divider`) take no variant clauses.

**Selecting one.** `--variant NAME` on `netlisp build`, `check`, `instances`,
`export-kicad`, `export-kicad-sch` and `export-pdf`; `?variant=NAME` on the
schematic page and the export endpoints; a `variant` argument on the
`list_instances` and `run_checks` structured tools. Omitted, the `(default)`
variant is selected, and failing that the base. The selection lands on each
part's `dnp` flag and `value` **before** ERC, the BOM, the exports and the
views read them, so everything the unconditional `(dnp)` already drives — the
BOM badge and CSV, the KiCad `dnp` / `exclude_from_bom` attributes, the ERC
exemptions, the schematic strike-through — follows the selected variant.

`netlisp instances` reports the declared variants, the selected one, and each
part's `populated_in` list; `netlisp designs` lists the names each design
declares. The BOM CSV gains a `Populated In` column listing, per rolled-up line,
which variants stuff that part — and two otherwise identical parts populated in
different variants become two lines, because they are two purchase decisions.
Both are omitted for a design that declares no variants, so a single-assembly
BOM keeps exactly the columns it has always had.

The `.bom` sidecar is the identity ledger for the **base** assembly:
every variant's parts are in it and it records the authored value, never a
`(value-in …)` override, so building a non-default variant cannot disturb the
MPN selections the base assembly's rows carry.

### Lint warnings and authoring errors

Unknown sub-forms / enum words inside known forms (e.g. `(role inptu)`, a
section-only form at top level) no longer vanish silently — `netlisp build`
prints `file:line:col: warning: …` to stderr. Eval errors now name the form
with expected arity, suggest `(import …)` or nearest-name for unbound
components, and print the module call stack.

Three `(instance …)` mistakes that used to build clean are **errors**, each
pointing at `file:line:col`:

- **A typo'd body sub-form.** Any head this parser does not dispatch on
  becomes an inline BOM property `(key "value")`, so `(decuples "U1" 1)` used
  to build a property named `decuples` and declare no decoupling at all. A
  head within two edits of a real sub-form (`pin`, `part`, `note`, `bus`,
  `id`, `as`, `dnp`, `decouples`, `near`, `strap-ok`, `nc-ok`, `power`, `row`,
  `col`) is now rejected with a did-you-mean. Property keys that are not
  near-misses — `(module-bypass "…")`, `(emi-couples "…")` — keep working.

- **A value that is not the family's declared kind.** A `component-family`
  declares `(parameter "value" capacitance | resistance | inductance |
  impedance | string)`, and the value is now checked against it, so
  `(cap-0402 "4.7k")` is rejected. The rule is one-sided: a value is refused
  only when it positively parses as *another* quantity — a number plus a unit
  (`F` / `H` / `R` / `Ω`) or a bare SI prefix that cannot belong to the
  declared kind (`k`, `M`, `G` are resistance; `f`, `p`, `n`, `u` are
  capacitance or inductance; `m` is plausible for all three). Anything else is
  accepted in silence: a bare number (`10`, `0.01`), a sentinel (`DNP`), a
  part number, a `(fmt "~R" …)` result, a trailing rating (`"10uF 25V"`), a
  bead's `"600R@100MHz"`, and a letter used as a decimal point (`24R9`). A
  family declaring `string` (or no kind at all) is never checked.

- **A pad the part does not have.** `(pin 99 "X")` on an 11-pad part used to
  produce only a downstream floating-net warning while the pad itself reached
  the netlist and the KiCad export. The pad set now comes from the part's
  `lib/pinouts/<name>.sexp` and its `lib/footprints/<name>.sexp` `(pad …)`
  ids; a token outside both is an error naming the pad count, with a
  did-you-mean when it looks like a misspelled pin function. The same check
  covers `(strap-ok PAD …)`, `(nc-ok PAD …)` and `(near … (own PAD))`. A part
  with **neither** record has an unknown pad set and every token on it passes,
  so newly imported parts and pinout-less passives are unaffected.

**`file` is the file the form actually lives in.** A warning or error raised
while an imported `lib/modules/*.sexp` or `lib/components/*.sexp` body
evaluates is reported against *that* file and its own line, not against the
design that imported it — so a retired form inside a shared module names the
module you have to edit, and the module call stack still says which call
reached it:

```text
lib/modules/adp7118-ldo.sexp:44:5: warning: unknown sub-form (placement …) in (design-block …)
lib/modules/probe-ldo.sexp:5:17: error: (port …) expects a direction or net after the name
  in module 'probe-ldo' (called at 4:21)
```

Forms spliced in from a sibling sidecar (`<design>.checks.sexp`,
`<design>.layout.sexp`, `<design>.diagram.sexp`) report against the **sidecar's**
own path and line, not the design's — see "Sidecar files" below.

### Sidecar files

A design may be split across up to four files that all live next to each other
under `src/`. Every sidecar is **optional** and is autoloaded by basename: when
`src/…/<name>.sexp` is evaluated, each sibling that exists is parsed and its
top-level forms are spliced onto the end of that design's `(design-block …)`
body. There is nothing to import and nothing to declare — the forms behave
exactly as if they had been written inline.

| File | Holds |
|---|---|
| `<name>.sexp` | the circuit: `section`, `instance`, `net`, `sub-block`, `port`, the shorthands — plus `board-role`, `hierarchical-ids`, `revision` |
| `<name>.checks.sexp` | verification forms (`verifies`, `assert`, …). Historical and deliberately unrestricted |
| `<name>.layout.sexp` | `board`, `stackup`, `net-class`, `pcb-plan`, `design-rules`, `pdn`, `module-policy`, `net-envelope`, `power-plane`, `rough`, `fabrication-layer`, `kicad-pcb` |
| `<name>.diagram.sexp` | `diagram-layout`, the design-scope `(group "name" ("R1" …))`, `function` |

`board-role` and `hierarchical-ids` stay in the design file on purpose: they
change what the design *is* — its identity and its place in a system — rather
than how it is laid out.

Two rules keep the split honest:

- **A form of the wrong kind is an error**, and the message names the file that
  should hold it. A `(section …)` cannot hide in the layout sidecar, and a
  `(diagram-layout …)` there is told to move next door.
- **A singleton form declared in two of the files is an error** naming both
  locations. `stackup`, `board`, `pcb-plan`, `design-rules` and `diagram-layout`
  may each be declared once per design; because the splice appends, a second
  copy would otherwise be resolved by file order rather than by you.

```text
src/boards/x.layout.sexp:9:1: error: (diagram-layout …) belongs in the .diagram.sexp sidecar, not x.layout.sexp
src/boards/x.layout.sexp:2:1: error: (stackup …) is declared twice: here and at x.sexp:5 — a design may declare it once
```

Sidecars are part of the design in every sense that matters downstream: they are
in the evaluator read-set, so the served page refreshes when one is edited; they
are in the fabrication gate's provable closure, the release source closure, the
design archive and the system-review package; and an `(id …)` minted by a form
that lives in a sidecar is written back **into that sidecar**, never into the
design file at a foreign byte offset.

#### Splitting an existing design

`split-design` does the move for you, and proves it:

```bash
netlisp tool split-design --project-dir projects/designs \
  --args '{"design":"barracuda"}'                 # dry run: the three diffs
netlisp tool split-design --project-dir projects/designs \
  --args '{"design":"barracuda","write":true}'    # apply
```

Every eligible top-level form is lifted at its parser span **byte for byte**,
together with the comment block written directly above it, and appended to the
matching sidecar (an existing sidecar is appended to, never overwritten). The
circuit, the file banner, `board-role`, `hierarchical-ids` and every `(id …)`
stay where they are. The write is refused unless the original and split trees
evaluate to the same design — the flattened netlist *and* the evaluated
design-scope form set, compared field for field.

### Duplicate ref-des

Two instances **authored** with the same ref-des in one block — including two
`(repeat …)` iterations that mint the same token — are a build error naming
both places, raised before ref-des auto-assignment can renumber the second one
into a confusing `pin_multi_net` further downstream:

```text
src/board.sexp:8:3: error: duplicate ref-des "R1" — already declared at src/board.sexp:5:3;
  a ref-des must be unique within its block (each (sub-block …) is its own namespace)
```

Scope is the **block**, so two instantiations of one module may each name their
own `R1`; the sub-block pass renumbers them apart. Shorthand-generated parts
(`(decouple …)`, `(series …)`, `(fanout …)`, `(pullup …)`, `(divider …)`,
`(led …)`) draw from the auto ref-des counters and never collide. ERC's
`duplicate_refdes` check stays in place for collisions that only appear after
the hierarchy is flattened.

### Did-you-mean for net names

A net with exactly one connection (and no declared port) that is within two
character edits of an *established* net — one with two or more connections, or
a declared port — carries the near-miss in its finding, so a typo reads as a
typo instead of as a mysterious dead end:

```text
WARN: Dead-end net "GNND" — only connected to C1 pin 2 — did you mean "GND"?
warning   floating_net   [GNND] — Floating net "GNND" — only one connection — did you mean "GND"?
```

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

### KiCad board target: `(kicad-pcb …)` and `kicad-projects.sexp`

`(kicad-pcb "/abs/path/board.kicad_pcb")` names the board file the file-based
KiCad sync writes to. It is the one form in the language whose value is a
property of the **machine**, not of the circuit — so it also resolves from
outside the source:

```lisp
;; projects/designs/kicad-projects.sexp — one entry per design, the design name
;; being the SOURCE FILE STEM (`netlisp designs` prints exactly these tokens).
(kicad-pcb "barracuda" "/mnt/nas/kicad/barracuda/barracuda.kicad_pcb")
(kicad-pcb "rds3"      "/mnt/nas/kicad/rds3/rds3.kicad_pcb")
```

An entry there **overrides** the design's own `(kicad-pcb …)` form and
**supplies** the target when the design declares none, so a shared design file
need carry no absolute path at all. The in-source form still works and is the
right choice when the path is genuinely the same everywhere the design is
opened.

The file is optional and fail-open: absent, unreadable, or with a malformed
entry, every design falls back to whatever its own source declares — a file of
machine-local paths must never fail a build on a machine that has none. Full
resolution rules: [docs/build-and-run.md](build-and-run.md).

### Board keepout regions

`(board … (keepout "NAME" …))` reserves a rectangle of board. It is the
*authored* keepout, as opposed to the two derived ones: `(perimeter-fence …
(keepout CLEARANCE …))` is a band computed from the outline, and
`(net-class … (keepout MM))` is an RF halo computed from copper. This form
states a mechanical fact instead — a heatsink plate's footprint, a shield can,
a bracket, a connector's mating shroud — so nothing about the outline, the
fence, or the routing can move it.

```scheme
(keepout "NAME"
  (rect X Y W H)                     ;; board-local mm from the outline's top-left
  (side top|bottom|both)
  [(blocks components tracks vias)]  ;; default: all three
  [(allow-nets "GND" …)]
  [(reason "why the space is reserved")])
```

The form is repeatable — a board may declare as many regions as it has
obstructions.

- **Frame.** `(rect X Y W H)` is board-local millimetres measured from the
  outline's top-left, the same frame `(heatsink (rect …))` uses, because both
  are read off the same mechanical drawing. The rectangle must lie wholly
  inside the declared `(size W H)` outline.
- **Face.** `top` / `bottom` reserve one assembly face and that face's copper
  (`F.Cu` / `B.Cu`); `both` reserves the whole board thickness, inner copper
  layers included. A through via crosses every layer, so it is measured
  against a region whatever face that region names.
- **What it enforces.** The placer refuses to put a component courtyard inside
  a region on a face it reserves (and the force solve is pushed out of one),
  DRC reports a fab-blocking `board keepout` violation for any courtyard,
  track segment, or via that lands there, and `(allow-nets …)` admits named
  copper anyway — a plate bonded to ground still wants its stitching.
- **What it shows.** The region is drawn and labelled on `/pcb-layout` and in
  the PCB PNG, and `/api/pcb-describe` lists it under `board.keepouts` in world
  millimetres with its side, blocked families, allowed nets, and reason.
- **Errors, not warnings.** A rectangle outside the outline, a non-positive
  size, an unknown side or `blocks` word, an unknown sub-form, or a missing
  `(rect …)` / `(side …)` stops the build with `file:line:col`. The derived
  keepouts degrade to a warning because there is something to fall back to;
  a silently dropped authored region reads on every surface exactly like a
  board that never reserved the space.

The motivating case — **illustrative, not a transcript of the corpus** — is
the Barracuda RF board's bottom frontend reserve. That board still records the
region as a prose comment marked "NOT machine-checked" and declares no
`(keepout …)` form; adopting one is a board edit nobody has made. The worked
example below is what adopting it *would* look like, and it is the right shape
to copy. Its outline is 81.0 × 24.8 mm, and the reserved rectangle occupies
`x = 174.0 … 189.0`, `y = 89.6 … 98.5` in that board's layout frame (outline
`x 126.5 … 207.5`, `y 89.6 … 114.4`) — board-local `x = 47.5`, `y = 0`,
`w = 15.0`, `h = 8.9`:

```scheme
(board
  (part-number "BARRACUDA-RF")
  (size 81.0 24.8)
  (corner-radius 2.0)
  (keepout "bottom frontend heatsink plate"
    (rect 47.5 0.0 15.0 8.9)
    (side bottom)
    (allow-nets "GND")
    (reason "bottom-side heatsink plate over the frontend/LNA region must stay part-free"))
  …)
```

### Ports

```scheme
(port "VDD"  in  (rated 1.62 1.98))
(port "GND"  bidi)
;; Long form when net differs from name:
(port "VOUT" vout-str  out  (rated 0.6 16.0))
```

Everything after the direction is an option, in any order. Two of them are
bare words with no parentheses and stay that way: `optional`, and a
signal-type word (`power`, `clock`, `rf`, `data`, `differential`, `signal`).
Everything else is a sub-form — see
[language-forms.md § Port sub-forms](language-forms.md) for the full table:

```scheme
(port "SPI_SCK" out clock
  (role "bus-clock")            ;; what this port does in its interface
  (protocol "SPI")              ;; the standard it speaks
  (class "fast")                ;; a free classification key
  (nominal 3.3))                ;; nominal voltage
```

**The numbers are expressions.** Both `(nominal V)` and **both bounds** of
`(rated LO HI)` are evaluated, so a parameterized module states its own window
in terms of its own arguments instead of making every board restate it — the
same rule module-scope `(net-envelope … (rated …))` follows:

```scheme
;; lib/modules/bcuda-lt3045-ldo.sexp — one line covers every instantiation
(port "VOUT" out power
  (nominal vout)
  (rated (* vout 0.95) (* vout 1.05))
  (current 0.5 0.5) (efficiency linear))
```

A bound that does not evaluate to a number, and a `LO` above its `HI`, are
both **errors naming the port** — an absent rated window is exactly what the
release rating checks cannot detect, so it is never dropped quietly. A literal
number evaluates to itself, so nothing already written parses differently.

The same evaluation applies to a `(port …)` written inside a `(section …)`.
A section port is a boundary/diagram declaration, so its `(rated …)` is
recorded and validated but does not itself seed a derived envelope; the module
port that actually publishes the rail does that.

Two older spellings still work and always will, each recording a
`deprecated_form` info that names its replacement:

| Old | Write instead |
| --- | --- |
| `role R` / `protocol P` / `class C` — a bare keyword that swallows the next token | `(role R)` / `(protocol P)` / `(class C)` |
| a bare trailing number | `(nominal V)` |

The keyword pairs read as two unrelated options to anyone scanning the line,
and a bare number is indistinguishable from a positional argument the form
does not have. Both forms parse identically to the sub-forms; rewriting one is
a pure spelling change.

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

### Interface bundles: `(interface …)`, `(port-group …)`, `(bridge-interface …)`

`(bus-port …)` writes a bus whose lanes are **numbered**. SPI, I²C, UART, SWD
and JTAG lanes are **named**, and the names vary: across `lib/modules` the SPI
clock is spelled `SCK`, `SCLK`, `SPI_SCK` and `RF_SPI_SCK`; data-out is `MOSI`,
`SDI`, `SPI_SDI`, `SPI_MOSI`; select is `CS`, `CSN`, `SPI_CS`, `SPI_CSN`,
`SPI_LMX_CSN`. The boards then carry 269 `(rename …)` forms to tie those
spellings together, 36 of them for SPI/I²C alone.

An `(interface …)` states one vocabulary once. Direction is always written from
the **peripheral's** point of view — a peripheral is clocked, is selected,
receives on `MOSI` and answers on `MISO`:

```scheme
;; stdlib/interfaces/spi.sexp, bundled into the binary
(interface spi "Four-wire SPI (controller/peripheral), peripheral perspective"
  (signal SCK  in  clock)
  (signal MOSI in  data)
  (signal MISO out data)
  (signal CS   in))
```

`spi`, `i2c`, `uart`, `swd` and `jtag` ship with the binary. A project shadows
one by name with its own `lib/interfaces/<name>.sexp` — the same
project → `--lib-dir` → `NETLISP_STDLIB_DIR` → bundle order every library file
resolves through (see [docs/standard-library.md](standard-library.md)) — and an
`(interface …)` written at the top level of a design or module file needs no
file at all.

#### The module side: `(port-group …)`

`(port-group "PREFIX" iface …)` expands to one `(port …)` per signal, named
`PREFIX_SIGNAL` (one underscore, however the prefix is spelled: `"IMU"` and
`"IMU_"` both give `IMU_SCK`). An empty prefix gives bare signal names. Every
trailing modifier — `(rated …)`, `(side …)`, `(electrical …)`, `optional` — is
replayed onto each lane exactly the way `(diff-port …)` replays them onto both
of its.

```scheme
;; lib/modules/bno08x-imu.sexp declares its SPI boundary as four lines:
(port "SCK"  in)
(port "MOSI" in)
(port "MISO" out)
(port "CS"   in)

;; The same boundary as one bundle — and the lanes now carry the signal types
;; the vocabulary states (`SCK` clock, `MOSI`/`MISO` data):
(port-group "" spi)
```

Three options shape the expansion:

- `(role controller)` mirrors every direction, so an MCU declares the same
  bundle as the peripheral it drives. A bidirectional lane — I²C's two
  open-drain lines, SWD's `SWDIO` — is its own mirror and never flips.
- `(rename SIGNAL "PORTNAME")` names one lane outright, for a part whose
  datasheet spells chip-select `CSN`.
- `(omit SIGNAL…)` drops lanes the part has no pin for.

```scheme
;; lib/modules/bcuda-dsa-hmc1119.sexp — a write-only three-wire attenuator:
(port "SPI_DSA_SCK" in)
(port "SPI_DSA_SDI" in)
(port "SPI_DSA_CSN" in)

;; …as one bundle that still keeps the datasheet's spellings:
(port-group "SPI_DSA" spi (rename MOSI "SPI_DSA_SDI") (rename CS "SPI_DSA_CSN")
                          (omit MISO))
```

The expansion also **records the bundle** on the block, which four hand-written
ports cannot. A group is addressed by its prefix — by the interface name when
the prefix is empty, so the `(port-group "" spi)` above is the group `"spi"`.

#### The board side: `(bridge-interface …)`

Inside a `(sub-block …)`, `(bridge-interface "GROUP" (to "NET_PREFIX"))` ties
every member port of that group to board net `NET_PREFIX_SIGNAL`. It is exactly
equivalent to the `(bridge …)` lines it replaces — same net ties, in the same
order:

```scheme
;; src/boards/cyclops/stm32n6.sexp, today:
(sub-block "imu" (bno08x-imu)
  (bridge "IMU_" SCK MOSI MISO INT NRST WAKE (rename CS NCS)) (id d444ddf5))

;; …with the bus named once and the three loose signals left as they were:
(sub-block "imu" (bno08x-imu)
  (bridge-interface "spi" (to "IMU") (rename CS "IMU_NCS"))
  (bridge "IMU_" INT NRST WAKE) (id d444ddf5))
```

```scheme
;; src/boards/barracuda/barracuda.sexp, today — five of the seven bridged
;; ports are the SPI bus, spelled out one (rename …) at a time:
(sub-block "dsa" (bcuda-dsa-hmc1119)
  (bridge "" (rename LPF_RF IF1_LNA) (rename DSA_RF IF1_DSA) V_3V3A
             (rename SPI_DSA_SCK SPI_SCK) (rename SPI_DSA_SDI SPI_MOSI)
             SPI_DSA_CSN GND)
  (id a625bd1e))

;; …with the module declaring (port-group "SPI_DSA" spi …) as above:
(sub-block "dsa" (bcuda-dsa-hmc1119)
  (bridge-interface "SPI_DSA" (to "SPI") (rename CS "SPI_DSA_CSN"))
  (bridge "" (rename LPF_RF IF1_LNA) (rename DSA_RF IF1_DSA) V_3V3A GND)
  (id a625bd1e))
```

A board that carries a bus straight through to its own boundary declares a
`(port-group …)` of its own and ties the sub-block to it by name:

```scheme
(port-group "EXT" spi (role controller))
(sub-block "imu" (bno08x-imu)
  (bridge-interface "spi" (to-group "EXT")))
;;   →  (net "EXT_SCK"  "imu/SCK")   (net "EXT_MOSI" "imu/MOSI")
;;      (net "EXT_MISO" "imu/MISO")  (net "EXT_CS"   "imu/CS")
```

A `(rename SIGNAL "NET")` on the `(bridge-interface …)` overrides one lane's
board net whichever destination form is used, and a signal a `(to-group …)`
peer does not carry is simply not tied.

#### What ERC does with a group

A `(port-group …)` is a **both-or-neither** bundle, like `(diff-port …)`:
wiring `SCK` and `MOSI` while leaving `CS` open is reported as
`interface_half_connected`, inside the module or from a parent that bridges
only part of the bus. Lanes the vocabulary marks `optional` (UART's `CTS`/`RTS`,
JTAG's `TRST`, SWD's `SWO`/`NRST`) are never demanded, and a group with nothing
wired at all is left to the ordinary required-port rule.

Separately, `interface_naming` is an **info**-severity advisory — never a
warning, so it cannot fail a release build. A module that declares two or more
ports out of one interface's naming vocabulary (`SCLK`, `SDI`, `SDO`, `CSN`,
`NCS`, `SS`, … all count) without a `(port-group …)` gets one row naming the
interface and the exact line that would replace those ports:

```
info  interface_naming — 'bcuda-dsa-hmc1119' declares SPI_DSA_SCK, SPI_DSA_SDI,
      SPI_DSA_CSN — the spi signal vocabulary — as loose ports; declare the
      bundle instead: (port-group "SPI_DSA" spi (rename MOSI "SPI_DSA_SDI")
      (rename CS "SPI_DSA_CSN") (omit MISO))
```

### Structural control flow: `when` / `unless` / `if` / `for` / `repeat`

Five forms are *statements* as well as expressions: written directly in a
design scope, their body holds whatever that scope accepts — instances,
ports, nets, `pins`, `decouple`/`series`, sub-blocks, notes, sections, and
each other. All five are legal at **design-block top level, inside a
`(section …)`, and inside a nested sub-section**; the generated forms are
indistinguishable from the same lines written out by hand, so a section
records its hosted instances, pin groups and notes exactly as before.

| Form | Body | Runs when |
| --- | --- | --- |
| `(when cond form…)` | any number of forms | `cond` is true |
| `(unless cond form…)` | any number of forms | `cond` is false |
| `(if cond then else)` | exactly one form per branch | always — one branch |
| `(for name (item…) body…)` | any number of forms | once per item |
| `(repeat name start end body…)` | any number of forms | once per integer, inclusive |

The condition is any expression that evaluates to a **boolean**:
`(== variant "A")`, `(> vout 5.0)`, a `(let …)`-bound comparison, a module
parameter compared against a value. A number or a string is rejected with an
error naming the form — in design scope a silently-taken branch would add or
drop real parts, so truthiness is not guessed. `(if …)` in *expression*
position (`(let rail (if (== ratio 1) "GND" "VCC"))`) keeps its ordinary
Lisp behaviour, truthiness included.

```scheme
;; Assembly options, at design-block top level.
(design-block "Regulator"
  (let precision (== grade "A"))
  (when precision
    (instance "R_SET" (res-0402 "49.9k" "0.1%") (pin 1 "VOUT") (pin 2 "SET")))
  (unless precision
    (instance "R_SET" (res-0402 "49.9k" "1%") (pin 1 "VOUT") (pin 2 "SET")))
  …)

;; The same choice as one-form-per-branch sugar.
(if precision
  (instance "C_REF" (cap-0402 "10nF" np0) (pin 1 "SET") (pin 2 "GND"))
  (instance "C_REF" (cap-0402 "10nF" x7r) (pin 1 "SET") (pin 2 "GND")))
```

```scheme
;; Loops inside a section — the four filters land in the section, and the
;; section's hosted-instance list, status and diagram read as if the sixteen
;; lines had been typed out.
(section "Anti-alias filters"
  (for ch ("A" "B" "C" "D")
    (for leg ("P" "N")
      (instance (fmt "R_F~a~a" ch leg) (res-0201 "33R")
        (pin 1 (fmt "AIN~a_EXT_~a" ch leg)) (pin 2 (fmt "AIN~a_~a" ch leg)))
      (instance (fmt "C_F~a~a" ch leg) (cap-0201 "68pF")
        (pin 1 (fmt "AIN~a_~a" ch leg)) (pin 2 "GND")))))

;; Nesting composes: a loop inside a conditional inside a section.
(section "Calibration"
  (when cal-fitted
    (for ch ("A" "B")
      (instance (fmt "R_CAL~a" ch) (res-0402 "1k")
        (pin 1 (fmt "CAL~a" ch)) (pin 2 "GND")))))
```

`(repeat …)` counts integers; `(for …)` walks a literal list, so a loop
variable can be a channel letter, a lane suffix, or any expression —
including `(let …)`-bound values. Each item is evaluated in the enclosing
scope, then bound in a fresh child scope for one pass over the body, so a
body-local `(let …)` never leaks sideways into the next iteration.

**Identity.** The **outermost** structural form owns one source-resident
`(id …)` anchor, which the build mints into the file when it is missing —
one anchor per nest, never one per generated child (they all share a single
source location, so per-child `(id …)` insertion is impossible). Every child
derives its id from that anchor, its own stable `origin_key`, and the
accumulated **key path** of the branches and iterations it sits inside:

- a taken `when`/`unless` body, and an `(if …)` then-branch, contribute `@t`;
- an `(if …)` else-branch contributes `@f`;
- a `for`/`repeat` iteration contributes `@<0-based ordinal>` / `@<index>`.

So a child of `(for …)` alone keys as `R_FAP@0`, and one inside
`(when …)` → `(for …)` keys as `R_CALA@t@0`. Two consequences worth stating:
flipping a condition **re-derives** rather than re-uses — an else-branch part
can never inherit the id of the then-branch part it replaces, even when both
carry the same ref-des — and nesting composes instead of the outer form
flattening the inner one's distinctions.

An `(ids ("R_FAP@0" <hex8>) …)` sidecar on the anchor form pins migrated
identities, which is how a hand-unrolled block is folded into a loop or a
conditional without changing its established PCB UUIDs. Wrapping existing
instances in a control form otherwise re-derives their ids, exactly as
folding them into a `for` does.

**Errors.** A body form that the enclosing scope does not accept is reported
at **its own** `file:line:col`, with the same message a hand-written sibling
would draw — `(stackup …) is top-level-only — ignored inside (section …)`
points at the `(stackup …)`, not at the `(when …)` around it.

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

### Anonymous wiring: `(connect …)` and `(chain …)`

Most nets in a signal chain exist only to have a name. On `barracuda.sexp`,
`IF1_PAD`, `IF1_LNA`, `IF1_MIX`, `LO1_PAD`, `LO1_DRIVE`, `LO1_FILTERED` and
`LO1_SYNTH` each name one node between two adjacent parts and nothing else,
and every one of them also costs a `(rename …)` on each bridge that touches it.
`(connect …)` states such a node by naming its **ends**; `(chain …)` states a
whole cascade by naming the parts in order.

Both lower to exactly the pin-net and net-tie records `(pin …)`, `(net …)` and
`(bridge …)` already produce, so ERC, `(decouples …)`/`(near …)`, net classes,
`(net-envelope …)`, the KiCad exports and every PCB tool see an ordinary net.

```scheme
;; One node, four ends, no invented name:
(connect "U1.SCK" "flash/SCK" "hdr.4")

;; The same node with a name you can reference elsewhere:
(connect "U1.SCK" "flash/SCK" (name "SPI_SCK") (class "spi-fast"))
```

An **END** is one of four spellings:

| Spelling | Means |
| --- | --- |
| `"REF.PAD"` | A physical pad on a placed part. |
| `"REF.FN"` | A pinout **function name**, resolved through the part's `lib/pinouts/<name>.sexp` exactly as `(pin FN …)` does. |
| `"sub/PORT"` | A declared port of a sub-block — the same record a `(bridge …)` writes, so `checkUnconnectedPorts` counts the port as wired. |
| `"PORT"` / `"NET"` | A port of the enclosing block, or any ordinary net name. |

Resolution is deferred until the whole block is built, so an end may name a
part or a sub-block written **below** the `(connect …)`.

**No silent merges.** Wiring a pad that already carries a different net is an
error naming both nets; wiring a sub-block port a `(bridge …)` or `(net …)`
already wired is an error naming the line that wired it. Only two *anonymous*
nodes landing on one pad merge — they are the same node stated twice — and that
merge is reported as a warning, because nothing in the source spells it out.

#### The generated name

Without `(name …)`, and with no end that is already an ordinary net, the net is
named from the **authored end tokens**:

```
n~lpf4-OUTPUT~lpf_if_1-RF_IN
n~pad1-RF-OUT~lna-RF_IN
```

- `n~` is the reserved prefix. `~` is an RFC 3986 *unreserved* character, so
  the name needs no escaping in any URL; it is not `.` (the per-pin
  bypass-stub separator) and not `/` (the hierarchy separator); it survives the
  KiCad netlist and `.kicad_sch` export verbatim; and the leading letter keeps
  a shell from tilde-expanding it. Every generated name is nevertheless checked
  against the block's own net names, so a collision is impossible rather than
  merely unlikely.
- Identity comes from what the **source** says — `lpf4`, `pad1`, `lna/RF_IN` —
  never from a post-flatten ref-des, so the board's auto ref-des pass and a
  sub-block renumber both leave the name alone. A bare two-terminal chain item
  is spelled by its pinout function names for the same reason.
- Ends beyond a 60-character name collapse to the first end plus a hash of the
  full key, and a name already in use takes a `~2`, `~3`, … ordinal rather than
  merging two nodes.
- `(name "NET")` gives an authored name instead — which is how a net-class
  `(nets …)` list or a `(net-envelope …)` reaches the node. Both also accept
  the generated name as written.

#### `(chain …)`: a cascade in one line

`(chain "NET_A" ITEM… "NET_B")` wires two-port items in order, with one
anonymous net per gap. The first and last tokens are ordinary `(connect …)`
ends; each ITEM is:

| Spelling | Means |
| --- | --- |
| `"REF"` | A two-terminal part: in on its first pad, out on its second (pinout order, or `1`/`2` for a part with no pinout). A part with more pads is an error saying so. |
| `"sub"` | A sub-block whose module declares exactly one signal `out` port and, among the ports sharing that output's kind, exactly one `in`. Power, ground/bidi and `optional` ports are never candidates. Anything less definite is an error listing them. |
| `"REF/IN>OUT"` | The two terminals named explicitly — pad ids or pinout function names for a part, port names for a sub-block. |

Barracuda's IF chain — mixer → LFCW-6000+ → 2× LFCN-1575D+ → YAT-1A+ → LNA →
DSA — is seven nets and six `(rename …)` lines as it stands:

```scheme
(sub-block "mixer" (bcuda-mixer-mm1)
  (bridge "" GND (rename RF RF1_PAD) (rename LO LO1_FILTERED) (rename IF IF1_MIX)))
(instance "lpf4"     lfcw-6000+  (pin 1 "IF1_MIX")       (pin 3 "IF1_LPF2")      (pin 2 4 "GND"))
(instance "lpf_if_1" lfcn-1575d+ (pin 1 "IF1_LPF2")      (pin 3 "IF1_LFCN_MID")  (pin 2 4 "GND"))
(instance "lpf_if_2" lfcn-1575d+ (pin 1 "IF1_LFCN_MID")  (pin 3 "IF1_LFCN")      (pin 2 4 "GND"))
(instance "pad1"     yat-1a+     (pin 2 "IF1_LFCN")      (pin 5 "IF1_PAD")       (pin 1 3 4 6 7 "GND"))
(sub-block "lna" (tsy-83lnw-lna)
  (bridge "" (rename RF_IN IF1_PAD) (rename RF_OUT IF1_LNA)
             (rename VDD V_5VA) (rename VBYP LNA_VBYP) GND))
(sub-block "dsa" (bcuda-dsa-hmc1119)
  (bridge "" (rename LPF_RF IF1_LNA) (rename DSA_RF IF1_DSA) V_3V3A … GND))
```

The same chain, with only the two nets that are referenced elsewhere named:

```scheme
(sub-block "mixer" (bcuda-mixer-mm1)
  (bridge "" GND (rename RF RF1_PAD) (rename LO LO1_FILTERED)))
(instance "lpf4"     lfcw-6000+  (pin 2 4 "GND"))
(instance "lpf_if_1" lfcn-1575d+ (pin 2 4 "GND"))
(instance "lpf_if_2" lfcn-1575d+ (pin 2 4 "GND"))
(instance "pad1"     yat-1a+     (pin 1 3 4 6 7 "GND"))
(sub-block "lna" (tsy-83lnw-lna)
  (bridge "" (rename VDD V_5VA) (rename VBYP LNA_VBYP) GND))
(sub-block "dsa" (bcuda-dsa-hmc1119)
  (bridge "" V_3V3A … GND))

(chain "mixer/IF"
       "lpf4/INPUT>OUTPUT"
       "lpf_if_1/RF_IN>RF_OUT"
       "lpf_if_2/RF_IN>RF_OUT"
       "pad1/RF-IN>RF-OUT"
       "lna"                     ;; RF_IN → RF_OUT; VBYP is an `in` too, but a
       "dsa"                     ;;   different kind, so the rf pair is unique
       "IF1_DSA"
       (class "if-50"))
```

The four filters name their two terminals because each carries ground pads as
well; `"lna"` and `"dsa"` do not, because each module declares exactly one rf
input and one rf output. `mixer/IF` and `IF1_DSA` stay as they are — the first
is a sub-block port, the second is named in the board's `(pcb-plan …)` wave
lists — and the six nets between them become
`n~mixer-IF~lpf4-INPUT`, `n~lpf4-OUTPUT~lpf_if_1-RF_IN`, and so on.

### Bus ties: `(bus-net …)`

`(bus-net "PREFIX" LO HI "SUB")` is the documented form: it expands to one
`(net "PREFIX<i>" "SUB/PREFIX<i>")` tie per index in the inclusive range, so
`(bus-net "FLASH_IO" 0 7 "flash")` replaces eight verbatim lines and nothing
else.

Two further grammars hang off the same head and each record a
`deprecated_form` info:

```scheme
;; Strided: distribute a channel range sub-major across (over …) x (ports …).
(bus-net "ADF_CH" 1 10 (suffixes P N) (over "adc1" "adc2") (ports AINA AINB))

;; Mapped: one sub-block, a parent suffix, and an offset child-port family.
(bus-net "DUT_A" 0 2 (suffix "_MCU") (over "shift" (port-base "B" 1)))
```

Both still work. Neither reads as the same operation the basic form performs —
the index means a different thing in each — so what a `(bus-net …)` line does
cannot be known from its head. Prefer the basic form per sub-block, or spell
the ties out with `(net …)` / `(bridge …)`, generating them with `(for …)`
when there are many.

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

### System contracts: `src/systems/<name>/system.sexp`

A *system* is the layer above one board: which boards form the product, which
exact connector contacts join them, and which review documents belong beside
each fabrication archive. It is authored as ordinary netlisp source in
`src/systems/<name>/system.sexp` and read by `netlisp system-check`, the
readiness gate, the `/systems` pages and the release/dossier composers. The
complete form table is in
[docs/language-forms.md § System contract forms](language-forms.md).

```lisp
(system "barracuda"
  (title "Barracuda OC-303-1-01")
  (part-number "OC-303-1-01")
  (revision "B3")

  (board "barracuda"
    (role rf)
    (source "src/boards/barracuda/barracuda.sexp")
    (part-number "BARRACUDA-RF")
    (revision "B4")
    (layout "Barracuda V2")
    (dnp drop))

  (interface "j1-board-to-board"
    (mates "barracuda/J1" "barracuda-base/base-interface/J1")
    (contact-count 40)
    (signal "V_12V" (left 1 "V_12V") (right 1 "V_12V_RF"))
    (signal "GND"   (left 9 "GND")   (right 9 "GND")))

  (document "interface-control"
    (title "Board-to-Board Interface Control")
    (path "src/systems/barracuda/docs/interface-control.md")
    (classification design)
    (generated interface-matrix)))
```

A system contract is never *evaluated*. It is parsed straight into the strict
`netlisp-system-review-v1` spec that the older hand-maintained
`src/systems/<name>/system.json` also parses to, so none of these forms is
valid inside a design source, and a design writing `(interface …)` gets the
ordinary unknown-form warning.

**The JSON manifest still loads.** Where only `system.json` exists nothing
changes. Where both exist the `.sexp` is the contract, the JSON is inert, and
readiness says so with a `manifest_shadowed` finding. To migrate:

```bash
netlisp tool convert-system-manifest --project-dir <d> --args '{"system":"barracuda"}' \
  --output projects/designs/src/systems/barracuda/system.sexp
```

The converter is read-only — it prints the equivalent source and writes nothing
into the project — and the printed contract re-parses to the identical
canonical spec, so the migration is provably not a rewrite. It is safe to
delete the JSON afterwards; note that the HTTP manifest-editing endpoints
(`POST /api/systems/:name/attest` above all) still operate on `system.json`,
so a workspace that attests through the browser should keep the JSON form for
now.

#### Endpoint handles

`(mates "board/CONNECTOR" "board/CONNECTOR")` names the two mated connectors.
The **board** is the first path segment; everything after it is the connector's
stable source handle, which may itself be a sub-block path
(`barracuda-base/base-interface/J1`). That handle is deliberately *not* a
flattened ref-des: evaluator-wide numbering may turn a module-local `J1` into
`U19`, and a contract must not drift when an unrelated part is inserted.

#### Aliases are derived, not authored

The strict schema requires exactly one board-local→canonical alias per contact
whose endpoint-local net differs from the canonical name, and requires every
alias to describe a real contact — so the derivable set is the only valid set.
The sexp form therefore has no alias form: writing
`(signal "V_12V" (left 1 "V_12V") (right 1 "V_12V_RF"))` *is* the declaration
that `V_12V_RF` on the right board is the system's `V_12V`. One board-local net
carrying two canonical names is refused.

#### `(auto)`: derive the contact table from the boards

```lisp
(interface "j1-board-to-board"
  (mates "barracuda/J1" "barracuda-base/base-interface/J1")
  (auto)
  (signal "IF1_DSA" (left 15) (right 15)))
```

`(auto)` walks the left connector's pad table, pairs each pad with the right
connector's same-numbered pad, and reads the net each side reaches. Pad ids
compare numerically, so a pinout file's `01` and a design source's `1` are one
contact. A contact the right connector does not carry is an error, not a
silently dropped row. A pad wired on one side only keeps the wired net as its
canonical name and gives the dead side a synthetic no-net name, so a derived
contract never invents a net that could collide with a real one.

An explicit `(signal …)` inside an `(auto)` interface **overrides one derived
contact** — its canonical name, its `optional` flag, and either endpoint net
you choose to restate. It must name a contact both connectors carry, and two
signals may not claim one contact.

`(auto)` is for bring-up, where the contract is "whatever the boards currently
say". A released product should carry the explicit table: that is what makes a
later wiring change show up as a diff rather than as a silently updated
contract.

#### `interface_mismatch` findings

Whatever the manifest's format, `netlisp system-check` and
`GET /api/systems/:name/readiness` check the contract against both boards'
evaluated netlists and connector pad tables. Error-severity findings clear the
`interface_contract` readiness check and block a release:

| Finding | Severity | Meaning |
| --- | --- | --- |
| `contact_unconnected_one_side` | error | The contact reaches a net on one side and nothing — no net, or a net the board's own rule checks call floating — on the other. |
| `voltage_domain_mismatch` | error | A **required** signal joins two nets that are both supplies or grounds but sit at different *declared* nominal potentials (ground is 0 V by definition). Undeclared potentials are not guessed. |
| `unknown_contact_pin` | error | A signal names a pad the connector's pinout does not carry. |
| `contact_count_over_pads` | error | The contract claims more contacts than the connector has pads. |
| `duplicate_contact_claim` | error | Two signal records claim one physical contact. |
| `contacts_not_covered` | warning | The connector has more pads than the contract covers — shield, mounting and spare pads are normal. |
| `connector_pinout_unavailable` | warning | The connector's pad table could not be read, so the pin-existence and pad-count checks did not run for that endpoint. Absent evidence is said out loud rather than passed silently. |

Two differing net **names** across the joint are never a mismatch. Pairing
`V_12V` with `V_12V_RF` is exactly what the canonical/alias layer is for; a
check that flagged it would fire on every real contract.

Where each is documented, all of it generated from the evaluator's own
tables:

| Where | Generated reference |
| --- | --- |
| Design-block scope | [language-forms.md § Design-scope forms](language-forms.md), row `(group …)` |
| `(diagram-layout …)` | [language-forms.md § Design-scope forms](language-forms.md), inside the `(diagram-layout …)` row's syntax |
| `(pins "REF" …)` | [language-forms.md § Instance sub-forms](language-forms.md), in the `(pins "REF" …)` children table at the end of that section |
| `(rough …)` | [language-forms.md § Design-scope forms](language-forms.md), inside the `(rough …)` row's syntax |

When in doubt, check the arity — a parenthesised member list means the
design-scope form.
