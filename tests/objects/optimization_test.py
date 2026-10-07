"""Cross-package folding, inlining and separate-object ABI regressions."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
FIXTURES = Path(__file__).resolve().parent / "fixtures"
STAMP = "v1.0%0123456789abcdef%"


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise AssertionError(f"{args}\n{result.stdout}{result.stderr}")
    return result.stdout


class OptimizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.temp.name)
        cls.math = FIXTURES / "optimization/math"
        cls.app = FIXTURES / "optimization/app"
        # Deliberately link an unoptimized dependency into optimized callers.
        cls.obj = cls.out / "math.o"
        run(ZANEC, "--kind", "library", "--object", cls.obj,
            "--package", f"{STAMP}math={cls.math}")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def flags(self):
        return ["--package", f"app={self.app}", "--package", f"{STAMP}math={self.math}"]

    def test_folding_and_inlining(self):
        plain = run(ZANEC, "--cgt", *self.flags())
        folded = run(ZANEC, "--cgt", "--optimize", *self.flags())
        self.assertIn("linkage: imported", plain)
        self.assertIn("linkage: available", folded)
        # Only main is inspected: dependency bodies retain their runtime loop.
        main = folded.split("symbol: app$main()", 1)[1].split("symbol:", 1)[0]
        self.assertNotIn("repeat", main)
        self.assertIn("100", main)
        before = run(ZANEC, "--ll", *self.flags())
        after = run(ZANEC, "--ll", "--optimize", *self.flags())
        self.assertRegex(before, r'call .*math\$add\(')
        self.assertNotRegex(after, r'call .*math\$(?:add|_add|squared)\(')
        # Recursive calls that LLVM leaves behind still target the library.
        self.assertRegex(after, r'(?:call|declare).*math\$fib\(')
        obj = self.out / "caller.o"
        run(ZANEC, "--object", obj, "--optimize", *self.flags())
        definitions = run("llvm-nm", "--defined-only", obj)
        self.assertNotRegex(definitions, r' [TW] .*math\$(?:add|_add|down|fib|bump|divide)\(')
        self.assertRegex(run("llvm-nm", obj), r' U .*math\$fib\(')

    def test_cross_target_objects(self):
        for target in ["x86_64-pc-windows-msvc", "aarch64-apple-macosx11.0.0"]:
            obj = self.out / f"{target}.o"
            run(ZANEC, "--object", obj, "--optimize", "--target", target, *self.flags())
            definitions = run("llvm-nm", "--defined-only", obj)
            self.assertNotRegex(definitions, r' [TW] _?.*math\$(?:add|_add|fib|bump)\(')

    def test_runtime_results(self):
        expected = "library\n42\n100\n9\n10\n49\n8\n99\n4\n36\n16\n21\n"
        for optimize in [False, True]:
            exe = self.out / f"app-{optimize}"
            run(ZANEC, "--build", exe, "--link", self.obj,
                *(["--optimize"] if optimize else []), *self.flags())
            self.assertEqual(run(exe, "7"), expected)

    def test_existing_library_features(self):
        obj = self.out / "geometry.o"
        run(ZANEC, "--kind", "library", "--object", obj,
            "--stamp", f"geometry={STAMP}", "--package", FIXTURES / "geometry")
        exe = self.out / "survey"
        run(ZANEC, "--build", exe, "--optimize", "--link", obj,
            "--stamp", f"geometry={STAMP}", "--package", FIXTURES / "survey",
            "--package", FIXTURES / "geometry")
        self.assertEqual(run(exe), (FIXTURES.parent / "golden/survey.out").read_text())

    def test_versions_and_transitive_imports(self):
        versions = FIXTURES / "versions"
        geo1 = "v1.0%0123456789abcdef%geometry"
        geo2 = "v2.0%0123456789abcdef%geometry"
        atlas = "v1.0%fedcba9876543210%atlas"
        objects = []
        for name, fixture, deps in [
            (geo1, "geometry1", []), (geo2, "geometry2", []),
            (atlas, "atlas", ["--package", f"{geo1}={versions / 'geometry1'}"]),
        ]:
            obj = self.out / f"{fixture}.o"
            run(ZANEC, "--kind", "library", "--object", obj, "--optimize",
                "--package", f"{name}={versions / fixture}", *deps)
            objects += ["--link", obj]
        exe = self.out / "versions"
        run(ZANEC, "--build", exe, "--optimize", *objects,
            "--package", f"app={versions / 'app'}",
            "--package", f"{geo2}={versions / 'geometry2'}",
            "--package", f"{atlas}={versions / 'atlas'}",
            "--package", f"{geo1}={versions / 'geometry1'}",
            "--import", f"app:geo={geo2}", "--import", f"app:atlas={atlas}",
            "--import", f"{atlas}:geometry={geo1}")
        self.assertEqual(run(exe), (FIXTURES.parent / "golden/versions.out").read_text())


if __name__ == "__main__":
    unittest.main()
