#!/usr/bin/env python3
"""Median-summarize the v3 compile/exec TSVs (0.15.1 / 0.16.0 / master).

Same shapes as summarize.py, widened to three toolchains.  Pass `--v2` to
summarize the previous run's tables instead.
"""
import collections
import os
import re
import statistics
import sys

S = os.path.dirname(os.path.abspath(__file__))
V2 = '--v2' in sys.argv
SUF = '' if V2 else '3'
TCS = ('0.15.1', '0.16.0') if V2 else ('0.15.1', '0.16.0', 'master')
MODES = ['Debug', 'ReleaseSafe', 'ReleaseFast']


def med(xs):
    return statistics.median(xs) if xs else float('nan')


print("== COMPILE (elapsed / cpu = user+sys, seconds; median of runs) ==")
rows = collections.defaultdict(lambda: {'e': [], 'c': []})
path = os.path.join(S, f'compile_times{SUF or "2"}.tsv')
if os.path.exists(path):
    for ln in open(path):
        f = ln.rstrip('\n').split('\t')
        if len(f) < 6:
            continue
        tc, mode, kind, idx, times, rc = f[:6]
        parts = times.split()
        if rc != '0' or len(parts) < 3:
            print(f"  !! {tc} {mode} {kind}#{idx} rc={rc} raw={times}")
            continue
        e, u, s = (float(x) for x in parts[:3])
        rows[(tc, mode, kind)]['e'].append(e)
        rows[(tc, mode, kind)]['c'].append(u + s)
    print(f"{'mode':14}{'kind':10}" + ''.join(f"{tc:>26}" for tc in TCS))
    print(f"{'':24}" + ''.join(f"{'elapsed     cpu':>26}" for _ in TCS))
    for mode in MODES:
        for kind in ('cold', 'rebuild'):
            if not any((tc, mode, kind) in rows for tc in TCS):
                continue
            line = f"{mode:14}{kind:10}"
            for tc in TCS:
                v = rows.get((tc, mode, kind))
                line += f"{med(v['e']):>16.2f}{med(v['c']):>10.2f}" if v else f"{'-':>26}"
            print(line)

print()
print("== EXEC (whole-run wall seconds; median of runs) ==")
path = os.path.join(S, f'exec_times{SUF}.tsv')
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
    print(f"{'mode':16}" + ''.join(f"{tc:>18}" for tc in TCS))
    for mode in MODES:
        line = f"{mode:16}"
        for tc in TCS:
            v = ex.get((tc, mode))
            line += f"{med(v['e']):>16.2f}s" if v else f"{'-':>18}"
        print(line)

print()
print("== BENCH per-design median_ms (median across runs) ==")
path = os.path.join(S, f'exec_raw{SUF}.txt')
per = collections.defaultdict(list)
if os.path.exists(path):
    cur = None
    for ln in open(path):
        m = re.match(r'=== (\S+) (\S+) run(\d+)', ln)
        if m:
            cur = (m.group(1), m.group(2))
            continue
        m = re.match(r'BENCH (\S+) parts=(\d+) median_ms=([\d.]+).*checksum=(\w+)', ln)
        if m and cur:
            per[(cur[0], cur[1], m.group(1))].append((float(m.group(3)), m.group(4)))
    designs = sorted({k[2] for k in per})
    for mode in MODES:
        print(f"\n  -- {mode} --")
        print(f"  {'design':18}" + ''.join(f"{tc:>14}" for tc in TCS) +
              f"{'m/0.15.1':>12}{'0.16/0.15.1':>13}")
        for d in designs:
            vals = {tc: med([v[0] for v in per.get((tc, mode, d), [])]) for tc in TCS}
            line = f"  {d:18}" + ''.join(f"{vals[tc]:>14.2f}" for tc in TCS)
            base = vals.get('0.15.1')
            if base and base == base:
                for tc in ('master', '0.16.0'):
                    v = vals.get(tc, float('nan'))
                    line += f"{v / base:>12.2f}x" if v == v else f"{'-':>13}"
            print(line)

    print()
    print("checksum agreement (across every toolchain x mode x run):")
    cks = collections.defaultdict(set)
    for (tc, mo, d), vals in per.items():
        for _, c in vals:
            cks[d].add(c)
    for d, cs in sorted(cks.items()):
        ok = 'OK (identical everywhere): ' + next(iter(cs)) if len(cs) == 1 else 'MISMATCH ' + str(cs)
        print(f"  {d:18} {ok}")
