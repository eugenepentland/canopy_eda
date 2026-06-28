/* KiCad-style sheet editor (prototype) — client (2D canvas renderer).
 *
 * Renders the server's scene-graph JSON (window.SCENE) onto a single <canvas>
 * in immediate mode: one draw call list, redrawn only when something changes
 * (pan/zoom/drag/edit), so a dense board stays smooth where ~2k retained SVG
 * nodes did not. Each (section …) is a navigable "sheet". All mutation goes
 * through the existing surgical /api/* endpoints; after each edit we refetch
 * /api/editor-scene/<design> and repaint.
 *
 * Dragging is a *wiring* gesture, never placement: drag a symbol/pin so a
 * terminal lands on a connection point; on drop we write the net (rewire-pin)
 * and refetch — the deterministic layout re-derives, so the part "snaps".
 * Drop on nothing → spring back. No coordinate is ever stored.
 *
 * Coordinates: world units (the scene's space). A single affine maps world→
 * device each frame (cam is the viewport). Stroke widths are screen-constant
 * (px/scale); fonts are world-scaled with a level-of-detail cutoff.
 */
(function () {
  "use strict";

  const DESIGN = window.DESIGN;
  let scene = window.SCENE || { sections: [], hubs: [], passives: [], wires: [], labels: [], viewBox: { w: 1000, h: 800 } };
  let lastVersion = window.START_VERSION || 0;

  const canvas = document.getElementById("ed-canvas");
  const ctx = canvas.getContext("2d");
  const wrap = document.getElementById("ed-canvas-wrap");
  const sheetList = document.getElementById("ed-sheet-list");
  const statusBar = document.getElementById("ed-status");
  const isoBox = document.getElementById("ed-isolate");
  const inspector = document.getElementById("ed-inspector");

  const C = {
    secStroke: "#2d3a4a", secLabel: "#6e7681",
    hub: "#1b2230", hubStroke: "#58708f", hubLabel: "#e6edf3", pinName: "#adbac7", pin: "#2d3a4a", pinStroke: "#58708f",
    pass: "#20262e", passStroke: "#8b949e", passText: "#c9d1d9",
    wire: "#4d9375", bus: "#6fb38d", hot: "#f0c674",
    labelNet: "#79c0ff", labelGnd: "#8b949e", labelPort: "#d2a8ff",
    sel: "#f0883e", snap: "#f0883e", band: "#f0c674",
  };
  const GRID = 60; // spatial-hash cell size (world units)

  // ── State ────────────────────────────────────────────────────────────
  let cam = { x: 0, y: 0, w: 1000, h: 800 };
  let M = null;                  // built scene model
  let activeSheet = -1;          // -1 = whole board
  let selection = null;          // {kind:'hub'|'pass', ref}
  let hotNet = null;
  let clip = null;               // copy/paste clipboard: {ref, src}
  let deleteArmed = false;       // inspector Delete needs a 2nd click to confirm
  let libIndex = null;
  let dirty = true, springBack = null;
  const stagePos = {};           // staged-part identity (src offset) -> {x,y} world position
  let firstBuild = true;

  // ── Helpers ──────────────────────────────────────────────────────────
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function rectOf() { return canvas.getBoundingClientRect(); }
  function scheduleDraw() { dirty = true; }
  function toast(msg, isErr) {
    const t = document.createElement("div");
    t.className = "ed-toast" + (isErr ? " err" : "");
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => t.remove(), isErr ? 4000 : 2200);
  }
  async function api(method, url, body) {
    const opt = { method };
    if (body !== undefined) { opt.headers = { "Content-Type": "application/json" }; opt.body = JSON.stringify(body); }
    const r = await fetch(url, opt);
    let data = null;
    try { data = await r.json(); } catch (e) { /* text body */ }
    if (!r.ok) throw new Error((data && (data.error || data.message)) || ("HTTP " + r.status));
    return data;
  }
  function scale() { const r = rectOf(); return r.width / cam.w; } // world→css px (aspect-normalized)
  // The source ref-des of a wizard-added part is its component name (it
  // auto-renumbers at build), so edits locate it by the stable source offset the
  // scene graph stamps on every element/staged entry — not by ref.
  function srcByRef(ref) {
    if (!M) return 0;
    const p = M.passes.find((x) => x.ref === ref); if (p && p.src) return p.src;
    const h = M.hubs.find((x) => x.ref === ref); if (h && h.src) return h.src;
    return 0;
  }

  // ── Scene model (built once per load; drives draw + hit-test) ─────────
  function gkey(x, y) { return (Math.floor(x / GRID)) + "," + (Math.floor(y / GRID)); }
  function nearestWireVertex(x, y, maxD) {
    let best = null, bestD = (maxD || 40) * (maxD || 40);
    for (const wire of scene.wires) for (const p of wire.points) {
      const dx = p[0] - x, dy = p[1] - y, d = dx * dx + dy * dy;
      if (d < bestD) { bestD = d; best = { net: wire.net, x: p[0], y: p[1] }; }
    }
    return best;
  }
  // The wire stub serving an IC pin starts on the pin's row (same y) just
  // outside the box edge. Match by row + side and take the vertex nearest the
  // edge — reliable regardless of the stub length, where a plain radius search
  // could grab an unrelated far wire or miss at exactly the stub gap.
  function pinWire(ex, y, side) {
    let best = null, bestDX = 1e9;
    for (const wire of scene.wires) for (const p of wire.points) {
      if (Math.abs(p[1] - y) > 2) continue;
      if (side === "left" ? p[0] > ex + 1 : p[0] < ex - 1) continue;
      const dx = Math.abs(p[0] - ex);
      if (dx < bestDX) { bestDX = dx; best = { net: wire.net, x: p[0], y: p[1] }; }
    }
    return best;
  }
  // A short net stub + hanging net label for a dangling pin (its net isn't drawn
  // by the layout). Shaped like real wires/labels so they draw, pick, and snap.
  function stubWire(net, x0, y, x1) { return { net, bus: false, pts: [[x0, y], [x1, y]], bb: [Math.min(x0, x1), y, Math.max(x0, x1), y] }; }
  function stubLabel(net, x, y, anchor) { return { text: net, x, y, anchor, ground: isGroundName(net), port: false, net }; }
  function buildModel() {
    const m = { secs: [], wires: [], labels: [], passes: [], hubs: [], ports: [], grid: new Map() };
    scene.sections.forEach((s, i) => m.secs.push({ name: s.name, x: s.x, y: s.y, w: s.w, h: s.h, idx: i, cx: s.x + s.w / 2, cy: s.y + s.h / 2 }));
    scene.wires.forEach((w) => {
      let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
      for (const p of w.points) { if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0]; if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1]; }
      m.wires.push({ net: w.net, bus: w.bus, pts: w.points, bb: [x0, y0, x1, y1] });
    });
    scene.labels.forEach((l) => m.labels.push({ text: l.text, x: l.x, y: l.y, anchor: l.anchor, ground: l.ground, port: l.port, net: l.text }));
    scene.passives.forEach((p) => {
      // Wires connect at p.y (the centerline); draw the box centered on it so its
      // left/right edge midpoints — the terminals — sit exactly on the wire.
      const cyc = p.y, top = p.y - p.h / 2;
      const lp = nearestWireVertex(p.x, cyc), rp = nearestWireVertex(p.x + p.w, cyc);
      let lnet = lp ? lp.net : "", rnet = rp ? rp.net : "", lDangle = false, rDangle = false;
      // A pin assigned a net the layout never drew (a dangling / single-pin net):
      // recover it from the real pin→net bindings and show it as a stub + label so
      // the connection is visible and clickable. Gate on the *absence* of a wire
      // (lp/rp null), NOT an empty net string: a wire that's present but unnamed is
      // a deliberately unlabeled internal series node (e.g. an R→D link), and must
      // stay label-free — resurrecting its net there draws a redundant label.
      const real = (p.pins || []).map((x) => x.net).filter(Boolean);
      if (!lp || !rp) {
        const shown = [lnet, rnet].filter(Boolean);
        const free = real.filter((n) => !shown.includes(n));
        if (!lp && free.length) { lnet = free.shift(); lDangle = true; }
        if (!rp && free.length) { rnet = free.shift(); rDangle = true; }
      }
      m.passes.push({
        ref: p.ref, src: p.src || 0, x: p.x, top, w: p.w, h: p.h, cx: p.x + p.w / 2, cy: cyc, flip: !!p.flip,
        type: passType(p.ref, p.component, p.value, p.symbol),
        label: (p.count > 1 ? p.count + "× " : "") + (p.value || p.ref),
        term: [{ pin: "1", x: p.x, y: cyc, net: lnet }, { pin: "2", x: p.x + p.w, y: cyc, net: rnet }],
      });
      // Match the auto terminal-label spacing exactly: a net label sits
      // net_label_gap (18) past the wire end; a ground label sits right at it.
      const STUB = 26, NLG = 18;
      const dangle = (net, termX, dir) => {
        const endX = termX + dir * STUB;
        m.wires.push(stubWire(net, termX, cyc, endX));
        const labelX = isGroundName(net) ? endX : endX + dir * NLG;
        m.labels.push(stubLabel(net, labelX, cyc, dir < 0 ? "end" : "start"));
      };
      if (lDangle) dangle(lnet, p.x, -1);
      if (rDangle) dangle(rnet, p.x + p.w, 1);
    });
    scene.hubs.forEach((h) => {
      const pins = [];
      (h.leftPins || []).forEach((pn) => addPin(pins, h, pn, "left"));
      (h.rightPins || []).forEach((pn) => addPin(pins, h, pn, "right"));
      m.hubs.push({ ref: h.ref, src: h.src || 0, x: h.x, y: h.y, w: h.w, h: h.h, label: h.label || h.ref, cx: h.x + h.w / 2, cy: h.y + h.h / 2, pins });
    });
    // Connection ports for snap (net-bearing): pins, labels, wire vertices.
    m.hubs.forEach((h) => h.pins.forEach((p) => { if (p.net) addPort(m, p.x, p.y, p.net, "pin", h.ref, p.pin); }));
    m.labels.forEach((l) => { if (l.net) addPort(m, l.x, l.y, l.net, "label"); });
    m.wires.forEach((w) => { if (w.net) w.pts.forEach((p) => addPort(m, p[0], p[1], w.net, "wire")); });
    addStaged(m);
    firstBuild = false;
    M = m;
  }
  // Parts in the design but absent from the derived hub/spoke layout (a
  // just-added, not-yet-wired cap has no computed position) get a visible
  // "staging" slot to drag onto a pin. A newly-seen part lands at the centre of
  // the current view; the initial batch sits near board centre.
  function addStaged(m) {
    let slot = 0;
    for (const c of scene.staged || []) {
      const key = String(c.src || c.ref);
      if (!stagePos[key]) {
        stagePos[key] = firstBuild
          ? { x: scene.viewBox.w * 0.4 + (slot % 4) * 80, y: scene.viewBox.h * 0.4 + Math.floor(slot / 4) * 40 }
          : { x: cam.x + cam.w / 2 - 30 + slot * 14, y: cam.y + cam.h / 2 + slot * 14 };
        slot++;
      }
      const w = 60, h = 20, x = stagePos[key].x, cyc = stagePos[key].y;
      m.passes.push({
        ref: c.ref, src: c.src || 0, x, top: cyc - h / 2, w, h, cx: x + w / 2, cy: cyc, staged: true,
        type: passType(c.ref, c.component, c.value, c.symbol),
        label: c.value || c.component || c.ref,
        term: [{ pin: "1", x, y: cyc, net: "" }, { pin: "2", x: x + w, y: cyc, net: "" }],
      });
    }
  }
  // Classify a passive into a schematic-symbol kind from its ref-des prefix
  // (the R/C/L/D/FB/X… convention this codebase already uses for hub/spoke) with
  // component/value/symbol text as a tie-breaker. Unknown → plain box.
  function passType(ref, component, value, sym) {
    const s = ((component || "") + " " + (value || "") + " " + (sym || "")).toLowerCase();
    const leaf = (ref || "").split("/").pop();
    const pre = (leaf.match(/^[A-Za-z]+/) || [""])[0].toUpperCase();
    if (s.includes("led") || pre === "LED") return "led";
    if (pre === "R" || s.includes("res")) return "resistor";
    if (pre === "C" || s.includes("cap")) return "capacitor";
    if (pre === "L" || s.includes("induct")) return "inductor";
    if (pre === "FB" || pre === "F" || s.includes("ferrite") || s.includes("bead")) return "ferrite";
    if (pre === "D" || s.includes("diode")) return "diode";
    if (pre === "X" || pre === "Y" || s.includes("crystal") || s.includes("xtal") || s.includes("osc")) return "crystal";
    return "box";
  }
  function addPin(pins, h, pn, side) {
    const ex = side === "left" ? h.x : h.x + h.w;
    const v = pinWire(ex, pn.y, side);
    pins.push({ pin: (pn.pins || "").split(",")[0], name: pn.name || pn.pins, side, x: ex, y: pn.y, net: v ? v.net : "", vx: v ? v.x : null, vy: v ? v.y : null });
  }
  function addPort(m, x, y, net, t, ref, pin) {
    const port = { x, y, net, t, ref, pin };
    m.ports.push(port);
    const k = gkey(x, y);
    let cell = m.grid.get(k); if (!cell) { cell = []; m.grid.set(k, cell); }
    cell.push(port);
  }
  function portsNear(x, y) {
    const out = []; const cx = Math.floor(x / GRID), cy = Math.floor(y / GRID);
    for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) { const c = M.grid.get((cx + i) + "," + (cy + j)); if (c) out.push(...c); }
    return out;
  }

  // ── Camera ───────────────────────────────────────────────────────────
  function normalizeAspect() {
    const r = rectOf(); if (!r.width || !r.height) return;
    const want = r.width / r.height, have = cam.w / cam.h;
    if (have < want) { const nw = cam.h * want; cam.x -= (nw - cam.w) / 2; cam.w = nw; }
    else { const nh = cam.w / want; cam.y -= (nh - cam.h) / 2; cam.h = nh; }
  }
  function fitTo(bb, padFrac) {
    const pad = padFrac || 0.06, px = bb.w * pad, py = bb.h * pad;
    cam = { x: bb.x - px, y: bb.y - py, w: Math.max(bb.w + 2 * px, 50), h: Math.max(bb.h + 2 * py, 50) };
    normalizeAspect(); scheduleDraw();
  }
  function fitAll() {
    activeSheet = -1;
    fitTo({ x: 0, y: 0, w: scene.viewBox.w, h: scene.viewBox.h }, 0.03);
    syncSheetUI(); updateStatus();
  }
  function worldFromEvent(e) {
    const r = rectOf();
    return [cam.x + ((e.clientX - r.left) / r.width) * cam.w, cam.y + ((e.clientY - r.top) / r.height) * cam.h];
  }
  function sizeCanvas() {
    const r = wrap.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.floor(r.width * dpr));
    canvas.height = Math.max(1, Math.floor(r.height * dpr));
    canvas.style.width = r.width + "px"; canvas.style.height = r.height + "px";
    normalizeAspect(); scheduleDraw();
  }

  // ── Draw ─────────────────────────────────────────────────────────────
  function offsetFor(ref) {
    if (drag && drag.kind === "part" && drag.ownerRef === ref) return drag.delta;
    if (springBack && springBack.ref === ref) return [springBack.dx, springBack.dy];
    return null;
  }
  function draw() {
    const dpr = window.devicePixelRatio || 1, s = scale();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(s * dpr, 0, 0, s * dpr, -cam.x * s * dpr, -cam.y * s * dpr);
    const sw = (px) => px / s;                       // screen-constant stroke width in world units
    const iso = isoBox.checked && activeSheet >= 0 && M.secs[activeSheet];
    const sec = iso ? M.secs[activeSheet] : null;
    const pad = 8;
    const inBox = (x, y) => !iso || (x >= sec.x - pad && x <= sec.x + sec.w + pad && y >= sec.y - pad && y <= sec.y + sec.h + pad);
    const dimW = drag ? 0.12 : 1;                    // dim wires while dragging
    ctx.lineJoin = "round"; ctx.lineCap = "round"; ctx.textBaseline = "middle";
    // Viewport culling: skip anything outside the camera box (+4% margin). The
    // win is largest zoomed into one sheet — the other sheets' wires/labels are
    // never touched. A part being dragged/springing is offset, so it's never
    // culled by its canonical box.
    const mx = cam.w * 0.04, my = cam.h * 0.04;
    const vx0 = cam.x - mx, vy0 = cam.y - my, vx1 = cam.x + cam.w + mx, vy1 = cam.y + cam.h + my;
    const boxVis = (x0, y0, x1, y1) => x1 >= vx0 && x0 <= vx1 && y1 >= vy0 && y0 <= vy1;
    const ptVis = (x, y) => x >= vx0 && x <= vx1 && y >= vy0 && y <= vy1;

    // Sections
    M.secs.forEach((sc) => {
      if (!boxVis(sc.x, sc.y, sc.x + sc.w, sc.y + sc.h)) return;
      ctx.globalAlpha = (iso && sc.idx !== activeSheet) ? 0.12 : 1;
      ctx.strokeStyle = sc.idx === activeSheet ? "#3a5878" : C.secStroke;
      ctx.lineWidth = sw(1.4); ctx.setLineDash([sw(6), sw(5)]);
      ctx.strokeRect(sc.x, sc.y, sc.w, sc.h);
      ctx.setLineDash([]);
      if (18 * s >= 8) { ctx.fillStyle = C.secLabel; ctx.font = "600 18px sans-serif"; ctx.textAlign = "left"; ctx.fillText(sc.name, sc.x + 10, sc.y - 8); }
    });

    // Wires
    M.wires.forEach((w) => {
      if (!boxVis(w.bb[0], w.bb[1], w.bb[2], w.bb[3])) return;
      const mid = w.pts[Math.floor(w.pts.length / 2)];
      const hot = hotNet && w.net === hotNet;
      ctx.globalAlpha = drag ? dimW : (inBox(mid[0], mid[1]) ? 1 : 0.12);
      ctx.strokeStyle = hot ? C.hot : (w.bus ? C.bus : C.wire);
      ctx.lineWidth = sw(hot ? 2.4 : (w.bus ? 3 : 1.5));
      ctx.beginPath(); ctx.moveTo(w.pts[0][0], w.pts[0][1]);
      for (let i = 1; i < w.pts.length; i++) ctx.lineTo(w.pts[i][0], w.pts[i][1]);
      ctx.stroke();
    });
    ctx.globalAlpha = 1;

    // Labels — net-name stubs / ports as text; grounds as a real earth symbol
    // (node dot on the wire, rake pointing down, caption below). The symbol
    // draws at any zoom; only its caption obeys the LOD text cutoff.
    {
      const showText = 11 * s >= 7;
      ctx.font = "11px sans-serif";
      M.labels.forEach((l) => {
        if (!ptVis(l.x, l.y)) return;
        ctx.globalAlpha = inBox(l.x, l.y) ? 1 : 0.12;
        const hot = hotNet && l.net === hotNet;
        if (l.ground) { drawGround(l.x, l.y, hot, sw, showText, l.text); return; }
        if (!showText) return;
        ctx.fillStyle = hot ? C.hot : l.port ? C.labelPort : C.labelNet;
        ctx.textAlign = l.anchor === "start" ? "left" : l.anchor === "end" ? "right" : "center";
        ctx.textBaseline = "middle";
        ctx.fillText(l.text, l.x, l.y);
      });
      ctx.globalAlpha = 1;
      ctx.textBaseline = "middle";                    // drawGround leaves it "top"
    }

    // Passives
    M.passes.forEach((p) => {
      const off = offsetFor(p.ref), ox = off ? off[0] : 0, oy = off ? off[1] : 0;
      if (!off && !boxVis(p.x, p.top, p.x + p.w, p.top + p.h)) return;
      const seld = selection && selection.ref === p.ref;
      const x0 = p.x + ox, x1 = p.x + p.w + ox, cy = p.cy + oy;
      const amp = Math.min(6, p.w * 0.22);
      ctx.globalAlpha = p.staged ? 1 : (inBox(p.cx, p.cy) ? 1 : 0.12);
      if (p.staged) { ctx.strokeStyle = C.snap; ctx.lineWidth = sw(1.2); ctx.setLineDash([sw(4), sw(3)]); roundRect(x0 - sw(5), cy - amp - sw(7), (x1 - x0) + sw(10), 2 * amp + sw(14), sw(4)); ctx.stroke(); ctx.setLineDash([]); }
      ctx.strokeStyle = seld ? C.sel : C.passStroke; ctx.lineWidth = sw(seld ? 2.2 : 1.5);
      if (p.type === "box") { ctx.fillStyle = C.pass; roundRect(x0, p.top + oy, p.w, p.h, sw(3)); ctx.fill(); ctx.stroke(); }
      // Left-side spokes are mirrored about their centre so directional symbols
      // (diode/LED) point the right way on both sides of the IC; symmetric ones
      // look identical either way.
      else if (p.flip) { ctx.save(); ctx.translate(2 * (p.cx + ox), 0); ctx.scale(-1, 1); symbol(p.type, x0, x1, cy, sw); ctx.restore(); }
      else symbol(p.type, x0, x1, cy, sw);
      for (const t of p.term) {                       // terminal nodes on the two sides
        const hot = hotNet && t.net === hotNet;
        ctx.beginPath(); ctx.arc(t.x + ox, t.y + oy, sw(3.5), 0, 7);
        ctx.fillStyle = hot ? C.hot : C.pin; ctx.strokeStyle = hot ? C.hot : C.pinStroke; ctx.lineWidth = sw(1); ctx.fill(); ctx.stroke();
      }
      if (11 * s >= 7) { ctx.fillStyle = C.passText; ctx.font = "11px sans-serif"; ctx.textAlign = "center"; ctx.fillText(p.label.length > 14 ? p.label.slice(0, 13) + "…" : p.label, p.cx + ox, cy + amp + 9); }
    });
    ctx.globalAlpha = 1;

    // Hubs + pins
    M.hubs.forEach((h) => {
      const off = offsetFor(h.ref), ox = off ? off[0] : 0, oy = off ? off[1] : 0;
      if (!off && !boxVis(h.x, h.y, h.x + h.w, h.y + h.h)) return;
      ctx.globalAlpha = inBox(h.cx, h.cy) ? 1 : 0.12;
      // pin connector stubs (close the gap to the wire)
      ctx.strokeStyle = C.wire; ctx.lineWidth = sw(1.4);
      h.pins.forEach((p) => { if (p.vx != null) { ctx.beginPath(); ctx.moveTo(p.x + ox, p.y + oy); ctx.lineTo(p.vx + (off ? ox : 0), p.vy + (off ? oy : 0)); ctx.stroke(); } });
      // body
      ctx.fillStyle = C.hub; ctx.strokeStyle = (selection && selection.ref === h.ref) ? C.sel : C.hubStroke;
      ctx.lineWidth = sw(selection && selection.ref === h.ref ? 3 : 2);
      roundRect(h.x + ox, h.y + oy, h.w, h.h, sw(4)); ctx.fill(); ctx.stroke();
      if (15 * s >= 8) { ctx.fillStyle = C.hubLabel; ctx.font = "600 15px sans-serif"; ctx.textAlign = "center"; ctx.fillText(h.label, h.cx + ox, h.y + oy + 16); }
      // pins
      h.pins.forEach((p) => {
        const hot = hotNet && p.net === hotNet;
        ctx.beginPath(); ctx.arc(p.x + ox, p.y + oy, sw(4.5), 0, 7);
        ctx.fillStyle = hot ? C.hot : C.pin; ctx.strokeStyle = hot ? C.hot : C.pinStroke; ctx.lineWidth = sw(1); ctx.fill(); ctx.stroke();
        if (11 * s >= 7 && p.name) {
          ctx.fillStyle = C.pinName; ctx.font = "11px sans-serif"; ctx.textAlign = p.side === "left" ? "left" : "right";
          const nm = p.name.length > 14 ? p.name.slice(0, 13) + "…" : p.name;
          ctx.fillText(nm, (p.side === "left" ? h.x + 7 : h.x + h.w - 7) + ox, p.y + oy);
        }
      });
    });
    ctx.globalAlpha = 1;

    // Snap / rubber-band overlay
    if (drag) {
      if (drag.kind === "pin") { ctx.strokeStyle = C.band; ctx.lineWidth = sw(1.7); ctx.setLineDash([sw(4), sw(4)]); line(drag.anchor[0], drag.anchor[1], drag.cursor[0], drag.cursor[1]); ctx.setLineDash([]); }
      if (drag.best) {
        const b = drag.best;
        ctx.strokeStyle = C.snap; ctx.lineWidth = sw(2); ctx.setLineDash([sw(5), sw(4)]); line(b.tx, b.ty, b.port.x, b.port.y); ctx.setLineDash([]);
        ctx.beginPath(); ctx.arc(b.port.x, b.port.y, sw(8), 0, 7); ctx.stroke();
      }
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
  }
  function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }
  function line(x1, y1, x2, y2) { ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); }

  // Earth-ground symbol drawn at a terminal: the connection node sits ON the
  // wire end (x,y) so it visibly touches the net, a short stub drops to the
  // three-bar rake, and the net caption reads below the icon. (Replaces the old
  // inline "⏚ GND" text that straddled the wire and never connected to it.)
  // Geometry is world units (scales with zoom); strokes stay screen-constant.
  function drawGround(x, y, hot, sw, showText, text) {
    const col = hot ? C.hot : C.labelGnd;
    const top = y + 6, gap = 3.2, half = [11, 7, 3.5];
    ctx.strokeStyle = col; ctx.lineWidth = sw(1.6);
    ctx.beginPath();
    ctx.moveTo(x, y); ctx.lineTo(x, top);                          // stub from the net down
    for (let i = 0; i < 3; i++) { const yy = top + i * gap; ctx.moveTo(x - half[i], yy); ctx.lineTo(x + half[i], yy); }
    ctx.stroke();
    ctx.beginPath(); ctx.arc(x, y, sw(3.2), 0, 7); ctx.fillStyle = col; ctx.fill();   // node on the net
    if (showText) { ctx.fillStyle = col; ctx.textAlign = "center"; ctx.textBaseline = "top"; ctx.fillText(text, x, top + 2 * gap + 4); }
  }

  // Draw a horizontal 2-terminal passive symbol on the axis x0→x1 at y=cy. The
  // current ctx.strokeStyle/lineWidth are honored; diode/LED triangles fill with
  // the stroke colour. Geometry is in world units, so the glyph scales with zoom.
  function symbol(type, x0, x1, cy, sw) {
    const cx = (x0 + x1) / 2, len = x1 - x0, amp = Math.min(6, len * 0.22);
    const bodyW = Math.min(Math.max(len * 0.5, 8), Math.max(len - 6, 4));
    const bx0 = cx - bodyW / 2, bx1 = cx + bodyW / 2;
    switch (type) {
      case "resistor": {
        line(x0, cy, bx0, cy); line(bx1, cy, x1, cy);
        const n = 6, step = bodyW / n;
        ctx.beginPath(); ctx.moveTo(bx0, cy);
        for (let i = 0; i < n; i++) ctx.lineTo(bx0 + step * (i + 0.5), cy + (i % 2 ? amp : -amp));
        ctx.lineTo(bx1, cy); ctx.stroke();
        break;
      }
      case "capacitor": {
        const g = Math.min(5, bodyW * 0.5);
        line(x0, cy, cx - g / 2, cy); line(cx + g / 2, cy, x1, cy);
        line(cx - g / 2, cy - amp, cx - g / 2, cy + amp);
        line(cx + g / 2, cy - amp, cx + g / 2, cy + amp);
        break;
      }
      case "inductor": {
        line(x0, cy, bx0, cy); line(bx1, cy, x1, cy);
        const n = 4, r = bodyW / (2 * n);
        ctx.beginPath();
        for (let i = 0; i < n; i++) ctx.arc(bx0 + r + i * 2 * r, cy, r, Math.PI, 0, true);
        ctx.stroke();
        break;
      }
      case "ferrite": {
        line(x0, cy, bx0, cy); line(bx1, cy, x1, cy);
        ctx.strokeRect(bx0, cy - amp, bodyW, 2 * amp);
        break;
      }
      case "diode":
      case "led": {
        const tL = cx - amp, tR = cx + amp;
        line(x0, cy, tL, cy); line(tR, cy, x1, cy);
        ctx.beginPath(); ctx.moveTo(tL, cy - amp); ctx.lineTo(tL, cy + amp); ctx.lineTo(tR, cy); ctx.closePath();
        const fs = ctx.fillStyle; ctx.fillStyle = ctx.strokeStyle; ctx.fill(); ctx.fillStyle = fs; ctx.stroke();
        line(tR, cy - amp, tR, cy + amp); // cathode bar
        if (type === "led") {
          for (let k = 0; k < 2; k++) {
            const ax = cx + 1 + k * 4, ay = cy - amp - 1, ex = ax + 5, ey = ay - 6;
            line(ax, ay, ex, ey);
            const a = Math.atan2(ey - ay, ex - ax), hh = 2.6;
            line(ex, ey, ex - hh * Math.cos(a - 0.5), ey - hh * Math.sin(a - 0.5));
            line(ex, ey, ex - hh * Math.cos(a + 0.5), ey - hh * Math.sin(a + 0.5));
          }
        }
        break;
      }
      case "crystal": {
        const g = Math.min(4, bodyW * 0.3);
        line(x0, cy, cx - g - 2, cy); line(cx + g + 2, cy, x1, cy);
        line(cx - g - 2, cy - amp, cx - g - 2, cy + amp);
        line(cx + g + 2, cy - amp, cx + g + 2, cy + amp);
        ctx.strokeRect(cx - g, cy - amp, 2 * g, 2 * amp);
        break;
      }
      default: { roundRect(x0, cy - amp, len, 2 * amp, sw(2)); ctx.stroke(); }
    }
  }

  function frame() {
    if (springBack) { springBack.dx *= 0.72; springBack.dy *= 0.72; if (Math.abs(springBack.dx) + Math.abs(springBack.dy) < 0.6) springBack = null; dirty = true; }
    if (dirty) { dirty = false; draw(); }
    requestAnimationFrame(frame);
  }

  // ── Hit testing ──────────────────────────────────────────────────────
  function distToSeg(px, py, a, b) {
    const vx = b[0] - a[0], vy = b[1] - a[1], wx = px - a[0], wy = py - a[1];
    const c1 = vx * wx + vy * wy; if (c1 <= 0) return Math.hypot(px - a[0], py - a[1]);
    const c2 = vx * vx + vy * vy; if (c2 <= c1) return Math.hypot(px - b[0], py - b[1]);
    const t = c1 / c2; return Math.hypot(px - (a[0] + t * vx), py - (a[1] + t * vy));
  }
  function pick(x, y) {
    const s = scale(), tp = 7 / s, tw = 5 / s, tl = 9 / s;
    for (const h of M.hubs) for (const p of h.pins) if (Math.hypot(p.x - x, p.y - y) < tp) return { t: "pin", ref: h.ref, pin: p.pin, net: p.net, x: p.x, y: p.y };
    for (const h of M.hubs) if (x >= h.x && x <= h.x + h.w && y >= h.y && y <= h.y + h.h) return { t: "part", ref: h.ref, kind: "hub" };
    for (const p of M.passes) if (x >= p.x && x <= p.x + p.w && y >= p.top && y <= p.top + p.h) return { t: "part", ref: p.ref, kind: "pass" };
    for (const w of M.wires) for (let i = 1; i < w.pts.length; i++) if (distToSeg(x, y, w.pts[i - 1], w.pts[i]) < tw) return { t: "net", net: w.net };
    for (const l of M.labels) if (Math.hypot(l.x - x, l.y - y) < tl) return { t: "net", net: l.net };
    return { t: "empty" };
  }

  // ── Interaction: pan / zoom / drag-to-connect / click ────────────────
  const SNAP_PX = 16;
  let mode = null, down = null, drag = null;

  canvas.addEventListener("pointerdown", (e) => {
    const w = worldFromEvent(e);
    down = { mx: e.clientX, my: e.clientY, world: w, camx: cam.x, camy: cam.y, hit: pick(w[0], w[1]) };
    try { canvas.setPointerCapture(e.pointerId); } catch (x) {}
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!down) return;
    if (!mode && (Math.abs(e.clientX - down.mx) + Math.abs(e.clientY - down.my) > 5)) {
      if (down.hit.t === "pin") { mode = "drag"; startDrag("pin", down.hit); }
      else if (down.hit.t === "part") { mode = "drag"; startDrag("part", down.hit); }
      else { mode = "pan"; canvas.classList.add("panning"); }
    }
    if (mode === "pan") { const s = scale(); cam.x = down.camx - (e.clientX - down.mx) / s; cam.y = down.camy - (e.clientY - down.my) / s; scheduleDraw(); }
    else if (mode === "drag") updateDrag(worldFromEvent(e));
  });
  canvas.addEventListener("pointerup", (e) => {
    try { canvas.releasePointerCapture(e.pointerId); } catch (x) {}
    if (mode === "pan") canvas.classList.remove("panning");
    else if (mode === "drag") endDrag();
    else if (down) {                                   // click (no movement)
      const h = down.hit;
      if (h.t === "pin") highlightNetToggle(h.net);
      else if (h.t === "part") select(h.kind, h.ref);
      else if (h.t === "net") highlightNetToggle(h.net);
      else deselect();
    }
    mode = null; down = null;
  });
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const r = rectOf(), mx = (e.clientX - r.left) / r.width, my = (e.clientY - r.top) / r.height;
    const wx = cam.x + mx * cam.w, wy = cam.y + my * cam.h, f = e.deltaY > 0 ? 1.12 : 1 / 1.12;
    cam.w = Math.min(Math.max(cam.w * f, 20), scene.viewBox.w * 4);
    cam.h = Math.min(Math.max(cam.h * f, 16), scene.viewBox.h * 4);
    cam.x = wx - mx * cam.w; cam.y = wy - my * cam.h; scheduleDraw();
  }, { passive: false });
  // Double-click selects the subject and jumps focus into its first inspector
  // field (net name / part value) for a quick edit. (The two single-clicks fire
  // first — they just select it.)
  canvas.addEventListener("dblclick", (e) => {
    const w = worldFromEvent(e), h = pick(w[0], w[1]);
    if (h.t === "net" || (h.t === "pin" && h.net)) { setHotNet(h.net); focusInspectorPrimary(); }
    else if (h.t === "part") { select(h.kind, h.ref); focusInspectorPrimary(); }
  });

  // Part and net are mutually exclusive in the inspector: selecting one clears
  // the other so the panel always reflects a single subject.
  function select(kind, ref) { selection = { kind, ref }; hotNet = null; deleteArmed = false; renderInspector(); updateStatus(); scheduleDraw(); }
  function deselect() { selection = null; hotNet = null; deleteArmed = false; renderInspector(); updateStatus(); scheduleDraw(); }
  function highlightNetToggle(net) { if (!net) return; hotNet = hotNet === net ? null : net; selection = null; deleteArmed = false; renderInspector(); updateStatus(); scheduleDraw(); }
  function setHotNet(net) { if (!net) return; hotNet = net; selection = null; deleteArmed = false; renderInspector(); updateStatus(); scheduleDraw(); }
  // Rename a net everywhere it's used (all pins/ports/net-forms). Renaming onto an
  // existing net name merges them. Driven by the inspector's Net name field.
  async function renameNet(oldNet, to) {
    if (!oldNet || !to || to === oldNet) return;
    try {
      await api("POST", `/api/rename-net/${DESIGN}`, { from: oldNet, to });
      if (hotNet === oldNet) hotNet = to;
      toast(`Renamed ${oldNet} → ${to}`);
      await refetch();
    } catch (err) { toast("Rename failed: " + err.message, true); }
  }

  // ── Drag-to-connect ──────────────────────────────────────────────────
  function startDrag(kind, hit) {
    if (kind === "pin") {
      drag = { kind: "pin", ownerRef: hit.ref, src: srcByRef(hit.ref), anchor: [hit.x, hit.y], cursor: [hit.x, hit.y], terminals: [{ ref: hit.ref, pin: hit.pin, net: hit.net, x: hit.x, y: hit.y }], best: null };
    } else {
      const item = M.hubs.find((h) => h.ref === hit.ref) || M.passes.find((p) => p.ref === hit.ref);
      const terminals = item.pins ? item.pins.map((p) => ({ ref: hit.ref, pin: p.pin, net: p.net, x: p.x, y: p.y })) : item.term.map((t) => ({ ref: hit.ref, pin: t.pin, net: t.net, x: t.x, y: t.y }));
      drag = { kind: "part", ownerRef: hit.ref, src: item.src || 0, delta: [0, 0], terminals, best: null, staged: !!item.staged, stageKey: String(item.src || item.ref) };
    }
    updateStatus();
  }
  function terminalsForConnect() {
    if (drag.kind === "pin") return drag.terminals;
    const floating = drag.terminals.filter((t) => !t.net);
    return floating.length ? floating : drag.terminals;
  }
  function updateDrag(cur) {
    if (drag.kind === "part") drag.delta = [cur[0] - down.world[0], cur[1] - down.world[1]];
    else drag.cursor = cur;
    const tol = SNAP_PX / scale(), bd = tol * tol;
    let best = null;
    terminalsForConnect().forEach((t) => {
      const tx = drag.kind === "part" ? t.x + drag.delta[0] : drag.cursor[0];
      const ty = drag.kind === "part" ? t.y + drag.delta[1] : drag.cursor[1];
      portsNear(tx, ty).forEach((pt) => {
        if (pt.ref === drag.ownerRef) return;
        const dx = pt.x - tx, dy = pt.y - ty, d = dx * dx + dy * dy;
        if (d < bd && (!best || d < best.d)) best = { d, term: t, tx, ty, port: pt };
      });
    });
    drag.best = best; scheduleDraw();
  }
  async function endDrag() {
    canvas.classList.remove("panning");
    const b = drag.best, d = drag;
    drag = null;
    if (!b) {
      // No snap target: a staged part stays where you dropped it (persist its
      // position); a placed part springs back to its derived spot.
      if (d.kind === "part" && d.staged && stagePos[d.stageKey]) { stagePos[d.stageKey].x += d.delta[0]; stagePos[d.stageKey].y += d.delta[1]; buildModel(); }
      else if (d.kind === "part") springBack = { ref: d.ownerRef, dx: d.delta[0], dy: d.delta[1] };
      scheduleDraw(); updateStatus(); return;
    }
    // Resolve which pin gets which net, plus the source offset to locate it.
    let ref, pin, net, so;
    if (b.port.net) { ref = b.term.ref; pin = b.term.pin; net = b.port.net; so = d.src; }
    else if (b.term.net && b.port.t === "pin") { ref = b.port.ref; pin = b.port.pin; net = b.term.net; so = srcByRef(b.port.ref); }
    else if (b.term.net) { ref = b.term.ref; pin = b.term.pin; net = b.term.net; so = d.src; }
    else { const n = prompt("New net name for this connection:", ""); if (!n) { if (d.kind === "part") springBack = { ref: d.ownerRef, dx: d.delta[0], dy: d.delta[1] }; return; } ref = b.term.ref; pin = b.term.pin; net = n; so = d.src; }
    try {
      await api("POST", `/api/rewire-pin/${DESIGN}`, { ref, pin, net, srcOff: so });
      const bound = await maybeBindDecouple(d, b);
      toast(bound ? `Connected ${ref}.${pin} → ${net} · pinned near ${bound}` : `Connected ${ref}.${pin} → ${net}`);
      await refetch();
    } catch (err) { toast("Connect failed: " + err.message, true); if (d.kind === "part") springBack = { ref: d.ownerRef, dx: d.delta[0], dy: d.delta[1] }; }
  }
  // A cap dropped on a hub pin records a (decouples "IC" PAD) binding so the
  // renderer docks it on THAT hub (boundHubPin), not whichever hub on a shared
  // net draws first — the DSL's "place this cap next to this pin" intent. Caps
  // only (the form is cap-specific); skip ground pins (a cap decouples a signal/
  // power pad referenced to ground, never the ground pad itself). Best-effort:
  // the wire already landed, so a failed binding just leaves default placement.
  async function maybeBindDecouple(d, b) {
    if (!d || d.kind !== "part" || !b || !b.port || b.port.t !== "pin" || !b.port.ref) return null;
    const tgtNet = b.port.net || (b.term && b.term.net) || "";
    if (isGroundName(tgtNet)) return null;
    const dp = M.passes.find((x) => x.ref === d.ownerRef);
    if (!dp || dp.type !== "capacitor") return null;
    try {
      await api("POST", `/api/bind-decouple/${DESIGN}`, { ref: d.ownerRef, ic: b.port.ref, pin: b.port.pin, srcOff: d.src });
      return b.port.ref + "." + b.port.pin;
    } catch (e) { return null; }
  }
  function isGroundName(n) { return /^(?:[adpe]?gnd|gnd[adpe]?|vss|ground)\b/i.test(String(n || "").trim()); }

  // ── Sheet navigator ──────────────────────────────────────────────────
  function buildSheetList() {
    clear(sheetList);
    const whole = document.createElement("div");
    whole.className = "ed-sheet"; whole.dataset.idx = "-1";
    whole.innerHTML = '<span class="num">0</span><span class="nm">Whole board</span>';
    whole.onclick = () => fitAll(); sheetList.appendChild(whole);
    scene.sections.forEach((s, i) => {
      const row = document.createElement("div");
      row.className = "ed-sheet"; row.dataset.idx = String(i);
      const n = i + 1;
      row.innerHTML = `<span class="num">${n <= 9 ? n : "·"}</span><span class="nm"></span><span class="ct">${countInSection(s)}</span>`;
      row.querySelector(".nm").textContent = s.name;
      row.title = s.description || s.name;
      row.onclick = () => selectSheet(i);
      sheetList.appendChild(row);
    });
    syncSheetUI();
  }
  function countInSection(s) {
    const pad = 8; let c = 0;
    const inside = (x, y) => x >= s.x - pad && x <= s.x + s.w + pad && y >= s.y - pad && y <= s.y + s.h + pad;
    scene.hubs.forEach((h) => { if (inside(h.x + h.w / 2, h.y + h.h / 2)) c++; });
    scene.passives.forEach((p) => { if (inside(p.x + p.w / 2, p.y + p.h / 2)) c++; });
    return c;
  }
  function selectSheet(i) {
    if (!scene.sections[i]) return;
    activeSheet = i; const s = scene.sections[i];
    fitTo({ x: s.x, y: s.y, w: s.w, h: s.h }, 0.08);
    syncSheetUI(); updateStatus();
  }
  function syncSheetUI() { [...sheetList.children].forEach((row) => row.classList.toggle("active", Number(row.dataset.idx) === activeSheet)); }
  function stepSheet(d) { const n = scene.sections.length; if (!n) return; selectSheet(activeSheet < 0 ? (d > 0 ? 0 : n - 1) : (activeSheet + d + n) % n); }

  // ── Status ───────────────────────────────────────────────────────────
  function updateStatus() {
    const parts = [];
    parts.push(activeSheet >= 0 && scene.sections[activeSheet] ? "Sheet: " + scene.sections[activeSheet].name : "Whole board");
    if (selection) parts.push('<span class="sel">' + selection.ref + "</span>");
    if (hotNet) parts.push("net: " + hotNet);
    if (M) { const u = M.passes.filter((p) => p.staged).length; if (u) parts.push('<span style="color:#f0883e">⚠ ' + u + ' unplaced — drag onto a pin to wire</span>'); }
    parts.push("drag a pin/part onto a net to connect · A add · E edit · Del remove · F fit · ? keys");
    statusBar.innerHTML = parts.join('<span style="opacity:.4">|</span>');
  }

  // ── Inspector (left properties panel — replaces the edit popups) ──────
  function mkEl(tag, cls, txt) { const e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }
  function partMeta(ref) {
    return scene.hubs.find((x) => x.ref === ref) || scene.passives.find((x) => x.ref === ref) || (scene.staged || []).find((x) => x.ref === ref) || null;
  }
  function isHubRef(ref) { return !!(M && M.hubs.find((x) => x.ref === ref)); }
  function partPins(ref) {
    // Passives/staged carry authoritative pin→net from the netlist (so a pin on a
    // brand-new single-pin net still shows its name instead of reading blank).
    const sp = scene.passives.find((x) => x.ref === ref) || (scene.staged || []).find((x) => x.ref === ref);
    if (sp && sp.pins && sp.pins.length) return sp.pins.map((pn) => ({ pin: pn.pin, label: "pin " + pn.pin, net: pn.net })).sort((a, b) => {
      const na = parseInt(a.pin, 10), nb = parseInt(b.pin, 10);
      return (!isNaN(na) && !isNaN(nb)) ? na - nb : String(a.pin).localeCompare(String(b.pin));
    });
    const h = M && M.hubs.find((x) => x.ref === ref);
    if (h) return h.pins.map((p) => ({ pin: p.pin, label: p.name || p.pin, net: p.net }));
    const p = M && M.passes.find((x) => x.ref === ref);
    if (p) return p.term.map((t) => ({ pin: t.pin, label: "pin " + t.pin, net: t.net }));
    return [];
  }
  function netConnections(net) {
    const out = [];
    (M ? M.hubs : []).forEach((h) => h.pins.forEach((p) => { if (p.net === net) out.push({ ref: h.ref, pin: p.name || p.pin }); }));
    (M ? M.passes : []).forEach((p) => p.term.forEach((t) => { if (t.net === net) out.push({ ref: p.ref, pin: "pin " + t.pin }); }));
    return out;
  }
  // A labeled field; read-only when onCommit is null, else commits on Enter/blur.
  function fieldRow(label, value, onCommit) {
    const row = mkEl("div", "ed-fld"); row.appendChild(mkEl("label", null, label));
    if (!onCommit) { const d = mkEl("div", "ro"); d.textContent = value || "—"; row.appendChild(d); return row; }
    const inp = document.createElement("input"); inp.value = value || "";
    inp.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); inp.blur(); } });
    inp.addEventListener("change", () => { const v = inp.value.trim(); if (v !== (value || "")) onCommit(v); });
    row.appendChild(inp); return row;
  }
  function renderInspector() {
    clear(inspector);
    if (selection) { renderPartInspector(selection.ref); return; }
    if (hotNet) { renderNetInspector(hotNet); return; }
    inspector.appendChild(mkEl("div", "ed-insp-empty", "Select a part or net to see and edit its properties — click on the canvas, or double-click to jump straight to editing."));
  }
  function renderPartInspector(ref) {
    const meta = partMeta(ref);
    if (!meta) { inspector.appendChild(mkEl("div", "ed-insp-empty", ref + " is no longer in the design.")); return; }
    const hub = isHubRef(ref);
    const head = mkEl("div", "ed-insp-head");
    head.appendChild(mkEl("span", "t", "Part")); head.appendChild(mkEl("span", "r", ref));
    head.appendChild(mkEl("span", "badge", hub ? "IC" : passType(ref, meta.component, meta.value, meta.symbol)));
    inspector.appendChild(head);
    const body = mkEl("div", "ed-insp-body");
    body.appendChild(fieldRow("Ref-des", ref, null));
    body.appendChild(fieldRow("Component", meta.component || "—", null));
    body.appendChild(fieldRow("Value", meta.value || "", (v) => applyValue(ref, v)));
    const pins = partPins(ref);
    if (pins.length) {
      body.appendChild(mkEl("div", "ed-insp-sec", "Pins → net"));
      pins.forEach((p) => {
        const row = mkEl("div", "ed-pinline");
        const pl = mkEl("span", "pl", p.label); pl.title = "pad " + p.pin; row.appendChild(pl);
        const inp = document.createElement("input"); inp.value = p.net || ""; inp.placeholder = "(unconnected)";
        inp.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); inp.blur(); } });
        inp.addEventListener("change", () => { const v = inp.value.trim(); if (v && v !== (p.net || "")) applyPinNet(ref, p.pin, v); });
        row.appendChild(inp); body.appendChild(row);
      });
    }
    const acts = mkEl("div", "ed-insp-actions");
    const copyBtn = mkEl("button", "ed-btn", "Copy"); copyBtn.onclick = () => doCopy(ref); acts.appendChild(copyBtn);
    const delBtn = mkEl("button", "ed-btn danger" + (deleteArmed ? " armed" : ""), deleteArmed ? "Confirm remove" : "Delete");
    delBtn.onclick = () => deleteSelected(); acts.appendChild(delBtn);
    body.appendChild(acts);
    inspector.appendChild(body);
  }
  function renderNetInspector(net) {
    const head = mkEl("div", "ed-insp-head");
    head.appendChild(mkEl("span", "t", "Net")); head.appendChild(mkEl("span", "r", net));
    inspector.appendChild(head);
    const body = mkEl("div", "ed-insp-body");
    body.appendChild(fieldRow("Net name", net, (v) => renameNet(net, v)));
    const conns = netConnections(net);
    body.appendChild(mkEl("div", "ed-insp-sec", "Connections (" + conns.length + ")"));
    if (!conns.length) body.appendChild(mkEl("div", "ed-insp-empty", "No pins on this net."));
    conns.forEach((c) => {
      const row = mkEl("div", "ed-conn");
      row.appendChild(mkEl("span", "cr", c.ref)); row.appendChild(mkEl("span", "cp", c.pin));
      row.onclick = () => select(isHubRef(c.ref) ? "hub" : "pass", c.ref);
      body.appendChild(row);
    });
    inspector.appendChild(body);
  }
  function focusInspectorPrimary() { const i = inspector.querySelector("input"); if (i) { i.focus(); i.select(); } }

  // ── Edits (no popups — driven by inspector fields / actions) ─────────
  async function applyValue(ref, value) {
    try { await api("POST", `/api/edit-value/${DESIGN}`, { ref, value, srcOff: srcByRef(ref) }); toast(`${ref} = ${value}`); await refetch(); }
    catch (err) { toast("Edit failed: " + err.message, true); }
  }
  async function applyPinNet(ref, pin, net) {
    try { await api("POST", `/api/rewire-pin/${DESIGN}`, { ref, pin, net, srcOff: srcByRef(ref) }); toast(`${ref}.${pin} → ${net}`); await refetch(); }
    catch (err) { toast("Rewire failed: " + err.message, true); }
  }
  async function doCopy(ref) {
    try { await api("POST", `/api/duplicate-instance/${DESIGN}`, { ref, srcOff: srcByRef(ref) }); toast("Pasted a copy of " + ref); await refetch(); }
    catch (err) { toast("Copy failed: " + err.message, true); }
  }
  function editSelected() { if (selection || hotNet) focusInspectorPrimary(); else toast("Click a part or net first.", true); }
  async function deleteSelected() {
    if (!selection) { toast("Select a component first (click it).", true); return; }
    if (!deleteArmed) { deleteArmed = true; renderInspector(); toast("Press Del again (or click Confirm) to remove " + selection.ref); return; }
    const ref = selection.ref;
    try { await api("POST", `/api/remove-instance/${DESIGN}`, { ref, srcOff: srcByRef(ref) }); toast(`Removed ${ref}`); selection = null; deleteArmed = false; renderInspector(); await refetch(); }
    catch (err) { toast("Remove failed: " + err.message, true); deleteArmed = false; renderInspector(); }
  }

  // ── Copy / paste ─────────────────────────────────────────────────────
  // Copy remembers the selected part by its stable source offset; paste clones
  // it server-side (exact duplicate — same value/pins/binding, fresh ref + id),
  // so an identical cap on the same rail merges into "2× …", and a part on a
  // shared net keeps its hub binding. Drag the copy elsewhere to rewire it.
  function copySelected() {
    if (!selection) { toast("Select a component first (click it).", true); return; }
    clip = { ref: selection.ref, src: srcByRef(selection.ref) };
    toast("Copied " + selection.ref + " — Ctrl+V to paste");
  }
  async function pasteClip() {
    if (!clip) { toast("Nothing to paste (select a part, then Ctrl+C).", true); return; }
    try { await api("POST", `/api/duplicate-instance/${DESIGN}`, { ref: clip.ref, srcOff: clip.src }); toast("Pasted a copy of " + clip.ref); await refetch(); }
    catch (err) { toast("Paste failed: " + err.message, true); }
  }

  // ── Add component (A) ────────────────────────────────────────────────
  async function openAdd() {
    if (!libIndex) { try { libIndex = await api("GET", "/api/lib-index"); } catch (e) { libIndex = { components: [], modules: [] }; } }
    const sheetName = activeSheet >= 0 && scene.sections[activeSheet] ? scene.sections[activeSheet].name : "";
    const ov = document.createElement("div");
    ov.className = "ed-overlay"; ov.id = "ed-add";
    ov.innerHTML = `
      <div class="ed-modal" role="dialog">
        <h2>Add component</h2>
        <p class="sub">Inserts an (instance …) into the source, then rebuilds. <span style="opacity:.7">↑↓ to navigate · Enter to select.</span></p>
        <input id="add-search" placeholder="Search library (cap-0402, res-0805, a module…)" autocomplete="off">
        <div class="ed-results" id="add-results"></div>
        <div id="add-form" hidden>
          <div class="row">
            <div><label>Value</label><input id="add-value" placeholder="100nF"></div>
            <div><label>Ref-des (optional)</label><input id="add-ref" placeholder="auto"></div>
          </div>
          <label>Sheet / section</label>
          <select id="add-section"></select>
          <label>Pin → net</label>
          <div class="ed-pinrows" id="add-pins"></div>
          <button class="ed-btn" id="add-pin-more" type="button">+ pin</button>
          <p class="ed-mini" id="add-chosen"></p>
        </div>
        <div class="ed-actions">
          <button class="ed-btn" id="add-cancel" type="button">Cancel</button>
          <button class="ed-btn primary" id="add-go" type="button" disabled>Add</button>
        </div>
      </div>`;
    document.body.appendChild(ov);
    ov.addEventListener("mousedown", (e) => { if (e.target === ov) ov.remove(); });

    const sectionSel = ov.querySelector("#add-section");
    scene.sections.forEach((s) => { const o = document.createElement("option"); o.value = s.name; o.textContent = s.name; if (s.name === sheetName) o.selected = true; sectionSel.appendChild(o); });
    const rootOpt = document.createElement("option"); rootOpt.value = ""; rootOpt.textContent = "(design root)"; sectionSel.appendChild(rootOpt);

    const pinsBox = ov.querySelector("#add-pins");
    function addPinRow(pn, net) {
      const row = document.createElement("div"); row.className = "ed-pinrow";
      row.innerHTML = '<input class="pn" placeholder="pin#"><input placeholder="net">';
      if (pn) row.children[0].value = pn; if (net) row.children[1].value = net;
      pinsBox.appendChild(row);
    }
    addPinRow("1", ""); addPinRow("2", "GND");
    ov.querySelector("#add-pin-more").onclick = () => addPinRow();

    let chosen = null, hiIdx = -1;
    const results = ov.querySelector("#add-results"), search = ov.querySelector("#add-search"), form = ov.querySelector("#add-form"), goBtn = ov.querySelector("#add-go");
    const rows = () => [...results.children];
    // Move the keyboard cursor (highlighted row) without committing a choice.
    function setCursor(i) {
      const rs = rows(); if (!rs.length) { hiIdx = -1; return; }
      hiIdx = Math.max(0, Math.min(i, rs.length - 1));
      rs.forEach((r, j) => r.classList.toggle("hi", j === hiIdx));
      rs[hiIdx].scrollIntoView({ block: "nearest" });
    }
    // Commit a row → reveal the detail form (same as clicking it).
    function selectResult(d) {
      if (!d) return;
      chosen = { name: d.dataset.name, kind: d.dataset.kind };
      setCursor(rows().indexOf(d));
      form.hidden = false; goBtn.disabled = false;
      ov.querySelector("#add-chosen").textContent = (chosen.kind === "module" ? "module " : "") + chosen.name;
    }
    function renderResults(q) {
      q = (q || "").toLowerCase();
      results.innerHTML = "";
      (libIndex.components || []).filter((c) => !q || c.name.toLowerCase().includes(q)).slice(0, 40).forEach((c) => addResult(c.name, c.family ? "family" : "part", c.footprint || "", "component"));
      (libIndex.modules || []).filter((m) => !q || m.name.toLowerCase().includes(q)).slice(0, 20).forEach((m) => addResult(m.name, "module", m.params || "", "module"));
      setCursor(0);                                   // highlight the top match so Enter picks it
    }
    function addResult(name, badge, fp, kind) {
      const d = document.createElement("div"); d.className = "ed-result";
      d.dataset.name = name; d.dataset.kind = kind;
      d.innerHTML = `<span class="badge ${badge === "module" ? "module" : ""}">${badge}</span><span class="nm"></span><span class="fp"></span>`;
      d.querySelector(".nm").textContent = name; d.querySelector(".fp").textContent = fp;
      d.onclick = () => selectResult(d);
      results.appendChild(d);
    }
    renderResults("");
    search.addEventListener("input", () => renderResults(search.value));
    // Arrow keys move the cursor through results; Enter picks it and jumps to Value.
    search.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown") { e.preventDefault(); setCursor(hiIdx + 1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); setCursor(hiIdx - 1); }
      else if (e.key === "Enter") { e.preventDefault(); const r = rows()[hiIdx]; if (r) { selectResult(r); ov.querySelector("#add-value").focus(); } }
    });
    // In the detail fields, Enter submits (so the whole flow is keyboard-only).
    ["#add-value", "#add-ref"].forEach((sel) => ov.querySelector(sel).addEventListener("keydown", (e) => { if (e.key === "Enter" && chosen) { e.preventDefault(); goBtn.click(); } }));
    search.focus();

    ov.querySelector("#add-cancel").onclick = () => ov.remove();
    goBtn.onclick = async () => {
      if (!chosen) return;
      const value = ov.querySelector("#add-value").value.trim(), ref = ov.querySelector("#add-ref").value.trim(), section = sectionSel.value;
      const pins = {};
      [...pinsBox.children].forEach((row) => { const pn = row.children[0].value.trim(), net = row.children[1].value.trim(); if (pn && net) pins[pn] = net; });
      const body = chosen.kind === "module" ? { kind: "module", component: chosen.name, name: chosen.name, args: value, import: true } : { component: chosen.name, value, section, ref: ref || undefined, pins, import: true };
      goBtn.disabled = true; goBtn.textContent = "Adding…";
      try { await api("POST", `/api/add-instance/${DESIGN}`, body); toast("Added " + chosen.name); ov.remove(); await refetch(); }
      catch (err) { toast("Add failed: " + err.message, true); goBtn.disabled = false; goBtn.textContent = "Add"; }
    };
  }

  // ── Cheat sheet ──────────────────────────────────────────────────────
  function toggleKeys() {
    const ex = document.getElementById("ed-keys"); if (ex) { ex.remove(); return; }
    const ov = document.createElement("div"); ov.className = "ed-overlay"; ov.id = "ed-keys";
    ov.innerHTML = `<div class="ed-modal"><h2>Keyboard &amp; mouse</h2><table class="ed-keytable">
      <tr><td><b>drag</b> a part/pin</td><td>Move it onto a net/pin to connect — drops onto a target write the wire, then the layout re-snaps. Drop a cap on a hub pin and it's pinned to that pin (a <code>(decouples …)</code> binding) so it stays there. Drop on empty → springs back. No positions are stored.</td></tr>
      <tr><td><kbd>A</kbd></td><td>Add component (to the current sheet)</td></tr>
      <tr><td><kbd>E</kbd></td><td>Jump to the inspector's first field (edit value / net name)</td></tr>
      <tr><td><kbd>Ctrl/⌘</kbd>+<kbd>C</kbd> / <kbd>V</kbd></td><td>Copy the selected component, then paste a duplicate (same value/pins, fresh ref). Drag the copy to rewire it.</td></tr>
      <tr><td><kbd>Del</kbd> / <kbd>⌫</kbd></td><td>Remove selected component</td></tr>
      <tr><td><kbd>1</kbd>–<kbd>9</kbd></td><td>Jump to sheet · <kbd>0</kbd> whole board</td></tr>
      <tr><td><kbd>[</kbd> <kbd>]</kbd></td><td>Previous / next sheet</td></tr>
      <tr><td><kbd>F</kbd></td><td>Fit current sheet / board</td></tr>
      <tr><td><kbd>Esc</kbd></td><td>Deselect / close</td></tr>
      <tr><td>click part / net</td><td>Show its properties in the left inspector (edit value, rename net, rewire pins, copy, delete)</td></tr>
      <tr><td><b>double-click</b></td><td>Select it and jump straight to the first editable field in the inspector</td></tr>
      <tr><td>scroll · drag empty</td><td>Zoom · pan</td></tr>
      </table><div class="ed-actions"><button class="ed-btn" id="keys-close">Close</button></div></div>`;
    document.body.appendChild(ov);
    ov.addEventListener("mousedown", (e) => { if (e.target === ov) ov.remove(); });
    ov.querySelector("#keys-close").onclick = () => ov.remove();
  }

  // ── Keyboard ─────────────────────────────────────────────────────────
  document.addEventListener("keydown", (e) => {
    const typing = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement && document.activeElement.tagName);
    if (typing) { if (e.key === "Escape") document.activeElement.blur(); return; }
    if (document.querySelector(".ed-overlay")) { if (e.key === "Escape") document.querySelector(".ed-overlay").remove(); return; }
    if (e.ctrlKey || e.metaKey) {
      if (e.key === "c" || e.key === "C") { copySelected(); return; }
      if (e.key === "v" || e.key === "V") { e.preventDefault(); pasteClip(); return; }
      return; // leave other shortcuts (Ctrl+R reload, devtools, …) to the browser
    }
    switch (e.key) {
      case "a": case "A": e.preventDefault(); openAdd(); break;
      case "e": case "E": editSelected(); break;
      case "Delete": case "Backspace": e.preventDefault(); deleteSelected(); break;
      case "f": case "F": if (activeSheet >= 0) selectSheet(activeSheet); else fitAll(); break;
      case "?": toggleKeys(); break;
      case "Escape": deselect(); break;
      case "[": stepSheet(-1); break;
      case "]": stepSheet(1); break;
      case "0": fitAll(); break;
      default: if (e.key >= "1" && e.key <= "9") { const i = +e.key - 1; if (scene.sections[i]) selectSheet(i); }
    }
  });

  // ── Toolbar ──────────────────────────────────────────────────────────
  const tools = document.createElement("div");
  tools.id = "ed-tools";
  tools.innerHTML = `<button id="tool-add" title="Add (A)">+ Add</button><button id="tool-fit" title="Fit (F)">Fit</button><button id="tool-keys" title="Keys (?)">?</button>`;
  wrap.appendChild(tools);
  tools.querySelector("#tool-add").onclick = openAdd;
  tools.querySelector("#tool-fit").onclick = () => { if (activeSheet >= 0) selectSheet(activeSheet); else fitAll(); };
  tools.querySelector("#tool-keys").onclick = toggleKeys;
  isoBox.addEventListener("change", scheduleDraw);

  // ── Refetch / live reload ────────────────────────────────────────────
  function rebuildScene() { buildModel(); buildSheetList(); renderInspector(); scheduleDraw(); }
  async function refetch() {
    try {
      const data = await api("GET", `/api/editor-scene/${DESIGN}`);
      if (data && data.error) { toast("Reload: " + data.error, true); return; }
      scene = data; rebuildScene();
      try { const v = await api("GET", `/api/version/${DESIGN}`); if (v && typeof v.version === "number") lastVersion = v.version; } catch (e) {}
      updateStatus();
    } catch (err) { toast("Reload failed: " + err.message, true); }
  }
  setInterval(async () => {
    try { const v = await api("GET", `/api/version/${DESIGN}`); if (v && typeof v.version === "number" && v.version !== lastVersion) { lastVersion = v.version; await refetch(); } } catch (e) {}
  }, 1500);

  // ── Boot ─────────────────────────────────────────────────────────────
  new ResizeObserver(sizeCanvas).observe(wrap);
  sizeCanvas();
  rebuildScene();
  requestAnimationFrame(() => { fitAll(); updateStatus(); requestAnimationFrame(frame); });
})();
