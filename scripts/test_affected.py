#!/usr/bin/env python3
"""Run the tests conservatively affected by the current Git diff.

This is a development accelerator, never a release verifier. It discovers
named Zig tests in changed modules and their reverse import/embed dependents,
adds a permanent boundary-smoke set, runs that compiler-filtered Debug subset,
then semantically analyzes the complete suite with `test-compile`.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
from pathlib import Path
import re
import subprocess
import sys
from collections import defaultdict


DEPENDENCY_RE = re.compile(r'@(import|embedFile)\(\s*"([^"\\]+)"\s*\)')
TEST_RE = re.compile(r'\btest\s+"((?:[^"\\]|\\.)*)"')

# These small, fail-closed boundaries run on every affected subset. Keep this
# aligned in spirit with build.zig's mutation smoke tier; the release/build
# contract filters are added because this command itself is part of that seam.
ALWAYS_FILTERS = (
    "parse rejects excessively deep nesting",
    "fuzz: parser never crashes",
    "modulo rejects non-positive divisor",
    "checkedInt rejects",
    "designSiblingPath rejects",
    "sanitizeKicadName neutralizes traversal",
    "route flags grid overflow",
    "mcpSetPartPoses rejects an empty poses array",
    "release preparation",
    "template predecessor",
    # The two shard-integrity boundaries: they prove src/test_shards.zig's
    # manifest still runs every named test exactly once and imports every module
    # whose tests run. A shard that silently drops a test (or a module that no
    # shard imports) ships green everywhere else, so these run on every subset.
    "shard manifest runs every named test exactly once",
    "the shard import bridge lists every module whose tests run",
)

# These inputs define how the suite is compiled or selected. Guessing a subset
# after changing one of them would be circular, so they deliberately run all.
FULL_RUN_FILES = {
    "build.zig",
    "build.zig.zon",
    "guardian.toml",
    "src/test_root.zig",
    "src/test_shards.zig",
    "scripts/test_affected.py",
}
FULL_RUN_PREFIXES = (".guardian/",)
MAX_FILTERS = 400
MAX_REVERSE_DEPTH = 3
IGNORED_DIRS = {".git", ".claude", ".zig-cache", "zig-cache", "zig-out"}


@dataclasses.dataclass(frozen=True)
class Plan:
    base: str
    changed: tuple[str, ...]
    affected_sources: tuple[str, ...]
    filters: tuple[str, ...]
    full_reason: str | None = None

    @property
    def full(self) -> bool:
        return self.full_reason is not None


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def git_paths(root: Path, *args: str) -> set[str]:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return {item.decode() for item in result.stdout.split(b"\0") if item}


def changed_from(root: Path, base: str) -> set[str]:
    changed = git_paths(root, "diff", "--name-only", "-z", base, "--")
    changed.update(git_paths(root, "ls-files", "--others", "--exclude-standard", "-z"))
    return changed


def default_base(root: Path) -> str:
    explicit = os.environ.get("AFFECTED_BASE")
    if explicit:
        return explicit
    if changed_from(root, "HEAD"):
        return "HEAD"
    branch = git(root, "branch", "--show-current")
    if branch and branch != "main":
        try:
            return git(root, "merge-base", "main", "HEAD")
        except subprocess.CalledProcessError:
            pass
    return "HEAD"


def repo_files(root: Path, suffix: str) -> list[Path]:
    files: list[Path] = []
    for path in root.rglob(f"*{suffix}"):
        rel = path.relative_to(root)
        if any(part in IGNORED_DIRS for part in rel.parts):
            continue
        files.append(rel)
    return sorted(files)


def read_text(root: Path, rel: Path) -> str:
    try:
        return (root / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def resolve_dependency(source: Path, value: str) -> Path | None:
    # Package imports (`std`, `httpz`, `build_options`) do not name repository
    # paths. Relative Zig imports and every embedFile value do.
    if "/" not in value and not value.endswith((".zig", ".js", ".css", ".wasm")):
        return None
    candidate = Path(os.path.normpath(source.parent / value))
    if candidate.is_absolute() or ".." in candidate.parts:
        return None
    return candidate


def dependency_graph(root: Path, sources: list[Path]) -> tuple[dict[Path, set[Path]], dict[Path, str]]:
    reverse: dict[Path, set[Path]] = defaultdict(set)
    texts: dict[Path, str] = {}
    for source in sources:
        text = read_text(root, source)
        texts[source] = text
        for _, value in DEPENDENCY_RE.findall(text):
            dependency = resolve_dependency(source, value)
            if dependency is not None:
                reverse[dependency].add(source)
    return reverse, texts


def quoted_path_dependents(changed: set[Path], texts: dict[Path, str]) -> dict[Path, set[Path]]:
    reverse: dict[Path, set[Path]] = defaultdict(set)
    for target in changed:
        needle = f'"{target.as_posix()}"'
        for source, text in texts.items():
            if needle in text:
                reverse[target].add(source)
    return reverse


def bounded_reverse_closure(
    seeds: set[Path], reverse: dict[Path, set[Path]], texts: dict[Path, str]
) -> set[Path]:
    """Walk consumers without letting test-only import cycles select the world.

    Direct consumers are always included. Later layers are included only while
    their combined named-test set remains beneath MAX_FILTERS; very low-level
    changes still trigger the explicit full-suite fallback below.
    """
    seen = set(seeds)
    frontier = set(seeds)
    for depth in range(MAX_REVERSE_DEPTH):
        next_frontier: set[Path] = set()
        for current in frontier:
            next_frontier.update(reverse.get(current, ()))
        next_frontier.difference_update(seen)
        if not next_frontier:
            break
        trial = seen | next_frontier
        named = set()
        for source in trial:
            if source in texts:
                named.update(test_names(texts[source]))
        if depth > 0 and len(named) + len(ALWAYS_FILTERS) > MAX_FILTERS:
            break
        seen = trial
        frontier = next_frontier
    return seen


def test_names(text: str) -> set[str]:
    # Zig filters accept the source spelling as a substring. Decode the common
    # quote/backslash escapes so argv contains the name the compiler sees.
    names: set[str] = set()
    for raw in TEST_RE.findall(text):
        names.add(raw.replace(r'\"', '"').replace(r"\\", "\\"))
    return names


def make_plan(root: Path, base: str, changed_names: set[str], force_full: bool = False) -> Plan:
    changed = {Path(name) for name in changed_names}
    full_reason: str | None = "requested with --full" if force_full else None
    if full_reason is None:
        for path in sorted(changed):
            name = path.as_posix()
            if name in FULL_RUN_FILES or name.startswith(FULL_RUN_PREFIXES):
                full_reason = f"{name} controls the test or build graph"
                break

    sources = repo_files(root, ".zig")
    reverse, texts = dependency_graph(root, sources)
    for dependency, dependents in quoted_path_dependents(changed, texts).items():
        reverse[dependency].update(dependents)

    seeds = set(changed)
    affected = bounded_reverse_closure(seeds, reverse, texts)
    affected_sources = sorted(path for path in affected if path.suffix == ".zig" and path in texts)

    selected = set(ALWAYS_FILTERS)
    for source in affected_sources:
        selected.update(test_names(texts[source]))

    code_changed = any(path.suffix in {".zig", ".js", ".css", ".wasm"} for path in changed)
    affected_named = selected.difference(ALWAYS_FILTERS)
    if full_reason is None and code_changed and not affected_named:
        full_reason = "changed code has no discoverable named behavioral tests"
    if full_reason is None and len(selected) > MAX_FILTERS:
        full_reason = f"{len(selected)} filters exceed the {MAX_FILTERS}-filter cutoff"

    return Plan(
        base=base,
        changed=tuple(sorted(path.as_posix() for path in changed)),
        affected_sources=tuple(path.as_posix() for path in affected_sources),
        filters=tuple(sorted(selected)),
        full_reason=full_reason,
    )


def print_plan(plan: Plan, verbose: bool = False) -> None:
    print(f"affected-tests: base {plan.base}; {len(plan.changed)} changed file(s)")
    for path in plan.changed:
        print(f"  changed  {path}")
    if plan.full:
        print(f"affected-tests: strategy FULL — {plan.full_reason}")
    else:
        print(
            "affected-tests: strategy FILTERED — "
            f"{len(plan.affected_sources)} affected Zig module(s), {len(plan.filters)} filter(s)"
        )
        shown = plan.filters if verbose else plan.filters[:10]
        for name in shown:
            print(f"  filter   {name}")
        if len(shown) < len(plan.filters):
            print(f"  ...      {len(plan.filters) - len(shown)} more (use -Daffected-list=true to inspect all)")


def run_plan(root: Path, plan: Plan) -> None:
    zig = os.environ.get("AFFECTED_TEST_ZIG", os.environ.get("ZIG", "zig"))
    command = [zig, "build", "--seed=1", "test"]
    if not plan.full:
        command.extend(f"-Dtest-filter={name}" for name in plan.filters)
    description = "complete Debug suite" if plan.full else f"filtered Debug suite ({len(plan.filters)} filters)"
    print(f"affected-tests: running {description}", flush=True)
    subprocess.run(command, cwd=root, check=True)
    if plan.full:
        print("affected-tests: full suite already analyzed every test; test-compile is redundant")
        return
    compile_command = [zig, "build", "--seed=1", "test-compile"]
    print("affected-tests: analyzing the complete suite with test-compile", flush=True)
    subprocess.run(compile_command, cwd=root, check=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Git revision to diff against (default: HEAD while dirty, else merge-base main)")
    parser.add_argument("--list", action="store_true", help="print the selection without running tests")
    parser.add_argument("--full", action="store_true", help="force the complete Debug suite")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    base = args.base or default_base(root)
    try:
        changed = changed_from(root, base)
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr
        print(f"affected-tests: cannot diff base {base!r}: {detail.strip()}", file=sys.stderr)
        return 2
    plan = make_plan(root, base, changed, args.full)
    print_plan(plan, verbose=args.list)
    if args.list:
        return 0
    try:
        run_plan(root, plan)
    except subprocess.CalledProcessError as error:
        print(f"affected-tests: command failed with exit {error.returncode}", file=sys.stderr)
        return error.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
