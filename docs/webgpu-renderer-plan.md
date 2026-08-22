# WebGPU board renderer — prototype plan

Branch: `claude/webgpu-renderer-spike`. Goal: prove that a GPU-native renderer
makes the `/pcb-layout` scene cost **constant in zoom** — the Canvas2D path's
remaining wall is raster fill-rate (a 0.3 mm track is ~2 device px at fit zoom
and ~25 px zoomed in, so the browser fills ~10x the pixels for the same
copper; pour washes cover the whole screen at every zoom). Every JS-side cost
has already been cached away (Path2D batches, glyph sprites, culling, zero
forced-layout reads — see `scripts/pcb_viewer_bench/`); what remains is the
paint engine itself, and the answer to that is triangles, not WASM (Canvas2D
is already native code; a WASM software rasterizer would be slower than the
GPU path it replaced).

## Why this shape

- **Fill-rate with AA is what GPUs do.** Every scene element the editor draws
  is one of four analytic shapes: a capsule (track segment, silk stroke), an
  annulus (via), a rounded rect / small polygon (pad), a polygon-with-holes
  (pour). All four render as instanced quads with a signed-distance fragment
  shader — resolution-independent AA, one draw call per class per layer, no
  per-zoom cost growth.
- **Pan/zoom becomes a uniform update.** The whole board is static vertex
  data; the camera is one mat3 uniform. A pan frame = write 12 floats +
  replay a pre-recorded **render bundle**. This is the endgame the overscan
  buffer approximates with pixels.
- **The scene graph never moves.** All invalidation seams already exist and
  are battle-tested by the Path2D caches: `copperTouched()` / `drawRoute()` /
  `onZonesChanged()` are exactly the instance-buffer rebuild triggers, and the
  copper-gesture bypass (`segdrag`/`viadrag`/`dtrace`) maps to "sub-write the
  touched instances or fall back".

## Architecture

Three stacked surfaces, only the bottom one new:

```
┌──────────────────────────────────────┐
│ SVG (unchanged): DRC markers, loop   │  pointer events, tooltips
│ overlays, marquee, outline bands     │
├──────────────────────────────────────┤
│ 2D canvas (unchanged, thinned):      │  text sprites, hover/selection
│ labels, flash, insp, draw preview    │  overdraw, anything cursor-anchored
├──────────────────────────────────────┤
│ WebGPU canvas (new): copper, pours,  │  static world geometry,
│ pads, silk, grid, board substrate    │  camera = one uniform
└──────────────────────────────────────┘
```

Hit-testing, gestures, and every mutation path are untouched — they are
already pure JS over the `PCB` model, not the canvas.

### Pipelines (WGSL)

| class | geometry | shader | status |
|---|---|---|---|
| tracks + silk strokes | instanced quad per segment `{x1,y1,x2,y2,w,layer,color}` | capsule SDF, round caps, AA feather = 1/kk | M1 (tracks) |
| vias | instanced quad per via `{x,y,r_outer,r_hole,color}` | annulus SDF | M1 |
| pads | instanced quad per pad `{cx,cy,hw,hh,rot,shape,color}`; polygon pads fan-triangulated | rounded-rect / circle SDF; poly pads plain triangles | M1 |
| pours / zone fills | triangle fan per RING (outer + each hole), static vertex buffer + one cover quad per area | stencil INVERT (colour off) then a covering quad at `stencil != 0`, `REPLACE` 0 | M2 |
| grid dots | full-screen triangle | procedural: distance to the nearest `X(n·g)` in svg units — exact at every zoom, zero geometry | M2 |
| board substrate / outline | triangulated once | flat | not yet |

Draw order replays `paintScene` bottom-up — grid, pour fills, pads + bores,
then `trackLayerOrder()` (stack bottom-up, active layer last), then vias —
with the `layerAlpha`/`pourLayerFade`/`pourForeignFade` ladder resolved
JS-side into per-draw alphas. Net-colours mode is a per-instance colour baked
through pcb_board.js's own expressions, so toggling it is a buffer rebuild
(cheap, and it cannot drift from the 2D rule the way a second palette would).

### Pours: stencil even-odd, not a triangulator (M2 deviation)

**The original plan here was Zig-side ear clipping; M2 does not do that, and
should not.** A pour is a polygon *with holes* whose 2D twin is exactly
`ctx.fill(path, "evenodd")` — and even-odd is a rasterizer rule, not a
tessellation. The standard GPU answer reproduces it with no triangulator at
all, on either side of the wire:

1. **Stencil pass.** Every ring of the area — the outer polygon AND each hole
   loop — is drawn as a triangle fan from *its own* first vertex, with colour
   writes off and the stencil op `INVERT` on every fragment. A fan of a concave
   ring covers the outside an even number of times and the inside an odd
   number; a hole ring inverts its interior a second time. What is left odd is
   precisely the even-odd interior — for any polygon, convex or not, holes
   included.
2. **Cover pass.** One quad over the area's bounding box, stencil compare
   `not-equal` against reference 0, stencil op `REPLACE` (with that same 0) on
   pass. It paints the fill AND clears the stencil behind itself, so the next
   area needs no clear of its own; the attachment is cleared once per frame.

Cost: a fan is `3(n−2)` vertices for an `n`-vertex ring (barracuda: 32 areas,
14 778 vertices total, ~118 KB — baked once per pour edit), two draws per area,
zero CPU geometry work per frame. The only per-frame write is each area's
alpha, which the pour-opacity slider moves.

The one price is a **stencil8 attachment on the render pass**, and a render
pass and a pipeline are compatible only when their depth-stencil formats
match — so *every* pipeline in the file declares `{format:"stencil8",
depthWriteEnabled:false, depthCompare:"always"}`, not just the two pour ones.
Getting that wrong is a runtime validation error reported asynchronously (a
blank canvas, no exception); `scripts/pcb_gpu_check/run.js` asserts it on every
pipeline.

Pad polygons keep their client-side fan with the documented convex caveat —
they are a handful of vertices each, and the stencil path above is the drop-in
fix if a real board ever ships a concave custom pad.

### Text stays hybrid

Glyph rendering on GPU (atlas + instanced quads) is real work and fix E already
made 2D-canvas labels cheap (sprite blits). Keep labels/adornments on the 2D
overlay indefinitely; revisit only if profiling says the overlay is the wall.

## Milestones

- **M1 — spike (this branch, first session).** `?gpu=1` opt-in on
  `/pcb-layout`: WebGPU context on a new canvas under the existing one; render
  tracks + vias + pads with layer colors; camera uniform driven from `setVB()`;
  frame-time HUD. Exit criterion: barracuda at max zoom pans at display
  refresh with p95 frame < 3 ms on the dev box, and the fallback (no
  `navigator.gpu`) leaves the page byte-identical to today.
- **M2 — the static under-layer (done).** Pour fills (stencil even-odd, above),
  the procedural grid, net-colours as baked per-instance colour, and the draw
  order fixed so pours sit UNDER the copper instead of over it (M1 left them in
  2D, on top). The `pourOp`/`layerAlpha`/`pourForeignFade` ladder is resolved in
  pcb_board.js and handed over as numbers, including the per-part foreign-side
  fade that pads and bores now carry via a split by owning-part side. Silk,
  board substrate and review-focus dimming stay on 2D. Exit: visual A/B vs
  Canvas2D at 3 zoom levels shows no regressions beyond documented AA
  differences.

- **M3 — interaction parity (done).** Every editing gesture now stays on the
  GPU; before this the renderer quietly reverted to the 2D scene the moment the
  user touched anything.

  1. **Copper gestures** (`segdrag` / `viadrag` / the draw tool / a
     copper-carrying rigid-group drag). These mutate `PCB.tracks`/`PCB.vias` in
     place per pointermove with no cache to drop — the 2D per-item painters
     re-read the model every frame, which is exactly why `cuBatchOn` refuses
     them. The GPU's answer is the opposite one: a one-line
     `gpuCuEdit()` at every mutation site marks the copper buffer, and the
     rebake happens once on the next rendered frame. Measured on barracuda
     (522 tracks / 60 vias) through the check harness: **~60 µs per rebake**,
     against a frame budget of 16 ms. So `gpuLive()` no longer borrows
     `cuBatchOn(null)` — it spells out its own, much shorter, refusal list.
  2. **Part drags retire the drag cache.** The static-scene bitmap is opaque and
     canvas-sized, so it necessarily hides the WebGPU surface beneath it —
     keeping it meant falling back for the whole gesture. Instead
     `PCBGpu.rebuildParts(excludeSet)` bakes the movers OUT of the pad / poly /
     bore buffers **once** when the drag becomes live, and the 2D canvas draws
     those parts (and only those) on top, with pad fills and bores ON. The
     remainder the 2D side still pays per frame is what fixes B–F already made
     cheap: no copper, no pad fills, culled, sprited labels. The exclusion is
     re-stated by the frame whenever `partsExclIs(mov)` goes false — a live `R`
     press commits poses through `setT`, which rebuilds the whole board — so a
     mover can never reappear baked under its own 2D copy. Drag end is the
     existing `dragCacheDrop()` seam: `rebuildParts()` with no argument.
  3. **Marquee copper selection.** Its purple fringe moves ABOVE the copper on a
     GPU frame instead of under it — the one deliberate visual difference of
     this milestone, and arguably the better read (the halo is no longer
     partly over-painted by the track it marks). `paintTracks` draws the two
     fringes and then bails; everything else in that pass is the GPU's.

  The 2D build is untouched: every change sits behind `gpuScene` / `gpuOn` /
  `gpuLive()`, and `scripts/pcb_viewer_bench/run.js` reports **zero op drift**
  across all four op scenarios and every pass counter.

  **What still falls back to the whole-frame 2D scene** (`gpuLive()`), and why —
  four things, none of them an editing gesture: the fab-preview surface
  (`?review=1` — a different palette and per-object mask logic), an active
  review focus (per-object dimming), the exclusive replay overlay
  (`ovExclusive`), and the single combination of an opaque pour with
  staged/unplaced parts (a per-part exemption from the foreign-side fade that
  the side-split pad grouping cannot express).
- **M4 — rollout.** Default-on with auto-fallback (adapter absent,
  Implemented 2026-08-06: GPU_REQ = navigator.gpu present && not ?gpu=0; HUD
  moved behind ?fbench=1; Canvas2D path verified byte-identical in non-WebGPU
  environments via the Node bench.
  `device.lost`), flag removed, Canvas2D path kept as the permanent fallback
  (older Safari/Firefox ESR; the server-side PNG renderer is unaffected).

- **M5 — retained command stream (done).** The static pipeline/buffer/bind-group
  sequence is recorded as a `GPURenderBundle` and replayed on ordinary frames.
  Pan and zoom now write the camera uniform and execute one bundle; appearance
  changes keep the bundle whenever only uniform alpha/grid values changed.
  Geometry rebuilds, layer-order changes, and a pour crossing zero opacity
  invalidate it. The immediate render-pass encoder remains the compatibility
  fallback and the fake-device gate executes the bundled path, including a
  second-frame assertion that it replays every draw without re-recording.

## Measurement (the honest kind)

The Node bench can't see GPUs. Add an in-page harness to this branch:
`?fbench=1` runs a deterministic camera path (fit → zoom to k=8 → 3 pan
sweeps → zoom out) via the real `setVB` path, records per-frame
`requestAnimationFrame` deltas, and dumps p50/p95/max to the console and a
`window.__fbench` blob. Run it on BOTH renderers (`?gpu=1` vs default) on the
same board for the A/B. This harness is worth building in M1 *before* the
first pipeline — it also gives the Canvas2D baseline numbers this plan's
claims get judged against.

The path now includes short dwell points at fit, maximum zoom, the seek jump,
and all three pan turnarounds. They make the run inspectable and expose delayed
driver/compositor stalls before motion resumes; each is recorded as `pause`, so
the intentional wait never enters the zoom/pan percentile report.

## Correctness (the part a GPU hides)

A WebGPU validation error is reported **asynchronously**: a wrong pipeline
state, a wrong instance offset or a pass/pipeline mismatch produces a subtly
wrong board — or a blank one — and never an exception to catch. So the renderer
carries its own standing gate:

```bash
node scripts/pcb_gpu_check/run.js <pcb_blob.json>       # ~22k assertions, ~1 s
```

It loads the REAL `pcb_gpu.js` against a fake `navigator.gpu` that records
every pipeline descriptor, buffer write and draw, then checks: every baked
instance against an independent 3×3 affine replay of the Canvas2D transform
chain (over a synthetic matrix of every rotation × side × pad-rotation, and
over a real board blob); every draw range tiling its buffer exactly; the
stencil pair's fan counts, cover containment and stencil ops; that every
pipeline declares the pass's stencil8 format; the draw ORDER (grid → pours →
pads → copper → vias); WGSL sanity (ordered `smoothstep` edges, the annulus
`rInner > 0` guard, every vertex layout matching its entry point's
`@location` list); that pcb_board.js's GPU-side colour/alpha ladders are the
*same text* as its 2D ones; and — from M3 — the two mutations of an already
baked buffer, each re-checked by re-running the whole instance+range gate over
the rebaked frame: a **drag exclusion** (`rebuildParts(excl)`, over a 1-part,
an 8-part and an all-parts set, plus the restore) and a **copper gesture** (a
track dragged the way `segMove` drags it, then `rebuildCopper` + one frame),
with the unmarked frame asserted STALE so the necessity of `gpuCuEdit()` is
itself under test. It also prints the per-rebake JS cost. Run it after any
change to either file.

The other half of the gate is `scripts/pcb_viewer_bench/run.js`, which must show
**zero op drift** with the GPU off — the flag is opt-in, so the shipped page has
to be byte-identical.

## Risks / open questions

- **Browser support:** Chrome/Edge stable, Firefox recent, Safari 18+. The
  fallback must stay first-class forever; this is an enhancement tier, not a
  replacement.
- **Device loss** (GPU reset, tab backgrounding on some drivers): handle
  `device.lost` → tear down → fall back to Canvas2D silently.
- **Color fidelity:** Canvas2D draws in sRGB with its own AA; SDF feathering
  will differ at edges by design. Same acceptance stance as the Path2D wave's
  compositing notes: document, don't chase byte-identity.
- **The 2D overlay still repaints on hover** — fix E made that cheap, and M3
  leaned on it further: a drag frame now renders the static board's courtyards,
  silk and ref-des labels in 2D over the GPU surface every frame instead of
  blitting them from a bitmap. That remainder is a strict subset of the full 2D
  scene the Node bench times at 0.68 ms on barracuda — it drops the copper and
  the pad fills and keeps the culling and the label sprites — so the headroom is
  there, but it is the pass to watch at high dpr. If the overlay ever becomes
  the wall, group boxes and courtyards are the next classes to move.
- **Blend order for translucent layer washes** must reproduce the ladder
  exactly (foreign-layer dimming, pour opacity ramp). M2's answer is that the
  ladder is never re-implemented: `gpuState()` evaluates pcb_board.js's own
  expressions and hands over resolved numbers, and the check script greps that
  the GPU-side and 2D-side spellings are identical text. What is still worth a
  side-by-side screenshot: pour RIMS now stroke over neighbouring areas' fills
  (fills all moved below), and the GPU grid stays visible during a gesture
  where the 2D one hides itself to dodge a raster cost the GPU doesn't have.

## Bring-up notes

- Branch from `main` AFTER the overscan/text-sprite wave merges, or rebase —
  fix E's sprite cache and cull seams are assumed by M3.
- The WebGPU canvas must live under the SVG inside `sceneShell` and follow
  the same `svgMetrics` sizing scenePaint uses; `setVB()` is the single
  camera-write seam.
- Keep every GPU file self-contained in `src/serve/assets/` (WGSL as JS
  template strings — the asset pipeline is @embedFile, no build step).
