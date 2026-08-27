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
//  · Failure is always total: no navigator.gpu, no adapter, a lost device or
//    any throw ⇒ active=false and the GPU canvas is removed. The editor may
//    resume its 2D path; Assembly treats that state as a visible hard failure.
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
  rebuildCam: rebuildCam,
  partsExclIs: partsExclIs,
  dispose: dispose, active: false, error: null,
};
window.PCBGpu = api;

// ── module state ────────────────────────────────────────────────────────
var O = null,            // init opts (PCB, S, MX, MY, M, nsig, TH, layerColor, colour hooks, pours, ref, host)
    dev = null, gctx = null, cvs = null,
    colorFmt = null, bundle = null, bundleKey = "",
    pipeSeg = null, pipeCir = null, pipePad = null, pipePoly = null,
    pipeGrid = null, pipeFan = null, pipeCover = null,
    pipeCamSeg = null, pipeCamCir = null, pipeCamPad = null,
    pipeCamPoly = null, pipeCamArc = null, pipeCamBoard = null,
    pipeCamReset = null, pipeCamTint = null, pipeCamSub = null, pipeCamBlit = null,
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
    camGeo = null, camDirty = true, camFailed = false,
    camFilm = null, camFilmView = null, camFilmBg = null, camFilmStencil = null,
    camFilmW = 0, camFilmH = 0, camFilmKey = "", camSampler = null,
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
var CAM_MAX_LAYERS = 32,
    S_THRU_T = 0, S_THRU_B = 1, S_TOP = 2, S_BOT = 3, S_BORE_T = 4, S_BORE_B = 5,
    S_VIA = 6, S_HOLE = 7, S_POUR = 8, S_GRID = 9, S_CAM = 10,
    S_EXTRA = S_CAM + CAM_MAX_LAYERS + 2;

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
"  if (v.shape > 1.5) {",
"    let e2 = vec2<f32>(-v.e1.y, v.e1.x);",
"    var a = v.c; var b = v.c; var r = v.h.y;",
"    if (v.h.x >= v.h.y) { a = v.c - v.e1 * (v.h.x - v.h.y); b = v.c + v.e1 * (v.h.x - v.h.y); r = v.h.y; }",
"    else { a = v.c - e2 * (v.h.y - v.h.x); b = v.c + e2 * (v.h.y - v.h.x); r = v.h.x; }",
"    dist = segDist(v.w, a, b) - r;",
"  }",
"  else if (v.shape > 0.5) { dist = length(d) - v.h.x; }",
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
"// CAM circular strokes: exact Gerber arcs, never sampled chords.",
"struct ArcV {",
"  @builtin(position) pos: vec4<f32>,",
"  @location(0) w: vec2<f32>, @location(1) c: vec2<f32>,",
"  @location(2) a: vec2<f32>, @location(3) b: vec2<f32>,",
"  @location(4) rh: vec2<f32>, @location(5) dir: f32, @location(6) col: vec4<f32>,",
"};",
"@vertex fn vsArc(@builtin(vertex_index) vi: u32,",
"                 @location(0) geo: vec4<f32>, @location(1) ends: vec4<f32>,",
"                 @location(2) arcInfo: vec4<f32>, @location(3) col: vec4<f32>) -> ArcV {",
"  let ext = geo.z + geo.w + 1.5 * onepx();",
"  let w = geo.xy + corner(vi) * ext;",
"  var o: ArcV; o.pos = clipOf(w); o.w = w; o.c = geo.xy; o.a = ends.xy; o.b = ends.zw;",
"  o.rh = geo.zw; o.dir = arcInfo.x; o.col = col; return o;",
"}",
"@fragment fn fsArc(v: ArcV) -> @location(0) vec4<f32> {",
"  let tau = 6.28318530718;",
"  let av = atan2(v.w.y - v.c.y, v.w.x - v.c.x);",
"  let a0 = atan2(v.a.y - v.c.y, v.a.x - v.c.x);",
"  let a1 = atan2(v.b.y - v.c.y, v.b.x - v.c.x);",
"  var span = a1 - a0; span = span - floor(span / tau) * tau;",
"  var rel = av - a0; rel = rel - floor(rel / tau) * tau;",
"  if (span < 0.0) { span = span + tau; } if (rel < 0.0) { rel = rel + tau; }",
"  if (v.dir < 0.0) { span = a0 - a1; span = span - floor(span / tau) * tau;",
"    rel = a0 - av; rel = rel - floor(rel / tau) * tau;",
"    if (span < 0.0) { span = span + tau; } if (rel < 0.0) { rel = rel + tau; } }",
"  var d = abs(distance(v.w, v.c) - v.rh.x);",
"  if (rel > span) { d = min(distance(v.w, v.a), distance(v.w, v.b)); }",
"  let f = 0.5 * onepx();",
"  let al = (1.0 - smoothstep(v.rh.y - f, v.rh.y + f, d)) * v.col.a * du.p.x;",
"  if (al <= 0.0) { discard; } return premul(v.col.rgb, al);",
"}",
"",
"// Binary analytic coverage for CAM stencil writes. The tint happens later;",
"// discard at the exact boundary so the colour shader's AA feather does not",
"// become a fully-covered extra pixel in the film mask.",
"@fragment fn fsStencilSeg(v: SegV) -> @location(0) vec4<f32> {",
"  if (segDist(v.w, v.a, v.b) > v.hw) { discard; } return vec4<f32>(0.0);",
"}",
"@fragment fn fsStencilCir(v: CirV) -> @location(0) vec4<f32> {",
"  let d = distance(v.w, v.c);",
"  if (d > v.r.x || (v.r.y > 0.0 && d < v.r.y)) { discard; } return vec4<f32>(0.0);",
"}",
"@fragment fn fsStencilPad(v: PadV) -> @location(0) vec4<f32> {",
"  let d = v.w - v.c; var dist: f32;",
"  if (v.shape > 1.5) {",
"    let e2 = vec2<f32>(-v.e1.y, v.e1.x); var a = v.c; var b = v.c; var r = v.h.y;",
"    if (v.h.x >= v.h.y) { a = v.c-v.e1*(v.h.x-v.h.y); b = v.c+v.e1*(v.h.x-v.h.y); r = v.h.y; }",
"    else { a = v.c-e2*(v.h.y-v.h.x); b = v.c+e2*(v.h.y-v.h.x); r = v.h.x; }",
"    dist = segDist(v.w, a, b) - r;",
"  } else if (v.shape > 0.5) { dist = length(d) - v.h.x; }",
"  else { let e2 = vec2<f32>(-v.e1.y, v.e1.x);",
"    let q = abs(vec2<f32>(dot(d,v.e1), dot(d,e2))) - v.h;",
"    dist = length(max(q,vec2<f32>(0.0))) + min(max(q.x,q.y),0.0); }",
"  if (dist > 0.0) { discard; } return vec4<f32>(0.0);",
"}",
"@fragment fn fsStencilArc(v: ArcV) -> @location(0) vec4<f32> {",
"  let tau=6.28318530718; let av=atan2(v.w.y-v.c.y,v.w.x-v.c.x);",
"  let a0=atan2(v.a.y-v.c.y,v.a.x-v.c.x); let a1=atan2(v.b.y-v.c.y,v.b.x-v.c.x);",
"  var span=a1-a0; span=span-floor(span/tau)*tau; var rel=av-a0; rel=rel-floor(rel/tau)*tau;",
"  if (v.dir < 0.0) { span=a0-a1; span=span-floor(span/tau)*tau; rel=a0-av; rel=rel-floor(rel/tau)*tau; }",
"  var d=abs(distance(v.w,v.c)-v.rh.x); if (rel > span) { d=min(distance(v.w,v.a),distance(v.w,v.b)); }",
"  if (d > v.rh.y) { discard; } return vec4<f32>(0.0);",
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
"",
"// CAM retained-film tint and camera composite.",
"@vertex fn vsFull(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {",
"  let p = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));",
"  return vec4<f32>(p[vi], 0.0, 1.0);",
"}",
"@fragment fn fsFull() -> @location(0) vec4<f32> { return premul(vec3<f32>(1.0), du.p.x); }",
"@fragment fn fsCamTint() -> @location(0) vec4<f32> {",
"  if (du.p.a <= 0.0) { discard; } return premul(du.p.rgb, du.p.a);",
"}",
"@group(2) @binding(0) var camFilm: texture_2d<f32>;",
"@group(2) @binding(1) var camFilmSampler: sampler;",
"@fragment fn fsCamBlit(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {",
"  let w = vec2<f32>(cam.vb.x + p.x / cam.px.x * cam.vb.z, cam.vb.y + p.y / cam.px.y * cam.vb.w);",
"  let uv = (w - cam.grid.xy) / cam.grid.zw;",
"  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) { discard; }",
"  return textureSampleLevel(camFilm, camFilmSampler, uv, 0.0);",
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
var SEG_F = 12, CIR_F = 8, PAD_F = 12, POLY_F = 8, ARC_F = 16, FAN_F = 2, COVER_F = 8;
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
var L_ARC = vbl(64, [{ shaderLocation: 0, offset: 0, format: "float32x4" },
                     { shaderLocation: 1, offset: 16, format: "float32x4" },
                     { shaderLocation: 2, offset: 32, format: "float32x4" },
                     { shaderLocation: 3, offset: 48, format: "float32x4" }]);
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
function ds(front, readMask, writeMask) {
  return { format: "stencil8", depthWriteEnabled: false, depthCompare: "always",
    stencilFront: front, stencilBack: front,
    stencilReadMask: readMask == null ? 0xff : readMask,
    stencilWriteMask: writeMask == null ? 0xff : writeMask };
}
var ST_KEEP = { compare: "always", failOp: "keep", depthFailOp: "keep", passOp: "keep" },
    ST_INVERT = { compare: "always", failOp: "keep", depthFailOp: "keep", passOp: "invert" },
    ST_COVER = { compare: "not-equal", failOp: "keep", depthFailOp: "keep", passOp: "replace" },
    ST_CAM_CLIP = { compare: "equal", failOp: "keep", depthFailOp: "keep", passOp: "keep" },
    ST_CAM_WRITE = { compare: "equal", failOp: "keep", depthFailOp: "keep", passOp: "replace" },
    ST_CAM_SHOW = { compare: "equal", failOp: "keep", depthFailOp: "keep", passOp: "keep" };

// ── init / teardown ─────────────────────────────────────────────────────
// Resolves false — never rejects — on every unsupported path, so the caller's
// success branch is the only place that can turn the renderer on.
function init(opts) {
  try {
    api.error = null;
    if (!opts || !opts.ref || !opts.host) { api.error = "WebGPU renderer options are incomplete"; return Promise.resolve(false); }
    if (!navigator.gpu) { api.error = "WebGPU is not available"; return Promise.resolve(false); }
    O = opts;
    return navigator.gpu.requestAdapter().then(function (ad) {
      if (!ad) { api.error = "No WebGPU adapter is available"; return false; }
      return ad.requestDevice().then(function (d) {
        if (!d) { api.error = "No WebGPU device is available"; return false; }
        return setup(d);
      });
    }).catch(function (e) { api.error = String(e && (e.message || e) || "WebGPU initialization failed"); teardown(); return false; });
  } catch (e) { api.error = String(e && (e.message || e) || "WebGPU initialization failed"); teardown(); return Promise.resolve(false); }
}

function setup(d) {
  dev = d;
  cvs = document.createElement("canvas");
  cvs.className = O.ref.className;   // .pcb-scene — absolute, pointer-events:none, z-index 0
  cvs.style.zIndex = "0";
  gctx = cvs.getContext("webgpu");
  if (!gctx) { api.error = "A WebGPU canvas context is not available"; teardown(); return false; }
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
    api.error = String(ev.error && ev.error.message || "uncaptured WebGPU error");
    console.error("pcb_gpu: device error, renderer disabled —", ev.error && ev.error.message);
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
  var bgl2 = dev.createBindGroupLayout({ entries: [
    { binding: 0, visibility: GPUShaderStage.FRAGMENT,
      texture: { sampleType: "float", viewDimension: "2d", multisampled: false } },
    { binding: 1, visibility: GPUShaderStage.FRAGMENT,
      sampler: { type: "filtering" } },
  ] });
  var pl = dev.createPipelineLayout({ bindGroupLayouts: [bgl0, bgl1] });
  var plCam = dev.createPipelineLayout({ bindGroupLayouts: [bgl0, bgl1, bgl2] });
  var blend = {
    color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
    alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
  };
  var eraseBlend = {
    color: { srcFactor: "zero", dstFactor: "one-minus-src-alpha", operation: "add" },
    alpha: { srcFactor: "zero", dstFactor: "one-minus-src-alpha", operation: "add" },
  };
  var mk = function (vs, fs, layout, topo, stencil, mask, blendMode, readMask, writeMask) {
    var target = (mask === 0) ? { format: fmt, writeMask: 0 }
      : { format: fmt, blend: blendMode === "erase" ? eraseBlend : blend };
    return dev.createRenderPipeline({
      layout: pl,
      vertex: { module: sh, entryPoint: vs, buffers: layout ? [layout] : [] },
      fragment: { module: sh, entryPoint: fs, targets: [target] },
      primitive: { topology: topo || "triangle-strip", cullMode: "none" },
      depthStencil: ds(stencil || ST_KEEP, readMask, writeMask),
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
  // CAM bit 0 is the finished-board clip. Bit 1 is the current Gerber film:
  // dark/clear operations REPLACE only that bit, then one tinted fullscreen
  // draw composites the finished film where both bits are set. Every film
  // stays in this one render pass; there are no viewport-sized scratch films.
  var camStencil = function (vs, fs, layout, topo) {
    return mk(vs, fs, layout, topo, ST_CAM_WRITE, 0, "paint", 1, 2);
  };
  pipeCamBoard = mk("vsFan", "fsFan", L_FAN, "triangle-list", ST_INVERT, 0, "paint", 0xff, 1);
  pipeCamReset = mk("vsFull", "fsFull", null, "triangle-list", ST_CAM_WRITE, 0, "paint", 1, 2);
  pipeCamTint = mk("vsFull", "fsCamTint", null, "triangle-list", ST_CAM_SHOW, 1, "paint", 3, 0);
  pipeCamSub = mk("vsFull", "fsCamTint", null, "triangle-list", ST_CAM_CLIP, 1, "paint", 1, 0);
  pipeCamSeg = camStencil("vsSeg", "fsStencilSeg", L_SEG);
  pipeCamCir = camStencil("vsCir", "fsStencilCir", L_CIR);
  pipeCamPad = camStencil("vsPad", "fsStencilPad", L_PAD);
  pipeCamPoly = camStencil("vsPoly", "fsPoly", L_POLY, "triangle-list");
  pipeCamArc = camStencil("vsArc", "fsStencilArc", L_ARC);
  pipeCamBlit = dev.createRenderPipeline({
    layout: plCam,
    vertex: { module: sh, entryPoint: "vsFull", buffers: [] },
    fragment: { module: sh, entryPoint: "fsCamBlit", targets: [{ format: fmt, blend: blend }] },
    primitive: { topology: "triangle-list", cullMode: "none" },
  });
  camSampler = dev.createSampler({ magFilter: "linear", minFilter: "linear" });
  O.camTextureLayout = bgl2;

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
  dirtyCu = dirtyPt = dirtyPo = camDirty = true; camFailed = false;
  api.active = true;
  if (dev.lost && dev.lost.then) dev.lost.then(function (info) {
    if (!api.active) return;
    api.error = "WebGPU device lost: " + String(info && (info.message || info.reason) || "unknown");
    dispose();
    try { if (O && O.onLost) O.onLost(info); } catch (e) {}
  });
  return true;
}

function teardown() {
  api.active = false;
  partsExcl = null;
  camGeoDrop();
  [segBuf, viaBuf, boreBuf, padBuf, polyBuf, fanBuf, coverBuf, camBuf, drawBuf, stTex].forEach(function (b) {
    try { if (b && b.destroy) b.destroy(); } catch (e) {}
  });
  segBuf = viaBuf = boreBuf = padBuf = polyBuf = fanBuf = coverBuf = camBuf = drawBuf = null;
  [camFilm, camFilmStencil].forEach(function (t) { try { if (t && t.destroy) t.destroy(); } catch (e) {} });
  camFilm = camFilmView = camFilmBg = camFilmStencil = camSampler = null;
  camFilmW = camFilmH = 0; camFilmKey = "";
  stTex = stView = null; stW = stH = 0;
  pipeSeg = pipeCir = pipePad = pipePoly = pipeGrid = pipeFan = pipeCover = bg0 = bg1 = null;
  pipeCamSeg = pipeCamCir = pipeCamPad = pipeCamPoly = pipeCamArc = null;
  pipeCamBoard = pipeCamReset = pipeCamTint = pipeCamSub = pipeCamBlit = null;
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
function rebuildCam() { camDirty = true; camFailed = false; }

// ── instance buffers ────────────────────────────────────────────────────
function upload(old, arr) {
  try { if (old && old.destroy) old.destroy(); } catch (e) {}
  if (!arr || !arr.length) return null;
  var b = dev.createBuffer({ size: arr.byteLength,
    usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
  dev.queue.writeBuffer(b, 0, arr);
  return b;
}

// ── retained manufacturing artwork ───────────────────────────────────────
// Triangulate each Gerber region once, at CAM install time, so a frame never
// walks its points. pcb_region.js takes the fast Earcut path for simple rings
// and decomposes self-crossing clearance contours by their non-zero winding.
// Clear regions remain separate ordered runs and therefore retain polarity.
function camRingClean(raw) {
  var out = [], eps = 1e-10;
  for (var i = 0; i < (raw || []).length; i++) {
    var p = raw[i], x = +(p && p[0]), y = +(p && p[1]);
    if (!isFinite(x) || !isFinite(y)) continue;
    var q = out[out.length - 1];
    if (!q || Math.abs(q[0] - x) > eps || Math.abs(q[1] - y) > eps) out.push([x, y]);
  }
  if (out.length > 2) {
    var f = out[0], z = out[out.length - 1];
    if (Math.abs(f[0] - z[0]) <= eps && Math.abs(f[1] - z[1]) <= eps) out.pop();
  }
  return out;
}
function camTriangulate(raw, out) {
  if (typeof window.PCBRegionTriangles !== "function") return false;
  var triangles = window.PCBRegionTriangles(raw);
  if (!triangles || triangles.length < 3) return false;
  for (var i = 0; i < triangles.length; i++) {
    var q = triangles[i];
    out.push(ux(q[0]), uy(q[1]), 0, 0, 1, 1, 1, 1);
  }
  return true;
}
function camBoardRing() {
  var P = O.PCB, p = P.board_poly;
  if (p && p.length >= 3) return camRingClean(p);
  p = P.outline && P.outline.pts;
  if (p && p.length >= 3) return camRingClean(p);
  var b = P.board;
  return b && b.w > 0 && b.h > 0 ? [[b.x, b.y], [b.x + b.w, b.y],
    [b.x + b.w, b.y + b.h], [b.x, b.y + b.h]] : [];
}
function camGeoDrop() {
  if (!camGeo) return;
  [camGeo.boardBuf, camGeo.segBuf, camGeo.cirBuf, camGeo.padBuf, camGeo.polyBuf, camGeo.arcBuf,
   camGeo.heatPadBuf, camGeo.heatSegBuf]
    .forEach(function (b) { try { if (b && b.destroy) b.destroy(); } catch (e) {} });
  camGeo = null;
  camFilmKey = "";
}
function camOpDark(o) { return o[0] === "r" ? !!o[1] : !!o[o.length - 1]; }
function camBuild() {
  camGeoDrop();
  api.error = null;
  var src = O.PCB.cam, layers = src && src.layers;
  if (!src || src.source !== "generated-gerber" || !Array.isArray(layers) ||
      layers.length > CAM_MAX_LAYERS) { api.error = "unsupported CAM payload"; camDirty = false; camFailed = true; return false; }
  var board = camBoardRing();
  if (board.length < 3) { api.error = "CAM board outline is empty"; camDirty = false; camFailed = true; return false; }
  var fan = [], v0 = board[0];
  var bx0 = ux(v0[0]), by0 = uy(v0[1]), bx1 = bx0, by1 = by0;
  for (var bb = 1; bb < board.length; bb++) {
    var bxx = ux(board[bb][0]), byy = uy(board[bb][1]);
    bx0 = Math.min(bx0, bxx); by0 = Math.min(by0, byy);
    bx1 = Math.max(bx1, bxx); by1 = Math.max(by1, byy);
  }
  for (var bi = 1; bi + 1 < board.length; bi++) {
    fan.push(ux(v0[0]), uy(v0[1]), ux(board[bi][0]), uy(board[bi][1]),
      ux(board[bi + 1][0]), uy(board[bi + 1][1]));
  }
  var seg = [], cir = [], pad = [], poly = [], arc = [], built = [], byId = {};
  function range(a, stride, emit) { var first = a.length / stride; emit(); return { first: first, count: a.length / stride - first }; }
  function emitFlash(o) {
    var shape = o[3] === 0 ? 1 : (o[3] === 1 ? 0 : 2), hw = (+o[4] || 0) * O.S / 2,
        hh = (shape === 1 ? (+o[4] || 0) : (+o[5] || 0)) * O.S / 2;
    pad.push(ux(+o[1]), uy(+o[2]), hw, hh, 1, 0, shape, 0, 1, 1, 1, 1);
  }
  function emitLine(o) {
    seg.push(ux(+o[1]), uy(+o[2]), ux(+o[3]), uy(+o[4]), (+o[5] || 0) * O.S / 2,
      0, 0, 0, 1, 1, 1, 1);
  }
  function emitArc(o) {
    var cx = ux(+o[5]), cy = uy(+o[6]), ax = ux(+o[1]), ay = uy(+o[2]);
    arc.push(cx, cy, Math.hypot(ax - cx, ay - cy), (+o[7] || 0) * O.S / 2,
      ax, ay, ux(+o[3]), uy(+o[4]), o[8] ? 1 : -1, 0, 0, 0, 1, 1, 1, 1);
  }
  for (var li = 0; li < layers.length; li++) {
    var L = layers[li], ops = L.ops || [], runs = [], run = null;
    for (var oi = 0; oi < ops.length; oi++) {
      var o = ops[oi], dark = camOpDark(o); if (L.negative) dark = !dark;
      if (!run || run.dark !== dark) { run = { dark: dark, f: [], l: [], a: [], r: [] }; runs.push(run); }
      if (run[o[0]]) run[o[0]].push(o);
    }
    var desc = { id: String(L.id || ("cam-" + li)), negative: !!L.negative, commands: [] };
    for (var ri = 0; ri < runs.length; ri++) {
      run = runs[ri];
      if (run.f.length) desc.commands.push({ kind: "pad", dark: run.dark,
        range: range(pad, PAD_F, function () { run.f.forEach(emitFlash); }) });
      if (run.l.length) desc.commands.push({ kind: "seg", dark: run.dark,
        range: range(seg, SEG_F, function () { run.l.forEach(emitLine); }) });
      if (run.a.length) desc.commands.push({ kind: "arc", dark: run.dark,
        range: range(arc, ARC_F, function () { run.a.forEach(emitArc); }) });
      if (run.r.length) {
        var first = poly.length / POLY_F, okay = true;
        for (var rr = 0; rr < run.r.length; rr++) if (!camTriangulate(run.r[rr][2], poly)) { okay = false; break; }
        if (!okay) { api.error = "CAM region triangulation failed in " + desc.id; camDirty = false; camFailed = true; return false; }
        desc.commands.push({ kind: "poly", dark: run.dark,
          range: { first: first, count: poly.length / POLY_F - first } });
      }
    }
    built.push(desc); byId[desc.id] = desc;
  }
  // Opposite-face hardware is part of the retained film so it can sit behind
  // the opaque substrate without reviving the Canvas CAM fallback. Its colour
  // is baked per instance; the host decides per frame whether this is the rear
  // face, causing one film rebuild only when orientation/visibility changes.
  var heatPad = [], heatSeg = [], heat = null, hs = O.PCB && O.PCB.heatsink;
  if (hs && +hs.w > 0 && +hs.h > 0) {
    var hx0 = ux(+hs.x), hy0 = uy(+hs.y), hx1 = ux(+hs.x + +hs.w), hy1 = uy(+hs.y + +hs.h),
        hc = rgb(hs.side === "top" ? "#f59e0b" : "#38bdf8"),
        hcx = (hx0 + hx1) / 2, hcy = (hy0 + hy1) / 2;
    heatPad.push(hcx, hcy, Math.abs(hx1 - hx0) / 2, Math.abs(hy1 - hy0) / 2,
      1, 0, 0, 0, hc[0], hc[1], hc[2], 0.24);
    function heatLine(x0, y0, x1, y1, hw, alpha) {
      heatSeg.push(x0, y0, x1, y1, hw, 0, 0, 0, hc[0], hc[1], hc[2], alpha);
    }
    heatLine(hx0, hy0, hx1, hy0, 0.85, 0.24); heatLine(hx1, hy0, hx1, hy1, 0.85, 0.24);
    heatLine(hx1, hy1, hx0, hy1, 0.85, 0.24); heatLine(hx0, hy1, hx0, hy0, 0.85, 0.24);
    var axis = hs.fin_axis || "length", gap = Math.max(+hs.fin_gap_mm || 0, 0),
        pitch = (+hs.fin_thickness_mm || 1) + gap, across = axis === "length" ? +hs.w : +hs.h,
        hn = Math.min(512, Math.max(1, Math.floor((across + gap) / pitch)));
    for (var hi = 0; hi < hn; hi++) { var hq = (hi + 0.5) / hn;
      if (axis === "length") heatLine(hx0 + hq * (hx1 - hx0), hy0, hx0 + hq * (hx1 - hx0), hy1, 0.5, 0.7);
      else heatLine(hx0, hy0 + hq * (hy1 - hy0), hx1, hy0 + hq * (hy1 - hy0), 0.5, 0.7);
    }
    heat = { x0: Math.min(hx0, hx1), y0: Math.min(hy0, hy1), x1: Math.max(hx0, hx1), y1: Math.max(hy0, hy1),
      padRange: { first: 0, count: heatPad.length / PAD_F }, segRange: { first: 0, count: heatSeg.length / SEG_F } };
  }
  camGeo = {
    source: src, layers: built, byId: byId,
    bounds: { x: bx0, y: by0, w: Math.max(bx1 - bx0, 1), h: Math.max(by1 - by0, 1) },
    boardBuf: upload(null, new Float32Array(fan)), boardRange: { first: 0, count: fan.length / FAN_F },
    segBuf: upload(null, new Float32Array(seg)), cirBuf: upload(null, new Float32Array(cir)),
    padBuf: upload(null, new Float32Array(pad)), polyBuf: upload(null, new Float32Array(poly)),
    arcBuf: upload(null, new Float32Array(arc)),
    heat: heat, heatPadBuf: upload(null, new Float32Array(heatPad)), heatSegBuf: upload(null, new Float32Array(heatSeg)),
  };
  camDirty = false; camFailed = false; return true;
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

function encodeCamLayer(pass, layer, slot) {
  var base = slotBase(), unitSlot = base + S_CAM;
  pass.setBindGroup(0, bg0);
  pass.setBindGroup(1, bg1, [unitSlot * DSTRIDE]);
  pass.setStencilReference(layer.negative ? 3 : 1);
  pass.setPipeline(pipeCamReset); pass.draw(3, 1, 0, 0);
  for (var i = 0; i < layer.commands.length; i++) {
    var c = layer.commands[i], pipe = null, buf = null, verts = false;
    if (c.kind === "seg") { pipe = pipeCamSeg; buf = camGeo.segBuf; }
    else if (c.kind === "cir") { pipe = pipeCamCir; buf = camGeo.cirBuf; }
    else if (c.kind === "pad") { pipe = pipeCamPad; buf = camGeo.padBuf; }
    else if (c.kind === "poly") { pipe = pipeCamPoly; buf = camGeo.polyBuf; verts = true; }
    else if (c.kind === "arc") { pipe = pipeCamArc; buf = camGeo.arcBuf; }
    if (!pipe || !buf || !c.range || !c.range.count) continue;
    pass.setStencilReference(c.dark ? 3 : 1);
    pass.setPipeline(pipe); pass.setVertexBuffer(0, buf);
    if (verts) pass.draw(c.range.count, 1, c.range.first, 0);
    else pass.draw(4, c.range.count, 0, c.range.first);
  }
  pass.setBindGroup(1, bg1, [slot * DSTRIDE]);
  pass.setStencilReference(3); pass.setPipeline(pipeCamTint); pass.draw(3, 1, 0, 0);
}
function camEncodeScene(p, base, layers, rearHeatsink) {
  p.setBindGroup(0, bg0); p.setBindGroup(1, bg1, [(base + S_CAM) * DSTRIDE]);
  var heat = rearHeatsink && camGeo.heat;
  if (heat && camGeo.heatPadBuf && heat.padRange.count) {
    p.setStencilReference(0); p.setPipeline(pipePad); p.setVertexBuffer(0, camGeo.heatPadBuf);
    p.draw(4, heat.padRange.count, 0, heat.padRange.first);
  }
  if (heat && camGeo.heatSegBuf && heat.segRange.count) {
    p.setStencilReference(0); p.setPipeline(pipeSeg); p.setVertexBuffer(0, camGeo.heatSegBuf);
    p.draw(4, heat.segRange.count, 0, heat.segRange.first);
  }
  p.setStencilReference(0); p.setPipeline(pipeCamBoard); p.setVertexBuffer(0, camGeo.boardBuf);
  p.draw(camGeo.boardRange.count, 1, camGeo.boardRange.first, 0);
  p.setBindGroup(1, bg1, [(base + S_CAM + 1) * DSTRIDE]);
  p.setStencilReference(1); p.setPipeline(pipeCamSub); p.draw(3, 1, 0, 0);
  for (var i = 0; i < layers.length; i++) {
    var want = layers[i], L = camGeo.byId[String(want.id || "")];
    if (L && want.a > 0) encodeCamLayer(p, L, base + S_CAM + 2 + i);
  }
}
function camBounds(rearHeatsink) {
  var b = camGeo.bounds, h = rearHeatsink && camGeo.heat;
  if (!h) return b;
  var x0 = Math.min(b.x, h.x0), y0 = Math.min(b.y, h.y0), x1 = Math.max(b.x + b.w, h.x1), y1 = Math.max(b.y + b.h, h.y1);
  return { x: x0, y: y0, w: Math.max(x1 - x0, 1), h: Math.max(y1 - y0, 1) };
}
function camFilmEnsure(b) {
  var limit = +(dev.limits && dev.limits.maxTextureDimension2D) || 4096;
  var w = Math.min(limit, Math.max(2048, cvs.width * 3)), h = Math.ceil(w * b.h / b.w);
  if (h > limit) { h = limit; w = Math.ceil(h * b.w / b.h); }
  w = Math.max(1, Math.floor(w)); h = Math.max(1, Math.floor(h));
  if (camFilm && camFilmW === w && camFilmH === h) return true;
  [camFilm, camFilmStencil].forEach(function (t) { try { if (t && t.destroy) t.destroy(); } catch (e) {} });
  camFilm = dev.createTexture({ size: [w, h], format: colorFmt,
    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING });
  camFilmStencil = dev.createTexture({ size: [w, h], format: "stencil8",
    usage: GPUTextureUsage.RENDER_ATTACHMENT });
  camFilmView = camFilm.createView(); camFilmW = w; camFilmH = h; camFilmKey = "";
  camFilmBg = dev.createBindGroup({ layout: O.camTextureLayout, entries: [
    { binding: 0, resource: camFilmView }, { binding: 1, resource: camSampler },
  ] });
  return true;
}
function camBake(base, layers, key, rearHeatsink, b) {
  if (!camFilmEnsure(b)) return false;
  camA[0] = b.x; camA[1] = b.y; camA[2] = b.w; camA[3] = b.h;
  camA[4] = camFilmW; camA[5] = camFilmH;
  for (var ci = 6; ci < 16; ci++) camA[ci] = 0;
  dev.queue.writeBuffer(camBuf, 0, camA);
  var enc = dev.createCommandEncoder(), p = enc.beginRenderPass({
    colorAttachments: [{ view: camFilmView,
      clearValue: { r: 0, g: 0, b: 0, a: 0 }, loadOp: "clear", storeOp: "store" }],
    depthStencilAttachment: { view: camFilmStencil.createView(),
      stencilClearValue: 0, stencilLoadOp: "clear", stencilStoreOp: "discard" },
  });
  camEncodeScene(p, base, layers, rearHeatsink); p.end(); dev.queue.submit([enc.finish()]); camFilmKey = key;
  return true;
}
function camFrame(vb, st) {
  if (camFailed && !camDirty) return false;
  if (camDirty || !camGeo || camGeo.source !== O.PCB.cam) if (!camBuild()) return false;
  if (camFailed || !camGeo) return false;
  var cst = st.cam || {}, base = slotBase(), layers = cst.layers || [];
  if (layers.length > CAM_MAX_LAYERS) return false;
  drawA.fill(0); drawA[(base + S_CAM) * DFLOATS] = 1;
  function setCol(slot, col, alpha) {
    var c = rgb(col), b = slot * DFLOATS;
    drawA[b] = c[0]; drawA[b + 1] = c[1]; drawA[b + 2] = c[2]; drawA[b + 3] = alpha == null ? 1 : alpha;
  }
  setCol(base + S_CAM + 1, cst.substrate, 1);
  for (var i = 0; i < layers.length; i++) setCol(base + S_CAM + 2 + i, layers[i].col, layers[i].a);
  dev.queue.writeBuffer(drawBuf, 0, drawA);
  var rearHeatsink = !!cst.rearHeatsink, bounds = camBounds(rearHeatsink),
      key = JSON.stringify([cst.substrate, layers, rearHeatsink, cvs.width, cvs.height]);
  if (!camFilm || camFilmKey !== key) if (!camBake(base, layers, key, rearHeatsink, bounds)) return false;
  camA[0] = vb.x; camA[1] = vb.y; camA[2] = vb.w; camA[3] = vb.h;
  camA[4] = cvs.width; camA[5] = cvs.height; camA[6] = camA[7] = 0;
  camA[8] = bounds.x; camA[9] = bounds.y; camA[10] = bounds.w; camA[11] = bounds.h;
  for (i = 12; i < 16; i++) camA[i] = 0;
  dev.queue.writeBuffer(camBuf, 0, camA);
  var enc = dev.createCommandEncoder(), bg = rgb(cst.bg), p = enc.beginRenderPass({
    colorAttachments: [{ view: gctx.getCurrentTexture().createView(),
      clearValue: { r: bg[0], g: bg[1], b: bg[2], a: 1 }, loadOp: "clear", storeOp: "store" }],
  });
  p.setPipeline(pipeCamBlit); p.setBindGroup(0, bg0);
  p.setBindGroup(1, bg1, [(base + S_CAM) * DSTRIDE]); p.setBindGroup(2, camFilmBg); p.draw(3, 1, 0, 0);
  p.end();
  dev.queue.submit([enc.finish()]); return true;
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
  if (!api.active || !dev || !gctx) return false;
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
    if (!(cvs.width > 0 && cvs.height > 0)) return false;

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

    // Physical review is a separate retained scene: manufacturing operations
    // bake the host-resolved film stack once. Camera-only frames update one
    // uniform and sample that film instead of walking Gerber operations.
    if (st && st.cam) return camFrame(vb, st);

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
    return true;
  } catch (e) {
    // A validation error or a vanished surface shuts the renderer down. The
    // editor may repaint in 2D; Assembly surfaces the hard WebGPU requirement.
    api.error = String(e && (e.stack || e.message) || e);
    dispose();
    try { if (O && O.onLost) O.onLost(e); } catch (e2) {}
    return false;
  }
}
})();
