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
  estimate. Named profiles in `tools/ambiguity/profiles.toml` collect search intent
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
  the count. Redirected output and saved reports have no transient line to
  rewrite, so the same numbers go out as ordinary lines at the configured
  cadence instead; only `AMBIGUITY_PROGRESS_SECONDS` at zero or less turns
  progress off.
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
  (for the current grammar, the value atoms `DECIMAL`/`FALSE`/`STRING`/`TRUE`
  collapse to one class, as do same-precedence operator groups such as
  `+`/`-` and `*`/`/`). Precedence and associativity are already resolved in
  the automaton's concrete actions, so tokens with different precedence never
  share a class; and a token that reaches a context the others do not — `INT`,
  which is also a const-generic argument — stays in its own class. Because
  class members generate isomorphic parse forests, a completed bound is a
  theorem up to renaming terminals within their class: an ambiguous sentence
  exists with one member iff it exists with every member, so no obligation is
  lost. Witnesses render with the representative terminal.
  A search exits 0 whether or not it found witnesses, since a bounded finding
  is not a verdict; exit 2 means the run itself failed.
- `ambiguity check TOKEN...` — runs the exact GLR recognizer on one token
  sequence, `EOF` included, and prints how many accepting derivations it has,
  capped at two. Token names can be passed separately or as one quoted string.
- `ambiguity classes` — lists the terminal equivalence classes the search
  collapses, so a grammar change that unexpectedly splits or merges a class is
  visible.
- `menhir --explain` — enumerates the conflict states that constitute the
  obligation ledger. `just explain --conflicts` prints them for the stock
  automaton, and `tools/ambiguity/conflict_census.py` summarises an
  explanations file by family, which is how `dune runtest` checks the census
  [`proof-obligations.md`](proof-obligations.md#where-the-current-conflicts-come-from)
  states.

## Watching a run

Every tool here writes as it goes, so a run in progress is readable rather than
a wait for a verdict. The engine flushes each line as it prints it, and
`ambiguity` streams the engine's output to the terminal and into `--output`
line by line. What ends up on disk is therefore always current: a run that is
killed or interrupted leaves behind everything it had printed, not an empty
file.

A search reports its own throughput: its depth, witness count, explored and
unique frontiers, and resident memory. On a terminal these are one line
rewritten in place several times a second. Elsewhere — under a wrapper, in a saved report, in CI — there is no cursor to
move back to, so the same numbers go out as ordinary lines every ten seconds and
stay in the log.

`AMBIGUITY_PROGRESS_SECONDS` overrides that cadence; zero or less turns progress
off entirely, for a caller that wants the result and nothing else. Anything
that is not a finite number is refused rather than obeyed: `nan` and `infinity`
parse as floats and would each be taken for a setting and then quietly show
nothing, one reading as switched off and the other as enabled but never due. Unlike the
four settings below it is optional, so it does not belong in
`machine-config.txt` — it is a property of how a particular run is being
watched, not of the machine.

## Local machine configuration

The ambiguity-tool executables load machine-specific values from the ignored
`dev/machine-config.txt` file. Copy `dev/machine-config.example` before running
them.
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

## Exact visible-stack proof

`dev/bin/ambiguity prove-visible` checks the entire accepted parse relation of
the shipped GLR backend and independently verifies a finite certificate. It
needs Python and the pinned Menhir (`--menhir` or `AMBIGUITY_MENHIR`), and does
not build the OCaml engine. `--stock` checks the grammar before the GLR nullable
rewrite. See [visible-proof.md](visible-proof.md) for the theorem, scope,
reproduction command, artifacts, limits, and exit statuses. It is the fast,
unverified implementation of the construction `just verify-grammar` checks in
Lean ([formal-proof.md](formal-proof.md)).
