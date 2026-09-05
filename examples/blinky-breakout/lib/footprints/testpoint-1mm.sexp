;; PROJECT OVERRIDE of the bundled `testpoint-1mm` land.
;;
;; The standard library ships a 1.00 mm probe pad. This board is brought up on
;; a bench with a sprung hook clip rather than a needle probe, so its probe
;; pads are 1.50 mm — enough copper for a hook to bite without slipping onto a
;; neighbouring net. Nothing else about the part changes: it keeps the bundled
;; `testpoint` component and pinout, and every other project still gets the
;; 1.00 mm land.
;;
;; Because the file name matches the bundled one, this copy wins for this
;; project only. That is the whole override mechanism: same name, your
;; directory, first hit wins. See docs/standard-library.md.
;;
;;   pad   1.50 mm round, no paste (nothing is soldered to it)
;;   silk  ring 0.20 mm outside the copper, so the pad is findable on a
;;         populated board
;;   courtyard 0.05 mm outside the silk ring
(footprint "testpoint-1mm"
  (description "1.5 mm SMD hook-probe test point (project override of the 1 mm bundled land)")

  (pad 1 smd circle (pos 0.00 0.00) (size 1.50 1.50) no-paste)
  (courtyard (rect -1.000 -1.000 1.000 1.000))
  (silkscreen
    (circle (0.00 0.00) 0.95)
  )
)
