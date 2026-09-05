;; Land pattern computed from the IPC-7351B density-level-B (nominal) equations
;; over the 0201 (0603 metric) chip package's published nominal dimensions:
;;   body 0.60 +/-0.03 x 0.30 +/-0.03 mm, end terminal 0.15 +/-0.05 mm, toe goal J_T = 0.20 mm,
;;   heel goal J_H = 0.00 mm, side goal J_S = 0.00 mm,
;;   fabrication allowance F = 0.05 mm, placement accuracy P = 0.025 mm.
;; Z_max = L_min + 2*J_T + rss(L_tol,F,P); G_min = S_max - rss(S_tol,F,P);
;; X_max = W_min + rss(W_tol,F,P); pad = ((Z-G)/2) x X centred at (Z+G)/4.
;; Courtyard = the greater of the pad and body extent plus 0.10 mm.
;; No silkscreen: a symmetric two-terminal chip has nothing to orient, and
;; the courtyard already carries the placement keep-out.
(footprint "l-0201"
  (description "Chip inductor, 0201 (0603 metric), IPC-7351B density level B (nominal) land")

  (pad 1 smd roundrect (pos -0.30 0.00) (size 0.44 0.35))
  (pad 2 smd roundrect (pos 0.30 0.00) (size 0.44 0.35))
  (courtyard (rect -0.650 -0.300 0.650 0.300))
)
