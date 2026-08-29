#!/usr/bin/env python3
"""Regression tests for scripts/check_js_asset_gates.py.

The checker's whole value is that it FAILS when a browser asset has no gate. A
checker never shown to fail is not evidence, so the load-bearing tests here are
the red ones: an ungated asset, a stale vendor exemption, and a gate pointing
at a renamed file. The last test runs it against this repository for real.
"""

from pathlib import Path
import contextlib
import io
import tempfile
import unittest

import check_js_asset_gates


def gate(name: str, path: str) -> str:
    return f"""
[[external]]
name = "{name}"
command = ["node", "--check", "{path}"]
inputs = ["{path}"]
"""


class JsAssetGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets = self.root / check_js_asset_gates.ASSET_DIR
        self.assets.mkdir(parents=True)
        self.write_asset("editor.js")

        # The real VENDORED table names paths in the real repo, which do not
        # exist inside these fixture trees. Swap in a fixture table and restore
        # it afterwards so each test states its own exemptions.
        self.real_vendored = check_js_asset_gates.VENDORED
        check_js_asset_gates.VENDORED = {}
        self.addCleanup(self.restore_vendored)

    def restore_vendored(self) -> None:
        check_js_asset_gates.VENDORED = self.real_vendored

    def write_asset(self, name: str) -> None:
        (self.assets / name).write_text("// asset\n", encoding="utf-8")

    def run_main(self, config_body: str, syntax: bool = False) -> tuple[int, str, str]:
        config = self.root / "guardian.toml"
        config.write_text(config_body, encoding="utf-8")
        argv = ["--root", str(self.root), "--config", str(config)]
        if syntax:
            argv.append("--syntax")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check_js_asset_gates.main(argv)
        return code, out.getvalue(), err.getvalue()

    # ── the ones that matter ─────────────────────────────────────────────

    def test_fails_on_a_first_party_asset_no_gate_names(self) -> None:
        """The point of the gate: a new asset nobody wired up is caught."""
        self.write_asset("brand_new.js")
        code, _, err = self.run_main(gate("editor-js-syntax", "src/serve/assets/editor.js"))
        self.assertEqual(code, 1)
        self.assertIn("brand_new.js", err)
        self.assertIn("no Guardian gate", err)
        # The one that IS gated must not be reported.
        self.assertNotIn("assets/editor.js:", err)

    def test_passes_once_the_asset_is_gated(self) -> None:
        """The same tree goes green the moment the missing external is added."""
        self.write_asset("brand_new.js")
        code, out, err = self.run_main(
            gate("editor-js-syntax", "src/serve/assets/editor.js")
            + gate("brand-new-js-syntax", "src/serve/assets/brand_new.js")
        )
        self.assertEqual(code, 0, err)
        self.assertIn("2 first-party asset(s) all gated", out)

    def test_inputs_alone_do_not_count_as_a_gate(self) -> None:
        """`inputs` decides when a gate re-runs, not whether anything parses it.

        This is the subtle way the rule could be defeated: list the asset as an
        input of some unrelated external and it looks wired up, while nothing
        ever reads it.
        """
        self.write_asset("brand_new.js")
        code, _, err = self.run_main(
            gate("editor-js-syntax", "src/serve/assets/editor.js")
            + """
[[external]]
name = "something-else"
command = ["true"]
inputs = ["src/serve/assets/brand_new.js"]
"""
        )
        self.assertEqual(code, 1)
        self.assertIn("brand_new.js", err)

    def test_fails_on_a_gate_naming_a_file_that_no_longer_exists(self) -> None:
        """A renamed asset leaves its gate passing over nothing."""
        code, _, err = self.run_main(
            gate("editor-js-syntax", "src/serve/assets/editor.js")
            + gate("renamed-js-syntax", "src/serve/assets/gone.js")
        )
        self.assertEqual(code, 1)
        self.assertIn("gone.js", err)
        self.assertIn("renamed or deleted", err)

    def test_fails_on_a_vendor_exemption_for_a_file_that_does_not_exist(self) -> None:
        """A stale allowlist is the shape an exemption rots into."""
        check_js_asset_gates.VENDORED = {
            "src/serve/assets/removed_lib.js": "a library we no longer ship",
        }
        code, _, err = self.run_main(gate("editor-js-syntax", "src/serve/assets/editor.js"))
        self.assertEqual(code, 1)
        self.assertIn("removed_lib.js", err)
        self.assertIn("drop the exemption", err)

    # ── the rest of the surface ──────────────────────────────────────────

    def test_a_vendored_asset_needs_no_gate(self) -> None:
        self.write_asset("upstream.min.js")
        check_js_asset_gates.VENDORED = {
            "src/serve/assets/upstream.min.js": "some upstream bundle, MIT",
        }
        code, out, err = self.run_main(gate("editor-js-syntax", "src/serve/assets/editor.js"))
        self.assertEqual(code, 0, err)
        self.assertIn("1 vendored", out)

    def test_a_vendored_directory_exempts_the_files_under_it(self) -> None:
        (self.assets / "vendor").mkdir()
        (self.assets / "vendor" / "lib.mjs").write_text("// vendored\n", encoding="utf-8")
        check_js_asset_gates.VENDORED = {
            "src/serve/assets/vendor": "a vendored drop, gated elsewhere",
        }
        code, _, err = self.run_main(gate("editor-js-syntax", "src/serve/assets/editor.js"))
        self.assertEqual(code, 0, err)

    def test_a_nested_first_party_asset_is_still_required_to_be_gated(self) -> None:
        """rglob, not glob: a subdirectory is not a hiding place."""
        (self.assets / "panels").mkdir()
        (self.assets / "panels" / "deep.js").write_text("// asset\n", encoding="utf-8")
        code, _, err = self.run_main(gate("editor-js-syntax", "src/serve/assets/editor.js"))
        self.assertEqual(code, 1)
        self.assertIn("panels/deep.js", err)

    def test_mjs_is_an_asset_too(self) -> None:
        self.write_asset("module.mjs")
        code, _, err = self.run_main(gate("editor-js-syntax", "src/serve/assets/editor.js"))
        self.assertEqual(code, 1)
        self.assertIn("module.mjs", err)

    def test_a_multi_file_command_gates_every_file_it_names(self) -> None:
        self.write_asset("second.js")
        code, out, err = self.run_main(
            """
[[external]]
name = "both-js-syntax"
command = ["node", "--check", "src/serve/assets/editor.js", "src/serve/assets/second.js"]
inputs = ["src/serve/assets/editor.js", "src/serve/assets/second.js"]
"""
        )
        self.assertEqual(code, 0, err)
        self.assertIn("2 first-party asset(s) all gated", out)

    def test_reports_every_problem_at_once(self) -> None:
        """One run, the whole list — not one failure per re-run."""
        self.write_asset("one.js")
        self.write_asset("two.js")
        code, _, err = self.run_main(gate("editor-js-syntax", "src/serve/assets/editor.js"))
        self.assertEqual(code, 1)
        self.assertIn("2 problem(s)", err)
        self.assertIn("one.js", err)
        self.assertIn("two.js", err)

    def test_an_empty_asset_directory_fails_loudly(self) -> None:
        """A vacuous pass would be the worst outcome: every rule holds."""
        (self.assets / "editor.js").unlink()
        code, _, err = self.run_main("")
        self.assertEqual(code, 1)
        self.assertIn("wrong repo root", err)

    def test_a_missing_config_is_reported_not_crashed(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check_js_asset_gates.main(
                ["--root", str(self.root), "--config", str(self.root / "nope.toml")]
            )
        self.assertEqual(code, 1)
        self.assertIn("not found", err.getvalue())

    def test_malformed_config_is_reported_not_crashed(self) -> None:
        code, _, err = self.run_main("[[external]\nname = ")
        self.assertEqual(code, 1)
        self.assertIn("not valid TOML", err)

    # ── --syntax: parsing, not just declaring ────────────────────────────

    def test_syntax_mode_fails_on_an_asset_that_does_not_parse(self) -> None:
        """The gate the inert `node --check` externals were supposed to be."""
        (self.assets / "editor.js").write_text("function broken( {\n", encoding="utf-8")
        code, _, err = self.run_main(
            gate("editor-js-syntax", "src/serve/assets/editor.js"), syntax=True
        )
        self.assertEqual(code, 1)
        self.assertIn("editor.js", err)
        self.assertIn("does not parse", err)

    def test_syntax_mode_passes_on_valid_assets(self) -> None:
        code, out, err = self.run_main(
            gate("editor-js-syntax", "src/serve/assets/editor.js"), syntax=True
        )
        self.assertEqual(code, 0, err)
        self.assertIn("all gated and parsed", out)

    def test_syntax_mode_does_not_parse_vendored_code(self) -> None:
        """Upstream's syntax is upstream's problem, and minified bundles are huge."""
        (self.assets / "upstream.min.js").write_text("this is ( not javascript\n", encoding="utf-8")
        check_js_asset_gates.VENDORED = {
            "src/serve/assets/upstream.min.js": "some upstream bundle, MIT",
        }
        code, _, err = self.run_main(
            gate("editor-js-syntax", "src/serve/assets/editor.js"), syntax=True
        )
        self.assertEqual(code, 0, err)

    def test_syntax_mode_is_not_reached_when_the_declaration_rule_fails(self) -> None:
        """An ungated asset is reported as ungated, not drowned in parse output."""
        self.write_asset("brand_new.js")
        code, _, err = self.run_main(
            gate("editor-js-syntax", "src/serve/assets/editor.js"), syntax=True
        )
        self.assertEqual(code, 1)
        self.assertIn("no Guardian gate", err)
        # Exactly the declaration problem — the trailing epilogue also says
        # "does not parse", so count is the honest assertion here.
        self.assertIn("1 problem(s)", err)

    # ── the real tree ────────────────────────────────────────────────────

    def test_this_repository_passes(self) -> None:
        """Every first-party asset in this repo is gated, right now."""
        self.restore_vendored()
        root = Path(check_js_asset_gates.__file__).resolve().parent.parent
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check_js_asset_gates.main(["--root", str(root), "--syntax"])
        self.assertEqual(code, 0, err.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
