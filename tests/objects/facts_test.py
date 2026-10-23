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
            ["--kind", "library", *packages("cells")],
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
        cgt = run(ZANEC, "--cgt", "--kind", "library", *packages("cells"))
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

    def test_elif_joins_the_if_before_it(self):
        # Each way into an `elif` already decides its `~this` half, so the
        # pair is one chain, as C's `else if` is, and neither body's work is
        # made a select that every pass round the loop pays for
        # (Passes.threading).
        for optimize in [[], ["--optimize"]]:
            ir = run(ZANEC, "--ll", *optimize, *packages("bounce"))
            self.assertNotRegex(ir, r"select i1 [^,]*, double", optimize)

    def test_places_and_frames_may_be_read_ahead(self):
        # The method's subject is the whole of the caller's slot, two list
        # handles, and `main`'s frame is all there once its scope is open,
        # so the loops in both read each list's count and block once.
        ir = run(ZANEC, "--ll", *packages("bounce"))
        self.assertRegex(ir, r'@"bounce\$step\([^"]*\)"\(ptr nonnull align 8 dereferenceable\(48\) %0')
        self.assertRegex(ir, r'call void @llvm\.assume\(i1 true\) \[ "dereferenceable"\(ptr %[^,]+, i64 [0-9]+\), "align"')

    def test_long_loops_lose_their_index_checks(self):
        # An optimized build emits a loop over elements twice, weighted to
        # go round 1,000 and 4 times (Emit.versioned), and IRCE splits the
        # long copy into a main loop with no checks and the iterations after
        # it, whose block names it gives (Passes.optimized). A plain build,
        # whose passes have no use for the copies, emits each loop once.
        ir = run(ZANEC, "--ll", *packages("bounce"))
        self.assertNotIn('!{!"branch_weights", i32 1000, i32 1}', ir)
        ir = run(ZANEC, "--ll", "--optimize", *packages("bounce"))
        self.assertRegex(ir, r"\nmain\.exit\.selector[.\w]*:")
        self.assertRegex(ir, r"\npostloop[.\w]*:")

    def test_bounce_runs_and_stops_out_of_range(self):
        with tempfile.TemporaryDirectory() as temp:
            for optimize in [[], ["--optimize"]]:
                exe = Path(temp) / "bounce"
                run(ZANEC, "--build", exe, *optimize, *packages("bounce"))
                self.assertEqual(run_program(exe, 20, 20, 3), "2727 963\n", optimize)
                self.assertEqual(run_program(exe, 20, 15, 3), "2268 806\n", optimize)
                result = subprocess.run([str(exe), "20", "21", "3"], capture_output=True, text=True, timeout=60)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (1, "", "index out of range\n"), optimize)

    def test_programs_run(self):
        with tempfile.TemporaryDirectory() as temp:
            pool = Path(temp) / "pool.o"
            run(ZANEC, "--kind", "library", "--object", pool, *packages("pool", stamped=["pool"]))
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
