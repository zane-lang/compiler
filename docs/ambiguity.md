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

- `ambiguity search [PROFILE]` — bounded, parallel GLR search for complete
  ambiguous sentences (`tools/ambiguity_search.ml`). A completed bound is a theorem
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
  estimate. Named profiles in `ambiguity-searches.toml` collect search intent
  in one reviewable place. `ambiguity profiles` lists them, and command-line
  options can temporarily override a profile. The default `general` profile
  is breadth-first; `deep-function-body` fixes the function-body prefix and
  rotates depth waves so sibling statements continue to receive attention.
  The search itself is bounded by the profile's token range and timeout, and a
  run that had to drop part of the space reports itself as interrupted.
  In an interactive terminal, one transient status line shows the active token
  depth, ambiguity families found at that depth, explored and unique frontiers,
  elapsed time, and a RAM bar against the configured memory budget. The
  coordinator deduplicates ambiguity families across workers before displaying
  the count. Redirected output and saved reports contain no progress line.
  `--nodes-per-depth N` expands up to `N` queued frontiers at one depth before
  descending to the next populated depth. When a deep wave ends, the search
  returns to the shallowest unfinished depth, so earlier token choices rotate
  instead of one deep subtree monopolizing the run. Smaller values are
  narrower and deeper; larger values explore more siblings before descending.
  Omitting the option preserves breadth-first scheduling. The scheduler does
  not prune queued frontiers, so a run that completes its bound remains
  exhaustive.
  `--min-tokens N` prevents shorter ambiguities from consuming witness slots.
  `--prefix-tokens "TOKENS..."` first advances the GLR parser through a fixed
  token prefix and searches from that frontier, which is useful for targeting
  contexts such as a function body. Minimum and maximum token counts include
  the prefix and `EOF`.
  Witnesses are grouped by the conflict states they
  traverse, which maps each finding directly onto an obligation above.
  Before searching, the tool computes **terminal equivalence classes**:
  terminals that behave identically throughout the LR automaton — the same
  shifts (up to a state bisimulation), the same reductions as a lookahead, and
  the same acceptance — are interchangeable, so swapping one for another is an
  automorphism of the recognition relation. The search explores a single
  representative per class instead of every interchangeable token, which cuts
  the branching factor wherever a construct admits several equivalent terminals
  (for the current grammar, the value atoms `FALSE`/`FLOAT`/`STRING`/`TRUE`
  collapse to one class, as do same-precedence operator groups such as
  `+`/`-` and `*`/`/`). Precedence and associativity are already resolved in
  the automaton's concrete actions, so tokens with different precedence never
  share a class; and a token that reaches a context the others do not — `INT`,
  which is also a const-generic argument — stays in its own class. Because
  class members generate isomorphic parse forests, a completed bound is a
  theorem up to renaming terminals within their class: an ambiguous sentence
  exists with one member iff it exists with every member, so no obligation is
  lost. Witnesses render with the representative terminal.
- `ambiguity prove K [PROFILE]` — conservative unambiguity proof mode built
  into the ambiguity search. It abstracts GLR stacks to their top-K states and
  exhaustively explores pairs of abstract parses of the same input, comparing
  reduction chains in lockstep. It does not depend on an external constraint
  solver. Three verdicts: exit 0 "PROVEN UNAMBIGUOUS" is a genuine proof with
  no sentence-length bound; exit 1 means a concrete ambiguous sentence was
  found; exit 3 means not proven — the abstraction reported a candidate the
  bounded search could not concretize, so raise the proof level or override the
  concretization profile.
  Because unambiguity is undecidable in general, the "not proven" verdict can
  never be eliminated entirely; the prover is validated against known-ambiguous
  grammars, LR(1) grammars, precedence-resolved expression grammars, and
  unambiguous non-LR grammars such as palindromes.
- `ambiguity classes` — lists the terminal equivalence classes the search
  collapses, so a grammar change that unexpectedly splits or merges a class is
  visible. The same classes bound the prover's terminal alphabet.
- `syntax-experiment` — compares candidate grammar changes under
  equal search bounds before they are adopted
  (`tools/SYNTAX_EXPERIMENT.md`).
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

Search intent lives in versioned profiles, with concise overrides for one-off
runs. For example, `ambiguity search general --tokens 0..100 --timeout 1h`
searches through 100 tokens for up to one hour, using the local machine budget.
Friendly durations such as `90s`, `30m`, and `1h` are accepted. Add
`--output report.txt` to display and save a report, or `--dry-run` to inspect
the resolved settings without building the engine.

Every profile setting has an identically named override flag: the TOML key and
the `--flag` share the same kebab-case spelling (`tokens`, `timeout`,
`witnesses`, `prefix-tokens`, `nodes-per-depth`, `output`), and the command line
overrides the profile. A single registry in `tools/ambiguity.py` declares each
setting once and drives both the profile keys and the flags, so they cannot
drift apart. The two remaining flags are not settings: `--breadth-first` is just
`nodes-per-depth` turned off (a profile expresses it by leaving the key unset),
and `--dry-run` is a run mode.

The `output` path — whether set as a profile key or passed with `--output` —
may contain placeholders that are filled in when the run starts: `{profile}` is
the resolved profile name, and `{date}`, `{time}`, and `{datetime}` are
timestamps laid out like the existing `reports/` filenames (`2026-07-23`,
`21-38-17`, and `2026-07-23_21-38-17`). Any directories in the expanded path are
created automatically, so `output = "reports/{profile}-{date}.txt"` in a profile
(or `--output reports/{profile}-{date}.txt` on the command line) drops a dated
report into `reports/` without a manual `mkdir`. Write `{{` and `}}` for literal
braces.

To concentrate a run inside a function body and favor depth over breadth:

```sh
ambiguity search deep-function-body
```

To change just one aspect without creating a profile:

```sh
ambiguity search deep-function-body --nodes-per-depth 4 --timeout 2h
```

Exact witnesses can be checked without quoting their token names:

```sh
ambiguity check UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN EOF
```

## Why this is sound

Unambiguity of an arbitrary grammar admits no complete decision procedure,
but a *specific* grammar is proven unambiguous by a finite argument when
its structure supports one. Keeping the obligations discharged is exactly
keeping such a finite argument in existence at all times: determinism
certificates where the grammar is locally LR, human induction arguments
where it is not, and exhaustive bounded search as the continuous attempt at
falsification.
