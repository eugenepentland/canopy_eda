#!/usr/bin/env node
// Deterministic interoperability test for the browser STEP writer. It checks
// topology repair and AP242 representation types, then imports the generated
// bytes through the same OpenCascade kernel used by the PCB 3D viewer.
// An optional STEP path also imports and reports the exact downloaded file.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const writer = require("../src/serve/assets/pcb_step_export.js");
const occt = require("../src/serve/assets/occt-import-js.js");

const points = [
  [0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0],
  [0, 0, 10], [10, 0, 10], [10, 10, 10], [0, 10, 10],
];
const triangles = [
  [0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7],
  [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5],
  [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7],
];

function shiftedPoints(dx) {
  return points.map((point) => [point[0] + dx, point[1], point[2]]);
}

function assertBalancedEdges(body) {
  const edges = new Map();
  for (const triangle of body.triangles) {
    for (const [a, b] of [[triangle[0], triangle[1]], [triangle[1], triangle[2]], [triangle[2], triangle[0]]]) {
      const key = a < b ? `${a},${b}` : `${b},${a}`;
      const state = edges.get(key) || { count: 0, balance: 0 };
      state.count++;
      state.balance += a < b ? 1 : -1;
      edges.set(key, state);
    }
  }
  for (const edge of edges.values()) assert.deepEqual(edge, { count: 2, balance: 0 });
}

// Deliberately reverse one face. ExtrudeGeometry can produce the same kind of
// consistent-but-locally-miswound closed surface at cap/wall seams.
const miswound = triangles.map((triangle) => triangle.slice());
miswound[4].reverse();
const repaired = writer.prepareBodies([{ name: "Miswound cube", points, triangles: miswound }]);
assert.equal(repaired.length, 1);
assert.equal(repaired[0].closed, true);
assertBalancedEdges(repaired[0]);

const flatTetrahedron = writer.prepareBodies([{
  name: "Zero-volume shell",
  points: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0.25, 0.25, 0]],
  triangles: [[0, 2, 1], [0, 1, 3], [1, 2, 3], [2, 0, 3]],
}]);
assert.equal(flatTetrahedron[0].closed, false, "a zero-volume shell is not a solid");

// Two source solids may touch but must never be welded into one non-manifold
// component. This mirrors package bodies and leads imported from vendor STEP.
const touching = writer.prepareBodies([
  { name: "Package", points, triangles },
  { name: "Lead", points: shiftedPoints(10), triangles },
]);
assert.equal(touching.length, 2);
assert(touching.every((body) => body.closed));
assert.deepEqual(writer.chunkItems([
  { id: 1, faces: 12000 }, { id: 2, faces: 7000 },
  { id: 3, faces: 2000 }, { id: 4, faces: 21000 },
], 20000).map((chunk) => chunk.map((item) => item.id)), [[1, 2], [3], [4]]);

const closed = writer.build("closed-fixture", [{
  name: "Cube", points, triangles: miswound, color: [0.05, 0.4, 0.2],
}], "2026-08-25T00:00:00");
const openBody = { name: "Surface", points: points.slice(0, 3), triangles: [[0, 1, 2]] };
const mixed = writer.build("mixed-fixture", [
  { name: "Solid", points, triangles }, openBody,
], "2026-08-25T00:00:00");
const multiRoot = writer.build("multi-root-fixture", [
  { name: "Cube A", points, triangles },
  { name: "Cube B", points: shiftedPoints(20), triangles },
], "2026-08-25T00:00:00", 12);
assert.throws(() => writer.build("open-fixture", [openBody], "2026-08-25T00:00:00"), /no closed 3D geometry/);

assert(closed.includes("=FACETED_BREP("));
assert(closed.includes("=CLOSED_SHELL("));
assert(closed.includes("=FACE_SURFACE("));
assert(!closed.includes("=ADVANCED_FACE("));
assert(!closed.includes("TRIANGULATED_FACE"));
assert.strictEqual((closed.match(/=FACE_SURFACE\(/g) || []).length, triangles.length);
assert(closed.includes("=FACETED_BREP_SHAPE_REPRESENTATION("));
assert(closed.includes("=MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION("));
assert(mixed.includes("=FACETED_BREP_SHAPE_REPRESENTATION("));
assert(!mixed.includes("=OPEN_SHELL("));
assert(!mixed.includes("=SHELL_BASED_SURFACE_MODEL("));
assert(!mixed.includes("=MANIFOLD_SURFACE_SHAPE_REPRESENTATION("));
assert(!/=SHAPE_REPRESENTATION\(/.test(mixed));
assert.equal((multiRoot.match(/=PRODUCT\(/g) || []).length, 2);
assert.equal((multiRoot.match(/=FACETED_BREP_SHAPE_REPRESENTATION\(/g) || []).length, 2);
assert.equal((multiRoot.match(/=SHAPE_DEFINITION_REPRESENTATION\(/g) || []).length, 2);

function meshSummary(result) {
  const bounds = { min: [Infinity, Infinity, Infinity], max: [-Infinity, -Infinity, -Infinity] };
  let facetCount = 0;
  for (const mesh of result.meshes || []) {
    const values = mesh.attributes && mesh.attributes.position && mesh.attributes.position.array || [];
    for (let i = 0; i + 2 < values.length; i += 3) {
      for (let axis = 0; axis < 3; axis++) {
        bounds.min[axis] = Math.min(bounds.min[axis], values[i + axis]);
        bounds.max[axis] = Math.max(bounds.max[axis], values[i + axis]);
      }
    }
    const index = mesh.index && mesh.index.array;
    facetCount += index ? index.length / 3 : values.length / 9;
  }
  return { meshes: (result.meshes || []).length, facets: facetCount, bounds };
}

occt({ locateFile: (name) => path.resolve(__dirname, "../src/serve/assets", name) }).then((kernel) => {
  for (const [label, step] of [["closed", closed], ["mixed", mixed], ["multi-root", multiRoot]]) {
    const result = kernel.ReadStepFile(new TextEncoder().encode(step), null);
    assert.equal(result.success, true, `${label} fixture must import through OpenCascade`);
    assert(result.meshes.length > 0, `${label} fixture must produce an OpenCascade mesh`);
    if (label === "closed") {
      const summary = meshSummary(result);
      assert.equal(summary.meshes, 1);
      assert.equal(summary.facets, 12);
      assert.deepEqual(summary.bounds, { min: [0, 0, 0], max: [10, 10, 10] });
      const color = result.meshes[0].color;
      assert(color && color.length >= 3 && color[1] > color[2] && color[2] > color[0],
        "OpenCascade must recover the solid's green presentation colour");
    }
    if (label === "multi-root") {
      const summary = meshSummary(result);
      assert.equal(summary.meshes, 2);
      assert.equal(summary.facets, 24);
      assert.deepEqual(summary.bounds, { min: [0, 0, 0], max: [30, 10, 10] });
    }
  }

  const externalPath = process.argv[2];
  if (externalPath) {
    const bytes = fs.readFileSync(externalPath);
    const result = kernel.ReadStepFile(new Uint8Array(bytes), null);
    assert.equal(result.success, true, "downloaded STEP must import through OpenCascade");
    const summary = meshSummary(result);
    assert(result.meshes.length > 0, "downloaded STEP must contain CAD bodies");
    assert(summary.facets > 0, "downloaded STEP bodies must tessellate to visible faces");
    assert(summary.bounds.min.concat(summary.bounds.max).every(Number.isFinite),
      "downloaded STEP bounds must be finite");
    for (let axis = 0; axis < 3; axis++) assert(summary.bounds.max[axis] > summary.bounds.min[axis],
      "downloaded STEP must occupy nonzero space on every axis");
    process.stdout.write(`Downloaded STEP: ${JSON.stringify(summary)}\n`);
  }
  process.stdout.write("PCB STEP export interoperability: PASS\n");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
