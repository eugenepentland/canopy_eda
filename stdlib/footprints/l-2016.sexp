;; Generic 2016 metric shielded power inductor: 2.0 x 1.6 mm body, 1.0 mm
;; tall, with two bottom terminations 0.5 mm long spanning the full 1.6 mm
;; width. No vendor part is assumed — check the inductor you actually buy
;; against these numbers before fabricating.
;;
;; Land = terminal + 0.20 mm toe + 0.20 mm heel in length, full body width,
;; so the outer span is the body length plus 0.40 mm. Courtyard = the greater
;; of the pad and the maximum body extent plus 0.25 mm.
(footprint "l-2016"
  (description "Shielded power inductor, 2016 metric (2.0 x 1.6 mm), generic")

  (pad 1 smd rect (pos -0.75 0.00) (size 0.90 1.60))
  (pad 2 smd rect (pos 0.75 0.00) (size 0.90 1.60))
  (courtyard (rect -1.450 -1.100 1.450 1.100))
)
