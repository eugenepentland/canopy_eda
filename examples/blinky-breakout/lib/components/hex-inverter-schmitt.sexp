;; Generic hex Schmitt-trigger inverter in a 14-lead narrow-body SOIC.
;;
;; Like the regulator beside it, this is a PACKAGE-STANDARD part rather than a
;; manufacturer's: the outline is JEDEC MS-012 AB and the pin assignment is the
;; industry-standard hex-inverter arrangement — six independent inverters,
;; input then output in pin order, ground on 7 and supply on 14 — that every
;; logic vendor's part in this package shares. No manufacturer, MPN or
;; datasheet is claimed, and the numbers below describe a generic CMOS logic
;; family rather than a measured device. See `ldo-3v3-sot23-5.sexp` for what to
;; do when you pick a real part.
(component "hex-inverter-schmitt"
  (description "Generic hex Schmitt-trigger inverter, 14-lead SOIC, six independent gates")
  (pinout hex-inverter-schmitt)
  (footprint soic-14)
  (refdes "U")

  (thermal (theta-ja 90.0) (tj-max 125.0))

  (requirement "Supply stays inside the 2.0-6.0 V operating range of this generic CMOS logic model."
    (check (voltage-range (pin "VCC") (min 2.0) (max 6.0))))
  (requirement "At least 100 nF of ceramic capacitance sits across VCC and GND, placed at the package."
    (check (decoupling (pin "VCC") (pin "GND") (min-uf 0.1)))))
