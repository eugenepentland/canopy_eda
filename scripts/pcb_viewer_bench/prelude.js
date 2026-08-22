// pcb_viewer_bench prelude — a minimal DOM/canvas stub environment that lets
// the real pcb_board.js run under Node for performance measurement. The stub
// canvas records operation COUNTS instead of rasterizing, so timings measure
// the JS side of a frame (path building, iteration, string work) and the
// counters measure what a real browser would be asked to draw. Layout-forcing
// reads (getScreenCTM / clientWidth / offsetLeft / getBoundingClientRect) are
// counted because each one flushes layout in a real browser.
// NOTE: deliberately NOT strict mode — the viewer scripts run sloppy in the
// browser and the concatenated bench must match.
const __fs = require("fs");
const __pcbSource = __fs.readFileSync(process.env.PCB_BLOB, "utf8");
function __pcbFromSource(src) {
  try { return JSON.parse(src); } catch (_) {}
  const mark = "const PCB=", at = src.indexOf(mark);
  if (at < 0) throw new Error("PCB_BLOB is neither JSON nor a PCB layout page");
  const start = at + mark.length, end = src.indexOf(";</script>", start);
  if (end < 0) throw new Error("PCB_BLOB has an unterminated PCB data script");
  return JSON.parse(src.slice(start, end));
}
const PCB = __pcbFromSource(__pcbSource);

const VIEW_W = 1600, VIEW_H = 900;

// ── counters ────────────────────────────────────────────────────────────
const OPS = {};
function resetOps() {
  for (const k of ["beginPath","pathVerts","arcs","rects","fills","strokes","fillRects",
    "strokeRects","fillTexts","strokeTexts","saves","restores","transforms","drawImages",
    "fontSets","p2dBuilt","p2dBuildVerts","p2dDrawVerts","ctmReads","rectReads",
    "clientReads","offsetReads","fetches","canvases"]) OPS[k] = 0;
}
resetOps();
globalThis.__OPS = OPS;
globalThis.__resetOps = resetOps;

// ── recording 2D context ────────────────────────────────────────────────
class BenchPath2D {
  constructor() { this.verts = 0; this.__p2d = true; OPS.p2dBuilt++; }
  moveTo() { this.verts++; OPS.p2dBuildVerts++; }
  lineTo() { this.verts++; OPS.p2dBuildVerts++; }
  arc() { this.verts++; OPS.p2dBuildVerts++; }
  arcTo() { this.verts++; OPS.p2dBuildVerts++; }
  ellipse() { this.verts++; OPS.p2dBuildVerts++; }
  rect() { this.verts++; OPS.p2dBuildVerts++; }
  quadraticCurveTo() { this.verts++; OPS.p2dBuildVerts++; }
  bezierCurveTo() { this.verts++; OPS.p2dBuildVerts++; }
  closePath() {}
  addPath(p) { if (p && p.__p2d) this.verts += p.verts; }
}
globalThis.Path2D = BenchPath2D;

function makeCtx() {
  const ctx = {
    canvas: null, _font: "10px sans-serif",
    globalAlpha: 1, fillStyle: "#000", strokeStyle: "#000", lineWidth: 1,
    lineCap: "butt", lineJoin: "miter", textAlign: "left", textBaseline: "alphabetic",
    beginPath() { OPS.beginPath++; },
    moveTo() { OPS.pathVerts++; }, lineTo() { OPS.pathVerts++; },
    arc() { OPS.arcs++; }, arcTo() { OPS.arcs++; }, ellipse() { OPS.arcs++; },
    rect() { OPS.rects++; },
    quadraticCurveTo() { OPS.pathVerts++; }, bezierCurveTo() { OPS.pathVerts++; },
    closePath() {},
    fill(a) { OPS.fills++; if (a && a.__p2d) OPS.p2dDrawVerts += a.verts; },
    stroke(a) { OPS.strokes++; if (a && a.__p2d) OPS.p2dDrawVerts += a.verts; },
    fillRect() { OPS.fillRects++; }, strokeRect() { OPS.strokeRects++; },
    clearRect() {},
    fillText() { OPS.fillTexts++; }, strokeText() { OPS.strokeTexts++; },
    measureText(t) { return { width: (t ? String(t).length : 1) * 6 }; },
    save() { OPS.saves++; }, restore() { OPS.restores++; },
    translate() { OPS.transforms++; }, rotate() { OPS.transforms++; },
    scale() { OPS.transforms++; }, transform() { OPS.transforms++; },
    setTransform() { OPS.transforms++; }, resetTransform() { OPS.transforms++; },
    getTransform() { return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }; },
    drawImage() { OPS.drawImages++; },
    setLineDash() {}, getLineDash() { return []; },
    clip() {}, isPointInPath() { return false; }, isPointInStroke() { return false; },
    createLinearGradient() { return { addColorStop() {} }; },
    createRadialGradient() { return { addColorStop() {} }; },
    createPattern() { return {}; },
    getImageData() { return { data: new Uint8ClampedArray(4) }; },
    putImageData() {},
  };
  Object.defineProperty(ctx, "font", {
    get() { return this._font; },
    set(v) { OPS.fontSets++; this._font = v; },
  });
  return ctx;
}

// ── element stub ────────────────────────────────────────────────────────
function makeEl(tag) {
  const el = {
    tagName: String(tag).toUpperCase(), children: [], attrs: {}, style: {},
    dataset: {}, parentNode: null,
    textContent: "", value: "", checked: false, hidden: false, disabled: false,
    className: "", id: "", title: "", innerHTML: "", selectedIndex: 0,
    options: [], selectedOptions: [], rows: [], cells: [],
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    // Listeners are STORED so the bench can drive real handlers (e.g. the svg
    // pointermove path) instead of re-implementing them.
    __listeners: null,
    addEventListener(type, fn) {
      if (!el.__listeners) el.__listeners = {};
      (el.__listeners[type] = el.__listeners[type] || []).push(fn);
    },
    removeEventListener() {}, dispatchEvent() { return true; },
    __fire(type, ev) { ((el.__listeners || {})[type] || []).forEach((f) => f(ev)); },
    setAttribute(k, v) { el.attrs[k] = String(v); if (el.__onSetAttr) el.__onSetAttr(k, v); },
    getAttribute(k) { return el.attrs[k] !== undefined ? el.attrs[k] : null; },
    removeAttribute(k) { delete el.attrs[k]; },
    hasAttribute(k) { return el.attrs[k] !== undefined; },
    appendChild(c) { el.children.push(c); c.parentNode = el; return c; },
    removeChild(c) { const i = el.children.indexOf(c); if (i >= 0) el.children.splice(i, 1); c.parentNode = null; return c; },
    insertBefore(c, ref) { const i = ref ? el.children.indexOf(ref) : -1; if (i < 0) el.children.push(c); else el.children.splice(i, 0, c); c.parentNode = el; return c; },
    contains() { return false; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    closest() { return null; },
    focus() {}, blur() {}, click() {},
    setPointerCapture() {}, releasePointerCapture() {},
    getBoundingClientRect() { OPS.rectReads++; return { left: 0, top: 0, width: VIEW_W, height: VIEW_H, right: VIEW_W, bottom: VIEW_H, x: 0, y: 0 }; },
    scrollIntoView() {},
    insertAdjacentHTML() {}, insertAdjacentElement(pos, c) { el.appendChild(c); return c; },
    insertAdjacentText() {},
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
  };
  Object.defineProperty(el, "firstChild", { get() { return el.children[0] || null; } });
  Object.defineProperty(el, "lastChild", { get() { return el.children[el.children.length - 1] || null; } });
  Object.defineProperty(el, "childNodes", { get() { return el.children; } });
  if (tag === "canvas") {
    el.width = 300; el.height = 150;
    OPS.canvases++;
    let ctx = null;
    el.getContext = function () { if (!ctx) { ctx = makeCtx(); ctx.canvas = el; } return ctx; };
    el.toDataURL = function () { return "data:,"; };
  }
  return el;
}

// The SVG scene element: layout-read counters + a live viewBox that the
// arithmetic fallback in svgScreenPoint reads, + a real affine getScreenCTM
// so coordinate math behaves exactly as in a browser.
function svgify(el) {
  el.viewBox = { baseVal: { x: 0, y: 0, width: VIEW_W, height: VIEW_H } };
  el.__onSetAttr = function (k, v) {
    if (k === "viewBox") {
      const p = String(v).split(/\s+/).map(Number);
      el.viewBox.baseVal = { x: p[0], y: p[1], width: p[2], height: p[3] };
    }
  };
  Object.defineProperty(el, "clientWidth", { get() { OPS.clientReads++; return VIEW_W; } });
  Object.defineProperty(el, "clientHeight", { get() { OPS.clientReads++; return VIEW_H; } });
  Object.defineProperty(el, "offsetLeft", { get() { OPS.offsetReads++; return 0; } });
  Object.defineProperty(el, "offsetTop", { get() { OPS.offsetReads++; return 0; } });
  el.getScreenCTM = function () {
    OPS.ctmReads++;
    const bv = el.viewBox.baseVal;
    const a = VIEW_W / bv.width, d = VIEW_H / bv.height;
    const e = -bv.x * a, f = -bv.y * d;
    return {
      a, b: 0, c: 0, d, e, f,
      inverse() {
        const ia = 1 / a, id = 1 / d;
        return { a: ia, b: 0, c: 0, d: id, e: -e * ia, f: -f * id };
      },
    };
  };
  el.createSVGPoint = function () {
    return {
      x: 0, y: 0,
      matrixTransform(m) { return { x: m.a * this.x + m.c * this.y + m.e, y: m.b * this.x + m.d * this.y + m.f }; },
    };
  };
  // pcb_board.js reads svg.parentNode at load to build the scene shell.
  const host = makeEl("div");
  host.appendChild(el);
}

// ── document / window / misc globals ────────────────────────────────────
const _els = {};
const document = {
  getElementById(id) {
    if (!(id in _els)) {
      _els[id] = makeEl(id === "pcb-svg" ? "svg" : "div");
      _els[id].id = id;
      if (id === "pcb-svg") svgify(_els[id]);
    }
    return _els[id];
  },
  createElement(t) { return makeEl(t); },
  createElementNS(ns, t) { return makeEl(t); },
  createTextNode(t) { return { textContent: t }; },
  createDocumentFragment() { return makeEl("#fragment"); },
  querySelector() { return null; }, querySelectorAll() { return []; },
  addEventListener() {}, removeEventListener() {},
  body: makeEl("body"), documentElement: makeEl("html"), head: makeEl("head"),
  hidden: false, visibilityState: "visible", activeElement: null,
  hasFocus() { return true; },
};

const location = {
  search: "", hash: "", pathname: "/pcb-layout/" + (PCB.name || "x"),
  href: "http://localhost/pcb-layout/" + (PCB.name || "x"),
  origin: "http://localhost", host: "localhost", protocol: "http:", reload() {},
};
const history = { replaceState() {}, pushState() {}, state: null };
const localStorage = { getItem() { return null; }, setItem() {}, removeItem() {}, clear() {} };
const sessionStorage = localStorage;
const navigator = { clipboard: { writeText() { return Promise.resolve(); } }, userAgent: "bench" };

const __rafQ = [];
function requestAnimationFrame(f) { __rafQ.push(f); return __rafQ.length; }
function cancelAnimationFrame() {}
globalThis.__flushRaf = function () {
  let guard = 0;
  while (__rafQ.length && guard++ < 1000) __rafQ.shift()(Date.now());
};

function fetch() {
  OPS.fetches++;
  return Promise.resolve({
    ok: false, status: 503,
    json() { return Promise.resolve({}); },
    text() { return Promise.resolve(""); },
    blob() { return Promise.resolve({}); },
    arrayBuffer() { return Promise.resolve(new ArrayBuffer(0)); },
    headers: { get() { return null; } },
  });
}

class Worker {
  constructor() { this.onmessage = null; this.onerror = null; }
  postMessage() {}
  terminate() {}
}
class BroadcastChannel2 {
  constructor() { this.onmessage = null; }
  postMessage() {}
  close() {}
}
function getComputedStyle() { return { getPropertyValue() { return ""; } }; }
function matchMedia() { return { matches: false, addEventListener() {}, addListener() {} }; }
function alert() {}
function confirm() { return false; }
function prompt() { return null; }
class Image { constructor() { this.onload = null; this.onerror = null; this.src = ""; } }
class XMLSerializer { serializeToString() { return ""; } }
class DOMParser { parseFromString() { return document; } }

// window IS the global object in a browser (window.X === bare X). The viewer
// relies on that — it assigns window.PCBOverlay and then reads bare
// PCBOverlay — so the bench must alias them the same way.
const window = globalThis;
const __winListeners = {};
window.addEventListener = function (type, fn) { (__winListeners[type] = __winListeners[type] || []).push(fn); };
window.removeEventListener = function () {};
window.dispatchEvent = function () { return true; };
window.__fireWin = function (type, ev) { (__winListeners[type] || []).forEach((f) => f(ev)); };
window.devicePixelRatio = 1;
window.innerWidth = VIEW_W;
window.innerHeight = VIEW_H;
window.open = function () { return null; };
window.scrollTo = function () {};
globalThis.document = document;
globalThis.location = location;
globalThis.history = history;
globalThis.localStorage = localStorage;
globalThis.sessionStorage = sessionStorage;
globalThis.navigator = navigator;
globalThis.requestAnimationFrame = requestAnimationFrame;
globalThis.cancelAnimationFrame = cancelAnimationFrame;
globalThis.fetch = fetch;
globalThis.Worker = Worker;
globalThis.BroadcastChannel = BroadcastChannel2;
globalThis.getComputedStyle = getComputedStyle;
globalThis.matchMedia = matchMedia;
globalThis.alert = alert;
globalThis.confirm = confirm;
globalThis.prompt = prompt;
globalThis.Image = Image;
globalThis.XMLSerializer = XMLSerializer;
globalThis.DOMParser = DOMParser;

process.on("unhandledRejection", () => {});
process.on("uncaughtException", (e) => { console.error("bench uncaught:", e && e.stack || e); process.exit(3); });
// ── end prelude ─────────────────────────────────────────────────────────
