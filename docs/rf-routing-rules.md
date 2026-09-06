# RF routing from pad directions

RF routing starts with the shape of the connection, before searching a grid.
For each terminal, let **p** be the pad centre and **d** its outward unit vector.
Its launch ray is **p + t d**, with **t ≥ 0**. Both vectors point away from their
components; they describe how copper attaches, not signal propagation direction.

For a two-terminal passive, the line between its two lands defines the axis.
The two ends point in opposite directions. Component rotation and bottom-side
mirroring transform that axis exactly, so a 45° blocking capacitor launches at
45°, even if its footprint origin is asymmetric. A long peripheral IC land uses
its own rotated axis, with the outward sign chosen from its package position.

The routing order is:

1. **Facing, collinear pads:** one straight segment.
2. **Forward-intersecting rays:** extend both rays to their intersection. This
   gives one corner, whether the relative angle is 90°, 45°, or another angle.
   An intersection behind either pad cannot justify reversing its launch.
3. **Offset rays:** extend both launches and join them with one segment. Compare
   legal candidates by the common fillet radius they can accommodate, then by
   total length. Reject backtracking and large detours. A perpendicular bridge
   is not automatically best: two tiny quarter circles can be worse than a
   diagonal bridge with two broad, shallow arcs.
4. **Layer transition:** when pad centres align on different faces, first try
   straight copper to one through via on that line, then straight copper on
   the destination face. Each leg and the barrel must pass the normal clearance
   checks. This also permits the legal under-connector launch seen at Black
   Canyon's Samtec connector; package-centre radial direction does not veto it.
5. **Obstacles:** if the simple constructions cannot clear the board, retain
   the existing routing fallback. Never relax copper, hole, keepout, layer, or
   via-count constraints merely to obtain a preferred shape.

Round each valid corner with the largest tangent fillet its legs and surrounding
copper permit. Adjacent corners share their connecting segment without overlap.
The same rule applies to 45° and 90° corners. The configured minimum bend radius
still controls under-radius findings; a large desired radius does not prove
clearance, so the smoother checks the emitted geometry and shrinks when needed.

An explicitly authored `(escape MM)` remains the ray construction's minimum
straight launch. The implicit 1 mm default remains a maze preference, but analytic
RF joins and their fillets use a half-trace-width launch instead of forcing a
short passive connection to detour just to spend that heuristic distance.

These are deterministic preferences, not a proof of a globally optimal route.
The offset construction searches a bounded 17-by-17 set of launch lengths;
clearance can require a smaller fillet or an obstacle-routing fallback. Persisted
candidates still require physical connectivity and DRC checks after smoothing,
tapers and cleanup.

Black Canyon exercises the cases directly: `RF_IN` and `RF_OUT` are straight
through-via transitions, `RF_A1_OUT` is an offset pair of horizontal launches,
and `RF_HPF1_IN` joins a capacitor's 45° launch to a horizontal filter input.
