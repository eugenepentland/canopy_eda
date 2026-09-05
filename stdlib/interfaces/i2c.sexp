;; Two-wire I²C. Both lines are open-drain and driven from either end, so both
;; are `bidi` whichever role a block plays — an I²C bundle is unchanged by
;; `(role controller)`.
(interface i2c "Two-wire I²C, open-drain, target perspective"
  (signal SDA bidi data)
  (signal SCL bidi clock))
