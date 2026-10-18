"""How an aggregate crosses a call (docs/design/lowering.md §9): in
registers while it takes no more than the target gives one, two on x86-64
Linux and macOS and on AArch64 and one on x86-64 Windows, and by address
past that; what a parameter passed by address and a result returned through
`sret` tell LLVM; and `--pack-aggregates`, which passes an aggregate that
fits in those registers as packed words."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
HERE = Path(__file__).resolve().parent
LARGEPARAM = HERE / "fixtures/largeparam"
CROSSING = HERE / "../codegen/fixtures/crossing"


def zanec(*args):
    result = subprocess.run([ZANEC, *map(str, args)], capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise AssertionError(f"zanec {' '.join(map(str, args))} exited {result.returncode}:\n{result.stderr}")
    return result.stdout


def signature(ir, name):
    """The `define` line of the function whose symbol starts with NAME."""
    match = re.search(r'^define [^\n]*@"[^"]*' + re.escape(name) + r'[^\n]*$', ir, re.M)
    if not match:
        raise AssertionError(f"no function {name} in the module")
    return match.group(0)


class AbiTests(unittest.TestCase):
    def test_a_parameter_by_address_is_a_borrow(self):
        ir = zanec("--kind", "library", "--ll", "--package", LARGEPARAM)
        consume = signature(ir, "largeparam$consume(")
        self.assertIn("(ptr noalias readonly align 8 dereferenceable(524288) %0)", consume)
        self.assertNotIn("nocapture", consume)
        self.assertNotIn("[65536 x i64] %", ir)

    def test_a_result_by_address_is_written_through_sret(self):
        ir = zanec("--kind", "library", "--ll", "--package", LARGEPARAM)
        same = signature(ir, "largeparam$same(")
        self.assertRegex(same, r"^define void ")
        self.assertIn("(ptr noalias sret([65536 x i64]) align 8 %0, ptr noalias readonly", same)

    def test_the_line_falls_where_the_target_puts_it(self):
        two = r'\{ i64, i64 \} @"[^"]*"\(\{ i64, i64 \} %0\)'
        by_address = r'void @"[^"]*"\(ptr noalias sret\(\{ i64, i64 \}\) align 8 %0, ptr noalias readonly'
        for target, pair in [
            ("x86_64-linux-gnu", two),
            ("aarch64-apple-darwin", two),
            ("x86_64-windows-gnu", by_address),
        ]:
            with self.subTest(target=target):
                ir = zanec("--ll", "--target", target, "--package", CROSSING)
                self.assertRegex(signature(ir, "crossing$swapped("), pair)
                # One piece passes as itself everywhere, three nowhere.
                self.assertRegex(signature(ir, "crossing$flipped("), r"\{ i32 \} %0\)")
                self.assertRegex(signature(ir, "crossing$rotated("), r"\(ptr noalias sret")

    def test_packing_passes_words(self):
        ir = zanec("--ll", "--pack-aggregates", "--target", "x86_64-linux-gnu", "--package", CROSSING)
        # Three I32s, three pieces in 12 bytes, travel as two words.
        self.assertRegex(signature(ir, "crossing$reversed("), r'\{ i64, i64 \} @"[^"]*"\(i64 %0, i64 %1\)')
        self.assertRegex(signature(ir, "crossing$rotated("), r"\(ptr noalias sret")
        ir = zanec("--ll", "--pack-aggregates", "--target", "x86_64-windows-gnu", "--package", CROSSING)
        self.assertRegex(signature(ir, "crossing$flipped("), r'i64 @"[^"]*"\(i64 %0\)')
        self.assertRegex(signature(ir, "crossing$reversed("), r"\(ptr noalias sret")

    def test_the_object_is_written_for_every_target(self):
        # LLVM crashed writing it when the array crossed as one value.
        with tempfile.TemporaryDirectory() as temp:
            for target in ["x86_64-linux-gnu", "x86_64-windows-gnu", "aarch64-apple-darwin"]:
                for optimize in [[], ["--optimize"]]:
                    with self.subTest(target=target, optimize=optimize):
                        output = Path(temp) / f"{target}{len(optimize)}.o"
                        zanec("--kind", "library", "--object", output, "--target", target, *optimize,
                              "--package", LARGEPARAM)
                        self.assertGreater(output.stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
