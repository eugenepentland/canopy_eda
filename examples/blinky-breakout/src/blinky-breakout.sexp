;; Blinky Breakout — the netlisp example board.
;;
;; A 5 V input, a 3.3 V regulator, a Schmitt-trigger relaxation oscillator that
;; blinks an LED at a couple of hertz, and the four unused gates brought out to
;; a 0.1 inch expansion header. Small enough to read in one sitting, complete
;; enough to build, check, lay out, route and hand to KiCad.
;;
;; Every form below is explained, in order, in ../README.md.
;;
;;   J1 ──► U1 (3.3 V LDO) ──► U2 gate 1 (RC oscillator) ──► gate 2 ──► R3 ──► D1
;;                             U2 gates 3-6 ─────────────────────────────────► J2
;;
;; Parts come from two places. The passives, the headers, the test points and
;; the mounting holes are in the standard library compiled into the netlisp
;; binary, so they need no files here. The regulator, the inverter and their
;; land patterns are not, so this project carries them in its own lib/ —
;; along with one deliberate override of a bundled footprint.

(import ldo-3v3-sot23-5
        hex-inverter-schmitt
        pin-header-1x2
        pin-header-2x5
        testpoint
        mounting-hole-m2)

(design-block "Blinky Breakout"

  ;; ── Physical board ──────────────────────────────────────────────────────
  ;; 46 x 30 mm, two copper layers with a ground pour on the bottom. The edge
  ;; words dock the two headers against real board edges and pin the mounting
  ;; holes to the four corners; everything else is placed by the solver.
  (board
    (size 46.0 30.0)
    (left "J1")
    (right "J2")
    (corners "H1" "H2" "H3" "H4"))

  (stackup 2
    (pour bottom "GND"))

  ;; Pins how the PCB engine should treat the input rail. Without this the
  ;; engine infers a class from the net name and says so; declaring it makes
  ;; the intent explicit and the inference silent. The child is
  ;; (placement-class …) — placement and routing-order criticality. The
  ;; top-level (net-class …) form is a different thing: routing geometry.
  (module-policy
    (placement-class "VIN_5V" input_rail))

  ;; ── Design maths ────────────────────────────────────────────────────────
  ;; `let` binds a value; numeric literals carry SI suffixes, so `470k` is
  ;; 470000 and `1uF` is 1e-6. Every number the board depends on is computed
  ;; here once and then referenced by the parts and their notes below, so a
  ;; changed resistor cannot disagree with the text next to it.
  (let v-in    5.0)
  (let v-rail  3.3)
  (let v-led   2.0)      ;; red LED forward drop at a few milliamps
  (let r-led   270R)
  (let i-led   (/ (- v-rail v-led) r-led))
  (let r-osc   470k)
  (let c-osc   1uF)
  ;; A Schmitt-trigger RC relaxation oscillator swings between the gate's two
  ;; hysteresis thresholds. For a CMOS Schmitt inverter, whose thresholds sit
  ;; near a third and two thirds of the supply, one period is about 0.8*R*C.
  (let t-blink (* 0.8 (* r-osc c-osc)))
  (let f-blink (/ 1.0 t-blink))

  ;; Assertions never stop evaluation: every one below is checked and recorded,
  ;; so one run reports all of them. What happens next is per command. `build`
  ;; and `export-kicad` hand off the board, so a failed assertion is fatal
  ;; there: they print every assertion, locate the failing ones at
  ;; file:line:col, write NOTHING — no netlist, no .bom, no export — and exit
  ;; 1. `check` reports it as one error finding beside ERC and still prints its
  ;; whole report. `export-pdf` and the review pages put it in the validation
  ;; table and produce the document anyway.
  (assert (> (- v-in v-rail) 0.5)
    "LDO input-to-output headroom must exceed the regulator's dropout voltage")
  (assert-range (* i-led 1000.0) 2.0 10.0 "LED current (mA)")
  (assert-range f-blink 0.5 5.0 "Blink rate (Hz)")

  ;; ── Board boundary ──────────────────────────────────────────────────────
  (port "VIN" "VIN_5V" in   power (nominal v-in)   (rated 4.5 5.5) (current 0.02 0.15))
  (port "GND"           bidi power)
  (port "3V3" "+3V3"    out  power (nominal v-rail) (rated 3.2 3.4))

  ;; ── Block diagram ───────────────────────────────────────────────────────
  ;; Names the clusters the schematic page's block view draws. Purely a
  ;; presentation form: it groups sections, it does not change the netlist.
  (diagram-layout
    (group "Power"   "Power Input Header" "3V3 LDO Regulator")
    (group "Blinker" "Schmitt Oscillator" "Status LED")
    (group "Breakout" "Expansion Header"))

  ;; ── Sections ────────────────────────────────────────────────────────────

  (section "Power Input Header" "2-pin 0.1 in header, 4.5-5.5 V bench supply"
    (row 0) (col 0) (category power)
    (description "Where the board is powered from.")
    (instance "J1" pin-header-1x2
      (pin 1 "VIN_5V")
      (pin 2 "GND")
      (note "Pin 1 is +5 V, pin 2 is ground. There is no reverse-polarity protection: swap the leads and the regulator sees -5 V.") (id db90264b))
  )

  (section "3V3 LDO Regulator" "Generic SOT-23-5 LDO, 5 V in, 3.3 V out"
    (row 0) (col 1) (category power)
    (description "Makes the 3.3 V rail the logic runs from, and enables it when power arrives.")
    (instance "U1" ldo-3v3-sot23-5
      (pin VIN  "VIN_5V" (i-typ 0.012) (i-max 0.15))
      (pin GND  "GND")
      (pin EN   "EN")
      (pin VOUT "+3V3"   (i-typ 0.012) (i-max 0.15))
      (nc-ok NC "Pin 4 has no internal connection on this outline; left open deliberately.")
      (note (fmt "Headroom is ~V - ~V = ~V, comfortably above any small-signal LDO's dropout." v-in v-rail (- v-in v-rail))) (id a171124e))
    (instance "C1" (cap-0603 "1uF")
      (pin 1 "VIN_5V")
      (pin 2 "GND")
      (near "U1" VIN)
      (note "Input capacitor. (near …) asks the placer to keep it against U1's VIN pad.") (id e2393be0))
    (instance "C2" (cap-0805 "10uF")
      (pin 1 "+3V3")
      (pin 2 "GND")
      (near "U1" VOUT)
      (note "Output capacitor: the reservoir the rail sags into when the LED switches.") (id f3ddd3b1))
    (instance "R1" (res-0603 "100k")
      (pin 1 "VIN_5V")
      (pin 2 "EN")
      (note "Enable is pulled to the input rail, so the regulator runs whenever power is present. Remove this resistor and drive EN yourself to sequence the board.") (id eed36e98))
  )

  (section "Schmitt Oscillator" "Hex Schmitt inverter, 470k x 1uF RC relaxation oscillator"
    (row 1) (col 0) (category clock)
    (description "Generates the blink. Gate 1 oscillates; gate 2 buffers it.")
    ;; The gate pins are quoted because a bare `1A` is a NUMBER — `1` with the
    ;; SI unit letter `A` — and would silently connect pad 1. Quote any pin name
    ;; that starts with a digit; bare atoms like VCC and GND are unambiguous.
    (instance "U2" hex-inverter-schmitt
      (pin VCC "+3V3" (i-typ 0.006) (i-max 0.05))
      (pin GND "GND")
      (pin "1A"  "RC_NODE")
      (pin "1Y"  "BLINK")
      (pin "2A"  "BLINK")
      (pin "2Y"  "LED_DRIVE")
      (note (fmt "One period is 0.8 * ~R * ~C = ~a s, so the LED blinks at about ~a Hz. Raise R2 or C4 to slow it down." r-osc c-osc t-blink f-blink)) (id b2bd49c9))
    (instance "R2" (res-0603 (fmt "~R" r-osc))
      (pin 1 "BLINK")
      (pin 2 "RC_NODE")
      (note "Feedback resistor: charges and discharges C4 from gate 1's output.") (id b49f91ed))
    (instance "C4" (cap-0603 (fmt "~C" c-osc))
      (pin 1 "RC_NODE")
      (pin 2 "GND")
      (note "Timing capacitor. Its value and R2's are the two numbers the blink rate is computed from.") (id a6bd5e2a))
    (instance "C3" (cap-0603 "100nF")
      (pin 1 "+3V3")
      (pin 2 "GND")
      (decouples "U2" VCC)
      (note "Decoupling capacitor. (decouples …) records which supply pad it serves, so the checks and the layout lints can find its loop — and it is what keeps the placer next to that pad.") (id cd3f7f72))
  )

  (section "Status LED" "Buffered red indicator, about 5 mA through 270 ohms"
    (row 1) (col 1) (category peripheral)
    (description "Shows the blink. Driven by gate 2, never by the timing node.")
    (instance "R3" (res-0603 (fmt "~R" r-led))
      (pin 1 "LED_DRIVE")
      (pin 2 "LED_A")
      (note (fmt "(~V rail - ~V LED drop) / ~R = ~A, inside the 2-10 mA the assertion at the top of the file allows." v-rail v-led r-led i-led)) (id f19682cb))
    (instance "D1" (led-0402 "red")
      (pin 1 "LED_A")
      (pin 2 "GND")
      (note "Pad 1 is the anode, pad 2 the cathode; the silkscreen bar marks the cathode end.") (id a969d128))
  )

  (section "Expansion Header" "2x5 0.1 in header: power, ground, four spare inverters"
    (row 2) (col 0) (category connector)
    (description "Brings the rail and the four unused gates off the board.")
    ;; (pins …) wires an already-placed part from another section, so one IC can
    ;; appear wherever its pins belong instead of all in one box.
    (pins "U2"
      (pin "3A" "EXP_3A")
      (pin "3Y" "EXP_3Y")
      (pin "4A" "EXP_4A")
      (pin "4Y" "EXP_4Y")
      (pin "5A" "EXP_5A")
      (pin "5Y" "EXP_5Y")
      (pin "6A" "EXP_6A")
      (pin "6Y" "EXP_6Y"))
    (instance "J2" pin-header-2x5
      (pin 1  "+3V3")
      (pin 2  "GND")
      (pin 3  "EXP_3A")
      (pin 4  "EXP_3Y")
      (pin 5  "EXP_4A")
      (pin 6  "EXP_4Y")
      (pin 7  "EXP_5A")
      (pin 8  "EXP_5Y")
      (pin 9  "EXP_6A")
      (pin 10 "EXP_6Y")
      (note "Odd pins are gate inputs, even pins the matching outputs, except pins 1 and 2 which are the 3.3 V rail and ground. Nothing on this board floats: every unused gate ends up here.") (id f7da0e41))
  )

  (section "Test Points" "Four hook-probe pads for bring-up"
    (row 2) (col 1) (category peripheral)
    (diagram hidden)
    (description "Four pads to clip a scope onto during bring-up.")
    ;; A probe pad is an ordinary part: `testpoint` from the standard library,
    ;; one pad, wired by naming a net. The note is what the review's bring-up
    ;; table prints. (The older `(test-point "TP1" "NET" (purpose …))` spelling
    ;; places exactly this and still works; keep it for `(virtual)` markers,
    ;; which have no pad and no other spelling.)
    (instance "TP1" testpoint (pin 1 "+3V3")
      (note "Regulated 3.3 V rail — check this first.") (id ee57727c))
    (instance "TP2" testpoint (pin 1 "BLINK")
      (note "Oscillator output; scope it to measure the real blink rate.") (id db1e766b))
    (instance "TP3" testpoint (pin 1 "GND")
      (note "Ground return for the scope clip.") (id c662916c))
    (instance "TP4" testpoint (pin 1 "VIN_5V")
      (note "Input rail, upstream of the regulator.") (id fe834c0b))
  )

  (section "Mounting Holes" "Four M2 holes, bonded to ground"
    (row 3) (col 0) (category connector)
    (diagram hidden)
    (description "Mechanical attachment; the plated holes tie the ground pour to the standoffs.")
    (instance "H1" mounting-hole-m2 (pin 1 "GND") (id b88b1c51))
    (instance "H2" mounting-hole-m2 (pin 1 "GND") (id d064e433))
    (instance "H3" mounting-hole-m2 (pin 1 "GND") (id c2b73098))
    (instance "H4" mounting-hole-m2 (pin 1 "GND") (id d2a0b35d))
  )
)
