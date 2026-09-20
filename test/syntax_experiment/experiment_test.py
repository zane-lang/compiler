#!/usr/bin/env python3
import unittest
from pathlib import Path

from tools.syntax_experiment import cli as experiments

ROOT = Path(__file__).resolve().parents[2]
GRAMMAR = ROOT / "lib" / "cst" / "parser.mly"


class SyntaxExperimentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = GRAMMAR.read_text(encoding="utf-8")

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


class SearchReportParsingTests(unittest.TestCase):
    """The report contract, read the way `metric` will read it."""

    EXHAUSTED = (
        "Search ended at depth 8 because the search space within the token "
        "bound was exhausted; no complete ambiguity was found in 25842 "
        "explored frontiers (25937 unique).\n"
        "This is a bounded result, not a proof of unambiguity.\n"
    )
    CURTAILED = (
        "Search ended at depth 13 because one or more workers reached a "
        "search limit; no complete ambiguity was found in 24029962 explored "
        "frontiers (31925217 unique).\n"
    )

    def test_an_exhausted_bound_is_not_recorded_as_stopped(self) -> None:
        # `stopped` means "a limit intervened" to metric() and the summary
        # table, so the reason for a completed bound has to come back as None
        # even though the engine now always prints one.
        result = experiments.parse_search_output(self.EXHAUSTED, 1.0)
        self.assertIsNone(result.error)
        self.assertIsNone(result.stopped)
        self.assertEqual(result.deepest, 8)
        self.assertEqual(result.families, 0)
        self.assertEqual(result.explored, 25842)

    def test_a_curtailed_search_keeps_its_reason(self) -> None:
        result = experiments.parse_search_output(self.CURTAILED, 1.0)
        self.assertIsNone(result.error)
        self.assertEqual(result.stopped, "one or more workers reached a search limit")
        self.assertEqual(result.deepest, 13)

    def test_a_missing_termination_line_is_an_error(self) -> None:
        # The failure that has to stay closed: without the line there is no
        # evidence the bound completed, and a None reason would be read as a
        # confidently clean result -- the one conclusion the output cannot
        # support.
        result = experiments.parse_search_output(
            "No complete ambiguity satisfying the search constraints was "
            "found after exploring 25842 frontiers (25937 unique).\n",
            1.0,
        )
        self.assertIsNotNone(result.error)
        self.assertIsNone(result.families)
        self.assertIsNone(result.stopped)


if __name__ == "__main__":
    unittest.main()
