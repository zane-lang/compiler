"""What codegen tells LLVM about a program, and what LLVM makes of it
(docs/design/lowering.md §9, "What LLVM is told")."""

from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
FACTS = Path(__file__).resolve().parent / "fixtures/facts"
STAMP = "v1.0%0123456789abcdef%"
SNAPSHOT = re.compile(r"load atomic|@zane_snapshot\(")


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise AssertionError(f"{args}\n{result.stdout}{result.stderr}")
    return result.stdout


def run_program(exe, *args):
    """What a program wrote, run with its drains checked and unchecked
    (`ZANE_CHECK` 1 and 0), as every program in this directory is run. The
    two runs must agree, and a failure names the mode it came from."""
    outputs = {}
    for check in ("1", "0"):
        command = [str(exe), *map(str, args)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60,
                                env={**os.environ, "ZANE_CHECK": check})
        if result.returncode:
            raise AssertionError(f"ZANE_CHECK={check} {command}\n{result.stdout}{result.stderr}")
        outputs[check] = result.stdout
    if outputs["1"] != outputs["0"]:
        raise AssertionError(f"{exe}: checked and unchecked runs differ\n"
                             f"ZANE_CHECK=1:\n{outputs['1']}ZANE_CHECK=0:\n{outputs['0']}")
    return outputs["1"]


def packages(*names, stamped=()):
    flags = []
    for name in names:
        flags += ["--package", f"{STAMP if name in stamped else ''}{name}={FACTS / name}"]
    return flags


class FactsTests(unittest.TestCase):
    def test_reads_need_no_snapshot_where_nothing_spawns(self):
        for optimize in [[], ["--optimize"]]:
            ir = run(ZANEC, "--ll", *optimize, *packages("quiet", "cells"))
            self.assertNotRegex(ir, SNAPSHOT)

    def test_reads_keep_snapshots_where_something_may_write_back(self):
        # A spawn in the program, in a stamped dependency it calls, or a
        # library's object, which may be linked into a program that spawns.
        for flags in [
            packages("busy", "cells"),
            packages("relay", "cells", "pool", stamped=["pool"]),
            ["--no-root", *packages("cells")],
        ]:
            self.assertRegex(run(ZANEC, "--ll", *flags), SNAPSHOT, flags)

    def test_runtime_helpers_made_in_line(self):
        ir = run(ZANEC, "--ll", *packages("quiet", "cells"))
        self.assertNotIn("@zane_list_new(", ir)
        self.assertNotIn("@zane_list_swap_remove(", ir)
        self.assertIn("@llvm.fptosi.sat.i64.f64(", ir)
        self.assertRegex(ir, r'!\{!"zane handle", ![0-9]+, i64 0\}')
        self.assertRegex(ir, r'!\{!"zane scalar", ![0-9]+, i64 0\}')

    def test_accesses_take_the_target_alignment(self):
        # The module has its target's data layout as it is emitted, so an
        # Int is read and written at the 8 bytes it is aligned to there.
        for target in [[], ["--target", "aarch64-apple-macos"]]:
            ir = run(ZANEC, "--ll", *target, *packages("quiet", "cells"))
            accesses = re.findall(r"(?:load|store) i64[^\n]*", ir)
            self.assertTrue(accesses, target)
            for access in accesses:
                self.assertIn("align 8", access, target)

    def test_discarded_removal_holds_nothing(self):
        # The cell `drop` takes out owns no block, so no scope holds it.
        cgt = run(ZANEC, "--cgt", "--no-root", *packages("cells"))
        drop = cgt.split("symbol: !cells$drop(", 1)[1].split("symbol:", 1)[0]
        self.assertIn("zane_list_swap_remove", drop)
        self.assertNotRegex(drop, r"scope|hold")

    def test_llvm_proves_the_sweep_in_bounds(self):
        # Each cell is written and read again through the list, and LLVM,
        # told the header is not an element, checks no index in the loop.
        # The labels of `main`'s inlined callees end in `.exit`, and in
        # `.exit.i` once `main` is inlined into the start function too.
        ir = run(ZANEC, "--ll", "--optimize", *packages("quiet", "cells"))
        start = re.search(r'\n"cells\$fill\(this cells\$Grid, %primitives\$I64\)\.exit(\.i)*":', ir).start()
        end = re.compile(r'\n"cells\$sweep\(this cells\$Grid\)\.exit(\.i)*":').search(ir, start).start()
        loop = ir[start:end]
        self.assertNotIn("@zane_out_of_range", loop)
        self.assertRegex(loop, r"store i64 .*!tbaa")

    def test_programs_run(self):
        with tempfile.TemporaryDirectory() as temp:
            pool = Path(temp) / "pool.o"
            run(ZANEC, "--no-root", "--object", pool, *packages("pool", stamped=["pool"]))
            for optimize in [[], ["--optimize"]]:
                for program, link, expected in [
                    ("quiet", [], "14 1\n"),
                    ("busy", [], "44 1\n"),
                    ("relay", ["--link", pool], "44\n"),
                ]:
                    exe = Path(temp) / program
                    deps = ["cells"] + (["pool"] if program == "relay" else [])
                    run(ZANEC, "--build", exe, *optimize, *link,
                        *packages(program, *deps, stamped=["pool"]))
                    self.assertEqual(run_program(exe, "4"), expected, (program, optimize))


if __name__ == "__main__":
    unittest.main()
