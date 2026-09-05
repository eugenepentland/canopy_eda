;; Land pattern computed from the IPC-7351B density-level-B (nominal) equations
;; over the 0805 (2012 metric) chip package's published nominal dimensions:
;;   body 2.00 +/-0.10 x 1.25 +/-0.10 mm, end terminal 0.40 +/-0.10 mm, toe goal J_T = 0.35 mm,
;;   heel goal J_H = 0.00 mm, side goal J_S = 0.00 mm,
;;   fabrication allowance F = 0.05 mm, placement accuracy P = 0.025 mm.
;; Z_max = L_min + 2*J_T + rss(L_tol,F,P); G_min = S_max - rss(S_tol,F,P);
;; X_max = W_min + rss(W_tol,F,P); pad = ((Z-G)/2) x X centred at (Z+G)/4.
;; Courtyard = the greater of the pad and body extent plus 0.10 mm.
;; No silkscreen: a symmetric two-terminal chip has nothing to orient, and
;; the courtyard already carries the placement keep-out.
(footprint "r-0805"
  (description "Chip resistor, 0805 (2012 metric), IPC-7351B density level B (nominal) land")

  (pad 1 smd roundrect (pos -0.93 0.00) (size 0.96 1.36))
  (pad 2 smd roundrect (pos 0.93 0.00) (size 0.96 1.36))
  (courtyard (rect -1.550 -0.800 1.550 0.800))
)
