# Ambiguity policy

Zane's grammar is deliberately not LR(1): the language is parsed with a
GLR+LR hybrid (menhirGLR, previously Elkhound), and constructs may require
unbounded lookahead. Nondeterminism is accepted; ambiguity is not.

**Policy: the grammar must remain provably unambiguous.** A GLR parser may
fork wherever it needs to, but on every input all forks except one must
eventually die. General context-free ambiguity is undecidable, so no tool
can certify this automatically for arbitrary grammars — instead the proof
is maintained as a finite set of per-conflict obligations, which is
possible because every fork point is an LR conflict state and Menhir
enumerates those exhaustively.

## Proof obligations

Every LR conflict state must carry exactly one of:

1. **A precedence resolution.** The conflict is resolved by a declared
   precedence or associativity; the resolution is deliberate and the
   intended reading is documented. Resolved conflicts are deterministic and
   need no further argument.
2. **A transience argument.** A short written proof that the two branches
   of the fork can never both reach acceptance, keyed to the conflict
   state's LR items so that grammar changes touching the construct
   visibly invalidate the argument.
3. **An open obligation.** Permitted, but tracked: open obligations are the
   standing targets of the bounded ambiguity search, and a found witness
   turns one into a bug.

A grammar change that introduces a new conflict state is incomplete until
the state is triaged into one of these categories.

## Tooling

- `just ambiguities` — bounded, parallel GLR search for complete ambiguous
  sentences (`tools/ambiguity_search.ml`). A completed bound is a theorem
  ("no ambiguous sentence of at most N tokens"), up to the astronomically
  unlikely collision of the 124-bit frontier digests used for
  deduplication; an interrupted bound is evidence only. `--max-frontiers`
  bounds resident memory per worker (an evicting digest cache plus a cap
  on queued frontiers, roughly 2 KB per unit); the search itself is
  bounded by `--max-tokens` and `--timeout`, and a run that had to drop
  part of the space reports itself as interrupted. Witnesses are grouped by the conflict states they
  traverse, which maps each finding directly onto an obligation above.
- `just prove` — conservative unambiguity prover (`--prove K`). It abstracts
  GLR stacks to their top-K states and exhaustively explores pairs of
  abstract parses of the same input, comparing reduction chains in lockstep.
  Three verdicts: exit 0 "PROVEN UNAMBIGUOUS" is a genuine proof with no
  sentence-length bound; exit 1 means a concrete ambiguous sentence was
  found; exit 3 means not proven — the abstraction reported a candidate the
  bounded search could not concretize, so raise `--prove` or the search
  bounds. Because unambiguity is undecidable in general, the "not proven"
  verdict can never be eliminated entirely; the prover is validated against
  known-ambiguous grammars, LR(1) grammars, precedence-resolved expression
  grammars, and unambiguous non-LR grammars such as palindromes.
- `just syntax-experiments` — compares candidate grammar changes under
  equal search bounds before they are adopted
  (`tools/SYNTAX_EXPERIMENTS.md`).
- `menhir --explain` — enumerates the conflict states that constitute the
  obligation ledger.

## Why this is sound

Unambiguity of an arbitrary grammar admits no complete decision procedure,
but a *specific* grammar is proven unambiguous by a finite argument when
its structure supports one. Keeping the obligations discharged is exactly
keeping such a finite argument in existence at all times: determinism
certificates where the grammar is locally LR, human induction arguments
where it is not, and exhaustive bounded search as the continuous attempt at
falsification.
