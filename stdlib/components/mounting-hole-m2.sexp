;; M2 clearance hole with a plated, ground-bonded pad on both outer layers.
;; A board feature, not a purchased part — the screw, washer and standoff are
;; assembly hardware and belong on a mechanical BOM. Use a bare NPTH footprint
;; instead when the hole must NOT carry copper to the chassis.
(component "mounting-hole-m2"
  (description "M2 plated mounting hole, 2.2 mm drill, 3.8 mm pad on both outer layers, bonded to GND")
  (pinout mounting-hole-m2)
  (footprint mounting-hole-m2)
  (refdes "H")
  (ignore-requirements))
