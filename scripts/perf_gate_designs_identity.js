#!/usr/bin/env node
// Stamp and verify the designs-workload identity carried by the pcb-page
// baseline (docs/benchmarks/pcb-page/baseline.json).
//
// `netlisp bench-page --json` reports measurements only: budgets are hand-set,
// and the workload identity comes from scripts/perf_gate.sh's snapshot
// fingerprint (NETLISP_PERF_DESIGNS_COMMIT / _FINGERPRINT — designs commit
// plus model/layout/BOM bundle hashes). Without the stamp, a designs-repo move
// reads as a latency regression and costs a forensic diff (FEEDBACK.md
// 2026-08-29). The pcb-browser and ui-browser baselines already carry the same
// identity under reference.designs; this brings the page baseline to parity.
//
//   stamp <recorded.json> [previous.json]  carry budgets forward, pin identity
//   check <baseline.json>                  compare pinned vs current identity
//
// check exits 0 when the identity matches (or none is available to compare)
// and 3 when the workload moved or the baseline is unstamped — the caller
// should refuse to compare latencies and re-record deliberately.
"use strict";
const fs = require("fs");

function identity() {
  const commit = process.env.NETLISP_PERF_DESIGNS_COMMIT;
  if (!commit) return null;
  return {
    commit,
    fingerprint: process.env.NETLISP_PERF_DESIGNS_FINGERPRINT || commit,
    dirty: false,
    source: "git-archive+workload-bundles",
  };
}

const short = (value) => String(value).slice(0, 12);
const RERECORD = "re-record deliberately (scripts/perf_gate.sh --record)";

function main() {
  const [mode, target, previousPath] = process.argv.slice(2);
  if (mode === "stamp" && target) {
    const recorded = JSON.parse(fs.readFileSync(target, "utf8"));
    if (previousPath && fs.existsSync(previousPath)) {
      const previous = JSON.parse(fs.readFileSync(previousPath, "utf8"));
      if (previous.budgets) recorded.budgets = previous.budgets;
    }
    const designs = identity();
    if (designs) recorded.designs = designs;
    fs.writeFileSync(target, `${JSON.stringify(recorded, null, 2)}\n`);
    return 0;
  }
  if (mode === "check" && target) {
    const current = identity();
    if (!current) return 0; // non-git designs dir: no identity to compare
    if (!fs.existsSync(target)) return 0; // bench-page names the missing baseline itself
    const recorded = JSON.parse(fs.readFileSync(target, "utf8")).designs;
    if (!recorded || !recorded.commit || !recorded.fingerprint) {
      console.error(`perf_gate: ${target} records no designs workload identity `
        + `(pre-stamp baseline) — cannot tell workload drift from regression; ${RERECORD}`);
      return 3;
    }
    if (recorded.fingerprint !== current.fingerprint) {
      const moved = recorded.commit === current.commit
        ? `designs commit ${short(current.commit)} is unchanged but the model/layout/BOM bundles moved`
        : `recorded against designs ${short(recorded.commit)}, comparing against designs ${short(current.commit)}`;
      console.error(`perf_gate: pcb-page workload changed — ${moved}; latency deltas `
        + `would be workload drift, not regression, so the comparison is refused; ${RERECORD}`);
      return 3;
    }
    console.log(`perf_gate: pcb-page baseline workload matches designs ${short(current.commit)}`);
    return 0;
  }
  console.error("usage: perf_gate_designs_identity.js stamp <recorded.json> [previous.json] | check <baseline.json>");
  return 2;
}

process.exit(main());
