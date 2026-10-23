"""Calls remembered while the program runs, on unless `--no-memoize`
(docs/design/memoization.md). Each fixture in fixtures/memo/ is built plain,
optimized and tiered, with and without `--no-memoize`, and prints the same in
all six builds. Which functions get a table is read from the symbols of each table's
state: one for a recursion whose arguments repeat, whether they are scalars,
an array or a variant, or it reads a package constant, and none for a
recursion that calls itself once or twice with equal arguments, takes a
String, prints, or runs in a program that spawns or in a library. Every
build gives the same functions a table."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
FIXTURES = Path(__file__).resolve().parent / "fixtures/memo"
LIBRARY = Path(__file__).resolve().parent / "fixtures/memolibrary"
BUILDS = {"plain": [], "optimized": ["--optimize"], "tiered": ["--tiered"]}


def run_program(exe, *args):
    """What a program wrote, run with its drains checked and unchecked
    (`ZANE_CHECK` 1 and 0), as every program in this directory is run. A
    tiered build's tier 1, beside it, is loaded before `main`."""
    outputs = {}
    tier1 = Path(f"{exe}.tier1")
    tiers = {"ZANE_TIER_UP": str(tier1), "ZANE_TIER_WAIT": "1"} if tier1.exists() else {}
    for check in ("1", "0"):
        command = [str(exe), *map(str, args)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60,
                                env={**os.environ, "ZANE_CHECK": check, **tiers})
        if result.returncode:
            raise AssertionError(f"ZANE_CHECK={check} {command}\n{result.stdout}{result.stderr}")
        outputs[check] = result.stdout
    if outputs["1"] != outputs["0"]:
        raise AssertionError(f"{exe}: checked and unchecked runs differ")
    return outputs["1"]


class MemoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.temp.name)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def build(self, name, build, memoize):
        exe = self.out / f"{name}.{build}.{'memo' if memoize else 'base'}"
        if not exe.exists():
            flags = [*BUILDS[build], *([] if memoize else ["--no-memoize"])]
            result = subprocess.run([ZANEC, "--build", exe, *flags, "--package", FIXTURES / name],
                                    capture_output=True, text=True, timeout=300)
            if result.returncode:
                raise AssertionError(f"{name} {build}\n{result.stdout}{result.stderr}")
            if build == "tiered":
                result = subprocess.run([ZANEC, "--tier-up", f"{exe}.tier1", *flags[1:], "--package", FIXTURES / name],
                                        capture_output=True, text=True, timeout=300)
                if result.returncode:
                    raise AssertionError(f"{name} tier 1\n{result.stdout}{result.stderr}")
        return exe

    def tables(self, name, build):
        """The functions given a table: each one's state symbol, less its
        suffix."""
        symbols = subprocess.run(["nm", self.build(name, build, True)], capture_output=True, text=True,
                                 check=True).stdout
        return sorted(line.split(" ", 2)[2][: -len(".memo.state")] for line in symbols.splitlines()
                      if line.endswith(".memo.state"))

    def test_every_build_prints_the_same(self):
        for name in sorted(p.name for p in FIXTURES.iterdir()):
            args = (FIXTURES / name / "arguments").read_text().split()
            expected = run_program(self.build(name, "plain", False), *args)
            for build in BUILDS:
                for memoize in (False, True):
                    with self.subTest(name=name, build=build, memoize=memoize):
                        self.assertEqual(run_program(self.build(name, build, memoize), *args), expected)

    def test_a_repeating_recursion_gets_a_table(self):
        for name, function in [
            ("fib", "fib$fib(%primitives$I64)"),
            ("constant", "constant$fib(%primitives$I64)"),
            ("ttt", "ttt$minimax(%primitives$Array<%primitives$I32, 9>, %primitives$I32)"),
            ("moves", "moves$ways(moves$Move, %primitives$I64)"),
        ]:
            for build in BUILDS:
                with self.subTest(name=name, build=build):
                    self.assertEqual(self.tables(name, build), [function])

    def test_what_is_left_alone_gets_none(self):
        for name in ["rejected", "spawning"]:
            for build in BUILDS:
                with self.subTest(name=name, build=build):
                    self.assertEqual(self.tables(name, build), [])

    def test_a_library_gets_none(self):
        # A program that links the library may call `fib` from its threads.
        # A library is built plain or optimized; only a program is tiered.
        for build in ["plain", "optimized"]:
            with self.subTest(build=build):
                result = subprocess.run([ZANEC, "--kind", "library", "--ll", *BUILDS[build],
                                         "--package", LIBRARY], capture_output=True, text=True, timeout=300)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("memolibrary$fib", result.stdout)
                self.assertNotIn(".memo.state", result.stdout)

    def test_every_build_gives_the_same_tables(self):
        # A tiered build's two tiers must emit one module, so no build's
        # choice depends on what its optimizer would make of the program.
        for name in ["shallow", "shallowin"]:
            for build in BUILDS:
                with self.subTest(name=name, build=build):
                    self.assertEqual(self.tables(name, build), [f"{name}$walk(%primitives$I64, %primitives$I64)"])

    def test_equal_calls_count_once(self):
        # `twice` makes the same call twice, which an optimizer makes once.
        for build in BUILDS:
            with self.subTest(build=build):
                self.assertEqual(self.tables("merged", build), [])


if __name__ == "__main__":
    unittest.main()
