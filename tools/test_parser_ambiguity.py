#!/usr/bin/env python3
import os
import shutil
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity_search.exe"
PARSER_SHAPE = ROOT / "_build" / "default" / "tools" / "parser_shape.exe"
GRAMMAR = ROOT / "lib" / "cst" / "parser.mly"


def engine_environment() -> dict[str, str] | None:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not ENGINE.exists() or not PARSER_SHAPE.exists() or menhir is None:
        return None
    return {
        **os.environ,
        "AMBIGUITY_MENHIR": menhir,
        "AMBIGUITY_MEMORY_MB": "64",
        "AMBIGUITY_MAX_FRONTIER_RATIO": "1.0",
        "AMBIGUITY_JOBS": "1",
    }


class ParserGrammarAmbiguityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires built ambiguity_search/parser_shape executables and menhir"
            )

    def check(self, tokens: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(ENGINE), "--check-tokens", tokens, str(GRAMMAR)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=120,
        )

    def assert_grouping(self, tokens: str, source: str, expected: str) -> None:
        result = self.check(tokens)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Accepting derivations: 1", result.stdout)

        parsed = subprocess.run(
            [str(PARSER_SHAPE), source],
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)
        self.assertEqual(parsed.stdout.strip(), expected)

    def test_shorthand_body_keeps_the_nearest_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "FALSE LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => false(); }",
            "lambda(call(bool))",
        )

    def test_parentheses_allow_calling_the_lambda(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LPAREN "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW FALSE "
            "RPAREN LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort (Int ? Int() => false)(); }",
            "call(paren(lambda(bool)))",
        )

    def test_shorthand_body_keeps_the_nearest_field_access(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "FALSE DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => false.length; }",
            "lambda(dot(bool))",
        )

    def test_parentheses_allow_field_access_on_the_lambda(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LPAREN "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW FALSE "
            "RPAREN DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort (Int ? Int() => false).length; }",
            "dot(paren(lambda(bool)))",
        )

    def test_mixed_postfix_chain_stays_in_the_lambda_body(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "LIDENT LPAREN RPAREN DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => value().field; }",
            "lambda(dot(call(name)))",
        )

    def test_prefix_wraps_the_mixed_postfix_chain(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "TILDE LIDENT LPAREN RPAREN DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => ~value().field; }",
            "lambda(flip(dot(call(name))))",
        )


if __name__ == "__main__":
    unittest.main()
