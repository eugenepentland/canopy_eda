#!/usr/bin/env python3
"""Corpus A/B of the rough PCB seed vs the starred hand layouts.

For every module that has a starred (default) `.layouts.json`, solve the rough
seed (`?rough=1`) and the starred layout (`?layout=<name>`) via a running
`eda serve`, then compare per interchangeable class (kind|nets|footprint), per
anchor-IC edge. The goal of the rough seed is hand-LIKENESS (put each part in the
same general area so the board is easy to finish by dragging), not the score — so
the columns are:

    area%  per-class per-edge count agreement, incl. `center`  (right region)
    side%  same but over non-center parts only                 (ring-side accuracy)
    gapR   median part->IC gap of the rough seed, mm           (radial tightness)
    gapS   median part->IC gap of the starred layout, mm       (the hand target ~0)
    load   does the starred layout actually load? (see below)

LOAD PARTITION (important): a starred layout saved in a PARENT board's flattened
ref-des namespace cannot be applied to the standalone module — `placeFromPoses`
keys poses by ref-des, finds no match, and every part collapses to (0,0) and reads
as `center`, scoring a spurious 0%. This script flags those by intersecting the
saved poses' refs with the standalone solve's refs; only `load=ok` rows are a valid
yardstick (they feed the means). Fixing that bug (key poses by origin_key) is what
makes the `broken` rows measurable.

Usage:
    # start a server first:  eda serve --project-dir projects/designs --port 7050
    python3 scripts/rough_corpus_bench.py
    python3 scripts/rough_corpus_bench.py --base http://localhost:7099
    python3 scripts/rough_corpus_bench.py --project-dir projects/designs --json out.json

The harness has no third-party dependencies (stdlib urllib/json only).
"""
import argparse
import json
import os
import statistics
import sys
import urllib.parse
import urllib.request
from collections import defaultdict

SIDES = ["left", "right", "top", "bottom", "center"]


def starred_designs(project_dir):
    """Map module name -> default (starred) layout name, for every sidecar that has one."""
    out = {}
    for root, _, files in os.walk(project_dir):
        for fn in files:
            if not fn.endswith(".layouts.json"):
                continue
            try:
                d = json.load(open(os.path.join(root, fn)))
            except (OSError, ValueError):
                continue
            if d.get("default"):
                out[fn[: -len(".layouts.json")]] = d
    return out


def fetch(base, name, query):
    url = f"{base}/api/pcb-describe/{urllib.parse.quote(name)}?{query}"
    try:
        with urllib.request.urlopen(url, timeout=120) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001 - report and skip
        return {"_err": str(e)}


def classkey(p):
    nets = ",".join(sorted(p.get("nets", [])))
    return f"{p.get('kind')}|{nets}|{round(p.get('w_mm', 0), 1)}x{round(p.get('h_mm', 0), 1)}"


def analyze(base, name, sidecar, regen):
    rough = fetch(base, name, "rough=1" + ("&regen=1" if regen else ""))
    star = fetch(base, name, "layout=" + urllib.parse.quote(sidecar["default"]))
    if "_err" in rough or "_err" in star:
        return {"name": name, "err": rough.get("_err") or star.get("_err")}

    def parts(d):
        return [p for p in d.get("parts", []) if p.get("side") != "anchor"]

    rp, sp = parts(rough), parts(star)
    rc, sc = defaultdict(lambda: defaultdict(int)), defaultdict(lambda: defaultdict(int))
    for p in rp:
        rc[classkey(p)][p.get("side")] += 1
    for p in sp:
        sc[classkey(p)][p.get("side")] += 1
    total = matched = nc_total = nc_matched = 0
    for c in set(rc) | set(sc):
        for s in SIDES:
            r, st = rc[c].get(s, 0), sc[c].get(s, 0)
            total += st
            matched += min(r, st)
            if s != "center":
                nc_total += st
                nc_matched += min(r, st)
    # A starred layout that failed to load collapses every part onto the anchor
    # (origin) — detect it by zero coordinate spread rather than by ref overlap,
    # so origin-keyed layouts (saved in a foreign ref-des namespace but bridged by
    # `rekeyPosesByOrigin`) correctly count as loaded.
    xs, ys = [p.get("x", 0) for p in sp], [p.get("y", 0) for p in sp]
    spread = (max(xs) - min(xs) if xs else 0) + (max(ys) - min(ys) if ys else 0)
    load_ok = spread > 0.5
    med = lambda ps: round(statistics.median([p.get("gap_mm", 0) for p in ps]), 2) if ps else 0
    return {
        "name": name,
        "n": len(sp),
        "load_ok": load_ok,
        "area": round(100 * matched / total, 1) if total else 0.0,
        "side": round(100 * nc_matched / nc_total, 1) if nc_total else None,
        "gap_rough": med(rp),
        "gap_starred": med(sp),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://localhost:7050", help="running eda serve base URL")
    ap.add_argument("--project-dir", default="projects/designs", help="where the .layouts.json sidecars live")
    ap.add_argument("--regen", action="store_true", help="force a fresh rough solve (avoids cache)")
    ap.add_argument("--json", help="also write the rows as JSON to this path")
    args = ap.parse_args()

    ds = starred_designs(args.project_dir)
    if not ds:
        sys.exit(f"no starred .layouts.json under {args.project_dir!r}")
    rows = [analyze(args.base, n, ds[n], args.regen) for n in sorted(ds)]

    hdr = f"{'':1}{'module':22} {'n':>3} {'area%':>6} {'side%':>6} {'gapR':>5} {'gapS':>5} {'load':>7}"
    print(hdr)
    print("-" * len(hdr))
    loadable = []
    for r in rows:
        if r.get("err"):
            print(f"  {r['name']:22} ERR {r['err'][:42]}")
            continue
        ok = r["load_ok"]
        side = r["side"] if r["side"] is not None else -1
        mark = "*" if ok else " "
        print(f"{mark} {r['name']:22} {r['n']:>3} {r['area']:>6} {side:>6} "
              f"{r['gap_rough']:>5} {r['gap_starred']:>5} {'ok' if ok else 'broken':>7}")
        if ok:
            loadable.append(r)
    if loadable:
        print("-" * len(hdr))
        a = sum(r["area"] for r in loadable) / len(loadable)
        gr = statistics.median([r["gap_rough"] for r in loadable])
        print(f"  loadable(*): n={len(loadable)}  mean area%={a:.1f}  median gapR={gr:.2f} mm")
        print(f"  ({len(rows) - len(loadable)} broken = starred saved in a parent ref-des namespace; "
              "not a valid yardstick until poses key on origin_key)")
    if args.json:
        json.dump({r["name"]: r for r in rows}, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
