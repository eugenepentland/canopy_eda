# EDA DSL Reference

This document is the source-of-truth catalog for every form a `.sexp` file
in this project may contain, plus the auxiliary file formats produced by
the build pipeline. It is indexed against the Zig evaluator under
`src/eval/`, the parser under `src/sexpr/`, and real example files under
`projects/designs/`.

## 1. Overview

The schematic / library / board language is an S-expression DSL evaluated
by the Zig interpreter in `src/eval/evaluator.zig`. A single `.sexp` file
can declare imports, parameterised modules (`defmodule`), one or more
`(design-block …)` results, optional `(board …)` wrappers, and the usual
component-library forms. Evaluation produces an in-memory `DesignBlock`
(or `Board`) plus side-effects: assertions accumulate, `(id …)` markers
get auto-inserted into the source via the pending-ID write-back list,
and BOM / layout sidecar files are reconciled. Every AST node carries a
byte/line span (`src/sexpr/ast.zig:3`) so the printer at
`src/sexpr/printer.zig` can round-trip a design without lexical drift, and
`src/eval/ids.zig` can graft 8-char hex IDs onto un-frozen forms in place.

Stable identity is the load-bearing invariant: every `instance`, `series`,
and `decouple` form gets either an explicit `(id <hex8>)` marker or a
freshly generated one that's flushed back to disk on the next build, so
ref-deses can be reshuffled or modules can be parameterised differently
without breaking the BOM/layout linkage.

## 2. Lexical syntax

Defined in `src/sexpr/tokenizer.zig`.

### Comments

Line comments start with `;` and run to end of line. Block comments do
not exist. (`src/sexpr/tokenizer.zig:78`)

```scheme
;; This is a comment
;; Multi-line comments are just multiple ;; lines.
```

### Strings

Double-quoted, with `\` for escape continuation (only the byte after the
backslash is consumed; no escape interpretation). Newlines inside strings
are illegal because the tokenizer reads byte-at-a-time and fails on
unterminated strings (`src/sexpr/tokenizer.zig:133`).

```scheme
"VDD" "ad7380-4.pdf" "VOUT must be 0.6V to 16V"
```

### Numbers

Three numeric token tags (`src/sexpr/tokenizer.zig:152`):

- `int` — `42`, `-5`. Plain decimal integer, optional leading `-`.
- `float` — `3.3`, `-0.6`. Decimal point is mandatory in source for a
  float; the cap-family value `"100nF"` is a quoted string, not a float.
- `unit_val` — `1.0mm`, `10mil`. Numeric followed by `mm` or `mil`. The
  parser converts the value to millimetres (1 mil = 0.0254 mm) and stores
  the float in `Node.tag.unit_val`.

Numbers followed immediately by atom-continuation characters get
re-tokenised as atoms (`src/sexpr/tokenizer.zig:201`) so identifiers
like `204928-0301.stp` and `12.5abc` survive intact.

### Atoms

An atom starts with `[a-zA-Z_~*]` and continues with `[a-zA-Z0-9_~*\-/.#@:]`
(`src/sexpr/tokenizer.zig:238`). The single-char operators `+ - * / %`
and the comparisons `> < = ! >= <= == !=` are also lexed as atoms
(`src/sexpr/tokenizer.zig:224`). Examples:

```text
res-0402   stm32n657l0h3q   USB2.0-HS   ~{CS}   ad7380-4bcpz   K5
```

The first character of an auto-generated 8-char hex ID is always one of
`a`-`f` so the tokenizer never mis-classifies it as a number
(`src/eval/ids.zig:264`).

### S-expression structure

Source is a sequence of top-level expressions. Each expression is either
a literal (atom / number / string) or a list `( … )` of children. There
is no quoting / unquoting / quasi-quoting; everything is positional or
keyword-by-head-atom. Every `(form …)` shape is dispatched by inspecting
the head atom; arguments are evaluated lazily for special forms and
eagerly for builtins (`src/eval/evaluator.zig:215`).

## 3. Top-level design forms

### `(import name1 name2 …)` — bring library files into scope

Resolves each name as a file under `lib/components/<name>.sexp` then
`lib/modules/<name>.sexp`, in `project_dir` then in the shared `lib_dir`
(`src/eval/modules.zig:43`). Components register in
`component_cache`; modules evaluate the file in a heap-owned env and
copy the resulting `ModuleDef` binding into the caller's env.

```scheme
(import stm32n657l0h3q
        cap-0201 cap-0402 cap-0603 cap-0805
        res-0402 ind-1616 ind-2016 ferrite-0402)
```

`projects/designs/src/stm32n6/stm32n6.sexp:1`

Gotchas:
- The same name cannot be both a `lib/components/` and a `lib/modules/`
  file — components are checked first.
- `(import x)` is a no-op if `x` is already cached / bound.
- A file is identified as a component iff its first top-level form is
  `(component …)` or `(component-family …)`; otherwise it's a module
  (`src/eval/modules.zig:64`).

### `(defmodule name (params…) "doc?" body…)` — parameterised macro

Captures the module file's lexical env at definition time so calls
resolve `import`s the module declared (`src/eval/modules.zig:253`). A
docstring is optional; everything after it is the body, evaluated in
order when the module is called.

```scheme
(defmodule tpsm84338 (rfbt rfbb rled)
  "3A Buck Converter with Power Good LED.
   VIN: 3.8V-28V, VOUT: 0.6V-16V, IOUT: 3A."
  (let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
  (assert-range vout 0.6 16.0 "VOUT")
  (design-block (fmt "~V Buck (TPSM84338)" vout)
    (instance "U1" tpsm84338rcjr (pin 1 "EN") …)))
```

`projects/designs/lib/modules/tpsm84338.sexp:8`

Gotchas:
- Calling arity must match exactly; surplus or missing args raise
  `ArityError` (`src/eval/modules.zig:297`).
- Module bodies almost always end with a `(design-block …)`. The return
  value of the last body expression is what flows out at the call site.

### `(design-block "name" body…)` — emit a `DesignBlock`

The name evaluates first (so `(fmt …)` template strings work) and the
remaining children are dispatched by head atom into the design's
instance/port/note/group/section/sub-block/series/decouple/verifies
buckets (`src/eval/design_block.zig:37`). Top-level `config` and
unrecognised forms are skipped silently.

```scheme
(design-block "ADF5901 24GHz Tx MMIC"
  (instance "U1" adf5901acpz …)
  (port "AVDD_TX" in (rated 3.15 3.45))
  (group "Loop Filter" ("R3" "R4" "R5" "C17" "C18" "C19")))
```

`projects/designs/src/rf/adf5901.sexp:7`

Gotchas:
- `design-block` automatically runs ref-des prescanning, auto-aliasing
  via pinout pin functions, ref-des renaming for descriptive labels,
  and `validate.validateDesign(…)`.
- Net-ties synthesised from pin-function matching (`is_auto = true`)
  are dropped before the block is stored to avoid bridging unrelated
  nets across blocks (`src/eval/design_block.zig:608`).

### `(sub-block "name" <expr>)` — embed another design block

The second arg can be a `.sexp` path string evaluated against
`project_dir`, or a module call expression (anything that yields a
`design_block` value). Each nested instance gets its ID re-derived from
the sub-block name + ref-des so IDs stay stable across rebuilds even
when the same module is instantiated more than once
(`src/eval/builders.zig:591`).

```scheme
(sub-block "battery" "blocks/battery-1s-lipo.sexp")
(sub-block "buck"    (tpsm84338 220000 47000 1000))
```

`projects/designs/src/stm32n6/stm32n6.sexp:427` (file path form),
`projects/designs/src/power/tpsm84338.sexp:5` (module-call form)

Gotchas:
- `pending_ids` from the sub-block evaluation are dropped — only the
  outer design's source file gets ID-frozen by `commands.zig`
  (`src/eval/builders.zig:611`).
- Sub-block ports are joined to parent nets with explicit `(net …)`
  forms (next section); there is no implicit upward propagation.

## 4. Section + layout primitives

### `(section "name" "description?" body…)`

Wraps related instances and pin assignments into a named group rendered
as a card in the schematic and review pages. The optional second
positional string is a description; everything after that is dispatched
through `evalSection` (`src/eval/design_block.zig:236`). Recognised
sub-forms: `status`, `role`, `description`, `note`, `port`, `protocol`,
`calc`, `instance`, `pins`, `decouple`, `series`, `net`, and nested
`section`.

```scheme
(section "USB" "USB 2.0 High-Speed with Type-C connector (USB4235-03-C)"
  (role input)
  (protocol USB2.0-HS)
  (port "VDDA18USB" in power 1.8)
  (pins "stm32"
    (pin D4 "VDDA18USB" (i-typ 0.025) (i-max 0.04))
    (pin C1 (as "USB2_OTG_HS_DP") "USB_DP"))
  (instance "usb-c" usb4235-03-c …))
```

`projects/designs/src/stm32n6/stm32n6.sexp:231`

Gotchas:
- Section status defaults to `concept` if the section has no instances
  or pin-groups, otherwise `implemented`. Override explicitly with
  `(status concept|implemented|review)` (`src/eval/design_block.zig:351`).
- `(role input)` / `(role output)` is a block-diagram hint; defaults to
  `auto` when absent.

### `(pins "ref-des" sub-forms…)` — assign pins on an existing instance

Used inside a section to attach pins of a top-level instance to the
section's diagram + master table. Each `(pin …)` entry inside is
identical to the one inside `(instance …)`, but the resolved `(ref_des,
pin, net)` triples are also attached as a `Part` to the parent
instance, with the section name as the part's title
(`src/eval/design_block.zig:373`, `addPartToInstance` at
`src/eval/builders.zig:637`).

```scheme
(pins "stm32"
  (group "VDD Power")
  (pin J14 K14 L14 "VDD" (i-typ 0.08) (i-max 0.15))
  (pin F1 "VDD" (i-typ 0.0001) (i-max 0.001))
  (pin H6 "VDDA18AON" (i-typ 0.0001) (i-max 0.005))
  (pin A19 F12 H14 N16 "GND"))
```

`projects/designs/src/stm32n6/stm32n6.sexp:42`

Gotchas:
- `(group "label")` inside a `(pins …)` form labels every pin in the
  block (rendered as the leftmost column in the master table).
- `(pin …)` syntax is shared with inline instance pins; see §5.

### `(calc "name" sub-forms…)` — named scalar calculation block

Runs a small env where `(let …)` sets variables and the resulting numeric
bindings get surfaced into the section card. Also accepts
`(assert-range …)` and `(assert …)` whose results land in the global
assertion list (`src/eval/builders.zig:118`).

```scheme
(calc "HSE load capacitors"
  (let cl 10.0)
  (let cstray 5.0)
  (let cload (* 2.0 (- cl cstray))))
```

`projects/designs/src/stm32n6/stm32n6.sexp:32`

### `(protocol NAME)` — section protocol annotation

Bare atom listing communication protocols this section uses (e.g.
`SPI`, `I2C`, `OctoSPI`, `USB2.0-HS`). Multiple `protocol` forms in one
section accumulate (`src/eval/design_block.zig:308`).

## 5. Instance forms

### `(instance "ref-des" <component> body…)`

The ref-des can be a standard pattern (`U1`, `R23`, `SW2`) or a
descriptive label (`stm32`, `flash`, `usb-c`). Descriptive labels get
auto-renamed to a standard ref-des at design-block-finalise time using
the prefix from `componentPrefix` (`src/eval/ids.zig:211`); references
inside nets / notes / sections are rewritten to match.

The `<component>` slot is either a bare atom referencing a fixed
component (`adf5901acpz`) or a family invocation `(family "value" …attrs)`
(`(cap-0402 "100nF" x7r)`). Family attrs are propagated as
schematic-level decorations like dielectric class.

Body sub-forms (`src/eval/instance.zig:148`):
- `(pin …)` — see below.
- `(bus "NET_PREFIX" "BUS_NAME")` — expand a `(bus …)` definition from
  the component's library entry (`src/eval/instance.zig:166`).
- `(note "text")` — short text annotation pinned to this instance.
- `(id <hex8>)` — explicit stable identity. Auto-inserted on next build
  if absent.
- Anything else `(key "val")` — captured as an inline property override
  that merges over the component's library properties
  (`src/eval/instance.zig:188`).

```scheme
(instance "U1" adf5901acpz
  (pin 1 3 6 8 10 12 13 19 33 "GND")
  (pin 4 5 14 16 17 30 "AVDD_TX")
  (pin 2 "TX_OUT1")
  (pin 7 "TX_OUT2")
  (pin 29 "VTUNE") (id e33105ce))
```

`projects/designs/src/rf/adf5901.sexp:9`

Gotchas:
- The component slot must resolve through `component_cache`. If the
  family was never `import`ed, evaluation fails with `UnboundVariable`
  (`src/eval/instance.zig:115`).
- Pin tokens are first looked up in the pinout's reverse map (function
  name → pin id) and only fall back to literal pin id when the lookup
  misses (`src/eval/instance.zig:285`). That's what makes
  `(pin "VCC" "3V3")` work alongside `(pin 4 "3V3")`.

### `(pin <pinspec…> "NET" annotations…)`

Pin spec is one or more pin tokens — each is a number, atom (BGA ball
like `J14`), or string (function name like `"VCC"`). When more than one
token appears, every listed pin joins the same net
(`src/eval/instance.zig:281`).

Annotations the parser strips off the tail before extracting the net
(`src/eval/instance.zig:241`):
- `(i-typ X)` — typical current draw (A) on this pin's rail. Only the
  first physical pin in a multi-pin form carries the value, so summing
  across nets doesn't double-count.
- `(i-max X)` — absolute-max current.
- `(as "FN1" "FN2" …)` — assert one or more alternate functions for
  this pin. Only meaningful on single-pin forms; otherwise silently
  dropped (`src/eval/instance.zig:275`).

```scheme
(pin J14 K14 L14 "VDD" (i-typ 0.08) (i-max 0.15))
(pin J19 (as "FMC_D21") "DATA_BUS_21")
(pin C1 (as "USB2_OTG_HS_DP") "USB_DP")
```

`projects/designs/src/stm32n6/stm32n6.sexp:44`, `…:239`

Gotchas:
- The function-name reverse-lookup means `(pin "VDD" "POWER_NET")` works
  iff the component's pinout file declares a pin whose function name is
  `"VDD"`. If multiple pins share that function name, only the first
  match wins.
- Auto-aliasing creates a hidden net-tie between the user's net name and
  the pinout's function name (`src/eval/builders.zig:288`). This is what
  makes `VDDA18USB` (port name) merge with the function-name `VDDA18USB`
  on the STM32's symbol.
- The `(part "label" (row N) (col M) …)` multi-part placement form from
  the older docs is no longer parsed by the current evaluator. Use a
  `(section …)` with a `(pins "REF" …)` sub-form to achieve the same
  visual grouping.

### `(bus "PREFIX" "BUS_NAME")` — instance-side bus expansion

Looks up `(bus "BUS_NAME" pin1 pin2 …)` in the component's library entry
(see §9 — that decl is on the component, not the instance) and emits one
pin-net entry per bus pin with net name `<PREFIX><idx>` starting at 0
(`src/eval/instance.zig:166`).

```scheme
(instance "flash" mx66uw1g45gxdi00
  (bus "FLASH_IO" "SIO")
  …)
```

`projects/designs/src/stm32n6/stm32n6.sexp:280`

### `(bus "PREFIX" pin1 pin2 … (as-prefix "FN_PREFIX")?)` — `(pins …)` bus form

Inside a `(pins "REF" …)` block (not a `(instance …)` body), `bus` lists
the pin tokens directly and optionally adds an `(as-prefix "X")` so each
lane is asserted as the function `<X><bus-idx>` without writing one
`(pin …)` per lane (`src/eval/builders.zig:253`).

```scheme
(bus "FLASH_IO" (as-prefix "XSPIM_P2_IO") PN2 PN3 PN4 PN5 PN8 PN9 PN10 PN11)
```

`projects/designs/src/stm32n6/stm32n6.sexp:273`

### `(series …)` — pair-of-pins helper

Two shapes (`src/eval/instance.zig:407`):

- Named: `(series "REF" (component-expr) "NET_A" "NET_B" key/val/note…)`
  — emits one instance with pin 1 on `NET_A` and pin 2 on `NET_B`.
  Trailing `(key "val")` forms become inline properties; one trailing
  `(note "text")` becomes the instance note.
- Auto: `(series (component-expr) "NET_A1" "NET_B1" "NET_A2" "NET_B2" …)`
  — one instance per consecutive net pair, ref-deses auto-assigned
  using the family's prefix.

```scheme
(series "R10" (res-0201 "10k") "FLASH_RESET" "VDDIO3" (id c734428e))
(series (cap-0402 "10pF" np0) "OSC_IN" "GND" "OSC_OUT" "GND" (id b5986a13))
```

`projects/designs/src/stm32n6/stm32n6.sexp:283`, `…:152`

Gotchas:
- Net counts must be even in the auto form; an odd trailing net is
  silently dropped.
- Each emitted instance gets a deterministic child ID derived from the
  series form's parent ID + net + index (`deriveChildId`).

### `(decouple …)` — bypass-cap helper

Two shapes (`src/eval/design_block.zig:180`):

- Single-net: `(decouple "NET" (component-expr) COUNT per-pin REF [PIN])`
  — emits `COUNT` capacitor instances per matching pin on the named
  reference. Optional trailing `PIN` token narrows the target to a
  specific pin id; otherwise every pin currently on `NET` (or any
  per-pin-net subnet `NET.REF.…`) qualifies.
- Multi-net: `(decouple (component-expr) COUNT per-pin REF "NET1" "NET2" …)`
  — same semantics, run once per listed net.

A wrapping `(bulk …)` / `(bypass …)` block can group multiple
sub-decouple specs under one `NET`.

```scheme
(decouple "VDDCORE" (cap-0603 "15uF") 4 per-pin stm32 P7 (id cfc02418))
(decouple (cap-0201 "100nF") 1 per-pin stm32 "VDDIO2" "VDDIO3" "VDDIO4")
```

`projects/designs/src/stm32n6/stm32n6.sexp:112`, `…:121`

Gotchas:
- The `per-pin` keyword is required; missing it raises `InvalidForm`
  (`src/eval/builders.zig:362`).
- `decouple` rewrites the target instance's pin net to a per-pin subnet
  (`NET.REF.PIN`) so each cap drops on its own subnet. Net-ties merge
  these back into `NET` for export but the schematic shows each cap on
  its own node (`src/eval/builders.zig:425`).

### `(net "NET" "PIN_REF1" "PIN_REF2" …)` — net-tie / sub-block bridging

Inside a design-block (or section), declares that a primary net "NET"
is the same as one or more secondary names. Used heavily to bridge
sub-block ports to parent rails via the sub-block prefix
(`src/eval/design_block.zig:166`).

```scheme
(net "VBATT" "battery/VBATT" "charger/VBATT" "buck/VIN")
(net "VREF_2V5" "adc1/REFIN" "adc2/REFIN" "adc3/REFIN")
```

`projects/designs/src/stm32n6/stm32n6.sexp:440`, `…:552`

Gotchas:
- The validator warns on combinable nets — same-prefix names declared in
  multiple sections that look like they should have been written as a
  single `(net …)` (`src/eval/validate.warnCombinableNets`).
- Per-pin subnets like `VDDCORE.stm32.P7` get rewritten too when a tie
  swallows the parent (`src/eval/design_block.zig:622`).

## 6. Connectivity primitives

### `(port "name" [net] direction sub-clauses…)`

The short form uses the port name as the net name; the long form takes
a separate net string (`src/eval/builders.zig:449`). Direction is one
of `in`, `out`, `bidi`, `io`. Optional sub-clauses:

- `(rated <min> <max>)` — voltage envelope.
- `(nominal <V>)` — nominal voltage.
- `(current <typ> [max])` — current capacity.
- `(efficiency <ratio>)` or `(efficiency linear)` — power-budget hint
  for output ports of regulators.
- `(enable "NET")` — name of the rail that gates this output.
- `optional` — bare keyword; suppresses ERC for unconnected port.

```scheme
(port "VIN"  in  (rated 3.8 28.0))
(port "VOUT" vout-str  out  (rated 0.6 16.0))
(port "GND"  bidi)
(port "VOUT" out (nominal 1.8) (rated 1.7 1.9) (current 0.4 0.5)
              (efficiency linear) (enable "EN"))
```

`projects/designs/lib/modules/tpsm84338.sexp:84`,
`projects/designs/blocks/ldo.sexp:26`

Gotchas:
- `(rated …)` requires both bounds.
- Long form with identical name and net emits a warning steering you to
  the short form (`src/eval/builders.zig:481`).

Section-level ports use a different parser (`parseSectionPort` at
`src/eval/builders.zig:29`) and additionally accept signal-type atoms
(`power`, `signal`, `clock`, `data`, `differential`), the keyword
`optional`, a numeric voltage, group strings, and the keywords `role X`
and `protocol X`.

```scheme
(port "VDD" in power 3.3)
(port "NRST" out signal role reset)
(port "EXP" io data)
(port "ADF_CH1P" in differential)
```

### `(note …)` — annotations

Three shapes:

- `(note "text")` — section-level note pinned to the section, no
  ref-des link. Lives inside `(section …)` (`src/eval/design_block.zig:291`).
- `(note "text" (ref "file.pdf" (page N) (quote "verbatim")?))` — same,
  with a PDF-page citation that the review's PDF viewer auto-highlights.
- `(note "REFDES" "text")` — design-block-level note attached to a
  specific instance (`src/eval/builders.zig:557`).

```scheme
(note "U1" "TPSM84338RCJR: 3.8-28V, 3A synchronous buck module.")
(note "F1 (VBAT) tied to VDD — LiPo 4.2V exceeds VBAT max (3.6V)")
(note "NC tied to GND per datasheet (GND/IN/OUT/open all allowed)")
```

`projects/designs/lib/modules/tpsm84338.sexp:90`,
`projects/designs/src/stm32n6/stm32n6.sexp:160`,
`projects/designs/blocks/ldo.sexp:31`

`(ref "file.pdf" (page N) (quote "…"))` is the same shape used by
component requirements and is parsed by `parseNoteRef`
(`src/eval/env.zig:458`). The `(quote …)` clause must contain a single
distinctive line for the viewer's per-span match to land reliably.

### `(group "label" ("REF1" "REF2" …))`

Visual grouping for the schematic renderer. The members slice is a list
of ref-des strings (`src/eval/builders.zig:569`).

```scheme
(group "Loop Filter" ("R3" "R4" "R5" "C17" "C18" "C19"))
```

`projects/designs/src/rf/adf5901.sexp:138`

### `(verifies (req "REFDES" REQID) "rationale" sub-clauses…)`

Top-level design-block sign-off that explicitly answers a library
`(requirement …)` the netlist alone can't auto-check. The short form
takes a single trailing string (the rationale); the long form uses
`(rationale "…")`, `(signed-off-by "…")`, and `(date "…")` sub-clauses
(`src/eval/design_block.zig:663`).

```scheme
(verifies (req "U2" b68c3fa5)
  "Power-up sequence (VDD/VBAT/VDDA18_AON before VDDCORE) is enforced
   by topology: VDD comes up from the buck once VBATT is present; …")
```

`projects/designs/src/stm32n6/stm32n6.sexp:682`

Gotchas:
- The `REQID` is matched against `Requirement.id`, which is either the
  explicit `(id …)` inside the requirement or the CRC32 of the
  requirement text (`src/eval/env.zig:214`).
- All-digit hex IDs like `41510609` must be quoted as a string in the
  source — bare digits would be parsed as a decimal int. The id-freezer
  quotes these automatically.
- A failing `(check …)` on the same requirement does **not** silently
  flip the status to `verified`; the review marks it
  fail-with-override (`src/eval/env.zig:170`).

## 7. Special forms / control flow

Defined in `src/eval/special_forms.zig`.

### `(let name expr)`

Bind `name` in the current env to the evaluated value of `expr`. Returns
nil. Body-of-let is implicit — the surrounding scope continues to see
the binding (`src/eval/special_forms.zig:15`).

```scheme
(let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
(let vout-str (fmt "~V" vout))
```

### `(if cond then else)`

Three-arity, short-circuiting. `else` is required (no implicit nil).
Truthy values are everything except `nil`, the boolean `false`, and the
number `0` (`src/eval/env.zig:54`).

```scheme
(if (> 5 3) "yes" "no")
```

### `(cond (test1 expr1) … (else exprN))`

Walks each clause in order; returns the first matching clause's
expression. The atom `else` matches unconditionally
(`src/eval/special_forms.zig:39`).

### `(fmt "template" args…)`

Lisp-flavoured directive printer (`src/eval/fmt.zig:25`):

- `~V` — voltage. Uses raw value with `V` suffix; whole numbers print
  without decimals; `1.85` → `1.85V`.
- `~R` — resistance. Auto-prefix M/k for magnitudes ≥ 1e6 / 1e3, else
  raw. `220000` → `220k`, `1500000` → `1.5M`.
- `~C` — capacitance. Auto SI prefix `mF/uF/nF/pF/F`. `0.000001` →
  `1uF`, `0.000000022` → `22nF`.
- `~A` — amperage. Auto `uA/mA/A`. `0.15` → `150mA`, `0` → `0A`.
- `~S` — string. Direct passthrough; argument must already be a string
  value.
- `~~` — literal `~`.

```scheme
(fmt "~V Buck (TPSM84338)" vout)
(fmt "RFBT = ~R, RFBB = ~R" rfbt rfbb)
(fmt "RLED = ~R. IF = (~V - 2.8V) / ~R." rled vout rled)
```

`projects/designs/lib/modules/tpsm84338.sexp:24`

Gotchas:
- Literal `%` characters need to be doubled inside string literals
  passed to `fmt` (Zig stdlib formatter quirk; see
  `tpsm84338.sexp:93` "RFBB = ~R (1%%)").
- Number formatting trims trailing zeros after the decimal but keeps the
  whole-number-no-decimal special case (`src/eval/fmt.zig:132`).

### `(assert cond "message")`

Append a pass/fail entry to `evaluator.assertions`. The build never
aborts on failure — the review page surfaces the failures
(`src/eval/special_forms.zig:87`).

### `(assert-range value lo hi "label")`

Special-case of `assert` with a formatted message
`<label> = <v> (range <lo>-<hi>)` (`src/eval/special_forms.zig:103`).

```scheme
(assert-range vout 0.6 16.0 "VOUT")
```

`projects/designs/lib/modules/tpsm84338.sexp:21`

## 8. Builtins

All defined in `src/eval/builtins.zig`. Arity is fixed at 2 except for
`not` which is 1.

### Arithmetic (`+ - * / %`)

Two operands, both numeric. `/` and `%` raise `DivisionByZero` on a
zero divisor (`src/eval/builtins.zig:41`).

### Comparison (`> >= < <=`)

Two numeric operands; returns a boolean (`src/eval/builtins.zig:63`).

### Equality (`==` / `!=`)

Two operands, either both numeric or both string. Mixed types raise
`TypeError` (`src/eval/builtins.zig:76`).

### Logic (`and or not`)

`and` / `or` use `isTruthy` semantics (`src/eval/builtins.zig:92`).

There are no list / string-manipulation builtins beyond the format
directives in `(fmt …)`.

```scheme
(* 0.6 (+ 1.0 (/ rfbt rfbb)))
(- vout 2.8)
(/ 150.0 (/ rilim 1000.0))
```

`projects/designs/lib/modules/tpsm84338.sexp:13`

## 9. Component library forms

Component files live in `lib/components/<name>.sexp`. The first
top-level form is either `(component …)` or `(component-family …)`.

### `(component "name" body…)`

Fixed library part. Recognised body fields
(`src/eval/modules.zig:99`):

- `(description "text")` — surfaced on every instance.
- `(symbol <atom>)` — symbol library name.
- `(footprint <atom>)` — footprint library name.
- `(pinout <atom>)` — pinout library name (defaults to symbol when
  missing).
- `(manufacturer "X")`, `(mpn "Y")`, `(datasheet "file.pdf")` — repeats
  for additional datasheets.
- `(requirement "text" …)` — see below.
- `(ignore-requirements)` — bare zero-arg marker; opts the part out of
  the missing-requirements review summary (mounting hardware, debug
  headers, etc.).
- `(bus "name" pin1 pin2 …)` — bus expansion lookup table for instance
  `(bus …)` forms.
- Any other `(key "value")` becomes a property propagated onto every
  instance.

```scheme
(component "ad7380-4bcpz"
  (description "Differential Input, Quad, External Reference Simultaneous Sampling, 16-Bit, SAR ADC")
  (pinout "ad7380-4bcpz")
  (footprint "qfn50p400x400x60-25n-d")
  (manufacturer "Analog Devices")
  (mpn "AD7380-4BCPZ")
  (datasheet "ad7380-4.pdf")
  (requirement "VCC must be 3.0 V to 3.6 V"
    (ref "ad7380-4.pdf" (page 4) (quote "VCC 3.0 3.3 3.6 V"))
    (check (voltage-range (pin "VCC") (min 3.0) (max 3.6)))))
```

`projects/designs/lib/components/ad7380-4bcpz.sexp:1`

### `(component-family "name" body…)`

Parameterised passive (`src/eval/modules.zig:219`). Adds:

- `(parameter "value" capacitance|resistance|…)` — parameter type tag,
  used by some renderers but otherwise informational.

```scheme
(component-family "cap-0402"
  (description "cap-0402 passive component")
  (symbol generic-cap)
  (footprint c-0402)
  (parameter "value" capacitance))
```

`projects/designs/lib/components/cap-0402.sexp:1`

Family invocation at use site:

```scheme
(cap-0402 "100nF")          ;; one positional value
(cap-0402 "10pF" np0)        ;; trailing atoms become attrs
```

The first positional arg is the parameter value (string); subsequent
atoms or strings are stored on the instance as `attrs` for downstream
renderers (`src/eval/evaluator.zig:251`).

### `(requirement "text" sub-clauses…)`

Library-side rule for using the part. Sub-clauses
(`src/eval/modules.zig:144`):

- `(ref "file.pdf" (page N) (quote "verbatim")?)` — datasheet citation.
- `(check (<primitive> …))` — automated check (see below).
- `(id <hex8>)` — explicit stable ID. Otherwise auto-derived from CRC32
  of the requirement text (`src/eval/env.zig:214`).

### `(check …)` primitives

The `(check (<kind> …))` body inside a requirement is parsed by
`parseCheck` (`src/eval/env.zig:297`). Pin references inside checks use
*function* names from the pinout, not physical pin IDs — a single
function name resolves consistently across boards even when the pinout
changes.

| Primitive | Body | Meaning |
|---|---|---|
| `connected` | `(pin "A") (pin "B")` | Both pins must be on the same net. |
| `decoupling` | `(pin "A") (pin "B") (min-uf F)` | At least one cap ≥ F µF must bridge those pin nets. |
| `decoupling-per-pin` | `(return-pin "GND") (pins "VDD_1" …) (min-uf F) (count N)` | Per-listed-pin cap ≥ F µF; total distinct caps ≥ N. |
| `pullup-range` | `(pin "P") (net "N") (min-ohms L) (max-ohms H)` | A resistor in `[L, H]` ohms must bridge pin P's net and N. |
| `voltage-range` | `(pin "V") (min L) (max H)` | The port on V's net must sit inside `[L, H]` V. |
| `tied-to-net` | `(pin "P") (net "N")` | Pin P must resolve to net N. |
| `not-connected` | `(pin "P")` | Pin P must be unconnected. |
| `pin-not-floating` | `(pin "P")` | Pin P must have a non-empty net with co-pins. |
| `pins-on-same-net` | `(pins "A" "B" "C" …)` | Every listed function-pin must be on the same net. |
| `series-element` | `(kind R\|L\|C) (pin "P") (target-net "N") (min X) (max Y)` | An R/L/C of value in `[X, Y]` between P's net and N. |

```scheme
(requirement "VCC must be 3.0 V to 3.6 V"
  (ref "ad7380-4.pdf" (page 4) (quote "VCC 3.0 3.3 3.6 V"))
  (check (voltage-range (pin "VCC") (min 3.0) (max 3.6))))

(requirement "All four GND pins (1, 5, 14, 16) must be connected"
  (check (pins-on-same-net (pins "GND_1" "GND_2" "GND_3" "GND_4"))))
```

`projects/designs/lib/components/ad7380-4bcpz.sexp:8`,
`…:17`

## 10. Pinout file format

Pinout files live in `lib/pinouts/<name>.sexp` and are loaded lazily on
first reference (`src/eval/ids.zig:360`). They are auto-generated by
`eda convert-pinout <file.kicad_sym>` and start with a marker comment.

```scheme
;; Auto-generated pinout — DO NOT EDIT
;; Source of truth for pin ID → function name mapping
(pinout "AD7380-4BCPZ"
  (pin 1 "GND_1")
  (pin 4 "VCC")
  (pin 25 "EP")
  (pin 18 "~{CS}"))
```

`projects/designs/lib/pinouts/ad7380-4bcpz.sexp:1`

`(pinout "name" (pin <id> "FUNC" alts…)…)` — top-level form parsed by
`loadPinoutFile` (`src/eval/ids.zig:360`). The `<id>` is whatever the
footprint uses (numbers `1..N`, BGA balls `J14`, multi-letter `PN1`).
Function names may include KiCad-style overbar markers (`~{CS}`,
`DQS/_DM0`).

### `(alt "FN" etype?)` — alternate functions

Multi-function pins on MCUs/FPGAs declare each AF on its own line. The
optional second argument is the electrical type atom (`io`, `input`,
`output`, etc.) and defaults to empty (`src/eval/ids.zig:380`).

```scheme
(pin J19 "PP5"
  (alt "FMC_D21" io)
  (alt "XSPIM_P1_IO5" io))
```

`projects/designs/lib/pinouts/stm32n657l0h3q.sexp:9`

Gotchas:
- The first column comment `;; source: …` (when present) records which
  KiCad symbol was the input to `convert-pinout`.
- Editing this file by hand defeats the auto-regen flow.

## 11. Footprint file format

Footprint files live in `lib/footprints/<name>.sexp` and are produced
by `eda convert-footprint <file.kicad_mod>` (`src/convert/footprint.zig:16`).
The shape is more terse than KiCad's: positions are pre-rotated and
compressed.

```scheme
(footprint "ABM810000MHZ12D2W"
  (description "ABM8")
  (pad 1 smd rect (pos -1.15 0.93) (size 1.05 1.30))
  (pad 2 smd rect (pos 1.15 0.93) (size 1.05 1.30))
  (courtyard (rect -2.800 -2.450 2.800 2.887))
  (silkscreen
    (line (-1.25 1.85) (-1.25 1.85))
    (line (-0.20 -1.25) (0.20 -1.25))))
```

`projects/designs/lib/footprints/abm810000mhz12d2w.sexp:1`

Recognised forms:

- `(description "text")` — single line.
- `(pad <id> <type> <shape> (pos X Y) (size W H) (drill D)? )` —
  `<type>` is `smd`/`thru`/`npth`; `<shape>` is `rect`/`roundrect`/
  `oval`/`circle`/`custom`. Numbers are millimetres. `(drill D)` is a
  single value or `(drill oval DX DY)`.
- `(courtyard (rect x1 y1 x2 y2))` — single rectangle. Falls back to a
  bounding box of `fp_line` segments on `F.CrtYd` if absent
  (`src/convert/footprint.zig:196`).
- `(silkscreen (line (x1 y1) (x2 y2)) (circle (cx cy) r) …)` — group of
  primitives, all on the front silkscreen layer.

Gotchas:
- The `(pos x y)` coordinate is the pad centre. `(size w h)` is in mm,
  pre-rotated (90°/270° rotations swap W/H during conversion).
- Pad ids can be numeric or strings; pinout/footprint pad-id matching
  is exact string compare after numeric-to-decimal normalisation.

## 12. KiCad source files

`lib/sources/` holds the original KiCad inputs (`.kicad_sym`,
`.kicad_mod`, `.step`). They are *not* read directly by the evaluator —
the converters at `eda convert-symbol`, `eda convert-footprint`, and
`eda convert-pinout` translate them into the project's `.sexp` files
under `lib/symbols/`, `lib/footprints/`, and `lib/pinouts/`.

- `convert-footprint <file.kicad_mod>` — emits the `(footprint …)`
  shape above (`src/convert/footprint.zig`).
- `convert-symbol <file.kicad_sym> [--filter <name>]` — emits a symbol
  file (graphics + pin labels) (`src/convert/symbol.zig:15`).
- `convert-pinout <file.kicad_sym>` — emits the `(pinout …)` form
  (`src/convert/symbol.zig:58`).
- `convert-package <sym.kicad_sym> <fp.kicad_mod> [--name <name>]` —
  emits a packaged-component bundle (`src/convert/symbol.zig:111`).

Inputs must be valid KiCad 7+ S-expression files. The converter strips
library-prefix syntax (`Lib:Name` → `Name`), normalises pad rotations
into the simple pre-rotated form, and harmonises layer names. Anything
the converter doesn't recognise is dropped silently — round-tripping
KiCad → eda `.sexp` → KiCad is intentionally lossy.

## 13. BOM file format

Auto-generated sidecar at `<design>.bom` (`src/bom.zig:48`). Stores the
identity of every emitted instance — UUID, component name, properties,
and net list — keyed by the `<sub-block>/<refdes>` path.

```scheme
;; BOM — auto-generated by eda build
;; Stores identity and properties per instance

(part "ldo/U2" "47b0776f-1c40-4c45-b4d8-a5907e5a49f4" "lt3045edd"
  (id "c86a0ba8")
  (nets "SET" "PG" "ILIM" "PGFB" "GND" "GND" "6V" "6V" "6V" "VIN" "VIN" "EN" "VIOC")
  (manufacturer "Analog Devices")
  (mpn "LT3045EDD-1#TRPBF"))
```

`projects/designs/src/power/lt3045.bom:4`

`(part "PATH" "UUID" "COMPONENT" sub-fields…)`. Sub-fields:

- `(id "<hex8>")` — short stable ID linking to the `(id …)` in the
  source `.sexp`.
- `(nets "N1" "N2" …)` — pin order matches the component's pinout.
- `(<key> "value")` — any other propagated property (manufacturer, mpn,
  custom keys). `footprint` and `value` keys are skipped on load
  (`src/bom.zig:90`).

The BOM is regenerated on every `eda build`, but the UUIDs are stable
across rebuilds — `bom_resolve.zig` reconciles freshly-emitted instances
to existing UUIDs by `(path, id)` so the manufacturing identity sticks
even when ref-deses are reshuffled.

A parallel `.ids` sidecar (e.g. `lt3045.ids`) maps just `(identity
"PATH" "UUID" "COMPONENT" …)` for tools that don't need the full BOM
(`projects/designs/src/power/lt3045.ids:1`).

## 14. Layout file format

Sidecar at `<design>.layout`. Plain text S-expression, auto-generated by
the placer / router and consumed by `src/render_pcb_json.zig` and the
PCB editor's update endpoint. Forms:

```text
(place "C1" 23.41 12.96 0 front "7838f275-2eb7-4a06-bae9-4c6d3cabf81c")
(trace "ldo/VOUT" "F.Cu" 0.20
 70.10 94.02  68.79 94.02  68.76 94.05)
(via 61.40 45.90 "V1P8" 0.20 0.35 "F.Cu" "B.Cu")
(rules 0.13 0.13 0.20 0.35)
```

`projects/designs/src/rf/pma3-14ln.layout:4`,
`projects/designs/src/stm32n6/stm32n6.layout`

- `(place "REF" X Y ROT SIDE "UUID")` — instance placement.
  `SIDE` is `front`/`back`. Coordinates are in mm.
- `(trace "NET" "LAYER" WIDTH x1 y1 x2 y2 …)` — polyline trace; pairs
  of coordinates after the width are vertices. `LAYER` follows the
  KiCad short names (`F.Cu`, `B.Cu`, …).
- `(via X Y "NET" DRILL SIZE "TOP_LAYER" "BOTTOM_LAYER")` — single via.
- `(rules CLEARANCE TRACK VIA_SIZE VIA_DRILL)` — board-level rule
  override block (single line).
- `(zone …)` and other PCB primitives may be added by future placer
  passes; the renderer ignores unknown forms.

The layout file is only auto-edited via the PCB editor / API endpoints
(`/api/pcb-placement/:name`, `/api/pcb-routing/:name`). Hand edits are
preserved across rebuilds because the BOM UUIDs in `(place …)` survive
and component identity is reconciled on load.

## 15. Board-level form

`(board "name" sub-forms…)` evaluates to a `Board` (design + physical
parameters) and lives outside `design-block`
(`src/eval/board.zig:39`).

```scheme
(board "my-pcb"
  (design <design-expr>)              ;; required: design_block or path
  (outline (rect 0 0 60 40))
  (thickness 1.6)
  (copper-layers 4)
  (rules
    (clearance 0.15)
    (track-width 0.2)
    (via-drill 0.3)
    (via-size 0.6))
  (stackup
    (copper "F.Cu" 0.035)
    (prepreg 0.2 (er 4.2))
    (core 0.8 (er 4.5)))
  (net-class "Power" (track-width 0.4) (nets "VDD" "GND" "V1P8"))
  (diff-pair "USB"
    (positive "USB_DP") (negative "USB_DM")
    (impedance 90) (spacing 0.15))
  (zone "GND" "B.Cu" (thermal-gap 0.3) (thermal-width 0.25))
  (keepout "antenna" (rect 10 10 20 20) no-tracks no-vias))
```

(`src/eval/board.zig:24` — synopsis from doc comment.)

Sub-forms:

- `(design <expr>)` — required. Either a `(design-block …)` literal /
  module call or a path string evaluated against `project_dir`.
- `(outline (rect x1 y1 x2 y2))` or `(outline (point x y) …)` — board
  shape in mm. `(rect …)` expands to four corner points
  (`src/eval/board.zig:155`).
- `(thickness <mm>)` — defaults 1.6.
- `(copper-layers <n>)` — defaults 2.
- `(rules …)` — clearance / track-width / via-drill / via-size in mm.
- `(stackup …)` — sequence of `(copper "Layer" thickness)`,
  `(prepreg thickness (er X)?)`, `(core thickness (er X)?)`.
- `(net-class "name" sub-forms… (nets "X" "Y" …))` — per-class
  overrides plus the net membership list (`src/eval/board.zig:273`).
- `(diff-pair "name" (positive "N+") (negative "N-") (impedance Z) (spacing S))`.
- `(zone "name" "layer" (thermal-gap …) (thermal-width …))` — design
  intent for copper pour; the actual fill is computed by
  `src/zone_fill.zig`.
- `(keepout "name" (rect …)? no-tracks? no-vias? no-pours?)` — the
  three exclusion flags can sit either as bare atoms or as zero-arg
  forms.

## 16. Conventions + invariants

- **Ref-des prefix categorisation.** `componentPrefix` at
  `src/eval/ids.zig:211` decides the prefix letter used by auto-numbering
  and rendering. Selected mappings:
  - `cap*` → `C`, `res*` → `R`, `ind` → `L`, `xfl*` → `L`,
    `ferrite*` → `L`.
  - `led`, `led-*`, `diode*` → `D`.
  - `connector*`, `amphenol*`, `lsh-*`, `usb4*` → `J`.
  - `ecmf*` → `U`.
  - `abm8`, `fc-*` → `Y` (crystals).
  - `ao3*`, `ao4*`, `bss*`, `dmn*`, `dmp*`, `2n*`, `irlml*` → `Q`
    (transistors).
  - Anything else with a non-empty family → `U` (IC).
- **Hub vs spoke** classification (used by the schematic renderer): hub
  prefixes are `U` / `J` / `P` / `X` / `Q`; spokes are `R` / `C` / `L`
  / `F` / `D` / `Y`. Hubs render as boxes, spokes render inline along
  connections.
- **ID stability.** Every `instance`, `series`, and `decouple` form
  carries an `(id <hex8>)` marker after the first build. The freezer
  rewrites the source file in place so a freshly cloned repo + first
  build has a non-empty diff. Module-internal IDs are derived
  deterministically from the sub-block name + ref-des
  (`src/eval/ids.zig:295`), so a sub-block instantiated twice produces
  two non-colliding ID sets.
- **Auto-aliasing.** When a pinout file defines a function name, that
  name becomes a synthetic net-tie target; writing
  `(pin C1 "USB_DP")` against an STM32 with function-name `USB2_OTG_HS_DP`
  on C1 tells the validator the two are the same net even if the design
  also exposes a port called `USB2_OTG_HS_DP`. Auto-ties never bridge
  two distinct user-declared nets — that's the
  `is_auto && a_pins != null && b_pins != null` short-circuit at
  `src/eval/design_block.zig:608`.
- **`(rated …)` envelope.** Both bounds are required; the long form of
  `(port …)` with identical name and net emits a warning — prefer the
  short form.
- **Multi-pin shorthand** `(pin 1 2 3 4 5 "VDD")` only works when every
  listed pin shares the same net. If different pins need different
  nets, write one `(pin …)` per net.
- **`per-pin` keyword.** `(decouple …)` requires the literal
  `per-pin` token; missing it raises `InvalidForm`.
- **Search path.** `(import x)` searches `lib/components/` first, then
  `lib/modules/`, under both `project_dir` and `lib_dir`. The first
  match wins (`src/eval/modules.zig:43`).
- **String quoting in `(verifies …)`.** Bare hex IDs that look numeric
  (`41510609`) must be quoted as a string in source. Atom-style hex
  (`b68c3fa5`) is fine because the leading letter is non-numeric.
- **AST source buffers are never freed.** Every string slice in an
  evaluated `Value` references either source bytes or an arena-style
  allocation kept alive for the rest of the evaluation; do not assume
  the slice is independently allocated.
