#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

global.window = {};
vm.runInThisContext(fs.readFileSync("src/serve/assets/pcb_earcut.js", "utf8"), {
  filename: "pcb_earcut.js",
});
vm.runInThisContext(fs.readFileSync("src/serve/assets/pcb_region.js", "utf8"), {
  filename: "pcb_region.js",
});

function triangleArea(a, b, c) {
  return Math.abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) / 2;
}

function trianglesArea(triangles) {
  let area = 0;
  assert.equal(triangles.length % 3, 0);
  for (let i = 0; i < triangles.length; i += 3) {
    const one = triangleArea(triangles[i], triangles[i + 1], triangles[i + 2]);
    assert.ok(one > 1e-12, "triangulator must not emit degenerate faces");
    area += one;
  }
  return area;
}

function largestTriangle(triangles) {
  let largest = 0;
  for (let i = 0; i < triangles.length; i += 3) {
    largest = Math.max(largest, triangleArea(triangles[i], triangles[i + 1], triangles[i + 2]));
  }
  return largest;
}

function winding(ring, point) {
  let value = 0;
  for (let i = 0; i < ring.length; i++) {
    const a = ring[i], b = ring[(i + 1) % ring.length];
    const side = (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0]);
    if (a[1] <= point[1]) {
      if (b[1] > point[1] && side > 1e-9) value++;
    } else if (b[1] <= point[1] && side < -1e-9) value--;
  }
  return value;
}

function assertInsideOriginal(ring, triangles) {
  for (let i = 0; i < triangles.length; i += 3) {
    const a = triangles[i], b = triangles[i + 1], c = triangles[i + 2];
    const centroid = [(a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3];
    assert.notEqual(winding(ring, centroid), 0, "triangle escaped the source region's non-zero fill");
  }
}

const concave = [[0, 0], [5, 0], [5, 1], [2, 1], [2, 4], [0, 4]];
const concaveTriangles = window.PCBRegionTriangles(concave);
assert.ok(concaveTriangles);
assert.ok(Math.abs(trianglesArea(concaveTriangles) - 11) < 1e-10);

const bowTie = [[0, 0], [4, 4], [0, 4], [4, 0]];
const bowTieTriangles = window.PCBRegionTriangles(bowTie);
assert.ok(bowTieTriangles);
assert.equal(bowTieTriangles.length / 3, 2);
assert.ok(Math.abs(trianglesArea(bowTieTriangles) - 8) < 1e-10);
assertInsideOriginal(bowTie, bowTieTriangles);

// Exact copper-bottom clearance contour from Barracuda Base. Feeding this
// self-crossing ring straight to Earcut produced a 23.696 mm² bridge triangle
// across the board. Its non-zero fill is 20 planar-face triangles instead.
const barracuda = [
  [187.3293, 79.2355], [187.4817, 79.3065], [190.3773, 79.3117],
  [193.0443, 81.9025], [199.6737, 86.7031], [207.8271, 86.7031],
  [209.8845, 85.1791], [210.0369, 85.102142], [210.3417, 85.094089],
  [210.4941, 85.1791], [210.5703, 85.2553], [210.573751, 85.7125],
  [209.9607, 85.8649], [209.8083, 85.7935], [209.6559, 85.7935],
  [194.5683, 82.5121], [190.1487, 79.9213], [187.4055, 79.9213],
  [187.2531, 80.001779], [186.9483, 80.002306], [186.7197, 79.3879],
  [186.8721, 79.235364],
];
const barracudaTriangles = window.PCBRegionTriangles(barracuda);
assert.ok(barracudaTriangles);
assert.equal(barracudaTriangles.length / 3, 20);
assert.ok(Math.abs(trianglesArea(barracudaTriangles) - 32.276215894893845) < 1e-9);
assert.ok(largestTriangle(barracudaTriangles) < 18, "the old cross-board bridge triangle returned");
assertInsideOriginal(barracuda, barracudaTriangles);

console.log("pcb_region: simple and self-crossing Gerber regions passed");
