# Barracuda route-space A/B — 2026-08-13

This experiment changes only the free-space representation used to direct
ordinary same-layer terminal trees. Net ordering, authored policy, direct
synthesis, exact segment acceptance, rip-up, fine rescue, cleanup, and the
post-route connectivity/DRC gates remain the existing router. The new `field`
mode rasterizes the live board with the pour engine's signed-margin primitives
at 0.05 mm, searches that field with margin-aware A*, string-pulls the result to
off-grid chords, and falls back to the lattice whenever the field or the
router's exact clearance oracle declines it.

## Scoring

Connectivity and zero fabrication-error DRC are hard gates. Inside those gates,
the existing v1 scalar remains:

`1000 * completion - 2 * vias - 0.1 * trace_mm - 50 * DRC_errors`

The benchmark now also reports geometry dimensions that the scalar cannot see:
bends, core-DRC-clear removable bends and their avoidable detour, micro-jogs,
non-octilinear segments, the shortest segment, and an ordered-copper hash.
Lower is better for every geometry count; the hash is only a determinism check.

## Reproduction

Both modes used the same saved Barracuda placement, Debug artifact, route-plan
seam, sub-circuit seed decision, and timing instrumentation:

```sh
zig-out/bin/netlisp bench-route \
  --project-dir /home/epentland/ai/canopy/eda/projects/designs \
  --route-space lattice --json --breakdown barracuda

zig-out/bin/netlisp bench-route \
  --project-dir /home/epentland/ai/canopy/eda/projects/designs \
  --route-space field --json --breakdown barracuda
```

## Result

| Metric | Lattice | Field | Delta |
| --- | ---: | ---: | ---: |
| Routed nets | 92/108 | 94/108 | +2 |
| DRC errors | 0 | 0 | 0 |
| v1 score | 684.350 | 696.322 | +11.972 |
| Track segments | 630 | 617 | -13 |
| Vias | 41 | 40 | -1 |
| Trace length | 855.02 mm | 940.48 mm | +85.46 mm |
| Bends | 433 | 433 | 0 |
| Core-DRC-clear removable bends | 363 | 343 | -20 |
| Removable detour | 46.2515 mm | 43.0989 mm | -3.1526 mm |
| Micro-jogs | 86 | 79 | -7 |
| Non-octilinear segments | 115 | 108 | -7 |
| Wall time | 192.4 s | 325.2–330.6 s | +69–72% |

The field recovered `LOCK_DET`, `SPI_MOSI`, `loop_amp/LF_FB_RC`, and
`loop_amp/LF_OUT`; it regressed `SPI_SCK` and `V_12V`, for a net gain of two.

The field result repeated exactly: both runs produced 94/108, the same open-net
set, all the same copper and shape counts, 288 field queries, 246 committed
field legs, 10,773,491 A* expansions, and copper hash
`5441270663429992225`. Only wall time changed (330.6 s to 325.2 s). The lattice
fingerprint was `10707986708699314253` and its copper counts matched the
pre-change baseline exactly.

## Decision

The experiment validates the premise: the higher-resolution, pour-derived
free-space view finds corridors the lattice misses and reduces several visible
artifact measures without changing the router's policy or acceptance rules.
It is not yet suitable as the default. Rebuilding a whole-board field per leg
cost 139.8–140.1 s by itself, and the winning route is 10% longer despite the
better completion and lower artifact counts.

Keep `lattice` as the default and `field` as an opt-in A/B. The next promotion
gate is a cached or incrementally updated per-layer/per-clearance margin field
(or bounded query windows) that preserves the deterministic 94-net result while
removing most of that 140-second field phase. Route-length cost also needs an
explicit limit rather than being hidden by the completion-heavy v1 scalar.

## Full-board cache optimization

The follow-up implementation retained the whole-board 0.05 mm field and added
three exact reuse levels for one routing run:

1. immutable outline/pad/zone rasters keyed by their complete effective
   geometry and clearance;
2. the most recent static-plus-live-copper field for consecutive endpoint
   queries; and
3. compact path answers keyed by the complete field plus endpoints.

Tracks and vias are still stamped afresh unless the complete live-copper key
matches. No query is cropped, resolution is unchanged, and every accepted chord
still passes through the router's exact clearance oracle. A 128-bit key is used
for lookup; the exact oracle remains the collision-safe acceptance boundary.

The final Debug run was behavior-identical to both original field runs: 94/108,
zero DRC errors, the same open-net set, all copper/shape metrics unchanged, and
copper hash `5441270663429992225`.

| Runtime metric | Original field | Cached field | Improvement |
| --- | ---: | ---: | ---: |
| Internal wall time | 325.2–330.6 s | 214.7 s | 34.0–35.1% |
| Field phase | 139.8–140.1 s | 29.9 s | 4.68x |
| A* expansions executed | 10,773,491 | 7,657,860 | 28.9% |

Of 288 field requests, 58 reused a complete query, 114 reused a fully stamped
live field, 80 reused the immutable base, and only 36 rebuilt that base. The
same-binary lattice control took 190.5 s, so field's former 69–72% premium is
now 12.7%. `/usr/bin/time -v` measured 1,877,920 KiB peak RSS for field versus
1,789,440 KiB for lattice: +88,480 KiB, or +4.9%.

The optimized field is viable as a primary director when completion and cleaner
local geometry outrank runtime and total copper length. It is not strictly
better in every dimension: it still emits 940.48 mm versus lattice's 855.02 mm
(+10.0%). Keep the shipping default unchanged until either route length is
brought within an explicit budget or product policy explicitly values the two
additional completed nets above that length and 12.7% runtime premium.

## Net and trace-length follow-up

The raw length comparison above mixed two different things: useful copper on
completed nets and fragments left by nets the connectivity oracle still called
open. It also compared boards that completed different net sets. The benchmark
now reports `connected_trace_mm`, `open_trace_mm`, and per-net trace/via totals
so those cases can be separated.

The field path now has four quality stages around the unchanged router:

1. its exact segment oracle greedily pulls the raster path to the farthest
   legal waypoint;
2. field-directed whole-board gloss accepts continuous exact-clearance chords
   instead of preserving a lattice quantization detour;
3. one bounded residual pass retries oracle-open nets while completed copper is
   frozen, then deletes only generated fragments for nets that remain open; and
4. hierarchical seeded/plain A/B candidates are finished only after the winner
   is selected, including the blocking diagnostic surface.

| Metric | Lattice control | Final field | Delta |
| --- | ---: | ---: | ---: |
| Routed nets | 92/108 | 96/108 | +4 |
| DRC errors | 0 | 0 | 0 |
| v1 score | 684.350 | 729.148 | +44.798 |
| Track segments | 630 | 592 | -38 |
| Vias | 41 | 33 | -8 |
| Total trace | 855.02 mm | 937.41 mm | +82.39 mm |
| Connected-net trace | 851.37 mm | 937.41 mm | +86.04 mm |
| Open-net fragments | 3.65 mm | 0.00 mm | -3.65 mm |
| Bends | 433 | 399 | -34 |
| Core-DRC-clear removable bends | 363 | 313 | -50 |
| Removable detour | 46.2515 mm | 39.4386 mm | -6.8129 mm |
| Micro-jogs | 86 | 66 | -20 |
| Non-octilinear segments | 115 | 143 | +28 |
| Wall time | 195.6 s | 234.5 s | +19.9% |

The total-length delta is almost entirely the different completion set. On the
91 nets both results complete, lattice uses 768.00 mm and field uses 771.54 mm:
only +3.54 mm (+0.46%). Field uniquely completes `LOCK_DET`, `SPI_MOSI`,
`RF1_DIV_IN`, `loop_amp/LF_FB_RC`, and `loop_amp/LF_OUT`, totaling 165.87 mm.
Lattice uniquely completes `SPI_SCK`, totaling 83.37 mm. Those unique nets plus
the 3.54 mm common-net delta account for the full 86.04 mm connected-copper
difference.

Against the cached 94-net field result, the final field result completes two
more nets while shortening total copper by 3.07 mm, removing 25 segments, 7
vias, 34 bends, 30 removable bends, 3.6603 mm of removable detour, and all
34.86 mm of failed-net fragments. A lower clearance-bias trial preserved 96
nets but did not improve measured length; it added one segment and one bend and
raised field expansions by 6%, so it was rejected.

The field director is therefore better on the existing scalar, completion,
failed-copper hygiene, vias, segment count, bends, removable detour, and
micro-jogs. It is still not literally better in every dimension: it takes 19.9%
longer, completes a different net set (losing `SPI_SCK`), uses 0.46% more copper
on common completed nets, and deliberately emits more arbitrary-angle segments.
The shipping default remains `lattice`; promoting `field` is now a product
trade-off rather than a hidden trace-accounting problem.

## Bounded joint-residual follow-up

The next experiment targeted the 12 nets still open in the 96-net field result
without changing the router or its signed-margin path director. After the safe
failed-only retry, one deterministic transaction groups at most three open nets
whose gap corridors name common blockers, vacates at most six cheap generated
routes (96 copper elements), and invokes the existing field router once. Ground,
plane/pour, differential, max-frequency RF, fenced, and caller-retained nets
cannot be seeds. The optional transaction is skipped entirely when caller-
retained vias are present because the router-neutral via surface cannot carry
saved RF-fence provenance. It is accepted only when the old open set becomes a
strict subset, the normal connectivity/DRC gate passes, and every frozen track
and via is still present with multiplicity.

| Metric | Current field baseline | Joint-residual field | Delta |
| --- | ---: | ---: | ---: |
| Routed nets | 96/108 | 97/108 | +1 |
| DRC errors | 0 | 0 | 0 |
| v1 score | 731.038 | 734.153 | +3.115 |
| Track segments | 538 | 550 | +12 |
| Vias | 37 | 39 | +2 |
| Connected trace | 838.51 mm | 859.95 mm | +21.44 mm |
| Open-net fragments | 0.00 mm | 0.00 mm | 0 |
| Bends | 360 | 370 | +10 |
| Removable bends | 285 | 290 | +5 |
| Removable detour | 34.5216 mm | 34.1169 mm | -0.4047 mm |
| Debug wall time | 251.2 s | 260.7 s | +3.8% |

The additional completed net is `EN_BUCK6V`: 21.4239 mm and two vias. No
previously completed net opens. Apart from two small blocker redraws
(`adf4159/ADF_TXDATA_1V8` +0.0656 mm and `buck_6v/FB` -0.0485 mm), the previous
completed-net copper is unchanged. The final ordered-copper hash is
`5703259234663676353`; the baseline hash is `12420265011571290762`.

The first working joint implementation took 270.5 s. Scoping its connectivity
analysis to the already-known open names and removing a rounded-outline fast
path that never applied to this board reduced the measured final run by 9.8 s.
Two exact-output hot-path experiments were also measured independently. SIMD
source discovery retained the baseline hash and measured 250.7 s versus
251.2 s, too small to claim beyond noise but safe to retain. A full-lattice
generation-stamped goal table also retained the hash but regressed to 263.4 s
and raised scratch traffic, so it was removed. The query cache now charges
retained path payloads to its immutable-raster memory ceiling; its single live
raster remains independently capped at three million cells (12 MB). Barracuda
stays below those bounds, so its cache hit behavior is unchanged.

This is a net completion win, not a universal geometry win: it deliberately
spends 21.44 mm, two vias, and ten bends to remove one airwire. Under the
established completion-heavy score the trade is positive, and the bounded
3.8% runtime premium is substantially smaller than the field director's earlier
cost. A product mode that values shortest copper above completion can still
decline the retry by using one-shot effort or the lattice route space.
