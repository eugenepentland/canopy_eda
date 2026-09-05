;; Arm Serial Wire Debug, stated from the TARGET's point of view: the debug
;; probe drives the clock and the reset, and the data line is bidirectional.
(interface swd "Arm Serial Wire Debug, target perspective"
  (signal SWCLK in   clock)
  (signal SWDIO bidi data)
  (signal NRST  in   optional)
  (signal SWO   out  optional))
