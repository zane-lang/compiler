#!/usr/bin/env python3
"""Tests of tools/nesting/lizard_check.py, the nesting limit for C and Python.

The fixtures under fixtures/lizard/ hold one function per rule of the count.
Their annotations are held to golden/lizard.expected, and the depths that are
not reported -- those under the limit -- are checked here directly, since a
count that charged them would show only as a warning that is not expected.
"""

import contextlib
import io
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tools.nesting import lizard_check

FIXTURES = Path("tests/nesting/fixtures/lizard")
EXPECTED = Path("tests/nesting/golden/lizard.expected")


def depths(path: Path) -> dict[str, int]:
    analyzer = lizard_check.lizard.FileAnalyzer(lizard_check.lizard.get_extensions(["NS"]))
    functions = analyzer.analyze_source_code(path.name, path.read_text(encoding="utf-8")).function_list
    return {f.name: f.max_nested_structures for f in functions}


class LizardCheckTests(unittest.TestCase):
    def test_annotations_match_golden(self) -> None:
        paths = sorted(path.as_posix() for path in FIXTURES.iterdir() if path.is_file())
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = lizard_check.main(paths)
        self.assertEqual(out.getvalue(), EXPECTED.read_text())
        self.assertEqual(status, 1)

    def test_skipped_files_report_nothing(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = lizard_check.main([(FIXTURES / name).as_posix() for name in ("generated.py", "shell")])
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(status, 0)

    def test_binary_file_is_ignored(self) -> None:
        with TemporaryDirectory() as directory:
            binary = Path(directory) / "blob"
            binary.write_bytes(b"\x89PNG\r\n\x1a\n\xff\xfe\x00")
            self.assertEqual(lizard_check.check(binary.as_posix()), [])

    def test_python_elif_chain_is_one_level(self) -> None:
        self.assertEqual(depths(FIXTURES / "depth.py")["elif_chain"], 4)

    def test_inner_function_is_measured_on_its_own(self) -> None:
        found = depths(FIXTURES / "depth.py")
        self.assertEqual(found["named_step"], 2)
        self.assertEqual(found["named_step.step"], 3)

    def test_c_switch_is_one_level(self) -> None:
        self.assertEqual(depths(FIXTURES / "depth.c")["switched"], 1)

    def test_c_else_if_counts_each_link(self) -> None:
        # A known difference from the OCaml count; see lizard_check.py.
        self.assertEqual(depths(FIXTURES / "depth.c")["chain"], 5)


if __name__ == "__main__":
    unittest.main()
