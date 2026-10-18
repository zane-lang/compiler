"""What `zanec` accepts for the options that name packages and stamp them
(docs/design/separate-compilation.md C6, C10): a stamp is held to the form
`--rewrite` checks."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
GEOMETRY = Path(__file__).resolve().parent / "fixtures/geometry"


def zanec(*args):
    return subprocess.run([ZANEC, *map(str, args)], capture_output=True, text=True, timeout=60)


class OptionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def assert_status(self, result, status):
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)

    def test_a_malformed_stamp_is_a_usage_error(self):
        output = self.root / "geometry.o"
        result = zanec("--kind", "library", "--object", output,
                       "--stamp", "geometry=garbage", "--package", GEOMETRY)
        self.assert_status(result, 2)
        self.assertIn("usage: zanec", result.stderr)
        self.assertFalse(output.exists())

    def test_a_stamp_is_still_accepted(self):
        output = self.root / "geometry.o"
        result = zanec("--kind", "library", "--object", output,
                       "--stamp", "geometry=v1.0.1%3f9a1c02b7e4d6a8%", "--package", GEOMETRY)
        self.assert_status(result, 0)
        self.assertTrue(output.exists())


if __name__ == "__main__":
    unittest.main()
