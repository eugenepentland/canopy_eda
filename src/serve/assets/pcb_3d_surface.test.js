"use strict";

const assert = require("node:assert/strict");
const THREE = require("./three.min.js");
global.window = global;
require("./pcb_3d_surface.js");

function boardShape(holes) {
  const shape = new THREE.Shape();
  shape.moveTo(0, 0);
  shape.lineTo(20, 0);
  shape.lineTo(20, -10);
  shape.lineTo(0, -10);
  shape.closePath();
  PCB3DSurface.addShapeHoles(THREE, shape, holes);
  return shape;
}

function triangleCovers(geometry, x, y, z) {
  const pos = geometry.getAttribute("position"), index = geometry.index;
  const count = index ? index.count : pos.count;
  function vertex(i) { return index ? index.getX(i) : i; }
  for (let i = 0; i < count; i += 3) {
    const ia = vertex(i), ib = vertex(i + 1), ic = vertex(i + 2);
    if (Math.abs(pos.getZ(ia) - z) > 1e-8 ||
        Math.abs(pos.getZ(ib) - z) > 1e-8 ||
        Math.abs(pos.getZ(ic) - z) > 1e-8) continue;
    const ax = pos.getX(ia), ay = pos.getY(ia);
    const bx = pos.getX(ib), by = pos.getY(ib);
    const cx = pos.getX(ic), cy = pos.getY(ic);
    const d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
    if (Math.abs(d) < 1e-12) continue;
    const u = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / d;
    const v = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / d;
    const w = 1 - u - v;
    if (u >= -1e-8 && v >= -1e-8 && w >= -1e-8) return true;
  }
  return false;
}

const holes = [
  { x: 5, y: 5, r: 1 },
  { x: 12, y: 5, x2: 15, y2: 5, r: 0.75 },
];
const shape = boardShape(holes);
const face = new THREE.ShapeGeometry(shape);
const substrate = new THREE.ExtrudeGeometry(shape, {
  depth: 1.6,
  bevelEnabled: false,
  curveSegments: 1,
});

for (const hole of holes) {
  assert.equal(triangleCovers(face, hole.x, -hole.y, 0), false,
    "the textured face must leave the drill center empty");
  assert.equal(triangleCovers(substrate, hole.x, -hole.y, 0), false,
    "the substrate bottom cap must leave the drill center empty");
  assert.equal(triangleCovers(substrate, hole.x, -hole.y, 1.6), false,
    "the substrate top cap must leave the drill center empty");
}

console.log("PCB 3D surface geometry: round and slotted drills remain open");
