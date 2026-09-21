#!/usr/bin/env python3
"""Sharpening the abstraction at the site a candidate was born at, and giving
a site up when that stops moving it.

Refinement deepens only the states behind the candidate rather than raising
the level everywhere, so what these tests pin is where it deepens, when it
stops, and that a run which retired anything never reports a proof.
"""

import re
import unittest

from test.ambiguity.prover import fixtures, harness

class RefinementTests(harness.ProverTestCase):
    """`--prove-refine` treats a candidate as a question, not as an answer.

    A uniform abstraction level has to be paid for everywhere it is raised, so
    the level that would close one blind spot is usually the level that makes
    the proof too expensive to run. Refinement deepens the retained stack only
    behind the candidate that needed it shallow, and tries again.

    The property that matters is the one that would be worst to lose: sharper
    is still sound. Every depth assignment over-approximates, because
    truncation is the only thing that shortens a suffix and nothing invents
    one, so refining can remove spurious pairs but never a real parse. These
    tests pin that, and pin the report that says how far refinement got --
    which is the part a regression run has to reproduce.
    """

    def test_refinement_never_proves_an_ambiguous_grammar(self) -> None:
        # The direction worth guarding. Refinement exists to remove candidates,
        # and a candidate removed too eagerly is a false proof of an ambiguous
        # grammar -- the worst output this tool has. Refining hard on grammars
        # known ambiguous by construction is the cheapest place to catch it.
        for name, grammar in fixtures.AMBIGUOUS_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar, 1, extra=("--prove-refine", "6")
                )
                self.assertNotRegex(output, harness.PROVEN_LINE)
                self.assertNotEqual(status, harness.PROVEN, output)

    def test_refinement_leaves_a_conflict_free_proof_alone(self) -> None:
        # Nothing to refine: a conflict-free automaton offers one action per
        # state and lookahead, so no pair ever diverges and no candidate is
        # ever raised. The proof must come out the same as without the flag,
        # and must not report rounds it did not run.
        for name, grammar in fixtures.CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar, 1, extra=("--prove-refine", "6")
                )
                self.assertEqual(status, harness.PROVEN, output)
                self.assertRegex(output, harness.PROVEN_LINE)
                self.assertNotRegex(output, harness.REFINEMENT_ROUND_LINE)

    def test_refinement_deepens_the_stack_it_retains(self) -> None:
        # The mechanism itself. The palindrome is the standing example of a
        # grammar the abstraction cannot prove, so it is guaranteed to raise a
        # candidate, and a round that ran must show up as a retained stack
        # deeper than the level the run started from.
        status, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "5")
        )
        self.assertIn(status, (harness.PROVEN, harness.NOT_PROVEN), output)
        self.assertRegex(output, harness.REFINEMENT_ROUND_LINE)
        deepest = harness.REFINEMENT_DEEPEST.search(output)
        self.assertIsNotNone(deepest, output)
        self.assertGreater(int(deepest.group(1)), 1, output)

    def test_refinement_says_why_it_stopped(self) -> None:
        # A refinement that gives up without saying so reads as a proof that
        # was never attempted. The palindrome cannot be closed at any depth, so
        # this run always ends in a stop reason rather than a proof.
        status, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "5")
        )
        self.assertEqual(status, harness.NOT_PROVEN, output)
        self.assertRegex(output, harness.REFINEMENT_STOPPED_LINE)

    def test_an_unbounded_blind_spot_is_reported_as_one(self) -> None:
        # What refinement is worth beyond the proof. A bounded blind spot closes
        # once the retained stack outgrows it; an unbounded one never does, and
        # a run has to say so rather than leave it to be inferred from a verdict
        # that looks the same either way.
        #
        # There are three ways it can say so, and which one a grammar gets
        # depends on how much context the abstraction can recover. The
        # palindrome's middle is unbounded, so either the counterexample grows a
        # nesting per round, or -- once the descent rebuilds its stacks to full
        # depth -- the chain stops asking for depth at all and the run reports
        # that no retained stack rules the candidate out, or the deepening
        # climbs to the ceiling and the run reports that the candidate survived
        # every stack the ceiling allowed. All three are the same conclusion.
        #
        # The third became reachable when rounds stopped restarting the walk.
        # A restarting round re-derived the whole space and so met the shortest
        # *remaining* candidate, which lengthened as the short ones were
        # settled; a round that resumes meets the shortest one there is, which
        # need not move. What it reports instead is the ceiling, which is the
        # same statement about the same blind spot.
        _, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "8")
        )
        candidates = [
            match.group(2) for match in harness.REFINEMENT_ROUND_LINE.finditer(output)
        ]
        # Two rounds are what widening needs to be visible, so requiring them
        # up front would rule out the second outcome this test accepts: a run
        # whose descent rebuilds the stacks in the first round and stops there.
        self.assertTrue(candidates, output)
        stopped = harness.REFINEMENT_EXHAUSTED.search(output)
        ceiling = harness.REFINEMENT_CEILING.search(output)
        widened = len(candidates) >= 2 and len(candidates[-1].split()) > len(
            candidates[0].split()
        )
        self.assertTrue(
            widened or stopped is not None or ceiling is not None, output
        )
        self.assertRegex(output, harness.NOT_PROVEN_LINE)

    def test_a_request_past_the_ceiling_is_reported_not_swallowed(self) -> None:
        # The palindrome's competing reduction is three symbols wide, so its
        # chain asks for a retained stack of four. A ceiling of two cannot give
        # that, and clamping quietly would leave the run looking as though the
        # depth it asked for had been granted.
        _, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "2")
        )
        capped = harness.REFINEMENT_CAPPED.search(output)
        self.assertIsNotNone(capped, output)
        self.assertEqual(capped.group(2), "2", output)
        self.assertGreater(int(capped.group(4)), 2, output)

    def test_no_cap_is_reported_when_every_request_fits(self) -> None:
        # The guard against the line above appearing whenever refinement runs.
        # The palindrome's chain asks for a retained stack of four and widens
        # by one per round after that, so a ceiling of eight covers every
        # request it makes and there is nothing to cut down -- where the
        # ceiling of two above cuts down the very first one.
        _, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "8")
        )
        self.assertRegex(output, harness.REFINEMENT_ROUND_LINE)
        self.assertNotRegex(output, harness.REFINEMENT_CAPPED)

    def test_a_round_keeps_what_the_last_one_settled(self) -> None:
        # Rounds share one walk. A deepening sharpens the abstraction the walk
        # is using, and a pair explored under the blunter one and found not to
        # accept cannot start accepting once the stacks behind it get longer --
        # so a round pays only for the pairs the deepening actually stood on,
        # where it used to re-derive the whole space from the initial pair.
        _, output = self.prove(
            fixtures.ACCEPTS_NON_SENTENCES,
            1,
            max_tokens="10",
            extra=("--prove-refine", "8"),
        )
        rounds = harness.REOPENED_LINE.findall(output)
        self.assertGreaterEqual(len(rounds), 2, output)
        for reopened, settled, _, _ in rounds:
            # Reopening everything would be the old behaviour wearing a new
            # line of output.
            self.assertLess(int(reopened), int(settled), output)
        # The walk keeps growing across rounds rather than starting again.
        self.assertGreater(int(rounds[-1][1]), int(rounds[0][1]), output)
        # And the stale queued pairs go. Without this the test passes on a run
        # that leaves them in the buckets, which is the failure the count was
        # added to make visible: the round then walks the blunt pair it set out
        # to replace. This grammar discards on some rounds and not others, so
        # what is pinned is that discarding happens at all.
        self.assertTrue(
            any(int(discarded) > 0 for _, _, _, discarded in rounds), output
        )

    def test_a_proof_without_rounds_is_not_reproved(self) -> None:
        # The fresh walk under a proof exists because rounds carry a table
        # built at blunter precisions. A run that never refined carries
        # nothing, so re-proving it would be paying twice for one walk.
        for name, grammar in fixtures.CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar, 1, extra=("--prove-refine", "8")
                )
                self.assertEqual(status, harness.PROVEN, output)
                self.assertNotRegex(output, harness.REFINEMENT_ROUND_LINE)
                self.assertNotRegex(output, harness.REPROVING_LINE)

    def test_the_round_limit_is_honoured(self) -> None:
        # The loop reruns a whole proof per round, so an unbounded blind spot
        # would otherwise refine until the clock stopped it, reporting a
        # timeout in place of the reason it actually failed.
        _, output = self.prove(
            fixtures.EVEN_PALINDROME,
            1,
            extra=("--prove-refine", "8", "--prove-refine-rounds", "1"),
        )
        rounds = harness.REFINEMENT_ROUND_LINE.findall(output)
        self.assertEqual(len(rounds), 1, output)
        stopped = harness.REFINEMENT_STOPPED_LINE.search(output)
        self.assertIsNotNone(stopped, output)
        self.assertIn("round limit", stopped.group(2), output)

    def test_a_curtailed_run_still_reports_what_refinement_did(self) -> None:
        # Running out of pairs after refining is a different situation from
        # never having refined, and the report used to look identical: the
        # pair-limit message alone, with no sign that the abstraction it
        # overflowed on was one refinement had already deepened. A reader
        # cannot tell from that whether to raise the budget or lower the
        # ceiling.
        #
        # The ratio admits the first round and not a later one, so the run
        # refines and then overflows rather than overflowing outright.
        status, output = self.prove(
            fixtures.EVEN_PALINDROME,
            1,
            extra=("--prove-refine", "8"),
            environment={
                **self.environment,
                "AMBIGUITY_MAX_FRONTIER_RATIO": "0.0012",
            },
        )
        self.assertEqual(status, harness.NOT_PROVEN, output)
        self.assertRegex(output, harness.NOT_PROVEN_LINE)
        self.assertRegex(output, harness.REFINEMENT_ROUND_LINE)
        self.assertRegex(
            output, re.compile(r"^Refinement reached: ", re.MULTILINE)
        )

    def test_rejected_combinations_do_not_run(self) -> None:
        # Each of these would otherwise look like it did something: refining
        # without a proof, refining shallower than the level it starts from, or
        # refining a survey, which walks the whole space and so never produces
        # the single candidate a refinement steers by.
        for name, level, extra in (
            ("without --prove", 0, ("--prove-refine", "4")),
            ("below --prove", 4, ("--prove-refine", "2")),
            (
                "with --prove-survey",
                1,
                ("--prove-refine", "4", "--prove-survey", "1"),
            ),
        ):
            with self.subTest(combination=name):
                status, output = self.prove(
                    fixtures.LR1_LIST, level, extra=extra, expect_verdict=False
                )
                self.assertNotIn(status, harness.VERDICT_STATUSES)
                self.assertNotRegex(output, harness.PROVEN_LINE)


class RetirementTests(harness.ProverTestCase):
    """`--prove-retire` bounds what one blind spot can cost a run.

    Refinement pursues one candidate at a time, so a site no depth in this
    abstraction reaches keeps producing candidates until the clock runs out,
    and the run ends having said nothing about any other part of the grammar.
    Retiring stops pursuing such a site, names it, and carries on.

    The property that would be worst to lose is not soundness of the
    abstraction -- retiring never sharpens anything -- but the reporting of a
    real ambiguity. Retiring drops the candidate the concretization search
    would otherwise have been handed, so these tests pin that a witness is
    still found, and that a run which retired anything never prints a proof.
    """

    def test_retirement_never_hides_an_ambiguity(self) -> None:
        # The direction that matters. `--prove-retire 1` retires at the first
        # opportunity, which is the most eager setting available and so the
        # most likely to step over a site that is a real ambiguity rather than
        # a blind spot. The witness has to survive it.
        for name, grammar in fixtures.AMBIGUOUS_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar,
                    1,
                    # The dangling else needs nine tokens for its shortest
                    # witness, which is past this suite's usual bound; without
                    # the room the run would report "not proven" for a reason
                    # that has nothing to do with retiring.
                    max_tokens="10",
                    extra=("--prove-refine", "6", "--prove-retire", "1"),
                )
                self.assertNotRegex(output, harness.PROVEN_LINE)
                self.assertNotEqual(status, harness.PROVEN, output)
                self.assertRegex(output, harness.WITNESS_LINE)
                self.assertEqual(status, harness.AMBIGUOUS, output)

    def test_a_retiring_run_never_reports_a_proof(self) -> None:
        # A retired site was stepped over, not answered, so a run that retired
        # anything has not proven the grammar however much of it came out
        # clean. Printing a proof there would be the most dangerous line this
        # tool has -- it would be a theorem about a space with a hole in it.
        status, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "5", "--prove-retire", "2")
        )
        self.assertRegex(output, harness.RETIRED_ANNOUNCEMENT)
        self.assertNotRegex(output, harness.PROVEN_LINE)
        self.assertRegex(output, harness.RETIRED_VERDICT)
        self.assertEqual(status, harness.NOT_PROVEN, output)

    def test_a_retired_site_is_named_with_its_evidence(self) -> None:
        # A site nobody can act on is not a useful thing to have stopped for.
        # Each retirement is printed with the sentence that reached it and the
        # conflict behind it, in the same form a survey uses.
        _, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "5", "--prove-retire", "2")
        )
        header = harness.RETIRED_HEADER.search(output)
        self.assertIsNotNone(header, output)
        self.assertEqual(len(harness.RETIRED_ENTRY.findall(output)), int(header.group(1)))
        self.assertRegex(output, harness.RETIRED_SENTENCE)
        self.assertRegex(output, harness.SITE_LOOKAHEAD_LINE)
        self.assertRegex(output, harness.SITE_CONFLICT_LINE)

    def test_the_run_continues_past_a_retired_site(self) -> None:
        # What retiring buys. Without it the abstract phase stops at the site
        # it gave up on; with it the phase runs to the end, so the verdict
        # covers the rest of the grammar rather than only the site with the
        # longest queue of counterexamples.
        _, output = self.prove(
            fixtures.EVEN_PALINDROME, 1, extra=("--prove-refine", "5", "--prove-retire", "2")
        )
        self.assertRegex(output, harness.RETIRED_CLOSED_LINE)

    def test_a_cut_short_run_claims_nothing_about_the_rest(self) -> None:
        # Retiring says what it gave up on; only an exhaustive walk says the
        # rest came out clean. A round limit that ends the run one retirement
        # in leaves a candidate standing at a different site, printed directly
        # below the retirement list -- so the unqualified "nowhere else" used
        # to contradict the same output it appeared in.
        _, cut_short = self.prove(
            fixtures.TWO_INDEPENDENT_SITES,
            1,
            extra=(
                "--prove-refine",
                "6",
                "--prove-retire",
                "1",
                "--prove-refine-rounds",
                "1",
            ),
        )
        self.assertRegex(cut_short, harness.RETIRED_HEADER_CUT_SHORT)
        self.assertNotRegex(cut_short, harness.RETIRED_HEADER)
        # The guard against that passing for the wrong reason: one more round
        # finishes the walk on the same grammar, and then the claim is earned.
        _, finished = self.prove(
            fixtures.TWO_INDEPENDENT_SITES,
            1,
            extra=(
                "--prove-refine",
                "6",
                "--prove-retire",
                "1",
                "--prove-refine-rounds",
                "2",
            ),
        )
        self.assertRegex(finished, harness.RETIRED_HEADER)
        self.assertNotRegex(finished, harness.RETIRED_HEADER_CUT_SHORT)

    def test_a_second_site_behind_the_first_is_still_reached(self) -> None:
        # The property retiring exists for, and the one its pruning could
        # break. A retired site takes its whole subtree with it, because every
        # node below a diverged one reports that node's site and so can only
        # produce candidates there. Prune a shade too widely and the site
        # behind it goes with it -- silently, since the run still ends in a
        # verdict. Two sites sharing nothing is the smallest thing that
        # notices.
        _, output = self.prove(
            fixtures.TWO_INDEPENDENT_SITES,
            1,
            extra=("--prove-refine", "6", "--prove-retire", "1"),
        )
        header = harness.RETIRED_HEADER.search(output)
        self.assertIsNotNone(header, output)
        self.assertEqual(int(header.group(1)), 2, output)
        lookaheads = {
            match.group(1) for match in harness.RETIRED_ANNOUNCEMENT.finditer(output)
        }
        self.assertEqual(lookaheads, {"A", "X"}, output)

    def test_the_round_limit_bounds_retirements_too(self) -> None:
        # What the round limit is bounding is abstract phases, and a
        # retirement starts one exactly as a deepening does. Charging only
        # deepenings left the limit unable to bite at all here: nothing
        # increments the round count on a retirement, so this grammar ran
        # three phases under a limit of one, and a grammar with many blind
        # spots would have run one per site.
        #
        # Both sites of this grammar exhaust the ceiling before any deepening
        # happens, so the whole budget goes to retirements and the count is
        # exactly the limit.
        for limit, expected in (("1", 1), ("2", 2)):
            with self.subTest(rounds=limit):
                _, output = self.prove(
                    fixtures.EVEN_PALINDROME,
                    1,
                    extra=(
                        "--prove-refine",
                        "5",
                        "--prove-refine-rounds",
                        limit,
                        "--prove-retire",
                        "1",
                    ),
                )
                retired = harness.RETIRED_ANNOUNCEMENT.findall(output)
                self.assertEqual(len(retired), expected, output)

    def test_a_retirement_with_no_budget_left_says_so(self) -> None:
        # A run that stops because it may not retire reads exactly like one
        # that stopped because the site was hopeless, and the two want
        # different things from the reader -- the first is a limit to raise.
        _, output = self.prove(
            fixtures.EVEN_PALINDROME,
            1,
            extra=(
                "--prove-refine",
                "5",
                "--prove-refine-rounds",
                "1",
                "--prove-retire",
                "1",
            ),
        )
        stopped = harness.REFINEMENT_STOPPED_LINE.search(output)
        self.assertIsNotNone(stopped, output)
        self.assertIn("no room to retire it", stopped.group(2), output)

    def test_retirement_leaves_a_conflict_free_proof_alone(self) -> None:
        # Nothing to retire: no pair ever diverges, so no candidate is raised
        # and the proof must come out exactly as it does without the flag --
        # including its status, which retiring anything would have changed.
        for name, grammar in fixtures.CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar,
                    1,
                    extra=("--prove-refine", "6", "--prove-retire", "1"),
                )
                self.assertEqual(status, harness.PROVEN, output)
                self.assertRegex(output, harness.PROVEN_LINE)
                self.assertNotRegex(output, harness.RETIRED_ANNOUNCEMENT)

    def test_retiring_without_refinement_does_not_run(self) -> None:
        # Retiring names what refinement failed to close, so without
        # refinement there is nothing for it to act on and it would run
        # exactly as if it had not been typed.
        status, output = self.prove(
            fixtures.LR1_LIST, 1, extra=("--prove-retire", "2"), expect_verdict=False
        )
        self.assertNotIn(status, harness.VERDICT_STATUSES)
        self.assertNotRegex(output, harness.PROVEN_LINE)


if __name__ == "__main__":
    unittest.main()
