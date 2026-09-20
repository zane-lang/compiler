#!/usr/bin/env python3
"""Walking the whole abstract space instead of stopping at the first
divergence.

A proof stops at one site, which says nothing about how many more lie behind
it -- and that count is what decides whether refining is worth attempting at
all. These pin what a survey counts, what it shows of each site, and the flag
combinations it cannot be asked for.
"""

import re
import subprocess
import unittest

from test.ambiguity.prover import fixtures, harness

class SurveyTests(harness.ProverTestCase):
    """Counting the blind spots, not stopping at the first."""

    def survey(
        self,
        grammar: str,
        level: int,
        examples: int = 3,
        timeout: str = "30",
    ) -> tuple[int, str]:
        path = self.directory / "grammar.mly"
        path.write_text(grammar, encoding="utf-8")
        result = subprocess.run(
            [
                str(harness.ENGINE),
                "--prove",
                str(level),
                "--prove-survey",
                str(examples),
                "--max-tokens",
                "8",
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
        self.assertIn(
            result.returncode, harness.VERDICT_STATUSES, result.stdout + result.stderr
        )
        return result.returncode, result.stdout

    def test_a_conflict_free_grammar_surveys_to_no_sites(self) -> None:
        # The survey walks the whole abstract space rather than stopping, so a
        # grammar with nothing to find must come back empty and still prove.
        status, output = self.survey(fixtures.LR1_LIST, 2)
        self.assertRegex(output, harness.SURVEY_LINE)
        self.assertIn("0 distinct divergence site(s)", output)
        self.assertEqual(status, harness.PROVEN, output)
        self.assertRegex(output, harness.PROVEN_LINE)

    def test_an_ambiguous_grammar_surveys_to_at_least_one_site(self) -> None:
        status, output = self.survey(fixtures.AMBIGUOUS_EXPRESSION, 2)
        self.assertRegex(output, harness.SURVEY_LINE)
        self.assertNotIn("0 distinct divergence site(s)", output)
        self.assertEqual(status, harness.NOT_PROVEN, output)

    def test_a_survey_does_not_stop_at_the_first_site(self) -> None:
        # The point of the mode. Dangling else diverges at more than one place,
        # so a survey that halted like a proof would report exactly one.
        _, output = self.survey(fixtures.DANGLING_ELSE, 2)
        match = re.search(r"Survey at level \d+: (\d+) distinct", output)
        self.assertIsNotNone(match, output)
        self.assertGreater(int(match.group(1)), 1, output)

    def test_a_divergence_on_eof_is_counted_as_a_site(self) -> None:
        # The soundness case for this mode. EOF is not one of the terminals the
        # site loop walks, so a grammar whose only divergence is on end of
        # input once produced zero sites while still accepting a diverged pair.
        # A survey gated on the site count would have called that a proof.
        status, output = self.survey(fixtures.EOF_REDUCE_REDUCE, 2)
        self.assertRegex(output, harness.SURVEY_LINE)
        self.assertNotIn("0 distinct divergence site(s)", output)
        self.assertNotRegex(output, harness.PROVEN_LINE)
        self.assertEqual(status, harness.NOT_PROVEN, output)

    def test_every_example_carries_the_site_it_was_born_at(self) -> None:
        # The point of the dump. A token trail is the same whether two parses
        # genuinely differ or the abstraction merely lost the context that
        # separated them; the stack, lookahead and conflicting moves are what
        # tell them apart, so no example may be reported without them.
        _, output = self.survey(fixtures.AMBIGUOUS_EXPRESSION, 2)
        examples = len(harness.EXAMPLE_LINE.findall(output))
        self.assertGreater(examples, 0, output)
        self.assertEqual(len(harness.SITE_LOOKAHEAD_LINE.findall(output)), examples, output)
        # Two runs part ways only by taking different moves, so an undiverged
        # pair holds one stack rather than two.
        self.assertEqual(len(harness.SITE_STACK_LINE.findall(output)), examples, output)
        self.assertEqual(len(harness.SITE_CONFLICT_LINE.findall(output)), examples, output)
        self.assertEqual(len(harness.SITE_MOVE_LINE.findall(output)), 2 * examples, output)

    def test_a_site_names_the_moves_the_abstraction_had_to_choose_between(
        self,
    ) -> None:
        # A bare pair of state numbers is only a cross-reference into
        # `menhir --explain`. Naming the two productions in conflict is what
        # makes it findable in the grammar itself.
        moves = self.conflict_moves(fixtures.AMBIGUOUS_EXPRESSION, 2)
        # Menhir prints productions as "lhs -> rhs", and a divergence needs a
        # reduction on at least one of the two sides.
        self.assertTrue(
            any("reduce " in line and " -> " in line for line in moves),
            "\n".join(moves),
        )

    def test_the_conflict_is_localized_past_the_site_when_the_chain_shares_a_step(
        self,
    ) -> None:
        # The failure this dump was rewritten for. A site's own top state often
        # offers a single shared reduction, and reporting only that shows two
        # identical moves and explains nothing -- the competing moves live a
        # step or two down the chain. Whatever the conflict turns out to be, it
        # must never be reported as one move against an identical one.
        moves = self.conflict_moves(fixtures.AMBIGUOUS_EXPRESSION, 2)
        self.assertNotEqual(moves[0], moves[1], "\n".join(moves))

    def conflict_moves(self, grammar: str, level: int) -> list[str]:
        _, output = self.survey(grammar, level, examples=1)
        lines = [line for line in output.splitlines() if harness.SITE_MOVE_LINE.match(line)]
        self.assertEqual(len(lines), 2, output)
        return lines

    def test_a_reduction_that_pops_the_retained_stack_exactly_is_constrained(
        self,
    ) -> None:
        # The boundary case. Popping exactly the retained stack exposes what sat
        # below its deepest entry, so the goto source is narrowed to that
        # entry's predecessors -- constrained, not unknown. Reporting it as
        # unconstrained would point a refinement at a gap the predecessor filter
        # already closed. At level 1 the retained stack is one state and
        # `x: A` is one symbol wide, so this is exactly that case.
        lines = self.conflict_moves(fixtures.EOF_REDUCE_REDUCE, 1)
        self.assertTrue(
            any("pops the retained stack exactly" in line for line in lines),
            "\n".join(lines),
        )
        self.assertFalse(
            any("pops past the retained stack" in line for line in lines),
            "\n".join(lines),
        )

    def test_a_reduction_that_pops_past_the_retained_stack_is_reported_as_such(
        self,
    ) -> None:
        # The case a refinement could actually close. The reduction lands below
        # the retained stack, so the goto source is narrowed by walking the
        # predecessor relation as far as the pop went rather than pinned to one
        # state -- looser than the exact-pop case, and the looseness is what a
        # deeper stack would buy back. `x: A B` is two symbols wide against a
        # one-state stack.
        lines = self.conflict_moves(fixtures.WIDE_REDUCE_REDUCE, 1)
        self.assertTrue(
            any(harness.PAST_STACK_TAG.search(line) for line in lines),
            "\n".join(lines),
        )

    def test_a_rebuilt_stack_recovers_the_context_the_automaton_forces(
        self,
    ) -> None:
        # The reset this abstraction used to take: a reduction popping past the
        # retained stack rebuilt it as a goto target on a guessed source, two
        # entries and nothing below, however deep the run was entitled to keep.
        # Every reduction after that popped into the unknown immediately, so one
        # imprecise step cost precision for the rest of the run.
        #
        # Where the automaton determines what sits below -- one state with a
        # transition into the source -- that context is recovered, so a rebuilt
        # stack reaches the retained depth like any other. Level 4 against a
        # forced chain is the case where every entry below is determined, so
        # anything shorter than 4 means the recovery stopped early.
        _, output = self.survey(fixtures.REBUILT_STACK, 4, examples=1)
        conflict = harness.SITE_CONFLICT_LINE.search(output)
        self.assertIsNotNone(conflict, output)
        self.assertEqual(len(conflict.group(1).split()), 4, output)

    def test_a_proving_survey_dumps_no_sites(self) -> None:
        # Nothing accepted means nothing to explain, and a site block printed
        # anyway would read as a blind spot the proof says is not there.
        status, output = self.survey(fixtures.LR1_LIST, 2)
        self.assertEqual(status, harness.PROVEN, output)
        self.assertNotRegex(output, harness.SITE_LOOKAHEAD_LINE)
        self.assertNotRegex(output, harness.SITE_STACK_LINE)
        self.assertNotRegex(output, harness.SITE_CONFLICT_LINE)

    def test_an_incomplete_survey_never_proves(self) -> None:
        # A walk that was cut short has counted nothing, so its zero is a floor
        # rather than a total and must not read as a proof -- the same rule the
        # ordinary bounded search follows.
        status, output = self.survey(fixtures.LR1_LIST, 2, timeout="0")
        self.assertRegex(output, harness.SURVEY_LINE)
        self.assertIn("incomplete", output)
        self.assertNotRegex(output, harness.PROVEN_LINE)
        self.assertEqual(status, harness.NOT_PROVEN, output)

    def test_a_survey_is_rejected_without_a_proof_level(self) -> None:
        path = self.directory / "grammar.mly"
        path.write_text(fixtures.LR1_LIST, encoding="utf-8")
        result = subprocess.run(
            [
                str(harness.ENGINE),
                "--prove-survey",
                "3",
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
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
