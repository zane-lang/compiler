#!/usr/bin/env python3
"""Soundness and precision checks for `ambiguity prove`.

The prover abstracts GLR stacks to their top K states, which over-approximates
the stack below that depth. Sharpening the abstraction makes it prove more, and
the failure mode of sharpening it too far is the worst one available: reporting
a genuinely ambiguous grammar as proven. These tests pin both directions of
soundness against grammars whose status is known by construction, so a
precision change that crosses the line fails here rather than in a report
somebody trusts.

Soundness is asserted unconditionally; precision is asserted only where the
verdict follows from the automaton rather than from the abstraction's current
sharpness.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity_search.exe"

# Proof-mode exit statuses. A proof is a verdict rather than a success or a
# failure, so the status says which verdict was reached; 2 stays reserved for a
# run that went wrong, which is why it is not a verdict status.
PROVEN = 0
AMBIGUOUS = 1
NOT_PROVEN = 3
VERDICT_STATUSES = (PROVEN, AMBIGUOUS, NOT_PROVEN)

# Witnesses are announced by "Found N complete ambiguity families." The search
# says "no complete ambiguity was found" when there are none, so these have to
# be anchored: a bare "complete ambiguity" substring matches the announcement
# and its denial alike, and would read every empty search as a witness.
WITNESS_LINE = re.compile(r"^Found \d+ complete ambiguity", re.MULTILINE)
PROVEN_LINE = re.compile(r"^PROVEN UNAMBIGUOUS:", re.MULTILINE)
NOT_PROVEN_LINE = re.compile(r"^NOT PROVEN:", re.MULTILINE)
# Every search reports how it ended, so this line is present whether or not
# witnesses were found and whether or not a limit curtailed the run.
TERMINATION_LINE = re.compile(r"^Search ended at depth \d+ because ", re.MULTILINE)
SURVEY_LINE = re.compile(r"^Survey at level \d+: ", re.MULTILINE)
# Each surveyed example is followed by the site it was born at: the lookahead,
# the shared abstract stack, and the conflicting moves localized to the stack
# they fire from. The sentence alone does not say why the pair was admitted.
EXAMPLE_LINE = re.compile(r"^  \d+\. ", re.MULTILINE)
SITE_LOOKAHEAD_LINE = re.compile(
    r"^     divergence site on lookahead \S+$", re.MULTILINE
)
SITE_STACK_LINE = re.compile(
    r"^     abstract stack \(top first\): (\d+( \d+)*)?$", re.MULTILINE
)
# The site's own top state usually offers a single shared reduction; the
# competing moves appear further down the chain, so the conflict is reported at
# the stack it actually fires from.
SITE_CONFLICT_LINE = re.compile(r"^     conflict at stack (\d+( \d+)*)?:$", re.MULTILINE)
SITE_MOVE_LINE = re.compile(r"^       (reduce |shift to |accept)", re.MULTILINE)
# Matched whole rather than by prefix: the annotation is assembled from a
# multi-line OCaml literal, where a continuation written without its backslash
# silently bakes the source indentation into the rendered text.
PAST_STACK_TAG = re.compile(
    r"\[pops past the retained stack: goto limited to states \d+ "
    r"below its deepest\]"
)

# Refinement reports one line per round, then why it stopped. The round line
# carries the candidate that provoked it, which is what makes a widening
# counterexample visible round by round.
REFINEMENT_ROUND_LINE = re.compile(
    r"^Refinement round (\d+): deepened the stacks behind (.*), "
    r"retaining up to (\d+) \((state \d+ to \d+)(, state \d+ to \d+)*\)\.$",
    re.MULTILINE,
)
REFINEMENT_STOPPED_LINE = re.compile(
    r"^Refinement stopped after (\d+) round\(s\): (.+)\.$", re.MULTILINE
)
# The forward walk from a candidate's divergence site down to acceptance. Each
# step names the token, the stacks, and either "[exact]" or the states where a
# side had to guess a goto -- which is the whole point of the walk, so a step
# saying neither would be a step that explains nothing.
FORWARD_HEADER = re.compile(
    r"^  forward from the site, to acceptance:$", re.MULTILINE
)
FORWARD_STEP = re.compile(
    r"^ *(\d+)\. on (\S+) +(?:stack|left) ", re.MULTILINE
)
# No side attribution: the pair is stored canonicalised, so which side a guess
# belongs to is not recoverable, and a label would be a guess about a guess.
FORWARD_GUESS = re.compile(r"^ +guessed at state \d+ \(exact from \d+\)$")
# A refinement request for more depth than the ceiling allows is clamped to the
# ceiling rather than skipped, so the run still makes what progress it can. The
# clamp has to be reported: silently cutting a request down is how a candidate
# can need a retained stack of 11, be asked for 9 every round, and survive with
# nothing in the output saying the ceiling was the constraint.
REFINEMENT_CAPPED = re.compile(
    r"^Refinement was capped: (\d+) state\(s\) asked for a deeper stack than "
    r"--prove-refine (\d+) allows and were cut down to it; the deepest is "
    r"state (\d+), which is exact from (\d+)\.$",
    re.MULTILINE,
)
REFINEMENT_DEEPEST = re.compile(
    r"to a retained stack of (\d+) at the deepest\.", re.MULTILINE
)
CANDIDATE_LINE = re.compile(
    r"^Abstract ambiguity candidate at level \d+ after \d+ pairs "
    r"\((?:spurious|confirmed by the recognizer)\): (.+)$",
    re.MULTILINE,
)
# What the exact recognizer made of a candidate's own sentence. The abstract
# phase cannot answer this and used to leave it to the reader; the answer is
# what decides whether a refinement round is work or waste.
CANDIDATE_REJECTED = re.compile(
    r"^  the recognizer rejects this sentence, so the pair is spurious$",
    re.MULTILINE,
)
CANDIDATE_SINGLE_PARSE = re.compile(
    r"^  the recognizer accepts it exactly once, so the pair is spurious$",
    re.MULTILINE,
)
CANDIDATE_AMBIGUOUS = re.compile(
    r"^  the recognizer finds (\d+) derivations of it$", re.MULTILINE
)
# Where the abstraction left the language, which is where a refinement aimed by
# the real parse spends its round.
CANDIDATE_DECISIVE = re.compile(
    r"^  the abstraction leaves the real parse's stacks after (\d+) token\(s\), "
    r"on (\S+)$",
    re.MULTILINE,
)
REFINEMENT_EXHAUSTED = re.compile(
    r"^Refinement stopped after \d+ round\(s\): the candidate's chains never "
    r"needed the abstraction to invent a goto and never stood on a stack it "
    r"could not have rebuilt, so no retained stack rules it out\.$",
    re.MULTILINE,
)
# Retirement announces each decision as it is made, and then lists them again
# with their evidence. The announcement is what says the run carried on; the
# list is what a reader acts on, so both are pinned.
RETIRED_ANNOUNCEMENT = re.compile(
    r"^Retired the divergence site at states? \d+(?: and \d+)? on lookahead "
    r"(\S+): (.+)\. Continuing with the rest of the grammar\.$",
    re.MULTILINE,
)
RETIRED_HEADER = re.compile(
    r"^Retired (\d+) divergence site\(s\), each after refinement stopped "
    r"moving it\. The grammar is unproven at these sites and nowhere else:$",
    re.MULTILINE,
)
# The same list when the abstract phase did not finish. "Nowhere else" is a
# claim about the whole grammar and only the exhaustive walk earns it.
RETIRED_HEADER_CUT_SHORT = re.compile(
    r"^Retired (\d+) divergence site\(s\), each after refinement stopped "
    r"moving it\. The grammar is unproven at these sites and unclassified "
    r"everywhere else, since this run stopped before it finished walking the "
    r"abstract space:$",
    re.MULTILINE,
)
RETIRED_ENTRY = re.compile(
    r"^  \d+\. states? \d+(?: and \d+)? on lookahead \S+: .+$", re.MULTILINE
)
RETIRED_SENTENCE = re.compile(r"^     reached by: .+$", re.MULTILINE)
# The abstract phase ran to the end rather than stopping at the site it gave
# up on. This is the whole point of retiring: without it the run reports the
# one site it ran out of patience at and nothing about the rest.
RETIRED_CLOSED_LINE = re.compile(
    r"^Closed everywhere the search was still allowed to look: outside the "
    r"retired site\(s\), no diverging pair of accepting parses exists in the "
    r"top-\d+ stack abstraction \(\d+ abstract pairs explored\)\.$",
    re.MULTILINE,
)
RETIRED_VERDICT = re.compile(
    r"^NOT PROVEN: (\d+) retired site\(s\) were stepped over rather than "
    r"answered, ",
    re.MULTILINE,
)
REACHABILITY_LINE = re.compile(
    r"^Stack height: refused (\d+) move\(s\) onto a state no stack that short "
    r"can carry; the height stops being counted past (\d+)\.$",
    re.MULTILINE,
)


# Two blind spots that share nothing: one palindrome over `a` and another over
# `x`, reachable from one start symbol through disjoint alternatives, each
# behind an opening token of its own so that the two empty sentences stay
# distinct. Retiring prunes the subtree under a site it gave up on, and the
# property that pruning could break is exactly the one retirement exists for --
# reaching what lies behind the site. A grammar with one site cannot tell the
# two apart.
#
# Both sites have to be blind spots rather than ambiguities. A real ambiguity
# is settled by the recognizer as soon as the abstraction names a candidate,
# and a settled grammar has nothing left to retire: the run reports the witness
# instead, which is the right answer and the wrong fixture.
TWO_INDEPENDENT_SITES = """\
%token L "l"
%token R "r"
%token A "a"
%token X "x"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | L p EOF { () }
  | R q EOF { () }
p:
  | { () }
  | A p A { () }
q:
  | { () }
  | X q X { () }
"""

# Ambiguous: `a + a + a` groups two ways with nothing to choose between them.
AMBIGUOUS_EXPRESSION = """\
%token A "a"
%token PLUS "+"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | e PLUS e { () }
"""

# The classic dangling else: `if x then if x then x else x` attaches the else
# to either conditional.
DANGLING_ELSE = """\
%token IF "if"
%token THEN "then"
%token ELSE "else"
%token X "x"
%token EOF "<eof>"
%start <unit> main
%%
main: s EOF { () }
s:
  | X { () }
  | IF X THEN s { () }
  | IF X THEN s ELSE s { () }
"""

# The same shape as AMBIGUOUS_EXPRESSION, but the declared precedences remove
# the losing actions from the automaton, leaving it conflict-free.
PRECEDENCE_EXPRESSION = """\
%token A "a"
%token PLUS "+"
%token TIMES "*"
%token EOF "<eof>"
%left PLUS
%left TIMES
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | e PLUS e { () }
  | e TIMES e { () }
"""

# Plainly LR(1): one action per state and lookahead, no precedence needed.
LR1_LIST = """\
%token A "a"
%token EOF "<eof>"
%start <unit> main
%%
main: items EOF { () }
items:
  | { () }
  | items A { () }
"""

# Unambiguous but not LR: the parser cannot know it has reached the middle
# until the input ends, so this needs the GLR fork the policy allows. Proving
# it is the standing precision target for the abstraction.
EVEN_PALINDROME = """\
%token A "a"
%token B "b"
%token EOF "<eof>"
%start <unit> main
%%
main: p EOF { () }
p:
  | { () }
  | A p A { () }
  | B p B { () }
"""

# Ambiguous, and the divergence is born on the EOF lookahead: `a` reduces to
# either `x` or `y`, and nothing before end of input distinguishes them. EOF is
# not one of the terminals the survey iterates -- it is a separate sentinel --
# so a grammar whose only divergence lives there is what catches a survey that
# counts sites on regular lookaheads alone.
EOF_REDUCE_REDUCE = """\
%token A "a"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | x EOF { () }
  | y EOF { () }
x: A { () }
y: A { () }
"""

# The same reduce/reduce conflict, but reached over two symbols instead of one.
# At proof level 1 the retained stack is a single state, so the competing
# reductions here are strictly wider than it while `EOF_REDUCE_REDUCE`'s are
# exactly as wide -- the two sides of the boundary the site dump has to keep
# apart.
WIDE_REDUCE_REDUCE = """\
%token A "a"
%token B "b"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | x EOF { () }
  | y EOF { () }
x: A B { () }
y: A B { () }
"""

# A conflict that is only reached after a reduction has already popped past the
# retained stack, which is what makes the rebuilt stack observable at all. `w`
# is six symbols wide, so at proof level 4 reducing it pops into the unknown and
# the abstraction rebuilds the stack from a goto target and a guessed source.
#
# Everything before `w` is a forced chain -- `p q r` can be reached exactly one
# way -- so the states below that source are determined by the automaton rather
# than guessed, and the rebuilt stack should reach the full retained depth
# instead of stopping at the two entries a rebuild starts from.
REBUILT_STACK = """\
%token P "p"
%token Q "q"
%token R "r"
%token A "a"
%token B "b"
%token C "c"
%token D "d"
%token E "e"
%token F "f"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | P Q R w x EOF { () }
  | P Q R w y EOF { () }
w: A B C D E F { () }
x: A { () }
y: A { () }
"""

# Three productions reduced in one state on one lookahead, so a pair walking
# through it takes two of them and leaves the third unselected. A trace claims
# to say what happened on the path this pair took, so the chain it never entered
# must not appear in it.
THREE_WAY_CONFLICT = """\
%token A "a"
%token B "b"
%token C "c"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | p C EOF { () }
  | q C EOF { () }
  | r B EOF { () }
p: A B { () }
q: A B { () }
r: A B { () }
"""

# No end-of-input terminal, so the two parses can only part ways under the
# sentinel the search appends. That is the case where the walk has no recorded
# edge to replay and has to fall back to the accepting node's own step.
SENTINEL_REDUCE_REDUCE = """\
%token A "a"
%start <unit> main
%%
main:
  | x { () }
  | y { () }
x: A { () }
y: A { () }
"""

# One nonterminal reachable both early and late. `d` can begin a sentence or
# follow four `B`s, so the goto that rebuilds a stack after an imprecise
# reduction has two sources, and the far one needs terminals a short sentence
# has not read. The bracket conflict is the shape the real grammar stalls on:
# on `[`, either the suffix list ends and the brackets belong to `d`, or
# another suffix begins.
LATE_ARM = """\
%token A "a"
%token B "b"
%token LB "["
%token RB "]"
%token SEMI ";"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | d EOF { () }
  | B B B B d EOF { () }
d: ty LB RB SEMI { () }
ty: A suffixes { () }
suffixes:
  |                  { () }
  | LB RB suffixes   { () }
"""

# The late arm again, with an unbounded blind spot bolted on. `pal` is the
# even-length palindrome, so no fixed retained depth ever separates its two
# parses and every level ends in a surviving candidate -- while the `B B B B d`
# arm still gives the abstraction guessed goto sources that no short stack can
# be standing on. A run needs both to show that the height test reports what it
# did even when the run does not end in a proof.
LATE_PALINDROME = """\
%token A "a"
%token B "b"
%token LB "["
%token RB "]"
%token SEMI ";"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | d EOF { () }
  | B B B B d EOF { () }
  | pal EOF { () }
d: ty LB RB SEMI { () }
ty: A suffixes { () }
suffixes:
  |                  { () }
  | LB RB suffixes   { () }
pal:
  |            { () }
  | A pal A    { () }
"""

# A chain that reduces several times before it shifts, over a stack deeper than
# the retained depth. `decl` wraps a `ty` whose own suffix list is built from
# bracket pairs, so closing the list on `[` runs `suffixes -> epsilon`, then
# `suffixes -> LB args RB suffixes`, then `ty -> U gen suffixes`, each popping
# from what the one before it left. Every one of those pops stays inside the
# retained stack, so every goto along the way resolves exactly -- but a chain
# that re-truncates at each step throws the deeper entries away between them,
# and the descent walks them back through every context `ty` appears in, which
# `alias` and `bind` make several. The chain then walks on over a stack no
# parse was standing on, with nothing about it reading as a guess.
MID_CHAIN = """\
%token U "u"
%token L "l"
%token DOT "."
%token LB "["
%token RB "]"
%token SEMI ";"
%token BANG "!"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | decl EOF { () }
  | alias EOF { () }
  | bind EOF { () }
decl: U gen DOT L ty LB args RB SEMI { () }
alias: L DOT ty SEMI { () }
bind: BANG ty SEMI { () }
ty: U gen suffixes { () }
gen: { () }
args: { () }
suffixes:
  |                     { () }
  | LB args RB suffixes { () }
"""

AMBIGUOUS_GRAMMARS = {
    "expression without precedence": AMBIGUOUS_EXPRESSION,
    "dangling else": DANGLING_ELSE,
    "reduce/reduce on eof": EOF_REDUCE_REDUCE,
}

UNAMBIGUOUS_GRAMMARS = {
    "lr(1) list": LR1_LIST,
    "precedence-resolved expression": PRECEDENCE_EXPRESSION,
    "even-length palindrome": EVEN_PALINDROME,
    "late arm": LATE_ARM,
}

# Conflict-free automata offer exactly one action per state and lookahead, so
# no pair of abstract runs can ever take differing moves. That makes the proof
# a property of the automaton rather than of the abstraction's sharpness, and
# it must hold at every level — given a pair budget large enough to finish,
# which the environment below leaves ample for grammars this size.
CONFLICT_FREE_GRAMMARS = {
    "lr(1) list": LR1_LIST,
    "precedence-resolved expression": PRECEDENCE_EXPRESSION,
}


def engine_environment() -> dict[str, str] | None:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not ENGINE.exists() or menhir is None:
        return None
    return {
        **os.environ,
        "AMBIGUITY_MENHIR": menhir,
        "AMBIGUITY_MEMORY_MB": "64",
        "AMBIGUITY_MAX_FRONTIER_RATIO": "1.0",
        "AMBIGUITY_JOBS": "1",
    }


class ProverTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)

    def prove(
        self,
        grammar: str,
        level: int,
        *,
        environment: dict[str, str] | None = None,
        timeout: str = "30",
        max_tokens: str = "8",
        extra: tuple[str, ...] = (),
        expect_verdict: bool = True,
    ) -> tuple[int, str]:
        path = self.directory / "grammar.mly"
        path.write_text(grammar, encoding="utf-8")
        # --timeout bounds each search phase separately, so a proof run may
        # take up to twice it; a process-level timeout keeps a hung binary or
        # menhir from blocking the whole suite regardless.
        result = subprocess.run(
            [
                str(ENGINE),
                "--prove",
                str(level),
                *extra,
                "--max-tokens",
                max_tokens,
                "--timeout",
                timeout,
                "--max-witnesses",
                "5",
                str(path),
            ],
            env=environment or self.environment,
            text=True,
            capture_output=True,
            timeout=180,
        )
        # Any status outside the verdict set means the run itself failed, which
        # would make every assertion below vacuous. Argument-validation tests
        # are the exception: a rejected invocation is what they assert.
        if expect_verdict:
            self.assertIn(
                result.returncode, VERDICT_STATUSES, result.stdout + result.stderr
            )
        return result.returncode, result.stdout


class ProverSoundnessTests(ProverTestCase):
    def test_an_ambiguous_grammar_is_never_proven(self) -> None:
        # The direction that matters most: a proof of an ambiguous grammar is
        # a false theorem, and every later verdict inherits it.
        for name, grammar in AMBIGUOUS_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertNotRegex(output, PROVEN_LINE)
                    self.assertNotEqual(status, PROVEN, output)

    def test_an_unambiguous_grammar_yields_no_witness(self) -> None:
        # The other direction: the concretization search must never produce a
        # witness for a grammar that has none, whatever the abstraction said.
        for name, grammar in UNAMBIGUOUS_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertNotRegex(output, WITNESS_LINE)
                    self.assertNotEqual(status, AMBIGUOUS, output)

    def test_an_ambiguous_grammar_is_still_concretized(self) -> None:
        # Sharpening the abstraction must not prune away the candidate that
        # leads to a real witness, so the prover keeps naming the sentence
        # rather than retreating to "not proven".
        status, output = self.prove(AMBIGUOUS_EXPRESSION, 2)
        self.assertRegex(output, WITNESS_LINE)
        self.assertEqual(status, AMBIGUOUS, output)


class ProverPrecisionTests(ProverTestCase):
    def test_conflict_free_grammars_are_proven_at_every_level(self) -> None:
        for name, grammar in CONFLICT_FREE_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertIn("PROVEN UNAMBIGUOUS", output)
                    self.assertEqual(status, PROVEN, output)

    def test_palindrome_verdict_is_reported(self) -> None:
        # Not an assertion about which verdict: this grammar is unambiguous but
        # not LR, so whether it proves depends on how sharp the abstraction
        # currently is. Soundness is covered above; this records the reach of
        # the abstraction as it changes, in a form the test log shows.
        for level in (1, 2, 3, 4):
            status, output = self.prove(EVEN_PALINDROME, level)
            self.assertIn(status, (PROVEN, NOT_PROVEN), output)
            verdict = "proven" if status == PROVEN else "not proven"
            print(f"even-length palindrome at level {level}: {verdict}")


class RefinementTests(ProverTestCase):
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
        for name, grammar in AMBIGUOUS_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar, 1, extra=("--prove-refine", "6")
                )
                self.assertNotRegex(output, PROVEN_LINE)
                self.assertNotEqual(status, PROVEN, output)

    def test_refinement_leaves_a_conflict_free_proof_alone(self) -> None:
        # Nothing to refine: a conflict-free automaton offers one action per
        # state and lookahead, so no pair ever diverges and no candidate is
        # ever raised. The proof must come out the same as without the flag,
        # and must not report rounds it did not run.
        for name, grammar in CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar, 1, extra=("--prove-refine", "6")
                )
                self.assertEqual(status, PROVEN, output)
                self.assertRegex(output, PROVEN_LINE)
                self.assertNotRegex(output, REFINEMENT_ROUND_LINE)

    def test_refinement_deepens_the_stack_it_retains(self) -> None:
        # The mechanism itself. The palindrome is the standing example of a
        # grammar the abstraction cannot prove, so it is guaranteed to raise a
        # candidate, and a round that ran must show up as a retained stack
        # deeper than the level the run started from.
        status, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "5")
        )
        self.assertIn(status, (PROVEN, NOT_PROVEN), output)
        self.assertRegex(output, REFINEMENT_ROUND_LINE)
        deepest = REFINEMENT_DEEPEST.search(output)
        self.assertIsNotNone(deepest, output)
        self.assertGreater(int(deepest.group(1)), 1, output)

    def test_refinement_says_why_it_stopped(self) -> None:
        # A refinement that gives up without saying so reads as a proof that
        # was never attempted. The palindrome cannot be closed at any depth, so
        # this run always ends in a stop reason rather than a proof.
        status, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "5")
        )
        self.assertEqual(status, NOT_PROVEN, output)
        self.assertRegex(output, REFINEMENT_STOPPED_LINE)

    def test_an_unbounded_blind_spot_is_reported_as_one(self) -> None:
        # What refinement is worth beyond the proof. A bounded blind spot closes
        # once the retained stack outgrows it; an unbounded one never does, and
        # a run has to say so rather than leave it to be inferred from a verdict
        # that looks the same either way.
        #
        # There are two ways it can say so, and which one a grammar gets depends
        # on how much context the abstraction can recover. The palindrome's
        # middle is unbounded, so either the counterexample grows a nesting per
        # round, or -- once the descent rebuilds its stacks to full depth -- the
        # chain stops asking for depth at all and the run reports that no
        # retained stack rules the candidate out. Both are the same conclusion.
        _, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "8")
        )
        candidates = [
            match.group(2) for match in REFINEMENT_ROUND_LINE.finditer(output)
        ]
        # Two rounds are what widening needs to be visible, so requiring them
        # up front would rule out the second outcome this test accepts: a run
        # whose descent rebuilds the stacks in the first round and stops there.
        self.assertTrue(candidates, output)
        stopped = REFINEMENT_EXHAUSTED.search(output)
        widened = len(candidates) >= 2 and len(candidates[-1].split()) > len(
            candidates[0].split()
        )
        self.assertTrue(widened or stopped is not None, output)
        self.assertRegex(output, NOT_PROVEN_LINE)

    def test_a_request_past_the_ceiling_is_reported_not_swallowed(self) -> None:
        # The palindrome's competing reduction is three symbols wide, so its
        # chain asks for a retained stack of four. A ceiling of two cannot give
        # that, and clamping quietly would leave the run looking as though the
        # depth it asked for had been granted.
        _, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "2")
        )
        capped = REFINEMENT_CAPPED.search(output)
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
            EVEN_PALINDROME, 1, extra=("--prove-refine", "8")
        )
        self.assertRegex(output, REFINEMENT_ROUND_LINE)
        self.assertNotRegex(output, REFINEMENT_CAPPED)

    def test_the_round_limit_is_honoured(self) -> None:
        # The loop reruns a whole proof per round, so an unbounded blind spot
        # would otherwise refine until the clock stopped it, reporting a
        # timeout in place of the reason it actually failed.
        _, output = self.prove(
            EVEN_PALINDROME,
            1,
            extra=("--prove-refine", "8", "--prove-refine-rounds", "1"),
        )
        rounds = REFINEMENT_ROUND_LINE.findall(output)
        self.assertEqual(len(rounds), 1, output)
        stopped = REFINEMENT_STOPPED_LINE.search(output)
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
            EVEN_PALINDROME,
            1,
            extra=("--prove-refine", "8"),
            environment={
                **self.environment,
                "AMBIGUITY_MAX_FRONTIER_RATIO": "0.0008",
            },
        )
        self.assertEqual(status, NOT_PROVEN, output)
        self.assertRegex(output, NOT_PROVEN_LINE)
        self.assertRegex(output, REFINEMENT_ROUND_LINE)
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
                    LR1_LIST, level, extra=extra, expect_verdict=False
                )
                self.assertNotIn(status, VERDICT_STATUSES)
                self.assertNotRegex(output, PROVEN_LINE)


class RetirementTests(ProverTestCase):
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
        for name, grammar in AMBIGUOUS_GRAMMARS.items():
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
                self.assertNotRegex(output, PROVEN_LINE)
                self.assertNotEqual(status, PROVEN, output)
                self.assertRegex(output, WITNESS_LINE)
                self.assertEqual(status, AMBIGUOUS, output)

    def test_a_retiring_run_never_reports_a_proof(self) -> None:
        # A retired site was stepped over, not answered, so a run that retired
        # anything has not proven the grammar however much of it came out
        # clean. Printing a proof there would be the most dangerous line this
        # tool has -- it would be a theorem about a space with a hole in it.
        status, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "5", "--prove-retire", "2")
        )
        self.assertRegex(output, RETIRED_ANNOUNCEMENT)
        self.assertNotRegex(output, PROVEN_LINE)
        self.assertRegex(output, RETIRED_VERDICT)
        self.assertEqual(status, NOT_PROVEN, output)

    def test_a_retired_site_is_named_with_its_evidence(self) -> None:
        # A site nobody can act on is not a useful thing to have stopped for.
        # Each retirement is printed with the sentence that reached it and the
        # conflict behind it, in the same form a survey uses.
        _, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "5", "--prove-retire", "2")
        )
        header = RETIRED_HEADER.search(output)
        self.assertIsNotNone(header, output)
        self.assertEqual(len(RETIRED_ENTRY.findall(output)), int(header.group(1)))
        self.assertRegex(output, RETIRED_SENTENCE)
        self.assertRegex(output, SITE_LOOKAHEAD_LINE)
        self.assertRegex(output, SITE_CONFLICT_LINE)

    def test_the_run_continues_past_a_retired_site(self) -> None:
        # What retiring buys. Without it the abstract phase stops at the site
        # it gave up on; with it the phase runs to the end, so the verdict
        # covers the rest of the grammar rather than only the site with the
        # longest queue of counterexamples.
        _, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "5", "--prove-retire", "2")
        )
        self.assertRegex(output, RETIRED_CLOSED_LINE)

    def test_a_cut_short_run_claims_nothing_about_the_rest(self) -> None:
        # Retiring says what it gave up on; only an exhaustive walk says the
        # rest came out clean. A round limit that ends the run one retirement
        # in leaves a candidate standing at a different site, printed directly
        # below the retirement list -- so the unqualified "nowhere else" used
        # to contradict the same output it appeared in.
        _, cut_short = self.prove(
            TWO_INDEPENDENT_SITES,
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
        self.assertRegex(cut_short, RETIRED_HEADER_CUT_SHORT)
        self.assertNotRegex(cut_short, RETIRED_HEADER)
        # The guard against that passing for the wrong reason: one more round
        # finishes the walk on the same grammar, and then the claim is earned.
        _, finished = self.prove(
            TWO_INDEPENDENT_SITES,
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
        self.assertRegex(finished, RETIRED_HEADER)
        self.assertNotRegex(finished, RETIRED_HEADER_CUT_SHORT)

    def test_a_second_site_behind_the_first_is_still_reached(self) -> None:
        # The property retiring exists for, and the one its pruning could
        # break. A retired site takes its whole subtree with it, because every
        # node below a diverged one reports that node's site and so can only
        # produce candidates there. Prune a shade too widely and the site
        # behind it goes with it -- silently, since the run still ends in a
        # verdict. Two sites sharing nothing is the smallest thing that
        # notices.
        _, output = self.prove(
            TWO_INDEPENDENT_SITES,
            1,
            extra=("--prove-refine", "6", "--prove-retire", "1"),
        )
        header = RETIRED_HEADER.search(output)
        self.assertIsNotNone(header, output)
        self.assertEqual(int(header.group(1)), 2, output)
        lookaheads = {
            match.group(1) for match in RETIRED_ANNOUNCEMENT.finditer(output)
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
                    EVEN_PALINDROME,
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
                retired = RETIRED_ANNOUNCEMENT.findall(output)
                self.assertEqual(len(retired), expected, output)

    def test_a_retirement_with_no_budget_left_says_so(self) -> None:
        # A run that stops because it may not retire reads exactly like one
        # that stopped because the site was hopeless, and the two want
        # different things from the reader -- the first is a limit to raise.
        _, output = self.prove(
            EVEN_PALINDROME,
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
        stopped = REFINEMENT_STOPPED_LINE.search(output)
        self.assertIsNotNone(stopped, output)
        self.assertIn("no room to retire it", stopped.group(2), output)

    def test_retirement_leaves_a_conflict_free_proof_alone(self) -> None:
        # Nothing to retire: no pair ever diverges, so no candidate is raised
        # and the proof must come out exactly as it does without the flag --
        # including its status, which retiring anything would have changed.
        for name, grammar in CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(
                    grammar,
                    1,
                    extra=("--prove-refine", "6", "--prove-retire", "1"),
                )
                self.assertEqual(status, PROVEN, output)
                self.assertRegex(output, PROVEN_LINE)
                self.assertNotRegex(output, RETIRED_ANNOUNCEMENT)

    def test_retiring_without_refinement_does_not_run(self) -> None:
        # Retiring names what refinement failed to close, so without
        # refinement there is nothing for it to act on and it would run
        # exactly as if it had not been typed.
        status, output = self.prove(
            LR1_LIST, 1, extra=("--prove-retire", "2"), expect_verdict=False
        )
        self.assertNotIn(status, VERDICT_STATUSES)
        self.assertNotRegex(output, PROVEN_LINE)


class StackHeightTests(ProverTestCase):
    def test_a_state_no_short_stack_can_carry_is_refused(self) -> None:
        # The abstraction rebuilds a stack on a guessed goto source, and the
        # sources it may guess are read off the automaton's shape alone. That
        # admits states needing a taller stack than the run has built, and
        # retained depth never rules them out, because depth is a chain of
        # adjacent states and so is the guess.
        status, output = self.prove(LATE_ARM, 1)
        self.assertEqual(status, PROVEN, output)
        match = REACHABILITY_LINE.search(output)
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
        status, output = self.prove(LATE_PALINDROME, 1)
        self.assertNotEqual(status, PROVEN, output)
        self.assertIn("Abstract ambiguity candidate", output)
        match = REACHABILITY_LINE.search(output)
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
        _, output = self.prove(MID_CHAIN, 3, extra=("--prove-trace",))
        steps = [
            line
            for line in output.splitlines()
            if re.match(r"^ *\d+\. on ", line)
        ]
        self.assertTrue(steps, output)
        self.assertTrue(steps[0].rstrip().endswith("[exact]"), output)

    def test_a_grammar_with_nothing_to_refuse_stays_silent(self) -> None:
        # The line has to mean something when it appears, which it only does if
        # a run that refused nothing does not print it.
        _, output = self.prove(LR1_LIST, 1)
        self.assertIsNone(REACHABILITY_LINE.search(output), output)

    def test_refusing_moves_never_proves_an_ambiguous_grammar(self) -> None:
        # The test removes moves from the search, which is the one kind of
        # change that can turn a sound over-approximation into a false
        # theorem. Every ambiguous grammar has to survive it at every level.
        for name, grammar in AMBIGUOUS_GRAMMARS.items():
            for level in (1, 2, 3):
                with self.subTest(grammar=name, level=level):
                    status, output = self.prove(grammar, level)
                    self.assertNotRegex(output, PROVEN_LINE)
                    self.assertNotEqual(status, PROVEN, output)


class CandidateParseTests(ProverTestCase):
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
        _, output = self.prove(EVEN_PALINDROME, 1)
        self.assertRegex(output, CANDIDATE_SINGLE_PARSE)
        self.assertNotRegex(output, CANDIDATE_AMBIGUOUS)

    def test_a_candidate_outside_the_language_is_named_as_one(self) -> None:
        # Refinement walks the palindrome on to candidates of odd length, which
        # the recognizer rejects outright: not an ambiguity, not even a
        # sentence. That is the answer a round would otherwise be spent
        # discovering.
        _, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "8")
        )
        self.assertRegex(output, CANDIDATE_REJECTED)
        self.assertNotRegex(output, CANDIDATE_AMBIGUOUS)

    def test_a_real_ambiguity_is_confirmed_not_suspected(self) -> None:
        # The other direction. Two derivations of the candidate's own sentence
        # settle the grammar, and the run says the recognizer found them rather
        # than reporting a suspicion the bounded search then has to chase.
        status, output = self.prove(AMBIGUOUS_EXPRESSION, 1)
        self.assertEqual(status, AMBIGUOUS, output)
        confirmed = CANDIDATE_AMBIGUOUS.search(output)
        self.assertIsNotNone(confirmed, output)
        self.assertEqual(confirmed.group(1), "2", output)
        self.assertRegex(output, WITNESS_LINE)

    def test_a_confirmed_ambiguity_is_not_refined(self) -> None:
        # Refining a candidate the recognizer has confirmed is sharpening an
        # abstraction that turned out to be right. There is nothing for a round
        # to buy, and the rounds are the expensive part of a proof run: the
        # grammar is already settled, so the run goes to the witness instead.
        status, output = self.prove(
            AMBIGUOUS_EXPRESSION, 1, extra=("--prove-refine", "8")
        )
        self.assertEqual(status, AMBIGUOUS, output)
        self.assertNotRegex(output, REFINEMENT_ROUND_LINE)
        self.assertRegex(output, WITNESS_LINE)

    def test_the_decisive_step_is_reported(self) -> None:
        # What aims a refinement round. The recognizer's stacks are compared
        # against the abstraction's step by step, and the first step whose
        # abstract stack no real stack carries is where the abstraction left
        # the language -- the steps before it were tracking a parse that
        # exists, the ones after are a walk no parse takes.
        _, output = self.prove(
            EVEN_PALINDROME, 1, extra=("--prove-refine", "8")
        )
        decisive = CANDIDATE_DECISIVE.search(output)
        self.assertIsNotNone(decisive, output)
        # A step is only named where the abstraction did leave the language, so
        # the sentence it was found on is one the recognizer rejects, and the
        # step is inside that sentence or at its end -- never past it.
        self.assertRegex(output, CANDIDATE_REJECTED)
        rounds = REFINEMENT_ROUND_LINE.findall(output)
        self.assertTrue(rounds, output)
        longest = max(len(match[1].split()) for match in rounds)
        self.assertLessEqual(int(decisive.group(1)), longest, output)

    def test_an_unambiguous_grammar_still_proves(self) -> None:
        # The guard on all of the above: a check that runs on candidates must
        # not disturb a run that never produces one.
        for name, grammar in CONFLICT_FREE_GRAMMARS.items():
            with self.subTest(grammar=name):
                status, output = self.prove(grammar, 1)
                self.assertEqual(status, PROVEN, output)
                self.assertRegex(output, PROVEN_LINE)


class ForwardTraceTests(ProverTestCase):
    """`--prove-trace` reports what happened after two parses parted ways.

    Every other diagnostic reports where a divergence was *born*, which
    explains a candidate only when the site is also the reason it survived.
    When the site's own conflict is exact -- two moves a real sentence could
    both begin with -- the pair is admitted by both sides walking on to
    acceptance, and the step that should have killed one of them is somewhere
    along that walk. Nothing else in the tool shows it.
    """

    def test_a_trace_is_absent_unless_requested(self) -> None:
        _, output = self.prove(AMBIGUOUS_EXPRESSION, 2)
        self.assertNotRegex(output, FORWARD_HEADER)

    def test_a_trace_follows_the_candidate_to_acceptance(self) -> None:
        # The walk has to end where the pair was counted: at end of input. That
        # step is not one of the recorded edges -- the pair reaches acceptance
        # under the sentinel, which the search takes separately -- so leaving it
        # off is the easy way for this to stop short of the thing it explains.
        _, output = self.prove(
            AMBIGUOUS_EXPRESSION, 2, extra=("--prove-trace",)
        )
        self.assertRegex(output, FORWARD_HEADER)
        steps = FORWARD_STEP.findall(output)
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
            AMBIGUOUS_EXPRESSION, 2, extra=("--prove-trace",)
        )
        lines = output.splitlines()
        starts = [
            index for index, line in enumerate(lines) if FORWARD_STEP.match(line)
        ]
        self.assertGreaterEqual(len(starts), 2, output)
        for index in starts:
            if lines[index].endswith("[exact]"):
                continue
            self.assertLess(index + 1, len(lines), output)
            self.assertRegex(lines[index + 1], FORWARD_GUESS, output)

    def test_each_guess_is_reported_once_per_step(self) -> None:
        # A reduction popping into the unknown yields one move per goto edge it
        # is allowed to take, and reporting each of them prints the same finding
        # several times over -- once per possibility the abstraction kept, which
        # reads as several separate problems. Three competing reductions in one
        # state is the case that produced it.
        _, output = self.prove(
            THREE_WAY_CONFLICT, 1, extra=("--prove-trace",)
        )
        lines = output.splitlines()
        starts = [
            index for index, line in enumerate(lines) if FORWARD_STEP.match(line)
        ]
        self.assertGreaterEqual(len(starts), 1, output)
        for position, start in enumerate(starts):
            stop = starts[position + 1] if position + 1 < len(starts) else len(lines)
            guesses = [
                line.strip()
                for line in lines[start + 1 : stop]
                if FORWARD_GUESS.match(line)
            ]
            self.assertCountEqual(guesses, set(guesses), output)

    def test_a_divergence_born_at_end_of_input_still_traces(self) -> None:
        # The walk replays recorded edges, and a pair that parts ways under the
        # sentinel has none: its divergence is born at the step the search takes
        # separately. That printed no trace at all, while still reporting that
        # one had been asked for.
        _, output = self.prove(
            SENTINEL_REDUCE_REDUCE, 1, extra=("--prove-trace",)
        )
        self.assertRegex(output, FORWARD_HEADER)
        steps = FORWARD_STEP.findall(output)
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
                    LR1_LIST, level, extra=extra, expect_verdict=False
                )
                self.assertNotIn(status, VERDICT_STATUSES)
                self.assertNotRegex(output, PROVEN_LINE)


class ProofStatusTests(ProverTestCase):
    """The status is the machine-readable verdict, so it must track the text."""

    def test_each_verdict_reports_its_documented_status(self) -> None:
        for grammar, expected, marker in (
            (LR1_LIST, PROVEN, PROVEN_LINE),
            (AMBIGUOUS_EXPRESSION, AMBIGUOUS, WITNESS_LINE),
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
            LR1_LIST,
            2,
            environment={
                **self.environment,
                "AMBIGUITY_MAX_FRONTIER_RATIO": "0.00001",
            },
        )
        self.assertEqual(status, NOT_PROVEN, output)
        self.assertRegex(output, NOT_PROVEN_LINE)
        self.assertNotRegex(output, PROVEN_LINE)

    def test_an_expired_timeout_reports_not_proven(self) -> None:
        # The abstract phase runs under the same --timeout as the search that
        # may follow it. A deadline of zero cannot admit a single pair, so the
        # proof stops with work still queued -- the one route out of the loop
        # that is neither a verdict nor an overflow. It must read as "not
        # proven": a proof cut short by the clock has established nothing, and
        # reporting one would be the worst bug this tool can have.
        status, output = self.prove(LR1_LIST, 2, timeout="0")
        self.assertEqual(status, NOT_PROVEN, output)
        self.assertRegex(output, NOT_PROVEN_LINE)
        self.assertNotRegex(output, PROVEN_LINE)

    def test_a_generous_timeout_still_proves(self) -> None:
        # The guard against the test above passing for the wrong reason: the
        # same grammar and level prove when the clock is not the constraint,
        # so the deadline is what changed the verdict.
        status, output = self.prove(LR1_LIST, 2)
        self.assertEqual(status, PROVEN, output)

    def test_a_plain_search_reports_no_verdict(self) -> None:
        # Only proof mode returns a verdict. A bounded search that finds
        # witnesses is still a successful run, so it keeps exiting 0 and
        # existing callers of `ambiguity search` are unaffected.
        path = self.directory / "grammar.mly"
        path.write_text(AMBIGUOUS_EXPRESSION, encoding="utf-8")
        result = subprocess.run(
            [
                str(ENGINE),
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
        self.assertRegex(result.stdout, WITNESS_LINE)


class SearchTerminationTests(ProverTestCase):
    """Every search says how it ended, so silence is never the explanation."""

    def search(
        self, grammar: str, *, max_tokens: str = "6", timeout: str = "30"
    ) -> str:
        path = self.directory / "grammar.mly"
        path.write_text(grammar, encoding="utf-8")
        result = subprocess.run(
            [
                str(ENGINE),
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
        output = self.search(LR1_LIST)
        self.assertRegex(output, TERMINATION_LINE)
        self.assertIn("the search space within the token bound was exhausted", output)

    def test_a_curtailed_search_names_its_limit(self) -> None:
        # The other side of the same line: a deadline of zero stops the search
        # before it can rule anything out, and the report has to say which of
        # the two happened.
        output = self.search(AMBIGUOUS_EXPRESSION, max_tokens="16", timeout="0")
        self.assertRegex(output, TERMINATION_LINE)
        self.assertIn("the timeout was reached", output)
        self.assertNotIn("the search space within the token bound was exhausted", output)

    def test_a_search_with_witnesses_also_reports_termination(self) -> None:
        # Witnesses do not excuse the run from saying how it ended: whether the
        # ones reported are all of them depends on the same distinction.
        output = self.search(AMBIGUOUS_EXPRESSION)
        self.assertRegex(output, WITNESS_LINE)
        self.assertRegex(output, TERMINATION_LINE)


class SurveyTests(ProverTestCase):
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
                str(ENGINE),
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
            result.returncode, VERDICT_STATUSES, result.stdout + result.stderr
        )
        return result.returncode, result.stdout

    def test_a_conflict_free_grammar_surveys_to_no_sites(self) -> None:
        # The survey walks the whole abstract space rather than stopping, so a
        # grammar with nothing to find must come back empty and still prove.
        status, output = self.survey(LR1_LIST, 2)
        self.assertRegex(output, SURVEY_LINE)
        self.assertIn("0 distinct divergence site(s)", output)
        self.assertEqual(status, PROVEN, output)
        self.assertRegex(output, PROVEN_LINE)

    def test_an_ambiguous_grammar_surveys_to_at_least_one_site(self) -> None:
        status, output = self.survey(AMBIGUOUS_EXPRESSION, 2)
        self.assertRegex(output, SURVEY_LINE)
        self.assertNotIn("0 distinct divergence site(s)", output)
        self.assertEqual(status, NOT_PROVEN, output)

    def test_a_survey_does_not_stop_at_the_first_site(self) -> None:
        # The point of the mode. Dangling else diverges at more than one place,
        # so a survey that halted like a proof would report exactly one.
        _, output = self.survey(DANGLING_ELSE, 2)
        match = re.search(r"Survey at level \d+: (\d+) distinct", output)
        self.assertIsNotNone(match, output)
        self.assertGreater(int(match.group(1)), 1, output)

    def test_a_divergence_on_eof_is_counted_as_a_site(self) -> None:
        # The soundness case for this mode. EOF is not one of the terminals the
        # site loop walks, so a grammar whose only divergence is on end of
        # input once produced zero sites while still accepting a diverged pair.
        # A survey gated on the site count would have called that a proof.
        status, output = self.survey(EOF_REDUCE_REDUCE, 2)
        self.assertRegex(output, SURVEY_LINE)
        self.assertNotIn("0 distinct divergence site(s)", output)
        self.assertNotRegex(output, PROVEN_LINE)
        self.assertEqual(status, NOT_PROVEN, output)

    def test_every_example_carries_the_site_it_was_born_at(self) -> None:
        # The point of the dump. A token trail is the same whether two parses
        # genuinely differ or the abstraction merely lost the context that
        # separated them; the stack, lookahead and conflicting moves are what
        # tell them apart, so no example may be reported without them.
        _, output = self.survey(AMBIGUOUS_EXPRESSION, 2)
        examples = len(EXAMPLE_LINE.findall(output))
        self.assertGreater(examples, 0, output)
        self.assertEqual(len(SITE_LOOKAHEAD_LINE.findall(output)), examples, output)
        # Two runs part ways only by taking different moves, so an undiverged
        # pair holds one stack rather than two.
        self.assertEqual(len(SITE_STACK_LINE.findall(output)), examples, output)
        self.assertEqual(len(SITE_CONFLICT_LINE.findall(output)), examples, output)
        self.assertEqual(len(SITE_MOVE_LINE.findall(output)), 2 * examples, output)

    def test_a_site_names_the_moves_the_abstraction_had_to_choose_between(
        self,
    ) -> None:
        # A bare pair of state numbers is only a cross-reference into
        # `menhir --explain`. Naming the two productions in conflict is what
        # makes it findable in the grammar itself.
        moves = self.conflict_moves(AMBIGUOUS_EXPRESSION, 2)
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
        moves = self.conflict_moves(AMBIGUOUS_EXPRESSION, 2)
        self.assertNotEqual(moves[0], moves[1], "\n".join(moves))

    def conflict_moves(self, grammar: str, level: int) -> list[str]:
        _, output = self.survey(grammar, level, examples=1)
        lines = [line for line in output.splitlines() if SITE_MOVE_LINE.match(line)]
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
        lines = self.conflict_moves(EOF_REDUCE_REDUCE, 1)
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
        lines = self.conflict_moves(WIDE_REDUCE_REDUCE, 1)
        self.assertTrue(
            any(PAST_STACK_TAG.search(line) for line in lines),
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
        _, output = self.survey(REBUILT_STACK, 4, examples=1)
        conflict = SITE_CONFLICT_LINE.search(output)
        self.assertIsNotNone(conflict, output)
        self.assertEqual(len(conflict.group(1).split()), 4, output)

    def test_a_proving_survey_dumps_no_sites(self) -> None:
        # Nothing accepted means nothing to explain, and a site block printed
        # anyway would read as a blind spot the proof says is not there.
        status, output = self.survey(LR1_LIST, 2)
        self.assertEqual(status, PROVEN, output)
        self.assertNotRegex(output, SITE_LOOKAHEAD_LINE)
        self.assertNotRegex(output, SITE_STACK_LINE)
        self.assertNotRegex(output, SITE_CONFLICT_LINE)

    def test_an_incomplete_survey_never_proves(self) -> None:
        # A walk that was cut short has counted nothing, so its zero is a floor
        # rather than a total and must not read as a proof -- the same rule the
        # ordinary bounded search follows.
        status, output = self.survey(LR1_LIST, 2, timeout="0")
        self.assertRegex(output, SURVEY_LINE)
        self.assertIn("incomplete", output)
        self.assertNotRegex(output, PROVEN_LINE)
        self.assertEqual(status, NOT_PROVEN, output)

    def test_a_survey_is_rejected_without_a_proof_level(self) -> None:
        path = self.directory / "grammar.mly"
        path.write_text(LR1_LIST, encoding="utf-8")
        result = subprocess.run(
            [
                str(ENGINE),
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


class ProofBudgetTests(ProverTestCase):
    def test_the_proof_budget_ignores_the_worker_count(self) -> None:
        # The abstract phase is a single sequential search, so splitting the
        # declared memory across workers that never start would shrink the
        # budget for no reason.
        budgets = set()
        for jobs in ("1", "4"):
            _, output = self.prove(
                LR1_LIST,
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
