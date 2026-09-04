#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const {
  routes, surfaces, responseScenarios, pcbToolstripControls, pcbPrimaryControls,
} = require("./manifest");

const root = path.resolve(__dirname, "..", "..");
const serveSource = fs.readFileSync(path.join(root, "src", "serve.zig"), "utf8");

// Extraction IS the contract. `/systems/:name` shipped uncovered while this
// file already required every route to be classified, so the lesson is not
// "match more shapes" — it is that a registration this file cannot see is
// indistinguishable from one that does not exist. Everything below therefore
// proves the absence of unreadable shapes before reading the readable ones.

// 1. Every router.get() in serve.zig must pass a plain string literal. A path
//    built from a constant or a concatenation would parse to nothing here and
//    land outside the gate in silence.
const getCalls = Array.from(serveSource.matchAll(/router\.get\(([\s\S]{0,200}?),/g), (match) => match[1].trim());
assert.deepStrictEqual(getCalls.filter((argument) => !/^"[^"\\]*"$/.test(argument)), [],
  "every router.get() path in src/serve.zig must be a plain string literal this contract can read");

// 2. httpz can register a GET page through verbs this file does not read —
//    `all`, `head`, `method`, or a `group(...)` whose own `.get` calls are
//    invisible to the scan above. None exist today; if one lands, extend the
//    extraction deliberately rather than let it register an unclassified page.
const unreadVerbs = [...new Set(Array.from(serveSource.matchAll(/\brouter\.(all|head|method|group)\(/g), (match) => match[1]))].sort();
assert.deepStrictEqual(unreadVerbs, [],
  "src/serve.zig registers routes through a verb this contract cannot read; teach the extraction about it");

// 3. serve.zig is the only router. A `router.get(` anywhere else registers
//    pages this file never reads.
const strayRouters = [];
(function scan(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const target = path.join(dir, entry.name);
    if (entry.isDirectory()) scan(target);
    else if (entry.name.endsWith(".zig") && target !== path.join(root, "src", "serve.zig")) {
      // Requiring an unescaped quote is what keeps src/serve/pages.zig out:
      // its `router.get(\\"…` is a Zig string literal in a test asserting on
      // serve.zig's own source, and the backslash makes it not match.
      if (/router\.get\(\s*"/.test(fs.readFileSync(target, "utf8"))) strayRouters.push(path.relative(root, target));
    }
  }
})(path.join(root, "src"));
assert.deepStrictEqual(strayRouters.sort(), [],
  "routes must be registered in src/serve.zig, which is the only file this contract reads");

// A server lifecycle test owns a private `GET /` router too. Route coverage is
// about the unique production surface, not how often a literal occurs in this
// source file.
const registered = [...new Set(getCalls.map((argument) => argument.slice(1, -1))
  .filter((route) => !route.startsWith("/api/")))].sort();
assert.deepStrictEqual(Object.keys(routes).sort(), registered,
  "manifest.js must classify every non-API GET route in src/serve.zig");

const ids = new Set();
const actionKeys = new Set();
for (const surface of surfaces) {
  assert.match(surface.id, /^[a-z0-9_]+$/);
  assert(!ids.has(surface.id), `duplicate surface ${surface.id}`);
  ids.add(surface.id);
  assert(surface.path.startsWith("/"), `${surface.id} needs an absolute route`);
  assert(surface.ready, `${surface.id} needs an app-ready selector`);
  assert(surface.scenarios.length > 0, `${surface.id} needs normal interaction scenarios`);
  const scenarioIds = new Set(surface.scenarios.map((scenario) => scenario.id));
  const scenariosById = new Map(surface.scenarios.map((scenario) => [scenario.id, scenario]));
  const scenarioOrder = new Map(surface.scenarios.map((scenario, index) => [scenario.id, index]));
  for (const scenario of surface.scenarios) {
    assert(["local", "async", "frame"].includes(scenario.kind),
      `${surface.id}.${scenario.id} has unknown kind ${scenario.kind}`);
    const key = `${surface.id}.${scenario.id}`;
    assert(!actionKeys.has(key), `duplicate scenario ${key}`);
    actionKeys.add(key);
    for (const setup of scenario.setup || []) {
      assert(scenarioIds.has(setup), `${key} names missing focused setup ${setup}`);
      assert(setup !== scenario.id, `${key} cannot set itself up`);
    }
    for (const label of scenario.privateMutations || []) {
      assert.match(label, /^POST \/api\/[a-z0-9_3d/-]+$/i, `${key} private mutation must name one exact POST path`);
    }
    for (const label of scenario.requiredPrivateMutations || []) {
      assert((scenario.privateMutations || []).includes(label), `${key} required private mutation ${label} is not allowlisted`);
    }
  }

  const visitState = new Map();
  const setupPath = [];
  function visitSetups(scenario) {
    const state = visitState.get(scenario.id);
    if (state === "done") return;
    if (state === "visiting") {
      const cycleStart = setupPath.indexOf(scenario.id);
      const cycle = [...setupPath.slice(cycleStart), scenario.id].join(" -> ");
      assert.fail(`${surface.id} has a cyclic focused setup dependency: ${cycle}`);
    }
    visitState.set(scenario.id, "visiting");
    setupPath.push(scenario.id);
    for (const setupId of scenario.setup || []) visitSetups(scenariosById.get(setupId));
    setupPath.pop();
    visitState.set(scenario.id, "done");
  }
  for (const scenario of surface.scenarios) visitSetups(scenario);

  for (const scenario of surface.scenarios) {
    for (const setupId of scenario.setup || []) {
      assert(scenarioOrder.get(setupId) < scenarioOrder.get(scenario.id),
        `${surface.id}.${scenario.id} focused setup ${setupId} must precede it for full-matrix runs`);
    }
  }
}

const home = surfaces.find((surface) => surface.id === "home");
assert.strictEqual(home.scenarios.at(-1)?.id, "progress_hydration",
  "home progress hydration must run last so its background requests drain before context teardown");

const pcb = surfaces.find((surface) => surface.id === "pcb_2d");
const pcbScenarioIds = new Set(pcb.scenarios.map((scenario) => scenario.id));
const pcbPageSource = fs.readFileSync(path.join(root, "src", "serve", "pcb_layout_page.zig"), "utf8");
const pcbBoardSource = fs.readFileSync(path.join(root, "src", "serve", "assets", "pcb_board.js"), "utf8");
const toolstripBlock = pcbPageSource.slice(
  pcbPageSource.indexOf("const toolstrip_html ="),
  pcbPageSource.indexOf("const mobile_view_tools_html"),
);
assert(toolstripBlock.length > 0, "PCB toolstrip source block is missing");
const sourceToolstripIds = Array.from(toolstripBlock.matchAll(/<button[^>]*id=\\\"([^\"]+)\\\"/g), (match) => match[1]);
const padAlignSource = fs.readFileSync(path.join(root, "src", "serve", "assets", "pcb_pad_align_tool.html"), "utf8");
sourceToolstripIds.push(...Array.from(padAlignSource.matchAll(/id="([^"]+)"/g), (match) => match[1]));
assert.deepStrictEqual(Object.keys(pcbToolstripControls).sort(), sourceToolstripIds.sort(),
  "PCB toolstrip source IDs and the reviewed primary-control inventory must stay in exact lockstep");
for (const [controlId, coverage] of Object.entries(pcbToolstripControls)) {
  assert(Boolean(coverage.scenario) !== Boolean(coverage.excluded),
    `PCB toolstrip control ${controlId} needs exactly one scenario or exclusion`);
  if (coverage.scenario) assert(pcbScenarioIds.has(coverage.scenario),
    `PCB toolstrip control ${controlId} names missing scenario ${coverage.scenario}`);
  if (coverage.excluded) assert(coverage.excluded.length >= 40,
    `PCB toolstrip control ${controlId} needs a concrete exclusion`);
}
for (const [controlId, coverage] of Object.entries(pcbPrimaryControls)) {
  assert(coverage.scenarios?.length > 0, `PCB primary control ${controlId} needs scenario coverage`);
  for (const scenario of coverage.scenarios) assert(pcbScenarioIds.has(scenario),
    `PCB primary control ${controlId} names missing scenario ${scenario}`);
  const source = fs.readFileSync(path.join(root, coverage.source), "utf8");
  assert(source.includes(`id=\\"${controlId}\\"`) || source.includes(`id="${controlId}"`) ||
    source.includes(`getElementById("${controlId}")`),
  `PCB primary control ${controlId} is absent from ${coverage.source}`);
}

function routeMatches(template, actual) {
  const expected = template.split("/");
  const got = new URL(actual, "http://127.0.0.1").pathname.split("/");
  return expected.length === got.length && expected.every((segment, i) => segment.startsWith(":") ? got[i].length > 0 : segment === got[i]);
}

// `uncovered` is deliberately last and deliberately loud: it is the only kind
// that admits a route has NO browser-perf coverage. It exists because the
// alternative on the day a route lands uncovered is worse — either a false
// classification ("asset" for an interactive page) or invented scenarios that
// put meaningless numbers in the gate. Every uncovered route is printed on a
// PASSING run, so it cannot go quiet the way an unclassified route did.
const coverageKinds = new Set(["surface", "surfaces", "delegated", "redirect", "response", "asset", "metadata", "uncovered"]);
const gate = fs.readFileSync(path.join(root, "scripts", "perf_gate.sh"), "utf8");
for (const [route, record] of Object.entries(routes)) {
  assert(coverageKinds.has(record.coverage), `${route} has unknown coverage ${record.coverage}`);
  if (record.coverage === "surface") {
    assert(ids.has(record.surface), `${route} names missing surface ${record.surface}`);
    const surface = surfaces.find((item) => item.id === record.surface);
    assert(routeMatches(route, surface.path), `${surface.id} path ${surface.path} does not exercise ${route}`);
  }
  if (record.coverage === "surfaces") for (const id of record.surfaces) {
    assert(ids.has(id), `${route} names missing surface ${id}`);
    const surface = surfaces.find((item) => item.id === id);
    assert(routeMatches(route, surface.path), `${surface.id} path ${surface.path} does not exercise ${route}`);
  }
  if (["redirect", "response"].includes(record.coverage)) {
    const responseScenario = responseScenarios.find((scenario) => scenario.id === record.scenario);
    assert(responseScenario, `${route} names missing response scenario`);
    assert(routeMatches(route, responseScenario.path),
      `${route} response scenario ${record.scenario} exercises unrelated path ${responseScenario.path}`);
  }
  if (record.coverage === "delegated") {
    assert(record.runner, `${route} needs its delegated runner`);
    assert(record.scenarios && record.scenarios.length > 0, `${route} needs its delegated normal interactions`);
    const delegatedPath = path.join(root, record.runner);
    assert(fs.existsSync(delegatedPath), `${route} delegated runner ${record.runner} does not exist`);
    assert(gate.includes(`node ${record.runner}`), `${route} delegated runner is not invoked by perf_gate.sh`);
    const delegatedSource = fs.readFileSync(delegatedPath, "utf8");
    const scenarioLiteral = delegatedSource.match(/const COVERED_SCENARIOS = Object\.freeze\((\[[\s\S]*?\])\);/);
    assert(scenarioLiteral, `${record.runner} must declare COVERED_SCENARIOS`);
    assert.deepStrictEqual(JSON.parse(scenarioLiteral[1]), record.scenarios, `${route} delegated scenarios drifted from its runner`);
    const controlsLiteral = delegatedSource.match(/const PRIMARY_CONTROLS = Object\.freeze\((\{[\s\S]*?\})\);/);
    const nonControlsLiteral = delegatedSource.match(/const NON_CONTROL_SCENARIOS = Object\.freeze\((\[[\s\S]*?\])\);/);
    assert(controlsLiteral && nonControlsLiteral,
      `${record.runner} must declare its primary-control and non-control scenario inventories`);
    const primaryControls = JSON.parse(controlsLiteral[1]);
    const nonControlScenarios = JSON.parse(nonControlsLiteral[1]);
    for (const [scenario, control] of Object.entries(primaryControls)) {
      assert(control && typeof control.selector === "string" && control.selector.length > 0,
        `${record.runner} primary control ${scenario} needs a locator`);
      if (control.excluded) assert(typeof control.excluded === "string" && control.excluded.length >= 20,
        `${record.runner} excluded primary control ${scenario} needs a concrete safety reason`);
    }
    const mappedScenarios = Object.entries(primaryControls)
      .filter(([, control]) => !control.excluded)
      .map(([scenario]) => scenario);
    assert.deepStrictEqual([...nonControlScenarios, ...mappedScenarios].sort(), [...record.scenarios].sort(),
      `${route} delegated scenarios must exactly cover its measured primary controls plus renderer phases`);
    assert(primaryControls.load_3d_models?.excluded && mappedScenarios.includes("model_3d_navigation"),
      `${record.runner} must explain the sprite-writing model toggle and exercise safe 3D navigation instead`);
    assert(delegatedSource.includes('usage("--url is restricted to a loopback HTTP(S) server")'),
      `${record.runner} must reject non-loopback existing servers`);
    assert(delegatedSource.includes('usage("--record cannot be combined with --url")'),
      `${record.runner} must not record a baseline against an unrelated existing server`);
    assert(delegatedSource.includes('await context.route("**/*"'),
      `${record.runner} must interpose on browser requests`);
    for (const audit of ["blocked_mutations", "blocked_external", "first-party request failures"]) {
      assert(delegatedSource.includes(audit), `${record.runner} is missing its ${audit} network audit`);
    }
    assert(delegatedSource.includes('fs.rmSync(overlay, { recursive: true, force: true })'),
      `${record.runner} must remove a partially constructed project overlay`);
  }
  if (["asset", "metadata"].includes(record.coverage)) assert(record.reason, `${route} needs an explicit non-page reason`);
  if (record.coverage === "uncovered") {
    assert(record.reason, `${route} needs an explicit reason for having no coverage`);
    // Long enough to be an account rather than a shrug: who owns it and why it
    // is not covered yet, so the entry can be acted on rather than inherited.
    assert(record.reason.length >= 80, `${route} needs a real account of the gap, not a placeholder`);
  }
}

const uncovered = Object.entries(routes).filter(([, record]) => record.coverage === "uncovered");
if (uncovered.length > 0) {
  console.log(`ui-browser-perf: ${uncovered.length} route(s) have NO browser-perf coverage:`);
  for (const [route, record] of uncovered) console.log(`  ${route} — ${record.reason}`);
}

const runner = fs.readFileSync(path.join(__dirname, "run.js"), "utf8");
const implemented = new Set(Array.from(runner.matchAll(/^\s+"([a-z0-9_]+\.[a-z0-9_]+)": async/gm), (match) => match[1]));
assert.deepStrictEqual(Array.from(implemented).sort(), Array.from(actionKeys).sort(),
  "run.js action table and manifest scenarios must stay in exact lockstep");
const baseline = JSON.parse(fs.readFileSync(path.join(root, "docs", "benchmarks", "ui-browser", "baseline.json"), "utf8"));
for (const surface of surfaces) for (const scenario of surface.scenarios) {
  const prefix = `surfaces.${surface.id}.actions.${scenario.id}`;
  const p95Metric = `${prefix}.${scenario.kind === "frame" ? "worst_p95_ms" : "p95_ms"}`;
  const maxMetric = `${prefix}.max_ms`;
  assert(Object.prototype.hasOwnProperty.call(baseline.budgets, p95Metric), `${p95Metric} needs a committed budget`);
  assert(Object.prototype.hasOwnProperty.call(baseline.budgets, maxMetric), `${maxMetric} needs a committed budget`);
  if (scenario.budgets) {
    assert.strictEqual(baseline.budgets[p95Metric], scenario.budgets.p95_ms,
      `${p95Metric} drifted from its reviewed manifest limit`);
    assert.strictEqual(baseline.budgets[maxMetric], scenario.budgets.max_ms,
      `${maxMetric} drifted from its reviewed manifest limit`);
  }
}
assert(runner.includes('#page-4[data-render-complete="true"]'),
  "PDF lazy-scroll timing must wait for the viewer's post-raster/text completion marker");
assert(runner.includes('body[data-pdf-ready="true"] #status.hidden'),
  "PDF navigation readiness must wait for the completed initial page/highlight positioning");
assert(runner.includes('detail.querySelector("#erc-rerun")') && runner.includes('message.startsWith("Error:")'),
  "ERC timing must wait past the synchronous Running placeholder for final results or error feedback");
assert(runner.includes('painted?.ambient === 26 && painted.revision > revision') &&
  runner.includes('url.pathname.startsWith("/api/thermal-field/")') &&
  runner.includes('url.searchParams.get("fragment") === "1"'),
  "thermal ambient timing must include the fragment response and the matching iframe field paint");
assert(runner.includes('painted?.scenario === "airflow_1ms" && painted.revision > revision') &&
  runner.includes('url.searchParams.get("scenario") === "airflow_1ms"') &&
  runner.includes('document.querySelector("#tp-heat-loading")?.hidden === true'),
  "thermal scenario timing must await its successful field response, cleared veil, and matching paint");
assert(pcbBoardSource.includes("var deferredAnalysisSeq=0") &&
  pcbBoardSource.includes("if(run===deferredAnalysisSeq&&PCB.analysis_deferred)loadDeferredAnalysis()"),
  "a save that stales deferred PCB analysis must re-arm exactly one fresh generation");
assert(runner.includes('painted?.side === "bottom" && painted.revision > revision'),
  "thermal face timing must include the iframe's applied and painted side change");
assert(runner.includes('canvas.width / canvas.clientWidth >= Math.min(window.devicePixelRatio || 1, 1) - 0.01'),
  "PCB 3D gestures must prove software rendering restores settled CSS-pixel quality");
assert(runner.includes('failUsage("--url requires --surface or --scenario")'),
  "an existing-server UI run must be focused and cannot record a complete baseline");
assert(runner.includes('fs.rmSync(overlay, { recursive: true, force: true })'),
  "the UI runner must remove a partially constructed project overlay");
assert(runner.includes("window.__uiPerfLongTasks.unshift(...durations)"),
  "full-navigation PCB layout loads must preserve earlier surface long tasks");
assert(runner.includes("original PCB layout was not restored in active label") &&
  runner.includes('page.locator("#pcb-lay-select").waitFor({ state: "visible"') && runner.includes('[data-sidetab="side-route"]'),
  "PCB layout load must reveal its normal control and restore the reviewed opening layout");
assert(pcbBoardSource.includes("window.PCBViaLegalCandidate=function(clientX,clientY,net)") &&
  pcbBoardSource.includes("viaViolation(q.x,q.y,net,vg.dia,vg.drill)") &&
  runner.includes("window.PCBViaLegalCandidate(x, y, net)") && runner.includes("await afterFrames(page, 1)"),
  "standalone-via setup must find a legal point with editor predicates and yield between scan rows");
assert(runner.includes("env.privateOverlay && env.activePrivateMutations.has(label)") &&
  runner.includes("privateMutationCheckpoint(overlay)") && runner.includes("restorePrivateMutationCheckpoint(mutationCheckpoint)"),
  "successful writes must be scoped to an active scenario in an owned, reset-between-reps overlay");
assert(runner.includes('entry === "src" || entry === "history"') && runner.includes('modelEntry === "model-config.json"') &&
  runner.includes("fs.copyFileSync("),
  "the private overlay must copy every small writable save target rather than expose it through a live symlink");
assert(runner.includes('document.querySelector("#pcb-savemsg")?.textContent === "updated ✓"') &&
  runner.includes('document.querySelector("#save-state")?.textContent === "saved ✓"'),
  "save timings must wait for successful user-visible completion in private runs");
assert(runner.includes("Restore the opening transform through the same private API outside the") &&
  runner.includes("window.__uiPerfOriginalModelTransform"),
  "model-save repetitions must restore the opening transform through the private endpoint");
assert(/const context = await browser\.newContext\([^\n]+\);\n  try \{\n    return await runSurfaceInContext/.test(runner),
  "the UI browser context cleanup must cover route and page initialization failures");

const fixture = path.join(root, "test", "fixtures", "browser_perf", "route-review.kicad_pcb");
assert(fs.existsSync(fixture), "the real route-review interaction needs its tracked tiny KiCad fixture");
const pdfFixture = path.join(root, "test", "fixtures", "browser_perf", "datasheet.pdf");
assert(fs.existsSync(pdfFixture), "the PDF viewer needs its tracked hermetic datasheet fixture");
const pdfBytes = fs.readFileSync(pdfFixture);
assert.strictEqual(pdfBytes.subarray(0, 5).toString(), "%PDF-", "datasheet fixture must be a PDF");
assert(pdfBytes.includes(Buffer.from("/Count 4")), "PDF lazy-render coverage needs four pages outside the preload margin");
const pdfGenerator = require(path.join(root, "test", "fixtures", "browser_perf", "generate_datasheet.js"));
assert(pdfBytes.includes(Buffer.from(pdfGenerator.WORKLOAD_MARKER)),
  "PDF fixture must retain the reviewed dense text/table/vector/image workload marker");
const generatedPdf = pdfGenerator.buildPdf();
assert.strictEqual(pdfBytes.length, generatedPdf.length,
  "PDF fixture must be regenerated from generate_datasheet.js");
assert.deepStrictEqual(pdfBytes, generatedPdf,
  "PDF fixture bytes drifted from their deterministic copyright-clean generator");
assert.strictEqual(require("crypto").createHash("sha256").update(pdfBytes).digest("hex"),
  "0d58f1ce70dc53a40c6cd872f7ea1f20a1d1bffa1136cdd4efd1f1dcb857a75b",
  "PDF fixture workload digest changed; review the generated rendering work before accepting it");
assert((gate.match(/node scripts\/ui_browser_perf\/run\.js/g) || []).length >= 2,
  "perf_gate.sh must run the all-pages matrix in both record and enforce modes");
assert((gate.match(/node scripts\/pcb_editor_perf\/run\.js/g) || []).length >= 2,
  "perf_gate.sh must run deterministic PCB editor zoom in both record and enforce modes");
assert(gate.includes("archive --format=tar") && gate.includes("NETLISP_PERF_DESIGNS_COMMIT"),
  "perf_gate.sh must measure a clean, identified designs HEAD snapshot");
assert(gate.includes("*.layouts.json") && gate.includes("layouts_fingerprint") && gate.includes("--reflink=auto") &&
  gate.includes("*.bom") && gate.includes("boms_fingerprint"),
  "perf_gate.sh must copy and identify ignored layout/model/BOM workload inputs");
assert((gate.match(/node scripts\/perf_gate_designs_identity\.js/g) || []).length >= 2,
  "perf_gate.sh must stamp the recorded page baseline's workload identity and verify it before enforcing");
assert(!gate.includes('ln -s "$source_project_dir/lib/models"'),
  "perf_gate.sh must never expose the live model bundle to benchmark writes");
// Standalone timing runs corrupted gated ones until the runners queued
// themselves (FEEDBACK.md 2026-08-29): every browser runner must re-exec
// under scripts/gate.sh's machine-wide lock when it does not already hold it,
// and a bench-page recording labelled contended must never become a baseline.
for (const perfRunner of ["scripts/pcb_browser_perf/run.js", "scripts/pcb_editor_perf/run.js", "scripts/ui_browser_perf/run.js"]) {
  const runnerSource = fs.readFileSync(path.join(root, perfRunner), "utf8");
  assert(runnerSource.includes('require("../perf_gate_lock")') && runnerSource.includes("ensureGateLock("),
    `${perfRunner} must queue standalone timing runs under scripts/gate.sh's machine-wide lock`);
}
// A benchmark server must be incapable of committing to the designs repository.
// config.zig's gitAutocommitEnabled() defaults to ENABLED when the variable is
// unset — only production is protected, by its systemd unit — and the
// system-review document save / attest / asset-upload endpoints call
// autocommit.begin() unconditionally. Two independent guards, either of which
// alone is sufficient:
//
//   1. Every spawned server gets NETLISP_GIT_AUTOCOMMIT=0. Checked against
//      EVERY `env: { ...process.env` literal, so a newly added spawn that
//      forgets the variable trips this too.
//   2. projectOverlay() never links .git. Git resolves the symlink, so an
//      overlay carrying one is a work tree of the real designs repo reporting
//      the overlay as its toplevel — `git add -A` + commit would land a commit
//      in the user's repository from a temporary copy of the tree.
//
// pcb_editor_perf has no overlay at all: it serves the real designs checkout,
// so for that runner guard 1 is the only thing standing between a benchmark
// write and the user's history.
const benchGitGuards = [
  {
    id: "bench-autocommit-disabled",
    // Applies to every runner, including pcb_editor_perf, which has no overlay
    // and serves the real checkout directly.
    check(runnerSource, perfRunner, fail) {
      const envLiterals = Array.from(runnerSource.matchAll(/env:\s*\{[^}]*\.\.\.process\.env[^}]*\}/g), (match) => match[0]);
      if (!envLiterals.length) fail(`${perfRunner} must spawn its server with an explicit env`);
      for (const literal of envLiterals) {
        if (!/NETLISP_GIT_AUTOCOMMIT:\s*"0"/.test(literal)) {
          fail(`${perfRunner} must spawn its server with NETLISP_GIT_AUTOCOMMIT="0" — auto-commit defaults to ENABLED when unset, so a benchmark write would commit to the designs repository`);
        }
      }
    },
  },
  {
    id: "bench-overlay-not-a-git-repo",
    // Only the two runners that build an overlay.
    check(runnerSource, perfRunner, fail) {
      const start = runnerSource.indexOf("function projectOverlay(");
      if (start === -1) return;
      const body = runnerSource.slice(start, runnerSource.indexOf("\n}", start));
      if (!/entry === "\.git"\) continue;/.test(body)) {
        fail(`${perfRunner} projectOverlay() must skip .git — a linked .git makes the overlay a work tree of the real designs repository`);
      }
      if (/symlinkSync\([^\n]*"\.git"/.test(body)) {
        fail(`${perfRunner} projectOverlay() must never symlink .git into the overlay`);
      }
    },
  },
];
for (const perfRunner of ["scripts/pcb_browser_perf/run.js", "scripts/pcb_editor_perf/run.js", "scripts/ui_browser_perf/run.js"]) {
  const runnerSource = fs.readFileSync(path.join(root, perfRunner), "utf8");
  for (const guard of benchGitGuards) {
    guard.check(runnerSource, perfRunner, (message) => assert.fail(`[${guard.id}] ${message}`));
  }
}
const gateLock = fs.readFileSync(path.join(root, "scripts", "perf_gate_lock.js"), "utf8");
assert(gateLock.includes("NETLISP_GATE_HELD") && gateLock.includes("NETLISP_GATE_SERIALIZE"),
  "perf_gate_lock.js must honor gate.sh's recursion guard and its explicit bypass");
assert(gate.includes(".load?.contended"),
  "perf_gate.sh --record must refuse to install a bench-page recording labelled contended");
const packageJson = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
assert.strictEqual(packageJson.scripts["perf:ui"], "node scripts/ui_browser_perf/run.js");
assert.strictEqual(packageJson.scripts["perf:pcb-editor"], "node scripts/pcb_editor_perf/run.js");
const editorBaseline = JSON.parse(fs.readFileSync(path.join(root, "docs", "benchmarks", "pcb-editor", "baseline.json"), "utf8"));
assert(editorBaseline.budgets["canvas.zoom_in.worst_p95_ms"] <= 45 &&
  editorBaseline.budgets["canvas.zoom_out.worst_p95_ms"] <= 45,
  "the DPR-2 editor fallback needs reviewed in/out frame budgets");
const prepareRelease = fs.readFileSync(path.join(root, ".githooks", "prepare-release.sh"), "utf8");
const deployProd = fs.readFileSync(path.join(root, ".githooks", "deploy-prod.sh"), "utf8");
assert(prepareRelease.includes("scripts/pcb_editor_perf/run.js") && prepareRelease.includes("pcb_editor_perf=passed"),
  "release preparation must run and certify the PCB editor zoom gate");
assert(prepareRelease.includes("scripts/perf_host_idle.js") && prepareRelease.includes("NETLISP_EDITOR_PERF_ATTEMPTS") &&
  prepareRelease.includes("PCB editor zoom regression:"),
  "release preparation must wait for a quiet host and retry timing-only editor failures");
assert(deployProd.includes("pcb_editor_perf=passed"),
  "deployment must reject a candidate that lacks PCB editor performance certification");
const prePush = fs.readFileSync(path.join(root, ".githooks", "pre-push"), "utf8");
assert(prePush.includes("git-common-dir") && prePush.includes("bash scripts/perf_gate.sh"),
  "linked-worktree pushes must resolve the shared designs checkout and invoke the full gate");
assert(prePush.includes('head_sha') && prePush.includes('pushed_main_sha') && prePush.includes('git status --porcelain'),
  "main pre-push must measure the exact clean commit being pushed");

console.log(`ui_browser_perf_manifest: PASS ${registered.length} routes, ${surfaces.length} surfaces, ${actionKeys.size} interactions`);
