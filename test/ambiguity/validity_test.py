#!/usr/bin/env python3
"""The validity model, measured against the rule it stands in for.

`Statement_check` decides whether a statement is spelled the way its own shape
calls for, and it does that after the parse, over the tree that survived. The
recognizer cannot wait that long: the question it is asked is how many
*derivations* survive, not whether one did, so the rule is applied at the
reduction that completes a statement instead. These tests pin the two claims
that makes: the model refuses exactly what `Statement_check` rejects, and it is
inert on every grammar that is not Zane's.

Only the engine binary is needed, not the compiler, so these run wherever the
ambiguity suites do.
"""

import os
import shutil
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity" / "ambiguity_search.exe"
GRAMMAR = ROOT / "lib" / "cst" / "parser.mly"

# Nothing to do with Zane: no `stat`, no `;`, no `}`. The model has to leave it
# alone, which is what keeps the soundness corpus measuring the grammars it is
# about rather than a filter.
UNRELATED_GRAMMAR = """\
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


def engine_environment() -> dict[str, str] | None:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not ENGINE.exists() or menhir is None:
        return None
    return {
        **os.environ,
        "AMBIGUITY_MENHIR": menhir,
        "AMBIGUITY_MEMORY_MB": "512",
        "AMBIGUITY_MAX_FRONTIER_RATIO": "1.0",
        "AMBIGUITY_JOBS": "1",
    }


class ValidityModelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest("requires a built ambiguity_search executable and menhir")

    def check(self, tokens: str, *flags: str, grammar: Path | None = None):
        return subprocess.run(
            [str(ENGINE), *flags, "--check-tokens", tokens,
             str(grammar or GRAMMAR)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=120,
        )

    def derivations(self, tokens: str, *flags: str) -> int:
        result = self.check(tokens, *flags)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reported = [
            line.strip()
            for line in result.stdout.splitlines()
            if line.startswith("Accepting derivations:")
        ]
        self.assertEqual(len(reported), 1, result.stdout)
        return int(reported[0].split(":")[1])

    def assert_counts(self, tokens: str, source: str, model: int, raw: int) -> None:
        """How many derivations are programs, and how many the grammar admits."""
        self.assertEqual(self.derivations(tokens), model, f"{source} (model)")
        self.assertEqual(
            self.derivations(tokens, "--raw-derivations"), raw, f"{source} (raw)"
        )

    def test_two_derivations_that_are_both_unterminated_are_not_an_ambiguity(
        self,
    ) -> None:
        # The witness from the scheduled proof run that reported an ambiguous
        # grammar (issue #100). The raw grammar derives it twice -- as
        # `abort ((false[])())`, and as `abort false` followed by `([])()` --
        # and neither reading is a program, because every statement in each
        # ends without the `;` its shape calls for. Two readings that are not
        # programs are not an ambiguity of Zane.
        self.assert_counts(
            "UIDENT LCURLY RCURLY LCURLY ABORT FALSE LBRACKET RBRACKET "
            "LPAREN RPAREN RCURLY EOF",
            "Int {} { abort false[]() }",
            model=0,
            raw=2,
        )

    def test_one_surviving_reading_of_two_is_not_an_ambiguity_either(self) -> None:
        # The same sentence with its terminator written. The raw grammar still
        # derives it twice -- as one `abort` statement, and as an unterminated
        # `abort false` followed by `[]();` -- but only the first is a program,
        # and one reading is not an ambiguity. This is the half of the rule a
        # filter that only dropped all-invalid witnesses would miss.
        self.assert_counts(
            "UIDENT LCURLY RCURLY LCURLY ABORT FALSE LBRACKET RBRACKET "
            "LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int {} { abort false[](); }",
            model=1,
            raw=2,
        )

    def test_a_statement_not_ending_in_a_brace_needs_its_terminator(self) -> None:
        self.assert_counts(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT FALSE RCURLY EOF",
            "Unit f() { abort false }",
            model=0,
            raw=1,
        )
        self.assert_counts(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT FALSE SEMICOLON RCURLY EOF",
            "Unit f() { abort false; }",
            model=1,
            raw=1,
        )

    def test_a_statement_ending_in_a_brace_takes_no_terminator(self) -> None:
        self.assert_counts(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT LPAREN RPAREN "
            "LCURLY RCURLY SEMICOLON RCURLY EOF",
            "Unit f() { abort value() { }; }",
            model=0,
            raw=1,
        )
        self.assert_counts(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT LPAREN RPAREN "
            "LCURLY RCURLY RCURLY EOF",
            "Unit f() { abort value() { } }",
            model=1,
            raw=1,
        )

    def test_the_terminator_the_grammar_requires_is_left_alone(self) -> None:
        # `import` ends on a bare name and the grammar requires its `;`, so the
        # statement carries no defect for the model to read. It still has to
        # pass: a predicate that asked for a closing brace here would reject a
        # program.
        self.assert_counts(
            "UIDENT LIDENT LPAREN RPAREN LCURLY IMPORT LIDENT DOLLAR SEMICOLON "
            "RCURLY EOF",
            "Unit f() { import core$; }",
            model=1,
            raw=1,
        )

    def test_the_model_says_which_count_it_is_giving(self) -> None:
        applied = self.check("UIDENT EOF")
        self.assertIn("Validity model: statement terminators", applied.stdout)
        raw = self.check("UIDENT EOF", "--raw-derivations")
        self.assertIn("Validity model: none", raw.stdout)

    def test_a_grammar_that_is_not_zane_keeps_its_raw_count(self) -> None:
        with TemporaryDirectory() as directory:
            grammar = Path(directory) / "unrelated.mly"
            grammar.write_text(UNRELATED_GRAMMAR, encoding="utf-8")
            result = self.check("A PLUS A PLUS A EOF", grammar=grammar)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Validity model: none", result.stdout)
            # Genuinely ambiguous, and it has to stay that way: the model must
            # not silently remove a grammar's real ambiguity.
            self.assertIn("Accepting derivations: 2", result.stdout)


if __name__ == "__main__":
    unittest.main()
