// Queue a standalone benchmark run under scripts/gate.sh's machine-wide lock.
//
// Timing runs are only comparable when nothing else competes for the machine,
// and the lock can only serialize the jobs that take it. Standalone browser
// benches used to take none: one such run overlapped a gated
// `perf_gate.sh --record`, aborted its browser pass on a networkidle timeout,
// and skewed a gated bench-page pass 17-72% on the big boards (FEEDBACK.md
// 2026-08-29). So the runners call ensureGateLock() before starting servers
// or browsers: when the lock is not already held, the process re-execs itself
// under scripts/gate.sh exactly as scripts/perf_gate.sh does, and queues.
//
// Contract with gate.sh (its recursion guard): gate.sh exports
// NETLISP_GATE_HELD=<lock path> and execs the command, so the re-entered
// runner sees the guard satisfied and falls through — one lock, no deadlock.
// NETLISP_GATE_SERIALIZE=0 bypasses the queue entirely, same as gate.sh.
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function ensureGateLock(tag) {
  const lock = process.env.NETLISP_GATE_LOCK || "/tmp/netlisp-gate.lock";
  if (process.env.NETLISP_GATE_HELD === lock) return; // already inside the lock (perf_gate.sh, prepare-release, a gated shell)
  if (process.env.NETLISP_GATE_SERIALIZE === "0") return; // explicit opt-out for a machine known to be idle
  const gate = path.join(__dirname, "gate.sh");
  if (!fs.existsSync(gate)) return; // outside the repo layout there is no queue to join
  const child = spawnSync(gate, [process.execPath, ...process.argv.slice(1)], { stdio: "inherit" });
  if (child.error) {
    console.error(`${tag}: failed to re-exec under scripts/gate.sh: ${child.error.message}`);
    process.exit(1);
  }
  // Die the way the gated child died, so wrappers see the same exit.
  if (child.signal) process.kill(process.pid, child.signal);
  process.exit(child.status === null ? 1 : child.status);
}

module.exports = { ensureGateLock };
