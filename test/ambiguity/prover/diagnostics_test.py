#!/usr/bin/env python3
"""What the prover says about a candidate beyond the verdict.

The stack-height and residue constraints that refuse a move the abstraction
would otherwise admit, the exact parse of a candidate that says whether it was
real, and the forward trace that follows one from its divergence site down to
acceptance naming every guess on the way.
"""

import re
import unittest

from test.ambiguity.prover import fixtures, harness

class StackHeightTests(harness.ProverTestCase):
    def test_a_state_no_short_stack_can_carry_is_refused(self) -> None:
        # The abstraction rebuilds a stack on a guessed goto source, and the
        # sources it may guess are read off the automaton's shape alone. That
        # admits states needing a taller stack than the run has built, and
        # retained depth never rules them out, because depth is a chain of
        # adjacent states and so is the guess.
        status, output = self.prove(fixtures.LATE_ARM, 1)
        self.assertEqual(status, harness.PROVEN, output)
        match = harness.REACHABILITY_LINE.search(output)
        self.assertIsNotNone(match, output)
        assert match is not None
        self.assertGreater(int(match.group(1)), 0, output)
        # Past the widest reduction the exact height decides nothing, so the
        # count stops there. A ceiling below that would leave reductions whose
        # room the abstraction can never check.
        self.assertGreater(int(match.group(2)), 0, output)

    def test_a_surviving_candidate_still_says_what_the_height_refused(
        self,
    ) -> None:
        # A candidate is the run whose reader most needs the count, because it
        # is what separates "the abstraction is blind here" from "the
        # abstraction looked and the moves it kept were real". Reporting it
        # only alongside a proof made the test look inert on every run that did
        # not find one.
        status, output = self.prove(fixtures.LATE_PALINDROME, 1)
        self.assertNotEqual(status, harness.PROVEN, output)
        self.assertIn("Abstract ambiguity candidate", output)
        match = harness.REACHABILITY_LINE.search(output)
        self.assertIsNotNone(match, output)
        assert match is not None
        self.assertGreater(int(match.group(1)), 0, output)

    def test_a_chain_keeps_the_entries_its_own_pops_left_behind(self) -> None:
        # Every pop in the chain leaving this site stays inside the retained
        # stack, so every goto it takes resolves off a suffix long enough to
        # expose its source, and the step has nothing to guess. It guessed
        # anyway, because the stack was cut back to the retained depth after
        # each pop and the descent then invented its way back down -- through
        # every context `ty` appears in, rather than the one the chain had
        # just been standing in. A pop never leaves more than it was given, so
        # keeping what it left costs nothing that outlives the chain.
        _, output = self.prove(fixtures.MID_CHAIN, 3, extra=("--prove-trace",))
        steps = [
            line
            for line in output.splitlines()
            if re.match(r"^ *\d+\. on ", line)
        ]
        if harness.PROVEN_LINE.search(output):
            # The viable-stack residue can now eliminate the invented chain
            # before a trace exists. A proof is stronger evidence than the old
            # exact first step this regression originally required.
            self.assertRegex(output, harness.PROVEN_LINE)
        else:
            self.assertTrue(steps, output)
            self.assertTrue(steps[0].rstrip().endswith("[exact]"), output)

    def test_a_grammar_with_nothing_to_refuse_stays_silent(self) -> None:
        # The line has to mean something when it appears, which it only does if
        # a run that refused nothing does not print it.
        _, output = self.prove(fixtures.LR1_LIST, 1)
        self.assertIsNone(harness.REACHABILITY_LINE.search(output), output)

    def test_refusing_moves_never_proves_an_ambiguous_grammar(self) -> None:
        # The test removes moves from the search, which is the one kind of
        # change that can turn a sound over-approximation into a false
        # theorem. Every ambiguous grammar has to survive it at every level.
        for name, grammar in fixtures.AMBIGUOUS_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertNotRegex(output, harness.PROVEN_LINE)
                    self.assertNotEqual(status, harness.PROVEN, output)


class CandidateParseTests(harness.ProverTestCase):
    """A candidate is parsed for real before anything is spent on it.

    The abstract phase reasons about every sentence at once and approximates to
    do it, so a candidate may be a real ambiguity or an artifact of the
    approximation. One sentence is short enough to parse exactly, and the
    engine already carries the recognizer, so the answer is available for the
    asking -- and it decides both what the report says and whether another
    refinement round is worth running.
    """

    def test_a_spurious_candidate_is_named_as_one(self) -> None:
        # The palindrome's first candidate is a sentence the grammar does
        # derive -- the abstraction simply cannot tell its one parse from a
        # second. One derivation is as spurious as none, and saying so is the
        # difference between a reader who knows the pair is an artifact and one
        # who has to go and check.
        _, output = self.prove(fixtures.EVEN_PALINDROME, 1)
        self.assertRegex(output, harness.CANDIDATE_SINGLE_PARSE)
        self.assertNotRegex(output, harness.CANDIDATE_AMBIGUOUS)

    def test_a_candidate_outside_the_language_is_named_as_one(self) -> None:
        # The other spurious answer: a candidate the recognizer rejects
        # outright. Not an ambiguity, not even a sentence -- and the answer a
        # refinement round would otherwise have been spent discovering.
        _, output = self.prove(fixtures.ACCEPTS_NON_SENTENCES, 1, max_tokens="10")
        # A sharper abstraction may eliminate every rejected candidate before
        # the recognizer has one to report. If it does report a candidate, the
        # exact check must still classify it as spurious.
        if not harness.PROVEN_LINE.search(output):
            self.assertTrue(
                harness.CANDIDATE_REJECTED.search(output)
                or harness.CANDIDATE_SINGLE_PARSE.search(output),
                output,
            )
            self.assertNotRegex(output, harness.CANDIDATE_AMBIGUOUS)

    def test_a_real_ambiguity_is_confirmed_not_suspected(self) -> None:
        # The other direction. Two derivations of the candidate's own sentence
        # settle the grammar, and the run says the recognizer found them rather
        # than reporting a suspicion the bounded search then has to chase.
        status, output = self.prove(fixtures.AMBIGUOUS_EXPRESSION, 1)
        self.assertEqual(status, harness.AMBIGUOUS, output)
        confirmed = harness.CANDIDATE_AMBIGUOUS.search(output)
        self.assertIsNotNone(confirmed, output)
        self.assertEqual(confirmed.group(1), "2", output)
        self.assertRegex(output, harness.WITNESS_LINE)

    def test_a_confirmed_ambiguity_is_not_refined(self) -> None:
        # Refining a candidate the recognizer has confirmed is sharpening an
        # abstraction that turned out to be right. There is nothing for a round
        # to buy, and the rounds are the expensive part of a proof run: the
        # grammar is already settled, so the run goes to the witness instead.
        status, output = self.prove(
            fixtures.AMBIGUOUS_EXPRESSION, 1, extra=("--prove-refine", "8")
        )
        self.assertEqual(status, harness.AMBIGUOUS, output)
        self.assertNotRegex(output, harness.REFINEMENT_ROUND_LINE)
        self.assertRegex(output, harness.WITNESS_LINE)

    def test_the_decisive_step_is_reported(self) -> None:
        # What aims a refinement round. The recognizer's stacks are compared
        # against the abstraction's step by step, and the first step whose
        # abstract stack no real stack carries is where the abstraction left
        # the language -- the steps before it were tracking a parse that
        # exists, the ones after are a walk no parse takes.
        _, output = self.prove(fixtures.ACCEPTS_NON_SENTENCES, 1, max_tokens="10")
        decisive = harness.CANDIDATE_DECISIVE.search(output)
        if harness.CANDIDATE_REJECTED.search(output) is None:
            # No rejected candidate means there is no point where an abstract
            # path demonstrably left this sentence's real parser frontier.
            self.assertIsNone(decisive, output)
            return
        self.assertIsNotNone(decisive, output)
        # A step is only named where the abstraction did leave the language, so
        # the sentence it was found on is one the recognizer rejects, and the
        # step is inside that sentence or at its end -- never past it.
        self.assertRegex(output, harness.CANDIDATE_REJECTED)
        candidate = harness.CANDIDATE_LINE.search(output)
        self.assertIsNotNone(candidate, output)
        self.assertLessEqual(
            int(decisive.group(1)), len(candidate.group(1).split()), output
        )

    def test_a_confirmed_ambiguity_outlives_the_search_bound(self) -> None:
        # The dangling else's shortest witness is ten tokens, so a search
        # bounded at eight cannot render it -- but the abstract phase has no
        # token bound, and the recognizer has already parsed the candidate
        # twice. Reporting "neither proven unambiguous nor shown ambiguous"
        # there would be the run disclaiming a finding it is holding.
        status, output = self.prove(fixtures.DANGLING_ELSE, 1, max_tokens="8")
        self.assertEqual(status, harness.AMBIGUOUS, output)
        beyond = harness.AMBIGUOUS_BEYOND_BOUND.search(output)
        if beyond is not None:
            self.assertEqual(beyond.group(3), "8", output)
        else:
            self.assertRegex(output, harness.WITNESS_LINE)
        self.assertNotRegex(output, harness.NOT_PROVEN_LINE)
        # The witness is named even though no family is rendered: a sentence
        # the reader can feed back to `ambiguity check` is the whole of what
        # the search would have added.
        if beyond is not None:
            self.assertGreater(len(beyond.group(1).split()), 8, output)

    def test_an_unambiguous_grammar_still_proves(self) -> None:
        # The guard on all of the above: a check that runs on candidates must
        # not disturb a run that never produces one.
        for name, grammar in fixtures.CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(grammar, 1)
                self.assertEqual(status, harness.PROVEN, output)
                self.assertRegex(output, harness.PROVEN_LINE)


class ForwardTraceTests(harness.ProverTestCase):
    """`--prove-trace` reports what happened after two parses parted ways.

    Every other diagnostic reports where a divergence was *born*, which
    explains a candidate only when the site is also the reason it survived.
    When the site's own conflict is exact -- two moves a real sentence could
    both begin with -- the pair is admitted by both sides walking on to
    acceptance, and the step that should have killed one of them is somewhere
    along that walk. Nothing else in the tool shows it.
    """

    def test_a_trace_is_absent_unless_requested(self) -> None:
        _, output = self.prove(fixtures.AMBIGUOUS_EXPRESSION, 2)
        self.assertNotRegex(output, harness.FORWARD_HEADER)

    def test_a_trace_follows_the_candidate_to_acceptance(self) -> None:
        # The walk has to end where the pair was counted: at end of input. That
        # step is not one of the recorded edges -- the pair reaches acceptance
        # under the sentinel, which the search takes separately -- so leaving it
        # off is the easy way for this to stop short of the thing it explains.
        _, output = self.prove(
            fixtures.AMBIGUOUS_EXPRESSION, 2, extra=("--prove-trace",)
        )
        self.assertRegex(output, harness.FORWARD_HEADER)
        steps = harness.FORWARD_STEP.findall(output)
        self.assertGreaterEqual(len(steps), 2, output)
        self.assertEqual(steps[-1][1], "#", output)
        # Numbered consecutively from one, so a dropped step is visible rather
        # than silently shortening the walk.
        self.assertEqual(
            [number for number, _ in steps],
            [str(index + 1) for index in range(len(steps))],
            output,
        )

    def test_every_step_says_whether_it_guessed(self) -> None:
        # A step that reports neither "[exact]" nor a guessed state explains
        # nothing, and this walk exists to answer exactly that question at
        # every step. Checked structurally rather than by counting, so a step
        # that loses its annotation fails here.
        _, output = self.prove(
            fixtures.AMBIGUOUS_EXPRESSION, 2, extra=("--prove-trace",)
        )
        lines = output.splitlines()
        starts = [
            index for index, line in enumerate(lines) if harness.FORWARD_STEP.match(line)
        ]
        self.assertGreaterEqual(len(starts), 2, output)
        for index in starts:
            if lines[index].endswith("[exact]"):
                continue
            self.assertLess(index + 1, len(lines), output)
            self.assertRegex(lines[index + 1], harness.FORWARD_GUESS, output)

    def test_each_guess_is_reported_once_per_step(self) -> None:
        # A reduction popping into the unknown yields one move per goto edge it
        # is allowed to take, and reporting each of them prints the same finding
        # several times over -- once per possibility the abstraction kept, which
        # reads as several separate problems. Three competing reductions in one
        # state is the case that produced it.
        _, output = self.prove(
            fixtures.THREE_WAY_CONFLICT, 1, extra=("--prove-trace",)
        )
        lines = output.splitlines()
        starts = [
            index for index, line in enumerate(lines) if harness.FORWARD_STEP.match(line)
        ]
        self.assertGreaterEqual(len(starts), 1, output)
        for position, start in enumerate(starts):
            stop = starts[position + 1] if position + 1 < len(starts) else len(lines)
            guesses = [
                line.strip()
                for line in lines[start + 1 : stop]
                if harness.FORWARD_GUESS.match(line)
            ]
            self.assertCountEqual(guesses, set(guesses), output)

    def test_a_divergence_born_at_end_of_input_still_traces(self) -> None:
        # The walk replays recorded edges, and a pair that parts ways under the
        # sentinel has none: its divergence is born at the step the search takes
        # separately. That printed no trace at all, while still reporting that
        # one had been asked for.
        _, output = self.prove(
            fixtures.SENTINEL_REDUCE_REDUCE, 1, extra=("--prove-trace",)
        )
        self.assertRegex(output, harness.FORWARD_HEADER)
        steps = harness.FORWARD_STEP.findall(output)
        self.assertEqual(len(steps), 1, output)
        self.assertEqual(steps[0][1], "#", output)

    def test_rejected_combinations_do_not_run(self) -> None:
        for name, level, extra in (
            ("without --prove", 0, ("--prove-trace",)),
            (
                "with --prove-survey",
                1,
                ("--prove-trace", "--prove-survey", "1"),
            ),
        ):
            with self.subTest(combination=name):
                status, output = self.prove(
                    fixtures.LR1_LIST, level, extra=extra, expect_verdict=False
                )
                self.assertNotIn(status, harness.VERDICT_STATUSES)
                self.assertNotRegex(output, harness.PROVEN_LINE)


if __name__ == "__main__":
    unittest.main()
