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
    wire: "#4d9375", bus: "#6fb38d", hot: "#f0c674", link: "#6ea8fe",
    labelNet: "#79c0ff", labelGnd: "#8b949e", labelPort: "#d2a8ff",
    sel: "#f0883e", snap: "#f0883e", band: "#f0c674",
    ghost: "#161c26", ghostStroke: "#3d5573", ghostLabel: "#7d9bc1",
    diff: "#c792ea",
    rail: "#e3b341", railGnd: "#768390",   // power-layer rail nodes (power / ground)
  };
  const GRID = 60; // spatial-hash cell size (world units)
  const NODE_W = 72; // power-layer rail-node pill width (shared by layout + draw)
  const SPOKE_SYM = 22; // side-spoke passive symbol length (shared by map layout + draw + hit-test)

  // ── State ────────────────────────────────────────────────────────────
  let cam = { x: 0, y: 0, w: 1000, h: 800 };
  let M = null;                  // built scene model
  let activeSheet = -1;          // -1 = whole board
  let selection = null;          // {kind:'hub'|'pass', ref}
  let hotNet = null;
  let clip = null;               // copy/paste clipboard: {ref, src}
  let showNets = true;           // draw device↔device net connections (vs name labels)
  let ghostRef = null;           // IC focused for "ghost partner" fan-out (null = off)
  let ghostAll = true;           // the connection map IS the editing surface — on by default, sticky
  let showPower = false;         // map power layer: overlay each IC cell's power/ground rail nodes
  let fullMap = false;           // full connection map: the whole netlist as one force-directed graph
  let sheets = [];               // navigable pages: design (group …) lists, else per-section
  let deleteArmed = false;       // inspector Delete needs a 2nd click to confirm
  let libIndex = null;
  let dirty = true, springBack = null;
  const stagePos = {};           // staged-part identity (src offset) -> {x,y} world position
  let firstBuild = true;
  let ercData = [];              // latest /api/erc violations
  let ercByRef = new Map();     // ref  -> worst severity ("err"|"warning") for canvas highlight
  let ercByNet = new Map();     // net  -> worst severity                    "
  let ercOpen = false;          // violations panel visible

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
    if (M) {
      const p = M.passes.find((x) => x.ref === ref); if (p && p.src) return p.src;
      const h = M.hubs.find((x) => x.ref === ref); if (h && h.src) return h.src;
    }
    // The global map clears M.passes and synthesises src-less hubs, so resolve the
    // source offset straight from the scene (passives / staged / hubs all carry it).
    const sp = scene.passives.find((x) => x.ref === ref) || (scene.staged || []).find((x) => x.ref === ref) || scene.hubs.find((x) => x.ref === ref);
    return sp && sp.src ? sp.src : 0;
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
      m.hubs.push({ ref: h.ref, src: h.src || 0, component: h.component || "", x: h.x, y: h.y, w: h.w, h: h.h, label: h.label || h.ref, cx: h.x + h.w / 2, cy: h.y + h.h / 2, pins });
    });
    // Draw real connections instead of a matching net label at each end:
    // same-IC passive bridges first (so the now-local pads aren't then taken for
    // a cross-device link), then inter-device channel wires. (Skipped in the
    // global map, which throws the real layout away for a fresh grid.)
    if (showNets && !ghostAll && !fullMap) { bridgeSamePins(m); connectHubs(m); }
    // Ghost-partner fan-out: ring one IC with dashed proxies of the ICs it
    // connects point-to-point to (ghostRef), rebuild the board as a grid of
    // self-contained per-IC cells (ghostAll), or rebuild the WHOLE netlist as one
    // force-directed connectivity graph — every part + every net (fullMap).
    if (ghostAll) buildGlobalMap(m);
    else if (fullMap) buildFullMap(m);
    else if (ghostRef) ghostPartners(m);
    // Connection ports for snap (net-bearing): pins, labels, wire vertices.
    // Ghost proxies are view-only — exclude them from snap targets.
    m.hubs.forEach((h) => { if (h.ghost) return; h.pins.forEach((p) => { if (p.net) addPort(m, p.x, p.y, p.net, "pin", h.ref, p.pin); }); });
    m.labels.forEach((l) => { if (l.net) addPort(m, l.x, l.y, l.net, "label"); });
    m.wires.forEach((w) => { if (w.net) w.pts.forEach((p) => addPort(m, p[0], p[1], w.net, "wire")); });
    if (!ghostAll && !fullMap) addStaged(m);
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
    // `net` is the wire-geometry-derived net the base view already uses; `anet` is the
    // pin's authoritative net from the scene (present for label-rendered power/ground
    // pins that have no wire) — read by the power layer, leaves base-view logic alone.
    pins.push({ pin: (pn.pins || "").split(",")[0], pins: pn.pins || "", name: pn.name || pn.pins, side, x: ex, y: pn.y, net: v ? v.net : "", anet: pn.net || "", vx: v ? v.x : null, vy: v ? v.y : null });
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
    if ((ghostAll || fullMap) && M.mapBox) fitTo(M.mapBox, 0.03);
    else fitTo({ x: 0, y: 0, w: scene.viewBox.w, h: scene.viewBox.h }, 0.03);
    syncSheetUI(); updateStatus();
  }
  // Frame a target from ?focus=<v> (or #<v>): a hub ref (U18), a net (LO1_DRIVE), or a
  // chain key (LO1 → every hub the chain touches, so a whole chain fills the view). So a
  // URL opens the editor pointed exactly where you want, no buttons or keys. Returns
  // whether anything matched.
  function focusTarget(val) {
    const w = String(val || "").trim().toLowerCase(); if (!w) return false;
    const reals = (M.hubs || []).filter((h) => !h.ghost);
    let hit = reals.filter((h) => h.ref.toLowerCase() === w || (h.ref.split("/").pop() || "").toLowerCase() === w || String(h.label || "").toLowerCase() === w);
    if (!hit.length) hit = reals.filter((h) => (h.pins || []).some((p) => p.net && (p.net.toLowerCase() === w || chainKey(p.net).toLowerCase() === w)));
    if (!hit.length) return false;
    // Frame each match's whole CELL (the sec box that holds its inline chain + ghost
    // partners), not just the IC body — so a focused chain shows end to end.
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    hit.forEach((h) => {
      const sec = (M.secs || []).find((s) => h.cx >= s.x && h.cx <= s.x + s.w && h.cy >= s.y && h.cy <= s.y + s.h);
      const b = sec || h;
      x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h);
    });
    fitTo({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 }, 0.08);
    return true;
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
    const aSheet = activeSheet >= 0 ? sheets[activeSheet] : null;
    const gbox = M.ghostBox;                          // ghost focus dims everything else
    const iso = gbox ? true : (isoBox.checked && aSheet && aSheet.box);
    const sec = gbox ? gbox : (iso ? aSheet.box : null);
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

    // Sections (dashed structure boxes) — dim those outside the active sheet.
    M.secs.forEach((sc) => {
      if (!boxVis(sc.x, sc.y, sc.x + sc.w, sc.y + sc.h)) return;
      ctx.globalAlpha = (iso && !inBox(sc.cx, sc.cy)) ? 0.12 : 1;
      ctx.strokeStyle = C.secStroke;
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
      ctx.globalAlpha = drag ? dimW : (w.link ? 1 : (inBox(mid[0], mid[1]) ? 1 : 0.12));
      if (w.via && !hot) {                             // in-line element in the path: leads + symbol/chip
        const dev = w.via.device, half = dev ? 16 : 11;
        const p0 = w.pts[0], p1 = w.pts[w.pts.length - 1], yy = p0[1], cxw = (p0[0] + p1[0]) / 2;
        ctx.strokeStyle = w.diff ? C.diff : C.link; ctx.lineWidth = sw(w.diff ? 1.5 : 1.6);
        ctx.beginPath(); ctx.moveTo(p0[0], yy); ctx.lineTo(cxw - half, yy); ctx.moveTo(cxw + half, yy); ctx.lineTo(p1[0], yy); ctx.stroke();
        if (dev) {                                      // pass-through device (level shifter): a filled chip
          const amp = half * 0.5; ctx.fillStyle = C.ghost; ctx.strokeStyle = C.ghostStroke; ctx.lineWidth = sw(1.6);
          roundRect(cxw - half, yy - amp, 2 * half, 2 * amp, sw(2)); ctx.fill(); ctx.stroke();
        } else {
          ctx.strokeStyle = C.passStroke; ctx.lineWidth = sw(1.5);
          symbol(w.via.type || "box", cxw - half, cxw + half, yy, sw);
        }
        return;
      }
      if (w.diff && !hot) {                            // differential pair: coupled twin lines
        ctx.strokeStyle = C.diff; ctx.lineWidth = sw(1.5);
        const off = sw(1.9);
        for (const d of [-off, off]) {
          ctx.beginPath();
          for (let i = 0; i < w.pts.length; i++) { const n = segNormal(w.pts, i); const x = w.pts[i][0] + n[0] * d, y = w.pts[i][1] + n[1] * d; i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
          ctx.stroke();
        }
        return;
      }
      ctx.strokeStyle = hot ? C.hot : (w.link ? C.link : (w.bus ? C.bus : C.wire));
      ctx.lineWidth = sw(hot ? 2.4 : (w.link ? 1.8 : (w.bus ? 3 : 1.5)));
      ctx.beginPath(); ctx.moveTo(w.pts[0][0], w.pts[0][1]);
      for (let i = 1; i < w.pts.length; i++) ctx.lineTo(w.pts[i][0], w.pts[i][1]);
      ctx.stroke();
    });
    ctx.globalAlpha = 1;
    // Full-map edges: every pin-on-net as a thin line from its component to the net
    // node. Power/ground edges are faded so the signal graph stays legible; the hot
    // net (if any) is solid and on top.
    (M.fullEdges || []).forEach((e) => {
      if (!boxVis(Math.min(e.x1, e.x2), Math.min(e.y1, e.y2), Math.max(e.x1, e.x2), Math.max(e.y1, e.y2))) return;
      const hot = hotNet && e.net === hotNet;
      ctx.globalAlpha = hot ? 1 : (e.pwr ? 0.14 : 0.45);
      ctx.strokeStyle = hot ? C.hot : (e.pwr ? C.rail : C.link);
      ctx.lineWidth = sw(hot ? 1.8 : 0.9);
      line(e.x1, e.y1, e.x2, e.y2);
    });
    ctx.globalAlpha = 1;
    // Passive branches hanging off a mapped net: the passive's symbol (resistor /
    // capacitor / inductor / …), then its far terminal — a ground symbol (decoupling
    // cap → GND), a rail bar + name (bypass / pull-up to a supply), or a short stub +
    // net name (a series element to another signal). A pull-up on a partner wire hangs
    // BELOW it (vertical); an extra-pin spoke fans OUT to the IC's side (horizontal,
    // axis "h") with the symbol inline and the terminal at the outboard end. (Plain pull
    // items carry no type/term, so they default to a resistor → rail-or-ground.)
    (M.pulls || []).forEach((p) => {
      if (!ptVis(p.x, p.y)) return;
      const txt = 15 * s >= 7;
      const type = p.type || "resistor", term = p.term || (p.up ? "rail" : "gnd");
      if (p.axis === "h") {                                          // side spoke: symbol inline on a horizontal wire
        const dir = p.dir || 1, y = p.y;
        const sA = p.x - SPOKE_SYM / 2, sB = p.x + SPOKE_SYM / 2;
        const jx = p.jx != null ? p.jx : (dir > 0 ? sA - 8 : sB + 8), tx = p.tx != null ? p.tx : (dir > 0 ? sB + 14 : sA - 14);
        ctx.strokeStyle = C.passStroke; ctx.lineWidth = sw(1.4);
        line(jx, y, dir > 0 ? sA : sB, y); line(dir > 0 ? sB : sA, y, tx, y);   // lead-in + lead-out
        symbol(type, sA, sB, y, sw);                                 // passive drawn ALONG the spoke
        if (txt) { const cap = p.value || p.ref || ""; ctx.fillStyle = C.passText; ctx.font = "10px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "bottom"; ctx.fillText(cap.length > 9 ? cap.slice(0, 8) + "…" : cap, p.x, y - 7); ctx.textBaseline = "middle"; }
        if (term === "rail") {                                       // supply: a perpendicular rail bar + name
          ctx.strokeStyle = C.passStroke; ctx.lineWidth = sw(1.6); line(tx, y - 5, tx, y + 5);
          if (txt) { ctx.fillStyle = C.labelNet; ctx.font = "10px sans-serif"; ctx.textAlign = dir > 0 ? "left" : "right"; ctx.textBaseline = "middle"; ctx.fillText("▲ " + p.rail, tx + dir * 5, y); }
        } else if (term === "net") {                                 // series to another signal net: name at the end
          if (txt) { ctx.fillStyle = C.labelNet; ctx.font = "10px sans-serif"; ctx.textAlign = dir > 0 ? "left" : "right"; ctx.textBaseline = "middle"; ctx.fillText(p.rail, tx + dir * 4, y); }
        } else {                                                     // ground rake at the spoke end (points down, as in the schematic)
          drawGround(tx, y, false, sw, txt && !/^gnd$/i.test(p.rail || ""), p.rail || "");
        }
        return;
      }
      const x = p.x, y0 = p.y + 4, yb = y0 + 14, yend = yb + 6;
      ctx.strokeStyle = C.passStroke; ctx.lineWidth = sw(1.4);
      line(x, p.y, x, y0); line(x, yb, x, yend);
      ctx.save(); ctx.translate(x, (y0 + yb) / 2); ctx.rotate(Math.PI / 2); symbol(type, -7, 7, 0, sw); ctx.restore();
      // value-only caption (e.g. "100nF", "2× 10uF"), like the standard editor — the
      // ref is one click away in the inspector. Truncated so it can't run into a neighbour.
      if (txt) { const cap = p.value || p.ref || ""; ctx.fillStyle = C.passText; ctx.font = "10px sans-serif"; ctx.textAlign = "left"; ctx.textBaseline = "middle"; ctx.fillText(cap.length > 9 ? cap.slice(0, 8) + "…" : cap, x + 8, (y0 + yb) / 2); }
      if (term === "rail") {                                       // to a supply: rail bar + name
        ctx.strokeStyle = C.passStroke; ctx.lineWidth = sw(1.6); line(x - 5, yend, x + 5, yend);
        if (txt) { ctx.fillStyle = C.labelNet; ctx.font = "10px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "top"; ctx.fillText("▲ " + p.rail, x, yend + 2); }
      } else if (term === "net") {                                 // series to another signal net: stub + net name
        ctx.strokeStyle = C.passStroke; ctx.lineWidth = sw(1.4); line(x, yend, x, yend + 5);
        if (txt) { ctx.fillStyle = C.labelNet; ctx.font = "10px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "top"; ctx.fillText(p.rail, x, yend + 7); }
      } else {                                                     // to ground (caption only for a named ground — the rake already says GND)
        drawGround(x, yend, false, sw, txt && !/^gnd$/i.test(p.rail || ""), p.rail || "");
      }
    });
    ctx.globalAlpha = 1; ctx.textBaseline = "middle";

    // Full-map net nodes: a dot per net (amber = power/ground, purple = boundary
    // port, blue = signal). Its name is drawn just above by the labels pass.
    (M.netNodes || []).forEach((n) => {
      if (!ptVis(n.x, n.y)) return;
      const hot = hotNet && n.net === hotNet;
      const col = hot ? C.hot : n.port ? C.labelPort : n.pwr ? C.rail : C.labelNet;
      const r = sw(n.pwr ? 4.5 : 3.2);
      ctx.beginPath(); ctx.arc(n.x, n.y, hot ? r * 1.6 : r, 0, 7);
      ctx.fillStyle = col; ctx.fill();
    });
    // Full-map local-net flags: power/ground/high-fanout net names tucked beneath each
    // member part (these nets stay out of the wired graph). Hidden when far zoomed out.
    if (11 * s >= 7) (M.flags || []).forEach((fl) => {
      if (!ptVis(fl.x, fl.y)) return;
      const hot = hotNet && fl.net === hotNet;
      ctx.fillStyle = hot ? C.hot : fl.port ? C.labelPort : fl.pwr ? C.rail : C.labelNet;
      ctx.font = "10px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
      const t = (fl.gnd ? "⏚ " : fl.pwr ? "▲ " : "") + netLeaf(fl.net);
      ctx.fillText(t.length > 14 ? t.slice(0, 13) + "…" : t, fl.x, fl.y);
    });
    ctx.textBaseline = "middle";

    // Labels — net-name stubs / ports as text; grounds as a real earth symbol
    // (node dot on the wire, rake pointing down, caption below). The symbol
    // draws at any zoom; only its caption obeys the LOD text cutoff.
    {
      const showText = 11 * s >= 7;
      ctx.font = "11px sans-serif";
      M.labels.forEach((l) => {
        if (!ptVis(l.x, l.y)) return;
        ctx.globalAlpha = (l.link || inBox(l.x, l.y)) ? 1 : 0.12;
        const hot = hotNet && l.net === hotNet;
        if (l.ground) { drawGround(l.x, l.y, hot, sw, showText, l.text); return; }
        if (!showText) return;
        const lev = ercByNet.get(l.net);                            // ERC-flagged net → tint its label
        ctx.fillStyle = hot ? C.hot : lev ? ercColor(lev) : l.diff ? C.diff : l.link ? C.link : l.port ? C.labelPort : C.labelNet;
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
      if (p.vertical) { drawVertPass(p, ox, oy, sw, s, inBox); return; }
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
      // body — a ghost proxy is dashed + muted so it reads as a reference, not a real placement
      const seldHub = selection && selection.ref === h.ref;
      ctx.fillStyle = h.ghost ? C.ghost : C.hub;
      ctx.strokeStyle = seldHub ? C.sel : (h.ghost ? C.ghostStroke : C.hubStroke);
      ctx.lineWidth = sw(seldHub ? 3 : 2);
      if (h.ghost) ctx.setLineDash([sw(6), sw(4)]);
      roundRect(h.x + ox, h.y + oy, h.w, h.h, sw(4)); ctx.fill(); ctx.stroke();
      ctx.setLineDash([]);
      const ev = h.terminal ? null : ercByRef.get(h.ref);            // ERC warning ring
      if (ev) { ctx.strokeStyle = ercColor(ev); ctx.lineWidth = sw(2); ctx.setLineDash([sw(3), sw(3)]); roundRect(h.x + ox - 3, h.y + oy - 3, h.w + 6, h.h + 6, sw(5)); ctx.stroke(); ctx.setLineDash([]); }
      if (15 * s >= 8) {
        ctx.fillStyle = h.ghost ? C.ghostLabel : C.hubLabel; ctx.font = "600 15px sans-serif"; ctx.textAlign = "center";
        // The ↗ marks a click-to-jump link (fan-out only); map proxies edit in place.
        ctx.fillText((h.ghost && !ghostAll ? "↗ " : "") + h.label, h.cx + ox, h.y + oy + (h.part ? 15 : 16));
        if (h.part && 11 * s >= 7) {                    // second line: the component / part number
          ctx.fillStyle = C.pinName; ctx.font = "11px sans-serif";
          const maxc = Math.max(4, Math.floor((h.w - 14) / 6.2));
          ctx.fillText(h.part.length > maxc ? h.part.slice(0, maxc - 1) + "…" : h.part, h.cx + ox, h.y + oy + 30);
        }
      }
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

    // Power layer (P): each IC card's power/ground rail nodes, in a reserved strip
    // along the card's lower edge. Drawn AFTER the cards — they live in the card's
    // lower band, which the opaque hub fill would otherwise paint over. One pill per
    // rail (▲ supply / ⏚ ground), ⎓N badging its decoupling-cap count; click a node
    // to select the net so the inspector lists/edits its decoupling. Map-only.
    (M.rails || []).forEach((r) => {
      if (!ptVis(r.x, r.y)) return;
      const w = NODE_W, h = 20, x0 = r.x - w / 2, y0 = r.y - h / 2, txt = 11 * s >= 7;
      const hot = hotNet && r.net === hotNet, col = hot ? C.hot : (r.up ? C.rail : C.railGnd);
      ctx.globalAlpha = 0.16; ctx.fillStyle = col; roundRect(x0, y0, w, h, sw(4)); ctx.fill(); ctx.globalAlpha = 1;
      ctx.strokeStyle = col; ctx.lineWidth = sw(hot ? 2 : 1.2); roundRect(x0, y0, w, h, sw(4)); ctx.stroke();
      if (txt) {
        ctx.fillStyle = col; ctx.font = "600 11px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
        const lbl = (r.up ? "▲ " : "⏚ ") + netLeaf(r.net) + (r.decoup ? "  ⎓" + r.decoup : "");
        ctx.fillText(lbl.length > 15 ? lbl.slice(0, 14) + "…" : lbl, r.x, r.y);
      }
    });
    ctx.globalAlpha = 1; ctx.textBaseline = "middle";

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

  // A bridged passive standing vertically between its two pads: rotate the
  // horizontal symbol 90° about its centre, dot the two terminals, caption to
  // the outboard side.
  function drawVertPass(p, ox, oy, sw, s, inBox) {
    const xl = p.xline + ox, len = (p.y1 - p.y0), cy = p.cy + oy;
    const seld = selection && selection.ref === p.ref;
    ctx.globalAlpha = inBox(p.cx, p.cy) ? 1 : 0.12;
    ctx.strokeStyle = seld ? C.sel : C.passStroke; ctx.lineWidth = sw(seld ? 2.2 : 1.5);
    ctx.save(); ctx.translate(xl, cy); ctx.rotate(Math.PI / 2);
    if (p.type === "box") { const amp = Math.min(6, len * 0.22); ctx.fillStyle = C.pass; roundRect(-len / 2, -amp, len, 2 * amp, sw(3)); ctx.fill(); ctx.stroke(); }
    else symbol(p.type, -len / 2, len / 2, 0, sw);
    ctx.restore();
    for (const t of p.term) {
      const hot = hotNet && t.net === hotNet;
      ctx.beginPath(); ctx.arc(t.x + ox, t.y + oy, sw(3.5), 0, 7);
      ctx.fillStyle = hot ? C.hot : C.pin; ctx.strokeStyle = hot ? C.hot : C.pinStroke; ctx.lineWidth = sw(1); ctx.fill(); ctx.stroke();
    }
    if (11 * s >= 7) {
      ctx.fillStyle = C.passText; ctx.font = "11px sans-serif";
      ctx.textAlign = p.dir < 0 ? "end" : "start"; ctx.textBaseline = "middle";
      ctx.fillText(p.label.length > 14 ? p.label.slice(0, 13) + "…" : p.label, xl + p.dir * 10, cy);
    }
    ctx.globalAlpha = 1;
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
    for (const h of M.hubs) { if (h.ghost) continue; for (const p of h.pins) if (Math.hypot(p.x - x, p.y - y) < tp) return { t: "pin", ref: h.ref, pin: p.pin, net: p.net, x: p.x, y: p.y }; }
    // In-line passives on the map are small precise targets — a series symbol riding
    // a link wire's midpoint, a pull resistor hanging just below it — so hit-test them
    // before the big ghost-block areas. Each carries its ref → select + edit like any part.
    for (const w of M.wires) { if (!w.via || !w.via.ref) continue; const p0 = w.pts[0], p1 = w.pts[w.pts.length - 1], mx = (p0[0] + p1[0]) / 2, my = p0[1]; if (Math.abs(x - mx) < 16 + tw && Math.abs(y - my) < 11 + tw) return { t: "part", ref: w.via.ref, kind: "pass" }; }
    for (const p of (M.pulls || [])) {
      if (!p.ref) continue;
      if (p.axis === "h") { if (Math.abs(x - p.x) < SPOKE_SYM / 2 + tw && Math.abs(y - p.y) < 8 + tw) return { t: "part", ref: p.ref, kind: "pass" }; continue; }
      if (Math.abs(x - p.x) < 10 + tw && y >= p.y - tw && y <= p.y + 26 + tw) return { t: "part", ref: p.ref, kind: "pass" };
    }
    // Power-layer rail pills sit inside the IC card's lower band, so test them before
    // the card area below (which would otherwise swallow the click as the IC itself).
    for (const r of (M.rails || [])) if (Math.abs(x - r.x) < NODE_W / 2 + tw && Math.abs(y - r.y) < 11 + tw) return { t: "net", net: r.net };
    // Full-map net-node dots: select the net (→ inspector). Tested before the part
    // boxes so a dot sitting under a box edge is still clickable.
    for (const n of (M.netNodes || [])) if (Math.hypot(x - n.x, y - n.y) < (n.pwr ? 6 : 5) + tw) return { t: "net", net: n.net };
    for (const fl of (M.flags || [])) if (Math.abs(x - fl.x) < 38 + tw && Math.abs(y - fl.y) < 7 + tw) return { t: "net", net: fl.net };
    // In the global map a proxy box is a first-class, selectable+editable copy of
    // the real component (click it → inspector, like any part); only the fan-out
    // overlay keeps proxies as click-to-jump links.
    for (const h of M.hubs) if (h.ghost && !h.terminal && x >= h.x && x <= h.x + h.w && y >= h.y && y <= h.y + h.h) return ghostAll ? { t: "part", ref: h.partnerRef || h.ref, kind: "hub" } : { t: "ghost", ref: h.partnerRef };
    for (const h of M.hubs) { if (h.synthetic) continue; if (x >= h.x && x <= h.x + h.w && y >= h.y && y <= h.y + h.h) return { t: "part", ref: h.ref, kind: "hub" }; }
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
      else if (down.hit.t === "part" && startDrag("part", down.hit)) { mode = "drag"; }
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
      else if (h.t === "ghost") jumpToGhost(h.ref);
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
  function deselect() { selection = null; hotNet = null; deleteArmed = false; if (ghostRef || fullMap) { ghostRef = null; fullMap = false; ghostAll = true; buildModel(); syncGhostBtns(); syncFullBtn(); } renderInspector(); updateStatus(); scheduleDraw(); }
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
      // A map-only passive (a series/pull symbol) has no draggable item in the
      // synthesized layout — report failure so the gesture falls back to a pan;
      // a click (no movement) still selects it for the inspector.
      const item = M.hubs.find((h) => h.ref === hit.ref) || M.passes.find((p) => p.ref === hit.ref);
      if (!item) return false;
      const terminals = item.pins ? item.pins.map((p) => ({ ref: hit.ref, pin: p.pin, net: p.net, x: p.x, y: p.y })) : item.term.map((t) => ({ ref: hit.ref, pin: t.pin, net: t.net, x: t.x, y: t.y }));
      drag = { kind: "part", ownerRef: hit.ref, src: item.src || 0, delta: [0, 0], terminals, best: null, staged: !!item.staged, stageKey: String(item.src || item.ref) };
    }
    updateStatus();
    return true;
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
  // Power/ground classification looks at the net's LEAF (after the last "/"): a
  // sub-block-internal rail flattens to a prefixed name (rx1/VREG, rx1/GND) and
  // the prefix would otherwise defeat the ^V / ^GND anchors, so a module's local
  // regulator/ground would read as an ordinary signal (e.g. a 200k *CS pull-up to
  // rx1/VREG would be walked as a series element instead of an ignored stub).
  function netLeaf(n) { const s = String(n || "").trim(); const i = s.lastIndexOf("/"); return i >= 0 ? s.slice(i + 1) : s; }
  function isGroundName(n) { return /^(?:[adpe]?gnd|gnd[adpe]?|vss|ground)\b/i.test(netLeaf(n)); }
  // A power rail (Vdd/Vcc/Vsys/3V3/+5V/AVDD…), excluded from device↔device line
  // drawing along with grounds. A control net like V1/V2 (V + digit) is NOT a
  // rail, so it still gets a connection line.
  function isPowerName(n) { return /^(?:[ad]?v[a-z]|\+?\d+v)/i.test(netLeaf(n)); }
  // Inter-device nets: a net on exactly two hub pins of two different,
  // side-by-side devices (no passive between, not power/ground) is a direct
  // device-to-device connection. Rather than a name label at each end, pull
  // those pins out of their main hub box and re-show them on a new per-device
  // 'group' block (same ref + label, drawn by the normal hub renderer, just
  // like a multi-part component splits into blocks). The two blocks list the
  // shared nets at matching heights, so the wires between them stay level.
  function connectHubs(m) {
    const ends = new Map(), passiveNets = new Set();
    m.passes.forEach((p) => p.term.forEach((t) => { if (t.net) passiveNets.add(t.net); }));
    m.hubs.forEach((h) => h.pins.forEach((p) => {
      if (!p.net || isGroundName(p.net) || isPowerName(p.net)) return;
      let a = ends.get(p.net); if (!a) { a = []; ends.set(p.net, a); }
      a.push({ hub: h, pin: p });
    }));
    const links = [];
    ends.forEach((eps, net) => {
      if (passiveNets.has(net) || eps.length !== 2) return;
      const ah = eps[0].hub, bh = eps[1].hub;
      if (ah === bh) return;
      // Only side-by-side hubs (vertical extents overlap) get a straight channel
      // line. Vertically stacked devices — e.g. an IC over a column of connectors
      // sharing its x — would need fan-out routing to avoid stacking lines on top
      // of each other, so those nets stay as name labels.
      if (!(ah.y < bh.y + bh.h && bh.y < ah.y + ah.h)) return;
      links.push({ net, a: eps[0], b: eps[1] });
    });
    if (!links.length) return;
    const linkPins = new Set(); links.forEach((l) => { linkPins.add(l.a.pin); linkPins.add(l.b.pin); });
    // Drop the per-end name labels + stub wires the layout drew for these nets.
    const linkSet = new Set(links.map((l) => l.net));
    m.wires = m.wires.filter((w) => !linkSet.has(w.net));
    m.labels = m.labels.filter((l) => !linkSet.has(l.net));
    // Pull the tied pins OUT of their main hub box (a multi-part style split):
    // each becomes a pin on a new group block, so the original box no longer
    // carries them.
    m.hubs.forEach((h) => { h.pins = h.pins.filter((p) => !linkPins.has(p)); });
    const PITCH = 26, GAP_Y = 36, LABEL_H = 24, BPAD = 6, SEC_PAD = 28, SEC_GAP = 36;
    // Per hub-pair, build a matched pair of group blocks: one per device, same
    // ref + label + width as the parent (a multi-part block stacked BELOW it with
    // some breathing room), both at a shared y so the wires between them are level.
    const pairs = new Map();
    links.forEach((lk) => { const k = [lk.a.hub.ref, lk.b.hub.ref].sort().join(" "); let g = pairs.get(k); if (!g) { g = []; pairs.set(k, g); } g.push(lk); });
    const placed = [];
    pairs.forEach((group) => {
      group.sort((x, y) => (x.a.pin.y + x.b.pin.y) - (y.a.pin.y + y.b.pin.y));
      const aHub = group[0].a.hub, bHub = group[0].b.hub, aLeft = aHub.cx < bHub.cx;
      const N = group.length, blkH = LABEL_H + N * PITCH + BPAD;
      const bandTop = Math.max(aHub.y + aHub.h, bHub.y + bHub.h) + GAP_Y;
      const aSide = aLeft ? "right" : "left", bSide = aLeft ? "left" : "right";
      const mkBlock = (hub) => ({ ref: hub.ref, src: hub.src || 0, x: hub.x, y: bandTop, w: hub.w, h: blkH, label: hub.label, cx: hub.x + hub.w / 2, cy: bandTop + blkH / 2, pins: [], synthetic: true });
      const ablk = mkBlock(aHub), bblk = mkBlock(bHub);
      const aPinX = aSide === "right" ? aHub.x + aHub.w : aHub.x;
      const bPinX = bSide === "right" ? bHub.x + bHub.w : bHub.x;
      group.forEach((lk, i) => {
        const y = bandTop + LABEL_H + i * PITCH + PITCH / 2;
        ablk.pins.push({ pin: lk.a.pin.pin, name: lk.a.pin.name, side: aSide, x: aPinX, y, net: lk.net, vx: null, vy: null });
        bblk.pins.push({ pin: lk.b.pin.pin, name: lk.b.pin.name, side: bSide, x: bPinX, y, net: lk.net, vx: null, vy: null });
        const pts = [[aPinX, y], [bPinX, y]];
        m.wires.push({ net: lk.net, bus: false, link: true, pts, bb: bbOf(pts) });
        m.labels.push({ text: lk.net, x: (aPinX + bPinX) / 2, y: y - 8, anchor: "center", ground: false, port: false, net: lk.net, link: true });
      });
      m.hubs.push(ablk, bblk);
      placed.push({ block: ablk, hub: aHub }, { block: bblk, hub: bHub });
    });
    if (placed.length) wrapSections(m, placed, SEC_PAD, SEC_GAP);
  }
  // Grow each parent's section box to wrap its group block (same padding the
  // section boxes already use), then shove any lower section + its contents down
  // so the extended box never overlaps the one beneath it.
  function wrapSections(m, placed, SEC_PAD, SEC_GAP) {
    const secOf = (hub) => m.secs.find((sc) => hub.cx >= sc.x && hub.cx <= sc.x + sc.w && hub.cy >= sc.y && hub.cy <= sc.y + sc.h);
    placed.forEach(({ block, hub }) => {
      const sc = secOf(hub); if (!sc) return;
      const need = block.y + block.h + SEC_PAD;
      if (need > sc.y + sc.h) sc.h = need - sc.y;
    });
    const ordered = m.secs.slice().sort((a, b) => a.y - b.y);
    for (let i = 0; i < ordered.length; i++) for (let j = i + 1; j < ordered.length; j++) {
      const A = ordered[i], B = ordered[j];
      if (A.x < B.x + B.w && B.x < A.x + A.w && B.y < A.y + A.h) shiftSection(m, B, A.y + A.h + SEC_GAP - B.y);
    }
    m.secs.forEach((sc) => { if (scene.viewBox) scene.viewBox.h = Math.max(scene.viewBox.h, sc.y + sc.h + 60); });
  }
  // Move a section box + everything spatially inside its column (from its top
  // down) by dy. Link wires/labels span the channel, so they fall outside the
  // single-column x test and stay put.
  function shiftSection(m, sec, dy) {
    if (dy <= 0) return;
    const x0 = sec.x - 1, x1 = sec.x + sec.w + 1, y0 = sec.y;
    const inX = (x) => x >= x0 && x <= x1;
    m.hubs.forEach((h) => { if (!h.synthetic && inX(h.cx) && h.cy >= y0) { h.y += dy; h.cy += dy; h.pins.forEach((p) => { p.y += dy; if (p.vy != null) p.vy += dy; }); } });
    m.passes.forEach((p) => { if (inX(p.cx) && p.cy >= y0) { p.cy += dy; p.top += dy; p.term.forEach((t) => { t.y += dy; }); } });
    m.wires.forEach((w) => { if (w.pts.every((pt) => inX(pt[0]) && pt[1] >= y0)) { w.pts.forEach((pt) => { pt[1] += dy; }); w.bb[1] += dy; w.bb[3] += dy; } });
    m.labels.forEach((l) => { if (inX(l.x) && l.y >= y0) l.y += dy; });
    sec.y += dy; sec.cy += dy;
  }
  function bbOf(pts) { let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9; for (const p of pts) { if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0]; if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1]; } return [x0, y0, x1, y1]; }
  // Unit normal at vertex i of a polyline (for drawing offset twin lines).
  function segNormal(pts, i) { const a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)]; const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1; return [-dy / L, dx / L]; }

  // Differential-pair twin of a net name (ADF_CH5P↔ADF_CH5N, FOO+↔FOO-), or null.
  function diffTwin(n) {
    let m = /^(.*[A-Za-z0-9])([+-])$/.exec(n); if (m) return m[1] + (m[2] === "+" ? "-" : "+");
    m = /^(.*\d)([PN])$/.exec(n); if (m) return m[1] + (m[2] === "P" ? "N" : "P");
    m = /^(.*_)([PN])$/.exec(n); if (m) return m[1] + (m[2] === "P" ? "N" : "P");
    return null;
  }
  // A level-translation channel pairs a net with its voltage-domain twin: the
  // same base signal carried at two rails, named X / X_1V8 (or _3V3, _5V, _2V5…).
  // passBase strips a trailing _<volts> suffix; two nets are a channel pair when
  // they share a base but differ (CS_RX1 ↔ CS_RX1_1V8). This is how a multi-pin
  // pass-through (a TXB0104/TXS0108 level shifter) is recognised on the map: a
  // device carrying both ends of a channel translates that signal through itself.
  function passBase(n) { return n.replace(/_\d+V\d*$/i, ""); }
  function passChannel(a, b) { return a !== b && passBase(a) === passBase(b); }
  // A level translator also names its channel pins A<n> / B<n> (TXB0104, TXS0108,
  // SN74AXC8T245, LSF0108…). The A<n>↔B<n> twin pin id, or null. This recognises a
  // channel even when the nets DON'T follow the voltage-twin convention — e.g. the
  // labstation wires A1=DUT_FIX_A0_3V3, B1=DUT_FIX_A0_MCU (both carry a suffix, so
  // passBase can't pair them). Pad numbers / GPIO names (PA3) never match.
  function pinTwinId(p) { const m = /^([ab])(\d+)$/i.exec(String(p || "")); return m ? (m[1].toUpperCase() === "A" ? "B" : "A") + m[2] : null; }
  // Signal-chain net-naming convention: a chain shares a net-name PREFIX (its "chain
  // key") and each net suffixes a node — RF1_IN, RF1_LNA, RF1_ATT, RF1_OUT → key "RF1".
  // A device bridging two nets of the SAME key is an inline link, so the map collapses
  // the run (amp → att → filter …) into one chain regardless of the parts' pin names or
  // type. The key is the leading token before the first "_" (≥2 chars, letter-led — so a
  // single-letter signal like V_TUNE and digit-led rails like 3V3 don't qualify).
  // Parallel chains take distinct keys (RF1, RF2, LO1). "" = not a chain net.
  function chainKey(n) { const m = /^([A-Za-z][A-Za-z0-9]+)_/.exec(netLeaf(n)); return m ? m[1] : ""; }
  // Guard for the pin-id path: are two nets plausibly the SAME signal at two domains?
  // Either the voltage twin (X / X_1V8), or a shared base with differing trailing
  // tags where ≥1 tag is a voltage (DUT_FIX_A0_3V3 / DUT_FIX_A0_MCU). Stops a
  // board-to-board connector's unrelated A1/B1 pins (SPI_CLK / SPI_MISO) collapsing.
  function chanNets(a, b) {
    if (!a || !b || a === b) return false;
    if (passChannel(a, b)) return true;
    const i = a.lastIndexOf("_"), j = b.lastIndexOf("_");
    if (i < 1 || j < 1 || a.slice(0, i) !== b.slice(0, j)) return false;
    const ta = a.slice(i + 1), tb = b.slice(j + 1);
    return ta !== tb && (/^\d+v\d*$/i.test(ta) || /^\d+v\d*$/i.test(tb));
  }
  // Longest common prefix of a set of net names, trimmed of trailing separators — a
  // compact label for a terminal stub gathering a shifter's out-nets (DUT_FIX_A0_MCU
  // … DUT_FIX_A7_MCU → "DUT_FIX_A"). Falls back to the first name.
  function lcpLabel(names) {
    const xs = names.filter(Boolean); if (!xs.length) return "";
    let p = xs[0];
    for (const s of xs) { let k = 0; while (k < p.length && k < s.length && p[k] === s[k]) k++; p = p.slice(0, k); if (!p) break; }
    return p.replace(/[_\-]+$/, "") || xs[0];
  }
  // "Ghost partners": ring an IC with lightweight dashed proxies of every OTHER IC
  // it has a direct point-to-point net with (exactly 2 endpoints, both ICs, no
  // passive, non-power/ground). Each shared pad is aligned to the focus IC's row,
  // so the link is one short straight wire with the net name above it. Differential
  // pairs (ADF_CH5P/N, FOO+/-) are drawn coupled in a distinct colour. The real
  // partner lives elsewhere; clicking a ghost hops to it. ghostRef = one IC;
  // ghostAll = every IC at once (the whole-board connection map).
  function ghostPartners(m) {
    const real = m.hubs.filter((h) => !h.ghost && !h.synthetic);
    const refs = ghostAll ? [...new Set(real.map((h) => h.ref))] : (ghostRef ? [ghostRef] : []);
    if (!refs.length) return;
    const allNets = new Set(); real.forEach((h) => h.pins.forEach((p) => { if (p.net) allNets.add(p.net); }));
    const isDiff = (n) => { const t = diffTwin(n); return !!(t && allNets.has(t)); };
    let box = null;
    refs.forEach((r) => { const b = ghostOneIC(m, r, isDiff); if (b && !ghostAll) box = b; });
    if (box) m.ghostBox = box;
  }
  function ghostOneIC(m, focusRef, isDiff) {
    const focusBlocks = m.hubs.filter((h) => !h.ghost && !h.synthetic && h.ref === focusRef);
    if (!focusBlocks.length) return null;
    const passiveNets = new Set();
    m.passes.forEach((p) => p.term.forEach((t) => { if (t.net) passiveNets.add(t.net); }));
    const ends = new Map();
    m.hubs.forEach((h) => { if (h.ghost || h.synthetic) return; h.pins.forEach((p) => {
      if (!p.net || isGroundName(p.net) || isPowerName(p.net)) return;
      let a = ends.get(p.net); if (!a) { a = []; ends.set(p.net, a); } a.push({ hub: h, pin: p });
    }); });
    // Group the focus IC's direct links by (partner, side it leaves the IC on).
    const byKey = new Map();
    ends.forEach((eps, net) => {
      if (passiveNets.has(net) || eps.length !== 2) return;
      const fe = eps.find((e) => e.hub.ref === focusRef), pe = eps.find((e) => e.hub.ref !== focusRef);
      if (!fe || !pe) return;                                   // not focus↔other
      // Label the ghost pin with the partner's own function name when it's
      // meaningful (a real IC pin), else the focus IC's name — never a bare pad
      // number (a connector pad like J1.46 reads as nothing).
      const pm = pe.pin.name && !/^[0-9]+$/.test(pe.pin.name) && pe.pin.name !== pe.pin.pin;
      const pinName = pm ? pe.pin.name : (fe.pin.name || pe.pin.pin);
      const key = pe.hub.ref + "|" + fe.pin.side;
      let g = byKey.get(key); if (!g) { g = { ref: pe.hub.ref, label: pe.hub.label, side: fe.pin.side, items: [] }; byKey.set(key, g); }
      g.items.push({ net, fx: fe.pin.x, fy: fe.pin.y, pinName, partnerPin: pe.pin.pin, diff: isDiff(net) });
    });
    if (!byKey.size) return null;
    const PAD = 10, LABEL = 22, OUT = 70, LANE = 150, GW = 132;
    const rightEdge = Math.max(...focusBlocks.map((h) => h.x + h.w));
    const leftEdge = Math.min(...focusBlocks.map((h) => h.x));
    const lanesBySide = { left: [], right: [] };
    const ghostedNets = new Set();
    let nx0 = leftEdge, ny0 = Math.min(...focusBlocks.map((h) => h.y));
    let nx1 = rightEdge, ny1 = Math.max(...focusBlocks.map((h) => h.y + h.h));
    [...byKey.values()].sort((a, b) => a.items[0].fy - b.items[0].fy).forEach((g) => {
      g.items.sort((a, b) => a.fy - b.fy);
      const top = g.items[0].fy - LABEL, bot = g.items[g.items.length - 1].fy + PAD;
      const lanes = lanesBySide[g.side] || (lanesBySide[g.side] = []);
      let lane = 0;
      for (; lane < lanes.length; lane++) if (lanes[lane].every((iv) => bot < iv.top || top > iv.bot)) break;
      if (lane === lanes.length) lanes.push([]);
      lanes[lane].push({ top, bot });
      const onRight = g.side === "right";
      const gx = onRight ? rightEdge + OUT + lane * LANE : leftEdge - OUT - lane * LANE - GW;
      const innerX = onRight ? gx : gx + GW;
      const blk = { ref: g.ref, label: g.label, x: gx, y: top, w: GW, h: bot - top, cx: gx + GW / 2, cy: (top + bot) / 2, pins: [], synthetic: true, ghost: true, partnerRef: g.ref };
      g.items.forEach((it) => {
        ghostedNets.add(it.net);
        blk.pins.push({ pin: it.partnerPin, name: it.pinName, side: onRight ? "left" : "right", x: innerX, y: it.fy, net: it.net, vx: null, vy: null });
        const pts = [[it.fx, it.fy], [innerX, it.fy]];
        m.wires.push({ net: it.net, bus: false, link: true, diff: it.diff, pts, bb: bbOf(pts) });
        m.labels.push({ text: it.net, x: (it.fx + innerX) / 2, y: it.fy - 9, anchor: "center", ground: false, port: false, net: it.net, link: true, diff: it.diff });
      });
      m.hubs.push(blk);
      nx0 = Math.min(nx0, gx); nx1 = Math.max(nx1, gx + GW); ny0 = Math.min(ny0, top); ny1 = Math.max(ny1, bot);
    });
    if (!ghostedNets.size) return null;
    // Drop the original stub labels for ghosted nets (keep the new centered ones).
    m.labels = m.labels.filter((l) => l.link || !ghostedNets.has(l.net));
    return { x: nx0 - 40, y: ny0 - 40, w: (nx1 - nx0) + 80, h: (ny1 - ny0) + 80 };
  }

  // All point-to-point IC↔IC connections for the maps: a net with exactly two IC
  // pins (direct), OR a linear chain of in-line elements between two IC pins — a
  // 2-pin series passive (R, AC-coupling cap, ferrite, a π-pad's series leg) AND a
  // multi-pin PASS-THROUGH device (a TXB0104/TXS0108 level shifter, an in-line ESD
  // array): a device that carries both ends of a level-translation channel
  // (CS_RX1 in, CS_RX1_1V8 out) is hopped through and recorded as an in-line
  // element, so on the map the signal traces host→[shifter]→slave instead of
  // dead-ending at the shifter. Passive stubs to power/ground are ignored.
  // Returns [{a:{ref,name,pin,net}, b:{…}, passives:[{ref,value,type,device?,inNet?,outNet?}]}].
  function icLinks(m) {
    const real = m.hubs.filter((h) => !h.ghost && !h.synthetic);
    const netIC = new Map(), netPass = new Map(), pinsByRef = new Map(), compByRef = new Map();
    real.forEach((h) => { if (!compByRef.has(h.ref)) compByRef.set(h.ref, h.component || ""); h.pins.forEach((p) => {
      if (!p.net) return;
      let a = netIC.get(p.net); if (!a) { a = []; netIC.set(p.net, a); } a.push({ ref: h.ref, name: p.name, pin: p.pin });
      let b = pinsByRef.get(h.ref); if (!b) { b = []; pinsByRef.set(h.ref, b); } b.push({ pin: p.pin, net: p.net });
    }); });
    // Series / in-line passives: a 2-pin part bridging two nets. Built from BOTH the
    // laid-out spokes (m.passes — terms carry resolved nets) AND the staged band
    // (scene.staged — its pins carry nets, but addStaged renders them net-less and
    // isn't even called in map mode). Without the staged half, a chain that runs
    // through a staged R — e.g. the DUT protection resistors between a level shifter
    // and the (not-yet-placed) connector — looks like an immediate dead-end, so the
    // pass-through hop guard fails and the shifter never collapses inline.
    const seenPass = new Set();
    const addPassEdge = (ref, type, label, n0, n1) => {
      if (!ref || (!n0 && !n1) || seenPass.has(ref)) return; seenPass.add(ref);
      const push = (net, other) => { if (!net) return; let a = netPass.get(net); if (!a) { a = []; netPass.set(net, a); } a.push({ ref, value: label, type, otherNet: other }); };
      push(n0, n1); push(n1, n0);
    };
    m.passes.forEach((p) => { if (p.term && p.term.length === 2) addPassEdge(p.ref, p.type, p.label, p.term[0].net, p.term[1].net); });
    (scene.staged || []).forEach((c) => {
      if (!c.pins || c.pins.length !== 2) return;
      addPassEdge(c.ref, passType(c.ref, c.component, c.value, c.symbol), c.value || c.component || c.ref, c.pins[0].net, c.pins[1].net);
    });
    const isStub = (n) => !n || isGroundName(n) || isPowerName(n);
    // The signal twin this device carries for `inNet` (its other leg) — the exit net of
    // a pass-through hop, or null if it carries none. Three conventions, tried in order:
    // (1) the net-name voltage twin (X / X_1V8), (2) the A<n>↔B<n> pin-id convention
    // (guarded by chanNets, for level shifters whose nets don't twin by name — e.g.
    // labstation's _3V3 / _MCU), and (3) the general chain-key prefix (RF1_IN / RF1_OUT
    // …) — device-agnostic, so an RF amp, a pad, an ESD array or a level shifter all
    // chain the same way once their two nets share a key.
    const passExit = (ref, inNet) => {
      const pins = pinsByRef.get(ref) || [];
      for (const pp of pins) if (!isStub(pp.net) && passChannel(inNet, pp.net)) return pp.net;
      for (const pp of pins) {
        if (pp.net !== inNet) continue;
        const tw = pinTwinId(pp.pin); if (!tw) continue;
        for (const q of pins) if (q.pin === tw && !isStub(q.net) && chanNets(inNet, q.net)) return q.net;
      }
      // (3) Chain-key: the exit is the UNIQUE other net sharing inNet's chain key. A
      // junction (mixer: RF1 in, IF1 out, LO1) has no same-key sibling per leg → stays
      // an endpoint; a splitter (≥2 same-key siblings) is ambiguous → not collapsed.
      const ik = chainKey(inNet);
      if (ik) {
        const sib = [...new Set(pins.filter((pp) => !isStub(pp.net) && pp.net !== inNet && chainKey(pp.net) === ik).map((pp) => pp.net))];
        if (sib.length === 1) return sib[0];
      }
      return null;
    };
    // Where a net continues, excluding refs already on the path (start IC + every
    // device hopped through), the passive we arrived through, and stub passives.
    const conts = (net, viaPass, excl) => {
      const out = [];
      (netIC.get(net) || []).forEach((e) => { if (!excl.has(e.ref)) out.push({ t: "ic", ref: e.ref, name: e.name, pin: e.pin }); });
      (netPass.get(net) || []).forEach((pp) => { if (pp.ref === viaPass || isStub(pp.otherNet)) return; out.push({ t: "pass", ref: pp.ref, value: pp.value, type: pp.type, otherNet: pp.otherNet }); });
      return out;
    };
    const links = [], seen = new Set();
    real.forEach((h) => h.pins.forEach((p0) => {
      if (isStub(p0.net)) return;
      // A pass-through device's own channel leg is captured INLINE from the real
      // endpoints' walks, so never start a walk from it — otherwise the shifter
      // also records host↔shifter / shifter↔slave half-links and re-appears as a
      // standalone block on top of the inline chip.
      if (passExit(h.ref, p0.net)) return;
      let net = p0.net, viaPass = null; const chain = [], startNet = p0.net, seenNets = new Set(), excl = new Set([h.ref]);
      let firstDev = null, recorded = false, fannedOut = false;
      for (let step = 0; step < 12; step++) {
        if (isStub(net) || seenNets.has(net)) break;
        seenNets.add(net);
        const cs = conts(net, viaPass, excl);
        let c;
        if (cs.length === 1) c = cs[0];
        else {
          // Fan-out: a real chain net can also carry high-Z taps — a VCO output that feeds
          // the filter chain AND taps the PLL feedback, say. Follow the SINGLE chain-
          // extending continuation (a series passive, or a passthrough IC whose exit
          // continues on) and ignore terminal taps. 0 or ≥2 extensions = a true junction.
          const extend = cs.filter((x) => x.t === "pass"
            ? !isStub(x.otherNet)
            : (function () { const ex = passExit(x.ref, net); return !!(ex && !seenNets.has(ex) && conts(ex, null, new Set([...excl, x.ref])).length === 1); })());
          if (extend.length === 1) c = extend[0];
          else { fannedOut = cs.some((x) => x.t === "ic"); break; }   // junction (has IC taps) ≠ dead end
        }
        if (c.t === "ic") {
          // Pass-through device? It carries the channel twin of `net`, and that
          // exit continues to exactly one further endpoint (so a multi-drop bus
          // through the shifter is NOT collapsed — that exit fans out → fall back
          // to treating the device as a plain endpoint, as before).
          const ex = passExit(c.ref, net);
          if (ex && !seenNets.has(ex) && conts(ex, null, new Set([...excl, c.ref])).length === 1) {
            chain.push({ ref: c.ref, value: "", type: "device", device: true, component: compByRef.get(c.ref) || "", inNet: net, outNet: ex });
            if (!firstDev) firstDev = { ref: c.ref, inNet: net, outNet: ex, component: compByRef.get(c.ref) || "" };
            excl.add(c.ref); viaPass = null; net = ex; continue;
          }
          if (c.ref !== h.ref) {
            const key = [h.ref + "." + p0.pin, c.ref + "." + c.pin].sort().join("|");
            if (!seen.has(key)) { seen.add(key); links.push({ a: { ref: h.ref, name: p0.name, pin: p0.pin, net: startNet }, b: { ref: c.ref, name: c.name, pin: c.pin, net }, passives: chain.slice() }); }
            recorded = true;
          }
          break;
        }
        chain.push({ ref: c.ref, value: c.value, type: c.type }); viaPass = c.ref; net = c.otherNet;
      }
      // A pass-through whose far side never reaches a second IC (e.g. the DUT
      // connector isn't instantiated yet — the channel dies in the protection
      // R/TVS net). Still surface the device inline with its in/out nets; the far
      // end becomes a terminal stub, grouped per device (ref + " ▸") so a shifter's
      // channels cluster into one run instead of scattering one block per net.
      if (firstDev && !recorded && !fannedOut) {
        const key = h.ref + "." + p0.pin + "|term";
        if (!seen.has(key)) {
          seen.add(key);
          links.push({
            a: { ref: h.ref, name: p0.name, pin: p0.pin, net: startNet },
            b: { ref: firstDev.ref + " ▸", terminal: true, name: "", pin: firstDev.outNet, net: firstDev.outNet },
            passives: [{ ref: firstDev.ref, value: "", type: "device", device: true, component: firstDev.component, inNet: firstDev.inNet, outNet: firstDev.outNet }],
          });
        }
      }
    }));
    return links;
  }
  // Global connection map: throw the real board layout away and rebuild it as a
  // grid of self-contained per-IC cells. Each cell is one real IC ringed by dashed
  // ghost proxies of the ICs it connects to point-to-point — pins aligned so each
  // link is one straight wire + net label, differential pairs coupled in violet.
  // Every partner gets its own row band (no interleaving) and every cell its own
  // grid slot, so NOTHING can overlap. To avoid redundancy each connection is drawn
  // exactly ONCE: a greedy set-cover keeps the fewest high-degree "anchor" ICs that
  // still cover every link, and low-degree ICs survive only as ghosts inside their
  // busiest neighbour's cell (they get no cell of their own).
  function buildGlobalMap(m) {
    const real = m.hubs.filter((h) => !h.ghost && !h.synthetic);
    const labelOf = new Map(), compOf = new Map();
    real.forEach((h) => { if (!labelOf.has(h.ref)) { labelOf.set(h.ref, h.label); compOf.set(h.ref, h.component || ""); } });
    const allNets = new Set(); real.forEach((h) => h.pins.forEach((p) => { if (p.net) allNets.add(p.net); }));
    const isDiff = (n) => { const t = diffTwin(n); return !!(t && allNets.has(t)); };
    // byIC: ref -> (partnerRef -> [{net, outNet, through, via, icPinName, ghostPinName, diff}])
    const byIC = new Map();
    const addItem = (a, b, link) => {
      let parts = byIC.get(a.ref); if (!parts) { parts = new Map(); byIC.set(a.ref, parts); }
      let arr = parts.get(b.ref); if (!arr) { arr = []; parts.set(b.ref, arr); }
      const pm = b.name && !/^[0-9]+$/.test(b.name) && b.name !== b.pin;   // partner name meaningful?
      const item = { net: a.net, outNet: null, farNet: null, through: null, via: null, tail: null, icPinName: a.name, ghostPinName: pm ? b.name : a.name, diff: isDiff(a.net), terminal: !!b.terminal };
      const devs = link.passives.filter((x) => x.device);
      if (devs.length === 1) {
        // Exactly one pass-through device → a FULL inline block (ref + mpn + in/out
        // pins) in a middle column, drawn like every other block. Any series passive
        // AFTER it (the DUT protection R between the shifter and the connector /
        // monitor mux) rides the OUTPUT leg as a small symbol; the partner ghost
        // sits on the net past it. With no tail this is the plain shifter (cyclops).
        const dev = devs[0], tail = link.passives.filter((x) => !x.device);
        item.through = { ref: dev.ref, component: dev.component || "" };
        const sOut = dev.outNet || b.net;                                   // shifter's own output net
        item.outNet = (sOut && sOut !== a.net) ? sOut : null;
        if (tail.length) {
          item.tail = { type: tail.length === 1 ? tail[0].type : "box", label: tail.length === 1 ? (tail[0].ref + (tail[0].value ? " " + tail[0].value : "")) : tail.map((x) => x.ref).join("+"), ref: tail[0].ref };
          item.farNet = (b.net && b.net !== sOut && b.net !== a.net) ? b.net : null;   // net past the tail (ghost pin)
        }
      } else if (link.passives.length) {
        // A plain series passive (or a multi-device chain) stays a small inline symbol.
        const one = link.passives[0], refs = link.passives.map((x) => x.ref).join("+");
        item.via = { type: link.passives.length === 1 ? one.type : "box", label: link.passives.length === 1 ? (one.ref + (one.value ? " " + one.value : "")) : refs, device: devs.length > 0, ref: one.ref };
        item.outNet = (devs.length > 0 && b.net && b.net !== a.net) ? b.net : null;
      }
      arr.push(item);
    };
    // A point-to-point link carries the SAME information from either IC's side, so
    // drawing it in both cells (and giving every IC a cell) is pure redundancy.
    // Greedily cover every link with the fewest anchor ICs: repeatedly take the IC
    // carrying the most still-unshown connections, show all of those in its cell,
    // mark them covered, and repeat. Each link is then added to exactly one anchor
    // (oriented anchor-first), and an IC with no uncovered links never gets a cell —
    // it appears only as a ghost inside whichever neighbour absorbed it.
    const links = icLinks(m);
    if (!links.length) return;
    const byRef = new Map();                              // ref -> [link index…]
    const terminalRefs = new Set();                       // synthetic "ref ▸" stubs — never anchor a cell
    links.forEach((lk, i) => [lk.a.ref, lk.b.ref].forEach((r) => {
      let a = byRef.get(r); if (!a) { a = []; byRef.set(r, a); } a.push(i);
    }));
    links.forEach((lk) => { if (lk.b.terminal) terminalRefs.add(lk.b.ref); });
    const deg = (r) => byRef.get(r).length;               // total degree (tiebreak)
    const covered = new Array(links.length).fill(false);
    let remaining = links.length;
    while (remaining > 0) {
      let best = null, bestN = -1;
      byRef.forEach((idxs, ref) => {
        if (terminalRefs.has(ref)) return;                // a terminal stub is only ever a partner, not an anchor
        let n = 0; for (const i of idxs) if (!covered[i]) n++;
        if (n <= 0) return;
        if (best === null || n > bestN ||
            (n === bestN && (deg(ref) > deg(best) || (deg(ref) === deg(best) && ref < best)))) { bestN = n; best = ref; }
      });
      if (best === null) break;
      for (const i of byRef.get(best)) {
        if (covered[i]) continue;
        covered[i] = true; remaining--;
        const lk = links[i];
        const a = lk.a.ref === best ? lk.a : lk.b, b = lk.a.ref === best ? lk.b : lk.a;
        addItem(a, b, lk);
      }
    }
    if (!byIC.size) return;
    // Pull-ups / pull-downs: a RESISTOR with one leg on a signal net and the other
    // on a rail (power/ground). Keyed by the signal net so a link carrying it can
    // draw the pull as a branch. (Resistors only — a cap to a rail is decoupling.)
    const isStub = (n) => !n || isGroundName(n) || isPowerName(n);
    const pullByNet = new Map();
    m.passes.forEach((p) => {
      if (!p.term || p.term.length !== 2 || p.type !== "resistor") return;
      const add = (sig, rail) => {
        if (!sig || isStub(sig) || !rail || !isStub(rail)) return;
        let a = pullByNet.get(sig); if (!a) { a = []; pullByNet.set(sig, a); }
        if (!a.some((x) => x.ref === p.ref)) a.push({ ref: p.ref, value: p.label || "", rail, up: isPowerName(rail) });
      };
      add(p.term[0].net, p.term[1].net); add(p.term[1].net, p.term[0].net);
    });
    // Passives on the map mirror the normal view. A bypass cap with a `(decouples …
    // PAD)` binding docks on the ONE pin it serves — resolved by pad+net the same way
    // the schematic's boundHubPin does — NOT on every pin of its shared rail. Series
    // elements and pulls (low-fanout, between specific nets) stay net-keyed. An UNBOUND
    // cap whose only legs are a rail and ground is rail-level and isn't drawn per pin.
    const isRailNet = (n) => isPowerName(n) || isGroundName(n) || /\d+v\d*/i.test(netLeaf(n));
    // (pad \0 net) -> hub ref, to resolve a decouple binding to its owner hub on that net.
    const padNetHub = new Map();
    (scene.hubs || []).forEach((h) => [].concat(h.leftPins || [], h.rightPins || []).forEach((pin) => {
      if (!pin.net) return;
      String(pin.pins || "").split(",").forEach((pad) => { if (pad) padNetHub.set(pad + " " + pin.net, h.ref); });
    }));
    const decoupByPin = new Map();   // "ownerRef \0 pad" -> [{ref,type,value,other}]  (bound bypass caps)
    const passByNet = new Map();     // signal net -> [{ref,type,value,other}]  (series + pulls)
    (scene.passives || []).forEach((p) => {
      const nets = (p.pins || []).map((x) => x.net).filter(Boolean);
      if (nets.length !== 2) return;
      const type = passType(p.ref, p.component, p.value, p.symbol);
      const value = (p.count > 1 ? p.count + "× " : "") + (p.value || p.ref);
      if (p.decouplePin) {                                   // bound bypass cap → its served pin only
        let owner = null;
        for (const net of nets) {
          const r = padNetHub.get(p.decouplePin + " " + net);
          if (r) { owner = { ref: r, net }; if (!p.decoupleIc || r === p.decoupleIc) break; }
        }
        if (owner) {
          const other = nets.find((n) => n !== owner.net) || "";
          const key = owner.ref + " " + p.decouplePin;
          let a = decoupByPin.get(key); if (!a) { a = []; decoupByPin.set(key, a); }
          if (!a.some((x) => x.ref === p.ref)) a.push({ ref: p.ref, type, value, other });
          return;
        }
      }
      // unbound: key by the SIGNAL leg(s) only — a pull's signal net, a series part's two
      // nets — so a rail-only cap (rail + ground, no signal leg) isn't redrawn per rail pin.
      const add = (net, other) => { if (!net || isRailNet(net)) return; let a = passByNet.get(net); if (!a) { a = []; passByNet.set(net, a); } if (!a.some((x) => x.ref === p.ref)) a.push({ ref: p.ref, type, value, other }); };
      add(nets[0], nets[1]); add(nets[1], nets[0]);
    });
    const PITCH = 38, HEAD = 46, PAD = 18, LBL = 44, GROWGAP = 20, ICW = 168, GW = 146, OUT = 92, MX = 24, MY = 22;
    const SHEAD = 38, SHIFT_W = 122, LEAD = 92, PULLH = 30, PULL_DROP = 11;       // pass-through shifter block + leads (wide enough for a ~14-char net label); pull-branch height; riser to the spoke below the wire
    // Extras band — the pins with no point-to-point partner (power/ground, multi-drop,
    // board IO) shown as horizontal SPOKES that fan out to BOTH sides of the IC, like
    // the original schematic (passives ride the spoke, terminal at the outboard end).
    const EXTRA_TOP = 16, EXTRA_PITCH = 30, PASSROW = 30;          // band top inset; bare-pin row height; parallel-spoke pitch
    const EXTRA_LEAD = 18, SYM_LEAD = 12, TERM_LEAD = 14, EXTRA_STUB = 56, EXTRA_LABELW = 90;
    const EXTRA_SPAN = EXTRA_LEAD + SYM_LEAD + SPOKE_SYM + TERM_LEAD + EXTRA_LABELW;   // outboard room a spoke side needs
    // Power layer (Shift+P): a strip of each IC's power/ground rail nodes, folded
    // into the bottom of its card so packing reserves room. Built only when the
    // layer is on, so the default map is byte-identical (no nodes, no extra height).
    // decoupByNet counts the decoupling caps on a rail so a node can badge "⎓N".
    const NODEW = NODE_W, NODEGAP = 8, RAILTOP = 14, RAILROW = 28;
    const decoupByNet = new Map();
    if (showPower) m.passes.forEach((p) => {
      if (p.type !== "capacitor" || !p.term || p.term.length !== 2) return;
      p.term.forEach((t) => { if (t.net && isStub(t.net)) { let a = decoupByNet.get(t.net); if (!a) { a = []; decoupByNet.set(t.net, a); } a.push(p.ref); } });
    });
    const layoutRails = (cell, ref, coreH) => {
      const rhub = real.find((h) => h.ref === ref);
      if (!rhub) return 0;
      const seen = new Set(), nets = [];
      rhub.pins.forEach((p) => { const nn = p.anet || ""; if (nn && isStub(nn) && !seen.has(nn)) { seen.add(nn); nets.push(nn); } });
      if (!nets.length) return 0;
      nets.sort((a, b) => ((isGroundName(a) ? 1 : 0) - (isGroundName(b) ? 1 : 0)) || (a < b ? -1 : a > b ? 1 : 0));   // power first, then ground
      const perRow = Math.max(1, Math.floor((ICW - NODEGAP) / (NODEW + NODEGAP)));
      const cx = cell.icX + ICW / 2;
      cell.rails = [];
      nets.forEach((net, i) => {
        const row = Math.floor(i / perRow), col = i % perRow;
        const count = Math.min(perRow, nets.length - row * perRow), rowW = count * NODEW + (count - 1) * NODEGAP;
        cell.rails.push({ x: cx - rowW / 2 + col * (NODEW + NODEGAP) + NODEW / 2, y: coreH + RAILTOP + row * RAILROW + RAILROW / 2, net, up: isPowerName(net) && !isGroundName(net), decoup: (decoupByNet.get(net) || []).length });
      });
      return RAILTOP + Math.ceil(nets.length / perRow) * RAILROW;
    };
    const cells = [];
    [...byIC.entries()].forEach(([ref, parts]) => {
      const groups = [...parts.entries()].map(([pref, items]) => ({ pref, label: labelOf.get(pref) || pref, items })).sort((a, b) => b.items.length - a.items.length);
      const side = { left: [], right: [] }; let lc = 0, rc = 0;                  // balance pins across the two sides
      groups.forEach((g) => { if (lc <= rc) { side.left.push(g); lc += g.items.length; } else { side.right.push(g); rc += g.items.length; } });
      const sidePT = (gs) => gs.some((g) => g.items.some((it) => it.through));
      const leftPT = sidePT(side.left), rightPT = sidePT(side.right);
      const sideW = (gs, pt) => gs.length ? (pt ? LEAD + SHIFT_W + LEAD + GW : OUT + GW) : 0;
      // Gather this IC's extra pins (no point-to-point partner) and split them across the
      // two sides, balanced by row height, so the band below the partner pins is ~half as
      // tall. Done BEFORE icX so each side reserves room for its outgoing spokes.
      const rhub = real.find((h) => h.ref === ref);
      const partnerNets = new Set();
      groups.forEach((g) => g.items.forEach((it) => { [it.net, it.outNet, it.farNet].forEach((n) => n && partnerNets.add(n)); }));
      const passClaimed = new Set();                 // each passive lands on at most one pin of this cell
      const rowHt = (ps) => Math.max(EXTRA_PITCH, ps.length * PASSROW);
      const extras = [], seenE = new Set();
      (rhub ? rhub.pins : []).forEach((p) => {
        const net = p.anet || p.net;
        if (!net || partnerNets.has(net) || seenE.has(net)) return;
        if (showPower && isStub(net)) return;        // power/ground live in the rail band when that layer is on
        seenE.add(net);
        const pads = String(p.pins || p.pin || "").split(",").filter(Boolean);
        const ps = [], seenP = new Set();            // bypass caps bound to a pad (decoupByPin) + series/pulls on the net
        pads.forEach((pad) => (decoupByPin.get(ref + " " + pad) || []).forEach((x) => { if (!seenP.has(x.ref)) { seenP.add(x.ref); ps.push(x); } }));
        (passByNet.get(net) || []).forEach((x) => { if (!seenP.has(x.ref) && !passClaimed.has(x.ref)) { seenP.add(x.ref); ps.push(x); } });
        ps.forEach((x) => passClaimed.add(x.ref));
        extras.push({ net, name: p.name, ps });
      });
      const eLeft = [], eRight = []; let ehL = 0, ehR = 0;
      extras.forEach((e) => { if (ehL <= ehR) { eLeft.push(e); ehL += rowHt(e.ps); } else { eRight.push(e); ehR += rowHt(e.ps); } });
      const extraSideW = (es) => es.length ? EXTRA_SPAN : 0;
      const leftW = Math.max(sideW(side.left, leftPT), extraSideW(eLeft));
      const rightW = Math.max(sideW(side.right, rightPT), extraSideW(eRight)), icX = leftW;
      const cell = { ref, label: labelOf.get(ref) || ref, ox: MX, oy: MY, ch: 0, w: 2 * MX + leftW + ICW + rightW, h: 0, icX, ghosts: [], wires: [], labels: [], pulls: [], leftPins: [], rightPins: [] };
      // A pull-up/down on `net` taps the wire segment [x0,x1]@y, drops a short riser
      // into the band just below it, then runs HORIZONTALLY (compact, to fit the partner
      // gap) out to its terminal — the same side-spoke idiom as the extra pins, so the
      // whole map reads uniformly instead of one resistor hanging straight down. `dir`
      // points the spoke toward open space (away from the IC). Returns the room used.
      const pullsOn = (net, x0, x1, y, dir) => {
        const ps = pullByNet.get(net); if (!ps || !ps.length) return 0;
        const mx0 = (x0 + x1) / 2, jy = y + PULL_DROP, d = dir || 1;
        ps.forEach((pl, k) => {
          const mx = mx0 + (k - (ps.length - 1) / 2) * 46;
          cell.wires.push({ net, pts: [[mx, y], [mx, jy]] });                    // riser from the wire down to the spoke
          cell.pulls.push({ axis: "h", dir: d, y: jy, jx: mx, x: mx + d * (6 + SPOKE_SYM / 2), tx: mx + d * (14 + SPOKE_SYM),
            ref: pl.ref, value: pl.value, type: "resistor", term: pl.up ? "rail" : "gnd", rail: netLeaf(pl.rail) });
        });
        return PULLH;
      };
      const layoutSide = (gs, onRight, pt) => {
        if (!gs.length) return HEAD;
        const icEdge = onRight ? icX + ICW : icX;
        const shiftX = onRight ? icEdge + LEAD : icEdge - LEAD - SHIFT_W;
        const shIn = onRight ? shiftX : shiftX + SHIFT_W, shOut = onRight ? shiftX + SHIFT_W : shiftX;
        const ghX = pt ? (onRight ? icEdge + LEAD + SHIFT_W + LEAD : icEdge - LEAD - SHIFT_W - LEAD - GW)
          : (onRight ? icEdge + OUT : icEdge - OUT - GW);
        const ghIn = onRight ? ghX : ghX + GW;
        let y = HEAD + PITCH / 2, lastBot = HEAD + PITCH;
        gs.forEach((g) => {
          // Order items so each shifter's channels are a contiguous run (direct first).
          const ordered = g.items.slice().sort((p, q) => {
            const sp = p.through ? p.through.ref : "", sq = q.through ? q.through.ref : "";
            return sp === sq ? 0 : !sp ? -1 : !sq ? 1 : sp < sq ? -1 : 1;
          });
          const gpins = [], rows = [];
          let curS = null;
          ordered.forEach((it) => {
            const s = it.through ? it.through.ref : null;
            if (s !== curS) { if (s) y += SHEAD; curS = s; }       // header room before a shifter run
            (onRight ? cell.rightPins : cell.leftPins).push({ name: it.icPinName, x: icEdge, y, net: it.net });
            const gnet = it.farNet || it.outNet || it.net;
            gpins.push({ pin: gnet, name: it.ghostPinName === it.icPinName ? "" : it.ghostPinName, side: onRight ? "left" : "right", x: ghIn, y, net: gnet, vx: null, vy: null });
            rows.push({ it, y, s });
            y += PITCH;
            if (pullByNet.has(it.net) || (it.outNet && pullByNet.has(it.outNet))) y += PULLH;   // room for a pull branch
          });
          const last = rows[rows.length - 1];
          const lastPull = pullByNet.has(last.it.net) || (last.it.outNet && pullByNet.has(last.it.outNet));
          const gTop = rows[0].y - LBL, gBot = last.y + (lastPull ? PULLH : PITCH / 2);   // box contains a trailing pull branch
          let i = 0;
          while (i < rows.length) {
            const r = rows[i];
            if (!r.s) {                                            // direct link: one straight wire + label
              cell.wires.push({ net: r.it.net, diff: r.it.diff, via: r.it.via, pts: [[icEdge, r.y], [ghIn, r.y]] });
              cell.labels.push({ text: r.it.net, x: (icEdge + ghIn) / 2, y: r.y - 10, diff: r.it.diff });
              pullsOn(r.it.net, icEdge, ghIn, r.y, onRight ? 1 : -1);
              i++; continue;
            }
            let j = i; while (j < rows.length && rows[j].s === r.s) j++;
            const run = rows.slice(i, j), spins = [];
            run.forEach((rr) => {                                  // anchor → shifter.in, shifter.out → (tail R) → ghost
              const oNet = rr.it.outNet || rr.it.net;              // shifter's own output net
              const fNet = rr.it.farNet || oNet;                   // ghost-side net (past any series protection R)
              spins.push({ pin: rr.it.net, name: "", side: onRight ? "left" : "right", x: shIn, y: rr.y, net: rr.it.net, vx: null, vy: null });
              spins.push({ pin: oNet, name: "", side: onRight ? "right" : "left", x: shOut, y: rr.y, net: oNet, vx: null, vy: null });
              cell.wires.push({ net: rr.it.net, diff: rr.it.diff, pts: [[icEdge, rr.y], [shIn, rr.y]] });
              cell.wires.push({ net: fNet, diff: rr.it.diff, via: rr.it.tail || null, pts: [[shOut, rr.y], [ghIn, rr.y]] });
              cell.labels.push({ text: rr.it.net, x: (icEdge + shIn) / 2, y: rr.y - 10, diff: rr.it.diff });
              // shifter output net: at the leg midpoint normally, else hugged to the shifter so it clears the tail symbol.
              if (rr.it.outNet) cell.labels.push({ text: oNet, x: rr.it.tail ? shOut + (onRight ? 1 : -1) * (LEAD * 0.3) : (shOut + ghIn) / 2, y: rr.y - 10, diff: rr.it.diff });
              pullsOn(rr.it.net, icEdge, shIn, rr.y, onRight ? 1 : -1);
              if (rr.it.outNet && !rr.it.tail) pullsOn(rr.it.outNet, shOut, ghIn, rr.y, onRight ? 1 : -1);
            });
            const d = run[0].it.through;
            cell.ghosts.push({ ref: d.ref, label: d.ref, part: d.component || compOf.get(d.ref) || "", x: shiftX, y: run[0].y - SHEAD, w: SHIFT_W, h: (run[run.length - 1].y + PITCH / 2) - (run[0].y - SHEAD), pins: spins });
            i = j;
          }
          const isTerm = g.items.length > 0 && g.items.every((it) => it.terminal);
          const gLabel = isTerm ? (lcpLabel(g.items.map((it) => it.outNet || it.net)) || "out") : g.pref;
          cell.ghosts.push({ ref: g.pref, label: gLabel, part: isTerm ? "" : (compOf.get(g.pref) || ""), terminal: isTerm, x: ghX, y: gTop, w: GW, h: gBot - gTop, pins: gpins });
          lastBot = gBot;
          y = gBot + GROWGAP + LBL;   // next group's box sits a fixed GROWGAP below this one, regardless of pulls (LBL = its header headroom)
        });
        return lastBot;
      };
      // Draw the pre-split extra pins (eLeft / eRight) as a band below the partner pins,
      // fanning out to BOTH sides of the IC like the original schematic: each pin gets a
      // horizontal SPOKE on its side (passive symbol inline, terminal — ground / rail /
      // net — at the outboard end). Splitting across two sides keeps the band short. A
      // bare pin is just a stub + net label. Returns the band height.
      const layoutExtras = (baseY) => {
        if (!eLeft.length && !eRight.length) return 0;
        const drawSide = (es, onRight) => {
          if (!es.length) return 0;
          const dir = onRight ? 1 : -1, edge = onRight ? icX + ICW : icX;
          const dst = (k) => edge + dir * k;
          let ey = baseY + EXTRA_TOP;
          es.forEach((e) => {
            const nP = e.ps.length, rowH = rowHt(e.ps), pinY = ey + rowH / 2;
            (onRight ? cell.rightPins : cell.leftPins).push({ name: e.name, x: edge, y: pinY, net: e.net });
            if (!nP) {                                   // bare pin → stub + net label
              cell.wires.push({ net: e.net, pts: [[edge, pinY], [dst(EXTRA_STUB), pinY]] });
              cell.labels.push({ text: e.net, x: dst(EXTRA_STUB + 6), y: pinY, anchor: onRight ? "start" : "end" });
            } else {                                     // pin → junction → parallel horizontal spokes
              const jx = dst(EXTRA_LEAD);
              cell.wires.push({ net: e.net, pts: [[edge, pinY], [jx, pinY]] });
              const y0 = pinY - (nP - 1) / 2 * PASSROW;
              if (nP > 1) cell.wires.push({ net: e.net, pts: [[jx, y0], [jx, y0 + (nP - 1) * PASSROW]] });   // riser linking the spokes
              e.ps.forEach((pp, k) => {
                const og = isGroundName(pp.other), op = isRailNet(pp.other) && !og;
                cell.pulls.push({ axis: "h", dir, y: y0 + k * PASSROW, jx,
                  x: dst(EXTRA_LEAD + SYM_LEAD + SPOKE_SYM / 2), tx: dst(EXTRA_LEAD + SYM_LEAD + SPOKE_SYM + TERM_LEAD),
                  ref: pp.ref, value: pp.value, type: pp.type || "resistor", term: og ? "gnd" : op ? "rail" : "net", rail: netLeaf(pp.other) });
              });
            }
            ey += rowH;
          });
          return ey - baseY;                             // band height (EXTRA_TOP + Σ rowH)
        };
        return Math.max(drawSide(eLeft, false), drawSide(eRight, true));
      };
      const lh = layoutSide(side.left, false, leftPT), rh = layoutSide(side.right, true, rightPT);
      const coreH = Math.max(lh, rh, HEAD + PITCH) + PAD;
      const extraH = layoutExtras(coreH);
      cell.ch = coreH + extraH + (showPower ? layoutRails(cell, ref, coreH + extraH) : 0);
      cell.h = 2 * MY + cell.ch;
      cells.push(cell);
    });
    // Shelf-pack the cells into rows so no two cells touch.
    const CGX = 72, CGY = 64, MAXW = 2600;
    let cx = 0, cy = 0, rowH = 0, bx1 = 0, by1 = 0;
    cells.forEach((c) => {
      if (cx > 0 && cx + c.w > MAXW) { cx = 0; cy += rowH + CGY; rowH = 0; }
      c.x = cx; c.y = cy; cx += c.w + CGX; rowH = Math.max(rowH, c.h);
    });
    // Emit the synthesized model (replacing the real layout).
    m.secs = []; m.hubs = []; m.passes = []; m.wires = []; m.labels = []; m.pulls = []; m.rails = [];
    cells.forEach((c) => {
      const ox = c.x + c.ox, oy = c.y + c.oy;                      // content origin (inset by the cell margin)
      m.secs.push({ name: "", x: c.x, y: c.y, w: c.w, h: c.h, idx: 0, cx: c.x + c.w / 2, cy: c.y + c.h / 2 });   // each block self-labels (ref + part), so no region title
      const mk = (p, side) => ({ pin: p.name, name: p.name, side, x: ox + p.x, y: oy + p.y, net: p.net, vx: null, vy: null });
      const pins = c.leftPins.map((p) => mk(p, "left")).concat(c.rightPins.map((p) => mk(p, "right")));
      m.hubs.push({ ref: c.ref, label: c.ref, part: compOf.get(c.ref) || "", x: ox + c.icX, y: oy, w: ICW, h: c.ch, cx: ox + c.icX + ICW / 2, cy: oy + c.ch / 2, pins });
      c.ghosts.forEach((g) => {
        const pins2 = g.pins.map((p) => ({ ...p, x: ox + p.x, y: oy + p.y }));
        m.hubs.push({ ref: g.ref, label: g.label, part: g.part, x: ox + g.x, y: oy + g.y, w: g.w, h: g.h, cx: ox + g.x + g.w / 2, cy: oy + g.y + g.h / 2, pins: pins2, synthetic: true, ghost: true, terminal: !!g.terminal, partnerRef: g.terminal ? null : g.ref });
      });
      c.wires.forEach((w) => { const pts = w.pts.map((pt) => [ox + pt[0], oy + pt[1]]); m.wires.push({ net: w.net, bus: false, link: true, diff: w.diff, via: w.via, pts, bb: bbOf(pts) }); });
      c.labels.forEach((l) => m.labels.push({ text: l.text, x: ox + l.x, y: oy + l.y, anchor: l.anchor || "center", ground: false, port: false, net: l.text, link: true, diff: l.diff }));
      c.pulls.forEach((p) => m.pulls.push({ x: ox + p.x, y: oy + p.y, ref: p.ref, value: p.value, rail: p.rail, up: p.up, type: p.type, term: p.term, axis: p.axis, dir: p.dir, jx: p.jx != null ? ox + p.jx : null, tx: p.tx != null ? ox + p.tx : null }));
      if (c.rails) c.rails.forEach((r) => m.rails.push({ x: ox + r.x, y: oy + r.y, net: r.net, up: r.up, decoup: r.decoup }));
      bx1 = Math.max(bx1, c.x + c.w); by1 = Math.max(by1, c.y + c.h);
    });
    m.mapBox = { x: -40, y: -40, w: bx1 + 80, h: by1 + 80 };
  }

  // ── Full connection map ──────────────────────────────────────────────
  // The complete netlist as one auto-arranged graph: EVERY component (IC, passive,
  // connector, staged part) is a node, EVERY net is a node, and each pin-on-net is
  // an edge — laid out force-directed so connected parts cluster. Unlike the
  // connection map (point-to-point IC↔IC only) nothing is dropped: power/ground,
  // multi-drop buses, passives and ports all appear. Built straight from the raw
  // scene (hub pins now carry their net — render_json JsonPin.net), so it needs no
  // base-layout geometry.
  function buildFullMap(m) {
    const comps = [];                                   // {kind, ref, label, part, nets:[net]}
    const addComp = (kind, ref, label, part, pinNets) => {
      const nets = [...new Set(pinNets.filter(Boolean))];
      if (!nets.length) return;                         // unplaceable by connectivity — no named net
      comps.push({ kind, ref, label: label || ref, part: part || "", nets });
    };
    (scene.hubs || []).forEach((h) => addComp("ic", h.ref, h.label || h.ref, h.part || h.component,
      [].concat(h.leftPins || [], h.rightPins || []).map((p) => p.net)));
    (scene.passives || []).forEach((p) => addComp("pass", p.ref, p.value || p.ref, p.component, (p.pins || []).map((x) => x.net)));
    (scene.staged || []).forEach((c) => addComp("pass", c.ref, c.value || c.ref, c.component, (c.pins || []).map((x) => x.net)));
    if (!comps.length) { m.secs = []; m.hubs = []; m.passes = []; m.wires = []; m.labels = []; m.pulls = []; m.rails = []; m.netNodes = []; m.fullEdges = []; m.mapBox = { x: 0, y: 0, w: 240, h: 200 }; return; }

    // net -> comp indices.
    const netComps = new Map();
    comps.forEach((c, ci) => c.nets.forEach((n) => { let a = netComps.get(n); if (!a) { a = []; netComps.set(n, a); } a.push(ci); }));
    const portNets = new Set((scene.ports || []).map((p) => p.net).filter(Boolean));

    // Two net classes. A low-fanout SIGNAL net becomes a routed net-node (a dot wired
    // to its pins, placed by the force sim — the readable connectivity graph). A
    // power/ground net, or any net above FANOUT_CAP, would be a star of dozens of
    // edges that collapses the layout into a hairball, so instead it's shown as a
    // small LOCAL FLAG beneath each member (the way schematics use power symbols
    // rather than one global wire) — present and clickable, but kept out of the sim.
    const FANOUT_CAP = 18;
    const isLocal = (net, deg) => deg > FANOUT_CAP || isPowerName(net) || isGroundName(net);
    const nodes = [];
    comps.forEach((c, ci) => nodes.push({ kind: "comp", ci, w: c.kind === "ic" ? 132 : 52, h: c.kind === "ic" ? 40 : 22 }));
    const netIdx = new Map();
    const localSet = new Set();
    netComps.forEach((cis, net) => {
      if (isLocal(net, cis.length)) { localSet.add(net); return; }
      netIdx.set(net, nodes.length); nodes.push({ kind: "net", net, deg: cis.length, port: portNets.has(net) });
    });
    const edges = [];
    comps.forEach((c, ci) => c.nets.forEach((n) => { const ni = netIdx.get(n); if (ni != null) edges.push({ a: ci, b: ni }); }));

    forceLayout(nodes, edges);

    let minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
    nodes.forEach((n) => { if (n.x < minx) minx = n.x; if (n.x > maxx) maxx = n.x; if (n.y < miny) miny = n.y; if (n.y > maxy) maxy = n.y; });
    const offx = 80 - minx, offy = 80 - miny;
    nodes.forEach((n) => { n.x += offx; n.y += offy; });

    m.secs = []; m.hubs = []; m.passes = []; m.wires = []; m.labels = []; m.pulls = []; m.rails = []; m.netNodes = []; m.fullEdges = []; m.flags = [];
    const compNode = new Map();
    nodes.forEach((n) => {
      if (n.kind !== "comp") return;
      compNode.set(n.ci, n);
      const c = comps[n.ci];
      m.hubs.push({ ref: c.ref, label: c.label, part: c.kind === "ic" ? c.part : "", x: n.x - n.w / 2, y: n.y - n.h / 2, w: n.w, h: n.h, cx: n.x, cy: n.y, pins: [], compKind: c.kind });
    });
    nodes.forEach((n) => {
      if (n.kind !== "net") return;
      const pwr = isPowerName(n.net) || isGroundName(n.net);
      m.netNodes.push({ x: n.x, y: n.y, net: n.net, deg: n.deg, port: n.port, pwr, gnd: isGroundName(n.net) });
      m.labels.push({ text: netLeaf(n.net), x: n.x, y: n.y - 11, anchor: "center", net: n.net, link: true, port: n.port });
    });
    edges.forEach((e) => {
      const a = nodes[e.a], b = nodes[e.b];
      m.fullEdges.push({ net: b.net, x1: a.x, y1: a.y, x2: b.x, y2: b.y, pwr: isPowerName(b.net) || isGroundName(b.net) });
    });
    // local (power/ground/high-fanout) nets → small labeled flags stacked beneath each member part.
    comps.forEach((c, ci) => {
      const ln = c.nets.filter((n) => localSet.has(n));
      const node = compNode.get(ci);
      if (!ln.length || !node) return;
      ln.forEach((net, j) => m.flags.push({ x: node.x, y: node.y + node.h / 2 + 10 + j * 11, net, pwr: isPowerName(net) || isGroundName(net), gnd: isGroundName(net), port: portNets.has(net) }));
    });
    m.mapBox = { x: -20, y: -20, w: (maxx - minx) + 200, h: (maxy - miny) + 200 };
  }

  // Force-directed (Fruchterman–Reingold) layout with grid-bucketed repulsion so it
  // stays ~O(n) per iteration on a whole-board graph. Deterministic seed (a jittered
  // grid keyed on node index, no RNG) so the layout is stable across rebuilds.
  function forceLayout(nodes, edges) {
    const N = nodes.length; if (!N) return;
    const k = 64, cell = k * 1.2;
    const iters = N > 700 ? 150 : N > 250 ? 220 : 320;
    const cols = Math.ceil(Math.sqrt(N));
    nodes.forEach((n, i) => { n.x = (i % cols) * k * 1.5 + ((i * 37) % 23) - 11; n.y = Math.floor(i / cols) * k * 1.5 + ((i * 53) % 19) - 9; n.dx = 0; n.dy = 0; });
    let temp = k * 8;
    for (let it = 0; it < iters; it++) {
      const grid = new Map();
      for (let i = 0; i < N; i++) { const n = nodes[i]; n.dx = 0; n.dy = 0; const key = Math.floor(n.x / cell) + "," + Math.floor(n.y / cell); let a = grid.get(key); if (!a) { a = []; grid.set(key, a); } a.push(i); }
      for (let i = 0; i < N; i++) {
        const n = nodes[i], gx = Math.floor(n.x / cell), gy = Math.floor(n.y / cell);
        for (let ox = -1; ox <= 1; ox++) for (let oy = -1; oy <= 1; oy++) {
          const a = grid.get((gx + ox) + "," + (gy + oy)); if (!a) continue;
          for (const j of a) {
            if (j === i) continue;
            let ddx = n.x - nodes[j].x, ddy = n.y - nodes[j].y, d2 = ddx * ddx + ddy * ddy;
            if (d2 < 0.02) { ddx = (i - j) * 0.01 + 0.01; ddy = 0.013; d2 = ddx * ddx + ddy * ddy; }
            const d = Math.sqrt(d2), f = k * k / d;
            n.dx += ddx / d * f; n.dy += ddy / d * f;
          }
        }
      }
      for (const e of edges) {
        const a = nodes[e.a], b = nodes[e.b];
        let ddx = a.x - b.x, ddy = a.y - b.y; const d = Math.hypot(ddx, ddy) || 0.01, f = d * d / k;
        const fx = ddx / d * f, fy = ddy / d * f;
        a.dx -= fx; a.dy -= fy; b.dx += fx; b.dy += fy;
      }
      // Weak gravity toward the centroid keeps edge-less nodes (e.g. decoupling caps
      // whose only nets are power/ground, so they have no routed edges) from drifting off.
      let cx = 0, cy = 0; for (let i = 0; i < N; i++) { cx += nodes[i].x; cy += nodes[i].y; } cx /= N; cy /= N;
      for (let i = 0; i < N; i++) { const n = nodes[i]; n.dx += (cx - n.x) * 0.03; n.dy += (cy - n.y) * 0.03; }
      for (let i = 0; i < N; i++) { const n = nodes[i]; const d = Math.hypot(n.dx, n.dy) || 0.01, mv = Math.min(d, temp); n.x += n.dx / d * mv; n.y += n.dy / d * mv; }
      temp = Math.max(temp * 0.95, k * 0.06);
    }
  }

  // A passive whose two terminals land on two *private* pads of the SAME IC — an
  // inductor across a buck-boost's SW nodes, a series R between two pins — is
  // otherwise drawn floating off to one side with a matching net label at each
  // pad, so the pad↔pad connection is only implied by the shared name. Instead,
  // co-locate the two pads on one side and stand the passive up VERTICALLY
  // between them, joined by two short level wires: the link is drawn, not labeled.
  function bridgeSamePins(m) {
    // net -> every consumer (hub pad or passive terminal). A clean private bridge
    // is a net with exactly two: the IC pad and this passive.
    const uses = new Map();
    const bump = (net, w) => { if (!net) return; let a = uses.get(net); if (!a) { a = []; uses.set(net, a); } a.push(w); };
    m.hubs.forEach((h) => h.pins.forEach((p) => bump(p.net, { hub: h, pin: p })));
    m.passes.forEach((p) => p.term.forEach((t) => bump(t.net, { pass: p })));
    const OUT = 48, PITCH = 40, MINSEP = 30;
    const bridged = [];
    m.passes.forEach((p) => {
      if (p.staged || p.term.length !== 2) return;
      const n0 = p.term[0].net, n1 = p.term[1].net;
      if (!n0 || !n1 || n0 === n1) return;
      if (isGroundName(n0) || isGroundName(n1) || isPowerName(n0) || isPowerName(n1)) return;
      const u0 = uses.get(n0) || [], u1 = uses.get(n1) || [];
      if (u0.length !== 2 || u1.length !== 2) return;       // not a private 2-point net
      const a0 = u0.find((x) => x.hub), a1 = u1.find((x) => x.hub);
      if (!a0 || !a1 || a0.hub !== a1.hub || a0.pin === a1.pin) return;   // both pads, one IC
      bridged.push({ p, hub: a0.hub, pinA: a0.pin, pinB: a1.pin, n0, n1 });
    });
    if (!bridged.length) return;
    const dropNets = new Set(), newWires = [];
    bridged.forEach(({ p, hub, pinA, pinB, n0, n1 }) => {
      dropNets.add(n0); dropNets.add(n1);
      const side = pinA.side, dir = side === "left" ? -1 : 1;
      const edgeX = side === "left" ? hub.x : hub.x + hub.w, center = (pinA.y + pinB.y) / 2;
      // Two adjacent rows around the pads' shared centre, dodging this side's
      // other pins (search a few offsets out; fall back to the centred pair).
      const occ = hub.pins.filter((q) => q !== pinA && q !== pinB && q.side === side).map((q) => q.y);
      let top = center - PITCH / 2;
      for (const off of [0, PITCH, -PITCH, 2 * PITCH, -2 * PITCH]) {
        const t = center - PITCH / 2 + off, b = t + PITCH;
        if (occ.every((y) => Math.abs(y - t) >= MINSEP && Math.abs(y - b) >= MINSEP)) { top = t; break; }
      }
      const bot = top + PITCH, mid = (top + bot) / 2, xline = edgeX + dir * OUT;
      pinA.side = side; pinA.x = edgeX; pinA.y = top; pinA.vx = null; pinA.vy = null;
      pinB.side = side; pinB.x = edgeX; pinB.y = bot; pinB.vx = null; pinB.vy = null;
      p.vertical = true; p.flip = false; p.dir = dir; p.xline = xline; p.y0 = top; p.y1 = bot;
      p.cx = xline; p.cy = mid; p.x = xline - 8; p.w = 16; p.top = top - 4; p.h = PITCH + 8;
      p.term = [{ pin: p.term[0].pin, x: xline, y: top, net: n0 }, { pin: p.term[1].pin, x: xline, y: bot, net: n1 }];
      [[top, n0], [bot, n1]].forEach(([y, net]) => { const pts = [[edgeX, y], [xline, y]]; newWires.push({ net, bus: false, pts, bb: bbOf(pts) }); });
    });
    m.wires = m.wires.filter((w) => !dropNets.has(w.net)).concat(newWires);
    m.labels = m.labels.filter((l) => !dropNets.has(l.net));
  }

  // ── Sheet navigator ──────────────────────────────────────────────────
  // A "sheet" is a navigable page = one authored (section …) of the design. A
  // design with no explicit sections (just instances, maybe (group …) hints) is
  // a single section: the navigator then shows one whole-design sheet rather than
  // splitting per IC. Built after the model so each section box reflects the
  // real, post-layout geometry.
  function countInBox(x, y, w, h) {
    const pad = 8; let c = 0;
    const inside = (cx, cy) => cx >= x - pad && cx <= x + w + pad && cy >= y - pad && cy <= y + h + pad;
    M.hubs.forEach((hh) => { if (!hh.synthetic && inside(hh.cx, hh.cy)) c++; });
    M.passes.forEach((p) => { if (inside(p.cx, p.cy)) c++; });
    return c;
  }
  function buildSheets() {
    sheets = [];
    const authored = scene.authored_sections || [];
    if (!authored.length) return;   // no explicit sections → one whole-design sheet
    // List EVERY authored section (so a freshly-created, still-empty section shows up
    // as a sheet). Attach its laid-out box/count when present — a grid-less section
    // has no box, so it lists + renames/deletes but doesn't zoom-to on select.
    const byName = new Map();
    M.secs.forEach((sc) => byName.set(sc.name, sc));
    authored.forEach((nm) => {
      const sc = byName.get(nm);
      sheets.push(sc
        ? { name: nm, title: nm, box: { x: sc.x, y: sc.y, w: sc.w, h: sc.h }, count: countInBox(sc.x, sc.y, sc.w, sc.h) }
        : { name: nm, title: nm, box: null, count: 0 });
    });
  }
  function buildSheetList() {
    clear(sheetList);
    const whole = document.createElement("div");
    whole.className = "ed-sheet"; whole.dataset.idx = "-1";
    whole.innerHTML = '<span class="num">0</span><span class="nm"></span>';
    whole.querySelector(".nm").textContent = sheets.length ? "Whole board" : (scene.name || "Whole board");
    whole.title = sheets.length ? "" : (scene.name || "");
    whole.onclick = () => fitAll(); sheetList.appendChild(whole);
    sheets.forEach((s, i) => {
      const row = document.createElement("div");
      row.className = "ed-sheet"; row.dataset.idx = String(i);
      const n = i + 1;
      row.innerHTML = `<span class="num">${n <= 9 ? n : "·"}</span><span class="nm"></span><span class="ct">${s.count}</span>`;
      row.querySelector(".nm").textContent = s.name;
      row.title = s.title;
      row.onclick = () => selectSheet(i);
      const tools = mkEl("span", "ed-sheet-tools");
      const rn = mkEl("button", "ed-x", "✎"); rn.title = "Rename sheet";
      rn.onclick = (e) => { e.stopPropagation(); const nm = (prompt("Rename sheet:", s.name) || "").trim(); if (nm) applyRenameSection(s.name, nm); };
      const dl = mkEl("button", "ed-x", "✕"); dl.title = "Delete sheet (must be empty)";
      dl.onclick = (e) => { e.stopPropagation(); applyRemoveSection(s.name); };
      tools.appendChild(rn); tools.appendChild(dl); row.appendChild(tools);
      sheetList.appendChild(row);
    });
    const addRow = mkEl("div", "ed-sheet ed-sheet-add", "+ New sheet");
    addRow.onclick = () => {
      const nm = (prompt("New sheet (section) name:") || "").trim(); if (!nm) return;
      const sub = (prompt("Subtitle (optional):", "") || "").trim();
      applyAddSection(nm, sub);
    };
    sheetList.appendChild(addRow);
    syncSheetUI();
  }
  function selectSheet(i) {
    const s = sheets[i]; if (!s || !s.box) return;
    activeSheet = i;
    fitTo(s.box, 0.08);
    syncSheetUI(); updateStatus();
  }
  function syncSheetUI() { [...sheetList.children].forEach((row) => row.classList.toggle("active", Number(row.dataset.idx) === activeSheet)); }
  function stepSheet(d) { const n = sheets.length; if (!n) return; selectSheet(activeSheet < 0 ? (d > 0 ? 0 : n - 1) : (activeSheet + d + n) % n); }

  // ── Status ───────────────────────────────────────────────────────────
  function updateStatus() {
    const parts = [];
    parts.push(activeSheet >= 0 && sheets[activeSheet] ? "Sheet: " + sheets[activeSheet].name : "Whole board");
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
    // A hub's FULL pin list comes from the scene — every part of a multi-part IC,
    // every pin — not the view's hub block: the global map only carries the drawn
    // (linked) pins, and M.hubs.find() returns just the first part, so reading
    // either would hide most of the component's pins. Resolve each pin's net the
    // same way the layout does (geometric pinWire) so it matches what's drawn.
    const shubs = scene.hubs.filter((x) => x.ref === ref);
    if (shubs.length) {
      const out = [], seen = new Set();
      const take = (h, pn, side) => {
        const key = pn.pins || pn.name; if (!key || seen.has(key)) return; seen.add(key);
        const ex = side === "left" ? h.x : h.x + h.w, v = pinWire(ex, pn.y, side);
        out.push({ pin: (pn.pins || "").split(",")[0], label: pn.name || pn.pins, net: v ? v.net : "" });
      };
      shubs.forEach((h) => { (h.leftPins || []).forEach((pn) => take(h, pn, "left")); (h.rightPins || []).forEach((pn) => take(h, pn, "right")); });
      if (out.length) return out;
    }
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
  // Every net name currently in the design (sorted, de-duped) — the option set
  // for the pin→net comboboxes.
  function allNets() {
    const s = new Set(); const add = (n) => { if (n) s.add(n); };
    // Source from the scene (authoritative, view-independent) so the dropdown
    // offers EVERY design net — the global map's synthetic M only carries the
    // drawn subset, which would otherwise hide most nets while editing there.
    scene.wires.forEach((w) => add(w.net));
    scene.labels.forEach((l) => add(l.text));
    scene.passives.forEach((p) => (p.pins || []).forEach((pn) => add(pn.net)));
    (scene.staged || []).forEach((p) => (p.pins || []).forEach((pn) => add(pn.net)));
    if (M) {
      M.hubs.forEach((h) => h.pins.forEach((p) => add(p.net)));
      M.passes.forEach((p) => (p.term || []).forEach((t) => add(t.net)));
      M.wires.forEach((w) => add(w.net));
      M.labels.forEach((l) => add(l.net));
    }
    return [...s].sort((a, b) => a.localeCompare(b));
  }
  // Attach a net-name combobox to an <input>: a filtered dropdown of existing
  // nets (↑/↓ to move the highlight, Enter to take it) that still accepts a
  // freely-typed new name. With onCommit, Enter/blur/pick writes the change;
  // without it the field is only filled (the Add dialog reads it at submit).
  function netCombo(inp, onCommit) {
    let initial = inp.value || "", hi = -1, pop = null;
    inp.setAttribute("autocomplete", "off");
    const close = () => { if (pop) { pop.remove(); pop = null; } hi = -1; };
    const commit = () => { if (!onCommit) return; const v = inp.value.trim(); if (v && v !== initial) { initial = v; onCommit(v); } };
    function render() {
      document.querySelectorAll(".ed-combo").forEach((e) => { if (e !== pop) e.remove(); });
      const q = inp.value.trim().toLowerCase();
      const list = allNets().filter((n) => n.toLowerCase().includes(q)).slice(0, 60);
      if (!list.length) { close(); return; }
      if (!pop) { pop = mkEl("div", "ed-combo"); document.body.appendChild(pop); }
      pop.innerHTML = "";
      list.forEach((n, i) => {
        const r = mkEl("div", "ed-combo-opt" + (i === hi ? " hi" : ""), n);
        r.addEventListener("mousedown", (e) => { e.preventDefault(); inp.value = n; close(); commit(); if (onCommit) inp.blur(); });
        pop.appendChild(r);
      });
      const b = inp.getBoundingClientRect();
      pop.style.left = b.left + "px"; pop.style.top = (b.bottom + 2) + "px"; pop.style.minWidth = b.width + "px";
    }
    function move(d) {
      if (!pop) { render(); if (!pop) return; }
      const n = pop.children.length; hi = hi < 0 ? (d > 0 ? 0 : n - 1) : (hi + d + n) % n;
      [...pop.children].forEach((c, i) => c.classList.toggle("hi", i === hi));
      pop.children[hi].scrollIntoView({ block: "nearest" });
    }
    inp.addEventListener("focus", render);
    inp.addEventListener("input", () => { hi = -1; render(); });
    inp.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
      else if (e.key === "Enter") {
        if (pop && hi >= 0) { e.preventDefault(); inp.value = pop.children[hi].textContent; }
        close(); commit(); if (onCommit) { e.preventDefault(); inp.blur(); }
      } else if (e.key === "Escape") { if (pop) { e.stopPropagation(); close(); } }
    });
    inp.addEventListener("blur", () => setTimeout(() => { commit(); close(); }, 120));
    return inp;
  }
  function renderInspector() {
    clear(inspector);
    if (selection) { renderPartInspector(selection.ref); return; }
    if (hotNet) { renderNetInspector(hotNet); return; }
    inspector.appendChild(mkEl("div", "ed-insp-empty", "Select a part or net to see and edit its properties — click on the canvas, or double-click to jump straight to editing."));
    renderPortsPanel();   // design-level: declare/drop boundary ports
  }
  // The design's boundary ports (derived from the scene's port-flagged labels) with
  // add/remove controls — shown when nothing is selected (the design-level view).
  function renderPortsPanel() {
    const ports = (scene.ports || []).slice().sort((a, b) => String(a.name).localeCompare(String(b.name)));
    const sec = mkEl("div", "ed-ports");
    sec.appendChild(mkEl("div", "ed-insp-sec", "Ports (" + ports.length + ")"));
    if (!ports.length) sec.appendChild(mkEl("div", "ed-insp-empty", "No boundary ports declared."));
    ports.forEach((p) => {
      const row = mkEl("div", "ed-portrow");
      row.appendChild(mkEl("span", "pn", p.name));
      if (p.dir) row.appendChild(mkEl("span", "ct", p.dir));
      const del = mkEl("button", "ed-x", "✕"); del.title = "Remove port"; del.onclick = () => applyRemovePort(p.name);
      row.appendChild(del); sec.appendChild(row);
    });
    const add = mkEl("button", "ed-btn", "+ Add port");
    add.onclick = () => {
      const net = (prompt("Port net name:") || "").trim(); if (!net) return;
      const dir = ((prompt("Direction (in / out / bidi):", "bidi") || "").trim() || "bidi").toLowerCase();
      applyAddPort(net, dir);
    };
    sec.appendChild(add); inspector.appendChild(sec);
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
    body.appendChild(fieldRow("Ref-des", ref, (v) => applyRefdes(ref, v)));
    // Component / footprint is swappable: an autocompleted field over the library
    // index (POST /api/edit-footprint validates the new family server-side).
    {
      const row = mkEl("div", "ed-fld"); row.appendChild(mkEl("label", null, "Component"));
      const cur = meta.component || "";
      const inp = document.createElement("input"); inp.value = cur; inp.placeholder = "(component)";
      inp.setAttribute("list", "ed-complist"); inp.setAttribute("autocomplete", "off");
      inp.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); inp.blur(); } });
      inp.addEventListener("change", () => { const v = inp.value.trim(); if (v && v !== cur) applyFootprint(ref, v, cur); });
      row.appendChild(inp); body.appendChild(row);
    }
    body.appendChild(fieldRow("Value", meta.value || "", (v) => applyValue(ref, v)));
    const pins = partPins(ref);
    if (pins.length) {
      body.appendChild(mkEl("div", "ed-insp-sec", "Pins → net"));
      pins.forEach((p) => {
        const row = mkEl("div", "ed-pinline");
        const pl = mkEl("span", "pl", p.label); pl.title = "pad " + p.pin; row.appendChild(pl);
        const inp = document.createElement("input"); inp.value = p.net || ""; inp.placeholder = "(unconnected)";
        netCombo(inp, (v) => applyPinNet(ref, p.pin, v));
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
  async function applyFootprint(ref, comp, oldComp) {
    if (!comp || comp === oldComp) return;
    try { await api("POST", `/api/edit-footprint/${DESIGN}`, { ref, component: comp, oldComponent: oldComp, srcOff: srcByRef(ref) }); toast(`${ref} → ${comp}`); await refetch(); }
    catch (err) { toast("Swap failed: " + err.message, true); }
  }
  async function applyRefdes(ref, to) {
    if (!to || to === ref) return;
    try { await api("POST", `/api/rename-refdes/${DESIGN}`, { ref, to, srcOff: srcByRef(ref) }); toast(`${ref} → ${to}`); if (selection) selection.ref = to; await refetch(); }
    catch (err) { toast("Rename failed: " + err.message, true); }
  }
  // Structural authoring (sheets/sections + ports) — each rebuilds via refetch.
  async function applyAddSection(section, subtitle) {
    try { await api("POST", `/api/add-section/${DESIGN}`, subtitle ? { section, subtitle } : { section }); toast("Added sheet " + section); await refetch(); }
    catch (err) { toast("Add sheet failed: " + err.message, true); }
  }
  async function applyRenameSection(from, to) {
    if (!to || to === from) return;
    try { await api("POST", `/api/rename-section/${DESIGN}`, { from, to }); toast(`${from} → ${to}`); await refetch(); }
    catch (err) { toast("Rename failed: " + err.message, true); }
  }
  async function applyRemoveSection(section) {
    try { await api("POST", `/api/remove-section/${DESIGN}`, { section }); toast("Removed sheet " + section); await refetch(); }
    catch (err) { toast("Remove failed: " + err.message, true); }
  }
  async function applyAddPort(net, dir) {
    try { await api("POST", `/api/add-port/${DESIGN}`, { net, dir }); toast(`port ${net} ${dir}`); await refetch(); }
    catch (err) { toast("Add port failed: " + err.message, true); }
  }
  async function applyRemovePort(net) {
    try { await api("POST", `/api/remove-port/${DESIGN}`, { net }); toast("Removed port " + net); await refetch(); }
    catch (err) { toast("Remove port failed: " + err.message, true); }
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

  // Load the component/module library index once (shared by the Add dialog and
  // the inspector's component-swap field) and fill the <datalist> that backs the
  // component autocomplete.
  async function ensureLib() {
    if (!libIndex) {
      try { libIndex = await api("GET", "/api/lib-index"); } catch (e) { libIndex = { components: [], modules: [] }; }
      populateCompDatalist();
    }
    return libIndex;
  }
  function populateCompDatalist() {
    let dl = document.getElementById("ed-complist");
    if (!dl) { dl = mkEl("datalist"); dl.id = "ed-complist"; document.body.appendChild(dl); }
    clear(dl);
    (libIndex && libIndex.components || []).forEach((c) => { const o = document.createElement("option"); o.value = c.name; if (c.footprint) o.label = c.footprint; dl.appendChild(o); });
  }
  // ── Add component (A) ────────────────────────────────────────────────
  async function openAdd() {
    await ensureLib();
    const sheetName = activeSheet >= 0 && sheets[activeSheet] ? sheets[activeSheet].name : "";
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
    const newOpt = document.createElement("option"); newOpt.value = "__new__"; newOpt.textContent = "➕ New section…"; sectionSel.appendChild(newOpt);
    // Picking "New section…" prompts for a name and inserts it as a selected option;
    // the section itself is created (add-section) at submit if it doesn't exist yet.
    sectionSel.addEventListener("change", () => {
      if (sectionSel.value !== "__new__") return;
      const nm = (prompt("New section name:") || "").trim();
      if (!nm) { sectionSel.value = sheetName || ""; return; }
      let opt = [...sectionSel.options].find((o) => o.value === nm);
      if (!opt) { opt = document.createElement("option"); opt.value = nm; opt.textContent = nm + " (new)"; sectionSel.insertBefore(opt, sectionSel.firstChild); }
      sectionSel.value = nm;
    });

    const pinsBox = ov.querySelector("#add-pins");
    function addPinRow(pn, net) {
      const row = document.createElement("div"); row.className = "ed-pinrow";
      row.innerHTML = '<input class="pn" placeholder="pin#"><input placeholder="net">';
      if (pn) row.children[0].value = pn; if (net) row.children[1].value = net;
      netCombo(row.children[1]);
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
      const value = ov.querySelector("#add-value").value.trim(), ref = ov.querySelector("#add-ref").value.trim();
      let section = sectionSel.value; if (section === "__new__") section = "";
      const pins = {};
      [...pinsBox.children].forEach((row) => { const pn = row.children[0].value.trim(), net = row.children[1].value.trim(); if (pn && net) pins[pn] = net; });
      const body = chosen.kind === "module" ? { kind: "module", component: chosen.name, name: chosen.name, args: value, import: true } : { component: chosen.name, value, section, ref: ref || undefined, pins, import: true };
      goBtn.disabled = true; goBtn.textContent = "Adding…";
      try {
        // Create the target section first if it's a new one, so the part lands in it
        // instead of falling back to the design root.
        if (section && !(scene.authored_sections || []).includes(section)) await api("POST", `/api/add-section/${DESIGN}`, { section });
        await api("POST", `/api/add-instance/${DESIGN}`, body); toast("Added " + chosen.name); ov.remove(); await refetch();
      } catch (err) { toast("Add failed: " + err.message, true); goBtn.disabled = false; goBtn.textContent = "Add"; }
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
      <tr><td><kbd>N</kbd></td><td>Toggle drawn connections vs. name labels: straight lines across the channel for device-to-device nets, and a passive stood up <b>vertically</b> between the two pads it bridges on one IC (e.g. an inductor across the SW pins)</td></tr>
      <tr><td><kbd>G</kbd></td><td>Fan out the selected IC — ring it with dashed <b>ghost</b> copies of every IC it connects to point-to-point, one straight wire each with the net name above it (the rest of the board dims). Differential pairs are drawn coupled in violet. Click a ghost to hop the focus to it; <kbd>Esc</kbd> exits.</td></tr>
      <tr><td><kbd>Shift</kbd>+<kbd>G</kbd></td><td>Connection map — rebuild the board as a grid of cells for the fewest anchor ICs that cover every point-to-point connection (each drawn once; low-degree ICs collapse into proxies inside a neighbour's cell, nothing overlaps). Every block — anchor or proxy — is selectable and editable in place.</td></tr>
      <tr><td><kbd>P</kbd></td><td>Power layer — overlay each IC card's power/ground rail nodes (the connection map normally hides rails). One pill per rail, <b>▲</b> for a supply / <b>⏚</b> for ground, with a <b>⎓N</b> badge counting its decoupling caps. Click a node to select that net so the inspector lists and edits its decoupling. (Turns the map on if it isn't already.)</td></tr>
      <tr><td><kbd>Esc</kbd></td><td>Deselect / close</td></tr>
      <tr><td>click part / net</td><td>Show its properties in the left inspector (edit value, rename net, rewire pins, copy, delete). The pin→net fields suggest existing nets — <kbd>↑</kbd>/<kbd>↓</kbd> + <kbd>Enter</kbd> to pick one, or just type a new name.</td></tr>
      <tr><td><b>double-click</b></td><td>Select it and jump straight to the first editable field in the inspector</td></tr>
      <tr><td>scroll · drag empty</td><td>Zoom · pan</td></tr>
      </table><div class="ed-actions"><button class="ed-btn" id="keys-close">Close</button></div></div>`;
    document.body.appendChild(ov);
    ov.addEventListener("mousedown", (e) => { if (e.target === ov) ov.remove(); });
    ov.querySelector("#keys-close").onclick = () => ov.remove();
  }

  // Toggle device↔device net lines (rebuilds the model so re-siding re-applies).
  function toggleNets() { showNets = !showNets; syncNetsBtn(); buildModel(); scheduleDraw(); }

  // Ghost-partner fan-out: focus the selected IC and ring it with dashed proxies
  // of every IC it connects to point-to-point. Toggles off if already on.
  function toggleGhost() {
    if (ghostRef) { ghostRef = null; buildModel(); syncGhostBtns(); scheduleDraw(); return; }
    if (!selection || !isHubRef(selection.ref)) { toast("Select an IC first, then press G to fan out its direct connections.", true); return; }
    ghostAll = false; ghostRef = selection.ref; buildModel();
    if (M.ghostBox) { fitTo(M.ghostBox, 0.08); toast("Ghosting " + ghostRef + "'s direct connections — click a ghost to hop to it, Esc to exit"); }
    else { ghostRef = null; toast(selection.ref + " has no direct IC-to-IC nets.", true); }
    syncGhostBtns(); updateStatus(); scheduleDraw();
  }
  // The connection map is the only view — the Map button just reframes the whole map
  // (it never drops back to a base layout). Sub-modes (single-IC ghost, full graph) exit
  // back here, not to a base page.
  function toggleGhostAll() {
    ghostAll = true; ghostRef = null; fullMap = false; selection = null; hotNet = null; activeSheet = -1;
    buildModel();
    if (M.mapBox) fitTo(M.mapBox, 0.03);
    syncGhostBtns(); syncFullBtn(); renderInspector(); updateStatus(); scheduleDraw();
  }
  // Full connection map (U): rebuild the ENTIRE netlist as one force-directed graph —
  // every part and every net, nothing hidden. Mutually exclusive with the other modes.
  function toggleFull() {
    fullMap = !fullMap;
    if (fullMap) { ghostAll = false; ghostRef = null; showPower = false; selection = null; hotNet = null; activeSheet = -1; }
    else { ghostAll = true; }                                  // exit full → back to the connection map
    buildModel();
    if (fullMap) {
      if (M.mapBox) { fitTo(M.mapBox, 0.04); toast("Full map — the whole netlist as one connectivity graph: every part + every net. Click a net dot or a part to select/edit; Esc exits."); }
      else { fullMap = false; ghostAll = true; buildModel(); toast("Nothing to lay out.", true); }
    } else if (M.mapBox) fitTo(M.mapBox, 0.03);
    syncGhostBtns(); syncPowerBtn(); syncFullBtn(); renderInspector(); updateStatus(); scheduleDraw();
  }
  // Power layer (P): overlay each IC cell's power/ground rail nodes. The layer only
  // renders on the connection map, so turning it on enters the map if not already there.
  function togglePower() {
    showPower = !showPower;
    if (showPower && !ghostAll) { toggleGhostAll(); }      // toggleGhostAll rebuilds with showPower now true
    else { buildModel(); scheduleDraw(); }
    syncPowerBtn();
    if (ghostAll) toast(showPower ? "Power layer on — click a rail node to see/edit its decoupling." : "Power layer off.", true);
  }
  // Click a ghost proxy → re-focus the fan-out on that real partner (walk the graph).
  function jumpToGhost(ref) {
    ghostAll = false; ghostRef = ref; selection = { kind: "hub", ref }; hotNet = null; deleteArmed = false;
    buildModel(); if (M.ghostBox) fitTo(M.ghostBox, 0.08);
    syncGhostBtns(); renderInspector(); updateStatus(); scheduleDraw();
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
      case "n": case "N": toggleNets(); break;
      case "g": case "G": (e.shiftKey ? toggleGhostAll : toggleGhost)(); break;
      case "p": case "P": togglePower(); break;
      case "u": case "U": toggleFull(); break;
      case "?": toggleKeys(); break;
      case "Escape": deselect(); break;
      case "[": stepSheet(-1); break;
      case "]": stepSheet(1); break;
      case "0": fitAll(); break;
      default: if (e.key >= "1" && e.key <= "9") { const i = +e.key - 1; if (sheets[i]) selectSheet(i); }
    }
  });

  // ── Toolbar ──────────────────────────────────────────────────────────
  const tools = document.createElement("div");
  tools.id = "ed-tools";
  tools.innerHTML = `<button id="tool-add" title="Add (A)">+ Add</button><button id="tool-nets" title="Draw connections instead of name labels: device-to-device channel wires + a passive stood vertically between two pads it bridges on one IC (N)">Nets</button><button id="tool-ghost" title="Fan out the selected IC: ring it with dashed ghost copies of every IC it connects to point-to-point, one straight wire each. Click a ghost to hop to it. (G)">Fan-out</button><button id="tool-ghost-all" title="Connection map: the fewest anchor ICs that cover every point-to-point connection, each in its own region; low-degree ICs collapse into ghosts so nothing's drawn twice (Shift+G)">Map</button><button id="tool-power" title="Power layer: overlay each IC's power/ground rail nodes on the connection map; click a node to see/edit its decoupling caps (P)">Power</button><button id="tool-full" title="Full map: the entire netlist as one force-directed graph — every part and every net, nothing hidden. Click a net dot or part to select/edit (U)">Full</button><button id="tool-fit" title="Fit (F)">Fit</button><button id="tool-keys" title="Keys (?)">?</button>`;
  wrap.appendChild(tools);
  tools.querySelector("#tool-add").onclick = openAdd;
  tools.querySelector("#tool-nets").onclick = toggleNets;
  tools.querySelector("#tool-ghost").onclick = toggleGhost;
  tools.querySelector("#tool-ghost-all").onclick = toggleGhostAll;
  tools.querySelector("#tool-power").onclick = togglePower;
  tools.querySelector("#tool-full").onclick = toggleFull;
  tools.querySelector("#tool-fit").onclick = () => { if (activeSheet >= 0) selectSheet(activeSheet); else fitAll(); };
  tools.querySelector("#tool-keys").onclick = toggleKeys;
  function syncNetsBtn() { const b = document.getElementById("tool-nets"); if (b) b.classList.toggle("on", showNets); }
  function syncGhostBtns() { const b = document.getElementById("tool-ghost"); if (b) b.classList.toggle("on", !!ghostRef); const a = document.getElementById("tool-ghost-all"); if (a) a.classList.toggle("on", ghostAll); }
  function syncPowerBtn() { const b = document.getElementById("tool-power"); if (b) b.classList.toggle("on", showPower); }
  function syncFullBtn() { const b = document.getElementById("tool-full"); if (b) b.classList.toggle("on", fullMap); }
  syncNetsBtn(); syncGhostBtns(); syncPowerBtn(); syncFullBtn();
  isoBox.addEventListener("change", scheduleDraw);

  // ── ERC / validation surface ─────────────────────────────────────────
  // The design is saved after every surgical edit, so GET /api/erc reflects the
  // live design. We show a health chip + a click-through violations panel, and
  // paint a warning ring on offending parts / tint offending net labels.
  const ercChip = document.getElementById("ed-erc-chip");
  const ercPanel = document.getElementById("ed-erc-panel");
  if (ercChip) ercChip.addEventListener("click", () => { ercOpen = !ercOpen; renderErcChip(); renderErcPanel(); });
  const ercRank = { error: 3, warning: 2, info: 1 };
  const ercTok = (s) => (s === "error" ? "err" : (s || "info"));   // css class / paint token
  const ercColor = (t) => (t === "err" ? "#f85149" : "#e3b341");
  async function fetchErc() {
    try { const data = await api("GET", `/api/erc/${DESIGN}`); ercData = Array.isArray(data) ? data : []; }
    catch (e) { ercData = []; }
    ercByRef = new Map(); ercByNet = new Map();
    const worse = (m, k, sev) => { const cur = m.get(k); if (!cur || ercRank[sev] > ercRank[cur]) m.set(k, ercTok(sev)); };
    for (const v of ercData) {
      if (v.severity !== "error" && v.severity !== "warning") continue;   // info → panel only, no canvas paint
      if (v.ref) worse(ercByRef, v.ref, v.severity);
      if (v.net) worse(ercByNet, v.net, v.severity);
    }
    renderErcChip(); renderErcPanel(); scheduleDraw();
  }
  function renderErcChip() {
    if (!ercChip) return;
    const errs = ercData.filter((v) => v.severity === "error").length;
    const warns = ercData.filter((v) => v.severity === "warning").length;
    ercChip.classList.remove("pass", "warn", "err");
    ercChip.classList.toggle("on", ercOpen);
    if (errs) { ercChip.classList.add("err"); ercChip.textContent = errs + (errs === 1 ? " error" : " errors") + (warns ? " · " + warns + " ⚠" : ""); }
    else if (warns) { ercChip.classList.add("warn"); ercChip.textContent = warns + (warns === 1 ? " warning" : " warnings"); }
    else { ercChip.classList.add("pass"); ercChip.textContent = "✓ ERC"; }
  }
  function renderErcPanel() {
    if (!ercPanel) return;
    ercPanel.hidden = !ercOpen;
    if (!ercOpen) return;
    clear(ercPanel);
    if (!ercData.length) { ercPanel.appendChild(mkEl("div", "empty", "✓ No electrical-rule violations.")); return; }
    const order = { error: 0, warning: 1, info: 2 };
    const rows = ercData.slice().sort((a, b) => (order[a.severity] ?? 3) - (order[b.severity] ?? 3));
    let curSev = null;
    rows.forEach((v) => {
      if (v.severity !== curSev) { curSev = v.severity; ercPanel.appendChild(mkEl("div", "h", (v.severity || "info") + "s")); }
      const row = mkEl("div", "ed-erc-row " + ercTok(v.severity));
      row.appendChild(mkEl("span", "dot"));
      const tgt = v.ref || v.net;
      if (tgt) row.appendChild(mkEl("span", "tgt", tgt));
      row.appendChild(mkEl("span", "msg", v.message || v.kind || ""));
      if (v.kind) row.title = v.kind;
      if (v.ref) row.onclick = () => { if (isHubRef(v.ref) || (M && M.passes.some((p) => p.ref === v.ref))) select(isHubRef(v.ref) ? "hub" : "pass", v.ref); };
      else if (v.net) row.onclick = () => highlightNetToggle(v.net);
      ercPanel.appendChild(row);
    });
  }

  // ── Refetch / live reload ────────────────────────────────────────────
  function rebuildScene() { buildModel(); buildSheets(); buildSheetList(); renderInspector(); scheduleDraw(); }
  async function refetch() {
    try {
      const data = await api("GET", `/api/editor-scene/${DESIGN}`);
      if (data && data.error) { toast("Reload: " + data.error, true); return; }
      scene = data; rebuildScene(); fetchErc();
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
  fetchErc();
  ensureLib();
  // Open straight into the map (the default surface), framing ?focus=<ref|net|chain-key>
  // — or #<focus> — when given, so a link lands exactly where you want with no clicks.
  const bootFocus = (() => { try { return new URLSearchParams(location.search).get("focus") || (location.hash ? decodeURIComponent(location.hash.slice(1)) : ""); } catch (e) { return ""; } })();
  requestAnimationFrame(() => {
    if (ghostAll && bootFocus && focusTarget(bootFocus)) { /* framed the requested cell/chain */ }
    else if (ghostAll && M.mapBox) fitTo(M.mapBox, 0.03);
    else fitAll();
    updateStatus(); requestAnimationFrame(frame);
  });
})();
