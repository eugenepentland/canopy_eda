#!/usr/bin/env node
// Headless-browser invariant probe for the PCB editor (src/serve/assets/pcb_board.js).
//
// WHY THIS EXISTS
//   The editor is ~12k lines of browser JS whose only gates are `node --check`
//   and hundreds of exact-substring marker assertions in static_assets.zig that
//   prove strings are PRESENT, not that anything WORKS. The 2026-08-29 drift
//   audit (e2a5f7e) found six state-ownership bugs there, every one invisible to
//   every existing gate. This probe drives the real page in Chromium and asserts
//   the behaviour each of those fixes restored, so a revert fails a check
//   instead of a customer.
//
// WHAT IT RUNS AGAINST
//   The page HTML + APIs come from a real netlisp server, but `pcb_board.js` and
//   `pcb_replay.js` are SUBSTITUTED from the working tree by a Playwright route
//   handler. static_assets.zig @embedFile()s them, so a binary only carries the
//   asset it was compiled with; substituting means the probe tests the source you
//   are editing, and it runs without a rebuild (agents share the zig cache).
//   `--no-substitute` tests the binary's own embedded copy instead.
//
// DETERMINISM
//   The board is scripts/pcb_editor_invariants/fixture/ — a ~13-part design that
//   imports only the probe-* parts sitting beside it. It is copied into a fresh
//   throwaway project dir under ~/.cache/netlisp/ on every run, once per
//   invariant, so no invariant sees another's saved layouts and nothing depends
//   on projects/designs (which moves under gates — a prior one broke that way).
//
// SELF-TEST
//   `--self-test` re-runs each invariant against a scratch copy of pcb_board.js
//   with that fix textually reverted, and requires the invariant to FAIL. A probe
//   never shown to fail is not evidence. Nothing under src/ is ever written; the
//   revert happens in the string the route handler serves.
//
//   One result from that self-test is worth recording. Reverting ONLY the
//   `selCuClear();inspClear();` that e2a5f7e added to restoreSnap is NOT caught
//   (`--invariant undo-selection --self-test --revert undo-selection`), because
//   restoreSnap's own `applyAll()` reaches `clearRoute()`, which calls
//   `copperTouched()` — which already clears both — for any board that still
//   holds copper, and a board with no copper has no copper selection to strand.
//   The shipped line is therefore defence-in-depth over a state this probe
//   cannot construct, not the load-bearing guard. The invariant still has teeth:
//   the default `undo-selection-deep` revert strips both clears and is caught
//   with the exact reported symptom (a Delete that reports "deleted 3 tracks",
//   removes none, and destroys the redo entry).
//
// USAGE
//   node scripts/pcb_editor_invariants/run.js [--binary PATH] [--invariant ID]
//        [--self-test] [--revert ID] [--no-substitute] [--headed] [--keep] [--list]
"use strict";

const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const localLib = path.join(os.homedir(), ".local", "lib", "playwright-chromium", "usr", "lib", "x86_64-linux-gnu");
if (fs.existsSync(localLib)) process.env.LD_LIBRARY_PATH = [localLib, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":");
const { chromium } = require("playwright");

// prod serves the live board here; a probe that bound it would take the site down.
const FORBIDDEN_PORT = 7050;
const FIXTURE = path.join(__dirname, "fixture");
const ASSETS = path.join(root, "src", "serve", "assets");
const CACHE = path.join(os.homedir(), ".cache", "netlisp", "pcb-editor-invariants");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── CLI ──────────────────────────────────────────────────────────────────────

function defaultBinary() {
  const candidates = [
    path.join(root, "zig-out", "bin", "netlisp"),
    path.join(root, "zig-out-browser-perf", "bin", "netlisp"),
  ];
  const prod = path.join(os.homedir(), ".cache", "netlisp", "prod");
  if (fs.existsSync(prod)) {
    // Any recent production prefix will do: the probe substitutes the browser
    // assets anyway, so the binary only has to serve the page shell and the APIs.
    const prefixes = fs.readdirSync(prod)
      .map((d) => path.join(prod, d, "bin", "netlisp"))
      .filter((p) => fs.existsSync(p))
      .map((p) => ({ p, t: fs.statSync(p).mtimeMs }))
      .sort((a, b) => b.t - a.t);
    for (const { p } of prefixes) candidates.push(p);
  }
  return candidates.find((p) => fs.existsSync(p)) || candidates[0];
}

function parseArgs(argv) {
  const out = {
    binary: null, url: null, invariant: null, selfTest: false,
    substitute: true, headed: false, keep: false, list: false, revert: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i], take = () => {
      if (++i >= argv.length) throw new Error(`${arg} requires a value`);
      return argv[i];
    };
    if (arg === "--binary") out.binary = path.resolve(take());
    else if (arg === "--url") out.url = take().replace(/\/$/, "");
    else if (arg === "--invariant") out.invariant = take();
    else if (arg === "--self-test") out.selfTest = true;
    else if (arg === "--revert") out.revert = take();
    else if (arg === "--no-substitute") out.substitute = false;
    else if (arg === "--headed") out.headed = true;
    else if (arg === "--keep") out.keep = true;
    else if (arg === "--list") out.list = true;
    else if (arg === "--help" || arg === "-h") {
      console.log("usage: run.js [--binary PATH] [--url LOOPBACK] [--invariant ID]\n" +
        "              [--self-test] [--no-substitute] [--headed] [--keep] [--list]");
      process.exit(0);
    } else throw new Error(`unknown argument ${arg}`);
  }
  if (!out.binary) out.binary = defaultBinary();
  if (out.url && !/^http:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?$/.test(out.url))
    throw new Error("--url must be loopback HTTP");
  if (out.url && Number(new URL(out.url).port) === FORBIDDEN_PORT)
    throw new Error(`refusing to drive port ${FORBIDDEN_PORT} — that is production`);
  return out;
}

// ── fixture project ──────────────────────────────────────────────────────────

function copyTree(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const src = path.join(from, entry.name), dst = path.join(to, entry.name);
    if (entry.isDirectory()) copyTree(src, dst);
    else fs.copyFileSync(src, dst);
  }
}

// One design per invariant. The server persists saved layouts into a `.layouts.json`
// sidecar beside the source, so sharing one design would let invariant 1's saves
// change what invariant 2 opens.
function buildProject(designs) {
  const dir = path.join(CACHE, `run-${process.pid}-${Date.now().toString(36)}`);
  copyTree(FIXTURE, dir);
  const base = fs.readFileSync(path.join(dir, "src", "probe-invariants.sexp"), "utf8");
  fs.rmSync(path.join(dir, "src", "probe-invariants.sexp"));
  for (const name of designs) fs.writeFileSync(path.join(dir, "src", `${name}.sexp`), base);
  return dir;
}

// ── server ───────────────────────────────────────────────────────────────────

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const port = s.address().port;
      s.close(() => (port === FORBIDDEN_PORT ? reject(new Error("refusing production port")) : resolve(port)));
    });
  });
}

async function waitForServer(url, child, text) {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    if (child.exitCode != null) throw new Error(`server exited ${child.exitCode}\n${text()}`);
    try { const r = await fetch(url); if (r.status > 0) return; } catch (_) {}
    await sleep(100);
  }
  throw new Error(`server did not become ready\n${text()}`);
}

// ── fix reverts, for --self-test ─────────────────────────────────────────────
//
// Each entry restores the pre-e2a5f7e behaviour of ONE fix, in the string the
// route handler serves. Every replacement is asserted to apply, so a refactor
// that moves the code fails loudly instead of silently self-testing nothing.

const reverts = {
  "row-aliasing": [
    // persistLayoutNow captured the live arrays into the cached panel row.
    ["var cu=cloneCopper(),savedZones=cloneZones();",
      "var cu={tracks:PCB.tracks||[],vias:PCB.vias||[],rf_paths:PCB.rf_paths||[]},savedZones=PCB.zones||[];"],
    // loadLayoutName handed the row's own arrays straight to the board.
    ["restoreCopperSnap(L.routes);PCB.drc=[];rfLoadBake();",
      "PCB.tracks=L.routes.tracks||[];PCB.vias=L.routes.vias||[];PCB.rf_paths=L.routes.rf_paths||[];PCB.drc=[];rfLoadBake();"],
  ],
  "save-name-race": [
    ["  if(curLayout!==queuedFor){", "  if(false){"],
  ],
  "undo-selection": [
    [" selCuClear();inspClear();\n", " /* reverted: undo left the copper selection dangling */\n"],
  ],
  // Belt-and-braces revert: restoreSnap's clear is redundant with the
  // copperTouched() that clearRoute() reaches whenever the board still holds
  // copper, so reverting the fix line ALONE is masked in reachable states. This
  // strips both, which is what a stale selCu actually looks like on screen.
  "undo-selection-deep": [
    [" selCuClear();inspClear();\n", " /* reverted: undo left the copper selection dangling */\n"],
    [" selCuClear(); // a rip-up/drag can free the selected objects — drop the refs\n inspClear();marqChipsHide();",
      " marqChipsHide();"],
  ],
  "deferred-analysis": [
    ["    if(j.rev!==expect){deferredAnalysisRebump(j.rev);return;}", "    if(j.rev!==rev)return;"],
  ],
  "reattach-undo": [
    [" if(opts.reattached)recordUndo();", " /* reverted: the reattach path recorded no undo step */"],
  ],
  "conflict-409": [
    ["     saveConflicted=true;", "     saveConflicted=false;"],
    ["     showConflictBanner();", "     /* reverted: no visible conflict state */"],
  ],
  "trace-properties": [
    ["rfDropForTracks([track]);track.w=width;track.net=net;",
      "rfDropForTracks([track]);/* reverted: inspector accepted but did not apply width/net */"],
  ],
};

function applyRevert(source, id) {
  const edits = reverts[id];
  if (!edits) throw new Error(`no revert defined for ${id}`);
  let out = source;
  for (const [from, to] of edits) {
    const at = out.indexOf(from);
    if (at < 0) throw new Error(`self-test revert "${id}" no longer matches the source:\n  ${JSON.stringify(from)}`);
    if (out.indexOf(from, at + from.length) >= 0)
      throw new Error(`self-test revert "${id}" matches more than once: ${JSON.stringify(from)}`);
    out = out.slice(0, at) + to + out.slice(at + from.length);
  }
  return out;
}

// ── page harness ─────────────────────────────────────────────────────────────

class Board {
  constructor(ctx, page, state) { this.ctx = ctx; this.page = page; this.state = state; }

  // The page fires a CHAIN of round-trips as it opens (board-role, the live-route
  // reattach probe, a pour refill, then `?derived=1`) and repaints when each
  // answers. Measuring or clicking at `load` races them — that exact race
  // produced a false regression in the zoom gate (FEEDBACK.md 2026-08-29). Wait
  // for the deferred payload to land AND for the request stream to go quiet.
  async settle({ deferred = true, quietMs = 700, timeoutMs = 60000 } = {}) {
    if (deferred) await this.page.waitForFunction(() => PCB && PCB.analysis_deferred === false, null, { timeout: timeoutMs });
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.state.inflight === 0 && Date.now() - this.state.lastActivity > quietMs) return;
      await sleep(80);
    }
    throw new Error("page never went quiet");
  }

  saves() { return this.state.saves; }
  errors() { return this.state.errors; }
  async close() { await this.ctx.close(); }
}

async function openBoard(env, design, opts = {}) {
  const ctx = await env.browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const state = { errors: [], saves: [], inflight: 0, lastActivity: Date.now() };
  page.on("pageerror", (e) => state.errors.push(`pageerror: ${e.message}`));
  page.on("request", (r) => { state.inflight++; state.lastActivity = Date.now(); });
  const settled = () => { state.inflight = Math.max(0, state.inflight - 1); state.lastActivity = Date.now(); };
  page.on("requestfinished", settled);
  page.on("requestfailed", settled);
  page.on("request", (r) => {
    if (r.method() !== "POST" || !r.url().includes("/api/pcb-layouts/")) return;
    let body = null;
    try { body = JSON.parse(r.postData() || "null"); } catch (_) {}
    state.saves.push({ url: new URL(r.url()).pathname, body });
  });

  if (env.substitute) {
    for (const [file, source] of Object.entries(env.scripts)) {
      await page.route(`**/static/${file}`, (route) =>
        route.fulfill({ status: 200, contentType: "application/javascript; charset=utf-8", body: source }));
    }
  }
  for (const [glob, handler] of opts.routes || []) await page.route(glob, handler);

  const board = new Board(ctx, page, state);
  const url = `${env.base}/pcb-layout/${encodeURIComponent(design)}`;
  const response = await page.goto(url, { waitUntil: "load", timeout: 60000 });
  if (!response || response.status() !== 200) throw new Error(`navigation returned ${response && response.status()}`);
  return board;
}

// ── assertion plumbing ───────────────────────────────────────────────────────

class Checks {
  constructor() { this.failures = []; this.notes = []; }
  ok(cond, message, detail) {
    if (!cond) this.failures.push(detail === undefined ? message : `${message} (${JSON.stringify(detail)})`);
  }
  eq(actual, expected, message) {
    this.ok(actual === expected, message, { actual, expected });
  }
  note(line) { this.notes.push(line); }
}

// Two tracks per layout, laid on F.Cu across the fixture board's parts.
const track = (i, layerY) => ({ x1: 4 + i, y1: layerY, x2: 22 + i, y2: layerY, l: 0, w: 0.25, net: "GND" });
const tracks = (n, base = 0) => Array.from({ length: n }, (_, i) => track(i + base, 12 + i * 1.2));

// Click a control through its own bound listener. The saved-layout rows live in
// a collapsed <details> inside a hidden side pane, and the toolstrip collapses
// on narrow viewports, so a pointer click is a viewport-layout assertion this
// probe is not making. Ancestor <details> are opened first so a failure still
// means "the control is gone", not "it was folded away".
async function clickBound(page, selector) {
  const found = await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) return false;
    for (let n = el.parentElement; n; n = n.parentElement) if (n.tagName === "DETAILS") n.open = true;
    el.click();
    return true;
  }, selector);
  if (!found) throw new Error(`no element matched ${selector}`);
}

// Save the board as `name` through the real Save as… button (window.prompt stubbed).
async function saveAs(board, name) {
  await board.page.evaluate((nm) => { window.prompt = () => nm; }, name);
  await clickBound(board.page, "#pcb-saveas");
  await board.page.waitForFunction((nm) => window.PCBActiveLayoutName() === nm, name, { timeout: 20000 });
}

// ── the invariants ───────────────────────────────────────────────────────────

const invariants = [
  {
    id: "trace-properties",
    title: "clicking a trace edits and persists its width and net",
    revert: "trace-properties",
    async run(env, c) {
      const board = await openBoard(env, env.design("trace-properties"));
      try {
        await board.settle();
        const page = board.page;
        const target = await page.evaluate(() => {
          const b = PCB.board || { x: PCB.minx, y: PCB.miny,
            w: Math.max(8, PCB.w / PCB.scale - 2 * PCB.margin), h: Math.max(8, PCB.h / PCB.scale - 2 * PCB.margin) };
          const net = (PCB.netnames || []).includes("GND") ? "GND" : PCB.netnames[0];
          const t = { x1: b.x + 1.5, y1: b.y + 1.5, x2: b.x + Math.min(6, b.w - 1.5), y2: b.y + 1.5,
            l: 0, w: 0.25, net, source: "human" };
          window.PCBAdoptCopper([t], [], [], []);
          const svg = document.getElementById("pcb-svg"), p = svg.createSVGPoint();
          p.x = (((t.x1 + t.x2) / 2) - PCB.minx + PCB.margin) * PCB.scale;
          p.y = (t.y1 - PCB.miny + PCB.margin) * PCB.scale;
          const q = p.matrixTransform(svg.getScreenCTM());
          return { x: q.x, y: q.y, net, other: (PCB.netnames || []).find((n) => n !== net) || "" };
        });
        c.ok(!!target.other, "the fixture exposes a second net for reassignment", target);

        await page.mouse.click(target.x, target.y);
        await page.waitForSelector("#prop-track-width", { timeout: 5000 }).catch(() => {});
        const opened = await page.evaluate(() => ({
          title: (document.querySelector("#prop-body .prop-ref") || {}).textContent || "",
          width: (document.getElementById("prop-track-width") || {}).value,
          net: (document.getElementById("prop-track-net") || {}).value,
          choices: Array.from((document.getElementById("prop-track-net") || { options: [] }).options || []).map((o) => o.value),
        }));
        c.eq(opened.title, "Track", "a plain trace click opened the Properties inspector");
        c.eq(opened.width, "0.25", "the inspector shows the segment width");
        c.eq(opened.net, target.net, "the inspector shows the segment net");
        c.ok(opened.choices.includes(target.other), "the net picker contains the board's other nets", opened.choices);

        await page.fill("#prop-track-width", "0.2");
        await page.press("#prop-track-width", "Enter");
        await sleep(300);
        const widened = await page.evaluate(() => ({
          width: PCB.tracks[0] && PCB.tracks[0].w,
          net: PCB.tracks[0] && PCB.tracks[0].net,
          inspector: !!document.getElementById("prop-track-width"),
          undoDisabled: document.getElementById("pcb-undo").disabled,
        }));
        c.eq(widened.width, 0.2, "typing a width updates the selected trace");
        c.eq(widened.net, target.net, "the width edit leaves the net alone");
        c.eq(widened.inspector, true, "the trace remains selected after editing");
        c.eq(widened.undoDisabled, false, "the width edit creates an undo step");

        await page.selectOption("#prop-track-net", target.other);
        await sleep(300);
        const renamed = await page.evaluate(() => ({ width: PCB.tracks[0] && PCB.tracks[0].w, net: PCB.tracks[0] && PCB.tracks[0].net,
          selected: (document.getElementById("prop-track-net") || {}).value }));
        c.eq(renamed.width, 0.2, "the net edit leaves the custom width alone");
        c.eq(renamed.net, target.other, "choosing another net reassigns the trace");
        c.eq(renamed.selected, target.other, "the reassigned trace stays selected in the inspector");

        await saveAs(board, "trace-edit");
        const saved = board.saves().filter((s) => s.body && s.body.name === "trace-edit").pop();
        const st = saved && saved.body.routes && saved.body.routes.tracks && saved.body.routes.tracks[0];
        c.eq(st && st.w, 0.2, "Save persists the edited width");
        c.eq(st && st.net, target.other, "Save persists the edited net");

        await page.keyboard.press("Control+z");
        await sleep(250);
        c.eq(await page.evaluate(() => PCB.tracks[0] && PCB.tracks[0].net), target.net,
          "one undo restores the previous net");
        await page.keyboard.press("Control+z");
        await sleep(250);
        c.eq(await page.evaluate(() => PCB.tracks[0] && PCB.tracks[0].w), 0.25,
          "a second undo restores the previous width");
        c.ok(board.errors().length === 0, "no page errors", board.errors());
      } finally { await board.close(); }
    },
  },

  {
    id: "row-aliasing",
    title: "a saved-layout row owns its copper; Load clones out of it",
    revert: "row-aliasing",
    async run(env, c) {
      const board = await openBoard(env, env.design("row-aliasing"));
      try {
        await board.settle();
        await board.page.evaluate((ts) => { PCB.tracks.push(...ts); }, tracks(2));
        await saveAs(board, "A");

        const pushed = await board.page.evaluate(() => {
          const row = (PCB.layouts || []).find((L) => L.name === "A");
          if (!row) return { missing: true };
          const before = (row.routes.tracks || []).length;
          const extra = { x1: 30, y1: 30, x2: 40, y2: 30, l: 0, w: 0.25, net: "VOUT", probe: true };
          PCB.tracks.push(extra);
          return {
            before,
            after: (row.routes.tracks || []).length,
            rowSawTheEdit: (row.routes.tracks || []).some((t) => t.probe === true),
            board: PCB.tracks.length,
          };
        });
        c.ok(!pushed.missing, "layout A was cached as a panel row");
        c.eq(pushed.before, 2, "row A cached the two saved tracks");
        c.eq(pushed.after, 2, "pushing into PCB.tracks left the cached row's length alone");
        c.eq(pushed.rowSawTheEdit, false, "the cached row did not absorb the pushed track");
        c.eq(pushed.board, 3, "the live board did take the pushed track");

        await clickBound(board.page, '[data-lay-load="A"]');
        // A revert leaves the board on the row's drifted array; do not wait 20 s for it.
        await board.page.waitForFunction(() => PCB.tracks.length === 2, null, { timeout: 8000 }).catch(() => {});

        const loaded = await board.page.evaluate(() => {
          const row = (PCB.layouts || []).find((L) => L.name === "A");
          const saved = row.routes.tracks || [];
          const key = (t) => [t.x1, t.y1, t.x2, t.y2, t.l, t.w, t.net].join("|");
          return {
            count: PCB.tracks.length,
            matchesRow: PCB.tracks.every((t, i) => key(t) === key(saved[i])),
            sharesIdentity: PCB.tracks.some((t) => saved.indexOf(t) >= 0),
            rowSharesArray: PCB.tracks === saved,
          };
        });
        c.eq(loaded.count, 2, "Load restored exactly the saved copper");
        c.eq(loaded.matchesRow, true, "the loaded board equals the saved row field for field");
        c.eq(loaded.sharesIdentity, false, "no loaded track shares object identity with the row");
        c.eq(loaded.rowSharesArray, false, "the board's track array is not the row's array");
        c.ok(board.errors().length === 0, "no page errors", board.errors());
      } finally { await board.close(); }
    },
  },

  {
    id: "save-name-race",
    title: "a queued save is abandoned when a Load changed the edit target",
    revert: "save-name-race",
    async run(env, c) {
      let release = null;
      const stall = new Promise((r) => { release = r; });
      // Armed only once layouts A and B exist — the setup saves must land for real.
      let arm = false, stalled = 0;
      const routes = [["**/api/pcb-layouts/**", async (route) => {
        if (route.request().method() !== "POST" || !arm) return route.continue();
        if (stalled++ === 0) {
          // Hold the queue open. Released as a 503 rather than a 200: a
          // SUCCESSFUL in-flight save legitimately re-activates the name it
          // wrote (persistLayoutNow's setActiveLayout), which is documented
          // behaviour, not the bug. Failing it isolates the QUEUED save's
          // ownership, which is what this invariant is about.
          await stall;
          return route.fulfill({ status: 503, contentType: "text/plain", body: "probe: stalled save released as unavailable" });
        }
        return route.continue();
      }]];

      const board = await openBoard(env, env.design("save-name-race"), { routes });
      try {
        await board.settle();
        // A = 2 tracks, B = 5. Any POST that names A while carrying 5+ tracks is
        // the bug: layout B's board written into row A.
        await board.page.evaluate((ts) => { PCB.tracks.push(...ts); }, tracks(2));
        await saveAs(board, "A");
        await board.page.evaluate((ts) => { PCB.tracks.push(...ts); }, tracks(3, 10));
        await saveAs(board, "B");
        await clickBound(board.page, '[data-lay-load="A"]');
        await board.page.waitForFunction(() => window.PCBActiveLayoutName() === "A" && PCB.tracks.length === 2,
          null, { timeout: 20000 });

        arm = true;
        const beforeStall = board.saves().length;
        // Save #1 for A — its POST hangs, occupying the save queue.
        await clickBound(board.page, "#pcb-update");
        for (let i = 0; i < 60 && board.saves().length === beforeStall; i++) await sleep(100);
        c.eq(board.saves().length, beforeStall + 1, "the manual save for A issued its POST");

        // Queue an autosave for A behind it (recordUndo → markDirty → 2.5 s timer).
        await board.page.evaluate(() => window.PCBAdoptCopper(PCB.tracks.slice(), PCB.vias.slice(), [], []));
        await sleep(3200);

        // Switch the edit target to B, then edit B.
        await clickBound(board.page, '[data-lay-load="B"]');
        await board.page.waitForFunction(() => window.PCBActiveLayoutName() === "B" && PCB.tracks.length === 5,
          null, { timeout: 20000 });
        await board.page.evaluate((t) => window.PCBAdoptCopper(PCB.tracks.concat([t]), PCB.vias.slice(), [], []),
          track(99, 26));

        release();
        await sleep(6000);

        const named = (nm) => board.saves().filter((s) => s.body && s.body.name === nm);
        const copper = (s) => ((s.body.routes && s.body.routes.tracks) || []).length;
        const crossed = named("A").filter((s) => copper(s) >= 5);
        c.eq(crossed.length, 0, "no POST carried layout A's name with layout B's board",
          crossed.map((s) => ({ name: s.body.name, tracks: copper(s) })));
        c.eq(await board.page.evaluate(() => window.PCBActiveLayoutName()), "B",
          "the abandoned save did not drag the edit target back to A");
        c.ok(named("B").some((s) => copper(s) === 6),
          "the re-armed autosave landed the edited board in layout B",
          board.saves().map((s) => s.body && `${s.body.name}:${copper(s)}`));
        c.ok(board.errors().length === 0, "no page errors", board.errors());
      } finally { release(); await board.close(); }
    },
  },

  {
    id: "undo-selection",
    title: "undo drops the copper selection, so a stale Delete cannot wipe redo",
    // restoreSnap's added clear is redundant with the copperTouched() that
    // clearRoute() reaches while the board still holds copper (see the header),
    // so the honest self-test reverts BOTH clears: that, not the one-line
    // revert, is what a dangling selCu actually looks like on screen.
    revert: "undo-selection-deep",
    async run(env, c) {
      const board = await openBoard(env, env.design("undo-selection"));
      try {
        await board.settle();
        const page = board.page;

        // Two undoable copper edits: undo has somewhere to go and redo something to hold.
        await page.evaluate((ts) => window.PCBAdoptCopper(ts, [], [], []), tracks(2));
        await page.evaluate((ts) => window.PCBAdoptCopper(ts, [], [], []), tracks(3));
        await sleep(400);
        c.eq(await page.evaluate(() => PCB.tracks.length), 3, "three tracks on the board");
        c.eq(await page.$eval("#pcb-undo", (b) => b.disabled), false, "undo has entries");

        // Marquee-equivalent copper selection: Ctrl+A commits through the exact
        // selectionCommit seam a band uses, without pixel maths on the canvas.
        await page.keyboard.press("Control+a");
        await sleep(250);
        const selected = await page.evaluate(() => {
          const chip = document.querySelector('.pcb-selection-chip[data-selection-type="track"]');
          return chip ? chip.textContent : null;
        });
        c.eq(selected, "3 tracks", "the selection caught the copper");

        await page.keyboard.press("Control+z");
        await sleep(500);
        const afterUndo = await page.evaluate(() => ({
          tracks: PCB.tracks.length,
          redoDisabled: document.getElementById("pcb-redo").disabled,
          inspectorRef: (document.querySelector("#prop-body .prop-ref") || {}).textContent || "",
          inspectorButtons: !!document.getElementById("insp-copy"),
        }));
        c.eq(afterUndo.tracks, 2, "undo rewound the copper");
        c.eq(afterUndo.redoDisabled, false, "undo pushed a redo entry");
        c.ok(!/^(Track|Via)$/.test(afterUndo.inspectorRef), "the inspector is not showing copper", afterUndo.inspectorRef);
        c.eq(afterUndo.inspectorButtons, false, "the copper inspector's controls are gone");

        // The bug: a stale selCu made this Delete a no-op that still recorded an
        // undo entry, and recordUndo() empties redoStack.
        await page.keyboard.press("Delete");
        await sleep(500);
        const afterDelete = await page.evaluate(() => ({
          tracks: PCB.tracks.length,
          redoDisabled: document.getElementById("pcb-redo").disabled,
          savemsg: (document.getElementById("pcb-savemsg") || {}).textContent || "",
        }));
        c.eq(afterDelete.tracks, 2, "the stale Delete removed nothing");
        c.eq(afterDelete.redoDisabled, false, "the redo entry survived the stale Delete");
        c.ok(!/^deleted /.test(afterDelete.savemsg), "no delete was reported", afterDelete.savemsg);

        await page.keyboard.press("Control+Shift+z");
        await sleep(500);
        c.eq(await page.evaluate(() => PCB.tracks.length), 3, "the undone edit is still redoable");
        c.ok(board.errors().length === 0, "no page errors", board.errors());
      } finally { await board.close(); }
    },
  },

  {
    id: "deferred-analysis",
    title: "a rev-bumped ?derived=1 answer is re-aimed, not stranded",
    revert: "deferred-analysis",
    async run(env, c) {
      const design = env.design("deferred-analysis");
      let seen = 0, real = null;
      // Every answer carries rev+1: the board this page opened was saved ONCE in
      // another window. The first answer therefore describes a rev this window
      // never loaded; the fix re-aims one bounded retry at the reported rev and
      // the second answer matches it. Pre-fix, a non-matching rev was silently
      // dropped and analysis_deferred stayed true forever.
      const routes = [[`**/pcb-layout/${design}?*derived=1*`, async (route) => {
        const response = await route.fetch();
        const payload = await response.json();
        if (!real) real = payload;
        seen++;
        return route.fulfill({
          status: 200, contentType: "application/json",
          body: JSON.stringify({ ...payload, rev: (payload.rev || 0) + 1 }),
        });
      }]];

      const board = await openBoard(env, design, { routes });
      try {
        const openedRev = await board.page.evaluate(() => PCB.rev);
        await board.settle({ timeoutMs: 25000 });
        const after = await board.page.evaluate(() => ({
          deferred: PCB.analysis_deferred,
          rev: PCB.rev,
          maskRelief: (((PCB.mask_relief || {}).openings) || []).length,
          traceEm: ((PCB.trace_em || {}).analyses || []).length,
          powerIntegrity: ((PCB.power_integrity || {}).nets || []).length,
          planeFills: (PCB.plane_fills || []).length,
          drc: (PCB.drc || []).length,
          savemsg: (document.getElementById("pcb-savemsg") || {}).textContent || "",
        }));
        c.eq(seen, 2, "the deferred analysis re-aimed exactly one retry", seen);
        c.eq(after.deferred, false, "analysis_deferred cleared");
        c.eq(after.rev, openedRev, "the page did NOT adopt the other window's rev");
        c.ok(real, "the server answered ?derived=1 at least once");
        // Every field the payload carries has to be the one on screen.
        c.eq(after.maskRelief, ((real.mask_relief || {}).openings || []).length, "mask relief came from the payload");
        c.eq(after.traceEm, ((real.trace_em || {}).analyses || []).length, "trace_em came from the payload");
        c.eq(after.powerIntegrity, ((real.power_integrity || {}).nets || []).length, "power_integrity came from the payload");
        c.eq(after.planeFills, (real.plane_fills || []).length, "plane fills came from the payload");
        c.eq(after.drc, (real.drc || []).length, "the DRC list came from the payload");
        c.ok(after.planeFills > 0, "the payload was not empty — the assertions above have teeth", after.planeFills);
        c.ok(/newer save made in another window/.test(after.savemsg),
          "the page says the numbers answer another window's save", after.savemsg);
        c.ok(board.errors().length === 0, "no page errors", board.errors());
      } finally { await board.close(); }
    },
  },

  {
    id: "reattach-undo",
    title: "a reattached live route records the undo step its missing click owed",
    revert: "reattach-undo",
    async run(env, c) {
      const design = env.design("reattach-undo");
      const final = {
        tracks: tracks(4), vias: [], drc: [], rf_paths: [],
        routed: 4, total: 4, stage: "global",
      };
      let polls = 0;
      const routes = [[`**/api/route-live/${design}*`, (route) => {
        if (route.request().method() !== "GET") return route.continue();
        polls++;
        // Poll 1 is pcb_replay.js's page-init liveReattach probe (running:true →
        // liveBegin with reattached:true). Poll 2 finishes the job.
        const body = polls === 1
          ? { gen: 1, attempt: 0, running: true, done: false, err: null, cancelled: false, routed: 0, total: 4, elapsed_ms: 10, next: 0, events: [] }
          : { gen: 1, attempt: 0, running: false, done: true, err: null, cancelled: false, routed: 4, total: 4, elapsed_ms: 900, next: 0, events: [], final };
        return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
      }]];

      const board = await openBoard(env, design, { routes });
      try {
        const page = board.page;
        await page.waitForFunction(() => PCB && PCB.analysis_deferred === false, null, { timeout: 60000 });
        // The reattach path applies the final and then persists it, so let the
        // whole chain run before reading the undo state.
        await page.waitForFunction(() => PCB.tracks.length === 4, null, { timeout: 30000 })
          .catch(() => {});
        await sleep(1500);

        const state = await page.evaluate(() => ({
          tracks: PCB.tracks.length,
          undoDisabled: document.getElementById("pcb-undo").disabled,
          replayStatus: (document.getElementById("rp-status") || {}).textContent || "",
          hasDriver: !!window.PCBLiveRoute,
        }));
        c.eq(state.hasDriver, true, "the live-route driver loaded");
        c.ok(polls >= 2, "the reattach probe and its poll both ran", polls);
        c.eq(state.tracks, 4, "the finished route's copper landed on the board");
        c.eq(state.undoDisabled, false, "applying a REATTACHED result recorded an undo entry");
        c.ok(/Ctrl\+Z restores what was here/.test(state.replayStatus),
          "the reattach status points at the new undo step", state.replayStatus);

        // The CLICK path must be unchanged: runRoute already recorded its undo
        // step before sending the job, so a non-reattached apply must add none.
        const clickPath = await page.evaluate((f) => {
          const before = document.getElementById("pcb-undo").disabled;
          // Drain the stack so "no new entry" is observable as still-disabled.
          while (!document.getElementById("pcb-undo").disabled) document.getElementById("pcb-undo").click();
          const drained = document.getElementById("pcb-undo").disabled;
          window.PCBApplyRouteResult(f, { clr: 0 });
          return { before, drained, after: document.getElementById("pcb-undo").disabled };
        }, final);
        c.eq(clickPath.drained, true, "the undo stack drained for the click-path check");
        c.eq(clickPath.after, true, "the click path recorded NO extra undo entry");
        c.ok(board.errors().length === 0, "no page errors", board.errors());
      } finally { await board.close(); }
    },
  },

  {
    id: "conflict-409",
    title: "a 409 raises a visible conflict state and stops arming doomed saves",
    revert: "conflict-409",
    async run(env, c) {
      // 409 only AFTER the page owns a named layout. The idle autosave declines
      // outright without one ("no-name"), which would make the "no second POST"
      // assertion pass for a reason that has nothing to do with the fix.
      let arm = false, conflicts = 0;
      const routes = [["**/api/pcb-layouts/**", (route) => {
        if (route.request().method() !== "POST" || !arm) return route.continue();
        conflicts++;
        return route.fulfill({ status: 409, contentType: "application/json", body: JSON.stringify({ error: "conflict", rev: 99 }) });
      }]];

      const board = await openBoard(env, env.design("conflict-409"), { routes });
      try {
        const page = board.page;
        await board.settle();
        await page.evaluate((ts) => { PCB.tracks.push(...ts); }, tracks(2));
        await saveAs(board, "A");
        c.eq(await page.evaluate(() => window.PCBActiveLayoutName()), "A",
          "the page is editing a named layout, so the idle autosave can arm");

        // Another window saves. Every save from here on is doomed. The edit
        // below arms the idle autosave (recordUndo → markDirty), which POSTs.
        arm = true;
        await page.evaluate(() => window.PCBAdoptCopper(PCB.tracks.slice(), PCB.vias.slice(), [], []));
        await page.waitForSelector("#pcb-conflict-banner", { timeout: 20000 }).catch(() => {});
        await sleep(500);

        const first = await page.evaluate(() => {
          const bar = document.getElementById("pcb-conflict-banner");
          return {
            banners: document.querySelectorAll("#pcb-conflict-banner").length,
            text: bar ? (bar.querySelector("span") || {}).textContent || "" : "",
            savemsg: (document.getElementById("pcb-savemsg") || {}).textContent || "",
            draft: !!localStorage.getItem("pcb-draft:" + PCB.name),
          };
        });
        c.eq(conflicts, 1, "exactly one save POST reached the conflicting server", conflicts);
        c.eq(first.banners, 1, "a conflict banner is visible");
        c.ok(/saved in another window/.test(first.text), "the banner says what happened", first.text);
        c.ok(/reload to continue/.test(first.savemsg), "the status line says what happened", first.savemsg);
        c.eq(first.draft, true, "the unsaved work was held in a draft");

        // A subsequent edit must NOT arm another save that is guaranteed to 409.
        // (Explicit Save as…/Update deliberately still POST — user intent — so
        // this drives the IDLE autosave path only.)
        await page.evaluate(() => window.PCBAdoptCopper(PCB.tracks.slice(), PCB.vias.slice(), [], []));
        await sleep(6000);
        const second = await page.evaluate(() => ({
          banners: document.querySelectorAll("#pcb-conflict-banner").length,
          dirty: !!localStorage.getItem("pcb-draft:" + PCB.name),
        }));
        c.eq(conflicts, 1, "the edit after the conflict issued NO further save POST", conflicts);
        c.eq(second.banners, 1, "the conflict banner survived the edit");
        c.eq(second.dirty, true, "the work is still held in the draft, not silently dropped");
        c.ok(board.errors().length === 0, "no page errors", board.errors());
      } finally { await board.close(); }
    },
  },
];

// ── driver ───────────────────────────────────────────────────────────────────

function readScripts() {
  return {
    "pcb_board.js": fs.readFileSync(path.join(ASSETS, "pcb_board.js"), "utf8"),
    "pcb_replay.js": fs.readFileSync(path.join(ASSETS, "pcb_replay.js"), "utf8"),
  };
}

async function runOne(inv, env) {
  const c = new Checks();
  try { await inv.run(env, c); }
  catch (e) { c.failures.push(`threw: ${e && e.message ? e.message : e}`); }
  return c;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.list) {
    for (const inv of invariants) console.log(`${inv.id}\t${inv.title}`);
    return 0;
  }
  const selected = options.invariant
    ? invariants.filter((i) => i.id === options.invariant)
    : invariants;
  if (!selected.length) throw new Error(`unknown invariant ${options.invariant}`);
  if (options.selfTest && !options.substitute)
    throw new Error("--self-test needs asset substitution (it serves a reverted script)");

  const designs = new Map(selected.map((i) => [i.id, `probe-${i.id}`]));
  fs.mkdirSync(CACHE, { recursive: true });
  const project = buildProject([...designs.values()]);

  let server = null, serverText = "", base = options.url;
  const started = Date.now();
  const results = [];
  try {
    if (!base) {
      if (!fs.existsSync(options.binary)) throw new Error(`no netlisp binary at ${options.binary}\n` +
        "  pass --binary PATH (any recent build works: the probe substitutes the browser assets)");
      const port = await freePort();
      base = `http://127.0.0.1:${port}`;
      server = spawn(options.binary, ["serve", "--project-dir", project, "--port", String(port), "--skip-warmup"], {
        cwd: root, env: { ...process.env, NETLISP_DEV: "1" }, stdio: ["ignore", "pipe", "pipe"],
      });
      // A Ctrl+C would otherwise leave the server holding a port and a project
      // dir this run is about to delete — pkill is not an option on a machine
      // that also runs production on 7050, so the child must die with its parent.
      const reap = () => { try { server.kill("SIGKILL"); } catch (_) {} process.exit(130); };
      process.once("SIGINT", reap); process.once("SIGTERM", reap);
      const append = (chunk) => { serverText = (serverText + chunk.toString()).slice(-16000); };
      server.stdout.on("data", append); server.stderr.on("data", append);
      await waitForServer(`${base}/`, server, () => serverText);
    }

    // With --url the caller's server must already be serving THIS project dir.
    // Say so instead of failing six invariants on 404s.
    let probeStatus = "unreachable";
    try {
      probeStatus = (await fetch(`${base}/pcb-layout/${encodeURIComponent([...designs.values()][0])}`)).status;
    } catch (_) {}
    if (probeStatus !== 200) {
      throw new Error(`the server at ${base} does not serve the probe fixture (${probeStatus}).\n` +
        `  start it with --project-dir ${project}, or drop --url and let this runner start its own.`);
    }

    const browser = await chromium.launch({ headless: !options.headed });
    try {
      const clean = readScripts();
      for (const inv of selected) {
        const env = {
          browser, base, substitute: options.substitute, scripts: clean,
          design: () => designs.get(inv.id),
        };
        const c = await runOne(inv, env);
        results.push({ inv, mode: "fix", pass: c.failures.length === 0, checks: c });
        const label = `${inv.id.padEnd(18)} ${inv.title}`;
        console.log(`${c.failures.length === 0 ? "PASS" : "FAIL"} ${label}`);
        for (const f of c.failures) console.log(`       · ${f}`);
        for (const n of c.notes) console.log(`       ~ ${n}`);

        if (!options.selfTest) continue;
        // Re-run the SAME invariant against a scratch copy of the asset with the
        // fix textually reverted. It must fail; a probe never shown to fail is
        // not evidence. src/ is untouched — only the served string changes.
        const reverted = {
          ...clean,
          "pcb_board.js": applyRevert(clean["pcb_board.js"], options.revert || inv.revert),
        };
        // Rebuild the design's sidecar state: the clean pass saved layouts into it.
        const sidecar = path.join(project, "src", `${designs.get(inv.id)}.layouts.json`);
        if (fs.existsSync(sidecar)) fs.rmSync(sidecar);
        const cm = await runOne(inv, { ...env, scripts: reverted });
        const caught = cm.failures.length > 0;
        results.push({ inv, mode: "revert", pass: caught, checks: cm });
        console.log(`${caught ? "PASS" : "FAIL"} ${inv.id.padEnd(18)} self-test: reverting "${options.revert || inv.revert}" is ${caught ? "caught" : "NOT CAUGHT"}`);
        for (const f of cm.failures) console.log(`       · caught: ${f}`);
      }
    } finally { await browser.close(); }
  } finally {
    if (server) {
      server.kill("SIGTERM");
      await sleep(200);
      if (server.exitCode == null) server.kill("SIGKILL");
    }
    if (!options.keep) fs.rmSync(project, { recursive: true, force: true });
    else console.log(`pcb_editor_invariants: kept ${project}`);
  }

  const failed = results.filter((r) => !r.pass);
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  console.log(`pcb_editor_invariants: ${results.length - failed.length}/${results.length} in ${secs}s`);
  return failed.length ? 1 : 0;
}

main().then((code) => process.exit(code),
  (e) => { console.error(`pcb_editor_invariants: FAIL: ${e && e.stack || e}`); process.exit(1); });
