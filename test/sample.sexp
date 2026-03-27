; Sample footprint for testing
(footprint "QFN9-3.3x4.5"
  (description "9-pin QFN, 3.3x4.5mm body, 0.5mm pitch")

  (pad 1 smd rect    (pos -1.25  1.75) (size 0.70 0.30))
  (pad 2 smd rect    (pos -1.25  0.75) (size 0.70 0.30))
  (pad 3 smd rect    (pos -1.25 -0.25) (size 0.70 0.30))

  (courtyard (rect -2.0 -2.5 2.0 2.5))

  (silkscreen
    (line (-1.8 2.2) (1.8 2.2))
    (circle (-2.0 2.8) 0.2))

  (mask-expansion 0.05mm)
  (paste-expansion -0.02mm))
