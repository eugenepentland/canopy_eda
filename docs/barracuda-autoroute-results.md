# Barracuda autoroute implementation results

Date: 2026-07-24

> **Historical record:** all ReleaseSafe values below describe the 2026-07-24
> run. Current internal reproduction, development, and benchmarking use
> pinned-master self-hosted Debug; only deployment creates ReleaseSafe.

This records the implementation and verification work for
`~/ai/barracuda-autoroute-plan.md`. All measurements below use a fresh
ReleaseSafe whole-board route at the hand-blessed placement, with no saved
track or via copper supplied to the router.

## Outcome

The best reproducible one-shot result is **87/90 nets** in 85.61 seconds. A
scoped follow-up routes `TXDATA_ADF` in 1.38 seconds and produces an 88-net
copper state. A fresh one-shot 90/90 route was not achieved.

| Measurement | Plan baseline | Final one-shot | Scoped follow-up |
| --- | ---: | ---: | ---: |
| Routed nets | 81/90 | 87/90 | 88/90 combined |
| Track segments | 302 | 423 | 418 |
| Vias | 46 | 74 | 82 |
| Trace length | 741 mm | 912.46 mm | not remeasured |
| Runtime | about 95 s | 85.61 s | +1.38 s |
| DRC errors | not split in plan | 11 | 11 |
| DRC warnings | not split in plan | 33 | 27 |

The final one-shot failures are:

- `SPI_SCK` (`search_budget`)
- `TXDATA_ADF` (`order_congestion`)
- `SPI_LMX_CSN` (`order_congestion`)

Every RF net remains routed. Every authored wave is complete except
`control-clock-escape` (0/1) and `control-data` (7/9).

The DRC error target is not met. The result is therefore an engine/design
improvement and investigation branch, not a production-ready routed board.

## Work completed

### In2 power pours

Three fitted user zones now occupy `In2.Cu` for `V_6VA`, `V_3V3A`, and
`V_3V3_LMX`. Placement and saved tracks/vias are unchanged. The diagnostic,
PNG, browser route, MCP route, and DRC paths now share the same shown user
zones and router-ready zone sources. A forced verification Gerber package
contains the non-empty `barracuda-In2_Cu.g3` layer.

The final route connects `V_3V3A`, `V_3V3_LMX`, and
`ldo_3v3_lmx/EN_UV`.

### Wave ordering and targeted guides

The control wave was split into targeted chip-select, data, lock, MOSI, and
clock stages. Guides were added for `SPI_ADF_CSN`, `LOCK_DET`, `SPI_MOSI`,
`SPI_SCK`, the internal ADF clock, and LMX VTUNE. Regulator feedback and
enable stubs precede their pours, and `V_1V8A` routes last as its own rail
class.

This routes the plan's original failures `SPI_MOSI`, `SPI_ADF_CSN`,
`adf4159/SPI_ADF_SDI_1V8`, `LOCK_DET`, and `V_1V8A`, while keeping
`adf4159/REFIN_1V8` connected.

### Router capability

The router now:

- classifies residual grid-quantization failures with a bounded live-grid
  flood before attempting a fine retry;
- retries eligible batch and scoped residuals in fine windows, with a capped
  quarter-pitch whole-board fallback;
- retries a failed authored guide immediately, before lower waves occupy its
  corridor;
- builds a shared, clearance-aware waypoint trunk for multi-terminal nets and
  falls back to the ordinary maze if exact guided copper is invalid;
- prefers a legal via-in-pad connection into an excluded-layer same-net pour;
- compares equal-count rip-up outcomes by authored wave priority before total
  copper length.

These changes route `lmx2595/LMX_VTUNE` on the fresh whole-board run without
moving parts or reusing the hand route.

## 90/90 investigation

The remaining SCK/LMX cluster was tested constructively, not only by increasing
budgets. Removing the exact union of 14 diagnosed blockers lets
`SPI_LMX_CSN` route, then lets `SPI_SCK` route. Restoring the displaced nets
sequentially finishes at 82/90; restoring the remaining eight as one scoped
batch accepts only one and finishes at 83/90. In other words, paths for both
remaining control nets exist, but they displace more previously completed nets
than they recover.

Additional guided and expanded-budget variants ran to the three-minute class
without improving the one-shot 87/90 result. The best retained next step is a
global negotiated-congestion or track-shoving capability for this cluster,
rather than another local budget increase.

## Relative guide vocabulary follow-up

Route waves may now replace absolute `(at X Y "layer")` points with
placement-relative `(guides …)` entries:

- `(between-pins "REF" "PIN" "REF" "PIN" "layer")` uses the midpoint of two
  placed pad centres;
- `(escape-from "REF" "PIN" "layer")` exits one clearance beyond the named
  pad's copper toward its nearest part edge;
- `(beside "REF" north|south|east|west "layer")` runs just outside the named
  courtyard side.

Resolved guides follow part moves, rotation, and board side, then snap to the
same 0.1 mm placement grid as the authored layout. Unknown refs, pins, and
layers become stable plan warnings.

All coordinate waypoints on the six targeted Barracuda waves were replaced
with relative pin landmarks. The live plan resolves the four single-point
cases to the original grid points exactly: VTUNE `143.1,93.6`, ADF CSN
`175.2,106.7`, LOCK_DET `176.0,107.2`, and SCK `187.3,109.3`. The three MOSI
points likewise resolve to `184.1,99.1`, `176.0,104.8`, and `176.0,105.3`;
the internal ADF clock resolves to the same routing neighborhood at
`162.4,107.9`.

On the current ReleaseSafe reproduction body, the exact-coordinate control
and all-relative plan both route 85/90. On the six migrated traces both route
VTUNE, ADF CSN, LOCK_DET, MOSI, and the internal ADF clock; both leave
`SPI_SCK` unresolved. The all-relative run completed in 102.01 seconds versus
118.04 seconds for the exact control. The wider five-net failure set is not
identical—the relative run trades `adf4159/SPI_ADF_SDI_1V8` for
`adf4159/ADF_CE`—so this establishes equivalent count and migrated-trace
behavior, not byte-identical whole-board copper.

## Verification

- ReleaseSafe build and Guardian gate: pass.
- Full ReleaseSafe `zig build test`: pass.
- `git diff --check` and Zig format check: pass.
- `netlisp check barracuda`: 34 known design/library findings, including the
  five documented `missing_requirements` errors and the existing U23
  requirement error.
- Forced Gerber verification ZIP: valid, 15 files, including a 7.5 KB
  `In2.Cu` layer.
- Fresh engine-only full route: 87/90 in 85.61 seconds.
- Scoped `TXDATA_ADF` follow-up: 1/1 in 1.38 seconds.
