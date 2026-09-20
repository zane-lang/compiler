#!/usr/bin/env python3
"""Running the prover and reading what it said.

The engine is an executable, so every test here is a subprocess and an
assertion about its output. This module owns both ends of that: the
environment a run needs, the base case that builds a grammar file and invokes
`--prove` against it, and the patterns the verdict, the refinement rounds, the
retirements, the forward trace and the survey are read back with.

The patterns are shared rather than per-test because they are the engine's
reporting contract. A line that changes shape should fail everything that
depends on it at once, in one place, instead of being re-spelled in each test
that happens to look for it.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[3]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity" / "ambiguity_search.exe"

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
WITNESS_LINE = re.compile(
    r"^(?:Found \d+ complete ambiguity|AMBIGUOUS: the recognizer found two derivations)",
    re.MULTILINE,
)
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
# A recognizer-confirmed ambiguity the bounded search could not reach. The
# abstract phase has no token bound and the search does, so the witness family
# can be out of the search's reach while the finding itself is settled.
AMBIGUOUS_BEYOND_BOUND = re.compile(
    r"^AMBIGUOUS: the recognizer found two derivations of (.+) \((.*)\), which "
    r"the bounded search did not reach within (\d+) tokens, so no witness "
    r"family is rendered\. Raise the token bound to render it\.$",
    re.MULTILINE,
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
# What a round costs now that rounds share one walk: the pairs a deepening put
# back into play, out of the ones already settled, and how many pairs they are
# reached from.
# A proof reached after refinement is re-proved from the initial pair at the
# precision the run ended on, because every round after the first inherits a
# table built at blunter precisions.
REPROVING_LINE = re.compile(
    r"^Re-proving from the initial pair at the precision this run ended on, ",
    re.MULTILINE,
)
REOPENED_LINE = re.compile(
    r"^  reopened (\d+) of (\d+) settled pair\(s\) from (\d+) entry point\(s\), "
    r"discarding (\d+) queued$",
    re.MULTILINE,
)
# The third way a run says a blind spot outlived every depth it could try: the
# deepening climbed to the ceiling the caller set and the candidate was still
# there.
REFINEMENT_CEILING = re.compile(
    r"^Refinement stopped after \d+ round\(s\): it survives every stack "
    r"--prove-refine \d+ allows\.$",
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
RESIDUE_LINE = re.compile(
    r"^Stack residue: refused (\d+) move\(s\) whose outstanding terminals "
    r"cannot reach the selected automaton state \((\d+) residue classes\)\.$",
    re.MULTILINE,
)


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
                "requires a built _build/default/tools/ambiguity/ambiguity_search.exe and menhir"
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
