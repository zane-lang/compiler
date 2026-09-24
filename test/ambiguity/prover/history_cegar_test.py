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
        # Other-history subsumption is directional: an already-seen Other
        # pair may cover a trie-prefix pair, but the blocked prefix must never
        # erase the Other pair that carries this reverse-order witness.
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

    def test_a_rejected_candidate_is_filtered_only_after_exact_replay(self) -> None:
        # This grammar's top-1 abstraction invents a short path outside the
        # recognizer's language. CEGAR may exclude it only after the exact
        # replay classifies the candidate as zero-parse. The candidate repeats
        # one terminal class, so the report must include its full substitution
        # product before excluding the history.
        _, output = self.prove(
            fixtures.ACCEPTS_NON_SENTENCES,
            1,
            max_tokens="0",
            extra=("--prove-cegar", "1"),
        )
        self.assertRegex(output, re.compile(r"^CEGAR refinement 1:", re.MULTILINE))
        self.assertRegex(output, re.compile(r"representative has 0 parse\(s\)"))
        self.assertRegex(
            output,
            re.compile(
                r"representative has 0 parse\(s\), and all \d+ concrete "
                r"terminal-class substitution\(s\) were checked"
            ),
        )

    def test_incomplete_exact_check_falls_through_to_stack_refinement(self) -> None:
        status, output = self.prove(
            fixtures.CEGAR_INCOMPLETE_EXCLUSION,
            1,
            max_tokens="0",
            extra=("--prove-cegar", "1", "--prove-refine", "4"),
        )
        self.assertRegex(
            output,
            re.compile(
                r"^CEGAR check skipped: the candidate represents more than "
                r"4096 concrete terminal sequence\(s\); continuing with stack "
                r"refinement for this candidate\.$",
                re.MULTILINE,
            ),
        )
        self.assertRegex(output, re.compile(r"^Refinement round 1:", re.MULTILINE))
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

    def test_blocked_acceptance_keeps_its_longer_shared_prefix(self) -> None:
        short = "AM AO A LB RB SEMI EOF"
        longer = "AM AO A LB RB SEMI EOF B X EOF"
        self.assertIn(
            "Accepting derivations: 1",
            self.check_tokens(fixtures.CEGAR_LONGER_SHARED_PREFIX, short),
        )
        self.assertIn(
            "Accepting derivations: 2",
            self.check_tokens(fixtures.CEGAR_LONGER_SHARED_PREFIX, longer),
        )
        status, output = self.prove(
            fixtures.CEGAR_LONGER_SHARED_PREFIX,
            1,
            max_tokens="0",
            extra=("--prove-cegar", "1"),
        )
        self.assertIn(f"complete history {short}", output)
        self.assertRegex(output, re.compile(r"^AMBIGUOUS:", re.MULTILINE))
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
