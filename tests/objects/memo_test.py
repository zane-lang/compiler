"""Calls remembered while the program runs, on unless `--no-memoize`
(docs/design/memoization.md). Each fixture in fixtures/memo/ is built plain,
optimized and tiered, with and without `--no-memoize`, and prints the same in
all six builds. Which functions get a table is read from the symbols of each table's
state: one for a recursion, whether its arguments are scalars, an array or a
variant, it reads a package constant, or it calls itself once, and one for a
heavy function called in a loop; none for a light function called in a loop,
a heavy one called outside any loop, or a function that takes a String,
or prints. In a program that spawns, and in a library, threads share each
table, and each keeps its own state. Every build gives the same functions a table, and every table starts
on a cache line."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
FIXTURES = Path(__file__).resolve().parent / "fixtures/memo"
LIBRARY = Path(__file__).resolve().parent / "fixtures/memolibrary"
USER = Path(__file__).resolve().parent / "fixtures/memolibraryuser"
STAMP = "v1.0%0123456789abcdef%"
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


def memo_variables(ir):
    """Whether each of a module's memo variables, its one remembered
    function's state and table and the count of work, is thread-local."""
    found = {}
    for line in ir.splitlines():
        name = line.split(" ", 1)[0]
        for kind, suffix in [("state", '.memo.state"'), ("table", '.memo.table"'), ("calls", "@zane.memo.calls")]:
            if line.startswith("@") and name.endswith(suffix):
                found[kind] = "thread_local" in line
    return found


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

    def tables(self, name, build, memoize=True):
        """The functions given a table: each one's state symbol, less its
        suffix."""
        symbols = subprocess.run(["nm", self.build(name, build, memoize)], capture_output=True, text=True,
                                 check=True).stdout
        return sorted(line.split(" ", 2)[2][: -len(".memo.state")] for line in symbols.splitlines()
                      if line.endswith(".memo.state"))

    def test_tables_start_on_a_cache_line(self):
        # So where a table lands in the binary does not decide which of its
        # entries straddle two cache lines.
        found = 0
        for name in sorted(p.name for p in FIXTURES.iterdir()):
            for build in BUILDS:
                symbols = subprocess.run(["nm", self.build(name, build, True)], capture_output=True,
                                         text=True, check=True).stdout
                for line in symbols.splitlines():
                    if line.endswith(".memo.table"):
                        found += 1
                        self.assertEqual(int(line.split(" ", 1)[0], 16) % 64, 0, (name, build, line))
        self.assertTrue(found)

    def test_a_table_holds_at_most_256_kib(self):
        # Its entries are as many as fit, a power of two: ttt's, of six
        # argument words, a result and a meta word, are 64 bytes, so it
        # holds 4096 of them.
        sizes = {}
        for name in sorted(p.name for p in FIXTURES.iterdir()):
            symbols = subprocess.run(["nm", "-S", self.build(name, "optimized", True)], capture_output=True,
                                     text=True, check=True).stdout
            for line in symbols.splitlines():
                if line.endswith(".memo.table"):
                    sizes[name] = int(line.split(" ", 2)[1], 16)
                    self.assertLessEqual(sizes[name], 262144, (name, line))
        self.assertEqual(sizes["ttt"], 262144)

    def test_every_build_prints_the_same(self):
        for name in sorted(p.name for p in FIXTURES.iterdir()):
            args = (FIXTURES / name / "arguments").read_text().split()
            expected = run_program(self.build(name, "plain", False), *args)
            for build in BUILDS:
                for memoize in (False, True):
                    with self.subTest(name=name, build=build, memoize=memoize):
                        self.assertEqual(run_program(self.build(name, build, memoize), *args), expected)

    def test_no_memoize_gives_no_tables(self):
        for name in sorted(p.name for p in FIXTURES.iterdir()):
            for build in BUILDS:
                with self.subTest(name=name, build=build):
                    self.assertEqual(self.tables(name, build, memoize=False), [])

    def test_a_repeating_recursion_gets_a_table(self):
        for name, function in [
            ("fib", "fib$fib(%primitives$I64)"),
            ("zeros", "zeros$fib(%primitives$I64)"),
            ("constant", "constant$fib(%primitives$I64)"),
            ("ttt", "ttt$minimax(%primitives$Array<%primitives$I32, 9>, %primitives$I32)"),
            ("moves", "moves$ways(moves$Move, %primitives$I64)"),
            ("spawning", "spawning$fib(%primitives$I64)"),
        ]:
            for build in BUILDS:
                with self.subTest(name=name, build=build):
                    self.assertEqual(self.tables(name, build), [function])

    def test_what_is_left_alone_gets_none(self):
        for name in ["rejected"]:
            for build in BUILDS:
                with self.subTest(name=name, build=build):
                    self.assertEqual(self.tables(name, build), [])

    def test_a_program_that_spawns_shares_its_tables(self):
        # Its spawned calls run `fib` on threads of the pool at once. They
        # share one table, whose entries' versions guard them, and each thread
        # keeps its own state and count of work.
        for name, spawns in [("spawning", True), ("fib", False)]:
            for build in ["plain", "optimized"]:
                with self.subTest(name=name, build=build):
                    result = subprocess.run([ZANEC, "--ll", *BUILDS[build], "--package", FIXTURES / name],
                                            capture_output=True, text=True, timeout=300)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(memo_variables(result.stdout), {
                        "state": spawns, "table": False, "calls": spawns}, name)
                    self.assertEqual("fence acquire" in result.stdout, spawns)

    def test_a_library_shares_its_tables(self):
        # A program that links the library may call `fib` from its threads.
        # A library is built plain or optimized; only a program is tiered.
        for build in ["plain", "optimized"]:
            with self.subTest(build=build):
                result = subprocess.run([ZANEC, "--no-root", "--ll", *BUILDS[build],
                                         "--package", LIBRARY], capture_output=True, text=True, timeout=300)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('memolibrary$fib(%primitives$I64).memo.state"', result.stdout)
                self.assertEqual(memo_variables(result.stdout), {"state": True, "table": False, "calls": True})

    def test_a_library_remembers_for_a_program_that_spawns(self):
        # The library's object, linked into a program that calls its `fib`
        # from two spawned calls and `main` at once, prints what it does
        # without tables.
        library = [f"--package", f"{STAMP}memolibrary={LIBRARY}"]
        outputs = {}
        for build in ["plain", "optimized"]:
            for memoize in (False, True):
                flags = [*BUILDS[build], *([] if memoize else ["--no-memoize"])]
                obj = self.out / f"memolibrary.{build}.{memoize}.o"
                exe = self.out / f"memolibraryuser.{build}.{memoize}"
                for command in ([ZANEC, "--no-root", "--object", obj, *flags, *library],
                                [ZANEC, "--build", exe, *flags, "--link", obj, "--package", USER, *library]):
                    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
                    self.assertEqual(result.returncode, 0, result.stderr)
                outputs[(build, memoize)] = run_program(exe, 25)
        self.assertEqual(set(outputs.values()), {"150050\n"}, outputs)

    def test_every_build_gives_the_same_tables(self):
        # A tiered build's two tiers must emit one module, so no build's
        # choice depends on what its optimizer would make of the program.
        for name in ["shallow", "shallowin"]:
            for build in BUILDS:
                with self.subTest(name=name, build=build):
                    self.assertEqual(self.tables(name, build), [f"{name}$walk(%primitives$I64, %primitives$I64)"])

    def test_a_recursion_that_calls_itself_once_gets_a_table(self):
        for build in BUILDS:
            with self.subTest(build=build):
                self.assertEqual(self.tables("once", build), ["once$fact(%primitives$I64)"])

    def test_a_heavy_call_in_a_loop_gets_a_table(self):
        # `light` is called in the same loop but does less than a lookup, as
        # does each case of `spread`, of which a call runs one; `alone` is as
        # heavy as `heavy` but called once outside any loop, and else only in
        # a loop that runs no times.
        for build in BUILDS:
            with self.subTest(build=build):
                self.assertEqual(self.tables("looped", build), ["looped$heavy(%primitives$I64)"])


if __name__ == "__main__":
    unittest.main()
