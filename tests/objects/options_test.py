"""What `zanec` accepts for the options that name packages and stamps them
(docs/design/separate-compilation.md C6, C10): a package name is held to the
lexer's identifier rule, Unicode letters included, and a stamp to the form
`--rewrite` checks."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
GEOMETRY = Path(__file__).resolve().parent / "fixtures/geometry"

BOOKS = """\
package {name};

alias Int = @primitives$I64;

Int pages() => Int(3);
"""

APP = """\
package app;

import bücher;

alias Int = @primitives$I64;

Int count() => bücher$pages();
"""

# A name that is no package name: an uppercase first letter, ASCII and not,
# a leading digit, nothing at all, and a keyword.
NOT_NAMES = ["Buecher", "Übersicht", "1bücher", "", "type"]


def zanec(*args):
    return subprocess.run([ZANEC, *map(str, args)], capture_output=True, text=True, timeout=60)


class OptionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ["bücher", "_bücher"]:
            (self.root / name).mkdir()
            (self.root / name / "books.zn").write_text(BOOKS.format(name=name), encoding="utf-8")
        (self.root / "app").mkdir()
        (self.root / "app/app.zn").write_text(APP, encoding="utf-8")

    def assert_status(self, result, status):
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)

    def test_a_unicode_package_name_binds_a_directory(self):
        self.assert_status(zanec("--check", "--package", f"bücher={self.root / 'bücher'}"), 0)

    def test_a_private_unicode_package_name_binds_a_directory(self):
        self.assert_status(zanec("--check", "--package", f"_bücher={self.root / '_bücher'}"), 0)

    def test_a_unicode_import_key_names_a_unicode_package(self):
        result = zanec("--check", "--package", f"app={self.root / 'app'}",
                       "--package", f"bücher={self.root / 'bücher'}",
                       "--import", "app:bücher=bücher")
        self.assert_status(result, 0)

    def test_what_is_no_name_is_read_as_a_directory(self):
        # `NAME=DIR` whose NAME is no package name is a path holding a `=`
        # (bin/zanec/zanec.ml, `package_request`), which does not exist.
        for name in NOT_NAMES:
            with self.subTest(name=name):
                argument = f"{name}={self.root / 'bücher'}"
                result = zanec("--check", "--package", argument)
                self.assert_status(result, 1)
                self.assertIn(argument, result.stderr)
                self.assertIn("no such directory", result.stderr)

    def test_an_import_key_that_is_no_name_is_a_usage_error(self):
        for name in NOT_NAMES:
            with self.subTest(name=name):
                result = zanec("--check", "--package", f"app={self.root / 'app'}",
                               "--package", f"bücher={self.root / 'bücher'}",
                               "--import", f"app:{name}=bücher")
                self.assert_status(result, 2)
                self.assertIn("usage: zanec", result.stderr)

    def test_a_malformed_stamp_is_a_usage_error(self):
        output = self.root / "geometry.o"
        result = zanec("--no-root", "--object", output,
                       "--stamp", "geometry=garbage", "--package", GEOMETRY)
        self.assert_status(result, 2)
        self.assertIn("usage: zanec", result.stderr)
        self.assertFalse(output.exists())

    def test_a_stamp_is_still_accepted(self):
        output = self.root / "geometry.o"
        result = zanec("--no-root", "--object", output,
                       "--stamp", "geometry=v1.0.1%3f9a1c02b7e4d6a8%", "--package", GEOMETRY)
        self.assert_status(result, 0)
        self.assertTrue(output.exists())


if __name__ == "__main__":
    unittest.main()
