;; The industry-standard hex-inverter pin assignment: gate n's input on the pin
;; before its output, three gates up each side, ground on 7 and supply on 14.
(pinout "hex-inverter-schmitt"
  (pin 1  "1A")
  (pin 2  "1Y")
  (pin 3  "2A")
  (pin 4  "2Y")
  (pin 5  "3A")
  (pin 6  "3Y")
  (pin 7  "GND")
  (pin 8  "4Y")
  (pin 9  "4A")
  (pin 10 "5Y")
  (pin 11 "5A")
  (pin 12 "6Y")
  (pin 13 "6A")
  (pin 14 "VCC"))
