#!/usr/bin/env node
// pcb_gpu_check — a standing correctness gate for src/serve/assets/pcb_gpu.js.
//
//   node scripts/pcb_gpu_check/run.js <pcb_blob.json> [assets_dir]
//
// The WebGPU renderer cannot be exercised in Node (there is no adapter) and its
// failure mode in a browser is the worst kind: a validation error is reported
// ASYNCHRONOUSLY, so a wrong pipeline or a wrong instance offset shows up as a
// board that is subtly misdrawn, or as nothing at all, with no exception to
// catch. This script runs the REAL module — not a transcription of it — against
// a fake `navigator.gpu` that records every pipeline descriptor, buffer write
// and draw call, then checks what was recorded against an INDEPENDENT ground
// truth: a literal 3x3 replay of the Canvas2D transform chain paintParts /
// padPath draw under, and the colour each hook actually returned.
//
// What it proves, in order:
//   A  transforms  every baked instance (track, pad, poly-pad, bore, via) is at
//                  the position, size, orientation and colour the 2D painter
//                  would have drawn it at — compared per instance, IN ORDER,
//                  against the affine replay, over a synthetic matrix of every
//                  rotation x side x pad-rotation combination and over a real
//                  board blob.
//   B  ranges      every draw range tiles its buffer exactly: no gap, no
//                  overlap, no over-run. This is where a firstInstance/count
//                  bookkeeping slip surfaces.
//   C  stencil     the pour pipeline pair really implements even-odd: fan
//                  vertex count = the sum of its rings' fans, the cover quad
//                  contains every ring, the fan pipeline is (compare always,
//                  INVERT, colorWrites off) and the cover is (not-equal 0,
//                  REPLACE) at stencil reference 0 — so each area self-clears.
//                  The shared RF-union cover also runs at zero alpha, so a
//                  hidden layer cannot leave stencil for the next visible one.
//   D  pass/pipe   the render pass carries a stencil8 attachment and EVERY
//                  pipeline declares the same format. A pass/pipeline
//                  depth-stencil mismatch is a runtime validation error, and
//                  adding a stencil attachment for one pipeline breaks all the
//                  others; this check is the reason that integration bug can't
//                  ship.
//   E  order       clear -> grid -> pour fills -> pads -> copper -> vias. The
//                  M1 renderer drew pours in 2D ON TOP of GPU copper; this
//                  pins the corrected order.
//   F  wgsl        every smoothstep has its edges in order (a reversed pair is
//                  a silent inversion, not an error), the annulus keeps its
//                  rInner>0 guard (without it every via centre dims), and every
//                  vertex-buffer layout matches the @location list of the entry
//                  point it feeds.
//   G  one rule    pcb_board.js's GPU-side colour/alpha ladders are the SAME
//                  TEXT as its 2D ones, and the seams that invalidate the baked
//                  buffers are wired. The two renderers can only agree if the
//                  rules are literally one expression; this greps that they are.
//   H  interaction the two M3 mutations of a baked buffer, re-checked END TO END
//                  by re-running A and B over the rebaked frame: an EXCLUSION
//                  bake (a part drag — the excluded parts contribute no pad, no
//                  poly pad and no bore, every other part is untouched, and the
//                  ranges still tile) and a GESTURE bake (a track dragged the way
//                  segMove drags it, then rebuildCopper + one frame — the new
//                  coordinates are what landed). Plus the JS cost of a copper
//                  rebake, reported so a regression in it is visible.
//   I  bundles     a second camera-only frame replays the complete draw stream
//                  without recording a new render bundle.
//
// Dependency-free by design (the repo's viewer assets have no build step).
"use strict";
const fs = require("fs");
const path = require("path");

const blobPath = process.argv[2];
const assets = process.argv[3] || path.join(__dirname, "..", "..", "src", "serve", "assets");
if (!blobPath || !fs.existsSync(blobPath)) {
  console.error("usage: run.js <pcb_blob.json> [assets_dir]");
  process.exit(2);
}

// ── check bookkeeping ───────────────────────────────────────────────────
let checked = 0;
const failures = [];
function ok(cond, label, detail) {
  checked++;
  if (!cond) failures.push(label + (detail === undefined ? "" : " — " + detail));
  return !!cond;
}
const EPS = 1e-3;
function nearOk(a, b, label) { return ok(Math.abs(a - b) <= EPS, label, a + " vs " + b); }

// ── fake WebGPU ─────────────────────────────────────────────────────────
// Records everything the renderer submits. Nothing is validated here on
// purpose: the checks below are explicit, so a silent "the fake accepted it"
// can never stand in for a real assertion.
function fakeGpu() {
  const cap = { buffers: [], textures: [], pipelines: {}, pipeList: [], wgsl: "", pass: null, cmds: [], bundleBuilds: 0 };
  const mkBuf = (d) => {
    const b = { size: d.size, usage: d.usage, data: null, i: cap.buffers.length,
      destroy() { b.dead = true; } };
    cap.buffers.push(b);
    return b;
  };
  const recorder = (out) => ({
    _pipe: null, _vb: null, _slot: 0, _ref: null,
    setBindGroup(i, g, off) { if (i === 1) this._slot = off ? off[0] / 256 : 0; },
    setPipeline(p) { this._pipe = p && p.__name; },
    setVertexBuffer(i, b) { this._vb = b; },
    setStencilReference(r) { this._ref = r; },
    draw(a, b, c, d) {
      out.push({ pipe: this._pipe, slot: this._slot, ref: this._ref,
        vb: this._vb ? this._vb.i : null, a: a, b: b, c: c, d: d });
    },
    finish() { return { cmds: out.slice() }; },
  });
  const pass = Object.assign(recorder(cap.cmds), {
    executeBundles(bs) { (bs || []).forEach((b) => (b.cmds || []).forEach((c) => cap.cmds.push(Object.assign({}, c)))); },
    end() {},
  });
  const device = {
    createShaderModule(d) { cap.wgsl = d.code; return { code: d.code }; },
    createBindGroupLayout: () => ({}),
    createPipelineLayout: () => ({}),
    createSampler: () => ({}),
    createRenderPipeline(d) {
      const name = d.vertex.entryPoint;
      cap.pipelines[name] = d;
      cap.pipeList.push(name);
      return { __name: name };
    },
    createBindGroup: () => ({}),
    createRenderBundleEncoder() { cap.bundleBuilds++; return recorder([]); },
    createBuffer: mkBuf,
    createTexture(d) {
      const t = { desc: d, destroy() {}, createView: () => ({ __tex: d }) };
      cap.textures.push(t);
      return t;
    },
    createCommandEncoder: () => ({
      // A fresh pass starts with nothing bound — the same pass object is reused
      // across frames here, and without this reset the grid (which binds no
      // vertex buffer at all) would inherit the previous frame's.
      beginRenderPass(d) {
        cap.pass = d;
        pass._pipe = null; pass._vb = null; pass._slot = 0; pass._ref = null;
        return pass;
      },
      finish: () => ({}),
    }),
    queue: {
      submit() {},
      // `new Float32Array(typedArray)` and not Float32Array.from(): `from` walks
      // the ITERATOR protocol even for a typed array, which turns a 6 k-float
      // copy into 6 k iterator steps and made the fake device, not the renderer,
      // the thing the rebake microbench below was timing.
      writeBuffer(buf, off, data) {
        if (off === 0) buf.data = new Float32Array(data);
        else { const a = buf.data || new Float32Array(buf.size / 4); a.set(data, off / 4); buf.data = a; }
      },
    },
    lost: new Promise(() => {}),
  };
  return { device, cap };
}

function fakeCanvas() {
  return {
    width: 0, height: 0, className: "", style: {},
    getContext: (k) => (k === "webgpu"
      ? { configure() {}, getCurrentTexture: () => ({ createView: () => ({}) }) }
      : null),
  };
}

function installGlobals(device) {
  globalThis.GPUShaderStage = { VERTEX: 1, FRAGMENT: 2 };
  globalThis.GPUBufferUsage = { UNIFORM: 1, COPY_DST: 2, VERTEX: 4 };
  globalThis.GPUTextureUsage = { RENDER_ATTACHMENT: 16, TEXTURE_BINDING: 32 };
  globalThis.document = { createElement: () => fakeCanvas() };
  // Node ships a read-only `navigator` accessor on globalThis — plain assignment
  // silently no-ops, so define over it.
  Object.defineProperty(globalThis, "navigator", {
    configurable: true, writable: true,
    value: {
      gpu: {
        requestAdapter: () => Promise.resolve({ requestDevice: () => Promise.resolve(device) }),
        getPreferredCanvasFormat: () => "bgra8unorm",
      },
    },
  });
  globalThis.window = globalThis;
}

// ── ground truth: a literal replay of the Canvas2D transform chain ──────
// 2x3 affine [a,b,c,d,e,f]; canvas post-multiplies, so `then` composes m·n.
const I = () => [1, 0, 0, 1, 0, 0];
const then = (m, n) => [
  m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
  m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
  m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5],
];
const T = (x, y) => [1, 0, 0, 1, x, y];
const R = (rad) => [Math.cos(rad), Math.sin(rad), -Math.sin(rad), Math.cos(rad), 0, 0];
const SC = (x, y) => [x, 0, 0, y, 0, 0];
const ap = (m, p) => [m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5]];

let S = 1, MX = 0, MY = 0, M = 0;
const X = (mm) => (mm - MX + M) * S;
const Y = (mm) => (mm - MY + M) * S;
// paintParts: translate(X(p.x),Y(p.y)); rotate(p.rot); if bottom scale(-1,1)
function partCTM(p) {
  let m = then(I(), T(X(p.x), Y(p.y)));
  m = then(m, R((p.rot || 0) * Math.PI / 180));
  if (p.side === "bottom") m = then(m, SC(-1, 1));
  return m;
}
// padPath: translate(pd.x*S,pd.y*S); rotate(pd.rot)
function padCTM(p, pd) {
  return then(then(partCTM(p), T(pd.x * S, pd.y * S)), R((pd.rot || 0) * Math.PI / 180));
}
const sortPts = (a) => a.slice().sort((u, v) => (u[0] - v[0]) || (u[1] - v[1]));
function samePts(got, want, label) {
  const g = sortPts(got), w = sortPts(want);
  if (!ok(g.length === w.length, label, g.length + " pts vs " + w.length)) return;
  for (let i = 0; i < g.length; i++) {
    if (!ok(Math.abs(g[i][0] - w[i][0]) <= EPS && Math.abs(g[i][1] - w[i][1]) <= EPS,
      label, "pt" + i + " (" + g[i] + ") vs (" + w[i] + ")")) return;
  }
}
function hex2rgb(c) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(String(c || ""));
  return m ? [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255]
           : [0.55, 0.58, 0.62];
}
function sameCol(arr, b, want, label) {
  const w = hex2rgb(want);
  ok(Math.abs(arr[b] - w[0]) <= 1 / 255 && Math.abs(arr[b + 1] - w[1]) <= 1 / 255 &&
     Math.abs(arr[b + 2] - w[2]) <= 1 / 255, label,
     "[" + arr[b].toFixed(3) + "," + arr[b + 1].toFixed(3) + "," + arr[b + 2].toFixed(3) + "] vs " + want);
}

// ── the 2D colour rules, transcribed from pcb_board.js ──────────────────
// paintTracks/cuBatchGet: (netColOn && netColorOf(netCollapse(net))) || layerColor(L)
// paintParts pad fill:    netColOn ? (pd.net ? netColorOf(pd.net) || TH.pth : "#ffffff") : …
// Check G below greps pcb_board.js to prove these are still the spellings in use.
const netCollapse = (s) => { const i = String(s).indexOf("."); return i < 0 ? String(s) : String(s).slice(0, i); };

// ── one run of the renderer ─────────────────────────────────────────────
// `bare` drops the colour-recording wrapper below — a Map insert per track, via
// and pad that every correctness check depends on and no browser pays. Only the
// timing case asks for it, so its microbenchmark measures the renderer's own
// staging rather than the harness's bookkeeping.
function runCase(name, pcb, opt, bare) {
  const { device, cap } = fakeGpu();
  installGlobals(device);
  S = opt.S; MX = opt.MX; MY = opt.MY; M = opt.M;

  delete globalThis.PCBGpu;
  const src = fs.readFileSync(path.join(assets, "pcb_gpu.js"), "utf8");
  (0, eval)(src);
  const G = globalThis.PCBGpu;
  if (!G) throw new Error(name + ": pcb_gpu.js exported no PCBGpu");

  // Every colour the renderer asks for is RECORDED against the object it was
  // asked about, so the per-instance colour check below is not a re-derivation
  // — it is "the byte that landed is the byte this object's hook returned".
  const colOf = new Map();
  const hook = bare ? (fn) => fn : (fn) => (a, b) => { const c = fn(a, b); colOf.set(a, c); return c; };

  const ref = fakeCanvas();
  ref.width = 1200; ref.height = 800;
  ref.style = { width: "1200px", height: "800px", left: "0px", top: "0px" };
  return G.init({
    PCB: pcb, S: opt.S, MX: opt.MX, MY: opt.MY, M: opt.M,
    nsig: opt.nsig, TH: opt.TH, layerColor: opt.layerColor,
    trackColor: hook(opt.trackColor), viaColor: hook(opt.viaColor), padColor: hook(opt.padColor),
    pours: opt.pours, ref, host: { insertBefore() {} },
    // pcb_gpu.js swallows every throw and shuts itself down — the page must
    // never die for a GPU fault. That is exactly wrong for a test, so the
    // harness re-raises whatever reached the fallback path.
    onLost: (e) => { cap.lost = e; },
  }).then((started) => {
    if (!started) throw new Error(name + ": init refused");
    const rc = { name, cap, pcb, opt, colOf, G, vb: { x: 0, y: 0, w: 1000, h: 667 } };
    frameOf(rc);
    return rc;
  });
}
// One frame, with the recorded command list RESET first — so every checker below
// reads exactly the frame it asked for and never a union of two. The buffer list
// deliberately keeps growing: `upload` destroys and re-creates on every rebake,
// and classify() finds the live buffers through the new draws.
function frameOf(rc) {
  rc.cap.cmds.length = 0;
  rc.G.frame(rc.vb, rc.opt.st);
  if (rc.cap.lost) throw (rc.cap.lost instanceof Error ? rc.cap.lost
    : new Error(rc.name + ": renderer fell back — " + rc.cap.lost));
  return rc;
}
// A view of `rc` describing a DIFFERENT expected board — the ground truth the
// A/B checkers derive their expectations from. Everything else (the recorded
// commands, the colour hooks' answers) is shared.
function asBoard(rc, name, pcb) { return Object.assign({}, rc, { name, pcb }); }

// ── buffer identification ───────────────────────────────────────────────
// Vertex buffers are named by the pipeline that draws them, in the order that
// pipeline first DRAWS them this frame. Creation order was the earlier rule and
// is not usable: a rebake re-creates one buffer and not the others (a copper
// gesture makes new seg/via buffers while the pad buffer stands; a drag's
// exclusion does the reverse), so buffer indices stop reflecting the roles.
function classify(cap) {
  const byPipe = {};
  cap.cmds.forEach((d) => {
    if (d.vb === null || d.vb === undefined) return;
    const l = byPipe[d.pipe] || (byPipe[d.pipe] = []);
    if (l.indexOf(d.vb) < 0) l.push(d.vb);
  });
  return byPipe;
}
// The two vsCir consumers — drill bores and vias — share a pipeline, so they are
// told apart by what each must CONTAIN: one instance per drilled pad for the
// bores, two per via (barrel-or-ring plus its hole punch) for the vias. A board whose
// two counts collide falls back to draw order, which frame() fixes (bores under
// the copper, vias over it). Either way a wrong guess fails loudly downstream,
// where every instance is compared against the affine replay.
function cirSplit(rc, bufs) {
  const ids = bufs.vsCir || [];
  const len = (i) => {
    const d = rc.cap.buffers[i] && rc.cap.buffers[i].data;
    return d ? d.length / 8 : 0;
  };
  const vias = rc.pcb.vias || [];
  const wantVia = vias.length * 2;
  let wantBore = 0;
  (rc.pcb.parts || []).forEach((p) => (p.pads || []).forEach((pd) => { if (pd.drill > 0) wantBore++; }));
  if (wantVia !== wantBore) {
    const via = ids.filter((i) => len(i) === wantVia)[0];
    const bore = ids.filter((i) => len(i) === wantBore && i !== via)[0];
    return { via: via === undefined ? null : via, bore: bore === undefined ? null : bore };
  }
  return { bore: ids.length ? ids[0] : null, via: ids.length > 1 ? ids[1] : null };
}

const STRIDE = { vsSeg: 12, vsCir: 8, vsPad: 12, vsPoly: 8, vsFan: 2, vsUnion: 2, vsCover: 8 };
const PER_VERTEX = { vsPoly: 1, vsFan: 1, vsUnion: 1 };   // draw(count,1,first,0) vs draw(4,count,0,first)

// ── A: instance transforms + colours, compared in emission order ────────
function checkInstances(rc) {
  const { name, cap, pcb, opt, colOf } = rc;
  const bufs = classify(cap);
  const dat = (i) => (cap.buffers[i] && cap.buffers[i].data) || null;

  // ---- tracks: grouped by layer, source order within a layer ----
  const segBuf = bufs.vsSeg ? bufs.vsSeg[0] : null;
  const seg = segBuf === null ? null : dat(segBuf);
  const tracks = pcb.tracks || [];
  if (ok(!!seg === !!tracks.length, name + " A: track buffer present iff there are tracks")) {
    if (seg) {
      ok(seg.length / 12 === tracks.length, name + " A: track instance count",
        seg.length / 12 + " vs " + tracks.length);
      let k = 0;
      for (let L = 0; L < opt.nsig; L++) {
        tracks.forEach((t) => {
          if (((t.l || 0) >= 0 && (t.l || 0) < opt.nsig ? (t.l || 0) : 0) !== L) return;
          const b = k * 12;
          samePts([[seg[b], seg[b + 1]], [seg[b + 2], seg[b + 3]]],
            [[X(t.x1), Y(t.y1)], [X(t.x2), Y(t.y2)]], name + " A: track " + k + " endpoints");
          nearOk(seg[b + 4], Math.max(t.w * S, 1.2) / 2, name + " A: track " + k + " half-width");
          sameCol(seg, b + 8, colOf.get(t), name + " A: track " + k + " colour");
          nearOk(seg[b + 11], 1, name + " A: track " + k + " opaque instance alpha");
          k++;
        });
      }
      ok(k === tracks.length, name + " A: every track emitted once", k + " vs " + tracks.length);
    }
  }

  // ---- vias: [barrels, hole punches, fence hole punches, fence rings] ----
  const cir = cirSplit(rc, bufs);
  const vias = pcb.vias || [];
  const va = cir.via === null ? null : dat(cir.via);
  if (va) {
    const barrels = vias.filter((v) => !v.f), fences = vias.filter((v) => v.f);
    ok(va.length / 8 === vias.length * 2,
      name + " A: via instance count", va.length / 8 + " vs " + (vias.length * 2));
    const drill = opt.st.viaDrill;
    barrels.forEach((v, i) => {
      const rr = v.d / 2 * S;
      const rh = ((v.drill > 0) ? v.drill : drill) / 2 * S;
      const b = i * 8, h = (barrels.length + i) * 8;
      samePts([[va[b], va[b + 1]]], [[X(v.x), Y(v.y)]], name + " A: via " + i + " centre");
      nearOk(va[b + 2], rr, name + " A: via " + i + " outer radius");
      nearOk(va[b + 3], 0, name + " A: via " + i + " is a disc (rInner 0)");
      sameCol(va, b + 4, colOf.get(v), name + " A: via " + i + " colour");
      samePts([[va[h], va[h + 1]]], [[X(v.x), Y(v.y)]], name + " A: via hole " + i + " centre");
      nearOk(va[h + 2], rh, name + " A: via hole " + i + " radius");
      sameCol(va, h + 4, opt.TH.viaHole, name + " A: via hole " + i + " is the board colour");
    });
    fences.forEach((v, i) => {
      const rr = v.d / 2 * S;
      const rh = ((v.drill > 0) ? v.drill : drill) / 2 * S;
      const lw = Math.max(rr - rh, 0.9), fr = Math.max(rr - lw / 2, 0.5);
      const h = (barrels.length * 2 + i) * 8;
      const b = (barrels.length * 2 + fences.length + i) * 8;
      samePts([[va[h], va[h + 1]]], [[X(v.x), Y(v.y)]], name + " A: fence hole " + i + " centre");
      nearOk(va[h + 2], rh, name + " A: fence hole " + i + " radius");
      sameCol(va, h + 4, opt.TH.viaHole, name + " A: fence hole " + i + " is the board colour");
      samePts([[va[b], va[b + 1]]], [[X(v.x), Y(v.y)]], name + " A: fence " + i + " centre");
      nearOk(va[b + 2], fr + lw / 2, name + " A: fence " + i + " outer radius");
      nearOk(va[b + 3], Math.max(fr - lw / 2, 0), name + " A: fence " + i + " inner radius");
      ok(va[b + 3] > 0, name + " A: fence " + i + " is a RING not a disc", String(va[b + 3]));
      sameCol(va, b + 4, colOf.get(v), name + " A: fence " + i + " colour");
      nearOk(va[b + 7], 0.7, name + " A: fence " + i + " keeps the 2D ring opacity");
    });
  }

  // ---- pads / poly pads / bores: 4 groups by (through-hole?, part side) ----
  const padBuf = bufs.vsPad ? bufs.vsPad[0] : null, pad = padBuf === null ? null : dat(padBuf);
  const polyBuf = bufs.vsPoly ? bufs.vsPoly[0] : null, poly = polyBuf === null ? null : dat(polyBuf);
  const bore = cir.bore === null ? null : dat(cir.bore);
  const groups = [[], [], [], []], polyG = [[], [], [], []], boreG = [[], []];
  (pcb.parts || []).forEach((p) => {
    const bt = p.side === "bottom";
    (p.pads || []).forEach((pd) => {
      const g = (pd.drill > 0) ? (bt ? 1 : 0) : (bt ? 3 : 2);
      if (pd.drill > 0) boreG[bt ? 1 : 0].push({ p, pd });
      if (pd.poly && pd.poly.length >= 3) polyG[g].push({ p, pd, bt });
      else groups[g].push({ p, pd, bt });
    });
  });
  if (pad) {
    let k = 0;
    groups.forEach((g) => g.forEach((e) => {
      const { p, pd, bt } = e, b = k * 12, cm = padCTM(p, pd);
      const c = ap(cm, [0, 0]);
      samePts([[pad[b], pad[b + 1]]], [c], name + " A: pad " + p.ref + "." + pd.num + " centre");
      const circ = pd.shape === "circle";
      ok((pad[b + 6] > 0.5) === circ, name + " A: pad " + p.ref + "." + pd.num + " shape flag");
      if (circ) {
        nearOk(pad[b + 2], Math.min(pd.w, pd.h) / 2 * S, name + " A: pad " + p.ref + "." + pd.num + " radius");
      } else {
        const e1 = [pad[b + 4], pad[b + 5]], e2 = [-pad[b + 5], pad[b + 4]];
        const hw = pad[b + 2], hh = pad[b + 3];
        const got = [[1, 1], [1, -1], [-1, 1], [-1, -1]].map(([sx, sy]) =>
          [c[0] + e1[0] * sx * hw + e2[0] * sy * hh, c[1] + e1[1] * sx * hw + e2[1] * sy * hh]);
        const want = [[1, 1], [1, -1], [-1, 1], [-1, -1]].map(([sx, sy]) =>
          ap(cm, [sx * pd.w / 2 * S, sy * pd.h / 2 * S]));
        samePts(got, want, name + " A: pad " + p.ref + "." + pd.num + " footprint corners");
        nearOk(Math.hypot(e1[0], e1[1]), 1, name + " A: pad " + p.ref + "." + pd.num + " frame is a unit axis");
      }
      sameCol(pad, b + 8, colOf.get(pd), name + " A: pad " + p.ref + "." + pd.num + " colour");
      k++;
    }));
    ok(k * 12 === pad.length, name + " A: pad buffer holds exactly the non-poly pads",
      k * 12 + " vs " + pad.length);
  }
  if (poly) {
    let k = 0;
    polyG.forEach((g) => g.forEach((e) => {
      const { p, pd } = e, pm = partCTM(p);
      // padPath's poly branch is in the PART frame: no pad translate, no pad rotate.
      const want = pd.poly.map((v) => ap(pm, [v[0] * S, v[1] * S]));
      const tris = pd.poly.length - 2;
      for (let q = 0; q < tris; q++) {
        [[0, 0], [1, q + 1], [2, q + 2]].forEach(([slot, srcIdx]) => {
          const b = (k + q * 3 + slot) * 8;
          samePts([[poly[b], poly[b + 1]]], [want[srcIdx]],
            name + " A: poly pad " + p.ref + "." + pd.num + " tri" + q + " v" + slot);
          sameCol(poly, b + 4, colOf.get(pd), name + " A: poly pad " + p.ref + "." + pd.num + " colour");
        });
      }
      k += tris * 3;
    }));
    ok(k * 8 === poly.length, name + " A: poly buffer holds exactly the fan triangles",
      k * 8 + " vs " + poly.length);
  }
  if (bore) {
    let k = 0;
    boreG.forEach((g) => g.forEach((e) => {
      const { p, pd } = e, b = k * 8, c = ap(padCTM(p, pd), [0, 0]);
      samePts([[bore[b], bore[b + 1]]], [c], name + " A: bore " + p.ref + "." + pd.num + " centre");
      nearOk(bore[b + 2], Math.max(pd.drill / 2 * S, 0.6), name + " A: bore " + p.ref + "." + pd.num + " radius");
      sameCol(bore, b + 4, opt.TH.hole, name + " A: bore " + p.ref + "." + pd.num + " is the board colour");
      k++;
    }));
    ok(k * 8 === bore.length, name + " A: bore buffer holds exactly the drilled pads",
      k * 8 + " vs " + bore.length);
  }
}

// ── B: draw ranges tile their buffers exactly ───────────────────────────
function checkRanges(rc, verbose) {
  const { name, cap } = rc;
  const groups = {};
  cap.cmds.forEach((d) => {
    if (d.vb === null || d.vb === undefined) return;
    (groups[d.pipe + "#" + d.vb] || (groups[d.pipe + "#" + d.vb] = [])).push(d);
  });
  Object.keys(groups).sort().forEach((key) => {
    const g = groups[key], pipe = g[0].pipe, buf = cap.buffers[g[0].vb];
    const total = buf.data.length / STRIDE[pipe];
    const spans = g.map((d) => (PER_VERTEX[pipe] ? [d.c, d.a] : [d.d, d.b]))
      .sort((u, v) => u[0] - v[0]);
    let cur = 0, bad = null, covered = 0;
    spans.forEach(([first, count]) => {
      if (first < cur) bad = "overlap at " + first + " (cursor " + cur + ")";
      if (first > cur) bad = "gap at " + cur + " (next range starts " + first + ")";
      cur = first + count; covered += count;
    });
    if (cur > total) bad = "over-run: " + cur + " > " + total;
    if (covered !== total) bad = bad || ("partial: " + covered + "/" + total + " drawn");
    if (verbose) {
      console.log("   " + name + " " + key.padEnd(14) + " " + String(spans.length).padStart(3) +
        " range(s), " + covered + "/" + total + (bad ? "   << " + bad : ""));
    }
    ok(!bad, name + " B: " + key + " ranges tile the buffer", bad || "");
  });
}

// ── C: the stencil even-odd pour pipeline pair ──────────────────────────
function checkStencil(rc) {
  const { name, cap, opt } = rc;
  const areas = opt.pours ? opt.pours() : [];
  const fanCmds = cap.cmds.filter((d) => d.pipe === "vsFan");
  const covCmds = cap.cmds.filter((d) => d.pipe === "vsCover");
  if (!ok(fanCmds.length === areas.length, name + " C: one fan draw per pour area",
    fanCmds.length + " vs " + areas.length)) return;
  ok(covCmds.length === areas.length, name + " C: one cover draw per pour area",
    covCmds.length + " vs " + areas.length);

  const fanBuf = cap.buffers[fanCmds[0].vb].data;
  const covBuf = cap.buffers[covCmds[0].vb].data;
  const ringVerts = (r) => (r && r.length >= 3) ? 3 * (r.length - 2) : 0;
  areas.forEach((A, i) => {
    let want = ringVerts(A.poly);
    (A.holes || []).forEach((h) => { want += ringVerts(h); });
    ok(fanCmds[i].a === want, name + " C: area " + i + " fan vertex count = sum of its rings' fans",
      fanCmds[i].a + " vs " + want);
    // Every fan vertex must be a transformed source vertex of one of the rings —
    // a fan can only ever repeat ring points, never invent one. Bucketed with a
    // tolerant probe: the buffer is float32 (~7 significant digits) while the
    // ground truth is float64, and a real board's svg coordinates run to four
    // digits before the point.
    const src = new Map();
    const key = (x, y) => Math.round(x * 10) + "|" + Math.round(y * 10);
    [A.poly].concat(A.holes || []).forEach((r) => (r || []).forEach((v) => {
      const p = [X(v[0]), Y(v[1])], k = key(p[0], p[1]);
      (src.get(k) || src.set(k, []).get(k)).push(p);
    }));
    const known = (x, y) => {
      for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
        const c = src.get((Math.round(x * 10) + dx) + "|" + (Math.round(y * 10) + dy));
        if (c && c.some((p) => Math.abs(p[0] - x) < 0.01 && Math.abs(p[1] - y) < 0.01)) return true;
      }
      return false;
    };
    let stray = 0;
    for (let q = 0; q < fanCmds[i].a; q++) {
      const b = (fanCmds[i].c + q) * 2;
      if (!known(fanBuf[b], fanBuf[b + 1])) stray++;
    }
    ok(stray === 0, name + " C: area " + i + " fan uses only ring vertices", stray + " stray");
    // Cover quad ⊇ every ring's bbox (otherwise the cover leaves stencil bits
    // set, and the NEXT area's cover paints through them).
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    [A.poly].concat(A.holes || []).forEach((r) => (r || []).forEach((v) => {
      const u = X(v[0]), w = Y(v[1]);
      x0 = Math.min(x0, u); x1 = Math.max(x1, u); y0 = Math.min(y0, w); y1 = Math.max(y1, w);
    }));
    const inst = covCmds[i].d, b = inst * 8;
    ok(inst === i, name + " C: area " + i + " cover instance index follows its fan", String(inst));
    ok(covBuf[b] <= x0 + EPS && covBuf[b + 1] <= y0 + EPS &&
       covBuf[b + 2] >= x1 - EPS && covBuf[b + 3] >= y1 - EPS,
      name + " C: area " + i + " cover quad contains every ring",
      "[" + covBuf[b].toFixed(2) + "," + covBuf[b + 1].toFixed(2) + "," +
      covBuf[b + 2].toFixed(2) + "," + covBuf[b + 3].toFixed(2) + "] vs ring bbox [" +
      x0.toFixed(2) + "," + y0.toFixed(2) + "," + x1.toFixed(2) + "," + y1.toFixed(2) + "]");
    // D (colour ladder): the fill colour and the frame's resolved alpha land on
    // THIS area's instance.
    sameCol(covBuf, b + 4, A.col, name + " D: area " + i + " fill colour");
    nearOk(covBuf[b + 7], opt.st.pourA[i], name + " D: area " + i + " effective fill alpha");
    // The fan is drawn immediately before its own cover — the invert is consumed
    // and cleared by the very next draw, never by a later area's.
    const fi = cap.cmds.indexOf(fanCmds[i]), ci = cap.cmds.indexOf(covCmds[i]);
    ok(ci === fi + 1, name + " C: area " + i + " cover immediately follows its fan", fi + "→" + ci);
  });

  // Pipeline states.
  const fan = cap.pipelines.vsFan, cov = cap.pipelines.vsCover;
  if (ok(!!fan && !!cov, name + " C: both pour pipelines exist")) {
    ["stencilFront", "stencilBack"].forEach((f) => {
      ok(fan.depthStencil[f].compare === "always", name + " C: fan " + f + " compare=always",
        fan.depthStencil[f].compare);
      ok(fan.depthStencil[f].passOp === "invert", name + " C: fan " + f + " passOp=invert",
        fan.depthStencil[f].passOp);
      ok(cov.depthStencil[f].compare === "not-equal", name + " C: cover " + f + " compare=not-equal",
        cov.depthStencil[f].compare);
      ok(cov.depthStencil[f].passOp === "replace", name + " C: cover " + f + " passOp=replace",
        cov.depthStencil[f].passOp);
    });
    ok(fan.fragment.targets[0].writeMask === 0, name + " C: fan writes no colour",
      String(fan.fragment.targets[0].writeMask));
    ok(fan.primitive.cullMode === "none", name + " C: fan culls nothing (INVERT needs both windings)",
      fan.primitive.cullMode);
    ok(fan.depthStencil.stencilWriteMask === 0xff && cov.depthStencil.stencilWriteMask === 0xff,
      name + " C: both pour pipelines write the whole stencil mask");
    ok(!!cov.fragment.targets[0].blend, name + " C: cover blends (it is the visible fill)");
    const refs = cap.cmds.filter((d) => d.pipe === "vsCover").map((d) => d.ref);
    ok(refs.every((r) => r === 0), name + " C: cover replaces with stencil reference 0",
      JSON.stringify(refs.slice(0, 4)));
  }
}

// ── D/E: pass compatibility and draw order ──────────────────────────────
function checkPassAndOrder(rc) {
  const { name, cap } = rc;
  const pass = cap.pass;
  const dsa = pass && pass.depthStencilAttachment;
  if (ok(!!dsa, name + " D: the render pass carries a depth-stencil attachment")) {
    ok(dsa.stencilLoadOp === "clear" && dsa.stencilClearValue === 0,
      name + " D: the stencil is cleared to 0 once per frame",
      dsa.stencilLoadOp + "/" + dsa.stencilClearValue);
    ok(dsa.depthLoadOp === undefined && dsa.depthStoreOp === undefined,
      name + " D: no depth ops on a stencil-only (stencil8) attachment");
  }
  ok(cap.textures.length >= 1 && cap.textures[0].desc.format === "stencil8",
    name + " D: the stencil texture is stencil8",
    cap.textures.length ? cap.textures[0].desc.format : "none");
  ok(!!cap.textures.length && (cap.textures[0].desc.usage & 16) !== 0,
    name + " D: the stencil texture is a render attachment");
  // EVERY pipeline must declare the same depth-stencil format or the pass
  // rejects it at draw time. This is the integration bug the stencil work
  // introduces, and it is invisible until a browser runs it.
  cap.pipeList.forEach((p) => {
    const d = cap.pipelines[p].depthStencil;
    ok(!!d && d.format === "stencil8", name + " D: pipeline " + p + " declares stencil8",
      d ? d.format : "none");
    if (d) {
      ok(d.depthWriteEnabled === false, name + " D: pipeline " + p + " writes no depth (stencil8 has none)");
      ok(d.depthCompare === "always", name + " D: pipeline " + p + " depth compare is the neutral 'always'");
    }
  });
  ok(cap.pass.colorAttachments[0].loadOp === "clear", name + " E: the frame clears its colour target");

  // Order: grid → pour fills → pads → copper → vias, which is paintScene's
  // paintGridDots → paintPours → paintParts → paintTracks bottom-up sequence.
  const first = (p) => cap.cmds.findIndex((d) => d.pipe === p);
  const last = (p) => cap.cmds.map((d) => d.pipe).lastIndexOf(p);
  const seq = [];
  if (first("vsGrid") >= 0) seq.push(["grid", first("vsGrid")]);
  if (first("vsFan") >= 0) seq.push(["pour fills", first("vsFan")]);
  if (first("vsPad") >= 0) seq.push(["pads", first("vsPad")]);
  if (first("vsSeg") >= 0) seq.push(["tracks", first("vsSeg")]);
  for (let i = 1; i < seq.length; i++) {
    ok(seq[i - 1][1] < seq[i][1], name + " E: " + seq[i - 1][0] + " draws under " + seq[i][0],
      seq[i - 1][1] + " vs " + seq[i][1]);
  }
  // Bores are drawn with the pad group (under copper); vias after it. The two
  // vsCir buffers are told apart by their expected instance COUNTS (cirSplit),
  // which is independent of the draw order under test here.
  const cir = cirSplit(rc, classify(cap));
  if (cir.bore !== null && cir.via !== null && first("vsSeg") >= 0) {
    const bore = cap.cmds.findIndex((d) => d.pipe === "vsCir" && d.vb === cir.bore);
    const via = cap.cmds.findIndex((d) => d.pipe === "vsCir" && d.vb === cir.via);
    ok(bore < first("vsSeg"), name + " E: drill bores draw under the copper", bore + " vs " + first("vsSeg"));
    ok(via > last("vsSeg"), name + " E: vias draw over the copper", via + " vs " + last("vsSeg"));
  }
}

// ── F: WGSL sanity ──────────────────────────────────────────────────────
function argsOf(src, at) {
  // `at` indexes the '(' after a call name; returns the top-level argument list.
  let depth = 0, start = at + 1, out = [];
  for (let i = at; i < src.length; i++) {
    const c = src[i];
    if (c === "(") depth++;
    else if (c === ")") { depth--; if (!depth) { out.push(src.slice(start, i)); return out; } }
    else if (c === "," && depth === 1) { out.push(src.slice(start, i)); start = i + 1; }
  }
  return out;
}
const norm = (s) => s.replace(/\s+/g, " ").trim();
function checkWgsl(wgsl) {
  // Reversed smoothstep edges invert the shape silently (the fragment gets
  // 1-alpha, not an error). Every edge pair here is either (e - f, e + f) or
  // (-f, f); anything else has to be justified by hand, so it fails.
  let n = 0, at = wgsl.indexOf("smoothstep(");
  while (at >= 0) {
    const a = argsOf(wgsl, at + "smoothstep".length).map(norm);
    const lo = a[0], hi = a[1];
    const m = /^(.*) - (\w[\w.]*)$/.exec(lo);
    const goodPair = m ? hi === m[1] + " + " + m[2] : (/^-(\w[\w.]*)$/.test(lo) && hi === lo.slice(1));
    ok(goodPair, "F: smoothstep #" + n + " edges are ordered (e0 < e1)", lo + " , " + hi);
    n++;
    at = wgsl.indexOf("smoothstep(", at + 1);
  }
  ok(n >= 6, "F: every SDF pass still feathers with smoothstep", "found " + n);
  // fsCover is not merely colour: its stencil REPLACE clears the immediately
  // preceding pour/RF shape. In particular a hidden RF layer has alpha zero but
  // still records its union, so discarding its cover leaks that shape through
  // the next visible layer's cover.
  const cover = /@fragment fn fsCover[^{]*\{([\s\S]*?)\n\}/.exec(wgsl);
  ok(!!cover && cover[1].indexOf("discard") < 0,
    "F: a zero-alpha cover still clears stencil for the next layer",
    cover ? norm(cover[1]) : "fsCover not found");
  // The annulus disc guard: without it, a via barrel (rInner 0) runs a
  // smoothstep straddling zero and every via centre comes out half-alpha.
  ok(/if \(v\.r\.y > 0\.0\) \{ al = al \* smoothstep/.test(wgsl),
    "F: the annulus only applies its inner edge when rInner > 0");
  ok(wgsl.indexOf("alphaMode") < 0, "F: WGSL carries no host-side spellings");
  ok(/fn premul\(/.test(wgsl) && wgsl.indexOf("return premul(") > 0,
    "F: fragments emit premultiplied colour");
}
// Vertex layouts vs the entry point's @location list.
const FMT_N = { float32: 1, float32x2: 2, float32x3: 3, float32x4: 4 };
const TYPE_N = { "f32": 1, "vec2<f32>": 2, "vec3<f32>": 3, "vec4<f32>": 4 };
function checkLayouts(cap) {
  cap.pipeList.forEach((p) => {
    const bufs = cap.pipelines[p].vertex.buffers || [];
    const at = cap.wgsl.indexOf("@vertex fn " + p + "(");
    if (!ok(at >= 0, "F: entry point " + p + " exists in the WGSL")) return;
    const decl = argsOf(cap.wgsl, at + ("@vertex fn " + p).length).map(norm);
    const locs = {};
    decl.forEach((d) => {
      const m = /^@location\((\d+)\)\s+\w+\s*:\s*(.+)$/.exec(d);
      if (m) locs[+m[1]] = TYPE_N[m[2].trim()];
    });
    const attrs = [];
    bufs.forEach((b) => (b.attributes || []).forEach((a) => attrs.push([b, a])));
    ok(attrs.length === Object.keys(locs).length,
      "F: " + p + " vertex-buffer attributes match its @location inputs",
      attrs.length + " attrs vs " + Object.keys(locs).length + " locations");
    attrs.forEach(([b, a]) => {
      const nComp = FMT_N[a.format];
      ok(locs[a.shaderLocation] === nComp,
        "F: " + p + " @location(" + a.shaderLocation + ") is " + a.format,
        locs[a.shaderLocation] + " components declared vs " + nComp);
      ok(a.offset % 4 === 0, "F: " + p + " @location(" + a.shaderLocation + ") offset is 4-aligned");
      ok(a.offset + nComp * 4 <= b.arrayStride,
        "F: " + p + " @location(" + a.shaderLocation + ") fits inside arrayStride " + b.arrayStride,
        a.offset + "+" + nComp * 4);
    });
    // No two attributes of one buffer may overlap.
    bufs.forEach((b) => {
      const rs = (b.attributes || []).map((a) => [a.offset, a.offset + FMT_N[a.format] * 4])
        .sort((u, v) => u[0] - v[0]);
      for (let i = 1; i < rs.length; i++) {
        ok(rs[i][0] >= rs[i - 1][1], "F: " + p + " attributes do not overlap",
          JSON.stringify(rs[i - 1]) + " / " + JSON.stringify(rs[i]));
      }
    });
  });
}

// ── G: pcb_board.js keeps ONE rule per decision ─────────────────────────
// The GPU can only agree with Canvas2D if both read the same expression. These
// are text greps on purpose: a paraphrase is exactly the drift they catch.
function checkBoardSeams() {
  const js = fs.readFileSync(path.join(assets, "pcb_board.js"), "utf8");
  const has = (s, label) => ok(js.indexOf(s) >= 0, "G: " + label, s.slice(0, 64));
  // Pour alpha ladder: the 2D fill and gpuPourAlphas() run the same arithmetic.
  has("var baseA=hit?0.30:(activeUserFill?0.36:(top?0.10:0.12)),baseEff=a*baseA;",
    "paintPours keeps its base-wash ladder");
  has("var baseA=activeUserFill?0.36:(top?0.10:0.12),baseEff=a*baseA;",
    "gpuPourAlphas mirrors that ladder (minus the focus term)");
  ok((js.match(/Math\.min\(1,baseEff\+\(1-baseEff\)\*\(viewSt\.pourOp\|\|0\)\)/g) || []).length === 2,
    "G: the pour-opacity ramp is the same expression on both sides");
  // Colour rules.
  has("(netColOn&&netColorOf(netCollapse(t.net)))||layerColor(L)", "the 2D track-colour rule survives");
  has("function gpuTrackColor(t,L){return (netColOn&&netColorOf(netCollapse(t.net)))||layerColor(L);}",
    "gpuTrackColor is that same rule");
  has("fill=pd.net?(netColorOf(pd.net)||TH.pth):\"#ffffff\";", "the 2D pad-colour rule survives");
  has("if(netColOn)return pd.net?(netColorOf(pd.net)||TH.pth):\"#ffffff\";", "gpuPadColor is that same rule");
  has("padThruTop:1,padThruBot:1", "through-hole pad copper spans every viewed face");
  has("boreTop:1,boreBot:1", "drilled pad bores remain opaque through a foreign-side pour");
  // Seams: the GPU's baked buffers are invalidated where the 2D caches are.
  has("function pourGeomDrop(){pourGeom=null;if(gpuOn)PCBGpu.rebuildPours();}",
    "the pour choke point rebuilds GPU pour geometry");
  has("if(gpuOn){PCBGpu.rebuildCopper();PCBGpu.rebuildParts();}",
    "the Net-colours toggle rebuilds the baked instance colours");
  // Each partial 2D skip asks the shared stage table who owns the stage,
  // instead of testing the per-frame flag directly (src/render_order.zig).
  has("function gpuOwns(n){return gpuScene&&!!GPU_OWN[n];}", "GPU ownership is read from the stage table");
  has("stages:gpuStageOrder(),", "the frame hands the renderer its stage ORDER, not just its alphas");
  has("else if(!gpuOwns(\"plane_fills\")){", "paintPours hands its FILL to the GPU on a GPU frame");
  has("ctx.fill(aq.fillPath,\"evenodd\")", "the 2D even-odd fill spelling is still present (keepouts)");
  // Refusals: netColOn and pourOp are no longer whole-frame fallbacks, and from
  // M3 neither are the copper gestures nor a marquee copper selection. What is
  // left is the documented four — and the gate has to SPELL them out rather than
  // borrow cuBatchOn(null), which refuses the gestures the GPU now survives.
  const gate = /function gpuLive\(\)\{[\s\S]*?\n/.exec(js);
  const gateSrc = gate ? js.slice(gate.index, js.indexOf("}", gate.index) + 1) : "";
  ok(gateSrc.indexOf("!netColOn") < 0, "G: gpuLive no longer refuses Net-colours mode", gateSrc);
  ok(gateSrc.indexOf("!(viewSt.pourOp>0)&&") < 0, "G: gpuLive no longer refuses an opaque pour", gateSrc);
  ok(gateSrc.indexOf("cuBatchOn(null)") < 0, "G: gpuLive no longer refuses the copper gestures", gateSrc);
  ok(gateSrc.indexOf("selCuCount()") < 0, "G: gpuLive no longer refuses a marquee copper selection", gateSrc);
  ok(gateSrc.indexOf("!PHYSICAL_REVIEW") > 0 && gateSrc.indexOf("!reviewFocusActive()") > 0 &&
     gateSrc.indexOf("!ovExclusive()") > 0 &&
     gateSrc.indexOf("!(viewSt.pourOp>0&&anyUnplaced())") > 0,
    "G: gpuLive keeps its four documented fallbacks", gateSrc);
  // The 2D batch keeps its own, wider refusal — the gestures move copper under
  // a Path2D cache that has no way to notice.
  has("!segdrag&&!viadrag&&!dtrace", "cuBatchOn still bypasses the 2D copper batch for the gestures");
  // Every gesture that mutates copper in place marks the baked instances.
  has("function gpuCuEdit(){keepoutGeomDrop();if(gpuOn)PCBGpu.rebuildCopper();}",
    "the copper-gesture mark is one lazy choke point");
  ok((js.match(/gpuCuEdit\(\)/g) || []).length >= 13,
    "G: every copper-gesture mutation site marks the bake",
    (js.match(/gpuCuEdit\(\)/g) || []).length + " call sites");
  // The drag path: exclusion in, full rebake out, and no opaque bitmap over the
  // GPU surface (the drag cache stays, but only on the 2D build).
  has("if(!PCBGpu.partsExclIs(mov))PCBGpu.rebuildParts(mov);",
    "a GPU drag frame states its exclusion set");
  has("if(gpuLive())gpuDragFrame(ctx,w,h,k,kk,mov,movG,cop);",
    "the drag branch takes the GPU path instead of building the drag cache");
  has("function dragCacheDrop(){dragCache=null;gpuDragCache=null;ovsRev++;keepoutGeomDrop();if(gpuOn)PCBGpu.rebuildParts();}",
    "drag end rebuilds the whole board (no argument = no exclusion)");
  has("if(gpuScene&&s.only&&st.m2)gpuScene=false;",
    "the movers alone are painted with pad fills ON");
  has("if(!gpuOwns(\"parts\")||hl||exactPoly){",
    "the static pad fill is still the one thing the GPU pass replaces");
  // The marquee fringe is now the only 2D copper on a GPU frame.
  has("if(selCu.t.length)selCuTrackFringe(ctx,cop,only);", "the track fringe draws before the GPU bail-out");
  has("if(selCu.v.length&&anyCopperVisible())selCuViaFringe(ctx,cop,only);",
    "the via fringe draws on a GPU frame too");
  has("PCBGpu.frame(vb,gpuState())", "the frame hands the renderer a resolved policy blob");
  has("var k=svgMetricsGet().cw/vb.w;", "the grid gates read the CACHED frame scale, forcing no layout");
}

// ── H: the M3 interaction bakes ─────────────────────────────────────────
// A part DRAG keeps the GPU by baking the movers OUT of the pad/bore buffers
// for the gesture's duration. The failure that would hide there is a ghost —
// a mover still baked at its pointerdown pose, under the 2D copy that follows
// the cursor — or, the other way, a static part silently dropped. So this does
// not count instances: it re-runs the WHOLE A + B gate against a board whose
// parts array is the KEPT ones, which asserts that every remaining pad is at
// the position, size, orientation and colour the 2D painter would draw it at,
// in order, and that the ranges still tile their buffers exactly.
function checkExclusion(rc, picks, label) {
  const parts = rc.pcb.parts || [];
  const excl = {};
  picks.forEach((i) => { excl[i] = 1; });
  const nm = rc.name + " " + label;
  ok(rc.G.partsExclIs(null), nm + " H: the bake starts unexcluded");
  rc.G.rebuildParts(excl);
  ok(rc.G.partsExclIs(excl), nm + " H: the renderer reports the exclusion it was handed");
  ok(!rc.G.partsExclIs({}), nm + " H: … and does not report it as empty");
  frameOf(rc);
  const kept = parts.filter((_, i) => !excl[i]);
  const view = asBoard(rc, nm, Object.assign({}, rc.pcb, { parts: kept }));
  checkInstances(view);
  checkRanges(view, false);
  // Explicit counts as well, so a failure names the shortfall instead of only
  // pointing at the first mismatched instance.
  const bufs = classify(rc.cap);
  const len = (p) => {
    const b = bufs[p] ? rc.cap.buffers[bufs[p][0]] : null;
    return b && b.data ? b.data.length : 0;
  };
  let wantPad = 0, wantPoly = 0, wantBore = 0;
  kept.forEach((p) => (p.pads || []).forEach((pd) => {
    if (pd.drill > 0) wantBore++;
    if (pd.poly && pd.poly.length >= 3) wantPoly += (pd.poly.length - 2) * 3;
    else wantPad++;
  }));
  ok(len("vsPad") === wantPad * 12, nm + " H: pad instances = the kept parts' pads",
    len("vsPad") / 12 + " vs " + wantPad);
  ok(len("vsPoly") === wantPoly * 8, nm + " H: poly vertices = the kept parts' fans",
    len("vsPoly") / 8 + " vs " + wantPoly);
  // With no parts left at all the bore buffer is absent entirely, which is the
  // honest answer for an empty bake (upload() returns null for zero instances).
  const cir = cirSplit(view, bufs);
  const bore = cir.bore === null ? null : rc.cap.buffers[cir.bore];
  ok(((bore && bore.data ? bore.data.length : 0) / 8) === wantBore,
    nm + " H: bore instances = the kept parts' drilled pads",
    ((bore && bore.data ? bore.data.length : 0) / 8) + " vs " + wantBore);
  // Drag end: no argument at all means the whole board comes back.
  rc.G.rebuildParts();
  ok(rc.G.partsExclIs(null), nm + " H: rebuildParts() with no argument clears the exclusion");
  frameOf(rc);
  checkInstances(asBoard(rc, nm + " restored", rc.pcb));
  checkRanges(asBoard(rc, nm + " restored", rc.pcb), false);
}
// A copper GESTURE (segMove / viaMove / the group drag's carried copper / the
// draw tool's commits) mutates PCB.tracks IN PLACE with no cache to drop, and
// marks the GPU's copper buffer through gpuCuEdit(). Both halves are asserted:
// the mark is what makes the rebake happen, and WITHOUT it the buffer really
// does keep the pre-gesture coordinates — which is exactly why every mutation
// site needs one.
function checkGesture(rc) {
  const ts = rc.pcb.tracks || [];
  if (!ok(ts.length > 0, rc.name + " H: the board has a track to drag")) return;
  const t = ts[0], seg0 = classify(rc.cap).vsSeg;
  const before = seg0 ? Float32Array.from(rc.cap.buffers[seg0[0]].data.slice(0, 4)) : null;
  const dx = 0.37, dy = -0.21;                 // one grid-snapped segMove step
  t.x1 += dx; t.y1 += dy; t.x2 += dx; t.y2 += dy;
  frameOf(rc);                                  // no mark: the bake must be STALE
  const stale = classify(rc.cap).vsSeg;
  if (before && stale) {
    const now = rc.cap.buffers[stale[0]].data;
    ok(Math.abs(now[0] - before[0]) < 1e-9 && Math.abs(now[1] - before[1]) < 1e-9,
      rc.name + " H: an unmarked copper mutation leaves the bake stale (hence gpuCuEdit)",
      now[0] + "," + now[1] + " vs " + before[0] + "," + before[1]);
  }
  rc.G.rebuildCopper();
  frameOf(rc);
  checkInstances(rc);                           // ground truth reads the MUTATED track
  checkRanges(rc, false);
  t.x1 -= dx; t.y1 -= dy; t.x2 -= dx; t.y2 -= dy;
  rc.G.rebuildCopper();
  frameOf(rc);
}
// What one full copper rebake costs in JS, as the delta between a frame that
// rebakes and one that does not — both pay the fake device's draw recording and
// the per-frame camera/alpha writes, so what is left is the Float32Array staging
// plus the queue write the real renderer pays too. Reported, not asserted: the
// number is a watch item (a gesture marks per pointermove, so this is the price
// of a gesture frame), and a hard threshold on a shared dev box is noise.
function bakeCost(rc, n) {
  const run = (mark) => {
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < n; i++) { if (mark) rc.G.rebuildCopper(); frameOf(rc); }
    return Number(process.hrtime.bigint() - t0) / 1e3 / n;   // µs per frame
  };
  // Median of five batches, not one: a rebake allocates ~50 kB of staging, so a
  // batch that catches a GC reads 2-3x high and a single sample is not a number
  // anyone should ratchet against.
  const med = (mark) => {
    const s = [];
    for (let b = 0; b < 5; b++) s.push(run(mark));
    return s.sort((a, b) => a - b)[2];
  };
  run(true); run(false);                        // warm the JIT before measuring
  const dirty = med(true), clean = med(false);
  return { dirty, clean, bake: dirty - clean };
}

// ── the two boards ──────────────────────────────────────────────────────
// A synthetic matrix first: every rotation x side x pad-rotation combination,
// with rect, circle, poly and drilled pads on each part, so a transform bug has
// nowhere to hide. Then the real blob, which is the only thing that exercises
// realistic pour geometry (500-vertex outlines, seven hole loops).
function synth() {
  const parts = [];
  let n = 0;
  [0, 17, 90, 180, 270].forEach((rot) => {
    ["top", "bottom"].forEach((side) => {
      [0, 30, 90, 135].forEach((prot) => {
        parts.push({
          ref: "U" + n + "_r" + rot + "_" + side + "_p" + prot,
          x: 10 + (n % 8) * 6, y: 10 + Math.floor(n / 8) * 6,
          rot, side, hw: 2, hh: 2, ccx: 0, ccy: 0,
          pads: [
            { num: "1", x: 1.2, y: -0.7, w: 0.9, h: 0.6, rot: prot, net: "A" },
            { num: "2", x: -1.2, y: 0.7, w: 0.6, h: 1.4, rot: prot, net: "B" },
            { num: "3", x: 0, y: 1.5, w: 0.8, h: 0.8, rot: prot, shape: "circle", net: "C" },
            { num: "4", x: 0.4, y: -1.6, w: 1.0, h: 1.0, rot: prot, drill: 0.4, net: "D" },
            { num: "5", x: 0, y: 0, w: 1, h: 1, rot: 0, net: "",
              poly: [[-0.5, -0.3], [0.5, -0.3], [0.6, 0.4], [0, 0.6], [-0.6, 0.4]] },
            { num: "6", x: -0.9, y: -1.4, w: 0.8, h: 0.8, rot: 0, drill: 0.5, npth: true, net: "" },
          ],
        });
        n++;
      });
    });
  });
  return {
    name: "synthetic", parts,
    tracks: [{ x1: 1, y1: 2, x2: 9, y2: 4, w: 0.25, l: 0, net: "A" },
             { x1: 3, y1: 8, x2: 3, y2: 1, w: 0.6, l: 1, net: "B" },
             { x1: 4, y1: 4, x2: 6, y2: 6, w: 0.15, l: 2, net: "GND.U1.3" },
             { x1: 6, y1: 6, x2: 8, y2: 6, w: 0.3, l: 0, net: "" }],
    vias: [{ x: 5, y: 5, d: 0.6, drill: 0.3, net: "A" },
           { x: 6, y: 5, d: 0.8, net: "GND.U1.3" },
           { x: 7, y: 5, d: 0.6, drill: 0.3, net: "GND", f: "RF1" }],
  };
}
// A concave outer ring with a square hole: the fan of a concave polygon is only
// correct because of the stencil INVERT, so this is the shape that proves it.
function synthPours() {
  return [
    { poly: [[2, 2], [12, 2], [12, 6], [8, 6], [8, 4], [6, 4], [6, 6], [2, 6]],
      holes: [[[3, 3], [4, 3], [4, 4], [3, 4]], [[10, 3], [11, 3], [11, 5], [10, 5]]],
      col: "#c83434" },
    { poly: [[14, 2], [20, 2], [20, 8], [14, 8]], holes: [], col: "#4d7fc4" },
    { poly: [[2, 10], [9, 10], [9, 14], [2, 14]], holes: [], col: "#c200c2" },
  ];
}

const TH = { bg: "#001023", gridDot: "#2a3a4a", padTop: "#C83434", padBot: "#4D7FC4",
  pth: "#d0a028", npth: "#26323e", hole: "#001023", via: "#B2B27A", viaHole: "#001023" };

function mkOpts(pcb, geo, layers, netcolor, netColOn, pours) {
  const layerColor = (l) => (layers.find((L) => L.l === l) || {}).c || "#8b949e";
  const netColorOf = (nk) => (nk && netcolor ? (netcolor[nk] || null) : null);
  const order = layers.map((L) => L.l).filter((l) => l !== 0).reverse().concat([0]);
  const areas = pours || [];
  return Object.assign({
    nsig: layers.length, TH, layerColor,
    trackColor: (t, L) => (netColOn && netColorOf(netCollapse(t.net))) || layerColor(L),
    viaColor: (v) => (netColOn && netColorOf(netCollapse(v.net))) || TH.via,
    padColor: (pd, bot) => {
      if (netColOn) return pd.net ? (netColorOf(pd.net) || TH.pth) : "#ffffff";
      if (pd.drill > 0) return pd.npth ? TH.npth : TH.pth;
      return bot ? TH.padBot : TH.padTop;
    },
    pours: () => areas,
    st: {
      // The GPU-owned half of the canonical paint order (src/render_order.zig),
      // handed over exactly as gpuState() sends it.
      stages: ["substrate", "plane_fills", "parts", "copper"],
      layers: order.map((l) => ({ l, a: l === 0 ? 0.95 : 0.28 })),
      padThruTop: 1, padThruBot: 1, padTop: 0.95, padBot: 0.28,
      boreTop: 1, boreBot: 1, via: 1, fence: 0.7, viaDrill: 0.2,
      // The pour ladder of paintPours, evaluated for activeLayer 0 / pourOp 0.35:
      // baseEff = a*baseA, then the ramp on the layer being looked at.
      pourA: areas.map((_, i) => [0.0332, 0.0336, 0.066][i % 3]),
      gridPitch: 1.27 * geo.S, gridDot: 1.4 / 4,
    },
  }, geo);
}

// The ROUTABLE layer rows of a blob's one layer table, in signal-index order —
// the same derivation pcb_board.js makes. Older fixture blobs (no layer table)
// fall back to the classic two-layer board.
function blobLayers(pcb) {
  const table = (pcb && pcb.layer_table) || [];
  const rows = table.filter((r) => typeof r.l === "number")
    .sort((a, b) => a.l - b.l).map((r) => ({ l: r.l, name: r.name, c: r.c }));
  return rows.length ? rows : [{ l: 0, c: "#C83434" }, { l: 1, c: "#4D7FC4" }];
}

function readPcbBlob(file) {
  const src = fs.readFileSync(file, "utf8");
  try { return JSON.parse(src); } catch (_) {}
  // A saved /pcb-layout page is an equally useful real-board fixture and is
  // much easier to capture from an authenticated local server than a private
  // data endpoint. Extract only the server-emitted `const PCB=…` script.
  const mark = "const PCB=", at = src.indexOf(mark);
  if (at < 0) throw new Error(file + ": neither JSON nor a PCB layout page");
  const start = at + mark.length, end = src.indexOf(";</script>", start);
  if (end < 0) throw new Error(file + ": unterminated PCB data script");
  return JSON.parse(src.slice(start, end));
}
const real = readPcbBlob(blobPath);

function checkBundleReuse(rc) {
  const before = rc.cap.bundleBuilds, draws = rc.cap.cmds.length;
  ok(before > 0, rc.name + " I: the renderer records a native render bundle");
  frameOf(rc);
  ok(rc.cap.bundleBuilds === before, rc.name + " I: a camera-only frame reuses its render bundle",
    rc.cap.bundleBuilds + " vs " + before);
  ok(rc.cap.cmds.length === draws, rc.name + " I: the reused bundle replays the complete draw stream",
    rc.cap.cmds.length + " vs " + draws);
  const alpha = rc.opt.st.layers[0].a;
  rc.opt.st.layers[0].a = alpha * 0.5;
  frameOf(rc);
  ok(rc.cap.bundleBuilds === before, rc.name + " I: an alpha-only frame keeps the bundle");
  rc.opt.st.layers[0].a = alpha;
  rc.G.rebuildCopper();
  frameOf(rc);
  ok(rc.cap.bundleBuilds === before + 1, rc.name + " I: a copper-buffer rebuild records a fresh bundle",
    rc.cap.bundleBuilds + " vs " + (before + 1));
  const drillBuilds = rc.cap.bundleBuilds, drill = rc.opt.st.viaDrill;
  rc.opt.st.viaDrill = drill + 0.05;
  frameOf(rc);
  ok(rc.cap.bundleBuilds === drillBuilds + 1,
    rc.name + " I: a via-drill buffer rebuild records a fresh bundle");
  rc.opt.st.viaDrill = drill;
  frameOf(rc);
  ok(rc.cap.bundleBuilds === drillBuilds + 2,
    rc.name + " I: restoring via drill records the restored copper buffers");
  if (rc.opt.st.pourA.length) {
    const builds = rc.cap.bundleBuilds, pour = rc.opt.st.pourA[0];
    rc.opt.st.pourA[0] = 0;
    frameOf(rc);
    ok(rc.cap.bundleBuilds === builds + 1,
      rc.name + " I: a pour crossing to zero alpha records a stencil-safe bundle");
    rc.opt.st.pourA[0] = pour;
    frameOf(rc);
    ok(rc.cap.bundleBuilds === builds + 2,
      rc.name + " I: a pour returning from zero records its fan and cover again");
  }
}
// The pour areas of the real blob, adapted the way reviewCopperAreas() does:
// declared pours and the carved fills of user zones, never a raw zone boundary.
function realPours() {
  const out = [];
  const push = (list) => (list || []).forEach((q) => {
    const poly = q.poly || q.polygon || q.points;
    if (!poly || poly.length < 3) return;
    const L = (typeof q.l === "number") ? q.l : (typeof q.layer === "number") ? q.layer
      : (q.side === "top" ? 0 : q.side === "bottom" ? 1 : null);
    out.push({ poly, holes: q.holes || [],
      col: (L != null && L >= 2) ? "#C200C2" : (L === 0 ? "#c83434" : "#4d7fc4") });
  });
  push(real.pours); push(real.zone_fills);
  return out;
}

console.log("pcb_gpu_check — " + path.relative(process.cwd(), path.join(assets, "pcb_gpu.js")));
runCase("synthetic", synth(), mkOpts(synth(),
  { S: 12, MX: 0, MY: 0, M: 4 },
  [{ l: 0, c: "#C83434" }, { l: 1, c: "#4D7FC4" }, { l: 2, c: "#B08040" }, { l: 3, c: "#40A080" }],
  { A: "#ff8800", B: "#00ccff", GND: "#8b5a2b", D: "#aa66ff" }, true, synthPours()))
  .then((rc) => {
    console.log("  synthetic: " + rc.cap.cmds.length + " draws, " +
      rc.cap.pipeList.length + " pipelines");
    checkInstances(rc); checkRanges(rc, true); checkStencil(rc); checkPassAndOrder(rc);
    checkWgsl(rc.cap.wgsl); checkLayouts(rc.cap); checkBundleReuse(rc);
    // H on the synthetic matrix: one part, then a rigid-group-sized set that
    // spans both sides and several rotations, then a set that leaves nothing.
    checkExclusion(rc, [0], "drag(1)");
    checkExclusion(rc, [1, 2, 3, 5, 8, 13, 21, 34], "drag(8 mixed)");
    checkExclusion(rc, (rc.pcb.parts || []).map((_, i) => i), "drag(all)");
    checkGesture(rc);
    const pours = realPours();
    return runCase("board", real, mkOpts(real,
      { S: real.scale, MX: real.minx, MY: real.miny, M: real.margin },
      blobLayers(real),
      real.netcolor, false, pours));
  })
  .then((rc) => {
    const m = rc.cap.cmds.length;
    console.log("  board:     " + m + " draws, " + (rc.pcb.parts || []).length + " parts, " +
      (rc.pcb.tracks || []).length + " tracks, " + rc.opt.pours().length + " pour areas");
    checkInstances(rc); checkRanges(rc, true); checkStencil(rc); checkPassAndOrder(rc); checkBundleReuse(rc);
    // A real board's drags: one part, and a sub-circuit-sized rigid group.
    checkExclusion(rc, [0], "drag(1)");
    checkExclusion(rc, Array.from({ length: 14 }, (_, i) => i * 3), "drag(14 group)");
    checkGesture(rc);
    checkBoardSeams();
    // A clean instance of the same board for the timing case (see runCase's
    // `bare`), so the microbench measures only what the browser would pay.
    return runCase("bench", real, mkOpts(real,
      { S: real.scale, MX: real.minx, MY: real.miny, M: real.margin },
      blobLayers(real),
      real.netcolor, false, realPours()), true);
  })
  .then((rc) => {
    const bc = bakeCost(rc, 100);
    console.log("  copper rebake: " + bc.bake.toFixed(1) + " µs/bake  (frame " +
      bc.dirty.toFixed(1) + " µs with the rebake vs " + bc.clean.toFixed(1) + " µs without, n=100)");
    console.log("\nchecks: " + checked + ", failures: " + failures.length);
    failures.slice(0, 30).forEach((f) => console.log("  FAIL " + f));
    if (failures.length > 30) console.log("  … and " + (failures.length - 30) + " more");
    process.exit(failures.length ? 1 : 0);
  })
  .catch((e) => { console.error(e && e.stack || e); process.exit(2); });
