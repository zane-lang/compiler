"""Modular delimiter histories are conservative at every nesting depth."""

from tests.ambiguity.prover import fixtures, harness


class DelimiterHistoryTests(harness.ProverTestCase):
    def test_nested_real_ambiguities_survive_every_modulus(self) -> None:
        grammar = """\
%token LPAREN RPAREN LBRACKET RBRACKET LCURLY RCURLY A EOF
%start <unit> main
%%
main: p EOF { () }
p: LPAREN p RPAREN { () } | LBRACKET p RBRACKET { () }
 | LCURLY p RCURLY { () } | x { () } | y { () }
x: A { () }
y: A { () }
"""
        for modulus in (1, 2, 3, 4, 8):
            for extra in ((), ("--prove-balanced",)):
                with self.subTest(modulus=modulus, extra=extra):
                    status, output = self.prove(
                        grammar, 2, extra=extra,
                        environment={**self.environment,
                                     "AMBIGUITY_DELIMITER_MODULUS": str(modulus)},
                    )
                    self.assertEqual(status, harness.AMBIGUOUS, output)
                    self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_history_exclusion_composes_with_modular_counts(self) -> None:
        status, output = self.prove(
            fixtures.CEGAR_AM_AO_PERMUTATIONS, 1,
            environment={**self.environment, "AMBIGUITY_DELIMITER_MODULUS": "2"},
            extra=("--prove-cegar", "1", "--prove-refine", "4"),
        )
        self.assertEqual(status, harness.AMBIGUOUS, output)

    def test_unbalanced_production_fails_closed(self) -> None:
        status, output = self.prove(
            "%token LPAREN EOF\n%start <unit> main\n%%\nmain: LPAREN EOF { () }\n",
            1, expect_verdict=False,
            environment={**self.environment, "AMBIGUITY_DELIMITER_MODULUS": "2"},
        )
        self.assertEqual(status, 2, output)
        self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_invalid_modulus_fails_closed(self) -> None:
        for modulus in ("0", "9", "garbage"):
            with self.subTest(modulus=modulus):
                status, output = self.prove(
                    fixtures.LR1_LIST, 1, expect_verdict=False,
                    environment={**self.environment, "AMBIGUITY_DELIMITER_MODULUS": modulus},
                )
                self.assertEqual(status, 2, output)
                self.assertNotRegex(output, harness.PROVEN_LINE)
