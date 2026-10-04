#!/usr/bin/env python3
"""Tests of tools/ambiguity/cli.py and runner.py: the command line and
streamed output."""

import queue
import subprocess
import threading
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import TextIO
import unittest

from tools.ambiguity import cli, profiles, runner
from tests.ambiguity.engine_support import ENGINE, ROOT, TINY_GRAMMAR, engine_environment

# A deliberately branchy expression grammar for the progress-pipe check: its
# search space is wide enough that the run is still going when a progress line
# falls due, which the tiny grammar's is not.
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


class StreamingOutputTests(unittest.TestCase):
    """The engine's output has to arrive while a run is happening, not when it
    ends.

    `ambiguity` reads it through a pipe, streaming it to the terminal and into
    the saved report, and on a pipe OCaml block-buffers stdout unless the
    engine flushes. Skipped when the engine binary or menhir is unavailable,
    like the other end-to-end checks here."""

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
        # Zane's own grammar with a long deadline: the search is still running
        # when the first line is read, which is what makes the read evidence
        # of flushing rather than of a run that happened to be over.
        process = subprocess.Popen(
            [
                str(ENGINE),
                "--max-tokens", "50",
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
            process.poll(), "the engine exited before the line could show anything"
        )

    def test_progress_reaches_a_pipe(self) -> None:
        # Enough unresolved expression branches that the search outlasts the
        # progress cadence; the witness limit is high enough not to end it
        # first.
        self.grammar.write_text(PROGRESS_GRAMMAR, encoding="utf-8")
        result = self.engine(
            "--max-tokens", "24",
            "--timeout", "2",
            "--max-witnesses", "100000",
            AMBIGUITY_PROGRESS_SECONDS="0.05",
        )
        self.assertTrue(
            any(line.startswith("●") for line in result.stderr.splitlines()),
            result.stderr,
        )

    def test_progress_can_be_switched_off(self) -> None:
        self.grammar.write_text(PROGRESS_GRAMMAR, encoding="utf-8")
        result = self.engine(
            "--max-tokens", "24",
            "--timeout", "2",
            "--max-witnesses", "100000",
            AMBIGUITY_PROGRESS_SECONDS="0",
        )
        self.assertNotIn("●", result.stderr)

    def cadence(self, value: str) -> subprocess.CompletedProcess[str]:
        return self.engine(
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
        # That handler clears the progress line first, so it must not read the
        # setting a second time.
        self.assertNotIn("Fatal error", result.stderr)

    def test_a_non_finite_cadence_is_refused_rather_than_obeyed(self) -> None:
        # These parse as floats, and taken for a setting each would show no
        # progress at all: every comparison against nan is false, and nothing
        # is ever as old as infinity. Neither is a cadence anyone asked for,
        # so both are refused like any other bad setting.
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
