#!/usr/bin/env python3
import unittest
from pathlib import Path

from tools import syntax_experiments as experiments


class SyntaxExperimentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = Path("lib/cst/parser.mly").read_text(encoding="utf-8")

    def test_every_predefined_variant_applies(self) -> None:
        names = set()
        for variant in experiments.VARIANTS:
            self.assertNotIn(variant.name, names)
            names.add(variant.name)
            grammar = experiments.apply_variant(self.source, variant)
            self.assertIn(f"Variant: {variant.name}", grammar)

    def test_semicolon_variants_replace_every_statement_list(self) -> None:
        for transform in (
            experiments.semicolon_separated,
            experiments.semicolon_terminated,
        ):
            grammar = transform(self.source)
            self.assertNotIn("decls=list(decl)", grammar)
            self.assertNotIn("list(stat)", grammar)
            self.assertIn("decls=decl_sequence", grammar)
            self.assertIn("statements=stat_sequence", grammar)

    def test_named_statement_variant_keeps_computed_calls_in_expressions(self) -> None:
        grammar = experiments.named_statement_calls(self.source)
        self.assertIn("verb_call:\n  | receiver=app", grammar)
        self.assertIn("verb_call=statement_verb_call", grammar)
        self.assertNotIn(experiments.STAT_CALL, grammar)

    def test_anchored_abort_handles_leave_no_expression_slots(self) -> None:
        grammar = experiments.anchored_abort_handles(self.source)
        self.assertNotIn("abort_handle=ioption(abort_handle) %prec", grammar)
        self.assertIn("handled_expr:", grammar)
        self.assertIn(
            "| verb_call=verb_call abort_handle=ioption(abort_handle) {", grammar
        )
        self.assertIn('value=handled_expr', grammar)
        self.assertIn('"(" e=handled_expr ")"', grammar)
        self.assertEqual(grammar.count("separated_list(COMMA, handled_expr)"), 3)

    def test_grouping_variants_are_mutually_distinct(self) -> None:
        bracket = experiments.bracket_grouping(self.source)
        keyword = experiments.keyword_grouping(self.source)
        none = experiments.no_grouping(self.source)
        self.assertIn('| "[" e=expr "]"', bracket)
        self.assertIn('| GROUP "(" e=expr ")"', keyword)
        self.assertNotIn("Nodes.Expr.Parenthized", none)


class WitnessSpellingTests(unittest.TestCase):
    @staticmethod
    def variant(name: str) -> experiments.Variant:
        return next(v for v in experiments.VARIANTS if v.name == name)

    @staticmethod
    def tokens(case_name: str, variant_name: str) -> str | None:
        case = next(c for c in experiments.KNOWN_CASES if c.name == case_name)
        return experiments.case_tokens(
            case, WitnessSpellingTests.variant(variant_name)
        )

    def test_every_transform_has_a_spelling_update(self) -> None:
        self.assertEqual(
            set(experiments.TRANSFORMS), set(experiments.SPELLINGS)
        )

    def test_baseline_spelling_reproduces_original_witnesses(self) -> None:
        expected = {
            "nullable-array-binding": "ALIAS UIDENT EQUAL UIDENT QSTNMARK UIDENT "
            "LBRACKET RBRACKET LBRACKET RBRACKET EOF",
            "adjacent-computed-call": "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN "
            "RPAREN LPAREN LIDENT RPAREN LPAREN RPAREN RCURLY EOF",
            "abort-handler-attachment": "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN "
            "TILDE TILDE LIDENT QSTNQSTN LIDENT RPAREN RCURLY EOF",
            "named-call-statement": "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN "
            "STRING RPAREN RCURLY EOF",
        }
        for name, tokens in expected.items():
            self.assertEqual(self.tokens(name, "baseline"), tokens)

    def test_bracket_calls_spell_print_hello_with_brackets(self) -> None:
        self.assertEqual(
            self.tokens("named-call-statement", "bracket-calls"),
            "UIDENT LPAREN RPAREN LCURLY LIDENT LBRACKET STRING RBRACKET RCURLY EOF",
        )

    def test_semicolon_terminated_terminates_statements_and_decls(self) -> None:
        self.assertEqual(
            self.tokens("named-call-statement", "semicolon-terminated"),
            "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN STRING RPAREN SEMICOLON "
            "RCURLY SEMICOLON EOF",
        )
        self.assertEqual(
            self.tokens("nullable-array-binding", "semicolon-terminated"),
            "ALIAS UIDENT EQUAL UIDENT QSTNMARK UIDENT LBRACKET RBRACKET "
            "LBRACKET RBRACKET SEMICOLON EOF",
        )

    def test_semicolon_separated_splits_the_two_statement_reading(self) -> None:
        self.assertEqual(
            self.tokens("adjacent-computed-call", "semicolon-separated"),
            "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN SEMICOLON "
            "LPAREN LIDENT RPAREN LPAREN RPAREN RCURLY EOF",
        )

    def test_computed_call_statements_can_be_inexpressible(self) -> None:
        self.assertIsNone(self.tokens("adjacent-computed-call", "named-statement-calls"))
        self.assertIsNone(self.tokens("adjacent-computed-call", "no-grouping"))

    def test_marked_computed_calls_keep_named_calls_plain(self) -> None:
        self.assertEqual(
            self.tokens("named-call-statement", "marked-computed-calls"),
            "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN STRING RPAREN RCURLY EOF",
        )
        self.assertEqual(
            self.tokens("adjacent-computed-call", "marked-computed-calls"),
            "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN "
            "LPAREN LIDENT RPAREN AT LPAREN RPAREN RCURLY EOF",
        )

    def test_transform_spellings_compose(self) -> None:
        self.assertEqual(
            self.tokens(
                "adjacent-computed-call", "bracket-grouping-and-semicolons"
            ),
            "UIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN SEMICOLON "
            "LBRACKET LIDENT RBRACKET LPAREN RPAREN RCURLY EOF",
        )


if __name__ == "__main__":
    unittest.main()
