;; Land pattern computed from the IPC-7351B density-level-B (nominal) equations
;; over the 0603 (1608 metric) chip package's published nominal dimensions:
;;   body 1.60 +/-0.10 x 0.80 +/-0.10 mm, end terminal 0.35 +/-0.10 mm, toe goal J_T = 0.35 mm,
;;   heel goal J_H = 0.00 mm, side goal J_S = 0.00 mm,
;;   fabrication allowance F = 0.05 mm, placement accuracy P = 0.025 mm.
;; Z_max = L_min + 2*J_T + rss(L_tol,F,P); G_min = S_max - rss(S_tol,F,P);
;; X_max = W_min + rss(W_tol,F,P); pad = ((Z-G)/2) x X centred at (Z+G)/4.
;; Courtyard = the greater of the pad and body extent plus 0.10 mm.
;; No silkscreen: a symmetric two-terminal chip has nothing to orient, and
;; the courtyard already carries the placement keep-out.
(footprint "c-0603"
  (description "MLCC capacitor, 0603 (1608 metric), IPC-7351B density level B (nominal) land")

  (pad 1 smd roundrect (pos -0.75 0.00) (size 0.91 0.91))
  (pad 2 smd roundrect (pos 0.75 0.00) (size 0.91 0.91))
  (courtyard (rect -1.350 -0.600 1.350 0.600))
)
