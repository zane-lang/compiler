#!/usr/bin/env python3
"""The sweep's process runner, which is what makes a level readable while it
runs rather than only once it ends.

These need no engine and no menhir: the runner's contract is about pipes,
kills, and what survives them, so the commands here are shells that produce a
known shape of output.
"""

import os
import subprocess
import sys
import time
import unittest
from threading import Thread
from unittest import mock

from tools import precision_sweep


class StreamTests(unittest.TestCase):
    def run_command(
        self, script: str, timeout: float = 30.0, echo: str | None = None
    ) -> tuple[int, str, str, bool]:
        return precision_sweep.stream(
            ["sh", "-c", script], dict(os.environ), timeout, echo
        )

    def test_both_channels_are_collected_and_kept_apart(self) -> None:
        # The row is read back out of stdout alone, so folding stderr into it
        # would let a diagnostic be mistaken for a survey line.
        status, out, errors, timed_out = self.run_command(
            "echo first; echo warned >&2; echo second; exit 3"
        )
        self.assertEqual(status, 3)
        self.assertFalse(timed_out)
        self.assertEqual(out, "first\nsecond\n")
        self.assertEqual(errors, "warned\n")

    def test_lines_are_echoed_under_their_prefix(self) -> None:
        # The prefix is what makes a level's output identifiable in a sweep
        # that runs several of them one after another.
        with mock.patch.object(sys, "stderr", new_callable=FakeStderr) as fake:
            self.run_command("echo one; echo two >&2", echo="[level 4] ")
        self.assertEqual(
            sorted(fake.written), ["[level 4] one\n", "[level 4] two\n"]
        )

    def test_nothing_is_echoed_without_a_prefix(self) -> None:
        with mock.patch.object(sys, "stderr", new_callable=FakeStderr) as fake:
            status, out, _, _ = self.run_command("echo one", echo=None)
        self.assertEqual(status, 0)
        self.assertEqual(out, "one\n")
        self.assertEqual(fake.written, [])

    def test_a_level_past_its_bound_is_killed_and_what_it_wrote_is_kept(
        self,
    ) -> None:
        status, out, _, timed_out = self.run_command("echo started; sleep 30", 0.5)
        self.assertTrue(timed_out)
        self.assertNotEqual(status, 0)
        # A killed level still reported the constraints it started under, and
        # the sweep prints them when it explains the broken row.
        self.assertEqual(out, "started\n")

    def test_a_killed_level_takes_what_it_forked_with_it(self) -> None:
        # The engine forks workers and shells out to menhir, so killing only
        # the process we started leaves those running -- burning a core and a
        # memory budget, and holding the inherited pipes open. The level runs
        # in its own process group and the group is what gets killed, so the
        # pipes close and the readers finish on their own.
        #
        # The grace period is set high on purpose: if the forked `sleep`
        # survived, the readers would still be blocked on its copy of the pipe
        # and the call could only return by waiting the whole grace out. So a
        # prompt return is the evidence that the group really died.
        with mock.patch.object(precision_sweep, "PUMP_GRACE_SECONDS", 30.0):
            started = time.monotonic()
            _, out, _, timed_out = self.run_command(
                "echo started; sleep 30 & sleep 30", 0.5
            )
            elapsed = time.monotonic() - started
        self.assertTrue(timed_out)
        self.assertEqual(out, "started\n")
        self.assertLess(elapsed, 5.0, "the forked child outlived the kill")

    def test_the_readers_are_still_bounded_if_something_survives(self) -> None:
        # Belt and braces behind the process group: a reader that cannot reach
        # EOF is left behind rather than waited on forever. Simulated by a
        # process the runner did not start, whose pipe therefore outlives it.
        holder = subprocess.Popen(["sleep", "30"], stdout=subprocess.PIPE)

        def release() -> None:
            holder.kill()
            holder.wait()
            if holder.stdout is not None:
                holder.stdout.close()

        self.addCleanup(release)
        assert holder.stdout is not None
        pumps_started = time.monotonic()
        with mock.patch.object(precision_sweep, "PUMP_GRACE_SECONDS", 0.5):
            reader = Thread(
                target=lambda: holder.stdout.read(), daemon=True  # type: ignore[union-attr]
            )
            reader.start()
            reader.join(precision_sweep.PUMP_GRACE_SECONDS)
        self.assertTrue(reader.is_alive(), "the reader should still be blocked")
        self.assertLess(time.monotonic() - pumps_started, 5.0)


class FakeStderr:
    """Collects what the runner echoes, one entry per write."""

    def __init__(self) -> None:
        self.written: list[str] = []

    def write(self, text: str) -> int:
        self.written.append(text)
        return len(text)

    def flush(self) -> None:
        pass


if __name__ == "__main__":
    unittest.main()
