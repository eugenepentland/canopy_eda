#!/usr/bin/env node
// Behavioral probes for the Assembly Gerber ruler's exact-edge snap geometry.

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

const visible = { visible: true, ops: [
  ["f", 0, 0, 0, 2, 2, true],
  ["f", 5, 0, 1, 2, 1, true],
  ["l", 10, 0, 13, 0, 0.4, true],
  ["a", 18, 0, 17, 1, 17, 0, 0.2, true, true],
  ["r", true, [[22, 0], [24, 0], [24, 2], [22, 2]]],
] };
const hidden = { visible: false, ops: [["f", 30, 0, 0, 2, 2, true]] };
const PCB = { cam: { source: "generated-gerber", layers: [visible, hidden] } };
const context = vm.createContext({
  assert,
  PCB,
  PHYSICAL_REVIEW: true,
  CAM_REVIEW: true,
  RULER_CAM_CELL: 2,
  rulerCamCache: null,
  S: 10,
  vb: { w: 100, h: 50 },
  svgMetricsGet() { return { cw: 1000, ch: 500 }; },
  camPayloadReady() { return true; },
  camLayerVisible(layer) { return layer.visible; },
});
const names = [
  "rulerSegNearest", "rulerCircleNearest", "rulerCapsuleNearest", "rulerAngleNorm",
  "rulerArcNearest", "rulerFeatureNearest", "rulerCamFeatures", "rulerCamSnap",
];
vm.runInContext(names.map(functionSource).join("\n"), context);

function near(actual, expected, message, tolerance = 1e-9) {
  assert(Math.abs(actual - expected) <= tolerance,
    `${message}: got ${actual}, expected ${expected}`);
}

let q = context.rulerCamSnap({ x: 1.06, y: 0 });
near(q.x, 1, "circular flash snaps to its aperture edge");
near(q.y, 0, "circular flash keeps the radial point");

q = context.rulerCamSnap({ x: 5, y: 0.56 });
near(q.x, 5, "rectangular flash keeps the projected coordinate");
near(q.y, 0.5, "rectangular flash snaps to its nearest side");

q = context.rulerCamSnap({ x: 11.5, y: 0.26 });
near(q.x, 11.5, "stroked segment keeps the along-track coordinate");
near(q.y, 0.2, "stroked segment snaps to its aperture boundary");

q = context.rulerCamSnap({ x: 17 + 1.06 / Math.sqrt(2), y: 1.06 / Math.sqrt(2) });
near(q.x, 17 + 1.1 / Math.sqrt(2), "clockwise Gerber arc snaps to its outer edge");
near(q.y, 1.1 / Math.sqrt(2), "clockwise Gerber arc respects its sweep");

q = context.rulerCamSnap({ x: 21.94, y: 1 });
near(q.x, 22, "Gerber region snaps to its polygon edge");
near(q.y, 1, "Gerber region keeps the edge projection");

assert.equal(context.rulerCamSnap({ x: 31.04, y: 0 }), null,
  "hidden CAM layers must not attract the ruler");
assert.equal(context.rulerCamFeatures().features.length, 12,
  "all flash, stroke, arc, and region boundary primitives are indexed once");

console.log("gerber_measure_snap: exact visible CAM edge snapping passed");
