#!/usr/bin/env node
// Wait for a quiet measurement window before latency-sensitive browser gates.
// The machine-wide gate lock serializes cooperating Netlisp jobs, but unrelated
// compilers and renderers can still distort frame timings. Sample instantaneous
// CPU activity and Linux's runnable-task count instead of gating on the lagging
// one-minute load average alone.
"use strict";

const fs = require("fs");
const os = require("os");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function positiveNumber(value, fallback, name) {
  if (value == null || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`${name} must be a positive number`);
  return parsed;
}

function configFromEnv(env = process.env, cpuCount = os.cpus().length) {
  return {
    maxBusyPct: positiveNumber(env.NETLISP_PERF_HOST_MAX_BUSY_PCT, 55, "NETLISP_PERF_HOST_MAX_BUSY_PCT"),
    maxRunnable: positiveNumber(env.NETLISP_PERF_HOST_MAX_RUNNABLE, Math.max(2, Math.ceil(cpuCount / 4)), "NETLISP_PERF_HOST_MAX_RUNNABLE"),
    maxLoadPerCpu: positiveNumber(env.NETLISP_PERF_HOST_MAX_LOAD_PER_CPU, 0.9, "NETLISP_PERF_HOST_MAX_LOAD_PER_CPU"),
    stableSamples: Math.ceil(positiveNumber(env.NETLISP_PERF_HOST_STABLE_SAMPLES, 3, "NETLISP_PERF_HOST_STABLE_SAMPLES")),
    sampleMs: positiveNumber(env.NETLISP_PERF_HOST_SAMPLE_MS, 1000, "NETLISP_PERF_HOST_SAMPLE_MS"),
    pollMs: positiveNumber(env.NETLISP_PERF_HOST_POLL_MS, 3000, "NETLISP_PERF_HOST_POLL_MS"),
    timeoutMs: positiveNumber(env.NETLISP_PERF_HOST_WAIT_SECONDS, 1800, "NETLISP_PERF_HOST_WAIT_SECONDS") * 1000,
    cpuCount,
  };
}

function cpuTotals(cpus = os.cpus()) {
  let idle = 0, total = 0;
  for (const cpu of cpus) {
    idle += cpu.times.idle;
    total += Object.values(cpu.times).reduce((sum, value) => sum + value, 0);
  }
  return { idle, total };
}

function readLinuxLoad() {
  try {
    const fields = fs.readFileSync("/proc/loadavg", "utf8").trim().split(/\s+/);
    return { load1: Number(fields[0]), runnable: Number(fields[3].split("/")[0]) };
  } catch (_) {
    return { load1: os.loadavg()[0], runnable: null };
  }
}

async function sampleHost(sampleMs) {
  const before = cpuTotals();
  await sleep(sampleMs);
  const after = cpuTotals();
  const elapsed = after.total - before.total;
  const busyPct = elapsed > 0 ? 100 * (1 - (after.idle - before.idle) / elapsed) : 0;
  return { busyPct, ...readLinuxLoad() };
}

function classifySample(sample, config) {
  const highBusy = sample.busyPct > config.maxBusyPct;
  const longRunQueue = Number.isFinite(sample.runnable) && sample.runnable > config.maxRunnable;
  // Load average includes recently-finished work. Use it only when the current
  // CPU sample is also meaningfully busy, so our own completed build does not
  // force several minutes of pointless decay before the browser may start.
  const sustainedLoad = Number.isFinite(sample.load1) &&
    sample.load1 > config.cpuCount * config.maxLoadPerCpu &&
    sample.busyPct > config.maxBusyPct / 2;
  const reasons = [];
  if (highBusy) reasons.push(`CPU ${sample.busyPct.toFixed(1)}% > ${config.maxBusyPct}%`);
  if (longRunQueue) reasons.push(`run queue ${sample.runnable} > ${config.maxRunnable}`);
  if (sustainedLoad) reasons.push(`load1 ${sample.load1.toFixed(2)} with active CPU pressure`);
  return { ready: reasons.length === 0, reasons };
}

function describe(sample) {
  const runnable = Number.isFinite(sample.runnable) ? sample.runnable : "unknown";
  return `CPU ${sample.busyPct.toFixed(1)}%, run queue ${runnable}, load1 ${sample.load1.toFixed(2)}`;
}

async function waitUntilIdle(options = {}) {
  const config = options.config || configFromEnv();
  const takeSample = options.sample || (() => sampleHost(config.sampleMs));
  const pause = options.sleep || sleep;
  const now = options.now || Date.now;
  const write = options.write || ((line) => process.stderr.write(`${line}\n`));
  const started = now();
  let stable = 0, announcedWait = false;

  while (true) {
    const sample = await takeSample();
    const state = classifySample(sample, config);
    stable = state.ready ? stable + 1 : 0;
    if (stable >= config.stableSamples) {
      write(`perf-host: quiet window confirmed (${describe(sample)}; ${stable} stable samples)`);
      return sample;
    }
    if (!state.ready && !announcedWait) {
      write(`perf-host: host is busy (${state.reasons.join(", ")}); waiting up to ${Math.round(config.timeoutMs / 1000)}s`);
      announcedWait = true;
    }
    if (now() - started >= config.timeoutMs) {
      const error = new Error(`timed out waiting for a quiet performance window (${describe(sample)})`);
      error.exitCode = 75;
      throw error;
    }
    await pause(config.pollMs);
  }
}

async function main() {
  if (process.argv.length > 2 && process.argv[2] !== "--wait") {
    throw new Error("usage: node scripts/perf_host_idle.js [--wait]");
  }
  await waitUntilIdle();
}

module.exports = { classifySample, configFromEnv, waitUntilIdle };

if (require.main === module) {
  main().catch((error) => {
    console.error(`perf-host: ${error.message}`);
    process.exit(error.exitCode || 1);
  });
}
