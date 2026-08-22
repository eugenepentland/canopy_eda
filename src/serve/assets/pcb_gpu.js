// pcb_gpu.js — WebGPU board renderer for /pcb-layout (M3, ?gpu=1).
//
// WHAT IT OWNS: the grid dots, copper-pour FILLS, pads (+ drill bores), copper
// tracks and vias (+ hole punches) — i.e. the whole static under-layer of the
// scene: the `substrate`, `plane_fills`, `parts` and `copper` stages of the
// canonical paint order (src/render_order.zig), handed to it by name per frame
// in `st.stages` rather than hard-coded here. Everything else on the page —
// pour rims/labels/keepouts, silk, courtyards, airwires, labels, every overlay
// and every gesture — stays on the 2D canvas ABOVE this one and is untouched.
// See docs/webgpu-renderer-plan.md.
//
// WHY: the Canvas2D path's remaining wall is raster fill-rate, which grows with
// zoom (a 0.3 mm track is ~2 device px at fit and ~25 px zoomed in). Every class
// this file draws is an analytic shape — capsule, annulus, rounded rect — so it
// renders as one instanced quad with a signed-distance fragment shader:
// resolution-independent AA, a handful of draw calls, and a pan/zoom that is a
// 64-byte uniform write rather than a re-raster. The two classes that are NOT
// analytic get the two techniques that need no triangulator: the grid is
// procedural (a full-screen triangle that computes its own dots), and a pour is
// stencil INVERT + cover, which reproduces `fill(path,"evenodd")` exactly from
// nothing but a triangle fan per ring.
//
// INVARIANTS this file is written to keep:
//  · It never touches board state. pcb_board.js hands it read-only structures at
//    init and a fully-resolved policy blob per frame (which layers, at which
//    alpha, in which order) — every alpha ladder, visibility rule and draw order
//    stays in pcb_board.js, where it already lives and is already tested. The
//    per-object COLOUR rules live there too, reached through the o.trackColor /
//    o.viaColor / o.padColor hooks, so net-colours mode cannot drift between the
//    two renderers.
//  · Geometry is baked in SVG UNITS (u=(mm−MX+M)·S), the same space the 2D
//    canvas transform works in, so the camera uniform is literally `vb` and the
//    two renderers can never disagree about where a thing is.
//  · Failure is always silent and total: no navigator.gpu, no adapter, a lost
//    device or any throw ⇒ active=false and the canvas is removed, after which
//    the page is byte-identical to the 2D-only build.
//
// Buffers are rebuilt WHOLE (no sub-writes yet) and lazily: rebuildCopper /
// rebuildParts / rebuildPours only set a dirty flag, so pcb_board.js can call
// them from broad seams without a cost per call, and a burst during a drag
// collapses into one rebuild on the next frame. That laziness is what lets the
// copper GESTURES stay on the GPU (M3): segment/via/trace drags mutate the
// model per pointermove and simply mark, and the rebake happens once on the
// frame that follows.
//
// The draw stream itself is retained too: one GPURenderBundle holds the static
// pipeline/buffer/range sequence. A camera frame writes uniforms and executes
// that bundle; geometry, layer-order, and visible-pour changes re-record it.
(function () {
"use strict";
if (typeof window === "undefined") return;

var api = {
  init: init, frame: frame, rebuildCopper: rebuildCopper,
  rebuildParts: rebuildParts, rebuildPours: rebuildPours,
  partsExclIs: partsExclIs,
  dispose: dispose, active: false,
};
window.PCBGpu = api;

// ── module state ────────────────────────────────────────────────────────
var O = null,            // init opts (PCB, S, MX, MY, M, nsig, TH, layerColor, colour hooks, pours, ref, host)
    dev = null, gctx = null, cvs = null,
    colorFmt = null, bundle = null, bundleKey = "",
    pipeSeg = null, pipeCir = null, pipePad = null, pipePoly = null,
    pipeGrid = null, pipeFan = null, pipeCover = null,
    camBuf = null, drawBuf = null, bg0 = null, bg1 = null,
    camA = null, drawA = null,
    stTex = null, stView = null, stW = 0, stH = 0,   // stencil attachment (pour even-odd)
    segBuf = null, segRange = null,       // tracks, one contiguous range per layer
    viaBuf = null, viaRange = null,       // [barrels, holes]
    boreBuf = null, boreRange = null,     // drill bores (pads), split by part side
    padBuf = null, padRange = null,       // [thru/top part, thru/bottom part, top SMD, bottom SMD]
    polyBuf = null, polyRange = null,     // polygon pads, same 4 groups, as triangles
    fanBuf = null, pourRange = null,      // pour ring fans (stencil pass), one range per area
    coverBuf = null, coverA = null, pourN = 0,   // pour cover quads, one instance per area
    partsExcl = null,    // parts left OUT of the pad/bore bake (a live drag — see rebuildParts)
    dirtyCu = true, dirtyPt = true, dirtyPo = true, lastDrill = -1,
    clearCol = { r: 0, g: 0, b: 0, a: 1 };

// Dynamic uniform offsets must be a multiple of minUniformBufferOffsetAlignment
// (256 on every current implementation), so one 256-byte slot per draw.
var DSTRIDE = 256, DFLOATS = 64;
// Slot map, relative to the layer block: layers occupy 0..nsig-1 (indexed by the
// layer id itself, which IS the 0..nsig-1 signal index pcb_board.js uses).
// SMD pads split by the owning part's side for the solid-pour foreign-side fade.
// Through-hole pads and bores keep parallel top/bottom ranges for a stable
// layout, but pcb_board.js assigns both groups full opacity on every view.
var S_THRU_T = 0, S_THRU_B = 1, S_TOP = 2, S_BOT = 3, S_BORE_T = 4, S_BORE_B = 5,
    S_VIA = 6, S_HOLE = 7, S_POUR = 8, S_GRID = 9, S_EXTRA = 10;

function slotBase() { return O.nsig; }
function slotCount() { return O.nsig + S_EXTRA; }

// ── helpers ─────────────────────────────────────────────────────────────
// "#rrggbb" → [r,g,b] in 0..1. Every colour this file draws comes from the
// theme table, the blob layer table or the net-colour map, which are hex; anything
// unparseable falls back to a neutral grey rather than throwing mid-bake.
// Memoized: a net-coloured bake asks for a colour per track/via/pad, and the
// distinct set is a few dozen strings.
var rgbCache = {};
function rgb(c) {
  var s = String(c || ""), hit = rgbCache[s];
  if (hit) return hit;
  var m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(s);
  var v = m ? [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255]
            : [0.55, 0.58, 0.62];
  rgbCache[s] = v;
  return v;
}
// The X()/Y() mapping of pcb_board.js: board mm → svg units.
function ux(mm) { return (mm - O.MX + O.M) * O.S; }
function uy(mm) { return (mm - O.MY + O.M) * O.S; }
// Per-object colour. The rule lives in pcb_board.js (one expression, shared with
// the 2D painter); the fallbacks keep the renderer working for a caller that
// hands over no hooks at all — they are M1's fixed layer/theme colours.
function trackCol(t, L) { return (O.trackColor && O.trackColor(t, L)) || O.layerColor(L); }
function viaCol(v) { return (O.viaColor && O.viaColor(v)) || O.TH.via; }
function padCol(pd, bt) {
  return (O.padColor && O.padColor(pd, bt)) ||
    ((pd.drill > 0) ? (pd.npth ? O.TH.npth : O.TH.pth) : (bt ? O.TH.padBot : O.TH.padTop));
}

// ── WGSL ────────────────────────────────────────────────────────────────
// One module, seven entry-point pairs. The camera is group 0 (written once per
// frame); the per-draw alpha is group 1 with a dynamic offset, so the layer
// ladder costs one setBindGroup per draw and zero buffer traffic.
//
// Clip-space mapping, and the one sign that matters: the canvas y axis grows
// DOWN (svg units, same as vb), clip y grows UP — hence `1 - 2*(v-vb.y)/vb.h`
// against `2*(u-vb.x)/vb.w - 1`.
var WGSL = [
"struct Cam { vb: vec4<f32>, px: vec4<f32>, grid: vec4<f32>, gcol: vec4<f32> };",
"@group(0) @binding(0) var<uniform> cam: Cam;",
"struct DrawU { p: vec4<f32> };",
"@group(1) @binding(0) var<uniform> du: DrawU;",
"",
"fn clipOf(u: vec2<f32>) -> vec4<f32> {",
"  return vec4<f32>((u.x - cam.vb.x) / cam.vb.z * 2.0 - 1.0,",
"                   1.0 - (u.y - cam.vb.y) / cam.vb.w * 2.0, 0.0, 1.0);",
"}",
// One device pixel expressed in svg units. vb tracks the canvas aspect exactly
// (vbResize keeps it so), hence one scale for both axes.
"fn onepx() -> f32 { return cam.vb.z / max(cam.px.x, 1.0); }",
// Unit-quad corner from the vertex index of a 4-vertex triangle strip:
// 0 (-1,-1)  1 (1,-1)  2 (-1,1)  3 (1,1).
"fn corner(vi: u32) -> vec2<f32> {",
"  return vec2<f32>(select(-1.0, 1.0, (vi & 1u) == 1u), select(-1.0, 1.0, (vi & 2u) == 2u));",
"}",
// The context is configured alphaMode:'premultiplied' and the blend is
// one / one-minus-src-alpha, so every fragment must emit premultiplied colour.
"fn premul(c: vec3<f32>, a: f32) -> vec4<f32> { return vec4<f32>(c * a, a); }",
"fn segDist(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {",
"  let pa = p - a; let ba = b - a;",
"  let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-12), 0.0, 1.0);",
"  return length(pa - ba * h);",
"}",
"",
// ── grid: a full-screen triangle that computes its own dots. cam.grid is
// (pitch, halfDot, x0, y0) in SVG UNITS — pitch = g*S and (x0,y0) = the svg
// image of board (0,0), so a dot centre is x0 + n*pitch for integer n, exactly
// the X(n*g) the 2D per-dot loop draws. Square dots, matching fillRect. ──
"struct GridV {",
"  @builtin(position) pos: vec4<f32>,",
"  @location(0) w: vec2<f32>,",
"};",
"@vertex fn vsGrid(@builtin(vertex_index) vi: u32) -> GridV {",
"  let c = vec2<f32>(f32((vi << 1u) & 2u) * 2.0 - 1.0, f32(vi & 2u) * 2.0 - 1.0);",
"  var o: GridV;",
"  o.pos = vec4<f32>(c, 0.0, 1.0);",
"  o.w = vec2<f32>(cam.vb.x + (c.x + 1.0) * 0.5 * cam.vb.z,",
"                  cam.vb.y + (1.0 - c.y) * 0.5 * cam.vb.w);",
"  return o;",
"}",
"@fragment fn fsGrid(v: GridV) -> @location(0) vec4<f32> {",
"  let pitch = cam.grid.x;",
"  if (pitch <= 0.0) { discard; }",
"  let h = cam.grid.y;",
"  let f = 0.5 * onepx();",
"  let tx = (v.w.x - cam.grid.z) / pitch;",
"  let ty = (v.w.y - cam.grid.w) / pitch;",
"  let dx = abs(tx - round(tx)) * pitch;",
"  let dy = abs(ty - round(ty)) * pitch;",
"  let al = (1.0 - smoothstep(h - f, h + f, dx)) * (1.0 - smoothstep(h - f, h + f, dy)) * du.p.x;",
"  if (al <= 0.0) { discard; }",
"  return premul(cam.gcol.rgb, al);",
"}",
"",
// ── pour ring fan: STENCIL ONLY (colorWrites 0, stencil op INVERT). Each ring
// of an area — the outer polygon and every hole loop — is fanned from its own
// first vertex; a fan covers points outside a concave ring an even number of
// times, and a hole ring inverts its interior a second time, so what survives
// as odd is exactly the even-odd interior. No triangulator anywhere. ──
"@vertex fn vsFan(@location(0) p: vec2<f32>) -> @builtin(position) vec4<f32> {",
"  return clipOf(p);",
"}",
"@fragment fn fsFan() -> @location(0) vec4<f32> { return vec4<f32>(0.0, 0.0, 0.0, 0.0); }",
"",
// ── pour cover: one quad over the area's bbox, drawn where stencil != 0 and
// REPLACING with 0 on the way through, so the cover both paints the fill and
// clears the stencil for the next area (no per-area stencil clear exists). ──
"struct CovV {",
"  @builtin(position) pos: vec4<f32>,",
"  @location(0) col: vec4<f32>,",
"};",
"@vertex fn vsCover(@builtin(vertex_index) vi: u32,",
"                   @location(0) box: vec4<f32>,",
"                   @location(1) col: vec4<f32>) -> CovV {",
"  let q = corner(vi);",
"  let w = vec2<f32>(select(box.x, box.z, q.x > 0.0), select(box.y, box.w, q.y > 0.0));",
"  var o: CovV; o.pos = clipOf(w); o.col = col; return o;",
"}",
"@fragment fn fsCover(v: CovV) -> @location(0) vec4<f32> {",
"  let al = v.col.a * du.p.x;",
"  if (al <= 0.0) { discard; }",
"  return premul(v.col.rgb, al);",
"}",
"",
// ── tracks: capsule SDF with round caps (matches 2D lineCap:'round') ──
"struct SegV {",
"  @builtin(position) pos: vec4<f32>,",
"  @location(0) w: vec2<f32>,",
"  @location(1) a: vec2<f32>,",
"  @location(2) b: vec2<f32>,",
"  @location(3) col: vec4<f32>,",
"  @location(4) hw: f32,",
"};",
"@vertex fn vsSeg(@builtin(vertex_index) vi: u32,",
"                 @location(0) seg: vec4<f32>,",
"                 @location(1) geo: vec4<f32>,",
"                 @location(2) col: vec4<f32>) -> SegV {",
"  let q = corner(vi);",
"  let a = seg.xy; let b = seg.zw;",
"  let d = b - a; let L = length(d);",
"  var dir = vec2<f32>(1.0, 0.0);",
"  if (L > 1e-9) { dir = d / L; }",
"  let nr = vec2<f32>(-dir.y, dir.x);",
// Expand past the half-width by a pixel and a half so the feathered edge and
// the round caps are always inside the quad at any zoom.
"  let ext = geo.x + 1.5 * onepx();",
"  let mid = (a + b) * 0.5;",
"  let w = mid + dir * (q.x * (L * 0.5 + ext)) + nr * (q.y * ext);",
"  var o: SegV;",
"  o.pos = clipOf(w); o.w = w; o.a = a; o.b = b; o.col = col; o.hw = geo.x;",
"  return o;",
"}",
"@fragment fn fsSeg(v: SegV) -> @location(0) vec4<f32> {",
"  let f = 0.5 * onepx();",
"  let al = (1.0 - smoothstep(v.hw - f, v.hw + f, segDist(v.w, v.a, v.b))) * v.col.a * du.p.x;",
"  if (al <= 0.0) { discard; }",
"  return premul(v.col.rgb, al);",
"}",
"",
// ── circles: annulus SDF. r.y == 0 ⇒ a filled disc (via barrel, hole
// punch, drill bore); r.y > 0 remains available to the generic pipeline. ──
"struct CirV {",
"  @builtin(position) pos: vec4<f32>,",
"  @location(0) w: vec2<f32>,",
"  @location(1) c: vec2<f32>,",
"  @location(2) r: vec2<f32>,",
"  @location(3) col: vec4<f32>,",
"};",
"@vertex fn vsCir(@builtin(vertex_index) vi: u32,",
"                 @location(0) geo: vec4<f32>,",
"                 @location(1) col: vec4<f32>) -> CirV {",
"  let w = geo.xy + corner(vi) * (geo.z + 1.5 * onepx());",
"  var o: CirV;",
"  o.pos = clipOf(w); o.w = w; o.c = geo.xy; o.r = geo.zw; o.col = col;",
"  return o;",
"}",
"@fragment fn fsCir(v: CirV) -> @location(0) vec4<f32> {",
"  let f = 0.5 * onepx();",
"  let d = distance(v.w, v.c);",
"  var al = 1.0 - smoothstep(v.r.x - f, v.r.x + f, d);",
// A disc must NOT run the inner term: smoothstep straddling 0 would halve the
// alpha at the centre and leave a dim dot in every via.
"  if (v.r.y > 0.0) { al = al * smoothstep(v.r.y - f, v.r.y + f, d); }",
"  al = al * v.col.a * du.p.x;",
"  if (al <= 0.0) { discard; }",
"  return premul(v.col.rgb, al);",
"}",
"",
// ── pads: rect or circle SDF in the pad's own frame. e1 is the pad's local
// +x axis in world space; the rect is symmetric, so the sign of the second
// axis is irrelevant and perp(e1) always works — which is what lets a
// bottom-side (mirrored, left-handed) pad frame be carried as one angle. ──
"struct PadV {",
"  @builtin(position) pos: vec4<f32>,",
"  @location(0) w: vec2<f32>,",
"  @location(1) c: vec2<f32>,",
"  @location(2) h: vec2<f32>,",
"  @location(3) e1: vec2<f32>,",
"  @location(4) col: vec4<f32>,",
"  @location(5) shape: f32,",
"};",
"@vertex fn vsPad(@builtin(vertex_index) vi: u32,",
"                 @location(0) geo: vec4<f32>,",
"                 @location(1) rot: vec4<f32>,",
"                 @location(2) col: vec4<f32>) -> PadV {",
"  let q = corner(vi);",
"  let e1 = vec2<f32>(rot.x, rot.y);",
"  let e2 = vec2<f32>(-rot.y, rot.x);",
"  let m = 1.5 * onepx();",
"  let w = geo.xy + e1 * (q.x * (geo.z + m)) + e2 * (q.y * (geo.w + m));",
"  var o: PadV;",
"  o.pos = clipOf(w); o.w = w; o.c = geo.xy; o.h = geo.zw; o.e1 = e1;",
"  o.col = col; o.shape = rot.z;",
"  return o;",
"}",
"@fragment fn fsPad(v: PadV) -> @location(0) vec4<f32> {",
"  let f = 0.5 * onepx();",
"  let d = v.w - v.c;",
"  var dist: f32;",
"  if (v.shape > 0.5) { dist = length(d) - v.h.x; }",
"  else {",
"    let e2 = vec2<f32>(-v.e1.y, v.e1.x);",
"    let q = abs(vec2<f32>(dot(d, v.e1), dot(d, e2))) - v.h;",
"    dist = length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0);",
"  }",
"  let al = (1.0 - smoothstep(-f, f, dist)) * v.col.a * du.p.x;",
"  if (al <= 0.0) { discard; }",
"  return premul(v.col.rgb, al);",
"}",
"",
// ── polygon pads: pre-triangulated, plain flat fill. ──
"struct PolyV {",
"  @builtin(position) pos: vec4<f32>,",
"  @location(0) col: vec4<f32>,",
"};",
"@vertex fn vsPoly(@location(0) p: vec2<f32>, @location(1) col: vec4<f32>) -> PolyV {",
"  var o: PolyV; o.pos = clipOf(p); o.col = col; return o;",
"}",
"@fragment fn fsPoly(v: PolyV) -> @location(0) vec4<f32> {",
"  let al = v.col.a * du.p.x;",
"  if (al <= 0.0) { discard; }",
"  return premul(v.col.rgb, al);",
"}",
].join("\n");

// ── vertex buffer layouts ───────────────────────────────────────────────
// Every attribute sits on a 16-byte boundary — not required by WebGPU (which
// only demands a 4-byte multiple for f32 components) but it makes the
// JS-side Float32Array index arithmetic below trivially checkable: attribute k
// starts at float 4k, and the whole instance is stride/4 floats. (The fan
// buffer is the one exception: bare positions, 8 bytes, nothing to align.)
//
//   tracks   stride 48 = 12 f32   @0  x4 (ax,ay,bx,by)  @16 x4 (halfw,-,-,-)  @32 x4 rgba
//   circles  stride 32 =  8 f32   @0  x4 (cx,cy,rOut,rIn)                     @16 x4 rgba
//   pads     stride 48 = 12 f32   @0  x4 (cx,cy,hw,hh)  @16 x4 (cos,sin,shape,-) @32 x4 rgba
//   poly     stride 32 =  8 f32   @0  x2 (x,y)                                @16 x4 rgba   [per-vertex]
//   fan      stride  8 =  2 f32   @0  x2 (x,y)                                              [per-vertex]
//   cover    stride 32 =  8 f32   @0  x4 (x0,y0,x1,y1)                        @16 x4 rgba
var SEG_F = 12, CIR_F = 8, PAD_F = 12, POLY_F = 8, FAN_F = 2, COVER_F = 8;
function vbl(stride, attrs, step) {
  return { arrayStride: stride, stepMode: step || "instance", attributes: attrs };
}
var L_SEG = vbl(48, [{ shaderLocation: 0, offset: 0, format: "float32x4" },
                     { shaderLocation: 1, offset: 16, format: "float32x4" },
                     { shaderLocation: 2, offset: 32, format: "float32x4" }]);
var L_CIR = vbl(32, [{ shaderLocation: 0, offset: 0, format: "float32x4" },
                     { shaderLocation: 1, offset: 16, format: "float32x4" }]);
var L_PAD = vbl(48, [{ shaderLocation: 0, offset: 0, format: "float32x4" },
                     { shaderLocation: 1, offset: 16, format: "float32x4" },
                     { shaderLocation: 2, offset: 32, format: "float32x4" }]);
var L_POLY = vbl(32, [{ shaderLocation: 0, offset: 0, format: "float32x2" },
                      { shaderLocation: 1, offset: 16, format: "float32x4" }], "vertex");
var L_FAN = vbl(8, [{ shaderLocation: 0, offset: 0, format: "float32x2" }], "vertex");
var L_COVER = vbl(32, [{ shaderLocation: 0, offset: 0, format: "float32x4" },
                       { shaderLocation: 1, offset: 16, format: "float32x4" }]);

// ── depth/stencil states ────────────────────────────────────────────────
// The render pass carries a stencil8 attachment for the pour passes, and a
// render pass and a pipeline are only compatible when their depth-stencil
// formats MATCH — so EVERY pipeline here has to declare the format, including
// the ones that never touch the stencil. Their state is the neutral one:
// no depth (stencil8 has no depth aspect, so depthWriteEnabled must stay false
// and depthCompare "always"), compare always, keep everything.
function ds(front) {
  return { format: "stencil8", depthWriteEnabled: false, depthCompare: "always",
    stencilFront: front, stencilBack: front,
    stencilReadMask: 0xff, stencilWriteMask: 0xff };
}
var ST_KEEP = { compare: "always", failOp: "keep", depthFailOp: "keep", passOp: "keep" },
    ST_INVERT = { compare: "always", failOp: "keep", depthFailOp: "keep", passOp: "invert" },
    ST_COVER = { compare: "not-equal", failOp: "keep", depthFailOp: "keep", passOp: "replace" };

// ── init / teardown ─────────────────────────────────────────────────────
// Resolves false — never rejects — on every unsupported path, so the caller's
// success branch is the only place that can turn the renderer on.
function init(opts) {
  try {
    if (!opts || !navigator.gpu || !opts.ref || !opts.host) return Promise.resolve(false);
    O = opts;
    return navigator.gpu.requestAdapter().then(function (ad) {
      if (!ad) return false;
      return ad.requestDevice().then(function (d) {
        if (!d) return false;
        return setup(d);
      });
    }).catch(function () { teardown(); return false; });
  } catch (e) { teardown(); return Promise.resolve(false); }
}

function setup(d) {
  dev = d;
  cvs = document.createElement("canvas");
  cvs.className = O.ref.className;   // .pcb-scene — absolute, pointer-events:none, z-index 0
  cvs.style.zIndex = "0";
  gctx = cvs.getContext("webgpu");
  if (!gctx) { teardown(); return false; }
  var fmt = navigator.gpu.getPreferredCanvasFormat();
  colorFmt = fmt;
  // premultiplied: the 2D canvas above clears to transparent, so this surface
  // is what the compositor shows through it.
  gctx.configure({ device: dev, format: fmt, alphaMode: "premultiplied" });

  // WebGPU reports shader-compile and pipeline-validation failures
  // ASYNCHRONOUSLY — createShaderModule/createRenderPipeline both succeed and
  // the only symptom is a canvas that stays at its clear colour. Both channels
  // are therefore wired to the console, and an uncaptured error falls the whole
  // renderer back to 2D rather than leaving a silently black board.
  var sh = dev.createShaderModule({ code: WGSL });
  if (sh.getCompilationInfo) sh.getCompilationInfo().then(function (info) {
    (info.messages || []).forEach(function (m) {
      if (m.type === "error") console.error("pcb_gpu: WGSL " + m.lineNum + ":" + m.linePos + " " + m.message);
    });
  }).catch(function () {});
  dev.onuncapturederror = function (ev) {
    console.error("pcb_gpu: device error, falling back to Canvas2D —", ev.error && ev.error.message);
    var cb = O && O.onLost;
    dispose();
    try { if (cb) cb(ev.error); } catch (e) {}
  };
  var bgl0 = dev.createBindGroupLayout({ entries: [{ binding: 0,
    visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
    buffer: { type: "uniform" } }] });
  var bgl1 = dev.createBindGroupLayout({ entries: [{ binding: 0,
    visibility: GPUShaderStage.FRAGMENT,
    buffer: { type: "uniform", hasDynamicOffset: true, minBindingSize: 16 } }] });
  var pl = dev.createPipelineLayout({ bindGroupLayouts: [bgl0, bgl1] });
  var blend = {
    color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
    alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
  };
  var mk = function (vs, fs, layout, topo, stencil, mask) {
    var target = (mask === 0) ? { format: fmt, writeMask: 0 } : { format: fmt, blend: blend };
    return dev.createRenderPipeline({
      layout: pl,
      vertex: { module: sh, entryPoint: vs, buffers: layout ? [layout] : [] },
      fragment: { module: sh, entryPoint: fs, targets: [target] },
      primitive: { topology: topo || "triangle-strip", cullMode: "none" },
      depthStencil: ds(stencil || ST_KEEP),
    });
  };
  pipeGrid = mk("vsGrid", "fsGrid", null, "triangle-list");
  // cullMode is "none" on the fan by necessity as well as by habit: INVERT must
  // fire for both windings or a hole ring drawn the "wrong" way round would not
  // cancel its parent.
  pipeFan = mk("vsFan", "fsFan", L_FAN, "triangle-list", ST_INVERT, 0);
  pipeCover = mk("vsCover", "fsCover", L_COVER, "triangle-strip", ST_COVER);
  pipeSeg = mk("vsSeg", "fsSeg", L_SEG);
  pipeCir = mk("vsCir", "fsCir", L_CIR);
  pipePad = mk("vsPad", "fsPad", L_PAD);
  pipePoly = mk("vsPoly", "fsPoly", L_POLY, "triangle-list");

  camA = new Float32Array(16);
  camBuf = dev.createBuffer({ size: 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  drawA = new Float32Array(slotCount() * DFLOATS);
  drawBuf = dev.createBuffer({ size: slotCount() * DSTRIDE,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  bg0 = dev.createBindGroup({ layout: bgl0, entries: [{ binding: 0, resource: { buffer: camBuf } }] });
  bg1 = dev.createBindGroup({ layout: bgl1,
    entries: [{ binding: 0, resource: { buffer: drawBuf, offset: 0, size: 16 } }] });

  var bg = rgb(O.TH.bg);
  clearCol = { r: bg[0], g: bg[1], b: bg[2], a: 1 };

  // Under the 2D canvas, inside the same shell — so both follow the identical
  // CSS box and the SVG interaction layer stays on top of both.
  O.host.insertBefore(cvs, O.ref);
  dirtyCu = dirtyPt = dirtyPo = true;
  api.active = true;
  if (dev.lost && dev.lost.then) dev.lost.then(function (info) {
    if (!api.active) return;
    dispose();
    try { if (O && O.onLost) O.onLost(info); } catch (e) {}
  });
  return true;
}

function teardown() {
  api.active = false;
  partsExcl = null;
  [segBuf, viaBuf, boreBuf, padBuf, polyBuf, fanBuf, coverBuf, camBuf, drawBuf, stTex].forEach(function (b) {
    try { if (b && b.destroy) b.destroy(); } catch (e) {}
  });
  segBuf = viaBuf = boreBuf = padBuf = polyBuf = fanBuf = coverBuf = camBuf = drawBuf = null;
  stTex = stView = null; stW = stH = 0;
  pipeSeg = pipeCir = pipePad = pipePoly = pipeGrid = pipeFan = pipeCover = bg0 = bg1 = null;
  bundle = null; bundleKey = ""; colorFmt = null;
  try { if (cvs && cvs.parentNode) cvs.parentNode.removeChild(cvs); } catch (e) {}
  cvs = null; gctx = null; dev = null;
}
function dispose() { teardown(); }

function rebuildCopper() { dirtyCu = true; bundle = null; }
// `exclude` is an index set ({3:1, 7:1, …}) of parts to leave OUT of the pad /
// poly-pad / bore bake; omit it (every pose-commit seam does) for the whole
// board. This is what keeps a part DRAG on the GPU: the movers are baked out
// ONCE when the drag starts and painted in 2D on top for its duration, so the
// GPU surface carries no stale ghost under the moving part and nothing is drawn
// twice — which is what retires the opaque drag-cache bitmap.
//
// Indices are positions in O.PCB.parts, which IS the array pcb_board.js drags
// (its `P` is `PCB.parts`), so identity is exact and costs nothing to check.
function rebuildParts(exclude) { partsExcl = exclude || null; dirtyPt = true; bundle = null; }
// Is the CURRENT bake's exclusion exactly `o`? The drag frame asks this instead
// of tracking its own flag, because any pose-commit seam (a live R press goes
// through setT) can clear the exclusion mid-drag — the frame simply re-states it
// whenever it no longer holds. Allocation-free, O(|exclusion| + |o|).
function partsExclIs(o) {
  var a = partsExcl || {}, n = 0, m = 0, k;
  for (k in a) { n++; if (!(o && o[k])) return false; }
  for (k in (o || {})) m++;
  return n === m;
}
function rebuildPours() { dirtyPo = true; bundle = null; }

// ── instance buffers ────────────────────────────────────────────────────
function upload(old, arr) {
  try { if (old && old.destroy) old.destroy(); } catch (e) {}
  if (!arr || !arr.length) return null;
  var b = dev.createBuffer({ size: arr.byteLength,
    usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
  dev.queue.writeBuffer(b, 0, arr);
  return b;
}

// Copper. Tracks are ordered by layer so each layer is one contiguous instance
// range drawn with its own alpha; vias split into barrels / hole punches in that
// draw order. Generated fence sites carry provenance in the model for safe
// regeneration, but render through this same ordinary-via path.
// Colours come from pcb_board.js's own
// expressions (net-colours mode included), so the two renderers agree
// pixel-for-intent.
function buildCopper(viaDrill) {
  bundle = null; // every upload below replaces buffers referenced by the bundle
  var P = O.PCB, S = O.S, TH = O.TH, i;
  var raw = P.tracks || [], ts = [], vs = P.vias || [];
  for (i = 0; i < raw.length; i++) {
    var chords = O.trackChords ? O.trackChords(raw[i]) : [raw[i]];
    for (var ci = 0; ci < chords.length; ci++) ts.push(chords[ci]);
  }
  var byL = [];
  for (i = 0; i < O.nsig; i++) byL.push([]);
  for (i = 0; i < ts.length; i++) {
    // A track naming a layer this board does not have is DROPPED, exactly as
    // the 2D path drops it (trackLayerOrder only walks real layers). Clamping
    // it to 0 instead drew stray copper on F.Cu that no other surface shows.
    var L = ts[i].l || 0;
    if (L >= 0 && L < O.nsig) byL[L].push(ts[i]);
  }
  var arr = new Float32Array(ts.length * SEG_F), off = 0;
  segRange = [];
  for (i = 0; i < O.nsig; i++) {
    var lst = byL[i];
    segRange.push({ first: off, count: lst.length });
    for (var j = 0; j < lst.length; j++) {
      var t = lst[j], b = off * SEG_F, c = rgb(trackCol(t, i));
      arr[b] = ux(t.x1); arr[b + 1] = uy(t.y1); arr[b + 2] = ux(t.x2); arr[b + 3] = uy(t.y2);
      arr[b + 4] = Math.max(t.w * S, 1.2) / 2;   // 2D strokes a max(w*S,1.2)-wide round line
      arr[b + 8] = c[0]; arr[b + 9] = c[1]; arr[b + 10] = c[2]; arr[b + 11] = 1;
      off++;
    }
  }
  segBuf = upload(segBuf, arr);

  var barrel = [], hole = [], ch = rgb(TH.viaHole);
  for (i = 0; i < vs.length; i++) {
    var v = vs[i], vc = rgb(viaCol(v));
    // Copper and bore radii are physical geometry. Interaction affordances live
    // on the 2D overlay and may grow independently, but this buffer must match
    // the model and Gerber apertures exactly even at a small board-fit scale.
    var rr = v.d / 2 * S;
    var dr = (v.drill > 0) ? v.drill : viaDrill;
    var rh = dr / 2 * S;
    barrel.push([ux(v.x), uy(v.y), rr, 0, vc]);
    hole.push([ux(v.x), uy(v.y), rh, 0, ch]);
  }
  var n = barrel.length + hole.length;
  var va = new Float32Array(n * CIR_F), k = 0;
  viaRange = [];
  [barrel, hole].forEach(function (grp) {
    viaRange.push({ first: k, count: grp.length });
    grp.forEach(function (g) {
      var b = k * CIR_F, c = g[4];
      va[b] = g[0]; va[b + 1] = g[1]; va[b + 2] = g[2]; va[b + 3] = g[3];
      va[b + 4] = c[0]; va[b + 5] = c[1]; va[b + 6] = c[2]; va[b + 7] = g.length > 5 ? g[5] : 1;
      k++;
    });
  });
  viaBuf = upload(viaBuf, va);
}

// Pads + bores. World-baked: the owning part's (x, y, rot, side) is folded into
// every instance at build time, copying the transform chain padPath draws under
// exactly — translate(X(p.x),Y(p.y)) · rotate(p.rot) · [scale(-1,1) if bottom] ·
// translate(pd.x·S,pd.y·S) · rotate(pd.rot). The pad frame that comes out of a
// bottom-side mirror is left-handed, but a centred rect is symmetric in its own
// axes, so it is carried as the single angle p.rot − pd.rot (top: p.rot + pd.rot).
//
// Grouping remains by (through-hole?, OWNING PART's side) so the buffer layout
// stays parallel with the SMD groups. The caller gives both through-pad and
// both bore groups alpha 1: drilled features cross the whole stack and remain
// visible from either face even when an opaque pour hides the owning part.
function buildParts() {
  bundle = null;
  var P = O.PCB.parts || [], S = O.S, TH = O.TH;
  var pads = [[], [], [], []],    // 0 thru/top part, 1 thru/bottom part, 2 top SMD, 3 bottom SMD
      polys = [[], [], [], []],   // same grouping, as world-space triangle vertices
      bores = [[], []];           // by part side
  var cHole = rgb(TH.hole);
  for (var i = 0; i < P.length; i++) {
    // A part the caller excluded (it is being dragged) contributes nothing at
    // all — no pad, no poly pad, no bore — so the 2D overlay owns it whole.
    if (partsExcl && partsExcl[i]) continue;
    var p = P[i], bt = (p.side === "bottom");
    var a = (p.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a);
    var ox = ux(p.x), oy = uy(p.y);
    // part-local (mm, already mirrored for a bottom part) → world svg units
    var wx = function (lx, ly) { return ox + (bt ? -lx : lx) * S * ca - ly * S * sa; };
    var wy = function (lx, ly) { return oy + (bt ? -lx : lx) * S * sa + ly * S * ca; };
    var pl = p.pads || [];
    for (var j = 0; j < pl.length; j++) {
      var pd = pl[j];
      var grp = (pd.drill > 0) ? (bt ? 1 : 0) : (bt ? 3 : 2);
      var col = rgb(padCol(pd, bt));
      var cx = wx(pd.x, pd.y), cy = wy(pd.x, pd.y);
      if (pd.drill > 0) bores[bt ? 1 : 0].push([cx, cy, Math.max(pd.drill / 2 * S, 0.6), 0]);
      if (pd.poly && pd.poly.length >= 3) {
        // A triangle fan is only exact for a simple convex ring, and imported
        // custom pads are not required to preserve either property. Leave
        // every custom outline to Canvas2D's exact polygon fill so an SMPM
        // ground-pad notch cannot become a large, pour-like fan triangle.
        continue;
      }
      var circ = (pd.shape === "circle");
      var hw = circ ? Math.min(pd.w, pd.h) / 2 * S : pd.w / 2 * S;
      var hh = circ ? hw : pd.h / 2 * S;
      var th = a + (bt ? -1 : 1) * (pd.rot || 0) * Math.PI / 180;
      pads[grp].push(cx, cy, hw, hh, Math.cos(th), Math.sin(th), circ ? 1 : 0, 0,
        col[0], col[1], col[2], 1);
    }
  }
  var total = 0;
  pads.forEach(function (g) { total += g.length; });
  var pa = new Float32Array(total), off = 0;
  padRange = [];
  pads.forEach(function (g) {
    padRange.push({ first: off / PAD_F, count: g.length / PAD_F });
    pa.set(g, off); off += g.length;
  });
  padBuf = upload(padBuf, pa);

  var pt = 0;
  polys.forEach(function (g) { pt += g.length; });
  var po = new Float32Array(pt), po_off = 0;
  polyRange = [];
  polys.forEach(function (g) {
    polyRange.push({ first: po_off / POLY_F, count: g.length / POLY_F });
    po.set(g, po_off); po_off += g.length;
  });
  polyBuf = upload(polyBuf, po);

  var bn = bores[0].length + bores[1].length;
  var ba = new Float32Array(bn * CIR_F), z = 0;
  boreRange = [];
  bores.forEach(function (g) {
    boreRange.push({ first: z, count: g.length });
    g.forEach(function (g2) {
      var b2 = z * CIR_F;
      ba[b2] = g2[0]; ba[b2 + 1] = g2[1]; ba[b2 + 2] = g2[2]; ba[b2 + 3] = g2[3];
      ba[b2 + 4] = cHole[0]; ba[b2 + 5] = cHole[1]; ba[b2 + 6] = cHole[2]; ba[b2 + 7] = 1;
      z++;
    });
  });
  boreBuf = upload(boreBuf, ba);
}

// Pour fills. O.pours() hands back the areas pcb_board.js decided are GPU-drawn
// fills — outer ring + hole loops in board mm, plus the fill colour — in a
// stable order the per-frame alpha array (st.pourA) is parallel to. Geometry
// only: the alpha ladder is re-read every frame.
//
// Each ring becomes a triangle fan from its OWN first vertex (n-2 triangles).
// The stencil pass inverts on every fragment, so a point covered an odd number
// of times survives — which is precisely the even-odd rule `fill(path,
// "evenodd")` applies, for concave rings and hole loops alike, with no
// triangulator in sight.
function ringFanVerts(r) { return (r && r.length >= 3) ? 3 * (r.length - 2) : 0; }
function buildPours() {
  bundle = null;
  var list = (O.pours && O.pours()) || [], i, j;
  var nv = 0;
  for (i = 0; i < list.length; i++) {
    nv += ringFanVerts(list[i].poly);
    var hs = list[i].holes || [];
    for (j = 0; j < hs.length; j++) nv += ringFanVerts(hs[j]);
  }
  var fa = new Float32Array(nv * FAN_F), ca = new Float32Array(list.length * COVER_F), k = 0;
  pourRange = [];
  var emit = function (r) {
    if (!r || r.length < 3) return;
    var v0x = ux(r[0][0]), v0y = uy(r[0][1]);
    for (var q = 1; q + 1 < r.length; q++) {
      var b = k * FAN_F;
      fa[b] = v0x; fa[b + 1] = v0y;
      fa[b + 2] = ux(r[q][0]); fa[b + 3] = uy(r[q][1]);
      fa[b + 4] = ux(r[q + 1][0]); fa[b + 5] = uy(r[q + 1][1]);
      k += 3;
    }
  };
  for (i = 0; i < list.length; i++) {
    var A = list[i], first = k, c = rgb(A.col);
    var x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
    var box = function (r) {
      if (!r || r.length < 3) return;
      for (var q = 0; q < r.length; q++) {
        var X = ux(r[q][0]), Y = uy(r[q][1]);
        if (X < x0) x0 = X; if (X > x1) x1 = X;
        if (Y < y0) y0 = Y; if (Y > y1) y1 = Y;
      }
    };
    emit(A.poly); box(A.poly);
    var hl = A.holes || [];
    for (j = 0; j < hl.length; j++) { emit(hl[j]); box(hl[j]); }
    pourRange.push({ first: first, count: k - first });
    var b2 = i * COVER_F, pad = 1;   // a pixel of slack so the cover cannot clip its own edge
    ca[b2] = (x0 > x1 ? 0 : x0 - pad); ca[b2 + 1] = (y0 > y1 ? 0 : y0 - pad);
    ca[b2 + 2] = (x0 > x1 ? 0 : x1 + pad); ca[b2 + 3] = (y0 > y1 ? 0 : y1 + pad);
    ca[b2 + 4] = c[0]; ca[b2 + 5] = c[1]; ca[b2 + 6] = c[2]; ca[b2 + 7] = 0;
  }
  fanBuf = upload(fanBuf, fa);
  coverBuf = upload(coverBuf, ca);
  coverA = ca;
  pourN = list.length;
}

// Record the static draw stream once and replay it as a render bundle. Camera,
// layer alpha, pour opacity and grid pitch all live in buffers, so ordinary
// pan/zoom and appearance changes only write those buffers; they do not need to
// rebuild JavaScript command objects. The bundle changes only when buffer
// identity changes, layer order changes, or a pour crosses the zero-alpha
// boundary (an invisible pour's stencil fan must be omitted with its cover).
function bundleFingerprint(st, pa, np) {
  var ls = st.layers || [], s = (st.stages || []).join(">") + "|";
  for (var i = 0; i < ls.length; i++) s += (i ? "," : "") + ls[i].l;
  s += "|" + np + "|";
  for (var j = 0; j < np; j++) s += pa[j] > 0 ? "1" : "0";
  return s;
}
// The passes this renderer owns, keyed by the paint-order stage they belong to.
// pcb_board.js hands the ORDER over in st.stages (its PAINT_STAGES filtered to
// GPU-owned entries), so this file never restates a draw sequence — it looks up
// each named stage in turn. A stage it has no pass for is simply absent here.
var STAGE_PASS = {
  // The grid shader discards when pitch is zero, so the command itself is
  // static even while zoom crosses the grid-visibility threshold.
  substrate: function (pass, ctx) {
    pass.setPipeline(pipeGrid);
    pass.setBindGroup(1, bg1, [(ctx.base + S_GRID) * DSTRIDE]);
    pass.draw(3, 1, 0, 0);
  },
  plane_fills: function (pass, ctx) {
    if (!(fanBuf && coverBuf && ctx.np > 0)) return;
    for (var i = 0; i < ctx.np; i++) {
      var rg = pourRange[i];
      if (!rg || !rg.count || !(ctx.pa[i] > 0)) continue;
      pass.setPipeline(pipeFan); pass.setVertexBuffer(0, fanBuf);
      pass.setBindGroup(1, bg1, [(ctx.base + S_POUR) * DSTRIDE]);
      pass.draw(rg.count, 1, rg.first, 0);
      pass.setPipeline(pipeCover); pass.setVertexBuffer(0, coverBuf);
      pass.draw(4, 1, 0, i);
    }
  },
  parts: function (pass, ctx) {
    var base = ctx.base, i;
    var padSlots = [base + S_THRU_T, base + S_THRU_B, base + S_TOP, base + S_BOT];
    if (padBuf) {
      pass.setPipeline(pipePad); pass.setVertexBuffer(0, padBuf);
      for (i = 0; i < 4; i++) ctx.draw(padRange[i], padSlots[i]);
    }
    if (polyBuf) {
      pass.setPipeline(pipePoly); pass.setVertexBuffer(0, polyBuf);
      for (i = 0; i < 4; i++) ctx.draw(polyRange[i], padSlots[i], true);
    }
    if (boreBuf) {
      pass.setPipeline(pipeCir); pass.setVertexBuffer(0, boreBuf);
      ctx.draw(boreRange[0], base + S_BORE_T);
      ctx.draw(boreRange[1], base + S_BORE_B);
    }
  },
  copper: function (pass, ctx) {
    var layers = ctx.layers, i;
    if (segBuf) {
      pass.setPipeline(pipeSeg); pass.setVertexBuffer(0, segBuf);
      for (i = 0; i < layers.length; i++) {
        var li = layers[i].l;
        // Alpha is dynamic. Recording a zero-alpha layer keeps visibility and
        // opacity changes on the uniform-only fast path.
        if (li >= 0 && li < segRange.length) ctx.draw(segRange[li], li);
      }
    }
    if (viaBuf) {
      pass.setPipeline(pipeCir); pass.setVertexBuffer(0, viaBuf);
      ctx.draw(viaRange[0], ctx.base + S_VIA);
      ctx.draw(viaRange[1], ctx.base + S_HOLE);
    }
  },
};
// The stage sequence used when the host sends none — the same four names in the
// same order, so an older/partial policy blob still draws a correct board.
var STAGE_FALLBACK = ["substrate", "plane_fills", "parts", "copper"];
function encodeScene(pass, st, pa, np) {
  var base = slotBase();
  pass.setBindGroup(0, bg0);
  if (pass.setStencilReference) pass.setStencilReference(0);
  var ctx = {
    base: base, pa: pa, np: np, layers: st.layers || [],
    draw: function (r, slot, verts) {
      if (!r || !r.count) return;
      pass.setBindGroup(1, bg1, [slot * DSTRIDE]);
      if (verts) pass.draw(r.count, 1, r.first, 0);
      else pass.draw(4, r.count, 0, r.first);
    },
  };
  var order = (st.stages && st.stages.length) ? st.stages : STAGE_FALLBACK;
  for (var i = 0; i < order.length; i++) {
    var fn = STAGE_PASS[order[i]];
    if (fn) fn(pass, ctx);
  }
}
function rebuildBundle(st, pa, np, key) {
  if (!dev.createRenderBundleEncoder || !colorFmt) return null;
  try {
    var enc = dev.createRenderBundleEncoder({
      colorFormats: [colorFmt], depthStencilFormat: "stencil8", sampleCount: 1,
    });
    encodeScene(enc, st, pa, np);
    bundleKey = key;
    return enc.finish();
  } catch (e) {
    // Render bundles are an optimization only. An implementation that refuses
    // one still gets the identical immediate command stream for this frame.
    bundleKey = "";
    return null;
  }
}

// ── frame ───────────────────────────────────────────────────────────────
// `st` is the fully-resolved policy blob pcb_board.js builds each frame:
//   stages[]  the GPU-owned stage NAMES in canonical paint order (its
//             PAINT_STAGES, mirrored from src/render_order.zig) — the draw
//             sequence is handed over, never restated here; see STAGE_PASS
//   layers[]  {l, a}   the trackLayerOrder() sequence with layerAlpha·pourLayerFade folded in
//   padThruTop/padThruBot/padTop/padBot/boreTop/boreBot/via  the alpha ladder for everything else
//   pourA[]   per-area effective fill alpha, parallel to O.pours()
//   gridPitch/gridDot  svg units; gridPitch 0 ⇒ the grid pass is skipped entirely
//   viaDrill  the Route panel's default drill (a change self-invalidates copper)
function frame(vb, st) {
  if (!api.active || !dev || !gctx) return;
  try {
    var ref = O.ref;
    // Mirror the 2D canvas exactly — device pixels AND the CSS box scenePaint
    // just wrote — so the two surfaces are pixel-coincident by construction.
    if (cvs.width !== ref.width) cvs.width = ref.width;
    if (cvs.height !== ref.height) cvs.height = ref.height;
    if (cvs.style.width !== ref.style.width) cvs.style.width = ref.style.width;
    if (cvs.style.height !== ref.style.height) cvs.style.height = ref.style.height;
    if (cvs.style.left !== ref.style.left) cvs.style.left = ref.style.left;
    if (cvs.style.top !== ref.style.top) cvs.style.top = ref.style.top;
    if (!(cvs.width > 0 && cvs.height > 0)) return;

    // The stencil attachment tracks the canvas size. Every pipeline declares the
    // stencil8 format (a pass and a pipeline must agree on it), so this texture
    // is required for EVERY frame, not just the ones that draw a pour.
    if (!stTex || stW !== cvs.width || stH !== cvs.height) {
      try { if (stTex && stTex.destroy) stTex.destroy(); } catch (e) {}
      stTex = dev.createTexture({ size: [cvs.width, cvs.height],
        format: "stencil8", usage: GPUTextureUsage.RENDER_ATTACHMENT });
      stView = stTex.createView();
      stW = cvs.width; stH = cvs.height;
    }

    if (st.viaDrill !== lastDrill) { lastDrill = st.viaDrill; dirtyCu = true; }
    if (dirtyCu) { buildCopper(st.viaDrill); dirtyCu = false; }
    if (dirtyPt) { buildParts(); dirtyPt = false; }
    if (dirtyPo) { buildPours(); dirtyPo = false; }

    var gp = st.gridPitch > 0 ? st.gridPitch : 0;
    camA[0] = vb.x; camA[1] = vb.y; camA[2] = vb.w; camA[3] = vb.h;
    camA[4] = cvs.width; camA[5] = cvs.height; camA[6] = 0; camA[7] = 0;
    camA[8] = gp; camA[9] = (st.gridDot || 0) / 2; camA[10] = ux(0); camA[11] = uy(0);
    var gc = rgb(O.TH.gridDot);
    camA[12] = gc[0]; camA[13] = gc[1]; camA[14] = gc[2]; camA[15] = 1;
    dev.queue.writeBuffer(camBuf, 0, camA);

    var base = slotBase(), i;
    drawA.fill(0);
    var layers = st.layers || [];
    for (i = 0; i < layers.length; i++) {
      var L = layers[i].l;
      if (L >= 0 && L < O.nsig) drawA[L * DFLOATS] = layers[i].a;
    }
    drawA[(base + S_THRU_T) * DFLOATS] = st.padThruTop;
    drawA[(base + S_THRU_B) * DFLOATS] = st.padThruBot;
    drawA[(base + S_TOP) * DFLOATS] = st.padTop;
    drawA[(base + S_BOT) * DFLOATS] = st.padBot;
    drawA[(base + S_BORE_T) * DFLOATS] = st.boreTop;
    drawA[(base + S_BORE_B) * DFLOATS] = st.boreBot;
    drawA[(base + S_VIA) * DFLOATS] = st.via;
    drawA[(base + S_HOLE) * DFLOATS] = st.via;
    drawA[(base + S_POUR) * DFLOATS] = 1;   // the per-area alpha rides the cover instance
    drawA[(base + S_GRID) * DFLOATS] = 1;
    dev.queue.writeBuffer(drawBuf, 0, drawA);

    // Per-area fill alpha is the ONLY pour input that moves per frame (the
    // pour-opacity ramp, layer visibility, the active layer), so the geometry
    // stays baked and just its alpha column is rewritten.
    var pa = st.pourA || [], np = Math.min(pourN, pa.length);
    if (coverBuf && coverA && np > 0) {
      for (i = 0; i < pourN; i++) coverA[i * COVER_F + 7] = (i < np ? (pa[i] || 0) : 0);
      dev.queue.writeBuffer(coverBuf, 0, coverA);
    }

    var key = bundleFingerprint(st, pa, np);
    if (bundle && bundleKey !== key) bundle = null;
    if (!bundle) bundle = rebuildBundle(st, pa, np, key);

    var enc = dev.createCommandEncoder();
    var pass = enc.beginRenderPass({
      colorAttachments: [{ view: gctx.getCurrentTexture().createView(),
        clearValue: clearCol, loadOp: "clear", storeOp: "store" }],
      // stencil8 has no depth aspect, so depthLoadOp/depthStoreOp must be absent.
      depthStencilAttachment: { view: stView,
        stencilClearValue: 0, stencilLoadOp: "clear", stencilStoreOp: "store" },
    });
    // Draw order replays the 2D scene bottom-up (paintScene): grid, pour
    // fills, pads/bores, layer-ordered copper, then stack-spanning vias. On the
    // normal path this is one native bundle execution; the immediate encoder is
    // the compatibility fallback and is intentionally byte-for-command equal.
    if (bundle && pass.executeBundles) pass.executeBundles([bundle]);
    else encodeScene(pass, st, pa, np);
    pass.end();
    dev.queue.submit([enc.finish()]);
  } catch (e) {
    // A validation error or a surface that vanished must never take the page
    // down: shut the renderer off and let pcb_board.js repaint everything in 2D.
    dispose();
    try { if (O && O.onLost) O.onLost(e); } catch (e2) {}
  }
}
})();
