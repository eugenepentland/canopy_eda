#!/usr/bin/env node
// Stamp, read back and verify the designs-workload identity carried by the
// pcb-page baseline (docs/benchmarks/pcb-page/baseline.json).
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
//   recorded <baseline.json>               print the pinned identity, if any
//   check <baseline.json> [--measured <fingerprint>] [--measured-commit <sha>]
//                         [--measured-source <label>]
//                                          compare pinned vs measured identity
//
// check exits 0 when the identity matches (or none is available to compare)
// and 3 when the workload moved or the baseline is unstamped — the caller
// should refuse to compare latencies and re-record deliberately.
//
// The measured identity is passed IN rather than always read from the
// environment because perf_gate.sh no longer always measures the live designs
// tree: when the live workload has drifted away from the recording, the gate
// restores (or rebuilds) the recorded workload snapshot and measures THAT, so
// the comparison stays apples to apples instead of refusing every push made
// after a board edit. Whatever it ends up measuring is what it names here, and
// this check still has the last word on whether that equals the recording.
// `recorded` is how the shell learns which workload to go looking for.
"use strict";
const fs = require("fs");

const MEASURED_FLAGS = ["measured", "measured-commit", "measured-source"];

/// The identity of the workload actually being measured: the caller's explicit
/// --measured pair when given, else the snapshot env perf_gate.sh exports.
/// A fingerprint without a commit still names one — its first field is the
/// designs commit — so a caller may pass either or both.
function identity(measured) {
  const explicit = measured.commit || measured.fingerprint;
  const commit = explicit
    ? measured.commit || String(measured.fingerprint).split(":")[0]
    : process.env.NETLISP_PERF_DESIGNS_COMMIT;
  if (!commit) return null;
  const fingerprint = explicit
    ? measured.fingerprint || commit
    : process.env.NETLISP_PERF_DESIGNS_FINGERPRINT || commit;
  return { commit, fingerprint, dirty: false, source: "git-archive+workload-bundles" };
}

const short = (value) => String(value).slice(0, 12);
const RERECORD = "re-record deliberately (scripts/perf_gate.sh --record)";

/// The pinned identity of a baseline, in either committed shape: the page
/// baseline's top-level `designs`, or the browser baselines' `reference.designs`.
/// An unreadable or unstamped file simply has none — naming that is `check`'s
/// job, not this reader's.
function recordedIdentity(path) {
  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (_) {
    return null;
  }
  const pinned = doc && (doc.designs || (doc.reference && doc.reference.designs));
  if (!pinned || !pinned.commit || !pinned.fingerprint) return null;
  return pinned;
}

function parseArgs(argv) {
  const rest = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      rest.push(arg);
      continue;
    }
    const key = arg.slice(2);
    if (!MEASURED_FLAGS.includes(key)) return null;
    const value = argv[++i];
    if (value === undefined) return null;
    flags[key] = value;
  }
  return { rest, flags };
}

function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (!parsed) return usage();
  const [mode, target, previousPath] = parsed.rest;
  const measured = {
    commit: parsed.flags["measured-commit"] || "",
    fingerprint: parsed.flags.measured || "",
    source: parsed.flags["measured-source"] || "",
  };
  if (mode === "stamp" && target) {
    const recorded = JSON.parse(fs.readFileSync(target, "utf8"));
    if (previousPath && fs.existsSync(previousPath)) {
      const previous = JSON.parse(fs.readFileSync(previousPath, "utf8"));
      if (previous.budgets) recorded.budgets = previous.budgets;
    }
    const designs = identity(measured);
    if (designs) recorded.designs = designs;
    fs.writeFileSync(target, `${JSON.stringify(recorded, null, 2)}\n`);
    return 0;
  }
  if (mode === "recorded" && target) {
    // Machine-readable, for the shell: `key=value` lines, or nothing at all
    // when this baseline pins no workload. Values are hex, so no quoting
    // question arises.
    const pinned = recordedIdentity(target);
    if (!pinned) return 0;
    console.log(`commit=${pinned.commit}`);
    console.log(`fingerprint=${pinned.fingerprint}`);
    return 0;
  }
  if (mode === "check" && target) {
    const current = identity(measured);
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
    const where = measured.source ? ` (${measured.source})` : "";
    console.log(`perf_gate: pcb-page baseline workload matches designs ${short(current.commit)}${where}`);
    return 0;
  }
  return usage();
}

function usage() {
  console.error("usage: perf_gate_designs_identity.js stamp <recorded.json> [previous.json]"
    + " | recorded <baseline.json>"
    + " | check <baseline.json> [--measured <fingerprint>] [--measured-commit <sha>] [--measured-source <label>]");
  return 2;
}

process.exit(main());
