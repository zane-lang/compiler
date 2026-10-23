"""Which targets `zanec` builds for (docs/design/platforms.md, "64-bit
targets only"): a target whose data layout has pointers other than 8 bytes,
or `i64` or `double` aligned other than to 8, is refused before anything is
emitted for it, and the first-tier and lower-tier targets are accepted."""

from pathlib import Path
import subprocess
import sys
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
GEOMETRY = Path(__file__).resolve().parent / "fixtures/geometry"


def zanec(*args):
    return subprocess.run([ZANEC, *map(str, args)], capture_output=True, text=True, timeout=60)


class TargetTests(unittest.TestCase):
    def ll(self, target):
        return zanec("--no-root", "--ll", "--target", target, "--package", GEOMETRY)

    def test_a_32_bit_target_is_refused(self):
        for target in ["i386-unknown-linux-gnu", "armv7-unknown-linux-gnueabihf"]:
            with self.subTest(target=target):
                result = self.ll(target)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(
                    f"the target `{target}` has 4-byte pointers; "
                    "this compiler builds for 64-bit targets only",
                    result.stderr,
                )
                self.assertEqual(result.stdout, "")

    def test_a_64_bit_target_is_accepted(self):
        for target in ["x86_64-windows-gnu", "aarch64-apple-darwin", "x86_64-linux-gnu"]:
            with self.subTest(target=target):
                result = self.ll(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("target datalayout", result.stdout)


if __name__ == "__main__":
    unittest.main()
