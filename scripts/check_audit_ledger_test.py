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


class LedgerFixture(unittest.TestCase):
    """A throwaway tree with two known zig tests, plus the run helpers.

    Declares no tests of its own so the suites below do not re-run each
    other's cases.
    """

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


class LedgerCheckerTests(LedgerFixture):
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


class HarnessTests(LedgerFixture):
    """`harness` is how a fix no zig test can reach still names a live guard.

    It has to be checked as strictly as `test`, or it becomes the soft option
    that quietly absorbs every entry someone did not want to write a test for.
    """

    def setUp(self) -> None:
        super().setUp()
        (self.root / "scripts").mkdir()
        # A stand-in for the editor probe: a harness file declaring named
        # invariants, the way run.js declares `id: "row-aliasing"`.
        # Mirrors the real probe's shape, including the trap: each invariant's
        # name also appears as a fixture key and a revert target, so a check
        # that merely looked for the quoted string would stay green after the
        # invariant itself was renamed away.
        (self.root / "scripts/probe.js").write_text(
            "const FIXTURES = {\n"
            '  "first-invariant": [],\n'
            '  "second-invariant": [],\n'
            "};\n"
            "const CHECKS = [\n"
            '  { id: "first-invariant", revert: "first-invariant" },\n'
            '  { id: "second-invariant", revert: "second-invariant" },\n'
            "];\n",
            encoding="utf-8",
        )

    def harness_entry(self, harness: str) -> str:
        return f"""
[[finding]]
id = "H-001"
summary = "a fix that lives in JavaScript"
severity = "high"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
harness = "{harness}"
"""

    # ── the ones that matter ─────────────────────────────────────────────

    def test_fails_when_the_named_invariant_is_gone_from_the_harness(self) -> None:
        """The whole reason for the `#anchor` form.

        A probe that still exists but no longer runs the invariant would pass a
        file-existence check while guarding nothing — which is the exact
        failure this ledger was built to catch, one level up.
        """
        code, _, err = self.run_main(self.harness_entry("scripts/probe.js#third-invariant"))
        self.assertEqual(1, code)
        self.assertIn("third-invariant", err)
        self.assertIn("no longer declared as an id", err)

    def test_fails_when_the_harness_file_is_gone(self) -> None:
        code, _, err = self.run_main(self.harness_entry("scripts/deleted_probe.js#first-invariant"))
        self.assertEqual(1, code)
        self.assertIn("deleted_probe.js", err)
        self.assertIn("deleted or renamed", err)

    def test_a_verified_harness_satisfies_a_fixed_finding(self) -> None:
        code, out, err = self.run_main(self.harness_entry("scripts/probe.js#first-invariant"))
        self.assertEqual(0, code, err)
        self.assertIn("1 fixed finding(s) guarded by a harness", out)
        self.assertIn("H-001", out)

    def test_a_failed_harness_does_not_stand_in_for_a_missing_test(self) -> None:
        """Two problems, not one: the broken anchor AND the unguarded finding.

        Reporting only the anchor would leave the entry looking like it still
        had a guard once someone 'fixed' the anchor by deleting it.
        """
        code, _, err = self.run_main(self.harness_entry("scripts/probe.js#gone"))
        self.assertEqual(1, code)
        self.assertIn("no longer declared as an id", err)
        self.assertIn("requires `test`", err)

    # ── the rest of the surface ──────────────────────────────────────────

    def test_a_bare_harness_path_needs_no_anchor(self) -> None:
        code, out, err = self.run_main(self.harness_entry("scripts/probe.js"))
        self.assertEqual(0, code, err)
        self.assertIn("H-001", out)

    def test_a_renamed_invariant_is_caught_even_though_the_name_lingers(self) -> None:
        """The measured near-miss: a bare quoted-string match was not enough.

        Renaming the real probe's `id: "row-aliasing"` left three other quoted
        occurrences of that name in the file, and a substring check stayed
        green. Only an id DECLARATION counts.
        """
        (self.root / "scripts/probe.js").write_text(
            "const FIXTURES = {\n"
            '  "first-invariant": [],\n'
            "};\n"
            "const CHECKS = [\n"
            '  { id: "first-invariant-v2", revert: "first-invariant" },\n'
            "];\n",
            encoding="utf-8",
        )
        code, _, err = self.run_main(self.harness_entry("scripts/probe.js#first-invariant"))
        self.assertEqual(1, code)
        self.assertIn("no longer declared as an id", err)

    def test_a_single_quoted_anchor_counts(self) -> None:
        (self.root / "scripts/probe.js").write_text(
            "const CHECKS = [{ id: 'single-quoted' }];\n", encoding="utf-8"
        )
        code, _, err = self.run_main(self.harness_entry("scripts/probe.js#single-quoted"))
        self.assertEqual(0, code, err)

    def test_a_json_style_id_key_counts(self) -> None:
        (self.root / "scripts/probe.json").write_text(
            '{"checks": [{"id": "json-invariant"}]}\n', encoding="utf-8"
        )
        code, _, err = self.run_main(self.harness_entry("scripts/probe.json#json-invariant"))
        self.assertEqual(0, code, err)

    def test_an_unquoted_substring_is_not_an_anchor(self) -> None:
        """`first` appears inside `first-invariant`; only a whole quoted id counts."""
        code, _, err = self.run_main(self.harness_entry("scripts/probe.js#first"))
        self.assertEqual(1, code)
        self.assertIn("no longer declared as an id", err)

    def test_harness_must_look_like_a_path(self) -> None:
        code, _, err = self.run_main(self.harness_entry("some prose about a probe"))
        self.assertEqual(1, code)
        self.assertIn("must name a path", err)

    def test_a_directory_is_not_a_harness(self) -> None:
        code, _, err = self.run_main(self.harness_entry("scripts/"))
        self.assertEqual(1, code)

    def test_harness_and_untested_are_mutually_exclusive(self) -> None:
        code, _, err = self.run_main(
            """
[[finding]]
id = "H-002"
summary = "cannot be both guarded and unguarded"
severity = "low"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
harness = "scripts/probe.js"
untested = true
note = "a note"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("mutually exclusive", err)

    def test_a_zig_test_and_a_harness_can_coexist(self) -> None:
        """A fix with both is listed as tested, not as harness-only."""
        code, out, err = self.run_main(
            """
[[finding]]
id = "H-003"
summary = "guarded twice over"
severity = "low"
status = "fixed"
file = ["src/thing.zig"]
fixed_in = "abc1234"
test = "the guard holds"
harness = "scripts/probe.js#first-invariant"
"""
        )
        self.assertEqual(0, code, err)
        self.assertNotIn("guarded by a harness", out)

    def test_harness_is_not_a_field_on_an_open_finding(self) -> None:
        code, _, err = self.run_main(
            """
[[finding]]
id = "H-004"
summary = "still open"
severity = "low"
status = "open"
file = ["src/thing.zig"]
harness = "scripts/probe.js"
note = "why"
"""
        )
        self.assertEqual(1, code)
        self.assertIn("unknown field", err)


class RealLedgerTests(unittest.TestCase):
    def test_this_repositorys_ledger_is_green(self) -> None:
        """The shipped ledger must pass its own gate."""
        root = Path(check_audit_ledger.__file__).resolve().parent.parent
        problems, entries = check_audit_ledger.check(root / "AUDIT-LEDGER.toml", root)
        self.assertEqual([], [str(p) for p in problems])
        self.assertGreater(len(entries), 0)

    def test_no_fixed_finding_is_left_unguarded(self) -> None:
        """The standing claim: every fixed finding names a test or a harness.

        This started at eight untested entries. Should one ever be added back,
        it is a deliberate act that has to change this assertion too.
        """
        root = Path(check_audit_ledger.__file__).resolve().parent.parent
        _, entries = check_audit_ledger.check(root / "AUDIT-LEDGER.toml", root)
        unguarded = [
            e.get("id")
            for e in entries
            if isinstance(e, dict) and e.get("status") == "fixed" and e.get("untested")
        ]
        self.assertEqual([], unguarded)


if __name__ == "__main__":
    unittest.main()
