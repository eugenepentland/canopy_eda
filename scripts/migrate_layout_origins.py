#!/usr/bin/env python3
"""Stamp the renumber-stable `origin` onto legacy saved layout poses.

Saved `.layouts.json` poses key on ref-des. A layout captured in a parent board's
flattened namespace (or before a ref-des renumber) then fails to load against the
standalone module: `rekeyPosesByOrigin` can only bridge poses that carry an
`origin` (module-local `origin_key`), and legacy entries have none, so every part
collapses to (0,0) and reads as `center` (a spurious 0% in layout-match).

The optimizer/serve code already writes + consumes `origin` correctly; this only
back-fills it on existing data. For each starred module it pulls the standalone
solve's ordered (ref, origin) list from a running `eda serve` and zips it onto each
saved layout BY INDEX — but only after verifying the ref-des-prefix sequence
(U/C/R/L/…) matches position-for-position, so a layout whose part order diverges is
reported and skipped rather than corrupted.

Usage:
    # start a server first:  eda serve --project-dir projects/designs --port 7050
    python3 scripts/migrate_layout_origins.py                 # dry-run (report only)
    python3 scripts/migrate_layout_origins.py --apply         # write + .bak backups
    python3 scripts/migrate_layout_origins.py --base http://localhost:7099 --apply

No third-party dependencies (stdlib only).
"""
import argparse
import json
import os
import shutil
import sys
import urllib.parse
import urllib.request


def leaf_prefix(ref):
    """First alpha run of a ref-des leaf ('a/C156' -> 'C', 'R_FB' -> 'R')."""
    leaf = ref.split("/")[-1]
    out = ""
    for ch in leaf:
        if ch.isalpha() or ch == "_":
            out += ch
        else:
            break
    return out.rstrip("_")


def standalone_parts(base, name):
    """Ordered (ref, origin, prefix) for the module solved standalone."""
    url = f"{base}/api/pcb-describe/{urllib.parse.quote(name)}?rough=1&regen=1"
    with urllib.request.urlopen(url, timeout=120) as r:
        d = json.load(r)
    return [(p.get("ref", ""), p.get("origin", ""), leaf_prefix(p.get("ref", ""))) for p in d.get("parts", [])]


def migrate_file(base, path):
    """Returns (module, [(layout_name, status, n_stamped, n_total)]) for reporting."""
    name = os.path.basename(path)[: -len(".layouts.json")]
    data = json.load(open(path))
    try:
        std = standalone_parts(base, name)
    except Exception as e:  # noqa: BLE001
        return name, [("<solve>", f"ERR {e}", 0, 0)], False
    results, changed = [], False
    for L in data.get("layouts", []):
        poses = L.get("parts", [])
        if not poses:
            results.append((L["name"], "empty", 0, 0))
            continue
        if all(p.get("origin") for p in poses):
            results.append((L["name"], "already-has-origin", 0, len(poses)))
            continue
        std_origin = {ref: origin for ref, origin, _ in std if ref}
        # Prefer exact ref-match (provably correct: ref IS the identity); only fall
        # back to verified index-match when the refs are a foreign namespace.
        if all(p.get("ref") in std_origin for p in poses):
            origins, method = [std_origin[p["ref"]] for p in poses], "stamped(ref)"
        elif len(poses) == len(std) and all(leaf_prefix(p.get("ref", "")) == std[i][2] for i, p in enumerate(poses)):
            origins, method = [std[i][1] for i in range(len(poses))], "stamped(index)"
        else:
            results.append((L["name"], "order-mismatch (skipped)", 0, len(poses)))
            continue
        n = 0
        for p, origin in zip(poses, origins):
            if origin and not p.get("origin"):
                p["origin"] = origin
                n += 1
        if n:
            changed = True
        results.append((L["name"], method, n, len(poses)))
    return name, results, changed, data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://localhost:7050")
    ap.add_argument("--project-dir", default="projects/designs")
    ap.add_argument("--apply", action="store_true", help="write changes (default: dry-run)")
    args = ap.parse_args()

    files = []
    for root, _, names in os.walk(args.project_dir):
        for fn in names:
            if fn.endswith(".layouts.json"):
                try:
                    if json.load(open(os.path.join(root, fn))).get("default"):
                        files.append(os.path.join(root, fn))
                except (OSError, ValueError):
                    pass
    if not files:
        sys.exit(f"no starred .layouts.json under {args.project_dir!r}")

    total_stamped = 0
    for path in sorted(files):
        name, results, changed, *rest = migrate_file(args.base, path)
        print(f"\n{name}")
        for lname, status, n, tot in results:
            print(f"  {status:26} {n:>3}/{tot:<3} {lname}")
        total_stamped += sum(n for _, _, n, _ in results)
        if changed and args.apply:
            shutil.copy2(path, path + ".bak")
            json.dump(rest[0], open(path, "w"), indent=1)
            print(f"  -> WROTE {path} (backup {path}.bak)")
    print(f"\n{'APPLIED' if args.apply else 'DRY-RUN'}: {total_stamped} poses stamped"
          + ("" if args.apply else " (re-run with --apply to write)"))


if __name__ == "__main__":
    main()
