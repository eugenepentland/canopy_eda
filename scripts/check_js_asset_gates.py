#!/usr/bin/env python3
"""Every first-party browser asset must be named by a Guardian gate.

Guardian scans Zig, spec and config. It does not parse JavaScript, so a broken
edit to `src/serve/assets/*.js` rides a green gate on an unchanged Zig tree —
that was audit finding DRIFT-INFRA-003, where twelve first-party assets had no
gate at all and `shape_sketch.test.js` was wired to no runner.

That finding was closed by adding `[[external]]` blocks by hand, which closes
it only for the files someone remembered. This script is the standing form of
the same rule: enumerate the assets on disk, and require each one to be named
by some external's COMMAND. A new asset with no gate fails here, and so does a
gate whose file was renamed out from under it.

Naming the file in an external's `inputs` is deliberately NOT enough. `inputs`
feeds the green-run digest — it decides when a gate re-runs, not whether the
file is ever parsed. Only a command argument means something actually reads it.

`--syntax` goes one step further and PARSES every first-party asset here, with
Node, rather than trusting that the declared gate runs. Measured 2026-08-29:
`[[external]]` gates in this tree are advisory — an external whose command
exits nonzero leaves `guardian-check all` reporting "0 blocking" — so the
twenty-one `node --check` declarations were not, on their own, gating anything.
build.zig runs this script with `--syntax` off the `test` step, which is what
makes the rule real while the declarations stay for the digest.

Read-only. Reports every problem it finds, not just the first.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

ASSET_DIR = "src/serve/assets"
ASSET_SUFFIXES = (".js", ".mjs")

# Third-party code we ship verbatim. Upstream's syntax is upstream's problem,
# and `node --check` on a 600 KiB minified bundle buys nothing — but the
# exemption is spelled out per file, with the reason, so that vendoring a new
# library is a deliberate act rather than a silent hole. Each path is checked
# for existence below: an exemption for a file that no longer exists is itself
# a defect, because it is the shape a stale allowlist takes.
VENDORED: dict[str, str] = {
    "src/serve/assets/three.min.js": "Three.js r128, MIT — minified upstream build",
    "src/serve/assets/OrbitControls.js": "Three.js r128 example controls, MIT",
    "src/serve/assets/occt-import-js.js": "occt-import-js Emscripten build, LGPL",
    "src/serve/assets/codemirror.bundle.js": "CodeMirror 5 bundle, MIT — minified",
    "src/serve/assets/pcb_earcut.js": "Mapbox earcut, ISC — extracted from the Three.js build",
    "src/serve/assets/vendor": "pdf.js drop — gated individually by the pdfjs externals",
}


class Problem:
    def __init__(self, where: str, message: str) -> None:
        self.where = where
        self.message = message

    def __str__(self) -> str:
        return f"{self.where}: {self.message}"


def _is_vendored(rel: str) -> bool:
    """True when `rel` is an exempt file or sits under an exempt directory."""
    if rel in VENDORED:
        return True
    return any(rel.startswith(prefix + "/") for prefix in VENDORED)


def find_assets(root: Path) -> list[str]:
    """Every browser script under the asset directory, repo-relative, sorted."""
    base = root / ASSET_DIR
    if not base.is_dir():
        return []
    found = [
        path.relative_to(root).as_posix()
        for path in base.rglob("*")
        if path.is_file() and path.suffix in ASSET_SUFFIXES
    ]
    return sorted(found)


def gated_paths(externals: list[dict]) -> dict[str, str]:
    """Map every path named by an external's command to the gate that names it.

    A gate can name several files (`node --check a.js b.js`), and several gates
    can name one file; the first gate wins for reporting purposes.
    """
    gated: dict[str, str] = {}
    for external in externals:
        if not isinstance(external, dict):
            continue
        name = str(external.get("name", "<unnamed>"))
        command = external.get("command")
        if not isinstance(command, list):
            continue
        for arg in command:
            if not isinstance(arg, str) or not arg.endswith(ASSET_SUFFIXES):
                continue
            gated.setdefault(arg, name)
    return gated


def _parse_one(root: Path, rel: str) -> Problem | None:
    """`node --check` a single asset. Returns a Problem when it does not parse."""
    result = subprocess.run(
        ["node", "--check", rel],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return None
    detail = (result.stderr or result.stdout).strip().splitlines()
    # Node leads with the offending file and line, then the message; keep the
    # first two informative lines so the failure is actionable in the log.
    head = " | ".join(line.strip() for line in detail[:4] if line.strip())
    return Problem(rel, f"does not parse: {head}")


def check_syntax(root: Path, assets: list[str], also: list[str] | None = None) -> list[Problem]:
    """Parse every first-party asset — and everything else a gate names.

    A syntax error in a browser asset is invisible to every Zig-side check and
    breaks the page at load. `also` carries the other JavaScript the
    `[[external]]` blocks name — the perf harnesses, the editor invariant
    probe, the WASM parity script — so that the whole set of `node --check`
    declarations becomes real here rather than staying advisory.

    Node startup dominates, so the files are checked concurrently; the whole
    set costs well under a second.
    """
    targets = {rel for rel in assets if not _is_vendored(rel)}
    for rel in also or []:
        if not _is_vendored(rel) and (root / rel).is_file():
            targets.add(rel)
    first_party = sorted(targets)
    if not first_party:
        return []
    if shutil.which("node") is None:
        # Deliberately a failure, not a skip. A gate that quietly disappears
        # when a tool is missing is the exact shape of the finding this script
        # exists to close.
        return [
            Problem(
                "node",
                "not on PATH, so no browser asset can be parsed — install Node "
                "or drop --syntax, but do not let the gate pass unrun",
            )
        ]
    problems: list[Problem] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for problem in pool.map(lambda rel: _parse_one(root, rel), first_party):
            if problem is not None:
                problems.append(problem)
    problems.sort(key=lambda p: p.where)
    return problems


def check(root: Path, config_path: Path) -> list[Problem]:
    problems: list[Problem] = []

    try:
        with config_path.open("rb") as handle:
            config = tomllib.load(handle)
    except FileNotFoundError:
        return [Problem(str(config_path), "guardian config not found")]
    except tomllib.TOMLDecodeError as exc:
        return [Problem(str(config_path), f"is not valid TOML: {exc}")]

    externals = config.get("external", [])
    if not isinstance(externals, list):
        return [Problem(str(config_path), "`[[external]]` is not a list of tables")]

    assets = find_assets(root)
    if not assets:
        # Bail loudly rather than reporting a vacuous pass: with no assets
        # found, every rule below would hold for the wrong reason.
        return [Problem(str(root / ASSET_DIR), "contains no .js/.mjs files — wrong repo root?")]

    gated = gated_paths(externals)

    for rel in assets:
        if _is_vendored(rel) or rel in gated:
            continue
        problems.append(
            Problem(
                rel,
                "first-party browser asset with no Guardian gate — no `[[external]]` "
                "command names it, so a syntax error in it rides a green gate. Add a "
                "`node --check` external, or record it in VENDORED with a reason",
            )
        )

    for rel, reason in sorted(VENDORED.items()):
        if not (root / rel).exists():
            problems.append(
                Problem(
                    rel,
                    f"exempted as vendored ({reason}) but does not exist — "
                    "drop the exemption",
                )
            )

    for rel, gate in sorted(gated.items()):
        if not (root / rel).exists():
            problems.append(
                Problem(
                    rel,
                    f"named by `[[external]]` {gate!r} but does not exist — the gate "
                    "is passing over a file that was renamed or deleted",
                )
            )

    return problems


def summarize(root: Path, config_path: Path, parsed: bool, out) -> None:
    with config_path.open("rb") as handle:
        config = tomllib.load(handle)
    assets = find_assets(root)
    gated = gated_paths(config.get("external", []))
    vendored = [rel for rel in assets if _is_vendored(rel)]
    first_party = [rel for rel in assets if not _is_vendored(rel)]
    if parsed:
        extra = sum(
            1 for rel in gated
            if rel not in first_party and not _is_vendored(rel) and (root / rel).is_file()
        )
        parsed_note = f" and parsed, with {extra} more script(s) a gate names parsed too"
    else:
        parsed_note = ""
    print(
        f"js asset gates OK — {len(first_party)} first-party asset(s) all gated{parsed_note}, "
        f"{len(vendored)} vendored, {len(gated)} path(s) named by externals",
        file=out,
    )


def main(argv: list[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(
        prog="check_js_asset_gates.py",
        description=(
            "Verify that every first-party JavaScript asset under "
            f"{ASSET_DIR}/ is named by the command of some [[external]] gate "
            "in guardian.toml, that every vendored exemption still exists, and "
            "that no gate names a file that has been renamed away."
        ),
        epilog=(
            "Exits 0 with a summary when every asset is gated, and 1 listing "
            "every problem at once when it is not. Read-only."
        ),
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=default_root,
        help="repository root (default: the directory above this script)",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="path to guardian.toml (default: guardian.toml under --root)",
    )
    parser.add_argument(
        "--syntax",
        action="store_true",
        help=(
            "also run `node --check` over every first-party asset, rather than "
            "trusting that the declared gate runs"
        ),
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    config = (args.config or (root / "guardian.toml")).resolve()

    problems = check(root, config)
    if args.syntax and not problems:
        # Only after the declaration rule holds: with an asset directory that
        # could not be read, a clean parse pass would be a vacuous pass.
        with config.open("rb") as handle:
            named = list(gated_paths(tomllib.load(handle).get("external", [])))
        problems = check_syntax(root, find_assets(root), named)
    if problems:
        print(f"js asset gates FAILED — {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "\nGuardian does not parse JavaScript. An asset no gate names is an "
            "asset nothing checks.",
            file=sys.stderr,
        )
        return 1

    summarize(root, config, args.syntax, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
