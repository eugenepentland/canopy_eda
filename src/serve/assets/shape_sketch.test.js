"use strict";

const assert = require("node:assert/strict");
const OS = require("./shape_sketch.js");

function lineDistance(a, b, p) {
  return Math.abs((p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)) /
    Math.hypot(b.x - a.x, b.y - a.y);
}

const constrained = {
  version: 1,
  points: [
    { id: 1, x: 0, y: 0 },
    { id: 2, x: 10, y: 0 },
    { id: 3, x: 2, y: 3 },
    { id: 4, x: 8, y: 5 },
  ],
  curves: [
    { id: 11, kind: "line", a: 1, b: 2 },
    { id: 12, kind: "line", a: 3, b: 4 },
  ],
  constraints: [],
};

assert.ok(OS.addConstraint(constrained, "collinear", 11, 12));
assert.ok(lineDistance(OS.point(constrained, 1), OS.point(constrained, 2), OS.point(constrained, 3)) < 1e-4);
const da = {
  x: OS.point(constrained, 2).x - OS.point(constrained, 1).x,
  y: OS.point(constrained, 2).y - OS.point(constrained, 1).y,
};
const db = {
  x: OS.point(constrained, 4).x - OS.point(constrained, 3).x,
  y: OS.point(constrained, 4).y - OS.point(constrained, 3).y,
};
assert.ok(Math.abs(da.x * db.y - da.y * db.x) < 1e-3);

const open = {
  version: 1,
  points: [
    { id: 1, x: 0, y: 0 },
    { id: 2, x: 10, y: 0 },
    { id: 3, x: 10, y: 10 },
    { id: 4, x: 0.1, y: 0.1 },
  ],
  curves: [
    { id: 11, kind: "line", a: 1, b: 2 },
    { id: 12, kind: "line", a: 2, b: 3 },
    { id: 13, kind: "line", a: 3, b: 4 },
  ],
  constraints: [],
};

const target = OS.closingEndpointTarget(open, 4, 0.02, 0.03, 0.25);
assert.equal(target.id, 1);
assert.equal(OS.closeByMergingEndpoints(open, 4, target.id), true);
assert.equal(OS.point(open, 4), null);
assert.equal(OS.curve(open, 13).b, 1);
assert.equal(OS.closed(open), true);

const disconnected = OS.clone(open);
disconnected.points.push({ id: 20, x: 20, y: 20 }, { id: 21, x: 21, y: 20 });
disconnected.curves.push({ id: 22, kind: "line", a: 20, b: 21 });
assert.equal(OS.closingEndpointTarget(disconnected, 20, 0, 0, 50), null);

console.log("Shape sketch: co-linear solve and dragged endpoint closure pass");
