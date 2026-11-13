"""The runtime's fixtures run under Valgrind as they run natively.

Valgrind hands a fault handler only the registers its translated code last
wrote back, so a store the runtime's handler makes good may run again at an
older address. `faults.c` is a store written in the shape that loses its
address; the runtime makes a context's whole range usable from the start
under Valgrind, so the store does not fault there (runtime/region.c,
zane_reserve). The perf suite and the instruction counts the perf work
quotes come from runs under Valgrind, so a program that runs differently
there is measured wrong. `dune runtest tests/runtime` builds the fixture
and runs it natively first; `just test-compiler` runs both. Skipped where
Valgrind is not installed.
"""

from pathlib import Path
import shutil
import subprocess
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILT = ROOT / "_build" / "default" / "tests" / "runtime"
VALGRIND = shutil.which("valgrind")


@unittest.skipUnless(VALGRIND, "valgrind is not installed")
class UnderValgrind(unittest.TestCase):
    def run_fixture(self, name):
        exe = BUILT / f"{name}.exe"
        if not exe.exists():
            self.fail(f"{exe} is missing: run `dune runtest tests/runtime` first")
        result = subprocess.run([VALGRIND, "-q", "--tool=none", str(exe)],
                                capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, (HERE / "golden" / f"{name}.out").read_text(), result.stderr)

    def test_a_store_that_faults_lands_where_it_was_meant(self):
        self.run_fixture("faults")


if __name__ == "__main__":
    unittest.main()
