#!/usr/bin/env node
"use strict";

const assert = require("assert");
const { classifySample, configFromEnv, waitUntilIdle } = require("./perf_host_idle");

// spec: Web Server - Release preparation waits for a stable quiet-host window before PCB-editor timing, retries timing-budget misses after contention clears, and never retries renderer or infrastructure failures
const config = configFromEnv({
  NETLISP_PERF_HOST_MAX_BUSY_PCT: "50",
  NETLISP_PERF_HOST_MAX_RUNNABLE: "4",
  NETLISP_PERF_HOST_MAX_LOAD_PER_CPU: "0.75",
  NETLISP_PERF_HOST_STABLE_SAMPLES: "3",
  NETLISP_PERF_HOST_SAMPLE_MS: "1",
  NETLISP_PERF_HOST_POLL_MS: "1",
  NETLISP_PERF_HOST_WAIT_SECONDS: "10",
}, 8);

assert.deepStrictEqual(classifySample({ busyPct: 20, runnable: 2, load1: 20 }, config), {
  ready: true,
  reasons: [],
}, "stale load average alone must not hold a quiet host");
assert.strictEqual(classifySample({ busyPct: 70, runnable: 2, load1: 2 }, config).ready, false);
assert.strictEqual(classifySample({ busyPct: 20, runnable: 7, load1: 2 }, config).ready, false);
assert.strictEqual(classifySample({ busyPct: 30, runnable: 2, load1: 8 }, config).ready, false);

(async () => {
  const samples = [
    { busyPct: 80, runnable: 8, load1: 9 },
    { busyPct: 10, runnable: 1, load1: 8 },
    { busyPct: 12, runnable: 1, load1: 7 },
    { busyPct: 75, runnable: 6, load1: 8 },
    { busyPct: 9, runnable: 1, load1: 7 },
    { busyPct: 8, runnable: 1, load1: 6 },
    { busyPct: 7, runnable: 1, load1: 5 },
  ];
  let index = 0, clock = 0;
  const lines = [];
  const result = await waitUntilIdle({
    config,
    sample: async () => samples[index++],
    sleep: async (ms) => { clock += ms; },
    now: () => clock,
    write: (line) => lines.push(line),
  });
  assert.strictEqual(index, samples.length, "a busy sample must reset the quiet streak");
  assert.strictEqual(result.busyPct, 7);
  assert(lines.some((line) => line.includes("host is busy")));
  assert(lines.some((line) => line.includes("quiet window confirmed")));
  console.log("perf_host_idle: PASS");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
