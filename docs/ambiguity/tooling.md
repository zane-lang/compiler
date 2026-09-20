# Tooling

- `ambiguity search [PROFILE]` — bounded, parallel GLR search for complete
  ambiguous sentences (`tools/ambiguity/`). A completed bound is a theorem
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
  The search itself is bounded by the profile's token range and timeout, and
  every run states the depth it reached and why it ended: the token bound was
  exhausted, or the timeout, witness limit or memory budget curtailed it. That
  distinction is what a result without witnesses is worth — an exhausted bound
  has checked every sentence that short, while a curtailed run has only stopped
  looking — so it is reported rather than left to be inferred.
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
  solver. Three verdicts, each reported in the exit status so a script can act
  on it without reading the report: exit 0 "PROVEN UNAMBIGUOUS" is a genuine
  proof with no sentence-length bound; exit 1 means a concrete ambiguous
  sentence was found, which is a bug in the grammar rather than a limit of the
  abstraction; exit 3 means not proven — the abstraction reported a candidate
  the bounded search could not concretize, so raise the proof level or override
  the concretization profile; or the abstract pair limit was reached, so raise
  the memory budget; or the timeout expired mid-proof, so raise it. Exit 2
  keeps its usual meaning
  everywhere in this tool — the run itself failed — so a caller can tell a
  verdict from a broken invocation. Only proof mode reports a verdict: a plain
  `ambiguity search` exits 0 whether or not it found witnesses, since a bounded
  finding is not one.

  Reduction chains are compared only until their histories first differ. Once a
  pair has diverged, later reductions cannot make the two derivations equal
  again, so each side is closed independently and only their final stacks are
  paired. Final pairs are unordered, just like the global pair table. This
  avoids constructing the Cartesian product of every intermediate reduction
  state without changing the relation the proof explores. **A candidate is
  parsed for real before anything is spent on it.** The abstract phase reasons
  about every sentence at once and has to approximate to do it, but a single
  candidate sentence is short, and the engine already carries the exact GLR
  recognizer that `ambiguity check` drives. So the sentence is recognized the
  moment the abstraction names it, and the answer decides what happens next.
  Two derivations settle the grammar: it is ambiguous, refining would be
  sharpening an abstraction that turned out to be right, and the run prints
  `AMBIGUOUS:` and exits directly. Only an unconfirmed candidate continues to
  the bounded search; that search can render a witness family, while the exact
  recognizer's finding is already decisive. Nought or one makes the pair
  spurious, and the report says which rather than leaving it to be inferred.
  The two spurious answers are not the same finding. Nought means the
  abstraction accepted something that is not a sentence — `x Foo(y(Bar` and its
  neighbours, unclosed parentheses and all — and a round spent on one buys
  nothing. One means the sentence is a real program whose single parse the
  abstraction cannot tell from a second, which is the blind spot itself. Of the
  twenty-two candidates the ninety-minute run in
  [`reports/ambiguity/prove/`](../../reports/ambiguity/prove) worked through,
  sixteen are the first kind and six the second, and before this check they
  were indistinguishable. The third answer has been seen once: the
  `import pkg$` bug, where the recognizer would have settled it in
  milliseconds rather than at the end of the bounded search.

  Because unambiguity is undecidable in general, the "not proven" verdict can
  never be eliminated entirely; the prover is validated against known-ambiguous
  grammars, LR(1) grammars, precedence-resolved expression grammars, and
  unambiguous non-LR grammars such as palindromes. That corpus lives in
  `test/ambiguity/prover/`, which pins both directions of soundness — an
  ambiguous grammar is never proven, and an unambiguous one never yields a
  witness — so a change that sharpens the abstraction cannot quietly start
  proving false theorems. A conflict-free automaton offers one action per state
  and lookahead, so no pair of abstract runs can ever diverge and it is proven
  at every level, given a pair budget large enough to finish: that is a
  property of the automaton rather than of how sharp the abstraction currently
  is, but exhausting the budget still reports "not proven", since a search that
  stopped early has proved nothing.

  What the abstraction can and cannot see — the three things that bound its
  reach, and what each of them does to a verdict — is in
  [`soundness.md`](soundness.md), along with the argument that the whole scheme
  is sound.

- `ambiguity classes` — lists the terminal equivalence classes the search
  collapses, so a grammar change that unexpectedly splits or merges a class is
  visible. The same classes bound the prover's terminal alphabet.
- `syntax-experiment` — compares candidate grammar changes under
  equal search bounds before they are adopted
  (`tools/syntax_experiment/README.md`).
- `menhir --explain` — enumerates the conflict states that constitute the
  obligation ledger.

## Watching a run

Every tool here writes as it goes, so a run in progress is readable rather than
a wait for a verdict. The engine flushes each line as it prints it, `ambiguity`
streams the engine's output to the terminal and into `--output` line by line,
and the sweep passes each level's output through under a `[level N]` prefix
while the level runs. What ends up on disk is therefore always current: a run
that is killed or interrupted leaves behind everything it had printed, not an
empty file.

Both long phases report their own throughput. The abstract phase prints how
many stack pairs it has settled, how many are still queued, and how many
accepting divergences it has found; the concretization search prints its depth,
witness count, explored and unique frontiers, and resident memory. On a
terminal these are one line rewritten in place several times a second.
Elsewhere — under a wrapper, in a saved report, in CI — there is no cursor to
move back to, so the same numbers go out as ordinary lines every ten seconds and
stay in the log.

`AMBIGUITY_PROGRESS_SECONDS` overrides that cadence; zero or less turns progress
off entirely, for a caller that wants the verdict and nothing else. Anything
that is not a finite number is refused rather than obeyed: `nan` and `infinity`
parse as floats and would each be taken for a setting and then quietly show
nothing, one reading as switched off and the other as enabled but never due. Unlike the
four settings below it is optional, so it does not belong in
`machine-config.txt` — it is a property of how a particular run is being
watched, not of the machine. The sweep's `--quiet` (`just sweep GRAMMAR
--quiet`) and `syntax-experiment --quiet` suppress the pass-through of the
engine's output without touching what the sweep or the experiment prints
itself.

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
`witnesses`, `prefix-tokens`, `nodes-per-depth`, `breadth-first`, `output`), and
the command line overrides the profile. A single registry in
`tools/ambiguity/profiles.py` declares every flag once — value flags, the
`breadth-first` toggle, and the `dry-run` mode alike — and marks which ones
profiles may set, so the flags and the profile keys are one list and cannot
drift apart. The only flag that is not a profile key is `--dry-run`, which is a
run mode (show the resolved settings without running the engine), not saved
search intent.

Scheduling is one slot with two spellings: a profile sets either
`nodes-per-depth = N` (depth waves) or `breadth-first = true` (shortest-first),
never both. Because breadth-first is now a real key, a child profile can reset
an inherited `nodes-per-depth` back to breadth-first (or the reverse) — the
child's choice replaces whichever the parent set. On the command line,
`--breadth-first` overrides a profile's `nodes-per-depth`, and giving both
`--breadth-first` and `--nodes-per-depth` at once is an error.

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
