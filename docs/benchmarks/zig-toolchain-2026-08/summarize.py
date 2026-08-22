#!/usr/bin/env python3
"""Median-summarize the compile/exec TSVs into the report table."""
import collections, statistics, sys, os, re

S = os.path.dirname(os.path.abspath(__file__))


def med(xs):
    return statistics.median(xs) if xs else float('nan')


print("== COMPILE (elapsed / cpu = user+sys, seconds; median of runs) ==")
rows = collections.defaultdict(lambda: {'e': [], 'c': []})
path = os.path.join(S, 'compile_times2.tsv')
if os.path.exists(path):
    for ln in open(path):
        f = ln.rstrip('\n').split('\t')
        if len(f) < 7:
            continue
        tc, mode, kind, idx, times, rc = f[0], f[1], f[2], f[3], f[4], f[5]
        parts = times.split()
        if rc != '0' or len(parts) < 3:
            print(f"  !! {tc} {mode} {kind}#{idx} rc={rc} raw={times}")
            continue
        e, u, s = (float(x) for x in parts[:3])
        rows[(tc, mode, kind)]['e'].append(e)
        rows[(tc, mode, kind)]['c'].append(u + s)
    print(f"{'toolchain':10} {'mode':22} {'kind':12} {'n':>2} {'elapsed':>9} {'cpu':>9}")
    for k in sorted(rows):
        v = rows[k]
        print(f"{k[0]:10} {k[1]:22} {k[2]:12} {len(v['e']):>2} "
              f"{med(v['e']):>9.2f} {med(v['c']):>9.2f}")

print()
print("== EXEC (wall seconds; median of runs) ==")
path = os.path.join(S, 'exec_times.tsv')
ex = collections.defaultdict(lambda: {'e': [], 'c': []})
if os.path.exists(path):
    for ln in open(path):
        f = ln.rstrip('\n').split('\t')
        if len(f) < 5:
            continue
        tc, mode, idx, times, rc = f[:5]
        parts = times.split()
        if rc != '0' or len(parts) < 3:
            print(f"  !! {tc} {mode} #{idx} rc={rc} raw={times}")
            continue
        e, u, s = (float(x) for x in parts[:3])
        ex[(tc, mode)]['e'].append(e)
        ex[(tc, mode)]['c'].append(u + s)
    for k in sorted(ex):
        v = ex[k]
        print(f"{k[0]:10} {k[1]:14} n={len(v['e'])} wall={med(v['e']):.2f}s cpu={med(v['c']):.2f}s")

print()
print("== BENCH per-design median_ms (median across runs) ==")
path = os.path.join(S, 'exec_raw.txt')
if os.path.exists(path):
    cur = None
    per = collections.defaultdict(list)
    for ln in open(path):
        m = re.match(r'=== (\S+) (\S+) run(\d+)', ln)
        if m:
            cur = (m.group(1), m.group(2))
            continue
        m = re.match(r'BENCH (\S+) parts=(\d+) median_ms=([\d.]+).*checksum=(\w+)', ln)
        if m and cur:
            per[(cur[0], cur[1], m.group(1))].append((float(m.group(3)), m.group(4)))
    designs = sorted({k[2] for k in per})
    modes = ['Debug', 'ReleaseSafe', 'ReleaseFast']
    hdr = f"{'design':16}" + ''.join(f"{tc+' '+mo:>22}" for tc in ('0.15.1', '0.16.0') for mo in modes)
    print(hdr)
    for d in designs:
        line = f"{d:16}"
        for tc in ('0.15.1', '0.16.0'):
            for mo in modes:
                vals = per.get((tc, mo, d), [])
                line += f"{med([v[0] for v in vals]):>22.2f}" if vals else f"{'-':>22}"
        print(line)
    print()
    print("checksum agreement:")
    cks = collections.defaultdict(set)
    for (tc, mo, d), vals in per.items():
        for _, c in vals:
            cks[d].add(c)
    for d, cs in sorted(cks.items()):
        print(f"  {d:16} {'OK (identical everywhere)' if len(cs)==1 else 'MISMATCH ' + str(cs)}")
