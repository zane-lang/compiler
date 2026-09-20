#!/usr/bin/env python3
"""Both directions of soundness, and what the level buys.

An ambiguous grammar must never be proven at any level, and a conflict-free
one must be proven at every level -- those two bound the abstraction from
either side. The precision tests are the middle: grammars whose proof needs a
retained stack wide enough to tell the competing reductions apart.
"""

import re
import unittest

from test.ambiguity.prover import fixtures, harness

class ProverSoundnessTests(harness.ProverTestCase):
    def test_an_ambiguous_grammar_is_never_proven(self) -> None:
        # The direction that matters most: a proof of an ambiguous grammar is
        # a false theorem, and every later verdict inherits it.
        for name, grammar in fixtures.AMBIGUOUS_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertNotRegex(output, harness.PROVEN_LINE)
                    self.assertNotEqual(status, harness.PROVEN, output)

    def test_an_unambiguous_grammar_yields_no_witness(self) -> None:
        # The other direction: the concretization search must never produce a
        # witness for a grammar that has none, whatever the abstraction said.
        for name, grammar in fixtures.UNAMBIGUOUS_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertNotRegex(output, harness.WITNESS_LINE)
                    self.assertNotEqual(status, harness.AMBIGUOUS, output)

    def test_an_ambiguous_grammar_is_still_concretized(self) -> None:
        # Sharpening the abstraction must not prune away the candidate that
        # leads to a real witness, so the prover keeps naming the sentence
        # rather than retreating to "not proven".
        status, output = self.prove(fixtures.AMBIGUOUS_EXPRESSION, 2)
        self.assertRegex(output, re.compile(r"^(?:Found \d+ complete ambiguity|AMBIGUOUS:)", re.MULTILINE))
        self.assertEqual(status, harness.AMBIGUOUS, output)

    def test_exact_confirmed_candidate_bypasses_zero_token_replay(self) -> None:
        grammar = """\
%start <unit> main
%token EOF "<eof>"
%%
main: x EOF { () } | y EOF { () }
x: { () }
y: { () }
"""
        status, output = self.prove(grammar, 1, max_tokens="0")
        self.assertEqual(status, harness.AMBIGUOUS, output)
        self.assertRegex(output, re.compile(r"^AMBIGUOUS: the recognizer found two derivations", re.MULTILINE))


class ProverPrecisionTests(harness.ProverTestCase):
    def test_conflict_free_grammars_are_proven_at_every_level(self) -> None:
        for name, grammar in fixtures.CONFLICT_FREE_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertIn("PROVEN UNAMBIGUOUS", output)
                    self.assertEqual(status, harness.PROVEN, output)

    def test_palindrome_verdict_is_reported(self) -> None:
        # Not an assertion about which verdict: this grammar is unambiguous but
        # not LR, so whether it proves depends on how sharp the abstraction
        # currently is. Soundness is covered above; this records the reach of
        # the abstraction as it changes, in a form the test log shows.
        for level in (1, 2, 3, 4):
            status, output = self.prove(fixtures.EVEN_PALINDROME, level)
            self.assertIn(status, (harness.PROVEN, harness.NOT_PROVEN), output)
            verdict = "proven" if status == harness.PROVEN else "not proven"
            print(f"even-length palindrome at level {level}: {verdict}")

    def test_recursive_lookahead_is_proven_at_level_one(self) -> None:
        # This is the unbounded false-candidate family that a finite top-K
        # suffix cannot close: each extra MATCH can hide one more brace below
        # the retained suffix. The viable-stack residue summarizes the whole
        # automaton path, so the invented brace ownership is impossible at the
        # first level already.
        status, output = self.prove(fixtures.RECURSIVE_MATCH, 1)
        self.assertEqual(status, harness.PROVEN, output)
        self.assertRegex(output, harness.PROVEN_LINE)
        refused = harness.RESIDUE_LINE.search(output)
        self.assertIsNotNone(refused, output)
        assert refused is not None
        self.assertGreater(int(refused.group(1)), 0, output)
        self.assertEqual(int(refused.group(2)), 1024, output)

    def test_stack_constraints_preserve_a_real_nested_ambiguity(self) -> None:
        # Two derivations of UIDENT inside the same recursive constructor/match
        # contexts. Pruning impossible height/residue combinations must not
        # mistake these genuinely different histories for an invented stack.
        grammar = fixtures.RECURSIVE_MATCH.replace(
            "| UIDENT { () }", "| UIDENT { () }\n  | alias { () }"
        ) + "\nalias: UIDENT { () }\n"
        for level in (1, 2, 3):
            with self.subTest(level=level):
                status, output = self.prove(grammar, level)
                self.assertEqual(status, harness.AMBIGUOUS, output)
                self.assertNotRegex(output, harness.PROVEN_LINE)


if __name__ == "__main__":
    unittest.main()
