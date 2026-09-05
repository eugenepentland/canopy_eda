;; Generic 1616 (4040 metric) shielded power inductor: 4.0 +/-0.2 mm square
;; body with two bottom terminations 1.0 mm long by 3.4 mm wide, the common
;; footprint of that package class. No vendor part is assumed — check the
;; inductor you actually buy against these numbers before fabricating.
;;
;; Land = terminal + 0.20 mm toe + 0.20 mm heel in length and + 0.10 mm total
;; in width, so the outer span is the body length plus 0.40 mm and the solder
;; fillet is inspectable from the side. Courtyard = the greater of the pad and
;; the maximum body extent plus 0.25 mm.
(footprint "l-1616"
  (description "Shielded power inductor, 1616 (4040 metric), 4.0 x 4.0 mm, generic")

  (pad 1 smd rect (pos -1.50 0.00) (size 1.40 3.50))
  (pad 2 smd rect (pos 1.50 0.00) (size 1.40 3.50))
  (courtyard (rect -2.450 -2.350 2.450 2.350))
)
