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

const moved = {
  version: 1,
  points: [
    { id: 1, x: 0, y: 0 },
    { id: 2, x: 10, y: 0 },
    { id: 3, x: 10, y: 10 },
  ],
  curves: [
    { id: 11, kind: "line", a: 1, b: 2 },
    { id: 12, kind: "line", a: 2, b: 3 },
  ],
  constraints: [],
};
const movedCurves = OS.physicalCurves(moved);
const shared = OS.point(moved, movedCurves[0].b);
const oldShared = { x: shared.x, y: shared.y };
const batch = OS.moveGeometry(moved, [], [movedCurves[0].id, movedCurves[1].id], 2.5, -1.25);
assert.equal(batch.conflict, false);
assert.equal(batch.moved, true);
assert.ok(Math.abs(shared.x - (oldShared.x + 2.5)) < 1e-4);
assert.ok(Math.abs(shared.y - (oldShared.y - 1.25)) < 1e-4);

const fixed = OS.fromPolygon([[0, 0], [5, 0], [5, 5], [0, 5]]);
const fixedCurve = OS.physicalCurves(fixed)[0];
assert.ok(OS.addConstraint(fixed, "fixed", fixedCurve.a));
assert.ok(OS.addConstraint(fixed, "fixed", fixedCurve.b));
const blocked = OS.moveGeometry(fixed, [], [fixedCurve.id], 0, 3);
assert.equal(blocked.conflict, true);
assert.equal(blocked.moved, false);

const dimensions = {
  version: 1,
  points: [
    { id: 1, x: 0, y: 0 }, { id: 2, x: 10, y: 0 },
    { id: 3, x: 0, y: 5 }, { id: 4, x: 10, y: 5 },
    { id: 5, x: 0, y: 10 }, { id: 6, x: 8, y: 18 },
    { id: 7, x: 15, y: 0 }, { id: 8, x: 25, y: 0 },
  ],
  curves: [
    { id: 11, kind: "line", a: 1, b: 2 },
    { id: 12, kind: "line", a: 3, b: 4 },
    { id: 13, kind: "line", a: 5, b: 6 },
    { id: 14, kind: "arc", a: 7, b: 8, mid: [20, -5] },
  ],
  constraints: [],
};
const lengthDraft = OS.inferDimension(dimensions, [{ type: "curve", id: 11 }], { x: 5, y: -3 });
assert.equal(lengthDraft.kind, "length");
assert.deepEqual(lengthDraft.placement, [5, -3]);
const offsetDraft = OS.inferDimension(dimensions, [{ type: "curve", id: 11 }, { type: "curve", id: 12 }], { x: 5, y: 7 });
assert.equal(offsetDraft.kind, "offset");
assert.equal(offsetDraft.value, 5);
const angleDraft = OS.inferDimension(dimensions, [{ type: "curve", id: 11 }, { type: "curve", id: 13 }], { x: 3, y: 4 });
assert.equal(angleDraft.kind, "angle_between");
assert.ok(Math.abs(angleDraft.value - 45) < 1e-9);
const obtuseDraft = OS.inferDimension(dimensions, [{ type: "curve", id: 11 }, { type: "curve", id: 13 }], { x: -12, y: 3 });
assert.ok(Math.abs(obtuseDraft.value - 135) < 1e-9);
const horizontalDraft = OS.inferDimension(dimensions, [{ type: "point", id: 1 }, { type: "point", id: 4 }], { x: 5, y: -10 });
assert.equal(horizontalDraft.kind, "distance_x");
const tangentDraft = OS.inferDimension(dimensions, [{ type: "curve", id: 11 }, { type: "curve", id: 14 }], { x: 13, y: -4 });
assert.equal(tangentDraft.kind, "tangent_distance");
assert.ok(tangentDraft.value > 0);
const placed = OS.addConstraint(dimensions, "offset", 11, 12, 7, null, { placement: [6, 8] });
assert.ok(placed);
assert.ok(Math.abs(OS.dimensionValue(dimensions, placed) - 7) < 1e-4);
assert.deepEqual(OS.annotations(dimensions).find((row) => row.id === placed.id), { id: placed.id, x: 6, y: 8, kind: "offset", value: OS.dimensionValue(dimensions, placed), driving: true });

console.log("Shape sketch: constraints, endpoint closure, batch move, and smart dimensions pass");
