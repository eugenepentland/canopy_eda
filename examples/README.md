# Your first board

This directory holds complete netlisp projects you can build, check, lay out
and export without writing anything first. Start with
[`blinky-breakout`](blinky-breakout): a 5 V input, a 3.3 V regulator, a
Schmitt-trigger oscillator blinking an LED, and four spare logic gates on an
expansion header. Twenty parts, one source file, one small project library.

It assumes you know electronics and have never seen this tool. Every command
below is run from the repository root after
[the quick start](../README.md#quick-start); `zig build run --` builds the
binary if needed and passes everything after `--` to it, so `netlisp build …`
and `zig build run -- build …` are the same command.

```text
J1 ──► U1 (3.3 V LDO) ──► U2 gate 1 (RC oscillator) ──► gate 2 ──► R3 ──► D1
                          U2 gates 3-6 ─────────────────────────────────► J2
```

---

## 1. Build it

```bash
zig build run -- build --project-dir examples/blinky-breakout blinky-breakout
```

`--project-dir` names the project; the trailing argument names the design
(`src/<design>.sexp`). The build parses the file, evaluates it, resolves every
part against the libraries, runs the checks, and prints the flattened design —
instances, nets, ports and notes — to stdout.

The three lines at the top are the design's own assertions:

```text
PASS: LDO input-to-output headroom must exceed the regulator's dropout voltage
PASS: LED current (mA) = 4.8148 (range 2.0-10.0)
PASS: Blink rate (Hz) = 2.6596 (range 0.5-5.0)
```

The build also **writes two things back into `src/`**:

* an 8-character `(id …)` marker on every instance that lacked one, spliced
  into the `.sexp` at its source position. Those ids are what make a part's
  identity survive a rename or a ref-des reshuffle, so the BOM and the PCB
  layout stay attached to the right part.
* `blinky-breakout.bom`, a sidecar recording each part's resolved identity,
  value, nets and a fingerprint of the library entry it came from.

Both are committed here, so the first build you run changes nothing: run it
twice and `git status` stays clean.

## 2. Read the source

Open [`blinky-breakout/src/blinky-breakout.sexp`](blinky-breakout/src/blinky-breakout.sexp)
and follow along. Everything in the language is a parenthesised form: a head
word and its arguments. `;` starts a comment.

### Imports, and where parts come from

```scheme
(import ldo-3v3-sot23-5
        hex-inverter-schmitt
        pin-header-1x2
        pin-header-2x5
        testpoint
        mounting-hole-m2)
```

Each name is looked up as `lib/components/<name>.sexp`, then
`lib/modules/<name>.sexp`, in this order:

1. **this project's `lib/`** — `examples/blinky-breakout/lib/`
2. a shared library, if you pass `--lib-dir <dir>` or set `NETLISP_LIB_DIR`
3. the **standard library compiled into the binary**

First hit wins, per file. So `ldo-3v3-sot23-5` and `hex-inverter-schmitt` come
from this project (the bundle has no ICs), while `pin-header-1x2`,
`pin-header-2x5`, `testpoint` and `mounting-hole-m2` come from the binary.

The passive families — `cap-0603`, `res-0603`, `cap-0805`, `led-0402` and
their siblings — are **not imported at all**: the evaluator loads all sixteen
of them into every design automatically. See
[docs/standard-library.md](../docs/standard-library.md) for the full list and
for how `NETLISP_STDLIB_DIR` replaces the bundle wholesale.

### The physical board

```scheme
(board
  (size 46.0 30.0)
  (left "J1")
  (right "J2")
  (corners "H1" "H2" "H3" "H4"))

(stackup 2
  (pour bottom "GND"))
```

`(board …)` is the outline in millimetres plus the parts pinned to it:
`left`/`right`/`top`/`bottom` dock a part flush inside that physical edge, and
`corners` pins mounting hardware to the four corners in the order TL, TR, BR,
BL. `(stackup 2 (pour bottom "GND"))` says two copper layers with a ground
pour on the bottom, which is why almost no ground is routed as traces later.

### Design maths

```scheme
(let v-rail  3.3)
(let v-led   2.0)
(let r-led   270R)
(let i-led   (/ (- v-rail v-led) r-led))
(let r-osc   470k)
(let c-osc   1uF)
(let t-blink (* 0.8 (* r-osc c-osc)))
(let f-blink (/ 1.0 t-blink))
```

`let` binds a name in the current scope. Arithmetic is prefix (`(/ a b)`), and
numeric literals take SI suffixes: `470k` is 470000, `1uF` is 1e-6, `270R` is
270. A scale-free unit letter (`V`, `A`, `F`, `H`, `R`) is allowed on the end
and carries no meaning of its own — it is there so the source reads like a
schematic.

These bindings are then used as values:

```scheme
(instance "R2" (res-0603 (fmt "~R" r-osc)) …)
```

`(fmt "template" args…)` formats engineering units: `~R` resistance
(`470000` → `470k`), `~C` capacitance (`1e-6` → `1uF`), `~V` volts, `~A` amps,
`~a` any value. R2's *value* is therefore computed, not typed — change
`r-osc` and the part, the BOM, the note and the blink rate all move together.

### Assertions

```scheme
(assert (> (- v-in v-rail) 0.5)
  "LDO input-to-output headroom must exceed the regulator's dropout voltage")
(assert-range (* i-led 1000.0) 2.0 10.0 "LED current (mA)")
(assert-range f-blink 0.5 5.0 "Blink rate (Hz)")
```

Assertions never interrupt *evaluation*: the design is evaluated to the end
and every assertion is recorded, so one run tells you about all of them rather
than stopping at the first. They then surface in `netlisp build`, in `netlisp
check` and in the review PDF — and a failing one makes those commands exit
non-zero, so nothing quietly ships a board whose own arithmetic disagrees with
it. Change `r-led` to `27R` and rebuild:

```text
PASS: LDO input-to-output headroom must exceed the regulator's dropout voltage
FAIL: LED current (mA) = 48.1481 (range 2.0-10.0)
PASS: Blink rate (Hz) = 2.6596 (range 0.5-5.0)
Build failed: assertion violations
```

### The board boundary

```scheme
(port "VIN" "VIN_5V" in   power 5.0 (rated 4.5 5.5) (current 0.02 0.15))
(port "GND"           bidi power)
(port "3V3" "+3V3"    out  power 3.3 (rated 3.2 3.4))
```

A port is a signal crossing the block boundary: a display name, optionally the
net it maps to, a direction, and modifiers. `(rated …)` is the voltage window
the checks hold the net to; `(current …)` says how much this board draws, which
is what lets the power-budget check compare source against load.

### Sections

A section is a functional subdivision. It positions its parts on the schematic
grid, names a cluster in the block diagram, and is the unit the review report
walks:

```scheme
(section "3V3 LDO Regulator" "Generic SOT-23-5 LDO, 5 V in, 3.3 V out"
  (row 0) (col 1)
  (description "Makes the 3.3 V rail the logic runs from, …")
  (instance "U1" ldo-3v3-sot23-5 …))
```

The name is matched against a keyword table to colour the block diagram
(`LDO`, `Regulator`, `Oscillator`, `Header`, `Mounting` all match something) —
so name sections after what they do. The subtitle and `(description …)` are
prose; keep the description under 100 characters or the build says so.

`(diagram hidden)` drops a section from the block diagram without hiding it
anywhere else — used here for the test points and the mounting holes.

### Instances and pins

```scheme
(instance "U1" ldo-3v3-sot23-5
  (pin VIN  "VIN_5V" (i-typ 0.012) (i-max 0.15))
  (pin GND  "GND")
  (pin EN   "EN")
  (pin VOUT "+3V3"   (i-typ 0.012) (i-max 0.15))
  (nc-ok NC "Pin 4 has no internal connection on this outline; left open deliberately.")
  (note (fmt "Headroom is ~V - ~V = ~V, …" v-in v-rail (- v-in v-rail))))
```

* **A net is created by naming it.** There is no wire object: two pins on the
  string `"VIN_5V"` are connected, and that is the whole model.
* **Pins are named, not numbered.** `VIN` is a function name from
  `lib/pinouts/ldo-3v3-sot23-5.sexp`; a bare pad number works too. One trap:
  a pin name that starts with a digit must be **quoted**, because `1A` parses
  as the number 1 with the unit letter `A`. That is why the inverter's gates
  are written `(pin "1A" …)` and its supply is written `(pin VCC …)`.
* `(i-typ …)` / `(i-max …)` state what the pin draws and what it is rated for.
  They feed the power budget and the PCB's copper-width solver.
* `(nc-ok …)` signs off a deliberately unconnected pad, satisfying the ERC rule
  that would otherwise flag it. `(strap-ok …)` does the same for a pin tied
  straight to a rail.
* `(note …)` attaches prose to the part; it renders in the schematic sidebar
  and the review PDF. Notes take an expression, so they can carry the same
  computed numbers the parts do.

Two more instance modifiers appear on this board:

```scheme
(instance "C1" (cap-0603 "1uF") (pin 1 "VIN_5V") (pin 2 "GND") (near "U1" VIN) …)
(instance "C3" (cap-0603 "100nF") (pin 1 "+3V3") (pin 2 "GND") (decouples "U2" VCC) …)
```

`(near "REF" PAD)` asks the placer to keep this part against that pad.
`(decouples "REF" PAD)` records *which supply pad* a bypass capacitor serves —
a real requirement, not a hint: a hand-named high-frequency decoupling cap on a
rail that lands on two or more of an IC's supply pads is an ERC **error**
without it. (The two are mutually exclusive intents; `decouples` already
implies the placement.)

### One IC, several sections

`U2` is declared in the oscillator section with the four pins that oscillate
and buffer. Its remaining gates belong to the expansion header, so that
section wires them without re-declaring the part:

```scheme
(pins "U2"
  (pin "3A" "EXP_3A")
  (pin "3Y" "EXP_3Y")
  …)
```

The schematic draws U2 twice — once per section, each box carrying only that
section's pins — while the netlist has one part.

### Test points

```scheme
(test-point "TP1" "+3V3" (purpose "Regulated 3.3 V rail — check this first."))
```

One line places a real pad from the standard library, wires it, attaches the
purpose as a note, and records the point in the design's bring-up list.

## 3. Check it

```bash
zig build run -- check --project-dir examples/blinky-breakout blinky-breakout
```

`check` runs the assertions, the electrical rule checks (floating nets,
unconnected pins, duplicate ref-deses, voltage mismatches, decoupling
bindings), the executable component requirements, and the datasheet-review
gate. The default `authoring` profile reports three findings and exits 0:

```text
info      power_budget      [+3V3] — Rail "+3V3" has 0.018A typ load but no regulator declares (current …) on its output
warning   datasheet_review  U1 — active component has no (datasheet-review ...) record
warning   datasheet_review  U2 — active component has no (datasheet-review ...) record
```

`--profile preflight` turns the open ones into errors and exits 1:

```bash
zig build run -- check --project-dir examples/blinky-breakout --profile preflight blinky-breakout
```

**All three are expected, and each is worth understanding.**

* The two `datasheet_review` errors are the tool refusing to call a board
  release-ready when an active semiconductor has no reviewed datasheet. This
  example ships *generic* parts on purpose — a package-standard LDO and a
  package-standard logic gate, with no manufacturer named and no vendor PDF
  shipped — so there is nothing to review and the finding correctly stands.
  On a real board you close it by choosing a part, fetching its datasheet
  (`netlisp tool fetch_datasheet`), and recording a
  `(datasheet-review …)` on the component.
* The `power_budget` info says nothing on the board declares how much current
  the regulator can *supply* — only ports carry a `(current …)` capacity, and
  U1 is an instance rather than a sub-block with ports. Wrap the regulator in
  a `(defmodule …)` with an output port and the rail gets a source.

Everything else the profile demands is already closed, and the *how* is worth
copying. The component files in `lib/components/` carry executable
requirements:

```scheme
(requirement "At least 1 uF of ceramic capacitance sits across VIN and GND."
  (check (decoupling (pin "VIN") (pin "GND") (min-uf 1.0))))
```

`(check …)` clauses are run against the real netlist on every build, so the
part's obligations are verified rather than asserted. On a real part each one
would also carry `(ref "part.pdf" (page 7) (quote "…"))`, and the citation
travels with the claim into the review report.

## 4. Look at it

```bash
zig build run -- serve --project-dir examples/blinky-breakout
```

Then open <http://127.0.0.1:7050>. The server binds loopback and treats a
local request as an admin, so there is nothing to configure. Useful pages:

| Page | What it shows |
| --- | --- |
| `/` | every design in the project |
| `/schematics/blinky-breakout` | the schematic: block diagram, per-section hub-and-spoke SVG, notes, checks |
| `/pcb-layout/blinky-breakout` | the board: placement, copper, pours, DRC, the routing controls |
| `/review/blinky-breakout` | the design-review surface |

The browser is a viewer and a review surface, not a capture tool: the `.sexp`
file is the design, and the page re-renders when it changes.

Serving or laying out a project makes the tool write runtime state beside it —
`logs/` for the interaction log, `history/` for layout snapshots. Both are
git-ignored here; the tracked example is `src/` and `lib/` only.

## 5. Lay it out and route it

The board that ships with this example is already placed and routed: its
copper lives in `src/blinky-breakout.layouts.json`, so the PCB page and the
PNG renderer show a finished board the moment you clone. Twenty parts, 121
track segments, 25 vias, all sixteen nets routed, no DRC errors.

Here is how that layout was made — every step is a structured tool, and the
same calls work from an agent, a script or the browser.

```bash
P="--project-dir examples/blinky-breakout"

# 1. Draw the board edge. (The (board (size …)) form declares the same
#    rectangle; this is what writes it into the layout sidecar.)
zig build run -- tool set_board_outline $P \
  --args '{"name":"blinky-breakout","rect":{"x":0,"y":0,"w":46,"h":30}}'

# 2. Place parts, in board millimetres with y growing DOWN. The coordinate is
#    the footprint's own origin: for a symmetric chip land that is its centre,
#    for a pin header it is pad 1.
zig build run -- tool set_part_poses $P \
  --args '{"name":"blinky-breakout","poses":[{"ref":"U2","x_mm":25.0,"y_mm":17.0},
                                             {"ref":"C3","x_mm":31.0,"y_mm":13.2}]}'

# 3. Autoroute everything at the design's resolved rules.
zig build run -- tool route_pcb $P --args '{"name":"blinky-breakout"}'

# 4. Fold any implicit trace crossings into real junctions.
zig build run -- tool normalize_junctions $P --args '{"name":"blinky-breakout"}'

# 5. Save the working state as a named, starred layout.
zig build run -- tool save_pcb_layout $P \
  --args '{"name":"blinky-breakout","layout_name":"routed","star":true}'
```

`route_pcb` answers with what it did:

```json
{"routed":16,"total":16,"drc_errors":0,"drc_warnings":6,
 "tracks":120,"vias":25,"trace_mm":235.4,"unrouted":[]}
```

To see the result without a browser, ask for the picture or the facts:

```bash
zig build run -- tool get_pcb_layout_image $P \
  --args '{"name":"blinky-breakout","route":true,"width":1200,"names":"ref"}' \
  --output board.png

zig build run -- tool describe_pcb_layout $P --args '{"name":"blinky-breakout"}'
```

The image and the facts are built from the identical placement, so they can
never disagree; `describe_pcb_layout` reports every part's pose, its side of
the anchor IC, its courtyard gap, and each decoupling loop's inductance.

### The design-rule check

```bash
zig build run -- tool run_fab_readiness $P --args '{"name":"blinky-breakout"}'
```

That is the full manufacturing gate: it re-runs DRC over the persisted copper
and reports every other release obligation as well. On this board it finds
**no DRC errors and six warnings**, which the gate itself labels
"assembly-hygiene advisories; they don't block the fab package":

* 5 × `land_transit` — a same-net trace laps the far edge of its own pad
  instead of entering through it. Cosmetic at this pitch. The
  `repair_land_transit` tool re-anchors such segments; on this board it trades
  the five for a larger crop of short stubs, so the committed layout keeps
  them as they are.
* 1 × `dangling_copper` — a short stub left behind after the junction
  normalisation.

`run_fab_readiness` also refuses to issue a release token for this board, and
it is right to: nothing here has a manufacturer part number, there is no
`(revision …)`, and the two datasheet reviews are open. Fabrication is gated
on choices this example deliberately does not make for you.

## 6. Hand it to KiCad

```bash
zig build run -- export-kicad --project-dir examples/blinky-breakout \
    --output-dir ~/blinky-kicad --with-schematic blinky-breakout
```

That directory opens as a complete KiCad project: `blinky-breakout.kicad_pro`,
a `.kicad_sch` hierarchy, the netlist, a `footprints.pretty/` library holding
every land pattern this design uses — the two written here *and* the bundled
ones — plus `sym-lib-table` / `fp-lib-table` wired up. Drop it on a machine
with KiCad 8 and open the project.

For a review document instead:

```bash
zig build run -- export-pdf --project-dir examples/blinky-breakout blinky-breakout \
    --output ~/blinky-breakout.pdf
```

Eight pages: cover, per-section schematics, the validation table with every
assertion and check, and the power table.

The schematic stays canonical after the export. When you have a board in
KiCad, declare `(kicad-pcb "<path>")` in the design and **Push to KiCad PCB**
on the schematic page diffs the board against the netlist and rewrites it in
place, preserving placements and pad nets; `import-kicad-layout` brings a
routed board back the other way.

## 7. Driving it from an agent

Every operation above is a structured tool with a JSON schema, and none of
them need the server:

```bash
zig build run -- tool list                       # names, descriptions, schemas
zig build run -- tool run_checks --project-dir examples/blinky-breakout \
    --args '{"name":"blinky-breakout","profile":"preflight"}'
```

Read-only tools an agent reaches for first: `list_designs`, `list_instances`,
`get_net`, `list_free_pins`, `describe_component`, `get_schematic`,
`run_checks`, `describe_pcb_layout`, `get_pcb_layout_image`, `diagnose_net`,
`get_language_reference`. Mutating ones: `write_file` / `edit_file` for the
source, `build`, then the layout tools used above. Use `--args-file req.json`
for a large request, and `--output` to write an image or a text result to a
file instead of stdout.

`zig build run -- reference [section]` prints the language grammar out of the
binary itself — the same content as
[docs/language-forms.md](../docs/language-forms.md), which is generated from
the evaluator's dispatch tables and therefore cannot drift from what the
parser accepts.

## 8. What is in this project's `lib/`

```text
blinky-breakout/lib/
  components/ldo-3v3-sot23-5.sexp     a part the standard library does not have
  components/hex-inverter-schmitt.sexp
  pinouts/ldo-3v3-sot23-5.sexp        pad number → function name
  pinouts/hex-inverter-schmitt.sexp
  footprints/sot23-5.sexp             land patterns for those two packages
  footprints/soic-14.sexp
  footprints/testpoint-1mm.sexp       ← an OVERRIDE of a bundled footprint
```

The first six files are the **extension** path: the bundle ships passives,
headers, test points and mounting holes, and everything else is yours to add.
A component names a pinout and a footprint; the pinout maps pad numbers to
function names, which is what lets the design say `(pin VOUT …)`.

`footprints/testpoint-1mm.sexp` is the **override** path. The standard library
already has a footprint by that name — a 1 mm probe pad — but this board is
brought up with a sprung hook clip, so the project ships its own 1.5 mm land.
Because the file name matches, this copy wins for this project and nothing
else changes: the `testpoint` *component* and its pinout still come from the
binary. Delete the file and the bundled 1 mm pad comes back on the next build.
Shadowing is per name, not wholesale.

Everything in this directory is written for this repository. The two land
patterns are computed from the IPC-7351B density-level-B equations over each
package's published JEDEC dimensions (MO-178 for the SOT-23-5, MS-012 AB for
the SOIC-14), and each file's header states the dimensions, the fillet goals,
the allowances, the equations and the arithmetic, so every number can be
re-derived rather than trusted. No manufacturer is named, no datasheet is
shipped, and the two ICs are generic package-standard parts rather than
anyone's product.

## 9. Make it yours

Small changes with visible consequences:

* **Blink faster.** Change `(let r-osc 470k)` to `330k` and rebuild. R2's
  value, its note, the section subtitle's story and the `Blink rate (Hz)`
  assertion all follow from that one number.
* **Break something on purpose.** Set `(let r-led 27R)` and watch the LED
  current assertion fail — every other assertion still reports, because
  evaluation runs to the end before the command exits non-zero.
* **Add a part.** Copy a `lib/components/*.sexp` file, give it a pinout and a
  footprint, `(import …)` it, and place an `(instance …)`.
* **Shadow a bundled part.** Drop your own `lib/components/cap-0603.sexp` into
  the project and every 0603 capacitor uses it — and only that name changes.
* **Re-place a part and re-route.** `set_part_poses`, then `route_pcb`, then
  `get_pcb_layout_image`. Moving a part drops the persisted copper on its
  nets, so the board never shows stale traces.

Where to read next:

* [docs/sexp-language.md](../docs/sexp-language.md) — the language, form by form
* [docs/language-forms.md](../docs/language-forms.md) — the generated grammar reference
* [docs/standard-library.md](../docs/standard-library.md) — what is bundled and how overrides resolve
* [docs/webserver-api.md](../docs/webserver-api.md) — every HTTP route and structured tool
* [docs/architecture.md](../docs/architecture.md) — how the pipeline fits together
