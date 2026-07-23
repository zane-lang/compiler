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

- `ambiguities` — bounded, parallel GLR search for complete ambiguous
  sentences (`tools/ambiguity_search.ml`). A completed bound is a theorem
  ("no ambiguous sentence of at most N tokens"), up to the astronomically
  unlikely collision of the 124-bit frontier digests used for
  deduplication; an interrupted bound is evidence only.
  `AMBIGUITY_MEMORY_MB` sets an approximate total resident-memory budget shared
  by all workers. The tool derives two per-worker limits from it: a queue cap,
  which controls search reach and the live stack set, and an evicting
  digest-cache size, which controls deduplication.
  `AMBIGUITY_MAX_FRONTIER_RATIO` is the number of digest-cache entries per
  queued frontier: raising it trades queue reach for stronger deduplication,
  while lowering it does the opposite. The estimate is based on
  `queue * (600 + 24 * max_tokens) + cache * 240` bytes per worker. The cache
  limit covers both of its generations; it is not multiplied behind the
  scenes. Workers also monitor their actual OCaml heap: they compact at 80% of
  their share, first release the older (purely optional) dedup generation,
  stop admitting new frontiers at 90%, and resume below 85%. The remaining 10%
  covers the coordinator, native allocations, and transient compaction/
  copy-on-write overhead. This keeps memory near the configured plateau while
  prioritizing queue reach even when real frontiers are larger than the
  estimate. The search itself is bounded by `--max-tokens` and `--timeout`, and
  a run that had to drop part of the space reports itself as interrupted.
  `--depth-bias N` changes which queued frontier is explored next without
  pruning any of them: `0` is breadth-first, `1` alternates shallowest and
  deepest work, and larger values perform `N` deepest expansions per
  shallowest expansion. This makes time-bounded runs narrower and deeper
  while preserving the exhaustiveness of a run that completes its bound.
  `--min-tokens N` prevents shorter ambiguities from consuming witness slots.
  `--prefix-tokens "TOKENS..."` first advances the GLR parser through a fixed
  token prefix and searches from that frontier, which is useful for targeting
  contexts such as a function body. Minimum and maximum token counts include
  the prefix and `EOF`.
  Witnesses are grouped by the conflict states they
  traverse, which maps each finding directly onto an obligation above.
- `ambiguities --prove K` — conservative unambiguity proof mode built into the
  ambiguity search. It abstracts GLR stacks to their top-K states and
  exhaustively explores pairs of abstract parses of the same input, comparing
  reduction chains in lockstep. It does not depend on an external constraint
  solver. Three verdicts: exit 0 "PROVEN UNAMBIGUOUS" is a genuine proof with
  no sentence-length bound; exit 1 means a concrete ambiguous sentence was
  found; exit 3 means not proven — the abstraction reported a candidate the
  bounded search could not concretize, so raise `--prove` or the search bounds.
  Because unambiguity is undecidable in general, the "not proven" verdict can
  never be eliminated entirely; the prover is validated against known-ambiguous
  grammars, LR(1) grammars, precedence-resolved expression grammars, and
  unambiguous non-LR grammars such as palindromes.
- `syntax-experiments` — compares candidate grammar changes under
  equal search bounds before they are adopted
  (`tools/SYNTAX_EXPERIMENTS.md`).
- `menhir --explain` — enumerates the conflict states that constitute the
  obligation ledger.

## Local machine configuration

The ambiguity-tool executables load machine-specific values from the ignored
`machine-config.txt` file. Copy `machine-config.example` before running them.
There are no fallback values: a missing setting is an error. This keeps memory,
worker-count, and executable-path tuning out of normal command invocations and
out of version control. The file supplies `AMBIGUITY_MEMORY_MB`,
`AMBIGUITY_MAX_FRONTIER_RATIO`, `AMBIGUITY_JOBS`, and `AMBIGUITY_MENHIR` as
environment variables; they are deliberately not command-line options.

Search intent remains on the command line. For example,
`ambiguities --max-tokens 100 --timeout 3600 --max-witnesses 50` searches
through 100 tokens for up to one hour, using the local machine budget.

To concentrate a run inside a function body and favor depth over breadth:

```sh
ambiguities \
  --prefix-tokens "UIDENT LIDENT LPAREN RPAREN LCURLY" \
  --min-tokens 15 \
  --max-tokens 20 \
  --depth-bias 20 \
  --timeout 3600 \
  --max-witnesses 50
```

## Why this is sound

Unambiguity of an arbitrary grammar admits no complete decision procedure,
but a *specific* grammar is proven unambiguous by a finite argument when
its structure supports one. Keeping the obligations discharged is exactly
keeping such a finite argument in existence at all times: determinism
certificates where the grammar is locally LR, human induction arguments
where it is not, and exhaustive bounded search as the continuous attempt at
falsification.
