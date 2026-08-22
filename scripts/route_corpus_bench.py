#!/usr/bin/env python3
"""Corpus benchmark of the autorouter — stage 0 of docs/autorouter-plan.md.

Routes every board in the corpus from its CURRENT saved copper and records what
came out: nets closed, DRC by severity, copper laid, wall clock. Prints a
per-board table plus the geometric mean of the routed fraction, and can write
each metric into the `[benchmark]` ledger so a result survives the session that
produced it.

WHY THIS EXISTS. Every routing change in the 2026-07 barracuda effort was judged
on ONE board, and at least two that looked reasonable turned out net-negative on
the very board they were designed against (the DRC error budget; the multi-net
rip tier). A single-board metric cannot see that, and neither can a person. The
gate this enables is the one in the plan: **geomean must not fall, and no board
may regress by more than one net.**

It measures the ENGINE, not the boards. A board sitting at 90/90 because someone
hand-finished it still reports 90/90 here — what moves is the delta when the
router changes underneath a fixed corpus. Run it before and after a change and
diff the tables; that is the whole workflow.

Usage:
    # start a server against a SCRATCH COPY of the project (routing mutates):
    netlisp serve --project-dir /tmp/bench-designs --port 7099

    python3 scripts/route_corpus_bench.py --base http://localhost:7099
    python3 scripts/route_corpus_bench.py --json out.json          # machine-readable
    python3 scripts/route_corpus_bench.py --record .               # write the ledger

NEVER point --base at a server running on projects/designs itself: `route` and
`close_open_nets` write layout sidecars, and a benchmark must not edit the boards
it measures.
"""

import argparse
import json
import math
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULT_BASE = "http://localhost:7099"
# Wall-clock ceiling for one board's route. A board that needs longer is a
# finding in itself, recorded as a timeout rather than hanging the run.
BOARD_TIMEOUT_S = 900


def mcp(base, tool, args, timeout=BOARD_TIMEOUT_S):
    """Call one MCP tool, returning its parsed JSON payload (or {} on failure)."""
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args},
        }
    ).encode()
    req = urllib.request.Request(
        base.rstrip("/") + "/mcp",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        return {"_error": str(e)}
    try:
        return json.loads(payload["result"]["content"][0]["text"])
    except (KeyError, IndexError, json.JSONDecodeError):
        return payload.get("result", {})


def describe(base, name):
    """The connectivity + DRC facts for a board, from the shared oracle."""
    url = f"{base.rstrip('/')}/api/pcb-describe/{name}"
    try:
        with urllib.request.urlopen(url, timeout=300) as r:
            return json.load(r)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return {}


def board_names(base):
    """Every design the server knows, in a stable order."""
    listed = mcp(base, "list_designs", {}, timeout=60)
    # The tool returns a bare list on some builds and a wrapper object on others.
    if isinstance(listed, dict):
        names = listed.get("designs") or listed.get("names") or []
    else:
        names = listed or []
    out = []
    for d in names:
        out.append(d.get("name") if isinstance(d, dict) else d)
    # Dedupe: the listing can repeat a name (one design reachable under several
    # paths), and a board counted twice would weight the geomean twice.
    return sorted({n for n in out if n})


def errors_of(desc):
    """(total, error-severity) DRC counts from a describe payload."""
    routed = desc.get("routed") or {}
    lst = routed.get("drc_list") or []
    return routed.get("drc", len(lst)), sum(1 for v in lst if v.get("sev") == "err")


def measure(base, name, route):
    """One board's row: route it (optionally), then read the oracle."""
    t0 = time.monotonic()
    err = None
    if route:
        res = mcp(base, "route_pcb", {"name": name})
        if "_error" in res:
            err = res["_error"]
    elapsed = time.monotonic() - t0
    desc = describe(base, name)
    r = desc.get("routed") or {}
    total, errs = errors_of(desc)
    return {
        "board": name,
        "routed": r.get("routed", 0),
        "total": r.get("total", 0),
        "open": r.get("unrouted") or [],
        "drc": total,
        "drc_errors": errs,
        "trace_mm": round(r.get("trace_mm", 0.0), 1),
        "vias": r.get("vias", 0),
        "secs": round(elapsed, 1),
        "error": err,
    }


def geomean(fractions):
    """Geometric mean of the per-board routed fractions (0 boards -> 0.0).

    Geometric, not arithmetic: it refuses to let one easy board's 100% paper
    over another's 60%, which is exactly the averaging mistake a router change
    can otherwise hide behind.
    """
    vals = [f for f in fractions if f > 0]
    if not vals:
        return 0.0
    return math.exp(sum(math.log(v) for v in vals) / len(vals))


def record(rows, gm, project_dir, binary):
    """Write the run into the [benchmark] ledger so it outlives the session."""
    def put(metric, value, unit, direction, note):
        subprocess.run(
            [binary, "bench", "set", metric, str(value), "--unit", unit,
             "--dir", direction, "--note", note, project_dir],
            check=False,
        )

    put("route_corpus_geomean_pct", round(gm * 100, 2), "%", "max",
        f"{len(rows)} boards, autorouter corpus bench")
    put("route_corpus_open_nets", sum(r["total"] - r["routed"] for r in rows), "nets",
        "min", "total unrouted across the corpus")
    put("route_corpus_drc_errors", sum(r["drc_errors"] for r in rows), "errors",
        "min", "error-severity DRC across the corpus")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default=DEFAULT_BASE,
                    help="server base URL (must NOT be serving projects/designs)")
    ap.add_argument("--boards", help="comma-separated subset; default is every design")
    ap.add_argument("--no-route", action="store_true",
                    help="measure the saved copper without re-routing (fast baseline)")
    ap.add_argument("--json", help="write the full result set here")
    ap.add_argument("--record", metavar="PROJECT_DIR",
                    help="write metrics into that project's [benchmark] ledger")
    ap.add_argument("--guardian", default="../guardian-zig/zig-out/bin/guardian-check",
                    help="guardian-check binary used by --record")
    args = ap.parse_args()

    names = ([b.strip() for b in args.boards.split(",") if b.strip()]
             if args.boards else board_names(args.base))
    if not names:
        print("no designs found — is the server up?", file=sys.stderr)
        return 1

    rows = []
    for n in names:
        row = measure(args.base, n, route=not args.no_route)
        rows.append(row)
        print(
            f"{row['board']:<22} {row['routed']:>3}/{row['total']:<3} "
            f"drc {row['drc']:>3}/{row['drc_errors']:<3}err "
            f"{row['trace_mm']:>8.1f}mm {row['vias']:>4}v {row['secs']:>7.1f}s"
            + (f"  ERROR {row['error']}" if row["error"] else ""),
            flush=True,
        )

    # Boards with no routable nets (no copper, no netlist to close) are excluded
    # from the geomean rather than scored 0 — they say nothing about the router,
    # and counting them would swamp the metric with corpus bookkeeping.
    gm = geomean([r["routed"] / r["total"] for r in rows if r["total"]])
    measured = sum(1 for r in rows if r["total"])
    opens = sum(r["total"] - r["routed"] for r in rows)
    errs = sum(r["drc_errors"] for r in rows)
    print("-" * 78)
    print(f"{len(rows)} boards ({measured} with routable nets) | "
          f"geomean routed {gm * 100:.2f}% | "
          f"{opens} net(s) open | {errs} DRC error(s) | "
          f"{sum(r['secs'] for r in rows):.1f}s total")

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"rows": rows, "geomean": gm, "open": opens, "drc_errors": errs},
                      f, indent=1)
        print(f"wrote {args.json}")
    if args.record:
        record(rows, gm, args.record, args.guardian)
    return 0


if __name__ == "__main__":
    sys.exit(main())
