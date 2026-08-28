#!/usr/bin/env node
"use strict";

// Real-browser assembly interaction benchmark. It starts an isolated local
// netlisp server unless --url is supplied, opens the actual assembly page, and
// adds the viewer's opt-in fbench flags to that page's PCB iframe request.
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const { execFileSync, spawn } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const localLib = path.join(os.homedir(), ".local", "lib", "playwright-chromium", "usr", "lib", "x86_64-linux-gnu");
if (fs.existsSync(localLib)) {
  process.env.LD_LIBRARY_PATH = [localLib, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":");
}
const { chromium } = require("playwright");
// Keep the user-facing control inventory beside the timings that exercise it.
// manifest.test.js parses these JSON literals and proves that the delegated
// route declaration, this inventory, and COVERED_SCENARIOS remain in lockstep.
const PRIMARY_CONTROLS = Object.freeze({
  "search": { "selector": "#assembly-search" },
  "type_filter": { "selector": "#type-filters input" },
  "show_dnp": { "selector": "#show-dnp" },
  "bom_select": { "selector": "#bom-list .bom-row" },
  "selection_clear": { "selector": "#clear-selection" },
  "panel_navigation": { "selector": "#guide-tab, .layer-menu > summary" },
  "cam_review": { "selector": "#cam-review" },
  "cam_layer_visibility": { "selector": "[data-cam-layer=\"copper\"]" },
  "board_side": { "selector": "#board-side" },
  "rotate": { "selector": "#board-rotate-left, #board-rotate-right" },
  "model_3d_navigation": { "selector": "nav[aria-label=\"Design views\"] a[href*=\"view=3d\"]" },
  "load_3d_models": {
    "selector": "#load-3d-models",
    "excluded": "cache misses intentionally POST generated sprites; the read-only gate exercises the 3D navigation link instead"
  }
});
const NON_CONTROL_SCENARIOS = Object.freeze(["exact_cam_ready", "pan", "zoom"]);
const COVERED_SCENARIOS = Object.freeze([
  "exact_cam_ready", "search", "type_filter", "show_dnp", "bom_select", "selection_clear",
  "panel_navigation", "cam_review", "cam_layer_visibility", "board_side", "rotate", "model_3d_navigation",
  "pan", "zoom"
]);

function assertCoverageContract() {
  const controlScenarios = Object.entries(PRIMARY_CONTROLS)
    .filter(([, record]) => !record.excluded)
    .map(([scenario]) => scenario);
  const expected = [...NON_CONTROL_SCENARIOS, ...controlScenarios].sort();
  const actual = [...COVERED_SCENARIOS].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`assembly scenario inventory drifted: ${JSON.stringify({ expected, actual })}`);
  }
}
assertCoverageContract();

function usage(message) {
  if (message) console.error(`assembly_browser_perf: ${message}`);
  console.error("usage: run.js [--project-dir DIR] [--binary FILE] [--design NAME] [--reps N] [--baseline FILE] [--record] [--url URL]");
  process.exit(2);
}

function argsRead(argv) {
  const out = {
    projectDir: path.join(root, "projects", "designs"),
    binary: path.join(root, "zig-out", "bin", "netlisp"),
    design: "barracuda-base",
    reps: 3,
    baseline: path.join(root, "docs", "benchmarks", "pcb-browser", "baseline.json"),
    record: false,
    url: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--record") out.record = true;
    else if (["--project-dir", "--binary", "--design", "--reps", "--baseline", "--url"].includes(a)) {
      if (++i >= argv.length) usage(`${a} needs a value`);
      const key = { "--project-dir": "projectDir", "--binary": "binary", "--design": "design", "--reps": "reps", "--baseline": "baseline", "--url": "url" }[a];
      out[key] = key === "reps" ? Number(argv[i]) : argv[i];
    } else usage(`unknown argument ${a}`);
  }
  if (!Number.isInteger(out.reps) || out.reps < 1 || out.reps > 20) usage("--reps must be an integer from 1 to 20");
  out.projectDir = path.resolve(out.projectDir);
  out.binary = path.resolve(out.binary);
  out.baseline = path.resolve(out.baseline);
  if (out.url) {
    let parsed;
    try { parsed = new URL(out.url); } catch (_) { usage("--url must be a valid loopback URL"); }
    if (!["http:", "https:"].includes(parsed.protocol) || !["127.0.0.1", "localhost", "[::1]"].includes(parsed.hostname)) {
      usage("--url is restricted to a loopback HTTP(S) server");
    }
  }
  if (out.record && out.url) usage("--record cannot be combined with --url");
  return out;
}

function percentile(values, q) {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.round(q * (sorted.length - 1))))];
}

function rounded(n) { return Number(n.toFixed(2)); }

async function parentAction(page, action, settle) {
  await page.evaluate(() => { window.__assemblyActionStart = performance.now(); });
  await action();
  if (settle) await settle();
  const ended = await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(performance.now())))));
  const started = await page.evaluate(() => window.__assemblyActionStart);
  return rounded(ended - started);
}

async function settleParent(page) {
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

async function reviewPaintState(boardFrame) {
  const state = await boardFrame.evaluate(() => window.PCBReviewPainted?.() || null);
  if (!state || !(state.revision > 0)) throw new Error(`assembly iframe has no painted review state: ${JSON.stringify(state)}`);
  return state;
}

async function waitForReviewPaint(boardFrame, afterRevision, expected) {
  await boardFrame.waitForFunction(({ afterRevision: after, expected: want }) => {
    const state = window.PCBReviewPainted?.();
    if (!state || !(state.revision > after)) return false;
    if (want.side != null && state.side !== want.side) return false;
    if (want.rotation != null && state.rotation !== want.rotation) return false;
    if (want.layers) {
      for (const [name, visible] of Object.entries(want.layers)) {
        if (state.layers?.[name] !== visible) return false;
      }
    }
    return true;
  }, { afterRevision, expected }, { timeout: 10000 });
  return reviewPaintState(boardFrame);
}

function expectedFirstPartyFailure(url, status) {
  const pathname = new URL(url).pathname;
  return (pathname.startsWith("/api/route-live/") && status === 404) || pathname === "/favicon.ico";
}

function expectedConsoleFailure(message, source) {
  if (!source.url || !message.text().includes("404")) return false;
  const pathname = new URL(source.url).pathname;
  return pathname.startsWith("/api/route-live/") || pathname === "/favicon.ico";
}

async function measureShellControls(page) {
  const controls = {};
  const frame = page.locator("#pcb-frame");
  const frameHandle = await frame.elementHandle();
  const boardFrame = frameHandle && await frameHandle.contentFrame();
  if (!boardFrame) throw new Error("assembly PCB iframe is unavailable");
  const boardScene = boardFrame.locator(".pcb-scene-shell");
  await boardScene.waitFor({ state: "visible" });
  const camReview = page.locator("#cam-review");
  if ((await camReview.getAttribute("aria-pressed")) !== "true") throw new Error("CAM Review was not active before control measurement");
  const beforeSemantic = await reviewPaintState(boardFrame);
  await camReview.click();
  await page.waitForFunction(() => document.querySelector("#cam-review")?.getAttribute("aria-pressed") === "false");
  await waitForReviewPaint(boardFrame, beforeSemantic.revision, {});
  const beforeCamRestore = await reviewPaintState(boardFrame);
  controls.cam_review_ms = await parentAction(page, () => camReview.click(), async () => {
    await page.waitForFunction(() => document.querySelector("#cam-review")?.getAttribute("aria-pressed") === "true");
    const painted = await waitForReviewPaint(boardFrame, beforeCamRestore.revision, {});
    if (!painted.cam_review) throw new Error("CAM Review toggle did not restore the generated manufacturing artwork");
  });
  controls.search_ms = await parentAction(page,
    () => page.locator("#assembly-search").fill("U19"),
    async () => {
      await page.locator("#search-results .result-item").first().waitFor({ state: "visible" });
      const value = await page.locator("#assembly-search").inputValue();
      if (value !== "U19") throw new Error(`assembly search value did not change: ${value}`);
    });

  const filter = page.locator("#type-filters input").first();
  const beforeFiltered = await page.locator("#search-results .result-item").count();
  controls.type_filter_ms = await parentAction(page, () => filter.uncheck(),
    () => page.waitForFunction((count) => !document.querySelector("#type-filters input")?.checked && document.querySelectorAll("#search-results .result-item").length !== count, beforeFiltered));
  await filter.check();
  await page.waitForFunction((count) => document.querySelectorAll("#search-results .result-item").length === count, beforeFiltered);
  await page.locator("#assembly-search").fill("");
  await settleParent(page);

  const dnp = page.locator("#show-dnp");
  const beforeDnp = await page.locator("#bom-list .bom-row").count();
  controls.show_dnp_ms = await parentAction(page, () => dnp.check(),
    () => page.waitForFunction((count) => document.querySelectorAll("#bom-list .bom-row").length !== count, beforeDnp));
  await dnp.uncheck();
  await page.waitForFunction((count) => document.querySelectorAll("#bom-list .bom-row").length === count, beforeDnp);
  await settleParent(page);

  const firstBom = page.locator("#bom-list .bom-row").first();
  const bomKey = await firstBom.getAttribute("data-key");
  if (!bomKey) throw new Error("assembly BOM selection fixture has no keyed row");
  controls.bom_select_ms = await parentAction(page,
    () => firstBom.press("Enter"),
    async () => {
      await page.waitForFunction((key) => {
        const row = document.querySelector(`#bom-list .bom-row[data-key="${CSS.escape(key)}"]`);
        const url = new URL(location.href);
        return row?.classList.contains("selected") &&
          url.searchParams.get("type") === "bom" && url.searchParams.get("q") === key;
      }, bomKey);
      if (!(await page.locator("#selection-title").textContent())?.trim()) {
        throw new Error("assembly BOM selection published no detail title");
      }
    });

  // BOM rows intentionally keep their compact inline selection and therefore
  // have no visible Clear button. Restore with the ordinary Escape shortcut,
  // then focus one normal part result to exercise the visible Clear control.
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("#bom-list .bom-row.selected"));
  await page.locator("#assembly-search").fill("U19");
  const partResult = page.locator("#search-results .result-item").first();
  await partResult.waitFor({ state: "visible" });
  await partResult.press("Enter");
  await page.locator("#selection").waitFor({ state: "visible" });
  controls.selection_clear_ms = await parentAction(page,
    () => page.locator("#clear-selection").click(),
    () => page.waitForFunction(() => {
      const url = new URL(location.href);
      return document.querySelector("#selection")?.hidden &&
        !document.querySelector("#bom-list .bom-row.selected") &&
        !url.searchParams.has("type") && !url.searchParams.has("q");
    }));
  await page.locator("#assembly-search").fill("");
  await settleParent(page);

  const guideTab = page.locator("#guide-tab");
  if (await guideTab.count()) {
    controls.panel_navigation_ms = await parentAction(page, async () => {
      await guideTab.click();
      const guideRow = page.locator("#guide-list .guide-list-item").first();
      if (await guideRow.count()) await guideRow.click();
    }, () => page.waitForFunction(() => {
      const workspace = document.querySelector("#guide-workspace");
      const article = document.querySelector("#rework-guide");
      const list = document.querySelector("#guide-list");
      return workspace && !workspace.hidden &&
        ((article && article.textContent.trim().length > 0) || (list && !list.hidden));
    }));
    if (await page.locator("#guide-back:visible").count()) {
      await page.locator("#guide-back").click();
      await page.locator("#guide-list").waitFor({ state: "visible" });
    }
    await page.locator("#parts-tab").click();
    await page.locator("#assembly-panel").waitFor({ state: "visible" });
  } else {
    const details = page.locator(".layer-menu");
    controls.panel_navigation_ms = await parentAction(page,
      () => details.locator("summary").click(),
      () => page.waitForFunction(() => document.querySelector(".layer-menu")?.open));
    const after = await details.locator(".layer-menu-pop").boundingBox();
    if (!after || !(after.width > 0 && after.height > 0)) throw new Error("assembly layer panel opened without a rendered popup");
    await details.locator("summary").click();
    await page.waitForFunction(() => !document.querySelector(".layer-menu")?.open);
  }

  const layerMenu = page.locator(".layer-menu");
  if (!(await layerMenu.evaluate((element) => element.open))) {
    await layerMenu.locator("summary").click();
    await page.waitForFunction(() => document.querySelector(".layer-menu")?.open);
  }
  const copper = page.locator('[data-cam-layer="copper"]');
  if (!(await copper.isChecked())) throw new Error("assembly face-copper control did not start enabled");
  const beforeCopperPaint = await reviewPaintState(boardFrame);
  controls.cam_layer_visibility_ms = await parentAction(page,
    () => copper.uncheck(),
    async () => {
      await page.waitForFunction(() => !document.querySelector('[data-cam-layer="copper"]')?.checked);
      await waitForReviewPaint(boardFrame, beforeCopperPaint.revision, { layers: { copper: false } });
    });
  const beforeCopperRestore = await reviewPaintState(boardFrame);
  await copper.check();
  await page.waitForFunction(() => document.querySelector('[data-cam-layer="copper"]')?.checked);
  await waitForReviewPaint(boardFrame, beforeCopperRestore.revision, { layers: { copper: true } });
  await layerMenu.locator("summary").click();
  await page.waitForFunction(() => !document.querySelector(".layer-menu")?.open);
  await settleParent(page);

  const side = page.locator("#board-side");
  const beforeSidePaint = await reviewPaintState(boardFrame);
  controls.board_side_ms = await parentAction(page, () => side.click(),
    async () => {
      await page.waitForFunction(() => document.querySelector("#board-side").getAttribute("aria-pressed") === "true");
      await waitForReviewPaint(boardFrame, beforeSidePaint.revision, { side: "bottom", rotation: 0 });
    });
  const beforeSideRestore = await reviewPaintState(boardFrame);
  await side.click();
  await page.waitForFunction(() => document.querySelector("#board-side").getAttribute("aria-pressed") === "false");
  await waitForReviewPaint(boardFrame, beforeSideRestore.revision, { side: "top", rotation: 0 });
  await settleParent(page);

  const beforeRotation = await page.locator("#board-orientation").textContent();
  const beforeRotationPaint = await reviewPaintState(boardFrame);
  controls.rotate_ms = await parentAction(page, () => page.locator("#board-rotate-right").click(),
    async () => {
      await page.waitForFunction((before) => document.querySelector("#board-orientation").textContent !== before, beforeRotation);
      await waitForReviewPaint(boardFrame, beforeRotationPaint.revision, { side: "top", rotation: 90 });
    });
  const beforeRotationRestore = await reviewPaintState(boardFrame);
  await page.locator("#board-rotate-left").click();
  await page.waitForFunction((before) => document.querySelector("#board-orientation").textContent === before, beforeRotation);
  await waitForReviewPaint(boardFrame, beforeRotationRestore.revision, { side: "top", rotation: 0 });
  await settleParent(page);

  const modelLink = page.locator('nav[aria-label="Design views"] a[href*="view=3d"]').first();
  const modelHref = await modelLink.getAttribute("href");
  if (!modelHref || !new URL(modelHref, page.url()).searchParams.has("view")) {
    throw new Error(`assembly 3D navigation link is unavailable: ${modelHref}`);
  }
  let modelPage;
  controls.model_3d_navigation_ms = await parentAction(page, async () => {
    const opened = page.context().waitForEvent("page", { timeout: 10000 });
    await modelLink.click({ button: "middle" });
    modelPage = await opened;
  }, async () => {
    await modelPage.waitForLoadState("domcontentloaded");
    await modelPage.locator("#pcb-3d-canvas").waitFor({ state: "visible", timeout: 30000 });
    await modelPage.waitForFunction(() => {
      const canvas = document.querySelector("#pcb-3d-canvas");
      const status = document.querySelector("#pcb-3d-status");
      return canvas && canvas.width > 0 && canvas.height > 0 && status && getComputedStyle(status).display === "none";
    }, null, { timeout: 30000 });
  });
  const openedUrl = new URL(modelPage.url());
  if (openedUrl.origin !== new URL(page.url()).origin || openedUrl.searchParams.get("view") !== "3d") {
    throw new Error(`assembly 3D navigation opened ${openedUrl.href}`);
  }
  // Do not close a streaming STEP scene and normalize aborted reads as success.
  // Drain it outside the base-navigation timing, then prove the full model set
  // arrived before closing the auxiliary tab.
  await modelPage.waitForFunction(() => {
    const button = document.querySelector("#pcb3d-export-step");
    return button && !button.disabled;
  }, null, { timeout: 90000 });
  const progress = await modelPage.evaluate(() => window.PCB3D?.modelProgress?.());
  if (!progress || !(progress.expected > 0) || progress.pending !== 0 || progress.loaded !== progress.expected) {
    throw new Error(`assembly 3D navigation left an incomplete model scene: ${JSON.stringify(progress)}`);
  }
  await modelPage.close();
  return controls;
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const port = s.address().port;
      s.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

async function waitForServer(url, server, log) {
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    if (server.exitCode !== null) throw new Error(`netlisp exited ${server.exitCode} before listening\n${log()}`);
    try {
      const response = await fetch(url, { redirect: "manual" });
      if (response.status >= 200 && response.status < 400) return;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`netlisp did not become ready within 120 s\n${log()}`);
}

function stopServer(server) {
  if (!server || server.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(() => { if (server.exitCode === null) server.kill("SIGKILL"); }, 5000);
    server.once("exit", () => { clearTimeout(timer); resolve(); });
    server.kill("SIGTERM");
  });
}

function projectOverlay(projectDir) {
  const overlay = fs.mkdtempSync(path.join(os.tmpdir(), "netlisp-assembly-perf-"));
  try {
    for (const entry of fs.readdirSync(projectDir)) {
      if (entry === "lib") continue;
      if (entry === "src") {
        fs.cpSync(path.join(projectDir, entry), path.join(overlay, entry), {
          recursive: true,
          mode: fs.constants.COPYFILE_FICLONE,
        });
        continue;
      }
      fs.symlinkSync(path.join(projectDir, entry), path.join(overlay, entry));
    }
    const sourceLib = path.join(projectDir, "lib");
    const overlayLib = path.join(overlay, "lib");
    fs.mkdirSync(overlayLib);
    for (const entry of fs.readdirSync(sourceLib)) {
      if (entry === "models") {
        const sourceModels = path.join(sourceLib, entry);
        const overlayModels = path.join(overlayLib, entry);
        fs.mkdirSync(overlayModels);
        for (const modelEntry of fs.readdirSync(sourceModels)) {
          if (modelEntry === ".sprites") continue;
          fs.symlinkSync(path.join(sourceModels, modelEntry), path.join(overlayModels, modelEntry));
        }
        fs.mkdirSync(path.join(overlayModels, ".sprites"));
        continue;
      }
      fs.symlinkSync(path.join(sourceLib, entry), path.join(overlayLib, entry));
    }
    return overlay;
  } catch (error) {
    fs.rmSync(overlay, { recursive: true, force: true });
    throw error;
  }
}

async function runOne(browser, baseUrl, design) {
  const context = await browser.newContext({
    viewport: { width: 1600, height: 900 },
    deviceScaleFactor: 1,
    serviceWorkers: "block",
  });
  try {
    return await runOneInContext(context, baseUrl, design);
  } finally {
    await context.close();
  }
}

async function runOneInContext(context, baseUrl, design) {
  const origin = new URL(baseUrl).origin;
  const network = { blocked_mutations: [], blocked_external: [], failures: [], cam_requests: 0 };
  const errors = [];
  const watchedPages = new WeakSet();
  function watchPage(candidate) {
    if (watchedPages.has(candidate)) return;
    watchedPages.add(candidate);
    candidate.on("pageerror", (error) => errors.push(String(error)));
    candidate.on("console", (message) => {
      if (message.type() !== "error") return;
      const source = message.location();
      if (expectedConsoleFailure(message, source)) return;
      const where = source.url ? ` (${source.url}:${source.lineNumber + 1}:${source.columnNumber + 1})` : "";
      errors.push(`console: ${message.text()}${where}`);
    });
  }
  context.on("page", watchPage);
  context.on("response", (response) => {
    const url = new URL(response.url());
    if (url.origin === origin && response.status() >= 400 && !expectedFirstPartyFailure(response.url(), response.status())) {
      network.failures.push(`${response.status()} ${url.pathname}`);
    }
  });
  context.on("requestfailed", (request) => {
    const url = new URL(request.url());
    const blockedLabel = `${request.method().toUpperCase()} ${url.pathname}`;
    if (url.origin === origin && !network.blocked_mutations.includes(blockedLabel)) {
      network.failures.push(`${blockedLabel}: ${request.failure()?.errorText || "failed"}`);
    }
  });
  await context.addInitScript(() => {
    window.__assemblyLongTasks = [];
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) window.__assemblyLongTasks.push({ start: entry.startTime, duration: entry.duration });
      }).observe({ type: "longtask", buffered: true });
    } catch (_) {}
  });
  await context.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (!["http:", "https:"].includes(url.protocol)) return route.continue();
    if (url.origin !== origin) {
      network.blocked_external.push(request.url());
      return route.abort("blockedbyclient");
    }
    const method = request.method().toUpperCase();
    if (method === "GET" && url.pathname.startsWith("/api/pcb-cam/")) network.cam_requests++;
    // This POST is a read-only calculation (the same exception used by the
    // all-pages browser gate), not a project mutation. The 3D page requests it
    // while deriving its review status.
    if (method === "POST" && /^\/api\/pcb-drc\/[^/]+$/.test(url.pathname)) return route.continue();
    if (!["GET", "HEAD", "OPTIONS"].includes(method)) {
      network.blocked_mutations.push(`${method} ${url.pathname}`);
      return route.abort("blockedbyclient");
    }
    return route.continue();
  });
  const page = await context.newPage();
  watchPage(page);

  const started = Date.now();
  const response = await page.goto(`${baseUrl}/assembly-debug/${encodeURIComponent(design)}?fbench=quick`, {
    waitUntil: "domcontentloaded",
    timeout: 120000,
  });
  if (!response || !response.ok()) throw new Error(`assembly page returned ${response ? response.status() : "no response"}`);
  if (!page.url().startsWith(baseUrl)) throw new Error(`assembly page escaped the local server: ${page.url()}`);
  await page.waitForFunction(() => {
    const frame = document.getElementById("pcb-frame");
    const state = frame?.contentWindow?.PCBReviewPainted?.();
    return state && state.revision > 0 && !state.cam_review;
  }, null, { timeout: 30000 });
  if (network.cam_requests !== 0) throw new Error(`default semantic Assembly requested CAM ${network.cam_requests} time(s)`);
  await page.locator("#cam-review").click();
  const pendingCamControl = await page.locator("#cam-review").evaluate((button) => ({
    label: button.textContent,
    busy: button.getAttribute("aria-busy"),
    status: document.querySelector("#cam-review-status")?.textContent || "",
  }));
  if (pendingCamControl.label !== "Loading CAM…" || pendingCamControl.busy !== "true" || pendingCamControl.status !== "Generating Gerbers…") {
    throw new Error(`CAM Review click published no immediate loading feedback: ${JSON.stringify(pendingCamControl)}`);
  }
  await page.waitForFunction(() => {
    const button = document.querySelector("#cam-review");
    return button?.getAttribute("aria-pressed") === "true" || /could not|unavailable/i.test(button?.title || "");
  }, null, { timeout: 240000 });
  const camControl = await page.locator("#cam-review").evaluate((button) => ({
    active: button.getAttribute("aria-pressed") === "true",
    label: button.textContent,
    status: document.querySelector("#cam-review-status")?.textContent || "",
    detail: button.title,
  }));
  if (!camControl.active) throw new Error(`CAM Review failed to activate: ${camControl.detail}`);
  if (camControl.label !== "Exit CAM Review" || camControl.status !== "Exact CAM active") {
    throw new Error(`CAM Review activation published the wrong visible state: ${JSON.stringify(camControl)}`);
  }
  if (network.cam_requests !== 1) throw new Error(`CAM Review expected one lazy payload request, saw ${network.cam_requests}`);
  await page.waitForFunction(() => {
    const win = document.getElementById("pcb-frame")?.contentWindow;
    const state = win?.PCBGpu?.camState?.();
    return state?.mode === "inspection" && state.samplesPerAxis >= 1.95;
  }, null, { timeout: 5000 });
  const benchDeadline = Date.now() + 120000;
  let nextProgress = Date.now() + 30000;
  while (Date.now() < benchDeadline) {
    const state = await page.evaluate(() => {
      const element = document.getElementById("pcb-frame");
      const win = element && element.contentWindow;
      return {
        url: win ? win.location.href : "missing",
        ready: win ? win.document.readyState : "missing",
        result: win && win.__fbench ? win.__fbench : null,
      };
    });
    if (state.result) break;
    if (Date.now() >= nextProgress) {
      process.stderr.write(`assembly_browser_perf: iframe ${state.ready} · ${state.url}\n`);
      nextProgress += 30000;
    }
    await page.waitForTimeout(250);
  }
  const hasResult = await page.evaluate(() => {
    const frame = document.getElementById("pcb-frame");
    return !!(frame && frame.contentWindow && frame.contentWindow.__fbench);
  });
  if (!hasResult) throw new Error("frame benchmark did not finish within 120 seconds");

  const controls = await measureShellControls(page);

  const measured = await page.evaluate(() => {
    const element = document.getElementById("pcb-frame");
    const win = element.contentWindow;
    const nav = win.performance.getEntriesByType("navigation")[0];
    const rect = element.getBoundingClientRect();
    const longTasks = win.__assemblyLongTasks || [];
    return {
      frame: win.__fbench,
      exact_cam_ready_ms: win.__fbenchCamReadyMs,
      iframe: { width: Math.round(rect.width), height: Math.round(rect.height) },
      navigation: nav ? {
        response_ms: +(nav.responseEnd - nav.startTime).toFixed(2),
        dom_content_loaded_ms: +(nav.domContentLoadedEventEnd - nav.startTime).toFixed(2),
        load_ms: +(nav.loadEventEnd - nav.startTime).toFixed(2),
      } : null,
      long_tasks: {
        count: longTasks.length,
        total_ms: +longTasks.reduce((sum, task) => sum + task.duration, 0).toFixed(2),
        max_ms: +longTasks.reduce((max, task) => Math.max(max, task.duration), 0).toFixed(2),
      },
    };
  });
  measured.wall_ms = Date.now() - started;
  measured.controls = controls;
  measured.errors = errors;

  if (measured.frame.error) throw new Error(measured.frame.error);
  if (measured.frame.design !== design) throw new Error(`expected ${design}, measured ${measured.frame.design}`);
  if (measured.frame.profile !== "quick") throw new Error(`expected quick frame profile, got ${measured.frame.profile}`);
  if (!measured.frame.physical_review) throw new Error("the PCB iframe was not in physical review mode");
  if (!measured.frame.cam_review) throw new Error("the benchmark ran before exact CAM artwork loaded");
  if (!(measured.exact_cam_ready_ms > 0)) throw new Error("the benchmark did not publish exact CAM readiness timing");
  if (measured.frame.mode !== "gpu") throw new Error(`expected WebGPU review renderer, got ${measured.frame.mode}`);
  if (network.blocked_mutations.length) throw new Error(`unexpected mutating requests:\n${network.blocked_mutations.join("\n")}`);
  if (network.blocked_external.length) throw new Error(`external requests (the gate is hermetic):\n${network.blocked_external.join("\n")}`);
  if (network.failures.length) throw new Error(`first-party request failures:\n${Array.from(new Set(network.failures)).join("\n")}`);
  if (errors.length) throw new Error(`browser errors:\n${errors.join("\n")}`);
  return measured;
}

function summarize(runs, browserVersion, design) {
  const phases = {};
  for (const phase of ["zoom_in", "seek", "pan", "zoom_out"]) {
    const rows = runs.map((run) => run.frame[phase]);
    phases[phase] = {
      frames: rows[0].n,
      p50_ms: rounded(percentile(rows.map((row) => row.p50), 0.5)),
      p95_ms: rounded(percentile(rows.map((row) => row.p95), 0.5)),
      worst_p95_ms: rounded(Math.max(...rows.map((row) => row.p95))),
      max_ms: rounded(Math.max(...rows.map((row) => row.max))),
    };
  }
  const controls = {};
  for (const name of Object.keys(runs[0].controls)) {
    const values = runs.map((run) => run.controls[name]);
    controls[name.replace(/_ms$/, "")] = {
      p50_ms: rounded(percentile(values, 0.5)),
      p95_ms: rounded(percentile(values, 0.95)),
      max_ms: rounded(Math.max(...values)),
    };
  }
  return {
    design,
    surface: "assembly physical CAM review",
    renderer: "WebGPU (SwiftShader/Vulkan)",
    browser: `Chromium ${browserVersion}`,
    viewport: { width: 1600, height: 900, dpr: 1 },
    iframe: runs[0].iframe,
    repetitions: runs.length,
    phases,
    controls,
    long_tasks: {
      median_count: percentile(runs.map((run) => run.long_tasks.count), 0.5),
      worst_count: Math.max(...runs.map((run) => run.long_tasks.count)),
      median_total_ms: rounded(percentile(runs.map((run) => run.long_tasks.total_ms), 0.5)),
      max_ms: rounded(Math.max(...runs.map((run) => run.long_tasks.max_ms))),
    },
    navigation: {
      median_response_ms: rounded(percentile(runs.map((run) => run.navigation.response_ms), 0.5)),
      median_load_ms: rounded(percentile(runs.map((run) => run.navigation.load_ms), 0.5)),
      median_exact_cam_ready_ms: rounded(percentile(runs.map((run) => run.exact_cam_ready_ms), 0.5)),
      worst_exact_cam_ready_ms: rounded(Math.max(...runs.map((run) => run.exact_cam_ready_ms))),
    },
    median_run_wall_ms: percentile(runs.map((run) => run.wall_ms), 0.5),
  };
}

function valueAt(object, dotted) {
  return dotted.split(".").reduce((value, key) => value == null ? undefined : value[key], object);
}

function projectFacts(projectDir) {
  if (process.env.NETLISP_PERF_DESIGNS_COMMIT) {
    return {
      commit: process.env.NETLISP_PERF_DESIGNS_COMMIT,
      fingerprint: process.env.NETLISP_PERF_DESIGNS_FINGERPRINT || process.env.NETLISP_PERF_DESIGNS_COMMIT,
      dirty: false,
      source: "git-archive+workload-bundles",
    };
  }
  try {
    const commit = execFileSync("git", ["-C", projectDir, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
    const modelDir = path.join(projectDir, "lib", "models");
    const modelHash = fs.existsSync(modelDir) ? execFileSync("bash", ["-c",
      "find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1"
    ], { cwd: modelDir, encoding: "utf8" }).trim() : null;
    const layoutHash = execFileSync("bash", ["-c",
      "find src -type f \\( -name '*.layouts.json' -o -name '*.autolayout.json' \\) -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1"
    ], { cwd: projectDir, encoding: "utf8" }).trim();
    const bomHash = execFileSync("bash", ["-c",
      "find src -type f -name '*.bom' -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1"
    ], { cwd: projectDir, encoding: "utf8" }).trim();
    return {
      commit,
      fingerprint: [commit, modelHash, layoutHash, bomHash].filter(Boolean).join(":"),
      dirty: execFileSync("git", ["-C", projectDir, "status", "--porcelain"], { encoding: "utf8" }).trim().length > 0,
      source: "checkout+model-bundle",
    };
  } catch (_) { return { commit: null, fingerprint: null, dirty: null }; }
}

function requiredBudgets() {
  return {
    "navigation.median_exact_cam_ready_ms": 8000,
    "navigation.worst_exact_cam_ready_ms": 10000,
    "long_tasks.max_ms": 250,
    "long_tasks.median_total_ms": 750,
    "controls.search.p95_ms": 150,
    "controls.search.max_ms": 250,
    "controls.type_filter.p95_ms": 150,
    "controls.type_filter.max_ms": 250,
    "controls.show_dnp.p95_ms": 150,
    "controls.show_dnp.max_ms": 250,
    "controls.bom_select.p95_ms": 200,
    "controls.bom_select.max_ms": 300,
    "controls.selection_clear.p95_ms": 150,
    "controls.selection_clear.max_ms": 250,
    "controls.panel_navigation.p95_ms": 150,
    "controls.panel_navigation.max_ms": 250,
    "controls.cam_review.p95_ms": 250,
    "controls.cam_review.max_ms": 350,
    "controls.cam_layer_visibility.p95_ms": 250,
    "controls.cam_layer_visibility.max_ms": 350,
    "controls.board_side.p95_ms": 250,
    "controls.board_side.max_ms": 350,
    "controls.rotate.p95_ms": 250,
    "controls.rotate.max_ms": 350,
    "controls.model_3d_navigation.p95_ms": 2500,
    "controls.model_3d_navigation.max_ms": 4000,
    "phases.pan.p50_ms": 20,
    "phases.pan.p95_ms": 22,
    "phases.pan.worst_p95_ms": 24,
    "phases.pan.max_ms": 40,
    "phases.zoom_in.worst_p95_ms": 52,
    "phases.zoom_in.max_ms": 55,
    "phases.zoom_out.worst_p95_ms": 35,
    "phases.zoom_out.max_ms": 38,
  };
}

function enforce(summary, baselinePath) {
  if (!fs.existsSync(baselinePath)) throw new Error(`missing browser baseline ${baselinePath}; run with --record deliberately`);
  const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
  if (!baseline.budgets || !Object.keys(baseline.budgets).length) throw new Error(`browser baseline ${baselinePath} has no budgets`);
  const failures = [];
  const recordedCommit = baseline.reference?.designs?.commit;
  if (!recordedCommit) failures.push("designs.commit: baseline has no workload commit");
  else if (summary.designs.commit !== recordedCommit) failures.push(`designs.commit: workload ${summary.designs.commit} != recorded ${recordedCommit}; re-record deliberately`);
  const recordedFingerprint = baseline.reference?.designs?.fingerprint;
  if (!recordedFingerprint) failures.push("designs.fingerprint: baseline has no workload fingerprint");
  else if (summary.designs.fingerprint !== recordedFingerprint) failures.push("designs.fingerprint: workload bundle changed; re-record deliberately");
  if (summary.designs.dirty) failures.push("designs.dirty: performance workload contains uncommitted changes");
  for (const metric of Object.keys(requiredBudgets())) {
    const limit = baseline.budgets[metric];
    if (!Object.prototype.hasOwnProperty.call(baseline.budgets, metric)) failures.push(`${metric}: baseline has no budget`);
    else if (typeof limit !== "number" || !Number.isFinite(limit) || limit < 0) failures.push(`${metric}: baseline budget must be a finite non-negative number`);
  }
  for (const [metric, limit] of Object.entries(baseline.budgets)) {
    if (typeof limit !== "number" || !Number.isFinite(limit) || limit < 0) {
      failures.push(`${metric}: baseline budget must be a finite non-negative number`);
      continue;
    }
    const actual = valueAt(summary, metric);
    if (typeof actual !== "number") failures.push(`${metric}: result has no numeric value`);
    else if (actual > limit) failures.push(`${metric}: ${actual} ms > ${limit} ms budget`);
  }
  if (failures.length) throw new Error(`assembly browser performance regression:\n  ${failures.join("\n  ")}`);
}

function printSummary(summary) {
  console.log(`assembly_browser_perf: ${summary.design} · ${summary.renderer} · iframe ${summary.iframe.width}x${summary.iframe.height}`);
  for (const [name, phase] of Object.entries(summary.phases)) {
    console.log(`  ${name.padEnd(8)} p50 ${phase.p50_ms.toFixed(2)} ms  p95 ${phase.p95_ms.toFixed(2)} ms  worst p95 ${phase.worst_p95_ms.toFixed(2)} ms  max ${phase.max_ms.toFixed(2)} ms`);
  }
  for (const [name, control] of Object.entries(summary.controls)) {
    console.log(`  ${name.padEnd(12)} control p50 ${control.p50_ms.toFixed(2)} ms  p95 ${control.p95_ms.toFixed(2)} ms`);
  }
  console.log(`  long tasks median ${summary.long_tasks.median_count}, worst ${summary.long_tasks.worst_count}; navigation response ${summary.navigation.median_response_ms.toFixed(2)} ms; exact CAM ready ${summary.navigation.median_exact_cam_ready_ms.toFixed(2)} ms`);
}

async function main() {
  const options = argsRead(process.argv.slice(2));
  let server = null;
  let overlay = null;
  let serverText = "";
  let baseUrl = options.url ? options.url.replace(/\/$/, "") : null;
  let browser = null;
  try {
    if (!baseUrl) {
      if (!fs.existsSync(options.binary)) throw new Error(`missing ${options.binary}; build netlisp first`);
      if (!fs.existsSync(path.join(options.projectDir, "src"))) throw new Error(`no designs repo at ${options.projectDir}`);
      overlay = projectOverlay(options.projectDir);
      const port = await freePort();
      baseUrl = `http://127.0.0.1:${port}`;
      server = spawn(options.binary, ["serve", "--project-dir", overlay, "--port", String(port), "--skip-warmup"], {
        cwd: root,
        env: { ...process.env, NETLISP_DEV: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      const append = (chunk) => { serverText = (serverText + chunk.toString()).slice(-16000); };
      server.stdout.on("data", append);
      server.stderr.on("data", append);
      await waitForServer(`${baseUrl}/`, server, () => serverText);
    }

    const swiftshaderIcd = path.join(path.dirname(chromium.executablePath()), "vk_swiftshader_icd.json");
    if (fs.existsSync(swiftshaderIcd) && !process.env.VK_ICD_FILENAMES) process.env.VK_ICD_FILENAMES = swiftshaderIcd;
    browser = await chromium.launch({ headless: true, args: [
      "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-angle=swiftshader",
      "--disable-vulkan-surface", "--enable-dawn-features=allow_unsafe_apis",
    ] });
    const runs = [];
    for (let i = 0; i < options.reps; i++) {
      process.stderr.write(`assembly_browser_perf: run ${i + 1}/${options.reps}\n`);
      runs.push(await runOne(browser, baseUrl, options.design));
    }
    const summary = summarize(runs, await browser.version(), options.design);
    summary.designs = projectFacts(options.projectDir);
    printSummary(summary);
    if (options.record) {
      if (summary.designs.dirty) throw new Error("refusing to record a baseline from a dirty designs checkout; use scripts/perf_gate.sh --record for a clean HEAD snapshot");
      const prior = fs.existsSync(options.baseline) ? JSON.parse(fs.readFileSync(options.baseline, "utf8")) : {};
      const document = {
        schema: 1,
        recorded_at: new Date().toISOString(),
        reference: summary,
        budgets: { ...requiredBudgets(), ...(prior.budgets || {}) },
      };
      fs.mkdirSync(path.dirname(options.baseline), { recursive: true });
      fs.writeFileSync(`${options.baseline}.tmp`, `${JSON.stringify(document, null, 2)}\n`);
      fs.renameSync(`${options.baseline}.tmp`, options.baseline);
      console.log(`assembly_browser_perf: recorded ${options.baseline}`);
    } else {
      enforce(summary, options.baseline);
      console.log(`assembly_browser_perf: PASS ${options.baseline}`);
    }
    console.log(JSON.stringify(summary));
  } finally {
    if (browser) await browser.close();
    await stopServer(server);
    if (overlay) fs.rmSync(overlay, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(`assembly_browser_perf: FAIL: ${error.stack || error}`);
  process.exitCode = 1;
});
