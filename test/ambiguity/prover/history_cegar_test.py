"""Sentence-history CEGAR must preserve every path it has not excluded."""

import re
import subprocess
import unittest

from test.ambiguity.prover import fixtures, harness


class HistoryCegarTests(harness.ProverTestCase):
    def check_tokens(self, grammar: str, tokens: str) -> str:
        path = self.directory / "grammar.mly"
        path.write_text(grammar, encoding="utf-8")
        result = subprocess.run(
            [str(harness.ENGINE), "--check-tokens", tokens, str(path)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=180,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_blocking_first_AM_AO_history_preserves_ambiguous_permutation(self) -> None:
        # The first history has one parse and the reverse ordering has two.
        # A sentence-only block keyed by merged parser states used to erase the
        # second history and falsely report PROVEN after filtering the first.
        self.assertIn(
            "Accepting derivations: 1",
            self.check_tokens(
                fixtures.CEGAR_AM_AO_PERMUTATIONS,
                "AM AO A LB RB SEMI EOF",
            ),
        )
        self.assertIn(
            "Accepting derivations: 2",
            self.check_tokens(
                fixtures.CEGAR_AM_AO_PERMUTATIONS,
                "AO AM A LB RB SEMI EOF",
            ),
        )
        status, output = self.prove(
            fixtures.CEGAR_AM_AO_PERMUTATIONS,
            1,
            max_tokens="0",
            extra=("--prove-cegar", "1"),
        )
        self.assertRegex(output, re.compile(r"^CEGAR refinement 1:", re.MULTILINE))
        self.assertRegex(output, re.compile(r"^AMBIGUOUS:", re.MULTILINE))
        self.assertNotRegex(output, harness.PROVEN_LINE)
        self.assertEqual(status, harness.AMBIGUOUS, output)

    def test_single_parse_and_rejected_candidates_need_exact_replay(self) -> None:
        # This grammar produces a one-parse abstraction candidate before a
        # later rejected candidate. CEGAR may exclude either only after exact
        # replay; neither verdict is enough by itself to prove the grammar.
        status, output = self.prove(
            fixtures.ACCEPTS_NON_SENTENCES,
            1,
            max_tokens="0",
            extra=("--prove-cegar", "2"),
        )
        self.assertRegex(output, re.compile(r"^CEGAR refinement 1:", re.MULTILINE))
        self.assertRegex(output, re.compile(r"^CEGAR refinement 2:", re.MULTILINE))
        for round_number, count in ((1, 1), (2, 0)):
            self.assertRegex(
                output,
                re.compile(
                    rf"^CEGAR refinement {round_number}: excluded complete history .+; "
                    rf"the representative has {count} parse\(s\), and all \d+ "
                    r"concrete terminal-class substitution\(s\) were checked",
                    re.MULTILINE,
                ),
            )
        self.assertNotEqual(status, harness.AMBIGUOUS, output)
        self.assertIn(status, (harness.PROVEN, harness.NOT_PROVEN), output)

    def test_CEGAR_reaches_a_second_independent_candidate(self) -> None:
        # L/p and R/q are independent blind spots. Excluding the first exact
        # nonambiguous sentence must not merge its history with the second
        # site's prefix or let one exclusion stand for the rest of the graph.
        status, output = self.prove(
            fixtures.TWO_INDEPENDENT_SITES,
            1,
            max_tokens="0",
            extra=("--prove-cegar", "2"),
        )
        self.assertEqual(
            len(re.findall(r"^CEGAR refinement \d+:", output, re.MULTILINE)), 2,
            output,
        )
        self.assertNotRegex(output, harness.PROVEN_LINE)
        self.assertEqual(status, harness.NOT_PROVEN, output)

    def test_exact_exclusion_does_not_hide_a_later_ambiguity(self) -> None:
        rejected = "AM AO A SEMI EOF B X EOF"
        ambiguous = "AO AM A SEMI EOF B X EOF"
        self.assertIn(
            "Accepting derivations: 0",
            self.check_tokens(fixtures.CEGAR_LONGER_SHARED_PREFIX, rejected),
        )
        self.assertIn(
            "Accepting derivations: 2",
            self.check_tokens(fixtures.CEGAR_LONGER_SHARED_PREFIX, ambiguous),
        )
        status, output = self.prove(
            fixtures.CEGAR_LONGER_SHARED_PREFIX,
            1,
            max_tokens="0",
            extra=("--prove-cegar", "1"),
        )
        self.assertRegex(
            output,
            re.compile(
                r"^CEGAR refinement 1: excluded complete history .+; "
                r"the representative has 0 parse\(s\), and all \d+ "
                r"concrete terminal-class substitution\(s\) were checked",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            output,
            re.compile(rf"^AMBIGUOUS:.*{re.escape(ambiguous)}", re.MULTILINE),
        )
        self.assertEqual(status, harness.AMBIGUOUS, output)

    def test_CEGAR_never_excludes_duplicate_production_ambiguity(self) -> None:
        for name, grammar in (
            ("duplicate production", fixtures.DUPLICATE_PRODUCTION),
            (
                "duplicate nonrepresentative terminal",
                fixtures.DUPLICATE_NONREPRESENTATIVE_TERMINAL,
            ),
            ("nullable EOF reduction", fixtures.NULLABLE_REDUCE_REDUCE),
        ):
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar,
                    1,
                    extra=("--prove-cegar", "2"),
                )
                self.assertEqual(status, harness.AMBIGUOUS, output)
                self.assertRegex(
                    output,
                    re.compile(r"^AMBIGUOUS: the recognizer found two derivations", re.MULTILINE),
                )
                self.assertNotRegex(output, harness.PROVEN_LINE)


if __name__ == "__main__":
    unittest.main()
