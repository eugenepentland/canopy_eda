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
  const SPOKE_SYM = 22; // side-spoke passive symbol length (shared by map layout + draw + hit-test)
  const GLANCE_S = 0.30; // world→px scale below which the map draws as glance chips (bands + one chip per cell)

  // ── State ────────────────────────────────────────────────────────────
  let cam = { x: 0, y: 0, w: 1000, h: 800 };
  let M = null;                  // built scene model
  let activeSheet = -1;          // -1 = whole board
  let selection = null;          // {kind:'hub'|'pass', ref}
  let hotNet = null;
  let clip = null;               // copy/paste clipboard: {ref, src}
  let hoverChip = null;          // net-partner chip under the cursor (draws its reveal wire)
  const pinnedChips = new Set(); // chips clicked to keep their reveal wire on
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
    // The connection map IS the view: rebuild the board as a grid of
    // self-contained per-IC cells (throwing the derived base layout away).
    buildGlobalMap(m);
    // Connection ports for snap (net-bearing): pins, labels, wire vertices.
    // Ghost proxies are view-only — exclude them from snap targets.
    m.hubs.forEach((h) => { if (h.ghost) return; h.pins.forEach((p) => { if (p.net) addPort(m, p.x, p.y, p.net, "pin", h.ref, p.pin); }); });
    m.labels.forEach((l) => { if (l.net) addPort(m, l.x, l.y, l.net, "label"); });
    m.wires.forEach((w) => { if (w.net) w.pts.forEach((p) => addPort(m, p[0], p[1], w.net, "wire")); });
    addStaged(m);                // just-added, not-yet-wired parts stay visible + draggable on the map
    firstBuild = false;
    pinnedChips.clear(); hoverChip = null;          // chip objects are rebuilt → drop stale reveal pins
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
    if (M.mapBox) fitTo(M.mapBox, 0.03);
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
    // A canon inline part (chain filter/pad) has no cell of its own — its inline box is the target.
    if (!hit.length) hit = (M.hubs || []).filter((h) => h.canon && (h.ref.toLowerCase() === w || (h.ref.split("/").pop() || "").toLowerCase() === w));
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
    const iso = isoBox.checked && aSheet && aSheet.box;
    const sec = iso ? aSheet.box : null;
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

    // Band containers (Power / multi-cell sections) — the wayfinding layer.
    const drawBands = (fs) => (M.bands || []).forEach((b) => {
      if (!boxVis(b.x, b.y, b.x + b.w, b.y + b.h)) return;
      ctx.strokeStyle = b.power ? "#3a3423" : "#1d2733"; ctx.lineWidth = sw(1.6);
      roundRect(b.x, b.y, b.w, b.h, 10); ctx.stroke();
      ctx.fillStyle = b.power ? C.rail : C.secLabel; ctx.font = "600 " + fs + "px sans-serif";
      ctx.textAlign = "left"; ctx.textBaseline = "middle";
      ctx.fillText(b.name, b.x + 16, b.y + Math.max(24, fs * 0.75));
    });

    // Far-zoom glance: the whole board as titled bands + one chip per cell —
    // "fit all" reads like a block diagram; zoom in (or double-click a chip)
    // for the full detail.
    if (s < GLANCE_S && M.mapBox) {
      drawBands(Math.min(150, 20 / s));
      const cfs = 14 / s;
      M.secs.forEach((sc) => {
        if (!boxVis(sc.x, sc.y, sc.x + sc.w, sc.y + sc.h)) return;
        ctx.fillStyle = C.hub; ctx.strokeStyle = C.hubStroke; ctx.lineWidth = sw(1.4);
        roundRect(sc.x, sc.y, sc.w, sc.h, 8); ctx.fill(); ctx.stroke();
        const label = sc.ref || sc.name || "";
        ctx.fillStyle = C.hubLabel; ctx.textAlign = "center"; ctx.textBaseline = "middle";
        fitFont(label, sc.w * 0.86, Math.min(sc.h * 0.34, cfs), 4, "600");
        ctx.fillText(label, sc.cx, sc.cy - (sc.part ? sc.h * 0.1 : 0));
        if (sc.part) {
          ctx.fillStyle = C.pinName;
          fitFont(sc.part, sc.w * 0.86, Math.min(sc.h * 0.2, cfs * 0.6), 3);
          ctx.fillText(sc.part, sc.cx, sc.cy + sc.h * 0.18);
        }
      });
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      return;
    }
    drawBands(Math.min(40, Math.max(20, 12 / s)));

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
      if (w.via) {                                     // in-line element in the path: leads + symbol/chip.
        // Draw even when the net is hot — highlighting one side must NOT make the part vanish.
        const dev = w.via.device, half = dev ? 16 : 11;
        const seld = selection && w.via.ref && selection.ref === w.via.ref;   // selected in inspector → tint the part
        const p0 = w.pts[0], p1 = w.pts[w.pts.length - 1], yy = p0[1], cxw = (p0[0] + p1[0]) / 2;
        ctx.strokeStyle = hot ? C.hot : (w.diff ? C.diff : C.link); ctx.lineWidth = sw(hot ? 2 : (w.diff ? 1.5 : 1.6));
        ctx.beginPath(); ctx.moveTo(p0[0], yy); ctx.lineTo(cxw - half, yy); ctx.moveTo(cxw + half, yy); ctx.lineTo(p1[0], yy); ctx.stroke();
        if (dev) {                                      // pass-through device (level shifter): a filled chip
          const amp = half * 0.5; ctx.fillStyle = C.ghost; ctx.strokeStyle = seld ? C.sel : C.ghostStroke; ctx.lineWidth = sw(seld ? 2.4 : 1.6);
          roundRect(cxw - half, yy - amp, 2 * half, 2 * amp, sw(2)); ctx.fill(); ctx.stroke();
        } else {
          // The part BRIDGES two nets — it isn't ON one — so a hot net never tints it (only selection does).
          ctx.strokeStyle = seld ? C.sel : C.passStroke; ctx.lineWidth = sw(seld ? 2.2 : 1.5);
          symbol(w.via.type || "box", cxw - half, cxw + half, yy, sw);
        }
        if (w.via.value && 11 * s >= 7) {               // value caption BELOW the symbol (net labels sit above)
          ctx.fillStyle = C.passText; ctx.font = "10px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "top";
          ctx.fillText(w.via.value.length > 9 ? w.via.value.slice(0, 8) + "…" : w.via.value, cxw, yy + 7);
          ctx.textBaseline = "middle";
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
      const seld = selection && p.ref && selection.ref === p.ref;   // selected in inspector → tint the spoke
      if (p.axis === "h") {                                          // side spoke: symbol inline on a horizontal wire
        const dir = p.dir || 1, y = p.y;
        const sA = p.x - SPOKE_SYM / 2, sB = p.x + SPOKE_SYM / 2;
        const jx = p.jx != null ? p.jx : (dir > 0 ? sA - 8 : sB + 8), tx = p.tx != null ? p.tx : (dir > 0 ? sB + 14 : sA - 14);
        ctx.strokeStyle = seld ? C.sel : C.passStroke; ctx.lineWidth = sw(seld ? 2.2 : 1.4);
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
      ctx.strokeStyle = seld ? C.sel : C.passStroke; ctx.lineWidth = sw(seld ? 2.2 : 1.4);
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

    // Labels — net-name stubs / ports as text; grounds as a real earth symbol
    // (node dot on the wire, rake pointing down, caption below). The symbol
    // draws at any zoom; only its caption obeys the LOD text cutoff.
    {
      const showText = 11 * s >= 7;
      M.labels.forEach((l) => {
        if (!ptVis(l.x, l.y)) return;
        ctx.globalAlpha = (l.link || inBox(l.x, l.y)) ? 1 : 0.12;
        const hot = hotNet && l.net === hotNet;
        if (l.ground) { drawGround(l.x, l.y, hot, sw, showText && !/^gnd$/i.test(l.text || ""), l.text); return; }
        if (!showText) return;
        const lev = ercByNet.get(l.net);                            // ERC-flagged net → tint its label
        ctx.fillStyle = hot ? C.hot : lev ? ercColor(lev) : l.diff ? C.diff : l.link ? C.link : l.port ? C.labelPort : C.labelNet;
        ctx.textAlign = l.anchor === "start" ? "left" : l.anchor === "end" ? "right" : "center";
        ctx.textBaseline = "middle";
        if (l.w) fitFont(l.text, l.w, 11, 6); else ctx.font = "11px sans-serif";   // shrink a net label wider than its line
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
      const seldHub = selection && selection.ref === h.ref;
      if (h.tp) {
        // Test point: an open pad circle with a centre dot + stem to its wire —
        // the classic TP glyph — with the ref reading to its left. The small
        // box (h.x/y/w/h) stays as the hit-test bounds.
        const col = seldHub ? C.sel : C.passStroke;
        ctx.strokeStyle = col; ctx.lineWidth = sw(seldHub ? 2.4 : 1.6);
        ctx.beginPath(); ctx.arc(h.cx + ox, h.cy + oy, 5.5, 0, 7); ctx.stroke();
        ctx.beginPath(); ctx.arc(h.cx + ox, h.cy + oy, sw(1.8), 0, 7); ctx.fillStyle = col; ctx.fill();
        line(h.cx + 5.5 + ox, h.cy + oy, h.x + h.w + ox, h.cy + oy);
        if (11 * s >= 7) { ctx.fillStyle = C.hubLabel; ctx.font = "600 11px sans-serif"; ctx.textAlign = "right"; ctx.fillText(h.label, h.x - 5 + ox, h.cy + oy); }
      } else {
      // body — a ghost proxy is dashed + muted so it reads as a reference, not a
      // real placement; a `canon` inline part (a chain filter/pad whose only
      // drawing is this one) is solid like any real part, with its ground rake.
      const ghosty = h.ghost && !h.canon;
      ctx.fillStyle = ghosty ? C.ghost : C.hub;
      ctx.strokeStyle = seldHub ? C.sel : (ghosty ? C.ghostStroke : C.hubStroke);
      ctx.lineWidth = sw(seldHub ? 3 : 2);
      if (ghosty) ctx.setLineDash([sw(6), sw(4)]);
      roundRect(h.x + ox, h.y + oy, h.w, h.h, sw(4)); ctx.fill(); ctx.stroke();
      ctx.setLineDash([]);
      if (h.canon && h.gnd) drawGround(h.cx + ox, h.y + h.h + oy, false, sw, false, "");
      const ev = h.terminal ? null : ercByRef.get(h.ref);            // ERC warning ring
      if (ev) { ctx.strokeStyle = ercColor(ev); ctx.lineWidth = sw(2); ctx.setLineDash([sw(3), sw(3)]); roundRect(h.x + ox - 3, h.y + oy - 3, h.w + 6, h.h + 6, sw(5)); ctx.stroke(); ctx.setLineDash([]); }
      if (15 * s >= 8) {
        ctx.fillStyle = ghosty ? C.ghostLabel : C.hubLabel; ctx.textAlign = "center";
        fitFont(h.label, h.w - 14, 15, 8, "600");       // shrink refdes/label to fit the box width
        ctx.fillText(h.label, h.cx + ox, h.y + oy + (h.part ? 15 : 16));
        if (h.part && 11 * s >= 7) {                    // second line: component / part number — shrunk to fit, not truncated
          ctx.fillStyle = C.pinName;
          fitFont(h.part, h.w - 14, 11, 7);
          ctx.fillText(h.part, h.cx + ox, h.y + oy + 30);
        }
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

    // Net-partner chips: a high-fanout / multi-drop net's other devices, anchored to the
    // pin as small ghost chips. Hover (hoverChip) or click-to-pin (pinnedChips) one and the
    // real connection draws to that device + flashes it. The reveal wire draws first (under
    // the chips, over the map); the chips draw last so they sit on top of the band.
    if (M.chips && M.chips.length) {
      const drawReveal = (c, strong) => {
        const t = chipTargetHub(c); if (!t) return;
        ctx.strokeStyle = C.hot; ctx.lineWidth = sw(strong ? 2.3 : 1.7);
        const mx = (c.hx + t.px) / 2;                                  // straight H-V-H elbow (schematic style, no diagonals)
        ctx.beginPath(); ctx.moveTo(c.hx, c.hy); ctx.lineTo(mx, c.hy); ctx.lineTo(mx, t.py); ctx.lineTo(t.px, t.py); ctx.stroke();
        ctx.setLineDash([sw(5), sw(4)]); ctx.lineWidth = sw(2);
        roundRect(t.hub.x, t.hub.y, t.hub.w, t.hub.h, sw(5)); ctx.stroke(); ctx.setLineDash([]);
      };
      pinnedChips.forEach((c) => { if (c !== hoverChip) drawReveal(c, false); });
      if (hoverChip && !hoverChip.overflow) drawReveal(hoverChip, true);
      const ctext = 10 * s >= 7;
      M.chips.forEach((c) => {
        if (!boxVis(c.x, c.y, c.x + c.w, c.y + c.h)) return;
        const on = c === hoverChip || pinnedChips.has(c) || (hotNet && c.net === hotNet);
        ctx.fillStyle = on ? "#26344a" : C.ghost;
        ctx.strokeStyle = on ? C.hot : (c.overflow ? "#33414f" : C.ghostStroke);
        ctx.lineWidth = sw(on ? 1.6 : 1);
        roundRect(c.x, c.y, c.w, c.h, sw(4)); ctx.fill(); ctx.stroke();
        if (ctext) {
          ctx.fillStyle = on ? C.hot : C.ghostLabel;
          ctx.font = "10px ui-monospace, monospace"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
          ctx.fillText(c.text, c.x + c.w / 2, c.y + c.h / 2);
        }
      });
      ctx.textBaseline = "middle";
    }

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
  // Shrink the font so `text` fits within `maxW` world-units (down to `floor`px), for labels
  // pinned to a fixed span — a net line, a component box. Sets ctx.font to the fitted
  // "[weight ]<px>px sans-serif" and returns the px used. maxW<=0 ⇒ keep base size.
  function fitFont(text, maxW, px, floor, weight) {
    const pre = weight ? weight + " " : "";
    ctx.font = pre + px + "px sans-serif";
    if (!(maxW > 0)) return px;
    const tw = ctx.measureText(text).width;
    if (tw <= maxW) return px;
    const p = Math.max(floor || 6, px * (maxW / tw));
    ctx.font = pre + p + "px sans-serif";
    return p;
  }
  // Usable text width of a wire segment between world-x a and b (its length minus padding).
  function segW(a, b) { return Math.max(8, Math.abs(b - a) - 10); }

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
    // A proxy box is a first-class, selectable+editable copy of the real
    // component (click it → inspector, like any part).
    for (const h of M.hubs) if (h.ghost && !h.terminal && x >= h.x && x <= h.x + h.w && y >= h.y && y <= h.y + h.h) return { t: "part", ref: h.partnerRef || h.ref, kind: "hub", ghost: true };
    for (const h of M.hubs) { if (h.synthetic) continue; if (x >= h.x && x <= h.x + h.w && y >= h.y && y <= h.y + h.h) return { t: "part", ref: h.ref, kind: "hub" }; }
    for (const c of (M.chips || [])) if (x >= c.x && x <= c.x + c.w && y >= c.y && y <= c.y + c.h) return { t: "chip", chip: c };
    for (const p of M.passes) if (x >= p.x && x <= p.x + p.w && y >= p.top && y <= p.top + p.h) return { t: "part", ref: p.ref, kind: "pass" };
    for (const w of M.wires) for (let i = 1; i < w.pts.length; i++) if (distToSeg(x, y, w.pts[i - 1], w.pts[i]) < tw) return { t: "net", net: w.net };
    for (const l of M.labels) if (Math.hypot(l.x - x, l.y - y) < tl) return { t: "net", net: l.net };
    return { t: "empty" };
  }
  // Resolve a chip's partner device → its hub box + the pin (on the chip's net) the reveal
  // wire should land on. Prefers the real cell; falls back to a ghost proxy of that ref.
  function chipTargetHub(c) {
    if (!c || !c.target || !M) return null;
    let hub = null;
    for (const h of M.hubs) { if (!h.synthetic && h.ref === c.target) { hub = h; break; } }
    if (!hub) for (const h of M.hubs) { if (h.partnerRef === c.target || h.ref === c.target) { hub = h; break; } }
    if (!hub) return null;
    let px = hub.cx, py = hub.cy, bd = Infinity;
    for (const p of (hub.pins || [])) { if (p.net !== c.net) continue; const d = Math.hypot(p.x - c.hx, p.y - c.hy); if (d < bd) { bd = d; px = p.vx != null ? p.vx : p.x; py = p.vy != null ? p.vy : p.y; } }   // bus pins carry a lead (vx/vy) — connect the reveal to the lead END so it's continuous
    return { hub, px, py };
  }
  function pickChip(x, y) {
    const tw = 4 / scale();
    for (const c of (M && M.chips ? M.chips : [])) if (x >= c.x - tw && x <= c.x + c.w + tw && y >= c.y - tw && y <= c.y + c.h + tw) return c;
    return null;
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
      else if (h.t === "part") { if (h.ghost) revealGhostBus(h.ref); else pinnedChips.clear(); select(h.kind, h.ref); }
      else if (h.t === "chip") toggleChipPin(h.chip);
      else if (h.t === "net") highlightNetToggle(h.net);
      else deselect();
    }
    mode = null; down = null;
  });
  // Hover (no button down): light the net-partner chip under the cursor so its reveal
  // wire draws. Cheap box-scan, only when the map has chips.
  canvas.addEventListener("pointermove", (e) => {
    if (down) return;
    const w = (M && M.chips && M.chips.length) ? worldFromEvent(e) : null;
    const c = w ? pickChip(w[0], w[1]) : null;
    if (c !== hoverChip) { hoverChip = c; canvas.style.cursor = c ? "pointer" : ""; scheduleDraw(); }
  });
  canvas.addEventListener("pointerleave", () => { if (hoverChip) { hoverChip = null; canvas.style.cursor = ""; scheduleDraw(); } });
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
    const w = worldFromEvent(e);
    if (scale() < GLANCE_S) {                        // glance chip → zoom into that cell
      const sec = (M.secs || []).find((sc) => w[0] >= sc.x && w[0] <= sc.x + sc.w && w[1] >= sc.y && w[1] <= sc.y + sc.h);
      if (sec) { fitTo(sec, 0.12); return; }
    }
    const h = pick(w[0], w[1]);
    if (h.t === "net" || (h.t === "pin" && h.net)) { setHotNet(h.net); focusInspectorPrimary(); }
    else if (h.t === "part" && h.ghost) { select(h.kind, h.ref); focusTarget(h.ref); }   // proxy → frame the part's own region
    else if (h.t === "part") { select(h.kind, h.ref); focusInspectorPrimary(); }         // real part → focus its value for editing
  });

  // Part and net are mutually exclusive in the inspector: selecting one clears
  // the other so the panel always reflects a single subject.
  function select(kind, ref) { selection = { kind, ref }; hotNet = null; deleteArmed = false; renderInspector(); updateStatus(); scheduleDraw(); }
  function deselect() { selection = null; hotNet = null; deleteArmed = false; pinnedChips.clear(); renderInspector(); updateStatus(); scheduleDraw(); }
  function highlightNetToggle(net) { if (!net) return; hotNet = hotNet === net ? null : net; selection = null; deleteArmed = false; renderInspector(); updateStatus(); scheduleDraw(); }
  // Click a net-partner chip → pin its reveal wire on (survives mouse-move); click again to
  // unpin. The "+N" overflow chip has no single target, so it just highlights the whole net.
  function toggleChipPin(c) {
    if (!c) return;
    if (c.overflow) { highlightNetToggle(c.net); return; }
    if (pinnedChips.has(c)) pinnedChips.delete(c); else pinnedChips.add(c);
    scheduleDraw();
  }
  // Click a ghost → pin (reveal) every bus line landing on it, so all its yellow connections
  // (e.g. the LMX2595 ghost's SPI_MOSI + SPI_SCK) draw at once — EXCLUSIVELY: this replaces any
  // other ghost's reveal so only one part is highlighted at a time. Re-clicking a ghost whose
  // lines are already the sole reveal toggles it back off.
  function revealGhostBus(ref) {
    const cs = (M.chips || []).filter((c) => c.target === ref && !c.overflow);
    const allOn = cs.length > 0 && pinnedChips.size === cs.length && cs.every((c) => pinnedChips.has(c));
    pinnedChips.clear();
    if (!allOn) cs.forEach((c) => pinnedChips.add(c));
    scheduleDraw();
  }
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
  // A 2-port device names its signal pins with an IN/OUT suffix (RFIN↔RFOUT,
  // ATTNIN↔ATTNOUT, INPUT↔OUTPUT). Given one pin's function name, the twin's expected
  // name (upper-case), or null. This is the ONLY way to hop THROUGH a sealed-module chip
  // whose internal coupling lands its input on a module-local net the chain key can't
  // see — so it's a fallback tried only after the net-name conventions. Requires a
  // non-empty base (so a bare power "IN"/"OUT" never pairs) and the twin pin to exist.
  function pinIoTwin(name) { const m = /^(.+?)(IN|OUT)$/i.exec(String(name || "")); return m ? (m[1] + (m[2].toUpperCase() === "IN" ? "OUT" : "IN")).toUpperCase() : null; }
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
  function icLinks(m) {
    const real = m.hubs.filter((h) => !h.ghost && !h.synthetic);
    const netIC = new Map(), netPass = new Map(), pinsByRef = new Map(), compByRef = new Map();
    real.forEach((h) => { if (!compByRef.has(h.ref)) compByRef.set(h.ref, h.component || ""); h.pins.forEach((p) => {
      if (!p.net) return;
      let a = netIC.get(p.net); if (!a) { a = []; netIC.set(p.net, a); } a.push({ ref: h.ref, name: p.name, pin: p.pin });
      let b = pinsByRef.get(h.ref); if (!b) { b = []; pinsByRef.set(h.ref, b); } b.push({ pin: p.pin, net: p.net, name: p.name });
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
    const isStub = (n) => !n || isGroundName(n) || isPowerName(n) || /\d+v\d*/i.test(netLeaf(n));   // incl. V_3V3_LMX/V_3V3A rails (a pull-up to them must TERMINATE the walk, not fork it)
    // Every part (IC or passive) sitting on a net — used to tell a real chain (its exit
    // reaches a NEW part) from a 2-wire bus that loops back between the same two devices.
    const partsOn = (net) => new Set([...(netIC.get(net) || []).map((e) => e.ref), ...(netPass.get(net) || []).map((p) => p.ref)]);
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
        if (sib.length === 1) {
          // Guard against a 2-wire BUS that merely shares a prefix (I2C_SCL / I2C_SDA
          // between the same J1↔EEPROM pair): a real chain's exit reaches a part the
          // in-net doesn't already touch; a bus loops back, adding none → not a hop.
          const out = sib[0], inParts = partsOn(inNet);
          if ([...partsOn(out)].some((r) => r !== ref && !inParts.has(r))) return out;
        }
      }
      // (4) Pin-name IN/OUT pairing — the pin feeding inNet is named <X>IN and the chip
      // has a matching <X>OUT pin (or vice-versa). Reaches through a sealed module whose
      // internal coupling cap puts the chip's RF leg on a module-local net.
      for (const pp of pins) {
        if (pp.net !== inNet) continue;
        const tw = pinIoTwin(pp.name); if (!tw) continue;
        for (const q of pins) if (q.name && String(q.name).toUpperCase() === tw && !isStub(q.net) && q.net !== inNet) return q.net;
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
          // A directly-wired terminal IC at the fan-out is the chain's natural END — a VCO
          // output that also taps the PLL feedback through a cap should end at the VCO, not
          // chase the high-Z tap. Prefer ending there over following the extending element.
          const endIC = cs.filter((x) => x.t === "ic" && !passExit(x.ref, net));
          if (endIC.length === 1 && (firstDev || chain.length)) c = endIC[0];
          else if (extend.length === 1) c = extend[0];
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
        chain.push({ ref: c.ref, value: c.value, type: c.type, inNet: net, outNet: c.otherNet }); viaPass = c.ref; net = c.otherNet;
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
  // grid of self-contained per-IC cells. EVERY real IC gets its own cell — its
  // complete local circuit (owned point-to-point links with ghost partners, series
  // chains, pulls, bound bypass caps, extras spokes) on one card, so a regulator
  // whose pins are all rails is a page too, not invisible. Two exceptions: test
  // points fold into one "Test points" card, and a pure two-port passive (filter /
  // pad / balun) draws inline in the chain that runs through it instead — solid,
  // as its canonical drawing (`canon`). Each link's DETAIL is
  // still drawn exactly once: in the cell of its lower-degree end (the
  // peripheral's page shows the wire + chain + a dashed ghost of the busy hub;
  // the hub's page shows that pin as a labeled stub + partner chip — the
  // off-page-reference idiom of a hand schematic). Pins are row-banded per
  // partner and every cell has its own grid slot, so NOTHING can overlap.
  function buildGlobalMap(m) {
    const real = m.hubs.filter((h) => !h.ghost && !h.synthetic);
    if (!real.length) return;                            // hub-less design — keep the base layout
    const labelOf = new Map(), compOf = new Map();
    real.forEach((h) => { if (!labelOf.has(h.ref)) { labelOf.set(h.ref, h.label); compOf.set(h.ref, h.component || ""); } });
    // The authored (section …) each IC sits in (looked up in the BASE layout,
    // before this rebuild discards it) names what the cell is for — it becomes
    // part of the cell's title above the dashed box.
    const baseSecs = m.secs.filter((sc) => sc.name);
    const secNameOf = (h) => { const sc = baseSecs.find((b) => h.cx >= b.x && h.cx <= b.x + b.w && h.cy >= b.y && h.cy <= b.y + b.h); return sc ? sc.name : ""; };
    // Test points collapse into one compact "Test points" card (a TP glyph per
    // row) instead of a full cell each; they never anchor or ghost a link.
    const isTPRef = (r) => /^tp\d*$/i.test(String(r).split("/").pop() || "");
    const allNets = new Set(); real.forEach((h) => h.pins.forEach((p) => { if (p.net) allNets.add(p.net); }));
    const isDiff = (n) => { const t = diffTwin(n); return !!(t && allNets.has(t)); };
    // net -> the ICs that sit on it, so an extra pin carrying a multi-drop bus (SPI_SCK /
    // SPI_MOSI on a connector) can name the devices it fans out to instead of dead-ending
    // as a bare stub — those slaves aren't a single point-to-point partner, so the map
    // otherwise drops them.
    const netICs = new Map();
    const netRefPin = new Map();          // net -> (ref -> short pin label on that net) — for a chip's "ref·pin" text
    const shortPin = (p) => {
      const nm = p.name || "", pad = String(p.pins || p.pin || "").split(",").filter(Boolean)[0] || "";
      if (nm && !/^[0-9]+$/.test(nm) && nm !== pad) return nm.length > 7 ? nm.slice(0, 7) : nm;
      return pad;
    };
    real.forEach((h) => h.pins.forEach((p) => {
      if (!p.net) return;
      let a = netICs.get(p.net); if (!a) { a = []; netICs.set(p.net, a); } if (!a.includes(h.ref)) a.push(h.ref);
      let mm = netRefPin.get(p.net); if (!mm) { mm = new Map(); netRefPin.set(p.net, mm); } if (!mm.has(h.ref)) mm.set(h.ref, shortPin(p));
    }));
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
        item.through = { ref: dev.ref, component: dev.component || "", canon: inlinePart(dev.ref), gnd: hasGndPin(dev.ref) };
        const sOut = dev.outNet || b.net;                                   // shifter's own output net
        item.outNet = (sOut && sOut !== a.net) ? sOut : null;
        if (tail.length) {
          item.tail = { type: tail.length === 1 ? tail[0].type : "box", label: tail.length === 1 ? (tail[0].ref + (tail[0].value ? " " + tail[0].value : "")) : tail.map((x) => x.ref).join("+"), ref: tail[0].ref };
          item.farNet = (b.net && b.net !== sOut && b.net !== a.net) ? b.net : null;   // net past the tail (ghost pin)
        }
      } else if (link.passives.length >= 2) {
        // A multi-element run (filters / pads / DC-blocks in series): draw EACH element
        // as its own block in a row, so the signal path reads end to end instead of
        // collapsing to one box. Orient elements anchor→ghost; carry the net AFTER each.
        const fwd = a.ref === link.a.ref;
        const els = fwd ? link.passives : link.passives.slice().reverse();
        item.chain = els.map((x) => ({ ref: x.ref, value: x.value || "", type: x.type, device: !!x.device, component: x.component || compOf.get(x.ref) || "", net: (fwd ? x.outNet : x.inNet) || "", canon: !!x.device && inlinePart(x.ref), gnd: !!x.device && hasGndPin(x.ref) }));
        item.outNet = (b.net && b.net !== a.net) ? b.net : null;
      } else if (link.passives.length) {
        // A single series passive stays one small inline symbol on the wire. Carry the
        // partner-side net too — a series R bridges two DIFFERENT nets — so the layout
        // can name each side of the symbol (not one label centered on it) and the ghost
        // pin reads its own net (netB), not the IC-side net.
        const one = link.passives[0];
        item.via = { type: one.type, label: one.ref + (one.value ? " " + one.value : ""), device: devs.length > 0, ref: one.ref, value: one.value || "" };
        item.outNet = (b.net && b.net !== a.net) ? b.net : null;
      }
      arr.push(item);
    };
    // A point-to-point link carries the SAME information from either IC's side, so
    // drawing its full detail in both cells would be pure redundancy — and worse,
    // the reader couldn't tell whether two drawings of R5 mean one part or two.
    // Each link is therefore OWNED by (drawn in detail inside) the cell of its
    // lower-degree end: the peripheral's page shows its complete wiring to the
    // busy hub/connector, while the hub's page shows that pin as a labeled stub +
    // partner chip via the extras band (its net stays out of the hub cell's
    // partnerNets). Ties break lexically so the layout is stable across rebuilds.
    // A synthetic terminal stub ("ref ▸") is only ever a partner, never an owner.
    const links = icLinks(m).filter((lk) => !isTPRef(lk.a.ref) && !isTPRef(lk.b.ref));
    // Pure two-port passives (filters, attenuator pads, baluns — a signal in +
    // out and ground, NO supply pin) don't get a cell of their own: the signal
    // chain that runs through them, drawn in its owner's cell, IS their complete
    // schematic, so they render there solid (ref + part + ground rake) instead
    // of as dashed proxies. Only parts that actually surface inline in some
    // link are collapsed — an orphaned filter keeps its cell so it can't vanish.
    const isRail = (n) => isPowerName(n) || /\d+v\d*/i.test(netLeaf(n));
    const twoPortPassive = (ref) => {
      let sig = 0, pwr = 0;
      const seen = new Set();
      real.forEach((h) => { if (h.ref === ref) h.pins.forEach((p) => {
        const n = p.anet || p.net; if (!n || seen.has(n)) return; seen.add(n);
        if (isGroundName(n)) return; if (isRail(n)) pwr++; else sig++;
      }); });
      return pwr === 0 && sig >= 1 && sig <= 2;
    };
    const hasGndPin = (ref) => real.some((h) => h.ref === ref && h.pins.some((p) => isGroundName(p.anet || p.net)));
    const inlineDevs = new Set();
    links.forEach((lk) => lk.passives.forEach((x) => { if (x.device) inlineDevs.add(x.ref); }));
    const inlinePart = (r) => inlineDevs.has(r) && twoPortPassive(r);
    // Power tree. scene.rails (server-derived from sub-block output ports) maps
    // each rail — and its ferrite-bridged aliases — to the IC that produces it.
    // A top-level input `(port … in)` on a rail-named net synthesizes an entry
    // for the board input, anchored to the connector carrying the most pads on
    // it, so the chain starts at the power inlet.
    const railByNet = new Map();          // net or alias -> {net, producer}
    (scene.rails || []).forEach((r) => {
      if (!r.source_hub) return;
      const entry = { net: r.net, producer: r.source_hub };
      railByNet.set(r.net, entry);
      (r.aliases || []).forEach((a) => railByNet.set(a, entry));
    });
    (scene.ports || []).forEach((p) => {
      if (!p.net || railByNet.has(p.net) || String(p.dir) !== "in") return;
      if (!(isPowerName(p.net) || /\d+v\d*/i.test(netLeaf(p.net)))) return;
      let best = null, bestN = 0;
      real.forEach((h) => {
        const pre = ((h.ref.split("/").pop() || "").match(/^[A-Za-z]+/) || [""])[0].toUpperCase();
        if (pre !== "J" && pre !== "P" && pre !== "X") return;
        let n = 0; h.pins.forEach((pp) => { if ((pp.anet || pp.net) === p.net) n++; });
        if (n > bestN) { bestN = n; best = h.ref; }
      });
      if (best) railByNet.set(p.net, { net: p.net, producer: best });
    });
    const producerRefs = new Set([...railByNet.values()].map((e) => e.producer));
    const railsOf = (ref) => {
      const out = [], seen = new Set();
      real.forEach((h) => { if (h.ref === ref) h.pins.forEach((p) => { const n = p.anet || p.net; if (n && !seen.has(n)) { seen.add(n); out.push({ net: n, name: p.name }); } }); });
      return out;
    };
    // Unbound rail-level caps (both legs rail + ground — invisible before) dock
    // as spokes on their rail's PRODUCER row: the regulator's output bank.
    const railCapsByNet = new Map();
    (scene.passives || []).forEach((p) => {
      const nets = (p.pins || []).map((x) => x.net).filter(Boolean);
      if (nets.length !== 2 || p.decouplePin) return;
      if (passType(p.ref, p.component, p.value, p.symbol) !== "capacitor") return;
      const g = nets.find((n) => isGroundName(n)), r = nets.find((n) => !isGroundName(n));
      if (!g || !r || !railByNet.has(r)) return;
      let a = railCapsByNet.get(r); if (!a) { a = []; railCapsByNet.set(r, a); }
      if (!a.some((x) => x.ref === p.ref)) a.push({ ref: p.ref, type: "capacitor", value: (p.count > 1 ? p.count + "× " : "") + (p.value || p.ref), other: g });
    });
    const byRef = new Map();                              // ref -> [link index…]
    links.forEach((lk, i) => [lk.a.ref, lk.b.ref].forEach((r) => {
      let a = byRef.get(r); if (!a) { a = []; byRef.set(r, a); } a.push(i);
    }));
    const deg = (r) => (byRef.get(r) || []).length;       // total degree (ownership rank)
    const linkPartner = new Map();                        // "ref\0pin" (non-owner end) -> owner-cell ref
    const inlinePass = new Set();                         // passives drawn inline in a link — never re-spoked in extras
    links.forEach((lk) => {
      let owner = lk.a, other = lk.b;
      if (!lk.b.terminal && (deg(lk.b.ref) < deg(lk.a.ref) || (deg(lk.b.ref) === deg(lk.a.ref) && lk.b.ref < lk.a.ref))) { owner = lk.b; other = lk.a; }
      addItem(owner, other, lk);
      if (!other.terminal) linkPartner.set(other.ref + "\0" + other.pin, owner.ref);
      lk.passives.forEach((x) => { if (!x.device) inlinePass.add(x.ref); });
    });
    // Each regulator's INPUT rail becomes a real partner row — one wire to a
    // ghost of the upstream producer — so a power cell reads "fed from X" and
    // the chain J1 → buck → LDO is walkable. Owned by the consumer: the
    // producer's own cell keeps the rail as a plain output stub + chips.
    producerRefs.forEach((ref) => {
      if (isTPRef(ref) || inlinePart(ref)) return;
      railsOf(ref).forEach((pn) => {
        const rail = railByNet.get(pn.net);
        if (!rail || rail.producer === ref || isGroundName(pn.net)) return;
        let parts = byIC.get(ref); if (!parts) { parts = new Map(); byIC.set(ref, parts); }
        let arr = parts.get(rail.producer); if (!arr) { arr = []; parts.set(rail.producer, arr); }
        if (arr.some((it) => it.net === pn.net)) return;
        arr.push({ net: pn.net, outNet: null, farNet: null, through: null, via: null, tail: null, icPinName: pn.name, ghostPinName: "", diff: false, terminal: false });
      });
    });
    // For a fanout net whose target is ALREADY a ghost in an anchor's cell (e.g. the LMX2595
    // is a ghost in J1's cell via its SPI_MISO/CSN links), add a "bus pin" to that ghost so it
    // shows the net as a dot + stub + label at rest — the connecting line is drawn on hover
    // (the chip reveal lands on this pin). Multi-drop only (deg-2 is a normal link); GND skipped.
    byIC.forEach((parts, anchorRef) => {
      const seen = new Set();
      real.forEach((bx) => { if (bx.ref !== anchorRef) return; bx.pins.forEach((p) => {
        const net = p.anet || p.net;
        if (!net || seen.has(net) || isGroundName(net)) return;
        seen.add(net);
        if ((netICs.get(net) || []).length < 3) return;
        (netICs.get(net) || []).forEach((tgt) => {
          if (tgt === anchorRef) return;
          const arr = parts.get(tgt); if (!arr) return;                 // target must already be a ghost here
          if (arr.some((it) => it.net === net)) return;                 // a link/pin already carries this net
          arr.push({ net, outNet: null, farNet: null, through: null, via: null, tail: null, icPinName: "", ghostPinName: "", diff: false, terminal: false, busPin: true });
        });
      }); });
    });
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
    const CHAIN_SLOT = 96, CHAIN_DEV = 40;        // per-element slot in a multi-element chain row; device-block half-width (passive elements use a small symbol) — wide enough for an MPN like "lfcn-1575d+" now that a chain filter's inline block is its ONLY drawing
    const BUS_LEAD = 46;                          // length of a ghost bus-pin's lead (dot → lead end where the hover reveal connects)
    // Extras band — the pins with no point-to-point partner (power/ground, multi-drop,
    // board IO) shown as horizontal SPOKES that fan out to BOTH sides of the IC, like
    // the original schematic (passives ride the spoke, terminal at the outboard end).
    const EXTRA_TOP = 16, EXTRA_PITCH = 30, PASSROW = 30;          // band top inset; bare-pin row height; parallel-spoke pitch
    const EXTRA_LEAD = 18, SYM_LEAD = 12, TERM_LEAD = 14, EXTRA_STUB = 56, EXTRA_LABELW = 90;
    const EXTRA_SPAN = EXTRA_LEAD + SYM_LEAD + SPOKE_SYM + TERM_LEAD + EXTRA_LABELW;   // outboard room a spoke side needs
    // Net-partner chips: for a bare pin on a high-fanout / multi-drop net, its OTHER devices
    // are drawn as small hoverable ghost chips hanging off the pin (same side), capped at
    // CHIP_CAP with a "+N" overflow. Hover / click-to-pin a chip → drawChips draws the real
    // connection to that device. Replaces the old "NET → U16 U17 U20" dead text label.
    const CHIP_CAP = 4, CHIP_H = 16, CHIP_GAP = 5, CHIP_LEADGAP = 9, CHIP_CHARW = 5.7, CHIP_PADX = 12, NETLBL_CHARW = 6.4;
    const chipW = (t) => Math.max(24, Math.round(String(t).length * CHIP_CHARW + CHIP_PADX));
    const cells = [];
    const cellRefs = [], seenCellRef = new Set();          // every real IC (test points + inline two-ports aside), in scene order
    real.forEach((h) => { if (!isTPRef(h.ref) && !inlinePart(h.ref) && !seenCellRef.has(h.ref)) { seenCellRef.add(h.ref); cellRefs.push(h.ref); } });
    // Power-first ordering: rail producers sort by depth in the rail flow
    // (board input 0, buck off it 1, LDO off the buck 2 …) ahead of everything
    // else (which keeps scene order) — the map opens on the power tree, page-1
    // style, flowing left to right.
    const prodDepth = new Map();
    const depthOf = (ref, guard) => {
      if (prodDepth.has(ref)) return prodDepth.get(ref);
      if (guard.has(ref)) return 0;
      guard.add(ref);
      let d = 0;
      railsOf(ref).forEach((pn) => {
        const rail = railByNet.get(pn.net);
        if (rail && rail.producer !== ref) d = Math.max(d, 1 + depthOf(rail.producer, guard));
      });
      prodDepth.set(ref, d);
      return d;
    };
    const depthGuard = new Set();
    cellRefs.sort((a, b) => (producerRefs.has(a) ? depthOf(a, depthGuard) : 1e9) - (producerRefs.has(b) ? depthOf(b, depthGuard) : 1e9));
    cellRefs.forEach((ref) => {
      const parts = byIC.get(ref) || new Map();
      const groups = [...parts.entries()].map(([pref, items]) => ({ pref, label: labelOf.get(pref) || pref, items })).sort((a, b) => b.items.length - a.items.length);
      const side = { left: [], right: [] }; let lc = 0, rc = 0;                  // balance pins across the two sides
      groups.forEach((g) => { if (lc <= rc) { side.left.push(g); lc += g.items.length; } else { side.right.push(g); rc += g.items.length; } });
      // The middle column between IC and ghost holds inline blocks: a pass-through
      // shifter (SHIFT_W) or a multi-element chain (one CHAIN_SLOT per element). Its
      // width sets how far out the ghost partner sits.
      const sideMid = (gs) => { let w = 0; gs.forEach((g) => g.items.forEach((it) => { if (it.through) w = Math.max(w, SHIFT_W); if (it.chain) w = Math.max(w, it.chain.length * CHAIN_SLOT); if (it.via) w = Math.max(w, CHAIN_SLOT); })); return w; };
      const leftMid = sideMid(side.left), rightMid = sideMid(side.right);
      const sideW = (gs, mid) => gs.length ? (mid > 0 ? LEAD + mid + LEAD + GW : OUT + GW) : 0;
      // Gather this IC's extra pins (no point-to-point partner) and split them across the
      // two sides, balanced by row height, so the band below the partner pins is ~half as
      // tall. Done BEFORE icX so each side reserves room for its outgoing spokes.
      const boxes = real.filter((h) => h.ref === ref);     // ALL the IC's boxes — a multi-part hub splits per (part …)
      const partnerNets = new Set();
      groups.forEach((g) => g.items.forEach((it) => { if (it.busPin) return; [it.net, it.outNet, it.farNet].forEach((n) => n && partnerNets.add(n)); }));
      const passClaimed = new Set();                 // each passive lands on at most one pin of this cell
      const rowHt = (e) => Math.max(EXTRA_PITCH, (e.ps || []).length * PASSROW);
      const extras = [], seenE = new Set();
      boxes.forEach((bx) => bx.pins.forEach((p) => {
        const net = p.anet || p.net;
        if (!net || partnerNets.has(net) || seenE.has(net)) return;
        seenE.add(net);
        const pads = String(p.pins || p.pin || "").split(",").filter(Boolean);
        const ps = [], seenP = new Set();            // bypass caps bound to a pad (decoupByPin) + series/pulls on the net
        pads.forEach((pad) => (decoupByPin.get(ref + " " + pad) || []).forEach((x) => { if (!seenP.has(x.ref)) { seenP.add(x.ref); ps.push(x); } }));
        (passByNet.get(net) || []).forEach((x) => { if (!seenP.has(x.ref) && !passClaimed.has(x.ref) && !inlinePass.has(x.ref)) { seenP.add(x.ref); ps.push(x); } });
        const rr = railByNet.get(net);               // rail-level cap bank rides its producer's rail row
        if (rr && rr.producer === ref) (railCapsByNet.get(net) || []).forEach((x) => { if (!seenP.has(x.ref) && !passClaimed.has(x.ref)) { seenP.add(x.ref); ps.push(x); } });
        ps.forEach((x) => passClaimed.add(x.ref));
        // A chain-connected pin has no IC directly on its own net (the partner sits
        // past the series parts, drawn in the owner's cell) — chip the owner instead.
        let targets = (netICs.get(net) || []).filter((r) => r !== ref);
        if (!targets.length) { const lp = linkPartner.get(ref + "\0" + p.pin); if (lp) targets = [lp]; }
        extras.push({ net, name: p.name, ps, targets });
      }));
      // Build each bare pin's partner-chip model (skip pins that already spoke to passives).
      const partnerPinLabel = (net, r) => { const mm = netRefPin.get(net); return mm ? (mm.get(r) || "") : ""; };
      extras.forEach((e) => {
        if (e.ps.length || isGroundName(e.net)) return;   // GND touches everything — chips there are pure noise
        const tg = e.targets || [], showPin = tg.length > 0 && tg.length <= CHIP_CAP;
        e.chips = tg.slice(0, CHIP_CAP).map((r) => {
          let text = r;
          if (showPin) { const pn = partnerPinLabel(e.net, r); if (pn) text = r + "·" + pn; }
          return { text, target: r, w: chipW(text), overflow: false };
        });
        if (tg.length > CHIP_CAP) { const t = "+" + (tg.length - CHIP_CAP); e.chips.push({ text: t, target: null, w: chipW(t), overflow: true, hidden: tg.slice(CHIP_CAP) }); }
      });
      // Outboard room a side needs: a passive spoke is EXTRA_SPAN; a bare pin is its
      // stub + net name + chip row (so wide bus pins don't collide with the next cell).
      const extraOutboard = (e) => {
        if (e.ps.length) return EXTRA_SPAN;
        const base = EXTRA_STUB + 6 + netLeaf(e.net).length * NETLBL_CHARW;
        const chips = e.chips || [];
        if (!chips.length) return base + 8;
        let w = base + CHIP_LEADGAP;
        chips.forEach((c, i) => { w += c.w + (i ? CHIP_GAP : 0); });
        return w + 8;
      };
      const eLeft = [], eRight = []; let ehL = 0, ehR = 0;
      extras.forEach((e) => { if (ehL <= ehR) { eLeft.push(e); ehL += rowHt(e); } else { eRight.push(e); ehR += rowHt(e); } });
      const extraSideW = (es) => es.length ? Math.max.apply(null, es.map(extraOutboard)) : 0;
      const leftW = Math.max(sideW(side.left, leftMid), extraSideW(eLeft));
      const rightW = Math.max(sideW(side.right, rightMid), extraSideW(eRight)), icX = leftW;
      const comp = compOf.get(ref) || "";
      const secName = boxes.length ? secNameOf(boxes[0]) : "";
      const title = ref + (comp && comp !== ref ? " · " + comp : "") + (secName ? " — " + secName : "");
      const cell = { ref, title, group: secName, label: labelOf.get(ref) || ref, ox: MX, oy: MY, ch: 0, w: 2 * MX + leftW + ICW + rightW, h: 0, icX, ghosts: [], wires: [], labels: [], pulls: [], chips: [], leftPins: [], rightPins: [] };
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
      const layoutSide = (gs, onRight) => {
        if (!gs.length) return HEAD;
        const icEdge = onRight ? icX + ICW : icX;
        const dir = onRight ? 1 : -1;
        const shiftX = onRight ? icEdge + LEAD : icEdge - LEAD - SHIFT_W;
        const shIn = onRight ? shiftX : shiftX + SHIFT_W, shOut = onRight ? shiftX + SHIFT_W : shiftX;
        const colStart = onRight ? icEdge + LEAD : icEdge - LEAD;   // IC-side edge of the chain column
        let y = HEAD + PITCH / 2, lastBot = HEAD + PITCH;
        gs.forEach((g) => {
          // Each ghost hugs the IC at ITS OWN distance — just past THIS group's widest
          // in-line run (shifter / chain), not the widest run on the whole side — so a
          // direct-link partner stays close even when a sibling group has a long chain.
          // (The cell still reserves the side max via sideW, so nothing overflows.)
          let gmid = 0;
          g.items.forEach((it) => { if (it.through) gmid = Math.max(gmid, SHIFT_W); if (it.chain) gmid = Math.max(gmid, it.chain.length * CHAIN_SLOT); if (it.via) gmid = Math.max(gmid, CHAIN_SLOT); });
          const ghX = gmid > 0 ? (onRight ? icEdge + LEAD + gmid + LEAD : icEdge - LEAD - gmid - LEAD - GW)
            : (onRight ? icEdge + OUT : icEdge - OUT - GW);
          const ghIn = onRight ? ghX : ghX + GW;
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
            if (!it.busPin) (onRight ? cell.rightPins : cell.leftPins).push({ name: it.icPinName, x: icEdge, y, net: it.net });
            const gnet = it.farNet || it.outNet || it.net;
            gpins.push({ pin: gnet, name: it.busPin ? "" : (it.ghostPinName === it.icPinName ? "" : it.ghostPinName), side: onRight ? "left" : "right", x: ghIn, y, net: gnet, vx: it.busPin ? ghIn - dir * BUS_LEAD : null, vy: it.busPin ? y : null });
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
            if (!r.s && r.it.chain) {                              // multi-element run: a row of blocks/symbols
              const ch = r.it.chain;
              let prevX = icEdge, prevNet = r.it.net;
              ch.forEach((el, k) => {
                const cx = colStart + dir * (k * CHAIN_SLOT + CHAIN_SLOT / 2);
                const half = el.device ? CHAIN_DEV : 13;
                cell.wires.push({ net: prevNet, pts: [[prevX, r.y], [cx - dir * half, r.y]] });
                if (prevNet) cell.labels.push({ text: prevNet, x: (prevX + cx - dir * half) / 2, y: r.y - 9, w: segW(prevX, cx - dir * half) });
                if (el.device) {
                  cell.ghosts.push({ ref: el.ref, label: el.ref, part: el.component || "", canon: el.canon, gnd: el.gnd, x: cx - half, y: r.y - SHEAD / 2, w: 2 * half, h: SHEAD, pins: [
                    { pin: prevNet, name: "", side: onRight ? "left" : "right", x: cx - dir * half, y: r.y, net: prevNet, vx: null, vy: null },
                    { pin: el.net, name: "", side: onRight ? "right" : "left", x: cx + dir * half, y: r.y, net: el.net, vx: null, vy: null },
                  ] });
                } else {
                  cell.wires.push({ net: prevNet, via: { type: el.type, label: el.ref + (el.value ? " " + el.value : ""), ref: el.ref, value: el.value || "" }, pts: [[cx - half, r.y], [cx + half, r.y]] });   // symbol span only, left→right (zero-length via-leads)
                }
                prevX = cx + dir * half; prevNet = el.net;
              });
              cell.wires.push({ net: prevNet, pts: [[prevX, r.y], [ghIn, r.y]] });
              if (prevNet) cell.labels.push({ text: prevNet, x: (prevX + ghIn) / 2, y: r.y - 9, w: segW(prevX, ghIn) });
              i++; continue;
            }
            if (r.it.busPin) {                                     // bus pin ON the ghost: dot + a lead (the gpin's vx/vy stub) + net label ABOVE the lead; the yellow reveal connects to the lead end
              // Align the label to the ghost edge, reading outward along the lead: left-aligned
              // when the pin is on the ghost's RIGHT edge (dir<0), right-aligned on the LEFT edge.
              cell.labels.push({ text: netLeaf(r.it.net), x: ghIn - dir * 7, y: r.y - 10, anchor: dir < 0 ? "start" : "end", w: BUS_LEAD - 8 });
              i++; continue;
            }
            if (!r.s) {                                            // direct link: one straight wire + label(s)
              if (r.it.via && r.it.outNet && r.it.outNet !== r.it.net) {
                // A series passive bridges two DIFFERENT nets. Emit it as three pieces —
                // IC-lead (icNet) + symbol + ghost-lead (farNet) — so EACH SIDE is its own
                // wire object: clicking one highlights only that net (not the whole line),
                // and each side carries its own label + pulls. (Same shape the multi-element
                // chain path produces; the ghost is spaced out one CHAIN_SLOT to fit it.)
                const half = r.it.via.device ? 16 : 11, cxw = (icEdge + ghIn) / 2;
                const icEnd = cxw - dir * half, ghEnd = cxw + dir * half;
                cell.wires.push({ net: r.it.net, diff: r.it.diff, pts: [[icEdge, r.y], [icEnd, r.y]] });
                cell.wires.push({ net: r.it.net, diff: r.it.diff, via: r.it.via, pts: [[cxw - half, r.y], [cxw + half, r.y]] });   // symbol span only, left→right: its via-leads are zero-length so no line is drawn THROUGH the part
                cell.wires.push({ net: r.it.outNet, diff: r.it.diff, pts: [[ghEnd, r.y], [ghIn, r.y]] });
                cell.labels.push({ text: r.it.net, x: (icEdge + icEnd) / 2, y: r.y - 10, diff: r.it.diff, w: segW(icEdge, icEnd) });
                cell.labels.push({ text: r.it.outNet, x: (ghEnd + ghIn) / 2, y: r.y - 10, diff: r.it.diff, w: segW(ghEnd, ghIn) });
                pullsOn(r.it.net, icEdge, icEnd, r.y, onRight ? 1 : -1);
                pullsOn(r.it.outNet, ghEnd, ghIn, r.y, onRight ? 1 : -1);
              } else {
                cell.wires.push({ net: r.it.net, diff: r.it.diff, via: r.it.via, pts: [[icEdge, r.y], [ghIn, r.y]] });
                cell.labels.push({ text: r.it.net, x: (icEdge + ghIn) / 2, y: r.y - 10, diff: r.it.diff, w: segW(icEdge, ghIn) });
                pullsOn(r.it.net, icEdge, ghIn, r.y, onRight ? 1 : -1);
              }
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
              cell.labels.push({ text: rr.it.net, x: (icEdge + shIn) / 2, y: rr.y - 10, diff: rr.it.diff, w: segW(icEdge, shIn) });
              // shifter output net: at the leg midpoint normally, else hugged to the shifter so it clears the tail symbol.
              if (rr.it.outNet) cell.labels.push({ text: oNet, x: rr.it.tail ? shOut + (onRight ? 1 : -1) * (LEAD * 0.3) : (shOut + ghIn) / 2, y: rr.y - 10, diff: rr.it.diff, w: rr.it.tail ? LEAD * 0.5 : segW(shOut, ghIn) });
              pullsOn(rr.it.net, icEdge, shIn, rr.y, onRight ? 1 : -1);
              if (rr.it.outNet && !rr.it.tail) pullsOn(rr.it.outNet, shOut, ghIn, rr.y, onRight ? 1 : -1);
            });
            const d = run[0].it.through;
            cell.ghosts.push({ ref: d.ref, label: d.ref, part: d.component || compOf.get(d.ref) || "", canon: d.canon, gnd: d.gnd, x: shiftX, y: run[0].y - SHEAD, w: SHIFT_W, h: (run[run.length - 1].y + PITCH / 2) - (run[0].y - SHEAD), pins: spins });
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
            const nP = e.ps.length, rowH = rowHt(e), pinY = ey + rowH / 2;
            (onRight ? cell.rightPins : cell.leftPins).push({ name: e.name, x: edge, y: pinY, net: e.net });
            if (!nP) {                                   // bare pin → stub + net name (grounds draw the earth symbol) + partner chips
              cell.wires.push({ net: e.net, pts: [[edge, pinY], [dst(EXTRA_STUB), pinY]] });
              if (isGroundName(e.net)) cell.labels.push({ text: netLeaf(e.net), x: dst(EXTRA_STUB), y: pinY, ground: true });
              else cell.labels.push({ text: netLeaf(e.net), x: dst(EXTRA_STUB + 6), y: pinY, anchor: onRight ? "start" : "end" });
              let k = EXTRA_STUB + 6 + netLeaf(e.net).length * NETLBL_CHARW + CHIP_LEADGAP;
              (e.chips || []).forEach((cm) => {
                const x0 = dst(k), x1 = dst(k + cm.w);
                cell.chips.push({ x: Math.min(x0, x1), y: pinY - CHIP_H / 2, w: cm.w, h: CHIP_H, text: cm.text, net: e.net,
                  target: cm.target, overflow: cm.overflow, hidden: cm.hidden || null, side: onRight ? "right" : "left", hx: edge, hy: pinY });
                k += cm.w + CHIP_GAP;
              });
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
      const lh = layoutSide(side.left, false), rh = layoutSide(side.right, true);
      const coreH = Math.max(lh, rh, HEAD + PITCH) + PAD;
      const extraH = layoutExtras(coreH);
      cell.ch = coreH + extraH;
      cell.h = 2 * MY + cell.ch;
      cells.push(cell);
    });
    // Test points: one compact card, a TP glyph per row with its net (ground nets
    // draw the earth symbol). Each glyph is still a real selectable/wirable hub.
    const tpRefs = [];
    { const seen = new Set(); real.forEach((h) => { if (isTPRef(h.ref) && !seen.has(h.ref)) { seen.add(h.ref); tpRefs.push(h.ref); } }); }
    if (tpRefs.length) {
      const TPROW = 30, REFW = 46, TSTUB = 42, TPB = 16;
      let maxLbl = 4;
      const rows = tpRefs.map((ref) => {
        let net = "";
        real.forEach((h) => { if (h.ref !== ref || net) return; h.pins.forEach((p) => { if (!net) net = p.anet || p.net || ""; }); });
        maxLbl = Math.max(maxLbl, netLeaf(net).length);
        return { ref, net };
      });
      const cell = { ref: "", title: "Test points", ox: MX, oy: MY, icX: 0, ch: 0, w: 2 * MX + REFW + TPB + TSTUB + 10 + maxLbl * NETLBL_CHARW + 14, h: 0, ghosts: [], wires: [], labels: [], pulls: [], chips: [], leftPins: [], rightPins: [], tps: [] };
      let ty = 22;
      rows.forEach((t) => {
        const pinX = REFW + TPB;
        cell.tps.push({ ref: t.ref, net: t.net, x: REFW, y: ty });
        if (t.net) {
          const end = pinX + TSTUB;
          cell.wires.push({ net: t.net, pts: [[pinX, ty], [end, ty]] });
          if (isGroundName(t.net)) cell.labels.push({ text: netLeaf(t.net), x: end, y: ty, ground: true });
          else cell.labels.push({ text: netLeaf(t.net), x: end + 6, y: ty, anchor: "start" });
        }
        ty += TPROW;
      });
      cell.ch = ty - TPROW / 2;
      cell.h = 2 * MY + cell.ch;
      cells.push(cell);
    }
    // Band the cells — Power first (the producer cells, already depth-sorted),
    // then each authored section that holds ≥2 cells, with single-cell sections
    // merging into unnamed runs in between — and shelf-pack each band into rows
    // so no two cells touch. A named band draws a faint container + title: the
    // wayfinding layer the far-zoom glance view enlarges.
    const bgroups = [], bgIdx = new Map();
    cells.forEach((c) => {
      const nm = c.tps ? " tp" : (producerRefs.has(c.ref) ? "Power" : (c.group || ""));
      let gi = bgIdx.get(nm);
      if (gi === undefined) { gi = bgroups.length; bgIdx.set(nm, gi); bgroups.push({ name: nm, cells: [] }); }
      bgroups[gi].cells.push(c);
    });
    const packs = [];
    bgroups.forEach((g) => {
      if (g.name === "Power" || (g.name && g.name !== " tp" && g.cells.length >= 2)) { packs.push({ name: g.name, cells: g.cells }); return; }
      const last = packs[packs.length - 1];
      if (last && !last.name) last.cells.push.apply(last.cells, g.cells);
      else packs.push({ name: null, cells: g.cells });
    });
    const CGX = 72, CGY = 64, MAXW = 2600, BAND_PAD = 24, BAND_HEAD = 68, BAND_GAP = 56;   // header tall enough that the band title clears the first cell's own title row
    let cy = 0, bx1 = 0, by1 = 0;
    m.bands = [];
    packs.forEach((p) => {
      const top = cy;
      if (p.name) cy += BAND_HEAD;
      let cx = 0, rowH = 0, right = 0;
      p.cells.forEach((c) => {
        if (cx > 0 && cx + c.w > MAXW) { cx = 0; cy += rowH + CGY; rowH = 0; }
        c.x = cx; c.y = cy; cx += c.w + CGX; rowH = Math.max(rowH, c.h);
        right = Math.max(right, c.x + c.w);
      });
      cy += rowH;
      if (p.name) {
        m.bands.push({ name: p.name, x: -BAND_PAD, y: top, w: right + 2 * BAND_PAD, h: (cy - top) + BAND_PAD, count: p.cells.length, power: p.name === "Power" });
        cy += BAND_PAD + BAND_GAP;
      } else cy += CGY;
      bx1 = Math.max(bx1, right);
    });
    by1 = cy;
    // Emit the synthesized model (replacing the real layout).
    m.secs = []; m.hubs = []; m.passes = []; m.wires = []; m.labels = []; m.pulls = []; m.chips = [];
    cells.forEach((c) => {
      const ox = c.x + c.ox, oy = c.y + c.oy;                      // content origin (inset by the cell margin)
      m.secs.push({ name: c.title || "", ref: c.ref || "", part: c.tps ? "" : (compOf.get(c.ref) || ""), x: c.x, y: c.y, w: c.w, h: c.h, idx: 0, cx: c.x + c.w / 2, cy: c.y + c.h / 2 });   // region title: ref · part — section (ref/part feed the glance chips)
      if (c.tps) {
        c.tps.forEach((t) => {
          const x = ox + t.x, y = oy + t.y;
          m.hubs.push({ ref: t.ref, label: t.ref, part: "", x, y: y - 8, w: 16, h: 16, cx: x + 8, cy: y, pins: [{ pin: "1", name: "", side: "right", x: x + 16, y, net: t.net, vx: null, vy: null }], tp: true });
        });
      } else {
        const mk = (p, side) => ({ pin: p.name, name: p.name, side, x: ox + p.x, y: oy + p.y, net: p.net, vx: null, vy: null });
        const pins = c.leftPins.map((p) => mk(p, "left")).concat(c.rightPins.map((p) => mk(p, "right")));
        m.hubs.push({ ref: c.ref, label: c.ref, part: compOf.get(c.ref) || "", x: ox + c.icX, y: oy, w: ICW, h: c.ch, cx: ox + c.icX + ICW / 2, cy: oy + c.ch / 2, pins });
      }
      c.ghosts.forEach((g) => {
        const pins2 = g.pins.map((p) => ({ ...p, x: ox + p.x, y: oy + p.y, vx: p.vx != null ? ox + p.vx : null, vy: p.vy != null ? oy + p.vy : null }));
        m.hubs.push({ ref: g.ref, label: g.label, part: g.part, canon: !!g.canon, gnd: !!g.gnd, x: ox + g.x, y: oy + g.y, w: g.w, h: g.h, cx: ox + g.x + g.w / 2, cy: oy + g.y + g.h / 2, pins: pins2, synthetic: true, ghost: true, terminal: !!g.terminal, partnerRef: g.terminal ? null : g.ref });
      });
      c.wires.forEach((w) => { const pts = w.pts.map((pt) => [ox + pt[0], oy + pt[1]]); m.wires.push({ net: w.net, bus: false, link: true, diff: w.diff, via: w.via, pts, bb: bbOf(pts) }); });
      c.labels.forEach((l) => m.labels.push({ text: l.text, x: ox + l.x, y: oy + l.y, anchor: l.anchor || "center", ground: !!l.ground, port: false, net: l.text, link: true, diff: l.diff, w: l.w }));
      c.pulls.forEach((p) => m.pulls.push({ x: ox + p.x, y: oy + p.y, ref: p.ref, value: p.value, rail: p.rail, up: p.up, type: p.type, term: p.term, axis: p.axis, dir: p.dir, jx: p.jx != null ? ox + p.jx : null, tx: p.tx != null ? ox + p.tx : null }));
      if (c.chips) c.chips.forEach((ch) => m.chips.push({ x: ox + ch.x, y: oy + ch.y, w: ch.w, h: ch.h, text: ch.text, net: ch.net, target: ch.target, overflow: ch.overflow, hidden: ch.hidden, side: ch.side, hx: ox + ch.hx, hy: oy + ch.hy, hostRef: c.ref }));
      bx1 = Math.max(bx1, c.x + c.w); by1 = Math.max(by1, c.y + c.h);
    });
    m.mapBox = { x: -40, y: -40, w: bx1 + 80, h: by1 + 80 };
  }

  function buildSheets() {
    sheets = [];
    const authored = scene.authored_sections || [];
    // The map's bands are the primary pages (Power, multi-cell sections) —
    // click zooms to the band. Authored sections that didn't form a band still
    // list box-less so they can be renamed / deleted (their `authored` flag
    // gates the manage tools; synthetic bands like "Power" have none).
    ((M && M.bands) || []).forEach((b) => sheets.push({ name: b.name, title: b.name, box: { x: b.x, y: b.y, w: b.w, h: b.h }, count: b.count, authored: authored.includes(b.name) }));
    const seen = new Set(sheets.map((s) => s.name));
    authored.forEach((nm) => { if (!seen.has(nm)) sheets.push({ name: nm, title: nm, box: null, count: 0, authored: true }); });
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
      if (s.authored) {                              // synthetic bands (Power, misc runs) aren't source sections
        const tools = mkEl("span", "ed-sheet-tools");
        const rn = mkEl("button", "ed-x", "✎"); rn.title = "Rename sheet";
        rn.onclick = (e) => { e.stopPropagation(); const nm = (prompt("Rename sheet:", s.name) || "").trim(); if (nm) applyRenameSection(s.name, nm); };
        const dl = mkEl("button", "ed-x", "✕"); dl.title = "Delete sheet (must be empty)";
        dl.onclick = (e) => { e.stopPropagation(); applyRemoveSection(s.name); };
        tools.appendChild(rn); tools.appendChild(dl); row.appendChild(tools);
      }
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
      <tr><td><kbd>/</kbd></td><td>Find — type a ref (U17), a net (SPI_SCK) or a chain key and <kbd>Enter</kbd> jumps the view there</td></tr>
      <tr><td>zoom out</td><td>Far out, the map turns into a <b>glance</b> block diagram — titled bands (Power, sections) with one chip per part. Double-click a chip to dive into its full cell.</td></tr>
      <tr><td><kbd>Esc</kbd></td><td>Deselect / close</td></tr>
      <tr><td>click part / net</td><td>Show its properties in the left inspector (edit value, rename net, rewire pins, copy, delete). The pin→net fields suggest existing nets — <kbd>↑</kbd>/<kbd>↓</kbd> + <kbd>Enter</kbd> to pick one, or just type a new name.</td></tr>
      <tr><td><b>double-click</b></td><td>Select it and jump straight to the first editable field in the inspector; on a dashed proxy, jump to that part's own region</td></tr>
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
      case "/": e.preventDefault(); findBox.focus(); findBox.select(); break;
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
  tools.innerHTML = `<button id="tool-add" title="Add (A)">+ Add</button><button id="tool-fit" title="Fit (F)">Fit</button><button id="tool-keys" title="Keys (?)">?</button>`;
  wrap.appendChild(tools);
  tools.querySelector("#tool-add").onclick = openAdd;
  tools.querySelector("#tool-fit").onclick = () => { if (activeSheet >= 0) selectSheet(activeSheet); else fitAll(); };
  tools.querySelector("#tool-keys").onclick = toggleKeys;

  // Find box (/) — jump straight to a ref, a net, or a chain key.
  const findBox = document.createElement("input");
  findBox.id = "ed-find"; findBox.placeholder = "Find ref / net…  ( / )";
  findBox.autocomplete = "off"; findBox.spellcheck = false;
  findBox.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { const v = findBox.value.trim(); if (!v) return; if (focusTarget(v)) findBox.blur(); else toast("No match: " + v, true); }
    else if (e.key === "Escape") { findBox.value = ""; findBox.blur(); }
  });
  sheetList.parentNode.insertBefore(findBox, sheetList);
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
    if (!(bootFocus && focusTarget(bootFocus))) fitAll();
    updateStatus(); requestAnimationFrame(frame);
  });
})();
