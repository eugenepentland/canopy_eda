#!/usr/bin/env node
// Behavioural probes for the browser's PER-TRACK power width targets.
//
// Every client-side widening used to read ONE number per net — the class row's
// `adaptive_power_width`, which is the IPC width for the WHOLE rail's current.
// A fanout carrying a tenth of the load was therefore widened as if it carried
// all of it. `powerTargetForTrack` prefers the deferred power-integrity
// screen's per-track solved requirement and falls back to that rail envelope
// only when the screen is absent, stale, or unsolved. These probes pin both
// halves, the never-narrow rule the recut depends on, and the deferral list
// that keeps every server-only power kind out of the fast DRC tier.
//
// Harness style follows scripts/rf_taper_geometry_test.mjs: functions are
// extracted from pcb_board.js by name and run in a vm context with stubs, so
// the assertions are about the shipped source, not a copy of it.

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const boardPath = fileURLToPath(new URL("../src/serve/assets/pcb_board.js", import.meta.url));
const source = fs.readFileSync(boardPath, "utf8");

function functionSource(name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  let i = source.indexOf("{", start);
  let depth = 0;
  for (; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${name}`);
}

function load(names, globals = {}) {
  const context = vm.createContext({ console, Math, String, Number, isFinite, window: {}, ...globals });
  vm.runInContext(names.map(functionSource).join("\n"), context);
  return context;
}

// The 1 mil manufacturing increment is a top-level `var`, not a function, so
// assert its value in source and hand the same number to the vm.
const MIL = 0.0254;
assert.match(source, /var POWER_WIDTH_STEP=0\.0254;/,
  "the per-track target must round up to the same 1 mil increment the DRC repair uses");

const TARGET_FNS = [
  "powerWidthRound", "powerFlowSolved", "powerTargetForTrack",
  "powerIntegrityInfo", "powerIntegrityTrack",
];

// One straight segment of V_12V on layer 0, plus the screen row that describes
// it. `required` is the server's solved requirement for that segment.
function fixture({ status = "solved", required = 0.31, current = 1.4, rail = 0.8, branchFloor = 0, minWidth = 0.127, typicalOnly = false } = {}) {
  const track = { net: "V_12V", l: 0, x1: 1, y1: 2, x2: 5, y2: 2, w: minWidth };
  const row = {
    l: 0, x1: 1, y1: 2, x2: 5, y2: 2,
    current_typical_a: current, current_maximum_a: current,
    required_width_typical_mm: required,
  };
  if (!typicalOnly) row.required_width_maximum_mm = required;
  const PCB = {
    rules: { min_width: minWidth, track_width: 0.2 },
    power_integrity: {
      nets: [{
        net: "V_12V",
        flow_typical_status: status,
        flow_maximum_status: status,
        tracks: [row],
      }],
    },
  };
  const ctx = load(TARGET_FNS, {
    PCB,
    POWER_WIDTH_STEP: MIL,
    powerIntegrityDirty: false,
    powerIntegrityIdx: null,
    netCollapse(n) { return String(n || "").split(".")[0]; },
    netClassInfo() { return { width: 0.4, adaptive_power_width: rail, power_branch_width: branchFloor }; },
  });
  return { ctx, track, PCB };
}

// ── 1 mil rounding ───────────────────────────────────────────────────────────
{
  const { ctx } = fixture();
  assert.equal(ctx.powerWidthRound(0), 0, "no requirement rounds to nothing, not to one mil");
  assert(Math.abs(ctx.powerWidthRound(0.31) - 13 * MIL) < 1e-12,
    "0.31 mm must round UP to the next whole mil (0.3302 mm)");
  assert(Math.abs(ctx.powerWidthRound(13 * MIL) - 13 * MIL) < 1e-12,
    "a requirement already on the grid must not be pushed a mil wider");
}

// ── solved flow → the per-track target ───────────────────────────────────────
{
  const { ctx, track } = fixture({ status: "solved", required: 0.31, rail: 0.8 });
  const q = ctx.powerTargetForTrack(track);
  assert.equal(q.source, "branch", "a solved rail must size this segment by its own current");
  assert(Math.abs(q.target - 13 * MIL) < 1e-12,
    `a solved 0.31 mm requirement must give 0.3302 mm, not the 0.8 mm whole-rail envelope (got ${q.target})`);
  assert.equal(q.current, 1.4, "the panel needs the branch current that produced the target");
}
{
  const { ctx, track } = fixture({ status: "solved-partial", required: 0.31 });
  assert.equal(ctx.powerTargetForTrack(track).source, "branch",
    "a partially solved rail still carries real branch currents on the segments it resolved");
  assert.equal(ctx.powerFlowSolved("solved"), true);
  assert.equal(ctx.powerFlowSolved("solved-partial"), true);
  assert.equal(ctx.powerFlowSolved("disconnected"), false);
}
{
  // No maximum column published: the typical requirement and ITS status govern.
  const { ctx, track } = fixture({ status: "solved", required: 0.2, typicalOnly: true });
  const q = ctx.powerTargetForTrack(track);
  assert.equal(q.source, "branch");
  assert(Math.abs(q.target - 8 * MIL) < 1e-12, "0.2 mm typical must round up to 0.2032 mm");
}

// ── unsolved / absent / stale → the whole-rail envelope ──────────────────────
for (const status of ["incomplete-load-terminals", "disconnected", "singular", "no-source-terminal"]) {
  const { ctx, track } = fixture({ status, required: 0.31, rail: 0.8 });
  const q = ctx.powerTargetForTrack(track);
  assert.equal(q.source, "rail", `an unsolved (${status}) rail must fall back to the envelope`);
  assert.equal(q.target, 0.8, "the fallback IS today's behaviour — the class adaptive_power_width");
  assert.equal(q.status, status, "the inspector has to be able to name the unsolved status");
}
{
  const { ctx, track } = fixture({ rail: 0.8 });
  ctx.powerIntegrityDirty = true;
  const q = ctx.powerTargetForTrack(track);
  assert.equal(q.source, "rail", "a screen stale after a copper edit must not size new copper");
  assert.equal(q.target, 0.8);
  assert.equal(q.status, "no-screen");
}
{
  // Copper the screen has no row for — a segment drawn since the last solve.
  const { ctx } = fixture({ rail: 0.8 });
  const q = ctx.powerTargetForTrack({ net: "V_12V", l: 0, x1: 40, y1: 40, x2: 44, y2: 40 });
  assert.equal(q.source, "rail", "an unmatched segment must fall back, never invent a target");
  assert.equal(q.target, 0.8);
  assert.equal(q.status, "no-screen-row");
  // The pen's own call shape: a net with no geometry at all cannot match.
  assert.equal(ctx.powerTargetForTrack({ net: "V_12V" }).source, "rail",
    "a pen stroke that is not on the board yet has no solve and must draw against the envelope");
}

// ── a solved branch carrying no current still has to be manufacturable ───────
{
  const { ctx, track } = fixture({ status: "solved", required: 0, current: 0, rail: 0.8, minWidth: 0.127 });
  const q = ctx.powerTargetForTrack(track);
  assert.equal(q.source, "branch");
  assert(Math.abs(q.target - 0.127) < 1e-12,
    `a 0 A solved branch must sit at the fabrication floor, not at 0 mm or at the 0.8 mm rail (got ${q.target})`);
}
{
  const { ctx, track } = fixture({ status: "solved", required: 0.05, branchFloor: 0.2, minWidth: 0.127 });
  assert(Math.abs(ctx.powerTargetForTrack(track).target - 0.2) < 1e-12,
    "a declared power_branch_width is a hard lower bound on the solved answer");
}

// ── never narrow existing copper ─────────────────────────────────────────────
{
  const rewidenFns = TARGET_FNS.concat(["rewidenTarget", "rewidenRunTarget"]);
  const PCB = {
    rules: { min_width: 0.127, track_width: 0.2 },
    power_integrity: {
      nets: [{
        net: "V_12V", flow_typical_status: "solved", flow_maximum_status: "solved",
        tracks: [
          { l: 0, x1: 0, y1: 0, x2: 4, y2: 0, current_typical_a: 1.4, current_maximum_a: 1.4, required_width_typical_mm: 0.31, required_width_maximum_mm: 0.31 },
          { l: 0, x1: 4, y1: 0, x2: 8, y2: 0, current_typical_a: 3.1, current_maximum_a: 3.1, required_width_typical_mm: 0.6, required_width_maximum_mm: 0.6 },
        ],
      }],
    },
  };
  const ctx = load(rewidenFns, {
    PCB,
    POWER_WIDTH_STEP: MIL,
    powerIntegrityDirty: false,
    powerIntegrityIdx: null,
    netCollapse(n) { return String(n || "").split(".")[0]; },
    netClassInfo() { return { width: 0.4, adaptive_power_width: 0.8, power_branch_width: 0 }; },
    baseTrackW() { return 0.2; },
  });
  const thin = { net: "V_12V", l: 0, x1: 0, y1: 0, x2: 4, y2: 0, w: 0.127 };
  const fat = { net: "V_12V", l: 0, x1: 0, y1: 0, x2: 4, y2: 0, w: 0.8 };

  const undersized = ctx.rewidenTarget(thin);
  assert.equal(undersized.source, "branch");
  assert(Math.abs(undersized.target - 13 * MIL) < 1e-12,
    "undersized copper on a solved branch must be recut to ITS current, not the whole rail's");

  const already = ctx.rewidenTarget(fat);
  assert.equal(already.target, 0.8,
    "copper already standing at the rail envelope must never be automatically narrowed to a smaller branch target");

  // The run is committed at ONE width, so it has to meet the hungriest member.
  const heavy = { net: "V_12V", l: 0, x1: 4, y1: 0, x2: 8, y2: 0, w: 0.127 };
  const runTarget = ctx.rewidenRunTarget([thin, heavy], undersized);
  assert(Math.abs(runTarget - 24 * MIL) < 1e-12,
    `a run must take the widest per-track target in the chain (0.6096 mm), got ${runTarget}`);

  // An unclassed / non-adaptive net is not enrolled at all — unchanged rule.
  const plain = load(rewidenFns, {
    PCB, POWER_WIDTH_STEP: MIL, powerIntegrityDirty: false, powerIntegrityIdx: null,
    netCollapse(n) { return String(n || "").split(".")[0]; },
    netClassInfo() { return { width: 0.4, adaptive_power_width: 0, power_branch_width: 0 }; },
    baseTrackW() { return 0.2; },
  });
  assert.equal(plain.rewidenTarget(thin), null,
    "a net the server never marked adaptive must stay out of the healer entirely");
}

// ── the deferred server-only kinds ───────────────────────────────────────────
{
  const PCB = { rules: { min_width: 0.127 } };
  let klass = { width: 0.4, adaptive_power_width: 0.4, power_branch_width: 0 };
  const g = load(["drcPowerKindDeferred", "drcGateDefersPowerWidth"], {
    PCB,
    netClassInfo() { return klass; },
  });
  const deferred = [
    "power width",
    "power width (envelope)",
    "via current",
    "via current (envelope)",
    // Prefix matching on purpose: a qualifier the server adds later must not
    // leak an unprovable finding into the fast tier before this list catches up.
    "power width (envelope, maximum)",
    "via current (maximum)",
  ];
  for (const k of deferred) {
    assert.equal(g.drcPowerKindDeferred(k), true, `${k} is server-only and must be deferred`);
    assert.equal(g.drcGateDefersPowerWidth({ k, a: { net: "V_12V" } }), true,
      `${k} must not block the synchronous client gate`);
    assert.equal(g.drcGateDefersPowerWidth({ k }), true,
      `${k} must defer even without a party — the kind alone is unprovable here`);
  }
  for (const k of ["track width", "net open", "track↔track", "board edge", "annular", "powerwidth", "via"]) {
    assert.equal(g.drcPowerKindDeferred(k), false, `${k} is not a server-only power kind`);
  }

  // The pre-existing `track width` deferral is unchanged.
  const width = (gap, net = "V_12V") => ({ k: "track width", gap, a: { net } });
  assert.equal(g.drcGateDefersPowerWidth(width(0.3)), true,
    "an adaptive rail without a branch floor still defers its electrical width");
  assert.equal(g.drcGateDefersPowerWidth(width(0.1)), false,
    "an adaptive rail below the fabrication minimum still fails in the fast tier");
  klass = { width: 0.4, adaptive_power_width: 0, power_branch_width: 0 };
  assert.equal(g.drcGateDefersPowerWidth(width(0.3, "RF_OUT")), false,
    "ordinary class-width violations must never be deferred");
  assert.equal(g.drcGateDefersPowerWidth(null), false, "a missing finding defers nothing");
}

// ── the finding row carries the server's reason ──────────────────────────────
{
  const g = load(["drcReason"], {});
  assert.equal(g.drcReason({ reason: "whole-rail envelope: disconnected" }), "whole-rail envelope: disconnected");
  assert.equal(g.drcReason({ why: "solved branch current 3.10 A" }), "solved branch current 3.10 A");
  assert.equal(g.drcReason({ msg: "needs 3 vias" }), "needs 3 vias");
  assert.equal(g.drcReason({}), "", "a finding with no explanation must print none");
  assert.equal(g.drcReason({ reason: 12 }), "", "a non-string must not be concatenated into the row");
}

console.log("power-branch-width: all probes passed");
