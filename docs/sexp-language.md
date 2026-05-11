# S-Expression Language Reference

The schematic capture language. Every form a `.sexp` file may contain, with a one-line description and a minimal example.

This is the *user-facing* reference — language-agnostic, no implementation details. For the architecture and pipeline that consumes these files, see [`architecture.md`](architecture.md).

---

## 1. Lexical & evaluation model

### Tokens

- **Atoms** — bareword identifiers like `res-0402`, `stm32n657l0h3q`, `~{CS}`. Start with a letter / `_` / `~` / `*`; continue with letters, digits, `-`, `/`, `.`, `#`, `@`, `:`. Operators (`+ - * / % > >= < <= == !=`) are also atoms.
- **Numbers** — `42` (integer), `3.3` (float; the decimal point is mandatory in source for a float), `1.0mm` / `10mil` (unit-valued; converted to millimetres internally).
- **Strings** — double-quoted: `"VDD"`, `"100nF"`, `"VOUT must be in [0.6, 16.0]"`. Newlines inside a string are illegal. `\` escapes the next byte (no special escape interpretation).
- **Lists** — `( … )`. The first element is the form head; remaining elements are arguments. There is no quoting / unquoting.
- **Comments** — `;` and `;;` start a line comment. No block comments.

### Evaluation

- Special forms (`let`, `if`, `cond`, `fmt`, `assert`, `assert-range`, `import`, `defmodule`, `design-block`) take un-evaluated arguments and decide what to evaluate themselves.
- Everything else evaluates eagerly, left-to-right.
- Lexical scoping. `let` introduces a binding in the current environment that shadows any outer binding of the same name. Modules close over the environment in which they were defined.
- Errors carry a source span (line + column + byte offset) so the build report points at the offending form.
- **Assertions never abort the build.** `(assert …)` and `(assert-range …)` accumulate pass/fail entries that surface in the design-review report. A failing assertion is a finding, not a stop.

### Stable IDs

Every `instance`, `series`, and `decouple` form gets either an explicit `(id <hex8>)` marker or a freshly generated 8-char hex one. Generated IDs are flushed back to the source file on the next build, so:

- the IDs are stable across renames, ref-des reshuffles, and module re-parameterisation; and
- BOM / PCB linkage survives those edits.

The first character of an auto-generated ID is always one of `a`–`f` so it never collides with a numeric literal.

---

## 2. Special forms

### `(let name expr)`

Bind `name` to the evaluated value of `expr` in the current scope. Returns nil — `let` is a side-effecting binder, not a value-producing form.

```scheme
(let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
(let vout-str (fmt "~V" vout))
```

### `(if cond then else)`

Short-circuited conditional. Only the matching branch evaluates.

```scheme
(if (> vout 5.0) "high" "low")
```

### `(cond (test1 expr1) … (else exprN))`

Multi-way conditional. Walks each clause in order, returning the value of the first expression whose test is truthy. The literal `else` keyword on a clause head matches unconditionally.

```scheme
(cond
  ((> vout 5.0)  "high-voltage rail")
  ((> vout 3.0)  "logic rail")
  (else          "low-voltage rail"))
```

### `(fmt "template" args…)`

Format a string using engineering-unit directives. See §4 for the directive table.

```scheme
(fmt "~V Buck (~R / ~R)" vout rfbt rfbb)
;; → "3.3V Buck (220k / 47k)"
```

### `(assert cond "message")`

Record a pass/fail entry on the evaluator's assertions list. Surfaced in the review report. **Does not abort the build** on failure.

```scheme
(assert (> vout 0.5) "VOUT below 0.5V is unsafe")
```

### `(assert-range value lo hi "label")`

Record an assertion with a formatted message like `VOUT = 3.3000 (range 0.6-16.0)`.

```scheme
(assert-range vout 0.6 16.0 "VOUT")
(assert-range led-current 0.0 0.01 "LED current")
```

### `(id <hex8>)`

Marker carrying a stable 8-char hex identity. You don't write this by hand — the build inserts one on every `instance`, `series`, and `decouple` that doesn't have one. You only need to know it exists and not delete it.

```scheme
(instance "C1" (cap-0402 "100nF") (id ab12cd34)
  (pin 1 "VDD")
  (pin 2 "GND"))
```

---

## 3. Builtin functions

All builtins are binary except `not` (unary). Numbers are doubles internally; `==` and `!=` also work on strings.

| Category | Builtins |
| --- | --- |
| Arithmetic | `+ - * / %` |
| Comparison | `> >= < <=` |
| Equality | `== !=` (numbers or strings) |
| Logic | `and or not` |

```scheme
(+ 1 2)             ; → 3
(* 0.6 (+ 1.0 (/ 220000 47000)))   ; voltage divider
(> vout 5.0)        ; → true / false
(and (> v 0.6) (< v 16.0))
(== "x7r" dielectric)
```

Division and modulo by zero are errors.

---

## 4. Format directives

Used inside `(fmt "template" args…)`. Each directive consumes one argument, in order.

| Directive | Input | Output |
| --- | --- | --- |
| `~V` | number (volts) | `3.3V`, `0.95V`, `12V` |
| `~R` | number (ohms) | `47`, `4.7k`, `220k`, `2.2M` |
| `~C` | number (farads) | `100nF`, `22uF`, `10pF`, `1mF` |
| `~A` | number (amps) | `5mA`, `2A`, `100uA` |
| `~S` | string | the string as-is |
| `~~` | (none) | a literal `~` |

The capacitance / resistance / current scalers pick the SI prefix that gives a small, readable mantissa.

```scheme
(fmt "RFBT = ~R, VOUT = ~V, IF = ~A" 220000 3.3 0.005)
;; → "RFBT = 220k, VOUT = 3.3V, IF = 5mA"
```

---

## 5. Top-level design constructs

### `(import name…)`

Bring library components and modules into scope. Each name resolves as `lib/components/<name>.sexp` then `lib/modules/<name>.sexp`. Re-importing an already-loaded name is a no-op.

```scheme
(import stm32n657l0h3q
        cap cap-0201 cap-0402 cap-0603 cap-0805
        res res-0402
        ind ind-1616 ferrite-0402
        led
        tpsm84338 lt3045)
```

### `(defmodule name (params…) "doc?" body…)`

Define a parameterised module. Its body evaluates with the given parameters bound; calling `(name args…)` later evaluates the body in that scope. Modules close over the environment in which they were defined.

```scheme
(defmodule tpsm84338 (rfbt rfbb rled)
  "3A Buck Converter with Power Good LED."
  (let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
  (assert-range vout 0.6 16.0 "VOUT")
  (design-block (fmt "~V Buck" vout)
    …))
```

A module typically returns a `design-block`, but it can return any value.

### `(design-block "name" body…)`

The top-level container. Evaluates its body, accumulating instances, ports, nets, sections, and sub-blocks into a single design block. The name is rendered in the schematic header.

```scheme
(design-block "STM32N6 Minimal Schematic"
  (instance "U1" stm32n657l0h3q …)
  (section "VDD Power" …)
  (port "VDD" "VDD" in (rated 3.0 3.6))
  (port "GND" "GND" bidi))
```

### `(instance "REF-DES" component-or-family pin-forms…)`

Place a component. The first argument is the ref-des (auto-assigned by prefix if you pass `""`); the second is either a bare component name or a component-family invocation; the rest are pin-to-net connections and modifiers (see §6).

```scheme
(instance "C1" (cap-0402 "100nF")
  (pin 1 "VDD")
  (pin 2 "GND"))

(instance "U1" stm32n657l0h3q
  (pin 1 2 3 4 5 "VDD")
  (pin 27 28 29 30 31 "GND"))
```

### `(port "name" [net-name] direction [signal-type…] [voltage] [rated])`

Declare an external port on a design block. The rendered name is `"name"`. If you provide a separate `net-name`, the port maps that name → net (used when the displayed name differs from the underlying net). See §7 for modifiers.

```scheme
(port "VDD"  "VDD"  in   (rated 3.0 3.6))
(port "GND"  "GND"  bidi)
(port "VOUT" vout-str  out  (rated 0.6 16.0))
```

### `(net "alias-a" "alias-b" …)`

Tie two or more net names together. Used to merge nets that came in under different names (e.g. across sub-blocks).

```scheme
(net "VBUS" "USB_5V")
```

### `(note "REF-DES" "text")`

Attach a free-form note to a ref-des. Renders in the schematic sidebar.

```scheme
(note "U1" "TPSM84338RCJR: 3.8-28V, 3A synchronous buck.")
(note "R4" (fmt "RFBT = ~R; VOUT = 0.6V × (1 + ~R/~R) = ~V."
                rfbt rfbt rfbb vout))
```

### `(group "name" ("REF1" "REF2" …))`

Visual grouping in the schematic — labels a cluster of related parts.

```scheme
(group "Power Good Indicator" ("Q1" "D1" "R9"))
(group "Input Decoupling"     ("C1" "C2" "C3" "C8"))
```

### `(section "name" ["subtitle"] [(row N)] [(col N)] body…)`

Group circuitry into a named, grid-positioned subdivision. Sections drive both the schematic layout and the auto-classified system-overview SVG in the page header (see §8).

A section's body can contain `(status …)`, `(description …)`, `(role …)`, `(protocol …)`, `(calc …)`, `(note …)`, `(port …)`, `(instance …)`, `(pins …)`, `(decouple …)`, `(series …)`, `(net …)`, and nested `(section …)`.

```scheme
(section "3.3V Buck" "TPSM84338, 12V→3.3V, 2A"
  (row 0) (col 1)
  (status implemented)
  (description "Main 3.3V rail for MCU + peripherals.")
  (sub-block "buck" (tpsm84338 220000 47000 1000)))
```

Section status values: `concept`, `design`, `implemented`, `review`. The ERC `concept_remaining` check flags any section still marked `concept`.

### `(sub-block "prefix" expr)`

Instantiate a module or compose another design block as a child. The prefix is prepended to the child's ref-deses. The expression is typically a module call.

```scheme
(sub-block "buck" (tpsm84338 220000 47000 1000))
(sub-block "ldo"  (lt3045    60000 300))
```

### `(series "REF-DES" component net-a net-b)`

Two-pin component placed between two nets (pin 1 = net-a, pin 2 = net-b).

```scheme
(series "R4" (res "33R") "SWDIO_MCU" "SWDIO")
```

### `(decouple …)`

Auto-generate decoupling capacitors with per-pin sub-nets so each cap routes close to its target IC pin. Three shapes:

```scheme
;; 1) one cap value across one net for all of U1's pins on it
(decouple "VDDA18PMU" (cap "100nF") U1)

;; 2) bulk + bypass groups on one net
(decouple "VDDSMPS"
  (bulk   (cap "10uF") U1)
  (bypass (cap "1uF") U1 (cap "100nF") U1))

;; 3) one cap value across multiple nets (auto-numbered ref-deses)
(decouple (cap "100nF") U1
  "VDDA18PLL" "VDDA18USB" "VDDA18ADC" "VDDIO2" "VDDIO3")
```

A specific pin can be targeted: `(decouple "VDDCORE" (cap "1uF") U1 W6)`.

### `(verifies …)`

Section-level rationale for design checks — used to record sign-offs and ERC exceptions.

```scheme
(verifies
  (req "VDD-decoupling-100nF-per-pin")
  (rationale "Single 100nF located within 1 mm of pin J14.")
  (signed-off-by "EP" (date 2026-04-15)))
```

### `(component …)` / `(component-family …)`

Library forms. A `component` is a fixed part (`tpsm84338rcjr`, `res-0402`); a `component-family` is a parameterised template that takes a value string (`(cap "100nF")`, `(res "10k")`). Both live in `lib/components/`. Their bodies declare the symbol, footprint, properties, datasheet, and (optionally) requirements.

These are *defined* in library files and *used* in designs — you don't write them inline in a design.

### `(connect "FN" "NET")` and `(pin … as "FN" …)`

Inside an instance, `(connect "FN" "NET")` binds a net to a pin by *function name* (e.g. `"SDIO_D0"`) instead of pin number, looking the function up in the component's pinout. `(as "FN1" "FN2")` inside a `(pin …)` form asserts which alternate functions the pin is being used for — checked against the pinout's alternate-function table by the `pin_function_*` ERC checks.

---

## 6. Instance modifiers

Forms allowed inside an `(instance …)` body.

### `(pin <pin-id…> "NET")`

Connect one or more pins to a net. Pin IDs can be bare atoms (`CC1`, `GND_A`), numbers (`1`, `27`), or quoted strings (`"D1+"`, `"~{CS}"`).

```scheme
(pin 1 "VDD")                            ; one pin
(pin 1 2 3 4 5 "VDD")                    ; multi-pin shorthand
(pin "D1+" "D2+" "USB_DP_CONN")          ; mixed quoted
```

### `(connect "FUNCTION" "NET")`

Connect by pinout function name (e.g. `"SDIO_D0"`) instead of pin number. Resolved via the component's `lib/pinouts/<name>.sexp`.

### `(part "name" [(row N)] [(col N)] body…)`

Multi-part symbol grouping. A single instance can spread across multiple grid cells, each with its own pin set. Each `part` block owns its `(row …) (col …) (pin …) (connect …)` forms.

```scheme
(instance "U1" stm32n657l0h3q
  (part "VDD Power" (row 0) (col 0)
    (pin 1 2 3 4 5 "VDD")
    (pin 27 28 29 30 31 "GND"))
  (part "USB" (row 3) (col 1)
    (pin 52 "USB_DP")
    (pin 53 "USB_DM")))
```

### `(row N)` / `(col N)`

Grid placement on a hub instance (when not split into `part` blocks).

```scheme
(instance "J2" amphenol-10164986
  (row 3) (col 1)
  (pin 1 12 13 24 "GND")
  (pin 4 9 16 21 "VBUS"))
```

### `(bus "PREFIX" pin1 pin2 …)`

Inside a `(pins "REF" …)` block, expand to sequentially numbered nets sharing a prefix.

```scheme
(pins "U1"
  (bus "FLASH_IO" T19 P19 V19 U18 V18 T18 R18 P18))
;; Expands to (pin T19 "FLASH_IO0") (pin P19 "FLASH_IO1") … (pin P18 "FLASH_IO7")
```

### `(pins "REF" …)`

Inside a section, distribute pin assignments for an already-instantiated component across multiple sections. The first arg is the target ref-des; the body holds `(pin …)` and `(bus …)` forms.

```scheme
(section "VDD Power"
  (pins "U1"
    (pin J14 K14 L14 "VDD")
    (pin A19 F12 H14 "GND")))
```

### Pin annotations

Inside a `(pin …)` form:

- `(i-typ X)` — typical current the instance draws on this pin (amps).
- `(i-max Y)` — maximum current the pin is rated for (amps).
- `(as "FN1" "FN2" …)` — assert the alternate functions the pin is being used for (verified by the `pin_function_*` ERC checks).

```scheme
(pin 4 "VOUT" (i-typ 0.5) (i-max 1.5))
(pin 12 "I2C_SDA" (as "I2C2_SDA"))
```

### `(note "text")`

A free-form note attached to this instance (rendered in the schematic sidebar).

### Free-form properties

Any unrecognised list inside an instance becomes a key-value property. Useful for pass-through metadata like `(mpn "TI-TPSM84338RCJR")` or `(supplier-stock 1240)`.

---

## 7. Port modifiers

A port form takes positional args followed by modifier keywords / forms.

| Modifier | Effect |
| --- | --- |
| `in` / `out` / `io` / `bidi` | Direction. |
| `power` | Tag as a power port. |
| `signal` | Tag as a signal port (default-ish). |
| `clock` | Tag as a clock port. |
| `data` | Tag as a data port. |
| `differential` | Tag as differential. |
| `optional` | Port is not required on all placements. |
| numeric arg | Nominal voltage in volts (`3.3`, `12.0`). |
| `(rated min max)` | Voltage range, in volts. |
| `(role <name>)` | Semantic role (e.g. `clk`, `reset`). |
| `(protocol <name>)` | Electrical protocol (`i2c`, `uart`, `usb-hs`, …). |

```scheme
(port "VDD"  "VDD"  in    power 3.3 (rated 3.0 3.6))
(port "GND"  "GND"  bidi  power)
(port "SCL"  "SCL"  bidi  signal (protocol i2c))
(port "USB_DP" "USB_DP" bidi (protocol usb-hs) differential)
```

The form is order-tolerant for modifiers; positional args (name, optional net-name, direction) come first.

---

## 8. Section conventions

Sections are how you tell the renderer the shape of the design. The system-overview SVG (the strip at the top of every schematic page) classifies each section by its **name keyword** and assigns it a column + colour. The classifier is case-insensitive substring matching against this table:

| Category | Keywords |
| --- | --- |
| **mcu** | `MCU`, `SoC`, `CPU`, `Core System`, `STM32`, `ESP32`, `nRF`, `Microcontroller` |
| **power** | `Buck`, `LDO`, `Regulator`, `Power`, `Charger`, `Converter`, `PMIC` |
| **memory** | `Flash`, `PSRAM`, `RAM`, `EEPROM`, `SD Card` |
| **clock** | `Clock`, `HSE`, `LSE`, `Oscillator`, `PLL`, `Crystal` |
| **comms** | `USB`, `Ethernet`, `BLE`, `WiFi`, `CAN`, `UART` |
| **sensor** | `IMU`, `ADC`, `Sensor`, `Temperature`, `Accelerometer`, `Gyro` |
| **analog** | `Analog`, `DAC`, `Op-Amp`, `Reference`, `Amplifier` |
| **protection** | `ESD`, `Protection`, `Fuse`, `TVS` |
| **connector** | `Connector`, `Expansion`, `Header`, `Mounting`, `SWD`, `Debug`, `RJ45`, `B2B` |
| **peripheral** (default) | none — fallback when nothing matches |

If no keyword matches and the section's first instance has a ref-des starting with `J` or `P`, it falls into **connector**.

**Naming convention.** 1–4 words, capitalised, functional role first. Pick a name that contains at least one classifier keyword.

**Subtitle.** A one-line technical caption — part number + key spec, e.g. `"TPSM84338, 12V→3.3V, 2A"`. Surfaces under the chip in the system-overview SVG.

**Grid placement.** Convention used in the existing designs:
- Column 0 — MCU / core.
- Column 1 — peripherals + buses + power rails.
- Rightmost column — connectors / debug / bring-up.

For designs that are mostly `(sub-block …)` calls, you can omit top-level `(section …)` declarations — the system-overview SVG synthesises a per-design chip from the design-block name.

---

## 9. Module composition patterns

### Parameterised design with validation

```scheme
(defmodule tpsm84338 (rfbt rfbb rled)
  "3A Buck Converter with Power Good LED."

  (let vout         (* 0.6 (+ 1.0 (/ rfbt rfbb))))
  (let led-current  (/ (- vout 2.8) rled))
  (let vout-str     (fmt "~V" vout))

  (assert-range vout 0.6 16.0 "VOUT")
  (assert-range led-current 0.0 0.01 "LED current")

  (design-block (fmt "~V Buck (TPSM84338)" vout)
    (instance "U1" tpsm84338rcjr
      (pin 4 vout-str)
      …)
    (port "VOUT" vout-str out (rated 0.6 16.0))))
```

The `let` bindings compute all derived values up front; `assert-range` records pass/fail entries; the design-block name is itself derived (`"3.3V Buck (TPSM84338)"`).

### Composing sub-blocks

```scheme
(import tpsm84338 lt3045)

(design-block "6V Low-Noise Power Supply"
  (sub-block "buck" (tpsm84338 320000 30000 820))
  (sub-block "ldo"  (lt3045    60000 300)))
```

The first `sub-block` arg is a ref-des prefix — `buck.U1`, `buck.R4`, `ldo.U1`, etc. The second arg is a module call with concrete parameter values.

### Closure capture

A module body sees the environment in which it was defined, so library-level `(let …)` bindings are visible to module bodies declared in the same file. This is mostly transparent — you'll notice it only if you start defining helpers at the top of a module file.

---

## 10. Worked example — minimal MCU board

```scheme
(import my-mcu cap res led)

(design-block "Minimal MCU Board"

  (instance "U1" my-mcu)

  (section "Power" (col 0) (row 0)
    (status implemented)
    (pins "U1"
      (pin 1 2 3 "VDD")
      (pin 10 11 12 "GND"))
    (decouple (cap "100nF") U1 "VDD"))

  (section "Clock" (col 0) (row 1)
    (pins "U1"
      (pin 4 "OSC_IN")
      (pin 5 "OSC_OUT"))
    (instance "X1" abm8
      (pin 1 "OSC_IN")
      (pin 2 "GND")
      (pin 3 "OSC_OUT")
      (pin 4 "GND"))
    (instance "C1" (cap "10pF" np0) (pin 1 "OSC_IN")  (pin 2 "GND"))
    (instance "C2" (cap "10pF" np0) (pin 1 "OSC_OUT") (pin 2 "GND")))

  (section "GPIO" (col 1) (row 0)
    (pins "U1"
      (pin 6 "LED_PIN"))
    (series "R1" (res "330R") "LED_PIN" "LED_NET")
    (instance "D1" (led "green")
      (pin 1 "LED_NET")
      (pin 2 "GND")))

  (port "VDD" "VDD" in   (rated 3.0 3.6))
  (port "GND" "GND" bidi))
```

For the real-world version with feedback divider math, sub-blocks, and a power-good LED, see `projects/designs/lib/modules/tpsm84338.sexp`. For a multi-section MCU schematic, see `projects/designs/src/stm32n6/stm32n6.sexp`.
