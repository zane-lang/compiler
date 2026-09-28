#!/usr/bin/env python3
"""Tests of the OCaml engine itself, run on small grammars: terminal
classes, the minimum token bound and the partition budget."""

import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tests.ambiguity.engine_support import ENGINE, TINY_GRAMMAR, engine_environment


# The short derivation accepts at A EOF; a longer accepted derivation needs
# that prefix to remain expandable until the requested four-token boundary.
MIN_TOKENS_GRAMMAR = """\
%token A "a"
%token X "x"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | e EOF { () }
  | e EOF X EOF { () }
e:
  | A { () }
  | A { () }
"""


class TerminalClassEngineTests(unittest.TestCase):
    """End-to-end checks that the search collapses interchangeable terminals
    without losing an ambiguity reachable only through a non-representative
    member. Skipped when the engine binary or menhir is unavailable, so the
    otherwise pure-Python suite still runs without the OCaml toolchain."""

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

    def engine(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        # --timeout only bounds the engine's own search; a process-level timeout
        # keeps a hung binary or menhir from blocking the whole suite.
        return subprocess.run(
            [str(ENGINE), *arguments, str(self.grammar)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=120,
        )

    def test_interchangeable_atoms_share_one_class(self) -> None:
        result = self.engine("--dump-terminal-classes")
        self.assertIn("{ A B }", result.stdout)

    def test_ambiguity_holds_through_a_non_representative_member(self) -> None:
        # B is not the class representative (A sorts first), so the search never
        # shifts it directly; the all-B sentence must still be recognized as
        # ambiguous, confirming the representative stands in for the whole class.
        result = self.engine("--check-tokens", "B PLUS B PLUS B EOF")
        self.assertIn("Accepting derivations: 2", result.stdout)
        self.assertEqual(result.returncode, 0)

    def test_prove_finds_the_ambiguity_via_the_representative(self) -> None:
        # prove drives the abstract BFS over class representatives, then
        # concretizes; it must surface the e-PLUS-e ambiguity even though every
        # witness is spelled with the representative atom.
        result = self.engine(
            "--prove", "2",
            "--max-tokens", "8",
            "--timeout", "30",
            "--max-witnesses", "5",
        )
        # TINY_GRAMMAR is ambiguous, so proof mode settles on the ambiguous
        # verdict and reports it in its status.
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertTrue(
            "complete ambiguity" in result.stdout
            or "AMBIGUOUS: the recognizer found two derivations" in result.stdout,
            result.stdout,
        )
        # The witness must be spelled with the class representative A, never the
        # non-representative B, confirming concretization stays on representatives.
        witnesses = [
            line for line in result.stdout.splitlines() if "Tokens (" in line
        ]
        if witnesses:
            tokens = witnesses[0].split(":", 1)[1].split()
            self.assertIn("A", tokens)
            self.assertNotIn("B", tokens)
        else:
            self.assertIn(
                "AMBIGUOUS: the recognizer found two derivations of A PLUS A PLUS A EOF",
                result.stdout,
            )


class MinTokenEngineTests(unittest.TestCase):
    """Accepted prefixes below --min-tokens must stay expandable and bounded."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/engine/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "min_tokens.mly"
        self.grammar.write_text(MIN_TOKENS_GRAMMAR, encoding="utf-8")

    def test_expands_an_accepted_prefix_to_the_requested_boundary(self) -> None:
        for jobs in (1, 2):
            with self.subTest(jobs=jobs):
                result = subprocess.run(
                    [
                        str(ENGINE),
                        "--min-tokens", "4",
                        "--max-tokens", "4",
                        "--timeout", "30",
                        "--max-witnesses", "1",
                        str(self.grammar),
                    ],
                    env={**self.environment, "AMBIGUITY_JOBS": str(jobs)},
                    text=True,
                    capture_output=True,
                    timeout=120,
                )
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("Found 1 complete ambiguity family.", result.stdout)
                self.assertIn("Tokens (4): A EOF X EOF", result.stdout)


class PartitionBudgetEngineTests(unittest.TestCase):
    """A stopped prepass must leave complete coverage to the workers."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/engine/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "branching_min_tokens.mly"
        count = 300
        tokens = "\n".join(
            f'%token X{index} "x{index}"\n%token Y{index} "y{index}"'
            for index in range(count)
        )
        continuations = "\n".join(
            f"  | e EOF X{index} Y{index} Z EOF {{ () }}"
            for index in range(count)
        )
        # The only ambiguity is in the final branch, beyond the prepass
        # frontier cap. Retaining only its partial [next] level misses it.
        continuations += "\n  | e EOF X299 Y299 Z EOF { () }"
        self.grammar.write_text(
            f"""%token A "a"
%token Z "z"
%token EOF "<eof>"
{tokens}
%start <unit> main
%%
main:
  | e EOF {{ () }}
{continuations}
e:
  | A {{ () }}
""",
            encoding="utf-8",
        )

    def test_frontier_budget_stop_preserves_late_unique_witness(self) -> None:
        result = subprocess.run(
            [
                str(ENGINE),
                "--min-tokens", "6",
                "--max-tokens", "6",
                "--timeout", "30",
                "--max-witnesses", "1",
                str(self.grammar),
            ],
            env={
                **self.environment,
                "AMBIGUITY_JOBS": "4",
                "AMBIGUITY_MEMORY_MB": "512",
                "AMBIGUITY_MAX_FRONTIER_RATIO": "0.001",
            },
            text=True,
            capture_output=True,
            timeout=120,
        )
        self.assertIn("Found 1 complete ambiguity family.", result.stdout)
        self.assertIn("Tokens (6): A EOF X299 Y299 Z EOF", result.stdout)
        self.assertIn("the witness limit was reached", result.stdout)
        self.assertNotIn(
            "the frontier budget stopped initial partitioning", result.stdout
        )


if __name__ == "__main__":
    unittest.main()
