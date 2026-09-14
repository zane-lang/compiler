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

    def test_dot_constructor_has_one_constructor_reading(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT DOT LIDENT LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort Vector2.zeros(); }",
            "named_ctor",
        )

    def test_spawn_takes_the_outer_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "SPAWN FALSE LPAREN RPAREN LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort spawn false()(); }",
            "spawn(call(call(bool)))",
        )

    def test_parentheses_allow_calling_what_a_spawn_produces(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LPAREN "
            "SPAWN FALSE LPAREN RPAREN RPAREN LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort (spawn false())(); }",
            "call(paren(spawn(call(bool))))",
        )

    def test_leading_reference_binds_the_lambda_return_type(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "AMPERSAND UIDENT LPAREN RPAREN THICK_ARROW FALSE SEMICOLON RCURLY EOF",
            "Int length() { abort &Int () => false; }",
            "lambda(bool)",
        )

    def test_parentheses_allow_referencing_the_lambda(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT AMPERSAND LPAREN "
            "UIDENT LPAREN RPAREN THICK_ARROW FALSE RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort &(Int () => false); }",
            "ref(paren(lambda(bool)))",
        )

    def test_a_trailing_block_joins_the_outer_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN FALSE LPAREN RPAREN RPAREN LCURLY RCURLY "
            "RCURLY EOF",
            "Int length() { abort value(false()) { } }",
            "call(name, call(bool), block)",
        )

    def test_both_spellings_of_a_block_argument_are_arguments(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN LCURLY ABORT FALSE SEMICOLON RCURLY RPAREN "
            "LCURLY RCURLY RCURLY EOF",
            "Int length() { abort value({ abort false; }) { } }",
            "call(name, block, block)",
        )

    def test_a_trailing_block_reaches_a_method_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN RPAREN COLON LIDENT LPAREN RPAREN LCURLY RCURLY "
            "RCURLY EOF",
            "Int length() { abort value():length() { } }",
            "meth(call(name), name, block)",
        )

    def test_a_match_keeps_the_brace_that_holds_its_arms(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "MATCH LIDENT LPAREN RPAREN LCURLY RCURLY RCURLY EOF",
            "Int length() { abort match value() { } }",
            "match(call(name))",
        )

    def test_a_scrutinee_takes_a_block_only_when_the_arms_still_have_one(
        self,
    ) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "MATCH LIDENT LPAREN RPAREN LCURLY RCURLY LCURLY RCURLY "
            "RCURLY EOF",
            "Int length() { abort match value() { } { } }",
            "match(call(name, block))",
        )

    def test_a_brace_argument_is_told_from_a_block_by_its_first_mark(
        self,
    ) -> None:
        # `,` after the first expression opens a map entry's value; `;` ends a
        # statement. The two never compete for the same text.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN LCURLY LIDENT COMMA FALSE SEMICOLON RCURLY RPAREN "
            "SEMICOLON RCURLY EOF",
            "Int length() { abort value({ first, false; }); }",
            "call(name, map(name, bool))",
        )
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN LCURLY ABORT FALSE SEMICOLON RCURLY RPAREN "
            "SEMICOLON RCURLY EOF",
            "Int length() { abort value({ abort false; }); }",
            "call(name, block)",
        )

    def test_a_map_literal_may_trail_a_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN RPAREN LCURLY LIDENT COMMA FALSE SEMICOLON RCURLY "
            "RCURLY EOF",
            "Int length() { abort value() { first, false; } }",
            "call(name, map(name, bool))",
        )

    def test_bare_type_member_has_one_value_reading(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Colors.red; }",
            "type_member",
        )


if __name__ == "__main__":
    unittest.main()
