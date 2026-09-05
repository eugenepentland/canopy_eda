;; Four-wire SPI, stated from the PERIPHERAL's point of view: a peripheral is
;; clocked and selected by the controller, receives on MOSI and answers on
;; MISO. A controller declares the same bundle with `(role controller)`, which
;; flips every direction.
(interface spi "Four-wire SPI (controller/peripheral), peripheral perspective"
  (signal SCK  in  clock)
  (signal MOSI in  data)
  (signal MISO out data)
  (signal CS   in))
