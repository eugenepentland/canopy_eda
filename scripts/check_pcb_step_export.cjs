#!/usr/bin/env node
// Deterministic interoperability smoke test for the browser STEP writer.
// It builds closed and open fixtures entirely in memory, then feeds the
// resulting AP242 bytes back through the same OpenCascade parser used by the
// PCB 3D viewer.  Run with: node scripts/check_pcb_step_export.cjs

"use strict";

const assert = require("assert");
const path = require("path");
const writer = require("../src/serve/assets/pcb_step_export.js");
const occt = require("../src/serve/assets/occt-import-js.js");

const points = [
  [0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0],
  [0, 0, 10], [10, 0, 10], [10, 10, 10], [0, 10, 10]
];
const triangles = [
  [0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7],
  [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5],
  [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]
];

const closed = writer.build("closed-fixture", [{ name: "Cube", points, triangles }], "2026-08-25T00:00:00");
const open = writer.build("open-fixture", [{ name: "Surface", points: points.slice(0, 3), triangles: [[0, 1, 2]] }], "2026-08-25T00:00:00");

assert(closed.includes("=FACETED_BREP("));
assert(closed.includes("=CLOSED_SHELL("));
assert(closed.includes("=ADVANCED_FACE("));
assert(!closed.includes("TRIANGULATED_FACE"));
assert.strictEqual((closed.match(/=ADVANCED_FACE\(/g) || []).length, triangles.length);
assert(open.includes("=SHELL_BASED_SURFACE_MODEL("));
assert(open.includes("=OPEN_SHELL("));

occt({ locateFile: (name) => path.resolve(__dirname, "../src/serve/assets", name) }).then((kernel) => {
  const closedResult = kernel.ReadStepFile(new TextEncoder().encode(closed), null);
  const openResult = kernel.ReadStepFile(new TextEncoder().encode(open), null);
  assert.strictEqual(closedResult.success, true);
  assert.strictEqual(openResult.success, true);
  assert(closedResult.meshes.length > 0, "closed B-rep must produce an OpenCascade mesh");
  assert(openResult.meshes.length > 0, "open surface shell must produce an OpenCascade mesh");
  process.stdout.write("PCB STEP export interoperability: PASS\n");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
