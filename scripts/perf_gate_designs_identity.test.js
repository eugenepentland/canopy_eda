#!/usr/bin/env node
// Contract test for scripts/perf_gate_designs_identity.js: the stamp must
// carry hand-set budgets forward and pin the snapshot identity, and the check
// must pass an identical workload, name drift instead of inventing a latency
// regression, and refuse an unstamped baseline. Hermetic: runs the script as
// a subprocess in a temp dir with the identity env explicitly controlled.
"use strict";
const assert = require("assert");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const script = path.join(__dirname, "perf_gate_designs_identity.js");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "perf-identity-test."));
process.on("exit", () => fs.rmSync(dir, { recursive: true, force: true }));

const COMMIT = "aaaabbbbccccddddeeeeffff0000111122223333";
const OTHER_COMMIT = "9999888877776666555544443333222211110000";
const FINGERPRINT = `${COMMIT}:model1:layout1:bom1`;

function run(args, env) {
  // Empty strings unset the identity even when the invoking shell exports it.
  const result = spawnSync(process.execPath, [script, ...args], {
    env: {
      ...process.env,
      NETLISP_PERF_DESIGNS_COMMIT: "",
      NETLISP_PERF_DESIGNS_FINGERPRINT: "",
      ...env,
    },
    encoding: "utf8",
  });
  assert.strictEqual(result.error, undefined);
  return result;
}

const file = (name, value) => {
  const p = path.join(dir, name);
  fs.writeFileSync(p, `${JSON.stringify(value, null, 2)}\n`);
  return p;
};
const read = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const identityEnv = {
  NETLISP_PERF_DESIGNS_COMMIT: COMMIT,
  NETLISP_PERF_DESIGNS_FINGERPRINT: FINGERPRINT,
};

// stamp: budgets carried from the previous baseline, identity pinned, and the
// recorded measurements untouched.
{
  const previous = file("previous.json", { boards: [{ name: "old" }], budgets: { page_ms: 1000 } });
  const recorded = file("recorded.json", { boards: [{ name: "barracuda", page_ms: 5668 }] });
  const result = run(["stamp", recorded, previous], identityEnv);
  assert.strictEqual(result.status, 0, result.stderr);
  const stamped = read(recorded);
  assert.deepStrictEqual(stamped.budgets, { page_ms: 1000 }, "budgets must carry forward");
  assert.deepStrictEqual(stamped.boards, [{ name: "barracuda", page_ms: 5668 }]);
  assert.strictEqual(stamped.designs.commit, COMMIT);
  assert.strictEqual(stamped.designs.fingerprint, FINGERPRINT);
  assert.strictEqual(stamped.designs.dirty, false);
  assert.strictEqual(stamped.designs.source, "git-archive+workload-bundles");
}

// stamp with no previous baseline: nothing invented, identity still pinned.
{
  const recorded = file("first.json", { boards: [] });
  const result = run(["stamp", recorded, path.join(dir, "absent.json")], identityEnv);
  assert.strictEqual(result.status, 0, result.stderr);
  const stamped = read(recorded);
  assert.strictEqual(stamped.budgets, undefined, "no budgets may be invented");
  assert.strictEqual(stamped.designs.fingerprint, FINGERPRINT);
}

// stamp without the identity env (non-git designs dir): budgets still carried,
// no identity claimed.
{
  const previous = file("previous2.json", { budgets: { page_ms: 2 } });
  const recorded = file("recorded2.json", { boards: [] });
  const result = run(["stamp", recorded, previous]);
  assert.strictEqual(result.status, 0, result.stderr);
  const stamped = read(recorded);
  assert.deepStrictEqual(stamped.budgets, { page_ms: 2 });
  assert.strictEqual(stamped.designs, undefined, "no identity env means no identity claim");
}

// check: identical workload passes and names the designs commit.
{
  const baseline = file("match.json", { boards: [], designs: { commit: COMMIT, fingerprint: FINGERPRINT } });
  const result = run(["check", baseline], identityEnv);
  assert.strictEqual(result.status, 0, result.stderr);
  assert.ok(result.stdout.includes(`matches designs ${COMMIT.slice(0, 12)}`), result.stdout);
}

// check: a moved designs commit is named as workload drift, not regression.
{
  const baseline = file("moved.json", {
    boards: [],
    designs: { commit: OTHER_COMMIT, fingerprint: `${OTHER_COMMIT}:model0:layout0:bom0` },
  });
  const result = run(["check", baseline], identityEnv);
  assert.strictEqual(result.status, 3);
  assert.ok(result.stderr.includes(`recorded against designs ${OTHER_COMMIT.slice(0, 12)}`), result.stderr);
  assert.ok(result.stderr.includes(`comparing against designs ${COMMIT.slice(0, 12)}`), result.stderr);
  assert.ok(result.stderr.includes("re-record deliberately"), result.stderr);
}

// check: same commit but moved model/layout/BOM bundles is still drift.
{
  const baseline = file("bundles.json", {
    boards: [],
    designs: { commit: COMMIT, fingerprint: `${COMMIT}:model0:layout1:bom1` },
  });
  const result = run(["check", baseline], identityEnv);
  assert.strictEqual(result.status, 3);
  assert.ok(result.stderr.includes("bundles moved"), result.stderr);
}

// check: an unstamped (pre-stamp) baseline is refused with its own reason.
{
  const baseline = file("unstamped.json", { boards: [], budgets: { page_ms: 1000 } });
  const result = run(["check", baseline], identityEnv);
  assert.strictEqual(result.status, 3);
  assert.ok(result.stderr.includes("records no designs workload identity"), result.stderr);
}

// check: without the identity env there is nothing to compare — not a failure.
{
  const baseline = file("noenv.json", { boards: [], designs: { commit: COMMIT, fingerprint: FINGERPRINT } });
  const result = run(["check", baseline]);
  assert.strictEqual(result.status, 0, result.stderr);
}

// check: a missing baseline file is bench-page's report to make, not ours.
{
  const result = run(["check", path.join(dir, "never-recorded.json")], identityEnv);
  assert.strictEqual(result.status, 0, result.stderr);
}

// usage errors are their own exit code, distinct from drift.
{
  assert.strictEqual(run(["stamp"]).status, 2);
  assert.strictEqual(run(["frobnicate", "x.json"]).status, 2);
}

console.log("perf_gate_designs_identity: PASS");
