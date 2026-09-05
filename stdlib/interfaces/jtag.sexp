;; IEEE 1149.1 JTAG, stated from the TARGET's point of view: the probe clocks
;; TCK, walks the state machine with TMS, shifts in on TDI and reads back TDO.
(interface jtag "IEEE 1149.1 JTAG, target perspective"
  (signal TCK  in  clock)
  (signal TMS  in)
  (signal TDI  in  data)
  (signal TDO  out data)
  (signal TRST in  optional))
