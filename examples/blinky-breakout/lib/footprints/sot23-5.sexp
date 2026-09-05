;; Land pattern for the 5-lead SOT-23 outline, computed from the IPC-7351B
;; density-level-B (nominal) gull-wing equations over the package's published
;; JEDEC MO-178 dimensions:
;;
;;   lead span    L = 2.80 +/-0.20 mm  (L_min 2.60, L_max 3.00, L_tol 0.40)
;;   foot length  T = 0.45 +/-0.15 mm  (T_min 0.30, T_max 0.60)
;;   lead width   W = 0.40 +/-0.10 mm  (W_min 0.30, W_tol 0.20)
;;   body         2.90 mm along the lead rows x 1.60 mm across, pitch 0.95 mm
;;
;; Density-level-B fillet goals for a gull-wing lead: toe J_T = 0.35 mm,
;; heel J_H = 0.35 mm, side J_S = 0.03 mm. Fabrication allowance F = 0.05 mm
;; and placement accuracy P = 0.025 mm — the same allowances the bundled chip
;; lands use, so this land and stdlib/footprints/ are one system.
;;
;;   S_max = L_max - 2*T_min = 2.400   (widest gap between the lead feet)
;;   S_min = L_min - 2*T_max = 1.400,  S_tol = 1.000
;;   Z_max = L_min + 2*J_T + rss(L_tol,F,P) = 2.600 + 0.700 + 0.404 = 3.704
;;   G_min = S_max - 2*J_H - rss(S_tol,F,P) = 2.400 - 0.700 - 1.002 = 0.698
;;   X_max = W_min + 2*J_S + rss(W_tol,F,P) = 0.300 + 0.060 + 0.208 = 0.568
;;   pad   = ((Z-G)/2) x X = 1.503 x 0.568, centred at (Z+G)/4 = 1.101
;;
;; The wide published foot tolerance makes this land about 0.2 mm more generous
;; at each fillet than a typical vendor-recommended SOT-23-5 land. That is the
;; honest output of level-B goals over these tolerances, and the extra copper
;; suits hand rework.
;;
;; Courtyard = the greater of the pad and body extent plus 0.10 mm, rounded up
;; to the next 0.05 mm: X 1.853 + 0.10 -> 2.00, Y 1.450 + 0.10 -> 1.55.
;;
;; Silkscreen: the two body ends plus a pin-1 dot. The body sides are omitted
;; because they would run across the lands. Pin 1 is the top of the left
;; column; numbering runs down that column and back up the right one.
(footprint "sot23-5"
  (description "5-lead SOT-23 (JEDEC MO-178), IPC-7351B density level B (nominal) land")

  (pad 1 smd roundrect (pos -1.101 -0.95) (size 1.503 0.568))
  (pad 2 smd roundrect (pos -1.101  0.00) (size 1.503 0.568))
  (pad 3 smd roundrect (pos -1.101  0.95) (size 1.503 0.568))
  (pad 4 smd roundrect (pos  1.101  0.95) (size 1.503 0.568))
  (pad 5 smd roundrect (pos  1.101 -0.95) (size 1.503 0.568))
  (courtyard (rect -2.000 -1.550 2.000 1.550))
  (silkscreen
    (line (-0.80 -1.45) (0.80 -1.45))
    (line (-0.80  1.45) (0.80  1.45))
    (circle (-1.00 -1.38) 0.10)
  )
)
