#!/usr/bin/env python3
"""Commit a stable batch of live design changes after a quiet period.

This is deliberately a checkpoint/backup writer, not a source-control workflow:
it only runs on the configured live branch, skips hooks, never pushes, and
leaves unrelated staged paths alone. Repeated timer invocations persist the
observed tree fingerprint under the repo's common git directory; a commit is
made only after that fingerprint has remained unchanged for the quiet period.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time


EXCLUDED_PREFIXES = ("history/", "backups/")
EXCLUDED_FRAGMENTS = ("/backups/", ".bak-")


class CheckpointError(RuntimeError):
    pass


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        ("git", "-C", os.fspath(repo), *args),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise CheckpointError(f"git {' '.join(args)} failed: {detail}")
    return result


def git_text(repo: Path, *args: str) -> str:
    return git(repo, *args).stdout.decode("utf-8", "replace").strip()


def is_excluded(path: str) -> bool:
    return path.startswith(EXCLUDED_PREFIXES) or any(part in path for part in EXCLUDED_FRAGMENTS)


def changed_paths(repo: Path) -> list[str]:
    unstaged = git(repo, "diff", "--name-only", "--no-renames", "-z", "--").stdout
    staged = git(repo, "diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD", "--").stdout
    untracked = git(repo, "ls-files", "--others", "--exclude-standard", "-z").stdout
    staged_paths = {
        raw.decode("utf-8", "surrogateescape")
        for raw in staged.split(b"\0")
        if raw
    }
    paths = {
        raw.decode("utf-8", "surrogateescape")
        for raw in (unstaged + untracked).split(b"\0")
        if raw
    }
    return sorted(path for path in paths if path not in staged_paths and not is_excluded(path))


def hash_file(digest: object, path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        digest.update(b"deleted\0")
        return
    digest.update(f"{stat.S_IFMT(info.st_mode):o}:{stat.S_IMODE(info.st_mode):o}\0".encode())
    if path.is_symlink():
        digest.update(os.readlink(path).encode("utf-8", "surrogateescape"))
    elif path.is_file():
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)


def tree_fingerprint(repo: Path, paths: list[str]) -> str:
    digest = hashlib.sha256()
    for relative in paths:
        digest.update(relative.encode("utf-8", "surrogateescape"))
        digest.update(b"\0")
        hash_file(digest, repo / relative)
        digest.update(b"\0")
    return digest.hexdigest()


def read_state(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    return value if isinstance(value, dict) else {}


def write_state(path: Path, fingerprint: str, first_seen: float) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps({"fingerprint": fingerprint, "first_seen": first_seen}) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def clear_state(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def checkpoint(repo: Path, branch: str, quiet_seconds: int, force: bool, verbose: bool) -> int:
    repo = repo.resolve()
    top = Path(git_text(repo, "rev-parse", "--show-toplevel")).resolve()
    if top != repo:
        raise CheckpointError(f"{repo} is inside {top}, but is not its own git checkout")
    if git_text(repo, "branch", "--show-current") != branch:
        if verbose:
            print(f"checkpoint-designs: skipped; live checkout is not branch {branch!r}")
        return 0

    common = Path(git_text(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    state_path = common / "designs-periodic-checkpoint.json"
    lock_path = common / "designs-periodic-checkpoint.lock"
    with lock_path.open("a+b") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0

        paths = changed_paths(repo)
        if not paths:
            clear_state(state_path)
            return 0

        fingerprint = tree_fingerprint(repo, paths)
        now = time.time()
        state = read_state(state_path)
        if state.get("fingerprint") != fingerprint:
            write_state(state_path, fingerprint, now)
            if verbose:
                print(f"checkpoint-designs: watching {len(paths)} changed path(s)")
            return 0

        first_seen = state.get("first_seen")
        if not isinstance(first_seen, (int, float)):
            first_seen = now
            write_state(state_path, fingerprint, first_seen)
        remaining = quiet_seconds - (now - first_seen)
        if not force and remaining > 0:
            if verbose:
                print(f"checkpoint-designs: quiet-period wait {remaining:.0f}s")
            return 0

        # Recheck under the checkpoint lock immediately before staging. Writers
        # do not take this lock, so this narrows (but cannot eliminate) the race;
        # a changing file yields a new fingerprint on the next timer pass.
        latest_paths = changed_paths(repo)
        latest_fingerprint = tree_fingerprint(repo, latest_paths)
        if latest_paths != paths or latest_fingerprint != fingerprint:
            write_state(state_path, latest_fingerprint, now)
            return 0

        git(repo, "add", "-A", "--", *paths)
        staged = git(repo, "diff", "--cached", "--quiet", "--", *paths, check=False)
        if staged.returncode == 0:
            clear_state(state_path)
            return 0
        if staged.returncode != 1:
            raise CheckpointError("could not inspect staged checkpoint")

        stamp = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(now))
        author = "netlisp-checkpoint <netlisp-checkpoint@local>"
        git(
            repo,
            "-c",
            "user.name=netlisp-checkpoint",
            "-c",
            "user.email=netlisp-checkpoint@local",
            "commit",
            "--no-verify",
            "--author",
            author,
            "--only",
            "-m",
            f"checkpoint: live designs {stamp}",
            "--",
            *paths,
        )
        clear_state(state_path)
        print(f"checkpoint-designs: committed {len(paths)} stable path(s)")
        return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", required=True, type=Path)
    parser.add_argument("--branch", default="main")
    parser.add_argument("--quiet-seconds", type=int, default=300)
    parser.add_argument("--force", action="store_true", help="commit an already-observed batch immediately")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.quiet_seconds < 0:
        parser.error("--quiet-seconds must be non-negative")
    return args


def main() -> int:
    args = parse_args()
    try:
        return checkpoint(
            args.project_dir,
            args.branch,
            args.quiet_seconds,
            args.force,
            args.verbose,
        )
    except CheckpointError as error:
        print(f"checkpoint-designs: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
