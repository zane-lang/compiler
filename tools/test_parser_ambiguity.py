#!/usr/bin/env python3
import os
import shutil
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity_search.exe"
GRAMMAR = ROOT / "lib" / "cst" / "parser.mly"


def engine_environment() -> dict[str, str] | None:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not ENGINE.exists() or menhir is None:
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
                "requires a built _build/default/tools/ambiguity_search.exe and menhir"
            )

    def check(self, tokens: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(ENGINE), "--check-tokens", tokens, str(GRAMMAR)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=120,
        )

    def assert_unambiguous(self, tokens: str) -> None:
        result = self.check(tokens)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Accepting derivations: 1", result.stdout)

    def test_shorthand_body_keeps_the_nearest_call(self) -> None:
        # `Int length() { abort Int ? Int() => false(); }` calls `false` inside
        # the lambda body. A bare lambda is not a postfix base, so the final `()`
        # cannot instead call the surrounding lambda.
        self.assert_unambiguous(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "FALSE LPAREN RPAREN SEMICOLON RCURLY EOF"
        )

    def test_parentheses_allow_calling_the_lambda(self) -> None:
        # `Int length() { abort (Int ? Int() => false)(); }` explicitly groups
        # the lambda, making the parenthesized expression a postfix base.
        self.assert_unambiguous(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LPAREN "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW FALSE "
            "RPAREN LPAREN RPAREN SEMICOLON RCURLY EOF"
        )


if __name__ == "__main__":
    unittest.main()
