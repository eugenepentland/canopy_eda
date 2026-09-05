;; Generic 3.3 V fixed-output LDO in the 5-lead SOT-23 outline.
;;
;; This is a PACKAGE-STANDARD part, not a manufacturer's part: the outline is
;; JEDEC MO-178 and the pin assignment (VIN / GND / EN / NC / VOUT) is the
;; arrangement the 5-lead SOT-23 regulators of every vendor share. No
;; manufacturer, MPN or datasheet is claimed.
;;
;; The numbers below therefore describe a GENERIC 150 mA-class regulator — the
;; model this example board is designed against — not a measured device. They
;; are written here rather than in the board so the checks can execute them:
;; each `(check …)` is run against the real netlist on every build. When you
;; pick a real part, copy this file, name it after the part, attach its
;; datasheet with `netlisp tool attach_datasheet`, and replace every number
;; below with the datasheet's, adding `(ref "part.pdf" (page N) (quote "…"))`
;; to each requirement so the citation travels with the claim.
(component "ldo-3v3-sot23-5"
  (description "Generic 3.3 V fixed LDO regulator, 150 mA class, 5-lead SOT-23, enable input")
  (pinout ldo-3v3-sot23-5)
  (footprint sot23-5)
  (refdes "U")

  (electrical "EN" (type input) (v-ih-min 1.2) (v-il-max 0.4) (max-voltage 6.0))

  (thermal (theta-ja 250.0) (tj-max 125.0))

  (requirement "Input supply stays inside the 2.5-6.0 V operating range of this generic regulator model."
    (check (voltage-range (pin "VIN") (min 2.5) (max 6.0))))
  (requirement "Output rail stays inside 3.135-3.465 V, the +/-5% band a fixed 3.3 V regulator of this class holds."
    (check (voltage-range (pin "VOUT") (min 3.135) (max 3.465))))
  (requirement "At least 1 uF of ceramic capacitance sits across VIN and GND."
    (check (decoupling (pin "VIN") (pin "GND") (min-uf 1.0))))
  (requirement "At least 1 uF of ceramic capacitance sits across VOUT and GND; an LDO of this class needs an output capacitor to be stable."
    (check (decoupling (pin "VOUT") (pin "GND") (min-uf 1.0)))))
