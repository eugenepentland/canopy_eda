#!/usr/bin/env python3
"""Regression tests for scripts/test_affected.py."""

from pathlib import Path
import contextlib
import io
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import test_affected


class AffectedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src/feature").mkdir(parents=True)
        (self.root / "src/serve/assets").mkdir(parents=True)

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def test_reverse_imports_select_consumer_tests_but_not_siblings(self) -> None:
        self.write("src/low.zig", 'test "low behavior" {}\n')
        self.write(
            "src/feature/consumer.zig",
            'const low = @import("../low.zig");\ntest "consumer behavior" { _ = low; }\n',
        )
        self.write("src/feature/sibling.zig", 'test "unrelated sibling" {}\n')
        plan = test_affected.make_plan(self.root, "HEAD", {"src/low.zig"})
        self.assertFalse(plan.full)
        self.assertIn("low behavior", plan.filters)
        self.assertIn("consumer behavior", plan.filters)
        self.assertNotIn("unrelated sibling", plan.filters)

    def test_reverse_walk_stops_before_a_large_cyclic_consumer_layer(self) -> None:
        self.write("src/low.zig", 'test "low" {}\n')
        self.write("src/direct.zig", 'const low = @import("low.zig");\ntest "direct" { _ = low; }\n')
        for index in range(test_affected.MAX_FILTERS):
            self.write(
                f"src/fanout_{index}.zig",
                f'const direct = @import("direct.zig");\ntest "fanout {index}" {{ _ = direct; }}\n',
            )
        plan = test_affected.make_plan(self.root, "HEAD", {"src/low.zig"})
        self.assertFalse(plan.full)
        self.assertIn("direct", plan.filters)
        self.assertNotIn("fanout 0", plan.filters)

    def test_embed_file_change_selects_its_zig_consumers(self) -> None:
        self.write("src/serve/assets/board.js", "const board = true;\n")
        self.write(
            "src/serve/view.zig",
            'const board = @embedFile("assets/board.js");\ntest "viewer contract" { _ = board; }\n',
        )
        plan = test_affected.make_plan(self.root, "HEAD", {"src/serve/assets/board.js"})
        self.assertFalse(plan.full)
        self.assertIn("viewer contract", plan.filters)

    def test_explicit_repository_path_selects_source_contract(self) -> None:
        self.write(".githooks/release.sh", "exit 0\n")
        self.write(
            "src/contracts.zig",
            'test "release source contract" { _ = ".githooks/release.sh"; }\n',
        )
        plan = test_affected.make_plan(self.root, "HEAD", {".githooks/release.sh"})
        self.assertFalse(plan.full)
        self.assertIn("release source contract", plan.filters)

    def test_build_graph_and_uncovered_code_fall_back_to_full(self) -> None:
        self.write("build.zig", "pub fn build() void {}\n")
        build = test_affected.make_plan(self.root, "HEAD", {"build.zig"})
        self.assertTrue(build.full)
        self.write("src/orphan.zig", "pub fn answer() u8 { return 42; }\n")
        orphan = test_affected.make_plan(self.root, "HEAD", {"src/orphan.zig"})
        self.assertTrue(orphan.full)

    def test_git_diff_includes_tracked_and_untracked_files(self) -> None:
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "test"], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "config", "user.email", "test@example.invalid"], check=True
        )
        self.write("src/tracked.zig", 'test "tracked" {}\n')
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "fixture"], check=True)
        self.write("src/tracked.zig", 'test "changed" {}\n')
        self.write("src/new.zig", 'test "new" {}\n')
        changed = test_affected.changed_from(self.root, "HEAD")
        self.assertEqual({"src/tracked.zig", "src/new.zig"}, changed)

    def test_filtered_execution_precedes_whole_suite_analysis(self) -> None:
        fake = self.root / "fake-zig"
        log = self.root / "commands"
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$AFFECTED_TEST_LOG"\n', encoding="utf-8")
        fake.chmod(0o755)
        plan = test_affected.Plan(
            base="HEAD",
            changed=("src/low.zig",),
            affected_sources=("src/low.zig",),
            filters=("low behavior", "route flags grid overflow"),
        )
        with mock.patch.dict(
            os.environ,
            {"AFFECTED_TEST_ZIG": str(fake), "AFFECTED_TEST_LOG": str(log)},
        ):
            with contextlib.redirect_stdout(io.StringIO()):
                test_affected.run_plan(self.root, plan)
        commands = log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(2, len(commands))
        self.assertIn("test -Dtest-filter=low behavior", commands[0])
        self.assertEqual("build --seed=1 test-compile", commands[1])


if __name__ == "__main__":
    unittest.main()
