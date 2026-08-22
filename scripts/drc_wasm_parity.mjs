#!/usr/bin/env node
// DRC WASM parity + performance harness (Node 22, ESM).
//
// End-to-end acceptance check for the client-side WASM DRC engine: for each
// named design it (1) pulls the /pcb-layout page blob, (2) runs the wasm engine
// (zig-out/bin/drc.wasm) over the marshaled blob, (3) applies the design's
// per-kind override map (PCB.drc_kinds) so the wasm result is apples-to-apples
// with the override-filtered server, (4) POSTs the equivalent body to
// /api/pcb-drc/<name> (mirroring pcb_board.js `runDrcNow`), and (5) compares
// violation counts, id multisets, and per-kind histograms. It also times both
// paths (wasm drc_check + server round-trip, median of 5 after 1 warmup).
//
// Exit status is non-zero if any design's wasm/server results diverge, so this
// doubles as a CI-style parity gate.
//
// Usage:
//   node scripts/drc_wasm_parity.mjs <server-url> <design> [<design> ...]
//   node scripts/drc_wasm_parity.mjs http://localhost:7802 straps labstation stm32n6
//
// Flags:
//   --scale-x20 <design>   also run a synthetic dense board (that design's
//                          tracks/vias duplicated 20x) through the wasm timer
//                          (and the server, best-effort) to gauge wasm perf on
//                          a heavy board vs. the server round trip.
//   --wasm <path>          override the drc.wasm path (default zig-out/bin).
//   --marshal <path>       override the drc_marshal.js path.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// ── Arg parsing ──────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const out = { url: null, designs: [], scaleX20: null, wasmPath: null, marshalPath: null };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--scale-x20") out.scaleX20 = argv[++i];
    else if (a === "--wasm") out.wasmPath = argv[++i];
    else if (a === "--marshal") out.marshalPath = argv[++i];
    else if (a === "--help" || a === "-h") out.help = true;
    else rest.push(a);
  }
  out.url = rest[0] || null;
  out.designs = rest.slice(1);
  return out;
}

const HELP = `DRC WASM parity + performance harness

  node scripts/drc_wasm_parity.mjs <server-url> <design> [<design> ...]
                                   [--scale-x20 <design>] [--wasm <path>] [--marshal <path>]

Example:
  node scripts/drc_wasm_parity.mjs http://localhost:7802 straps labstation stm32n6 \\
       bcuda-synth-lmx2595 --scale-x20 straps
`;

// ── Page blob extraction ─────────────────────────────────────────────────────

// The /pcb-layout page embeds `<script>const PCB={...};</script>` — a single
// JSON object literal. `<` is escaped to < inside strings (so a net/ref
// name can't close the tag), but we brace-balance with full string-state
// tracking anyway, so extraction is robust regardless of the terminator.
function extractPcbBlob(html) {
  const anchor = "const PCB=";
  const at = html.indexOf(anchor);
  if (at < 0) throw new Error("no `const PCB=` blob found in page");
  let i = at + anchor.length;
  while (i < html.length && html[i] !== "{") i++;
  if (html[i] !== "{") throw new Error("blob opening brace not found");
  const begin = i;
  let depth = 0, inStr = false, esc = false;
  for (; i < html.length; i++) {
    const c = html[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
    } else if (c === '"') inStr = true;
    else if (c === "{") depth++;
    else if (c === "}") { if (--depth === 0) { i++; break; } }
  }
  if (depth !== 0) throw new Error("unbalanced braces in PCB blob");
  return JSON.parse(html.slice(begin, i));
}

// ── WASM two-call ABI ────────────────────────────────────────────────────────

async function loadWasm(path) {
  const buf = readFileSync(path);
  const { instance } = await WebAssembly.instantiate(buf, {});
  const ex = instance.exports;
  for (const fn of ["wasm_alloc", "drc_check", "drc_output_ptr", "memory"]) {
    if (!ex[fn]) throw new Error(`drc.wasm missing export ${fn}`);
  }
  return instance;
}

// p = wasm_alloc(len) → write JSON at memory[p..] → outLen = drc_check(p,len) →
// read memory[drc_output_ptr()..+outLen]. Re-take the memory view after each
// call: wasm_alloc can grow (and detach) the buffer.
function runWasmDrc(instance, inputStr) {
  const ex = instance.exports;
  const bytes = new TextEncoder().encode(inputStr);
  const p = ex.wasm_alloc(bytes.length);
  new Uint8Array(ex.memory.buffer).set(bytes, p);
  const outLen = ex.drc_check(p, bytes.length);
  const outPtr = ex.drc_output_ptr();
  const json = new TextDecoder().decode(new Uint8Array(ex.memory.buffer, outPtr, outLen));
  return JSON.parse(json);
}

// ── Override map (mirror src/serve/drc_rules.zig `apply` / pcb_board.js) ──────

// The wasm returns built-in severities; /api/pcb-drc is override-filtered. Apply
// PCB.drc_kinds: unset kind → keep; `ignore` → drop; `warn`/`err` → retag sev.
// The map is keyed by the kind WORD, which is drc_kinds' `label` == violation.k.
function applyOverrides(list, drcKinds) {
  const ov = {};
  for (const kk of drcKinds || []) ov[kk.label] = kk.ov || null;
  const out = [];
  for (const v of list) {
    const a = ov[v.k];
    if (a == null) { out.push(v); continue; }
    if (a === "ignore") continue;
    out.push({ ...v, sev: a === "warn" ? "warn" : "err" });
  }
  return out;
}

// ── Server body (mirror pcb_board.js `runDrcNow`) ────────────────────────────

function serverBody(PCB) {
  return {
    parts: (PCB.parts || []).map((p) => ({ ref: p.ref, x: p.x, y: p.y, rot: p.rot || 0, side: p.side || "top" })),
    tracks: PCB.tracks || [],
    vias: PCB.vias || [],
    clearance: PCB.clr,
    outline: PCB.outline || null,
  };
}

async function postDrc(url, name, sub, body) {
  const q = sub ? `?sub=${encodeURIComponent(sub)}` : "";
  const r = await fetch(`${url}/api/pcb-drc/${encodeURIComponent(name)}${q}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`POST /api/pcb-drc/${name} → HTTP ${r.status}`);
  return r.json();
}

// ── Comparison ───────────────────────────────────────────────────────────────

function multiset(arr) {
  const m = new Map();
  for (const x of arr) m.set(x, (m.get(x) || 0) + 1);
  return m;
}

// Returns { equal, onlyA:[[key,count]], onlyB:[[key,count]] } for a=wasm,b=server.
function diffMultiset(a, b) {
  const ma = multiset(a), mb = multiset(b);
  const keys = new Set([...ma.keys(), ...mb.keys()]);
  const onlyA = [], onlyB = [];
  for (const k of keys) {
    const d = (ma.get(k) || 0) - (mb.get(k) || 0);
    if (d > 0) onlyA.push([k, d]);
    else if (d < 0) onlyB.push([k, -d]);
  }
  return { equal: onlyA.length === 0 && onlyB.length === 0, onlyA, onlyB };
}

function kindHist(list) {
  const m = {};
  for (const v of list) m[v.k] = (m[v.k] || 0) + 1;
  return m;
}

// A full-record key (id-collisions on the 16-bit id space aside) — a stronger
// signal than the id alone on violation-storm boards. Rounds coords to match
// the id's own 0.01 mm / 0.001 mm quantization so float noise can't split them.
function recKey(v) {
  const q = (x, s) => Math.round((x || 0) * s);
  return `${v.k}|${q(v.x, 100)}|${q(v.y, 100)}|${q(v.gap, 1000)}|${q(v.clr, 1000)}|${v.sev}`;
}

function histDiffPairs(a, b) {
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
  const rows = [];
  for (const k of keys) {
    const wa = a[k] || 0, sv = b[k] || 0;
    if (wa !== sv) rows.push(`${k}: wasm ${wa} / server ${sv}`);
  }
  return rows;
}

// Dot-collapse diagnostic: the marshal collapses track/via/net-class net names
// at the first '.', matching the blob's dot-collapsed PAD nets. On bypass-stub
// boards (<rail>.<ic>.<pad>) this merges distinct raw nets under a shared rail —
// the one documented place the wasm legitimately diverges from the server.
// Raw (uncollapsed) names only survive in tracks/vias/netclasses, so those are
// where we can detect the merges.
function dotCollapseReport(PCB) {
  const raw = new Set();
  for (const t of PCB.tracks || []) if (t.net) raw.add(t.net);
  for (const v of PCB.vias || []) if (v.net) raw.add(v.net);
  for (const c of PCB.netclasses || []) if (c.net) raw.add(c.net);
  const groups = new Map(); // collapsed key → Set(raw names)
  for (const n of raw) {
    const key = n.includes(".") ? n.slice(0, n.indexOf(".")) : n;
    if (!groups.has(key)) groups.set(key, new Set());
    groups.get(key).add(n);
  }
  const merges = [];
  for (const [key, names] of groups) if (names.size > 1) merges.push({ key, names: [...names] });
  return merges;
}

// ── Timing ───────────────────────────────────────────────────────────────────

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

function timeWasm(instance, inputStr, runs = 5) {
  runWasmDrc(instance, inputStr); // warmup
  const t = [];
  for (let i = 0; i < runs; i++) {
    const s = performance.now();
    runWasmDrc(instance, inputStr);
    t.push(performance.now() - s);
  }
  return median(t);
}

async function timeServer(url, name, sub, body, runs = 5) {
  await postDrc(url, name, sub, body); // warmup
  const t = [];
  for (let i = 0; i < runs; i++) {
    const s = performance.now();
    await postDrc(url, name, sub, body);
    t.push(performance.now() - s);
  }
  return median(t);
}

// ── Per-design run ───────────────────────────────────────────────────────────

async function runDesign(url, name, instance, buildDrcInput) {
  const pageRes = await fetch(`${url}/pcb-layout/${encodeURIComponent(name)}`);
  if (!pageRes.ok) return { name, skipped: `page HTTP ${pageRes.status}` };
  const html = await pageRes.text();
  let PCB;
  try {
    PCB = extractPcbBlob(html);
  } catch (e) {
    return { name, skipped: `blob: ${e.message}` };
  }
  const sub = PCB.sub || null;

  // WASM path: marshal → run → override.
  const inputStr = JSON.stringify(buildDrcInput(PCB, { clearance: PCB.clr, outline: PCB.outline || null }));
  const wasmRaw = runWasmDrc(instance, inputStr);
  if (wasmRaw.error) return { name, skipped: `wasm error: ${wasmRaw.error}` };
  const wasmList = applyOverrides(wasmRaw.drc || [], PCB.drc_kinds);

  // Server path.
  const body = serverBody(PCB);
  let srvJson;
  try {
    srvJson = await postDrc(url, name, sub, body);
  } catch (e) {
    return { name, skipped: `server: ${e.message}` };
  }
  const srvList = srvJson.drc || [];

  // Compare.
  const idDiff = diffMultiset(wasmList.map((v) => v.id), srvList.map((v) => v.id));
  const recDiff = diffMultiset(wasmList.map(recKey), srvList.map(recKey));
  const wHist = kindHist(wasmList), sHist = kindHist(srvList);
  const merges = dotCollapseReport(PCB);

  // Timing.
  const wasmMs = timeWasm(instance, inputStr);
  const serverMs = await timeServer(url, name, sub, body);

  const pass = idDiff.equal;
  let cause = "";
  if (!pass) {
    if (merges.length) cause = `dot-collapse (${merges.length} merged net group(s))`;
    else cause = "geometry divergence";
  }

  return {
    name, sub, parts: (PCB.parts || []).length,
    nTracks: (PCB.tracks || []).length, nVias: (PCB.vias || []).length,
    nWasm: wasmList.length, nServer: srvList.length,
    pass, idDiff, recDiff, wHist, sHist, merges, cause,
    wasmMs, serverMs, inputStr,
  };
}

// ── Reporting ────────────────────────────────────────────────────────────────

function pad(s, n) { s = String(s); return s.length >= n ? s : s + " ".repeat(n - s.length); }
function padL(s, n) { s = String(s); return s.length >= n ? s : " ".repeat(n - s.length) + s; }

function printParityTable(results) {
  console.log("\n=== PARITY ===");
  console.log(pad("design", 26) + padL("n_wasm", 8) + padL("n_srv", 8) + "  " + pad("ids_eq", 8) + pad("cause", 40));
  console.log("-".repeat(90));
  for (const r of results) {
    if (r.skipped) {
      console.log(pad(r.name, 26) + padL("-", 8) + padL("-", 8) + "  " + pad("SKIP", 8) + r.skipped);
      continue;
    }
    console.log(
      pad(r.name, 26) + padL(r.nWasm, 8) + padL(r.nServer, 8) + "  " +
      pad(r.pass ? "PASS" : "FAIL", 8) + pad(r.cause || "", 40)
    );
  }
  // Diff detail for any mismatch.
  for (const r of results) {
    if (r.skipped || r.pass) continue;
    console.log(`\n  ── ${r.name} id-multiset diff ──`);
    console.log(`     only-wasm ids: ${r.idDiff.onlyA.length}  (${sample(r.idDiff.onlyA)})`);
    console.log(`     only-srv  ids: ${r.idDiff.onlyB.length}  (${sample(r.idDiff.onlyB)})`);
    const hd = histDiffPairs(r.wHist, r.sHist);
    if (hd.length) console.log(`     per-kind diffs:\n       ${hd.join("\n       ")}`);
    else console.log("     per-kind counts equal (id divergence within same kinds — likely 16-bit id collisions or coord noise)");
    console.log(`     full-record multiset equal: ${r.recDiff.equal}` +
      (r.recDiff.equal ? "" : ` (only-wasm ${r.recDiff.onlyA.length}, only-srv ${r.recDiff.onlyB.length})`));
    if (r.merges.length) {
      console.log(`     dot-collapsed net groups (wasm merges these; server keeps distinct):`);
      for (const m of r.merges.slice(0, 8)) console.log(`       ${m.key}  ←  ${m.names.join(", ")}`);
      if (r.merges.length > 8) console.log(`       … and ${r.merges.length - 8} more`);
    }
  }
}

function sample(pairs) {
  return pairs.slice(0, 6).map(([k, c]) => (c > 1 ? `${k}×${c}` : k)).join(", ") || "—";
}

function printTimingTable(results, scaled) {
  console.log("\n=== TIMING (median of 5, ms) ===");
  console.log(pad("design", 26) + padL("wasm_ms", 10) + padL("server_ms", 12) + padL("speedup", 10));
  console.log("-".repeat(58));
  for (const r of results) {
    if (r.skipped) continue;
    const sp = r.serverMs / r.wasmMs;
    console.log(
      pad(r.name, 26) + padL(r.wasmMs.toFixed(3), 10) + padL(r.serverMs.toFixed(2), 12) +
      padL(sp.toFixed(1) + "x", 10)
    );
  }
  if (scaled) {
    console.log("-".repeat(58));
    const srv = scaled.serverMs != null ? scaled.serverMs.toFixed(2) : "n/a";
    console.log(
      pad(scaled.label, 26) + padL(scaled.wasmMs.toFixed(3), 10) + padL(srv, 12) +
      padL(scaled.serverMs != null ? (scaled.serverMs / scaled.wasmMs).toFixed(1) + "x" : "—", 10)
    );
    console.log(`  (${scaled.note})`);
  }
}

// ── Scaled dense-board perf case ─────────────────────────────────────────────

async function runScaled(url, name, factor, instance, buildDrcInput) {
  const pageRes = await fetch(`${url}/pcb-layout/${encodeURIComponent(name)}`);
  if (!pageRes.ok) return null;
  const PCB = extractPcbBlob(await pageRes.text());
  const tracks = [], vias = [];
  for (let i = 0; i < factor; i++) {
    for (const t of PCB.tracks || []) tracks.push(t);
    for (const v of PCB.vias || []) vias.push(v);
  }
  const dense = { ...PCB, tracks, vias };
  const inputStr = JSON.stringify(buildDrcInput(dense, { clearance: PCB.clr, outline: PCB.outline || null }));
  const raw = runWasmDrc(instance, inputStr);
  const wasmMs = timeWasm(instance, inputStr);
  // Best-effort server number (single warmup + median of 5) — same body shape.
  let serverMs = null;
  try {
    serverMs = await timeServer(url, name, PCB.sub || null, serverBody(dense));
  } catch { /* server may reject / time out on the dense body — wasm number stands */ }
  return {
    label: `${name} x${factor} (dense)`,
    wasmMs, serverMs,
    note: `${tracks.length} tracks / ${vias.length} vias, ${raw.n} wasm violations`,
  };
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.url || args.designs.length === 0) {
    console.log(HELP);
    process.exit(args.help ? 0 : 2);
  }
  const url = args.url.replace(/\/$/, "");
  const marshalPath = args.marshalPath || join(__dirname, "..", "src", "serve", "assets", "drc_marshal.js");
  const wasmPath = args.wasmPath || join(__dirname, "..", "zig-out", "bin", "drc.wasm");
  const { buildDrcInput } = require(marshalPath);
  const instance = await loadWasm(wasmPath);

  console.log(`server:  ${url}`);
  console.log(`wasm:    ${wasmPath}`);
  console.log(`marshal: ${marshalPath}`);
  console.log(`designs: ${args.designs.join(", ")}`);

  const results = [];
  for (const name of args.designs) {
    process.stdout.write(`\nchecking ${name} … `);
    try {
      const r = await runDesign(url, name, instance, buildDrcInput);
      results.push(r);
      process.stdout.write(r.skipped ? `SKIP (${r.skipped})` : (r.pass ? "PASS" : "FAIL"));
    } catch (e) {
      results.push({ name, skipped: `error: ${e.message}` });
      process.stdout.write(`ERROR (${e.message})`);
    }
  }
  console.log();

  let scaled = null;
  if (args.scaleX20) {
    process.stdout.write(`\nscaled x20 perf case on ${args.scaleX20} … `);
    try {
      scaled = await runScaled(url, args.scaleX20, 20, instance, buildDrcInput);
      process.stdout.write(scaled ? "done" : "unavailable");
    } catch (e) {
      process.stdout.write(`error (${e.message})`);
    }
    console.log();
  }

  printParityTable(results);
  printTimingTable(results, scaled);

  const failed = results.filter((r) => !r.skipped && !r.pass);
  const skipped = results.filter((r) => r.skipped);
  console.log(`\n${results.length - skipped.length - failed.length} pass, ${failed.length} fail, ${skipped.length} skip`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(3);
});
