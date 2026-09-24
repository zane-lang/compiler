# CEGAR proof research handoff

As of 2026-09-24, draft [PR #106](https://github.com/zane-lang/compiler/pull/106)
remains exploratory. The last baseline full-grammar CI probe, run #125, tested
branch revision `7ab4e04dd50cfc90185ad14a2af4cd0f39438d02`; its CEGAR changes and
regression tests are in place, but the full grammar is **not proven
unambiguous**. The CI job was green because its probe treats an inconclusive
proof (exit 3) as an acceptable research result; green CI is not a proof
verdict. Follow-up review commit
[`40af4bd`](https://github.com/zane-lang/compiler/commit/40af4bd96d10321981e5a42cd9899373d9388694)
caches terminal-class members during exact replay; this document does not
record a full-grammar probe result for that later commit.

The temporary 21-minute proof-probe step and artifact upload were removed in
[`6ce1ba8`](https://github.com/zane-lang/compiler/commit/6ce1ba85b7bd947d75ef7b3ac898aac7d2cd6535)
after these measurements were captured. Normal CI on that head passed in
[run #128](https://github.com/zane-lang/compiler/actions/runs/35977109651);
it did not run a full-grammar proof probe, so run #125 remains the latest
baseline CI result. Later isolated comparison probes on research variants are
recorded separately below; they do not update the baseline CI result or prove
the current grammar unambiguous.

## Current CEGAR behavior

`--prove-cegar N` is opt-in. For a candidate history, the exact recognizer
checks the representative and every concrete substitution represented by its
terminal-equivalence classes (up to 4,096 histories). If any history has two
parses, the run reports ambiguity. If every history has at most one parse, the
prover adds that complete history to a path-sensitive history-trie/DFA product
and restarts the abstract walk. The filter is part of the pair key, so an
unblocked history that reaches the same parser state stays visible. If exact
checking exceeds its variant or deadline limit, CEGAR skips that candidate and
falls through to stack refinement; it does not exclude an unchecked history.

Regression coverage includes reversed histories where the first sentence has
one parse but the other has two, longer sentences sharing a blocked prefix,
independent candidates, incomplete class expansion, and duplicate and
nullable reductions. See [`history_cegar_test.py`](../../test/ambiguity/prover/history_cegar_test.py)
and the filter construction in [`prover.ml`](../../tools/ambiguity/prover.ml).

## Full-grammar CI probes

Both runs used `AMBIGUITY_MEMORY_MB=6144`,
`AMBIGUITY_MAX_FRONTIER_RATIO=1.0`, `AMBIGUITY_JOBS=4`, and
`AMBIGUITY_MENHIR=menhir`. The friendly profile command requires room for EOF,
so CI called the engine entry point directly to request the zero-token proof
probe. The prover reports its pair budget as single-threaded; `JOBS=4` does not
parallelize the abstract pair walk.

| Actions run | Branch revision / report `GITHUB_SHA` | CI result | Proof result |
| --- | --- | --- | --- |
| [#124](https://github.com/zane-lang/compiler/actions/runs/35970922044) | `7261f32c0f950c352f085ed0b1f64941eabdde98` / `12cae4fdff40c281ed69febec345ef7d223a2ed7` | Success | `NOT PROVEN` (exit 3): the 330-second engine timeout expired at level 1 after 1,296,161 pairs; one history was exactly excluded. |
| [#125](https://github.com/zane-lang/compiler/actions/runs/35973025701) | `7ab4e04dd50cfc90185ad14a2af4cd0f39438d02` / `8fd260ad2d983ec2f2b83d314e4e336b8bf1a485` | Success; build and 204 tests passed | `NOT PROVEN` (exit 3): the 6,902,626-pair limit stopped the level-1 walk before its shared deadline. |

The report artifacts are named `ambiguity-proof-probe-35970922044-1` and
`ambiguity-proof-probe-35973025701-1`. The run links carry the artifacts; this
document keeps the results because artifact retention is temporary.

Run #128 is a separate post-cleanup CI check: its build and parser/ambiguity
tests passed, but it has no proof verdict because the temporary probe had been
removed. A green CI check and a decisive ambiguity-proof result are separate
things.

The exact engine invocations were:

```sh
timeout --signal=TERM --kill-after=10s 6m devbox run -- \
  dev/bin/ambiguity __engine --max-tokens 0 --min-tokens 0 \
  --timeout 330 --max-witnesses 1 --prove 1 --prove-cegar 3 --prove-refine 4

timeout --signal=TERM --kill-after=10s 22m devbox run -- \
  dev/bin/ambiguity __engine --max-tokens 0 --min-tokens 0 \
  --timeout 1260 --max-witnesses 1 --prove 1 --prove-cegar 3 --prove-refine 4
```

Run #124 found one spurious history, then timed out during the next level-1
walk. Run #125 raised the shared engine deadline to 1,260 seconds. It exactly
excluded three histories, each with zero parses for its representative and
one terminal-class substitution checked for at most one parse:

```text
UIDENT DOT LIDENT LCURLY RCURLY THICK_ARROW UIDENT RPAREN EOF
UIDENT LCURLY RCURLY THICK_ARROW LCURLY TILDE UIDENT RPAREN EOF
UIDENT LCURLY RCURLY THICK_ARROW TILDE LCURLY UIDENT RPAREN EOF
```

After the third exclusion, the restarted walk grew from about 1.5M pairs / 1.2M
queued at 5:05 to 6.8M / 6.5M queued at 6:03, then reached the 6,902,626-pair
cap at about 6:29 with zero accepting pairs. The next blocker is pair-space
size or representation; more wall-clock time alone leaves the cap unchanged.
The run has not established unambiguity, and it has not produced a concrete
ambiguity in the current grammar.

## Soundness history and rejected experiments

- **Duplicate reductions:** the prover now preserves production-occurrence
  identity, so identical-looking alternatives remain distinct derivations.
  CEGAR regression tests require duplicate production, non-representative
  terminal, and nullable/EOF ambiguities to remain visible. See commit
  [`ee1ab95`](https://github.com/zane-lang/compiler/commit/ee1ab95) and
  `test_CEGAR_never_excludes_duplicate_production_ambiguity` in the cited
  suite.
- **Minimum-token search:** an accepted prefix shorter than `--min-tokens` must
  remain expandable until the requested boundary. The fix is in
  [`73256b4`](https://github.com/zane-lang/compiler/commit/73256b4), with a
  four-token regression in [`cli_test.py`](../../test/ambiguity/cli_test.py).
- **Earlier CEGAR false proof:** sentence blocking keyed only by merged parser
  states erased a second, ambiguous history after excluding the first history.
  In `CEGAR_AM_AO_PERMUTATIONS`, `AM AO A LB RB SEMI EOF` has one parse while
  `AO AM A LB RB SEMI EOF` has two. Blocking the first by merged parser state
  erased the reverse-order history and falsely reported `PROVEN`. The current
  filter tracks history in the DFA product; regression
  `test_blocking_first_AM_AO_history_preserves_ambiguous_permutation` checks
  both exact counts and requires the proof run to report `AMBIGUOUS`.
- **Rejected terminal-count filter:** filtering a pair using balance counts
  from its first-arriving sentence was unsound: the same abstract pair may be
  reached later by a balanced ambiguous sentence. The experiment was removed;
  its reasoning and measurements are recorded in
  [`experiments.md`](experiments.md#sharpenings-that-were-measured-and-rejected).
- **Rejected bottom-stack precision:** retaining bottom entries or keeping
  every short stack exact caused pair growth (about 10k pairs at level 2 with
  no bottom entries, 90k with three, and no completion within five minutes
  with five). The measured alternatives are also in
  [`experiments.md`](experiments.md#sharpenings-that-were-measured-and-rejected).

The open issue [#90](https://github.com/zane-lang/compiler/issues/90) records a
historical 13-token match ambiguity and the command that found it. That witness
was addressed by [#88](https://github.com/zane-lang/compiler/pull/88), which
parenthesized match scrutinees. #90 does not track the present, inconclusive
proof status. The current obligations remain listed in
[`proof-obligations.md`](proof-obligations.md).

One context-specific refinement direction remains unfinished. The measured
bottom-entry experiment in [`experiments.md`](experiments.md#sharpenings-that-were-measured-and-rejected)
cost about 10k level-2 pairs with no bottom entries, 90k with three, and did
not finish within five minutes with five, even though the context markers of
interest sit at height five or deeper. The current soundness argument descends
through forced predecessors and stops at a branch; carrying one stack for
each predecessor would make the pair work quadratic in the branch count.
An on-demand, conflict-context-specific split at just the needed markers has
not been implemented or measured. The proposed single-run, conflict-origin
closure is tracked separately in [issue #108](https://github.com/zane-lang/compiler/issues/108);
the global pair-cap/proof objective remains [#107](https://github.com/zane-lang/compiler/issues/107).

## Toolchain and limits

Run #125 used OCaml 5.4.1 and Menhir 20260209 from the repository's Devbox/opam
toolchain. The package requires OCaml >=5.1 and Menhir >=20260122; Menhir state
numbers are version-sensitive. Older checked-in reports built with OCaml
4.14.1 and Menhir 20231231 are useful for their witnesses and outcomes, but
their automaton state numbers should not be compared with the current CI run.
The repository's current CI toolchain version is available in the [#125 job
log](https://github.com/zane-lang/compiler/actions/runs/35973025701).

The direct probe used a 21-minute shared engine deadline, a 22-minute outer
timeout, and a 23-minute step timeout. Memory and the pair cap are separate
from the clock. In particular, the latest run ended on the pair cap, not the
deadline.

## Next steps

1. Track the present proof blocker in [issue #107](https://github.com/zane-lang/compiler/issues/107). Compare CEGAR disabled and 1–3 rounds against stack refinement under the same pair and memory limits, then profile pair-key and queue storage in `tools/ambiguity/prover.ml`. Any larger budget should include measured resident memory and pair counts.
2. Keep the proof obligation ledger honest: report only a sound proof, a recognizer-confirmed two-parse witness, or `NOT PROVEN` with its stopping limit.
3. The one-off 21-minute proof step, its artifact upload, and its extended timeout were removed in [`6ce1ba8`](https://github.com/zane-lang/compiler/commit/6ce1ba85b7bd947d75ef7b3ac898aac7d2cd6535); standard CI passed afterward in [run #128](https://github.com/zane-lang/compiler/actions/runs/35977109651). The exact probe commands and results are retained above.
4. PR review suggested two performance checks. The repeated-terminal-class rescan during exact exclusion was removed by caching class-member lists by class ID for each candidate check in [`40af4bd`](https://github.com/zane-lang/compiler/commit/40af4bd96d10321981e5a42cd9899373d9388694), so repeated positions reuse a list instead of rescanning all terminals; the regression verifies that the full substitution product is reported. A separate suggestion to remove the per-token `over_budget()` call in [`search.ml`](https://github.com/zane-lang/compiler/blob/40af4bd96d10321981e5a42cd9899373d9388694/tools/ambiguity/search.ml#L461-L477) was declined: the outer guard runs once per queued item, but one item may have many token transitions. The inner guard checks deadline and heap budget before each shift, while queue/frontier caps are checked after shifting, so dropping it could overshoot a hard budget. See [review comment 1](https://github.com/zane-lang/compiler/pull/106#discussion_r4090931970), the [maintainer reply](https://github.com/zane-lang/compiler/pull/106#discussion_r4091574556), and [review comment 2](https://github.com/zane-lang/compiler/pull/106#discussion_r4090931978). This guard rationale is separate from the full proof's pair-cap cause.


## Pair-hash and CEGAR comparison

These later isolated full-grammar probes compared research variants after the
baseline CI run #125. They do not conflict with the statement above that #125
was the latest probe in the baseline CI series. The isolated pair-hash trial
did not establish a useful standalone speedup. The CEGAR history-subsumption
trial produced only 31 skips across 113 enqueue checks, a small effect. All
three reviewed variants built and passed the parser and ambiguity test suites;
each full-grammar run below ended with the expected bounded `NOT PROVEN`
verdict.

| Run | Source variant | Terminal pair count | Peak RSS | Wall time | Result |
| --- | --- | ---: | ---: | ---: | --- |
| [#2](https://github.com/zane-lang/compiler/actions/runs/35983432969) | Pair hash + CEGAR | 4,133,138 | 7,058,316 KB | 14:10.70 | [Artifact](https://github.com/zane-lang/compiler/actions/runs/35983432969/artifacts/10802390443) |
| [#4](https://github.com/zane-lang/compiler/actions/runs/35987228169) | CEGAR only | 1,489,794 | 7,346,328 KB | 14:01.94 | [Artifact](https://github.com/zane-lang/compiler/actions/runs/35987228169/artifacts/10803167041) |
| [#6](https://github.com/zane-lang/compiler/actions/runs/35990378384) | Pair hash only | 1,115,371 | 7,047,260 KB | 14:02.39 | [Artifact](https://github.com/zane-lang/compiler/actions/runs/35990378384/artifacts/10804418419) |

Run #2 reached 4.13 million pairs after three history exclusions; run #4 reached 1.49 million after its CEGAR skips; run #6 reached 1.12 million after three history exclusions. These are the reported pair counts at the terminal phase, not totals summed over CEGAR restarts. Each run had the same 840-second engine timeout and 15-minute outer timeout. The baseline [run #125](https://github.com/zane-lang/compiler/actions/runs/35973025701) reached its 6,902,626 pair cap at about 6:29; its workflow did not record peak RSS.

These results vary substantially between runs and after CEGAR restarts, so they do not establish causality or a stable throughput benefit for either optimization. The pair-hash source change and CEGAR subsumption change are therefore reverted for now. Keep future comparisons isolated and repeat them before drawing a performance conclusion.
