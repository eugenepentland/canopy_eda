# The netlisp design language

A netlisp design is a text file. There is no schematic editor and no binary
database: `src/<name>.sexp` *is* the circuit, and every other surface — the
served schematic page, the netlist, the PCB layout, the KiCad project, the
review PDF — is derived from it.

This is the hand-written reference. It assumes you know electronics and have
never seen this tool. Two companions:

- **[`language-forms.md`](language-forms.md)** — the exhaustive, *generated*
  table of every form, with arities and allowed scopes. It is rendered from the
  evaluator's own dispatch tables by `zig build docs`, and a test fails when it
  is stale, so it cannot drift from what the parser accepts. When you want to
  know *whether* a form exists and what it takes, look there. This file explains
  what the forms mean and how they are used together.
- **[`standard-library.md`](standard-library.md)** — the parts compiled into the
  binary, and how a project shadows them.

If you would rather read a working board first,
[`examples/README.md`](../examples/README.md) walks through
`examples/blinky-breakout` line by line.

---

## Contents

1. [Files, projects and commands](#1-files-projects-and-commands)
2. [Atoms, numbers, strings, comments](#2-atoms-numbers-strings-comments)
3. [The design-block skeleton](#3-the-design-block-skeleton)
4. [Components, families and `import`](#4-components-families-and-import)
5. [Instances, pins, nets and ports](#5-instances-pins-nets-and-ports)
6. [Sections and the block diagram](#6-sections-and-the-block-diagram)
7. [Modules, sub-blocks and hierarchy](#7-modules-sub-blocks-and-hierarchy)
8. [`let`, `if`, structural control flow, variants](#8-let-if-structural-control-flow-variants)
9. [`connect`, `chain` and interface bundles](#9-connect-chain-and-interface-bundles)
10. [Typed attributes, design-owned rules, system contracts](#10-typed-attributes-design-owned-rules-system-contracts)
11. [Arithmetic and `fmt`](#11-arithmetic-and-fmt)
12. [Assertions and checks](#12-assertions-and-checks)
13. [Sidecars and identity](#13-sidecars-and-identity)
14. [Exports](#14-exports)
15. [Board and layout forms](#15-board-and-layout-forms)
16. [Common mistakes](#16-common-mistakes)

---

## 1. Files, projects and commands

### Project layout

Every command takes `--project-dir <d>` (default `.`). A project is a directory
with a `src/` and, usually, a `lib/`:

```text
my-project/
  src/
    board.sexp              the design — one (design-block …)
    board.checks.sexp       optional sidecars, autoloaded by basename
    board.layout.sexp
    board.diagram.sexp
    board.bom               written by the build (identity ledger)
    board.layouts.json      written by the PCB tools (placement + copper)
  lib/
    components/<name>.sexp  parts
    footprints/<name>.sexp  land patterns
    pinouts/<name>.sexp     pad number → function name
    symbols/<name>.sexp     schematic symbols
    modules/<name>.sexp     reusable parameterised circuits
    interfaces/<name>.sexp  named-lane bus vocabularies
    parts/<name>.sexp       purchasable rows (MPN, rating, tolerance)
    datasheets/<name>.pdf   the PDFs requirements cite
```

The design *name* is the source file stem — `netlisp designs` prints exactly
the tokens the other commands accept.

Two more directories appear beside those while the tool **runs**, and neither is
part of the design: `logs/` (the interaction log `serve` writes) and `history/`
(the snapshots the layout and edit tools take before every mutation).

### Where runtime output goes

`--state-dir <d>`, accepted by **every** command, puts `logs/` and `history/` under
`<d>` instead of beside the project; `NETLISP_STATE_DIR=<d>` does the same and the
flag wins. Nothing else moves — design sources, their sidecars (`.bom`,
`.layouts.json`, …), the library and every export stay exactly where they were, so a
relocated run reads and writes the same design. It is what lets a *tracked* project
be served and laid out with a clean `git status`.

```bash
netlisp serve --project-dir examples/blinky-breakout --state-dir /var/tmp/nl-state
```

Like `--lib-dir` below, this is consumed before the command sees its arguments, so
its value can never be mistaken for a positional design name.

### Where a library name resolves

Every `lib/<sub>/<name>.sexp` lookup — components, footprints, pinouts, modules,
interfaces and parts tables alike — walks the same four places and takes the
first hit, **per file name**:

| # | Where | How it is set |
| --- | --- | --- |
| 1 | `<project-dir>/lib/<sub>/<name>.sexp` | `--project-dir` |
| 2 | `<lib-dir>/lib/<sub>/<name>.sexp` | `--lib-dir <d>` / `NETLISP_LIB_DIR` |
| 3 | `<stdlib-dir>/<sub>/<name>.sexp` | `NETLISP_STDLIB_DIR=<d>` |
| 4 | the library compiled into the binary | always present |

Shadowing is per name, not wholesale: your own `lib/footprints/testpoint-1mm.sexp`
replaces that one land pattern and leaves the bundled `testpoint` *component*
alone. See [`standard-library.md`](standard-library.md).

### The commands you will use

```bash
netlisp build  --project-dir <d> <name>    # evaluate; print the resolved design
netlisp check  --project-dir <d> <name>    # ERC + requirements + assertions
netlisp serve  --project-dir <d>           # the schematic / PCB / review pages
netlisp instances    --project-dir <d> <name>   # parts as JSON
netlisp netlist-dump --project-dir <d> <name>   # the FLATTENED netlist
netlisp reference [section]                # the generated grammar, from the binary
```

`netlisp build` prints the design *before* hierarchy is flattened, so a
sub-block's nets still carry their `sub/NET` names. `netlisp netlist-dump` prints
the flattened truth — one sorted line per net with its `REF.PAD` members — and is
the right thing to diff when you want to prove an edit changed nothing.

**The build writes back into `src/`.** Two things, both intentional:

- an 8-character `(id …)` marker on every form that needs a stable identity and
  does not have one, spliced in at its source byte offset;
- `<name>.bom`, recording each part's resolved identity, value, nets and a
  fingerprint of the library entry it came from.

See [§13](#13-sidecars-and-identity).

---

## 2. Atoms, numbers, strings, comments

Everything is a parenthesised list. The first element is the form head; the rest
are its arguments.

```lisp
(instance "C1" (cap-0402 "100nF")
  (pin 1 "VDD")
  (pin 2 "GND"))
```

### Atoms

Barewords such as `res-0402`, `stm32n657l0h3q`, `VCC`, `~{CS}`. An atom **starts**
with a letter, `_`, `~` or `*`, and **continues** with letters, digits and
`- / . * # @ : + , $`. The operators (`+ - * / % > >= < <= == != and or not`) are
atoms too.

There is no quoting, no unquoting, and no macro system.

### Numbers, and the SI suffixes

`42` is an integer, `3.3` a float (the decimal point is required — `3.` and `.3`
are not floats). A number may carry an **SI scale suffix**, optionally followed by
**one scale-free unit letter**:

| Suffix | Scale | Notes |
| --- | --- | --- |
| `k` | 10³ | |
| `M` | 10⁶ | |
| `G` | 10⁹ | |
| `m` | 10⁻³ | **only with a unit letter** — `100mV` is 0.1, bare `3m` is not a number |
| `u` | 10⁻⁶ | |
| `n` | 10⁻⁹ | |
| `p` | 10⁻¹² | |

The unit letters are `V A F H R`. They carry **no scale** — they are there so the
source reads like a schematic: `100nF` == `100n` == 1e-7, `3.3V` == `3.3`,
`270R` == `270`. A trailing `%` closes a literal the same way and also carries no
scale: `10%` is the number **10** that remembers its spelling, not 0.1. Tolerances
are authored, compared and printed in percent everywhere in this language.

Two dimension tokens are separate: `mm` keeps the value in millimetres, and `mil`
converts to mm (1 mil = 0.0254 mm).

Three rules decide whether a token is a number at all:

- **The suffix must END the token.** `100kHz` is not 100000 — `H` is a unit letter
  but `z` follows it, so the whole token falls through to a plain atom. So does
  `204928-0301.stp`.
- **There is no exponent notation.** `1e-7` is an *atom*, and using it where a
  number belongs fails with `unknown name '1e-7'`. Write `100n` or `0.0000001`.
- **There are no boolean literals.** `true` and `false` are unbound names.
  Booleans come only from `(> …)`, `(== …)`, `(and …)` and friends.

**A suffixed literal keeps its spelling.** The value is a plain `f64` in
arithmetic — `(let x 100nF)` then `(* x 2)` is 2e-7 — but the source text travels
with it, so anywhere a number is written out as a *part value* it renders by its
unit:

```lisp
(pullup "SDA" 4.7k "V_3V3")      ; a 4.7k resistor, not a "4700" one
(cap-0402 100nF)                 ; identical to (cap-0402 "100nF")
```

### Strings

Double-quoted. A string **may span source lines** — the lexer scans to the closing
quote — which is how a long `(note …)` or a `(net-envelope …)` rationale is
written. A backslash escapes the next byte for lexing purposes only; there is no
escape *interpretation*, so `\"` and `\\` reach the value with their backslash
intact and round-trip through the printer unchanged.

```lisp
(note "U1" "LT3045 SET sources 98/100/102 uA into R_SET, so the node
            sits within 3 % of the programmed output")
```

### Comments

`;` starts a line comment and runs to the end of the line. `;;` is the same thing —
a house-style convention, not a different token. There are no block comments.

### Evaluation

- **Special forms** (`let`, `if`, `when`, `unless`, `for`, `repeat`, `fmt`,
  `assert`, `assert-range`, `import`, `defmodule`, `block`, `design-block`,
  `interface`, `implements`) receive their arguments un-evaluated and decide what
  to evaluate. Everything else evaluates eagerly, left to right.
- **Lexical scoping.** `(let …)` binds in the current scope and shadows any outer
  binding. A module closes over the environment it was *defined* in.
- **`(if …)` in expression position keeps ordinary Lisp truthiness. In design
  scope it does not** — see [§8](#8-let-if-structural-control-flow-variants).
- **There is no `cond`.** It was removed; a multi-way choice is nested `(if …)`
  or a `(when …)`/`(unless …)` pair.
- Every node carries a source span, so an error or a warning reads
  `file:line:col: …`. The `file` is the file the form actually lives in — a
  warning raised while an imported `lib/modules/*.sexp` body evaluates names *that*
  file and its own line, and the module call stack says which call reached it:

  ```text
  lib/modules/probe-ldo.sexp:7:20: error: 'ldo-3v3-sot23-5' is in the library — add (import ldo-3v3-sot23-5)
    in module 'probe-ldo' (called at 3:23)
  ```

---

## 3. The design-block skeleton

A design file evaluates to exactly one design block. Three spellings exist and all
three are permanent; they differ only in the shape of the name:

```lisp
(design-block "Blinky Breakout" …)   ; the original spelling
(block        "Blinky Breakout" …)   ; identical — a QUOTED name is a design root
(block tpsm84338 (rfbt rfbb) …)      ; a BARE atom + a parameter list is a MODULE
```

`(defmodule name (params…) …)` is the permanent alias for the third. Prefer
`(block …)` in new work — a module with no parameters and a design differ only in
whether anything instantiates them — and keep whichever spelling a file already
uses consistently.

Here is a complete design that builds, checks and exports:

```lisp
(import pin-header-1x2 mounting-hole-m2)

(design-block "Sidecar Probe"
  (board-role board)
  (revision "A" (date "2026-09-05") (change "A" "first spin"))

  (section "Inlet" "2-pin header and its bulk cap"
    (row 0) (col 0)
    (description "Where the board is powered.")
    (instance "J1" pin-header-1x2 (pin 1 "V_5V") (pin 2 "GND"))
    (instance "C1" (cap-0805 "10uF") (pin 1 "V_5V") (pin 2 "GND")))

  (instance "H1" mounting-hole-m2 (pin 1 "GND"))
  (instance "H2" mounting-hole-m2 (pin 1 "GND"))
  (instance "H3" mounting-hole-m2 (pin 1 "GND"))
  (instance "H4" mounting-hole-m2 (pin 1 "GND")))
```

Everything a design says lives **inside** the block. A design-scope form written
after the closing paren is evaluated as an ordinary expression and fails
(`error: unknown name 'stackup'`) — except `(import …)` and `(interface …)`,
which are file-level.

`(board-role board|subcircuit)` is explicit and defaults to `subcircuit`, so a
fabricable board must say so. `(revision "ID" …)` is the human spin id shown on
the schematic header and the review doc.

---

## 4. Components, families and `import`

### `(import name…)`

```lisp
(import ldo-3v3-sot23-5 hex-inverter-schmitt pin-header-1x2 testpoint)
```

Each name is looked up as `lib/components/<name>.sexp`, then
`lib/modules/<name>.sexp`, through the four-level order in
[§1](#1-files-projects-and-commands). Re-importing a loaded name is a no-op.

Using a library name you did not import is an error that tells you so:

```text
error: 'hex-inverter-schmitt' is in the library — add (import hex-inverter-schmitt)
```

**The sixteen passive families need no import.** `cap-`, `res-` and `ind-` in
`0201/0402/0603/0805`, plus `ind-1616`, `ind-2016`, `ferrite-0402` and `led-0402`,
are loaded into every design and every module automatically.

### Fixed parts and families

A **component** is a fixed part — `(instance "U1" ldo-3v3-sot23-5 …)`. A
**component-family** is parameterised by one value the call site supplies —
`(cap-0402 "100nF")`, `(res-0402 "10k")`, `(ferrite-0402 "600R")`. The call is an
ordinary value, which is why a module can take *a part* as a parameter
([§7](#7-modules-sub-blocks-and-hierarchy)).

**The value is checked against the family's declared kind.** A family declares
`(parameter "value" capacitance | resistance | inductance | impedance | string)`,
and a value that positively parses as another quantity is refused:

```text
error: (cap-0402 "4.7k") — "4.7k" is not a capacitance value;
       cap-0402 declares (parameter "value" capacitance)
```

The rule is one-sided. A bare number (`10`), a sentinel (`DNP`), a part number, a
trailing rating (`"10uF 25V"`), a bead's `"600R@100MHz"` and a letter used as a
decimal point (`24R9`) are all accepted in silence. A family declaring `string`
(or no kind) is never checked.

### Library file fields

You write library files, not designs, with `(component …)` / `(component-family …)`.
Their bodies declare `(symbol …)`, `(footprint …)`, `(pinout …)`,
`(description …)`, `(refdes "U")`, `(datasheet "part.pdf")`,
`(datasheet-review …)`, `(class ldo)`, `(electrical "PIN" …)`, `(thermal …)`,
`(bus "name" PIN…)` and `(requirement "text" (check …))`. Any other
`(key "value")` child is an inline **property** carried onto every placed
instance. The full field table, the executable `(check …)` primitives and the
datasheet-review record are in
[`language-forms.md`](language-forms.md) under *Component library fields*,
*Requirement checks* and *Datasheet review preflight*.

Three of those fields carry weight beyond the part itself:

```lisp
(component lm66100
  (class load-switch)                    ; binds a component-class review profile
  (footprint sc70-6)
  (datasheet "LM66100DCKR.pdf")          ; the ONLY linkage between part and PDF
  (datasheet-review
    (datasheet "LM66100DCKR.pdf")
    (sha256 "<64 lowercase hex characters>")
    (status complete) (reviewed-by "…") (date "YYYY-MM-DD")
    (category supply)
    (category-na sequencing "no sequencing requirement on this part"))
  (requirement "At least 1 uF of ceramic capacitance sits across VIN and GND."
    (ref "LM66100DCKR.pdf" (page 7) (quote "…"))
    (check (decoupling (pin "VIN") (pin "GND") (min-uf 1.0)))))
```

`(datasheet "…")` is a filename in `lib/datasheets/` or an absolute `http(s)` URL,
and it is what fills each placed instance's `docs.datasheets` and what the coverage
check demands of every active IC — a PDF sitting in `lib/datasheets/` that no
component declares documents nothing. `(datasheet-review …)` binds the review to
exact bytes, so replacing the file makes the review stale. `(class <key>)` selects
the review profile the release checks apply; without it the class is inferred from
the pin function names. The chain has CLI tools so nothing is hand-edited:
`fetch_datasheet` (URL → disk), `attach_datasheet` (PDF → this declaration),
`read_datasheet` (text plus the `sha256` to cite).

---

## 5. Instances, pins, nets and ports

### `(instance "REF" component sub-form…)`

```lisp
(instance "C1" (cap-0402 "100nF")
  (pin 1 "VDD")
  (pin 2 "GND"))
```

A bare string child is positional shorthand for the next physical pad, so
`(instance "R1" (res-0402 "10k") "VIN" "TAP")` wires pads 1 and 2.

**Ref-des.** A token that looks standard — uppercase letters followed by digits,
`U1`, `C23`, `SW2` — is kept verbatim and reserves that number. Anything else
(`R_SET`, `C_BULK`, `lpf4`, or `""`) is **auto-assigned** from the part's class
prefix, and every reference to it in nets, notes and pin groups is rewritten. So

```lisp
(instance "R_SET"  (res-0402 "10k") …)     ; emitted as R8
(instance "R7"     (res-0402 "10k") …)     ; emitted as R7
(instance ""       (res-0402 "10k") …)     ; emitted as R9
(instance "C_BULK" (cap-0805 "10uF") …)    ; emitted as C1
```

The **authored** token is still the part's stable origin key — it is what `(id …)`
derivation, `"sub/REF"` rule targets and the `.bom` sidecar key off — so a
descriptive name costs nothing except that you will not see it in the netlist.
Two instances authored with the same ref-des in one block is a hard error naming
both places; each `(sub-block …)` and each module body is its own namespace.

### Pins

```lisp
(pin 1 "VDD")                       ; a physical pad id
(pin VIN "VIN_5V")                  ; a pinout FUNCTION name (bare atom)
(pin "1A" "RC_NODE")                ; a function name that must be QUOTED
(pin 1 2 3 4 5 "VDD")               ; several pads onto one net
(pin 4 "VOUT" (i-typ 0.5) (i-max 1.5) (load "sensor rail"))
(pin H4 (as "PC13" "PWR_WKUP3") "PWR_BTN")
```

Every `PIN` token — in `(pin …)`, `(strap-ok …)`, `(nc-ok …)`, `(near …)`,
`(decouples …)` — is **either a physical pad id or a pinout function name**,
resolved through the part's `lib/pinouts/<name>.sexp`. The function name is the
better spelling: it says what the pin *is*, and a pinout regeneration that
renumbers pads carries it along.

> **The quoting rule.** A bare token is resolved by the *lexer* first. If it
> parses as a number — a digit run followed by a scale letter, a unit letter
> (`V A F H R`) or `%` — it becomes that number, and the only reading left for it
> is a **pad id**. That collision is no longer resolved in silence. A `(pin …)`
> token that reached the parser as an SI-suffixed numeric literal is checked
> against the part's own library records before it is bound:
>
> - the part's pinout has a **function** literally named after the token's source
>   text, or its footprint has a **pad** so named — the two readings genuinely
>   disagree, and the build **stops** at `file:line:col` naming both of them and
>   the quoting that picks one;
> - **nothing** on the part answers to that text — the numeric reading is the only
>   one available, so it stands, with a warning that names both readings.
>
> So on a hex inverter whose pinout maps pad 1 to function `1A` and pad 5 to `3A`:
>
> ```lisp
> (pin 3A  "X")     ; ERROR: the NUMBER 3 with unit A → pad 3, but "3A" is pad 5's function
> (pin "3A" "X")    ; the function name 3A → pad 5. Right.
> (pin 3   "X")     ; the pad. Also right, and unambiguous.
> (pin 1Y  "X")     ; Y is not a unit letter → an atom → function 1Y → pad 2. Fine.
> ```
>
> ```text
> src/p-pin3a.sexp:6:10: error: (pin 3A …) on "U2" — `3A` is ambiguous: unquoted it is
> a NUMBER (the SI unit/scale letter closes the literal) and binds pad 3, but this part
> also has a pin function named "3A" (pad 5). Write (pin "3A" …) for the pin name, or
> (pin 3 …) for the pad.
> ```
>
> A token that names nothing on the part — `2V` on that same inverter — binds the
> numeric pad and says so, which is the case the warning exists for: `3n` is far
> likelier to be a mis-quoted pin name than a deliberate 3e-9.
>
> ```text
> src/p-pin2v.sexp:6:10: warning: (pin 2V …) on "U2" — `2V` is a NUMBER here (the SI
> unit/scale letter closes the literal), so it binds pad 2. Quote a pin name that
> starts with a digit: (pin "2V" …)
> ```
>
> (If the numeric reading is not a pad the part has, the ordinary pad-set error
> below follows the warning — `3n` is 3e-9, which resolves to pad `0`.)
>
> **Quote any function name that starts with a digit.** Bare atoms like `VCC`,
> `GND`, `VIN`, `PA3` and `1Y` are unambiguous and need no quotes, and so is a bare
> `(pin 1 …)`: a plain integer is not an SI-suffixed literal either, so neither
> spelling is ever checked or warned about. If you are not sure, quoting is always
> safe — a quoted token is resolved as a function name first and as a pad id second.
>
> The check runs on both `(pin …)` spellings — an instance body and
> `(pins "REF" … (pin …))` — and nowhere else: a `(strap-ok 3A …)`, `(nc-ok 3A …)`
> or `(near …)` pad still takes the numeric reading silently.

A pad the part does not have is an error, not a downstream floating-net warning:

```text
error: (pin 99 …) on instance "C9" — this part has no pad 99 (2 pads)
```

The pad set comes from the part's pinout file and its footprint's `(pad …)` ids. A
part with **neither** has an unknown pad set and every token on it passes, which is
most passives' normal state; an IC wired on three or more pads with no pinout file
draws a warning naming the file to add.

`(as "FN"…)` asserts which pinout function a pad is being used for — the spelling
guard that warns when the library pinout disagrees, and the way a pin with several
alternate functions declares which one this board uses.

### Multi-part symbols, and `(pins …)`

One IC can be drawn in several places. `(part …)` splits an instance's own body:

```lisp
(instance "U2" hex-inverter-schmitt
  (part "Supply" (row 0) (col 0)
    (pin VCC "V_3V3") (pin GND "GND"))
  (part "Gates" (row 1) (col 0)
    (pin "1A" "IN") (pin "1Y" "OUT")))
```

`(pins "REF" …)` wires an **already-placed** part from somewhere else in the file —
usually from the section the pins belong to:

```lisp
(section "Expansion" "the spare gates"
  (pins "U2" (group "spare gates")
    (pin "3A" "E3A") (pin "3Y" "E3Y")
    (bus "EXP" "4A" "4Y" "5A")))        ; → EXP0 on 4A, EXP1 on 4Y, EXP2 on 5A
```

The netlist has one part; the schematic draws it once per section, each box
carrying only that section's pins.

### Nets

**A net is created by naming it.** There is no wire object: two pins carrying the
string `"VIN_5V"` are connected, and that is the whole model.

```lisp
(net "VBUS" "USB_5V")          ; tie two names together (net merge)
```

Two net-name shapes are generated rather than authored, and you will see them in
`netlist-dump`:

- `NET.REF.PAD` — a per-pin bypass stub minted by `(decouple … (per-pin …))`, e.g.
  `V_3V3.U2.14`.
- `n~end~end` — an anonymous `(connect …)` / `(chain …)` node
  ([§9](#9-connect-chain-and-interface-bundles)).

A net with exactly one connection and no declared port is reported as a
`floating_net`, with a did-you-mean when it is within two edits of an established
name (`Floating net "GNND" … did you mean "GND"?`).

### Instance sub-forms worth knowing

| Form | What it says |
| --- | --- |
| `(note "text")` | Prose on this part. The argument **is** evaluated, so it may be `(fmt …)`. |
| `(dnp)` | Do Not Populate — footprint and pads stay on the board, the part leaves the assembly BOM. Unconditional. |
| `(decouples "IC" PIN)` / `(decouples rail)` | Which supply pad this bypass cap serves, or that it deliberately serves the whole rail. |
| `(near "REF" PIN [(own PAD)])` | Pure adjacency: keep my leg against that pad. Never a decoupling loop. |
| `(strap-ok PIN "reason")` | Sign off a config strap tied straight to a rail. |
| `(nc-ok PIN "reason")` | Sign off a deliberately unconnected pad. |
| `(power W)` / `(power (typ W) (max W))` | What this part dissipates, for the thermal screen. |
| `(only-in …)` / `(dnp-in …)` / `(value-in …)` | Assembly variants — [§8](#8-let-if-structural-control-flow-variants). |
| `(mpn "…")`, `(class ldo)`, `(emi-couples "CHASSIS")` | Any other `(key "value")` child is an inline **property**. |

`(decouples …)` and `(near …)` both resolve `PIN` through the **target's** pinout,
in a post-build pass once every instance exists — so declaration order does not
matter and a passive, which has no pinout of its own, can still name a function.
Declaring which pad a bypass cap serves is a hard requirement (the
`decoupling_unbound` ERC **error**) whenever an HF cap sits on a rail that lands on
two or more of a hub's supply pads; bulk reservoirs ≥ 4.7 µF, single-supply-pad
rails and `(decouples rail)` opt-outs are exempt.

A typo'd sub-form is an error rather than a silent property:

```text
error: unknown sub-form (decuples …) in (instance "C9" …) — did you mean (decouples …)?
```

Property keys that are not near-misses (`(module-bypass "…")`, `(emi-couples "…")`)
keep working. `(emi-couples "DOMAIN")` is one such property with an ERC meaning of
its own: it marks a capacitor that deliberately provides an AC path from a named
non-supply domain (chassis, an isolated return) to a ground return, and ERC rejects
it on a non-capacitor, on a misnamed domain, with no ground leg, or combined with
`(decouples …)`.

### Sign-offs: `(strap-ok …)` and `(nc-ok …)`

Two ERC rules exist to catch a wire you meant to draw and did not, and both are
closed by a sign-off with a **mandatory reason** rather than by a suppression flag.

A configuration strap (`EN`, `CE`, `MODE`, `ILIM`, `SHDN`, `BOOT`, an I²C address
bit, `OE`, …) tied **directly** to a power or ground rail is easy to wire backwards
and impossible to rework once fabbed. The idiomatic default is a pull resistor,
which lands the strap on its own private net and is silently fine; only a strap pad
sitting on the rail itself is flagged, as the `strap_tied_to_rail` **error**. When
the direct tie is correct, bless it:

```lisp
(instance "U1" lt3045edd#pbf
  (pin ILIM "GND")
  (strap-ok ILIM "ILIM->GND selects the default (max) current limit per datasheet"))
```

An unconnected pad is tiered by confidence rather than flagged wholesale: an
**error** when the library's `(electrical "FN" (type input))` marks it a driven
input, a **warning** when its function name is a config/enable/reset strap, and
**silent** for supplies (owned by the power-presence check), unused outputs,
GPIO, passive pins, translator channels and datasheet no-connect names — which is
what keeps the check quiet on a 100-pin MCU. Sign one off the same way:

```lisp
(instance "U1" w5500
  (nc-ok 37 "3V3_EN — the 3V3 LDO is always enabled internally, no external strap"))
```

Both take a `PIN` resolved exactly like a `(pin …)` token, and an empty or missing
reason does **not** suppress the finding. The module-level twin is
`(port … optional)`. One thing they do *not* inherit is the SI-suffixed-token check
described under [Pins](#pins) above: a `(nc-ok 3A …)` still takes the numeric reading
without a word, so quote a sign-off pin name that starts with a digit.

### Rewriting pads to function names

`netlisp tool rewrite-pins-by-name` converts a whole module or board from pad
numbers to pinout function names in place:

```bash
netlisp tool rewrite-pins-by-name --project-dir <d> --args '{"file": "lib/modules/x.sexp"}'
netlisp tool rewrite-pins-by-name --project-dir <d> --args '{"file": "src/board.sexp", "write": true}'
```

Text is spliced at the parser's byte spans, so every comment and column of
alignment outside the replaced token survives. A pad is rewritten **only** when the
evaluator's own resolver, re-run on the proposed spelling, returns the very pad the
original bound to — which is why a name the tokenizer would re-read as a number is
quoted or skipped. The default is `write:false` (diff and skip list only), and even
with `write:true` the change is refused unless the original and rewritten sources
produce identical netlists and identical resolved
`(decouples …)`/`(near …)`/`(strap-ok …)`/`(nc-ok …)` bindings.

### Ports

A port is a signal crossing the block boundary. It is what makes a module
composable and what the rail, level and rating checks read.

```lisp
(port "VIN"  in  power 5.0 (rated 4.5 5.5) (current 0.02 0.15))
(port "GND"      bidi power)
(port "VOUT" out power (nominal vout) (rated (* vout 0.97) (* vout 1.03)))
(port "EN"   in  optional)
(port "3V3"  "+3V3" out power)         ; long form: the NET differs from the NAME
```

Positional arguments come first: the name, optionally the net it maps to, then the
direction (`in` / `out` / `io` / `bidi`). Everything after that is an option in any
order. Two options are bare words and stay that way: `optional`, and a signal-type
keyword (`power`, `clock`, `rf`, `data`, `differential`, `signal`). Everything else
is a sub-form — `(rated LO HI)`, `(nominal V)`, `(current TYP [MAX])`,
`(efficiency …)`, `(enable "NET")`, `(electrical …)`, `(side …)`, `(role …)`,
`(protocol …)`, `(class …)`. The arguments of `(nominal …)` and `(rated …)` are
**evaluated**, so a regulator module can publish an output computed from its own
parameters.

Two older spellings still work and each records a `deprecated_form` info naming
its replacement: a bare keyword pair (`role R`, `protocol P`, `class C` — write
`(role R)`), and a bare trailing number for the nominal voltage (write
`(nominal V)`).

`(port … optional)` is the module-level twin of `(nc-ok …)`: a required port that
nothing connects is an ERC error, an optional one is silently fine.

Two shorthands expand into ordinary ports:

```lisp
(bus-port "IO" 0 3 io)                      ; → IO0 IO1 IO2 IO3
(bus-port "ADF_CH" 1 10 (suffixes P N) in differential)   ; → ADF_CH1P … ADF_CH10N
(diff-port "AIN" in)                        ; → AIN_P / AIN_N, kind differential
(diff-port "RFIN1" in rf (suffixes "+" "-"))              ; → RFIN1+ / RFIN1-
(diff-port "RFIN1" "LNA_IN" in)             ; long form: nets LNA_IN_P / LNA_IN_N
```

Unlike two hand-written ports, `(diff-port …)` **records the pairing**, and ERC
holds the pair to a both-or-neither contract (`diff_pair_half_connected`).

---

### Decoupling hosts, pins and the default IC; rated windows as expressions

**Host vs. pin, with a default IC set.** The token right after `per-pin` is
genuinely ambiguous once `(decouple-defaults (ic "REF"))` is in force: BGA pads
are spelled exactly like ref-des (`J14`, `H1`, `C3` are all real pads on parts
in this library). It is resolved in a fixed order that never depends on
declaration order:

1. the default IC's own ref — the host, spelled out redundantly;
2. a pad id or pin function of that IC — a **pin**, so a pad keeps its meaning
   when an unrelated `J14` connector is added to the block later;
3. a part declared in this block — the **host**, and the tokens after it are its
   pins;
4. neither, and that IC has a pinout to check against — an error naming the
   token and its line, rather than a guess.

Rule 3 is why `(decouple "V_3V3" (cap-0402 "100nF") 1 per-pin R1 1)` places one
cap on R1 pin 1. It used to read `R1` as a *pad of the default IC*, so a single
form emitted two differently-keyed children and the build pinned an
`(ids ("100nF@R1#0" …) ("100nF@1#0" …))` sidecar the next build refused to read.

form. Spell the host and the part at each site instead.
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

`(id …)` and `(ids …)` are **inert wherever they appear** — the evaluator
short-circuits both to nil, so a form that walks its own children (`decouple`,
`series`, `fanout`, `pullup`/`pulldown`, `divider`, `led`, `sub-block`, and
every structural control form) reads back the anchor the previous build
appended to it instead of trying to evaluate it. That is the invariant that
makes id write-back safe: what the tool writes, the tool reads.

delete the JSON afterwards: every surface that reads a manifest resolves the
contract the same way, so a sexp-only workspace gets its home-page card, its
`/api/systems` entry, its editor, its readiness, draft, dossier and release —
and it can be approved through the browser. `POST /api/systems/:name/attest`
writes the approval back as an `(attestation …)` form spliced in at its byte
span, replacing the one already there or appending a new one; every other byte
of the contract, comments and blank lines included, is left exactly as
authored. Invalidating an approval (any document save or asset upload) removes
that form again, restoring the source it was spliced into.

## 6. Sections and the block diagram

A `(section …)` is a functional subsystem: it groups parts on the schematic grid,
becomes a node in the block diagram, and is the unit the review report walks.

```lisp
(section "3V3 LDO Regulator" "Generic SOT-23-5 LDO, 5 V in, 3.3 V out"
  (row 0) (col 1)
  (category power)
  (description "Makes the 3.3 V rail the logic runs from.")
  (instance "U1" ldo-3v3-sot23-5 …)
  (instance "C1" (cap-0603 "1uF") …))
```

### Name and subtitle

The **name** is evaluated, so it may be computed. The **subtitle is not**: it is
the second positional argument and must be a literal string. A `(fmt …)` there is
not read as a subtitle at all — it falls through into the body and draws

```text
warning: unknown sub-form (fmt …) in (section …)
```

Compute the string into a `let` and it still will not work, because the slot takes
an AST string literal, not a value. If a section title must carry a number, put it
in `(description …)` or a `(note …)`, both of which *are* evaluated.

Keep the name 1–4 words and functional; keep the subtitle a one-line technical
caption with concrete numbers (`"12V-to-3.3V, 2A"`, not `"buck regulator"`).

### Status is inferred, never declared

**There is no `(status …)` form.** Writing one draws
`warning: unknown sub-form (status …) in (section …)` and changes nothing.

A section's maturity is derived from what it contains:

- **`concept`** — the section has no instances, no `(pins …)` groups and no hosted
  sub-blocks.
- **`implemented`** — anything else.

A `concept` section is then **upgraded to `implemented`** when the design shows it
is really built elsewhere: a `(group …)` (top level or inside `(diagram-layout …)`)
whose member list names both the section and a real sub-block, or a `(sub-block …)`
form written **directly after** the `(section …)` at design-block top level — the
house idiom for a subsystem whose pin-level implementation is sealed in a module.

ERC's `concept_remaining` check reports whatever is still `concept`. To close it,
give the section content or attach its sub-block by adjacency or by a group.

### Categories and the diagram

`(category <key>)` pins the section's diagram column and colour and is the source
of truth. Valid keys: `mcu`, `power`, `memory`, `peripheral`, `connector`, `clock`,
`comms`, `sensor`, `analog`, `protection`. Only a section **without** one is
classified by case-insensitive keyword matching on its name, falling back to
`connector` when the section holds a `J`/`P`-prefixed instance and to `peripheral`
otherwise. That fallback announces itself as a `section_category_inferred` info
naming the `(category …)` line that would pin it. The keyword table is generated
into [`language-forms.md` § *Section-name classifier keywords*](language-forms.md).

Other section-scope forms: `(description "text")` (one line, kept under ~100
characters), `(role input|output)`, `(protocol usb)`, `(diagram hidden)` to drop
the section from the block diagram without hiding it anywhere else,
`(hosts "sub1" …)` to fold named sub-blocks into this section's diagram node, and
`(row N)` / `(col N)` for grid placement. A section body may also carry
`(port …)`, `(bus-port …)`, `(calc …)`, `(net …)`, `(instance …)`, `(pins …)`,
`(sub-block …)`, the shorthands, and a nested `(section …)` one level deep.

### `(calc …)` — design maths that reaches the report

```lisp
(calc "LED current"
  (let vf 2.0)
  (let r  270.0)
  (let i  (/ (- 3.3 vf) r))
  (assert-range i 0.002 0.010 "I_LED"))
```

Each `(let …)` binds and records a value in the block's own scope; the
`(assert-range …)` is checked and surfaced in the review report. Its message uses
a different format from a top-level assertion — see
[§12](#12-assertions-and-checks).

### `(note …)` — three scopes, three shapes

This is the one form whose grammar changes with where it sits, and getting it wrong
loses text silently.

| Scope | Shape | Evaluated? |
| --- | --- | --- |
| design-block | `(note "REF" text)` — exactly 2 args | **both** arguments |
| instance body | `(note text)` — 1 arg | the argument |
| section / sub-section | `(note text)` or `(note text "literal")` | **the first argument only** |

```lisp
(design-block "Note Probe"
  (let r 4700)

  (instance "R4" (res-0402 "4.7k") (pin 1 "A") (pin 2 "GND")
    (note (fmt "instance note: R = ~R" r)))      ; ✓ "instance note: R = 4.7k"

  (note "R4" (fmt "design note: R = ~R" r))      ; ✓ "design note: R = 4.7k"

  (section "S1" "subtitle"
    (note (fmt "section note: R = ~R" r))        ; ✓ evaluated
    (note "SUBJECT" "two literal strings")       ; ✓ joined as "SUBJECT — two literal strings"
    (note "R7" (fmt "…" r))))                    ; ✗ text is "R7"; the fmt warns
```

A section note's second argument is a **subject label joined with an em dash**, not
a ref-des, and it must be a literal string. Anything else there that is not a
`(ref "file.pdf" (page N))` draws
`warning: unknown note modifier in (note …)`. If you want a computed section note,
put the whole sentence in the first argument.

### The four unrelated `(group …)` forms

`group` is overloaded across four grammars that share nothing but the word. When in
doubt, check the arity — a parenthesised member **list** means the design-scope
form.

| Where | Shape | Meaning |
| --- | --- | --- |
| design-block scope | `(group "name" ("R1" "R2" …))` | Visual grouping of ref-deses in the schematic. |
| `(diagram-layout …)` | `(group "Label" "a" "b" …)` | A labelled region over variadic block keys. |
| `(pins "REF" …)` | `(group "label")` | Label every pin this block declares. |
| `(rough …)` | `(group "name" "REF"…)` | A PCB rough-placement priority tier. |

### `(diagram-layout …)` and `(function …)`

```lisp
(diagram-layout
  (anchor "Power Input Header")
  (group "Power"   "Power Input Header" "3V3 LDO Regulator")
  (group "Blinker" "Schmitt Oscillator" "Status LED")
  (place "Expansion Header" (right-of "Status LED")))

(function "Sensing" "one SPI sensor" (hosts "Sense"))
```

`(diagram-layout …)` positions blocks relative to one another on the **schematic**
block diagram — nothing to do with PCB placement, which is the solver on
`/pcb-layout`. `diagram-layout` is the only spelling; the old `(layout …)` alias is
retired. `(function …)` is the hand-authored functional super-block for the
top-level system view.

Keep these in sync with the netlist by hand: a `(place …)` naming a block that no
longer exists is dropped silently, and a new block with no `(place …)` falls back
to auto-placement and can land anywhere.

---

## 7. Modules, sub-blocks and hierarchy

### Defining a module

```lisp
;; lib/modules/probe-ldo.sexp
(import ldo-3v3-sot23-5)

(block probe-ldo ((vout 3.3) (cin (cap-0603 "1uF")))
  "Generic LDO wrapper: vout is the programmed output, cin the input cap part."

  (let headroom (- 5.0 vout))
  (assert-range headroom 0.3 12.0 "LDO headroom")

  (design-block (fmt "~V LDO" vout)
    (instance "U1" ldo-3v3-sot23-5
      (pin VIN "VIN") (pin GND "GND") (pin EN "EN") (pin VOUT "VOUT"))
    (instance "C1" cin (pin 1 "VIN") (pin 2 "GND") (near "U1" VIN))
    (instance "R1" (res-0402 "100k") (pin 1 "VIN") (pin 2 "EN"))

    (net-envelope "VOUT" (rated (* vout 0.97) (* vout 1.03)) "regulated within 3%")

    (port "VIN"  in  power 5.0 (rated 4.5 5.5))
    (port "GND"      bidi power)
    (port "EN"   in  optional)
    (port "VOUT" out power (nominal vout)
                           (rated (* vout 0.97) (* vout 1.03)) (current 0.15))))
```

- The optional string after the parameter list is a **docstring**.
- A `(param default)` pair makes the argument optional. The default is evaluated at
  **call time**, so a later default may reference an earlier parameter, and a
  fully-defaulted module renders standalone everywhere a design does.
- The block's own `(let …)` and `(assert-range …)` run once per instantiation, so
  each call is validated at its own numbers.
- **A parameter may be a component, not just a number.** `cin` above is a family
  call, placed with `(instance "C1" cin …)`. Both the footprint and the value
  follow the argument, so this is a real part substitution.
- **Modules are first-class on every read surface.** A `lib/modules/` name works
  wherever a design name does: `/modules/<name>`, `run_checks`, `list_instances`,
  `/pcb-layout/<name>` — all resolve a bare module through its parameter defaults.

`(implements component (policy canonical|recommended|example) (role name))` declares
that a module is *the* way to use a primary component; a canonical implementation
prohibits direct board instantiation.

### Instantiating it

```lisp
(sub-block "ldo_a" (probe-ldo)
  (bridge "" (rename VIN "V_5V") (rename VOUT "V_3V3") GND))

(sub-block "ldo_b" (probe-ldo (vout 3.0) (cin (cap-0805 "10uF")))
  (bridge "B_" VIN VOUT GND EN))
```

Arguments may be positional, named, or mixed (positional may not follow named).
The sub-block's parts flatten into the netlist under its name — `ldo_a/U2`,
`ldo_a/C2` — and are renumbered into the board's global ref-des space. Its nets
become `ldo_a/VIN` and so on until a bridge or a `(net …)` ties them to board nets.

A `(sub-block …)` evaluates correctly at design-block top level, inside a
`(section …)` and inside a sub-section. House style puts it at top level
immediately after its section, which is also what credits that section as
implemented ([§6](#6-sections-and-the-block-diagram)).

### `(bridge …)` — how hierarchy is wired

`(bridge "PREFIX" PORT… (rename PORT SUFFIX)…)` emits **one net tie** per bridged
port `P`, between board net `PREFIX<suffix>` and module net `<name>/P`, where
`<suffix>` is `P` unless a `(rename …)` overrides it. It is exactly equivalent to
writing the `(net …)` lines out. Two idioms are in use:

```lisp
;; Shared prefix — the board nets are named after the peripheral.
(bridge "IMU_" SCK MOSI MISO (rename CS NCS))
;;   → IMU_SCK ↔ imu/SCK, IMU_MOSI ↔ imu/MOSI, IMU_MISO ↔ imu/MISO, IMU_NCS ↔ imu/CS

;; Empty prefix + one (rename PORT NET) per port — reads as a port → net map.
(bridge "" (rename VIN "V_5V") (rename VOUT "V_3V3") GND)
```

Power and ground ports are normally left *off* the bridge list and wired through
the consolidated `(net …)` rail forms instead — one `(net …)` per rail, so the
validator does not see a rail split across sections. Bridge them only when the
module's rail name genuinely differs from the board's.

A `(sub-block …)` accepts only `(bridge …)`, `(bridge-interface …)`, `(id …)`,
`(ids …)` and `(reflow)` as trailing children; anything else warns. `(reflow)` opts
the sub-block out of module-layout composition, so the parent lays its contents out
from scratch.

### Module-owned net envelopes

Most nets need no `(net-envelope …)`: a rail's envelope follows its own
declaration and carries across ferrite beads and series resistors. The ones that
*do* need one are usually a module's internals — a regulator's SET or FB node, a
bias pin behind its bypass cap — and those are a function of the module's
parameters, not of the board.

So `(net-envelope …)` is a module form too. Inside a module body the net name is
**module-local** and `LO`/`HI` are **evaluated expressions**, as in the example
above. On flatten the declaration lands on `sub-block/NET` at each
instantiation's own numbers: `(probe-ldo (vout 3.0))` gives `ldo_b/VOUT` a
2.91–3.09 V envelope, and the report says `declared in module ldo_b`.

**Precedence.** A board may restate or **widen** what a module claims; narrowing
it is a failed assertion, because the module owns the node. So is any declaration
that fails to cover what the design already proves:

```text
FAIL: (net-envelope "V_5V" (rated 4.5 5.5)) [declared on the board]
      does not cover the 3.3–3.3 V this design already declares for that net
```

---

## 8. `let`, `if`, structural control flow, variants

### `(let name expr)`

Binds `name` in the current scope to the evaluated value of `expr` and returns
nil — a side-effecting binder, not a value-producing form.

```lisp
(let vout     (* 0.6 (+ 1.0 (/ rfbt rfbb))))
(let vout-str (fmt "~V" vout))
```

### `(if cond then else)` as an expression

```lisp
(let label (if (> r 4000) "high" "low"))
```

Short-circuiting, ordinary Lisp truthiness, exactly one expression per branch.

### The five structural forms

`when`, `unless`, `if`, `for` and `repeat` are **statements as well as
expressions**. Written directly in a design scope their body holds whatever that
scope accepts — instances, ports, nets, `pins`, shorthands, sub-blocks, notes,
sections, and each other. All five are legal at design-block top level, inside a
`(section …)`, and inside a nested sub-section, and the generated forms are
indistinguishable from the same lines written out by hand.

| Form | Body | Runs when |
| --- | --- | --- |
| `(when cond form…)` | any number of forms | `cond` is true |
| `(unless cond form…)` | any number of forms | `cond` is false |
| `(if cond then else)` | exactly one form per branch | always — one branch |
| `(for name (item…) body…)` | any number of forms | once per item |
| `(repeat name start end body…)` | any number of forms | once per integer, inclusive |

```lisp
(design-block "Control Flow Probe"
  (let grade "A")
  (let precision (== grade "A"))

  (when precision
    (instance "R_SET" (res-0402 "49.9k") (pin 1 "VOUT") (pin 2 "SET")))
  (unless precision
    (instance "R_ALT" (res-0402 "49.9k") (pin 1 "VOUT") (pin 2 "SET")))

  (if precision
    (instance "C_REF" (cap-0402 "10nF" np0) (pin 1 "SET") (pin 2 "GND"))
    (instance "C_REF" (cap-0402 "10nF" x7r) (pin 1 "SET") (pin 2 "GND")))

  (section "Filters"
    (for ch ("A" "B")
      (for leg ("P" "N")
        (instance (fmt "R_F~a~a" ch leg) (res-0402 "33R")
          (pin 1 (fmt "AIN~a_EXT_~a" ch leg))
          (pin 2 (fmt "AIN~a_~a" ch leg))))))

  (repeat i 1 3
    (instance (fmt "C_B~a" i) (cap-0402 "100nF") (pin 1 "VOUT") (pin 2 "GND"))))
```

**In design scope the condition must be a boolean.** A number or a string is
rejected with an error naming the form: a silently-taken branch would add or drop
real parts, so truthiness is not guessed there. Since there are no `true`/`false`
literals, write a comparison — `(== variant "A")`, `(> vout 5.0)`, a `let`-bound
comparison, a module parameter compared against a value.

`(repeat …)` counts integers; `(for …)` walks a literal list, so a loop variable
can be a channel letter or a lane suffix. Each item is evaluated in the enclosing
scope, then bound in a fresh child scope for one pass, so a body-local `(let …)`
never leaks into the next iteration.

**Identity.** The **outermost** structural form owns one source-resident `(id …)`
anchor, minted into the file when missing — one anchor per nest, never one per
generated child. Every child derives its id from that anchor, its own stable
origin key, and the accumulated **key path** of the branches and iterations around
it: a taken `when`/`unless` body and an `(if …)` then-branch contribute `@t`, an
else-branch `@f`, and a `for`/`repeat` iteration `@<ordinal>`. So a child of
`(for …)` keys as `R_FAP@0`, and one inside `(when …)` → `(for …)` as `R_CALA@t@0`.
Flipping a condition therefore **re-derives** rather than re-uses, and nesting
composes. An `(ids ("R_FAP@0" <hex8>) …)` sidecar on the anchor pins migrated
identities, which is how a hand-unrolled block is folded into a loop without
changing its PCB UUIDs.

A body form the enclosing scope does not accept is reported at **its own**
`file:line:col`, with the message a hand-written sibling would draw.

### Assembly variants

One PCB, one netlist, one set of footprints — several build configurations
differing only in **which parts are populated** and **what value a populated part
carries**.

```lisp
(design-block "Variant Probe"
  (variant "Lite" "no radio, cost reduced")
  (variant "Pro"  "full feature set" (default))

  (instance "U7"  (sx1262)         (only-in "Pro"))       ; Pro only
  (instance "R14" (res-0402 "0R")  (dnp-in "Lite"))       ; everywhere but Lite
  (instance "R9"  (res-0402 "10k") (value-in "Pro" "4.7k")))
```

`(variant …)` is repeatable, at most one may carry `(default)`, and the name is a
literal quoted string. A design with no declaration has one implicit **base**
variant. The three instance clauses' arguments *are* evaluated, so a `let`-bound
name or an `(fmt …)` works.

Only assembly differences are expressible: the footprint and its pads stay on the
board in every variant. A difference that changes the netlist or the footprints is
a different board, not a variant.

**Variants are design-level.** A `(variant …)` inside a module body is an error,
while an instance inside a `(sub-block …)` names the **root design's** variants
directly; a name the root never declared is a build error naming the module's own
file and line, with a did-you-mean.

Select one with `--variant NAME`, `?variant=NAME`, or a structured tool's `variant`
argument; omitted, the `(default)` variant wins, and failing that the base. The
selection lands on each part's `dnp` flag and `value` **before** ERC, the BOM, the
exports and the views read them:

```console
$ netlisp instances --project-dir . p-var | jq -r '.variant, (.instances[]|"\(.ref_des) \(.value) \(.populated_in)")'
Pro
U7  0R   ["Pro"]
R14 0R   ["Pro"]
R9  4.7k ["Lite","Pro"]

$ netlisp instances --project-dir . --variant Lite p-var | …
Lite
R9  10k  ["Lite","Pro"]
```

Errors: `(dnp)` is unconditional, so combining it with `(only-in …)` or
`(dnp-in …)` is an error; so is naming one variant in both, a second `(default)`,
a duplicate variant name, and a duplicate `(value-in …)` for one variant. The
shorthand-generated parts take no variant clauses.

---

## 9. `connect`, `chain` and interface bundles

### Wiring shorthands

Before the anonymous forms, the ordinary ones. All of these emit real parts with
auto ref-deses and real nets:

```lisp
(net      "V_3V3" "VDD_ALIAS")                              ; merge two names
(series   "R20" (res-0402 "33R") "SWDIO_MCU" "SWDIO")       ; two-pin part between two nets
(pullup   "SDA" 4.7k "V_3V3")                               ; signal → positive rail
(pulldown "BOOT0" 10k)                                      ; signal → GND (or an explicit return)
(divider  "V_5V" "VSENSE" "GND" 10k 10k (expect 2.5 5%))    ; two resistors + an assertion
(led      "PWR" "V_3V3" green (r 1k))                       ; series resistor + indicator
(fanout   "V_3V3" (res-0402 "0R") "BR1" "BR2")              ; one part from a common net to each listed net
(decouple "V_3V3"
  (per-pin (cap-0402 "100nF") VCC)                          ; one bypass per named pin function
  (bulk    (cap-0805 "10uF") 1))                            ; shared rail reservoir
```

`(decouple …)` has a second, positional grammar
(`(decouple "VDD" (comp "val") COUNT per-pin REF PIN…)`) that still works and
records a `deprecated_form` info; so does `(decouple-defaults …)`. Prefer the
sub-form spelling and spell the host and the part at each site. Each generated
per-pin cap records its host ref and resolved pad as a real `(decouples …)`
binding, and lands on a stub net named `NET.REF.PAD`.

### `(connect …)` — a node named by its ends

Most nets in a signal chain exist only to have a name. `(connect …)` states such a
node by naming its **ends** instead:

```lisp
(connect "U2.3A" "s1/SCK" "J1.1")
(connect "U2.4A" "s1/MOSI" (name "SPI_MOSI") (class "spi-fast"))
```

An **END** is one of four spellings:

| Spelling | Means |
| --- | --- |
| `"REF.PAD"` | A physical pad on a placed part. |
| `"REF.FN"` | A pinout **function name**, resolved exactly as `(pin FN …)` does. |
| `"sub/PORT"` | A declared port of a sub-block — the same record a `(bridge …)` writes. |
| `"PORT"` / `"NET"` | A port of the enclosing block, or any ordinary net name. |

Resolution is deferred until the whole block is built, so an end may name a part
written *below* the `(connect …)`.

**No silent merges.** Wiring a pad that already carries a different net is an error
naming both:

```text
error: pad U2.2 is already wired to net "BUF"; this (connect …) would silently merge it
       with "n~U2-1Y~s1-SCK~J1-1" — wire one of them through a named (net …) if that is intended
```

Only two *anonymous* nodes landing on one pad merge — they are the same node stated
twice — and that merge is reported as a warning.

**The generated name.** Without `(name …)`, and with no end that is already an
ordinary net, the net is named from the **authored end tokens**:

```text
n~U2-3A~s1-SCK~J1-1
n~lpf4-OUTPUT~lpf_if_1-RF_IN
```

`n~` is the reserved prefix; `~` is URL-unreserved, is not `.` (the per-pin stub
separator) or `/` (the hierarchy separator), and survives the KiCad exports
verbatim. The identity comes from what the **source** says, never from a
post-flatten ref-des, so auto-numbering and sub-block renumbering leave the name
alone. Ends beyond 60 characters collapse to the first end plus a hash, and a
collision takes a `~2`, `~3`, … ordinal rather than merging two nodes. `(name "NET")`
gives an authored name instead — which is how a `(net-class … (nets …))` list or a
`(net-envelope …)` reaches the node; both also accept the generated name as written.

`(class "…")` names a `(net-class …)` and warns when no such class exists:
`warning: (class "spi-fast") names no (net-class …) in this design — the net is
wired, but carries no class`.

### `(chain …)` — a cascade in one line

```lisp
(chain "BUF" "R11" "R12" "OUT_END" (class "sig"))
;;   → BUF ↔ R11.1, n~R11-2~R12-1 between R11.2 and R12.1, R12.2 ↔ OUT_END
```

The first and last tokens are ordinary `(connect …)` ends; each ITEM between them
is one of:

| Spelling | Means |
| --- | --- |
| `"REF"` | A two-terminal part: in on its first pad, out on its second. More pads is an error. |
| `"sub"` | A sub-block declaring exactly one signal `out` port and, among the ports sharing that output's kind, exactly one `in`. Power, ground/bidi and optional ports are never candidates. |
| `"REF/IN>OUT"` | The two terminals named explicitly — pad ids or function names for a part, port names for a sub-block. |

```lisp
(chain "mixer/IF"
       "lpf4/INPUT>OUTPUT"      ; named terminals: this part also has ground pads
       "lna"                    ; unambiguous: one rf in, one rf out
       "dsa"
       "IF1_DSA"
       (class "if-50"))
```

### Interface bundles

`(bus-port …)` writes a bus whose lanes are **numbered**. SPI, I²C, UART, SWD and
JTAG lanes are **named**, and the names vary across vendors (`SCK`/`SCLK`,
`MOSI`/`SDI`, `CS`/`CSN`/`NCS`/`SS`). An `(interface …)` states one vocabulary
once, always from the **peripheral's** point of view:

```lisp
;; stdlib/interfaces/spi.sexp, bundled into the binary
(interface spi "Four-wire SPI (controller/peripheral), peripheral perspective"
  (signal SCK  in  clock)
  (signal MOSI in  data)
  (signal MISO out data)
  (signal CS   in))
```

`spi`, `i2c`, `uart`, `swd` and `jtag` ship with the binary; a project shadows one
with `lib/interfaces/<name>.sexp`, and an `(interface …)` at the top level of a
design or module file needs no file at all.

**The module side** declares its half with one line:

```lisp
(port-group "" spi)                          ; → ports SCK MOSI MISO CS
(port-group "SPI_DSA" spi (rename MOSI "SPI_DSA_SDI")
                          (rename CS   "SPI_DSA_CSN")
                          (omit MISO))       ; a write-only three-wire attenuator
(port-group "EXT" spi (role controller))     ; mirrors every direction
```

The name is `PREFIX_SIGNAL`, joined by one underscore however the prefix is spelled
(`"IMU"` and `"IMU_"` both give `IMU_SCK`); an empty prefix gives bare signal
names. Every trailing port modifier is replayed onto each lane. `(role controller)`
mirrors each direction — a bidirectional lane is its own mirror and never flips.
The group is addressed by its prefix, or by the interface name when the prefix is
empty, so `(port-group "" spi)` is the group `"spi"`.

**The board side** wires the whole bundle inside the `(sub-block …)`:

```lisp
(sub-block "s1" (probe-sensor)
  (bridge-interface "spi" (to "IMU") (rename CS "IMU_NCS"))
  (bridge "" (rename VDD V_3V3) GND))
;;   → IMU_SCK IMU_MOSI IMU_MISO IMU_NCS

(port-group "EXT" spi (role controller))
(sub-block "s2" (probe-sensor)
  (bridge-interface "spi" (to-group "EXT")))
;;   → EXT_SCK EXT_MOSI EXT_MISO EXT_CS
```

`(to "NET_PREFIX")` names board nets `NET_PREFIX_SIGNAL`; `(to-group "BOARDGROUP")`
ties signal by signal to a `(port-group …)` this block declares itself — how a board
passes a bus straight through to its own boundary. A signal the board group does
not carry is simply not tied, and a `(rename SIGNAL "NET")` overrides one lane
whichever destination form is used.

**ERC** treats a `(port-group …)` as a both-or-neither bundle: wiring `SCK` and
`MOSI` while leaving `CS` open is `interface_half_connected`. Lanes the vocabulary
marks `optional` are never demanded, and a group with nothing wired at all falls to
the ordinary required-port rule. Separately, `interface_naming` is an **info**
advisory that names the `(port-group …)` line which would replace a module's loose
ports.

### `(bus-net …)`

```lisp
(bus-port "IO" 0 3 io)          ; in the module
(bus-net  "IO" 0 3 "flash")     ; in the board → IO0…IO3 tied to flash/IO0…flash/IO3
```

`(bus-net "PREFIX" LO HI "SUB")` is the documented form: one
`(net "PREFIX<i>" "SUB/PREFIX<i>")` tie per index in the inclusive range. Two
further grammars hang off the same head — a strided one over `(over …)` × `(ports …)`
and a mapped one with `(suffix …)`/`(port-base …)` — and each records a
`deprecated_form` info, because the index means a different thing in each. Prefer
the basic form, or spell the ties with `(net …)`/`(bridge …)` generated by a
`(for …)`.

---

## 10. Typed attributes, design-owned rules, system contracts

### Typed attributes on a family call

A component-family call takes a value and then any number of attributes, written
bare or keyed. **The two mean exactly the same thing** — both normalise to the same
instance:

```lisp
(cap-0402 "1uF" x7r "10%" "25V")
(cap-0402 "1uF" (dielectric x7r) (tolerance 10%) (rating 25V))
;;   both emit   (attrs x7r 10% 25V)
(cap-0402 "100nF" (esr 10mR) (esl 0.4nH))
(res-0402-0p1 rset-str (tolerance 0.1%) (power 0.063W) (rating 50V) (tempco 25ppm/C))
```

| Keys | Property | Selects a `lib/parts/` row |
| --- | --- | --- |
| `rating`, `voltage` | `voltage` | yes |
| `dielectric` | `dielectric` | yes |
| `tolerance` | `tolerance` | yes |
| `power` | `power` | yes |
| `current` | `current` | yes |
| `tempco`, `tcr` | `tempco` | yes |
| `esr` | `esr` | no — an analysis override for the PDN screen |
| `esl` | `esl` | no — likewise |

The placed property is the one source the BOM, the parts-row lookup, the
capacitor-rating check, the PDN screen and the KiCad export read.

**A keyed attribute is checked**: an unknown key is an error with a did-you-mean,
and setting the same key twice is an error. **A bare attribute is classified, never
rejected**: `"25V"` → voltage, `"10%"`/`"±15%"` → tolerance, `x5r`/`x7r`/`np0`/`c0g`
→ dielectric, `"0.063W"` → power, `"1A"` → current, `"25ppm/C"` → tempco. Anything
else — `DNP`, `green`, `jumper`, a bead's `600R@100MHz` — stays a raw attribute and
reaches the schematic and the parts table untouched.

The parts lookup is deliberately lenient: with no row carrying the requested
rating it falls back to a value-only match and `netlisp check` reports the
substitution as an `attribute_row_mismatch` warning naming both values. A row that
is *better* than what was asked is silent — headroom ratings (`voltage`, `power`,
`current`) must be at least the authored one, deviation budgets (`tolerance`,
`tempco`) no wider. `dielectric` is categorical, so any difference is reported.

### Design-owned rules

A library `(requirement …)` is a rule the *component* hands the design: the
datasheet says the part needs it, so every board placing the part inherits it. The
rules a **board's own author** writes down have two forms of their own, accepted at
design-block, section, sub-section and module scope:

```lisp
;; A rule about one of this design's own parts.
(requirement "R9 keeps its pull to ground"
  (on "R9")
  (check (tied-to-net (pin "2") (net "GND"))))

;; A rule about NETS — no pinout, no (on …), nothing to place.
(net-rule "Every rail carries a reservoir and a class"
  (nets "V_*")
  (min-bulk-uf 4.7)
  (in-net-class))
```

```text
info  requirement  R9 [cb2fb887] — pin '2' on GND (matches GND)
info  requirement     [c9e5d577] — V_A: bulk to ground, µF: 10.000; in a net class
```

- **`(on "REF")`** names an instance of the **containing block**, and the check runs
  against that block — the same contract a library requirement gets, so `(pin "VIN")`
  resolves through that instance's pinout and against that block's nets. `"sub/REF"`
  reaches a part inside a sub-block and is judged **in the sub-block**. A target
  naming no instance **fails**, naming itself: a renamed part must not quietly
  retire the rule about it. Every `(check …)` primitive works unchanged — the full
  list is [`language-forms.md` § *Requirement checks*](language-forms.md).
- **Globs** match flattened net names — `V_*`, `*_RF`, `sub/*`, or an exact name —
  case-insensitively, where `*` matches any run of characters. A glob is matched
  both against the net's name as the rule's own block sees it and against its full
  flattened name. Per-pin bypass stubs (`V_3V3.U1.5`) are excluded. A glob matching
  **zero** nets is a **failed** result naming the glob, never a silent pass. The
  predicates are `(min-bulk-uf F)`, `(declared-envelope)`, `(in-net-class)` and
  `(max-fanout N)`; a rule may carry several and the net must satisfy every one.
- Both forms are gated **exactly like library requirements** — same statuses, same
  `netlisp check` findings, same review table — and carry `source: design` so a
  reviewer can tell "you used the part wrong" from "you broke your own contract".
- **Ids.** An explicit `(id "…")` wins; otherwise the id is the CRC32 of the rule's
  own text. Editing anything except that sentence — retargeting it, adding a
  predicate, moving it into a section — leaves the id, and therefore every sign-off,
  attached. Sign one off with:

  ```lisp
  (verifies (req design-rule "cb2fb887") "checked on the bench")
  ```

### System contracts

A *system* is the layer above one board: which boards form the product, which exact
connector contacts join them, and which review documents belong beside each
fabrication archive. It is authored as ordinary netlisp source in
`src/systems/<name>/system.sexp`:

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

**A system contract is never evaluated.** It is parsed straight into the strict
`netlisp-system-review-v1` spec, so **none of these forms is valid in a design
source** — a design writing `(interface "…" (mates …))` gets an unknown-form
warning. `netlisp system-check` and `GET /api/systems/:name/readiness` check the
contract against both boards' evaluated netlists and connector pad tables; the
`interface_mismatch` findings are listed in
[`language-forms.md` § *System contract forms*](language-forms.md).

Two details worth stating here. `(mates "board/CONNECTOR" …)` names the board as
the first path segment and then the connector's **stable source handle**, which may
be a sub-block path — deliberately not a flattened ref-des, which numbering may
change. And aliases are derived, not authored: writing
`(signal "V_12V" (left 1 "V_12V") (right 1 "V_12V_RF"))` *is* the declaration that
`V_12V_RF` on the right board is the system's `V_12V`. `(auto)` derives the whole
contact table from the two connectors' pad tables, for bring-up; a released product
should carry the explicit table so a later wiring change shows up as a diff.

---

## 11. Arithmetic and `fmt`

### Builtins

All are binary except `not` (unary) and `e96` (unary). Numbers are `f64`; `==` and
`!=` also work on strings.

| Category | Builtins |
| --- | --- |
| Arithmetic | `+ - * / %` |
| Comparison | `> >= < <=` |
| Equality | `== !=` (number↔number or string↔string) |
| Logic | `and or not` (eager — both arguments are evaluated) |
| Standard values | `e96` |

```lisp
(* 0.6 (+ 1.0 (/ 220k 47k)))     ; a feedback divider → 3.4085…
(e96 4630)                       ; → 4.64k, the nearest E96 (1%) value
(and (> v 0.6) (< v 16.0))
```

Division and modulo by zero are errors.

### `(fmt "template" args…)`

Formats a string with engineering-unit directives. Each `~X` consumes the next
argument, in order.

| Directive | Argument | Renders |
| --- | --- | --- |
| `~a` | any value | Generic display — a number by the rule below, a string verbatim, a boolean as `true`/`false`. |
| `~V` | number | The number, then `V`. **No SI scaling.** |
| `~R` | number | SI-scaled with `k` (≥ 10³) or `M` (≥ 10⁶); below 10³, bare. **No unit letter.** |
| `~C` | number | SI-scaled `F` (≥ 1) / `mF` (≥ 10⁻³) / `uF` (≥ 10⁻⁶) / `nF` (≥ 10⁻⁹) / `pF`. |
| `~A` | number | SI-scaled `A` (≥ 1) / `mA` (≥ 10⁻³) / `uA`; exactly zero renders `0A`. |
| `~S` | string | The string verbatim. A non-string argument is a type error. |
| `~~` | — | A literal `~`, consuming no argument. |

**The exact rounding.** Every number goes through one rule, applied to the *scaled*
mantissa:

- a whole number (and `|v| < 1e15`) prints as an integer with no decimal point;
- otherwise it prints with `{d:.4}` — **four decimal places, rounded** — and then
  trailing zeros and a trailing decimal point are trimmed.

So the scaling picks the prefix and the mantissa is what gets four places, not the
raw value. Measured output:

```lisp
(fmt "~V|~V|~V|~V"          3.3 3.41 12.0 0.123456)  ; → 3.3V|3.41V|12V|0.1235V
(fmt "~R|~R|~R|~R|~R"       47 4700 220000 2200000 0.5)
                                                     ; → 47|4.7k|220k|2.2M|0.5
(fmt "~C|~C|~C|~C|~C|~C"    100n 1u 22n 1p 2.2mF 2.0)
                                                     ; → 100nF|1uF|22nF|1pF|2.2mF|2F
(fmt "~A|~A|~A|~A|~A"       2.0 0.15 1mA 50u 0.0)    ; → 2A|150mA|1mA|50uA|0A
(fmt "~S|~a|~a|~a|~~"       "str" 2 "RF" 3.14159265) ; → str|2|RF|3.1416|~
(fmt "~R|~V"                1234.5678 1.00000)       ; → 1.2346k|1V
```

Note what the directives do **not** do: `~R` emits no `R`/`Ω`, and `~V` never
scales — `(fmt "~V" 0.0033)` is `0.0033V`, not `3.3mV`.

`(fmt …)` is how a computed number reaches a part value, a design name, a net name
and a note, so one number can drive all of them:

```lisp
(let r-osc 470k)
(instance "R2" (res-0603 (fmt "~R" r-osc)) …)
(design-block (fmt "~V Buck" vout) …)
(instance (fmt "R_F~a~a" ch leg) (res-0201 "33R") …)
```

**When a template does not hold.** All three failures are ordinary located
`file:line:col` errors that name the directive and its byte offset in the template.
The span points at the **argument** when the directive was reaching for one, and at
the **template** otherwise:

| What went wrong | Spanned at | Message |
| --- | --- | --- |
| Unknown directive | the template | ``(fmt …) unknown directive `~Q` at template offset 8 — the directives are ~a ~V ~R ~C ~A ~S ~~`` |
| Too few arguments | the template | ``(fmt …) directive `~V` at template offset 7 wants argument 2, but the form supplies 1`` |
| Wrong kind of argument | **the argument** | ``(fmt …) directive `~V` at template offset 2 needs a number argument`` |

The accepted set in that first message is rendered from the directive table itself,
so it is exactly the seven rows above: `~a ~V ~R ~C ~A ~S ~~`. The "needs a *kind*
argument" wording comes from the same table's argument column — `~S` handed a number
says `needs a string argument`.

---

## 12. Assertions and checks

### `(assert cond "message")` and `(assert-range value lo hi "label")`

```lisp
(assert (> (- v-in v-rail) 0.5)
  "LDO input-to-output headroom must exceed the regulator's dropout voltage")
(assert-range (* i-led 1000.0) 2.0 10.0 "LED current (mA)")
```

`(assert …)`'s message must be a string. `(assert-range …)` builds its own message
in the fixed shape `LABEL = VALUE (range LO-HI)`. Every number in it — the value and
both bounds — goes through one rule:

- a **whole** number prints plain, with no decimal point and no trailing `.0`;
- an ordinary magnitude prints at four decimal places with trailing zeros trimmed;
- a magnitude **below a hundredth** prints at the shortest text that round-trips,
  because four decimals stop carrying such a value's own digits.

```text
VOUT = 3.3 (range 0.6-16)
LED current (mA) = 4.8148 (range 2-10)
LED current (A) = 0.0048148148 (range 0.002-0.01)
```

That last line is why the rule exists: under a flat one-decimal rendering a
milliamp-scale window reported itself as `(range 0.0-0.0)`, a message that described
nothing.

Inside a `(calc …)` block the same head renders differently, and that spelling is
unchanged — label, colon, three decimals everywhere, and a bracketed interval:

```text
I_LED: 0.005 in [0.002, 0.010]
```

### Which layer aborts

**Assertions never interrupt *evaluation*.** The design is evaluated to the end and
every assertion is recorded, so one run tells you about all of them rather than
stopping at the first. What happens *after* evaluation is decided per command, by
what that command hands you. `netlisp help` states the same rule.

| Layer | Commands | A failed assertion |
| --- | --- | --- |
| **Hand off the board** | `build`, `export-kicad` | Every assertion prints, the failing ones at `file:line:col`. **Nothing is written** — no resolved design on stdout, no `.bom`, no KiCad project — and the command exits 1. Ids that were minted *are* still written back to the source. |
| **Report** | `check` | One **error-severity** finding beside the ERC and requirement findings. The whole report still prints; exit 1. |
| **Review** | `export-pdf`, the served pages, `review-audit` | The document is still produced. A review of a board that fails its own arithmetic is exactly what you want to read, so the PDF's *Validation* page lists every assertion (`Assertions: 2 pass, 2 warn, 2 fail`) and the schematic page shows the failing ones. Exit 0. **Caveat:** the `review-audit` Markdown is written but does *not* carry them — its release-profile row counts only non-assertion findings, and `run_fab_readiness` passes on warning-severity assertions alone — so read the audit beside `netlisp check`, not instead of it. |
| **Derived views** | `export-kicad-sch`, `export-spice`, `export-pinmap`, `netlist-dump`, `instances`, … | Produced regardless. Exit 0. |

The `file:line:col` on a `FAIL:` line is the assertion's **first argument** — the
condition of an `(assert …)`, the value expression of an `(assert-range …)` — so it
is as jumpable as a compiler diagnostic:

```console
$ netlisp build --project-dir . p-layer
PASS: v exceeds 1V
FAIL: ./src/p-layer.sexp:6:11: v exceeds 5V
PASS: VOUT = 3.3 (range 0.6-16)
FAIL: ./src/p-layer.sexp:8:17: VIN = 3.3 (range 5-12)
Build failed: the design's own assertions do not hold — nothing was emitted.
  Evaluation never stops at an assertion, so every one above was checked; a
  command that EMITS refuses to write a netlist, BOM or export the design's
  own arithmetic contradicts. `netlisp check` reports the same failures as
  findings beside ERC, prints its whole report, and exits 1.
$ echo $?
1
```

An assertion with no source form of its own — the frequency-plan and PLL analyses
synthesise theirs — falls back to the bare message with no location.

**Warning-severity assertions block nothing, in any layer.** They print `WARN:` and
are reported as `warning assertion` findings. Two kinds exist: evaluator diagnostics
recorded as assertions (a dead-end net, for instance), and the *advisory* rows an RF
analysis raises — `(frequency-plan … (mode advisory))` and `(pll-loop …)`. A build
carrying only those still emits its resolved design and its `.bom`, and exits 0.

### `netlisp check`

`check` runs the electrical rule checks (floating nets, unconnected pins, duplicate
ref-deses, voltage mismatches, decoupling and adjacency bindings, strap and
no-connect sign-offs, interface and differential-pair completeness), the executable
component and design-owned requirements, and the datasheet-review gate. Three
profiles:

- **`authoring`** (default) — open obligations are informational or warnings.
- **`preflight`** — incomplete datasheet reviews and unverified manual requirements
  become errors.
- **`release`** — preflight plus the component-class profile obligations, at least
  one cited requirement on every active part, and the evaluator's own warnings
  promoted (an unknown sub-form becomes an error).

`--severity info` shows the informational rows, including every `deprecated_form`
notice:

```text
info  deprecated_form  — probe-sensor.sexp:9:26: a bare trailing number in (port "VDD" …)
                         is the old nominal-voltage spelling — write (nominal 3.3)
info  deprecated_form  — p-wire.sexp:29:4: a non-virtual (test-point "TP1" "BUF" …) places
                         the same physical pad as (instance "TP1" testpoint (pin 1 "BUF"))
```

`netlisp build` deliberately does **not** run ERC — the build path exists to
evaluate and view work in progress. Run `check` to gate.

### Sign-offs

`(verifies (req "REF" REQID) [rationale])` marks a library requirement satisfied by
a specific instance; `(verifies (req design-rule "<id>") …)` does the same for a
design-owned rule. Both live naturally in the `<name>.checks.sexp` sidecar.

---

## 13. Sidecars and identity

### The four files

A design may be split across up to four files that live next to each other under
`src/`. Every sidecar is **optional** and is autoloaded by basename: when
`src/<name>.sexp` is evaluated, each sibling that exists is parsed and its top-level
forms are spliced onto the end of that design's `(design-block …)` body. There is
nothing to import and nothing to declare.

| File | Holds |
| --- | --- |
| `<name>.sexp` | the circuit: `section`, `instance`, `net`, `sub-block`, `port`, the shorthands — plus `board-role`, `hierarchical-ids`, `revision` |
| `<name>.checks.sexp` | verification forms (`verifies`, `assert`, …) — deliberately unrestricted |
| `<name>.layout.sexp` | `board`, `stackup`, `net-class`, `pcb-plan`, `design-rules`, `pdn`, `module-policy`, `net-envelope`, `power-plane`, `rough`, `fabrication-layer`, `kicad-pcb` |
| `<name>.diagram.sexp` | `diagram-layout`, the design-scope `(group "name" ("R1" …))`, `function` |

`board-role` and `hierarchical-ids` stay in the design file on purpose: they change
what the design *is* rather than how it is laid out.

Two rules keep the split honest, and both are errors:

```text
src/x.layout.sexp:17:1: error: (diagram-layout …) belongs in the .diagram.sexp sidecar, not x.layout.sexp
src/x.layout.sexp:13:1: error: (stackup …) is declared twice: here and at x.sexp:4 — a design may declare it once
```

`stackup`, `board`, `pcb-plan`, `design-rules` and `diagram-layout` may each be
declared once per design; because the splice appends, a second copy would otherwise
be resolved by file order rather than by you.

Sidecars are part of the design in every sense that matters downstream: they are in
the evaluator read-set (so the served page refreshes when one is edited), in the
fabrication gate's provable closure, the release source closure, the design archive
and the system-review package. A diagnostic raised by a spliced form reports against
the **sidecar's** own path and line, and an `(id …)` minted by a form that lives in a
sidecar is written back **into that sidecar**, never into the design file at a
foreign byte offset.

`netlisp tool split-design` does the move for an existing design and proves it: every
eligible top-level form is lifted at its parser span byte for byte, together with the
comment block above it, and the write is refused unless the original and split trees
evaluate to the same flattened netlist *and* the same evaluated design-scope form set.

### `(id …)` — what is written back into the source

Every part needs a stable identity that survives a rename, a ref-des reshuffle and a
module re-parameterisation, because the BOM row and the PCB footprint hang off it
(`id` → `uuidFromId` → the KiCad `tstamp`).

The build **mints an 8-character hex `(id …)` into the source** on every form that
needs one and does not have one: instances, `series`, `decouple` and the other
shorthands, sub-blocks, structural control-flow anchors, `stub`, `test-point`. The
first character is always `a`–`f`, so an id can never be mistaken for a numeric
literal. You do not write these by hand; you only need to not delete them.

```lisp
(when precision
  (instance "R_SET" (res-0402 "49.9k") (pin 1 "VOUT") (pin 2 "SET")) (id b7260ab9))
```

For parts *inside* a `(sub-block …)` there are two schemes:

- **Legacy (default).** Each `(sub-block …)` carries an enumerated
  `(ids ("U1" …) ("C106" …) …)` sidecar — one frozen entry per child, keyed on the
  seed-time ref-des, written at the call site. Verbose, and the key drifts when a
  part renumbers because of an edit upstream.
- **Hierarchical (opt-in).** Add `(hierarchical-ids)` to the design-block body. Then
  each `(sub-block …)` gets **one** id and every child's id is derived from it plus
  the child's stable module-local origin key, so no `(ids …)` sidecar is written and
  a renumber cannot shuffle identities:

  ```lisp
  (design-block "Hier Probe"
    (hierarchical-ids)
    (sub-block "a" (probe-ldo) (id feb7cc4b))
    (sub-block "b" (probe-ldo (vout 3.0)) (id be7105e5)))
  ```

The two schemes coexist per design. Switching an existing design to
`(hierarchical-ids)` changes its child ids, so it is a one-time board re-stamp —
adopt deliberately.

### `<name>.bom` and `<name>.layouts.json`

`<name>.bom` is written by `netlisp build`: the identity ledger, one record per
instance with its resolved uuid, its `(id …)`, its value, its nets and a
`source-fingerprint` of the library entry it came from.

```lisp
(part "J1" "d40a898b-458d-5f76-89f1-e2df8d271b29" "pin-header-1x2"
  (id "d495cebb")
  (value "")
  (source-fingerprint "21f6…f24b")
  (nets "GND" "V_5V")
  (description "2-pin 2.54 mm (0.1 in) through-hole pin header, single row"))
```

It is the ledger for the **base** assembly: every variant's parts are in it and it
records the authored value, never a `(value-in …)` override, so building a
non-default variant cannot disturb the MPN selections the base rows carry.

`<name>.layouts.json` is written by the PCB tools (`set_part_poses`, `route_pcb`,
`save_pcb_layout`, …) and holds the board outline, the placement and the routed
copper, as one or more **named** layouts of which one may be starred as the default.
It is not authored by hand; the design source declares intent (`(board …)`,
`(stackup …)`, `(net-class …)`) and the sidecar holds geometry.

A part's pose in there is its **footprint origin** in board millimetres, y growing
down — the `(0,0)` its land pattern's `(pad … (pos X Y))` offsets are measured from.
That is the body centre only when the pads happen to be centred on it: the bundled
0.1 in pin header puts pad 1 at `(0, 0)` and its courtyard at `y = -1.27 … 3.81`, so
its origin sits 1.27 mm from the middle of the strip. `set_part_poses`' `x_mm`/`y_mm`
and `describe_pcb_layout`'s `parts[].x`/`y` are that same point, which is what lets
one be fed straight back to the other.

Both belong in version control: committing them is what makes a clone show the same
board, and what makes a rebuild a no-op.

---

### Editing a split design from the GUI, and undo

The GUI edits them in place too. The PCB **Design Settings** drawer
(`/api/design-rules/:name`, `/api/stackup-planes/:name`), the Layout tab's
drag-to-arrange writeback (`/api/diagram-layout/:name`) and the subcircuit
supply-plane toggle (`/api/power-plane/:name`) each patch **the file that
actually declares the form**, at that file's own byte spans — so on a split
design the `(design-rules …)` edit lands in `<name>.layout.sexp` and the design
file is not touched at all. A form nobody has authored yet is created in the
sidecar that owns its kind when the design has one, and in the design file when
it does not; the same singleton declared in two of the files is refused, naming
both, which is the state the loader would refuse anyway. Nothing about a split
design is read-only from the GUI.

Undo covers them. A history snapshot captures the design source **and** every
sidecar that exists beside it, so the entry written before a settings save
contains the file that save changed; restoring it moves all of those files back
together, and removes a sidecar the entry proves did not exist in that revision
(an entry written before this — one with no `.files` manifest — still restores
its design file and leaves today's sidecars untouched). The schematic page's
raw-source editor covers them too: on a split design its title bar grows a file
picker listing the design source and each sidecar that exists, and saving one
goes through the same whole-file replace, the same syntax check, the same
re-evaluation of the whole design, and the same history snapshot as a design
save — `GET`/`POST /api/source/:name?file=design|checks|layout|diagram` (see
`docs/webserver-api.md`). Only an already-authored sidecar is offered and
writable; `split-design` below is what creates one.

## 14. Exports

Everything below reads the same evaluated design, so none of them can disagree with
the schematic.

| Command | Produces |
| --- | --- |
| `export-kicad --output-dir <d> [--with-schematic]` | A complete KiCad project: `.net` netlist, `footprints.pretty/` with every land pattern used, `models/`, and with `--with-schematic` the `.kicad_sch` hierarchy, `netlisp.kicad_sym`, `sym-lib-table` / `fp-lib-table` and `<name>.kicad_pro`. |
| `export-kicad-sch [--flat]` | The hierarchical schematic alone — root plus one `.kicad_sch` per section/module. |
| `sync-kicad-sch` | Pushes that schematic *into* the KiCad project directory the design's `(kicad-pcb "<path>")` names, guarded. |
| `export-pdf` | The design-review PDF: cover, per-section schematics, the validation table with every assertion and check, and the power table. |
| `export-pinmap [--format c\|json]` | The firmware pin map — every connected pad of every hub IC with its function, its `(as …)` alternates, its net and the `(pins … (group …))` / `(section …)` it was declared in. |
| `export-spice` | A flattened SPICE netlist: R/C/L/ferrite/diode/transistor element lines plus one empty `.subckt` stub per IC. Its header states its own limits — no models, no parasitics. |
| `export-schematic-png`, `gerber-dump`, `netlist-dump` | A block PNG without a browser; the unstamped fabrication artwork of a saved layout; the flattened netlist. |
| `export-system-review` | A watermarked review ZIP for a `(system …)` — Markdown, PDF and an offline HTML dossier, with no fabrication CAM. |

`--variant NAME` is accepted by `build`, `check`, `instances`, `export-kicad`,
`export-kicad-sch` and `export-pdf`.

The `.sexp` stays canonical after an export. `import-kicad-layout` brings a routed
board back the other way as the design's starred layout, leaving the board file
read-only.

---

## 15. Board and layout forms

These are the forms that describe the *physical* board. They belong in the
`<name>.layout.sexp` sidecar (or the design file, if you have not split it). Their
option grammars are large and fully tabulated in
[`language-forms.md` § *Design-scope forms*](language-forms.md); what follows is
what each one is for, with a worked example.

```lisp
;; src/p-side.layout.sexp
(board
  (part-number "PROBE-1")
  (size 40.0 25.0)
  (corner-radius 2.0)
  (keepout "antenna clearance"
    (rect 30.0 0.0 10.0 8.0)
    (side both)
    (blocks components tracks vias)
    (allow-nets "GND")
    (reason "keep copper out from under the antenna"))
  (left "J1")
  (corners "H1" "H2" "H3" "H4"))

(stackup 2 (pour bottom "GND"))
(design-rules (clearance 0.15) (track-width 0.2) (via 0.4 0.2))
(net-class "power" (width 0.5) (nets "V_5V"))
(module-policy (placement-class "V_5V" input_rail))
```

- **`(board …)`** is the outline in millimetres — `(size W H)` is required, and
  without it the form is inert — plus the parts pinned to it.
  `left`/`right`/`top`/`bottom` dock a part flush **inside** that physical edge,
  slid along it toward the pads it connects to; `(corners "REF"…)` pins mounting
  hardware to the four corners in the order TL, TR, BR, BL. `(corner-radius R)`
  rounds the outline. `(perimeter-fence …)` generates plated vias around the
  outline. Everything else is placed by the solver.
- **`(board … (keepout "NAME" …))`** is the *authored* keepout, as opposed to the
  two derived ones (`(perimeter-fence … (keepout …))` computed from the outline and
  `(net-class … (keepout MM))` computed from copper). It states a mechanical fact —
  a heatsink plate, a shield can, a bracket, a connector shroud — so nothing about
  the outline, the fence or the routing can move it. `(rect X Y W H)` is board-local
  millimetres from the outline's top-left; the rectangle must lie wholly inside
  `(size W H)`. The placer refuses a component courtyard there, DRC reports a
  fab-blocking `board keepout` for a courtyard, track or via that lands there, and
  `(allow-nets …)` admits named copper anyway. A rectangle outside the outline, a
  non-positive size or an unknown `side`/`blocks` word **stops the build**; the
  derived keepouts degrade to a warning only because there is something to fall back
  to.
- **`(stackup N | "PRESET" …)`** declares the copper stack: N layers, with
  `(plane IDX "NET")` making a layer a solid plane and `(pour top|bottom "NET")` as
  sugar for a plane on the matching outer layer. `(stackup 2)` is a plain two-layer
  board with no planes; `(stackup 2 (pour bottom "GND"))` is the classic one with a
  bottom ground pour. Physical construction — `(copper …)`, `(dielectric …)`,
  `(soldermask …)`, `(thickness …)` — is optional and independent of electrical
  role, and is what controlled-impedance synthesis reads.
- **`(design-rules …)`** are the board-level defaults: clearance, minimum drill and
  width, mask margin and web, annular ring, pour clearance, default track width and
  via geometry. A per-net `(net-class …)` still overrides width, clearance and via
  for its own nets.
- **`(net-class "name" …)`** is *routing geometry* and routing order for named nets —
  width, clearance, via size, priority tier, `(diff-pair …)`, `(impedance …)`,
  `(max-freq …)`, `(fence …)`, `(match-group …)` and the rest. Membership is
  `(nets "A" "B" …)`; a reusable subcircuit may assign membership while a destination
  board declares the same class name with geometry and no nets.
- **`(module-policy (placement-class "NET" <class>))`** is *placement criticality* —
  how tightly the placer packs a net's loop and how early the router claims its path.
  The two words meant different things and sharing one made every reading a guess, so
  `placement-class` is the spelling; `(module-policy (net-class …))` is a permanent
  alias that records a `deprecated_form` info. Design-block scope only; the net is the
  flattened name, or a bare leaf matching every module-local net of that name. A
  pinned net stops being reported as `layout_class_inferred`.

Also in the layout sidecar, each documented in the generated reference:

| Form | For |
| --- | --- |
| `(pdn "NET" (ripple-v V) …)` | The transient-noise budget for one power domain; drives the routed-board PDN impedance screen. |
| `(pcb-plan (place …) (route …))` | The ordered plan for completing the layout — which parts are placed first, which nets are routed first, with per-wave layer, via and waypoint constraints. |
| `(rough (anchor "REF") (group …) (critical-loop …))` | The rough-placement seed: which IC everything centres on and which parts pack tightest to it. |
| `(power-plane on\|off)` | Whether a subcircuit's supply rails use planes or route as ordinary copper. Ground planes are retained either way. |
| `(fabrication-layer "FILE.gbr" …)` | Separately applied artwork such as FPC backing tape. |
| `(net-envelope "NET" (rated LO HI) ["why"])` | The worst-case DC potential a net's copper reaches, for the release rating checks — see [§7](#7-modules-sub-blocks-and-hierarchy). |

Those twelve heads — `board`, `stackup`, `net-class`, `pcb-plan`, `design-rules`,
`pdn`, `module-policy`, `net-envelope`, `power-plane`, `rough`,
`fabrication-layer`, `kicad-pcb` — are the *complete* set the layout sidecar
accepts. Anything else there is refused by name:

```text
src/p-pll.layout.sexp:1:1: error: (pll-loop …) is not a .layout.sexp form — move it back into the design file
```

So `(pll-loop …)` and `(frequency-plan …)` — the gated RF analyses that emit
ordinary build/check assertions for an inverting active charge-pump loop and a
fixed-LO downconversion plan — belong in the design file itself (or in the
unrestricted `.checks.sexp`).

### The KiCad board target

```lisp
(kicad-pcb "/mnt/nas/kicad/barracuda/barracuda.kicad_pcb")
```

This is the one form in the language whose value is a property of the **machine**,
not of the circuit — so it also resolves from outside the source. A
`kicad-projects.sexp` at the project root maps design names to board paths:

```lisp
;; projects/designs/kicad-projects.sexp — the design name is the SOURCE FILE STEM
(kicad-pcb "barracuda" "/mnt/nas/kicad/barracuda/barracuda.kicad_pcb")
```

An entry there **overrides** the design's own form and **supplies** the target when
the design declares none, so a shared design file need carry no absolute path. The
file is optional and fail-open: absent, unreadable or malformed, every design falls
back to what its own source declares.

### Test points and mechanical parts

```lisp
(instance "TP1" testpoint (pin 1 "+3V3"))                     ; the recommended spelling
(test-point "TP2" "BLINK" (purpose "scope the real blink rate"))
(test-point "TPV" "OSC" (virtual))                            ; schematic-only marker, no pad
(instance "H1" mounting-hole-m2 (pin 1 "GND"))
```

A `(test-point …)` without `(virtual)` places **the same physical pad** as the
`(instance …)` spelling, plus its `(purpose …)` / `(required-for …)` metadata, and
records a `deprecated_form` info saying so. `(virtual)` has no other spelling and is
not deprecated. Test points take a renumber-safe `TP` ref-des from their own counter
and are exempt from the "IC has no ground" ERC.

Because the schematic's hub/spoke rule calls every non-passive prefix a hub, board
**fixture** — the `TP`, `H`/`MH`/`MK`/`M` and `FID` classes, each a pad and a label
and nothing else — is drawn as a hub too. It does not, however, spend a budget meant
for circuit blocks: `export-schematic-png` refuses an unfocused render above **eight**
hubs, and fixture is not counted, so a four-block board with four test points and four
mounting holes renders without `--ref`. Nine *real* hubs still refuse, and say so:

```text
design has more than eight schematic circuit hubs (test points, mounting holes and
fiducials are not counted); choose sub=<slug> or ref=<hub>
```

---

## 16. Common mistakes

**1. Writing `(status implemented)` in a section.** There is no such form —
`warning: unknown sub-form (status …) in (section …)`, and nothing changes. Status
is *inferred*: `concept` when the section has no instances, no `(pins …)` groups and
no hosted sub-blocks, `implemented` otherwise. A section whose implementation is
sealed in a module is credited as implemented by adjacency (a `(sub-block …)`
written directly after it) or by a `(group …)` naming both the section and the
sub-block. See [§6](#6-sections-and-the-block-diagram).

**2. Expecting a section subtitle or a section note to evaluate.** The section
subtitle is the second positional argument and must be a **literal string**; a
`(fmt …)` there is not a subtitle at all — it falls into the body and draws
`unknown sub-form (fmt …) in (section …)`. And a section-scope
`(note "R4" (fmt …))` is not the design-scope two-argument note: at section scope
the first argument is the text (so the note reads `"R4"`) and the `(fmt …)` warns
as an unknown note modifier. The rule is per scope — design-block `(note "REF" text)`
evaluates both arguments, an instance `(note text)` evaluates its one, and a section
`(note …)` evaluates only its first. See [§6](#6-sections-and-the-block-diagram).

**3. Believing a failed assertion is only a finding.** It is a finding *inside*
evaluation — the design is evaluated to the end and every assertion is recorded —
but the layer that follows decides. `netlisp build` and `netlisp export-kicad` hand
off the board, so they print every assertion (the failing ones at `file:line:col`)
and **exit 1 with nothing written** — no resolved design, no `.bom`, no KiCad
project; only the minted ids still land back in the source. `netlisp check` reports
each as an `error assertion` beside the ERC findings and exits 1. `export-pdf` and
the served pages still produce their document *with* the failure in it, `review-audit`
still writes its audit (but does not carry the failure — read it beside `check`), and
every other export is a derived view produced regardless. A *warning*-severity
assertion — a dead-end net, or an advisory `(frequency-plan …)` / `(pll-loop …)`
row — blocks nothing anywhere. See [§12](#12-assertions-and-checks).

**4. Writing a pin function name that starts with a digit, unquoted.**
`(pin 1A "NET")` is the *number* 1 carrying the SI unit letter `A`. That no longer
passes in silence: because the part's pinout has a function literally named `1A`,
the two readings collide and the **build stops** at `file:line:col`, naming both and
the quoting that picks one. `(pin 3A …)` on a hex inverter is the same error — pad 3
versus the pad 5 its pinout calls `3A`. Write `(pin "3A" "NET")` for the name or
`(pin 3 "NET")` for the pad. When nothing on the part answers to the text (`2V` on
that inverter) it binds the numeric pad **with a warning** naming both readings. The
trigger is a digit run followed by a scale letter (`k M G u n p`, or `m` before a
unit letter), a unit letter (`V A F H R`) or `%`; `1Y` and `1B` are unaffected
because `Y` and `B` are neither. Bare atoms like `VCC`, `GND`, `VIN` and `PA3` are
always safe, a bare `(pin 1 …)` is unambiguous, and a quoted token is resolved as a
function name first and a pad id second — so quoting is never wrong. The check
covers `(pin …)` and `(pins "REF" … (pin …))` only; a `(strap-ok 3A …)` or
`(nc-ok 3A …)` still binds the number quietly. See
[§5](#5-instances-pins-nets-and-ports).

**5. Expecting `~R` to print an `R`, or `~V` to scale.** `~R` emits `47`, `4.7k`,
`2.2M` — SI-scaled, with **no** unit letter. `~V` emits the plain number plus `V`
with **no** scaling, so `(fmt "~V" 0.0033)` is `0.0033V`. The rounding is: a whole
number prints as an integer, otherwise the *scaled mantissa* prints to four decimal
places and trailing zeros are trimmed — `(fmt "~R" 1234.5678)` is `1.2346k`.
`(assert-range …)` has its own fixed format — `LABEL = VALUE (range LO-HI)`, whole
numbers plain, ordinary magnitudes at four trimmed decimals and anything under a
hundredth at full round-trip precision, so `VOUT = 3.3 (range 0.6-16)` and
`LED current (A) = 0.0048148148 (range 0.002-0.01)`. Inside a `(calc …)` block a
third (`I_LED: 0.005 in [0.002, 0.010]`). And a template that does not hold is a
located error naming the directive, not a bare `error.FormatError`. See
[§11](#11-arithmetic-and-fmt) and [§12](#12-assertions-and-checks).

**6. Reaching for `cond`, `true`/`false`, or `1e-7`.** None of the three exists.
`cond` was removed — nest `(if …)` or use `(when …)`/`(unless …)`. There are no
boolean literals; write a comparison. There is no exponent notation; write `100n`
or `0.0000001`. And bare `m` is not a scale — `2.2m` is an atom, `2.2mF` is
0.0022.

**7. Assuming your descriptive ref-des survives.** `R_SET`, `C_BULK` and `""` are
auto-assigned from the part's class prefix and every reference to them is rewritten,
so the netlist shows `R8`, `C1`, `R9`. Only `<uppercase letters><digits>` is kept
verbatim. The *authored* token is still the stable origin key that `(id …)`
derivation and `"sub/REF"` rule targets use — but if you need to see a name in the
netlist, spell it as a standard ref-des. See
[§5](#5-instances-pins-nets-and-ports).

**8. Putting a form in the wrong sidecar, or twice.** Both are errors that name the
file that should hold it, and `stackup`, `board`, `pcb-plan`, `design-rules` and
`diagram-layout` may each be declared once per design. And a design-scope form
written *after* the closing paren of `(design-block …)` is not a design form at all —
it is evaluated as an expression and fails with `unknown name`. See
[§13](#13-sidecars-and-identity).

---

## Where to look next

- [`language-forms.md`](language-forms.md) — the exhaustive generated grammar: every
  form, arity and scope, plus the instance/port/sub-block/pins sub-form tables, the
  requirement checks, the net-rule predicates, the thermal declarations, the system
  contract forms, and the section classifier keywords. `netlisp reference [section]`
  prints the same content out of the binary.
- [`standard-library.md`](standard-library.md) — what ships in the binary and how a
  project extends or shadows it.
- [`../examples/README.md`](../examples/README.md) — a complete board, built,
  checked, laid out, routed and exported.
- [`build-and-run.md`](build-and-run.md) — the full build / run / deploy reference,
  including the id-persistence rules.
- [`webserver-api.md`](webserver-api.md) — every HTTP route and structured tool.
- [`architecture.md`](architecture.md) — how the pipeline fits together.
