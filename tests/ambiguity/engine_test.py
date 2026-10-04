#!/usr/bin/env python3
"""Tests of the OCaml engine itself, run on small grammars: terminal
classes, how a search reports its end, duplicate reductions, the minimum token
bound and the partition budget."""

import re
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tests.ambiguity.engine_support import ENGINE, TINY_GRAMMAR, engine_environment


# Witnesses are announced by "Found N complete ambiguity families." The search
# says "no complete ambiguity was found" when there are none, so this has to be
# anchored: a bare "complete ambiguity" substring matches both.
WITNESS_LINE = re.compile(r"^Found \d+ complete ambiguity", re.MULTILINE)
# Every search reports how it ended, whether or not it found witnesses and
# whether or not a limit curtailed it.
TERMINATION_LINE = re.compile(r"^Search ended at depth \d+ because ", re.MULTILINE)

# Plainly LR(1): one action per state and lookahead.
LR1_LIST = """\
%token A "a"
%token EOF "<eof>"
%start <unit> main
%%
main: items EOF { () }
items:
  | { () }
  | items A { () }
"""

# Ambiguous: `a + a + a` groups two ways with nothing to choose between them.
AMBIGUOUS_EXPRESSION = """\
%token A "a"
%token PLUS "+"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | e PLUS e { () }
"""

# Menhir prints both alternatives as `e -> A`; they are still two reductions.
DUPLICATE_PRODUCTION = """\
%token A "a"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | A { () }
"""

# The duplicate reductions live on B, which is not its class's representative.
# If terminal equivalence discarded reduction multiplicity, A and B would merge
# and the search would only try A, missing the ambiguous sentence `B EOF`.
DUPLICATE_NONREPRESENTATIVE_TERMINAL = """\
%token A "a"
%token B "b"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | B { () }
  | B { () }
"""


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

    def test_search_finds_the_ambiguity_via_the_representative(self) -> None:
        # The search shifts class representatives only; it must still surface
        # the e-PLUS-e ambiguity, spelled with the representative atom.
        result = self.engine(
            "--max-tokens", "8",
            "--timeout", "30",
            "--max-witnesses", "5",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, WITNESS_LINE)
        witnesses = [
            line for line in result.stdout.splitlines() if "Tokens (" in line
        ]
        tokens = witnesses[0].split(":", 1)[1].split()
        self.assertIn("A", tokens)
        self.assertNotIn("B", tokens)


class EngineTestCase(unittest.TestCase):
    """Writes one grammar per test into a temporary directory and runs the
    engine on it."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/engine/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "grammar.mly"

    def engine(self, grammar: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        self.grammar.write_text(grammar, encoding="utf-8")
        return subprocess.run(
            [str(ENGINE), *arguments, str(self.grammar)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=180,
        )

    def search(
        self, grammar: str, *, max_tokens: str = "6", timeout: str = "30"
    ) -> str:
        result = self.engine(
            grammar,
            "--max-tokens", max_tokens,
            "--timeout", timeout,
            "--max-witnesses", "5",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout


class SearchTerminationTests(EngineTestCase):
    """Every search says how it ended, so silence is never the explanation."""

    def test_an_exhausted_bound_says_so(self) -> None:
        # The conclusive case: nothing of this length is ambiguous because
        # every sentence of this length was checked, not because the search
        # gave up.
        output = self.search(LR1_LIST)
        self.assertRegex(output, TERMINATION_LINE)
        self.assertIn("the search space within the token bound was exhausted", output)

    def test_a_curtailed_search_names_its_limit(self) -> None:
        # A deadline of zero stops the search before it can rule anything
        # out, and the report has to say which of the two happened.
        output = self.search(AMBIGUOUS_EXPRESSION, max_tokens="16", timeout="0")
        self.assertRegex(output, TERMINATION_LINE)
        self.assertIn("the timeout was reached", output)
        self.assertNotIn("the search space within the token bound was exhausted", output)

    def test_a_search_with_witnesses_also_reports_termination(self) -> None:
        # Witnesses do not excuse the run from saying how it ended: whether the
        # ones reported are all of them depends on the same distinction. A
        # search that finds witnesses is still a successful run, so it exits 0.
        output = self.search(AMBIGUOUS_EXPRESSION)
        self.assertRegex(output, WITNESS_LINE)
        self.assertRegex(output, TERMINATION_LINE)


class DuplicateReductionTests(EngineTestCase):
    """Two identical-looking alternatives are two derivations, including on a
    terminal that is not its class's representative."""

    CASES = (
        ("duplicate production text", DUPLICATE_PRODUCTION, "A EOF"),
        (
            "duplicate non-representative terminal",
            DUPLICATE_NONREPRESENTATIVE_TERMINAL,
            "B EOF",
        ),
    )

    def test_the_recognizer_counts_both_derivations(self) -> None:
        for name, grammar, tokens in self.CASES:
            with self.subTest(grammar=name):
                result = self.engine(grammar, "--check-tokens", tokens)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Accepting derivations: 2", result.stdout)

    def test_the_search_reports_the_ambiguity(self) -> None:
        for name, grammar, _ in self.CASES:
            with self.subTest(grammar=name):
                self.assertRegex(self.search(grammar), WITNESS_LINE)


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
