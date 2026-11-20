"""A worker pool across objects (docs/design/lowering.md, runtime/workers.c):
a library's object makes a pool whose events own a block, and a program
built apart from it starts the pool's workers, whose steps publish to it.
The two objects each have their own walk table for the event type, so the
runtime tells event types apart by a hash of the type's symbol, which both
objects compute alike."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
HERE = Path(__file__).resolve().parent
LIBRARY = HERE / "fixtures/poollibrary"
USER = HERE / "fixtures/pooluser"
STAMP = "v1.0%0123456789abcdef%"
BUILDS = {"plain": [], "optimized": ["--optimize"]}


def run_program(exe):
    """What a program wrote, run with its drains checked and unchecked
    (`ZANE_CHECK` 1 and 0), as every program in this directory is run."""
    outputs = {}
    for check in ("1", "0"):
        result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60,
                                env={**os.environ, "ZANE_CHECK": check})
        if result.returncode:
            raise AssertionError(f"ZANE_CHECK={check} {exe}\n{result.stdout}{result.stderr}")
        outputs[check] = result.stdout
    if outputs["1"] != outputs["0"]:
        raise AssertionError(f"{exe}: checked and unchecked runs differ")
    return outputs["1"]


class PoolTests(unittest.TestCase):
    def test_a_program_publishes_to_a_library_pool(self):
        # 1 + 4 + 9 from one worker and 1 + 4 + 9 + 16 from the other.
        library = ["--package", f"{STAMP}poollibrary={LIBRARY}"]
        with tempfile.TemporaryDirectory() as out:
            for build, flags in BUILDS.items():
                with self.subTest(build=build):
                    obj = Path(out) / f"poollibrary.{build}.o"
                    exe = Path(out) / f"pooluser.{build}"
                    for command in ([ZANEC, "--no-root", "--object", obj, *flags, *library],
                                    [ZANEC, "--build", exe, *flags, "--link", obj, "--package", USER, *library]):
                        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(run_program(exe), "44\n")


if __name__ == "__main__":
    unittest.main()
