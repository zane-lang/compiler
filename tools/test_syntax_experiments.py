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

    def test_grouping_variants_are_mutually_distinct(self) -> None:
        bracket = experiments.bracket_grouping(self.source)
        keyword = experiments.keyword_grouping(self.source)
        none = experiments.no_grouping(self.source)
        self.assertIn('| "[" e=expr "]"', bracket)
        self.assertIn('| GROUP "(" e=expr ")"', keyword)
        self.assertNotIn("Nodes.Expr.Parenthized", none)


if __name__ == "__main__":
    unittest.main()
