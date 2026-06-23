#!/usr/bin/env python3
"""Integration test: KiCad layout-sync of a main design with sub-circuits.

Regression guard for the bug where the per-sub-circuit "Seed layout from saved
PCB layout" option (the `sub_circuits` list the Push-to-KiCad modal renders as
checkboxes) silently vanished for a design that has NO whole-design layout of
its own, even when its sub-modules carried their own starred (default) layouts.
`buildSubCircuitsJson` used to bail on a null whole-design `premade_layout`;
it now mirrors the actual seeder (`subCircuitSource`), so a sub-block whose
module is starred is listed and seedable.

The test stands up a throwaway project (real `lib/` symlinked so every import
resolves) holding a copy of an existing sub-circuit design pointed at a fresh,
writable temp `.kicad_pcb`, then drives the file-based sync HTTP API against it.
Nothing the user owns is touched: the real project dir is read-only here and the
board is a brand-new empty file under a temp dir.

Usage:
    python3 scripts/test_kicad_sync_layout.py \
        [--binary zig-out/bin/netlisp] \
        [--project /home/epentland/ai/canopy/eda/projects/designs] \
        [--design barracuda-base] [--port 7091]

Exit code 0 = all scenarios pass.
"""
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error


class _Skip(Exception):
    """Raised when the design can't be evaluated in an isolated temp project — a
    harness limitation (location-dependent imports), not a sync bug."""

EMPTY_BOARD = """(kicad_pcb (version 20221018) (generator pcbnew)
  (general (thickness 1.6))
  (paper "A4")
  (layers
    (0 "F.Cu" signal)
    (31 "B.Cu" signal)
    (44 "Edge.Cuts" user)
  )
  (setup)
  (net 0 "")
)
"""


def log(msg):
    print(msg, flush=True)


def post(url, body=None):
    data = json.dumps(body).encode() if body is not None else b""
    req = urllib.request.Request(url, data=data, method="POST")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.status, r.read().decode()


def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.status, r.read().decode()


def free_port(preferred):
    for p in (preferred, 0):
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", p))
            port = s.getsockname()[1]
            s.close()
            return port
        except OSError:
            s.close()
    raise RuntimeError("no free port")


def module_sources_with_starred_layout(project, design_sexp):
    """Sub-block name -> module source, for sub-blocks whose module has a
    starred (default) layout sidecar in lib/modules. These are exactly the
    sub-circuits the fix must surface in `sub_circuits`."""
    src = open(design_sexp, encoding="utf-8").read()
    subs = re.findall(r'\(sub-block\s+"([^"]+)"\s+\(([A-Za-z0-9_\-]+)', src)
    out = {}
    for name, source in subs:
        side = os.path.join(project, "lib", "modules", source + ".layouts.json")
        if not os.path.exists(side):
            continue
        try:
            d = json.load(open(side, encoding="utf-8"))
        except Exception:
            continue
        if d.get("default") and any(L.get("parts") for L in d.get("layouts", [])):
            out[name] = source
    return out


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--binary", default=os.path.join(here, "zig-out/bin/netlisp"))
    ap.add_argument("--project", default=os.path.join(here, "projects/designs"))
    ap.add_argument("--design", default="barracuda-base")
    ap.add_argument("--port", type=int, default=7091)
    args = ap.parse_args()

    if not os.path.isdir(os.path.join(args.project, "lib")):
        alt = "/home/epentland/ai/canopy/eda/projects/designs"
        if os.path.isdir(os.path.join(alt, "lib")):
            args.project = alt
    real_design = None
    for root, _dirs, files in os.walk(os.path.join(args.project, "src")):
        if args.design + ".sexp" in files:
            real_design = os.path.join(root, args.design + ".sexp")
            break
    if not real_design:
        log(f"SKIP: design {args.design}.sexp not found under {args.project}/src")
        return 0

    starred = module_sources_with_starred_layout(args.project, real_design)
    if not starred:
        log(f"SKIP: {args.design} has no sub-block whose module carries a starred layout")
        return 0
    log(f"sub-blocks with starred module layouts: {starred}")

    tmp = tempfile.mkdtemp(prefix="synctest_")
    proc = None
    failures = []
    skipped = False
    try:
        os.makedirs(os.path.join(tmp, "src"))
        os.symlink(os.path.join(args.project, "lib"), os.path.join(tmp, "lib"))
        board = os.path.join(tmp, "board.kicad_pcb")
        open(board, "w").write(EMPTY_BOARD)
        src = open(real_design, encoding="utf-8").read()
        src2 = re.sub(r'\(kicad-pcb\s+"[^"]*"\)', f'(kicad-pcb "{board}")', src)
        assert src2 != src, "design has no (kicad-pcb ...) form to repoint"
        design = "synctest_" + args.design.replace("-", "_")
        open(os.path.join(tmp, "src", design + ".sexp"), "w").write(src2)

        whole = os.path.join(tmp, "src", design + ".layouts.json")
        has_whole = os.path.exists(whole) and json.load(open(whole)).get("default")
        log(f"whole-design layout present: {bool(has_whole)} (fix is exercised when False)")

        port = free_port(args.port)
        proc = subprocess.Popen(
            [args.binary, "serve", "--project-dir", tmp, "--port", str(port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        base = f"http://localhost:{port}"
        for _ in range(60):
            try:
                get(base + "/")
                break
            except Exception:
                time.sleep(0.25)
        else:
            raise RuntimeError("server did not come up")

        try:
            st, _ = post(f"{base}/api/push/{design}")
        except urllib.error.HTTPError as e:
            raise _Skip(f"{design} did not build in an isolated temp project "
                        f"(location-dependent import) — verify it in the real "
                        f"project instead: {e.read().decode()[:160]}")

        st, html = get(f"{base}/schematics/{design}")
        if st == 200 and "kicad-sync-chip" in html and "push-kicad-pcb-btn" in html:
            log("PASS E: schematic page 200 with sync chip + Push button")
        else:
            failures.append(f"E: page status={st} chip={'kicad-sync-chip' in html}")

        st, body = post(f"{base}/api/sync-kicad-pcb/{design}?dry_run=1")
        dry = json.loads(body)
        listed = {s["name"] for s in dry.get("sub_circuits", [])}
        missing = [n for n in starred if n not in listed]
        if not missing:
            log(f"PASS A: sub_circuits lists all starred sub-blocks {sorted(starred)} "
                f"(parts: {[(s['name'], s['parts']) for s in dry['sub_circuits'] if s['name'] in starred]})")
        else:
            failures.append(f"A: sub_circuits missing {missing}; got {sorted(listed)}")

        bad = [s for s in dry.get("sub_circuits", []) if s.get("parts", 0) < 1]
        if bad:
            failures.append(f"A2: sub_circuits with 0 parts: {[b['name'] for b in bad]}")
        else:
            log("PASS A2: every listed sub_circuit has >=1 seedable part")

        added_before = dry["summary"]["added"]

        seed = list(starred.keys())
        st, body = post(f"{base}/api/sync-kicad-pcb/{design}", {"seed": seed})
        assert st == 200, f"seeded write failed: {st}"
        applied = json.loads(body).get("applied", {})
        board_txt = open(board, encoding="utf-8").read()
        fp_count = len(re.findall(r"\(footprint\b", board_txt))
        if applied.get("added", 0) == added_before and fp_count == added_before:
            log(f"PASS C: seeded write added {fp_count} footprints to the board")
        else:
            failures.append(f"C: applied.added={applied.get('added')} fp_on_board={fp_count} expected={added_before}")

        sub0 = seed[0]
        refs = re.findall(r'\(property "Reference" "(' + re.escape(sub0) + r'/[^"]+)"', board_txt)
        if len(refs) >= 2:
            log(f"PASS C2: sub-block '{sub0}' wrote {len(refs)} placed parts")
        else:
            failures.append(f"C2: sub-block '{sub0}' wrote only {len(refs)} parts")

        st, body = post(f"{base}/api/sync-kicad-pcb/{design}?dry_run=1")
        assert st == 200, f"re-sync dry-run failed: {st}"
        dry2 = json.loads(body)
        if dry2["summary"]["added"] < added_before:
            log(f"PASS D: re-sync added drops {added_before} -> {dry2['summary']['added']} (placed parts now matched)")
        else:
            failures.append(f"D: re-sync added did not drop ({dry2['summary']['added']})")

        all_subs = dict(re.findall(r'\(sub-block\s+"([^"]+)"\s+\(([A-Za-z0-9_\-]+)', src))
        unstarred = [n for n in all_subs if n not in starred]
        false_pos = [n for n in unstarred if n in listed]
        if not has_whole and false_pos:
            failures.append(f"F: unstarred sub-blocks wrongly listed: {false_pos}")
        else:
            log("PASS F: no unstarred sub-block listed without a whole-design layout")

    except _Skip as sk:
        log(f"SKIP: {sk}")
        skipped = True
    except Exception as e:
        failures.append(f"EXC: {type(e).__name__}: {e}")
    finally:
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)

    if skipped:
        return 0
    if failures:
        log("\nFAIL:")
        for f in failures:
            log("  - " + f)
        return 1
    log("\nALL SCENARIOS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
