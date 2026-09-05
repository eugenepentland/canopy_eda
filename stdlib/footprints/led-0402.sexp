;; Same IPC-7351B density-level-B land as the 0402 chip resistor (body
;; 1.00 +/-0.05 x 0.50 +/-0.05 mm, end terminal 0.25 +/-0.05 mm, toe goal
;; J_T = 0.20 mm), plus a polarity bar. The courtyard is widened in X to
;; contain that bar.
;;
;; Pad 1 = anode (A), pad 2 = cathode (K). The silkscreen bar marks the
;; cathode end, so the part reads the same way as its schematic symbol.
(footprint "led-0402"
  (description "LED, 0402 (1005 metric), IPC-7351B density level B (nominal) land; pad 1 = anode, pad 2 = cathode")

  (pad 1 smd roundrect (pos -0.45 0.00) (size 0.56 0.56))
  (pad 2 smd roundrect (pos 0.45 0.00) (size 0.56 0.56))
  (courtyard (rect -0.850 -0.400 1.100 0.400))
  (silkscreen
    (line (0.95 -0.30) (0.95 0.30))
  )
)
