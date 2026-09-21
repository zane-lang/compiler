#!/usr/bin/env python3
"""The answer a run ends with, and the budgets that decide which one it can
give.

A proof is a verdict rather than a success: proven, a concrete ambiguous
sentence, or neither. These pin which status each outcome exits with, what
ends a bounded concretization search, and what happens when the pair budget
runs out before the abstract space does.
"""

import subprocess
import unittest

from test.ambiguity.prover import fixtures, harness

class ProofStatusTests(harness.ProverTestCase):
    """The status is the machine-readable verdict, so it must track the text."""

    def test_each_verdict_reports_its_documented_status(self) -> None:
        for grammar, expected, marker in (
            (fixtures.LR1_LIST, harness.PROVEN, harness.PROVEN_LINE),
            (fixtures.AMBIGUOUS_EXPRESSION, harness.AMBIGUOUS, harness.WITNESS_LINE),
        ):
            with self.subTest(status=expected):
                status, output = self.prove(grammar, 2)
                self.assertEqual(status, expected, output)
                self.assertRegex(output, marker)

    def test_an_exhausted_pair_budget_reports_not_proven(self) -> None:
        # The third status needs its own case. A conflict-free grammar proves
        # and an ambiguous one concretizes, so neither reaches it, and pinning
        # it to a grammar the abstraction merely cannot handle would make the
        # test a hostage to precision work. Starving the budget reaches it
        # from the other side: a ratio this small floors the pair limit at one,
        # so the search overflows on the first pair it adds, whatever the
        # grammar.
        status, output = self.prove(
            fixtures.LR1_LIST,
            2,
            environment={
                **self.environment,
                "AMBIGUITY_MAX_FRONTIER_RATIO": "0.00001",
            },
        )
        self.assertEqual(status, harness.NOT_PROVEN, output)
        self.assertRegex(output, harness.NOT_PROVEN_LINE)
        self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_an_expired_timeout_reports_not_proven(self) -> None:
        # The abstract phase runs under the same --timeout as the search that
        # may follow it. A deadline of zero cannot admit a single pair, so the
        # proof stops with work still queued -- the one route out of the loop
        # that is neither a verdict nor an overflow. It must read as "not
        # proven": a proof cut short by the clock has established nothing, and
        # reporting one would be the worst bug this tool can have.
        status, output = self.prove(fixtures.LR1_LIST, 2, timeout="0")
        self.assertEqual(status, harness.NOT_PROVEN, output)
        self.assertRegex(output, harness.NOT_PROVEN_LINE)
        self.assertNotRegex(output, harness.PROVEN_LINE)

    def test_a_generous_timeout_still_proves(self) -> None:
        # The guard against the test above passing for the wrong reason: the
        # same grammar and level prove when the clock is not the constraint,
        # so the deadline is what changed the verdict.
        status, output = self.prove(fixtures.LR1_LIST, 2)
        self.assertEqual(status, harness.PROVEN, output)

    def test_a_plain_search_reports_no_verdict(self) -> None:
        # Only proof mode returns a verdict. A bounded search that finds
        # witnesses is still a successful run, so it keeps exiting 0 and
        # existing callers of `ambiguity search` are unaffected.
        path = self.directory / "grammar.mly"
        path.write_text(fixtures.AMBIGUOUS_EXPRESSION, encoding="utf-8")
        result = subprocess.run(
            [
                str(harness.ENGINE),
                "--max-tokens",
                "8",
                "--timeout",
                "30",
                "--max-witnesses",
                "5",
                str(path),
            ],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=180,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, harness.WITNESS_LINE)


class SearchTerminationTests(harness.ProverTestCase):
    """Every search says how it ended, so silence is never the explanation."""

    def search(
        self, grammar: str, *, max_tokens: str = "6", timeout: str = "30"
    ) -> str:
        path = self.directory / "grammar.mly"
        path.write_text(grammar, encoding="utf-8")
        result = subprocess.run(
            [
                str(harness.ENGINE),
                "--max-tokens",
                max_tokens,
                "--timeout",
                timeout,
                "--max-witnesses",
                "5",
                str(path),
            ],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=180,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_an_exhausted_bound_says_so(self) -> None:
        # The conclusive case, and the one that used to be reported by leaving
        # the reason out: nothing of this length is ambiguous because every
        # sentence of this length was checked, not because the search gave up.
        output = self.search(fixtures.LR1_LIST)
        self.assertRegex(output, harness.TERMINATION_LINE)
        self.assertIn("the search space within the token bound was exhausted", output)

    def test_a_curtailed_search_names_its_limit(self) -> None:
        # The other side of the same line: a deadline of zero stops the search
        # before it can rule anything out, and the report has to say which of
        # the two happened.
        output = self.search(fixtures.AMBIGUOUS_EXPRESSION, max_tokens="16", timeout="0")
        self.assertRegex(output, harness.TERMINATION_LINE)
        self.assertIn("the timeout was reached", output)
        self.assertNotIn("the search space within the token bound was exhausted", output)

    def test_a_search_with_witnesses_also_reports_termination(self) -> None:
        # Witnesses do not excuse the run from saying how it ended: whether the
        # ones reported are all of them depends on the same distinction.
        output = self.search(fixtures.AMBIGUOUS_EXPRESSION)
        self.assertRegex(output, harness.WITNESS_LINE)
        self.assertRegex(output, harness.TERMINATION_LINE)


class ProofBudgetTests(harness.ProverTestCase):
    def test_the_proof_budget_ignores_the_worker_count(self) -> None:
        # The abstract phase is a single sequential search, so splitting the
        # declared memory across workers that never start would shrink the
        # budget for no reason.
        budgets = set()
        for jobs in ("1", "4"):
            _, output = self.prove(
                fixtures.LR1_LIST,
                2,
                environment={**self.environment, "AMBIGUITY_JOBS": jobs},
            )
            line = [
                text
                for text in output.splitlines()
                if text.startswith("Proof budget:")
            ]
            self.assertTrue(line, output)
            budgets.add(line[0].split("(")[0].strip())
        self.assertEqual(len(budgets), 1, budgets)


if __name__ == "__main__":
    unittest.main()
