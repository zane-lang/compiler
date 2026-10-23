"""Tiered builds (docs/design/tiers.md): a program that moves to tier 1 while
it runs, the libraries the runtime must refuse, and the cache of tier-1
libraries.

Each test builds into a directory of its own, with a cache directory of its
own, so none sees another's libraries. `fixtures/swap` says it started, then
works in calls of its own for as many rounds as its argument says;
`fixtures/other` is another program. `just test-compiler` runs these.
"""

import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ZANEC = ROOT / "_build" / "default" / "bin" / "zanec" / "zanec.exe"
FIXTURES = HERE / "fixtures"
# Enough rounds that a plain build runs for about a second.
ROUNDS = "300000"


class Tiers(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="zane-tiers-"))
        self.env = dict(os.environ, ZANE_CACHE_DIR=str(self.dir / "cache"))
        for name in ("ZANE_TIER_UP", "ZANE_TIER_WAIT", "ZANE_TIER_LOG"):
            self.env.pop(name, None)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def zanec(self, *args):
        subprocess.run([str(ZANEC), *args], check=True, env=self.env)

    def tier0(self, package="swap", where=FIXTURES):
        exe = self.dir / f"{package}.tier0"
        self.zanec("--build", str(exe), "--tiered", "--package", str(where / package))
        return exe

    def tier1(self, name, package="swap", where=FIXTURES):
        library = self.dir / name
        self.zanec("--tier-up", str(library), "--package", str(where / package))
        return library

    def plain(self):
        exe = self.dir / "swap.plain"
        self.zanec("--build", str(exe), "--package", str(FIXTURES / "swap"))
        return subprocess.run([str(exe), ROUNDS], check=True, capture_output=True, text=True).stdout

    def run_tiered(self, exe, library, put=None):
        """Runs *exe* with tier 1 at *library*, which *put* puts in place
        once the program has printed its first line; its output and what
        the runtime said. Its output goes to a terminal, so the program
        writes each line as it prints it."""
        env = dict(self.env, ZANE_TIER_UP=str(library), ZANE_TIER_LOG="1")
        main, side = pty.openpty()
        p = subprocess.Popen([str(exe), ROUNDS], stdout=side, stderr=subprocess.PIPE, env=env)
        os.close(side)
        output = b""
        while True:
            try:
                chunk = os.read(main, 4096)
            except OSError:
                break
            if not chunk:
                break
            if put and b"\n" in output + chunk and b"\n" not in output:
                put()
            output += chunk
        os.close(main)
        with p.stderr:
            said = p.stderr.read().decode()
        p.wait()
        self.assertEqual(p.returncode, 0, said)
        return output.decode().replace("\r\n", "\n"), said

    def test_moves_to_tier_1_while_it_runs(self):
        exe = self.tier0()
        built = self.tier1("built")
        library = self.dir / "swap.tier1"
        output, said = self.run_tiered(exe, library, put=lambda: os.rename(built, library))
        self.assertEqual(output, self.plain())
        self.assertRegex(said, r"zane: tier 1 runs (\d+) of \1 functions")

    def test_refuses_another_programs_library(self):
        exe = self.tier0()
        library = self.tier1("other.tier1", package="other")
        output, said = self.run_tiered(exe, library)
        self.assertEqual(output, self.plain())
        self.assertIn("zane: tier 1 is another program's", said)

    def test_refuses_the_library_of_the_program_before_an_edit(self):
        edited = self.dir / "edited"
        shutil.copytree(FIXTURES / "swap", edited / "swap")
        source = edited / "swap" / "main.zn"
        source.write_text(source.read_text().replace("Int(1000)", "Int(999)"))
        library = self.tier1("edited.tier1", where=edited)
        output, said = self.run_tiered(self.tier0(), library)
        self.assertEqual(output, self.plain())
        self.assertIn("zane: tier 1 is another program's", said)

    def test_stays_in_tier_0_when_no_library_comes(self):
        output, said = self.run_tiered(self.tier0(), self.dir / "never.tier1")
        self.assertEqual(output, self.plain())
        self.assertEqual(said, "")

    def test_stays_in_tier_0_when_the_library_does_not_load(self):
        library = self.dir / "broken.tier1"
        library.write_bytes(b"not a library")
        output, said = self.run_tiered(self.tier0(), library)
        self.assertEqual(output, self.plain())
        self.assertIn("zane: tier 1 did not load", said)

    def test_waiting_for_a_library_that_does_not_load_stops_the_program(self):
        library = self.dir / "broken.tier1"
        library.write_bytes(b"not a library")
        env = dict(self.env, ZANE_TIER_UP=str(library), ZANE_TIER_WAIT="1")
        p = subprocess.run([str(self.tier0()), ROUNDS], capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(p.stdout, "")
        self.assertIn("zane: tier 1 did not take every function", p.stderr)

    def test_waiting_for_a_library_that_is_not_there_stops_the_program(self):
        env = dict(self.env, ZANE_TIER_UP=str(self.dir / "never.tier1"), ZANE_TIER_WAIT="1")
        p = subprocess.run([str(self.tier0()), ROUNDS], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(p.stdout, "")
        self.assertIn("zane: tier 1 did not take every function", p.stderr)

    def test_a_stale_work_directory_that_links_elsewhere_removes_only_the_link(self):
        elsewhere = self.dir / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "kept").write_text("kept")
        library = self.dir / "linked.tier1"
        Path(f"{library}.work").symlink_to(elsewhere, target_is_directory=True)
        self.tier1("linked.tier1")
        self.assertEqual((elsewhere / "kept").read_text(), "kept")
        self.assertFalse(Path(f"{library}.work").exists())

    def test_takes_a_library_named_without_a_directory_from_the_current_one(self):
        self.tier1("bare.tier1")
        env = dict(self.env, ZANE_TIER_UP="bare.tier1", ZANE_TIER_WAIT="1")
        p = subprocess.run([str(self.tier0()), ROUNDS], capture_output=True, text=True, env=env, cwd=self.dir)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, self.plain())

    def test_takes_a_library_built_before_from_the_cache(self):
        first = self.tier1("first.tier1")
        kept = list((self.dir / "cache" / "tier").iterdir())
        self.assertEqual(len(kept), 1)
        # What the cache holds is what a second build gives back, so a mark
        # put on it shows the second build did not make its own.
        kept[0].write_bytes(first.read_bytes() + b"from the cache")
        second = self.tier1("second.tier1")
        self.assertTrue(second.read_bytes().endswith(b"from the cache"))
        self.assertFalse(Path(f"{second}.work").exists())
        self.assertFalse(Path(f"{second}.partial").exists())

    def test_the_cache_keeps_the_newest_libraries(self):
        tier = self.dir / "cache" / "tier"
        tier.mkdir(parents=True)
        for i in range(40):
            old = tier / f"old{i:02}.so"
            old.write_bytes(b"old")
            os.utime(old, (1000 + i, 1000 + i))
        self.tier1("new.tier1")
        left = sorted(p.name for p in tier.iterdir())
        self.assertEqual(len(left), 32)
        self.assertNotIn("old00.so", left)
        self.assertIn("old39.so", left)


if __name__ == "__main__":
    unittest.main()
