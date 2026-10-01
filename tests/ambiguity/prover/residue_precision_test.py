"""A smaller viable-stack fingerprint changes precision, never soundness."""

from tests.ambiguity.prover import fixtures, harness


class ResiduePrecisionTests(harness.ProverTestCase):
    def test_all_fingerprint_widths_preserve_known_ambiguities(self) -> None:
        for bits in (0, 1, 2, 4, 10):
            for name, grammar in fixtures.AMBIGUOUS_GRAMMARS.items():
                with self.subTest(bits=bits, grammar=name):
                    status, output = self.prove(
                        grammar, 2,
                        environment={**self.environment, "AMBIGUITY_RESIDUE_BITS": str(bits)},
                    )
                    self.assertEqual(status, harness.AMBIGUOUS, output)
                    self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_conflict_free_grammar_proves_without_a_fingerprint(self) -> None:
        status, output = self.prove(
            fixtures.LR1_LIST, 1,
            environment={**self.environment, "AMBIGUITY_RESIDUE_BITS": "0"},
        )
        self.assertEqual(status, harness.PROVEN, output)

    def test_invalid_fingerprint_width_fails_closed(self) -> None:
        for bits in ("-1", "11", "garbage"):
            with self.subTest(bits=bits):
                status, output = self.prove(
                    fixtures.LR1_LIST, 1, expect_verdict=False,
                    environment={**self.environment, "AMBIGUITY_RESIDUE_BITS": bits},
                )
                self.assertEqual(status, 2, output)
                self.assertNotRegex(output, harness.PROVEN_LINE)
