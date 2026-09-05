;; M2 clearance hole, plated, with a ground-bonded pad on both outer layers.
;;
;;   drill 2.20 mm  = M2 (2.0 mm major diameter) screw shank plus clearance
;;   pad   3.80 mm  = 0.80 mm annular ring, and wide enough for a DIN 965
;;                    countersunk M2 head (3.8 mm) to sit entirely on copper
;;   courtyard r = 2.15 mm, i.e. 0.25 mm outside the pad. That suits a flush
;;   countersunk head; widen it for a pan head or for driver access.
(footprint "mounting-hole-m2"
  (description "M2 plated mounting hole, 2.2 mm drill, 3.8 mm pad on both outer layers")

  (pad 1 thru circle (pos 0.00 0.00) (size 3.80 3.80) (drill 2.20))
  (courtyard (circle (0.00 0.00) 2.15))
)
