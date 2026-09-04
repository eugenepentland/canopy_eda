"use strict";

const assert = require("node:assert/strict");
const thermal = require("./system_cad.js");

function model(power, temperatures) {
  return {
    ambient_c: 25,
    parts: [{ power: { watts: power } }],
    scenarios: Object.entries(temperatures).map(([scenario, board_max_c]) => ({ scenario, board_max_c, converged: true }))
  };
}

const boards = [
  {
    name: "barracuda", width: 81, depth: 24.8,
    thermal: model(4.27874, { natural: 82, airflow_1ms: 63, airflow_2ms: 54, heatsink: 55, fan_heatsink: 42 }),
    cooling: {
      heatsink: { w: 56.6, d: 26.1, shape: "stepped", lower_w: 250, lower_d: 250 },
      fan: { x: 0, y: 0, w: 80, d: 80, flow_m3_s: 0.025, operating_fraction: 0.6 }
    }
  },
  {
    name: "black-canyon", width: 66.9, depth: 18.5,
    thermal: model(1.61656833, { natural: 70, airflow_1ms: 55, airflow_2ms: 48 }),
    cooling: { heatsink: null, fan: null }
  }
];

const centers = [-77, -55, -33, -11, 11, 33, 55, 77];
const instances = [{ id: "barracuda", board: "barracuda", x: 0, y: 0, z: 18.5, rot: 0, on: true }];
for (const side of ["left", "right"]) {
  const x = side === "left" ? -73.95 : 73.95;
  centers.forEach((y, index) => instances.push({ id: `black-canyon-${side}-${index + 1}`, board: "black-canyon", x, y, z: 18.5, rot: 0, on: true }));
}

for (let i = 1; i < centers.length; i += 1) assert.equal(centers[i] - centers[i - 1], 22);
const first = thermal.rotatedBounds(66.9, 18.5, instances[1], 0, 0);
const last = thermal.rotatedBounds(66.9, 18.5, instances[8], 0, 0);
assert.equal(Number((last.maxy - first.miny).toFixed(1)), 172.5);
assert.equal(Number((2 * (73.95 + 66.9 / 2)).toFixed(1)), 214.8);

const result = thermal.solveSystem(boards, instances, 25);
assert.equal(result.instances.length, 17);
assert.ok(Math.abs(result.total_watts - 30.14383328) < 1e-9);
assert.ok(result.outlet_rise_c > 1.6 && result.outlet_rise_c < 1.8);
assert.equal(result.hottest.board, "black-canyon");
const barracuda = result.instances.find((row) => row.id === "barracuda");
assert.ok(barracuda.coverage > 0.98 && barracuda.coverage < 1);
assert.ok(barracuda.velocity > 2);
assert.ok(barracuda.temperature_c < result.hottest.temperature_c);

const wheelGesture = { last: -Infinity, total: 0 };
let appliedWheel = 0;
for (let i = 0; i < 100; i += 1) appliedWheel += thermal.boundedWheelStep(wheelGesture, -24, 0, i * 8, 900);
assert.equal(appliedWheel, -480);
assert.equal(thermal.boundedWheelStep(wheelGesture, -120, 0, 1000, 900), -120);
assert.equal(thermal.boundedWheelStep(wheelGesture, 3, 1, 1020, 900), 48);

console.log("System thermal: RDS3 pitch, repeated instances, fan coverage, bounded wheel zoom, and coupled screen pass");
