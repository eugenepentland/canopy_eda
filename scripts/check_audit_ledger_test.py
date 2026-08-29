#!/usr/bin/env python3
"""Regression tests for scripts/check_audit_ledger.py.

The checker's whole value is that it FAILS when a fixed finding's regression
test stops existing. A checker never shown to fail is not evidence, so the
first two tests below are the load-bearing ones: red on a bad ledger, green on
a good one. The last test runs it against this repository's real ledger.
"""

from pathlib import Path
import contextlib
import io
import tempfile
import unittest

import check_audit_ledger


GOOD_ENTRY = """
[[finding]]
id = "X-001"
summary = "a real defect"
severity = "high"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "the guard holds"
"""


class LedgerCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        # The fixture tree declares exactly two tests. Everything the ledgers
        # below claim is measured against these.
        (self.root / "src/thing.zig").write_text(
            'test "the guard holds" {}\n'
            'test "the other guard holds" {}\n'
            '// test "a name that only appears in a comment" is not a declaration\n',
            encoding="utf-8",
        )

    def write_ledger(self, body: str) -> Path:
        path = self.root / "AUDIT-LEDGER.toml"
        path.write_text(body, encoding="utf-8")
        return path

    def run_main(self, body: str) -> tuple[int, str, str]:
        ledger = self.write_ledger(body)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check_audit_ledger.main(["--root", str(self.root), "--ledger", str(ledger)])
        return code, out.getvalue(), err.getvalue()

    # ── the two that matter ──────────────────────────────────────────────

    def test_fails_when_a_fixed_findings_test_does_not_exist(self) -> None:
        """The point of the gate: a deleted or renamed regression test is caught."""
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-002"
summary = "a fix whose regression test was renamed away"
severity = "critical"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "the guard that used to hold"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("X-002", err)
        self.assertIn("the guard that used to hold", err)
        self.assertIn("deleted or renamed", err)

    def test_passes_on_a_good_ledger_and_prints_a_status_summary(self) -> None:
        code, out, err = self.run_main(GOOD_ENTRY)
        self.assertEqual(0, code, msg=err)
        self.assertIn("audit ledger OK", out)
        self.assertIn("1 fixed", out)

    # ── the same check, in the shapes it has to survive ──────────────────

    def test_a_test_name_only_mentioned_in_a_comment_does_not_count(self) -> None:
        """A prose mention must not satisfy a `test` claim."""
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-003"
summary = "claims a name that exists only inside a comment"
severity = "medium"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "a name that only appears in a comment"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("X-003", err)

    def test_every_named_test_in_a_list_is_checked(self) -> None:
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-004"
summary = "two tests, only one of which survives"
severity = "high"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = ["the guard holds", "the guard that vanished"]
"""
        )
        self.assertEqual(1, code)
        self.assertIn("the guard that vanished", err)
        self.assertNotIn('`test "the guard holds"`', err)

    def test_reports_every_problem_at_once_rather_than_the_first(self) -> None:
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-005"
summary = "first broken entry"
severity = "high"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "gone one"

[[finding]]
id = "X-006"
summary = "second broken entry"
severity = "high"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "gone two"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("gone one", err)
        self.assertIn("gone two", err)
        self.assertIn("2 problem(s)", err)

    # ── field and identity rules ─────────────────────────────────────────

    def test_duplicate_ids_are_rejected(self) -> None:
        code, _, err = self.run_main(GOOD_ENTRY + GOOD_ENTRY)
        self.assertEqual(1, code)
        self.assertIn("duplicate `id`", err)

    def test_status_required_fields_are_enforced(self) -> None:
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-007"
summary = "fixed with no commit"
severity = "low"
status = "fixed"
file = ["src/thing.zig"]
test = "the guard holds"

[[finding]]
id = "X-008"
summary = "open with no explanation"
severity = "low"
status = "open"
file = ["src/thing.zig"]

[[finding]]
id = "X-009"
summary = "waived with no reason"
severity = "low"
status = "waived"
file = ["src/thing.zig"]
"""
        )
        self.assertEqual(1, code)
        self.assertIn("requires `fixed_in`", err)
        self.assertIn("requires a `note`", err)
        self.assertIn("requires a `reason`", err)

    def test_untested_needs_a_note_and_is_listed_in_the_summary(self) -> None:
        bad_code, _, err = self.run_main(
            """
[[finding]]
id = "X-010"
summary = "fixed with no test and no explanation"
severity = "high"
status = "fixed"
untested = true
file = ["src/thing.zig"]
fixed_in = "abc1234"
"""
        )
        self.assertEqual(1, bad_code)
        self.assertIn("requires a `note`", err)

        good_code, out, err = self.run_main(
            """
[[finding]]
id = "X-011"
summary = "fixed in a JS asset no zig test can reach"
severity = "high"
status = "fixed"
untested = true
file = ["src/thing.zig"]
fixed_in = "abc1234"
note = "NO REGRESSION TEST — nothing in the tree would fail if this regressed."
"""
        )
        self.assertEqual(0, good_code, msg=err)
        self.assertIn("NO regression test", out)
        self.assertIn("X-011", out)

    def test_untested_and_test_together_are_rejected(self) -> None:
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-012"
summary = "claims both a test and no test"
severity = "low"
status = "fixed"
untested = true
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "the guard holds"
note = "contradictory"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("mutually exclusive", err)

    def test_a_stale_file_path_is_reported(self) -> None:
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-013"
summary = "records a file that has since been deleted"
severity = "low"
status = "fixed"
file = ["src/gone.zig"]
fixed_in = "abc1234"
test = "the guard holds"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("does not exist", err)

    def test_a_dangling_reopens_link_is_reported(self) -> None:
        code, _, err = self.run_main(
            GOOD_ENTRY
            + """
[[finding]]
id = "X-014"
summary = "points at a finding that is not in the ledger"
severity = "low"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "the other guard holds"
reopens = "X-999"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("unknown finding", err)

    def test_a_misspelled_field_is_rejected(self) -> None:
        """A typo'd field name silently drops the constraint it encodes."""
        code, _, err = self.run_main(
            """
[[finding]]
id = "X-015"
summary = "spells the test field wrong"
severity = "low"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "the guard holds"
tests = "the guard holds"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("unknown field", err)

    def test_a_wrong_root_fails_loudly_instead_of_passing_everything(self) -> None:
        """With no src/ tests found, every `test` claim would fail for the wrong reason."""
        empty = self.root / "empty"
        empty.mkdir()
        ledger = self.write_ledger(GOOD_ENTRY)
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = check_audit_ledger.main(["--root", str(empty), "--ledger", str(ledger)])
        self.assertEqual(1, code)
        self.assertIn("found no zig tests", err.getvalue())

    def test_a_missing_or_malformed_ledger_is_reported(self) -> None:
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = check_audit_ledger.main(
                ["--root", str(self.root), "--ledger", str(self.root / "nope.toml")]
            )
        self.assertEqual(1, code)
        self.assertIn("not found", err.getvalue())

        code, _, err_text = self.run_main("[[finding]\nid = broken")
        self.assertEqual(1, code)
        self.assertIn("not valid TOML", err_text)


class RealLedgerTests(unittest.TestCase):
    def test_this_repositorys_ledger_is_green(self) -> None:
        """The shipped ledger must pass its own gate."""
        root = Path(check_audit_ledger.__file__).resolve().parent.parent
        problems, entries = check_audit_ledger.check(root / "AUDIT-LEDGER.toml", root)
        self.assertEqual([], [str(p) for p in problems])
        self.assertGreater(len(entries), 0)


if __name__ == "__main__":
    unittest.main()
