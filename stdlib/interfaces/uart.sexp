;; Asynchronous serial, stated from the PERIPHERAL (DCE) side: RX is what the
;; peripheral receives, TX what it drives. The hardware-handshake pair is
;; optional — most links leave CTS/RTS unwired.
(interface uart "Asynchronous serial, peripheral (device) perspective"
  (signal RX  in  data)
  (signal TX  out data)
  (signal CTS in  optional)
  (signal RTS out optional))
