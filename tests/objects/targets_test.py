"""Which targets `zanec` builds for (docs/design/platforms.md, "64-bit
targets only"): a target whose data layout has pointers other than 8 bytes,
or `i64` or `double` aligned other than to 8, is refused before anything is
emitted for it, and the first-tier and lower-tier targets are accepted.
A boxed member is stored as a chunk's number on a Mach-O target, and
relative to the image elsewhere (docs/optimizations.md, "Boxes in 32
bits")."""

from pathlib import Path
import os
import subprocess
import sys
import unittest

ZANEC = str(Path(sys.argv.pop(1)).resolve())
GEOMETRY = Path(__file__).resolve().parent / "fixtures/geometry"
COUNTDOWN = Path(__file__).resolve().parent / "fixtures/countdown"
SWITCHES = ["ZANE_FRAME_REFS", "ZANE_IMAGE_BOXES", "ZANE_CHUNK_BOXES"]


def zanec(*args, env=None):
    environment = {k: v for k, v in os.environ.items() if k not in SWITCHES}
    environment.update(env or {})
    return subprocess.run(
        [ZANEC, *map(str, args)], capture_output=True, text=True, timeout=60, env=environment
    )


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

    def boxes(self, target, env=None):
        result = zanec("--no-root", "--ll", "--target", target, "--package", COUNTDOWN, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_a_mach_o_target_numbers_boxes_by_chunk(self):
        # arm64 macOS leaves no room within 16 GiB of the image for the
        # window image boxes need (#418), so its boxes name chunks.
        for target in ["aarch64-apple-darwin", "x86_64-apple-darwin"]:
            with self.subTest(target=target):
                self.assertIn("zane_mib_bases", self.boxes(target))

    def test_other_targets_store_boxes_relative_to_the_image(self):
        for target, image in [("x86_64-linux-gnu", "@__ehdr_start"), ("x86_64-windows-gnu", "@__ImageBase")]:
            with self.subTest(target=target):
                ll = self.boxes(target)
                self.assertNotIn("zane_mib_bases", ll)
                self.assertIn(image, ll)

    def test_the_switches_choose_a_mach_o_targets_boxes(self):
        target = "aarch64-apple-darwin"
        image = self.boxes(target, {"ZANE_CHUNK_BOXES": "0"})
        self.assertNotIn("zane_mib_bases", image)
        self.assertIn("@_mh_execute_header", image)
        wide = self.boxes(target, {"ZANE_IMAGE_BOXES": "0"})
        self.assertNotIn("zane_mib_bases", wide)
        self.assertNotIn("@_mh_execute_header", wide)

if __name__ == "__main__":
    unittest.main()
