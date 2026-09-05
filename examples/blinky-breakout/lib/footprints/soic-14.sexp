;; Land pattern for the 14-lead narrow-body SOIC, computed from the IPC-7351B
;; density-level-B (nominal) gull-wing equations over the package's published
;; JEDEC MS-012 variation AB dimensions:
;;
;;   lead span    L = 6.00 +/-0.20 mm  (L_min 5.80, L_max 6.20, L_tol 0.40)
;;   foot length  T = 0.40 .. 1.27 mm  (T_min 0.40, T_max 1.27)
;;   lead width   W = 0.42 +/-0.09 mm  (W_min 0.33, W_tol 0.18)
;;   body         8.65 mm along the lead rows x 3.90 mm across, pitch 1.27 mm
;;
;; Density-level-B fillet goals for a gull-wing lead: toe J_T = 0.35 mm,
;; heel J_H = 0.35 mm, side J_S = 0.03 mm. Fabrication allowance F = 0.05 mm
;; and placement accuracy P = 0.025 mm — the same allowances the bundled chip
;; lands use, so this land and stdlib/footprints/ are one system.
;;
;;   S_max = L_max - 2*T_min = 5.400   (widest gap between the lead feet)
;;   S_min = L_min - 2*T_max = 3.260,  S_tol = 2.140
;;   Z_max = L_min + 2*J_T + rss(L_tol,F,P) = 5.800 + 0.700 + 0.404 = 6.904
;;   G_min = S_max - 2*J_H - rss(S_tol,F,P) = 5.400 - 0.700 - 2.141 = 2.559
;;   X_max = W_min + 2*J_S + rss(W_tol,F,P) = 0.330 + 0.060 + 0.188 = 0.578
;;   pad   = ((Z-G)/2) x X = 2.173 x 0.578, centred at (Z+G)/4 = 2.366
;;
;; The published foot length spans 0.40 to 1.27 mm, and that one tolerance is
;; what makes the heel end of the land reach further under the body than a
;; typical vendor-recommended SOIC land. It is the honest output of level-B
;; goals over these tolerances.
;;
;; Courtyard = the greater of the pad and body extent plus 0.10 mm, rounded up
;; to the next 0.05 mm: X 3.453 + 0.10 -> 3.60, Y 4.325 + 0.10 -> 4.50.
;;
;; Silkscreen: the two body ends plus a pin-1 dot. The body sides are omitted
;; because they would run across the lands. Pin 1 is the top of the left
;; column; numbering runs down that column and back up the right one.
(footprint "soic-14"
  (description "14-lead narrow-body SOIC, 1.27 mm pitch (JEDEC MS-012 AB), IPC-7351B density level B (nominal) land")

  (pad 1  smd roundrect (pos -2.366 -3.81) (size 2.173 0.578))
  (pad 2  smd roundrect (pos -2.366 -2.54) (size 2.173 0.578))
  (pad 3  smd roundrect (pos -2.366 -1.27) (size 2.173 0.578))
  (pad 4  smd roundrect (pos -2.366  0.00) (size 2.173 0.578))
  (pad 5  smd roundrect (pos -2.366  1.27) (size 2.173 0.578))
  (pad 6  smd roundrect (pos -2.366  2.54) (size 2.173 0.578))
  (pad 7  smd roundrect (pos -2.366  3.81) (size 2.173 0.578))
  (pad 8  smd roundrect (pos  2.366  3.81) (size 2.173 0.578))
  (pad 9  smd roundrect (pos  2.366  2.54) (size 2.173 0.578))
  (pad 10 smd roundrect (pos  2.366  1.27) (size 2.173 0.578))
  (pad 11 smd roundrect (pos  2.366  0.00) (size 2.173 0.578))
  (pad 12 smd roundrect (pos  2.366 -1.27) (size 2.173 0.578))
  (pad 13 smd roundrect (pos  2.366 -2.54) (size 2.173 0.578))
  (pad 14 smd roundrect (pos  2.366 -3.81) (size 2.173 0.578))
  (courtyard (rect -3.600 -4.500 3.600 4.500))
  (silkscreen
    (line (-1.95 -4.325) (1.95 -4.325))
    (line (-1.95  4.325) (1.95  4.325))
    (circle (-2.60 -4.30) 0.12)
  )
)
