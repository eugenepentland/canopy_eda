#!/usr/bin/env python3
"""Gate AUDIT-LEDGER.toml against the tree it describes.

The ledger records which audit finding was closed, by what, and whether it is
still closed. Its load-bearing claim is the `test` field: a finding marked
`fixed` names the regression test that proves it. This checker verifies that
test STILL EXISTS as `test "<name>"` under src/**/*.zig — because a fixed
finding whose regression test was deleted or renamed has silently lost its
guard, which is exactly how the July 2026 `</script>` finding stayed reopened
for two months with a green suite.

Read-only. Reports every problem it finds, not just the first.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tomllib
from pathlib import Path

SEVERITIES = frozenset({"critical", "high", "medium", "low"})
STATUSES = ("fixed", "open", "waived")

ID_RE = re.compile(r"\A[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*\Z")
# Zig test declarations. Anchored to the start of a line (allowing indentation)
# so a test name mentioned inside a comment or a string does not count as a
# declaration — the whole point is to find the real thing.
TEST_DECL_RE = re.compile(rb'^[ \t]*test "([^"\n]*)"', re.MULTILINE)


def _ID_DECL_RE(anchor: str) -> re.Pattern[bytes]:
    """`id: "anchor"` / `id = "anchor"` / `"id": "anchor"`, in either quote.

    A harness anchor has to name a DECLARED check, not merely a string that
    occurs somewhere in the file — the probe mentions each invariant's name in
    its fixture keys and revert targets too, so a bare substring match would
    survive the invariant itself being renamed away.
    """
    return re.compile(
        rb'["\']?\bid["\']?\s*[:=]\s*["\']' + re.escape(anchor.encode()) + rb'["\']'
    )

# Fields every entry may carry, by status. Anything else is a typo, and a typo
# in a field name silently drops the constraint it was meant to express.
COMMON_FIELDS = frozenset(
    {"id", "summary", "severity", "status", "file", "note", "guard", "reopens"}
)
STATUS_FIELDS = {
    "fixed": COMMON_FIELDS | {"fixed_in", "test", "untested", "harness"},
    "open": COMMON_FIELDS,
    "waived": COMMON_FIELDS | {"reason"},
}


class Problem:
    """One ledger defect, tagged with the entry it belongs to."""

    def __init__(self, where: str, message: str) -> None:
        self.where = where
        self.message = message

    def __str__(self) -> str:
        return f"{self.where}: {self.message}"


def index_tests(root: Path) -> dict[str, str]:
    """Map every `test "<name>"` under src/ to the file that declares it.

    A duplicate name keeps its first file; the ledger only asks whether a name
    exists at all.
    """
    index: dict[str, str] = {}
    src = root / "src"
    if not src.is_dir():
        return index
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(".zig"):
                continue
            path = Path(dirpath) / name
            try:
                data = path.read_bytes()
            except OSError:
                continue
            rel = path.relative_to(root).as_posix()
            for match in TEST_DECL_RE.finditer(data):
                index.setdefault(match.group(1).decode("utf-8", "replace"), rel)
    return index


def _as_names(value: object) -> list[str] | None:
    """Accept a `test` field written as one name or as a list of names."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(v, str) for v in value):
        return list(value)
    return None


def _looks_like_path(value: str) -> bool:
    return "/" in value and not any(c.isspace() for c in value)


def _check_harness(raw: object, root: Path, add) -> bool:
    """Verify a non-Zig regression harness, and report whether it holds.

    Some fixes are not provable by a Zig test: the browser-editor findings live
    in JavaScript that Guardian cannot parse, and the JS-asset-gate rule is a
    property of a directory. Those are guarded by a real harness — a headless
    browser probe, a directory-walking checker — and `harness` names it so the
    ledger can check the same thing it checks for `test`: that the guard still
    exists, by name.

    A `path#anchor` value asserts more than the file's existence: the anchor
    must still be DECLARED as an id inside it — `id: "anchor"`, `id = "anchor"`
    or `"id": "anchor"`. That is what makes `run.js#row-aliasing` mean "the
    probe still declares that invariant" rather than merely "the probe file is
    still there" — a probe that dropped the invariant would otherwise pass.

    Matching a bare quoted occurrence is not enough, and this was measured:
    renaming the probe's `id: "row-aliasing"` to `row-aliasing-v2` left three
    other quoted `"row-aliasing"` strings in the file (a fixture key, a revert
    target, a design name) and a substring check stayed green.
    """
    if not isinstance(raw, str) or not raw.strip():
        add("`harness`, when present, must be a non-empty string")
        return False

    path_part, _, anchor = raw.partition("#")
    if not _looks_like_path(path_part):
        add(f"`harness` must name a path (optionally `path#anchor`), got {raw!r}")
        return False

    target = root / path_part
    if not target.is_file():
        add(
            f"`harness` names a file that does not exist: {path_part!r} — the "
            "harness that guarded this fix was deleted or renamed"
        )
        return False

    if not anchor:
        return True

    try:
        body = target.read_bytes()
    except OSError as exc:
        add(f"`harness` file {path_part!r} could not be read: {exc}")
        return False

    if not _ID_DECL_RE(anchor).search(body):
        add(
            f"`harness` anchor {anchor!r} is no longer declared as an id in "
            f"{path_part!r} — the specific check that guarded this fix is gone, "
            "even though the harness file remains"
        )
        return False
    return True


def _check_entry(
    entry: dict,
    where: str,
    root: Path,
    tests: dict[str, str],
    problems: list[Problem],
) -> None:
    def add(message: str) -> None:
        problems.append(Problem(where, message))

    summary = entry.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        add("missing a non-empty `summary`")

    severity = entry.get("severity")
    if severity not in SEVERITIES:
        add(f"`severity` must be one of {sorted(SEVERITIES)}, got {severity!r}")

    status = entry.get("status")
    if status not in STATUSES:
        add(f"`status` must be one of {list(STATUSES)}, got {status!r}")
        return  # every remaining rule is status-dependent

    unknown = set(entry) - STATUS_FIELDS[status]
    if unknown:
        add(
            f"unknown field(s) for status {status!r}: {sorted(unknown)} "
            "— a misspelled field silently drops the constraint it encodes"
        )

    files = entry.get("file")
    if not isinstance(files, list) or not files or not all(isinstance(f, str) for f in files):
        add("`file` must be a non-empty list of paths")
    else:
        for rel in files:
            if not (root / rel).exists():
                add(f"`file` entry {rel!r} does not exist — the record is stale")

    guard = entry.get("guard")
    if guard is not None:
        if not isinstance(guard, str) or not guard.strip():
            add("`guard`, when present, must be a non-empty string")
        elif _looks_like_path(guard) and not (root / guard).exists():
            add(f"`guard` names a path that does not exist: {guard!r}")

    if status == "fixed":
        _check_fixed(entry, root, tests, add)
    elif status == "open":
        if not str(entry.get("note", "")).strip():
            add("status `open` requires a `note` explaining why it is still open")
    elif status == "waived":
        if not str(entry.get("reason", "")).strip():
            add("status `waived` requires a `reason`")


def _check_fixed(entry: dict, root: Path, tests: dict[str, str], add) -> None:
    if not str(entry.get("fixed_in", "")).strip():
        add("status `fixed` requires `fixed_in` naming the commit that closed it")

    untested = entry.get("untested", False)
    if not isinstance(untested, bool):
        add(f"`untested` must be a boolean, got {untested!r}")
        untested = bool(untested)

    raw_tests = entry.get("test")
    raw_harness = entry.get("harness")
    has_harness = raw_harness is not None and _check_harness(raw_harness, root, add)

    if untested:
        # The deliberate escape hatch for a fix with no regression test. It must
        # be spelled out rather than implied by an absent field, and it must say
        # why — these are the entries the summary lists on every run.
        if raw_tests is not None:
            add("`untested = true` and `test` are mutually exclusive — drop one")
        if raw_harness is not None:
            add("`untested = true` and `harness` are mutually exclusive — drop one")
        if not str(entry.get("note", "")).strip():
            add("`untested = true` requires a `note` recording why there is no test")
        return

    if raw_tests is None:
        # A harness alone is enough for a fix no Zig test can reach, but only a
        # VERIFIED one: `_check_harness` has already reported why if it failed,
        # and a failed harness must not silently stand in for a missing test.
        if not has_harness:
            add(
                "status `fixed` requires `test` naming the regression test that proves it, "
                "or `harness` naming a non-Zig one (or `untested = true` with a `note`, "
                "if there genuinely is none)"
            )
        return

    names = _as_names(raw_tests)
    if names is None:
        add("`test` must be a test name or a list of test names")
        return
    if not names:
        add("`test` is empty — name the regression test or set `untested = true`")
        return

    for name in names:
        if not name.strip():
            add("`test` contains an empty name")
        elif name not in tests:
            add(
                f'no `test "{name}"` exists under src/**/*.zig — the regression '
                "test that guarded this fix was deleted or renamed"
            )


def check(ledger_path: Path, root: Path) -> tuple[list[Problem], list[dict]]:
    """Validate the ledger. Returns (problems, entries)."""
    problems: list[Problem] = []

    try:
        with ledger_path.open("rb") as handle:
            data = tomllib.load(handle)
    except FileNotFoundError:
        return [Problem(str(ledger_path), "ledger not found")], []
    except tomllib.TOMLDecodeError as exc:
        return [Problem(str(ledger_path), f"is not valid TOML: {exc}")], []

    entries = data.get("finding", [])
    if not isinstance(entries, list) or not entries:
        return [Problem(str(ledger_path), "contains no [[finding]] entries")], []

    tests = index_tests(root)
    if not tests:
        problems.append(
            Problem(
                str(root),
                "found no zig tests under src/ — wrong repo root, so every "
                "`test` claim below would fail for the wrong reason",
            )
        )
        return problems, entries

    seen: dict[str, int] = {}
    for position, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            problems.append(Problem(f"[[finding]] #{position}", "is not a table"))
            continue

        raw_id = entry.get("id")
        if not isinstance(raw_id, str) or not raw_id.strip():
            problems.append(Problem(f"[[finding]] #{position}", "missing a non-empty `id`"))
            where = f"[[finding]] #{position}"
        else:
            where = raw_id
            if not ID_RE.match(raw_id):
                problems.append(
                    Problem(where, "`id` should be upper-case dash-separated, e.g. DRIFT-SEC-001")
                )
            if raw_id in seen:
                problems.append(
                    Problem(where, f"duplicate `id` — already used by entry #{seen[raw_id]}")
                )
            else:
                seen[raw_id] = position

        _check_entry(entry, where, root, tests, problems)

    # `reopens` is the machine-readable link that makes a reopened class
    # visible. A dangling link is a broken chain of custody.
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        target = entry.get("reopens")
        if target is None:
            continue
        if not isinstance(target, str) or target not in seen:
            problems.append(
                Problem(str(entry.get("id", "?")), f"`reopens` names an unknown finding: {target!r}")
            )

    return problems, entries


def summarize(entries: list[dict], out) -> None:
    counts = {status: 0 for status in STATUSES}
    untested: list[dict] = []
    harnessed: list[dict] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        status = entry.get("status")
        if status in counts:
            counts[status] += 1
        if status != "fixed":
            continue
        if entry.get("untested"):
            untested.append(entry)
        elif entry.get("test") is None and entry.get("harness") is not None:
            harnessed.append(entry)

    total = sum(counts.values())
    parts = ", ".join(f"{counts[s]} {s}" for s in STATUSES)
    print(f"audit ledger OK — {total} findings: {parts}", file=out)

    if harnessed:
        # Not a defect — but these are guarded by something the unit suite does
        # not run, so say which harness has to keep working for the claim to
        # hold. A harness nobody runs is the failure mode here.
        print(
            f"\n{len(harnessed)} fixed finding(s) guarded by a harness, not a zig test:",
            file=out,
        )
        for entry in harnessed:
            print(f"  {entry.get('id')}  {entry.get('harness')}", file=out)

    if untested:
        # Never let these go quiet. A fix with no regression test is the exact
        # condition this ledger exists to surface.
        print(
            f"\n{len(untested)} fixed finding(s) have NO regression test:",
            file=out,
        )
        for entry in untested:
            print(f"  {entry.get('id')}  {entry.get('summary', '')[:96]}", file=out)


def main(argv: list[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(
        prog="check_audit_ledger.py",
        description=(
            "Verify AUDIT-LEDGER.toml against the tree: every finding marked "
            "`fixed` must name a regression test that still exists under "
            "src/**/*.zig, every entry must carry the fields its status "
            "requires, and every id must be unique."
        ),
        epilog=(
            "Exits 0 with a status summary when the ledger is sound, and 1 "
            "listing every problem at once when it is not. Read-only."
        ),
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=default_root,
        help="repository root (default: the directory above this script)",
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        default=None,
        help="path to the ledger (default: AUDIT-LEDGER.toml under --root)",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    ledger = (args.ledger or (root / "AUDIT-LEDGER.toml")).resolve()

    problems, entries = check(ledger, root)

    if problems:
        print(f"audit ledger FAILED — {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "\nA `fixed` finding must name a regression test that exists. If the "
            "test was renamed, update the ledger; if it was deleted, the finding "
            "is no longer guarded and should be reopened.",
            file=sys.stderr,
        )
        return 1

    summarize(entries, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
