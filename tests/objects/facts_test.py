"""What codegen tells LLVM about a program, and what LLVM makes of it
(docs/design/lowering.md §9, "What LLVM is told")."""

from pathlib import Path
import os
import platform
import re
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
FACTS = Path(__file__).resolve().parent / "fixtures/facts"
STAMP = "v1.0%0123456789abcdef%"
SNAPSHOT = re.compile(r"load atomic|@zane_snapshot\(")
# A list handle's room and size: with frame references (experimental,
# lib/cgt/ref32.ml), on by default on every target, the room counts elements
# in 32 bits and the handle is 16 bytes; without, the room counts bytes and
# it is 24.
FRAME_REFS = os.environ.get("ZANE_FRAME_REFS") != "0"
FIRST_ROOM = r"store i32 4, " if FRAME_REFS else r"store i64 32, "
TWO_HANDLES = 32 if FRAME_REFS else 48


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

    def test_reads_need_no_snapshot_where_nothing_is_written_back(self):
        # A spawned call that writes no subject back races no read.
        for optimize in [[], ["--optimize"]]:
            ir = run(ZANEC, "--ll", *optimize, *packages("idle", "cells"))
            self.assertNotRegex(ir, SNAPSHOT)

    def test_only_reads_of_a_place_written_back_take_snapshots(self):
        # `busy` writes back a `Tally`'s Int: reading it back is a snapshot,
        # and the cells' Int hits and Float heat, in owners of another type,
        # are read plainly though they are values of the same types.
        ir = run(ZANEC, "--ll", *packages("busy", "cells"))
        self.assertRegex(ir, r"load atomic i64")
        sweep = ir[ir.index('define internal i64 @"cells$sweep('):]
        sweep = sweep[: sweep.index("\n}\n")]
        self.assertNotRegex(sweep, SNAPSHOT)

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
        # Int is read and written at the 8 bytes it is aligned to there,
        # wherever its address is known to be aligned: a local, a list's
        # element of a whole number of words. A walk's helper is given the
        # address of a value that may be a member of a packed one, at any
        # byte, so it reads and writes at 1.
        for target in [[], ["--target", "aarch64-apple-macos"]]:
            ir = run(ZANEC, "--ll", *target, *packages("quiet", "cells"))
            helper = None
            seen = {True: 0, False: 0}
            for line in ir.splitlines():
                if line.startswith("define"):
                    helper = '@"%primitives$' in line
                elif re.search(r"(?:load|store) i64", line):
                    seen[helper] += 1
                    self.assertRegex(line, r"align 1(?!\d)" if helper else r"align 8(?!\d)", target)
            self.assertTrue(seen[True] and seen[False], target)

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

    def test_removals_of_scalars_leave_the_count(self):
        # A move of elements that hold no handle is a scalar access, which
        # cannot write a list's header, so the loop that removes foes from
        # its list in one way keeps the count it read in a register through
        # the other, and each bounds check compares against that register.
        # A move of strings, each a handle, carries no tag. How many copies
        # of each move LLVM keeps is its own choice.
        ir = run(ZANEC, "--ll", "--optimize", *packages("culls"))
        moves = re.findall(r"call void @llvm\.memmove\.p0\.p0\.i64\([^\n]*", ir)
        self.assertEqual(sorted({"!tbaa" in move for move in moves}), [False, True], moves)
        start = re.search(r"(?ms)^define [^\n]*@zane_main\(.*?^}", ir).group(0)
        defined = dict(re.findall(r"(?m)^\s*(%[\w.]+) = (\w+)", start))
        counts = re.findall(r"icmp ult i64 %[\w.]+, (%[\w.]+)", start)
        self.assertTrue(counts)
        self.assertNotIn("load", [defined.get(count) for count in counts])
        with tempfile.TemporaryDirectory() as temp:
            for optimize in [[], ["--optimize"]]:
                exe = Path(temp) / "culls"
                run(ZANEC, "--build", exe, *optimize, *packages("culls"))
                self.assertEqual(run_program(exe, 9), "64 7\n", optimize)

    def test_pushes_of_scalars_leave_the_count(self):
        # The element a push moves in is a scalar access, tagged so LLVM
        # sees it cannot write the list's header, which is what lets the
        # optimizer keep the count and room of pushes in a row in registers.
        # Each element store carries that tag.
        ir = run(ZANEC, "--ll", *packages("pushes"))
        gather = re.search(r"(?ms)^define [^\n]*@\"pushes\$gather\(.*?^}", ir).group(0)
        stores = re.findall(r"store double [^\n]*", gather)
        self.assertEqual(len(stores), 4, gather)
        for store in stores:
            self.assertIn("!tbaa", store)
        with tempfile.TemporaryDirectory() as temp:
            for optimize in [[], ["--optimize"]]:
                exe = Path(temp) / "pushes"
                run(ZANEC, "--build", exe, *optimize, *packages("pushes"))
                self.assertEqual(run_program(exe, 1), "11\n", optimize)

    def test_first_blocks_are_made_inline_in_a_scope(self):
        # An empty list's first block, of at most ZANE_LIST_FIRST bytes, is
        # made by the push itself, which stores its room for four of its
        # 8-byte elements, in a function with a scope of its own open, when
        # the region has no returned block of that size and room at its
        # frontier or in the frame; otherwise, and in a function with no
        # scope, the push calls the runtime for it (Emit.push).
        ir = run(ZANEC, "--ll", *packages("pushes"))
        body = lambda name: re.search(r"(?ms)^define [^\n]*@\"pushes\$" + name + r"\(.*?^}", ir).group(0)
        self.assertRegex(body("gather"), FIRST_ROOM)
        self.assertNotRegex(body("fill"), FIRST_ROOM)
        self.assertIn("@zane_list_push", body("fill"))

    def test_runs_of_pushes_make_room_once(self):
        # A new list pushed to four times in a row makes room for all four
        # at its first push, so the room is compared once, and the other
        # three pushes are stores with no look at it; past a first block,
        # the runtime makes the room for all four (Loop_shapes.runs).
        ir = run(ZANEC, "--ll", *packages("pushes"))
        gather = re.search(r"(?ms)^define [^\n]*@\"pushes\$gather\(.*?^}", ir).group(0)
        self.assertEqual(gather.count("icmp sgt"), 1, gather)
        self.assertIn("@zane_list_reserve(", gather)
        self.assertNotIn("@zane_list_push(", gather)

    def test_optimized_builds_inline_the_runtimes_bodies(self):
        # A plain build calls the runtime; an optimized one takes the bodies
        # of the functions it calls from the runtime's bitcode for LLVM to
        # inline, all but a cold one's, which stays a call
        # (lib/codegen/runtime_bodies.ml).
        call = lambda name: re.compile(r"call [^\n]*@" + name + r"\(")
        plain = run(ZANEC, "--ll", *packages("pushes"))
        optimized = run(ZANEC, "--ll", "--optimize", *packages("pushes"))
        for name in ["zane_defer", "zane_leaves"]:
            self.assertRegex(plain, call(name))
            self.assertNotRegex(optimized, call(name))
        self.assertRegex(optimized, call("zane_hold"))
        self.assertNotIn("available_externally", optimized)

    @unittest.skipIf(sys.platform == "win32", "the wrapper is a shell script")
    def test_runtime_bodies_inline_whatever_processor_the_c_compiler_targets(self):
        # The runtime's bitcode is stamped with the C compiler's own
        # processor, which on macOS is newer than the baseline the program
        # is compiled for; the bodies kept lose it, so they inline all the
        # same (lib/codegen/runtime_bodies.ml). Here the C compiler is made
        # to target a newer processor than the baseline on any host.
        newer = "-mcpu=apple-m1" if platform.machine() in ("arm64", "aarch64") else "-march=penryn"
        cc = os.environ.get("ZANE_BITCODE_CC") or os.environ.get("ZANE_CC") or "clang"
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = Path(tmp) / "cc"
            wrapper.write_text(f'#!/bin/sh\nexec "{cc}" {newer} "$@"\n')
            wrapper.chmod(0o755)
            result = subprocess.run([ZANEC, "--ll", "--optimize", *packages("pushes")], capture_output=True,
                                    text=True, encoding="utf-8", timeout=60,
                                    env={**os.environ, "ZANE_BITCODE_CC": str(wrapper)})
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ["zane_defer", "zane_leaves"]:
            self.assertNotRegex(result.stdout, r"call [^\n]*@" + name + r"\(")

    def test_elif_joins_the_if_before_it(self):
        # Each way into an `elif` already decides its `~this` half, so the
        # pair is one chain, as C's `else if` is, and neither body's work is
        # made a select that every pass round the loop pays for
        # (Passes.optimized).
        for optimize in [[], ["--optimize"]]:
            ir = run(ZANEC, "--ll", *optimize, *packages("bounce"))
            self.assertNotRegex(ir, r"select i1 [^,]*, double", optimize)

    def test_places_and_frames_may_be_read_ahead(self):
        # The method's subject is the whole of the caller's slot, two list
        # handles, and `main`'s frame is all there once its scope is open,
        # so the loops in both read each list's count and block once. The
        # slot may be a member at any byte of a packed value, so it claims
        # no alignment (Emit.declare_places).
        ir = run(ZANEC, "--ll", *packages("bounce"))
        self.assertRegex(ir, rf'@"bounce\$step\([^"]*\)"\(ptr nonnull dereferenceable\({TWO_HANDLES}\) %0')
        self.assertRegex(ir, r'call void @llvm\.assume\(i1 true\) \[ "dereferenceable"\(ptr %[^,]+, i64 [0-9]+\), "align"')

    def test_references_may_be_read_ahead(self):
        # An `&T` parameter names a settled owner, which stays where it is
        # for as long as the reference lives (memory.md §4.2), so the whole
        # of its slot, two list handles, is there for the call.
        ir = run(ZANEC, "--ll", *packages("borrowed"))
        self.assertRegex(
            ir, rf'(?m)^define [^@\n]*@"borrowed\$total\(&borrowed\$Field, [^"]*\)"\(ptr nonnull dereferenceable\({TWO_HANDLES}\) %0')

    def test_long_loops_lose_their_index_checks(self):
        # An optimized build emits a loop over elements twice, weighted to
        # go round 1,000 and 4 times (Emit.versioned), and IRCE splits the
        # long copy into a main loop with no checks and the iterations after
        # it, whose block names it gives (Passes.optimized): both of
        # bounce's loops, the one in `step`, inlined into `main`, and the
        # one in `main` itself. A plain build, whose passes have no use for
        # the copies, emits each loop once.
        ir = run(ZANEC, "--ll", *packages("bounce"))
        self.assertNotIn('!{!"branch_weights", i32 1000, i32 1}', ir)
        ir = run(ZANEC, "--ll", "--optimize", *packages("bounce"))
        selectors = set(re.findall(r"\n(main\.exit\.selector[.\w]*):", ir))
        self.assertGreaterEqual(len(selectors), 2, selectors)
        self.assertRegex(ir, r"\npostloop[.\w]*:")

    def test_short_loops_that_leave_early_are_unrolled_twice(self):
        # A counted loop that can return early and holds only arithmetic is
        # asked to be unrolled twice (Emit.unrolled): its back edge names a
        # loop node that holds `llvm.loop.unroll.count` 2, in each of
        # `escapes`' copies, the memo pass's and the plain one. `first`'s
        # loop, which calls `sevenfold`, carries none. Optimized, LLVM
        # unrolls each copy of `escapes`' loop, so its escape test is there
        # twice as often.
        ir = run(ZANEC, "--ll", *packages("escapes"))
        bodies = {}
        for m in re.finditer(r'(?ms)^define [^\n]*@"escapes\$(\w+)\([^"]*\)([.\w]*)"[^\n]*\n(.*?)^\}', ir):
            bodies[m.group(1) + m.group(2)] = m.group(3)
        hint = re.search(r'(?m)^(![0-9]+) = !\{!"llvm\.loop\.unroll\.count", i32 2\}$', ir)
        self.assertIsNotNone(hint, "no unroll count in the plain build")
        loops = {m.group(1) for m in re.finditer(rf'(?m)^(![0-9]+) = distinct !\{{\1, {hint.group(1)}\}}$', ir)}
        for name in ("escapes.memo", "escapes.plain"):
            self.assertRegex(bodies[name], r"br label %\w+, !llvm\.loop !\d+", name)
            named = set(re.findall(r"!llvm\.loop (![0-9]+)", bodies[name]))
            self.assertTrue(named and named <= loops, (name, named, loops))
        self.assertNotIn("!llvm.loop", bodies["first"])
        tests = lambda ir: len(re.findall(r"fcmp \w+ double [^\n]*4\.000000e\+00", ir))
        optimized = run(ZANEC, "--ll", "--optimize", *packages("escapes"))
        self.assertEqual(tests(optimized), 2 * tests(ir))

    def test_escapes_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            for optimize in [[], ["--optimize"]]:
                exe = Path(temp) / "escapes"
                run(ZANEC, "--build", exe, *optimize, *packages("escapes"))
                self.assertEqual(run_program(exe, 40, 20), "29 14\n", optimize)
                self.assertEqual(run_program(exe, 100, 10), "71 0\n", optimize)

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
            run(ZANEC, "--no-root", "--object", pool, *packages("pool", stamped=["pool"]))
            for optimize in [[], ["--optimize"]]:
                for program, link, expected in [
                    ("quiet", [], "14 1\n"),
                    ("busy", [], "44 1\n"),
                    ("idle", [], "44 1\n"),
                    ("relay", ["--link", pool], "44\n"),
                ]:
                    exe = Path(temp) / program
                    deps = ["cells"] + (["pool"] if program == "relay" else [])
                    run(ZANEC, "--build", exe, *optimize, *link,
                        *packages(program, *deps, stamped=["pool"]))
                    self.assertEqual(run_program(exe, "4"), expected, (program, optimize))


if __name__ == "__main__":
    unittest.main()
