;; Standard-library smoke fixture.
;;
;; This project directory has NO `lib/` of its own: every part below comes from
;; the standard library bundled into the netlisp binary. It exists so
;; `netlisp build` / `check` / `export-kicad` are proven end to end against the
;; bundle rather than only in unit tests — the way a brand-new user's first
;; project resolves. See docs/standard-library.md.
;;
;; Board: a 2-pin power inlet, a ferrite-filtered rail with bulk + local
;; decoupling, an LC post-filter brought out to a test point, and a power LED.

(import pin-header-1x2)
(import testpoint)
(import mounting-hole-m2)

(design-block "Stdlib Smoke Board"

  (section "Power Inlet" "2-pin 0.1 in header, ferrite-filtered +3V3 rail with bulk and local decoupling"
    (row 0) (col 0)
    (instance "J1" pin-header-1x2
      (pin 1 "+3V3")
      (pin 2 "GND") (id eccdaaa2))
    (instance "FB1" (ferrite-0402 "600R")
      (pin 2 "+3V3")
      (pin 1 "+3V3_F") (id c9f5502c))
    (instance "C1" (cap-0805 "10uF")
      (pin 1 "+3V3_F")
      (pin 2 "GND") (id ada43e4e))
    (instance "C2" (cap-0402 "100nF")
      (pin 1 "+3V3_F")
      (pin 2 "GND")
      (decouples rail) (id c061de4a))
  )

  (section "Filtered Rail" "LC post-filter on the +3V3 rail, brought out to a probe pad"
    (row 0) (col 1)
    (instance "L1" (ind-0603 "10uH")
      (pin 1 "+3V3_F")
      (pin 2 "+3V3_LC") (id b98ca3f5))
    (instance "C3" (cap-0603 "1uF")
      (pin 1 "+3V3_LC")
      (pin 2 "GND") (id d28a256b))
    (instance "TP1" testpoint
      (pin 1 "+3V3_LC") (id b9c13f73))
  )

  (section "Power Indicator" "1 kohm series resistor and an 0402 LED across the filtered rail"
    (row 1) (col 0)
    (instance "R1" (res-0402 "1k")
      (pin 1 "+3V3_F")
      (pin 2 "LED_A") (id ed338b02))
    (instance "D1" (led-0402 "red")
      (pin 1 "LED_A")
      (pin 2 "GND") (id f1da3d19))
  )

  (section "Mechanical" "Two M2 mounting holes, both bonded to ground"
    (row 1) (col 1)
    (instance "H1" mounting-hole-m2
      (pin 1 "GND") (id ce267d38))
    (instance "H2" mounting-hole-m2
      (pin 1 "GND") (id e6d792c0))
  )
)
