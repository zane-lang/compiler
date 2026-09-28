#!/usr/bin/env python3
"""Tests of tools/ambiguity/cli.py and runner.py: the command line, survey
flags and streamed output."""

import queue
import subprocess
import threading
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import TextIO
import unittest

from tools.ambiguity import cli, profiles, runner
from tests.ambiguity.engine_support import ENGINE, ROOT, TINY_GRAMMAR, engine_environment

# A deliberately branchy expression grammar for the progress-pipe check. The
# tiny grammar settles its proof before the engine's 128-pair progress
# cadence is reached, so it cannot exercise progress output reliably.
PROGRESS_GRAMMAR = """\
%token A "a"
%token B "b"
%token PLUS "+"
%token TIMES "*"
%token MINUS "-"
%token SLASH "/"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | B { () }
  | e PLUS e { () }
  | e TIMES e { () }
  | e MINUS e { () }
  | e SLASH e { () }
"""


class CommandLineTests(unittest.TestCase):
    def test_search_defaults_to_general(self) -> None:
        arguments = cli.parser().parse_args(["search"])
        self.assertEqual(arguments.profile, "general")

    def test_prove_defaults_to_quick(self) -> None:
        arguments = cli.parser().parse_args(["prove", "3"])
        self.assertEqual(arguments.profile, "quick")

    def test_check_accepts_quoted_or_individual_tokens(self) -> None:
        command = cli.parser()
        quoted = command.parse_args(["check", "UIDENT LPAREN RPAREN EOF"])
        separate = command.parse_args(
            ["check", "UIDENT", "LPAREN", "RPAREN", "EOF"]
        )
        self.assertEqual(" ".join(quoted.tokens), " ".join(separate.tokens))

    def test_engine_arguments_are_stable_and_low_level(self) -> None:
        profile = profiles.SearchProfile(
            name="deep",
            description="",
            min_tokens=12,
            max_tokens=50,
            timeout_seconds=1800,
            witnesses=50,
            prefix_tokens=("UIDENT", "LCURLY"),
            nodes_per_depth=10,
        )
        self.assertEqual(
            runner.engine_arguments(profile),
            [
                "--max-tokens",
                "50",
                "--min-tokens",
                "12",
                "--timeout",
                "1800",
                "--max-witnesses",
                "50",
                "--prefix-tokens",
                "UIDENT LCURLY",
                "--nodes-per-depth",
                "10",
            ],
        )


class SurveyFlagTests(unittest.TestCase):
    """The survey reaches the engine only when asked for."""

    def profile(self) -> profiles.SearchProfile:
        return profiles.SearchProfile(
            name="quick",
            description="",
            min_tokens=0,
            max_tokens=16,
            timeout_seconds=900,
            witnesses=50,
            prefix_tokens=(),
            nodes_per_depth=None,
        )

    def test_a_survey_is_absent_unless_requested(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3)
        self.assertNotIn("--prove-survey", arguments)

    def test_a_requested_survey_reaches_the_engine(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3, 5)
        self.assertIn("--prove-survey", arguments)
        self.assertEqual(
            arguments[arguments.index("--prove-survey") + 1], "5"
        )

    def test_requested_CEGAR_reaches_the_engine(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3, cegar=2)
        self.assertEqual(arguments[arguments.index("--prove-cegar") + 1], "2")

    def test_CEGAR_and_refinement_can_be_requested_together(self) -> None:
        arguments = runner.engine_arguments(
            self.profile(), 3, refine=9, cegar=2
        )
        self.assertEqual(arguments[arguments.index("--prove-cegar") + 1], "2")
        self.assertEqual(arguments[arguments.index("--prove-refine") + 1], "9")

    def test_refinement_is_absent_unless_requested(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3)
        self.assertNotIn("--prove-refine", arguments)
        self.assertNotIn("--prove-refine-rounds", arguments)

    def test_requested_refinement_reaches_the_engine(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3, refine=9)
        self.assertIn("--prove-refine", arguments)
        self.assertEqual(arguments[arguments.index("--prove-refine") + 1], "9")

    def test_a_round_limit_only_travels_with_refinement(self) -> None:
        # The engine has its own default, so passing a round limit without
        # refinement would set a bound on something that is not running.
        arguments = runner.engine_arguments(
            self.profile(), 3, refine=0, refine_rounds=4
        )
        self.assertNotIn("--prove-refine-rounds", arguments)
        arguments = runner.engine_arguments(
            self.profile(), 3, refine=9, refine_rounds=4
        )
        self.assertEqual(
            arguments[arguments.index("--prove-refine-rounds") + 1], "4"
        )

    def test_retirement_only_travels_with_refinement(self) -> None:
        # Retiring names what refinement failed to close, so on its own it has
        # nothing to act on and the engine would never see the option.
        arguments = runner.engine_arguments(self.profile(), 3, refine=0, retire=2)
        self.assertNotIn("--prove-retire", arguments)
        arguments = runner.engine_arguments(self.profile(), 3, refine=9, retire=2)
        self.assertEqual(arguments[arguments.index("--prove-retire") + 1], "2")

    def test_a_trace_only_travels_when_asked(self) -> None:
        self.assertNotIn("--prove-trace", runner.engine_arguments(self.profile(), 3))
        self.assertIn(
            "--prove-trace",
            runner.engine_arguments(self.profile(), 3, trace=True),
        )

    def test_the_wrapper_rejects_its_own_invalid_refinements(self) -> None:
        # The wrapper repeats two checks the engine also makes, so that the
        # message names the option the caller typed rather than the engine's
        # spelling of it. Without a test the duplication can rot away silently:
        # the run still fails, just with the wrong option name in the error.
        for name, argv in (
            ("below the proof level", ["prove", "4", "--refine", "2"]),
            ("with a survey", ["prove", "1", "--refine", "4", "--survey", "1"]),
            ("rounds without refinement", ["prove", "1", "--refine-rounds", "4"]),
            ("trace with a survey", ["prove", "1", "--trace", "--survey", "1"]),
            ("retire without refinement", ["prove", "1", "--retire", "2"]),
            ("negative CEGAR rounds", ["prove", "1", "--cegar", "-1"]),
            ("CEGAR with a survey", ["prove", "1", "--cegar", "1", "--survey", "1"]),
        ):
            with self.subTest(combination=name):
                with self.assertRaises(SystemExit):
                    cli.main([*argv, "--dry-run"])

    def test_the_wrapper_accepts_a_valid_refinement(self) -> None:
        # The guard against the test above passing because every prove
        # invocation is rejected.
        self.assertEqual(
            cli.main(
                ["prove", "1", "--refine", "4", "--refine-rounds", "2", "--dry-run"]
            ),
            0,
        )

    def test_the_wrapper_accepts_CEGAR(self) -> None:
        self.assertEqual(cli.main(["prove", "1", "--cegar", "2", "--dry-run"]), 0)


class StreamingOutputTests(unittest.TestCase):
    """The engine's output has to arrive while a run is happening, not when it
    ends.

    Every wrapper reads it through a pipe -- `ambiguity` streams it to the
    terminal and into the saved report, the sweep passes each level's through --
    and on a pipe OCaml block-buffers stdout. A whole proof run's output used to
    sit in that buffer until the process exited, so a report file stayed empty
    for the run it was documenting, and a search that ran for an hour said
    nothing while it did. Skipped when the engine binary or menhir is
    unavailable, like the other end-to-end checks here."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/engine/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "tiny.mly"
        self.grammar.write_text(TINY_GRAMMAR, encoding="utf-8")

    def engine(
        self, *arguments: str, **overrides: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(ENGINE), *arguments, str(self.grammar)],
            env={**self.environment, **overrides},
            text=True,
            capture_output=True,
            timeout=120,
        )

    @staticmethod
    def first_line(handle: TextIO, seconds: float) -> str | None:
        """The first line, or None if none arrives within ``seconds``.

        Read on a thread rather than with a plain `readline`, which would block
        for as long as the run lasts -- exactly the state this test has to be
        able to observe from the outside.
        """
        lines: queue.Queue[str] = queue.Queue()
        reader = threading.Thread(
            target=lambda: lines.put(handle.readline()), daemon=True
        )
        reader.start()
        try:
            return lines.get(timeout=seconds)
        except queue.Empty:
            return None

    def test_the_first_line_arrives_before_the_run_ends(self) -> None:
        # Zane's own grammar with a long deadline: the abstract phase is still
        # walking when the first line is read, which is what makes the read
        # evidence of flushing rather than of a run that happened to be over.
        process = subprocess.Popen(
            [
                str(ENGINE),
                "--prove", "2",
                "--prove-survey", "1",
                "--max-tokens", "8",
                "--timeout", "60",
                "--max-witnesses", "2",
                str(ROOT / "lib" / "cst" / "parser.mly"),
            ],
            env={**self.environment, "AMBIGUITY_MEMORY_MB": "512"},
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )

        def stop() -> None:
            process.kill()
            process.wait()
            if process.stdout is not None:
                process.stdout.close()

        self.addCleanup(stop)
        assert process.stdout is not None
        line = self.first_line(process.stdout, 60)
        self.assertIsNotNone(line, "no output arrived while the engine ran")
        self.assertIn("Search constraints", line or "")
        self.assertIsNone(
            process.poll(), "the engine exited before the line could prove anything"
        )

    def test_progress_reaches_a_pipe(self) -> None:
        # Use enough unresolved expression branches to cross the engine's
        # progress cadence. The tiny grammar settles before 128 pairs, so it
        # cannot exercise progress output reliably.
        self.grammar.write_text(PROGRESS_GRAMMAR, encoding="utf-8")
        result = self.engine(
            "--prove", "2",
            "--prove-survey", "1",
            "--max-tokens", "24",
            "--timeout", "5",
            "--max-witnesses", "5",
            AMBIGUITY_PROGRESS_SECONDS="0.05",
        )
        # Survey mode keeps the run in the abstract phase, so this cannot be
        # satisfied by the concrete-search force emission after a candidate.
        self.assertIn("Survey at level", result.stdout)
        self.assertTrue(
            any(line.startswith("●") for line in result.stderr.splitlines()),
            result.stderr,
        )

    def test_progress_can_be_switched_off(self) -> None:
        result = self.engine(
            "--prove", "2",
            "--max-tokens", "24",
            "--timeout", "5",
            "--max-witnesses", "5",
            AMBIGUITY_PROGRESS_SECONDS="0",
        )
        self.assertNotIn("●", result.stderr)

    def cadence(self, value: str) -> subprocess.CompletedProcess[str]:
        return self.engine(
            "--prove", "2",
            "--max-tokens", "8",
            "--timeout", "5",
            "--max-witnesses", "5",
            AMBIGUITY_PROGRESS_SECONDS=value,
        )

    def test_a_malformed_cadence_is_an_ordinary_error(self) -> None:
        result = self.cadence("often")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(
            "AMBIGUITY_PROGRESS_SECONDS must be a finite number", result.stderr
        )
        # Reported by the toplevel handler rather than as an uncaught exception.
        # That handler clears the progress line first, and reading the setting
        # a second time there is what used to turn the error into a crash.
        self.assertNotIn("Fatal error", result.stderr)

    def test_a_non_finite_cadence_is_refused_rather_than_obeyed(self) -> None:
        # These parse as floats, so they used to be taken for a setting and
        # then show no progress at all -- silently, and in two different ways.
        # Every comparison against nan is false, so it read as switched off;
        # nothing is ever as old as infinity, so a run reported progress as
        # enabled and never printed a line. Neither is a cadence anyone asked
        # for, so both are refused like any other bad setting.
        for value in ("nan", "infinity", "-infinity"):
            with self.subTest(cadence=value):
                result = self.cadence(value)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(
                    "AMBIGUITY_PROGRESS_SECONDS must be a finite number",
                    result.stderr,
                )
                self.assertNotIn("Fatal error", result.stderr)


if __name__ == "__main__":
    unittest.main()
