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
(footprint "pin-header-1x2-2-54mm"
  (description "Through-hole 1x2 pin header, 2.54 mm (0.1 in) pitch, single row")

  (pad 1  thru rect   (pos 0.00 0.00) (size 1.70 1.70) (drill 1.00))
  (pad 2  thru circle (pos 0.00 2.54) (size 1.70 1.70) (drill 1.00))
  (courtyard (rect -1.270 -1.270 1.270 3.810))
  (silkscreen
    (line (-1.27 -1.27) (1.27 -1.27))
    (line (1.27 -1.27) (1.27 3.81))
    (line (1.27 3.81) (-1.27 3.81))
    (line (-1.27 3.81) (-1.27 -1.27))
  )
)
