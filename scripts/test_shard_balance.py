#!/usr/bin/env python3
"""Regenerate src/test_shards.zig: the `zig build test` shard partition.

`zig build test` compiles one test binary per shard and runs them concurrently.
Each shard is a `--test-filter` set, so the partition has to be balanced by
MEASURED test wall time — test count is a bad proxy here, where one file
(placement/router.zig) is 40% of the suite and one single test is 14% of it.

Usage
-----
    # 1. build the unfiltered test binary and note the path the build prints
    zig build test-compile                       # or any `zig build test` run
    # 2. time every test, then repartition
    scripts/test_shard_balance.py measure <test-binary> timings.tsv
    scripts/test_shard_balance.py generate timings.tsv [--shards N]

`measure` drives the binary over Zig's own test protocol (the one `zig build`
speaks), running each test once and recording its wall time. It needs the repo
root as its cwd, and a stack big enough for the deep-recursion parser test:

    (ulimit -s 65536; scripts/test_shard_balance.py measure ... )

`generate` writes src/test_shards.zig. It is deterministic: the same timings
file and shard count always produce the same bytes, so a regenerated manifest
diffs cleanly. It refuses to write a partition it cannot prove correct.
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import struct
import subprocess
import sys
import time

MANIFEST = "src/test_shards.zig"

# A file costing more than this many seconds is split on a fixed-length test
# name prefix instead of being kept whole.
SPLIT_OVER_SECONDS = 4.0
PREFIX_LEN = 3

TEST_DECL = re.compile(r'^test\s+"((?:[^"\\]|\\.)*)"\s*\{', re.M)


# ── measuring ────────────────────────────────────────────────────────────────

# Zig's test protocol. Client tags are what we send, server tags what we read;
# both are `std.zig.Client.Message.Tag` / `std.zig.Server.Message.Tag` ordinals.
CLIENT_EXIT, CLIENT_QUERY_METADATA, CLIENT_RUN_TEST = 0, 4, 5
SERVER_TEST_METADATA, SERVER_TEST_RESULTS, SERVER_TEST_STARTED = 3, 4, 5


class TestBinary:
    def __init__(self, path: str):
        self.proc = subprocess.Popen(
            [path, "--listen=-"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self._recv()  # zig_version

    def _send(self, tag: int, body: bytes = b"") -> None:
        self.proc.stdin.write(struct.pack("<II", tag, len(body)) + body)
        self.proc.stdin.flush()

    def _recv(self):
        header = self.proc.stdout.read(8)
        if len(header) < 8:
            return None, None
        tag, size = struct.unpack("<II", header)
        body = b""
        while len(body) < size:
            chunk = self.proc.stdout.read(size - len(body))
            if not chunk:
                break
            body += chunk
        return tag, body

    def names(self) -> list[str]:
        self._send(CLIENT_QUERY_METADATA)
        while True:
            tag, body = self._recv()
            if tag == SERVER_TEST_METADATA:
                break
            if tag is None:
                sys.exit("test binary closed the protocol before sending metadata")
        string_len, count = struct.unpack("<II", body[:8])
        at = 8
        offsets = struct.unpack("<%dI" % count, body[at : at + 4 * count])
        at += 8 * count  # names, then expected_panic_msgs
        strings = body[at : at + string_len]
        return [strings[o : strings.index(b"\0", o)].decode() for o in offsets]

    def time_test(self, index: int) -> float:
        started = time.monotonic()
        self._send(CLIENT_RUN_TEST, struct.pack("<I", index))
        while True:
            tag, _ = self._recv()
            if tag is None:
                sys.exit("test %d crashed the test binary" % index)
            if tag == SERVER_TEST_STARTED:
                started = time.monotonic()
            if tag == SERVER_TEST_RESULTS:
                return time.monotonic() - started

    def close(self) -> None:
        self._send(CLIENT_EXIT)
        self.proc.wait()


def measure(binary: str, out_path: str) -> None:
    runner = TestBinary(binary)
    names = runner.names()
    with open(out_path, "w") as out:
        for index, name in enumerate(names):
            out.write("%.6f\t%s\n" % (runner.time_test(index), name))
    runner.close()
    print("timed %d tests -> %s" % (len(names), out_path))


# ── partitioning ─────────────────────────────────────────────────────────────


def static_tests() -> dict[str, list[str]]:
    """Every `test "..."` in src/, keyed by dotted module path.

    Exactly what runs: `src/test_root.zig`'s import bridge is exhaustive over
    the tree, so every module a scan finds here is one the compiler analyzes.
    """
    found: dict[str, list[str]] = collections.defaultdict(list)
    for parent, _, files in os.walk("src"):
        for name in files:
            if not name.endswith(".zig"):
                continue
            path = os.path.join(parent, name)
            module = os.path.relpath(path, "src")[:-4].replace(os.sep, ".")
            source = open(path, encoding="utf-8", errors="replace").read()
            declared = TEST_DECL.findall(source)
            # Only modules that declare a test get an entry: a key with an empty
            # list would become a filter matching nothing, which is a shard the
            # compiler leaves empty and Guardian's runner fails on.
            if declared:
                found[module].extend(declared)
    return found


def load_costs(timings: str) -> dict[str, float]:
    costs: dict[str, float] = collections.defaultdict(float)
    for line in open(timings):
        seconds, name = line.rstrip("\n").split("\t", 1)
        cut = name.find(".test.")
        if cut < 0:
            continue  # unnamed block: linked into every shard, not assignable
        costs[name] = float(seconds)
    return costs


def build_atoms(static: dict[str, list[str]], costs: dict[str, float]):
    """Indivisible units of (filter, cost, claimed names)."""
    per_module: dict[str, float] = collections.defaultdict(float)
    for name, seconds in costs.items():
        per_module[name[: name.find(".test.")]] += seconds

    atoms = []
    for module in sorted(static):
        names = static[module]
        if per_module.get(module, 0.0) > SPLIT_OVER_SECONDS and len(names) > 1:
            buckets: dict[str, list[str]] = collections.defaultdict(list)
            for name in names:
                buckets[name[:PREFIX_LEN]].append(name)
            for prefix, members in sorted(buckets.items()):
                cost = sum(
                    costs.get("%s.test.%s" % (module, n), 0.0) for n in members
                )
                atoms.append(
                    (
                        "%s.test.%s" % (module, prefix),
                        cost,
                        ["%s.test.%s" % (module, n) for n in members],
                    )
                )
        else:
            atoms.append(
                (
                    "%s.test." % module,
                    per_module.get(module, 0.0),
                    ["%s.test.%s" % (module, n) for n in names],
                )
            )
    return atoms


def collision_units(atoms) -> dict[int, list[int]]:
    """Group atoms whose filter would also select another atom's tests.

    `--test-filter` is a plain substring match with no anchor, so
    `exit.test.` selects `placement.pad_exit.test.*` too. Such atoms cannot be
    separated and are packed as one unit.
    """
    parent = list(range(len(atoms)))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i, (filter_text, _, _) in enumerate(atoms):
        for j, (_, _, names) in enumerate(atoms):
            if i != j and any(filter_text in name for name in names):
                a, b = find(i), find(j)
                if a != b:
                    parent[a] = b

    units: dict[int, list[int]] = collections.defaultdict(list)
    for i in range(len(atoms)):
        units[find(i)].append(i)
    return units


def pack(atoms, units, shard_count: int):
    """Longest-processing-time-first bin packing: the standard 4/3-optimal
    greedy, which is well inside the noise of run-to-run test timing."""
    load = [0.0] * shard_count
    bins: list[list[str]] = [[] for _ in range(shard_count)]
    costs = {u: sum(atoms[i][1] for i in ids) for u, ids in units.items()}
    for unit in sorted(costs, key=lambda u: -costs[u]):
        target = load.index(min(load))
        bins[target].extend(atoms[i][0] for i in units[unit])
        load[target] += costs[unit]
    return [sorted(b) for b in bins], load


def verify(bins, static) -> None:
    """Refuses to emit a partition that is not one."""
    every_name = [
        "%s.test.%s" % (module, name)
        for module, names in static.items()
        for name in names
    ]
    for name in every_name:
        claims = sum(1 for b in bins if any(f in name for f in b))
        if claims != 1:
            sys.exit("%d shards claim %r — refusing to write a bad manifest" % (claims, name))
    for shard in bins:
        for filter_text in shard:
            if not any(filter_text in name for name in every_name):
                sys.exit("filter %r matches no test — refusing to write" % filter_text)
    print("verified: %d named tests, each claimed by exactly one shard" % len(every_name))


# ── emitting ─────────────────────────────────────────────────────────────────

HEADER = '''//! Test-suite shard manifest: which unit tests each parallel `zig build test`
//! binary runs.
//!
//! `zig build test` compiles one test binary PER SHARD and runs them
//! concurrently (the build system runs independent steps in parallel). Every
//! binary is built from the same `src/test_root.zig` module, the same optimize
//! mode and the same Guardian test runner; the only difference is the
//! `--test-filter` set the compiler applies, which is exactly the list below.
//!
//! Each entry is a literal `--test-filter` substring, matched by the COMPILER
//! against the fully-qualified test name (`<dotted source path>.test.<name>`).
//! Two forms are used:
//!
//!   "placement.drc.test."       — every named test in `src/placement/drc.zig`
//!   "placement.router.test.con" — the tests in `src/placement/router.zig`
//!                                 whose names start with `con`
//!
//! The second form exists only for files too expensive to keep whole:
//! `placement/router.zig` alone is 30.8s of a 78.0s serial suite, so no
//! file-granular split can beat it. Splitting on a fixed-length name prefix
//! keeps the entries stable under everything except a rename that changes a
//! test's first three characters — and that rename fails the coverage test in
//! `src/test_root.zig` loudly instead of silently dropping the test.
//!
//! Substring matching has no anchor, so `"exit.test."` also selects
//! `placement.pad_exit.test.*`; atoms that cannot be separated that way are
//! packed into the same shard rather than being renamed.
//!
//! INVARIANTS, all enforced by tests in `src/test_root.zig` rather than by
//! this file's good intentions:
//!
//!   * every named test in src/ is claimed by exactly ONE shard;
//!   * every filter here still names a test;
//!   * every test a shard claims is actually IN that shard's compiled binary
//!     (an unnamed `test` block runs the check inside each shard — a filter
//!     naming a test the compiler never analyzed would otherwise vanish
//!     silently, which is how the first sharded build lost 49 tests while all
//!     eight shards reported PASS).
//!
//! Unnamed `test { _ = @import(...) }` blocks are NOT listed: the compiler
//! links them into every filtered binary regardless of the filters, so each
//! shard runs all of them. They are import bridges with empty bodies, so the
//! duplicate cost is nil; it is why the shard test counts sum to more than the
//! whole suite's count.
//!
//! Balance is by MEASURED wall time, not test count. Regenerate with
//! `scripts/test_shard_balance.py` after a large shift in test cost.

'''


def zig_string(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def emit(bins) -> None:
    out = [HEADER, "pub const shards: []const []const []const u8 = &.{\n"]
    for index, shard in enumerate(bins):
        out.append("    // shard %d\n    &.{\n" % index)
        for filter_text in shard:
            out.append('        "%s",\n' % zig_string(filter_text))
        out.append("    },\n")
    out.append("};\n")
    open(MANIFEST, "w").write("".join(out))
    print("wrote %s (%d filters)" % (MANIFEST, sum(len(b) for b in bins)))


def generate(timings: str, shard_count: int) -> None:
    static = static_tests()
    costs = load_costs(timings)
    atoms = build_atoms(static, costs)
    units = collision_units(atoms)
    bins, load = pack(atoms, units, shard_count)
    verify(bins, static)
    serial = sum(load)
    print(
        "shards=%d  serial=%.1fs  slowest shard=%.1fs  ideal speedup=%.1fx"
        % (shard_count, serial, max(load), serial / max(load))
    )
    emit(bins)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    m = sub.add_parser("measure", help="time every test in a built test binary")
    m.add_argument("binary")
    m.add_argument("timings")
    g = sub.add_parser("generate", help="rewrite src/test_shards.zig")
    g.add_argument("timings")
    g.add_argument("--shards", type=int, default=8)
    args = parser.parse_args()
    if args.command == "measure":
        measure(args.binary, args.timings)
    else:
        generate(args.timings, args.shards)


if __name__ == "__main__":
    main()
