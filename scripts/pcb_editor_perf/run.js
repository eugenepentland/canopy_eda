#!/usr/bin/env node
// Deterministic Barracuda PCB-editor zoom gate.
//
// The all-pages runner sends ordinary wheel input, which browsers may coalesce
// before a paint. This gate uses pcb_board.js's opt-in frame program instead:
// one camera mutation is queued ahead of one paint, at 8x zoom in both
// directions. It checks two deliberately different renderer contracts:
//   - Canvas2D at DPR 2: the supported fallback on a high-density display.
//   - WebGPU at DPR 1 through pinned SwiftShader: asserts RF copper remains on
//     the retained GPU path and bounds command/raster cost deterministically.
//
// The baseline also carries the designs-workload identity it was recorded
// against (reference.designs). Under scripts/perf_gate.sh's snapshot env that
// identity is enforced like the sibling runners'; standalone (prepare-release
// certifying the release binary against the live checkout) drift is labelled,
// not failed — the zoom budgets here are absolute, so certification does not
// depend on a matching baseline workload.
"use strict";

const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const { execFileSync, spawn } = require("child_process");
const { ensureGateLock } = require("../perf_gate_lock");

const localLib = path.join(os.homedir(), ".local", "lib", "playwright-chromium", "usr", "lib", "x86_64-linux-gnu");
if (fs.existsSync(localLib)) process.env.LD_LIBRARY_PATH = [localLib, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "..", "..");
const defaults = {
  binary: path.join(root, "zig-out-browser-perf", "bin", "netlisp"),
  projectDir: path.join(root, "projects", "designs"),
  baseline: path.join(root, "docs", "benchmarks", "pcb-editor", "baseline.json"),
  design: "barracuda-base",
  reps: 3,
  record: false,
  url: null,
};

function parseArgs(argv) {
  const out = { ...defaults };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i], take = () => {
      if (++i >= argv.length) throw new Error(`${arg} requires a value`);
      return argv[i];
    };
    if (arg === "--binary") out.binary = path.resolve(take());
    else if (arg === "--project-dir") out.projectDir = path.resolve(take());
    else if (arg === "--baseline") out.baseline = path.resolve(take());
    else if (arg === "--design") out.design = take();
    else if (arg === "--reps") out.reps = Number(take());
    else if (arg === "--url") out.url = take().replace(/\/$/, "");
    else if (arg === "--record") out.record = true;
    else if (arg === "--help") {
      console.log("usage: node scripts/pcb_editor_perf/run.js [--binary PATH] [--project-dir DIR] [--reps N] [--baseline FILE] [--url LOOPBACK] [--record]");
      process.exit(0);
    } else throw new Error(`unknown argument ${arg}`);
  }
  if (!Number.isInteger(out.reps) || out.reps < 1) throw new Error("--reps must be a positive integer");
  if (out.url && !/^http:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?$/.test(out.url)) throw new Error("--url must be loopback HTTP");
  if (out.url && out.record) throw new Error("--record requires a self-started server");
  return out;
}

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => { const port = s.address().port; s.close(() => resolve(port)); });
  });
}

async function waitForServer(url, child, text) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (child.exitCode != null) throw new Error(`server exited ${child.exitCode}\n${text()}`);
    try { const r = await fetch(url); if (r.status > 0) return; } catch (_) {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`server did not become ready\n${text()}`);
}

function percentile(values, q) {
  const a = values.slice().sort((x, y) => x - y);
  if (!a.length) return 0;
  return a[Math.min(a.length - 1, Math.max(0, Math.round(q * (a.length - 1))))];
}
const round = (v) => Math.round(v * 10) / 10;

function summarizeRuns(runs) {
  const out = {};
  for (const phase of ["zoom_in", "zoom_out"]) {
    out[phase] = {
      median_p50_ms: round(percentile(runs.map((r) => r.frame[phase].p50), 0.5)),
      worst_p95_ms: round(Math.max(...runs.map((r) => r.frame[phase].p95))),
      max_ms: round(Math.max(...runs.map((r) => r.frame[phase].max))),
    };
  }
  return out;
}

async function runOne(browser, baseUrl, design, profile) {
  const context = await browser.newContext({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: profile.dpr });
  const page = await context.newPage(), faults = [];
  page.on("pageerror", (e) => faults.push(`pageerror: ${e.message}`));
  page.on("request", (req) => {
    const u = new URL(req.url());
    if (!["GET", "HEAD", "OPTIONS"].includes(req.method()) && !(req.method() === "POST" && u.pathname.startsWith("/api/pcb-drc/")))
      faults.push(`unexpected ${req.method()} ${req.url()}`);
  });
  page.on("response", (res) => {
    const u = new URL(res.url());
    if (res.status() >= 400 && u.pathname !== "/favicon.ico" && !(res.status() === 404 && u.pathname.startsWith("/api/route-live/")))
      faults.push(`HTTP ${res.status()} ${u.pathname}`);
  });
  const url = `${baseUrl}/pcb-layout/${encodeURIComponent(design)}?gpu=${profile.gpu ? 1 : 0}&fbench=zoom`;
  const response = await page.goto(url, { waitUntil: "load", timeout: 120000 });
  if (!response || response.status() !== 200) throw new Error(`${profile.id}: navigation returned ${response && response.status()}`);
  await page.waitForFunction(() => window.__fbench, null, { timeout: 120000 });
  const result = await page.evaluate(() => ({
    frame: window.__fbench,
    chip: document.querySelector("#st-gpu")?.textContent || "",
    gpuActive: !!window.PCBGpu?.active,
    workload: window.__fbench?.workload || {},
  }));
  await context.close();
  if (faults.length) throw new Error(`${profile.id}: browser faults\n  ${faults.join("\n  ")}`);
  if (result.frame?.error) throw new Error(`${profile.id}: ${result.frame.error}`);
  if (result.frame?.profile !== "zoom" || result.frame?.dpr !== profile.dpr) throw new Error(`${profile.id}: wrong benchmark profile/DPR`);
  if (result.frame?.mode !== profile.mode) throw new Error(`${profile.id}: renderer ${result.frame?.mode}, expected ${profile.mode}`);
  if (profile.gpu && (!result.gpuActive || result.chip !== "GPU")) throw new Error(`${profile.id}: WebGPU did not remain active`);
  const w = result.workload;
  if (w.rf_paths < 50 || w.tracks < 1000 || w.vias < 500) throw new Error(`${profile.id}: Barracuda workload is too small (${JSON.stringify(w)})`);
  return result;
}

function limits() {
  return {
    "canvas.zoom_in.median_p50_ms": 30,
    "canvas.zoom_in.worst_p95_ms": 45,
    "canvas.zoom_in.max_ms": 55,
    "canvas.zoom_out.median_p50_ms": 30,
    "canvas.zoom_out.worst_p95_ms": 45,
    "canvas.zoom_out.max_ms": 55,
    // SwiftShader is intentionally a deterministic correctness/command-cost
    // oracle, not a stand-in for a hardware GPU. These caps catch a return to
    // per-path draw explosions while the DPR-2 Canvas profile carries the
    // strict user-facing frame budget.
    "gpu.zoom_in.median_p50_ms": 110,
    "gpu.zoom_in.worst_p95_ms": 150,
    "gpu.zoom_in.max_ms": 160,
    "gpu.zoom_out.median_p50_ms": 110,
    "gpu.zoom_out.worst_p95_ms": 150,
    "gpu.zoom_out.max_ms": 160,
  };
}

function valueAt(o, dotted) { return dotted.split(".").reduce((v, k) => v == null ? undefined : v[k], o); }

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

function enforce(summary, baseline) {
  if (!fs.existsSync(baseline)) throw new Error(`missing ${baseline}; record it deliberately`);
  const doc = JSON.parse(fs.readFileSync(baseline, "utf8")), budgets = doc.budgets || {}, failures = [];
  // Workload identity: strict under scripts/perf_gate.sh's snapshot env (the
  // sibling runners' contract); a printed label standalone, where
  // prepare-release measures the live checkout and must not be blocked by
  // designs work-in-progress.
  const strict = Boolean(process.env.NETLISP_PERF_DESIGNS_COMMIT);
  const recorded = doc.reference?.designs, note = (line) => console.error(`pcb_editor_perf: NOTE ${line}`);
  if (!recorded?.commit || !recorded?.fingerprint) {
    if (strict) failures.push("designs.fingerprint: baseline has no workload identity; re-record deliberately");
    else note(`${baseline} records no designs workload identity; the next scripts/perf_gate.sh --record stamps it`);
  } else if (summary.designs.fingerprint && summary.designs.fingerprint !== recorded.fingerprint) {
    if (strict) failures.push(`designs.fingerprint: workload bundle changed (recorded designs ${recorded.commit.slice(0, 12)}, measuring ${summary.designs.commit.slice(0, 12)}); re-record deliberately`);
    else note(`measuring designs ${String(summary.designs.commit).slice(0, 12)} against a baseline recorded at designs ${recorded.commit.slice(0, 12)} — workload drift; the absolute zoom budgets still apply`);
  }
  if (summary.designs.dirty) {
    if (strict) failures.push("designs.dirty: performance workload contains uncommitted changes");
    else note("measuring a dirty designs checkout; the identity above reflects committed state only");
  }
  for (const metric of Object.keys(limits())) {
    const actual = valueAt(summary, metric), limit = budgets[metric];
    if (!Number.isFinite(limit)) failures.push(`${metric}: missing finite budget`);
    else if (!Number.isFinite(actual)) failures.push(`${metric}: missing result`);
    else if (actual > limit) failures.push(`${metric}: ${actual} ms > ${limit} ms`);
  }
  if (failures.length) throw new Error(`PCB editor zoom regression:\n  ${failures.join("\n  ")}`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  // A standalone zoom run is a timing measurement like any other: queue it
  // under the machine-wide gate so it cannot skew (or be skewed by) a gated
  // run in a sibling session. No-op when perf_gate.sh already holds the lock.
  ensureGateLock("pcb_editor_perf");
  let server = null, serverText = "", baseUrl = options.url;
  try {
    if (!baseUrl) {
      if (!fs.existsSync(options.binary)) throw new Error(`missing ${options.binary}`);
      if (!fs.existsSync(path.join(options.projectDir, "src"))) throw new Error(`no designs repo at ${options.projectDir}`);
      const port = await freePort(); baseUrl = `http://127.0.0.1:${port}`;
      server = spawn(options.binary, ["serve", "--project-dir", options.projectDir, "--port", String(port), "--skip-warmup"], {
        // This runner has no overlay — it serves the REAL designs checkout, so
        // it is the one place where an auto-commit would land in the user's
        // repository directly rather than through a symlinked .git. config.zig
        // defaults auto-commit to ENABLED when unset; disable it explicitly.
        cwd: root, env: { ...process.env, NETLISP_DEV: "1", NETLISP_GIT_AUTOCOMMIT: "0" }, stdio: ["ignore", "pipe", "pipe"],
      });
      const append = (c) => { serverText = (serverText + c.toString()).slice(-16000); };
      server.stdout.on("data", append); server.stderr.on("data", append);
      await waitForServer(`${baseUrl}/`, server, () => serverText);
    }

    const icd = path.join(path.dirname(chromium.executablePath()), "vk_swiftshader_icd.json");
    if (fs.existsSync(icd) && !process.env.VK_ICD_FILENAMES) process.env.VK_ICD_FILENAMES = icd;
    const profiles = [
      { id: "canvas", dpr: 2, gpu: false, mode: "2d", launch: { headless: true } },
      { id: "gpu", dpr: 1, gpu: true, mode: "gpu", launch: { headless: true, args: [
        "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-angle=swiftshader",
        "--disable-vulkan-surface", "--enable-dawn-features=allow_unsafe_apis",
      ] } },
    ], summary = { schema: 1, design: options.design, viewport: { width: 1600, height: 900 }, repetitions: options.reps };
    summary.designs = projectFacts(options.projectDir);
    if (options.record && summary.designs.dirty)
      throw new Error("refusing to record a baseline from a dirty designs checkout; use scripts/perf_gate.sh --record for a clean HEAD snapshot");
    for (const profile of profiles) {
      // Launch profiles serially so the software WebGPU process cannot steal
      // CPU from the high-DPI Canvas measurement (or vice versa).
      const browser = await chromium.launch(profile.launch);
      try {
        const runs = [];
        for (let i = 0; i < options.reps; i++) {
          process.stderr.write(`pcb_editor_perf: ${profile.id} ${i + 1}/${options.reps}\n`);
          runs.push(await runOne(browser, baseUrl, options.design, profile));
        }
        summary[profile.id] = summarizeRuns(runs);
        summary[profile.id].dpr = profile.dpr;
        summary[profile.id].renderer = profile.mode;
        summary.workload = runs[0].workload;
      } finally { await browser.close(); }
    }
    console.log(JSON.stringify(summary, null, 2));
    if (options.record) {
      const prior = fs.existsSync(options.baseline) ? JSON.parse(fs.readFileSync(options.baseline, "utf8")) : {};
      const doc = { schema: 1, recorded_at: new Date().toISOString(), reference: summary, budgets: prior.budgets || limits() };
      fs.mkdirSync(path.dirname(options.baseline), { recursive: true });
      fs.writeFileSync(`${options.baseline}.tmp`, `${JSON.stringify(doc, null, 2)}\n`);
      fs.renameSync(`${options.baseline}.tmp`, options.baseline);
      console.log(`pcb_editor_perf: recorded ${options.baseline}`);
    } else {
      enforce(summary, options.baseline);
      console.log(`pcb_editor_perf: PASS ${options.baseline}`);
    }
  } finally {
    if (server) { server.kill("SIGTERM"); await new Promise((r) => setTimeout(r, 100)); if (server.exitCode == null) server.kill("SIGKILL"); }
  }
}

main().catch((e) => { console.error(`pcb_editor_perf: FAIL: ${e.stack || e}`); process.exit(1); });
