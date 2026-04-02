# Schematic Syntax Reference

Schematic designs are written as S-expression (`.sexp`) files. Each file describes a circuit using a declarative, Lisp-like syntax. This reference covers every available form, with examples drawn from a real STM32N6 design.

## File Structure

A schematic file has two top-level forms: `import` and `design-block`.

```scheme
(import stm32n657l0h3q cap res ind led
        abm8 fc-135 ecmf02-2amx6 connector-swd amphenol-10164986
        mx66uw1g45gxdi00 aps256xxn-ob9-bg)

(design-block "STM32N657L0H3Q Minimal Schematic"
  ;; ... instances, sections, ports ...
)
```

### `import`

Loads component and module definitions from the project library. Names correspond to `.sexp` files in `lib/components/` or `lib/modules/`.

```scheme
(import cap res ind led)          ;; Parameterized component families
(import stm32n657l0h3q)           ;; Named component
(import tpsm84338)                ;; Parameterized module
```

### `design-block`

The top-level container for a circuit. Takes a name string followed by any number of child forms (instances, sections, ports, etc.).

```scheme
(design-block "My Circuit"
  ;; all circuit forms go here
)
```

### Comments

Line comments start with `;;`.

```scheme
;; This is a comment
(instance "R1" (res "10k")  ;; inline comment
  (pin 1 "VDD")
  (pin 2 "SIGNAL"))
```

## Components

### Parameterized families

Generic components like resistors, capacitors, inductors, and LEDs are created by calling the family name with a value string. Optional attributes (e.g., dielectric type) can follow.

```scheme
(cap "100nF")           ;; 100nF capacitor
(cap "10pF" np0)        ;; 10pF NP0/C0G capacitor
(cap "2.2nF" x7r)       ;; 2.2nF X7R capacitor
(res "10k")             ;; 10k resistor
(res "2R")              ;; 2 ohm resistor
(ind "1uH")             ;; 1uH inductor
(led "green")           ;; Green LED
```

### Named components

Specific parts (ICs, connectors, crystals) are referenced by their import name as a bare atom.

```scheme
stm32n657l0h3q          ;; STM32 MCU
amphenol-10164986       ;; USB-C connector
abm8                    ;; 24 MHz crystal
connector-swd           ;; SWD debug header
```

## Instances

### Basic instance

Creates a component instance with a reference designator, component, and pin-to-net assignments.

```scheme
(instance "U1" stm32n657l0h3q)

(instance "L1" (ind "1uH")
  (pin 1 "VLXSMPS")
  (pin 2 "VDDCORE"))

(instance "D1" (led "green")
  (pin 1 "LED_NET")
  (pin 2 "GND"))
```

### Multi-pin shorthand

Multiple pins can be assigned to the same net in a single `pin` form.

```scheme
(instance "J2" amphenol-10164986
  (pin GND_A GND_A__1 GND_B GND_B__1 "GND")        ;; 4 pins -> GND
  (pin VBUS_A VBUS_A__1 VBUS_B VBUS_B__1 "VBUS")    ;; 4 pins -> VBUS
  (pin CC1 "CC1")
  (pin CC2 "CC2")
  (pin "D1+" "D2+" "USB_DP_CONN")                   ;; 2 pins -> same net
  (pin "D1-" "D2-" "USB_DM_CONN")
  (pin SHIELD SHIELD__1 SHIELD__2 SHIELD__3 "GND"))
```

Pin IDs can be bare atoms (`CC1`, `GND_A`) or quoted strings (`"D1+"`, `"~{CS}"`) when they contain special characters.

## Sections

Sections group related circuitry. They organize the schematic visually and logically.

```scheme
(section "VDD Power"
  ;; pin assignments, instances, decoupling, etc.
)
```

### `pins` — bulk pin assignment

Inside a section, `pins` assigns pins of an already-instantiated component to nets. This is how large ICs (like MCUs) have their pins distributed across multiple sections.

```scheme
(section "VDD Power"
  (pins "U1"
    (pin J14 K14 L14 "VDD")
    (pin F1 "VDD")
    (pin H6 "VDDA18AON")
    (pin A19 F12 H14 N16 P8 P12 P14 W1 W19 N6 G6 H2 "GND"))
  (decouple (cap "100nF") U1 "VDD" "VDDA18AON"))
```

The first argument to `pins` is the reference designator of the target instance. Each `pin` form inside maps one or more pin IDs to a net name (the last argument).

### `bus` — sequential pin mapping

Inside a `pins` block, `bus` maps a list of pins to sequentially numbered nets with a shared prefix.

```scheme
(pins "U1"
  (pin P16 "FLASH_NCS")
  (pin U19 "FLASH_CLK")
  (pin R19 "FLASH_DQS")
  (bus "FLASH_IO" T19 P19 V19 U18 V18 T18 R18 P18))
```

This expands to:

```scheme
(pin T19 "FLASH_IO0")
(pin P19 "FLASH_IO1")
(pin V19 "FLASH_IO2")
;; ... through FLASH_IO7
```

Useful for wide data buses:

```scheme
(bus "PSRAM_IO" PP0 PP1 PP2 PP3 PP4 PP5 PP6 PP7
                PP8 PP9 PP10 PP11 PP12 PP13 PP14 PP15)
;; Expands to PSRAM_IO0 through PSRAM_IO15
```

## Shorthand Forms

These forms reduce boilerplate for common passive component patterns.

### `to-gnd` — component to ground

Connects a two-pin component between a net and GND (pin 1 = net, pin 2 = GND).

```scheme
;; With explicit ref-des:
(to-gnd "C35" (cap "100nF") "NRST")
(to-gnd "R1" (res "2R") "SNUB1")

;; Multi-net form (auto-numbered ref-des):
(to-gnd (res "10k") "BOOT0" "PA6")          ;; Creates R_auto for each net
(to-gnd (cap "10pF" np0) "OSC_IN" "OSC_OUT") ;; Creates C_auto for each net
```

The multi-net form creates one component per net, with automatically assigned reference designators.

### `to-rail` — component to a power rail

Like `to-gnd` but connects pin 2 to a named rail instead of GND. Used for pull-up resistors.

```scheme
(to-rail "R10" (res "10k") "FLASH_RESET" "VDDIO3")
;; pin 1 = FLASH_RESET, pin 2 = VDDIO3

(to-rail "R11" (res "10k") "FLASH_NCS" "VDDIO3")
```

### `series` — component in series

Places a two-pin component between two nets (pin 1 = first net, pin 2 = second net).

```scheme
(series "R4" (res "33R") "SWDIO_MCU" "SWDIO")
(series "R5" (res "33R") "SWCLK_MCU" "SWCLK")
```

### `decouple` — decoupling capacitors

Places decoupling capacitors on a power net, automatically creating per-pin sub-nets to route each cap close to its target IC pin.

**Single net, single cap:**

```scheme
(decouple "VDDA18PMU" (cap "100nF") U1)
```

This creates one 100nF cap for each pin of U1 that is on the `VDDA18PMU` net.

**Single net with bulk and bypass:**

```scheme
(decouple "VDDSMPS"
  (bulk   (cap "10uF") U1)
  (bypass (cap "1uF") U1 (cap "100nF") U1))
```

`bulk` and `bypass` sub-forms group multiple cap values. Each `(cap "val") REF` pair creates caps for the target's pins on that net.

**Single net, specific pin:**

```scheme
(decouple "VDDCORE" (cap "1uF") U1 W6)  ;; Only targets pin W6 of U1
```

**Multi-net form (auto-numbered):**

```scheme
(decouple (cap "100nF") U1
  "VDDA18PLL" "VDDA18USB" "VDDA18ADC" "VDDIO2" "VDDIO3")
```

When the first argument after `decouple` is a component (not a net name string), the remaining strings are treated as net names. One decoupling cap is created per pin per net.

## Ports

Ports define the external interface of a design block. Each port has a display name, net name, direction, and optional voltage rating.

```scheme
(port "VDD"       "VDD"       in   (rated 3.0 3.6))
(port "VDDCORE"   "VDDCORE"   in   (rated 0.78 0.95))
(port "GND"       "GND"       bidi)
(port "VBUS"      "VBUS"      in   (rated 4.0 5.5))
```

Directions: `in`, `out`, `bidi`.

The `rated` form specifies the minimum and maximum voltage for the port.

## Parameterized Modules

Modules define reusable circuit blocks with parameters. They are defined in `lib/modules/` and instantiated via `sub-block`.

### `defmodule`

```scheme
(defmodule tpsm84338 (rfbt rfbb rled)
  "3A Buck Converter with Power Good LED."

  ;; Computed values
  (let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
  (let led-current (/ (- vout 2.8) rled))
  (let rfbt-str (fmt "~R" rfbt))
  (let vout-str (fmt "~V" vout))

  ;; Validation
  (assert-range vout 0.6 16.0 "VOUT")
  (assert-range led-current 0.0 0.01 "LED current")

  (design-block (fmt "~V Buck (TPSM84338)" vout)
    (instance "U1" tpsm84338rcjr
      (pin 4 vout-str)
      ;; ...
    )
    (port "VIN"  "VIN"     in   (rated 3.8 28.0))
    (port "VOUT" vout-str  out  (rated 0.6 16.0))
    (port "GND"  "GND"     bidi)))
```

### Language features inside modules

| Form | Description | Example |
|------|-------------|---------|
| `let` | Bind a name to a computed value | `(let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))` |
| `fmt` | Format a value as a string | `(fmt "~V" vout)` -> `"3.3V"` |
| `assert-range` | Validate a parameter is within bounds | `(assert-range vout 0.6 16.0 "VOUT")` |
| `if` | Conditional | `(if (> vout 5.0) "high" "low")` |
| `cond` | Multi-branch conditional | `(cond (c1 e1) (c2 e2) (else e3))` |

**`fmt` specifiers:**

| Specifier | Formats as | Example |
|-----------|-----------|---------|
| `~V` | Voltage | `3.3V` |
| `~R` | Resistance | `10k`, `4.7M` |
| `~C` | Capacitance | `100nF`, `10uF` |
| `~A` | Current | `500mA` |
| `~S` | String (quoted) | `"hello"` |

**Arithmetic operators:** `+`, `-`, `*`, `/`, `%`
**Comparison:** `>`, `>=`, `<`, `<=`, `==`, `!=`
**Logic:** `and`, `or`, `not`

### `sub-block` — instantiate a module

```scheme
(import tpsm84338 lt3045)

(design-block "6V Low Noise Power Supply"
  (sub-block "buck" (tpsm84338 320000 30000 820))
  (sub-block "ldo" (lt3045 60000 300)))
```

The first argument is a prefix for the sub-block's reference designators. The second is a module call with parameter values.

## Annotations

### `note` — component annotation

Attaches descriptive text to a reference designator, displayed in the schematic viewer sidebar.

```scheme
(note "U1" "TPSM84338RCJR: 3.8-28V, 3A synchronous buck module.")
(note "R4" (fmt "RFBT = ~R. VOUT = 0.6V x (1 + ~R/~R) = ~V."
                rfbt rfbt rfbb vout))
```

### `group` — visual grouping

Groups components together visually in the schematic.

```scheme
(group "Power Good Indicator" ("Q1" "D1" "R9"))
(group "Input Decoupling" ("C1" "C2" "C3" "C8"))
(group "Feedback Divider" ("R4" "R5" "C7"))
```

## Complete Example

A minimal design with an MCU, crystal, and debug LED:

```scheme
(import my-mcu cap res led)

(design-block "Minimal MCU Board"

  (instance "U1" my-mcu)

  (section "Power"
    (pins "U1"
      (pin 1 2 3 "VDD")
      (pin 10 11 12 "GND"))
    (decouple (cap "100nF") U1 "VDD"))

  (section "Clock"
    (pins "U1"
      (pin 4 "OSC_IN")
      (pin 5 "OSC_OUT"))
    (to-gnd (cap "10pF" np0) "OSC_IN" "OSC_OUT"))

  (section "GPIO"
    (pins "U1"
      (pin 6 "LED_PIN"))
    (series "R1" (res "330R") "LED_PIN" "LED_NET")
    (instance "D1" (led "green")
      (pin 1 "LED_NET")
      (pin 2 "GND")))

  (port "VDD" "VDD" in  (rated 3.0 3.6))
  (port "GND" "GND" bidi))
```
