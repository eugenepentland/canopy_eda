// pcb_viewer_bench tail — runs after pcb_board.js has initialized against the
// stub DOM. Reaches file-scope internals through the globalThis.__B hook the
// runner injects before the main IIFE's closer. Prints one JSON object.
(function () {
  const B = globalThis.__B;
  const OPS = globalThis.__OPS;
  if (!B) { console.error("bench: __B hook missing — injection failed"); process.exit(2); }
  globalThis.__flushRaf();

  const RESULT = { meta: {
    parts: PCB.parts.length,
    pads: PCB.parts.reduce((a, p) => a + (p.pads || []).length, 0),
    tracks: (PCB.tracks || []).length, vias: (PCB.vias || []).length,
    pours: (PCB.pours || []).length, zone_fills: (PCB.zone_fills || []).length,
    links: (PCB.links || []).length, drc: (PCB.drc || []).length,
    netclasses: (PCB.netclasses || []).length,
  }, scenarios: {} };

  function ms(fn, n, warmup) {
    for (let i = 0; i < (warmup || 5); i++) fn(i);
    const t0 = performance.now();
    for (let i = 0; i < n; i++) fn(i);
    return +((performance.now() - t0) / n).toFixed(3);
  }
  function snapOps(fn) {
    globalThis.__resetOps();
    fn();
    const o = {};
    for (const k in OPS) if (OPS[k]) o[k] = OPS[k];
    return o;
  }

  // Deterministic starting viewport: whole board framed.
  // Keepouts-off is the comparison baseline; individual scenarios below turn
  // the real plural visibility key on explicitly.
  B.viewSt.vis.keepouts = 0;
  B.fitVB();
  globalThis.__flushRaf();
  const fitVb = Object.assign({}, B.vbGet());

  // 1. Full static repaint (what a hover flip / selection change costs).
  //    quiet() clears the viewport-busy window so pad labels + grid dots and
  //    every other quiet-only pass are included, matching an idle repaint.
  const filletBuilds0 = B.outlineFilletBuildsGet();
  RESULT.scenarios.static_full_repaint_ms = ms(() => { B.quiet(); B.scenePaint(); }, 60, 10);
  RESULT.scenarios.static_full_repaint_outline_fillet_builds = B.outlineFilletBuildsGet() - filletBuilds0;
  RESULT.scenarios.static_full_repaint_ops = snapOps(() => { B.quiet(); B.scenePaint(); });
  B.viewSt.vis.keepouts=1;B.keepoutDrop();
  // First call builds the retained layer; subsequent repaints model hover and
  // selection frames while the board/view transform is unchanged.
  B.quiet();B.scenePaint();
  RESULT.scenarios.static_keepouts_on_repaint_ms=ms(() => { B.quiet();B.scenePaint(); },60,10);
  RESULT.scenarios.static_keepouts_on_repaint_ops=snapOps(() => { B.quiet();B.scenePaint(); });
  B.viewSt.vis.keepouts=0;B.keepoutDrop();

  // 2. Pan frames: viewport translate + setVB + repaint, exactly the panMove →
  //    setVB → rAF scenePaint pipeline (vbBusy stays hot, as in a real pan).
  let dir = 1;
  RESULT.scenarios.pan_frame_ms = ms((i) => {
    if (i % 40 === 39) dir = -dir;
    const vb = B.vbGet(); vb.x += 0.8 * dir;
    B.setVB(); B.scenePaint();
  }, 120, 10);
  RESULT.scenarios.pan_frame_ops = snapOps(() => {
    const vb = B.vbGet(); vb.x += 0.8;
    B.setVB(); B.scenePaint();
  });

  // 3. Zoom frames (wheel-notch style, alternating in/out around the center).
  RESULT.scenarios.zoom_frame_ms = ms((i) => {
    B.zoomAt(VIEW_W / 2, VIEW_H / 2, i % 2 ? 1.03 : 1 / 1.03);
    B.scenePaint();
  }, 80, 10);

  // 3b. ZOOMED-IN pan — the pin-numbers-visible case (vb.w=300 → k≈5.3, the
  // zoom band where per-frame raster cost dominates in a real browser).
  {
    const vb0 = B.vbGet();
    const saved = { x: vb0.x, y: vb0.y, w: vb0.w, h: vb0.h };
    vb0.w = 300; vb0.h = 300 * (VIEW_H / VIEW_W);
    vb0.x = fitVb.x + fitVb.w / 2 - vb0.w / 2; vb0.y = fitVb.y + fitVb.h / 2 - vb0.h / 2;
    B.setVB();
    let zdir = 1;
    RESULT.scenarios.panzoomed_frame_ms = ms((i) => {
      if (i % 40 === 39) zdir = -zdir;
      const vb = B.vbGet(); vb.x += 0.8 * zdir;
      B.setVB(); B.scenePaint();
    }, 120, 10);
    RESULT.scenarios.panzoomed_frame_ops = snapOps(() => {
      const vb = B.vbGet(); vb.x += 0.8;
      B.setVB(); B.scenePaint();
    });
    const vb1 = B.vbGet();
    vb1.x = saved.x; vb1.y = saved.y; vb1.w = saved.w; vb1.h = saved.h;
    B.setVB();
  }

  // 4. Mid-zoom static repaint — the grid-dot-heavy hover case. vb.w=300 puts
  //    the dot pitch above the 8px draw threshold with tens of thousands of
  //    dots in view.
  {
    const vb = B.vbGet();
    vb.w = 300; vb.h = 300 * (VIEW_H / VIEW_W);
    vb.x = fitVb.x + fitVb.w / 2 - vb.w / 2; vb.y = fitVb.y + fitVb.h / 2 - vb.h / 2;
    B.setVB();
    RESULT.scenarios.midzoom_repaint_ms = ms(() => { B.quiet(); B.scenePaint(); }, 40, 5);
    RESULT.scenarios.midzoom_repaint_ops = snapOps(() => { B.quiet(); B.scenePaint(); });
  }
  B.fitVB();

  // 5. Pointer-event path: the real svg pointermove handler with no gesture
  //    live (status bar + hover hit-testing), plus mm() alone. Layout-forcing
  //    reads are the headline number: each is a forced layout in a browser.
  {
    const svg = B.svg;
    const mkEv = (x, y) => ({
      clientX: x, clientY: y, pointerType: "mouse", pointerId: 1, button: 0, buttons: 0,
      shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
      target: svg, preventDefault() {}, stopPropagation() {},
    });
    RESULT.scenarios.pointermove_ms = ms((i) => {
      svg.__fire("pointermove", mkEv(200 + (i % 40) * 30, 200 + (i % 13) * 40));
    }, 400, 40);
    RESULT.scenarios.pointermove_layout_reads = snapOps(() => {
      for (let i = 0; i < 100; i++) svg.__fire("pointermove", mkEv(200 + (i % 40) * 30, 200 + (i % 13) * 40));
    });
    RESULT.scenarios.mm_only_ms = ms((i) => B.mm(mkEv(300 + (i % 100), 300)), 1000, 100);
  }

  // 6. Individual paint passes at the fit viewport (per-pass attribution).
  {
    B.quiet();
    const ctx = B.CTX();
    const k = VIEW_W / B.vbGet().w;
    const passes = B.passes;
    const per = {};
    const run = {
      pours: () => passes.pours(ctx, k),
      tracks: () => passes.tracks(ctx),
      parts: () => passes.parts(ctx, k),
      links: () => passes.links(ctx),
      padLabels: () => { B.quiet(); passes.padLabels(ctx, k); },
      gridDots: () => { B.quiet(); passes.grid(ctx, k); },
      texts: () => passes.texts(ctx),
    };
    for (const name in run) {
      per[name] = { ms: ms(run[name], 40, 5), ops: snapOps(run[name]) };
    }
    // Keepout pass with the layer toggled ON (off is the default and returns
    // immediately; RF work turns it on, which is when its cost matters).
    B.viewSt.vis.keepouts = 1;
    B.keepoutDrop();
    per.keepout_on = { ms: ms(run_keepout, 40, 5), ops: snapOps(run_keepout) };
    per.keepout_cold = { ms: ms(() => { B.keepoutDrop(); run_keepout(); }, 40, 5),
      ops: snapOps(() => { B.keepoutDrop(); run_keepout(); }) };
    function run_keepout() { passes.keepout(ctx, k); }
    B.viewSt.vis.keepouts = 0;
    B.keepoutDrop();
    RESULT.scenarios.passes = per;
  }

  // 7. netClassInfo lookup cost over every copper net (the per-frame pattern
  //    the keepout pass uses).
  {
    const nets = (PCB.tracks || []).map((t) => t.net).concat((PCB.vias || []).map((v) => v.net));
    RESULT.scenarios.netclass_lookup_all_copper_ms = ms(() => {
      for (let i = 0; i < nets.length; i++) B.netClassInfo(nets[i]);
    }, 60, 10);
  }

  // 8. linksRecompute — the copper-edit connectivity pass (drag-end cost).
  RESULT.scenarios.links_recompute_ms = ms(() => B.linksRecompute(), 20, 3);

  // Optional engine-exact parity/timing probe. Point DRC_WASM at drc.wasm to
  // compare the scoped commit gate with its former full-board equivalent.
  if (process.env.DRC_WASM && __fs.existsSync(process.env.DRC_WASM)) {
    const mod = new WebAssembly.Module(__fs.readFileSync(process.env.DRC_WASM));
    B.gateSet(new WebAssembly.Instance(mod, {}));
    const bt=PCB.tracks||[],bv=PCB.vias||[],pd=PCB.parts[0]&&PCB.parts[0].pads&&PCB.parts[0].pads[0];
    if (pd) {
      const q=B.wptFn(0,pd.x,pd.y),cand={x:q.x,y:q.y,d:0.4,drill:0.2,net:"__BENCH_FOREIGN__"},av=bv.concat([cand]);
      let t=performance.now();const full=B.gateFullDiffFn(bt,bv,bt,av);RESULT.scenarios.drc_gate_full_ms=+(performance.now()-t).toFixed(2);
      t=performance.now();const scoped=B.gateDiffFn(bt,bv,bt,av);RESULT.scenarios.drc_gate_scoped_ms=+(performance.now()-t).toFixed(2);
      RESULT.scenarios.drc_gate_scope_matches_full=full===scoped;
      const s=B.gateScopeFn(bt,bv,bt,av);RESULT.meta.drc_gate_scope={parts:s.parts.length,tracks:s.at.length,vias:s.av.length};
      const cases=[{bt:bt,bv:bv,at:bt,av:bv.concat([{x:q.x-20,y:q.y-20,d:0.4,drill:0.2,net:"__BENCH_STAGE__"}])}];
      for(let i=0;i<Math.min(5,bt.length);i++){const at=bt.slice(),o=bt[i];
        at[i]=Object.assign({},o,{x1:o.x1+0.05,x2:o.x2+0.05});cases.push({bt:bt,bv:bv,at:at,av:bv});}
      let matched=0;cases.forEach(function(c){if(B.gateFullDiffFn(c.bt,c.bv,c.at,c.av)===B.gateDiffFn(c.bt,c.bv,c.at,c.av))matched++;});
      RESULT.scenarios.drc_gate_scope_parity=matched+"/"+cases.length;
    }
  }

  // 9. Real part/group pointer gestures. This drives the shipping handler
  // chain and splits the release handler from its post-drop rAF. SVG creation
  // is counted after initialisation so retained-overlay churn is visible.
  {
    let domCreates = 0;
    const origNS = document.createElementNS.bind(document);
    document.createElementNS = function (ns, tag) { domCreates++; return origNS(ns, tag); };
    const P = PCB.parts, partLoops = B.partLoopsGet(), grps = B.grpsGet();
    let solo = -1, soloLoops = -1, big = null, bigN = -1;
    P.forEach((p, i) => { if (B.grpOfFn(p.ref)) return;
      const n = (partLoops[i] || []).length;if (n > soloLoops) { solo = i; soloLoops = n; } });
    for (const g in grps) if (grps[g].length > bigN) { big = g; bigN = grps[g].length; }
    RESULT.meta.drag_solo_part = solo >= 0 ? P[solo].ref : null;
    RESULT.meta.drag_biggest_group = big;RESULT.meta.drag_biggest_group_parts = bigN;
    function w2c(wx, wy) { const v = B.vbGet();return {
      x: (B.XW(wx) - v.x) * (VIEW_W / v.w), y: (B.YW(wy) - v.y) * (VIEW_H / v.h) }; }
    function pev(x, y) { return { clientX:x,clientY:y,button:0,buttons:1,pointerId:1,
      pointerType:"mouse",isPrimary:true,target:B.svg,shiftKey:false,ctrlKey:false,
      metaKey:false,altKey:false,preventDefault(){},stopPropagation(){} }; }
    function fire(type, ev) { B.svg.__fire(type, ev); }
    function dragCycle(i, eventsPerFrame, frames) {
      const c0 = w2c(P[i].x, P[i].y), step = Math.max(B.GGet() * VIEW_W / B.vbGet().w, 1.5);
      fire("pointerdown", pev(c0.x, c0.y));
      fire("pointermove", pev(c0.x + 12, c0.y));globalThis.__flushRaf();
      fire("pointermove", pev(c0.x, c0.y));globalThis.__flushRaf();
      const dc = domCreates,t0 = performance.now();
      for (let f = 0; f < frames; f++) { const dir = f % 2 ? -1 : 1;
        for (let e = 0; e < eventsPerFrame; e++)
          fire("pointermove", pev(c0.x + dir * step * (1 + e / eventsPerFrame), c0.y));
        globalThis.__flushRaf(); }
      const frameMs = (performance.now() - t0) / frames;
      fire("pointermove", pev(c0.x, c0.y));globalThis.__flushRaf();
      let t = performance.now();fire("pointerup", pev(c0.x, c0.y));const upMs = performance.now() - t;
      t = performance.now();globalThis.__flushRaf();const dropFrameMs = performance.now() - t;
      return { frame:+frameMs.toFixed(3),up:+upMs.toFixed(3),dropFrame:+dropFrameMs.toFixed(3),
        domPerFrame:+((domCreates-dc)/frames).toFixed(1) };
    }
    if (solo >= 0) {
      const c = w2c(P[solo].x,P[solo].y);
      RESULT.scenarios.pointerdown_grab_ms = ms(() => { fire("pointerdown",pev(c.x,c.y));B.dragSet(null);B.gdragSet(null); },40,5);
      RESULT.scenarios.snap_all_ms = ms(() => B.snapAllFn(),40,5);
      const one = dragCycle(solo,1,30),poll = dragCycle(solo,8,60);
      RESULT.scenarios.drag_single_frame_ms=one.frame;RESULT.scenarios.drag_single_8ev_frame_ms=poll.frame;
      RESULT.scenarios.drag_single_drop_up_ms=one.up;RESULT.scenarios.drag_single_drop_frame_ms=one.dropFrame;
      RESULT.scenarios.drag_single_dom_creates_per_frame=one.domPerFrame;
    }
    if (big != null) {
      const i=grps[big][0],one=dragCycle(i,1,30),poll=dragCycle(i,8,60);
      RESULT.scenarios.drag_group_frame_ms=one.frame;RESULT.scenarios.drag_group_8ev_frame_ms=poll.frame;
      RESULT.scenarios.drag_group_drop_up_ms=one.up;RESULT.scenarios.drag_group_drop_frame_ms=one.dropFrame;
      RESULT.scenarios.drag_group_dom_creates_per_frame=one.domPerFrame;
      const c=w2c(P[i].x,P[i].y);fire("pointerdown",pev(c.x,c.y));const gd=B.gdragGet();
      RESULT.meta.drag_group_carried_tracks=gd?gd.ct.length:0;RESULT.meta.drag_group_carried_vias=gd?gd.cv.length:0;
      B.dragSet(null);B.gdragSet(null);
    }
    // Same real gestures with the costly board layer enabled. The initial
    // dragged frame is included in each cycle's warm-up, matching a user who
    // starts moving after the visible keepout scene has already rendered.
    B.viewSt.vis.keepouts=1;B.keepoutDrop();
    if(solo>=0){const one=dragCycle(solo,1,30);
      RESULT.scenarios.drag_single_keepouts_frame_ms=one.frame;
      RESULT.scenarios.drag_single_keepouts_drop_frame_ms=one.dropFrame;}
    if(big!=null){const one=dragCycle(grps[big][0],1,30);
      RESULT.scenarios.drag_group_keepouts_frame_ms=one.frame;
      RESULT.scenarios.drag_group_keepouts_drop_frame_ms=one.dropFrame;}
    B.viewSt.vis.keepouts=0;B.keepoutDrop();
  }

  console.log(JSON.stringify(RESULT, null, 1));
  process.exit(0);
})();
