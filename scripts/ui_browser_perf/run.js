#!/usr/bin/env node
"use strict";

const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const { execFileSync, spawn } = require("child_process");
const { performance } = require("perf_hooks");
const { surfaces, responseScenarios } = require("./manifest");
const { ensureGateLock } = require("../perf_gate_lock");

const scenarioSpecs = new Map(surfaces.flatMap((surface) =>
  surface.scenarios.map((scenario) => [`${surface.id}.${scenario.id}`, scenario])));
const routeReviewWorkload = scenarioSpecs.get("route_review.route").workload;

const root = path.resolve(__dirname, "..", "..");
const localLib = path.join(os.homedir(), ".local", "lib", "playwright-chromium", "usr", "lib", "x86_64-linux-gnu");
if (fs.existsSync(localLib)) {
  process.env.LD_LIBRARY_PATH = [localLib, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":");
}
const { chromium } = require("playwright");
const PAGE_TIMEOUT_MS = 90000;

function failUsage(message) {
  if (message) console.error(`ui_browser_perf: ${message}`);
  console.error("usage: run.js [--project-dir DIR] [--binary FILE] [--reps N] [--baseline FILE] [--record] [--url URL] [--surface ID[,ID...]] [--scenario SURFACE.ACTION] [--list]");
  process.exit(2);
}

function readArgs(argv) {
  let defaultProjectDir = path.join(root, "projects", "designs");
  if (!fs.existsSync(path.join(defaultProjectDir, "src"))) {
    try {
      const common = execFileSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: root, encoding: "utf8" }).trim();
      const mainCheckout = path.basename(common) === ".git" ? path.dirname(common) : path.dirname(path.dirname(common));
      const sharedDesigns = path.join(mainCheckout, "projects", "designs");
      if (fs.existsSync(path.join(sharedDesigns, "src"))) defaultProjectDir = sharedDesigns;
    } catch (_) {}
  }
  const options = {
    projectDir: defaultProjectDir,
    binary: path.join(root, "zig-out", "bin", "netlisp"),
    baseline: path.join(root, "docs", "benchmarks", "ui-browser", "baseline.json"),
    fixture: path.join(root, "test", "fixtures", "browser_perf", "route-review.kicad_pcb"),
    pdfFixture: path.join(root, "test", "fixtures", "browser_perf", "datasheet.pdf"),
    reps: 3,
    record: false,
    list: false,
    url: null,
    surfaceIds: null,
    scenario: null,
  };
  const valueArgs = new Set(["--project-dir", "--binary", "--reps", "--baseline", "--url", "--surface", "--scenario"]);
  const keys = { "--project-dir": "projectDir", "--binary": "binary", "--reps": "reps", "--baseline": "baseline", "--url": "url", "--scenario": "scenario" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--record") options.record = true;
    else if (arg === "--list") options.list = true;
    else if (valueArgs.has(arg)) {
      if (++i >= argv.length) failUsage(`${arg} needs a value`);
      if (arg === "--surface") options.surfaceIds = argv[i].split(",").filter(Boolean);
      else options[keys[arg]] = arg === "--reps" ? Number(argv[i]) : argv[i];
    } else failUsage(`unknown argument ${arg}`);
  }
  if (!Number.isInteger(options.reps) || options.reps < 1 || options.reps > 20) failUsage("--reps must be an integer from 1 to 20");
  options.projectDir = path.resolve(options.projectDir);
  options.binary = path.resolve(options.binary);
  options.baseline = path.resolve(options.baseline);
  if (options.url) {
    let parsed;
    try { parsed = new URL(options.url); } catch (_) { failUsage("--url must be a valid loopback URL"); }
    if (!["http:", "https:"].includes(parsed.protocol) || !["127.0.0.1", "localhost", "[::1]"].includes(parsed.hostname)) {
      failUsage("--url is restricted to a loopback HTTP(S) server");
    }
    if (!(options.surfaceIds || options.scenario)) failUsage("--url requires --surface or --scenario");
  }
  if (options.record && (options.surfaceIds || options.scenario)) failUsage("--record requires the complete matrix (no filters)");
  return options;
}

function percentile(values, q) {
  if (!values.length) return 0;
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.round(q * (sorted.length - 1))))];
}
function round(value) { return Number(value.toFixed(2)); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close((error) => error ? reject(error) : resolve(port));
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
    await sleep(100);
  }
  throw new Error(`netlisp did not become ready within 120 seconds\n${log()}`);
}

function stopServer(server) {
  if (!server || server.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(() => { if (server.exitCode === null) server.kill("SIGKILL"); }, 5000);
    server.once("exit", () => { clearTimeout(timer); resolve(); });
    server.kill("SIGTERM");
  });
}

function projectOverlay(projectDir, pdfFixture) {
  const overlay = fs.mkdtempSync(path.join(os.tmpdir(), "netlisp-ui-perf-"));
  try {
    for (const entry of fs.readdirSync(projectDir)) {
      if (entry === "lib") continue;
      // Never link .git. Git resolves the symlink, so an overlay carrying one
      // is a work tree of the REAL designs repository whose toplevel is the
      // overlay itself: `git add -A -- <overlay path>` + commit would write a
      // commit into the user's repo from a temporary copy of the tree. The
      // overlay needs no git for anything, so it simply is not a repo.
      if (entry === ".git") continue;
      if (entry === "src" || entry === "history") {
        // Some read-only page GETs may refresh generated placement sidecars.
        // Successful private layout saves also append history. Give both
        // writable trees copy-on-write storage instead of live symlinks.
        fs.cpSync(path.join(projectDir, entry), path.join(overlay, entry), {
          recursive: true,
          dereference: true,
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
      if (entry === "datasheets") continue;
      if (entry === "models") {
        const sourceModels = path.join(sourceLib, entry);
        const overlayModels = path.join(overlayLib, entry);
        fs.mkdirSync(overlayModels);
        for (const modelEntry of fs.readdirSync(sourceModels)) {
          if (modelEntry === ".sprites") continue;
          if (modelEntry === "model-config.json") {
            // The model-alignment Save endpoint atomically replaces this file.
            // Copy the small writable metadata; only large model binaries stay
            // symlinked to the source library.
            fs.copyFileSync(path.join(sourceModels, modelEntry), path.join(overlayModels, modelEntry), fs.constants.COPYFILE_FICLONE);
          } else {
            fs.symlinkSync(path.join(sourceModels, modelEntry), path.join(overlayModels, modelEntry));
          }
        }
        // Sprite misses may be filled by the browser. Keep that cache private.
        fs.mkdirSync(path.join(overlayModels, ".sprites"));
        continue;
      }
      fs.symlinkSync(path.join(sourceLib, entry), path.join(overlayLib, entry));
    }

    const sourceDatasheets = path.join(sourceLib, "datasheets");
    const overlayDatasheets = path.join(overlayLib, "datasheets");
    fs.mkdirSync(overlayDatasheets);
    if (fs.existsSync(sourceDatasheets)) {
      for (const entry of fs.readdirSync(sourceDatasheets)) {
        if (entry === "browser-perf.pdf") continue;
        fs.symlinkSync(path.join(sourceDatasheets, entry), path.join(overlayDatasheets, entry));
      }
    }
    fs.symlinkSync(pdfFixture, path.join(overlayDatasheets, "browser-perf.pdf"));
    return overlay;
  } catch (error) {
    fs.rmSync(overlay, { recursive: true, force: true });
    throw error;
  }
}

function assertPrivateOverlay(projectDir) {
  const resolved = fs.realpathSync(projectDir);
  if (path.dirname(resolved) !== os.tmpdir() || !path.basename(resolved).startsWith("netlisp-ui-perf-")) {
    throw new Error(`refusing private mutation checkpoint outside an owned overlay: ${resolved}`);
  }
  return resolved;
}

function snapshotEntry(target) {
  let stat;
  try { stat = fs.lstatSync(target); } catch (error) {
    if (error.code === "ENOENT") return { kind: "missing" };
    throw error;
  }
  if (stat.isSymbolicLink()) return { kind: "symlink", target: fs.readlinkSync(target) };
  if (stat.isFile()) return { kind: "file", mode: stat.mode, data: fs.readFileSync(target) };
  if (stat.isDirectory()) return {
    kind: "directory",
    mode: stat.mode,
    entries: fs.readdirSync(target).map((name) => ({ name, snapshot: snapshotEntry(path.join(target, name)) })),
  };
  throw new Error(`unsupported private mutation checkpoint entry ${target}`);
}

function restoreEntry(target, snapshot) {
  fs.rmSync(target, { recursive: true, force: true });
  if (snapshot.kind === "missing") return;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  if (snapshot.kind === "symlink") {
    fs.symlinkSync(snapshot.target, target);
    return;
  }
  if (snapshot.kind === "file") {
    fs.writeFileSync(target, snapshot.data, { mode: snapshot.mode });
    return;
  }
  fs.mkdirSync(target, { mode: snapshot.mode, recursive: true });
  for (const entry of snapshot.entries) restoreEntry(path.join(target, entry.name), entry.snapshot);
}

function privateMutationCheckpoint(projectDir) {
  const overlay = assertPrivateOverlay(projectDir);
  const targets = [];
  const src = path.join(overlay, "src");
  function collect(dir) {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const target = path.join(dir, entry.name);
      if (entry.isDirectory()) collect(target);
      else if (entry.name.endsWith(".layouts.json") || entry.name.endsWith(".autolayout.json")) targets.push(target);
    }
  }
  collect(src);
  targets.push(path.join(overlay, "lib", "models", "model-config.json"));
  targets.push(path.join(overlay, "history", "barracuda-base", "layouts"));
  return { overlay, entries: targets.map((target) => ({ target, snapshot: snapshotEntry(target) })) };
}

function restorePrivateMutationCheckpoint(checkpoint) {
  const overlay = assertPrivateOverlay(checkpoint.overlay);
  for (const entry of checkpoint.entries) {
    const relative = path.relative(overlay, entry.target);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error(`refusing private mutation restore outside ${overlay}: ${entry.target}`);
    }
    restoreEntry(entry.target, entry.snapshot);
  }
}

async function afterFrames(realm, count = 2) {
  return realm.evaluate((n) => new Promise((resolve) => {
    function step() { if (--n <= 0) resolve(performance.now()); else requestAnimationFrame(step); }
    requestAnimationFrame(step);
  }), count);
}

async function measured(realm, action, settle) {
  await realm.evaluate(() => { window.__uiPerfActionStart = performance.now(); });
  await action();
  if (settle) await settle();
  const ended = await afterFrames(realm, 2);
  const started = await realm.evaluate(() => window.__uiPerfActionStart);
  return { ms: round(ended - started) };
}

async function measuredWall(realm, action, settle) {
  const started = performance.now();
  await action();
  if (settle) await settle();
  await afterFrames(realm, 2);
  return { ms: round(performance.now() - started) };
}

async function visualSnapshot(locator) {
  return locator.screenshot({ animations: "disabled" });
}

function requireVisualChange(before, after, label) {
  if (before.equals(after)) throw new Error(`${label} completed without changing the rendered view`);
}

async function measuredVisual(page, locator, label, action, settle) {
  const before = await visualSnapshot(locator);
  const result = await measured(page, action, settle);
  requireVisualChange(before, await visualSnapshot(locator), label);
  return result;
}

async function startFrames(realm) {
  await realm.evaluate(() => new Promise((resolve) => {
    window.__uiPerfFrames = [];
    window.__uiPerfCollectFrames = true;
    window.__uiPerfLastFrame = null;
    requestAnimationFrame(function tick(now) {
      if (!window.__uiPerfCollectFrames) return;
      if (window.__uiPerfLastFrame != null) window.__uiPerfFrames.push(now - window.__uiPerfLastFrame);
      window.__uiPerfLastFrame = now;
      requestAnimationFrame(tick);
    });
    requestAnimationFrame(resolve);
  }));
}

async function stopFrames(realm) {
  await afterFrames(realm, 3);
  const raw = await realm.evaluate(() => {
    window.__uiPerfCollectFrames = false;
    return (window.__uiPerfFrames || []).slice(1);
  });
  // A multi-second delta is the exact main-thread stall this gate must catch;
  // never discard it as an outlier. Only non-finite/non-positive samples are
  // structurally invalid.
  const frames = raw.filter((value) => Number.isFinite(value) && value > 0);
  if (frames.length < 3) throw new Error(`gesture produced only ${frames.length} measured frames`);
  return {
    frames: frames.length,
    p50_ms: round(percentile(frames, 0.5)),
    p95_ms: round(percentile(frames, 0.95)),
    max_ms: round(Math.max(...frames)),
  };
}

async function dragGesture(page, realm, locator, options = {}) {
  const box = await locator.boundingBox();
  if (!box || box.width < 2 || box.height < 2) throw new Error(`cannot drag hidden ${locator}`);
  const x = box.x + box.width * 0.5;
  const y = box.y + box.height * 0.5;
  const before = await visualSnapshot(locator);
  const stateBefore = options.state ? JSON.stringify(await options.state()) : null;
  if (options.space) await page.keyboard.down("Space");
  await page.mouse.move(x, y);
  await startFrames(realm);
  await page.mouse.down({ button: options.button || "left" });
  for (let i = 1; i <= 36; i++) {
    await page.mouse.move(x + i * 2.2, y + Math.sin(i / 4) * 12);
    await page.waitForTimeout(4);
  }
  await page.mouse.up({ button: options.button || "left" });
  if (options.space) await page.keyboard.up("Space");
  const result = await stopFrames(realm);
  if (options.after) await options.after();
  requireVisualChange(before, await visualSnapshot(locator), "drag gesture");
  if (options.state && JSON.stringify(await options.state()) === stateBefore) throw new Error("drag gesture did not change application camera state");
  return result;
}

async function wheelGesture(page, realm, locator, options = {}) {
  const box = await locator.boundingBox();
  if (!box || box.width < 2 || box.height < 2) throw new Error(`cannot zoom hidden ${locator}`);
  const before = await visualSnapshot(locator);
  const stateBefore = options.state ? JSON.stringify(await options.state()) : null;
  await page.mouse.move(box.x + box.width * 0.55, box.y + box.height * 0.48);
  await startFrames(realm);
  for (let i = 0; i < 14; i++) {
    await page.mouse.wheel(0, -65);
    await page.waitForTimeout(8);
  }
  const result = await stopFrames(realm);
  if (options.after) await options.after();
  requireVisualChange(before, await visualSnapshot(locator), "zoom gesture");
  if (options.state && JSON.stringify(await options.state()) === stateBefore) throw new Error("zoom gesture did not change application camera state");
  return result;
}

async function thermalFrame(page) {
  const handle = await page.locator("#tp-frame").elementHandle();
  const frame = handle && await handle.contentFrame();
  if (!frame) throw new Error("thermal PCB iframe is unavailable");
  await frame.locator(".pcb-scene").waitFor({ state: "visible", timeout: PAGE_TIMEOUT_MS });
  return frame;
}

async function waitForErcPanel(page) {
  await page.waitForFunction(() => {
    const detail = document.querySelector("#sb-detail");
    if (detail?.querySelector("h4")?.textContent.trim() !== "ERC") return false;
    if (detail.querySelector("#erc-rerun")) return true;
    const message = detail.querySelector(".sb-empty")?.textContent.trim() || "";
    return message.startsWith("Error:") && message !== "Running…";
  }, null, { timeout: PAGE_TIMEOUT_MS });
}

function pcb3dGestureState(page) {
  return {
    state: () => page.evaluate(() => window.PCB3D.cameraState()),
    // Frame percentiles cover the active low-resolution gesture. Separately
    // prove the real canvas returned to at least CSS-pixel density afterward,
    // so a fast benchmark cannot leave the user's settled view blurry.
    after: () => page.waitForFunction(() => {
      const canvas = document.querySelector("#pcb-3d-canvas");
      if (!canvas || !canvas.clientWidth) return false;
      return canvas.width / canvas.clientWidth >= Math.min(window.devicePixelRatio || 1, 1) - 0.01;
    }),
  };
}

function model3dGestureQuality(page) {
  return {
    // The model viewer deliberately renders gestures at 60% resolution. A
    // fast interaction only counts if its settled canvas returns to the
    // native (DPR-capped) backing-buffer density a user reads afterward.
    after: () => page.waitForFunction(() => {
      const canvas = document.querySelector("#view");
      if (!canvas || !canvas.clientWidth) return false;
      return canvas.width / canvas.clientWidth >= Math.min(window.devicePixelRatio || 1, 2) - 0.01;
    }),
  };
}

function schematicZoomQuality(page) {
  return {
    // Wheel input hides the expensive referenced schematics for 140 ms. Prove
    // the post-gesture view reaches real LOD 2 content instead of benchmarking
    // a permanently blank fast path.
    after: () => page.waitForFunction(() => {
      const svg = document.querySelector(".dg-svg[data-lod]");
      const deep = svg?.querySelector(".dg-deep");
      if (!svg || svg.classList.contains("dg-zooming") || svg.dataset.lod !== "2" ||
          !deep || deep.querySelectorAll("use").length === 0) return false;
      const style = getComputedStyle(deep);
      return style.display !== "none" && Number(style.opacity) > 0.9;
    }),
  };
}

async function pcbPartDragUndo(page, ref) {
  const pose = () => page.evaluate((wanted) => {
    const part = PCB.parts.find((item) => item.ref === wanted);
    return part ? [part.x, part.y, part.rot || 0, part.side || "top"] : null;
  }, ref);
  const beforePose = await pose();
  if (!beforePose) throw new Error(`PCB drag fixture part ${ref} is missing`);
  const point = await page.evaluate((wanted) => {
    const part = PCB.parts.find((item) => item.ref === wanted);
    const svg = document.querySelector("#pcb-svg");
    const world = new DOMPoint(
      (part.x - PCB.minx + PCB.margin) * PCB.scale,
      (part.y - PCB.miny + PCB.margin) * PCB.scale,
    );
    const client = world.matrixTransform(svg.getScreenCTM());
    return { x: client.x, y: client.y };
  }, ref);
  const scene = page.locator(".pcb-scene-shell");
  const beforeImage = await visualSnapshot(scene);
  await page.mouse.move(point.x, point.y);
  await startFrames(page);
  await page.mouse.down();
  for (let i = 1; i <= 36; i++) {
    await page.mouse.move(point.x + i * 1.4, point.y + Math.sin(i / 5) * 7);
    await page.waitForTimeout(4);
  }
  await page.mouse.up();
  const result = await stopFrames(page);
  const movedPose = await pose();
  if (!movedPose || (movedPose[0] === beforePose[0] && movedPose[1] === beforePose[1])) {
    throw new Error(`PCB part ${ref} did not move`);
  }
  requireVisualChange(beforeImage, await visualSnapshot(scene), "PCB component drag");
  await page.locator("#pcb-undo").click();
  await page.waitForFunction(({ wanted, original }) => {
    const part = PCB.parts.find((item) => item.ref === wanted);
    return part && Math.abs(part.x - original[0]) < 1e-9 && Math.abs(part.y - original[1]) < 1e-9;
  }, { wanted: ref, original: beforePose });
  await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => {});
  await afterFrames(page, 2);
  return result;
}

async function pcbPadClientPoint(page) {
  return page.evaluate(() => {
    const svg = document.querySelector("#pcb-svg");
    const box = svg?.getBoundingClientRect();
    if (!svg || !box) return null;
    const viewBox = svg.viewBox.baseVal;
    const candidates = [];
    PCB.parts.forEach((part, partIndex) => (part.pads || []).forEach((pad) => {
      if (!pad.net) return;
      let localX = pad.x;
      if (part.side === "bottom") localX = -localX;
      const angle = (part.rot || 0) * Math.PI / 180;
      const worldX = part.x + localX * Math.cos(angle) - pad.y * Math.sin(angle);
      const worldY = part.y + localX * Math.sin(angle) + pad.y * Math.cos(angle);
      const svgX = (worldX - PCB.minx + PCB.margin) * PCB.scale;
      const svgY = (worldY - PCB.miny + PCB.margin) * PCB.scale;
      const client = {
        x: box.left + (svgX - viewBox.x) / viewBox.width * box.width,
        y: box.top + (svgY - viewBox.y) / viewBox.height * box.height,
      };
      if (client.x > box.left + 30 && client.x < box.right - 30 &&
          client.y > box.top + 30 && client.y < box.bottom - 30) {
        candidates.push({ x: client.x, y: client.y, net: pad.net, ref: part.ref,
          distance: Math.hypot(client.x - (box.left + box.width / 2), client.y - (box.top + box.height / 2)) });
      }
    }));
    candidates.sort((a, b) => a.distance - b.distance);
    return candidates[0] || null;
  });
}

async function pcbTraceRouteCancel(page) {
  const scene = page.locator(".pcb-scene-shell");
  const beforeImage = await visualSnapshot(scene);
  const copperState = () => page.evaluate(() => JSON.stringify({
    tracks: (PCB.tracks || []).map((track) => ({ x1: track.x1, y1: track.y1, xm: track.xm, ym: track.ym,
      x2: track.x2, y2: track.y2, l: track.l || 0, w: track.w, net: track.net || "", g: track.g, source: track.source })),
    vias: (PCB.vias || []).map((via) => ({ x: via.x, y: via.y, d: via.d, drill: via.drill,
      net: via.net || "", g: via.g, f: via.f, source: via.source, s: Array.isArray(via.s) ? via.s : undefined })),
    rfPaths: (PCB.rf_paths || []).map((path) => ({ net: path.net, l: path.l || 0, portal: Boolean(path.portal),
      track_ids: path.track_ids || [], samples: (path.samples || []).map((sample) => sample.map(Number)) })),
  }));
  const beforeCopper = await copperState();
  const pad = await pcbPadClientPoint(page);
  if (!pad) throw new Error("PCB trace fixture has no visible netted pad");
  const result = await measured(page, async () => {
    await page.locator("#pcb-draw").click();
    await page.waitForFunction(() => document.querySelector("#pcb-draw")?.classList.contains("on") &&
      /^route\s+·/.test(document.querySelector("#st-tool")?.textContent || ""));
    await page.mouse.click(pad.x, pad.y);
    await page.mouse.move(pad.x + 42, pad.y + 24, { steps: 5 });
  }, async () => page.waitForFunction(() => document.querySelector("#pcb-draw")?.classList.contains("on") &&
    /^route\s+(?!·)/.test(document.querySelector("#st-tool")?.textContent || "")));
  requireVisualChange(beforeImage, await visualSnapshot(scene), "PCB trace preview");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("#pcb-draw")?.classList.contains("on") &&
    document.querySelector("#tool-select")?.classList.contains("on") &&
    document.querySelector("#pcb-savemsg")?.textContent === "routing cancelled");
  const afterCopper = await copperState();
  if (afterCopper !== beforeCopper) throw new Error("cancelling PCB trace preview changed copper");
  await afterFrames(page, 2);
  return result;
}

async function pcbViaFixturePoint(page, netName) {
  const box = await page.locator("#pcb-svg").boundingBox();
  if (!box) return null;
  // Discover setup outside the timed click. Probe a coarse visible grid through
  // the editor's own snap/clearance predicates; small per-row batches plus a
  // frame yield prevent fixture search from manufacturing a long task.
  const xFractions = [0.55, ...Array.from({ length: 23 }, (_, index) => 0.06 + index * 0.04)
    .filter((fraction) => Math.abs(fraction - 0.55) > 0.001)];
  const yFractions = [0.10, ...Array.from({ length: 23 }, (_, index) => 0.06 + index * 0.04)
    .filter((fraction) => Math.abs(fraction - 0.10) > 0.001)];
  for (let row = 0; row < yFractions.length; row++) {
    const point = await page.evaluate(({ bounds, yFraction, columns, net }) => {
      if (typeof window.PCBViaLegalCandidate !== "function") return null;
      const y = bounds.y + bounds.height * yFraction;
      for (const xFraction of columns) {
        const x = bounds.x + bounds.width * xFraction;
        const client = window.PCBViaLegalCandidate(x, y, net);
        if (!client) continue;
        if (client.x > bounds.x + 4 && client.x < bounds.x + bounds.width - 4 &&
            client.y > bounds.y + 4 && client.y < bounds.y + bounds.height - 4) {
          return client;
        }
      }
      return null;
    }, { bounds: box, yFraction: yFractions[row], columns: xFractions, net: netName });
    if (point) return point;
    await afterFrames(page, 1);
  }
  return null;
}

async function pcbViaPlaceUndo(page) {
  const initialCount = await page.evaluate(() => (PCB.vias || []).length);
  await page.locator("#pcb-via").click();
  await page.waitForFunction(() => document.querySelector("#pcb-via")?.classList.contains("on") &&
    !document.querySelector("#st-via")?.hidden);
  const net = await page.locator('#pcb-via-net option:not([value=""])').first().getAttribute("value");
  if (!net) throw new Error("PCB via fixture has no net option");
  await page.locator("#pcb-via-net").selectOption(net);
  await page.waitForFunction((value) => document.querySelector("#pcb-via-net")?.value === value, net);
  const point = await pcbViaFixturePoint(page, net);
  if (!point) throw new Error("PCB fixture has no legal visible standalone-via point");
  const before = await page.evaluate(() => (PCB.vias || []).map((via) => via.id || JSON.stringify(via)));
  const result = await measuredVisual(page, page.locator(".pcb-scene-shell"), "PCB standalone via",
    async () => page.mouse.click(point.x, point.y),
    async () => page.waitForFunction(({ count, net }) => {
      const vias = PCB.vias || [];
      const via = vias[vias.length - 1];
      return vias.length === count + 1 && via?.source === "human" && via.net === net;
    }, { count: before.length, net }));
  await page.locator("#pcb-undo").click();
  await page.waitForFunction((ids) => JSON.stringify((PCB.vias || []).map((via) => via.id || JSON.stringify(via))) === JSON.stringify(ids), before);
  await page.locator("#tool-select").click();
  await page.waitForFunction(() => !document.querySelector("#pcb-via")?.classList.contains("on") &&
    document.querySelector("#tool-select")?.classList.contains("on"));
  await afterFrames(page, 2);
  return result;
}

async function footprintPadDragUndo(page) {
  const pad = page.locator("#editor-svg [data-pad-key]").first();
  const key = await pad.getAttribute("data-pad-key");
  const beforeBox = await pad.boundingBox();
  const beforeX = Number(await page.locator("#pad-x").inputValue());
  if (!key || !beforeBox) throw new Error("footprint drag pad is unavailable");
  const beforeImage = await visualSnapshot(page.locator("#editor-svg"));
  const x = beforeBox.x + beforeBox.width / 2, y = beforeBox.y + beforeBox.height / 2;
  await page.mouse.move(x, y);
  await startFrames(page);
  await page.mouse.down();
  for (let i = 1; i <= 30; i++) {
    await page.mouse.move(x + i * 1.2, y + Math.sin(i / 4) * 4);
    await page.waitForTimeout(4);
  }
  await page.mouse.up();
  const result = await stopFrames(page);
  const movedBox = await pad.boundingBox();
  if (!movedBox || Math.hypot(movedBox.x - beforeBox.x, movedBox.y - beforeBox.y) < 2) throw new Error("footprint pad did not move");
  requireVisualChange(beforeImage, await visualSnapshot(page.locator("#editor-svg")), "footprint pad drag");
  await page.locator("#undo").click();
  await page.waitForFunction((value) => Math.abs(Number(document.querySelector("#pad-x")?.value) - value) < 1e-9, beforeX);
  await afterFrames(page, 2);
  return result;
}

async function openSystemDocument(page, title) {
  const button = page.locator("#docs button", { hasText: title });
  if (await button.count() !== 1) throw new Error(`system review document ${title} is not uniquely listed`);
  return measured(page, async () => button.click(), async () => {
    await page.waitForFunction((expected) => {
      const active = document.querySelector("#docs button.active");
      const heading = document.querySelector("#doc-title")?.textContent || "";
      return Boolean(active) && active.textContent.includes(expected) && heading.startsWith(`${expected} \u00b7 `) &&
        (document.querySelector("#source")?.value.length || 0) > 0 &&
        (document.querySelector("#rendered")?.childElementCount || 0) > 0;
    }, title, { timeout: PAGE_TIMEOUT_MS });
  });
}

const ACTIONS = {
  "home.search": async (page) => {
    const before = await page.locator("#home-grid .design-card:visible").count();
    return measured(page, async () => {
      await page.locator("#home-search").fill("barracuda");
    }, async () => page.waitForFunction(({ oldCount, query }) => {
      const visible = Array.from(document.querySelectorAll("#home-grid .design-card"))
        .filter((card) => getComputedStyle(card).display !== "none");
      return visible.length > 0 && visible.length < oldCount && visible.every((card) =>
        (card.getAttribute("data-search") || "").toLowerCase().includes(query));
    }, { oldCount: before, query: "barracuda" }));
  },
  "home.filter": async (page) => {
    await page.locator("#home-search").fill("");
    await page.waitForFunction(() => Array.from(document.querySelectorAll("#home-grid .design-card"))
      .every((card) => getComputedStyle(card).display !== "none"));
    const expected = await page.evaluate(() => {
      const cards = Array.from(document.querySelectorAll("#home-grid .design-card"));
      return { total: cards.length, matching: cards.filter((card) => card.dataset.kind === "subcircuit").length };
    });
    if (!(expected.matching > 0 && expected.matching < expected.total)) {
      throw new Error(`home filter fixture needs both matching and non-matching cards: ${JSON.stringify(expected)}`);
    }
    return measured(page, async () => {
      await page.locator('[data-filter="subcircuit"]').click();
    }, async () => page.waitForFunction(({ matching, total }) => {
      const visible = Array.from(document.querySelectorAll("#home-grid .design-card"))
        .filter((card) => getComputedStyle(card).display !== "none");
      const count = document.querySelector("#home-count")?.textContent || "";
      return document.querySelector('[data-filter="subcircuit"]')?.classList.contains("active") &&
        visible.length === matching && visible.every((card) => card.dataset.kind === "subcircuit") &&
        count.trim() === `${matching} of ${total} items`;
    }, expected));
  },
  "home.new_design_dialog": async (page) => measured(page, async () => {
    const dialog = new Promise((resolve) => page.once("dialog", async (value) => {
      await value.dismiss();
      resolve();
    }));
    await page.locator("#home-new").click();
    await dialog;
  }),
  "home.progress_hydration": async (page) => {
    const selector = "#home-grid [data-layout-progress]";
    const cards = page.locator(selector);
    const count = await cards.count();
    if (count < 1) throw new Error("home progress hydration has no board cards");
    return measured(page, async () => {}, async () => page.waitForFunction((progressSelector) => {
      const progress = Array.from(document.querySelectorAll(progressSelector));
      return progress.length > 0 && progress.every((element) => !element.classList.contains("loading"));
    }, selector, { timeout: PAGE_TIMEOUT_MS }));
  },

  "schematic.search": async (page) => measured(page, async () => page.locator("#sch-search").fill("U19"),
    async () => page.waitForFunction(() => document.querySelector("#sb-results").textContent.trim().length > 0)),
  "schematic.diagram_tab": async (page) => measured(page, async () => page.locator('label[for="dg-tab-layout"]').click(),
    async () => page.waitForFunction(() => document.querySelector("#dg-tab-layout").checked)),
  "schematic.source_editor": async (page) => measured(page, async () => page.locator("#edit-src-btn").click(),
    async () => page.locator(".se-ta").waitFor({ state: "visible" })).then(async (result) => { await page.locator(".se-cancel").click(); await afterFrames(page, 2); return result; }),
  "schematic.erc": async (page) => measured(page, async () => page.locator("#erc-btn").click(),
    async () => waitForErcPanel(page)),
  "schematic.pan": async (page) => dragGesture(page, page, page.locator(".dg-svg:visible").first()),
  "schematic.zoom": async (page) => wheelGesture(page, page, page.locator(".dg-svg:visible").first(), schematicZoomQuality(page)),
  "schematic.view_switch": async (page) => measuredWall(page, async () => page.locator(".schematic-mode-slider").click(),
    async () => page.waitForFunction(() => document.body.dataset.schematicView === "original")),

  "module.search": async (page) => measured(page, async () => page.locator("#sch-search").fill("LT3045"),
    async () => page.waitForFunction(() => document.querySelector("#sb-results").textContent.trim().length > 0)),
  "module.detail_pick": async (page) => {
    const component = page.locator("svg .component[data-ref]").first();
    const ref = await component.getAttribute("data-ref");
    const before = (await page.locator("#sb-detail h4").textContent())?.trim() || "";
    if (!ref) throw new Error("module detail fixture component has no reference");
    return measured(page, async () => component.click(), async () => page.waitForFunction(({ oldTitle, wanted }) => {
      const title = document.querySelector("#sb-detail h4")?.textContent.trim() || "";
      return title !== oldTitle && title === wanted;
    }, { oldTitle: before, wanted: ref }));
  },
  "module.source_editor": async (page) => measured(page, async () => page.locator("#edit-src-btn").click(),
    async () => page.locator(".se-ta").waitFor({ state: "visible" })).then(async (result) => { await page.locator(".se-cancel").click(); await afterFrames(page, 2); return result; }),
  "module.erc_feedback": async (page) => measured(page, async () => page.locator("#erc-btn").click(),
    async () => waitForErcPanel(page)),

  "board_review.search": async (page) => measured(page,
    async () => page.locator("#review-search").fill("creepage"),
    async () => page.waitForFunction(() => {
      const shown = Array.from(document.querySelectorAll(".review-item")).filter((row) => !row.hidden);
      return shown.length > 0 && shown.length < 258 && shown.every((row) =>
        (row.textContent || "").toLowerCase().includes("creepage"));
    })),
  "board_review.remaining_filter": async (page) => {
    await page.locator("#review-search").fill("");
    return measured(page, async () => page.locator('[data-filter="remaining"]').click(),
      async () => page.waitForFunction(() => document.querySelector('[data-filter="remaining"]')?.classList.contains("active")));
  },
  "board_review.section_expand": async (page) => {
    const section = page.locator('.section-card[data-section="2"]');
    if (await section.getAttribute("open") !== null) await section.locator("summary").click();
    return measured(page, async () => section.locator("summary").click(),
      async () => page.waitForFunction(() => document.querySelector('.section-card[data-section="2"]')?.open));
  },

  "pcb_2d.find": async (page) => measured(page, async () => page.locator("#pcb-find-input").fill("U19"),
    async () => page.locator("#pcb-find-results [data-findrow]").first().waitFor({ state: "visible" })),
  "pcb_2d.side_panel": async (page) => measured(page, async () => page.locator('[data-sidetab="side-drc"]').click(),
    async () => page.locator("#side-drc").waitFor({ state: "visible" })),
  "pcb_2d.appearance": async (page) => {
    const eye = page.locator("#ap-layers .ap-eye").first();
    const beforeOff = await eye.evaluate((button) => button.classList.contains("off"));
    const result = await measuredVisual(page, page.locator(".pcb-scene-shell"), "PCB appearance toggle",
      async () => eye.click(),
      async () => page.waitForFunction((off) => document.querySelector("#ap-layers .ap-eye")?.classList.contains("off") !== off, beforeOff));
    await eye.click();
    await afterFrames(page, 2);
    return result;
  },
  "pcb_2d.layout_load": async (page) => {
    if (!await page.locator("#side-route").isVisible()) {
      await page.locator('[data-sidetab="side-route"]').click();
      await page.waitForFunction(() => document.querySelector('[data-sidetab="side-route"]')?.getAttribute("aria-selected") === "true" &&
        document.querySelector("#side-route")?.hidden === false && document.querySelector("#side-drc")?.hidden === true &&
        getComputedStyle(document.querySelector("#pcb-lay-select")).display !== "none");
    }
    await page.locator("#pcb-lay-select").waitFor({ state: "visible", timeout: PAGE_TIMEOUT_MS });
    await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => {});
    const priorLongTasks = await page.evaluate(() => {
      const pending = window.__uiPerfLongTaskObserver?.takeRecords?.() || [];
      return [...(window.__uiPerfLongTasks || []), ...pending
        .filter((entry) => entry.startTime >= window.__uiPerfLongTaskSince)
        .map((entry) => entry.duration)];
    });
    const target = await page.evaluate(() => {
      const current = document.querySelector("#pcb-lay-select")?.value || PCB.shown_layout || "";
      const layouts = PCB.layouts || [];
      const choice = layouts.find((layout) => layout.name !== current && layout.routes !== null) ||
        layouts.find((layout) => layout.name !== current);
      const original = layouts.find((layout) => layout.name === current);
      return choice ? { name: choice.name, navigates: choice.routes === null,
        current, currentNavigates: original?.routes === null } : null;
    });
    if (!target?.current) throw new Error("PCB layout-load fixture needs an active original and at least one alternate saved layout");
    const result = await measuredWall(page, async () => {
      if (target.navigates) {
        await Promise.all([
          page.waitForNavigation({ waitUntil: "domcontentloaded", timeout: PAGE_TIMEOUT_MS }),
          page.locator("#pcb-lay-select").selectOption(target.name),
        ]);
        await page.locator(".pcb-scene").waitFor({ state: "visible", timeout: PAGE_TIMEOUT_MS });
        await page.evaluate((durations) => window.__uiPerfLongTasks.unshift(...durations), priorLongTasks);
      } else {
        await page.locator("#pcb-lay-select").selectOption(target.name);
      }
    }, async () => page.waitForFunction((name) => {
      const params = new URLSearchParams(location.search);
      return PCB.shown_layout === name && window.PCBActiveLayoutName?.() === name &&
        document.querySelector("#pcb-lay-select")?.value === name && params.get("layout") === name &&
        !document.querySelector("#pcb-update")?.disabled;
    }, target.name, { timeout: PAGE_TIMEOUT_MS }));
    const active = (await page.locator("#pcb-active").textContent())?.trim() || "";
    if (!active.includes(target.name)) throw new Error(`loaded PCB layout is not reflected in active label: ${active}`);
    // The remaining edit fixtures are reviewed against the opening layout.
    // Restore it outside the measured interval so a normal full-matrix run
    // cannot inherit a different board from this navigation benchmark.
    if (target.currentNavigates) {
      const accumulatedLongTasks = await page.evaluate(() => {
        const pending = window.__uiPerfLongTaskObserver?.takeRecords?.() || [];
        return [...(window.__uiPerfLongTasks || []), ...pending
          .filter((entry) => entry.startTime >= window.__uiPerfLongTaskSince)
          .map((entry) => entry.duration)];
      });
      await Promise.all([
        page.waitForNavigation({ waitUntil: "domcontentloaded", timeout: PAGE_TIMEOUT_MS }),
        page.locator("#pcb-lay-select").selectOption(target.current),
      ]);
      await page.locator(".pcb-scene").waitFor({ state: "visible", timeout: PAGE_TIMEOUT_MS });
      await page.evaluate((durations) => window.__uiPerfLongTasks.unshift(...durations), accumulatedLongTasks);
    } else {
      await page.locator("#pcb-lay-select").selectOption(target.current);
    }
    await page.waitForFunction((name) => {
      const params = new URLSearchParams(location.search);
      return PCB.shown_layout === name && window.PCBActiveLayoutName?.() === name &&
        document.querySelector("#pcb-lay-select")?.value === name && params.get("layout") === name &&
        !document.querySelector("#pcb-update")?.disabled;
    }, target.current, { timeout: PAGE_TIMEOUT_MS });
    const restored = (await page.locator("#pcb-active").textContent())?.trim() || "";
    if (!restored.includes(target.current)) throw new Error(`original PCB layout was not restored in active label: ${restored}`);
    await afterFrames(page, 2);
    return result;
  },
  "pcb_2d.layout_save": async (page, env) => {
    const active = await page.evaluate(() => window.PCBActiveLayoutName?.());
    if (!active || await page.locator("#pcb-update").isDisabled()) throw new Error("PCB layout update control has no active saved layout");
    const beforeRev = await page.evaluate(() => PCB.rev || 0);
    const before = (await page.locator("#pcb-savemsg").textContent()) || "";
    let response;
    let result;
    if (env.privateOverlay) {
      const responsePromise = page.waitForResponse((candidate) => {
        const url = new URL(candidate.url());
        return candidate.request().method() === "POST" && url.pathname === "/api/pcb-layouts/barracuda-base";
      }, { timeout: PAGE_TIMEOUT_MS });
      result = await measured(page, async () => page.locator("#pcb-update").click(), async () => {
        response = await responsePromise;
        await page.waitForFunction((rev) => document.querySelector("#pcb-savemsg")?.textContent === "updated ✓" &&
          (PCB.rev || 0) > rev && document.querySelector("#pcb-update")?.disabled === false,
        beforeRev, { timeout: PAGE_TIMEOUT_MS });
      });
      if (!response.ok()) throw new Error(`PCB layout update returned ${response.status()}`);
      const body = await response.json();
      if (body?.ok !== true || !(body.rev > beforeRev)) throw new Error(`PCB layout update returned invalid revision ${JSON.stringify(body)}`);
    } else {
      result = await measured(page, async () => page.locator("#pcb-update").click(), async () =>
        page.waitForFunction((old) => {
          const message = document.querySelector("#pcb-savemsg")?.textContent || "";
          return message !== old && !/updating…/.test(message) && /(failed|interrupted|fetch|network)/i.test(message);
        }, before));
    }
    if (await page.evaluate(() => window.PCBActiveLayoutName?.()) !== active) throw new Error("PCB update changed the active layout identity");
    return result;
  },
  "pcb_2d.drc_navigation": async (page) => {
    if (!await page.locator("#side-drc").isVisible()) await page.locator('[data-sidetab="side-drc"]').click();
    await page.locator("#side-drc").waitFor({ state: "visible" });
    await page.waitForFunction(() => (PCB.drc || []).length > 0 &&
      document.querySelectorAll("#drc-list .drc-row, #drc-list .drc-net").length > 0);
    const before = await page.evaluate(() => ({
      pos: document.querySelector("#drc-pos")?.textContent || "",
      message: document.querySelector("#drc-cur")?.textContent || "",
    }));
    const result = await measured(page, async () => page.locator("#drc-next").click(), async () =>
      page.waitForFunction(({ oldPos, oldMessage }) => {
        const pos = document.querySelector("#drc-pos")?.textContent || "";
        const message = document.querySelector("#drc-cur")?.textContent || "";
        return pos !== oldPos && message !== oldMessage && /^1\s*\/\s*\d+$/.test(pos.trim()) &&
          document.querySelectorAll("#drc-list .cur").length > 0;
      }, { oldPos: before.pos, oldMessage: before.message }));
    await page.locator("#drc-prev").click();
    await page.waitForFunction(({ oldPos, oldMessage }) => {
      const selected = document.querySelector(".drc-row.cur, .drc-net.cur");
      const pos = document.querySelector("#drc-pos")?.textContent || "";
      const message = document.querySelector("#drc-cur")?.textContent || "";
      const match = pos.trim().match(/^(\d+)\s*\/\s*(\d+)$/);
      return selected && match && match[1] === match[2] && pos !== oldPos && message !== oldMessage &&
        message.length > 0 && !message.startsWith("Click a violation");
    }, { oldPos: before.pos, oldMessage: before.message });
    await page.locator("#z-fit").click();
    await afterFrames(page, 2);
    return result;
  },
  "pcb_2d.trace_route_cancel": async (page) => pcbTraceRouteCancel(page),
  "pcb_2d.via_place_undo": async (page) => pcbViaPlaceUndo(page),
  "pcb_2d.pour_zone_cancel": async (page) => {
    const zones = await page.evaluate(() => JSON.stringify(PCB.zones || []));
    const result = await measuredVisual(page, page.locator("#pcb-toolstrip"), "PCB pour-zone tool",
      async () => page.locator("#pcb-pour-zone").click(),
      async () => page.waitForFunction(() => document.querySelector("#pcb-pour-zone")?.classList.contains("on") &&
        !document.querySelector("#tool-select")?.classList.contains("on")));
    await page.locator("#tool-select").click();
    await page.waitForFunction(() => !document.querySelector("#pcb-pour-zone")?.classList.contains("on") &&
      document.querySelector("#tool-select")?.classList.contains("on"));
    if (await page.evaluate(() => JSON.stringify(PCB.zones || [])) !== zones) throw new Error("cancelling PCB pour-zone tool changed zones");
    return result;
  },
  "pcb_2d.pour_refill": async (page) => {
    if (!await page.locator("#side-route").isVisible()) await page.locator('[data-sidetab="side-route"]').click();
    const button = page.locator("#pcb-pour");
    await button.waitFor({ state: "visible" });
    await page.waitForFunction(() => PCB.analysis_deferred === false &&
      document.querySelector("#pcb-pour")?.disabled === false, null, { timeout: PAGE_TIMEOUT_MS });
    const responsePromise = page.waitForResponse((response) => {
      const url = new URL(response.url());
      return response.request().method() === "POST" && /^\/api\/pcb-drc\/[^/]+$/.test(url.pathname) &&
        url.searchParams.get("pours") === "1" && url.searchParams.get("pours_only") === "1";
    }, { timeout: PAGE_TIMEOUT_MS });
    let response;
    const result = await measuredWall(page, async () => button.click(), async () => {
      response = await responsePromise;
      await page.waitForFunction(() => {
        const fills = (PCB.pours || []).length + (PCB.plane_fills || []).length + (PCB.zone_fills || []).length;
        return document.querySelector("#pcb-pour")?.disabled === false && PCB.poursStale === false && fills > 0;
      }, null, { timeout: PAGE_TIMEOUT_MS });
    });
    if (!response.ok()) throw new Error(`PCB pour refill returned ${response.status()}`);
    const payload = await response.json();
    if (![payload.pours, payload.plane_fills, payload.zone_fills].some(Array.isArray)) {
      throw new Error("PCB pour refill response contains no fill arrays");
    }
    return result;
  },
  "pcb_2d.zoom_controls": async (page) => {
    const scene = page.locator(".pcb-scene-shell");
    const beforeImage = await visualSnapshot(scene);
    const initial = await page.locator("#pcb-svg").getAttribute("viewBox");
    const initialWidth = Number(initial.split(/\s+/)[2]);
    const result = await measured(page, async () => page.locator("#z-in").click(), async () =>
      page.waitForFunction((width) => Number(document.querySelector("#pcb-svg")?.getAttribute("viewBox")?.split(/\s+/)[2]) < width, initialWidth));
    requireVisualChange(beforeImage, await visualSnapshot(scene), "PCB zoom-in control");
    const zoomedWidth = Number((await page.locator("#pcb-svg").getAttribute("viewBox")).split(/\s+/)[2]);
    await page.locator("#z-out").click();
    await page.waitForFunction((width) => Number(document.querySelector("#pcb-svg")?.getAttribute("viewBox")?.split(/\s+/)[2]) > width, zoomedWidth);
    const zoomedOutWidth = Number((await page.locator("#pcb-svg").getAttribute("viewBox")).split(/\s+/)[2]);
    await page.locator("#z-in").click();
    await page.waitForFunction((width) => Number(document.querySelector("#pcb-svg")?.getAttribute("viewBox")?.split(/\s+/)[2]) < width, zoomedOutWidth);
    const beforeFitWidth = Number((await page.locator("#pcb-svg").getAttribute("viewBox")).split(/\s+/)[2]);
    await page.locator("#z-fit").click();
    await page.waitForFunction(({ beforeFit, fitted }) => {
      const width = Number(document.querySelector("#pcb-svg")?.getAttribute("viewBox")?.split(/\s+/)[2]);
      return width > beforeFit && Math.abs(width - fitted) < 0.1;
    }, { beforeFit: beforeFitWidth, fitted: initialWidth });
    return result;
  },
  "pcb_2d.part_drag_undo": async (page) => pcbPartDragUndo(page, "U8"),
  "pcb_2d.pan": async (page) => dragGesture(page, page, page.locator(".pcb-scene"), { button: "middle" }),
  "pcb_2d.zoom": async (page) => wheelGesture(page, page, page.locator(".pcb-scene")),

  "pcb_3d.streaming_orbit": async (page) => dragGesture(page, page, page.locator("#pcb-3d-canvas"), pcb3dGestureState(page)),
  "pcb_3d.streaming_zoom": async (page) => wheelGesture(page, page, page.locator("#pcb-3d-canvas"), pcb3dGestureState(page)),
  "pcb_3d.preset": async (page) => measuredVisual(page, page.locator("#pcb-3d-canvas"), "PCB 3D camera preset",
    async () => page.locator("#pcb3d-top").click()),
  "pcb_3d.visibility": async (page) => {
    const toggle = page.locator("#pcb3d-t-axes");
    const result = await measuredVisual(page, page.locator("#pcb-3d-canvas"), "PCB 3D visibility toggle",
      async () => toggle.uncheck(), async () => page.waitForFunction(() => !document.querySelector("#pcb3d-t-axes")?.checked));
    await toggle.check();
    await afterFrames(page, 3);
    return result;
  },
  "pcb_3d.orbit": async (page) => dragGesture(page, page, page.locator("#pcb-3d-canvas"), pcb3dGestureState(page)),
  "pcb_3d.zoom": async (page) => wheelGesture(page, page, page.locator("#pcb-3d-canvas"), pcb3dGestureState(page)),

  "thermal.scenario": async (page) => {
    const frame = await thermalFrame(page);
    const beforeRevision = await frame.evaluate(() => window.PCBThermal?.painted?.().revision || 0);
    const responsePromise = page.waitForResponse((response) => {
      const url = new URL(response.url());
      return url.pathname.startsWith("/api/thermal-field/") && url.searchParams.get("scenario") === "airflow_1ms";
    }, { timeout: PAGE_TIMEOUT_MS });
    let response;
    const result = await measured(page, async () => page.locator('[data-scenario="airflow_1ms"].tp-seg-btn').click(), async () => {
      response = await responsePromise;
      await page.waitForFunction(() => document.querySelector('[data-scenario="airflow_1ms"].tp-seg-btn')?.classList.contains("on") &&
        document.querySelector("#tp-heat-loading")?.hidden === true && document.querySelector("#tp-status")?.hidden === true,
      null, { timeout: PAGE_TIMEOUT_MS });
      await frame.waitForFunction((revision) => {
        const painted = window.PCBThermal?.painted?.();
        return painted?.scenario === "airflow_1ms" && painted.revision > revision;
      }, beforeRevision, { timeout: PAGE_TIMEOUT_MS });
    });
    if (!response.ok()) throw new Error(`thermal scenario field returned ${response.status()}`);
    return result;
  },
  "thermal.ambient": async (page) => {
    const frame = await thermalFrame(page);
    const beforeRevision = await frame.evaluate(() => window.PCBThermal?.painted?.().revision || 0);
    const fieldResponse = page.waitForResponse((response) => {
      const url = new URL(response.url());
      return url.pathname.startsWith("/api/thermal-field/") && url.searchParams.get("ambient") === "26";
    }, { timeout: PAGE_TIMEOUT_MS });
    const fragmentResponse = page.waitForResponse((response) => {
      const url = new URL(response.url());
      return url.pathname.startsWith("/thermal/") && url.searchParams.get("fragment") === "1" &&
        url.searchParams.get("ambient") === "26";
    }, { timeout: PAGE_TIMEOUT_MS });
    let field;
    let fragment;
    const result = await measured(page, async () => {
      await page.locator("#tp-ambient").fill("26");
      await page.locator("#tp-ambient").press("Enter");
    }, async () => {
      [field, fragment] = await Promise.all([fieldResponse, fragmentResponse]);
      await page.waitForFunction(() => document.querySelector("#tp-page")?.dataset.ambient === "26" &&
        document.querySelector("#tp-status")?.hidden === true, null, { timeout: PAGE_TIMEOUT_MS });
      await frame.waitForFunction((revision) => {
        const painted = window.PCBThermal?.painted?.();
        return painted?.ambient === 26 && painted.revision > revision;
      }, beforeRevision, { timeout: PAGE_TIMEOUT_MS });
    });
    if (!field.ok()) throw new Error(`thermal field refresh returned ${field.status()}`);
    if (!fragment.ok()) throw new Error(`thermal ambient fragment returned ${fragment.status()}`);
    return result;
  },
  "thermal.face": async (page) => {
    const frame = await thermalFrame(page);
    const beforeRevision = await frame.evaluate(() => window.PCBThermal?.painted?.().revision || 0);
    const result = await measured(page, async () => page.locator("#tp-face-bottom").click(), async () => {
      await page.waitForFunction(() => document.querySelector("#tp-face-bottom").getAttribute("aria-pressed") === "true");
      await frame.waitForFunction((revision) => {
        const painted = window.PCBThermal?.painted?.();
        return painted?.side === "bottom" && painted.revision > revision;
      }, beforeRevision);
    });
    // Restore the component-populated face before exercising labels. Some
    // valid boards have no bottom-side labelled parts, in which case a real
    // labels toggle would correctly leave the pixels unchanged.
    await page.locator("#tp-face-top").click();
    await page.waitForFunction(() => document.querySelector("#tp-face-top").getAttribute("aria-pressed") === "true");
    await frame.waitForFunction(() => window.PCBThermal?.painted?.().side === "top");
    await afterFrames(frame, 3);
    return result;
  },
  "thermal.labels": async (page) => {
    const frame = await thermalFrame(page);
    return measuredVisual(page, frame.locator(".pcb-scene-shell"), "thermal labels",
      async () => page.locator("#tp-labels").check(), async () => {
        await frame.waitForFunction(() => window.PCBThermal?.painted?.().labels === true);
      });
  },
  "thermal.opacity": async (page) => {
    const frame = await thermalFrame(page);
    return measuredVisual(page, frame.locator(".pcb-scene-shell"), "thermal opacity",
      async () => page.locator("#tp-opacity").evaluate((input) => {
        input.value = "60"; input.dispatchEvent(new Event("input", { bubbles: true }));
      }), async () => {
        await frame.waitForFunction(() => window.PCBThermal?.painted?.().opacity === 0.6);
      });
  },
  "thermal.pan": async (page) => { const frame = await thermalFrame(page); return dragGesture(page, frame, frame.locator(".pcb-scene"), { button: "middle" }); },
  "thermal.zoom": async (page) => { const frame = await thermalFrame(page); return wheelGesture(page, frame, frame.locator(".pcb-scene")); },

  // The system-review workspace opens a document by clicking its list button.
  // Wait for the whole applied state — active button, title, loaded source,
  // rendered preview — because openDoc() sets them from one awaited fetch and
  // a partial check would time the fetch instead of the usable document.
  "system_review.document_open": async (page) => openSystemDocument(page, "Barracuda B3 Manufacturing Review"),
  // No listener is bound to the textarea today, so this measures the editor's
  // raw input latency on a real authored document. It is the tripwire for the
  // live-preview/validation work this pane invites: anything that starts
  // reacting to keystrokes shows up here rather than in a user's hands.
  "system_review.source_edit": async (page) => {
    const source = page.locator("#source");
    if (await source.isDisabled()) throw new Error("system review source edit needs an editable document open");
    const before = await source.inputValue();
    const result = await measured(page, async () => source.pressSequentially(" review note", { delay: 0 }),
      async () => page.waitForFunction((old) => document.querySelector("#source")?.value === `${old} review note`, before));
    // Never saved, but leave the pane on the authored text so a later
    // repetition cannot measure a document that drifted inside the browser.
    await source.fill(before);
    await page.waitForFunction((old) => document.querySelector("#source")?.value === old, before);
    await afterFrames(page, 2);
    return result;
  },
  "system_review.large_document": async (page) => openSystemDocument(page, "Historical Complete BOM Snapshot"),

  "library.search": async (page) => {
    const before = {
      page: (await page.locator("#page-info").textContent())?.trim() || "",
      visible: await page.locator("#lib-grid .comp-card:visible").count(),
    };
    const result = await measured(page, async () => page.locator("#lib-search").fill("c-0402"),
      async () => page.waitForFunction(({ oldPage, oldCount, query }) => {
        const visible = Array.from(document.querySelectorAll("#lib-grid .comp-card"))
          .filter((card) => getComputedStyle(card).display !== "none");
        const pageInfo = document.querySelector("#page-info")?.textContent.trim() || "";
        return pageInfo !== oldPage && visible.length > 0 && visible.length < oldCount && visible.every((card) =>
          (card.getAttribute("data-search") || "").toLowerCase().includes(query));
      }, { oldPage: before.page, oldCount: before.visible, query: "c-0402" }));
    await page.locator("#lib-search").fill("");
    await afterFrames(page, 2);
    return result;
  },
  "library.pagination": async (page) => {
    const before = await page.locator("#page-info").textContent();
    const result = await measured(page, async () => page.locator("#page-next").click(),
      async () => page.waitForFunction((old) => document.querySelector("#page-info").textContent !== old, before));
    await page.locator("#page-prev").click();
    await afterFrames(page, 2);
    return result;
  },
  "library.footprint_preview": async (page) => {
    await page.locator("#lib-search").fill("c-0402");
    const tag = page.locator('.fp-toggle[data-fp="c-0402"]:visible').first();
    return measured(page, async () => tag.click(), async () => page.locator(".fp-preview.open .fp-court-edit").waitFor({ state: "visible" }));
  },
  "library.courtyard_editor": async (page) => measured(page, async () => page.locator(".fp-preview.open .fp-court-edit").click(),
    async () => page.locator("#lib-court-modal").waitFor({ state: "visible" })).then(async (result) => { await page.locator("#lib-court-cancel").click(); await afterFrames(page, 2); return result; }),

  "footprint_editor.select_pad": async (page) => measured(page, async () => page.locator("#editor-svg [data-pad-key]").first().click(),
    async () => page.locator("#pad-inspector").waitFor({ state: "visible" })),
  "footprint_editor.pad_drag_undo": async (page) => footprintPadDragUndo(page),
  "footprint_editor.inspector_edit_undo": async (page) => {
    const input = page.locator("#pad-x");
    const before = Number(await input.inputValue());
    const target = Number((before + 0.1).toFixed(3));
    const result = await measured(page, async () => {
      await input.fill(String(target));
      await input.press("Tab");
    }, async () => page.waitForFunction((value) => Math.abs(Number(document.querySelector("#pad-x")?.value) - value) < 1e-9, target));
    await page.locator("#undo").click();
    await page.waitForFunction((value) => Math.abs(Number(document.querySelector("#pad-x")?.value) - value) < 1e-9, before);
    await afterFrames(page, 2);
    return result;
  },
  "footprint_editor.duplicate_undo": async (page) => {
    const before = await page.locator("#editor-svg [data-pad-key]").count();
    return measured(page, async () => {
    await page.locator("#duplicate-pad").click();
    await page.waitForFunction((count) => document.querySelectorAll("#editor-svg [data-pad-key]").length === count + 1, before);
    await page.locator("#undo").click();
    }, async () => page.waitForFunction((count) => document.querySelectorAll("#editor-svg [data-pad-key]").length === count, before));
  },
  "footprint_editor.add_undo": async (page) => {
    const before = await page.locator("#editor-svg [data-pad-key]").count();
    return measured(page, async () => {
    await page.locator("#add-pad").click();
    await page.waitForFunction((count) => document.querySelectorAll("#editor-svg [data-pad-key]").length === count + 1, before);
    await page.locator("#undo").click();
    }, async () => page.waitForFunction((count) => document.querySelectorAll("#editor-svg [data-pad-key]").length === count, before));
  },
  "footprint_editor.grid_units": async (page) => measuredVisual(page, page.locator("#editor-svg"), "footprint grid and units", async () => {
    await page.locator("#grid").selectOption({ index: 1 });
    await page.locator("#units").selectOption("mil");
    await page.locator("#units").selectOption("mm");
  }, async () => page.waitForFunction(() => document.querySelector("#grid")?.value === "0.025" && document.querySelector("#units")?.value === "mm")),
  "footprint_editor.pan": async (page) => dragGesture(page, page, page.locator("#editor-svg"), { button: "middle" }),
  "footprint_editor.zoom": async (page) => wheelGesture(page, page, page.locator("#editor-svg")),

  "model_alignment_3d.preset": async (page) => measuredVisual(page, page.locator("#view"), "model camera preset",
    async () => page.locator("#view-top").click()),
  "model_alignment_3d.rotation": async (page) => {
    const target = await page.evaluate(() => {
      const selectors = ["#rot-x-r", "#rot-y-r", "#rot-z-r", "#off-x-r", "#off-y-r", "#off-z-r"];
      window.__uiPerfOriginalModelTransform ||= selectors.map((selector) => Number(document.querySelector(selector)?.value || 0));
      const input = document.querySelector("#rot-z-r");
      const current = Number(input.value);
      const max = Number(input.max || 180);
      const min = Number(input.min || -180);
      return current + 15 <= max ? current + 15 : Math.max(min, current - 15);
    });
    return measuredVisual(page, page.locator("#view"), "model rotation", async () => page.locator("#rot-z-r").evaluate((input, value) => {
      input.value = String(value); input.dispatchEvent(new Event("input", { bubbles: true }));
    }, target), async () => page.waitForFunction((value) => Math.abs(Number(document.querySelector("#rot-z-r")?.value) - value) < 1e-9, target));
  },
  "model_alignment_3d.offset": async (page) => measuredVisual(page, page.locator("#view"), "model offset", async () => page.locator("#off-x-r").evaluate((input) => {
    input.value = "1"; input.dispatchEvent(new Event("input", { bubbles: true }));
  }), async () => page.waitForFunction(() => document.querySelector("#off-x-r")?.value === "1")),
  "model_alignment_3d.visibility": async (page) => {
    const toggle = page.locator("#t-model");
    const result = await measuredVisual(page, page.locator("#view"), "model visibility",
      async () => toggle.uncheck(), async () => page.waitForFunction(() => !document.querySelector("#t-model")?.checked));
    await toggle.check();
    await afterFrames(page, 2);
    return result;
  },
  "model_alignment_3d.seat_mode": async (page) => {
    const result = await measured(page, async () => page.locator("#align-seat").click(), async () =>
      page.waitForFunction(() => document.querySelector("#align-seat")?.classList.contains("active") &&
        document.querySelector("#status")?.textContent.includes("Seat")));
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => !document.querySelector("#align-seat")?.classList.contains("active"));
    await afterFrames(page, 2);
    return result;
  },
  "model_alignment_3d.move_mode": async (page) => {
    const result = await measured(page, async () => page.locator("#align-move").click(), async () =>
      page.waitForFunction(() => document.querySelector("#align-move")?.classList.contains("active") &&
        document.querySelector("#status")?.textContent.includes("Move")));
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => !document.querySelector("#align-move")?.classList.contains("active"));
    await afterFrames(page, 2);
    return result;
  },
  "model_alignment_3d.save": async (page, env) => {
    if (!env.privateOverlay) return measured(page, async () => page.locator("#save").click(), async () =>
      page.waitForFunction(() => document.querySelector("#save-state")?.textContent === "save failed"));
    const saveResponse = () => page.waitForResponse((candidate) => candidate.request().method() === "POST" &&
      new URL(candidate.url()).pathname === "/api/model-transform/mc3007", { timeout: PAGE_TIMEOUT_MS });
    let response;
    const pending = saveResponse();
    const result = await measured(page, async () => page.locator("#save").click(), async () => {
      response = await pending;
      await page.waitForFunction(() => document.querySelector("#save-state")?.textContent === "saved ✓" &&
        document.querySelector("#save")?.disabled === true, null, { timeout: PAGE_TIMEOUT_MS });
    });
    if (!response.ok() || (await response.json())?.ok !== true) throw new Error(`model transform save returned ${response.status()}`);

    // Restore the opening transform through the same private API outside the
    // timed interval. This resets server-side invalidation/version state as
    // well as the file before the next repetition.
    const original = await page.evaluate(() => window.__uiPerfOriginalModelTransform);
    if (!Array.isArray(original) || original.length !== 6) throw new Error("model transform save has no opening-state checkpoint");
    await page.evaluate((values) => {
      ["#rot-x-r", "#rot-y-r", "#rot-z-r", "#off-x-r", "#off-y-r", "#off-z-r"].forEach((selector, index) => {
        const input = document.querySelector(selector);
        input.value = String(values[index]);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
    }, original);
    await page.waitForFunction(() => document.querySelector("#save")?.disabled === false &&
      document.querySelector("#save-state")?.textContent === "unsaved changes");
    const restorePending = saveResponse();
    await page.locator("#save").click();
    const restoreResponse = await restorePending;
    await page.waitForFunction(() => document.querySelector("#save-state")?.textContent === "saved ✓" &&
      document.querySelector("#save")?.disabled === true, null, { timeout: PAGE_TIMEOUT_MS });
    if (!restoreResponse.ok() || (await restoreResponse.json())?.ok !== true) {
      throw new Error(`model transform restore returned ${restoreResponse.status()}`);
    }
    await afterFrames(page, 2);
    return result;
  },
  "model_alignment_3d.reset": async (page) => {
    // Save restores the opening transform before this scenario. Seed a local,
    // deliberately unsaved pose so Reset is guaranteed to exercise a real
    // rendered transition even when the library transform already is zero.
    await page.locator("#rot-z-r").evaluate((input) => {
      input.value = "17";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await page.waitForFunction(() => document.querySelector("#rot-z-r")?.value === "17" &&
      document.querySelector("#save-state")?.textContent === "unsaved changes");
    await afterFrames(page, 2);
    return measuredVisual(page, page.locator("#view"), "model reset",
      async () => page.locator("#reset").click(), async () => page.waitForFunction(() =>
        document.querySelector("#rot-z-r")?.value === "0" && document.querySelector("#off-x-r")?.value === "0"));
  },
  "model_alignment_3d.orbit": async (page) => dragGesture(page, page, page.locator("#view"), model3dGestureQuality(page)),
  "model_alignment_3d.zoom": async (page) => wheelGesture(page, page, page.locator("#view"), model3dGestureQuality(page)),

  "route_review.route": async (page, env) => {
    await page.locator("#rr-files").setInputFiles(env.fixture);
    const responsePromise = page.waitForResponse((response) =>
      response.request().method() === "POST" && new URL(response.url()).pathname === "/api/kicad-route-review/run");
    const result = await measured(page, async () => page.locator("#rr-run").click(),
      async () => page.waitForFunction(() => !document.querySelector("#rr-app").hidden, null, { timeout: 60000 }));
    const review = await (await responsePromise).json();
    const last = review.timeline?.at(-1);
    const workload = {
      parts: review.parts?.length,
      nets: review.nets?.length,
      zones: review.zones?.length,
      decisions: review.timeline?.length,
      routed: review.final?.routed,
      tracks: last?.tracks?.length,
      vias: last?.vias?.length,
    };
    if (!workload || workload.parts !== routeReviewWorkload.parts ||
        workload.nets !== routeReviewWorkload.nets || workload.zones !== routeReviewWorkload.zones ||
        workload.decisions < routeReviewWorkload.min_decisions || workload.routed !== routeReviewWorkload.nets ||
        workload.tracks < routeReviewWorkload.min_tracks || workload.vias < routeReviewWorkload.min_vias) {
      throw new Error(`route-review fixture workload mismatch: ${JSON.stringify(workload)}`);
    }
    return { ...result, workload };
  },
  "route_review.timeline": async (page) => {
    const before = Number(await page.locator("#rr-slider").inputValue());
    return measuredVisual(page, page.locator("#rr-canvas"), "route timeline",
      async () => page.locator("#rr-next").click(),
      async () => page.waitForFunction((step) => Number(document.querySelector("#rr-slider")?.value) === step + 1, before));
  },
  "route_review.layers": async (page) => {
    const toggle = page.locator("#rr-labels");
    const result = await measuredVisual(page, page.locator("#rr-canvas"), "route labels",
      async () => toggle.uncheck(), async () => page.waitForFunction(() => !document.querySelector("#rr-labels")?.checked));
    await toggle.check();
    await afterFrames(page, 2);
    return result;
  },
  "route_review.pan": async (page) => dragGesture(page, page, page.locator("#rr-canvas")),
  "route_review.zoom": async (page) => wheelGesture(page, page, page.locator("#rr-canvas")),

  "pdf_viewer.lazy_scroll": async (page) => {
    const completed = page.locator('#page-4[data-render-complete="true"]');
    if (await completed.count()) throw new Error("PDF lazy target rendered before scrolling");
    return measured(page, async () => {
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    }, async () => completed.waitFor({ state: "attached", timeout: 30000 }));
  },
  "pdf_viewer.next_match": async (page) => measured(page, async () => {
    await page.locator("#next").click();
  }, async () => {
    await page.waitForFunction(() => document.querySelector("#count")?.textContent.trim() === "2 / 4");
    await page.evaluate(() => new Promise((resolve) => {
      let previous = window.scrollY, stableFrames = 0;
      function frame() {
        const current = window.scrollY;
        stableFrames = Math.abs(current - previous) < 0.5 ? stableFrames + 1 : 0;
        previous = current;
        if (stableFrames >= 4) resolve();
        else requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
    }));
  }),
};

async function waitSurfaceReady(page, surface) {
  await page.locator(surface.ready).first().waitFor({ state: "visible", timeout: PAGE_TIMEOUT_MS });
  if (["pcb_2d", "pcb_3d"].includes(surface.id)) {
    await page.waitForFunction(() => typeof PCB !== "undefined", null, { timeout: PAGE_TIMEOUT_MS });
  }
  if (surface.id === "pcb_3d") {
    await page.waitForFunction(() => {
      const canvas = document.querySelector("#pcb-3d-canvas");
      const status = document.querySelector("#pcb-3d-status");
      return canvas && canvas.width > 0 && status && getComputedStyle(status).display === "none";
    }, null, { timeout: PAGE_TIMEOUT_MS });
  }
  if (surface.id === "thermal") {
    const frame = await thermalFrame(page);
    await frame.waitForFunction(() => typeof PCB !== "undefined", null, { timeout: PAGE_TIMEOUT_MS });
    await page.locator("#tp-heat-loading").waitFor({ state: "hidden", timeout: PAGE_TIMEOUT_MS });
  }
  if (surface.id === "model_alignment_3d") {
    await page.waitForFunction(() => {
      const view = document.querySelector("#view");
      const status = document.querySelector("#status");
      return view && view.width > 0 && status && getComputedStyle(status).display === "none";
    }, null, { timeout: PAGE_TIMEOUT_MS });
  }
  if (surface.id === "system_review") {
    // boot() opens the first document and then fires refreshReady(). Wait for
    // BOTH to settle — the editor holding real source, and the readiness panel
    // off its "Computing readiness…" placeholder — so no scenario below is
    // timed while boot() is still assigning page state.
    await page.waitForFunction(() => {
      const panel = document.querySelector("#readiness");
      return (document.querySelector("#source")?.value.length || 0) > 0 &&
        (document.querySelector("#rendered")?.childElementCount || 0) > 0 &&
        Boolean(panel) && (panel.classList.contains("ok") || panel.classList.contains("blocked"));
    }, null, { timeout: PAGE_TIMEOUT_MS });
  }
  if (surface.id === "pdf_viewer") {
    await page.locator('body[data-pdf-ready="true"] #status.hidden').waitFor({ state: "attached", timeout: PAGE_TIMEOUT_MS });
  }
  await afterFrames(page, 2);
}

function expectedFailure(url, status) {
  const pathname = new URL(url).pathname;
  return (pathname === "/api/erc/lt3045" && status === 500) ||
    pathname.startsWith("/api/sync-kicad-pcb/") ||
    (pathname.startsWith("/api/route-live/") && status === 404) ||
    pathname === "/favicon.ico";
}

function focusedScenarioPlan(surface, target) {
  const scenariosById = new Map(surface.scenarios.map((scenario) => [scenario.id, scenario]));
  const completed = new Set();
  const visiting = [];
  const plan = [];
  function visit(scenario) {
    if (completed.has(scenario.id)) return;
    const cycleStart = visiting.indexOf(scenario.id);
    if (cycleStart !== -1) {
      const cycle = [...visiting.slice(cycleStart), scenario.id].join(" -> ");
      throw new Error(`${surface.id} has a cyclic focused setup dependency: ${cycle}`);
    }
    visiting.push(scenario.id);
    for (const setupId of scenario.setup || []) {
      const setup = scenariosById.get(setupId);
      if (!setup) throw new Error(`${surface.id}.${scenario.id} needs missing setup ${setupId}`);
      visit(setup);
    }
    visiting.pop();
    completed.add(scenario.id);
    plan.push(scenario);
  }
  visit(target);
  return plan;
}

async function runSurface(browser, baseUrl, surface, env) {
  const context = await browser.newContext({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1, serviceWorkers: "block" });
  try {
    return await runSurfaceInContext(context, baseUrl, surface, env);
  } finally {
    await context.close();
  }
}

async function runSurfaceInContext(context, baseUrl, surface, env) {
  const network = { private_mutations: [], blocked_mutations: [], blocked_expected: [], blocked_external: [], failures: [] };
  const focusedTarget = env.scenario ? surface.scenarios.find((scenario) =>
    env.scenario === `${surface.id}.${scenario.id}`) : null;
  if (env.scenario && !focusedTarget) throw new Error(`${surface.id} has no focused scenario ${env.scenario}`);
  const focusedPlan = focusedTarget ? focusedScenarioPlan(surface, focusedTarget) : null;
  const enabledScenarios = focusedPlan || surface.scenarios;
  env.expectedBlockedMutations = enabledScenarios.flatMap((scenario) => scenario.blockedMutations || []);
  env.requiredBlockedMutations = enabledScenarios.flatMap((scenario) => scenario.requiredBlockedMutations || []);
  env.expectedPrivateMutations = enabledScenarios.flatMap((scenario) => scenario.privateMutations || []);
  env.requiredPrivateMutations = enabledScenarios.flatMap((scenario) => scenario.requiredPrivateMutations || []);
  env.activePrivateMutations = new Set();
  const origin = new URL(baseUrl).origin;
  await context.addInitScript(() => {
    window.__uiPerfLongTasks = [];
    window.__uiPerfLongTaskSince = 0;
    try {
      window.__uiPerfLongTaskObserver = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.startTime >= window.__uiPerfLongTaskSince) window.__uiPerfLongTasks.push(entry.duration);
        }
      });
      window.__uiPerfLongTaskObserver.observe({ type: "longtask", buffered: true });
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
    if (request.method() === "GET" && url.pathname === "/datasheets/browser-perf.pdf") {
      return route.fulfill({ path: env.pdfFixture, contentType: "application/pdf" });
    }
    // System-review release readiness is deliberately OUT of browser-perf
    // scope, and blocked rather than merely unmeasured. It cannot succeed
    // here: the overlay symlinks lib/, and the board-review source closure
    // requires every imported .sexp to canonicalize INSIDE --project-dir, so
    // the composition always ends in SourceOutsideProject (HTTP 422) after
    // ~27 s of real work. Waiting for that would spend a third of this
    // surface's wall clock on a guaranteed error, and letting it run in the
    // background would leave both boards' fab analyses competing with every
    // interaction timed below. The page renders the failure into #readiness
    // and stays fully usable, which is the state the scenarios measure.
    // Covering it for real needs the overlay to copy lib/components and
    // lib/modules; see AUDIT-LEDGER DRIFT-SYSREV-001.
    if (request.method() === "GET" && /^\/api\/systems\/[^/]+\/readiness$/.test(url.pathname)) {
      network.blocked_expected.push(`${request.method()} ${url.pathname}`);
      return route.abort("blockedbyclient");
    }
    const method = request.method().toUpperCase();
    if (!["GET", "HEAD", "OPTIONS"].includes(method)) {
      if (method === "POST" && url.pathname === "/api/kicad-route-review/run") return route.continue();
      if (method === "POST" && url.pathname.startsWith("/api/sync-kicad-pcb/") && url.searchParams.get("dry_run") === "1") return route.continue();
      if (method === "POST" && /^\/api\/pcb-drc\/[^/]+$/.test(url.pathname)) return route.continue();
      const label = `${method} ${url.pathname}`;
      if (env.privateOverlay && env.activePrivateMutations.has(label)) {
        network.private_mutations.push(label);
        return route.continue();
      }
      if (!env.privateOverlay && (env.expectedPrivateMutations || []).includes(label)) {
        network.blocked_expected.push(label);
        return route.abort("blockedbyclient");
      }
      if ((env.expectedBlockedMutations || []).some((prefix) => label.startsWith(prefix))) network.blocked_expected.push(label);
      else network.blocked_mutations.push(label);
      return route.abort("blockedbyclient");
    }
    return route.continue();
  });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(String(error)));
  page.on("response", (response) => {
    if (response.status() >= 400 && new URL(response.url()).origin === origin && !expectedFailure(response.url(), response.status())) {
      network.failures.push(`${response.status()} ${new URL(response.url()).pathname}`);
    }
  });
  page.on("requestfailed", (request) => {
    const url = new URL(request.url());
    const label = `${request.method()} ${url.pathname}: ${request.failure()?.errorText || "failed"}`;
    const blockedLabel = `${request.method()} ${url.pathname}`;
    if (url.origin === origin && !network.blocked_mutations.includes(blockedLabel) && !network.blocked_expected.includes(blockedLabel)) network.failures.push(label);
  });

    let scene = null;
    const started = performance.now();
    const response = await page.goto(`${baseUrl}${surface.path}`, { waitUntil: "domcontentloaded", timeout: PAGE_TIMEOUT_MS });
    if (!response || !response.ok()) throw new Error(`${surface.path} returned ${response ? response.status() : "no response"}`);
    await waitSurfaceReady(page, surface);
    const readyMs = performance.now() - started;
    const nav = await page.evaluate(() => {
      const row = performance.getEntriesByType("navigation")[0];
      return row ? {
        response_ms: row.responseEnd - row.startTime,
        dom_content_loaded_ms: row.domContentLoadedEventEnd - row.startTime,
        load_ms: row.loadEventEnd > 0 ? row.loadEventEnd - row.startTime : null,
      } : null;
    });
    const actions = {};
    async function waitForRequiredBlockedMutations(scenario, sinceIndex) {
      if (!scenario.requiredBlockedMutations?.length) return;
      const deadline = Date.now() + 3000;
      while (Date.now() < deadline && scenario.requiredBlockedMutations.some((prefix) =>
        !network.blocked_expected.slice(sinceIndex).some((label) => label.startsWith(prefix)))) await sleep(25);
      for (const prefix of scenario.requiredBlockedMutations) {
        if (!network.blocked_expected.slice(sinceIndex).some((label) => label.startsWith(prefix))) {
          throw new Error(`${surface.id}.${scenario.id} did not freshly attempt expected blocked mutation ${prefix}`);
        }
      }
    }
    async function waitForRequiredPrivateMutations(scenario, sinceIndex) {
      if (!scenario.requiredPrivateMutations?.length) return;
      const observed = env.privateOverlay ? network.private_mutations : network.blocked_expected;
      const deadline = Date.now() + 3000;
      while (Date.now() < deadline && scenario.requiredPrivateMutations.some((label) =>
        !observed.slice(sinceIndex).includes(label))) await sleep(25);
      for (const label of scenario.requiredPrivateMutations) {
        if (!observed.slice(sinceIndex).includes(label)) {
          throw new Error(`${surface.id}.${scenario.id} did not freshly ${env.privateOverlay ? "complete private" : "attempt blocked"} mutation ${label}`);
        }
      }
    }
    async function runScenario(scenario) {
      const key = `${surface.id}.${scenario.id}`;
      const blockedAt = network.blocked_expected.length;
      const privateAt = env.privateOverlay ? network.private_mutations.length : network.blocked_expected.length;
      env.activePrivateMutations = new Set(scenario.privateMutations || []);
      try {
        const result = await ACTIONS[key](page, env);
        await waitForRequiredBlockedMutations(scenario, blockedAt);
        await waitForRequiredPrivateMutations(scenario, privateAt);
        return result;
      } finally {
        env.activePrivateMutations.clear();
      }
    }
    async function runFocusedSetups() {
      const setups = focusedPlan.slice(0, -1);
      for (const setup of setups) {
        process.stderr.write(`ui_browser_perf:   setup ${surface.id}.${setup.id}\n`);
        await runScenario(setup);
      }
      if (!setups.length) return;
      await page.evaluate(() => {
        window.__uiPerfLongTaskSince = performance.now();
        window.__uiPerfLongTaskObserver?.takeRecords();
        window.__uiPerfLongTasks = [];
      });
    }
    async function runActions(phase) {
      for (const scenario of surface.scenarios) {
        if ((scenario.phase || "steady") !== phase) continue;
        const key = `${surface.id}.${scenario.id}`;
        if (env.scenario && env.scenario !== key) continue;
        if (env.scenario) await runFocusedSetups();
        process.stderr.write(`ui_browser_perf:   ${key}\n`);
        actions[scenario.id] = { kind: scenario.kind, ...await runScenario(scenario) };
      }
    }
    // Base readiness intentionally means the textured board and camera are
    // usable. Exercise it while STEP parsing is still active, then wait for
    // every preview before timing the same steady-state 3D interactions.
    if (surface.id === "pcb_3d") {
      await page.waitForFunction(() => document.querySelector("#pcb3d-export-step")?.disabled, null, { timeout: 30000 });
      await runActions("streaming");
      await page.waitForFunction(() => {
        const button = document.querySelector("#pcb3d-export-step");
        return button && !button.disabled;
      }, null, { timeout: PAGE_TIMEOUT_MS });
      await afterFrames(page, 2);
      nav.full_scene_ready_ms = performance.now() - started;
      const progress = await page.evaluate(() => window.PCB3D.modelProgress());
      if (!(progress.expected > 0) || progress.pending !== 0 || progress.loaded !== progress.expected) {
        throw new Error(`PCB 3D model scene incomplete: ${JSON.stringify(progress)}`);
      }
      scene = { model_instances: progress.loaded };
    }
    await runActions("steady");
    const longTasks = await page.evaluate(() => window.__uiPerfLongTasks || []);
    for (const prefix of env.requiredBlockedMutations) {
      if (!network.blocked_expected.some((label) => label.startsWith(prefix))) {
        throw new Error(`${surface.id} did not attempt expected blocked mutation ${prefix}`);
      }
    }
    const privateObserved = env.privateOverlay ? network.private_mutations : network.blocked_expected;
    for (const label of env.requiredPrivateMutations) {
      if (!privateObserved.includes(label)) {
        throw new Error(`${surface.id} did not ${env.privateOverlay ? "complete required private" : "attempt required blocked"} mutation ${label}`);
      }
    }
    if (pageErrors.length) throw new Error(`page errors:\n${pageErrors.join("\n")}`);
    if (network.blocked_mutations.length) throw new Error(`unexpected mutating requests:\n${network.blocked_mutations.join("\n")}`);
    if (network.blocked_external.length) throw new Error(`external requests (the gate is hermetic):\n${network.blocked_external.join("\n")}`);
    if (network.failures.length) throw new Error(`first-party request failures:\n${Array.from(new Set(network.failures)).join("\n")}`);
    return {
      navigation: { ...nav, ready_ms: round(readyMs) },
      ...(scene ? { scene } : {}),
      actions,
      long_tasks: { count: longTasks.length, total_ms: round(longTasks.reduce((sum, value) => sum + value, 0)), max_ms: round(Math.max(0, ...longTasks)) },
    };
}

function summarizeSurface(surface, runs) {
  const navigation = {};
  for (const metric of ["response_ms", "dom_content_loaded_ms", "load_ms", "ready_ms", "full_scene_ready_ms"]) {
    const values = runs.map((run) => run.navigation[metric]).filter((value) => typeof value === "number");
    if (!values.length) continue;
    navigation[`${metric.replace(/_ms$/, "")}_p50_ms`] = round(percentile(values, 0.5));
    navigation[`${metric.replace(/_ms$/, "")}_p95_ms`] = round(percentile(values, 0.95));
    navigation[`${metric.replace(/_ms$/, "")}_max_ms`] = round(Math.max(0, ...values));
  }
  const actions = {};
  for (const scenario of surface.scenarios) {
    const rows = runs.map((run) => run.actions[scenario.id]).filter(Boolean);
    if (!rows.length) continue;
    if (scenario.kind === "frame") {
      actions[scenario.id] = {
        kind: scenario.kind,
        median_frames: percentile(rows.map((row) => row.frames), 0.5),
        p50_ms: round(percentile(rows.map((row) => row.p50_ms), 0.5)),
        p95_ms: round(percentile(rows.map((row) => row.p95_ms), 0.95)),
        worst_p95_ms: round(Math.max(...rows.map((row) => row.p95_ms))),
        max_ms: round(Math.max(...rows.map((row) => row.max_ms))),
      };
    } else {
      const values = rows.map((row) => row.ms);
      actions[scenario.id] = {
        kind: scenario.kind,
        p50_ms: round(percentile(values, 0.5)),
        p95_ms: round(percentile(values, 0.95)),
        max_ms: round(Math.max(...values)),
        ...(rows[0].workload ? { workload: rows[0].workload } : {}),
      };
    }
  }
  return {
    label: surface.label,
    path: surface.path,
    repetitions: runs.length,
    navigation,
    actions,
    ...(runs[0].scene ? { scene: runs[0].scene } : {}),
    long_tasks: {
      median_count: percentile(runs.map((run) => run.long_tasks.count), 0.5),
      worst_count: Math.max(...runs.map((run) => run.long_tasks.count)),
      median_total_ms: round(percentile(runs.map((run) => run.long_tasks.total_ms), 0.5)),
      max_ms: round(Math.max(...runs.map((run) => run.long_tasks.max_ms)), 0.5),
    },
  };
}

async function runResponses(baseUrl) {
  const rows = {};
  for (const scenario of responseScenarios) {
    const start = performance.now();
    const response = await fetch(`${baseUrl}${scenario.path}`, { redirect: "manual" });
    const body = await response.arrayBuffer();
    const elapsed = round(performance.now() - start);
    if (response.status !== scenario.expect) throw new Error(`${scenario.id}: HTTP ${response.status}, expected ${scenario.expect}`);
    if (scenario.location && response.headers.get("location") !== scenario.location) {
      throw new Error(`${scenario.id}: Location ${response.headers.get("location")}, expected ${scenario.location}`);
    }
    if (scenario.contentType && !(response.headers.get("content-type") || "").startsWith(scenario.contentType)) {
      throw new Error(`${scenario.id}: content type ${response.headers.get("content-type")}, expected ${scenario.contentType}`);
    }
    rows[scenario.id] = { path: scenario.path, response_ms: elapsed, bytes: body.byteLength };
  }
  return rows;
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

function valueAt(object, dotted) {
  return dotted.split(".").reduce((value, key) => value == null ? undefined : value[key], object);
}

function defaultBudgets(summary) {
  const budgets = {};
  const navigationLimits = {
    home: 750,
    schematic: 2000,
    module: 750,
    pcb_2d: 2000,
    pcb_3d: 2000,
    thermal: 3000,
    system_review: 750,
    library: 750,
    footprint_editor: 750,
    model_alignment_3d: 1500,
    route_review: 750,
    pdf_viewer: 1500,
  };
  const longTaskTotalLimits = {
    home: 1000,
    pcb_2d: 750,
    pcb_3d: 1000,
    model_alignment_3d: 750,
    pdf_viewer: 750,
  };
  for (const [id, surface] of Object.entries(summary.surfaces)) {
    budgets[`surfaces.${id}.navigation.ready_p95_ms`] = navigationLimits[id] || 10000;
    // SwiftShader's first textured PCB frame contains a one-time native layer
    // commit (measured 184–254 ms) before base readiness. STEP streaming adds
    // no long tasks; the strict frame budgets below gate actual interaction.
    budgets[`surfaces.${id}.long_tasks.max_ms`] = id === "pcb_3d" ? 300 : 250;
    budgets[`surfaces.${id}.long_tasks.median_total_ms`] = longTaskTotalLimits[id] || 500;
    if (id === "pcb_3d") {
      budgets["surfaces.pcb_3d.navigation.full_scene_ready_p95_ms"] = 20000;
      budgets["surfaces.pcb_3d.navigation.full_scene_ready_max_ms"] = 25000;
    }
    for (const [actionId, action] of Object.entries(surface.actions)) {
      const spec = scenarioSpecs.get(`${id}.${actionId}`);
      if (action.kind === "frame") {
        budgets[`surfaces.${id}.actions.${actionId}.worst_p95_ms`] = spec?.budgets?.p95_ms ?? 35;
        budgets[`surfaces.${id}.actions.${actionId}.max_ms`] = spec?.budgets?.max_ms ?? 65;
      } else {
        const asyncLimit = id === "thermal" && actionId === "ambient" ? 8000 : 3000;
        const p95Limit = action.kind === "async" ? asyncLimit : 150;
        const maxLimit = action.kind === "async" ? asyncLimit * 1.25 : 250;
        budgets[`surfaces.${id}.actions.${actionId}.p95_ms`] = spec?.budgets?.p95_ms ?? p95Limit;
        budgets[`surfaces.${id}.actions.${actionId}.max_ms`] = spec?.budgets?.max_ms ?? maxLimit;
      }
    }
  }
  for (const id of Object.keys(summary.responses || {})) {
    budgets[`responses.${id}.response_ms`] = id === "datasheet_response" ? 500 : 250;
  }
  return budgets;
}

function enforce(summary, baselinePath, partial) {
  if (!fs.existsSync(baselinePath)) throw new Error(`missing UI browser baseline ${baselinePath}; run --record deliberately`);
  const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
  if (!baseline.budgets || !Object.keys(baseline.budgets).length) throw new Error(`${baselinePath} has no budgets`);
  const failures = [];
  if (!partial) {
    const recordedCommit = baseline.reference?.designs?.commit;
    if (!recordedCommit) failures.push("designs.commit: baseline has no workload commit");
    else if (summary.designs.commit !== recordedCommit) failures.push(`designs.commit: workload ${summary.designs.commit} != recorded ${recordedCommit}; re-record deliberately`);
    const recordedFingerprint = baseline.reference?.designs?.fingerprint;
    if (!recordedFingerprint) failures.push("designs.fingerprint: baseline has no workload fingerprint");
    else if (summary.designs.fingerprint !== recordedFingerprint) failures.push("designs.fingerprint: workload bundle changed; re-record deliberately");
    if (summary.designs.dirty) failures.push("designs.dirty: performance workload contains uncommitted changes");
  }
  for (const metric of Object.keys(defaultBudgets(summary))) {
    const limit = baseline.budgets[metric];
    if (!Object.prototype.hasOwnProperty.call(baseline.budgets, metric)) failures.push(`${metric}: baseline has no budget`);
    else if (typeof limit !== "number" || !Number.isFinite(limit) || limit < 0) failures.push(`${metric}: baseline budget must be a finite non-negative number`);
  }
  for (const [metric, limit] of Object.entries(baseline.budgets)) {
    if (typeof limit !== "number" || !Number.isFinite(limit) || limit < 0) {
      if (!failures.some((failure) => failure.startsWith(`${metric}:`))) failures.push(`${metric}: baseline budget must be a finite non-negative number`);
      continue;
    }
    const actual = valueAt(summary, metric);
    if (actual == null && partial) continue;
    if (typeof actual !== "number") failures.push(`${metric}: result has no numeric value`);
    else if (actual > limit) failures.push(`${metric}: ${actual} ms > ${limit} ms budget`);
  }
  if (failures.length) throw new Error(`UI browser performance regression:\n  ${failures.join("\n  ")}`);
}

function printSummary(summary) {
  console.log(`ui_browser_perf: ${summary.browser} · ${Object.keys(summary.surfaces).length} surfaces`);
  for (const [id, surface] of Object.entries(summary.surfaces)) {
    const fullScene = surface.navigation.full_scene_ready_p50_ms == null ? "" :
      `  full scene ${surface.navigation.full_scene_ready_p50_ms.toFixed(1)} ms`;
    console.log(`  ${id.padEnd(19)} ready p50 ${surface.navigation.ready_p50_ms.toFixed(1)} ms  p95 ${surface.navigation.ready_p95_ms.toFixed(1)} ms${fullScene}`);
    for (const [name, action] of Object.entries(surface.actions)) {
      if (action.kind === "frame") console.log(`    ${name.padEnd(19)} frame p50 ${action.p50_ms.toFixed(1)}  p95 ${action.worst_p95_ms.toFixed(1)}  max ${action.max_ms.toFixed(1)} ms`);
      else console.log(`    ${name.padEnd(19)} ${action.kind.padEnd(5)} p50 ${action.p50_ms.toFixed(1)}  p95 ${action.p95_ms.toFixed(1)} ms`);
    }
  }
}

async function main() {
  const options = readArgs(process.argv.slice(2));
  if (options.list) {
    for (const surface of surfaces) console.log(`${surface.id}: ${surface.scenarios.map((scenario) => `${scenario.id}(${scenario.kind})`).join(", ")}`);
    console.log("assembly: delegated to scripts/pcb_browser_perf/run.js");
    for (const scenario of responseScenarios) console.log(`${scenario.id}: ${scenario.path}`);
    return;
  }
  const knownIds = new Set(surfaces.map((surface) => surface.id));
  if (options.surfaceIds) for (const id of options.surfaceIds) if (!knownIds.has(id)) failUsage(`unknown surface ${id}`);
  if (options.scenario && !Object.prototype.hasOwnProperty.call(ACTIONS, options.scenario)) failUsage(`unknown scenario ${options.scenario}`);
  let selected = options.surfaceIds ? surfaces.filter((surface) => options.surfaceIds.includes(surface.id)) : surfaces;
  if (options.scenario) selected = selected.filter((surface) => options.scenario.startsWith(`${surface.id}.`));
  if (!selected.length) failUsage("filters selected no surfaces");
  // Past the free checks (--list and argument validation exit above), this is
  // a timing measurement: queue it under the machine-wide gate so it cannot
  // skew (or be skewed by) a gated run in a sibling session. No-op when
  // perf_gate.sh already holds the lock.
  ensureGateLock("ui_browser_perf");
  if (!fs.existsSync(options.fixture)) throw new Error(`missing route-review fixture ${options.fixture}`);
  if (!fs.existsSync(options.pdfFixture)) throw new Error(`missing PDF fixture ${options.pdfFixture}`);

  let server = null;
  let overlay = null;
  let serverText = "";
  let browser = null;
  let baseUrl = options.url ? options.url.replace(/\/$/, "") : null;
  try {
    if (!baseUrl) {
      if (!fs.existsSync(options.binary)) throw new Error(`missing ${options.binary}; build netlisp first`);
      if (!fs.existsSync(path.join(options.projectDir, "src"))) throw new Error(`no designs repo at ${options.projectDir}`);
      overlay = projectOverlay(options.projectDir, options.pdfFixture);
      const port = await freePort();
      baseUrl = `http://127.0.0.1:${port}`;
      server = spawn(options.binary, ["serve", "--project-dir", overlay, "--port", String(port), "--skip-warmup"], {
        cwd: root,
        // NETLISP_GIT_AUTOCOMMIT=0 is not optional: config.zig defaults
        // auto-commit to ENABLED when the variable is unset, and the mutating
        // endpoints (system_review_api.zig document save / attest / asset
        // upload) call autocommit.begin() unconditionally. Only production is
        // otherwise protected, by its systemd unit. Together with
        // projectOverlay's refusal to link .git this is defence in depth: a
        // benchmark server must not be able to commit anywhere.
        env: { ...process.env, NETLISP_DEV: "1", NETLISP_GIT_AUTOCOMMIT: "0" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      const append = (chunk) => { serverText = (serverText + chunk.toString()).slice(-24000); };
      server.stdout.on("data", append);
      server.stderr.on("data", append);
      await waitForServer(`${baseUrl}/`, server, () => serverText);
    }

    browser = await chromium.launch({ headless: true });
    const summary = {
      schema: 1,
      browser: `Chromium ${await browser.version()}`,
      viewport: { width: 1600, height: 900, dpr: 1 },
      designs: projectFacts(options.projectDir),
      repetitions: options.reps,
      surfaces: {},
      responses: options.url || options.scenario || options.surfaceIds ? {} : await runResponses(baseUrl),
    };
    const failures = [];
    for (const surface of selected) {
      const runs = [];
      for (let rep = 0; rep < options.reps; rep++) {
        process.stderr.write(`ui_browser_perf: ${surface.id} ${rep + 1}/${options.reps}\n`);
        const mutationCheckpoint = overlay && surface.scenarios.some((scenario) => scenario.privateMutations?.length) ?
          privateMutationCheckpoint(overlay) : null;
        try {
          runs.push(await runSurface(browser, baseUrl, surface, {
            fixture: options.fixture,
            pdfFixture: options.pdfFixture,
            scenario: options.scenario,
            privateOverlay: Boolean(overlay),
          }));
        } catch (error) {
          failures.push(`${surface.id} run ${rep + 1}: ${error.stack || error}`);
          break;
        } finally {
          if (mutationCheckpoint) restorePrivateMutationCheckpoint(mutationCheckpoint);
        }
      }
      if (runs.length) summary.surfaces[surface.id] = summarizeSurface(surface, runs);
    }
    printSummary(summary);
    if (failures.length) throw new Error(`surface failures:\n${failures.join("\n\n")}`);
    if (options.record && summary.designs.dirty) throw new Error("refusing to record a baseline from a dirty designs checkout; use scripts/perf_gate.sh --record for a clean HEAD snapshot");
    if (options.record) {
      const previous = fs.existsSync(options.baseline) ? JSON.parse(fs.readFileSync(options.baseline, "utf8")) : {};
      const document = {
        schema: 1,
        recorded_at: new Date().toISOString(),
        reference: summary,
        budgets: { ...defaultBudgets(summary), ...(previous.budgets || {}) },
      };
      fs.mkdirSync(path.dirname(options.baseline), { recursive: true });
      fs.writeFileSync(`${options.baseline}.tmp`, `${JSON.stringify(document, null, 2)}\n`);
      fs.renameSync(`${options.baseline}.tmp`, options.baseline);
      console.log(`ui_browser_perf: recorded ${options.baseline}`);
    } else {
      enforce(summary, options.baseline, !!(options.surfaceIds || options.scenario));
      console.log(`ui_browser_perf: PASS ${options.baseline}`);
    }
    console.log(JSON.stringify(summary));
  } finally {
    if (browser) await browser.close();
    await stopServer(server);
    if (overlay) fs.rmSync(overlay, { recursive: true, force: true });
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`ui_browser_perf: FAIL: ${error.stack || error}`);
    process.exitCode = 1;
  });
}

module.exports = { ACTIONS, defaultBudgets, summarizeSurface };
