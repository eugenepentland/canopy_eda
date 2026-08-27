#!/usr/bin/env node
"use strict";

// Real-browser assembly interaction benchmark. It starts an isolated local
// netlisp server unless --url is supplied, opens the actual assembly page, and
// adds the viewer's opt-in fbench flags to that page's PCB iframe request.
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const localLib = path.join(os.homedir(), ".local", "lib", "playwright-chromium", "usr", "lib", "x86_64-linux-gnu");
if (fs.existsSync(localLib)) {
  process.env.LD_LIBRARY_PATH = [localLib, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":");
}
const { chromium } = require("playwright");

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
  return out;
}

function percentile(values, q) {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.round(q * (sorted.length - 1))))];
}

function rounded(n) { return Number(n.toFixed(2)); }

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

async function runOne(browser, baseUrl, design) {
  const context = await browser.newContext({
    viewport: { width: 1600, height: 900 },
    deviceScaleFactor: 1,
    serviceWorkers: "block",
  });
  await context.addInitScript(() => {
    window.__assemblyLongTasks = [];
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) window.__assemblyLongTasks.push({ start: entry.startTime, duration: entry.duration });
      }).observe({ type: "longtask", buffered: true });
    } catch (_) {}
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  page.on("console", (message) => { if (message.type() === "error") errors.push(`console: ${message.text()}`); });

  const started = Date.now();
  const response = await page.goto(`${baseUrl}/assembly-debug/${encodeURIComponent(design)}`, {
    waitUntil: "domcontentloaded",
    timeout: 180000,
  });
  if (!response || !response.ok()) throw new Error(`assembly page returned ${response ? response.status() : "no response"}`);
  if (!page.url().startsWith(baseUrl)) throw new Error(`assembly page escaped the local server: ${page.url()}`);
  // Change the frame's actual document URL. Rewriting only the intercepted
  // request URL leaves window.location at the original query in Chromium, so
  // the viewer correctly sees no fbench flag and never starts its harness.
  await page.locator("#pcb-frame").evaluate((element) => {
    const url = new URL(element.src);
    url.searchParams.set("fbench", "quick");
    url.searchParams.set("gpu", "0");
    element.src = url.toString();
  });
  const benchDeadline = Date.now() + 600000;
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
  if (!hasResult) throw new Error("frame benchmark did not finish within 600 seconds");

  const measured = await page.evaluate(() => {
    const element = document.getElementById("pcb-frame");
    const win = element.contentWindow;
    const nav = win.performance.getEntriesByType("navigation")[0];
    const rect = element.getBoundingClientRect();
    const longTasks = win.__assemblyLongTasks || [];
    return {
      frame: win.__fbench,
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
  measured.errors = errors;
  await context.close();

  if (measured.frame.error) throw new Error(measured.frame.error);
  if (measured.frame.design !== design) throw new Error(`expected ${design}, measured ${measured.frame.design}`);
  if (measured.frame.profile !== "quick") throw new Error(`expected quick frame profile, got ${measured.frame.profile}`);
  if (!measured.frame.physical_review) throw new Error("the PCB iframe was not in physical review mode");
  if (!measured.frame.cam_review) throw new Error("the benchmark ran before exact CAM artwork loaded");
  if (measured.frame.mode !== "2d") throw new Error(`expected deterministic 2D review renderer, got ${measured.frame.mode}`);
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
  return {
    design,
    surface: "assembly physical CAM review",
    renderer: "Canvas2D",
    browser: `Chromium ${browserVersion}`,
    viewport: { width: 1600, height: 900, dpr: 1 },
    iframe: runs[0].iframe,
    repetitions: runs.length,
    phases,
    long_tasks: {
      median_count: percentile(runs.map((run) => run.long_tasks.count), 0.5),
      worst_count: Math.max(...runs.map((run) => run.long_tasks.count)),
      median_total_ms: rounded(percentile(runs.map((run) => run.long_tasks.total_ms), 0.5)),
      max_ms: rounded(Math.max(...runs.map((run) => run.long_tasks.max_ms))),
    },
    navigation: {
      median_response_ms: rounded(percentile(runs.map((run) => run.navigation.response_ms), 0.5)),
      median_load_ms: rounded(percentile(runs.map((run) => run.navigation.load_ms), 0.5)),
    },
    median_run_wall_ms: percentile(runs.map((run) => run.wall_ms), 0.5),
  };
}

function valueAt(object, dotted) {
  return dotted.split(".").reduce((value, key) => value == null ? undefined : value[key], object);
}

function enforce(summary, baselinePath) {
  if (!fs.existsSync(baselinePath)) throw new Error(`missing browser baseline ${baselinePath}; run with --record deliberately`);
  const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
  if (!baseline.budgets || !Object.keys(baseline.budgets).length) throw new Error(`browser baseline ${baselinePath} has no budgets`);
  const failures = [];
  for (const [metric, limit] of Object.entries(baseline.budgets)) {
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
  console.log(`  long tasks median ${summary.long_tasks.median_count}, worst ${summary.long_tasks.worst_count}; navigation response ${summary.navigation.median_response_ms.toFixed(2)} ms`);
}

async function main() {
  const options = argsRead(process.argv.slice(2));
  let server = null;
  let serverText = "";
  let baseUrl = options.url ? options.url.replace(/\/$/, "") : null;
  let browser = null;
  try {
    if (!baseUrl) {
      if (!fs.existsSync(options.binary)) throw new Error(`missing ${options.binary}; build netlisp first`);
      if (!fs.existsSync(path.join(options.projectDir, "src"))) throw new Error(`no designs repo at ${options.projectDir}`);
      const port = await freePort();
      baseUrl = `http://127.0.0.1:${port}`;
      server = spawn(options.binary, ["serve", "--project-dir", options.projectDir, "--port", String(port), "--skip-warmup"], {
        cwd: root,
        env: { ...process.env, NETLISP_DEV: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      const append = (chunk) => { serverText = (serverText + chunk.toString()).slice(-16000); };
      server.stdout.on("data", append);
      server.stderr.on("data", append);
      await waitForServer(`${baseUrl}/`, server, () => serverText);
    }

    browser = await chromium.launch({ headless: true });
    const runs = [];
    for (let i = 0; i < options.reps; i++) {
      process.stderr.write(`assembly_browser_perf: run ${i + 1}/${options.reps}\n`);
      runs.push(await runOne(browser, baseUrl, options.design));
    }
    const summary = summarize(runs, await browser.version(), options.design);
    printSummary(summary);
    if (options.record) {
      const prior = fs.existsSync(options.baseline) ? JSON.parse(fs.readFileSync(options.baseline, "utf8")) : {};
      const document = { schema: 1, recorded_at: new Date().toISOString(), reference: summary, budgets: prior.budgets || {} };
      fs.mkdirSync(path.dirname(options.baseline), { recursive: true });
      fs.writeFileSync(`${options.baseline}.tmp`, `${JSON.stringify(document, null, 2)}\n`);
      fs.renameSync(`${options.baseline}.tmp`, options.baseline);
      console.log(`assembly_browser_perf: recorded ${options.baseline}`);
      if (!Object.keys(document.budgets).length) console.warn("assembly_browser_perf: add reviewed budgets before enabling enforcement");
    } else {
      enforce(summary, options.baseline);
      console.log(`assembly_browser_perf: PASS ${options.baseline}`);
    }
    console.log(JSON.stringify(summary));
  } finally {
    if (browser) await browser.close();
    await stopServer(server);
  }
}

main().catch((error) => {
  console.error(`assembly_browser_perf: FAIL: ${error.stack || error}`);
  process.exitCode = 1;
});
