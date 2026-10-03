"""Recursive delimiter summaries must preserve every real ambiguity."""

from tests.ambiguity.prover import fixtures, harness


class BalancedProofTests(harness.ProverTestCase):
    def test_generic_lambda_comparison_ambiguity_survives_balancing(self) -> None:
        # Reduced from the real Zane witness Foo<1>[]() {}. Both readings
        # are balanced; a delimiter filter must preserve their ambiguity.
        grammar = """\
%token LIDENT UIDENT EQUAL INT LESS MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY EOF
%left LESS MORE
%start <unit> main
%%
main: LIDENT UIDENT EQUAL expr EOF { () }
expr: UIDENT { () } | INT { () } | call { () }
 | ret_type LPAREN RPAREN LCURLY RCURLY { () }
 | expr LESS expr { () } | expr MORE expr { () }
ret_type: UIDENT LESS INT MORE LBRACKET RBRACKET { () }
call: LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY { () }
"""
        for extra in ((), ("--prove-balanced",)):
            with self.subTest(extra=extra):
                status, output = self.prove(grammar, 1, max_tokens="0", extra=extra)
                self.assertEqual(status, harness.AMBIGUOUS, output)
                self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_known_ambiguities_are_preserved(self) -> None:
        for name, grammar in fixtures.AMBIGUOUS_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar, 1, extra=("--prove-balanced",)
                )
                self.assertEqual(status, harness.AMBIGUOUS, output)
                self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_conflict_free_grammars_are_proven(self) -> None:
        for name, grammar in fixtures.CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar, 1, extra=("--prove-balanced",)
                )
                self.assertEqual(status, harness.PROVEN, output)

    def test_recursive_balanced_ambiguity_is_not_filtered(self) -> None:
        grammar = """\
%token LPAREN RPAREN LBRACKET RBRACKET LCURLY RCURLY A EOF
%start <unit> main
%%
main: p EOF { () }
p: LPAREN p RPAREN { () }
 | LBRACKET p RBRACKET { () }
 | LCURLY p RCURLY { () }
 | x { () } | y { () }
x: A { () }
y: A { () }
"""
        status, output = self.prove(
            grammar, 1, max_tokens="0", extra=("--prove-balanced",)
        )
        self.assertEqual(status, harness.AMBIGUOUS, output)

    def test_unbalanced_production_fails_closed(self) -> None:
        grammar = """\
%token LPAREN A EOF
%start <unit> main
%%
main: LPAREN A EOF { () } | LPAREN A EOF { () }
"""
        status, output = self.prove(
            grammar, 1, extra=("--prove-balanced",), expect_verdict=False
        )
        self.assertEqual(status, 2, output)
        self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_misnested_production_fails_closed(self) -> None:
        grammar = """\
%token LPAREN RPAREN LBRACKET RBRACKET EOF
%start <unit> main
%%
main: LPAREN LBRACKET RPAREN RBRACKET EOF { () }
"""
        status, output = self.prove(
            grammar, 1, extra=("--prove-balanced",), expect_verdict=False
        )
        self.assertEqual(status, 2, output)
        self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_balanced_refinement_and_exact_exclusion_keep_ambiguity(self) -> None:
        status, output = self.prove(
            fixtures.CEGAR_AM_AO_PERMUTATIONS,
            1,
            max_tokens="0",
            extra=("--prove-balanced", "--prove-cegar", "1", "--prove-refine", "4"),
        )
        self.assertEqual(status, harness.AMBIGUOUS, output)
        self.assertNotRegex(output, harness.PROVEN_LINE)
