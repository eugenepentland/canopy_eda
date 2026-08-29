;; Deterministic fixture board for scripts/pcb_editor_invariants/run.js.
;;
;; Deliberately tiny and self-contained: it imports only the probe-* parts that
;; live beside it under fixture/lib, so the invariant probe never depends on the
;; projects/designs corpus (which moves under the gate — a prior browser gate
;; broke exactly that way). Small also means the editor page opens fast, which
;; keeps the probe's runtime modest.

(import probe-ic8)
(import probe-res)
(import probe-cap)

(design-block "PCB Editor Invariant Fixture"

  (section "Regulator" "8-pin regulator stand-in with its passives"
    (row 0) (col 0)

    (instance "U1" probe-ic8
      (pin 1 "VIN")
      (pin 2 "EN")
      (pin 3 "NC_1")
      (pin 4 "GND")
      (pin 5 "FB")
      (pin 6 "SW")
      (pin 7 "BOOT")
      (pin 8 "VOUT"))

    (instance "C1" (probe-cap "10uF")
      (pin 1 "VIN")
      (pin 2 "GND"))

    (instance "C2" (probe-cap "100nF")
      (pin 1 "VIN")
      (pin 2 "GND"))

    (instance "C3" (probe-cap "22uF")
      (pin 1 "VOUT")
      (pin 2 "GND"))

    (instance "C4" (probe-cap "100nF")
      (pin 1 "BOOT")
      (pin 2 "SW"))

    (instance "R1" (probe-res "100k")
      (pin 1 "VOUT")
      (pin 2 "FB"))

    (instance "R2" (probe-res "33k2")
      (pin 1 "FB")
      (pin 2 "GND"))

    (instance "R3" (probe-res "10k")
      (pin 1 "VIN")
      (pin 2 "EN")))

  (section "Load" "Resistive load bank on the regulated rail"
    (row 0) (col 1)

    (instance "R4" (probe-res "1k")
      (pin 1 "VOUT")
      (pin 2 "GND"))

    (instance "R5" (probe-res "1k")
      (pin 1 "VOUT")
      (pin 2 "GND"))

    (instance "R6" (probe-res "1k")
      (pin 1 "VOUT")
      (pin 2 "GND"))

    (instance "C5" (probe-cap "1uF")
      (pin 1 "VOUT")
      (pin 2 "GND"))))
