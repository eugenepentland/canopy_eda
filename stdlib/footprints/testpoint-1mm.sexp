;; Bare 1 mm round probe pad: one SMD land, no paste (nothing is soldered to
;; it), and a silk ring 0.2 mm outside the copper so the pad is findable on a
;; populated board.
(footprint "testpoint-1mm"
  (description "1 mm diameter SMD test point / probe pad")

  (pad 1 smd circle (pos 0.00 0.00) (size 1.00 1.00) no-paste)
  (courtyard (rect -0.800 -0.800 0.800 0.800))
  (silkscreen
    (circle (0.00 0.00) 0.70)
  )
)
