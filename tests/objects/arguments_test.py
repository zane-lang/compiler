"""The marker `--object OUT` writes beside the object when a `comptime` call
read the runtime's `arguments` (docs/design/comptime.md,
docs/design/separate-compilation.md): an empty `STEM.arguments` when some
marked call read them, and none otherwise, with a marker an earlier build
left at that path removed. A package manager keys its cache of the object on
the build's arguments only when the marker is there."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())

LIBRARY = """\
package counts;

alias Int = @primitives$I64;

Int count(runtime &@runtime$Runtime) => runtime:arguments():size();
"""

# The root's `main` returns a value a marked call gave. `{call}` is that call.
ROOT = """\
package app;

import counts;

alias Int = @primitives$I64;
alias Unit = @primitives$Unit;

Int seven() => Int(7);

Int read(runtime &@runtime$Runtime) => runtime:arguments():size();

Unit main() {{
	n Int = {call};
	return Unit();
}}
"""

# A marked call that reads the arguments in the root, one that reads them
# through a library's verb, and one that reads nothing.
READS_IN_ROOT = "comptime read(@program$runtime)"
READS_IN_LIBRARY = "comptime counts$count(@program$runtime)"
READS_NOTHING = "comptime seven()"


class ArgumentsMarkerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "counts").mkdir()
        (self.root / "counts/counts.zn").write_text(LIBRARY, encoding="utf-8")
        (self.root / "app").mkdir()
        self.object = self.root / "app.o"
        self.marker = self.root / "app.arguments"

    def build(self, call, *arguments):
        """Builds the root's object with `main` running `call`, given each of
        `arguments` with `--build-argument`."""
        (self.root / "app/app.zn").write_text(ROOT.format(call=call), encoding="utf-8")
        flags = [flag for argument in arguments for flag in ("--build-argument", argument)]
        result = subprocess.run(
            [ZANEC, "--object", self.object, "--package", self.root / "app", "--package", self.root / "counts",
             *flags],
            capture_output=True, text=True, encoding="utf-8", timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.object.is_file())

    def test_a_read_in_the_root_writes_an_empty_marker(self):
        self.build(READS_IN_ROOT, "alpha", "beta")
        self.assertTrue(self.marker.is_file())
        self.assertEqual(self.marker.read_bytes(), b"")

    def test_a_read_through_a_library_verb_writes_the_marker(self):
        self.build(READS_IN_LIBRARY, "alpha")
        self.assertTrue(self.marker.is_file())

    def test_a_read_with_no_arguments_still_writes_the_marker(self):
        # The marker records the read, not the values.
        self.build(READS_IN_ROOT)
        self.assertTrue(self.marker.is_file())

    def test_no_read_writes_no_marker(self):
        self.build(READS_NOTHING, "alpha")
        self.assertFalse(self.marker.exists())

    def refuse(self, name):
        """Runs `--object` on the object path `name` and checks that zanec refuses it."""
        (self.root / "app/app.zn").write_text(ROOT.format(call=READS_IN_ROOT), encoding="utf-8")
        output = self.root / name
        result = subprocess.run(
            [ZANEC, "--object", output, "--package", self.root / "app", "--package", self.root / "counts",
             "--build-argument", "alpha"],
            capture_output=True, text=True, encoding="utf-8", timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("`.arguments`", result.stderr)
        self.assertFalse(output.exists())

    def test_an_object_named_like_its_marker_is_refused(self):
        # `app.arguments` would be its own marker, which the build removes.
        self.refuse("app.arguments")

    def test_an_object_named_like_its_marker_in_another_case_is_refused(self):
        # On a file system that ignores case, `app.ARGUMENTS` is the marker.
        self.refuse("app.ARGUMENTS")

    def test_a_build_without_the_read_removes_an_earlier_marker(self):
        self.build(READS_IN_ROOT, "alpha")
        self.assertTrue(self.marker.is_file())
        self.build(READS_NOTHING, "alpha")
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
