#!/usr/bin/env node
// Behavioral probes for the browser's variable-width RF and power geometry.
// These use the Barracuda launches/corridor that exposed a folded sweep, an
// off-centre pad exit, and a power trace that could not pass its neighbour.

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const boardPath = fileURLToPath(new URL("../src/serve/assets/pcb_board.js", import.meta.url));
const source = fs.readFileSync(boardPath, "utf8");
const require = createRequire(import.meta.url);

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
  const context = vm.createContext({ console, Math, ...globals });
  vm.runInContext(names.map(functionSource).join("\n"), context);
  return context;
}

// A capsule's round cap hides a width step along a straight and nothing at all
// across an angle, so every emitted pair that meets at a bend has to meet at ONE
// width. Every suite that emits shaped copper runs this.
function assertBendContinuity(shaped, label) {
  for (let i = 1; i < shaped.length; i++) {
    const p = shaped[i - 1];
    const q = shaped[i];
    if (Math.hypot(q.x1 - p.x2, q.y1 - p.y2) > 1e-9) continue;
    const ax = p.x2 - p.x1, ay = p.y2 - p.y1, bx = q.x2 - q.x1, by = q.y2 - q.y1;
    const al = Math.hypot(ax, ay), bl = Math.hypot(bx, by);
    if (!(al > 1e-12) || !(bl > 1e-12)) continue;
    if (Math.abs((ax * by - ay * bx) / (al * bl)) <= 1e-9 && ax * bx + ay * by > 0) continue;
    assert(Math.abs(p.w - q.w) < 1e-9,
      `${label}: slices meeting at (${q.x1}, ${q.y1}) step from ${p.w} to ${q.w} across the bend`);
  }
}

{
  const document = { getElementById() { return { value: "net" }; } };
  const PCB = { rules: { track_width: 0.127, min_width: 0.1 }, zones: [] };
  const g = load(["trackW", "drawPowerTarget", "drawNetGeometry"], {
    PCB,
    document,
    netClassInfo() { return { width: 0.4, adaptive_power_width: 0.4 }; },
    baseTrackW() { return 0.127; },
  });
  assert.deepEqual({ ...g.drawNetGeometry("V_12V_RAW") }, { width: 0.127, target: 0.4 },
    "a current-rated rail must steer at ordinary routing width while retaining its electrical target");

  PCB.zones = [{ net: "V_12V_RAW", keepout: false }];
  assert.deepEqual({ ...g.drawNetGeometry("V_12V_RAW") }, { width: 0.127, target: 0.4 },
    "a local eFuse zone must not disable adaptive widening on the rest of the rail");
}

{
  const g = load(["drawTaperProfile"], {
    PCB: { rules: { track_width: 0.127, min_width: 0.1 } },
    netClassInfo() { return {
      width: 0.4,
      adaptive_power_width: 0.4,
      pad_neck_width: 0.1524,
      pad_neck_max_length: 0.75,
      pad_neck_taper_length: 0.35,
    }; },
    baseTrackW() { return 0.127; },
  });
  const pad = { pd: { w: 0.3, h: 2.4 } };
  const profile = g.drawTaperProfile("V_12V_RAW", pad, 0.4, { land: 1.2, span: 0.3 });
  assert.equal(profile.kind, "power");
  assert.notEqual(profile.width, 0.1524, "a generic authored escape must not override the adaptive pad-sized launch");
  assert(Math.abs(profile.width - 0.3) < 1e-12,
    "the power launch must use the pad's smaller physical dimension, independent of route angle");
  assert(Math.abs(profile.land - 1.2) < 1e-12, "the power taper must begin at the measured pad boundary");
  assert(Math.abs(profile.taper - 0.05) < 1e-12,
    "a 0.3-to-0.4 mm launch needs only 0.05 mm for 45-degree copper flanks");
}

{
  const floor = 0.127;
  const target = 0.4;
  const g = load([
    "drawProfileWidth",
    "drawTrackEndDirection",
    "drawAdaptiveBendJoint",
    "drawAdaptiveStations",
    "drawAdaptiveClearWidth",
    "drawAdaptiveExactClearWidth",
    "drawAdaptiveRefinedClearWidth",
    "drawSamePointXY",
    "drawShapedPush",
    "drawAdaptivePowerRun",
  ], {
    DRAW_ADAPTIVE_STEP: 0.05,
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    drawTrackPoint(t, f) { return { x: t.x1 + (t.x2 - t.x1) * f, y: t.y1 + (t.y2 - t.y1) * f }; },
    trackIdEnsure(t) { return t.id; },
    segViolation(x1, _y1, x2, _y2, _layer, _net, hw) {
      const x = (x1 + x2) / 2;
      const limit = x > 1.1 && x < 1.9 ? 0.22 : target;
      return 2 * hw > limit + 1e-9 ? { k: "clearance" } : null;
    },
  });
  const track = { id: "power-owner", net: "V_12V_RAW", l: 0, x1: 0, y1: 0, x2: 3, y2: 0 };
  const start = { kind: "power", width: 0.3, land: 0.3, taper: 0.05, step: 0.0125 };
  const plan = g.drawAdaptivePowerRun([track], start, null, floor, target);
  assert.equal(plan.paths.length, 1);
  const samples = plan.paths[0].samples;
  function widthAt(x) {
    const sample = samples.find((s) => Math.abs(s[0] - x) < 1e-8);
    assert(sample, `missing exact adaptive station at ${x}`);
    return sample[2];
  }
  assert(Math.abs(widthAt(0) - 0.3) < 1e-8, "the launch must start at the pad's 0.3 mm minimum dimension");
  assert(Math.abs(widthAt(0.3) - 0.3) < 1e-8, "the taper must not begin before the pad boundary");
  assert(Math.abs(widthAt(0.35) - 0.4) < 2e-4, "the compact taper must reach the 0.4 mm target after 0.05 mm");
  assert(samples.some((s) => s[0] > 1.2 && s[0] < 1.8 && s[2] <= 0.2202),
    "the physical path must neck down only where the neighbouring trace constrains it");
  assert(samples.some((s) => s[0] > 2.2 && s[2] > 0.399), "open copper must recover the full electrical target");
  samples.forEach((s, i) => {
    assert(s[2] >= floor - 1e-9, "adaptive copper must never fall below the routing floor");
    if (!i) return;
    const prior = samples[i - 1];
    const distance = Math.hypot(s[0] - prior[0], s[1] - prior[1]);
    assert(Math.abs(s[2] - prior[2]) <= 2 * distance + 1e-8,
      "adjacent adaptive widths must retain 45-degree-or-shallower flanks");
  });

  // Shaped copper is committed as real tracks now, so equal-width collinear
  // stations have to leave as ONE segment instead of a 50 um slice per station.
  const shaped = plan.tracks;
  assert(shaped.length < samples.length / 4,
    `equal-width stations must collapse into runs (${shaped.length} of ${samples.length - 1} slices)`);
  const trunk = shaped.filter((t) => t.x1 > 1.9 && Math.abs(t.w - target) < 1e-9);
  assert.equal(trunk.length, 1, "the recovered full-width trunk must be one track, not one per station");
  assert(trunk[0].x2 > 2.99, "the collapsed trunk must reach the end of the run");
  assert.equal(shaped.filter((t) => t.w < 0.23).length, 1, "the necked stretch must also be a single segment");
  shaped.forEach((t, i) => {
    assert(Math.hypot(t.x2 - t.x1, t.y2 - t.y1) > 1e-9, "shaped copper must never emit a zero-length slice");
    if (i) assert(Math.abs(t.x1 - shaped[i - 1].x2) < 1e-9 && Math.abs(t.y1 - shaped[i - 1].y2) < 1e-9,
      "collapsing must keep the shaped run continuous");
  });
  assert(Math.abs(shaped[0].x1) < 1e-12 && Math.abs(shaped.at(-1).x2 - 3) < 1e-12,
    "the collapsed run must still span the whole centreline");
  assertBendContinuity(shaped, "straight pad-launched power run");
}

{
  // The reported ledge: a width transition that crosses a BEND station puts the
  // step exactly on the elbow, where no round cap can hide it. Both slices at
  // the corner must carry the corner's own width and the taper must move onto
  // the straight.
  const floor = 0.127;
  const target = 0.4;
  const g = load([
    "drawProfileWidth", "drawTrackEndDirection", "drawAdaptiveBendJoint", "drawAdaptiveStations",
    "drawAdaptiveClearWidth", "drawAdaptiveExactClearWidth", "drawAdaptiveRefinedClearWidth",
    "drawSamePointXY", "drawShapedPush", "drawAdaptivePowerRun",
  ], {
    DRAW_ADAPTIVE_STEP: 0.05,
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    drawTrackPoint(t, f) { return { x: t.x1 + (t.x2 - t.x1) * f, y: t.y1 + (t.y2 - t.y1) * f }; },
    trackIdEnsure(t) { return t.id; },
    // A neighbour crowds only the incoming leg, from x = 1 up to the corner.
    segViolation(x1, y1, x2, y2, _layer, _net, hw) {
      const necked = Math.abs(y1) < 1e-9 && Math.abs(y2) < 1e-9 && (x1 + x2) / 2 > 1;
      return 2 * hw > (necked ? 0.2 : target) + 1e-9 ? { k: "clearance" } : null;
    },
  });
  const legs = [
    { id: "in", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 2, y2: 0 },
    { id: "out", net: "V_12V", l: 0, x1: 2, y1: 0, x2: 2, y2: 2 },
  ];
  const plan = g.drawAdaptivePowerRun(legs, null, null, floor, target);
  const shaped = plan.tracks;
  assertBendContinuity(shaped, "necked two-leg bend");
  const into = shaped.filter((t) => Math.hypot(t.x2 - 2, t.y2) < 1e-9);
  const outOf = shaped.filter((t) => Math.hypot(t.x1 - 2, t.y1) < 1e-9);
  assert.equal(into.length, 1, "exactly one slice may arrive at the corner");
  assert.equal(outOf.length, 1, "exactly one slice may leave the corner");
  assert(Math.abs(into[0].w - outOf[0].w) < 1e-12,
    `the two slices at the bend must share one width (${into[0].w} vs ${outOf[0].w})`);
  assert(into[0].w > 0.19 && into[0].w <= 0.2 + 1e-9,
    `the corner must carry the narrower leg's clearance-fitted width, not the wide leg's (${into[0].w})`);
  const flank = shaped.filter((t) => Math.abs(t.x1 - 2) < 1e-9 && t.y1 > 1e-9);
  assert(flank.length >= 1 && flank.every((t) => t.w > 0.2 + 1e-9),
    "the recovered width must live on the straight beyond the corner");
  assert(shaped.some((t) => Math.abs(t.w - target) < 1e-9), "the open leg still reaches the electrical target");
  const samples = plan.paths[0].samples;
  const corner = samples.find((s) => Math.hypot(s[0] - 2, s[1]) < 1e-9);
  assert(corner && corner[2] > 0.19 && corner[2] <= 0.2 + 1e-9,
    "the sampled corner station carries the joint width");
  assert(Math.abs(corner[2] - into[0].w) < 1e-12, "the emitted corner slices carry exactly the corner station's width");
  samples.forEach((s, i) => {
    if (!i) return;
    const prior = samples[i - 1];
    assert(Math.abs(s[2] - prior[2]) <= 2 * Math.hypot(s[0] - prior[0], s[1] - prior[1]) + 1e-8,
      "a bent run keeps 45-degree-or-shallower flanks through the corner");
  });
}

{
  // Run-boundary caps. A terminal that butts onto existing same-net copper is
  // not free: it leaves at THAT neighbour's width, narrower or wider, and the
  // 45-degree flank carries it to the target inboard.
  const floor = 0.127;
  const target = 0.4;
  const g = load([
    "drawProfileWidth", "drawTrackEndDirection", "drawAdaptiveBendJoint", "drawAdaptiveStations",
    "drawAdaptiveClearWidth", "drawAdaptiveExactClearWidth", "drawAdaptiveRefinedClearWidth",
    "drawSamePointXY", "drawShapedPush", "drawAdaptivePowerRun", "drawJointProfile",
  ], {
    DRAW_ADAPTIVE_STEP: 0.05,
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    drawTrackPoint(t, f) { return { x: t.x1 + (t.x2 - t.x1) * f, y: t.y1 + (t.y2 - t.y1) * f }; },
    trackIdEnsure(t) { return t.id; },
    segViolation(_x1, _y1, _x2, _y2, _layer, _net, hw) { return 2 * hw > 0.9 ? { k: "clearance" } : null; },
  });

  assert.equal(g.drawJointProfile(0, target), null, "no neighbour is no joint");
  assert.equal(g.drawJointProfile(target, target), null, "a neighbour already at target needs no profile");
  const narrow = g.drawJointProfile(0.127, target);
  assert.equal(narrow.land, 0, "the joint width is held AT the joint, not past it");
  assert(Math.abs(narrow.taper - (target - 0.127) / 2) < 1e-12,
    "a narrower neighbour flares up over half the width difference — a 45-degree flank");

  const track = { id: "spliced", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0 };
  const capped = g.drawAdaptivePowerRun([track], narrow, null, floor, target);
  assertBendContinuity(capped.tracks, "narrow-neighbour terminal");
  assert(Math.abs(capped.tracks[0].w - 0.127) < 1e-9,
    `the terminal slice must meet the 0.127 mm neighbour (${capped.tracks[0].w})`);
  assert(Math.abs(capped.paths[0].samples[0][2] - 0.127) < 1e-9, "the sampled terminal station carries the joint width");
  assert(capped.tracks[0].x2 <= 0.05 + 1e-9, "only the slice touching the joint is capped");
  assert(capped.tracks.some((t) => Math.abs(t.w - target) < 1e-9), "the run still reaches its target inboard");
  capped.paths[0].samples.forEach((s, i) => {
    if (!i) return;
    const prior = capped.paths[0].samples[i - 1];
    assert(Math.abs(s[2] - prior[2]) <= 2 * (s[0] - prior[0]) + 1e-8, "the inboard flank stays at 45 degrees");
    assert(s[2] >= floor - 1e-9, "a joint cap never drops the run below the routing floor");
  });

  const trunk = g.drawJointProfile(0.8, target);
  assert(Math.abs(trunk.taper - (0.8 - target) / 2) < 1e-12,
    "a wider neighbour comes DOWN over half the difference at the same 45 degrees");
  const flared = g.drawAdaptivePowerRun([track], trunk, null, floor, target);
  assertBendContinuity(flared.tracks, "wide-trunk terminal");
  assert(Math.abs(flared.tracks[0].w - 0.8) < 1e-9,
    `joining an already-wide trunk must flare UP to meet it (${flared.tracks[0].w})`);
  assert(flared.maxWidth >= 0.8 - 1e-9, "the flare is reported as the run's widest copper");
  assert(flared.tracks.some((t) => Math.abs(t.w - target) < 1e-9), "the flare comes back to target on the straight");

  // Clearance still outranks cosmetics: a flare no cell can fit is clamped.
  const tight = load([
    "drawProfileWidth", "drawTrackEndDirection", "drawAdaptiveBendJoint", "drawAdaptiveStations",
    "drawAdaptiveClearWidth", "drawAdaptiveExactClearWidth", "drawAdaptiveRefinedClearWidth",
    "drawSamePointXY", "drawShapedPush", "drawAdaptivePowerRun",
  ], {
    DRAW_ADAPTIVE_STEP: 0.05,
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    drawTrackPoint(t, f) { return { x: t.x1 + (t.x2 - t.x1) * f, y: t.y1 + (t.y2 - t.y1) * f }; },
    trackIdEnsure(t) { return t.id; },
    segViolation(_x1, _y1, _x2, _y2, _layer, _net, hw) { return 2 * hw > 0.45 ? { k: "clearance" } : null; },
  });
  const clamped = tight.drawAdaptivePowerRun([track], trunk, null, floor, target);
  assert(clamped.tracks[0].w <= 0.45 + 1e-9,
    "a joint flare stays inside the clearance-fitted cell cap like every other station");
}

{
  // Which terminals are joints at all. A fresh gesture that stops on existing
  // copper splices only where EXACTLY one same-net, same-layer track ends and no
  // via barrel covers the point.
  const trunk = { id: "trunk", net: "V_12V", l: 0, x1: 3, y1: 0, x2: 6, y2: 0, w: 0.8 };
  const branch = { id: "branch", net: "V_12V", l: 0, x1: 3, y1: 0, x2: 3, y2: 3, w: 0.3 };
  const foreign = { id: "gnd", net: "GND", l: 0, x1: 3, y1: 0, x2: 3, y2: -3, w: 0.5 };
  const upper = { id: "lay", net: "V_12V", l: 1, x1: 3, y1: 0, x2: 3, y2: -3, w: 0.5 };
  const mine = { id: "mine", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: 0.127 };
  const PCB = { tracks: [trunk, branch, foreign, upper, mine], vias: [] };
  const g = load(["drawJointNeighbourWidth"], { PCB, DRAW_JOINT_SNAP: 2e-3 });

  assert.equal(g.drawJointNeighbourWidth("V_12V", 0, 3, 0, [mine]), 0,
    "a T-junction is an ordinary trunk/branch step and must stay free");
  PCB.tracks = [trunk, foreign, upper, mine];
  assert(Math.abs(g.drawJointNeighbourWidth("V_12V", 0, 3, 0, [mine]) - 0.8) < 1e-12,
    "one same-net same-layer neighbour is a two-way splice and supplies its width");
  assert(Math.abs(g.drawJointNeighbourWidth("V_12V", 0, 3.0015, 0, [mine]) - 0.8) < 1e-12,
    "a gesture that lands within the snap tolerance still splices");
  assert.equal(g.drawJointNeighbourWidth("V_12V", 0, 3.05, 0, [mine]), 0, "copper further off is not a joint");
  assert(Math.abs(g.drawJointNeighbourWidth("V_12V", 1, 3, 0, []) - 0.5) < 1e-12,
    "each layer counts only its own copper — the layer-0 trunk is invisible from layer 1");
  assert.equal(g.drawJointNeighbourWidth("V_5VA", 0, 3, 0, [mine]), 0, "another net never pins this terminal");
  assert.equal(g.drawJointNeighbourWidth("V_12V", 0, 3, 0, []), 0,
    "the gesture's own laid copper must be excluded before the neighbours are counted");
  PCB.vias = [{ net: "V_12V", x: 3, y: 0, d: 0.6 }];
  assert.equal(g.drawJointNeighbourWidth("V_12V", 0, 3, 0, [mine]), 0,
    "a same-net via barrel covers the elbow — that corner stays free");
  PCB.vias = [{ net: "GND", x: 3, y: 0, d: 0.6 }];
  assert(Math.abs(g.drawJointNeighbourWidth("V_12V", 0, 3, 0, [mine]) - 0.8) < 1e-12,
    "a foreign via covers nothing on this net");
}

{
  const g = load(["drawSamePointXY", "drawShapedPush"]);
  function push(...slices) {
    const out = [];
    slices.forEach((s) => g.drawShapedPush(out, s));
    return out;
  }
  const straight = push(
    { x1: 0, y1: 0, x2: 1, y2: 0, w: 0.4 },
    { x1: 1, y1: 0, x2: 2, y2: 0, w: 0.4 },
  );
  assert.equal(straight.length, 1, "collinear equal-width slices must merge");
  assert.equal(straight[0].x2, 2);
  assert.equal(push(
    { x1: 0, y1: 0, x2: 1, y2: 0, w: 0.4 },
    { x1: 1, y1: 0, x2: 2, y2: 0, w: 0.5 },
  ).length, 2, "a width step must stay its own segment");
  assert.equal(push(
    { x1: 0, y1: 0, x2: 1, y2: 0, w: 0.4 },
    { x1: 1, y1: 0, x2: 1, y2: 1, w: 0.4 },
  ).length, 2, "a bend must never be merged away");
  assert.equal(push(
    { x1: 0, y1: 0, x2: 1, y2: 0, w: 0.4 },
    { x1: 1, y1: 0, x2: 0, y2: 0, w: 0.4 },
  ).length, 2, "a 180-degree retrace is not one segment");
  assert.equal(push(
    { x1: 0, y1: 0, x2: 1, y2: 0, w: 0.4 },
    { x1: 1.001, y1: 0, x2: 2, y2: 0, w: 0.4 },
  ).length, 2, "a gap in the run must not be bridged");
}

{
  const floor = 0.127;
  const target = 0.4;
  const exactLimit = 0.31;
  const attempted = [];
  const g = load([
    "drawAdaptiveClearWidth",
    "drawAdaptiveProbePath",
    "drawAdaptiveExactClearWidth",
    "drawAdaptiveRefinedClearWidth",
  ], {
    drcGate: { ready: true, failed: false },
    segViolation(_x1, _y1, _x2, _y2, _layer, _net, hw) {
      return 2 * hw > 0.18 ? { k: "conservative pad box" } : null;
    },
    drcGateBlocks(_tracks, _vias, paths) {
      const width = paths[0].samples[0][2];
      attempted.push(width);
      return width > exactLimit + 1e-9;
    },
  });
  const a = { x: 0, y: 0 };
  const b = { x: 0.05, y: 0 };
  const fast = g.drawAdaptiveClearWidth(a, b, 1, "V_12V", floor, target, []);
  const fitted = g.drawAdaptiveRefinedClearWidth(a, b, 1, "V_12V", floor, target, []);
  assert(fast < 0.181, "the fixture must reproduce the conservative fast-probe cap");
  assert(fitted > exactLimit - 0.0022 && fitted <= exactLimit + 1e-9,
    "each interval must grow past a conservative preview cap to its exact DRC-clean maximum");
  assert(attempted.includes(target), "the exact fitter must try the desired width first");
  assert(attempted.length <= 9, "a blocked interval must converge to about 0.002 mm with a bounded binary search");
}

{
  const existingTrack = { id: "existing" };
  const existingPart = { ref: "U1" };
  let baselineRuns = 0;
  let candidateRuns = 0;
  const g = load(["drawAdaptiveProbePath", "drawAdaptiveIntervalBlocker"], {
    drcGate: { ready: true, failed: false },
    PCB: { tracks: [existingTrack], vias: [], rf_paths: [] },
    P: [existingPart],
    drcGateScope(bt, bv) {
      return { bt, bv, at: bt, av: bv, parts: [existingPart], brf: [] };
    },
    drcGateRun(_tracks, _vias, _parts, paths) {
      if (paths.length) candidateRuns++;
      else baselineRuns++;
      return [];
    },
    drcBlockCounts() { return {}; },
  });
  const cache = {};
  const a = { x: 0, y: 0 };
  const b = { x: 0.05, y: 0 };
  const first = g.drawAdaptiveIntervalBlocker(a, b, 1, "V_12V", 0.4, cache);
  const second = g.drawAdaptiveIntervalBlocker(a, b, 1, "V_12V", 0.4, cache);
  assert.equal(first(g.drawAdaptiveProbePath(a, b, 1, "V_12V", 0.4)), false);
  assert.equal(second(g.drawAdaptiveProbePath(a, b, 1, "V_12V", 0.3)), false);
  assert.equal(baselineRuns, 1, "identical local scopes must reuse their unchanged DRC baseline");
  assert.equal(candidateRuns, 2, "each proposed interval width must still receive its own exact DRC run");
}

{
  const g = load(["drawCompactTaperProfile"]);
  const wide = { kind: "rf", width: 0.6, land: 0.2, taper: 0.48, step: 0.08, portal: { id: 1 } };
  const compact = g.drawCompactTaperProfile(wide, 0.4, 0.25);
  assert.equal(compact.taper, 0.12, "a blocked wide-land flare must be shortened by the requested scale");
  assert.equal(compact.step, 0.02, "compaction must retain the taper's sampling density");
  assert.equal(compact.portal, wide.portal, "compaction must preserve the pad-contained portal collar");
  assert.notEqual(compact, wide, "compaction must not mutate the full-size preview profile");
  const narrow = { kind: "rf", width: 0.2, taper: 0.48, step: 0.08 };
  assert.equal(g.drawCompactTaperProfile(narrow, 0.4, 0.25), narrow,
    "a narrow-land taper must not be shortened toward a wider, less-clear trace");
}

{
  const PCB = { vias: [{ x: 0, y: 0, d: 0.6, net: "RF" }], rules: { min_width: 0.1, track_width: 0.2 } };
  const globals = {
    PCB,
    netClassInfo() { return { width: 0.2, impedance_ohms: 50, diff_impedance_ohms: 0 }; },
    baseTrackW() { return 0.2; },
  };
  const g = load(["drawSamePointXY", "drawEndpointVia", "drawPathPadLaunch", "drawTaperProfile"], globals);
  const via = g.drawEndpointVia("RF", 0, 0);
  assert(via?.via, "a through-via must resolve as an RF taper endpoint");
  assert.equal(g.drawEndpointVia("OTHER", 0, 0), null, "a foreign via must not become this net's endpoint");
  const launch = g.drawPathPadLaunch(null, via, true);
  assert.equal(launch.span, 0.6);
  assert.equal(launch.land, 0.3);
  const profile = g.drawTaperProfile("RF", via, 0.2, launch);
  assert.equal(profile.width, 0.6, "the flare must meet the through-via's actual copper diameter");
  assert.equal(profile.land, 0.3, "the via diameter must be held through the annulus edge");
  assert.equal(profile.taper, 0.24);
  assert.equal(profile.portal, null, "a circular via needs no rectangular pad collar");
}

{
  const PCB = { vias: [{ x: 0, y: 0, d: 0.6, net: "RF" }], rules: { min_width: 0.1, track_width: 0.2 } };
  let nextId = 0;
  const globals = {
    PCB,
    netClassInfo() { return { width: 0.2, impedance_ohms: 50, diff_impedance_ohms: 0 }; },
    baseTrackW() { return 0.2; },
    trackArcGeom() { return null; },
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    trackChords(t) { return [t]; },
    trackIdEnsure(t) { return t.id || (t.id = `t${++nextId}`); },
    trackIdNew() { return `s${++nextId}`; },
  };
  const g = load([
    "drawSamePointXY", "drawEndpointVia", "drawPathPadLaunch", "drawTaperProfile",
    "drawProfileWidth", "drawTrackPoint", "drawTrackPiece", "drawTaperTracks", "drawTaperPath",
    "drawTaperPortalPath", "drawSamePortalPath", "drawTaperPathSet", "drawRfTaperPlan",
  ], globals);
  const plan = g.drawRfTaperPlan([
    { x1: -2, y1: 0, x2: 0, y2: 0, l: 0, w: 0.2, net: "RF" },
    { x1: 0, y1: 0, x2: 2, y2: 0, l: 1, w: 0.2, net: "RF" },
  ], null, null, 0.2);
  assert.equal(plan.paths.length, 2, "a layer transition must get one taper path on each connected face");
  assert.equal(plan.paths[0].samples.at(-1)[2], 0.6, "the incoming face must widen into the via");
  assert.equal(plan.paths[1].samples[0][2], 0.6, "the outgoing face must leave at the via diameter");
  assert(plan.paths.every((path) => new Set(path.samples.map((s) => s[2])).size > 1),
    "both via faces must carry a real variable-width transition");
}

{
  const track = { id: "via-run", x1: 0, y1: 0, x2: 2, y2: 0, l: 0, w: 0.2, net: "RF" };
  const PCB = { tracks: [track], vias: [{ x: 0, y: 0, d: 0.6, net: "RF" }] };
  let seededVia = null;
  const globals = {
    PCB,
    P: [],
    drawEndpointPad() { return null; },
    netClassInfo() { return { width: 0.2, impedance_ohms: 50, diff_impedance_ohms: 0 }; },
    baseTrackW() { return 0.2; },
    trackIdEnsure(t) { return t.id; },
    rfOwnsTrack() { return false; },
    drawTrackEndDirection() { return { x: 1, y: 0 }; },
    drawTaperProfile(_net, land) { return land?.via ? { width: land.via.d } : null; },
    drawRfRetrofitRun(_track, _reverse, _nominal, land) {
      seededVia = land;
      return [{ net: "RF", l: 0, samples: [[0, 0, 0.6], [1, 0, 0.2]] }];
    },
  };
  const g = load([
    "drawSamePointXY", "drawEndpointVia", "drawEndpointLand", "drawReverseTrack", "drawRfRetrofitGroups",
  ], globals);
  const groups = g.drawRfRetrofitGroups();
  assert.equal(groups.length, 1, "saved nominal-width copper must seed a retrofit from its through-via endpoint");
  assert.equal(seededVia?.via, PCB.vias[0]);
}

{
  const g = load(["segsCross", "polySelfIntersects", "polyContains", "rfRingFolded", "rfFallbackRegions"]);
  const points = [
    [143.96, 105.45],
    [144.22, 105.45],
    [144.22, 105.5],
  ];
  const widths = [0.56, 0.56, 0.56];
  const folded = [
    [143.96, 105.73],
    [143.94, 105.73],
    [143.94, 105.5],
    [144.5, 105.5],
    [144.5, 105.17],
    [143.96, 105.17],
  ];
  assert(g.polySelfIntersects(folded), "ADF terminal-jog fixture must fold");
  const regions = g.rfFallbackRegions(points, widths, folded);
  assert.equal(regions.length, 3);
  assert(!regions.some(g.polySelfIntersects), "fallback regions must stay simple");
  assert(regions.some((polygon) => g.polyContains(polygon, 144.0, 105.55)), "fallback clipped valid earlier copper");
  assert(g.rfRingFolded([[0, 0], [2, 0], [1, 0], [1, 1], [0, 1]]), "collinear retrace must lower through the fallback");
}

{
  const g = load(["rfCleanSamples", "rfRingFolded", "rfFallbackRegions", "rfCompactRing"]);
  const cleaned = g.rfCleanSamples([
    [0, 0, 0.2],
    [0, 0, 0.4],
    [1, 0, 0.3],
    [1, 0, 0.1],
  ]);
  assert.equal(cleaned.pts.length, 2, "consecutive duplicate stations must collapse");
  assert.equal(cleaned.ws[0], 0.4, "a collapsed station must retain its widest copper");
  assert.equal(cleaned.ws[1], 0.3, "the max-width merge must apply at every station");
  const ring = g.rfCompactRing(cleaned.pts, cleaned.ws);
  assert.equal(ring.length, 4, "a cleaned straight run must retain a compact ring");
  assert(ring.every((point) => point.every(Number.isFinite)), "cleaned compact geometry must stay finite");
  assert.equal(g.rfFallbackRegions(cleaned.pts, cleaned.ws, ring).length, 1);

  const coincident = g.rfCleanSamples([
    [2, 3, 0.1],
    [2, 3, 0.5],
    [2, 3, 0.25],
  ]);
  assert.equal(coincident.pts.length, 1, "an all-coincident path must collapse to one station");
  assert.equal(coincident.ws[0], 0.5, "all-coincident cleaning must retain the maximum width");
  assert.equal(g.rfCompactRing(coincident.pts, coincident.ws).length, 0, "an all-coincident path must not emit a ring");
  assert.equal(g.rfFallbackRegions(coincident.pts, coincident.ws, []).length, 0, "an all-coincident path must not emit fallback copper");
}

{
  // Barracuda F4.1 is 0.55 mm wide across the route but only 0.25 mm long.
  // Its adjacent F4.2 ground land begins 0.375 mm behind the RF pad centre.
  // The old max-width capsule invented a 0.275 mm round cap and saw only a
  // 0.100 mm gap; the actual butt-ended taper is comfortably clear at 0.127 mm.
  const P = [{ side: "top", pads: [{ net: "GND" }] }];
  const g = load([
    "polyContains", "ptSegDist", "segSegDist", "rfCleanSamples", "rfRingFolded",
    "rfFallbackRegions", "rfCompactRing", "drawPolyRectGap", "drawTaperPathsPadViolation",
  ], {
    P,
    netClrFor() { return 0.127; },
    sameNet(a, b) { return a && b && a === b; },
    wrect() { return { x0: -0.625, y0: -0.275, x1: -0.375, y1: 0.275 }; },
  });
  const path = [{ net: "LO1_DRIVE", l: 0, samples: [
    [0, 0, 0.55], [0.125, 0, 0.55], [0.353, 0, 0.19], [1, 0, 0.19],
  ] }];
  assert(!g.drawTaperPathsPadViolation(path, 0, "LO1_DRIVE"),
    "F4.1's exact butt-ended taper must clear the adjacent F4.2 ground land");
}

{
  const { buildDrcInput } = require("../src/serve/assets/drc_marshal.js");
  const PCB = {
    tracks: [{ id: "old", x1: 0, y1: 0, x2: 1, y2: 0, l: 0, w: 0.2, net: "RF" }],
    rf_paths: [{ net: "RF", l: 0, track_ids: ["old"], samples: [[0, 0, 0.3], [1, 0, 0.2]] }],
  };
  const candidateTrack = { id: "new", x1: 2, y1: 0, x2: 3, y2: 0, l: 0, w: 0.2, net: "RF" };
  const candidatePath = { net: "RF", l: 0, track_ids: ["new"], samples: [[2, 0, 0.4], [3, 0, 0.2]] };
  const input = buildDrcInput(PCB, { tracks: [candidateTrack], rf_paths: [candidatePath] });
  assert.equal(input.tracks.length, 1, "an explicit trial RF path must replace its own compact handle");
  assert.equal(input.tracks[0].x1, 2);
  assert.equal(input.tracks[0].w, 0.4);
}

{
  const globals = {
    PCB: { rules: { min_width: 0.1 } },
    wpt(_i, x, y) {
      return { x, y };
    },
    drawReverseTrack(t) {
      return { x1: t.x2, y1: t.y2, x2: t.x1, y2: t.y1, l: t.l || 0, w: t.w, net: t.net || "" };
    },
    trackChords(t) {
      return [t];
    },
    trackLength(t) {
      return Math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    },
    netClassInfo() {
      return { width: 0.18993671363271875, impedance_ohms: 50 };
    },
    baseTrackW() {
      return 0.18993671363271875;
    },
  };
  const g = load(["drawPadFrame", "drawPadPortal", "drawPathPadLaunch", "drawTaperProfile", "drawTaperPortalPath", "drawSamePortalPath"], globals);
  const points = [
    [149.70000000000002, 104.98],
    [149.70000000000002, 105],
    [149.66193976625587, 105.19134171618309],
    [149.63390958983942, 105.24844006892205],
    [149.6145384401762, 105.27956731142432],
    [149.59293848866537, 105.30919143604933],
    [149.56922586931807, 105.33715316612384],
    [149.55355339059363, 105.3535533905945],
    [149.5435280750872, 105.36330216298292],
    [149.51598327239037, 105.38749783427886],
    [149.48673955824634, 105.40961008988818],
    [149.39134171618286, 105.4619397662577],
    [149.20000000000002, 105.500000000003],
  ];
  const tracks = points.slice(1).map((point, i) => ({
    x1: points[i][0],
    y1: points[i][1],
    x2: point[0],
    y2: point[1],
    l: 0,
    w: 0.18335412052887323,
    net: "DIV_RAW",
  }));
  const pad = { i: 0, pd: { x: points[0][0], y: points[0][1], w: 0.56, h: 0.62, rot: 90, shape: "roundrect" } };
  const launch = g.drawPathPadLaunch(tracks, pad, true);
  assert(launch?.portal);
  assert(launch.land > 0.28 && launch.land < 0.31, `wrong path land ${launch.land}`);
  const collar = g.drawTaperPortalPath({ kind: "rf", portal: launch.portal }, tracks[0], tracks[0].w);
  const [a, b] = collar.samples;
  assert(Math.abs(Math.hypot(b[0] - a[0], b[1] - a[1]) - 0.24) < 1e-7, "collar capsule must fit inside the roundrect flat face");
  assert.equal(a[2], 0.1, "collar must meet the fabrication minimum width");
  const oldMid = { x: (launch.portal.a.x + launch.portal.b.x) / 2, y: (launch.portal.a.y + launch.portal.b.y) / 2 };
  const newMid = { x: (a[0] + b[0]) / 2, y: (a[1] + b[1]) / 2 };
  assert(Math.abs(newMid.x - (oldMid.x - launch.portal.out.x * 0.05)) < 1e-7);
  assert(Math.abs(newMid.y - (oldMid.y - launch.portal.out.y * 0.05)) < 1e-7,
    "collar centreline must move inward by its probe radius");
  assert(g.drawSamePortalPath(collar, { net: collar.net, l: collar.l, samples: [b, a] }), "reversed saved collar must be recognized after reload");
  assert(!g.drawSamePortalPath(collar, { net: "OTHER", l: 0, samples: [b, a] }), "another net must not suppress a collar");
  assert(!g.drawSamePortalPath(collar, { net: collar.net, l: 1, samples: [b, a] }), "another layer must not suppress a collar");

  for (const shape of ["rect", "roundrect", "oval"])
    assert(g.drawPadFrame({ i: 0, pd: { x: 0, y: 0, w: 1, h: 0.6, shape } }).portalOk, `${shape} must expose a flat portal`);
  for (const shape of ["circle", "custom"])
    assert(!g.drawPadFrame({ i: 0, pd: { x: 0, y: 0, w: 1, h: 0.6, shape } }).portalOk, `${shape} must not expose a flat portal`);
  assert(!g.drawPadFrame({ i: 0, pd: { x: 0, y: 0, w: 1, h: 0.6, shape: "rect", poly: [[0, 0], [1, 0], [0, 1]] } }).portalOk,
    "a custom polygon must not borrow the rectangular portal model");

  const square = { i: 0, pd: { x: 0, y: 0, w: 0.5, h: 0.5, shape: "roundrect" } };
  const diagonal = g.drawPathPadLaunch([{ x1: 0, y1: 0, x2: 1, y2: 1 }], square, true);
  assert.equal(diagonal.span, 0, "a 45-degree square-pad exit must not acquire the sqrt(2) centre-chord flare");
  const horizontal = g.drawPathPadLaunch([{ x1: 0, y1: 0, x2: 1, y2: 0 }], square, true);
  assert(Math.abs(horizontal.span - 0.5) < 1e-9, "an orthogonal square-pad exit must retain its full face width");

  const nominal = 0.18993671363271875;
  const c127 = { i: 0, pd: { w: 0.5, h: 0.3, shape: "roundrect" } };
  const c127Profile = g.drawTaperProfile("RF", c127, nominal,
    { land: 0.212, span: 0.02828427124745862, portal: null });
  assert(Math.abs(c127Profile.width - 0.3) < 1e-9,
    "C127's near-corner chord must taper from its 0.3 mm pad instead of pinching or disappearing");
  const narrow = { i: 0, pd: { w: 0.1, h: 0.3, shape: "roundrect" } };
  const narrowProfile = g.drawTaperProfile("RF", narrow, nominal,
    { land: 0.15, span: 0.028, portal: null });
  assert(Math.abs(narrowProfile.width - 0.1) < 1e-9,
    "a genuinely narrow land must still taper to its physical minimum dimension, not its corner chord");
}

{
  const track = { id: "seg-owner", net: "RF", l: 0, x1: 0, y1: 0, x2: 1, y2: 0 };
  const PCB = { tracks: [], vias: [], rf_paths: [
    { net: "RF", l: 0, track_ids: ["seg-owner"], samples: [[0, 0, 0.2], [1, 0, 0.2]] },
    { net: "RF", l: 0, portal: true, track_ids: ["seg-owner"], samples: [[0.5, -0.2, 0.1], [0.5, 0.2, 0.1]] },
    { net: "RF", l: 0, track_ids: ["seg-other"], samples: [[2, 0, 0.2], [3, 0, 0.2]] },
  ] };
  const g = load([
    "rfPathOwnsTrack", "rfOwnsTrack", "rfPathBelongsToTrack", "rfPathPower", "rfPathBakeWidth",
    "rfBakePath", "rfWasIndex", "rfDropForTracks", "cloneCopper",
  ], {
    PCB,
    cuGeomDrop() {},
    netClassInfo() { return { impedance_ohms: 50 }; },
    trackIdEnsure(t) { return t.id; },
    viaIdEnsure(v) { return v.id; },
  });
  assert(g.rfPathOwnsTrack(PCB.rf_paths[0], track), "main path must own its editor handle");
  assert(!g.rfPathOwnsTrack(PCB.rf_paths[1], track), "collar alone must not hide an editor handle");
  assert(g.rfPathBelongsToTrack(PCB.rf_paths[1], track), "collar must retain lifecycle membership through its owner id");
  assert(g.rfOwnsTrack(track), "a main path must hide its owned editor handle even when a collar shares the id");
  assert(g.cloneCopper().rf_paths[1].portal, "undo snapshots must preserve collar identity");
  g.rfDropForTracks([track]);
  assert.equal(PCB.rf_paths.length, 1, "editing a main route must drop its collar atomically without touching unrelated RF copper");
  assert.equal(PCB.rf_paths[0].track_ids[0], "seg-other");
}

{
  const t1 = { id: "leg-a", net: "RF", l: 0, x1: 0, y1: 0, x2: 5, y2: 0 };
  const t2 = { id: "leg-b", net: "RF", l: 0, x1: 5, y1: 0, x2: 5, y2: 5 };
  const arc = { id: "fillet", net: "RF", l: 0, x1: 4, y1: 0,
    xm: 4 + Math.SQRT1_2, ym: 1 - Math.SQRT1_2, x2: 5, y2: 1 };
  const main = { net: "RF", l: 0, track_ids: [t1.id, t2.id], samples: [
    [0, 0, 0.6], [1, 0, 0.2], [5, 0, 0.2], [5, 4, 0.2], [5, 5, 0.5],
  ] };
  const collar = { net: "RF", l: 0, portal: true, track_ids: [t1.id, t2.id],
    samples: [[-0.1, -0.2, 0.1], [-0.1, 0.2, 0.1]] };
  const unrelated = { net: "RF", l: 0, track_ids: ["elsewhere"], samples: [[8, 0, 0.2], [9, 0, 0.2]] };
  const g = load([
    "trackArcGeom", "trackChords", "drawTrackPoint", "rfPathOwnsTrack", "rfPathBelongsToTrack",
    "traceFilletRfLocate", "traceFilletRfWidth", "traceFilletRfPush", "traceFilletRfCopy",
    "traceFilletRfPath", "traceFilletRfPaths",
  ]);
  const paths = g.traceFilletRfPaths([main, collar, unrelated], [t1, t2], {
    corner: { x: 5, y: 0 }, arc,
  });
  assert.equal(paths.length, 3, "a valid fillet must retain the main taper, its pad collar, and unrelated RF copper");
  assert.equal(paths[2], unrelated, "unrelated RF geometry must not be rewritten");
  assert.deepEqual(Array.from(paths[0].track_ids), [t1.id, t2.id, arc.id], "the new native arc must join the taper lifecycle");
  assert.equal(paths[0].samples[0][2], 0.6, "the first pad taper width must survive the fillet");
  assert.equal(paths[0].samples.at(-1)[2], 0.5, "the second pad taper width must survive the fillet");
  assert(!paths[0].samples.some((s) => Math.hypot(s[0] - 5, s[1]) < 1e-9), "the old sharp corner must leave the swept path");
  assert(paths[0].samples.some((s) => s[0] > 4.1 && s[0] < 4.9 && s[1] > 0.1 && s[1] < 0.9),
    "the transformed width profile must follow interior stations of the fillet arc");
  assert.deepEqual(Array.from(paths[1].track_ids), [t1.id, t2.id, arc.id], "the retained pad collar must share arc invalidation");
  assert.deepEqual(paths[1].samples, collar.samples, "filleting a remote corner must not move the pad-contained collar");

  const reverse = { ...main, samples: main.samples.slice().reverse().map((s) => s.slice()) };
  const reversed = g.traceFilletRfPaths([reverse], [t1, t2], { corner: { x: 5, y: 0 }, arc })[0];
  assert.equal(reversed.samples[0][2], 0.5, "reverse-authored routes must keep their first landing taper");
  assert.equal(reversed.samples.at(-1)[2], 0.6, "reverse-authored routes must keep their far landing taper");
  assert(!reversed.samples.some((s) => Math.hypot(s[0] - 5, s[1]) < 1e-9),
    "reverse-authored routes must also replace the sharp corner with the fillet");
}

{
  let acceptAnyPad = false;
  let ownsLegacyTrack = false;
  let launchCalls = 0;
  const PCB = { rules: { min_width: 0.1, track_width: 0.2 }, tracks: [], rf_paths: [] };
  const globals = {
    PCB,
    netClassInfo() { return { impedance_ohms: 50, diff_impedance_ohms: 0, width: 0.2 }; },
    baseTrackW() { return 0.2; },
    drawEndpointPad(_net, _layer, x, y) {
      return (acceptAnyPad || (Math.abs(x) < 1e-9 && Math.abs(y) < 1e-9)) ? { pd: {} } : null;
    },
    drawPathPadLaunch() {
      launchCalls++;
      return { portal: { a: { x: -0.2, y: 0 }, b: { x: 0.2, y: 0 } } };
    },
    rfPathOwnsTrack() { return ownsLegacyTrack; },
    trackIdEnsure(t) { return t.id; },
  };
  const g = load(["drawTaperPortalPath", "drawSamePortalPath", "drawRfMissingPortalGroups"], globals);

  const legacy = { net: "RF", l: 0, samples: [[0, 0, 0.4], [1, 0, 0.2]] };
  PCB.rf_paths = [legacy];
  let groups = g.drawRfMissingPortalGroups();
  assert.equal(groups.length, 1, "an RF-path-only legacy launch must receive a collar");
  assert.equal(groups[0].length, 1);
  assert(groups[0][0].portal, "a migrated collar must be tagged for lifecycle handling");
  PCB.rf_paths.push(groups[0][0]);
  assert.equal(g.drawRfMissingPortalGroups().length, 0, "migration must be idempotent after its collar is present");

  launchCalls = 0;
  acceptAnyPad = true;
  PCB.rf_paths = [{ net: "RF", l: 0, portal: true, samples: [[0, 0, 0.1], [0, 1, 0.1]] }];
  assert.equal(g.drawRfMissingPortalGroups().length, 0, "a portal path must never become a migration source");
  assert.equal(launchCalls, 0, "portal-source rejection must happen before launch reconstruction");

  acceptAnyPad = false;
  ownsLegacyTrack = true;
  const ownedTrack = { id: "legacy-owner", net: "RF", l: 0 };
  const ownedLegacy = { net: "RF", l: 0, samples: [[4, 0, 0.2], [5, 0, 0.2]] };
  PCB.tracks = [ownedTrack];
  PCB.rf_paths = [ownedLegacy];
  assert.equal(g.drawRfMissingPortalGroups().length, 0);
  assert.equal(ownedLegacy.track_ids.length, 1, "a geometrically owned legacy main path should acquire stable track ids");
  assert.equal(ownedLegacy.track_ids[0], "legacy-owner");
}

// An adaptive power overlay is the ONLY record of a rail's real width, and
// nothing regenerates it: dropping one has to leave that width on the copper.
function loadRfLifecycle(PCB, impedance) {
  return load([
    "rfSamePoint", "rfPathSpanWidth", "rfPathCoversTrack", "rfPathOwnsTrack", "rfOwnsTrack",
    "rfPathBelongsToTrack", "rfPathPower", "rfPathBakeWidth", "rfBakePath", "rfPathOwnsAny",
    "rfWasIndex", "rfDropForTracks", "rfLoadBake",
  ], {
    PCB,
    cuGeomDrop() {},
    netClassInfo(net) { return impedance.includes(net) ? { impedance_ohms: 50 } : null; },
    segDist(px, py, t) {
      const dx = t.x2 - t.x1, dy = t.y2 - t.y1, l2 = dx * dx + dy * dy;
      const f = l2 > 0 ? Math.max(0, Math.min(1, ((px - t.x1) * dx + (py - t.y1) * dy) / l2)) : 0;
      return Math.hypot(px - (t.x1 + dx * f), py - (t.y1 + dy * f));
    },
  });
}

{
  const a = { id: "a", net: "V_5VA", l: 0, x1: 0, y1: 0, x2: 1, y2: 0, w: 0.127 };
  const b = { id: "b", net: "V_5VA", l: 0, x1: 1, y1: 0, x2: 2, y2: 0, w: 0.127 };
  const rf = { id: "r", net: "LO1", l: 0, x1: 5, y1: 0, x2: 6, y2: 0, w: 0.19 };
  const PCB = {
    tracks: [a, b, rf],
    rf_paths: [
      { net: "V_5VA", l: 0, track_ids: ["a", "b"],
        samples: [[0, 0, 0.2], [0.5, 0, 0.6], [1, 0, 0.3], [2, 0, 0.25]] },
      { net: "LO1", l: 0, track_ids: ["r"], samples: [[5, 0, 0.4], [6, 0, 0.19]] },
    ],
  };
  const g = loadRfLifecycle(PCB, ["LO1"]);
  g.rfDropForTracks([a]);
  assert.equal(PCB.rf_paths.length, 1, "editing one segment must retire its whole power overlay");
  assert(Math.abs(a.w - 0.6) < 1e-12, "the dragged segment must keep the widest copper it actually had");
  assert(Math.abs(b.w - 0.3) < 1e-12, "every other segment of the run must keep ITS width, not the run maximum");
  g.rfDropForTracks([rf]);
  assert.equal(PCB.rf_paths.length, 0);
  assert(Math.abs(rf.w - 0.19) < 1e-12,
    "a controlled-impedance handle must stay at its class width — Route regenerates that taper");
}

{
  // A segment drag moves its attached neighbours BEFORE the overlay is
  // released, so the bake reads the drag snapshot's pre-gesture geometry.
  const a = { id: "a", net: "V_5VA", l: 0, x1: 0, y1: 0, x2: 1, y2: 0, w: 0.127 };
  const b = { id: "b", net: "V_5VA", l: 0, x1: 1, y1: 0.4, x2: 2, y2: 0.4, w: 0.127 };
  const PCB = { tracks: [a, b], rf_paths: [
    { net: "V_5VA", l: 0, track_ids: ["a", "b"], samples: [[0, 0, 0.5], [1, 0, 0.5], [2, 0, 0.32]] },
  ] };
  const g = loadRfLifecycle(PCB, []);
  const was = [
    { id: "a", net: "V_5VA", l: 0, x1: 0, y1: 0, x2: 1, y2: 0 },
    { id: "b", net: "V_5VA", l: 0, x1: 1, y1: 0, x2: 2, y2: 0 },
  ];
  g.rfDropForTracks([a, b], was);
  assert(Math.abs(a.w - 0.5) < 1e-12, "the grabbed segment bakes from its pre-drag span");
  assert(Math.abs(b.w - 0.5) < 1e-12, "an already-stretched neighbour must still bake, not silently revert");
}

{
  // One open of a pre-adaptive board heals it: widths onto the copper, overlay
  // and exact-probe debris gone, controlled-impedance proofs untouched.
  const power = { id: "p", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 2, y2: 0, w: 0.127 };
  const rf = { id: "r", net: "LO1", l: 0, x1: 5, y1: 0, x2: 6, y2: 0, w: 0.19 };
  const keep = { net: "LO1", l: 0, track_ids: ["r"], samples: [[5, 0, 0.4], [5.2, 0, 0.19], [6, 0, 0.19]] };
  const collar = { net: "LO1", l: 0, portal: true, track_ids: ["r"], samples: [[5, -0.2, 0.1], [5, 0.2, 0.1]] };
  const PCB = {
    tracks: [power, rf],
    rf_paths: [
      { net: "V_12V", l: 0, track_ids: ["p"], samples: [[0, 0, 0.45], [1, 0, 0.45], [2, 0, 0.45]] },
      { net: "LO1", l: 0, track_ids: [], samples: [[9, 0, 0.3], [9.5, 0, 0.3]] },
      keep, collar,
    ],
  };
  const g = loadRfLifecycle(PCB, ["LO1"]);
  g.rfLoadBake();
  assert.equal(PCB.rf_paths.length, 2, "power overlays and orphan probe debris must not survive the load");
  assert.equal(PCB.rf_paths[0], keep, "a controlled-impedance taper must be kept verbatim");
  assert.equal(PCB.rf_paths[1], collar, "a two-sample pad collar owns no handle and must still be kept");
  assert(Math.abs(power.w - 0.45) < 1e-12, "the healed rail keeps its physical width as ordinary copper");
  assert(Math.abs(rf.w - 0.19) < 1e-12, "healing must not touch controlled-impedance handles");
  g.rfLoadBake();
  assert.equal(PCB.rf_paths.length, 2, "a healed board must reload idempotently");
}

{
  // Zero-length crumbs are copper no contact predicate can join, so the server
  // reports them as phantom islands. The gesture that made one culls it.
  const main = { id: "m", x1: 0, y1: 0, x2: 1, y2: 0 };
  const crumb = { id: "c", x1: 2, y1: 2, x2: 2, y2: 2 };
  const live = { id: "n", x1: 1, y1: 0, x2: 1, y2: 1 };
  const jog = { id: "j", x1: 3, y1: 3, x2: 3, y2: 3 };
  const PCB = { tracks: [main, crumb, live, jog] };
  const g = load(["segCrumbClean"], {
    PCB,
    gpuCuEdit() {},
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
  });
  g.segCrumbClean({ t: main, moved: false, a: { jog, at: [{ q: crumb, e: 1 }] }, b: { jog: null, at: [] } });
  assert.deepEqual(Array.from(PCB.tracks, (t) => t.id), ["m", "c", "n"],
    "a stationary press cleans only the jog it laid — it must not silently delete existing copper");
  PCB.tracks = [main, crumb, live, jog];
  g.segCrumbClean({ t: main, moved: true, a: { jog, at: [{ q: crumb, e: 1 }] }, b: { jog: null, at: [{ q: live, e: 2 }] } });
  assert.deepEqual(Array.from(PCB.tracks, (t) => t.id), ["m", "n"],
    "a real drag culls every zero-length track it touched, followed neighbours included");
  const gone = { id: "g", x1: 4, y1: 4, x2: 4, y2: 4 };
  PCB.tracks = [gone];
  const sd = { t: gone, moved: true, a: { jog: null, at: [] }, b: { jog: null, at: [] } };
  g.segCrumbClean(sd);
  assert.equal(PCB.tracks.length, 0, "a grabbed segment whose own corners met is a crumb too");
}

{
  // A drawn power run commits SHAPED COPPER, not a second representation: the
  // gate judges the real tracks and no overlay is left to go stale.
  const laid = [
    { id: "l1", x1: 0, y1: 0, x2: 1, y2: 0, l: 0, w: 0.127, net: "V_12V" },
    { id: "l2", x1: 1, y1: 0, x2: 2, y2: 0, l: 0, w: 0.127, net: "V_12V" },
  ];
  const other = { id: "o", x1: 9, y1: 9, x2: 9.5, y2: 9, l: 0, w: 0.2, net: "GND" };
  const shaped = [
    { x1: 0, y1: 0, x2: 1, y2: 0, l: 0, w: 0.4, net: "V_12V", source: "human" },
    { x1: 1, y1: 0, x2: 2, y2: 0, l: 0, w: 0.32, net: "V_12V", source: "human" },
  ];
  const overlay = { net: "V_12V", l: 0, track_ids: ["l1", "l2"], samples: [[0, 0, 0.4], [2, 0, 0.32]] };
  const PCB = { tracks: [other, ...laid], vias: [], rf_paths: [] };
  const dtrace = { pair: null, laid: laid.slice(), w: 0.127, powerTarget: 0.4, net: "V_12V", l: 0,
    lx: 2, ly: 0, startPad: null, undo: { tracks: [other], vias: [], rf_paths: [] } };
  const seen = [];
  const planned = [];
  let minted = 0;
  const g = load([
    "drawSamePointXY", "drawCommitShaped", "drawJointProfile", "drawJointNeighbourWidth",
    "drawApplyAutomaticTapers",
  ], {
    PCB,
    dtrace,
    DRAW_JOINT_SNAP: 2e-3,
    drcGate: { ready: true, failed: false },
    drawAdaptiveRefinedClearWidth() {},
    drawEndpointLand() { return null; },
    drawAdaptivePowerPlan(_tracks, startPad, endPad) {
      planned.push({ startPad, endPad });
      return { tracks: shaped, paths: [overlay], maxWidth: 0.4, power: true };
    },
    drawAutomaticTaperPlan() { throw new Error("a power run must not fall back to the impedance planner"); },
    drcGateDiffBlocks(_bt, _bv, after, _av, _brf, arf) { seen.push({ after, arf }); return false; },
    trackIdEnsure(t) { return t.id; },
    trackIdNew() { return `s${++minted}`; },
    cuGeomDrop() {},
    gpuCuEdit() {},
    routeStatMsg() {},
  });
  const out = g.drawApplyAutomaticTapers();
  assert.equal(out.changed, true);
  assert.equal(out.power, true);
  assert.equal(out.paths.length, 0, "a power run must publish no swept overlay at all");
  assert.equal(PCB.rf_paths.length, 0, "the board must carry one representation of that copper");
  assert.deepEqual(Array.from(PCB.tracks, (t) => t.id), ["o", "l1", "l2"],
    "shaped copper replaces the laid handles in place and inherits identical spans' ids");
  assert.deepEqual(Array.from(PCB.tracks, (t) => t.w), [0.2, 0.4, 0.32], "the committed tracks carry the shaped widths");
  assert.equal(minted, 0, "an unchanged span must not churn its track id");
  assert.equal(seen.length, 1);
  assert.deepEqual(Array.from(seen[0].after, (t) => t.w), [0.2, 0.4, 0.32], "the gate must judge the shaped copper");
  assert.equal(seen[0].arf.length, 0, "the gate must not be shown a power overlay it will never commit");
  assert.deepEqual(Array.from(dtrace.laid, (t) => t.w), [0.4, 0.32], "the gesture's laid set follows the copper it committed");
  assert.equal(planned[0].startPad, null, "open copper on its own hands the planner no terminal profile");
  assert.equal(planned[0].endPad, null);

  // The same gesture, finished ON an existing wide rail. No land, one same-net
  // same-layer neighbour: the run has to leave at that trunk's width.
  const rail = { id: "rail", x1: 2, y1: 0, x2: 5, y2: 0, l: 0, w: 0.8, net: "V_12V" };
  PCB.tracks = [other, rail, ...laid];
  PCB.rf_paths = [];
  dtrace.laid = laid.slice();
  planned.length = 0;
  g.drawApplyAutomaticTapers();
  assert.equal(planned[0].startPad, null, "the free start is still free");
  assert(planned[0].endPad?.joint, "the spliced finish must reach the planner as a joint profile");
  assert(Math.abs(planned[0].endPad.width - 0.8) < 1e-12, "that profile carries the trunk's real width");
  assert.equal(planned[0].endPad.land, 0, "the trunk width is met AT the joint");
  assert(Math.abs(planned[0].endPad.taper - 0.2) < 1e-12, "and comes down to target over a 45-degree flank");
}

// Scoped re-widen. An edited adaptive rail heals to the clearance it has NOW,
// so the first thing that has to be right is which copper the recut covers: one
// unambiguous same-net, same-layer chain, ordered head-to-tail however its
// segments were authored.
function loadRewidenWalk(PCB, lands = [], owned = []) {
  return load([
    "drawSamePointXY", "drawReverseTrack", "drawTrackFromPoint",
    "rewidenTarget", "rewidenTrack", "rewidenGrow", "rewidenRun", "rewidenRuns",
  ], {
    PCB,
    RO: false,
    baseTrackW() { return 0.127; },
    netClassInfo(net) { return net.slice(0, 2) === "V_" ? { adaptive_power_width: 0.4 } : null; },
    rfOwnsTrack(t) { return owned.indexOf(t.id) >= 0; },
    trackIdEnsure(t) { return t.id; },
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    drawEndpointLand(net, layer, x, y) {
      return lands.find((l) => l.net === net && Math.hypot(l.x - x, l.y - y) < 1e-9) || null;
    },
  });
}

{
  const a = { id: "a", net: "V_5VA", l: 0, x1: 1, y1: 0, x2: 2, y2: 0, w: 0.127 };
  const b = { id: "b", net: "V_5VA", l: 0, x1: 0, y1: 0, x2: 1, y2: 0, w: 0.127 };
  const c = { id: "c", net: "V_5VA", l: 0, x1: 2, y1: 0, x2: 3, y2: 0, w: 0.127 };
  const d1 = { id: "d1", net: "V_5VA", l: 0, x1: 3, y1: 0, x2: 4, y2: 0, w: 0.127 };
  const d2 = { id: "d2", net: "V_5VA", l: 0, x1: 3, y1: 0, x2: 3, y2: 1, w: 0.127 };
  const foreign = { id: "x", net: "GND", l: 0, x1: 2, y1: 0, x2: 2, y2: 1, w: 0.2 };
  const otherLayer = { id: "lay", net: "V_5VA", l: 1, x1: 1, y1: 0, x2: 1, y2: -1, w: 0.127 };
  const land = { net: "V_5VA", x: 0, y: 0, pd: { w: 0.3, h: 0.3 } };
  const PCB = { rules: { track_width: 0.127, min_width: 0.1 }, tracks: [a, b, c, d1, d2, foreign, otherLayer] };
  const g = loadRewidenWalk(PCB, [land]);

  const runs = g.rewidenRuns([a]);
  assert.equal(runs.length, 1, "one seed identifies one run");
  assert.deepEqual(Array.from(runs[0].tracks, (t) => t.id), ["b", "a", "c"],
    "the run grows both ways from the seed and stops at the branch");
  assert.deepEqual(Array.from(runs[0].run, (t) => [t.x1, t.x2]), [[0, 1], [1, 2], [2, 3]],
    "reverse-authored copper is re-oriented so the planner reads one ordered centreline");
  assert.equal(runs[0].startPad, land, "the land a run starts on supplies its launch profile");
  assert.equal(runs[0].endPad, null, "a branch ends a run without a land");
  assert.equal(runs[0].startJoint, 0, "a land end is governed by its launch profile, never by a joint cap");
  assert.equal(runs[0].endJoint, 0,
    "a T-junction is a normal trunk/branch width step — that terminal stays free");
  assert.equal(runs[0].target, 0.4);
  assert.equal(runs[0].floor, 0.127, "the run recuts against the pen's routing floor");

  const all = g.rewidenRuns(null);
  assert.deepEqual(Array.from(all, (r) => Array.from(r.tracks, (t) => t.id)), [["b", "a", "c"], ["d1"], ["d2"], ["lay"]],
    "a whole-board pass partitions the net's copper by topology alone — the other layer is its own run");
  assert(!all.some((r) => r.tracks.some((t) => t.id === "x")),
    "foreign copper never joins a run through a shared node");
}

{
  const up = { id: "u", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 1, y2: 0, w: 0.127 };
  const dn = { id: "d", net: "V_12V", l: 1, x1: 1, y1: 0, x2: 2, y2: 0, w: 0.127 };
  const viaLand = { net: "V_12V", x: 1, y: 0, via: { d: 0.4 }, pd: { w: 0.4, h: 0.4 } };
  const PCB = { rules: { track_width: 0.127, min_width: 0.1 }, tracks: [up, dn] };
  const g = loadRewidenWalk(PCB, [viaLand]);
  const runs = g.rewidenRuns([up]);
  assert.deepEqual(Array.from(runs[0].tracks, (t) => t.id), ["u"], "a via ends the run it feeds");
  assert.equal(runs[0].endPad, viaLand, "the via's annulus becomes that end's launch profile");
  assert.equal(runs[0].endJoint, 0, "a via barrel covers that corner — no joint cap is synthesized there");
  const both = g.rewidenRuns(null);
  assert.equal(both.length, 2, "a rail crossing layers through a via recuts as one run per face");
  assert(both.every((r) => new Set(r.run.map((t) => t.l)).size === 1), "no run may span two layers");
}

{
  const straight = { id: "s", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 1, y2: 0, w: 0.127 };
  const arc = { id: "arc", net: "V_12V", l: 0, x1: 1, y1: 0, xm: 1.5, ym: 0.2, x2: 2, y2: 0, w: 0.127 };
  const PCB = { rules: { track_width: 0.127, min_width: 0.1 }, tracks: [straight, arc] };
  const g = loadRewidenWalk(PCB, []);
  const run = g.rewidenRuns([straight])[0];
  assert.deepEqual(Array.from(run.tracks, (t) => t.id), ["s"],
    "an authored fillet ends a run — the station sampler would leave chords in its place");
  assert.equal(g.rewidenRuns([arc]).length, 0, "an arc never seeds a recut");
  // The recut cannot touch that fillet, so its width is a hard boundary
  // condition for this run rather than a free edge.
  assert(Math.abs(run.endJoint - 0.127) < 1e-12,
    "a run butted against copper the recut may not reshape must meet that copper's width");
  assert.equal(run.startJoint, 0, "the open end has no neighbour and stays free");

  const owner = { id: "owned", net: "V_12V", l: 0, x1: 1, y1: 0, x2: 2, y2: 0, w: 0.2 };
  PCB.tracks = [straight, owner];
  const excluded = loadRewidenWalk(PCB, [], ["owned"]).rewidenRuns([straight])[0];
  assert.deepEqual(Array.from(excluded.tracks, (t) => t.id), ["s"], "an overlay-owned handle also ends the run");
  assert(Math.abs(excluded.endJoint - 0.2) < 1e-12,
    "every stop that is neither a land nor a branch reports its neighbour's width");
}

{
  // The recut itself, through the planner the pen uses. Growing and shrinking
  // are equally correct: width on an adaptive rail is derived from the clearance
  // it has right now, and the exact gate has the final say either way.
  const floor = 0.127;
  const target = 0.4;
  let limit = () => Infinity;
  let blocked = false;
  let minted = 0;
  const gate = { ready: true, failed: false };
  const gated = [];
  const PCB = { rules: { track_width: floor, min_width: 0.1 }, tracks: [], vias: [], rf_paths: [] };
  const g = load([
    "drawProfileWidth", "drawTrackEndDirection", "drawAdaptiveBendJoint", "drawAdaptiveStations",
    "drawAdaptiveClearWidth",
    "drawAdaptiveExactClearWidth", "drawAdaptiveRefinedClearWidth",
    "drawSamePointXY", "drawShapedPush", "drawAdaptivePowerRun", "drawJointProfile", "drawAdaptivePowerPlan",
    "drawReverseTrack", "drawTrackFromPoint", "drawCommitShaped",
    "rewidenTarget", "rewidenTrack", "rewidenGrow", "rewidenRun", "rewidenRuns", "rewidenSame",
    "rewidenDeclined", "rewidenAtFloor", "rewidenPlan", "rewidenStatus", "rewidenApply", "rewidenHeal",
  ], {
    PCB,
    RO: false,
    DRAW_ADAPTIVE_STEP: 0.05,
    drcGate: gate,
    baseTrackW() { return floor; },
    netClassInfo(net) { return net === "V_12V" ? { adaptive_power_width: target } : null; },
    rfOwnsTrack() { return false; },
    drawEndpointLand() { return null; },
    trackIdEnsure(t) { return t.id; },
    trackIdNew() { return `s${++minted}`; },
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    drawTrackPoint(t, f) { return { x: t.x1 + (t.x2 - t.x1) * f, y: t.y1 + (t.y2 - t.y1) * f }; },
    // The fitter's per-interval probe, reduced to this fixture's obstacle map.
    drawAdaptiveRunClearer() {
      return (p, q, _layer, _net, lo, cap) => Math.max(lo, Math.min(cap, limit((p.x + q.x) / 2)));
    },
    drcGateDiffBlocks(_bt, _bv, after) { gated.push(after); return blocked; },
    cuGeomDrop() {}, gpuCuEdit() {}, ovPaintSoon() {},
  });

  const rail = { id: "rail", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: floor, source: "human" };
  PCB.tracks = [rail];
  assert.deepEqual({ ...g.rewidenStatus() }, { tracks: 1, nets: 1, changed: 1, editable: true },
    "copper under its class target is eligible for a recut");
  assert(g.rewidenHeal([rail]) >= 1, "a released gesture heals the run it moved");
  assert.equal(PCB.tracks.length, 1, "an unobstructed run recuts to one full-width segment");
  assert(Math.abs(PCB.tracks[0].w - target) < 1e-9,
    "a rail left at the routing floor grows back to its electrical target");
  assert.equal(PCB.tracks[0].id, "rail", "an unchanged span keeps its track id");
  assert.equal(g.rewidenStatus().tracks, 0, "the healed rail is no longer under target");
  assert.deepEqual(Array.from(gated.at(-1), (t) => t.w), [target],
    "the gate judges the shaped copper, not an overlay");

  limit = (x) => (x > 1 && x < 2 ? 0.2 : Infinity);
  const wide = { id: "wide", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: target, source: "human" };
  PCB.tracks = [wide];
  assert.equal(g.rewidenStatus().tracks, 0, "copper already at target reads as nothing to grow");
  assert(g.rewidenHeal([wide]) > 1, "an obstacle splits the recut into shaped segments");
  const widths = Array.from(PCB.tracks, (t) => t.w);
  assert(widths.some((w) => w <= 0.2 + 1e-9), "the recut necks down where an obstacle now sits");
  assert(widths.some((w) => Math.abs(w - target) < 1e-9), "clear stretches still carry the full target");
  assert(widths.every((w) => w >= floor - 1e-9), "a recut never goes below the routing floor");
  assert(Math.abs(PCB.tracks[0].x1) < 1e-12 && Math.abs(PCB.tracks.at(-1).x2 - 3) < 1e-12,
    "the recut copper still spans the whole run");

  limit = () => Infinity;
  const fitted = { id: "fit", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: target, source: "human" };
  PCB.tracks = [fitted];
  assert.equal(g.rewidenHeal([fitted]), 0, "a run already at its fitted width is left untouched");
  assert.equal(PCB.tracks[0], fitted, "an unchanged answer must not churn the board's copper");
  assert.equal(fitted.w, target);

  // Nowhere left to widen is an answer too, and it is the floor.
  limit = () => 0.05;
  const crowded = { id: "crowd", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: target, source: "human" };
  PCB.tracks = [crowded];
  assert(g.rewidenHeal([crowded]) >= 1);
  assert(Math.abs(PCB.tracks[0].w - floor) < 1e-9, "a run with no room anywhere recuts down to the routing floor");
  assert.equal(PCB.tracks[0].id, "crowd", "the floor recut keeps the copper's identity");
  const pinned = { id: "pin", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: floor, source: "human" };
  PCB.tracks = [pinned];
  assert.equal(g.rewidenHeal([pinned]), 0, "a run already at the floor with no room does no work");
  assert.equal(PCB.tracks[0], pinned);

  limit = () => Infinity;
  blocked = true;
  const narrow = { id: "narrow", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: floor, source: "human" };
  PCB.tracks = [narrow];
  assert.equal(g.rewidenHeal([narrow]), 0, "a recut the exact gate rejects is not committed");
  assert.equal(PCB.tracks[0], narrow, "gate-rejected copper is left exactly where the gesture put it");
  assert.equal(narrow.w, floor);
  blocked = false;

  const signal = { id: "sig", net: "SDA", l: 0, x1: 5, y1: 0, x2: 6, y2: 0, w: 0.2, source: "human" };
  PCB.tracks = [signal];
  assert.equal(g.rewidenPlan([signal]).runs.length, 0, "a net with no adaptive target is never recut");
  assert.equal(g.rewidenHeal([signal]), 0);
  assert.equal(signal.w, 0.2, "ordinary hand-authored width stays authored");

  PCB.tracks = [narrow];
  gate.ready = false;
  assert.equal(g.rewidenHeal([narrow]), 0, "healing is skipped while the exact gate is unavailable");
  gate.ready = true;
  gate.failed = true;
  assert.equal(g.rewidenHeal([narrow]), 0, "a failed gate degrades to the width the gesture left");
  gate.failed = false;
  g.RO = true;
  assert.equal(g.rewidenHeal([narrow]), 0, "a read-only board is never healed");
  g.RO = false;
  assert.equal(g.rewidenHeal([]), 0, "a gesture that moved no copper does no work");

  const one = { id: "one", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: floor, source: "human" };
  const two = { id: "two", net: "V_12V", l: 0, x1: 0, y1: 5, x2: 3, y2: 5, w: floor, source: "human" };
  PCB.tracks = [one, two];
  g.rewidenHeal([one]);
  assert.equal(PCB.tracks.length, 2);
  assert(Math.abs(PCB.tracks[0].w - target) < 1e-9, "the run the gesture touched heals");
  assert.equal(PCB.tracks[1], two, "a separate run on the same net is not the gesture's business");
  assert.equal(two.w, floor);
  assert(g.rewidenApply(null) >= 1, "the whole-board action covers every adaptive run");
  assert(Math.abs(PCB.tracks[1].w - target) < 1e-9);

  // A recut whose walk stops against copper it may not reshape has to LAND on
  // that copper's width, then flare back to target on its own straight.
  const butt = { id: "butt", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: floor, source: "human" };
  const fillet = { id: "fillet", net: "V_12V", l: 0, x1: 3, y1: 0, xm: 3.5, ym: 0.2, x2: 4, y2: 0, w: 0.127 };
  PCB.tracks = [butt, fillet];
  assert(g.rewidenHeal([butt]) >= 1, "the butted run still recuts");
  const cut = PCB.tracks.filter((t) => t.xm == null);
  assertBendContinuity(cut, "recut butted against a fillet");
  assert.equal(PCB.tracks.filter((t) => t.xm != null).length, 1, "the fillet itself is never reshaped");
  const meets = cut.filter((t) => Math.abs(t.x2 - 3) < 1e-9);
  assert.equal(meets.length, 1);
  assert(Math.abs(meets[0].w - 0.127) < 1e-9,
    `the terminal slice must meet the fillet's 0.127 mm copper (${meets[0].w})`);
  assert(meets[0].x1 >= 3 - 0.05 - 1e-9, "only the slice touching the joint is capped — the flank is inboard");
  assert(cut.some((t) => Math.abs(t.w - target) < 1e-9), "the rest of the run still carries the electrical target");
  assert(cut.every((t) => t.w >= floor - 1e-9), "a joint cap never goes below the routing floor");

  // Three ways in is a trunk/branch step, not a splice: that terminal is free.
  const trunk = { id: "trunk", net: "V_12V", l: 0, x1: 0, y1: 0, x2: 3, y2: 0, w: floor, source: "human" };
  const legA = { id: "legA", net: "V_12V", l: 0, x1: 3, y1: 0, x2: 4, y2: 0, w: 0.127, source: "human" };
  const legB = { id: "legB", net: "V_12V", l: 0, x1: 3, y1: 0, x2: 3, y2: 1, w: 0.127, source: "human" };
  PCB.tracks = [trunk, legA, legB];
  assert(g.rewidenHeal([trunk]) >= 1);
  const teed = PCB.tracks.filter((t) => t.id !== "legA" && t.id !== "legB" && t.x1 < 3);
  assert(teed.every((t) => Math.abs(t.w - target) < 1e-9),
    "a T-junction terminal keeps today's free full-width answer");
}

console.log("RF and power taper geometry probes PASS");
