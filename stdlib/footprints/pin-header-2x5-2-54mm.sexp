;; Through-hole pin header on a 2.54 mm (0.100 in) grid — the de facto
;; 0.1-inch header land:
;;
;;   drill 1.00 mm = a 0.64 mm square post (0.90 mm across the diagonal) plus
;;                   fabrication clearance
;;   pad   1.70 mm = 0.35 mm annular ring around that drill
;;   pin 1 is rectangular, the rest round, so orientation survives assembly
;;
;; Body outline = 2.54 mm per row/column centred on the pin grid; the
;; silkscreen traces it and the courtyard is that outline.
(footprint "pin-header-2x5-2-54mm"
  (description "Through-hole 2x5 (10-pin) pin header, 2.54 mm (0.1 in) pitch, dual row; odd pins in column 1, even pins in column 2")

  (pad 1  thru rect   (pos 0.00 0.00) (size 1.70 1.70) (drill 1.00))
  (pad 2  thru circle (pos 2.54 0.00) (size 1.70 1.70) (drill 1.00))
  (pad 3  thru circle (pos 0.00 2.54) (size 1.70 1.70) (drill 1.00))
  (pad 4  thru circle (pos 2.54 2.54) (size 1.70 1.70) (drill 1.00))
  (pad 5  thru circle (pos 0.00 5.08) (size 1.70 1.70) (drill 1.00))
  (pad 6  thru circle (pos 2.54 5.08) (size 1.70 1.70) (drill 1.00))
  (pad 7  thru circle (pos 0.00 7.62) (size 1.70 1.70) (drill 1.00))
  (pad 8  thru circle (pos 2.54 7.62) (size 1.70 1.70) (drill 1.00))
  (pad 9  thru circle (pos 0.00 10.16) (size 1.70 1.70) (drill 1.00))
  (pad 10 thru circle (pos 2.54 10.16) (size 1.70 1.70) (drill 1.00))
  (courtyard (rect -1.270 -1.270 3.810 11.430))
  (silkscreen
    (line (-1.27 -1.27) (3.81 -1.27))
    (line (3.81 -1.27) (3.81 11.43))
    (line (3.81 11.43) (-1.27 11.43))
    (line (-1.27 11.43) (-1.27 -1.27))
  )
)
